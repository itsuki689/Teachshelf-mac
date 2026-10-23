import Foundation
import Network

struct MCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum MCPHTTPParse {
    case waiting, rejected(Int), request(MCPHTTPRequest)
    static let maxBody = 1_048_576
    static func parse(_ data: Data) -> Self {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 16_384 ? .rejected(431) : .waiting }
        guard range.lowerBound <= 16_384, let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return .rejected(431) }
        let lines = head.components(separatedBy: "\r\n"), request = lines[0].components(separatedBy: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" else { return .rejected(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { return .rejected(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // No request smuggling or unbounded/chunked bodies; each connection handles one request.
        guard headers["transfer-encoding"] == nil else { return .rejected(400) }
        guard headers["expect"] == nil else { return .rejected(417) }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(rawLength) else { return .rejected(400) }
        guard length <= maxBody else { return .rejected(413) }
        let body = data[range.upperBound...]
        guard body.count >= length else { return .waiting }
        guard body.count == length else { return .rejected(400) }
        return .request(MCPHTTPRequest(method: request[0], path: request[1], headers: headers, body: Data(body)))
    }
}

/// Authenticated loopback-only Streamable HTTP. No SSE/session state is required.
public final class MCPHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.teachshelf.mcp-http")
    private let listener: NWListener
    private let token: String
    private let handler: @Sendable (Data) async -> Data?
    private let onState: @Sendable (String) -> Void
    private var connections: [UUID: Peer] = [:]
    private var stopped = false
    private final class Peer {
        let connection: NWConnection
        var data = Data()
        var timeout: DispatchWorkItem?
        var task: Task<Void, Never>?
        var responding = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    public init(port: UInt16, token: String, onState: @escaping @Sendable (String) -> Void,
                handler: @escaping @Sendable (Data) async -> Data?) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        self.token = token; self.handler = handler; self.onState = onState
    }
    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState("正在监听 127.0.0.1:\(self.listener.port?.rawValue ?? 0)")
            case .failed(let error): self.onState("连接服务启动失败（\(error.localizedDescription)），请检查端口是否被占用。")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    public func stop() { stop(completion: {}) }
    public func stopAndWait() async {
        await withCheckedContinuation { continuation in stop { continuation.resume() } }
    }
    private func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !stopped else { completion(); return }
            stopped = true
            // Wait for the socket to close before a replacement listener binds the same port.
            listener.stateUpdateHandler = { [self] state in
                if case .cancelled = state {
                    listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
                    completion()
                }
            }
            for id in Array(connections.keys) { close(id) }
            listener.cancel()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 32 else { connection.cancel(); return }
        let id = UUID(), peer = Peer(connection); connections[id] = peer
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.close(id) } }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }; peer.timeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive(id)
    }
    private func close(_ id: UUID) {
        guard let peer = connections.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.task?.cancel(); peer.connection.cancel()
    }
    private func receive(_ id: UUID) {
        guard let peer = connections[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, let peer = self.connections[id] else { return }
            if let data { peer.data.append(data) }
            switch MCPHTTPParse.parse(peer.data) {
            case .waiting: if complete || error != nil { self.close(id) } else { self.receive(id) }
            case .rejected(let code): self.respond(id, status: code)
            case .request(let request): self.process(id, request)
            }
        }
    }
    private func process(_ id: UUID, _ r: MCPHTTPRequest) {
        guard let port = listener.port?.rawValue else { respond(id, status: 503); return }
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(r.headers["host"]?.lowercased() ?? "") else { respond(id, status: 403); return }
        if let origin = r.headers["origin"] {
            guard let url = URLComponents(string: origin), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? ""), url.port == Int(port), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { respond(id, status: 403); return }
        }
        let supplied = Array((r.headers["authorization"] ?? "").utf8), expected = Array("Bearer \(token)".utf8)
        var difference = supplied.count ^ expected.count
        for index in expected.indices { difference |= Int(expected[index] ^ (index < supplied.count ? supplied[index] : 0)) }
        guard difference == 0 else { respond(id, status: 401); return }
        guard r.path == "/mcp" else { respond(id, status: 404); return }
        guard r.method == "POST" else { respond(id, status: 405); return }
        guard (r.headers["content-type"] ?? "").lowercased().split(separator: ";").first == "application/json" else { respond(id, status: 415); return }
        if let version = r.headers["mcp-protocol-version"], !MCPProtocol.versions.contains(version) { respond(id, status: 400); return }
        guard let peer = connections[id], !peer.responding else { return }
        peer.responding = true
        peer.task = Task { [weak self, handler] in
            guard !Task.isCancelled else { return }
            let body = await handler(r.body)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in self?.respond(id, status: body == nil ? 202 : 200, body: body ?? Data()) }
        }
    }
    private func respond(_ id: UUID, status: Int, body: Data = Data()) {
        guard let peer = connections[id] else { return }
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 415: "Unsupported Media Type", 417: "Expectation Failed", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if status == 405 { header += "Allow: POST\r\n" }
        if status == 401 { header += "WWW-Authenticate: Bearer realm=\"Teachshelf\"\r\n" }
        let data = Data((header + "\r\n").utf8) + body
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
}
