import SwiftUI

struct AppearanceSettingsControl: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveDark: Bool {
        switch store.state.appearance {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    private var darkBinding: Binding<Bool> {
        Binding(get: { effectiveDark }, set: { save($0 ? "dark" : "light") })
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("显示模式").font(.body.weight(.medium))
                Toggle("跟随系统", isOn: Binding(
                    get: { store.state.appearance == "system" },
                    set: { save($0 ? "system" : effectiveDark ? "dark" : "light") }
                )).toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            DayNightToggle(isDark: darkBinding)
                .contextMenu {
                    appearanceChoice("跟随系统", value: "system")
                    Divider()
                    appearanceChoice("浅色", value: "light")
                    appearanceChoice("深色", value: "dark")
                }
        }
        .padding(.vertical, 4)
        .disabled(store.isBusy)
    }

    private func appearanceChoice(_ title: String, value: String) -> some View {
        Button { save(value) } label: {
            if store.state.appearance == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func save(_ value: String) {
        store.perform { try store.repository.saveAppearance(value) }
    }
}
