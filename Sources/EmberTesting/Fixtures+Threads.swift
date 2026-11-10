import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Replies

    /// A reply under `parentID`, by Grace in General unless said otherwise, quoting `parentText`.
    /// `alsoSent` puts it in the room's timeline too.
    public static func reply(
        _ id: String,
        _ text: String,
        to parentID: String,
        by creator: User = grace,
        in roomID: RoomID = general.id,
        minute: Int = 0,
        alsoSent: Bool = false,
        parentText: String = "",
        clientMessageId: String? = nil
    ) -> Message {
        var reply = message(id, text, by: creator, in: roomID, minute: minute, clientMessageId: clientMessageId)
        reply.parentId = parentID
        reply.alsoSent = alsoSent ? true : nil
        reply.parentText = parentText
        return reply
    }

    /// What a deleted message with replies leaves: no text, `deleted`, and its thread still there.
    public static func tombstone(_ id: String, by creator: User = grace, in roomID: RoomID = general.id, minute: Int = 0) -> Message {
        var message = message(id, "", by: creator, in: roomID, minute: minute)
        message.body = ""
        message.deleted = true
        return message
    }

    /// `message` with a thread of `count` replies, the latest at `minute`, by `people`.
    public static func withThread(_ message: Message, count: Int, latestMinute minute: Int = 30, people: [User] = [grace]) -> Message {
        var message = message
        message.thread = threadSummary(count: count, latestMinute: minute, people: people)
        return message
    }

    /// A thread's summary as its parent carries it.
    public static func threadSummary(count: Int, latestMinute minute: Int = 30, people: [User] = [grace]) -> ThreadSummary {
        let latest = date("2026-10-12T10:00:00.000Z").addingTimeInterval(TimeInterval(minute * 60))
        return decode(json([
            "count": count, "latestAt": EmberJSON.string(from: latest), "people": people.map { value($0) },
        ]))
    }

    // MARK: Files

    /// A stored file, served from signed paths under `/files/`.
    public static func storedFile(
        _ id: String = "file_1",
        name: String = "notes.txt",
        contentType: String = "text/plain",
        byteSize: Int = 12,
        width: Int? = nil,
        height: Int? = nil,
        preview: Bool = false
    ) -> StoredFile {
        decode(json([
            "id": id, "name": name, "contentType": contentType, "byteSize": byteSize,
            "width": width ?? NSNull(), "height": height ?? NSNull(),
            "url": "/files/\(id)/\(name)?sig=test", "downloadUrl": "/files/\(id)/\(name)?sig=test&download=1",
            "previewUrl": preview ? "/files/\(id)/preview?sig=test" : NSNull(),
        ]))
    }

    /// A file message, as an upload's last part answers it: no text, and the file attached.
    public static func fileMessage(
        _ id: String,
        file: StoredFile = storedFile(),
        by creator: User = ada,
        in roomID: RoomID = general.id,
        minute: Int = 0,
        parentID: String? = nil,
        alsoSent: Bool = false,
        clientMessageId: String
    ) -> Message {
        var message = message(id, "", by: creator, in: roomID, minute: minute, clientMessageId: clientMessageId)
        message.body = ""
        message.attachment = file
        message.parentId = parentID
        message.alsoSent = parentID != nil && alsoSent ? true : nil
        return message
    }

    /// What starting an upload answers.
    public static func uploadTicket(_ id: String = "upload_1", partSize: Int = 5 * 1024 * 1024, parts: Int = 1) -> UploadTicket {
        UploadTicket(id: id, partSize: partSize, parts: parts)
    }

    /// `POST /api/rooms/:id/uploads`'s answer.
    public static func uploadTicketJSON(_ ticket: UploadTicket) -> String {
        json(["id": ticket.id, "partSize": ticket.partSize, "parts": ticket.parts])
    }

    /// A message as bare JSON, as a completing part answers it.
    public static func messageJSON(_ message: Message) -> String {
        guard let object = value(message) as? [String: Any] else { return "{}" }
        return json(object)
    }
}

extension Fixtures.RoomFrames {
    /// `thread.opened`: the thread's parent (nil for one that's gone) and its newest replies.
    public static func threadOpened(_ parentID: String, parent: Message?, replies: [Message] = [], hasMore: Bool = false) -> String {
        Fixtures.json([
            "type": "thread.opened", "parentId": parentID, "parent": parent.map { Fixtures.value($0) } ?? NSNull(),
            "messages": replies.map { Fixtures.value($0) }, "hasMore": hasMore,
        ])
    }

    /// `thread.history`: the replies before `before`.
    public static func threadHistory(_ parentID: String, before: String, replies: [Message], hasMore: Bool) -> String {
        Fixtures.json([
            "type": "thread.history", "parentId": parentID, "before": before,
            "messages": replies.map { Fixtures.value($0) }, "hasMore": hasMore,
        ])
    }

    /// A bot typing (or stopping) in a thread.
    public static func typing(_ user: User, _ typing: Bool, inThread parentID: String) -> String {
        Fixtures.json(["type": "typing", "user": Fixtures.value(user), "typing": typing, "threadId": parentID])
    }

    /// A refusal of several messages at once, as the room sends for a `message.check`'s resends.
    public static func error(_ message: String, clientMessageIds: [String], failed: String? = nil) -> String {
        var object: [String: Any] = ["type": "error", "message": message, "clientMessageIds": clientMessageIds]
        if let failed { object["failed"] = failed }
        return Fixtures.json(object)
    }
}
