import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TeachshelfCore

extension UTType {
    static let teachshelfMaterial = UTType(exportedAs: "com.teachshelf.material-selection", conformingTo: .data)
}

struct MaterialDragPayload: Codable {
    let libraryPath: String
    let courseID: UUID
    let ids: [UUID]
}

extension AppStore {
    var materialSortMode: MaterialSortMode { state.courses.first { $0.id == currentCourseID }?.materialSort ?? .time }
    var canReorderMaterials: Bool { currentCourseID != nil && materialSortMode == .custom }
    var selectedVisibleMaterialIDs: Set<UUID> { selectedMaterialIDs.intersection(Set(visibleMaterials.map(\.id))) }
    var currentMaterialFolders: [MaterialFolder] {
        state.materialFolders.filter { $0.courseID == currentCourseID && $0.parentID == materialFolderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func openMaterialFolder(_ id: UUID?) {
        guard beforeLeavingMaterial?() != false else { return }
        materialFolderID = id; selectedMaterialIDs = []
    }
    func reorderMaterials(_ ids: Set<UUID>, before target: UUID?) {
        guard canReorderMaterials, let courseID = currentCourseID else { return }
        perform { try repository.reorderMaterials(ids: ids, before: target, courseID: courseID, folderID: materialFolderID); status = "资料顺序已保存" }
    }
    func materialDragData(_ ids: Set<UUID>) -> Data? {
        guard let courseID = currentCourseID else { return nil }
        return try? JSONEncoder().encode(MaterialDragPayload(libraryPath: repository.root.path, courseID: courseID, ids: Array(ids)))
    }
    func materialProvider(_ material: MaterialRecord) -> NSItemProvider {
        let provider = (try? repository.resolveURL(material)).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        let ids = selectedMaterialIDs.contains(material.id) ? selectedVisibleMaterialIDs : [material.id]
        if let data = materialDragData(ids) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.teachshelfMaterial.identifier, visibility: .ownProcess) { completion in
                completion(data, nil); return nil
            }
        }
        return provider
    }
    func acceptMaterialDrop(_ providers: [NSItemProvider], before target: UUID? = nil, into folderID: UUID? = nil, grouping: Bool = false) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.teachshelfMaterial.identifier) }
        guard !providers.isEmpty, let courseID = currentCourseID, grouping || canReorderMaterials else { return false }
        let root = repository.root
        let sourceFolderID = materialFolderID
        Task { @MainActor in
            var ids: Set<UUID> = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.teachshelfMaterial.identifier) { data, _ in continuation.resume(returning: data) }
                }
                guard let data, let payload = try? JSONDecoder().decode(MaterialDragPayload.self, from: data),
                      payload.libraryPath == root.path, payload.courseID == courseID else { return }
                ids.formUnion(payload.ids)
            }
            guard repository.root == root, currentCourseID == courseID, grouping || materialFolderID == sourceFolderID else { return }
            if grouping {
                perform { try repository.moveMaterials(ids: ids, to: folderID, courseID: courseID); selectedMaterialIDs.subtract(ids); status = "已移动 \(ids.count) 份资料" }
            } else { reorderMaterials(ids, before: target) }
        }
        return true
    }
    func exportMaterials(_ ids: Set<UUID>) {
        guard !ids.isEmpty, beforeLeavingMaterial?() != false else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = (currentCourseID.map(courseName) ?? "课程资料") + ".zip"
        panel.message = "导出所选 \(ids.count) 份资料，保留课程文件夹分组"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let repo = repository
        Task { await runOperation("正在生成 ZIP…") { try repo.exportMaterials(ids: ids, to: target); return "已导出 \(ids.count) 份资料到 \(target.lastPathComponent)" } }
    }
    func renameMaterialFolder(_ folder: MaterialFolder) {
        let alert = NSAlert(); alert.messageText = "重命名文件夹"
        let input = NSTextField(string: folder.name); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn { perform { try repository.renameMaterialFolder(id: folder.id, name: input.stringValue) } }
    }
    func dissolveMaterialFolder(_ folder: MaterialFolder) {
        let alert = NSAlert(); alert.messageText = "解散「\(folder.name)」？"
        alert.informativeText = "所有子文件夹中的资料移回上一级，文件和资料记录保留。"
        alert.addButton(withTitle: "解散文件夹"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { perform { try repository.dissolveMaterialFolder(id: folder.id); status = "文件夹已解散，资料已移回上一级" } }
    }
}

struct MaterialFolderRequest: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
    let parentID: UUID?
}

struct MaterialFolderSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let ids: Set<UUID>
    @ViewState private var creating: Bool
    @ViewState private var target: UUID?
    @ViewState private var name = ""
    init(ids: Set<UUID>, parentID: UUID?) {
        self.ids = ids; _target = State(initialValue: parentID); _creating = State(initialValue: ids.isEmpty)
    }
    private var options: [ChoiceOption<UUID?>] {
        [ChoiceOption(value: nil, title: "课程根目录")] + store.state.materialFolders.filter { $0.courseID == store.currentCourseID }.map {
            ChoiceOption(value: Optional($0.id), title: MaterialOrdering.folderPath($0.id, in: store.state.materialFolders).map(\.name).joined(separator: " / "))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(ids.isEmpty ? "新建文件夹" : "整理 \(ids.count) 份资料", systemImage: "folder.badge.plus").font(.title2.weight(.semibold))
            if !ids.isEmpty {
                Picker("整理方式", selection: $creating) { Text("已有文件夹").tag(false); Text("新建文件夹").tag(true) }.pickerStyle(.segmented)
            }
            if creating { TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("文件夹名称") }
            VStack(alignment: .leading, spacing: 6) {
                Text(creating ? "新建位置" : "目标文件夹").font(.caption).foregroundStyle(.secondary)
                SolidChoiceMenu("目标文件夹", selection: $target, options: options)
            }
            Text("分组随资料库保存，不改变原文件位置。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? (ids.isEmpty ? "新建" : "新建并移入") : "移入") { save() }
                    .appPrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(creating && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 420)
    }
    private func save() {
        guard let courseID = store.currentCourseID else { return }
        do {
            if creating { try store.repository.createMaterialFolder(name: name, courseID: courseID, parentID: target, materialIDs: ids) }
            else { try store.repository.moveMaterials(ids: ids, to: target, courseID: courseID) }
            store.selectedMaterialIDs = []; store.reload(); store.status = ids.isEmpty ? "文件夹已创建" : "已整理 \(ids.count) 份资料"
            dismiss()
        } catch { store.report(error) }
    }
}
