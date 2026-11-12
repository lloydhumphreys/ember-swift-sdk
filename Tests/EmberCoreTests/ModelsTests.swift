import Foundation
import Testing
@testable import EmberCore

@Suite struct ModelsTests {
    @Test func anUnknownRoleIsKeptRatherThanFailing() throws {
        let json = #"{"id":"u1","name":"Ada","role":"overlord","status":"active","avatarUrl":"/users/t/avatar"}"#
        let user = try JSONDecoder().decode(DirectoryUser.self, from: Data(json.utf8))
        #expect(user.role == .unknown("overlord"))
        #expect(user.role != .administrator)
        #expect(user.role != .bot)
        #expect(!user.role.isKnown)
    }

    @Test func anUnknownStatusIsKeptAndIsNotActive() throws {
        let json = #"{"id":"u1","name":"Ada","role":"member","status":"frozen","avatarUrl":"/users/t/avatar"}"#
        let user = try JSONDecoder().decode(DirectoryUser.self, from: Data(json.utf8))
        #expect(user.status == .unknown("frozen"))
        #expect(user.status != .active)
        #expect(try roundTrip(user.status) == "\"frozen\"")
    }

    @Test func anUnknownRoomKindIsKeptAndIsNeitherOpenNorDirect() throws {
        let json = #"{"id":"r1","kind":"broadcast","name":"News"}"#
        let room = try JSONDecoder().decode(SidebarRoom.self, from: Data(json.utf8))
        #expect(room.room.kind == .unknown("broadcast"))
        #expect(room.room.kind != .open)
        #expect(room.room.kind != .closed)
        #expect(!room.room.isDirect)
        #expect(room.involvement == .mentions)
        #expect(try roundTrip(room.room).contains(#""kind":"broadcast""#))
    }

    @Test func anUnknownInvolvementIsKeptAndNeitherHidesNorQuietsTheRoom() throws {
        let json = #"{"id":"r1","kind":"open","name":"General","involvement":"digest"}"#
        let room = try JSONDecoder().decode(SidebarRoom.self, from: Data(json.utf8))
        #expect(room.involvement == .unknown("digest"))
        #expect(!RoomList.isHidden(room))
        #expect(room.involvement != .nothing)
        #expect(!Involvement.allCases.contains(room.involvement))
        #expect(try roundTrip(room.involvement) == "\"digest\"")
    }

    @Test func anUnknownSetupStateIsKeptAndIsNotPending() throws {
        let json = #"{"setup":"migrating","account":{"name":"Acme"}}"#
        let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: Data(json.utf8))
        #expect(bootstrap.setup == .unknown("migrating"))
        #expect(bootstrap.setup != .pending)
        #expect(try roundTrip(bootstrap.setup) == "\"migrating\"")
    }

    @Test func aKnownValueReadsAsItsCaseWhicheverWayItIsMade() throws {
        #expect(Role("administrator") == .administrator)
        #expect(Role(rawValue: "administrator") == .administrator)
        #expect(Role(rawValue: "overlord") == nil)
        #expect(Role("overlord").rawValue == "overlord")
        #expect(try JSONDecoder().decode(RoomKind.self, from: Data(#""direct""#.utf8)) == .direct)
        #expect(try roundTrip(Role.bot) == "\"bot\"")
    }

    @Test func aSidebarRoomIsTheRoomFlattened() throws {
        let json = #"{"id":"r1","kind":"open","name":"General","unread":true,"involvement":"everything"}"#
        let room = try JSONDecoder().decode(SidebarRoom.self, from: Data(json.utf8))
        #expect(room.room.name == "General")
        #expect(room.unread)
        #expect(room.involvement == .everything)
    }
}

private func roundTrip(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
