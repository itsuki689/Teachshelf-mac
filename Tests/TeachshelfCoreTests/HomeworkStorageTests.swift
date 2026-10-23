import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct HomeworkStorageTests {
    private let fm = FileManager.default

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-homework-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try action(root)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writeState(_ state: LibraryState, at root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("library.json"))
    }

    @Test func defaultHomeworkIsInsideTheSameCourseFolderAsMaterials() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "数据库")
            try repo.saveCourse(course)
            let source = root.appendingPathComponent("lecture.pdf")
            try write("lecture", to: source)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true)
            let material = try #require(repo.state.materials.first)
            let homework = try repo.homeworkURL(courseID: course.id)
            #expect(homework.lastPathComponent == "作业")
            #expect(try homework.deletingLastPathComponent().path == repo.resolveURL(material).deletingLastPathComponent().deletingLastPathComponent().path)
            #expect(try repo.homeworkURL(courseID: nil).path == repo.root.appendingPathComponent("files/未分类/作业").path)
            let exercise = root.appendingPathComponent("实验/代码/main.py")
            try write("print(1)", to: exercise)
            _ = try repo.importHomework(urls: [root.appendingPathComponent("实验")], courseID: course.id, relativePath: "")
            #expect(try String(contentsOf: homework.appendingPathComponent("实验/代码/main.py"), encoding: .utf8) == "print(1)")
            #expect(repo.state.materials.count == 1)
        }
    }

    @Test func openingMigratesLegacyCourseAndPublicTreesPreservingMetadata() throws {
        try fixture { root in
            let course = Course(name: "数学")
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            try writeState(state, at: root)
            let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let legacy = root.appendingPathComponent("HomeworkFiles/\(course.id.uuidString)")
            try write("draft", to: legacy.appendingPathComponent("实验/草稿.md"))
            try write("config", to: legacy.appendingPathComponent("实验/.config"))
            try fm.createDirectory(at: legacy.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            try write("public", to: root.appendingPathComponent("HomeworkFiles/Unassigned/public.txt"))
            let repo = try LibraryRepository(root: root)
            let homework = try repo.homeworkURL(courseID: course.id)
            #expect(try String(contentsOf: homework.appendingPathComponent("实验/草稿.md"), encoding: .utf8) == "draft")
            #expect(fm.fileExists(atPath: homework.appendingPathComponent("实验/.config").path))
            #expect(fm.fileExists(atPath: homework.appendingPathComponent("空目录").path))
            #expect(try repo.listHomework(courseID: nil, relativePath: "").map(\.name) == ["public.txt"])
            #expect(!fm.fileExists(atPath: root.appendingPathComponent("HomeworkFiles").path))
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json.bak")) == bytes)
            #expect(repo.state.courses == state.courses && repo.state.schemaVersion == 9)
        }
    }

    @Test func courseRenameMovesHomeworkAndDeletingTheCourseRetainsItsFiles() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            var course = Course(name: "旧课程")
            try repo.saveCourse(course)
            let old = try repo.homeworkURL(courseID: course.id)
            try write("solution", to: old.appendingPathComponent("实验/main.c"))
            course.name = "新课程"
            try repo.saveCourse(course)
            let current = try repo.homeworkURL(courseID: course.id)
            #expect(current.path.contains("新课程 [\(course.id.uuidString)]/作业"))
            #expect(!fm.fileExists(atPath: old.path))
            #expect(try String(contentsOf: current.appendingPathComponent("实验/main.c"), encoding: .utf8) == "solution")
            try repo.deleteCourse(id: course.id)
            #expect(fm.fileExists(atPath: current.appendingPathComponent("实验/main.c").path))
        }
    }

    @Test func failedRenameRestoresHomeworkAndDoesNotRemovePreexistingFiles() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            var course = Course(name: "旧名")
            try repo.saveCourse(course)
            let source = try repo.homeworkURL(courseID: course.id)
            try write("original", to: source.appendingPathComponent("answer.txt"))
            course.name = "新名"
            let target = repo.root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course))
            try write("keep", to: target.appendingPathComponent("keep.txt"))
            let before = repo.state
            let backup = repo.root.appendingPathComponent("library.json.bak")
            try fm.removeItem(at: backup)
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try repo.saveCourse(course) }
            #expect(repo.state == before)
            #expect(try String(contentsOf: source.appendingPathComponent("answer.txt"), encoding: .utf8) == "original")
            #expect(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
            #expect(!fm.fileExists(atPath: target.appendingPathComponent("answer.txt").path))
        }
    }

    @Test func legacyMergesKeepBothVersionsOfConflictingFilesAndFolderContents() throws {
        try fixture { root in
            let course = Course(name: "数学")
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            try writeState(state, at: root)
            let legacy = root.appendingPathComponent("HomeworkFiles/\(course.id.uuidString)")
            let target = root.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course))
            try write("old answer", to: legacy.appendingPathComponent("实验/answer.txt"))
            try write("same", to: legacy.appendingPathComponent("实验/shared.txt"))
            try write("old code", to: legacy.appendingPathComponent("代码/main.py"))
            try write("new answer", to: target.appendingPathComponent("实验/answer.txt"))
            try write("same", to: target.appendingPathComponent("实验/shared.txt"))
            try write("keep file", to: target.appendingPathComponent("代码"))
            let repo = try LibraryRepository(root: root)
            #expect(try repo.listHomework(courseID: course.id, relativePath: "实验").count == 3)
            #expect(try String(contentsOf: target.appendingPathComponent("实验/answer.txt"), encoding: .utf8) == "new answer")
            #expect(try String(contentsOf: target.appendingPathComponent("实验/answer 2.txt"), encoding: .utf8) == "old answer")
            #expect(try String(contentsOf: target.appendingPathComponent("代码"), encoding: .utf8) == "keep file")
            #expect(try String(contentsOf: target.appendingPathComponent("代码 2/main.py"), encoding: .utf8) == "old code")
            #expect(!fm.fileExists(atPath: legacy.path))
        }
    }

    @Test func externalMountsStayExternalAndTheirInternalFallbackIsMigrated() throws {
        try fixture { root in
            let outside = root.appendingPathComponent("Outside")
            try write("external", to: outside.appendingPathComponent("answer.txt"))
            let course = Course(name: "数学", homeworkFolder: outside.path)
            let library = root.appendingPathComponent("Library")
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            try writeState(state, at: library)
            try write("internal", to: library.appendingPathComponent("HomeworkFiles/\(course.id.uuidString)/draft.txt"))
            let repo = try LibraryRepository(root: library)
            #expect(try repo.homeworkURL(courseID: course.id).path == outside.path)
            #expect(try fm.contentsOfDirectory(atPath: outside.path) == ["answer.txt"])
            try repo.mountHomework(courseID: course.id, url: nil)
            let fallback = try repo.homeworkURL(courseID: course.id)
            #expect(fallback.path == library.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course)).path)
            #expect(try String(contentsOf: fallback.appendingPathComponent("draft.txt"), encoding: .utf8) == "internal")
        }
    }

    @Test(arguments: [false, true]) func interruptedRenamesRecoverTheDirectoryTreeUsingTheIndex(committed: Bool) throws {
        try fixture { root in
            var course = Course(name: "旧名")
            let source = MaterialStorageLayout.homeworkPath(for: course)
            course.name = "新名"
            let target = MaterialStorageLayout.homeworkPath(for: course)
            if !committed { course.name = "旧名" }
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            try writeState(state, at: root)
            try write("answer", to: root.appendingPathComponent(source + "/实验/answer.txt"))
            try write("answer", to: root.appendingPathComponent(target + "/实验/answer.txt"))
            let journal: [[String: Any]] = [
                ["source": source, "destination": target, "homework": true, "directory": true],
                ["source": source + "/实验", "destination": target + "/实验", "homework": true, "directory": true],
                ["source": source + "/实验/answer.txt", "destination": target + "/实验/answer.txt", "homework": true]
            ]
            try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent(".material-relocation.json"))
            let repo = try LibraryRepository(root: root)
            let actual = try repo.homeworkURL(courseID: course.id)
            #expect(actual.path == root.appendingPathComponent(committed ? target : source).path)
            #expect(try String(contentsOf: actual.appendingPathComponent("实验/answer.txt"), encoding: .utf8) == "answer")
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(committed ? source : target).path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".material-relocation.json").path))
        }
    }

    @Test func oldAndNewBackupsRestoreHomeworkAndSupportLibraryMigration() throws {
        try fixture { root in
            let course = Course(name: "数学")
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            let legacy = root.appendingPathComponent("Legacy.teachshelfbackup")
            try writeState(state, at: legacy)
            try write("answer", to: legacy.appendingPathComponent("HomeworkFiles/\(course.id.uuidString)/实验/main.py"))
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            try repo.restore(from: legacy)
            let path = MaterialStorageLayout.homeworkPath(for: course) + "/实验/main.py"
            #expect(try String(contentsOf: repo.root.appendingPathComponent(path), encoding: .utf8) == "answer")
            let backup = root.appendingPathComponent("New.teachshelfbackup")
            try repo.backup(to: backup)
            #expect(fm.fileExists(atPath: backup.appendingPathComponent(path).path))
            let restored = try LibraryRepository(root: root.appendingPathComponent("Restored"))
            try restored.restore(from: backup)
            #expect(try restored.listHomework(courseID: course.id, relativePath: "实验").map(\.name) == ["main.py"])
            let destination = root.appendingPathComponent("Migrated")
            try repo.copyLibrary(to: destination)
            let migrated = try LibraryRepository(root: destination)
            #expect(try migrated.listHomework(courseID: course.id, relativePath: "实验").map(\.name) == ["main.py"])
        }
    }

    @Test func unsafeLegacyTreesAndOccupiedHomeworkRootsArePreserved() throws {
        try fixture { root in
            let course = Course(name: "数学")
            var state = LibraryState(); state.schemaVersion = 8; state.courses = [course]
            let library = root.appendingPathComponent("Library")
            try writeState(state, at: library)
            let source = library.appendingPathComponent("HomeworkFiles/\(course.id.uuidString)")
            try write("answer", to: source.appendingPathComponent("answer.txt"))
            let target = library.appendingPathComponent(MaterialStorageLayout.homeworkPath(for: course))
            try write("keep", to: target)
            #expect(throws: (any Error).self) { try LibraryRepository(root: library) }
            #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
            try fm.removeItem(at: target)
            let outside = root.appendingPathComponent("outside.txt")
            try write("private", to: outside)
            try fm.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)
            #expect(throws: (any Error).self) { try LibraryRepository(root: library) }
            #expect(try String(contentsOf: source.appendingPathComponent("answer.txt"), encoding: .utf8) == "answer")
            #expect(!fm.fileExists(atPath: target.path))
        }
    }
}
