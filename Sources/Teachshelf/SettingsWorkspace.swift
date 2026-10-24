import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, toolbar, library, backup, assistant, mcp, about
    var id: Self { self }
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .toolbar: return "顶栏"
        case .library: return "资料库"
        case .backup: return "备份"
        case .assistant: return "AI 助手"
        case .mcp: return "MCP"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .toolbar: return "rectangle.topthird.inset.filled"
        case .library: return "externaldrive"
        case .backup: return "clock.arrow.circlepath"
        case .assistant: return "sparkles"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .appearance: return "选择舒适的显示模式，让课屿更合你的习惯。"
        case .toolbar: return "把常用操作放在手边，按你的习惯排列。"
        case .library: return "查看本机资料，管理资料库的位置。"
        case .backup: return "保存一份完整副本，让资料随时可以恢复。"
        case .assistant: return "连接模型，在课屿中用自然语言安排计划、管理资料。"
        case .mcp: return "向外部客户端提供课屿工具，连接计划、课程与资料。"
        case .about: return "每一份知识，都有位置。"
        }
    }
}

struct SettingsWorkspace: View {
    @EnvironmentObject private var store: AppStore
    private var section: SettingsSection { store.settingsSection }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 720 ? 20 : 32
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("设置").font(.system(size: 22, weight: .bold, design: .rounded))
                        Spacer()
                        if store.isBusy { ProgressView().controlSize(.small).help(store.status) }
                    }
                    HStack(spacing: 4) {
                        ForEach(SettingsSection.allCases) { item in
                            SettingsTab(section: item, isSelected: section == item) { store.settingsSection = item }
                        }
                    }.padding(5)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .contain).accessibilityLabel("设置分类")
                }
                .padding(.horizontal, inset).padding(.top, 20).padding(.bottom, 18)
                .frame(maxWidth: 840).frame(maxWidth: .infinity)
                Divider().opacity(0.6)
                ScrollView {
                    SettingsPage(section: section)
                        .padding(.horizontal, inset).padding(.top, 26).padding(.bottom, 32)
                        .frame(maxWidth: 840).frame(maxWidth: .infinity)
                }.id(section)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsTab: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @ViewState private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: section.symbol).font(.system(size: 16, weight: .medium)).frame(height: 18)
                Text(section.title).font(.system(size: 12, weight: isSelected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.ink : Color.secondary)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? theme.ink.opacity(0.18) : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(section.title).accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("settings.tab.\(section.rawValue)")
    }
}

