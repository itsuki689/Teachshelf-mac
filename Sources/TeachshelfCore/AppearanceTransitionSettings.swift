import Foundation

public enum AppearanceTransitionDirection: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case top, bottom, left, right

    public var id: Self { self }
    public var title: String {
        switch self {
        case .top: return "从上方"
        case .bottom: return "从下方"
        case .left: return "从左侧"
        case .right: return "从右侧"
        }
    }
    public var symbol: String {
        switch self {
        case .top: return "arrow.down"
        case .bottom: return "arrow.up"
        case .left: return "arrow.right"
        case .right: return "arrow.left"
        }
    }
}

public enum AppearanceTransitionColorMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case solid, rainbow

    public var id: Self { self }
    public var title: String {
        switch self {
        case .solid: return "单色"
        case .rainbow: return "彩虹十色"
        }
    }
}

/// Opaque transition colors and motion preferences travel with the library's appearance.
public struct AppearanceTransitionSettings: Codable, Hashable, Sendable {
    public var direction: AppearanceTransitionDirection
    public var speed: Double
    public var colorMode: AppearanceTransitionColorMode
    public var colorHex: String

    public static let `default` = AppearanceTransitionSettings()
    public static let rainbowHexes = [
        "#E85B65", "#ED8659", "#E8AD4A", "#DFCE58", "#9DC96A",
        "#58B791", "#4DB6BB", "#568CC9", "#7A75C9", "#AE73BD"
    ]

    public init(direction: AppearanceTransitionDirection = .top, speed: Double = 1,
                colorMode: AppearanceTransitionColorMode = .solid, colorHex: String = "#808080") {
        self.direction = direction
        self.speed = speed
        self.colorMode = colorMode
        self.colorHex = colorHex
    }

    public var isValid: Bool {
        speed.isFinite && (0.5...2).contains(speed) && ColorPalette.isStoredColor(colorHex)
    }
}
