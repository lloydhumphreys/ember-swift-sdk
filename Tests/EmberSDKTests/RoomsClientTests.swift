import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Creating, changing and deleting rooms, the sidebar's orders, and link previews, as the client sends them.
@Suite struct RoomsClientTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    func refusal(_ status: Int, _ message: String, _ call: () async throws -> Void) async -> EmberError? {
        do {
            try await call()
            return nil
        } catch {
            return error as? EmberError
        }
    }

    // MARK: Rooms

    @Test func readsWhoANewRoomCanHave() async throws {
        transport.stub("GET", "/api/rooms/new", json: Fixtures.newRoomFormJSON())
        let form = try await client.newRoomForm()
        #expect(form.people == [Fixtures.ada, Fixtures.alan, Fixtures.grace])
    }

    @Test func createsAnOpenRoom() async throws {
        let created = Room(id: "room-looms", kind: .open, name: "Looms")
        transport.stub("POST", "/api/rooms", status: 201, json: Fixtures.roomJSON(created))
        let room = try await client.createRoom(NewRoom(name: "Looms"))
        #expect(room == created)
        let body = try #require(transport.lastBody("POST", "/api/rooms"))
        #expect(body.count == 2)
        #expect(body["name"] as? String == "Looms")
        #expect(body["kind"] as? String == "open")
    }

    @Test func createsAClosedRoomWithItsMembersAndIcon() async throws {
        let created = Room(id: "room-looms", kind: .closed, name: "Looms", icon: "cog")
        transport.stub("POST", "/api/rooms", status: 201, json: Fixtures.roomJSON(created))
        _ = try await client.createRoom(NewRoom(name: "Looms", icon: "cog", access: .closed(memberIDs: [Fixtures.ada.id, Fixtures.grace.id])))
        let body = try #require(transport.lastBody("POST", "/api/rooms"))
        #expect(body["kind"] as? String == "closed")
        #expect(body["icon"] as? String == "cog")
        #expect(body["memberIds"] as? [String] == ["user_ada", "user_grace"])
    }

    @Test func roomRefusalsReachTheError() async {
        transport.stub("POST", "/api/rooms", status: 403, json: Fixtures.errorJSON("Only administrators can create rooms"))
        let forbidden = await refusal(403, "") { _ = try await client.createRoom(NewRoom(name: "Looms")) }
        #expect(forbidden == EmberError(status: 403, message: "Only administrators can create rooms"))

        transport.stub("GET", "/api/rooms/room-gone/settings", status: 404, json: Fixtures.errorJSON("Room not found"))
        let missing = await refusal(404, "") { _ = try await client.roomSettings("room-gone") }
        #expect(missing == EmberError(status: 404, message: "Room not found"))

        transport.stub("PATCH", "/api/rooms/room-engines", status: 422, json: Fixtures.errorJSON("Name can’t be blank"))
        let invalid = await refusal(422, "") { _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(name: "")) }
        #expect(invalid == EmberError(status: 422, message: "Name can’t be blank"))
    }

    @Test func readsARoomsSettings() async throws {
        transport.stub("GET", "/api/rooms/room-engines/settings", json: Fixtures.roomSettingsJSON())
        let settings = try await client.roomSettings(Fixtures.engines.id)
        #expect(settings.room == Fixtures.engines)
        #expect(settings.canAdminister)
        #expect(settings.people.map(\.id) == [Fixtures.ada.id, Fixtures.alan.id, Fixtures.grace.id])
        #expect(settings.people.map(\.member) == [true, false, true])
        #expect(settings.people[1].user == Fixtures.alan)
    }

    @Test func aRoomWithNoIconReadsAsNone() async throws {
        let plain = Room(id: "room-plain", kind: .open, name: "Plain")
        transport.stub("GET", "/api/rooms/room-plain/settings", json: Fixtures.roomSettingsJSON(plain))
        #expect(try await client.roomSettings(plain.id).room.icon == nil)
    }

    @Test func changesOnlyWhatsGiven() async throws {
        let renamed = Room(id: Fixtures.engines.id, kind: .closed, name: "Difference Engines", icon: "cog")
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(renamed))
        let room = try await client.changeRoom(Fixtures.engines.id, RoomChanges(name: "Difference Engines"))
        #expect(room == renamed)
        let body = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(body.keys.sorted() == ["name"])

        _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(icon: "", access: .open))
        let opened = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(opened.keys.sorted() == ["icon", "kind"])
        #expect(opened["icon"] as? String == "")
        #expect(opened["kind"] as? String == "open")

        _ = try await client.changeRoom(Fixtures.engines.id, RoomChanges(access: .closed(memberIDs: [Fixtures.grace.id])))
        let closed = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines"))
        #expect(closed["kind"] as? String == "closed")
        #expect(closed["memberIds"] as? [String] == ["user_grace"])
    }

    @Test func deletesARoom() async throws {
        transport.stub("DELETE", "/api/rooms/room-engines", status: 204, json: "")
        try await client.deleteRoom(Fixtures.engines.id)
        #expect(transport.requests("DELETE", "/api/rooms/room-engines").count == 1)

        transport.stub("DELETE", "/api/rooms/room-general", status: 403, json: Fixtures.errorJSON("Only administrators and the room's creator can delete it"))
        let error = await refusal(403, "") { try await client.deleteRoom(Fixtures.general.id) }
        #expect(error?.status == 403)
        #expect(error?.message == "Only administrators and the room's creator can delete it")
    }

    // MARK: Sidebar order

    @Test func putsStarsInOrder() async throws {
        let answer = Favorites(rooms: [Fixtures.engines.id, Fixtures.general.id], version: 4)
        transport.stub("PUT", "/api/sidebar/order", json: Fixtures.favoritesJSON(answer))
        let favorites = try await client.setFavoriteOrder([Fixtures.engines.id, Fixtures.general.id])
        #expect(favorites == answer)
        let body = try #require(transport.lastBody("PUT", "/api/sidebar/order"))
        #expect(body["roomIds"] as? [String] == ["room-engines", "room-general"])

        transport.stub("PUT", "/api/sidebar/order", status: 403, json: Fixtures.errorJSON("Those aren't the rooms you've starred"))
        let error = await refusal(403, "") { _ = try await client.setFavoriteOrder([Fixtures.engines.id]) }
        #expect(error == EmberError(status: 403, message: "Those aren't the rooms you've starred"))
    }

    @Test func putsSharedRoomsInOrderAndClearsIt() async throws {
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([Fixtures.general.id, Fixtures.engines.id]))
        let order = try await client.setSharedOrder([Fixtures.general.id, Fixtures.engines.id])
        #expect(order == [Fixtures.general.id, Fixtures.engines.id])
        #expect(transport.lastBody("PUT", "/api/account/room_order")?["roomIds"] as? [String] == ["room-general", "room-engines"])

        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([]))
        #expect(try await client.setSharedOrder([]).isEmpty)
        #expect(transport.lastBody("PUT", "/api/account/room_order")?["roomIds"] as? [String] == [])

        transport.stub("PUT", "/api/account/room_order", status: 403, json: Fixtures.errorJSON("Only administrators can put rooms in order for everyone"))
        let error = await refusal(403, "") { _ = try await client.setSharedOrder([Fixtures.general.id]) }
        #expect(error?.status == 403)
        #expect(error?.message == "Only administrators can put rooms in order for everyone")
    }

    @Test func dismissesTheInvitation() async throws {
        transport.stub("DELETE", "/api/sidebar/invitation", status: 204, json: "")
        try await client.dismissInvitation()
        #expect(transport.requests("DELETE", "/api/sidebar/invitation").count == 1)
    }

    // MARK: Link previews

    @Test func readsALinksPreview() async throws {
        transport.stub("POST", "/api/unfurl", json: Fixtures.linkPreviewJSON())
        let preview = try await client.linkPreview(for: URL(string: "https://example.com/engine")!)
        #expect(preview == Fixtures.linkPreview)
        #expect(transport.lastBody("POST", "/api/unfurl")?["url"] as? String == "https://example.com/engine")
    }

    @Test func aLinkWithoutAPreviewIsNil() async throws {
        transport.stub("POST", "/api/unfurl", status: 204, json: "")
        #expect(try await client.linkPreview(for: URL(string: "https://example.com/")!) == nil)
    }

    @Test func aPreviewWithoutATitleIsNil() async throws {
        transport.stub("POST", "/api/unfurl", json: #"{"title":"","url":"https://example.com/","image":null,"description":"D"}"#)
        #expect(try await client.linkPreview(for: URL(string: "https://example.com/")!) == nil)
        transport.stub("POST", "/api/unfurl", json: #"{"url":"https://example.com/"}"#)
        #expect(try await client.linkPreview(for: URL(string: "https://example.com/")!) == nil)
    }

    @Test func aPreviewWithNoImageOrDescriptionReads() async throws {
        transport.stub("POST", "/api/unfurl", json: #"{"title":"T","url":"https://example.com/","image":null}"#)
        let preview = try await client.linkPreview(for: URL(string: "https://example.com/")!)
        #expect(preview == LinkPreview(title: "T", url: "https://example.com/"))
    }

    @Test func tooManyPreviewsIsRefused() async {
        transport.stub("POST", "/api/unfurl", status: 429, json: Fixtures.errorJSON("Too many link previews. Try again in a minute."))
        let error = await refusal(429, "") { _ = try await client.linkPreview(for: URL(string: "https://example.com/")!) }
        #expect(error?.status == 429)
        #expect(error?.message == "Too many link previews. Try again in a minute.")
    }
}
