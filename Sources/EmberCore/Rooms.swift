import Foundation

/// Who can see a shared room.
public enum RoomAccess: Hashable, Sendable {
    /// Everyone in the workspace.
    case open
    /// Only these people.
    case closed(memberIDs: [UserID])
}

/// A room to create with `EmberClient.createRoom(_:)`.
public struct NewRoom: Hashable, Sendable {
    public var name: String
    /// An icon's name. Nil gives the default one.
    public var icon: String?
    public var access: RoomAccess

    public init(name: String, icon: String? = nil, access: RoomAccess = .open) {
        self.name = name
        self.icon = icon
        self.access = access
    }

    package var body: RoomBody { RoomBody(name: name, icon: icon, access: access) }
}

/// What `EmberClient.changeRoom(_:_:)` changes. Anything nil stays as it is.
public struct RoomChanges: Hashable, Sendable {
    public var name: String?
    /// An icon's name. An empty one gives the default icon back.
    public var icon: String?
    /// Who can see it. Closing a room without you in it takes you out of it.
    public var access: RoomAccess?

    public init(name: String? = nil, icon: String? = nil, access: RoomAccess? = nil) {
        self.name = name
        self.icon = icon
        self.access = access
    }

    package var body: RoomBody { RoomBody(name: name, icon: icon, access: access) }
}

/// `POST /api/rooms` and `PATCH /api/rooms/:id`: a room's fields, those left out kept.
package struct RoomBody: Encodable, Sendable {
    package var name: String?
    package var icon: String?
    package var kind: RoomKind?
    package var memberIds: [UserID]?

    package init(name: String?, icon: String?, access: RoomAccess?) {
        self.name = name
        self.icon = icon
        switch access {
        case .open: kind = .open
        case let .closed(memberIDs): (kind, memberIds) = (.closed, memberIDs)
        case nil: break
        }
    }
}

/// `GET /api/rooms/new`: who a new closed room can have in it.
public struct NewRoomForm: Decodable, Hashable, Sendable {
    /// Everyone active, by name.
    public var people: [User]
}

/// Someone a room's settings list, and whether they're in it.
public struct RoomPerson: Decodable, Hashable, Identifiable, Sendable {
    public var id: UserID
    public var name: String
    public var member: Bool

    /// Them as a `User`.
    public var user: User { User(id: id, name: name) }
}

/// `GET /api/rooms/:id/settings`: a room as its settings page shows it.
public struct RoomSettings: Decodable, Hashable, Sendable {
    public var room: Room
    /// Whether you can change or delete it: administrators and its creator can.
    public var canAdminister: Bool
    /// Everyone active, with whether they're in the room.
    public var people: [RoomPerson]
}

/// A link's preview, from `EmberClient.linkPreview(for:)`, to send with a message.
public struct LinkPreview: Codable, Hashable, Sendable {
    public var title: String
    /// The page's address.
    public var url: String
    /// An image's address.
    public var image: String?
    public var description: String

    public init(title: String, url: String, image: String? = nil, description: String = "") {
        self.title = title
        self.url = url
        self.image = image
        self.description = description
    }
}

/// `PUT /api/sidebar/order` and `PUT /api/account/room_order`.
package struct RoomOrder: Encodable, Sendable {
    package var roomIds: [RoomID]
    package init(roomIds: [RoomID]) { self.roomIds = roomIds }
}
