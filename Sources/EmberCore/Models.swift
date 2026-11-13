import Foundation

// The shapes Ember's HTTP API and sockets speak, as `packages/protocol` in the
// server's repository declares them. Names follow the protocol's, so a field
// here can be looked up there.

/// An enum the server may grow. A value this build doesn't know decodes as
/// `unknown` with the server's string, rather than failing the whole answer
/// (one new role shouldn't empty the directory) or passing for a value it
/// isn't, and encodes back to that same string. A question asked of an
/// unknown value answers no: it grants nothing and is shown as nothing it isn't.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    /// The values this build knows.
    static var known: [Self] { get }
    static func unknown(_ rawValue: String) -> Self
}

extension OpenEnum {
    /// The known value with this string, or `unknown` keeping it.
    public init(_ rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    /// The known value with this string, or nil.
    public init?(rawValue: String) {
        guard let known = Self.known.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = known
    }

    /// Whether this build knows the value.
    public var isKnown: Bool { Self.known.contains(self) }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - People

public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: UserID
    public var name: String

    public init(id: UserID, name: String) {
        self.id = id
        self.name = name
    }
}

/// The person signed in.
public struct Me: Codable, Hashable, Identifiable, Sendable {
    public var id: UserID
    public var name: String
    public var administrator: Bool

    public init(id: UserID, name: String, administrator: Bool) {
        self.id = id
        self.name = name
        self.administrator = administrator
    }

    public var user: User { User(id: id, name: name) }
}

/// Someone's role. An unknown one is neither an administrator nor a bot.
public enum Role: OpenEnum {
    case member, administrator, bot
    case unknown(String)

    public static let known: [Role] = [.member, .administrator, .bot]

    public var rawValue: String {
        switch self {
        case .member: "member"
        case .administrator: "administrator"
        case .bot: "bot"
        case .unknown(let raw): raw
        }
    }
}

/// Whether someone can take part. An unknown status is not active.
public enum UserStatus: OpenEnum {
    case active, deactivated, banned, suspended
    case unknown(String)

    public static let known: [UserStatus] = [.active, .deactivated, .banned, .suspended]

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .deactivated: "deactivated"
        case .banned: "banned"
        case .suspended: "suspended"
        case .unknown(let raw): raw
        }
    }
}

/// Someone as the people directory lists them (`GET /api/users`).
public struct DirectoryUser: Codable, Hashable, Identifiable, Sendable {
    public var id: UserID
    public var name: String
    public var bio: String?
    public var role: Role
    public var status: UserStatus
    /// A path on the server, `/users/<token>/avatar?v=<version>`. It answers an
    /// SVG of their initials until they upload a picture.
    public var avatarUrl: String

    public init(id: UserID, name: String, bio: String? = nil, role: Role = .member, status: UserStatus = .active, avatarUrl: String) {
        self.id = id
        self.name = name
        self.bio = bio
        self.role = role
        self.status = status
        self.avatarUrl = avatarUrl
    }
}

public struct Directory: Codable, Sendable {
    public var users: [DirectoryUser]
}

/// The assistant, which is a person in the directory with this id.
public enum Assistant {
    public static let id: UserID = "ember"
    public static let name = "Ember"
}

// MARK: - Rooms

/// A room's kind. An unknown kind is neither open to everyone nor direct.
public enum RoomKind: OpenEnum {
    case open, closed, direct
    case unknown(String)

    public static let known: [RoomKind] = [.open, .closed, .direct]

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        case .direct: "direct"
        case .unknown(let raw): raw
        }
    }
}

/// A room of any kind. A shared room (`open` or `closed`) has a `name` and an
/// `icon`; a direct one has `members`, the reader among them, and `activeAt`.
public struct Room: Codable, Hashable, Identifiable, Sendable {
    public var id: RoomID
    public var kind: RoomKind
    public var name: String?
    /// A Lucide or Iconoir icon's name, or nil for the default `#`.
    public var icon: String?
    public var members: [User]?
    public var activeAt: Date?

    public init(id: RoomID, kind: RoomKind, name: String? = nil, icon: String? = nil, members: [User]? = nil, activeAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.icon = icon
        self.members = members
        self.activeAt = activeAt
    }

    public var isDirect: Bool { kind == .direct }
}

/// How much of a room reaches someone, from most rooms' starting level down
/// to a room hidden from their sidebar. An unknown level neither hides the
/// room nor turns its notifications off; `allCases` lists the known levels.
public enum Involvement: OpenEnum, CaseIterable {
    case mentions, everything, nothing, invisible
    case unknown(String)

