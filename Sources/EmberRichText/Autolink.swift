import Foundation

/// Links bare addresses in text, as rails_autolink's `auto_link` does for the web (autolink.ts), but
/// over plain text rather than serialised HTML. A text piece is either a run of ordinary text or an
/// address, with the `href` the web would give it.
enum Autolink {
    struct Piece: Equatable {
        var text: String
        var href: String?
    }

    /// Schemes `AUTO_LINK_RE` knows. Each must be followed by `://`.
    private static let schemes: [[UInt32]] = [
        "ed2k", "ftp", "http", "https", "irc", "mailto", "news", "gopher", "nntp", "telnet", "webcal", "xmpp", "callto",
        "feed", "svn", "urn", "aim", "rsync", "tag", "ssh", "sftp", "rtsp", "afs", "file",
    ].map { $0.unicodeScalars.map(\.value) }

    /// Splits `text` into plain and linked pieces. Returns a single plain piece when there is nothing to link.
    static func pieces(in text: String) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        // Cheap exit: every address needs a `.` or `:` or `@`.
        guard scalars.contains(where: { $0 == "." || $0 == ":" || $0 == "@" }) else { return [Piece(text: text, href: nil)] }

        var pieces: [Piece] = []
        var plainStart = 0
        var position = 0

        func appendPlain(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let slice = String(String.UnicodeScalarView(scalars[range]))
            pieces.append(contentsOf: emailPieces(in: slice))
        }

