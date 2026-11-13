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
            "invitation": value(invitation),
            "suggestions": [grace, alan].map { value($0) },
        ])
    }

    /// `GET /api/rooms/new`.
    public static func newRoomFormJSON(_ people: [User] = [ada, alan, grace]) -> String {
        json(["people": people.map { value($0) }])
    }

    /// `GET /api/rooms/:id/settings`. The room is shared, so its icon is there, null when it has none.
    public static func roomSettingsJSON(_ room: Room = engines, canAdminister: Bool = true, members: [User] = [ada, grace], people: [User] = [ada, alan, grace]) -> String {
        let memberIDs = Set(members.map(\.id))
        return json([
            "room": ["id": room.id.rawValue, "kind": room.kind.rawValue, "name": room.name ?? "", "icon": room.icon.map { $0 as Any } ?? NSNull()] as [String: Any],
            "canAdminister": canAdminister,
            "people": people.map { ["id": $0.id.rawValue, "name": $0.name, "member": memberIDs.contains($0.id)] },
        ])
    }

    /// `PUT /api/account/room_order`'s answer.
    public static func sharedOrderJSON(_ order: [RoomID]) -> String {
        json(["sharedOrder": order.map(\.rawValue)])
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
