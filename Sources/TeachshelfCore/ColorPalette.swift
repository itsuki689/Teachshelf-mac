import Foundation

public struct ColorChoice: Hashable, Sendable {
    public let name: String
    public let hex: String

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }
}

public enum ColorPalette {
    public static let defaultAccent = "#39786B"
    public static let themes: [ColorChoice] = [
        ColorChoice(name: "松柏绿", hex: defaultAccent),
        ColorChoice(name: "湖水青", hex: "#287D8E"),
        ColorChoice(name: "晴空蓝", hex: "#3B72B8"),
        ColorChoice(name: "靛青", hex: "#5555A5"),
        ColorChoice(name: "鸢尾紫", hex: "#8058A1"),
        ColorChoice(name: "玫瑰粉", hex: "#AE567C"),
        ColorChoice(name: "砖红", hex: "#B2534D"),
        ColorChoice(name: "陶土橙", hex: "#AC633C"),
        ColorChoice(name: "琥珀金", hex: "#967326"),
        ColorChoice(name: "橄榄绿", hex: "#6C7E3D"),
        ColorChoice(name: "咖啡棕", hex: "#826452"),
        ColorChoice(name: "石墨灰", hex: "#596574")
    ]

    /// Stored colors retain the original library format: # followed by six ASCII hex digits.
    public static func isStoredColor(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && RGBColor(hex: value) != nil
    }
}

/// An opaque sRGB color independent of AppKit and SwiftUI.
public struct RGBColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    /// Accepts six ASCII hex digits, with one optional leading # and surrounding whitespace.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        let bytes = Array(value.utf8)
        guard bytes.count == 6,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let integer = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((integer >> 16) & 255) / 255,
                  green: Double((integer >> 8) & 255) / 255,
                  blue: Double(integer & 255) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: RGBColor) -> Double {
        let first = relativeLuminance, second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Preserves the color when readable; otherwise changes it as little as possible
    /// along the sRGB segment toward whichever black/white endpoint has greater contrast.
    /// An unattainable ratio returns that endpoint, the most readable available color.
    public func contrasting(on background: RGBColor, minimumRatio: Double) -> RGBColor {
        guard !minimumRatio.isNaN, minimumRatio > 1,
              contrastRatio(with: background) < minimumRatio else { return self }
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let endpoint = black.contrastRatio(with: background) >= white.contrastRatio(with: background) ? black : white
        guard endpoint.contrastRatio(with: background) > minimumRatio else { return endpoint }
        func blended(_ amount: Double) -> RGBColor {
            RGBColor(red: red + (endpoint.red - red) * amount,
                     green: green + (endpoint.green - green) * amount,
                     blue: blue + (endpoint.blue - blue) * amount)
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<60 {
            let middle = (lower + upper) / 2
            if blended(middle).contrastRatio(with: background) >= minimumRatio { upper = middle }
            else { lower = middle }
        }
        return blended(upper)
    }

    private static func clamp(_ component: Double) -> Double {
        component.isNaN ? 0 : max(0, min(1, component))
    }
}
