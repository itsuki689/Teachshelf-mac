import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct ShortcutNavigationTests {
    @Test func historyReturnsToNestedFoldersAndASeparatePageWithoutChangingTheScheduleDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "历史记录", semester: "2026 秋季")
        try repo.saveCourse(course)
        let outer = try repo.createMaterialFolder(name: "课件", courseID: course.id)
        let inner = try repo.createMaterialFolder(name: "第一章", courseID: course.id, parentID: outer.id)
        let store = AppStore(repository: repo, remembersLocation: false)
        let date = store.scheduleSelection.selectedDate
        #expect(!store.canGoBack && !store.canGoForward)
        store.navigate(to: .course(course.id))
        store.openMaterialFolder(outer.id)
        store.openMaterialFolder(inner.id)
        store.navigate(to: .schedule)
        store.semester = "其他学期"
        store.goBack()
        #expect(store.navigation == .course(course.id))
        #expect(store.materialFolderID == inner.id)
        #expect(store.semester == course.semester)
        #expect(store.workspaceCourseID == course.id)
        store.goBack()
        #expect(store.materialFolderID == outer.id)
        store.goForward()
        #expect(store.materialFolderID == inner.id)
        store.goForward()
        #expect(store.navigation == .schedule)
        #expect(store.scheduleSelection.selectedDate == date)
        #expect(!store.canGoForward)
    }

    @Test func blockedHistoryDoesNotConsumeEntriesAndNewNavigationDiscardsForwardHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-guard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: try LibraryRepository(root: root), remembersLocation: false)
        store.navigate(to: .favorites)
        store.navigate(to: .tasks)
        store.beforeLeavingMaterial = { false }
        store.goBack()
        #expect(store.navigation == .tasks)
        #expect(store.canGoBack && !store.canGoForward)
        store.beforeLeavingMaterial = nil
        store.goBack()
        #expect(store.navigation == .favorites)
        store.navigate(to: .favorites) // Reselecting the same page does not create history.
        #expect(store.canGoForward)
        store.navigate(to: .homework)
        #expect(!store.canGoForward)
        store.goBack()
        #expect(store.navigation == .favorites)
        store.goBack()
        #expect(store.navigation == .all)
        #expect(!store.canGoBack)
    }

    @Test func historyDoesNotReopenDeletedFoldersOrCourses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-deleted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "临时课程")
        try repo.saveCourse(course)
        let folder = try repo.createMaterialFolder(name: "临时分组", courseID: course.id)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .course(course.id)); store.openMaterialFolder(folder.id)
        store.navigate(to: .settings)
        try repo.dissolveMaterialFolder(id: folder.id); store.reload()
        store.goBack()
        #expect(store.navigation == .course(course.id))
        #expect(store.materialFolderID == nil)
        store.navigate(to: .settings)
        try repo.deleteCourse(id: course.id); store.reload()
        store.goBack()
        #expect(store.navigation == .all)
    }

    @Test func changingLibraryClearsSessionHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("first"))
        let nextRoot = root.appendingPathComponent("second", isDirectory: true)
        try repo.copyLibrary(to: nextRoot)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .schedule); store.navigate(to: .tasks); store.goBack()
        #expect(store.canGoBack && store.canGoForward)
        await store.changeLibrary(to: nextRoot, migrate: false)
        #expect(store.repository.root == nextRoot)
        #expect(store.navigation == .all)
        #expect(!store.canGoBack && !store.canGoForward)
    }

    @Test func pendingShortcutOpensItsOwnListWithoutChangingTheScheduleOrBypassingUnsavedEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let store = AppStore(repository: repository, remembersLocation: false)
        store.scheduleSelection.planFilter = .completed
        let date = store.scheduleSelection.selectedDate
        store.beforeLeavingMaterial = { false }
        store.navigate(to: .tasks)
        #expect(store.navigation == .all)
        #expect(store.scheduleSelection.planFilter == .completed)
        store.beforeLeavingMaterial = nil
        store.navigate(to: .tasks)
        #expect(store.navigation == .tasks)
        #expect(store.title == "待完成计划")
        #expect(store.scheduleSelection.planFilter == .completed)
        store.navigate(to: .schedule)
        #expect(store.navigation == .schedule)
        #expect(store.scheduleSelection.selectedDate == date)
    }

    @Test func homeworkRemembersBothACourseAndTheExplicitPublicFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-homework-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let first = Course(name: "第一门课"), second = Course(name: "第二门课")
        try repository.saveCourse(first); try repository.saveCourse(second)
        let store = AppStore(repository: repository, remembersLocation: false)
        #expect(store.prepareWorkspaceCourse() == first.id)
        store.selectWorkspaceCourse(second.id)
        store.navigate(to: .all); store.navigate(to: .homework)
        #expect(store.prepareWorkspaceCourse() == second.id)
        store.selectWorkspaceCourse(nil)
        store.navigate(to: .tasks); store.navigate(to: .homework)
        #expect(store.prepareWorkspaceCourse() == nil)
        store.navigate(to: .course(first.id)); store.navigate(to: .homework)
        #expect(store.prepareWorkspaceCourse() == first.id)
    }
}
