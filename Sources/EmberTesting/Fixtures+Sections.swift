import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Sections, who a message notifies and pauses

    public static let product = RoomSection(id: "section-product", name: "Product")
    public static let company = RoomSection(id: "section-company", name: "Company")

    /// The sidebar's sections: Product with Engines in it, and Company with no room of yours.
    public static let sidebarSections: [SidebarSection] = [
        SidebarSection(id: product.id, name: product.name, roomIds: [engines.id]),
        SidebarSection(id: company.id, name: company.name),
    ]

    /// The sections New room and a room's settings offer.
    public static let sectionOptions: [SectionOption] = [
        SectionOption(id: product.id, name: product.name, rooms: 1),
        SectionOption(id: company.id, name: company.name),
    ]

    /// `POST /api/account/sections` and `PATCH /api/account/sections/:id`'s answer.
    public static func sectionJSON(_ section: RoomSection) -> String {
        json(["section": value(section)])
    }

    /// `GET /api/rooms/:id/notified`: the people in a room, and how many each special mention you
    /// may use there would notify.
    public static func notifiedJSON(members: Int = 8, mentions: [SpecialMention: Int] = [.here: 3, .channel: 7, .everyone: 12]) -> String {
        json(["members": members, "mentions": Dictionary(uniqueKeysWithValues: mentions.map { ($0.key.rawValue, $0.value) })])
    }

    /// Someone with their notifications paused until `until`.
    public static func paused(_ user: DirectoryUser, until: Date) -> DirectoryUser {
        var user = user
        user.pausedUntil = until
        return user
    }

    /// `SidebarSection` only decodes, so its JSON is written out here.
    static func sidebarSectionObject(_ section: SidebarSection) -> [String: Any] {
        ["id": section.id.rawValue, "name": section.name, "roomIds": section.roomIds.map(\.rawValue)]
    }

    /// `SectionOption` only decodes, so its JSON is written out here.
    static func sectionOptionObject(_ section: SectionOption) -> [String: Any] {
        ["id": section.id.rawValue, "name": section.name, "rooms": section.rooms]
    }
}
