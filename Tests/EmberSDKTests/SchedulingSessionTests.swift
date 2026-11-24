import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Messages you schedule and messages only you see, on a room's socket.
@MainActor @Suite struct SchedulingSessionTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock
    /// Nine in the morning, when `Fixtures.scheduled` sends.
    let nine: Date
    let unreachable = EmberError(kind: .unreachable, message: RoomSession.notConnected)

    init() throws {
        (timing, clock) = manualTiming()
        nine = try #require(EmberJSON.date(from: "2026-11-24T09:00:00.000Z"))
    }

    func session() -> RoomSession {
        RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
    }

    /// A session whose every socket is welcomed with these, opened and admitted.
    func opened(scheduled: [ScheduledMessage] = [], ephemeral: [EphemeralMessage] = []) async throws -> (RoomSession, MockSocketConnection) {
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(ephemeral: ephemeral, scheduled: scheduled)) }
        let session = session()
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open && session.isAdmitted })
        return (session, try #require(connector.latest))
    }

    /// Drops `socket` and waits for the next connection to be let in, by whatever `onConnect` sends.
    /// `attempt` counts the drops before this one: none was open long enough to start the backoff again.
    func reconnect(_ session: RoomSession, from socket: MockSocketConnection, attempt: Int = 0) async throws -> MockSocketConnection {
        let count = connector.connections.count
        socket.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting })
        try #require(await clock.pass(timing.backoff(attempt: attempt)))
        try #require(await eventually { connector.connections.count == count + 1 && session.status == .open })
        let next = try #require(connector.latest)
        try #require(await eventually { session.isAdmitted })
        return next
    }

    /// The id the client gave the `message.schedule` it sent on `socket`, once it has.
    func scheduledID(on socket: MockSocketConnection, count: Int = 1) async throws -> ClientMessageID {
        try #require(await eventually { socket.sent("message.schedule").count == count })
        let frame = try #require(socket.sentFrames.last { $0.type == "message.schedule" })
        return ClientMessageID(try #require(frame.string("clientMessageId")))
    }

    // MARK: Scheduling

    @Test func aScheduledMessageFinishesOnceTheRoomListsIt() async throws {
        let (session, socket) = try await opened()
        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        let id = try await scheduledID(on: socket)
        #expect(socket.sent("message.schedule") == [.scheduleMessage(clientMessageId: id, body: "<p>Standup</p>", sendAt: nine)])
        let frame = try #require(socket.sentFrames.first { $0.type == "message.schedule" })
        #expect(frame.string("sendAt") == "2026-11-24T09:00:00.000Z")
        #expect(frame["parentId"] == nil && frame["alsoSend"] == nil)

        // A list without it, as one another of your devices changed, isn't its answer.
        let earlier = Fixtures.scheduled("s0", "Earlier", minute: -5)
        socket.serverSends(Fixtures.RoomFrames.scheduled([earlier]))
        #expect(await eventually { session.timeline.scheduled == [earlier] })
        #expect(session.changes.count == 1)

        let standup = Fixtures.scheduled("s1", "Standup", clientMessageId: id)
        socket.serverSends(Fixtures.RoomFrames.scheduled([earlier, standup]))
        #expect(try await scheduling.value == id)
        #expect(session.timeline.scheduled == [earlier, standup])
        #expect(session.timeline.scheduledForRoom == [earlier, standup])
        // It's no message of the room's yet, nor one on its way.
        #expect(session.timeline.messages.count == 3 && session.timeline.pending.isEmpty)
        #expect(session.notice == nil)
    }

    @Test func aRefusedScheduleIsThrownAndIsntANotice() async throws {
        let (session, socket) = try await opened()
        let first = Task { try await session.schedule(body: "<p>One</p>", at: nine) }
        let firstID = try await scheduledID(on: socket)
        let second = Task { try await session.schedule(body: "<p>Two</p>", at: nine.addingTimeInterval(60)) }
        let secondID = try await scheduledID(on: socket, count: 2)
        #expect(firstID != secondID)

        // The refusal names the message, so it's the second's alone though the first is older.
        let full = "You can schedule up to 30 messages in a room."
        socket.serverSends(Fixtures.RoomFrames.error(full, clientMessageId: secondID))
        await #expect(throws: EmberError(kind: .refused, message: full)) { try await second.value }
        #expect(session.changes.count == 1)
        #expect(session.notice == nil)

        socket.serverSends(Fixtures.RoomFrames.scheduled([Fixtures.scheduled("s1", "One", clientMessageId: firstID)]))
        #expect(try await first.value == firstID)
        #expect(session.timeline.scheduled.map(\.id) == ["s1"])
        #expect(session.timeline.pending.isEmpty)
        #expect(session.notice == nil)
    }

    @Test func aBodyTooLongIsntSent() async throws {
        let (session, socket) = try await opened(scheduled: [Fixtures.scheduled("s1", "Standup")])
        let long = String(repeating: "a", count: Limits.message + 1)
        let invalid = EmberError(kind: .invalid, message: "Messages can be up to 40,000 characters.")
        await #expect(throws: invalid) { try await session.schedule(body: long, at: nine) }
        await #expect(throws: invalid) { try await session.edit(scheduled: "s1", body: long) }
        await #expect(throws: invalid) { try await session.thread("m001").schedule(body: long, at: nine) }
        await settle()
        #expect(socket.sent("message.schedule").isEmpty && socket.sent("scheduled.edit").isEmpty)
        #expect(session.notice == nil)
    }

    @Test func withNoSocketNothingIsScheduledOrChanged() async {
        let session = session()
        await #expect(throws: unreachable) { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        await #expect(throws: unreachable) { try await session.edit(scheduled: "s1", body: "<p>Standup</p>") }
        #expect(throws: unreachable) { try session.reschedule(scheduled: "s1", to: nine) }
        #expect(throws: unreachable) { try session.sendNow(scheduled: "s1") }
        #expect(throws: unreachable) { try session.delete(scheduled: "s1") }
        #expect(session.notice == nil)
        #expect(connector.connections.isEmpty)
    }

    @Test func oneAskedForWhileConnectingGoesOnceTheRoomLetsTheSocketIn() async throws {
        connector.onConnect { _ in }
        let session = session()
        session.start()
        #expect(await eventually { session.status == .open })
        let socket = try #require(connector.latest)

        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        let edit = Task { try await session.edit(scheduled: "s0", body: "<p>Earlier still</p>") }
        await settle()
        #expect(socket.sent.isEmpty)
        // What the room answers with a list, or not at all, isn't kept for later.
        #expect(throws: unreachable) { try session.reschedule(scheduled: "s0", to: nine) }
        #expect(throws: unreachable) { try session.sendNow(scheduled: "s0") }
        #expect(throws: unreachable) { try session.delete(scheduled: "s0") }

        let earlier = Fixtures.scheduled("s0", "Earlier", minute: -5)
        socket.serverSends(Fixtures.RoomFrames.welcome(scheduled: [earlier]))
        let id = try await scheduledID(on: socket)
        #expect(await eventually { socket.sent("scheduled.edit") == [.editScheduled(scheduledId: "s0", body: "<p>Earlier still</p>")] })
        socket.serverSends(Fixtures.RoomFrames.scheduled([earlier, Fixtures.scheduled("s1", "Standup", clientMessageId: id)]))
        #expect(try await scheduling.value == id)
        socket.serverSends(Fixtures.RoomFrames.scheduled([Fixtures.scheduled("s0", "Earlier still", minute: -5)], edited: "s0"))
        try await edit.value
        #expect(session.timeline.scheduled.map(\.body) == ["<p>Earlier still</p>"])
    }

    @Test func oneWhoseAnswerADroppedSocketLostGoesAgain() async throws {
        let (session, socket) = try await opened()
        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        let id = try await scheduledID(on: socket)

        let next = try await reconnect(session, from: socket)
        #expect(await eventually { next.sent("message.schedule").count == 1 })
        // Under the same id, so the room keeps it once.
        #expect(next.sent("message.schedule") == [.scheduleMessage(clientMessageId: id, body: "<p>Standup</p>", sendAt: nine)])
        next.serverSends(Fixtures.RoomFrames.scheduled([Fixtures.scheduled("s1", "Standup", clientMessageId: id)]))
        #expect(try await scheduling.value == id)
        #expect(session.timeline.scheduled.map(\.id) == ["s1"])
    }

    @Test func oneTheRoomAlreadyHoldsOnComingBackIsDone() async throws {
        let (session, socket) = try await opened()
        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        let id = try await scheduledID(on: socket)
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(scheduled: [Fixtures.scheduled("s1", "Standup", clientMessageId: id)])) }
        _ = try await reconnect(session, from: socket)
        #expect(try await scheduling.value == id)
        #expect(session.timeline.scheduled.map(\.id) == ["s1"])
        #expect(session.changes.isEmpty)
    }

    @Test func oneSentWhileTheSocketWasAwayIsDone() async throws {
        let (session, socket) = try await opened()
        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        let id = try await scheduledID(on: socket)
        // Its time came: the room lists it no longer, and it's among the messages.
        let sent = Fixtures.message("m004", "Standup", by: Fixtures.ada, minute: 4, clientMessageId: id)
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(messages: Fixtures.messages(3) + [sent], seq: 11)) }
        _ = try await reconnect(session, from: socket)
        #expect(try await scheduling.value == id)
        #expect(session.timeline.scheduled.isEmpty)
        #expect(session.timeline.messages.last?.id == "m004")
        #expect(session.changes.isEmpty)
    }

    @Test func oneUnansweredTimesOut() async throws {
        let (session, socket) = try await opened()
        let scheduling = Task { try await session.schedule(body: "<p>Standup</p>", at: nine) }
        _ = try await scheduledID(on: socket)
        try #require(await clock.pass(RoomSession.changeTimeout))
        await #expect(throws: EmberError(kind: .timedOut, message: RoomSession.changeTimedOut)) { try await scheduling.value }
        #expect(session.notice == nil)
    }

    // MARK: What's scheduled

    @Test func welcomeAndResumedListWhatsScheduled() async throws {
        let standup = Fixtures.scheduled("s1", "Standup")
        let reply = Fixtures.scheduled("s2", "On it", minute: 5, parentId: "m001")
        let (session, socket) = try await opened(scheduled: [standup, reply])
        #expect(session.timeline.scheduled == [standup, reply])
        #expect(session.timeline.scheduledForRoom == [standup])
        #expect(session.thread("m001").scheduled == [reply])
        #expect(session.thread("m002").scheduled.isEmpty)

        // One was sent while the socket was away; the room says what's left.
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.resumed(seq: 10, scheduled: [reply])) }
        let next = try await reconnect(session, from: socket)
        #expect(session.timeline.scheduled == [reply])

        // And none, by leaving the list out.
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.resumed(seq: 10)) }
        _ = try await reconnect(session, from: next, attempt: 1)
        #expect(session.timeline.scheduled.isEmpty)
        #expect(session.thread("m001").scheduled.isEmpty)
    }

    @Test func aReplyWhoseThreadIsGoneIsListedWithTheRooms() async throws {
        let orphan = Fixtures.scheduled("s2", "On it", parentId: "m001", failure: ScheduledMessage.threadDeleted)
        let (session, _) = try await opened(scheduled: [orphan])
        #expect(session.timeline.scheduledForRoom == [orphan])
        #expect(session.thread("m001").scheduled == [orphan])
    }

    // MARK: Editing

    @Test func anEditFinishesOnTheListThatNamesIt() async throws {
        let standup = Fixtures.scheduled("s1", "Standup")
        let retro = Fixtures.scheduled("s2", "Retro", minute: 30)
        let (session, socket) = try await opened(scheduled: [standup])
        let edit = Task { try await session.edit(scheduled: "s1", body: "<p>Standup at ten</p>") }
        #expect(await eventually { socket.sent("scheduled.edit").count == 1 })
        #expect(socket.sent("scheduled.edit") == [.editScheduled(scheduledId: "s1", body: "<p>Standup at ten</p>")])

        // A list for something else, or naming another's edit, isn't its answer.
        socket.serverSends(Fixtures.RoomFrames.scheduled([standup, retro]))
        socket.serverSends(Fixtures.RoomFrames.scheduled([standup, retro], edited: "s2"))
        #expect(await eventually { session.timeline.scheduled == [standup, retro] })
        await settle()
        #expect(session.changes.count == 1)

        let changed = Fixtures.scheduled("s1", "Standup at ten")
        socket.serverSends(Fixtures.RoomFrames.scheduled([changed, retro], edited: "s1"))
        try await edit.value
        #expect(session.timeline.scheduled == [changed, retro])
        #expect(session.notice == nil)
    }

    @Test func aRefusedEditIsThrownAndIsntANotice() async throws {
        let (session, socket) = try await opened(scheduled: [Fixtures.scheduled("s1", "Standup"), Fixtures.scheduled("s2", "Retro", minute: 30)])
        let edit = Task { try await session.edit(scheduled: "s1", body: "<p>Standup at ten</p>") }
        #expect(await eventually { socket.sent("scheduled.edit").count == 1 })

        // One for another message's edit, as from another of your devices, is neither thrown nor shown.
        socket.serverSends(Fixtures.RoomFrames.error("That message isn’t scheduled any more.", scheduledId: "s2", failed: "scheduled.edit"))
        await settle()
        #expect(session.changes.count == 1)
        #expect(session.notice == nil)

        let gone = "That message isn’t scheduled any more."
        socket.serverSends(Fixtures.RoomFrames.error(gone, scheduledId: "s1", failed: "scheduled.edit"))
        await #expect(throws: EmberError(kind: .refused, message: gone)) { try await edit.value }
        #expect(session.notice == nil)
        #expect(session.timeline.scheduled.map(\.body) == ["<p>Standup</p>", "<p>Retro</p>"])
    }

    @Test func anotherRefusalWhileAnEditWaitsIsTheRoomsNotice() async throws {
        let (session, socket) = try await opened(scheduled: [Fixtures.scheduled("s1", "Standup")])
        let edit = Task { try await session.edit(scheduled: "s1", body: "<p>Standup at ten</p>") }
        #expect(await eventually { socket.sent("scheduled.edit").count == 1 })
        try session.reschedule(scheduled: "s1", to: nine.addingTimeInterval(-86_400 * 30))
        socket.serverSends(Fixtures.RoomFrames.error("Choose a time to come."))
        #expect(await eventually { session.notice == "Choose a time to come." })
        #expect(session.changes.count == 1)
        socket.serverSends(Fixtures.RoomFrames.scheduled([Fixtures.scheduled("s1", "Standup at ten")], edited: "s1"))
        try await edit.value
    }

    // MARK: Moving, sending and deleting

    @Test func movingSendingAndDeletingGoAtOnce() async throws {
        let standup = Fixtures.scheduled("s1", "Standup")
        let retro = Fixtures.scheduled("s2", "Retro", minute: 30)
        let (session, socket) = try await opened(scheduled: [standup, retro])
        let ten = nine.addingTimeInterval(3_600)
        try session.reschedule(scheduled: "s1", to: ten)
        try session.sendNow(scheduled: "s2")
        try session.delete(scheduled: "s1")
        #expect(await eventually { socket.sent("scheduled.delete").count == 1 })
        #expect(socket.sentClientFrames.filter { $0.type.hasPrefix("scheduled.") } == [
            .reschedule(scheduledId: "s1", sendAt: ten),
            .sendScheduled(scheduledId: "s2"),
            .deleteScheduled(scheduledId: "s1"),
        ])
        #expect(socket.sentFrames.first { $0.type == "scheduled.reschedule" }?.string("sendAt") == "2026-11-24T10:00:00.000Z")
        // Nothing waits on them: each answer is a list that takes the last's place.
        #expect(session.changes.isEmpty)

        let moved = Fixtures.scheduled("s1", "Standup", minute: 60)
        socket.serverSends(Fixtures.RoomFrames.scheduled([retro, moved]))
        #expect(await eventually { session.timeline.scheduled == [retro, moved] })
        // Sent now, it arrives as a message with its own id and leaves the list.
        let sent = Fixtures.message("m004", "Retro", by: Fixtures.ada, minute: 4, clientMessageId: retro.clientMessageId)
        socket.serverSends(Fixtures.RoomFrames.messageCreated(sent, seq: 11))
        socket.serverSends(Fixtures.RoomFrames.scheduled([moved]))
        #expect(await eventually { session.timeline.scheduled == [moved] && session.timeline.messages.last == sent })
        #expect(session.timeline.pending.isEmpty)
        socket.serverSends(Fixtures.RoomFrames.scheduled([]))
        #expect(await eventually { session.timeline.scheduled.isEmpty })
        #expect(session.notice == nil)
    }

    @Test func oneThatCouldntBeSentStaysWithWhy() async throws {
        let reply = Fixtures.scheduled("s1", "On it", parentId: "m001")
        let (session, socket) = try await opened(scheduled: [reply])
        try session.sendNow(scheduled: "s1")
        #expect(await eventually { socket.sent("scheduled.send") == [.sendScheduled(scheduledId: "s1")] })
        let failed = Fixtures.scheduled("s1", "On it", parentId: "m001", failure: ScheduledMessage.threadDeleted)
        socket.serverSends(Fixtures.RoomFrames.scheduled([failed]))
        socket.serverSends(Fixtures.RoomFrames.error(ScheduledMessage.threadDeleted))
        #expect(await eventually { session.timeline.scheduled == [failed] && session.notice == ScheduledMessage.threadDeleted })
        #expect(session.timeline.scheduledForRoom == [failed])
    }

    // MARK: Threads

    @Test func aReplyIsScheduledIntoItsThread() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let only = Task { try await thread.schedule(body: "<p>On it</p>", at: nine) }
        let onlyID = try await scheduledID(on: socket)
        let both = Task { try await thread.schedule(body: "<p>Done</p>", at: nine.addingTimeInterval(300), delivery: .threadAndRoom) }
        let bothID = try await scheduledID(on: socket, count: 2)
        #expect(socket.sent("message.schedule") == [
            .scheduleMessage(clientMessageId: onlyID, body: "<p>On it</p>", sendAt: nine, parentId: "m001", alsoSend: false),
            .scheduleMessage(clientMessageId: bothID, body: "<p>Done</p>", sendAt: nine.addingTimeInterval(300), parentId: "m001", alsoSend: true),
        ])

        let first = Fixtures.scheduled("s1", "On it", clientMessageId: onlyID, parentId: "m001")
        let second = Fixtures.scheduled("s2", "Done", minute: 5, clientMessageId: bothID, parentId: "m001", alsoSend: true)
        socket.serverSends(Fixtures.RoomFrames.scheduled([first]))
        #expect(try await only.value == onlyID)
        socket.serverSends(Fixtures.RoomFrames.scheduled([first, second]))
        #expect(try await both.value == bothID)
        #expect(thread.scheduled == [first, second])
        #expect(session.timeline.scheduledForRoom.isEmpty)
        #expect(session.thread("m002").scheduled.isEmpty)

        // The room's own calls change a thread's.
        try session.delete(scheduled: "s1")
        #expect(await eventually { socket.sent("scheduled.delete") == [.deleteScheduled(scheduledId: "s1")] })
        socket.serverSends(Fixtures.RoomFrames.scheduled([second]))
        #expect(await eventually { thread.scheduled == [second] })
    }

    // MARK: Messages only you see

    @Test func messagesOnlyYouSeeArriveApartFromTheRooms() async throws {
        let asked = Fixtures.ephemeral("e1")
        let (session, socket) = try await opened(ephemeral: [asked])
        #expect(session.timeline.ephemeral == [asked])
        #expect(session.timeline.ephemeral.first?.cards == [Fixtures.approvalCard])
        #expect(session.timeline.messages.map(\.id) == ["m001", "m002", "m003"])
        #expect(session.timeline.message("e1") == nil)

        let another = Fixtures.ephemeral("e2", plainText: "Send the invoice?", minute: 1)
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(another))
        #expect(await eventually { session.timeline.ephemeral == [asked, another] })
        // One for a thread isn't the room's.
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(Fixtures.ephemeral("e3", minute: 2, parentId: "m001")))
        await settle()
        #expect(session.timeline.ephemeral.map(\.id) == ["e1", "e2"])
        #expect(session.timeline.seq == 10)
        #expect(session.notice == nil)
    }

    @Test func aClickOnOneGoesAsAnyCardsAndWhatCameOfItTakesItsPlace() async throws {
        let (session, socket) = try await opened(ephemeral: [Fixtures.ephemeral("e1")])
        let click = Task { try await session.click(Fixtures.approveAction, on: "e1") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        #expect(socket.sentClicks[0].string("messageId") == "e1")
        #expect(socket.sentClicks[0].string("actionId") == "approve")
        socket.answerClick()
        try await click.value

        let done = Fixtures.ephemeral("e1", cards: [], plainText: "Deployed web 2.4.1.")
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(done))
        #expect(await eventually { session.timeline.ephemeral == [done] })
        #expect(session.notice == nil)
    }

    @Test func comingBackTakesThoseStillWaiting() async throws {
        let first = Fixtures.ephemeral("e1")
        let second = Fixtures.ephemeral("e2", minute: 1)
        let (session, socket) = try await opened(ephemeral: [first, second])
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.resumed(seq: 10, ephemeral: [second])) }
        let next = try await reconnect(session, from: socket)
        #expect(session.timeline.ephemeral == [second])
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome()) }
        _ = try await reconnect(session, from: next, attempt: 1)
        #expect(session.timeline.ephemeral.isEmpty)
    }

    @Test func aThreadsOwnArriveWithItAndAfter() async throws {
        let (session, socket) = try await opened()
        let parent = Fixtures.withThread(Fixtures.message("m001", "Message 1", minute: 1), count: 1)
        let thread = session.thread("m001")
        let lease = thread.open()
        #expect(await eventually { socket.sent("thread.open").count == 1 })
        let asked = Fixtures.ephemeral("e1", parentId: "m001")
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent, ephemeral: [asked]))
        #expect(await eventually { thread.timeline.isLoaded })
        #expect(thread.timeline.ephemeral == [asked])
        #expect(thread.timeline.replies.isEmpty)

        let another = Fixtures.ephemeral("e2", minute: 1, parentId: "m001")
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(another))
        // The room's, and another thread's, aren't this thread's.
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(Fixtures.ephemeral("e3", minute: 2)))
        socket.serverSends(Fixtures.RoomFrames.messageEphemeral(Fixtures.ephemeral("e4", minute: 3, parentId: "m002")))
        #expect(await eventually { thread.timeline.ephemeral == [asked, another] && session.timeline.ephemeral.map(\.id) == ["e3"] })

        let click = Task { try await thread.click(Fixtures.holdAction, on: "e2") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        #expect(socket.sentClicks[0].string("messageId") == "e2")
        socket.answerClick()
        try await click.value
        lease.close()
    }
}
