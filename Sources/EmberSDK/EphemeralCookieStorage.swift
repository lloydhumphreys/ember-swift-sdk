import Foundation

/// Cookies kept in memory only, for a client that mustn't share `HTTPCookieStorage.shared`: tests,
/// previews, or a second account signed in alongside the first.
///
/// (A plain `HTTPCookieStorage()` keeps nothing, so this stands in for one.) It does what
/// `EmberClient` asks of a cookie storage: keeps what `Set-Cookie` sets, forgets expired cookies,
/// and answers the cookies that go with an address by domain, path and `Secure`.
public final class EphemeralCookieStorage: HTTPCookieStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HTTPCookie] = []
    private var added: [ObjectIdentifier: Date] = [:]

    /// An empty storage.
    public override init() {
        super.init()
    }

    /// Every cookie kept, expired ones left out.
    public override var cookies: [HTTPCookie]? {
        lock.withLock { live() }
    }

    /// Keeps `cookie` in place of any with its name, domain and path, or forgets that one when it has
    /// expired, as a sign-out's `Set-Cookie` does.
    public override func setCookie(_ cookie: HTTPCookie) {
        lock.withLock {
            stored.removeAll { Self.same($0, cookie) }
            if let expires = cookie.expiresDate, expires <= Date() { return }
            stored.append(cookie)
            added[ObjectIdentifier(cookie)] = Date()
        }
    }

    /// Forgets `cookie`.
    public override func deleteCookie(_ cookie: HTTPCookie) {
        lock.withLock { stored.removeAll { Self.same($0, cookie) } }
    }

    /// Forgets every cookie set since `date`.
    public override func removeCookies(since date: Date) {
        lock.withLock { stored.removeAll { (added[ObjectIdentifier($0)] ?? .distantPast) >= date } }
    }

    /// Keeps each of `cookies`.
    public override func setCookies(_ cookies: [HTTPCookie], for URL: URL?, mainDocumentURL: URL?) {
        for cookie in cookies { setCookie(cookie) }
    }

    /// The cookies a request to `url` sends.
    public override func cookies(for url: URL) -> [HTTPCookie]? {
        guard let host = url.host()?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = ["https", "wss"].contains(url.scheme?.lowercased() ?? "")
        return lock.withLock {
            live().filter { cookie in
                Self.domain(cookie.domain, matches: host)
                    && Self.path(cookie.path, matches: path)
                    && (!cookie.isSecure || secure)
            }
        }
    }

    /// The cookies a request to `task`'s address sends.
    public override func getCookiesFor(_ task: URLSessionTask, completionHandler: @escaping @Sendable ([HTTPCookie]?) -> Void) {
        completionHandler(task.currentRequest?.url.flatMap { cookies(for: $0) })
    }

    /// Keeps `cookies`.
    public override func storeCookies(_ cookies: [HTTPCookie], for task: URLSessionTask) {
        setCookies(cookies, for: task.currentRequest?.url, mainDocumentURL: nil)
    }

    private func live() -> [HTTPCookie] {
        let now = Date()
        return stored.filter { $0.expiresDate.map { $0 > now } ?? true }
    }

    private static func same(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.name == b.name && a.domain.lowercased() == b.domain.lowercased() && a.path == b.path
    }

    private static func domain(_ domain: String, matches host: String) -> Bool {
        let domain = domain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }

    private static func path(_ cookiePath: String, matches path: String) -> Bool {
        if cookiePath.isEmpty || cookiePath == "/" { return true }
        if path == cookiePath { return true }
        return path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
    }
}
