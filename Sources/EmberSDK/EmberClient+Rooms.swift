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

    /// `PATCH /api/rooms/:id/members`: puts people in a closed room and takes people out, leaving
    /// everyone else as they are, answering the room as saved. 403 for anyone but an administrator or
    /// its creator, 409 for an open room, which everyone is in, and 422 for someone both put in and
    /// taken out.
    public func changeMembers(of roomID: RoomID, adding added: [UserID] = [], removing removed: [UserID] = []) async throws -> Room {
        let change = MembersChange(addedIds: added, removedIds: removed)
        return try await send("PATCH", "/api/rooms/\(Self.segment(roomID))/members", body: change, as: SavedRoom.self).room
    }

    /// `GET /api/rooms/:id/notified`: how many people are in a room and how many each special mention
    /// you may use there would notify, for `NotifiedCounts.notifying(_:)` to say whether to ask before
    /// a message is sent. 404 for a room you aren't in.
    public func notified(in roomID: RoomID) async throws -> NotifiedCounts {
        try await get("/api/rooms/\(Self.segment(roomID))/notified")
    }

    /// `DELETE /api/rooms/:id`: deletes a room or DM. 403 for anyone but an administrator or its
    /// creator; anyone in a DM can delete it.
    public func deleteRoom(_ roomID: RoomID) async throws {
        try await send("DELETE", "/api/rooms/\(Self.segment(roomID))")
    }

    // MARK: Sections

    /// `POST /api/account/sections`: makes a section, after the others, answering it. Administrators
    /// only. 409 when a section has the name already, and 422 for a name that isn't 1 to
    /// `Limits.sectionName` characters or when there are `Limits.sections` already.
    public func makeSection(named name: String) async throws -> RoomSection {
        try await send("POST", "/api/account/sections", body: SectionName(name: name), as: SavedSection.self).section
    }

    /// `PATCH /api/account/sections/:id`: renames a section, answering it. Administrators only. 409
    /// when another section has the name.
    public func renameSection(_ sectionID: SectionID, to name: String) async throws -> RoomSection {
        try await send("PATCH", "/api/account/sections/\(Self.segment(sectionID))", body: SectionName(name: name), as: SavedSection.self).section
    }

    /// `DELETE /api/account/sections/:id`: deletes a section, leaving its rooms in none.
    /// Administrators only.
    public func deleteSection(_ sectionID: SectionID) async throws {
        try await send("DELETE", "/api/account/sections/\(Self.segment(sectionID))")
    }

    // MARK: Sidebar order

    /// `PUT /api/sidebar/order`: puts your stars in this order, answering them. It must list exactly
    /// the rooms you've starred.
    public func setFavoriteOrder(_ roomIDs: [RoomID]) async throws -> Favorites {
        struct Answer: Decodable { var favorites: Favorites }
        return try await send("PUT", "/api/sidebar/order", body: RoomOrder(roomIds: roomIDs), as: Answer.self).favorites
    }

    /// `PUT /api/account/room_order`: puts shared rooms in this order for everyone, answering the rooms
    /// of yours it ranks. Administrators only. An empty list clears the order. The sections and the
    /// rooms in them stay as they are; `setRoomLayout(_:)` places those too.
    public func setSharedOrder(_ roomIDs: [RoomID]) async throws -> [RoomID] {
        try await setRoomLayout(RoomLayout(roomIds: roomIDs)).sharedOrder
    }

    /// `PUT /api/account/room_order`: puts shared rooms in the layout's order for everyone, and when
    /// it has sections, puts those in its order, each with the rooms it lists, the rest of the
    /// layout's rooms going in none. Answers the rooms of yours the order ranks and every section.
    /// Administrators only.
    ///
    /// A section the layout doesn't list, as one made since it was read, comes after the ones it
    /// does and keeps its rooms.
    public func setRoomLayout(_ layout: RoomLayout) async throws -> SavedRoomLayout {
        try await send("PUT", "/api/account/room_order", body: layout, as: SavedRoomLayout.self)
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

/// What making or renaming a section sends.
private struct SectionName: Encodable {
    var name: String
}

/// What making or renaming a section answers.
private struct SavedSection: Decodable {
    var section: RoomSection
}

/// What unfurling answers, each part read only if it's there.
private struct Unfurled: Decodable {
    var title: String?
    var url: String?
    var image: String?
    var description: String?
}
