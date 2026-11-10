import Testing
@testable import EmberRichText

private let host = "once.campfire.test"
private let userId = "0abcdefghijklmno"

private func document(_ html: String, plainText: String = "x") -> RichDocument {
    RichText.document(html: html, plainText: plainText, host: host)
}

private func plain(_ text: String) -> RichInline { .text(text, []) }

@Suite("Blocks")
struct BlockTests {
    @Test func paragraphsAndEmptyOnesDropped() {
        // From the server corpus: "lexxy paragraphs".
        let doc = document("<p>First</p><p>Second</p><p><br></p><p>Fourth</p>")
        #expect(doc.blocks == [.paragraph([plain("First")]), .paragraph([plain("Second")]), .paragraph([plain("Fourth")])])
    }

    @Test func plainTextBodyIsOneParagraph() {
        #expect(document("First post!").blocks == [.paragraph([plain("First post!")])])
    }

    @Test func lineBreaksStayAndEdgesAreTrimmed() {
        let doc = document("<p>one<br>two<br><br>three<br></p>")
        #expect(doc.blocks == [.paragraph([plain("one"), .lineBreak, plain("two"), .lineBreak, .lineBreak, plain("three")])])
    }

    @Test func whitespaceCollapsesLikeABrowser() {
        let doc = document("<p>  a \n\t b <b>c </b> d\u{00A0}\u{00A0}e </p>")
        #expect(doc.blocks == [.paragraph([plain("a b "), .text("c ", .bold), plain("d\u{00A0}\u{00A0}e")])])
    }

