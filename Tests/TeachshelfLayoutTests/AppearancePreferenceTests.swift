import Combine
import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct AppearancePreferenceTests {
    @Test func appearancePublishesOnlyAfterSavingAndPreservesTheCurrentWorkspaceOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-preference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let course = Course(name: "当前课程")
        try repository.saveCourse(course)
        let source = root.appendingPathComponent("notes.md")
        try Data("当前正在编辑的资料".utf8).write(to: source)
        _ = try repository.importFiles(urls: [source], courseID: course.id, category: "笔记", copy: true)
        let material = try #require(repository.state.materials.first)
        let folder = try repository.createMaterialFolder(name: "复习", courseID: course.id, materialIDs: [material.id])
        let store = AppStore(repository: repository, remembersLocation: false)
        store.navigate(to: .course(course.id)); store.openMaterialFolder(folder.id)
        store.materialEditing = true
        store.selectMaterials([material.id])
        store.search = "notes"; store.categoryFilter = "笔记"; store.formatFilter = "文档"
        let location = store.workspaceLocation, history = store.navigationHistory
        let date = store.scheduleSelection.selectedDate
        let index = root.appendingPathComponent("library.json")
        var publishedAfterSaving: [Bool] = []
        let observation = store.$state.dropFirst().sink { value in
            let saved = try? JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: index))
            publishedAfterSaving.append(saved == value)
        }
        defer { observation.cancel() }

        try store.setAppearance("dark")
        #expect(store.state.appearance == "dark" && repository.state.appearance == "dark")
        #expect(publishedAfterSaving == [true])
        try store.setAppearance("dark")
        #expect(publishedAfterSaving == [true])
        store.isBusy = true
        try store.setAppearance("light")
        store.isBusy = false
        #expect(store.state.appearance == "dark")

        let bytes = try Data(contentsOf: index)
        let backup = root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.setAppearance("light") }
        #expect(store.state.appearance == "dark" && repository.state.appearance == "dark")
        #expect(try Data(contentsOf: index) == bytes)
        #expect(publishedAfterSaving == [true])
        #expect(store.workspaceLocation == location)
        #expect(store.navigationHistory.back == history.back && store.navigationHistory.forward == history.forward)
        #expect(store.materialEditing && store.selectedMaterialIDs == [material.id])
        #expect(store.search == "notes" && store.categoryFilter == "笔记" && store.formatFilter == "文档")
        #expect(store.scheduleSelection.selectedDate == date)
    }
}
