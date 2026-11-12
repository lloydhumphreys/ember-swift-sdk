import Foundation
import Testing
@testable import EmberCore

/// A message this build can't read whole, as an older or newer server might send it.
private let nameless = #"{"id":"m002","roomId":"r1","creator":{"id":"u9"},"plainText":"Who?","createdAt":"2026-10-12T10:01:00Z"}"#
private let halfAttached = #"{"id":"m003","roomId":"r1","creator":{"id":"u2","name":"Grace"},"plainText":"A file","createdAt":"2026-10-12T10:02:00Z","attachment":{"id":"f1","name":"a.png"},"boosts":[{"id":"b1"},{"id":"b2","messageId":"m003","booster":{"id":"u1","name":"Ada"},"content":"👍","createdAt":"2026-10-12T10:03:00Z"}],"mentions":[{"id":"u1"},{"id":"u1","name":"Ada"}],"editedAt":"yesterday","thread":{"count":"two"}}"#
private let you = #"{"id":"u1","name":"Ada"}"#

/// One bad message leaves the rest of its frame read.
@Suite struct LenientFrameTests {
    @Test func aWelcomeWithAMessageItCantReadStillWelcomes() {
        let frame = ServerFrame(text: #"{"type":"welcome","you":\#(you),"present":[\#(you),{"id":"u9"}],"seq":7,"messages":[\#(messageJSON),\#(nameless)],"hasMore":true}"#)
        guard case let .welcome(me, present, seq, page) = frame else { Issue.record("\(frame)"); return }
        #expect(me == ada)
        #expect(present == [ada])
        #expect(seq == 7)
        #expect(page.messages.map(\.id) == ["m001"])
        #expect(page.hasMore)
    }

    @Test func everyListOfMessagesLeavesOutOnlyTheBadOne() throws {
        let good = try Self.read(messageJSON)
        let list = "[\(nameless),\(messageJSON)]"
        let resumed = ServerFrame(text: #"{"type":"resumed","you":\#(you),"messages":\#(list),"deletedIds":[],"present":[],"seq":9}"#)
        guard case let .resumed(_, messages, _, _, 9) = resumed else { Issue.record("\(resumed)"); return }
        #expect(messages.map(\.id) == ["m001"])
        let history = ServerFrame(text: #"{"type":"history","before":"m005","messages":\#(list),"hasMore":true}"#)
        #expect(history == .history(before: "m005", messages: [good], hasMore: true))
        let after = ServerFrame(text: #"{"type":"history.after","after":"m000","messages":\#(list),"hasNewer":false}"#)
        #expect(after == .historyAfter(after: "m000", messages: [good], hasNewer: false))
        let around = ServerFrame(text: #"{"type":"history.around","messages":\#(list),"around":"m001"}"#)
        guard case let .historyAround(page) = around else { Issue.record("\(around)"); return }
        #expect(page.messages.map(\.id) == ["m001"])
        let opened = ServerFrame(text: #"{"type":"thread.opened","parentId":"m001","parent":\#(nameless),"messages":\#(list),"hasMore":false}"#)
        #expect(opened == .threadOpened(parentId: "m001", parent: nil, messages: [good], hasMore: false))
        let older = ServerFrame(text: #"{"type":"thread.history","parentId":"m001","before":"m009","messages":\#(list),"hasMore":true}"#)
        #expect(older == .threadHistory(parentId: "m001", before: "m009", messages: [good], hasMore: true))
    }

    @Test func aMessageKeepsWhatItCanReadOfItsOptionalParts() {
        let frame = ServerFrame(text: #"{"type":"message.created","message":\#(halfAttached),"seq":3}"#)
        guard case let .messageCreated(message, 3) = frame else { Issue.record("\(frame)"); return }
        #expect(message.id == "m003")
        #expect(message.plainText == "A file")
        #expect(message.attachment == nil)
        #expect(message.boosts.map(\.id) == ["b2"])
        #expect(message.mentions == [ada])
        #expect(message.editedAt == nil)
        #expect(message.thread == nil)
        #expect(message.updatedAt == message.createdAt)
    }

    @Test func aMessageWithoutWhatPlacesItIsntRead() {
        let noRoom = #"{"id":"m004","creator":{"id":"u2","name":"Grace"},"createdAt":"2026-10-12T10:02:00Z"}"#
        #expect(ServerFrame(text: #"{"type":"message.created","message":\#(noRoom),"seq":3}"#) == .unknown("message.created"))
    }

    private static func read(_ json: String) throws -> Message {
        try EmberJSON.decoder().decode(Message.self, from: Data(json.utf8))
    }
}
