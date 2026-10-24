import Foundation
import TeachshelfCore

struct AIToolCall {
    let id: String
    let name: String
    let arguments: String
}
struct AIReply {
    let message: [String: Any]
    let text: String
    let calls: [AIToolCall]
}
@MainActor protocol AICompleting {
    func complete(messages: [[String: Any]], tools: [[String: Any]], toolChoice: Any) async throws -> AIReply
}

/// Do not forward an API key to redirects, even if a proxy claims a new endpoint.
final class AINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class AIChatClient: AICompleting {
    let configuration: AIConfiguration
    private let key: String
    private let session: URLSession
    init(configuration: AIConfiguration, key: String, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration; self.key = key
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        sessionConfiguration.httpCookieStorage = nil; sessionConfiguration.urlCache = nil
        sessionConfiguration.urlCredentialStorage = nil
        session = URLSession(configuration: sessionConfiguration, delegate: AINoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    static func tools() -> [[String: Any]] {
        TeachshelfMCPTools.definitions.map { definition in
            ["type": "function", "function": ["name": definition["name"]!, "description": definition["description"]!, "parameters": definition["inputSchema"]!]]
        }
    }
    func complete(messages: [[String: Any]], tools: [[String: Any]], toolChoice: Any = "auto") async throws -> AIReply {
        try Task.checkCancellation()
        guard configuration.isConfigured else { throw PlanMCPError("请先设置模型地址和名称。") }
        var request = URLRequest(url: try configuration.completionURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": configuration.model, "messages": messages, "tools": tools, "tool_choice": toolChoice, "stream": false]
        if configuration.reasoningDisabled { body["reasoning_effort"] = "none" }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 1_500_000 else { throw PlanMCPError("这段对话已较长，请新建对话后继续。") }
        request.httpBody = data
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw PlanMCPError("无法连接模型服务，请检查地址、网络及服务状态。")
        }
        guard let response = response as? HTTPURLResponse else { bytes.task.cancel(); throw PlanMCPError("模型服务未返回 HTTP 响应。") }
        guard (200..<300).contains(response.statusCode) else {
            bytes.task.cancel()
            let hint: String
            switch response.statusCode {
            case 300..<400: hint = "服务要求重定向，请直接填写最终 API 地址。"
            case 401, 403: hint = "请检查 API Key 和服务权限。"
            case 404: hint = "请检查 API 地址和模型名称。"
            case 429: hint = "请求过于频繁或额度不足，请稍后重试。"
            default: hint = "请检查模型名称、工具调用支持和服务状态。"
            }
            throw PlanMCPError("模型服务返回 HTTP \(response.statusCode)。\(hint)")
        }
        var output = Data()
        do {
            for try await byte in bytes {
                if output.count >= 2_000_000 { bytes.task.cancel(); throw PlanMCPError("模型响应过大，已停止读取。") }
                output.append(byte)
            }
        } catch { bytes.task.cancel(); if Task.isCancelled { throw CancellationError() }; throw PlanMCPError("模型响应中断或过大，请重试。") }
        try Task.checkCancellation()
        return try Self.parse(output)
    }

    static func parse(_ data: Data) throws -> AIReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let raw = choice["message"] as? [String: Any], raw["role"] as? String == "assistant" else {
            throw PlanMCPError("响应格式不兼容，需要支持 Chat Completions 和工具调用的服务。")
        }
        if let reason = choice["finish_reason"] as? String, ["length", "content_filter"].contains(reason) {
            throw PlanMCPError("模型回答未完成（\(reason)），没有执行其中的操作。")
        }
        let text = raw["content"] as? String ?? ""
        var message: [String: Any] = ["role": "assistant", "content": raw["content"] as? String as Any? ?? NSNull()]
        // Some compatible reasoning servers require this field in subsequent tool turns.
        if let reasoning = raw["reasoning_content"] as? String { message["reasoning_content"] = reasoning }
        var calls: [AIToolCall] = []
        if let rawCalls = raw["tool_calls"], !(rawCalls is NSNull) {
            guard let values = rawCalls as? [[String: Any]], values.count <= 8 else { throw PlanMCPError("模型一次请求了过多操作或工具格式无效。") }
            var ids: Set<String> = []
            for value in values {
                guard value["type"] as? String == "function", let id = value["id"] as? String, !id.isEmpty, id.count <= 200,
                      ids.insert(id).inserted, let function = value["function"] as? [String: Any],
                      let name = function["name"] as? String, let arguments = function["arguments"] as? String else {
                    throw PlanMCPError("模型返回的工具调用格式无效，没有执行操作。")
                }
                calls.append(AIToolCall(id: id, name: name, arguments: arguments))
            }
            message["tool_calls"] = values
        }
        guard !text.isEmpty || !calls.isEmpty else { throw PlanMCPError("模型返回了空回答。") }
        return AIReply(message: message, text: text, calls: calls)
    }

    func testConnection() async throws {
        let definition: [String: Any] = ["type": "function", "function": ["name": "connection_test", "description": "Return ok true.", "parameters": ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false]]]
        let reply = try await complete(messages: [["role": "user", "content": "Call connection_test with ok=true."]], tools: [definition], toolChoice: ["type": "function", "function": ["name": "connection_test"]])
        guard reply.calls.count == 1, reply.calls[0].name == "connection_test",
              let args = try? JSONSerialization.jsonObject(with: Data(reply.calls[0].arguments.utf8)) as? [String: Any], args["ok"] as? Bool == true else {
            throw PlanMCPError("服务可以连接，但模型未正确调用工具。请换用支持工具调用的模型或调整服务配置。")
        }
    }
}