struct SettingsPage: View {
    let section: SettingsSection
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState private var accentSession: AccentEditingSession?
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if section != .about {
                HStack(spacing: 13) {
                    SettingsIcon(symbol: section.symbol, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.padding(.bottom, 2)
            }
            switch section {
            case .appearance: appearancePage
            case .toolbar: ToolbarSettingsControl()
            case .library: libraryPage
            case .backup: backupPage
            case .assistant: AISettingsView(controller: store.assistant, model: store.assistantSettings)
            case .mcp: MCPSettingsView()
            case .about: aboutPage
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $accentSession) { session in
                AccentColorEditor(sessionID: session.id).environmentObject(store)
            }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "显示模式") {
                SettingsCard { AppearanceSettingsControl().padding(20) }
            }
            SettingsGroup(title: "个性配色") {
                SettingsCard {
                    SettingsRow(title: "强调色", detail: "用于按钮、选中项与重点信息。") {
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: store.effectiveAccentHex)).frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(.primary.opacity(0.12)) }.accessibilityHidden(true)
                            Button("调整颜色…") {
                                if let id = store.beginAccentPreview() { accentSession = AccentEditingSession(id: id) }
                            }.disabled(store.accentPreviewID != nil)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "课程色边框", detail: "在侧栏显示每门课程的专属颜色。") {
                        Toggle("课程色边框", isOn: Binding(
                            get: { store.state.showCourseBorders },
                            set: { enabled in store.perform { try store.repository.saveCourseBorders(enabled) } }
                        )).labelsHidden().toggleStyle(.switch).tint(theme.controlAccent)
                    }
                }
                SettingsNote(text: "课程颜色在课程中单独调整，不随强调色改变。")
            }
            SettingsGroup(title: "切换动效", detail: "在浅色与深色之间切换时，使用你喜欢的过渡效果。") {
                SettingsCard { AppearanceTransitionSettingsControl() }
            }
        }.disabled(store.isBusy)
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "当前资料库") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "externaldrive.fill", size: 42)
                            Text(store.repository.root.lastPathComponent).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            Spacer(minLength: 8)
                            SettingsBadge(title: "保存在本机", symbol: "internaldrive")
                        }
                        SettingsCode(text: store.repository.root.path)
                        HStack(spacing: 12) {
                            Button("在 Finder 中打开") { store.openURL(store.repository.root) }
                            Button("复制路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(store.repository.root.path, forType: .string)
                            }.buttonStyle(.borderless)
                        }
                    }.padding(20)
                    SettingsDivider()
                    HStack(spacing: 0) {
                        libraryCount(store.state.courses.count, title: "门课程")
                        Divider().frame(height: 30)
                        libraryCount(store.state.materials.count, title: "份资料")
                        Divider().frame(height: 30)
                        libraryCount(store.state.tasks.count, title: "项计划")
                        Divider().frame(height: 30)
                        libraryCount(store.state.timetableTerms.count, title: "份课表")
                    }.padding(.vertical, 18)
                }
            }
            SettingsGroup(title: "位置与迁移") {
                SettingsCard {
                    SettingsRow(title: "打开其他资料库", detail: "选择一个已有资料库，切换当前工作内容。", symbol: "folder") {
                        Button("选择资料库…") { chooseLocation(migrate: false) }
                    }
                    SettingsDivider()
                    SettingsRow(title: "迁移到新位置", detail: "复制当前资料库，完成后切换到新目录。", symbol: "externaldrive.badge.plus") {
                        Button("迁移资料库…") { chooseLocation(migrate: true) }
                    }
                }.disabled(store.isBusy)
                SettingsNote(text: "迁移时请选择空文件夹。原资料库会保留，外部引用文件仍使用原路径。")
            }
        }
    }

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "备份与恢复") {
                SettingsCard {
                    SettingsRow(title: "导出完整备份", detail: "将当前资料库保存为一个备份包。", symbol: "arrow.up.doc") {
                        Button("导出备份…", action: backup).buttonStyle(.borderedProminent).tint(theme.controlAccent)
                    }
                    SettingsDivider()
                    SettingsRow(title: "从备份恢复", detail: "用已有备份恢复课程、资料与计划。", symbol: "arrow.counterclockwise") {
                        Button("恢复备份…", action: restore)
                    }
                }.disabled(store.isBusy)
            }
            SettingsGroup(title: "备份会保留什么") {
                SettingsCard {
                    SettingsRow(title: "资料库内容", detail: "课程、资料记录、计划、课表，以及外观和顶栏设置。", symbol: "square.stack.3d.up") { EmptyView() }
                    SettingsDivider()
                    SettingsRow(title: "库内文件", detail: "入库副本与作业目录，也包括移除记录后留在库内的文件。", symbol: "doc.on.doc") { EmptyView() }
                }
                SettingsNote(text: "外部引用文件和挂载的作业目录仅保存路径。请单独备份这些原文件。", symbol: "arrow.up.right.square")
            }
            SettingsCard {
                SettingsDisclosure(title: "恢复前的资料会怎样？", symbol: "clock.arrow.circlepath") {
                    Text("恢复会替换当前课程、资料与计划。操作前的索引和文件会保留在原资料库的 History 文件夹中，便于找回。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 18) {
                        SettingsIcon(symbol: "books.vertical.fill", size: 70)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("课屿").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Teachshelf for macOS").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("每一份知识，都有位置。")
                        .font(.system(size: 17, weight: .medium))
                    HStack(spacing: 8) {
                        SettingsBadge(title: "版本 \(version)")
                        Text("构建 \(build)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsGroup(title: "为本机学习与整理而做") {
                SettingsCard {
                    SettingsRow(title: "资料留在本机", detail: "资料、封面与搜索均在本机处理，无需课屿账户。", symbol: "lock.shield") { EmptyView() }
                    SettingsDivider()
                    SettingsRow(title: "文件与目录属于你", detail: "课程资料和作业使用真实目录，可继续通过 Finder 或其他工具管理。", symbol: "folder") { EmptyView() }
                    SettingsDivider()
                    SettingsRow(title: "保留原文件", detail: "移除资料记录或删除课程时，实际文件仍会保留。", symbol: "doc.badge.clock") { EmptyView() }
                }
            }
            SettingsCard {
                SettingsDisclosure(title: "资料的导入与浏览", symbol: "books.vertical") {
                    Text("导入时可复制入库，或引用原文件。列表与封面视图在资料页右上角切换；预览使用 macOS 快速查看，打开文件使用系统默认应用。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func libraryCount(_ count: Int, title: String) -> some View {
        VStack(spacing: 5) {
            Text("\(count)").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
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
        let alert = NSAlert(); alert.messageText = "恢复此备份？"; alert.informativeText = "当前课程、资料和计划将由备份替换。现有文件及索引会保留在资料库的 History 中。"
        alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let repository = store.repository
            Task { await store.runOperation("正在校验并恢复备份…") { try repository.restore(from: url); return "资料库已恢复，恢复前内容已保留" } }
        }
    }
}
