import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeachshelfCore

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, library, backup, about
    var id: Self { self }
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .library: return "资料库"
        case .backup: return "备份"
        case .about: return "关于"
        }
    }
    var subtitle: String {
        switch self {
        case .appearance: return "显示模式、强调色与课程标记"
        case .library: return "查看资料库位置，或切换到其他资料库"
        case .backup: return "导出完整备份，或从已有备份恢复"
        case .about: return "课屿版本与文件管理说明"
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, detail: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.detail = detail; self.control = control
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control().fixedSize()
        }.padding(18)
    }
}

private struct SettingsInformationRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(18)
    }
}

private struct SettingsDisclosure<Content: View>: View {
    let title: String
    @ViewState private var isExpanded = false
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                    Spacer(minLength: 0)
                }.padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
            if isExpanded {
                content().padding(.horizontal, 18).padding(.bottom, 18).transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
    }
}

struct SettingsWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @SceneStorage("settings.section") private var selectedSection = SettingsSection.appearance.rawValue
    @ViewState private var accentSession: AccentEditingSession?

    private var section: SettingsSection { SettingsSection(rawValue: selectedSection) ?? .appearance }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.0" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("设置").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isBusy { ProgressView().controlSize(.small).help(store.status) }
                }
                Picker("设置分类", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: 800).frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .appearance: appearancePage
                    case .library: libraryPage
                    case .backup: backupPage
                    case .about: aboutPage
                    }
                }
                .padding(28).frame(maxWidth: 800).frame(maxWidth: .infinity)
            }.id(section)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $accentSession) { session in
            AccentColorEditor(sessionID: session.id).environmentObject(store)
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPanel {
                AppearanceSettingsControl().padding(18)
                panelDivider
                SettingsControlRow("强调色", detail: "按钮、选中项与重点信息") {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: store.effectiveAccentHex))
                            .frame(width: 25, height: 25)
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)) }
                        Button("调整强调色…") {
                            if let id = store.beginAccentPreview() { accentSession = AccentEditingSession(id: id) }
                        }.disabled(store.accentPreviewID != nil)
                    }
                }
                panelDivider
                SettingsControlRow("课程色边框", detail: "在侧栏为课程显示各自的颜色") {
                    Toggle("课程色边框", isOn: Binding(
                        get: { store.state.showCourseBorders },
                        set: { enabled in store.perform { try store.repository.saveCourseBorders(enabled) } }
                    )).labelsHidden().toggleStyle(.switch).tint(theme.controlAccent)
                }
            }.disabled(store.isBusy)
            Text("课程颜色在课程中单独调整，不随强调色改变。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill").font(.system(size: 23))
                            .foregroundStyle(theme.ink).frame(width: 44, height: 44)
                            .background(theme.selection, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("当前资料库").font(.caption).foregroundStyle(.secondary)
                            Text(store.repository.root.lastPathComponent).font(.headline).lineLimit(1)
                        }
                        Spacer()
                        Button("在 Finder 中打开") { store.openURL(store.repository.root) }
                    }
                    Text(store.repository.root.path)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Label("保存在本机", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.repository.root.path, forType: .string)
                        }.buttonStyle(.borderless)
                    }
                }.padding(18)
                panelDivider
                HStack(spacing: 0) {
                    libraryCount(store.state.courses.count, title: "门课程")
                    Divider().frame(height: 32)
                    libraryCount(store.state.materials.count, title: "份资料")
                    Divider().frame(height: 32)
                    libraryCount(store.state.timetableTerms.count, title: "份课表")
                }.padding(.vertical, 16)
            }
            SettingsPanel {
                SettingsControlRow("打开其他资料库", detail: "切换到已有的课屿资料库") {
                    Button("选择资料库…") { chooseLocation(migrate: false) }
                }
                panelDivider
                SettingsControlRow("迁移资料库", detail: "复制到新位置，保留当前目录") {
                    Button("迁移…") { chooseLocation(migrate: true) }
                }
            }.disabled(store.isBusy)
        }
    }

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPanel {
                SettingsControlRow("导出完整备份", detail: "保存课程、计划、入库资料与作业目录") {
                    Button("导出备份…", action: backup).appPrimaryButton()
                }
                panelDivider
                SettingsControlRow("从备份恢复", detail: "恢复前会保留当前资料库的副本") {
                    Button("恢复备份…", action: restore)
                }
            }.disabled(store.isBusy)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("外部引用文件与挂载的作业目录只保存路径，请另行备份原文件。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 4)
            SettingsPanel {
                SettingsDisclosure("备份范围与恢复说明") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("备份包含课程、资料记录、计划、课表、外观设置，以及资料库内的文件和作业目录。")
                        Text("移除记录后仍留在库内的文件也会一起备份。")
                        Text("恢复会替换当前课程、资料与计划；恢复前的内容保存在原资料库的 History 文件夹中。")
                    }.font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPanel {
                HStack(spacing: 16) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 36)).foregroundStyle(theme.ink)
                        .frame(width: 64, height: 64).background(theme.selection, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("课屿").font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Teachshelf for macOS · \(version)").font(.callout).foregroundStyle(.secondary)
                        Text("课程资料与个人计划，留在本机。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(20)
            }
            SettingsPanel {
                SettingsInformationRow(symbol: "lock", title: "本机处理", detail: "资料、封面与搜索均在本机完成，无需课屿账户。")
                panelDivider
                SettingsInformationRow(symbol: "doc.badge.clock", title: "保留原文件", detail: "移除资料记录或删除课程时，实际文件仍会保留。")
                panelDivider
                SettingsInformationRow(symbol: "folder", title: "课程内的作业目录", detail: "作业默认保存在课程文件夹下，可在 Finder、编辑器和其他工具中继续管理。")
            }
            SettingsPanel {
                SettingsDisclosure("资料的导入与浏览") {
                    Text("导入时可复制入库，或引用原文件。列表与封面视图在资料页右上角切换；预览使用 macOS 快速查看，打开文件使用系统默认应用。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var panelDivider: some View { Divider().padding(.horizontal, 18) }

    private func libraryCount(_ count: Int, title: String) -> some View {
        VStack(spacing: 4) {
            Text("\(count)").font(.system(size: 21, weight: .semibold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
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
