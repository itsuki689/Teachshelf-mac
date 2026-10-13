import AppKit
import SwiftUI

/// Keep SwiftUI's window delegate while protecting file operations and unsaved metadata.
struct WindowCloseGuard: NSViewRepresentable {
    let store: AppStore
    func makeNSView(context: Context) -> GuardView { GuardView(store: store) }
    func updateNSView(_ view: GuardView, context: Context) {}

    @MainActor final class GuardView: NSView {
        let store: AppStore
        var proxy: CloseDelegate?
        init(store: AppStore) { self.store = store; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, proxy == nil else { return }
            let delegate = CloseDelegate(store: store, original: window.delegate)
            proxy = delegate
            window.delegate = delegate
        }
    }

    @MainActor final class CloseDelegate: NSObject, NSWindowDelegate {
        let store: AppStore
        let original: (any NSWindowDelegate)?
        init(store: AppStore, original: (any NSWindowDelegate)?) { self.store = store; self.original = original }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if store.isBusy {
                let alert = NSAlert(); alert.messageText = "正在处理文件"; alert.informativeText = "请等待当前操作完成后关闭窗口。"; alert.runModal()
                return false
            }
            guard store.beforeLeavingMaterial?() != false else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
