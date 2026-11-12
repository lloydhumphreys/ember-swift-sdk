import Foundation
import Synchronization

/// One Ember server, as the person using this app knows it: its HTTP API, its cookies, and the
/// sockets it opens.
///
/// Everything goes through two seams, `transport` for HTTP and `connector` for sockets, so tests and
/// previews hand it EmberTesting's mocks (`EmberClient.mock()`) and nothing touches the network.
/// Every method fails with `EmberError`.
///
/// The client attaches the session cookie itself from `cookies` and keeps what the server sets
/// there, so the same rules hold over any transport.
public final class EmberClient: Sendable {
    /// The server's origin, such as `https://chat.example.com`: lowercased, with no default port
    /// and nothing after the host, as `ServerAddress.normalizedOrigin(_:)` writes it.
    public let origin: URL
    /// Where HTTP requests go.
    public let transport: any HTTPTransport
    /// Where sockets open.
    public let connector: any SocketConnector
    /// Where the session cookie is kept.
    public let cookies: HTTPCookieStorage
    /// The intervals this client's sockets and stores wait on.
    public let timing: EmberTiming
    /// Where this client's sockets hear whether there's a network.
    public let network: any NetworkPathSource

    private let signedOutHandlers = SignedOutHandlers()
    private let lastSignOut = Mutex<SignOutReason?>(nil)

    /// The real thing: URLSession, with cookies in `HTTPCookieStorage.shared`, which is what keeps
    /// someone signed in between launches.
    public convenience init(origin: URL) {
        self.init(origin: origin, cookies: .shared)
    }

    /// URLSession, with cookies kept in `cookies`: an `EphemeralCookieStorage` keeps a session apart
    /// from the app's own, as the live tests do.
    public convenience init(origin: URL, cookies: HTTPCookieStorage) {
        let session = URLSessionHTTPTransport.makeSession()
        self.init(
            origin: origin,
            transport: URLSessionHTTPTransport(session: session),
            connector: URLSessionSocketConnector(session: session),
            cookies: cookies,
            network: SystemNetworkPath()
        )
    }

    /// Any transports: what tests and previews use. Its sockets take the network to be always there.
    public convenience init(origin: URL, transport: any HTTPTransport, connector: any SocketConnector, cookies: HTTPCookieStorage = .shared, timing: EmberTiming = .standard) {
        self.init(origin: origin, transport: transport, connector: connector, cookies: cookies, timing: timing, network: SteadyNetworkPath())
    }

    /// Any transports, with sockets that hear from `network` whether there's a network to try.
    public init(origin: URL, transport: any HTTPTransport, connector: any SocketConnector, cookies: HTTPCookieStorage = .shared, timing: EmberTiming = .standard, network: any NetworkPathSource) {
        self.origin = ServerAddress.normalizedOrigin(origin)
        self.transport = transport
        self.connector = connector
        self.cookies = cookies
        self.timing = timing
        self.network = network
    }

    // MARK: Addresses

    /// A server path such as an `avatarUrl` (`/users/…/avatar?v=3`) as a URL on this server.
    /// An absolute URL passes through.
    public func url(_ path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return URL(string: path, relativeTo: origin)?.absoluteURL
    }

    /// The origin as the `Origin` header writes it: scheme, host and port, nothing else.
    public var originHeader: String {
        var text = origin.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: The escape hatches

    /// GET bytes from a server path, cookies sent. For avatars, previews, attachments.
    public func data(at path: String) async throws -> Data {
        let (data, _) = try await perform(try request("GET", path))
        return data
    }

    /// GET any endpoint the SDK hasn't wrapped yet, decoding its answer as Ember writes JSON.
    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let (data, response) = try await perform(try request("GET", path))
        return try decode(T.self, from: data, status: response.statusCode)
    }

