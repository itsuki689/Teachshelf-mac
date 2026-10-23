import Foundation
import Darwin

extension LibraryRepository {
    func atomicRename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func isBeneath(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
    func rejectSymbolicLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            // Foundation standardizes /private/var and /private/tmp back to these
            // macOS system aliases. Permit only their exact, system-owned targets.
            if url.path == "/var" || url.path == "/tmp" {
                let expected = "private" + url.path
                if let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path), target == expected || target == "/" + expected { return }
            }
            throw LibraryError.unsafePath(url.path)
        }
    }
    func ensureSafePath(_ url: URL, beneath base: URL?) throws {
        let url = url.standardizedFileURL
        if let base, !isBeneath(url, root: base) { throw LibraryError.unsafePath(url.path) }
        var cursor = url
        while cursor.path != "/" {
            try rejectSymbolicLink(cursor)
            if let base, cursor.path == base.path { break }
            cursor.deleteLastPathComponent()
        }
    }
    func ensureDirectory(_ url: URL) throws {
        try ensureSafePath(url, beneath: nil)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw LibraryError.invalidInput("请选择一个现有文件夹：\(url.path)") }
    }

    /// Copy a tree explicitly, refusing links instead of allowing Foundation to copy links.
    func copyTree(_ source: URL, to target: URL) throws {
        try rejectSymbolicLink(source)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, to: target.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true { try fileManager.copyItem(at: source, to: target) }
        else { throw LibraryError.unsafePath(source.path) }
    }
}
