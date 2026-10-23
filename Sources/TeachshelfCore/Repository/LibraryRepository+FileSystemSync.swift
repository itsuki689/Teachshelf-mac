import Foundation
import Darwin

/// An inode plus volume and creation time follows a rename, but not an unrelated
/// file copied to the same name. Observations live outside the portable index.
struct FileObservation: Codable, Equatable {
    var path: String
    var identity: String
    var size: Int64?
}

private struct DiskEntry {
    var path: String
    var identity: String
    var directory: Bool
    var size: Int64
}

extension LibraryRepository {
    private var observationURL: URL { root.appendingPathComponent(".file-observations.json") }

    func loadFileObservations() {
        guard (try? ensureSafePath(observationURL, beneath: root)) != nil,
              let data = try? Data(contentsOf: observationURL),
              let observations = try? JSONDecoder().decode([String: FileObservation].self, from: data) else { return }
        fileObservations = observations
    }

    private func trackedPaths(in state: LibraryState) -> [String: String] {
        let layout = MaterialStorageLayout.Directories(courses: state.courses, folders: state.materialFolders)
        var paths: [String: String] = [:]
        for course in state.courses {
            paths["course:\(course.id)"] = layout.courses[course.id]
            paths["root:\(course.id)"] = layout.materialRoots[course.id]
        }
        for folder in state.materialFolders { paths["folder:\(folder.id)"] = layout.folders[folder.id] }
        for material in state.materials where material.isManaged { paths["file:\(material.id)"] = material.storedPath }
        return paths
    }

