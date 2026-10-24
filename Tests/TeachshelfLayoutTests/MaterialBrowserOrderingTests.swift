import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct MaterialBrowserOrderingTests {
    @Test func chineseChaptersRemainOrderedWhenExpandingEnteringAndSwitchingToCustom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-chinese-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "数据库系统概论"); try repo.saveCourse(course)
        let website = try repo.createMaterialFolder(name: "教学网站", courseID: course.id)
        let handouts = try repo.createMaterialFolder(name: "课件", courseID: course.id, parentID: website.id)
        let chapters = ["第一章", "第二章", "第三章", "第四章", "第五章", "第六章", "第七章", "第十章", "第十一章"]
        let folders = try chapters.reversed().map { try repo.createMaterialFolder(name: $0, courseID: course.id, parentID: handouts.id) }
        let second = try #require(folders.first { $0.name == "第二章" })
        let titles = ["第二节", "第三节", "第10节", "第十一节"]
        let urls = try titles.reversed().map { title -> URL in
            let url = root.appendingPathComponent(title + ".txt")
            try Data(title.utf8).write(to: url)
            return url
        }
        _ = try repo.importFiles(urls: urls, courseID: course.id, category: "课件", copy: false, folderID: second.id)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .course(course.id))
        let before = repo.state
        store.expandedMaterialFolderIDs = [website.id, handouts.id, second.id]
        #expect(store.materialBrowserRows.compactMap(\.folder).map(\.name) == ["教学网站", "课件"] + chapters)
        #expect(store.materialBrowserRows.compactMap(\.material).map(\.title) == titles)
        store.openMaterialFolder(handouts.id)
        #expect(store.materialBrowserRows.map(\.title) == chapters)
        #expect(store.currentMaterialFolders.map(\.name) == chapters)
        store.openMaterialFolder(second.id)
        #expect(store.materialBrowserRows.map(\.title) == titles)
        #expect(store.visibleMaterials.map(\.title) == titles)
        store.navigate(to: .all); store.sort = "名称"
        #expect(store.visibleMaterials.map(\.title) == titles)
        #expect(repo.state == before)
        try repo.setMaterialSort(.custom, courseID: course.id); store.reload()
        store.navigate(to: .course(course.id)); store.openMaterialFolder(second.id)
        #expect(store.materialBrowserRows.map(\.title) == titles)
    }

    @Test func defaultNamesApplyToExpandedAndEnteredFoldersAndDoNotJumpWhenChoosingCustom() throws {
        try fixture { store, course, outer, inner, earlierOuter, earlierInner, records in
            #expect(store.state.courses.first { $0.id == course.id }?.materialSort == nil)
            #expect(store.materialSortMode == .name)
            store.expandedMaterialFolderIDs = [outer.id, inner.id]
            let expected = [earlierOuter.id, outer.id, earlierInner.id, inner.id,
                            records[5].id, records[4].id, records[3].id, records[2].id,
                            records[1].id, records[0].id]
            #expect(store.materialBrowserRows.map(\.id) == expected)
            #expect(store.materialBrowserRows.map(\.depth) == [0, 0, 1, 1, 2, 2, 1, 1, 0, 0])
            #expect(store.visibleMaterials.map(\.id) == [records[1].id, records[0].id])

            try store.repository.setMaterialSort(.custom, courseID: course.id); store.reload()
            #expect(store.canReorderMaterials)
            #expect(store.materialBrowserRows.map(\.id) == expected)
            store.openMaterialFolder(outer.id)
            #expect(store.materialBrowserRows.map(\.id) == [earlierInner.id, inner.id, records[3].id, records[2].id])
            #expect(store.visibleMaterials.map(\.id) == [records[3].id, records[2].id])
            store.openMaterialFolder(inner.id)
            #expect(store.materialBrowserRows.map(\.id) == [records[5].id, records[4].id])
            #expect(store.visibleMaterials.map(\.id) == [records[5].id, records[4].id])
        }
    }

    @Test func explicitTimeAndCustomSortRemainAvailableAcrossFolderLevels() throws {
        try fixture { store, course, outer, inner, earlierOuter, earlierInner, records in
            try store.repository.setMaterialSort(.time, courseID: course.id); store.reload()
            store.expandedMaterialFolderIDs = [outer.id, inner.id]
            let timed = [earlierOuter.id, outer.id, earlierInner.id, inner.id,
                         records[4].id, records[5].id, records[2].id, records[3].id,
                         records[0].id, records[1].id]
            #expect(store.materialSortMode == .time)
            #expect(!store.canReorderMaterials)
            #expect(store.materialBrowserRows.map(\.id) == timed)
            try store.repository.setMaterialSort(.custom, courseID: course.id); store.reload()
            #expect(store.materialBrowserRows.map(\.id) == timed)
            store.reorderMaterials([records[5].id], before: records[4].id)
            let custom = store.materialBrowserRows.map(\.id)
            #expect(custom == [earlierOuter.id, outer.id, earlierInner.id, inner.id,
                              records[5].id, records[4].id, records[2].id, records[3].id,
                              records[0].id, records[1].id])
            let reopenedView = AppStore(repository: store.repository, remembersLocation: false)
            reopenedView.navigate(to: .course(course.id)); reopenedView.openMaterialFolder(inner.id)
            #expect(reopenedView.materialSortMode == .custom)
            #expect(reopenedView.materialBrowserRows.map(\.id) == [records[5].id, records[4].id])
        }
    }

    private func fixture(_ action: (AppStore, Course, MaterialFolder, MaterialFolder, MaterialFolder, MaterialFolder, [MaterialRecord]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-folder-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("library"))
        let course = Course(name: "默认排序")
        try repo.saveCourse(course)
        let names = ["根10.txt", "根2.txt", "章10.txt", "章2.txt", "练习10.txt", "练习2.txt"]
        let urls = try names.map { name -> URL in
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        _ = try repo.importFiles(urls: urls, courseID: course.id, category: "课件", copy: false)
        var records = try names.map { name in try #require(repo.state.materials.first { $0.originalName == name }) }
        for index in records.indices {
            records[index].addedAt = Date(timeIntervalSince1970: index.isMultiple(of: 2) ? 20 : 10)
            try repo.updateMaterial(records[index])
        }
        let outer = try repo.createMaterialFolder(name: "第10章", courseID: course.id, materialIDs: Set(records[2...3].map(\.id)))
        let inner = try repo.createMaterialFolder(name: "练习10", courseID: course.id, parentID: outer.id, materialIDs: Set(records[4...5].map(\.id)))
        let earlierOuter = try repo.createMaterialFolder(name: "第2章", courseID: course.id)
        let earlierInner = try repo.createMaterialFolder(name: "练习2", courseID: course.id, parentID: outer.id)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .course(course.id))
        try action(store, course, outer, inner, earlierOuter, earlierInner, records)
    }
}
