import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if let controller = store.mcpController { MCPConnectionSettings(controller: controller) }
        else { Text("此隔离资料库未启动 MCP 服务。请在正式安装的课屿中使用。") }
    }
}

private struct MCPConnectionSettings: View {
    @ObservedObject var controller: MCPController
    @EnvironmentObject private var store: AppStore
    @ViewState<String> private var port = ""
    @ViewState<String> private var copied = ""
    @ViewState<Bool> private var showRemote = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("允许 MCP 客户端访问计划", isOn: Binding(get: { controller.configuration?.enabled == true }, set: { controller.configure(enabled: $0) }))
                        .toggleStyle(.switch).disabled(controller.configuration == nil)
                    Text(controller.connectionStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("可查询课程和资料标题，读取、创建、编辑和删除计划。修改会立即保存，计划工作区可撤销最近一次修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("客户端连接") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.configuration?.endpoint ?? "配置不可用").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text("端口")
                        TextField("53141", text: $port).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button("应用") { if let value = UInt16(port), value >= 1024 { controller.configure(port: value) } }
                            .disabled(UInt16(port).map { $0 < 1024 } ?? true)
                        Spacer()
                    }
                    HStack {
                        Button("复制 stdio 配置") { controller.copyStdioConfiguration(); copied = "已复制 stdio 配置" }
                        Button("复制 HTTP 配置") { controller.copyHTTPConfiguration(); copied = "已复制 HTTP 配置（含令牌）" }
                    }
                    HStack {
                        Button("复制访问令牌") { controller.copyToken(); copied = "访问令牌已复制" }
                        Button("更换令牌") { controller.configure(rotateToken: true); copied = "令牌已更换，请更新 HTTP 客户端配置" }
                    }
                    Text(copied.isEmpty ? "仅监听本机。HTTP 配置包含访问令牌，请只交给你信任的客户端。" : copied)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(controller.configuration == nil)
            DisclosureGroup("连接服务器上部署的模型", isExpanded: $showRemote) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型需通过支持 MCP 的客户端或 Agent 调用工具。保持 Mac 上的课屿打开，在 Mac 终端建立 SSH 反向隧道：")
                    Text("ssh -N -R 127.0.0.1:\(controller.configuration?.port ?? 53141):127.0.0.1:\(controller.configuration?.port ?? 53141) user@server")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("把 HTTP 配置交给服务器上的 MCP 客户端，并将 user@server 换为你的服务器账号。客户端若在容器中，需额外配置访问宿主机的隧道端口。")
                    Button("打开完整连接说明") {
                        if let url = Bundle.main.url(forResource: "MCP", withExtension: "md") { NSWorkspace.shared.open(url) }
                    }
                }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            Text("当前资料库：\(store.repository.root.lastPathComponent)\n\(controller.lastAction)")
                .font(.caption).foregroundStyle(.secondary)
            if store.canUndoPlanChange { Button("撤销最近一次计划修改") { store.undoPlanChange() }.disabled(store.isBusy) }
        }
        .onAppear { port = String(controller.configuration?.port ?? 53141) }
    }
}
