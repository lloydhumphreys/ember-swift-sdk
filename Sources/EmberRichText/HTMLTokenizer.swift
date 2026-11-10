import Foundation

/// A lexical piece of markup. Comments, doctypes and bogus comments never reach this type: dropping
/// them here is what "comments dropped" means.
enum HTMLToken: Equatable {
    case text(String)
    case start(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case end(name: String)
}

struct HTMLAttribute: Equatable {
    var name: String
    var value: String
}

/// A small, forgiving tokenizer in the spirit of the HTML5 one: it never fails, and anything it
/// cannot make sense of becomes text or is dropped. Stored bodies are sanitised on the server, so
/// the aim is tolerance, not conformance.
struct HTMLTokenizer {
    private let input: [Unicode.Scalar]
    private var index = 0
    private var tokens: [HTMLToken] = []
    private var pendingText = String.UnicodeScalarView()

    /// Elements whose content is raw text, so a `<` inside is not a tag.
    private static let rawTextElements: Set<String> = ["script", "style"]

    static func tokenize(_ html: String) -> [HTMLToken] {
        var tokenizer = HTMLTokenizer(input: preprocess(html))
        tokenizer.run()
        return tokenizer.tokens
    }

    /// HTML's input preprocessing: newlines normalised, NUL dropped.
    private static func preprocess(_ html: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(html.unicodeScalars.count)
        var previousWasCR = false
        for scalar in html.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            defer { previousWasCR = false }
            if scalar == "\n" && previousWasCR { continue }
            if scalar.value == 0 { continue }
            out.append(scalar)
        }
        return out
    }

