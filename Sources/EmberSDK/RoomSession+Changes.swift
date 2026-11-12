import Foundation

/// An edit, deletion or boost sent with an `async` form, waiting for the room to show it made. The
/// room answers none of them, so the change it broadcasts is the answer: `shows` tells it.
struct ChangeWaiter {
    let id: UUID
    let frame: ClientFrame
    /// What goes right after `frame`, for a change the room doesn't answer when it changes nothing.
    let marker: ClientFrame?
    /// The frame's type, as an error's `failed` names it.
    var type: String { frame.type }
    let shows: @MainActor (ServerFrame) -> Bool
    let continuation: CheckedContinuation<ServerFrame?, any Error>
    let timer: Task<Void, Never>
    /// Whether it went on a socket. One asked for while the room was reconnecting waits to be let in.
    var isWritten: Bool
}

extension RoomSession {
    /// How long an `async` edit, deletion or boost waits for the room to show it made.
    public static let changeTimeout: Duration = .seconds(15)

    /// What an `async` change throws when no answer came in `changeTimeout`.
    public static let changeTimedOut = "The room didn’t answer. Try again."

    /// Edits one of your messages, returning once the room has taken the edit: its `message.updated`
    /// is in the timeline, or it had nothing to change once it sanitised the body. Throws the room's
    /// refusal (`kind` `.refused`), `.timedOut` when nothing came in `changeTimeout`, and
    /// `.unreachable` when the room isn't connected or connecting, or the socket drops after the
    /// edit went on it. One asked for while the room is connecting goes once it's let in, and is
    /// timed from when it was asked for: one that runs out of time first is never sent. A body the
    /// same as the message's returns at once, as the room changes nothing for it.
    ///
    /// The room says nothing for an edit that changes nothing, and the body it stores may differ
    /// from the one sent, so neither the body nor an echo is waited for: a `message.check` for an id
    /// no message has goes right after the edit, and the room, which handles a socket's frames one
    /// at a time and in order, answers it only once the edit is stored, echoed or refused.
    public func edit(message messageID: String, body: String) async throws {
        if knownMessage(messageID)?.body == body { return }
        let marker = UUID().uuidString.lowercased()
        _ = try await change(.updateMessage(messageId: messageID, body: body), then: .checkMessages(clientMessageIds: [marker])) { frame in
            if case let .messageChecked(stored, missing) = frame { stored.contains(marker) || missing.contains(marker) } else { false }
        }
    }

    /// Deletes one of your messages, returning once the room has shown it gone: deleted, or kept
    /// for its thread's replies. Throws as `edit(message:body:)` does.
    public func delete(message messageID: String) async throws {
        _ = try await change(.deleteMessage(messageId: messageID)) { frame in
            switch frame {
            case let .messageDeleted(id, _): id == messageID
            case let .messageUpdated(message, _): message.id == messageID && message.isDeleted
            default: false
            }
        }
    }

    /// Boosts a message with an emoji or a few words, trimmed, returning the boost once the room
    /// has shown it. Throws `.invalid` for one that doesn't fit (`Limits.boostFits`), and otherwise
    /// as `edit(message:body:)` does. A boost of yours with the same content returns at once.
    @discardableResult
    public func boost(message messageID: String, content: String) async throws -> Boost {
        guard Limits.boostFits(content) else {
            throw EmberError(kind: .invalid, message: "Boosts can be up to \(Limits.boost) characters.")
        }
        let content = Limits.trimmedBoost(content)
        let me = timeline.me?.id
        if let me, let boost = knownMessage(messageID)?.boosts.first(where: { $0.booster.id == me && $0.content == content }) {
            return boost
        }
        let frame = try await change(.createBoost(messageId: messageID, content: content)) { frame in
            if case let .boostCreated(boost, _) = frame {
                boost.messageId == messageID && boost.booster.id == me && boost.content == content
            } else {
                false
            }
        }
        guard case let .boostCreated(boost, _) = frame else { throw EmberError.unreadable(status: 0) }
        return boost
    }

    /// Takes back one of your boosts, returning once the room has shown it gone. Throws as
    /// `edit(message:body:)` does.
    public func removeBoost(id boostID: String) async throws {
        _ = try await change(.deleteBoost(boostId: boostID)) { frame in
            if case let .boostDeleted(id, _, _) = frame { id == boostID } else { false }
        }
    }

    /// The message `id` as the room or an open thread has it.
    private func knownMessage(_ id: String) -> Message? {
        timeline.message(id) ?? threads.lazy.compactMap { $0.timeline.replies.first { $0.id == id } }.first
    }

    /// Sends `frame`, and `marker` after it, now or once the room lets the socket in, and waits for
    /// the frame `shows` picks out, a refusal, the clock, or a drop after it was sent.
    private func change(_ frame: ClientFrame, then marker: ClientFrame? = nil, shows: @escaping @MainActor (ServerFrame) -> Bool) async throws -> ServerFrame? {
        let unreachable = EmberError(kind: .unreachable, message: Self.notConnected)
        if isAdmitted {
            guard write(frame, then: marker) else { throw unreachable }
        } else {
            guard status == .connecting || status == .open else { throw unreachable }
        }
        let isWritten = isAdmitted
        let id = UUID()
        let timing = client.timing
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await timing.sleep(for: Self.changeTimeout) } catch { return }
                self?.finishChange(id, with: .failure(EmberError(kind: .timedOut, message: Self.changeTimedOut)))
            }
            changes.append(ChangeWaiter(id: id, frame: frame, marker: marker, shows: shows, continuation: continuation, timer: timer, isWritten: isWritten))
        }
    }

    private func write(_ frame: ClientFrame, then marker: ClientFrame?) -> Bool {
        transmit(sending: frame) && (marker.map { transmit(sending: $0) } ?? true)
    }

    /// The room has let the socket in: the changes asked for while it was connecting go now, in the
    /// order they were asked for.
    func sendWaitingChanges() {
        for index in changes.indices where !changes[index].isWritten {
            let waiter = changes[index]
            changes[index].isWritten = true
            if !write(waiter.frame, then: waiter.marker) {
                finishChange(waiter.id, with: .failure(EmberError(kind: .unreachable, message: Self.notConnected)))
                return sendWaitingChanges()
            }
        }
    }

    private func finishChange(_ id: UUID, with result: Result<ServerFrame?, any Error>) {
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return }
        let waiter = changes.remove(at: index)
        waiter.timer.cancel()
        waiter.continuation.resume(with: result)
    }

    /// Finishes each change `frame` shows made.
    func changeShown(_ frame: ServerFrame) {
        for waiter in changes where waiter.shows(frame) {
            finishChange(waiter.id, with: .success(frame))
        }
    }

    /// Hands an error frame that names no message to the oldest change it can be the answer to,
    /// since the room answers a socket's frames in order: one that names the frame's type, or names
    /// none, as most refusals of these do. Answers whether one took it.
    func changeRefused(_ message: String, failed: String?) -> Bool {
        guard let waiter = changes.first(where: { $0.isWritten && (failed == nil || $0.type == failed) }) else { return false }
        finishChange(waiter.id, with: .failure(EmberError(kind: .refused, message: message)))
        return true
    }

    /// The socket dropped, to `status`: no answer to what was sent on it will come. What wasn't sent
    /// yet waits for the next connection, unless the room has stopped trying.
    func changesDisconnected(_ status: ReconnectingSocket.Status) {
        let isTrying = status == .connecting || status == .open
        for waiter in changes where waiter.isWritten || !isTrying {
            finishChange(waiter.id, with: .failure(EmberError(kind: .unreachable, message: Self.notConnected)))
        }
    }
}
