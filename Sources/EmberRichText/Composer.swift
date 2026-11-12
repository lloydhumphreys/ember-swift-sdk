import Foundation

/// Writes the body the server stores for what someone composed, in the form Lexxy sends and
/// `bodyFromPlainText` (body.ts) writes: one paragraph, its line breaks `<br>`.
enum Composer {
    /// The mention attachment as render.ts's `mentionAttachment` builds it (content-type, then sgid;
    /// an sgid is the user's id, mentions.ts `mentionSgid`). The server fills in `content` itself.
    static func mention(_ userId: String) -> String {
        "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>"
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
    /// "@Ann" isn't found in "@Anna" or "x@Ann". Where two names fit, the longer one wins.
    static func segments(_ text: String, mentions: [String: String]) -> [ComposeSegment] {
        var segments: [ComposeSegment] = []
        var runStart = text.startIndex
        for match in matches(text, mentions: mentions) {
            if runStart < match.range.lowerBound { segments.append(.text(String(text[runStart..<match.range.lowerBound]))) }
            segments.append(.mention(userId: match.userId, name: match.name))
            runStart = match.range.upperBound
        }
        if runStart < text.endIndex || segments.isEmpty { segments.append(.text(String(text[runStart...]))) }
        return segments
    }

    /// Where `text` has the "@" and name of someone in `mentions`, in order, as `segments` finds them.
    static func matches(_ text: String, mentions: [String: String]) -> [(userId: String, name: String, range: Range<String.Index>)] {
        let people = mentions
            .filter { !$0.value.isEmpty }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        guard !people.isEmpty else { return [] }
        var matches: [(userId: String, name: String, range: Range<String.Index>)] = []
        var index = text.startIndex
        var previous: Character?
        while index < text.endIndex {
            let character = text[index]
            let afterAt = text.index(after: index)
            if character == "@", !(previous.map(isWordCharacter) ?? false),
               let (userId, name, end) = people.lazy.compactMap({ person -> (String, String, String.Index)? in
                   guard text[afterAt...].hasPrefix(person.value) else { return nil }
                   let end = text.index(afterAt, offsetBy: person.value.count)
                   guard end == text.endIndex || !isWordCharacter(text[end]) else { return nil }
                   return (person.key, person.value, end)
               }).first {
                matches.append((userId, name, index..<end))
                previous = text[text.index(before: end)]
                index = end
                continue
            }
            previous = character
            index = afterAt
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
