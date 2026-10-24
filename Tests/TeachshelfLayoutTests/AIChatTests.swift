import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor private final class ScriptedAI: AICompleting {
    var requests: [[[String: Any]]] = []
    let respond: (Int, [[String: Any]]) async throws -> AIReply
    init(_ respond: @escaping (Int, [[String: Any]]) async throws -> AIReply) { self.respond = respond }
    func complete(messages: [[String: Any]], tools: [[String: Any]], toolChoice: Any) async throws -> AIReply {
        requests.append(messages)
        #expect(tools.count == TeachshelfMCPTools.definitions.count)
        return try await respond(requests.count, messages)
    }
}
@Suite(.serialized) @MainActor final class AIChatTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIChat-\(UUID())")
    let defaultsName = "AIChatTests-\(UUID())"
    var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }
    deinit { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
    func store() throws -> AppStore { AppStore(repository: try LibraryRepository(root: root), remembersLocation: false) }
    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw PlanMCPError("等待测试状态超时")
    }
    static func reply(_ name: String? = nil, _ arguments: [String: Any] = [:], id: String = UUID().uuidString) throws -> AIReply {
        var message: [String: Any] = ["role": "assistant", "content": "完成"]
        if let name {
            message["content"] = NSNull()
            message["tool_calls"] = [["id": id, "type": "function", "function": ["name": name, "arguments": try AIChatController.json(arguments)]]]
        }
        return try AIChatClient.parse(JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": name == nil ? "stop" : "tool_calls"]]]))
    }
    @Test func planConversationConfirmsWritesRefreshesUIAndSupportsUndo() async throws {
        let store = try store()
        let course = Course(name: "数据库"); try store.repository.saveCourse(course)
        let draft = StudyTask(title: "复习数据库", courseID: course.id); try store.repository.savePlan(draft); store.reload()
        let plan = try #require(store.state.tasks.first)
        let service = PlanMCPService(repository: store.repository)
        let client = ScriptedAI { turn, messages in
            switch turn {
            case 1: return try Self.reply("teachshelf_context")
            case 2:
                #expect(messages.last?["role"] as? String == "tool")
                return try Self.reply("teachshelf_get_plan", ["id": plan.id.uuidString])
            case 3:
                let content = try #require(messages.last?["content"] as? String)
                let result = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
                let record = result["plan"] as! [String: Any]
                return try Self.reply("teachshelf_update_plan", ["library_id": service.libraryID, "id": plan.id.uuidString, "expected_revision": record["revision"]!, "patch": ["title": "复习事务与索引", "location": "教118"]])
            default: return try Self.reply()
            }
        }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        chat.captureContext(courseID: course.id, materialIDs: [])
        chat.send("把复习计划改成复习事务与索引，地点教118")
        try await waitFor { chat.pending != nil }
        #expect(store.state.tasks.first?.title == "复习数据库")
        #expect(chat.pending?.detail.contains("教118") == true)
        #expect(client.requests[0].last?["content"] as? String != nil)
        #expect((client.requests[0].last?["content"] as? String)?.contains(course.id.uuidString) == true)
        chat.decide(true)
        try await waitFor { !chat.isRunning }
        #expect(store.state.tasks.first?.title == "复习事务与索引")
        #expect(store.state.tasks.first?.location == "教118")
        #expect(store.canUndoPlanChange)
        let receipt = try #require(chat.items.first { $0.undoArguments != nil })
        #expect(receipt.outcome == "已保存" && receipt.links.first?.id == plan.id)
        chat.send("再查一下课程")
        try await waitFor { !chat.isRunning }
        #expect(client.requests.last!.filter { $0["role"] as? String == "user" }.count == 2)
        chat.undo(receipt)
        try await waitFor { !chat.isRunning }
        #expect(store.state.tasks.first == plan)
        #expect(chat.items.first { $0.id == receipt.id }?.outcome == "已撤销")
    }
    @Test func rejectedDeletionAndCancelledApprovalNeverMutate() async throws {
        let store = try store(), course = Course(name: "保留课程")
        try store.repository.saveCourse(course); store.reload()
        let service = LibraryMCPService(repository: store.repository)
        let arguments: [String: Any] = ["library_id": service.libraryID, "expected_library_revision": try service.context()["library_revision"]!, "id": course.id.uuidString]
        let client = ScriptedAI { turn, _ in try Self.reply(turn % 2 == 1 ? "teachshelf_delete_course" : nil, arguments) }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        chat.send("删除课程"); try await waitFor { chat.pending != nil }
        #expect(chat.pending?.detail.contains("实际文件及计划保留") == true)
        chat.decide(false); try await waitFor { !chat.isRunning }
        #expect(store.state.courses == [course])
        chat.send("删除课程"); try await waitFor { chat.pending != nil }
        chat.stop(); try await waitFor { !chat.isRunning }
        #expect(chat.pending == nil && store.state.courses == [course])
        #expect(chat.items.contains { $0.outcome == "已取消，未执行" })
    }
    @Test func staleConfirmationAndOpenEditorsCannotOverwriteChanges() async throws {
        let store = try store(), plan = StudyTask(title: "原计划")
        try store.repository.savePlan(plan); store.reload()
        let service = PlanMCPService(repository: store.repository)
        let client = ScriptedAI { turn, _ in
            try Self.reply(turn % 2 == 1 ? "teachshelf_update_plan" : nil, ["library_id": service.libraryID, "id": plan.id.uuidString, "expected_revision": try PlanMCPService.revision(plan), "patch": ["title": "AI 修改"]])
        }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        chat.send("修改计划"); try await waitFor { chat.pending != nil }
        var updated = plan; updated.title = "用户的新修改"; try store.repository.savePlan(updated); store.reload()
        chat.decide(true); try await waitFor { !chat.isRunning }
        #expect(store.state.tasks.first?.title == "用户的新修改")
        #expect(chat.items.contains { $0.outcome.hasPrefix("未执行：") })
        try store.repository.savePlan(plan); store.reload()
        chat.send("再修改"); try await waitFor { chat.pending != nil }
        store.editingPlanCounts[plan.id] = 1
        chat.decide(true); try await waitFor { !chat.isRunning }
        #expect(store.state.tasks.first == plan)
    }
    @Test func cancelledNetworkAndSwitchedLibraryRejectLateToolCalls() async throws {
        let store = try store()
        var continuation: CheckedContinuation<AIReply, Error>?
        let client = ScriptedAI { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        for switchLibrary in [false, true] {
            let service = PlanMCPService(repository: store.repository)
            chat.send("添加计划")
            try await waitFor { continuation != nil }
            if switchLibrary { store.repository = try LibraryRepository(root: root.appendingPathComponent("Second")); store.reload() }
            else { chat.stop() }
            let next = continuation; continuation = nil
            next?.resume(returning: try Self.reply("teachshelf_create_plan", ["library_id": service.libraryID, "request_id": UUID().uuidString, "fields": ["title": "不应创建"]]))
            try await waitFor { !chat.isRunning }
            #expect(chat.pending == nil && store.state.tasks.isEmpty && service.repository.state.tasks.isEmpty)
        }
    }
    @Test func malformedAndUnknownToolsReturnErrorsWithoutApproval() async throws {
        let store = try store()
        let client = ScriptedAI { turn, _ in
            switch turn {
            case 1: return try Self.reply("execute_shell", ["command": "anything"])
            case 2: return try Self.reply("teachshelf_create_course", ["fields": ["name": "参数缺失"]])
            default: return try Self.reply()
            }
        }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        chat.send("测试"); try await waitFor { !chat.isRunning }
        #expect(chat.pending == nil && store.state.courses.isEmpty)
        #expect(chat.items.filter { $0.outcome.hasPrefix("未执行：") }.count == 2)
        #expect(client.requests[2].filter { $0["role"] as? String == "tool" }.count == 2)
    }
    @Test func physicalFolderOperationsUseSharedExecutor() async throws {
        let store = try store(), course = Course(name: "数学")
        try store.repository.saveCourse(course); store.reload()
        let service = LibraryMCPService(repository: store.repository)
        let folderID = UUID()
        let client = ScriptedAI { turn, _ in
            try Self.reply(turn == 1 ? "teachshelf_create_material_folder" : nil,
                ["library_id": service.libraryID, "expected_library_revision": try service.context()["library_revision"]!, "request_id": folderID.uuidString, "name": "复习", "course_id": course.id.uuidString])
        }
        let chat = AIChatController(store: store, defaults: defaults, provider: { _ in client })
        chat.send("创建复习文件夹"); try await waitFor { chat.pending != nil }
        chat.decide(true); try await waitFor { !chat.isRunning }
        #expect(store.state.materialFolders.first?.id == folderID)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let names = files.compactMap { ($0 as? URL)?.lastPathComponent }
        #expect(names.contains("复习"))
        #expect(chat.items.contains { $0.outcome == "已保存" })
    }
    @Test func parserRejectsPartialOrDuplicateCallsAndAcceptsReasoningServers() throws {
        let call: [String: Any] = ["id": "call1", "type": "function", "function": ["name": "teachshelf_context", "arguments": "{}"]]
        for (reason, calls) in [("length", [call]), ("tool_calls", [call, call])] {
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["role": "assistant", "tool_calls": calls]]]])
            #expect(throws: (any Error).self) { try AIChatClient.parse(data) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "reasoning_content": "server reasoning", "content": NSNull(), "tool_calls": [call]]]]])
        let reply = try AIChatClient.parse(data)
        #expect(reply.calls.count == 1 && reply.message["reasoning_content"] as? String == "server reasoning")
    }
    @Test func approvalPreviewPreservesLiteralFieldsAndShowsDefaultScope() throws {
        let store = try store(), plan = StudyTask(title: "原计划")
        try store.repository.savePlan(plan); store.reload()
        let detail = AIToolPresentation.preview(name: "teachshelf_update_plan", arguments: ["id": plan.id.uuidString, "patch": ["title": "all", "location": "weekly"]], state: store.state)
        #expect(detail.contains("标题：all"))
        #expect(detail.contains("地点：weekly"))
        #expect(detail.contains("作用范围：整个计划"))
    }
    @Test func endpointValidationAndPersistenceNeverIncludeCredentials() throws {
        for endpoint in ["https://example.com/v1", "https://example.com/v1/", "https://example.com/v1/chat/completions"] {
            let config = AIConfiguration(endpoint: endpoint, model: "test-model")
            #expect(try config.completionURL().absoluteString == "https://example.com/v1/chat/completions")
            try config.save(defaults: defaults)
            #expect(AIConfiguration.load(defaults: defaults) == config)
        }
        for endpoint in ["file:///tmp/a", "https://user:password@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "invalid"] {
            #expect(throws: (any Error).self) { try AIConfiguration(endpoint: endpoint, model: "m").completionURL() }
        }
        #expect(AIConfiguration(endpoint: "http://127.0.0.1:8000/v1", model: "local").isConfigured)
        let stored = try #require(defaults.data(forKey: "aiAssistantConfiguration"))
        let object = try JSONSerialization.jsonObject(with: stored) as! [String: Any]
        #expect(Set(object.keys) == ["endpoint", "model", "reasoningDisabled"])
    }
}
