import Foundation
import CryptoKit

enum MCPRevision {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func libraryID(_ repository: LibraryRepository) -> String { hash(Data(repository.root.resolvingSymlinksInPath().standardizedFileURL.path.utf8)) }
    static func value<T: Encodable>(_ value: T) throws -> String {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        func canonical(_ value: Any, key: String = "") -> Any {
            if let array = value as? [String], key == "overriddenFields" { return array.sorted() }
            if let dict = value as? [String: Any] { return Dictionary(uniqueKeysWithValues: dict.map { ($0.key, canonical($0.value, key: $0.key)) }) }
            if let array = value as? [Any] { return array.map { canonical($0) } }
            return value
        }
        return hash(try JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys]))
    }
    static func library(_ state: LibraryState) throws -> String {
        // UI preferences and last-opened timestamps must not invalidate unrelated edits.
        var relevant = LibraryState()
        relevant.courses = state.courses; relevant.materials = state.materials
        for index in relevant.materials.indices { relevant.materials[index].lastOpenedAt = nil }
        relevant.materialFolders = state.materialFolders; relevant.tasks = state.tasks
        relevant.customCategories = state.customCategories
        relevant.teachingConnections = state.teachingConnections; relevant.timetableTerms = state.timetableTerms
        return try value(relevant)
    }
}
