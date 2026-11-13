import CryptoKit
import Foundation
import Synchronization

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
    public var clientMessageId: ClientMessageID
    public var body: String
    public var plainText: String
    public var createdAt: Date
    /// Why it failed, for one that did; it comes back failed, for a retry or a discard.
    public var failure: String?
    /// The message it replies to, for a thread reply; nil for a room message.
    public var parentId: MessageID?
    /// Where a reply goes. Always `.threadOnly` without `parentId`.
    public var delivery: ReplyDelivery

    public init(
        clientMessageId: ClientMessageID, body: String, plainText: String, createdAt: Date, failure: String? = nil,
        parentId: MessageID? = nil, delivery: ReplyDelivery = .threadOnly
    ) {
        self.clientMessageId = clientMessageId
        self.body = body
        self.plainText = plainText
        self.createdAt = createdAt
        self.failure = failure
        self.parentId = parentId
        self.delivery = parentId == nil ? .threadOnly : delivery
    }

    // Saved files keep the shape they had when `delivery` was the Bool `alsoSend`, so files already
    // on disk still read, and a file without the key reads as thread-only.
    private enum CodingKeys: String, CodingKey { case clientMessageId, body, plainText, createdAt, failure, parentId, alsoSend }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let parentId = try container.decodeIfPresent(MessageID.self, forKey: .parentId)
        let alsoSend = try container.decodeIfPresent(Bool.self, forKey: .alsoSend) ?? false
        self.init(
            clientMessageId: try container.decode(ClientMessageID.self, forKey: .clientMessageId),
            body: try container.decode(String.self, forKey: .body),
            plainText: try container.decode(String.self, forKey: .plainText),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            failure: try container.decodeIfPresent(String.self, forKey: .failure),
            parentId: parentId,
            delivery: alsoSend ? .threadAndRoom : .threadOnly
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientMessageId, forKey: .clientMessageId)
        try container.encode(body, forKey: .body)
        try container.encode(plainText, forKey: .plainText)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encode(delivery == .threadAndRoom, forKey: .alsoSend)
    }

    init(_ pending: PendingMessage) {
        self.init(
            clientMessageId: pending.clientMessageId, body: pending.body, plainText: pending.plainText, createdAt: pending.createdAt,
            failure: pending.failure, parentId: pending.parentId, delivery: pending.delivery
        )
    }
}

// MARK: Stores

/// Where a `RoomSession` keeps its unsent text messages and thread replies, so they go after the app
/// was quit. The session hands over the whole list for its key each time it changes, and reads it
/// once it knows who you are: at once when `Workspace` made it, else at its room's first welcome.
/// Files aren't kept: one going up when the app quits is lost.
///
/// One store serves every session on a client, so it keeps each key apart from the others.
///
/// How the SDK calls it:
/// - `messages(for:)` on the main actor, as a session learns who's signed in, since the room's first
///   `message.check` depends on what's pending.
/// - `save(_:for:)` and `removeAll(server:userID:)` off the main actor, one at a time for each store
///   instance, in the order they were asked for. While one runs, only the newest list for a key
///   waits behind it.
///
/// Each method throws rather than answering as if nothing were saved: a session doesn't write over
/// what it couldn't read, and keeps a list it couldn't write to try again. The SDK's stores throw
/// `UnsentStoreError`.
///
/// Forget an account's messages with `discardUnsent(server:userID:)` rather than calling
/// `removeAll(server:userID:)` yourself, so the removal comes after the saves already queued.
///
/// One writer for each key: use one store instance for a folder in a process. Two instances (or
/// two processes) writing the same key each replace its whole list, so the last write wins; neither
/// merges the other's.
public protocol UnsentMessageStore: AnyObject, Sendable {
    /// What was saved for `key`; empty when nothing was.
    func messages(for key: UnsentMessageKey) throws -> [UnsentMessage]
    /// Saves `messages` for `key` in place of what was; an empty list forgets the key.
    func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) throws
    /// Forgets everything saved for `userID` on `server`, in every room.
    func removeAll(server: URL, userID: UserID) throws
}

extension UnsentMessageStore {
    /// Forgets everything saved for `userID` on `server`, in every room, as signing out does, once
    /// the saves already asked of this store are done. A save of theirs still waiting is dropped, so
    /// nothing comes back. Throws what `removeAll(server:userID:)` threw; it's tried again, before
    /// any later save of theirs, at the next retry (a `flushUnsent()`, `Workspace.start()`).
    @MainActor public func discardUnsent(server: URL, userID: UserID) async throws {
        try await UnsentWriter.writer(for: self).discard(server: server, userID: userID)
    }
}

