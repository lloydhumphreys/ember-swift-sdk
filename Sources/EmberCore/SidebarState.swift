import Foundation

/// A sidebar as a client holds it, and what the workspace socket's frames do to it (a port of
/// `changed` and `roomListReducer` in room-list.ts). Pure, so the rules are unit-tested without a socket.
///
/// While a fresh sidebar is on its way (between `willLoad()` and `loaded(_:)`), the changes made
/// meanwhile are kept, and replayed over it when it arrives, since it may have been read before them.
///
/// A star is shown as soon as it's asked for (`beginFavorite`), over the stars the server has
/// given, until its answer comes (`acceptFavorite` or `rejectFavorite`); a sidebar or socket frame
/// landing meanwhile doesn't undo it.
public struct SidebarState: Equatable, Sendable {
    /// The rooms you're in.
    public private(set) var rooms: [SidebarRoom]
    /// The workspace's order for shared rooms.
    public private(set) var sharedOrder: [RoomID]
    /// The people the sidebar offers DMs with.
    public private(set) var suggestions: [User]
    /// An invitation an administrator hasn't dismissed yet.
    public private(set) var invitation: Invitation?

    /// The stars as the server has them, newest version kept.
    private var starred: Favorites
    /// Stars and unstars asked for and not answered yet, oldest first.
    private var guesses: [FavoriteGuess] = []
    private var guessesMade = 0

    /// The changes made since a sidebar was asked for, while one is on its way; nil otherwise.
    private var unseen: [Change]?

    public init() {
        rooms = []
        starred = Favorites()
        sharedOrder = []
        suggestions = []
        invitation = nil
    }

    public init(_ sidebar: Sidebar) {
        rooms = sidebar.rooms
        starred = sidebar.favorites
        sharedOrder = sidebar.sharedOrder
        suggestions = sidebar.suggestions
        invitation = sidebar.invitation
    }

    /// Your stars: the server's, with those asked for and not yet answered over them.
    public var favorites: Favorites {
        var rooms = starred.rooms
        for guess in guesses {
            rooms.removeAll { $0 == guess.roomID }
            if guess.favorite { rooms.append(guess.roomID) }
        }
        return Favorites(rooms: rooms, version: starred.version)
    }

    /// Stars or unstars a room for now, until `acceptFavorite` or `rejectFavorite` hears the
    /// server's answer to the guess it returns.
    public mutating func beginFavorite(_ favorite: Bool, roomID: RoomID) -> FavoriteGuess {
        guessesMade += 1
        let guess = FavoriteGuess(roomID: roomID, favorite: favorite, number: guessesMade)
        guesses.append(guess)
        return guess
    }

    /// The server took `guess` and answered with its stars, which count if they're newer.
    public mutating func acceptFavorite(_ guess: FavoriteGuess, favorites: Favorites) {
        guesses.removeAll { $0 == guess }
        setFavorites(favorites)
    }

    /// The server refused `guess`: it no longer shows, and the stars are the server's again (with
    /// any other guess still on its way over them).
    public mutating func rejectFavorite(_ guess: FavoriteGuess) {
        guesses.removeAll { $0 == guess }
    }

    /// Applies a frame. Returns true when the frame means the sidebar should be fetched again:
    /// `welcome`, since anything could have changed while the socket was closed, and `rooms.reordered`,
    /// which names no rooms. For `user.updated`, which can mean a refetch too, use
    /// `apply(_:me:directory:)`.
    @discardableResult
    public mutating func apply(_ frame: WorkspaceFrame) -> Bool {
        switch frame {
        case .welcome, .roomsReordered:
            return true
        case let .roomUnread(id): record(.marked(id, unread: true))
        case let .roomRead(id): record(.marked(id, unread: false))
        case let .roomSaved(room): record(.saved(room))
        case let .roomGone(id): record(.gone(id))
        case let .roomActive(id, at): record(.active(id, at: at))
        case let .favoritesChanged(favorites): record(.starred(favorites))
        case let .roomInvolvement(id, involvement): record(.involved(id, involvement))
        case .invitationDismissed: record(.invitationDismissed)
        case .userUpdated, .accountUpdated, .error, .pong, .unknown:
            break
        }
        return false
    }

