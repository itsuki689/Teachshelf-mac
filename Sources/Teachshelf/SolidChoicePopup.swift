import AppKit
import SwiftUI

/// A small child window keeps course choices opaque, including their edges and shadow.
struct SolidChoicePopup<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let size: CGSize
    let surface: NSColor
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onDismiss = { isPresented = false }
        if isPresented {
            context.coordinator.show(from: view, title: title, size: size, surface: surface, content: content)
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class PopupPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    final class Coordinator {
        var onDismiss: (() -> Void)?
        private var panel: PopupPanel?
        private var hosting: NSHostingView<Content>?
        private var mouseMonitor: Any?
        private var inactiveObserver: NSObjectProtocol?
        private weak var anchor: NSView?

        func show(from anchor: NSView, title: String, size: CGSize, surface: NSColor, content: Content) {
            guard let parent = anchor.window else { return }
            self.anchor = anchor
            if let panel, let hosting {
                hosting.rootView = content
                place(panel, from: anchor, size: size)
                return
            }

            let panel = PopupPanel(contentRect: CGRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = title
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.animationBehavior = .none
            panel.becomesKeyOnlyIfNeeded = false
            let hosting = NSHostingView(rootView: content)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = surface.cgColor
            hosting.layer?.cornerRadius = 8
            hosting.layer?.masksToBounds = true
            hosting.layer?.borderWidth = 1
            hosting.layer?.borderColor = NSColor.separatorColor.cgColor
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
            place(panel, from: anchor, size: size)
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)

            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                let point = NSEvent.mouseLocation
                guard !panel.frame.contains(point) else { return event }
                let clickedAnchor = self.anchor.map { view in
                    view.window?.convertToScreen(view.convert(view.bounds, to: nil)).contains(point) ?? false
                } ?? false
                self.dismiss()
                // The trigger's second click closes the list without immediately reopening it.
                return clickedAnchor ? nil : event
            }
            inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
                self?.dismiss()
            }
        }

        private func place(_ panel: NSPanel, from anchor: NSView, size: CGSize) {
            guard let parent = anchor.window else { return }
            let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = parent.screen?.visibleFrame ?? rect.insetBy(dx: -size.width, dy: -size.height)
            let x = min(max(rect.minX, screen.minX + 6), screen.maxX - size.width - 6)
            let below = rect.minY - size.height - 5
            let y = below >= screen.minY + 6 ? below : min(rect.maxY + 5, screen.maxY - size.height - 6)
            panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        }

        private func dismiss() {
            close()
            onDismiss?()
        }

        func close() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
            inactiveObserver = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.contentView = nil
            }
            hosting = nil
            panel = nil
            anchor = nil
        }
    }
}
