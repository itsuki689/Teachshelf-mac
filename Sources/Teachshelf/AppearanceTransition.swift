import AppKit
import QuartzCore
import TeachshelfCore

/// Cover the native window before changing appearance, then reveal it from the opposite edge.
@MainActor final class AppearanceTransition {
    static let shared = AppearanceTransition()

    private struct Frame {
        weak var window: NSWindow?
        let overlay: BlockOverlay
    }
    private enum Phase {
        case covering(TimeInterval), holding(TimeInterval), revealing(TimeInterval)
    }

    private var frames: [Frame] = []
    private var phase: Phase?
    private var timer: Timer?
    private var pendingChanges: (() -> Void)?
    private var requestedMode: String?
    private var requestGeneration: UInt = 0
    private let baseDuration: TimeInterval
    private var duration: TimeInterval
    private var settings: AppearanceTransitionSettings = .default
    private let clock: () -> TimeInterval

    init(duration: TimeInterval = 0.74, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let duration = max(0.01, duration)
        self.baseDuration = duration
        self.duration = duration
        self.clock = clock
    }

    deinit { timer?.invalidate() }

    func apply(_ mode: String, settings: AppearanceTransitionSettings = .default, animated: Bool) {
        let normalized = ["light", "dark"].contains(mode) ? mode : "system"
        let appearance: NSAppearance? = normalized == "system" ? nil
            : NSAppearance(named: normalized == "dark" ? .darkAqua : .aqua)
        let windows = Self.normalWindows()
        let motionAllowed = settings.isEnabled && NSApp.isActive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if phase != nil, requestedMode == normalized, motionAllowed {
            // A new scene's onAppear may be non-animated. Join it to the existing
            // sweep rather than canceling every other window's transition.
            synchronizeFrames(in: windows)
            if frames.isEmpty { finish() }
            return
        }
        guard animated, motionAllowed else {
            pendingChanges = nil
            finish()
            NSApp.appearance = appearance
            return
        }
        // Actual appearance deliberately lags the requested mode until coverage is opaque.
        // Coalesce scene notifications, but accept a click back to the still-visible mode.
        guard requestedMode != normalized else { return }
        guard phase != nil || NSApp.appearance?.name != appearance?.name else { return }
        requestedMode = normalized
        transition(in: windows, settings: settings) { NSApp.appearance = appearance }
    }

    /// Preview the mask without changing appearance or replacing an in-flight request.
    func preview(settings: AppearanceTransitionSettings) {
        guard settings.isEnabled, phase == nil, NSApp.isActive, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch NSApp.appearance?.name {
        case .darkAqua: requestedMode = "dark"
        case .aqua: requestedMode = "light"
        default: requestedMode = "system"
        }
        transition(in: Self.normalWindows(), settings: settings) {}
    }

