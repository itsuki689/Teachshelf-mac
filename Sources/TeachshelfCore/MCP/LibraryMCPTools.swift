import Foundation

/// Catalog shared by HTTP and stdio; existing plan tool names remain compatible.
public enum TeachshelfMCPTools {
    public static var definitions: [[String: Any]] { PlanMCPTools.definitions + LibraryMCPTools.definitions }
    public static var writeNames: Set<String> { PlanMCPTools.writeNames.union(LibraryMCPTools.writeNames) }
}

public enum LibraryMCPTools {
    private typealias S = PlanMCPTools
    public static let writeNames: Set<String> = ["teachshelf_create_course", "teachshelf_update_course", "teachshelf_delete_course", "teachshelf_update_material", "teachshelf_move_materials", "teachshelf_remove_materials", "teachshelf_create_material_folder", "teachshelf_update_material_folder", "teachshelf_dissolve_material_folder"]
    public static var names: Set<String> { Set(definitions.compactMap { $0["name"] as? String }) }
    private static let page: [String: Any] = ["offset": ["type": "integer", "minimum": 0, "maximum": 1_000_000], "limit": ["type": "integer", "minimum": 1, "maximum": 100]]
    private static let courseFields: [String: Any] = ["name": ["type": "string", "minLength": 1, "maxLength": 500], "semester": S.string(), "teacher": S.string(), "color_hex": S.string("六位 HEX 颜色。"), "archived": S.boolean]
    private static let guards: [String: Any] = ["library_id": S.string("当前资料库 ID，来自 context。"), "expected_library_revision": S.string("最近一次课程/资料查询返回的 library_revision。任一课程、资料、文件夹或关联计划更新后须重新读取。")]
    private static let guarded = ["library_id", "expected_library_revision"]
    private static let ids: [String: Any] = ["type": "array", "items": S.uuid, "maxItems": 100]
    public static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            let writes = writeNames.contains(name)
            return ["name": name, "description": description, "inputSchema": S.object(writes ? guards.merging(properties) { _, b in b } : properties, required: (writes ? guarded : []) + required), "annotations": ["readOnlyHint": !writes, "destructiveHint": writes, "openWorldHint": false]]
        }
        let folderFields: [String: Any] = ["name": S.string(), "color_hex": S.nullable(S.string()), "course_id": S.nullable(S.uuid), "parent_id": S.nullable(S.uuid)]
        let filters = page.merging(["query": S.string(), "course_id": S.nullable(S.uuid)]) { _, b in b }
        return [
            tool("teachshelf_list_courses", "搜索课程及数量统计，返回 library_revision 供所有课程资料写入使用。默认含归档，可过滤 archived；同名课程靠 ID 区分。", page.merging(["query": S.string(), "archived": S.boolean]) { _, b in b }),
            tool("teachshelf_get_course", "读取课程详情、归档状态、资料和文件夹数量，以及当前 library_revision。", ["id": S.uuid], ["id"]),
            tool("teachshelf_create_course", "创建课程及物理目录。request_id 是客户端 UUID，也是新课程 ID；重试复用，已存在时拒绝重复创建。", ["request_id": S.uuid, "fields": S.object(courseFields, required: ["name"])], ["request_id", "fields"]),
            tool("teachshelf_update_course", "局部修改课程名称、学期、教师、颜色、归档状态。改名同步物理目录；未提供的字段保持原样。", ["id": S.uuid, "patch": S.object(courseFields)], ["id", "patch"]),
            tool("teachshelf_delete_course", "删除课程及其教学网站连接；资料移为未分类，关联计划和实际文件保留，课程文件夹分组解除。不可用计划 undo_change 撤销。仅在用户要求删除课程时调用。", ["id": S.uuid], ["id"]),
            tool("teachshelf_list_materials", "分页搜索资料标题、原名、标签、备注。course_id/folder_id 不传表示全部，null 表示未分类/根目录；folder_id 默认仅当前层，recursive=true 包含子文件夹。", filters.merging(["folder_id": S.nullable(S.uuid), "recursive": S.boolean, "category": S.string(), "favorite": S.boolean, "missing": S.boolean]) { _, b in b }),
            tool("teachshelf_get_material", "读取资料元数据、标签、备注、所属位置及关联计划 ID。不读取文件正文，也不返回外部原文件路径。", ["id": S.uuid], ["id"]),
            tool("teachshelf_update_material", "局部修改资料标题、分类、标签、备注、收藏。title 只改显示标题；filename 重命名库内实际文件，必须保留扩展名；外部引用文件不能重命名。移动请用 move_materials。", ["id": S.uuid, "patch": S.object(["title": S.string(), "category": S.string(), "tags": S.string(), "notes": S.string(), "favorite": S.boolean, "filename": S.string()])], ["id", "patch"]),
            tool("teachshelf_move_materials", "原子批量移动资料到课程/物理文件夹，支持跨课程；course_id=null 移到未分类，folder_id=null 移到课程根目录。只移动库内副本，外部引用原文件留在原处。", ["ids": ids, "course_id": S.nullable(S.uuid), "folder_id": S.nullable(S.uuid)], ["ids", "course_id", "folder_id"]),
            tool("teachshelf_remove_materials", "移除资料记录并解除计划关联，保留实际文件（不移入废纸篓）。不可用计划 undo_change 撤销。仅在用户要求移除记录时调用。", ["ids": ids], ["ids"]),
            tool("teachshelf_list_material_folders", "列出物理文件夹，返回路径、层级、课程和资料数量。course_id 不传表示全部，null 表示未分类；parent_id 不传表示所有层，null 仅根层。", page.merging(["course_id": S.nullable(S.uuid), "parent_id": S.nullable(S.uuid)]) { _, b in b }),
            tool("teachshelf_get_material_folder", "读取文件夹详情及 library_revision。", ["id": S.uuid], ["id"]),
            tool("teachshelf_create_material_folder", "创建物理文件夹；request_id 是 UUID，也是新文件夹 ID。可指定课程和父目录，null 表示未分类/根目录。", ["request_id": S.uuid, "name": S.string(), "course_id": S.nullable(S.uuid), "parent_id": S.nullable(S.uuid), "color_hex": S.nullable(S.string())], ["request_id", "name", "course_id"]),
            tool("teachshelf_update_material_folder", "重命名、改色或移动物理文件夹，连同所有子目录和资料一起移动。换课程时未指定 parent_id 会移到新课程根目录；禁止循环嵌套和同层重名。", ["id": S.uuid, "patch": S.object(folderFields)], ["id", "patch"]),
            tool("teachshelf_dissolve_material_folder", "解散当前文件夹及所有子文件夹，资料移回上一级，实际文件保留；这会解除整个子树的分组。不可用计划 undo_change 撤销。", ["id": S.uuid], ["id"])
        ]
    }
}
