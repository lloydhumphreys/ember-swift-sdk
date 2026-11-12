#!/usr/bin/env node
// A stand-in Ember: the HTTP and WebSocket protocol of the real server (Cloudflare Workers and Durable
// Objects, which can't be run here), over state kept in memory and the same cast Ember's own seed makes.
// Plain Node with no dependencies. See README.md.

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_PREVIEW_BYTES, PART_SIZE, files } from "./files.mjs";
import { createBotApi } from "./bots.mjs";
import { cardPicture, keptCards } from "./cards.mjs";
import { PEOPLE, deployCards, seed } from "./seed.mjs";
import { HISTORY_PAGE_SIZE, MAX_BOOST_LENGTH, Store, randomBase36, sortableId } from "./store.mjs";
import { acceptWebSocket, refuseUpgrade } from "./ws.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PASSWORD_FILE = path.resolve(HERE, "../../.dev/seed-password");
const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? "127.0.0.1";
const GUEST_SIGN_IN = process.env.EMBER_GUEST_SIGN_IN === "1";
const REPLIER = process.env.EMBER_REPLIER !== "0";
const MEDIA_ORIGIN = (process.env.MEDIA_ORIGIN ?? `http://media.localhost:${PORT}`).replace(/\/+$/, "");
/// How long after a person's message the scripted card bots post, and how long Uptime then waits to replace its alert.
const delayOf = (name, fallback) => (Number.isFinite(Number(process.env[name])) && process.env[name] !== undefined && process.env[name] !== "" ? Math.max(0, Number(process.env[name])) : fallback);
const BOT_DELAY = delayOf("EMBER_BOT_DELAY", 1500);
const BOT_REPLACE_DELAY = delayOf("EMBER_BOT_REPLACE_DELAY", 6000);
const COOKIE = "session_token";
const COOKIE_MAX_AGE = 400 * 24 * 60 * 60;
const ROOM_PROTOCOL = 4;
const ROOM_ID = /^[a-z0-9][a-z0-9-]{0,62}$/;
const MAX_LISTED_USERS = 1000;
const OUTDATED = "Ember has been updated. Reload the page to keep chatting.";
const SIGN_IN_REJECTED = "Incorrect email or password. Please try again.";
const VERSION = "mock-1";

/// The password everyone seeded shares: the environment's, or else the file's. It never leaves this function but as a digest.
function sharedPasswordDigest() {
  let password = process.env.EMBER_SEED_PASSWORD;
  if (!password && existsSync(PASSWORD_FILE)) password = readFileSync(PASSWORD_FILE, "utf8");
  password = password?.trim();
  if (!password) {
    console.error(`No seed password. Set EMBER_SEED_PASSWORD, or put one in ${PASSWORD_FILE}.`);
    process.exit(2);
  }
  return createHash("sha256").update(password).digest();
}

const passwordDigest = sharedPasswordDigest();
const passwordMatches = (given) => timingSafeEqual(createHash("sha256").update(given).digest(), passwordDigest);

const store = new Store();
const { people, rooms, bots: seededBots } = seed(store, Date.now(), { mediaOrigin: MEDIA_ORIGIN });
const avatarSecret = randomBytes(32);
const avatarToken = (userId) => `${userId}.${createHmac("sha256", avatarSecret).update(`avatar:${userId}`).digest("base64url").slice(0, 22)}`;
const avatarTokenUser = (token) => {
  const userId = token.slice(0, Math.max(token.lastIndexOf("."), 0));
  if (!userId) return null;
  const expected = Buffer.from(avatarToken(userId));
  const given = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected) ? userId : null;
};

// Who is connected

/// A workspace socket: { conn, userId, token }.
const workspaceSockets = new Set();
/// A room socket: { conn, userId, token, roomId, visible }.
const roomSockets = new Set();
const typingIn = new Map();

const send = (conn, frame) => conn.send(JSON.stringify(frame));

