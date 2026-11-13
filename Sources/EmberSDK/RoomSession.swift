import Foundation
import Observation

/// One room, live: its socket and the timeline its frames add up to.
///
/// Frames go through `Timeline.apply`, and what it answers (checks for unconfirmed messages,
/// messages to send again) goes straight back. A message sent while the socket is closed waits in
/// `timeline.pending` and goes once the room lets the socket in again.
///
/// The socket is open while anything holds a lease on the session (`open()`, or `start()`, which
/// takes the session's own), and closes with the last.
@MainActor @Observable public final class RoomSession {
    /// The room.
    public let roomID: RoomID
    /// The server the room is on.
    @ObservationIgnored public let client: EmberClient
    /// What the room's frames add up to.
    public internal(set) var timeline = Timeline()
    /// `.stopped(.notFound)` when the room is gone or you're no longer in it.
    public private(set) var status: ConnectionStatus = .idle
    /// Where the room's connection is, as a screen shows it: `status`, and whether the room has let
    /// the socket in.
    public private(set) var phase: Phase = .idle
    /// The latest thing the room refused that nothing else answers for: not a pending message's
    /// failure, and not an edit, deletion or boost, which throw instead. It also names the files
    /// `send(files:…)` refused as too large. The view shows it and sets it back to nil.
    public var notice: String?
    /// Whether the app is in front, which the room shows others as presence.
    public private(set) var isVisible = true
    /// Whether a page around a message is on its way, from `jump(to:)` (or `init(…around:)`) until it
    /// arrives, the room refuses it, or `jumpToLatest()` takes its place. Paging waits meanwhile.
    public private(set) var isJumping = false

    /// The socket closed because the session is gone. `Workspace` sets it to sign out.
    @ObservationIgnored public var onSignedOut: (@MainActor () -> Void)?

    @ObservationIgnored private var socket: ReconnectingSocket?
    /// Whether the room has let the socket in (a welcome or resumed has arrived since it opened).
    /// Nothing goes before that, as on the web.
    @ObservationIgnored private var admitted = false
    /// What the next connection opens on; back to `.catchUp` once it has.
    @ObservationIgnored private var aroundOnConnect = Opening.catchUp
    /// What the open connection asked to open on.
    @ObservationIgnored private var askedAround = Opening.catchUp
    /// Whether the open connection said the app was in front.
    @ObservationIgnored private var askedVisible = true
    /// The message being jumped to, asked for again should the socket drop before its page comes.
    @ObservationIgnored private var jumpTarget: MessageID?
    /// How many `history.around` requests the open connection has sent and not had answered.
    @ObservationIgnored private var aroundsAsked = 0
    /// The first message shown when an older page was asked for while the room hadn't let the socket
    /// in, so the page goes once it has, should that message still be first.
    @ObservationIgnored private var olderWanted: MessageID?
    /// The same for a newer page, by the last message shown.
    @ObservationIgnored private var newerWanted: MessageID?

    /// How many leases are open, `start()`'s included.
    @ObservationIgnored private(set) var leases = 0
    /// The lease `start()` takes and `stop()` closes.
    @ObservationIgnored private var ownLease: RoomLease?
    /// Set by `Workspace` while it's stopped: leases are kept, but the socket stays closed.
    @ObservationIgnored private(set) var isHeldBack = false
    /// Hears the number of leases change, for `Workspace`'s cache.
    @ObservationIgnored var onLeasesChanged: (@MainActor () -> Void)?

    /// Threads that hear the room's frames: those a screen holds, in the order they were opened, and
    /// those let go of with a reply or file still unsettled.
    @ObservationIgnored var threads: [ThreadSession] = []
    /// The thread the server has open for this connection: the last `thread.open` sent on it.
    @ObservationIgnored var openThread: MessageID?
    /// Files waiting to go up, and texts waiting on the files ahead of them, in the order sent.
    @ObservationIgnored var outgoing: [Outgoing] = []
    /// The file going up now. One at a time, as on the web.
    @ObservationIgnored var running: RunningUpload?
    /// Files that failed, kept so `retry` can send them again.
    @ObservationIgnored var failedUploads: [ClientMessageID: UploadJob] = [:]

