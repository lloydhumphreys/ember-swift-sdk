import Foundation

// A bot's cards, as `packages/protocol/src/cards.ts` declares them: what a Slack-style webhook's
// legacy attachments and Block Kit blocks show under the message a bot posts. The server translates
// Slack's payload at ingest, so a client only ever sees these. Nothing in a card is interactive: a
// button is a link. Text is plain (a name, a title, a header, a footer, a field's title, an image's
// alt) or, where it's called `html`, `pretext`, `body` or `subtext`, and in a table's cells, rich text
// in the stored form, as a message's body is (`CardText.document` reads it). Addresses come as the
// webhook sent them: pass a card through `withAddresses` before showing it.
//
// Reading is lenient, as the protocol's `parseCards` is, so a newer server's kinds never fail a
// message: a part this build doesn't know, or one missing what it needs, is left out, and a card
// left with nothing to show goes.

/// A card under a bot's message: a Slack attachment, framed with a bar down its leading side in its
/// colour, or the message's Block Kit blocks, framed without one.
public struct Card: Codable, Hashable, Sendable {
    /// What it shows: an attachment, whose bar takes its colour, or the message's blocks.
    public enum Source: String, Codable, Hashable, Sendable {
        case attachment, blocks
    }

    public var source: Source
    /// An attachment's bar's colour, in lowercase: `good`, `warning`, `danger` or `#rrggbb`. See `accent`.
    public var color: String?
    /// Rich text above an attachment's frame, where Slack puts its pretext.
    public var pretext: String?
    /// A small image at the trailing side of an attachment's parts.
    public var thumb: CardImage?
    /// What it shows, top to bottom.
    public var parts: [CardPart]

    public init(source: Source, color: String? = nil, pretext: String? = nil, thumb: CardImage? = nil, parts: [CardPart]) {
        self.source = source
        self.color = color
        self.pretext = pretext
        self.thumb = thumb
        self.parts = parts
    }

