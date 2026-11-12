import EmberTesting
import Foundation
import Testing

/// What a room does after a page fails, a change goes missing, or a reconnect can't resume.
@MainActor @Suite struct RoomRecoveryTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    func session() -> RoomSession {
        RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id)
    }

    func opened(_ session: RoomSession, welcome: String) async throws -> MockSocketConnection {
        connector.onConnect { $0.serverSends(welcome) }
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return try #require(connector.latest)
    }

    func query(_ socket: MockSocketConnection?) -> [String: String] {
        let items = socket?.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    func olderPages(_ socket: MockSocketConnection) -> Int {
        socket.sentFrames.filter { if case .historyBefore = $0 { true } else { false } }.count
    }

    @Test func aFailedOlderPageWaitsForARetry() async throws {
        let session = session()
        let socket = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3, from: 5), hasMore: true))
        session.loadOlder()
        #expect(await eventually { olderPages(socket) == 1 })
        socket.serverSends(Fixtures.RoomFrames.error("Too many requests", failed: "history.before"))
        #expect(await eventually { session.timeline.olderPageFailure == "Too many requests" })
        #expect(session.notice == nil)
        session.loadOlder()
        session.loadOlder()
        #expect(olderPages(socket) == 1)
        session.retryOlder()
        #expect(await eventually { olderPages(socket) == 2 })
        #expect(session.timeline.olderPageFailure == nil)
    }

    @Test func anOlderPageTheRoomDoesntAnswerFailsAsARefusedOneDoesAndRetryLoadsIt() async throws {
        let session = session()
        let socket = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3, from: 5), hasMore: true))
        session.loadOlder()
        #expect(await eventually { olderPages(socket) == 1 })
        #expect(await clock.sleeping(dueWithin: RoomSession.pageTimeout))
        clock.advance(by: RoomSession.pageTimeout - .seconds(1))
        await settle()
        #expect(session.timeline.isLoadingOlder)
        #expect(await clock.pass(.seconds(1)))
        #expect(await eventually { session.timeline.olderPageFailure == Timeline.pageNotLoaded })
        #expect(!session.timeline.isLoadingOlder)

        session.retryOlder()
        #expect(await eventually { olderPages(socket) == 2 })
        socket.serverSends(Fixtures.RoomFrames.history(before: "m005", messages: Fixtures.messages(3, from: 2), hasMore: false))
        #expect(await eventually { session.timeline.messages.first?.id == "m002" })
        #expect(session.timeline.olderPageFailure == nil)
    }

    @Test func anOlderPageOnItsWayWhenTheSocketDropsFailsAndPagesAgainAfterTheReconnect() async throws {
        let session = session()
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3, from: 5), hasMore: true))
        session.loadOlder()
        #expect(await eventually { olderPages(first) == 1 })
        first.serverCloses(code: 1006)
        #expect(await eventually { session.timeline.olderPageFailure == Timeline.pageNotLoaded })
        #expect(!session.timeline.isLoadingOlder)

        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count == 2 && session.phase == .admitted })
        let second = try #require(connector.latest)
        session.retryOlder()
        #expect(await eventually { olderPages(second) == 1 })
        #expect(session.timeline.isLoadingOlder)
    }

    @Test func aNewerPageTheRoomDoesntAnswerFailsAndRetryAsksAgain() async throws {
        let session = session()
        let socket = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3), hasNewer: true, around: "m002"))
        session.loadNewer()
        let newer = { socket.sentFrames.filter { if case .historyAfter = $0 { true } else { false } }.count }
        #expect(await eventually { newer() == 1 })
        #expect(await clock.pass(RoomSession.pageTimeout))
        #expect(await eventually { session.timeline.newerPageFailure == Timeline.pageNotLoaded })
        session.retryNewer()
        #expect(await eventually { newer() == 2 })
        #expect(session.timeline.newerPageFailure == nil)
    }

    @Test func aChangeLostForGoodIsCaughtUpWithoutWaitingForADrop() async throws {
        let session = session()
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3), seq: 10))
        for (n, seq) in [(5, 12), (6, 13), (7, 14)] {
            first.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message(String(format: "m%03d", n), "Later", minute: n), seq: seq))
        }
        #expect(await eventually { connector.connections.count == 2 })
        #expect(query(connector.latest)["since"] == "10")
    }

    @Test func aReaderScrolledUpKeepsTheirPlaceWhenTheRoomCantResume() async throws {
        let session = session()
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(20), seq: 10, hasMore: true))
        session.setAwayFromLatest(true)
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(20, from: 200), seq: 400, hasMore: true)) }
        first.serverCloses(code: SocketClose.reconnect)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(await eventually { connector.connections.count == 2 && session.timeline.seq == 400 })
        #expect(session.timeline.messages.first?.id == "m001")
        #expect(session.timeline.messages.last?.id == "m020")
        #expect(session.timeline.hasNewer)
    }

    /// Opened on the page around m120 (as from a search), landed, one older page in (m040 to m079),
    /// and with `inFlight` the next one asked for when the socket drops; then the room answers the
    /// next connection with `reconnect`.
    func jumpedPagedAndBack(inFlight: Bool, away: Bool = false, reconnect: String) async throws -> (RoomSession, MockSocketConnection) {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: "m120")
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(81, from: 80), seq: 10, hasMore: true, hasNewer: true, around: "m120"))
        #expect(query(first)["around"] == "m120")
        #expect(!session.isJumping)
        session.anchorShown()
        session.loadOlder()
        #expect(await eventually { olderPages(first) == 1 })
        first.serverSends(Fixtures.RoomFrames.history(before: "m080", messages: Fixtures.messages(40, from: 40), hasMore: true))
        #expect(await eventually { session.timeline.messages.first?.id == "m040" })
        if inFlight {
            session.loadOlder()
            #expect(await eventually { olderPages(first) == 2 })
        }
        session.setAwayFromLatest(away)
        connector.onConnect { $0.serverSends(reconnect) }
        first.serverCloses(code: 1006)
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count == 2 && session.phase == .admitted })
        let second = try #require(connector.latest)
        #expect(query(second)["since"] == "10")
        #expect(query(second)["around"] == nil)
        return (session, second)
    }

    /// Paging older asks for the page before m040 on the new connection, and it lands.
    func pagesOn(_ session: RoomSession, _ socket: MockSocketConnection) async {
        #expect(!session.isJumping)
        #expect(session.timeline.anchor == nil)
        if session.timeline.olderPageFailure != nil { session.retryOlder() } else { session.loadOlder() }
        #expect(await eventually { olderPages(socket) == 1 })
        #expect(socket.sentFrames.contains(.historyBefore(messageId: "m040")))
        socket.serverSends(Fixtures.RoomFrames.history(before: "m040", messages: Fixtures.messages(39, from: 1), hasMore: false))
        #expect(await eventually { session.timeline.messages.first?.id == "m001" })
    }

    @Test(arguments: [false, true]) func aRoomOpenedByAJumpPagesOlderAfterCatchingUp(inFlight: Bool) async throws {
        let (session, socket) = try await jumpedPagedAndBack(inFlight: inFlight, reconnect: Fixtures.RoomFrames.resumed(seq: 12))
        await pagesOn(session, socket)
    }

    @Test(arguments: [false, true]) func aRoomOpenedByAJumpPagesOlderAfterANewestPageThatOverlaps(inFlight: Bool) async throws {
        let welcome = Fixtures.RoomFrames.welcome(messages: Fixtures.messages(40, from: 141), seq: 400, hasMore: true)
        let (session, socket) = try await jumpedPagedAndBack(inFlight: inFlight, reconnect: welcome)
        #expect(session.timeline.messages.first?.id == "m040")
        await pagesOn(session, socket)
    }

    @Test(arguments: [false, true]) func aRoomOpenedByAJumpPagesOlderAfterANewestPageThatDoesntOverlap(inFlight: Bool) async throws {
        let welcome = Fixtures.RoomFrames.welcome(messages: Fixtures.messages(40, from: 200), seq: 400, hasMore: true)
        let (session, socket) = try await jumpedPagedAndBack(inFlight: inFlight, away: true, reconnect: welcome)
        #expect(session.timeline.messages.first?.id == "m040")
        await pagesOn(session, socket)
    }

    /// The room stops answering for a while, as a server paused with `kill -STOP`: the page on its
    /// way (or one asked for meanwhile) gets no answer, the unanswered ping drops the socket, and
    /// connecting again waits until the room comes back and catches the client up.
    @Test(arguments: [false, true]) func aRoomOpenedByAJumpPagesOlderAfterTheRoomStopsAnsweringForAWhile(inFlight: Bool) async throws {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: "m120")
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(81, from: 80), seq: 10, hasMore: true, hasNewer: true, around: "m120"))
        session.anchorShown()
        session.loadOlder()
        #expect(await eventually { olderPages(first) == 1 })
        first.serverSends(Fixtures.RoomFrames.history(before: "m080", messages: Fixtures.messages(40, from: 40), hasMore: true))
        #expect(await eventually { session.timeline.messages.first?.id == "m040" })
        session.setAwayFromLatest(true)
        connector.autoOpen = false
        connector.onConnect { _ in }
        if inFlight {
            session.loadOlder()
            #expect(await eventually { olderPages(first) == 2 })
        }
        // The next beat pings, the one after finds it unanswered and drops the socket, and the
        // backoff after that connects again.
        #expect(await clock.pass(timing.heartbeat, waking: inFlight ? 2 : 1))
        #expect(await eventually { first.sent.contains(ReconnectingSocket.ping) })
        #expect(await clock.pass(timing.heartbeat))
        #expect(await eventually { first.isClosedByClient })
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count > 1 })
        #expect(session.phase != .admitted)
        session.loadOlder()
        let socket = try #require(connector.latest)
        connector.autoOpen = true
        socket.serverSends(Fixtures.RoomFrames.resumed(seq: 10))
        socket.open()
        #expect(await eventually { session.phase == .admitted })
        #expect(query(socket)["since"] == "10")
        await pagesOn(session, socket)
    }

    /// The reader reaches the top while the room is reconnecting: the page asked for then goes once
    /// the room lets the socket in, with nothing asked again, since the view has already asked.
    @Test func anOlderPageAskedForWhileReconnectingGoesOnceTheRoomIsBack() async throws {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: "m120")
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(81, from: 80), seq: 10, hasMore: true, hasNewer: true, around: "m120"))
        session.anchorShown()
        connector.autoOpen = false
        first.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        session.loadOlder()
        session.loadOlder()
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count == 2 })
        let second = try #require(connector.latest)
        #expect(second !== first)
        second.serverSends(Fixtures.RoomFrames.resumed(seq: 10))
        second.open()
        #expect(await eventually { olderPages(second) == 1 })
        #expect(second.sentFrames.contains(.historyBefore(messageId: "m080")))
        second.serverSends(Fixtures.RoomFrames.history(before: "m080", messages: Fixtures.messages(40, from: 40), hasMore: true))
        #expect(await eventually { session.timeline.messages.first?.id == "m040" })
        await settle()
        #expect(olderPages(second) == 1)
    }

    /// The same for the newer page, after a jump.
    @Test func aNewerPageAskedForWhileReconnectingGoesOnceTheRoomIsBack() async throws {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: "m120")
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(81, from: 80), seq: 10, hasMore: true, hasNewer: true, around: "m120"))
        session.anchorShown()
        connector.autoOpen = false
        first.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        session.loadNewer()
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count == 2 })
        let second = try #require(connector.latest)
        second.serverSends(Fixtures.RoomFrames.resumed(seq: 10))
        second.open()
        #expect(await eventually { second.sentFrames.contains(.historyAfter(messageId: "m160")) })
    }

    /// A jump asked for while reconnecting replaces the page the wish was for: nothing goes for it.
    @Test func aPageAskedForWhileReconnectingIsForgottenByAJump() async throws {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: "m120")
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(messages: Fixtures.messages(81, from: 80), seq: 10, hasMore: true, hasNewer: true, around: "m120"))
        session.anchorShown()
        connector.autoOpen = false
        first.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        session.loadOlder()
        session.jumpToLatest()
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { connector.connections.count == 2 })
        let second = try #require(connector.latest)
        second.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(40, from: 200), seq: 400, hasMore: true))
        second.open()
        #expect(await eventually { session.timeline.messages.first?.id == "m200" })
        await settle()
        #expect(olderPages(second) == 0)
    }
}
