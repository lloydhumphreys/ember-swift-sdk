import Foundation

/// What a client runs on: where its requests and sockets go, where it keeps cookies and unsent
/// messages, and what it asks of the system while a file goes up.
///
/// Start from `.system()` and change what you need, so the rest stays real:
///
/// ```swift
/// var environment = EmberEnvironment.system()
/// environment.transport = MyTransport()
/// let client = EmberClient(origin: origin, environment: environment)
/// ```
public struct EmberEnvironment: Sendable {
    /// Where HTTP requests go.
    public var transport: any HTTPTransport
    /// Where sockets open.
    public var connector: any SocketConnector
    /// Where the session cookie is kept.
    public var cookies: HTTPCookieStorage
    /// The intervals the client's sockets and stores wait on.
    public var timing: EmberTiming
    /// Where the client's sockets hear whether there's a network.
    public var network: any NetworkPathSource
    /// Where the client's room sessions keep unsent messages across launches.
    public var unsentStore: any UnsentMessageStore
    /// What keeps a file going up when the app leaves the foreground.
    public var backgroundTime: BackgroundTime

    public init(
        transport: any HTTPTransport,
        connector: any SocketConnector,
        cookies: HTTPCookieStorage,
        timing: EmberTiming,
        network: any NetworkPathSource,
        unsentStore: any UnsentMessageStore,
        backgroundTime: BackgroundTime
    ) {
        self.transport = transport
        self.connector = connector
        self.cookies = cookies
        self.timing = timing
        self.network = network
        self.unsentStore = unsentStore
        self.backgroundTime = backgroundTime
    }

    /// The real thing: one URLSession for HTTP and sockets, `SystemNetworkPath.shared`, unsent
    /// messages in `FileUnsentMessageStore.shared`, and `BackgroundTime.system`. Cookies are kept in
    /// `cookies`.
    public static func system(cookies: HTTPCookieStorage = .shared) -> EmberEnvironment {
        let session = URLSessionHTTPTransport.makeSession()
        return EmberEnvironment(
            transport: URLSessionHTTPTransport(session: session),
            connector: URLSessionSocketConnector(session: session),
            cookies: cookies,
            timing: .standard,
            network: SystemNetworkPath.shared,
            unsentStore: FileUnsentMessageStore.shared,
            backgroundTime: .system
        )
    }
}
