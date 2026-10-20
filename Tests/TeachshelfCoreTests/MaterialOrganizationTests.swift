import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct MaterialOrganizationTests {
    private let fm = FileManager.default
    private func fixture(_ action: (URL, LibraryRepository, Course, [MaterialRecord]) throws -> Void) throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-organization-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library")), course = Course(name: "测试课程")
        try repo.saveCourse(course)
        for (index, name) in ["第10章.txt", "第2章.txt", "第1章.txt", "草稿.txt"].enumerated() {
            let source = root.appendingPathComponent(name)
            try name.write(to: source, atomically: true, encoding: .utf8)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "笔记", copy: true)
            var record = repo.state.materials.last!
            record.addedAt = Date(timeIntervalSinceReferenceDate: Double(index))
            try repo.updateMaterial(record)
        }
        try action(root, repo, course, repo.state.materials)
    }

    @Test func naturalNamesNewestFirstAndCustomOrderRemainIndependent() throws {
        try fixture { _, repo, course, records in
            #expect(MaterialOrdering.sorted(records, by: .name).filter { $0.title.hasPrefix("第") }.map(\.title) == ["第1章", "第2章", "第10章"])
            #expect(MaterialOrdering.sorted(records, by: .time).map(\.id) == records.reversed().map(\.id))
            try repo.setMaterialSort(.name, courseID: course.id)
            try repo.setMaterialSort(.custom, courseID: course.id)
            let initial = MaterialOrdering.sorted(repo.state.materials, by: .custom)
            try repo.reorderMaterials(ids: Set(initial.suffix(2).map(\.id)), before: initial[0].id, courseID: course.id, folderID: nil)
            let changed = MaterialOrdering.sorted(repo.state.materials, by: .custom).map(\.id)
            #expect(changed == (Array(initial.suffix(2)) + Array(initial.prefix(2))).map(\.id))
            try repo.setMaterialSort(.time, courseID: course.id)
            try repo.setMaterialSort(.custom, courseID: course.id)
            #expect(MaterialOrdering.sorted(repo.state.materials, by: .custom).map(\.id) == changed)
        }
    }

    @Test func filteredDragRetainsHiddenRecordsAndRejectsForeignSelectionsAtomically() throws {
        try fixture { _, repo, course, records in
            try repo.setMaterialSort(.custom, courseID: course.id)
            let before = MaterialOrdering.sorted(repo.state.materials, by: .custom)
            try repo.reorderMaterials(ids: [before[3].id], before: before[1].id, courseID: course.id, folderID: nil)
            #expect(MaterialOrdering.sorted(repo.state.materials, by: .custom).map(\.id) == [before[0].id, before[3].id, before[1].id, before[2].id])
            let snapshot = repo.state
            #expect(throws: (any Error).self) { try repo.reorderMaterials(ids: [records[0].id, UUID()], before: nil, courseID: course.id, folderID: nil) }
            #expect(repo.state == snapshot)
        }
    }

    @Test func groupingIsAtomicCourseScopedAndLeavesFilePathsUntouched() throws {
        try fixture { _, repo, course, records in
            let group = try repo.createMaterialFolder(name: "复习", courseID: course.id, materialIDs: Set(records.prefix(2).map(\.id)))
            let nested = try repo.createMaterialFolder(name: "重点", courseID: course.id, parentID: group.id)
            try repo.moveMaterials(ids: [records[1].id], to: nested.id, courseID: course.id)
            #expect(repo.state.materials[1].folderID == nested.id)
            #expect(repo.state.materials.map(\.storedPath) == records.map(\.storedPath))
            let other = Course(name: "其他课程"); try repo.saveCourse(other)
            let snapshot = repo.state
            #expect(throws: (any Error).self) { try repo.moveMaterials(ids: [records[0].id], to: group.id, courseID: other.id) }
            #expect(throws: (any Error).self) { try repo.createMaterialFolder(name: "复习", courseID: course.id) }
            #expect(throws: (any Error).self) { try repo.createMaterialFolder(name: "../逃逸", courseID: course.id, materialIDs: [records[2].id]) }
            #expect(repo.state == snapshot)
            try repo.dissolveMaterialFolder(id: group.id)
            #expect(repo.state.materialFolders.isEmpty)
            #expect(repo.state.materials.allSatisfy { $0.folderID == nil })
        }
    }

    @Test func movingCourseClearsItsOldFolderAndDeletingCoursePreservesFiles() throws {
        try fixture { _, repo, course, records in
            let folder = try repo.createMaterialFolder(name: "资料", courseID: course.id, materialIDs: [records[0].id])
            var material = repo.state.materials[0]
            material.courseID = nil; try repo.updateMaterial(material)
            #expect(repo.state.materials[0].folderID == nil)
            try repo.deleteCourse(id: course.id)
            #expect(!repo.state.materialFolders.contains { $0.id == folder.id })
            #expect(repo.state.materials.allSatisfy { $0.courseID == nil && $0.folderID == nil })
            for record in repo.state.materials { #expect(fm.fileExists(atPath: try repo.resolveURL(record).path)) }
        }
    }

    @Test func importIntoFolderAndFailedGroupSaveKeepSnapshotConsistent() throws {
        try fixture { root, repo, course, records in
            let folder = try repo.createMaterialFolder(name: "分组", courseID: course.id)
            let source = root.appendingPathComponent("新增.txt"); try "新增".write(to: source, atomically: true, encoding: .utf8)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "笔记", copy: false, folderID: folder.id)
            #expect(repo.state.materials.last?.folderID == folder.id)
            let before = repo.state
            let index = repo.root.appendingPathComponent("library.json")
            try fm.removeItem(at: index); try fm.createDirectory(at: index, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try repo.createMaterialFolder(name: "不会保存", courseID: course.id, materialIDs: [records[0].id]) }
            #expect(repo.state == before)
        }
    }

    @Test func versionFiveLoadsWithoutRewritingAndNewGroupsSurviveReopen() throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Teachshelf-legacy-groups-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var old = LibraryState(); old.schemaVersion = 5; old.courses = [Course(name: "旧课程")]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "materialFolders")
        let bytes = try JSONSerialization.data(withJSONObject: object), index = root.appendingPathComponent("library.json")
        try bytes.write(to: index)
        var repo: LibraryRepository? = try LibraryRepository(root: root)
        #expect(repo?.state.schemaVersion == 6 && repo?.state.materialFolders.isEmpty == true)
        #expect(try Data(contentsOf: index) == bytes)
        let folder = try repo!.createMaterialFolder(name: "保留分组", courseID: old.courses[0].id)
        try repo!.setMaterialSort(.custom, courseID: old.courses[0].id)
        repo = nil
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state.materialFolders == [folder])
        #expect(reopened.state.courses[0].materialSort == .custom)
    }

    @Test func zipIncludesSelectedManagedAndReferencedFilesWithGroupsAndDuplicateNames() throws {
        try fixture { root, repo, course, records in
            let folder = try repo.createMaterialFolder(name: "复习", courseID: course.id, materialIDs: [records[0].id])
            let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
            try fm.createDirectory(at: a, withIntermediateDirectories: false); try fm.createDirectory(at: b, withIntermediateDirectories: false)
            let one = a.appendingPathComponent("同名.txt"), two = b.appendingPathComponent("同名.txt")
            try "一".write(to: one, atomically: true, encoding: .utf8); try "二".write(to: two, atomically: true, encoding: .utf8)
            _ = try repo.importFiles(urls: [one, two], courseID: course.id, category: "笔记", copy: false, folderID: folder.id)
            let selected = Set([records[0].id] + repo.state.materials.suffix(2).map(\.id)), target = root.appendingPathComponent("资料.zip")
            let snapshot = repo.state
            try repo.exportMaterials(ids: selected, to: target)
            let zipBytes = try Data(contentsOf: target)
            #expect(zipBytes[7] & 0x08 == 0x08, "ZIP 的本地文件头必须标记 UTF-8")
            #expect(zipBytes.range(of: Data("复习".utf8)) != nil)
            let expanded = root.appendingPathComponent("expanded")
            let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); unzip.arguments = ["-x", "-k", target.path, expanded.path]
            try unzip.run(); unzip.waitUntilExit(); #expect(unzip.terminationStatus == 0)
            let dir = expanded.appendingPathComponent("课程资料/复习")
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            #expect(names.count == 3 && names.contains("同名.txt") && names.contains("同名 (2).txt"))
            #expect(Set(try names.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }) == ["第10章.txt", "一", "二"])
            #expect(repo.state == snapshot)
            #expect(try String(contentsOf: one, encoding: .utf8) == "一")
        }
    }

    @Test func failedZipNeverOverwritesDestinationOrIncludesUnselectedFiles() throws {
        try fixture { root, repo, _, records in
            let target = root.appendingPathComponent("保留.zip"); try Data("之前的压缩包".utf8).write(to: target)
            try fm.removeItem(at: repo.resolveURL(records[0]))
            #expect(throws: (any Error).self) { try repo.exportMaterials(ids: [records[0].id], to: target) }
            #expect(try String(contentsOf: target, encoding: .utf8) == "之前的压缩包")
            #expect(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".teachshelf-export-") })
            #expect(throws: (any Error).self) { try repo.exportMaterials(ids: [records[1].id], to: repo.root.appendingPathComponent("禁止.zip")) }
        }
    }

    @Test func deletingReferencedRecordsLeavesOriginalsAndUnlinksPlans() throws {
        try fixture { root, repo, course, _ in
            let source = root.appendingPathComponent("外部文件.txt"); try "保留".write(to: source, atomically: true, encoding: .utf8)
            _ = try repo.importFiles(urls: [source], courseID: course.id, category: "笔记", copy: false)
            let record = repo.state.materials.last!
            let task = StudyTask(title: "关联计划", courseID: course.id, materialIDs: [record.id]); try repo.saveTask(task)
            try repo.trashMaterials(ids: [record.id])
            #expect(!repo.state.materials.contains { $0.id == record.id })
            #expect(repo.state.tasks[0].materialIDs.isEmpty)
            #expect(try String(contentsOf: source, encoding: .utf8) == "保留")
        }
    }

    @Test func failedTrashBatchRestoresAlreadyMovedCopiesAndKeepsMetadata() throws {
        try fixture { root, repo, _, records in
            let trash = root.appendingPathComponent("DisposableTrash")
            try fm.createDirectory(at: trash, withIntermediateDirectories: false)
            let before = repo.state, sources = try records.prefix(2).map { try repo.resolveURL($0) }
            var calls = 0
            #expect(throws: (any Error).self) {
                try repo.trashMaterials(ids: Set(records.prefix(2).map(\.id)), moveToTrash: { source in
                    calls += 1
                    if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
                    let target = trash.appendingPathComponent(source.lastPathComponent)
                    try fm.moveItem(at: source, to: target); return target
                })
            }
            #expect(repo.state == before)
            #expect(sources.allSatisfy { fm.fileExists(atPath: $0.path) })
            #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
        }
    }

    @Test func failedMetadataCommitRestoresTrashedCopiesAndSuccessfulDeletionKeepsOriginals() throws {
        try fixture { root, repo, _, records in
            let trash = root.appendingPathComponent("DisposableTrash")
            try fm.createDirectory(at: trash, withIntermediateDirectories: false)
            let before = repo.state, source = try repo.resolveURL(records[0])
            let index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
            try fm.removeItem(at: index); try fm.createDirectory(at: index, withIntermediateDirectories: false)
            let mover: (URL) throws -> URL = { source in
                let target = trash.appendingPathComponent(source.lastPathComponent)
                try fm.moveItem(at: source, to: target); return target
            }
            #expect(throws: (any Error).self) { try repo.trashMaterials(ids: [records[0].id], moveToTrash: mover) }
            #expect(repo.state == before && fm.fileExists(atPath: source.path))
            try fm.removeItem(at: index); try bytes.write(to: index)
            try repo.trashMaterials(ids: [records[0].id], moveToTrash: mover)
            #expect(!repo.state.materials.contains { $0.id == records[0].id })
            #expect(!fm.fileExists(atPath: source.path))
            #expect(fm.fileExists(atPath: records[0].sourcePath))
        }
    }
}
