import Foundation
import Testing
@testable import TeachshelfCore

@Suite final class PlanMCPServiceTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPPlans-\(UUID())")
    deinit { try? FileManager.default.removeItem(at: root) }
    func service() throws -> PlanMCPService { PlanMCPService(repository: try LibraryRepository(root: root)) }
    func create(_ service: PlanMCPService, _ fields: [String: Any] = ["title": "复习计划", "content": "第一步\n第二步"]) throws -> [String: Any] {
        try service.call(name: "teachshelf_create_plan", arguments: ["library_id": service.libraryID, "request_id": UUID().uuidString, "fields": fields])
    }
    func target(_ service: PlanMCPService) throws -> [String: Any] {
        let plan = try #require(service.repository.state.tasks.first)
        return ["library_id": service.libraryID, "id": plan.id.uuidString, "expected_revision": try PlanMCPService.revision(plan)]
    }
    @Test func partialUpdatePreservesFieldsAndUndoIsDurable() throws {
        let s = try service(); _ = try create(s)
        let original = s.repository.state.tasks[0]
        var a = try target(s); a["patch"] = ["title": "新标题"]
        let result = try s.call(name: "teachshelf_update_plan", arguments: a)
        #expect(s.repository.state.tasks[0].content == original.content)
        #expect(!s.repository.state.tasks[0].hasExecutionTime)
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_update_plan", arguments: a) }
        _ = try s.call(name: "teachshelf_undo_change", arguments: ["library_id": s.libraryID, "change_id": result["change_id"]!])
        #expect(s.repository.state.tasks[0] == original)
        let disk = try LibraryRepository.decode(Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(disk.tasks == s.repository.state.tasks)
    }
    @Test func invalidInputsAreAtomicAndUnknownFieldsRejected() throws {
        let s = try service(); _ = try create(s)
        let original = s.repository.state
        for patch: [String: Any] in [["title": "  "], ["bogus": "x"], ["title": NSNull()], ["deadline": "2026-10-23"], ["is_all_day": 1], ["material_ids": [UUID().uuidString]], ["repeat_rule": ["frequency": "daily", "interval": 367]], ["color_hex": "invalid"]] {
            var a = try target(s); a["patch"] = patch
            #expect(throws: (any Error).self) { try s.call(name: "teachshelf_update_plan", arguments: a) }
            #expect(s.repository.state.tasks == original.tasks)
        }
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_list_plans", arguments: ["limit": 101]) }
    }
    @Test func wrongLibraryAndRepeatedCreateNeverWrite() throws {
        let s = try service(), id = UUID().uuidString
        let a: [String: Any] = ["library_id": s.libraryID, "request_id": id, "fields": ["title": "一次"]]
        _ = try s.call(name: "teachshelf_create_plan", arguments: a)
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_create_plan", arguments: a) }
        var wrong = try target(s); wrong["library_id"] = "different"; wrong["patch"] = ["title": "不应保存"]
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_update_plan", arguments: wrong) }
        #expect(s.repository.state.tasks.count == 1 && s.repository.state.tasks[0].title == "一次")
    }
    @Test func timedPlanNullableFieldsAndStatus() throws {
        let s = try service()
        _ = try create(s, ["title": "带截止时间", "starts_at": "2026-10-23T19:00:00+08:00", "ends_at": "2026-10-23T20:00:00+08:00", "deadline": "2026-10-24T23:59:00+08:00", "is_all_day": false])
        #expect(s.repository.state.tasks[0].hasExecutionTime)
        var a = try target(s); a["patch"] = ["deadline": NSNull(), "has_execution_time": false]
        _ = try s.call(name: "teachshelf_update_plan", arguments: a)
        #expect(s.repository.state.tasks[0].deadline == nil && s.repository.state.tasks[0].endsAt == nil)
        for action in ["complete", "reopen", "cancel", "restore"] {
            var a = try target(s); a["action"] = action
            _ = try s.call(name: "teachshelf_set_plan_status", arguments: a)
            #expect(s.repository.state.tasks[0].isCompleted == (action == "complete"))
            #expect(s.repository.state.tasks[0].isCancelled == (action == "cancel"))
        }
    }
    @Test func occurrenceEditPreservesSeriesAndResolvesFractionalAnchor() throws {
        let s = try service()
        _ = try create(s, ["title": "每周计划", "starts_at": "2026-10-12T19:00:00.123+08:00", "repeat_rule": ["frequency": "weekly", "until": "2026-11-30"]])
        var a = try target(s); a["scope"] = "thisOccurrence"; a["original_date"] = "2026-10-19"; a["patch"] = ["title": "本次标题", "content": "新增内容"]
        _ = try s.call(name: "teachshelf_update_plan", arguments: a)
        let parent = s.repository.state.tasks[0]
        #expect(parent.title == "每周计划" && parent.exceptions.count == 1)
        let single = try s.call(name: "teachshelf_get_plan", arguments: ["id": parent.id.uuidString, "original_date": "2026-10-19"])["plan"] as! [String: Any]
        #expect(single["title"] as? String == "本次标题")
        #expect(try single["revision"] as? String == PlanMCPService.revision(parent))
        a = try target(s); a["scope"] = "thisOccurrence"; a["original_date"] = "2026-10-20"; a["patch"] = ["title": "无效"]
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_update_plan", arguments: a) }
        var complete = try target(s); complete["scope"] = "thisOccurrence"; complete["original_date"] = "2026-10-19"; complete["action"] = "complete"
        _ = try s.call(name: "teachshelf_set_plan_status", arguments: complete)
        #expect(!s.repository.state.tasks[0].isCompleted)
        #expect(s.repository.state.tasks[0].exceptions[0].completedAt != nil)
        let events = try s.call(name: "teachshelf_list_occurrences", arguments: ["from": "2026-10-19", "to": "2026-10-25"])["events"] as! [[String: Any]]
        #expect(events.count == 1 && events[0]["title"] as? String == "本次标题")
    }
    @Test func splitSeriesAndUndoRestoreAllAffectedPlans() throws {
        let s = try service()
        _ = try create(s, ["title": "每周", "starts_at": "2026-10-12T19:00:00+08:00", "repeat_rule": ["frequency": "weekly"]])
        let original = s.repository.state.tasks
        var a = try target(s); a["scope"] = "thisAndFuture"; a["original_date"] = "2026-10-19"; a["patch"] = ["content": "后续新内容"]
        let result = try s.call(name: "teachshelf_update_plan", arguments: a)
        #expect(s.repository.state.tasks.count == 2)
        _ = try s.call(name: "teachshelf_undo_change", arguments: ["library_id": s.libraryID, "change_id": result["change_id"]!])
        #expect(s.repository.state.tasks == original)
    }
    @Test func deleteUndoAndUndoConflict() throws {
        let s = try service(); _ = try create(s)
        let original = s.repository.state.tasks[0]
        let deleted = try s.call(name: "teachshelf_delete_plan", arguments: target(s))
        #expect(s.repository.state.tasks.isEmpty)
        _ = try s.call(name: "teachshelf_undo_change", arguments: ["library_id": s.libraryID, "change_id": deleted["change_id"]!])
        var a = try target(s); a["patch"] = ["content": "remote"]
        let changed = try s.call(name: "teachshelf_update_plan", arguments: a)
        var newer = s.repository.state.tasks[0]; newer.title = "UI saved later"; try s.repository.savePlan(newer)
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_undo_change", arguments: ["library_id": s.libraryID, "change_id": changed["change_id"]!]) }
        #expect(s.repository.state.tasks[0].title == newer.title && s.repository.state.tasks[0].id == original.id)
    }
    @Test func archiveRequiresUnarchiveBeforeEditing() throws {
        let s = try service(); _ = try create(s, ["title": "过去", "starts_at": "2020-01-01T00:00:00Z"])
        var a = try target(s); a["action"] = "archive"
        _ = try s.call(name: "teachshelf_set_plan_status", arguments: a)
        a = try target(s); a["patch"] = ["title": "不能保存"]
        #expect(throws: (any Error).self) { try s.call(name: "teachshelf_update_plan", arguments: a) }
        a = try target(s); a["action"] = "unarchive"
        _ = try s.call(name: "teachshelf_set_plan_status", arguments: a)
        #expect(!s.repository.state.tasks[0].isArchived)
    }
}
