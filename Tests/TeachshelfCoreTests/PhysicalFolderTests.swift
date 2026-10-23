import Foundation
import Darwin
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct PhysicalFolderTests {
    private let fm = FileManager.default

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-physical-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try action(root)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return value.st_ino
    }

    @Test(arguments: [6, 7]) func legacyGroupsMigrateIncludingEmptyFoldersAndPreserveContents(version: Int) throws {
        try fixture { root in
            let course = Course(name: "课程")
            let parent = MaterialFolder(courseID: course.id, name: "教学网站")
            let child = MaterialFolder(courseID: course.id, parentID: parent.id, name: "第一章")
            let empty = MaterialFolder(courseID: course.id, parentID: child.id, name: "空文件夹")
            var state = LibraryState(); state.schemaVersion = version
            state.courses = [course]; state.materialFolders = [parent, child, empty]
            let original = "files/\(course.name) [\(course.id)]/lecture.pdf"
            var record = MaterialRecord(courseID: course.id, title: "课件", originalName: "lecture.pdf",
                                        sourcePath: "/original.pdf", storedPath: original, isManaged: true,
                                        tags: "标签", notes: "备注")
            record.folderID = child.id; state.materials = [record]
            let external = root.appendingPathComponent("external.txt")
            try write("external", to: external)
            var reference = MaterialRecord(courseID: course.id, title: "引用", originalName: "external.txt",
                                           sourcePath: external.path, storedPath: external.path, isManaged: false)
            reference.folderID = empty.id; state.materials.append(reference)
            let library = root.appendingPathComponent("Library")
            try write("content", to: library.appendingPathComponent(original))
            let oldInode = try inode(library.appendingPathComponent(original))
            let index = library.appendingPathComponent("library.json")
            let bytes = try LibraryRepository.encoder.encode(state); try bytes.write(to: index)
            var repo: LibraryRepository? = try LibraryRepository(root: library)
            let result = try #require(repo?.state.materials.first)
            let file = try repo!.resolveURL(record)
            #expect(file.path.contains("/资料/教学网站/第一章/"))
            #expect(try inode(file) == oldInode, "同卷迁移应移动目录项而不是复制内容")
            #expect(try Data(contentsOf: file) == Data("content".utf8))
            #expect(result.id == record.id && result.tags == record.tags && result.notes == record.notes)
            #expect(repo?.state.materials.last == reference)
            #expect(repo?.state.schemaVersion == 8 && repo?.state.materialFolders == state.materialFolders)
            let emptyURL = try #require(repo!.materialFolderRevealURLs(id: empty.id).first)
            #expect(try fm.contentsOfDirectory(atPath: emptyURL.path).isEmpty)
            #expect(try Data(contentsOf: library.appendingPathComponent("library.json.bak")) == bytes)
            let migratedBytes = try Data(contentsOf: index)
            repo = nil
            let reopened = try LibraryRepository(root: library)
            #expect(reopened.state.materials.first == result)
            #expect(try Data(contentsOf: index) == migratedBytes)
            #expect(!fm.fileExists(atPath: reopened.physicalStorageJournalURL.path))
        }
    }

    @Test func renameMovesNestedAndUnindexedContentsWithoutCopyingOrTouchingHomework() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            var course = Course(name: "原课程"); try repo.saveCourse(course)
            let parent = try repo.createMaterialFolder(name: "Lectures", courseID: course.id)
            let child = try repo.createMaterialFolder(name: "Chapter", courseID: course.id, parentID: parent.id)
            let source = root.appendingPathComponent("lecture.txt"); try write("data", to: source)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true, folderID: child.id)
            let record = repo.state.materials[0], oldURL = try repo.resolveURL(repo.state.materials[0])
            let originalInode = try inode(oldURL)
            let originalDirectory = try #require(repo.materialFolderRevealURLs(id: parent.id).first)
            let directoryInode = try inode(originalDirectory)
            try write("extra", to: originalDirectory.appendingPathComponent("unindexed.txt"))
            let homework = try repo.homeworkURL(courseID: course.id)
            try write("homework", to: homework.appendingPathComponent("answer.txt"))
            try repo.renameMaterialFolder(id: parent.id, name: "lectures")
            let renamedDirectory = try #require(repo.materialFolderRevealURLs(id: parent.id).first)
            #expect(try inode(renamedDirectory) == directoryInode)
            #expect(try fm.contentsOfDirectory(atPath: renamedDirectory.deletingLastPathComponent().path).contains("lectures"))
            try repo.renameMaterialFolder(id: parent.id, name: "复习")
            course.name = "新课程"; try repo.saveCourse(course)
            let newURL = try repo.resolveURL(record)
            #expect(newURL.path.contains("/资料/复习/Chapter/"))
            #expect(try inode(newURL) == originalInode)
            #expect(try String(contentsOf: newURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("unindexed.txt"), encoding: .utf8) == "extra")
            #expect(try String(contentsOf: repo.homeworkURL(courseID: course.id).appendingPathComponent("answer.txt"), encoding: .utf8) == "homework")
            #expect(!fm.fileExists(atPath: oldURL.path))
        }
    }

    @Test func movingAndDissolvingDirectoriesPreserveFilesAndRemoveEmptyAncestors() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "课程"); try repo.saveCourse(course)
            let folder = try repo.createMaterialFolder(name: "作业", courseID: course.id)
            let nested = try repo.createMaterialFolder(name: "子目录", courseID: course.id, parentID: folder.id)
            let source = root.appendingPathComponent("a.txt"); try write("a", to: source)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true, folderID: nested.id)
            let record = repo.state.materials[0]
            let directory = try #require(repo.materialFolderRevealURLs(id: folder.id).first)
            let homework = try repo.homeworkURL(courseID: course.id)
            #expect(directory != homework)
            try repo.moveMaterials(ids: [record.id], to: folder.id, courseID: course.id)
            #expect(try repo.resolveURL(record).deletingLastPathComponent() == directory)
            #expect(fm.fileExists(atPath: directory.appendingPathComponent("子目录").path), "空文件夹仍应保留")
            try repo.dissolveMaterialFolder(id: folder.id)
            #expect(!fm.fileExists(atPath: directory.path))
            #expect(try repo.resolveURL(record).deletingLastPathComponent().lastPathComponent == "资料")
            #expect(try Data(contentsOf: repo.resolveURL(record)) == Data("a".utf8))
            #expect(fm.fileExists(atPath: homework.path))
        }
    }

    @Test func failedRenameAndEmptyFolderCreationRestorePhysicalAndIndexedState() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "课程"); try repo.saveCourse(course)
            let folder = try repo.createMaterialFolder(name: "Original", courseID: course.id)
            let original = try #require(repo.materialFolderRevealURLs(id: folder.id).first)
            try write("keep", to: original.appendingPathComponent("extra.txt"))
            let before = repo.state
            let backup = repo.root.appendingPathComponent("library.json.bak")
            try fm.removeItem(at: backup); try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            for name in ["Different", "original"] {
                #expect(throws: (any Error).self) { try repo.renameMaterialFolder(id: folder.id, name: name) }
                #expect(repo.state == before)
                #expect(try fm.contentsOfDirectory(atPath: original.deletingLastPathComponent().path) == ["Original"])
                #expect(try String(contentsOf: original.appendingPathComponent("extra.txt"), encoding: .utf8) == "keep")
            }
            #expect(throws: (any Error).self) { try repo.createMaterialFolder(name: "Failed", courseID: course.id) }
            #expect(!fm.fileExists(atPath: original.deletingLastPathComponent().appendingPathComponent("Failed").path))
            #expect(!fm.fileExists(atPath: repo.physicalStorageJournalURL.path))
        }
    }

    @Test func diskCollisionsAndSymlinksNeverOverwriteOtherContents() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "课程"); try repo.saveCourse(course)
            let folder = try repo.createMaterialFolder(name: "Original", courseID: course.id)
            let original = try #require(repo.materialFolderRevealURLs(id: folder.id).first)
            let occupied = original.deletingLastPathComponent().appendingPathComponent("Occupied")
            try write("keep", to: occupied.appendingPathComponent("extra.txt"))
            #expect(throws: (any Error).self) { try repo.renameMaterialFolder(id: folder.id, name: "Occupied") }
            let symlink = original.deletingLastPathComponent().appendingPathComponent("Link")
            try fm.createSymbolicLink(at: symlink, withDestinationURL: root)
            #expect(throws: (any Error).self) { try repo.renameMaterialFolder(id: folder.id, name: "Link") }
            #expect(try repo.materialFolderRevealURLs(id: folder.id) == [original])
            #expect(try String(contentsOf: occupied.appendingPathComponent("extra.txt"), encoding: .utf8) == "keep")
        }
    }

    @Test(arguments: [false, true]) func interruptedDirectoryMovesRecoverAccordingToIndex(committed: Bool) throws {
        try fixture { root in
            var repo: LibraryRepository? = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "课程"); try repo!.saveCourse(course)
            let folder = try repo!.createMaterialFolder(name: "Before", courseID: course.id)
            let beforeURL = try #require(repo!.materialFolderRevealURLs(id: folder.id).first)
            try write("keep", to: beforeURL.appendingPathComponent("unindexed.txt"))
            var next = repo!.state; next.materialFolders[0].name = "After"
            let journal = repo!.physicalStorageJournalURL
            do {
                let tx = LibraryRepository.PhysicalStorageTransaction(repository: repo!, next: next)
                try repo!.preparePhysicalStorage(from: repo!.state, candidates: next, to: next, repairDirectories: false, transaction: tx)
                if committed { try LibraryRepository.encoder.encode(next).write(to: repo!.indexURL, options: .atomic) }
                // Simulate termination during the next append, before it could run.
                let handle = try FileHandle(forWritingTo: journal)
                try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"kind\":\"move\"".utf8)); try handle.close()
            }
            repo = nil
            let reopened = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let directory = try #require(reopened.materialFolderRevealURLs(id: folder.id).first)
            #expect(directory.lastPathComponent == (committed ? "After" : "Before"))
            #expect(try String(contentsOf: directory.appendingPathComponent("unindexed.txt"), encoding: .utf8) == "keep")
            #expect(try fm.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path) == [directory.lastPathComponent])
            #expect(!fm.fileExists(atPath: journal.path))
        }
    }

    @Test func aSecondInterruptionDuringRollbackResumesAfterAlreadyRestoredChildren() throws {
        try fixture { root in
            let library = root.appendingPathComponent("Library")
            var repo: LibraryRepository? = try LibraryRepository(root: library)
            let course = Course(name: "Before"); try repo!.saveCourse(course)
            let folder = try repo!.createMaterialFolder(name: "Child", courseID: course.id)
            let before = repo!.state
            let oldFolder = try #require(repo!.materialFolderRevealURLs(id: folder.id).first)
            try write("keep", to: oldFolder.appendingPathComponent("extra.txt"))
            var next = before
            next.courses[0].name = "After"; next.materialFolders[0].name = "Renamed"
            do {
                let tx = LibraryRepository.PhysicalStorageTransaction(repository: repo!, next: next)
                try repo!.preparePhysicalStorage(from: before, candidates: next, to: next, repairDirectories: false, transaction: tx)
                let newCourse = library.appendingPathComponent(MaterialStorageLayout.courseDirectory(for: next.courses[0]))
                // Undo the child, flush its progress, then undo the ancestor and
                // terminate before its progress record could be flushed.
                try fm.moveItem(at: newCourse.appendingPathComponent("资料/Renamed"), to: newCourse.appendingPathComponent("资料/Child"))
                try repo!.appendStorageJournalEntry(.init(kind: .undo, completed: 1))
                try fm.moveItem(at: newCourse, to: library.appendingPathComponent(MaterialStorageLayout.courseDirectory(for: course)))
            }
            repo = nil
            let reopened = try LibraryRepository(root: library)
            #expect(reopened.state == before)
            #expect(try String(contentsOf: oldFolder.appendingPathComponent("extra.txt"), encoding: .utf8) == "keep")
            #expect(!fm.fileExists(atPath: reopened.physicalStorageJournalURL.path))
        }
    }

    @Test func nestedPhysicalFoldersSurviveBackupRestoreIncludingEmptyOnes() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "课程"); try repo.saveCourse(course)
            let folder = try repo.createMaterialFolder(name: "父", courseID: course.id)
            let empty = try repo.createMaterialFolder(name: "空", courseID: course.id, parentID: folder.id)
            let source = root.appendingPathComponent("a.txt"); try write("a", to: source)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true, folderID: folder.id)
            let backup = root.appendingPathComponent("Backup.teachshelfbackup"); try repo.backup(to: backup)
            try repo.renameMaterialFolder(id: folder.id, name: "修改")
            try repo.restore(from: backup)
            let directory = try #require(repo.materialFolderRevealURLs(id: empty.id).first)
            #expect(directory.path.hasSuffix("/资料/父/空"))
            #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(try String(contentsOf: repo.resolveURL(repo.state.materials[0]), encoding: .utf8) == "a")
            #expect(!fm.fileExists(atPath: directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("修改").path))
        }
    }
}
