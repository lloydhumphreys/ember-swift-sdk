import Foundation

/// A bot card's rich text and addresses, as the web's `bot-card.tsx` reads them.
public enum CardText {
    /// What a card's rich text shows (a text part, a field, a section, a cell, a tile's body): as a
    /// message body does, but never emoji-only and never losing a lone link, since a card has no plain
    /// text to decide either by. `host` is the server's host. Never throws.
    public static func document(html: String, host: String) -> RichDocument {
        RichText.document(html: html, plainText: "", host: host)
    }

    /// The address a card may show (an image, an icon, a link, a button), or nil to leave it out: an
    /// absolute `http` or `https` address to a named host other than the server's own, as the web's
    /// `cardAddress` allows. Pass it to `Card.withAddresses` as `{ CardText.address($0, host: host) }`.
    public static func address(_ value: String?, host: String) -> String? {
        guard let value, isWellFormed(value) else { return nil }
        return PreviewReader.webURL(value, host: host)
    }

    /// Whether the protocol's RFC 3986 reading takes it: before its query, and in its fragment, only
    /// the characters a URI may hold, and `%` only before two hex digits. A query may hold anything.
    private static func isWellFormed(_ value: String) -> Bool {
        enum Part { case head, query, fragment }
        let scalars = Array(value.unicodeScalars)
        var part = Part.head
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch (part, scalar) {
            case (.head, "?"): part = .query
            case (.head, "#"), (.query, "#"): part = .fragment
            case (.query, _), (.fragment, "?"): continue
            case (_, "%"):
                guard index + 1 < scalars.count, scalars[index].properties.isASCIIHexDigit, scalars[index + 1].properties.isASCIIHexDigit else { return false }
                index += 2
            default:
                guard uriCharacters.contains(scalar) else { return false }
            }
        }
        return true
    }

    /// `[!$&-.0-9:;=@A-Z_a-z~/]`, what the protocol's URI parser lets a host, a path and a fragment hold.
    private static let uriCharacters: Set<Unicode.Scalar> = {
        var characters = Set("!$&'()*+,-.:;=@_~/".unicodeScalars)
        for range in ["0" ... "9", "A" ... "Z", "a" ... "z"] as [ClosedRange<Unicode.Scalar>] {
            for value in range.lowerBound.value ... range.upperBound.value { characters.insert(Unicode.Scalar(value)!) }
        }
        return characters
    }()

    /// Whether a text part is long enough to fold behind "Show more": over 700 characters, or more than
    /// five line breaks, counting a `<br>` and each block after the first.
    public static func isLong(html: String) -> Bool {
        guard let root = try? HTMLTreeBuilder.parse(html) else { return false }
        var count = Count()
        for child in root.children { count.add(child) }
        return count.characters > foldCharacters || count.lineBreaks > foldLineBreaks
    }

    private static let foldCharacters = 700
    private static let foldLineBreaks = 5
    private static let blocks: Set<String> = ["p", "div", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6"]

    private struct Count {
        var characters = 0
        /// The first block's starts no line.
        var lineBreaks = -1

        mutating func add(_ node: HTMLNode) {
            switch node.kind {
            case .text:
                characters += node.text.utf16.count
                lineBreaks += node.text.utf16.count { $0 == 0x0A }
            case .element:
                if node.name == PreviewReader.attachmentTag { return }
                if node.name == "br" || (CardText.blocks.contains(node.name) && !startsWithBlock(node)) { lineBreaks += 1 }
                for child in node.children { add(child) }
            }
        }

        /// Whether its first child is a block, which starts the line instead.
        private func startsWithBlock(_ node: HTMLNode) -> Bool {
            guard let first = node.children.first else { return false }
            return first.kind == .element && CardText.blocks.contains(first.name)
        }
    }
}
