import Foundation

/// A sidebar as a client holds it, and what the workspace socket's frames do to it (a port of
/// `changed` and `roomListReducer` in room-list.ts). Pure, so the rules are unit-tested without a socket.
///
/// While a fresh sidebar is on its way (between `willLoad()` and `loaded(_:)`), the changes made
/// meanwhile are kept, and replayed over it when it arrives, since it may have been read before them.
///
/// A star is shown as soon as it's asked for (`beginFavorite`), over the stars the server has
/// given, until its answer comes (`acceptFavorite` or `rejectFavorite`); a sidebar or socket frame
/// landing meanwhile doesn't undo it. Reordering stars or shared rooms, and dismissing the
/// invitation, show at once the same way (`beginFavoriteOrder`, `beginSharedOrder`, `beginDismissal`).
public struct SidebarState: Equatable, Sendable {
    /// The rooms you're in.
    public private(set) var rooms: [SidebarRoom]
    /// The people the sidebar offers DMs with.
    public private(set) var suggestions: [User]

    /// The shared order as the server has given it.
    private var savedSharedOrder: [RoomID]
    /// The invitation as the server has given it.
    private var savedInvitation: Invitation?
    /// Orders asked for and not answered yet, oldest first.
    private var favoriteOrders: [OrderGuess] = []
    private var sharedOrders: [OrderGuess] = []
    /// Dismissals of the invitation not answered yet.
    private var dismissals = 0

    /// The stars as the server has them, newest version kept.
    private var starred: Favorites
    /// Stars and unstars asked for and not answered yet, oldest first.
    private var guesses: [FavoriteGuess] = []
    private var guessesMade = 0

    /// The changes made since a sidebar was asked for, while one is on its way; nil otherwise.
    private var unseen: [Change]?

    package init() {
        rooms = []
        starred = Favorites()
        savedSharedOrder = []
        suggestions = []
        savedInvitation = nil
    }

    package init(_ sidebar: Sidebar) {
        rooms = sidebar.rooms
        starred = sidebar.favorites
        savedSharedOrder = sidebar.sharedOrder
        suggestions = sidebar.suggestions
        savedInvitation = sidebar.invitation
    }

    /// The workspace's order for shared rooms: the server's, or the one asked for last.
    public var sharedOrder: [RoomID] { sharedOrders.last?.roomIDs ?? savedSharedOrder }

    /// An invitation an administrator hasn't dismissed yet.
    public var invitation: Invitation? { dismissals > 0 ? nil : savedInvitation }

    /// Your stars: the server's, with those asked for and not yet answered over them.
    public var favorites: Favorites {
        var rooms = starred.rooms
        if let order = favoriteOrders.last { rooms = RoomList.reordered(rooms, by: order.roomIDs) }
        for guess in guesses {
            rooms.removeAll { $0 == guess.roomID }
            if guess.favorite { rooms.append(guess.roomID) }
        }
        return Favorites(rooms: rooms, version: starred.version)
    }

    /// Stars or unstars a room for now, until `acceptFavorite` or `rejectFavorite` hears the
    /// server's answer to the guess it returns.
    package mutating func beginFavorite(_ favorite: Bool, roomID: RoomID) -> FavoriteGuess {
        guessesMade += 1
        let guess = FavoriteGuess(roomID: roomID, favorite: favorite, number: guessesMade)
        guesses.append(guess)
        return guess
    }

    /// The server took `guess` and answered with its stars, which count if they're newer.
    package mutating func acceptFavorite(_ guess: FavoriteGuess, favorites: Favorites) {
        guesses.removeAll { $0 == guess }
        setFavorites(favorites)
    }

    /// The server refused `guess`: it no longer shows, and the stars are the server's again (with
    /// any other guess still on its way over them).
    package mutating func rejectFavorite(_ guess: FavoriteGuess) {
        guesses.removeAll { $0 == guess }
    }

    /// Puts the stars in this order for now, until `acceptFavoriteOrder` or `rejectFavoriteOrder`.
    package mutating func beginFavoriteOrder(_ roomIDs: [RoomID]) -> OrderGuess {
        guessesMade += 1
        let guess = OrderGuess(roomIDs: roomIDs, number: guessesMade)
        favoriteOrders.append(guess)
        return guess
    }

    /// The server took the order and answered with its stars.
    package mutating func acceptFavoriteOrder(_ guess: OrderGuess, favorites: Favorites) {
        favoriteOrders.removeAll { $0 == guess }
        setFavorites(favorites)
    }

    /// The server refused the order: the stars are in the server's order again.
    package mutating func rejectFavoriteOrder(_ guess: OrderGuess) {
        favoriteOrders.removeAll { $0 == guess }
    }

