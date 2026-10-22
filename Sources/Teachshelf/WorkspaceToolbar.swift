import SwiftUI
import AppKit
import TeachshelfCore

struct WorkspaceAppearanceToolbarItem: ToolbarContent {
    @ToolbarContentBuilder var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 0) {
                AppearanceModeToggle(width: 72)
                    .accessibilityIdentifier("workspace.appearance")
            }
            // Reserve 48 points after the toggle so it and the native search sit farther left.
            .frame(width: 120, height: 36, alignment: .leading).fixedSize()
        }
    }
}

struct WorkspaceToolbarActions: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var settingsRotation: Double = 0
    @ViewState private var updateRotation: Double = 0
    @ViewState private var importTrigger = 0
    @ViewState private var createRotation: Double = 0
    @ViewState private var showingCreateMenu = false
    @ViewState private var pendingCreateAction: (() -> Void)?

    private let diameter: CGFloat = 36
    private var actions: [ToolbarAction] { store.state.toolbarSettings.actions }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                actionButton(action)
            }
        }
        .buttonStyle(.plain).font(.system(size: 16))
        .accessibilityElement(children: .contain)
        .frame(width: diameter * CGFloat(actions.count), height: diameter).fixedSize()
        .overlay {
            if colorScheme == .light {
                Capsule().strokeBorder(Color(white: 0.35).opacity(activeState == .inactive ? 0.13 : 0.20),
                                       lineWidth: contrast == .increased ? 1 : 0.6)
                    .shadow(color: .black.opacity(activeState == .inactive ? 0.04 : 0.09), radius: 2, y: 1)
                    .overlay {
                        Capsule().inset(by: 0.7).strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.05)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .disabled(store.isBusy)
        .onChange(of: actions) { _, value in
            if !value.contains(.create) { showingCreateMenu = false }
        }
        .onChange(of: showingCreateMenu) { _, expanded in
            withAnimation(reduceMotion ? nil : .easeOut(duration: expanded ? 0.72 : 0.18)) {
                // Three full turns plus 45 degrees; closing completes the final quarter-turn.
                createRotation += expanded ? 1_125 : 315
            }
        }
        .onDisappear { showingCreateMenu = false }
    }

    @ViewBuilder private func actionButton(_ action: ToolbarAction) -> some View {
        if action == .create {
            Button { showingCreateMenu.toggle() } label: {
                ToolbarPlusArtwork()
                    .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(createRotation))
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .help(showingCreateMenu ? "关闭新建菜单" : "新建课程或计划")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showingCreateMenu ? "关闭新建菜单" : "快捷新建")
            .accessibilityValue(showingCreateMenu ? "已展开" : "已收起")
            .accessibilityIdentifier("workspace.create")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if !store.isBusy { showingCreateMenu.toggle() } }
            .popover(isPresented: $showingCreateMenu, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    createMenuRow("新建课程…", symbol: "books.vertical") {
                        guard store.beforeLeavingMaterial?() != false else { return }
                        store.courseToEdit = nil; store.showingCourseEditor = true
                    }
                    createMenuRow("新建计划…", symbol: "calendar.badge.plus") { store.startToolbarPlan() }
                    Divider().padding(.vertical, 3)
                    createMenuRow("连接教学网站…", symbol: "globe") {
                        guard store.beforeLeavingMaterial?() != false else { return }
                        store.teachingUpdateAll = false; store.teachingConnectionToOpen = nil
                        store.showingTeachingWebsite = true
                    }
                }
                .padding(6).frame(width: 212)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityElement(children: .contain).accessibilityLabel("新建")
                .onDisappear {
                    guard let action = pendingCreateAction else { return }
                    pendingCreateAction = nil
                    Task { @MainActor in await Task.yield(); action() }
                }
            }
        } else {
            Button { activate(action) } label: {
                icon(action)
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .help(help(action))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(action == .settings && store.navigation == .settings ? "关闭设置" : action.title)
            .accessibilityIdentifier("workspace.\(action.rawValue)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate(action) }
            .disabled(action == .update && store.state.teachingConnections.isEmpty)
        }
    }

    @ViewBuilder private func icon(_ action: ToolbarAction) -> some View {
        switch action {
        case .update:
            Image(systemName: action.symbol)
                .rotationEffect(.degrees(updateRotation))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: updateRotation)
        case .settings:
            Image(systemName: action.symbol)
                .rotationEffect(.degrees(settingsRotation))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.42), value: settingsRotation)
        case .importMaterials:
            if reduceMotion {
                ToolbarImportArtwork(phase: 0)
            } else {
                ToolbarImportArtwork(phase: 0)
                    .keyframeAnimator(initialValue: 0.0, trigger: importTrigger) { _, phase in
                        ToolbarImportArtwork(phase: phase)
                    } keyframes: { _ in
                        MoveKeyframe(0.0)
                        LinearKeyframe(1.0, duration: 0.4)
                    }
            }
        default:
            Image(systemName: action.symbol)
        }
    }

    private func activate(_ action: ToolbarAction) {
        guard !store.isBusy else { return }
        switch action {
        case .update:
            guard !store.state.teachingConnections.isEmpty, store.beforeLeavingMaterial?() != false else { return }
            if !reduceMotion { updateRotation += 360 }
            store.teachingUpdateAll = true; store.teachingConnectionToOpen = nil; store.showingTeachingWebsite = true
        case .settings:
            let previous = store.workspaceLocation
            if store.navigation == .settings {
                if store.canGoBack { store.goBack() }
                else { store.navigate(to: .all) }
            } else { store.navigate(to: .settings) }
            if store.workspaceLocation != previous, !reduceMotion { settingsRotation += 360 }
        case .importMaterials:
            if store.chooseImport(), !reduceMotion { importTrigger += 1 }
        case .schedule:
            store.navigate(to: .schedule)
            if store.navigation == .schedule { store.scheduleSelection.planFilter = .all }
        case .allMaterials: store.navigate(to: .all)
        case .favorites: store.navigate(to: .favorites)
        case .recent: store.navigate(to: .recent)
        case .homework: store.navigate(to: .homework)
        case .pendingTasks: store.navigate(to: .tasks)
        case .create: break
        }
    }

    private func createMenuRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            pendingCreateAction = action
            showingCreateMenu = false
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.system(size: 13))
    }

    private func help(_ action: ToolbarAction) -> String {
        switch action {
        case .update: return "检查所有已连接课程的网站更新"
        case .settings: return store.navigation == .settings ? "关闭设置，返回上一页面" : "设置"
        case .importMaterials: return "导入文件或文件夹 · ⌘O"
        default: return action.title
        }
    }
}

