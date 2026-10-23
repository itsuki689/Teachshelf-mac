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
    @ObservedObject var controller: MCPController
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState private var port = ""
    @ViewState private var copied = ""
    private var validPort: Bool { UInt16(port).map { $0 >= 1024 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "连接服务") {
                SettingsCard {
                    SettingsRow(title: "允许 MCP 客户端访问课屿", detail: "让支持 MCP 的 AI 客户端调用课屿工具。", symbol: "point.3.connected.trianglepath.dotted") {
                        Toggle("允许 MCP 客户端访问课屿", isOn: Binding(
                            get: { controller.configuration?.enabled == true },
                            set: { controller.configure(enabled: $0) }
                        )).labelsHidden().toggleStyle(.switch).tint(theme.controlAccent)
                            .disabled(controller.configuration == nil)
                    }
                    SettingsDivider()
                    HStack(spacing: 8) {
                        Circle().fill(controller.configuration?.enabled == true ? theme.ink : Color.secondary).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(controller.connectionStatus).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                }
                SettingsNote(text: "支持计划、课程、资料信息和物理文件夹操作。修改会立即保存；资料文件正文不会通过 MCP 读取。")
            }

            SettingsGroup(title: "连接客户端", detail: "复制配置，加入客户端的 MCP 设置后重新连接。") {
                SettingsCard {
                    SettingsRow(title: "本机客户端", detail: "stdio 入口自动读取本机配置，课屿需保持打开。", symbol: "desktopcomputer") {
                        Button("复制 stdio 配置") { controller.copyStdioConfiguration(); copied = "已复制 stdio 配置" }
                            .buttonStyle(.borderedProminent).tint(theme.controlAccent)
                    }
                    SettingsDivider()
                    SettingsRow(title: "HTTP 客户端", detail: "使用 Streamable HTTP 连接，配置中包含访问令牌。", symbol: "network") {
                        Button("复制 HTTP 配置") { controller.copyHTTPConfiguration(); copied = "已复制 HTTP 配置（含令牌）" }
                    }
                }.disabled(controller.configuration == nil)
                if !copied.isEmpty { SettingsNote(text: copied, symbol: "checkmark.circle") }
            }

            SettingsGroup(title: "连接地址与访问令牌") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsCode(text: controller.configuration?.endpoint ?? "配置不可用")
                        HStack(spacing: 10) {
                            Text("本机端口").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 8)
                            TextField("53141", text: $port).font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder).frame(width: 86).accessibilityLabel("MCP 本机端口")
                            Button("应用") { if let value = UInt16(port), value >= 1024 { controller.configure(port: value) } }
                                .disabled(!validPort || UInt16(port) == controller.configuration?.port)
                        }
                        if !validPort { Text("端口须为 1024–65535 之间的整数。") .font(.caption).foregroundStyle(.red) }
                    }.padding(20)
                    SettingsDivider()
                    SettingsRow(title: "访问令牌", detail: "仅向可信客户端提供；更换后需更新 HTTP 配置。") {
                        HStack(spacing: 8) {
                            Button("复制令牌") { controller.copyToken(); copied = "访问令牌已复制" }
                            Button("更换令牌") { controller.configure(rotateToken: true); copied = "令牌已更换，请更新 HTTP 客户端配置" }
                        }
                    }
                }.disabled(controller.configuration == nil)
                SettingsNote(text: "服务仅监听本机地址。服务器上的模型可通过 SSH 隧道连接。", symbol: "lock")
            }

            SettingsCard {
                SettingsDisclosure(title: "连接服务器上部署的模型", symbol: "server.rack") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("模型需通过支持 MCP 的客户端或 Agent 调用工具。保持 Mac 上的课屿打开，在 Mac 终端建立 SSH 反向隧道：")
                        SettingsCode(text: "ssh -N -R 127.0.0.1:\(controller.configuration?.port ?? 53141):127.0.0.1:\(controller.configuration?.port ?? 53141) user@server")
                        Text("将 user@server 换为服务器账号，再把 HTTP 配置交给服务器上的 MCP 客户端。容器内的客户端需额外配置访问宿主机的隧道端口。")
                        Button("打开完整连接说明") {
                            if let url = Bundle.main.url(forResource: "MCP", withExtension: "md") { NSWorkspace.shared.open(url) }
                        }
                    }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup(title: "当前会话") {
                SettingsCard {
                    SettingsRow(title: store.repository.root.lastPathComponent, detail: controller.lastAction, symbol: "externaldrive") {
                        if store.canUndoPlanChange {
                            Button("撤销计划修改") { store.undoPlanChange() }.disabled(store.isBusy)
                        }
                    }
                }
                SettingsNote(text: "计划修改支持撤销；课程资料操作不进入计划撤销记录。")
            }
        }
        .onAppear { port = String(controller.configuration?.port ?? 53141) }
        .onChange(of: controller.configuration?.port) { old, new in
            if port == old.map(String.init) { port = new.map(String.init) ?? "53141" }
        }
    }
}
