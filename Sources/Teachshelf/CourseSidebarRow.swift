import SwiftUI
import TeachshelfCore

/// The course's own colour paints the pixel tide; the app accent remains the selection base.
struct CourseSidebarRow: View {
    let course: Course
    let count: Int
    let isSelected: Bool
    let showBorders: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var isHovered = false
    @ViewState private var isVisible = false
    @ViewState private var wave = CoursePixelTide()

    private var isWindowActive: Bool {
        scenePhase == .active && controlActiveState != .inactive
    }

    private var shouldAnimate: Bool {
        isVisible && isWindowActive && !reduceMotion && wave.phase != .idle && wave.phase != .settled
    }

    private var showsCount: Bool { isHovered || isSelected }
    private var countWidth: CGFloat { max(40, CGFloat(String(count).count) * 7 + 20) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onEdit) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: course.colorHex))
                    .frame(width: 12, height: 12)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("调整\(course.name)的课程颜色")
            .help("调整课程颜色")

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Text(course.name).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .fontWeight(isSelected ? .semibold : .regular)
                // Reserve the panel's space so the title never reflows on hover.
                .padding(.trailing, countWidth + 8)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(course.name)
            .accessibilityValue("\(count) 份资料\(isSelected ? "，当前课程" : "")")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .frame(height: 38)
        .background {
            ZStack {
                if isSelected {
                    theme.selection
                } else if isHovered {
                    theme.selection.opacity(0.45)
                }
                if !reduceMotion {
                    pixelBackground.clipped().padding(.trailing, countWidth)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            ZStack(alignment: .leading) {
                Color(hex: course.colorHex).opacity(theme.isDark ? 0.24 : 0.16)
                Rectangle().fill(Color(hex: course.colorHex)).frame(width: 2)
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: countWidth, height: 38)
            .offset(x: showsCount ? 0 : countWidth + 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: showsCount)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            if showBorders {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(hex: course.colorHex).opacity(isSelected || isHovered ? 0.72 : 0.50), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .onHover { hovering in
            isHovered = hovering
            guard !reduceMotion, isWindowActive, !isSelected else { return }
            let now = Date()
            if hovering {
                // An old selected row finishes its retreat before a new hover tide starts.
                guard wave.phase != .retracting else { return }
                wave = CoursePixelTide(phase: .hover, startedAt: now,
                                       initialProgress: wave.progress(at: now))
            } else if wave.phase != .idle && wave.phase != .retracting {
                wave = CoursePixelTide(phase: .receding, startedAt: now,
                                       initialProgress: wave.progress(at: now))
            }
        }
        .onAppear {
            isVisible = true
            wave = CoursePixelTide(phase: isSelected ? .settled : .idle)
        }
        .onDisappear {
            isVisible = false
            isHovered = false
            wave = CoursePixelTide()
        }
        .onChange(of: isSelected) { _, selected in
            guard !reduceMotion, isVisible, isWindowActive else {
                wave = CoursePixelTide(phase: selected ? .settled : .idle)
                return
            }
            let now = Date()
            wave = selected
                ? CoursePixelTide(phase: .selecting, startedAt: now,
                                 initialProgress: wave.progress(at: now))
                : CoursePixelTide(phase: .retracting, startedAt: now,
                                  initialProgress: wave.progress(at: now))
        }
        .onChange(of: controlActiveState) { _, _ in settleInactiveWindow() }
        .onChange(of: scenePhase) { _, _ in settleInactiveWindow() }
        .onChange(of: reduceMotion) { _, _ in
            wave = CoursePixelTide(phase: isSelected ? .settled : .idle)
        }
        .task(id: wave) { @MainActor in
            guard let duration = wave.finishAfter else { return }
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            if isSelected {
                wave = wave.settled(at: Date())
            } else if isHovered && isWindowActive && !reduceMotion {
                // Once a hover front reaches the divider, leave a static mosaic.
                wave = wave.phase == .hover ? wave.settled(at: Date()) : CoursePixelTide(phase: .hover)
            } else {
                wave = CoursePixelTide()
            }
        }
    }

    @ViewBuilder private var pixelBackground: some View {
        if shouldAnimate {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                pixelCanvas(at: timeline.date)
            }
        } else if wave.phase == .settled {
            // Hover and selection stop scheduling frames after reaching the divider.
            pixelCanvas(at: wave.startedAt)
        }
    }

    private func pixelCanvas(at date: Date) -> some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            wave.draw(in: &context, size: size, at: date,
                      accent: Color(hex: course.colorHex), dark: theme.isDark)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func settleInactiveWindow() {
        guard !isWindowActive else { return }
        isHovered = false
        wave = CoursePixelTide(phase: isSelected ? .settled : .idle)
    }
}

/// Time-derived frames avoid publishing row state 30 times a second.
private struct CoursePixelTide: Hashable {
    enum Phase: Hashable { case idle, hover, selecting, settled, receding, retracting }

    var phase: Phase = .idle
    var startedAt: Date = Date()
    var initialProgress: Double = 0
    var stoppedAt: Date?

    private static let tile: Double = 6
    private static let advanceDuration: Double = 4.6

    var finishAfter: Double? {
        switch phase {
        case .hover, .selecting: return max(0.04, (1 - initialProgress) * Self.advanceDuration + 0.12)
        case .receding: return max(0.04, initialProgress * 1.1)
        case .retracting: return max(0.04, initialProgress * 0.72)
        default: return nil
        }
    }

    func progress(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        switch phase {
        case .idle: return 0
        case .settled: return 1
        case .hover, .selecting:
            return min(1, initialProgress + elapsed / Self.advanceDuration)
        case .receding: return max(0, initialProgress - elapsed / 1.1)
        case .retracting: return max(0, initialProgress - elapsed / 0.72)
        }
    }

    func settled(at date: Date) -> Self {
        var result = self
        result.phase = .settled
        result.stoppedAt = date
        return result
    }

    func draw(in context: inout GraphicsContext, size: CGSize, at date: Date, accent: Color, dark: Bool) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }
        let elapsed = max(0, (stoppedAt ?? date).timeIntervalSince(startedAt))
        let progress = progress(at: date)
        guard progress > 0 else { return }
        let rows = max(1, Int(ceil(height / Self.tile)))
        let full = phase == .settled || ((phase == .hover || phase == .selecting) && progress >= 1)
        let plainEdge = phase == .retracting || phase == .receding

        for row in 0..<rows {
            let offset = full || plainEdge ? 0 : jaggedOffset(row: row, elapsed: elapsed, seed: 0)
            let end = min(width, max(0, width * progress + offset))
            guard end > 0 else { continue }
            let columns = Int(ceil(end / Self.tile))
            for column in 0..<columns {
                let x = Double(column) * Self.tile
                let y = Double(row) * Self.tile
                let rect = CGRect(x: x, y: y, width: min(Self.tile, end - x), height: min(Self.tile, height - y))
                let hash = cellHash(column: column, row: row)
                let breath = sin(elapsed * (0.5 + hash * 0.7) + hash * 40)
                let fillOpacity = (dark ? 0.16 : 0.10) + (breath + 1) * 0.018
                context.fill(Path(rect), with: .color(accent.opacity(fillOpacity)))
                // Paired light/dark grid strokes create a restrained embossed mosaic.
                let line = breath > 0.45 ? Color.white.opacity(dark ? 0.10 : 0.42) : accent.opacity(dark ? 0.20 : 0.12)
                context.stroke(Path(rect.insetBy(dx: 0.3, dy: 0.3)), with: .color(line), lineWidth: 0.6)
            }
        }

        guard phase == .hover || phase == .selecting else { return }
        drawFront(in: &context, rows: rows, size: size,
                  x: width * (initialProgress + elapsed / Self.advanceDuration), elapsed: elapsed,
                  seed: 0, accent: accent)
    }

    private func drawFront(in context: inout GraphicsContext, rows: Int, size: CGSize,
                           x: Double, elapsed: Double, seed: Double, accent: Color) {
        var previousX: Double?
        for row in 0..<rows {
            let front = x + jaggedOffset(row: row, elapsed: elapsed, seed: seed)
            guard front >= 0, front < size.width - 1 else {
                previousX = nil
                continue
            }
            let pixelX = min(floor(front / Self.tile) * Self.tile + Self.tile - 1, size.width - 1)
            let y = Double(row) * Self.tile
            let edge = CGRect(x: pixelX, y: y, width: 1, height: min(Self.tile, size.height - y))
            context.fill(Path(edge), with: .color(accent.opacity(0.48)))
            if let previousX, abs(previousX - pixelX) > 0.1 {
                let join = CGRect(x: min(previousX, pixelX), y: max(0, y - 1),
                                  width: abs(previousX - pixelX) + 1, height: 1)
                context.fill(Path(join), with: .color(accent.opacity(0.48)))
            }
            previousX = pixelX
        }
    }

    private func jaggedOffset(row: Int, elapsed: Double, seed: Double) -> Double {
        Self.tile * (1.6 * sin(Double(row) * 0.9 + seed + elapsed * 1.1)
                     + 0.7 * sin(Double(row) * 2.3 + seed * 2 + elapsed * 0.6)).rounded()
    }

    private func cellHash(column: Int, row: Int) -> Double {
        let value = sin(Double(column) * 12.9898 + Double(row) * 78.233) * 43758.5453
        return value - floor(value)
    }
}
