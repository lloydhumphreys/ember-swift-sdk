import Foundation
import Testing
@testable import EmberSDK
import EmberTesting

@Suite struct KeychainCookieStorageTests {
    private let origin = URL(string: "https://chat.ember.test")!

    private func cookie(_ name: String = "__Host-session_token", value: String, expires: Date = Date().addingTimeInterval(3600)) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: "chat.ember.test", .path: "/",
            .expires: expires, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ])!
    }

    @Test func whatItKeepsIsThereForTheNextStorageOnTheSameVault() throws {
        let vault = MemoryCookieVault()
        let expires = Date().addingTimeInterval(86_400).rounded
        KeychainCookieStorage(vault: vault).setCookie(cookie(value: "abc", expires: expires))

        let again = try #require(KeychainCookieStorage(vault: vault).cookies(for: origin)?.first)
        #expect(again.name == "__Host-session_token")
        #expect(again.value == "abc")
        #expect(again.isSecure)
        #expect(again.isHTTPOnly)
        #expect(again.path == "/")
        #expect(again.expiresDate?.rounded == expires)
    }

    @Test func twoAccountsOnOneServerKeepTheirOwnSession() {
        let first = KeychainCookieStorage(vault: MemoryCookieVault())
        let second = KeychainCookieStorage(vault: MemoryCookieVault())
        first.setCookie(cookie(value: "first"))
        second.setCookie(cookie(value: "second"))

        #expect(first.cookies(for: origin)?.map(\.value) == ["first"])
        #expect(second.cookies(for: origin)?.map(\.value) == ["second"])
    }

    @Test func settingWhatIsAlreadyKeptDoesNotWriteAgain() {
        let vault = MemoryCookieVault()
        let storage = KeychainCookieStorage(vault: vault)
        let expires = Date().addingTimeInterval(3600)
        storage.setCookie(cookie(value: "abc", expires: expires))
        storage.setCookie(cookie(value: "abc", expires: expires))
        #expect(vault.writeCount == 1)

        storage.setCookie(cookie(value: "def", expires: expires))
        #expect(vault.writeCount == 2)
    }

    @Test func anExpiredSetCookieErasesTheVault() {
        let vault = MemoryCookieVault()
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "abc"))
        #expect(vault.read() != nil)

        storage.setCookie(cookie(value: "", expires: Date().addingTimeInterval(-1)))
        #expect(storage.cookies(for: origin)?.isEmpty == true)
        #expect(vault.read() == nil)
    }

    @Test func erasingAllForgetsEveryCookieAndTheVault() {
        let vault = MemoryCookieVault()
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "abc"))
        storage.setCookie(cookie("other", value: "x"))

        storage.eraseAll()
        #expect(storage.cookies?.isEmpty == true)
        #expect(vault.read() == nil)
        #expect(KeychainCookieStorage(vault: vault).cookies?.isEmpty == true)
    }

    @Test func cookiesThatExpiredWhileTheAppWasAwayAreLeftOut() {
        let vault = MemoryCookieVault(KeychainCookieStorage.data(from: [cookie(value: "old", expires: Date().addingTimeInterval(-60))]))
        #expect(KeychainCookieStorage(vault: vault).cookies?.isEmpty == true)
    }

    @Test func unreadableBytesInTheVaultAreNoCookies() {
        #expect(KeychainCookieStorage(vault: MemoryCookieVault(Data("not json".utf8))).cookies?.isEmpty == true)
    }

    @Test func twoClientsOnOneServerSignInAndOutWithoutTouchingEachOther() async throws {
        let firstVault = MemoryCookieVault()
        let secondVault = MemoryCookieVault()
        let first = EmberClient.mock(origin: origin, transport: signingIn(token: "first"), cookies: KeychainCookieStorage(vault: firstVault))
        let second = EmberClient.mock(origin: origin, transport: signingIn(token: "second"), cookies: KeychainCookieStorage(vault: secondVault))

        _ = try await first.signIn(emailAddress: "a@example.com", password: "pw")
        _ = try await second.signIn(emailAddress: "b@example.com", password: "pw")
        #expect(first.cookies.cookies(for: origin)?.map(\.value) == ["first"])
        #expect(second.cookies.cookies(for: origin)?.map(\.value) == ["second"])

        await first.signOut()
        #expect(!first.hasSessionCookie)
        #expect(firstVault.read() == nil)
        #expect(second.hasSessionCookie)
        #expect(KeychainCookieStorage(vault: secondVault).cookies(for: origin)?.map(\.value) == ["second"])
    }

    /// A server that signs in by setting the session cookie to `token`.
    private func signingIn(token: String) -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        transport.stub("POST", "/api/session", status: 201, json: Fixtures.meJSON(),
                       headers: ["Set-Cookie": "__Host-session_token=\(token); Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax"])
        transport.stub("DELETE", "/api/session", status: 204, json: "",
                       headers: ["Set-Cookie": "__Host-session_token=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"])
        return transport
    }
}