store.hub = {
  room(roomId, frame, { exceptUser } = {}) {
    const text = JSON.stringify(frame);
    for (const socket of roomSockets) if (socket.roomId === roomId && socket.userId !== exceptUser) socket.conn.send(text);
  },
  workspace(userId, frame) {
    const text = JSON.stringify(frame);
    for (const socket of workspaceSockets) if (socket.userId === userId) socket.conn.send(text);
  },
  viewers(roomId) {
    const viewers = new Set();
    for (const socket of roomSockets) if (socket.roomId === roomId && socket.visible) viewers.add(socket.userId);
    return viewers;
  },
  present(roomId) {
    const present = [];
    for (const socket of roomSockets) if (socket.roomId === roomId && !present.includes(socket.userId)) present.push(socket.userId);
    return present;
  },
  typing(roomId, userId, typing) {
    let set = typingIn.get(roomId);
    if (!set) typingIn.set(roomId, (set = new Set()));
    const was = set.has(userId);
    if (typing) set.add(userId);
    else set.delete(userId);
    if (was !== typing) this.room(roomId, { type: "typing", user: store.ref(userId), typing }, { exceptUser: userId });
  },
};

// HTTP

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };

function reply(res, status, body, headers = {}) {
  if (status === 204 || status === 304) {
    res.writeHead(status, headers);
    return res.end();
  }
  res.writeHead(status, { ...jsonHeaders, ...headers });
  res.end(JSON.stringify(body));
}

const fail = (res, status, message, extra = {}) => reply(res, status, { error: message, ...extra });

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size <= 2_000_000) chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(size === 0 ? undefined : JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        resolve(undefined);
      }
    });
    req.on("error", () => resolve(undefined));
  });
}

/// A body as bytes, keeping no more than `limit` of them. `size` is how many arrived, so a caller can tell it was too long.
function readRaw(req, limit) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size <= limit) chunks.push(chunk);
    });
    req.on("end", () => resolve({ bytes: Buffer.concat(chunks), size }));
    req.on("error", () => resolve({ bytes: Buffer.alloc(0), size: 0 }));
  });
}

/// The Content-Length a request names, or NaN when it names none, as a chunked upload doesn't.
const lengthOf = (req) => Number(req.headers["content-length"] ?? NaN);

const isObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

function cookiesOf(req) {
  const jar = {};
  for (const part of (req.headers.cookie ?? "").split(";")) {
    const index = part.indexOf("=");
    if (index > 0) jar[part.slice(0, index).trim()] = part.slice(index + 1).trim();
  }
  return jar;
}

const sessionToken = (req) => cookiesOf(req)[COOKIE];
const userOf = (req) => {
  const token = sessionToken(req);
  const userId = token ? store.sessions.get(token) : undefined;
  return userId ? store.users.get(userId) : undefined;
};
const sessionCookie = (token, maxAge = COOKIE_MAX_AGE) => `${COOKIE}=${token}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${maxAge}`;

/// The real server's rule for writes under /api: refused when `Origin` names another site, or `Sec-Fetch-Site` says the request came from one.
/// Over plain HTTP a request with neither header (curl, a URLSession) is let through.
function isCrossSite(req) {
  const own = `http://${req.headers.host}`;
  const origin = req.headers.origin;
  const site = req.headers["sec-fetch-site"];
  if (origin !== undefined && origin !== own) return true;
  return site !== undefined && site !== "same-origin";
}

const accountWire = () => ({
  name: store.account.name,
  tagline: store.account.tagline,
  logo: null,
  customDomain: null,
  joinLink: false,
  openSignUp: false,
  restrictRoomCreation: false,
  hideTranslationButtons: false,
  customStyles: "",
});

function startSession(user) {
  const token = randomBytes(32).toString("base64url");
  store.sessions.set(token, user.id);
  return sessionCookie(token);
}

function etagged(req, res, body) {
  const text = JSON.stringify(body);
  const etag = `"${createHash("sha1").update(text).digest("base64url")}"`;
  if (req.headers["if-none-match"] === etag) return reply(res, 304, null, { ETag: etag, "Cache-Control": "no-store" });
  res.writeHead(200, { ...jsonHeaders, ETag: etag });
  res.end(text);
}

const signedOut = (res) => fail(res, 401, "Not signed in");
for (const bot of Object.values(seededBots)) rooms.engineering.members.set(bot.id, { unread: false, involvement: "mentions" });
const bots = createBotApi({ store, files, avatarToken, readRaw });

const routes = [];
const route = (method, pattern, handler) => routes.push({ method, pattern: new RegExp(`^${pattern}$`), handler });

route("GET", "/api/account/bots", (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  if (user.role !== "administrator") return fail(res, 403, "Only administrators can do that");
  reply(res, 200, { bots: bots.listed() });
});

