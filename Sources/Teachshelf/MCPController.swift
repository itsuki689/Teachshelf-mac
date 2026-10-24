import AppKit
import TeachshelfCore
import TeachshelfMCPKit

@MainActor final class MCPController: ObservableObject {
    @Published private(set) var configuration: MCPConfiguration?
    @Published private(set) var connectionStatus = "尚未启动"
    @Published private(set) var lastAction = "暂无 MCP 修改"
    private weak var store: AppStore?
    private let configURL: URL
    private var server: MCPHTTPServer?
    private var restartTask: Task<Void, Never>?
    private var generation = UUID()

    init(store: AppStore, configURL: URL = MCPConfiguration.defaultURL) {
        self.store = store; self.configURL = configURL
        do {
            if FileManager.default.fileExists(atPath: configURL.path) { configuration = try MCPConfiguration.load(from: configURL) }
            else { let value = MCPConfiguration(token: try MCPConfiguration.newToken()); try value.save(to: configURL); configuration = value }
            restart()
        } catch { connectionStatus = error.localizedDescription }
    }
    deinit { restartTask?.cancel(); server?.stop() }
    func configure(enabled: Bool? = nil, port: UInt16? = nil, rotateToken: Bool = false) {
        guard var value = configuration else { return }
        do {
            if let enabled { value.enabled = enabled }
            if let port {
                guard port >= 1024 else { throw PlanMCPError("端口须在 1024–65535 之间。") }; value.port = port
            }
            if rotateToken { value.token = try MCPConfiguration.newToken() }
            try value.save(to: configURL); configuration = value; restart()
        } catch { connectionStatus = error.localizedDescription }
    }
    private func restart() {
        let previousRestart = restartTask, previousServer = server
        server = nil; generation = UUID()
        let expected = generation
        connectionStatus = configuration?.enabled == true ? "正在启动…" : "已关闭"
        restartTask = Task { [weak self] in
            await previousRestart?.value
            if let previousServer { await previousServer.stopAndWait() }
            guard !Task.isCancelled, let self, self.generation == expected,
                  let configuration = self.configuration, configuration.enabled else { return }
            do {
                let next = try MCPHTTPServer(port: configuration.port, token: configuration.token, onState: { [weak self] message in
                    Task { @MainActor in guard let self, self.generation == expected else { return }; self.connectionStatus = message }
                }, handler: { [weak self] data in
                    await self?.handle(data, generation: expected)
                })
                self.server = next; next.start()
            } catch { self.connectionStatus = "启动失败：\(error.localizedDescription)" }
        }
    }
    func handle(_ data: Data, generation expected: UUID? = nil) async -> Data? {
        await MCPProtocol.responseAsync(to: data) { name, arguments in
            guard !Task.isCancelled, let store, configuration?.enabled == true, expected == nil || generation == expected else { throw PlanMCPError("MCP 已关闭或连接配置已更新，请重新连接。") }
            let result = try await store.toolExecutor.call(name: name, arguments: arguments)
            if result["changed"] as? Bool == true {
                lastAction = "\(Date().formatted(date: .omitted, time: .standard)) · \(name.replacingOccurrences(of: "teachshelf_", with: ""))"
            }
            return result
        }
    }
    func copyStdioConfiguration() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TeachshelfMCP").path
        copy(["mcpServers": ["teachshelf": ["command": executable]]])
    }
    func copyHTTPConfiguration() {
        guard let configuration else { return }
        copy(["mcpServers": ["teachshelf": ["url": configuration.endpoint, "headers": ["Authorization": "Bearer \(configuration.token)"]]]])
    }
    func copyToken() {
        guard let configuration else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration.token, forType: .string)
    }
    private func copy(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let value = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}
