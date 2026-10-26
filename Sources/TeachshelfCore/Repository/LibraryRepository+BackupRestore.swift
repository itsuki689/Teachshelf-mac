import Foundation
import Darwin

extension LibraryRepository {
    var backupRestoreJournalURL: URL { root.appendingPathComponent(".backup-restore.json") }

    struct RestoreIdentity: Codable, Equatable {
        var device: Int32
        var inode: UInt64
        var birthSeconds: Int64
        var birthNanoseconds: Int64
    }

    struct BackupRestoreJournal: Codable {
        enum Phase: String, Codable { case prepared, movingOld, installing, committing, committed, rollingBack, rolledBack }
        struct Directory: Codable {
            var name: String
            var old: RestoreIdentity?
            var new: RestoreIdentity
        }
        var version = 1
        var id: UUID
        var phase: Phase
        var stagingPath: String
        var historyPath: String
        var stagingIdentity: RestoreIdentity
        var historyIdentity: RestoreIdentity
        var oldIndex: RestoreIdentity
        var newIndex: RestoreIdentity
        var oldDigest: String
        var newDigest: String
        var directories: [Directory]
        var backupHistory: RestoreIdentity?
    }

    func requireNoPendingBackupRestore() throws {
        try ensureSafePath(backupRestoreJournalURL, beneath: root)
        if fileManager.fileExists(atPath: backupRestoreJournalURL.path) {
            throw restoreRecoveryError("上一次恢复尚未结束，请退出并重新打开资料库。")
        }
    }

    private func restoreRecoveryError(_ detail: String) -> LibraryError {
        .invalidLibrary("备份恢复未完成，已保留现场。请勿移动或删除 .backup-restore.json、.restore-* 和 History/Restore-*；关闭课屿，复制整个资料库后重试打开。若仍失败，请保留副本并检查日志所指的恢复目录。资料库：\(root.path)。\(detail)")
    }

    private func restoreIdentity(_ url: URL, directory: Bool) throws -> RestoreIdentity? {
        try ensureSafePath(url, beneath: root)
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw LibraryError.unsafePath(url.path) }
        return RestoreIdentity(device: value.st_dev, inode: value.st_ino,
                               birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }

    private func requiredRestoreIdentity(_ url: URL, directory: Bool) throws -> RestoreIdentity {
        guard let identity = try restoreIdentity(url, directory: directory) else { throw LibraryError.missingFile(url.path) }
        return identity
    }

