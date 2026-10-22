import Foundation
import Darwin

extension LibraryRepository {
    private static func validateTeachingConnections(_ state: LibraryState) throws {
        guard Set(state.teachingConnections.map(\.id)).count == state.teachingConnections.count,
              state.teachingConnections.count <= 500 else { throw LibraryError.invalidInput("教学网站连接数量异常或包含重复编号。") }
        var identities = Set<String>()
        for connection in state.teachingConnections {
            guard state.courses.contains(where: { $0.id == connection.courseID }),
                  !connection.remoteCourseID.isEmpty, connection.remoteCourseID.count <= 16,
                  connection.remoteCourseID.allSatisfy(\.isNumber),
                  !connection.accountID.isEmpty, connection.accountID.count <= 64, connection.accountID.allSatisfy(\.isNumber),
                  !connection.remoteTitle.isEmpty, connection.remoteTitle.count <= 1000,
                  TimeZone(identifier: connection.timeZone) != nil,
                  connection.items.count <= 50_000, connection.folders.count <= 10_000,
                  connection.messages.count <= 300,
                  Set(connection.items.map(\.id)).count == connection.items.count,
                  Set(connection.folders.map(\.key)).count == connection.folders.count,
                  identities.insert("\(connection.accountID):\(connection.remoteCourseID)").inserted else {
                throw LibraryError.invalidInput("教学网站连接无效，或同一网站课程已连接。")
            }
        }
    }

    /// Reuses an existing source binding without resetting its options or synchronization history.
    public func connectTeachingCourse(_ value: TeachingConnection) throws -> TeachingConnection {
        try withLock {
            if let existing = snapshot.teachingConnections.first(where: {
                $0.accountID == value.accountID && $0.remoteCourseID == value.remoteCourseID
            }) {
                guard existing.courseID == value.courseID else {
                    let name = snapshot.courses.first { $0.id == existing.courseID }?.name ?? "其他课程"
                    throw LibraryError.invalidInput("该网站课程已绑定至「\(name)」，请打开已有连接。")
                }
                return existing
            }
            try saveTeachingConnection(value)
            return value
        }
    }

    public func saveTeachingConnection(_ value: TeachingConnection) throws {
        try commit { state in
            var value = value
            if let index = state.teachingConnections.firstIndex(where: { $0.id == value.id }) {
                let old = state.teachingConnections[index]
                guard old.courseID == value.courseID, old.remoteCourseID == value.remoteCourseID, old.accountID == value.accountID else {
                    throw LibraryError.invalidInput("请断开旧连接后重新绑定课程或账号。")
                }
                value.items = old.items; value.folders = old.folders; value.messages = old.messages; value.lastSyncAt = old.lastSyncAt
                state.teachingConnections[index] = value
            } else { state.teachingConnections.append(value) }
            state.schemaVersion = 7
        }
    }

    public func disconnectTeachingWebsite(_ id: UUID) throws {
        try commit { $0.teachingConnections.removeAll { $0.id == id } }
    }

