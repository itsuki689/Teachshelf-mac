import Foundation
import Testing
import WebKit
import TeachshelfCore
@testable import Teachshelf

@MainActor @Suite(.serialized) struct TeachingUpdateFlowTests {
    private final class Transport: TeachingWebsiteTransport {
        var pages: [String: TeachingPage] = [:]
        var files: [String: URL] = [:]
        var loaded: URL?
        var opened: URL?
        var cancelAtDownload = false
        var fetchCount = 0
        func open(_ url: URL) { opened = url }
        func load(_ url: URL) async throws { loaded = url; try Task.checkCancellation() }
        func read() async throws -> TeachingPage {
            guard let key = loaded?.absoluteString, let page = pages[key] else { throw TeachingWebError.unreadable }
            return page
        }
        func fetch(_ file: TeachingFile) async throws -> URL {
            fetchCount += 1
            if cancelAtDownload { throw CancellationError() }
            guard let value = files[file.key] else { throw TeachingWebError.download }
            return value
        }
        func cleanDownload() {}
        func cancel() {}
    }
    private func setup() throws -> (AppStore, TeachingConnection, TeachingWebsiteController, Transport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-web-flow-\(UUID().uuidString)")
        let repo = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "数据库系统概论"); try repo.saveCourse(course)
        let connection = TeachingConnection(courseID: course.id, remoteCourseID: "411", remoteTitle: course.name, accountID: "123")
        try repo.saveTeachingConnection(connection)
        let store = AppStore(repository: repo, remembersLocation: false), transport = Transport()
        let controller = TeachingWebsiteController(root: repo.root, dataStore: .nonPersistent(), transport: transport)
        return (store, connection, controller, transport, root)
    }
    private func assignment() -> TeachingActivity {
        TeachingActivity(id: "5302", kind: "assign", title: "作业09", sectionID: "section-2", section: "作业", url: URL(string: "https://selearning.nju.edu.cn/mod/assign/view.php?id=5302")!)
    }
    private func installPages(_ transport: Transport, root: URL) throws {
        let activity = assignment()
        let file = TeachingFile(key: "notes.txt", name: "notes.txt", url: URL(string: "https://selearning.nju.edu.cn/pluginfile.php/1/mod_assign/introattachment/0/notes.txt")!)
        let bytes = root.appendingPathComponent("downloaded.txt"); try Data("Assignment notes".utf8).write(to: bytes)
        transport.files[file.key] = bytes
        transport.pages[TeachingWebsite.courseURL("411").absoluteString] = TeachingPage(accountID: "123", courseID: "411", title: "数据库", activities: [activity])
        transport.pages[activity.url.absoluteString] = TeachingPage(kind: "assign", accountID: "123", courseID: "411", files: [file], intro: "完成第九题", deadlineText: "2099-10-26 18:00")
    }

    @Test func updateCommitsAttachmentsAndOnePlanThenRepeatsWithoutDuplicates() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        controller.update(connection, store: store)
        #expect(store.isBusy && controller.updating)
        await controller.operation?.value
        #expect(!store.isBusy && !controller.updating)
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1)
        #expect(store.state.tasks.first?.materialIDs == store.state.materials.map(\.id))
        #expect(store.state.teachingConnections.first?.lastSyncAt != nil)
        #expect(controller.messages.allSatisfy { !$0.isIssue })
        controller.update(try #require(store.state.teachingConnections.first), store: store)
        await controller.operation?.value
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1)
        #expect(controller.status.contains("新增 0 项 · 更新 0 项"))
    }

    @Test func attachmentFailureStillCreatesTheKnownDeadlineAndCanBeRetried() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        let downloaded = transport.files.removeValue(forKey: "notes.txt")
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.tasks.count == 1 && store.state.tasks.first?.deadline != nil)
        #expect(store.state.materials.isEmpty && controller.messages.contains { $0.isIssue })
        transport.files["notes.txt"] = downloaded
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.tasks.count == 1 && store.state.materials.count == 1)
        #expect(store.state.tasks.first?.materialIDs == store.state.materials.map(\.id))
    }

    @Test func changedAccountPausesBeforeAnyImportAndReleasesBusyState() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        transport.pages[TeachingWebsite.courseURL("411").absoluteString]?.accountID = "456"
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.materials.isEmpty && store.state.tasks.isEmpty)
        #expect(!store.isBusy && !controller.updating)
        #expect(transport.opened == nil && controller.showWeb)
        #expect(controller.status.contains("账号不同"))
        #expect(store.state.teachingConnections.first?.lastSyncAt == nil)
    }

    @Test func cancellationDoesNotPublishAnEmptySuccessAndRetryWorks() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); transport.cancelAtDownload = true
        controller.update(connection, store: store); await controller.operation?.value
        #expect(!store.isBusy && store.state.materials.isEmpty && store.state.tasks.isEmpty)
        #expect(controller.status.contains("已取消更新"))
        #expect(store.state.teachingConnections.first?.lastSyncAt == nil)
        transport.cancelAtDownload = false
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1)
    }

    @Test func deletingAWebsitePlanAlsoSkipsNewAttachmentsUntilExplicitlyReintroduced() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        controller.update(connection, store: store); await controller.operation?.value
        try store.repository.deleteTasks(ids: Set(store.state.tasks.map(\.id))); store.reload()
        let previousDownloads = transport.fetchCount
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.tasks.isEmpty && transport.fetchCount == previousDownloads)
        try store.repository.restoreIgnoredTeachingItems(connection.id)
        controller.update(connection, store: store); await controller.operation?.value
        #expect(store.state.tasks.count == 1 && store.state.materials.count == 1)
    }
}