route("GET", "/api/bootstrap", (req, res) => {
  const user = userOf(req);
  const headers = user ? { "Set-Cookie": sessionCookie(sessionToken(req)) } : {};
  reply(
    res,
    200,
    {
      setup: "complete",
      setupAccess: null,
      setupPlaceholders: null,
      guestSignIn: GUEST_SIGN_IN,
      signInWithMemberful: false,
      turnstileSiteKey: null,
      passwordResetCodes: false,
      account: accountWire(),
      version: VERSION,
      vapidPublicKey: null,
      platform: "other",
      user: user ? store.me(user) : null,
    },
    headers,
  );
});

route("POST", "/api/session", async (req, res) => {
  const body = await readBody(req);
  if (isObject(body) && "name" in body) {
    if (!GUEST_SIGN_IN) return fail(res, 403, "Signing in with just a name is turned off");
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (Array.from(name).length < 1 || Array.from(name).length > 48) return fail(res, 422, "Name must be 1 to 48 characters");
    if (name.toLowerCase() === "ember") return fail(res, 422, "Ember is the AI assistant’s name. Choose another.");
    const guest = store.addUser({ id: randomBase36(16), name, role: "member", createdAt: Date.now() });
    for (const room of store.rooms.values()) {
      if (room.kind === "open") room.members.set(guest.id, { unread: false, involvement: "mentions" });
    }
    return reply(res, 201, { user: store.me(guest) }, { "Set-Cookie": startSession(guest) });
  }
  const email = isObject(body) ? body.emailAddress : undefined;
  const password = isObject(body) ? body.password : undefined;
  if (typeof email !== "string" || typeof password !== "string" || email.length > 254 || password === "") return fail(res, 401, SIGN_IN_REJECTED);
  const user = store.userByEmail(email);
  // Compared even when there's no such person, so the answer takes as long either way.
  const matches = passwordMatches(password);
  if (!user || !matches) return fail(res, 401, SIGN_IN_REJECTED);
  reply(res, 201, { user: store.me(user) }, { "Set-Cookie": startSession(user) });
});

route("DELETE", "/api/session", (req, res) => {
  const token = sessionToken(req);
  if (token) {
    store.sessions.delete(token);
    for (const socket of [...workspaceSockets, ...roomSockets]) if (socket.token === token) socket.conn.close(4003, "Revoked");
  }
  reply(res, 204, null, { "Set-Cookie": sessionCookie("", 0) });
});

route("GET", "/api/me", (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  reply(res, 200, { user: store.me(user) }, { "Set-Cookie": sessionCookie(sessionToken(req)) });
});

route("GET", "/api/sidebar", (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  etagged(req, res, store.sidebar(user.id));
});

route("DELETE", "/api/sidebar/invitation", (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  store.invitations.set(user.id, true);
  store.hub.workspace(user.id, { type: "invitation.dismissed" });
  reply(res, 204, null);
});

route("GET", "/api/users", (req, res) => {
  if (!userOf(req)) return signedOut(res);
  const users = [...store.users.values()].sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
  etagged(req, res, { users: users.map((user) => store.directoryUser(user, avatarToken)) });
});

route("POST", "/api/directs", async (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  const body = await readBody(req);
  if (!isObject(body)) return fail(res, 422, "Expected a JSON object");
  const named = body.userIds === undefined ? [] : body.userIds;
  if (!Array.isArray(named) || named.length > MAX_LISTED_USERS || !named.every(isId)) return fail(res, 422, `People must be a list of at most ${MAX_LISTED_USERS} user ids`);
  // Like the real server, keep the people who exist whatever their role, and ignore the rest.
  const { room, started } = store.startDirect(user.id, named.filter((id) => store.users.has(id)));
  reply(res, started ? 201 : 200, { room: store.roomWire(room) });
});

route("PUT", "/api/rooms/([^/]+)/favorite", async (req, res, [roomId]) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  if (!ROOM_ID.test(roomId)) return fail(res, 400, "invalid room ID");
  const body = await readBody(req);
  if (!isObject(body) || typeof body.favorite !== "boolean") return fail(res, 400, "favorite must be true or false");
  const favorites = store.setFavourite(user.id, roomId, body.favorite);
  if (!favorites) return fail(res, 403, "You can't star that room");
  reply(res, 200, { favorites });
});

route("PUT", "/api/rooms/([^/]+)/involvement", async (req, res, [roomId]) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  if (!ROOM_ID.test(roomId) || !store.rooms.get(roomId)?.members.has(user.id)) return fail(res, 404, "Room not found or inaccessible");
  const body = await readBody(req);
  const level = isObject(body) ? body.involvement : undefined;
  if (!["mentions", "everything", "nothing", "invisible"].includes(level)) return fail(res, 422, "Notification level must be mentions, everything, nothing or invisible");
  reply(res, 200, { involvement: store.setInvolvement(user.id, roomId, level) });
});

