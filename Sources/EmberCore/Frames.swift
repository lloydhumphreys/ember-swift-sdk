import Foundation

// The frames the two sockets carry, as `ClientFrame`, `ServerFrame` and `WorkspaceServerFrame` in
// packages/protocol/src/index.ts declare them. Each `type` string here is the protocol's own.

/// A page of a room's messages that takes the timeline's place: the newest, or the one around a message.
public struct TimelinePage: Decodable, Hashable, Sendable {
    /// Oldest first.
    public var messages: [Message]
    /// Whether the room has messages older than the page.
    public var hasMore: Bool
    /// Whether it has newer ones, which only a page around a message can leave out.
    public var hasNewer: Bool
    /// The message the page is around, or nil for the newest page.
    public var around: String?

    public init(messages: [Message], hasMore: Bool = false, hasNewer: Bool = false, around: String? = nil) {
        self.messages = messages
        self.hasMore = hasMore
        self.hasNewer = hasNewer
        self.around = around
    }

    private enum CodingKeys: String, CodingKey { case messages, hasMore, hasNewer, around }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent(Lossy<Message>.self, forKey: .messages)?.elements ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        hasNewer = try container.decodeIfPresent(Bool.self, forKey: .hasNewer) ?? false
        around = try container.decodeIfPresent(String.self, forKey: .around)
    }
}

// MARK: - Client frames

/// What a client sends on a room socket.
public enum ClientFrame: Equatable, Sendable {
    /// A new message, its body markup. With `parentId`, a reply in that message's thread, which
    /// `alsoSend` sends to the room too.
    case createMessage(clientMessageId: String, body: String, parentId: String? = nil, alsoSend: Bool? = nil)
    case updateMessage(messageId: String, body: String)
    case deleteMessage(messageId: String)
    case createBoost(messageId: String, content: String)
    case deleteBoost(boostId: String)
    case typingStart
    case typingStop
    /// Up to `limit` messages before `messageId`, oldest first. The wire calls it `before`.
    case historyBefore(messageId: String, limit: Int? = nil)
    /// Up to `limit` messages after `messageId`. The wire calls it `after`.
    case historyAfter(messageId: String, limit: Int? = nil)
    /// The page around a message, or the newest page for nil.
    case historyAround(messageId: String?)
    /// Which of these the room stored, after a closed socket lost their confirmations. At most
    /// `Limits.checkedMessages` ids.
    case checkMessages(clientMessageIds: [String])
    case openThread(parentId: String)
    case closeThread(parentId: String)
    case threadBefore(parentId: String, before: String, limit: Int? = nil)
    /// `presence.visible`: the app is or isn't in front.
    case visible(Bool)
    case ping

    /// The protocol's name for the frame (`message.create`, `history.before`…), which is what a server
    /// `error` frame's `failed` names.
    public var type: String {
        switch self {
        case .createMessage: "message.create"
        case .updateMessage: "message.update"
        case .deleteMessage: "message.delete"
        case .createBoost: "boost.create"
        case .deleteBoost: "boost.delete"
        case .typingStart: "typing.start"
        case .typingStop: "typing.stop"
        case .historyBefore: "history.before"
        case .historyAfter: "history.after"
        case .historyAround: "history.around"
        case .checkMessages: "message.check"
        case .openThread: "thread.open"
        case .closeThread: "thread.close"
        case .threadBefore: "thread.before"
        case .visible: "presence.visible"
        case .ping: "ping"
        }
    }

