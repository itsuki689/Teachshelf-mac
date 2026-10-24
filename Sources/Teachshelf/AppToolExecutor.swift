import Foundation
import TeachshelfCore

/// One execution boundary for external MCP and the in-app assistant.
@MainActor final class AppToolExecutor {
    private weak var store: AppStore?
    private var service: PlanMCPService?
    private var libraryService: LibraryMCPService?
    init(store: AppStore) { self.store = store }

    func affectedPlanIDs(name: String, arguments: [String: Any]) -> Set<UUID> {
        guard let store, service?.repository === store.repository else { return [] }
        return service?.affectedIDs(name: name, arguments: arguments) ?? []
    }

    func call(name: String, arguments: [String: Any], source: String = "MCP",
              expectedRepository: LibraryRepository? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let store, expectedRepository == nil || store.repository === expectedRepository else {
            throw PlanMCPError("资料库已切换，请开始新对话。")
        }
        guard !store.isBusy else { throw PlanMCPError("课屿正在保存或切换资料库，请稍后重试。") }
        let repository = store.repository
        if service?.repository !== repository { service = PlanMCPService(repository: repository) }
        if libraryService?.repository !== repository { libraryService = LibraryMCPService(repository: repository) }
        let service = service!, libraryService = libraryService!
        let isLibrary = LibraryMCPTools.names.contains(name), writes = TeachshelfMCPTools.writeNames.contains(name)
        if writes {
            if isLibrary {
                guard !store.showingCourseEditor, !store.showingImport, !store.showingTeachingWebsite,
                      store.editingMaterialCounts.isEmpty, store.editingFolderCounts.isEmpty, store.editingPlanCounts.isEmpty,
                      store.materialFolderSheetCount == 0,
                      store.toolbarPlanDraft == nil else { throw PlanMCPError("请先保存并关闭课程、资料、文件夹或计划编辑窗口，再执行课程资料修改。") }
            } else {
                guard service.affectedIDs(name: name, arguments: arguments).isDisjoint(with: Set(store.editingPlanCounts.keys)) else { throw PlanMCPError("该计划正在课屿编辑窗口中打开，请先保存或关闭编辑窗口后重试。") }
            }
        }
        let before = store.repository.state.tasks
        // Physical directory transactions run off the main actor; busy serializes UI/MCP writes.
        store.isBusy = true
        defer { store.isBusy = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                if isLibrary { return try libraryService.call(name: name, arguments: arguments) }
                var result = try service.call(name: name, arguments: arguments)
                if name == "teachshelf_context" { result.merge(try libraryService.context()) { _, value in value } }
                return result
            }.value
            store.reload()
            if writes, result["changed"] as? Bool == true {
                if !isLibrary { store.recordPlanChange(before: before, label: "\(source) 修改计划") }
                store.status = isLibrary ? "\(source) 课程资料修改已保存" : "\(source) 修改已保存，可撤销"
            }
            return result
        } catch { store.reload(); throw error }
    }
}
