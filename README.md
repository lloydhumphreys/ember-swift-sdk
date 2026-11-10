# Ember Swift SDK

A Swift client for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), a team chat app that runs on Cloudflare Workers and Durable Objects.

## Layers

| Product | What it is |
| --- | --- |
| `EmberCore` | The wire shapes and the pure logic over them (timeline, sidebar, search). No I/O. |
| `EmberRichText` | Message bodies, read into blocks and written from what someone typed. |
| `EmberSDK` | The HTTP client, the two sockets, and the stores an app holds: `Workspace` and `RoomSession`. Re-exports `EmberCore`. |
| `EmberTesting` | Stand-in transports, a manual clock and fixtures, for an app's tests and previews. |

Swift 6, iOS 18 and macOS 15. Foundation and Observation only.

Bot cards, Ember's message attachments for bots, are read in `EmberCore` and their text in `EmberRichText`.

The SDK is built and tested against the stand-in server below, which tracks Ember release 0.4.2. It has not yet been exercised end to end against a production Ember server.

[Ember for iOS](https://github.com/lloydhumphreys/ember-ios) is the reference client: an iPhone app built on these products.

## Installing

There are no tagged releases yet, so depend on the main branch:

```swift
.package(url: "https://github.com/lloydhumphreys/ember-swift-sdk", branch: "main")
```

Then add `EmberSDK` to your target, plus `EmberRichText` if you draw message bodies, and `EmberTesting` to your test target.

## Quick start

```swift
import EmberSDK

let client = EmberClient(origin: URL(string: "https://chat.example.com")!)
let me = try await client.signIn(emailAddress: email, password: password)
let bootstrap = try await client.bootstrap()

// The sidebar, kept live by the workspace socket. Observable, so SwiftUI redraws as it changes.
let workspace = Workspace(client: client, me: me, account: bootstrap.account)
workspace.onSignedOut = { /* back to signing in */ }
workspace.start()

// A room, kept live by its own socket while a lease on it is open. The workspace keeps one
// session per room.
let room = workspace.session(for: roomID)
let lease = room.open()          // in onAppear; lease.close() in onDisappear
room.send(body: "<p>Hello</p>", plainText: "Hello")
// room.timeline.messages, room.timeline.pending, room.loadOlder(), room.jump(to:)…

// Search. An empty query reads just the recent searches.
let results = try await client.search(SearchQuery(q: "launch"), record: true)
```

`EmberClient(origin:)` keeps the session cookie in `HTTPCookieStorage.shared`, so someone stays signed in between launches. `client.hasSessionCookie` says whether to try `me()` before showing sign-in. Every call throws `EmberError`, whose `message` can be shown as it is.

## The workspace

- `stop()` closes every socket, the rooms' included, and `start()` opens them again: the workspace's, and each room's that still has a lease. Call them as the app goes to the background and comes back. A room opened while the workspace is stopped waits for `start()`.
- `shutdown()` is for signing out: it stops everything for good, and nothing it was loading lands afterwards. Calling it twice is the same as once. The workspace does it itself when the session turns out to be gone, before `onSignedOut`. Each room's files stop, their temporary copies deleted and their pending messages dropped; its threads are let go of, their pending replies left as they are. A room or thread shut down sends no files afterwards: `send(files:…)` answers no ids and deletes temporary sources.
- `directoryStatus` is `.loading`, `.loaded` or `.failed(message)`; `reloadDirectory()` tries again. A directory that loaded once stays `.loaded` through a later failure.
- Sessions with an open lease are kept, and so are the 8 (`Workspace.idleSessionLimit`) used most recently without one. An older one is let go of: its socket closes, and its files stop, as on `shutdown()`, but its threads stay. While anything still holds it, `session(for:)` answers that same session again, and opening it takes it back into the cache. Keep the lease, not just the session, for as long as a screen shows the room.

## Rooms

- `open()` answers a `RoomLease`: the socket opens with a session's first lease and closes with its last, and a lease let go of closes itself. `start()` and `stop()` are the session's own lease, for code that holds just one.
- `jump(to:)` shows the page around a message, and `isJumping` is true until it arrives (or the room refuses it); `loadOlder()` and `loadNewer()` wait meanwhile. Scroll to `timeline.anchor`, then call `anchorShown()`. `jumpToLatest()` goes back to the newest page.
- `send` always goes at the end of the newest page: from older history or mid-jump, it asks for that page first, and a message sent before the room lets the socket in waits for it.
- `edit`, `delete`, `boost` and `removeBoost` don't wait. Each answers false when the room hasn't let the socket in, sending nothing, with `notice` set to `RoomSession.notConnected`.
- A boost is trimmed, and refused (false, nothing sent) unless `Limits.boostFits` it: up to `Limits.boost` UTF-16 units. `Limits.clampedBoost` shortens a text field's contents to fit as someone types, by whole characters.

## Threads

A thread rides its room's socket. Get it from the session, and hold a lease while it's on screen:

```swift
let thread = session.thread(parent.id)          // or thread(parent.id, at: replyID) to land on a reply
let lease = thread.open()                       // holds the room's socket open too
let id = thread.reply(body: "<p>Yes</p>", plainText: "Yes")
thread.reply(body: html, plainText: text, alsoSend: true)   // shows in the room as well
thread.loadOlder()
lease.close()
```

- `thread.timeline` has the parent (`parentMessage`, nil once it's gone), `replies`, `pending`, `typing` and `canReply`. A deleted parent with replies still takes them.
- With several threads open, the most recently opened one is the server's; closing it opens the next again. All of them open again after a reconnect.
- A reply goes at once when the room has let the socket in, and otherwise is checked and resent when the thread opens again. Refusals land on the reply (`retry`, `discard`); a thread that can't open says why in `thread.notice`, never the room's.
- A thread let go of with a reply or file still unconfirmed is kept by the session, and `session.thread(_:)` answers the same one, until it settles.
- `session.thread(id, at: replyID)` on a thread that's there already moves `timeline.focus` to that reply, paging back to it if it isn't loaded. Scroll there once `focus` is set and `isLoaded`, then call `focusShown()`.
- Edits, deletes and boosts on a reply are the room's: `session.edit(…)`, `session.delete(…)`, `session.boost(…)`.

## Uploads

```swift
let source = try UploadSource(fileURL: url, contentType: "image/png",
                              preview: UploadPreview(data: webp, contentType: "image/webp"),
                              isTemporary: true)        // the SDK deletes it once it's posted or discarded
let ids = session.send(files: [source], body: html, plainText: text)
thread.send(files: [source], alsoSend: true)
```

- `UploadSource(fileURL:…)` throws when the file can't be read, or when the server would refuse its name or type (`Uploads.refusal(name:contentType:)`): a blank name, or either over 255 UTF-16 code units.
- A temporary source is deleted once it's posted, discarded or refused, and so is the folder it's in if that's left empty (never the temporary directory itself), so stage each file in a folder of its own.
- Each file is a pending message straight away, with `upload` progress on it that never goes back; the text, if any, goes after the files, in order. Files go one at a time. `send(files:…)` answers an id for each file, in order, then the text's.
- A file whose `isTooLarge` is true (over `Limits.fileBytes`, 250 MB) isn't sent: its id is answered all the same, to keep the positions, but nothing is pending under it, and the `notice` of the room or thread it was sent from says `Uploads.tooLarge(name)`: “notes.txt is too large. Choose a file that’s 250 MB or smaller.” A refusal says the server's reason; a lost network says `Uploads.failed`. `retry(_:)` starts that file again from the first part, and `discard(_:)` drops it. A failed file the room confirms after all is let go of as the confirmation lands.
- The ticket the server answers is checked against the file before any part goes; one that doesn't fit fails the upload. A part the network dropped is sent again, twice at most. A 409 for part 1 (the server still had a try whose answer was lost) is sent again at once, within the same budget, and fails as `Uploads.failed` if it lasts.
- An upload keeps going through a reconnect and after its screen's lease is let go of; the workspace keeps a session that's busy with one.
- `client.upload(_:in:clientMessageId:parentId:alsoSend:progress:)` is the same three routes without a session: start, parts in order (part 1 first), and the preview before the last part.
- A `StoredFile`'s `url` and `downloadUrl` are signed, so `client.url(file.url)` loads without a cookie.

## Links

A message body keeps the link schemes the server's sanitiser keeps; anything else comes out as plain text. Fewer are safe to hand to the system: open a tapped link only when `EmberRichText`'s `LinkPolicy.opens(url)` (http and https with a host, `mailto`, `tel`).

## Endpoints the SDK hasn't wrapped

`get`, `send` and `data(at:)` attach the cookie, add the headers Ember's cross-site check asks of a write, and decode with Ember's dates. Only for the server itself, though: an absolute URL with another scheme, host or port goes without the cookie or those headers, keeps no cookie it's sent, and its 401 doesn't sign anyone out.

```swift
struct Pin: Codable { var messageId: String }

let pins: [Pin] = try await client.get("/api/rooms/\(roomID)/pins")
let pin: Pin = try await client.send("POST", "/api/rooms/\(roomID)/pins", body: Pin(messageId: "m1"))
let avatar = try await client.data(at: user.avatarUrl)
```

`request(_:_:)` and `perform(_:)` are there for anything else.

## Tests and previews

`EmberTesting` stands in for the server: `MockHTTPTransport` answers from stubs, `MockSocketConnector` plays the server's side of each socket, `ManualClock` moves only when told, and `Fixtures` has people, rooms, messages and frames.

```swift
import EmberTesting

// A preview: a workspace signed in as Fixtures.me with its sidebar loaded. Its rooms stay closed
// until start(), as a real workspace's do.
let workspace = Workspace.mock()
workspace.start()

let room = RoomSession.mock(messages: Fixtures.messages(20))
room.start()
```

```swift
import EmberTesting
import Testing

@MainActor @Test func showsTheRefusal() async {
    let transport = MockHTTPTransport()
    let workspace = Workspace.mock(transport: transport)
    transport.stub("PUT", "/api/rooms/room-engines/favorite", status: 403, json: Fixtures.errorJSON("You can’t star that."))
    await workspace.setFavorite(true, roomID: Fixtures.engines.id)
    #expect(workspace.notice == "You can’t star that.")
}
```

For sockets, script the server with `connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome()) }`, read what the client sent from `connector.latest?.sentFrames`, and pass `EmberTiming(clock: manualClock)` so a 25-second heartbeat or a reconnect's backoff passes with `manualClock.advance(by:)`.

## Running the tests

```bash
swift test
```

None of them touch the network, apart from the live tests below, which skip unless asked for.

## The stand-in server

`Tools/mock-server` is a small Node server that speaks Ember's HTTP and socket protocol, with seeded people and rooms. Its README has the details.

```bash
PORT=8791 node Tools/mock-server/server.mjs
```

The seeded accounts share one password, which you choose, read from `EMBER_SEED_PASSWORD` or `.dev/seed-password`. The server never prints it.

## Live tests

`Tests/EmberLiveTests` signs in to a running server and goes through bootstrap, signing in, the sidebar, search, stars, both sockets, threads, files, cards and signing out. They skip unless `EMBER_TEST_ORIGIN` is set:

```bash
EMBER_TEST_ORIGIN=http://127.0.0.1:8791 swift test --filter LiveTests
```

They sign in as the stand-in server's administrator unless `EMBER_TEST_EMAIL` names another account. The password comes from `EMBER_SEED_PASSWORD` or `.dev/seed-password`, as for the server. Each test uses cookies of its own, never the shared store.

## Editing a message

`EditableBody` lets a plain-text field edit a stored body without losing formatting. Its `text` is the field's starting value: one line per block, mentions as "@Name", links as their text, attachments as nothing. `body(editedTo:)` changes only the part of the body the edit touched, so bold, links, lists, mentions and attachments elsewhere stay byte for byte.

```swift
let editable = EditableBody(body: message.body, mentionNames: names)
draft = editable.text
// on save
room.edit(message.id, body: editable.body(editedTo: draft))
```

Text typed into the middle of a formatted run takes its formatting; text typed at its end does too, except after a link. Markup it can't map (badly nested tags) reads as plain text, and an edit to it is saved as `RichText.body(fromPlainText:)`.

## Licence and credits

MIT. See [LICENSE](LICENSE).

The SDK is a client for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), which grew out of [Campfire](https://github.com/basecamp/once-campfire) by 37signals. Parts of it are ports of Ember's TypeScript.
