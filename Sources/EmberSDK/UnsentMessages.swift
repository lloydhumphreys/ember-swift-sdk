import Foundation

/// Whose unsent messages, in which room, on which server.
public struct UnsentMessageKey: Hashable, Sendable {
    /// The server's origin.
    public var server: URL
    /// Who wrote them.
    public var userID: UserID
    /// The room they're for.
    public var roomID: RoomID

    public init(server: URL, userID: UserID, roomID: RoomID) {
        self.server = server
        self.userID = userID
        self.roomID = roomID
    }
}

/// A room message or thread reply written but not yet confirmed, as it's kept across launches. It
/// goes again under the same `clientMessageId`, but only after a `message.check` says the room
/// doesn't have it: the room stores a create twice if it's sent twice.
public struct UnsentMessage: Codable, Hashable, Sendable {
    public var clientMessageId: String
    public var body: String
    public var plainText: String
    public var createdAt: Date
    /// Why it failed, for one that did; it comes back failed, for a retry or a discard.
    public var failure: String?
    /// The message it replies to, for a thread reply; nil for a room message.
    public var parentId: String?
    /// Whether a reply goes to the room too.
    public var alsoSend: Bool

    public init(clientMessageId: String, body: String, plainText: String, createdAt: Date, failure: String? = nil, parentId: String? = nil, alsoSend: Bool = false) {
        self.clientMessageId = clientMessageId
        self.body = body
        self.plainText = plainText
        self.createdAt = createdAt
        self.failure = failure
        self.parentId = parentId
        self.alsoSend = parentId != nil && alsoSend
    }

    private enum CodingKeys: String, CodingKey { case clientMessageId, body, plainText, createdAt, failure, parentId, alsoSend }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientMessageId = try container.decode(String.self, forKey: .clientMessageId)
        body = try container.decode(String.self, forKey: .body)
        plainText = try container.decode(String.self, forKey: .plainText)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        alsoSend = try container.decodeIfPresent(Bool.self, forKey: .alsoSend) ?? false
    }

    init(_ pending: PendingMessage) {
        self.init(
            clientMessageId: pending.clientMessageId, body: pending.body, plainText: pending.plainText, createdAt: pending.createdAt,
            failure: pending.failure, parentId: pending.parentId, alsoSend: pending.alsoSend
        )
    }
}

/// Where a `RoomSession` keeps its unsent text messages and thread replies, so they go after the app
/// was quit. The session saves the whole list for its key each time it changes, and reads it once it
/// knows who you are: at once when `Workspace` made it, else at its room's first welcome. Files
/// aren't kept: one going up when the app quits is lost.
@MainActor public protocol UnsentMessageStore: AnyObject {
    /// What was saved for `key`; empty when nothing was.
    func messages(for key: UnsentMessageKey) -> [UnsentMessage]
    /// Saves `messages` for `key` in place of what was; an empty list forgets the key.
    func save(_ messages: [UnsentMessage], for key: UnsentMessageKey)
    /// Forgets everything saved for `userID` on `server`, in every room, as signing out may.
    func removeAll(server: URL, userID: UserID)
}

/// Unsent messages as a JSON file a room, in a folder of their own (Application Support's
/// `Ember/Unsent` unless given).
@MainActor public final class FileUnsentMessageStore: UnsentMessageStore {
    /// The folder the files are in.
    public let folder: URL

    public init(folder: URL = URL.applicationSupportDirectory.appending(path: "Ember/Unsent", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    public func messages(for key: UnsentMessageKey) -> [UnsentMessage] {
        guard let data = try? Data(contentsOf: file(for: key)) else { return [] }
        return (try? JSONDecoder().decode([UnsentMessage].self, from: data)) ?? []
    }

    public func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) {
        let file = file(for: key)
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func removeAll(server: URL, userID: UserID) {
        let prefix = [server.absoluteString, userID, ""].joined(separator: "\n")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let parts = Self.parts(of: file.deletingPathExtension().lastPathComponent), parts.hasPrefix(prefix) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// One file a key, named for all three parts so no two keys share one.
    private func file(for key: UnsentMessageKey) -> URL {
        let name = Data([key.server.absoluteString, key.userID, key.roomID].joined(separator: "\n").utf8)
            .base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
        return folder.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    /// The three parts a file's name was made of, joined as `file(for:)` joins them.
    private static func parts(of name: String) -> String? {
        var base64 = name.replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Unsent messages in memory, gone with the store: for tests, and for a client that shouldn't
/// write to disk.
@MainActor public final class MemoryUnsentMessageStore: UnsentMessageStore {
    /// What's saved, by key.
    public private(set) var saved: [UnsentMessageKey: [UnsentMessage]] = [:]

    public init() {}

    public func messages(for key: UnsentMessageKey) -> [UnsentMessage] {
        saved[key] ?? []
    }

    public func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) {
        saved[key] = messages.isEmpty ? nil : messages
    }

    public func removeAll(server: URL, userID: UserID) {
        saved = saved.filter { $0.key.server != server || $0.key.userID != userID }
    }
}
