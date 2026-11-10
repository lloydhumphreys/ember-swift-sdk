import Foundation

/// Writes the body the server stores for what someone composed, in the form Lexxy sends and
/// `bodyFromPlainText` (body.ts) writes: one paragraph, its line breaks `<br>`.
enum Composer {
    /// The mention attachment as render.ts's `mentionAttachment` builds it (content-type, then sgid;
    /// an sgid is the user's id, mentions.ts `mentionSgid`). The server fills in `content` itself.
    private static func mention(_ userId: String) -> String {
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
