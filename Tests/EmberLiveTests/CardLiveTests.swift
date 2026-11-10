import EmberRichText
import EmberSDK
import Foundation
import Testing

private extension CardPart {
    /// The wire's name for the part's kind.
    var kind: String {
        switch self {
        case .author: "author"
        case .title: "title"
        case .header: "header"
        case .text: "text"
        case .section: "section"
        case .fields: "fields"
        case .image: "image"
        case .context: "context"
        case .divider: "divider"
        case .buttons: "buttons"
        case .table: "table"
        case .tiles: "tiles"
        case .footer: "footer"
        }
    }
}

private extension Card {
    var kinds: [String] { parts.map(\.kind) }
}

/// Bot cards against a running server: Engineering's seeded card messages C1–C7, the scripted bots,
/// and what a refused edit looks like.
extension LiveTests {
    /// The room called engineering, opened and loaded.
    @MainActor
    func engineering(on client: EmberClient) async throws -> RoomSession {
        let sidebar = try await client.sidebar()
        let room = try #require(sidebar.rooms.first { $0.room.name?.lowercased() == "engineering" }?.room)
        let session = RoomSession(client: client, roomID: room.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return session
    }

    /// The seven seeded card messages, oldest first. Other tests add messages after them, so they're
    /// found by C1's header and the six messages that follow it.
    @MainActor
    func seededCards(in session: RoomSession) throws -> [Message] {
        let messages = session.timeline.messages
        let first = try #require(messages.firstIndex { $0.cards?.first?.label == "Deployed message-api v2.4.2 to production" })
        try #require(messages.count >= first + 7)
        return Array(messages[first ..< first + 7])
    }

    @MainActor @Test func engineeringsSeededCardsArriveTyped() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let seeds = try seededCards(in: session)
        #expect(seeds.map(\.creator.name) == ["Deploy Bot", "Uptime", "Uptime", "Deploy Bot", "Deploy Bot", "Deploy Bot", "Uptime"])
        let cards = try seeds.map { try #require($0.cards?.first) }
        #expect(seeds.allSatisfy { $0.cards?.count == 1 })

        // C1
        #expect(cards[0].source == .blocks)
        #expect(cards[0].kinds == ["header", "section", "section", "context"])
        if case let .section(_, fields, _, button) = cards[0].parts[1] {
            #expect(fields.isEmpty)
            #expect(button?.text == "Release notes")
            #expect(button?.style == .primary)
        } else { Issue.record("C1's second part isn't a section") }
        if case let .section(_, fields, _, button) = cards[0].parts[2] {
            #expect(fields.count == 2)
            #expect(fields.allSatisfy { $0.short })
            #expect(button == nil)
        } else { Issue.record("C1's third part isn't a section") }

        // C2
        #expect(cards[1].source == .attachment)
        #expect(cards[1].accent == .danger)
        #expect(cards[1].kinds == ["title", "text", "fields", "buttons", "footer"])
        if case let .title(text, href) = cards[1].parts[0] {
            #expect(text == "[FIRING] HighErrorRate message-api")
            #expect(href == "https://status.fernwood.example/alerts/high-error-rate")
        } else { Issue.record("C2 has no title") }
        if case let .buttons(buttons) = cards[1].parts[3] {
            #expect(buttons.contains { $0.style == .danger })
        } else { Issue.record("C2 has no buttons") }
        if case let .footer(text, _, at) = cards[1].parts[4] {
            #expect(text == "Uptime")
            #expect(at != nil)
        } else { Issue.record("C2 has no footer") }
        #expect(!seeds[1].body.isEmpty)

        // C3
        #expect(cards[2].accent == .good)

        // C4
        #expect(cards[3].kinds == ["header", "section", "table", "divider", "context"])
        if case let .table(rows, columns) = cards[3].parts[2] {
            #expect(rows.count == 4)
            #expect(rows.allSatisfy { $0.count == 3 })
            #expect(columns.map(\.align) == [.left, .right, .right])
        } else { Issue.record("C4 has no table") }
        if case let .context(items) = cards[3].parts[4] {
            #expect(items.count == 2)
            #expect(items.contains { if case .image = $0 { true } else { false } })
            #expect(items.contains { if case .html = $0 { true } else { false } })
        } else { Issue.record("C4 has no context") }

        // C5
        #expect(cards[4].source == .attachment)
        #expect(cards[4].pretext != nil)
        #expect(cards[4].thumb != nil)
        #expect(cards[4].kinds == ["author", "title", "text", "fields", "image", "footer"])
        #expect(cards[4].accent == .rgb(red: Double(0x7c) / 255, green: Double(0x3a) / 255, blue: Double(0xed) / 255))
        if case let .author(_, _, icon) = cards[4].parts[0] { #expect(icon != nil) } else { Issue.record("C5 has no author") }
        if case let .text(html) = cards[4].parts[2] { #expect(CardText.isLong(html: html)) } else { Issue.record("C5 has no text") }
        if case let .fields(fields) = cards[4].parts[3] { #expect(fields.contains { !$0.short }) } else { Issue.record("C5 has no fields") }
        if case let .image(_, title) = cards[4].parts[4] { #expect(title == "Coverage by package") } else { Issue.record("C5 has no image") }
        if case let .footer(_, icon, _) = cards[4].parts[5] { #expect(icon != nil) } else { Issue.record("C5 has no footer") }

        // C6
        #expect(cards[5].kinds == ["section", "tiles"])
        if case let .tiles(tiles) = cards[5].parts[1] {
            #expect(tiles.count == 3)
            let order = tiles[0].buttonsInOrder
            #expect(order.leading.map(\.text) == ["Tear down"])
            #expect(order.trailing.map(\.text) == ["Logs", "Open"])
        } else { Issue.record("C6 has no tiles") }

        // C7
        #expect(cards[6].accent == .warning)

        // All 13 kinds between them.
        let allKinds = Set(cards.flatMap(\.kinds))
        #expect(allKinds == ["author", "title", "header", "text", "section", "fields", "image", "context", "divider", "buttons", "table", "tiles", "footer"])
    }

    @MainActor @Test func aSeededMessageWithoutCardsHasNone() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let plain = try #require(session.timeline.messages.first { $0.creator.name != "Deploy Bot" && $0.creator.name != "Uptime" && !$0.plainText.isEmpty })
        #expect(plain.cards == nil)
    }

    @MainActor @Test func aCardMessagesPlainTextIsItsTextThenItsParts() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let first = try seededCards(in: session)[0]
        #expect(first.plainText == "Deployed message-api v2.4.2 to production\nSmoke tests passed in 2m 14s. Nothing to roll back.\nRelease notes\nCommit\n8a1969f\nStarted by\nMaya Chen\nTook 4m 31s · Deploy #1874")
    }

    @MainActor @Test func cardAddressesFollowTheHostRule() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let seeds = try seededCards(in: session)
        let cards = seeds[3...5].map { $0.cards! }

        func addresses(_ cards: [Card]) -> (images: [String], links: [String]) {
            var images: [String] = []
            var links: [String] = []
            func image(_ value: CardImage?) { if let value { images.append(value.url) } }
            for card in cards {
                image(card.thumb)
                for part in card.parts {
                    switch part {
                    case let .author(_, href, icon):
                        if let href { links.append(href) }
                        if let icon { images.append(icon) }
                    case let .title(_, href): if let href { links.append(href) }
                    case let .section(_, _, thumb, button):
                        image(thumb)
                        if let button { links.append(button.href) }
                    case let .image(value, _): image(value)
                    case let .context(items):
                        for item in items { if case let .image(value) = item { image(value) } }
                    case let .buttons(buttons): links += buttons.map(\.href)
                    case let .tiles(tiles):
                        for tile in tiles {
                            image(tile.hero)
                            image(tile.icon)
                            links += tile.buttons.map(\.href)
                        }
                    case let .footer(_, icon, _): if let icon { images.append(icon) }
                    default: break
                    }
                }
            }
            return (images, links)
        }

        let raw = addresses(cards.flatMap { $0 })
        #expect(!raw.images.isEmpty)
        #expect(raw.images.allSatisfy { $0.contains("media.localhost") })
        #expect(raw.links.allSatisfy { $0.contains("fernwood.example") })

        let kept = cards.map { $0.withAddresses { CardText.address($0, host: "127.0.0.1") } }
        #expect(kept.count == 3)
        let shown = addresses(kept.flatMap { $0 })
        #expect(shown.images == raw.images)
        #expect(shown.links == raw.links)
        #expect(!shown.links.isEmpty)

        // The images' own host is the server's: they go, and what held only them goes too.
        let refused = cards.map { $0.withAddresses { CardText.address($0, host: "media.localhost") } }
        let after = addresses(refused.flatMap { $0 })
        #expect(after.images.isEmpty)
        #expect(after.links == raw.links)
        let c4 = try #require(refused[0].first)
        #expect(c4.kinds == ["header", "section", "table", "divider", "context"])
        if case let .context(items) = c4.parts.last { #expect(items.count == 1) } else { Issue.record("C4 lost its context") }
        let c5 = try #require(refused[1].first)
        #expect(c5.thumb == nil)
        #expect(c5.kinds == ["author", "title", "text", "fields", "footer"])
        let c6 = try #require(refused[2].first)
        guard case let .tiles(tiles) = c6.parts.last else {
            Issue.record("C6 lost its tiles")
            return
        }
        // The third tile had only an icon beyond its text, so it keeps its title; the heroes are gone.
        #expect(tiles.allSatisfy { $0.hero == nil && $0.icon == nil })
        #expect(tiles.count == 3)
    }

    /// Waits for a message from `name` after `known` that satisfies `matches`.
    @MainActor
    func botMessage(in session: RoomSession, from name: String, excluding known: Set<String>, where matches: (Message) -> Bool = { _ in true }) async -> Message? {
        _ = await eventually(within: .seconds(15)) {
            session.timeline.messages.contains { !known.contains($0.id) && $0.creator.name == name && matches($0) }
        }
        return session.timeline.messages.first { !known.contains($0.id) && $0.creator.name == name && matches($0) }
    }

    @MainActor @Test func deployBringsADeployBotCard() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let known = Set(session.timeline.messages.map(\.id))
        let tag = UUID().uuidString.prefix(8)
        let text = "Time to deploy \(tag)"
        _ = session.send(body: "<p>\(text)</p>", plainText: text)
        let reply = try #require(await botMessage(in: session, from: "Deploy Bot", excluding: known))
        #expect(reply.cards?.count == 1)
        #expect(reply.cards?.first?.source == .blocks)
        #expect(reply.cards?.first?.label == "Deployed message-api v2.4.3 to production")
    }

    @MainActor @Test func alertBringsACardThatUptimeThenReplacesWithText() async throws {
        let client = try await signedIn()
        let session = try await engineering(on: client)
        defer { session.stop() }
        let known = Set(session.timeline.messages.map(\.id))
        let tag = UUID().uuidString.prefix(8)
        let text = "Alert check \(tag)"
        _ = session.send(body: "<p>\(text)</p>", plainText: text)
        let alert = try #require(await botMessage(in: session, from: "Uptime", excluding: known))
        #expect(alert.cards?.first?.accent == .danger)
        #expect(alert.cards?.first?.label?.contains("HighErrorRate") == true)

        #expect(await eventually(within: .seconds(20)) {
            session.timeline.messages.first { $0.id == alert.id }?.cards == nil
        })
        let replaced = try #require(session.timeline.messages.first { $0.id == alert.id })
        #expect(replaced.cards == nil)
        #expect(replaced.plainText.lowercased().contains("back to normal"))
        #expect(replaced.body.lowercased().contains("back to normal"))
    }

    @MainActor @Test func aCardMessageCantBeEdited() async throws {
        let client = try await signedIn()
        let me = try await client.me()
        #expect(me.administrator)
        let session = try await engineering(on: client)
        defer { session.stop() }
        let target = try seededCards(in: session)[1]
        #expect(session.notice == nil)
        #expect(session.edit(target.id, body: "<p>Edited by a person</p>"))
        #expect(await eventually { session.notice != nil })
        #expect(session.notice == "Messages with cards can't be edited.")
        #expect(session.timeline.pending.isEmpty)
        // Nothing changed. The room's frames come in order, so once a message sent after the edit is back,
        // any update to the card message would have arrived already.
        let probe = session.send(body: "<p>Edit probe</p>", plainText: "Edit probe")
        #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == probe } })
        let kept = try #require(session.timeline.messages.first { $0.id == target.id })
        #expect(kept.cards == target.cards)
        #expect(kept.body == target.body)
        #expect(kept.editedAt == nil)
    }

    @Test func searchFindsTheAlertsWithTheirCards() async throws {
        let client = try await signedIn()
        let results = try await client.search(SearchQuery(q: "HighErrorRate"))
        let cards = results.matches.compactMap(\.message.cards).flatMap { $0 }
        #expect(cards.contains { $0.label?.hasPrefix("[FIRING]") == true && $0.accent == .danger })
        #expect(cards.contains { $0.label?.hasPrefix("[RESOLVED]") == true && $0.accent == .good })
        #expect(cards.allSatisfy { $0.kinds.contains("title") })
    }
}
