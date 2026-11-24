import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Rooms, sidebar order and link previews

    /// The invitation an administrator's sidebar offers until it's dismissed.
    public static let invitation: Invitation = decode(#"{"roomId":"room-general","joinCode":"aB3d"}"#)

    /// `GET /api/sidebar` with `invitation` in it.
    public static func sidebarJSON(invitation: Invitation, sharedOrder: [RoomID] = [engines.id, general.id]) -> String {
        json([
            "rooms": sidebarRooms.map(sidebarRoomObject),
            "favorites": value(favorites),
            "sharedOrder": sharedOrder.map(\.rawValue),
            "sections": [Any](),
            "invitation": value(invitation),
        ])
    }

    /// `GET /api/rooms/new`.
    public static func newRoomFormJSON(_ people: [User] = [ada, alan, grace], sections: [SectionOption] = []) -> String {
        json(["people": people.map { value($0) }, "sections": sections.map(sectionOptionObject)])
    }

    /// `GET /api/rooms/:id/settings`. The room is shared, so its icon is there, null when it has none,
    /// and `channelMentions` only once they're off. `sections` are for whoever can change the room.
    public static func roomSettingsJSON(
        _ room: Room = engines, canAdminister: Bool = true, canChangeChannelMentions: Bool = true, members: [User] = [ada, grace],
        people: [User] = [ada, alan, grace], section: RoomSection? = nil, sections: [SectionOption] = []
    ) -> String {
        let memberIDs = Set(members.map(\.id))
        var roomObject: [String: Any] = [
            "id": room.id.rawValue, "kind": room.kind.rawValue, "name": room.name ?? "", "icon": room.icon.map { $0 as Any } ?? NSNull(),
        ]
        if room.channelMentions == false { roomObject["channelMentions"] = false }
        return json([
            "room": roomObject,
            "canAdminister": canAdminister,
            "canChangeHuddles": false,
            "canChangeChannelMentions": canChangeChannelMentions,
            "people": people.map { ["id": $0.id.rawValue, "name": $0.name, "member": memberIDs.contains($0.id)] },
            "section": section.map { value($0) } ?? NSNull(),
            "sections": sections.map(sectionOptionObject),
        ])
    }

    /// `PUT /api/account/room_order`'s answer.
    public static func sharedOrderJSON(_ order: [RoomID], sections: [SidebarSection] = []) -> String {
        json(["sharedOrder": order.map(\.rawValue), "sections": sections.map(sidebarSectionObject)])
    }

    /// A link's preview.
    public static let linkPreview = LinkPreview(
        title: "Analytical Engine", url: "https://example.com/engine",
        image: "https://example.com/engine.png", description: "Babbage’s design for a general-purpose computer."
    )

    /// `POST /api/unfurl`'s answer for a link with a preview.
    public static func linkPreviewJSON(_ preview: LinkPreview = linkPreview) -> String {
        json(["title": preview.title, "url": preview.url, "image": preview.image.map { $0 as Any } ?? NSNull(), "description": preview.description])
    }
}

extension Fixtures.WorkspaceFrames {
    public static let invitationDismissed = #"{"type":"invitation.dismissed"}"#
}
