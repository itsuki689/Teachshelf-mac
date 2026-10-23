import Foundation

extension LibraryRepository {
    static func validateTeachingConnections(_ state: LibraryState) throws {
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
            state.schemaVersion = 8
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
                let localIDs = link.id.hasPrefix("file:") ? materialIDs : taskIDs
                return link.ignored || link.localID.map(localIDs.contains) != true
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

    /// Check the local source mapping without downloading or changing library records.
    public func teachingFileState(connectionID: UUID, activity: TeachingActivity, file: TeachingFile) throws -> TeachingFileState {
        try withLock {
            guard let connection = snapshot.teachingConnections.first(where: { $0.id == connectionID }) else { throw LibraryError.missingRecord("课程连接") }
            guard let link = connection.items.first(where: { $0.id == "file:\(activity.key):\(file.key)" }) else { return .new }
            guard !link.ignored, let material = snapshot.materials.first(where: { $0.id == link.localID }), material.courseID == connection.courseID else { return .ignored }
            guard let url = try? resolveURL(material), fileManager.isReadableFile(atPath: url.path) else { return .missing }
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

    /// Downloaded bytes and their source identity commit together. Prior versions stay in the library.
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
            material.storedPath = MaterialStorageLayout.relativePath(for: material, courses: state.courses, folders: state.materialFolders)
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
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: downloadedURL, to: target)
            var link = TeachingItemLink(id: key, localID: id, title: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent)
            link.digest = digest; link.folderID = sourceFolder
            connection.items.removeAll { $0.id == key }; connection.items.append(link)
            state.materials.append(material); state.teachingConnections[c] = connection
            do { try saveSnapshot(state) }
            catch { try? fileManager.removeItem(at: target); throw error }
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
