import AppKit
import SwiftUI
import TeachshelfCore

struct PlanColorControl: View {
    @Binding var colorHex: String?
    let inheritedHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("自定义计划颜色", isOn: Binding(get: { colorHex != nil }, set: { colorHex = $0 ? inheritedHex : nil }))
            if colorHex != nil {
                HStack {
                    ColorPicker("计划颜色", selection: Binding(get: { Color(hex: colorHex ?? inheritedHex) }, set: { colorHex = $0.hexString }), supportsOpacity: false)
                    Spacer()
                    Menu("预设") {
                        ForEach(ColorPalette.themes, id: \.hex) { choice in
                            Button(choice.name) { colorHex = choice.hex }
                        }
                    }.fixedSize()
                    TextField("HEX", text: Binding(get: { colorHex ?? inheritedHex }, set: { colorHex = $0 }))
                        .font(.system(.body, design: .monospaced)).frame(width: 100).accessibilityLabel("计划颜色 HEX")
                }
                if let hex = colorHex, RGBColor(hex: hex) == nil {
                    Text("请输入六位 HEX 颜色，例如 #8058A1。").font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("跟随关联课程颜色；未关联课程时使用强调色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: colorHex == nil) { _, isInherited in
            if isInherited { NSColorPanel.shared.orderOut(nil) }
        }
    }
}
