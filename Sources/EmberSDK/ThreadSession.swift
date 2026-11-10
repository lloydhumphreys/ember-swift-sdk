import Foundation
import Observation

/// One thread of a room, on the room's socket: its parent and replies as `timeline`, and what's
/// sent from it. Get one from `RoomSession.thread(_:at:)`, and hold `open()`'s lease while it's
/// shown.
///
/// Edits, deletions and boosts on replies are the room's: `room.edit(…)`, `room.delete(…)`,
/// `room.boost(…)`.
@MainActor @Observable public final class ThreadSession {
    /// The message the thread is under.
    public let parentID: String
    /// The room the thread is in, whose socket it's on.
    public let room: RoomSession
    /// The parent, the replies and what's pending, as the room's frames have them.
    public private(set) var timeline: ThreadTimeline
    /// What went wrong, for the screen to show and clear: opening or paging the thread.
    public var notice: String?

    @ObservationIgnored private(set) var leases = 0
    /// The lease on the room this thread keeps while it has any of its own.
    @ObservationIgnored private var roomLease: RoomLease?
    /// Moments on the session's clock, so a bot's typing expires on a test's `ManualClock` too.
    @ObservationIgnored private let elapsed: @Sendable () -> Duration
    @ObservationIgnored private let started = Date()
    /// Drops typing that's gone quiet, while anyone is typing.
    @ObservationIgnored private var typingTicker: Task<Void, Never>?

    init(room: RoomSession, parentID: String, at replyID: String?) {
        self.room = room
        self.parentID = parentID
        timeline = ThreadTimeline(parentId: parentID, me: room.timeline.me, at: replyID)
        elapsed = room.client.timing.stopwatch()
    }

    // MARK: Leases

    /// Takes a lease: the thread opens on the room's socket, and the socket is held open (the thread
    /// keeps a `RoomLease` of its own) for as long as any thread lease is. A lease on a thread
    /// that's open already makes it the room's current thread again.
    public func open() -> ThreadLease {
        leases += 1
        // A room that's shut down has let go of its threads; one registering again would keep the
        // two alive together.
        guard !room.isShutDown else { return ThreadLease(self) }
        if leases == 1 { roomLease = room.open() }
        room.threadOpened(self)
        return ThreadLease(self)
    }

    /// A lease has closed.
    func leaseClosed() {
        leases = max(0, leases - 1)
        guard leases == 0 else { return }
        room.threadClosed(self)
        roomLease?.close()
        roomLease = nil
    }

    /// The room is shut down and has let go of the thread: the typing ticker stops and the room's
    /// lease goes. Leases a screen still holds close as usual, reaching nothing.
    func end() {
        typingTicker?.cancel()
        typingTicker = nil
        roomLease?.close()
        roomLease = nil
    }

    /// Whether a screen holds a lease.
    var isHeld: Bool { leases > 0 }

    /// Whether a reply is still on its way: pending and not failed.
    var hasUnsettled: Bool {
        timeline.pending.contains { $0.failure == nil }
    }

    // MARK: Replies

    /// Sends a reply, or with `alsoSend` a reply that's in the room too. It goes now when the
    /// socket is admitted, and otherwise once the thread opens again. Answers its client message id.
    @discardableResult
    public func reply(body: String, plainText: String, alsoSend: Bool = false) -> String {
        let id = UUID().uuidString.lowercased()
        let frame = timeline.reply(body: body, plainText: plainText, alsoSend: alsoSend, clientMessageId: id, now: now())
        if !room.isShutDown { room.keep(self) }
        // A reply never waits on the room's newest page, as a room message does.
        if room.isAdmitted { room.transmit(frame) }
        return id
    }

    /// Files then text, as `RoomSession.send(files:…)`, into the thread. A refused file's notice is
    /// the thread's `notice`.
    @discardableResult
    public func send(files: [UploadSource], body: String? = nil, plainText: String? = nil, alsoSend: Bool = false) -> [String] {
        room.enqueue(files: files, body: body, plainText: plainText, thread: self, alsoSend: alsoSend)
    }

    /// Sends a refused reply again, under the same id. A file that failed goes up again from the
    /// start, after any still waiting.
    public func retry(_ clientMessageId: String) {
        if timeline.pending.first(where: { $0.clientMessageId == clientMessageId })?.upload != nil {
            _ = timeline.retry(clientMessageId)
            room.retryUpload(clientMessageId)
            return
        }
        guard let frame = timeline.retry(clientMessageId) else { return }
        if !room.isShutDown { room.keep(self) }
        if room.isAdmitted { room.transmit(frame) }
    }

    /// Forgets a pending reply. A file on its way up stops.
    public func discard(_ clientMessageId: String) {
        room.discardUpload(clientMessageId)
        timeline.discard(clientMessageId)
        room.settle(self)
    }

