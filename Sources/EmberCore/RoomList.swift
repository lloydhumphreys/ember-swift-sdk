import Foundation

// Ports of apps/web/src/lib/room-list.ts and directs.ts.

/// How the sidebar lists someone's rooms, and how it names and finds people for DMs.
///
/// Someone's rooms keep the order the sidebar's answer gives them, the order they were put in them.
/// The sidebar lists their DMs apart from the other rooms, and lists the rooms they've starred first,
/// in the order they starred them, then the rooms the workspace's shared order ranks, in its order,
/// then the rest in the order they were put in them, rather than by name, so a room that's just been
/// made, or that they've just been put in, comes last. Their DMs go by when each was last active,
/// latest first. The rooms someone has hidden are listed too, for them to open, but their sidebar
/// leaves them out.
public enum RoomList {
    /// Whether someone has hidden the room, which leaves it out of the sidebar but not out of the list.
    public static func isHidden(_ room: SidebarRoom) -> Bool { room.involvement == .invisible }

    /// Shared rooms, none hidden, in sidebar order: starred first in star order, then the ones the
    /// workspace's shared order ranks, in its order, then the rest in the order they're given, the
    /// order someone was put in them.
    public static func shared(_ rooms: [SidebarRoom], favorites: [RoomID], sharedOrder: [RoomID]) -> [SidebarRoom] {
        inSidebarOrder(rooms.filter { !$0.room.isDirect && !isHidden($0) }, favorites: favorites, sharedOrder: sharedOrder)
    }

    /// Shared rooms, hidden ones too, in the workspace's shared order, stars aside: what an
    /// administrator puts in order for everyone.
    public static func inSharedOrder(_ rooms: [SidebarRoom], sharedOrder: [RoomID]) -> [SidebarRoom] {
        inSidebarOrder(rooms.filter { !$0.room.isDirect }, favorites: [], sharedOrder: sharedOrder)
    }

    /// `ids` with the ones at `offsets` moved to before `destination`, as SwiftUI's `onMove` gives them.
    package static func moving<T>(_ ids: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        let moved = offsets.filter { ids.indices.contains($0) }.map { ids[$0] }
        let before = ids.indices.filter { $0 < destination && !offsets.contains($0) }.map { ids[$0] }
        let after = ids.indices.filter { $0 >= destination && !offsets.contains($0) }.map { ids[$0] }
        return before + moved + after
    }

    /// `ids` with the ones `order` lists in its order, in the places those held, the rest kept where they are.
    package static func reordered(_ ids: [RoomID], by order: [RoomID]) -> [RoomID] {
        let present = Set(ids)
        var queue = order.filter { present.contains($0) }
        let ordered = Set(queue)
        var seen = Set<RoomID>()
        queue.removeAll { !seen.insert($0).inserted }
        var result: [RoomID] = []
        var next = queue.makeIterator()
        for id in ids {
            if ordered.contains(id) {
                if let id = next.next() { result.append(id) }
            } else {
                result.append(id)
            }
        }
        return result
    }

    /// `rooms`, given in the order someone was put in them, in the sidebar's order: the rooms in
    /// `favorites` first, then the ones `sharedOrder` ranks, then the rest as they're given, each
    /// room's places worked out once rather than at every comparison (`inSidebarOrder` in room-list.ts).
    private static func inSidebarOrder(_ rooms: [SidebarRoom], favorites: [RoomID], sharedOrder: [RoomID]) -> [SidebarRoom] {
        let stars = places(in: favorites)
        let ranks = places(in: sharedOrder)
        return rooms.enumerated()
            .map { (room: $0.element, star: stars[$0.element.id] ?? .max, rank: ranks[$0.element.id] ?? .max, given: $0.offset) }
            .sorted { a, b in
                if a.star != b.star { return a.star < b.star }
                if a.rank != b.rank { return a.rank < b.rank }
                return a.given < b.given
            }
            .map(\.room)
    }

