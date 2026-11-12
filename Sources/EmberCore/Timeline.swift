import Foundation

// A port of the room reducer in apps/web/src/lib/room-state.ts, as far as a room's own timeline goes.
// Threads are a separate view upstream and their frames don't touch it.

/// A message sent from here that the room hasn't confirmed yet.
public struct PendingMessage: Hashable, Identifiable, Sendable {
    public var clientMessageId: String
    /// Markup, as sent.
    public var body: String
    public var plainText: String
    public var createdAt: Date
    /// Why the room refused it; nil while it's on its way.
    public var failure: String?
    /// The thread it replies in; nil for a room message.
    public var parentId: String?
    /// Whether a reply also goes to the room. Always false without `parentId`.
    public var alsoSend: Bool
    /// Set for a file on its way up: `body` is "" and `plainText` the file's name.
    public var upload: PendingUpload?
    public var id: String { clientMessageId }

    public init(
        clientMessageId: String, body: String, plainText: String, createdAt: Date, failure: String? = nil,
        parentId: String? = nil, alsoSend: Bool = false, upload: PendingUpload? = nil
    ) {
        self.clientMessageId = clientMessageId
        self.body = body
        self.plainText = plainText
        self.createdAt = createdAt
        self.failure = failure
        self.parentId = parentId
        self.alsoSend = parentId != nil && alsoSend
        self.upload = upload
    }

    /// The frame that sends it, again or for the first time.
    var createFrame: ClientFrame {
        .createMessage(clientMessageId: clientMessageId, body: body, parentId: parentId, alsoSend: parentId == nil ? nil : alsoSend)
    }

    /// Whether a reconnect asks the room about it: any text, on its way or failed, and a file that
    /// failed, since a failed one may have been stored anyway (one sent whose answer was lost). The
    /// room's answer drops one it has; a failed one it doesn't have stays failed. Not a file still
    /// going up.
    var isChecked: Bool {
        upload == nil || failure != nil
    }
}

/// How far a file has got.
public struct PendingUpload: Hashable, Sendable {
    public var name: String
    public var contentType: String
    public var byteSize: Int
    /// Bytes handed to the server so far.
    public var sentBytes: Int

    public init(name: String, contentType: String, byteSize: Int, sentBytes: Int = 0) {
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.sentBytes = sentBytes
    }

    /// 0...1; 1 for an empty file.
    public var fraction: Double {
        guard byteSize > 0 else { return 1 }
        return min(1, max(0, Double(sentBytes) / Double(byteSize)))
    }

    /// Every byte is up and the room has yet to answer (the web's "Processing…").
    public var isProcessing: Bool { sentBytes >= byteSize }
}

extension Limits {
    /// How many messages a timeline holds before it lets the far end go (`MAX_MESSAGES`).
    public static let timelineMessages = 300
    /// How far past `timelineMessages` it goes before cutting, so it doesn't cut on every message.
    public static let timelineLeeway = 20
    /// How much of a parent's text a reply quotes (`PARENT_TEXT_LENGTH`), in Unicode scalars.
    public static let parentText = 150
    /// How many of the room's later changes may arrive before a missing one counts as lost
    /// (`Timeline.needsCatchUp`) rather than late.
    public static let seqReorder = 3
}

