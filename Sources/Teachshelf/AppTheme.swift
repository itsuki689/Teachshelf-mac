import SwiftUI
import AppKit
import TeachshelfCore

struct AppTheme {
    let source: TeachshelfCore.RGBColor
    let inkRGB: TeachshelfCore.RGBColor
    let controlRGB: TeachshelfCore.RGBColor
    let isDark: Bool

    init(hex: String, dark: Bool = false, increasedContrast: Bool = false) {
        source = RGBColor(hex: hex) ?? RGBColor(hex: ColorPalette.defaultAccent)!
        isDark = dark
        let background = RGBColor(hex: dark ? "#242628" : "#FFFFFF")!
        let ratio = increasedContrast ? 7.0 : 4.5
        inkRGB = source.contrasting(on: background, minimumRatio: ratio)
        // Native filled controls use light labels, so keep their tint readable too.
        controlRGB = source.contrasting(on: RGBColor(hex: "#FFFFFF")!, minimumRatio: ratio)
    }

    var accent: Color { Color(rgb: source) }
    var ink: Color { Color(rgb: inkRGB) }
    var controlAccent: Color { Color(rgb: controlRGB) }
    var selection: Color { ink.opacity(isDark ? 0.22 : 0.12) }
    var selectionBorder: Color { ink.opacity(0.65) }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(hex: ColorPalette.defaultAccent)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

private struct AppThemeModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let theme = AppTheme(hex: store.effectiveAccentHex, dark: colorScheme == .dark,
                             increasedContrast: contrast == .increased)
        content.environment(\.appTheme, theme).tint(theme.ink)
    }
}

private struct AppPrimaryButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(theme.controlAccent).foregroundStyle(.white)
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content
            .onAppear { AppearanceTransition.shared.apply(store.state.appearance, animated: false) }
            .onChange(of: store.state.appearance) { _, mode in
                AppearanceTransition.shared.apply(mode, animated: true)
            }
    }
}

extension View {
    func appTheme() -> some View { modifier(AppThemeModifier()) }
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
    func appPrimaryButton() -> some View { modifier(AppPrimaryButtonModifier()) }
}

extension Color {
    init(rgb: TeachshelfCore.RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
