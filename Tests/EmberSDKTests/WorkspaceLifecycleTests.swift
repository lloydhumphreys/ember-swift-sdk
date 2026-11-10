import EmberTesting
import Foundation
import Testing

/// The workspace's rooms across stopping, starting and shutting down, its cache of sessions, and
/// answers that come back out of order.
@MainActor @Suite struct WorkspaceLifecycleTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let workspace: Workspace

    init() {
        let (timing, _) = manualTiming()
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    func started() async throws {
        workspace.start()
        try #require(await eventually { workspace.isLoaded && transport.requests("GET", "/api/sidebar").count >= 2 })
        await workspace.reload()
    }

    var roomSockets: [MockSocketConnection] {
        connector.connections.filter { $0.request.url?.path.hasSuffix("/socket") == true && $0.request.url?.path != "/api/socket" }
    }

    func involvementAnswer() -> @Sendable (URLRequest) throws -> (status: Int, json: String) {
        { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (200, #"{"involvement":"\#(body?["involvement"] as? String ?? "")"}"#)
        }
    }

    // MARK: Stopping and starting

    @Test func stoppingClosesTheRoomsAndStartingCatchesThemUp() async throws {
        try await started()
        let session = workspace.session(for: Fixtures.general.id)
        let lease = session.open()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })

        workspace.stop()
        #expect(session.status == .idle)
        #expect(workspace.connection == .idle)
        workspace.start()
        #expect(await eventually { session.status == .open && roomSockets.count == 2 })
        #expect(roomSockets.last?.request.query?.contains("since=10") == true)
        lease.close()
    }

    @Test func aRoomOpenedWhileStoppedWaitsForStart() async throws {
        let session = workspace.session(for: Fixtures.general.id)
        let lease = session.open()
        await settle()
        #expect(roomSockets.isEmpty)
        #expect(session.status == .idle)
        workspace.start()
        #expect(await eventually { session.status == .open })
        #expect(roomSockets.count == 1)
        lease.close()
    }

    @Test func aRoomWithNoLeaseStaysClosedOnStart() async throws {
        try await started()
        let session = workspace.session(for: Fixtures.general.id)
        workspace.stop()
        workspace.start()
        await settle()
        #expect(roomSockets.isEmpty)
        #expect(session.status == .idle)
    }

    // MARK: The cache

    @Test func keepsLeasedSessionsAndTheLatestIdleOnes() async throws {
        let leased = workspace.session(for: "leased")
        let lease = leased.open()
        let rooms = (0..<10).map { workspace.session(for: "r\($0)") }
        // r0 and r1 are the two idle sessions least recently used, beyond the eight kept; the leased
        // one is older than all of them and stays. A session let go of no longer hears sign-out.
        #expect(leased.onSignedOut != nil)
        #expect(rooms.map { $0.onSignedOut == nil } == [true, true] + Array(repeating: false, count: 8))
        #expect(workspace.session(for: "leased") === leased)

        // The test still holds r0, so it's the one answered again, back in the cache, where it
        // counts as used and crowds out the idle one now least recently used.
        #expect(workspace.session(for: "r0") === rooms[0])
        #expect(rooms[0].onSignedOut != nil)
        #expect(rooms[2].onSignedOut == nil)
        #expect(rooms[3].onSignedOut != nil)
        lease.close()
    }

    @Test func usingASessionKeepsIt() async {
        let first = workspace.session(for: "r0")
        for index in 1..<8 { _ = workspace.session(for: "r\(index)") }
        #expect(workspace.session(for: "r0") === first)
        _ = workspace.session(for: "r8")
        _ = workspace.session(for: "r9")
        #expect(workspace.session(for: "r0") === first)
        #expect(first.onSignedOut != nil)
    }

    @Test func aSessionLosingItsLastLeaseCanBeLetGoOf() async {
        let first = workspace.session(for: "r0")
        let lease = first.open()
        for index in 1..<10 { _ = workspace.session(for: "r\(index)") }
        #expect(first.onSignedOut != nil)
        lease.close()
        #expect(first.onSignedOut == nil)
    }

    // MARK: Shutting down

    @Test func shuttingDownIsFinal() async throws {
        try await started()
        let session = workspace.session(for: Fixtures.general.id)
        let lease = session.open()
        try #require(await eventually { session.status == .open })
        let connections = connector.connections.count

        workspace.shutdown()
        workspace.shutdown()
        #expect(workspace.connection == .idle)
        #expect(session.status == .idle)
        #expect(session.onSignedOut == nil)
        #expect(workspace.session(for: Fixtures.general.id) !== session)

        workspace.start()
        let requests = transport.requests.count
        await workspace.reload()
        await workspace.reloadDirectory()
        await settle()
        #expect(connector.connections.count == connections)
        #expect(transport.requests.count == requests)
        lease.close()
    }

    @Test func aLoadLandingAfterShutdownIsDropped() async {
        let gate = transport.hold("GET", "/api/sidebar")
        let loading = Task { await workspace.reload() }
        await gate.waitForRequest()
        workspace.shutdown()
        gate.release()
        await loading.value
        #expect(!workspace.isLoaded)
        #expect(workspace.rooms.isEmpty)
    }

    // MARK: Answers out of order

    @Test func theLatestLevelWinsWhateverOrderTheAnswersCome() async throws {
        try await started()
        let path = "/api/rooms/room-general/involvement"
        transport.stub("PUT", path, involvementAnswer())
        let first = transport.hold("PUT", path)
        let second = transport.hold("PUT", path)
        let asking = Task { await workspace.setInvolvement(.nothing, roomID: Fixtures.general.id) }
        await first.waitForRequest()
        let askingAgain = Task { await workspace.setInvolvement(.everything, roomID: Fixtures.general.id) }
        await second.waitForRequest()
        second.release()
        await askingAgain.value
        first.release()
        await asking.value
        #expect(workspace.room(Fixtures.general.id)?.involvement == .everything)
    }

    @Test func aRefusedLatestLevelGoesBackToTheServersLast() async throws {
        try await started()
        let path = "/api/rooms/room-general/involvement"
        let first = transport.hold("PUT", path)
        let second = transport.hold("PUT", path)
        transport.stub("PUT", path, involvementAnswer())
        let asking = Task { await workspace.setInvolvement(.nothing, roomID: Fixtures.general.id) }
        await first.waitForRequest()
        let askingAgain = Task { await workspace.setInvolvement(.everything, roomID: Fixtures.general.id) }
        await second.waitForRequest()
        first.release()
        await asking.value
        #expect(workspace.room(Fixtures.general.id)?.involvement == .everything)
        transport.stub("PUT", path, status: 403, json: Fixtures.errorJSON("Not here."))
        second.release()
        await askingAgain.value
        #expect(workspace.room(Fixtures.general.id)?.involvement == .nothing)
        #expect(workspace.notice == "Not here.")
    }

    // MARK: The directory

    @Test func theDirectorySaysWhereItIs() async throws {
        #expect(workspace.directoryStatus == .loading)
        transport.stub("GET", "/api/users", status: 500, json: Fixtures.errorJSON("Something went wrong."))
        await workspace.reload()
        #expect(workspace.directoryStatus == .failed("Something went wrong."))
        #expect(workspace.isLoaded)

        transport.stub("GET", "/api/users", json: Fixtures.directoryJSON())
        await workspace.reloadDirectory()
        #expect(workspace.directoryStatus == .loaded)
        #expect(workspace.person(Fixtures.grace.id) != nil)

        // Once loaded, a failed reload keeps what it had.
        transport.stub("GET", "/api/users", status: 500, json: Fixtures.errorJSON("Something went wrong."))
        await workspace.reloadDirectory()
        #expect(workspace.directoryStatus == .loaded)
        #expect(workspace.person(Fixtures.grace.id) != nil)
    }
}
