import SwiftUI

struct AIConfigurationSheet: View {
    @ObservedObject var controller: AIChatController
    @Environment(\.dismiss) private var dismiss
    @ViewState private var value: AIConfiguration
    @ViewState private var key = ""
    @ViewState private var message = ""
    @ViewState private var testing = false
    @ViewState private var testTask: Task<Void, Never>?
    @ViewState private var loaded = false
    @ViewState private var keyLoaded = true
    init(controller: AIChatController) {
        self.controller = controller
        _value = ViewState(initialValue: controller.configuration)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "network")
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型连接").font(.title2.weight(.semibold))
                    Text("使用支持工具调用的 Chat Completions 服务").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsGroup(title: "服务配置", detail: "填写服务提供的 API 基础地址（通常以 /v1 结尾），或完整的 /chat/completions 地址。") {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 16) {
                                field("API 地址") { TextField("https://your-server.example/v1", text: $value.endpoint) }
                                field("模型名称") { TextField("填写服务中的模型 ID", text: $value.model) }
                                field("API Key（本地服务可留空）") { SecureField("密钥保存在 macOS 钥匙串", text: $key) }
                                Toggle("关闭模型推理（reasoning_effort: none）", isOn: $value.reasoningDisabled).font(.callout)
                                Text("仅在服务要求以此模式使用工具调用时开启；其他服务保持关闭。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.textFieldStyle(.roundedBorder).padding(20)
                        }
                    }
                    if value.endpoint.lowercased().hasPrefix("http://") {
                        SettingsNote(text: "此地址使用明文 HTTP。仅在可信的本机或私有网络使用，远程服务建议配置 HTTPS。", symbol: "lock.open")
                    }
                    SettingsNote(text: "测试只发送测试消息，不读取或修改资料库。正式对话会把消息及查询到的元数据发给此服务；本机执行工具，无需向服务器开放课屿 MCP 端口。")
                    SettingsNote(text: "更改模型配置会清空当前对话。更换 API 地址后，需要重新填写该地址的密钥。")
                    if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(24)
            }
            Divider()
            HStack {
                Button(testing ? "正在测试…" : "测试连接与工具调用") { test() }.disabled(testing || !value.isConfigured || !keyLoaded)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(testing || !value.isConfigured || !keyLoaded)
            }.padding(20)
        }.frame(width: 620, height: 620)
        .onAppear {
            guard !loaded else { return }
            if value.isConfigured {
                do { key = try AIKeychain.read(value) }
                catch { keyLoaded = false; message = error.localizedDescription + " 关闭此窗口，解锁后重试。" }
            }
            loaded = true
        }
        .onChange(of: value.endpoint) { old, new in
            if loaded, old != new { key = ""; keyLoaded = true; cancelTest() }
        }
        .onChange(of: value.model) { _, _ in cancelTest() }
        .onChange(of: value.reasoningDisabled) { _, _ in cancelTest() }
        .onChange(of: key) { _, _ in cancelTest() }
        .onDisappear { testTask?.cancel() }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 12, weight: .medium)); content() }
    }
    private func cancelTest() { testTask?.cancel(); testTask = nil; testing = false; message = "" }
    private func test() {
        testing = true; message = ""
        let client = AIChatClient(configuration: value, key: key)
        testTask = Task {
            do { try await client.testConnection(); if !Task.isCancelled { message = "连接成功，模型已正确返回工具调用。" } }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled { testing = false }
        }
    }
    private func save() {
        do { try controller.updateConfiguration(value, key: key); dismiss() }
        catch { message = error.localizedDescription }
    }
}