/// Why an `UnsentMessageStore` couldn't read, write or remove.
public struct UnsentStoreError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// The file is there but couldn't be read: protected until the device is first unlocked, or
        /// not permitted. Nothing is written over it. Until it reads, what's unsent in that room is
        /// kept in memory only.
        case unreadable
        /// The file couldn't be read as unsent messages, in whole or in part. A copy is kept in the
        /// store's quarantine.
        case corrupt
        /// Written by a newer SDK, in the version given. It's left as it is and not written over, so
        /// what's unsent in that room is kept in memory only.
        case newerVersion(Int)
        /// The list couldn't be written: no space, not permitted, or the folder isn't there to be made.
        case unwritable
        /// What was saved couldn't all be removed.
        case couldNotRemove
    }

    public var kind: Kind
    /// The file or folder concerned, when there's one.
    public var file: URL?
    /// What the file system (or a custom store) threw.
    public var underlying: (any Error)?
    /// For a `.corrupt` file some of whose messages still read: those. Nil when none could be read
    /// and the file was moved to the quarantine.
    public var recovered: [UnsentMessage]?
    /// How many messages of a `.corrupt` file couldn't be read, when that's known.
    public var lost: Int

    public init(_ kind: Kind, file: URL? = nil, underlying: (any Error)? = nil, recovered: [UnsentMessage]? = nil, lost: Int = 0) {
        self.kind = kind
        self.file = file
        self.underlying = underlying
        self.recovered = recovered
        self.lost = lost
    }

    /// `error` as itself when it's one of these, else as `kind` wrapping it.
    init(_ error: any Error, as kind: Kind) {
        self = error as? UnsentStoreError ?? UnsentStoreError(kind, underlying: error)
    }

    public var description: String {
        var text = "UnsentStoreError.\(kind)"
        if let file { text += " at \(file.path(percentEncoded: false))" }
        if lost > 0 { text += ", \(lost) lost" }
        if let underlying { text += ": \(underlying)" }
        return text
    }
}

/// Whether a session's unsent messages are on disk as they are now.
public enum UnsentState: Equatable, Sendable {
    /// What's unsent is saved (or there's nothing to save).
    case saved
    /// A save is waiting or under way.
    case saving
    /// The latest read or save failed. The session goes on working; it tries again on its next
    /// change, as it starts or comes to the front, and on `flushUnsent()`.
    case failed(UnsentStoreError)

    public static func == (lhs: UnsentState, rhs: UnsentState) -> Bool {
        switch (lhs, rhs) {
        case (.saved, .saved), (.saving, .saving): true
        case let (.failed(a), .failed(b)): a.kind == b.kind && a.file == b.file
        default: false
        }
    }
}

/// Unsent messages as a JSON file a room, in a folder of their own (Application Support's
/// `Ember/Unsent` unless given):
///
///     <folder>/<hash of server and user>/<hash of room>.json
///     <folder>/<hash of server and user>/Quarantine/<time>-<id>.json
///
/// Each hash is the SHA-256, in lowercase hex, of its parts' UTF-8, each part after its length as
/// 8 bytes big-endian, so names have a fixed length whatever the ids are. A file holds
/// `{"version":1,"key":{"server":…,"userID":…,"roomID":…},"messages":[…]}`, and is read only for
/// the key it names. Files written by builds before this format, named by the Base64 of the key at
/// the folder's top, are still read while there's no file in this format for their key. They're left
/// as they are by a read; the next save for the key writes this format and deletes the old file.
/// An old file that can't be deleted stays, shadowed by the new one (an empty list then writes an
/// empty file rather than removing it), and is tried again at each save.
///
/// A file that can't be read at all is moved to the quarantine and the read throws `.corrupt`. One
/// some of whose messages can't be read is copied there (unless the newest copy there is the same),
/// and the read throws `.corrupt` with the others in `recovered`. A file of a newer version is left alone. Only the newest
/// `quarantineLimit` files are kept for each person on each server.
///
/// Files are written atomically, protected until the device is first unlocked, and the folder is
/// left out of backups unless `includedInBackup`: a backup restored weeks later shouldn't bring
/// back messages that were never sent and send them then.
public final class FileUnsentMessageStore: UnsentMessageStore {
    /// The version of the files this SDK writes.
    public static let version = 1
    /// How many quarantined files are kept for each person on each server.
    public static let quarantineLimit = 5
    /// Where files go when no folder is given.
    public static let defaultFolder = URL.applicationSupportDirectory.appending(path: "Ember/Unsent", directoryHint: .isDirectory)
    /// The store in `defaultFolder`, left out of backups, which `EmberEnvironment.system()` uses:
    /// one for the process, so its files have one writer.
    public static let shared = FileUnsentMessageStore()

