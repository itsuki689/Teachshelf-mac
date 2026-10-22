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
        #expect(try isGray(sample(content, in: root, at: 0.98)))
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
            #expect(try isGray(sample(content, in: root, at: 0.98)))
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

    @Test(arguments: AppearanceTransitionDirection.allCases)
    func eachDirectionCoversFromItsChosenEdgeAndRevealsFromTheOppositeEdge(direction: AppearanceTransitionDirection) throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var settings = AppearanceTransitionSettings.default
        settings.direction = direction; settings.colorHex = "#4080C0"
        let expected = try color(hex: settings.colorHex)
        var now: TimeInterval = 0
        var changes = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window], settings: settings) { changes += 1; content.color = .black }

        now = 0.2; transition.advance()
        #expect(changes == 0)
        #expect(try matches(sample(content, in: root, from: direction, at: 0.02), expected))
        #expect(try sample(content, in: root, from: direction, at: 0.98).redComponent > 0.9)

        now = 0.4; transition.advance()
        #expect(changes == 1)
        for fraction in [CGFloat(0.02), 0.5, 0.98] {
            #expect(try matches(sample(content, in: root, from: direction, at: fraction), expected))
        }
        now = 0.5; transition.advance()
        now = 0.7; transition.advance()
        #expect(try matches(sample(content, in: root, from: direction, at: 0.02), expected))
        let revealed = try sample(content, in: root, from: direction, at: 0.98)
        #expect(revealed.redComponent < 0.1 && revealed.greenComponent < 0.1 && revealed.blueComponent < 0.1)

        now = 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(changes == 1)
    }

    @Test func anExplicitSRGBDrawingContextPreservesSolidViewAndOverlayColors() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        let expected = try color(hex: "#4080C0")
        let point = root.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), from: content)
        content.color = expected
        let ordinaryView = try pixel(at: point, in: root)
        #expect(matches(ordinaryView, expected))

        var settings = AppearanceTransitionSettings.default
        settings.colorHex = "#4080C0"
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window], settings: settings) { content.color = .black }
        now = 0.4; transition.advance()
        let opaqueOverlay = try pixel(at: point, in: root)
        #expect(matches(opaqueOverlay, ordinaryView))
        #expect(matches(opaqueOverlay, expected))
    }

    @Test(arguments: AppearanceTransitionDirection.allCases)
    func rainbowUsesTenOpaqueColorsInOrderFromTheSelectedEdge(direction: AppearanceTransitionDirection) throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var settings = AppearanceTransitionSettings.default
        settings.direction = direction; settings.colorMode = .rainbow
        // A retained custom single color must not tint the rainbow palette.
        settings.colorHex = "#202020"
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window], settings: settings) { content.color = .black }
        now = 0.4; transition.advance()
        #expect(AppearanceTransitionSettings.rainbowHexes.count == 10)
        let covered = try orderedBandColors(in: root, from: direction)
        for (actual, hex) in zip(covered, AppearanceTransitionSettings.rainbowHexes) {
            #expect(try matches(actual, color(hex: hex)))
        }
        now = 0.5; transition.advance()
        now = 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
    }

    @Test(arguments: [0.5, 2.0])
    func speedScalesTheEntireCoverHoldAndRevealWithoutChangingTheirOrder(speed: Double) throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var settings = AppearanceTransitionSettings.default
        settings.speed = speed
        let total = 1 / speed
        var now: TimeInterval = 0
        var changes = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window], settings: settings) { changes += 1; content.color = .black }

        now = total * 0.39; transition.advance()
        #expect(changes == 0)
        now = total * 0.4; transition.advance()
        #expect(changes == 1)
        #expect(try isGray(sample(content, in: root, at: 0.12)))
        now = total * 0.5; transition.advance()
        now = total * 0.7; transition.advance()
        #expect(try isGray(sample(content, in: root, at: 0.98)))
        #expect(try sample(content, in: root, at: 0.02).redComponent < 0.1)
        now = total * 0.99; transition.advance()
        #expect(overlays(in: root).count == 1)
        now = total * 1.01; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(changes == 1)
    }

    @Test func changedSettingsWaitForTheNextIdleCycleEvenWhenTheCurrentRequestIsReversed() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var original = AppearanceTransitionSettings.default
        original.colorHex = "#4080C0"
        var edited = AppearanceTransitionSettings.default
        edited.direction = .right; edited.speed = 2; edited.colorMode = .rainbow
        let expected = try color(hex: original.colorHex)
        var now: TimeInterval = 0
        var applied: [String] = []
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window], settings: original) { applied.append("superseded"); content.color = .black }
        now = 0.2; transition.advance()
        let before = try sample(content, in: root, from: .top, at: 0.02)
        transition.transition(in: [window], settings: edited) { applied.append("dark"); content.color = .black }
        #expect(try matches(sample(content, in: root, from: .top, at: 0.02), before))
        now = 0.4; transition.advance()
        #expect(applied == ["dark"])
        for actual in try orderedBandColors(in: root, from: .top) { #expect(matches(actual, expected)) }
        now = 0.5; transition.advance()
        now = 0.7; transition.advance()
        let revealing = try orderedBandColors(in: root, from: .top)
        transition.transition(in: [window], settings: edited) { applied.append("reversed"); content.color = .white }
        for (actual, previous) in zip(try orderedBandColors(in: root, from: .top), revealing) {
            #expect(matches(actual, previous))
        }
        now = 1.11; transition.advance()
        #expect(applied == ["dark", "reversed"])
        for actual in try orderedBandColors(in: root, from: .top) { #expect(matches(actual, expected)) }
        now = 1.22; transition.advance()
        now = 1.73; transition.advance()
        #expect(overlays(in: root).isEmpty)

        let start = now
        transition.transition(in: [window], settings: edited) { applied.append("next"); content.color = .black }
        now = start + 0.1; transition.advance()
        #expect(try matches(sample(content, in: root, from: .right, at: 0.02), color(hex: AppearanceTransitionSettings.rainbowHexes[0])))
        #expect(try sample(content, in: root, from: .right, at: 0.98).redComponent > 0.9)
        now = start + 0.201; transition.advance()
        #expect(applied == ["dark", "reversed", "next"])
        for (actual, hex) in zip(try orderedBandColors(in: root, from: .right), AppearanceTransitionSettings.rainbowHexes) {
            #expect(try matches(actual, color(hex: hex)))
        }
        now = start + 0.26; transition.advance()
        now = start + 0.52; transition.advance()
        #expect(overlays(in: root).isEmpty)
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
        return try pixel(at: point, in: root)
    }

    private func sample(_ content: NSView, in root: NSView, from direction: AppearanceTransitionDirection, at fraction: CGFloat) throws -> NSColor {
        let point = root.convert(point(in: content.bounds, from: direction, at: fraction), from: content)
        return try pixel(at: point, in: root)
    }

    private func point(in bounds: NSRect, from direction: AppearanceTransitionDirection, at fraction: CGFloat) -> NSPoint {
        switch direction {
        case .top: return NSPoint(x: bounds.midX, y: bounds.maxY - bounds.height * fraction)
        case .bottom: return NSPoint(x: bounds.midX, y: bounds.minY + bounds.height * fraction)
        case .left: return NSPoint(x: bounds.minX + bounds.width * fraction, y: bounds.midY)
        case .right: return NSPoint(x: bounds.maxX - bounds.width * fraction, y: bounds.midY)
        }
    }

    private func pixel(at point: NSPoint, in root: NSView) throws -> NSColor {
        // AppKit's display cache can return Color LCD bytes tagged as Generic RGB.
        // Draw into a known sRGB destination so palette checks do not depend on the display profile.
        let width = Int(ceil(root.bounds.width)), height = Int(ceil(root.bounds.height))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: -root.bounds.minX, y: -root.bounds.minY)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        root.displayIgnoringOpacity(root.bounds, in: graphics)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let x = Int(point.x - root.bounds.minX), y = height - 1 - Int(point.y - root.bounds.minY)
        let offset = y * context.bytesPerRow + x * 4
        return NSColor(srgbRed: CGFloat(data[offset]) / 255, green: CGFloat(data[offset + 1]) / 255,
                       blue: CGFloat(data[offset + 2]) / 255, alpha: CGFloat(data[offset + 3]) / 255)
    }

    private func orderedBandColors(in root: NSView, from direction: AppearanceTransitionDirection) throws -> [NSColor] {
        try (0..<10).map { index in
            try pixel(at: point(in: root.bounds, from: direction, at: (CGFloat(index) + 0.5) / 10), in: root)
        }
    }

    private func color(hex: String) throws -> NSColor {
        let value = try #require(RGBColor(hex: hex))
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
    }

    private func matches(_ actual: NSColor, _ expected: NSColor) -> Bool {
        abs(actual.redComponent - expected.redComponent) < 0.025
            && abs(actual.greenComponent - expected.greenComponent) < 0.025
            && abs(actual.blueComponent - expected.blueComponent) < 0.025
    }

    private func bandColors(in root: NSView) throws -> [NSColor] {
        try orderedBandColors(in: root, from: .top)
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