function searchParamsOf(url) {
  const params = url.searchParams;
  const input = { q: params.get("q") ?? "" };
  if (params.get("in")) input.in = params.get("in");
  if (params.get("from")) input.from = params.get("from");
  if (params.get("with") === "me") input.withMe = true;
  if (params.getAll("has").includes("link")) input.hasLink = true;
  if (params.getAll("has").includes("file")) input.hasFile = true;
  if (params.get("is") === "thread") input.inThread = true;
  if (params.get("sort")) input.sort = params.get("sort");
  const cursor = Number(params.get("cursor"));
  return { input, cursor: params.has("cursor") && Number.isInteger(cursor) && cursor >= 0 ? cursor : null };
}

route("GET", "/api/searches", (req, res, _match, url) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  const { input, cursor } = searchParamsOf(url);
  const parsed = store.normaliseSearch(input);
  if (parsed.error) return fail(res, 422, parsed.error);
  reply(res, 200, store.search(user.id, parsed.search, parsed.sort, cursor));
});

route("POST", "/api/searches", async (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  const body = await readBody(req);
  if (!isObject(body)) return fail(res, 422, "Expected a JSON object");
  const parsed = store.normaliseSearch(body);
  if (parsed.error) return fail(res, 422, parsed.error);
  store.record(user.id, parsed.search);
  reply(res, 200, store.search(user.id, parsed.search, parsed.sort, null));
});

route("DELETE", "/api/searches", (req, res) => {
  const user = userOf(req);
  if (!user) return signedOut(res);
  store.clearSearches(user.id);
  reply(res, 204, null);
});

// Uploads

const MAX_JSON_BODY = 1024 * 1024;

/// The room for an upload request, or null once the response says why not.
function uploadRoom(req, res, roomId) {
  const user = userOf(req);
  if (!user) {
    signedOut(res);
    return null;
  }
  const room = ROOM_ID.test(roomId) ? store.rooms.get(roomId) : undefined;
  if (!room?.members.has(user.id)) {
    fail(res, 404, "Room not found or inaccessible");
    return null;
  }
  return { user, room };
}

/// Posts a finished upload as a message and answers it: 201 with the message, or the 422 the thread's loss gives.
function postUpload(res, { user, room }, upload) {
  const attachment = files.finish(upload);
  const result = store.createMessage(room, user.id, {
    clientMessageId: upload.clientMessageId,
    parentId: upload.parentId,
    alsoSend: upload.alsoSend,
    attachment,
  });
  if (result.error) {
    files.objects.delete(upload.id);
    return fail(res, 422, result.error.message);
  }
  upload.messageId = result.message.id;
  upload.completed = true;
  // The kept file holds the bytes now; the parts would hold them a second time.
  upload.received.clear();
  reply(res, 201, store.wire(room, result.message));
}

route("POST", "/api/rooms/([^/]+)/uploads", async (req, res, [roomId]) => {
  const found = uploadRoom(req, res, roomId);
  if (!found) return;
  const { bytes, size } = await readRaw(req, MAX_JSON_BODY);
  if (size > MAX_JSON_BODY) return fail(res, 413, "A request's body can be at most 1 MiB");
  let input = null;
  try {
    input = JSON.parse(bytes.toString("utf8"));
  } catch {
    input = null;
  }
  const started = files.start(found.room.id, found.user.id, input);
  if (started.error) return fail(res, started.status, started.error);
  const { upload } = started;
  if (upload.parentId !== undefined) {
    const parent = found.room.messages.find((message) => message.id === upload.parentId);
    if (!parent || parent.parentId) {
      files.uploads.delete(upload.id);
      return fail(res, 422, "That message no longer exists");
    }
  }
  reply(res, 201, { id: upload.id, partSize: PART_SIZE, parts: upload.parts });
});

