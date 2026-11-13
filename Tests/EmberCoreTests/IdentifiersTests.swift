import Foundation
import Testing
@testable import EmberCore

/// Each id kind answers its own name here. Were two kinds one type, these would be one function
/// declared twice and the file wouldn't compile.
private func kind(_: UserID) -> String { "user" }
private func kind(_: RoomID) -> String { "room" }
private func kind(_: MessageID) -> String { "message" }
private func kind(_: ClientMessageID) -> String { "client message" }
private func kind(_: BoostID) -> String { "boost" }
private func kind(_: UploadID) -> String { "upload" }
private func kind(_: FileID) -> String { "file" }

private func encoded(_ value: some Encodable) throws -> JSONValue? {
    json(String(decoding: try EmberJSON.encoder().encode(value), as: UTF8.self))
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try EmberJSON.decoder().decode(type, from: Data(text.utf8))
}

@Suite struct IdentifiersTests {
    @Test func madeFromALiteralOrAnInterpolation() {
        let n = 7
        let literal: MessageID = "m007"
        let interpolated: MessageID = "m00\(n)"
        #expect(literal == interpolated)
        #expect(interpolated.rawValue == "m007")
        let room: RoomID = "room-\(n)"
        #expect(room.rawValue == "room-7")
    }

    @Test func describedAsItsString() {
        let id = UserID("u_42")
        #expect(id.description == "u_42")
        #expect("\(id)" == "u_42")
        #expect(String(describing: id) == "u_42")
        #expect(id.debugDescription == #"UserID("u_42")"#)
        #expect(String(reflecting: ClientMessageID("c\"1")) == #"ClientMessageID("c\"1")"#)
    }

    @Test func nothingIsCheckedOrChanged() {
        for text in ["", " M1 ", "ünï/cødé?&=", "a\nb"] {
            #expect(MessageID(text).rawValue == text)
            #expect(UploadID(rawValue: text).rawValue == text)
        }
    }

    @Test func sortedAsTheirStrings() {
        let texts = ["m10", "m2", "M3", "", "m1", "é", "e", "m002"]
        #expect(texts.map(MessageID.init).sorted().map(\.rawValue) == texts.sorted())
        #expect(RoomID("a") < RoomID("b"))
        #expect(!(RoomID("b") < RoomID("b")))
        #expect(BoostID("b10") < BoostID("b9"))
    }

    @Test func hashingAndEqualityAgreeHoweverMade() {
        let ids: [FileID] = [FileID(rawValue: "f1"), FileID("f1"), "f1", "f\(1)"]
        #expect(Set(ids).count == 1)
        #expect(ids.allSatisfy { $0 == ids[0] && $0.hashValue == ids[0].hashValue })
        #expect(FileID("f1") != FileID("f2"))
        #expect([FileID("f1"): 1][ids[2]] == 1)
    }

    @Test func eachKindIsItsOwnType() {
        #expect(kind(UserID("x")) == "user")
        #expect(kind(RoomID("x")) == "room")
        #expect(kind(MessageID("x")) == "message")
        #expect(kind(ClientMessageID("x")) == "client message")
        #expect(kind(BoostID("x")) == "boost")
        #expect(kind(UploadID("x")) == "upload")
        #expect(kind(FileID("x")) == "file")
        let types: [Any.Type] = [UserID.self, RoomID.self, MessageID.self, ClientMessageID.self, BoostID.self, UploadID.self, FileID.self]
        #expect(Set(types.map(ObjectIdentifier.init)).count == 7)
    }

    @Test func aBareJSONString() throws {
        let data = try JSONEncoder().encode(MessageID("m1"))
        #expect(String(decoding: data, as: UTF8.self) == #""m1""#)
        #expect(try JSONDecoder().decode(MessageID.self, from: Data(#""m1""#.utf8)) == "m1")
        #expect(try JSONEncoder().encode([UserID("u1"), "u2"]) == Data(#"["u1","u2"]"#.utf8))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MessageID.self, from: Data("1".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MessageID.self, from: Data(#"{"rawValue":"m1"}"#.utf8)) }
    }