    /// DMs, none hidden, latest active first, and of two active at once, the one made later.
    public static func directs(_ rooms: [SidebarRoom]) -> [SidebarRoom] {
        let listed = rooms.filter { $0.room.isDirect && !isHidden($0) }
        // Upstream reverses the list and sorts it stably, so ties go to the room listed later.
        return listed.enumerated()
            .sorted { a, b in
                let first = a.element.room.activeAt ?? .distantPast
                let second = b.element.room.activeAt ?? .distantPast
                return first != second ? first > second : a.offset > b.offset
            }
            .map(\.element)
    }

    /// Whether the sidebar marks the room unread: never the room on screen, which counts as read while
    /// it's open, nor one hidden after it was marked.
    public static func isMarkedUnread(_ room: SidebarRoom, currentRoomID: RoomID?) -> Bool {
        room.unread && room.id != currentRoomID && !isHidden(room)
    }

    /// `rooms` with `room` as it is now, in place of what it was, keeping its mark and level, or last,
    /// read and at the level its kind starts at, as the room someone was put in most recently, whether
    /// it's just been made or they've just been put in it, which is where the list has it when it loads
    /// again. A DM keeps the later of its two last-active times, since a message can come between the
    /// server reading it and its answer arriving.
    public static func withRoom(_ rooms: [SidebarRoom], _ room: Room) -> [SidebarRoom] {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else {
            return rooms + [SidebarRoom(room: room, unread: false, involvement: .starting(for: room.kind))]
        }
        var rooms = rooms
        let listed = rooms[index]
        var saved = room
        if listed.room.isDirect, room.isDirect, let before = listed.room.activeAt, before > room.activeAt ?? .distantPast {
            saved.activeAt = before
        }
        rooms[index] = SidebarRoom(
            room: saved, unread: listed.unread, unreadSince: listed.unreadSince, unreadCount: listed.unreadCount, involvement: listed.involvement
        )
        return rooms
    }

    /// Who a DM shows: the others, or just you in your DM with yourself.
    public static func membersShown(_ room: Room, me: UserID) -> [User] {
        let members = room.members ?? []
        let others = members.filter { $0.id != me }
        return others.isEmpty ? members : others
    }

    /// A room's name as `me` reads it: a shared room's own, and a DM's others in a sentence.
    /// `nameOf` gives each person's name as it is now.
    public static func name(of room: Room, me: UserID, nameOf: (User) -> String) -> String {
        room.isDirect ? sentence(membersShown(room, me: me).map(nameOf)) : room.name ?? ""
    }

    /// Names joined as Rails' `to_sentence` joins them: "Ada", "Ada and Grace", "Ada, Grace, and Alan".
    public static func sentence(_ names: [String]) -> String {
        guard names.count > 2, let last = names.last else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + ", and " + last
    }

    /// What New direct message looks for in what's typed: the name without any @s before it.
    public static func soughtName(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop { $0 == "@" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The people New direct message lists for `name`: everyone active but `me`, bots included, whose
    /// name has `name` in it, ignoring the case of A to Z only, as SQLite's LIKE does, ordered by that
    /// folded name and then id.
    public static func peopleMatching(_ people: [DirectoryUser], me: UserID, name: String) -> [DirectoryUser] {
        let sought = folded(name)
        return people
            .filter { $0.status == .active && $0.id != me }
            .map { (person: $0, key: folded($0.name)) }
            .filter { sought.isEmpty || $0.key.contains(sought) }
            .sorted { a, b in a.key != b.key ? jsLess(a.key, b.key) : jsLess(a.person.id, b.person.id) }
            .map(\.person)
    }

    private static func places(in order: [RoomID]) -> [RoomID: Int] {
        // As a JavaScript Map built from the order, a room listed twice takes its later place.
        var places: [RoomID: Int] = [:]
        for (place, id) in order.enumerated() { places[id] = place }
        return places
    }

    /// `text` with A to Z lowercased and nothing else, as SQLite's LOWER() folds it.
    private static func folded(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if ("A"..."Z").contains(scalar), let lower = Unicode.Scalar(scalar.value + 32) {
                scalars.append(lower)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