    public static let known: [Involvement] = [.mentions, .everything, .nothing, .invisible]
    public static var allCases: [Involvement] { known }

    public var rawValue: String {
        switch self {
        case .mentions: "mentions"
        case .everything: "everything"
        case .nothing: "nothing"
        case .invisible: "invisible"
        case .unknown(let raw): raw
        }
    }

    /// The level a room starts at: everything in a DM, mentions elsewhere.
    public static func starting(for kind: RoomKind) -> Involvement {
        kind == .direct ? .everything : .mentions
    }
}

/// A room as someone's sidebar lists it: the room, flattened, with whether
/// it's unread and their level in it.
public struct SidebarRoom: Decodable, Hashable, Identifiable, Sendable {
    public var room: Room
    public var unread: Bool
    public var involvement: Involvement

    public var id: RoomID { room.id }

    public init(room: Room, unread: Bool = false, involvement: Involvement? = nil) {
        self.room = room
        self.unread = unread
        self.involvement = involvement ?? .starting(for: room.kind)
    }

    private enum CodingKeys: String, CodingKey { case unread, involvement }

    public init(from decoder: Decoder) throws {
        room = try Room(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        involvement = try container.decodeIfPresent(Involvement.self, forKey: .involvement) ?? .starting(for: room.kind)
    }
}

public struct Favorites: Codable, Hashable, Sendable {
    public var rooms: [RoomID]
    public var version: Int

    public init(rooms: [RoomID] = [], version: Int = 0) {
        self.rooms = rooms
        self.version = version
    }
}

public struct Invitation: Codable, Hashable, Sendable {
    public var roomId: RoomID
    public var joinCode: String
}

/// `GET /api/sidebar`.
public struct Sidebar: Decodable, Sendable {
    public var rooms: [SidebarRoom]
    public var favorites: Favorites
    public var sharedOrder: [RoomID]
    public var invitation: Invitation?
    public var suggestions: [User]

    private enum CodingKeys: String, CodingKey { case rooms, favorites, sharedOrder, invitation, suggestions }

    /// A sidebar as given, for tests and previews.
    public init(rooms: [SidebarRoom] = [], favorites: Favorites = Favorites(), sharedOrder: [RoomID] = [], invitation: Invitation? = nil, suggestions: [User] = []) {
        self.rooms = rooms
        self.favorites = favorites
        self.sharedOrder = sharedOrder
        self.invitation = invitation
        self.suggestions = suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try container.decode([SidebarRoom].self, forKey: .rooms)
        favorites = try container.decodeIfPresent(Favorites.self, forKey: .favorites) ?? Favorites()
        sharedOrder = try container.decodeIfPresent([RoomID].self, forKey: .sharedOrder) ?? []
        invitation = try container.decodeIfPresent(Invitation.self, forKey: .invitation)
        suggestions = try container.decodeIfPresent([User].self, forKey: .suggestions) ?? []
    }
}

/// `POST /api/directs`: the DM with exactly these people and the sender.
package struct NewDirect: Encodable, Sendable {
    package var userIds: [UserID]
    package init(userIds: [UserID]) { self.userIds = userIds }
}

package struct StartedDirect: Decodable, Sendable {
    package var room: Room
}

// MARK: - Workspace

/// The workspace: its name, and the switches that change what the app offers.
/// Only what the app reads is decoded, and each field has a default, so a
/// server a version ahead or behind still signs in.
public struct Account: Decodable, Hashable, Sendable {
    public var name: String
    public var tagline: String
    public var logo: String?
    public var customDomain: String?
    public var restrictRoomCreation: Bool
    public var hideTranslationButtons: Bool

    public init(name: String, tagline: String = "", logo: String? = nil, customDomain: String? = nil, restrictRoomCreation: Bool = false, hideTranslationButtons: Bool = false) {
        self.name = name
        self.tagline = tagline
        self.logo = logo
        self.customDomain = customDomain
        self.restrictRoomCreation = restrictRoomCreation
        self.hideTranslationButtons = hideTranslationButtons
    }

    private enum CodingKeys: String, CodingKey {
        case name, tagline, logo, customDomain, restrictRoomCreation, hideTranslationButtons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        customDomain = try container.decodeIfPresent(String.self, forKey: .customDomain)
        restrictRoomCreation = try container.decodeIfPresent(Bool.self, forKey: .restrictRoomCreation) ?? false
        hideTranslationButtons = try container.decodeIfPresent(Bool.self, forKey: .hideTranslationButtons) ?? false
    }
}

/// `GET /api/bootstrap`: what the app needs before anyone signs in.
public struct Bootstrap: Decodable, Sendable {
    /// An unknown setup state is not pending, so the app never offers to set up a workspace it can't read.
    public enum Setup: OpenEnum {
        case pending, complete
        case unknown(String)