    /// The folder the files are in.
    public let folder: URL
    /// Whether the folder is backed up. It's set on the folder the first time this instance finds
    /// it, whoever made it.
    public let includedInBackup: Bool
    /// Whether the folder has been marked for backup as `includedInBackup` says.
    private let backupMarked = Mutex(false)

    public init(folder: URL = FileUnsentMessageStore.defaultFolder, includedInBackup: Bool = false) {
        self.folder = folder
        self.includedInBackup = includedInBackup
    }

    // MARK: Where

    /// The folder for `userID` on `server`, which `removeAll(server:userID:)` removes.
    public func directory(server: URL, userID: UserID) -> URL {
        folder.appending(path: Self.hashedName([server.absoluteString, userID.rawValue]), directoryHint: .isDirectory)
    }

    /// The file for `key`.
    public func fileURL(for key: UnsentMessageKey) -> URL {
        directory(server: key.server, userID: key.userID)
            .appending(path: Self.hashedName([key.roomID.rawValue]) + ".json", directoryHint: .notDirectory)
    }

    /// Where unreadable files for `userID` on `server` are kept.
    public func quarantine(server: URL, userID: UserID) -> URL {
        directory(server: server, userID: userID).appending(path: "Quarantine", directoryHint: .isDirectory)
    }

    /// The SHA-256, in lowercase hex, of each part's UTF-8 after its length as 8 bytes big-endian.
    static func hashedName(_ parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading

    public func messages(for key: UnsentMessageKey) throws -> [UnsentMessage] {
        markForBackup()
        let file = fileURL(for: key)
        guard let data = try contents(of: file) else { return try legacyMessages(for: key) }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw quarantine(file, of: key, moving: true, underlying: nil)
        }
        if header.version > Self.version {
            throw UnsentStoreError(.newerVersion(header.version), file: file)
        }
        let envelope: Envelope<Lossy>
        do {
            envelope = try decoder.decode(Envelope<Lossy>.self, from: data)
        } catch {
            throw quarantine(file, of: key, moving: true, underlying: error)
        }
        guard header.version == Self.version, envelope.key == StoredKey(key) else {
            throw quarantine(file, of: key, moving: true, underlying: nil)
        }
        return try recovered(envelope.messages, file: file, of: key)
    }

    /// The messages that read, or, when some didn't, a `.corrupt` error with them, `file` copied to
    /// the quarantine.
    private func recovered(_ rows: [Lossy], file: URL, of key: UnsentMessageKey) throws -> [UnsentMessage] {
        let messages = rows.compactMap(\.message)
        let lost = rows.count - messages.count
        guard lost == 0 else { throw quarantine(file, of: key, moving: false, recovered: messages, lost: lost) }
        return messages
    }

    /// A file in the format before this one, named by the Base64 of the key, read when there's no
    /// file in this format. It's left as it is: the next save writes this format and deletes it.
    private func legacyMessages(for key: UnsentMessageKey) throws -> [UnsentMessage] {
        guard let file = legacyFileURL(for: key), let data = try contents(of: file) else { return [] }
        let rows: [Lossy]
        do {
            rows = try JSONDecoder().decode([Lossy].self, from: data)
        } catch {
            throw quarantine(file, of: key, moving: true, underlying: error)
        }
        return try recovered(rows, file: file, of: key)
    }

    /// The bytes of `file`, or nil when there's none.
    private func contents(of file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch where Self.isMissing(error) {
            return nil
        } catch {
            throw UnsentStoreError(.unreadable, file: file, underlying: error)
        }
    }

