import Foundation
import Security
import TeachshelfCore

struct AIConfiguration: Codable, Equatable {
    var endpoint = ""
    var model = ""
    var reasoningDisabled = false
    var isConfigured: Bool { (try? completionURL()) != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func completionURL() throws -> URL {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw PlanMCPError("请填写有效的 HTTP 或 HTTPS API 地址，不包含密钥、查询参数或用户密码。")
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        guard let url = parts.url else { throw PlanMCPError("API 地址无效。") }
        return url
    }

    static func load(defaults: UserDefaults = .standard) -> AIConfiguration {
        guard let data = defaults.data(forKey: "aiAssistantConfiguration"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) throws {
        _ = try completionURL()
        guard isConfigured else { throw PlanMCPError("请填写模型名称。") }
        defaults.set(try JSONEncoder().encode(self), forKey: "aiAssistantConfiguration")
    }
}

/// Credentials are scoped to the exact completion endpoint, outside the library and backups.
/// Access happens only after Send or opening/saving model settings, so Keychain may ask the user.
enum AIKeychain {
    private static func query(_ config: AIConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.teachshelf.mac.ai-api-key",
         kSecAttrAccount as String: try config.completionURL().absoluteString,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow]
    }
    static func read(_ config: AIConfiguration) throws -> String {
        var q = try query(config)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw PlanMCPError("无法读取 AI 密钥，请解锁钥匙串后重试（\(status)）。")
        }
        return key
    }
    static func save(_ key: String, config: AIConfiguration) throws {
        let q = try query(config)
        if key.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PlanMCPError("无法清除 AI 密钥（\(status)）。") }
            return
        }
        guard !key.contains("\n"), !key.contains("\r"), key.utf8.count <= 8192 else { throw PlanMCPError("API Key 格式无效。") }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrLabel as String: "课屿 · AI 模型密钥"]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(values) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PlanMCPError("无法保存 AI 密钥（\(status)）。") }
    }
}
