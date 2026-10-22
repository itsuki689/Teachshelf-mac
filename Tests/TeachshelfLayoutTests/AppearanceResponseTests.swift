import Combine
import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor @Suite(.serialized) struct AppearanceResponseTests {
    @Test func aRequestPublishesItsTargetImmediatelyAndSavingPreservesTheCurrentWorkspaceAndDrafts() async throws {
        let (store, course, material, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        store.navigate(to: .course(course.id))
        store.selectedMaterialIDs = [material.id]
        store.search = "正在输入的资料搜索"
        store.workspaceSearchQuery = "尚未提交的全局搜索"
        store.showingWorkspaceSearch = true
        store.materialEditing = true
        var courseDraft = course
        courseDraft.name = "尚未保存的课程名称"
        store.courseToEdit = courseDraft
        store.showingCourseEditor = true
        let planDraft = StudyTask(title: "尚未保存的计划", content: "编辑中的备注", courseID: course.id)
        store.toolbarPlanDraft = ToolbarPlanDraft(task: planDraft, isNew: true)
        var leaveAttempts = 0
        store.beforeLeavingMaterial = { leaveAttempts += 1; return false }
        let history = store.navigationHistory.back
        var expected = store.state
        expected.appearance = "dark"

        store.requestAppearance("dark")
        #expect(store.appearancePreference.mode == "dark")
        #expect(store.appearancePreference.isSaving)
        #expect(store.state.appearance == "light")
        #expect(store.repository.state.appearance == "light")
        await store.flushAppearance()

        #expect(store.repository.state.appearance == "dark")
        #expect(store.state == expected)
        #expect(!store.appearancePreference.isSaving)
        #expect(store.selectedMaterialIDs == [material.id])
        #expect(store.selectedMaterial == material)
        #expect(store.navigation == .course(course.id))
        #expect(store.navigationHistory.back == history)
        #expect(store.search == "正在输入的资料搜索")
        #expect(store.workspaceSearchQuery == "尚未提交的全局搜索")
        #expect(store.showingWorkspaceSearch && store.materialEditing && store.showingCourseEditor)
        #expect(store.courseToEdit == courseDraft)
        #expect(store.toolbarPlanDraft?.task == planDraft)
        #expect(store.toolbarPlanDraft?.isNew == true)
        #expect(leaveAttempts == 0)
        #expect(try diskAppearance(in: store.repository.root) == "dark")
    }

    @Test func aLibraryOperationWaitsForTheLatestQueuedAppearanceToReachDisk() async throws {
        let (store, _, _, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = store.repository, gate = SaveCompletionGate(), observations = OperationObservations()
        defer { gate.release() }
        var supersededCompletions: [String] = []
        store.appearancePreference.request("dark", save: {
            try repository.saveAppearance($0)
            gate.pauseAfterWrite()
        }, didSave: { supersededCompletions.append($0) }, didFail: { error in
            Issue.record("Unexpected appearance save error: \(error)")
        })
        await gate.waitUntilWritten()
        store.requestAppearance("system")
        #expect(store.appearancePreference.mode == "system")
        #expect(repository.state.appearance == "dark")

        var operation: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            operation = Task { @MainActor in
                started.resume()
                await store.runOperation("正在等待最新外观") {
                    let index = repository.root.appendingPathComponent("library.json")
                    let bytes = try Data(contentsOf: index)
                    let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    observations.record(try #require(document?["appearance"] as? String))
                    return "已检查最新外观"
                }
            }
        }
        #expect(store.isBusy)
        #expect(observations.modes.isEmpty)
        #expect(store.status == "正在等待最新外观")
        gate.release()
        await operation?.value

        #expect(observations.modes == ["system"])
        #expect(repository.state.appearance == "system")
        #expect(store.state.appearance == "system")
        #expect(store.appearancePreference.mode == "system")
        #expect(supersededCompletions.isEmpty)
        #expect(!store.isBusy && !store.appearancePreference.isSaving)
        #expect(store.status == "已检查最新外观")
    }

    @Test func reloadingAnIntermediateDiskThemeNeverPublishesItOverANewerRequestedTarget() async throws {
        let (store, _, _, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = store.repository, gate = SaveCompletionGate()
        defer { gate.release() }
        var published: [String] = [], supersededCompletions: [String] = []
        let subscription = store.$state.sink { published.append($0.appearance) }
        defer { subscription.cancel() }
        store.appearancePreference.request("dark", save: {
            try repository.saveAppearance($0)
            gate.pauseAfterWrite()
        }, didSave: { supersededCompletions.append($0) }, didFail: { error in
            Issue.record("Unexpected appearance save error: \(error)")
        })
        await gate.waitUntilWritten()
        #expect(repository.state.appearance == "dark")
        #expect(try diskAppearance(in: repository.root) == "dark")
        store.requestAppearance("system")
        #expect(store.appearancePreference.isSaving)

        // The first write is durable, but its closure has not returned. A normal
        // library reload must preserve the old committed UI theme until the latest write wins.
        store.reload()
        #expect(store.state.appearance == "light")
        #expect(store.appearancePreference.mode == "system")
        #expect(!published.contains("dark"))
        gate.release()
        await store.flushAppearance()

        #expect(store.state.appearance == "system")
        #expect(store.appearancePreference.mode == "system")
        #expect(repository.state.appearance == "system")
        #expect(!published.contains("dark"))
        #expect(published.last == "system")
        #expect(supersededCompletions.isEmpty)
    }

    private func setup() throws -> (AppStore, Course, MaterialRecord, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-appearance-response-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "响应测试课程")
        try repository.saveCourse(course)
        let source = root.appendingPathComponent("notes.txt")
        try Data("Notes".utf8).write(to: source)
        _ = try repository.importFiles(urls: [source], courseID: course.id, category: "课件", copy: false)
        try repository.saveAppearance("light")
        let material = try #require(repository.state.materials.first)
        return (AppStore(repository: repository, remembersLocation: false), course, material, root)
    }

    private func diskAppearance(in root: URL) throws -> String {
        let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        return try #require(document?["appearance"] as? String)
    }

    /// Pause after the repository transaction has released its lock; only the
    /// completion is held so the main actor can safely reload or queue another save.
    private final class SaveCompletionGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var written = false, released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func pauseAfterWrite() {
            condition.lock()
            written = true
            let ready = waiters
            waiters.removeAll()
            condition.unlock()
            ready.forEach { $0.resume() }
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
        }

        func waitUntilWritten() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if written { condition.unlock(); continuation.resume() }
                else { waiters.append(continuation); condition.unlock() }
            }
        }

        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    private final class OperationObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedModes: [String] = []

        var modes: [String] { lock.lock(); defer { lock.unlock() }; return recordedModes }
        func record(_ mode: String) { lock.lock(); recordedModes.append(mode); lock.unlock() }
    }
}
