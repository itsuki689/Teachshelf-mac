import SwiftUI

struct AISettingsView: View {
    @ObservedObject var controller: AIChatController
    @ObservedObject var model: AISettingsModel
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "模型服务", detail: "云端 API 和服务器上的本地模型，统一使用 OpenAI 兼容接口。") {
                SettingsCard {
                    HStack {
                        Label("OpenAI API", systemImage: "network").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        SettingsBadge(title: "Chat Completions")
                    }.padding(20)
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 18) {
                        field("Base URL", detail: "填写 /v1 基础地址，也支持完整的 /chat/completions 地址。") {
                            TextField("https://api.openai.com/v1", text: $model.value.endpoint)
                                .accessibilityLabel("AI Base URL")
                        }
                        field("模型名称", detail: "使用服务提供的完整模型 ID。") {
                            TextField("填写模型 ID", text: $model.value.model).accessibilityLabel("AI 模型名称")
                        }
                        field("API Key", detail: "密钥保存在 macOS 钥匙串；无需鉴权的本地服务可留空。") {
                            SecureField("本地服务可留空", text: $model.key).accessibilityLabel("AI API Key")
                        }
                    }.textFieldStyle(.roundedBorder).padding(20).disabled(controller.isRunning)
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { connectionActions; Spacer(minLength: 12); saveActions }
                            VStack(alignment: .leading, spacing: 12) { connectionActions; HStack { Spacer(); saveActions } }
                        }
                        if !model.message.isEmpty {
                            Label(model.message, systemImage: model.succeeded ? "checkmark.circle" : "info.circle")
                                .font(.callout).foregroundStyle(model.succeeded ? theme.ink : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if model.hasChanges {
                            Text("有未保存的修改。切换分页会保留草稿，保存后生效。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20)
                }
                if controller.isRunning { SettingsNote(text: "AI 助手正在处理消息，请停止或等待完成后修改连接。") }
                if model.value.endpoint.lowercased().hasPrefix("http://") {
                    SettingsNote(text: "当前使用 HTTP，请仅连接可信的本机或私有网络服务。", symbol: "lock.open")
                }
            }
            SettingsCard {
                SettingsDisclosure(title: "高级兼容选项", symbol: "slider.horizontal.3") {
                    Toggle("关闭模型推理", isOn: $model.value.reasoningDisabled)
                        .toggleStyle(.switch).tint(theme.controlAccent).disabled(controller.isRunning)
                    Text("发送 reasoning_effort: none。仅在服务要求以此模式使用工具调用时开启，其他服务保持关闭。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup(title: "在课屿中使用") {
                SettingsCard {
                    SettingsRow(title: "打开 AI 助手", detail: "通过聊天查询或修改计划、课程与资料，写入前会展示确认卡片。", symbol: "sparkles") {
                        Button("开始对话") { store.navigate(to: .assistant) }
                            .disabled(!controller.configuration.isConfigured)
                    }
                    SettingsDivider()
                    SettingsDisclosure(title: "接入服务器上的本地模型", symbol: "server.rack") {
                        Text("在 Base URL 中填写 Mac 可访问的服务器地址（通常以 /v1 结尾），并填写服务中的模型 ID。无鉴权时 API Key 留空，然后测试连接并保存。")
                        Text("服务器需支持 OpenAI Chat Completions 和工具调用。上下文窗口及 MTP 由服务器控制，无需在课屿另填。")
                        Text("课屿直接请求模型 API，并在本机执行操作。无需开启 MCP 服务，也无需为模型 API 建立课屿 MCP 的 SSH 隧道。")
                    }.font(.callout).foregroundStyle(.secondary)
                }
                SettingsNote(text: "连接测试仅发送测试消息，不访问资料库。正式对话会发送消息及按需查询的元数据，不发送资料文件正文；更改连接配置会清空当前对话。")
            }
        }
        .onAppear { model.load() }
        .onDisappear { if model.testing { model.cancelTest() } }
    }
    private var connectionActions: some View {
        HStack(spacing: 8) {
            Button(model.testing ? "正在测试…" : "测试连接") { model.test() }.disabled(!model.canUseConnection)
                .accessibilityLabel("测试 AI 连接与工具调用")
            if model.testing { ProgressView().controlSize(.small); Button("停止") { model.cancelTest() } }
            if !model.keyLoaded { Button("重新读取") { model.load() } }
        }
    }
    private var saveActions: some View {
        HStack(spacing: 8) {
            Button("还原") { model.restore() }.disabled(!model.hasChanges || controller.isRunning)
            Button("保存配置") { model.save() }.buttonStyle(.borderedProminent).tint(theme.controlAccent)
                .disabled(!model.canUseConnection || !model.hasChanges)
        }
    }
    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .medium))
            content()
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
