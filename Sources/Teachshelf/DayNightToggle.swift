// Native interpretation of Teftelkin's MEGASWITCHER-3000:
// https://codepen.io/lgmus/pen/gOBoZyd
// Appearance preferences remain owned by AppStore.

import SwiftUI

struct DayNightToggle: View {
    @Binding private var isDark: Bool
    private let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var isVisible = false
    @ViewState private var startedAt = Date()

    init(isDark: Binding<Bool>, width: CGFloat = 160) {
        self._isDark = isDark
        self.width = width
    }

    private var shouldAnimate: Bool {
        isVisible && !reduceMotion && scenePhase == .active && controlActiveState != .inactive
    }

    var body: some View {
        Button { isDark.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !shouldAnimate)) { timeline in
                DayNightArtwork(isDark: isDark,
                                elapsed: shouldAnimate ? timeline.date.timeIntervalSince(startedAt) : 0)
                    .animation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.34, 1.17, duration: 1), value: isDark)
                    .frame(width: 250, height: 100)
                    .scaleEffect(width / 250, anchor: .topLeading)
                    .frame(width: width, height: width * 0.4, alignment: .topLeading)
            }
            .frame(width: width, height: width * 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onAppear { startedAt = Date(); isVisible = true }
        .onDisappear { isVisible = false }
        .help(isDark ? "切换到浅色模式" : "切换到深色模式")
        .accessibilityLabel("日夜外观切换")
        .accessibilityValue(isDark ? "深色" : "浅色")
        .accessibilityHint("按下以切换浅色和深色模式")
    }
}

private struct DayNightArtwork: View {
    let isDark: Bool
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            Color(hex: "#397AB0").opacity(isDark ? 0 : 1)
            Color(hex: "#1C202C").opacity(isDark ? 1 : 0)

            DayNightClouds(back: true)
                .scaleEffect(pulse(period: 8, delay: 5))
                .offset(y: isDark ? 130 : 0)
                .opacity(isDark ? 0 : 1)

            DayNightStars(elapsed: elapsed)
                .offset(y: isDark ? 0 : -150)
                .opacity(isDark ? 1 : 0)

            ZStack {
                ForEach([280.0, 210.0, 140.0], id: \.self) { diameter in
                    Circle().fill(.white.opacity(0.07)).frame(width: diameter, height: diameter)
                }
            }
            .position(x: isDark ? 200 : 50, y: 50)

            DayNightOrb(isDark: isDark, elapsed: elapsed)
                .position(x: isDark ? 200 : 50, y: 50)

            DayNightClouds(back: false)
                .scaleEffect(pulse(period: 10))
                .offset(y: isDark ? 100 : 0)
                .opacity(isDark ? 0 : 1)
        }
        .frame(width: 250, height: 100)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(.black.opacity(0.5), lineWidth: 8)
                .blur(radius: 5).offset(y: 5).clipShape(Capsule())
                .allowsHitTesting(false)
        }
        .overlay {
            Capsule().stroke(.black.opacity(0.3), lineWidth: 8)
                .blur(radius: 9).offset(y: -5).clipShape(Capsule())
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 2, x: 0, y: -3)
        .shadow(color: .white.opacity(isDark ? 0.18 : 0.95), radius: 2, x: 0, y: 3)
        .accessibilityHidden(true)
    }

    private func pulse(period: Double, delay: Double = 0) -> CGFloat {
        1 + 0.025 * (1 - cos((elapsed + delay) * 2 * .pi / period))
    }
}

private struct DayNightOrb: View {
    let isDark: Bool
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            Circle().fill(surface(Color(hex: "#F2C426")))
            moon
                .rotationEffect(.degrees(isDark ? 0 : 50))
                .offset(x: isDark ? 0 : 84)
        }
        .frame(width: 80, height: 80)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.3), radius: 5, x: 4, y: 4)
    }

    private var moon: some View {
        ZStack {
            Circle().fill(surface(Color(hex: "#C5C8CF")))
            ForEach(-1...1, id: \.self) { tile in
                let shift = elapsed.truncatingRemainder(dividingBy: 25) / 25 * 80 + Double(tile) * 80
                crater(size: 28).position(x: 28 + shift, y: 47)
                crater(size: 16).position(x: 40 + shift, y: 20)
                crater(size: 16).position(x: 60 + shift, y: 54)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(Circle())
    }

    private func surface(_ color: Color) -> some ShapeStyle {
        color.shadow(.inner(color: .black.opacity(0.4), radius: 5, x: -2, y: -2))
            .shadow(.inner(color: .white.opacity(0.9), radius: 5, x: 2, y: 2))
    }

    private func crater(size: CGFloat) -> some View {
        Circle().fill(RadialGradient(stops: [
            .init(color: Color(hex: "#969DB0"), location: 0),
            .init(color: Color(hex: "#969DB0"), location: 0.72),
            .init(color: Color(hex: "#798090"), location: 0.9),
            .init(color: Color(hex: "#818899").opacity(0), location: 1)
        ], center: .center, startRadius: 0, endRadius: size / 2))
        .frame(width: size, height: size)
    }
}

private struct DayNightClouds: View {
    let back: Bool
    private var circles: [(x: CGFloat, y: CGFloat, size: CGFloat)] {
        back ? [(247, 37, 90), (202, 59, 50), (177, 77, 70), (147, 105, 90),
                (107, 101, 90), (67, 117, 90), (37, 124, 90)]
             : [(252, 59, 90), (225, 84, 70), (187, 117, 90), (152, 116, 70),
                (117, 109, 66), (72, 114, 70), (42, 134, 90)]
    }

    var body: some View {
        ZStack {
            ForEach(circles.indices, id: \.self) { index in
                let cloud = circles[index]
                Circle().fill(back ? Color(hex: "#A5C5DC") : .white)
                    .frame(width: cloud.size, height: cloud.size)
                    .position(x: cloud.x, y: cloud.y)
            }
        }.frame(width: 250, height: 100)
    }
}

private struct DayNightStars: View {
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            stars([(45, 15), (127, 30)], size: 13.5, period: 7)
            stars([(115, 73)], size: 10, period: 9.1, delay: 2.8)
            stars([(32, 34), (59, 46), (111, 29), (133, 61), (59, 86)], size: 6, period: 5.6, delay: 7)
            stars([(34, 80), (40, 72), (101, 52)], size: 4, period: 11.2, delay: 1.4)
        }.frame(width: 250, height: 100)
    }

    private func stars(_ positions: [(CGFloat, CGFloat)], size: CGFloat, period: Double, delay: Double = 0) -> some View {
        ForEach(positions.indices, id: \.self) { index in
            DayNightStar().fill(.white)
                .frame(width: size, height: size)
                .opacity(0.65 + 0.35 * cos((elapsed + delay) * 2 * .pi / period))
                .position(x: positions[index].0, y: positions[index].1)
        }
    }
}

private struct DayNightStar: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.midX, y = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: x, y: rect.maxY), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: y), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x, y: y))
        path.closeSubpath()
        return path
    }
}
