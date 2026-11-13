import Foundation

extension EmberClient {
    // MARK: Rooms

    /// `GET /api/rooms/new`: who a new closed room can have in it. 403 for someone who can't create rooms.
    public func newRoomForm() async throws -> NewRoomForm {
        try await get("/api/rooms/new")
    }

    /// `POST /api/rooms`: creates a shared room, answering it. The room is sent as given, so a closed
    /// room should list you among its members; `Workspace.createRoom(_:)` adds you.
    public func createRoom(_ room: NewRoom) async throws -> Room {
        try await send("POST", "/api/rooms", body: room.body, as: SavedRoom.self).room
    }

    /// `GET /api/rooms/:id/settings`: a room as its settings page shows it. 404 for a room you aren't in.
    public func roomSettings(_ roomID: RoomID) async throws -> RoomSettings {
        try await get("/api/rooms/\(Self.segment(roomID))/settings")
    }

    /// `PATCH /api/rooms/:id`: changes a room, answering it as saved. 403 for anyone but an
    /// administrator or its creator.
    public func changeRoom(_ roomID: RoomID, _ changes: RoomChanges) async throws -> Room {
        try await send("PATCH", "/api/rooms/\(Self.segment(roomID))", body: changes.body, as: SavedRoom.self).room
    }

    /// `DELETE /api/rooms/:id`: deletes a room or DM. 403 for anyone but an administrator or its
    /// creator; anyone in a DM can delete it.
    public func deleteRoom(_ roomID: RoomID) async throws {
        try await send("DELETE", "/api/rooms/\(Self.segment(roomID))")
    }

    // MARK: Sidebar order

    /// `PUT /api/sidebar/order`: puts your stars in this order, answering them. It must list exactly
    /// the rooms you've starred.
    public func setFavoriteOrder(_ roomIDs: [RoomID]) async throws -> Favorites {
        struct Answer: Decodable { var favorites: Favorites }
        return try await send("PUT", "/api/sidebar/order", body: RoomOrder(roomIds: roomIDs), as: Answer.self).favorites
    }

    /// `PUT /api/account/room_order`: puts shared rooms in this order for everyone, answering the rooms
    /// of yours it ranks. Administrators only. An empty list clears the order.
    public func setSharedOrder(_ roomIDs: [RoomID]) async throws -> [RoomID] {
        struct Answer: Decodable { var sharedOrder: [RoomID] }
        return try await send("PUT", "/api/account/room_order", body: RoomOrder(roomIds: roomIDs), as: Answer.self).sharedOrder
    }

    /// `DELETE /api/sidebar/invitation`: dismisses the sidebar's invitation for good.
    public func dismissInvitation() async throws {
        try await send("DELETE", "/api/sidebar/invitation")
    }

    // MARK: Link previews

    /// `POST /api/unfurl`: a link's preview, or nil when it has none.
    public func linkPreview(for url: URL) async throws -> LinkPreview? {
        struct Body: Encodable { var url: String }
        let (data, response) = try await perform(try request("POST", "/api/unfurl", body: Body(url: url.absoluteString)))
        guard response.statusCode != 204, !data.isEmpty else { return nil }
        let preview = try decode(Unfurled.self, from: data, status: response.statusCode)
        // As the web reads it: a preview without a title or an address is none.
        guard let title = preview.title, !title.isEmpty, let address = preview.url, !address.isEmpty else { return nil }
        return LinkPreview(title: title, url: address, image: preview.image, description: preview.description ?? "")
    }
}

/// What creating or changing a room answers.
private struct SavedRoom: Decodable {
    var room: Room
}

/// What unfurling answers, each part read only if it's there.
private struct Unfurled: Decodable {
    var title: String?
    var url: String?
    var image: String?
    var description: String?
}
