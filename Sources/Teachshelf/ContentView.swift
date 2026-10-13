import SwiftUI
import TeachshelfCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        // Page-specific intrinsic widths must not change the scene's resize limits.
        GeometryReader { windowGeometry in
            NavigationSplitView {
                sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
            } detail: {
                // Keep the split view's detail minimum independent of the active page.
                GeometryReader { detailGeometry in
                    VStack(spacing: 0) {
                        Group {
                            switch store.navigation {
                            case .tasks: TaskWorkspace()
                            case .calendar: CalendarWorkspace()
                            case .homework: HomeworkWorkspace()
                            case .settings: SettingsWorkspace()
                            default: LibraryWorkspace()
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        HStack(spacing: 8) {
                            if store.isBusy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(AppPalette.accent) }
                            Text(store.status).lineLimit(1)
                            Spacer()
                            Text("本地资料库").foregroundStyle(.tertiary)
                            Button { store.openURL(store.repository.root) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help(store.repository.root.path)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 30).background(.bar)
                    }
                    .frame(width: detailGeometry.size.width, height: detailGeometry.size.height)
                }
                .navigationTitle(store.title)
                .toolbar {
                    if store.navigation?.isLibrary == true {
                        ToolbarItem(placement: .primaryAction) {
                            Button { store.chooseImport() } label: { Label("导入资料", systemImage: "plus") }.disabled(store.isBusy).help("导入文件或文件夹 · ⌘O")
                        }
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(width: windowGeometry.size.width, height: windowGeometry.size.height)
        }
        .tint(Color(hex: store.state.accentColor))
        .frame(minWidth: 1020, minHeight: 680)
        .background(WindowCloseGuard(store: store))
        .disabled(store.isBusy)
        .sheet(isPresented: $store.showingCourseEditor) { CourseEditor(course: store.courseToEdit).environmentObject(store) }
        .sheet(isPresented: $store.showingImport) { ImportSheet(urls: store.importURLs).environmentObject(store) }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onChange(of: store.navigation) { _, _ in store.selectedMaterialIDs = [] }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").font(.system(size: 22)).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teachshelf").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("每一份知识，都有位置").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
            ChoiceMenu("学期", selection: $store.semester, selectedTitle: store.semester) {
                ForEach(store.semesters, id: \.self) { Text($0).tag($0) }
            }.padding(.horizontal, 14).padding(.bottom, 10)
            List(selection: Binding(get: { store.navigation }, set: { store.navigate(to: $0) })) {
                Section("资料库") {
                    navRow("全部资料", "tray.full", .all, count: store.state.materials.count)
                    navRow("我的收藏", "star", .favorites, count: store.state.materials.filter(\.isFavorite).count)
                    navRow("最近打开", "clock", .recent)
                    navRow("未分类", "tray", .unassigned)
                }
                Section("学习") {
                    navRow("作业文件夹", "folder", .homework)
                    navRow("待办", "checklist", .tasks, count: store.pendingTaskCount)
                    navRow("日历", "calendar", .calendar)
                }
                Section {
                    ChoiceMenu("课程状态", selection: $store.courseArchiveFilter, selectedTitle: store.courseArchiveFilter, compact: true) {
                        ForEach(["当前课程", "已归档课程", "全部课程"], id: \.self) { Text($0).tag($0) }
                    }
                    ForEach(store.sidebarCourses) { course in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 4).fill(Color(hex: course.colorHex)).frame(width: 12, height: 12)
                            Text(course.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(store.state.materials.filter { $0.courseID == course.id }.count)").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 3).tag(SidebarSelection.course(course.id))
                            .contextMenu {
                                Button("编辑课程…") { store.courseToEdit = course; store.showingCourseEditor = true }
                                Button(course.isArchived ? "恢复课程" : "归档课程") { store.perform { try store.repository.archiveCourse(id: course.id, archived: !course.isArchived) } }
                            }
                    }
                    if store.sidebarCourses.isEmpty { Text("添加课程，开始整理资料").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4) }
                } header: {
                    HStack {
                        Text("课程")
                        Spacer()
                        Button { store.courseToEdit = nil; store.showingCourseEditor = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建课程 · ⌘N")
                    }
                }
                Section { navRow("设置", "gearshape", .settings) }
            }.listStyle(.sidebar)
        }
    }
    private func navRow(_ title: String, _ symbol: String, _ selection: SidebarSelection, count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 2).tag(selection)
    }
}

typealias ViewState<Value> = SwiftUI.State<Value>

/// Give AppKit's split view a concrete size instead of its panes' combined ideal size.
struct WorkspaceSplitView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            HSplitView { content() }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

enum AppPalette { static let accent = Color(hex: "#39786B") }
extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x39786B
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .systemTeal
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(AppPalette.accent.opacity(0.65))
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}
