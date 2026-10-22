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
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveDark: Bool {
        switch preference.mode {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("显示模式").font(.body.weight(.medium))
                Toggle("跟随系统", isOn: Binding(
                    get: { preference.mode == "system" },
                    set: { save($0 ? "system" : effectiveDark ? "dark" : "light") }
                )).toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            AppearanceModeToggle()
        }
        .padding(.vertical, 4)
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
