import AppKit
import SwiftUI
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct AppearanceTransitionTests {
    @Test func nativeWorkspaceCaptureKeepsItsFrameAndToolbar() throws {
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
        let transition = AppearanceTransition()
        defer { transition.finish() }
        let started = ProcessInfo.processInfo.systemUptime
        transition.transition(in: [window]) { window.appearance = NSAppearance(named: .aqua) }
        print("Native workspace appearance capture: \(ProcessInfo.processInfo.systemUptime - started) seconds")
        #expect(overlays(in: root).count == 1)
        #expect(overlays(in: root).first?.frame == root.bounds)
        #expect(overlays(in: root).first?.liveRects.isEmpty == false)
        transition.finish()
        #expect(overlays(in: root).isEmpty)
        #expect(window.frame == frame)
        #expect(window.toolbar === toolbar)
    }

    @Test func wholeWindowPassesThroughGrayWithoutTakingFocusOrClicks() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        let field = NSTextField(string: "未保存的输入")
        field.frame = NSRect(x: 12, y: 12, width: 120, height: 24)
        content.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder, frame = window.frame
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }

        transition.transition(in: [window]) { content.color = .black }
        let overlay = try #require(root.subviews.compactMap { $0 as? AppearanceTransition.SnapshotView }.first)
        #expect(overlay.hitTest(NSPoint(x: 40, y: 40)) == nil)
        #expect(!overlay.acceptsFirstResponder)
        #expect(window.firstResponder === responder)
        #expect(try centerColor(of: root).redComponent > 0.9)

        now = 0.5; transition.advance()
        let gray = try centerColor(of: root)
        #expect(gray.redComponent > 0.15 && gray.redComponent < 0.9)
        #expect(abs(gray.redComponent - gray.greenComponent) < 0.03)
        #expect(abs(gray.redComponent - gray.blueComponent) < 0.03)

        now = 1.1; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(try centerColor(of: root).redComponent < 0.1)
        #expect(window.frame == frame)
        #expect(field.stringValue == "未保存的输入")
        #expect(window.firstResponder === responder)
    }

    @Test func reversingMidFadeStartsFromTheVisibleGrayAndLeavesNoOverlay() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { content.color = .black }
        now = 0.5; transition.advance()
        let before = try centerColor(of: root).redComponent

        transition.transition(in: [window]) { content.color = .white }
        #expect(overlays(in: root).count == 1)
        #expect(abs(try centerColor(of: root).redComponent - before) < 0.03)
        now += 0.5; transition.advance()
        #expect(try centerColor(of: root).redComponent > before)
        transition.finish()
        now += 2; transition.advance()
        #expect(overlays(in: root).isEmpty)
        #expect(try centerColor(of: root).redComponent > 0.9)
    }

    @Test func resizingCancelsTheSnapshotAndMissingWindowsStillApplyTheChange() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        let transition = AppearanceTransition()
        defer { transition.finish() }
        transition.transition(in: [window]) { content.color = .black }
        #expect(overlays(in: root).count == 1)
        window.setContentSize(NSSize(width: 400, height: 260))
        transition.advance()
        #expect(overlays(in: root).isEmpty)
        var changed = false
        transition.transition(in: []) { changed = true }
        #expect(changed)
    }

    @Test func liveControlChangesImmediatelyWhileItsWindowStillBlends() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        let marker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 130, y: 140, width: 60, height: 30))
        content.addSubview(marker)
        let liveRect = root.convert(marker.bounds, from: marker)
        let livePoint = NSPoint(x: liveRect.midX, y: liveRect.midY)
        let mirroredPoint = NSPoint(x: livePoint.x, y: root.bounds.maxY - livePoint.y)
        let outsidePoint = NSPoint(x: 30, y: livePoint.y)
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { content.color = .black }
        let overlay = try #require(overlays(in: root).first)
        #expect(overlay.liveRects == [liveRect.insetBy(dx: -2, dy: -2)])
        #expect(try color(at: livePoint, in: root).redComponent < 0.1)
        #expect(try color(at: outsidePoint, in: root).redComponent > 0.9)
        #expect(try color(at: mirroredPoint, in: root).redComponent > 0.9)
        now = 0.5; transition.advance()
        #expect(try color(at: livePoint, in: root).redComponent < 0.1)
        let gray = try color(at: outsidePoint, in: root)
        #expect(gray.redComponent > 0.15 && gray.redComponent < 0.9)
    }

    @Test func liveRegionsBelongOnlyToTheirOwnWindow() throws {
        let (first, firstContent, firstRoot) = makeWindow()
        let (second, secondContent, secondRoot) = makeWindow()
        defer { first.close(); second.close() }
        firstContent.addSubview(AppearanceLiveRegion.MarkerView(frame: NSRect(x: 130, y: 70, width: 60, height: 60)))
        secondContent.addSubview(AppearanceLiveRegion.MarkerView(frame: NSRect(x: 10, y: 70, width: 60, height: 60)))
        let transition = AppearanceTransition()
        defer { transition.finish() }
        transition.transition(in: [first, second]) { firstContent.color = .black; secondContent.color = .black }
        #expect(overlays(in: firstRoot).first?.liveRects.count == 1)
        #expect(overlays(in: secondRoot).first?.liveRects.count == 1)
        #expect(try color(at: NSPoint(x: firstRoot.bounds.midX, y: firstRoot.bounds.midY), in: firstRoot).redComponent < 0.1)
        #expect(try color(at: NSPoint(x: 40, y: firstRoot.bounds.midY), in: firstRoot).redComponent > 0.9)
        #expect(try color(at: NSPoint(x: secondRoot.bounds.midX, y: secondRoot.bounds.midY), in: secondRoot).redComponent > 0.9)
        #expect(try color(at: NSPoint(x: 40, y: secondRoot.bounds.midY), in: secondRoot).redComponent < 0.1)
    }

    @Test func movedHiddenAndRemovedMarkersDoNotLeaveStaleHoles() throws {
        let (window, content, root) = makeWindow()
        defer { window.close() }
        var marker: AppearanceLiveRegion.MarkerView? = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 130, y: 70, width: 60, height: 60))
        content.addSubview(marker!)
        var now: TimeInterval = 0
        let transition = AppearanceTransition(duration: 1, clock: { now })
        defer { transition.finish() }
        transition.transition(in: [window]) { content.color = .black }
        let overlay = try #require(overlays(in: root).first)
        #expect(overlay.liveRects.count == 1)
        marker?.setFrameOrigin(NSPoint(x: 10, y: 70))
        now = 0.05; transition.advance()
        #expect(try color(at: NSPoint(x: root.bounds.midX, y: root.bounds.midY), in: root).redComponent > 0.9)
        #expect(try color(at: NSPoint(x: 40, y: root.bounds.midY), in: root).redComponent < 0.1)
        marker?.isHidden = true; transition.advance()
        #expect(overlay.liveRects.isEmpty)
        marker?.isHidden = false; transition.advance()
        #expect(overlay.liveRects.count == 1)
        marker?.removeFromSuperview(); marker = nil
        transition.advance()
        #expect(overlay.liveRects.isEmpty)
        #expect(try color(at: NSPoint(x: 40, y: root.bounds.midY), in: root).redComponent > 0.9)
    }

    @Test func liveRegionRegistryDoesNotRetainMarkers() {
        weak var weakMarker: AppearanceLiveRegion.MarkerView?
        autoreleasepool {
            let marker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
            weakMarker = marker
        }
        #expect(weakMarker == nil)
    }

    private func makeWindow() -> (NSWindow, ColorView, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = ColorView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = content
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, content, content.superview ?? content)
    }

    private func overlays(in view: NSView) -> [AppearanceTransition.SnapshotView] {
        view.subviews.compactMap { $0 as? AppearanceTransition.SnapshotView }
    }

    private func centerColor(of view: NSView) throws -> NSColor {
        try color(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func color(at point: NSPoint, in view: NSView) throws -> NSColor {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = Int((point.x - view.bounds.minX) / view.bounds.width * CGFloat(bitmap.pixelsWide))
        let y = Int((view.bounds.maxY - point.y) / view.bounds.height * CGFloat(bitmap.pixelsHigh))
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private final class ColorView: NSView {
        var color: NSColor = .white { didSet { needsDisplay = true } }
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
    }
}