    /// Asks for the replies before the oldest loaded, when `timeline.hasMore` and none is on its way.
    public func loadOlder() {
        guard room.isAdmitted, let frame = timeline.olderPage() else { return }
        room.transmit(frame)
    }

    /// Brings `replyID` into focus, as a second link into the thread asks.
    func go(to replyID: String) {
        for frame in timeline.go(to: replyID, isOpen: room.isAdmitted) { room.transmit(frame) }
    }

    /// The screen has scrolled to `timeline.focus`.
    public func focusShown() {
        timeline.clearFocus()
    }

    // MARK: From the room

    /// Applies a frame from the room's socket; answers what to send back.
    func apply(_ frame: ServerFrame) -> [ClientFrame] {
        let answers = timeline.apply(frame, now: now())
        if let text = timeline.notice {
            notice = text
            timeline.notice = nil
        }
        watchTyping()
        return answers
    }

    /// `thread.open`, for the room to send.
    func opening() -> ClientFrame {
        timeline.opening()
    }

    /// The socket dropped.
    func disconnected() {
        timeline.disconnected()
        watchTyping()
    }

    /// A reply held behind files: shown as pending now, with the frame that sends it answered.
    func hold(body: String, plainText: String, alsoSend: Bool, clientMessageId: String) -> ClientFrame {
        timeline.reply(body: body, plainText: plainText, alsoSend: alsoSend, clientMessageId: clientMessageId, now: now())
    }

    /// A held reply's turn has come. One discarded meanwhile doesn't go, and one that can't go yet
    /// waits for the check that follows the thread opening again.
    func release(_ frame: ClientFrame, clientMessageId: String) {
        guard room.isAdmitted, timeline.pending.contains(where: { $0.clientMessageId == clientMessageId && $0.failure == nil }) else { return }
        room.transmit(frame)
    }

    func attach(_ upload: PendingUpload, alsoSend: Bool, clientMessageId: String) {
        timeline.attach(upload, alsoSend: alsoSend, clientMessageId: clientMessageId, now: now())
    }

    func uploadProgress(_ clientMessageId: String, sentBytes: Int) {
        timeline.uploadProgress(clientMessageId, sentBytes: sentBytes)
    }

    func posted(_ message: Message) {
        timeline.posted(message)
    }

    func fail(_ clientMessageId: String, reason: String) -> ClientFrame? {
        timeline.fail(clientMessageId, reason: reason)
    }

    // MARK: Typing

    /// Now, as the session's clock has it.
    private func now() -> Date {
        started.addingTimeInterval(TimeInterval(elapsed() / .seconds(1)))
    }

    /// Ticks once a second while a bot is typing, so one that's gone quiet goes, and stops after.
    private func watchTyping() {
        guard !timeline.typing.isEmpty else {
            typingTicker?.cancel()
            typingTicker = nil
            return
        }
        guard typingTicker == nil else { return }
        let timing = room.client.timing
        typingTicker = Task { [weak self] in
            while true {
                do { try await timing.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.timeline.expireTyping(now: self.now())
                if self.timeline.typing.isEmpty {
                    self.typingTicker = nil
                    return
                }
            }
        }
    }
}

/// A hold on a thread, from `ThreadSession.open()`: the thread is open on the room's socket, and
/// the socket held open, for as long as any is. Each screen showing the thread keeps one.
///
/// Closing twice is the same as once, and a lease that's let go of closes itself.
@MainActor public final class ThreadLease {
    private let hold: ThreadHold

    init(_ thread: ThreadSession) {
        hold = ThreadHold(thread)
    }

    deinit {
        // As `RoomLease`: at once on the main actor, else as soon as the main actor gets to it.
        let hold = hold
        if Thread.isMainThread {
            MainActor.assumeIsolated { hold.close() }
        } else {
            Task { @MainActor in hold.close() }
        }
    }

    /// Whether `close()` has been called (or the lease let go of).
    public var isClosed: Bool { hold.isClosed }

    /// Lets go of the thread. Nothing when closed already.
    public func close() {
        hold.close()
    }
}

/// What a thread lease holds, kept apart from it so its deinit can reach it.
@MainActor private final class ThreadHold {
    private weak var thread: ThreadSession?
    private(set) var isClosed = false

    init(_ thread: ThreadSession) {
        self.thread = thread
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        thread?.leaseClosed()
    }
}

extension EmberTiming {
    /// How long has passed on `clock` since this was called, each time the answer is called.
    func stopwatch() -> @Sendable () -> Duration {
        let clock = clock
        return Self.measure(on: clock)
    }

    private static func measure<C: Clock<Duration>>(on clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