    private init(input: [Unicode.Scalar]) {
        self.input = input
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < input.count ? input[position] : nil
    }

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        tokens.append(.text(String(pendingText)))
        pendingText = String.UnicodeScalarView()
    }

    private mutating func run() {
        while index < input.count {
            let scalar = input[index]
            if scalar == "<" {
                if !consumeMarkup() {
                    pendingText.append("<")
                    index += 1
                }
            } else if scalar == "&" {
                if let (decoded, length) = HTMLEntities.decode(input, at: index, inAttribute: false) {
                    pendingText.append(contentsOf: decoded.unicodeScalars)
                    index += length
                } else {
                    pendingText.append("&")
                    index += 1
                }
            } else {
                pendingText.append(scalar)
                index += 1
            }
        }
        flushText()
    }

    /// Tries to read a tag, comment or declaration at `index` (a `<`). False means the `<` is text.
    private mutating func consumeMarkup() -> Bool {
        guard let next = peek(1) else { return false }
        if next == "!" {
            if peek(2) == "-" && peek(3) == "-" {
                flushText()
                index += 4
                skipComment()
            } else {
                flushText()
                skipPast(">")
            }
            return true
        }
        if next == "?" {
            flushText()
            skipPast(">")
            return true
        }
        if next == "/" {
            guard let afterSlash = peek(2) else { return false }
            if afterSlash.isASCIILetter {
                flushText()
                index += 2
                let name = readTagName()
                skipPast(">")
                tokens.append(.end(name: name))
                return true
            }
            if afterSlash == ">" {
                // `</>` is dropped entirely.
                flushText()
                index += 3
                return true
            }
            flushText()
            skipPast(">")
            return true
        }
        guard next.isASCIILetter else { return false }
        return consumeStartTag()
    }

    private mutating func skipComment() {
        // `<!-->` and `<!--->` are empty comments.
        if peek() == ">" { index += 1; return }
        if peek() == "-" && peek(1) == ">" { index += 2; return }
        while index < input.count {
            if input[index] == "-" && peek(1) == "-" {
                if peek(2) == ">" { index += 3; return }
                if peek(2) == "!" && peek(3) == ">" { index += 4; return }
            }
            index += 1
        }
    }

    private mutating func skipPast(_ terminator: Unicode.Scalar) {
        while index < input.count {
            let scalar = input[index]
            index += 1
            if scalar == terminator { return }
        }
    }

    private mutating func readTagName() -> String {
        var name = String.UnicodeScalarView()
        while let scalar = peek(), !scalar.isHTMLSpace, scalar != "/", scalar != ">" {
            name.append(scalar.asciiLowercased)
            index += 1
        }
        return String(name)
    }

    /// Reads `<name attr=value …>`. If the input ends inside the tag the tag is dropped, as HTML5 does.
    private mutating func consumeStartTag() -> Bool {
        index += 1
        let name = readTagName()
        var attributes: [HTMLAttribute] = []
        var selfClosing = false
        var closed = false

        while index < input.count {
            while let scalar = peek(), scalar.isHTMLSpace { index += 1 }
            guard let scalar = peek() else { break }
            if scalar == ">" {
                index += 1
                closed = true
                break
            }
            if scalar == "/" {
                index += 1
                if peek() == ">" {
                    selfClosing = true
                    index += 1
                    closed = true
                    break
                }
                continue
            }
            // Attribute name: anything up to whitespace, `/`, `>` or `=` (a leading `=` is part of the name).
            var attributeName = String.UnicodeScalarView()
            if scalar == "=" {
                attributeName.append("=")
                index += 1
            }
            while let character = peek(), !character.isHTMLSpace, character != "/", character != ">", character != "=" {
                attributeName.append(character.asciiLowercased)
                index += 1
            }
            while let character = peek(), character.isHTMLSpace { index += 1 }
            var value = ""
            if peek() == "=" {
                index += 1
                while let character = peek(), character.isHTMLSpace { index += 1 }
                value = readAttributeValue()
            }
            let key = String(attributeName)
            if !key.isEmpty, !attributes.contains(where: { $0.name == key }) {
                attributes.append(HTMLAttribute(name: key, value: value))
            }
        }

        guard closed else {
            // End of input inside the tag: drop it, and everything after (there is nothing after).
            index = input.count
            return true
        }
        flushText()
        tokens.append(.start(name: name, attributes: attributes, selfClosing: selfClosing))
        if HTMLTokenizer.rawTextElements.contains(name), !selfClosing {
            consumeRawText(until: name)
        }
        return true
    }

    private mutating func readAttributeValue() -> String {
        guard let quote = peek() else { return "" }
        var value = String.UnicodeScalarView()
        if quote == "\"" || quote == "'" {
            index += 1
            while index < input.count, input[index] != quote {
                appendAttributeScalar(into: &value)
            }
            if index < input.count { index += 1 }
        } else {
            while let scalar = peek(), !scalar.isHTMLSpace, scalar != ">" {
                appendAttributeScalar(into: &value)
            }
        }
        return String(value)
    }

    private mutating func appendAttributeScalar(into value: inout String.UnicodeScalarView) {
        let scalar = input[index]
        if scalar == "&", let (decoded, length) = HTMLEntities.decode(input, at: index, inAttribute: true) {
            value.append(contentsOf: decoded.unicodeScalars)
            index += length
        } else {
            value.append(scalar)
            index += 1
        }
    }

    /// Script and style content is not markup: it runs to the matching end tag.
    private mutating func consumeRawText(until name: String) {
        let closing = Array(("</" + name).unicodeScalars)
        var raw = String.UnicodeScalarView()
        while index < input.count {
            if input[index] == "<", matches(closing, at: index), let after = peekScalar(at: index + closing.count),
               after.isHTMLSpace || after == ">" || after == "/" {
                break
            }
            raw.append(input[index])
            index += 1
        }
        if !raw.isEmpty { tokens.append(.text(String(raw))) }
    }

    private func peekScalar(at position: Int) -> Unicode.Scalar? {
        position < input.count ? input[position] : nil
    }

    private func matches(_ pattern: [Unicode.Scalar], at position: Int) -> Bool {
        guard position + pattern.count <= input.count else { return false }
        for (offset, scalar) in pattern.enumerated() where input[position + offset].asciiLowercased != scalar {
            return false
        }
        return true
    }
}

