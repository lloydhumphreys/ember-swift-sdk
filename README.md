# Ember Swift SDK

A Swift client for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), a team chat app that runs on Cloudflare Workers and Durable Objects.

[Ember for iOS](https://github.com/lloydhumphreys/ember-ios) is an iPhone app built on this SDK.

## Layers

| Product | Description |
| --- | --- |
| `EmberCore` | Wire shapes and logic (timeline, sidebar, search). No I/O. |
| `EmberRichText` | Message bodies, read into blocks. |
| `EmberSDK` | HTTP client, two sockets, and stores: `Workspace` and `RoomSession`. Re-exports `EmberCore`. |
| `EmberTesting` | Fixtures etc, for an app's tests and previews. |

Swift 6, iOS 18 and macOS 15. Foundation and Observation only.

Bot cards, Ember's message attachments for bots, are read in `EmberCore` and their text in `EmberRichText`.

| | |
| --- | --- |
| Upstream | [ember-cloudflare](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), commit `7657ea4c`, 2026-11-08 |
| Swift | 6.0 or later (`swift-tools-version: 6.0`) |
| Xcode | 16.0 or later |
| Platforms | iOS 18, macOS 15 |

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

// Observable sidebar
let workspace = Workspace(client: client, me: me, account: bootstrap.account)
workspace.onSignedOut = { /* back to signing in */ }
workspace.start()

// A room, kept live by its own socket. The workspace keeps one session per room.
let room = workspace.session(for: roomID)
let lease = room.open()          // in onAppear; lease.close() in onDisappear
room.send(body: "<p>Hello</p>", plainText: "Hello")
// room.timeline.messages, room.timeline.pending, room.loadOlder(), room.jump(to:)…

// Search
let results = try await client.search(SearchQuery(q: "launch"), record: true)
```

`EmberClient(origin:)` keeps the session cookie in `HTTPCookieStorage.shared`, so someone stays signed in between launches. `client.hasSessionCookie` says whether to try `me()` before showing sign-in. Every call throws `EmberError`, whose `message` can be shown as it is, and whose `kind` says what went wrong: `.unreachable`, `.http`, `.undecodable`, `.unreadableFile`, `.invalid`, `.refused` or `.timedOut`.

## Sign out

```swift
workspace.onSignedOut = {
    switch client.signOutReason {
    case .sessionEnded: break     // the server ended the session (a request was answered 401)
    case .userInitiated, nil: break // signed out manually
    }
}
```

## Multiple account management

`HTTPCookieStorage.shared` keeps one session cookie per server, so two people signed in to one server would overwrite each other's. Give each account a `KeychainCookieStorage` of its own instead:

```swift
let cookies = KeychainCookieStorage(account: accountID)   // any name that stays the same for the account
let client = EmberClient(origin: origin, cookies: cookies)
```

This keeps the cookies in memory and writes them to one Keychain item (readable after first unlock, this device only) whenever they change. Each `EmberClient(origin:cookies:)` has a URLSession of its own, with no cookie store or cache of its own. `cookies.eraseAll()` forgets the cookies and the Keychain item, as when the account is removed. 

Keychain can't be read while a device is locked after a restart: `cookies.readFailure` returns a failure. A write the Keychain refuses is retried at the next change. `cookies.syncVault()` tries both again now, as when the app comes to the foreground, and answers whether the Keychain is up to date. `KeychainCookieStorage(vault:)` takes any `CookieVault`; tests use `MemoryCookieVault`.

## Your own transport

```swift
var environment = EmberEnvironment.system()
environment.transport = MyTransport()                // any HTTPTransport
let client = EmberClient(origin: origin, environment: environment)
```

`EmberEnvironment` is what a client runs on: transport, socket connector, cookies, timing, network path, unsent-message store and background time. `.system()` is what `EmberClient(origin:)` uses, so the rest stays as it is: unsent messages on disk, and time asked for while a file goes up.

## Network status

`workspace.isNetworkAvailable` is false while the device has no network, and each socket's `isNetworkAvailable` the same for it. A socket waiting to reconnect tries again the moment the network is back, and doesn't use up its backoff while there is none. The client's `EmberEnvironment` has the `NetworkPathSource` that says so: `SystemNetworkPath` in `.system()`, and in tests EmberTesting's `MockNetworkPath`, whose `set(available:)` takes the network away.

## The workspace

- `stop()` closes every socket, the rooms' included, and `start()` opens them again: the workspace's, and each room's that still has a lease. Call them as the app goes to the background and comes back. A room opened while the workspace is stopped waits for `start()`.
- `shutdown()` is for signing out: it stops everything for good, and nothing it was loading lands afterwards. Calling it twice is the same as once. The workspace does it itself when the session turns out to be gone, before `onSignedOut`. Each room's files stop, their temporary copies deleted and their pending messages dropped; its threads are let go of, their pending replies left as they are. A room or thread shut down sends no files afterwards: `send(files:…)` answers no ids and deletes temporary sources.
- `directoryStatus` is `.loading`, `.loaded` or `.failed(message)`; `reloadDirectory()` tries again. A directory that loaded once stays `.loaded` through a later failure.
- Sessions with an open lease are kept, and so are the 8 (`Workspace.idleSessionLimit`) used most recently without one. An older one is let go of: its socket closes, and its files stop, as on `shutdown()`, but its threads stay. While anything still holds it, `session(for:)` answers that same session again, and opening it takes it back into the cache. Keep the lease, not just the session, for as long as a screen shows the room.

## Ids

```swift
let general: RoomID = "general"
let message = MessageID(url.lastPathComponent)   // a String needs wrapping
general.rawValue                                 // "general"
```

`UserID`, `RoomID`, `MessageID`, `ClientMessageID`, `BoostID`, `UploadID` and `FileID` each hold the server's string as it is, and one can't be passed for another. In JSON, and as a dictionary key, each is just that string.

## Rooms

- `open()` answers a `RoomLease`: the socket opens with a session's first lease and closes with its last, and a lease let go of closes itself. `start()` and `stop()` are the session's own lease, for code that holds just one.
- `jump(to:)` shows the page around a message, and `isJumping` is true until it arrives (or the room refuses it); `loadOlder()` and `loadNewer()` wait meanwhile. A page the room doesn't answer within `RoomSession.pageTimeout` (15 seconds), or one on its way when the socket drops, fails as a refused one does: `timeline.olderPageFailure` (or `newerPageFailure`) says so, and `retryOlder()` (or `retryNewer()`) asks again. A thread's page that fails clears its loading and sets the thread's `notice`; `loadOlder()` asks again. Scroll to `timeline.anchor`, then call `anchorShown()`. `jumpToLatest()` goes back to the newest page.
- `send` always goes at the end of the newest page: from older history or mid-jump, it asks for that page first, and a message sent before the room lets the socket in waits for it.
- `edit`, `delete`, `boost` and `removeBoost` don't wait. Each answers false when the room hasn't let the socket in, sending nothing, with `notice` set to `RoomSession.notConnected`. Their `async` forms, below, wait for the room's answer.
- `phase` is `.idle`, `.connecting`, `.admitted`, `.reconnecting` or `.stopped(reason)`; `.reconnecting` shows only after the room had let the socket in.
- After a stop, `reconnect()` (on the room or a thread) connects again while a lease holds the room, as a Retry button asks. It does nothing while connected, and after a stop for signing out.

## Sending plain text

```swift
let id = try room.send(text: "Use <b> for bold")     // shows as typed, "<b>" and all
try thread.reply(text: "Yes\nand no", alsoSend: true)
```

- `send(text:)`, `send(files:text:)`, `thread.reply(text:alsoSend:)` and `thread.send(files:text:alsoSend:)` take what someone typed: escaped, each line its own, line endings made `\n` and blank lines at the end dropped. They throw `EmberError` of kind `.invalid`, sending nothing, for text that's blank or over `Limits.message` characters.
- `send(body:plainText:)` and `reply(body:plainText:)` are still there for a body you made yourself.

## Unsent messages and Retry

```swift
for message in room.timeline.pending where message.failure != nil {
    // show message.failure, with Retry and Discard
    room.retry(message.clientMessageId)               // or room.discard(message.clientMessageId)
}
// On signing out, forget what this account left unsent on this device, in every room.
room.unsentStore.removeAll(server: client.origin, userID: me.id)
```

- A message or reply is pending until the room confirms it. One unconfirmed `sendTimeout` (30 seconds) after it was sent or retried fails with `RoomSession.notSent`, whatever the connection is doing. One sent while the room is reconnecting goes if the room is back in time; one that failed first isn't sent when it's back, only asked about.
- `retry` asks the room with `message.check` first, and sends the text again only if the room says it's missing, since the room stores a create twice if it's sent twice. A failed text is asked about after each reconnect too, and one the room has after all leaves the pending list.
- An unsent text keeps its room's socket open after the last lease closes, until it's confirmed, failed or discarded.
- Unsent and failed texts and thread replies are kept on disk by `FileUnsentMessageStore`, per server, person and room, so they're sent again, under the same id, after the app was quit. A room's come back when it next opens, and a thread's replies when the thread does. Files going up aren't kept: one on its way when the app quits is lost.
- A session uses its client's `unsentStore`. `RoomSession(client:roomID:around:unsentStore:)` takes any other `UnsentMessageStore`; `MemoryUnsentMessageStore` keeps nothing on disk.

## Changes that throw

```swift
do {
    try await room.edit(message: message.id, body: newBody)
    let boost = try await room.boost(message: message.id, content: "🎉")
    try await room.removeBoost(id: boost.id)
    try await room.delete(message: message.id)
} catch let error as EmberError {
    // error.kind is .refused (error.message is the room's words), .timedOut or .unreachable
}
```

- Each returns once the room has shown the change made, and throws the room's refusal, `.timedOut` after `RoomSession.changeTimeout` (15 seconds), or `.unreachable` when the room isn't connected or connecting, or the socket drops after the change went on it. One asked for while the room is reconnecting goes once it's back, timed from when it was asked for; one that runs out of time first is never sent.
- An edit finishes once the room has taken it, even when the body it stores after sanitising isn't the one sent, or is the one it had. An edit to the body the message has, or a boost of yours that's there already, returns at once.
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

## Search

`SearchSession` holds a search for a screen: the query being edited, the matches, further pages and the recent searches. It is `@Observable` and runs on the main actor.

```swift
let search = SearchSession(client: client)
await search.loadRecent()           // when the screen opens, before anything is typed
search.query.q = "launch"
search.run(record: true)            // true when someone typed it: it joins their recent searches
// search.phase (.idle, .searching, .loaded, .failed(message)), search.matches, search.rooms, search.recent
if search.canLoadMore { search.loadMore() }
search.clearFilters()               // keeps the words
```

- Nothing runs as `query` changes. Call `run(record:)` when the person submits, or after a short pause you choose.
- A new search cancels the one before it, and an answer that arrives late is dropped, so `matches` always belong to the last search run.
- `loadMore()` continues the search the shown matches are for, even if `query` has been edited since. `moreFailure` says why a page failed; the matches stay.
- A query with no words and no filters runs nothing: `run(record:)` resets the session to `.idle`. `retry()` runs the last query again without recording it.
- `run(_:)` takes one of `recent`, and `clearRecent()` asks the server to forget them.

## One message

```swift
let message = try await client.message(messageID, in: roomID)
```

The server has no route that answers one message to a signed-in person. `message(_:in:)` uses the nearest real one: it opens the room's socket with `around=<id>` and `visible=0`, reads the welcome, takes the message from it and closes the socket. The room isn't marked read. Only a message in the room's own timeline is found, so a reply that wasn't also sent to the room is not, and a message the room doesn't have or has deleted fails with status 404.

## Bots

`EmberBot` posts to a room through the server's bot API. A bot has no session: its key, `<bot id>-<token>`, is in each request's address. It needs no `EmberClient` and no sign-in, and it is `Sendable`.

```swift
let bot = EmberBot(origin: URL(string: "https://chat.example.com")!, roomID: roomID, key: botKey)

let posted = try await bot.post(text: "Deploy finished")     // posted.id, posted.url
try await bot.post(html: "<p>Deploy <b>finished</b></p>")
try await bot.post(file: logData, named: "build.log", contentType: "text/plain")
try await bot.post(fileAt: logURL, contentType: "text/plain")
let boost = try await bot.boost(posted.id, with: "ship it")  // up to Limits.boost UTF-16 units
```

- `post(text:)` is plain text, escaped as `room.send(text:)` escapes it, so `<b>` shows as typed. It throws `.invalid`, sending nothing, for text that's blank or over `Limits.message` characters. `post(html:)` sends markup as it is.
- Posting answers the message's id and permalink. A boost answers the boost's id, its content and the message's id.
- It does only what the server's bot API does: post text, post a file, boost. It can't read, edit or delete a message, or remove a boost.
- Every call throws `EmberError`. The server answers some refusals with no body (422 for a blank message, 404 for a bot that isn't in the room), and those read as their status's wording. A key the server doesn't know is 401 `Unknown bot key`, which does not sign anyone out.
- The key is not in the bot's `description`, `debugDescription` or `dump`, or in any error. It is in the request's address, so keep it out of your own logs of requests. Keep it somewhere private: the Keychain, not a plist in the app.
- `EmberBot(origin:roomID:key:transport:)` takes the SDK's `HTTPTransport`, so a test hands it `MockHTTPTransport`.

## App extensions and widgets

An app extension or widget is a separate process. It has its own `HTTPCookieStorage.shared`, so an `EmberClient(origin:)` there knows nothing of the session the app signed in with. Share the session through an app group:

```swift
let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "group.com.example.chat")
let client = EmberClient(origin: origin, cookies: cookies)
```

Use the same group identifier, with the App Groups capability, in the app and in each extension, and make the client the same way in the app. The client attaches the cookie from the storage it is given and keeps what the server sets in it, so signing in from the app signs in the extension. When the server ends the session, a request answers 401 and calls the handlers added with `addSignedOutHandler`. That does not delete the cookie: call `client.forgetCookies()` there, and `hasSessionCookie` goes false in both.

```swift
guard client.hasSessionCookie else { return placeholder }   // nobody has signed in on this device
let me = try await client.me()
let sidebar = try await client.sidebar()
let results = try await client.search(SearchQuery(q: "launch"))
```

- A widget's timeline provider and an extension's code should make one-shot requests like these. `me()`, `sidebar()`, `directory()`, `search(_:)` and the endpoints under "Endpoints the SDK hasn't wrapped" are plain HTTP and open no socket. Don't make a `Workspace` or `RoomSession` there: they hold sockets open, which an extension can't do for long.
- `message(_:in:)` opens a socket for the length of one welcome. It works in an extension, but it isn't a request without a socket.
- To post from an extension without a person's session, use an `EmberBot`. Its key is the only thing to share, and a Keychain access group is the place for it.
- Not tested on a device: the app-group cookie storage is Foundation's, and the SDK's tests run the calls above on stand-in transports only.

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

The tests need Swift 6.1 (Xcode 16.3) or later: they read the error that `#expect(throws:)` returns. The library itself builds with Swift 6.0.

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

