import Testing
@testable import EmberRichText

private let host = "once.campfire.test"

private func plain(_ text: String) -> RichInline { .text(text, []) }

@Suite("Card addresses")
struct CardAddressTests {
    @Test func anAbsoluteWebAddressIsKept() {
        for value in [
            "http://example.com/page", "https://example.com/image.png", "https://xn--80aswg.xn--p1ai/page",
            "https://example.com/a%20b?q=a b|c#top?x", "https://alertmanager.example.com/#/alerts?receiver=slack-alerts",
        ] {
            #expect(CardText.address(value, host: host) == value, "\(value)")
        }
    }

    @Test func anythingElseIsLeftOut() {
        let refused: [String?] = [
            nil, "", "   ", "javascript:alert(1)", "data:text/html,pwned", "vbscript:msgbox(1)", "mailto:nobody",
            "//example.com/image.png", "/rooms/1", "rooms/1", "http://exa mple.com/ ", "https:/rooms/1", "https:rooms/1",
            "http:/rooms/1", "https://", "http://:80/rooms/1", "https://.../x", "https://example.com/a b", "https://example.com/%zz",
            "https://example.com/#a b", "https://example.com/#a#b", "https://exa\"mple.com/",
        ]
        for value in refused {
            #expect(CardText.address(value, host: host) == nil, "\(value ?? "nil")")
        }
    }

    @Test func theServersOwnHostIsLeftOutHoweverItIsWritten() {
        for value in [
            "https://once.campfire.test/rooms/1", "http://once.campfire.test/rooms/1", "https://ONCE.Campfire.Test/rooms/1",
            "https://once.campfire.test./rooms/1", "https://%6fnce.campfire.test/rooms/1",
        ] {
            #expect(CardText.address(value, host: host) == nil, "\(value)")
        }
        #expect(CardText.address("https://example.com/page", host: host) == "https://example.com/page")
    }

    @Test func aHostMustBeANameWithADot() {
        for value in [
            "http://127.0.0.1/rooms/1", "http://2130706433/rooms/1", "http://0177.0.0.1/rooms/1", "http://0x7f.0.0.1/rooms/1",
            "http://1.2.3.0xff/rooms/1", "http://[::1]/rooms/1", "http://localhost/rooms/1", "https://203.0.113.10/image.png",
            "https://intranet/image.png", "https://%77ww.example.com/x.png",
        ] {
            #expect(CardText.address(value, host: host) == nil, "\(value)")
        }
    }
}

@Suite("Card folding")
struct CardFoldTests {
    @Test func sevenHundredCharactersFitAndOneMoreFolds() {
        #expect(!CardText.isLong(html: "<p>\(String(repeating: "a", count: 700))</p>"))
        #expect(CardText.isLong(html: "<p>\(String(repeating: "a", count: 701))</p>"))
        // Characters count as JavaScript's do, in UTF-16.
        #expect(!CardText.isLong(html: "<p>\(String(repeating: "🚀", count: 350))</p>"))
        #expect(CardText.isLong(html: "<p>\(String(repeating: "🚀", count: 351))</p>"))
        // Entities count as what they read.
        #expect(!CardText.isLong(html: "<p>\(String(repeating: "&amp;", count: 700))</p>"))
    }

    @Test func fiveLineBreaksFitAndSixFold() {
        #expect(!CardText.isLong(html: "<p>1<br>2<br>3<br>4<br>5<br>6</p>"))
        #expect(CardText.isLong(html: "<p>1<br>2<br>3<br>4<br>5<br>6<br>7</p>"))
        #expect(!CardText.isLong(html: "1<br>2<br>3<br>4<br>5<br>6"))
    }

    @Test func eachBlockAfterTheFirstStartsALine() {
        #expect(!CardText.isLong(html: String(repeating: "<p>x</p>", count: 6)))
        #expect(CardText.isLong(html: String(repeating: "<p>x</p>", count: 7)))
        #expect(CardText.isLong(html: "<ul>" + String(repeating: "<li>x</li>", count: 7) + "</ul>"))
        #expect(CardText.isLong(html: "<h1>a</h1><div>b</div><blockquote>c</blockquote><pre>d</pre><h6>e</h6><p>f</p><li>g</li>"))
    }

