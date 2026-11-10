import Foundation
import Testing
@testable import EmberCore

/// The cards of a message whose `cards` is `cards`, read as a client reads a message.
private func cards(_ cards: String) throws -> [Card]? {
    let text = #"{"id":"m001","roomId":"r1","creator":{"id":"u2","name":"Grace"},"body":"","plainText":"","createdAt":"2026-10-12T10:00:00Z","cards":\#(cards)}"#
    return try EmberJSON.decoder().decode(Message.self, from: Data(text.utf8)).cards
}

/// The one card of an attachment whose parts are `parts`.
private func card(_ parts: String, _ extra: String = "") throws -> Card? {
    try cards(#"[{"source":"attachment"\#(extra),"parts":\#(parts)}]"#)?.first
}

/// The parts of an attachment whose parts are `parts`, or [] when the card goes.
private func parts(_ parts: String) throws -> [CardPart] {
    try card(parts)?.parts ?? []
}

/// `value` as JSON, to compare whatever the key order.
private func written(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: EmberJSON.encoder().encode(value))
}

/// A colour of 8-bit components, as `Card.accent` reads one.
private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> CardAccent {
    .rgb(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
}

private let link = CardButton(text: "Open", href: "https://example.com/open")

@Suite struct CardReadingTests {
    @Test func everySlackFixtureReadsAndWritesBackAsItCame() throws {
        #expect(slackCards.count == 10)
        for fixture in slackCards {
            let read = try #require(try cards(fixture.cards), "\(fixture.name)")
            #expect(read.count == 1, "\(fixture.name)")
            #expect(try written(read) == json(fixture.cards), "\(fixture.name)")
        }
    }

    @Test func anAlertmanagerAlert() throws {
        let card = try #require(try cards(slackCards[0].cards)?.first)
        #expect(card == Card(source: .attachment, color: "danger", parts: [
            .title(text: "[FIRING:2] InstanceDown (node-exporter production)", href: "https://alertmanager.example.com/#/alerts?receiver=slack-alerts"),
        ]))
        #expect(card.accent == .danger)
        #expect(card.label == "[FIRING:2] InstanceDown (node-exporter production)")
    }

    @Test func aGrafanaFooterIsAMoment() throws {
        let card = try #require(try cards(slackCards[1].cards)?.first)
        #expect(card.parts.last == .footer(text: "Grafana v12.2.0", icon: "https://grafana.com/static/assets/img/fav32.png", at: Date(timeIntervalSince1970: 1_792_584_000)))
        #expect(card.accent == rgb(0xd6, 0x32, 0x32))
    }

    @Test func aGitLabPipeline() throws {
        let card = try #require(try cards(slackCards[2].cards)?.first)
        #expect(card.accent == .good)
        #expect(card.parts.first == .author(name: "Ada Lovelace (ada)", href: "https://gitlab.example.com/ada", icon: "https://gitlab.example.com/uploads/-/system/user/avatar/1/avatar.png"))
        guard case let .fields(fields) = card.parts[2] else { Issue.record("\(card.parts[2])"); return }
        #expect(fields.map(\.title) == ["Branch", "Commit"])
        #expect(fields.allSatisfy { $0.short })
        #expect(card.label == "Pipeline #1042 has passed in 02:14")
    }

    @Test func anUptimeKumaMonitor() throws {
        let card = try #require(try cards(slackCards[6].cards)?.first)
        #expect(card.label == "Example API")
        #expect(card.parts[1] == .context([.html("<p><em>Production / APIs</em></p>")]))
        guard case let .section(html, fields, thumb, button) = card.parts[2] else { Issue.record("\(card.parts[2])"); return }
        #expect(html == nil && thumb == nil && button == nil)
        #expect(fields.count == 2 && fields.allSatisfy { $0.title == nil && $0.short })
        #expect(card.parts[3] == .buttons([
            CardButton(text: "Visit Uptime Kuma", href: "https://status.example.com/dashboard/12"),
            CardButton(text: "Visit site", href: "https://api.example.com/"),
        ]))
    }

    @Test func aDeploySummary() throws {
        let card = try #require(try cards(slackCards[8].cards)?.first)
        #expect(card.source == .blocks && card.color == nil && card.accent == nil)
        #expect(card.label == "Deployed web 2.4.0 🚀")
        #expect(card.parts[1] == .section(
            html: "<p><strong>3 services</strong> are live in <strong>production</strong>.</p>", fields: [], thumb: nil,
            button: CardButton(text: "Release notes", href: "https://example.com/releases/2.4.0", style: .primary)
        ))
        guard case let .table(rows, columns) = card.parts[2] else { Issue.record("\(card.parts[2])"); return }
        #expect(rows.count == 4 && rows.allSatisfy { $0.count == 3 })
        #expect(columns == [CardColumn(align: .left, wrap: true), CardColumn(align: .right), CardColumn(align: .right)])
        #expect(card.parts[3] == .divider)
        #expect(card.parts[4] == .context([
            .image(CardImage(url: "https://example.com/ada.png", alt: "Ada Lovelace")),
            .html("<p>Started by <strong>Ada Lovelace</strong> at Oct 21, 2026 12:00 PM UTC</p>"),
        ]))
    }

    @Test func aCarouselOfRooms() throws {
        let card = try #require(try cards(slackCards[9].cards)?.first)
        #expect(card.label == nil)
        guard case let .tiles(tiles) = card.parts[1] else { Issue.record("\(card.parts[1])"); return }
        #expect(tiles.map(\.title) == ["Lovelace", "Hopper"])
        #expect(tiles[0].hero == CardImage(url: "https://example.com/rooms/lovelace.jpg", alt: "Lovelace, a room with a long table"))
        #expect(tiles[0].body == "<p>Free until <strong>4 PM</strong></p>" && tiles[0].subtext == nil)
        #expect(tiles[1].subtext == "<p>Has a screen</p>")
        #expect(tiles[0].buttons.map(\.text) == ["Book", "Floor plan"])
    }

    @Test func anUnknownKindOrAMalformedPartIsLeftOut() throws {
        #expect(try parts(#"[{"kind":"poll","question":"?"},{"kind":"header","text":"Kept"},{"kind":"title"},{"kind":"title","text":"   "},"title",null,7]"#) == [.header(text: "Kept")])
        #expect(try parts(#"[{"kind":"image","image":{"alt":"no url"}},{"kind":"text","html":""},{"kind":"buttons","buttons":[{"text":"No href"}]}]"#) == [])
        #expect(try parts(#"[{"kind":"section"},{"kind":"fields","fields":[]},{"kind":"context","items":[]},{"kind":"tiles","tiles":[]},{"kind":"footer","icon":"https://example.com/i.png"}]"#) == [])
    }

    @Test func aCardOfAnUnknownSourceOrOfNothingGoes() throws {
        #expect(try cards(#"[{"source":"canvas","parts":[{"kind":"header","text":"Hi"}]},{"parts":[{"kind":"header","text":"Hi"}]}]"#) == nil)
        #expect(try cards(#"[{"source":"blocks","parts":[{"kind":"divider"},{"kind":"divider"}]}]"#) == nil)
        #expect(try cards(#"[{"source":"attachment","parts":[{"kind":"divider"}]}]"#) == nil)
        #expect(try cards(#"[{"source":"attachment","parts":"none"}]"#) == nil)
        #expect(try cards(#"[{"source":"blocks","parts":[{"kind":"divider"},{"kind":"header","text":"Kept"}]}]"#)?.first?.parts == [.divider, .header(text: "Kept")])
    }

    @Test func anAttachmentWithOnlyAPretextStays() throws {
        let card = try #require(try card("[]", #","pretext":"<p>Only this</p>""#))
        #expect(card.pretext == "<p>Only this</p>" && card.parts.isEmpty)
    }

    @Test func onlyAnAttachmentHasABarAPretextAndAThumbnail() throws {
        let blocks = try #require(try cards(#"[{"source":"blocks","color":"good","pretext":"<p>Above</p>","thumb":{"url":"https://example.com/t.png"},"parts":[{"kind":"header","text":"Hi"}]}]"#)?.first)
        #expect(blocks == Card(source: .blocks, parts: [.header(text: "Hi")]))
        let attachment = try #require(try card(#"[{"kind":"header","text":"Hi"}]"#, #","thumb":{"url":"https://example.com/t.png"}"#))
        #expect(attachment.thumb == CardImage(url: "https://example.com/t.png"))
    }

    @Test func aColourIsReadInLowercaseOrNotAtAll() throws {
        for (sent, read) in [("#36a64f", "#36a64f"), ("#ABCDEF", "#abcdef"), ("DANGER", "danger"), ("DaNgEr", "danger"), ("Warning", "warning")] {
            #expect(try card(#"[{"kind":"header","text":"Hi"}]"#, #","color":"\#(sent)""#)?.color == read)
        }
        for sent in ["\"red\"", "\"#fff\"", "\"#36a64f; background: url(x)\"", "\"javascript:alert(1)\"", "7", "\"#36a64g\""] {
            let card = try #require(try card(#"[{"kind":"header","text":"Hi"}]"#, #","color":\#(sent)"#))
            #expect(card.color == nil, "\(sent)")
        }
    }

    @Test func whatAPartLeavesOutTakesItsDefault() throws {
        #expect(try parts(#"[{"kind":"fields","fields":[{"short":true},"field",{"title":"Kept","short":"yes"}]}]"#) == [.fields([CardField(title: "Kept", html: "", short: false)])])
        #expect(try parts(#"[{"kind":"image","image":{"url":"https://example.com/i.png"}}]"#) == [.image(CardImage(url: "https://example.com/i.png", alt: ""), title: nil)])
        #expect(try parts(#"[{"kind":"buttons","buttons":[{"text":"Go","href":"https://example.com","style":"link"}]}]"#) == [.buttons([CardButton(text: "Go", href: "https://example.com")])])
        #expect(try parts(#"[{"kind":"section","html":"<p>Hi</p>","fields":[]}]"#) == [.section(html: "<p>Hi</p>", fields: [], thumb: nil, button: nil)])
        #expect(try parts(#"[{"kind":"footer","text":"Only text"}]"#) == [.footer(text: "Only text", icon: nil, at: nil)])
        #expect(try parts(#"[{"kind":"footer","at":0}]"#) == [.footer(text: nil, icon: nil, at: Date(timeIntervalSince1970: 0))])
        #expect(try parts(#"[{"kind":"footer","at":1e300}]"#) == [])
    }

    @Test func aTableKeepsRowsAndColumnsItCanRead() throws {
        let cells = (1 ... 21).map { #""<p>\#($0)</p>""# }.joined(separator: ",")
        let read = try parts(#"[{"kind":"table","rows":["row",[],[7,\#(cells)]],"columns":[{"align":"justify","wrap":"yes"},null,{"align":"center","wrap":true}]}]"#)
        guard case let .table(rows, columns)? = read.first else { Issue.record("\(read)"); return }
        #expect(rows.count == 1)
        #expect(rows[0].count == 20 && rows[0][0] == "" && rows[0][1] == "<p>1</p>")
        #expect(columns == [CardColumn(), CardColumn(), CardColumn(align: .center, wrap: true)])
        #expect(try parts(#"[{"kind":"table","rows":[[]]}]"#) == [])
    }

    @Test func aTileNeedsMoreThanAnIcon() throws {
        let icon = #"{"url":"https://example.com/i.png"}"#
        let buttons = (1 ... 4).map { #"{"text":"B\#($0)","href":"https://example.com/\#($0)"}"# }.joined(separator: ",")
        let read = try parts(#"[{"kind":"tiles","tiles":[{"icon":\#(icon)},{"title":"Kept","buttons":[{"text":"No href"},\#(buttons)]}]}]"#)
        guard case let .tiles(tiles)? = read.first else { Issue.record("\(read)"); return }
        #expect(tiles.count == 1)
        #expect(tiles[0].buttons.map(\.text) == ["B1", "B2", "B3"])
        #expect(try parts(#"[{"kind":"tiles","tiles":[{"icon":\#(icon)}]}]"#) == [])
    }

    @Test func aContextItemNamingAnImageIsOne() throws {
        #expect(try parts(#"[{"kind":"context","items":[{"image":{"url":"https://example.com/i.png"}},{"html":"<p>Gone</p>","image":7},{"html":""},{"html":"<p>Kept</p>"}]}]"#) == [
            .context([.image(CardImage(url: "https://example.com/i.png")), .html("<p>Kept</p>")]),
        ])
    }

    @Test func plainTextAndAddressesHaveLimits() throws {
        let long = String(repeating: "a", count: 3001)
        #expect(try parts(#"[{"kind":"header","text":"\#(long)"}]"#) == [])
        #expect(try parts(#"[{"kind":"header","text":"\#(long.dropLast())"}]"#).count == 1)
        #expect(try parts(#"[{"kind":"title","text":"Hi","href":"https://example.com/\#(long)"}]"#) == [.title(text: "Hi", href: nil)])
    }

    @Test func aMessageHoldsUpToAHundredAndOneCards() throws {
        let one = #"{"source":"blocks","parts":[{"kind":"header","text":"Hi"}]}"#
        #expect(try cards("[" + Array(repeating: one, count: 102).joined(separator: ",") + "]")?.count == 101)
    }

    @Test func aPartListIsCutBeforeItIsRead() throws {
        let gone = Array(repeating: #"{"kind":"poll"}"#, count: 60).joined(separator: ",")
        #expect(try cards(#"[{"source":"blocks","parts":[\#(gone),{"kind":"header","text":"Too late"}]}]"#) == nil)
    }

    @Test func aMessageWithoutCardsHasNone() throws {
        #expect(try cards("null") == nil)
        #expect(try cards("[]") == nil)
        #expect(try cards(#"{"source":"blocks"}"#) == nil)
        #expect(try cards(#""cards""#) == nil)
        #expect(try cards("[7, null]") == nil)
        let plain = try EmberJSON.decoder().decode(Message.self, from: Data(messageJSON.utf8))
        #expect(plain.cards == nil)
        guard case let .object(object) = try written(plain) else { Issue.record("not an object"); return }
        #expect(object["cards"] == nil)
    }

    @Test func aCardDecodedOnItsOwnThrowsWhenItShowsNothing() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Card.self, from: Data(#"{"source":"blocks","parts":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CardPart.self, from: Data(#"{"kind":"poll"}"#.utf8))
        }
        #expect((try? JSONDecoder().decode(CardColumn.self, from: Data("7".utf8))) == CardColumn())
    }

    @Test func everyKindWritesBackAsItReads() throws {
        let image = CardImage(url: "https://example.com/i.png", alt: "An image")
        let card = Card(source: .attachment, color: "warning", pretext: "<p>Above</p>", thumb: image, parts: [
            .author(name: "Ada", href: "https://example.com/ada", icon: "https://example.com/ada.png"),
            .author(name: "Grace", href: nil, icon: nil),
            .title(text: "A title", href: nil),
            .header(text: "A header"),
            .text(html: "<p>Text</p>"),
            .section(html: nil, fields: [CardField(html: "<p>Value</p>")], thumb: image, button: link),
            .section(html: "<p>Only html</p>", fields: [], thumb: nil, button: nil),
            .fields([CardField(title: "Only a title"), CardField(title: "Both", html: "<p>Value</p>", short: true)]),
            .image(image, title: "Titled"),
            .context([.html("<p>Small</p>"), .image(image)]),
            .divider,
            .buttons([link, CardButton(text: "Stop", href: "https://example.com/stop", style: .danger)]),
            .table(rows: [["<p>a</p>", ""], ["<p>b</p>"]], columns: [CardColumn(align: .right, wrap: true)]),
            .tiles([CardTile(hero: image, icon: image, title: "T", subtitle: "S", body: "<p>B</p>", subtext: "<p>s</p>", buttons: [link]), CardTile(title: "Only a title")]),
            .footer(text: "Footer", icon: "https://example.com/f.png", at: Date(timeIntervalSince1970: 1_792_584_000.5)),
            .footer(text: nil, icon: nil, at: Date(timeIntervalSince1970: 1_792_584_000)),
        ])
        let data = try EmberJSON.encoder().encode([card])
        #expect(try cards(String(decoding: data, as: UTF8.self)) == [card])
        #expect(try EmberJSON.decoder().decode(Card.self, from: EmberJSON.encoder().encode(card)) == card)
        let footer = try written(CardPart.footer(text: nil, icon: nil, at: Date(timeIntervalSince1970: 1_792_584_000)))
        #expect(footer == json(#"{"kind":"footer","at":1792584000}"#))
    }

    @Test func aMessageWritesItsCardsBack() throws {
        var carded = message("m001")
        carded.cards = [Card(source: .blocks, parts: [.header(text: "Hi")])]
        let read = try EmberJSON.decoder().decode(Message.self, from: EmberJSON.encoder().encode(carded))
        #expect(read.cards == carded.cards)
        #expect(Message(id: "m2", clientMessageId: "c2", roomId: "r1", creator: grace, body: "", plainText: "", createdAt: noon(), cards: carded.cards).cards == carded.cards)
    }
}

@Suite struct CardFrameTests {
    private let withCards = #"{"id":"m001","clientMessageId":"c1","roomId":"r1","creator":{"id":"u2","name":"Grace"},"body":"","plainText":"Hi","createdAt":"2026-10-12T10:00:00Z","cards":[{"source":"blocks","parts":[{"kind":"header","text":"Hi"},{"kind":"poll"}]}]}"#
    private let you = #"{"id":"u1","name":"Ada"}"#

    @Test func aCreatedMessageBringsItsCards() {
        guard case let .messageCreated(created, 3) = ServerFrame(text: #"{"type":"message.created","message":\#(withCards),"seq":3}"#) else {
            Issue.record("message.created"); return
        }
        #expect(created.cards == [Card(source: .blocks, parts: [.header(text: "Hi")])])
        guard case let .messageCreated(plain, 4) = ServerFrame(text: #"{"type":"message.created","message":\#(messageJSON),"seq":4}"#) else {
            Issue.record("message.created"); return
        }
        #expect(plain.cards == nil)
    }

    @Test func aWelcomeBringsItsMessagesCards() {
        let frame = ServerFrame(text: #"{"type":"welcome","you":\#(you),"present":[],"seq":7,"messages":[\#(withCards),\#(messageJSON)],"hasMore":false,"hasNewer":false,"around":null}"#)
        guard case let .welcome(_, _, _, page) = frame else { Issue.record("\(frame)"); return }
        #expect(page.messages.map { $0.cards?.count } == [1, nil])
    }

    @Test func cardsTheBuildCannotReadNeverLoseTheMessage() {
        let unreadable = withCards.replacingOccurrences(of: #""cards":["#, with: #""cards":[7,{"source":"canvas"},"#)
        guard case let .messageUpdated(updated, 5) = ServerFrame(text: #"{"type":"message.updated","message":\#(unreadable),"seq":5}"#) else {
            Issue.record("message.updated"); return
        }
        #expect(updated.cards?.count == 1)
        let worse = withCards.replacingOccurrences(of: #""cards":["#, with: #""cards":{"oops":["#) + "}"
        guard case let .messageUpdated(kept, 6) = ServerFrame(text: #"{"type":"message.updated","message":\#(worse),"seq":6}"#) else {
            Issue.record("message.updated with unreadable cards"); return
        }
        #expect(kept.cards == nil)
    }

    @Test func anUpdateWithoutCardsTakesThemAway() {
        var carded = message("m001")
        carded.cards = [Card(source: .blocks, parts: [.header(text: "Hi")])]
        var timeline = Timeline()
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 1, page: TimelinePage(messages: [carded], hasMore: false, hasNewer: false, around: nil)))
        #expect(timeline.message("m001")?.cards?.count == 1)
        _ = timeline.apply(.messageUpdated(message("m001", text: "Edited"), seq: 2))
        #expect(timeline.message("m001")?.cards == nil)
    }
}

@Suite struct CardViewTests {
    @Test func theLabelIsTheFirstTitleOrHeader() {
        #expect(Card(source: .attachment, parts: [.text(html: "<p>a</p>"), .header(text: "First"), .title(text: "Second", href: nil)]).label == "First")
        #expect(Card(source: .attachment, parts: [.author(name: "Ada", href: nil, icon: nil)]).label == nil)
    }

    @Test func theAccent() {
        func accent(_ color: String?) -> CardAccent? { Card(source: .attachment, color: color, parts: []).accent }
        #expect(accent("good") == .good && accent("WARNING") == .warning && accent("Danger") == .danger)
        #expect(accent("#36A64F") == rgb(0x36, 0xa6, 0x4f))
        #expect(accent("#000000") == .rgb(red: 0, green: 0, blue: 0) && accent("#ffffff") == .rgb(red: 1, green: 1, blue: 1))
        for color in [nil, "", "red", "#fff", "#36a64g", "36a64f", "#36a64f0", "#+1a64f"] {
            #expect(accent(color) == nil, "\(color ?? "nil")")
        }
    }

    @Test func aTileLaysOutDangerFirstAndPrimaryLast() {
        let primary = CardButton(text: "Book", href: "https://example.com/1", style: .primary)
        let stop = CardButton(text: "Stop", href: "https://example.com/2", style: .danger)
        let plan = CardButton(text: "Plan", href: "https://example.com/3")
        let cancel = CardButton(text: "Cancel", href: "https://example.com/4", style: .danger)
        let order = CardTile(title: "T", buttons: [primary, stop, plan, cancel]).buttonsInOrder
        #expect(order.leading == [stop, cancel])
        #expect(order.trailing == [plan, primary])
        #expect(CardTile(title: "T").buttonsInOrder.leading.isEmpty)
    }
}

@Suite struct CardAddressTests {
    /// Refuses any address with "bad" in it and shows the rest through a proxy.
    private let shown: (String) -> String? = { $0.contains("bad") ? nil : "https://proxy.test/?" + $0 }
    private let good = CardImage(url: "good.png", alt: "Good")
    private let bad = CardImage(url: "bad.png", alt: "Bad")
    private let shownGood = CardImage(url: "https://proxy.test/?good.png", alt: "Good")

    private func through(_ parts: [CardPart], thumb: CardImage? = nil, pretext: String? = nil) -> Card? {
        Card(source: .attachment, pretext: pretext, thumb: thumb, parts: parts).withAddresses(shown)
    }

    @Test func eachAddressIsTheOneShown() {
        let card = through([.author(name: "Ada", href: "good", icon: "good.png")], thumb: good)
        #expect(card == Card(source: .attachment, thumb: shownGood, parts: [.author(name: "Ada", href: "https://proxy.test/?good", icon: "https://proxy.test/?good.png")]))
    }

    @Test func aRefusedLinkOrIconLeavesItsText() {
        let card = through([
            .author(name: "Ada", href: "bad", icon: "bad.png"),
            .title(text: "Title", href: "bad"),
            .footer(text: "Footer", icon: "bad.png", at: nil),
        ], thumb: bad)
        #expect(card == Card(source: .attachment, parts: [
            .author(name: "Ada", href: nil, icon: nil), .title(text: "Title", href: nil), .footer(text: "Footer", icon: nil, at: nil),
        ]))
    }

    @Test func aRefusedImageGoes() {
        #expect(through([.image(bad, title: "Gone"), .header(text: "Kept")])?.parts == [.header(text: "Kept")])
        #expect(through([.image(good, title: "Kept")])?.parts == [.image(shownGood, title: "Kept")])
        #expect(through([.context([.image(bad), .html("<p>Kept</p>")])])?.parts == [.context([.html("<p>Kept</p>")])])
        #expect(through([.context([.image(bad)]), .header(text: "Kept")])?.parts == [.header(text: "Kept")])
        let section = CardPart.section(html: "<p>Kept</p>", fields: [], thumb: bad, button: CardButton(text: "Gone", href: "bad"))
        #expect(through([section])?.parts == [.section(html: "<p>Kept</p>", fields: [], thumb: nil, button: nil)])
    }

    @Test func aRefusedButtonGoesAndARowLeftEmptyWithIt() {
        let gone = CardButton(text: "Gone", href: "bad")
        let kept = CardButton(text: "Kept", href: "good", style: .primary)
        #expect(through([.buttons([gone, kept])])?.parts == [.buttons([CardButton(text: "Kept", href: "https://proxy.test/?good", style: .primary)])])
        #expect(through([.buttons([gone]), .header(text: "Kept")])?.parts == [.header(text: "Kept")])
    }

    @Test func aTileLeftWithNothingGoes() {
        let tiles = CardPart.tiles([
            CardTile(hero: bad, icon: good, buttons: [CardButton(text: "Gone", href: "bad")]),
            CardTile(hero: bad, icon: bad, title: "Kept"),
        ])
        #expect(through([tiles])?.parts == [.tiles([CardTile(title: "Kept")])])
        #expect(through([.tiles([CardTile(hero: bad)]), .header(text: "Kept")])?.parts == [.header(text: "Kept")])
    }

    @Test func aCardLeftWithNothingGoes() {
        #expect(through([.image(bad, title: nil), .divider]) == nil)
        #expect(through([.image(bad, title: nil)], pretext: "<p>Above</p>")?.parts == [])
        #expect(through([.text(html: "<p>No addresses</p>"), .table(rows: [["<p>a</p>"]], columns: [])])?.parts.count == 2)
    }

    @Test func aListKeepsTheCardsLeftWithSomething() {
        let cards = [
            Card(source: .blocks, parts: [.image(bad, title: nil)]),
            Card(source: .blocks, parts: [.header(text: "Kept")]),
        ]
        #expect(cards.withAddresses(shown) == [Card(source: .blocks, parts: [.header(text: "Kept")])])
    }
}