    /// `apply(_:)`, knowing who's signed in and the directory as it was before the frame, which a
    /// `user.updated` needs: a change to their own role loads their rooms again, since only
    /// administrators get the welcome card, and so does someone coming back (active now, though the
    /// directory lists them otherwise), since the suggestions only list people active when they loaded.
    @discardableResult
    public mutating func apply(_ frame: WorkspaceFrame, me: Me?, directory: [DirectoryUser]) -> Bool {
        guard case let .userUpdated(user) = frame else { return apply(frame) }
        if let me, user.id == me.id {
            return (user.role == .administrator) != me.administrator
        }
        let before = directory.first { $0.id == user.id }?.status ?? .active
        return user.status == .active && before != .active
    }

    /// They've opened a room, or read it elsewhere.
    public mutating func markRead(_ roomID: RoomID) { record(.marked(roomID, unread: false)) }

    /// Sets how much of a room reaches you.
    public mutating func setInvolvement(_ involvement: Involvement, roomID: RoomID) {
        record(.involved(roomID, involvement))
    }

    /// Takes the stars only when their version is newer: they come from a star's answer, the socket
    /// and the sidebar itself, in whatever order they arrive.
    public mutating func setFavorites(_ favorites: Favorites) { record(.starred(favorites)) }

    /// A room as the server saved it (`RoomList.withRoom`).
    public mutating func add(_ room: Room) { record(.saved(room)) }

    /// A sidebar has been asked for: changes from now on are kept until it arrives.
    public mutating func willLoad() { unseen = [] }

    /// The sidebar asked for has arrived: it takes the place of this one, with the changes made since
    /// it was asked for over it.
    public mutating func loaded(_ sidebar: Sidebar) {
        let changes = unseen ?? []
        let (guesses, guessesMade) = (self.guesses, self.guessesMade)
        self = SidebarState(sidebar)
        // Stars on their way are answered later, whatever the sidebar says meanwhile.
        (self.guesses, self.guessesMade) = (guesses, guessesMade)
        for change in changes { apply(change) }
    }

    /// The sidebar asked for didn't arrive: keep this one, and stop keeping changes.
    public mutating func unanswered() { unseen = nil }

    private enum Change: Equatable, Sendable {
        case saved(Room)
        case gone(RoomID)
        case marked(RoomID, unread: Bool)
        case active(RoomID, at: Date)
        case involved(RoomID, Involvement)
        case starred(Favorites)
        case invitationDismissed
    }

    private mutating func record(_ change: Change) {
        apply(change)
        unseen?.append(change)
    }

    private mutating func apply(_ change: Change) {
        switch change {
        case let .saved(room):
            rooms = RoomList.withRoom(rooms, room)
        case let .gone(id):
            rooms.removeAll { $0.id == id }
            // A room that's gone takes its star with it, as the server's stars do.
            starred.rooms.removeAll { $0 == id }
            guesses.removeAll { $0.roomID == id }
        case let .marked(id, unread):
            for index in rooms.indices where rooms[index].id == id { rooms[index].unread = unread }
        case let .active(id, at):
            for index in rooms.indices where rooms[index].id == id && rooms[index].room.isDirect {
                if (rooms[index].room.activeAt ?? .distantPast) < at { rooms[index].room.activeAt = at }
            }
        case let .involved(id, involvement):
            for index in rooms.indices where rooms[index].id == id { rooms[index].involvement = involvement }
        case let .starred(newer):
            if newer.version > starred.version { starred = newer }
        case .invitationDismissed:
            invitation = nil
        }
    }
}

/// A star or unstar asked for, from `SidebarState.beginFavorite`, to hand back with its answer.
public struct FavoriteGuess: Hashable, Sendable {
    /// The room starred or unstarred.
    public let roomID: RoomID
    /// Whether it was starred.
    public let favorite: Bool
    let number: Int
}
