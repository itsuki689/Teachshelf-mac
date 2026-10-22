import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore

struct LibraryWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("libraryPresentation") private var presentation = "list"
    @ViewState private var dropTarget = false
    @ViewState private var showInspector = true
    @ViewState private var showingCoursePlans = false
    @ViewState private var folderRequest: MaterialFolderRequest?
    @ViewState private var folderToEdit: MaterialFolder?
    @ViewState private var reorderTargetID: UUID?
    private var rows: [MaterialBrowserRow] { store.materialBrowserRows }
    private var items: [MaterialRecord] { rows.compactMap(\.material) }
    private var inspectorVisible: Bool { showInspector && !store.materialEditing && store.selectedMaterialIDs.count == 1 }
    private var hasMaterialFilters: Bool { !store.search.isEmpty || store.categoryFilter != "全部类别" || store.formatFilter != "全部格式" }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            if store.currentCourseID != nil { folderNavigation }
            if let courseID = store.currentCourseID {
                let tasks = store.state.tasks.filter { $0.courseID == courseID && $0.completionRequired && !$0.isArchived && !$0.isCompleted && $0.cancelledAt == nil }
                if !tasks.isEmpty {
                    HStack(spacing: 12) {
                        Label("\(tasks.count) 个待完成计划", systemImage: "checklist").font(.caption.weight(.medium)).foregroundStyle(.primary)
                        Text(tasks.prefix(2).map(\.title).joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("查看计划") { showingCoursePlans = true }.buttonStyle(.plain).foregroundStyle(theme.ink).font(.caption)
                    }.padding(.horizontal, 24).padding(.vertical, 10).background(theme.ink.opacity(0.06))
                }
            }
            Divider()
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Group {
                        if rows.isEmpty {
                            VStack(spacing: 0) {
                                EmptyStateView(symbol: hasMaterialFilters ? "magnifyingglass" : "folder", title: hasMaterialFilters ? "没有匹配的资料" : (store.materialFolderID != nil ? "文件夹里还没有资料" : "这里还没有资料"), detail: hasMaterialFilters ? "尝试其他关键词，或清除类别与格式筛选。" : "导入资料，或将文件拖到这里；也可打开上方文件夹查看。")
                                Button(hasMaterialFilters ? "清除筛选" : "导入资料") {
                                    if hasMaterialFilters { store.search = ""; store.categoryFilter = "全部类别"; store.formatFilter = "全部格式" }
                                    else { store.chooseImport() }
                                }.appPrimaryButton().padding(.bottom, 100)
                            }
                        } else if presentation == "covers" { coverGrid }
                        else { materialTable }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                    // Animate only the drawer, on a fixed canvas at the right edge.
                    // The material table keeps its viewport and scroll position.
                    ZStack(alignment: .trailing) {
                        if inspectorVisible, let material = store.selectedMaterial {
                            MaterialInspector(material: material).id(material.id)
                                .frame(width: min(320, geometry.size.width * 0.44), height: geometry.size.height)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
                                .shadow(color: .black.opacity(theme.isDark ? 0.22 : 0.08), radius: 12, x: -4, y: 0)
                                .transition(.offset(x: min(320, geometry.size.width * 0.44)))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: inspectorVisible)
                    .zIndex(1)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).fill(theme.selection).overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                }.padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.teachshelfMaterial, .fileURL], isTargeted: $dropTarget) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.teachshelfMaterial.identifier) }) {
                return store.acceptMaterialDrop(providers)
            }
            FileDropLoader.load(providers) { urls in store.importURLs = urls; store.showingImport = !urls.isEmpty }
            return true
        }
        .onChange(of: store.selectedMaterialIDs) { _, ids in if !ids.isEmpty { showInspector = true } }
        .sheet(isPresented: $showingCoursePlans) {
            PlanListSheet(courseID: store.currentCourseID, pendingOnly: true)
        }
        .sheet(item: $folderToEdit) { folder in MaterialFolderEditor(folder: folder, inheritedColor: store.courseColor(folder.courseID)).environmentObject(store) }
        .sheet(item: $folderRequest) { request in MaterialFolderSheet(ids: request.ids, parentID: request.parentID).environmentObject(store) }
    }

    private var subtitle: String {
        if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
            return [course.semester, course.teacher, course.isArchived ? "已归档" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return "课件、教材与灵感，井然有序。"
    }

    private var commandBar: some View {
        WorkspaceCommandBar(title: store.title, subtitle: subtitle, countLabel: "\(store.materialBrowserSelectableIDs.count) 份") {
            Button(store.materialEditing ? "完成" : "编辑") {
                guard store.beforeLeavingMaterial?() != false else { return }
                store.materialEditing.toggle()
            }.buttonStyle(.bordered).frame(width: 54).accessibilityLabel(store.materialEditing ? "完成资料编辑" : "编辑资料")
            if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
                let connection = store.state.teachingConnections.first { $0.courseID == id }
                Button {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.teachingUpdateAll = false; store.teachingConnectionToOpen = connection?.id; store.showingTeachingWebsite = true
                } label: { Label(connection == nil ? "连接教学网站" : "网站更新", systemImage: connection == nil ? "globe" : "arrow.clockwise") }
                    .buttonStyle(.bordered).help(connection == nil ? "连接课件、作业与实验" : "检查网站课件和作业的更新")
                Button { store.courseToEdit = course; store.showingCourseEditor = true } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless).help("编辑课程")
            } else if !store.state.teachingConnections.isEmpty {
                Button {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.teachingUpdateAll = true; store.teachingConnectionToOpen = nil; store.showingTeachingWebsite = true
                } label: { Label("网站更新", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered).help("检查所有已连接课程的网站更新")
            }
            Picker("视图", selection: $presentation) {
                Image(systemName: "list.bullet").tag("list")
                Image(systemName: "square.grid.2x2").tag("covers")
            }.labelsHidden().pickerStyle(.segmented).tint(theme.controlAccent).frame(width: 82).help("列表 / 封面")
            Button {
                guard store.beforeLeavingMaterial?() != false else { return }
                showInspector.toggle()
            } label: { Image(systemName: "sidebar.right") }.buttonStyle(.borderless).help("资料信息")
                .disabled(store.selectedMaterial == nil)
        } controls: {
            ZStack {
                filters.opacity(store.materialEditing ? 0 : 1).allowsHitTesting(!store.materialEditing).accessibilityHidden(store.materialEditing)
                editingBar.opacity(store.materialEditing ? 1 : 0).allowsHitTesting(store.materialEditing).accessibilityHidden(!store.materialEditing)
            }.frame(height: 32)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.materialEditing)
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、课程、标签和备注", text: $store.search).textFieldStyle(.plain)
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 10).frame(height: 31).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            ChoiceMenu("格式", selection: $store.formatFilter, selectedTitle: store.formatFilter) {
                ForEach(store.fileTypes, id: \.self) { Text($0) }
            }.frame(width: 110)
            ChoiceMenu("类别", selection: $store.categoryFilter, selectedTitle: store.categoryFilter) {
                Text("全部类别").tag("全部类别"); ForEach(store.categories, id: \.self) { Text($0).tag($0) }
            }.frame(width: 120)
            if let courseID = store.currentCourseID {
                SolidChoiceMenu("资料排序", selection: Binding(get: { store.materialSortMode }, set: { mode in
                    store.perform { try store.repository.setMaterialSort(mode, courseID: courseID) }
                }), options: MaterialSortMode.allCases.map { ChoiceOption(value: $0, title: $0.title) })
                    .frame(width: 128).help(store.canReorderMaterials ? "拖曳资料调整顺序，自动保存" : (store.materialSortMode == .name ? "名称按自然顺序排列" : "时间按导入时间从新到旧排列"))
            } else {
                ChoiceMenu("排序", selection: $store.sort, selectedTitle: store.sort) {
                    ForEach(["最近添加", "名称", "最近打开", "文件大小"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 110)
            }
        }
    }

    private var materialTable: some View {
        MaterialListView(items: items,
                         selection: Binding(get: { store.selectedMaterialIDs }, set: { store.selectMaterials($0) }),
                         theme: theme,
                         courseName: { store.courseName($0) }, courseColor: { store.courseColor($0) },
                         resolveURL: { try? store.repository.resolveURL($0) },
                         onOpen: { store.openMaterial($0) },
                         onQuickLook: { QuickLookController.shared.show(try? store.repository.resolveURL($0)) },
                         onReveal: { if let url = try? store.repository.resolveURL($0) { store.revealURL(url) } },
                         onFavorite: { store.favorite($0) }, onRemove: { store.removeMaterials($0) },
                         browserRows: rows,
                         onToggleFolder: { store.toggleMaterialFolder($0.id) }, onOpenFolder: { store.openMaterialFolder($0.id) },
                         onEditFolder: { folderToEdit = $0 }, onDissolveFolder: { store.dissolveMaterialFolder($0) },
                         onMoveToFolder: { ids, folderID in
                             guard let courseID = store.currentCourseID else { return }
                             store.perform { try store.repository.moveMaterials(ids: ids, to: folderID, courseID: courseID); store.selectedMaterialIDs.subtract(ids) }
                         },
                         editing: store.materialEditing, dragData: { store.materialDragData($0) },
                         onReorder: store.canReorderMaterials ? { ids, target in store.reorderMaterials(ids, before: target) } : nil,
                         onGroup: store.currentCourseID != nil ? { ids in organize(ids) } : nil,
                         onExport: { store.exportMaterials($0) })
    }

    private var coverGuides: [MaterialFolderGuide] {
        MaterialFolderGuide.project(rows) { $0.colorHex ?? store.courseColor($0.courseID).hexString }
    }
    private var coverGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(MaterialBrowserSection.sections(from: rows)) { section in
                    Group {
                        if let first = section.rows.first, first.folder != nil {
                            folderCoverRow(first)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 200), spacing: 24)], alignment: .leading, spacing: 26) {
                                ForEach(section.rows) { row in coverCard(row.material!) }
                            }.padding(.leading, MaterialBrowserLayout.borderInset(depth: section.rows.first?.depth ?? 0) - 6)
                        }
                    }.anchorPreference(key: MaterialCoverBounds.self, value: .bounds) { anchor in
                        Dictionary(uniqueKeysWithValues: section.rows.map { ($0.id, anchor) })
                    }
                }
            }
            .overlayPreferenceValue(MaterialCoverBounds.self) { anchors in
                GeometryReader { proxy in
                    ForEach(coverGuides) { guide in
                        if let first = anchors[rows[guide.firstChild].id], let last = anchors[rows[guide.lastChild].id] {
                            let top = proxy[first].minY, bottom = proxy[last].maxY
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: guide.colorHex))
                                .frame(width: 6, height: max(0, bottom - top))
                                .position(x: MaterialBrowserLayout.borderInset(depth: guide.depth + 1) - 15, y: (top + bottom) / 2)
                                .transition(.scale(scale: 0.01, anchor: .top).combined(with: .opacity))
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: coverGuides)
            }
            .padding(24)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: rows.map(\.id))
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
            .focusable().focusEffectDisabled()
            .onKeyPress(.space) {
                guard let material = store.selectedMaterial else { return .ignored }
                QuickLookController.shared.show(try? store.repository.resolveURL(material)); return .handled
            }
    }
    private func coverCard(_ material: MaterialRecord) -> some View {
        MaterialCoverCard(material: material, url: try? store.repository.resolveURL(material),
                          courseName: store.courseName(material.courseID), courseColor: store.courseColor(material.courseID),
                          selected: store.selectedMaterialIDs.contains(material.id))
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if store.materialEditing {
                    Toggle("选择：\(material.title)", isOn: Binding(get: { store.selectedMaterialIDs.contains(material.id) }, set: { _ in selectCover(material.id, extending: true) }))
                        .toggleStyle(.checkbox).labelsHidden().padding(8)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(reorderTargetID == material.id ? theme.ink : .clear, lineWidth: 2).allowsHitTesting(false) }
            .onTapGesture(count: 2) { if !store.materialEditing { store.openMaterial(material) } }
            .onTapGesture { selectCover(material.id, extending: store.materialEditing || NSEvent.modifierFlags.contains(.command)) }
            .accessibilityAction { selectCover(material.id, extending: store.materialEditing) }
            .contextMenu { materialMenu(material, ids: store.selectedMaterialIDs.contains(material.id) ? store.selectedVisibleMaterialIDs : [material.id]) }
            .onDrag { store.materialProvider(material) }
            .onDrop(of: [.teachshelfMaterial], isTargeted: Binding(get: { reorderTargetID == material.id }, set: { targeted in
                if targeted && store.canReorderMaterials { reorderTargetID = material.id }
                else if reorderTargetID == material.id { reorderTargetID = nil }
            })) { providers in store.acceptMaterialDrop(providers, before: material.id) }
    }

    @ViewBuilder private func materialMenu(_ material: MaterialRecord, ids: Set<UUID>) -> some View {
        Button("打开资料") { store.openMaterial(material) }
        Button("快速查看") { QuickLookController.shared.show(try? store.repository.resolveURL(material)) }
        Button("在 Finder 中显示") { if let url = try? store.repository.resolveURL(material) { store.revealURL(url) } }
        Button(material.isFavorite ? "取消收藏" : "收藏") { store.favorite(material) }
        Divider()
        if store.currentCourseID != nil { Button("移入文件夹…") { organize(ids) } }
        Button("导出为 ZIP…") { store.exportMaterials(ids) }
        Button("删除 \(ids.count) 份资料…", role: .destructive) { store.removeMaterials(ids) }
    }

    private func selectCover(_ id: UUID, extending: Bool) {
        var ids = extending ? store.selectedMaterialIDs : []
        if !ids.insert(id).inserted { ids.remove(id) }
        store.selectMaterials(ids)
    }

    private func organize(_ ids: Set<UUID>) {
        guard store.beforeLeavingMaterial?() != false else { return }
        folderRequest = MaterialFolderRequest(ids: ids, parentID: store.materialFolderID)
    }

    private var editingBar: some View {
        HStack(spacing: 12) {
            Text("已选择 \(store.selectedVisibleMaterialIDs.count) 份").font(.callout.weight(.medium))
            Button("全选") { store.selectMaterials(store.materialBrowserSelectableIDs) }
            Button("取消选择") { store.selectMaterials([]) }.disabled(store.selectedVisibleMaterialIDs.isEmpty)
            Spacer(minLength: 4)
            Button { organize(store.selectedVisibleMaterialIDs) } label: { Label("移入文件夹", systemImage: "folder.badge.plus") }
                .disabled(store.currentCourseID == nil || store.selectedVisibleMaterialIDs.isEmpty)
            Button { store.exportMaterials(store.selectedVisibleMaterialIDs) } label: { Label("导出 ZIP", systemImage: "square.and.arrow.up") }
                .disabled(store.selectedVisibleMaterialIDs.isEmpty)
            Button(role: .destructive) { store.removeMaterials(store.selectedVisibleMaterialIDs) } label: { Label("删除", systemImage: "trash") }
                .disabled(store.selectedVisibleMaterialIDs.isEmpty)
        }.controlSize(.small)
    }

    private var folderNavigation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button("课程资料") { store.openMaterialFolder(nil) }.buttonStyle(.plain)
                    .onDrop(of: [.teachshelfMaterial], isTargeted: nil) { store.acceptMaterialDrop($0, into: nil, grouping: true) }
                ForEach(MaterialOrdering.folderPath(store.materialFolderID, in: store.state.materialFolders)) { folder in
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button(folder.name) { store.openMaterialFolder(folder.id) }.buttonStyle(.plain).lineLimit(1)
                        .onDrop(of: [.teachshelfMaterial], isTargeted: nil) { store.acceptMaterialDrop($0, into: folder.id, grouping: true) }
                }
                Spacer()
                if store.canReorderMaterials { Text("拖曳调整顺序").foregroundStyle(.secondary).font(.caption) }
                Button { organize([]) } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }.buttonStyle(.plain)
            }.font(.callout)
        }.padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 12)
    }

    private func folderCoverRow(_ row: MaterialBrowserRow) -> some View {
        let folder = row.folder!
        return HStack(spacing: 12) {
                Toggle("选择：\(folder.name)", isOn: Binding(get: { !row.materialIDs.isEmpty && row.materialIDs.isSubset(of: store.selectedMaterialIDs) }, set: { selected in
                    var ids = store.selectedMaterialIDs
                    if selected { ids.formUnion(row.materialIDs) } else { ids.subtract(row.materialIDs) }
                    store.selectMaterials(ids)
                })).toggleStyle(.checkbox).labelsHidden().disabled(row.materialIDs.isEmpty)
                    .opacity(store.materialEditing ? 1 : 0).allowsHitTesting(store.materialEditing).accessibilityHidden(!store.materialEditing)
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "folder.fill").font(.system(size: 28)).foregroundStyle(folder.colorHex.map { Color(hex: $0) } ?? store.courseColor(folder.courseID))
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.system(size: 13, weight: .medium))
                Text("文件夹 · \(row.materialIDs.count) 份资料").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 14).frame(height: 62)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.openMaterialFolder(folder.id) }
            .onTapGesture { store.toggleMaterialFolder(folder.id) }
            .accessibilityElement(children: .contain).accessibilityLabel("\(folder.name)，文件夹")
            .contextMenu {
                Button("进入文件夹") { store.openMaterialFolder(folder.id) }
                Button("编辑名称与颜色…") { folderToEdit = folder }
                Button("解散文件夹…") { store.dissolveMaterialFolder(folder) }
            }
            .onDrop(of: [.teachshelfMaterial], isTargeted: nil) { store.acceptMaterialDrop($0, into: folder.id, grouping: true) }
            .padding(.leading, MaterialBrowserLayout.borderInset(depth: row.depth) - 6)
    }

}

struct FileGlyph: View {
    let material: MaterialRecord
    let tint: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.10))
            Text(material.fileExtension.isEmpty ? "FILE" : String(material.fileExtension.prefix(4))).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(tint)
        }
    }
}

enum FileDropLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else if let text = item as? String { continuation.resume(returning: URL(string: text)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            completion(urls)
        }
    }
}

private struct MaterialCoverBounds: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
