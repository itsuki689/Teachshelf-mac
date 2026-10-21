import SwiftUI

struct WorkspaceToolbarActions: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 0) {
            Button { store.chooseImport() } label: {
                Label("导入资料", systemImage: "square.and.arrow.down")
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .help("导入文件或文件夹 · ⌘O")
            .accessibilityIdentifier("workspace.import")
            Menu {
                Button("新建课程…", systemImage: "books.vertical") {
                    guard store.beforeLeavingMaterial?() != false else { return }
                    store.courseToEdit = nil; store.showingCourseEditor = true
                }
                Button("新建计划…", systemImage: "calendar.badge.plus") { store.startToolbarPlan() }
            } label: {
                Label("快捷新建", systemImage: "plus")
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuIndicator(.hidden).tint(Color.primary)
            .help("新建课程或计划")
            .accessibilityLabel("快捷新建")
            .accessibilityIdentifier("workspace.create")
        }
        .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 16))
        .padding(.horizontal, 3).frame(height: 34).fixedSize()
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
