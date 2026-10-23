import Foundation

/// All revision checks and mutations run under the owning repository's recursive lock.
public final class LibraryMCPService: @unchecked Sendable {
    public let repository: LibraryRepository
    public let libraryID: String
    public init(repository: LibraryRepository) {
        self.repository = repository; libraryID = MCPRevision.libraryID(repository)
    }
    public func context() throws -> [String: Any] {
        try repository.withLock {
            let state = repository.state
            let categories = Set(["课件", "教材", "笔记", "参考资料", "其他"] + state.customCategories + state.materials.map(\.category))
            return ["library_revision": try MCPRevision.library(state), "material_categories": categories.sorted()]
        }
    }
    public func call(name: String, arguments a: [String: Any]) throws -> [String: Any] {
        guard let schema = LibraryMCPTools.definitions.first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any] else { throw PlanMCPError("未知课程资料工具。") }
        try PlanMCPTools.validate(a, schema: schema)
        return try repository.withLock {
            try repository.synchronizeFileSystem()
            let before = repository.state
            var result: [String: Any]
            if LibraryMCPTools.writeNames.contains(name) {
                guard a["library_id"] as? String == libraryID else { throw PlanMCPError("资料库已切换，请重新查询当前资料库。") }
                guard try a["expected_library_revision"] as? String == MCPRevision.library(before) else { throw PlanMCPError("revision_conflict：课程资料或关联计划已变化，请重新查询后合并修改。") }
                result = try mutate(name, a)
                result["changed"] = repository.state != before
            } else { result = try read(name, a) }
            result["library_id"] = libraryID; result["library_revision"] = try MCPRevision.library(repository.state)
            return result
        }
    }
    private func read(_ name: String, _ a: [String: Any]) throws -> [String: Any] {
        let state = repository.state, query = a["query"] as? String ?? ""
        let courseID = try optionalID(a, "course_id")
        switch name {
        case "teachshelf_list_courses":
            let courses = state.courses.filter { (query.isEmpty || ($0.name + " " + $0.semester + " " + $0.teacher).localizedCaseInsensitiveContains(query)) && (a["archived"] == nil || $0.isArchived == a["archived"] as? Bool) }.sorted { $0.id.uuidString < $1.id.uuidString }
            return page(courses, arguments: a, key: "courses", map: courseDTO)
        case "teachshelf_get_course": return ["course": courseDTO(try course(a))]
        case "teachshelf_list_materials":
            let folderID = try optionalID(a, "folder_id")
            if let folderID { _ = try folder(id: folderID) }
            let recursive = a["recursive"] as? Bool ?? false
            let folders = folderID.map { descendants($0, in: state) } ?? Set<UUID>()
            let materials = state.materials.filter { m in
                (a["course_id"] == nil || m.courseID == courseID) &&
                (a["folder_id"] == nil || (recursive ? (folderID == nil || m.folderID.map(folders.contains) == true) : m.folderID == folderID)) &&
                (a["category"] == nil || m.category == a["category"] as? String) &&
                (a["favorite"] == nil || m.isFavorite == a["favorite"] as? Bool) &&
                (a["missing"] == nil || (m.isMissing == true) == a["missing"] as? Bool) &&
                (query.isEmpty || [m.title, m.originalName, m.tags, m.notes].joined(separator: " ").localizedCaseInsensitiveContains(query))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return page(materials, arguments: a, key: "materials") { materialDTO($0, full: false) }
        case "teachshelf_get_material":
            let material = try material(a)
            var result = materialDTO(material, full: true)
            result["linked_plan_ids"] = state.tasks.filter { $0.materialIDs.contains(material.id) || $0.exceptions.contains { $0.details?.materialIDs.contains(material.id) == true } }.map { $0.id.uuidString }
            return ["material": result]
        case "teachshelf_list_material_folders":
            let parentID = try optionalID(a, "parent_id")
            let folders = state.materialFolders.filter { (a["course_id"] == nil || $0.courseID == courseID) && (a["parent_id"] == nil || $0.parentID == parentID) }.sorted { $0.id.uuidString < $1.id.uuidString }
            return page(folders, arguments: a, key: "folders", map: folderDTO)
        case "teachshelf_get_material_folder": return ["folder": folderDTO(try folder(id: id(a, "id")))]
        default: throw PlanMCPError("未知课程资料工具。")
        }
    }
    private func mutate(_ name: String, _ a: [String: Any]) throws -> [String: Any] {
        switch name {
        case "teachshelf_create_course", "teachshelf_update_course":
            let creating = name == "teachshelf_create_course"
            let fields = a[creating ? "fields" : "patch"] as! [String: Any]
            var value = creating ? Course(id: try id(a, "request_id"), name: "") : try course(a)
            if creating, repository.state.courses.contains(where: { $0.id == value.id }) { throw PlanMCPError("request_id 已存在，请用该 ID 查询，不会重复创建。") }
            if let name = fields["name"] as? String { value.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let semester = fields["semester"] as? String { value.semester = semester }
            if let teacher = fields["teacher"] as? String { value.teacher = teacher }
            if let color = fields["color_hex"] as? String { value.colorHex = try hex(color) }
            if let archived = fields["archived"] as? Bool { value.isArchived = archived }
            try repository.saveCourse(value)
            return ["course": courseDTO(repository.state.courses.first { $0.id == value.id }!)]
        case "teachshelf_delete_course":
            let value = try course(a); try repository.deleteCourse(id: value.id)
            return ["deleted_course_id": value.id.uuidString, "files_preserved": true]
        case "teachshelf_update_material":
            var value = try material(a); let fields = a["patch"] as! [String: Any]
            if let title = fields["title"] as? String { value.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let category = fields["category"] as? String { value.category = category }
            if let tags = fields["tags"] as? String { value.tags = tags }
            if let notes = fields["notes"] as? String { value.notes = notes }
            if let favorite = fields["favorite"] as? Bool { value.isFavorite = favorite }
            if let filename = fields["filename"] as? String {
                guard value.isManaged, value.isMissing != true else { throw PlanMCPError("只能重命名位置正常的库内副本。外部引用或丢失文件保持原状。") }
                try validFilename(filename)
                guard URL(fileURLWithPath: filename).pathExtension.lowercased() == value.fileExtension else { throw PlanMCPError("重命名必须保留原扩展名，不能通过改名转换文件格式。") }
                value.storageName = filename
            }
            try repository.updateMaterial(value)
            return ["material": materialDTO(repository.state.materials.first { $0.id == value.id }!, full: true)]
        case "teachshelf_move_materials":
            let ids = try materialIDs(a), courseID = try optionalID(a, "course_id"), folderID = try optionalID(a, "folder_id")
            try repository.commit { state in
                try repository.ensureCourse(courseID); try LibraryRepository.ensureMaterialFolder(folderID, courseID: courseID, in: state)
                for index in state.materials.indices where ids.contains(state.materials[index].id) {
                    let old = state.materials[index]
                    if old.courseID != courseID || old.folderID != folderID {
                        state.materials[index].courseID = courseID; state.materials[index].folderID = folderID
                        state.materials[index].customOrder = nil; state.materials[index].storageDirectory = nil
                    }
                }
            }
            return ["materials": repository.state.materials.filter { ids.contains($0.id) }.map { materialDTO($0, full: false) }]
        case "teachshelf_remove_materials":
            let ids = try materialIDs(a); try repository.removeMaterials(ids: ids)
            return ["removed_ids": ids.map(\.uuidString).sorted(), "files_preserved": true]
        case "teachshelf_create_material_folder":
            let identifier = try id(a, "request_id")
            guard !repository.state.materialFolders.contains(where: { $0.id == identifier }) else { throw PlanMCPError("request_id 已存在，请用该 ID 查询，不会重复创建。") }
            let value = MaterialFolder(id: identifier, courseID: try optionalID(a, "course_id"), parentID: try optionalID(a, "parent_id"), name: (a["name"] as! String).trimmingCharacters(in: .whitespacesAndNewlines), colorHex: try (a["color_hex"] as? String).map(hex))
            try repository.commit { $0.materialFolders.append(value) }
            return ["folder": folderDTO(repository.state.materialFolders.first { $0.id == identifier }!)]
        case "teachshelf_update_material_folder":
            let original = try folder(id: id(a, "id")), fields = a["patch"] as! [String: Any]
            let children = descendants(original.id, in: repository.state)
            var value = original
            if let name = fields["name"] as? String { value.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if fields["color_hex"] != nil { value.colorHex = try (fields["color_hex"] as? String).map(hex) }
            if fields["course_id"] != nil { value.courseID = try optionalID(fields, "course_id") }
            if value.courseID != original.courseID { value.parentID = nil }
            if fields["parent_id"] != nil { value.parentID = try optionalID(fields, "parent_id") }
            guard value.parentID.map(children.contains) != true else { throw PlanMCPError("不能将文件夹移入自身或子文件夹。") }
            let moving = value.courseID != original.courseID || value.parentID != original.parentID
            if moving { value.storageDirectory = nil }
            else if value.name != original.name, let path = value.storageDirectory {
                value.storageDirectory = String(path[..<path.lastIndex(of: "/")!]) + "/" + value.name
            }
            try repository.commit { state in
                try repository.ensureCourse(value.courseID)
                for index in state.materialFolders.indices where children.contains(state.materialFolders[index].id) {
                    if state.materialFolders[index].id == value.id { state.materialFolders[index] = value }
                    else if moving { state.materialFolders[index].courseID = value.courseID; state.materialFolders[index].storageDirectory = nil }
                }
                if moving {
                    for index in state.materials.indices where state.materials[index].folderID.map(children.contains) == true {
                        state.materials[index].courseID = value.courseID; state.materials[index].customOrder = nil; state.materials[index].storageDirectory = nil
                    }
                }
            }
            return ["folder": folderDTO(repository.state.materialFolders.first { $0.id == value.id }!)]
        case "teachshelf_dissolve_material_folder":
            let value = try folder(id: id(a, "id")); try repository.dissolveMaterialFolder(id: value.id)
            return ["dissolved_folder_id": value.id.uuidString, "files_preserved": true]
        default: throw PlanMCPError("未知课程资料工具。")
        }
    }
    private func materialIDs(_ a: [String: Any]) throws -> Set<UUID> {
        let values = try (a["ids"] as! [String]).map(uuid), ids = Set(values)
        guard !ids.isEmpty, ids.count == values.count, ids.isSubset(of: Set(repository.state.materials.map(\.id))) else { throw PlanMCPError("请选择存在且不重复的资料 ID，批量操作未执行。") }
        return ids
    }
    private func course(_ a: [String: Any]) throws -> Course {
        let identifier = try id(a, "id")
        guard let value = repository.state.courses.first(where: { $0.id == identifier }) else { throw PlanMCPError("课程不存在，请重新查询。") }; return value
    }
    private func material(_ a: [String: Any]) throws -> MaterialRecord {
        let identifier = try id(a, "id")
        guard let value = repository.state.materials.first(where: { $0.id == identifier }) else { throw PlanMCPError("资料不存在，请重新查询。") }; return value
    }
    private func folder(id: UUID) throws -> MaterialFolder {
        guard let value = repository.state.materialFolders.first(where: { $0.id == id }) else { throw PlanMCPError("文件夹不存在，请重新查询。") }; return value
    }
    private func descendants(_ id: UUID, in state: LibraryState) -> Set<UUID> { Set(state.materialFolders.filter { MaterialOrdering.folderPath($0.id, in: state.materialFolders).contains { $0.id == id } }.map(\.id)) }
    private func id(_ a: [String: Any], _ key: String) throws -> UUID { try uuid(a[key] as! String) }
    private func optionalID(_ a: [String: Any], _ key: String) throws -> UUID? { try (a[key] as? String).map(uuid) }
    private func uuid(_ text: String) throws -> UUID { guard let value = UUID(uuidString: text) else { throw PlanMCPError("无效 UUID。") }; return value }
    private func hex(_ text: String) throws -> String { guard let value = RGBColor(hex: text) else { throw PlanMCPError("颜色必须为六位 HEX。") }; return value.hex }
    private func validFilename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PlanMCPError("文件名必须是普通名称，不能包含路径分隔符或控制字符。") }
    }
    private func page<T>(_ values: [T], arguments: [String: Any], key: String, map: (T) -> [String: Any]) -> [String: Any] {
        let start = min(arguments["offset"] as? Int ?? 0, values.count), end = min(start + (arguments["limit"] as? Int ?? 50), values.count)
        return [key: values[start..<end].map(map), "total": values.count, "next_offset": end < values.count ? end as Any : NSNull()]
    }
    private func courseDTO(_ c: Course) -> [String: Any] {
        let state = repository.state
        return ["id": c.id.uuidString, "name": c.name, "semester": c.semester, "teacher": c.teacher, "color_hex": c.colorHex, "archived": c.isArchived, "missing": c.isMissing == true, "material_count": state.materials.filter { $0.courseID == c.id }.count, "folder_count": state.materialFolders.filter { $0.courseID == c.id }.count]
    }
    private func folderDTO(_ f: MaterialFolder) -> [String: Any] {
        let state = repository.state, subtree = descendants(f.id, in: state)
        return ["id": f.id.uuidString, "name": f.name, "course_id": f.courseID?.uuidString as Any? ?? NSNull(), "parent_id": f.parentID?.uuidString as Any? ?? NSNull(), "color_hex": f.colorHex as Any? ?? NSNull(), "missing": f.isMissing == true, "path": MaterialOrdering.folderPath(f.id, in: state.materialFolders).map(\.name).joined(separator: "/"), "material_count": state.materials.filter { $0.folderID == f.id }.count, "recursive_material_count": state.materials.filter { $0.folderID.map(subtree.contains) == true }.count]
    }
    private func materialDTO(_ m: MaterialRecord, full: Bool) -> [String: Any] {
        var result: [String: Any] = ["id": m.id.uuidString, "title": m.title, "original_name": m.originalName, "filename": m.isManaged ? URL(fileURLWithPath: m.storedPath).lastPathComponent : m.originalName, "course_id": m.courseID?.uuidString as Any? ?? NSNull(), "folder_id": m.folderID?.uuidString as Any? ?? NSNull(), "folder_path": MaterialOrdering.folderPath(m.folderID, in: repository.state.materialFolders).map(\.name).joined(separator: "/"), "category": m.category, "tags": m.tags, "favorite": m.isFavorite, "managed": m.isManaged, "missing": m.isMissing == true, "size_bytes": m.size, "file_type": m.fileType]
        if full { result["notes"] = m.notes; result["added_at"] = ISO8601DateFormatter().string(from: m.addedAt) }
        return result
    }
}
