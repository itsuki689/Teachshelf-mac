import Foundation
import Darwin

/// A single writer owns a library. Every metadata mutation commits to disk before
/// replacing the in-memory snapshot, so a failed save never changes visible data.
public final class LibraryRepository: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let mutex = NSRecursiveLock()
    private var snapshot = LibraryState()
    private var lockDescriptor: Int32 = -1
    private var deletedTaskBatches: [[StudyTask]] = []
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var filesURL: URL { root.appendingPathComponent("files", isDirectory: true) }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private static func decode(_ data: Data) throws -> LibraryState {
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
        return try decoder.decode(LibraryState.self, from: data)
    }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try rejectSymbolicLink(self.root)
        let lockURL = self.root.appendingPathComponent(".teachshelf.lock")
        try rejectSymbolicLink(lockURL)
        lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockDescriptor); lockDescriptor = -1
            throw LibraryError.locked
        }
        do {
            try rejectSymbolicLink(filesURL)
            if fm.fileExists(atPath: indexURL.path) {
                try rejectSymbolicLink(indexURL)
                do {
                    snapshot = try Self.decode(Data(contentsOf: indexURL))
                    try validate(snapshot)
                } catch {
                    throw LibraryError.invalidLibrary(error.localizedDescription)
                }
            } else {
                guard !fm.fileExists(atPath: self.root.appendingPathComponent("library.json.bak").path) else {
                    throw LibraryError.invalidLibrary("主索引缺失，但检测到 library.json.bak。请先恢复原索引，避免创建空资料库。")
                }
                try persist(snapshot)
            }
            try rejectSymbolicLink(filesURL)
            try fm.createDirectory(at: filesURL, withIntermediateDirectories: true)
        } catch {
            flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1
            throw error
        }
    }

    deinit {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor) }
    }

    public var state: LibraryState { withLock { snapshot } }
    public var canUndoTaskDeletion: Bool { withLock { !deletedTaskBatches.isEmpty } }
    private func withLock<T>(_ action: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }; return try action()
    }
    private func commit(_ modify: (inout LibraryState) throws -> Void) throws {
        try withLock {
            var next = snapshot
            try modify(&next)
            try validate(next)
            try persist(next)
            snapshot = next
        }
    }

    public func saveCourse(_ course: Course) throws {
        try commit { state in
            guard !course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入课程名称。") }
            if let folder = course.homeworkFolder,
               folder != state.courses.first(where: { $0.id == course.id })?.homeworkFolder {
                try validateMount(URL(fileURLWithPath: folder), for: course.id, in: state)
            }
            if let index = state.courses.firstIndex(where: { $0.id == course.id }) { state.courses[index] = course }
            else { state.courses.append(course) }
            for index in state.tasks.indices where state.tasks[index].courseID == course.id && !state.tasks[index].isArchived { state.tasks[index].courseNameSnapshot = course.name }
        }
    }

    public func deleteCourse(id: UUID) throws {
        try commit { state in
            guard let course = state.courses.first(where: { $0.id == id }) else { throw LibraryError.missingRecord("课程") }
            state.courses.removeAll { $0.id == id }
            for index in state.materials.indices where state.materials[index].courseID == id { state.materials[index].courseID = nil }
            for index in state.tasks.indices where state.tasks[index].courseID == id {
                state.tasks[index].courseID = nil
                if !state.tasks[index].isArchived || state.tasks[index].courseNameSnapshot == nil { state.tasks[index].courseNameSnapshot = course.name }
            }
        }
    }

    public func archiveCourse(id: UUID, archived: Bool) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("课程") }
            state.courses[index].isArchived = archived
        }
    }

    public func updateMaterial(_ material: MaterialRecord) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == material.id }) else { throw LibraryError.missingRecord("资料") }
            guard !material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入资料标题。") }
            let existing = state.materials[index]
            guard existing.storedPath == material.storedPath, existing.isManaged == material.isManaged, existing.sourcePath == material.sourcePath else {
                throw LibraryError.invalidInput("编辑资料时不能改变文件位置，请重新导入文件。")
            }
            var material = material
            material.category = try rememberCategory(material.category, in: &state)
            state.materials[index] = material
        }
    }

    /// Reconnect an external reference without changing its identity or annotations.
    /// Managed copies retain their library paths and must be reimported instead.
    public func relinkMaterial(id: UUID, to url: URL) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            guard !state.materials[index].isManaged else { throw LibraryError.invalidInput("库内副本不能重新链接，请重新导入文件。") }
            let url = url.standardizedFileURL
            try ensureSafePath(url, beneath: nil)
            guard fm.fileExists(atPath: url.path) else { throw LibraryError.missingFile(url.path) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw LibraryError.invalidInput("请选择一个普通文件。") }
            state.materials[index].sourcePath = url.path
            state.materials[index].storedPath = url.path
            state.materials[index].originalName = url.lastPathComponent
            state.materials[index].size = Int64(values.fileSize ?? 0)
        }
    }

    /// Removing a record deliberately retains its managed file on disk.
    public func removeMaterials(ids: Set<UUID>) throws {
        try commit { state in
            state.materials.removeAll { ids.contains($0.id) }
            for index in state.tasks.indices { state.tasks[index].materialIDs.removeAll { ids.contains($0) } }
        }
    }
    public func setFavorite(id: UUID, favorite: Bool) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            state.materials[index].isFavorite = favorite
        }
    }
    public func recordOpen(id: UUID) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            state.materials[index].lastOpenedAt = Date()
        }
    }
    public func resolveURL(_ material: MaterialRecord) throws -> URL {
        try withLock {
            let url = try fileURL(for: material)
            try ensureSafePath(url, beneath: material.isManaged ? root : nil)
            guard fm.fileExists(atPath: url.path) else { throw LibraryError.missingFile(url.path) }
            return url
        }
    }

    public func importFiles(urls: [URL], courseID: UUID?, category: String, copy: Bool) throws -> ImportSummary {
        try withLock {
            try ensureCourse(courseID)
            var next = snapshot
            let normalizedCategory = try rememberCategory(category, in: &next)
            var summary = ImportSummary()
            var created: [URL] = []
            var seen = Set(next.materials.filter { $0.courseID == courseID }.map(\.sourcePath))
            let candidates = collectFiles(urls, summary: &summary)
            do {
                for source in candidates {
                    if seen.contains(source.path) { summary.skipped += 1; continue }
                    do {
                        let id = UUID()
                        let name = source.lastPathComponent
                        let stored = copy ? "files/\(id.uuidString)-\(name)" : source.path
                        let values = try source.resourceValues(forKeys: [.fileSizeKey])
                        if copy {
                            let target = root.appendingPathComponent(stored)
                            try ensureSafePath(target, beneath: root)
                            try fm.copyItem(at: source, to: target)
                            created.append(target)
                        }
                        next.materials.append(MaterialRecord(id: id, courseID: courseID, title: source.deletingPathExtension().lastPathComponent, originalName: name, sourcePath: source.path, storedPath: stored, isManaged: copy, category: normalizedCategory, size: Int64(values.fileSize ?? 0)))
                        seen.insert(source.path); summary.imported += 1
                    } catch { summary.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
                }
                if summary.imported > 0 {
                    try validate(next); try persist(next); snapshot = next
                }
                return summary
            } catch {
                for url in created { try? fm.removeItem(at: url) }
                throw error
            }
        }
    }

    public func saveTask(_ task: StudyTask) throws {
        try commit { state in
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入待办标题。") }
            if let existing = state.tasks.first(where: { $0.id == task.id }), existing.isArchived {
                throw LibraryError.invalidInput("归档待办为只读，请先恢复后再编辑。")
            }
            var task = task
            if let courseID = task.courseID { task.courseNameSnapshot = state.courses.first { $0.id == courseID }?.name }
            task.materialIDs = Array(Set(task.materialIDs)).sorted { $0.uuidString < $1.uuidString }
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[index] = task }
            else { state.tasks.append(task) }
        }
    }
    public func setTaskCompleted(id: UUID, completed: Bool) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档待办为只读，请先恢复后再修改完成状态。") }
            state.tasks[index].completedAt = completed ? (state.tasks[index].completedAt ?? Date()) : nil
        }
    }
    public func archiveTask(id: UUID) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            if state.tasks[index].isArchived { return }
            let timestamp = Date()
            guard state.tasks[index].startsAt <= timestamp else { throw LibraryError.invalidInput("开始时间尚未到，无法归档此待办。") }
            if let completed = state.tasks[index].completedAt, completed > timestamp { throw LibraryError.invalidInput("完成时间晚于当前归档时间，无法归档此待办。") }
            state.tasks[index].completedAt = state.tasks[index].completedAt ?? timestamp
            state.tasks[index].archivedAt = timestamp
        }
    }
    public func restoreTask(id: UUID) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            state.tasks[index].archivedAt = nil
        }
    }
    public func deleteTasks(ids: Set<UUID>) throws {
        try withLock {
            let removed = snapshot.tasks.filter { ids.contains($0.id) }
            if removed.isEmpty { return }
            try commit { $0.tasks.removeAll { ids.contains($0.id) } }
            deletedTaskBatches.append(removed)
        }
    }
    public func undoTaskDeletion() throws {
        try withLock {
            guard let batch = deletedTaskBatches.last else { return }
            try commit { state in
                let courseIDs = Set(state.courses.map(\.id)), materialIDs = Set(state.materials.map(\.id))
                for var task in batch where !state.tasks.contains(where: { $0.id == task.id }) {
                    if let id = task.courseID, !courseIDs.contains(id) { task.courseID = nil }
                    task.materialIDs.removeAll { !materialIDs.contains($0) }
                    state.tasks.append(task)
                }
            }
            deletedTaskBatches.removeLast()
        }
    }

    public func saveAppearance(_ value: String) throws {
        guard ["system", "light", "dark"].contains(value) else { throw LibraryError.invalidInput("未知的外观设置。") }
        try commit { $0.appearance = value }
    }

    private func ensureCourse(_ id: UUID?) throws {
        if let id, !snapshot.courses.contains(where: { $0.id == id }) { throw LibraryError.missingRecord("课程") }
    }
    private func validate(_ state: LibraryState) throws {
        guard state.schemaVersion == 1 else { throw LibraryError.invalidInput("不支持的资料库版本 \(state.schemaVersion)。") }
        guard ["system", "light", "dark"].contains(state.appearance) else { throw LibraryError.invalidInput("未知的外观设置。") }
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
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("待办标题不能为空。") }
            guard [task.startsAt, task.deadline, task.completedAt, task.archivedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw LibraryError.invalidInput("待办包含无效日期。") }
            if let completed = task.completedAt, completed < task.startsAt { throw LibraryError.invalidInput("完成时间不能早于待办开始时间。") }
            if let archived = task.archivedAt {
                guard let completed = task.completedAt, completed <= archived else { throw LibraryError.invalidInput("归档待办必须已完成，且完成时间不能晚于归档时间。") }
            }
            if let id = task.courseID, !courseIDs.contains(id) { throw LibraryError.invalidInput("待办关联的课程不存在。") }
            guard task.materialIDs.allSatisfy(materialIDs.contains) else { throw LibraryError.invalidInput("待办关联的资料不存在。") }
        }
    }
    private func persist(_ state: LibraryState) throws {
        try rejectSymbolicLink(indexURL)
        let temporary = root.appendingPathComponent(".index-\(UUID().uuidString).tmp")
        let backupTemporary = root.appendingPathComponent(".backup-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary); try? fm.removeItem(at: backupTemporary) }
        let data = try Self.encoder.encode(state)
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        if fm.fileExists(atPath: indexURL.path) {
            try fm.copyItem(at: indexURL, to: backupTemporary)
            try atomicRename(backupTemporary, root.appendingPathComponent("library.json.bak"))
        }
        try atomicRename(temporary, indexURL)
    }
    private func atomicRename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func fileURL(for material: MaterialRecord) throws -> URL {
        if material.isManaged {
            guard !material.storedPath.hasPrefix("/"), material.storedPath.hasPrefix("files/"), !material.storedPath.split(separator: "/").contains(".."), !material.storedPath.contains("\0") else { throw LibraryError.unsafePath(material.storedPath) }
            let url = root.appendingPathComponent(material.storedPath).standardizedFileURL
            guard isBeneath(url, root: filesURL), url.path != filesURL.path else { throw LibraryError.unsafePath(material.storedPath) }
            return url
        }
        guard material.storedPath.hasPrefix("/") else { throw LibraryError.unsafePath(material.storedPath) }
        return URL(fileURLWithPath: material.storedPath).standardizedFileURL
    }
    private func isBeneath(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
    private func rejectSymbolicLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            // Foundation standardizes /private/var and /private/tmp back to these
            // macOS system aliases. Permit only their exact, system-owned targets.
            if url.path == "/var" || url.path == "/tmp" {
                let expected = "private" + url.path
                if let target = try? fm.destinationOfSymbolicLink(atPath: url.path), target == expected || target == "/" + expected { return }
            }
            throw LibraryError.unsafePath(url.path)
        }
    }
    private func ensureSafePath(_ url: URL, beneath base: URL?) throws {
        let url = url.standardizedFileURL
        if let base, !isBeneath(url, root: base) { throw LibraryError.unsafePath(url.path) }
        var cursor = url
        while cursor.path != "/" {
            try rejectSymbolicLink(cursor)
            if let base, cursor.path == base.path { break }
            cursor.deleteLastPathComponent()
        }
    }
    private func ensureDirectory(_ url: URL) throws {
        try ensureSafePath(url, beneath: nil)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw LibraryError.invalidInput("请选择一个现有文件夹：\(url.path)") }
    }
    private func collectFiles(_ urls: [URL], summary: inout ImportSummary) -> [URL] {
        var result: [URL] = []
        func visit(_ url: URL) {
            do {
                let url = url.standardizedFileURL
                try ensureSafePath(url, beneath: nil)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) { visit(child) }
                } else if values.isRegularFile == true { result.append(url) }
                else { summary.skipped += 1 }
            } catch { summary.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); summary.skipped += 1 }
        }
        for url in urls { visit(url) }
        return result
    }

    private static let builtInCategories = ["课件", "教材", "笔记", "参考资料", "其他"]
    private func normalizeCategory(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LibraryError.invalidInput("类别名称需要 1–40 个字符，不能包含换行或控制字符。") }
        guard !["作业", "全部类别", "全部用途"].contains(name) else { throw LibraryError.invalidInput("请使用具体的资料类别；作业请放入课程作业文件夹。") }
        return name
    }
    private func rememberCategory(_ value: String, in state: inout LibraryState) throws -> String {
        let normalized = try normalizeCategory(value)
        let known = Self.builtInCategories + state.customCategories + state.materials.map(\.category)
        let name = known.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? normalized
        if !Self.builtInCategories.contains(name), !state.customCategories.contains(name) { state.customCategories.append(name) }
        return name
    }
}

