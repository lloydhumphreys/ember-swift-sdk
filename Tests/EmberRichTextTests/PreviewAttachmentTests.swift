import Testing
@testable import EmberRichText

// The stored form is from packages/richtext/src/previews.test.ts, "stores a preview": the content is
// `previewContent`, and the attribute escapes & < > " but leaves ' as it is.

private let host = "ember.example"

/// `content`, as the server's serializer writes it into an attribute.
private func attribute(_ content: String) -> String {
    content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func stored(_ content: String) -> String {
    #"<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="\#(attribute(content))"></action-text-attachment>"#
}

private func previews(_ html: String) -> [RichPreview] {
    RichText.document(html: html, plainText: "x", host: host).blocks.compactMap {
        if case let .preview(preview) = $0 { preview } else { nil }
    }
}

@Suite struct PreviewAttachmentTests {
    @Test func writesWhatTheServerStores() {
        let markup = RichText.previewAttachment(title: "Title", url: "https://example.com/page", description: "", image: "https://example.com/i.png")
        let content = #"<actiontext-opengraph-embed><div class="og-embed gap"><div class="og-embed__content">"#
            + #"<div class="og-embed__title"><a href="https://example.com/page" rel="noreferrer" target="_blank">Title</a></div>"#
            + #"<div class="og-embed__description"></div></div>"#
            + #"<div class="og-embed__image"><img src="https://example.com/i.png" class="image center" alt=""></div>"#
            + #"</div></actiontext-opengraph-embed>"#
        #expect(markup == stored(content))
    }

    @Test func withoutAnImageThereIsNoImage() {
        let markup = RichText.previewAttachment(title: "T", url: "https://example.com/", description: "D", image: nil)
        #expect(!markup.contains("og-embed__image"))
        #expect(markup.contains("og-embed__description&quot;&gt;D&lt;"))
    }

    @Test func escapesItsTextTwiceAsTheWebDoes() {
        let markup = RichText.previewAttachment(title: #"Tom & "Jerry's" <b>"#, url: "https://example.com/?a=1&b=2", description: "x < y", image: nil)
        // htmlEscape inside the content, then the attribute's own escaping over it.
        #expect(markup.contains("Tom &amp;amp; &amp;quot;Jerry&amp;#39;s&amp;quot; &amp;lt;b&amp;gt;"))
        #expect(markup.contains("href=&quot;https://example.com/?a=1&amp;amp;b=2&quot;"))
        #expect(markup.contains("x &amp;lt; y"))
        #expect(!markup.contains("'"))
    }

    @Test func shortensAndStripsAsTheServerStores() {
        let markup = RichText.previewAttachment(title: "  " + String(repeating: "😀", count: 300), url: "https://example.com/", description: String(repeating: "a", count: 600) + "  ", image: nil)
        let preview = try! #require(previews(markup).first)
        // Shortened before it's stripped, as `previewContent` does, so the spaces count.
        #expect(preview.title == String(repeating: "😀", count: 277) + "…")
        #expect(preview.description == String(repeating: "a", count: 559) + "…")
        #expect(RichText.previewAttachment(title: "  Title  ", url: "https://example.com/", description: "", image: nil).contains("&gt;Title&lt;/a&gt;"))
    }

    @Test func anXAvatarIsMarked() {
        let markup = RichText.previewAttachment(title: "Grace", url: "https://x.com/grace", description: "", image: "https://pbs.twimg.com/profile_images/1/a.jpg")
        #expect(markup.contains("og-embed gap og-embed--twitter-avatar"))
        #expect(previews(markup).first?.isAvatar == true)
        #expect(previews(RichText.previewAttachment(title: "G", url: "https://x.com/", description: "", image: "https://example.com/a.jpg")).first?.isAvatar == false)
    }

    @Test func readsBackAsThePreviewItWas() {
        let markup = RichText.previewAttachment(title: #"Tom & "Jerry's" <b>"#, url: "https://example.com/page", description: "A & B", image: "https://example.com/i.png")
        let document = RichText.document(html: "<p>Look</p>" + markup, plainText: "Look", host: host)
        #expect(document.blocks == [
            .paragraph([.text("Look", [])]),
            .preview(RichPreview(title: #"Tom & "Jerry's" <b>"#, href: "https://example.com/page", description: "A & B", image: "https://example.com/i.png")),
        ])
    }

    @Test func aMessageThatIsOnlyItsLinkShowsOnlyThePreview() {
        let markup = RichText.previewAttachment(title: "Page", url: "https://example.com/page", description: "", image: nil)
        let document = RichText.document(html: "<p>https://example.com/page</p>" + markup, plainText: "https://example.com/page", host: host)
        #expect(document.blocks == [.preview(RichPreview(title: "Page", href: "https://example.com/page"))])
    }

    @Test func anEditKeepsThePreviewAsItIs() {
        let markup = RichText.previewAttachment(title: "Page", url: "https://example.com/page", description: "D", image: nil)
        let editable = EditableBody(body: "<p>Look</p>" + markup)
        #expect(editable.text == "Look")
        let edited = editable.body(editedTo: "Look here https://example.com/other")
        #expect(edited.hasSuffix(markup))
        // An edit adds no preview for a new link.
        #expect(edited.components(separatedBy: "action-text-attachment content-type").count == 2)
        #expect(previews(edited) == [RichPreview(title: "Page", href: "https://example.com/page", description: "D")])
    }
}