extension Unicode.Scalar {
    var isASCIILetter: Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
    }

    /// HTML's ASCII whitespace: tab, line feed, form feed, space (carriage returns are normalised away).
    var isHTMLSpace: Bool {
        value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0C || value == 0x0D
    }

    var asciiLowercased: Unicode.Scalar {
        (value >= 0x41 && value <= 0x5A) ? Unicode.Scalar(value + 0x20) ?? self : self
    }
}

/// Character references: numeric ones, and the named ones people actually write.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{AD}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„",
        "bull": "•", "middot": "·", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³", "micro": "µ", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒", "hearts": "♥", "check": "✓", "infin": "∞",
        "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "minus": "−", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "prime": "′", "Prime": "″", "iexcl": "¡", "iquest": "¿", "szlig": "ß",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ",
        "agrave": "à", "egrave": "è", "auml": "ä", "ouml": "ö", "uuml": "ü", "ccedil": "ç",
        "not": "¬", "notin": "∉", "Aacute": "Á", "Eacute": "É", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "Ntilde": "Ñ",
    ]

    /// Names that HTML decodes even without the closing semicolon.
    private static let legacy: [String] = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg", "not"]

    /// Decodes the reference at `position` (an `&`). Returns the text and how many scalars it used.
    static func decode(_ input: [Unicode.Scalar], at position: Int, inAttribute: Bool) -> (String, Int)? {
        var cursor = position + 1
        guard cursor < input.count else { return nil }
        if input[cursor] == "#" {
            cursor += 1
            var radix = 10
            if cursor < input.count, input[cursor] == "x" || input[cursor] == "X" {
                radix = 16
                cursor += 1
            }
            let digitsStart = cursor
            var value: UInt64 = 0
            while cursor < input.count, let digit = hexValue(input[cursor]), digit < radix {
                value = min(value * UInt64(radix) + UInt64(digit), 0x110000)
                cursor += 1
            }
            guard cursor > digitsStart else { return nil }
            if cursor < input.count, input[cursor] == ";" { cursor += 1 }
            return (numeric(value), cursor - position)
        }

        var name = ""
        var end = cursor
        while end < input.count, end - cursor < 32, input[end].isASCIILetter || (input[end].value >= 0x30 && input[end].value <= 0x39) {
            name.unicodeScalars.append(input[end])
            end += 1
        }
        if end < input.count, input[end] == ";", let replacement = named[name] {
            return (replacement, end + 1 - position)
        }
        if !inAttribute {
            // Longest legacy prefix, as in `&ampfoo`.
            for candidate in legacy.sorted(by: { $0.count > $1.count }) where name.hasPrefix(candidate) {
                return (named[candidate] ?? "", 1 + candidate.unicodeScalars.count)
            }
        }
        return nil
    }

    private static func numeric(_ value: UInt64) -> String {
        guard value != 0, value <= 0x10FFFF else { return "\u{FFFD}" }
        // HTML reads 0x80-0x9F as Windows-1252, so `&#128;` is the euro sign.
        if value >= 0x80, value <= 0x9F, let mapped = windows1252[Int(value) - 0x80] { return String(Character(mapped)) }
        guard let scalar = Unicode.Scalar(UInt32(value)) else { return "\u{FFFD}" }
        return String(Character(scalar))
    }

    private static let windows1252: [Unicode.Scalar?] = [
        "\u{20AC}", nil, "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", nil, "\u{017D}", nil,
        nil, "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", nil, "\u{017E}", "\u{0178}",
    ]

    private static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: Int(scalar.value) - 0x30
        case 0x41...0x46: Int(scalar.value) - 0x41 + 10
        case 0x61...0x66: Int(scalar.value) - 0x61 + 10
        default: nil
        }
    }
}
