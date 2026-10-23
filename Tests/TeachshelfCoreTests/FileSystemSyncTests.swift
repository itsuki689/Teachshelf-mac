import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct FileSystemSyncTests {
    private let fm = FileManager.default

    private func fixture(_ action: (URL, LibraryRepository, Course, Course) throws -> Void) throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-sync-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let first = Course(name: "课程一"), second = Course(name: "课程二")
        try repo.saveCourse(first); try repo.saveCourse(second)
        try action(root, repo, first, second)
    }

    private func material(_ repo: LibraryRepository, root: URL, course: Course, folder: UUID? = nil) throws -> MaterialRecord {
        let source = root.appendingPathComponent("lecture.txt")
        try Data("original content".utf8).write(to: source)
        _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true, folderID: folder)
        var record = repo.state.materials.last!
        record.tags = "复习"; record.notes = "保留笔记"; record.isFavorite = true
        try repo.updateMaterial(record)
        return repo.state.materials.last!
    }

    private func materialRoot(_ repo: LibraryRepository, _ course: Course) -> URL {
        repo.root.appendingPathComponent(MaterialStorageLayout.materialRoot(for: course))
    }

    @Test func renameAndCrossCourseMoveRetainIdentityAndAnnotations() throws {
        try fixture { root, repo, first, second in
            let record = try material(repo, root: root, course: first)
            let task = StudyTask(title: "复习", courseID: first.id, materialIDs: [record.id])
            try repo.saveTask(task)
            let destination = materialRoot(repo, second).appendingPathComponent("第二章.txt")
            try fm.moveItem(at: repo.resolveURL(record), to: destination)
            #expect(try repo.synchronizeFileSystem())
            let updated = repo.state.materials[0]
            #expect(updated.id == record.id && updated.courseID == second.id && updated.folderID == nil)
            #expect(updated.title == "第二章" && updated.originalName == "第二章.txt")
            #expect(updated.notes == record.notes && updated.tags == record.tags && updated.isFavorite)
            #expect(repo.state.tasks[0].materialIDs == [record.id])
            #expect(try repo.resolveURL(record) == destination)
            try repo.setFavorite(id: record.id, favorite: false)
            #expect(try repo.resolveURL(record) == destination)
            #expect(try !repo.synchronizeFileSystem())
        }
    }

    @Test func nestedFolderMoveAcrossCoursesKeepsEmptyDescendantsAndCustomTitles() throws {
        try fixture { root, repo, first, second in
            let folder = try repo.createMaterialFolder(name: "章节", courseID: first.id)
            let child = try repo.createMaterialFolder(name: "空目录", courseID: first.id, parentID: folder.id)
            var record = try material(repo, root: root, course: first, folder: folder.id)
            record.title = "自定义标题"; try repo.updateMaterial(record)
            let source = try #require(repo.materialFolderRevealURLs(id: folder.id).first)
            let parent = materialRoot(repo, second).appendingPathComponent("Finder 新建/二级")
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let destination = parent.appendingPathComponent("重命名章节")
            try fm.moveItem(at: source, to: destination)
            try repo.synchronizeFileSystem()
            let updated = try #require(repo.state.materialFolders.first { $0.id == folder.id })
            #expect(updated.courseID == second.id && updated.name == "重命名章节" && updated.parentID != nil)
            #expect(repo.state.materialFolders.first { $0.id == child.id }?.courseID == second.id)
            #expect(repo.state.materials[0].title == "自定义标题" && repo.state.materials[0].folderID == folder.id)
            #expect(repo.state.materials[0].courseID == second.id)
            #expect(try repo.materialFolderRevealURLs(id: folder.id).map(\.path) == [destination.path])
            try repo.renameMaterialFolder(id: folder.id, name: "应用中改名")
            #expect(try repo.resolveURL(record).path.contains("/Finder 新建/二级/应用中改名/"))
        }
    }

    @Test func courseAndMaterialRootRenameArePreservedBySubsequentSaves() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let old = repo.root.appendingPathComponent(MaterialStorageLayout.courseDirectory(for: first))
            let renamed = old.deletingLastPathComponent().appendingPathComponent("Finder 课程")
            try fm.moveItem(at: old, to: renamed)
            try fm.moveItem(at: renamed.appendingPathComponent("资料"), to: renamed.appendingPathComponent("我的资料"))
            try repo.synchronizeFileSystem()
            #expect(repo.state.courses[0].name == "Finder 课程")
            #expect(try repo.resolveURL(record).path.contains("/Finder 课程/我的资料/"))
            var course = repo.state.courses[0]; course.teacher = "教师"; try repo.saveCourse(course)
            #expect(try repo.resolveURL(record).path.contains("/Finder 课程/我的资料/"))
            course.name = "应用改名"; try repo.saveCourse(course)
            #expect(try repo.resolveURL(record).path.contains("/应用改名 [\(course.id)]/我的资料/"))
        }
    }

    @Test func movedOutsideRecordsRemainMissingUntilReturnOrRelink() throws {
        try fixture { root, repo, first, _ in
            let folder = try repo.createMaterialFolder(name: "整组", courseID: first.id)
            let record = try material(repo, root: root, course: first, folder: folder.id)
            let original = try #require(repo.materialFolderRevealURLs(id: folder.id).first)
            let outside = root.appendingPathComponent("外部整组")
            try fm.moveItem(at: original, to: outside)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == true && repo.state.materialFolders[0].isMissing == true)
            #expect(throws: (any Error).self) { try repo.resolveURL(record) }
            try repo.setFavorite(id: record.id, favorite: false)
            #expect(!fm.fileExists(atPath: original.path))
            try fm.moveItem(at: outside, to: original)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == nil && repo.state.materialFolders[0].isMissing == nil)
            let outsideFile = root.appendingPathComponent("重新定位.txt")
            try fm.moveItem(at: repo.resolveURL(record), to: outsideFile)
            try repo.relinkMaterial(id: record.id, to: outsideFile)
            #expect(repo.state.materials[0].isMissing == nil && repo.state.materials[0].id == record.id)
            #expect(repo.state.materials[0].notes == record.notes)
            #expect(fm.fileExists(atPath: outsideFile.path), "重新定位不会移走外部原件")
            #expect(try Data(contentsOf: repo.resolveURL(record)) == Data("original content".utf8))
        }
    }

    @Test func offlineRenameAndMissingFolderAreReconciledBeforeStartupRepair() throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-offline-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        var repo: LibraryRepository? = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let course = Course(name: "课程"); try repo!.saveCourse(course)
        let folder = try repo!.createMaterialFolder(name: "目录", courseID: course.id)
        let record = try material(repo!, root: root, course: course, folder: folder.id)
        let original = try #require(repo!.materialFolderRevealURLs(id: folder.id).first)
        repo = nil
        let renamed = original.deletingLastPathComponent().appendingPathComponent("离线改名")
        try fm.moveItem(at: original, to: renamed)
        repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        #expect(repo!.state.materialFolders[0].name == "离线改名")
        #expect(try repo!.resolveURL(record).path.hasPrefix(renamed.path))
        #expect(!fm.fileExists(atPath: original.path))
        repo = nil
        try fm.moveItem(at: renamed, to: root.appendingPathComponent("移出"))
        repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        #expect(repo!.state.materials[0].isMissing == true)
        #expect(!fm.fileExists(atPath: renamed.path))
    }

    @Test func identityWinsWhenOldPathIsReusedAndCopiesAreNotImported() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record), renamed = original.deletingLastPathComponent().appendingPathComponent("renamed.txt")
            try fm.moveItem(at: original, to: renamed)
            try Data("replacement".utf8).write(to: original)
            try fm.copyItem(at: renamed, to: renamed.deletingLastPathComponent().appendingPathComponent("copy.txt"))
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials.count == 1)
            #expect(try repo.resolveURL(record) == renamed)
            #expect(try String(contentsOf: original, encoding: .utf8) == "replacement")
        }
    }

    @Test func atomicReplacementAndCaseOnlyRenameDoNotLoseRecord() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record)
            try Data("new content".utf8).write(to: original, options: .atomic)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == nil && repo.state.materials[0].size == 11)
            let renamed = original.deletingLastPathComponent().appendingPathComponent(original.lastPathComponent.uppercased())
            try fm.moveItem(at: original, to: renamed)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].storedPath.hasSuffix(renamed.lastPathComponent))
        }
    }

    @Test func folderMovedToUnassignedRemainsPhysical() throws {
        try fixture { root, repo, first, _ in
            let folder = try repo.createMaterialFolder(name: "目录", courseID: first.id)
            let record = try material(repo, root: root, course: first, folder: folder.id)
            let destination = repo.root.appendingPathComponent("files/未分类/资料/目录")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: repo.materialFolderRevealURLs(id: folder.id)[0], to: destination)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materialFolders[0].courseID == nil && repo.state.materials[0].courseID == nil)
            #expect(repo.state.materials[0].folderID == folder.id)
            try repo.setFavorite(id: record.id, favorite: false)
            #expect(try repo.materialFolderRevealURLs(id: folder.id).map(\.path) == [destination.path])
        }
    }

    @Test func failedIndexSaveLeavesExternalMoveIntactAndRetryable() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record), target = original.deletingLastPathComponent().appendingPathComponent("new.txt")
            try fm.moveItem(at: original, to: target)
            let backup = repo.root.appendingPathComponent("library.json.bak")
            try fm.removeItem(at: backup); try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try repo.synchronizeFileSystem() }
            #expect(repo.state.materials[0].storedPath == record.storedPath)
            #expect(fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: original.path))
            try fm.removeItem(at: backup)
            try repo.synchronizeFileSystem()
            #expect(try repo.resolveURL(record) == target)
        }
    }

    @Test func symbolicLinkCannotRedirectManagedRecord() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record), outside = root.appendingPathComponent("outside.txt")
            try fm.moveItem(at: original, to: outside)
            try fm.createSymbolicLink(at: original, withDestinationURL: outside)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == true)
            #expect(throws: (any Error).self) { try repo.resolveURL(record) }
            #expect(try String(contentsOf: outside, encoding: .utf8) == "original content")
        }
    }

    @Test func aNewOccupantDoesNotReplaceAnAlreadyMissingRecord() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record), outside = root.appendingPathComponent("outside.txt")
            try fm.moveItem(at: original, to: outside)
            try repo.synchronizeFileSystem()
            try Data("unrelated".utf8).write(to: original)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == true)
            #expect(throws: (any Error).self) { try repo.resolveURL(record) }
            try repo.setFavorite(id: record.id, favorite: false)
            #expect(try String(contentsOf: original, encoding: .utf8) == "unrelated")
        }
    }

    @Test func ambiguousHardLinksAreNotChosenArbitrarily() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let original = try repo.resolveURL(record)
            try fm.linkItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent("link-a.txt"))
            try fm.linkItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent("link-b.txt"))
            try fm.moveItem(at: original, to: root.appendingPathComponent("outside.txt"))
            try repo.synchronizeFileSystem()
            #expect(repo.state.materials[0].isMissing == true && repo.state.materials[0].storedPath == record.storedPath)
        }
    }

    @Test func portableCopyRebuildsFileIdentitiesAndContinuesTracking() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            let copyURL = root.appendingPathComponent("Copy")
            try repo.copyLibrary(to: copyURL)
            let copy = try LibraryRepository(root: copyURL)
            #expect(copy.state == repo.state)
            let original = try copy.resolveURL(record), renamed = original.deletingLastPathComponent().appendingPathComponent("copy-renamed.txt")
            try fm.moveItem(at: original, to: renamed)
            try copy.synchronizeFileSystem()
            #expect(copy.state.materials[0].originalName == "copy-renamed.txt")
            #expect(try repo.resolveURL(record).lastPathComponent != renamed.lastPathComponent)
        }
    }

    @Test func backupAndRestorePreserveExplicitlyMissingRecords() throws {
        try fixture { root, repo, first, _ in
            let record = try material(repo, root: root, course: first)
            try fm.moveItem(at: repo.resolveURL(record), to: root.appendingPathComponent("outside.txt"))
            let backup = root.appendingPathComponent("Missing.teachshelfbackup")
            try repo.backup(to: backup)
            let target = try LibraryRepository(root: root.appendingPathComponent("Restored"))
            try target.restore(from: backup)
            #expect(target.state.materials[0].isMissing == true && target.state.materials[0].id == record.id)
            #expect(target.state.materials[0].notes == record.notes)
        }
    }

    @Test func finderFolderNamesRetainLegalPOSIXCharacters() throws {
        try fixture { root, repo, first, _ in
            let folder = try repo.createMaterialFolder(name: "目录", courseID: first.id)
            let record = try material(repo, root: root, course: first, folder: folder.id)
            let source = try repo.materialFolderRevealURLs(id: folder.id)[0]
            let name = "chapter:notes\\archive"
            let target = source.deletingLastPathComponent().appendingPathComponent(name)
            try fm.moveItem(at: source, to: target)
            try repo.synchronizeFileSystem()
            #expect(repo.state.materialFolders[0].name == name)
            #expect(try repo.resolveURL(record).deletingLastPathComponent().path == target.path)
        }
    }

    @Test func unsafeStoredDirectoriesCannotRedirectOrRenameTheLibraryRoot() throws {
        try fixture { root, repo, _, _ in
            for path in ["files", "files/../outside", "/tmp", "files//bad", "files/\0bad"] {
                var state = repo.state; state.courses[0].storageDirectory = path
                let invalid = root.appendingPathComponent("Invalid-\(UUID())")
                try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
                let bytes = try JSONEncoder().encode(state), index = invalid.appendingPathComponent("library.json")
                try bytes.write(to: index)
                #expect(throws: (any Error).self) { try LibraryRepository(root: invalid) }
                #expect(try Data(contentsOf: index) == bytes)
            }
        }
    }
}
