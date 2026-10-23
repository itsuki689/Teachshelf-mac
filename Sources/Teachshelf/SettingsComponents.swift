import SwiftUI

/// Shared spacing and surfaces for the workspace and the standalone settings window.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)).allowsHitTesting(false) }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    var detail = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 2)
            content()
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail = ""
    var symbol: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                label.frame(minWidth: 180, alignment: .leading)
                Spacer(minLength: 12)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: 14) {
                label
                control()
            }
        }.padding(20)
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol { SettingsIcon(symbol: symbol, size: 32) }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    var size: CGFloat = 40
    @Environment(\.appTheme) private var theme
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(theme.ink).frame(width: size, height: size)
            .background(theme.selection, in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct SettingsBadge: View {
    let title: String
    var symbol: String? = nil
    @Environment(\.appTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }.font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.ink).padding(.horizontal, 9).padding(.vertical, 5)
            .background(theme.selection, in: Capsule()).fixedSize()
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().opacity(0.65).padding(.horizontal, 20) }
}

struct SettingsNote: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).padding(.top, 1)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCode: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    var symbol = "info.circle"
    @ViewBuilder var content: () -> Content
    @ViewState private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
                }.padding(20).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
            if isExpanded {
                content().padding(.horizontal, 20).padding(.bottom, 20).transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
    }
}
