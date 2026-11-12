# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `RoomSession.send(text:)` and `send(files:text:)`, and `ThreadSession.reply(text:alsoSend:)` and `send(files:text:alsoSend:)`, which take text someone typed. It is escaped, so `<b>` shows as typed, and each line stays its own. Blank text, or text over `Limits.message` characters, throws `EmberError` of kind `.invalid` and nothing is sent. `RichText.body(fromPlainText:)` does the escaping.
- Unsent messages are kept across launches. `UnsentMessageStore` is the protocol; `FileUnsentMessageStore` (the default for a real client) and `MemoryUnsentMessageStore` implement it; `UnsentMessage` and `UnsentMessageKey` are what they hold. Room messages and thread replies are both kept, by server, person and room, and are sent again under the same id after a relaunch. `RoomSession.unsentStore` is the session's store, and `RoomSession(client:roomID:around:unsentStore:)` takes one.
- `UnsentMessageStore.removeAll(server:userID:)` forgets everything one account left unsent on a server, in every room, for signing out.
- `RoomSession.sendTimeout` (30 seconds) and `RoomSession.notSent`. A message or reply the room hasn't confirmed by then, on a connection it let in, fails with that text, ready for `retry` or `discard`.
- Async throwing `RoomSession.edit(message:body:)`, `delete(message:)`, `boost(message:content:)` and `removeBoost(id:)`. They return once the room shows the change made, and throw the room's refusal, `.timedOut` after `RoomSession.changeTimeout` (with `changeTimedOut` as its message), or `.unreachable`. The old non-throwing forms are still there.
- `EmberError.kind`, one of `.unreachable`, `.http`, `.undecodable`, `.unreadableFile`, `.invalid`, `.refused` and `.timedOut`, and `EmberError(kind:status:message:field:)`.
- `RoomSession.phase` (`.idle`, `.connecting`, `.admitted`, `.reconnecting`, `.stopped(_:)`), observable.
- `RoomSession.reconnect()` and `ThreadSession.reconnect()`, which connect again after the server stopped the connection, while a lease holds the room. Closing a lease and opening another didn't, while any other lease was held.
- `RoomSession.retryOlder()`, `retryNewer()` and `setAwayFromLatest(_:)`, with `Timeline.olderPageFailure`, `newerPageFailure`, `needsCatchUp`, `isAwayFromLatest`, `retryOlderPage()`, `retryNewerPage()`, `setAwayFromLatest(_:)` and `Timeline.seqReorder`.
- `RoomSession.pageTimeout` (15 seconds), `Timeline.pageNotLoaded`, `Timeline.olderPageFailed(_:)`, `Timeline.newerPageFailed(_:)` and `ThreadTimeline.olderPageFailed(_:)`.
- `EmberClient.checkServer()`, which answers a `ServerCheck`: the bootstrap and the origin the server answered from after redirects.
- `EmberClient.signOutReason`, a `SignOutReason` of `.asked` or `.sessionEnded`, saying why someone was last signed out.
- `ServerAddress.normalizedOrigin(_:)`, `isLocal(_:)` and `needsHTTPS(_:)`.
- `NetworkPathSource` and `SystemNetworkPath`, which tell sockets when the device has a network. `EmberClient` and `ReconnectingSocket` take one in new initialisers, and `ReconnectingSocket.isNetworkAvailable` and `Workspace.isNetworkAvailable` report it. EmberTesting has `MockNetworkPath`, and `EmberClient.mock` takes one.
- `EmberTiming.reconnectFloor`, `stablePeriod`, `sidebarRefresh`, `directoryRefresh` and `reconnectDelay()`.
- `BackgroundTime` and `RoomSession.backgroundTime`, which ask the system for time to finish an upload as the app goes to the background.
- `Workspace.thread(_:in:at:)`, which opens a thread without moving its room's page.
- `AvatarStyle.initials(of:atMost:)`.
- `EmberBot`, a client for the server's keyed bot API. It is made from a server address, a room and a bot key, needs no signed-in `EmberClient`, and posts text, HTML or a file to the room and boosts a message. The key is never in its description, its debug output or an error.
- `EmberClient.message(_:in:)`, which fetches one message of a room once.
- `KeychainCookieStorage`, one account's cookies kept in memory and written to a `CookieVault` whenever they change, so two accounts on one server never share a session cookie. `KeychainCookieVault` keeps them in a Keychain item (readable after first unlock, this device only), and `KeychainCookieVault.accounts(service:)` lists the items there; `MemoryCookieVault` is for tests. A vault's calls throw when it can't do them (`KeychainCookieVault.Failure` carries the `OSStatus`), and `read()` answers nil only when nothing is kept. A write the vault refuses is tried again at the next change; after a read that failed, `readFailure` says why and the storage never erases or overwrites the kept item for holding nothing; `syncVault()` reads and writes again now, and answers whether the vault is up to date. `EphemeralCookieStorage` is no longer `final`.
- `RichText.segments(_:mentions:)`, `RichText.mentionRanges(in:mentions:)` and `EditableBody.body(editedTo:mentions:)`, which turn "@Name" typed in plain text into mentions of the people named.
- `SearchSession`, an observable search for a screen to hold: the query being edited, the matches, further pages, recent searches and the state of the search.
- The stand-in server answers the bot API, and lists bot keys to an administrator at `GET /api/account/bots`. `Tools/mock-server/check.mjs` checks both.
- README sections on sending plain text, unsent messages and Retry, changes that throw, signing out and why, checking a server, network status, search, one message, bots, and app extensions and widgets, each sample run by a test. A compatibility table names the upstream Ember commit the SDK was built against.
- A CI workflow that runs `swift test` and the stand-in server check on macOS.
- `ManualClock.sleeperCount(dueWithin:)`, how many waiting sleeps a move of that length would wake, so a test can wait for a timer to be sleeping before it moves the clock.

