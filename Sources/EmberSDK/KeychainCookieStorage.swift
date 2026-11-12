import Foundation
import Security

/// Somewhere a `KeychainCookieStorage` keeps its cookies between launches: a Keychain item, or
/// memory in tests. Each call throws when the vault couldn't do it, which is not the same as there
/// being nothing kept: `read()` answers nil for that.
public protocol CookieVault: Sendable {
    /// What was last written; nil when nothing was, or it was erased. Throws when it can't be read.
    func read() throws -> Data?
    /// Keeps `data` in place of what was.
    func write(_ data: Data) throws
    /// Forgets what was written. Nothing to forget isn't a failure.
    func erase() throws
}

/// One generic-password item in the Keychain, read after the device's first unlock (so a session
/// can reconnect in the background) and never synced or restored to another device.
public struct KeychainCookieVault: CookieVault {
    /// The service every account's cookies are kept under.
    public static let defaultService = "Ember session cookies"

    /// What a Keychain call that failed answered, such as `errSecInteractionNotAllowed` while the
    /// device is locked.
    public struct Failure: Error, Equatable, Sendable {
        public let status: OSStatus
    }

    public let service: String
    public let account: String

    public init(account: String, service: String = KeychainCookieVault.defaultService) {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    public func erase() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// The account of every item kept under `service`, so an app can erase those it no longer
    /// holds an account for. Empty when the Keychain can't be read.
    public static func accounts(service: String = KeychainCookieVault.defaultService) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// A vault in memory, gone with it: for tests. It never fails.
public final class MemoryCookieVault: CookieVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var writes = 0

    public init(_ data: Data? = nil) {
        self.data = data
    }

    public func read() -> Data? { lock.withLock { data } }
    public func write(_ data: Data) { lock.withLock { self.data = data; writes += 1 } }
    public func erase() { lock.withLock { data = nil } }

    /// How many times it's been written.
    public var writeCount: Int { lock.withLock { writes } }
}

/// One account's cookies, in memory as `EphemeralCookieStorage` keeps them and written to `vault`
/// whenever they change, so the session outlives the app. Each account signed in on the device has
/// its own, under its own name: two people signed in to one server never share or overwrite each
/// other's session cookie, as they would in `HTTPCookieStorage.shared`.
///
/// The vault can refuse, as the Keychain does while a device is locked after a restart. A write it
/// refused is tried again at the next change, or by `syncVault()`. When the first read failed,
/// `readFailure` says why and the storage starts empty, but it never erases or overwrites the kept
/// item just because it holds nothing: only new cookies (a new sign-in) or `eraseAll()` replace it.
/// `syncVault()` reads it again, and takes what's kept if nothing has been set meanwhile.
public final class KeychainCookieStorage: EphemeralCookieStorage, @unchecked Sendable {
    public let vault: any CookieVault
    private let writeLock = NSLock()
    /// What the vault is known to hold.
    private var kept: Kept
    private var unread: (any Error)?

    private enum Kept: Equatable {
        /// Not known: the first read failed, and nothing has been written since.
        case unread
        /// Something `eraseAll()` couldn't erase.
        case stale
        /// These bytes, or nothing.
        case holds(Data?)
    }

    /// The cookies kept in `vault`, which keeps every change from now on. A vault that can't be read
    /// gives an empty storage, with `readFailure` set.
    public init(vault: any CookieVault) {
        self.vault = vault
        var cookies: [HTTPCookie] = []
        do {
            let data = try vault.read()
            kept = .holds(data)
            cookies = data.map(Self.cookies(from:)) ?? []
        } catch {
            kept = .unread
            unread = error
        }
        super.init(holding: cookies)
    }

    /// The cookies kept in the Keychain item for `account`.
    public convenience init(account: String, service: String = KeychainCookieVault.defaultService) {
        self.init(vault: KeychainCookieVault(account: account, service: service))
    }

    /// Why the vault couldn't be read, while it hasn't been: nil once it has, or once a write has
    /// replaced what it kept.
    public var readFailure: (any Error)? {
        writeLock.withLock { unread }
    }

    /// Brings the vault up to date now, rather than at the next change, as when the app comes to the
    /// foreground: reads it again if that failed before, taking its cookies if none have been set
    /// since, and writes what it refused before. True when the vault holds what the storage does.
    @discardableResult
    public func syncVault() -> Bool {
        let loaded: [HTTPCookie]? = writeLock.withLock {
            guard kept == .unread else { return nil }
            do {
                let data = try vault.read()
                kept = .holds(data)
                unread = nil
                return data.map(Self.cookies(from:)) ?? []
            } catch {
                unread = error
                return nil
            }
        }
        // A change, which writes what's held if that differs from what was read.
        if let loaded { holdIfEmpty(loaded) }
        return writeLock.withLock { push(Self.data(from: cookies ?? [])) }
    }

    /// Forgets every cookie, and the vault's item with them, even one that couldn't be read. An
    /// item the vault wouldn't erase is erased at the next change or `syncVault()`.
    public func eraseAll() {
        for cookie in cookies ?? [] { deleteCookie(cookie) }
        writeLock.withLock {
            do {
                try vault.erase()
                kept = .holds(nil)
            } catch {
                kept = .stale
            }
            unread = nil
        }
    }

    override func changed(_ cookies: [HTTPCookie]) {
        writeLock.withLock {
            // Read again under the write lock rather than taken from the change, so two changes on
            // different threads can't write in the wrong order.
            _ = push(Self.data(from: self.cookies ?? []))
        }
    }

    /// Writes `data` (erases, for no cookies) unless the vault holds it already, or its item
    /// couldn't be read and there's nothing to put in its place. True when the vault is up to date.
    /// Called under the write lock.
    private func push(_ data: Data) -> Bool {
        let wanted = data == Self.empty ? nil : data
        // A response that sets what's already kept doesn't write the Keychain again.
        if kept == .holds(wanted) { return true }
        if kept == .unread && wanted == nil { return false }
        do {
            if let wanted { try vault.write(wanted) } else { try vault.erase() }
            kept = .holds(wanted)
            unread = nil
            return true
        } catch {
            return false
        }
    }

    /// What's written of no cookies.
    private static let empty = data(from: [])


    /// What's written of a cookie: all `EmberClient` reads back.
    struct Saved: Codable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sameSite = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }

    static func data(from cookies: [HTTPCookie]) -> Data {
        let saved = cookies.map(Saved.init).sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(saved)) ?? Data()
    }

    static func cookies(from data: Data) -> [HTTPCookie] {
        ((try? JSONDecoder().decode([Saved].self, from: data)) ?? []).compactMap(\.cookie)
    }
}