route("PUT", "/api/rooms/([^/]+)/uploads/([^/]+)/parts/([1-9][0-9]*)", async (req, res, [roomId, uploadId, number]) => {
  const found = uploadRoom(req, res, roomId);
  if (!found) return;
  const n = Number(number);
  const upload = files.find(found.room.id, found.user.id, uploadId);
  if (!upload || n > upload.parts) return fail(res, 404, "Upload not found");
  if (upload.completed) return postedAlready(res, found.room, upload);
  const length = lengthOf(req);
  if (!Number.isSafeInteger(length)) return fail(res, 411, "A part needs its Content-Length");
  const expected = files.expectedLength(upload, n);
  if (length !== expected) {
    await readRaw(req, 0);
    return fail(res, length < expected ? 400 : 413, `Part ${n} is ${expected} bytes`);
  }
  if (n > 1 && !upload.received.has(1)) {
    await readRaw(req, 0);
    return fail(res, 409, "The first part goes first");
  }
  const { bytes } = await readRaw(req, expected);
  if (bytes.length !== expected) return fail(res, 400, `Part ${n} is ${expected} bytes`);
  // Again now the part has arrived, as the real server does: its sender may have signed out meanwhile, and the
  // upload may have gone or been posted by another request.
  const arrived = uploadRoom(req, res, roomId);
  if (!arrived) return;
  if (!files.find(arrived.room.id, arrived.user.id, uploadId)) return fail(res, 404, "Upload not found");
  if (upload.completed) return postedAlready(res, arrived.room, upload);
  upload.received.set(n, bytes);
  if (upload.received.size < upload.parts) return reply(res, 204, null);
  postUpload(res, found, upload);
});

function postedAlready(res, room, upload) {
  const message = room.messages.find((candidate) => candidate.id === upload.messageId);
  if (!message) return fail(res, 404, "Upload not found");
  reply(res, 200, store.wire(room, message));
}

route("PUT", "/api/rooms/([^/]+)/uploads/([^/]+)/preview", async (req, res, [roomId, uploadId]) => {
  const found = uploadRoom(req, res, roomId);
  if (!found) return;
  const upload = files.find(found.room.id, found.user.id, uploadId);
  if (!upload) return fail(res, 404, "Upload not found");
  if (upload.completed) return fail(res, 409, "The file is posted already");
  const length = lengthOf(req);
  if (!Number.isSafeInteger(length)) return fail(res, 411, "A preview needs its Content-Length");
  if (length > MAX_PREVIEW_BYTES) {
    await readRaw(req, 0);
    return fail(res, 413, "A preview is at most 5 MiB");
  }
  const { bytes } = await readRaw(req, MAX_PREVIEW_BYTES);
  const checked = files.checkPreview(bytes);
  if (checked.error) return fail(res, checked.status, checked.error);
  // Again now the preview has arrived, as for a part.
  const arrived = uploadRoom(req, res, roomId);
  if (!arrived) return;
  if (!files.find(arrived.room.id, arrived.user.id, uploadId)) return fail(res, 404, "Upload not found");
  if (upload.completed) return fail(res, 409, "The file is posted already");
  upload.preview = checked.preview;
  reply(res, 204, null);
});

// The upgrade is what serves these; a plain request for them is not found, as on the real server.
route("GET", "/api/socket", (req, res) => fail(res, 404, "Not found"));
route("GET", "/api/rooms/([^/]+)/socket", (req, res, [roomId]) => fail(res, 404, ROOM_ID.test(roomId) ? "Not found" : "Room not found or inaccessible"));

const initialsOf = (name) => {
  const words = name.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "?";
  const first = Array.from(words[0])[0];
  const last = words.length > 1 ? Array.from(words[words.length - 1])[0] : "";
  return (first + last).toUpperCase();
};