        while position < scalars.count {
            guard let matchEnd = urlEnd(in: scalars, at: position) else {
                position += 1
                continue
            }
            let whole = Array(scalars[position..<matchEnd])
            let (address, _) = withoutTrailingPunctuation(whole)
            // The address can shrink to nothing useful (such as just "www.a"): it still matched, as on the web.
            appendPlain(plainStart..<position)
            let addressText = String(String.UnicodeScalarView(address))
            let hasScheme = !(addressText.lowercased().hasPrefix("www.") && !addressText.contains("://"))
            let href = hasScheme ? addressText : "http://" + addressText
            pieces.append(Piece(text: addressText, href: sanitisedHref(href)))
            position += address.count
            plainStart = position
            // Punctuation that was trimmed stays in the following plain text.
        }
        appendPlain(plainStart..<scalars.count)
        return mergePlain(pieces)
    }

    // MARK: URLs

    /// The end of an address starting at `start`, or nil if none starts there. It is `AUTO_LINK_RE`:
    /// a known scheme and `//`, or `www.` and a word character, then anything but whitespace and `"`.
    private static func urlEnd(in scalars: [Unicode.Scalar], at start: Int) -> Int? {
        var afterPrefix: Int?
        let first = scalars[start].asciiLowercased
        if first == "w" {
            let www: [UInt32] = [0x77, 0x77, 0x77, 0x2E]
            if hasPrefix(scalars, at: start, www), start + 4 < scalars.count, isAddressWordCharacter(scalars[start + 4]) {
                afterPrefix = start + 5
            }
        } else if first.isASCIILetter || (first.value >= 0x30 && first.value <= 0x39) {
            for scheme in schemes where hasPrefix(scalars, at: start, scheme) {
                let colon = start + scheme.count
                if colon + 2 < scalars.count, scalars[colon] == ":", scalars[colon + 1] == "/", scalars[colon + 2] == "/" {
                    afterPrefix = colon + 3
                    break
                }
            }
        }
        guard var end = afterPrefix else { return nil }
        // `[^ \t\r\n\v\f"]+` after the prefix, which for `www.` has already taken one character.
        let requiredCharacters = scalars[start].asciiLowercased == "w" ? 0 : 1
        let bodyStart = end
        while end < scalars.count, !isAddressTerminator(scalars[end]) { end += 1 }
        if end - bodyStart < requiredCharacters { return nil }
        return end
    }

    private static func hasPrefix(_ scalars: [Unicode.Scalar], at start: Int, _ prefix: [UInt32]) -> Bool {
        guard start + prefix.count <= scalars.count else { return false }
        for (offset, value) in prefix.enumerated() where scalars[start + offset].asciiLowercased.value != value {
            return false
        }
        return true
    }

    private static func isAddressWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCIILetter || (scalar.value >= 0x30 && scalar.value <= 0x39) || scalar == "_"
    }

    private static func isAddressTerminator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x22, 0xA0: true
        default: false
        }
    }

    private static let closingBrackets: [Unicode.Scalar: Unicode.Scalar] = ["]": "[", ")": "(", "}": "{"]

    /// An address without the punctuation that ends it: everything after its last word character,
    /// `/`, `-`, `=` or `;`, but a closing bracket stays when the address opened more of them.
    static func withoutTrailingPunctuation(_ address: [Unicode.Scalar]) -> ([Unicode.Scalar], [Unicode.Scalar]) {
        var kept = address
        var removed: [Unicode.Scalar] = []
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in kept { counts[scalar, default: 0] += 1 }
        while let last = kept.last, !(isWordCharacter(last) || "/-=;".unicodeScalars.contains(last)) {
            kept.removeLast()
            removed.append(last)
            counts[last, default: 0] -= 1
            if let opening = closingBrackets[last], counts[opening, default: 0] > counts[last, default: 0] {
                kept.append(removed.removeLast())
                break
            }
        }
        return (kept, removed.reversed())
    }

    /// Ruby's `\p{Word}`: alphabetic characters, marks, decimal digits, connector punctuation.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic || scalar.properties.isJoinControl { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    // MARK: Hrefs

    /// What `sanitize(href)` leaves, as the server's `scrub` would for a link's href: spaces and quotes
    /// escaped and control characters dropped. Links with schemes the sanitiser rejects are still
    /// made here (the web links them after sanitising, so `feed://` survives), but never `javascript:`.
    private static func sanitisedHref(_ href: String) -> String? {
        var out = String.UnicodeScalarView()
        for scalar in href.unicodeScalars {
            switch scalar.value {
            case 0x20: out.append(contentsOf: "%20".unicodeScalars)
            case 0x22: out.append(contentsOf: "%22".unicodeScalars)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: Email addresses

    private static func isLocalStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCIILetter || (scalar.value >= 0x30 && scalar.value <= 0x39) || "_.!#$%+-".unicodeScalars.contains(scalar)
    }

    /// `AUTO_EMAIL_LOCAL_RE`: characters an address's local part is made of; none may directly precede one.
    private static func isLocalCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCIILetter || (scalar.value >= 0x30 && scalar.value <= 0x39) || "_.!#$%&'*/=?^`{|}~+-".unicodeScalars.contains(scalar)
    }

    private static func isDomainLabelCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCIILetter || (scalar.value >= 0x30 && scalar.value <= 0x39) || scalar == "_" || scalar == "-"
    }

    private static func emailPieces(in text: String) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains("@") else { return [Piece(text: text, href: nil)] }
        var pieces: [Piece] = []
        var plainStart = 0
        var position = 0
        while position < scalars.count {
            let precededByLocalCharacter = position > 0 && isLocalCharacter(scalars[position - 1])
            if !precededByLocalCharacter, let end = emailEnd(in: scalars, at: position) {
                if plainStart < position {
                    pieces.append(Piece(text: String(String.UnicodeScalarView(scalars[plainStart..<position])), href: nil))
                }
                let email = String(String.UnicodeScalarView(scalars[position..<end]))
                pieces.append(Piece(text: email, href: "mailto:" + urlEncode(email).replacingOccurrences(of: "%40", with: "@")))
                position = end
                plainStart = end
            } else {
                position += 1
            }
        }
        if plainStart < scalars.count {
            pieces.append(Piece(text: String(String.UnicodeScalarView(scalars[plainStart...])), href: nil))
        }
        return pieces
    }

    /// `AUTO_EMAIL_RE` at one position: a local part, `@`, and a domain of at least two labels.
    private static func emailEnd(in scalars: [Unicode.Scalar], at start: Int) -> Int? {
        guard isLocalStart(scalars[start]) else { return nil }
        var cursor = start + 1
        while cursor < scalars.count, isLocalCharacter(scalars[cursor]) { cursor += 1 }
        guard cursor < scalars.count, scalars[cursor] == "@" else { return nil }
        cursor += 1
        var labels = 0
        var end = cursor
        while true {
            var labelEnd = end
            while labelEnd < scalars.count, isDomainLabelCharacter(scalars[labelEnd]) { labelEnd += 1 }
            guard labelEnd > end else { break }
            labels += 1
            end = labelEnd
            if end + 1 < scalars.count, scalars[end] == ".", isDomainLabelCharacter(scalars[end + 1]) {
                end += 1
            } else {
                break
            }
        }
        return labels >= 2 ? end : nil
    }

    /// `ERB::Util.url_encode`: every UTF-8 byte but `a-z A-Z 0-9 _ - . ~` as `%XX`.
    private static func urlEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            let isUnreserved = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2D || byte == 0x2E || byte == 0x7E
            out += isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return out
    }

    private static func mergePlain(_ pieces: [Piece]) -> [Piece] {
        var merged: [Piece] = []
        for piece in pieces {
            if piece.href == nil, let last = merged.last, last.href == nil {
                merged[merged.count - 1].text += piece.text
            } else {
                merged.append(piece)
            }
        }
        return merged
    }
}
