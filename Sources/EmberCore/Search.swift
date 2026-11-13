import Foundation

// A port of packages/protocol/src/search.ts.

extension Limits {
    /// The most characters a search's words may have (`MAX_SEARCH_LENGTH`).
    public static let search = 1000
    /// How many matches a page of results holds (`SEARCH_LIMIT`).
    public static let searchPage = 100
    /// How many recent searches the server keeps for someone (`RECENT_SEARCHES`).
    public static let recentSearches = 10
}

/// A search: its words, and the filters that narrow it.
public struct SearchQuery: Codable, Hashable, Sendable {
    public var q: String
    /// Only this room's messages. The wire calls it `in`.
    public var roomID: RoomID?
    /// Only this person's messages.
    public var from: UserID?
    /// Only messages mentioning me, or in my DMs.
    public var withMe: Bool
    /// Only messages with a link.
    public var hasLink: Bool
    /// Only messages with a file.
    public var hasFile: Bool
    /// Only replies in threads.
    public var inThread: Bool

    /// A search for `text`, with no filters. Add them with the modifiers below, each of which
    /// answers a copy: `SearchQuery("launch").inRoom(roomID).from(userID)`.
    public init(_ text: String = "") {
        q = text
        roomID = nil
        from = nil
        withMe = false
        hasLink = false
        hasFile = false
        inThread = false
    }

    /// Narrowed to messages in the room `roomID`.
    public func inRoom(_ roomID: RoomID) -> SearchQuery { changed { $0.roomID = roomID } }

    /// Narrowed to messages written by `userID`.
    public func from(_ userID: UserID) -> SearchQuery { changed { $0.from = userID } }

    /// Narrowed to messages that mention me, or are in my DMs.
    public func involvingMe() -> SearchQuery { changed { $0.withMe = true } }

    /// Narrowed to messages with a link in them.
    public func havingLinks() -> SearchQuery { changed { $0.hasLink = true } }

    /// Narrowed to messages with a file attached.
    public func havingFiles() -> SearchQuery { changed { $0.hasFile = true } }

    /// Narrowed to replies in threads.
    public func inThreads() -> SearchQuery { changed { $0.inThread = true } }

    private func changed(_ change: (inout SearchQuery) -> Void) -> SearchQuery {
        var copy = self
        change(&copy)
        return copy
    }

    /// Whether any filter is set, which makes a search worth running without words.
    public var hasFilters: Bool {
        roomID != nil || from != nil || withMe || hasLink || hasFile || inThread
    }

    /// Whether it can find anything: a word, or a filter. Punctuation and emoji alone find nothing,
    /// since the index only holds words.
    public var isSearchable: Bool { Self.hasWords(q) || hasFilters }

