import AppKit
import SwiftUI

/// Keep animated controls live while an appearance cover masks the rest of their window.
@MainActor struct AppearanceLiveRegion: NSViewRepresentable {
    private final class WeakMarker {
        weak var view: MarkerView?
        init(_ view: MarkerView) { self.view = view }
    }
    private static var markers: [ObjectIdentifier: WeakMarker] = [:]

    func makeNSView(context: Context) -> MarkerView { MarkerView(frame: .zero) }
    func updateNSView(_ nsView: MarkerView, context: Context) {}
    static func dismantleNSView(_ nsView: MarkerView, coordinator: ()) {
        markers.removeValue(forKey: ObjectIdentifier(nsView))
    }

    static func rectangles(in root: NSView) -> [NSRect] {
        markers = markers.filter { $0.value.view != nil }
        let values = markers.values.compactMap { marker -> NSRect? in
            guard let view = marker.view, let window = view.window, window === root.window,
                  view.isDescendant(of: root), !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            // Non-clipping NSViews may report a visibleRect larger than their own bounds.
            let visibleBounds = view.visibleRect.intersection(view.bounds)
            guard !visibleBounds.isEmpty else { return nil }
            let rect = root.convert(visibleBounds, from: view).insetBy(dx: -2, dy: -2).intersection(root.bounds)
            return rect.isEmpty ? nil : rect
        }
        // Even-odd clipping would fill the overlap between two holes. Merge overlaps first.
        var merged: [NSRect] = []
        for var rect in values {
            var index = 0
            while index < merged.count {
                if rect.intersects(merged[index]) {
                    rect = rect.union(merged.remove(at: index)); index = 0
                } else { index += 1 }
            }
            merged.append(rect)
        }
        return merged.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    final class MarkerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            Self.register(self)
            setAccessibilityElement(false); setAccessibilityHidden(true)
        }
        private static func register(_ view: MarkerView) {
            AppearanceLiveRegion.markers[ObjectIdentifier(view)] = WeakMarker(view)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
