import Foundation

// A port of apps/web/src/lib/thread-state.ts. Upstream a thread keeps its replies in a room timeline of
// their own that keeps everything it loads; here that's folded into one value. Threads don't track seq.

extension Limits {
    /// How long a "typing" lasts without another (`TYPING_TTL_MS`), in seconds.
    public static let typingTTL: TimeInterval = 5
}

/// One thread as a client holds it: its parent, its replies, and what's sent from it, as the room's
/// socket frames add up to.
public struct ThreadTimeline: Equatable, Sendable {
    /// The message a thread is for, as far as the room has said.
    public enum Parent: Equatable, Sendable {
        /// Not heard yet.
        case unknown
        /// The room has no such message, or it's a reply: "This message no longer exists."
        case gone
        /// May be a tombstone (`isDeleted`), which can still be replied to.
        case message(Message)
    }

    public let parentId: String
    public private(set) var me: User?
    public private(set) var parent: Parent = .unknown
    /// Every loaded reply, oldest first. Never cut.
    public private(set) var replies: [Message] = []
    /// Replies and files sent from here that the room hasn't confirmed, oldest first.
    public private(set) var pending: [PendingMessage] = []
    public private(set) var hasMore = false
    /// Whether a `thread.opened` has ever arrived.
    public private(set) var isLoaded = false
    public private(set) var isLoadingOlder = false
    /// Bots answering in this thread. (People can't type in a thread.)
    public private(set) var typing: [User] = []
    /// The reply to bring into view: the one the thread was opened at, once it's loaded.
    public private(set) var focus: String?
    /// What went wrong opening or paging, for the screen to show and clear.
    public var notice: String?

    /// The reply a permalink goes to, until the thread has gone there, paging back if it's older
    /// than every reply loaded.
    private var openingAt: String?
    /// The id `thread.before` pages back from. It stays put when the oldest reply is deleted, since
    /// the room pages from ids, not from what's shown.
    private var oldestId: String?
    /// Whether a `thread.open` is waiting on its `thread.opened`.
    private var isOpening = false
    /// When each typist was last heard from.
    private var typingSince: [UserID: Date] = [:]

    /// `replyId` is a reply to open at (a permalink or search result).
    public init(parentId: String, me: User? = nil, at replyId: String? = nil) {
        self.parentId = parentId
        self.me = me
        openingAt = replyId
    }

    /// Whether a reply can be written: there's a parent, tombstone included.
    public var canReply: Bool { parentMessage != nil }

    /// The parent, when there is one.
    public var parentMessage: Message? {
        if case let .message(message) = parent { message } else { nil }
    }

    /// Applies any frame from the room's socket; one that isn't about this thread changes nothing.
    /// Answers what to send back.
    public mutating func apply(_ frame: ServerFrame, now: Date = Date()) -> [ClientFrame] {
        switch frame {
        case let .welcome(you, _, _, _):
            me = you

        case let .resumed(you, messages, deletedIds, _, _):
            me = you
            let deleted = Set(deletedIds)
            if deleted.contains(parentId) { parent = .gone }
            replies.removeAll { deleted.contains($0.id) }
            for message in messages {
                if message.id == parentId {
                    setParent(message)
                } else if message.parentId == parentId {
                    upsert(message)
                }
            }
            dropConfirmed(by: messages)

        case let .threadOpened(id, parent, messages, hasMore):
            guard id == parentId else { return [] }
            isOpening = false
            if isLoaded {
                reopen(messages, hasMore: hasMore)
            } else {
                show(messages, hasMore: hasMore)
            }
            // The page's replies quote the parent as the room has it, so there's nothing to retell.
            if let parent, parent.parentId == nil {
                self.parent = .message(parent)
            } else {
                self.parent = .gone
            }
            isLoaded = true
            isLoadingOlder = false
            clearTyping()
            return goToOpeningReply() + pending.checks()

        case let .threadHistory(id, before, messages, hasMore):
            guard id == parentId else { return [] }
            isLoadingOlder = false
            // A page for bounds since replaced, by a reconnect, is stale.
            guard before == oldestId else { return [] }
            let known = Set(replies.map(\.id))
            let older = messages.filter { $0.parentId == parentId && !known.contains($0.id) }
            replies.insert(contentsOf: older, at: 0)
            if let first = older.first { oldestId = first.id }
            self.hasMore = hasMore
            dropConfirmed(by: messages)
            return goToOpeningReply()

        case let .messageCreated(message, _):
            guard message.parentId == parentId else { return [] }
            dropConfirmed(by: [message])
            stopTyping(message.creator.id)
            upsert(message, always: true)

        case let .messageUpdated(message, _):
            if message.id == parentId {
                setParent(message)
            } else if let index = replies.firstIndex(where: { $0.id == message.id }) {
                replies[index] = message
            }

        case let .messageDeleted(messageId, _):
            if messageId == parentId {
                parent = .gone
            } else {
                replies.removeAll { $0.id == messageId }
            }

        case let .boostCreated(boost, _):
            change(boost.messageId) { message in
                if !message.boosts.contains(where: { $0.id == boost.id }) { message.boosts.append(boost) }
            }

        case let .boostDeleted(boostId, messageId, _):
            change(messageId) { $0.boosts.removeAll { $0.id == boostId } }

        case let .messageChecked(stored, missing):
            let storedIds = Set(stored)
            pending.removeAll { storedIds.contains($0.clientMessageId) }
            // `message.checked` says nothing of threads, so each view answers only for its own. A file
            // has no body to send again: it stays as it is.
            return missing.compactMap { id in
                guard let message = pending.first(where: { $0.clientMessageId == id && $0.failure == nil && $0.upload == nil }) else { return nil }
                return message.createFrame
            }

        case let .typing(user, isTyping, threadId):
            guard threadId == parentId, user.id != me?.id else { return [] }
            if isTyping {
                if !typing.contains(where: { $0.id == user.id }) { typing.append(user) }
                typingSince[user.id] = now
            } else {
                stopTyping(user.id)
            }

        case let .error(text, clientMessageId, clientMessageIds, failed):
            switch failed {
            case "thread.open":
                if isOpening {
                    isOpening = false
                    notice = text
                }
                return []
            case "thread.before":
                // A failed page leaves nothing in flight, so the reader can page again, though the
                // thread stops paging back to the reply a permalink goes to.
                if isLoadingOlder {
                    isLoadingOlder = false
                    openingAt = nil
                    notice = text
                }
                return []
            default:
                let ids = Set(clientMessageIds ?? clientMessageId.map { [$0] } ?? [])
                for index in pending.indices where ids.contains(pending[index].clientMessageId) {
                    pending[index].failure = text
                }
            }

        case .presenceJoined, .presenceLeft, .history, .historyAfter, .historyAround, .pong, .unknown:
            break
        }
        return []
    }

