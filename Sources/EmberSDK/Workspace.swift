import Foundation
import Observation

/// Everything the signed-in person's sidebar knows, kept current by the workspace socket.
///
/// An app makes one after signing in, calls `start()` when it comes to the front and `stop()` when
/// it goes to the back, sets `onSignedOut` to go back to signing in, and calls `shutdown()` when it's
/// done with it.
@MainActor @Observable public final class Workspace {
    /// The server this workspace is on.
    @ObservationIgnored public let client: EmberClient
    /// Who's signed in, as the latest welcome or `user.updated` has them.
    public private(set) var me: Me
    /// The workspace's name and switches.
    public private(set) var account: Account
    /// The directory, by id.
    public private(set) var people: [UserID: DirectoryUser] = [:] {
        didSet {
            directory = Array(people.values)
            // Someone suggested who's been banned or let back in since is left out or back.
            if suggestions.contains(where: { RoomList.isSuggestable($0.id, people: oldValue) != RoomList.isSuggestable($0.id, people: people) }) {
                sortCount += 1
                publishSuggestedPeople()
            }
        }
    }
    /// Whether the first sidebar has arrived.
    public private(set) var isLoaded = false
    /// Why the latest sidebar didn't arrive; nil once one does.
    public private(set) var loadError: EmberError?
    /// The workspace socket's state.
    public private(set) var connection: ConnectionStatus = .idle
    /// The latest thing the server refused (a star, a level), to show once and set back to nil.
    public var notice: String?
    /// Where the directory is: `people` is empty until it has loaded once.
    public private(set) var directoryStatus: DirectoryStatus = .loading
    /// Whether the workspace socket last heard there's a network. Its sockets try again as soon as
    /// it's back.
    public private(set) var isNetworkAvailable = true

    /// Where the directory is.
    public enum DirectoryStatus: Equatable, Sendable {
        /// Not loaded yet.
        case loading
        /// Loaded; a reload keeps it loaded until it answers.
        case loaded
        /// It didn't load, and why.
        case failed(String)
    }

    /// How many sessions with no lease are kept, latest used first, so going back to a room shows it
    /// at once.
    public static let idleSessionLimit = 8

    /// The room on screen, which counts as read while it's open. A room view sets and clears it.
    public var currentRoomID: RoomID? {
        didSet {
            if let currentRoomID { markRead(currentRoomID) }
            publishUnread()
        }
    }

    /// The server no longer knows this session (the socket closed as revoked, or a request answered
    /// 401). The app goes back to signing in.
    @ObservationIgnored public var onSignedOut: (@MainActor () -> Void)?

    /// What the sidebar knows. Each change publishes what's observed of it, each list sorted once.
    @ObservationIgnored private var state = SidebarState() {
        didSet { publish() }
    }
    /// The position of each room in `rooms`.
    @ObservationIgnored private var roomIndex: [RoomID: Int] = [:]
    /// `people`'s values, for the frames that look someone up.
    @ObservationIgnored private var directory: [DirectoryUser] = []
    /// How many times the sidebar's lists have been sorted.
    @ObservationIgnored private(set) var sortCount = 0