    /// The frame's fields, `type` among them, as the wire has them.
    public var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["type": .string(type)]
        func set(_ key: String, _ value: String?) { if let value { fields[key] = .string(value) } }
        func set(_ key: String, _ value: Int?) { if let value { fields[key] = .number(Double(value)) } }
        func set(_ key: String, _ value: Bool?) { if let value { fields[key] = .bool(value) } }
        switch self {
        case let .createMessage(clientMessageId, body, parentId, alsoSend):
            set("clientMessageId", clientMessageId)
            set("body", body)
            set("parentId", parentId)
            set("alsoSend", alsoSend)
        case let .updateMessage(messageId, body):
            set("messageId", messageId)
            set("body", body)
        case let .deleteMessage(messageId):
            set("messageId", messageId)
        case let .createBoost(messageId, content):
            set("messageId", messageId)
            set("content", content)
        case let .deleteBoost(boostId):
            set("boostId", boostId)
        case let .historyBefore(messageId, limit):
            set("before", messageId)
            set("limit", limit)
        case let .historyAfter(messageId, limit):
            set("after", messageId)
            set("limit", limit)
        case let .historyAround(messageId):
            set("messageId", messageId)
        case let .checkMessages(clientMessageIds):
            fields["clientMessageIds"] = .array(clientMessageIds.map(JSONValue.string))
        case let .openThread(parentId), let .closeThread(parentId):
            set("parentId", parentId)
        case let .threadBefore(parentId, before, limit):
            set("parentId", parentId)
            set("before", before)
            set("limit", limit)
        case let .visible(visible):
            set("visible", visible)
        case .typingStart, .typingStop, .ping:
            break
        }
        return fields
    }

    /// The frame as the JSON text the socket sends. `ping` is exactly `{"type":"ping"}`.
    public var text: String {
        if case .ping = self { return #"{"type":"ping"}"# }
        let encoder = EmberJSON.encoder()
        encoder.outputFormatting.insert(.sortedKeys)
        // Strings, numbers and booleans always encode.
        let data = (try? encoder.encode(fields)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a frame a client sent, as the room would: nil for anything it wouldn't take. For tests and
    /// stand-in servers that check what a client sent.
    public init?(text: String) {
        guard let value = try? EmberJSON.decoder().decode(JSONValue.self, from: Data(text.utf8)),
              case let .object(f) = value, case let .string(type)? = f["type"] else { return nil }
        func string(_ key: String) -> String? { if case let .string(s)? = f[key] { s } else { nil } }
        func int(_ key: String) -> Int? { if case let .number(n)? = f[key], n == n.rounded() { Int(n) } else { nil } }
        func bool(_ key: String) -> Bool? { if case let .bool(b)? = f[key] { b } else { nil } }
        switch type {
        case "message.create":
            guard let id = string("clientMessageId"), let body = string("body") else { return nil }
            self = .createMessage(clientMessageId: id, body: body, parentId: string("parentId"), alsoSend: bool("alsoSend"))
        case "message.update":
            guard let id = string("messageId"), let body = string("body") else { return nil }
            self = .updateMessage(messageId: id, body: body)
        case "message.delete":
            guard let id = string("messageId") else { return nil }
            self = .deleteMessage(messageId: id)
        case "boost.create":
            guard let id = string("messageId"), let content = string("content") else { return nil }
            self = .createBoost(messageId: id, content: content)
        case "boost.delete":
            guard let id = string("boostId") else { return nil }
            self = .deleteBoost(boostId: id)
        case "typing.start": self = .typingStart
        case "typing.stop": self = .typingStop
        case "history.before":
            guard let id = string("before") else { return nil }
            self = .historyBefore(messageId: id, limit: int("limit"))
        case "history.after":
            guard let id = string("after") else { return nil }
            self = .historyAfter(messageId: id, limit: int("limit"))
        case "history.around":
            self = .historyAround(messageId: string("messageId"))
        case "message.check":
            guard case let .array(items)? = f["clientMessageIds"] else { return nil }
            let ids = items.compactMap { if case let .string(s) = $0 { s } else { nil } }
            guard ids.count == items.count else { return nil }
            self = .checkMessages(clientMessageIds: ids)
        case "thread.open":
            guard let id = string("parentId") else { return nil }
            self = .openThread(parentId: id)
        case "thread.close":
            guard let id = string("parentId") else { return nil }
            self = .closeThread(parentId: id)
        case "thread.before":
            guard let id = string("parentId"), let before = string("before") else { return nil }
            self = .threadBefore(parentId: id, before: before, limit: int("limit"))
        case "presence.visible":
            guard let visible = bool("visible") else { return nil }
            self = .visible(visible)
        case "ping": self = .ping
        default: return nil
        }
    }
}

// MARK: - Room frames

/// What a room sends. `init(text:)` never throws: anything it can't read is `.unknown(type)`, with
/// the frame's `type`, or an empty string when the text isn't a frame at all.
public enum ServerFrame: Equatable, Sendable {
    /// Everything a newcomer needs. Its page is the newest, or the one around the message the
    /// socket's address named.
    case welcome(you: User, present: [User], seq: Int, page: TimelinePage)
    /// In place of a welcome, to a socket that named `since=`: the messages changed since, as they are
    /// now, oldest first, and the ids of those deleted.
    case resumed(you: User, messages: [Message], deletedIds: [String], present: [User], seq: Int)
    case messageCreated(Message, seq: Int)
    case messageUpdated(Message, seq: Int)
    case messageDeleted(messageId: String, seq: Int)
    case boostCreated(Boost, seq: Int)
    case boostDeleted(boostId: String, messageId: String, seq: Int)
    case presenceJoined(User)
    case presenceLeft(userId: UserID)
    /// Someone started or stopped typing: in the room's composer, or, with `threadId`, in that thread.
    case typing(user: User, typing: Bool, threadId: String?)
    /// Answers `history.before`.
    case history(before: String, messages: [Message], hasMore: Bool)
    /// Answers `history.after`.
    case historyAfter(after: String, messages: [Message], hasNewer: Bool)
    /// Answers `history.around` with a page to show in the timeline's place.
    case historyAround(TimelinePage)
    /// Answers `message.check`: which the room stored, and which it never received.
    case messageChecked(stored: [String], missing: [String])
    case threadOpened(parentId: String, parent: Message?, messages: [Message], hasMore: Bool)
    case threadHistory(parentId: String, before: String, messages: [Message], hasMore: Bool)
    /// `failed` names the request that went wrong (a `ClientFrame.type`), and `clientMessageId` or
    /// `clientMessageIds` the messages it was about.
    case error(message: String, clientMessageId: String?, clientMessageIds: [String]?, failed: String?)
    case pong
    case unknown(String)

    public init(text: String) {
        let data = Data(text.utf8)
        let decoder = EmberJSON.decoder()
        guard let head = try? decoder.decode(FrameType.self, from: data) else {
            self = .unknown("")
            return
        }
        do {
            self = try Self.decode(head.type, data, decoder)
        } catch {
            self = .unknown(head.type)
        }
    }

    private static func decode(_ type: String, _ data: Data, _ decoder: JSONDecoder) throws -> ServerFrame {
        func read<T: Decodable>(_: T.Type) throws -> T { try decoder.decode(T.self, from: data) }
        switch type {
        case "welcome":
            let f = try read(Welcome.self)
            return .welcome(you: f.you, present: f.present?.elements ?? [], seq: f.seq, page: try read(TimelinePage.self))
        case "resumed":
            let f = try read(Resumed.self)
            return .resumed(you: f.you, messages: f.messages?.elements ?? [], deletedIds: f.deletedIds ?? [], present: f.present?.elements ?? [], seq: f.seq)
        case "message.created":
            let f = try read(MessageChange.self)
            return .messageCreated(f.message, seq: f.seq)
        case "message.updated":
            let f = try read(MessageChange.self)
            return .messageUpdated(f.message, seq: f.seq)
        case "message.deleted":
            let f = try read(MessageDeleted.self)
            return .messageDeleted(messageId: f.messageId, seq: f.seq)
        case "boost.created":
            let f = try read(BoostCreated.self)
            return .boostCreated(f.boost, seq: f.seq)
        case "boost.deleted":
            let f = try read(BoostDeleted.self)
            return .boostDeleted(boostId: f.boostId, messageId: f.messageId, seq: f.seq)
        case "presence.joined":
            return .presenceJoined(try read(PresenceJoined.self).user)
        case "presence.left":
            return .presenceLeft(userId: try read(PresenceLeft.self).userId)
        case "typing":
            let f = try read(Typing.self)
            return .typing(user: f.user, typing: f.typing, threadId: f.threadId)
        case "history":
            let f = try read(History.self)
            return .history(before: f.before, messages: f.messages?.elements ?? [], hasMore: f.hasMore ?? false)
        case "history.after":
            let f = try read(HistoryAfter.self)
            return .historyAfter(after: f.after, messages: f.messages?.elements ?? [], hasNewer: f.hasNewer ?? false)
        case "history.around":
            return .historyAround(try read(TimelinePage.self))
        case "message.checked":
            let f = try read(Checked.self)
            return .messageChecked(stored: f.stored ?? [], missing: f.missing ?? [])
        case "thread.opened":
            let f = try read(ThreadOpened.self)
            return .threadOpened(parentId: f.parentId, parent: f.parent?.value, messages: f.messages?.elements ?? [], hasMore: f.hasMore ?? false)
        case "thread.history":
            let f = try read(ThreadHistory.self)
            return .threadHistory(parentId: f.parentId, before: f.before, messages: f.messages?.elements ?? [], hasMore: f.hasMore ?? false)
        case "error":
            let f = try read(ErrorFrame.self)
            return .error(message: f.message ?? "", clientMessageId: f.clientMessageId, clientMessageIds: f.clientMessageIds, failed: f.failed)
        case "pong":
            return .pong
        default:
            return .unknown(type)
        }
    }

    // Lists are read one element at a time: one the build can't read is left out, never the frame.
    private struct Welcome: Decodable { var you: User; var present: Lossy<User>?; var seq: Int }
    private struct Resumed: Decodable { var you: User; var messages: Lossy<Message>?; var deletedIds: [String]?; var present: Lossy<User>?; var seq: Int }
    private struct MessageChange: Decodable { var message: Message; var seq: Int }
    private struct MessageDeleted: Decodable { var messageId: String; var seq: Int }
    private struct BoostCreated: Decodable { var boost: Boost; var seq: Int }
    private struct BoostDeleted: Decodable { var boostId: String; var messageId: String; var seq: Int }
    private struct PresenceJoined: Decodable { var user: User }
    private struct PresenceLeft: Decodable { var userId: UserID }
    private struct Typing: Decodable { var user: User; var typing: Bool; var threadId: String? }
    private struct History: Decodable { var before: String; var messages: Lossy<Message>?; var hasMore: Bool? }
    private struct HistoryAfter: Decodable { var after: String; var messages: Lossy<Message>?; var hasNewer: Bool? }
    private struct Checked: Decodable { var stored: [String]?; var missing: [String]? }
    private struct ThreadOpened: Decodable { var parentId: String; var parent: Lenient<Message>?; var messages: Lossy<Message>?; var hasMore: Bool? }
    private struct ThreadHistory: Decodable { var parentId: String; var before: String; var messages: Lossy<Message>?; var hasMore: Bool? }
    private struct ErrorFrame: Decodable { var message: String?; var clientMessageId: String?; var clientMessageIds: [String]?; var failed: String? }
}

/// A frame's `type`, read before the rest.
private struct FrameType: Decodable { var type: String }

/// A value read if this build can, and nil if it can't.
private struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Workspace frames

/// What the workspace socket (`/api/socket`) sends. `init(text:)` never throws: anything it can't
/// read is `.unknown(type)`, as for `ServerFrame`.
public enum WorkspaceFrame: Equatable, Sendable {
    /// Sent as the socket opens: who its session signs in, and the workspace as it is then.
    case welcome(you: Me, account: Account)
    /// A room of theirs has a message they haven't seen.
    case roomUnread(RoomID)
    /// They've read a room marked unread, here or elsewhere.
    case roomRead(RoomID)
    /// Someone changed, as the directory now lists them.
    case userUpdated(DirectoryUser)
    /// A room of theirs as it is now: made, renamed, changed, or newly theirs.
    case roomSaved(Room)
    /// A room that's no longer theirs.
    case roomGone(RoomID)
    /// A message came in a DM of theirs at `at`.
    case roomActive(RoomID, at: Date)
    /// Their stars as they are now.
    case favoritesChanged(Favorites)
    /// Their new notification level in a room.
    case roomInvolvement(RoomID, Involvement)
    /// They dismissed the welcome card.
    case invitationDismissed
    /// An administrator saved the shared room order, which names no rooms: load the sidebar again.
    case roomsReordered
    case accountUpdated(Account)
    case error(String)
    case pong
    case unknown(String)

    public init(text: String) {
        let data = Data(text.utf8)
        let decoder = EmberJSON.decoder()
        guard let head = try? decoder.decode(FrameType.self, from: data) else {
            self = .unknown("")
            return
        }
        do {
            self = try Self.decode(head.type, data, decoder)
        } catch {
            self = .unknown(head.type)
        }
    }

    private static func decode(_ type: String, _ data: Data, _ decoder: JSONDecoder) throws -> WorkspaceFrame {
        func read<T: Decodable>(_: T.Type) throws -> T { try decoder.decode(T.self, from: data) }
        switch type {
        case "welcome":
            let f = try read(Welcome.self)
            return .welcome(you: f.you, account: f.account)
        case "room.unread": return .roomUnread(try read(RoomOnly.self).roomId)
        case "room.read": return .roomRead(try read(RoomOnly.self).roomId)
        case "user.updated": return .userUpdated(try read(UserUpdated.self).user)
        case "room.saved": return .roomSaved(try read(RoomSaved.self).room)
        case "room.gone": return .roomGone(try read(RoomOnly.self).roomId)
        case "room.active":
            let f = try read(RoomActive.self)
            return .roomActive(f.roomId, at: f.at)
        case "favorites.changed": return .favoritesChanged(try read(FavoritesChanged.self).favorites)
        case "room.involvement":
            let f = try read(RoomInvolvement.self)
            return .roomInvolvement(f.roomId, f.involvement)
        case "invitation.dismissed": return .invitationDismissed
        case "rooms.reordered": return .roomsReordered
        case "account.updated": return .accountUpdated(try read(AccountUpdated.self).account)
        case "error": return .error(try read(ErrorFrame.self).message ?? "")
        case "pong": return .pong
        default: return .unknown(type)
        }
    }

    private struct Welcome: Decodable { var you: Me; var account: Account }
    private struct RoomOnly: Decodable { var roomId: RoomID }
    private struct UserUpdated: Decodable { var user: DirectoryUser }
    private struct RoomSaved: Decodable { var room: Room }
    private struct RoomActive: Decodable { var roomId: RoomID; var at: Date }
    private struct FavoritesChanged: Decodable { var favorites: Favorites }
    private struct RoomInvolvement: Decodable { var roomId: RoomID; var involvement: Involvement }
    private struct AccountUpdated: Decodable { var account: Account }
    private struct ErrorFrame: Decodable { var message: String? }
}

// MARK: - Sockets

/// The query of a room socket's address, as `roomSocketQuery` writes it, without its `?`:
/// `visible=0|1&protocol=4[&since=<seq>][&around=<id>]`.
public enum RoomSocket {
    /// The revision of the room protocol this SDK speaks. The room refuses messages from older ones.
    public static let protocolRevision = 4

    public static func query(visible: Bool, since: Int?, around: String?) -> String {
        var query = "visible=\(visible ? 1 : 0)&protocol=\(protocolRevision)"
        if let since { query += "&since=\(since)" }
        if let around { query += "&around=\(encodeURIComponent(around))" }
        return query
    }
}

/// The close codes a socket ends with when it isn't coming back as it was (`CloseCode` upstream).
public enum SocketClose {
    /// Connect again, after checking the session is still signed in.
    public static let reconnect = 4001
    /// Don't connect again: the person was removed from the workspace or banned.
    public static let revoked = 4003
    /// Don't connect again: the room isn't there for this person.
    public static let notFound = 4004
}
