import Foundation
import Testing
@testable import Teachshelf

@MainActor struct TeachingLoginSessionTests {
    private final class Storage: TeachingSessionStorage {
        var data: Data?
        var reads = 0
        var writes = 0
        var deletes = 0
        var fail = false
        func read(allowInteraction: Bool) throws -> Data? { reads += 1; if fail { throw Failure() }; return data }
        func write(_ data: Data, allowInteraction: Bool) throws { if fail { throw Failure() }; self.data = data; writes += 1 }
        func remove(allowInteraction: Bool) throws { if fail { throw Failure() }; data = nil; deletes += 1 }
        struct Failure: LocalizedError { var errorDescription: String? { "测试钥匙串不可用" } }
    }
    private final class Jar: TeachingCookieJar {
        var cookies: [HTTPCookie] = []
        var installed: [HTTPCookie] = []
        var delayedRead: CheckedContinuation<[HTTPCookie], Never>?
        var delay = false
        func allCookies() async -> [HTTPCookie] {
            if delay { return await withCheckedContinuation { delayedRead = $0 } }
            return cookies
        }
        func setCookie(_ cookie: HTTPCookie) async { installed.append(cookie) }
    }
    private func cookie(name: String = "MoodleSession", domain: String = "selearning.nju.edu.cn", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "opaque-test-session", .domain: domain, .path: "/", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    private func fixture() -> (UserDefaults, String, Storage, Jar, TeachingLoginSession) {
        let suite = "Teachshelf-session-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let storage = Storage(), jar = Jar()
        let session = TeachingLoginSession(profile: "test", preferences: preferences, storage: storage, jar: jar)
        return (preferences, suite, storage, jar, session)
    }

    @Test func optInSavesOnlyTeachingSessionAndRestoresBeforeTheNextLaunch() async throws {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        jar.cookies = [cookie(), cookie(name: "MOODLEID1_"), cookie(name: "CASTGC", domain: "authserver.nju.edu.cn"), cookie(domain: ".nju.edu.cn")]
        await session.prepare(); session.didAuthenticate(); await session.saveNow()
        #expect(storage.reads == 0 && storage.writes == 0 && storage.data == nil)
        session.setEnabled(true); await session.saveNow()
        let saved = try JSONDecoder().decode(TeachingSavedSession.self, from: #require(storage.data))
        #expect(saved.cookies.count == 1 && saved.cookies.first?.name == "MoodleSession")
        let jarAfterRestart = Jar()
        let restarted = TeachingLoginSession(profile: "test", preferences: preferences, storage: storage, jar: jarAfterRestart)
        defer { restarted.close() }
        await restarted.prepare()
        #expect(restarted.enabled && jarAfterRestart.installed.count == 1)
        let restored = try #require(jarAfterRestart.installed.first)
        #expect(restored.value == "opaque-test-session" && restored.isSecure && restored.isHTTPOnly && restored.isSessionOnly)
        #expect(restored.expiresDate == nil && restored.domain == "selearning.nju.edu.cn")
        await restarted.prepare()
        #expect(jarAfterRestart.installed.count == 1)
    }

    @Test func disableRemovesTheSecretAndThePreferenceWithoutLoggingOutTheCurrentPage() async {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        jar.cookies = [cookie()]; session.setEnabled(true); session.didAuthenticate(); await session.saveNow()
        #expect(storage.data != nil)
        session.setEnabled(false)
        #expect(storage.data == nil && !session.enabled && jar.cookies.count == 1)
        let restarted = TeachingLoginSession(profile: "test", preferences: preferences, storage: storage, jar: Jar())
        defer { restarted.close() }
        await restarted.prepare(); #expect(!restarted.enabled)
    }

    @Test func disablingDuringCookieReadCannotResaveTheSecret() async {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        session.setEnabled(true); session.didAuthenticate(); jar.delay = true
        let save = Task { await session.saveNow() }
        while jar.delayedRead == nil { await Task.yield() }
        session.setEnabled(false)
        jar.delayedRead?.resume(returning: [cookie()]); jar.delayedRead = nil
        await save.value
        #expect(storage.data == nil && storage.writes == 0)
    }

    @Test func rejectedSessionClearsSavedCredentialsAndAnonymousCookiesAreNotSaved() async {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        jar.cookies = [cookie()]; session.setEnabled(true); session.didAuthenticate(); await session.saveNow()
        session.needsLogin(); await session.saveNow()
        #expect(storage.data == nil)
        session.didAuthenticate(); await session.saveNow()
        #expect(storage.data != nil)
    }

    @Test func expiredOrMalformedSavedSessionsNeverReachWebKit() async throws {
        let (preferences, suite, storage, _, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        session.setEnabled(true)
        let old = TeachingSavedSession(version: 1, savedAt: Date().addingTimeInterval(-8 * 86_400), cookies: [TeachingSavedCookie(cookie(), now: Date())!])
        for data in [try JSONEncoder().encode(old), Data("corrupt".utf8)] {
            storage.data = data
            let jar = Jar()
            let checked = TeachingLoginSession(profile: "test", preferences: preferences, storage: storage, jar: jar)
            await checked.prepare()
            #expect(jar.installed.isEmpty && storage.data == nil)
            checked.close()
        }
        let expired = cookie(expires: Date().addingTimeInterval(-1))
        #expect(TeachingSavedCookie(expired, now: Date()) == nil)
        let future = TeachingSavedSession(version: 1, savedAt: Date().addingTimeInterval(3600), cookies: [])
        #expect(future.validCookies(now: Date()) == nil)
    }

    @Test func keychainFailureHasNoPlaintextFallbackAndCanBeRetried() async {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        storage.fail = true; session.setEnabled(true); jar.cookies = [cookie()]
        session.didAuthenticate(); await session.saveNow()
        #expect(storage.data == nil && session.hasIssue)
        storage.fail = false; await session.saveNow()
        #expect(storage.data != nil && !session.hasIssue)
    }

    @Test func websiteCookieRemovalAlsoRemovesTheSavedSession() async {
        let (preferences, suite, storage, jar, session) = fixture()
        defer { session.close(); preferences.removePersistentDomain(forName: suite) }
        jar.cookies = [cookie()]; session.setEnabled(true); session.didAuthenticate(); await session.saveNow()
        #expect(storage.data != nil)
        jar.cookies = []; await session.saveNow()
        #expect(storage.data == nil)
    }

    @Test func libraryProfilesAreStableAndIsolated() {
        let a = URL(fileURLWithPath: "/tmp/library-a"), b = URL(fileURLWithPath: "/tmp/library-b")
        #expect(TeachingLoginSession.profile(for: a) == TeachingLoginSession.profile(for: a.appendingPathComponent(".")))
        #expect(TeachingLoginSession.profile(for: a) != TeachingLoginSession.profile(for: b))
    }

    @Test func decodedRecordsCannotRestoreOtherDomainsOrCredentialNames() throws {
        let now = Date(), valid = TeachingSavedSession(version: 1, savedAt: now, cookies: [TeachingSavedCookie(cookie(), now: now)!])
        let data = try JSONEncoder().encode(valid)
        for (field, replacement) in [("domain", "authserver.nju.edu.cn"), ("name", "CASTGC"), ("path", "relative") ] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var cookies = try #require(object["cookies"] as? [[String: Any]])
            cookies[0][field] = replacement; object["cookies"] = cookies
            let decoded = try JSONDecoder().decode(TeachingSavedSession.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.validCookies(now: now) == nil)
        }
    }

    @Test func olderMoodleSessionCookiesAreRestoredAsHTTPSOnly() throws {
        let now = Date(), original = cookie(secure: false)
        #expect(!original.isSecure)
        let saved = try #require(TeachingSavedCookie(original, now: now))
        let restored = try #require(saved.cookie(now: now))
        #expect(restored.isSecure && restored.value == original.value && restored.expiresDate == original.expiresDate)
    }
}
