import Foundation

struct WorkspaceLocation: Equatable {
    let page: SidebarSelection?
    var folderID: UUID?
}

/// Session-only history. A folder is part of a location, not a separate page.
struct WorkspaceNavigationHistory {
    private(set) var back: [WorkspaceLocation] = []
    private(set) var forward: [WorkspaceLocation] = []

    mutating func record(_ location: WorkspaceLocation) {
        if back.last != location { back.append(location) }
        if back.count > 60 { back.removeFirst(back.count - 60) }
        forward = []
    }

    mutating func step(backwards: Bool, from current: WorkspaceLocation) -> WorkspaceLocation? {
        if backwards {
            guard let previous = back.popLast() else { return nil }
            forward.append(current)
            return previous
        }
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        return next
    }

    mutating func removeInvalidLocations(where isValid: (WorkspaceLocation) -> Bool) {
        back.removeAll { !isValid($0) }
        forward.removeAll { !isValid($0) }
    }
}

extension AppStore {
    var canGoBack: Bool { !navigationHistory.back.isEmpty }
    var canGoForward: Bool { !navigationHistory.forward.isEmpty }
    var workspaceLocation: WorkspaceLocation { WorkspaceLocation(page: navigation, folderID: materialFolderID) }

    func goBack() { stepHistory(backwards: true) }
    func goForward() { stepHistory(backwards: false) }

    private func stepHistory(backwards: Bool) {
        guard (backwards ? canGoBack : canGoForward), beforeLeavingMaterial?() != false else { return }
        guard let destination = navigationHistory.step(backwards: backwards, from: workspaceLocation) else { return }
        applyWorkspaceLocation(destination)
    }

    func applyWorkspaceLocation(_ location: WorkspaceLocation) {
        if case .course(let id) = location.page {
            workspaceCourseID = id
            if semester != "全部学期", let course = state.courses.first(where: { $0.id == id }), course.semester != semester {
                semester = course.semester.isEmpty ? "全部学期" : course.semester
            }
        }
        navigation = location.page
        materialFolderID = location.folderID
        expandedMaterialFolderIDs = []
        materialEditing = false
        selectedMaterialIDs = []
    }

    func reconcileNavigationHistory() {
        let courses = Set(state.courses.map(\.id))
        let folders = state.materialFolders
        navigationHistory.removeInvalidLocations { location in
            if case .course(let id) = location.page {
                guard courses.contains(id) else { return false }
                return location.folderID == nil || folders.contains { $0.id == location.folderID && $0.courseID == id }
            }
            if location.page == .unassigned { return location.folderID == nil || folders.contains { $0.id == location.folderID && $0.courseID == nil } }
            return location.folderID == nil
        }
    }
}
