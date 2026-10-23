import Foundation
import Testing
import TeachshelfCore
import TeachshelfMCPKit
@testable import Teachshelf

@Suite(.serialized) @MainActor final class MCPControllerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPUI-\(UUID())")
    deinit { try? FileManager.default.removeItem(at: root) }
    @Test func remoteMutationRefreshesUIAndHonorsDraftBusyAndLibraryGuards() async throws {
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let plan = StudyTask(title: "Original"); try repository.savePlan(plan)
        let store = AppStore(repository: repository, remembersLocation: false)
        let config = root.appendingPathComponent("Config/config.json")
        try MCPConfiguration(port: 42191, token: MCPConfiguration.newToken()).save(to: config)
        let controller = MCPController(store: store, configURL: config)
        defer { controller.configure(enabled: false) }
        let service = PlanMCPService(repository: repository)
        func update(_ revision: String, library: String? = nil) async throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "teachshelf_update_plan", "arguments": ["library_id": library ?? service.libraryID, "id": plan.id.uuidString, "expected_revision": revision, "patch": ["title": "Remote"]]]]
            let data = try #require(await controller.handle(JSONSerialization.data(withJSONObject: request)))
            return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["result"] as! [String: Any]
        }
        let revision = try PlanMCPService.revision(repository.state.tasks[0])
        store.editingPlanCounts[plan.id] = 1
        #expect(try await update(revision)["isError"] as? Bool == true)
        store.editingPlanCounts = [:]; store.isBusy = true
        #expect(try await update(revision)["isError"] as? Bool == true)
        store.isBusy = false
        #expect(try await update(revision)["isError"] as? Bool == false)
        #expect(store.state.tasks[0].title == "Remote" && store.canUndoPlanChange)
        store.undoPlanChange()
        #expect(store.state.tasks[0] == plan)
        store.repository = try LibraryRepository(root: root.appendingPathComponent("Second")); store.reload()
        #expect(try await update(revision)["isError"] as? Bool == true)
        #expect(store.repository.state.tasks.isEmpty)
    }
    @Test func libraryWritesHonorEditorsAndReloadWithoutPlanUndo() async throws {
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let course = Course(name: "数学"); try repository.saveCourse(course)
        let store = AppStore(repository: repository, remembersLocation: false)
        let configURL = root.appendingPathComponent("Config/config.json")
        try MCPConfiguration(port: 42193, token: MCPConfiguration.newToken()).save(to: configURL)
        let controller = MCPController(store: store, configURL: configURL)
        defer { controller.configure(enabled: false) }
        let service = LibraryMCPService(repository: repository)
        let revision = try service.context()["library_revision"] as! String
        func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let data = try #require(await controller.handle(JSONSerialization.data(withJSONObject: request)))
            return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["result"] as! [String: Any]
        }
        let arguments: [String: Any] = ["library_id": service.libraryID, "expected_library_revision": revision, "id": course.id.uuidString, "patch": ["name": "高等数学"]]
        let context = try await call("teachshelf_context", [:])["structuredContent"] as! [String: Any]
        #expect(context["library_revision"] as? String == revision)
        for keyPath in [\AppStore.showingCourseEditor, \.showingImport, \.showingTeachingWebsite, \.isBusy] {
            store[keyPath: keyPath] = true
            #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == true)
            store[keyPath: keyPath] = false
        }
        for keyPath in [\AppStore.editingMaterialCounts, \.editingFolderCounts, \.editingPlanCounts] {
            store[keyPath: keyPath] = [UUID(): 1]
            #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == true)
            store[keyPath: keyPath] = [:]
        }
        store.materialFolderSheetCount = 1
        #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == true)
        // Reads remain available while an editor is open.
        #expect(try await call("teachshelf_get_course", ["id": course.id.uuidString])["isError"] as? Bool == false)
        store.materialFolderSheetCount = 0
        #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == false)
        #expect(store.state.courses[0].name == "高等数学" && !store.canUndoPlanChange && !store.isBusy)
        #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == true)
        store.repository = try LibraryRepository(root: root.appendingPathComponent("Second")); store.reload()
        #expect(try await call("teachshelf_update_course", arguments)["isError"] as? Bool == true)
        #expect(store.state.courses.isEmpty)
    }
    @Test func tokenRotationAndToggleRestartTheListener() async throws {
        let store = AppStore(repository: try LibraryRepository(root: root.appendingPathComponent("Library")), remembersLocation: false)
        let configURL = root.appendingPathComponent("Config/config.json")
        let token = try MCPConfiguration.newToken()
        try MCPConfiguration(port: 42192, token: token).save(to: configURL)
        let controller = MCPController(store: store, configURL: configURL)
        defer { controller.configure(enabled: false) }
        func ready() async throws {
            for _ in 0..<100 {
                if controller.connectionStatus.hasPrefix("正在监听") { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("\(controller.connectionStatus)")
        }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        func ping(_ token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: controller.configuration!.endpoint)!)
            request.httpMethod = "POST"; request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        try await ready(); #expect(try await ping(token) == 200)
        controller.configure(rotateToken: true)
        try await ready()
        #expect(try await ping(token) == 401)
        #expect(try await ping(controller.configuration!.token) == 200)
        controller.configure(enabled: false); controller.configure(enabled: true)
        try await ready()
        #expect(try await ping(controller.configuration!.token) == 200)
    }

}
