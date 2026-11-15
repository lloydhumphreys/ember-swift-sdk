# Testing

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
