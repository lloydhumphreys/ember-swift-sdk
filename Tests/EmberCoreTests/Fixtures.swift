import Foundation
@testable import EmberCore

let ada = User(id: "u1", name: "Ada")
let grace = User(id: "u2", name: "Grace")
let linus = User(id: "u3", name: "Linus")

/// Noon on 12 October 2026, plus `minutes`.
func noon(_ minutes: Int = 0) -> Date {
    Date(timeIntervalSince1970: 1_791_806_400 + Double(minutes) * 60)
}

/// A message in room r1, its client id `c` and its id.
func message(_ id: String, by creator: User = grace, clientMessageId: String? = nil, text: String? = nil, parentId: String? = nil, alsoSent: Bool? = nil) -> Message {
    let text = text ?? "Message \(id)"
    return Message(
        id: id, clientMessageId: clientMessageId ?? "c-\(id)", roomId: "r1", creator: creator, body: "<p>\(text)</p>",
        plainText: text, createdAt: noon(), parentId: parentId, alsoSent: alsoSent
    )
}

/// Messages m001 to m`to`, ids that sort as the room's do.
func stored(_ from: Int, _ to: Int) -> [Message] {
    guard from <= to else { return [] }
    return (from ... to).map { message(id($0)) }
}

func id(_ n: Int) -> String { String(format: "m%03d", n) }

/// `text` parsed as JSON, to compare frames whatever their key order.
func json(_ text: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// A message as the server writes one, for frame fixtures.
let messageJSON = #"{"id":"m001","clientMessageId":"c1","roomId":"r1","creator":{"id":"u2","name":"Grace"},"body":"<p>Hi</p>","plainText":"Hi","mentions":[],"createdAt":"2026-10-12T10:00:00.000Z","updatedAt":"2026-10-12T10:00:00Z","boosts":[]}"#
