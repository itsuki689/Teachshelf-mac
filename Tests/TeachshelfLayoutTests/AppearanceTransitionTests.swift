import AppKit
import SwiftUI
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct AppearanceTransitionTests {
    @Test func nativeWorkspaceOverlayKeepsItsFrameAndToolbar() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: try LibraryRepository(root: directory), remembersLocation: false)
        let host = NSHostingView(rootView: ContentView().appTheme().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let root = try #require(host.superview), frame = window.frame
        let toolbar = window.toolbar
        var now: TimeInterval = 0
        var changed = false
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        let started = ProcessInfo.processInfo.systemUptime
        transition.transition(in: [window]) { changed = true; window.appearance = NSAppearance(named: .aqua) }
        print("Native workspace appearance overlay setup: \(ProcessInfo.processInfo.systemUptime - started) seconds")
        #expect(overlays(in: root).count == 1)
        #expect(overlays(in: root).first?.frame == root.bounds)
        #expect(!changed)
        now = 0.4; transition.advance()
        #expect(changed)
        #expect(overlays(in: root).count == 1)
        now = 0.5; transition.advance()
        now = 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(window.frame == frame)
        #expect(window.toolbar === toolbar)
    }

    @Test func grayBandsCoverFromTheTopAndRevealFromTheBottomWithoutTakingFocusOrClicks() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        let field = NSTextField(string: "未保存的输入")
        field.frame = NSRect(x: 12, y: 12, width: 120, height: 24)
        content.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder, frame = window.frame
        var now: TimeInterval = 0
        var changes = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { changes += 1; content.color = .black }
        let overlay = try #require(overlays(in: root).first)
        #expect(overlay.hitTest(NSPoint(x: 40, y: 40)) == nil)
        #expect(!overlay.acceptsFirstResponder)
        #expect(changes == 0)
        #expect(try sample(content, in: root, at: 0.5).redComponent > 0.9)

        now = 0.2; transition.advance()
        #expect(changes == 0)
        #expect(try isGray(sample(content, in: root, at: 0.88)))
        #expect(try sample(content, in: root, at: 0.12).redComponent > 0.9)

        now = 0.4; transition.advance()
        #expect(changes == 1)
        for fraction in [0.12, 0.5, 0.88] {
            #expect(try isGray(sample(content, in: root, at: fraction)))
        }
        now = 0.5; transition.advance()
        #expect(changes == 1)
        #expect(try isGray(sample(content, in: root, at: 0.88)))

        now = 0.75; transition.advance()
        #expect(try isGray(sample(content, in: root, at: 0.88)))
        #expect(try sample(content, in: root, at: 0.12).redComponent < 0.1)

        now = 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(changes == 1)
        #expect(try sample(content, in: root, at: 0.5).redComponent < 0.1)
        #expect(window.frame == frame)
        #expect(field.stringValue == "未保存的输入")
        #expect(window.firstResponder === responder)
    }

    @Test func aNewTargetDuringCoverReplacesThePendingChangeWithoutRestartingTheCover() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var now: TimeInterval = 0
        var applied: [String] = []
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { applied.append("superseded"); content.color = .black }
        now = 0.2; transition.advance()
        let before = try sample(content, in: root, at: 0.88).redComponent
        transition.transition(in: [window]) { applied.append("latest"); content.color = .black }
        #expect(overlays(in: root).count == 1)
        #expect(applied.isEmpty)
        #expect(abs(try sample(content, in: root, at: 0.88).redComponent - before) < 0.03)
        now = 0.4; transition.advance()
        #expect(applied == ["latest"])
        #expect(try isGray(sample(content, in: root, at: 0.12)))
        now = 0.5; transition.advance()
        now = 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(applied == ["latest"])
    }

    @Test func aNewTargetWhileCoveredAppliesUnderTheGrayAndRestartsTheHold() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var now: TimeInterval = 0
        var applied: [String] = []
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { applied.append("dark"); content.color = .black }
        now = 0.4; transition.advance()
        now = 0.46
        transition.transition(in: [window]) { applied.append("light"); content.color = .white }
        #expect(applied == ["dark", "light"])
        #expect(overlays(in: root).count == 1)
        now = 0.54; transition.advance()
        #expect(try isGray(sample(content, in: root, at: 0.12)))
        #expect(try isGray(sample(content, in: root, at: 0.88)))
        now = 0.57; transition.advance()
        now = 1.1; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(applied == ["dark", "light"])
        #expect(try sample(content, in: root, at: 0.5).redComponent > 0.9)
    }

    @Test func theOpaqueHoldStartsAfterTheAppearanceChangeHasFinishedDrawing() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var now: TimeInterval = 0
        var changes = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) {
            changes += 1; content.color = .black
            // Model synchronous native/SwiftUI work while the gray cover is opaque.
            now = 0.7
        }
        now = 0.4; transition.advance()
        #expect(changes == 1)
        let coveredBottom = try sample(content, in: root, at: 0.02).redComponent
        #expect(coveredBottom > 0.3 && coveredBottom < 0.7)
        now = 0.75; transition.advance()
        #expect(abs(try sample(content, in: root, at: 0.02).redComponent - coveredBottom) < 0.01)
        #expect(try isGray(sample(content, in: root, at: 0.88)))
        now = 0.81; transition.advance()
        #expect(try sample(content, in: root, at: 0.02).redComponent < coveredBottom - 0.02)
        #expect(try isGray(sample(content, in: root, at: 0.88)))
        now = 1.31; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(changes == 1)
        #expect(try sample(content, in: root, at: 0.5).redComponent < 0.1)
    }

    @Test func aWindowJoiningDuringRecoverageKeepsEveryBandInSyncOnTheNextFrame() throws {
        let (first, firstContent, firstRoot) = makeWindow()
        let (second, secondContent, secondRoot) = makeWindow()
        defer { first.close(); second.close() }
        secondContent.color = .black
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [first]) { firstContent.color = .black }
        now = 0.4; transition.advance()
        now = 0.5; transition.advance()
        now = 0.75; transition.advance()
        transition.transition(in: [first]) { firstContent.color = .black }
        now = 0.95; transition.advance()
        transition.transition(in: [first, second]) { firstContent.color = .black; secondContent.color = .black }
        let firstOverlay = try #require(overlays(in: firstRoot).first)
        let secondOverlay = try #require(overlays(in: secondRoot).first)
        let nextFrames: [TimeInterval?] = [nil, 0.96, 1.0]
        for instant in nextFrames {
            if let instant { now = instant; transition.advance() }
            // Matching only the current image is insufficient: the next frame
            // must also retain the original partially visible covering baseline.
            #expect(firstOverlay.opacities == secondOverlay.opacities)
            let firstBands = try bandColors(in: firstRoot)
            let secondBands = try bandColors(in: secondRoot)
            for (firstColor, secondColor) in zip(firstBands, secondBands) {
                #expect(abs(firstColor.redComponent - secondColor.redComponent) < 0.004)
                #expect(abs(firstColor.greenComponent - secondColor.greenComponent) < 0.004)
                #expect(abs(firstColor.blueComponent - secondColor.blueComponent) < 0.004)
            }
        }
    }

    @Test func reversingDuringRevealStartsFromTheVisibleBandsAndChangesOnlyAfterCoveringAgain() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var now: TimeInterval = 0
        var applied: [String] = []
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { applied.append("dark"); content.color = .black }
        now = 0.4; transition.advance()
        now = 0.5; transition.advance()
        now = 0.75; transition.advance()
        let before = try [0.12, 0.5, 0.88].map { try sample(content, in: root, at: $0).redComponent }
        transition.transition(in: [window]) { applied.append("light"); content.color = .white }
        #expect(applied == ["dark"])
        #expect(overlays(in: root).count == 1)
        for (index, fraction) in [0.12, 0.5, 0.88].enumerated() {
            #expect(abs(try sample(content, in: root, at: fraction).redComponent - before[index]) < 0.03)
        }
        now = 1.16; transition.advance()
        #expect(applied == ["dark", "light"])
        for fraction in [0.12, 0.5, 0.88] {
            #expect(try isGray(sample(content, in: root, at: fraction)))
        }
        now = 1.27; transition.advance()
        now = 1.78; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(try sample(content, in: root, at: 0.5).redComponent > 0.9)
        #expect(applied == ["dark", "light"])
    }

    @Test func windowsShareTheSameCoverAndRevealAndResizeKeepsEveryEdgeCovered() throws {
        let (first, firstContent, firstRoot) = makeWindow()
        let (second, secondContent, secondRoot) = makeWindow(size: NSSize(width: 440, height: 280))
        defer { first.close(); second.close() }
        var now: TimeInterval = 0
        var changes = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [first, second]) {
            changes += 1; firstContent.color = .black; secondContent.color = .black
        }
        now = 0.2; transition.advance()
        for (content, root) in [(firstContent, firstRoot), (secondContent, secondRoot)] {
            #expect(overlays(in: root).count == 1)
            #expect(try isGray(sample(content, in: root, at: 0.88)))
            #expect(try sample(content, in: root, at: 0.12).redComponent > 0.9)
        }
        first.setContentSize(NSSize(width: 480, height: 320))
        first.contentView?.layoutSubtreeIfNeeded()
        now = 0.3; transition.advance()
        #expect(overlays(in: firstRoot).first?.frame == firstRoot.bounds)
        #expect(changes == 0)
        now = 0.4; transition.advance()
        #expect(changes == 1)
        for (content, root) in [(firstContent, firstRoot), (secondContent, secondRoot)] {
            #expect(try isGray(sample(content, in: root, at: 0.12)))
            #expect(try isGray(sample(content, in: root, at: 0.88)))
        }
        now = 0.5; transition.advance()
        now = 0.75; transition.advance()
        for (content, root) in [(firstContent, firstRoot), (secondContent, secondRoot)] {
            #expect(try isGray(sample(content, in: root, at: 0.88)))
            #expect(try sample(content, in: root, at: 0.12).redComponent < 0.1)
        }
        now = 1.01; transition.advance()
        #expect(overlays(in: firstRoot).isEmpty)
        #expect(overlays(in: secondRoot).isEmpty)
        #expect(changes == 1)
    }

    @Test func finishingOrLosingAllRootsStillAppliesTheLastRequestExactlyOnce() throws {
        let (window, _, root) = makeWindow()
        defer { window.close() }
        let transition = AppearanceTransition(duration: 1)
        var applied: [String] = []
        transition.transition(in: [window]) { applied.append("superseded") }
        transition.transition(in: [window]) { applied.append("latest") }
        transition.finish(); transition.finish(); transition.advance()
        #expect(applied == ["latest"])
        #expect(overlays(in: root).isEmpty)

        transition.transition(in: [window]) { applied.append("missing-root") }
        window.contentView = nil
        transition.advance()
        #expect(applied == ["latest", "missing-root"])
        #expect(overlays(in: root).isEmpty)
        transition.transition(in: []) { applied.append("no-windows") }
        #expect(applied == ["latest", "missing-root", "no-windows"])
        transition.finish()
        #expect(applied == ["latest", "missing-root", "no-windows"])
    }

    private func makeWindow(size: NSSize = NSSize(width: 320, height: 200)) -> (NSWindow, ColorView, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = ColorView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, content, content.superview ?? content)
    }

    private func overlays(in view: NSView) -> [AppearanceTransition.BlockOverlay] {
        view.subviews.compactMap { $0 as? AppearanceTransition.BlockOverlay }
    }

    private func sample(_ content: NSView, in root: NSView, at fraction: CGFloat) throws -> NSColor {
        let point = root.convert(NSPoint(x: content.bounds.midX, y: content.bounds.height * fraction), from: content)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let x = Int((point.x - root.bounds.minX) / root.bounds.width * CGFloat(bitmap.pixelsWide))
        let y = Int((root.bounds.maxY - point.y) / root.bounds.height * CGFloat(bitmap.pixelsHigh))
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func bandColors(in root: NSView) throws -> [NSColor] {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        return try (0..<10).map { index in
            let y = Int((CGFloat(index) + 0.5) / 10 * CGFloat(bitmap.pixelsHigh))
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
        }
    }

    private func isGray(_ color: NSColor) -> Bool {
        color.redComponent > 0.3 && color.redComponent < 0.7
            && abs(color.redComponent - color.greenComponent) < 0.03
            && abs(color.redComponent - color.blueComponent) < 0.03
    }

    private final class ColorView: NSView {
        var color: NSColor = .white { didSet { needsDisplay = true } }
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
    }
}
