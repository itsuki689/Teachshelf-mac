import SwiftUI
import AppKit

@main struct TeachshelfApp: App {
    @NSApplicationDelegateAdaptor(TeachshelfAppDelegate.self) private var delegate
    @StateObject private var store = AppStore.bootstrap()

    var body: some Scene {
        WindowGroup("Teachshelf") {
            ContentView().appTheme().environmentObject(store)
                .preferredColorScheme(store.state.appearance == "dark" ? .dark : store.state.appearance == "light" ? .light : nil)
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1260, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建课程") { store.courseToEdit = nil; store.showingCourseEditor = true }.keyboardShortcut("n")
                Button("导入资料…") { store.chooseImport() }.keyboardShortcut("o")
                Divider()
                Button("打开资料库文件夹") { store.openURL(store.repository.root) }
            }
            CommandGroup(after: .saveItem) {
                Button("保存资料信息") { NotificationCenter.default.post(name: .saveMaterial, object: nil) }.keyboardShortcut("s")
                    .disabled(store.selectedMaterial == nil)
            }
            CommandMenu("资料") {
                Button("打开") { if let m = store.selectedMaterial { store.openMaterial(m) } }.keyboardShortcut(.return, modifiers: .command)
                Button("快速查看") { if let m = store.selectedMaterial { QuickLookController.shared.show(try? store.repository.resolveURL(m)) } }.keyboardShortcut("y")
                Button("在 Finder 中显示") { if let m = store.selectedMaterial, let url = try? store.repository.resolveURL(m) { store.revealURL(url) } }
                Divider()
                Button("收藏 / 取消收藏") { if let m = store.selectedMaterial { store.favorite(m) } }
                Button("移除所选记录…") { store.removeMaterials(store.selectedMaterialIDs) }.disabled(store.selectedMaterialIDs.isEmpty)
                Divider()
                Button("撤销待办删除") { store.undoTaskDeletion() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(!store.canUndoTaskDeletion)
            }
        }
        Settings {
            SettingsWorkspace().appTheme().environmentObject(store)
                .preferredColorScheme(store.state.appearance == "dark" ? .dark : store.state.appearance == "light" ? .light : nil)
                .frame(width: 650, height: 600)
        }
    }
}

@MainActor final class TeachshelfAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isBusy == true {
            let alert = NSAlert(); alert.messageText = "正在处理文件"; alert.informativeText = "请等待当前操作完成后退出。"; alert.runModal()
            return .terminateCancel
        }
        return store?.beforeLeavingMaterial?() == false ? .terminateCancel : .terminateNow
    }
}

extension Notification.Name { static let saveMaterial = Notification.Name("Teachshelf.saveMaterial") }
