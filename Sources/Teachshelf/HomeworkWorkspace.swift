import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore


struct HomeworkWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState<UUID?> private var courseID: UUID?
    @ViewState<String> private var relativePath = ""
    @ViewState<[WorkspaceEntry]> private var entries: [WorkspaceEntry] = []
    @ViewState<Set<String>> private var selection = Set<String>()
    @ViewState<String> private var search = ""
    @ViewState<Bool> private var isDropTargeted = false
    @ViewState<URL?> private var folderURL: URL?
    @ViewState<Bool> private var showingNewFolder = false
    @ViewState<String> private var newFolderName = ""

    private var visibleEntries: [WorkspaceEntry] {
        entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var selectedCourse: Course? { store.state.courses.first { $0.id == courseID } }
    private var breadcrumbs: [String] { relativePath.split(separator: "/").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceCommandBar(title: "作业文件夹", subtitle: "题目、草稿与成果，像 Finder 一样整理。") {
                Button { chooseImport() } label: { Label("添加文件", systemImage: "plus") }
                    .appPrimaryButton().controlSize(.regular).disabled(store.isBusy)
            } controls: {
                HStack(spacing: 12) {
                    CourseMenu(selection: $courseID,
                               courses: store.state.courses.filter { !$0.isArchived || $0.id == courseID },
                               emptyTitle: "公共作业文件夹").frame(width: 230)
                    Spacer()
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新文件夹")
                    Button { if let folderURL { store.openURL(folderURL) } } label: { Label("在 Finder 中打开", systemImage: "folder") }
                    Menu {
                        Button("新建文件夹…") { newFolderName = ""; showingNewFolder = true }
                        Divider()
                        Button("复制文件夹路径") { copyFolderPath() }
                        if courseID != nil {
                            Divider()
                            Button("使用已有文件夹…") { chooseMount() }
                            if selectedCourse?.homeworkFolder != nil {
                                Button("使用资料库内的作业文件夹") { unmount() }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                }
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    relativePath = breadcrumbs.dropLast().joined(separator: "/")
                    search = ""; reload()
                } label: { Image(systemName: "arrow.up") }
                    .disabled(relativePath.isEmpty).help("上一级文件夹").keyboardShortcut(.upArrow, modifiers: [.command])
                Button { relativePath = ""; reload() } label: {
                    Label(selectedCourse?.name ?? "公共作业", systemImage: selectedCourse?.homeworkFolder == nil ? "folder" : "externaldrive")
                }.buttonStyle(.borderless)
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(component) {
                        relativePath = breadcrumbs.prefix(index + 1).joined(separator: "/")
                        reload()
                    }.buttonStyle(.borderless)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索当前文件夹", text: $search).textFieldStyle(.plain)
                }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).frame(width: 210)
            }.padding(.horizontal, 24).padding(.vertical, 12)

            ZStack {
                if visibleEntries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 54, weight: .light)).foregroundStyle(theme.ink.opacity(0.7))
                        Text(search.isEmpty ? "给作业留一个位置" : "没有找到匹配的文件").font(.title2.weight(.semibold))
                        Text(search.isEmpty ? "把文件和文件夹拖到这里，或点击「添加文件」。" : "试试其他名称。").foregroundStyle(.secondary)
                        if search.isEmpty { Button("添加文件…") { chooseImport() }.buttonStyle(.bordered) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(visibleEntries, selection: $selection) {
                        TableColumn("名称") { entry in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 25, height: 25)
                                Text(entry.name).lineLimit(1)
                            }.padding(.vertical, 5)
                        }.width(min: 260, ideal: 430)
                        TableColumn("修改日期") { entry in
                            Text(entry.modifiedAt.formatted(.dateTime.year().month().day().hour().minute())).foregroundStyle(.secondary)
                        }.width(min: 150, ideal: 175)
                        TableColumn("类型") { entry in
                            Text(entry.isDirectory ? "文件夹" : (entry.url.pathExtension.isEmpty ? "文件" : entry.url.pathExtension.uppercased())).foregroundStyle(.secondary)
                        }.width(min: 65, ideal: 90)
                        TableColumn("大小") { entry in
                            Text(entry.isDirectory ? "—" : entry.sizeLabel).foregroundStyle(.secondary)
                        }.width(90)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button(ids.count == 1 && entries.first(where: { ids.contains($0.id) })?.isDirectory == true ? "打开文件夹" : "打开") { openSelection(ids) }.disabled(ids.isEmpty)
                        Button("在 Finder 中显示") {
                            for entry in entries where ids.contains(entry.id) { store.revealURL(entry.url) }
                        }.disabled(ids.isEmpty)
                        Button("复制路径") {
                            let paths = entries.filter { ids.contains($0.id) }.map { $0.url.path }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(paths, forType: .string)
                        }.disabled(ids.isEmpty)
                    } primaryAction: { ids in openSelection(ids) }
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12).fill(theme.selection)
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 2, dash: [7])) }
                        .padding(8).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                guard !store.isBusy else { return false }
                Task { @MainActor in
                    let urls = await homeworkDroppedURLs(providers)
                    if !urls.isEmpty { await importItems(urls) }
                }
                return true
            }
            Divider()
            HStack(spacing: 10) {
                Text(selection.isEmpty ? "\(visibleEntries.count) 个项目" : "已选择 \(selection.count) 个项目").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let folderURL {
                    Text(folderURL.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }.padding(12)
        }
        .onAppear { courseID = store.prepareWorkspaceCourse(); reload() }
        .onChange(of: courseID) { _, id in store.selectWorkspaceCourse(id); relativePath = ""; search = ""; reload() }
        .onChange(of: store.repository.root) { _, _ in courseID = nil; relativePath = ""; reload() }
        .onChange(of: store.state.courses) { _, courses in
            if let courseID, !courses.contains(where: { $0.id == courseID }) { self.courseID = nil; relativePath = "" }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.perform { _ = try store.repository.createHomeworkFolder(name: name, courseID: courseID, relativePath: relativePath) }
                reload()
            }.disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("文件夹会建立在当前作业目录中。") }
    }

    private func reload() {
        guard !store.isBusy else { return }
        do {
            let baseURL = try store.repository.homeworkURL(courseID: courseID)
            folderURL = relativePath.isEmpty ? baseURL : baseURL.appendingPathComponent(relativePath)
            entries = try store.repository.listHomework(courseID: courseID, relativePath: relativePath)
            selection.formIntersection(Set(entries.map(\.id)))
        } catch { store.report(error); entries = [] }
    }

    private func openSelection(_ ids: Set<String>) {
        let chosen = entries.filter { ids.contains($0.id) }
        if chosen.count == 1, let entry = chosen.first, entry.isDirectory {
            relativePath = relativePath.isEmpty ? entry.name : "\(relativePath)/\(entry.name)"
            search = ""; selection = []; reload()
        } else {
            for entry in chosen { store.openURL(entry.url) }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "添加到作业文件夹"
        panel.message = "文件和文件夹将复制到当前作业目录。"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await importItems(urls) }
        }
    }

    private func importItems(_ urls: [URL]) async {
        let repository = store.repository
        let targetCourse = courseID
        let targetPath = relativePath
        await store.runOperation("正在添加作业文件…") {
            let result = try repository.importHomework(urls: urls, courseID: targetCourse, relativePath: targetPath)
            return "新增 \(result.imported) 个项目，跳过 \(result.skipped) 个" + (result.errors.isEmpty ? "" : " · " + result.errors.joined(separator: "；"))
        }
        reload()
    }

    private func chooseMount() {
        guard let courseID else { return }
        let panel = NSOpenPanel()
        panel.title = "选择课程作业文件夹"
        panel.message = "直接管理这个文件夹中的内容；文件会保留在原位置。"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            store.perform { try store.repository.mountHomework(courseID: courseID, url: url) }
            relativePath = ""; reload()
        }
    }

    private func unmount() {
        guard let courseID else { return }
        store.perform { try store.repository.mountHomework(courseID: courseID, url: nil) }
        relativePath = ""; reload()
    }

    private func copyFolderPath() {
        guard let folderURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folderURL.path, forType: .string)
    }
}

private func homeworkDroppedURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        let url: URL? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let url = item as? NSURL { continuation.resume(returning: url as URL) }
                else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                else if let string = item as? String { continuation.resume(returning: URL(string: string)) }
                else { continuation.resume(returning: nil) }
            }
        }
        if let url, url.isFileURL { urls.append(url) }
    }
    return urls
}
