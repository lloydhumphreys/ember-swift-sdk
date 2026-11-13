import EmberRichText

extension RichText {
    /// A link's preview as a body carries it, to put after the paragraph with the link, as the web
    /// composer does. `RoomSession.send(body:plainText:previews:)` adds it for you.
    public static func previewAttachment(_ preview: LinkPreview) -> String {
        previewAttachment(title: preview.title, url: preview.url, description: preview.description, image: preview.image)
    }
}

/// `body` with each preview's attachment after it.
func withPreviews(_ body: String, _ previews: [LinkPreview]) -> String {
    body + previews.map { RichText.previewAttachment($0) }.joined()
}