    /// Where unsent text messages are kept across launches.
    @ObservationIgnored public let unsentStore: any UnsentMessageStore
    /// Whose they are, once `Workspace` or the room's first welcome has said.
    @ObservationIgnored private var unsentKey: UnsentMessageKey?
    /// What `unsentStore` is known to hold for `unsentKey`, so an unchanged list isn't written again.
    @ObservationIgnored private var savedUnsent: [UnsentMessage] = []
    /// Writes `unsentStore` off the main actor, shared with every session on it.
    @ObservationIgnored private let unsentWriter: UnsentWriter
    /// Why what `unsentStore` kept couldn't be read, while it's still to be: nothing is written
    /// over it meanwhile, and messages sent meanwhile are kept with it once it reads.
    @ObservationIgnored private var unsentReadFailure: UnsentStoreError?
    /// Whether what was read is to be written even unchanged: some of it couldn't be read.
    @ObservationIgnored private var unsentRewriteOwed = false
    /// Whether the unsent messages are on disk as they are now. The session goes on working when
    /// they can't be: it tries again on its next change, as it starts or comes to the front, and on
    /// `flushUnsent()`.
    public private(set) var unsentState: UnsentState = .saved
    /// What was lost of the unsent messages kept from before: a file that couldn't be read, in whole
    /// or in part (`.corrupt`, with `lost` and `recovered`), and was kept in the store's quarantine.
    public private(set) var unsentLoss: UnsentStoreError?
    /// Failed replies in threads no screen holds, kept until their thread is asked for again.
    @ObservationIgnored var parkedReplies: [UnsentMessage] = []
    /// How long a message may go unconfirmed before it shows as failed (`notSent`), counted from
    /// when it was sent or retried, whatever the connection does meanwhile. One that fails before
    /// it was written to a socket isn't sent when the connection returns.
    @ObservationIgnored public var sendTimeout: Duration = .seconds(30)
    /// How long a page of older or newer messages may go unanswered before it fails, as one the room
    /// refused does (`timeline.olderPageFailure`, `timeline.newerPageFailure`).
    public static let pageTimeout: Duration = .seconds(15)
    /// Counts connections, so a timer started on one does nothing on the next.
    @ObservationIgnored private var connection = 0
    /// The timers of messages sent or retried and not yet confirmed or failed.
    @ObservationIgnored private var sendTimers: [ClientMessageID: Task<Void, Never>] = [:]
    /// The timers of the older and newer pages on their way.
    @ObservationIgnored private var olderTimer: Task<Void, Never>?
    @ObservationIgnored private var newerTimer: Task<Void, Never>?
    /// The messages and replies created on this connection, since their last retry. The room answers
    /// a socket's frames in order, so a check's `missing` for one of them comes from a check sent
    /// before the create, and sending it again would store it twice.
    @ObservationIgnored private var created: Set<ClientMessageID> = []
    /// Whether the socket was kept open after the last lease closed, for unsent messages.
    @ObservationIgnored private var lingering = false
    /// Changes sent with the `async` forms of edit, delete and boost, waiting to be shown made.
    @ObservationIgnored var changes: [ChangeWaiter] = []
    /// How far each file got before it failed, so a retry goes on from there.
    @ObservationIgnored var uploadCheckpoints: [ClientMessageID: UploadCheckpoint] = [:]
    /// What keeps a file going up when the app leaves the foreground: the client's `backgroundTime`
    /// unless changed.
    @ObservationIgnored public var backgroundTime: BackgroundTime

    @ObservationIgnored private var typingSent = false
    @ObservationIgnored private var typingThrottled = false
    @ObservationIgnored private var throttle: Task<Void, Never>?
    @ObservationIgnored private var pause: Task<Void, Never>?

    /// A session for a room on `client`. With `messageID`, it opens on the page around that message.
    /// Unsent messages are kept in the client's `unsentStore`.
    public convenience init(client: EmberClient, roomID: RoomID, around messageID: MessageID? = nil) {
        self.init(client: client, roomID: roomID, around: messageID, unsentStore: client.unsentStore)
    }

    /// A session for a room on `client` that keeps its unsent messages in `unsentStore` rather than
    /// the client's.
    public init(client: EmberClient, roomID: RoomID, around messageID: MessageID? = nil, unsentStore: any UnsentMessageStore) {
        self.client = client
        self.roomID = roomID
        self.unsentStore = unsentStore
        unsentWriter = UnsentWriter.writer(for: unsentStore)
        backgroundTime = client.backgroundTime
        aroundOnConnect = messageID.map(Opening.message) ?? .catchUp
        jumpTarget = messageID
        isJumping = messageID != nil
        let socket = client.roomSocket { [weak self] in
            self?.nextRequest() ?? URLRequest(url: client.origin)
        }
        socket.onStatus = { [weak self] status in self?.socketChanged(status) }
        socket.onText = { [weak self] text in self?.handle(ServerFrame(text: text)) }
        self.socket = socket
    }