    public init(from decoder: Decoder) throws {
        guard let card = Card(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a card this build can show"))
        }
        self = card
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// One of a card's parts.
public enum CardPart: Codable, Hashable, Sendable {
    /// Who it's from, in a small row with their icon, linked to `href`.
    case author(name: String, href: String?, icon: String?)
    case title(text: String, href: String?)
    /// A header block's heading.
    case header(text: String)
    /// Rich text, which folds when it's long (`CardText.isLong`).
    case text(html: String)
    /// A section block: its rich text over its fields, with a thumbnail or a link button at their trailing side.
    /// Always has `html` or at least one field.
    case section(html: String?, fields: [CardField], thumb: CardImage?, button: CardButton?)
    case fields([CardField])
    /// An image, under its title.
    case image(CardImage, title: String?)
    /// A context block's small row of rich text and images.
    case context([CardContextItem])
    /// A rule.
    case divider
    case buttons([CardButton])
    /// A table's rows of rich text cells, every row drawn alike, each column aligned and wrapped as
    /// `columns` says. A row may have more cells than there are columns: those take the defaults.
    case table(rows: [[String]], columns: [CardColumn])
    /// Card blocks' small cards: one, or a carousel's, in a row that scrolls sideways.
    case tiles([CardTile])
    /// A small row at the foot: an icon, text, and a moment, which shows in its reader's time zone.
    /// Always has `text` or `at`. On the wire `at` is in epoch seconds.
    case footer(text: String?, icon: String?, at: Date?)

    public init(from decoder: Decoder) throws {
        guard let part = CardPart(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a part this build can show"))
        }
        self = part
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    /// Whether it's a rule, which shows nothing on its own.
    public var isDivider: Bool {
        if case .divider = self { true } else { false }
    }
}

/// A title in plain text over a value in rich text, taking half the card's width when `short`.
public struct CardField: Codable, Hashable, Sendable {
    public var title: String?
    /// Rich text, or "" for none.
    public var html: String
    public var short: Bool

    public init(title: String? = nil, html: String = "", short: Bool = false) {
        self.title = title
        self.html = html
        self.short = short
    }

    public init(from decoder: Decoder) throws {
        guard let field = CardField(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a card field"))
        }
        self = field
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

public struct CardImage: Codable, Hashable, Sendable {
    public var url: String
    /// What it shows, for VoiceOver, or "" where the payload doesn't say.
    public var alt: String

    public init(url: String, alt: String = "") {
        self.url = url
        self.alt = alt
    }

    public init(from decoder: Decoder) throws {
        guard let image = CardImage(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a card image"))
        }
        self = image
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A link drawn as a button: bordered by default, filled for `primary`, red for `danger`.
public struct CardButton: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Hashable, Sendable {
        case primary, danger
    }

    public var text: String
    public var href: String
    public var style: Style?

    public init(text: String, href: String, style: Style? = nil) {
        self.text = text
        self.href = href
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        guard let button = CardButton(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a card button"))
        }
        self = button
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// Rich text or an image in a context row. On the wire, `{html}` or `{image}`.
public enum CardContextItem: Codable, Hashable, Sendable {
    case html(String)
    case image(CardImage)

    public init(from decoder: Decoder) throws {
        guard let item = CardContextItem(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a context item"))
        }
        self = item
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// How a table's column lines up its cells, and whether their text wraps rather than being cut short.
public struct CardColumn: Codable, Hashable, Sendable {
    public enum Alignment: String, Codable, Hashable, Sendable {
        case left, center, right
    }

    public var align: Alignment
    public var wrap: Bool

    public init(align: Alignment = .left, wrap: Bool = false) {
        self.align = align
        self.wrap = wrap
    }

    public init(from decoder: Decoder) throws {
        self = CardColumn(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A card block's small card: an image across its top, an icon beside its title and subtitle in plain
/// text, its body and subtext in rich text, and up to three link buttons.
public struct CardTile: Codable, Hashable, Sendable {
    public var hero: CardImage?
    public var icon: CardImage?
    public var title: String?
    public var subtitle: String?
    /// Rich text.
    public var body: String?
    /// Rich text, drawn small.
    public var subtext: String?
    public var buttons: [CardButton]

    public init(
        hero: CardImage? = nil, icon: CardImage? = nil, title: String? = nil, subtitle: String? = nil,
        body: String? = nil, subtext: String? = nil, buttons: [CardButton] = []
    ) {
        self.hero = hero
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.subtext = subtext
        self.buttons = buttons
    }

    public init(from decoder: Decoder) throws {
        guard let tile = CardTile(json: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a card tile"))
        }
        self = tile
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    /// Its buttons as the web's tile lays them out: the danger ones at the leading side, in order, and
    /// the rest at the trailing side, a primary one last (`bot-card.tsx`'s `Tile`).
    public var buttonsInOrder: (leading: [CardButton], trailing: [CardButton]) {
        let rest = buttons.filter { $0.style != .danger }
        return (
            leading: buttons.filter { $0.style == .danger },
            trailing: rest.filter { $0.style != .primary } + rest.filter { $0.style == .primary }
        )
    }

    /// Whether it shows anything: an icon alone doesn't count, as the protocol's `tileOf` has it.
    var showsAnything: Bool {
        hero != nil || title != nil || subtitle != nil || body != nil || subtext != nil || !buttons.isEmpty
    }
}

/// An attachment's bar colour, read from `Card.color`.
public enum CardAccent: Hashable, Sendable {
    case good, warning, danger
    /// A colour written `#rrggbb`, each component from 0 to 1.
    case rgb(red: Double, green: Double, blue: Double)
}

// MARK: - What a view needs

extension Card {
    /// The text of its first title or header, which names the card, as the web labels its article.
    public var label: String? {
        for part in parts {
            switch part {
            case let .title(text, _), let .header(text): return text
            default: continue
            }
        }
        return nil
    }

    /// Its colour: `good`, `warning`, `danger` or `#rrggbb`, in any case. Nil for none or anything else.
    public var accent: CardAccent? {
        guard let color else { return nil }
        switch color.lowercased() {
        case "good": return .good
        case "warning": return .warning
        case "danger": return .danger
        default: break
        }
        let scalars = Array(color.unicodeScalars)
        guard Card.isColor(color), scalars.count == 7 else { return nil }
        var components: [Double] = []
        for index in stride(from: 1, to: 7, by: 2) {
            guard let value = UInt8(String(String.UnicodeScalarView(scalars[index ..< index + 2])), radix: 16) else { return nil }
            components.append(Double(value) / 255)
        }
        return .rgb(red: components[0], green: components[1], blue: components[2])
    }

    /// Whether it shows anything: a part that isn't a rule, or an attachment's pretext.
    var showsAnything: Bool {
        parts.contains { !$0.isDivider } || pretext != nil
    }

    /// The card with every address in it passed through `shown`, as the web passes each through
    /// `shownAddress` before drawing it: `shown` answers the address to use, or nil to refuse it.
    ///
    /// A refused image goes (the card's or a section's thumbnail, an image part with its part, a context
    /// image, a tile's hero or icon); a refused icon or link (an author's, a title's, a footer's) goes,
    /// leaving its text; a refused button goes, and with it a row of buttons left empty. A part, or a
    /// tile, left with nothing to show goes, and a card left with nothing is nil.
    public func withAddresses(_ shown: (String) -> String?) -> Card? {
        func image(_ image: CardImage?) -> CardImage? {
            guard let image, let url = shown(image.url) else { return nil }
            return CardImage(url: url, alt: image.alt)
        }
        func address(_ value: String?) -> String? { value.flatMap(shown) }
        func button(_ button: CardButton?) -> CardButton? {
            guard let button, let href = shown(button.href) else { return nil }
            return CardButton(text: button.text, href: href, style: button.style)
        }

        var card = self
        card.thumb = image(thumb)
        card.parts = parts.compactMap { part -> CardPart? in
            switch part {
            case let .author(name, href, icon):
                return .author(name: name, href: address(href), icon: address(icon))
            case let .title(text, href):
                return .title(text: text, href: address(href))
            case .header, .text, .fields, .divider, .table:
                return part
            case let .section(html, fields, thumb, sectionButton):
                return .section(html: html, fields: fields, thumb: image(thumb), button: button(sectionButton))
            case let .image(shownImage, title):
                return image(shownImage).map { .image($0, title: title) }
            case let .context(items):
                let kept = items.compactMap { item -> CardContextItem? in
                    switch item {
                    case .html: item
                    case let .image(contextImage): image(contextImage).map(CardContextItem.image)
                    }
                }
                return kept.isEmpty ? nil : .context(kept)
            case let .buttons(buttons):
                let kept = buttons.compactMap(button)
                return kept.isEmpty ? nil : .buttons(kept)
            case let .tiles(tiles):
                let kept = tiles.compactMap { tile -> CardTile? in
                    var tile = tile
                    tile.hero = image(tile.hero)
                    tile.icon = image(tile.icon)
                    tile.buttons = tile.buttons.compactMap(button)
                    return tile.showsAnything ? tile : nil
                }
                return kept.isEmpty ? nil : .tiles(kept)
            case let .footer(text, icon, at):
                return .footer(text: text, icon: address(icon), at: at)
            }
        }
        return card.showsAnything ? card : nil
    }
}

extension Array where Element == Card {
    /// Each card with its addresses passed through `shown` (`Card.withAddresses`), without those left
    /// with nothing to show.
    public func withAddresses(_ shown: (String) -> String?) -> [Card] {
        compactMap { $0.withAddresses(shown) }
    }
}

// MARK: - Reading the wire

/// The protocol's limits, so a card reads here as the room keeps it.
private enum CardLimits {
    static let cards = 101
    static let parts = 60
    static let items = 100
    static let columns = 20
    static let tileButtons = 3
    static let text = 3000
    static let url = 3000
    /// `MAX_MESSAGE_HTML_LENGTH`.
    static let html = 100_000
    /// The furthest a JavaScript `Date` reaches either side of 1970, in seconds.
    static let moment = 8.64e12
}

extension Card {
    /// The cards a message's `cards` value lists, as the protocol's `parseCards` reads them, or nil
    /// when it isn't a list or none of them shows anything.
    static func list(_ value: JSONValue?) -> [Card]? {
        guard case let .array(items)? = value else { return nil }
        let cards = items.prefix(CardLimits.cards).compactMap(Card.init(json:))
        return cards.isEmpty ? nil : cards
    }

    init?(json value: JSONValue) {
        guard case let .object(object) = value,
              let source = object["source"]?.string.flatMap(Source.init(rawValue:)) else { return nil }
        let parts = listOf(object["parts"]).prefix(CardLimits.parts).compactMap(CardPart.init(json:))
        switch source {
        case .blocks:
            // Only an attachment has a bar, a pretext and a thumbnail.
            self.init(source: .blocks, parts: parts)
        case .attachment:
            let color = object["color"]?.string.flatMap { color in Card.isColor(color) ? color.lowercased() : nil }
            self.init(source: .attachment, color: color, pretext: htmlOf(object["pretext"]), thumb: object["thumb"].flatMap(CardImage.init(json:)), parts: parts)
        }
        guard showsAnything else { return nil }
    }

    /// `good`, `warning`, `danger` or `#` and six hex digits, in any case.
    static func isColor(_ color: String) -> Bool {
        if ["good", "warning", "danger"].contains(color.lowercased()) { return true }
        let scalars = Array(color.unicodeScalars)
        return scalars.count == 7 && scalars[0] == "#" && scalars.dropFirst().allSatisfy { $0.properties.isASCIIHexDigit }
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["source": .string(source.rawValue), "parts": .array(parts.map(\.json))]
        object["color"] = color.map(JSONValue.string)
        object["pretext"] = pretext.map(JSONValue.string)
        object["thumb"] = thumb?.json
        return .object(object)
    }
}

extension CardPart {
    init?(json value: JSONValue) {
        guard case let .object(object) = value, let kind = object["kind"]?.string else { return nil }
        switch kind {
        case "author":
            guard let name = textOf(object["name"]) else { return nil }
            self = .author(name: name, href: urlOf(object["href"]), icon: urlOf(object["icon"]))
        case "title":
            guard let text = textOf(object["text"]) else { return nil }
            self = .title(text: text, href: urlOf(object["href"]))
        case "header":
            guard let text = textOf(object["text"]) else { return nil }
            self = .header(text: text)
        case "text":
            guard let html = htmlOf(object["html"]) else { return nil }
            self = .text(html: html)
        case "section":
            let html = htmlOf(object["html"])
            let fields = itemsOf(object["fields"], CardField.init(json:))
            guard html != nil || !fields.isEmpty else { return nil }
            self = .section(html: html, fields: fields, thumb: object["thumb"].flatMap(CardImage.init(json:)), button: object["button"].flatMap(CardButton.init(json:)))
        case "fields":
            let fields = itemsOf(object["fields"], CardField.init(json:))
            guard !fields.isEmpty else { return nil }
            self = .fields(fields)
        case "image":
            guard let image = object["image"].flatMap(CardImage.init(json:)) else { return nil }
            self = .image(image, title: textOf(object["title"]))
        case "context":
            let items = itemsOf(object["items"], CardContextItem.init(json:))
            guard !items.isEmpty else { return nil }
            self = .context(items)
        case "divider":
            self = .divider
        case "buttons":
            let buttons = itemsOf(object["buttons"], CardButton.init(json:))
            guard !buttons.isEmpty else { return nil }
            self = .buttons(buttons)
        case "table":
            let rows = itemsOf(object["rows"]) { row -> [String]? in
                guard case let .array(cells) = row, !cells.isEmpty else { return nil }
                return cells.prefix(CardLimits.columns).map { htmlOf($0) ?? "" }
            }
            guard !rows.isEmpty else { return nil }
            self = .table(rows: rows, columns: listOf(object["columns"]).prefix(CardLimits.columns).map(CardColumn.init(json:)))
        case "tiles":
            let tiles = itemsOf(object["tiles"], CardTile.init(json:))
            guard !tiles.isEmpty else { return nil }
            self = .tiles(tiles)
        case "footer":
            let text = textOf(object["text"])
            let at = momentOf(object["at"])
            guard text != nil || at != nil else { return nil }
            self = .footer(text: text, icon: urlOf(object["icon"]), at: at)
        default:
            return nil
        }
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        func set(_ key: String, _ value: String?) { object[key] = value.map(JSONValue.string) }
        switch self {
        case let .author(name, href, icon):
            object["kind"] = .string("author")
            set("name", name)
            set("href", href)
            set("icon", icon)
        case let .title(text, href):
            object["kind"] = .string("title")
            set("text", text)
            set("href", href)
        case let .header(text):
            object["kind"] = .string("header")
            set("text", text)
        case let .text(html):
            object["kind"] = .string("text")
            set("html", html)
        case let .section(html, fields, thumb, button):
            object["kind"] = .string("section")
            set("html", html)
            if !fields.isEmpty { object["fields"] = .array(fields.map(\.json)) }
            object["thumb"] = thumb?.json
            object["button"] = button?.json
        case let .fields(fields):
            object["kind"] = .string("fields")
            object["fields"] = .array(fields.map(\.json))
        case let .image(image, title):
            object["kind"] = .string("image")
            object["image"] = image.json
            set("title", title)
        case let .context(items):
            object["kind"] = .string("context")
            object["items"] = .array(items.map(\.json))
        case .divider:
            object["kind"] = .string("divider")
        case let .buttons(buttons):
            object["kind"] = .string("buttons")
            object["buttons"] = .array(buttons.map(\.json))
        case let .table(rows, columns):
            object["kind"] = .string("table")
            object["rows"] = .array(rows.map { .array($0.map(JSONValue.string)) })
            object["columns"] = .array(columns.map(\.json))
        case let .tiles(tiles):
            object["kind"] = .string("tiles")
            object["tiles"] = .array(tiles.map(\.json))
        case let .footer(text, icon, at):
            object["kind"] = .string("footer")
            set("text", text)
            set("icon", icon)
            object["at"] = at.map { .number($0.timeIntervalSince1970) }
        }
        return .object(object)
    }
}

extension CardField {
    init?(json value: JSONValue) {
        guard case let .object(object) = value else { return nil }
        let title = textOf(object["title"])
        let html = htmlOf(object["html"])
        guard title != nil || html != nil else { return nil }
        self.init(title: title, html: html ?? "", short: object["short"] == .bool(true))
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["html": .string(html), "short": .bool(short)]
        object["title"] = title.map(JSONValue.string)
        return .object(object)
    }
}

extension CardImage {
    init?(json value: JSONValue) {
        guard case let .object(object) = value, let url = urlOf(object["url"]) else { return nil }
        self.init(url: url, alt: textOf(object["alt"]) ?? "")
    }

    var json: JSONValue { .object(["url": .string(url), "alt": .string(alt)]) }
}

extension CardButton {
    init?(json value: JSONValue) {
        guard case let .object(object) = value, let text = textOf(object["text"]), let href = urlOf(object["href"]) else { return nil }
        self.init(text: text, href: href, style: object["style"]?.string.flatMap(Style.init(rawValue:)))
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["text": .string(text), "href": .string(href)]
        object["style"] = style.map { .string($0.rawValue) }
        return .object(object)
    }
}

extension CardContextItem {
    init?(json value: JSONValue) {
        guard case let .object(object) = value else { return nil }
        // An item naming an image is one, or nothing, whatever else it holds.
        if let image = object["image"] {
            guard let image = CardImage(json: image) else { return nil }
            self = .image(image)
            return
        }
        guard let html = htmlOf(object["html"]) else { return nil }
        self = .html(html)
    }

    var json: JSONValue {
        switch self {
        case let .html(html): .object(["html": .string(html)])
        case let .image(image): .object(["image": image.json])
        }
    }
}

extension CardColumn {
    /// Anything that isn't a column reads as the default one, as the protocol's `columnOf` has it.
    init(json value: JSONValue) {
        guard case let .object(object) = value else {
            self.init()
            return
        }
        self.init(align: object["align"]?.string.flatMap(Alignment.init(rawValue:)) ?? .left, wrap: object["wrap"] == .bool(true))
    }

    var json: JSONValue { .object(["align": .string(align.rawValue), "wrap": .bool(wrap)]) }
}

extension CardTile {
    init?(json value: JSONValue) {
        guard case let .object(object) = value else { return nil }
        self.init(
            hero: object["hero"].flatMap(CardImage.init(json:)),
            icon: object["icon"].flatMap(CardImage.init(json:)),
            title: textOf(object["title"]),
            subtitle: textOf(object["subtitle"]),
            body: htmlOf(object["body"]),
            subtext: htmlOf(object["subtext"]),
            buttons: Array(itemsOf(object["buttons"], CardButton.init(json:)).prefix(CardLimits.tileButtons))
        )
        guard showsAnything else { return nil }
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object["hero"] = hero?.json
        object["icon"] = icon?.json
        object["title"] = title.map(JSONValue.string)
        object["subtitle"] = subtitle.map(JSONValue.string)
        object["body"] = body.map(JSONValue.string)
        object["subtext"] = subtext.map(JSONValue.string)
        if !buttons.isEmpty { object["buttons"] = .array(buttons.map(\.json)) }
        return .object(object)
    }
}

private extension JSONValue {
    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }
}

/// JavaScript's `trim()` whitespace.
private let jsWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

/// Plain text a card shows, or nil for none (blank), or too much.
private func textOf(_ value: JSONValue?) -> String? {
    guard let text = value?.string, !text.trimmingCharacters(in: jsWhitespace).isEmpty, text.utf16.count <= CardLimits.text else { return nil }
    return text
}

/// Rich text a card shows, or nil for none, or more than a message's body can hold.
private func htmlOf(_ value: JSONValue?) -> String? {
    guard let html = value?.string, !html.isEmpty, html.utf16.count <= CardLimits.html else { return nil }
    return html
}

/// An address, unchecked but for its length. Which addresses show is `Card.withAddresses`'s question.
private func urlOf(_ value: JSONValue?) -> String? {
    guard let url = value?.string, url.utf16.count <= CardLimits.url else { return nil }
    return url
}

/// A moment in seconds that a JavaScript date can hold, or nil.
private func momentOf(_ value: JSONValue?) -> Date? {
    guard case let .number(seconds)? = value, seconds.isFinite, abs(seconds) <= CardLimits.moment else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func listOf(_ value: JSONValue?) -> [JSONValue] {
    if case let .array(items)? = value { items } else { [] }
}

/// The items of a list that `parse` keeps, of its first `CardLimits.items`.
private func itemsOf<Item>(_ value: JSONValue?, _ parse: (JSONValue) -> Item?) -> [Item] {
    listOf(value).prefix(CardLimits.items).compactMap(parse)
}
