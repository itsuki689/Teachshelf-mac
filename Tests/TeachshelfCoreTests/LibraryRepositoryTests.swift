import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
final class LibraryRepositoryTests {
    private var sandboxes: [URL] = []
    deinit { for folder in sandboxes { try? FileManager.default.removeItem(at: folder) } }
    private func sandbox() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TeachshelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sandboxes.append(folder)
        return folder
    }
    private func file(_ folder: URL, _ name: String, content: String = "study") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    private func repository(_ folder: URL) throws -> LibraryRepository {
        try LibraryRepository(root: folder.appendingPathComponent("Library", isDirectory: true))
    }

    @Test func testMetadataPersistsAndKeepsPreviousIndex() throws {
        let folder = try sandbox(), course = Course(name: "线性代数", semester: "2026 秋")
        var repo: LibraryRepository? = try repository(folder)
        try repo!.saveCourse(course)
        try repo!.saveAppearance("dark")
        expectTrue(FileManager.default.fileExists(atPath: repo!.root.appendingPathComponent("library.json.bak").path))
        repo = nil
        let reopened = try repository(folder)
        expectEqual(reopened.state.courses, [course]); expectEqual(reopened.state.appearance, "dark")
    }

    @Test func testSecondWriterIsRejectedAndLockIsReleased() throws {
        let folder = try sandbox()
        var first: LibraryRepository? = try repository(folder)
        expectNotNil(first)
        expectThrows(try repository(folder)) { error in
            guard case LibraryError.locked = error else { return fail("Unexpected error: \(error)") }
        }
        first = nil
        expectNoThrow(try repository(folder))
    }

    @Test func testCorruptIndexIsPreserved() throws {
        let folder = try sandbox(), root = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try file(root, "library.json", content: "{invalid index")
        let before = try Data(contentsOf: index)
        expectThrows(try LibraryRepository(root: root))
        expectEqual(try Data(contentsOf: index), before)
        // A failed initialization must release its writer lock.
        try JSONEncoder().encode(LibraryState()).write(to: index)
        expectNoThrow(try LibraryRepository(root: root))
    }

    @Test func testMissingPrimaryWithBackupDoesNotCreateEmptyLibrary() throws {
        let folder = try sandbox(), root = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backup = try file(root, "library.json.bak", content: "preserve me")
        let before = try Data(contentsOf: backup)
        expectThrows(try LibraryRepository(root: root))
        expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        expectEqual(try Data(contentsOf: backup), before)
    }

    @Test func testUnsafeExistingFilesDirectoryDoesNotCreateIndex() throws {
        let folder = try sandbox(), root = folder.appendingPathComponent("Library"), external = folder.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("files"), withDestinationURL: external)
        expectThrows(try LibraryRepository(root: root))
        expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }

    @Test func testImportsRecursivelyDeduplicatesAndSeparatesCourses() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let source = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("week1"), withIntermediateDirectories: true)
        _ = try file(source, "lecture.pdf"); _ = try file(source.appendingPathComponent("week1"), "notes.md")
        let course = Course(name: "数学"); try repo.saveCourse(course)
        let first = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true)
        expectEqual(first.imported, 2); expectTrue(first.errors.isEmpty)
        expectEqual(try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true).skipped, 2)
        expectEqual(try repo.importFiles(urls: [source], courseID: nil, category: "笔记", copy: false).imported, 2)
        for material in repo.state.materials { expectTrue(FileManager.default.fileExists(atPath: try repo.resolveURL(material).path)) }
        expectEqual(Set(repo.state.materials.filter(\.isManaged).map(\.storedPath)).count, 2)
    }

    @Test func testImportRejectsSymbolicLinks() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let original = try file(folder, "original.pdf"), link = folder.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let result = try repo.importFiles(urls: [link], courseID: nil, category: "课件", copy: true)
        expectEqual(result.imported, 0); expectEqual(result.errors.count, 1)
        expectTrue(repo.state.materials.isEmpty)
    }

    @Test func testImportRollsBackFilesWhenIndexSaveFails() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let source = try file(folder, "new.pdf"), before = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        // The backup destination cannot atomically replace an existing directory.
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("library.json.bak"), withIntermediateDirectories: false)
        expectThrows(try repo.importFiles(urls: [source], courseID: nil, category: "课件", copy: true))
        expectTrue(repo.state.materials.isEmpty)
        expectTrue(try FileManager.default.contentsOfDirectory(at: repo.root.appendingPathComponent("files"), includingPropertiesForKeys: nil).isEmpty)
        expectEqual(try Data(contentsOf: repo.root.appendingPathComponent("library.json")), before)
    }

    @Test func testMutationFailureDoesNotChangeSnapshot() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("library.json.bak"), withIntermediateDirectories: false)
        expectThrows(try repo.saveCourse(Course(name: "失败的课程")))
        expectTrue(repo.state.courses.isEmpty)
    }

    @Test func testDeletingMetadataPreservesFilesAndCourseHistory() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let course = Course(name: "物理"); try repo.saveCourse(course)
        try requireImported(try repo.importFiles(urls: [try file(folder, "physics.pdf")], courseID: course.id, category: "教材", copy: true))
        let material = try unwrap(repo.state.materials.first)
        let task = StudyTask(title: "读第一章", courseID: course.id, materialIDs: [material.id]); try repo.saveTask(task)
        try repo.deleteCourse(id: course.id)
        expectNil(repo.state.materials.first?.courseID); expectNil(repo.state.tasks.first?.courseID)
        expectEqual(repo.state.tasks.first?.courseNameSnapshot, course.name)
        let managedFile = try repo.resolveURL(material)
        try repo.removeMaterials(ids: [material.id])
        expectTrue(FileManager.default.fileExists(atPath: managedFile.path))
        expectEqual(repo.state.tasks.first?.materialIDs, [])
    }

    @Test func testCompletionArchiveAndDeletionUndoAreIndependent() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let first = StudyTask(title: "完成实验"), second = StudyTask(title: "准备考试")
        try repo.saveTask(first); try repo.saveTask(second)
        try repo.setTaskCompleted(id: first.id, completed: true); try repo.archiveTask(id: first.id)
        expectTrue(try unwrap(repo.state.tasks.first).isCompleted); expectTrue(try unwrap(repo.state.tasks.first).isArchived)
        try repo.restoreTask(id: first.id)
        expectTrue(try unwrap(repo.state.tasks.first).isCompleted); expectFalse(try unwrap(repo.state.tasks.first).isArchived)
        try repo.deleteTasks(ids: [first.id]); try repo.deleteTasks(ids: [second.id])
        expectTrue(repo.canUndoTaskDeletion); expectTrue(repo.state.tasks.isEmpty)
        try repo.undoTaskDeletion(); expectEqual(repo.state.tasks.map(\.id), [second.id])
        try repo.undoTaskDeletion(); expectEqual(Set(repo.state.tasks.map(\.id)), [first.id, second.id])
        expectFalse(repo.canUndoTaskDeletion)
    }

    @Test func testUndoAfterCourseAndMaterialDeletionRepairsReferences() throws {
        let folder = try sandbox(), repo = try repository(folder), course = Course(name: "历史课程")
        try repo.saveCourse(course)
        try requireImported(try repo.importFiles(urls: [try file(folder, "old.txt")], courseID: course.id, category: "笔记", copy: true))
        let material = try unwrap(repo.state.materials.first), task = StudyTask(title: "历史任务", courseID: course.id, materialIDs: [material.id])
        try repo.saveTask(task); try repo.deleteTasks(ids: [task.id]); try repo.deleteCourse(id: course.id); try repo.removeMaterials(ids: [material.id]); try repo.undoTaskDeletion()
        expectNil(repo.state.tasks.first?.courseID); expectEqual(repo.state.tasks.first?.materialIDs, [])
        expectEqual(repo.state.tasks.first?.courseNameSnapshot, course.name)
    }

    @Test func testHomeworkUsesOrdinaryFoldersAndDoesNotOverwrite() throws {
        let folder = try sandbox(), repo = try repository(folder), course = Course(name: "编程")
        try repo.saveCourse(course)
        let source = try file(folder, "solution.py", content: "print(1)")
        expectEqual(try repo.importHomework(urls: [source], courseID: course.id, relativePath: "").imported, 1)
        expectEqual(try repo.importHomework(urls: [source], courseID: course.id, relativePath: "").imported, 1)
        let entries = try repo.listHomework(courseID: course.id, relativePath: "")
        expectEqual(Set(entries.map(\.name)), ["solution.py", "solution 2.py"])
        expectTrue(repo.state.materials.isEmpty)
        _ = try repo.createHomeworkFolder(name: "实验", courseID: course.id, relativePath: "")
        expectTrue(try unwrap(repo.listHomework(courseID: course.id, relativePath: "").first).isDirectory)
        expectThrows(try repo.listHomework(courseID: course.id, relativePath: "../.."))
    }

    @Test func testMountedHomeworkHasNoExtraMetadataAndCannotTraverseLinks() throws {
        let folder = try sandbox(), repo = try repository(folder), course = Course(name: "设计")
        try repo.saveCourse(course)
        let mounted = folder.appendingPathComponent("mounted"), outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        _ = try file(outside, "private.txt")
        try repo.mountHomework(courseID: course.id, url: mounted)
        let resolvedMount = try repo.homeworkURL(courseID: course.id)
        // `mounted` was constructed before the directory existed. Foundation
        // adds a directory hint (trailing slash) when recreating its persisted URL.
        expectEqual(resolvedMount.path, mounted.standardizedFileURL.path)
        expectTrue(resolvedMount.hasDirectoryPath)
        expectEqual(repo.state.courses.first?.homeworkFolder, mounted.standardizedFileURL.path)
        try FileManager.default.createSymbolicLink(at: mounted.appendingPathComponent("link"), withDestinationURL: outside)
        expectTrue(try repo.listHomework(courseID: course.id, relativePath: "").isEmpty)
        expectThrows(try repo.listHomework(courseID: course.id, relativePath: "link"))
        expectEqual(try FileManager.default.contentsOfDirectory(at: mounted, includingPropertiesForKeys: nil).count, 1)
    }

    @Test func testBackupIncludesOrphansAndRestoresIntoAnotherLibrary() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "orphan.pdf"), try file(folder, "active.pdf")], courseID: nil, category: "课件", copy: true), expected: 2)
        let orphan = try unwrap(repo.state.materials.first), orphanRelative = orphan.storedPath
        try repo.removeMaterials(ids: [orphan.id])
        try requireImported(try repo.importHomework(urls: [try file(folder, "homework.txt")], courseID: nil, relativePath: ""))
        let removedCourse = Course(name: "已删除的课程")
        try repo.saveCourse(removedCourse)
        try requireImported(try repo.importHomework(urls: [try file(folder, "old-homework.txt")], courseID: removedCourse.id, relativePath: ""))
        let retainedHomeworkPath = String(try repo.homeworkURL(courseID: removedCourse.id).path.dropFirst(repo.root.path.count + 1)) + "/old-homework.txt"
        try repo.deleteCourse(id: removedCourse.id)
        let backup = folder.appendingPathComponent("Snapshot.teachshelfbackup")
        try repo.backup(to: backup)
        expectTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(orphanRelative).path))
        expectTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(retainedHomeworkPath).path))
        let target = try LibraryRepository(root: folder.appendingPathComponent("OtherLibrary"))
        try target.restore(from: backup)
        expectEqual(target.state.materials, repo.state.materials)
        expectTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent(orphanRelative).path))
        expectEqual(try target.listHomework(courseID: nil, relativePath: "").map(\.name), ["homework.txt"])
        expectTrue(try target.resolveURL(unwrap(target.state.materials.first)).path.hasPrefix(target.root.path))
    }

    @Test func testRestorePreservesPreviousFilesAndRejectsIncompleteBackup() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "before.txt")], courseID: nil, category: "笔记", copy: true))
        let original = try unwrap(repo.state.materials.first), backup = folder.appendingPathComponent("Snapshot.teachshelfbackup")
        try repo.backup(to: backup)
        try requireImported(try repo.importFiles(urls: [try file(folder, "after.txt")], courseID: nil, category: "笔记", copy: true))
        let later = try unwrap(repo.state.materials.last)
        try repo.restore(from: backup)
        expectEqual(repo.state.materials.map(\.id), [original.id])
        let history = try FileManager.default.contentsOfDirectory(at: repo.root.appendingPathComponent("History"), includingPropertiesForKeys: nil)
        expectTrue(history.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(later.storedPath).path) })
        try FileManager.default.removeItem(at: backup.appendingPathComponent(original.storedPath))
        let before = repo.state
        expectThrows(try repo.restore(from: backup)); expectEqual(repo.state, before)
        expectNoThrow(try repo.resolveURL(original))
    }

    @Test func testLibraryMigrationPreservesSourceAndRelocatesManagedPaths() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "textbook.pdf")], courseID: nil, category: "教材", copy: true))
        let copied = folder.appendingPathComponent("MovedLibrary")
        try repo.copyLibrary(to: copied)
        expectFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent(".teachshelf.lock").path))
        let moved = try LibraryRepository(root: copied)
        expectEqual(moved.state, repo.state)
        expectNoThrow(try repo.resolveURL(unwrap(repo.state.materials.first)))
        expectTrue(try moved.resolveURL(unwrap(moved.state.materials.first)).path.hasPrefix(copied.path))
        expectThrows(try repo.copyLibrary(to: repo.root.appendingPathComponent("nested")))
    }

    @Test func testMigrationAcceptsEmptyDirectoryButPreservesNonemptyDestination() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try repo.saveCourse(Course(name: "迁移课程"))
        let destination = folder.appendingPathComponent("chosen-empty-folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try repo.copyLibrary(to: destination)
        let copied = try LibraryRepository(root: destination)
        expectEqual(copied.state, repo.state)
        let occupied = folder.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let keep = try file(occupied, "keep.txt", content: "must remain")
        expectThrows(try repo.copyLibrary(to: occupied))
        expectEqual(String(data: try Data(contentsOf: keep), encoding: .utf8), "must remain")
        expectFalse(FileManager.default.fileExists(atPath: occupied.appendingPathComponent("library.json").path))
    }

    @Test func testFailedRestoreRollsBackFilesAndState() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "before.txt")], courseID: nil, category: "笔记", copy: true))
        let backup = folder.appendingPathComponent("Snapshot.teachshelfbackup")
        try repo.backup(to: backup)
        try requireImported(try repo.importFiles(urls: [try file(folder, "later.txt")], courseID: nil, category: "笔记", copy: true))
        let before = repo.state, indexBefore = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("library.json.bak"))
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("library.json.bak"), withIntermediateDirectories: false)
        expectThrows(try repo.restore(from: backup))
        expectEqual(repo.state, before)
        expectEqual(try Data(contentsOf: repo.root.appendingPathComponent("library.json")), indexBefore)
        for material in before.materials { expectNoThrow(try repo.resolveURL(material)) }
        expectFalse(try FileManager.default.contentsOfDirectory(at: repo.root, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".restore-") })
    }

    @Test func testArchivedTasksAreReadOnlyUntilRestored() throws {
        let folder = try sandbox(), repo = try repository(folder), task = StudyTask(title: "已归档任务")
        try repo.saveTask(task); try repo.archiveTask(id: task.id)
        let archived = try unwrap(repo.state.tasks.first)
        expectThrows(try repo.setTaskCompleted(id: task.id, completed: false))
        var edited = archived; edited.title = "不可直接编辑"; edited.archivedAt = nil
        expectThrows(try repo.saveTask(edited))
        expectEqual(try unwrap(repo.state.tasks.first), archived)
        try repo.restoreTask(id: task.id); try repo.saveTask(edited)
        expectEqual(try unwrap(repo.state.tasks.first).title, edited.title)
    }

    @Test func testArchiveCompletesPendingTaskAndPreservesExistingCompletion() throws {
        let folder = try sandbox(), repo = try repository(folder), task = StudyTask(title: "直接归档")
        try repo.saveTask(task); try repo.archiveTask(id: task.id)
        expectEqual(try unwrap(repo.state.tasks.first).completedAt, try unwrap(repo.state.tasks.first).archivedAt)
        let start = Date().addingTimeInterval(-200), completion = Date().addingTimeInterval(-100)
        let completedTask = StudyTask(title: "保留完成时间", startsAt: start, completedAt: completion)
        try repo.saveTask(completedTask); try repo.archiveTask(id: completedTask.id)
        let archived = try unwrap(repo.state.tasks.first { $0.id == completedTask.id })
        expectEqual(archived.completedAt, completion)
        expectTrue(try unwrap(archived.archivedAt) >= completion)
    }

    @Test func testFutureStartAndFutureCompletionCannotBeArchived() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let future = StudyTask(title: "未来开始", startsAt: Date().addingTimeInterval(3_600))
        try repo.saveTask(future)
        expectThrows(try repo.archiveTask(id: future.id))
        expectNoThrow(try repo.setTaskCompleted(id: future.id, completed: true))
        expectTrue(try unwrap(repo.state.tasks.first).isCompleted); expectFalse(try unwrap(repo.state.tasks.first).isArchived)
        expectTrue(try unwrap(repo.state.tasks.first?.completedAt) < future.startsAt)
        let futureCompletion = StudyTask(title: "未来完成", startsAt: Date().addingTimeInterval(-100), completedAt: Date().addingTimeInterval(3_600))
        try repo.saveTask(futureCompletion)
        expectThrows(try repo.archiveTask(id: futureCompletion.id))
        expectFalse(try unwrap(repo.state.tasks.first { $0.id == futureCompletion.id }).isArchived)
    }

    @Test func testArchivedCourseNameSnapshotSurvivesRenameAndDeletion() throws {
        let folder = try sandbox(), repo = try repository(folder)
        var course = Course(name: "原课程名"); try repo.saveCourse(course)
        let archived = StudyTask(title: "历史记录", courseID: course.id), active = StudyTask(title: "进行中的记录", courseID: course.id)
        try repo.saveTask(archived); try repo.saveTask(active); try repo.archiveTask(id: archived.id)
        course.name = "新课程名"; try repo.saveCourse(course)
        expectEqual(repo.state.tasks.first { $0.id == archived.id }?.courseNameSnapshot, "原课程名")
        expectEqual(repo.state.tasks.first { $0.id == active.id }?.courseNameSnapshot, "新课程名")
        try repo.deleteCourse(id: course.id)
        expectEqual(repo.state.tasks.first { $0.id == archived.id }?.courseNameSnapshot, "原课程名")
        expectNil(repo.state.tasks.first { $0.id == archived.id }?.courseID)
    }

    @Test func testTaskChronologyAndLoadedTitlesAppearanceAreValidated() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let start = Date()
        let earlyCompletion = StudyTask(title: "提前完成", startsAt: start, completedAt: start.addingTimeInterval(-1))
        expectNoThrow(try repo.saveTask(earlyCompletion))
        expectEqual(repo.state.tasks.first?.completedAt, earlyCompletion.completedAt)
        expectThrows(try repo.saveTask(StudyTask(title: "归档但未完成", startsAt: start, archivedAt: start.addingTimeInterval(1))))
        expectThrows(try repo.saveTask(StudyTask(title: "完成晚于归档", startsAt: start, completedAt: start.addingTimeInterval(2), archivedAt: start.addingTimeInterval(1))))
        expectEqual(repo.state.tasks.count, 1)
        let invalidRoot = folder.appendingPathComponent("InvalidLibrary")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: false)
        var state = LibraryState(); state.courses = [Course(name: " ")]
        let index = invalidRoot.appendingPathComponent("library.json")
        try JSONEncoder().encode(state).write(to: index)
        expectThrows(try LibraryRepository(root: invalidRoot))
        state = LibraryState(); state.appearance = "invalid"
        try JSONEncoder().encode(state).write(to: index)
        expectThrows(try LibraryRepository(root: invalidRoot))
    }

    @Test func testExternalReferenceRelinkPreservesIdentityAndAnnotations() throws {
        let folder = try sandbox(), repo = try repository(folder)
        let source = try file(folder, "old.txt"), replacement = try file(folder, "new.pdf", content: "replacement content")
        try requireImported(try repo.importFiles(urls: [source], courseID: nil, category: "笔记", copy: false))
        var material = try unwrap(repo.state.materials.first)
        material.title = "保留的标题"; material.tags = "复习"; material.notes = "保留备注"; material.isFavorite = true
        try repo.updateMaterial(material); try repo.recordOpen(id: material.id)
        material = try unwrap(repo.state.materials.first)
        try FileManager.default.removeItem(at: source)
        try repo.relinkMaterial(id: material.id, to: replacement)
        let relinked = try unwrap(repo.state.materials.first)
        expectEqual(relinked.id, material.id); expectEqual(relinked.title, material.title)
        expectEqual(relinked.tags, material.tags); expectEqual(relinked.notes, material.notes)
        expectEqual(relinked.addedAt, material.addedAt); expectEqual(relinked.lastOpenedAt, material.lastOpenedAt)
        expectEqual(relinked.isFavorite, material.isFavorite); expectEqual(relinked.category, material.category)
        expectEqual(relinked.sourcePath, replacement.standardizedFileURL.path); expectEqual(relinked.storedPath, replacement.standardizedFileURL.path)
        expectEqual(relinked.originalName, "new.pdf"); expectEqual(relinked.size, Int64("replacement content".utf8.count))
        expectEqual(try repo.resolveURL(relinked).path, replacement.standardizedFileURL.path)
    }

    @Test func testRelinkRejectsManagedMissingAndSymbolicLinkTargetsWithoutChanges() throws {
        let folder = try sandbox(), repo = try repository(folder), source = try file(folder, "source.txt")
        try requireImported(try repo.importFiles(urls: [source], courseID: nil, category: "课件", copy: true))
        let managed = try unwrap(repo.state.materials.first)
        expectThrows(try repo.relinkMaterial(id: managed.id, to: source))
        try requireImported(try repo.importFiles(urls: [try file(folder, "external.txt")], courseID: nil, category: "课件", copy: false))
        let external = try unwrap(repo.state.materials.last), before = repo.state
        expectThrows(try repo.relinkMaterial(id: external.id, to: folder.appendingPathComponent("missing.txt")))
        let link = folder.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        expectThrows(try repo.relinkMaterial(id: external.id, to: link))
        expectThrows(try repo.relinkMaterial(id: external.id, to: folder))
        expectEqual(repo.state, before)
        expectNoThrow(try repo.resolveURL(managed))
    }

    @Test func testRelinkMetadataSaveFailureRollsBack() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "external.txt")], courseID: nil, category: "课件", copy: false))
        let external = try unwrap(repo.state.materials.first), before = repo.state
        let newFile = try file(folder, "replacement.txt"), indexBefore = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("library.json.bak"))
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("library.json.bak"), withIntermediateDirectories: false)
        expectThrows(try repo.relinkMaterial(id: external.id, to: newFile))
        expectEqual(repo.state, before)
        expectEqual(try Data(contentsOf: repo.root.appendingPathComponent("library.json")), indexBefore)
        expectTrue(FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test func testWorkspaceMountsRejectLibraryAndOtherCourseOverlap() throws {
        let folder = try sandbox(), repo = try repository(folder), first = Course(name: "第一门课"), second = Course(name: "第二门课")
        try repo.saveCourse(first); try repo.saveCourse(second)
        let mounted = folder.appendingPathComponent("work"), child = mounted.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        expectThrows(try repo.mountHomework(courseID: first.id, url: repo.root))
        expectThrows(try repo.mountHomework(courseID: first.id, url: try repo.homeworkURL(courseID: first.id)))
        expectThrows(try repo.mountHomework(courseID: first.id, url: folder))
        try repo.mountHomework(courseID: first.id, url: mounted)
        expectThrows(try repo.mountHomework(courseID: second.id, url: mounted))
        expectThrows(try repo.mountHomework(courseID: second.id, url: child))
        expectThrows(try repo.mountHomework(courseID: second.id, url: folder))
        expectNil(repo.state.courses.first { $0.id == second.id }?.homeworkFolder)
        var bypass = second; bypass.homeworkFolder = child.path
        expectThrows(try repo.saveCourse(bypass))
    }

    @Test func testDisconnectedMountsRemainLoadableAndCourseMetadataEditable() throws {
        let folder = try sandbox(), root = folder.appendingPathComponent("DisconnectedLibrary"), mounted = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: false)
        let course = Course(name: "离线课程")
        do {
            let repo = try LibraryRepository(root: root)
            try repo.saveCourse(course); try repo.mountHomework(courseID: course.id, url: mounted)
        }
        try FileManager.default.removeItem(at: mounted)
        let reopened = try LibraryRepository(root: root)
        var edited = try unwrap(reopened.state.courses.first); edited.teacher = "更新教师"
        try reopened.saveCourse(edited)
        expectEqual(reopened.state.courses.first?.teacher, "更新教师")
        expectEqual(reopened.state.courses.first?.homeworkFolder, mounted.standardizedFileURL.path)
        expectThrows(try reopened.homeworkURL(courseID: course.id))
    }

    @Test func testCategoriesShareCanonicalCatalogAcrossImportUpdateAndDeletion() throws {
        let folder = try sandbox(), repo = try repository(folder)
        try requireImported(try repo.importFiles(urls: [try file(folder, "one.txt")], courseID: nil, category: "  Research  ", copy: false))
        try requireImported(try repo.importFiles(urls: [try file(folder, "two.txt")], courseID: nil, category: "research", copy: true))
        expectEqual(repo.state.customCategories, ["Research"])
        expectEqual(Set(repo.state.materials.map(\.category)), ["Research"])
        var edited = try unwrap(repo.state.materials.first); edited.category = "  实验记录  "
        try repo.updateMaterial(edited)
        expectEqual(repo.state.materials.first?.category, "实验记录")
        expectEqual(repo.state.customCategories, ["Research", "实验记录"])
        try repo.removeMaterials(ids: Set(repo.state.materials.map(\.id)))
        expectEqual(repo.state.customCategories, ["Research", "实验记录"])
    }

    @Test func testEmptyReservedAndControlCharacterCategoriesAreRejected() throws {
        let folder = try sandbox(), repo = try repository(folder), source = try file(folder, "source.txt")
        for category in ["", "  ", "作业", "全部类别", "全部用途", "a\nb", String(repeating: "a", count: 41)] {
            expectThrows(try repo.importFiles(urls: [source], courseID: nil, category: category, copy: false))
        }
        expectTrue(repo.state.materials.isEmpty); expectTrue(repo.state.customCategories.isEmpty)
        try requireImported(try repo.importFiles(urls: [source], courseID: nil, category: "课件", copy: false))
        var edited = try unwrap(repo.state.materials.first); edited.category = "全部类别"
        let before = repo.state
        expectThrows(try repo.updateMaterial(edited)); expectEqual(repo.state, before)
    }
}

// These helpers evaluate throwing repository expressions once and preserve the
// call site's test failure, while keeping filesystem setup readable.
private func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) {
    do { #expect(try lhs() == rhs()) } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectTrue(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try value()) } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectFalse(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try !value()) } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectNil<T>(_ value: @autoclosure () throws -> T?) {
    do { #expect(try value() == nil) } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectNotNil<T>(_ value: @autoclosure () throws -> T?) {
    do { #expect(try value() != nil) } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T, check: (Error) -> Void = { _ in }) {
    do { _ = try value(); Issue.record("Expected an error") } catch { check(error) }
}
private func expectNoThrow<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value() } catch { Issue.record("Unexpected error: \(error)") }
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { Issue.record("Expected a non-nil value"); throw LibraryError.invalidInput("Missing test value") }
    return value
}
private func fail(_ message: String) { Issue.record(Comment(rawValue: message)) }

private func requireImported(_ summary: ImportSummary, expected: Int = 1) throws {
    guard summary.imported == expected, summary.errors.isEmpty else {
        Issue.record("Import fixture failed: imported \(summary.imported), errors \(summary.errors)")
        throw LibraryError.invalidInput("Import fixture failed")
    }
}