function serveAvatar(res, token) {
  const userId = avatarTokenUser(token);
  const user = userId ? store.users.get(userId) : undefined;
  if (!user) return fail(res, 404, "Not found");
  const hue = parseInt(createHash("sha1").update(user.id).digest("hex").slice(0, 4), 16) % 360;
  const initials = initialsOf(user.name).replace(/[<>&]/g, "");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" fill="hsl(${hue} 55% 45%)"/><text x="64" y="64" fill="#fff" font-family="sans-serif" font-size="52" text-anchor="middle" dominant-baseline="central">${initials}</text></svg>`;
  res.writeHead(200, { "Content-Type": "image/svg+xml", "Cache-Control": "public, max-age=1800" });
  res.end(svg);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const method = req.method ?? "GET";
    const avatar = /^\/users\/([^/]+)\/avatar$/.exec(url.pathname);
    if (avatar && (method === "GET" || method === "HEAD")) return serveAvatar(res, decodeURIComponent(avatar[1]));
    const media = /^\/card-media\/([a-z0-9-]+)\.png$/.exec(url.pathname);
    if (media && (method === "GET" || method === "HEAD")) {
      const png = cardPicture(media[1]);
      if (!png) return fail(res, 404, "Not found");
      res.writeHead(200, { "Content-Type": "image/png", "Content-Length": png.length, "Cache-Control": "public, max-age=3600" });
      return res.end(method === "HEAD" ? undefined : png);
    }
    if (await bots.handle(req, res, url)) return;
    const file = /^\/(files|previews)\/([^/]+)\/([^/]+)\/./.exec(url.pathname);
    if (file) return files.serve(req, res, file[1], file[2], file[3], url);
    for (const { method: wanted, pattern, handler } of routes) {
      const match = pattern.exec(url.pathname);
      if (!match || (wanted !== method && !(method === "HEAD" && wanted === "GET"))) continue;
      if (method !== "GET" && method !== "HEAD" && isCrossSite(req)) return fail(res, 422, "Requests from other sites are refused");
      return await handler(req, res, match.slice(1).map(decodeURIComponent), url);
    }
    fail(res, 404, "Not found");
  } catch (error) {
    console.error(error);
    if (!res.headersSent) fail(res, 500, "Something went wrong");
    else res.end();
  }
});

// Sockets

server.on("upgrade", (req, socket) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const roomMatch = /^\/api\/rooms\/([^/]+)\/socket$/.exec(url.pathname);
  if (url.pathname !== "/api/socket" && !roomMatch) return refuseUpgrade(socket, 404, "Not Found", { error: "Not found" });
  const roomId = roomMatch ? decodeURIComponent(roomMatch[1]) : null;
  if (roomMatch && !ROOM_ID.test(roomId)) return refuseUpgrade(socket, 404, "Not Found", { error: "Room not found or inaccessible" });
  const own = `http://${req.headers.host}`;
  if (req.headers.upgrade?.toLowerCase() !== "websocket" || req.headers.origin !== own) return refuseUpgrade(socket, 404, "Not Found", { error: "Not found" });
  const user = userOf(req);
  if (!user) return refuseUpgrade(socket, 401, "Unauthorized", { error: "Sign in first" });
  const conn = acceptWebSocket(req, socket);
  if (!conn) return;
  const token = sessionToken(req);
  if (roomId === null) return workspaceSocket(conn, user, token);
  const room = store.rooms.get(roomId);
  if (!room || !room.members.has(user.id)) return conn.close(4004, "NotFound");
  roomSocket(conn, user, token, room, url.searchParams);
});

function workspaceSocket(conn, user, token) {
  const socket = { conn, userId: user.id, token };
  workspaceSockets.add(socket);
  conn.onClose = () => workspaceSockets.delete(socket);
  conn.onText = (text) => {
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      frame = null;
    }
    if (frame?.type === "ping") send(conn, { type: "pong" });
    else send(conn, { type: "error", message: "Unrecognized frame" });
  };
  send(conn, { type: "welcome", you: store.me(user), account: accountWire() });
}

const unrecognised = (conn) => send(conn, { type: "error", message: "Unrecognized frame" });
const isId = (value) => typeof value === "string" && value.length > 0 && value.length <= 64;
/// The real parser's page size: a number, floored and held to 1..100, or else the default.
const limitOf = (value) => (typeof value === "number" ? Math.min(Math.max(1, Math.floor(value)), 100) : HISTORY_PAGE_SIZE);

