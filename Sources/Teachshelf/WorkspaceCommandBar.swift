import SwiftUI

struct WorkspaceCommandBar<Actions: View, Controls: View>: View {
    let title: String
    let subtitle: String
    var countLabel: String?
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var controls: () -> Controls

    var body: some View {
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
