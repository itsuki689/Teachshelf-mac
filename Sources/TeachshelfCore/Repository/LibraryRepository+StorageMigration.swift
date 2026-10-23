import Foundation
import Darwin

extension LibraryRepository {
    var relocationURL: URL { root.appendingPathComponent(".material-relocation.json") }
    struct MaterialRelocation: Codable {
        var source: String
        var destination: String
        var temporary: String?
        var homework: Bool?
        var directory: Bool?
        var retainDestination: Bool?
    }

    func organizedMaterials(_ state: LibraryState) throws -> LibraryState {
        var next = state
        for index in next.materials.indices where next.materials[index].isManaged {
            let material = next.materials[index]
            let destination = MaterialStorageLayout.relativePath(for: material, courses: next.courses)
            guard material.storedPath != destination else { continue }
            let source = try fileURL(for: material)
            try ensureSafePath(source, beneath: filesURL)
            // Missing files remain visible and can still be removed from the library.
            guard fileManager.fileExists(atPath: source.path) else { continue }
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryError.unsafePath(source.path)
            }
            next.materials[index].storedPath = destination
        }
        return next
    }

    func relocationFile(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."),
              path.hasPrefix("files/") || path.hasPrefix("HomeworkFiles/") else { throw LibraryError.unsafePath(path) }
        let url = root.appendingPathComponent(path).standardizedFileURL
        try ensureSafePath(url, beneath: root)
        return url
    }

    func recoverMaterialRelocation(rollingBack: Bool = false) throws {
        try ensureSafePath(relocationURL, beneath: root)
        guard fileManager.fileExists(atPath: relocationURL.path) else { return }
        let relocations = try JSONDecoder().decode([MaterialRelocation].self, from: Data(contentsOf: relocationURL))
        let referenced = Set(snapshot.materials.filter(\.isManaged).map(\.storedPath))
        let homeworkRoots = ([MaterialStorageLayout.homeworkPath(for: nil)] + snapshot.courses.map { MaterialStorageLayout.homeworkPath(for: $0) })
        func isReferenced(_ path: String, homework: Bool) -> Bool {
            homework ? homeworkRoots.contains { path == $0 || path.hasPrefix($0 + "/") } : referenced.contains(path)
        }
        // Children are cleaned before their parent directories.
        for relocation in relocations.reversed() {
            let source = try relocationFile(relocation.source), destination = try relocationFile(relocation.destination)
            if let path = relocation.temporary {
                let prefix = "files/.material-copy-"
                guard path.hasPrefix(prefix), UUID(uuidString: String(path.dropFirst(prefix.count))) != nil else {
                    throw LibraryError.invalidLibrary("资料整理日志包含无效的临时文件路径。")
                }
                let temporary = try relocationFile(path)
                if !referenced.contains(path), fileManager.fileExists(atPath: temporary.path),
                   try temporary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    try fileManager.removeItem(at: temporary)
                }
            }
            let discard: URL, keep: URL
            if rollingBack {
                guard relocation.retainDestination != true,
                      relocation.homework == true || !referenced.contains(relocation.destination) else { continue }
                discard = destination; keep = source
            } else if isReferenced(relocation.destination, homework: relocation.homework == true),
                      !isReferenced(relocation.source, homework: relocation.homework == true) {
                discard = source; keep = destination
            } else if isReferenced(relocation.source, homework: relocation.homework == true),
                      !isReferenced(relocation.destination, homework: relocation.homework == true) {
                guard relocation.retainDestination != true else { continue }
                discard = destination; keep = source
            } else { continue }
            if relocation.directory == true {
                if fileManager.fileExists(atPath: keep.path) { _ = Darwin.rmdir(discard.path) }
                removeEmptyMaterialDirectories(from: discard.deletingLastPathComponent())
                continue
            }
            // Never remove the last surviving copy or overwrite an unrelated collision.
            if fileManager.fileExists(atPath: discard.path), fileManager.fileExists(atPath: keep.path),
               sameMaterialContents(discard, keep) {
                try fileManager.removeItem(at: discard)
            }
            removeEmptyMaterialDirectories(from: discard.deletingLastPathComponent())
        }
        try fileManager.removeItem(at: relocationURL)
        _ = Darwin.rmdir(root.appendingPathComponent("HomeworkFiles").path)
    }

    func sameMaterialContents(_ first: URL, _ second: URL) -> Bool {
        var a = stat(), b = stat()
        guard lstat(first.path, &a) == 0, lstat(second.path, &b) == 0,
              a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG else { return false }
        return (a.st_dev == b.st_dev && a.st_ino == b.st_ino) || fileManager.contentsEqual(atPath: first.path, andPath: second.path)
    }

    func removeEmptyMaterialDirectories(from directory: URL) {
        var cursor = directory
        let legacy = root.appendingPathComponent("HomeworkFiles")
        let boundary = isBeneath(cursor, root: filesURL) ? filesURL : legacy
        while cursor.path != boundary.path && isBeneath(cursor, root: boundary) {
            // rmdir only removes an empty directory; retained records/files are untouched.
            guard Darwin.rmdir(cursor.path) == 0 else { break }
            cursor.deleteLastPathComponent()
        }
    }

    func homeworkRelocations(in state: LibraryState) throws -> [MaterialRelocation] {
        var result: [MaterialRelocation] = []
        var planned: [String: URL] = [:]
        let courseFolders = try fileManager.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil).map(\.standardizedFileURL)
        func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)) }
        func visit(_ source: URL, to proposed: URL) throws {
            try ensureSafePath(source, beneath: root)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let directory = values.isDirectory == true
            guard directory || values.isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
            var target = proposed
            let name = proposed.deletingPathExtension().lastPathComponent, suffix = proposed.pathExtension
            var number = 2
            while true {
                try ensureSafePath(target, beneath: root)
                let existing = planned[target.path] ?? (fileManager.fileExists(atPath: target.path) ? target : nil)
                guard let existing else { break }
                let isDirectory = try existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if (directory && isDirectory) || (!directory && !isDirectory && sameMaterialContents(source, existing)) { break }
                target = proposed.deletingLastPathComponent().appendingPathComponent("\(name) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
                number += 1
            }
            let retained = fileManager.fileExists(atPath: target.path) || planned[target.path] != nil
            planned[target.path] = source
            result.append(MaterialRelocation(source: relative(source), destination: relative(target),
                                             temporary: directory ? nil : "files/.material-copy-\(UUID().uuidString)",
                                             homework: true, directory: directory, retainDestination: retained))
            if directory {
                for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                    try visit(child.standardizedFileURL, to: target.appendingPathComponent(child.lastPathComponent))
                }
            }
        }
        for course in state.courses.map(Optional.some) + [nil] {
            let target = root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course))
            var sources = [root.appendingPathComponent("HomeworkFiles/\(course?.id.uuidString ?? "Unassigned")")]
            if let course {
                sources += courseFolders.filter { $0.lastPathComponent.hasSuffix(" [\(course.id.uuidString)]") }.map { $0.appendingPathComponent("作业") }
            }
            for source in sources where source.path != target.path && fileManager.fileExists(atPath: source.path) {
                try ensureSafePath(target, beneath: root)
                if fileManager.fileExists(atPath: target.path),
                   try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                    throw LibraryError.invalidInput("课程目录中的“作业”已被文件占用，请先移走该文件：\(target.path)")
                }
                try visit(source, to: target)
            }
        }
        return result
    }
}