private struct ToolbarPlusArtwork: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
        }
    }
}

private struct ToolbarImportArtwork: View {
    let phase: Double
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 6))
                path.addLine(to: CGPoint(x: 1, y: 15))
                path.addQuadCurve(to: CGPoint(x: 3, y: 17), control: CGPoint(x: 1, y: 17))
                path.addLine(to: CGPoint(x: 15, y: 17))
                path.addQuadCurve(to: CGPoint(x: 17, y: 15), control: CGPoint(x: 17, y: 17))
                path.addLine(to: CGPoint(x: 17, y: 6))
            }.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ZStack {
                arrow.offset(y: phase * 16)
                arrow.offset(y: (phase - 1) * 16)
            }.frame(width: 14, height: 16).clipped().offset(y: -3)
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }

    private var arrow: some View {
        Path { path in
            path.move(to: CGPoint(x: 7, y: 1))
            path.addLine(to: CGPoint(x: 7, y: 11))
            path.move(to: CGPoint(x: 3.5, y: 7.5))
            path.addLine(to: CGPoint(x: 7, y: 11))
            path.addLine(to: CGPoint(x: 10.5, y: 7.5))
        }.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 16)
    }
}

extension View {
    @ViewBuilder func workspaceWindowTitle(_ title: String) -> some View {
        if #available(macOS 15.0, *) {
            navigationTitle(title).toolbar(removing: .title)
        } else {
            navigationTitle("课屿")
        }
    }
}
