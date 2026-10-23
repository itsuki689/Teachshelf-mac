import Foundation

extension LibraryRepository {
    public func saveAppearance(_ value: String) throws {
        guard ["system", "light", "dark"].contains(value) else { throw LibraryError.invalidInput("未知的外观设置。") }
        try commit { $0.appearance = value }
    }

    public func saveAppearanceTransition(_ value: AppearanceTransitionSettings) throws {
        guard let color = RGBColor(hex: value.colorHex) else {
            throw LibraryError.invalidInput("请输入六位 HEX 过渡颜色，例如 #808080。")
        }
        var value = value
        value.colorHex = color.hex
        guard value.isValid else { throw LibraryError.invalidInput("过渡速度须在 0.5× 至 2× 之间。") }
        try commit { $0.appearanceTransition = value }
    }

    public func saveToolbarSettings(_ value: ToolbarSettings) throws {
        guard value.isValid else { throw LibraryError.invalidInput("顶栏最多放置 6 个不重复的快捷操作。") }
        try commit { $0.toolbarSettings = value }
    }

    public func saveAccentColor(_ value: String) throws {
        guard let color = RGBColor(hex: value) else { throw LibraryError.invalidInput("请输入六位 HEX 颜色，例如 #39786B。") }
        try commit { $0.accentColor = color.hex }
    }

    public func saveCourseBorders(_ enabled: Bool) throws {
        try commit { $0.showCourseBorders = enabled }
    }
}
