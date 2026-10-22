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
            .frame(width: 72, height: 36).fixedSize()
        }
    }
}

struct WorkspaceToolbarActions: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

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
                Button("检查全部网站课程…", systemImage: "arrow.triangle.2.circlepath") {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.teachingUpdateAll = true; store.teachingConnectionToOpen = nil; store.showingTeachingWebsite = true
                }.disabled(store.state.teachingConnections.isEmpty)
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
        // Two tangent circles: each action occupies one diameter of the capsule.
        .frame(width: diameter * 2, height: diameter).fixedSize()
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
