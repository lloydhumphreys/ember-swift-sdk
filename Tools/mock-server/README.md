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

## Not implemented

Real email, invitations and join codes beyond the seeded one, user management, push notifications, rate limits, and persistence. Search matches prefixes of words, which approximates the real full-text index.
