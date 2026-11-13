# Stand-in Ember server

A small Node server (no dependencies, Node 18 or later) that speaks Ember's HTTP and WebSocket protocol closely enough for the Swift SDK's live tests and the iOS app. The real server runs on Cloudflare Workers and Durable Objects, which can't run locally. State is in memory and resets on every start.

## Running it

    node server.mjs
    node check.mjs http://127.0.0.1:8787

`check.mjs` starts nothing. It prints a pass or fail line per check and exits non-zero if any failed. Run it against a freshly started server, because a first run reads the seeded unread marks.

| Variable | Meaning |
| --- | --- |
| `PORT` | Port to listen on. Default 8787. |
| `HOST` | Address to bind. Default 127.0.0.1. |
| `EMBER_SEED_PASSWORD` | The shared password for every seeded account. |
| `EMBER_GUEST_SIGN_IN` | `1` turns on signing in with just a name. Otherwise `POST /api/session {name}` answers 403. |
| `EMBER_REPLIER` | `0` turns off the scripted replier. |
| `EMBER_WORKSPACE_NAME` | The workspace's name in the bootstrap and welcome. Default Fernwood. Messages still say Fernwood. |
| `EMBER_SEARCH_PAGE` | Search page size. Default 100. Lower it to test paging. |
| `MEDIA_ORIGIN` | Origin written into the seeded cards' image URLs. Default `http://media.localhost:<PORT>`. |
| `EMBER_BOT_DELAY` | Milliseconds before a scripted bot posts its card. Default 1500. |
| `EMBER_BOT_REPLACE_DELAY` | Milliseconds before the alert bot replaces its card. Default 6000. |

The password is read from `EMBER_SEED_PASSWORD`, or else from `.dev/seed-password` at the root of the SDK checkout. If neither exists the server exits and says where it looked. The server and the checker never print it.

## Seeded accounts

Everyone signs in with the shared password.

- Maya Chen, maya@example.com (administrator)
- Sam Rivera, sam@example.com
- Priya Patel, priya@example.com
- Leo Park, leo@example.com
- Jordan Lee, jordan@example.com
- Amara Okafor, amara@example.com
- Tomás García, tomas@example.com

Ember, the assistant, has the id `ember`. Deploy Bot and Uptime are bots.

## Rooms

- general: about 150 messages over six days from several people, with some boosts. Use it for history paging.
- random: the scripted replier answers as Jordan.
- Launch: rich bodies (lists, code, links, quotes, mentions, emoji-only, strikethrough), an edited message, a thread, boosts. Starred by Maya.
- Design: an SVG attachment.
- Engineering: bot posts, ending in seven card messages (below). Unread for Maya.
- Support.
- Leadership: closed. Maya, Sam and Priya only.
- Direct messages: Sam and Maya (unread for Maya, with the scripted replier answering as Sam), Priya and Maya, and a group of Leo, Maya and Jordan.

Everyone belongs to every open room. The administrator invitation is left showing for Maya.

The replier starts typing 700 ms after a message and replies about two seconds later.

## Implemented

Bootstrap, sign-in and sign-out, me, sidebar and users with ETags, favourites, involvement, starting direct messages, search with filters and recent searches, avatars, uploads and file serving, and the workspace socket and room sockets. The room socket handles welcome, resume with `since`, `around`, history paging, create, update, delete, boosts, typing, presence, read marks and `message.check`.

Cross-site writes are refused with 422, and a socket from the wrong origin gets 404, as on the real server. Signing out closes that session's sockets with 4003.

## Uploads and files

`POST /api/rooms/:id/uploads` starts an upload and answers `{id, partSize, parts}` (10 MiB parts, 250,000,000 bytes at most). `PUT .../uploads/:id/parts/:n` takes each part, any order once part 1 is in, and the part that completes the set posts the file's message with a 201. `PUT .../uploads/:id/preview` takes a WebP, JPEG or PNG of at most 1200×800 and 5 MiB, until the file is posted. A reply upload takes `parentId` and `alsoSend`.

Files are served at `/files/<key>/<signature>/<name>` and `/previews/...`, signed with a per-process secret, so no cookie is needed. The name is only for show. Ranges (single, suffix, open, multipart, 416), `HEAD` and `If-Modified-Since` follow Rack. Images and PDFs are inline; everything else, SVG and HTML included, is served as `application/octet-stream` attachment. The seeded `palette.svg` in Design is served this way.

Not mirrored: EXIF orientation swaps, TIFF, HEIF and AVIF header sizes, the 24-hour purge of unfinished uploads, and the 429 and 503 branches. Files live in memory, so a restart loses them. File names are transliterated approximately. Content types are chosen by magic bytes, then the declared type, then the extension.

## Threads

Replies always carry `alsoSent`, and a thread's `people` are newest replier first. A deleted parent with replies stays as a tombstone that still takes replies; removing its last reply removes it too, with its own `message.deleted`. Resume sends only messages in the room's timeline and falls back to a welcome when more than 100 changes behind. Page limits are floored and held to 1..100. Frames are validated as the real parser does, so a `parentId` of null or a `message.check` of none or over 50 ids is `Unrecognized frame`.

## Cards

Messages can carry `cards`, stored already translated to Ember's wire shape; the key is absent when there are none. The Slack translator and `/slack` webhook are not ported. A client frame can never set cards. A card message's `plainText` is its text, then one line per card part, joined by newlines.

Engineering ends with seven card messages, the newest things in the room: a deploy blocks card (26 h ago), an uptime alert and its resolution, a deploy summary with a table, a CI attachment with pretext, thumb and image, tiles, and a certificate warning (90 min ago). Times are relative to start-up.

