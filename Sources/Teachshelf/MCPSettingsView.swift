import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if let controller = store.mcpController { MCPConnectionSettings(controller: controller) }
        else {
            SettingsCard {
                SettingsRow(title: "此资料库未启动 MCP", detail: "隔离资料库不启用连接服务，请在正式安装的课屿中使用。", symbol: "network.slash") { EmptyView() }
            }
        }
    }
}

private struct MCPConnectionSettings: View {
    enum Transport: String, CaseIterable { case stdio = "本机 · stdio", http = "HTTP 客户端" }
    @ObservedObject var controller: MCPController
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState private var transport = Transport.stdio
    @ViewState private var port = ""
    @ViewState private var copied = ""
    private var validPort: Bool { UInt16(port).map { $0 >= 1024 } ?? false }
    private var enabled: Bool { controller.configuration?.enabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "工具服务", detail: "供外部 MCP 客户端查询和编辑课屿中的内容。") {
                SettingsCard {
                    SettingsRow(title: "启用 MCP", detail: "提供计划、课程、资料信息及物理文件夹工具。", symbol: "point.3.connected.trianglepath.dotted") {
                        Toggle("启用 MCP", isOn: Binding(get: { enabled }, set: { controller.configure(enabled: $0) }))
                            .labelsHidden().toggleStyle(.switch).tint(theme.controlAccent)
                            .disabled(controller.configuration == nil)
                    }
                    SettingsDivider()
                    HStack(alignment: .top, spacing: 12) {
                        SettingsBadge(title: enabled ? "已启用" : "已关闭", symbol: enabled ? "network" : "network.slash")
                        Text(controller.connectionStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(20)
                }
            }
            SettingsGroup(title: "连接客户端", detail: "选择客户端支持的方式，复制配置并加入客户端的 MCP 设置。") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("MCP 连接方式", selection: $transport) {
                            ForEach(Transport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        HStack(alignment: .top, spacing: 12) {
                            SettingsIcon(symbol: transport == .stdio ? "desktopcomputer" : "network", size: 34)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(transport == .stdio ? "同一台 Mac 上的客户端" : "Streamable HTTP")
                                    .font(.system(size: 13, weight: .medium))
                                Text(transport == .stdio ? "自动读取本机连接配置，无需手动填写令牌。" : "配置包含连接地址和访问令牌，请仅交给可信客户端。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if transport == .http { SettingsCode(text: controller.configuration?.endpoint ?? "配置不可用") }
                        HStack {
                            Text("连接期间请保持课屿打开。").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(transport == .stdio ? "复制 stdio 配置" : "复制 HTTP 配置") {
                                if transport == .stdio { controller.copyStdioConfiguration(); copied = "已复制 stdio 配置" }
                                else { controller.copyHTTPConfiguration(); copied = "已复制 HTTP 配置（含令牌）" }
                            }.buttonStyle(.borderedProminent).tint(theme.controlAccent)
                        }
                        if !copied.isEmpty { SettingsNote(text: copied, symbol: "checkmark.circle") }
                    }.padding(20)
                }.disabled(controller.configuration == nil)
                SettingsNote(text: "外部客户端发起的修改会立即保存。资料文件正文不会通过 MCP 读取。")
            }
            SettingsCard {
                SettingsDisclosure(title: "端口与访问令牌", symbol: "lock.shield") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Text("本机端口").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 8)
                            TextField("53141", text: $port).font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder).frame(width: 86).accessibilityLabel("MCP 本机端口")
                            Button("应用") { if let value = UInt16(port), value >= 1024 { controller.configure(port: value) } }
                                .disabled(!validPort || UInt16(port) == controller.configuration?.port)
                        }
                        if !validPort { Text("端口须为 1024–65535 之间的整数。").font(.caption).foregroundStyle(.red) }
                        SettingsCode(text: controller.configuration?.endpoint ?? "配置不可用")
                        HStack(spacing: 8) {
                            Text("访问令牌").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 8)
                            Button("复制令牌") { controller.copyToken(); copied = "访问令牌已复制" }
                            Button("更换令牌") { controller.configure(rotateToken: true); copied = "令牌已更换，请更新 HTTP 客户端配置" }
                        }
                        SettingsNote(text: "服务仅监听 127.0.0.1。更换端口或令牌后，请重新复制 HTTP 客户端配置。", symbol: "lock")
                    }.disabled(controller.configuration == nil)
                }
                SettingsDivider()
                SettingsDisclosure(title: "远程 MCP 客户端", symbol: "server.rack") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("仅当 MCP 客户端或 Agent 运行在另一台服务器时需要隧道。在 Mac 终端建立连接，并保持课屿运行：")
                        SettingsCode(text: "ssh -o ExitOnForwardFailure=yes -N -R 127.0.0.1:\(controller.configuration?.port ?? 53141):127.0.0.1:\(controller.configuration?.port ?? 53141) user@server")
                        Text("将 user@server 换为服务器账号。远程客户端通过转发地址和访问令牌连接；容器网络等配置见完整说明。")
                        Button("打开 MCP 连接说明") {
                            if let url = Bundle.main.url(forResource: "MCP", withExtension: "md") { NSWorkspace.shared.open(url) }
                        }
                    }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup(title: "当前会话") {
                SettingsCard {
                    SettingsRow(title: store.repository.root.lastPathComponent, detail: controller.lastAction, symbol: "externaldrive") { EmptyView() }
                    if store.canUndoPlanChange {
                        SettingsDivider()
                        SettingsRow(title: "最近的计划修改", detail: store.planUndoLabel ?? "包括应用内及客户端发起的计划修改。") {
                            Button("撤销计划修改") { store.undoPlanChange() }.disabled(store.isBusy)
                        }
                    }
                }
                SettingsNote(text: "计划修改支持撤销；课程资料操作不进入计划撤销记录。")
            }
            SettingsCard {
                SettingsRow(title: "在课屿中直接聊天", detail: "模型 API 接入已集中在「AI 助手」设置中。", symbol: "sparkles") {
                    Button("AI 助手设置") { store.settingsSection = .assistant }
                }
            }
        }
        .onAppear { port = String(controller.configuration?.port ?? 53141) }
        .onChange(of: transport) { _, _ in copied = "" }
        .onChange(of: controller.configuration?.port) { old, new in
            if port == old.map(String.init) { port = new.map(String.init) ?? "53141" }
        }
    }
}
