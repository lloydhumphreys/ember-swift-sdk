import EmberRichText

// EmberRichText knows nothing of EmberCore, so its mentions carry a user's id as a String. These
// take and give a `UserID` instead.

extension ComposeSegment {
    /// A mention of `userID`, showing `name` in the composer.
    public static func mention(_ userID: UserID, name: String) -> ComposeSegment {
        .mention(userId: userID.rawValue, name: name)
    }

    /// Who a mention is of; nil for text.
    public var userID: UserID? {
        if case let .mention(userId, _) = self { UserID(userId) } else { nil }
    }
}

extension RichInline {
    /// Who a mention read out of a body is of; nil for anything else.
    public var userID: UserID? {
        if case let .mention(userId) = self { UserID(userId) } else { nil }
    }
}

extension RichText {
    /// `segments(_:mentions:)`, with each person chosen by their `UserID`.
    public static func segments(_ text: String, mentions: [UserID: String]) -> [ComposeSegment] {
        segments(text, mentions: plain(mentions))
    }

    /// `mentionRanges(in:mentions:)`, with each person chosen by their `UserID`.
    public static func mentionRanges(in text: String, mentions: [UserID: String]) -> [Range<String.Index>] {
        mentionRanges(in: text, mentions: plain(mentions))
    }
}

extension EditableBody {
    /// `init(body:mentionNames:)`, with each name keyed by the person's `UserID`.
    public init(body: String, mentionNames: [UserID: String]) {
        self.init(body: body, mentionNames: plain(mentionNames))
    }

    /// `body(editedTo:mentions:)`, with each person chosen by their `UserID`.
    public func body(editedTo newText: String, mentions: [UserID: String]) -> String {
        body(editedTo: newText, mentions: plain(mentions))
    }
}

private func plain(_ names: [UserID: String]) -> [String: String] {
    Dictionary(names.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
}