    @Test func dictionariesKeyedByIdsAreJSONObjects() throws {
        let unread: [RoomID: Int] = ["r1": 3]
        #expect(try JSONEncoder().encode(unread) == Data(#"{"r1":3}"#.utf8))
        let names: [UserID: String] = ["u1": "Ada"]
        #expect(try JSONEncoder().encode(names) == Data(#"{"u1":"Ada"}"#.utf8))

        let rooms = try JSONDecoder().decode([RoomID: Int].self, from: Data(#"{"r1":3,"r2":0}"#.utf8))
        #expect(rooms == ["r1": 3, "r2": 0])
        let people = try JSONDecoder().decode([UserID: String].self, from: Data(#"{"u1":"Ada","u2":"Grace"}"#.utf8))
        #expect(people == ["u1": "Ada", "u2": "Grace"])
        let both: [RoomID: Int] = ["r1": 3, "r2": 0]
        #expect(try json(String(decoding: JSONEncoder().encode(both), as: UTF8.self)) == json(#"{"r1":3,"r2":0}"#))
    }

    @Test func aMessageRoundTrips() throws {
        let text = #"{"id":"m1","clientMessageId":"c1","roomId":"r1","creator":{"id":"u2","name":"Grace"},"body":"<p>Hi</p>","plainText":"Hi","mentions":[],"createdAt":"2026-10-12T10:00:00.000Z","parentId":"m0","boosts":[{"id":"b1","messageId":"m1","booster":{"id":"u1","name":"Ada"},"content":"Yes","createdAt":"2026-10-12T10:01:00.000Z"}]}"#
        let message = try decoded(Message.self, text)
        #expect(message.id == MessageID("m1"))
        #expect(message.clientMessageId == ClientMessageID("c1"))
        #expect(message.roomId == RoomID("r1"))
        #expect(message.creator.id == UserID("u2"))
        #expect(message.parentId == MessageID("m0"))
        #expect(message.boosts.first?.id == BoostID("b1"))

        guard case let .object(object)? = try encoded(message) else { Issue.record("not an object"); return }
        #expect(object["id"] == .string("m1"))
        #expect(object["clientMessageId"] == .string("c1"))
        #expect(object["roomId"] == .string("r1"))
        #expect(object["parentId"] == .string("m0"))
        #expect(object["creator"] == json(#"{"id":"u2","name":"Grace"}"#))
        guard case let .array(boosts)? = object["boosts"], case let .object(boost)? = boosts.first else { Issue.record("no boost"); return }
        #expect(boost["id"] == .string("b1"))
        #expect(boost["messageId"] == .string("m1"))
        #expect(try decoded(Message.self, String(decoding: EmberJSON.encoder().encode(message), as: UTF8.self)) == message)
    }

    @Test func aMessageWithoutAClientIdTakesItsId() throws {
        let text = #"{"id":"m1","roomId":"r1","creator":{"id":"u2","name":"Grace"},"body":"","plainText":"","createdAt":"2026-10-12T10:00:00.000Z"}"#
        #expect(try decoded(Message.self, text).clientMessageId == ClientMessageID("m1"))
    }

    @Test func aBoostRoundTrips() throws {
        let text = #"{"id":"b1","messageId":"m1","booster":{"id":"u1","name":"Ada"},"content":"Yes","createdAt":"2026-10-12T10:01:00.000Z"}"#
        let boost = try decoded(Boost.self, text)
        #expect(boost.id == BoostID("b1"))
        #expect(boost.messageId == MessageID("m1"))
        #expect(boost.booster.id == UserID("u1"))
        #expect(try encoded(boost) == json(text))
    }

    @Test func anUploadTicketRoundTrips() throws {
        let text = #"{"id":"upload_1","partSize":5242880,"parts":2}"#
        let ticket = try decoded(UploadTicket.self, text)
        #expect(ticket == UploadTicket(id: "upload_1", partSize: 5_242_880, parts: 2))
        #expect(try encoded(ticket) == json(text))
    }

    @Test func aNewUploadRoundTrips() throws {
        let text = #"{"name":"a.pdf","type":"application/pdf","size":10,"clientMessageId":"c1","parentId":"m1","alsoSend":true}"#
        let upload = NewUpload(name: "a.pdf", type: "application/pdf", size: 10, clientMessageId: "c1", parentId: "m1", delivery: .threadAndRoom)
        #expect(try encoded(upload) == json(text))
        #expect(try decoded(NewUpload.self, text) == upload)
        let bare = NewUpload(name: "a.pdf", type: "application/pdf", size: 10, clientMessageId: "c1")
        #expect(try encoded(bare) == json(#"{"name":"a.pdf","type":"application/pdf","size":10,"clientMessageId":"c1"}"#))
    }
}