/// A room's timeline as a client holds it: what the socket's frames add up to.
public struct Timeline: Equatable, Sendable {
    /// Who the room's socket signs in, from its welcome or resumed.
    public private(set) var me: User?
    /// The room's own timeline (messages that are `isInRoom`), oldest first.
    public private(set) var messages: [Message] = []
    /// Sent, not yet confirmed, oldest first.
    public private(set) var pending: [PendingMessage] = []
    /// Whether older pages exist.
    public private(set) var hasMore = false
    /// Whether the timeline stops short of the room's latest message, after a jump or a cut.
    public private(set) var hasNewer = false
    /// Whether a welcome or resumed has arrived.
    public private(set) var isLoaded = false
    public private(set) var isLoadingOlder = false
    public private(set) var isLoadingNewer = false
    /// Whether a page asked for with `pageAround` is on its way.
    public private(set) var isLoadingPage = false
    /// The message the latest page was centred on, to scroll to.
    public private(set) var anchor: String?
    /// The latest change the room has told us of, for `since=` when reconnecting.
    public private(set) var seq: Int?
    public private(set) var present: [User] = []
    /// Others typing in the room's composer, not in threads.
    public private(set) var typing: [User] = []
    /// How many messages came in while `hasNewer` held them back, for a "new messages" button.
    public private(set) var arrivals = 0
    /// Why the page before the oldest message didn't load, or nil. Until `retryOlderPage()`, a page
    /// that loads, or the next connection, `olderPage()` asks for nothing, so a page that fails isn't
    /// asked for again and again.
    public private(set) var olderPageFailure: String?
    /// Why the page after the newest message didn't load, or nil, as `olderPageFailure` for
    /// `newerPage()` and `retryNewerPage()`.
    public private(set) var newerPageFailure: String?
    /// Whether a change the room numbered has gone missing, as the `seq` of the changes after it
    /// shows: connecting again with `since` (`seq`, which stays at the change before it) brings it.
    /// Set once `Limits.seqReorder` later changes have come without it, since changes the room makes
    /// at once can arrive a little out of order. A welcome or resumed clears it.
    public private(set) var needsCatchUp = false
    /// Whether the reader has scrolled away from the newest messages, as the view says with
    /// `setAwayFromLatest`. A reconnect that can't catch up then keeps the messages they're reading
    /// and treats the newer ones as not loaded yet (`hasNewer`), rather than showing the newest page.
    public private(set) var isAwayFromLatest = false

    // The page bounds the room's history requests go from. They stay put when the messages at the
    // ends are deleted, since the room pages from ids, not from what's shown.
    private var oldestId: String?
    private var newestId: String?
    /// The numbered changes heard after a gap in `seq`, which move `seq` on once the gap fills.
    private var ahead: Set<Int> = []

    public init() {}

