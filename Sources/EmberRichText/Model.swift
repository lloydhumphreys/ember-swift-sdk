import Foundation

/// What a message shows, as blocks top to bottom.
public struct RichDocument: Hashable, Sendable {
    public var blocks: [RichBlock]
    /// True when the body is only emoji, which the web shows large. It follows the web's rule
    /// exactly (`isAllEmoji` over the message's `plainText`), so it is decided from the plain text,
    /// not from the markup.
    public var isEmojiOnly: Bool

    public init(blocks: [RichBlock], isEmojiOnly: Bool = false) {
        self.blocks = blocks
        self.isEmojiOnly = isEmojiOnly
    }
}

/// A block of a message, mirroring the elements display.ts lets a message keep.
public indirect enum RichBlock: Hashable, Sendable {
    case paragraph([RichInline])
    case heading(level: Int, [RichInline])
    case codeBlock(language: String?, code: String)
    case quote([RichBlock])
    /// `start` is the `start` attribute of an `<ol>`, when it has a readable one.
    case list(ordered: Bool, start: Int?, items: [[RichBlock]])
    /// Cells hold inlines only; anything block-shaped inside a cell is flattened with line breaks.
    case table(header: [[RichInline]]?, rows: [[[RichInline]]])
    case rule
    /// A link preview / opengraph embed.
    case preview(RichPreview)
}

/// Inline formatting that can stack, such as bold italic.
public struct RichStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = RichStyle(rawValue: 1 << 0)
    public static let italic = RichStyle(rawValue: 1 << 1)
    public static let strikethrough = RichStyle(rawValue: 1 << 2)
    public static let underline = RichStyle(rawValue: 1 << 3)
    public static let code = RichStyle(rawValue: 1 << 4)
    /// `<mark>`.
    public static let highlight = RichStyle(rawValue: 1 << 5)
    public static let superscript = RichStyle(rawValue: 1 << 6)
    public static let `subscript` = RichStyle(rawValue: 1 << 7)
}

public indirect enum RichInline: Hashable, Sendable {
    case text(String, RichStyle)
    /// `url` is the href as stored; the app resolves relative ones.
    case link(url: String, [RichInline])
    /// The app shows the person's current name.
    case mention(userId: String)
    case lineBreak
}

/// A link preview, as display.ts's `DisplayPreview` carries one.
public struct RichPreview: Hashable, Sendable {
    public var title: String
    public var href: String?
    public var description: String
    public var image: String?
    /// display.ts's `avatar`: the image is someone's X avatar, which shows small and round.
    public var isAvatar: Bool

    public init(title: String, href: String? = nil, description: String = "", image: String? = nil, isAvatar: Bool = false) {
        self.title = title
        self.href = href
        self.description = description
        self.image = image
        self.isAvatar = isAvatar
    }
}

/// One piece of what someone is composing, in order.
public enum ComposeSegment: Hashable, Sendable {
    case text(String)
    /// `name` is what the composer showed; the server resolves the person by `userId` alone.
    case mention(userId: String, name: String)
}
