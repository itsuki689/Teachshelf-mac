import AppKit
import SwiftUI
import TeachshelfCore

struct AccentEditingSession: Identifiable { let id: UUID }

struct AccentColorEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ViewState private var hexInput = ""
    @FocusState private var hexFocused: Bool
    let sessionID: UUID

    private var selectedHex: String { store.previewAccentHex ?? store.state.accentColor }
    private var inputIsValid: Bool { RGBColor(hex: hexInput) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("强调色").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("为按钮、选中项和重点信息选择颜色。课程颜色保持独立。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("12 种预设").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(ColorPalette.themes, id: \.hex) { choice in
                        Button { apply(choice.hex) } label: {
                            let color = RGBColor(hex: choice.hex)!
                            let label = RGBColor(hex: "#FFFFFF")!.contrastRatio(with: color) >= 4.5 ? Color.white : Color.black
                            RoundedRectangle(cornerRadius: 8).fill(Color(rgb: color))
                                .frame(height: 38)
                                .overlay {
                                    if selectedHex == choice.hex {
                                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(label)
                                    }
                                }
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                        }.buttonStyle(.plain).help("\(choice.name) · \(choice.hex)")
                            .accessibilityLabel(choice.name)
                            .accessibilityValue(selectedHex == choice.hex ? "已选中" : choice.hex)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ColorPicker("自定义颜色", selection: Binding(
                        get: { Color(hex: selectedHex) },
                        set: { apply($0.hexString) }
                    ), supportsOpacity: false)
                    Spacer()
                    Text("HEX").font(.caption).foregroundStyle(.secondary)
                    TextField("#39786B", text: $hexInput)
                        .font(.system(.body, design: .monospaced)).textFieldStyle(.plain)
                        .focused($hexFocused).focusEffectDisabled()
                        .padding(.horizontal, 9).frame(width: 118, height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(hexFocused ? theme.ink : Color.secondary.opacity(0.35), lineWidth: hexFocused ? 2 : 1)
                        }
                        .accessibilityLabel("强调色 HEX")
                        .onSubmit { if let color = RGBColor(hex: hexInput) { apply(color.hex) } }
                }
                Text(inputIsValid ? " " : "请输入 6 位十六进制颜色，例如 #3B72B8。")
                    .font(.caption).foregroundStyle(.red).frame(height: 15)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("效果预览").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("主要按钮").font(.callout.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(theme.controlAccent, in: RoundedRectangle(cornerRadius: 7))
                    Label("选中项目", systemImage: "doc.text")
                        .font(.callout).foregroundStyle(.primary).padding(8)
                        .background(theme.selection, in: RoundedRectangle(cornerRadius: 7))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(theme.ink)
                }.accessibilityElement(children: .ignore).accessibilityLabel("强调色效果预览")
                Text("浅色、深色与高对比度会自动适配；控件明度会调整以保持文字清晰。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            Button("恢复默认松柏绿") { apply(ColorPalette.defaultAccent) }.buttonStyle(.plain).foregroundStyle(theme.ink)
            Divider()
            HStack {
                Text("保存后记住颜色；取消会还原。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    store.cancelAccentPreview(sessionID: sessionID)
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("保存强调色") {
                    if store.saveAccentPreview(sessionID: sessionID) { dismiss() }
                }.appPrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(!inputIsValid || store.isBusy || store.accentPreviewID != sessionID)
            }
        }.padding(26).frame(width: 500)
            .appTheme()
            .dismissColorPanelAutomatically()
            .onAppear { hexInput = selectedHex }
            .onChange(of: hexInput) { _, value in store.previewAccent(value, sessionID: sessionID) }
            .onDisappear {
                store.cancelAccentPreview(sessionID: sessionID)
            }
    }

    private func apply(_ hex: String) {
        guard let color = RGBColor(hex: hex) else { return }
        hexInput = color.hex
        store.previewAccent(color.hex, sessionID: sessionID)
    }
}
