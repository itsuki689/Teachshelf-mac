import Foundation
import Darwin
import Testing
@testable import TeachshelfCore

/// The parent kills a separate Swift Testing runner, so no catch/defer or object
/// teardown in the repository can simulate a successful crash recovery.
@Suite(.serialized)
struct BackupRestoreRecoveryTests {
    private let fm = FileManager.default
    private struct Fixture {
        let base: URL
        let old: LibraryState
        let new: LibraryState
        let oldFiles: [String: Data]
        let newFiles: [String: Data]
        var root: URL { base.appendingPathComponent("Library") }
        var backup: URL { base.appendingPathComponent("Backup.teachshelfbackup") }
        var journal: URL { root.appendingPathComponent(".backup-restore.json") }
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        guard fm.fileExists(atPath: root.path) else { return [:] }
        var result: [String: Data] = [:]
        func visit(_ url: URL, key: String) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { result[key] = Data((try fm.destinationOfSymbolicLink(atPath: url.path)).utf8) }
            else if values.isDirectory == true {
                result[key + "/"] = Data()
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try visit(child, key: key + "/" + child.lastPathComponent) }
            } else { result[key] = try Data(contentsOf: url) }
        }
        try visit(root, key: "")
        return result
    }

    private func files(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in ["files", "HomeworkFiles"] {
            for (path, bytes) in try tree(root.appendingPathComponent(name)) { result[name + path] = bytes }
        }
        return result
    }

    private func expectFiles(_ root: URL, _ expected: [String: Data]) throws {
        let actual = try files(root)
        let changed = Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.sorted()
        #expect(actual == expected, "File differences: \(changed)")
    }

    private func fixture(identicalIndex: Bool = false, _ action: (Fixture) throws -> Void) throws {
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-restore-process-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Library"), backup = base.appendingPathComponent("Backup.teachshelfbackup")
        let source = base.appendingPathComponent("Source")
        let old: LibraryState, new: LibraryState
        do {
            let repo = try LibraryRepository(root: root)
            let course = Course(name: "原课程")
            try repo.saveCourse(course)
            let folder = try repo.createMaterialFolder(name: "第一章", courseID: course.id)
            _ = try repo.createMaterialFolder(name: "空目录", courseID: course.id, parentID: folder.id)
            let input = base.appendingPathComponent("lecture.txt"); try write("old-content", input)
            _ = try repo.importFiles(urls: [input], courseID: course.id, category: "课件", copy: true, folderID: folder.id)
            var material = try #require(repo.state.materials.first)
            material.tags = "标签"; material.notes = "原备注"; try repo.updateMaterial(material)
            try repo.saveTask(StudyTask(title: "关联计划", courseID: course.id, materialIDs: [material.id]))
            try write("old-homework", repo.homeworkURL(courseID: course.id).appendingPathComponent("answer.txt"))
            try write("old-orphan", root.appendingPathComponent("files/orphan.txt"))
            try write("old-legacy", root.appendingPathComponent("HomeworkFiles/retired/answer.txt"))
            try write("keep-history", root.appendingPathComponent("History/existing.txt"))
            old = repo.state
            try repo.copyLibrary(to: source)
        }
        do {
            let repo = try LibraryRepository(root: source)
            if !identicalIndex {
                var course = repo.state.courses[0]; course.name = "新课程"; try repo.saveCourse(course)
                var material = repo.state.materials[0]; material.notes = "新备注"; try repo.updateMaterial(material)
                var task = repo.state.tasks[0]; task.title = "恢复后的计划"; try repo.saveTask(task)
            }
            try write("new-content", repo.resolveURL(repo.state.materials[0]))
            try write("new-homework", repo.homeworkURL(courseID: repo.state.courses[0].id).appendingPathComponent("answer.txt"))
            try write("new-orphan", source.appendingPathComponent("files/orphan.txt"))
            try write("new-legacy", source.appendingPathComponent("HomeworkFiles/retired/answer.txt"))
            try write("backup-history", source.appendingPathComponent("History/from-backup.txt"))
            try repo.backup(to: backup)
            new = repo.state
        }
        if identicalIndex { #expect(old == new) }
        try action(Fixture(base: base, old: old, new: new, oldFiles: files(root), newFiles: files(backup)))
    }

    @Test func restoreCrashWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let basePath = env["TEACHSHELF_RESTORE_TEST_BASE"], let checkpoint = env["TEACHSHELF_RESTORE_TEST_CHECKPOINT"],
              let marker = env["TEACHSHELF_RESTORE_TEST_MARKER"] else { return }
        let base = URL(fileURLWithPath: basePath)
        let hook: (String) throws -> Void = { point in
            if point == checkpoint {
                try Data(point.utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
                // Stop before returning to repository code. Only the parent sends
                // SIGKILL; the worker never exits normally at a fault boundary.
                Darwin.kill(Darwin.getpid(), SIGSTOP)
                throw CocoaError(.userCancelled)
            }
        }
        let repo = try LibraryRepository(root: base.appendingPathComponent("Library"), restoreCheckpoint: hook)
        if env["TEACHSHELF_RESTORE_TEST_ACTION"] == "restore" {
            try repo.restore(from: base.appendingPathComponent("Backup.teachshelfbackup"))
        }
        Issue.record("Worker did not reach checkpoint \(checkpoint)")
    }

    private func terminate(_ fixture: Fixture, at checkpoint: String, action: String = "restore") throws {
        let marker = fixture.base.appendingPathComponent("checkpoint-\(UUID())")
        let output = fixture.base.appendingPathComponent("worker-\(UUID()).log")
        fm.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--testing-library", "swift-testing", "--filter", "BackupRestoreRecoveryTests/restoreCrashWorker"]
        // Recent macOS SwiftPM loads a Mach-O test bundle via its helper;
        // the helper needs the bundle path as well as the test filter.
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"), index + 1 < CommandLine.arguments.count {
            process.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1]] + process.arguments!
        }
        var env = ProcessInfo.processInfo.environment
        env["TEACHSHELF_RESTORE_TEST_BASE"] = fixture.base.path
        env["TEACHSHELF_RESTORE_TEST_CHECKPOINT"] = checkpoint
        env["TEACHSHELF_RESTORE_TEST_MARKER"] = marker.path
        env["TEACHSHELF_RESTORE_TEST_ACTION"] = action
        process.environment = env; process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(20)
        while !fm.fileExists(atPath: marker.path), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard fm.fileExists(atPath: marker.path) else {
            Issue.record("Checkpoint \(checkpoint) not reached (running: \(process.isRunning)): \((try? String(contentsOf: output, encoding: .utf8)) ?? "")")
            throw CocoaError(.fileReadUnknown)
        }
        #expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }

    private func verify(_ fixture: Fixture, committed: Bool) throws {
        let expected = committed ? fixture.new : fixture.old
        for _ in 0..<3 {
            let repo = try LibraryRepository(root: fixture.root)
            #expect(repo.state == expected)
            try expectFiles(fixture.root, committed ? fixture.newFiles : fixture.oldFiles)
            #expect(repo.state.materials.map(\.id) == fixture.old.materials.map(\.id))
            #expect(repo.state.tasks[0].materialIDs == [repo.state.materials[0].id])
            #expect(repo.state.materials[0].folderID == fixture.old.materials[0].folderID)
            #expect(try Data(contentsOf: repo.resolveURL(repo.state.materials[0])) == Data((committed ? "new-content" : "old-content").utf8))
            let history = fixture.root.appendingPathComponent("History")
            #expect(try String(contentsOf: history.appendingPathComponent("existing.txt"), encoding: .utf8) == "keep-history")
            let archives = try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Restore-") }
            #expect(archives.count == (committed ? 1 : 0))
            if committed, let archive = archives.first {
                try expectFiles(archive, fixture.oldFiles)
                #expect(try LibraryRepository.decode(Data(contentsOf: archive.appendingPathComponent("library.json"))) == fixture.old)
                #expect(try String(contentsOf: archive.appendingPathComponent("BackupHistory/from-backup.txt"), encoding: .utf8) == "backup-history")
            }
            #expect(!fm.fileExists(atPath: fixture.journal.path))
            #expect(!fm.fileExists(atPath: repo.physicalStorageJournalURL.path))
            #expect(!fm.fileExists(atPath: repo.relocationURL.path))
            #expect(try fm.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".restore-") })
        }
    }

    @Test(arguments: ["prepared", "historyPrepared", "oldMoved.files", "oldDirectoriesMoved", "installed.files", "installed.HomeworkFiles", "allDirectoriesInstalled", "indexInstalled", "recovery.committed", "recovery.stagingRemoved", "recovery.historySettled"])
    func processTerminationRestoresOneCompleteGeneration(checkpoint: String) throws {
        try fixture { f in
            try terminate(f, at: checkpoint)
            try verify(f, committed: checkpoint == "indexInstalled" || checkpoint.hasPrefix("recovery."))
        }
    }

    @Test(arguments: [false, true]) func identicalIndexBytesStillHaveAnUnambiguousCommitPoint(committed: Bool) throws {
        try fixture(identicalIndex: true) { f in
            try terminate(f, at: committed ? "indexInstalled" : "allDirectoriesInstalled")
            try verify(f, committed: committed)
        }
    }

    @Test(arguments: ["rollback.newReturned.HomeworkFiles", "rollback.oldReturned.HomeworkFiles", "rollback.newReturned.files", "rollback.oldReturned.files", "recovery.beforeCleanup", "recovery.stagingChildRemoved", "recovery.stagingRemoved", "recovery.historyChildRemoved", "recovery.historySettled"])
    func rollbackSurvivesASecondKilledProcess(checkpoint: String) throws {
        try fixture { f in
            try terminate(f, at: "allDirectoriesInstalled")
            try terminate(f, at: checkpoint, action: "open")
            try verify(f, committed: false)
        }
    }

    @Test(arguments: ["recovery.committed", "recovery.beforeCleanup", "recovery.stagingChildRemoved", "recovery.stagingRemoved", "recovery.historySettled"])
    func committedCleanupSurvivesASecondKilledProcess(checkpoint: String) throws {
        try fixture { f in
            try terminate(f, at: "indexInstalled")
            try terminate(f, at: checkpoint, action: "open")
            try verify(f, committed: true)
        }
    }

    @Test(arguments: ["prepared", "historyPrepared", "oldMoved.files", "oldDirectoriesMoved", "installed.files", "allDirectoriesInstalled"])
    func ordinaryErrorsRollBackWithoutReopening(checkpoint: String) throws {
        try fixture { f in
            do {
                let repo = try LibraryRepository(root: f.root)
                repo.restoreCheckpoint = { if $0 == checkpoint { throw CocoaError(.fileWriteUnknown) } }
                #expect(throws: (any Error).self) { try repo.restore(from: f.backup) }
                #expect(repo.state == f.old)
                #expect(try files(f.root) == f.oldFiles)
            }
            try verify(f, committed: false)
        }
    }

    @Test(arguments: ["invalidJSON", "unknownVersion", "outsideStaging", "outsideHistory", "directoryTraversal", "missingOldDirectory", "missingOldIndex", "missingNewIndex", "missingLiveIndex", "missingNewMaterial", "missingBackupHistory", "occupiedRoot", "symlinkRoot", "symlinkChild", "symlinkJournal", "symlinkStaging", "physicalLog", "relocationLog", "badDigest"])
    func unsafeOrIncompleteTransactionsPreserveTheScene(problem: String) throws {
        try fixture { f in
            try terminate(f, at: "oldDirectoriesMoved")
            var journal = try JSONDecoder().decode(LibraryRepository.BackupRestoreJournal.self, from: Data(contentsOf: f.journal))
            let history = f.root.appendingPathComponent(journal.historyPath)
            let staging = f.root.appendingPathComponent(journal.stagingPath)
            let outside = f.base.appendingPathComponent("Outside"); try write("untouched", outside.appendingPathComponent("keep.txt"))
            switch problem {
            case "invalidJSON": try Data("{broken".utf8).write(to: f.journal)
            case "unknownVersion": journal.version = 999
            case "outsideStaging": journal.stagingPath = "../Outside"
            case "outsideHistory": journal.historyPath = outside.path
            case "directoryTraversal": journal.directories[0].name = "../Outside"
            case "missingOldDirectory": try fm.moveItem(at: history.appendingPathComponent("files"), to: outside.appendingPathComponent("rescued"))
            case "missingOldIndex": try fm.removeItem(at: history.appendingPathComponent("library.json"))
            case "missingNewIndex": try fm.removeItem(at: staging.appendingPathComponent("library.json"))
            case "missingLiveIndex": try fm.removeItem(at: f.root.appendingPathComponent("library.json"))
            case "missingNewMaterial": try fm.removeItem(at: staging.appendingPathComponent(f.new.materials[0].storedPath))
            case "missingBackupHistory": try fm.removeItem(at: staging.appendingPathComponent("BackupHistory"))
            case "occupiedRoot": try write("unrelated", f.root.appendingPathComponent("files/collision.txt"))
            case "symlinkRoot": try fm.createSymbolicLink(at: f.root.appendingPathComponent("files"), withDestinationURL: outside)
            case "symlinkChild": try fm.createSymbolicLink(at: history.appendingPathComponent("files/link"), withDestinationURL: outside)
            case "symlinkJournal":
                try fm.moveItem(at: f.journal, to: outside.appendingPathComponent("journal"))
                try fm.createSymbolicLink(at: f.journal, withDestinationURL: outside.appendingPathComponent("journal"))
            case "symlinkStaging":
                try fm.moveItem(at: staging, to: outside.appendingPathComponent("rescued"))
                try fm.createSymbolicLink(at: staging, withDestinationURL: outside.appendingPathComponent("rescued"))
            case "physicalLog": try write("pending", f.root.appendingPathComponent(".physical-storage.jsonl"))
            case "relocationLog": try write("pending", f.root.appendingPathComponent(".material-relocation.json"))
            case "badDigest": journal.oldDigest = String(repeating: "0", count: 64)
            default: break
            }
            if ["unknownVersion", "outsideStaging", "outsideHistory", "directoryTraversal", "badDigest"].contains(problem) {
                try JSONEncoder().encode(journal).write(to: f.journal)
            }
            let before = try tree(f.root), external = try tree(outside)
            for _ in 0..<2 {
                do {
                    _ = try LibraryRepository(root: f.root)
                    Issue.record("Unsafe transaction unexpectedly opened")
                } catch { #expect(error.localizedDescription.contains("已保留现场")) }
                #expect(try tree(f.root) == before)
                #expect(try tree(outside) == external)
            }
        }
    }

    @Test(arguments: [false, true]) func legacyBackupMigrationFinishesBeforeLiveReplacement(committed: Bool) throws {
        try fixture { f in
            var legacy = f.new; legacy.schemaVersion = 6
            let original = f.backup.appendingPathComponent(legacy.materials[0].storedPath)
            legacy.materials[0].storedPath = "files/legacy.txt"
            try fm.moveItem(at: original, to: f.backup.appendingPathComponent("files/legacy.txt"))
            try LibraryRepository.encoder.encode(legacy).write(to: f.backup.appendingPathComponent("library.json"))
            try terminate(f, at: committed ? "indexInstalled" : "allDirectoriesInstalled")
            #expect(!fm.fileExists(atPath: f.root.appendingPathComponent(".physical-storage.jsonl").path))
            #expect(!fm.fileExists(atPath: f.root.appendingPathComponent(".material-relocation.json").path))
            try verify(f, committed: committed)
        }
    }

    @Test func pendingStorageLogsAreDrainedBeforeRestorePublishesItsJournal() throws {
        try fixture { f in
            do {
                let repo = try LibraryRepository(root: f.root)
                var next = repo.state; next.courses[0].name = "尚未提交的课程改名"
                next = try repo.organizedMaterials(next)
                let transaction = LibraryRepository.PhysicalStorageTransaction(repository: repo, next: next)
                try repo.preparePhysicalStorage(from: repo.state, candidates: next, to: next, repairDirectories: false, transaction: transaction)
                #expect(fm.fileExists(atPath: repo.physicalStorageJournalURL.path))
                try Data("[]".utf8).write(to: repo.relocationURL)
                let physical = repo.physicalStorageJournalURL, relocation = repo.relocationURL
                repo.restoreCheckpoint = { point in
                    if point == "prepared" {
                        #expect(!fm.fileExists(atPath: physical.path))
                        #expect(!fm.fileExists(atPath: relocation.path))
                    }
                }
                try repo.restore(from: f.backup)
            }
            try verify(f, committed: true)
        }
    }

    @Test func missingCommittedFileBlocksCleanupAndPreservesRecoveryCopy() throws {
        try fixture { f in
            try terminate(f, at: "indexInstalled")
            try fm.removeItem(at: f.root.appendingPathComponent(f.new.materials[0].storedPath))
            let before = try tree(f.root)
            for _ in 0..<2 {
                #expect(throws: (any Error).self) { _ = try LibraryRepository(root: f.root) }
                #expect(try tree(f.root) == before)
            }
        }
    }

    @Test(arguments: ["indexInstalled", "recovery.stagingChildRemoved"])
    func recoverablePostCommitErrorsFinishTheNewGeneration(checkpoint: String) throws {
        try fixture { f in
            do {
                let repo = try LibraryRepository(root: f.root)
                var failed = false
                repo.restoreCheckpoint = { point in
                    if point == checkpoint && !failed { failed = true; throw CocoaError(.fileWriteUnknown) }
                }
                try repo.restore(from: f.backup)
                #expect(failed)
                #expect(repo.state == f.new)
            }
            try verify(f, committed: true)
        }
    }
}
