import Foundation
import EmberSDK

extension EmberClient {
    /// A client on stand-in transports, with cookies of its own, so nothing touches the network or
    /// the app's real session. Pass `timing` on a `ManualClock` to control every wait.
    public static func mock(
        origin: URL = URL(string: "https://ember.test")!,
        transport: MockHTTPTransport = MockHTTPTransport(),
        connector: MockSocketConnector = MockSocketConnector(),
        cookies: HTTPCookieStorage = EphemeralCookieStorage(),
        timing: EmberTiming = EmberTiming()
    ) -> EmberClient {
        EmberClient(origin: origin, transport: transport, connector: connector, cookies: cookies, timing: timing)
    }
}

extension MockHTTPTransport {
    /// Stubs the endpoints a signed-in workspace loads: me, bootstrap, the sidebar and the directory,
    /// with `Fixtures` unless given others.
    public func stubSignedIn(
        me: Me = Fixtures.me,
        sidebar: String = Fixtures.sidebarJSON(),
        directory: String = Fixtures.directoryJSON()
    ) {
        stub("GET", "/api/me", json: Fixtures.meJSON(me))
        stub("GET", "/api/bootstrap", json: Fixtures.bootstrapJSON(user: me))
        stub("GET", "/api/sidebar", json: sidebar)
        stub("GET", "/api/users", json: directory)
    }
}

extension MockSocketConnector {
    /// Answers each workspace socket with a welcome and each room socket with a room welcome of
    /// `messages`, as soon as it's asked for.
    public func welcomeEverySocket(me: Me = Fixtures.me, messages: [Message] = Fixtures.messages(3), seq: Int = 10) {
        onConnect { connection in
            let path = connection.request.url?.path ?? ""
            if path == "/api/socket" {
                connection.serverSends(Fixtures.WorkspaceFrames.welcome(you: me))
            } else if path.hasSuffix("/socket") {
                connection.serverSends(Fixtures.RoomFrames.welcome(you: me.user, messages: messages, seq: seq))
            }
        }
    }
}

extension Workspace {
    /// A workspace signed in as `Fixtures.me` on a mock client, its sidebar and directory stubbed
    /// and every socket welcomed. Call `start()` to load it, as an app would. For previews and tests.
    public static func mock(
        transport: MockHTTPTransport = MockHTTPTransport(),
        connector: MockSocketConnector = MockSocketConnector(),
        timing: EmberTiming = EmberTiming()
    ) -> Workspace {
        transport.stubSignedIn()
        connector.welcomeEverySocket()
        let client = EmberClient.mock(transport: transport, connector: connector, timing: timing)
        return Workspace(client: client, me: Fixtures.me, account: Fixtures.account)
    }
}

extension RoomSession {
    /// A session in General on a mock client whose socket welcomes it with `messages`. Call `start()`
    /// to open it, as an app would. For previews and tests.
    public static func mock(
        roomID: RoomID = Fixtures.general.id,
        messages: [Message] = Fixtures.messages(3),
        connector: MockSocketConnector = MockSocketConnector(),
        timing: EmberTiming = EmberTiming()
    ) -> RoomSession {
        connector.welcomeEverySocket(messages: messages)
        let client = EmberClient.mock(connector: connector, timing: timing)
        return RoomSession(client: client, roomID: roomID)
    }
}