    /// Sends `body` as JSON to any endpoint the SDK hasn't wrapped yet, with the headers Ember's
    /// cross-site check asks of a write, decoding its answer.
    public func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body, as type: T.Type = T.self) async throws -> T {
        let (data, response) = try await perform(try request(method, path, body: body))
        return try decode(T.self, from: data, status: response.statusCode)
    }

    /// Sends a request with no body to any endpoint, ignoring what it answers unless it refuses.
    public func send(_ method: String, _ path: String) async throws {
        _ = try await perform(try request(method, path))
    }

    /// Sends `body` as JSON to any endpoint, ignoring what it answers unless it refuses.
    public func send<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        _ = try await perform(try request(method, path, body: body))
    }

    // MARK: Signing in

    /// `GET /api/bootstrap`: what the app needs before anyone signs in, and who's signed in already.
    public func bootstrap() async throws -> Bootstrap {
        try await get("/api/bootstrap")
    }

    /// `bootstrap()`, also answering the origin it was finally answered from: a server that redirects
    /// (`http` to `https`, or `chat.example.com` to `ember.example.com`) is reached there, so that's
    /// the origin to keep and make a client for. A redirect from `https` to `http` isn't followed
    /// down: `origin` stays this client's.
    public func checkServer() async throws -> ServerCheck {
        let (data, response) = try await perform(try request("GET", "/api/bootstrap"))
        let bootstrap = try decode(Bootstrap.self, from: data, status: response.statusCode)
        var reached = response.url.map(ServerAddress.normalizedOrigin) ?? origin
        if origin.scheme == "https" && reached.scheme != "https" { reached = origin }
        return ServerCheck(bootstrap: bootstrap, origin: reached)
    }

    /// `GET /api/me`: who's signed in. 401 when nobody is.
    public func me() async throws -> Me {
        try await get("/api/me", as: SignedIn.self).user
    }

    /// `POST /api/session` with an email address and password. 401 for a wrong one; a person who
    /// signs in with Memberful fails with a 202 or 403 `EmberError` saying so.
    public func signIn(emailAddress: String, password: String) async throws -> Me {
        try await startSession(PasswordBody(emailAddress: emailAddress, password: password))
    }

    /// `POST /api/session` with just a name, where `Bootstrap.guestSignIn` allows (403 otherwise).
    public func signIn(name: String) async throws -> Me {
        try await startSession(GuestBody(name: name))
    }

    /// `DELETE /api/session`, then forgets this server's cookies whatever it answered.
    /// `signOutReason` becomes `.asked`, unless the session had ended already.
    public func signOut() async {
        lastSignOut.withLock { $0 = $0 ?? .asked }
        _ = try? await perform(try request("DELETE", "/api/session"))
        forgetCookies()
    }

    /// Why someone was last signed out on this client: they asked (`signOut()`), or the server
    /// ended the session (a 401). nil since signing in, or when nobody's been signed out.
    public var signOutReason: SignOutReason? {
        lastSignOut.withLock { $0 }
    }

    /// A socket found the session gone (closed as revoked, or its upgrade refused 401) and the app is
    /// about to hear it: `signOutReason` becomes `.sessionEnded`, unless someone asked to sign out.
    func sessionEnded() {
        lastSignOut.withLock { $0 = $0 ?? .sessionEnded }
    }

    /// Whether a session cookie for this server is kept: someone may still be signed in.
    public var hasSessionCookie: Bool {
        (cookies.cookies(for: origin) ?? []).contains { Self.sessionCookieNames.contains($0.name) }
    }

    /// Forgets every cookie this server set.
    public func forgetCookies() {
        for cookie in cookies.cookies(for: origin) ?? [] { cookies.deleteCookie(cookie) }
    }

    // MARK: The sidebar

    /// `GET /api/sidebar`: the rooms you're in, your stars, and the shared order.
    public func sidebar() async throws -> Sidebar {
        try await get("/api/sidebar")
    }

    /// `GET /api/users`: everyone in the workspace.
    public func directory() async throws -> Directory {
        try await get("/api/users")
    }

    /// `PUT /api/rooms/:id/favorite`: stars or unstars a room, answering your stars now.
    public func setFavorite(_ favorite: Bool, roomID: RoomID) async throws -> Favorites {
        struct Body: Encodable { var favorite: Bool }
        struct Answer: Decodable { var favorites: Favorites }
        return try await send("PUT", "/api/rooms/\(Self.segment(roomID))/favorite", body: Body(favorite: favorite), as: Answer.self).favorites
    }

    /// `PUT /api/rooms/:id/involvement`: how much of a room reaches you, answering the level kept.
    public func setInvolvement(_ involvement: Involvement, roomID: RoomID) async throws -> Involvement {
        struct Body: Encodable { var involvement: Involvement }
        struct Answer: Decodable { var involvement: Involvement }
        return try await send("PUT", "/api/rooms/\(Self.segment(roomID))/involvement", body: Body(involvement: involvement), as: Answer.self).involvement
    }

    /// `POST /api/directs`: the DM with exactly these people and you, new or the one you had.
    public func startDirect(with userIDs: [UserID]) async throws -> Room {
        try await send("POST", "/api/directs", body: NewDirect(userIds: userIDs), as: StartedDirect.self).room
    }

    // MARK: Search

    /// `record: true` is a search someone typed (POST /api/searches, which remembers it); false reads
    /// results or a further page (GET /api/searches). A query with nothing to search for reads just
    /// your recent searches.
    public func search(_ query: SearchQuery, sort: SearchSort = .newest, cursor: Int? = nil, record: Bool = false) async throws -> SearchResults {
        if record && cursor == nil {
            return try await send("POST", "/api/searches", body: query.body(sort: sort))
        }
        // With nothing to search for, the server answers just the recent searches, as the web reads them.
        guard query.isSearchable else { return try await get("/api/searches") }
        return try await get("/api/searches?\(query.queryString(sort: sort, cursor: cursor))")
    }

    /// `DELETE /api/searches`: forgets your recent searches.
    public func clearRecentSearches() async throws {
        try await send("DELETE", "/api/searches")
    }

    // MARK: Sockets

    /// The workspace socket's request: wss (or ws) to `/api/socket`, `Origin` set to the server's
    /// origin, and the session cookie attached.
    public func workspaceSocketRequest() -> URLRequest {
        socketRequest("/api/socket")
    }

    /// A room socket's request, as `RoomSocket.query` names what it asks for.
    public func roomSocketRequest(roomID: RoomID, visible: Bool, since: Int?, around: String?) -> URLRequest {
        socketRequest("/api/rooms/\(Self.segment(roomID))/socket?\(RoomSocket.query(visible: visible, since: since, around: around))")
    }

    /// The workspace socket, keeping itself connected on this client's connector and network.
    @MainActor public func workspaceSocket() -> ReconnectingSocket {
        ReconnectingSocket(connector: connector, timing: timing, network: network) { [self] in workspaceSocketRequest() }
    }

    /// A room's socket, keeping itself connected; `request` is asked again for each attempt.
    @MainActor public func roomSocket(request: @escaping @MainActor () -> URLRequest) -> ReconnectingSocket {
        ReconnectingSocket(connector: connector, timing: timing, network: network, request: request)
    }

    // MARK: Signed out

    /// Calls `handler` whenever a request on this client is answered 401 (signing in excepted) for the
    /// session it's signed in with now (an answer about a session replaced while it was on its way
    /// doesn't count), until
    /// the returned token is passed to `removeSignedOutHandler`. `Workspace` uses it so that any
    /// request, the app's own included, sends someone back to signing in.
    @discardableResult
    public func addSignedOutHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        signedOutHandlers.add(handler)
    }

    /// Stops calling a handler `addSignedOutHandler` added.
    public func removeSignedOutHandler(_ token: UUID) {
        signedOutHandlers.remove(token)
    }

    // MARK: Requests

    /// The names Ember gives its session cookie: `__Host-` over HTTPS, plain over HTTP.
    static let sessionCookieNames: Set<String> = ["__Host-session_token", "session_token"]

    /// A request to `path` on this server. A write carries `Origin` and `Sec-Fetch-Site:
    /// same-origin`, without which Ember refuses it (422) as a cross-site request. An absolute URL
    /// elsewhere carries neither, since it isn't this server's request.
    public func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = url(path) else { throw EmberError(status: 0, message: "That isn’t an address on this server.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" && method != "HEAD" && isOwn(url) {
            request.setValue(originHeader, forHTTPHeaderField: "Origin")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        return request
    }

    /// A request to `path` with `body` as JSON.
    public func request<Body: Encodable>(_ method: String, _ path: String, body: Body) throws -> URLRequest {
        var request = try request(method, path)
        do {
            request.httpBody = try EmberJSON.encoder().encode(body)
        } catch {
            throw EmberError(status: 0, message: "The request couldn’t be written.")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Sends `request` with this server's cookies, keeps any it sets, and answers a 2xx; anything else
    /// throws the server's `EmberError`.
    ///
    /// Only a request to `origin` itself (scheme, host and port) is this server's: one anywhere else,
    /// such as an attachment's absolute URL, goes without cookies, `Origin` or `Sec-Fetch-Site`, keeps
    /// nothing it's sent, and its 401 doesn't sign anyone out.
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try answered(request, await exchange(request) { try await self.transport.send($0) })
    }

    /// `perform` for a request whose body goes up through the transport's `upload`, so `progress`
    /// hears it go.
    func perform(_ request: URLRequest, uploading body: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        try answered(request, await exchange(request) { try await self.transport.upload($0, body: body, progress: progress) })
    }

    /// A 2xx answer as it is; anything else as the server's `EmberError`.
    private func answered(_ request: URLRequest, _ answer: Exchanged) throws -> (Data, HTTPURLResponse) {
        let (data, response) = (answer.data, answer.response)
        guard (200..<300).contains(response.statusCode) else {
            throw refusal(response.statusCode, data: data, request: request, response: response, sessionWasCurrent: answer.sessionWasCurrent)
        }
        if request.url?.path == "/api/session", request.httpMethod == "POST" { lastSignOut.withLock { $0 = nil } }
        return (data, response)
    }

    /// An answer, and whether the session cookie it went with is still the one kept.
    private struct Exchanged {
        var data: Data
        var response: HTTPURLResponse
        var sessionWasCurrent: Bool
    }

    /// Whether `url` is on this server: the same scheme, host and port as `origin`.
    func isOwn(_ url: URL) -> Bool {
        Self.sameOrigin(url, origin)
    }

    /// Whether two URLs have the same origin, as `ServerAddress.normalizedOrigin(_:)` writes them.
    static func sameOrigin(_ one: URL, _ other: URL) -> Bool {
        guard one.scheme != nil, one.host != nil else { return false }
        return ServerAddress.normalizedOrigin(one) == ServerAddress.normalizedOrigin(other)
    }

    /// Whether the answer came from this server: the request was to it, and wasn't redirected away.
    private func isOwn(_ request: URLRequest, _ response: HTTPURLResponse) -> Bool {
        guard let url = request.url, isOwn(url) else { return false }
        return response.url.map(isOwn) ?? true
    }

    /// Sends `request` with cookies attached and keeps those the answer sets, whatever its status.
    private func exchange(_ request: URLRequest, through send: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> Exchanged {
        var request = request
        let sentSession = sessionToken()
        if let url = request.url, isOwn(url) {
            if let sent = cookies.cookies(for: url), !sent.isEmpty {
                for (name, value) in HTTPCookie.requestHeaderFields(with: sent) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
        } else {
            // Headers that would pass this server's cross-site check have no business elsewhere.
            request.setValue(nil, forHTTPHeaderField: "Origin")
            request.setValue(nil, forHTTPHeaderField: "Sec-Fetch-Site")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as EmberError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw EmberError.unreachable(origin)
        }
        let sessionWasCurrent = sessionToken() == sentSession
        if isOwn(request, response), let url = response.url ?? request.url {
            keepCookies(from: response, for: url)
        }
        return Exchanged(data: data, response: response, sessionWasCurrent: sessionWasCurrent)
    }

    /// The session cookie kept for this server now, if any.
    private func sessionToken() -> String? {
        (cookies.cookies(for: origin) ?? []).first { Self.sessionCookieNames.contains($0.name) }?.value
    }

    /// Keeps the cookies `response` sets for `url`'s host, and none it names another domain for.
    private func keepCookies(from response: HTTPURLResponse, for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { fields[name] = value }
        }
        let set = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { Self.domain($0.domain, matches: host) }
        if !set.isEmpty { cookies.setCookies(set, for: url, mainDocumentURL: nil) }
    }

    /// Whether a cookie's `domain` covers `host`, as RFC 6265 matches them: the host itself, or a
    /// domain the host is under (never for an IP address).
    static func domain(_ domain: String, matches host: String) -> Bool {
        var domain = domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        if domain == host { return true }
        let isAddress = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        return !isAddress && host.hasSuffix("." + domain)
    }

    private func refusal(_ status: Int, data: Data, request: URLRequest, response: HTTPURLResponse, sessionWasCurrent: Bool) -> EmberError {
        let error = EmberError.refusal(status: status, data: data)
        if status == 401, sessionWasCurrent, isOwn(request, response), request.url?.path != "/api/session" {
            lastSignOut.withLock { $0 = .sessionEnded }
            signedOutHandlers.call()
        }
        return error
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        do {
            return try EmberJSON.decoder().decode(T.self, from: data)
        } catch {
            throw EmberError.unreadable(status: status)
        }
    }

    private func startSession<Body: Encodable>(_ body: Body) async throws -> Me {
        let (data, response) = try await perform(try request("POST", "/api/session", body: body))
        if response.statusCode == 202 {
            // A member who signs in with Memberful: their password checked out, but the server sends
            // them to connect their Memberful account (`{ memberfulConnection }`), which only a browser can.
            throw EmberError(status: 202, message: "This account signs in with Memberful. Sign in on the web to connect it first.")
        }
        return try decode(SignedIn.self, from: data, status: response.statusCode).user
    }

    private func socketRequest(_ path: String) -> URLRequest {
        let http = url(path) ?? origin
        var components = URLComponents(url: http, resolvingAgainstBaseURL: false)
        components?.scheme = http.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components?.url ?? http)
        request.setValue(originHeader, forHTTPHeaderField: "Origin")
        // URLSession doesn't reliably attach cookies to a ws(s) request, so they're named here, as the
        // http(s) address would send them.
        if let sent = cookies.cookies(for: http), !sent.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: sent) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    /// `id` as one segment of a path, so nothing in it can reach another route.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}

/// Why someone was signed out.
public enum SignOutReason: Equatable, Sendable {
    /// They signed out: `EmberClient.signOut()`.
    case asked
    /// The server no longer knows their session: a request was answered 401, or a socket closed as
    /// revoked or had its upgrade refused 401.
    case sessionEnded
}

/// What `EmberClient.checkServer()` found.
public struct ServerCheck: Sendable {
    /// What the server answered.
    public var bootstrap: Bootstrap
    /// The origin that answered, after any redirects: the one to keep.
    public var origin: URL

    /// A server's answer, and where it came from.
    public init(bootstrap: Bootstrap, origin: URL) {
        self.bootstrap = bootstrap
        self.origin = origin
    }
}

private struct PasswordBody: Encodable {
    var emailAddress: String
    var password: String
}

private struct GuestBody: Encodable {
    var name: String
}

private final class SignedOutHandlers: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func add(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.withLock { handlers[token] = handler }
        return token
    }

    func remove(_ token: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: token) }
    }

    func call() {
        for handler in lock.withLock({ Array(handlers.values) }) { handler() }
    }
}
