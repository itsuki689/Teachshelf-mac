import AppKit
import Foundation
import Testing
@testable import Teachshelf
@testable import TeachshelfCore

@Suite(.serialized) @MainActor
struct FileSystemWatcherTests {
    @Test func actualFileEventsRefreshTheStoreAndRetainSelection() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-watcher-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let course = Course(name: "监听测试"); try repo.saveCourse(course)
        let original = root.appendingPathComponent("lecture.txt")
        try Data("watcher".utf8).write(to: original)
        _ = try repo.importFiles(urls: [original], courseID: course.id, category: "课件", copy: true)
        let record = repo.state.materials[0]
        let store = AppStore(repository: repo, remembersLocation: false)
        store.selectedMaterialIDs = [record.id]
        let source = try repo.resolveURL(record), target = source.deletingLastPathComponent().appendingPathComponent("Finder renamed.txt")
        try fm.moveItem(at: source, to: target)
        for _ in 0..<40 {
            if store.state.materials[0].originalName == target.lastPathComponent { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(store.state.materials[0].originalName == target.lastPathComponent)
        #expect(store.selectedMaterialIDs == [record.id])
        try fm.moveItem(at: target, to: root.appendingPathComponent("outside.txt"))
        for _ in 0..<40 {
            if store.state.materials[0].isMissing == true { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(store.state.materials[0].isMissing == true)
        #expect(store.selectedMaterialIDs == [record.id])
    }

    @Test func switchingLibrariesRebindsTheWatcher() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-watch-switch-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let first = try LibraryRepository(root: root.appendingPathComponent("First"))
        let secondURL = root.appendingPathComponent("Second")
        var second: LibraryRepository? = try LibraryRepository(root: secondURL)
        let course = Course(name: "另一资料库"); try second!.saveCourse(course)
        let source = root.appendingPathComponent("file.txt"); try Data("file".utf8).write(to: source)
        _ = try second!.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true)
        let original = try second!.resolveURL(second!.state.materials[0]); second = nil
        let store = AppStore(repository: first, remembersLocation: false)
        await store.changeLibrary(to: secondURL, migrate: false)
        let target = original.deletingLastPathComponent().appendingPathComponent("new.txt")
        try fm.moveItem(at: original, to: target)
        for _ in 0..<40 {
            if store.state.materials.first?.originalName == "new.txt" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(store.state.materials.first?.originalName == "new.txt")
        #expect(first.state.materials.isEmpty)
    }
}