    public func finishTeachingUpdate(_ id: UUID, messages: [TeachingSyncMessage], completed: Bool) throws {
        try commit { state in
            guard let i = state.teachingConnections.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("网站连接") }
            state.teachingConnections[i].messages = Array(messages.suffix(300))
            if completed { state.teachingConnections[i].lastSyncAt = Date() }
        }
    }

    public func restoreIgnoredTeachingItems(_ id: UUID) throws {
        try commit { state in
            guard let i = state.teachingConnections.firstIndex(where: { $0.id == id }) else { return }
            let materialIDs = Set(state.materials.map(\.id)), taskIDs = Set(state.tasks.map(\.id))
            state.teachingConnections[i].items.removeAll { link in
                link.ignored || (link.id.hasPrefix("file:") ? !materialIDs.contains(link.localID ?? UUID()) : !taskIDs.contains(link.localID ?? UUID()))
            }
        }
    }

    public func resolveTeachingDeadline(connectionID: UUID, key: String, useWebsite: Bool) throws {
        try commit { state in
            guard let c = state.teachingConnections.firstIndex(where: { $0.id == connectionID }),
                  let i = state.teachingConnections[c].items.firstIndex(where: { $0.id == key }),
                  let pending = state.teachingConnections[c].items[i].pendingDeadline,
                  let t = state.tasks.firstIndex(where: { $0.id == state.teachingConnections[c].items[i].localID }),
                  !state.tasks[t].isArchived else { throw LibraryError.invalidInput("该截止时间变更已失效，或计划已归档。") }
            if useWebsite {
                state.tasks[t].deadline = pending.date; state.tasks[t].deadlineIsAllDay = pending.allDay
                state.teachingConnections[c].items[i].appliedDeadline = pending.date
                state.teachingConnections[c].items[i].appliedDeadlineIsAllDay = pending.allDay
            }
            state.teachingConnections[c].items[i].pendingDeadline = nil
        }
    }

    /// Downloaded bytes and their source identity commit together. Prior versions stay in the library.
    public func teachingFileState(connectionID: UUID, activity: TeachingActivity, file: TeachingFile) throws -> TeachingFileState {
        try withLock {
            guard let connection = snapshot.teachingConnections.first(where: { $0.id == connectionID }) else { throw LibraryError.missingRecord("课程连接") }
            guard let link = connection.items.first(where: { $0.id == "file:\(activity.key):\(file.key)" }) else { return .new }
            guard !link.ignored, let material = snapshot.materials.first(where: { $0.id == link.localID }), material.courseID == connection.courseID else { return .ignored }
            guard let url = try? resolveURL(material), fm.isReadableFile(atPath: url.path) else { return .missing }
            return .existing
        }
    }

    /// Runs exactly the same merge as confirmation, against a disposable snapshot.
    public func previewTeachingAssignment(connectionID: UUID, activity: TeachingActivity, page: TeachingPage, now: Date = Date()) throws -> TeachingAssignmentChange? {
        try withLock {
            var state = snapshot, message = ""
            let oldLink = state.teachingConnections.first { $0.id == connectionID }?.items.first { $0.id == "plan:\(activity.id)" }
            let before = state.tasks.first { $0.id == oldLink?.localID }
            try Self.mergeTeachingAssignment(state: &state, connectionID: connectionID, activity: activity, page: page, now: now, message: &message)
            guard let connection = state.teachingConnections.first(where: { $0.id == connectionID }),
                  let link = connection.items.first(where: { $0.id == "plan:\(activity.id)" }), !link.ignored,
                  let task = state.tasks.first(where: { $0.id == link.localID && $0.courseID == connection.courseID }), !task.isArchived,
                  task != before || link.pendingDeadline != nil else { return nil }
            return TeachingAssignmentChange(before: before, proposed: task, pendingDeadline: link.pendingDeadline, message: message)
        }
    }

    public func syncTeachingFile(connectionID: UUID, activity: TeachingActivity, file: TeachingFile, downloadedURL: URL) throws -> String {
        guard TeachingWebsite.isDownload(file.url), TeachingWebsite.identifier(activity.url) == activity.id,
              ["folder", "resource", "assign"].contains(activity.kind), !file.name.isEmpty,
              file.name == URL(fileURLWithPath: file.name).lastPathComponent, !file.name.contains("\\"), !file.name.contains("\0") else {
            throw LibraryError.invalidInput("网站文件名或下载地址无效。")
        }
        try TeachingWebsite.validateFile(downloadedURL, name: file.name)
        let digest = try TeachingWebsite.digest(downloadedURL)
        return try withLock {
            var state = snapshot
            guard let c = state.teachingConnections.firstIndex(where: { $0.id == connectionID }),
                  let course = state.courses.first(where: { $0.id == state.teachingConnections[c].courseID }), !course.isArchived else {
                throw LibraryError.invalidInput("课程连接已移除或课程已归档。")
            }
            var connection = state.teachingConnections[c]
            let key = "file:\(activity.key):\(file.key)"
            let previous = connection.items.first { $0.id == key }
            let old = state.materials.first { $0.id == previous?.localID }
            if let previous, previous.ignored || old == nil || old?.courseID != course.id {
                if let i = connection.items.firstIndex(where: { $0.id == key }) { connection.items[i].ignored = true }
                state.teachingConnections[c] = connection; try saveSnapshot(state)
                return "忽略 · \(file.name)（已在本地移除或转移）"
            }
            if let old, previous?.digest == digest, let currentURL = try? resolveURL(old),
               (try? TeachingWebsite.digest(currentURL)) == digest { return "未变 · \(file.name)" }
            var path: [(String, String)] = [("root", "教学网站"), ("section:\(activity.sectionID)", activity.section)]
            if activity.kind == "folder" || activity.kind == "assign" { path.append((activity.key, activity.title)) }
            for (i, name) in file.subfolders.enumerated() { path.append(("\(activity.key)/" + file.subfolders.prefix(i + 1).joined(separator: "/"), name)) }
            let sourceFolder = Self.teachingFolder(path, courseID: course.id, connection: &connection, state: &state)
            let folder = old != nil && old?.folderID != previous?.folderID ? old?.folderID : sourceFolder
            let id = UUID()
            let category = activity.kind == "assign" ? (activity.isExperiment ? "实验资料" : "作业附件") : "课件"
            let normalized = try rememberCategory(category, in: &state)
            var material = MaterialRecord(id: id, courseID: course.id,
                title: old != nil && old?.title != previous?.title ? old!.title : URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent,
                originalName: file.name, sourcePath: "teaching://\(connection.id.uuidString)/\(key)", storedPath: "", isManaged: true, category: normalized)
            material.folderID = folder; material.size = Int64(try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            material.storedPath = MaterialStorageLayout.relativePath(for: material, courses: state.courses)
            material.customOrder = (state.materials.filter { $0.courseID == course.id && $0.folderID == folder }.compactMap(\.customOrder).max() ?? -1) + 1
            if let old {
                material.tags = old.tags; material.notes = old.notes; material.isFavorite = old.isFavorite
                if old.folderID == folder { material.customOrder = old.customOrder }
                if old.category != category { material.category = old.category }
                let history = Self.teachingFolder([("root", "教学网站"), ("history", "历史版本")], courseID: course.id, connection: &connection, state: &state)
                if let i = state.materials.firstIndex(where: { $0.id == old.id }) { state.materials[i].folderID = history }
                for i in state.tasks.indices where !state.tasks[i].isArchived {
                    state.tasks[i].materialIDs = state.tasks[i].materialIDs.map { $0 == old.id ? id : $0 }
                    for e in state.tasks[i].exceptions.indices {
                        if var details = state.tasks[i].exceptions[e].details {
                            details.materialIDs = details.materialIDs.map { $0 == old.id ? id : $0 }; state.tasks[i].exceptions[e].details = details
                        }
                    }
                }
            }
            let target = root.appendingPathComponent(material.storedPath)
            try ensureSafePath(target, beneath: filesURL)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: downloadedURL, to: target)
            var link = TeachingItemLink(id: key, localID: id, title: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent)
            link.digest = digest; link.folderID = sourceFolder
            connection.items.removeAll { $0.id == key }; connection.items.append(link)
            state.materials.append(material); state.teachingConnections[c] = connection
            do { try saveSnapshot(state) }
            catch { try? fm.removeItem(at: target); throw error }
            return "\(old == nil ? "新增" : "更新") · \(file.name)\(old == nil ? "" : "（旧版已保留）")"
        }
    }

    public func syncTeachingAssignment(connectionID: UUID, activity: TeachingActivity, page: TeachingPage, now: Date = Date()) throws -> String {
        guard activity.kind == "assign", TeachingWebsite.isPage(activity.url) else { throw LibraryError.invalidInput("不是可读取的作业页面。") }
        var message = ""
        try commit { state in
            try Self.mergeTeachingAssignment(state: &state, connectionID: connectionID, activity: activity, page: page, now: now, message: &message)
        }
        return message
    }

    private static func mergeTeachingAssignment(state: inout LibraryState, connectionID: UUID, activity: TeachingActivity, page: TeachingPage, now: Date, message: inout String) throws {
        guard activity.kind == "assign", TeachingWebsite.isPage(activity.url) else { throw LibraryError.invalidInput("不是可读取的作业页面。") }
        guard let c = state.teachingConnections.firstIndex(where: { $0.id == connectionID }),
              let course = state.courses.first(where: { $0.id == state.teachingConnections[c].courseID }), !course.isArchived else { throw LibraryError.missingRecord("课程连接") }
        var connection = state.teachingConnections[c]
        guard page.accountID == connection.accountID, page.courseID == connection.remoteCourseID else { throw LibraryError.invalidInput("网站账号或课程已变化，请重新连接。") }
        let key = "plan:\(activity.id)", parsed = TeachingWebsite.deadline(page.deadlineText, timeZone: connection.timeZone)
        let unclear = !page.deadlineText.isEmpty && parsed.date == nil
        let previous = connection.items.first { $0.id == key }
        let index = state.tasks.firstIndex { $0.id == previous?.localID }
        if let previous, previous.ignored || index == nil || index.map({ state.tasks[$0].courseID != course.id }) == true {
            if let i = connection.items.firstIndex(where: { $0.id == key }) { connection.items[i].ignored = true }
            state.teachingConnections[c] = connection; message = "忽略 · \(activity.title)（已在本地移除或转移）"; return
        }
        if previous == nil, !connection.includeHistory, page.submitted || (parsed.date.map { $0 < now } ?? false) {
            message = "跳过历史 · \(activity.title)"; return
        }
        if let index, state.tasks[index].isArchived { message = "保留归档 · \(activity.title)"; return }
        let content = String(page.intro.prefix(80_000)) + "\n\n教学网站：\(activity.url.absoluteString)"
        var task = index.map { state.tasks[$0] } ?? StudyTask(title: activity.title, kind: activity.isExperiment ? "实验" : "作业", courseID: course.id, origin: .fixed, hasExecutionTime: false)
        let before = task
        if previous == nil || task.title == previous?.title { task.title = activity.title }
        if previous == nil || task.content == previous?.content { task.content = content }
        task.courseNameSnapshot = course.name
        let attachments = connection.items.filter { $0.id.hasPrefix("file:\(activity.key):") && !$0.ignored }.compactMap(\.localID).filter { id in state.materials.contains { $0.id == id && $0.courseID == course.id } }
        task.materialIDs = Array(Set(task.materialIDs + attachments)).sorted { $0.uuidString < $1.uuidString }
        var link = previous ?? TeachingItemLink(id: key, localID: task.id, title: activity.title)
        if !unclear, previous == nil || link.remoteDeadline != parsed.date || link.remoteDeadlineIsAllDay != parsed.allDay {
            if previous == nil || (task.deadline == link.appliedDeadline && task.deadlineIsAllDay == (link.appliedDeadlineIsAllDay ?? task.deadlineIsAllDay) && task.repeatRule == nil) {
                task.deadline = parsed.date; task.deadlineIsAllDay = parsed.allDay
                link.appliedDeadline = parsed.date; link.appliedDeadlineIsAllDay = parsed.allDay; link.pendingDeadline = nil
            } else { link.pendingDeadline = TeachingDeadlineChange(date: parsed.date, allDay: parsed.allDay, text: page.deadlineText) }
            link.remoteDeadline = parsed.date
            link.remoteDeadlineIsAllDay = parsed.allDay
        }
        if previous == nil, page.submitted { task.completedAt = now }
        link.title = activity.title; link.content = content; link.submitted = page.submitted
        if let index { state.tasks[index] = task } else { state.tasks.append(task) }
        connection.items.removeAll { $0.id == key }; connection.items.append(link); state.teachingConnections[c] = connection
        message = "\(index == nil ? "新增计划" : (task == before ? "未变" : "更新计划")) · \(activity.title)"
        if unclear { message += " · 截止时间待核对：\(page.deadlineText)" }
        if link.pendingDeadline != nil { message += " · 截止时间冲突待处理" }
    }


    private static func teachingFolder(_ path: [(String, String)], courseID: UUID, connection: inout TeachingConnection, state: inout LibraryState) -> UUID? {
        var parent: UUID?
        for (key, raw) in path {
            if let link = connection.folders.first(where: { $0.key == key }) {
                if let folder = state.materialFolders.first(where: { $0.id == link.localID && $0.courseID == courseID }) { parent = folder.id }
                continue // A folder dissolved by the user is not silently recreated.
            }
            let name = MaterialStorageLayout.component(raw, byteLimit: 100)
            func folded(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            let siblings = state.materialFolders.filter { $0.courseID == courseID && $0.parentID == parent }
            let claimed = Set((state.teachingConnections.flatMap(\.folders) + connection.folders).filter {
                $0.key != "root" && $0.key != "history" && !$0.key.hasPrefix("section:")
            }.compactMap(\.localID))
            let shared = key == "root" || key == "history" || key.hasPrefix("section:")
            let existing = siblings.first { folded($0.name) == folded(name) && (shared || !claimed.contains($0.id)) }
            var uniqueName = name, suffix = 2
            while existing == nil && siblings.contains(where: { folded($0.name) == folded(uniqueName) }) {
                uniqueName = "\(name) (\(suffix))"; suffix += 1
            }
            let folder = existing ?? MaterialFolder(courseID: courseID, parentID: parent, name: uniqueName)
            if existing == nil { state.materialFolders.append(folder) }
            parent = folder.id; connection.folders.append(TeachingFolderLink(key: key, localID: folder.id))
        }
        return parent
    }
}

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
    private var relocationURL: URL { root.appendingPathComponent(".material-relocation.json") }
    private struct MaterialRelocation: Codable {
        var source: String
        var destination: String
        var temporary: String?
        var homework: Bool?
        var directory: Bool?
        var retainDestination: Bool?
    }
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
        var state = try decoder.decode(LibraryState.self, from: data)
        // Older builds cannot preserve material folders, sorting, or plan attributes.
        // Upgrade the in-memory snapshot on read; the next successful mutation or
        // storage migration writes version 6, which those builds refuse to open.
        if (1...5).contains(state.schemaVersion) { state.schemaVersion = 6 }
        return state
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
            try recoverMaterialRelocation()
            // Keep schema-only upgrades lazy while organizing both materials and homework.
            try saveSnapshot(snapshot, storageOnly: true)
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
            try saveSnapshot(next)
        }
    }

    private func organizedMaterials(_ state: LibraryState) throws -> LibraryState {
        var next = state
        for index in next.materials.indices where next.materials[index].isManaged {
            let material = next.materials[index]
            let destination = MaterialStorageLayout.relativePath(for: material, courses: next.courses)
            guard material.storedPath != destination else { continue }
            let source = try fileURL(for: material)
            try ensureSafePath(source, beneath: filesURL)
            // Missing files remain visible and can still be removed from the library.
            guard fm.fileExists(atPath: source.path) else { continue }
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryError.unsafePath(source.path)
            }
            next.materials[index].storedPath = destination
        }
        return next
    }

    /// Keep both paths valid until the index commits. A small journal allows the
    /// next launch to finish cleanup after termination on either side of the commit.
    private func saveSnapshot(_ state: LibraryState, storageOnly: Bool = false) throws {
        try recoverMaterialRelocation()
        try validate(state)
        let next = try organizedMaterials(state)
        try validate(next)
        var relocations = zip(state.materials, next.materials).compactMap { before, after -> MaterialRelocation? in
            guard before.isManaged, before.storedPath != after.storedPath else { return nil }
            return MaterialRelocation(source: before.storedPath, destination: after.storedPath,
                                      temporary: "files/.material-copy-\(UUID().uuidString)")
        }
        relocations += try homeworkRelocations(in: next)
        if relocations.isEmpty {
            if !storageOnly { try persist(next) }
            snapshot = next
            return
        }
        try ensureSafePath(relocationURL, beneath: root)
        try Self.encoder.encode(relocations).write(to: relocationURL, options: .atomic)
        do {
            for relocation in relocations {
                let source = try relocationFile(relocation.source)
                let destination = try relocationFile(relocation.destination)
                if relocation.directory == true {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    // A previous attempt may have stopped after preparing this path.
                    guard sameMaterialContents(source, destination) else {
                        throw LibraryError.invalidInput("课程资料目录中已有不同内容的同名文件：\(destination.lastPathComponent)")
                    }
                } else {
                    // Links keep large course-file moves cheap on the same volume.
                    // Volumes without hard-link support use a regular copy instead.
                    do { try fm.linkItem(at: source, to: destination) }
                    catch {
                        let temporary = try relocationFile(relocation.temporary!)
                        try fm.copyItem(at: source, to: temporary)
                        let handle = try FileHandle(forWritingTo: temporary)
                        try handle.synchronize(); try handle.close()
                        guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                }
            }
            if !storageOnly || next != snapshot { try persist(next) }
            snapshot = next
        } catch {
            try? recoverMaterialRelocation(rollingBack: true)
            throw error
        }
        // The committed index is authoritative even if cleanup must wait for reopening.
        try? recoverMaterialRelocation()
    }

    private func relocationFile(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."),
              path.hasPrefix("files/") || path.hasPrefix("HomeworkFiles/") else { throw LibraryError.unsafePath(path) }
        let url = root.appendingPathComponent(path).standardizedFileURL
        try ensureSafePath(url, beneath: root)
        return url
    }

    private func recoverMaterialRelocation(rollingBack: Bool = false) throws {
        try ensureSafePath(relocationURL, beneath: root)
        guard fm.fileExists(atPath: relocationURL.path) else { return }
        let relocations = try JSONDecoder().decode([MaterialRelocation].self, from: Data(contentsOf: relocationURL))
        let referenced = Set(snapshot.materials.filter(\.isManaged).map(\.storedPath))
        let homeworkRoots = ([MaterialStorageLayout.homeworkPath(for: nil)] + snapshot.courses.map { MaterialStorageLayout.homeworkPath(for: $0) })
        func isReferenced(_ path: String, homework: Bool) -> Bool {
            homework ? homeworkRoots.contains { path == $0 || path.hasPrefix($0 + "/") } : referenced.contains(path)
        }
        // Children are cleaned before their parent directories.
        for relocation in relocations.reversed() {
            let source = try relocationFile(relocation.source), destination = try relocationFile(relocation.destination)
            if let path = relocation.temporary {
                let prefix = "files/.material-copy-"
                guard path.hasPrefix(prefix), UUID(uuidString: String(path.dropFirst(prefix.count))) != nil else {
                    throw LibraryError.invalidLibrary("资料整理日志包含无效的临时文件路径。")
                }
                let temporary = try relocationFile(path)
                if !referenced.contains(path), fm.fileExists(atPath: temporary.path),
                   try temporary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    try fm.removeItem(at: temporary)
                }
            }
            let discard: URL, keep: URL
            if rollingBack {
                guard relocation.retainDestination != true,
                      relocation.homework == true || !referenced.contains(relocation.destination) else { continue }
                discard = destination; keep = source
            } else if isReferenced(relocation.destination, homework: relocation.homework == true),
                      !isReferenced(relocation.source, homework: relocation.homework == true) {
                discard = source; keep = destination
            } else if isReferenced(relocation.source, homework: relocation.homework == true),
                      !isReferenced(relocation.destination, homework: relocation.homework == true) {
                guard relocation.retainDestination != true else { continue }
                discard = destination; keep = source
            } else { continue }
            if relocation.directory == true {
                if fm.fileExists(atPath: keep.path) { _ = Darwin.rmdir(discard.path) }
                removeEmptyMaterialDirectories(from: discard.deletingLastPathComponent())
                continue
            }
            // Never remove the last surviving copy or overwrite an unrelated collision.
            if fm.fileExists(atPath: discard.path), fm.fileExists(atPath: keep.path),
               sameMaterialContents(discard, keep) {
                try fm.removeItem(at: discard)
            }
            removeEmptyMaterialDirectories(from: discard.deletingLastPathComponent())
        }
        try fm.removeItem(at: relocationURL)
        _ = Darwin.rmdir(root.appendingPathComponent("HomeworkFiles").path)
    }

    private func sameMaterialContents(_ first: URL, _ second: URL) -> Bool {
        var a = stat(), b = stat()
        guard lstat(first.path, &a) == 0, lstat(second.path, &b) == 0,
              a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG else { return false }
        return (a.st_dev == b.st_dev && a.st_ino == b.st_ino) || fm.contentsEqual(atPath: first.path, andPath: second.path)
    }

    private func removeEmptyMaterialDirectories(from directory: URL) {
        var cursor = directory
        let legacy = root.appendingPathComponent("HomeworkFiles")
        let boundary = isBeneath(cursor, root: filesURL) ? filesURL : legacy
        while cursor.path != boundary.path && isBeneath(cursor, root: boundary) {
            // rmdir only removes an empty directory; retained records/files are untouched.
            guard Darwin.rmdir(cursor.path) == 0 else { break }
            cursor.deleteLastPathComponent()
        }
    }

    private func homeworkRelocations(in state: LibraryState) throws -> [MaterialRelocation] {
        var result: [MaterialRelocation] = []
        var planned: [String: URL] = [:]
        let courseFolders = try fm.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil).map(\.standardizedFileURL)
        func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)) }
        func visit(_ source: URL, to proposed: URL) throws {
            try ensureSafePath(source, beneath: root)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let directory = values.isDirectory == true
            guard directory || values.isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
            var target = proposed
            let name = proposed.deletingPathExtension().lastPathComponent, suffix = proposed.pathExtension
            var number = 2
            while true {
                try ensureSafePath(target, beneath: root)
                let existing = planned[target.path] ?? (fm.fileExists(atPath: target.path) ? target : nil)
                guard let existing else { break }
                let isDirectory = try existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if (directory && isDirectory) || (!directory && !isDirectory && sameMaterialContents(source, existing)) { break }
                target = proposed.deletingLastPathComponent().appendingPathComponent("\(name) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
                number += 1
            }
            let retained = fm.fileExists(atPath: target.path) || planned[target.path] != nil
            planned[target.path] = source
            result.append(MaterialRelocation(source: relative(source), destination: relative(target),
                                             temporary: directory ? nil : "files/.material-copy-\(UUID().uuidString)",
                                             homework: true, directory: directory, retainDestination: retained))
            if directory {
                for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                    try visit(child.standardizedFileURL, to: target.appendingPathComponent(child.lastPathComponent))
                }
            }
        }
        for course in state.courses.map(Optional.some) + [nil] {
            let target = root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course))
            var sources = [root.appendingPathComponent("HomeworkFiles/\(course?.id.uuidString ?? "Unassigned")")]
            if let course {
                sources += courseFolders.filter { $0.lastPathComponent.hasSuffix(" [\(course.id.uuidString)]") }.map { $0.appendingPathComponent("作业") }
            }
            for source in sources where source.path != target.path && fm.fileExists(atPath: source.path) {
                try ensureSafePath(target, beneath: root)
                if fm.fileExists(atPath: target.path),
                   try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                    throw LibraryError.invalidInput("课程目录中的“作业”已被文件占用，请先移走该文件：\(target.path)")
                }
                try visit(source, to: target)
            }
        }
        return result
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
            for index in state.tasks.indices where !state.tasks[index].isArchived {
                for e in state.tasks[index].exceptions.indices where state.tasks[index].exceptions[e].details?.courseID == course.id {
                    state.tasks[index].exceptions[e].details?.courseNameSnapshot = course.name
                }
            }
        }
    }

    public func deleteCourse(id: UUID) throws {
        try commit { state in
            guard let course = state.courses.first(where: { $0.id == id }) else { throw LibraryError.missingRecord("课程") }
            state.courses.removeAll { $0.id == id }
            state.teachingConnections.removeAll { $0.courseID == id }
            state.materialFolders.removeAll { $0.courseID == id }
            for index in state.materials.indices where state.materials[index].courseID == id {
                state.materials[index].folderID = nil; state.materials[index].customOrder = nil
            }
            for index in state.materials.indices where state.materials[index].courseID == id { state.materials[index].courseID = nil }
            for index in state.tasks.indices where state.tasks[index].courseID == id {
                state.tasks[index].courseID = nil
                if !state.tasks[index].isArchived || state.tasks[index].courseNameSnapshot == nil { state.tasks[index].courseNameSnapshot = course.name }
            }
            for index in state.tasks.indices {
                for e in state.tasks[index].exceptions.indices where state.tasks[index].exceptions[e].details?.courseID == id {
                    state.tasks[index].exceptions[e].details?.courseID = nil
                    if !state.tasks[index].isArchived || state.tasks[index].exceptions[e].details?.courseNameSnapshot == nil {
                        state.tasks[index].exceptions[e].details?.courseNameSnapshot = course.name
                    }
                }
            }
            for termIndex in state.timetableTerms.indices {
                for meetingIndex in state.timetableTerms[termIndex].meetings.indices where state.timetableTerms[termIndex].meetings[meetingIndex].courseID == id {
                    state.timetableTerms[termIndex].meetings[meetingIndex].courseID = nil
                }
                for index in state.timetableTerms[termIndex].reschedules.indices where state.timetableTerms[termIndex].reschedules[index].meeting.courseID == id {
                    state.timetableTerms[termIndex].reschedules[index].meeting.courseID = nil
                }
                for index in state.timetableTerms[termIndex].cancellations.indices where state.timetableTerms[termIndex].cancellations[index].savedReschedule?.meeting.courseID == id {
                    state.timetableTerms[termIndex].cancellations[index].savedReschedule?.meeting.courseID = nil
                }
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
            if material.courseID != existing.courseID { material.folderID = nil; material.customOrder = nil }
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
            for index in state.tasks.indices {
                state.tasks[index].materialIDs.removeAll { ids.contains($0) }
                for e in state.tasks[index].exceptions.indices {
                    state.tasks[index].exceptions[e].details?.materialIDs.removeAll { ids.contains($0) }
                }
            }
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
            // Editors and drag providers may still hold the pre-move value snapshot.
            let current = snapshot.materials.first(where: { $0.id == material.id }) ?? material
            let url = try fileURL(for: current)
            try ensureSafePath(url, beneath: current.isManaged ? root : nil)
            guard fm.fileExists(atPath: url.path) else { throw LibraryError.missingFile(url.path) }
            return url
        }
    }

    public func importFiles(urls: [URL], courseID: UUID?, category: String, copy: Bool, folderID: UUID? = nil) throws -> ImportSummary {
        try withLock {
            try ensureCourse(courseID)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: snapshot)
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
                        var material = MaterialRecord(id: id, courseID: courseID, title: source.deletingPathExtension().lastPathComponent, originalName: name, sourcePath: source.path, storedPath: source.path, isManaged: copy, category: normalizedCategory)
                        material.folderID = folderID
                        let existingRanks = next.materials.filter { $0.courseID == courseID && $0.folderID == folderID }.compactMap(\.customOrder)
                        if !existingRanks.isEmpty || next.courses.first(where: { $0.id == courseID })?.materialSort == .custom {
                            material.customOrder = (existingRanks.max() ?? -1) + 1
                        }
                        if copy { material.storedPath = MaterialStorageLayout.relativePath(for: material, courses: next.courses) }
                        let values = try source.resourceValues(forKeys: [.fileSizeKey])
                        material.size = Int64(values.fileSize ?? 0)
                        if copy {
                            let target = root.appendingPathComponent(material.storedPath)
                            try ensureSafePath(target, beneath: root)
                            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fm.copyItem(at: source, to: target)
                            created.append(target)
                        }
                        next.materials.append(material)
                        seen.insert(source.path); summary.imported += 1
                    } catch { summary.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
                }
                if summary.imported > 0 {
                    try saveSnapshot(next)
                }
                return summary
            } catch {
                for url in created {
                    try? fm.removeItem(at: url)
                    removeEmptyMaterialDirectories(from: url.deletingLastPathComponent())
                }
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
                    for e in task.exceptions.indices {
                        if let id = task.exceptions[e].details?.courseID, !courseIDs.contains(id) { task.exceptions[e].details?.courseID = nil }
                        task.exceptions[e].details?.materialIDs.removeAll { !materialIDs.contains($0) }
                    }
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

    public func saveAccentColor(_ value: String) throws {
        guard let color = RGBColor(hex: value) else { throw LibraryError.invalidInput("请输入六位 HEX 颜色，例如 #39786B。") }
        try commit { $0.accentColor = color.hex }
    }

    public func saveCourseBorders(_ enabled: Bool) throws {
        try commit { $0.showCourseBorders = enabled }
    }

    private func ensureCourse(_ id: UUID?) throws {
        if let id, !snapshot.courses.contains(where: { $0.id == id }) { throw LibraryError.missingRecord("课程") }
    }
    private func validate(_ state: LibraryState) throws {
        guard [6, 7].contains(state.schemaVersion), state.schemaVersion == 7 || state.teachingConnections.isEmpty else { throw LibraryError.invalidInput("不支持的资料库版本 \(state.schemaVersion)。") }
        try Self.validateTeachingConnections(state)
        try Self.validateMaterialOrganization(state)
        guard ["system", "light", "dark"].contains(state.appearance) else { throw LibraryError.invalidInput("未知的外观设置。") }
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
    /// Replaces one semester in a single metadata transaction. Existing course
    /// records retain their user edits, materials, tasks, and workspace folders.
    @discardableResult public func importUndergraduateTimetable(_ schedule: UndergraduateSchedule) throws -> TimetableImportSummary {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidInput("课表缺少学期名称。") }
        guard !schedule.courses.isEmpty else { throw LibraryError.invalidInput("课表中没有可导入的本科课程。") }
        var summary = TimetableImportSummary(termID: UUID(), coursesCreated: 0, meetingsImported: 0)
        try commit { state in
            let existing = state.timetableTerms.first { $0.name == name }
            var term = existing ?? TimetableTerm(name: name)
            let courseIDs = Set(state.courses.map(\.id))
            var oldCourseIDs: [TimetableCourseKey: UUID] = [:]
            var oldSessionIDs: [TimetableMeeting: UUID] = [:]
            var oldMonthFlags: [TimetableMeeting: Bool?] = [:]
            for meeting in term.meetings {
                if let id = meeting.courseID, courseIDs.contains(id) {
                    oldCourseIDs[TimetableCourseKey(code: meeting.courseCode, title: meeting.title, teacher: meeting.teacher)] = id
                }
                oldSessionIDs[Self.timetableSessionKey(meeting)] = meeting.id
                oldMonthFlags[Self.timetableSessionKey(meeting)] = .some(meeting.showInMonth)
            }
            var importedCourseIDs: [TimetableCourseKey: UUID] = [:]
            var sessions = Set<TimetableMeeting>()
            var meetings: [TimetableMeeting] = []
            var created = 0
            for course in schedule.courses {
                let title = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let teacher = (course.teacher ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let code = (course.classNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let classroom = (course.classroom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var notes = [(course.info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
                if let time = course.examTime?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty { notes.append("考试时间：\(time)") }
                if let location = course.examLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty { notes.append("考试地点：\(location)") }
                // Validate the raw offset too: a free-time row must not conceal
                // malformed negative or non-zero period data.
                guard course.timeCount >= 0, course.timeCount < 30,
                      course.startSection > 0 || course.timeCount == 0 else { throw LibraryError.invalidInput("\(title)：课程节次无效。") }
                var meeting = TimetableMeeting(courseCode: code, title: title, teacher: teacher, classroom: classroom,
                    weeks: Array(Set(course.weeks)).sorted(), weekday: course.weekday == 0 ? nil : course.weekday,
                    startSection: course.startSection, sectionCount: course.sectionCount, note: notes.filter { !$0.isEmpty }.joined(separator: "\n"))
                try Self.validateTimetableMeeting(meeting, weekCount: 60, courseIDs: nil)
                let key = TimetableCourseKey(code: code, title: title, teacher: teacher)
                if let id = importedCourseIDs[key] ?? oldCourseIDs[key] {
                    meeting.courseID = id
                } else if let existingCourse = state.courses.first(where: { $0.semester == name && $0.name == title && $0.teacher == teacher }) {
                    meeting.courseID = existingCourse.id
                } else {
                    let newCourse = Course(name: title, semester: name, teacher: teacher,
                        colorHex: ColorPalette.themes[state.courses.count % ColorPalette.themes.count].hex)
                    state.courses.append(newCourse)
                    meeting.courseID = newCourse.id
                    created += 1
                }
                importedCourseIDs[key] = meeting.courseID
                let sessionKey = Self.timetableSessionKey(meeting)
                guard sessions.insert(sessionKey).inserted else { continue }
                meeting.id = oldSessionIDs[sessionKey] ?? meeting.id
                meeting.showInMonth = oldMonthFlags[sessionKey] ?? nil
                meeting.colorHex = term.meetings.first { Self.timetableSessionKey($0) == sessionKey }?.colorHex
                if oldMonthFlags[sessionKey] == nil {
                    let oldSlots = term.meetings.filter {
                        $0.courseID == meeting.courseID && $0.weekday == meeting.weekday &&
                        $0.startSection == meeting.startSection && $0.sectionCount == meeting.sectionCount
                    }
                    if oldSlots.count == 1 { meeting.showInMonth = oldSlots[0].showInMonth }
                }
                meetings.append(meeting)
            }
            term.cancellations = Self.remapTimetableCancellations(term.cancellations, oldMeetings: term.meetings, newMeetings: meetings)
            term.reschedules = Self.remapTimetableReschedules(term.reschedules, oldMeetings: term.meetings, newMeetings: meetings)
            term.meetings = meetings
            let importedWeeks = meetings.flatMap(\.weeks).max() ?? 1
            if term.endDate != nil, importedWeeks > term.weekCount {
                throw LibraryError.invalidInput("导入课表含第 \(importedWeeks) 周课程，超过已设置的 \(term.weekCount) 周学期。请先核对学期结束日期与周数。")
            }
            if term.endDate == nil { term.weekCount = max(term.weekCount, importedWeeks) }
            if let index = state.timetableTerms.firstIndex(where: { $0.id == term.id }) { state.timetableTerms[index] = term }
            else { state.timetableTerms.append(term) }
            summary = TimetableImportSummary(termID: term.id, coursesCreated: created, meetingsImported: meetings.count)
        }
        return summary
    }

    public func saveTimetableTerm(_ term: TimetableTerm) throws {
        var term = term
        term.name = term.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let monday = term.weekOneMonday, monday.timeIntervalSinceReferenceDate.isFinite {
            term.weekOneMonday = TimetableTerm.academicCalendar.startOfDay(for: monday)
        }
        if let endDate = term.endDate, endDate.timeIntervalSinceReferenceDate.isFinite { term.endDate = TimetableTerm.academicCalendar.startOfDay(for: endDate) }
        term.reschedules = term.reschedules.map(Self.normalizedReschedule)
        for index in term.cancellations.indices {
            if term.cancellations[index].date.timeIntervalSinceReferenceDate.isFinite { term.cancellations[index].date = TimetableTerm.academicCalendar.startOfDay(for: term.cancellations[index].date) }
            if let saved = term.cancellations[index].savedReschedule { term.cancellations[index].savedReschedule = Self.normalizedReschedule(saved) }
        }
        try commit { state in
            if let index = state.timetableTerms.firstIndex(where: { $0.id == term.id }) { state.timetableTerms[index] = term }
            else { state.timetableTerms.append(term) }
        }
    }

    public func deleteTimetableTerm(id: UUID) throws {
        try commit { state in
            guard state.timetableTerms.contains(where: { $0.id == id }) else { throw LibraryError.missingRecord("学期课表") }
            state.timetableTerms.removeAll { $0.id == id }
        }
    }

    /// Cancels one real occurrence without changing recurring weeks or other
    /// sessions. Repeating this action preserves both the original record and backup.
    public func cancelTimetableClass(termID: UUID, meetingID: UUID, on date: Date, reason: String = "") throws {
        try withLock {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("停课日期无效。") }
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            let calendar = TimetableTerm.academicCalendar
            let day = calendar.startOfDay(for: date)
            guard !term.cancellations.contains(where: { $0.meetingID == meetingID && calendar.isDate($0.date, inSameDayAs: day) }) else { return }
            let move = term.reschedules.first { $0.meetingID == meetingID && calendar.isDate($0.originalDate, inSameDayAs: day) }
            let source = term.meetings.first { $0.id == meetingID }
            guard let meeting = move?.meeting ?? source else { throw LibraryError.missingRecord("上课时段") }
            guard move != nil || Self.isActualOccurrence(meeting, in: term, on: day) else {
                throw LibraryError.invalidInput("所选日期没有这次固定课程，无法设置停课。")
            }
            let cancellation = TimetableCancellation(meetingID: meetingID, date: day, title: meeting.title,
                                                     reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), savedReschedule: move)
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let move { state.timetableTerms[index].reschedules.removeAll { $0.id == move.id } }
                state.timetableTerms[index].cancellations.append(cancellation)
            }
        }
    }

    public func restoreTimetableClass(termID: UUID, cancellationID: UUID) throws {
        try withLock {
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard let cancellation = term.cancellations.first(where: { $0.id == cancellationID }) else { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let saved = cancellation.savedReschedule { state.timetableTerms[index].reschedules.append(saved) }
                state.timetableTerms[index].cancellations.removeAll { $0.id == cancellationID }
            }
        }
    }

    public func rescheduleTimetableClass(termID: UUID, meetingID: UUID, originalDate: Date, to date: Date, startSection: Int, sectionCount: Int, classroom: String, startMinute: Int? = nil, endMinute: Int? = nil) throws {
        try withLock {
            guard [originalDate, date].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw LibraryError.invalidInput("调课日期无效。") }
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            let calendar = TimetableTerm.academicCalendar
            let origin = calendar.startOfDay(for: originalDate), target = calendar.startOfDay(for: date)
            let existing = term.reschedules.first { $0.meetingID == meetingID && calendar.isDate($0.originalDate, inSameDayAs: origin) }
            let master = term.meetings.first { $0.id == meetingID }
            guard let source = existing?.meeting ?? master else { throw LibraryError.missingRecord("上课时段") }
            guard !term.isCancelled(source, on: origin), existing != nil || Self.isActualOccurrence(source, in: term, on: origin) else {
                throw LibraryError.invalidInput("原课次不存在或已停课，请先恢复停课后再调整。")
            }
            guard let targetWeek = term.week(containing: target) else { throw LibraryError.invalidInput("调课目标日期应在所选学期内。") }
            guard (1...30).contains(startSection), (1...30).contains(sectionCount), startSection <= 31 - sectionCount else {
                throw LibraryError.invalidInput("调课节次需在第 1–30 节内。")
            }
            let room = classroom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (startMinute == nil && endMinute == nil) || (startMinute.flatMap { start in endMinute.flatMap { PlanTimeRange(start: start, end: $0) } } != nil) else {
                throw LibraryError.invalidInput("课程时间必须在同一天内，且结束晚于开始。")
            }
            if let master, Self.isActualOccurrence(master, in: term, on: origin), origin == target,
               master.startSection == startSection, master.sectionCount == sectionCount, master.classroom == room,
               (startMinute == nil && endMinute == nil || master.timeRange(sectionTimes: term.sectionTimes) == startMinute.flatMap { start in endMinute.flatMap { PlanTimeRange(start: start, end: $0) } }) {
                if let existing { try restoreTimetableReschedule(termID: termID, rescheduleID: existing.id) }
                return
            }
            var moved = source
            moved.id = meetingID; moved.weekday = (calendar.component(.weekday, from: target) + 5) % 7 + 1
            moved.weeks = [targetWeek]; moved.startSection = startSection; moved.sectionCount = sectionCount; moved.classroom = room
            moved.startMinuteOverride = startMinute; moved.endMinuteOverride = endMinute
            let move = TimetableReschedule(id: existing?.id ?? UUID(), meetingID: meetingID, originalDate: origin, date: target, meeting: moved)
            if move == existing { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let position = state.timetableTerms[index].reschedules.firstIndex(where: { $0.id == move.id }) { state.timetableTerms[index].reschedules[position] = move }
                else { state.timetableTerms[index].reschedules.append(move) }
            }
        }
    }

    public func restoreTimetableReschedule(termID: UUID, rescheduleID: UUID) throws {
        try withLock {
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard term.reschedules.contains(where: { $0.id == rescheduleID }) else { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                state.timetableTerms[index].reschedules.removeAll { $0.id == rescheduleID }
            }
        }
    }

    public func updateTimetableMeeting(termID: UUID, meeting: TimetableMeeting) throws {
        try commit { state in
            guard let termIndex = state.timetableTerms.firstIndex(where: { $0.id == termID }),
                  let meetingIndex = state.timetableTerms[termIndex].meetings.firstIndex(where: { $0.id == meeting.id }) else { throw LibraryError.missingRecord("上课时段") }
            let previousTerm = state.timetableTerms[termIndex]
            func rebasedSourceDay(_ original: Date) -> Date {
                guard meeting.isScheduled, let week = previousTerm.week(containing: original), meeting.weeks.contains(week),
                      let weekday = meeting.weekday, let day = previousTerm.date(week: week, weekday: weekday) else { return original }
                return day
            }
            for index in state.timetableTerms[termIndex].reschedules.indices where state.timetableTerms[termIndex].reschedules[index].meetingID == meeting.id {
                state.timetableTerms[termIndex].reschedules[index].originalDate = rebasedSourceDay(state.timetableTerms[termIndex].reschedules[index].originalDate)
            }
            for index in state.timetableTerms[termIndex].cancellations.indices where state.timetableTerms[termIndex].cancellations[index].meetingID == meeting.id {
                let day = rebasedSourceDay(state.timetableTerms[termIndex].cancellations[index].date)
                state.timetableTerms[termIndex].cancellations[index].date = day
                if state.timetableTerms[termIndex].cancellations[index].savedReschedule != nil {
                    state.timetableTerms[termIndex].cancellations[index].savedReschedule?.originalDate = day
                }
            }
            state.timetableTerms[termIndex].meetings[meetingIndex] = meeting
        }
    }

    public func setTimetableMeetingColor(termID: UUID, meetingID: UUID, hex: String?) throws {
        let color: String?
        if let hex {
            guard let rgb = RGBColor(hex: hex) else { throw LibraryError.invalidInput("计划颜色须为六位 HEX 颜色。") }
            color = rgb.hex
        } else { color = nil }
        try commit { state in
            guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期") }
            for m in state.timetableTerms[index].meetings.indices where state.timetableTerms[index].meetings[m].id == meetingID {
                state.timetableTerms[index].meetings[m].colorHex = color
            }
            for r in state.timetableTerms[index].reschedules.indices where state.timetableTerms[index].reschedules[r].meetingID == meetingID {
                state.timetableTerms[index].reschedules[r].meeting.colorHex = color
            }
            for c in state.timetableTerms[index].cancellations.indices where state.timetableTerms[index].cancellations[c].meetingID == meetingID {
                state.timetableTerms[index].cancellations[c].savedReschedule?.meeting.colorHex = color
            }
        }
    }

    public func deleteTimetableMeeting(termID: UUID, meetingID: UUID) throws {
        try commit { state in
            guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard state.timetableTerms[index].meetings.contains(where: { $0.id == meetingID }) || state.timetableTerms[index].reschedules.contains(where: { $0.meetingID == meetingID }) else {
                throw LibraryError.missingRecord("上课时段")
            }
            state.timetableTerms[index].meetings.removeAll { $0.id == meetingID }
            state.timetableTerms[index].reschedules.removeAll { $0.meetingID == meetingID }
            for cancellationIndex in state.timetableTerms[index].cancellations.indices where state.timetableTerms[index].cancellations[cancellationIndex].meetingID == meetingID {
                state.timetableTerms[index].cancellations[cancellationIndex].savedReschedule = nil
            }
        }
    }

    private static func isActualOccurrence(_ meeting: TimetableMeeting, in term: TimetableTerm, on day: Date) -> Bool {
        let weekday = (TimetableTerm.academicCalendar.component(.weekday, from: day) + 5) % 7 + 1
        return meeting.isScheduled && meeting.weekday == weekday && term.week(containing: day).map(meeting.weeks.contains) == true
    }

    private static func normalizedReschedule(_ move: TimetableReschedule) -> TimetableReschedule {
        var move = move
        if move.date.timeIntervalSinceReferenceDate.isFinite { move.date = TimetableTerm.academicCalendar.startOfDay(for: move.date) }
        if move.originalDate.timeIntervalSinceReferenceDate.isFinite { move.originalDate = TimetableTerm.academicCalendar.startOfDay(for: move.originalDate) }
        return move
    }

    private func validateTimetables(_ terms: [TimetableTerm], courseIDs: Set<UUID>) throws {
        guard Set(terms.map(\.id)).count == terms.count,
              Set(terms.map(\.name)).count == terms.count else { throw LibraryError.invalidInput("课表包含重复的学期编号或名称。") }
        var meetingIDs = Set<UUID>(), cancellationIDs = Set<UUID>(), rescheduleIDs = Set<UUID>()
        for term in terms {
            guard !term.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  term.name == term.name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw LibraryError.invalidInput("课表学期名称不能为空或含有首尾空格。") }
            guard (1...60).contains(term.weekCount) else { throw LibraryError.invalidInput("学期周数应为 1–60 周。") }
            if let monday = term.weekOneMonday {
                guard monday.timeIntervalSinceReferenceDate.isFinite,
                      TimetableTerm.academicCalendar.component(.weekday, from: monday) == 2 else { throw LibraryError.invalidInput("请将第一周起始日设为周一（中国标准时间）。") }
            }
            if let end = term.endDate {
                guard end.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("学期结束日期无效。") }
                if let monday = term.weekOneMonday {
                    let calendar = TimetableTerm.academicCalendar
                    let start = calendar.startOfDay(for: monday), last = calendar.startOfDay(for: end)
                    let dayCount = calendar.dateComponents([.day], from: start, to: last).day ?? -1
                    guard dayCount >= (term.weekCount - 1) * 7, dayCount < term.weekCount * 7 else {
                        throw LibraryError.invalidInput("学期结束日期应位于第 \(term.weekCount) 周内，请核对开始日期与总周数。")
                    }
                }
            }
            var previousSection = 0, previousEnd = 0
            for time in term.sectionTimes {
                guard (1...30).contains(time.section), time.section > previousSection,
                      time.startMinute >= 0, time.startMinute < time.endMinute, time.endMinute <= 1_440,
                      time.startMinute >= previousEnd else { throw LibraryError.invalidInput("作息时间需按节次排序，各节的开始和结束时间不能重叠。") }
                previousSection = time.section; previousEnd = time.endMinute
            }
            for meeting in term.meetings {
                guard meetingIDs.insert(meeting.id).inserted else { throw LibraryError.invalidInput("课表包含重复的上课记录编号。") }
                try Self.validateTimetableMeeting(meeting, weekCount: term.weekCount, courseIDs: courseIDs)
            }
            var cancelledOccurrences = Set<String>(), movedOccurrences = Set<String>()
            for cancellation in term.cancellations {
                guard cancellationIDs.insert(cancellation.id).inserted else { throw LibraryError.invalidInput("课表包含重复的停课记录编号。") }
                guard cancellation.date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("停课记录包含无效日期。") }
                guard !cancellation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("停课记录的课程名称不能为空。") }
                let key = Self.timetableOccurrenceKey(meetingID: cancellation.meetingID, date: cancellation.date)
                guard cancelledOccurrences.insert(key).inserted else { throw LibraryError.invalidInput("同一课次存在重复停课记录。") }
                if let saved = cancellation.savedReschedule {
                    guard saved.originalDate.timeIntervalSinceReferenceDate.isFinite, saved.meetingID == cancellation.meetingID,
                          TimetableTerm.academicCalendar.isDate(saved.originalDate, inSameDayAs: cancellation.date) else { throw LibraryError.invalidInput("停课记录的原调课快照不匹配。") }
                    guard rescheduleIDs.insert(saved.id).inserted else { throw LibraryError.invalidInput("课表包含重复的调课记录编号。") }
                    try Self.validateTimetableReschedule(saved, in: term, courseIDs: courseIDs, active: false)
                }
                // Detached meeting IDs intentionally retain a visible history after reimports.
            }
            for move in term.reschedules {
                guard rescheduleIDs.insert(move.id).inserted else { throw LibraryError.invalidInput("课表包含重复的调课记录编号。") }
                try Self.validateTimetableReschedule(move, in: term, courseIDs: courseIDs, active: true)
                let key = Self.timetableOccurrenceKey(meetingID: move.meetingID, date: move.originalDate)
                guard movedOccurrences.insert(key).inserted, !cancelledOccurrences.contains(key) else { throw LibraryError.invalidInput("同一课次存在重复调课，或同时标记为停课。") }
            }
        }
    }

    private static func validateTimetableMeeting(_ meeting: TimetableMeeting, weekCount: Int, courseIDs: Set<UUID>?) throws {
        if let hex = meeting.colorHex, RGBColor(hex: hex) == nil { throw LibraryError.invalidInput("课程时段颜色无效。") }
        if meeting.startMinuteOverride != nil || meeting.endMinuteOverride != nil {
            guard let start = meeting.startMinuteOverride, let end = meeting.endMinuteOverride,
                  PlanTimeRange(start: start, end: end) != nil else { throw LibraryError.invalidInput("课程时间须在同一天内。") }
        }
        guard !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("课表课程名称不能为空。") }
        if let id = meeting.courseID, let courseIDs, !courseIDs.contains(id) { throw LibraryError.invalidInput("课表关联的课程不存在。") }
        let freeTime = (meeting.weekday == nil || meeting.weekday == 0) && meeting.startSection == 0 && meeting.sectionCount == 0
        guard (freeTime || !meeting.weeks.isEmpty), Set(meeting.weeks).count == meeting.weeks.count,
              meeting.weeks.allSatisfy({ (1...weekCount).contains($0) }) else { throw LibraryError.invalidInput("\(meeting.title)：上课周次应在学期周数范围内。") }
        if meeting.weekday == nil || meeting.weekday == 0 {
            guard meeting.startSection == 0, meeting.sectionCount == 0 else { throw LibraryError.invalidInput("\(meeting.title)：自由时间课程不能包含固定节次。") }
        } else {
            guard let weekday = meeting.weekday, (1...7).contains(weekday), (1...30).contains(meeting.startSection),
                  (1...30).contains(meeting.sectionCount), meeting.endSection <= 30 else { throw LibraryError.invalidInput("\(meeting.title)：星期或课程节次无效。") }
        }
    }

    private static func validateTimetableReschedule(_ move: TimetableReschedule, in term: TimetableTerm, courseIDs: Set<UUID>, active: Bool) throws {
        guard move.date.timeIntervalSinceReferenceDate.isFinite, move.originalDate.timeIntervalSinceReferenceDate.isFinite,
              move.meetingID == move.meeting.id, move.meeting.isScheduled else { throw LibraryError.invalidInput("调课记录的日期、课堂编号或节次无效。") }
        try validateTimetableMeeting(move.meeting, weekCount: 60, courseIDs: courseIDs)
        let calendar = TimetableTerm.academicCalendar
        guard move.date == calendar.startOfDay(for: move.date), move.originalDate == calendar.startOfDay(for: move.originalDate),
              move.meeting.weekday == (calendar.component(.weekday, from: move.date) + 5) % 7 + 1 else {
            throw LibraryError.invalidInput("调课日期需按北京时间整日保存，星期应与目标日期一致。")
        }
        if active, term.weekOneMonday != nil {
            // The snapshot's original week labels are descriptive; its civil
            // target remains authoritative when semester dates are adjusted.
            guard term.week(containing: move.date) != nil else { throw LibraryError.invalidInput("调课目标日期应在所选学期内。") }
        }
    }

    private static func timetableOccurrenceKey(meetingID: UUID, date: Date) -> String {
        "\(meetingID.uuidString)-\(TimetableTerm.academicCalendar.startOfDay(for: date).timeIntervalSinceReferenceDate)"
    }

    private static func timetableSessionKey(_ meeting: TimetableMeeting) -> TimetableMeeting {
        var key = meeting
        key.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        key.courseID = nil
        key.showInMonth = nil
        key.colorHex = nil; key.startMinuteOverride = nil; key.endMinuteOverride = nil
        return key
    }

    private static func remapTimetableCancellations(_ cancellations: [TimetableCancellation], oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> [TimetableCancellation] {
        return cancellations.map { cancellation in
            var remapped = cancellation
            remapped.meetingID = remappedMeetingID(cancellation.meetingID, oldMeetings: oldMeetings, newMeetings: newMeetings)
            if let saved = cancellation.savedReschedule {
                remapped.savedReschedule = remapTimetableReschedules([saved], oldMeetings: oldMeetings, newMeetings: newMeetings).first
            }
            return remapped
        }
    }

    private static func remapTimetableReschedules(_ moves: [TimetableReschedule], oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> [TimetableReschedule] {
        moves.map { move in
            var remapped = move
            remapped.meetingID = remappedMeetingID(move.meetingID, oldMeetings: oldMeetings, newMeetings: newMeetings)
            remapped.meeting.id = remapped.meetingID
            return remapped
        }
    }

    private static func remappedMeetingID(_ id: UUID, oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> UUID {
        func sameSlot(_ first: TimetableMeeting, _ second: TimetableMeeting) -> Bool {
            guard first.isScheduled, second.isScheduled, first.weekday == second.weekday,
                  first.startSection == second.startSection, first.sectionCount == second.sectionCount else { return false }
            return (first.courseID != nil && first.courseID == second.courseID) || (!first.courseCode.isEmpty && first.courseCode == second.courseCode)
        }
        guard !newMeetings.contains(where: { $0.id == id }), let old = oldMeetings.first(where: { $0.id == id }) else { return id }
        let candidates = newMeetings.filter { sameSlot(old, $0) }
        guard candidates.count == 1, let candidate = candidates.first, oldMeetings.filter({ sameSlot($0, candidate) }).count == 1 else { return id }
        return candidate.id
    }
}

private struct TimetableCourseKey: Hashable {
    var code: String
    var title: String
    var teacher: String

    init(code: String, title: String, teacher: String) {
        self.code = code
        // A portal course number survives user edits to the library course.
        self.title = code.isEmpty ? title : ""
        self.teacher = code.isEmpty ? teacher : ""
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
            let course = snapshot.courses.first { $0.id == courseID }
            let url = root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course), isDirectory: true)
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
                try saveSnapshot(restored)
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

extension LibraryRepository {
    /// Restores only changed records; unrelated later edits remain intact.
    public func restorePlanChanges(before: [StudyTask], after: [StudyTask]) throws {
        try commit { state in
            let ids = Set(before.map(\.id)).union(after.map(\.id))
            guard Set(before.map(\.id)).count == before.count, Set(after.map(\.id)).count == after.count else {
                throw LibraryError.invalidInput("撤销记录包含重复计划。")
            }
            let expected = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            let current = Dictionary(uniqueKeysWithValues: state.tasks.filter { ids.contains($0.id) }.map { ($0.id, $0) })
            guard current == expected else { throw LibraryError.invalidInput("这些计划后来已被修改，无法撤销。") }
            state.tasks.removeAll { ids.contains($0.id) }
            state.tasks.append(contentsOf: before)
        }
    }

    public func movePlanOccurrence(id: UUID, originalDate: Date, isDeadline: Bool, to date: Date) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            let parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            let current = PlanCalendar.snapshot(of: parent, originalDate: originalDate)
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("计划时间无效。") }
            if isDeadline {
                guard current.deadline != nil else { throw LibraryError.invalidInput("该计划没有截止时间。") }
                if parent.repeatRule == nil { state.tasks[index].deadline = date }
                else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.deadline = date } }
            } else {
                guard current.hasExecutionTime else { throw LibraryError.invalidInput("该计划尚未安排执行时间。") }
                let end = current.endsAt.map { date.addingTimeInterval($0.timeIntervalSince(current.startsAt)) }
                if parent.repeatRule == nil { state.tasks[index].startsAt = date; state.tasks[index].endsAt = end }
                else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.startsAt = date; $0.endsAt = end } }
            }
        }
    }

    public func setPlanOccurrenceTime(id: UUID, originalDate: Date, day: Date, range: PlanTimeRange) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            let current = PlanCalendar.snapshot(of: parent, originalDate: originalDate)
            guard current.hasExecutionTime, !current.isAllDay, day.timeIntervalSinceReferenceDate.isFinite else {
                throw LibraryError.invalidInput("请选择有具体时段的计划。")
            }
            let midnight = PlanCalendar.calendar.startOfDay(for: day)
            let start = midnight.addingTimeInterval(Double(range.start) * 60)
            let end = midnight.addingTimeInterval(Double(range.end) * 60)
            if parent.repeatRule == nil { state.tasks[index].startsAt = start; state.tasks[index].endsAt = end }
            else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.startsAt = start; $0.endsAt = end } }
        }
    }

    public func setPlanOccurrenceCompleted(id: UUID, originalDate: Date, completed: Bool) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            if parent.repeatRule == nil { state.tasks[index].completedAt = completed ? (parent.completedAt ?? Date()) : nil }
            else {
                Self.editException(in: &state.tasks[index], on: originalDate) {
                    $0.completedAt = completed ? ($0.completedAt ?? Date()) : nil
                    $0.completedOverride = completed
                }
            }
        }
    }

    public func setPlanOccurrenceCancelled(id: UUID, originalDate: Date, cancelled: Bool) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            if parent.repeatRule == nil { state.tasks[index].cancelledAt = cancelled ? (parent.cancelledAt ?? Date()) : nil }
            else {
                guard parent.cancelledAt == nil else { throw LibraryError.invalidInput("整组计划已取消，请先恢复整组。") }
                Self.editException(in: &state.tasks[index], on: originalDate) { $0.cancelledAt = cancelled ? ($0.cancelledAt ?? Date()) : nil }
            }
        }
    }

    /// Clears one occurrence's overrides, restoring its original arrangement.
    public func restorePlanOccurrence(id: UUID, originalDate: Date) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            try Self.requireOccurrence(originalDate, of: state.tasks[index])
            if state.tasks[index].repeatRule == nil {
                state.tasks[index].cancelledAt = nil; state.tasks[index].completedAt = nil
            } else { state.tasks[index].exceptions.removeAll { $0.originalDate == originalDate } }
        }
    }

    public func savePlan(_ task: StudyTask, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        if scope == .all {
            try commit { state in
                var replacement = Self.normalizedPlan(task, in: state)
                if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                    guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档计划为只读，请先恢复。") }
                    let previous = state.tasks[index]
                    replacement.exceptions = Self.remappedPlanExceptions(task.exceptions, from: previous, to: task)
                    if previous.deadline != nil && task.deadline == nil {
                        for e in replacement.exceptions.indices {
                            replacement.exceptions[e].deadline = nil
                            replacement.exceptions[e].details?.deadline = nil
                        }
                    }
                    if previous.hasExecutionTime && !task.hasExecutionTime {
                        for e in replacement.exceptions.indices {
                            replacement.exceptions[e].startsAt = nil; replacement.exceptions[e].endsAt = nil
                            replacement.exceptions[e].details?.hasExecutionTime = false
                        }
                    }
                    state.tasks[index] = replacement
                } else { state.tasks.append(replacement) }
            }
            return
        }
        try commit { state in
            let index = try Self.editablePlanIndex(task.id, in: state), parent = state.tasks[index]
            guard let originalDate else { throw LibraryError.invalidInput("请选择要调整的这次计划。") }
            try Self.requireOccurrence(originalDate, of: parent)
            guard parent.repeatRule != nil else {
                var replacement = task; replacement.id = parent.id; replacement.exceptions = []
                state.tasks[index] = Self.normalizedPlan(replacement, in: state); return
            }
            if scope == .thisOccurrence {
                var nominal = parent; nominal.exceptions = []
                let base = PlanCalendar.snapshot(of: nominal, originalDate: originalDate)
                var details = PlanDetails(Self.normalizedPlan(task, in: state), comparedTo: base)
                details.materialIDs = Array(Set(details.materialIDs)).sorted { $0.uuidString < $1.uuidString }
                Self.editException(in: &state.tasks[index], on: originalDate) {
                    $0.details = details; $0.startsAt = nil; $0.endsAt = nil; $0.deadline = nil; $0.location = nil
                    $0.completedAt = task.completedAt; $0.cancelledAt = task.cancelledAt
                    $0.completedOverride = task.completedAt != base.completedAt ? task.completedAt != nil : nil
                }
            } else {
                let base = PlanCalendar.anchor(for: parent)
                if originalDate == base {
                    var replacement = task; replacement.id = parent.id
                    replacement = Self.normalizedPlan(replacement, in: state)
                    replacement.exceptions = Self.remappedPlanExceptions(parent.exceptions.filter { $0.originalDate != originalDate }, from: parent, to: replacement)
                    state.tasks[index] = replacement
                } else {
                    var future = Self.normalizedPlan(task, in: state)
                    future.id = UUID(); future.exceptions = []
                    if let oldRule = parent.repeatRule, let newRule = future.repeatRule {
                        let sourceIndex = PlanCalendar.indexNear(originalDate, base: base, rule: oldRule)
                        let newBase = PlanCalendar.anchor(for: future)
                        for old in parent.exceptions where old.originalDate > originalDate {
                            let offset = PlanCalendar.indexNear(old.originalDate, base: base, rule: oldRule) - sourceIndex
                            guard let newOriginal = PlanCalendar.occurrenceDate(index: offset, base: newBase, rule: newRule), PlanCalendar.isOccurrenceAnchor(newOriginal, for: future) else { continue }
                            var remapped = old; remapped.originalDate = newOriginal
                            future.exceptions.append(remapped)
                        }
                    }
                    Self.truncatePlan(&state.tasks[index], before: originalDate)
                    state.tasks.append(future)
                }
            }
        }
    }

    public func cancelPlan(id: UUID, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        guard scope == .all || originalDate != nil else { throw LibraryError.invalidInput("请选择要取消的这次计划。") }
        if scope == .thisOccurrence, let originalDate { try setPlanOccurrenceCancelled(id: id, originalDate: originalDate, cancelled: true); return }
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            if scope == .thisAndFuture, let originalDate, state.tasks[index].repeatRule != nil {
                try Self.requireOccurrence(originalDate, of: state.tasks[index])
                if originalDate == PlanCalendar.anchor(for: state.tasks[index]) { state.tasks[index].cancelledAt = Date() }
                else {
                    let parent = state.tasks[index]
                    var nominal = parent; nominal.exceptions = []
                    var future = PlanCalendar.snapshot(of: nominal, originalDate: originalDate)
                    future.id = UUID(); future.cancelledAt = Date()
                    future.exceptions = []
                    if let rule = parent.repeatRule {
                        let sourceIndex = PlanCalendar.indexNear(originalDate, base: PlanCalendar.anchor(for: parent), rule: rule)
                        for old in parent.exceptions where old.originalDate >= originalDate {
                            let offset = PlanCalendar.indexNear(old.originalDate, base: PlanCalendar.anchor(for: parent), rule: rule) - sourceIndex
                            if let next = PlanCalendar.occurrenceDate(index: offset, base: PlanCalendar.anchor(for: future), rule: rule) {
                                var copy = old; copy.originalDate = next; future.exceptions.append(copy)
                            }
                        }
                    }
                    Self.truncatePlan(&state.tasks[index], before: originalDate)
                    state.tasks.append(future)
                }
            } else { state.tasks[index].cancelledAt = Date() }
        }
    }

    public func deletePlan(id: UUID, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        guard scope == .all || originalDate != nil else { throw LibraryError.invalidInput("请选择要移除的这次计划。") }
        if scope == .all { try deleteTasks(ids: [id]); return }
        if scope == .thisOccurrence, let originalDate { try setPlanOccurrenceCancelled(id: id, originalDate: originalDate, cancelled: true); return }
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            guard let originalDate else { throw LibraryError.invalidInput("请选择要移除的这次计划。") }
            try Self.requireOccurrence(originalDate, of: state.tasks[index])
            if state.tasks[index].repeatRule == nil || originalDate == PlanCalendar.anchor(for: state.tasks[index]) { state.tasks.remove(at: index) }
            else { Self.truncatePlan(&state.tasks[index], before: originalDate) }
        }
    }

    private static func editablePlanIndex(_ id: UUID, in state: LibraryState) throws -> Int {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("计划") }
        guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档计划为只读，请先恢复。") }
        return index
    }
    private static func requireOccurrence(_ date: Date, of plan: StudyTask) throws {
        guard PlanCalendar.isOccurrenceAnchor(date, for: plan) else { throw LibraryError.invalidInput("找不到该次计划，重复规则可能已经改变。") }
    }
    private static func normalizedPlan(_ plan: StudyTask, in state: LibraryState) -> StudyTask {
        var result = plan
        if let hex = result.colorHex, let color = RGBColor(hex: hex) { result.colorHex = color.hex }
        result.materialIDs = Array(Set(result.materialIDs)).sorted { $0.uuidString < $1.uuidString }
        if let id = result.courseID { result.courseNameSnapshot = state.courses.first { $0.id == id }?.name }
        return result
    }
    private static func editException(in plan: inout StudyTask, on date: Date, _ action: (inout PlanException) -> Void) {
        let index = plan.exceptions.firstIndex { $0.originalDate == date }
        var exception = index.map { plan.exceptions[$0] } ?? PlanException(originalDate: date)
        action(&exception)
        if let index { plan.exceptions[index] = exception } else { plan.exceptions.append(exception) }
        plan.exceptions.sort { $0.originalDate < $1.originalDate }
    }
    private static func truncatePlan(_ plan: inout StudyTask, before date: Date) {
        plan.repeatRule?.until = PlanCalendar.calendar.date(byAdding: .day, value: -1, to: PlanCalendar.calendar.startOfDay(for: date))
        plan.exceptions.removeAll { $0.originalDate >= date }
    }
}