function roomSocket(conn, user, token, room, params) {
  // `thread` is the one thread this socket has open. Opening another replaces it, and closing clears it only for the same parent.
  const socket = { conn, userId: user.id, token, roomId: room.id, visible: params.get("visible") !== "0", thread: null };
  const hadOtherSocket = [...roomSockets].some((other) => other.roomId === room.id && other.userId === user.id);
  roomSockets.add(socket);
  const you = store.ref(user.id);
  const present = () => store.hub.present(room.id).map(store.ref);
  const since = params.has("since") ? Number(params.get("since")) : null;
  const resumed = since === null ? null : store.resumedSince(room, since);
  if (resumed) send(conn, { type: "resumed", you, ...resumed, present: present(), seq: room.seq });
  else {
    const page = params.get("around") ? store.aroundPage(room, params.get("around")) : store.newestPage(room);
    send(conn, { type: "welcome", you, present: present(), seq: room.seq, ...page });
  }
  // A missing or unreadable protocol counts as 1, as on the real server.
  const outdated = (Number(params.get("protocol")) || 1) < ROOM_PROTOCOL;
  if (outdated) send(conn, { type: "error", message: OUTDATED });
  if (!hadOtherSocket) store.hub.room(room.id, { type: "presence.joined", user: you }, { exceptUser: user.id });
  if (socket.visible) store.markRead(room, user.id);

  conn.onClose = () => {
    roomSockets.delete(socket);
    const stillHere = [...roomSockets].some((other) => other.roomId === room.id && other.userId === user.id);
    const typing = typingIn.get(room.id);
    if (!stillHere) {
      typing?.delete(user.id);
      store.hub.room(room.id, { type: "presence.left", userId: user.id });
    } else if (typing?.has(user.id)) store.hub.typing(room.id, user.id, false);
  };

  conn.onText = (text) => {
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      return unrecognised(conn);
    }
    if (!isObject(frame) || typeof frame.type !== "string") return unrecognised(conn);
    const refused = (result) => {
      if (!result?.error) return false;
      send(conn, result.error);
      return true;
    };
    switch (frame.type) {
      case "ping":
        return send(conn, { type: "pong" });
      case "message.create": {
        if (!isId(frame.clientMessageId) || typeof frame.body !== "string") return unrecognised(conn);
        if (frame.parentId !== undefined && !isId(frame.parentId)) return unrecognised(conn);
        if (outdated) return send(conn, { type: "error", message: OUTDATED, clientMessageId: frame.clientMessageId, failed: "message.create" });
        const result = store.createMessage(room, user.id, frame);
        if (refused(result)) return;
        if (REPLIER && !result.message.parentId) {
          cardBots(room, result.message);
          scriptedReply(room, result.message);
        }
        return;
      }
      case "message.update":
        if (!isId(frame.messageId) || typeof frame.body !== "string") return unrecognised(conn);
        if (outdated) {
          const target = room.messages.find((message) => message.id === frame.messageId && !message.deleted);
          if (target && (target.creatorId === user.id || user.role === "administrator")) return send(conn, { type: "error", message: OUTDATED, failed: "message.update" });
        }
        return refused(store.updateMessage(room, user.id, frame));
      case "message.delete":
        if (!isId(frame.messageId)) return unrecognised(conn);
        return refused(store.deleteMessage(room, user.id, frame.messageId));
      case "boost.create":
        if (!isId(frame.messageId) || typeof frame.content !== "string") return unrecognised(conn);
        // The real parser trims the content and drops the frame when it is blank or past 16 UTF-16 units.
        {
          const content = frame.content.trim();
          if (content.length === 0 || content.length > MAX_BOOST_LENGTH) return unrecognised(conn);
          return refused(store.createBoost(room, user.id, { ...frame, content }));
        }
      case "boost.delete":
        if (!isId(frame.boostId)) return unrecognised(conn);
        return refused(store.deleteBoost(room, user.id, frame.boostId));
      case "typing.start":
        return store.hub.typing(room.id, user.id, true);
      case "typing.stop":
        return store.hub.typing(room.id, user.id, false);
      case "history.before":
        if (!isId(frame.before)) return unrecognised(conn);
        return send(conn, store.before(room, frame.before, limitOf(frame.limit)));
      case "history.after":
        if (!isId(frame.after)) return unrecognised(conn);
        return send(conn, store.after(room, frame.after, limitOf(frame.limit)));
      case "history.around":
        return send(conn, { type: "history.around", ...(isId(frame.messageId) ? store.aroundPage(room, frame.messageId) : store.newestPage(room)) });
      case "message.check": {
        if (!Array.isArray(frame.clientMessageIds) || frame.clientMessageIds.length === 0 || frame.clientMessageIds.length > 50 || !frame.clientMessageIds.every(isId)) return unrecognised(conn);
        const mine = new Set(room.messages.filter((message) => message.creatorId === user.id).map((message) => message.clientMessageId));
        return send(conn, {
          type: "message.checked",
          stored: frame.clientMessageIds.filter((id) => mine.has(id)),
          missing: frame.clientMessageIds.filter((id) => !mine.has(id)),
        });
      }
      case "thread.open":
        if (!isId(frame.parentId)) return unrecognised(conn);
        socket.thread = frame.parentId;
        return send(conn, store.threadOpened(room, frame.parentId));
      case "thread.close":
        if (!isId(frame.parentId)) return unrecognised(conn);
        if (socket.thread === frame.parentId) socket.thread = null;
        return;
      case "thread.before":
        if (!isId(frame.parentId) || !isId(frame.before)) return unrecognised(conn);
        return send(conn, store.threadBefore(room, frame.parentId, frame.before, limitOf(frame.limit)));
      case "presence.visible":
        if (typeof frame.visible !== "boolean") return unrecognised(conn);
        socket.visible = frame.visible;
        if (socket.visible) store.markRead(room, user.id);
        return;
      default:
        return unrecognised(conn);
    }
  };
}

