import Foundation

public enum MaterialSortMode: String, Codable, CaseIterable, Sendable {
    case name, time, custom
    public var title: String {
        switch self { case .name: return "按名称排序"; case .time: return "按时间排序"; case .custom: return "自定义排序" }
    }
}

/// Course-local physical directories. External references retain their original paths.
public struct MaterialFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var courseID: UUID?
    public var parentID: UUID?
    public var name: String
    public var colorHex: String?
    public var createdAt: Date
    public var storageDirectory: String?
    public var isMissing: Bool?
    public init(id: UUID = UUID(), courseID: UUID?, parentID: UUID? = nil, name: String, colorHex: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.courseID = courseID; self.parentID = parentID; self.name = name; self.colorHex = colorHex; self.createdAt = createdAt
    }
}

public enum MaterialOrdering {
    public static func sorted(_ records: [MaterialRecord], by mode: MaterialSortMode) -> [MaterialRecord] {
        records.map { (record: $0, name: mode == .name ? chapterSortKey($0.title) : "") }.sorted { lhs, rhs in
            let a = lhs.record, b = rhs.record
            if mode == .custom, a.customOrder != b.customOrder {
                return (a.customOrder ?? Int.max) < (b.customOrder ?? Int.max)
            }
            if mode == .name {
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
            return a.id.uuidString < b.id.uuidString
        }.map(\.record)
    }

    public static func folderPath(_ id: UUID?, in folders: [MaterialFolder]) -> [MaterialFolder] {
        var result: [MaterialFolder] = [], current = id, visited: Set<UUID> = []
        while let value = current, visited.insert(value).inserted, let folder = folders.first(where: { $0.id == value }) {
            result.insert(folder, at: 0); current = folder.parentID
        }
        return result
    }
}