    /// `thread.open`. The session sends it once admitted, and again after every welcome or resumed.
    public mutating func opening() -> ClientFrame {
        isOpening = true
        return .openThread(parentId: parentId)
    }

    /// Shows a reply as pending, and answers the frame that sends it.
    public mutating func reply(body: String, plainText: String, alsoSend: Bool, clientMessageId: String, now: Date) -> ClientFrame {
        let reply = PendingMessage(clientMessageId: clientMessageId, body: body, plainText: plainText, createdAt: now, parentId: parentId, alsoSend: alsoSend)
        pending.append(reply)
        return reply.createFrame
    }

    /// Shows a file on its way up as a pending reply. Nothing to send: the file goes over HTTP.
    public mutating func attach(_ upload: PendingUpload, alsoSend: Bool, clientMessageId: String, now: Date) {
        pending.append(PendingMessage(
            clientMessageId: clientMessageId, body: "", plainText: upload.name, createdAt: now, parentId: parentId, alsoSend: alsoSend, upload: upload
        ))
    }

    /// Moves a pending upload's progress on. Nothing for an unknown id.
    public mutating func uploadProgress(_ clientMessageId: String, sentBytes: Int) {
        pending.progress(clientMessageId, sentBytes: sentBytes)
    }

    /// Marks a pending as failed. For an upload, answers the `message.check` to send, since the file
    /// may have been posted anyway.
    public mutating func fail(_ clientMessageId: String, reason: String) -> ClientFrame? {
        pending.fail(clientMessageId, reason: reason)
    }

    /// The message an upload's last part answered with: its pending goes and it shows among the
    /// replies, once.
    public mutating func posted(_ message: Message) {
        pending.removeAll { $0.clientMessageId == message.clientMessageId }
        guard message.parentId == parentId else { return }
        upsert(message, always: true, replacing: false)
    }

