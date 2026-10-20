import Foundation
import TeachshelfCore

enum WorkspaceSearchKind: String, CaseIterable, Identifiable {
    case course = "课程", material = "资料", plan = "计划"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .course: return "books.vertical"
        case .material: return "doc"
        case .plan: return "calendar"
        }
    }
}

struct WorkspaceSearchResult: Identifiable, Equatable {
    let kind: WorkspaceSearchKind
    let recordID: UUID
    let title: String
    let detail: String
    let colorHex: String
    var id: String { "\(kind.rawValue)-\(recordID)" }
}

enum WorkspaceSearch {
    static func results(for query: String, in state: LibraryState, limitPerKind: Int = 6) -> [WorkspaceSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limitPerKind > 0 else { return [] }
        let courses = Dictionary(uniqueKeysWithValues: state.courses.map { ($0.id, $0) })
        func matches(_ parts: [String]) -> Bool {
            let text = parts.joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        func limited(_ results: [WorkspaceSearchResult]) -> [WorkspaceSearchResult] {
            Array(results.sorted {
                let firstExact = $0.title.localizedCaseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                let secondExact = $1.title.localizedCaseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                if firstExact != secondExact { return firstExact }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }.prefix(limitPerKind))
        }
        let courseResults = state.courses.compactMap { course -> WorkspaceSearchResult? in
            guard matches([course.name, course.teacher, course.semester]) else { return nil }
            return WorkspaceSearchResult(kind: .course, recordID: course.id, title: course.name,
                detail: [course.semester, course.teacher, course.isArchived ? "已归档" : ""].filter { !$0.isEmpty }.joined(separator: " · "), colorHex: course.colorHex)
        }
        let materialResults = state.materials.compactMap { material -> WorkspaceSearchResult? in
            let course = material.courseID.flatMap { courses[$0] }
            guard matches([material.title, material.originalName, material.tags, material.notes, material.category, course?.name ?? "未分类"]) else { return nil }
            return WorkspaceSearchResult(kind: .material, recordID: material.id, title: material.title,
                detail: "\(course?.name ?? "未分类") · \(material.category) · \(material.fileType)", colorHex: course?.colorHex ?? state.accentColor)
        }
        let planResults = state.tasks.compactMap { plan -> WorkspaceSearchResult? in
            let course = plan.courseID.flatMap { courses[$0] }
            guard matches([plan.title, plan.content, plan.kind, plan.location, course?.name ?? ""]) else { return nil }
            let status = plan.isArchived ? "已归档" : plan.isCancelled ? "已取消" : plan.isCompleted ? "已完成" : ""
            return WorkspaceSearchResult(kind: .plan, recordID: plan.id, title: plan.title,
                detail: [plan.kind, course?.name ?? "", status].filter { !$0.isEmpty }.joined(separator: " · "), colorHex: plan.colorHex ?? course?.colorHex ?? state.accentColor)
        }
        return limited(courseResults) + limited(materialResults) + limited(planResults)
    }
}

struct ToolbarPlanDraft: Identifiable {
    let task: StudyTask
    var isNew = false
    var id: UUID { task.id }
}

extension AppStore {
    func startToolbarPlan() {
        guard !isBusy, beforeLeavingMaterial?() != false else { return }
        let courseID = navigation == .schedule ? scheduleSelection.courseID : currentCourseID
        let date = navigation == .schedule ? scheduleSelection.selectedDate : Date()
        toolbarPlanDraft = ToolbarPlanDraft(task: StudyTask(title: "", kind: "自主规划", courseID: courseID,
            startsAt: date, hasExecutionTime: false, completionRequired: navigation == .tasks), isNew: true)
    }

    @discardableResult func activateSearchResult(_ result: WorkspaceSearchResult) -> Bool {
        guard !isBusy else { return false }
        // Resolve against live data: a result may outlive a deletion or a library switch.
        switch result.kind {
        case .course:
            guard let course = state.courses.first(where: { $0.id == result.recordID }), beforeLeavingMaterial?() != false else { return false }
            revealSearchLocation(WorkspaceLocation(page: .course(course.id)))
            if course.isArchived || courseArchiveFilter == "已归档课程" { courseArchiveFilter = "全部课程" }
            clearMaterialFilters()
        case .material:
            guard let material = state.materials.first(where: { $0.id == result.recordID }), beforeLeavingMaterial?() != false else { return false }
            revealSearchLocation(WorkspaceLocation(page: material.courseID.map(SidebarSelection.course) ?? .unassigned, folderID: material.folderID))
            if let course = state.courses.first(where: { $0.id == material.courseID }), course.isArchived || courseArchiveFilter == "已归档课程" { courseArchiveFilter = "全部课程" }
            if material.courseID == nil { semester = "全部学期" }
            clearMaterialFilters()
            selectedMaterialIDs = [material.id]
        case .plan:
            guard let plan = state.tasks.first(where: { $0.id == result.recordID }), beforeLeavingMaterial?() != false else { return false }
            toolbarPlanDraft = ToolbarPlanDraft(task: plan)
        }
        showingWorkspaceSearch = false; workspaceSearchQuery = ""
        return true
    }

    private func revealSearchLocation(_ location: WorkspaceLocation) {
        if workspaceLocation != location { navigationHistory.record(workspaceLocation) }
        applyWorkspaceLocation(location)
    }

    private func clearMaterialFilters() {
        search = ""; categoryFilter = "全部类别"; formatFilter = "全部格式"
    }
}