    @Test func headingsQuotesRulesAndCode() {
        let doc = document("<h2>Sub</h2><blockquote>Quoted <i>text</i></blockquote><hr><pre data-language=\"ruby\">def x<br>end</pre>")
        #expect(doc.blocks == [
            .heading(level: 2, [plain("Sub")]),
            .quote([.paragraph([plain("Quoted "), .text("text", .italic)])]),
            .rule,
            .codeBlock(language: "ruby", code: "def x\nend"),
        ])
    }

    @Test func codeBlockKeepsWhitespaceAndDropsTheFirstNewline() {
        let doc = document("<pre>\nline 1\n  line 2\n</pre>")
        #expect(doc.blocks == [.codeBlock(language: nil, code: "line 1\n  line 2")])
    }

    @Test func nestedListsAreItemsHoldingLists() {
        // The server corpus's "lexxy nested list".
        let doc = document("<ul><li>One<ul><li>Nested a</li><li>Nested b<ol><li>Deep</li></ol></li></ul></li><li>Two</li></ul>")
        let deep = RichBlock.list(ordered: true, start: nil, items: [[.paragraph([plain("Deep")])]])
        let nested = RichBlock.list(ordered: false, start: nil, items: [
            [.paragraph([plain("Nested a")])],
            [.paragraph([plain("Nested b")]), deep],
        ])
        #expect(doc.blocks == [.list(ordered: false, start: nil, items: [[.paragraph([plain("One")]), nested], [.paragraph([plain("Two")])]])])
    }

    @Test func orderedListStart() {
        let doc = document("<ol start=\"3\"><li value=\"3\">Three</li><li value=\"4\">Four</li></ol>")
        #expect(doc.blocks == [.list(ordered: true, start: 3, items: [[.paragraph([plain("Three")])], [.paragraph([plain("Four")])]])])
    }

    @Test func lexxyTableInAFigure() {
        let html = "<figure class=\"lexxy-content__table-wrapper\"><table><tbody><tr><th><p>Name</p></th><th><p>Role</p></th></tr><tr><td><p>Jason</p></td><td><p>CTO</p></td></tr></tbody></table></figure>"
        #expect(document(html).blocks == [.table(header: [[plain("Name")], [plain("Role")]], rows: [[[plain("Jason")], [plain("CTO")]]])])
    }

    @Test func tableWithoutHeaderAndWithTheadAndFooter() {
        let html = "<table><colgroup><col></colgroup><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody><tfoot><tr><td>f</td><td>g</td></tr></tfoot></table>"
        #expect(document(html).blocks == [.table(header: [[plain("A")], [plain("B")]], rows: [[[plain("1")], [plain("2")]], [[plain("f")], [plain("g")]]])])
        #expect(document("<table><tr><td>x</td></tr></table>").blocks == [.table(header: nil, rows: [[[plain("x")]]])])
    }

    @Test func trixDivsAndFormatting() {
        let html = "<div>Hello <strong>bold</strong> <em>it</em> <del>gone</del> <a href=\"https://example.com/\">link</a><br>second line</div><h1>Heading</h1>"
        let doc = document(html)
        #expect(doc.blocks == [
            .paragraph([
                plain("Hello "), .text("bold", .bold), plain(" "), .text("it", .italic), plain(" "), .text("gone", .strikethrough), plain(" "),
                .link(url: "https://example.com/", [plain("link")]), .lineBreak, plain("second line"),
            ]),
            .heading(level: 1, [plain("Heading")]),
        ])
    }

    @Test func stylesStack() {
        let doc = document("<p><b><i>both</i></b> <u>u</u><mark>m</mark><sup>2</sup><sub>i</sub><code>c</code></p>")
        #expect(doc.blocks == [.paragraph([
            .text("both", [.bold, .italic]), plain(" "), .text("u", .underline), .text("m", .highlight),
            .text("2", .superscript), .text("i", .subscript), .text("c", .code),
        ])])
    }

    @Test func unsafeLinksLoseTheirHref() {
        let doc = document("<p><a href=\"javascript:alert(1)\">bad</a> <a href=\" jav&#x09;ascript:x\">worse</a> <a href=\"/rooms/1\">ok</a></p>")
        #expect(doc.blocks == [.paragraph([plain("bad worse "), .link(url: "/rooms/1", [plain("ok")])])])
    }

    @Test func aFileLinkIsPlainText() {
        // The server's sanitiser strips `file:` hrefs, so the text stays and the link goes.
        let doc = document("<p><a href=\"file:///etc/hosts\">hosts</a> <a href=\"FILE:///x\">x</a></p>")
        #expect(doc.blocks == [.paragraph([plain("hosts x")])])
    }

    @Test func scriptAndStyleAreNotShown() {
        #expect(document("<p>a</p><script>alert(1)</script><style>p{}</style><p>b</p>").blocks == [.paragraph([plain("a")]), .paragraph([plain("b")])])
    }

    @Test func entitiesAreDecoded() {
        let doc = document("<p>a &lt; b &amp;&amp; c &#8364; &#128; &copy &notin; &unknown;</p>")
        #expect(doc.blocks == [.paragraph([plain("a < b && c € € © ∉ &unknown;")])])
    }

    @Test func brokenMarkupStillReads() {
        let doc = document("<p>one<p>two<ul><li>a<li>b</ul><b>unclosed")
        #expect(doc.blocks == [
            .paragraph([plain("one")]), .paragraph([plain("two")]),
            .list(ordered: false, start: nil, items: [[.paragraph([plain("a")])], [.paragraph([plain("b")])]]),
            .paragraph([.text("unclosed", .bold)]),
        ])
    }

    @Test func documentWrapperTagsAndTitleAreIgnored() {
        #expect(document("<!DOCTYPE html><html><head><title>t</title></head><body><p>b</p></body></html>").blocks == [.paragraph([plain("b")])])
    }

    @Test func tooDeepFallsBackToPlainText() {
        let html = String(repeating: "<b>", count: 450) + "deep"
        let doc = RichText.document(html: html, plainText: "line one\nline two", host: host)
        #expect(doc.blocks == [.paragraph([plain("line one"), .lineBreak, plain("line two")])])
    }

    @Test func deepButAllowedNestingDoesNotOverflow() {
        let html = String(repeating: "<b>", count: 300) + "deep"
        #expect(document(html).blocks == [.paragraph([.text("deep", .bold)])])
        let quotes = String(repeating: "<blockquote>", count: 390) + "q"
        #expect(!document(quotes).blocks.isEmpty)
        let lists = String(repeating: "<ul><li>", count: 190) + "l"
        #expect(!document(lists).blocks.isEmpty)
    }

    @Test func emptyBodyHasNoBlocks() {
        #expect(document("", plainText: "").blocks.isEmpty)
        #expect(document("<p><br></p>", plainText: "").blocks.isEmpty)
    }

    @Test func mediaOnlyBodyShowsItsPlainText() {
        let html = "<action-text-attachment content-type=\"image/png\" url=\"https://example.com/p.png\"></action-text-attachment>"
        #expect(document(html, plainText: "[Image]").blocks == [.paragraph([plain("[Image]")])])
    }
}

