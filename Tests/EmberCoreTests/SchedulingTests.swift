import Foundation
import Testing
@testable import EmberCore

// What a client owes the messages you've scheduled and the ones only you see.

private func welcomed(_ messages: [Message] = [], hasNewer: Bool = false, ephemeral: [EphemeralMessage] = [], scheduled: [ScheduledMessage] = []) -> Timeline {
    var timeline = Timeline()
    _ = timeline.apply(.welcome(you: ada, present: [ada], seq: 1, page: TimelinePage(messages: messages, hasNewer: hasNewer), ephemeral: ephemeral, scheduled: scheduled))
    return timeline
}

private func scheduled(_ id: ScheduledMessageID, minutes: Int = 0, parentId: MessageID? = nil, failure: String? = nil) -> ScheduledMessage {
    ScheduledMessage(id: id, clientMessageId: ClientMessageID("c-\(id)"), body: "<p>\(id)</p>", sendAt: noon(minutes), parentId: parentId, failure: failure)
}

private let ember = User(id: "ember", name: "Ember")

private func ephemeral(_ id: MessageID, _ text: String = "Run it?", parentId: MessageID? = nil) -> EphemeralMessage {
    EphemeralMessage(id: id, roomId: "r1", creator: ember, plainText: text, createdAt: noon(), parentId: parentId)
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try EmberJSON.decoder().decode(type, from: Data(json.utf8))
}

