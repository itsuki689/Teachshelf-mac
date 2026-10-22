import Foundation
import Security
import WebKit
import CryptoKit
import TeachshelfCore

@MainActor protocol TeachingSessionStorage {
    func read(allowInteraction: Bool) throws -> Data?
    func write(_ data: Data, allowInteraction: Bool) throws
    func remove(allowInteraction: Bool) throws
}

/// macOS login keychain, scoped to this app and library. No synchronizable items.
@MainActor final class TeachingSessionKeychain: TeachingSessionStorage {
    private let account: String
    init(profile: String) { account = profile }
    private func query(_ allowInteraction: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.teachshelf.mac.teaching-session",
         kSecAttrAccount as String: account,
         kSecUseAuthenticationUI as String: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
    }
    func read(allowInteraction: Bool) throws -> Data? {
        var query = query(allowInteraction)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw AccessError(status: status) }
        return data
    }
    func write(_ data: Data, allowInteraction: Bool) throws {
        let query = query(allowInteraction)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "课屿 · 教学网站登录"]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; attributes.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccessError(status: status) }
    }
    func remove(allowInteraction: Bool) throws {
        let status = SecItemDelete(query(allowInteraction) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessError(status: status) }
    }
    struct AccessError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "钥匙串暂不可用（\(status)），可解锁后点击重试；仍可手动登录。" }
    }
}

@MainActor protocol TeachingCookieJar {
    func allCookies() async -> [HTTPCookie]
    func setCookie(_ cookie: HTTPCookie) async
}
@MainActor private struct TeachingWebKitCookies: TeachingCookieJar {
    let store: WKHTTPCookieStore
    func allCookies() async -> [HTTPCookie] { await store.allCookies() }
    func setCookie(_ cookie: HTTPCookie) async { await store.setCookie(cookie) }
}