        public static let known: [Setup] = [.pending, .complete]

        public var rawValue: String {
            switch self {
            case .pending: "pending"
            case .complete: "complete"
            case .unknown(let raw): raw
            }
        }
    }

    /// Whether anyone has set the workspace up yet.
    public var setup: Setup
    /// Whether signing in with just a name is on, as a local `pnpm dev` has it.
    public var guestSignIn: Bool
    public var signInWithMemberful: Bool
    /// The Cloudflare Turnstile site key the reset-code and sign-up forms check with, or nil when
    /// they don't. When it's set, `EmberClient.askForPasswordReset` needs a token made with it.
    public var turnstileSiteKey: String?
    /// Whether Ember can email a code to reset a password.
    public var passwordResetCodes: Bool
    public var account: Account
    public var version: String
    public var user: Me?

    private enum CodingKeys: String, CodingKey {
        case setup, guestSignIn, signInWithMemberful, turnstileSiteKey, passwordResetCodes, account, version, user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = try container.decodeIfPresent(Setup.self, forKey: .setup) ?? .complete
        guestSignIn = try container.decodeIfPresent(Bool.self, forKey: .guestSignIn) ?? false
        signInWithMemberful = try container.decodeIfPresent(Bool.self, forKey: .signInWithMemberful) ?? false
        turnstileSiteKey = try container.decodeIfPresent(String.self, forKey: .turnstileSiteKey)
        passwordResetCodes = try container.decodeIfPresent(Bool.self, forKey: .passwordResetCodes) ?? false
        account = try container.decode(Account.self, forKey: .account)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        user = try container.decodeIfPresent(Me.self, forKey: .user)
    }
}

/// `POST /api/session` with an email address and password.
package struct PasswordSignIn: Encodable, Sendable {
    package var emailAddress: String
    package var password: String
}

/// `POST /api/session` with just a name, where `Bootstrap.guestSignIn` allows.
package struct GuestSignIn: Encodable, Sendable {
    package var name: String
}

/// What signing in answers, and `GET /api/me`.
package struct SignedIn: Decodable, Sendable {
    package var user: Me
}

// MARK: - Messages

/// A short reaction someone left on a message: an emoji, or up to `Limits.boost` characters of text.
public struct Boost: Codable, Hashable, Identifiable, Sendable {
    public var id: BoostID
    public var messageId: MessageID
    public var booster: User
    public var content: String
    public var createdAt: Date

    public init(id: BoostID, messageId: MessageID, booster: User, content: String, createdAt: Date) {
        self.id = id
        self.messageId = messageId
        self.booster = booster
        self.content = content
        self.createdAt = createdAt
    }
}

/// A thread under a message, as the room's timeline shows it.
public struct ThreadSummary: Codable, Hashable, Sendable {
    public var count: Int
    public var latestAt: Date
    /// Up to four of the people who replied.
    public var people: [User]
}

/// A file message's file. `url`, `downloadUrl` and `previewUrl` are signed
/// paths on the server that need no cookie and don't expire.
public struct StoredFile: Codable, Hashable, Identifiable, Sendable {
    public var id: FileID
    public var name: String
    public var contentType: String
    public var byteSize: Int
    public var width: Int?
    public var height: Int?
    public var url: String
    public var downloadUrl: String
    public var previewUrl: String?

    /// Whether the message shows the file by a picture: an image's thumbnail
    /// or a video's poster.
    public var isImage: Bool { contentType.hasPrefix("image/") }
    public var isVideo: Bool { contentType.hasPrefix("video") }
}

public struct Message: Codable, Hashable, Identifiable, Sendable {
    public var id: MessageID
    /// The id its sender's app gave it, which matches a message on its way to
    /// the one the room stored.
    public var clientMessageId: ClientMessageID
    public var roomId: RoomID
    public var creator: User
    /// Its body as markup: Action Text's HTML, sanitised by the server.
    public var body: String
    public var plainText: String
    public var mentions: [User]
    public var createdAt: Date
    public var updatedAt: Date
    public var editedAt: Date?
    public var boosts: [Boost]
    public var attachment: StoredFile?
    /// A bot's cards, under its body, or nil for none: those this build can show, read leniently,
    /// as the protocol's `parseCards` reads them.
    public var cards: [Card]?
    /// The message this one replies to, in its thread.
    public var parentId: MessageID?
    /// Whether a reply was sent to the room too.
    public var alsoSent: Bool?
    public var parentText: String?
    public var thread: ThreadSummary?
    public var deleted: Bool?

