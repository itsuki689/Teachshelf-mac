import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct WorkspaceSearchTests {
    @Test func searchMatchesMultipleWordsAcrossMetadataAndLimitsEachKindIndependently() {
        var state = LibraryState()
        let course = Course(name: "算法", semester: "2026 秋季", teacher: "陈老师")
        state.courses = [course]
        state.materials = (1...10).map { index in
            MaterialRecord(courseID: course.id, title: "第 \(index) 章", originalName: "\(index).pdf", sourcePath: "", storedPath: "", isManaged: false, tags: "复习", notes: "图论")
        }
        state.tasks = [StudyTask(title: "算法复习", content: "图论", location: "图书馆")]
        #expect(WorkspaceSearch.results(for: "  \n", in: state).isEmpty)
        #expect(WorkspaceSearch.results(for: "陈老师 秋季", in: state).map(\.recordID) == [course.id])
        let materials = WorkspaceSearch.results(for: "算法 复习", in: state).filter { $0.kind == .material }
        #expect(materials.count == 6)
        #expect(materials.map(\.title) == (1...6).map { "第 \($0) 章" })
        #expect(WorkspaceSearch.results(for: "图书馆 图论", in: state).map(\.kind) == [.plan])
        #expect(WorkspaceSearch.results(for: "算法", in: state, limitPerKind: 1).map(\.kind) == [.course, .material, .plan])
        #expect(WorkspaceSearch.results(for: "不匹配", in: state).isEmpty)
    }

    @Test func searchRevealsNestedFilesInArchivedCoursesAndClearsConflictingFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "算法", semester: "2025 秋季", isArchived: true)
        try repo.saveCourse(course)
        let folder = try repo.createMaterialFolder(name: "复习", courseID: course.id)
        let file = root.appendingPathComponent("图论.txt")
        try "资料".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.importFiles(urls: [file], courseID: course.id, category: "课件", copy: true)
        let material = try #require(repo.state.materials.first)
        try repo.moveMaterials(ids: [material.id], to: folder.id, courseID: course.id)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .settings)
        store.semester = "2026 秋季"; store.search = "不匹配"; store.categoryFilter = "教材"; store.formatFilter = "PDF"
        let result = try #require(WorkspaceSearch.results(for: "图论", in: store.state).first)
        #expect(store.activateSearchResult(result))
        #expect(store.navigation == .course(course.id))
        #expect(store.materialFolderID == folder.id)
        #expect(store.selectedMaterialIDs == [material.id])
        #expect(store.courseArchiveFilter == "全部课程")
        #expect(store.semester == course.semester)
        #expect(store.visibleMaterials.map(\.id) == [material.id])
        store.goBack()
        #expect(store.navigation == .settings)
    }

    @Test func unsavedEditsAndStaleResultsCannotChangeTheCurrentLocationOrFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-search-guard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "算法")
        try repo.saveCourse(course)
        let store = AppStore(repository: repo, remembersLocation: false)
        let result = try #require(WorkspaceSearch.results(for: "算法", in: store.state).first)
        store.search = "保留关键词"; store.workspaceSearchQuery = "保留搜索"
        store.beforeLeavingMaterial = { false }
        #expect(!store.activateSearchResult(result))
        #expect(store.navigation == .all && !store.canGoBack)
        #expect(store.search == "保留关键词" && store.workspaceSearchQuery == "保留搜索")
        store.startToolbarPlan()
        #expect(store.toolbarPlanDraft == nil)
        store.beforeLeavingMaterial = nil
        try repo.deleteCourse(id: course.id); store.reload()
        #expect(!store.activateSearchResult(result))
        #expect(store.navigation == .all && !store.canGoBack)
    }

    @Test func unassignedFilesAndActiveCoursesRemainVisibleDespitePreviousSemesterAndArchiveFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-search-filters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "当前课程", semester: "2026 秋季")
        try repo.saveCourse(course)
        let file = root.appendingPathComponent("公共笔记.txt")
        try "资料".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.importFiles(urls: [file], courseID: nil, category: "笔记", copy: true)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.courseArchiveFilter = "已归档课程"
        store.semester = "2025 秋季"
        let courseResult = try #require(WorkspaceSearch.results(for: "当前课程", in: store.state).first)
        #expect(store.activateSearchResult(courseResult))
        #expect(store.sidebarCourses.map(\.id) == [course.id])
        let materialResult = try #require(WorkspaceSearch.results(for: "公共笔记", in: store.state).first)
        #expect(store.activateSearchResult(materialResult))
        #expect(store.navigation == .unassigned && store.semester == "全部学期")
        #expect(store.visibleMaterials.map(\.id) == [materialResult.recordID])
        #expect(store.selectedMaterialIDs == [materialResult.recordID])
    }

    @Test func existingPlansOpenWithoutLosingTheirIdentityAndQuickCreateUsesTheCurrentContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-search-plan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "算法")
        try repo.saveCourse(course)
        let archived = StudyTask(title: "整理算法笔记", completedAt: Date().addingTimeInterval(-60), archivedAt: Date())
        try repo.saveTask(archived)
        let store = AppStore(repository: repo, remembersLocation: false)
        let result = try #require(WorkspaceSearch.results(for: "算法笔记", in: store.state).first)
        #expect(result.detail.contains("已归档"))
        #expect(store.activateSearchResult(result))
        #expect(store.toolbarPlanDraft?.task == archived)
        #expect(store.toolbarPlanDraft?.isNew == false)
        #expect(store.state.tasks.count == 1)
        store.toolbarPlanDraft = nil
        store.navigate(to: .course(course.id)); store.startToolbarPlan()
        #expect(store.toolbarPlanDraft?.task.courseID == course.id)
        #expect(store.toolbarPlanDraft?.isNew == true)
        #expect(store.toolbarPlanDraft?.task.hasExecutionTime == false)
        store.toolbarPlanDraft = nil
        store.navigate(to: .tasks); store.startToolbarPlan()
        #expect(store.toolbarPlanDraft?.task.completionRequired == true)
    }
}
