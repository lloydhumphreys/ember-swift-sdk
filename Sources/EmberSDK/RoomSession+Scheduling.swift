import Foundation

extension RoomSession {
    /// Schedules a message to the room for `sendAt`, returning its `clientMessageId` once the room
    /// has it: `timeline.scheduled` lists it, or its time has come and it's been sent. The room
    /// keeps up to `Limits.scheduledMessages` of yours at once, each for a time to come within
    /// `Limits.scheduleAhead`. `previews` go after the body.
    ///
    /// Throws the room's refusal (`kind` `.refused`), `.invalid`, sending nothing, for a body over
    /// `Limits.message` characters, `.timedOut` when nothing came in `changeTimeout`, and
    /// `.unreachable` when the room isn't connected or connecting. One asked for while the room is
    /// connecting goes once it's let in, and one whose answer a dropped socket lost goes again on
    /// the next connection, as the room keeps a message scheduled twice under one id once.
    @discardableResult
    public func schedule(body: String, at sendAt: Date, previews: [LinkPreview] = []) async throws -> ClientMessageID {
        try await schedule(body: withPreviews(body, previews), at: sendAt, parentId: nil, alsoSend: nil)
    }

    /// Schedules a message, or with `parentId` a reply in that message's thread.
    func schedule(body: String, at sendAt: Date, parentId: MessageID?, alsoSend: Bool?) async throws -> ClientMessageID {
        guard body.utf16.count <= Limits.message else { throw EmberError(kind: .invalid, message: PlainTextMessage.tooLong) }
        let id = ClientMessageID(UUID().uuidString.lowercased())
        let frame = ClientFrame.scheduleMessage(clientMessageId: id, body: body, sendAt: sendAt, parentId: parentId, alsoSend: alsoSend)
        _ = try await change(frame, resends: true) { frame in
            switch frame {
            case let .scheduled(messages, _): messages.contains { $0.clientMessageId == id }
            // A welcome that doesn't list it may hold it sent, when its time came while the socket was away.
            case let .welcome(_, _, _, page, _, scheduled):
                scheduled.contains { $0.clientMessageId == id } || page.messages.contains { $0.clientMessageId == id }
            case let .resumed(_, messages, _, _, _, _, scheduled):
                scheduled.contains { $0.clientMessageId == id } || messages.contains { $0.clientMessageId == id }
            default: false
            }
        }
        return id
    }

    /// Changes a scheduled message's body, keeping its time, returning once the room has made the
    /// edit and `timeline.scheduled` shows it. Throws as `edit(message:body:)` does: the room's
    /// refusal, such as one for a message that's been sent or deleted since, is thrown and never the
    /// room's `notice`.
    public func edit(scheduled scheduledID: ScheduledMessageID, body: String) async throws {
        guard body.utf16.count <= Limits.message else { throw EmberError(kind: .invalid, message: PlainTextMessage.tooLong) }
        _ = try await change(.editScheduled(scheduledId: scheduledID, body: body)) { frame in
            if case let .scheduled(_, edited) = frame { edited == scheduledID } else { false }
        }
    }

    /// Moves a scheduled message to `sendAt`, a time to come within `Limits.scheduleAhead`. The room
    /// answers with what's scheduled now, in `timeline.scheduled`, and a refusal is the room's
    /// `notice`. Throws `.unreachable` when the room hasn't let the socket in; nothing is kept to
    /// send later.
    public func reschedule(scheduled scheduledID: ScheduledMessageID, to sendAt: Date) throws {
        try changeScheduled(.reschedule(scheduledId: scheduledID, sendAt: sendAt))
    }

    /// Sends a scheduled message now, as if it had just been written: it arrives as a message with
    /// its `clientMessageId` and leaves `timeline.scheduled`, or stays there with why it couldn't be
    /// sent as its `failure`, which is the room's `notice` too. Throws as
    /// `reschedule(scheduled:to:)` does.
    public func sendNow(scheduled scheduledID: ScheduledMessageID) throws {
        try changeScheduled(.sendScheduled(scheduledId: scheduledID))
    }

    /// Deletes a scheduled message, unsent. Throws as `reschedule(scheduled:to:)` does.
    public func delete(scheduled scheduledID: ScheduledMessageID) throws {
        try changeScheduled(.deleteScheduled(scheduledId: scheduledID))
    }

    private func changeScheduled(_ frame: ClientFrame) throws {
        guard isAdmitted, transmit(sending: frame) else {
            throw EmberError(kind: .unreachable, message: Self.notConnected)
        }
    }
}