    func transition(in windows: [NSWindow], settings value: AppearanceTransitionSettings = .default, changes: @escaping () -> Void) {
        guard value.isEnabled else {
            pendingChanges = nil
            finish()
            changes()
            return
        }
        if phase == nil {
            // Freeze a cycle's palette and timing, including any reversal. Settings
            // edited behind the mask take effect on the next complete cycle.
            settings = value.isValid ? value : .default
            duration = baseDuration / settings.speed
        }
        requestGeneration &+= 1
        pendingChanges = changes
        synchronizeFrames(in: windows)
        guard !frames.isEmpty else { finish(); return }
        switch phase {
        case .covering:
            // Keep the current sweep; only the final requested appearance changes.
            break
        case .holding:
            commitUnderCover()
        case .revealing, nil:
            frames.forEach { $0.overlay.beginCovering() }
            phase = .covering(clock())
        }
        if timer == nil, phase != nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func synchronizeFrames(in windows: [NSWindow]) {
        let allowed = Set(windows.map(ObjectIdentifier.init))
        frames.removeAll { frame in
            guard let window = frame.window, allowed.contains(ObjectIdentifier(window)),
                  let root = Self.root(of: window), frame.overlay.superview === root else {
                frame.overlay.removeFromSuperview()
                return true
            }
            return false
        }
        let reference = frames.first?.overlay
        for window in windows {
            guard !frames.contains(where: { $0.window === window }), let root = Self.root(of: window) else { continue }
            let overlay = BlockOverlay(frame: root.bounds, settings: settings)
            if let reference { overlay.synchronize(with: reference) }
            else if case .holding = phase { overlay.cover() }
            root.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlay.updateLiveRegions(in: root)
            frames.append(Frame(window: window, overlay: overlay))
        }
    }

    func advance() {
        guard let phase else { return }
        frames.removeAll { frame in
            guard let window = frame.window, let root = Self.root(of: window), frame.overlay.superview === root else {
                frame.overlay.removeFromSuperview()
                return true
            }
            if frame.overlay.frame != root.bounds { frame.overlay.frame = root.bounds }
            frame.overlay.updateLiveRegions(in: root)
            return false
        }
        guard !frames.isEmpty else { finish(); return }
        let now = clock()
        switch phase {
        case .covering(let start):
            let progress = min(1, max(0, (now - start) / (duration * 0.4)))
            frames.forEach { $0.overlay.cover(progress: progress) }
            if progress >= 1 {
                commitUnderCover()
            }
        case .holding(let start):
            guard now >= start + duration * 0.1 else { return }
            self.phase = .revealing(start + duration * 0.1)
            advance()
        case .revealing(let start):
            let progress = min(1, max(0, (now - start) / (duration * 0.5)))
            frames.forEach { $0.overlay.reveal(progress: progress) }
            if progress >= 1 { finish() }
        }
    }

    /// Even an interrupted/closed window must leave the latest preference applied.
    func finish() {
        requestGeneration &+= 1
        timer?.invalidate(); timer = nil
        let previous = frames
        frames.removeAll(); phase = nil; requestedMode = nil
        commitPending()
        previous.forEach { $0.overlay.removeFromSuperview() }
    }

    private func commitUnderCover() {
        // Submit the opaque cover before changing native and SwiftUI colors.
        frames.forEach { $0.overlay.cover(); $0.overlay.displayIfNeeded() }
        CATransaction.flush()
        let generation = requestGeneration
        phase = .holding(clock())
        commitPending()
        // Rendering work inside the appearance change must not consume the hold.
        // A reentrant request owns its own phase and must not be overwritten here.
        if requestGeneration == generation { phase = .holding(clock()) }
    }

    private func commitPending() {
        let changes = pendingChanges
        pendingChanges = nil
        changes?()
    }

    private static func root(of window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let root = content.superview ?? content
        return root.bounds.width > 0 && root.bounds.height > 0 ? root : nil
    }

    private static func normalWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.alphaValue > 0 && $0.level == .normal }
    }

    final class BlockOverlay: NSView {
        private static let count = 10
        private(set) var opacities = Array(repeating: CGFloat.zero, count: count)
        private var coveringFrom = Array(repeating: CGFloat.zero, count: count)
        private let direction: AppearanceTransitionDirection
        private let colors: [NSColor]
        private(set) var liveRects: [NSRect] = []

        init(frame frameRect: NSRect, settings: AppearanceTransitionSettings) {
            direction = settings.direction
            let hexes = settings.colorMode == .rainbow ? AppearanceTransitionSettings.rainbowHexes
                : Array(repeating: settings.colorHex, count: Self.count)
            colors = hexes.map { hex in
                let rgb = RGBColor(hex: hex) ?? RGBColor(hex: "#808080")!
                return NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
            }
            super.init(frame: frameRect)
            wantsLayer = true
            autoresizingMask = [.width, .height]
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func updateLiveRegions(in root: NSView) {
            let rects = AppearanceLiveRegion.rectangles(in: root).map { convert($0, from: root) }
            guard rects != liveRects else { return }
            liveRects = rects
            needsDisplay = true
        }

        func beginCovering() { coveringFrom = opacities }
        func synchronize(with other: BlockOverlay) {
            setOpacities(other.opacities)
            coveringFrom = other.coveringFrom
        }
        func cover() { setOpacities(Array(repeating: 1, count: Self.count)) }
        func cover(progress: Double) {
            setOpacities((0..<Self.count).map { index in
                let local = Self.staggered(progress, index: index, spread: 0.6)
                return coveringFrom[index] + (1 - coveringFrom[index]) * local
            })
        }
        func reveal(progress: Double) {
            setOpacities((0..<Self.count).map { index in
                1 - Self.staggered(progress, index: Self.count - 1 - index, spread: 0.55)
            })
        }
        func setOpacities(_ values: [CGFloat]) {
            guard values != opacities else { return }
            opacities = values
            needsDisplay = true
        }
        private static func staggered(_ progress: Double, index: Int, spread: Double) -> CGFloat {
            let start = spread * Double(index) / Double(count - 1)
            let local = min(1, max(0, (progress - start) / (1 - spread)))
            return CGFloat(1 - pow(1 - local, 3))
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }
            let path = CGMutablePath()
            path.addRect(bounds)
            for rect in liveRects {
                path.addRoundedRect(in: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2)
            }
            context.addPath(path)
            context.clip(using: .evenOdd)
            let horizontal = direction == .left || direction == .right
            let step = (horizontal ? bounds.width : bounds.height) / CGFloat(Self.count)
            let reversed = direction == .bottom || direction == .right
            for index in 0..<Self.count where opacities[index] > 0 {
                colors[index].withAlphaComponent(opacities[index]).setFill()
                let slot = CGFloat(reversed ? Self.count - 1 - index : index)
                // Overlap adjacent edges so fractional Retina rows cannot leave seams.
                let rect = horizontal
                    ? NSRect(x: bounds.minX + slot * step, y: bounds.minY, width: step + 1, height: bounds.height)
                    : NSRect(x: bounds.minX, y: bounds.minY + slot * step, width: bounds.width, height: step + 1)
                rect.fill()
            }
        }
    }
}
