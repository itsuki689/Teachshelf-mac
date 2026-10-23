import Foundation
import Testing
import TeachshelfCore
@testable import TeachshelfMCPKit

@Suite final class MCPTransportTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPTransport-\(UUID())")
    deinit { try? FileManager.default.removeItem(at: root) }
    func response(_ object: Any) throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try MCPProtocol.response(to: data) { _, _ in throw PlanMCPError("expected tool error") }.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }
    @Test func protocolNegotiationToolsNotificationsAndErrors() throws {
        let initResult = try response(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2099-01-01", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])?["result"] as! [String: Any]
        #expect(initResult["protocolVersion"] as? String == "2025-11-25")
        let tools = try response(["jsonrpc": "2.0", "id": "list", "method": "tools/list"])?["result"] as! [String: Any]
        #expect((tools["tools"] as? [Any])?.count == TeachshelfMCPTools.definitions.count)
        #expect(try response(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let bad = try response(["jsonrpc": "2.0", "id": true, "method": "tools/list"])?["error"] as! [String: Any]
        #expect(bad["code"] as? Int == -32600)
        let call = try response(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "teachshelf_context", "arguments": [:]]])?["result"] as! [String: Any]
        #expect(call["isError"] as? Bool == true)
        var invoked = false
        let notification = Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"teachshelf_create_plan"}}"#.utf8)
        #expect(MCPProtocol.response(to: notification) { _, _ in invoked = true; return [:] } == nil)
        #expect(!invoked)
        #expect(try response([])?["error"] != nil)
    }
    @Test func boundedParserRejectsAmbiguousFraming() {
        let complete = Data("POST /mcp HTTP/1.1\r\nHost: localhost:53141\r\nContent-Length: 2\r\n\r\n{}".utf8)
        if case .waiting = MCPHTTPParse.parse(complete.dropLast()) {} else { Issue.record("fragment must wait") }
        if case .request(let r) = MCPHTTPParse.parse(complete) { #expect(r.body == Data("{}".utf8)) } else { Issue.record("complete request must parse") }
        for headers in ["Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 1048577", "Content-Length : 0"] {
            if case .rejected = MCPHTTPParse.parse(Data("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n{}".utf8)) {} else { Issue.record("unsafe framing accepted") }
        }
        if case .rejected(431) = MCPHTTPParse.parse(Data(repeating: 65, count: 16_385)) {} else { Issue.record("header cap missing") }
    }
    @Test func privateConfigurationAndRotation() throws {
        let url = root.appendingPathComponent("Private/config.json")
        var config = MCPConfiguration(token: try MCPConfiguration.newToken()); try config.save(to: url)
        #expect(try MCPConfiguration.load(from: url) == config)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        #expect(mode.intValue == 0o600)
        let old = config.token; config.token = try MCPConfiguration.newToken(); try config.save(to: url)
        #expect(try MCPConfiguration.load(from: url).token != old)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try MCPConfiguration.load(from: url) }
    }
    @Test func credentialSymlinksAreRejected() throws {
        let target = root.appendingPathComponent("Private/config.json")
        let config = MCPConfiguration(token: try MCPConfiguration.newToken()); try config.save(to: target)
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try MCPConfiguration.load(from: link) }
        #expect(throws: (any Error).self) { try config.save(to: link) }
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock(); private var value = ""
        func set(_ text: String) { lock.lock(); defer { lock.unlock() }; value = text }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }
    func start(_ handler: @escaping @Sendable (Data) async -> Data?) async throws -> (MCPHTTPServer, UInt16, String) {
        let state = State(), token = try MCPConfiguration.newToken()
        let server = try MCPHTTPServer(port: 0, token: token, onState: { state.set($0) }, handler: handler)
        server.start()
        for _ in 0..<100 {
            if let port = state.get().split(separator: ":").last.flatMap({ UInt16($0) }), port > 0 { return (server, port, token) }
            try await Task.sleep(for: .milliseconds(20))
        }
        server.stop(); throw PlanMCPError("listener did not start: \(state.get())")
    }
    @Test func realHTTPAuthenticationOriginAndNotifications() async throws {
        let (server, port, token) = try await start { data in MCPProtocol.response(to: data) { _, _ in ["ok": true] } }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        func status(_ r: URLRequest) async throws -> Int { let (_, response) = try await session.data(for: r); return (response as! HTTPURLResponse).statusCode }
        #expect(try await status(request) == 401)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        #expect(try await status(request) == 200)
        request.setValue("https://attacker.invalid", forHTTPHeaderField: "Origin")
        #expect(try await status(request) == 403)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.setValue("2099-01-01", forHTTPHeaderField: "MCP-Protocol-Version")
        #expect(try await status(request) == 400)
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(try await status(request) == 202)
        request.httpMethod = "GET"; request.httpBody = nil
        #expect(try await status(request) == 405)
    }
    @Test func stdioProcessWritesThroughHTTPIntoRepository() async throws {
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library")), service = PlanMCPService(repository: repository)
        let (server, port, token) = try await start { data in MCPProtocol.response(to: data, call: service.call) }
        defer { server.stop() }
        let configURL = root.appendingPathComponent("Config/config.json")
        try MCPConfiguration(port: port, token: token).save(to: configURL)
        let id = UUID().uuidString
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "teachshelf_create_plan", "arguments": ["library_id": service.libraryID, "request_id": id, "fields": ["title": "中文与 emoji 📚", "content": "第一行\n第二行"]]]]
        ]
        let responses = try await stdio(messages, configURL: configURL)
        #expect(responses.count == 2)
        #expect(repository.state.tasks.first?.id.uuidString == id)
        #expect(repository.state.tasks.first?.content == "第一行\n第二行")
    }
    @Test func stdioProcessRenamesMaterialAndReadsCommittedMetadata() async throws {
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let source = root.appendingPathComponent("fixture.txt")
        try Data("MCP fixture".utf8).write(to: source)
        _ = try repository.importFiles(urls: [source], courseID: nil, category: "笔记", copy: true)
        let material = repository.state.materials[0], service = LibraryMCPService(repository: repository)
        let oldURL = try repository.resolveURL(material)
        let revision = try service.context()["library_revision"] as! String
        let (server, port, token) = try await start { data in MCPProtocol.response(to: data, call: service.call) }
        defer { server.stop() }
        let configURL = root.appendingPathComponent("Config/config.json")
        try MCPConfiguration(port: port, token: token).save(to: configURL)
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "teachshelf_update_material", "arguments": ["library_id": service.libraryID, "expected_library_revision": revision, "id": material.id.uuidString, "patch": ["filename": "第一章.txt", "notes": "下次复习", "favorite": true]]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "teachshelf_get_material", "arguments": ["id": material.id.uuidString]]]
        ]
        let responses = try await stdio(messages, configURL: configURL)
        #expect(responses.count == 2)
        for response in responses {
            #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
        }
        let record = repository.state.materials[0], newURL = try repository.resolveURL(record)
        #expect(record.notes == "下次复习" && record.isFavorite && newURL.lastPathComponent == "第一章.txt")
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try Data(contentsOf: newURL) == Data(contentsOf: source))
        let result = responses.last?["result"] as? [String: Any]
        let content = result?["structuredContent"] as? [String: Any]
        #expect((content?["material"] as? [String: Any])?["notes"] as? String == "下次复习")
    }
    private func stdio(_ messages: [[String: Any]], configURL: URL) async throws -> [[String: Any]] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = project.appendingPathComponent(".build/debug/TeachshelfMCP")
        process.arguments = ["--config", configURL.path]; process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for message in messages { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10])) }
        try input.fileHandleForWriting.close()
        for _ in 0..<250 { if !process.isRunning { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(!process.isRunning)
        if process.isRunning { return [] }
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: 10)
        #expect(process.terminationStatus == 0)
        #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        return try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }
}
