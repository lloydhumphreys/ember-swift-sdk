import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Every endpoint: what goes out, what comes back, and how refusals read.
@Suite struct ClientTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    /// The headers Ember's cross-site check asks of every write.
    func expectWriteHeaders(_ request: URLRequest?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(request?.value(forHTTPHeaderField: "Origin") == "https://ember.test", sourceLocation: sourceLocation)
        #expect(request?.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin", sourceLocation: sourceLocation)
    }

    // MARK: Signing in

    @Test func bootstrapReadsWhoIsSignedIn() async throws {
        transport.stub("GET", "/api/bootstrap", json: Fixtures.bootstrapJSON())
        let bootstrap = try await client.bootstrap()
        #expect(bootstrap.user == Fixtures.me)
        #expect(bootstrap.guestSignIn == false)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://ember.test/api/bootstrap")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil)
    }

    @Test func meReadsTheUser() async throws {
        transport.stub("GET", "/api/me", json: Fixtures.meJSON())
        #expect(try await client.me() == Fixtures.me)
    }

    @Test func signingInPostsTheAddressAndPassword() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON())
        let me = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        #expect(me == Fixtures.me)
        let request = transport.requests("POST", "/api/session").last
        expectWriteHeaders(request)
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = transport.lastBody("POST", "/api/session")
        #expect(body?["emailAddress"] as? String == "ada@example.com")
        #expect(body?["password"] as? String == "not-a-real-password")
    }

    @Test func aWrongPasswordIsRefusedWithoutSigningOut() async {
        transport.stub("POST", "/api/session", status: 401, json: Fixtures.errorJSON("That email address or password isn’t right."))
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        let error = await #expect(throws: EmberError.self) {
            try await client.signIn(emailAddress: "ada@example.com", password: "wrong")
        }
        #expect(error?.status == 401)
        #expect(error?.isSignedOut == true)
        #expect(error?.message == "That email address or password isn’t right.")
        #expect(signedOut.value == 0)
    }

    @Test func aMemberfulAccountIsSentToTheWeb() async {
        transport.stub("POST", "/api/session", status: 202, json: #"{"memberfulConnection":{"url":"https://example.com"}}"#)
        let error = await #expect(throws: EmberError.self) {
            try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        }
        #expect(error?.status == 202)
    }

    @Test func aGuestSignsInWithAName() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON())
        _ = try await client.signIn(name: "Ada")
        #expect(transport.lastBody("POST", "/api/session")?["name"] as? String == "Ada")
        #expect(transport.lastBody("POST", "/api/session")?["password"] == nil)
    }

    // MARK: Cookies

    @Test func theSessionCookieIsKeptAndSent() async throws {
        #expect(!client.hasSessionCookie)
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        transport.stub("GET", "/api/me", json: Fixtures.meJSON())
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        #expect(client.hasSessionCookie)
        _ = try await client.me()
        let cookie = transport.requests("GET", "/api/me").last?.value(forHTTPHeaderField: "Cookie")
        #expect(cookie == "session_token=test-session")
        // Kept apart from the app's own cookies, and from another client's.
        #expect(HTTPCookieStorage.shared.cookies(for: client.origin)?.contains { $0.value == "test-session" } != true)
        #expect(!EmberClient.mock().hasSessionCookie)
    }

    @Test func signingOutForgetsTheCookies() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        transport.stub("DELETE", "/api/session", status: 204, json: "")
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        await client.signOut()
        #expect(!client.hasSessionCookie)
        let request = transport.requests("DELETE", "/api/session").last
        expectWriteHeaders(request)
        #expect(request?.value(forHTTPHeaderField: "Cookie") == "session_token=test-session")
    }

    @Test func signingOutForgetsTheCookiesEvenUnanswered() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        transport.failEverything()
        await client.signOut()
        #expect(!client.hasSessionCookie)
    }

    @Test func anExpiredCookieIsForgotten() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        transport.stub("GET", "/api/me", status: 401, json: Fixtures.errorJSON("Sign in."), headers: Fixtures.expiredCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        _ = try? await client.me()
        #expect(!client.hasSessionCookie)
    }

    // MARK: Other origins

    /// Signs in, so there's a session cookie to keep to this server.
    func signedIn() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        try #require(client.hasSessionCookie)
    }

    @Test(arguments: ["https://elsewhere.test/hook", "https://ember.test:8443/hook", "http://ember.test/hook", "https://ember.test.elsewhere.test/hook"])
    func aRequestElsewhereGoesWithoutTheSessionOrTheWriteHeaders(address: String) async throws {
        try await signedIn()
        transport.stub("POST", "/hook", json: "{}")
        try await client.send("POST", address)
        let request = try #require(transport.requests("POST", "/hook").last)
        #expect(request.url?.absoluteString == address)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil)
    }

    @Test func aRequestBuiltForElsewhereLosesTheWriteHeaders() async throws {
        var request = URLRequest(url: URL(string: "https://elsewhere.test/hook")!)
        request.httpMethod = "POST"
        request.setValue("https://ember.test", forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        transport.stub("POST", "/hook", json: "{}")
        _ = try await client.perform(request)
        let sent = try #require(transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Origin") == nil)
        #expect(sent.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil)
    }

    @Test func thisServerSpelledOutIsStillThisServer() async throws {
        try await signedIn()
        transport.stub("POST", "/api/hook", json: "{}")
        try await client.send("POST", "HTTPS://Ember.test:443/api/hook")
        let request = try #require(transport.requests("POST", "/api/hook").last)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session_token=test-session")
        expectWriteHeaders(request)
    }

    @Test func a401ElsewhereDoesntSignOut() async throws {
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        transport.stub("GET", "/file", status: 401, json: Fixtures.errorJSON("Sign in."))
        await #expect(throws: EmberError.self) { try await client.data(at: "https://elsewhere.test/file") }
        #expect(signedOut.value == 0)

        await #expect(throws: EmberError.self) { try await client.data(at: "/file") }
        #expect(signedOut.value == 1)
    }

    @Test func aCookieSetElsewhereIsntKept() async throws {
        transport.stub("GET", "/file", json: "{}", headers: Fixtures.sessionCookieHeaders)
        _ = try await client.data(at: "https://elsewhere.test/file")
        #expect(!client.hasSessionCookie)
        #expect(client.cookies.cookies?.isEmpty != false)
    }

    @Test func aCookieThisServerSetsForAnotherDomainIsntKept() async throws {
        transport.stub("GET", "/api/me", json: Fixtures.meJSON(), headers: ["Set-Cookie": "tracker=1; Path=/; Domain=elsewhere.test"])
        _ = try await client.me()
        #expect(client.cookies.cookies?.isEmpty != false)

        transport.stub("GET", "/api/me", json: Fixtures.meJSON(), headers: ["Set-Cookie": "theme=dark; Path=/; Domain=ember.test"])
        _ = try await client.me()
        #expect(client.cookies.cookies?.map(\.name) == ["theme"])
    }

    @Test func cookieDomainsMatchAsTheRFCSays() {
        #expect(EmberClient.domain("ember.test", matches: "ember.test"))
        #expect(EmberClient.domain(".ember.test", matches: "chat.ember.test"))
        #expect(!EmberClient.domain("ember.test", matches: "notember.test"))
        #expect(!EmberClient.domain("chat.ember.test", matches: "ember.test"))
        #expect(!EmberClient.domain("0.1", matches: "127.0.0.1"))
        #expect(EmberClient.domain("127.0.0.1", matches: "127.0.0.1"))
        #expect(!EmberClient.domain("", matches: "ember.test"))
    }

    // MARK: The sidebar

    @Test func sidebarAndDirectory() async throws {
        transport.stubSignedIn()
        let sidebar = try await client.sidebar()
        #expect(sidebar.rooms.map(\.id) == Fixtures.sidebarRooms.map(\.id))
        #expect(sidebar.favorites == Fixtures.favorites)
        let directory = try await client.directory()
        #expect(directory.users.map(\.id) == Fixtures.people.map(\.id))
        #expect(transport.requests.compactMap(\.url?.path) == ["/api/sidebar", "/api/users"])
    }

    @Test func starringPutsTheFavourite() async throws {
        let answer = Favorites(rooms: [Fixtures.general.id, Fixtures.engines.id], version: 2)
        transport.stub("PUT", "/api/rooms/room-engines/favorite", json: Fixtures.favoritesJSON(answer))
        #expect(try await client.setFavorite(true, roomID: Fixtures.engines.id) == answer)
        expectWriteHeaders(transport.requests.last)
        #expect(transport.lastBody("PUT", "/api/rooms/room-engines/favorite")?["favorite"] as? Bool == true)
    }

    @Test func involvementPutsTheLevel() async throws {
        transport.stub("PUT", "/api/rooms/room-general/involvement", json: #"{"involvement":"everything"}"#)
        #expect(try await client.setInvolvement(.everything, roomID: Fixtures.general.id) == .everything)
        expectWriteHeaders(transport.requests.last)
        #expect(transport.lastBody("PUT", "/api/rooms/room-general/involvement")?["involvement"] as? String == "everything")
    }

    @Test(arguments: [201, 200]) func startingADirectAnswersTheRoom(status: Int) async throws {
        transport.stub("POST", "/api/directs", status: status, json: Fixtures.roomJSON(Fixtures.directWithGrace))
        let room = try await client.startDirect(with: [Fixtures.grace.id])
        #expect(room.id == Fixtures.directWithGrace.id)
        expectWriteHeaders(transport.requests.last)
        #expect(transport.lastBody("POST", "/api/directs")?["userIds"] as? [String] == [Fixtures.grace.id])
    }

    // MARK: Search

    @Test func aTypedSearchIsPostedAndRemembered() async throws {
        let query = SearchQuery(q: "engine", roomID: Fixtures.general.id)
        transport.stub("POST", "/api/searches", json: Fixtures.searchJSON(search: query, matches: Fixtures.messages(2), next: 2))
        let results = try await client.search(query, sort: .oldest, record: true)
        #expect(results.search == query)
        #expect(results.matches.map(\.id) == ["m001", "m002"])
        #expect(results.next == 2)
        expectWriteHeaders(transport.requests.last)
        let body = transport.lastBody("POST", "/api/searches")
        #expect(body?["q"] as? String == "engine")
        #expect(body?["in"] as? String == Fixtures.general.id)
        #expect(body?["sort"] as? String == "oldest")
    }

    @Test func aFurtherPageIsRead() async throws {
        let query = SearchQuery(q: "analytical engine", roomID: Fixtures.general.id)
        transport.stub("GET", "/api/searches?q=analytical+engine&in=room-general&cursor=40", json: Fixtures.searchJSON(search: query))
        _ = try await client.search(query, cursor: 40, record: true)
        #expect(transport.requests.last?.httpMethod == "GET")
        #expect(transport.requests.last?.query == "q=analytical+engine&in=room-general&cursor=40")
    }

    @Test func anEmptySearchReadsTheRecentOnes() async throws {
        let recent = [SearchQuery(q: "engine"), SearchQuery(q: "", from: Fixtures.grace.id)]
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON(recent: recent))
        let results = try await client.search(SearchQuery(q: ""), record: false)
        #expect(results.search == nil)
        #expect(results.matches.isEmpty)
        #expect(results.recent == recent)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://ember.test/api/searches")
    }

    @Test func recentSearchesAreCleared() async throws {
        transport.stub("DELETE", "/api/searches", status: 204, json: "")
        try await client.clearRecentSearches()
        expectWriteHeaders(transport.requests.last)
    }

    // MARK: The escape hatches

    @Test func anUnwrappedEndpoint() async throws {
        struct Pin: Codable, Equatable { var messageId: String }
        transport.stub("GET", "/api/rooms/room-general/pins", json: #"[{"messageId":"m001"}]"#)
        transport.stub("POST", "/api/rooms/room-general/pins", status: 201, json: #"{"messageId":"m002"}"#)
        #expect(try await client.get("/api/rooms/room-general/pins") == [Pin(messageId: "m001")])
        #expect(try await client.send("POST", "/api/rooms/room-general/pins", body: Pin(messageId: "m002")) == Pin(messageId: "m002"))
        expectWriteHeaders(transport.requests.last)
        #expect(transport.lastBody("POST", "/api/rooms/room-general/pins")?["messageId"] as? String == "m002")
    }

    @Test func pathsBecomeAddresses() {
        #expect(client.url("/users/user_ada/avatar?v=3")?.absoluteString == "https://ember.test/users/user_ada/avatar?v=3")
        #expect(client.url("https://cdn.example.com/a.png")?.absoluteString == "https://cdn.example.com/a.png")
        #expect(EmberClient.mock(origin: URL(string: "https://ember.test/some/path")!).originHeader == "https://ember.test")
    }

    // MARK: Refusals

    @Test func aForbiddenAnswerReadsTheServersMessage() async {
        transport.stub("PUT", "/api/rooms/room-general/favorite", status: 403, json: Fixtures.errorJSON("You can’t star that."))
        let error = await #expect(throws: EmberError.self) {
            try await client.setFavorite(true, roomID: Fixtures.general.id)
        }
        #expect(error == EmberError(status: 403, message: "You can’t star that."))
    }

    @Test func aRefusalNamesItsField() async {
        transport.stub("POST", "/api/directs", status: 422, json: Fixtures.errorJSON("Choose someone.", field: "userIds"))
        let error = await #expect(throws: EmberError.self) {
            try await client.startDirect(with: [])
        }
        #expect(error?.status == 422)
        #expect(error?.field == "userIds")
        #expect(error?.message == "Choose someone.")
    }

    @Test func aRefusalWithoutABodyStillReads() async {
        transport.stub("GET", "/api/sidebar", status: 500, json: "oops")
        let error = await #expect(throws: EmberError.self) { try await client.sidebar() }
        #expect(error?.status == 500)
        #expect(error?.message.isEmpty == false)
    }

    @Test func anUnreachableServerIsStatusZero() async {
        transport.failEverything()
        let error = await #expect(throws: EmberError.self) { try await client.me() }
        #expect(error?.isUnreachable == true)
        #expect(error?.message == "Couldn’t reach ember.test.")
    }

    @Test func anUnreadableAnswer() async {
        transport.stub("GET", "/api/me", json: #"{"nobody":true}"#)
        let error = await #expect(throws: EmberError.self) { try await client.me() }
        #expect(error?.status == 200)
    }

    @Test func any401CallsTheSignedOutHandler() async {
        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        let signedOut = Counter()
        let token = client.addSignedOutHandler { signedOut.add() }
        _ = try? await client.sidebar()
        #expect(signedOut.value == 1)
        client.removeSignedOutHandler(token)
        _ = try? await client.sidebar()
        #expect(signedOut.value == 1)
    }

    // MARK: Socket requests

    @Test func theWorkspaceSocketIsWSSWithOriginAndCookie() async throws {
        transport.stub("POST", "/api/session", json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        _ = try await client.signIn(emailAddress: "ada@example.com", password: "not-a-real-password")
        let request = client.workspaceSocketRequest()
        #expect(request.url?.absoluteString == "wss://ember.test/api/socket")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://ember.test")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session_token=test-session")
    }

    @Test func plainHTTPIsWS() {
        let client = EmberClient.mock(origin: URL(string: "http://127.0.0.1:8791")!)
        let request = client.workspaceSocketRequest()
        #expect(request.url?.absoluteString == "ws://127.0.0.1:8791/api/socket")
        #expect(request.value(forHTTPHeaderField: "Origin") == "http://127.0.0.1:8791")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func aRoomSocketNamesWhatItAsksFor() {
        let caughtUp = client.roomSocketRequest(roomID: Fixtures.general.id, visible: true, since: 12, around: nil)
        #expect(caughtUp.url?.scheme == "wss")
        #expect(caughtUp.url?.path == "/api/rooms/room-general/socket")
        #expect(caughtUp.query == "visible=1&protocol=\(RoomSocket.protocolRevision)&since=12")
        let around = client.roomSocketRequest(roomID: Fixtures.general.id, visible: false, since: nil, around: "m010")
        #expect(around.query == "visible=0&protocol=\(RoomSocket.protocolRevision)&around=m010")
        #expect(around.value(forHTTPHeaderField: "Origin") == "https://ember.test")
    }
}

/// A count that any thread can add to.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
