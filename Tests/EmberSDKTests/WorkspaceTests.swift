import EmberTesting
import Foundation
import Testing

/// The workspace end to end, on mock transports.
@MainActor @Suite struct WorkspaceTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let clock: ManualClock
    let workspace: Workspace

    init() {
        let (timing, clock) = manualTiming()
        self.clock = clock
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    /// Starts the workspace and waits until the loads its start and welcome asked for are done.
    func started() async throws {
        workspace.start()
        try #require(await eventually { workspace.isLoaded && transport.requests("GET", "/api/sidebar").count >= 2 })
        await workspace.reload()
    }

    @Test func loads() async throws {
        #expect(!workspace.isLoaded)
        try await started()
        #expect(workspace.isLoaded)
        #expect(workspace.connection == .open)
        #expect(Set(workspace.rooms.map(\.id)) == Set(Fixtures.sidebarRooms.map(\.id)))
        #expect(workspace.isFavorite(Fixtures.general.id))
        #expect(!workspace.isFavorite(Fixtures.engines.id))
        #expect(workspace.unreadRooms.map(\.id) == [Fixtures.general.id])
        #expect(workspace.directRooms.map(\.id) == [Fixtures.directWithGrace.id])
        #expect(workspace.person(Fixtures.grace.id)?.name == Fixtures.grace.name)
        #expect(workspace.me == Fixtures.me)
        #expect(workspace.account == Fixtures.account)
        #expect(connector.connections.first?.request.url?.path == "/api/socket")
    }

    @Test func aFailedLoadSaysWhy() async {
        transport.stub("GET", "/api/sidebar", status: 500, json: Fixtures.errorJSON("Something went wrong."))
        await workspace.reload()
        #expect(!workspace.isLoaded)
        #expect(workspace.loadError?.message == "Something went wrong.")
    }

    @Test func liveFramesChangeTheSidebar() async throws {
        try await started()
        let socket = try #require(connector.latest)

        socket.serverSends(Fixtures.WorkspaceFrames.roomRead(Fixtures.general.id))
        #expect(await eventually { workspace.unreadCount == 0 })

        socket.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.engines.id))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.unread == true })

        socket.serverSends(Fixtures.WorkspaceFrames.favoritesChanged(Favorites(rooms: [Fixtures.engines.id], version: 5)))
        #expect(await eventually { workspace.isFavorite(Fixtures.engines.id) && !workspace.isFavorite(Fixtures.general.id) })

        let renamed = Room(id: Fixtures.engines.id, kind: .closed, name: "Difference Engines")
        socket.serverSends(Fixtures.WorkspaceFrames.roomSaved(renamed))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.room.name == "Difference Engines" })

        socket.serverSends(Fixtures.WorkspaceFrames.roomGone(Fixtures.engines.id))
        #expect(await eventually { workspace.room(Fixtures.engines.id) == nil })

        let account = Account(name: "Difference Engines", tagline: "Calculating")
        socket.serverSends(Fixtures.WorkspaceFrames.accountUpdated(account))
        #expect(await eventually { workspace.account == account })

        socket.serverSends(#"{"type":"error","message":"Slow down."}"#)
        #expect(await eventually { workspace.notice == "Slow down." })
    }

    @Test func theRoomOnScreenStaysRead() async throws {
        try await started()
        workspace.currentRoomID = Fixtures.general.id
        #expect(workspace.room(Fixtures.general.id)?.unread == false)
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.general.id))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.engines.id))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.unread == true })
        #expect(workspace.room(Fixtures.general.id)?.unread == false)
    }

    @Test func aRenamedPersonIsRenamed() async throws {
        try await started()
        let me = DirectoryUser(id: Fixtures.me.id, name: "Augusta Ada King", role: .administrator, avatarUrl: "/users/user_ada/avatar?v=2")
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(me))
        #expect(await eventually { workspace.me.name == "Augusta Ada King" })
        #expect(workspace.person(Fixtures.me.id)?.avatarUrl == "/users/user_ada/avatar?v=2")
    }

    @Test func starringIsShownAtOnceAndKeptWhenAnswered() async throws {
        try await started()
        let answer = Favorites(rooms: [Fixtures.general.id, Fixtures.engines.id], version: 2)
        transport.stub("PUT", "/api/rooms/room-engines/favorite", json: Fixtures.favoritesJSON(answer))
        await workspace.setFavorite(true, roomID: Fixtures.engines.id)
        #expect(workspace.favorites == answer)
        #expect(workspace.notice == nil)
    }

    @Test func aRefusedStarIsPutBack() async throws {
        try await started()
        let gate = transport.hold("PUT", "/api/rooms/room-engines/favorite")
        transport.stub("PUT", "/api/rooms/room-engines/favorite", status: 403, json: Fixtures.errorJSON("You can’t star that."))
        let starring = Task { await workspace.setFavorite(true, roomID: Fixtures.engines.id) }
        await gate.waitForRequest()
        #expect(workspace.isFavorite(Fixtures.engines.id))
        // A sidebar landing meanwhile, read before the star, doesn't undo it.
        await workspace.reload()
        #expect(workspace.isFavorite(Fixtures.engines.id))
        gate.release()
        await starring.value
        #expect(!workspace.isFavorite(Fixtures.engines.id))
        #expect(workspace.favorites == Fixtures.favorites)
        #expect(workspace.notice == "You can’t star that.")
    }

    @Test func aRefusedInvolvementIsPutBack() async throws {
        try await started()
        transport.stub("PUT", "/api/rooms/room-general/involvement", status: 403, json: Fixtures.errorJSON("Not here."))
        await workspace.setInvolvement(.nothing, roomID: Fixtures.general.id)
        #expect(workspace.room(Fixtures.general.id)?.involvement == .mentions)
        #expect(workspace.notice == "Not here.")
    }

    @Test func aStartedDirectJoinsTheSidebar() async throws {
        try await started()
        let alan = Room(id: "room-dm-alan", kind: .direct, members: [Fixtures.ada, Fixtures.alan])
        transport.stub("POST", "/api/directs", status: 201, json: Fixtures.roomJSON(alan))
        let room = try await workspace.startDirect(with: [Fixtures.alan.id])
        #expect(room.id == alan.id)
        #expect(workspace.room(alan.id) != nil)
    }

    @Test func aMessageSentBeforeTheRoomsFirstWelcomeIsSavedAtOnce() throws {
        let session = workspace.session(for: Fixtures.general.id)
        let store = try #require(session.unsentStore as? MemoryUnsentMessageStore)
        let id = session.send(body: "<p>Early</p>", plainText: "Early")
        #expect(store.saved.values.flatMap { $0 }.map(\.clientMessageId) == [id])
        #expect(store.saved.keys.map(\.userID) == [Fixtures.me.id])
    }

    @Test func aRoomKeepsItsSession() async {
        let session = workspace.session(for: Fixtures.general.id)
        #expect(workspace.session(for: Fixtures.general.id) === session)
        #expect(workspace.session(for: Fixtures.engines.id) !== session)
    }

    @Test func aRevokedSessionSignsOut() async throws {
        try await started()
        var signedOut = 0
        workspace.onSignedOut = { signedOut += 1 }
        let session = workspace.session(for: Fixtures.general.id)
        session.start()
        #expect(await eventually { session.status == .open })

        transport.stub("GET", "/api/me", status: 401, json: Fixtures.errorJSON("Sign in."))
        let socket = try #require(connector.connections.first { $0.request.url?.path == "/api/socket" })
        socket.serverCloses(code: SocketClose.revoked)
        #expect(await eventually { signedOut == 1 })
        #expect(workspace.connection == .idle)
        #expect(await eventually { session.status == .idle })
        await settle()
        #expect(signedOut == 1)
    }

    @Test func anUpgradeRefused401SaysTheSessionEndedBeforeTheAppHears() async throws {
        try await started()
        let client = workspace.client
        var heard: [SignOutReason?] = []
        workspace.onSignedOut = { heard.append(client.signOutReason) }
        transport.stub("GET", "/api/me", status: 401, json: Fixtures.errorJSON("Sign in."))
        connector.autoOpen = false
        connector.onConnect { $0.serverCloses(httpStatus: 401) }
        let socket = try #require(connector.latest)
        socket.serverCloses(code: SocketClose.reconnect)
        #expect(await clock.pass(.milliseconds(250)))
        #expect(await eventually { connector.connections.count == 2 })
        #expect(await eventually { heard == [.sessionEnded] })

        await client.signOut()
        #expect(client.signOutReason == .sessionEnded)
    }

    @Test func aRefusedUpgradeIsCheckedBeforeSigningOut() async throws {
        try await started()
        var signedOut = 0
        workspace.onSignedOut = { signedOut += 1 }
        let socket = try #require(connector.latest)
        socket.serverCloses(code: SocketClose.revoked)
        // `/api/me` still answers: a bad network, not a lost session, so it tries again later.
        #expect(await eventually { transport.requests("GET", "/api/me").count == 1 })
        #expect(await clock.pass(.seconds(15)))
        #expect(await eventually { connector.connections.count == 2 && workspace.connection == .open })
        #expect(signedOut == 0)
    }

    @Test func any401SignsOut() async throws {
        try await started()
        var signedOut = 0
        workspace.onSignedOut = { signedOut += 1 }
        transport.stub("GET", "/api/sidebar", status: 401, json: Fixtures.errorJSON("Sign in."))
        await workspace.reload()
        #expect(await eventually { signedOut == 1 })
    }
}
