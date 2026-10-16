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
    private var items: [MaterialRecord] { store.visibleMaterials }
    private var inspectorVisible: Bool { showInspector && store.selectedMaterial != nil }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
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
                        if items.isEmpty {
                            VStack(spacing: 0) {
                                EmptyStateView(symbol: store.state.materials.isEmpty ? "books.vertical" : "magnifyingglass", title: store.state.materials.isEmpty ? "让知识住进你的书架" : "没有匹配的资料", detail: store.state.materials.isEmpty ? "导入课件、教材和笔记，或将文件拖到这里。所有资料都留在本机。" : "尝试其他关键词，或清除类别与格式筛选。")
                                Button(store.state.materials.isEmpty ? "导入第一份资料" : "清除筛选") {
                                    if store.state.materials.isEmpty { store.chooseImport() }
                                    else { store.search = ""; store.categoryFilter = "全部类别"; store.formatFilter = "全部格式" }
                                }.appPrimaryButton().padding(.bottom, 100)
                            }
                        } else if presentation == "covers" { coverGrid }
                        else { materialTable }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                    if inspectorVisible, let material = store.selectedMaterial {
                        VStack(spacing: 0) {
                            MaterialInspector(material: material).id(material.id)
                        }
                        .frame(width: min(320, geometry.size.width * 0.44), height: geometry.size.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
                        .shadow(color: .black.opacity(theme.isDark ? 0.22 : 0.08), radius: 12, x: -4, y: 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: inspectorVisible)
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
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            FileDropLoader.load(providers) { urls in store.importURLs = urls; store.showingImport = !urls.isEmpty }
            return true
        }
        .onChange(of: store.selectedMaterialIDs) { _, ids in if !ids.isEmpty { showInspector = true } }
        .sheet(isPresented: $showingCoursePlans) {
            PlanListSheet(courseID: store.currentCourseID, pendingOnly: true)
        }
    }

    private var subtitle: String {
        if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
            return [course.semester, course.teacher, course.isArchived ? "已归档" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return "课件、教材与灵感，井然有序。"
    }

    private var commandBar: some View {
        WorkspaceCommandBar(title: store.title, subtitle: subtitle, countLabel: "\(items.count) 份") {
            if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
                Button { store.courseToEdit = course; store.showingCourseEditor = true } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless).help("编辑课程")
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
                         onFavorite: { store.favorite($0) }, onRemove: { store.removeMaterials($0) })
    }

    private var coverGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 200), spacing: 24)], alignment: .leading, spacing: 26) {
                ForEach(items) { material in
                    MaterialCoverCard(material: material, url: try? store.repository.resolveURL(material),
                                      courseName: store.courseName(material.courseID), courseColor: store.courseColor(material.courseID),
                                      selected: store.selectedMaterialIDs.contains(material.id))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.openMaterial(material) }
                        .onTapGesture { store.selectMaterials([material.id]) }
                        .accessibilityAction { store.selectMaterials([material.id]) }
                        .contextMenu { materialMenu(material, ids: [material.id]) }
                        .onDrag { NSItemProvider(contentsOf: (try? store.repository.resolveURL(material)) ?? URL(fileURLWithPath: material.sourcePath)) ?? NSItemProvider() }
                }
            }.padding(24)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
            .focusable().focusEffectDisabled()
            .onKeyPress(.space) {
                guard let material = store.selectedMaterial else { return .ignored }
                QuickLookController.shared.show(try? store.repository.resolveURL(material)); return .handled
            }
    }
    @ViewBuilder private func materialMenu(_ material: MaterialRecord, ids: Set<UUID>) -> some View {
        Button("打开资料") { store.openMaterial(material) }
        Button("快速查看") { QuickLookController.shared.show(try? store.repository.resolveURL(material)) }
        Button("在 Finder 中显示") { if let url = try? store.repository.resolveURL(material) { store.revealURL(url) } }
        Button(material.isFavorite ? "取消收藏" : "收藏") { store.favorite(material) }
        Divider()
        Button("移除 \(ids.count) 份记录…") { store.removeMaterials(ids) }
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
