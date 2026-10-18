import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct MaterialStorageTests {
    private let fm = FileManager.default

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-storage-\(UUID().uuidString)")
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

    private func legacyState(course: Course) -> LibraryState {
        let id = UUID()
        var state = LibraryState()
        state.courses = [course]
        state.materials = [MaterialRecord(id: id, courseID: course.id, title: "保留标题", originalName: "lecture.pdf", sourcePath: "/missing/original.pdf", storedPath: "files/\(id.uuidString)-lecture.pdf", isManaged: true, tags: "期末", notes: "保留备注", size: 7)]
        return state
    }

    @Test func importsUseSeparateReadableCourseFoldersAndAnUnassignedFolder() throws {
        try fixture { folder in
            let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
            let a = Course(name: "数据库"), b = Course(name: "数据库")
            try repo.saveCourse(a); try repo.saveCourse(b)
            let source = folder.appendingPathComponent("lecture.pdf")
            try write("content", to: source)
            for id in [a.id, b.id, nil] {
                let result = try repo.importFiles(urls: [source], courseID: id, category: "课件", copy: true)
                #expect(result.imported == 1 && result.errors.isEmpty)
            }
            let records = repo.state.materials
            #expect(Set(records.map { URL(fileURLWithPath: $0.storedPath).deletingLastPathComponent().path }).count == 3)
            #expect(records[0].storedPath.hasPrefix("files/数据库 [\(a.id.uuidString)]/"))
            #expect(records[1].storedPath.hasPrefix("files/数据库 [\(b.id.uuidString)]/"))
            #expect(records[2].storedPath.hasPrefix("files/未分类/"))
            for record in records {
                #expect(try String(contentsOf: repo.resolveURL(record), encoding: .utf8) == "content")
            }
            #expect(try String(contentsOf: source, encoding: .utf8) == "content")
        }
    }

    @Test func renamingReassigningAndDeletingCoursesKeepFilePathsInSync() throws {
        try fixture { folder in
            let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
            var a = Course(name: "旧课程")
            let b = Course(name: "目标课程")
            try repo.saveCourse(a); try repo.saveCourse(b)
            let source = folder.appendingPathComponent("lecture.pdf")
            try write("content", to: source)
            _ = try repo.importFiles(urls: [source], courseID: a.id, category: "课件", copy: true)
            let original = try #require(repo.state.materials.first)
            let oldURL = try repo.resolveURL(original)
            a.name = "新课程"
            try repo.saveCourse(a)
            var record = try #require(repo.state.materials.first)
            #expect(record.storedPath.hasPrefix("files/新课程 [\(a.id.uuidString)]/"))
            #expect(!fm.fileExists(atPath: oldURL.path))
            #expect(!fm.fileExists(atPath: oldURL.deletingLastPathComponent().path))
            record.courseID = b.id; record.notes = "保留注释"
            try repo.updateMaterial(record)
            record = try #require(repo.state.materials.first)
            #expect(record.storedPath.hasPrefix("files/目标课程 [\(b.id.uuidString)]/"))
            try repo.archiveCourse(id: b.id, archived: true)
            #expect(repo.state.materials.first?.storedPath == record.storedPath)
            try repo.deleteCourse(id: b.id)
            record = try #require(repo.state.materials.first)
            #expect(record.courseID == nil && record.storedPath.hasPrefix("files/未分类/"))
            #expect(record.id == original.id && record.sourcePath == original.sourcePath && record.notes == "保留注释")
            #expect(try String(contentsOf: repo.resolveURL(record), encoding: .utf8) == "content")
            #expect(try repo.resolveURL(original) == repo.resolveURL(record))
        }
    }

    @Test func openingAnOldLibraryMigratesManagedFilesAndRetainsOrphansAndReferences() throws {
        try fixture { root in
            var state = legacyState(course: Course(name: "线性代数"))
            let original = state.materials[0]
            state.materials.append(MaterialRecord(title: "外部", originalName: "external.pdf", sourcePath: "/missing/external.pdf", storedPath: "/missing/external.pdf", isManaged: false))
            try writeState(state, at: root)
            let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
            try write("content", to: root.appendingPathComponent(original.storedPath))
            try write("orphan", to: root.appendingPathComponent("files/orphan.pdf"))
            var repo: LibraryRepository? = try LibraryRepository(root: root)
            let migrated = try #require(repo?.state.materials.first)
            #expect(migrated.id == original.id && migrated.tags == original.tags && migrated.notes == original.notes)
            #expect(migrated.storedPath.hasPrefix("files/线性代数 ["))
            #expect(try Data(contentsOf: repo!.resolveURL(migrated)) == Data("content".utf8))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(original.storedPath).path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent("files/orphan.pdf").path))
            #expect(repo?.state.materials.last == state.materials.last)
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json.bak")) == before)
            let committed = try Data(contentsOf: root.appendingPathComponent("library.json"))
            repo = nil
            let reopened = try LibraryRepository(root: root)
            #expect(reopened.state.materials.first == migrated)
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json")) == committed)
        }
    }

    @Test func aFailedMigrationLeavesTheOldIndexAndFilesUsable() throws {
        try fixture { root in
            let state = legacyState(course: Course(name: "数学")), original = state.materials[0]
            try writeState(state, at: root)
            try write("content", to: root.appendingPathComponent(original.storedPath))
            let index = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("library.json.bak")
            let before = try Data(contentsOf: index)
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
            #expect(try Data(contentsOf: index) == before)
            #expect(try String(contentsOf: root.appendingPathComponent(original.storedPath), encoding: .utf8) == "content")
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".material-relocation.json").path))
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("files").path) == [URL(fileURLWithPath: original.storedPath).lastPathComponent])
            try fm.removeItem(at: backup)
            let repo = try LibraryRepository(root: root)
            #expect(repo.state.materials[0].storedPath != original.storedPath)
        }
    }

    @Test func failedCourseRenameRollsBackAllPreparedFilesAndMetadata() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            var course = Course(name: "旧名")
            try repo.saveCourse(course)
            for name in ["a.pdf", "b.pdf"] {
                let source = root.appendingPathComponent(name)
                try write(name, to: source)
                _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true)
            }
            let before = repo.state
            let backup = repo.root.appendingPathComponent("library.json.bak")
            try fm.removeItem(at: backup)
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            course.name = "新名"
            #expect(throws: (any Error).self) { try repo.saveCourse(course) }
            #expect(repo.state == before)
            for record in before.materials { #expect(fm.fileExists(atPath: try repo.resolveURL(record).path)) }
            #expect(try fm.contentsOfDirectory(atPath: repo.root.appendingPathComponent("files").path).count == 1)
            #expect(!fm.fileExists(atPath: repo.root.appendingPathComponent(".material-relocation.json").path))
        }
    }

    @Test func migrationNeverOverwritesAnUnrelatedDestinationFile() throws {
        try fixture { root in
            let state = legacyState(course: Course(name: "数学")), original = state.materials[0]
            try writeState(state, at: root)
            try write("content", to: root.appendingPathComponent(original.storedPath))
            let destination = root.appendingPathComponent(MaterialStorageLayout.relativePath(for: original, courses: state.courses))
            try write("keep this unrelated file", to: destination)
            #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "keep this unrelated file")
            #expect(try String(contentsOf: root.appendingPathComponent(original.storedPath), encoding: .utf8) == "content")
        }
    }

    @Test func missingLegacyFilesRemainRemovableAndDoNotBlockOpening() throws {
        try fixture { root in
            let state = legacyState(course: Course(name: "数学"))
            try writeState(state, at: root)
            let repo = try LibraryRepository(root: root)
            #expect(repo.state == state)
            #expect(throws: (any Error).self) { try repo.resolveURL(state.materials[0]) }
            try repo.removeMaterials(ids: [state.materials[0].id])
            #expect(repo.state.materials.isEmpty)
        }
    }

    @Test func aSymlinkInTheCourseDestinationCannotRedirectMigration() throws {
        try fixture { folder in
            let root = folder.appendingPathComponent("Library"), outside = folder.appendingPathComponent("Outside")
            let state = legacyState(course: Course(name: "数学")), record = state.materials[0]
            try writeState(state, at: root)
            try write("content", to: root.appendingPathComponent(record.storedPath))
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = root.appendingPathComponent(MaterialStorageLayout.relativePath(for: record, courses: state.courses))
            try fm.createSymbolicLink(at: target.deletingLastPathComponent(), withDestinationURL: outside)
            #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
            #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
            #expect(try String(contentsOf: root.appendingPathComponent(record.storedPath), encoding: .utf8) == "content")
        }
    }

    @Test(arguments: [false, true]) func interruptedRelocationsRecoverUsingTheCommittedIndex(committed: Bool) throws {
        try fixture { root in
            let a = Course(name: "原课程"), b = Course(name: "目标课程")
            var state = legacyState(course: a)
            state.courses.append(b)
            var record = state.materials[0]
            let source = MaterialStorageLayout.relativePath(for: record, courses: state.courses)
            record.courseID = b.id
            let destination = MaterialStorageLayout.relativePath(for: record, courses: state.courses)
            try write("content", to: root.appendingPathComponent(source))
            try write("content", to: root.appendingPathComponent(destination))
            state.materials[0].courseID = committed ? b.id : a.id
            state.materials[0].storedPath = committed ? destination : source
            try writeState(state, at: root)
            let journal = root.appendingPathComponent(".material-relocation.json")
            let temporary = "files/.material-copy-\(UUID().uuidString)"
            try write("partial copy", to: root.appendingPathComponent(temporary))
            try JSONSerialization.data(withJSONObject: [["source": source, "destination": destination, "temporary": temporary]]).write(to: journal)
            let repo = try LibraryRepository(root: root)
            #expect(repo.state == state)
            #expect(fm.fileExists(atPath: try repo.resolveURL(state.materials[0]).path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(committed ? source : destination).path))
            #expect(!fm.fileExists(atPath: journal.path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(temporary).path))
        }
    }

    @Test func courseNamesAreSafeAndLongFilenamesKeepTheirExtension() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            let course = Course(name: "../数学/分析:\\" + String(repeating: "课程", count: 80))
            try repo.saveCourse(course)
            let source = root.appendingPathComponent(String(repeating: "a", count: 230) + ".pdf")
            try write("content", to: source)
            let summary = try repo.importFiles(urls: [source], courseID: course.id, category: "教材", copy: true)
            #expect(summary.imported == 1 && summary.errors.isEmpty)
            let material = try #require(repo.state.materials.first)
            let components = material.storedPath.split(separator: "/")
            #expect(components.count == 3 && components[1].contains(course.id.uuidString))
            #expect(components.allSatisfy { $0.utf8.count <= 255 && $0 != ".." && !$0.contains(":") && !$0.contains("\\") })
            #expect(try repo.resolveURL(material).pathExtension == "pdf")
            #expect(material.originalName == source.lastPathComponent)
        }
    }

    @Test func externalReferencesAndRemovedRecordsKeepTheirPhysicalLocations() throws {
        try fixture { root in
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            var course = Course(name: "课程")
            try repo.saveCourse(course)
            let source = root.appendingPathComponent("reference.pdf"), managedSource = root.appendingPathComponent("managed.pdf")
            try write("external", to: source); try write("managed", to: managedSource)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "课件", copy: false)
            _ = try repo.importFiles(urls: [managedSource], courseID: course.id, category: "课件", copy: true)
            let managed = try #require(repo.state.materials.first(where: { $0.isManaged }))
            let retained = try repo.resolveURL(managed)
            try repo.removeMaterials(ids: [managed.id])
            course.name = "改名"
            try repo.saveCourse(course); try repo.deleteCourse(id: course.id)
            #expect(fm.fileExists(atPath: retained.path))
            let external = try #require(repo.state.materials.first)
            #expect(external.storedPath == source.path && !external.isManaged && external.courseID == nil)
        }
    }

    @Test func oldBackupsRestoreIntoCourseFoldersAndRemainPortable() throws {
        try fixture { root in
            let legacy = root.appendingPathComponent("Legacy.teachshelfbackup")
            let state = legacyState(course: Course(name: "数据库"))
            try writeState(state, at: legacy)
            try write("content", to: legacy.appendingPathComponent(state.materials[0].storedPath))
            let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
            try repo.restore(from: legacy)
            let record = try #require(repo.state.materials.first)
            #expect(record.storedPath.hasPrefix("files/数据库 ["))
            #expect(try String(contentsOf: repo.resolveURL(record), encoding: .utf8) == "content")
            let backup = root.appendingPathComponent("New.teachshelfbackup")
            try repo.backup(to: backup)
            #expect(fm.fileExists(atPath: backup.appendingPathComponent(record.storedPath).path))
            let restored = try LibraryRepository(root: root.appendingPathComponent("Restored"))
            try restored.restore(from: backup)
            #expect(restored.state == repo.state)
            let copy = root.appendingPathComponent("Migrated")
            try repo.copyLibrary(to: copy)
            let migrated = try LibraryRepository(root: copy)
            #expect(migrated.state == repo.state)
            #expect(fm.fileExists(atPath: try migrated.resolveURL(record).path))
        }
    }
}
