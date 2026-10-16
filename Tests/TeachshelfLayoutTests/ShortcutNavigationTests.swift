import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct ShortcutNavigationTests {
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
