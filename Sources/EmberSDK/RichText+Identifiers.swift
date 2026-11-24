import EmberRichText

// EmberRichText knows nothing of EmberCore, so its mentions carry a user's or a room's id, or a
// special mention's name, as a String. These take and give a `UserID`, a `RoomID` and a
// `SpecialMention` instead.

extension ComposeSegment {
    /// A mention of `userID`, showing `name` in the composer.
    public static func mention(_ userID: UserID, name: String) -> ComposeSegment {
        .mention(userId: userID.rawValue, name: name)
    }

    /// "@here", "@channel" or "@everyone".
    public static func specialMention(_ mention: SpecialMention) -> ComposeSegment {
        .specialMention(mention.rawValue)
    }

    /// A mention of the room `roomID`, showing `name` in the composer.
    public static func roomMention(_ roomID: RoomID, name: String) -> ComposeSegment {
        .roomMention(roomId: roomID.rawValue, name: name)
    }

    /// Who a mention is of; nil for anything else.
    public var userID: UserID? {
        if case let .mention(userId, _) = self { UserID(userId) } else { nil }
    }

    /// Which special mention this is; nil for anything else.
    public var special: SpecialMention? {
        if case let .specialMention(name) = self { SpecialMention(name) } else { nil }
    }

    /// Which room a room mention is of; nil for anything else.
    public var roomID: RoomID? {
        if case let .roomMention(roomId, _) = self { RoomID(roomId) } else { nil }
    }
}

extension RichInline {
    /// Who a mention read out of a body is of; nil for anything else.
    public var userID: UserID? {
        if case let .mention(userId) = self { UserID(userId) } else { nil }
    }

    /// Which special mention read out of a body this is; nil for anything else.
    public var special: SpecialMention? {
        if case let .specialMention(name) = self { SpecialMention(name) } else { nil }
    }

    /// Which room a room mention read out of a body is of; nil for anything else.
    public var roomID: RoomID? {
        if case let .roomMention(roomId) = self { RoomID(roomId) } else { nil }
    }
}

extension RichText {
    /// `segments(_:mentions:specialMentions:rooms:)`, with each person chosen by their `UserID`, each
    /// special mention chosen as a `SpecialMention`, and each room by its `RoomID`.
    public static func segments(
        _ text: String, mentions: [UserID: String], specialMentions: [SpecialMention] = [], rooms: [RoomID: String] = [:]
    ) -> [ComposeSegment] {
        segments(text, mentions: plain(mentions), specialMentions: specialMentions.map(\.rawValue), rooms: plain(rooms))
    }

    /// `mentionRanges(in:mentions:specialMentions:rooms:)`, with each person chosen by their `UserID`,
    /// each special mention chosen as a `SpecialMention`, and each room by its `RoomID`.
    public static func mentionRanges(
        in text: String, mentions: [UserID: String], specialMentions: [SpecialMention] = [], rooms: [RoomID: String] = [:]
    ) -> [Range<String.Index>] {
        mentionRanges(in: text, mentions: plain(mentions), specialMentions: specialMentions.map(\.rawValue), rooms: plain(rooms))
    }

    /// The special mentions `segments` make, each once, for `NotifiedCounts.notifying(_:)`.
    public static func specialMentions(in segments: [ComposeSegment]) -> [SpecialMention] {
        var made: [SpecialMention] = []
        for mention in segments.compactMap(\.special) where mention.isKnown && !made.contains(mention) { made.append(mention) }
        return made
    }
}

extension EditableBody {
    /// `init(body:mentionNames:roomNames:)`, with each name keyed by the person's `UserID` or the
    /// room's `RoomID`.
    public init(body: String, mentionNames: [UserID: String], roomNames: [RoomID: String] = [:]) {
        self.init(body: body, mentionNames: plain(mentionNames), roomNames: plain(roomNames))
    }

    /// `body(editedTo:mentions:)`, with each person chosen by their `UserID`.
    public func body(editedTo newText: String, mentions: [UserID: String]) -> String {
        body(editedTo: newText, mentions: plain(mentions))
    }
}

private func plain<ID: EmberIdentifier>(_ names: [ID: String]) -> [String: String] {
    Dictionary(names.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
}