extension LibraryRepository {
    private static func remappedPlanExceptions(_ exceptions: [PlanException], from old: StudyTask, to new: StudyTask) -> [PlanException] {
        guard let oldRule = old.repeatRule, let newRule = new.repeatRule else { return [] }
        let oldBase = PlanCalendar.anchor(for: old), newBase = PlanCalendar.anchor(for: new)
        return exceptions.compactMap { exception in
            let index = PlanCalendar.indexNear(exception.originalDate, base: oldBase, rule: oldRule)
            guard let date = PlanCalendar.occurrenceDate(index: index, base: newBase, rule: newRule), PlanCalendar.isOccurrenceAnchor(date, for: new) else { return nil }
            var copy = exception; copy.originalDate = date
            return copy
        }
    }
    private static func validatePlan(_ task: StudyTask, courseIDs: Set<UUID>, materialIDs: Set<UUID>) throws {
        if let hex = task.colorHex, RGBColor(hex: hex) == nil { throw LibraryError.invalidInput("计划颜色须为六位 HEX 颜色。") }
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("计划名称不能为空。") }
        guard [task.startsAt, task.endsAt, task.deadline, task.completedAt, task.archivedAt, task.cancelledAt, task.repeatRule?.until].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryError.invalidInput("计划包含无效日期。")
        }
        if task.hasExecutionTime, let end = task.endsAt {
            guard end >= task.startsAt, end.timeIntervalSince(task.startsAt) <= 3660 * 86400 else { throw LibraryError.invalidInput("执行结束时间须在开始之后，且跨度不能超过十年。") }
        }
        if let archived = task.archivedAt {
            guard let completed = task.completedAt, completed <= archived else { throw LibraryError.invalidInput("归档计划必须已完成，且完成时间不能晚于归档时间。") }
        }
        if let id = task.courseID, !courseIDs.contains(id) { throw LibraryError.invalidInput("计划关联的课程不存在。") }
        guard task.materialIDs.allSatisfy(materialIDs.contains) else { throw LibraryError.invalidInput("计划关联的资料不存在。") }
        if let rule = task.repeatRule {
            guard (1...366).contains(rule.interval), task.hasExecutionTime || task.deadline != nil else { throw LibraryError.invalidInput("重复间隔须为1至366，且需要执行时间或截止时间。") }
            if let until = rule.until, PlanCalendar.calendar.startOfDay(for: until) < PlanCalendar.calendar.startOfDay(for: PlanCalendar.anchor(for: task)) { throw LibraryError.invalidInput("重复结束日期不能早于首次安排。") }
        } else if !task.exceptions.isEmpty { throw LibraryError.invalidInput("非重复计划不能包含单次例外。") }
        guard task.exceptions.count <= 10_000, Set(task.exceptions.map(\.originalDate)).count == task.exceptions.count else { throw LibraryError.invalidInput("重复计划例外过多或包含重复日期。") }
        for exception in task.exceptions {
            guard [exception.originalDate, exception.startsAt, exception.endsAt, exception.deadline, exception.completedAt, exception.cancelledAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }), PlanCalendar.isOccurrenceAnchor(exception.originalDate, for: task) else { throw LibraryError.invalidInput("计划的单次调整不属于当前重复规则。") }
            var effective = PlanCalendar.snapshot(of: task, originalDate: exception.originalDate)
            effective.repeatRule = nil; effective.exceptions = []; effective.archivedAt = nil
            try validatePlan(effective, courseIDs: courseIDs, materialIDs: materialIDs)
        }
    }
}

