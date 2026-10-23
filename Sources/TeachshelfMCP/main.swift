import Foundation
import TeachshelfMCPKit

// stdout is exclusively newline-delimited JSON-RPC. Configuration errors go to stderr.
@main struct Bridge {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            FileHandle.standardError.write(Data("TeachshelfMCP [--config /absolute/path/config.json]\n请先打开课屿并启用设置 → MCP。\n".utf8)); return
        }
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--config" && arguments[1].hasPrefix("/")) else { fail("参数：TeachshelfMCP [--config /absolute/path/config.json]") }
        let url = arguments.isEmpty ? MCPConfiguration.defaultURL : URL(fileURLWithPath: arguments[1])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 20; sessionConfig.timeoutIntervalForResource = 25
        sessionConfig.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfig, delegate: NoRedirect(), delegateQueue: nil)
        var buffer = Data()
        var protocolVersion = MCPProtocol.versions[0]
        while true {
            let chunk: Data
            do { chunk = try FileHandle.standardInput.read(upToCount: 65_536) ?? Data() }
            catch { fail("读取 MCP 输入失败。") }
            if chunk.isEmpty {
                if !buffer.isEmpty { await forward(buffer, configURL: url, session: session, protocolVersion: &protocolVersion) }
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576 else { fail("MCP 请求超过 1 MiB。") }
                if !line.isEmpty { await forward(line, configURL: url, session: session, protocolVersion: &protocolVersion) }
            }
            guard buffer.count <= 1_048_576 else { fail("MCP 请求超过 1 MiB。") }
        }
        session.invalidateAndCancel()
    }
    static func forward(_ data: Data, configURL: URL, session: URLSession, protocolVersion: inout String) async {
        do {
            let config = try MCPConfiguration.load(from: configURL)
            guard config.enabled else { throw BridgeError("课屿 MCP 已关闭，请在设置中开启。") }
            var request = URLRequest(url: URL(string: config.endpoint)!)
            request.httpMethod = "POST"; request.httpBody = data
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, [200, 202].contains(response.statusCode) else { throw BridgeError("MCP 连接被拒绝，请检查课屿设置与端口。") }
            if response.statusCode == 200 {
                let object = try JSONSerialization.jsonObject(with: body)
                if let response = object as? [String: Any], let result = response["result"] as? [String: Any],
                   let negotiated = result["protocolVersion"] as? String, MCPProtocol.versions.contains(negotiated) {
                    protocolVersion = negotiated
                }
                var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); line.append(10)
                try FileHandle.standardOutput.write(contentsOf: line)
            }
        } catch {
            let message = (error as? BridgeError)?.message ?? "无法连接课屿，请确认应用已打开且 MCP 已启用。"
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Failed notifications still must not produce a protocol response.
            if let id = object?["id"] {
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
                if var line = try? JSONSerialization.data(withJSONObject: response) { line.append(10); try? FileHandle.standardOutput.write(contentsOf: line) }
            } else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        }
    }
    static func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
    struct BridgeError: Error { let message: String; init(_ message: String) { self.message = message } }
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