They sign in as the stand-in server's administrator unless `EMBER_TEST_EMAIL` names another account. The password comes from `EMBER_SEED_PASSWORD` or `.dev/seed-password`, as for the server. Each test uses cookies of its own, never the shared store. Start the stand-in afresh for them: they look for its seeded messages on a room's newest page, and running `check.mjs` first posts enough to push those off it.

## Editing a message

`EditableBody` lets a plain-text field edit a stored body without losing formatting. Its `text` is the field's starting value: one line per block, mentions as "@Name", links as their text, attachments as nothing. `body(editedTo:)` changes only the part of the body the edit touched, so bold, links, lists, mentions and attachments elsewhere stay byte for byte.

```swift
let editable = EditableBody(body: message.body, mentionNames: names)
draft = editable.text
// on save
try await room.edit(message: message.id, body: editable.body(editedTo: draft))
```

Text typed into the middle of a formatted run takes its formatting; text typed at its end does too, except after a link. Markup it can't map (badly nested tags) reads as plain text, and an edit to it is saved as `RichText.body(fromPlainText:)`.

## Licence and credits

MIT. See [LICENSE](LICENSE).

The SDK is a client for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), which grew out of [Campfire](https://github.com/basecamp/once-campfire) by 37signals. Parts of it are ports of Ember's TypeScript.
