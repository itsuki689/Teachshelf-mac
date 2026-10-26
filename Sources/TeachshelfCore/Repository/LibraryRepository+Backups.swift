import Foundation
import Darwin

extension LibraryRepository {
    /// A backup is a macOS directory package. It includes orphan files left by
    /// record deletion, all internal homework folders, and previous restore history.
    public func backup(to destination: URL) throws {
        try withLock {
            try synchronizeFileSystem()
            try prepareDestination(destination)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-backup-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try Self.encoder.encode(snapshot).write(to: staging.appendingPathComponent("library.json"), options: .withoutOverwriting)
            for name in ["files", "HomeworkFiles", "History"] {
                let source = root.appendingPathComponent(name)
                if fileManager.fileExists(atPath: source.path) { try copyTree(source, to: staging.appendingPathComponent(name)) }
            }
            let marker = Data("{\"format\":\"Teachshelf macOS backup\",\"version\":1}".utf8)
            try marker.write(to: staging.appendingPathComponent("backup.json"))
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    public func restore(from source: URL) throws {
        try withLock {
            let source = source.standardizedFileURL
            try ensureDirectory(source)
            guard !isBeneath(source, root: root), !isBeneath(root, root: source) else { throw LibraryError.invalidInput("请选择当前资料库以外的备份。") }
            let sourceIndex = source.appendingPathComponent("library.json")
            try ensureSafePath(sourceIndex, beneath: source)
            // Drain previous file transactions before publishing a restore log.
            try synchronizeFileSystem()
            try restoreBackupTransaction(from: source, sourceIndex: sourceIndex)
        }
    }

    /// Copies the entire library, preserving the source and excluding its writer lock.
    public func copyLibrary(to destination: URL) throws {
        try withLock {
            try synchronizeFileSystem()
            let destination = destination.standardizedFileURL
            let replacingEmptyDirectory = try prepareDestination(destination, allowEmptyDirectory: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-migrate-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if child.lastPathComponent == ".teachshelf.lock" || child.lastPathComponent.hasPrefix(".restore-") || child.lastPathComponent.hasPrefix(".index-") || child.lastPathComponent.hasPrefix(".backup-") { continue }
                try copyTree(child, to: staging.appendingPathComponent(child.lastPathComponent))
            }
            // Decode and validate the copied index before exposing the destination.
            let copied = try Self.decode(Data(contentsOf: staging.appendingPathComponent("library.json")))
            try validate(copied)
            if replacingEmptyDirectory {
                try ensureDirectory(destination)
                // rmdir is atomic and fails if anything was added after the empty check.
                guard Darwin.rmdir(destination.path) == 0 else {
                    throw LibraryError.invalidInput("目标文件夹已包含文件，请重新选择一个空文件夹。")
                }
            }
            // RENAME_EXCL refuses replacement even if a destination appears concurrently.
            if Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                if replacingEmptyDirectory, !fileManager.fileExists(atPath: destination.path) { try? fileManager.createDirectory(at: destination, withIntermediateDirectories: false) }
                throw error
            }
        }
    }

    @discardableResult private func prepareDestination(_ destination: URL, allowEmptyDirectory: Bool = false) throws -> Bool {
        let destination = destination.standardizedFileURL
        guard !isBeneath(destination, root: root), !isBeneath(root, root: destination) else { throw LibraryError.invalidInput("目标文件夹不能位于当前资料库内部。") }
        try ensureSafePath(destination, beneath: nil)
        if fileManager.fileExists(atPath: destination.path) {
            guard allowEmptyDirectory else { throw LibraryError.invalidInput("目标已存在，请选择新的文件夹名称。") }
            try ensureDirectory(destination)
            guard try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty else { throw LibraryError.invalidInput("请选择一个空文件夹，已有文件将保留。") }
            return true
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return false
    }
}
