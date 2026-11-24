import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Scheduled messages and messages only you see

    /// A message scheduled in a room for nine in the morning plus `minute`, or with a `parentId` a
    /// reply scheduled in that message's thread.
    public static func scheduled(
        _ id: ScheduledMessageID,
        _ text: String,
        minute: Int = 0,
        clientMessageId: ClientMessageID? = nil,
        parentId: MessageID? = nil,
        alsoSend: Bool = false,
        failure: String? = nil
    ) -> ScheduledMessage {
        ScheduledMessage(
            id: id, clientMessageId: clientMessageId ?? "client_\(id)", body: "<p>\(text)</p>",
            sendAt: date("2026-11-24T09:00:00.000Z").addingTimeInterval(TimeInterval(minute * 60)),
            parentId: parentId, alsoSend: alsoSend, failure: failure
        )
    }

    /// A message only you see: the assistant's card asking before it calls a connected app's tool,
    /// `approvalCard` unless said otherwise, at a minute past ten plus `minute`.
    public static func ephemeral(
        _ id: MessageID,
        cards: [Card] = [approvalCard],
        plainText: String = "web 2.4.1 is ready for production.",
        by creator: User = User(id: Assistant.id, name: Assistant.name),
        in roomID: RoomID = general.id,
        minute: Int = 0,
        parentId: MessageID? = nil
    ) -> EphemeralMessage {
        EphemeralMessage(
            id: id, roomId: roomID, creator: creator, plainText: plainText, cards: cards,
            createdAt: date("2026-10-12T10:00:00.000Z").addingTimeInterval(TimeInterval(minute * 60)), parentId: parentId
        )
    }

    /// `ScheduledMessage` only decodes, so its JSON is written out here.
    static func scheduledObject(_ message: ScheduledMessage) -> [String: Any] {
        var object: [String: Any] = [
            "id": message.id.rawValue, "clientMessageId": message.clientMessageId.rawValue, "body": message.body,
            "sendAt": EmberJSON.string(from: message.sendAt),
        ]
        if let parentId = message.parentId { object["parentId"] = parentId.rawValue }
        if message.alsoSend { object["alsoSend"] = true }
        if let failure = message.failure { object["failure"] = failure }
        return object
    }

    /// `EphemeralMessage` only decodes, so its JSON is written out here.
    static func ephemeralObject(_ message: EphemeralMessage) -> [String: Any] {
        var object: [String: Any] = [
            "id": message.id.rawValue, "roomId": message.roomId.rawValue, "creator": value(message.creator), "body": message.body,
            "plainText": message.plainText, "cards": message.cards.map { value($0) }, "createdAt": EmberJSON.string(from: message.createdAt),
        ]
        if let parentId = message.parentId { object["parentId"] = parentId.rawValue }
        return object
    }
}

extension Fixtures.RoomFrames {
    /// `scheduled`: every message you've scheduled in the room, soonest first. `edited` is the one
    /// a `scheduled.edit` changed.
    public static func scheduled(_ messages: [ScheduledMessage], edited: ScheduledMessageID? = nil) -> String {
        var object: [String: Any] = ["type": "scheduled", "messages": messages.map(Fixtures.scheduledObject)]
        if let edited { object["edited"] = edited.rawValue }
        return Fixtures.json(object)
    }

    /// `message.ephemeral`: a message only you see, new or changed.
    public static func messageEphemeral(_ message: EphemeralMessage) -> String {
        Fixtures.json(["type": "message.ephemeral", "message": Fixtures.ephemeralObject(message)])
    }
}
