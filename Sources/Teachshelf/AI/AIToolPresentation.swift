import Foundation
import TeachshelfCore

struct AIResultLink: Identifiable {
    let id: UUID
    let kind: WorkspaceSearchKind
    let title: String
}

/// Presentation comes from validated arguments and local records, never model-provided approval prose.
enum AIToolPresentation {
    static let titles: [String: String] = [
        "context": "读取资料库概况", "list_plans": "查询计划", "get_plan": "读取计划", "list_occurrences": "查询日程",
        "search_materials": "查找关联资料", "create_plan": "新建计划", "update_plan": "修改计划", "set_plan_status": "更改计划状态",
        "delete_plan": "删除计划", "undo_change": "撤销计划修改", "list_courses": "查询课程", "get_course": "读取课程",
        "create_course": "新建课程", "update_course": "修改课程", "delete_course": "删除课程", "list_materials": "查询资料",
        "get_material": "读取资料", "update_material": "修改资料", "move_materials": "移动资料", "remove_materials": "移除资料记录",
        "list_material_folders": "查询文件夹", "get_material_folder": "读取文件夹", "create_material_folder": "新建文件夹",
        "update_material_folder": "修改文件夹", "dissolve_material_folder": "解散文件夹"
    ]
    static func title(_ name: String) -> String { titles[name.replacingOccurrences(of: "teachshelf_", with: "")] ?? "未知操作" }
    static let labels: [String: String] = [
        "title": "标题", "name": "名称", "content": "正文", "kind": "类型", "course_id": "课程", "material_ids": "关联资料",
        "location": "地点", "starts_at": "开始时间", "ends_at": "结束时间", "deadline": "截止时间", "has_execution_time": "设置执行时间",
        "is_all_day": "全天", "deadline_is_all_day": "全天截止", "show_in_month": "月视图显示", "completion_required": "需要完成",
        "origin": "日程类型", "color_hex": "颜色", "repeat_rule": "重复规则", "frequency": "频率", "interval": "间隔", "until": "重复结束日期",
        "semester": "学期", "teacher": "教师", "archived": "归档", "category": "分类", "tags": "标签", "notes": "备注", "favorite": "收藏",
        "filename": "实际文件名", "folder_id": "目标文件夹", "parent_id": "上级文件夹", "scope": "作用范围", "original_date": "原始发生日期", "action": "状态"
    ]
    static func preview(name: String, arguments: [String: Any], state: LibraryState) -> String {
        func resolve(_ raw: String) -> String {
            guard let id = UUID(uuidString: raw) else { return raw }
            return state.courses.first { $0.id == id }?.name ?? state.materials.first { $0.id == id }?.title ??
                state.materialFolders.first { $0.id == id }?.name ?? state.tasks.first { $0.id == id }?.title ?? "未找到的记录（\(raw)）"
        }
        func display(_ value: Any, key: String) -> String {
            if value is NSNull { return ["course_id": "未分类", "folder_id": "课程根目录", "parent_id": "课程根目录"][key] ?? "清空" }
            if let object = value as? [String: Any] { return object.keys.sorted().map { "\(labels[$0] ?? $0)：\(display(object[$0]!, key: $0))" }.joined(separator: "；") }
            if let values = value as? [String] { return values.map(resolve).joined(separator: "、") }
            if let string = value as? String {
                let meanings = ["all": "整个计划", "thisOccurrence": "仅本次", "thisAndFuture": "本次及以后", "complete": "完成", "reopen": "未完成", "cancel": "取消", "restore": "恢复", "archive": "归档", "unarchive": "取消归档", "daily": "每天", "weekly": "每周", "monthly": "每月", "activity": "活动", "fixed": "固定安排"]
                if ["scope", "action", "frequency", "origin"].contains(key) { return meanings[string] ?? string }
                return ["course_id", "folder_id", "parent_id"].contains(key) ? resolve(string) : string
            }
            if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "是" : "否") : number.stringValue }
            return String(describing: value)
        }
        var lines: [String] = []
        if let id = arguments["id"] as? String { lines.append("对象：\(resolve(id))") }
        if let ids = arguments["ids"] as? [String] { lines.append("\(ids.count) 份资料：\(ids.map(resolve).joined(separator: "、"))") }
        let fields = (arguments["patch"] as? [String: Any]) ?? (arguments["fields"] as? [String: Any]) ?? [:]
        let direct = arguments.filter { labels[$0.key] != nil }
        for (key, value) in fields.merging(direct) { _, b in b }.sorted(by: { $0.key < $1.key }) {
            lines.append("\(labels[key] ?? key)：\(display(value, key: key))")
        }
        if ["teachshelf_delete_plan", "teachshelf_update_plan", "teachshelf_set_plan_status"].contains(name), arguments["scope"] == nil { lines.append("作用范围：整个计划（包括重复日程）") }
        if name == "teachshelf_delete_course" {
            if let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) {
                lines.append("影响 \(state.materials.filter { $0.courseID == id }.count) 份资料、\(state.materialFolders.filter { $0.courseID == id }.count) 个文件夹分组。")
            }
            lines.append("课程分组将被删除，资料移到未分类；实际文件及计划保留。此操作不能通过计划撤销恢复。") }
        if name == "teachshelf_remove_materials" { lines.append("移除记录并解除计划关联，实际文件保留。此操作不能通过计划撤销恢复。") }
        if name == "teachshelf_dissolve_material_folder" || name == "teachshelf_update_material_folder" {
            if let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) {
                var ids: Set<UUID> = [id]
                var previous = 0
                while previous != ids.count { previous = ids.count; ids.formUnion(state.materialFolders.filter { $0.parentID.map(ids.contains) == true }.map(\.id)) }
                let count = state.materials.filter { $0.folderID.map(ids.contains) == true }.count
                lines.append("包含 \(max(ids.count - 1, 0)) 个子文件夹、\(count) 份资料。移动或重命名会同步物理目录。")
            }
            if name == "teachshelf_dissolve_material_folder" { lines.append("解除整个子树的分组，资料移到上一级，文件保留。此操作不能通过计划撤销恢复。") }
        }
        return lines.joined(separator: "\n")
    }
    static func links(_ result: [String: Any]) -> [AIResultLink] {
        var links: [AIResultLink] = []
        for (singular, plural, kind) in [("plan", "plans", WorkspaceSearchKind.plan), ("course", "courses", .course), ("material", "materials", .material)] {
            let items = (result[plural] as? [[String: Any]] ?? []) + (result[singular].map { [$0 as? [String: Any] ?? [:]] } ?? [])
            for item in items {
                if let raw = item["id"] as? String, let id = UUID(uuidString: raw), let title = (item["title"] ?? item["name"]) as? String, !links.contains(where: { $0.id == id }) {
                    links.append(AIResultLink(id: id, kind: kind, title: title))
                }
            }
        }
        return Array(links.prefix(12))
    }
}
