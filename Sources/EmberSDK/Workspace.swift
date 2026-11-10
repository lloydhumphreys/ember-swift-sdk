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
    public private(set) var people: [UserID: DirectoryUser] = [:]
    /// Whether the first sidebar has arrived.
    public private(set) var isLoaded = false
    /// Why the latest sidebar didn't arrive; nil once one does.
    public private(set) var loadError: EmberError?
    /// The workspace socket's state.
    public private(set) var connection: ReconnectingSocket.Status = .idle
    /// The latest thing the server refused (a star, a level), to show once and set back to nil.
    public var notice: String?
    /// Where the directory is: `people` is empty until it has loaded once.
    public private(set) var directoryStatus: DirectoryStatus = .loading

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
        didSet { if let currentRoomID { markRead(currentRoomID) } }
    }

    /// The server no longer knows this session (the socket closed as revoked, or a request answered
    /// 401). The app goes back to signing in.
    @ObservationIgnored public var onSignedOut: (@MainActor () -> Void)?

    private var state = SidebarState()

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
    public var rooms: [SidebarRoom] { state.rooms }
    /// Your stars.
    public var favorites: Favorites { state.favorites }
    /// The workspace's order for shared rooms.
    public var sharedOrder: [RoomID] { state.sharedOrder }
    /// The people the sidebar offers DMs with.
    public var suggestions: [User] { state.suggestions }
    /// An invitation an administrator hasn't dismissed yet.
    public var invitation: Invitation? { state.invitation }

    /// Shared rooms, none hidden, in sidebar order.
    public var sharedRooms: [SidebarRoom] {
        RoomList.shared(state.rooms, favorites: state.favorites.rooms, sharedOrder: state.sharedOrder)
    }

    /// DMs, none hidden, latest active first.
    public var directRooms: [SidebarRoom] { RoomList.directs(state.rooms) }

    /// The people to suggest DMs with, leaving out those you have DMs with.
    public var suggestedPeople: [User] { RoomList.suggestedPeople(state.suggestions, rooms: state.rooms) }

    /// The rooms marked unread, shared then DMs. The room on screen never is.
    public var unreadRooms: [SidebarRoom] {
        (sharedRooms + directRooms).filter { RoomList.isMarkedUnread($0, currentRoomID: currentRoomID) }
    }

    /// How many rooms are marked unread.
    public var unreadCount: Int { unreadRooms.count }

    /// The room with `id`, when you're in it.
    public func room(_ id: RoomID) -> SidebarRoom? {
        state.rooms.first { $0.id == id }
    }

    /// Whether you've starred the room.
    public func isFavorite(_ id: RoomID) -> Bool {
        state.favorites.rooms.contains(id)
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
    /// holds a lease on, each catching up from its `seq`. Nothing when already started, or after
    /// `shutdown()`.
    public func start() {
        guard !started, !isShutDown else { return }
        started = true
        let socket = socket ?? makeSocket()
        self.socket = socket
        socket.start()
        for session in liveSessions { session.resume() }
        if !isLoaded { Task { await reload() } }
    }

    /// Closes the socket and every room's, as when the app goes to the background; the rooms keep
    /// their leases. `start()` opens them all again, and the welcomes bring them up to date. A room
    /// opened meanwhile waits for `start()`.
    public func stop() {
        started = false
        check?.cancel()
        check = nil
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

    /// Loads the sidebar and directory again, as pull to refresh does. A reload asked for while one
    /// is on its way runs once more after it, since the one on its way may have read too early.
    public func reload() async {
        guard !isShutDown else { return }
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
    public func session(for roomID: RoomID, around messageID: String? = nil) -> RoomSession {
        if let session = sessions[roomID] ?? takeBack(roomID) {
            if let messageID { session.jump(to: messageID) }
            touch(roomID)
            trimSessions()
            return session
        }
        let session = RoomSession(client: client, roomID: roomID, around: messageID)
        if !started { session.holdBack() }
        guard !isShutDown else { return session }
        adopt(session)
        touch(roomID)
        trimSessions()
        return session
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
        let task = Task { [weak self] in
            await self?.loadDirectory()
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
        return socket
    }

    private func socketChanged(_ status: ReconnectingSocket.Status) {
        connection = status
        if case .stopped(.signedOut) = status { confirmSignedOut() }
    }

    /// Handles one frame from the workspace socket.
    func handle(_ frame: WorkspaceFrame) {
        switch frame {
        case let .welcome(you, account):
            me = you
            self.account = account
            Task { await reload() }
        case let .accountUpdated(account):
            self.account = account
        case let .userUpdated(user):
            let refetch = state.apply(frame, me: me, directory: Array(people.values))
            people[user.id] = user
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
            if state.apply(frame, me: me, directory: Array(people.values)) { Task { await reload() } }
        }
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
        async let sidebar = client.sidebar()
        async let directory: Void = loadDirectory()
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

    private func loadDirectory() async {
        if case .failed = directoryStatus { directoryStatus = .loading }
        let answer: Result<Directory, any Error>
        do { answer = .success(try await client.directory()) } catch { answer = .failure(error) }
        guard !isShutDown else { return }
        switch answer {
        case let .success(directory):
            people = Dictionary(directory.users.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            directoryStatus = .loaded
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
