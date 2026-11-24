import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Sections and the rooms in them, a closed room's members, who a message would notify and pausing
/// notifications, as the client sends them.
@Suite struct SectionsClientTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    func refusal(_ call: () async throws -> Void) async -> EmberError? {
        do {
            try await call()
            return nil
        } catch {
            return error as? EmberError
        }
    }

    // MARK: Sections

    @Test func makesASection() async throws {
        let ops = RoomSection(id: "section-ops", name: "Ops")
        transport.stub("POST", "/api/account/sections", status: 201, json: Fixtures.sectionJSON(ops))
        #expect(try await client.makeSection(named: "Ops") == ops)
        let body = try #require(transport.lastBody("POST", "/api/account/sections"))
        #expect(body.count == 1 && body["name"] as? String == "Ops")

        transport.stub("POST", "/api/account/sections", status: 409, json: Fixtures.errorJSON("A section has that name already"))
        let taken = await refusal { _ = try await client.makeSection(named: "Ops") }
        #expect(taken == EmberError(status: 409, message: "A section has that name already"))
    }

    @Test func renamesASection() async throws {
        let renamed = RoomSection(id: Fixtures.product.id, name: "Products")
        transport.stub("PATCH", "/api/account/sections/section-product", json: Fixtures.sectionJSON(renamed))
        #expect(try await client.renameSection(Fixtures.product.id, to: "Products") == renamed)
        let body = try #require(transport.lastBody("PATCH", "/api/account/sections/section-product"))
        #expect(body.count == 1 && body["name"] as? String == "Products")

        transport.stub("PATCH", "/api/account/sections/section-gone", status: 404, json: Fixtures.errorJSON("Section not found"))
        let missing = await refusal { _ = try await client.renameSection("section-gone", to: "Ops") }
        #expect(missing == EmberError(status: 404, message: "Section not found"))
    }

    @Test func deletesASection() async throws {
        transport.stub("DELETE", "/api/account/sections/section-company", status: 204, json: "")
        try await client.deleteSection(Fixtures.company.id)
        #expect(transport.requests("DELETE", "/api/account/sections/section-company").count == 1)

        transport.stub("DELETE", "/api/account/sections/section-company", status: 403, json: Fixtures.errorJSON("Only administrators can change sections"))
        let forbidden = await refusal { try await client.deleteSection(Fixtures.company.id) }
        #expect(forbidden == EmberError(status: 403, message: "Only administrators can change sections"))
    }

    @Test func aSectionsIDCantReachAnotherRoute() async throws {
        transport.stub("DELETE", "/api/account/sections/..%2Froom_order", status: 204, json: "")
        try await client.deleteSection("../room_order")
        #expect(transport.requests("DELETE", "/api/account/sections/..%2Froom_order").count == 1)
    }

    // MARK: Layout

    @Test func putsRoomsAndSectionsInALayout() async throws {
        let saved = [
            SidebarSection(id: Fixtures.company.id, name: "Company", roomIds: [Fixtures.general.id]),
            SidebarSection(id: Fixtures.product.id, name: "Product", roomIds: [Fixtures.engines.id]),
        ]
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([Fixtures.general.id, Fixtures.engines.id], sections: saved))
        let layout = RoomLayout(roomIds: [Fixtures.general.id, Fixtures.engines.id], sections: [
            RoomLayout.Placement(id: Fixtures.company.id, roomIds: [Fixtures.general.id]),
            RoomLayout.Placement(id: Fixtures.product.id, roomIds: [Fixtures.engines.id]),
        ])
        let answer = try await client.setRoomLayout(layout)
        #expect(answer == SavedRoomLayout(sharedOrder: [Fixtures.general.id, Fixtures.engines.id], sections: saved))

        let body = try #require(transport.lastBody("PUT", "/api/account/room_order"))
        #expect(body.keys.sorted() == ["roomIds", "sections"])
        #expect(body["roomIds"] as? [String] == ["room-general", "room-engines"])
        let sections = try #require(body["sections"] as? [[String: Any]])
        #expect(sections.map { $0["id"] as? String } == ["section-company", "section-product"])
        #expect(sections.map { $0["roomIds"] as? [String] } == [["room-general"], ["room-engines"]])
    }

    @Test func anOrderAloneLeavesTheSectionsOut() async throws {
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([Fixtures.general.id], sections: Fixtures.sidebarSections))
        #expect(try await client.setSharedOrder([Fixtures.general.id]) == [Fixtures.general.id])
        let body = try #require(transport.lastBody("PUT", "/api/account/room_order"))
        #expect(body.keys.sorted() == ["roomIds"])

        // A layout that empties every section still says so.
        _ = try await client.setRoomLayout(RoomLayout(roomIds: [Fixtures.general.id], sections: []))
        let emptied = try #require(transport.lastBody("PUT", "/api/account/room_order"))
        #expect(emptied["sections"] as? [[String: Any]] != nil)
    }

    @Test func aServerFromBeforeSectionsAnswersTheOrderAlone() async throws {
        transport.stub("PUT", "/api/account/room_order", json: #"{"sharedOrder":["room-general"]}"#)
        let answer = try await client.setRoomLayout(RoomLayout(roomIds: [Fixtures.general.id]))
        #expect(answer == SavedRoomLayout(sharedOrder: [Fixtures.general.id]))
    }

    // MARK: Rooms in sections

    @Test func aNewRoomSaysItsSection() async throws {
        let created = Room(id: "room-looms", kind: .open, name: "Looms")
        transport.stub("POST", "/api/rooms", status: 201, json: Fixtures.roomJSON(created))

        _ = try await client.createRoom(NewRoom(name: "Looms", section: .section(Fixtures.product.id)))
        #expect(transport.lastBody("POST", "/api/rooms")?["section"] as? String == "section-product")

        _ = try await client.createRoom(NewRoom(name: "Looms", section: .new(name: "Ops")))
        #expect(transport.lastBody("POST", "/api/rooms")?["section"] as? [String: String] == ["name": "Ops"])

        _ = try await client.createRoom(NewRoom(name: "Looms"))
        #expect(transport.lastBody("POST", "/api/rooms")?["section"] == nil)
    }

    @Test func aRoomIsMovedToASectionOrOutOfOne() async throws {
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(Fixtures.engines))

        _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(section: .section(Fixtures.company.id)))
        let moved = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(moved.keys.sorted() == ["section"])
        #expect(moved["section"] as? String == "section-company")

        // Out of every section is said with null, where saying nothing leaves the room where it is.
        _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(section: .noSection))
        let loose = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(loose.keys.sorted() == ["section"])
        #expect(loose["section"] is NSNull)

        _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(name: "Engines", section: .new(name: "Ops")))
        let made = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(made.keys.sorted() == ["name", "section"])
        #expect(made["section"] as? [String: String] == ["name": "Ops"])
    }

    @Test func aRoomsChannelMentionsAreTurnedOffAndOn() async throws {
        transport.stub("PATCH", "/api/rooms/room-engines", json: #"{"room":{"id":"room-engines","kind":"closed","name":"Engines","icon":"cog","channelMentions":false}}"#)
        let saved = try await client.changeRoom(Fixtures.engines.id, RoomChanges(channelMentions: false))
        #expect(saved.channelMentions == false && !saved.allowsChannelMentions)
        let off = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(off.keys.sorted() == ["channelMentions"])
        #expect(off["channelMentions"] as? Bool == false)

        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(Fixtures.engines))
        #expect(try await client.changeRoom(Fixtures.engines.id, RoomChanges(channelMentions: true)).allowsChannelMentions)
        #expect(transport.lastBody("PATCH", "/api/rooms/room-engines")?["channelMentions"] as? Bool == true)
    }

    @Test func theFormsOfferTheSections() async throws {
        transport.stub("GET", "/api/rooms/new", json: Fixtures.newRoomFormJSON(sections: Fixtures.sectionOptions))
        #expect(try await client.newRoomForm().sections == Fixtures.sectionOptions)

        transport.stub("GET", "/api/rooms/room-engines/settings", json: Fixtures.roomSettingsJSON(
            canChangeChannelMentions: false, section: Fixtures.product, sections: Fixtures.sectionOptions
        ))
        let settings = try await client.roomSettings(Fixtures.engines.id)
        #expect(settings.section == Fixtures.product)
        #expect(settings.sections == Fixtures.sectionOptions)
        #expect(settings.canAdminister && !settings.canChangeChannelMentions)

        // A room in no section, read by someone who can't change it.
        transport.stub("GET", "/api/rooms/room-general/settings", json: Fixtures.roomSettingsJSON(Fixtures.general, canAdminister: false))
        let loose = try await client.roomSettings(Fixtures.general.id)
        #expect(loose.section == nil && loose.sections.isEmpty)
    }

    // MARK: Members

    @Test func putsPeopleInAndTakesPeopleOut() async throws {
        transport.stub("PATCH", "/api/rooms/room-engines/members", json: Fixtures.roomJSON(Fixtures.engines))
        let room = try await client.changeMembers(of: Fixtures.engines.id, adding: [Fixtures.alan.id], removing: [Fixtures.grace.id])
        #expect(room == Fixtures.engines)
        let body = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines/members"))
        #expect(body.keys.sorted() == ["addedIds", "removedIds"])
        #expect(body["addedIds"] as? [String] == ["user_alan"])
        #expect(body["removedIds"] as? [String] == ["user_grace"])
    }

    @Test func aChangeOneWayChangesNobodyTheOther() async throws {
        transport.stub("PATCH", "/api/rooms/room-engines/members", json: Fixtures.roomJSON(Fixtures.engines))
        _ = try await client.changeMembers(of: Fixtures.engines.id, adding: [Fixtures.alan.id])
        let added = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines/members"))
        #expect(added["addedIds"] as? [String] == ["user_alan"] && added["removedIds"] as? [String] == [])
        _ = try await client.changeMembers(of: Fixtures.engines.id, removing: [Fixtures.grace.id])
        let removed = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines/members"))
        #expect(removed["addedIds"] as? [String] == [] && removed["removedIds"] as? [String] == ["user_grace"])
    }

    @Test func anOpenRoomsMembersCantBeChanged() async {
        transport.stub("PATCH", "/api/rooms/room-general/members", status: 409, json: Fixtures.errorJSON("Everyone is in an open room"))
        let refused = await refusal { _ = try await client.changeMembers(of: Fixtures.general.id, adding: [Fixtures.alan.id]) }
        #expect(refused == EmberError(status: 409, message: "Everyone is in an open room"))
    }

    // MARK: Who a message would notify

    @Test func readsWhoARoomsMentionsWouldNotify() async throws {
        transport.stub("GET", "/api/rooms/room-general/notified", json: Fixtures.notifiedJSON())
        let counts = try await client.notified(in: Fixtures.general.id)
        #expect(counts == NotifiedCounts(members: 8, mentions: [.here: 3, .channel: 7, .everyone: 12]))
        #expect(counts.notifying([.here, .channel]) == Notifying(mention: .channel, people: 7))

        // A DM, where they notify nobody.
        transport.stub("GET", "/api/rooms/dm-grace/notified", json: Fixtures.notifiedJSON(members: 2, mentions: [:]))
        let direct = try await client.notified(in: "dm-grace")
        #expect(direct == NotifiedCounts(members: 2) && direct.notifying([.channel]) == nil)

        transport.stub("GET", "/api/rooms/room-gone/notified", status: 404, json: Fixtures.errorJSON("Room not found"))
        let missing = await refusal { _ = try await client.notified(in: "room-gone") }
        #expect(missing == EmberError(status: 404, message: "Room not found"))
    }

    // MARK: Pausing notifications

    @Test func pausesUntilATime() async throws {
        let until = try #require(EmberJSON.date(from: "2026-10-12T18:00:00.000Z"))
        let paused = Fixtures.paused(Fixtures.people[0], until: until)
        transport.stub("PUT", "/api/users/me/notifications-pause", json: Fixtures.changedPersonJSON(paused))
        let answer = try await client.pauseNotifications(until: until)
        #expect(answer == paused && answer.pausedUntil == until)
        let body = try #require(transport.lastBody("PUT", "/api/users/me/notifications-pause"))
        #expect(body.count == 1 && body["until"] as? String == "2026-10-12T18:00:00.000Z")
    }

    @Test func resumesWithNull() async throws {
        transport.stub("PUT", "/api/users/me/notifications-pause", json: Fixtures.changedPersonJSON(Fixtures.people[0]))
        #expect(try await client.pauseNotifications(until: nil).pausedUntil == nil)
        let body = try #require(transport.lastBody("PUT", "/api/users/me/notifications-pause"))
        #expect(body.count == 1 && body["until"] is NSNull)
    }

    @Test func aPauseTooLongIsRefused() async {
        transport.stub("PUT", "/api/users/me/notifications-pause", status: 422, json: Fixtures.errorJSON("Pause for up to 7 days"))
        let refused = await refusal { _ = try await client.pauseNotifications(until: Date(timeIntervalSince1970: 0)) }
        #expect(refused == EmberError(status: 422, message: "Pause for up to 7 days"))
    }
}
