import Foundation

/// Readable course names for Finder, with stable IDs to separate same-named courses.
enum MaterialStorageLayout {
    static func courseDirectory(for course: Course?) -> String {
        guard let course else { return "files/未分类" }
        if let path = course.storageDirectory { return path }
        return "files/\(component(course.name, byteLimit: 120)) [\(course.id.uuidString)]"
    }

    static func materialRoot(for course: Course?) -> String {
        courseDirectory(for: course) + "/" + (course?.materialRootName ?? "资料")
    }

    static func homeworkPath(for course: Course?) -> String {
        courseDirectory(for: course) + "/作业"
    }

    /// A separate material root keeps a user folder named “作业” distinct from
    /// the homework workspace. Memoized paths avoid walking the tree per file.
    struct Directories {
        let courses: [UUID: String]
        let materialRoots: [UUID: String]
        let folders: [UUID: String]

        init(courses: [Course], folders: [MaterialFolder]) {
            self.courses = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, courseDirectory(for: $0)) })
            self.materialRoots = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, materialRoot(for: $0)) })
            let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            let roots = self.materialRoots
            var paths: [UUID: String] = [:]
            func path(_ id: UUID) -> String {
                if let cached = paths[id] { return cached }
                let folder = byID[id]!
                let parent = folder.parentID.map(path) ?? (folder.courseID.flatMap { roots[$0] } ?? materialRoot(for: nil))
                let result = folder.storageDirectory ?? (parent + "/" + folder.name)
                paths[id] = result
                return result
            }
            for folder in folders { _ = path(folder.id) }
            self.folders = paths
        }

        func directory(for material: MaterialRecord) -> String {
            material.storageDirectory ?? material.folderID.flatMap { folders[$0] }
                ?? (material.courseID.flatMap { materialRoots[$0] } ?? materialRoot(for: nil))
        }

        func required(in state: LibraryState) -> Set<String> {
            var result = Set(state.courses.filter { $0.isMissing != true }.compactMap { courses[$0.id] })
            result.formUnion(state.courses.filter { $0.isMissing != true }.compactMap { materialRoots[$0.id] })
            result.formUnion(state.materialFolders.filter { $0.isMissing != true }.compactMap { folders[$0.id] })
            if state.materials.contains(where: { $0.isManaged && $0.courseID == nil && $0.isMissing != true }) {
                result.insert(courseDirectory(for: nil))
                result.insert(courseDirectory(for: nil) + "/资料")
            }
            return result
        }
    }

    static func relativePath(for material: MaterialRecord, courses: [Course], folders: [MaterialFolder] = []) -> String {
        relativePath(for: material, directories: Directories(courses: courses, folders: folders))
    }

    static func relativePath(for material: MaterialRecord, directories: Directories) -> String {
        if material.isMissing == true { return material.storedPath }
        let directory = directories.directory(for: material)
        if let name = material.storageName { return directory + "/" + name }
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

    static func component(_ text: String, byteLimit: Int) -> String {
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
