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
    public private(set) var status: ReconnectingSocket.Status = .idle
    /// The latest thing the room refused that isn't a pending message's failure (an edit, a boost…).
    /// The view shows it and sets it back to nil.
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
    @ObservationIgnored private var jumpTarget: String?
    /// How many `history.around` requests the open connection has sent and not had answered.
    @ObservationIgnored private var aroundsAsked = 0

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
    @ObservationIgnored var openThread: String?
    /// Files waiting to go up, and texts waiting on the files ahead of them, in the order sent.
    @ObservationIgnored var outgoing: [Outgoing] = []
    /// The file going up now. One at a time, as on the web.
    @ObservationIgnored var running: RunningUpload?
    /// Files that failed, kept so `retry` can send them again.
    @ObservationIgnored var failedUploads: [String: UploadJob] = [:]

    @ObservationIgnored private var typingSent = false
    @ObservationIgnored private var typingThrottled = false
    @ObservationIgnored private var throttle: Task<Void, Never>?
    @ObservationIgnored private var pause: Task<Void, Never>?

    /// A session for a room on `client`. With `messageID`, it opens on the page around that message.
    public init(client: EmberClient, roomID: RoomID, around messageID: String? = nil) {
        self.client = client
        self.roomID = roomID
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
    }

    // MARK: Connecting

    /// Takes a lease on the room: the socket opens, unless another lease has it open already. Close
    /// the lease (or let go of it) when the room is no longer shown.
    public func open() -> RoomLease {
        leases += 1
        if leases == 1 { connect() }
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

    /// A lease has closed.
    func leaseClosed() {
        leases = max(0, leases - 1)
        if leases == 0 { socket?.stop() }
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
        socket?.stop()
        dropUploads()
    }

    /// Done with, as the workspace is shut down: closed for good, typing timers and all.
    func shutDown() {
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
        guard leases > 0, !isHeldBack else { return }
        socket?.start()
    }

    /// Tells the room whether the app is in front (`presence.visible`).
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if admitted { transmit(.visible(visible)) }
    }

    // MARK: Messages

    /// Sends a message: pending at once, sent now or when the socket is next open. Answers its
    /// `clientMessageId`, a lowercase UUID as the web makes them.
    @discardableResult
    public func send(body: String, plainText: String) -> String {
        let clientMessageId = UUID().uuidString.lowercased()
        let frame = timeline.send(body: body, plainText: plainText, clientMessageId: clientMessageId)
        // While the room hasn't let the socket in, the message waits: the welcome's `message.check`
        // finds it missing, and the room's answer sends it.
        if admitted { transmitMessage(frame) }
        return clientMessageId
    }

    /// Sends a refused message again, under the same id. A file that failed goes up again from the
    /// start, after any still waiting.
    public func retry(_ clientMessageId: String) {
        if timeline.pending.first(where: { $0.clientMessageId == clientMessageId })?.upload != nil {
            _ = timeline.retry(clientMessageId)
            retryUpload(clientMessageId)
            return
        }
        guard let frame = timeline.retry(clientMessageId) else { return }
        if admitted { transmitMessage(frame) }
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
    }

    /// Forgets a pending message. A file on its way up stops.
    public func discard(_ clientMessageId: String) {
        discardUpload(clientMessageId)
        timeline.discard(clientMessageId)
    }

    /// What `notice` says when an edit, deletion or boost can't go because the room hasn't let the
    /// socket in.
    public static let notConnected = "Not connected. Try again once you’re reconnected."

    /// Edits one of your messages. Unlike a new message, it isn't kept to send later: false, with
    /// `notice` saying so, when the socket isn't open.
    @discardableResult
    public func edit(_ messageID: String, body: String) -> Bool {
        sendOrWarn(.updateMessage(messageId: messageID, body: body))
    }

    /// Deletes one of your messages. False, with `notice` saying so, when the socket isn't open.
    @discardableResult
    public func delete(_ messageID: String) -> Bool {
        sendOrWarn(.deleteMessage(messageId: messageID))
    }

    /// Boosts a message with an emoji or a few words, trimmed. False, sending nothing, when it doesn't
    /// fit (`Limits.boostFits`), or, with `notice` saying so, when the socket isn't open.
    @discardableResult
    public func boost(_ messageID: String, content: String) -> Bool {
        guard Limits.boostFits(content) else { return false }
        return sendOrWarn(.createBoost(messageId: messageID, content: Limits.trimmedBoost(content)))
    }

    /// Takes back one of your boosts. False, with `notice` saying so, when the socket isn't open.
    @discardableResult
    public func removeBoost(_ boostID: String) -> Bool {
        sendOrWarn(.deleteBoost(boostId: boostID))
    }

    private func sendOrWarn(_ frame: ClientFrame) -> Bool {
        guard admitted, socket?.send(frame.text) == true else {
            notice = Self.notConnected
            return false
        }
        return true
    }

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
    /// Nothing while `isJumping`, since the page it's from is about to be replaced.
    public func loadOlder() {
        guard admitted, !isJumping, let frame = timeline.olderPage() else { return }
        transmit(frame)
    }

    /// Asks for the page after the newest message, when `timeline.hasNewer` and none is on its way.
    /// Nothing while `isJumping`.
    public func loadNewer() {
        guard admitted, !isJumping, let frame = timeline.newerPage() else { return }
        transmit(frame)
    }

    /// Shows the page around a message (`history.around`); `timeline.anchor` says where to scroll.
    public func jump(to messageID: String) {
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
        endJump()
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

    private func askAround(_ messageID: String?) {
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

    // MARK: Frames

    /// What a connection opens on.
    private enum Opening: Equatable {
        /// What changed since the timeline's `seq`, or the newest page for a timeline not loaded yet.
        case catchUp
        /// The page around a message.
        case message(String)
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

    private func socketChanged(_ status: ReconnectingSocket.Status) {
        self.status = status
        guard status != .open else { return }
        timeline.disconnected()
        admitted = false
        // Whatever page was on its way won't come on this connection: the next one opens around it.
        aroundsAsked = 0
        if let jumpTarget { aroundOnConnect = .message(jumpTarget) }
        openThread = nil
        for thread in threads { thread.disconnected() }
        typingSent = false
        pause?.cancel()
        pause = nil
        if case .stopped(.signedOut) = status { onSignedOut?() }
    }

    /// Handles one frame from the room's socket.
    func handle(_ frame: ServerFrame) {
        switch frame {
        case .welcome, .resumed:
            admitted = true
        case let .error(message, clientMessageId, clientMessageIds, failed):
            let ids = Set(clientMessageIds ?? clientMessageId.map { [$0] } ?? [])
            // A reply's refusal is its thread's to show, as a message's is the timeline's.
            let isPending = timeline.pending.contains { ids.contains($0.clientMessageId) }
                || threads.contains { $0.timeline.pending.contains { ids.contains($0.clientMessageId) } }
            if !isPending, !message.isEmpty, failed != "thread.open", failed != "thread.before" {
                notice = message
            }
            if failed == "history.around" { aroundAnswered() }
        case .historyAround:
            aroundAnswered()
        default:
            break
        }
        let answers = timeline.apply(frame)
        for answer in answers {
            if case let .createMessage(id, _, _, _) = answer {
                if !isHeldText(id) { transmitMessage(answer) }
            } else {
                transmit(answer)
            }
        }
        // Every reply reaches every socket, and nothing says which thread an update or deletion is
        // in, so each thread hears everything and takes what's its own. What a thread sends back
        // goes as it is: a reply never waits on the room's newest page.
        for thread in threads {
            for answer in thread.apply(frame) {
                if case let .createMessage(id, _, _, _) = answer, isHeldText(id) { continue }
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
    }

    /// The room has let the socket in.
    private func opened() {
        aroundOnConnect = .catchUp
        askedAround = .catchUp
        if isVisible != askedVisible { transmit(.visible(isVisible)) }
    }

    /// Whether the room has let the open socket in, so frames sent now arrive.
    var isAdmitted: Bool { admitted }

    func transmit(_ frame: ClientFrame) {
        socket?.send(frame.text)
    }
}