    deinit {
        if let socket = socket {
            Task { @MainActor in socket.stop() }
        }
        throttle?.cancel()
        pause?.cancel()
        for timer in sendTimers.values { timer.cancel() }
        olderTimer?.cancel()
        newerTimer?.cancel()
    }

    // MARK: Connecting

    /// Takes a lease on the room: the socket opens, unless another lease has it open already. Close
    /// the lease (or let go of it) when the room is no longer shown.
    public func open() -> RoomLease {
        leases += 1
        if leases == 1 {
            retryUnsent()
            connect()
        }
        onLeasesChanged?()
        return RoomLease(self)
    }

    /// Connects, visible, by taking the session's own lease. Nothing when already started.
    public func start() {
        guard ownLease == nil else { return }
        ownLease = open()
    }

    /// Closes the session's own lease, which leaves the room unless something else holds one. The
    /// timeline stays, so coming back shows it at once and catches up from its `seq`.
    public func stop() {
        ownLease?.close()
        ownLease = nil
    }

    /// A lease has closed. With the last, the socket closes, unless a message is still unsent: then
    /// it stays open until none is (`releaseIfIdle()`).
    func leaseClosed() {
        leases = max(0, leases - 1)
        if leases == 0 {
            if hasUnsentMessages {
                lingering = true
            } else {
                socket?.stop()
            }
        }
        onLeasesChanged?()
    }

    /// Whether a text message is on its way, the room's or a thread's: pending and not failed.
    var hasUnsentMessages: Bool {
        timeline.pending.contains { $0.upload == nil && $0.failure == nil } || threads.contains(where: \.hasUnsettled)
    }

    /// Closes a socket kept open for unsent messages once none is left, and tells `Workspace`, whose
    /// cache may let go of the session now.
    func releaseIfIdle() {
        guard lingering, leases == 0, !hasUnsentMessages else { return }
        lingering = false
        socket?.stop()
        onLeasesChanged?()
    }

    /// Closes the socket and keeps it closed, leases and all, until `resume()`.
    func holdBack() {
        isHeldBack = true
        socket?.stop()
    }

    /// Opens the socket again after `holdBack()`, if anything holds a lease.
    func resume() {
        isHeldBack = false
        retryUnsent()
        connect()
    }

    /// Let go of by `Workspace`'s cache: the socket closes, and every file going, waiting or failed
    /// stops, its temporary copy deleted and its pending message dropped, since nothing may ever come
    /// back to retry it. The workspace still knows the session (weakly) and takes it back should a
    /// screen open it or ask for its room again, so `onLeasesChanged` stays.
    ///
    /// Threads are left as they are: the cache only lets go of a session with none to settle, and a
    /// session that's taken back needs its threads to go on hearing its frames.
    func detach() {
        onSignedOut = nil
        lingering = false
        socket?.stop()
        dropUploads()
    }

    /// Done with, as the workspace is shut down: closed for good, typing timers and all.
    func shutDown() {
        // What's unsent now is handed over before anything else can be.
        saveUnsent()
        isShutDown = true
        onLeasesChanged = nil
        detach()
        holdBack()
        // Each thread holds its room, and the room its threads: unless they're let go of here, a
        // thread with a reply still pending keeps both alive after signing out. Pending replies stay
        // as they are, as the room's own pending messages do.
        for thread in threads { thread.end() }
        threads = []
        openThread = nil
        throttle?.cancel()
        throttle = nil
        pause?.cancel()
        pause = nil
    }

    /// Whether the workspace has shut the session down. Nothing registers with it afterwards.
    @ObservationIgnored private(set) var isShutDown = false

    /// Stops every file (`cancelUploads()`) and drops the pending messages they showed as, which
    /// would otherwise show as going up for good and keep their thread unsettled.
    private func dropUploads() {
        var dropped: [UploadJob] = running.map { [$0.job] } ?? []
        for item in outgoing { if case let .file(job) = item { dropped.append(job) } }
        dropped += failedUploads.values
        cancelUploads()
        for job in dropped {
            if let thread = job.thread {
                thread.discard(job.clientMessageId)
            } else {
                timeline.discard(job.clientMessageId)
            }
        }
    }

    private func connect() {
        guard leases > 0 || lingering, !isHeldBack else { return }
        socket?.start()
    }

    /// Connects again after the server stopped the connection (`phase` is `.stopped`), as a Retry
    /// button asks, while a lease holds the room. Does nothing while the room is connected or
    /// connecting, when nothing holds it, while `Workspace` holds it back, and after a stop for
    /// signing out, which only signing in again mends.
    public func reconnect() {
        guard case let .stopped(reason) = status, reason != .signedOut else { return }
        connect()
    }

