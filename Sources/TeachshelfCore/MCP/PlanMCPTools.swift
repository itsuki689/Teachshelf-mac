import Foundation
import CoreFoundation

public struct PlanMCPError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The schema is also enforced server-side; clients are not trusted to validate arguments.
public enum PlanMCPTools {
    static func string(_ description: String = "") -> [String: Any] { ["type": "string", "description": description, "maxLength": 200_000] }
    static func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    static func nullable(_ schema: [String: Any]) -> [String: Any] { ["anyOf": [schema, ["type": "null"]]] }
    static let boolean: [String: Any] = ["type": "boolean"]
    static let date = string("RFC3339 时间，必须含时区，如 2026-10-23T09:00:00+08:00。")
    static let civilDate = string("Asia/Shanghai 的日期，格式 YYYY-MM-DD。")
    static let uuid = string("UUID；必须从查询结果获取关联 ID，不要猜测。")
    static let fields: [String: Any] = [
        "title": ["type": "string", "minLength": 1, "maxLength": 500],
        "content": string("计划正文，纯文本或 Markdown。"), "kind": string("例如 作业、考试、自主规划。"),
        "course_id": nullable(uuid), "material_ids": ["type": "array", "items": uuid, "maxItems": 500],
        "location": string(), "starts_at": date, "ends_at": nullable(date), "deadline": nullable(date),
        "has_execution_time": boolean, "is_all_day": boolean, "deadline_is_all_day": boolean,
        "show_in_month": boolean, "completion_required": boolean,
        "origin": choice(["activity", "fixed"]), "color_hex": nullable(string("六位 HEX，如 #34AADC；null 恢复继承。")),
        "repeat_rule": nullable(object([
            "frequency": choice(["daily", "weekly", "monthly"]),
            "interval": ["type": "integer", "minimum": 1, "maximum": 366], "until": nullable(civilDate)
        ], required: ["frequency"]))
    ]
    static let target: [String: Any] = [
        "library_id": string("teachshelf_context 返回的资料库标识。"), "id": uuid,
        "expected_revision": string("最近一次读取返回的 revision；冲突后重新读取，不能盲目重试。"),
        "scope": choice(["all", "thisOccurrence", "thisAndFuture"]),
        "original_date": civilDate
    ]
    public static let writeNames: Set<String> = ["teachshelf_create_plan", "teachshelf_update_plan", "teachshelf_set_plan_status", "teachshelf_delete_plan", "teachshelf_undo_change"]
    public static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": object(properties, required: required),
             "annotations": ["readOnlyHint": !writeNames.contains(name), "destructiveHint": writeNames.contains(name), "openWorldHint": false]]
        }
        let guarded = ["library_id", "id", "expected_revision"]
        return [
            tool("teachshelf_context", "先调用本工具，获取当前资料库、课程 ID、北京时间和使用规则。仅操作课屿计划，不执行命令或读取资料文件。", [:]),
            tool("teachshelf_list_plans", "搜索计划（默认仅未完成、未取消、未归档）；返回 ID、revision 和摘要。编辑前调用 get_plan 查看正文。分页 offset/limit。", ["query": string(), "course_id": uuid, "status": choice(["active", "completed", "cancelled", "archived", "all"]), "offset": ["type": "integer", "minimum": 0, "maximum": 1_000_000], "limit": ["type": "integer", "minimum": 1, "maximum": 100]]),
            tool("teachshelf_get_plan", "读取完整计划及 revision。可给 original_date 查看重复计划某一次的有效内容，revision 始终属于整组。", ["id": uuid, "original_date": civilDate], ["id"]),
            tool("teachshelf_list_occurrences", "按北京时间查询日程与截止事件，包含重复计划和临时变更。from/to 均为包含端点的日期，最多 31 天；同一计划可同时有执行与截止事件。", ["from": civilDate, "to": civilDate, "course_id": uuid], ["from", "to"]),
            tool("teachshelf_search_materials", "按标题查找可关联的资料 ID；不返回文件内容或磁盘路径。", ["query": string(), "course_id": uuid], ["query"]),
            tool("teachshelf_create_plan", "新建计划。request_id 为客户端生成的 UUID，重试必须复用，避免重复创建。fields 至少有 title；默认没有执行时间，时间默认为非全天。成功后返回 change_id，可撤销。", ["library_id": string(), "request_id": uuid, "fields": object(fields, required: ["title"])], ["library_id", "request_id", "fields"]),
            tool("teachshelf_update_plan", "局部更新计划：只修改 patch 中的字段，null 清空可空字段。scope 默认为 all；本次/本次及以后必须提供 original_date。仅本次不能修改 repeat_rule 或 origin。修改执行时间时可同时更新 ends_at。", target.merging(["patch": object(fields)]) { _, b in b }, guarded + ["patch"]),
            tool("teachshelf_set_plan_status", "设置完成、未完成、取消、恢复、归档或取消归档。完成/未完成/恢复支持 all 和 thisOccurrence；取消另支持 thisAndFuture；归档操作只允许 all。restore 恢复取消状态，保留本次其他修改。", target.merging(["action": choice(["complete", "reopen", "cancel", "restore", "archive", "unarchive"])]) { _, b in b }, guarded + ["action"]),
            tool("teachshelf_delete_plan", "删除整组或本次及以后；仅本次等同于取消该次。请按用户指定的范围执行。返回 change_id 可撤销。", target, guarded),
            tool("teachshelf_undo_change", "撤销本次应用会话中最近 50 次 MCP 修改之一；如相关计划之后又被修改，会拒绝撤销，避免覆盖新内容。", ["library_id": string(), "change_id": uuid], ["library_id", "change_id"])
        ]
    }

    public static func validate(_ value: Any, schema: [String: Any], path: String = "arguments") throws {
        if let variants = schema["anyOf"] as? [[String: Any]] {
            if variants.contains(where: { (try? validate(value, schema: $0, path: path)) != nil }) { return }
            throw PlanMCPError("\(path) 类型不正确。")
        }
        func fail() throws { throw PlanMCPError("\(path) 不符合参数要求。") }
        switch schema["type"] as? String {
        case "object":
            guard let value = value as? [String: Any], let props = schema["properties"] as? [String: [String: Any]] else { return try fail() }
            guard Set(value.keys).isSubset(of: Set(props.keys)), (schema["required"] as? [String] ?? []).allSatisfy({ value[$0] != nil }) else { return try fail() }
            for (key, item) in value { try validate(item, schema: props[key]!, path: "\(path).\(key)") }
        case "string":
            guard let value = value as? String, value.count >= (schema["minLength"] as? Int ?? 0), value.count <= (schema["maxLength"] as? Int ?? 200_000) else { return try fail() }
            if let choices = schema["enum"] as? [String], !choices.contains(value) { return try fail() }
        case "boolean":
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return try fail() }
        case "integer":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? 0),
                  n.doubleValue <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? 1_000_000) else { return try fail() }
        case "array":
            guard let items = value as? [Any], items.count <= (schema["maxItems"] as? Int ?? 500), let itemSchema = schema["items"] as? [String: Any] else { return try fail() }
            for item in items { try validate(item, schema: itemSchema, path: path) }
        case "null": guard value is NSNull else { return try fail() }
        default: try fail()
        }
    }
}