// The scripted other person: a message in the random room, or in the DM between Sam and Maya, is answered by
// someone else after a moment, once, so a client has typing and an arriving message to show without a second person.

const CANNED = [
  "Ha, good point.",
  "Let me think about that and get back to you.",
  "Sounds good to me.",
  "I was just about to say the same thing.",
  "Can you say a little more?",
  "Thanks for the update.",
];
let cannedIndex = 0;

function scriptedReply(room, message) {
  let replier;
  if (room.id === rooms.random.id) replier = people.jordan;
  else if (room.id === rooms.samAndMaya.id) replier = [...room.members.keys()].map((id) => store.users.get(id)).find((member) => member.id !== message.creatorId);
  if (!replier || replier.id === message.creatorId || store.users.get(message.creatorId)?.role === "bot") return;
  const line = CANNED[cannedIndex++ % CANNED.length];
  setTimeout(() => store.hub.typing(room.id, replier.id, true), 700);
  setTimeout(() => {
    store.createMessage(room, replier.id, { clientMessageId: sortableId(), body: `<p>${line}</p>` });
    store.hub.typing(room.id, replier.id, false);
  }, 2700);
}

// The scripted bots: in Engineering, a person's top-level message that says "deploy" brings a deploy card from Deploy Bot,
// and one that says "alert" brings Uptime's alert, which Uptime replaces a few seconds later with its text alone (no cards).

function cardBots(room, message) {
  if (room.id !== rooms.engineering.id || store.users.get(message.creatorId)?.role === "bot") return;
  const bots = { deploy: seededBots.deployBot, uptime: seededBots.uptime };
  if (/deploy/i.test(message.plainText)) {
    setTimeout(() => {
      const kept = keptCards(deployCards("v2.4.3"));
      store.createMessage(room, bots.deploy.id, { clientMessageId: sortableId(), body: "" }, Date.now(), { cards: kept.cards, cardsText: kept.plainText });
    }, BOT_DELAY);
  }
  if (/alert/i.test(message.plainText)) {
    setTimeout(() => {
      const kept = keptCards(alertCards());
      const result = store.createMessage(room, bots.uptime.id, { clientMessageId: sortableId(), body: "<p>Message API errors are up</p>" }, Date.now(), { cards: kept.cards, cardsText: kept.plainText });
      if (!result.message) return;
      setTimeout(() => store.replaceBotMessage(room, bots.uptime.id, result.message.id, "<p>Message API errors are back to normal</p>"), BOT_REPLACE_DELAY);
    }, BOT_DELAY);
  }
}

function alertCards() {
  const alertLink = "https://status.fernwood.example/alerts/high-error-rate";
  return [
    {
      source: "attachment",
      color: "danger",
      parts: [
        { kind: "title", text: "[FIRING] HighErrorRate message-api", href: alertLink },
        { kind: "text", html: "<p>5xx rate is <strong>4.2%</strong> over the last 5 minutes (threshold 1%).</p>" },
        { kind: "fields", fields: [{ title: "Severity", html: "<p>critical</p>", short: true }, { title: "Region", html: "<p>fra1</p>", short: true }] },
        { kind: "buttons", buttons: [{ text: "Runbook", href: "https://runbooks.fernwood.example/high-error-rate", style: "danger" }] },
        { kind: "footer", text: "Uptime", at: Math.floor(Date.now() / 1000) },
      ],
    },
  ];
}

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") console.error(`Port ${PORT} on ${HOST} is already in use. Set PORT to another.`);
  else console.error(error);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  const admin = PEOPLE[0];
  console.log(`Stand-in Ember listening on http://${HOST}:${PORT}`);
  console.log(`Sign in as ${admin.email} (administrator), or any other seeded person, with the shared password.`);
  console.log(`Guest sign-in is ${GUEST_SIGN_IN ? "on" : "off"}; the scripted replier is ${REPLIER ? "on" : "off"}.`);
  console.log(`Card images are addressed at ${MEDIA_ORIGIN}/card-media/<name>.png`);
});
