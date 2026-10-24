import Foundation
import TeachshelfCore

struct MaterialBrowserRow: Identifiable, Equatable {
    enum Content: Equatable { case material(MaterialRecord), folder(MaterialFolder) }
    var content: Content
    var depth: Int = 0
    var isExpanded = false
    var materialIDs: Set<UUID>
    var id: UUID { material?.id ?? folder!.id }
    var title: String { material?.title ?? folder!.name }
    var material: MaterialRecord? { if case .material(let record) = content { return record }; return nil }
    var folder: MaterialFolder? { if case .folder(let folder) = content { return folder }; return nil }
    static func file(_ record: MaterialRecord, depth: Int = 0) -> Self {
        Self(content: .material(record), depth: depth, materialIDs: [record.id])
    }
}

struct MaterialBrowserSection: Identifiable {
    var rows: [MaterialBrowserRow]
    var id: UUID { rows[0].id }
    static func sections(from rows: [MaterialBrowserRow]) -> [Self] {
        var result: [Self] = []
        for row in rows {
            if row.material != nil, let last = result.last, last.rows[0].material != nil, last.rows[0].depth == row.depth {
                result[result.count - 1].rows.append(row)
            } else { result.append(Self(rows: [row])) }
        }
        return result
    }
}

@MainActor extension AppStore {
    var materialBrowserRows: [MaterialBrowserRow] {
        guard currentCourseID != nil || navigation == .unassigned else { return visibleMaterials.map { .file($0) } }
        let courseID = currentCourseID
        let folders = state.materialFolders.filter { $0.courseID == courseID }
        let records = filteredMaterials.filter { $0.courseID == courseID }
        let foldersByParent = Dictionary(grouping: folders, by: \.parentID)
        let recordsByFolder = Dictionary(grouping: records, by: \.folderID)
        let filtered = !search.isEmpty || categoryFilter != "全部类别" || formatFilter != "全部格式"
        var descendants: [UUID: Set<UUID>] = [:]
        for record in records {
            for folder in MaterialOrdering.folderPath(record.folderID, in: folders) { descendants[folder.id, default: []].insert(record.id) }
        }
        func rows(in parent: UUID?, depth: Int) -> [MaterialBrowserRow] {
            var result: [MaterialBrowserRow] = []
            for folder in MaterialOrdering.sortedFolders(foldersByParent[parent] ?? []) {
                let ids = descendants[folder.id] ?? []
                guard !filtered || !ids.isEmpty || folder.name.localizedCaseInsensitiveContains(search) && categoryFilter == "全部类别" && formatFilter == "全部格式" else { continue }
                let expanded = expandedMaterialFolderIDs.contains(folder.id) || filtered && !ids.isEmpty
                result.append(MaterialBrowserRow(content: .folder(folder), depth: depth, isExpanded: expanded, materialIDs: ids))
                if expanded { result += rows(in: folder.id, depth: depth + 1) }
            }
            result += MaterialOrdering.sorted(recordsByFolder[parent] ?? [], by: materialSortMode).map { .file($0, depth: depth) }
            return result
        }
        return rows(in: materialFolderID, depth: 0)
    }
    var materialBrowserSelectableIDs: Set<UUID> { materialBrowserRows.reduce(into: []) { $0.formUnion($1.materialIDs) } }
    func toggleMaterialFolder(_ id: UUID) {
        guard beforeLeavingMaterial?() != false else { return }
        if !expandedMaterialFolderIDs.insert(id).inserted { expandedMaterialFolderIDs.remove(id) }
    }
}

/// Leave a little more room between the hierarchy marker and each child surface.
enum MaterialBrowserLayout {
    static func contentInset(depth: Int) -> CGFloat { CGFloat(depth) * 22 }
    static func borderInset(depth: Int) -> CGFloat { 6 + contentInset(depth: depth) + (depth > 0 ? 6 : 0) }
}

struct MaterialFolderGuide: Identifiable, Equatable {
    let id: UUID
    let depth: Int
    let firstChild: Int
    let lastChild: Int
    let colorHex: String

    static func project(_ rows: [MaterialBrowserRow], color: (MaterialFolder) -> String) -> [Self] {
        rows.indices.compactMap { index in
            let row = rows[index]
            guard let folder = row.folder, row.isExpanded, index + 1 < rows.count, rows[index + 1].depth > row.depth else { return nil }
            var end = index + 1
            while end + 1 < rows.count && rows[end + 1].depth > row.depth { end += 1 }
            return Self(id: folder.id, depth: row.depth, firstChild: index + 1, lastChild: end, colorHex: color(folder))
        }
    }
}