    /// Whether `text` has a character the index treats as part of a word, as the web's `\w` with
    /// the `v` flag counts them.
    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let p = scalar.properties
            if p.isAlphabetic || p.isJoinControl { return true }
            switch p.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
            default: return false
            }
        }
    }

    /// The query string of GET /api/searches, as `searchQuery` writes it (no leading `?`). Spaces
    /// are `+`, as a form writes them.
    package func queryString(sort: SearchSort = .newest, cursor: Int? = nil) -> String {
        var pairs: [(String, String)] = [("q", q)]
        if let roomID { pairs.append(("in", roomID.rawValue)) }
        if let from { pairs.append(("from", from.rawValue)) }
        if withMe { pairs.append(("with", "me")) }
        if hasLink { pairs.append(("has", "link")) }
        if hasFile { pairs.append(("has", "file")) }
        if inThread { pairs.append(("is", "thread")) }
        if sort != .newest { pairs.append(("sort", sort.rawValue)) }
        if let cursor { pairs.append(("cursor", String(cursor))) }
        return pairs
            .map { "\(Self.formEncoded($0.0))=\(Self.formEncoded($0.1))" }
            .joined(separator: "&")
    }

    private static func formEncoded(_ value: String) -> String {
        encodeURIComponent(value).replacingOccurrences(of: "%20", with: "+")
    }

    /// The body of POST /api/searches, which saves the search among the recent ones.
    package func body(sort: SearchSort = .newest) -> SearchBody { SearchBody(self, sort: sort) }

    private enum CodingKeys: String, CodingKey {
        case q, roomID = "in", from, withMe, hasLink, hasFile, inThread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        q = try container.decodeIfPresent(String.self, forKey: .q) ?? ""
        roomID = try container.decodeIfPresent(RoomID.self, forKey: .roomID)
        from = try container.decodeIfPresent(UserID.self, forKey: .from)
        withMe = try container.decodeIfPresent(Bool.self, forKey: .withMe) ?? false
        hasLink = try container.decodeIfPresent(Bool.self, forKey: .hasLink) ?? false
        hasFile = try container.decodeIfPresent(Bool.self, forKey: .hasFile) ?? false
        inThread = try container.decodeIfPresent(Bool.self, forKey: .inThread) ?? false
    }

    /// Flags are `true` or absent on the wire, never `false`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(q, forKey: .q)
        try container.encodeIfPresent(roomID, forKey: .roomID)
        try container.encodeIfPresent(from, forKey: .from)
        if withMe { try container.encode(true, forKey: .withMe) }
        if hasLink { try container.encode(true, forKey: .hasLink) }
        if hasFile { try container.encode(true, forKey: .hasFile) }
        if inThread { try container.encode(true, forKey: .inThread) }
    }
}

/// Whether running a search keeps it among the person's recent searches.
public enum SearchHistory: Sendable, Hashable {
    /// Saves the search in the person's recent searches on the server, as one they typed is.
    case record
    /// Runs the search without saving it: a further page, a retry, or a search the app made itself.
    case skip
}

/// The order of a search's matches.
public enum SearchSort: String, Codable, Sendable {
    case newest, oldest
}

/// What POST /api/searches takes: the search, and its order when that isn't newest first.
package struct SearchBody: Encodable, Hashable, Sendable {
    package var query: SearchQuery
    package var sort: SearchSort

    package init(_ query: SearchQuery, sort: SearchSort = .newest) {
        self.query = query
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey { case sort }

    package func encode(to encoder: Encoder) throws {
        try query.encode(to: encoder)
        if sort != .newest {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sort, forKey: .sort)
        }
    }
}

/// A message a search found, and the words in it to highlight.
public struct SearchMatch: Decodable, Hashable, Identifiable, Sendable {
    public var message: Message
    public var words: [String]
    public var id: MessageID { message.id }

    public init(message: Message, words: [String] = []) {
        self.message = message
        self.words = words
    }

    private enum CodingKeys: String, CodingKey { case message, words }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(Message.self, forKey: .message)
        words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
    }
}

/// A page of a search's results, as GET /api/searches answers.
public struct SearchResults: Decodable, Sendable {
    /// The search as the server understood it, or nil when there wasn't one to run.
    public var search: SearchQuery?
    public var matches: [SearchMatch]
    /// The cursor for the next page, or nil on the last.
    public var next: Int?
    /// The rooms the matches are in, to name them.
    public var rooms: [Room]
    /// Their recent searches, latest first.
    public var recent: [SearchQuery]

    public init(search: SearchQuery? = nil, matches: [SearchMatch] = [], next: Int? = nil, rooms: [Room] = [], recent: [SearchQuery] = []) {
        self.search = search
        self.matches = matches
        self.next = next
        self.rooms = rooms
        self.recent = recent
    }

    private enum CodingKeys: String, CodingKey { case search, matches, next, rooms, recent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        search = try container.decodeIfPresent(SearchQuery.self, forKey: .search)
        matches = try container.decodeIfPresent([SearchMatch].self, forKey: .matches) ?? []
        next = try container.decodeIfPresent(Int.self, forKey: .next)
        rooms = try container.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        recent = try container.decodeIfPresent([SearchQuery].self, forKey: .recent) ?? []
    }
}