    private func diskEntry(_ url: URL, volumes: inout [dev_t: String]) throws -> DiskEntry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { return nil } // never follow symbolic links
        let volume: String
        if let cached = volumes[info.st_dev] { volume = cached }
        else {
            volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? String(info.st_dev)
            volumes[info.st_dev] = volume
        }
        let absolute = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard absolute.hasPrefix(base + "/") else { throw LibraryError.unsafePath(absolute) }
        return DiskEntry(path: String(absolute.dropFirst(base.count + 1)),
                         identity: "\(volume):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)",
                         directory: type == S_IFDIR, size: info.st_size)
    }

    private func scanFiles() throws -> [String: DiskEntry] {
        try ensureSafePath(filesURL, beneath: root)
        guard fileManager.fileExists(atPath: filesURL.path) else { return [:] }
        var result: [String: DiskEntry] = [:], volumes: [dev_t: String] = [:]
        var failure: Error?
        guard let enumerator = fileManager.enumerator(at: filesURL, includingPropertiesForKeys: nil,
            errorHandler: { _, error in failure = error; return false }) else { throw LibraryError.missingFile(filesURL.path) }
        for case let url as URL in enumerator {
            if let entry = try diskEntry(url, volumes: &volumes) { result[entry.path] = entry }
            else { enumerator.skipDescendants() }
        }
        if let failure { throw failure } // unreadable subtrees must never be marked missing
        return result
    }

    func refreshFileObservations() throws {
        var next: [String: FileObservation] = [:], volumes: [dev_t: String] = [:]
        for (key, path) in trackedPaths(in: snapshot) {
            let missing: Bool
            if key.hasPrefix("file:"), let id = UUID(uuidString: String(key.dropFirst(5))) {
                missing = snapshot.materials.first { $0.id == id }?.isMissing == true
            } else if key.hasPrefix("folder:"), let id = UUID(uuidString: String(key.dropFirst(7))) {
                missing = snapshot.materialFolders.first { $0.id == id }?.isMissing == true
            } else if let id = UUID(uuidString: String(key.dropFirst(key.hasPrefix("root:") ? 5 : 7))) {
                missing = snapshot.courses.first { $0.id == id }?.isMissing == true
            } else { missing = false }
            if missing { next[key] = fileObservations[key]; continue }
            try ensureSafePath(root.appendingPathComponent(path), beneath: filesURL)
            if !missing, let entry = try diskEntry(root.appendingPathComponent(path), volumes: &volumes) {
                next[key] = FileObservation(path: path, identity: entry.identity, size: entry.size)
            } else { next[key] = fileObservations[key] }
        }
        guard next != fileObservations || !fileManager.fileExists(atPath: observationURL.path) else { return }
        try ensureSafePath(observationURL, beneath: root)
        try JSONEncoder().encode(next).write(to: observationURL, options: .atomic)
        fileObservations = next
    }

    /// Reconcile disk changes without moving, copying or deleting any user file.
    /// This also runs before metadata edits and on startup to cover missed events.
    @discardableResult
    public func synchronizeFileSystem() throws -> Bool {
        try withLock {
            guard snapshot.schemaVersion >= 9 else { return false }
            try recoverPhysicalStorage()
            try recoverMaterialRelocation()
            let entries = try scanFiles()
            let identities = Dictionary(grouping: entries.values, by: \.identity)
            let oldPaths = trackedPaths(in: snapshot)
            let missingKeys = Set(snapshot.materials.filter { $0.isMissing == true }.map { "file:\($0.id)" }
                + snapshot.materialFolders.filter { $0.isMissing == true }.map { "folder:\($0.id)" }
                + snapshot.courses.filter { $0.isMissing == true }.flatMap { ["course:\($0.id)", "root:\($0.id)"] })
            func locate(_ key: String, directory: Bool) -> DiskEntry? {
                guard let expected = oldPaths[key] else { return nil }
                if let observation = fileObservations[key], let candidates = identities[observation.identity] {
                    let matches = candidates.filter { $0.directory == directory }
                    // Hard links are ambiguous. Follow only an unambiguous location.
                    return matches.first { $0.path == expected } ?? matches.first { $0.path == observation.path }
                        ?? (matches.count == 1 ? matches.first : nil)
                }
                // Editors often replace a file atomically; portable library copies
                // also have fresh inodes. An existing expected path can be re-enrolled.
                // Once reported missing, a new occupant must not steal its record.
                if missingKeys.contains(key), fileObservations[key] != nil { return nil }
                return entries[expected].flatMap { $0.directory == directory ? $0 : nil }
            }
            var next = snapshot
            for i in next.courses.indices {
                let course = next.courses[i]
                if let entry = locate("course:\(course.id)", directory: true) {
                    next.courses[i].isMissing = nil
                    if entry.path != oldPaths["course:\(course.id)"] {
                        next.courses[i].storageDirectory = entry.path
                        let suffix = " [\(course.id)]", name = URL(fileURLWithPath: entry.path).lastPathComponent
                        let readable = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
                        if !readable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.courses[i].name = readable }
                    }
                    if let materialRoot = locate("root:\(course.id)", directory: true),
                       String(materialRoot.path[..<materialRoot.path.lastIndex(of: "/")!]) == entry.path {
                        let name = URL(fileURLWithPath: materialRoot.path).lastPathComponent
                        next.courses[i].materialRootName = name == "资料" ? nil : name
                    }
                } else { next.courses[i].isMissing = true }
            }
            let layout = MaterialStorageLayout.Directories(courses: next.courses, folders: next.materialFolders)
            var anchors: [String: UUID?] = [MaterialStorageLayout.materialRoot(for: nil): nil, "files": nil]
            for course in next.courses where course.isMissing != true {
                anchors[layout.courses[course.id]!] = .some(course.id)
                anchors[layout.materialRoots[course.id]!] = .some(course.id)
            }
            var folderEntries: [UUID: DiskEntry] = [:]
            var folderIDs: [String: UUID] = [:]
            for i in next.materialFolders.indices {
                let folder = next.materialFolders[i]
                if let entry = locate("folder:\(folder.id)", directory: true), anchors[entry.path] == nil {
                    folderEntries[folder.id] = entry; folderIDs[entry.path] = folder.id
                    next.materialFolders[i].isMissing = nil
                } else { next.materialFolders[i].isMissing = true }
            }
            var completed: Set<String> = []
            func parentPath(_ path: String) -> String { String(path[..<path.lastIndex(of: "/")!]) }
            func ensureFolder(_ path: String) throws -> (UUID?, UUID?) {
                if let course = anchors[path] { return (course, nil) }
                guard let entry = entries[path], entry.directory, path.hasPrefix("files/") else {
                    throw LibraryError.missingFile(path)
                }
                if completed.contains(path), let id = folderIDs[path], let folder = next.materialFolders.first(where: { $0.id == id }) {
                    return (folder.courseID, id)
                }
                let (courseID, parentID) = try ensureFolder(parentPath(path))
                let name = URL(fileURLWithPath: path).lastPathComponent
                let id: UUID
                if let existing = folderIDs[path] { id = existing }
                else {
                    id = UUID(); folderIDs[path] = id
                    next.materialFolders.append(MaterialFolder(id: id, courseID: courseID, name: name))
                }
                let i = next.materialFolders.firstIndex { $0.id == id }!
                next.materialFolders[i].courseID = courseID; next.materialFolders[i].parentID = parentID
                next.materialFolders[i].name = name; next.materialFolders[i].isMissing = nil
                // A directory placed directly in files/ or a course root remains
                // at its exact Finder location; its children still use physical paths.
                let canonicalParent = parentID == nil ? (courseID.flatMap { layout.materialRoots[$0] } ?? MaterialStorageLayout.materialRoot(for: nil)) : parentPath(path)
                next.materialFolders[i].storageDirectory = canonicalParent == parentPath(path) ? nil : path
                completed.insert(path)
                return (courseID, id)
            }
            for entry in folderEntries.values.sorted(by: { $0.path < $1.path }) { _ = try ensureFolder(entry.path) }
            // Missing descendants keep their IDs and annotations. If an ancestor
            // crossed courses, retain a valid parent/course relationship as well.
            for i in next.materialFolders.indices.sorted(by: {
                MaterialOrdering.folderPath(next.materialFolders[$0].id, in: next.materialFolders).count < MaterialOrdering.folderPath(next.materialFolders[$1].id, in: next.materialFolders).count
            }) where next.materialFolders[i].isMissing == true {
                if let parent = MaterialOrdering.folderPath(next.materialFolders[i].parentID, in: next.materialFolders).last {
                    next.materialFolders[i].courseID = parent.courseID
                }
            }
            for i in next.materials.indices {
                let material = next.materials[i]
                guard material.isManaged else {
                    if let folder = next.materialFolders.first(where: { $0.id == material.folderID }) { next.materials[i].courseID = folder.courseID }
                    continue
                }
                guard let entry = locate("file:\(material.id)", directory: false) else {
                    next.materials[i].isMissing = true
                    if let folder = next.materialFolders.first(where: { $0.id == material.folderID }) { next.materials[i].courseID = folder.courseID }
                    continue
                }
                let (courseID, folderID) = try ensureFolder(parentPath(entry.path))
                next.materials[i].isMissing = nil
                next.materials[i].storedPath = entry.path
                if courseID != material.courseID || folderID != material.folderID { next.materials[i].customOrder = nil }
                next.materials[i].courseID = courseID; next.materials[i].folderID = folderID
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                if name != URL(fileURLWithPath: material.storedPath).lastPathComponent {
                    let prefix = "\(material.id)-", original = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
                    if material.title == URL(fileURLWithPath: material.originalName).deletingPathExtension().lastPathComponent {
                        let title = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
                        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.materials[i].title = title }
                    }
                    next.materials[i].originalName = original; next.materials[i].storageName = name
                }
                let canonicalParent = folderID == nil ? (courseID.flatMap { layout.materialRoots[$0] } ?? MaterialStorageLayout.materialRoot(for: nil)) : parentPath(entry.path)
                next.materials[i].storageDirectory = canonicalParent == parentPath(entry.path) ? nil : parentPath(entry.path)
                if entry.path != material.storedPath || fileObservations["file:\(material.id)"]?.size != entry.size {
                    next.materials[i].size = entry.size
                }
            }
            let renamedCourses = next.courses.filter { course in snapshot.courses.first { $0.id == course.id }?.name != course.name }
            for i in next.tasks.indices where !next.tasks[i].isArchived {
                if let course = renamedCourses.first(where: { $0.id == next.tasks[i].courseID }) { next.tasks[i].courseNameSnapshot = course.name }
                for e in next.tasks[i].exceptions.indices {
                    if let course = renamedCourses.first(where: { $0.id == next.tasks[i].exceptions[e].details?.courseID }) {
                        next.tasks[i].exceptions[e].details?.courseNameSnapshot = course.name
                    }
                }
            }
            let changed = next != snapshot
            try publishFileSystemChanges(next)
            try refreshFileObservations()
            return changed
        }
    }

    func validateStorageOverrides(_ state: LibraryState) throws {
        for path in state.courses.compactMap(\.storageDirectory) + state.materialFolders.compactMap(\.storageDirectory) where path == "files" {
            throw LibraryError.unsafePath(path)
        }
        for path in state.courses.compactMap(\.storageDirectory) + state.materialFolders.compactMap(\.storageDirectory) + state.materials.compactMap(\.storageDirectory) {
            guard path == "files" || (path.hasPrefix("files/") && !path.hasSuffix("/")),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.contains("\0") else { throw LibraryError.unsafePath(path) }
        }
        for name in state.courses.compactMap(\.materialRootName) + state.materials.compactMap(\.storageName) {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw LibraryError.unsafePath(name) }
        }
    }
}
