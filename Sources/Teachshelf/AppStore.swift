import AppKit
import SwiftUI
import TeachshelfCore

enum SidebarSelection: Hashable {
    case all, favorites, recent, unassigned, course(UUID), homework, tasks, schedule, settings
    var isLibrary: Bool {
        switch self { case .all, .favorites, .recent, .unassigned, .course: return true; default: return false }
    }
}

private struct TimetableUndo {
    let root: URL
    let before: TimetableTerm
    let after: TimetableTerm?
    let label: String
}

private struct PlanUndo {
    let root: URL
    let before: [StudyTask]
    let after: [StudyTask]
    let label: String
    var ids: Set<UUID> { Set((before + after).map(\.id)) }
}

@MainActor final class AppStore: ObservableObject {
    @Published var state: LibraryState
    @Published var repository: LibraryRepository
    let appearancePreference: AppearancePreference
    @Published var navigation: SidebarSelection? = .all
    @Published var navigationHistory = WorkspaceNavigationHistory()
    @Published var selectedMaterialIDs: Set<UUID> = []
    @Published var search = ""
    @Published var categoryFilter = "全部类别"
    @Published var formatFilter = "全部格式"
    @Published var sort = "最近添加"
    @Published var materialEditing = false
    @Published var materialFolderID: UUID?
    @Published var expandedMaterialFolderIDs: Set<UUID> = []
    @Published var semester = "全部学期"
    @Published var courseArchiveFilter = "当前课程"
    @Published var workspaceCourseID: UUID?
    private var workspaceCourseInitialized = false
    @Published var isBusy = false
    @Published var canUndoTaskDeletion = false
    @Published var status = "就绪"
    @Published var errorMessage: String?
    @Published var showingImport = false
    @Published var importURLs: [URL] = []
    @Published var courseToEdit: Course?
    @Published var showingCourseEditor = false
    @Published var showingTeachingWebsite = false
    @Published var teachingConnectionToOpen: UUID?
    @Published var teachingUpdateAll = false
    private var teachingSession: TeachingWebsiteController?
    private var teachingSessionRoot: URL?

    func flushTeachingLogin() async { await teachingSession?.client.loginSession.saveNow() }

    func teachingWebsiteSession() -> TeachingWebsiteController {
        if let teachingSession, teachingSessionRoot == repository.root { return teachingSession }
        teachingSession?.close()
        let value = TeachingWebsiteController(root: repository.root)
        teachingSession = value; teachingSessionRoot = repository.root
        return value
    }
    @Published var showingWorkspaceSearch = false
    @Published var workspaceSearchQuery = ""
    @Published var toolbarPlanDraft: ToolbarPlanDraft?
    @Published private(set) var previewAccentHex: String?
    @Published private(set) var accentPreviewID: UUID?
    let scheduleSelection = ScheduleSelection()
    @Published private var timetableUndo: TimetableUndo?
    @Published private var planUndo: PlanUndo?
    private let remembersLocation: Bool
    var beforeLeavingMaterial: (() -> Bool)?

    var effectiveAccentHex: String { previewAccentHex ?? state.accentColor }

    var canUndoTimetableChange: Bool {
        guard let undo = timetableUndo, undo.root == repository.root else { return false }
        return state.timetableTerms.first(where: { $0.id == undo.before.id }) == undo.after
    }
    var timetableUndoLabel: String? { canUndoTimetableChange ? timetableUndo?.label : nil }

    var canUndoPlanChange: Bool {
        guard let undo = planUndo, undo.root == repository.root else { return false }
        return Set(state.tasks.filter { undo.ids.contains($0.id) }) == Set(undo.after)
    }
    var planUndoLabel: String? { canUndoPlanChange ? planUndo?.label : nil }

    @discardableResult
    func changePlan(id: UUID, label: String, action: (LibraryRepository) throws -> Void) -> Bool {
        guard !isBusy else { return false }
        let before = state.tasks
        do {
            try action(repository)
            reload()
            let ids = Set((before + state.tasks).map(\.id)).filter { id in
                before.first { $0.id == id } != state.tasks.first { $0.id == id }
            }
            if !ids.isEmpty {
                planUndo = PlanUndo(root: repository.root, before: before.filter { ids.contains($0.id) },
                                    after: state.tasks.filter { ids.contains($0.id) }, label: label)
            }
            status = label
            return true
        } catch { report(error); return false }
    }

    func undoPlanChange() {
        guard !isBusy, canUndoPlanChange, let undo = planUndo else { return }
        do {
            try repository.restorePlanChanges(before: undo.before, after: undo.after)
            planUndo = nil
            reload(); status = "已撤销\(undo.label)"
        } catch { report(error) }
    }