### Changed

- `Role`, `UserStatus`, `RoomKind`, `Involvement` and `Bootstrap.Setup` keep a value this build doesn't know as `.unknown(String)` instead of reading it as a fallback, and write it back unchanged. They conform to the new `OpenEnum` protocol, which replaces `FallbackDecodable`, and the `fallback` members are gone. A `switch` over one of them needs a case for `.unknown`. `init(rawValue:)` still answers nil for an unknown value; `init(_:)` keeps it, and `isKnown` says which it is. An unknown value answers no to every question: not an administrator or a bot, not active, neither open nor direct, neither hidden nor muted, and not waiting for setup.
- `EmberBot.post(text:)` now sends plain text, escaped as `RoomSession.send(text:)` escapes it, and throws `.invalid` for blank or over-long text. Use `post(html:)` to send markup as it is.
- `EmberError.isUnreachable` now reads `kind`. It answers as before for every error the SDK made before.
- `Workspace.sharedRooms`, `directRooms`, `suggestedPeople` and `unreadRooms` are stored, and sorted once per change, instead of being worked out on every read.
- A retried upload goes on from the parts the server already took. A part is tried again with backoff after no answer, 408, 429 or a 5xx.
- `EmberSDK` now depends on `EmberRichText`.

### Fixed

- `RoomSession.loadOlder()` and `loadNewer()` called while the room was reconnecting did nothing, so a view that asks once at the top of a page never asked again and older paging stopped until the room was reopened. The page now goes once the room lets the socket in, unless a jump or a new page has replaced the messages it was for.
- A page of older or newer messages the room never answered left paging stuck with no failure, and one on its way when the socket dropped was forgotten without one, so no retry showed and scrolling up loaded nothing again until the room was reopened. Either now fails as a refused page does, `retryOlder()` and `retryNewer()` ask again, and paging works after any failure. A thread's older page does the same, with its `notice`.
- A message or reply sent while the room was reconnecting stayed pending until the connection came back, however long. It's now timed from when it was sent, and fails with `RoomSession.notSent` after `sendTimeout`; one that failed before it was written isn't sent when the connection returns, and Retry asks the room first as before.
- An async edit, delete, boost or boost removal asked for while the room was reconnecting threw `.unreachable` at once. They now wait for the room to let the socket in, timed from when they were asked for, and throw `.timedOut` after `changeTimeout`; one that timed out is never sent.
- A message sent while the socket was reconnecting could be lost: it wasn't counted as busy, and leaving the room closed the socket under it. An unsent message now keeps the socket open until it's confirmed, failed or discarded.
- Nothing was saved before a room's first welcome. A room made by `Workspace` now saves what's typed from the start.
- An async edit timed out when the server's sanitising left the body as it was, or stored a different body from the one sent.
- One message the SDK couldn't read lost the whole frame it came in; it is now left out on its own. A message's unreadable optional parts are dropped one by one.
- A message that arrived out of order went at the end; it now goes in its place. A change heard twice is ignored, and a gap that lasts three changes reconnects to fetch what was missed.
- After a long outage, the newest page replaced the window someone had scrolled up to. A welcome that overlaps the window is now merged in.
- A failed older or newer page was asked for again and again. It now waits for a retry, a jump or a reconnect.
- A 4001 close reconnected at once, and backoff reset on the first frame heard. A 4001 now waits about `reconnectFloor`, and backoff resets only after `stablePeriod` open.
- An upgrade refused with a 4xx other than 401, 408 or 429 retried forever. It now stops with `StopReason.refused(status:)`.
- A late 401 from a replaced session signed the new one out.
- Origins were compared in more than one form; one form, `normalizedOrigin`, is now used for the Origin header, socket addresses and same-origin checks. A bare private address defaulted to `https`.
- A socket waiting to reconnect kept using up its backoff while the device had no network, and didn't try again as soon as the network came back.
- Opening a room normally after a search jump stayed on the page around that message.
- A file that couldn't be read was reported as the server being unreachable.
- The stand-in server's search took time that grew with the square of a room's length. It is now linear.
- Retry on a message that failed as not sent could post it twice, as the room stores a create twice. `retry` now asks with `message.check` first and sends again only when the room says it's missing, and failed texts are asked about after each reconnect. The stand-in server no longer de-duplicates a create, so it behaves as the real one does.
- A thread reply held behind a file, or sent while a check on it was on its way, could be posted twice: the check came back saying the reply was missing and created it again. A reply is now remembered as created once it's sent, as a room message is.
- A session ended that a room socket found (closed as revoked, or its upgrade refused 401) left `signOutReason` as `.asked` once the app signed out. It is now `.sessionEnded` before the app hears, and a sign-out someone asked for still says `.asked`.
- The SDK's own tests of reconnecting, timeouts and typing failed now and then on a busy machine: they moved the clock before the timer they meant to fire was sleeping. They now wait for that sleep first.

