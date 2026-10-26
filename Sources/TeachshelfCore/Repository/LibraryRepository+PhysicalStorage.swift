import Foundation
import CryptoKit
import Darwin

extension LibraryRepository {
    var physicalStorageJournalURL: URL { root.appendingPathComponent(".physical-storage.jsonl") }

    struct StorageJournalEntry: Codable {
        enum Kind: String, Codable { case begin, move, mkdir, cleanup, duplicate, commit, undo }
        var kind: Kind
        var source: String? = nil
        var destination: String? = nil
        var device: Int32? = nil
        var inode: UInt64? = nil
        var indexDigest: String? = nil
        var indexChanges: Bool? = nil
        var completed: Int? = nil
    }

    static func storageDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Append-only write-ahead log: each complete record is flushed before its
    /// operation. A torn final line cannot describe an operation that has run.
    final class PhysicalStorageTransaction {
        let repository: LibraryRepository
        private let next: LibraryState
        private var started = false

        init(repository: LibraryRepository, next: LibraryState) {
            self.repository = repository
            self.next = next
        }

        func append(_ entry: StorageJournalEntry) throws {
            let journal = repository.physicalStorageJournalURL
            try repository.ensureSafePath(journal, beneath: repository.root)
            let encoder = JSONEncoder()
            if !started {
                let digest = LibraryRepository.storageDigest(try LibraryRepository.encoder.encode(next))
                let current = LibraryRepository.storageDigest(try Data(contentsOf: repository.indexURL))
                let header = StorageJournalEntry(kind: .begin, indexDigest: digest, indexChanges: digest != current)
                try (encoder.encode(header) + Data([10])).write(to: journal, options: .withoutOverwriting)
                started = true
            }
            try repository.appendStorageJournalEntry(entry)
        }

        func ensureDirectory(_ path: String) throws {
            guard path != "files" else { return }
            let url = try repository.relocationFile(path)
            if repository.fileManager.fileExists(atPath: url.path) {
                try repository.ensureDirectory(url)
                return
            }
            let parent = String(path[..<(path.lastIndex(of: "/")!)])
            try ensureDirectory(parent)
            try append(StorageJournalEntry(kind: .mkdir, destination: path))
            try repository.fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }

        func move(_ sourcePath: String, to destinationPath: String, directory: Bool = false) throws {
            guard sourcePath != destinationPath else { return }
            let source = try repository.relocationFile(sourcePath)
            let destination = try repository.relocationFile(destinationPath)
            guard repository.fileManager.fileExists(atPath: source.path) else {
                // Missing records stay visible, but must not acquire unrelated bytes.
                guard !repository.fileManager.fileExists(atPath: destination.path) else {
                    throw LibraryError.invalidInput("目标位置已有文件，无法恢复缺失资料：\(destination.path)")
                }
                return
            }
            var identity = stat()
            guard lstat(source.path, &identity) == 0,
                  identity.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
                throw LibraryError.unsafePath(source.path)
            }
            try ensureDirectory(String(destinationPath[..<(destinationPath.lastIndex(of: "/")!)]))
            var targetIdentity = stat()
            let exists = lstat(destination.path, &targetIdentity) == 0
            let sameItem = exists && identity.st_dev == targetIdentity.st_dev && identity.st_ino == targetIdentity.st_ino
            if exists && !sameItem {
                if !directory && repository.sameMaterialContents(source, destination) {
                    try append(StorageJournalEntry(kind: .duplicate, source: sourcePath, destination: destinationPath))
                    return
                }
                throw LibraryError.invalidInput("目标位置已存在同名内容，请先在 Finder 中处理：\(destination.path)")
            }
            // A temporary hop handles case-only renames on case-insensitive disks.
            if sameItem {
                let temporary = "files/.physical-move-\(UUID().uuidString)"
                try rename(sourcePath, to: temporary, identity: identity)
                if !directory && repository.fileManager.fileExists(atPath: destination.path) {
                    // Two distinct hard links, rather than two spellings of one path.
                    try append(StorageJournalEntry(kind: .duplicate, source: temporary, destination: destinationPath))
                } else { try rename(temporary, to: destinationPath, identity: identity) }
            } else {
                try rename(sourcePath, to: destinationPath, identity: identity)
            }
        }

