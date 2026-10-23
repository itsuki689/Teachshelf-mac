import AppKit
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor @Suite(.serialized) struct ToolbarTeachingUpdateTests {
    private enum Blocker: String, CaseIterable {
        case busy, noConnections, courseEditor, importSheet, planEditor, websiteSheet, replacedRepository
    }

    @Test func anAllowedRequestOnlyOpensGlobalReviewAndRepeatedPresentationIsRejected() throws {
        let (store, repository, connection, root) = try setup()
        defer { store.beforeLeavingMaterial = nil; try? FileManager.default.removeItem(at: root) }
        let before = store.state
        store.navigation = .favorites
        store.teachingConnectionToOpen = connection.id
        var leaveChecks = 0
        store.beforeLeavingMaterial = {
            leaveChecks += 1
            #expect(!store.showingTeachingWebsite)
            #expect(!store.teachingUpdateAll)
            return true
        }

        #expect(store.presentToolbarTeachingUpdate(in: repository))
        #expect(store.showingTeachingWebsite)
        #expect(store.teachingUpdateAll)
        #expect(store.teachingConnectionToOpen == nil)
        #expect(store.navigation == .favorites)
        #expect(store.state == before)
        #expect(repository.state == before)
        #expect(leaveChecks == 1)
        #expect(!store.presentToolbarTeachingUpdate(in: repository))
        #expect(leaveChecks == 1)
    }

    @Test func ineligibleRequestsDoNotAskToLeaveOrChangeTheExistingPresentation() throws {
        for blocker in Blocker.allCases {
            let (store, repository, connection, root) = try setup()
            defer { store.beforeLeavingMaterial = nil; try? FileManager.default.removeItem(at: root) }
            let replacement = try LibraryRepository(root: root.appendingPathComponent("other-library"))
            try replacement.saveCourse(try #require(repository.state.courses.first))
            try replacement.saveTeachingConnection(connection)
            store.teachingConnectionToOpen = connection.id
            apply(blocker, to: store, replacement: replacement)
            var leaveChecks = 0
            store.beforeLeavingMaterial = { leaveChecks += 1; return true }

            #expect(!store.presentToolbarTeachingUpdate(in: repository), "\(blocker)")
            #expect(leaveChecks == 0, "\(blocker)")
            #expect(!store.teachingUpdateAll, "\(blocker)")
            #expect(store.teachingConnectionToOpen == connection.id, "\(blocker)")
            #expect(store.showingTeachingWebsite == (blocker == .websiteSheet), "\(blocker)")
        }
    }

    @Test func cancellingUnsavedEditsDoesNotOpenReviewOrChangeTheCurrentCourse() throws {
        let (store, repository, connection, root) = try setup()
        defer { store.beforeLeavingMaterial = nil; try? FileManager.default.removeItem(at: root) }
        store.navigation = .course(connection.courseID)
        store.teachingConnectionToOpen = connection.id
        let before = store.state
        var leaveChecks = 0
        store.beforeLeavingMaterial = { leaveChecks += 1; return false }

        #expect(!store.presentToolbarTeachingUpdate(in: repository))
        #expect(leaveChecks == 1)
        #expect(!store.showingTeachingWebsite)
        #expect(!store.teachingUpdateAll)
        #expect(store.teachingConnectionToOpen == connection.id)
        #expect(store.navigation == .course(connection.courseID))
        #expect(store.state == before)
    }

    @Test func eligibilityIsRecheckedAfterTheUnsavedEditsCallbackReturns() throws {
        for blocker in Blocker.allCases {
            let (store, repository, connection, root) = try setup()
            defer { store.beforeLeavingMaterial = nil; try? FileManager.default.removeItem(at: root) }
            let replacement = try LibraryRepository(root: root.appendingPathComponent("other-library"))
            try replacement.saveCourse(try #require(repository.state.courses.first))
            try replacement.saveTeachingConnection(connection)
            store.teachingConnectionToOpen = connection.id
            var leaveChecks = 0
            store.beforeLeavingMaterial = {
                leaveChecks += 1
                apply(blocker, to: store, replacement: replacement)
                return true
            }

            #expect(!store.presentToolbarTeachingUpdate(in: repository), "\(blocker)")
            #expect(leaveChecks == 1, "\(blocker)")
            #expect(!store.teachingUpdateAll, "\(blocker)")
            #expect(store.teachingConnectionToOpen == connection.id, "\(blocker)")
            #expect(store.showingTeachingWebsite == (blocker == .websiteSheet), "\(blocker)")
        }
    }

    private func apply(_ blocker: Blocker, to store: AppStore, replacement: LibraryRepository) {
        switch blocker {
        case .busy: store.isBusy = true
        case .noConnections: store.state.teachingConnections = []
        case .courseEditor: store.showingCourseEditor = true
        case .importSheet: store.showingImport = true
        case .planEditor: store.toolbarPlanDraft = ToolbarPlanDraft(task: StudyTask(title: "编辑计划"))
        case .websiteSheet: store.showingTeachingWebsite = true
        case .replacedRepository:
            // A request belongs to its original repository, even after another library is opened.
            store.repository = replacement
            store.reload()
        }
    }

    private func setup() throws -> (AppStore, LibraryRepository, TeachingConnection, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-toolbar-update-\(UUID())")
        let repository = try LibraryRepository(root: root)
        let course = Course(name: "更新课程")
        try repository.saveCourse(course)
        let connection = TeachingConnection(courseID: course.id, remoteCourseID: "411", remoteTitle: course.name, accountID: "123")
        try repository.saveTeachingConnection(connection)
        return (AppStore(repository: repository, remembersLocation: false), repository, connection, root)
    }
}
