import Foundation

extension LibraryRepository {
    public func homeworkURL(courseID: UUID?) throws -> URL {
        try withLock {
            try ensureCourse(courseID)
            if let courseID, let mount = snapshot.courses.first(where: { $0.id == courseID })?.homeworkFolder {
                let url = URL(fileURLWithPath: mount).standardizedFileURL
                try ensureDirectory(url)
                return url
            }
            let course = snapshot.courses.first { $0.id == courseID }
            let url = root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course), isDirectory: true)
            try ensureSafePath(url, beneath: root)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    public func mountHomework(courseID: UUID, url: URL?) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == courseID }) else { throw LibraryError.missingRecord("课程") }
            if let url {
                try validateMount(url.standardizedFileURL, for: courseID, in: state)
                state.courses[index].homeworkFolder = url.standardizedFileURL.path
            } else { state.courses[index].homeworkFolder = nil }
        }
    }

    public func listHomework(courseID: UUID?, relativePath: String) throws -> [WorkspaceEntry] {
        try withLock {
            let folder = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(folder)
            return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]).compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else { return nil }
                return WorkspaceEntry(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public func importHomework(urls: [URL], courseID: UUID?, relativePath: String) throws -> ImportSummary {
        try withLock {
            let folder = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(folder)
            var summary = ImportSummary()
            for source in urls {
                var target: URL?
                do {
                    let source = source.standardizedFileURL
                    try ensureSafePath(source, beneath: nil)
                    // A directory cannot be copied into itself or one of its descendants.
                    guard !isBeneath(folder, root: source) else { throw LibraryError.invalidInput("不能将文件夹导入到自身内部。") }
                    let destination = uniqueURL(in: folder, name: source.lastPathComponent)
                    target = destination
                    try copyTree(source, to: destination)
                    summary.imported += 1
                } catch {
                    if let target { try? fileManager.removeItem(at: target) }
                    summary.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)"); summary.skipped += 1
                }
            }
            return summary
        }
    }

    /// Creates a real folder in the workspace, also used by the native New Folder action.
    @discardableResult public func createHomeworkFolder(name: String, courseID: UUID?, relativePath: String) throws -> URL {
        try withLock {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw LibraryError.invalidInput("请输入有效的文件夹名称。") }
            let parent = try workspaceFolder(courseID: courseID, relativePath: relativePath)
            try ensureDirectory(parent)
            let destination = uniqueURL(in: parent, name: name)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return destination
        }
    }

    private func workspaceFolder(courseID: UUID?, relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."), !relativePath.contains("\0") else { throw LibraryError.unsafePath(relativePath) }
        let base = try homeworkURL(courseID: courseID)
        let folder = relativePath.isEmpty ? base : base.appendingPathComponent(relativePath).standardizedFileURL
        try ensureSafePath(folder, beneath: base)
        return folder
    }

    func validateMount(_ url: URL, for courseID: UUID, in state: LibraryState) throws {
        try ensureDirectory(url)
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let libraryRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard !isBeneath(candidate, root: libraryRoot), !isBeneath(libraryRoot, root: candidate) else { throw LibraryError.invalidInput("挂载的作业文件夹必须位于资料库外部，且不能包含资料库。") }
        for other in state.courses where other.id != courseID {
            guard let path = other.homeworkFolder else { continue }
            // Disconnected mounts still reserve their stored path; no existence check.
            let mounted = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard !isBeneath(candidate, root: mounted), !isBeneath(mounted, root: candidate) else { throw LibraryError.invalidInput("该文件夹与课程“\(other.name)”的作业文件夹重叠，请选择独立文件夹。") }
        }
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        let initial = folder.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: initial.path) { return initial }
        let file = URL(fileURLWithPath: name)
        let suffix = file.pathExtension
        let base = suffix.isEmpty ? name : file.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }
}