    /// Applies a frame. Returns what to send back: `message.check` for anything pending after a
    /// (re)connect, and the pending messages a `message.checked` says the room never got.
    public mutating func apply(_ frame: ServerFrame) -> [ClientFrame] {
        switch frame {
        case let .welcome(you, present, seq, page):
            me = you
            if isLoaded, page.around == nil {
                reconnect(to: page)
            } else {
                show(page)
            }
            self.present = present
            self.seq = seq
            settle()
            return checks()

        case let .resumed(you, changed, deletedIds, present, seq):
            me = you
            // Something newer than a window that stops short of the latest counts once, as the web does.
            let known = Set(messages.map(\.id))
            let newest = messages.last?.id ?? newestId
            let cameNewer = changed.contains { message in
                message.isInRoom && !known.contains(message.id) && newest.map { jsLess($0, message.id) } ?? true
            }
            if hasNewer, cameNewer { arrivals += 1 }
            let deleted = Set(deletedIds)
            messages.removeAll { deleted.contains($0.id) }
            for message in changed {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message
                } else if message.isInRoom, inRange(message.id) {
                    messages.append(message)
                }
            }
            messages.sort { jsLess($0.id, $1.id) }
            for message in changed { retell(message) }
            dropConfirmed(by: changed)
            self.present = present
            self.seq = seq
            settle()
            cutFromStart()
            return checks()

        case let .messageCreated(message, seq):
            guard see(seq) else { return [] }
            let isMine = !message.clientMessageId.isEmpty && pending.contains { $0.clientMessageId == message.clientMessageId }
            dropConfirmed(by: [message])
            typing.removeAll { $0.id == message.creator.id }
            guard message.isInRoom else { return [] }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else if hasNewer {
                // Your own message confirmed isn't news to you.
                if !isMine { arrivals += 1 }
            } else if isAwayFromLatest, messages.count >= Limits.timelineMessages + Limits.timelineLeeway,
                      newestId.map({ jsLess($0, message.id) }) ?? false {
                // A full window someone's reading back through isn't cut from its start for something
                // newer: it stops short of the latest instead, as after a jump.
                hasNewer = true
                if !isMine { arrivals += 1 }
            } else if inRange(message.id) {
                insert(message)
                if newestId.map({ jsLess($0, message.id) }) ?? true { newestId = message.id }
                if oldestId == nil { oldestId = message.id }
            }
            cutFromStart()

        case let .messageUpdated(message, seq):
            guard see(seq) else { return [] }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
            retell(message)

        case let .messageDeleted(messageId, seq):
            guard see(seq) else { return [] }
            messages.removeAll { $0.id == messageId }

        case let .boostCreated(boost, seq):
            guard see(seq) else { return [] }
            if let index = messages.firstIndex(where: { $0.id == boost.messageId }),
               !messages[index].boosts.contains(where: { $0.id == boost.id }) {
                messages[index].boosts.append(boost)
            }

        case let .boostDeleted(boostId, messageId, seq):
            guard see(seq) else { return [] }
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].boosts.removeAll { $0.id == boostId }
            }

        case let .presenceJoined(user):
            if !present.contains(where: { $0.id == user.id }) { present.append(user) }

        case let .presenceLeft(userId):
            present.removeAll { $0.id == userId }
            typing.removeAll { $0.id == userId }

        case let .typing(user, isTyping, threadId):
            guard threadId == nil, user.id != me?.id else { return [] }
            if isTyping {
                if !typing.contains(where: { $0.id == user.id }) { typing.append(user) }
            } else {
                typing.removeAll { $0.id == user.id }
            }

        case let .history(before, page, hasMore):
            isLoadingOlder = false
            // A page for bounds since replaced, by a jump or a reconnect, is stale.
            guard before == oldestId else { return [] }
            let known = Set(messages.map(\.id))
            let older = page.filter { $0.isInRoom && !known.contains($0.id) }
            messages.insert(contentsOf: older, at: 0)
            dropConfirmed(by: page)
            self.hasMore = hasMore
            if let first = page.first, oldestId.map({ jsLess(first.id, $0) }) ?? true { oldestId = first.id }
            // A page that moves the bound on nothing would be asked for again, the same, at once.
            olderPageFailure = hasMore && oldestId == before ? Self.emptyPage : nil
            cutFromEnd()

        case let .historyAfter(after, page, hasNewer):
            isLoadingNewer = false
            guard self.hasNewer, after == newestId else { return [] }
            let known = Set(messages.map(\.id))
            let newer = page.filter { $0.isInRoom && !known.contains($0.id) }
            messages.append(contentsOf: newer)
            dropConfirmed(by: page)
            self.hasNewer = hasNewer
            if let last = page.last, newestId.map({ jsLess($0, last.id) }) ?? true { newestId = last.id }
            newerPageFailure = hasNewer && newestId == after ? Self.emptyPage : nil
            if !hasNewer { arrivals = 0 }
            cutFromStart()

        case let .historyAround(page):
            show(page)
            isLoadingPage = false
            isLoadingOlder = false
            isLoadingNewer = false

        case let .messageChecked(stored, missing):
            let storedIds = Set(stored)
            pending.removeAll { storedIds.contains($0.clientMessageId) }
            // The room never got these, so those still on their way go again under the same ids.
            // The room doesn't de-duplicate a create, so one that failed stays failed until a retry
            // asks again. A file has no body to send again: it stays as it is.
            return missing.compactMap { id in
                guard let message = pending.first(where: { $0.clientMessageId == id && $0.failure == nil && $0.upload == nil }) else { return nil }
                return message.createFrame
            }

        case .threadOpened, .threadHistory:
            break

        case let .error(text, clientMessageId, clientMessageIds, failed):
            switch failed {
            case "history.before":
                isLoadingOlder = false
                olderPageFailure = text
            case "history.after":
                isLoadingNewer = false
                newerPageFailure = text
            case "history.around": isLoadingPage = false
            case "thread.open", "thread.before": return []
            default: break
            }
            let ids = Set(clientMessageIds ?? clientMessageId.map { [$0] } ?? [])
            for index in pending.indices where ids.contains(pending[index].clientMessageId) {
                pending[index].failure = text
            }

        case .pong, .unknown:
            break
        }
        return []
    }

    /// Queues a message and returns the frame that sends it.
    public mutating func send(body: String, plainText: String, clientMessageId: String = UUID().uuidString.lowercased(), now: Date = .now) -> ClientFrame {
        pending.append(PendingMessage(clientMessageId: clientMessageId, body: body, plainText: plainText, createdAt: now))
        return .createMessage(clientMessageId: clientMessageId, body: body)
    }

    /// Puts a failed message on its way again, under the same id, and answers the frame that creates
    /// it. nil when it isn't pending, and for a file, which the session uploads again. The room
    /// doesn't de-duplicate a create, so `RoomSession` asks it with `message.check` first and sends
    /// this only for a message the room says is missing.
    public mutating func retry(_ clientMessageId: String) -> ClientFrame? {
        guard let index = pending.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return nil }
        pending[index].failure = nil
        if pending[index].upload != nil {
            pending[index].upload?.sentBytes = 0
            return nil
        }
        return pending[index].createFrame
    }

    /// Shows a file on its way up as pending. Nothing to send: the file goes over HTTP.
    public mutating func attach(_ upload: PendingUpload, clientMessageId: String, now: Date) {
        pending.append(PendingMessage(clientMessageId: clientMessageId, body: "", plainText: upload.name, createdAt: now, upload: upload))
    }

    /// Moves a pending upload's progress on. Nothing for an unknown id.
    public mutating func uploadProgress(_ clientMessageId: String, sentBytes: Int) {
        pending.progress(clientMessageId, sentBytes: sentBytes)
    }

    /// Marks a pending as failed. For an upload, answers the `message.check` to send, since the
    /// file may have been posted anyway.
    public mutating func fail(_ clientMessageId: String, reason: String) -> ClientFrame? {
        pending.fail(clientMessageId, reason: reason)
    }

    /// The message an upload's last part answered with. The pending with its `clientMessageId`
    /// goes, and the message is shown as `message.created` would show it, but with no seq, and
    /// nothing changes if it's shown already. Out of range (`hasNewer`), only the pending goes.
    public mutating func posted(_ message: Message) {
        pending.removeAll { $0.clientMessageId == message.clientMessageId }
        guard message.isInRoom, !hasNewer, !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { jsLess($0.id, $1.id) }
        newestId = messages.last?.id
        if oldestId == nil { oldestId = message.id }
        cutFromStart()
    }

    public mutating func discard(_ clientMessageId: String) {
        pending.removeAll { $0.clientMessageId == clientMessageId }
    }

    /// `history.before` the oldest message, when there's more, none is on its way, and the last one
    /// didn't fail (`olderPageFailure`).
    public mutating func olderPage() -> ClientFrame? {
        guard isLoaded, hasMore, !isLoadingOlder, olderPageFailure == nil, let oldestId else { return nil }
        isLoadingOlder = true
        return .historyBefore(messageId: oldestId)
    }

    /// `history.after` the newest message, when there's newer, none is on its way, and the last one
    /// didn't fail (`newerPageFailure`).
    public mutating func newerPage() -> ClientFrame? {
        guard isLoaded, hasNewer, !isLoadingNewer, newerPageFailure == nil, let newestId else { return nil }
        isLoadingNewer = true
        return .historyAfter(messageId: newestId)
    }

    /// Asks again for the page before the oldest message after it failed: `olderPageFailure` is
    /// forgotten and `olderPage()` answers.
    public mutating func retryOlderPage() -> ClientFrame? {
        olderPageFailure = nil
        return olderPage()
    }

    /// Asks again for the page after the newest message after it failed, as `retryOlderPage()`.
    public mutating func retryNewerPage() -> ClientFrame? {
        newerPageFailure = nil
        return newerPage()
    }

    /// `history.around` a message, to jump to it, or the newest page for nil, to jump back.
    public mutating func pageAround(_ messageID: String?) -> ClientFrame {
        isLoadingPage = true
        return .historyAround(messageId: messageID)
    }

    /// The reader has scrolled away from the newest messages, or back to them (`isAwayFromLatest`).
    public mutating func setAwayFromLatest(_ away: Bool) {
        isAwayFromLatest = away
    }

    /// The view has scrolled to `anchor`: forget it, so it isn't scrolled to again.
    public mutating func clearAnchor() {
        anchor = nil
    }

    /// The socket dropped: nobody's typing as far as we know, and no page is on its way. An older
    /// or newer page that was on its way fails (`pageNotLoaded`), as a refused one does, so it's
    /// asked for again with a retry.
    public mutating func disconnected() {
        typing = []
        olderPageFailed()
        newerPageFailed()
        isLoadingPage = false
    }

    /// What `olderPageFailure` or `newerPageFailure` says of a page the room didn't answer in time,
    /// or that the connection dropped before it came.
    public static let pageNotLoaded = "The page didn’t load."

    /// The page before the oldest message didn't come: it fails with `reason`, as one the room
    /// refused does, and `retryOlderPage()` asks again. Nothing when none is on its way.
    public mutating func olderPageFailed(_ reason: String = Self.pageNotLoaded) {
        guard isLoadingOlder else { return }
        isLoadingOlder = false
        olderPageFailure = reason
    }

    /// The page after the newest message didn't come, as `olderPageFailed(_:)`.
    public mutating func newerPageFailed(_ reason: String = Self.pageNotLoaded) {
        guard isLoadingNewer else { return }
        isLoadingNewer = false
        newerPageFailure = reason
    }

    public func message(_ id: String) -> Message? {
        messages.first { $0.id == id }
    }

    /// The start of `plainText` a reply quotes its parent with.
    public static func parentText(of plainText: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: plainText.unicodeScalars.prefix(Limits.parentText))
        return String(scalars)
    }

    private mutating func show(_ page: TimelinePage) {
        messages = page.messages.filter(\.isInRoom)
        dropConfirmed(by: page.messages)
        hasMore = page.hasMore
        hasNewer = page.hasNewer
        oldestId = page.messages.first?.id
        newestId = page.messages.last?.id
        anchor = page.around
        arrivals = 0
        olderPageFailure = nil
        newerPageFailure = nil
    }

    /// The newest page, on a reconnect the room couldn't catch up with `since`. Where it overlaps
    /// what's shown it takes over from its first message, and the older messages stay. Where it
    /// doesn't, a reader away from the latest keeps what they're reading, with the newer messages
    /// to load (`hasNewer`) as after a jump; anyone else gets the page.
    private mutating func reconnect(to page: TimelinePage) {
        guard let first = page.messages.first, let oldestId, let newestId, !messages.isEmpty else { return show(page) }
        if !jsLess(first.id, oldestId), !jsLess(newestId, first.id) {
            messages.removeAll { !jsLess($0.id, first.id) }
            messages += page.messages.filter(\.isInRoom)
            dropConfirmed(by: page.messages)
            hasNewer = page.hasNewer
            self.newestId = page.messages.last?.id
            anchor = nil
            arrivals = 0
            olderPageFailure = nil
            newerPageFailure = nil
            cutFromStart()
        } else if isAwayFromLatest, jsLess(newestId, first.id) {
            dropConfirmed(by: page.messages)
            if !hasNewer { arrivals += 1 }
            hasNewer = true
            olderPageFailure = nil
            newerPageFailure = nil
        } else {
            show(page)
        }
    }

    private mutating func settle() {
        isLoaded = true
        isLoadingOlder = false
        isLoadingNewer = false
        isLoadingPage = false
        typing = []
        ahead = []
        needsCatchUp = false
    }

    /// Whether a numbered change is news: false for one already heard, which changes nothing again.
    ///
    /// The room numbers its changes one after another, so a gap is one not heard of yet. `seq` stays
    /// at the change before it, so connecting again with `since` brings what was missed; the changes
    /// after it are kept in `ahead` and move `seq` on should it arrive late. A room that doesn't number
    /// its changes (no `seq` on its welcome) stays without one.
    private mutating func see(_ seq: Int) -> Bool {
        guard let current = self.seq else { return true }
        guard seq > current, !ahead.contains(seq) else { return false }
        if seq == current + 1 {
            var latest = seq
            while ahead.remove(latest + 1) != nil { latest += 1 }
            self.seq = latest
        } else {
            ahead.insert(seq)
        }
        needsCatchUp = ahead.count >= Limits.seqReorder
        return true
    }

    /// Puts a message among the others by id, which orders them as the room does, wherever it arrives.
    private mutating func insert(_ message: Message) {
        let index = messages.lastIndex { jsLess($0.id, message.id) }.map { $0 + 1 } ?? 0
        messages.insert(message, at: index)
    }

    /// What `olderPageFailure` or `newerPageFailure` says of a page that brought nothing to move on from.
    static let emptyPage = "The room sent an empty page."

    /// Whether a message changed while we were away belongs between the page's bounds.
    private func inRange(_ id: String) -> Bool {
        if let oldestId, !jsLess(oldestId, id) { return false }
        if hasNewer, let newestId, !jsLess(id, newestId) { return false }
        return true
    }

    /// Drops the pending messages these confirm: the same client id, sent by me. Matching the
    /// creator too stops someone else's message claiming one of mine by reusing its id.
    private mutating func dropConfirmed(by confirmed: [Message]) {
        guard let me, !pending.isEmpty else { return }
        let ids = Set(confirmed.filter { $0.creator.id == me.id }.map(\.clientMessageId))
        pending.removeAll { ids.contains($0.clientMessageId) }
    }

    /// Replies quote their parent's text, so an edit retells it in each.
    private mutating func retell(_ parent: Message) {
        let text = Self.parentText(of: parent.plainText)
        for index in messages.indices where messages[index].parentId == parent.id {
            messages[index].parentText = text
        }
    }

    /// The `message.check` frames for whatever's still on its way, after a (re)connect lost its
    /// confirmations.
    private func checks() -> [ClientFrame] {
        pending.checks()
    }

    /// Lets the oldest messages go once there are too many, as new ones arrive.
    private mutating func cutFromStart() {
        guard messages.count > Limits.timelineMessages + Limits.timelineLeeway else { return }
        let over = messages.count - Limits.timelineMessages
        oldestId = messages[over].id
        messages.removeFirst(over)
        hasMore = true
    }

    /// Lets the newest messages go once there are too many, as older pages arrive.
    private mutating func cutFromEnd() {
        guard messages.count > Limits.timelineMessages + Limits.timelineLeeway else { return }
        newestId = messages[Limits.timelineMessages - 1].id
        messages.removeLast(messages.count - Limits.timelineMessages)
        hasNewer = true
    }
}

extension [PendingMessage] {
    /// The `message.check` frames for those a reconnect asks about, in chunks the room takes.
    func checks() -> [ClientFrame] {
        let ids = filter(\.isChecked).map(\.clientMessageId)
        return stride(from: 0, to: ids.count, by: Limits.checkedMessages).map {
            .checkMessages(clientMessageIds: [String](ids[$0 ..< Swift.min($0 + Limits.checkedMessages, ids.count)]))
        }
    }

    mutating func progress(_ clientMessageId: String, sentBytes: Int) {
        guard let index = firstIndex(where: { $0.clientMessageId == clientMessageId }), let upload = self[index].upload else { return }
        // Only forward: a part sent again counts from its start, and the bar shouldn't jump back for
        // it. A whole upload retried starts from 0 in `retry`, not here.
        self[index].upload?.sentBytes = Swift.max(upload.sentBytes, Swift.min(Swift.max(0, sentBytes), upload.byteSize))
    }

    mutating func fail(_ clientMessageId: String, reason: String) -> ClientFrame? {
        guard let index = firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return nil }
        self[index].failure = reason
        return self[index].upload == nil ? nil : .checkMessages(clientMessageIds: [clientMessageId])
    }
}
