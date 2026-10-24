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
    var materialSortMode: MaterialSortMode { state.courses.first { $0.id == currentCourseID }?.materialSort ?? .name }
    var canReorderMaterials: Bool { currentCourseID != nil && materialSortMode == .custom }
    var selectedVisibleMaterialIDs: Set<UUID> { selectedMaterialIDs.intersection(materialBrowserSelectableIDs) }
    var currentMaterialFolders: [MaterialFolder] {
        MaterialOrdering.sortedFolders(state.materialFolders.filter { $0.courseID == currentCourseID && $0.parentID == materialFolderID })
    }

    func openMaterialFolder(_ id: UUID?) {
        guard id != materialFolderID else { return }
        guard beforeLeavingMaterial?() != false else { return }
        navigationHistory.record(workspaceLocation)
        materialFolderID = id; selectedMaterialIDs = []; expandedMaterialFolderIDs = []
    }

    func revealMaterialFolder(_ folder: MaterialFolder) {
        guard !isBusy else { return }
        do {
            let urls = try repository.materialFolderRevealURLs(id: folder.id)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch { report(error) }
    }

    func reorderMaterials(_ ids: Set<UUID>, before target: UUID?) {
        guard canReorderMaterials, let courseID = currentCourseID else { return }
        let records = state.materials.filter { ids.contains($0.id) }
        guard let first = records.first, records.allSatisfy({ $0.courseID == courseID && $0.folderID == first.folderID }) else { return }
        perform { try repository.reorderMaterials(ids: ids, before: target, courseID: courseID, folderID: first.folderID); status = "资料顺序已保存" }
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
        }.sorted { MaterialOrdering.compareNames($0.title, $1.title) == .orderedAscending }
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
            Text("文件夹对应资料库中的真实目录，移动库内资料会同步移动文件。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? (ids.isEmpty ? "新建" : "新建并移入") : "移入") { save() }
                    .appPrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(creating && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 420)
            .onAppear { store.materialFolderSheetCount += 1 }
            .onDisappear { store.materialFolderSheetCount = max(0, store.materialFolderSheetCount - 1) }
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

struct MaterialFolderEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let folder: MaterialFolder
    @ViewState private var name: String
    @ViewState private var color: Color
    @ViewState private var customColor: Bool
    init(folder: MaterialFolder, inheritedColor: Color) {
        self.folder = folder
        _name = State(initialValue: folder.name)
        _color = State(initialValue: folder.colorHex.map { Color(hex: $0) } ?? inheritedColor)
        _customColor = State(initialValue: folder.colorHex != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("编辑文件夹", systemImage: "folder.fill").font(.title2.weight(.semibold)).foregroundStyle(color)
            TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("文件夹名称")
            ColorPicker("文件夹颜色", selection: Binding(get: { color }, set: { color = $0; customColor = true }), supportsOpacity: false)
            HStack(spacing: 10) {
                ForEach(ColorPalette.themes, id: \.hex) { choice in
                    Button { color = Color(hex: choice.hex); customColor = true } label: {
                        Circle().fill(Color(hex: choice.hex)).frame(width: 19, height: 19)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(color.hexString == choice.hex ? 0.8 : 0), lineWidth: 2).padding(-3) }
                    }.buttonStyle(.plain).help(choice.name).accessibilityLabel("文件夹颜色：\(choice.name)")
                }
            }
            Button("跟随课程颜色") { color = store.courseColor(folder.courseID); customColor = false }.buttonStyle(.plain).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.appPrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 420).dismissColorPanelAutomatically()
            .onAppear { store.editingFolderCounts[folder.id, default: 0] += 1 }
            .onDisappear {
                let count = (store.editingFolderCounts[folder.id] ?? 1) - 1
                store.editingFolderCounts[folder.id] = count > 0 ? count : nil
            }
    }
    private func save() {
        do {
            try store.repository.updateMaterialFolder(id: folder.id, name: name, colorHex: customColor ? color.hexString : nil)
            store.reload(); store.status = "文件夹已保存"; dismiss()
        } catch { store.report(error) }
    }
}