@Suite("Links")
struct LinkTests {
    @Test func bareAddressesAreLinked() {
        let doc = document("<p>See https://example.com/a?b=1&amp;c=2, www.example.com and me@example.com.</p>")
        #expect(doc.blocks == [.paragraph([
            plain("See "), .link(url: "https://example.com/a?b=1&c=2", [plain("https://example.com/a?b=1&c=2")]), plain(", "),
            .link(url: "http://www.example.com", [plain("www.example.com")]), plain(" and "),
            .link(url: "mailto:me@example.com", [plain("me@example.com")]), plain("."),
        ])])
    }

    @Test func trailingPunctuationAndBracketsAreHandledAsTheServerDoes() {
        let pieces = Autolink.pieces(in: "(https://example.com/a_(b)) https://x.org/a)")
        #expect(pieces == [
            Autolink.Piece(text: "(", href: nil),
            Autolink.Piece(text: "https://example.com/a_(b)", href: "https://example.com/a_(b)"),
            Autolink.Piece(text: ") ", href: nil),
            Autolink.Piece(text: "https://x.org/a", href: "https://x.org/a"),
            Autolink.Piece(text: ")", href: nil),
        ])
    }

    @Test func anchorsAreNotLinkedAgainAndCodeIsLeftAlone() {
        let doc = document("<p><a href=\"https://a.com/\">https://b.com/</a> <code>https://c.com/</code></p>")
        #expect(doc.blocks == [.paragraph([.link(url: "https://a.com/", [plain("https://b.com/")]), plain(" "), .text("https://c.com/", .code)])])
    }

    @Test func schemesAndLookalikes() {
        #expect(Autolink.pieces(in: "feed://x.org/a").first?.href == "feed://x.org/a")
        #expect(Autolink.pieces(in: "version 1.2.3 and a:b").allSatisfy { $0.href == nil })
    }
}

@Suite("Mentions and previews")
struct AttachmentTests {
    private let mention = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>"

    @Test func mentionByUserId() {
        let doc = document("<p>Hi \(mention), hello</p>")
        #expect(doc.blocks == [.paragraph([plain("Hi "), .mention(userId: userId), plain(", hello")])])
    }

    @Test func mentionOfAnAssistantAndOfNoOne() {
        let ember = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"ember\"></action-text-attachment>"
        #expect(document("<p>\(ember)</p>").blocks == [.paragraph([.mention(userId: "ember")])])
        // The server corpus's "sgid numeric data" shape: an sgid that names no user shows as a box.
        let bad = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"eyJfcmFpbHMi--x\"></action-text-attachment>"
        #expect(document("<p>\(bad)</p>").blocks == [.paragraph([plain("☒")])])
    }

    private let embedAttachment = "<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" content=\"&lt;actiontext-opengraph-embed&gt;&lt;div class=&quot;og-embed gap&quot;&gt;&lt;div class=&quot;og-embed__content&quot;&gt;&lt;div class=&quot;og-embed__title&quot;&gt;&lt;a href=&quot;https://basecamp.com/&quot;&gt;Basecamp&lt;/a&gt;&lt;/div&gt;&lt;div class=&quot;og-embed__description&quot;&gt;Project management&lt;/div&gt;&lt;/div&gt;&lt;div class=&quot;og-embed__image&quot;&gt;&lt;img src=&quot;https://basecamp.com/og.png&quot; class=&quot;image center&quot; alt=&quot;&quot;&gt;&lt;/div&gt;&lt;/div&gt;&lt;/actiontext-opengraph-embed&gt;\"></action-text-attachment>"

    private var lexxyEmbed: String { "<p><a href=\"https://basecamp.com/\">https://basecamp.com/</a></p>" + embedAttachment }

    @Test func soloUnfurledLinkShowsOnlyThePreview() {
        // The server corpus's "lexxy embed solo".
        let doc = document(lexxyEmbed, plainText: "https://basecamp.com/")
        #expect(doc.blocks == [.preview(RichPreview(title: "Basecamp", href: "https://basecamp.com/", description: "Project management", image: "https://basecamp.com/og.png"))])
    }

    @Test func linkWithOtherTextKeepsItsParagraph() {
        let doc = document("<p>Look: <a href=\"https://basecamp.com/\">https://basecamp.com/</a></p>" + embedAttachment, plainText: "Look: https://basecamp.com/")
        #expect(doc.blocks.count == 2)
        guard case .preview = doc.blocks.last else {
            Issue.record("expected a preview last")
            return
        }
    }