    @discardableResult
    func changeTimetable(termID: UUID, label: String, action: (LibraryRepository) throws -> Void) -> Bool {
        guard !isBusy, let before = state.timetableTerms.first(where: { $0.id == termID }) else { return false }
        do {
            try action(repository)
            let after = repository.state.timetableTerms.first(where: { $0.id == termID })
            reload()
            if before != after { timetableUndo = TimetableUndo(root: repository.root, before: before, after: after, label: label) }
            status = label
            return true
        } catch { report(error); return false }
    }

    func undoTimetableChange() {
        guard !isBusy, canUndoTimetableChange, let undo = timetableUndo else { return }
        do {
            try repository.saveTimetableTerm(undo.before)
            timetableUndo = nil
            reload(); status = "已撤销\(undo.label)"
        } catch { report(error) }
    }

    func beginAccentPreview() -> UUID? {
        guard !isBusy, accentPreviewID == nil else { return nil }
        let id = UUID()
        accentPreviewID = id; previewAccentHex = state.accentColor
        return id
    }

    func previewAccent(_ hex: String, sessionID: UUID) {
        guard accentPreviewID == sessionID, let color = RGBColor(hex: hex) else { return }
        previewAccentHex = color.hex
    }

    func cancelAccentPreview(sessionID: UUID) {
        guard accentPreviewID == sessionID else { return }
        previewAccentHex = nil; accentPreviewID = nil
    }

    func saveAccentPreview(sessionID: UUID) -> Bool {
        guard !isBusy, accentPreviewID == sessionID, let hex = previewAccentHex else { return false }
        do {
            try repository.saveAccentColor(hex)
            reload(); cancelAccentPreview(sessionID: sessionID)
            status = "强调色已保存"
            return true
        } catch { report(error); return false }
    }

    func navigate(to destination: SidebarSelection?) {
        guard destination != navigation else { return }
        guard beforeLeavingMaterial?() != false else { return }
        navigationHistory.record(workspaceLocation)
        applyWorkspaceLocation(WorkspaceLocation(page: destination))
    }

    func prepareWorkspaceCourse() -> UUID? {
        if !workspaceCourseInitialized {
            workspaceCourseInitialized = true
            workspaceCourseID = workspaceCourseID ?? state.courses.first(where: { !$0.isArchived })?.id
        }
        return workspaceCourseID
    }

    func selectWorkspaceCourse(_ id: UUID?) {
        workspaceCourseInitialized = true
        workspaceCourseID = id
    }
    func selectMaterials(_ ids: Set<UUID>) {
        if let current = selectedMaterial?.id, !ids.contains(current), beforeLeavingMaterial?() == false { return }
        selectedMaterialIDs = ids
    }

    init(repository: LibraryRepository, remembersLocation: Bool = true) {
        self.repository = repository
        let state = repository.state
        self.state = state
        self.appearancePreference = AppearancePreference(mode: state.appearance)
        self.canUndoTaskDeletion = repository.canUndoTaskDeletion
        self.remembersLocation = remembersLocation
        scheduleSelection.reconcile(state)
    }