    /// Sends a refused reply again, under the same id. nil when it isn't pending, and for a file,
    /// which starts again from its first byte: the session uploads it again.
    public mutating func retry(_ clientMessageId: String) -> ClientFrame? {
        guard let index = pending.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return nil }
        pending[index].failure = nil
        if pending[index].upload != nil {
            pending[index].upload?.sentBytes = 0
            return nil
        }
        return pending[index].createFrame
    }

    public mutating func discard(_ clientMessageId: String) {
        pending.removeAll { $0.clientMessageId == clientMessageId }
    }

    /// `thread.before` from the oldest loaded reply; nil while loading, with nothing more, or with
    /// nothing loaded.
    public mutating func olderPage() -> ClientFrame? {
        guard isLoaded, hasMore, !isLoadingOlder, let oldestId else { return nil }
        isLoadingOlder = true
        return .threadBefore(parentId: parentId, before: oldestId)
    }

    /// Goes to `replyId` as opening the thread at it does, for a thread that's open already (a
    /// second link into it): `focus` names it once it's loaded, paging back to it first while it's
    /// older than every reply loaded. Before the thread has opened, it's where the open goes.
    /// Replies and pendings stay as they are. Answers what to send.
    ///
    /// `isOpen` false says the socket isn't in the room, so a reply not loaded waits for the next
    /// `thread.opened` rather than paging now.
    public mutating func go(to replyId: String, isOpen: Bool = true) -> [ClientFrame] {
        openingAt = replyId
        guard isLoaded, isOpen || replies.contains(where: { $0.id == replyId }) else { return [] }
        return goToOpeningReply()
    }

    /// The screen has brought `focus` into view: forget it, so it isn't brought there again.
    public mutating func clearFocus() {
        focus = nil
    }

    /// The socket dropped: loading flags and typing clear; replies and pendings stay.
    public mutating func disconnected() {
        isLoadingOlder = false
        isOpening = false
        clearTyping()
    }

    /// Drops bots not heard from for `Limits.typingTTL`.
    public mutating func expireTyping(now: Date) {
        let before = now.addingTimeInterval(-Limits.typingTTL)
        for (id, since) in typingSince where since < before {
            stopTyping(id)
        }
    }

    /// Goes to the reply `openingAt` names once the thread has opened: there once it has it, or, while
    /// that's older than every reply loaded, on its way, paging back; or else to the end.
    private mutating func goToOpeningReply() -> [ClientFrame] {
        guard let openingAt, isLoaded else { return [] }
        let found = replies.contains { $0.id == openingAt }
        if !found, hasMore, let oldestId, jsLess(openingAt, oldestId) {
            return olderPage().map { [$0] } ?? []
        }
        focus = found ? openingAt : nil
        self.openingAt = nil
        return []
    }

    /// The newest page in the place of whatever was shown, as when the thread first opens.
    private mutating func show(_ messages: [Message], hasMore: Bool) {
        replies = messages
        oldestId = messages.first?.id
        self.hasMore = hasMore
        dropConfirmed(by: messages)
    }

    /// The thread opened again, after a reconnect (the web's `reopened`). While the newest page holds
    /// every reply shown, those catch up with it, and those it doesn't hold have been deleted. Once
    /// they go back further, the page can't say what came, changed or went before it, so it takes
    /// their place, and paging back brings the older ones as they are now.
    private mutating func reopen(_ messages: [Message], hasMore: Bool) {
        if hasMore, let first = messages.first, replies.first.map({ jsLess($0.id, first.id) }) ?? true {
            show(messages, hasMore: hasMore)
            return
        }
        let kept = Set(messages.map(\.id))
        replies.removeAll { !kept.contains($0.id) }
        for message in messages where message.parentId == parentId { upsert(message) }
        if oldestId == nil { oldestId = replies.first?.id }
        // The page reaches back past everything shown, so it knows whether there's more before that.
        self.hasMore = self.hasMore && hasMore
        dropConfirmed(by: messages)
    }

    /// Replaces a loaded reply, or adds one in id order. One older than the oldest loaded, with more
    /// before it, is left for paging back to bring, so no gap opens, unless `always`, for a reply
    /// that's just been posted.
    private mutating func upsert(_ message: Message, always: Bool = false, replacing: Bool = true) {
        if let index = replies.firstIndex(where: { $0.id == message.id }) {
            if replacing { replies[index] = message }
            return
        }
        if !always, hasMore, let oldestId, !jsLess(oldestId, message.id) { return }
        let index = replies.firstIndex { jsLess(message.id, $0.id) } ?? replies.endIndex
        replies.insert(message, at: index)
        if oldestId == nil { oldestId = replies.first?.id }
    }

    /// The parent, replaced whole, and the text its loaded replies quote it with retold.
    private mutating func setParent(_ message: Message) {
        parent = .message(message)
        let text = message.isDeleted ? "" : Timeline.parentText(of: message.plainText)
        for index in replies.indices {
            replies[index].parentText = text
        }
    }

    /// Changes the parent or a loaded reply, whichever has `id`.
    private mutating func change(_ id: String, _ body: (inout Message) -> Void) {
        if id == parentId, case var .message(message) = parent {
            body(&message)
            parent = .message(message)
        } else if let index = replies.firstIndex(where: { $0.id == id }) {
            body(&replies[index])
        }
    }

    /// Drops the pending replies these confirm: the same client id, sent by me.
    private mutating func dropConfirmed(by confirmed: [Message]) {
        guard let me, !pending.isEmpty else { return }
        let ids = Set(confirmed.filter { $0.creator.id == me.id }.map(\.clientMessageId))
        pending.removeAll { ids.contains($0.clientMessageId) }
    }

    private mutating func stopTyping(_ id: UserID) {
        typing.removeAll { $0.id == id }
        typingSince[id] = nil
    }

    private mutating func clearTyping() {
        typing = []
        typingSince = [:]
    }
}