    @Test func trixAttributesAndTwitterAvatar() {
        let html = "<div><action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" filename=\"A post\" href=\"https://x.com/dhh/status/1\" url=\"https://pbs.twimg.com/profile_images/1/a.jpg\" caption=\"Words\"></action-text-attachment></div>"
        #expect(document(html).blocks == [.preview(RichPreview(title: "A post", href: "https://x.com/dhh/status/1", description: "Words", image: "https://pbs.twimg.com/profile_images/1/a.jpg", isAvatar: true))])
    }

    @Test func previewAddressesOnThisServerOrWithoutAHostAreDropped() {
        let html = "<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" filename=\"T\" href=\"https://once.campfire.test/x\" url=\"https://localhost/p.png\"></action-text-attachment>"
        #expect(document(html).blocks == [.preview(RichPreview(title: "T"))])
        #expect(PreviewReader.webURL("https://10.0.0.1/", host: host) == nil)
        #expect(PreviewReader.webURL("javascript:alert(1)", host: host) == nil)
        #expect(PreviewReader.webURL("https://Example.com./a", host: host) == "https://Example.com./a")
    }

    @Test func titleAndDescriptionAreTruncated() {
        let long = String(repeating: "a", count: 400)
        let longer = String(repeating: "b", count: 600)
        let html = "<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" filename=\"\(long)\" caption=\"\(longer)\"></action-text-attachment>"
        guard case .preview(let preview)? = document(html).blocks.first else {
            Issue.record("expected a preview")
            return
        }
        #expect(preview.title.count == 280 && preview.title.hasSuffix("…"))
        #expect(preview.description.count == 560 && preview.description.hasSuffix("…"))
    }

    @Test func tweetAddressesCompareEqual() {
        #expect(PreviewReader.normalizeTweetURL("https://x.com/dhh/status/1?s=20") == PreviewReader.normalizeTweetURL("https://twitter.com/dhh/status/1"))
        #expect(PreviewReader.normalizeTweetURL("plain text") == "plain text")
    }
}

@Suite("Emoji")
struct EmojiTests {
    @Test func emojiOnlyFollowsTheWebRule() {
        #expect(RichText.document(html: "<p>😄🤘</p>", plainText: "😄🤘", host: host).isEmojiOnly)
        #expect(RichText.document(html: "<p>👍🏽 ❤️ 🇬🇧 ©</p>", plainText: "👍🏽❤️🇬🇧©™", host: host).isEmojiOnly)
        #expect(!RichText.document(html: "<p>Haha! 😄</p>", plainText: "Haha! 😄", host: host).isEmojiOnly)
        #expect(!RichText.document(html: "", plainText: "", host: host).isEmojiOnly)
        // A joiner (as in a family) and a keycap digit are not matched by the web's regex either.
        #expect(!Emoji.isAllEmoji("👨\u{200D}👩"))
        #expect(!Emoji.isAllEmoji("1\u{FE0F}\u{20E3}"))
    }
}

@Suite("Composing")
struct ComposerTests {
    @Test func plainTextMatchesTheServersBodyFromPlainText() {
        // body.ts's own test.
        #expect(RichText.body(fromPlainText: "a < b & c\nd\r\ne\rf") == "<p>a &lt; b &amp; c<br>d<br>e<br>f</p>")
        #expect(RichText.body(fromPlainText: "\u{00A0}\n\n<b>\"quoted\"</b>") == "<p>&nbsp;<br><br>&lt;b&gt;\"quoted\"&lt;/b&gt;</p>")
        #expect(RichText.body(fromPlainText: "") == "<p></p>")
    }

    @Test func mentionsUseTheCanonicalAttachment() {
        let body = RichText.body(from: [.text("Hi "), .mention(userId: userId, name: "Ann"), .text(", ok\nbye")])
        #expect(body == "<p>Hi <action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>, ok<br>bye</p>")
    }

    @Test func invalidIdsBecomeText() {
        #expect(RichText.body(from: [.mention(userId: "7", name: "A<b")]) == "<p>@A&lt;b</p>")
    }

    @Test func composedBodiesReadBack() {
        let body = RichText.body(from: [.text("Hi "), .mention(userId: userId, name: "Ann"), .text(" & co\nline 2")])
        let doc = document(body, plainText: "Hi @Ann & co\nline 2")
        #expect(doc.blocks == [.paragraph([plain("Hi "), .mention(userId: userId), plain(" & co"), .lineBreak, plain("line 2")])])
    }
}
