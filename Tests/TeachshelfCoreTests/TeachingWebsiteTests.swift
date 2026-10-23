import Foundation
import Testing
@testable import TeachshelfCore

struct TeachingWebsiteTests {
    private func fixture() throws -> (LibraryRepository, TeachingConnection, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-web-tests-\(UUID().uuidString)")
        let repo = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "数据库"); try repo.saveCourse(course)
        let connection = TeachingConnection(courseID: course.id, remoteCourseID: "411", remoteTitle: "数据库系统概论", accountID: "123")
        try repo.saveTeachingConnection(connection)
        return (repo, connection, root)
    }
    private func activity(_ kind: String = "assign", id: String = "5302") -> TeachingActivity {
        TeachingActivity(id: id, kind: kind, title: kind == "assign" ? "作业09" : "第一章", sectionID: kind == "assign" ? "section-2" : "section-1", section: kind == "assign" ? "作业" : "课件", url: URL(string: "https://selearning.nju.edu.cn/mod/\(kind)/view.php?id=\(id)")!)
    }
    private func page(_ deadline: String = "2026年10月26日 Monday 18:00", submitted: Bool = false) -> TeachingPage {
        TeachingPage(kind: "assign", accountID: "123", courseID: "411", title: "作业09", intro: "阅读教材，完成题目。", deadlineText: deadline, submitted: submitted)
    }
    private func sample(_ root: URL, content: String = "lecture", name: String = "lecture.txt") throws -> (TeachingFile, URL) {
        let path = root.appendingPathComponent(UUID().uuidString)
        try Data(content.utf8).write(to: path)
        return (TeachingFile(key: name, name: name, url: URL(string: "https://selearning.nju.edu.cn/pluginfile.php/1/mod_assign/introattachment/0/\(name)")!), path)
    }
    private func date(_ value: String) throws -> Date { try #require(TeachingWebsite.deadline(value, timeZone: "Asia/Shanghai").date) }

    @Test func urlPolicyExcludesLoginScriptsSubmissionsAndOtherOrigins() {
        #expect(TeachingWebsite.isPage(TeachingWebsite.courseURL("411")))
        #expect(TeachingWebsite.isDownload(URL(string: "https://selearning.nju.edu.cn/pluginfile.php/1/mod_folder/content/0/ch00.pptx")))
        for raw in ["http://selearning.nju.edu.cn/course/view.php?id=411", "https://selearning.nju.edu.cn.evil.invalid/course/view.php?id=411", "https://selearning.nju.edu.cn:8443/course/view.php?id=411", "https://selearning.nju.edu.cn/grade/report/index.php?id=411", "https://authserver.nju.edu.cn/authserver/login"] {
            #expect(!TeachingWebsite.isPage(URL(string: raw)))
        }
        #expect(!TeachingWebsite.isDownload(URL(string: "https://selearning.nju.edu.cn/pluginfile.php/1/assignsubmission_file/submission_files/0/private.zip")))
        #expect(!TeachingWebsite.allowsNavigation(URL(string: "https://unrelated.nju.edu.cn/")))
    }

    @Test func datesKeepExplicitTimeZonesAndRejectInvalidDates() throws {
        let shanghai = try date("2026年10月26日 Monday 18:00")
        let utc = try #require(TeachingWebsite.deadline("2026-10-26 10:00", timeZone: "UTC").date)
        #expect(shanghai == utc)
        #expect(!TeachingWebsite.deadline("2026年10月26日 Monday 18:00", timeZone: "Asia/Shanghai").allDay)
        #expect(TeachingWebsite.deadline("2026-10-26", timeZone: "Asia/Shanghai").allDay)
        for text in ["2026-02-30 18:00", "2026-13-01", "2026-10-26 25:00", "下周一交"] {
            #expect(TeachingWebsite.deadline(text, timeZone: "Asia/Shanghai").date == nil)
        }
    }

    @Test func bindingUsesSchemaSevenAndPreventsDuplicateRemoteCourses() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(repo.state.schemaVersion == 9)
        let decoded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: repo.root.appendingPathComponent("library.json")))
        #expect(decoded.teachingConnections == [connection])
        let duplicate = TeachingConnection(courseID: connection.courseID, remoteCourseID: "411", remoteTitle: "同一课程", accountID: "123")
        #expect(throws: (any Error).self) { try repo.saveTeachingConnection(duplicate) }
        try repo.deleteCourse(id: connection.courseID)
        #expect(repo.state.teachingConnections.isEmpty)
    }

    @Test func connectingTheSameCourseReusesItsBindingWithoutChangingImportedData() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, url) = try sample(root)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: date("2026-10-21"))
        var options = connection; options.includeHistory = true; options.includeExperiments = false
        try repo.saveTeachingConnection(options)
        try repo.finishTeachingUpdate(connection.id, messages: [TeachingSyncMessage("已有更新记录")], completed: true)
        let before = repo.state, index = repo.root.appendingPathComponent("library.json")
        let indexBytes = try Data(contentsOf: index)
        let original = try #require(before.teachingConnections.first)
        let request = TeachingConnection(courseID: connection.courseID, remoteCourseID: "411", remoteTitle: "重新读取的网站标题", accountID: "123")
        let reused = try repo.connectTeachingCourse(request)
        #expect(reused == original && reused.id != request.id)
        #expect(!reused.items.isEmpty && !reused.folders.isEmpty && reused.lastSyncAt != nil)
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == indexBytes)
        let material = try #require(repo.state.materials.first)
        #expect(try Data(contentsOf: repo.resolveURL(material)) == Data(contentsOf: url))
    }

    @Test func connectingAnAlreadyBoundSourceToAnotherCourseDoesNotChangeTheIndex() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = Course(name: "另一本地课程"); try repo.saveCourse(other)
        let before = repo.state, index = repo.root.appendingPathComponent("library.json")
        let indexBytes = try Data(contentsOf: index)
        let request = TeachingConnection(courseID: other.id, remoteCourseID: connection.remoteCourseID, remoteTitle: connection.remoteTitle, accountID: connection.accountID)
        do {
            _ = try repo.connectTeachingCourse(request)
            Issue.record("已绑定的网站课程不应被改绑。")
        } catch {
            #expect(error.localizedDescription.contains("数据库"))
        }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == indexBytes)
    }

    @Test func connectingNewSourcesSeparatesAccountsAndPreservesTheChosenCourse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-web-connect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "数据库", semester: "2026-2027学年 第1学期", teacher: "本地教师", colorHex: "#123456")
        try repo.saveCourse(course)
        let first = TeachingConnection(courseID: course.id, remoteCourseID: "411", remoteTitle: "数据库系统概论", accountID: "123")
        let second = TeachingConnection(courseID: course.id, remoteCourseID: "411", remoteTitle: "数据库系统概论", accountID: "456")
        #expect(try repo.connectTeachingCourse(first) == first)
        #expect(try repo.connectTeachingCourse(second) == second)
        #expect(repo.state.schemaVersion == 9 && repo.state.teachingConnections == [first, second])
        #expect(repo.state.courses == [course])
        let reopened = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: repo.root.appendingPathComponent("library.json")))
        #expect(reopened == repo.state)
    }

    @Test func repeatedDownloadsDoNotDuplicateAndVersionsPreserveLocalEditsAndLinks() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = activity(), (file, first) = try sample(root)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: a, file: file, downloadedURL: first)
        let original = try #require(repo.state.materials.first)
        let (sameFile, sameBytes) = try sample(root)
        #expect(try repo.syncTeachingFile(connectionID: connection.id, activity: a, file: sameFile, downloadedURL: sameBytes).hasPrefix("未变"))
        #expect(repo.state.materials.count == 1)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: a, page: page(), now: date("2026-10-21"))
        let archived = StudyTask(title: "已归档的提交记录", courseID: connection.courseID, materialIDs: [original.id], completedAt: try date("2026-10-20"), archivedAt: try date("2026-10-21"))
        try repo.savePlan(archived)
        let customFolder = try repo.createMaterialFolder(name: "我自己的分类", courseID: connection.courseID)
        var edited = original; edited.title = "我的讲义"; edited.tags = "重点"; edited.notes = "本地笔记"; edited.isFavorite = true
        try repo.updateMaterial(edited); try repo.moveMaterials(ids: [edited.id], to: customFolder.id, courseID: connection.courseID)
        let (_, changedBytes) = try sample(root, content: "new edition")
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: a, file: file, downloadedURL: changedBytes)
        let link = try #require(repo.state.teachingConnections.first?.items.first { $0.id.hasPrefix("file:") })
        let latest = try #require(repo.state.materials.first { $0.id == link.localID })
        #expect(latest.id != original.id)
        #expect(latest.title == "我的讲义" && latest.tags == "重点" && latest.notes == "本地笔记" && latest.isFavorite)
        #expect(latest.folderID == customFolder.id)
        #expect(latest.customOrder == 0)
        #expect(repo.state.tasks.first?.materialIDs == [latest.id])
        #expect(repo.state.tasks.first { $0.id == archived.id }?.materialIDs == [original.id])
        #expect(String(data: try Data(contentsOf: repo.resolveURL(original)), encoding: .utf8) == "lecture")
        #expect(repo.state.materialFolders.contains { $0.name == "历史版本" })
        #expect(repo.state.materials.count == 2)
    }

    @Test func deletedItemsStayIgnoredAndCanBeExplicitlyReintroduced() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, url) = try sample(root)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url)
        try repo.removeMaterials(ids: Set(repo.state.materials.map(\.id)))
        #expect(try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url).hasPrefix("忽略"))
        #expect(repo.state.materials.isEmpty)
        try repo.restoreIgnoredTeachingItems(connection.id)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url)
        #expect(repo.state.materials.count == 1)
    }

    @Test func assignmentsProduceOneDeadlineAndKeepCompletionAndExecutionEdits() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-10-21")
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: now)
        let original = try #require(repo.state.tasks.first)
        #expect(original.origin == .fixed && !original.hasExecutionTime)
        #expect(PlanCalendar.events(on: try date("2026-10-26"), plans: repo.state.tasks).filter(\.isDeadline).count == 1)
        var edited = original; edited.title = "自己的作业名"; edited.completedAt = now; edited.hasExecutionTime = true; edited.startsAt = now
        try repo.savePlan(edited)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026年10月27日 18:00"), now: now)
        let updated = try #require(repo.state.tasks.first)
        #expect(repo.state.tasks.count == 1 && updated.id == original.id)
        #expect(updated.title == edited.title && updated.completedAt == now && updated.hasExecutionTime)
        #expect(updated.deadline == (try date("2026-10-27 18:00")))
    }

    @Test func localDeadlineConflictsDoNotRepeatAndCanBeResolved() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-10-21")
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: now)
        var task = try #require(repo.state.tasks.first); task.deadline = try date("2026-10-25 18:00"); try repo.savePlan(task)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-28 18:00"), now: now)
        #expect(repo.state.tasks.first?.deadline == task.deadline)
        #expect(repo.state.teachingConnections.first?.items.first?.pendingDeadline != nil)
        try repo.resolveTeachingDeadline(connectionID: connection.id, key: "plan:5302", useWebsite: false)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-28 18:00"), now: now)
        #expect(repo.state.teachingConnections.first?.items.first?.pendingDeadline == nil)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-29 18:00"), now: now)
        try repo.resolveTeachingDeadline(connectionID: connection.id, key: "plan:5302", useWebsite: true)
        #expect(repo.state.tasks.first?.deadline == (try date("2026-10-29 18:00")))
    }

    @Test func missingAndAmbiguousDatesNeverInventOrEraseDeadlines() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: date("2026-10-21"))
        let deadline = repo.state.tasks.first?.deadline
        let result = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("下周一"), now: date("2026-10-21"))
        #expect(result.contains("待核对") && repo.state.tasks.first?.deadline == deadline)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(""), now: date("2026-10-21"))
        #expect(repo.state.tasks.first?.deadline == nil)
    }

    @Test func oldAssignmentsAndWrongAccountsDoNotPolluteTheLibrary() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-01 18:00"), now: date("2026-10-21"))
        #expect(repo.state.tasks.isEmpty)
        var other = page(); other.accountID = "another-account"
        #expect(throws: (any Error).self) { try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: other) }
        #expect(repo.state.tasks.isEmpty)
        var options = connection; options.includeHistory = true; try repo.saveTeachingConnection(options)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-01", submitted: true), now: date("2026-10-21"))
        #expect(repo.state.tasks.first?.isCompleted == true)
    }

    @Test func failedDownloadsCannotCreateRecordsAndDisconnectKeepsImportedData() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, url) = try sample(root, content: "<!doctype html><html>Login</html>")
        #expect(throws: (any Error).self) { try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url) }
        #expect(repo.state.materials.isEmpty && repo.state.materialFolders.isEmpty)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: date("2026-10-21"))
        try repo.disconnectTeachingWebsite(connection.id)
        #expect(repo.state.teachingConnections.isEmpty && repo.state.tasks.count == 1)
    }

    @Test func changingAnAllDayDeadlineToMidnightUpdatesItsDisplayKind() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-26"), now: date("2026-10-21"))
        let previous = repo.state.tasks.first?.deadline
        #expect(repo.state.tasks.first?.deadlineIsAllDay == true)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page("2026-10-26 00:00"), now: date("2026-10-21"))
        #expect(repo.state.tasks.first?.deadline == previous)
        #expect(repo.state.tasks.first?.deadlineIsAllDay == false)
    }

    @Test func backupRestoresSourceMappingsTogetherWithTheirFiles() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, url) = try sample(root)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url)
        _ = try repo.syncTeachingAssignment(connectionID: connection.id, activity: activity(), page: page(), now: date("2026-10-21"))
        let backup = root.appendingPathComponent("backup.teachshelfbackup"); try repo.backup(to: backup)
        let restored = try LibraryRepository(root: root.appendingPathComponent("restored")); try restored.restore(from: backup)
        #expect(restored.state == repo.state)
        let record = try #require(restored.state.materials.first)
        #expect(try Data(contentsOf: restored.resolveURL(record)) == Data(contentsOf: url))
    }

    @Test func indexWriteFailureRollsBackDownloadedCopiesAndMetadata() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = repo.state, (file, url) = try sample(root)
        let blocker = repo.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repo.syncTeachingFile(connectionID: connection.id, activity: activity(), file: file, downloadedURL: url) }
        #expect(repo.state == before)
        let enumerator = try #require(FileManager.default.enumerator(at: repo.root.appendingPathComponent("files"), includingPropertiesForKeys: [.isRegularFileKey]))
        #expect(enumerator.allObjects.compactMap { $0 as? URL }.allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true })
    }

    @Test func longAndSameNamedWebsiteFoldersRemainValidAndDistinct() throws {
        let (repo, connection, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, url) = try sample(root)
        var first = activity("folder", id: "5282"), second = activity("folder", id: "5283")
        first.title = String(repeating: "实验说明：章节/", count: 30); second.title = first.title
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: first, file: file, downloadedURL: url)
        _ = try repo.syncTeachingFile(connectionID: connection.id, activity: second, file: file, downloadedURL: url)
        #expect(repo.state.materials.count == 2)
        #expect(Set(repo.state.materials.compactMap(\.folderID)).count == 2)
        #expect(repo.state.materialFolders.allSatisfy { $0.name.utf8.count <= 120 && !$0.name.contains(":") && !$0.name.contains("/") })
        #expect(repo.state.materialFolders.filter { $0.name == "教学网站" }.count == 1)
    }
}