    @Test func aBlockThatStartsWithABlockLeavesTheLineToIt() {
        #expect(!CardText.isLong(html: String(repeating: "<blockquote><p>x</p></blockquote>", count: 6)))
        #expect(CardText.isLong(html: String(repeating: "<blockquote>x</blockquote>", count: 7)))
        #expect(!CardText.isLong(html: "<div><div><div><div><div><div><p>x</p></div></div></div></div></div></div>"))
    }

    @Test func aNewlineInTextIsALine() {
        #expect(!CardText.isLong(html: "<pre>a\nb\nc\nd\ne\nf</pre>"))
        #expect(CardText.isLong(html: "<pre>a\nb\nc\nd\ne\nf\ng</pre>"))
    }

    @Test func theSlackFixturesFoldAsTheWebsDo() {
        let grafana = "<p>**Firing**<br><br>Value: A=97.2<br>Labels:<br> - alertname = HighCPU<br> - instance = web-1<br> - env = production<br>Annotations:<br> - summary = CPU above 90% for 5 minutes<br>Source: https://grafana.example.com/alerting/grafana/cpu-high/view?orgId=1<br>Silence: https://grafana.example.com/alerting/silence/new?alertmanager=grafana&amp;matcher=alertname%3DHighCPU<br>Dashboard: https://grafana.example.com/d/node-overview?orgId=1</p>"
        #expect(CardText.isLong(html: grafana))
        #expect(!CardText.isLong(html: "<p>Open the sign-in page in Safari 18 &amp; sign in: the page reloads.</p>"))
    }

    @Test func textItCannotReadNeverFolds() {
        #expect(!CardText.isLong(html: ""))
        #expect(!CardText.isLong(html: String(repeating: "<div>", count: 500) + String(repeating: "a", count: 800)))
    }
}

@Suite("Card text")
struct CardDocumentTests {
    private func document(_ html: String) -> RichDocument { CardText.document(html: html, host: host) }

    @Test func styledTextAndLinks() {
        let doc = document("<p>You have a new request:<br><strong><a href=\"https://example.com/people/fred\">Fred Enriquez</a></strong> <em>now</em> <code>v2</code></p>")
        #expect(doc.blocks == [.paragraph([
            plain("You have a new request:"), .lineBreak,
            .link(url: "https://example.com/people/fred", [.text("Fred Enriquez", .bold)]), plain(" "),
            .text("now", .italic), plain(" "), .text("v2", .code),
        ])])
    }

    @Test func anEscapedTagIsText() {
        let doc = document("<p><a href=\"https://gitea.example.com/acme/web/commit/1a2b3c4d5e6f\">1a2b3c4</a>: Keep &lt;br&gt; in previews</p>")
        #expect(doc.blocks == [.paragraph([
            .link(url: "https://gitea.example.com/acme/web/commit/1a2b3c4d5e6f", [plain("1a2b3c4")]), plain(": Keep <br> in previews"),
        ])])
    }

    @Test func listsCodeAndQuotes() {
        let doc = document("<ul><li>One</li><li>Two</li></ul><pre>let x = 1\nlet y = 2</pre><blockquote>Quoted</blockquote>")
        #expect(doc.blocks == [
            .list(ordered: false, start: nil, items: [[.paragraph([plain("One")])], [.paragraph([plain("Two")])]]),
            .codeBlock(language: nil, code: "let x = 1\nlet y = 2"),
            .quote([.paragraph([plain("Quoted")])]),
        ])
    }

    @Test func neverEmojiOnlyAndALoneLinkStays() {
        #expect(!document("<p>🚀</p>").isEmojiOnly)
        #expect(document("<p>🚀</p>").blocks == [.paragraph([plain("🚀")])])
        let link = "<p><a href=\"https://example.com/\">https://example.com/</a></p>"
        #expect(document(link).blocks == [.paragraph([.link(url: "https://example.com/", [plain("https://example.com/")])])])
    }

    @Test func textItCannotReadShowsNothing() {
        #expect(document(String(repeating: "<div>", count: 500)).blocks == [])
        #expect(document("").blocks == [])
    }
}
