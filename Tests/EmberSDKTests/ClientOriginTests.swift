import EmberTesting
import Foundation
import Testing

/// The origin a client sends and compares, why it signs out, and where a server check lands.
@Suite struct ClientOriginTests {
    // MARK: The origin

    @Test(arguments: [
        "https://Chat.Example.com",
        "HTTPS://chat.example.com",
        "https://chat.example.com:443",
        "https://chat.example.com/",
        "https://chat.example.com/ember/?a=1#top",
    ])
    func theOriginIsWrittenAsABrowserWritesIt(typed: String) async throws {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(origin: URL(string: typed)!, transport: transport)
        #expect(client.origin.absoluteString == "https://chat.example.com")
        #expect(client.originHeader == "https://chat.example.com")
        #expect(client.workspaceSocketRequest().value(forHTTPHeaderField: "Origin") == "https://chat.example.com")
        #expect(client.workspaceSocketRequest().url?.absoluteString == "wss://chat.example.com/api/socket")

        transport.stub("PUT", "/api/rooms/r1/favorite", json: #"{"favorites":{"rooms":[],"version":1}}"#)
        _ = try await client.setFavorite(true, roomID: "r1")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Origin") == "https://chat.example.com")
    }

    @Test func aPortThatIsntTheSchemesOwnIsKept() {
        let client = EmberClient.mock(origin: URL(string: "http://LOCALHOST:8787/")!)
        #expect(client.originHeader == "http://localhost:8787")
        #expect(client.workspaceSocketRequest().url?.absoluteString == "ws://localhost:8787/api/socket")
    }

    @Test func anAddressWrittenDifferentlyIsStillThisServers() async throws {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(origin: URL(string: "https://chat.example.com")!, transport: transport)
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        transport.stub("GET", "/file", json: "{}")
        _ = try await client.data(at: "https://CHAT.example.com:443/file")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Cookie") == "session_token=test-session")
    }

    // MARK: Signing out

    @Test func a401SignsOutAndSaysTheSessionEnded() async {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(transport: transport)
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        #expect(client.signOutReason == nil)
        _ = try? await client.sidebar()
        #expect(signedOut.value == 1)
        #expect(client.signOutReason == .sessionEnded)
    }

    @Test func signingOutSaysItWasUserInitiated() async throws {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(transport: transport)
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        await client.signOut()
        #expect(client.signOutReason == .userInitiated)

        // Signing in again forgets it.
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        #expect(client.signOutReason == nil)
    }

    @Test func signingOutAfterTheSessionEndedStillSaysItEnded() async {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(transport: transport)
        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        _ = try? await client.sidebar()
        await client.signOut()
        #expect(client.signOutReason == .sessionEnded)
    }

    @Test func a401ForASessionSinceReplacedDoesntSignOut() async throws {
        let transport = MockHTTPTransport()
        let client = EmberClient.mock(transport: transport)
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")

        // A request goes with the first session, and is answered only after signing in again.
        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        let gate = transport.hold("GET", "/api/sidebar")
        let stale = Task { try? await client.sidebar() }
        await gate.waitForRequest()
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: ["Set-Cookie": "session_token=second-session; Path=/; HttpOnly"])
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        gate.release()
        _ = await stale.value

        #expect(signedOut.value == 0)
        #expect(client.signOutReason == nil)
        #expect(client.hasSessionCookie)
    }

    // MARK: Checking a server

    @Test func checkingAServerAnswersWhereItWasRedirected() async throws {
        let client = redirected(from: "http://chat.example.com", to: "https://Ember.Example.com/api/bootstrap")
        let check = try await client.checkServer()
        #expect(check.origin.absoluteString == "https://ember.example.com")
        #expect(check.bootstrap.user == Fixtures.me)
    }

    @Test func checkingAServerThatIsntRedirectedAnswersItsOwnOrigin() async throws {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/bootstrap", json: Fixtures.bootstrapJSON())
        let client = EmberClient.mock(origin: URL(string: "https://chat.example.com")!, transport: transport)
        #expect(try await client.checkServer().origin.absoluteString == "https://chat.example.com")
    }

    @Test func aRedirectDownToHTTPIsntAdopted() async throws {
        let client = redirected(from: "https://chat.example.com", to: "http://chat.example.com/api/bootstrap")
        #expect(try await client.checkServer().origin.absoluteString == "https://chat.example.com")
    }
}

/// A client for `origin` whose every request is answered from `to`.
private func redirected(from origin: String, to: String) -> EmberClient {
    EmberClient(origin: URL(string: origin)!, environment: .mock(transport: Redirecting(to: to)))
}

/// A server whose `/api/bootstrap` is answered from `to`, as URLSession reports a redirect it followed.
private struct Redirecting: HTTPTransport {
    let to: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: URL(string: to)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(Fixtures.bootstrapJSON().utf8), response)
    }
}
