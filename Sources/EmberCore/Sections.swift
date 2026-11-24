import Foundation

/// A name that shared rooms are listed under in everyone's sidebar, after the rooms in none: the
/// protocol's `Section`.
///
/// Administrators make, rename, order and delete sections, and whoever can change a room puts it in
/// one in its settings.
public struct RoomSection: Codable, Hashable, Identifiable, Sendable {
    public var id: SectionID
    public var name: String

    public init(id: SectionID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A section as the sidebar lists it, with which of your rooms are in it, in no particular order.
public struct SidebarSection: Decodable, Hashable, Identifiable, Sendable {
    public var id: SectionID
    public var name: String
    public var roomIds: [RoomID]

    public init(id: SectionID, name: String, roomIds: [RoomID] = []) {
        self.id = id
        self.name = name
        self.roomIds = roomIds
    }

    /// The section alone.
    public var section: RoomSection { RoomSection(id: id, name: name) }

    private enum CodingKeys: String, CodingKey { case id, name, roomIds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SectionID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        roomIds = (try? container.decodeIfPresent([RoomID].self, forKey: .roomIds)) ?? []
    }
}

/// A section as New room and a room's settings offer it, with how many of your rooms are in it.
public struct SectionOption: Decodable, Hashable, Identifiable, Sendable {
    public var id: SectionID
    public var name: String
    public var rooms: Int

    public init(id: SectionID, name: String, rooms: Int = 0) {
        self.id = id
        self.name = name
        self.rooms = rooms
    }

    /// The section alone.
    public var section: RoomSection { RoomSection(id: id, name: name) }

    private enum CodingKeys: String, CodingKey { case id, name, rooms }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SectionID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        rooms = (try? container.decodeIfPresent(Int.self, forKey: .rooms)) ?? 0
    }
}

/// The section a room is put in.
public enum SectionChoice: Encodable, Hashable, Sendable {
    /// A section that's there.
    case section(SectionID)
    /// None: the room is listed before the sections.
    case noSection
    /// The section with this name, or else a new one with it, last, which only an administrator
    /// can make.
    case new(name: String)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .section(id):
            var container = encoder.singleValueContainer()
            try container.encode(id)
        case .noSection:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .new(name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
        }
    }

    private enum CodingKeys: String, CodingKey { case name }
}

/// `PUT /api/account/room_order`: the shared rooms in order, and with `sections`, the sections in
/// order, each with which of those rooms are in it, the rest being in none. Without `sections`, they
/// and their rooms stay as they are.
public struct RoomLayout: Encodable, Hashable, Sendable {
    public var roomIds: [RoomID]
    public var sections: [Placement]?

    /// A section and the rooms in it.
    public struct Placement: Encodable, Hashable, Sendable {
        public var id: SectionID
        public var roomIds: [RoomID]

        public init(id: SectionID, roomIds: [RoomID]) {
            self.id = id
            self.roomIds = roomIds
        }
    }

    public init(roomIds: [RoomID], sections: [Placement]? = nil) {
        self.roomIds = roomIds
        self.sections = sections
    }
}

/// What saving a `RoomLayout` answers: the rooms of yours the order ranks, in its order, and every
/// section.
public struct SavedRoomLayout: Decodable, Hashable, Sendable {
    public var sharedOrder: [RoomID]
    public var sections: [SidebarSection]

    public init(sharedOrder: [RoomID], sections: [SidebarSection] = []) {
        self.sharedOrder = sharedOrder
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case sharedOrder, sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedOrder = try container.decodeIfPresent([RoomID].self, forKey: .sharedOrder) ?? []
        sections = (try? container.decodeIfPresent(Lossy<SidebarSection>.self, forKey: .sections))?.elements ?? []
    }
}

/// `PATCH /api/rooms/:id/members`: who to put in a closed room and who to take out, everyone else
/// staying as they are.
package struct MembersChange: Encodable, Sendable {
    package var addedIds: [UserID]
    package var removedIds: [UserID]

    package init(addedIds: [UserID], removedIds: [UserID]) {
        self.addedIds = addedIds
        self.removedIds = removedIds
    }
}

/// A section of the sidebar with the rooms listed under it.
public struct ListedSection: Hashable, Identifiable, Sendable {
    public var section: RoomSection
    public var rooms: [SidebarRoom]

    public var id: SectionID { section.id }

    public init(section: RoomSection, rooms: [SidebarRoom]) {
        self.section = section
        self.rooms = rooms
    }
}

/// Rooms as the sidebar lists them under its sections: the ones in none first, a starred room among
/// them, then each section that has one, in the sections' order.
public struct SectionedRooms: Hashable, Sendable {
    public var loose: [SidebarRoom]
    public var sections: [ListedSection]

    public init(loose: [SidebarRoom] = [], sections: [ListedSection] = []) {
        self.loose = loose
        self.sections = sections
    }
}