@Suite struct ScheduledMessageTests {
    @Test func readsWithWhatItHas() throws {
        let full = try decoded(ScheduledMessage.self, #"""
        {"id":"s1","clientMessageId":"c1","body":"<p>Hi</p>","sendAt":"2026-10-12T12:00:00.000Z","parentId":"m1","alsoSend":true,"failure":"Its thread's message has been deleted."}
        """#)
        #expect(full == ScheduledMessage(id: "s1", clientMessageId: "c1", body: "<p>Hi</p>", sendAt: noon(), parentId: "m1", alsoSend: true, failure: ScheduledMessage.threadDeleted))
        // Without its sender's id it takes its own, and what can't be read is left out.
        let bare = try decoded(ScheduledMessage.self, #"{"id":"s1","sendAt":"2026-10-12T12:00:00Z","body":5,"alsoSend":"yes","failure":false}"#)
        #expect(bare == ScheduledMessage(id: "s1", clientMessageId: "s1", body: "", sendAt: noon()))
        #expect(throws: (any Error).self) { try decoded(ScheduledMessage.self, #"{"id":"s1","body":"Hi"}"#) }
        #expect(throws: (any Error).self) { try decoded(ScheduledMessage.self, #"{"id":"s1","body":"Hi","sendAt":"soon"}"#) }
    }

    @Test func theRoomsLimitsAreTheServers() {
        #expect(Limits.scheduledMessages == 30)
        #expect(Limits.scheduleAhead == 120 * 86_400)
    }

    @Test func welcomeListsThem() {
        let timeline = welcomed(scheduled: [scheduled("s1"), scheduled("s2", minutes: 5, parentId: "m001")])
        #expect(timeline.scheduled.map(\.id) == ["s1", "s2"])
        #expect(timeline.scheduledForRoom.map(\.id) == ["s1"])
        #expect(timeline.scheduled(in: "m001").map(\.id) == ["s2"])
        #expect(timeline.scheduled(in: "m002").isEmpty)
        #expect(welcomed().scheduled.isEmpty)
    }

    @Test func eachListTakesTheLastsPlace() {
        var timeline = welcomed(scheduled: [scheduled("s1")])
        let asked = timeline.apply(.scheduled([scheduled("s0", minutes: -5), scheduled("s1")]))
        #expect(asked.isEmpty)
        #expect(timeline.scheduled.map(\.id) == ["s0", "s1"])
        _ = timeline.apply(.scheduled([scheduled("s1", minutes: 30)], edited: "s1"))
        #expect(timeline.scheduled == [scheduled("s1", minutes: 30)])
        // The last of them sent or deleted.
        _ = timeline.apply(.scheduled([]))
        #expect(timeline.scheduled.isEmpty)
    }

    @Test func resumingTakesTheListAsItIsNow() {
        var timeline = welcomed(scheduled: [scheduled("s1"), scheduled("s2", minutes: 5)])
        // One was sent while the socket was down, and comes back as a message.
        _ = timeline.apply(.resumed(you: ada, messages: [message("m001", by: ada, clientMessageId: "c-s1")], deletedIds: [], present: [ada], seq: 2, scheduled: [scheduled("s2", minutes: 5)]))
        #expect(timeline.scheduled.map(\.id) == ["s2"])
        #expect(timeline.messages.map(\.id) == ["m001"])
        // None left, which the room says by leaving the list out.
        _ = timeline.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [ada], seq: 2))
        #expect(timeline.scheduled.isEmpty)
    }

    @Test func aReplyWhoseThreadIsGoneIsListedWithTheRooms() {
        let orphan = scheduled("s2", minutes: 5, parentId: "m001", failure: ScheduledMessage.threadDeleted)
        let late = scheduled("s3", minutes: 9, parentId: "m002", failure: "You’re no longer in this room.")
        let timeline = welcomed(scheduled: [scheduled("s1"), orphan, late])
        #expect(timeline.scheduledForRoom.map(\.id) == ["s1", "s2"])
        #expect(timeline.scheduled(in: "m001") == [orphan])
        #expect(timeline.scheduled(in: "m002") == [late])
    }

    @Test func anEditRefusedFailsNoMessageOnItsWay() {
        var timeline = welcomed(scheduled: [scheduled("s1")])
        _ = timeline.send(body: "<p>One</p>", plainText: "One", clientMessageId: "c1", now: noon())
        let asked = timeline.apply(.error(message: "Too long", clientMessageId: nil, clientMessageIds: nil, scheduledId: "s1", failed: "scheduled.edit"))
        #expect(asked.isEmpty)
        #expect(timeline.pending.map(\.failure) == [nil])
        #expect(timeline.scheduled == [scheduled("s1")])

        var thread = ThreadTimeline(parentId: "m001", me: ada)
        _ = thread.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [], hasMore: false))
        let refused = thread.apply(.error(message: "Too long", clientMessageId: nil, clientMessageIds: nil, scheduledId: "s1", failed: "scheduled.edit"))
        let listed = thread.apply(.scheduled([scheduled("s1", parentId: "m001")]))
        #expect(refused.isEmpty && listed.isEmpty && thread.pending.isEmpty)
    }
}

@Suite struct EphemeralMessageTests {
    @Test func readsWithWhatItHas() throws {
        let card = #"{"source":"blocks","parts":[{"kind":"header","text":"Run deploy?"}]}"#
        let asked = try decoded(EphemeralMessage.self, #"""
        {"id":"e1","roomId":"r1","creator":{"id":"ember","name":"Ember"},"body":"","plainText":"Run deploy?","cards":[\#(card)],"createdAt":"2026-10-12T12:00:00.000Z","parentId":"m1"}
        """#)
        #expect(asked.id == "e1" && asked.roomId == "r1" && asked.creator == ember && asked.parentId == "m1")
        #expect(asked.plainText == "Run deploy?" && asked.body.isEmpty && asked.createdAt == noon())
        #expect(asked.cards.count == 1)
        #expect(asked.creator.id == Assistant.id && asked.creator.name == Assistant.name)
        // Its text and cards are left out when they can't be read.
        let bare = try decoded(EphemeralMessage.self, #"{"id":"e1","roomId":"r1","creator":{"id":"ember","name":"Ember"},"body":5,"cards":"none","createdAt":"2026-10-12T12:00:00Z"}"#)
        #expect(bare == ephemeral("e1", ""))
        #expect(throws: (any Error).self) { try decoded(EphemeralMessage.self, #"{"id":"e1","roomId":"r1","createdAt":"2026-10-12T12:00:00Z"}"#) }
    }

    @Test func welcomeListsTheRoomsAndTheThreadsItsOwn() {
        let timeline = welcomed(stored(1, 2), ephemeral: [ephemeral("e1")])
        #expect(timeline.ephemeral == [ephemeral("e1")])
        // They're no part of the room's messages.
        #expect(timeline.messages.map(\.id) == ["m001", "m002"])
        #expect(timeline.message("e1") == nil)

        var thread = ThreadTimeline(parentId: "m001", me: ada)
        _ = thread.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [], hasMore: false, ephemeral: [ephemeral("e2", parentId: "m001")]))
        #expect(thread.ephemeral.map(\.id) == ["e2"])
        #expect(thread.replies.isEmpty)
    }

    @Test func oneArrivesAndIsChangedInPlace() {
        var timeline = welcomed(ephemeral: [ephemeral("e1")])
        let asked = timeline.apply(.messageEphemeral(ephemeral("e2", "Send it?")))
        #expect(asked.isEmpty)
        #expect(timeline.ephemeral.map(\.id) == ["e1", "e2"])
        // What came of the call takes the card's place.
        _ = timeline.apply(.messageEphemeral(ephemeral("e1", "Done.")))
        #expect(timeline.ephemeral.map(\.plainText) == ["Done.", "Send it?"])
        #expect(timeline.seq == 1)
    }

    @Test func oneInAThreadIsItsThreadsAlone() {
        var timeline = welcomed()
        var thread = ThreadTimeline(parentId: "m001", me: ada)
        _ = thread.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [], hasMore: false))
        let inThread = ServerFrame.messageEphemeral(ephemeral("e1", parentId: "m001"))
        let elsewhere = ServerFrame.messageEphemeral(ephemeral("e2", parentId: "m002"))
        let inRoom = ServerFrame.messageEphemeral(ephemeral("e3"))
        for frame in [inThread, elsewhere, inRoom] {
            _ = timeline.apply(frame)
            _ = thread.apply(frame)
        }
        #expect(timeline.ephemeral.map(\.id) == ["e3"])
        #expect(thread.ephemeral.map(\.id) == ["e1"])
        _ = thread.apply(.messageEphemeral(ephemeral("e1", "Done.", parentId: "m001")))
        #expect(thread.ephemeral.map(\.plainText) == ["Done."])
    }

    @Test func resumingTakesThoseStillWaiting() {
        var timeline = welcomed(ephemeral: [ephemeral("e1"), ephemeral("e2")])
        _ = timeline.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [ada], seq: 1, ephemeral: [ephemeral("e2")]))
        #expect(timeline.ephemeral.map(\.id) == ["e2"])
        _ = timeline.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [ada], seq: 1))
        #expect(timeline.ephemeral.isEmpty)

        // A thread opened again takes its own afresh.
        var thread = ThreadTimeline(parentId: "m001", me: ada)
        _ = thread.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [], hasMore: false, ephemeral: [ephemeral("e1", parentId: "m001")]))
        _ = thread.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [], hasMore: false))
        #expect(thread.ephemeral.isEmpty)
    }

    @Test func oneThatArrivesAwayFromTheNewestMessagesCountsAsAnArrival() {
        var timeline = welcomed(stored(1, 3), hasNewer: true)
        _ = timeline.apply(.messageEphemeral(ephemeral("e1")))
        #expect(timeline.arrivals == 1)
        // A change to it is no new arrival.
        _ = timeline.apply(.messageEphemeral(ephemeral("e1", "Done.")))
        #expect(timeline.arrivals == 1)
        var newest = welcomed(stored(1, 3))
        _ = newest.apply(.messageEphemeral(ephemeral("e1")))
        #expect(newest.arrivals == 0)
    }
}
