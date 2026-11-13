import EmberSDK
import Foundation
import Testing

/// Whether a server to test against was named. Without one, every live test skips.
let liveOrigin = ProcessInfo.processInfo.environment["EMBER_TEST_ORIGIN"].flatMap(URL.init(string:))

/// The account the tests sign in as.
let liveEmail = ProcessInfo.processInfo.environment["EMBER_TEST_EMAIL"] ?? "maya@example.com"

/// The seeded accounts' password: `EMBER_SEED_PASSWORD`, or `.dev/seed-password` at the package's
/// root. It's only ever handed to `signIn`, never printed or compared in an expectation.
func livePassword(filePath: String = #filePath) -> String? {
    if let password = ProcessInfo.processInfo.environment["EMBER_SEED_PASSWORD"], !password.isEmpty { return password }
    let root = URL(filePath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let text = try? String(contentsOf: root.appending(path: ".dev/seed-password"), encoding: .utf8) else { return nil }
    let password = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return password.isEmpty ? nil : password
}

/// Waits on the real clock until `condition` holds.
@MainActor
func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Against a running server: the stand-in in `Tools/mock-server`, or a development Ember. Each test
/// signs in on a client with cookies of its own, so nothing touches the app's session.
@Suite(.enabled(if: liveOrigin != nil), .serialized) struct LiveTests {
    let origin = liveOrigin ?? URL(string: "http://127.0.0.1:8791")!

    func freshClient() -> EmberClient {
        EmberClient(origin: origin, cookies: EphemeralCookieStorage())
    }

    func signedIn() async throws -> EmberClient {
        let password = try #require(livePassword(), "Set EMBER_SEED_PASSWORD or write .dev/seed-password.")
        let client = freshClient()
        _ = try await client.signIn(emailAddress: liveEmail, password: password)
        return client
    }

    /// The room called general, from the sidebar.
    func general(on client: EmberClient) async throws -> Room {
        let sidebar = try await client.sidebar()
        return try #require(sidebar.rooms.first { $0.room.name?.lowercased() == "general" }?.room)
    }

    @Test func bootstrapsSignedOut() async throws {
        let bootstrap = try await freshClient().bootstrap()
        #expect(bootstrap.user == nil)
    }

    @Test func aWrongPasswordIsRefused() async {
        let client = freshClient()
        let error = await #expect(throws: EmberError.self) {
            try await client.signIn(emailAddress: liveEmail, password: "definitely-not-the-password")
        }
        #expect(error?.status == 401)
        #expect(!client.hasSessionCookie)
    }

    @Test func signsInAndSaysWho() async throws {
        let client = try await signedIn()
        #expect(client.hasSessionCookie)
        let me = try await client.me()
        #expect(!me.name.isEmpty)
        #expect(try await client.bootstrap().user?.id == me.id)
    }

    @Test func readsTheSidebarAndDirectory() async throws {
        let client = try await signedIn()
        let sidebar = try await client.sidebar()
        #expect(!sidebar.rooms.isEmpty)
        _ = try await general(on: client)
        let me = try await client.me()
        let directory = try await client.directory()
        #expect(directory.users.contains { $0.id == me.id })
    }

    @Test func searches() async throws {
        let client = try await signedIn()
        let recorded = try await client.search(SearchQuery("the"), history: .record)
        #expect(recorded.search?.q == "the")
        let recent = try await client.search(SearchQuery(), history: .skip)
        #expect(recent.search == nil)
        #expect(recent.matches.isEmpty)
        #expect(recent.recent.contains { $0.q == "the" })
    }

    @Test func starsAndUnstars() async throws {
        let client = try await signedIn()
        let room = try await general(on: client)
        let wasStarred = try await client.sidebar().favorites.rooms.contains(room.id)
        let starred = try await client.setFavorite(true, roomID: room.id)
        #expect(starred.rooms.contains(room.id))
        let unstarred = try await client.setFavorite(false, roomID: room.id)
        #expect(!unstarred.rooms.contains(room.id))
        #expect(unstarred.version > starred.version)
        if wasStarred { _ = try await client.setFavorite(true, roomID: room.id) }
    }

    @MainActor @Test func theWorkspaceSocketWelcomes() async throws {
        let client = try await signedIn()
        let socket = client.workspaceSocket()
        var frames: [WorkspaceFrame] = []
        socket.onText = { frames.append(WorkspaceFrame(text: $0)) }
        socket.start()
        defer { socket.stop() }
        #expect(await eventually {
            frames.contains { if case .welcome = $0 { true } else { false } }
        })
    }

    @MainActor @Test func aRoomWelcomesAndTakesAMessage() async throws {
        let client = try await signedIn()
        let room = try await general(on: client)
        let session = RoomSession(client: client, roomID: room.id)
        session.start()
        defer { session.stop() }
        #expect(await eventually { session.timeline.isLoaded })
        #expect(!session.timeline.messages.isEmpty)

        let text = "From the Swift SDK’s live tests \(UUID().uuidString.prefix(8))"
        let id = session.send(body: "<p>\(text)</p>", plainText: text)
        #expect(await eventually {
            session.timeline.pending.isEmpty
                && session.timeline.messages.contains { $0.clientMessageId == id && $0.plainText == text }
        })
    }

    @MainActor @Test func aWorkspaceLoads() async throws {
        let client = try await signedIn()
        let workspace = Workspace(client: client, me: try await client.me(), account: try await client.bootstrap().account)
        workspace.start()
        defer { workspace.stop() }
        #expect(await eventually { workspace.isLoaded && workspace.connection == .open })
        #expect(!workspace.rooms.isEmpty)
    }

    @Test func signsOut() async throws {
        let client = try await signedIn()
        await client.signOut()
        #expect(!client.hasSessionCookie)
        let error = await #expect(throws: EmberError.self) { try await client.me() }
        #expect(error?.isSignedOut == true)
    }
}
