import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Bot cards

    /// A bot that posts through a Slack-style webhook.
    public static let deployBot = User(id: "user_deploys", name: "Deploys")

    /// A deploy summary in blocks, as the server translates one: a header, a section with a link
    /// button, a table, a rule and a context row.
    public static let deployCard = Card(source: .blocks, parts: [
        .header(text: "Deployed web 2.4.0"),
        .section(
            html: "<p><strong>3 services</strong> are live in <strong>production</strong>.</p>", fields: [], thumb: nil,
            button: CardButton(text: "Release notes", href: "https://example.com/releases/2.4.0", style: .primary)
        ),
        .table(
            rows: [
                ["<p>Service</p>", "<p>Took</p>", "<p>Errors</p>"],
                ["<p>api</p>", "<p>1m 12s</p>", "<p>0</p>"],
                ["<p>web</p>", "<p>48s</p>", "<p>0</p>"],
            ],
            columns: [CardColumn(align: .left, wrap: true), CardColumn(align: .right), CardColumn(align: .right)]
        ),
        .divider,
        .context([
            .image(CardImage(url: "https://example.com/ada.png", alt: "Ada Lovelace")),
            .html("<p>Started by <strong>Ada Lovelace</strong></p>"),
        ]),
    ])

    /// A firing alert as a legacy attachment: a red bar, a linked title, text and a footer.
    public static let alertCard = Card(source: .attachment, color: "danger", parts: [
        .title(text: "[FIRING:1] HighCPU (web-1 production)", href: "https://grafana.example.com/alerting/list"),
        .text(html: "<p>Value: A=97.2<br>Labels:<br> - instance = web-1</p>"),
        .footer(text: "Grafana", icon: "https://grafana.com/static/assets/img/fav32.png", at: date("2026-10-12T10:00:00.000Z")),
    ])

    /// A bot's message: no body, its plain text, and `cards` under it.
    public static func cardMessage(
        _ id: String,
        cards: [Card] = [deployCard],
        plainText: String = "Deployed web 2.4.0",
        by creator: User = deployBot,
        in roomID: RoomID = general.id,
        minute: Int = 0
    ) -> Message {
        var message = message(id, plainText, by: creator, in: roomID, minute: minute)
        message.body = ""
        message.cards = cards
        return message
    }
}
