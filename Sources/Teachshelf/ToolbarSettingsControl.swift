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
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("操作胶囊").font(.headline)
                Spacer()
                Button("恢复默认") { save(.default) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(settings == .default)
                    .accessibilityIdentifier("settings.toolbar.reset")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("预览").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(settings.actions.count) / \(ToolbarSettings.maximumActionCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("已选择 \(settings.actions.count) 个图标，最多 \(ToolbarSettings.maximumActionCount) 个")
                }
                HStack {
                    Spacer(minLength: 0)
                    if settings.actions.isEmpty {
                        Label("胶囊已隐藏", systemImage: "eye.slash")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 0) {
                            ForEach(settings.actions) { action in
                                Image(systemName: action.symbol)
                                    .font(.system(size: 16, weight: action == .create ? .medium : .regular))
                                    .frame(width: 36, height: 36)
                                    .help(action.title)
                            }
                        }
                        .foregroundStyle(.primary)
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.7) }
                        .shadow(color: .black.opacity(theme.isDark ? 0.12 : 0.05), radius: 2, y: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("胶囊预览")
                        .accessibilityValue(settings.actions.map(\.title).joined(separator: "、"))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 48)
                .accessibilityIdentifier("settings.toolbar.preview")
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: settings.actions)
                Text(settings.actions.isEmpty ? "按 ⌘, 打开设置，即可重新添加图标。" : "胶囊随图标数量自动伸缩，按下面的顺序从左到右显示。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.secondary.opacity(theme.isDark ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 9) {
                Text("已选图标").font(.callout.weight(.medium))
                if settings.actions.isEmpty {
                    Text("从下方添加常用操作。")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(settings.actions.enumerated()), id: \.element) { index, action in
                            selectedRow(action, at: index)
                            if index < settings.actions.count - 1 {
                                Divider().padding(.horizontal, 12)
                            }
                        }
                    }
                    .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("添加图标").font(.callout.weight(.medium))
                    Spacer()
                    if !canAddAction {
                        Text("已达 \(ToolbarSettings.maximumActionCount) 个上限")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(availableActions) { action in
                        Button { add(action) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: action.symbol).font(.system(size: 15)).frame(width: 21)
                                Text(action.title).font(.callout).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .disabled(!canAddAction)
                        .opacity(canAddAction ? 1 : 0.5)
                        .accessibilityLabel("添加\(action.title)")
                        .accessibilityIdentifier("settings.toolbar.add.\(action.rawValue)")
                    }
                }
                Text("按 ⌘, 可随时打开设置。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .disabled(store.isBusy)
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
        .padding(.horizontal, 10).frame(height: 42)
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