    @ObservationIgnored private var socket: ReconnectingSocket?
    @ObservationIgnored private var sessions: [RoomID: RoomSession] = [:]
    /// The rooms in `sessions`, least recently used first.
    @ObservationIgnored private var recency: [RoomID] = []
    /// Sessions the cache has let go of, held weakly: a screen can still hold one after its lease
    /// has lapsed (a room left under others in a navigation stack). While anything holds it, it's
    /// still the room's one session. `session(for:)` hands it back rather than making a second,
    /// opening it takes it back into `sessions`, and `stop()`, `start()` and `shutdown()` reach it
    /// meanwhile, so no live session is ever out of the workspace's reach.
    @ObservationIgnored private var released: [RoomID: Released] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasSignedOut = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var directoryLoading: Task<Void, Never>?
    /// The latest level asked for each room, so only the latest answer counts.
    @ObservationIgnored private var involvementAsks: [RoomID: Int] = [:]
    /// Each room's level as the server last had it, while one is asked for.
    @ObservationIgnored private var involvementKept: [RoomID: Involvement] = [:]
    @ObservationIgnored private var involvementAsked = 0
    @ObservationIgnored private var loadAgain = false
    @ObservationIgnored private var check: Task<Void, Never>?
    /// Whether the next load reads the directory too, and since which person heard (`heardCount`)
    /// it was first asked for.
    @ObservationIgnored private var directoryWanted = false
    @ObservationIgnored private var directoryWantedSince: Int?
    /// How long since a welcome last read the sidebar again.
    @ObservationIgnored private var sinceWelcomeRefresh: (@Sendable () -> Duration)?
    /// How long since the directory last arrived.
    @ObservationIgnored private var sinceDirectory: (@Sendable () -> Duration)?
    /// How many directory loads are asked for or under way.
    @ObservationIgnored private var directoryLoads = 0
    /// Each person heard of while a directory load was asked for or under way, numbered, so its
    /// answer doesn't undo them: it puts back those heard since it was asked for.
    @ObservationIgnored private var heardDuringLoads: [(number: Int, user: DirectoryUser)] = []
    @ObservationIgnored private var heardCount = 0
    /// A welcome's reload put off until `EmberTiming.sidebarRefresh` has passed since the last.
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private let relay = Relay()
    @ObservationIgnored private let signedOutToken: UUID

    /// A workspace for `me`, as signing in or `GET /api/bootstrap` answered, on `client`.
    public init(client: EmberClient, me: Me, account: Account) {
        self.client = client
        self.me = me
        self.account = account
        let relay = relay
        signedOutToken = client.addSignedOutHandler {
            Task { @MainActor in relay.workspace?.signedOut() }
        }
        relay.workspace = self
    }

    deinit {
        client.removeSignedOutHandler(signedOutToken)
        if let socket = socket {
            Task { @MainActor in socket.stop() }
        }
    }

    // MARK: The sidebar

    /// The rooms you're in, as `GET /api/sidebar` lists them, with what the socket has said since.
    public private(set) var rooms: [SidebarRoom] = []
    /// Your stars.
    public private(set) var favorites = Favorites(rooms: [], version: 0)
    /// The workspace's order for shared rooms.
    public private(set) var sharedOrder: [RoomID] = []
    /// The people the sidebar offers DMs with.
    public private(set) var suggestions: [User] = []
    /// An invitation an administrator hasn't dismissed yet.
    public private(set) var invitation: Invitation?

    /// Shared rooms, none hidden, in sidebar order.
    public private(set) var sharedRooms: [SidebarRoom] = []

    /// The starred rooms at the start of `sharedRooms`, which `moveFavorites` moves.
    public var favoriteRooms: [SidebarRoom] { sharedRooms.filter { isFavorite($0.id) } }

    /// Shared rooms, hidden ones too, in the shared order, stars aside, which `moveSharedRooms` moves.
    public private(set) var roomsInSharedOrder: [SidebarRoom] = []

    /// DMs, none hidden, latest active first.
    public private(set) var directRooms: [SidebarRoom] = []

    /// The people to suggest DMs with, leaving out those you have DMs with and anyone the directory
    /// has as banned, deactivated or suspended. It changes as they're banned or let back in.
    public private(set) var suggestedPeople: [User] = []

    /// The rooms marked unread, shared then DMs. The room on screen never is.
    public private(set) var unreadRooms: [SidebarRoom] = []

    /// How many rooms are marked unread.
    public var unreadCount: Int { unreadRooms.count }

    /// The room with `id`, when you're in it.
    public func room(_ id: RoomID) -> SidebarRoom? {
        let rooms = rooms
        guard let index = roomIndex[id], rooms.indices.contains(index), rooms[index].id == id else { return nil }
        return rooms[index]
    }