Card images are generated PNGs at `GET /card-media/<name>.png` (`avatar`, `icon`, `thumb`, `chart`, `hero-1`, `hero-2`), served with any Host and no session, so `media.localhost` works.

Editing a card message answers `Messages with cards can't be edited.` (`failed: "message.update"`). Boosts and deletes work.

While the replier is on, a person's top-level message in Engineering containing "deploy" (any case) brings a Deploy Bot card after `EMBER_BOT_DELAY`, and "alert" brings an Uptime alert card that Uptime replaces `EMBER_BOT_REPLACE_DELAY` later with plain text. The replacement drops the cards and everyone connected gets `message.updated` without a `cards` key.

## Bots

`POST /rooms/:room/:key/messages` and `POST /rooms/:room/:key/messages/:id/boosts` are the keyed bot API: no session or cookie, and the key is `<bot id>-<token>`. A text body is the message's markup whatever its type. A multipart body with an `attachment` file posts a file. A message answers 201 with the permalink in `Location` and no body; a boost answers 201 with `{id, content, created_at, booster, message}`. A key that is no bot's is 401 `Unknown bot key`; a bot that isn't in the room, a missing message, or a blank body is an empty 404 or 422, as the real server answers.

Deploy Bot and Uptime are in Engineering. Their keys are made at start-up, and an administrator reads them from `GET /api/account/bots`. Not ported: reading, editing and deleting through a key, removing a boost, and the `/slack` webhook.

## Rooms, people and getting in

Routes, messages, permissions and socket frames follow the real worker.

| Route | Answer | Frames |
| --- | --- | --- |
| `POST /api/rooms` | 201 `{room}` | `room.saved` to its members |
| `GET /api/rooms/new` | `{people}` | |
| `GET /api/rooms/:id/settings` | `{room, canAdminister, people}`; 404 for a non-member or a DM | |
| `PATCH /api/rooms/:id` | `{room}`; administrators and the creator | `room.saved`, and `room.gone` plus a 4004 socket close for people removed |
| `DELETE /api/rooms/:id` | 204; administrators and the creator, any member for a DM | `room.gone`, sockets closed 4004 |
| `PUT /api/sidebar/order` | `{favorites}` | `favorites.changed` to that person |
| `PUT /api/account/room_order` | `{sharedOrder}`; administrators | `rooms.reordered` to everyone |
| `DELETE /api/sidebar/invitation` | 204 | `invitation.dismissed` to that person |
| `GET`, `PATCH /api/users/me/profile` | `{profile, transferId}` | `user.updated` to everyone |
| `PUT`, `DELETE /api/users/me/avatar` | `{profile}` | `user.updated` to everyone |
| `GET /api/users/:id` | `{person}`; administrators also get the email address and `transferId` | |
| `POST`, `DELETE /api/users/:id/ban` | `{user}`; administrators | `user.updated`; a ban ends their sessions (close 4003) and deletes their messages |
| `POST /api/session/transfers` | 201 `{user}` and a cookie; an empty 400 for any failure | |
| `POST`, `PUT /api/password_resets` | 202, then 201 `{user}`; a reset ends every other session (close 4001) | |
| `POST /api/invitations`, `POST /api/invitations/:id/resend`, `DELETE /api/invitations/:id` | `{outcomes}`, `{invitation, link}`, 204; administrators | |
| `GET /api/account` | `{account, joinCode, invitations, ...}`; members get no invitations | |
| `POST /api/email_links/lookup` | `{kind, emailAddress}` or 404 | |
| `POST /api/unfurl` | 200 preview, 204 none, 429 past 30 a minute | |

Banned people and bots can't sign in. A changed password replaces the shared seed password for that person.

### No email: the log and the outbox

The mock sends nothing. Where the real server would email, it prints to stdout:

    RESET CODE <address> <code>
    INVITATION LINK <address> <url>

The same are returned by `GET /mock/outbox` (mock only, no sign-in): `{resetCodes: [{emailAddress, code, expiresAt}], invitationLinks: [{emailAddress, link}]}`, newest link per address. A reset code is 8 digits, lasts 15 minutes and allows 5 wrong tries. Invitation links look like `http://<host>/join/invitation#token=<43 characters>`; resending or inviting again replaces the link. A reset is only "sent" to an active, non-bot person. Bootstrap says `passwordResetCodes: true`.

### Seeded invitations

`first.guest@example.com` and `second.guest@example.com` are pending at start; their links are logged at start-up and are the same each run. Maya's sidebar carries the invitation card (room and join code); dismissing it is per person.

### Link previews

`POST /api/unfurl` has no network access. An `http` or `https` address on `example.com` or any subdomain gets `{title: "Example Domain", url, image: null, description}`; every other address, a non-string, and this server's own address get 204.

### Differences from the real server

- No IP bans, Turnstile, email rate limits or `PASSWORD_RESETS_LIMITED`; no real email.
- A new avatar never refuses for being too soon; its version moves to a later second instead.
- Room icons are accepted by pattern (lower-case words joined by hyphens, at most 64 characters), not the real list.
- Room creation is never restricted to administrators.
- The shared room order is one list for everyone, so `room_order` keeps ranks of rooms the administrator can't see.
- A closed room made through the API holds only the listed people, as on the real server.
- Seeded invitation tokens are derived from the address; real ones are random.

## Not implemented

Real email, join codes beyond the seeded one, push notifications, rate limits, and persistence. Search matches prefixes of words, which approximates the real full-text index.
