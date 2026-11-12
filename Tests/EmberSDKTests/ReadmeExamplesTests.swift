import EmberTesting
import Foundation
import Testing
import EmberRichText
@testable import EmberSDK

/// The calls the README's samples make, run on stand-in transports. Each test keeps its sample's lines as they are
/// and changes only what the sample leaves out: where the origin, the ids and the files come from.
@MainActor @Suite struct ReadmeExamplesTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let roomID: RoomID = "room-general"
    let botKey = "bot42-s3cr3tt0k3n"

    @Test func theBotSample() async throws {
        let created = MockHTTPTransport.Answer(status: 201, json: "null", headers: ["Location": "https://chat.example.com/rooms/room-general/@m500"])
        transport.stub("POST", "/rooms/room-general/bot42-s3cr3tt0k3n/messages", answer: { _ in created })
        transport.stub("POST", "/rooms/room-general/bot42-s3cr3tt0k3n/messages/m500/boosts", status: 201, json: """
        {"id":"b1","content":"ship it","message":{"id":"m500","url":"https://chat.example.com/rooms/room-general/@m500"}}
        """)
        let logData = Data("log".utf8)
        let logURL = try TestFile(Array("log".utf8), name: "build.log").url

        // The sample's default transport is the real one; the test hands the bot the mock.
        _ = EmberBot(origin: URL(string: "https://chat.example.com")!, roomID: roomID, key: botKey)
        let bot = EmberBot(origin: URL(string: "https://chat.example.com")!, roomID: roomID, key: botKey, transport: transport)

        let posted = try await bot.post(text: "Deploy finished")     // posted.id, posted.url
        try await bot.post(html: "<p>Deploy <b>finished</b></p>")
        try await bot.post(file: logData, named: "build.log", contentType: "text/plain")
        try await bot.post(fileAt: logURL, contentType: "text/plain")
        let boost = try await bot.boost(posted.id, with: "ship it")  // up to Limits.boost UTF-16 units

        #expect(posted.id == "m500")
        #expect(boost.messageID == "m500")
        #expect(transport.requests("POST", "/rooms/room-general/bot42-s3cr3tt0k3n/messages").count == 4)
        #expect("ship it".utf16.count <= Limits.boost)
    }

    @Test func theOneMessageSample() async throws {
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3), around: "m002")) }
        let client = EmberClient.mock(transport: transport, connector: connector)
        let messageID = "m002"

        let message = try await client.message(messageID, in: roomID)

        #expect(message.id == "m002")
        #expect(connector.latest?.request.query?.contains("around=m002") == true)
        #expect(connector.latest?.request.query?.contains("visible=0") == true)
        #expect(connector.latest?.isClosedByClient == true)
    }

    @Test func theSearchSample() async throws {
        let launch = SearchQuery(q: "launch")
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON(recent: [launch]))
        transport.stub("POST", "/api/searches", status: 201, json: Fixtures.searchJSON(search: launch, matches: Fixtures.messages(2), next: 2, rooms: [Fixtures.general], recent: [launch]))
        transport.stub("GET", "/api/searches?q=launch&cursor=2", json: Fixtures.searchJSON(search: launch, matches: Fixtures.messages(1, from: 3), rooms: [Fixtures.general]))
        let client = EmberClient.mock(transport: transport)

        let search = SearchSession(client: client)
        await search.loadRecent()           // when the screen opens, before anything is typed
        search.query.q = "launch"
        search.run(record: true)            // true when someone typed it: it joins their recent searches
        #expect(await eventually { search.phase == .loaded })
        _ = (search.phase, search.matches, search.rooms, search.recent)
        if search.canLoadMore { search.loadMore() }
        #expect(await eventually { !search.isLoadingMore && search.matches.count == 3 })
        search.clearFilters()               // keeps the words

        #expect(search.recent == [launch])
        #expect(search.query.q == "launch")
    }

    @Test func theAppExtensionSample() async throws {
        // The first two lines are the sample's own. A group nobody entitled gives Foundation's storage for it anyway,
        // so the test only checks that a client is made from it; the calls after go through a mock.
        let origin = URL(string: "https://chat.example.com")!
        let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "group.com.example.chat")
        _ = EmberClient(origin: origin, cookies: cookies)

        transport.stubSignedIn()
        transport.stub("GET", "/api/searches?q=launch", json: Fixtures.searchJSON(search: SearchQuery(q: "launch"), matches: Fixtures.messages(1)))
        let jar = EphemeralCookieStorage()
        jar.setCookie(HTTPCookie(properties: [.name: "session_token", .value: "test-session", .domain: "ember.test", .path: "/"])!)
        let client = EmberClient.mock(transport: transport, cookies: jar)

        guard client.hasSessionCookie else { Issue.record("the session cookie should be found"); return }
        let me = try await client.me()
        let sidebar = try await client.sidebar()
        let results = try await client.search(SearchQuery(q: "launch"))

        #expect(me == Fixtures.me)
        #expect(!sidebar.rooms.isEmpty)
        #expect(results.matches.count == 1)
        #expect(connector.connections.isEmpty)
    }

    @Test func theMoreThanOneAccountSample() throws {
        // The sample's lines, compiled but not run: they'd read and write the machine's real Keychain.
        let sample: (String, URL) -> EmberClient = { accountID, origin in
            let cookies = KeychainCookieStorage(account: accountID)   // any name that stays the same for the account
            let client = EmberClient(origin: origin, cookies: cookies)
            return client
        }
        _ = sample

        // The same, run with the vault the README says tests use.
        let origin = URL(string: "https://chat.example.com")!
        let vault = MemoryCookieVault()
        let cookies = KeychainCookieStorage(vault: vault)
        let client = EmberClient(origin: origin, cookies: cookies)
        cookies.setCookie(HTTPCookie(properties: [.name: "session_token", .value: "test-session", .domain: "chat.example.com", .path: "/"])!)

        #expect(client.cookies === cookies)
        #expect(client.hasSessionCookie)
        #expect(vault.read() != nil)
        cookies.eraseAll()
        #expect(vault.read() == nil)
        #expect(!client.hasSessionCookie)
    }

    @Test func theServerCheckSample() async throws {
        transport.stub("GET", "/api/bootstrap", json: Fixtures.bootstrapJSON(user: nil))
        // The sample's typed address is the real transport's; the test checks through the mock.
        let typed = URL(string: "https://chat.example.com")!
        _ = typed

        let check = try await EmberClient.mock(transport: transport).checkServer()
        let client = EmberClient(origin: check.origin)      // where the server answered, after redirects
        _ = (check.bootstrap.setup, check.bootstrap.account)

        #expect(client.origin == URL(string: "https://ember.test")!)
    }

    @Test func theSignOutReasonSample() async throws {
        transport.stubSignedIn()
        connector.welcomeEverySocket()
        let client = EmberClient.mock(transport: transport, connector: connector)
        let workspace = Workspace(client: client, me: Fixtures.me, account: Fixtures.account)
        var reasons: [SignOutReason?] = []

        workspace.onSignedOut = {
            switch client.signOutReason {
            case .sessionEnded: break     // the server ended the session: a request was answered 401
            case .asked, nil: break       // they signed out
            }
            reasons.append(client.signOutReason)
        }

        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        await workspace.reload()
        #expect(await eventually { reasons == [.sessionEnded] })
    }

    @Test func theNetworkSample() async throws {
        let network = MockNetworkPath()
        transport.stubSignedIn()
        connector.welcomeEverySocket()
        let workspace = Workspace(client: .mock(transport: transport, connector: connector, network: network), me: Fixtures.me, account: Fixtures.account)
        workspace.start()
        #expect(await eventually { workspace.connection == .open })

        network.set(available: false)
        #expect(await eventually { !workspace.isNetworkAvailable })
        network.set(available: true)
        #expect(await eventually { workspace.isNetworkAvailable })
        workspace.stop()
    }

    @Test func thePlainTextSample() throws {
        let room = RoomSession(client: .mock(connector: connector), roomID: roomID)
        let thread = room.thread("m001")

        let id = try room.send(text: "Use <b> for bold")     // shows as typed, "<b>" and all
        try thread.reply(text: "Yes\nand no", alsoSend: true)

        #expect(room.timeline.pending.first { $0.clientMessageId == id }?.body.contains("&lt;b&gt;") == true)
        #expect(thread.timeline.pending.first?.alsoSend == true)
    }

    @Test func theUnsentSample() async throws {
        connector.welcomeEverySocket()
        let client = EmberClient.mock(connector: connector)
        let me = Fixtures.me
        let room = RoomSession(client: client, roomID: roomID, unsentStore: MemoryUnsentMessageStore())
        room.start()
        #expect(await eventually { room.isAdmitted })
        let sent = try room.send(text: "Hello")
        connector.latest?.serverSends(Fixtures.RoomFrames.error("That’s too long.", clientMessageId: sent, failed: "message.create"))
        #expect(await eventually { room.timeline.pending.first?.failure != nil })

        for message in room.timeline.pending where message.failure != nil {
            // show message.failure, with Retry and Discard
            room.retry(message.clientMessageId)               // or room.discard(message.clientMessageId)
        }
        #expect(room.timeline.pending.first?.failure == nil)
        let store = try #require(room.unsentStore as? MemoryUnsentMessageStore)
        #expect(!store.saved.isEmpty)
        // On signing out, forget what this account left unsent on this device, in every room.
        room.unsentStore.removeAll(server: client.origin, userID: me.id)
        #expect(store.saved.isEmpty)
        room.stop()
    }

    @Test func theChangesSample() async throws {
        let mine = Fixtures.message("m009", "Mine", by: Fixtures.ada, minute: 9)
        connector.welcomeEverySocket(messages: [mine])
        let room = RoomSession(client: .mock(connector: connector), roomID: roomID)
        room.start()
        #expect(await eventually { room.isAdmitted })
        let socket = try #require(connector.latest)
        let message = mine
        let newBody = "<p>Changed</p>"
        var thrown: EmberError.Kind?

        let sample = Task {
            do {
                try await room.edit(message: message.id, body: newBody)
                let boost = try await room.boost(message: message.id, content: "🎉")
                try await room.removeBoost(id: boost.id)
                try await room.delete(message: message.id)
            } catch let error as EmberError {
                // error.kind is .refused (error.message is the room's words), .timedOut or .unreachable
                thrown = error.kind
            }
        }
        #expect(await eventually { !socket.sent("message.check").isEmpty })
        guard case let .checkMessages(ids) = socket.sent("message.check").last else { Issue.record("no check"); return }
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: ids))
        #expect(await eventually { !socket.sent("boost.create").isEmpty })
        socket.serverSends(Fixtures.RoomFrames.error("You can’t boost that.", failed: "boost.create"))
        _ = await sample.result
        #expect(thrown == .refused)
        #expect(socket.sent("message.delete").isEmpty)
        room.stop()
    }

    @Test func theEditingSample() async throws {
        let mine = Fixtures.message("m009", "<strong>Ship</strong> it", by: Fixtures.ada, minute: 9)
        connector.welcomeEverySocket(messages: [mine])
        let room = RoomSession(client: .mock(connector: connector), roomID: roomID)
        room.start()
        #expect(await eventually { room.isAdmitted })
        let socket = try #require(connector.latest)
        let message = mine
        let names: [String: String] = [:]
        var draft = ""

        let editable = EditableBody(body: message.body, mentionNames: names)
        draft = editable.text
        #expect(draft == "Ship it")
        draft += " now"
        let sample = Task {
            // on save
            try await room.edit(message: message.id, body: editable.body(editedTo: draft))
        }
        #expect(await eventually { !socket.sent("message.check").isEmpty })
        #expect(socket.sent("message.update") == [.updateMessage(messageId: message.id, body: "<p><strong>Ship</strong> it now</p>")])
        guard case let .checkMessages(ids) = socket.sent("message.check").last else { Issue.record("no check"); return }
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: ids))
        try await sample.value
        room.stop()
    }
}
