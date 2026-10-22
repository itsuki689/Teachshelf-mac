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
        var redirects: [String: URL] = [:]
        func open(_ url: URL) { opened = url }
        func load(_ url: URL) async throws {
            loaded = url; try Task.checkCancellation()
            if let target = redirects[url.absoluteString] { throw TeachingWebError.directFile(target, target.lastPathComponent) }
        }
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


    private func run(_ controller: TeachingWebsiteController, _ connection: TeachingConnection, _ store: AppStore) async {
        controller.check([connection], store: store); await controller.operation?.value
        controller.applySelected(store: store); await controller.operation?.value
    }

    @Test func checkingDoesNotDownloadOrMutateAndConfirmationIsIncremental() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        let index = store.repository.root.appendingPathComponent("library.json"), before = try Data(contentsOf: index)
        controller.check([connection], store: store)
        #expect(store.isBusy && controller.checking)
        await controller.operation?.value
        #expect(controller.proposals.count == 2 && controller.selectedProposalIDs.count == 2)
        #expect(store.state.materials.isEmpty && store.state.tasks.isEmpty && transport.fetchCount == 0)
        #expect(try Data(contentsOf: index) == before)
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1 && transport.fetchCount == 1)
        #expect(store.state.tasks.first?.materialIDs == store.state.materials.map(\.id))
        #expect(store.state.teachingConnections.first?.lastSyncAt != nil)
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        #expect(controller.proposals.isEmpty && controller.skippedFiles == 1 && transport.fetchCount == 1)
        #expect(!store.isBusy && !controller.updating)
    }

    @Test func attachmentFailureStillCreatesTheKnownDeadlineAndCanBeRetried() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        let downloaded = transport.files.removeValue(forKey: "notes.txt")
        await run(controller, connection, store)
        #expect(store.state.tasks.count == 1 && store.state.tasks.first?.deadline != nil)
        #expect(store.state.materials.isEmpty && controller.messages.contains { $0.isIssue })
        transport.files["notes.txt"] = downloaded
        await run(controller, store.state.teachingConnections[0], store)
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1)
        #expect(store.state.tasks.first?.materialIDs == store.state.materials.map(\.id))
    }

    @Test func changedAccountPausesBeforeAnyImportAndReleasesBusyState() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        transport.pages[TeachingWebsite.courseURL("411").absoluteString]?.accountID = "456"
        controller.check([connection], store: store); await controller.operation?.value
        #expect(store.state.materials.isEmpty && store.state.tasks.isEmpty && transport.fetchCount == 0)
        #expect(!store.isBusy && !controller.updating && controller.messages.contains { $0.text.contains("账号不同") })
        #expect(store.state.teachingConnections.first?.lastSyncAt == nil)
    }

    @Test func cancellationKeepsTheReviewAndRetryDoesNotRequireAnotherCheck() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); transport.cancelAtDownload = true
        await run(controller, connection, store)
        #expect(!store.isBusy && store.state.materials.isEmpty && store.state.tasks.isEmpty)
        #expect(controller.status.contains("暂停") && controller.hasReview)
        #expect(store.state.teachingConnections.first?.lastSyncAt == nil)
        transport.cancelAtDownload = false
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.materials.count == 1 && store.state.tasks.count == 1)
    }

    @Test func deletingAWebsitePlanAlsoSkipsNewAttachmentsUntilExplicitlyReintroduced() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); await run(controller, connection, store)
        try store.repository.deleteTasks(ids: Set(store.state.tasks.map(\.id))); store.reload()
        let previousDownloads = transport.fetchCount
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        #expect(store.state.tasks.isEmpty && controller.proposals.isEmpty && transport.fetchCount == previousDownloads)
        try store.repository.restoreIgnoredTeachingItems(connection.id); store.reload()
        await run(controller, store.state.teachingConnections[0], store)
        #expect(store.state.tasks.count == 1 && store.state.materials.count == 1 && transport.fetchCount == previousDownloads)
    }

    @Test func partialSelectionOnlyImportsCheckedRowsAndCanLinkAttachmentsLater() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        controller.check([connection], store: store); await controller.operation?.value
        controller.selectedProposalIDs = Set(controller.proposals.filter { $0.file != nil }.map(\.id))
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.materials.count == 1 && store.state.tasks.isEmpty && controller.proposals.count == 1)
        controller.selectAllProposals(true); controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.tasks.first?.materialIDs == store.state.materials.map(\.id) && transport.fetchCount == 1)
    }

    @Test func missingFilesRequireExplicitOptInAndIgnoredRecordsNeverDownload() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); await run(controller, connection, store)
        let material = try #require(store.state.materials.first)
        try FileManager.default.removeItem(at: store.repository.resolveURL(material))
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        #expect(controller.proposals.count == 1 && controller.proposals.first?.repair == true && controller.selectedProposalIDs.isEmpty)
        #expect(transport.fetchCount == 1)
        controller.selectAllProposals(true); controller.applySelected(store: store); await controller.operation?.value
        #expect(transport.fetchCount == 2)
        let latestID = try #require(store.state.teachingConnections[0].items.first { $0.id.hasPrefix("file:") }?.localID)
        try store.repository.removeMaterials(ids: [latestID]); store.reload()
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        #expect(controller.proposals.isEmpty && transport.fetchCount == 2)
    }

    @Test func editingThePlanAfterCheckingPreventsAnUnreviewedOverwrite() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); await run(controller, connection, store)
        transport.pages[assignment().url.absoluteString]?.deadlineText = "2099-10-27 18:00"
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        var edited = try #require(store.state.tasks.first); edited.title = "用户刚修改的计划"
        try store.repository.savePlan(edited); store.reload()
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.tasks.first == edited && controller.hasReview && controller.messages.contains { $0.isIssue })
        #expect(transport.fetchCount == 1)
    }

    @Test(arguments: [true, false]) func deadlineConflictIsReviewedBeforeAnyLibraryChange(adopt: Bool) async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); await run(controller, connection, store)
        var edited = try #require(store.state.tasks.first)
        edited.deadline = TeachingWebsite.deadline("2099-10-28 18:00", timeZone: "Asia/Shanghai").date
        try store.repository.savePlan(edited); store.reload()
        transport.pages[assignment().url.absoluteString]?.deadlineText = "2099-10-27 18:00"
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        let proposal = try #require(controller.proposals.first)
        #expect(proposal.change?.pendingDeadline != nil)
        #expect(store.state.teachingConnections[0].items.first { $0.id.hasPrefix("plan:") }?.pendingDeadline == nil)
        if adopt { controller.adoptWebsiteDeadlineIDs.insert(proposal.id) }
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.tasks.first?.deadline == (adopt ? TeachingWebsite.deadline("2099-10-27 18:00", timeZone: "Asia/Shanghai").date : edited.deadline))
        #expect(store.state.teachingConnections[0].items.first { $0.id.hasPrefix("plan:") }?.pendingDeadline == nil)
    }

    private func secondCourse(_ store: AppStore, _ transport: Transport) throws -> TeachingConnection {
        let course = Course(name: "软件工程"); try store.repository.saveCourse(course)
        let connection = TeachingConnection(courseID: course.id, remoteCourseID: "408", remoteTitle: course.name, accountID: "123")
        try store.repository.saveTeachingConnection(connection); store.reload()
        let activity = TeachingActivity(id: "6", kind: "assign", title: "第二门课作业", url: URL(string: "https://selearning.nju.edu.cn/mod/assign/view.php?id=6")!)
        transport.pages[TeachingWebsite.courseURL("408").absoluteString] = TeachingPage(accountID: "123", courseID: "408", title: course.name, activities: [activity])
        var page = transport.pages[assignment().url.absoluteString]!
        page.courseID = "408"; transport.pages[activity.url.absoluteString] = page
        return connection
    }

    @Test func globalReviewGroupsCoursesAndOnlyAppliesSelectedCourseRows() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); let second = try secondCourse(store, transport)
        controller.check(store.state.teachingConnections, store: store, global: true); await controller.operation?.value
        #expect(controller.reviewIsGlobal && controller.reviewSources.count == 2 && controller.proposals.count == 4 && transport.fetchCount == 0)
        controller.selectedProposalIDs = Set(controller.proposals.filter { $0.connection.id == connection.id }.map(\.id))
        controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.tasks.count == 1 && store.state.tasks.first?.courseID == connection.courseID && transport.fetchCount == 1)
        controller.selectAllProposals(true); controller.applySelected(store: store); await controller.operation?.value
        #expect(store.state.tasks.count == 2 && store.state.materials.count == 2 && transport.fetchCount == 2)
        #expect(Set(store.state.tasks.compactMap(\.courseID)) == [connection.courseID, second.courseID])
    }

    @Test func oneUnavailableCourseDoesNotHideOtherGlobalCandidatesAndArchivedCoursesAreExcluded() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root); let second = try secondCourse(store, transport)
        transport.pages.removeValue(forKey: TeachingWebsite.courseURL("408").absoluteString)
        controller.check(store.state.teachingConnections, store: store, global: true); await controller.operation?.value
        #expect(controller.proposals.count == 2 && controller.messages.contains { $0.isIssue } && transport.fetchCount == 0)
        var archived = try #require(store.state.courses.first { $0.id == second.courseID }); archived.isArchived = true
        try store.repository.saveCourse(archived); store.reload()
        controller.check(store.state.teachingConnections, store: store, global: true); await controller.operation?.value
        #expect(controller.reviewSources.map(\.id) == [connection.id] && !controller.messages.contains { $0.isIssue })
    }

    @Test func changedConnectionAfterReviewBlocksDownloads() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        controller.check([connection], store: store); await controller.operation?.value
        var changed = connection; changed.includeMaterials = false
        try store.repository.saveTeachingConnection(changed); store.reload()
        controller.applySelected(store: store); await controller.operation?.value
        #expect(transport.fetchCount == 0 && store.state.tasks.isEmpty && controller.messages.contains { $0.isIssue })
    }

    @Test func directResourceIsReviewedWithoutFetchingAndKnownContentIsNeverRetransferred() async throws {
        let (store, connection, controller, transport, root) = try setup(); defer { controller.close(); try? FileManager.default.removeItem(at: root) }
        try installPages(transport, root: root)
        let resource = TeachingActivity(id: "8", kind: "resource", title: "讲义", url: URL(string: "https://selearning.nju.edu.cn/mod/resource/view.php?id=8")!)
        let file = URL(string: "https://selearning.nju.edu.cn/pluginfile.php/1/mod_resource/content/1/notes.txt")!
        transport.pages[TeachingWebsite.courseURL("411").absoluteString]?.activities = [resource]
        transport.redirects[resource.url.absoluteString] = file
        controller.check([connection], store: store); await controller.operation?.value
        #expect(transport.fetchCount == 0 && controller.proposals.count == 1 && controller.downloadedFiles == 0)
        controller.applySelected(store: store); await controller.operation?.value
        #expect(controller.downloadedFiles == 1 && transport.fetchCount == 1)
        try Data("Teacher replaced the same file".utf8).write(to: transport.files["notes.txt"]!)
        controller.check(store.state.teachingConnections, store: store); await controller.operation?.value
        #expect(controller.proposals.isEmpty && controller.skippedFiles == 1 && transport.fetchCount == 1)
    }
}
