import Foundation
import Testing
@testable import EmberCore

@Suite struct ModelsTests {
    @Test func anUnknownRoleFallsBackRatherThanFailing() throws {
        let json = #"{"id":"u1","name":"Ada","role":"overlord","status":"active","avatarUrl":"/users/t/avatar"}"#
        let user = try JSONDecoder().decode(DirectoryUser.self, from: Data(json.utf8))
        #expect(user.role == .member)
    }

    @Test func aSidebarRoomIsTheRoomFlattened() throws {
        let json = #"{"id":"r1","kind":"open","name":"General","unread":true,"involvement":"everything"}"#
        let room = try JSONDecoder().decode(SidebarRoom.self, from: Data(json.utf8))
        #expect(room.room.name == "General")
        #expect(room.unread)
        #expect(room.involvement == .everything)
    }
}