    /// Validate the entire tree before any recursive cleanup. A symlink (including
    /// a dangling link) or a special file is never traversed or silently removed.
    private func checkRestoreTree(_ url: URL) throws {
        try ensureSafePath(url, beneath: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try checkRestoreTree(child) }
        } else if values.isRegularFile != true { throw LibraryError.unsafePath(url.path) }
    }

    private func writeRestoreJournal(_ journal: BackupRestoreJournal) throws {
        let temporary = root.appendingPathComponent(".restore-journal-\(UUID()).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try ensureSafePath(backupRestoreJournalURL, beneath: root)
        try Self.encoder.encode(journal).write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        try atomicRename(temporary, backupRestoreJournalURL)
    }

    private func moveRestoreItem(_ source: URL, to destination: URL) throws {
        try ensureSafePath(source, beneath: root)
        try ensureSafePath(destination, beneath: root)
        guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func discardRestoreDirectory(_ directory: URL, checkpoint: String) throws {
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            try checkRestoreTree(child)
            try fileManager.removeItem(at: child)
            try restoreCheckpoint?(checkpoint)
        }
        // Refuse to remove the root if new content appeared concurrently.
        guard Darwin.rmdir(directory.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func checkRestoreMaterials(_ state: LibraryState, directory: (String) throws -> URL) throws {
        try validate(state)
        for material in state.materials where material.isManaged && material.isMissing != true {
            let file = try directory(material.storedPath)
            _ = try requiredRestoreIdentity(file, directory: false)
        }
    }

    func restoreBackupTransaction(from source: URL, sourceIndex: URL) throws {
        let restored = try Self.decode(Data(contentsOf: sourceIndex))
        try validate(restored)
        let id = UUID()
        let staging = root.appendingPathComponent(".restore-\(id)", isDirectory: true)
        let history = root.appendingPathComponent("History/Restore-\(id)", isDirectory: true)
        let preparedHistory = staging.appendingPathComponent("Previous", isDirectory: true)
        try ensureSafePath(staging, beneath: root)
        try ensureSafePath(history, beneath: root)
        var published = false
        defer {
            // Before publication no live directory has moved. Once published,
            // only the journal replay may dispose of transaction-owned contents.
            if !published {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        for name in ["files", "HomeworkFiles"] {
            let from = source.appendingPathComponent(name), to = staging.appendingPathComponent(name)
            try ensureSafePath(from, beneath: source)
            if fileManager.fileExists(atPath: from.path) { try copyTree(from, to: to) }
            else { try fileManager.createDirectory(at: to, withIntermediateDirectories: false) }
        }
        try checkRestoreMaterials(restored) { staging.appendingPathComponent($0) }
        let sourceHistory = source.appendingPathComponent("History")
        try ensureSafePath(sourceHistory, beneath: source)
        if fileManager.fileExists(atPath: sourceHistory.path) { try copyTree(sourceHistory, to: staging.appendingPathComponent("BackupHistory")) }
        try Self.encoder.encode(restored).write(to: staging.appendingPathComponent("library.json"), options: .withoutOverwriting)

        // Complete old-format storage upgrades in isolation. Their logs never
        // refer to live directories and must be drained before the outer journal.
        let next: LibraryState
        do {
            let staged = try LibraryRepository(root: staging)
            try staged.recoverPhysicalStorage()
            try staged.recoverMaterialRelocation()
            next = staged.state
        }
        try fileManager.createDirectory(at: staging.appendingPathComponent("HomeworkFiles"), withIntermediateDirectories: true)
        try checkRestoreTree(staging)
        // Even the History copy is prepared privately; the durable journal is
        // published before creating anything under the live History directory.
        try fileManager.createDirectory(at: preparedHistory, withIntermediateDirectories: false)
        let oldData = try Data(contentsOf: indexURL)
        try oldData.write(to: preparedHistory.appendingPathComponent("library.json"), options: .withoutOverwriting)
        let oldHandle = try FileHandle(forWritingTo: preparedHistory.appendingPathComponent("library.json"))
        try oldHandle.synchronize(); try oldHandle.close()
        var directories: [BackupRestoreJournal.Directory] = []
        for name in ["files", "HomeworkFiles"] {
            let current = root.appendingPathComponent(name)
            let old = try restoreIdentity(current, directory: true)
            if old != nil { try checkRestoreTree(current) }
            directories.append(.init(name: name, old: old, new: try requiredRestoreIdentity(staging.appendingPathComponent(name), directory: true)))
        }
        let newIndex = staging.appendingPathComponent("library.json")
        // Also flush a backup that required no index rewrite during staging.
        let handle = try FileHandle(forWritingTo: newIndex)
        try handle.synchronize(); try handle.close()
        var journal = BackupRestoreJournal(id: id, phase: .prepared,
            stagingPath: staging.lastPathComponent, historyPath: "History/\(history.lastPathComponent)",
            stagingIdentity: try requiredRestoreIdentity(staging, directory: true), historyIdentity: try requiredRestoreIdentity(preparedHistory, directory: true),
            oldIndex: try requiredRestoreIdentity(indexURL, directory: false), newIndex: try requiredRestoreIdentity(newIndex, directory: false),
            oldDigest: Self.storageDigest(oldData), newDigest: Self.storageDigest(try Data(contentsOf: newIndex)), directories: directories,
            backupHistory: try restoreIdentity(staging.appendingPathComponent("BackupHistory"), directory: true))
        try requireNoPendingBackupRestore()
        try writeRestoreJournal(journal)
        published = true
        do {
            try restoreCheckpoint?("prepared")
            try ensureSafePath(history, beneath: root)
            try fileManager.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
            try moveRestoreItem(preparedHistory, to: history)
            try restoreCheckpoint?("historyPrepared")
            journal.phase = .movingOld; try writeRestoreJournal(journal)
            for item in journal.directories where item.old != nil {
                try moveRestoreItem(root.appendingPathComponent(item.name), to: history.appendingPathComponent(item.name))
                try restoreCheckpoint?("oldMoved.\(item.name)")
            }
            try restoreCheckpoint?("oldDirectoriesMoved")
            journal.phase = .installing; try writeRestoreJournal(journal)
            for item in journal.directories {
                try moveRestoreItem(staging.appendingPathComponent(item.name), to: root.appendingPathComponent(item.name))
                try restoreCheckpoint?("installed.\(item.name)")
            }
            if journal.backupHistory != nil {
                try moveRestoreItem(staging.appendingPathComponent("BackupHistory"), to: history.appendingPathComponent("BackupHistory"))
            }
            try restoreCheckpoint?("allDirectoriesInstalled")
            try checkRestoreMaterials(next) { root.appendingPathComponent($0) }
            journal.phase = .committing; try writeRestoreJournal(journal)
            try installPreparedIndex(newIndex) // the only commit point
            try restoreCheckpoint?("indexInstalled") // intentionally before progress is updated
            journal.phase = .committed; try writeRestoreJournal(journal)
            try recoverBackupRestore()
            try reloadAfterBackupRestore()
        } catch {
            let original = error
            do {
                try recoverBackupRestore()
                try reloadAfterBackupRestore()
            } catch { throw restoreRecoveryError(error.localizedDescription) }
            // A cleanup error cannot undo a committed index. If replay finished
            // successfully, report the completed restore rather than a rollback.
            if try restoreIdentity(indexURL, directory: false) == journal.newIndex { return }
            throw original
        }
    }

    /// Replaying uses both durable phase and inode placement, never assumes that
    /// an operation failed just because its following progress write is absent.
    func recoverBackupRestore() throws {
        do { try replayBackupRestore() }
        catch { throw restoreRecoveryError(error.localizedDescription) }
    }

    private func replayBackupRestore() throws {
        try ensureSafePath(backupRestoreJournalURL, beneath: root)
        guard fileManager.fileExists(atPath: backupRestoreJournalURL.path) else { return }
        var journal = try JSONDecoder().decode(BackupRestoreJournal.self, from: Data(contentsOf: backupRestoreJournalURL))
        guard journal.version == 1, journal.stagingPath == ".restore-\(journal.id)", journal.historyPath == "History/Restore-\(journal.id)",
              journal.directories.map(\.name) == ["files", "HomeworkFiles"], journal.oldIndex != journal.newIndex,
              [journal.oldDigest, journal.newDigest].allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw LibraryError.invalidLibrary("恢复日志的版本、事务身份、路径或摘要无效。")
        }
        // These journals cannot legitimately overlap: staging normalized the new
        // tree and restore drained live transactions before it published its log.
        for other in [physicalStorageJournalURL, relocationURL] {
            try ensureSafePath(other, beneath: root)
            guard !fileManager.fileExists(atPath: other.path) else { throw LibraryError.invalidLibrary("恢复日志与 \(other.lastPathComponent) 同时存在，无法安全判断目录所属事务。") }
        }
        let staging = root.appendingPathComponent(journal.stagingPath), archive = root.appendingPathComponent(journal.historyPath)
        let preparedHistory = staging.appendingPathComponent("Previous")
        let liveIndex = try requiredRestoreIdentity(indexURL, directory: false)
        let digest = Self.storageDigest(try Data(contentsOf: indexURL))
        let committed = liveIndex == journal.newIndex && digest == journal.newDigest
        let old = liveIndex == journal.oldIndex && digest == journal.oldDigest
        guard committed || old,
              !(committed && [.rollingBack, .rolledBack].contains(journal.phase)),
              !(old && journal.phase == .committed) else { throw LibraryError.invalidLibrary("主索引与恢复日志不匹配，不能确定提交点。") }
        let stagingIdentity = try restoreIdentity(staging, directory: true)
        let archivedIdentity = try restoreIdentity(archive, directory: true)
        let preparedIdentity = try restoreIdentity(preparedHistory, directory: true)
        guard (archivedIdentity == nil || archivedIdentity == journal.historyIdentity),
              (preparedIdentity == nil || preparedIdentity == journal.historyIdentity),
              !(archivedIdentity != nil && preparedIdentity != nil),
              !committed || archivedIdentity == journal.historyIdentity else {
            throw LibraryError.invalidLibrary("History 恢复目录的身份或位置不明确。")
        }
        let history = preparedIdentity != nil ? preparedHistory : archive
        let historyIdentity = try restoreIdentity(history, directory: true)
        guard (stagingIdentity == journal.stagingIdentity || (stagingIdentity == nil && (journal.phase == .committed || journal.phase == .rolledBack))),
              (historyIdentity == journal.historyIdentity || (historyIdentity == nil && journal.phase == .rolledBack)) else {
            throw LibraryError.invalidLibrary("恢复暂存目录或 History 副本缺失或已被替换。")
        }
        if stagingIdentity != nil { try checkRestoreTree(staging) }
        if historyIdentity != nil { try checkRestoreTree(history) }
        let liveState = try Self.decode(Data(contentsOf: indexURL))
        try validate(liveState)
        if journal.phase != .rolledBack {
            let oldIndex = history.appendingPathComponent("library.json")
            _ = try requiredRestoreIdentity(oldIndex, directory: false)
            guard Self.storageDigest(try Data(contentsOf: oldIndex)) == journal.oldDigest else { throw LibraryError.invalidLibrary("History 中的原索引缺失或损坏。") }
        }
        if committed {
            // Preflight all roots and both versions before cleanup touches anything.
            for item in journal.directories {
                guard try restoreIdentity(root.appendingPathComponent(item.name), directory: true) == item.new,
                      try restoreIdentity(history.appendingPathComponent(item.name), directory: true) == item.old,
                      try restoreIdentity(staging.appendingPathComponent(item.name), directory: true) == nil else {
                    throw LibraryError.invalidLibrary("提交后的目录版本不完整：\(item.name)。")
                }
                try checkRestoreTree(root.appendingPathComponent(item.name))
            }
            guard try restoreIdentity(history.appendingPathComponent("BackupHistory"), directory: true) == journal.backupHistory else {
                throw LibraryError.invalidLibrary("备份自带的 History 副本缺失。")
            }
            try checkRestoreMaterials(liveState) { root.appendingPathComponent($0) }
            let oldState = try Self.decode(Data(contentsOf: history.appendingPathComponent("library.json")))
            try checkRestoreMaterials(oldState) { history.appendingPathComponent($0) }
            journal.phase = .committed; try writeRestoreJournal(journal)
            try restoreCheckpoint?("recovery.committed")
            // Old inode observations must not reinterpret restored paths as Finder
            // moves. Enroll the selected generation afresh on the next normal scan.
            let observations = root.appendingPathComponent(".file-observations.json")
            try ensureSafePath(observations, beneath: root)
            if fileManager.fileExists(atPath: observations.path) { try fileManager.removeItem(at: observations) }
        } else if journal.phase != .rolledBack {
            // Validate all placements up front. Each old and new directory must
            // occur exactly once, in one of its two legal positions.
            for item in journal.directories {
                let live = try restoreIdentity(root.appendingPathComponent(item.name), directory: true)
                let archived = try restoreIdentity(history.appendingPathComponent(item.name), directory: true)
                let staged = try restoreIdentity(staging.appendingPathComponent(item.name), directory: true)
                guard (live == nil || live == item.old || live == item.new),
                      (archived == nil || archived == item.old), (staged == nil || staged == item.new),
                      [live, staged].compactMap({ $0 }).filter({ $0 == item.new }).count == 1,
                      item.old == nil ? archived == nil : [live, archived].compactMap({ $0 }).filter({ $0 == item.old }).count == 1 else {
                    throw LibraryError.invalidLibrary("无法安全还原目录：\(item.name)。存在缺失或同名占用。")
                }
                if live != nil { try checkRestoreTree(root.appendingPathComponent(item.name)) }
            }
            let preparedIndex = staging.appendingPathComponent("library.json")
            guard try restoreIdentity(preparedIndex, directory: false) == journal.newIndex,
                  Self.storageDigest(try Data(contentsOf: preparedIndex)) == journal.newDigest else { throw LibraryError.invalidLibrary("暂存的新索引缺失或损坏。") }
            let newState = try Self.decode(Data(contentsOf: preparedIndex))
            try checkRestoreMaterials(newState) { path in
                let name = String(path.prefix(while: { $0 != "/" }))
                guard let item = journal.directories.first(where: { $0.name == name }) else { throw LibraryError.unsafePath(path) }
                let base = try restoreIdentity(root.appendingPathComponent(name), directory: true) == item.new ? root : staging
                return base.appendingPathComponent(path)
            }
            let stagedHistory = try restoreIdentity(staging.appendingPathComponent("BackupHistory"), directory: true)
            let archivedHistory = try restoreIdentity(history.appendingPathComponent("BackupHistory"), directory: true)
            guard (stagedHistory == nil || stagedHistory == journal.backupHistory),
                  (archivedHistory == nil || archivedHistory == journal.backupHistory),
                  [stagedHistory, archivedHistory].compactMap({ $0 }).count == (journal.backupHistory == nil ? 0 : 1) else {
                throw LibraryError.invalidLibrary("备份自带的 History 副本缺失或已被替换。")
            }
            try checkRestoreMaterials(liveState) { path in
                let name = String(path.prefix(while: { $0 != "/" }))
                guard let item = journal.directories.first(where: { $0.name == name }), let identity = item.old else { throw LibraryError.unsafePath(path) }
                let base = try restoreIdentity(root.appendingPathComponent(name), directory: true) == identity ? root : history
                return base.appendingPathComponent(path)
            }
            journal.phase = .rollingBack; try writeRestoreJournal(journal)
            for item in journal.directories.reversed() {
                let live = root.appendingPathComponent(item.name)
                if try restoreIdentity(live, directory: true) == item.new {
                    try moveRestoreItem(live, to: staging.appendingPathComponent(item.name))
                    try restoreCheckpoint?("rollback.newReturned.\(item.name)")
                }
                if let identity = item.old, try restoreIdentity(live, directory: true) != identity {
                    try moveRestoreItem(history.appendingPathComponent(item.name), to: live)
                    try restoreCheckpoint?("rollback.oldReturned.\(item.name)")
                }
            }
            journal.phase = .rolledBack; try writeRestoreJournal(journal)
        }
        if !committed {
            for item in journal.directories {
                guard try restoreIdentity(root.appendingPathComponent(item.name), directory: true) == item.old,
                      try restoreIdentity(history.appendingPathComponent(item.name), directory: true) == nil else {
                    throw LibraryError.invalidLibrary("回滚目录尚未完整归位：\(item.name)。")
                }
            }
            try checkRestoreMaterials(liveState) { root.appendingPathComponent($0) }
        }
        // Terminal phases are persisted before recursive cleanup; partial removal
        // can be retried without requiring already-discarded staging files.
        try restoreCheckpoint?("recovery.beforeCleanup")
        if stagingIdentity != nil { try discardRestoreDirectory(staging, checkpoint: "recovery.stagingChildRemoved") }
        try restoreCheckpoint?("recovery.stagingRemoved")
        if !committed && historyIdentity != nil && fileManager.fileExists(atPath: history.path) {
            try discardRestoreDirectory(history, checkpoint: "recovery.historyChildRemoved")
        }
        try restoreCheckpoint?("recovery.historySettled")
        try fileManager.removeItem(at: backupRestoreJournalURL)
    }
}
