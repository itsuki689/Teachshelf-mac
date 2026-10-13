import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore

struct LibraryWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("libraryPresentation") private var presentation = "list"
    @ViewState private var dropTarget = false
    @ViewState private var showInspector = true
    private var items: [MaterialRecord] { store.visibleMaterials }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            if let courseID = store.currentCourseID {
                let tasks = store.state.tasks.filter { $0.courseID == courseID && !$0.isArchived && !$0.isCompleted }
                if !tasks.isEmpty {
                    HStack(spacing: 12) {
                        Label("\(tasks.count) 个未完成待办", systemImage: "checklist").font(.caption.weight(.medium)).foregroundStyle(AppPalette.accent)
                        Text(tasks.prefix(2).map(\.title).joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("查看待办") { store.navigate(to: .tasks) }.buttonStyle(.link).font(.caption)
                    }.padding(.horizontal, 24).padding(.vertical, 10).background(AppPalette.accent.opacity(0.06))
                }
            }
            Divider()
            HSplitView {
                Group {
                    if items.isEmpty {
                        VStack(spacing: 0) {
                            EmptyStateView(symbol: store.state.materials.isEmpty ? "books.vertical" : "magnifyingglass", title: store.state.materials.isEmpty ? "让知识住进你的书架" : "没有匹配的资料", detail: store.state.materials.isEmpty ? "导入课件、教材和笔记，或将文件拖到这里。所有资料都留在本机。" : "尝试其他关键词，或清除类别与格式筛选。")
                            Button(store.state.materials.isEmpty ? "导入第一份资料" : "清除筛选") {
                                if store.state.materials.isEmpty { store.chooseImport() }
                                else { store.search = ""; store.categoryFilter = "全部类别"; store.formatFilter = "全部格式" }
                            }.buttonStyle(.borderedProminent).padding(.bottom, 100)
                        }
                    } else if presentation == "covers" { coverGrid }
                    else { materialTable }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector, let material = store.selectedMaterial {
                    MaterialInspector(material: material).id(material.id).frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).fill(AppPalette.accent.opacity(0.08)).overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                }.padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            FileDropLoader.load(providers) { urls in store.importURLs = urls; store.showingImport = !urls.isEmpty }
            return true
        }
        .onChange(of: store.selectedMaterialIDs) { _, ids in if !ids.isEmpty { showInspector = true } }
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(store.title).font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(items.count) 份").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4).background(.quaternary, in: Capsule())
                    }
                    if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
                        Text([course.semester, course.teacher, course.isArchived ? "已归档" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("课件、教材与灵感，井然有序。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let id = store.currentCourseID, let course = store.state.courses.first(where: { $0.id == id }) {
                    Button { store.courseToEdit = course; store.showingCourseEditor = true } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless).help("编辑课程")
                }
                Picker("视图", selection: $presentation) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("covers")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 82).help("列表 / 封面")
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.buttonStyle(.borderless).help("资料信息")
            }
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
        }.padding(.horizontal, 24).padding(.vertical, 22)
    }

    private var materialTable: some View {
        Table(items, selection: Binding(get: { store.selectedMaterialIDs }, set: { store.selectMaterials($0) })) {
            TableColumn("名称") { material in
                HStack(spacing: 10) {
                    FileGlyph(material: material, tint: store.courseColor(material.courseID)).frame(width: 32, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(material.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(store.courseName(material.courseID)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 5)
            }.width(min: 200, ideal: 330)
            TableColumn("类别", value: \.category).width(min: 70, ideal: 85, max: 130)
            TableColumn("大小") { Text($0.sizeLabel).foregroundStyle(.secondary) }.width(80)
            TableColumn("添加日期") { Text($0.addedAt, format: .dateTime.year().month().day()).foregroundStyle(.secondary) }.width(100)
            TableColumn("收藏") { material in
                Button { store.favorite(material) } label: { Image(systemName: material.isFavorite ? "star.fill" : "star").foregroundStyle(material.isFavorite ? Color.orange : Color.secondary.opacity(0.55)) }.buttonStyle(.plain).help("收藏 / 取消收藏")
            }.width(40)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let material = store.state.materials.first(where: { ids.contains($0.id) }) { materialMenu(material, ids: ids) }
        } primaryAction: { ids in if let material = store.state.materials.first(where: { ids.contains($0.id) }) { store.openMaterial(material) } }
        .onDeleteCommand { if !store.selectedMaterialIDs.isEmpty { store.removeMaterials(store.selectedMaterialIDs) } }
        .onKeyPress(.space) {
            guard let material = store.selectedMaterial else { return .ignored }
            QuickLookController.shared.show(try? store.repository.resolveURL(material)); return .handled
        }
    }

    private var coverGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 200), spacing: 24)], alignment: .leading, spacing: 26) {
                ForEach(items) { material in
                    VStack(alignment: .leading, spacing: 9) {
                        CoverThumbnail(material: material, url: try? store.repository.resolveURL(material), color: store.courseColor(material.courseID))
                            .frame(height: 205).shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 4)
                        Text(material.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(height: 34, alignment: .topLeading)
                        HStack {
                            Text(store.courseName(material.courseID)).lineLimit(1)
                            Spacer(minLength: 0)
                            if material.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(10).background(store.selectedMaterialIDs.contains(material.id) ? AppPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.openMaterial(material) }
                        .onTapGesture { store.selectMaterials([material.id]) }
                        .contextMenu { materialMenu(material, ids: [material.id]) }
                        .onDrag { NSItemProvider(contentsOf: (try? store.repository.resolveURL(material)) ?? URL(fileURLWithPath: material.sourcePath)) ?? NSItemProvider() }
                }
            }.padding(24)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
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