extension LibraryRepository {
    public func setMaterialSort(_ mode: MaterialSortMode, courseID: UUID) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == courseID }) else { throw LibraryError.missingRecord("课程") }
            if mode == .custom {
                let usesDefaultOrder = state.courses[index].materialSort == nil
                let previous = state.courses[index].materialSort ?? .name
                let records = state.materials.filter { $0.courseID == courseID }
                for group in Dictionary(grouping: records, by: \.folderID).values where usesDefaultOrder || group.allSatisfy({ $0.customOrder == nil }) {
                    for (rank, material) in MaterialOrdering.sorted(group, by: previous).enumerated() {
                        state.materials[state.materials.firstIndex { $0.id == material.id }!].customOrder = rank
                    }
                }
            }
            state.courses[index].materialSort = mode
        }
    }

    public func reorderMaterials(ids: Set<UUID>, before target: UUID?, courseID: UUID, folderID: UUID?) throws {
        try commit { state in
            try Self.ensureMaterialIDs(ids, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: state)
            guard !ids.isEmpty else { return }
            let records = MaterialOrdering.sorted(state.materials.filter { $0.courseID == courseID && $0.folderID == folderID }, by: .custom)
            guard ids.isSubset(of: Set(records.map(\.id))), target == nil || records.contains(where: { $0.id == target }) else {
                throw LibraryError.invalidInput("只能调整当前文件夹中的资料顺序。")
            }
            if let target, ids.contains(target) { return }
            let moving = records.filter { ids.contains($0.id) }
            var remaining = records.filter { !ids.contains($0.id) }
            let index = target.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.count
            remaining.insert(contentsOf: moving, at: index)
            for (rank, record) in remaining.enumerated() {
                state.materials[state.materials.firstIndex { $0.id == record.id }!].customOrder = rank
            }
            state.courses[state.courses.firstIndex { $0.id == courseID }!].materialSort = .custom
        }
    }

    @discardableResult
    public func createMaterialFolder(name: String, courseID: UUID, parentID: UUID? = nil, materialIDs: Set<UUID> = []) throws -> MaterialFolder {
        var result: MaterialFolder!
        try commit { state in
            try Self.ensureMaterialIDs(materialIDs, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(parentID, courseID: courseID, in: state)
            result = MaterialFolder(courseID: courseID, parentID: parentID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            state.materialFolders.append(result)
            Self.assignMaterials(materialIDs, to: result.id, in: &state)
        }
        return result
    }

    public func renameMaterialFolder(id: UUID, name: String) throws {
        try commit { state in
            guard let index = state.materialFolders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            state.materialFolders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func updateMaterialFolder(id: UUID, name: String, colorHex: String?) throws {
        try commit { state in
            guard let index = state.materialFolders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            if let colorHex, RGBColor(hex: colorHex) == nil { throw LibraryError.invalidInput("请输入六位 HEX 文件夹颜色。") }
            state.materialFolders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.materialFolders[index].colorHex = colorHex.flatMap { RGBColor(hex: $0)?.hex }
        }
    }

    public func moveMaterials(ids: Set<UUID>, to folderID: UUID?, courseID: UUID) throws {
        try commit { state in
            try Self.ensureMaterialIDs(ids, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: state)
            Self.assignMaterials(ids, to: folderID, in: &state)
        }
    }

    /// Dissolving a group returns all descendants to its parent without deleting files.
    public func dissolveMaterialFolder(id: UUID) throws {
        try commit { state in
            guard let folder = state.materialFolders.first(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            let descendants = Set(state.materialFolders.filter { MaterialOrdering.folderPath($0.id, in: state.materialFolders).contains(where: { $0.id == id }) }.map(\.id))
            let ids = Set(state.materials.filter { $0.folderID.map(descendants.contains) == true }.map(\.id))
            Self.assignMaterials(ids, to: folder.parentID, in: &state)
            state.materialFolders.removeAll { descendants.contains($0.id) }
        }
    }

    /// Only managed library copies enter Trash; external originals remain untouched.
    public func trashMaterials(ids: Set<UUID>) throws {
        try trashMaterials(ids: ids, moveToTrash: { source in
            var trashed: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &trashed)
            guard let trashed else { throw LibraryError.invalidInput("文件已移到废纸篓，但无法记录其恢复位置。请从废纸篓恢复文件后重试。") }
            return trashed as URL
        })
    }

    func trashMaterials(ids: Set<UUID>, moveToTrash: (URL) throws -> URL) throws {
        try withLock {
            guard !ids.isEmpty, ids.isSubset(of: Set(snapshot.materials.map(\.id))) else { throw LibraryError.missingRecord("资料") }
            var moved: [(URL, URL)] = []
            do {
                for record in snapshot.materials where ids.contains(record.id) && record.isManaged {
                    let source = try fileURL(for: record)
                    try ensureSafePath(source, beneath: filesURL)
                    guard fm.fileExists(atPath: source.path) else { continue }
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
                    moved.append((source, try moveToTrash(source)))
                }
                try removeMaterials(ids: ids)
            } catch {
                var failed: [String] = []
                for (original, trashed) in moved.reversed() {
                    do { try fm.moveItem(at: trashed, to: original) }
                    catch { failed.append(original.lastPathComponent) }
                }
                if !failed.isEmpty { throw LibraryError.invalidInput("删除未完成，部分文件可从废纸篓恢复：" + failed.joined(separator: "、")) }
                throw error
            }
        }
    }

    public func exportMaterials(ids: Set<UUID>, to destination: URL) throws {
        try withLock {
            let records = snapshot.materials.filter { ids.contains($0.id) }
            guard !ids.isEmpty, records.count == ids.count else { throw LibraryError.missingRecord("所选资料") }
            let destination = destination.standardizedFileURL
            try ensureSafePath(destination, beneath: nil)
            guard !isBeneath(destination, root: root), destination.pathExtension.lowercased() == "zip" else {
                throw LibraryError.invalidInput("请将 ZIP 导出到资料库以外的文件夹。")
            }
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-export-\(UUID().uuidString)")
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            let payload = stage.appendingPathComponent("课程资料", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: false)
            var used: Set<String> = []
            let multipleCourses = Set(records.map(\.courseID)).count > 1
            var directories: [UUID: URL] = [:]
            for record in records {
                var directory = payload
                if multipleCourses {
                    let course = snapshot.courses.first { $0.id == record.courseID }
                    directory.appendPathComponent(MaterialStorageLayout.component(course?.name ?? "未分类", byteLimit: 120) + " [\(record.courseID?.uuidString ?? "未分类")]")
                }
                for folder in MaterialOrdering.folderPath(record.folderID, in: snapshot.materialFolders) {
                    directory.appendPathComponent(folder.name)
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                directories[record.id] = directory
            }
            for record in MaterialOrdering.sorted(records, by: .custom) {
                let source = try resolveURL(record)
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
                let directory = directories[record.id]!
                let name = MaterialStorageLayout.component(record.originalName, byteLimit: 218)
                let ext = URL(fileURLWithPath: name).pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                var candidate = directory.appendingPathComponent(name), number = 2
                while fm.fileExists(atPath: candidate.path) || used.contains(candidate.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
                    candidate = directory.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")); number += 1
                }
                used.insert(candidate.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                try fm.copyItem(at: source, to: candidate)
            }
            let archive = stage.appendingPathComponent("export.zip")
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", "--keepParent", payload.path, archive.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LibraryError.invalidInput("压缩失败：" + (String(data: data, encoding: .utf8) ?? "无法生成 ZIP")) }
            try ZipUTF8Names.mark(in: archive)
            try atomicRename(archive, destination)
        }
    }

    private static func ensureMaterialFolder(_ id: UUID?, courseID: UUID?, in state: LibraryState) throws {
        if let id, !state.materialFolders.contains(where: { $0.id == id && $0.courseID == courseID }) {
            throw LibraryError.invalidInput("文件夹不属于当前课程。")
        }
    }
    private static func ensureMaterialIDs(_ ids: Set<UUID>, courseID: UUID, in state: LibraryState) throws {
        guard state.courses.contains(where: { $0.id == courseID }), ids.isSubset(of: Set(state.materials.filter { $0.courseID == courseID }.map(\.id))) else {
            throw LibraryError.invalidInput("请选择同一课程中的资料。")
        }
    }
    private static func assignMaterials(_ ids: Set<UUID>, to folderID: UUID?, in state: inout LibraryState) {
        var rank = (state.materials.filter { $0.folderID == folderID }.compactMap(\.customOrder).max() ?? -1) + 1
        for record in MaterialOrdering.sorted(state.materials.filter { ids.contains($0.id) }, by: .custom) where record.folderID != folderID {
            let index = state.materials.firstIndex { $0.id == record.id }!
            state.materials[index].folderID = folderID; state.materials[index].customOrder = rank; rank += 1
        }
    }
    private static func validateMaterialOrganization(_ state: LibraryState) throws {
        guard Set(state.materialFolders.map(\.id)).count == state.materialFolders.count else { throw LibraryError.invalidInput("文件夹编号重复。") }
        var names: Set<String> = []
        for folder in state.materialFolders {
            if let color = folder.colorHex, !ColorPalette.isStoredColor(color) { throw LibraryError.invalidInput("文件夹颜色无效。") }
            guard state.courses.contains(where: { $0.id == folder.courseID }), !folder.name.isEmpty,
                  folder.name == folder.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  folder.name.utf8.count <= 120, folder.name != ".", folder.name != "..",
                  !folder.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }) else {
                throw LibraryError.invalidInput("文件夹名称不能为空、超过 120 字节或包含路径分隔符。")
            }
            try ensureMaterialFolder(folder.parentID, courseID: folder.courseID, in: state)
            var visited: Set<UUID> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard visited.insert(id).inserted else { throw LibraryError.invalidInput("文件夹不能形成循环。") }
                parent = state.materialFolders.first { $0.id == id }?.parentID
            }
            let key = "\(folder.courseID)/\(folder.parentID?.uuidString ?? "root")/" + folder.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw LibraryError.invalidInput("同一位置已存在同名文件夹。") }
        }
        for record in state.materials {
            try ensureMaterialFolder(record.folderID, courseID: record.courseID, in: state)
            if let rank = record.customOrder, rank < 0 || rank >= Int.max - state.materials.count - 1 { throw LibraryError.invalidInput("资料顺序无效。") }
        }
    }
}
