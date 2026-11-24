import Foundation

/// Writes the body the server stores for what someone composed, in the form Lexxy sends and
/// `bodyFromPlainText` (body.ts) writes: one paragraph, its line breaks `<br>`.
enum Composer {
    /// The mention attachment as render.ts's `mentionAttachment` builds it (content-type, then sgid;
    /// an sgid is the user's id, mentions.ts `mentionSgid`). The server fills in `content` itself.
    static func mention(_ userId: String) -> String {
        "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>"
    }

    /// The special mentions, narrowest first (attachments.ts `SPECIAL_MENTIONS`): a mention whose sgid
    /// is one of these names.
    static let specialMentions = ["here", "channel", "everyone"]

    /// attachments.ts `ROOM_MENTION_CONTENT_TYPE`.
    static let roomMentionContentType = "application/vnd.campfire.room"

    /// What a room shows as to someone who can't see it (room-mentions.ts `PRIVATE_ROOM_NAME`).
    static let privateRoomName = "private room"

    /// The room mention attachment as render.ts's `mentionAttachment` builds it: the room mention
    /// content type, then the room's id as its sgid.
    static func roomMention(_ roomId: String) -> String {
        "<action-text-attachment content-type=\"\(roomMentionContentType)\" sgid=\"\(roomId)\"></action-text-attachment>"
    }

    /// Ids that could name a room (the protocol's `isRoomId`). Anything else is sent as the text the
    /// person saw.
    static func isValidRoomId(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        guard let first = scalars.first, scalars.count <= 63, isLowerAlphanumeric(first) else { return false }
        return scalars.allSatisfy { isLowerAlphanumeric($0) || $0 == "-" }
    }

    /// Ids the server accepts as an sgid: 16 lowercase base-36 characters, or `ember` (mentions.ts `USER_ID`).
    /// Anything else would come back as "☒", so it is sent as the text the person saw instead.
    static func isValidUserId(_ id: String) -> Bool {
        if id == "ember" { return true }
        let scalars = Array(id.unicodeScalars)
        return scalars.count == 16 && scalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) }
    }

    static func body(fromPlainText text: String) -> String {
        body(from: [.text(text)])
    }

    /// `text` as segments, each "@" and name of someone in `mentions` (a user id to the name the
    /// composer wrote for them) a mention of them, and the rest text. A name counts only as a whole:
    /// at the start or after something that isn't a letter or digit, and not running on into one, so
    /// "@Ann" isn't found in "@Anna" or "x@Ann". Where two names fit, the longer one wins. Each "@" and
    /// name in `specialMentions` is that special mention, unless someone in `mentions` has the name,
    /// and each "#" and name of a room in `rooms` (a room id to the name the composer wrote for it) a
    /// mention of the room, by the same rule.
    static func segments(_ text: String, mentions: [String: String], specialMentions: [String] = [], rooms: [String: String] = [:]) -> [ComposeSegment] {
        var segments: [ComposeSegment] = []
        var runStart = text.startIndex
        for match in found(text, mentions: mentions, specialMentions: specialMentions, rooms: rooms) {
            if runStart < match.range.lowerBound { segments.append(.text(String(text[runStart..<match.range.lowerBound]))) }
            segments.append(match.segment)
            runStart = match.range.upperBound
        }
        if runStart < text.endIndex || segments.isEmpty { segments.append(.text(String(text[runStart...]))) }
        return segments
    }

    /// Where `text` has the "@" and name of someone in `mentions`, in order, as `segments` finds them.
    static func matches(_ text: String, mentions: [String: String]) -> [(userId: String, name: String, range: Range<String.Index>)] {
        found(text, mentions: mentions).compactMap { match in
            if case let .mention(userId, name) = match.segment { (userId, name, match.range) } else { nil }
        }
    }

    /// Where `text` has a mention `segments` finds, in order, with the segment each makes.
    static func found(_ text: String, mentions: [String: String], specialMentions: [String] = [], rooms: [String: String] = [:]) -> [(segment: ComposeSegment, range: Range<String.Index>)] {
        // Longest name first, and on a tie someone before a special mention: they were picked by name.
        let people = mentions
            .filter { !$0.value.isEmpty }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { (name: $0.value, segment: ComposeSegment.mention(userId: $0.key, name: $0.value)) }
        let special = Composer.specialMentions
            .filter(specialMentions.contains)
            .map { (name: $0, segment: ComposeSegment.specialMention($0)) }
        let atNames = (people + special).enumerated()
            .sorted { ($0.element.name.count, $1.offset) > ($1.element.name.count, $0.offset) }
            .map(\.element)
        let hashNames = rooms
            .filter { !$0.value.isEmpty }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { (name: $0.value, segment: ComposeSegment.roomMention(roomId: $0.key, name: $0.value)) }
        guard !atNames.isEmpty || !hashNames.isEmpty else { return [] }
        var matches: [(segment: ComposeSegment, range: Range<String.Index>)] = []
        var index = text.startIndex
        var previous: Character?
        while index < text.endIndex {
            let character = text[index]
            let afterSign = text.index(after: index)
            let names = character == "@" ? atNames : character == "#" ? hashNames : []
            if !names.isEmpty, !(previous.map(isWordCharacter) ?? false),
               let (segment, end) = names.lazy.compactMap({ named -> (ComposeSegment, String.Index)? in
                   guard text[afterSign...].hasPrefix(named.name) else { return nil }
                   let end = text.index(afterSign, offsetBy: named.name.count)
                   guard end == text.endIndex || !isWordCharacter(text[end]) else { return nil }
                   return (named.segment, end)
               }).first {
                matches.append((segment, index..<end))
                previous = text[text.index(before: end)]
                index = end
                continue
            }
            previous = character
            index = afterSign
        }
        return matches
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func body(from segments: [ComposeSegment]) -> String {
        var html = "<p>"
        for segment in segments {
            switch segment {
            case .text(let text):
                html += escapedLines(text)
            case .mention(let userId, let name):
                html += isValidUserId(userId) ? mention(userId) : escapedLines("@" + name)
            case .specialMention(let name):
                html += specialMentions.contains(name) ? mention(name) : escapedLines("@" + name)
            case .roomMention(let roomId, let name):
                html += isValidRoomId(roomId) ? roomMention(roomId) : escapedLines("#" + name)
            }
        }
        return html + "</p>"
    }

    /// Text as the server's serialiser writes it: `& < >` and U+00A0 escaped, each line break `<br>`
    /// (split on `\r\n`, `\r` or `\n`, as body.ts does).
    private static func escapedLines(_ text: String) -> String {
        var out = ""
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousWasCarriageReturn { out += "<br>" }
                previousWasCarriageReturn = false
                continue
            }
            if scalar == "\r" {
                out += "<br>"
                previousWasCarriageReturn = true
                continue
            }
            previousWasCarriageReturn = false
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\u{00A0}": out += "&nbsp;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
