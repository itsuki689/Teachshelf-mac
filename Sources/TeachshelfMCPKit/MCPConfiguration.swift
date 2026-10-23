import Foundation
import Security
import Darwin

public struct MCPConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var port: UInt16
    public var token: String
    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TeachshelfMCP/config.json")
    }
    public init(enabled: Bool = true, port: UInt16 = 53141, token: String) { self.enabled = enabled; self.port = port; self.token = token }
    public static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func load(from url: URL = defaultURL) throws -> MCPConfiguration {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw NSError(domain: "TeachshelfMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "MCP 配置必须由当前用户拥有，且仅当前用户可读写（0600）。"])
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.port >= 1024, value.token.count == 64, value.token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    public func save(to url: URL = defaultURL) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fm.fileExists(atPath: url.path) { _ = try Self.load(from: url) }
        // Stage privately before rename: atomic Data.write alone can create a world-readable temporary.
        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(self)); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
