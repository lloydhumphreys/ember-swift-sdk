import EmberTesting
import Foundation
import Testing

/// A room end to end, on a mock socket and a clock the tests move.
@MainActor @Suite struct RoomSessionTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    /// A session in General whose every socket is welcomed with `messages`, unless the test scripts its own.
    func session(messages: [Message] = Fixtures.messages(3), around: String? = nil, welcome: Bool = true) -> RoomSession {
        if welcome { connector.welcomeEverySocket(messages: messages) }
        return RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, around: around)
    }

    /// Starts `session` and waits for its welcome.
    func opened(_ session: RoomSession) async throws -> MockSocketConnection {
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return try #require(connector.latest)
    }

    @Test func welcomes() async throws {
        let session = session()
        let socket = try await opened(session)
        #expect(session.timeline.messages.map(\.id) == ["m001", "m002", "m003"])
        #expect(session.timeline.seq == 10)
        #expect(socket.request.url?.path == "/api/rooms/room-general/socket")
        #expect(socket.request.query == "visible=1&protocol=\(RoomSocket.protocolRevision)")
        #expect(socket.request.value(forHTTPHeaderField: "Origin") == "https://ember.test")
    }

    @Test func aSentMessageIsPendingUntilCreated() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(session.timeline.pending.map(\.clientMessageId) == [id])
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Hello</p>")] })

        let created = Fixtures.message("m004", "Hello", by: Fixtures.ada, minute: 4, clientMessageId: id)
        socket.serverSends(Fixtures.RoomFrames.messageCreated(created, seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(session.timeline.messages.last?.id == "m004")
        #expect(session.timeline.seq == 11)
    }

    @Test func aRefusedMessageSaysWhyAndCanBeRetried() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        socket.serverSends(Fixtures.RoomFrames.error("That’s too long.", clientMessageId: id, failed: "message.create"))
        #expect(await eventually { session.timeline.pending.first?.failure == "That’s too long." })
        #expect(session.notice == nil)

        session.retry(id)
        #expect(session.timeline.pending.first?.failure == nil)
        #expect(await eventually { socket.sent("message.create").count == 2 })
        session.discard(id)
        #expect(session.timeline.pending.isEmpty)
    }

    @Test func anEditsRefusalIsANotice() async throws {
        let session = session()
        let socket = try await opened(session)
        session.edit("m001", body: "<p>Changed</p>")
        session.delete("m002")
        session.boost("m003", content: "👍")
        #expect(await eventually { socket.sent.count == 3 })
        #expect(socket.sentFrames == [
            .updateMessage(messageId: "m001", body: "<p>Changed</p>"),
            .deleteMessage(messageId: "m002"),
            .createBoost(messageId: "m003", content: "👍"),
        ])
        socket.serverSends(Fixtures.RoomFrames.error("You can’t edit that."))
        #expect(await eventually { session.notice == "You can’t edit that." })
    }

    @Test func aMessageSentBeforeTheRoomLetsItInGoesOnceChecked() async throws {
        connector.autoOpen = false
        let session = session(welcome: false)
        let id = session.send(body: "<p>Early</p>", plainText: "Early")
        session.start()
        #expect(await eventually { connector.connections.count == 1 })
        let socket = try #require(connector.latest)
        socket.open()
        #expect(await eventually { session.status == .open })
        await settle()
        // Nothing goes until the room says welcome.
        #expect(socket.sent.isEmpty)

        socket.serverSends(Fixtures.RoomFrames.welcome())
        #expect(await eventually { socket.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        #expect(socket.sent("message.create").isEmpty)
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Early</p>")] })
    }

    @Test func reconnectingCatchesUpAndChecksWhatsPending() async throws {
        let session = session()
        let first = try await opened(session)
        let created = Fixtures.message("m004", "Hello", minute: 4)
        first.serverSends(Fixtures.RoomFrames.messageCreated(created, seq: 11))
        #expect(await eventually { session.timeline.seq == 11 })

        first.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount == 1 })
        let id = session.send(body: "<p>Offline</p>", plainText: "Offline")
        #expect(first.sent("message.create").isEmpty)

        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 2 && session.status == .open })
        let second = try #require(connector.latest)
        #expect(second.request.query == "visible=1&protocol=\(RoomSocket.protocolRevision)&since=11")
        #expect(await eventually { second.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        #expect(second.sent("message.create").isEmpty)
    }

    @Test func pagesOlderAndNewer() async throws {
        connector.onConnect { connection in
            connection.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(40, from: 41), hasMore: true, hasNewer: true))
        }
        let session = session(welcome: false)
        let socket = try await opened(session)
        #expect(session.timeline.hasMore)

        session.loadOlder()
        session.loadOlder()
        #expect(await eventually { socket.sent("history.before") == [.historyBefore(messageId: "m041")] })
        socket.serverSends(Fixtures.RoomFrames.history(before: "m041", messages: Fixtures.messages(40, from: 1), hasMore: false))
        #expect(await eventually { session.timeline.messages.count == 80 })
        #expect(!session.timeline.hasMore)
        session.loadOlder()

        session.loadNewer()
        #expect(await eventually { socket.sent("history.after") == [.historyAfter(messageId: "m080")] })
        socket.serverSends(Fixtures.RoomFrames.historyAfter(after: "m080", messages: Fixtures.messages(5, from: 81), hasNewer: false))
        #expect(await eventually { session.timeline.messages.last?.id == "m085" })
        // Frames go out in order, so once this one has, a second page would have too.
        session.setVisible(false)
        #expect(await eventually { socket.sent("presence.visible").count == 1 })
        #expect(socket.sent("history.before").count == 1)
    }

    @Test func jumpsToAMessage() async throws {
        let session = session()
        let socket = try await opened(session)
        session.jump(to: "m100")
        #expect(await eventually { socket.sent("history.around") == [.historyAround(messageId: "m100")] })
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        #expect(await eventually { session.timeline.anchor == "m100" })
        #expect(session.timeline.messages.map(\.id).contains("m100"))

        session.jumpToLatest()
        #expect(await eventually { socket.sent("history.around").last == .historyAround(messageId: nil) })
    }

    @Test func opensAroundAMessage() async throws {
        let session = session(messages: Fixtures.messages(5, from: 98), around: "m100")
        let socket = try await opened(session)
        #expect(socket.request.query == "visible=1&protocol=\(RoomSocket.protocolRevision)&around=m100")
        session.setVisible(false)
        #expect(await eventually { socket.sent("presence.visible").count == 1 })
        #expect(socket.sent("history.around").isEmpty)
    }

    @Test func throttlesTyping() async throws {
        let session = session()
        let socket = try await opened(session)
        let starts = { socket.sent("typing.start").count }
        let stops = { socket.sent("typing.stop").count }

        session.setTyping(true)
        session.setTyping(true)
        #expect(await eventually { starts() == 1 })
        session.setTyping(false)
        #expect(await eventually { stops() == 1 })
        // Within the throttle, even after a stop, no second start; and so no second stop.
        session.setTyping(true)
        session.setTyping(false)
        session.setVisible(false)
        #expect(await eventually { socket.sent("presence.visible").count == 1 })
        #expect(starts() == 1)
        #expect(stops() == 1)

        // The heartbeat and the throttle are waiting.
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(1))
        #expect(await eventually {
            session.setTyping(true)
            return starts() == 2
        })

        // Left alone, the composer stops typing by itself.
        #expect(await eventually { clock.sleeperCount == 3 })
        clock.advance(by: .seconds(5))
        #expect(await eventually { stops() == 2 })
    }

    @Test func aRoomYouLeftStops() async {
        connector.onConnect { connection in connection.serverCloses(code: SocketClose.notFound) }
        let session = session(welcome: false)
        session.start()
        #expect(await eventually { session.status == .stopped(.notFound) })
    }

    @Test func aRevokedRoomSocketSignsOut() async {
        connector.onConnect { connection in connection.serverCloses(code: SocketClose.revoked) }
        let session = session(welcome: false)
        var signedOut = false
        session.onSignedOut = { signedOut = true }
        session.start()
        #expect(await eventually { signedOut })
    }

    @Test func visibilityIsSent() async throws {
        let session = session()
        let socket = try await opened(session)
        session.setVisible(false)
        #expect(await eventually { socket.sent("presence.visible") == [.visible(false)] })
        #expect(!session.isVisible)
    }

    @Test func theMockOpensWithItsMessages() async {
        let session = RoomSession.mock(messages: Fixtures.messages(7))
        session.start()
        #expect(await eventually { session.timeline.messages.count == 7 })
        session.stop()
    }
}
