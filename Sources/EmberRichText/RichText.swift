import Foundation

/// Entry points: a stored message body in, a native display model out, and composer input back
/// into the body the server stores.
public enum RichText {
    /// What a stored message body shows. `plainText` is the message's own plain text, which decides
    /// the emoji-only look and the "only a link" preview rule, and is what shows if the body cannot be
    /// read. `host` is the server's host, which a link preview may not point at. Never throws.
    public static func document(html: String, plainText: String, host: String) -> RichDocument {
        let emojiOnly = Emoji.isAllEmoji(plainText)
        guard let root = try? HTMLTreeBuilder.parse(html) else {
            return RichDocument(blocks: fallbackBlocks(plainText), isEmojiOnly: emojiOnly)
        }
        PreviewReader.removeSoloUnfurledLinkText(root, plainText: plainText, host: host)
        var blocks = DocumentConverter(host: host).blocks(from: root)
        // A body of only things this model cannot show (an image) still has its plain text, such as "[Image]".
        if blocks.isEmpty, hasUnshownMedia(root) { blocks = fallbackBlocks(plainText) }
        return RichDocument(blocks: blocks, isEmojiOnly: emojiOnly)
    }

    /// The body to send for text typed in plain: one paragraph, each line separated by `<br>`.
    public static func body(fromPlainText text: String) -> String {
        Composer.body(fromPlainText: text)
    }

    /// The body to send for a message with mentions, in the order it was written.
    public static func body(from segments: [ComposeSegment]) -> String {
        Composer.body(from: segments)
    }

    /// Text typed in plain as segments for `body(from:)`: each "@" and the name of someone in
    /// `mentions` (a user id to the name the composer wrote for them) mentions them, where it stands
    /// as a whole name rather than the start of a longer word.
    public static func segments(_ text: String, mentions: [String: String]) -> [ComposeSegment] {
        Composer.segments(text, mentions: mentions)
    }

    /// Where in `text` `segments` finds each mention, "@" and name, in order: what a composer shows
    /// as a mention while it's being written.
    public static func mentionRanges(in text: String, mentions: [String: String]) -> [Range<String.Index>] {
        Composer.matches(text, mentions: mentions).map(\.range)
    }

    /// Whether the body holds something the model cannot show, whose plain text ("[Image]") is the best stand-in.
    private static func hasUnshownMedia(_ root: HTMLNode) -> Bool {
        let media: Set<String> = [PreviewReader.attachmentTag, "img", "video", "audio", "embed", "source"]
        return root.descendantElements().contains { media.contains($0.name) }
    }

    private static func fallbackBlocks(_ plainText: String) -> [RichBlock] {
        guard !PreviewReader.isBlank(plainText) else { return [] }
        var inlines: [RichInline] = []
        let lines = plainText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            if index > 0 { inlines.append(.lineBreak) }
            if !line.isEmpty { inlines.append(.text(String(line), [])) }
        }
        return [.paragraph(inlines)]
    }
}
