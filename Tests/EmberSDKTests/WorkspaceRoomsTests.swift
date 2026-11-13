import EmberTesting
import Foundation
import Testing

/// Creating, changing and deleting rooms, putting the sidebar in order and dismissing the invitation,
/// as the workspace shows them, and the frames that follow agreeing with what it showed.
@MainActor @Suite struct WorkspaceRoomsTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let workspace: Workspace

    /// Both shared rooms starred, General first.
    static let bothStarred = Favorites(rooms: [Fixtures.general.id, Fixtures.engines.id], version: 3)

    init() {
        let (timing, _) = manualTiming()
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    func started(sidebar: String? = nil) async throws {
        if let sidebar { transport.stub("GET", "/api/sidebar", json: sidebar) }
        workspace.start()
        try #require(await eventually { workspace.isLoaded && transport.requests("GET", "/api/sidebar").count >= 2 })
        await workspace.reload()
    }

    var sidebarLoads: Int { transport.requests("GET", "/api/sidebar").count }

    // MARK: Rooms

    @Test func aCreatedClosedRoomHasYouAndJoinsTheSidebar() async throws {
        try await started()
        let looms = Room(id: "room-looms", kind: .closed, name: "Looms")
        transport.stub("POST", "/api/rooms", status: 201, json: Fixtures.roomJSON(looms))
        let room = try await workspace.createRoom(NewRoom(name: "Looms", access: .closed(memberIDs: [Fixtures.grace.id])))
        #expect(room.id == looms.id)
        #expect(transport.lastBody("POST", "/api/rooms")?["memberIds"] as? [String] == ["user_ada", "user_grace"])
        #expect(workspace.room(looms.id)?.room == looms)
        #expect(workspace.sharedRooms.contains { $0.id == looms.id })

        // Its room.saved frame doesn't add it twice.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomSaved(looms))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomRead(looms.id))
        #expect(await eventually { workspace.room(looms.id)?.unread == false })
        #expect(workspace.rooms.filter { $0.id == looms.id }.count == 1)
    }

    @Test func aRefusedRoomIsntAdded() async throws {
        try await started()
        transport.stub("POST", "/api/rooms", status: 422, json: Fixtures.errorJSON("Name can’t be blank"))
        await #expect(throws: EmberError(status: 422, message: "Name can’t be blank")) {
            _ = try await workspace.createRoom(NewRoom(name: ""))
        }
        #expect(workspace.rooms.count == Fixtures.sidebarRooms.count)
    }

    @Test func aChangedRoomIsChanged() async throws {
        try await started()
        let renamed = Room(id: Fixtures.engines.id, kind: .closed, name: "Difference Engines", icon: "cog")
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(renamed))
        try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(name: "Difference Engines"))
        #expect(workspace.room(Fixtures.engines.id)?.room.name == "Difference Engines")
    }

    @Test func closingARoomWithoutYouLeavesIt() async throws {
        try await started()
        let closed = Room(id: Fixtures.engines.id, kind: .closed, name: Fixtures.engines.name, icon: "cog")
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(closed))
        try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(access: .closed(memberIDs: [Fixtures.grace.id])))
        #expect(workspace.room(Fixtures.engines.id) == nil)

        // The room.gone frame the server sends you agrees.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomGone(Fixtures.engines.id))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomRead(Fixtures.general.id))
        #expect(await eventually { workspace.room(Fixtures.general.id)?.unread == false })
        #expect(workspace.room(Fixtures.engines.id) == nil)
    }

    @Test func aDeletedRoomLeavesTheSidebar() async throws {
        try await started()
        transport.stub("DELETE", "/api/rooms/room-engines", status: 204, json: "")
        try await workspace.deleteRoom(Fixtures.engines.id)
        #expect(workspace.room(Fixtures.engines.id) == nil)
        #expect(!workspace.roomsInSharedOrder.contains { $0.id == Fixtures.engines.id })
    }

    @Test func aRefusedDeleteKeepsTheRoom() async throws {
        try await started()
        transport.stub("DELETE", "/api/rooms/room-engines", status: 403, json: Fixtures.errorJSON("Only administrators and the room's creator can delete it"))
        await #expect(throws: EmberError.self) { try await workspace.deleteRoom(Fixtures.engines.id) }
        #expect(workspace.room(Fixtures.engines.id) != nil)
    }

    // MARK: Stars

    @Test func movedStarsShowAtOnceAndStayWhenAnswered() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(favorites: Self.bothStarred))
        #expect(workspace.favoriteRooms.map(\.id) == [Fixtures.general.id, Fixtures.engines.id])
        let answer = Favorites(rooms: [Fixtures.engines.id, Fixtures.general.id], version: 4)
        let gate = transport.hold("PUT", "/api/sidebar/order")
        transport.stub("PUT", "/api/sidebar/order", json: Fixtures.favoritesJSON(answer))

        let moving = Task { await workspace.moveFavorites(fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        await gate.waitForRequest()
        #expect(workspace.favoriteRooms.map(\.id) == [Fixtures.engines.id, Fixtures.general.id])
        #expect(transport.lastBody("PUT", "/api/sidebar/order")?["roomIds"] as? [String] == ["room-engines", "room-general"])

        // A sidebar read before the move doesn't undo it.
        await workspace.reload()
        #expect(workspace.favoriteRooms.map(\.id) == [Fixtures.engines.id, Fixtures.general.id])

        gate.release()
        await moving.value
        #expect(workspace.favorites == answer)
        #expect(workspace.notice == nil)
    }

    @Test func theFrameForAMoveAgreesWithIt() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(favorites: Self.bothStarred))
        let answer = Favorites(rooms: [Fixtures.engines.id, Fixtures.general.id], version: 4)
        let gate = transport.hold("PUT", "/api/sidebar/order")
        transport.stub("PUT", "/api/sidebar/order", json: Fixtures.favoritesJSON(answer))

        var seen: [[RoomID]] = []
        let moving = Task { await workspace.moveFavorites(fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        await gate.waitForRequest()
        seen.append(workspace.favoriteRooms.map(\.id))

        // The frame lands before the answer, then an older one late: neither moves anything.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.favoritesChanged(answer))
        #expect(await eventually { workspace.favorites.version == 4 })
        seen.append(workspace.favoriteRooms.map(\.id))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.favoritesChanged(Self.bothStarred))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomRead(Fixtures.general.id))
        #expect(await eventually { workspace.room(Fixtures.general.id)?.unread == false })
        seen.append(workspace.favoriteRooms.map(\.id))

        gate.release()
        await moving.value
        seen.append(workspace.favoriteRooms.map(\.id))
        #expect(seen == Array(repeating: [Fixtures.engines.id, Fixtures.general.id], count: 4))
        #expect(workspace.favorites == answer)
    }

    @Test func aRefusedMoveIsPutBack() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(favorites: Self.bothStarred))
        let loads = sidebarLoads
        transport.stub("PUT", "/api/sidebar/order", status: 403, json: Fixtures.errorJSON("Those aren't the rooms you've starred"))
        await workspace.moveFavorites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(workspace.favoriteRooms.map(\.id) == [Fixtures.general.id, Fixtures.engines.id])
        #expect(workspace.favorites == Self.bothStarred)
        #expect(workspace.notice == "Those aren't the rooms you've starred")
        #expect(sidebarLoads == loads + 1)
    }

    @Test func aMoveThatChangesNothingSendsNothing() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(favorites: Self.bothStarred))
        await workspace.moveFavorites(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(transport.requests("PUT", "/api/sidebar/order").isEmpty)
    }

    // MARK: The shared order

    @Test func movedSharedRoomsShowAtOnceAndStay() async throws {
        try await started()
        #expect(workspace.roomsInSharedOrder.map(\.id) == [Fixtures.engines.id, Fixtures.general.id])
        let moved = [Fixtures.general.id, Fixtures.engines.id]
        let gate = transport.hold("PUT", "/api/account/room_order")
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON(moved))

        let moving = Task { await workspace.moveSharedRooms(fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        await gate.waitForRequest()
        #expect(workspace.sharedOrder == moved)
        #expect(workspace.roomsInSharedOrder.map(\.id) == moved)
        #expect(transport.lastBody("PUT", "/api/account/room_order")?["roomIds"] as? [String] == ["room-general", "room-engines"])

        // A sidebar read before the move doesn't undo it.
        await workspace.reload()
        #expect(workspace.sharedOrder == moved)

        gate.release()
        await moving.value
        #expect(workspace.sharedOrder == moved)

        // rooms.reordered loads the sidebar again, which now has the order too.
        let loads = sidebarLoads
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sharedOrder: moved))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomsReordered)
        #expect(await eventually { sidebarLoads > loads })
        await workspace.reload()
        #expect(workspace.sharedOrder == moved)
        #expect(workspace.notice == nil)
    }

    @Test func aRefusedSharedMoveIsPutBack() async throws {
        try await started()
        let loads = sidebarLoads
        transport.stub("PUT", "/api/account/room_order", status: 403, json: Fixtures.errorJSON("Only administrators can put rooms in order for everyone"))
        await workspace.moveSharedRooms(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(workspace.sharedOrder == [Fixtures.engines.id, Fixtures.general.id])
        #expect(workspace.roomsInSharedOrder.map(\.id) == [Fixtures.engines.id, Fixtures.general.id])
        #expect(workspace.notice == "Only administrators can put rooms in order for everyone")
        #expect(sidebarLoads == loads + 1)
    }

    @Test func clearingTheSharedOrderSendsNothingToRank() async throws {
        try await started()
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([]))
        await workspace.clearSharedOrder()
        #expect(transport.lastBody("PUT", "/api/account/room_order")?["roomIds"] as? [String] == [])
        #expect(workspace.sharedOrder.isEmpty)
        #expect(workspace.notice == nil)
    }

    // MARK: The invitation

    @Test func aDismissedInvitationGoesAtOnceAndStaysGone() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(invitation: Fixtures.invitation))
        #expect(workspace.invitation == Fixtures.invitation)
        let gate = transport.hold("DELETE", "/api/sidebar/invitation")
        transport.stub("DELETE", "/api/sidebar/invitation", status: 204, json: "")

        let dismissing = Task { await workspace.dismissInvitation() }
        await gate.waitForRequest()
        #expect(workspace.invitation == nil)

        // A sidebar read before the dismissal doesn't bring it back.
        await workspace.reload()
        #expect(workspace.invitation == nil)

        gate.release()
        await dismissing.value
        #expect(workspace.invitation == nil)

        // Its frame agrees, and so does a sidebar read after it.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.invitationDismissed)
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON())
        await workspace.reload()
        #expect(workspace.invitation == nil)
        #expect(workspace.notice == nil)
    }

    @Test func aRefusedDismissalBringsTheInvitationBack() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(invitation: Fixtures.invitation))
        transport.stub("DELETE", "/api/sidebar/invitation", status: 403, json: Fixtures.errorJSON("Only administrators can do that"))
        await workspace.dismissInvitation()
        #expect(workspace.invitation == Fixtures.invitation)
        #expect(workspace.notice == "Only administrators can do that")
    }

    @Test func anInvitationDismissedElsewhereGoes() async throws {
        try await started(sidebar: Fixtures.sidebarJSON(invitation: Fixtures.invitation))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.invitationDismissed)
        #expect(await eventually { workspace.invitation == nil })
    }

    @Test func dismissingNoInvitationSendsNothing() async throws {
        try await started()
        await workspace.dismissInvitation()
        #expect(transport.requests("DELETE", "/api/sidebar/invitation").isEmpty)
    }
}