/// Only Moodle's session cookie is eligible. CAS tickets, passwords and username cookies are excluded.
struct TeachingSavedCookie: Codable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let httpOnly: Bool
    init?(_ cookie: HTTPCookie, now: Date) {
        guard Self.allowed(name: cookie.name, domain: cookie.domain, path: cookie.path, value: cookie.value),
              cookie.expiresDate.map({ $0 > now }) ?? true else { return nil }
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        expires = cookie.expiresDate; httpOnly = cookie.isHTTPOnly
    }
    private static func allowed(name: String, domain: String, path: String, value: String) -> Bool {
        name.utf8.count <= 128 && name.range(of: #"^MoodleSession[A-Za-z0-9_-]*$"#, options: .regularExpression) != nil &&
            [TeachingWebsite.host, "." + TeachingWebsite.host].contains(domain.lowercased()) &&
            path.hasPrefix("/") && path.utf8.count <= 1024 && !path.contains("\0") &&
            !value.isEmpty && value.utf8.count <= 8192 && !value.contains("\r") && !value.contains("\n")
    }
    func cookie(now: Date) -> HTTPCookie? {
        guard Self.allowed(name: name, domain: domain, path: path, value: value), expires.map({ $0 > now }) ?? true else { return nil }
        // Older Moodle configurations omit Secure. Restoration is always restricted to HTTPS.
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires } // Preserve session-only semantics when no expiry was provided.
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

struct TeachingSavedSession: Codable {
    let version: Int
    let savedAt: Date
    let cookies: [TeachingSavedCookie]
    func validCookies(now: Date) -> [HTTPCookie]? {
        guard version == 1, savedAt <= now.addingTimeInterval(300), now.timeIntervalSince(savedAt) < 7 * 86_400,
              !cookies.isEmpty, cookies.count <= 8 else { return nil }
        let result = cookies.compactMap { $0.cookie(now: now) }
        return result.count == cookies.count ? result : nil
    }
}

@MainActor final class TeachingLoginSession: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "只保留当前应用内登录"
    @Published private(set) var hasIssue = false
    private let preferences: UserDefaults
    private let preferenceKey: String
    private let storage: TeachingSessionStorage
    private let jar: TeachingCookieJar
    private let cookieStore: WKHTTPCookieStore?
    private var prepared = false
    private var preparation: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var verified = false
    private var mayInvalidateSavedSession = false
    private var closed = false
    private var generation = UUID()
    private var savedCookies: [TeachingSavedCookie] = []

    static func profile(for root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    convenience init(root: URL, cookieStore: WKHTTPCookieStore) {
        let profile = Self.profile(for: root)
        self.init(profile: profile, preferences: .standard, storage: TeachingSessionKeychain(profile: profile), jar: TeachingWebKitCookies(store: cookieStore), cookieStore: cookieStore)
    }
    init(profile: String, preferences: UserDefaults, storage: TeachingSessionStorage, jar: TeachingCookieJar, cookieStore: WKHTTPCookieStore? = nil) {
        self.preferences = preferences; preferenceKey = "teaching.remember-session." + profile
        self.storage = storage; self.jar = jar; self.cookieStore = cookieStore
        enabled = preferences.bool(forKey: preferenceKey)
        super.init()
        if enabled { status = "将从本机钥匙串恢复登录" }
        cookieStore?.add(self)
    }

    /// Must finish before the first request. Concurrent opens share the same restoration.
    func prepare(allowInteraction: Bool = false) async {
        if let preparation { await preparation.value; return }
        guard !closed, !prepared else { return }
        prepared = true
        guard enabled else { return }
        let expected = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let data = try self.storage.read(allowInteraction: allowInteraction) else { self.status = "记住登录已开启，登录成功后保存"; return }
                guard data.count <= 96_000, let record = try? JSONDecoder().decode(TeachingSavedSession.self, from: data),
                      let cookies = record.validCookies(now: Date()) else {
                    try self.storage.remove(allowInteraction: allowInteraction); self.status = "保存的会话已过期，请重新登录"; return
                }
                for cookie in cookies {
                    guard !self.closed, self.enabled, expected == self.generation else { return }
                    await self.jar.setCookie(cookie)
                }
                guard !self.closed, self.enabled, expected == self.generation else { return }
                self.savedCookies = record.cookies; self.mayInvalidateSavedSession = true
                self.status = "已恢复本机会话，等待网站验证"; self.hasIssue = false
            } catch { self.status = error.localizedDescription; self.hasIssue = true }
        }
        preparation = task
        await task.value; preparation = nil
    }

    func setEnabled(_ value: Bool) {
        guard !closed else { return }
        generation = UUID(); capture?.cancel(); capture = nil
        enabled = value; preferences.set(value, forKey: preferenceKey)
        if value {
            status = "记住登录已开启，登录成功后保存"; hasIssue = false
            if verified { capture = Task { [weak self] in await self?.saveNow(allowInteraction: true) } }
        } else {
            do { try storage.remove(allowInteraction: true); savedCookies = []; status = "已关闭并清除保存的登录；当前网页登录保留"; hasIssue = false }
            catch { status = "已停止恢复登录，但钥匙串副本未清除。" + error.localizedDescription; hasIssue = true }
        }
    }
    func didAuthenticate() {
        guard !closed else { return }
        verified = true; mayInvalidateSavedSession = true
        if enabled { scheduleSave() }
    }
    func needsLogin(explicitLogout: Bool = false) {
        verified = false; generation = UUID(); capture?.cancel(); capture = nil; savedCookies = []
        guard enabled else { return }
        // An app update may need renewed keychain permission. A failed read is not
        // evidence that the saved session expired, so never delete it in that case.
        guard mayInvalidateSavedSession || explicitLogout else {
            if !hasIssue { status = "学校要求重新登录，成功后将保存新会话" }
            return
        }
        do { try storage.remove(allowInteraction: false); mayInvalidateSavedSession = false; status = "学校要求重新登录，成功后将保存新会话"; hasIssue = false }
        catch { status = error.localizedDescription; hasIssue = true }
    }
    func saveNow(allowInteraction: Bool = false) async {
        guard !closed, enabled, verified else { return }
        let expected = generation, now = Date()
        let cookies = await jar.allCookies().compactMap { TeachingSavedCookie($0, now: now) }.sorted { ($0.name, $0.domain, $0.path) < ($1.name, $1.domain, $1.path) }
        guard !closed, enabled, verified, generation == expected, !Task.isCancelled else { return }
        guard cookies.count <= 8 else { status = "教学网站会话数量异常，未保存"; hasIssue = true; return }
        if cookies.isEmpty { needsLogin(); return }
        guard cookies != savedCookies else { status = "登录已保存在本机钥匙串"; hasIssue = false; return }
        do {
            let data = try JSONEncoder().encode(TeachingSavedSession(version: 1, savedAt: now, cookies: cookies))
            try storage.write(data, allowInteraction: allowInteraction)
            savedCookies = cookies; status = "登录已保存在本机钥匙串"; hasIssue = false
        } catch { status = error.localizedDescription; hasIssue = true }
    }
    func retry() {
        if !enabled { setEnabled(false); return }
        hasIssue = false
        if verified { capture = Task { [weak self] in await self?.saveNow(allowInteraction: true) } }
        else { prepared = false; Task { [weak self] in await self?.prepare(allowInteraction: true) } }
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { if enabled && verified { scheduleSave() } }
    private func scheduleSave() {
        capture?.cancel()
        capture = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)); await self?.saveNow() } catch {}
        }
    }
    func close() {
        closed = true; generation = UUID(); capture?.cancel(); preparation?.cancel()
        cookieStore?.remove(self)
    }
}
