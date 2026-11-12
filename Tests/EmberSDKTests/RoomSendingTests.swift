import EmberRichText
import EmberTesting
import Foundation
import Testing

/// Sending in a room: its phase, what's unsent across a lease and a launch, messages that never
/// get an answer, the `async` changes, and text typed in plain.
@MainActor @Suite struct RoomSendingTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        var (timing, clock) = manualTiming()
        // A socket left connecting stays so while the tests move the clock, instead of timing out
        // and trying again.
        timing.connectTimeout = .seconds(1_000_000)
        self.timing = timing
        self.clock = clock
    }

    func session(connector: MockSocketConnector? = nil, store: MemoryUnsentMessageStore = MemoryUnsentMessageStore(), welcome: Bool = true) -> RoomSession {
        let connector = connector ?? self.connector
        if welcome { connector.welcomeEverySocket() }
        return RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: store)
    }

    func opened(_ session: RoomSession, on connector: MockSocketConnector? = nil) async throws -> MockSocketConnection {
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open && session.phase == .admitted })
        return try #require((connector ?? self.connector).latest)
    }

    func created(_ id: String, clientMessageId: String, seq: Int) -> String {
        Fixtures.RoomFrames.messageCreated(Fixtures.message(id, "Hello", by: Fixtures.ada, minute: 9, clientMessageId: clientMessageId), seq: seq)
    }

    // MARK: Phase

    @Test func thePhaseGoesFromConnectingToAdmittedAndReconnectingAfterADrop() async throws {
        connector.autoOpen = false
        let session = session(welcome: false)
        #expect(session.phase == .idle)
        session.start()
        #expect(await eventually { session.phase == .connecting })
        let socket = try #require(await eventually { connector.latest != nil } ? connector.latest : nil)
        socket.open()
        #expect(await eventually { session.status == .open })
        #expect(session.phase == .connecting)
        socket.serverSends(Fixtures.RoomFrames.welcome())
        #expect(await eventually { session.phase == .admitted })

        socket.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        session.stop()
        #expect(await eventually { session.phase == .idle })
    }

    @Test func aRoomYouLeftShowsStopped() async throws {
        connector.onConnect { $0.serverCloses(code: SocketClose.notFound) }
        let session = session(welcome: false)
        session.start()
        #expect(await eventually { session.phase == .stopped(.notFound) })
    }

    @Test func aRefusedRoomHeldByTwoLeasesConnectsAgainOnReconnect() async throws {
        connector.onConnect { $0.serverCloses(httpStatus: 403) }
        let session = session(welcome: false)
        let room = session.open()
        let other = session.open()
        #expect(await eventually { session.phase == .stopped(.refused(status: 403)) })
        let count = connector.connections.count

        // Taking a fresh lease while another is held doesn't connect: that's what reconnect is for.
        room.close()
        let again = session.open()
        await settle()
        #expect(connector.connections.count == count)

        connector.welcomeEverySocket()
        session.reconnect()
        #expect(await eventually { session.phase == .admitted })
        #expect(connector.connections.count == count + 1)
        again.close()
        other.close()
    }

    @Test func reconnectDoesNothingWhileConnectedOrWhenNothingHoldsTheRoom() async throws {
        let session = session()
        let socket = try await opened(session)
        let count = connector.connections.count
        session.reconnect()
        await settle()
        #expect(connector.connections.count == count)
        #expect(!socket.isClosedByClient)
        #expect(session.phase == .admitted)

        connector.onConnect { $0.serverCloses(httpStatus: 403) }
        socket.serverCloses(code: 1006)
        #expect(await clock.pass(timing.backoff(attempt: 0)))
        #expect(await eventually { session.phase == .stopped(.refused(status: 403)) })
        session.stop()
        let stopped = connector.connections.count
        connector.welcomeEverySocket()
        session.reconnect()
        await settle()
        #expect(connector.connections.count == stopped)
    }

    @Test func aThreadReconnectsItsRefusedRoom() async throws {
        connector.onConnect { $0.serverCloses(httpStatus: 403) }
        let session = session(welcome: false)
        let room = session.open()
        let thread = session.thread("m001")
        let lease = thread.open()
        #expect(await eventually { session.phase == .stopped(.refused(status: 403)) })
        connector.welcomeEverySocket()
        thread.reconnect()
        #expect(await eventually { session.phase == .admitted })
        lease.close()
        room.close()
    }

    // MARK: Unsent across a lease

    @Test func aMessageStillUnsentKeepsTheSocketOpenAfterTheLastLeaseCloses() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        session.stop()
        await settle()
        #expect(!socket.isClosedByClient)

        socket.serverSends(created("m009", clientMessageId: id, seq: 11))
        #expect(await eventually { socket.isClosedByClient })
        #expect(session.phase == .idle)
    }

    @Test func discardingTheLastUnsentMessageClosesASocketKeptForIt() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        session.stop()
        await settle()
        #expect(!socket.isClosedByClient)
        session.discard(id)
        #expect(await eventually { socket.isClosedByClient })
    }

    // MARK: Unsent across a launch

    @Test func anUnsentMessageIsSentAgainUnderItsOwnIdAfterARelaunch() async throws {
        let store = MemoryUnsentMessageStore()
        let first = session(store: store)
        _ = try await opened(first)
        let id = first.send(body: "<p>Hello</p>", plainText: "Hello")
        let key = UnsentMessageKey(server: URL(string: "https://ember.test")!, userID: Fixtures.ada.id, roomID: Fixtures.general.id)
        #expect(store.saved[key]?.map(\.clientMessageId) == [id])

        let relaunched = MockSocketConnector()
        let second = session(connector: relaunched, store: store)
        #expect(second.timeline.pending.isEmpty)
        let socket = try await opened(second, on: relaunched)
        #expect(second.timeline.pending.map(\.clientMessageId) == [id])
        #expect(await eventually { socket.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        #expect(socket.sent("message.create").isEmpty)

        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Hello</p>")] })
        socket.serverSends(created("m009", clientMessageId: id, seq: 11))
        #expect(await eventually { second.timeline.pending.isEmpty })
        #expect(second.timeline.messages.filter { $0.clientMessageId == id }.count == 1)
        #expect(store.saved[key] == nil)
    }

    @Test func aFailedMessageComesBackFailedAfterARelaunch() async throws {
        let store = MemoryUnsentMessageStore()
        let first = session(store: store)
        let socket = try await opened(first)
        let id = first.send(body: "<p>Hello</p>", plainText: "Hello")
        socket.serverSends(Fixtures.RoomFrames.error("That’s too long.", clientMessageId: id, failed: "message.create"))
        #expect(await eventually { first.timeline.pending.first?.failure != nil })

        let relaunched = MockSocketConnector()
        let second = session(connector: relaunched, store: store)
        let next = try await opened(second, on: relaunched)
        #expect(second.timeline.pending.first?.failure == "That’s too long.")
        await settle()
        #expect(next.sent("message.create").isEmpty)
    }

    // MARK: No answer

    @Test func aMessageUnansweredOnAnOpenConnectionFails() async throws {
        let session = session()
        let socket = try await opened(session)
        session.sendTimeout = .seconds(5)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await clock.pass(.seconds(5)))
        #expect(await eventually { session.timeline.pending.first?.failure == RoomSession.notSent })

        session.retry(id)
        #expect(session.timeline.pending.first?.failure == nil)
        #expect(await eventually { socket.sent("message.check").last == .checkMessages(clientMessageIds: [id]) })
        #expect(socket.sent("message.create").count == 1)
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { socket.sent("message.create").count == 2 })
        session.discard(id)
        #expect(session.timeline.pending.isEmpty)
    }

    /// Sends a message the room never answers, and waits until it shows as not sent.
    func notSent(_ session: RoomSession) async throws -> String {
        session.sendTimeout = .seconds(5)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        try #require(await clock.pass(.seconds(5)))
        try #require(await eventually { session.timeline.pending.first?.failure == RoomSession.notSent })
        return id
    }

    @Test func aMessageStoredWhoseAnswerWasLostIsStoredOnceWhenRetried() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = try await notSent(session)

        session.retry(id)
        #expect(await eventually { socket.sent("message.check").last == .checkMessages(clientMessageIds: [id]) })
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [id], missing: []))
        #expect(await eventually { session.timeline.pending.isEmpty })
        await settle()
        #expect(socket.sent("message.create").count == 1)
    }

    @Test func aRetriedMessageTheRoomTwiceSaysIsMissingIsCreatedOnce() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = try await notSent(session)

        session.retry(id)
        session.retry(id)
        #expect(await eventually { socket.sent("message.check").count >= 2 })
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { socket.sent("message.create").count == 2 })
        await settle()
        #expect(socket.sent("message.create").count == 2)
    }

    @Test func aMessageThatFailedAsNotSentIsAskedAboutAfterAReconnect() async throws {
        let session = session()
        let first = try await opened(session)
        let id = try await notSent(session)

        let count = connector.connections.count
        first.serverCloses(code: 1006)
        #expect(await clock.pass(timing.backoff(attempt: 0)))
        #expect(await eventually { connector.connections.count > count && session.phase == .admitted })
        let second = try #require(connector.latest)
        #expect(await eventually { second.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })

        second.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        await settle()
        #expect(session.timeline.pending.map(\.failure) == [RoomSession.notSent])
        #expect(second.sent("message.create").isEmpty)

        second.serverSends(Fixtures.RoomFrames.messageChecked(stored: [id], missing: []))
        #expect(await eventually { session.timeline.pending.isEmpty })
    }

    /// Drops `socket` and leaves the room reconnecting: the next socket is asked for and waits to be
    /// opened, with its welcome waiting.
    func reconnecting(_ session: RoomSession, from socket: MockSocketConnection) async throws {
        connector.autoOpen = false
        let count = connector.connections.count
        socket.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        try #require(await clock.pass(timing.backoff(attempt: 0)))
        try #require(await eventually { connector.connections.count > count })
        #expect(session.phase == .reconnecting)
    }

    /// Lets the latest socket in, as the room comes back.
    func comesBack(_ session: RoomSession) async throws -> MockSocketConnection {
        connector.autoOpen = true
        let socket = try #require(connector.latest)
        socket.open()
        try #require(await eventually { session.phase == .admitted })
        return try #require(connector.latest)
    }

    @Test func aMessageSentWhileReconnectingFailsInTimeAndIsntSentWhenTheRoomComesBack() async throws {
        let session = session()
        let first = try await opened(session)
        try await reconnecting(session, from: first)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")

        #expect(await clock.sleeping(dueWithin: session.sendTimeout))
        clock.advance(by: session.sendTimeout - .seconds(1))
        await settle()
        #expect(session.timeline.pending.map(\.failure) == [nil])
        #expect(await clock.pass(.seconds(1)))
        #expect(await eventually { session.timeline.pending.map(\.failure) == [RoomSession.notSent] })
        #expect(session.phase == .reconnecting)

        let back = try await comesBack(session)
        #expect(await eventually { back.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        back.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        await settle()
        #expect(back.sent("message.create").isEmpty)
        #expect(session.timeline.pending.map(\.failure) == [RoomSession.notSent])

        // Retry asks the room first, and the one copy goes once it says it's missing.
        session.retry(id)
        #expect(await eventually { back.sent("message.check").count == 2 })
        back.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { back.sent("message.create").count == 1 })
        await settle()
        #expect(back.sent("message.create").count == 1)
    }

    @Test func aMessageSentWhileReconnectingGoesWhenTheRoomComesBackInTime() async throws {
        let session = session()
        let first = try await opened(session)
        try await reconnecting(session, from: first)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await clock.sleeping(dueWithin: session.sendTimeout))
        clock.advance(by: .seconds(5))

        let back = try await comesBack(session)
        #expect(await eventually { back.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        back.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { back.sent("message.create").count == 1 })
        back.serverSends(created("m009", clientMessageId: id, seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        clock.advance(by: session.sendTimeout)
        await settle()
        #expect(session.timeline.messages.last?.id == "m009")
    }

    @Test func aMessageSentBeforeADropIsStillTimedFromWhenItWasSent() async throws {
        let session = session()
        let first = try await opened(session)
        _ = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await eventually { first.sent("message.create").count == 1 })
        // The send's timer and the socket's heartbeat.
        #expect(await clock.sleeping(2, dueWithin: session.sendTimeout))
        clock.advance(by: .seconds(10))
        try await reconnecting(session, from: first)
        #expect(await clock.pass(session.sendTimeout - .seconds(10)))
        #expect(await eventually { session.timeline.pending.map(\.failure) == [RoomSession.notSent] })
    }

    // MARK: Async changes

    /// The id of the `message.check` an async edit sent after its `message.update`.
    func editMarker(_ socket: MockSocketConnection) async throws -> String {
        try #require(await eventually { socket.sent("message.update").count == 1 && !socket.sent("message.check").isEmpty })
        guard case let .checkMessages(ids)? = socket.sent("message.check").last, let marker = ids.first else {
            throw EmberError(kind: .invalid, message: "No marker.")
        }
        return marker
    }

    @Test func anAsyncEditFinishesOnceTheRoomHasAnsweredWhatFollowsIt() async throws {
        let session = session()
        let socket = try await opened(session)
        let edit = Task { try await session.edit(message: "m001", body: "<p>Changed</p>") }
        let marker = try await editMarker(socket)
        var changed = Fixtures.messages(3)[0]
        changed.body = "<p>Changed</p>"
        socket.serverSends(Fixtures.RoomFrames.messageUpdated(changed, seq: 11))
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [marker]))
        try await edit.value
        #expect(session.timeline.message("m001")?.body == "<p>Changed</p>")
    }

    @Test func anAsyncEditTheRoomSanitisesFinishesWithTheBodyTheRoomStored() async throws {
        let session = session()
        let socket = try await opened(session)
        let edit = Task { try await session.edit(message: "m001", body: #"<p onclick="x()">Changed<script>x()</script></p>"#) }
        let marker = try await editMarker(socket)
        var changed = Fixtures.messages(3)[0]
        changed.body = "<p>Changed</p>"
        socket.serverSends(Fixtures.RoomFrames.messageUpdated(changed, seq: 11))
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [marker]))
        try await edit.value
        #expect(session.timeline.message("m001")?.body == "<p>Changed</p>")
        #expect(session.notice == nil)
    }

    @Test func anAsyncEditThatSanitisesToTheSameBodyFinishesThoughTheRoomSaysNothing() async throws {
        let session = session()
        let socket = try await opened(session)
        let edit = Task { try await session.edit(message: "m001", body: "<p>Message 1<script>x()</script></p>") }
        let marker = try await editMarker(socket)
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [marker]))
        try await edit.value
        #expect(session.timeline.message("m001")?.body == "<p>Message 1</p>")
    }

    @Test func anAsyncEditIsntFinishedByAnUpdateTheRoomSentBeforeIt() async throws {
        let session = session()
        let socket = try await opened(session)
        let edit = Task { try await session.edit(message: "m001", body: "<p>Changed</p>") }
        let marker = try await editMarker(socket)
        socket.serverSends(Fixtures.RoomFrames.messageUpdated(Fixtures.messages(3)[0], seq: 11))
        await settle()
        socket.serverSends(Fixtures.RoomFrames.error("You can only edit your own messages"))
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [marker]))
        await #expect(throws: EmberError(kind: .refused, message: "You can only edit your own messages")) { try await edit.value }
    }

    @Test func anAsyncEditToTheSameBodyFinishesAtOnce() async throws {
        let session = session()
        let socket = try await opened(session)
        try await session.edit(message: "m001", body: "<p>Message 1</p>")
        #expect(socket.sent("message.update").isEmpty)
    }

    @Test func anAsyncBoostThrowsTheRoomsRefusalInsteadOfANotice() async throws {
        let session = session()
        let socket = try await opened(session)
        let boost = Task { try await session.boost(message: "m002", content: "👍") }
        #expect(await eventually { socket.sent("boost.create").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.error("You can’t boost that."))
        await #expect(throws: EmberError(kind: .refused, message: "You can’t boost that.")) { try await boost.value }
        #expect(session.notice == nil)
    }

    @Test func anAsyncBoostAnswersTheBoostTheRoomShows() async throws {
        let session = session()
        let socket = try await opened(session)
        let boost = Task { try await session.boost(message: "m002", content: " 👍 ") }
        #expect(await eventually { socket.sent("boost.create") == [.createBoost(messageId: "m002", content: "👍")] })
        let made = Boost(id: "b1", messageId: "m002", booster: Fixtures.ada, content: "👍", createdAt: Date(timeIntervalSince1970: 0))
        socket.serverSends(frame(["type": "boost.created", "boost": made, "seq": 11]))
        #expect(try await boost.value == made)

        let removal = Task { try await session.removeBoost(id: "b1") }
        #expect(await eventually { socket.sent("boost.delete").count == 1 })
        socket.serverSends(frame(["type": "boost.deleted", "boostId": "b1", "messageId": "m002", "seq": 12]))
        try await removal.value
    }

    @Test func aBoostThatDoesntFitIsRefusedBeforeSending() async throws {
        let session = session()
        let socket = try await opened(session)
        await #expect(throws: EmberError.self) { try await session.boost(message: "m002", content: String(repeating: "a", count: 40)) }
        #expect(socket.sent("boost.create").isEmpty)
    }

    @Test func anAsyncDeleteUnansweredTimesOut() async throws {
        let session = session()
        let socket = try await opened(session)
        let deletion = Task { try await session.delete(message: "m002") }
        #expect(await eventually { socket.sent("message.delete").count == 1 })
        try #require(await clock.pass(RoomSession.changeTimeout))
        await #expect(throws: EmberError(kind: .timedOut, message: RoomSession.changeTimedOut)) { try await deletion.value }
    }

    @Test func anAsyncBoostAskedForWhileReconnectingGoesWhenTheRoomComesBack() async throws {
        let session = session()
        let first = try await opened(session)
        try await reconnecting(session, from: first)
        let boost = Task { try await session.boost(message: "m002", content: "👍") }
        #expect(await clock.sleeping(dueWithin: RoomSession.changeTimeout))
        clock.advance(by: .seconds(5))

        let back = try await comesBack(session)
        #expect(await eventually { back.sent("boost.create") == [.createBoost(messageId: "m002", content: "👍")] })
        let made = Boost(id: "b1", messageId: "m002", booster: Fixtures.ada, content: "👍", createdAt: Date(timeIntervalSince1970: 0))
        back.serverSends(frame(["type": "boost.created", "boost": made, "seq": 11]))
        #expect(try await boost.value == made)
    }

    @Test func anAsyncDeleteAskedForWhileReconnectingTimesOutAndIsNeverSent() async throws {
        let session = session()
        let first = try await opened(session)
        try await reconnecting(session, from: first)
        let deletion = Task { try await session.delete(message: "m002") }
        try #require(await clock.pass(RoomSession.changeTimeout))
        await #expect(throws: EmberError(kind: .timedOut, message: RoomSession.changeTimedOut)) { try await deletion.value }

        let back = try await comesBack(session)
        await settle()
        #expect(back.sent("message.delete").isEmpty)
        #expect(first.sent("message.delete").isEmpty)
    }

    @Test func anAsyncEditAskedForWhileReconnectingGoesWithItsMarkerWhenTheRoomComesBack() async throws {
        let session = session()
        let first = try await opened(session)
        try await reconnecting(session, from: first)
        let edit = Task { try await session.edit(message: "m001", body: "<p>Changed</p>") }
        #expect(await clock.sleeping(dueWithin: RoomSession.changeTimeout))
        clock.advance(by: .seconds(5))
        let back = try await comesBack(session)
        let marker = try await editMarker(back)
        back.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [marker]))
        try await edit.value
    }

    @Test func anAsyncDeleteSentBeforeADropIsUnreachable() async throws {
        let session = session()
        let first = try await opened(session)
        let deletion = Task { try await session.delete(message: "m002") }
        #expect(await eventually { first.sent("message.delete").count == 1 })
        first.serverCloses(code: 1006)
        await #expect(throws: EmberError(kind: .unreachable, message: RoomSession.notConnected)) { try await deletion.value }
    }

    @Test func anAsyncDeleteWithTheRoomNotConnectingIsUnreachableAtOnce() async throws {
        let session = session()
        await #expect(throws: EmberError(kind: .unreachable, message: RoomSession.notConnected)) { try await session.delete(message: "m002") }
    }

    @Test func anAsyncDeleteFinishesOnTheDeletion() async throws {
        let session = session()
        let socket = try await opened(session)
        let deletion = Task { try await session.delete(message: "m002") }
        #expect(await eventually { socket.sent("message.delete").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.messageDeleted("m002", seq: 11))
        try await deletion.value
    }

    @Test func anAsyncChangeThrowsUnreachableWhenTheSocketDrops() async throws {
        let session = session()
        let socket = try await opened(session)
        let edit = Task { try await session.edit(message: "m001", body: "<p>Changed</p>") }
        #expect(await eventually { socket.sent("message.update").count == 1 })
        socket.serverCloses(code: 1006)
        do {
            try await edit.value
            Issue.record("It finished.")
        } catch let error as EmberError {
            #expect(error.isUnreachable)
        }
    }

    // MARK: Plain text

    @Test func plainTextIsEscapedAndItsLineEndingsMadeOne() async throws {
        let session = session()
        let socket = try await opened(session)
        let id = try session.send(text: "<b>Hi</b> & bye\r\nthere\n\n")
        let body = RichText.body(fromPlainText: "<b>Hi</b> & bye\nthere")
        #expect(!body.contains("<b>"))
        #expect(session.timeline.pending.first?.plainText == "<b>Hi</b> & bye\nthere")
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: body)] })
    }

    @Test func plainTextOverTheLimitIsRefusedBeforeSending() async throws {
        let session = session()
        _ = try await opened(session)
        #expect(throws: EmberError(kind: .invalid, message: "Messages can be up to 10,000 characters.")) {
            try session.send(text: String(repeating: "a", count: Limits.message + 1))
        }
        #expect(throws: EmberError.self) { try session.send(text: " \n ") }
        #expect(throws: EmberError.self) { try session.send(files: [], text: String(repeating: "a", count: Limits.message + 1)) }
        #expect(session.timeline.pending.isEmpty)
        #expect(try session.send(text: String(repeating: "a", count: Limits.message)).isEmpty == false)
    }

    @Test func aCaptionAndAReplyInPlainTextAreEscaped() async throws {
        let session = session()
        let socket = try await opened(session)
        let ids = try session.send(files: [], text: "1 < 2")
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: ids[0], body: RichText.body(fromPlainText: "1 < 2"))] })

        let thread = session.thread("m001")
        let reply = try thread.reply(text: "a & b")
        #expect(await eventually {
            socket.sent("message.create").contains {
                if case let .createMessage(id, body, parentId, _) = $0 {
                    id == reply && body == RichText.body(fromPlainText: "a & b") && parentId == "m001"
                } else {
                    false
                }
            }
        })
    }

    /// A room frame as JSON, with `Encodable` values written as the server writes them.
    func frame(_ fields: [String: Any]) -> String {
        var object: [String: Any] = [:]
        for (key, value) in fields {
            if let value = value as? any Encodable, !(value is String), !(value is Int) {
                let data = try? EmberJSON.encoder().encode(value)
                object[key] = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            } else {
                object[key] = value
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