    static func bootstrap() -> AppStore {
        let args = CommandLine.arguments
        let override = args.firstIndex(of: "--data-dir").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let remembered = UserDefaults.standard.string(forKey: "libraryPath")
        var root = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? remembered.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Teachshelf", isDirectory: true)
        var mustExist = override == nil && remembered != nil
        while true {
            do {
                if mustExist && !FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path) {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "记住的资料库不可用，请连接磁盘或选择已有资料库。"])
                }
                return AppStore(repository: try LibraryRepository(root: root), remembersLocation: override == nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法打开资料库"
                alert.informativeText = "\(root.path)\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "选择已有资料库")
                alert.addButton(withTitle: "退出")
                guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.message = "选择包含 library.json 的资料库文件夹"
                guard panel.runModal() == .OK, let chosen = panel.url else { exit(1) }
                root = chosen; mustExist = true
            }
        }
    }

    var currentCourseID: UUID? { if case .course(let id) = navigation { return id }; return nil }
    var selectedMaterial: MaterialRecord? { state.materials.first { selectedMaterialIDs.contains($0.id) } }
    var pendingTaskCount: Int {
        state.tasks.filter { parent in
            guard !parent.isArchived, !parent.isCancelled else { return false }
            let variants = [parent] + parent.exceptions.map { PlanCalendar.snapshot(of: parent, originalDate: $0.originalDate) }
            return variants.contains { $0.completionRequired && !$0.isCompleted && !$0.isCancelled }
        }.count
    }
    var categories: [String] { Array(Set(["课件", "教材", "笔记", "参考资料", "其他"] + state.customCategories + state.materials.map(\.category))).sorted() }
    var fileTypes: [String] { ["全部格式"] + Array(Set(["PDF", "文档", "演示文稿", "表格", "图片"] + state.materials.map(\.fileType))).sorted() }
    var semesters: [String] { ["全部学期"] + Array(Set(state.courses.map(\.semester).filter { !$0.isEmpty })).sorted().reversed() }
    var sidebarCourses: [Course] {
        state.courses.filter {
            (semester == "全部学期" || $0.semester == semester) &&
            (courseArchiveFilter == "全部课程" || $0.isArchived == (courseArchiveFilter == "已归档课程"))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var title: String {
        switch navigation {
        case .favorites: return "我的收藏"
        case .recent: return "最近打开"
        case .unassigned: return "未分类"
        case .course(let id): return courseName(id)
        case .homework: return "作业文件夹"
        case .tasks: return "待完成计划"
        case .schedule: return "计划"
        case .settings: return "设置"
        default: return "全部资料"
        }
    }
    var filteredMaterials: [MaterialRecord] {
        let words = search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var items = state.materials.filter { material in
            switch navigation {
            case .favorites: if !material.isFavorite { return false }
            case .recent: if material.lastOpenedAt == nil { return false }
            case .unassigned: if material.courseID != nil { return false }
            case .course(let id): if material.courseID != id { return false }
            default: break
            }
            if semester != "全部学期" && !state.courses.contains(where: { $0.id == material.courseID && $0.semester == semester }) { return false }
            if categoryFilter != "全部类别" && material.category != categoryFilter { return false }
            if formatFilter != "全部格式" && material.fileType != formatFilter { return false }
            let text = [material.title, material.originalName, material.tags, material.notes, courseName(material.courseID)].joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        if let id = currentCourseID {
            return MaterialOrdering.sorted(items, by: state.courses.first { $0.id == id }?.materialSort ?? .name)
        }
        items.sort {
            switch sort {
            case "名称": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case "文件大小": return $0.size > $1.size
            case "最近打开": return ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
            default: return navigation == .recent ? ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) : $0.addedAt > $1.addedAt
            }
        }
        return items
    }
    var visibleMaterials: [MaterialRecord] {
        filteredMaterials.filter { currentCourseID == nil || $0.folderID == materialFolderID }
    }
    func courseName(_ id: UUID?) -> String { state.courses.first { $0.id == id }?.name ?? "未分类" }
    func courseColor(_ id: UUID?) -> Color { Color(hex: state.courses.first { $0.id == id }?.colorHex ?? "#39786B") }
    func reload() {
        var next = repository.state
        // Another edit may reload a saved intermediate click while a newer target is queued.
        if appearancePreference.isSaving { next.appearance = state.appearance }
        state = next
        appearancePreference.synchronize(state.appearance)
        scheduleSelection.reconcile(state)
        canUndoTaskDeletion = repository.canUndoTaskDeletion
        selectedMaterialIDs.formIntersection(Set(state.materials.map(\.id)))
        if !fileTypes.contains(formatFilter) { formatFilter = "全部格式" }
        if categoryFilter != "全部类别", !categories.contains(categoryFilter) { categoryFilter = "全部类别" }
        if let id = workspaceCourseID, !state.courses.contains(where: { $0.id == id }) { workspaceCourseID = nil }
        if let id = currentCourseID, !state.courses.contains(where: { $0.id == id }) { navigation = .unassigned; selectedMaterialIDs = [] }
        expandedMaterialFolderIDs.formIntersection(Set(state.materialFolders.map(\.id)))
        if let id = materialFolderID, !state.materialFolders.contains(where: { $0.id == id && $0.courseID == currentCourseID }) { materialFolderID = nil }
        reconcileNavigationHistory()
    }
    func report(_ error: Error) {
        status = "操作未完成"
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
    func perform(_ action: () throws -> Void) { guard !isBusy else { return }; do { try action(); reload() } catch { report(error) } }
    func requestAppearance(_ value: String) {
        guard !isBusy else { return }
        let repository = repository
        appearancePreference.request(value, save: { try repository.saveAppearance($0) }, didSave: { [weak self] mode in
            guard let self, self.repository === repository else { return }
            // Only the theme changed. Do not rebuild file selection, filtering or navigation.
            if self.state.appearance != mode { self.state.appearance = mode }
        }, didFail: { [weak self] error in
            guard let self, self.repository === repository else { return }
            // A prior queued click may have committed before the final write failed.
            let savedMode = self.appearancePreference.mode
            if self.state.appearance != savedMode { self.state.appearance = savedMode }
            self.report(error)
        })
    }
    func flushAppearance() async { await appearancePreference.flush() }
    func runOperation(_ label: String, operation: @escaping @Sendable () throws -> String) async {
        guard !isBusy else { return }
        isBusy = true; status = label
        defer { isBusy = false }
        await flushAppearance()
        do { status = try await Task.detached(priority: .userInitiated, operation: operation).value; reload() }
        catch { report(error) }
    }
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择资料文件或文件夹"
        if panel.runModal() == .OK { importURLs = panel.urls; showingImport = true }
    }
    func importMaterials(urls: [URL], courseID: UUID?, category: String, copy: Bool) async {
        let repo = repository
        let folderID = courseID == currentCourseID ? materialFolderID : nil
        await runOperation("正在导入资料…") {
            let result = try repo.importFiles(urls: urls, courseID: courseID, category: category, copy: copy, folderID: folderID)
            return "新增 \(result.imported) 份，跳过 \(result.skipped) 份" + (result.errors.isEmpty ? "" : " · " + result.errors.joined(separator: "；"))
        }
    }
    func openURL(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { report(CocoaError(.fileReadNoSuchFile)); return }
        if !NSWorkspace.shared.open(url) { errorMessage = "无法打开文件，请确认已安装支持此格式的应用。" }
    }
    func revealURL(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openMaterial(_ material: MaterialRecord) {
        do {
            let url = try repository.resolveURL(material)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            if NSWorkspace.shared.open(url) { try repository.recordOpen(id: material.id); reload(); status = "已在默认应用中打开" }
            else { errorMessage = "找不到可打开该文件的应用。" }
        } catch { report(error) }
    }
    func favorite(_ material: MaterialRecord) { perform { try repository.setFavorite(id: material.id, favorite: !material.isFavorite) } }
    func removeMaterials(_ ids: Set<UUID>) {
        guard !ids.isEmpty, beforeLeavingMaterial?() != false else { return }
        let managed = state.materials.filter { ids.contains($0.id) && $0.isManaged }.count
        let alert = NSAlert(); alert.messageText = "删除 \(ids.count) 份资料？"
        alert.informativeText = "\(managed) 份库内副本可移到废纸篓。原始文件与外部引用文件保留；关联计划将解除与这些资料的关联。"
        if managed > 0 { alert.addButton(withTitle: "移到废纸篓") }
        alert.addButton(withTitle: "仅移除记录"); alert.addButton(withTitle: "取消")
        let result = alert.runModal()
        if managed > 0 && result == .alertFirstButtonReturn { perform { try repository.trashMaterials(ids: ids); status = "已删除 \(ids.count) 份资料，库内副本可从废纸篓找回" } }
        else if result == (managed > 0 ? .alertSecondButtonReturn : .alertFirstButtonReturn) { perform { try repository.removeMaterials(ids: ids); status = "已移除 \(ids.count) 份资料记录，文件保留" } }
    }
    func saveTask(_ task: StudyTask) { perform { try repository.saveTask(task); status = "待办已保存" } }
    func setTaskCompleted(_ task: StudyTask) { perform { try repository.setTaskCompleted(id: task.id, completed: !task.isCompleted) } }
    func archiveTask(_ task: StudyTask) { perform { try repository.archiveTask(id: task.id) } }
    func restoreTask(_ task: StudyTask) { perform { try repository.restoreTask(id: task.id) } }
    func deleteTasks(_ ids: Set<UUID>) { perform { try repository.deleteTasks(ids: ids); status = "待办已删除，可撤销" } }
    func undoTaskDeletion() { perform { try repository.undoTaskDeletion() } }

    func changeLibrary(to target: URL, migrate: Bool) async {
        guard !isBusy else { return }
        isBusy = true; status = migrate ? "正在迁移资料库…" : "正在打开资料库…"
        defer { isBusy = false }
        await flushAppearance()
        let previous = repository
        do {
            let next = try await Task.detached(priority: .userInitiated) {
                if migrate { try previous.copyLibrary(to: target) }
                else if !FileManager.default.fileExists(atPath: target.appendingPathComponent("library.json").path) { throw CocoaError(.fileReadNoSuchFile) }
                return try LibraryRepository(root: target)
            }.value
            if remembersLocation { UserDefaults.standard.set(target.path, forKey: "libraryPath") }
            if let id = accentPreviewID { cancelAccentPreview(sessionID: id) }
            repository = next; selectedMaterialIDs = []; materialFolderID = nil; expandedMaterialFolderIDs = []; materialEditing = false; workspaceCourseID = nil; workspaceCourseInitialized = false; search = ""; semester = "全部学期"; categoryFilter = "全部类别"; formatFilter = "全部格式"; navigation = .all
            navigationHistory = WorkspaceNavigationHistory()
            showingWorkspaceSearch = false; workspaceSearchQuery = ""; toolbarPlanDraft = nil
            reload(); status = "已切换资料库，原目录保留"
        } catch { report(error) }
    }
}
