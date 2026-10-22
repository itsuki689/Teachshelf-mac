import AppKit
import Testing
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct AppearanceLiveRegionTests {
    @Test func registryDoesNotRetainMarkers() {
        weak var weakMarker: AppearanceLiveRegion.MarkerView?
        autoreleasepool {
            let marker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
            weakMarker = marker
        }
        #expect(weakMarker == nil)
    }

    @Test func regionsBelongOnlyToTheirOwnWindowAndRequestedSubtree() {
        let (first, firstRoot) = makeWindow(), (second, secondRoot) = makeWindow()
        defer { first.close(); second.close() }
        let firstMarker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 120, y: 70, width: 60, height: 30))
        let secondMarker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 10, y: 70, width: 60, height: 30))
        firstRoot.addSubview(firstMarker)
        secondRoot.addSubview(secondMarker)
        #expect(AppearanceLiveRegion.rectangles(in: firstRoot) == [expanded(firstMarker, in: firstRoot)])
        #expect(AppearanceLiveRegion.rectangles(in: secondRoot) == [expanded(secondMarker, in: secondRoot)])
        let sibling = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        firstRoot.addSubview(sibling)
        #expect(AppearanceLiveRegion.rectangles(in: sibling).isEmpty)
        #expect(AppearanceLiveRegion.rectangles(in: NSView(frame: firstRoot.bounds)).isEmpty)
    }

    @Test func movedHiddenAndRemovedMarkersDoNotLeaveStaleRegions() {
        let (window, root) = makeWindow()
        defer { window.close() }
        let container = NSView(frame: root.bounds)
        root.addSubview(container)
        let marker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 120, y: 70, width: 60, height: 30))
        container.addSubview(marker)
        let original = AppearanceLiveRegion.rectangles(in: root)
        #expect(original == [expanded(marker, in: root)])
        marker.setFrameOrigin(NSPoint(x: 10, y: 40))
        #expect(AppearanceLiveRegion.rectangles(in: root) == [expanded(marker, in: root)])
        #expect(AppearanceLiveRegion.rectangles(in: root) != original)
        marker.isHidden = true
        #expect(AppearanceLiveRegion.rectangles(in: root).isEmpty)
        marker.isHidden = false; container.isHidden = true
        #expect(AppearanceLiveRegion.rectangles(in: root).isEmpty)
        container.isHidden = false
        #expect(AppearanceLiveRegion.rectangles(in: root) == [expanded(marker, in: root)])
        marker.removeFromSuperview()
        #expect(AppearanceLiveRegion.rectangles(in: root).isEmpty)
    }

    @Test func anOversizedVisibleRectIsClippedToMarkerBoundsAndTheRootEdge() {
        let (window, root) = makeWindow()
        defer { window.close() }
        root.clipsToBounds = true
        let marker = AppearanceLiveRegion.MarkerView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
        marker.clipsToBounds = false
        root.addSubview(marker)
        // Non-clipping marker views inherit an area larger than their own bounds.
        #expect(marker.visibleRect.width > marker.bounds.width)
        #expect(marker.visibleRect.height > marker.bounds.height)
        let regions = AppearanceLiveRegion.rectangles(in: root)
        #expect(regions == [expanded(marker, in: root)])
        #expect(regions.first == NSRect(x: 0, y: 0, width: 62, height: 32))
    }

    private func expanded(_ marker: NSView, in root: NSView) -> NSRect {
        root.convert(marker.bounds, from: marker).insetBy(dx: -2, dy: -2).intersection(root.bounds)
    }

    private func makeWindow() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let size = NSSize(width: 320, height: 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }
}