    /// Whether you've starred the room.
    public func isFavorite(_ id: RoomID) -> Bool {
        favorites.rooms.contains(id)
    }

    /// Sets each observed part of the sidebar that `state` has changed, sorting the lists again only
    /// when what they're sorted from has changed, so a view reading one part hears only its changes.
    private func publish() {
        let roomsChanged = state.rooms != rooms
        let favoritesChanged = state.favorites != favorites
        let orderChanged = state.sharedOrder != sharedOrder
        let suggestionsChanged = state.suggestions != suggestions
        if roomsChanged {
            rooms = state.rooms
            roomIndex = Dictionary(rooms.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if favoritesChanged { favorites = state.favorites }
        if orderChanged { sharedOrder = state.sharedOrder }
        if suggestionsChanged { suggestions = state.suggestions }
        if state.invitation != invitation { invitation = state.invitation }
        guard roomsChanged || favoritesChanged || orderChanged || suggestionsChanged else { return }
        sortCount += 1
        if roomsChanged || favoritesChanged || orderChanged {
            assign(\.sharedRooms, RoomList.shared(rooms, favorites: favorites.rooms, sharedOrder: sharedOrder))
        }
        if roomsChanged || orderChanged {
            assign(\.roomsInSharedOrder, RoomList.inSharedOrder(rooms, sharedOrder: sharedOrder))
        }
        if roomsChanged { assign(\.directRooms, RoomList.directs(rooms)) }
        if roomsChanged || suggestionsChanged { publishSuggestedPeople() }
        publishUnread()
    }

    private func publishSuggestedPeople() {
        assign(\.suggestedPeople, RoomList.suggestedPeople(suggestions, rooms: rooms, people: people))
    }

    private func publishUnread() {
        assign(\.unreadRooms, (sharedRooms + directRooms).filter { RoomList.isMarkedUnread($0, currentRoomID: currentRoomID) })
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Workspace, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: People

    /// A room's name: a shared room's own, and a DM's others in a sentence, as the directory names them.
    public func name(of room: Room) -> String {
        RoomList.name(of: room, me: me.id) { self.name(of: $0) }
    }

    /// Someone's name as the directory has it now, which may be newer than the one a message carries.
    public func name(of user: User) -> String {
        name(ofUserID: user.id) ?? user.name
    }

    /// Someone's name by id, or nil when nobody here has it.
    public func name(ofUserID id: UserID) -> String? {
        if let person = people[id] { return person.name }
        if id == me.id { return me.name }
        if id == Assistant.id { return Assistant.name }
        return nil
    }

    /// Someone in the directory.
    public func person(_ id: UserID) -> DirectoryUser? {
        people[id]
    }

    /// The server path of someone's avatar, for `EmberClient.url(_:)` or `data(at:)`.
    public func avatarPath(for id: UserID) -> String? {
        people[id]?.avatarUrl
    }

    /// Whether `id` is Ember's assistant.
    public func isAssistant(_ id: UserID) -> Bool {
        id == Assistant.id
    }

    // MARK: Actions

    /// Opens the socket and loads the sidebar and directory, and opens again every room something
    /// holds a lease on, each catching up from its `seq`. Unsent messages that failed to be saved, and
    /// removals that failed, are tried again. Nothing when already started, or after
    /// `shutdown()`.
    public func start() {
        guard !started, !isShutDown else { return }
        started = true
        let socket = socket ?? makeSocket()
        self.socket = socket
        socket.start()
        for session in liveSessions { session.resume() }
        UnsentWriter.writer(for: client.unsentStore).retry()
        if !isLoaded { Task { await reload() } }
    }

    /// Closes the socket and every room's, as when the app goes to the background; the rooms keep
    /// their leases. `start()` opens them all again, and the welcomes bring them up to date. A room
    /// opened meanwhile waits for `start()`.
    public func stop() {
        started = false
        check?.cancel()
        check = nil
        refresh?.cancel()
        refresh = nil
        socket?.stop()
        for session in liveSessions { session.holdBack() }
    }

    /// Done with for good, as on signing out: closes every socket, stops every timer and load, and
    /// lets go of the rooms. `start()` does nothing afterwards. Nothing when shut down already.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        stop()
        socket = nil
        loading?.cancel()
        loading = nil
        directoryLoading?.cancel()
        directoryLoading = nil
        for session in liveSessions { session.shutDown() }
        sessions = [:]
        released = [:]
        recency = []
    }

    /// Waits for every room's unsent messages to be written, as the app goes to the background, failed
    /// ones tried again first. Throws the first error, once every room has been tried; what failed is
    /// kept and goes at the next retry.
    public func flushUnsent() async throws {
        var failure: (any Error)?
        for session in liveSessions {
            do { try await session.flushUnsent() } catch { failure = failure ?? error }
        }
        do { try await client.flushUnsent() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// Loads the sidebar and directory again, as pull to refresh does. A reload asked for while one
    /// is on its way runs once more after it, since the one on its way may have read too early.
    public func reload() async {
        await load(directory: true)
    }

    /// Loads the sidebar again, and the directory too when `directory`, coalescing with any load on
    /// its way.
    private func load(directory: Bool) async {
        guard !isShutDown else { return }
        if directory {
            directoryWanted = true
            if directoryWantedSince == nil { directoryWantedSince = heardCount }
        }
        if let loading {
            loadAgain = true
            await loading.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.loadAgain = false
                await self.loadOnce()
            } while self.loadAgain && !Task.isCancelled
            if !Task.isCancelled { self.loading = nil }
        }
        loading = task
        await task.value
    }

    /// Stars or unstars a room at once, and puts it back if the server refuses.
    public func setFavorite(_ favorite: Bool, roomID: RoomID) async {
        let guess = state.beginFavorite(favorite, roomID: roomID)
        do {
            let answer = try await client.setFavorite(favorite, roomID: roomID)
            guard !isShutDown else { return }
            state.acceptFavorite(guess, favorites: answer)
        } catch {
            guard !isShutDown else { return }
            state.rejectFavorite(guess)
            refused(error)
        }
    }

    /// Sets how much of a room reaches you at once, and puts it back if the server refuses. When it's
    /// set again before the server answers, only the latest answer counts.
    public func setInvolvement(_ involvement: Involvement, roomID: RoomID) async {
        guard let shown = room(roomID)?.involvement else { return }
        if involvementAsks[roomID] == nil { involvementKept[roomID] = shown }
        involvementAsked += 1
        let ask = involvementAsked
        involvementAsks[roomID] = ask
        state.setInvolvement(involvement, roomID: roomID)
        let answer: Result<Involvement, any Error>
        do {
            answer = .success(try await client.setInvolvement(involvement, roomID: roomID))
        } catch {
            answer = .failure(error)
        }
        guard !isShutDown else { return }
        let isLatest = involvementAsks[roomID] == ask
        switch answer {
        case let .success(kept):
            if isLatest {
                state.setInvolvement(kept, roomID: roomID)
            } else {
                // A later one is on its way: this is only what to go back to should it be refused.
                involvementKept[roomID] = kept
            }
        case let .failure(error):
            if isLatest, let kept = involvementKept[roomID] { state.setInvolvement(kept, roomID: roomID) }
            if isLatest { refused(error) }
        }
        if isLatest {
            involvementAsks[roomID] = nil
            involvementKept[roomID] = nil
        }
    }

    /// The DM with exactly these people and you, new or the one you had, added to the sidebar.
    public func startDirect(with userIDs: [UserID]) async throws -> SidebarRoom {
        let room = try await client.startDirect(with: userIDs)
        state.add(room)
        return self.room(room.id) ?? SidebarRoom(room: room)
    }

    /// Creates a shared room and adds it to the sidebar. A closed room always has you in it.
    public func createRoom(_ newRoom: NewRoom) async throws -> SidebarRoom {
        var newRoom = newRoom
        if case let .closed(memberIDs) = newRoom.access, !memberIDs.contains(me.id) {
            newRoom.access = .closed(memberIDs: [me.id] + memberIDs)
        }
        let room = try await client.createRoom(newRoom)
        state.add(room)
        return self.room(room.id) ?? SidebarRoom(room: room)
    }

    /// Changes a room, answering it as saved. Closing it without you in it takes it out of the sidebar.
    @discardableResult
    public func changeRoom(_ roomID: RoomID, _ changes: RoomChanges) async throws -> Room {
        let room = try await client.changeRoom(roomID, changes)
        if case let .closed(memberIDs) = changes.access, !memberIDs.contains(me.id) {
            state.remove(roomID)
        } else {
            state.add(room)
        }
        return room
    }

    /// Deletes a room or DM and takes it out of the sidebar.
    public func deleteRoom(_ roomID: RoomID) async throws {
        try await client.deleteRoom(roomID)
        state.remove(roomID)
    }

    /// Moves starred rooms, as `favoriteRooms` lists them, at once. If the server refuses, they go
    /// back, `notice` says why, and the sidebar loads again.
    public func moveFavorites(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        let shown = favoriteRooms.map(\.id)
        let moved = RoomList.moving(shown, fromOffsets: offsets, toOffset: destination)
        guard moved != shown else { return }
        let order = RoomList.reordered(favorites.rooms, by: moved)
        let guess = state.beginFavoriteOrder(order)
        do {
            let answer = try await client.setFavoriteOrder(order)
            guard !isShutDown else { return }
            state.acceptFavoriteOrder(guess, favorites: answer)
        } catch {
            guard !isShutDown else { return }
            state.rejectFavoriteOrder(guess)
            refused(error)
            await load(directory: false)
        }
    }

    /// Moves rooms in the shared order, as `roomsInSharedOrder` lists them, at once, for everyone.
    /// Administrators only. If the server refuses, they go back, `notice` says why, and the sidebar
    /// loads again.
    public func moveSharedRooms(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        let shown = roomsInSharedOrder.map(\.id)
        let moved = RoomList.moving(shown, fromOffsets: offsets, toOffset: destination)
        guard moved != shown else { return }
        await saveSharedOrder(moved)
    }

    /// Clears the shared order, so shared rooms go by name. Administrators only.
    public func clearSharedOrder() async {
        await saveSharedOrder([])
    }

    private func saveSharedOrder(_ order: [RoomID]) async {
        let guess = state.beginSharedOrder(order)
        do {
            let answer = try await client.setSharedOrder(order)
            guard !isShutDown else { return }
            state.acceptSharedOrder(guess, order: answer)
        } catch {
            guard !isShutDown else { return }
            state.rejectSharedOrder(guess)
            refused(error)
            await load(directory: false)
        }
    }

    /// Dismisses the invitation at once, and shows it again if the server refuses.
    public func dismissInvitation() async {
        guard invitation != nil else { return }
        state.beginDismissal()
        do {
            try await client.dismissInvitation()
            guard !isShutDown else { return }
            state.acceptDismissal()
        } catch {
            guard !isShutDown else { return }
            state.rejectDismissal()
            refused(error)
        }
    }

    /// Changes your profile, and shows your new name and bio here at once. Answers it as saved.
    @discardableResult
    public func changeProfile(_ changes: ProfileChanges) async throws -> UserProfile {
        let profile = try await client.changeProfile(changes).profile
        took(profile)
        return profile
    }

    /// Gives you a new picture, and shows it here at once. `variant` is a smaller copy to show in
    /// lists; without one the SDK makes it, when it can read the picture.
    @discardableResult
    public func changeAvatar(_ data: Data, contentType: String, variant: AvatarVariant? = nil) async throws -> UserProfile {
        let profile = try await client.changeAvatar(data, contentType: contentType, variant: variant).profile
        took(profile)
        return profile
    }

    /// Takes your picture away, leaving your initials.
    @discardableResult
    public func removeAvatar() async throws -> UserProfile {
        let profile = try await client.removeAvatar().profile
        took(profile)
        return profile
    }

    /// Your profile as the server just saved it, shown here before the socket says so.
    private func took(_ profile: UserProfile) {
        me.name = profile.name
        guard var mine = people[me.id] else { return }
        mine.name = profile.name
        mine.bio = profile.bio
        mine.avatarUrl = profile.avatarUrl
        heard(mine)
    }

    /// Bans someone: they're signed out, can't come back, and their messages are deleted.
    /// Administrators only. `people` shows them as banned at once.
    public func ban(_ userID: UserID) async throws {
        heard(try await client.ban(userID))
    }

    /// Lets someone banned back in. Their deleted messages stay deleted. Administrators only.
    public func unban(_ userID: UserID) async throws {
        heard(try await client.unban(userID))
    }

    /// Everyone banned, by name, for an administrator to let back in.
    public var bannedPeople: [DirectoryUser] {
        people.values.filter { $0.status == .banned }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Marks a room read here; the room's socket tells the server.
    public func markRead(_ roomID: RoomID) {
        state.markRead(roomID)
    }

    /// A room's live session on this workspace's client: the same one each time for a room, so its
    /// timeline is there on coming back. With `messageID`, it opens on the page around that message.
    ///
    /// Sessions something holds a lease on are kept, and the `idleSessionLimit` latest used of the
    /// rest; the others are let go of, but one that's still held elsewhere is the one answered here
    /// again. Its socket waits for `start()` while the workspace is stopped.
    ///
    /// Without `messageID`, a session left on a page around a message (a search's jump) goes back
    /// to the newest messages, as opening a room does.
    public func session(for roomID: RoomID, around messageID: MessageID? = nil) -> RoomSession {
        if let session = sessions[roomID] ?? takeBack(roomID) {
            if let messageID {
                session.jump(to: messageID)
            } else if session.isJumping || session.timeline.hasNewer || session.timeline.anchor != nil {
                session.jumpToLatest()
            }
            touch(roomID)
            trimSessions()
            return session
        }
        let session = RoomSession(client: client, roomID: roomID, around: messageID)
        session.signedIn(as: me.id)
        if !started { session.holdBack() }
        guard !isShutDown else { return session }
        adopt(session)
        touch(roomID)
        trimSessions()
        return session
    }

    /// A thread in a room's live session, opening at `replyID` when given. The room's session stays
    /// on whatever page it shows, unlike `session(for:)`.
    public func thread(_ parentID: MessageID, in roomID: RoomID, at replyID: MessageID? = nil) -> ThreadSession {
        let room = sessions[roomID] ?? takeBack(roomID) ?? session(for: roomID)
        touch(roomID)
        trimSessions()
        return room.thread(parentID, at: replyID)
    }

    /// Every session still alive: the cache's, and those it let go of that something still holds.
    private var liveSessions: [RoomSession] {
        Array(sessions.values) + released.values.compactMap(\.session)
    }

    /// Puts `session` in the cache, hearing it sign out and its leases change.
    private func adopt(_ session: RoomSession) {
        session.onSignedOut = { [weak self] in self?.signedOut() }
        session.onLeasesChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            self.leasesChanged(session)
        }
        sessions[session.roomID] = session
    }

    /// The session let go of for `roomID`, back in the cache, if anything still holds it.
    private func takeBack(_ roomID: RoomID) -> RoomSession? {
        guard let session = released.removeValue(forKey: roomID)?.session else { return nil }
        adopt(session)
        return session
    }

    private func leasesChanged(_ session: RoomSession) {
        // A screen that kept a session the cache let go of has opened it again.
        if sessions[session.roomID] !== session, released[session.roomID]?.session === session {
            _ = takeBack(session.roomID)
            touch(session.roomID)
        }
        trimSessions()
    }

    /// Loads the directory again, as after `directoryStatus` says it failed.
    public func reloadDirectory() async {
        guard !isShutDown else { return }
        if let directoryLoading {
            await directoryLoading.value
            return
        }
        let start = beginDirectoryLoad()
        let task = Task { [weak self] in
            await self?.loadDirectory(since: start)
            if !Task.isCancelled { self?.directoryLoading = nil }
        }
        directoryLoading = task
        await task.value
    }

    private func touch(_ roomID: RoomID) {
        recency.removeAll { $0 == roomID }
        recency.append(roomID)
    }

    /// Lets go of the least recently used sessions with no lease, beyond `idleSessionLimit`.
    private func trimSessions() {
        // A session with a file going up, or a reply still unsettled, is kept until it's done.
        let idle = recency.filter { sessions[$0].map { $0.leases == 0 && !$0.isBusy } ?? true }
        for roomID in idle.dropLast(Self.idleSessionLimit) {
            recency.removeAll { $0 == roomID }
            guard let session = sessions.removeValue(forKey: roomID) else { continue }
            session.detach()
            released[roomID] = Released(session: session)
        }
        released = released.filter { $0.value.session != nil }
    }

    // MARK: The socket

    private func makeSocket() -> ReconnectingSocket {
        let socket = client.workspaceSocket()
        socket.onStatus = { [weak self] status in self?.socketChanged(status) }
        socket.onText = { [weak self] text in self?.handle(WorkspaceFrame(text: text)) }
        socket.onNetwork = { [weak self] available in self?.isNetworkAvailable = available }
        return socket
    }

    private func socketChanged(_ status: ConnectionStatus) {
        connection = status
        if case .stopped(.signedOut) = status { confirmSignedOut() }
    }

    /// Handles one frame from the workspace socket.
    func handle(_ frame: WorkspaceFrame) {
        switch frame {
        case let .welcome(you, account):
            me = you
            self.account = account
            refreshAfterWelcome()
        case let .accountUpdated(account):
            self.account = account
        case let .userUpdated(user):
            let refetch = state.apply(frame, me: me, directory: directory)
            heard(user)
            if user.id == me.id {
                me = Me(id: me.id, name: user.name, administrator: user.role == .administrator)
            }
            if refetch { Task { await reload() } }
        case let .roomUnread(id) where id == currentRoomID:
            // The room on screen is being read.
            state.apply(frame)
            state.markRead(id)
        case let .error(message):
            if !message.isEmpty { notice = message }
        default:
            if state.apply(frame, me: me, directory: directory) { Task { await reload() } }
        }
    }

    /// A welcome means the socket may have missed something, so the sidebar is read again: at once,
    /// or once `EmberTiming.sidebarRefresh` has passed since a welcome last read it, so a socket
    /// that keeps reconnecting doesn't read it each time. The directory comes too once
    /// `EmberTiming.directoryRefresh` has passed since it last arrived.
    private func refreshAfterWelcome() {
        guard refresh == nil, !isShutDown else { return }
        let timing = client.timing
        let wait = sinceWelcomeRefresh.map { timing.sidebarRefresh - $0() } ?? .zero
        guard wait > .zero else {
            sinceWelcomeRefresh = timing.stopwatch()
            Task { await load(directory: directoryIsStale) }
            return
        }
        refresh = Task { [weak self] in
            try? await timing.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.refresh = nil
            self.sinceWelcomeRefresh = timing.stopwatch()
            await self.load(directory: self.directoryIsStale)
        }
    }

    private var directoryIsStale: Bool {
        guard directoryStatus == .loaded, let sinceDirectory else { return true }
        return sinceDirectory() >= client.timing.directoryRefresh
    }

    /// The socket stopped as signed out: a revoked session is gone, but an upgrade refused on a bad
    /// network is worth asking `/api/me` about first, as the web does. A 401 there signs out through
    /// the client's handler; an answer means try again later.
    private func confirmSignedOut() {
        check?.cancel()
        check = Task { [weak self, client] in
            do {
                _ = try await client.me()
            } catch let error as EmberError where error.isSignedOut {
                client.sessionEnded()
                self?.signedOut()
                return
            } catch {}
            guard let timing = self?.client.timing else { return }
            try? await timing.sleep(for: timing.backoffMax)
            guard !Task.isCancelled, let self, self.started, !self.isShutDown else { return }
            self.socket?.start()
        }
    }

    // MARK: Loading

    private func loadOnce() async {
        state.willLoad()
        let directoryStart = directoryWanted ? beginDirectoryLoad(since: directoryWantedSince) : nil
        directoryWanted = false
        directoryWantedSince = nil
        async let sidebar = client.sidebar()
        async let directory: Void = loadDirectory(since: directoryStart)
        let answer: Result<Sidebar, any Error>
        do { answer = .success(try await sidebar) } catch { answer = .failure(error) }
        // Nothing lands once shut down: the workspace is done with.
        if !isShutDown {
            switch answer {
            case let .success(sidebar):
                state.loaded(sidebar)
                isLoaded = true
                loadError = nil
                if let currentRoomID { state.markRead(currentRoomID) }
            case let .failure(error):
                state.unanswered()
                loadError = error as? EmberError
            }
        }
        await directory
    }

    private func loadDirectory(since start: Int?) async {
        if let start { await loadDirectory(since: start) }
    }

    /// Someone as the socket or the server just had them, kept over any directory answer already
    /// on its way.
    private func heard(_ user: DirectoryUser) {
        people[user.id] = user
        guard directoryLoads > 0 || directoryWantedSince != nil else { return }
        heardCount += 1
        heardDuringLoads.append((heardCount, user))
    }

    /// Counts a directory load from now until `loadDirectory(since:)` ends, and answers where its
    /// people heard begin: `since`, when it was asked for earlier, else now.
    private func beginDirectoryLoad(since: Int? = nil) -> Int {
        directoryLoads += 1
        return since ?? heardCount
    }

    /// Loads the directory, begun with `beginDirectoryLoad(since:)`, and keeps those heard since
    /// `start` over its answer.
    private func loadDirectory(since start: Int) async {
        if case .failed = directoryStatus { directoryStatus = .loading }
        let answer: Result<Directory, any Error>
        do { answer = .success(try await client.directory()) } catch { answer = .failure(error) }
        directoryLoads -= 1
        // Those heard since it was asked for are as new as its answer, or newer.
        let since = heardDuringLoads.filter { $0.number > start }.map(\.user)
        if directoryLoads == 0, directoryWantedSince == nil { heardDuringLoads = [] }
        guard !isShutDown else { return }
        switch answer {
        case let .success(directory):
            var loaded = Dictionary(directory.users.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for user in since { loaded[user.id] = user }
            people = loaded
            directoryStatus = .loaded
            sinceDirectory = client.timing.stopwatch()
        case let .failure(error):
            // A directory that loaded once is still worth showing.
            if directoryStatus != .loaded {
                directoryStatus = .failed((error as? EmberError)?.message ?? "Couldn’t load the directory.")
            }
        }
    }

    private func refused(_ error: any Error) {
        guard let error = error as? EmberError, !error.isSignedOut else { return }
        notice = error.message
    }

    private func signedOut() {
        guard !hasSignedOut else { return }
        hasSignedOut = true
        shutdown()
        onSignedOut?()
    }
}

/// A session the cache let go of, known without being kept.
private struct Released {
    weak var session: RoomSession?
}

/// Points the client's signed-out handler at a workspace without keeping it alive.
@MainActor private final class Relay {
    weak var workspace: Workspace?
}
