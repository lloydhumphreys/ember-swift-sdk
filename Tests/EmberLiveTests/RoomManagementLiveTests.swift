import EmberSDK
import Foundation
import Testing

/// Making, changing and deleting rooms, the sidebar's orders, the invitation card and link
/// previews. Each test makes its own room and deletes it, and puts any order back as it found it.
extension LiveTests {
    func uniqueRoomName() -> String {
        "Live \(UUID().uuidString.prefix(8).lowercased())"
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func makesChangesAndDeletesARoom() async throws {
        let client = try await signedIn()
        let me = try await client.me()
        let form = try await client.newRoomForm()
        #expect(!form.people.isEmpty)
        let someoneElse = try #require(form.people.first { $0.id != me.id })

        let name = uniqueRoomName()
        let room = try await client.createRoom(NewRoom(name: name))
        var deleted = false
        try await afterwards({ if !deleted { try await client.deleteRoom(room.id) } }) {
            #expect(room.name == name)
            #expect(room.kind == .open)
            #expect(try await client.sidebar().rooms.contains { $0.id == room.id })

            let settings = try await client.roomSettings(room.id)
            #expect(settings.room.id == room.id)
            #expect(settings.canAdminister)
            #expect(settings.people.contains { $0.id == me.id && $0.member })

            let renamed = try await client.changeRoom(room.id, RoomChanges(name: name + " renamed", icon: "rocket"))
            #expect(renamed.name == name + " renamed")
            #expect(renamed.icon == "rocket")

            let closed = try await client.changeRoom(room.id, RoomChanges(access: .closed(memberIDs: [me.id, someoneElse.id])))
            #expect(closed.kind == .closed)
            let members = try await client.roomSettings(room.id).people.filter(\.member).map(\.id)
            #expect(Set(members) == [me.id, someoneElse.id])

            try await client.deleteRoom(room.id)
            deleted = true
            #expect(try await client.sidebar().rooms.contains { $0.id == room.id } == false)
            let error = await #expect(throws: EmberError.self) { try await client.roomSettings(room.id) }
            #expect(error?.status == 404)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aWorkspaceMakesChangesAndDeletesAClosedRoom() async throws {
        let client = try await signedIn()
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let me = workspace.me

        let name = uniqueRoomName()
        // Closed with no one listed: the workspace puts me in it.
        let made = try await workspace.createRoom(NewRoom(name: name, access: .closed(memberIDs: [])))
        var deleted = false
        try await afterwards({ if !deleted { try await client.deleteRoom(made.id) } }) {
            #expect(made.room.kind == .closed)
            #expect(workspace.room(made.id) != nil)
            #expect(try await client.roomSettings(made.id).people.contains { $0.id == me.id && $0.member })

            let changed = try await workspace.changeRoom(made.id, RoomChanges(name: name + " changed"))
            #expect(changed.name == name + " changed")
            #expect(workspace.room(made.id)?.room.name == name + " changed")

            try await workspace.deleteRoom(made.id)
            deleted = true
            #expect(workspace.room(made.id) == nil)
            #expect(try await client.sidebar().rooms.contains { $0.id == made.id } == false)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func movesFavoritesAndPutsThemBack() async throws {
        let client = try await signedIn()
        let general = try await general(on: client)
        let before = try await client.sidebar().favorites.rooms
        let generalWasStarred = before.contains(general.id)
        if !generalWasStarred { _ = try await client.setFavorite(true, roomID: general.id) }
        let starred = try await client.sidebar().favorites.rooms
        try #require(starred.count >= 2, "Needs two starred rooms: Launch is starred in the seed.")

        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        try await afterwards({
            _ = try await client.setFavoriteOrder(starred)
            if !generalWasStarred { _ = try await client.setFavorite(false, roomID: general.id) }
        }) {
            let shown = workspace.favoriteRooms.map(\.id)
            #expect(Set(shown) == Set(starred))
            await workspace.moveFavorites(fromOffsets: [0], toOffset: shown.count)
            let moved = Array(shown.dropFirst()) + [shown[0]]
            #expect(workspace.notice == nil)
            #expect(workspace.favoriteRooms.map(\.id) == moved)
            let saved = try await client.sidebar().favorites.rooms.filter { shown.contains($0) }
            #expect(saved == moved)

            // A list that isn't my stars is refused.
            let error = await #expect(throws: EmberError.self) { try await client.setFavoriteOrder([general.id]) }
            #expect(error?.status == 403)
        }
        #expect(try await client.sidebar().favorites.rooms == before)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func movesAndClearsTheSharedOrderAndPutsItBack() async throws {
        let client = try await signedIn()
        let original = try await client.sidebar().sharedOrder
        try #require(!original.isEmpty, "The seed has a shared order.")
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }

        try await afterwards({ _ = try await client.setSharedOrder(original) }) {
            let shown = workspace.roomsInSharedOrder.map(\.id)
            try #require(shown.count >= 2)
            await workspace.moveSharedRooms(fromOffsets: [0], toOffset: 2)
            var moved = shown
            moved.swapAt(0, 1)
            #expect(workspace.notice == nil)
            #expect(workspace.roomsInSharedOrder.map(\.id) == moved)
            #expect(try await client.sidebar().sharedOrder == moved)

            await workspace.clearSharedOrder()
            #expect(workspace.notice == nil)
            #expect(workspace.sharedOrder.isEmpty)
            #expect(try await client.sidebar().sharedOrder.isEmpty)
        }
        #expect(try await client.sidebar().sharedOrder == original)
        #expect(await eventually { workspace.sharedOrder == original })
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func clearingTheSharedOrderWithRoomsMadeSinceListsThemByNameAndStays() async throws {
        let client = try await signedIn()
        let original = try await client.sidebar().sharedOrder
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let open = try await workspace.createRoom(NewRoom(name: uniqueRoomName()))
        let closed = try await workspace.createRoom(NewRoom(name: uniqueRoomName(), access: .closed(memberIDs: [])))

        try await afterwards({
            try? await client.deleteRoom(open.id)
            try? await client.deleteRoom(closed.id)
            _ = try await client.setSharedOrder(original)
        }) {
            await workspace.moveSharedRooms(fromOffsets: [0], toOffset: 2)
            #expect(workspace.notice == nil)
            #expect(!workspace.sharedOrder.isEmpty)

            await workspace.clearSharedOrder()
            #expect(workspace.notice == nil)
            #expect(workspace.sharedOrder.isEmpty)
            let byName = workspace.roomsInSharedOrder.map { ($0.room.name ?? "").lowercased() }
            #expect(byName == byName.sorted { $0.compare($1, locale: .current) == .orderedAscending })

            // rooms.reordered loads the sidebar again, which keeps it cleared.
            await workspace.reload()
            #expect(workspace.sharedOrder.isEmpty)
            let saved = try await client.sidebar().sharedOrder
            #expect(saved.isEmpty)
        }
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func someoneWhoIsntAnAdministratorCantSetTheSharedOrder() async throws {
        let client = try await signedIn(as: "sam@example.com")
        let order = try await client.sidebar().sharedOrder
        let error = await #expect(throws: EmberError.self) { try await client.setSharedOrder(order) }
        #expect(error?.status == 403)
        #expect(try await client.sidebar().sharedOrder == order)
    }

    /// Dismissing is for good on that server, so this can only pass once per start of the stand-in.
    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func dismissesTheInvitationCard() async throws {
        let client = try await signedIn()
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let invitation = try #require(workspace.invitation, "Already dismissed: start the stand-in again.")
        #expect(workspace.room(invitation.roomId) != nil)

        await workspace.dismissInvitation()
        #expect(workspace.notice == nil)
        #expect(workspace.invitation == nil)
        #expect(try await client.sidebar().invitation == nil)
        // Again does nothing.
        await workspace.dismissInvitation()
        #expect(workspace.notice == nil)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func previewsALinkAndSendsIt() async throws {
        let client = try await signedIn()
        let address = try #require(URL(string: "https://example.com/live-\(UUID().uuidString.prefix(8).lowercased())"))
        let preview = try #require(try await client.linkPreview(for: address))
        #expect(preview.title == "Example Domain")
        #expect(preview.url == address.absoluteString)
        #expect(preview.image == nil)
        #expect(!preview.description.isEmpty)
        #expect(try await client.linkPreview(for: try #require(URL(string: "https://example.org/"))) == nil)

        let room = try await general(on: client)
        let session = RoomSession(client: client, roomID: room.id)
        session.start()
        defer { session.stop() }
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })

        let id = try session.send(text: "A preview from the live tests: \(address.absoluteString)", previews: [preview])
        try #require(await eventually {
            session.timeline.pending.isEmpty && session.timeline.messages.contains { $0.clientMessageId == id }
        })
        let sent = try #require(session.timeline.messages.first { $0.clientMessageId == id })
        let stored = try await client.message(sent.id, in: room.id)
        #expect(stored.body.contains("og-embed"))
        #expect(stored.body.contains("Example Domain"))
        #expect(stored.body.contains(address.absoluteString))
        try await session.delete(message: sent.id)
    }
}