    /// Tells the room whether the app is in front (`presence.visible`).
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if admitted { transmit(.visible(visible)) }
    }

    // MARK: Messages

    /// Sends a message: pending at once, sent now or when the socket is next open. Answers its
    /// `clientMessageId`, a lowercase UUID as the web makes them. `previews` go after the body.
    @discardableResult
    public func send(body: String, plainText: String, previews: [LinkPreview] = []) -> ClientMessageID {
        let clientMessageId = ClientMessageID(UUID().uuidString.lowercased())
        let body = withPreviews(body, previews)
        let frame = timeline.send(body: body, plainText: plainText, clientMessageId: clientMessageId)
        // While the room hasn't let the socket in, the message waits, timed from now: the welcome's
        // `message.check` finds it missing, and the room's answer sends it.
        if admitted { transmitMessage(frame) } else { watchSend(clientMessageId) }
        saveUnsent()
        return clientMessageId
    }

    /// Sends a failed message again, under the same id. The room is asked first whether it has the
    /// message, as one that failed for want of an answer may have been stored, and it's created only
    /// if the room says it's missing. A file that failed goes on from the part after the last the
    /// server took (from the start if the server forgot the upload), after any still waiting.
    public func retry(_ clientMessageId: ClientMessageID) {
        if timeline.pending.first(where: { $0.clientMessageId == clientMessageId })?.upload != nil {
            _ = timeline.retry(clientMessageId)
            retryUpload(clientMessageId)
            return
        }
        guard timeline.retry(clientMessageId) != nil else { return }
        if admitted { checkAgain(clientMessageId) } else { watchSend(clientMessageId, again: true) }
        saveUnsent()
    }

    /// Asks the room whether it has `id`, a message or reply sent again, and times it from now. The
    /// answer creates it if the room says it's missing.
    func checkAgain(_ id: ClientMessageID) {
        created.remove(id)
        transmit(.checkMessages(clientMessageIds: [id]))
        watchSend(id, again: true)
    }

    /// A message goes at the end of the newest page, which a timeline reading older history (or on its
    /// way to a page) asks for first, as the web does: otherwise its confirmation lands past the end
    /// of the window and isn't shown.
    func transmitMessage(_ frame: ClientFrame) {
        if timeline.hasNewer || timeline.isLoadingPage || isJumping {
            endJump()
            askAround(nil)
        }
        transmit(frame)
        if case let .createMessage(id, _, _, _) = frame {
            created.insert(id)
            watchSend(id)
        }
    }

    /// Sends a thread's reply on this connection, remembered as created, as `transmitMessage(_:)`
    /// remembers a room message: a check sent before it that finds it missing mustn't create it again.
    func transmitReply(_ frame: ClientFrame) {
        transmit(frame)
        if case let .createMessage(id, _, _, _) = frame { created.insert(id) }
    }

    /// Forgets a pending message. A file on its way up stops.
    public func discard(_ clientMessageId: ClientMessageID) {
        discardUpload(clientMessageId)
        timeline.discard(clientMessageId)
        saveUnsent()
        releaseIfIdle()
    }

    /// The `failure` of a message the room hasn't confirmed within `sendTimeout`.
    public static let notSent = "Not sent. Try again, or discard it."

    /// Fails `id`, a room message or a thread's reply, should it still be unconfirmed `sendTimeout`
    /// after it was asked for. A timer already running for it goes on, unless `again`, as a retry
    /// is timed from the retry.
    func watchSend(_ id: ClientMessageID, again: Bool = false) {
        if !again, sendTimers[id] != nil { return }
        sendTimers[id]?.cancel()
        let timing = client.timing
        let timeout = sendTimeout
        sendTimers[id] = Task { [weak self] in
            do { try await timing.sleep(for: timeout) } catch { return }
            self?.sendTimedOut(id)
        }
    }

    private func sendTimedOut(_ id: ClientMessageID) {
        sendTimers[id] = nil
        let isUnsent: (PendingMessage) -> Bool = { $0.clientMessageId == id && $0.upload == nil && $0.failure == nil }
        if timeline.pending.contains(where: isUnsent) {
            _ = timeline.fail(id, reason: Self.notSent)
        } else if let thread = threads.first(where: { $0.timeline.pending.contains(where: isUnsent) }) {
            _ = thread.fail(id, reason: Self.notSent)
            settle(thread)
        } else {
            return
        }
        saveUnsent()
        releaseIfIdle()
    }

    /// Hands `unsentStore`'s writer the room's unsent and failed texts and thread replies, when
    /// they differ from what it was last handed (or, with nothing of it still to write, from what's
    /// known written). Nothing until the session knows who you are, nor while what was kept is still
    /// to be read, nor once shut down.
    func saveUnsent() {
        guard let unsentKey, !isShutDown, unsentReadFailure == nil else {
            updateUnsentState()
            return
        }
        let messages = timeline.pending.filter { $0.upload == nil && $0.parentId == nil }
        let replies = threads.flatMap { $0.timeline.pending.filter { $0.upload == nil } }
        let unsent = (messages + replies).map(UnsentMessage.init) + parkedReplies
        if unsent != (unsentWriter.handed(for: unsentKey) ?? savedUnsent) || unsentRewriteOwed {
            unsentRewriteOwed = false
            unsentWriter.save(unsent, for: unsentKey)
        }
        updateUnsentState()
    }

    /// Waits for the room's unsent messages to be written, as they are now. What couldn't be read
    /// before is read again first, and a write that failed is tried again. Throws the store's
    /// error should either fail; the session goes on working, and tries again later.
    public func flushUnsent() async throws {
        if unsentReadFailure != nil, !isShutDown { readUnsent() }
        if let unsentReadFailure { throw unsentReadFailure }
        guard let unsentKey else { return }
        saveUnsent()
        try await unsentWriter.flush(unsentKey)
    }

    /// Reads again what couldn't be read, or hands over again what couldn't be written.
    private func retryUnsent() {
        guard let unsentKey, !isShutDown else { return }
        if unsentReadFailure != nil {
            readUnsent()
        } else {
            unsentWriter.retry(unsentKey)
            saveUnsent()
        }
    }

    /// How a write of the session's key went, from its writer.
    func unsentWritten(_ outcome: UnsentWriter.Outcome) {
        switch outcome {
        case let .saved(messages): savedUnsent = messages
        case .removed: savedUnsent = []
        case .failed: break
        }
        updateUnsentState()
    }

    private func updateUnsentState() {
        let state: UnsentState =
            if let unsentReadFailure { .failed(unsentReadFailure) } else if let unsentKey { unsentWriter.state(for: unsentKey) } else { .saved }
        if unsentState != state { unsentState = state }
    }

    /// Says who's signed in before the room's first welcome does, so what's unsent is read and kept
    /// from the start. `Workspace` calls it as it makes the session.
    func signedIn(as userID: UserID) {
        restoreUnsent(for: userID)
    }

    /// Once the session knows who you are: what `unsentStore` kept for you here comes back as
    /// pending (`readUnsent()`).
    private func restoreUnsent(for userID: UserID) {
        guard unsentKey == nil else { return }
        let key = UnsentMessageKey(server: client.origin, userID: userID, roomID: roomID)
        unsentKey = key
        unsentWriter.listen(self, to: key)
        readUnsent()
    }

    /// What's kept for the session's key, from what its writer was last handed when that's still
    /// to be written, else from `unsentStore`, comes back as pending, under the same ids, joining
    /// what's pending already. Then what's unsent now is saved.
    ///
    /// A file that couldn't be read in part brings back what could, and is written again, once.
    /// One that couldn't be read at all, and was moved aside, brings back nothing, and saving goes
    /// on as for none (`unsentLoss` says which). Any other failure leaves the file as it is: nothing
    /// is written over it until it reads, at the next retry.
    private func readUnsent() {
        guard let unsentKey else { return }
        let saved: [UnsentMessage]
        if let handed = unsentWriter.handed(for: unsentKey) {
            saved = handed
        } else {
            do {
                saved = try unsentStore.messages(for: unsentKey)
                savedUnsent = saved
            } catch {
                let error = UnsentStoreError(error, as: .unreadable)
                guard error.kind == .corrupt else {
                    unsentReadFailure = error
                    updateUnsentState()
                    return
                }
                unsentLoss = error
                saved = error.recovered ?? []
                savedUnsent = saved
                unsentRewriteOwed = error.recovered != nil
            }
        }
        unsentReadFailure = nil
        restoreUnsent(saved)
        saveUnsent()
    }

    /// `saved`, those not pending already, as pending: a room message for the welcome's check, or
    /// for its own once the room has let the socket in. A thread with a reply still on its way is
    /// kept to send it; one whose replies all failed waits until it's asked for.
    private func restoreUnsent(_ saved: [UnsentMessage]) {
        let known = Set((timeline.pending + threads.flatMap(\.timeline.pending)).map(\.clientMessageId))
        let unknown = saved.filter { !known.contains($0.clientMessageId) }
        for message in unknown where message.parentId == nil {
            _ = timeline.send(body: message.body, plainText: message.plainText, clientMessageId: message.clientMessageId, now: message.createdAt)
            if let failure = message.failure {
                _ = timeline.fail(message.clientMessageId, reason: failure)
            } else if admitted {
                checkAgain(message.clientMessageId)
            }
        }
        var replies: [MessageID: [UnsentMessage]] = [:]
        var parents: [MessageID] = []
        for message in unknown {
            guard let parent = message.parentId else { continue }
            if replies[parent] == nil { parents.append(parent) }
            replies[parent, default: []].append(message)
        }
        var kept = false
        for parent in parents {
            let group = replies[parent] ?? []
            if group.contains(where: { $0.failure == nil }), !isShutDown {
                let thread = thread(parent)
                thread.restore(group)
                keep(thread)
                kept = true
            } else {
                parkedReplies += group
            }
        }
        // Each thread's opening checks its replies, as the welcome would have.
        if kept, admitted { reopenThreads() }
    }

    /// The message an edit, deletion or boost throws (`kind` `.unreachable`) when it can't go
    /// because the room isn't connected.
    public static let notConnected = "Not connected. Try again once you’re reconnected."

    // MARK: Typing

    /// Called as the composer changes, true while it has something in it. Sends `typing.start` at
    /// most once a `typingThrottle` (even across a stop, as the web does), and `typing.stop` on false
    /// or once the composer has been left alone for `typingPause`.
    public func setTyping(_ typing: Bool) {
        pause?.cancel()
        pause = nil
        guard typing else {
            stopTyping()
            return
        }
        guard admitted else { return }
        let timing = client.timing
        pause = Task { [weak self] in
            do { try await timing.sleep(for: timing.typingPause) } catch { return }
            self?.stopTyping()
        }
        guard !typingThrottled else { return }
        typingThrottled = true
        typingSent = true
        transmit(.typingStart)
        throttle = Task { [weak self] in
            try? await timing.sleep(for: timing.typingThrottle)
            self?.typingThrottled = false
        }
    }

    private func stopTyping() {
        pause?.cancel()
        pause = nil
        guard typingSent else { return }
        typingSent = false
        if admitted { transmit(.typingStop) }
    }

    // MARK: Paging

    /// Asks for the page before the oldest message, when `timeline.hasMore` and none is on its way.
    /// Nothing while `isJumping`, since the page it's from is about to be replaced. Asked for while
    /// reconnecting, it goes once the room lets the socket in, unless what it was for has been replaced.
    public func loadOlder() {
        guard !isJumping else { return }
        guard admitted else {
            olderWanted = timeline.messages.first?.id
            return
        }
        olderWanted = nil
        guard let frame = timeline.olderPage() else { return }
        transmit(frame)
        watchOlder()
    }

    /// Asks for the page after the newest message, when `timeline.hasNewer` and none is on its way.
    /// Nothing while `isJumping`. Asked for while reconnecting, it waits as `loadOlder()` does.
    public func loadNewer() {
        guard !isJumping else { return }
        guard admitted else {
            newerWanted = timeline.messages.last?.id
            return
        }
        newerWanted = nil
        guard let frame = timeline.newerPage() else { return }
        transmit(frame)
        watchNewer()
    }

    /// Asks again for the older page after `timeline.olderPageFailure`.
    public func retryOlder() {
        guard admitted, !isJumping, let frame = timeline.retryOlderPage() else { return }
        transmit(frame)
        watchOlder()
    }

    /// Asks again for the newer page after `timeline.newerPageFailure`.
    public func retryNewer() {
        guard admitted, !isJumping, let frame = timeline.retryNewerPage() else { return }
        transmit(frame)
        watchNewer()
    }

    /// Fails the older page asked for on this connection, should it still be on its way
    /// `pageTimeout` from now. A late answer still shows.
    private func watchOlder() {
        olderTimer?.cancel()
        let timing = client.timing
        let connection = connection
        olderTimer = Task { [weak self] in
            do { try await timing.sleep(for: Self.pageTimeout) } catch { return }
            guard let self, connection == self.connection else { return }
            olderTimer = nil
            timeline.olderPageFailed()
        }
    }

    /// Fails the newer page asked for on this connection, should it still be on its way
    /// `pageTimeout` from now.
    private func watchNewer() {
        newerTimer?.cancel()
        let timing = client.timing
        let connection = connection
        newerTimer = Task { [weak self] in
            do { try await timing.sleep(for: Self.pageTimeout) } catch { return }
            guard let self, connection == self.connection else { return }
            newerTimer = nil
            timeline.newerPageFailed()
        }
    }

    /// Whether the reader has scrolled away from the newest message, so a reconnect that can't
    /// catch up keeps their place instead of showing the newest page.
    public func setAwayFromLatest(_ away: Bool) {
        timeline.setAwayFromLatest(away)
    }

    /// Shows the page around a message (`history.around`); `timeline.anchor` says where to scroll.
    public func jump(to messageID: MessageID) {
        forgetWantedPages()
        jumpTarget = messageID
        isJumping = true
        if admitted {
            askAround(messageID)
        } else {
            aroundOnConnect = .message(messageID)
        }
    }

    /// Shows the newest page again, after a jump, or instead of one on its way.
    public func jumpToLatest() {
        forgetWantedPages()
        endJump()
        timeline.setAwayFromLatest(false)
        if admitted {
            askAround(nil)
        } else {
            aroundOnConnect = .latest
        }
    }

    /// The view has scrolled to `timeline.anchor`, so it's forgotten and not scrolled to again.
    public func anchorShown() {
        timeline.clearAnchor()
    }

    private func askAround(_ messageID: MessageID?) {
        aroundsAsked += 1
        transmit(timeline.pageAround(messageID))
    }

    /// A `history.around` has been answered, with a page or a refusal: the jump is over once nothing
    /// asked for since is still on its way.
    private func aroundAnswered() {
        aroundsAsked = max(0, aroundsAsked - 1)
        if aroundsAsked == 0 { endJump() }
    }

    private func endJump() {
        jumpTarget = nil
        if isJumping { isJumping = false }
    }

    private func forgetWantedPages() {
        olderWanted = nil
        newerWanted = nil
    }

    /// Sends the pages asked for while reconnecting, for the messages still at the ends they were for.
    private func sendWantedPages() {
        let older = olderWanted
        let newer = newerWanted
        forgetWantedPages()
        guard !isJumping else { return }
        if let older, older == timeline.messages.first?.id { loadOlder() }
        if let newer, newer == timeline.messages.last?.id { loadNewer() }
    }

    // MARK: Frames

    /// What a connection opens on.
    private enum Opening: Equatable {
        /// What changed since the timeline's `seq`, or the newest page for a timeline not loaded yet.
        case catchUp
        /// The page around a message.
        case message(MessageID)
        /// The newest page, whatever the timeline shows.
        case latest
    }

    /// The request for the next connection: catching up from the timeline's `seq`, or opening around
    /// the message asked for or on the newest page, which a `seq` would skip.
    private func nextRequest() -> URLRequest {
        askedAround = aroundOnConnect
        askedVisible = isVisible
        switch aroundOnConnect {
        case .catchUp:
            let since = timeline.isLoaded ? timeline.seq : nil
            return client.roomSocketRequest(roomID: roomID, visible: isVisible, since: since, around: nil)
        case let .message(id):
            return client.roomSocketRequest(roomID: roomID, visible: isVisible, since: nil, around: id)
        case .latest:
            return client.roomSocketRequest(roomID: roomID, visible: isVisible, since: nil, around: nil)
        }
    }

    /// Asks the open connection for what `opening` names, which it didn't ask for on connecting.
    private func ask(_ opening: Opening) {
        switch opening {
        case .catchUp: break
        case let .message(id): askAround(id)
        case .latest: askAround(nil)
        }
    }

    private func socketChanged(_ status: ConnectionStatus) {
        self.status = status
        let phase: Phase = switch status {
        case .idle: .idle
        case .connecting, .open: self.phase == .admitted || self.phase == .reconnecting ? .reconnecting : .connecting
        case let .stopped(reason): .stopped(reason)
        }
        if phase != self.phase { self.phase = phase }
        guard status != .open else { return }
        timeline.disconnected()
        admitted = false
        // What was sent on the connection that dropped waits for the next one's check, still timed
        // from when it was asked for. A page on its way failed with the connection.
        connection += 1
        olderTimer?.cancel()
        newerTimer?.cancel()
        olderTimer = nil
        newerTimer = nil
        created = []
        changesDisconnected(status)
        // Whatever page was on its way won't come on this connection: the next one opens around it.
        aroundsAsked = 0
        if let jumpTarget { aroundOnConnect = .message(jumpTarget) }
        openThread = nil
        for thread in threads { thread.disconnected() }
        typingSent = false
        pause?.cancel()
        pause = nil
        if case .stopped(.signedOut) = status {
            client.sessionEnded()
            onSignedOut?()
        }
    }

    /// Handles one frame from the room's socket.
    func handle(_ frame: ServerFrame) {
        switch frame {
        case let .welcome(you, _, _, _):
            // Read (or read again, after a failure) before the welcome's check, which asks about
            // what's pending.
            if unsentKey == nil { restoreUnsent(for: you.id) } else if unsentReadFailure != nil { readUnsent() }
            admitted = true
            if phase != .admitted { phase = .admitted }
        case .resumed:
            admitted = true
            if phase != .admitted { phase = .admitted }
        case let .error(message, clientMessageId, clientMessageIds, failed):
            let ids = Set(clientMessageIds ?? clientMessageId.map { [$0] } ?? [])
            // A reply's refusal is its thread's to show, as a message's is the timeline's.
            let isPending = timeline.pending.contains { ids.contains($0.clientMessageId) }
                || threads.contains { $0.timeline.pending.contains { ids.contains($0.clientMessageId) } }
            // A change sent with an `async` form hears its refusal as a throw instead.
            let isChange = ids.isEmpty && changeRefused(message, failed: failed)
            if !isPending, !isChange, !message.isEmpty, failed != "thread.open", failed != "thread.before",
               failed != "history.before", failed != "history.after" {
                notice = message
            }
            if failed == "history.around" { aroundAnswered() }
        case .historyAround:
            aroundAnswered()
        default:
            break
        }
        let answers = timeline.apply(frame)
        changeShown(frame)
        for answer in answers {
            if case let .createMessage(id, _, _, _) = answer {
                if !isHeldText(id), !created.contains(id) { transmitMessage(answer) }
            } else {
                transmit(answer)
            }
        }
        // Every reply reaches every socket, and nothing says which thread an update or deletion is
        // in, so each thread hears everything and takes what's its own. What a thread sends back
        // goes as it is: a reply never waits on the room's newest page.
        for thread in threads {
            for answer in thread.apply(frame) {
                if case let .createMessage(id, _, _, _) = answer {
                    if isHeldText(id) || created.contains(id) { continue }
                    created.insert(id)
                    watchSend(id)
                }
                transmit(answer)
            }
        }
        // A failed file the frame confirmed (`message.created`, a check's answer, a page) has nothing
        // left to retry: its job and temporary file go now, not at the next send. A pending goes only
        // when confirmed or discarded, so one still failed and waiting for a retry stays.
        dropConfirmedFailures()

        if case .welcome = frame {
            if aroundOnConnect != askedAround {
                // Asked for while this connection was opening, so it didn't ask for it.
                ask(aroundOnConnect)
            }
            // Otherwise the welcome's page is the one the jump asked for.
            if aroundsAsked == 0 { endJump() }
            opened()
            reopenThreads()
        } else if case .resumed = frame {
            // A connection that resumes asked to catch up, so anything else was asked for since.
            ask(aroundOnConnect)
            if aroundsAsked == 0 { endJump() }
            opened()
            reopenThreads()
        }
        for thread in threads where !thread.isHeld { settle(thread) }
        saveUnsent()
        releaseIfIdle()
        // A change still missing after several later ones was lost: connecting again catches up from it.
        if admitted, timeline.needsCatchUp { socket?.stop(); connect() }
    }

    /// The room has let the socket in. What's unsent and not held behind files, and not timed since
    /// it was asked for (one kept from an earlier launch), is timed from here: the check the welcome
    /// sent finds it, and the room's answer sends it or says it's stored. Changes asked for while
    /// it was connecting go now.
    private func opened() {
        aroundOnConnect = .catchUp
        askedAround = .catchUp
        if isVisible != askedVisible { transmit(.visible(isVisible)) }
        for message in timeline.pending + threads.flatMap(\.timeline.pending)
        where message.upload == nil && message.failure == nil && !isHeldText(message.clientMessageId) {
            watchSend(message.clientMessageId)
        }
        sendWaitingChanges()
        sendWantedPages()
    }

    /// Whether the room has let the open socket in, so frames sent now arrive.
    var isAdmitted: Bool { admitted }

    /// Sends `frame` on the socket; false when it couldn't go.
    @discardableResult
    func transmit(sending frame: ClientFrame) -> Bool {
        socket?.send(frame.text) == true
    }

    func transmit(_ frame: ClientFrame) {
        socket?.send(frame.text)
    }
}

extension RoomSession {
    /// Where a room's connection is.
    public enum Phase: Equatable, Sendable {
        /// Not connected, and not trying: nothing holds the room, or the app is in the background.
        case idle
        /// Connecting, or connected and waiting for the room to let the socket in.
        case connecting
        /// The room has let the socket in: what's sent now arrives.
        case admitted
        /// The connection dropped after the room had let it in, and is being made again.
        case reconnecting
        /// The server said not to come back.
        case stopped(ConnectionStatus.StopReason)
    }
}
