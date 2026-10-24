import SwiftUI

struct LibraryShortcut: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    let title: String
    let symbol: String
    let selected: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.ink : Color.primary.opacity(0.8))
                .scaleEffect(hovered && !reduceMotion ? 1.06 : 1)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? theme.selection : (hovered ? theme.ink.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? theme.ink.opacity(0.18) : .clear, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "当前视图" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(hint)
    }
}

struct SidebarDestinationButton: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    let title: String
    let symbol: String
    let selected: Bool
    let count: Int?
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 9) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 14 : 17, weight: selected ? .semibold : .regular))
                    .frame(width: compact ? 16 : 18)
                Text(title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: compact ? 0 : 4)
                if let count, count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }.font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, compact ? 8 : 10).frame(height: compact ? 30 : 36)
                .foregroundStyle(.primary)
                .background(selected ? theme.selection : (hovered ? theme.ink.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "当前页面" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
