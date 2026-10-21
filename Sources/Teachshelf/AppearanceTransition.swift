import AppKit
import QuartzCore

/// Blend the complete native window so SwiftUI, AppKit tables and the toolbar change together.
@MainActor final class AppearanceTransition {
    static let shared = AppearanceTransition()

    private struct Frame {
        weak var window: NSWindow?
        let overlay: SnapshotView
        let size: NSSize
    }

    private var frames: [Frame] = []
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private let duration: TimeInterval
    private let clock: () -> TimeInterval

    init(duration: TimeInterval = 0.5, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.duration = duration
        self.clock = clock
    }

    deinit { timer?.invalidate() }

    func apply(_ mode: String, animated: Bool) {
        let appearance: NSAppearance?
        switch mode {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        // Multiple SwiftUI scenes can observe the same preference change.
        guard NSApp.appearance?.name != appearance?.name else { return }
        guard animated, NSApp.isActive, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            NSApp.appearance = appearance
            return
        }
        let before = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let wasTransitioning = !frames.isEmpty
        transition(in: NSApp.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.alphaValue > 0 && $0.level == .normal
        }) { NSApp.appearance = appearance }
        if !wasTransitioning, NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == before { finish() }
    }

    func transition(in windows: [NSWindow], changes: () -> Void) {
        // An interrupted fade is captured at its current opacity before the old layer is removed.
        let snapshots = windows.compactMap { window -> (NSWindow, NSView, NSImage)? in
            guard let root = window.contentView?.superview ?? window.contentView,
                  root.bounds.width > 0, root.bounds.height > 0,
                  let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let image = NSImage(size: root.bounds.size)
            image.addRepresentation(bitmap)
            return (window, root, image)
        }
        finish()
        for (window, root, image) in snapshots {
            let overlay = SnapshotView(frame: root.bounds)
            overlay.image = image
            root.addSubview(overlay, positioned: .above, relativeTo: nil)
            frames.append(Frame(window: window, overlay: overlay, size: window.frame.size))
        }
        changes()
        guard !frames.isEmpty else { return }
        // Let the new native appearance and SwiftUI colors render under the old image first.
        startedAt = clock() + 1.0 / 30
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advance() {
        let progress = min(1, max(0, (clock() - startedAt) / duration))
        let eased = progress * progress * (3 - 2 * progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frames.removeAll { frame in
            guard let window = frame.window, window.frame.size == frame.size,
                  window.contentView != nil, frame.overlay.superview != nil, progress < 1 else {
                frame.overlay.removeFromSuperview()
                return true
            }
            frame.overlay.alphaValue = 1 - eased
            return false
        }
        CATransaction.commit()
        if frames.isEmpty { finish() }
    }

    func finish() {
        timer?.invalidate(); timer = nil
        frames.forEach { $0.overlay.removeFromSuperview() }
        frames.removeAll()
    }

    final class SnapshotView: NSImageView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageScaling = .scaleAxesIndependently
            wantsLayer = true
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
