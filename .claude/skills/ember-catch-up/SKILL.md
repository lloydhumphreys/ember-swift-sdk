---
name: ember-catch-up
description: Check whether upstream Ember (NYLLON-SOFTWARE/ember-cloudflare) has moved past the version this SDK speaks, work out what a client must change, and bring the SDK, mock server and tests up to it. Use when asked to catch up with Ember, check for upstream changes, or prepare an SDK release for a new Ember beta.
---

# Catching up with Ember

The SDK speaks one upstream Ember version at a time. Every WebSocket frame and API shape is typed in
`packages/protocol`, so diffing that folder between the pinned version and the new one is the quickest
way to see what a client needs to change. Everything else (worker handlers, web hooks) is read only to
learn behaviour the types don't say.

Repos: this SDK (`~/Code/ember-swift-sdk`), upstream (`~/Code/ember-cloudflare`), the iOS app
(`~/Code/ember-ios`). Clone upstream there if it's missing.

## 1. Where we are and where Ember is

```sh
grep -n "Upstream" README.md                     # pinned tag and commit, e.g. v0.5.0-beta.12 (30755b2a)
sed -n '1,30p' CHANGELOG.md                      # what's unreleased
cd ~/Code/ember-cloudflare
git fetch -q origin main --tags
git tag --sort=-creatordate | head -5            # newest release tags (v0.5.0-beta.N, v0.5.0, …)
git log --oneline <pinned>..origin/main          # what's landed on main since, not yet released
gh release view <tag> --repo NYLLON-SOFTWARE/ember-cloudflare --json body -q .body   # PR list
```

Target the newest **tag**. Changes only on `main` are previews: report them, but don't ship them
unless the user asks, since they can still change before release.

If nothing in `packages/protocol` changed, say so and stop: no SDK update is needed (worker-only
changes can still matter; skim step 2's behaviour files to be sure).

## 2. What changed

```sh
git diff --stat <pinned> <target> -- packages/protocol
git diff <pinned> <target> -- packages/protocol/src/index.ts      # frames, models, limits, ROOM_PROTOCOL
git diff <pinned> <target> -- packages/protocol/src ':!*.test.ts' # the other shapes (search, push, cards…)
```

Look for, in `index.ts`:
- `ClientFrame`, `ServerFrame` (room socket), `WorkspaceClientFrame`, `WorkspaceServerFrame` (workspace socket)
- `ROOM_PROTOCOL` and the socket URL builders (query parameters)
- interfaces answered by `GET /api/...` (`Sidebar`, `RoomSettings`, `NewRoomForm`, …) and request bodies (`NewRoom`, `RoomChanges`, …)
- `MAX_*` limits and refusal messages
- `parse*` functions: they say what the server accepts and refuses

Then, for behaviour the types don't spell out:
- routes: `git diff <pinned> <target> -- apps/worker/src/index.ts | grep -E '^\+.*pathname'`
- handlers: `apps/worker/src/` (`workspace.ts`, `workspace-store.ts`, `chat-room.ts`, `presence.ts`, `viewing.ts`)
- how the web client uses it: `apps/web/src/hooks/` (`use-sidebar.ts`, `use-room.ts`) and `apps/web/src/lib/` (`presence.ts`)

## 3. Where it goes in the SDK

| Upstream | SDK |
|---|---|
| Frame unions | `Sources/EmberCore/Frames.swift` (unknown types decode as `.unknown`; read new optional fields leniently with `Lenient`/`Lossy`) |
| Models, `Sidebar`, `Room`, `Message` | `Sources/EmberCore/Models.swift`, `SidebarState.swift`, `RoomList.swift` |
| Timeline behaviour | `Sources/EmberCore/Timeline.swift`, `ThreadTimeline.swift` |
| Room settings, new rooms | `Sources/EmberCore/Rooms.swift`, `Sources/EmberSDK/EmberClient+Rooms.swift` |
| Search, uploads, cards, invitations, profiles | the matching file in `Sources/EmberCore` and `Sources/EmberSDK/EmberClient+*.swift` |
| Workspace socket, presence | `Sources/EmberSDK/Workspace.swift` |
| Room socket, `ROOM_PROTOCOL` | `Sources/EmberSDK/RoomSession.swift`, `ThreadSession.swift` |
| `MAX_*` limits | the `Limits` constants (`grep -rn "enum Limits" Sources`) |
| Fixtures | `Sources/EmberTesting/` |

Keep decoding lenient: an older or newer server must never make a whole frame or sidebar fail.
Anything removed upstream is a breaking change for SDK users; note it as such.

## 4. Mock server and tests

The stand-in server in `Tools/mock-server` (`store.mjs`, `server.mjs`, `seed.mjs`, `check.mjs`, its
README) must answer as the target does. Add each new route, field and frame there, and a check for it
in `check.mjs`. Add unit tests in `Tests/` beside the ones for the code you touched.

Run all three (the live tests need the mock server; the seed password is in `.dev/seed-password`,
never print it):

```sh
swift test
(cd Tools/mock-server && PORT=8799 node server.mjs) &     # then:
node Tools/mock-server/check.mjs http://127.0.0.1:8799     # expect 0 failures; stop the server after
(cd Tools/mock-server && PORT=8798 node server.mjs) &     # a fresh one for the live tests
EMBER_TEST_ORIGIN=http://127.0.0.1:8798 swift test --filter EmberLiveTests
```

Each check needs a freshly started server, since they change its data.

## 5. Docs and release

- `README.md` Upstream row: tag, short commit, date of the target.
- `CHANGELOG.md` under `## [Unreleased]`: "Tracks upstream Ember `<tag>` (commit `<sha>`)", then Added / Changed / Removed / Fixed.
- `Testing.md` if the mock server or test setup changed.

The SDK keeps its own version numbers (not Ember's). Breaking changes bump the minor while < 1.0.
Ask the user which version before releasing. Release pattern, only when the user asks:
1. work commit (e.g. "Speak Ember v0.5.0-beta.13")
2. "Changelog for X.Y.Z" (moves Unreleased to the version, dated)
3. "README installs X.Y.Z" (install line `.upToNextMinor(from: "X.Y.Z")`)
4. annotated tag `X.Y.Z` on main, message: `X.Y.Z: speaks Ember <tag> (<sha>)` and a short bullet summary of what changed
5. push main and the tag

No co-author or "generated with" lines in commits. Never comment on PRs.

## 6. iOS app

Note what `~/Code/ember-ios` needs: removed API it uses, new things worth showing. After a release,
bump `exactVersion` in its `project.yml`, regenerate with xcodegen, and build.

## 7. Report

Tell the user, briefly:
- pinned version → newest tag, and whether `main` is ahead (and with what)
- whether an SDK update is needed, and the list of changes it needs (breaking ones first)
- what the iOS app would need
- what you did, and the test results, if you went ahead