    /// Whether the room's own timeline lists it: not a reply, or a reply also
    /// sent to the room.
    public var isInRoom: Bool { parentId == nil || alsoSent == true }
    public var isDeleted: Bool { deleted == true }

    private enum CodingKeys: String, CodingKey {
        case id, clientMessageId, roomId, creator, body, plainText, mentions, createdAt, updatedAt, editedAt
        case boosts, attachment, cards, parentId, alsoSent, parentText, thread, deleted
    }

    public init(
        id: MessageID, clientMessageId: ClientMessageID, roomId: RoomID, creator: User, body: String, plainText: String,
        mentions: [User] = [], createdAt: Date, updatedAt: Date? = nil, editedAt: Date? = nil, boosts: [Boost] = [],
        attachment: StoredFile? = nil, cards: [Card]? = nil, parentId: MessageID? = nil, alsoSent: Bool? = nil,
        thread: ThreadSummary? = nil
    ) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.roomId = roomId
        self.creator = creator
        self.body = body
        self.plainText = plainText
        self.mentions = mentions
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.editedAt = editedAt
        self.boosts = boosts
        self.attachment = attachment
        self.cards = cards
        self.parentId = parentId
        self.alsoSent = alsoSent
        self.thread = thread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MessageID.self, forKey: .id)
        // A message from before client ids had none, and is matched by its own id.
        clientMessageId = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageId) ?? ClientMessageID(id.rawValue)
        roomId = try container.decode(RoomID.self, forKey: .roomId)
        creator = try container.decode(User.self, forKey: .creator)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        parentId = try container.decodeIfPresent(MessageID.self, forKey: .parentId)
        // Past what places it, a part this build can't read is left out and the message kept.
        body = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? ""
        plainText = (try? container.decodeIfPresent(String.self, forKey: .plainText)) ?? ""
        mentions = (try? container.decodeIfPresent(Lossy<User>.self, forKey: .mentions))?.elements ?? []
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        editedAt = try? container.decodeIfPresent(Date.self, forKey: .editedAt)
        boosts = (try? container.decodeIfPresent(Lossy<Boost>.self, forKey: .boosts))?.elements ?? []
        attachment = try? container.decodeIfPresent(StoredFile.self, forKey: .attachment)
        cards = Card.list((try? container.decodeIfPresent(JSONValue.self, forKey: .cards)) ?? nil)
        alsoSent = try? container.decodeIfPresent(Bool.self, forKey: .alsoSent)
        parentText = try? container.decodeIfPresent(String.self, forKey: .parentText)
        thread = try? container.decodeIfPresent(ThreadSummary.self, forKey: .thread)
        deleted = try? container.decodeIfPresent(Bool.self, forKey: .deleted)
    }
}

/// The reactions the app offers; anything up to `Limits.boost` characters can
/// be typed instead.
public enum Reactions {
    public static let all = ["👍", "👏", "👋", "💪", "❤️", "😂", "🎉", "🔥"]
    public static let quickCount = 3
}

public enum Limits {
    /// The longest message, in UTF-16 code units of its text.
    public static let message = 10_000
    /// The longest boost, in UTF-16 code units once trimmed, as the server counts it.
    public static let boost = 16
    public static let historyPage = 40
    public static let checkedMessages = 50
    public static let roomName = 100
    public static let userName = 100
    public static let bio = 200

    /// Whether the room takes `text` as a boost: something left once trimmed, and no more than
    /// `boost` UTF-16 code units of it. A longer one would be refused whole.
    public static func boostFits(_ text: String) -> Bool {
        let trimmed = trimmedBoost(text)
        return !trimmed.isEmpty && trimmed.utf16.count <= boost
    }

    /// `text` with whole characters dropped from its end until it's no more than `boost` UTF-16 code
    /// units, so an emoji is never cut in half. It doesn't trim, so it can run on every keystroke.
    public static func clampedBoost(_ text: String) -> String {
        var clamped = Substring(text)
        while clamped.utf16.count > boost { clamped = clamped.dropLast() }
        return String(clamped)
    }

    /// `text` trimmed as the server trims it, of the whitespace JavaScript's `trim()` drops.
    public static func trimmedBoost(_ text: String) -> String {
        text.trimmingCharacters(in: jsWhitespace)
    }

    private static let jsWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
}

// MARK: - Loose JSON

/// A list read one element at a time, leaving out any this build can't read.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(JSONValue.self)
            }
        }
        self.elements = elements
    }
}

/// JSON the app carries without reading yet.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
