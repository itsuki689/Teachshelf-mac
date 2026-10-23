import SwiftUI

struct AppearanceSettingsControl: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        AppearanceSettingsBody(preference: store.appearancePreference, save: store.requestAppearance)
            .disabled(store.isBusy)
    }
}

private struct AppearanceSettingsBody: View {
    @ObservedObject var preference: AppearancePreference
    let save: (String) -> Void
    @Environment(\.appTheme) private var theme
    private let modes = [("light", "浅色", "sun.max"), ("dark", "深色", "moon"), ("system", "跟随系统", "desktopcomputer")]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(modes, id: \.0) { mode in
                    Button { save(mode.0) } label: {
                        VStack(spacing: 10) {
                            AppearanceThumbnail(mode: mode.0)
                            HStack(spacing: 6) {
                                Image(systemName: mode.2).font(.system(size: 12))
                                Text(mode.1).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 0)
                                Image(systemName: preference.mode == mode.0 ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(preference.mode == mode.0 ? theme.ink : Color.secondary.opacity(0.35))
                            }
                        }.padding(10)
                            .foregroundStyle(preference.mode == mode.0 ? theme.ink : .primary)
                            .background(preference.mode == mode.0 ? theme.selection : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(preference.mode == mode.0 ? theme.selectionBorder : Color.primary.opacity(0.08), lineWidth: 1) }
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("\(mode.1)显示模式")
                        .accessibilityValue(preference.mode == mode.0 ? "已选中" : "未选中")
                        .accessibilityIdentifier("settings.appearance.\(mode.0)")
                }
            }
            SettingsNote(text: "跟随系统会自动匹配 macOS 外观。所有显示设置随当前资料库保存。")
        }
    }
}

private struct AppearanceThumbnail: View {
    let mode: String
    @Environment(\.appTheme) private var theme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature(dark: false)
                if mode != "light" {
                    miniature(dark: true).mask(alignment: .trailing) {
                        Rectangle().frame(width: mode == "system" ? geometry.size.width / 2 : geometry.size.width)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.1)) }
        }.frame(height: 76).accessibilityHidden(true)
    }
    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(dark ? Color.white.opacity(0.2) : .black.opacity(0.15)).frame(width: 4, height: 4) } }
                    .padding(.bottom, 6)
                RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(dark ? 0.55 : 0.3)).frame(height: 7)
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.12) : .black.opacity(0.07)).frame(height: 5)
                Spacer(minLength: 0)
            }.padding(8).frame(width: 46).background(dark ? Color(white: 0.2) : Color(white: 0.91))
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.3) : .black.opacity(0.2)).frame(width: 30, height: 5)
                RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(dark ? 0.35 : 0.12)).frame(height: 15)
                RoundedRectangle(cornerRadius: 3).fill(dark ? Color.white.opacity(0.07) : .black.opacity(0.04)).frame(height: 15)
            }.padding(9).frame(maxWidth: .infinity).frame(height: 76).background(dark ? Color(white: 0.13) : .white)
        }
    }
}

/// The target is published independently so the control can move before disk work finishes.
struct AppearanceModeToggle: View {
    @EnvironmentObject private var store: AppStore
    var width: CGFloat = 100

    var body: some View {
        AppearanceModeToggleBody(preference: store.appearancePreference, width: width, save: store.requestAppearance)
            .disabled(store.isBusy)
    }
}

private struct AppearanceModeToggleBody: View {
    @ObservedObject var preference: AppearancePreference
    let width: CGFloat
    let save: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveDark: Bool {
        switch preference.mode {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    var body: some View {
        DayNightToggle(isDark: Binding(get: { effectiveDark }, set: { save($0 ? "dark" : "light") }), width: width)
            .contextMenu {
                appearanceChoice("跟随系统", value: "system")
                Divider()
                appearanceChoice("浅色", value: "light")
                appearanceChoice("深色", value: "dark")
            }
    }

    private func appearanceChoice(_ title: String, value: String) -> some View {
        Button { save(value) } label: {
            if preference.mode == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}
