import Foundation
import Testing
@testable import Teachshelf

private final class AIHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest, Data) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; body.append(buffer, count: size) }
        }
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        let (status, data) = handler?(request, body) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct AIChatClientTests {
    func client(_ handler: @escaping (URLRequest, Data) -> (Int, Data)) -> AIChatClient {
        AIHTTPFixture.lock.lock(); AIHTTPFixture.handler = handler; AIHTTPFixture.lock.unlock()
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [AIHTTPFixture.self]
        return AIChatClient(configuration: AIConfiguration(endpoint: "https://fixture.invalid/v1", model: "fixture", reasoningDisabled: true), key: "fixture-key", sessionConfiguration: session)
    }
    @Test func actualHTTPEncodingAndToolCapabilityProbe() async throws {
        let client = client { request, data in
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(body["reasoning_effort"] as? String == "none")
            #expect(body["stream"] as? Bool == false)
            #expect((body["messages"] as? [[String: Any]])?.count == 1)
            let tools = body["tools"] as! [[String: Any]]
            #expect(tools.count == 1 && (tools[0]["function"] as? [String: Any])?["name"] as? String == "connection_test")
            return (200, Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"test","type":"function","function":{"name":"connection_test","arguments":"{\"ok\":true}"}}]}}]}"#.utf8))
        }
        try await client.testConnection()
    }
    @Test func serviceErrorsDoNotExposeResponseBodiesAndTextOnlyModelsFailProbe() async throws {
        for status in [401, 429, 302] {
            let client = client { _, _ in (status, Data("private server details and fixture-key".utf8)) }
            do { try await client.testConnection(); Issue.record("HTTP error was accepted") }
            catch { #expect(!error.localizedDescription.contains("fixture-key")); #expect(error.localizedDescription.contains("\(status)")) }
        }
        let client = client { _, _ in (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#.utf8)) }
        await #expect(throws: (any Error).self) { try await client.testConnection() }
    }
    @Test func redirectsNeverForwardCredentials() async {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://untrusted.invalid/redirect")!)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        var redirected = true
        AINoRedirect().urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 != nil }
        #expect(!redirected)
    }
}
