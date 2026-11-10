import EmberTesting
import Foundation
import Testing

/// Where a room's messages land, what it catches up from, and what it does with actions it can't send.
@MainActor @Suite struct RoomOrderingTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    func session() -> RoomSession {
        RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id)
    }

    /// Starts `session` with every socket welcomed `welcome`, and waits for it.
    func opened(_ session: RoomSession, welcome: String = Fixtures.RoomFrames.welcome()) async throws -> MockSocketConnection {
        connector.onConnect { $0.serverSends(welcome) }
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return try #require(connector.latest)
    }

    /// The query items of `socket`'s request, by name.
    func query(_ socket: MockSocketConnection?) -> [String: String] {
        let items = socket?.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    /// The paging and message frames `socket` sent, in order.
    func pagesAndMessages(_ socket: MockSocketConnection) -> [ClientFrame] {
        socket.sentFrames.filter {
            switch $0 {
            case .historyAround, .createMessage: true
            default: false
            }
        }
    }

    // MARK: Catching up

    @Test func aGapInSeqIsCaughtUpFromBeforeIt() async throws {
        let session = session()
        let first = try await opened(session, welcome: Fixtures.RoomFrames.welcome(seq: 0))
        first.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message("m004", "One", by: Fixtures.grace, minute: 4), seq: 1))
        first.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message("m005", "Three", by: Fixtures.grace, minute: 5), seq: 3))
        first.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message("m006", "Four", by: Fixtures.grace, minute: 6), seq: 4))
        #expect(await eventually { session.timeline.messages.last?.id == "m006" })
        #expect(session.timeline.seq == 1)

        first.serverCloses(code: SocketClose.reconnect)
        #expect(await eventually { connector.connections.count == 2 })
        #expect(query(connector.latest)["since"] == "1")
        #expect(query(connector.latest)["around"] == nil)
    }

    @Test func jumpingToLatestWhileDisconnectedOpensOnTheNewestPage() async throws {
        let session = session()
        let first = try await opened(session)
        first.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        session.jumpToLatest()
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 2 })
        let items = query(connector.latest)
        #expect(items["since"] == nil)
        #expect(items["around"] == nil)
        #expect(await eventually { session.status == .open && session.timeline.isLoaded })
        #expect(!session.isJumping)
    }

    @Test func aJumpWhileDisconnectedOpensAroundItsMessage() async throws {
        let session = session()
        let first = try await opened(session)
        first.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        session.jump(to: "m100")
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 2 })
        #expect(query(connector.latest)["around"] == "m100")
        #expect(query(connector.latest)["since"] == nil)
    }

    // MARK: Where a message lands

    @Test func sendingWhileReadingOlderHistoryAsksForTheNewestPageFirst() async throws {
        let session = session()
        let socket = try await opened(session, welcome: Fixtures.RoomFrames.welcome(hasMore: true, hasNewer: true))
        let id = session.send(body: "<p>Hi</p>", plainText: "Hi")
        #expect(await eventually { socket.sent("message.create").count == 1 })
        #expect(pagesAndMessages(socket) == [.historyAround(messageId: nil), .createMessage(clientMessageId: id, body: "<p>Hi</p>")])

        // Its confirmation, landing before the newest page, isn't news.
        socket.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.message("m009", "Hi", by: Fixtures.ada, minute: 9, clientMessageId: id), seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(session.timeline.arrivals == 0)
    }

    @Test func sendingDuringAJumpEndsIt() async throws {
        let session = session()
        let socket = try await opened(session)
        session.jump(to: "m100")
        let id = session.send(body: "Hi", plainText: "Hi")
        #expect(!session.isJumping)
        #expect(await eventually { socket.sent("message.create").count == 1 })
        #expect(pagesAndMessages(socket) == [
            .historyAround(messageId: "m100"), .historyAround(messageId: nil), .createMessage(clientMessageId: id, body: "Hi"),
        ])
    }

    @Test func sendingAtTheLatestJustSends() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "Hi", plainText: "Hi")
        #expect(await eventually { socket.sent("message.create").count == 1 })
        #expect(pagesAndMessages(socket) == [.createMessage(clientMessageId: id, body: "Hi")])
    }

    @Test func aRetryAwayFromTheLatestAsksForTheNewestPageFirst() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "Hi", plainText: "Hi")
        socket.serverSends(Fixtures.RoomFrames.error("Slow down.", clientMessageId: id, failed: "message.create"))
        #expect(await eventually { session.timeline.pending.first?.failure != nil })
        session.jump(to: "m100")
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        #expect(await eventually { !session.isJumping && session.timeline.hasNewer })

        session.retry(id)
        #expect(await eventually { socket.sent("message.create").count == 2 })
        #expect(pagesAndMessages(socket).suffix(2) == [.historyAround(messageId: nil), .createMessage(clientMessageId: id, body: "Hi")])
    }

    @Test func aMessageWaitingForTheRoomAsksForTheNewestPageFirst() async throws {
        connector.onConnect { _ in }
        let session = session()
        session.start()
        #expect(await eventually { session.status == .open })
        let socket = try #require(connector.latest)
        let id = session.send(body: "Hi", plainText: "Hi")
        #expect(socket.sent.isEmpty)

        socket.serverSends(Fixtures.RoomFrames.welcome(hasMore: true, hasNewer: true))
        #expect(await eventually { socket.sent("message.check").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { socket.sent("message.create").count == 1 })
        #expect(pagesAndMessages(socket) == [.historyAround(messageId: nil), .createMessage(clientMessageId: id, body: "Hi")])
    }

    // MARK: Actions that can't wait

    @Test func actionsBeforeTheRoomLetsTheSocketInAreRefused() async throws {
        connector.onConnect { _ in }
        let session = session()
        session.start()
        #expect(await eventually { session.status == .open })
        let socket = try #require(connector.latest)

        #expect(!session.edit("m001", body: "Changed"))
        #expect(session.notice == RoomSession.notConnected)
        session.notice = nil
        #expect(!session.delete("m001"))
        #expect(session.notice == RoomSession.notConnected)
        #expect(!session.boost("m001", content: "👍"))
        #expect(!session.removeBoost("b001"))
        #expect(socket.sent.isEmpty)

        // Nothing was kept to send once it's in.
        socket.serverSends(Fixtures.RoomFrames.welcome())
        #expect(await eventually { session.timeline.isLoaded })
        #expect(session.edit("m001", body: "Changed"))
        #expect(await eventually { socket.sent("message.update").count == 1 })
        #expect(socket.sent("message.delete").isEmpty)
        #expect(socket.sent("boost.create").isEmpty)
        #expect(socket.sent("boost.delete").isEmpty)
    }

    @Test func actionsWithNoSocketAreRefused() {
        let session = session()
        #expect(!session.boost("m001", content: "👍"))
        #expect(session.notice == RoomSession.notConnected)
        #expect(connector.connections.isEmpty)
    }

    @Test func aBoostIsTrimmedAndOneTooLongIsntSent() async throws {
        let session = session()
        let socket = try await opened(session)
        #expect(!session.boost("m001", content: String(repeating: "🔥", count: 9)))
        #expect(!session.boost("m001", content: "   "))
        #expect(session.notice == nil)
        #expect(session.boost("m002", content: "  so good \n"))
        #expect(session.removeBoost("b001"))
        #expect(await eventually { socket.sent("boost.delete").count == 1 })
        #expect(socket.sent("boost.create") == [.createBoost(messageId: "m002", content: "so good")])
    }
}
