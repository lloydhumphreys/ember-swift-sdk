import EmberTesting
import Foundation
import Testing

/// A room's leases, and jumping to a message, on a mock socket and a clock the tests move.
@MainActor @Suite struct LeaseAndJumpTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    func session(around: MessageID? = nil) -> RoomSession {
        connector.welcomeEverySocket(messages: Fixtures.messages(3))
        return RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: around)
    }

    func welcomed(_ session: RoomSession) async -> Bool {
        await eventually { session.timeline.isLoaded && session.status == .open }
    }

    /// A session open on a page around m100, with older and newer pages either side.
    func onAPage() async throws -> (RoomSession, MockSocketConnection) {
        let session = session()
        session.start()
        try #require(await welcomed(session))
        let socket = try #require(connector.latest)
        session.jump(to: "m100")
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        try #require(await eventually { session.timeline.anchor == "m100" && !session.isJumping })
        return (session, socket)
    }

    // MARK: Leases

    @Test func theSocketOpensWithTheFirstLeaseAndClosesWithTheLast() async throws {
        let session = session()
        #expect(session.status == .idle)
        let first = session.open()
        #expect(await welcomed(session))
        let second = session.open()
        first.close()
        first.close()
        #expect(first.isClosed)
        #expect(session.status == .open)
        second.close()
        #expect(session.status == .idle)
        #expect(connector.connections.count == 1)

        let third = session.open()
        #expect(await eventually { connector.connections.count == 2 && session.status == .open })
        third.close()
        #expect(session.status == .idle)
    }

    @Test func aLeaseLetGoOfCloses() async {
        let session = session()
        var lease: RoomLease? = session.open()
        #expect(await welcomed(session))
        #expect(lease?.isClosed == false)
        lease = nil
        #expect(session.status == .idle)
    }

    @Test func startAndStopAreTheSessionsOwnLease() async {
        let session = session()
        let lease = session.open()
        #expect(await welcomed(session))
        session.start()
        session.start()
        session.stop()
        #expect(session.status == .open)
        lease.close()
        #expect(session.status == .idle)

        session.start()
        #expect(await eventually { session.status == .open })
        session.stop()
        session.stop()
        #expect(session.status == .idle)
    }

    // MARK: Jumping

    @Test func aJumpLastsUntilItsPageAndHoldsBackPaging() async throws {
        connector.onConnect { connection in
            connection.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(40, from: 41), hasMore: true, hasNewer: true))
        }
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id)
        session.start()
        #expect(await welcomed(session))
        let socket = try #require(connector.latest)

        session.jump(to: "m100")
        #expect(session.isJumping)
        session.loadOlder()
        session.loadNewer()
        #expect(await eventually { socket.sent("history.around") == [.historyAround(messageId: "m100")] })
        #expect(socket.sent("history.before").isEmpty)
        #expect(socket.sent("history.after").isEmpty)

        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        #expect(await eventually { !session.isJumping })
        #expect(session.timeline.anchor == "m100")
        session.loadOlder()
        #expect(await eventually { socket.sent("history.before") == [.historyBefore(messageId: "m098")] })

        session.anchorShown()
        #expect(session.timeline.anchor == nil)
    }

    @Test func aRefusedJumpEnds() async throws {
        let session = session()
        session.start()
        #expect(await welcomed(session))
        let socket = try #require(connector.latest)
        session.jump(to: "m404")
        #expect(await eventually { socket.sent("history.around").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.error("Message not found.", failed: "history.around"))
        #expect(await eventually { !session.isJumping })
        #expect(!session.timeline.isLoadingPage)
    }

    @Test func jumpingToLatestTakesAJumpsPlace() async throws {
        let session = session()
        session.start()
        #expect(await welcomed(session))
        let socket = try #require(connector.latest)
        session.jump(to: "m100")
        session.jumpToLatest()
        #expect(!session.isJumping)
        #expect(await eventually { socket.sent("history.around") == [.historyAround(messageId: "m100"), .historyAround(messageId: nil)] })
    }

    @Test func theLatestOfTwoJumpsEndsIt() async throws {
        let session = session()
        session.start()
        #expect(await welcomed(session))
        let socket = try #require(connector.latest)
        session.jump(to: "m50")
        session.jump(to: "m100")
        #expect(await eventually { socket.sent("history.around").count == 2 })
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 48), around: "m50"))
        #expect(await eventually { session.timeline.anchor == "m50" })
        #expect(session.isJumping)
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        #expect(await eventually { !session.isJumping })
    }

    @Test func aJumpBeforeTheRoomLetsTheSocketInWaitsForIt() async throws {
        connector.autoOpen = false
        let session = session()
        session.start()
        #expect(await eventually { connector.connections.count == 1 })
        session.jump(to: "m100")
        #expect(session.isJumping)
        let socket = try #require(connector.latest)
        socket.open()
        #expect(await eventually { socket.sent("history.around") == [.historyAround(messageId: "m100")] })
        #expect(session.isJumping)
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        #expect(await eventually { !session.isJumping })
    }

    @Test func aSessionOpenedAroundAMessageIsJumpingUntilItsWelcome() async {
        let session = session(around: "m100")
        #expect(session.isJumping)
        session.start()
        #expect(await welcomed(session))
        #expect(!session.isJumping)
    }

    @Test func aJumpTheSocketDroppedIsAskedForAgain() async throws {
        let session = session()
        session.start()
        #expect(await welcomed(session))
        let first = try #require(connector.latest)
        session.jump(to: "m100")
        #expect(await eventually { first.sent("history.around").count == 1 })
        first.serverCloses(code: SocketClose.reconnect)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        clock.advance(by: timing.reconnectFloor)
        #expect(await eventually { connector.connections.count == 2 })
        #expect(connector.latest?.request.query?.contains("around=m100") == true)
        // The timeline stays loaded across the drop, so wait on the jump itself, not on loading.
        #expect(await eventually { session.status == .open && !session.isJumping })
    }

    @Test func pagesEitherSideAndLiveMessagesLeaveTheAnchor() async throws {
        let (session, socket) = try await onAPage()
        session.loadOlder()
        #expect(await eventually { socket.sent("history.before").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.history(before: "m098", messages: Fixtures.messages(5, from: 93), hasMore: true))
        #expect(await eventually { session.timeline.messages.first?.id == "m093" })
        session.loadNewer()
        #expect(await eventually { socket.sent("history.after").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.historyAfter(after: "m102", messages: Fixtures.messages(5, from: 103), hasNewer: true))
        #expect(await eventually { session.timeline.messages.last?.id == "m107" })
        socket.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message("m200", "Late", by: Fixtures.grace, minute: 9), seq: 11))
        #expect(await eventually { session.timeline.seq == 11 })
        #expect(session.timeline.anchor == "m100")
    }

    @Test func theNewestPageClearsTheAnchor() async throws {
        let (session, socket) = try await onAPage()
        session.jumpToLatest()
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(3), hasMore: true, hasNewer: false, around: nil))
        #expect(await eventually { session.timeline.anchor == nil })
    }

    @Test func aPlainWelcomeClearsTheAnchor() async throws {
        let (session, socket) = try await onAPage()
        socket.serverCloses(code: SocketClose.reconnect)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        clock.advance(by: timing.reconnectFloor)
        #expect(await eventually { connector.connections.count == 2 && session.timeline.anchor == nil })
    }
}