    /// Moves `file` (or copies it, when `moving` is false) into the quarantine, and answers the
    /// `.corrupt` error to throw. When it can't be kept there, it's left where it is and the answer
    /// is `.unreadable`, so nothing writes over it.
    private func quarantine(
        _ file: URL, of key: UnsentMessageKey, moving: Bool, recovered: [UnsentMessage]? = nil, lost: Int = 0,
        underlying: (any Error)? = nil
    ) -> UnsentStoreError {
        let manager = FileManager.default
        let quarantine = quarantine(server: key.server, userID: key.userID)
        if !moving, isNewestInQuarantine(file, quarantine) {
            // A copy read again before it could be written again: kept once.
            return UnsentStoreError(.corrupt, file: file, underlying: underlying, recovered: recovered, lost: lost)
        }
        do {
            try manager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let millis = Int64(Date().timeIntervalSince1970 * 1000)
            let name = String(format: "%015lld", millis) + "-" + UUID().uuidString.lowercased() + ".json"
            let destination = quarantine.appending(path: name, directoryHint: .notDirectory)
            if moving {
                try manager.moveItem(at: file, to: destination)
            } else {
                try manager.copyItem(at: file, to: destination)
            }
        } catch {
            return UnsentStoreError(.unreadable, file: file, underlying: error)
        }
        // Older copies only: failing to trim them loses nothing.
        if let kept = try? manager.contentsOfDirectory(atPath: quarantine.path(percentEncoded: false)) {
            for name in kept.sorted(by: >).dropFirst(Self.quarantineLimit) {
                try? manager.removeItem(at: quarantine.appending(path: name, directoryHint: .notDirectory))
            }
        }
        return UnsentStoreError(.corrupt, file: file, underlying: underlying, recovered: recovered, lost: lost)
    }

    /// Whether the newest file in `quarantine` has the same bytes as `file`.
    private func isNewestInQuarantine(_ file: URL, _ quarantine: URL) -> Bool {
        guard let newest = try? FileManager.default.contentsOfDirectory(atPath: quarantine.path(percentEncoded: false)).max(),
              let kept = try? Data(contentsOf: quarantine.appending(path: newest, directoryHint: .notDirectory)),
              let data = try? Data(contentsOf: file)
        else { return false }
        return kept == data
    }

    // MARK: Writing