    /// Shows this shared order for now, until `acceptSharedOrder` or `rejectSharedOrder`.
    package mutating func beginSharedOrder(_ roomIDs: [RoomID]) -> OrderGuess {
        guessesMade += 1
        let guess = OrderGuess(roomIDs: roomIDs, number: guessesMade)
        sharedOrders.append(guess)
        return guess
    }

    /// The server saved the order and answered the rooms of yours it ranks.
    package mutating func acceptSharedOrder(_ guess: OrderGuess, order: [RoomID]) {
        sharedOrders.removeAll { $0 == guess }
        record(.ordered(order))
    }

    /// The server refused the order: the shared order is the server's again.
    package mutating func rejectSharedOrder(_ guess: OrderGuess) {
        sharedOrders.removeAll { $0 == guess }
    }

    /// Hides the invitation for now, until `acceptDismissal` or `rejectDismissal`.
    package mutating func beginDismissal() { dismissals += 1 }

    /// The server dismissed the invitation.
    package mutating func acceptDismissal() {
        dismissals = max(0, dismissals - 1)
        record(.invitationDismissed)
    }

    /// The server refused: the invitation shows again.
    package mutating func rejectDismissal() { dismissals = max(0, dismissals - 1) }

    /// Applies a frame. Returns true when the frame means the sidebar should be fetched again:
    /// `welcome`, since anything could have changed while the socket was closed, and `rooms.reordered`,
    /// which names no rooms. For `user.updated`, which can mean a refetch too, use
    /// `apply(_:me:directory:)`.
    @discardableResult
    package mutating func apply(_ frame: WorkspaceFrame) -> Bool {
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
    package mutating func apply(_ frame: WorkspaceFrame, me: Me?, directory: [DirectoryUser]) -> Bool {
        guard case let .userUpdated(user) = frame else { return apply(frame) }
        if let me, user.id == me.id {
            return (user.role == .administrator) != me.administrator
        }
        let before = directory.first { $0.id == user.id }?.status ?? .active
        return user.status == .active && before != .active
    }

    /// They've opened a room, or read it elsewhere.
    package mutating func markRead(_ roomID: RoomID) { record(.marked(roomID, unread: false)) }

    /// Sets how much of a room reaches you.
    package mutating func setInvolvement(_ involvement: Involvement, roomID: RoomID) {
        record(.involved(roomID, involvement))
    }

    /// Takes the stars only when their version is newer: they come from a star's answer, the socket
    /// and the sidebar itself, in whatever order they arrive.
    package mutating func setFavorites(_ favorites: Favorites) { record(.starred(favorites)) }

    /// A room as the server saved it (`RoomList.withRoom`).
    package mutating func add(_ room: Room) { record(.saved(room)) }

    /// A room you've left or deleted, as `room.gone` takes it out.
    package mutating func remove(_ roomID: RoomID) { record(.gone(roomID)) }

    /// A sidebar has been asked for: changes from now on are kept until it arrives.
    package mutating func willLoad() { unseen = [] }

    /// The sidebar asked for has arrived: it takes the place of this one, with the changes made since
    /// it was asked for over it.
    package mutating func loaded(_ sidebar: Sidebar) {
        let changes = unseen ?? []
        let before = self
        self = SidebarState(sidebar)
        // Stars, orders and dismissals on their way are answered later, whatever the sidebar says meanwhile.
        (guesses, guessesMade) = (before.guesses, before.guessesMade)
        (favoriteOrders, sharedOrders, dismissals) = (before.favoriteOrders, before.sharedOrders, before.dismissals)
        for change in changes { apply(change) }
    }

    /// The sidebar asked for didn't arrive: keep this one, and stop keeping changes.
    package mutating func unanswered() { unseen = nil }

    private enum Change: Equatable, Sendable {
        case saved(Room)
        case gone(RoomID)
        case marked(RoomID, unread: Bool)
        case active(RoomID, at: Date)
        case involved(RoomID, Involvement)
        case starred(Favorites)
        case ordered([RoomID])
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
        case let .ordered(order):
            savedSharedOrder = order
        case .invitationDismissed:
            savedInvitation = nil
        }
    }
}

/// A star or unstar asked for, from `SidebarState.beginFavorite`, to hand back with its answer.
package struct FavoriteGuess: Hashable, Sendable {
    /// The room starred or unstarred.
    package let roomID: RoomID
    /// Whether it was starred.
    package let favorite: Bool
    let number: Int
}

/// An order asked for, from `SidebarState.beginFavoriteOrder` or `beginSharedOrder`, to hand back with its answer.
package struct OrderGuess: Hashable, Sendable {
    /// The rooms in the order asked for.
    package let roomIDs: [RoomID]
    let number: Int
}
