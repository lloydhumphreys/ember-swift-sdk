import Foundation
import Testing
@testable import EmberCore

@Suite struct ClientFrameTests {
    static let cases: [(ClientFrame, String)] = [
        (.createMessage(clientMessageId: "c1", body: "<p>Hi</p>"), #"{"type":"message.create","clientMessageId":"c1","body":"<p>Hi</p>"}"#),
        (.createMessage(clientMessageId: "c1", body: "Hi", parentId: "m1", alsoSend: true),
         #"{"type":"message.create","clientMessageId":"c1","body":"Hi","parentId":"m1","alsoSend":true}"#),
        (.updateMessage(messageId: "m1", body: "Edited"), #"{"type":"message.update","messageId":"m1","body":"Edited"}"#),
        (.deleteMessage(messageId: "m1"), #"{"type":"message.delete","messageId":"m1"}"#),
        (.createBoost(messageId: "m1", content: "🎉"), #"{"type":"boost.create","messageId":"m1","content":"🎉"}"#),
        (.deleteBoost(boostId: "b1"), #"{"type":"boost.delete","boostId":"b1"}"#),
        (.typingStart, #"{"type":"typing.start"}"#),
        (.typingStop, #"{"type":"typing.stop"}"#),
        (.historyBefore(messageId: "m5"), #"{"type":"history.before","before":"m5"}"#),
        (.historyBefore(messageId: "m5", limit: 10), #"{"type":"history.before","before":"m5","limit":10}"#),
        (.historyAfter(messageId: "m5"), #"{"type":"history.after","after":"m5"}"#),
        (.historyAfter(messageId: "m5", limit: 10), #"{"type":"history.after","after":"m5","limit":10}"#),
        (.historyAround(messageId: "m5"), #"{"type":"history.around","messageId":"m5"}"#),
        (.historyAround(messageId: nil), #"{"type":"history.around"}"#),
        (.checkMessages(clientMessageIds: ["c1", "c2"]), #"{"type":"message.check","clientMessageIds":["c1","c2"]}"#),
        (.openThread(parentId: "m1"), #"{"type":"thread.open","parentId":"m1"}"#),
        (.closeThread(parentId: "m1"), #"{"type":"thread.close","parentId":"m1"}"#),
        (.threadBefore(parentId: "m1", before: "m9"), #"{"type":"thread.before","parentId":"m1","before":"m9"}"#),
        (.threadBefore(parentId: "m1", before: "m9", limit: 5), #"{"type":"thread.before","parentId":"m1","before":"m9","limit":5}"#),
        (.visible(true), #"{"type":"presence.visible","visible":true}"#),
        (.visible(false), #"{"type":"presence.visible","visible":false}"#),
        (.ping, #"{"type":"ping"}"#),
    ]

    @Test(arguments: cases.indices)
    func encodesAsTheProtocolHasIt(_ index: Int) {
        let (frame, expected) = Self.cases[index]
        #expect(json(frame.text) == json(expected))
        #expect(json(frame.text).flatMap { if case let .object(f) = $0 { f["type"] } else { nil } } == .string(frame.type))
    }

    @Test(arguments: cases.indices)
    func readsBackAsTheSameFrame(_ index: Int) {
        let (frame, expected) = Self.cases[index]
        #expect(ClientFrame(text: frame.text) == frame)
        #expect(ClientFrame(text: expected) == frame)
    }

    @Test func pingIsExactlyItsText() {
        #expect(ClientFrame.ping.text == #"{"type":"ping"}"#)
    }

    @Test func slashesAreNotEscaped() {
        #expect(ClientFrame.createMessage(clientMessageId: "c1", body: "<p>a/b</p>").text.contains("</p>"))
    }

    @Test func refusesWhatTheRoomWouldNot() {
        #expect(ClientFrame(text: "nonsense") == nil)
        #expect(ClientFrame(text: #"{"type":"message.create","body":"Hi"}"#) == nil)
        #expect(ClientFrame(text: #"{"type":"teleport"}"#) == nil)
        #expect(ClientFrame(text: #"{"type":"message.check","clientMessageIds":["c1",2]}"#) == nil)
    }
}

@Suite struct ServerFrameTests {
    let you = #"{"id":"u1","name":"Ada"}"#
    let grace = #"{"id":"u2","name":"Grace"}"#

    @Test func welcome() throws {
        let frame = ServerFrame(text: #"{"type":"welcome","you":\#(you),"present":[\#(grace)],"seq":7,"messages":[\#(messageJSON)],"hasMore":true,"hasNewer":false,"around":null}"#)
        guard case let .welcome(me, present, seq, page) = frame else { Issue.record("\(frame)"); return }
        #expect(me == ada)
        #expect(present == [EmberCoreTests.grace])
        #expect(seq == 7)
        #expect(page.messages.map(\.id) == ["m001"])
        #expect(page.hasMore && !page.hasNewer && page.around == nil)
    }

    @Test func welcomeAroundAMessage() {
        let frame = ServerFrame(text: #"{"type":"welcome","you":\#(you),"present":[],"seq":1,"messages":[],"hasMore":false,"hasNewer":true,"around":"m5"}"#)
        #expect(frame == .welcome(you: ada, present: [], seq: 1, page: TimelinePage(messages: [], hasNewer: true, around: "m5")))
    }

    @Test func resumed() {
        let frame = ServerFrame(text: #"{"type":"resumed","you":\#(you),"messages":[\#(messageJSON)],"deletedIds":["m000"],"present":[],"seq":9}"#)
        guard case let .resumed(_, messages, deletedIds, present, seq) = frame else { Issue.record("\(frame)"); return }
        #expect(messages.count == 1 && deletedIds == ["m000"] && present.isEmpty && seq == 9)
    }

    @Test func messageChanges() throws {
        guard case let .messageCreated(created, 3) = ServerFrame(text: #"{"type":"message.created","message":\#(messageJSON),"seq":3}"#) else {
            Issue.record("message.created"); return
        }
        #expect(created.id == "m001")
        #expect(created.createdAt == EmberJSON.date(from: "2026-10-12T10:00:00Z"))
        guard case .messageUpdated(_, 4) = ServerFrame(text: #"{"type":"message.updated","message":\#(messageJSON),"seq":4}"#) else {
            Issue.record("message.updated"); return
        }
        #expect(ServerFrame(text: #"{"type":"message.deleted","messageId":"m1","seq":5}"#) == .messageDeleted(messageId: "m1", seq: 5))
    }

    @Test func boosts() {
        let frame = ServerFrame(text: #"{"type":"boost.created","boost":{"id":"b1","messageId":"m1","booster":\#(grace),"content":"🎉","createdAt":"2026-10-12T10:00:00.123Z"},"seq":6}"#)
        let boost = Boost(id: "b1", messageId: "m1", booster: EmberCoreTests.grace, content: "🎉", createdAt: EmberJSON.date(from: "2026-10-12T10:00:00.123Z")!)
        #expect(frame == .boostCreated(boost, seq: 6))
        #expect(ServerFrame(text: #"{"type":"boost.deleted","boostId":"b1","messageId":"m1","seq":7}"#) == .boostDeleted(boostId: "b1", messageId: "m1", seq: 7))
    }

    @Test func presenceAndTyping() {
        #expect(ServerFrame(text: #"{"type":"presence.joined","user":\#(grace)}"#) == .presenceJoined(EmberCoreTests.grace))
        #expect(ServerFrame(text: #"{"type":"presence.left","userId":"u2"}"#) == .presenceLeft(userId: "u2"))
        #expect(ServerFrame(text: #"{"type":"typing","user":\#(grace),"typing":true}"#) == .typing(user: EmberCoreTests.grace, typing: true, threadId: nil))
        #expect(ServerFrame(text: #"{"type":"typing","user":\#(grace),"typing":false,"threadId":"m1"}"#) == .typing(user: EmberCoreTests.grace, typing: false, threadId: "m1"))
    }

    @Test func history() {
        guard case let .history("m5", messages, true) = ServerFrame(text: #"{"type":"history","before":"m5","messages":[\#(messageJSON)],"hasMore":true}"#) else {
            Issue.record("history"); return
        }
        #expect(messages.count == 1)
        #expect(ServerFrame(text: #"{"type":"history.after","after":"m5","messages":[],"hasNewer":false}"#) == .historyAfter(after: "m5", messages: [], hasNewer: false))
        #expect(ServerFrame(text: #"{"type":"history.around","messages":[],"hasMore":true,"hasNewer":true,"around":"m5"}"#)
            == .historyAround(TimelinePage(messages: [], hasMore: true, hasNewer: true, around: "m5")))
    }

    @Test func checked() {
        #expect(ServerFrame(text: #"{"type":"message.checked","stored":["c1"],"missing":["c2"]}"#) == .messageChecked(stored: ["c1"], missing: ["c2"]))
    }

    @Test func threads() {
        #expect(ServerFrame(text: #"{"type":"thread.opened","parentId":"m1","parent":null,"messages":[],"hasMore":false}"#)
            == .threadOpened(parentId: "m1", parent: nil, messages: [], hasMore: false))
        guard case let .threadOpened(_, parent?, _, _) = ServerFrame(text: #"{"type":"thread.opened","parentId":"m001","parent":\#(messageJSON),"messages":[],"hasMore":true}"#) else {
            Issue.record("thread.opened"); return
        }
        #expect(parent.id == "m001")
        #expect(ServerFrame(text: #"{"type":"thread.history","parentId":"m1","before":"m9","messages":[],"hasMore":false}"#)
            == .threadHistory(parentId: "m1", before: "m9", messages: [], hasMore: false))
    }

    @Test func errors() {
        #expect(ServerFrame(text: #"{"type":"error","message":"Too long"}"#) == .error(message: "Too long", clientMessageId: nil, clientMessageIds: nil, failed: nil))
        #expect(ServerFrame(text: #"{"type":"error","message":"No","clientMessageId":"c1","failed":"message.create"}"#)
            == .error(message: "No", clientMessageId: "c1", clientMessageIds: nil, failed: "message.create"))
        #expect(ServerFrame(text: #"{"type":"error","message":"No","clientMessageIds":["c1","c2"],"failed":"message.check"}"#)
            == .error(message: "No", clientMessageId: nil, clientMessageIds: ["c1", "c2"], failed: "message.check"))
        #expect(ServerFrame(text: #"{"type":"pong"}"#) == .pong)
    }

    @Test(arguments: [
        ("nonsense", ""),
        ("", ""),
        ("[1,2]", ""),
        (#"{"type":5}"#, ""),
        (#"{"message":"no type"}"#, ""),
        (#"{"type":"teleport","to":"Mars"}"#, "teleport"),
        (#"{"type":"welcome"}"#, "welcome"),
        (#"{"type":"message.created","message":{"id":"m1"},"seq":1}"#, "message.created"),
        (#"{"type":"message.deleted","messageId":"m1","seq":"one"}"#, "message.deleted"),
        (#"{"type":"boost.created","boost":{"id":"b1","messageId":"m1","booster":{"id":"u1","name":"Ada"},"content":"x","createdAt":"yesterday"},"seq":1}"#, "boost.created"),
    ])
    func unreadableIsUnknown(_ text: String, _ type: String) {
        #expect(ServerFrame(text: text) == .unknown(type))
    }
}

@Suite struct WorkspaceFrameTests {
    @Test func welcome() {
        let frame = WorkspaceFrame(text: #"{"type":"welcome","you":{"id":"u1","name":"Ada","administrator":true},"account":{"name":"Acme","tagline":"","restrictRoomCreation":false,"hideTranslationButtons":false}}"#)
        #expect(frame == .welcome(you: Me(id: "u1", name: "Ada", administrator: true), account: Account(name: "Acme")))
    }

    @Test func rooms() {
        #expect(WorkspaceFrame(text: #"{"type":"room.unread","roomId":"r1"}"#) == .roomUnread("r1"))
        #expect(WorkspaceFrame(text: #"{"type":"room.read","roomId":"r1"}"#) == .roomRead("r1"))
        #expect(WorkspaceFrame(text: #"{"type":"room.saved","room":{"id":"r1","kind":"open","name":"general","icon":null}}"#)
            == .roomSaved(Room(id: "r1", kind: .open, name: "general")))
        #expect(WorkspaceFrame(text: #"{"type":"room.gone","roomId":"r1"}"#) == .roomGone("r1"))
        #expect(WorkspaceFrame(text: #"{"type":"room.active","roomId":"d1","at":"2026-10-12T12:00:00.000Z"}"#) == .roomActive("d1", at: noon()))
        #expect(WorkspaceFrame(text: #"{"type":"room.active","roomId":"d1","at":"2026-10-12T12:00:00Z"}"#) == .roomActive("d1", at: noon()))
        #expect(WorkspaceFrame(text: #"{"type":"room.involvement","roomId":"r1","involvement":"nothing"}"#) == .roomInvolvement("r1", .nothing))
        #expect(WorkspaceFrame(text: #"{"type":"rooms.reordered"}"#) == .roomsReordered)
    }

    @Test func peopleStarsAndAccount() {
        #expect(WorkspaceFrame(text: #"{"type":"user.updated","user":{"id":"u2","name":"Grace","role":"member","status":"active","avatarUrl":"/a"}}"#)
            == .userUpdated(DirectoryUser(id: "u2", name: "Grace", avatarUrl: "/a")))
        #expect(WorkspaceFrame(text: #"{"type":"favorites.changed","favorites":{"rooms":["r2","r1"],"version":3}}"#)
            == .favoritesChanged(Favorites(rooms: ["r2", "r1"], version: 3)))
        #expect(WorkspaceFrame(text: #"{"type":"invitation.dismissed"}"#) == .invitationDismissed)
        #expect(WorkspaceFrame(text: #"{"type":"account.updated","account":{"name":"Acme Ltd"}}"#) == .accountUpdated(Account(name: "Acme Ltd")))
        #expect(WorkspaceFrame(text: #"{"type":"error","message":"Nope"}"#) == .error("Nope"))
        #expect(WorkspaceFrame(text: #"{"type":"pong"}"#) == .pong)
    }

    @Test(arguments: [
        ("{", ""),
        (#"{"type":null}"#, ""),
        (#"{"type":"room.unread"}"#, "room.unread"),
        (#"{"type":"room.active","roomId":"d1","at":"noon"}"#, "room.active"),
        (#"{"type":"favorites.changed","favorites":{"rooms":"r1"}}"#, "favorites.changed"),
        (#"{"type":"something.new"}"#, "something.new"),
    ])
    func unreadableIsUnknown(_ text: String, _ type: String) {
        #expect(WorkspaceFrame(text: text) == .unknown(type))
    }
}

@Suite struct SocketTests {
    @Test func roomSocketQuery() {
        #expect(RoomSocket.protocolRevision == 4)
        #expect(RoomSocket.query(visible: true, since: nil, around: nil) == "visible=1&protocol=4")
        #expect(RoomSocket.query(visible: false, since: 42, around: nil) == "visible=0&protocol=4&since=42")
        #expect(RoomSocket.query(visible: true, since: nil, around: "m 1/é") == "visible=1&protocol=4&around=m%201%2F%C3%A9")
        #expect(RoomSocket.query(visible: true, since: 0, around: "m1") == "visible=1&protocol=4&since=0&around=m1")
    }

    @Test func closeCodes() {
        #expect(SocketClose.reconnect == 4001)
        #expect(SocketClose.revoked == 4003)
        #expect(SocketClose.notFound == 4004)
    }

    @Test func datesReadWithOrWithoutFractionalSecondsAndWriteWithMilliseconds() throws {
        #expect(EmberJSON.date(from: "2026-10-12T12:00:00Z") == noon())
        #expect(EmberJSON.date(from: "2026-10-12T12:00:00.000Z") == noon())
        #expect(EmberJSON.date(from: "12 October") == nil)
        #expect(EmberJSON.string(from: noon()) == "2026-10-12T12:00:00.000Z")
        let data = try EmberJSON.encoder().encode([noon()])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-10-12T12:00:00.000Z"]"#)
        #expect(try EmberJSON.decoder().decode([Date].self, from: data) == [noon()])
        #expect(throws: DecodingError.self) { try EmberJSON.decoder().decode([Date].self, from: Data(#"["soon"]"#.utf8)) }
    }
}
