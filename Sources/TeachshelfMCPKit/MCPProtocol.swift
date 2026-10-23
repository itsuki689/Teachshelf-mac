import Foundation
import CoreFoundation
import TeachshelfCore

/// JSON-only, stateless MCP 2025-11-25, with earlier Streamable HTTP versions.
public enum MCPProtocol {
    public static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private enum Route { case reply(Data?), tool(Any, String, [String: Any]) }
    public static func response(to data: Data, call: (String, [String: Any]) throws -> [String: Any]) -> Data? {
        switch route(data) {
        case .reply(let data): return data
        case .tool(let id, let name, let arguments): return toolResult(id: id, result: Result { try call(name, arguments) })
        }
    }
    public static func responseAsync(to data: Data, call: (String, [String: Any]) async throws -> [String: Any]) async -> Data? {
        switch route(data) {
        case .reply(let data): return data
        case .tool(let id, let name, let arguments):
            do { return toolResult(id: id, result: .success(try await call(name, arguments))) }
            catch { return toolResult(id: id, result: .failure(error)) }
        }
    }
    private static func toolResult(id: Any, result: Result<[String: Any], Error>) -> Data {
        let value: [String: Any]
        do {
            let content = try result.get()
            let text = String(data: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), encoding: .utf8)!
            value = ["content": [["type": "text", "text": text]], "structuredContent": content, "isError": false]
        } catch { value = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
        return try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": value], options: [.sortedKeys])
    }
    private static func route(_ data: Data) -> Route {
        func encode(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data() }
        func rpcError(_ code: Int, _ message: String, id: Any = NSNull()) -> Route { .reply(encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])) }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return rpcError(-32700, "Parse error") }
        guard let request = raw as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return rpcError(-32600, "Invalid Request") }
        let id = request["id"]
        if let id {
            let validNumber = (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue.rounded() == $0.doubleValue } ?? false
            guard id is String || validNumber else { return rpcError(-32600, "Invalid request ID") }
        }
        // Notifications never receive a JSON-RPC response and cannot invoke tools.
        guard let id else { return .reply(nil) }
        if request["params"] != nil && !(request["params"] is [String: Any]) { return rpcError(-32602, "params must be an object", id: id) }
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String, params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else { return rpcError(-32602, "Invalid initialize parameters", id: id) }
            result = ["protocolVersion": versions.contains(requested) ? requested : versions[0], "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "teachshelf", "version": "1.13.0"], "instructions": "先调用 teachshelf_context。支持计划、课程、资料信息和物理文件夹操作。计划编辑需 revision；课程资料写入需 library_revision。不读取资料文件正文。"]
        case "ping": result = [:]
        case "tools/list":
            guard params["cursor"] == nil else { return rpcError(-32602, "This tool list has no cursor", id: id) }
            result = ["tools": TeachshelfMCPTools.definitions]
        case "tools/call":
            guard let name = params["name"] as? String, TeachshelfMCPTools.definitions.contains(where: { $0["name"] as? String == name }),
                  params["arguments"] == nil || params["arguments"] is [String: Any] else { return rpcError(-32602, "Unknown tool or invalid arguments", id: id) }
            return .tool(id, name, params["arguments"] as? [String: Any] ?? [:])
        default: return rpcError(-32601, "Method not found", id: id)
        }
        return .reply(encode(["jsonrpc": "2.0", "id": id, "result": result]))
    }
}
