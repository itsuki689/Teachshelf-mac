import SwiftUI

private struct UsesWindowToolbarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesWindowToolbar: Bool {
        get { self[UsesWindowToolbarKey.self] }
        set { self[UsesWindowToolbarKey.self] = newValue }
    }
}

struct WorkspaceCommandBar<Actions: View, Controls: View>: View {
    @Environment(\.usesWindowToolbar) private var usesWindowToolbar
    let title: String
    let subtitle: String
    var countLabel: String?
    var toolbarSubtitle = ""
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        if usesWindowToolbar {
            controls().frame(minHeight: 32)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .navigationSubtitle(toolbarSubtitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) { actions() }
                }
        } else {
            standaloneHeader
        }
    }

    private var standaloneHeader: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                        if let countLabel {
                            Text(countLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                actions()
            }
            controls().frame(minHeight: 32)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
    }
}