extension LibraryRepository {
    public func homeworkURL(courseID: UUID?) throws -> URL {
        try withLock {
            try ensureCourse(courseID)
            if let courseID, let mount = snapshot.courses.first(where: { $0.id == courseID })?.homeworkFolder {
                let url = URL(fileURLWithPath: mount).standardizedFileURL
                try ensureDirectory(url)
                return url
            }
            let url = root.appendingPathComponent("HomeworkFiles", isDirectory: true).appendingPathComponent(courseID?.uuidString ?? "Unassigned", isDirectory: true)
            try ensureSafePath(url, beneath: root)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    public func mountHomework(courseID: UUID, url: URL?) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == courseID }) else { throw LibraryError.missingRecord("课程") }
            if let url {
                try validateMount(url.standardizedFileURL, for: courseID, in: state)
                state.courses[index].homeworkFolder = url.standardizedFileURL.path
            } else { state.courses[index].homeworkFolder = nil }
        }
    }

    public func listHomework(courseID: UUID?, relativePath: String) throws -> [WorkspaceEntry] {
        try withLock {
            let folder = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(folder)
            return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]).compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else { return nil }
                return WorkspaceEntry(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public func importHomework(urls: [URL], courseID: UUID?, relativePath: String) throws -> ImportSummary {
        try withLock {
            let folder = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(folder)
            var summary = ImportSummary()
            for source in urls {
                var target: URL?
                do {
                    let source = source.standardizedFileURL
                    try ensureSafePath(source, beneath: nil)
                    // A directory cannot be copied into itself or one of its descendants.
                    guard !isBeneath(folder, root: source) else { throw LibraryError.invalidInput("不能将文件夹导入到自身内部。") }
                    let destination = uniqueURL(in: folder, name: source.lastPathComponent)
                    target = destination
                    try copyTree(source, to: destination)
                    summary.imported += 1
                } catch {
                    if let target { try? fm.removeItem(at: target) }
                    summary.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)"); summary.skipped += 1
                }
            }
            return summary
        }
    }

    /// Creates a real folder in the workspace, also used by the native New Folder action.
    @discardableResult public func createHomeworkFolder(name: String, courseID: UUID?, relativePath: String) throws -> URL {
        try withLock {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw LibraryError.invalidInput("请输入有效的文件夹名称。") }
            let parent = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(parent)
            let destination = uniqueURL(in: parent, name: name)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            return destination
        }
    }

    private func workspaceFolder(courseID: UUID?, relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."), !relativePath.contains("\0") else { throw LibraryError.unsafePath(relativePath) }
        let base = try homeworkURL(courseID: courseID)
        let folder = relativePath.isEmpty ? base : base.appendingPathComponent(relativePath).standardizedFileURL
        try ensureSafePath(folder, beneath: base)
        return folder
    }

    private func validateMount(_ url: URL, for courseID: UUID, in state: LibraryState) throws {
        try ensureDirectory(url)
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let libraryRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard !isBeneath(candidate, root: libraryRoot), !isBeneath(libraryRoot, root: candidate) else { throw LibraryError.invalidInput("挂载的作业文件夹必须位于资料库外部，且不能包含资料库。") }
        for other in state.courses where other.id != courseID {
            guard let path = other.homeworkFolder else { continue }
            // Disconnected mounts still reserve their stored path; no existence check.
            let mounted = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard !isBeneath(candidate, root: mounted), !isBeneath(mounted, root: candidate) else { throw LibraryError.invalidInput("该文件夹与课程“\(other.name)”的作业文件夹重叠，请选择独立文件夹。") }
        }
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        let initial = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: initial.path) { return initial }
        let file = URL(fileURLWithPath: name)
        let suffix = file.pathExtension
        let base = suffix.isEmpty ? name : file.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Copy a tree explicitly, refusing links instead of allowing Foundation to copy links.
    private func copyTree(_ source: URL, to target: URL) throws {
        try rejectSymbolicLink(source)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, to: target.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true { try fm.copyItem(at: source, to: target) }
        else { throw LibraryError.unsafePath(source.path) }
    }

    /// A backup is a macOS directory package. It includes orphan files left by
    /// record deletion, all internal homework folders, and previous restore history.
    public func backup(to destination: URL) throws {
        try withLock {
            try prepareDestination(destination)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-backup-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try Self.encoder.encode(snapshot).write(to: staging.appendingPathComponent("library.json"), options: .withoutOverwriting)
            for name in ["files", "HomeworkFiles", "History"] {
                let source = root.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) { try copyTree(source, to: staging.appendingPathComponent(name)) }
            }
            let marker = Data("{\"format\":\"Teachshelf macOS backup\",\"version\":1}".utf8)
            try marker.write(to: staging.appendingPathComponent("backup.json"))
            try fm.moveItem(at: staging, to: destination)
        }
    }

    public func restore(from source: URL) throws {
        try withLock {
            let source = source.standardizedFileURL
            try ensureDirectory(source)
            guard !isBeneath(source, root: root), !isBeneath(root, root: source) else { throw LibraryError.invalidInput("请选择当前资料库以外的备份。") }
            let sourceIndex = source.appendingPathComponent("library.json")
            try ensureSafePath(sourceIndex, beneath: source)
            var restored: LibraryState
            do { restored = try Self.decode(Data(contentsOf: sourceIndex)); try validate(restored) }
            catch { throw LibraryError.invalidLibrary(error.localizedDescription) }
            let staging = root.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for name in ["files", "HomeworkFiles"] {
                let from = source.appendingPathComponent(name), to = staging.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) { try copyTree(from, to: to) }
                else { try fm.createDirectory(at: to, withIntermediateDirectories: false) }
            }
            // Managed paths are relative, so no old-machine absolute paths survive migration.
            for index in restored.materials.indices where restored.materials[index].isManaged {
                let relative = restored.materials[index].storedPath
                let file = staging.appendingPathComponent(relative)
                try ensureSafePath(file, beneath: staging)
                guard fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.invalidLibrary("备份缺少文件：\(restored.materials[index].originalName)") }
            }
            // Historical files from the backup remain recoverable without replacing local history.
            let sourceHistory = source.appendingPathComponent("History")
            if fm.fileExists(atPath: sourceHistory.path) { try copyTree(sourceHistory, to: staging.appendingPathComponent("BackupHistory")) }
            let history = root.appendingPathComponent("History", isDirectory: true).appendingPathComponent("Restore-\(UUID().uuidString)", isDirectory: true)
            try ensureSafePath(history, beneath: root)
            try fm.createDirectory(at: history, withIntermediateDirectories: true)
            try Self.encoder.encode(snapshot).write(to: history.appendingPathComponent("library.json"), options: .withoutOverwriting)
            var movedOld: [String] = [], installed: [String] = []
            do {
                for name in ["files", "HomeworkFiles"] {
                    let current = root.appendingPathComponent(name)
                    if fm.fileExists(atPath: current.path) {
                        try rejectSymbolicLink(current)
                        try fm.moveItem(at: current, to: history.appendingPathComponent(name)); movedOld.append(name)
                    }
                    try fm.moveItem(at: staging.appendingPathComponent(name), to: current); installed.append(name)
                }
                let backupHistory = staging.appendingPathComponent("BackupHistory")
                if fm.fileExists(atPath: backupHistory.path) { try fm.moveItem(at: backupHistory, to: history.appendingPathComponent("BackupHistory")) }
                try persist(restored)
                snapshot = restored
                deletedTaskBatches.removeAll()
            } catch {
                var rollbackFailed = false
                for name in installed.reversed() {
                    do { try fm.removeItem(at: root.appendingPathComponent(name)) } catch { rollbackFailed = true }
                }
                for name in movedOld.reversed() {
                    do { try fm.moveItem(at: history.appendingPathComponent(name), to: root.appendingPathComponent(name)) } catch { rollbackFailed = true }
                }
                if rollbackFailed {
                    // Never delete the recovery copy if an OS error prevents rollback.
                    throw LibraryError.invalidInput("恢复未完成。原文件保留在 \(history.path)。\(error.localizedDescription)")
                }
                try? fm.removeItem(at: history)
                throw error
            }
        }
    }

    /// Copies the entire library, preserving the source and excluding its writer lock.
    public func copyLibrary(to destination: URL) throws {
        try withLock {
            let destination = destination.standardizedFileURL
            let replacingEmptyDirectory = try prepareDestination(destination, allowEmptyDirectory: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-migrate-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if child.lastPathComponent == ".teachshelf.lock" || child.lastPathComponent.hasPrefix(".restore-") || child.lastPathComponent.hasPrefix(".index-") || child.lastPathComponent.hasPrefix(".backup-") { continue }
                try copyTree(child, to: staging.appendingPathComponent(child.lastPathComponent))
            }
            // Decode and validate the copied index before exposing the destination.
            let copied = try Self.decode(Data(contentsOf: staging.appendingPathComponent("library.json")))
            try validate(copied)
            if replacingEmptyDirectory {
                try ensureDirectory(destination)
                // rmdir is atomic and fails if anything was added after the empty check.
                guard Darwin.rmdir(destination.path) == 0 else {
                    throw LibraryError.invalidInput("目标文件夹已包含文件，请重新选择一个空文件夹。")
                }
            }
            // RENAME_EXCL refuses replacement even if a destination appears concurrently.
            if Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                if replacingEmptyDirectory, !fm.fileExists(atPath: destination.path) { try? fm.createDirectory(at: destination, withIntermediateDirectories: false) }
                throw error
            }
        }
    }

    @discardableResult private func prepareDestination(_ destination: URL, allowEmptyDirectory: Bool = false) throws -> Bool {
        let destination = destination.standardizedFileURL
        guard !isBeneath(destination, root: root), !isBeneath(root, root: destination) else { throw LibraryError.invalidInput("目标文件夹不能位于当前资料库内部。") }
        try ensureSafePath(destination, beneath: nil)
        if fm.fileExists(atPath: destination.path) {
            guard allowEmptyDirectory else { throw LibraryError.invalidInput("目标已存在，请选择新的文件夹名称。") }
            try ensureDirectory(destination)
            guard try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty else { throw LibraryError.invalidInput("请选择一个空文件夹，已有文件将保留。") }
            return true
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return false
    }
}
