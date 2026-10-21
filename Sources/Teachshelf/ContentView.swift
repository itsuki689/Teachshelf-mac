import SwiftUI
import TeachshelfCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
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
                            case .tasks: TaskWorkspace(pendingOnly: true)
                            case .schedule: ScheduleWorkspace()
                            case .homework: HomeworkWorkspace()
                            case .settings: SettingsWorkspace()
                            default: LibraryWorkspace()
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        HStack(spacing: 8) {
                            if store.isBusy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(theme.ink) }
                            Text(store.status).lineLimit(1)
                            Spacer()
                            Text("本地资料库").foregroundStyle(.tertiary)
                            Button { store.openURL(store.repository.root) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help(store.repository.root.path)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 30).background(.bar)
                    }
                    .frame(width: detailGeometry.size.width, height: detailGeometry.size.height)
                }
                .workspaceWindowTitle(store.title)
                // A space preserves native placeholder metrics without displaying a prompt.
                .searchable(text: $store.workspaceSearchQuery, isPresented: $store.showingWorkspaceSearch,
                            placement: .toolbarPrincipal, prompt: Text(verbatim: " "))
                .searchSuggestions {
                    ForEach(WorkspaceSearch.results(for: store.workspaceSearchQuery, in: store.state)) { result in
                        Button("\(result.kind.rawValue) · \(result.title)", systemImage: result.kind.symbol) {
                            store.activateSearchResult(result)
                        }.searchCompletion(result.title).help(result.detail)
                    }
                }
                .onSubmit(of: .search) {
                    if let result = WorkspaceSearch.results(for: store.workspaceSearchQuery, in: store.state).first {
                        store.activateSearchResult(result)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { store.goBack() } label: { Label("后退", systemImage: "chevron.left") }
                            .disabled(!store.canGoBack || store.isBusy).help("后退 · ⌘[")
                            .accessibilityIdentifier("workspace.back")
                        Button { store.goForward() } label: { Label("前进", systemImage: "chevron.right") }
                            .disabled(!store.canGoForward || store.isBusy).help("前进 · ⌘]")
                            .accessibilityIdentifier("workspace.forward")
                    }
                    WorkspaceAppearanceToolbarItem()
                    ToolbarItem(placement: .primaryAction) { WorkspaceToolbarActions() }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(width: windowGeometry.size.width, height: windowGeometry.size.height)
        }
        .frame(minWidth: 1020, minHeight: 680)
        .background(WindowCloseGuard(store: store))
        .disabled(store.isBusy)
        .sheet(isPresented: $store.showingCourseEditor) { CourseEditor(course: store.courseToEdit).environmentObject(store) }
        .sheet(isPresented: $store.showingImport) { ImportSheet(urls: store.importURLs).environmentObject(store) }
        .sheet(isPresented: $store.showingTeachingWebsite) {
            TeachingWebsiteSheet(controller: store.teachingWebsiteSession(), initialCourseID: store.currentCourseID, connectionID: store.teachingConnectionToOpen).environmentObject(store)
        }
        .sheet(item: $store.toolbarPlanDraft) { draft in
            TaskEditor(task: draft.task, isNew: draft.isNew, compact: true, calendar: PlanCalendar.calendar)
                .environmentObject(store)
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").font(.system(size: 22)).foregroundStyle(theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teachshelf").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("每一份知识，都有位置").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
            ChoiceMenu("学期", selection: $store.semester, selectedTitle: store.semester) {
                ForEach(store.semesters, id: \.self) { Text($0).tag($0) }
            }.padding(.horizontal, 14).padding(.bottom, 12)
            HStack(spacing: 2) {
                libraryShortcut("全部资料", "tray.full", .all, hint: "全部资料 · \(store.state.materials.count) 份")
                libraryShortcut("我的收藏", "star", .favorites, hint: "我的收藏 · \(store.state.materials.filter(\.isFavorite).count) 份")
                libraryShortcut("最近打开", "clock", .recent, hint: "最近打开")
                libraryShortcut("未分类", "tray", .unassigned, hint: "未分类资料")
                libraryShortcut("作业文件夹", "folder", .homework, hint: "作业文件夹")
                libraryShortcut("待完成计划", "checklist", .tasks, hint: "待完成计划 · \(store.pendingTaskCount) 项")
            }.padding(.horizontal, 14).padding(.bottom, 6)
                .accessibilityElement(children: .contain).accessibilityLabel("快捷入口")

            navRow("计划", "calendar", .schedule, compact: true).padding(.horizontal, 14)
            Divider().padding(.horizontal, 20).padding(.vertical, 12)
            HStack(spacing: 8) {
                SolidChoiceMenu("课程状态", selection: $store.courseArchiveFilter,
                                options: ["当前课程", "已归档课程", "全部课程"].map { ChoiceOption(value: $0, title: $0) },
                                compact: true)
                    .frame(maxWidth: .infinity)
                Button { store.courseToEdit = nil; store.showingCourseEditor = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).help("新建课程 · ⌘N").accessibilityLabel("新建课程")
            }.padding(.horizontal, 14).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.sidebarCourses) { course in
                        CourseSidebarRow(course: course,
                                         count: store.state.materials.filter { $0.courseID == course.id }.count,
                                         isSelected: store.navigation == .course(course.id),
                                         showBorders: store.state.showCourseBorders,
                                         onSelect: { store.navigate(to: .course(course.id)) },
                                         onEdit: {
                                             guard store.beforeLeavingMaterial?() != false else { return }
                                             store.courseToEdit = course; store.showingCourseEditor = true
                                         })
                            .contextMenu {
                                Button("编辑课程…") { store.courseToEdit = course; store.showingCourseEditor = true }
                                Button(course.isArchived ? "恢复课程" : "归档课程") { store.perform { try store.repository.archiveCourse(id: course.id, archived: !course.isArchived) } }
                            }
                    }
                    if store.sidebarCourses.isEmpty {
                        Text("添加课程，开始整理资料").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
            Divider().padding(.horizontal, 20)
            navRow("设置", "gearshape", .settings).padding(.horizontal, 14).padding(.vertical, 12)
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSidebar(1); return .handled }
        .onKeyPress(.upArrow) { moveSidebar(-1); return .handled }
    }
    private func navRow(_ title: String, _ symbol: String, _ selection: SidebarSelection, count: Int? = nil, compact: Bool = false) -> some View {
        SidebarDestinationButton(title: title, symbol: symbol, selected: store.navigation == selection, count: count, compact: compact) {
            if selection == .schedule { store.scheduleSelection.planFilter = .all }
            store.navigate(to: selection)
        }
    }

    private func libraryShortcut(_ title: String, _ symbol: String, _ selection: SidebarSelection, hint: String) -> some View {
        LibraryShortcut(title: title, symbol: symbol, selected: store.navigation == selection, hint: hint) {
            store.navigate(to: selection)
        }
    }

    private func moveSidebar(_ offset: Int) {
        let destinations: [SidebarSelection] = [.all, .favorites, .recent, .unassigned, .homework, .tasks, .schedule]
            + store.sidebarCourses.map { .course($0.id) } + [.settings]
        let index = store.navigation.flatMap { destinations.firstIndex(of: $0) } ?? 0
        store.navigate(to: destinations[min(max(index + offset, 0), destinations.count - 1)])
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

extension Color {
    init(hex: String) {
        self.init(rgb: RGBColor(hex: hex) ?? RGBColor(hex: ColorPalette.defaultAccent)!)
    }
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .systemTeal
        return RGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent).hex
    }
}
struct EmptyStateView: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(theme.ink.opacity(0.65))
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}
