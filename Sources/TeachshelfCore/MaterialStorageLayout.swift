import Foundation

/// Readable course names for Finder, with stable IDs to separate same-named courses.
enum MaterialStorageLayout {
    static func courseDirectory(for course: Course?) -> String {
        guard let course else { return "files/未分类" }
        return "files/\(component(course.name, byteLimit: 120)) [\(course.id.uuidString)]"
    }

    static func homeworkPath(for course: Course?) -> String {
        courseDirectory(for: course) + "/作业"
    }

    static func relativePath(for material: MaterialRecord, courses: [Course]) -> String {
        let directory = courseDirectory(for: courses.first(where: { $0.id == material.courseID }))
        var name = component(material.originalName, byteLimit: Int.max)
        if name.utf8.count > 218 {
            let suffix = URL(fileURLWithPath: name).pathExtension
            if !suffix.isEmpty, suffix.utf8.count <= 32 {
                name = component(String(name.dropLast(suffix.count + 1)), byteLimit: 217 - suffix.utf8.count) + "." + suffix
            } else {
                name = component(name, byteLimit: 218)
            }
        }
        return "\(directory)/\(material.id.uuidString)-\(name)"
    }

    private static func component(_ text: String, byteLimit: Int) -> String {
        let cleaned = String(text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) { return "_" }
            return Character(String(scalar))
        }).precomposedStringWithCanonicalMapping
        var result = ""
        var byteCount = 0
        for character in cleaned {
            let size = String(character).utf8.count
            guard byteCount + size <= byteLimit else { break }
            result.append(character)
            byteCount += size
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? "未命名" : result
    }
}
