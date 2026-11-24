import EmberSDK
import Foundation
import Testing

/// Messages scheduled for later, and the cards only you see. The scheduling tests keep to a room of
/// their own and delete it; the cards are Deploy Bot's, in Engineering, and each is answered.
extension LiveTests {
    /// A time to come, to the second, as the room keeps one to the millisecond.
    func time(inHours hours: Double) -> Date {
        Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + hours * 3600).rounded())
    }

    /// A room of the test's own, opened and loaded.
    @MainActor
    func opened(_ room: RoomID, on client: EmberClient) async throws -> RoomSession {
        let session = RoomSession(client: client, roomID: room)
        session.start()
        guard await eventually({ session.timeline.isLoaded && session.status == .open }) else {
            session.stop()
            Issue.record("The room didn't open.")
            throw CancellationError()
        }
        return session
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func schedulesEditsMovesSendsNowAndDeletes() async throws {
        let client = try await signedIn()
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName()))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            let session = try await opened(room.id, on: client)
            defer { session.stop() }
            #expect(session.timeline.scheduled.isEmpty)

            let later = time(inHours: 48)
            let first = try await session.schedule(body: "<p>Later</p>", at: later)
            let listed = try #require(session.timeline.scheduled.first)
            #expect(session.timeline.scheduled.count == 1)
            #expect(listed.clientMessageId == first)
            #expect(listed.body == "<p>Later</p>")
            #expect(listed.sendAt == later)
            #expect(listed.parentId == nil)
            #expect(listed.failure == nil)
            #expect(!session.timeline.messages.contains { $0.clientMessageId == first })

            // Soonest first.
            let second = try await session.schedule(body: "<p>Sooner</p>", at: time(inHours: 24))
            #expect(session.timeline.scheduled.map(\.clientMessageId) == [second, first])

            // Too far ahead is refused to whoever asked, and isn't the room's notice.
            await #expect(throws: EmberError(kind: .refused, message: "Pick a time between now and 120 days from now.")) {
                try await session.schedule(body: "<p>Never</p>", at: Date.now.addingTimeInterval(Limits.scheduleAhead + 86400))
            }
            #expect(session.notice == nil)
            #expect(session.timeline.scheduled.count == 2)

            try await session.edit(scheduled: listed.id, body: "<p>Later, edited</p>")
            #expect(session.timeline.scheduled.first { $0.id == listed.id }?.body == "<p>Later, edited</p>")
            #expect(session.timeline.scheduled.first { $0.id == listed.id }?.sendAt == later)
            await #expect(throws: EmberError(kind: .refused, message: "Your message is empty.")) {
                try await session.edit(scheduled: listed.id, body: "")
            }
            #expect(session.notice == nil)
            #expect(session.timeline.scheduled.first { $0.id == listed.id }?.body == "<p>Later, edited</p>")

            // Moved ahead of the other.
            let soonest = time(inHours: 12)
            try session.reschedule(scheduled: listed.id, to: soonest)
            #expect(await eventually { session.timeline.scheduled.map(\.clientMessageId) == [first, second] })
            #expect(session.timeline.scheduled.first?.sendAt == soonest)
            // A move that's refused is the room's notice, and moves nothing.
            try session.reschedule(scheduled: listed.id, to: Date.now.addingTimeInterval(-3600))
            #expect(await eventually { session.notice == "Pick a time between now and 120 days from now." })
            session.notice = nil
            #expect(session.timeline.scheduled.first?.sendAt == soonest)

            // Another socket of yours lists them from its welcome. Nobody else's does.
            let other = try await opened(room.id, on: client)
            defer { other.stop() }
            #expect(other.timeline.scheduled.map(\.clientMessageId) == [first, second])
            let sam = try await opened(room.id, on: try await signedIn(as: "sam@example.com"))
            defer { sam.stop() }
            #expect(sam.timeline.scheduled.isEmpty)

            // Sent now, it's a message under the id it was scheduled with, and everyone's to read.
            let sooner = try #require(session.timeline.scheduled.first { $0.clientMessageId == second })
            try session.sendNow(scheduled: sooner.id)
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == second } })
            #expect(session.timeline.messages.first { $0.clientMessageId == second }?.body == "<p>Sooner</p>")
            #expect(session.timeline.messages.filter { $0.body == "<p>Sooner</p>" }.count == 1)
            #expect(await eventually {
                session.timeline.scheduled.map(\.clientMessageId) == [first] && other.timeline.scheduled.map(\.clientMessageId) == [first]
            })
            #expect(await eventually { sam.timeline.messages.contains { $0.body == "<p>Sooner</p>" } })

            try session.delete(scheduled: listed.id)
            #expect(await eventually { session.timeline.scheduled.isEmpty && other.timeline.scheduled.isEmpty })
            #expect(!session.timeline.messages.contains { $0.clientMessageId == first })
            // Gone, there's nothing left to send.
            try session.sendNow(scheduled: listed.id)
            #expect(await eventually { session.notice == "That message isn't scheduled any more." })
            session.notice = nil

            // One whose time comes is sent by the room.
            let due = try await session.schedule(body: "<p>Due</p>", at: Date.now.addingTimeInterval(1))
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == due } })
            #expect(await eventually { session.timeline.scheduled.isEmpty })
            #expect(await eventually { sam.timeline.messages.contains { $0.body == "<p>Due</p>" } })
            #expect(session.notice == nil)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aScheduledReplyWaitsInItsThreadAndStaysWhenItsMessageIsGone() async throws {
        let client = try await signedIn()
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName()))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            let session = try await opened(room.id, on: client)
            defer { session.stop() }
            let sent = session.send(body: "<p>A thread</p>", plainText: "A thread")
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == sent } })
            let parent = try #require(session.timeline.messages.first { $0.clientMessageId == sent })
            let thread = session.thread(parent.id)
            let lease = thread.open()
            defer { lease.close() }
            #expect(await eventually { thread.timeline.isLoaded })

            let at = time(inHours: 24)
            let loud = try await thread.schedule(body: "<p>Reply, later</p>", at: at, delivery: .threadAndRoom)
            let quiet = try await thread.schedule(body: "<p>Reply, quietly</p>", at: time(inHours: 25))
            #expect(thread.scheduled.map(\.clientMessageId) == [loud, quiet])
            #expect(thread.scheduled.map(\.alsoSend) == [true, false])
            #expect(thread.scheduled.allSatisfy { $0.parentId == parent.id && $0.failure == nil })
            #expect(thread.scheduled.first?.sendAt == at)
            // The room's own list has neither; the room's whole list has both.
            #expect(session.timeline.scheduledForRoom.isEmpty)
            #expect(session.timeline.scheduled.count == 2)

            // Sent now, the one that goes to the room too is in both.
            let first = try #require(thread.scheduled.first)
            try session.sendNow(scheduled: first.id)
            #expect(await eventually { thread.timeline.replies.contains { $0.clientMessageId == loud } })
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == loud && $0.parentId == parent.id } })
            #expect(await eventually { thread.scheduled.map(\.clientMessageId) == [quiet] })

            let waiting = try #require(thread.scheduled.first)
            try session.delete(scheduled: waiting.id)
            #expect(await eventually { session.timeline.scheduled.isEmpty })

            // A reply to a message that's deleted before anyone else replies can't be sent. It stays, saying why.
            let other = session.send(body: "<p>Another thread</p>", plainText: "Another thread")
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == other } })
            let gone = try #require(session.timeline.messages.first { $0.clientMessageId == other })
            let late = try await session.thread(gone.id).schedule(body: "<p>Too late</p>", at: at)
            let stuck = try #require(session.timeline.scheduled.first { $0.clientMessageId == late })
            #expect(stuck.parentId == gone.id)
            try await session.delete(message: gone.id)
            try session.sendNow(scheduled: stuck.id)
            #expect(await eventually { session.timeline.scheduled.first { $0.id == stuck.id }?.failure == ScheduledMessage.threadDeleted })
            #expect(await eventually { session.notice == ScheduledMessage.threadDeleted })
            session.notice = nil
            #expect(!session.timeline.messages.contains { $0.clientMessageId == late })

            try session.delete(scheduled: stuck.id)
            #expect(await eventually { session.timeline.scheduled.isEmpty })
        }
    }

    /// The buttons a card ends with.
    func lastButtons(of message: EphemeralMessage) throws -> [CardButton] {
        guard case let .buttons(buttons)? = message.cards.first?.parts.last else {
            Issue.record("The card doesn't end with buttons.")
            throw CancellationError()
        }
        return buttons
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aCardOnlyYouSeeIsAnsweredInPlace() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let leo = try await engineering(on: try await signedIn(as: "leo@example.com"))
        defer { leo.stop() }
        let known = Set(session.timeline.ephemeral.map(\.id))

        let question = "Should we rollback \(UUID().uuidString.prefix(8))?"
        _ = session.send(body: "<p>\(question)</p>", plainText: question)
        #expect(await eventually(within: .seconds(15)) { session.timeline.ephemeral.contains { !known.contains($0.id) } })
        let card = try #require(session.timeline.ephemeral.first { !known.contains($0.id) })
        #expect(card.creator.name == "Deploy Bot")
        #expect(card.roomId == session.roomID)
        #expect(card.parentId == nil)
        #expect(card.body.isEmpty)
        #expect(card.plainText.contains("back to v2.4.2?"))
        let buttons = try lastButtons(of: card)
        #expect(buttons.map(\.text) == ["Roll back", "Cancel"])
        let cancel = try #require(buttons.last?.action)
        #expect(cancel == CardAction(id: "cancel", blockId: "rollback_actions", value: "v2.4.2"))

        // It isn't one of the room's messages, and nobody else has it.
        #expect(!session.timeline.messages.contains { $0.id == card.id })
        #expect(await eventually { leo.timeline.messages.contains { $0.plainText == question } })
        #expect(!leo.timeline.ephemeral.contains { $0.id == card.id })
        // Another socket of yours has it from its welcome.
        let second = try await engineering(on: client)
        defer { second.stop() }
        #expect(second.timeline.ephemeral.contains { $0.id == card.id })

        // Answered, it's changed where it is, on each of your sockets.
        try await session.click(cancel, on: card.id)
        let answered = try #require(session.timeline.ephemeral.first { $0.id == card.id })
        #expect(answered.plainText.contains("You cancelled this."))
        #expect(answered.cards.first?.parts.contains { if case .buttons = $0 { true } else { false } } == false)
        #expect(session.timeline.ephemeral.filter { !known.contains($0.id) }.count == 1)
        #expect(await eventually { second.timeline.ephemeral.first { $0.id == card.id }?.plainText.contains("You cancelled this.") == true })
        #expect(session.notice == nil)

        await #expect(throws: EmberError(kind: .refused, message: "That button is no longer there")) {
            try await session.click(cancel, on: card.id)
        }
        #expect(session.notice == nil)

        // A socket opened since no longer has it.
        let third = try await engineering(on: client)
        defer { third.stop() }
        #expect(!third.timeline.ephemeral.contains { $0.id == card.id })
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aCardOnlyYouSeeInAThreadIsTheThreads() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let known = Set(session.timeline.ephemeral.map(\.id))
        let text = "Deploys look off \(UUID().uuidString.prefix(8))"
        let sent = session.send(body: "<p>\(text)</p>", plainText: text)
        #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == sent } })
        let parent = try #require(session.timeline.messages.first { $0.clientMessageId == sent })
        let thread = session.thread(parent.id)
        let lease = thread.open()
        defer { lease.close() }
        #expect(await eventually { thread.timeline.isLoaded })
        #expect(thread.timeline.ephemeral.isEmpty)

        thread.reply(body: "<p>Time to rollback?</p>", plainText: "Time to rollback?")
        #expect(await eventually(within: .seconds(15)) { !thread.timeline.ephemeral.isEmpty })
        let card = try #require(thread.timeline.ephemeral.first)
        #expect(card.creator.name == "Deploy Bot")
        #expect(card.parentId == parent.id)
        #expect(card.plainText.contains("back to v2.4.2?"))
        // The room's own timeline doesn't show it.
        #expect(!session.timeline.ephemeral.contains { !known.contains($0.id) })

        // The thread, opened on another socket of yours, has it.
        let second = try await engineering(on: client)
        defer { second.stop() }
        let again = second.thread(parent.id)
        let secondLease = again.open()
        defer { secondLease.close() }
        #expect(await eventually { again.timeline.isLoaded })
        #expect(again.timeline.ephemeral.map(\.id) == [card.id])

        let rollBack = try #require(try lastButtons(of: card).first { $0.text == "Roll back" }?.action)
        try await thread.click(rollBack, on: card.id)
        #expect(thread.timeline.ephemeral.first?.plainText.contains("You allowed this.") == true)
        #expect(thread.timeline.ephemeral.count == 1)
        #expect(thread.notice == nil)
        #expect(await eventually { again.timeline.ephemeral.first?.plainText.contains("You allowed this.") == true })
        // What the bot does about it is a reply, for everyone.
        #expect(await eventually(within: .seconds(15)) {
            thread.timeline.replies.contains { $0.creator.name == "Deploy Bot" && $0.plainText.hasPrefix("Rolling message-api back to v2.4.2, as ") }
        })
    }
}
