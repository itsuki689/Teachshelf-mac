import AppKit
import SwiftUI

private struct ColorPanelDismissal: ViewModifier {
    @ViewState private var mouseMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard mouseMonitor == nil else { return }
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    let panel = NSColorPanel.shared
                    if panel.isVisible {
                        var window = event.window
                        while let current = window, current !== panel { window = current.parent ?? current.sheetParent }
                        if window == nil { panel.orderOut(nil) }
                    }
                    return event
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                NSColorPanel.shared.orderOut(nil)
            }
            .onDisappear {
                if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
                mouseMonitor = nil
                NSColorPanel.shared.orderOut(nil)
            }
    }
}

extension View {
    func dismissColorPanelAutomatically() -> some View { modifier(ColorPanelDismissal()) }
}
