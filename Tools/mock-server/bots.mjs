// The keyed bot API: a bot posts text or a file to a room it is in, and boosts a message, at
// /rooms/<room id>/<bot key>/messages. The key is all a bot has, so these routes never read a session cookie.
// A bot's key is `<bot id>-<token>`; tokens are made at start-up and an administrator reads them from
// GET /api/account/bots, as on the real server. Not ported: reading, editing and deleting messages, removing
// a boost, and the /slack webhook.

import { timingSafeEqual } from "node:crypto";
import { MAX_BOOST_LENGTH, MAX_MESSAGE_HTML_LENGTH, randomBase36, sortableId } from "./store.mjs";
import { sanitizedFilename, sniff } from "./files.mjs";

const MESSAGES = /^\/rooms\/([^/.]+)\/([^/.]+)\/messages(?:\.json)?$/;
const BOOSTS = /^\/rooms\/([^/.]+)\/([^/.]+)\/messages\/([^/.]+)\/boosts(?:\.json)?$/;
const MAX_BODY_BYTES = 3 * MAX_MESSAGE_HTML_LENGTH;
const JSON_TYPE = "application/json; charset=utf-8";
const NOT_A_FILE = "An attachment has to be a file";

const segmentText = (segment) => {
  try {
    return decodeURIComponent(segment);
  } catch {
    return "";
  }
};

/// The part of a multipart body named `attachment`, as `{ filename, contentType, bytes }` for a file, `{ text: true }`
/// for a field that isn't one, or null when there is none. A part with an empty filename is skipped, as Rack skips it.
function attachmentIn(body, boundary) {
  const delimiter = Buffer.from(`--${boundary}`);
  let at = body.indexOf(delimiter);
  while (at !== -1) {
    const start = at + delimiter.length;
    if (body.subarray(start, start + 2).toString() === "--") return null;
    const headEnd = body.indexOf("\r\n\r\n", start);
    if (headEnd === -1) return null;
    const next = body.indexOf(Buffer.from(`\r\n--${boundary}`), headEnd + 4);
    if (next === -1) return null;
    const head = body.subarray(start, headEnd).toString("utf8");
    const disposition = /^content-disposition:\s*form-data;(.*)$/im.exec(head)?.[1] ?? "";
    const name = /\bname="([^"]*)"/.exec(disposition)?.[1];
    const filename = /\bfilename="([^"]*)"/.exec(disposition)?.[1];
    if (name === "attachment" && filename !== "") {
      if (filename === undefined) return { text: true };
      const contentType = /^content-type:\s*(.+)$/im.exec(head)?.[1]?.trim() ?? "";
      return { filename: decodeURIComponent(filename.replace(/%(?![0-9a-f]{2})/gi, "%25")), contentType, bytes: body.subarray(headEnd + 4, next) };
    }
    at = body.indexOf(delimiter, next);
  }
  return null;
}

