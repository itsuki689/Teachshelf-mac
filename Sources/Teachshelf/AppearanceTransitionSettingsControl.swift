import AppKit
import SwiftUI
import TeachshelfCore

struct AppearanceTransitionSettingsControl: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var draft = AppearanceTransitionSettings.default
    @ViewState private var hexInput = AppearanceTransitionSettings.default.colorHex
    @ViewState private var editingSpeed = false
    @ViewState private var editingRoot: URL?
    @ViewState private var pendingSave: Task<Void, Never>?
    @FocusState private var hexFocused: Bool

    private var validHex: Bool { RGBColor(hex: hexInput) != nil }
    private var durationText: String { String(format: "约 %.2f 秒", 0.74 / draft.speed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("明暗过渡").font(.headline)
                Spacer()
                Button {
                    commitHex()
                    if persistDraft() { AppearanceTransition.shared.preview(settings: draft) }
                } label: {
                    Label("预览", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(reduceMotion || (draft.colorMode == .solid && !validHex))
                .help(reduceMotion ? "系统已开启减少动态效果" : "预览过渡动画")
                .accessibilityIdentifier("appearance.transition.preview")
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("铺开方向").font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    ForEach(AppearanceTransitionDirection.allCases) { direction in
                        Button {
                            draft.direction = direction
                            commitHex()
                            persistDraft()
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: direction.symbol).font(.system(size: 16, weight: .medium))
                                Text(direction.title).font(.callout)
                            }
                            .frame(maxWidth: .infinity).frame(height: 58)
                            .foregroundStyle(draft.direction == direction ? theme.ink : Color.primary)
                            .background(draft.direction == direction ? theme.selection : Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(
                                    draft.direction == direction ? theme.ink.opacity(0.65) : Color.secondary.opacity(0.18), lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(direction.title)铺开")
                        .accessibilityValue(draft.direction == direction ? "已选中" : "未选中")
                        .accessibilityIdentifier("appearance.transition.direction.\(direction.rawValue)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("速度").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f×", draft.speed)).font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("appearance.transition.speed.value")
                }
                HStack(spacing: 10) {
                    Text("慢").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { draft.speed }, set: { value in
                        draft.speed = value
                        if !editingSpeed { scheduleSave() }
                    }), in: 0.5...2, step: 0.1, onEditingChanged: { editing in
                        editingSpeed = editing
                        if editing { cancelPendingSave() }
                        else { persistDraft() }
                    })
                    .labelsHidden()
                    .accessibilityLabel("明暗过渡速度")
                    .accessibilityIdentifier("appearance.transition.speed")
                    Text("快").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("颜色").font(.callout.weight(.medium))
                    Spacer()
                    Picker("过渡配色", selection: Binding(get: { draft.colorMode }, set: { mode in
                        commitHex()
                        draft.colorMode = mode
                        hexInput = draft.colorHex
                        persistDraft()
                    })) {
                        ForEach(AppearanceTransitionColorMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                    .accessibilityIdentifier("appearance.transition.palette")
                }
                if draft.colorMode == .solid {
                    HStack(spacing: 12) {
                        ColorPicker("过渡颜色", selection: Binding(get: { Color(hex: draft.colorHex) }, set: { color in
                            draft.colorHex = color.hexString
                            hexInput = draft.colorHex
                            scheduleSave()
                        }), supportsOpacity: false)
                        .accessibilityIdentifier("appearance.transition.color")
                        Spacer(minLength: 0)
                        Text("HEX").font(.caption).foregroundStyle(.secondary)
                        TextField("#808080", text: $hexInput)
                            .font(.system(.callout, design: .monospaced))
                            .textFieldStyle(.roundedBorder).frame(width: 108)
                            .focused($hexFocused)
                            .accessibilityLabel("过渡颜色 HEX")
                            .accessibilityIdentifier("appearance.transition.hex")
                            .onSubmit { commitHex(); persistDraft() }
                    }
                    if !validHex {
                        Text("请输入六位 HEX 颜色，例如 #808080。")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else {
                    HStack(spacing: 3) {
                        ForEach(AppearanceTransitionSettings.rainbowHexes, id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: hex))
                                .frame(maxWidth: .infinity).frame(height: 24)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("彩虹十色预览")
                }
            }

            HStack {
                Text(durationText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    draft = .default
                    hexInput = draft.colorHex
                    persistDraft()
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(theme.ink)
                .accessibilityIdentifier("appearance.transition.reset")
            }
        }
        .padding(18)
        .dismissColorPanelAutomatically()
        .onAppear { synchronize() }
        .onChange(of: store.state.appearanceTransition) { _, _ in synchronize() }
        .onChange(of: store.repository.root) { _, _ in synchronize() }
        .onChange(of: hexFocused) { _, focused in
            if !focused { commitHex(); persistDraft() }
        }
        .onDisappear {
            commitHex()
            persistDraft()
        }
    }

    private func commitHex() {
        guard let color = RGBColor(hex: hexInput) else { return }
        draft.colorHex = color.hex
        hexInput = color.hex
    }

    private func synchronize() {
        // A debounced slider/color save may finish while a new HEX edit is in progress.
        // Keep that uncommitted text in the same library; a library change always refreshes it.
        let pendingHexInput = hexFocused && editingRoot == store.repository.root && hexInput != draft.colorHex
            ? hexInput : nil
        cancelPendingSave()
        editingRoot = store.repository.root
        draft = store.state.appearanceTransition
        hexInput = pendingHexInput ?? draft.colorHex
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func scheduleSave() {
        cancelPendingSave()
        let root = editingRoot
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard !Task.isCancelled, root == store.repository.root else { return }
            persistDraft()
        }
    }

    @discardableResult private func persistDraft() -> Bool {
        cancelPendingSave()
        guard editingRoot == store.repository.root, draft.isValid else { return false }
        guard !store.isBusy else { scheduleSave(); return false }
        let value = draft
        guard value != store.state.appearanceTransition else { return true }
        store.perform { try store.repository.saveAppearanceTransition(value) }
        let saved = store.state.appearanceTransition
        if saved != value {
            draft = saved
            hexInput = saved.colorHex
            return false
        }
        return true
    }
}
