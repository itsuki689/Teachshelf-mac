import Foundation
import Darwin

/// A single writer owns a library. Every metadata mutation commits to disk before
/// replacing the in-memory snapshot, so a failed save never changes visible data.
/// Domain operations live in Repository/ extensions and share this transaction boundary.
public final class LibraryRepository: @unchecked Sendable {
    public let root: URL
    let fileManager = FileManager.default
    private let stateLock = NSRecursiveLock()

    // Internal state is shared with domain extensions only while holding withLock.
    // Only this file can replace the snapshot after a successful disk commit.
    private(set) var snapshot = LibraryState()
    private var lockDescriptor: Int32 = -1
    var deletedTaskBatches: [[StudyTask]] = []
    var fileObservations: [String: FileObservation] = [:]

    var indexURL: URL { root.appendingPathComponent("library.json") }
    var filesURL: URL { root.appendingPathComponent("files", isDirectory: true) }

    // MARK: - Index encoding and compatibility

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decode(_ data: Data) throws -> LibraryState {
        let decoder = JSONDecoder()
        // Swift Date's reference-time representation preserves sub-second precision.
        // Accept ISO dates too, so early development libraries remain readable.
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "无法读取日期：\(text)")
        }
        var state = try decoder.decode(LibraryState.self, from: data)
        // Normalize early metadata first. The transactional storage upgrade writes
        // the current version only after the physical directory layout is ready.
        if (1...5).contains(state.schemaVersion) { state.schemaVersion = 6 }
        return state
    }

    // MARK: - Library ownership

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        try rejectSymbolicLink(self.root)
        let lockURL = self.root.appendingPathComponent(".teachshelf.lock")
        try rejectSymbolicLink(lockURL)
        lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
            throw LibraryError.locked
        }
        do {
            try rejectSymbolicLink(filesURL)
            if fileManager.fileExists(atPath: indexURL.path) {
                try rejectSymbolicLink(indexURL)
                do {
                    snapshot = try Self.decode(Data(contentsOf: indexURL))
                    try validate(snapshot)
                } catch {
                    throw LibraryError.invalidLibrary(error.localizedDescription)
                }
            } else {
                guard !fileManager.fileExists(atPath: self.root.appendingPathComponent("library.json.bak").path) else {
                    throw LibraryError.invalidLibrary("主索引缺失，但检测到 library.json.bak。请先恢复原索引，避免创建空资料库。")
                }
                try persist(snapshot)
            }
            try rejectSymbolicLink(filesURL)
            try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)
            try recoverPhysicalStorage()
            try recoverMaterialRelocation()
            loadFileObservations()
            if snapshot.schemaVersion >= 9 { try synchronizeFileSystem() }
            // Upgrade legacy layouts while retaining recoverable filesystem transactions.
            try saveSnapshot(snapshot, storageOnly: true, repairDirectories: snapshot.schemaVersion < 9)
        } catch {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
            throw error
        }
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
    }

    // MARK: - Transactions

    public var state: LibraryState { withLock { snapshot } }
    public var canUndoTaskDeletion: Bool { withLock { !deletedTaskBatches.isEmpty } }

    /// Keep a read/modify/write operation and its file changes under the same lock.
    func withLock<T>(_ action: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try action()
    }

    /// Mutate a value copy; publish it only after validation and persistence succeed.
    func commit(_ modify: (inout LibraryState) throws -> Void) throws {
        try withLock {
            try synchronizeFileSystem()
            var next = snapshot
            try modify(&next)
            try saveSnapshot(next)
        }
    }

    /// Journal filesystem changes before applying them. The index hash distinguishes
    /// a committed move from an interrupted transaction on the next launch.
    func saveSnapshot(_ state: LibraryState, storageOnly: Bool = false, storageState: LibraryState? = nil, repairDirectories: Bool = false) throws {
        try recoverPhysicalStorage()
        try recoverMaterialRelocation()
        try validate(state)
        let next = try organizedMaterials(state)
        try validate(next)
        let transaction = PhysicalStorageTransaction(repository: self, next: next)
        do {
            try preparePhysicalStorage(from: storageState ?? snapshot, candidates: state, to: next,
                                       repairDirectories: repairDirectories || storageState != nil, transaction: transaction)
            if !storageOnly || next != snapshot { try persist(next) }
            snapshot = next
        } catch {
            do { try recoverPhysicalStorage(rollingBack: true) }
            catch { throw LibraryError.invalidInput("文件整理未完成，恢复日志已保留；请重新打开资料库重试恢复。\(error.localizedDescription)") }
            throw error
        }
        // A committed index remains authoritative if cleanup is interrupted.
        try? transaction.finish()
        // A stale observation file is safe: IDs survive renames and absent entries
        // are enrolled from the committed paths on the next scan.
        try? refreshFileObservations()
    }

    func publishFileSystemChanges(_ state: LibraryState) throws {
        try validate(state)
        if state != snapshot { try persist(state); snapshot = state }
    }

    // MARK: - Validation and atomic persistence

    func validate(_ state: LibraryState) throws {
        guard [6, 7, 8, 9].contains(state.schemaVersion), state.schemaVersion >= 7 || state.teachingConnections.isEmpty else { throw LibraryError.invalidInput("不支持的资料库版本 \(state.schemaVersion)。") }
        try validateStorageOverrides(state)
        try Self.validateTeachingConnections(state)
        try Self.validateMaterialOrganization(state)
        guard ["system", "light", "dark"].contains(state.appearance) else { throw LibraryError.invalidInput("未知的外观设置。") }
        guard state.appearanceTransition.isValid else { throw LibraryError.invalidInput("资料库包含无效的明暗过渡设置。") }
        guard state.toolbarSettings.isValid else { throw LibraryError.invalidInput("资料库包含无效的顶栏设置。") }
        guard ColorPalette.isStoredColor(state.accentColor) else { throw LibraryError.invalidInput("资料库包含无效的强调色。") }
        guard Set(state.courses.map(\.id)).count == state.courses.count,
              Set(state.materials.map(\.id)).count == state.materials.count,
              Set(state.tasks.map(\.id)).count == state.tasks.count else { throw LibraryError.invalidInput("资料库包含重复的记录编号。") }
        let courseIDs = Set(state.courses.map(\.id)), materialIDs = Set(state.materials.map(\.id))
        let categoryNames = try state.customCategories.map(normalizeCategory)
        guard categoryNames == state.customCategories,
              Set(categoryNames.map { $0.lowercased() }).count == categoryNames.count else { throw LibraryError.invalidInput("自定义类别包含重复或未规范化的名称。") }
        for course in state.courses {
            guard !course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("课程名称不能为空。") }
            if let folder = course.homeworkFolder, !folder.hasPrefix("/") || folder.contains("\0") { throw LibraryError.unsafePath(folder) }
        }
        for material in state.materials {
            guard !material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("资料标题不能为空。") }
            guard try normalizeCategory(material.category) == material.category else { throw LibraryError.invalidInput("资料类别名称未规范化。") }
            if let id = material.courseID, !courseIDs.contains(id) { throw LibraryError.invalidInput("资料关联的课程不存在。") }
            _ = try fileURL(for: material)
        }
        for task in state.tasks {
            try Self.validatePlan(task, courseIDs: courseIDs, materialIDs: materialIDs)
        }
        try validateTimetables(state.timetableTerms, courseIDs: courseIDs)
    }

    private func persist(_ state: LibraryState) throws {
        try rejectSymbolicLink(indexURL)
        let temporary = root.appendingPathComponent(".index-\(UUID().uuidString).tmp")
        let backupTemporary = root.appendingPathComponent(".backup-\(UUID().uuidString).tmp")
        defer {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: backupTemporary)
        }
        let data = try Self.encoder.encode(state)
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.copyItem(at: indexURL, to: backupTemporary)
            try atomicRename(backupTemporary, root.appendingPathComponent("library.json.bak"))
        }
        try atomicRename(temporary, indexURL)
    }
}
