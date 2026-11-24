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
    /// The section to list it under. Nil lists it under none.
    public var section: SectionChoice?

    public init(name: String, icon: String? = nil, access: RoomAccess = .open, section: SectionChoice? = nil) {
        self.name = name
        self.icon = icon
        self.access = access
        self.section = section
    }

    package var body: RoomBody { RoomBody(name: name, icon: icon, access: access, section: section) }
}

/// What `EmberClient.changeRoom(_:_:)` changes. Anything nil stays as it is.
public struct RoomChanges: Hashable, Sendable {
    public var name: String?
    /// An icon's name. An empty one gives the default icon back.
    public var icon: String?
    /// Who can see it. Closing a room without you in it takes you out of it.
    public var access: RoomAccess?
    /// Whether @channel, @here and @everyone notify the room. Only administrators can change it.
    public var channelMentions: Bool?
    /// The section to list it under, `.noSection` taking it out of the one it's in.
    public var section: SectionChoice?

    public init(name: String? = nil, icon: String? = nil, access: RoomAccess? = nil, channelMentions: Bool? = nil, section: SectionChoice? = nil) {
        self.name = name
        self.icon = icon
        self.access = access
        self.channelMentions = channelMentions
        self.section = section
    }

    package var body: RoomBody {
        RoomBody(name: name, icon: icon, access: access, channelMentions: channelMentions, section: section)
    }
}

/// `POST /api/rooms` and `PATCH /api/rooms/:id`: a room's fields, those left out kept.
package struct RoomBody: Encodable, Sendable {
    package var name: String?
    package var icon: String?
    package var kind: RoomKind?
    package var memberIds: [UserID]?
    package var channelMentions: Bool?
    /// Left out, the room stays where it is; `.noSection` goes as null.
    package var section: SectionChoice?

    package init(name: String?, icon: String?, access: RoomAccess?, channelMentions: Bool? = nil, section: SectionChoice? = nil) {
        self.name = name
        self.icon = icon
        self.channelMentions = channelMentions
        self.section = section
        switch access {
        case .open: kind = .open
        case let .closed(memberIDs): (kind, memberIds) = (.closed, memberIDs)
        case nil: break
        }
    }
}

/// `GET /api/rooms/new`: who a new closed room can have in it, and the sections it can go under.
public struct NewRoomForm: Decodable, Hashable, Sendable {
    /// Everyone active, by name.
    public var people: [User]
    /// Every section, in order.
    public var sections: [SectionOption]

    public init(people: [User], sections: [SectionOption] = []) {
        self.people = people
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case people, sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        people = try container.decode([User].self, forKey: .people)
        sections = (try? container.decodeIfPresent(Lossy<SectionOption>.self, forKey: .sections))?.elements ?? []
    }
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
    /// Whether you can turn @channel, @here and @everyone on or off in it: only administrators can.
    public var canChangeChannelMentions: Bool
    /// Everyone active, with whether they're in the room.
    public var people: [RoomPerson]
    /// The section it's listed under, if any.
    public var section: RoomSection?
    /// For whoever can change the room, every section, in order; for anyone else, none.
    public var sections: [SectionOption]

    public init(
        room: Room,
        canAdminister: Bool,
        canChangeChannelMentions: Bool = false,
        people: [RoomPerson],
        section: RoomSection? = nil,
        sections: [SectionOption] = []
    ) {
        self.room = room
        self.canAdminister = canAdminister
        self.canChangeChannelMentions = canChangeChannelMentions
        self.people = people
        self.section = section
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case room, canAdminister, canChangeChannelMentions, people, section, sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try container.decode(Room.self, forKey: .room)
        canAdminister = try container.decode(Bool.self, forKey: .canAdminister)
        canChangeChannelMentions = (try? container.decodeIfPresent(Bool.self, forKey: .canChangeChannelMentions)) ?? false
        people = try container.decode([RoomPerson].self, forKey: .people)
        section = (try? container.decodeIfPresent(RoomSection.self, forKey: .section)) ?? nil
        sections = (try? container.decodeIfPresent(Lossy<SectionOption>.self, forKey: .sections))?.elements ?? []
    }
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

/// `PUT /api/sidebar/order`.
package struct RoomOrder: Encodable, Sendable {
    package var roomIds: [RoomID]
    package init(roomIds: [RoomID]) { self.roomIds = roomIds }
}
