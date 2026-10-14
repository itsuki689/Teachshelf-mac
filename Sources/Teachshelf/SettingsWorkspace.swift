import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore

struct SettingsWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState private var accentSession: AccentEditingSession?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 32)).foregroundStyle(theme.ink)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你的学习空间").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Teachshelf for macOS · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0")").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 4)
                settingsCard("外观", symbol: "paintpalette") {
                    HStack {
                        Text("显示模式")
                        Spacer()
                        Picker("显示模式", selection: Binding(get: { store.state.appearance }, set: { value in store.perform { try store.repository.saveAppearance(value) } })) {
                            Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                        }.labelsHidden().pickerStyle(.segmented).tint(theme.controlAccent).frame(width: 260)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7).fill(Color(hex: store.effectiveAccentHex)).frame(width: 32, height: 32)
                            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 1) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("强调色")
                            Text(store.effectiveAccentHex).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("调整强调色…") {
                            if let id = store.beginAccentPreview() { accentSession = AccentEditingSession(id: id) }
                        }.disabled(store.isBusy || store.accentPreviewID != nil)
                    }
                    Toggle("显示课程色边框", isOn: Binding(
                        get: { store.state.showCourseBorders },
                        set: { enabled in store.perform { try store.repository.saveCourseBorders(enabled) } }
                    )).tint(theme.controlAccent)
                    Text("课程标记与边框使用各课程的颜色，强调色用于界面操作。").font(.caption).foregroundStyle(.secondary)
                    Text("列表与封面视图可在资料页右上角切换。文件预览使用 macOS 快速查看。").font(.caption).foregroundStyle(.secondary)
                }
                settingsCard("资料库", symbol: "internaldrive") {
                    Text(store.repository.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    HStack {
                        Button("在 Finder 中打开") { store.openURL(store.repository.root) }
                        Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.repository.root.path, forType: .string) }
                    }
                    Divider()
                    HStack {
                        Button("迁移到新文件夹…") { chooseLocation(migrate: true) }
                        Button("打开其他资料库…") { chooseLocation(migrate: false) }
                    }
                    Text("迁移保留原目录，并记住新的启动位置。打开其他资料库会切换当前内容。使用 --data-dir 启动时，位置切换仅对本次会话生效。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                settingsCard("备份与恢复", symbol: "externaldrive.badge.timemachine") {
                    HStack {
                        Button("导出完整备份…", action: backup)
                        Button("恢复备份…", action: restore)
                    }
                    Text("备份包包含元数据、库内资料、作业目录和删除记录后保留的文件。外部引用及挂载仅保存路径，请另行备份这些文件。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("恢复前的资料库会保留在 History 文件夹中。").font(.caption).foregroundStyle(.secondary)
                }
                settingsCard("文件管理", symbol: "folder") {
                    Label("导入时可复制入库，或引用原文件", systemImage: "doc.on.doc")
                    Label("移除资料记录和删除课程保留实际文件", systemImage: "checkmark.shield")
                    Label("作业文件夹是普通目录，可与编辑器和 agent 共用", systemImage: "folder.badge.gearshape")
                    Label("资料、封面与搜索均在本机处理", systemImage: "lock")
                }
            }.padding(32).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $accentSession) { session in
                AccentColorEditor(sessionID: session.id).environmentObject(store)
            }
    }
    private func settingsCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1) }
    }
    private func chooseLocation(migrate: Bool) {
        guard store.beforeLeavingMaterial?() != false else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = migrate
        panel.message = migrate ? "选择一个空文件夹，原资料库会保留。" : "选择包含 library.json 的已有资料库。"
        panel.prompt = migrate ? "迁移" : "打开资料库"
        if panel.runModal() == .OK, let url = panel.url { Task { await store.changeLibrary(to: url, migrate: migrate) } }
    }
    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Teachshelf-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).teachshelfbackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "teachshelfbackup") ?? .package]
        panel.message = "保存资料库备份包（请选择资料库之外的位置）"
        if panel.runModal() == .OK, let url = panel.url {
            let repository = store.repository
            Task { await store.runOperation("正在备份资料库…") { try repository.backup(to: url); return "备份已保存：\(url.lastPathComponent)" } }
        }
    }
    private func restore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "teachshelfbackup") ?? .package]
        panel.message = "选择 Teachshelf macOS 备份包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "恢复此备份？"; alert.informativeText = "当前课程、资料和待办将由备份替换。现有文件及索引会保留在资料库的 History 中。"
        alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let repository = store.repository
            Task { await store.runOperation("正在校验并恢复备份…") { try repository.restore(from: url); return "资料库已恢复，恢复前内容已保留" } }
        }
    }
}
