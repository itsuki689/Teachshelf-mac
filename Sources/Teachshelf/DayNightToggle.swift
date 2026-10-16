// Native sun, moon, clouds and stars, adapted from the user-provided
// DesignerVsDeveloperDayNightToggle.swift. Appearance is owned by AppStore.

import SwiftUI

struct DayNightToggle: View {
    @Binding private var isDark: Bool
    private let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isDark: Binding<Bool>, width: CGFloat = 160) {
        self._isDark = isDark
        self.width = width
    }

    var body: some View {
        Button {
            isDark.toggle()
        } label: {
            GeometryReader { proxy in
                let scale = proxy.size.width / 250

                artwork
                    .frame(width: 250, height: 100)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
            }
            .frame(width: width, height: width * 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(
            reduceMotion ? nil : .spring(response: 0.82, dampingFraction: 0.79),
            value: isDark
        )
        .help(isDark ? "切换到浅色模式" : "切换到深色模式")
        .accessibilityLabel("日夜外观切换")
        .accessibilityValue(isDark ? "深色" : "浅色")
        .accessibilityHint("按下以切换浅色和深色模式")
    }

    private var artwork: some View {
        ZStack {
            ZStack {
                daySky.opacity(isDark ? 0 : 1)
                nightSky.opacity(isDark ? 1 : 0)
            }

            DayNightStars()
                .opacity(isDark ? 1 : 0)
                .scaleEffect(isDark ? 1 : 0.80)
                .offset(x: isDark ? 0 : -13, y: isDark ? 0 : -12)

            ZStack {
                Circle().fill(.white.opacity(isDark ? 0.040 : 0.075))
                    .frame(width: 194, height: 194)
                Circle().fill(.white.opacity(isDark ? 0.055 : 0.11))
                    .frame(width: 154, height: 154)
                Circle().fill(.white.opacity(isDark ? 0.065 : 0.15))
                    .frame(width: 116, height: 116)
            }
            .position(x: isDark ? 200 : 50, y: 50)

            sunMoonOrb
                .position(x: isDark ? 200 : 50, y: 50)

            DayNightCloudBank(isBackLayer: true)
                .offset(x: isDark ? 30 : 0, y: isDark ? 112 : 0)

            DayNightCloudBank(isBackLayer: false)
                .offset(x: isDark ? 42 : 0, y: isDark ? 130 : 0)
        }
        .frame(width: 250, height: 100)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.black.opacity(isDark ? 0.32 : 0.13), lineWidth: 2)
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(isDark ? 0.12 : 0.40), lineWidth: 1.2)
                .padding(2)
        }
        .shadow(color: .black.opacity(0.20), radius: 9, x: 0, y: 5)
        .accessibilityHidden(true)
    }

    private var daySky: some View {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.54, blue: 0.83),
                Color(red: 0.45, green: 0.78, blue: 0.96)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var nightSky: some View {
        LinearGradient(
            colors: [
                Color(red: 0.085, green: 0.115, blue: 0.19),
                Color(red: 0.17, green: 0.23, blue: 0.36)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var sunMoonOrb: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.86, blue: 0.29),
                            Color(red: 0.99, green: 0.66, blue: 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(isDark ? 0 : 1)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.92, green: 0.94, blue: 0.98),
                            Color(red: 0.71, green: 0.75, blue: 0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(isDark ? 1 : 0)

            ZStack {
                crater(size: 24, x: -16, y: -15)
                crater(size: 15, x: 18, y: 10)
                crater(size: 10, x: -9, y: 22)
            }
            .rotationEffect(.degrees(isDark ? 0 : -90))
            .opacity(isDark ? 1 : 0)

            Circle()
                .strokeBorder(.white.opacity(isDark ? 0.34 : 0.27), lineWidth: 2)
                .padding(3)
        }
        .frame(width: 86, height: 86)
        .shadow(
            color: isDark
                ? .black.opacity(0.30)
                : Color(red: 0.99, green: 0.79, blue: 0.27).opacity(0.48),
            radius: isDark ? 6 : 10,
            x: 0,
            y: 4
        )
    }

    private func crater(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.63, green: 0.69, blue: 0.79).opacity(0.82))
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }
}

private struct DayNightStars: View {
    var body: some View {
        ZStack {
            DayNightStar(x: 26, y: 32, size: 16, sparkle: true)
            DayNightStar(x: 76, y: 17, size: 11, sparkle: true)
            DayNightStar(x: 114, y: 51, size: 13, sparkle: true)
            DayNightStar(x: 146, y: 23, size: 8, sparkle: true)
            DayNightStar(x: 55, y: 69, size: 7, sparkle: true)
            DayNightStar(x: 99, y: 78, size: 5, sparkle: true)
            DayNightStar(x: 34, y: 11, size: 3, sparkle: false)
            DayNightStar(x: 100, y: 28, size: 3, sparkle: false)
            DayNightStar(x: 160, y: 62, size: 3, sparkle: false)
            DayNightStar(x: 137, y: 85, size: 4, sparkle: false)
        }
        .frame(width: 250, height: 100)
    }
}

private struct DayNightStar: View {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let sparkle: Bool

    var body: some View {
        Group {
            if sparkle {
                Image(systemName: "sparkle")
                    .resizable()
                    .scaledToFit()
            } else {
                Circle()
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .shadow(color: .white.opacity(0.70), radius: 3)
        .position(x: x, y: y)
    }
}

private struct DayNightCloudBank: View {
    let isBackLayer: Bool

    private var cloudColor: Color {
        isBackLayer
            ? Color(red: 0.73, green: 0.86, blue: 0.95)
            : Color(red: 0.99, green: 0.995, blue: 1.0)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(cloudColor)
                .frame(width: 220, height: 65)
                .offset(x: isBackLayer ? 85 : 135, y: isBackLayer ? 82 : 84)

            if isBackLayer {
                cloud(diameter: 78, x: 75, y: 49)
                cloud(diameter: 86, x: 110, y: 37)
                cloud(diameter: 84, x: 157, y: 39)
                cloud(diameter: 102, x: 207, y: 18)
            } else {
                cloud(diameter: 62, x: 104, y: 67)
                cloud(diameter: 72, x: 135, y: 62)
                cloud(diameter: 87, x: 170, y: 58)
                cloud(diameter: 76, x: 225, y: 52)
            }
        }
        .frame(width: 250, height: 100, alignment: .topLeading)
    }

    private func cloud(diameter: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(cloudColor)
            .frame(width: diameter, height: diameter)
            .offset(x: x, y: y)
    }
}