private extension Date {
    /// To the second, as a cookie's expiry is kept.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// A vault in memory that refuses to read, or to write and erase, while told to.
private final class FailingCookieVault: CookieVault, @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var data: Data?
    private var refusingReads = false
    private var refusingWrites = false

    init(_ data: Data? = nil, failReads: Bool = false, failWrites: Bool = false) {
        self.data = data
        refusingReads = failReads
        refusingWrites = failWrites
    }

    var failReads: Bool {
        get { lock.withLock { refusingReads } }
        set { lock.withLock { refusingReads = newValue } }
    }

    var failWrites: Bool {
        get { lock.withLock { refusingWrites } }
        set { lock.withLock { refusingWrites = newValue } }
    }

    /// What it holds, failing or not.
    var held: Data? { lock.withLock { data } }

    func read() throws -> Data? {
        try lock.withLock {
            if refusingReads { throw Refused() }
            return data
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            if refusingWrites { throw Refused() }
            self.data = data
        }
    }

    func erase() throws {
        try lock.withLock {
            if refusingWrites { throw Refused() }
            data = nil
        }
    }
}

@Suite struct KeychainCookieStorageFailureTests {
    private let origin = URL(string: "https://chat.ember.test")!

    private func cookie(_ name: String = "__Host-session_token", value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: "chat.ember.test", .path: "/",
            .expires: Date().addingTimeInterval(3600), .secure: "TRUE",
        ])!
    }

    private func values(in data: Data?) -> [String] {
        data.map { KeychainCookieStorage.cookies(from: $0).map(\.value) } ?? []
    }

    @Test func aRefusedWriteIsTriedAgainAtTheNextChange() {
        let vault = FailingCookieVault(failWrites: true)
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "abc"))
        #expect(vault.held == nil)

        vault.failWrites = false
        storage.setCookie(cookie("other", value: "x"))
        #expect(Set(values(in: vault.held)) == ["abc", "x"])
    }

    @Test func aRefusedWriteIsTriedAgainBySyncingTheVault() {
        let vault = FailingCookieVault(failWrites: true)
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "abc"))
        #expect(storage.syncVault() == false)
        #expect(vault.held == nil)

        vault.failWrites = false
        #expect(storage.syncVault())
        #expect(values(in: vault.held) == ["abc"])
    }

    @Test func aFailedReadIsNotErasedByAChangeThatLeavesNoCookies() {
        let kept = KeychainCookieStorage.data(from: [cookie(value: "kept")])
        let vault = FailingCookieVault(kept, failReads: true)
        let storage = KeychainCookieStorage(vault: vault)
        #expect(storage.readFailure is FailingCookieVault.Refused)
        #expect(storage.cookies?.isEmpty == true)

        storage.removeCookies(since: .distantPast)
        storage.setCookie(HTTPCookie(properties: [
            .name: "gone", .value: "", .domain: "chat.ember.test", .path: "/",
            .expires: Date().addingTimeInterval(-1),
        ])!)
        #expect(vault.held == kept)
    }

    @Test func syncingTheVaultAfterAFailedReadLoadsWhatIsKept() {
        let kept = KeychainCookieStorage.data(from: [cookie(value: "kept")])
        let vault = FailingCookieVault(kept, failReads: true)
        let storage = KeychainCookieStorage(vault: vault)
        #expect(storage.syncVault() == false)
        #expect(storage.readFailure != nil)

        vault.failReads = false
        #expect(storage.syncVault())
        #expect(storage.readFailure == nil)
        #expect(storage.cookies(for: origin)?.map(\.value) == ["kept"])
        #expect(vault.held == kept)
    }

    @Test func aNewSignInAfterAFailedReadReplacesWhatIsKept() {
        let vault = FailingCookieVault(KeychainCookieStorage.data(from: [cookie(value: "old")]), failReads: true)
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "new"))
        #expect(values(in: vault.held) == ["new"])
        #expect(storage.readFailure == nil)

        // Read again now, it keeps what was set since rather than what was kept before.
        vault.failReads = false
        #expect(storage.syncVault())
        #expect(storage.cookies(for: origin)?.map(\.value) == ["new"])
    }

    @Test func erasingAllAfterAFailedReadErasesTheVault() {
        let vault = FailingCookieVault(KeychainCookieStorage.data(from: [cookie(value: "kept")]), failReads: true)
        let storage = KeychainCookieStorage(vault: vault)
        storage.eraseAll()
        #expect(vault.held == nil)
        #expect(storage.readFailure == nil)
        #expect(storage.syncVault())
    }

    @Test func anEraseTheVaultRefusedIsTriedAgain() {
        let vault = FailingCookieVault()
        let storage = KeychainCookieStorage(vault: vault)
        storage.setCookie(cookie(value: "abc"))
        vault.failWrites = true
        storage.eraseAll()
        #expect(vault.held != nil)

        vault.failWrites = false
        #expect(storage.syncVault())
        #expect(vault.held == nil)
    }
}
