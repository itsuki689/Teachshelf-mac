import Foundation
import Testing
@testable import TeachshelfCore

@Suite final class LibraryMCPServiceTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPLibrary-\(UUID())")
    deinit { try? FileManager.default.removeItem(at: root) }
    struct Fixture {
        let repo: LibraryRepository
        let service: LibraryMCPService
        let first: Course
        let second: Course
        let folder: MaterialFolder
        let material: MaterialRecord
        let source: URL
    }
    func fixture() throws -> Fixture {
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let first = Course(name: "数学", semester: "2026 秋"), second = Course(name: "计算机")
        try repo.saveCourse(first); try repo.saveCourse(second)
        let folder = try repo.createMaterialFolder(name: "讲义", courseID: first.id)
        let source = root.appendingPathComponent("source.txt"); try Data("fixture content".utf8).write(to: source)
        _ = try repo.importFiles(urls: [source], courseID: first.id, category: "课件", copy: true, folderID: folder.id)
        return Fixture(repo: repo, service: LibraryMCPService(repository: repo), first: first, second: second, folder: folder, material: repo.state.materials[0], source: source)
    }
    func write(_ f: Fixture, _ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        var a = arguments; a["library_id"] = f.service.libraryID
        a["expected_library_revision"] = try f.service.context()["library_revision"]
        return try f.service.call(name: name, arguments: a)
    }
    @Test func catalogIsUniqueAndDoesNotExposeFileContentOrExternalImports() {
        let names = TeachshelfMCPTools.definitions.compactMap { $0["name"] as? String }
        #expect(names.count == 25 && Set(names).count == names.count)
        #expect(!names.contains("teachshelf_read_material_text") && !names.contains("teachshelf_import_materials"))
    }
    @Test func courseRenameArchiveDeletePreserveFilesAndPlanHistory() throws {
        let f = try fixture(), old = try f.repo.resolveURL(f.material)
        let plan = StudyTask(title: "关联计划", courseID: f.first.id, materialIDs: [f.material.id], hasExecutionTime: false)
        try f.repo.savePlan(plan)
        _ = try write(f, "teachshelf_update_course", ["id": f.first.id.uuidString, "patch": ["name": "高等数学", "teacher": "陈老师", "archived": true]])
        let renamed = f.repo.state.courses.first { $0.id == f.first.id }!
        #expect(renamed.name == "高等数学" && renamed.teacher == "陈老师" && renamed.isArchived)
        #expect(renamed.semester == "2026 秋")
        let newURL = try f.repo.resolveURL(f.repo.state.materials[0])
        #expect(newURL != old && !FileManager.default.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: newURL) == Data(contentsOf: f.source))
        #expect(f.repo.state.tasks[0].courseNameSnapshot == "高等数学")
        _ = try write(f, "teachshelf_delete_course", ["id": f.first.id.uuidString])
        #expect(!f.repo.state.courses.contains { $0.id == f.first.id })
        #expect(f.repo.state.materials[0].courseID == nil && f.repo.state.materials[0].folderID == nil)
        #expect(f.repo.state.tasks[0].courseID == nil && f.repo.state.tasks[0].materialIDs == [f.material.id])
        #expect(try Data(contentsOf: f.repo.resolveURL(f.repo.state.materials[0])) == Data(contentsOf: f.source))
    }
    @Test func courseAndFolderCreationRequireFreshRevisionAndStableIDs() throws {
        let f = try fixture(), id = UUID().uuidString
        let result = try write(f, "teachshelf_create_course", ["request_id": id, "fields": ["name": "新课程", "color_hex": "#112233"]])
        #expect((result["course"] as? [String: Any])?["id"] as? String == id)
        #expect(throws: (any Error).self) { try write(f, "teachshelf_create_course", ["request_id": id, "fields": ["name": "重复"]]) }
        let folder = UUID().uuidString
        _ = try write(f, "teachshelf_create_material_folder", ["request_id": folder, "name": "空文件夹", "course_id": id])
        let path = try f.repo.materialFolderRevealURLs(id: UUID(uuidString: folder)!)[0]
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(throws: (any Error).self) { try write(f, "teachshelf_create_material_folder", ["request_id": UUID().uuidString, "name": "空文件夹", "course_id": id]) }
    }
    @Test func materialMetadataAndFilenameAreSeparateAndCollisionsRollBack() throws {
        let f = try fixture(), old = try f.repo.resolveURL(f.material)
        _ = try write(f, "teachshelf_update_material", ["id": f.material.id.uuidString, "patch": ["title": "第一讲", "category": "教材", "tags": "重点", "notes": "复习定义", "favorite": true]])
        #expect(try f.repo.resolveURL(f.repo.state.materials[0]) == old)
        _ = try write(f, "teachshelf_update_material", ["id": f.material.id.uuidString, "patch": ["filename": "第一讲.txt"]])
        let renamed = f.repo.state.materials[0], url = try f.repo.resolveURL(renamed)
        #expect(url.lastPathComponent == "第一讲.txt" && renamed.title == "第一讲" && renamed.isFavorite)
        #expect(renamed.notes == "复习定义" && renamed.tags == "重点" && renamed.category == "教材")
        let occupied = url.deletingLastPathComponent().appendingPathComponent("占用.txt")
        try Data("unindexed user file".utf8).write(to: occupied)
        #expect(throws: (any Error).self) { try write(f, "teachshelf_update_material", ["id": renamed.id.uuidString, "patch": ["filename": "占用.txt"]]) }
        #expect(f.repo.state.materials[0] == renamed)
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "unindexed user file")
        #expect(try Data(contentsOf: url) == Data(contentsOf: f.source))
    }
    @Test func batchMoveIsAtomicAndExternalReferenceStaysInPlace() throws {
        let f = try fixture(), destination = try f.repo.createMaterialFolder(name: "目标", courseID: f.second.id)
        let external = root.appendingPathComponent("reference.txt"); try Data("external".utf8).write(to: external)
        _ = try f.repo.importFiles(urls: [external], courseID: f.first.id, category: "课件", copy: false)
        let ids = f.repo.state.materials.map { $0.id.uuidString }
        _ = try write(f, "teachshelf_move_materials", ["ids": ids, "course_id": f.second.id.uuidString, "folder_id": destination.id.uuidString])
        #expect(f.repo.state.materials.allSatisfy { $0.courseID == f.second.id && $0.folderID == destination.id })
        #expect(try f.repo.resolveURL(f.repo.state.materials.first { !$0.isManaged }!) == external)
        #expect(FileManager.default.fileExists(atPath: external.path))
        let before = f.repo.state
        #expect(throws: (any Error).self) { try write(f, "teachshelf_move_materials", ["ids": ids + [UUID().uuidString], "course_id": NSNull(), "folder_id": NSNull()]) }
        #expect(f.repo.state == before)
        #expect(throws: (any Error).self) { try write(f, "teachshelf_move_materials", ["ids": ids, "course_id": f.first.id.uuidString, "folder_id": destination.id.uuidString]) }
        #expect(f.repo.state == before)
    }
    @Test func failedIndexSaveRollsBackPhysicalMoveAndMetadata() throws {
        let f = try fixture(), before = f.repo.state, oldURL = try f.repo.resolveURL(f.material)
        let index = f.repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        let backup = f.repo.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try write(f, "teachshelf_move_materials", ["ids": [f.material.id.uuidString], "course_id": f.second.id.uuidString, "folder_id": NSNull()])
        }
        #expect(f.repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
        #expect(try Data(contentsOf: oldURL) == Data(contentsOf: f.source))
        #expect(try f.repo.resolveURL(f.repo.state.materials[0]) == oldURL)
    }
    @Test func nestedFolderMoveRetainsIDsBytesAndUnindexedContents() throws {
        let f = try fixture(), child = try f.repo.createMaterialFolder(name: "子目录", courseID: f.first.id, parentID: f.folder.id)
        try f.repo.moveMaterials(ids: [f.material.id], to: child.id, courseID: f.first.id)
        let folderURL = try f.repo.materialFolderRevealURLs(id: f.folder.id)[0]
        try Data("loose".utf8).write(to: folderURL.appendingPathComponent("other.txt"))
        _ = try write(f, "teachshelf_update_material_folder", ["id": f.folder.id.uuidString, "patch": ["course_id": f.second.id.uuidString, "name": "移入讲义"]])
        #expect(f.repo.state.materialFolders.allSatisfy { $0.courseID == f.second.id })
        #expect(f.repo.state.materials[0].courseID == f.second.id && f.repo.state.materials[0].folderID == child.id)
        #expect(try Data(contentsOf: f.repo.resolveURL(f.repo.state.materials[0])) == Data(contentsOf: f.source))
        let moved = try f.repo.materialFolderRevealURLs(id: f.folder.id)[0]
        #expect(try String(contentsOf: moved.appendingPathComponent("other.txt"), encoding: .utf8) == "loose")
        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
        #expect(throws: (any Error).self) { try write(f, "teachshelf_update_material_folder", ["id": f.folder.id.uuidString, "patch": ["parent_id": child.id.uuidString]]) }
    }
    @Test func dissolveFlattensDescendantsAndRemovalRetainsFile() throws {
        let f = try fixture(), child = try f.repo.createMaterialFolder(name: "子目录", courseID: f.first.id, parentID: f.folder.id)
        try f.repo.moveMaterials(ids: [f.material.id], to: child.id, courseID: f.first.id)
        try f.repo.savePlan(StudyTask(title: "关联", materialIDs: [f.material.id]))
        _ = try write(f, "teachshelf_dissolve_material_folder", ["id": f.folder.id.uuidString])
        #expect(f.repo.state.materialFolders.isEmpty && f.repo.state.materials[0].folderID == nil)
        let url = try f.repo.resolveURL(f.repo.state.materials[0])
        _ = try write(f, "teachshelf_remove_materials", ["ids": [f.material.id.uuidString]])
        #expect(f.repo.state.materials.isEmpty && f.repo.state.tasks[0].materialIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test func revisionGuardsUIFinderAndPlanChangesButIgnoresAppearanceAndOpenTimes() throws {
        let f = try fixture(), revision = try f.service.context()["library_revision"] as! String
        try f.repo.recordOpen(id: f.material.id); try f.repo.saveAppearance("dark")
        #expect(try f.service.context()["library_revision"] as? String == revision)
        let oldURL = try f.repo.resolveURL(f.material), renamed = oldURL.deletingLastPathComponent().appendingPathComponent("Finder.txt")
        try FileManager.default.moveItem(at: oldURL, to: renamed)
        let stale: [String: Any] = ["library_id": f.service.libraryID, "expected_library_revision": revision, "id": f.material.id.uuidString, "patch": ["notes": "stale"]]
        #expect(throws: (any Error).self) { try f.service.call(name: "teachshelf_update_material", arguments: stale) }
        #expect(f.repo.state.materials[0].notes.isEmpty)
        let fresh = try f.service.context()["library_revision"] as! String
        try f.repo.savePlan(StudyTask(title: "新关联", materialIDs: [f.material.id]))
        var a = stale; a["expected_library_revision"] = fresh
        #expect(throws: (any Error).self) { try f.service.call(name: "teachshelf_update_material", arguments: a) }
        a["library_id"] = "wrong"; a["expected_library_revision"] = try f.service.context()["library_revision"]
        #expect(throws: (any Error).self) { try f.service.call(name: "teachshelf_update_material", arguments: a) }
    }
    @Test func searchFiltersPaginationAndDetailsDoNotReturnSourcePaths() throws {
        let f = try fixture()
        _ = try write(f, "teachshelf_update_material", ["id": f.material.id.uuidString, "patch": ["tags": "复习", "notes": "章节重点", "favorite": true]])
        let result = try f.service.call(name: "teachshelf_list_materials", arguments: ["query": "重点", "favorite": true, "course_id": f.first.id.uuidString, "limit": 1])
        #expect(result["total"] as? Int == 1)
        #expect(try f.service.call(name: "teachshelf_list_materials", arguments: ["folder_id": NSNull()])["total"] as? Int == 0)
        #expect(try f.service.call(name: "teachshelf_list_materials", arguments: ["folder_id": NSNull(), "recursive": true, "course_id": f.first.id.uuidString])["total"] as? Int == 1)
        #expect((try f.service.context()["material_categories"] as? [String])?.contains("教材") == true)
        #expect(try f.service.call(name: "teachshelf_list_materials", arguments: ["course_id": NSNull()])["total"] as? Int == 0)
        let details = try f.service.call(name: "teachshelf_get_material", arguments: ["id": f.material.id.uuidString])
        let text = String(data: try JSONSerialization.data(withJSONObject: details), encoding: .utf8)!
        #expect(!text.contains(f.source.path) && !text.contains("sourcePath") && !text.contains("storedPath"))
        #expect(throws: (any Error).self) { try f.service.call(name: "teachshelf_list_materials", arguments: ["limit": 101]) }
    }
    @Test func unsafeNamesUnknownFieldsAndExternalRenamesAreRejected() throws {
        let f = try fixture()
        for name in ["../escape.txt", "bad\0.txt", "file.pdf", ""] {
            #expect(throws: (any Error).self) { try write(f, "teachshelf_update_material", ["id": f.material.id.uuidString, "patch": ["filename": name]]) }
        }
        for name in ["..", "a/b", ""] {
            #expect(throws: (any Error).self) { try write(f, "teachshelf_create_material_folder", ["request_id": UUID().uuidString, "name": name, "course_id": f.first.id.uuidString]) }
        }
        #expect(throws: (any Error).self) { try write(f, "teachshelf_update_material", ["id": f.material.id.uuidString, "patch": ["storedPath": "/tmp/other"]]) }
        #expect(throws: (any Error).self) { try write(f, "teachshelf_update_course", ["id": f.first.id.uuidString, "patch": ["homeworkFolder": "/tmp"]]) }
        _ = try f.repo.importFiles(urls: [f.source], courseID: f.second.id, category: "课件", copy: false)
        let reference = f.repo.state.materials.first { !$0.isManaged }!
        #expect(throws: (any Error).self) { try write(f, "teachshelf_update_material", ["id": reference.id.uuidString, "patch": ["filename": "external.txt"]]) }
    }
}