    public func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) throws {
        let file = fileURL(for: key)
        let legacy = legacyFileURL(for: key)
        if messages.isEmpty {
            // A file in the old format would be read again once this one is gone, so while it
            // can't be deleted, an empty file stays in its way.
            if let legacy, (try? remove(legacy)) == nil {
                try write([], to: file, for: key)
            } else {
                try remove(file)
            }
        } else {
            try write(messages, to: file, for: key)
            // The new file is read in its place, so one that can't be deleted now is tried again
            // at the next save.
            if let legacy { try? remove(legacy) }
        }
    }

    private func write(_ messages: [UnsentMessage], to file: URL, for key: UnsentMessageKey) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(Envelope(version: Self.version, key: StoredKey(key), messages: messages))
        } catch {
            throw UnsentStoreError(.unwritable, file: file, underlying: error)
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            markForBackup()
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw UnsentStoreError(.unwritable, file: file, underlying: error)
        }
    }

    /// Moves the folder of `userID` on `server` out of the way, then deletes it, and deletes their
    /// files in the old format. Throws `.couldNotRemove` once it has tried them all, should any stay.
    public func removeAll(server: URL, userID: UserID) throws {
        markForBackup()
        let manager = FileManager.default
        var failure: UnsentStoreError?
        let directory = directory(server: server, userID: userID)
        let trash = folder.appending(path: ".trash", directoryHint: .isDirectory)
        if manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            do {
                try manager.createDirectory(at: trash, withIntermediateDirectories: true)
                try manager.moveItem(at: directory, to: trash.appending(path: UUID().uuidString, directoryHint: .isDirectory))
            } catch {
                failure = UnsentStoreError(.couldNotRemove, file: directory, underlying: error)
            }
        }
        let prefix = [server.absoluteString, userID.rawValue, ""].joined(separator: "\n")
        do {
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let parts = Self.legacyParts(of: file.deletingPathExtension().lastPathComponent), parts.hasPrefix(prefix) else { continue }
                do { try remove(file) } catch { failure = failure ?? UnsentStoreError(error, as: .couldNotRemove) }
            }
        } catch where Self.isMissing(error) {
            // No folder, so nothing in it.
        } catch {
            failure = failure ?? UnsentStoreError(.couldNotRemove, file: folder, underlying: error)
        }
        // What was moved aside is out of every read's way; one left now goes with the next removal.
        if manager.fileExists(atPath: trash.path(percentEncoded: false)) { try? manager.removeItem(at: trash) }
        if let failure { throw failure }
    }

    private func remove(_ file: URL) throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch where Self.isMissing(error) {
            // Already gone.
        } catch {
            throw UnsentStoreError(.couldNotRemove, file: file, underlying: error)
        }
    }

    /// Leaves the folder out of backups (or not), the first time it's found. Until it's there it
    /// can't be marked, so it's tried again each time.
    private func markForBackup() {
        backupMarked.withLock { marked in
            guard !marked else { return }
            var folder = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = !includedInBackup
            marked = (try? folder.setResourceValues(values)) != nil
        }
    }

    static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(ENOENT), Int(ENOTDIR)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(underlying.code)
        }
        return false
    }

    // MARK: The format before this one

    /// One file a key at the folder's top, named for all three parts. Nil for a key whose name is
    /// too long for a file, which could never have been written.
    func legacyFileURL(for key: UnsentMessageKey) -> URL? {
        let name = Data([key.server.absoluteString, key.userID.rawValue, key.roomID.rawValue].joined(separator: "\n").utf8)
            .base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
        guard name.utf8.count + 5 <= 255 else { return nil }
        return folder.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    /// The three parts an old file's name was made of, joined as `legacyFileURL(for:)` joins them.
    private static func legacyParts(of name: String) -> String? {
        var base64 = name.replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: The format

    private struct Header: Decodable {
        var version: Int
    }

    private struct StoredKey: Codable, Equatable {
        var server: String
        var userID: String
        var roomID: String

        init(_ key: UnsentMessageKey) {
            server = key.server.absoluteString
            userID = key.userID.rawValue
            roomID = key.roomID.rawValue
        }
    }

    private struct Envelope<Message: Codable>: Codable {
        var version: Int
        var key: StoredKey
        var messages: [Message]
    }

    /// A message, or nil for one that doesn't read, so the others still do.
    private struct Lossy: Codable {
        var message: UnsentMessage?

        init(from decoder: any Decoder) throws {
            message = try? UnsentMessage(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try message.encode(to: encoder)
        }
    }
}

/// Unsent messages in memory, gone with the store: for tests, and for a client that shouldn't
/// write to disk. Safe from any thread. Tests can make its reads, writes or removals fail.
public final class MemoryUnsentMessageStore: UnsentMessageStore {
    private struct State {
        var saved: [UnsentMessageKey: [UnsentMessage]] = [:]
        var failsReads = false
        var failsWrites = false
        var failsRemovals = false
    }

    private let state = Mutex(State())

    public init() {}

    /// What's saved, by key.
    public var saved: [UnsentMessageKey: [UnsentMessage]] {
        state.withLock { $0.saved }
    }

    /// Whether `messages(for:)` throws `.unreadable`.
    public var failsReads: Bool {
        get { state.withLock { $0.failsReads } }
        set { state.withLock { $0.failsReads = newValue } }
    }

    /// Whether `save(_:for:)` throws `.unwritable`, leaving what was saved.
    public var failsWrites: Bool {
        get { state.withLock { $0.failsWrites } }
        set { state.withLock { $0.failsWrites = newValue } }
    }

    /// Whether `removeAll(server:userID:)` throws `.couldNotRemove`, leaving what was saved.
    public var failsRemovals: Bool {
        get { state.withLock { $0.failsRemovals } }
        set { state.withLock { $0.failsRemovals = newValue } }
    }

    public func messages(for key: UnsentMessageKey) throws -> [UnsentMessage] {
        try state.withLock { state in
            if state.failsReads { throw UnsentStoreError(.unreadable, underlying: CocoaError(.fileReadNoPermission)) }
            return state.saved[key] ?? []
        }
    }

    public func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) throws {
        try state.withLock { state in
            if state.failsWrites { throw UnsentStoreError(.unwritable, underlying: CocoaError(.fileWriteOutOfSpace)) }
            state.saved[key] = messages.isEmpty ? nil : messages
        }
    }

    public func removeAll(server: URL, userID: UserID) throws {
        try state.withLock { state in
            if state.failsRemovals { throw UnsentStoreError(.couldNotRemove, underlying: CocoaError(.fileWriteNoPermission)) }
            state.saved = state.saved.filter { $0.key.server != server || $0.key.userID != userID }
        }
    }
}
