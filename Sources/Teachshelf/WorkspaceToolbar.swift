import SwiftUI
import AppKit

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

    private let diameter: CGFloat = 36

    // Native Menu labels normalize SF Symbol metrics and flatten custom SwiftUI drawing.
    // Supply a vector image at its intended size, with explicit appearance variants.
    private static let lightPlusImage = makePlusImage(color: NSColor(white: 0.15, alpha: 1))
    private static let darkPlusImage = makePlusImage(color: NSColor(white: 0.9, alpha: 1))

    private static func makePlusImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            path.move(to: NSPoint(x: rect.midX, y: rect.minY + 2))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
            path.lineWidth = 2.2; path.lineCapStyle = .round
            color.setStroke(); path.stroke()
            return true
        }
        return image
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard store.beforeLeavingMaterial?() != false else { return }
                store.teachingUpdateAll = true; store.teachingConnectionToOpen = nil; store.showingTeachingWebsite = true
            } label: {
                Label("全局更新", systemImage: "arrow.triangle.2.circlepath")
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .help("检查所有已连接课程的网站更新")
            .accessibilityIdentifier("workspace.update")
            .disabled(store.state.teachingConnections.isEmpty)
            Button {
                store.navigate(to: .settings)
                guard store.navigation == .settings, !reduceMotion else { return }
                settingsRotation += 360
            } label: {
                Image(systemName: "gearshape")
                    .rotationEffect(.degrees(settingsRotation))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.42), value: settingsRotation)
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .help("设置")
            .accessibilityLabel("设置")
            .accessibilityIdentifier("workspace.settings")
            Button { store.chooseImport() } label: {
                Label("导入资料", systemImage: "square.and.arrow.down")
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .help("导入文件或文件夹 · ⌘O")
            .accessibilityIdentifier("workspace.import")
            Menu {
                Button("新建课程…", systemImage: "books.vertical") {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.courseToEdit = nil; store.showingCourseEditor = true
                }
                Button("新建计划…", systemImage: "calendar.badge.plus") { store.startToolbarPlan() }
                Divider()
                Button("连接教学网站…", systemImage: "globe") {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.teachingUpdateAll = false; store.teachingConnectionToOpen = nil; store.showingTeachingWebsite = true
                }
            } label: {
                Image(nsImage: colorScheme == .dark ? Self.darkPlusImage : Self.lightPlusImage)
                    .renderingMode(.original)
                    .frame(width: diameter, height: diameter).contentShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .menuIndicator(.hidden).tint(Color.primary)
            .help("新建课程或计划")
            .accessibilityLabel("快捷新建")
            .accessibilityIdentifier("workspace.create")
        }
        .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 16))
        // Each action occupies one diameter; the outer actions share the capsule's round ends.
        .frame(width: diameter * 4, height: diameter).fixedSize()
        .overlay {
            // Keep the toolbar's native glass; only reinforce its edge on light backdrops.
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