export function createBotApi({ store, files, avatarToken, readRaw }) {
  const tokens = new Map();
  for (const user of store.users.values()) if (user.role === "bot") tokens.set(user.id, randomBase36(12));
  const keyOf = (user) => `${user.id}-${tokens.get(user.id)}`;

  /// The bots as GET /api/account/bots lists them: each with its key and the rooms it is in.
  const listed = () =>
    [...store.users.values()]
      .filter((user) => tokens.has(user.id))
      .map((user) => ({
        ...store.directoryUser(user, avatarToken),
        key: keyOf(user),
        rooms: [...store.rooms.values()].filter((room) => room.kind !== "direct" && room.members.has(user.id)).map((room) => ({ id: room.id, name: room.name })),
      }));

  const empty = (res, status) => {
    res.writeHead(status, { "Content-Type": "text/html" });
    res.end();
  };
  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { "Content-Type": JSON_TYPE, ...headers });
    res.end(JSON.stringify(body));
  };
  const originOf = (req) => `http://${req.headers.host ?? "localhost"}`;
  const permalink = (req, room, message) => `${originOf(req)}/rooms/${room.id}/@${message.id}`;

  /// The bot and room a request is for, or null once the response says why not: 401 for a key that is no bot's, and an
  /// empty 404 for a bot that is not in the room.
  function access(req, res, roomId, key) {
    const [botId, token] = segmentText(key).trim().split("-");
    const given = Buffer.from(token ?? "");
    const wanted = Buffer.from(tokens.get(botId) ?? "");
    const bot = botId && token && given.length === wanted.length && timingSafeEqual(given, wanted) ? store.users.get(botId) : undefined;
    if (!bot) {
      json(res, 401, { error: "Unknown bot key" });
      return null;
    }
    const room = store.rooms.get(roomId);
    if (!room?.members.has(bot.id)) {
      empty(res, 404);
      return null;
    }
    return { bot, room };
  }

  async function postMessage(req, res, roomId, key) {
    const found = access(req, res, roomId, key);
    if (!found) return;
    const { bytes, size } = await readRaw(req, MAX_BODY_BYTES);
    if (size > MAX_BODY_BYTES) return json(res, 413, { status: 413, error: "Content Too Large" });
    const type = req.headers["content-type"] ?? "";
    const boundary = /^multipart\/form-data;.*boundary=("?)([^";]+)\1/i.exec(type)?.[2];
    if (/^multipart\/form-data/i.test(type) && !boundary) return json(res, 400, { status: 400, error: "Bad Request" });
    // The key is checked again once the body has arrived, as the real server does.
    const arrived = access(req, res, roomId, key);
    if (!arrived) return;
    let created;
    if (boundary) {
      const attachment = attachmentIn(bytes, boundary);
      if (attachment?.text) return json(res, 422, { error: NOT_A_FILE });
      if (!attachment) return empty(res, 422);
      const name = sanitizedFilename(attachment.filename);
      const kept = files.keep({
        key: randomBase36(28),
        name,
        contentType: sniff(attachment.bytes.subarray(0, 4096), attachment.contentType, attachment.filename),
        bytes: attachment.bytes,
        uploadedAt: Date.now(),
      });
      created = store.createMessage(arrived.room, arrived.bot.id, { clientMessageId: sortableId(), attachment: kept });
    } else {
      const markup = bytes.toString("utf8");
      if (markup.trim() === "") return empty(res, 422);
      if (markup.length > MAX_MESSAGE_HTML_LENGTH) return json(res, 413, { status: 413, error: "Content Too Large" });
      created = store.createMessage(arrived.room, arrived.bot.id, { clientMessageId: sortableId(), body: markup });
    }
    if (created.error) return json(res, 422, { error: created.error.message });
    json(res, 201, null, { Location: permalink(req, arrived.room, created.message) });
  }

  async function postBoost(req, res, roomId, key, messageId) {
    const found = access(req, res, roomId, key);
    if (!found) return;
    const { bytes, size } = await readRaw(req, MAX_BODY_BYTES);
    if (size > MAX_BODY_BYTES) return json(res, 413, { status: 413, error: "Content Too Large" });
    const arrived = access(req, res, roomId, key);
    if (!arrived) return;
    const { room, bot } = arrived;
    const message = room.messages.find((candidate) => candidate.id === messageId);
    if (!message || message.deleted) return empty(res, 404);
    const content = bytes.toString("utf8").trim();
    if (content === "") return empty(res, 422);
    if (content.length > MAX_BOOST_LENGTH) return json(res, 422, { error: `Boosts can be up to ${MAX_BOOST_LENGTH} characters.` });
    const result = store.createBoost(room, bot.id, { messageId, content });
    if (result.error) return json(res, 422, { error: result.error.message });
    const boost = message.boosts.find((candidate) => candidate.userId === bot.id && candidate.content === content);
    const booster = store.directoryUser(bot, avatarToken);
    json(res, 201, {
      id: boost.id,
      content: boost.content,
      created_at: new Date(boost.createdAt).toISOString(),
      booster: { id: booster.id, name: booster.name, role: booster.role, avatar_url: `${originOf(req)}${booster.avatarUrl}` },
      message: { id: message.id, url: permalink(req, room, message) },
    });
  }

  /// Answers the request if it is for the bot API, and says whether it was.
  async function handle(req, res, url) {
    const method = req.method ?? "GET";
    const messages = MESSAGES.exec(url.pathname);
    if (messages && method === "POST") return await postMessage(req, res, messages[1], messages[2]), true;
    const boosts = BOOSTS.exec(url.pathname);
    if (boosts && method === "POST") return await postBoost(req, res, boosts[1], boosts[2], boosts[3]), true;
    return false;
  }

  return { handle, listed, keyOf };
}