        private func rename(_ source: String, to destination: String, identity: stat) throws {
            let from = try repository.relocationFile(source), to = try repository.relocationFile(destination)
            try append(StorageJournalEntry(kind: .move, source: source, destination: destination,
                                           device: identity.st_dev, inode: identity.st_ino))
            guard Darwin.renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        func cleanup(_ directory: String) throws {
            try append(StorageJournalEntry(kind: .cleanup, source: directory))
        }

        func finish() throws {
            guard started else { return }
            try append(StorageJournalEntry(kind: .commit))
            try repository.recoverPhysicalStorage()
        }
    }

    func appendStorageJournalEntry(_ entry: StorageJournalEntry) throws {
        try ensureSafePath(physicalStorageJournalURL, beneath: root)
        let handle = try FileHandle(forWritingTo: physicalStorageJournalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(entry) + Data([10]))
        try handle.synchronize()
    }

    func recoverPhysicalStorage(rollingBack: Bool = false) throws {
        try requireNoPendingBackupRestore()
        let journal = physicalStorageJournalURL
        try ensureSafePath(journal, beneath: root)
        guard fileManager.fileExists(atPath: journal.path) else { return }
        let data = try Data(contentsOf: journal)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let entries = try lines.map { try JSONDecoder().decode(StorageJournalEntry.self, from: Data($0)) }
        guard let header = entries.first, header.kind == .begin, let digest = header.indexDigest,
              !entries.dropFirst().contains(where: { $0.kind == .begin }) else {
            throw LibraryError.invalidLibrary("文件整理日志不完整，请保留日志并恢复资料库备份。")
        }
        var committed = false
        if !rollingBack && !entries.contains(where: { $0.kind == .undo }) {
            if entries.last?.kind == .commit { committed = true }
            else if header.indexChanges == true { committed = Self.storageDigest(try Data(contentsOf: indexURL)) == digest }
        }
        if committed {
            for entry in entries where entry.kind == .duplicate {
                let source = try relocationFile(try journalPath(entry.source))
                let destination = try relocationFile(try journalPath(entry.destination))
                if sameMaterialContents(source, destination) { try fileManager.removeItem(at: source) }
            }
            // Only empty, obsolete directories are removed. Files outside the index
            // (including deliberately removed records) remain on disk.
            let retained = MaterialStorageLayout.Directories(courses: snapshot.courses, folders: snapshot.materialFolders).required(in: snapshot)
            let directories = try entries.filter { $0.kind == .cleanup }.map { try journalPath($0.source) }
            for path in Set(directories).sorted(by: { $0.count > $1.count }) where !retained.contains(path) {
                let url = try relocationFile(path)
                _ = Darwin.rmdir(url.path)
            }
            _ = Darwin.rmdir(root.appendingPathComponent("HomeworkFiles").path)
        } else {
            let actions = entries.filter { ![.begin, .commit, .undo].contains($0.kind) }
            let completed = entries.last(where: { $0.kind == .undo })?.completed ?? 0
            guard (0...actions.count).contains(completed) else { throw LibraryError.invalidLibrary("文件恢复日志进度无效。") }
            // Remove an unflushed partial line before appending recovery progress.
            // Persist each inverse before undoing its ancestor directory, so a
            // second termination cannot make earlier paths impossible to locate.
            if data.last != 10, let newline = data.lastIndex(of: 10) {
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(newline + 1))
                try handle.synchronize()
            }
            for (offset, entry) in actions.reversed().enumerated().dropFirst(completed) {
                switch entry.kind {
                case .move:
                    let source = try relocationFile(try journalPath(entry.source))
                    let destination = try relocationFile(try journalPath(entry.destination))
                    func matches(_ url: URL) -> Bool {
                        var value = stat()
                        return lstat(url.path, &value) == 0 && value.st_dev == entry.device && value.st_ino == entry.inode
                    }
                    if !matches(source) { // operation did not run, or already rolled back
                        guard matches(destination), !fileManager.fileExists(atPath: source.path),
                              Darwin.renamex_np(destination.path, source.path, UInt32(RENAME_EXCL)) == 0 else {
                            throw LibraryError.invalidLibrary("无法恢复移动的文件，原路径可能被占用：\(source.path)")
                        }
                    }
                case .mkdir:
                    let url = try relocationFile(try journalPath(entry.destination))
                    _ = Darwin.rmdir(url.path) // never recursively remove new user content
                default: break
                }
                try appendStorageJournalEntry(StorageJournalEntry(kind: .undo, completed: offset + 1))
            }
        }
        try fileManager.removeItem(at: journal)
    }

    private func journalPath(_ path: String?) throws -> String {
        guard let path else { throw LibraryError.invalidLibrary("文件整理日志缺少路径。") }
        return path
    }

    func preparePhysicalStorage(from before: LibraryState, candidates: LibraryState, to next: LibraryState,
                                repairDirectories: Bool, transaction: PhysicalStorageTransaction) throws {
        let old = MaterialStorageLayout.Directories(courses: before.courses, folders: before.materialFolders)
        let new = MaterialStorageLayout.Directories(courses: next.courses, folders: next.materialFolders)
        var rewrites: [(String, String)] = []
        func transformed(_ original: String) -> String {
            rewrites.reduce(original) { path, pair in
                path == pair.0 || path.hasPrefix(pair.0 + "/") ? pair.1 + path.dropFirst(pair.0.count) : path
            }
        }
        // Rename entire directories, including unindexed contents. Descendant
        // material paths are rewritten in memory; their bytes need no per-file I/O.
        for course in before.courses {
            guard let source = old.courses[course.id], let target = new.courses[course.id], source != target else { continue }
            try transaction.move(source, to: target, directory: true)
            rewrites.append((source, target))
        }
        if before.schemaVersion >= 8 {
            for folder in before.materialFolders.sorted(by: { old.folders[$0.id]!.count < old.folders[$1.id]!.count }) {
                guard let original = old.folders[folder.id], let target = new.folders[folder.id] else { continue }
                let source = transformed(original)
                guard source != target else { continue }
                try transaction.move(source, to: target, directory: true)
                rewrites.append((source, target))
            }
        }
        let required = new.required(in: next)
        if repairDirectories || before.schemaVersion < 8 || old.required(in: before) != required {
            for path in required.sorted(by: { $0.count < $1.count }) { try transaction.ensureDirectory(path) }
        }
        var obsolete = old.required(in: before).map(transformed).filter { !required.contains($0) }
        for (source, record) in zip(candidates.materials, next.materials) where source.isManaged {
            let path = transformed(source.storedPath)
            guard path != record.storedPath else { continue }
            try transaction.move(path, to: record.storedPath)
            var parent = String(path[..<(path.lastIndex(of: "/")!)])
            while parent != "files", parent.hasPrefix("files/") {
                if !required.contains(parent) { obsolete.append(parent) }
                parent = String(parent[..<(parent.lastIndex(of: "/")!)])
            }
        }
        if repairDirectories || before.schemaVersion < 8 {
            for relocation in try homeworkRelocations(in: next) {
                if relocation.directory == true {
                    try transaction.ensureDirectory(relocation.destination)
                    obsolete.append(relocation.source)
                } else { try transaction.move(relocation.source, to: relocation.destination) }
            }
        }
        for path in Set(obsolete) { try transaction.cleanup(path) }
    }
}
