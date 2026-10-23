import SwiftUI
import TeachshelfCore

struct ToolbarSettingsControl: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: ToolbarSettings { store.state.toolbarSettings }
    private var availableActions: [ToolbarAction] {
        ToolbarAction.allCases.filter { !settings.actions.contains($0) }
    }
    private var canAddAction: Bool { settings.actions.count < ToolbarSettings.maximumActionCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "实时预览", detail: "图标按下方顺序从左到右显示，胶囊随数量自动伸缩。") {
                SettingsCard {
                    VStack(spacing: 18) {
                        HStack {
                            SettingsBadge(title: "\(settings.actions.count) / \(ToolbarSettings.maximumActionCount) 个图标")
                                .accessibilityLabel("已选择 \(settings.actions.count) 个图标，最多 \(ToolbarSettings.maximumActionCount) 个")
                            Spacer()
                            Button("恢复默认") { save(.default) }
                                .buttonStyle(.borderless).controlSize(.small)
                                .disabled(settings == .default)
                                .accessibilityIdentifier("settings.toolbar.reset")
                        }
                        HStack(spacing: 18) {
                            HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.25)).frame(width: 7, height: 7) } }
                                .accessibilityHidden(true)
                            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.045)).frame(maxWidth: .infinity).frame(height: 26)
                                .accessibilityHidden(true)
                            capsulePreview
                        }.padding(16).frame(height: 78)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("settings.toolbar.preview")
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: settings.actions)
                    }.padding(20)
                }
            }
            SettingsGroup(title: "已选操作", detail: "使用箭头调整顺序，点击减号移除。") {
                SettingsCard {
                    if settings.actions.isEmpty {
                        SettingsRow(title: "尚未选择操作", detail: "从下方添加图标，即可重新显示顶栏胶囊。", symbol: "plus.circle") { EmptyView() }
                    } else {
                        ForEach(Array(settings.actions.enumerated()), id: \.element) { index, action in
                            selectedRow(action, at: index)
                            if index < settings.actions.count - 1 { SettingsDivider() }
                        }
                    }
                }
            }
            SettingsGroup(title: "添加操作", detail: canAddAction ? "选择你常用的功能，最多显示 \(ToolbarSettings.maximumActionCount) 个。" : "已达 \(ToolbarSettings.maximumActionCount) 个上限，移除一个操作后可继续添加。") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(availableActions) { action in
                        Button { add(action) } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(symbol: action.symbol, size: 30)
                                Text(action.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "plus.circle").font(.system(size: 16)).foregroundStyle(theme.ink)
                            }.padding(14).frame(maxWidth: .infinity, minHeight: 58)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.07)) }
                                .contentShape(RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(.plain).foregroundStyle(.primary)
                            .disabled(!canAddAction).opacity(canAddAction ? 1 : 0.5)
                            .accessibilityLabel("添加\(action.title)")
                            .accessibilityIdentifier("settings.toolbar.add.\(action.rawValue)")
                    }
                }
                SettingsNote(text: "即使移除设置图标，也可随时按 ⌘, 打开设置。", symbol: "keyboard")
            }
        }.disabled(store.isBusy)
    }

    @ViewBuilder private var capsulePreview: some View {
        if settings.actions.isEmpty {
            Label("胶囊已隐藏", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 0) {
                ForEach(settings.actions) { action in
                    Image(systemName: action.symbol).font(.system(size: 16, weight: .regular)).frame(width: 34, height: 36)
                }
            }.foregroundStyle(.primary)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.1)) }
                .shadow(color: .black.opacity(theme.isDark ? 0.12 : 0.05), radius: 3, y: 2)
                .accessibilityElement(children: .ignore).accessibilityLabel("胶囊预览")
                .accessibilityValue(settings.actions.map(\.title).joined(separator: "、"))
        }
    }

    private func selectedRow(_ action: ToolbarAction, at index: Int) -> some View {
        HStack(spacing: 9) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18)
            Image(systemName: action.symbol).font(.system(size: 15)).frame(width: 21)
            Text(action.title).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Button { move(action, by: -1) } label: {
                Image(systemName: "arrow.up").frame(width: 24, height: 26)
            }
            .disabled(index == 0)
            .help("上移\(action.title)")
            .accessibilityLabel("上移\(action.title)")
            .accessibilityIdentifier("settings.toolbar.up.\(action.rawValue)")
            Button { move(action, by: 1) } label: {
                Image(systemName: "arrow.down").frame(width: 24, height: 26)
            }
            .disabled(index == settings.actions.count - 1)
            .help("下移\(action.title)")
            .accessibilityLabel("下移\(action.title)")
            .accessibilityIdentifier("settings.toolbar.down.\(action.rawValue)")
            Button { remove(action) } label: {
                Image(systemName: "minus.circle").frame(width: 24, height: 26)
            }
            .help("移除\(action.title)")
            .accessibilityLabel("移除\(action.title)")
            .accessibilityIdentifier("settings.toolbar.remove.\(action.rawValue)")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 20).frame(height: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.toolbar.selected.\(action.rawValue)")
    }

    private func add(_ action: ToolbarAction) {
        guard canAddAction, !settings.actions.contains(action) else { return }
        save(ToolbarSettings(actions: settings.actions + [action]))
    }

    private func remove(_ action: ToolbarAction) {
        save(ToolbarSettings(actions: settings.actions.filter { $0 != action }))
    }

    private func move(_ action: ToolbarAction, by offset: Int) {
        var actions = settings.actions
        guard let index = actions.firstIndex(of: action), actions.indices.contains(index + offset) else { return }
        actions.swapAt(index, index + offset)
        save(ToolbarSettings(actions: actions))
    }

    private func save(_ value: ToolbarSettings) {
        guard !store.isBusy, value != settings else { return }
        store.perform { try store.repository.saveToolbarSettings(value) }
    }
}
