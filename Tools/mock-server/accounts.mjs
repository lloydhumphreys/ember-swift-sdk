// The routes that make and change rooms, order the sidebar, show and change people, get someone back in
// (transfers and password resets), invite people by email and preview links. They sit apart from server.mjs,
// which hands in what they share. The real server's rules are the source; README.md lists where this differs.

import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { sortableId } from "./store.mjs";

const MAX_ROOM_NAME_LENGTH = 100;
const MAX_FAVORITES = 4096;
const MAX_SHARED_ORDER = 4096;
const MAX_BIO_LENGTH = 200;
const MAX_USER_NAME_LENGTH = 100;
const MAX_EMAIL_ADDRESS_LENGTH = 254;
const MAX_AVATAR_SIZE = 16_000_000;
const MAX_PICTURE_REQUEST = MAX_AVATAR_SIZE + 2 * 1024 * 1024;
const AVATAR_BOX = 512;
const INVITATIONS_AT_ONCE = 20;
const INVITATION_DAYS = 7;
const DAY = 24 * 60 * 60 * 1000;
const TRANSFER_LINK_EXPIRY_MS = 4 * 60 * 60 * 1000;
const RESET_CODE_DIGITS = 8;
const RESET_CODE_MS = 15 * 60 * 1000;
const RESET_CODE_TRIES = 5;
const UNFURLS = 30;
const UNFURL_WINDOW_MS = 60 * 1000;
const RECONNECT = 4001;
const REVOKED = 4003;

const AVATAR_TOO_LARGE = "Photos must be 16 MB or smaller.";
const NAME_TOO_LONG = `Name must be at most ${MAX_USER_NAME_LENGTH} characters`;
const NAME_RESERVED = "Ember is the AI assistant's name. Choose another.";
const EMAIL_ADDRESS_TOO_LONG = `Email address must be at most ${MAX_EMAIL_ADDRESS_LENGTH} characters`;
const PASSWORD_TOO_SHORT = "Password must be at least 8 characters.";
const PASSWORD_TOO_LONG = "Password must be at most 72 characters.";
const CURRENT_PASSWORD_NEEDED = "Enter your current password to change your email address or password.";
const CURRENT_PASSWORD_WRONG = "That isn't your current password.";
const EMAIL_ADDRESS_NEEDED = "Enter your email address, such as ann@example.com";
const NOT_AN_EMAIL_ADDRESS = "Each must be an email address, such as ann@example.com";
const NO_EMAIL_ADDRESSES = "Give an email address to invite";
const RESET_CODE_NEEDED = "Enter the 8-digit code from the email.";
const RESET_CODE_WRONG = "That code is wrong or no longer works. Check the newest email from Ember, or send another code.";
const EMAIL_LINK_GONE = "This link has expired, been used, or been replaced by a newer one.";
const SHARED_ORDER_FORBIDDEN = "Only administrators can put rooms in order for everyone, and only the rooms in their sidebar";

const ROOM_ICON = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const sha256 = (text) => createHash("sha256").update(text).digest();
const hex = (text) => createHash("sha256").update(text).digest("hex");
const text = (value) => (typeof value === "string" ? value.trim() : "");
const lengthOf = (value) => Array.from(value).length;
const isAdministrator = (user) => user.role === "administrator";

/// Ember as a name: the AI assistant's, which nobody else may take. As the real server reads it: NFKC, no format characters, no leading @, any case.
const isReservedName = (name) =>
  name
    .normalize("NFKC")
    .replace(/\p{Cf}/gu, "")
    .replace(/^[@\s]+/, "")
    .trim()
    .toLowerCase() === "ember";

// Pictures

const startsWith = (bytes, signature, at = 0) => signature.every((byte, index) => bytes[at + index] === byte);

/// "image/png", "image/jpeg", "image/webp" or "image/gif" by the first bytes, else null.
function magicType(bytes) {
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)) return "image/webp";
  if (startsWith(bytes, [0x47, 0x49, 0x46, 0x38])) return "image/gif";
  return null;
}

/// The width and height a PNG, JPEG or WebP says it has, or null when it doesn't say.
function imageSize(bytes, type) {
  try {
    if (type === "image/png") return bytes.length >= 24 ? { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) } : null;
    if (type === "image/jpeg") {
      let at = 2;
      while (at + 9 < bytes.length) {
        if (bytes[at] !== 0xff) return null;
        const marker = bytes[at + 1];
        if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { height: bytes.readUInt16BE(at + 5), width: bytes.readUInt16BE(at + 7) };
        at += 2 + bytes.readUInt16BE(at + 2);
      }
      return null;
    }
    if (type === "image/webp") {
      const kind = bytes.toString("latin1", 12, 16);
      if (kind === "VP8X") return { width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3) };
      if (kind === "VP8L") {
        const bits = bytes.readUInt32LE(21);
        return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >> 14) & 0x3fff) };
      }
      if (kind === "VP8 ") return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
    }
  } catch {
    return null;
  }
  return null;
}

/// The parts of a multipart/form-data body: { name, filename, type, bytes } each, or null when it is no form.
function parseForm(contentType, body) {
  const boundary = /boundary=(?:"([^"]+)"|([^;\s]+))/i.exec(contentType ?? "");
  if (!/^multipart\/form-data/i.test(contentType ?? "") || !boundary) return null;
  const delimiter = Buffer.from(`--${boundary[1] ?? boundary[2]}`);
  const parts = [];
  let at = body.indexOf(delimiter);
  if (at < 0) return null;
  for (;;) {
    at += delimiter.length;
    if (body.subarray(at, at + 2).toString() === "--") return parts;
    if (body.subarray(at, at + 2).toString() !== "\r\n") return null;
    at += 2;
    const headerEnd = body.indexOf("\r\n\r\n", at);
    if (headerEnd < 0) return null;
    const headers = body.subarray(at, headerEnd).toString("utf8");
    const next = body.indexOf(Buffer.concat([Buffer.from("\r\n"), delimiter]), headerEnd + 4);
    if (next < 0) return null;
    const disposition = /^content-disposition:.*$/im.exec(headers)?.[0] ?? "";
    parts.push({
      name: /\bname="([^"]*)"/i.exec(disposition)?.[1] ?? "",
      filename: /\bfilename="([^"]*)"/i.exec(disposition)?.[1],
      type: /^content-type:\s*(.+)$/im.exec(headers)?.[1]?.trim() ?? "",
      bytes: body.subarray(headerEnd + 4, next),
    });
    at = next + 2;
  }
}

// Link previews: the mock never touches the network. These addresses get a canned preview; every other address has none.

const CANNED_PREVIEW_HOST = /^(?:[a-z0-9-]+\.)*example\.com$/i;

export function installAccountRoutes(ctx) {
  const { route, store, userOf, sessionToken, startSession, endSessions, reply, fail, readBody, readRaw, lengthOf: contentLength, isObject, isId, signedOut, avatarToken, passwordMatches, accountWire, ROOM_ID, MAX_LISTED_USERS } = ctx;
  const transferSecret = randomBytes(32);
  const resets = new Map();
  /// The newest link told for each invitation, by its address: what the real server would have emailed.
  const links = new Map();
  const unfurls = new Map();

  const empty = (res, status) => {
    res.writeHead(status, { "Cache-Control": "no-store" });
    res.end();
  };
  const originOf = (req) => (req ? `http://${req.headers.host}` : ctx.origin);
  const refreshed = (user) => {
    user.updatedAt = Math.max(Date.now(), (Math.floor(user.updatedAt / 1000) + 1) * 1000);
  };
  const userUpdated = (user) => store.hub.everyone({ type: "user.updated", user: store.directoryUser(user, avatarToken) });
  const tokenOfCookie = (cookie) => /session_token=([^;]+)/.exec(cookie)?.[1];

  // Transfers: a link that signs someone in as a person from a session that is still signed in.

  const sessionIdOf = (token) => hex(`session:${token}`).slice(0, 16);
  const transferSignature = (userId, sessionId, expiresAt) => createHmac("sha256", transferSecret).update(JSON.stringify(["transfer", userId, sessionId, expiresAt])).digest("base64url");
  const transferIdFor = (userId, token) => {
    const sessionId = sessionIdOf(token);
    const expiresAt = Date.now() + TRANSFER_LINK_EXPIRY_MS;
    return `${userId}.${sessionId}.${expiresAt.toString(36)}.${transferSignature(userId, sessionId, expiresAt)}`;
  };

  /// The person a transfer id is for, or null when it is bad, tampered with, expired, or its session has gone or may not show it.
  function transferTarget(id) {
    const parts = id.split(".");
    if (parts.length < 4) return null;
    const [sessionId, expiry, signature] = parts.slice(-3);
    const userId = parts.slice(0, -3).join(".");
    const expiresAt = parseInt(expiry, 36);
    if (!userId || !Number.isFinite(expiresAt) || expiresAt < Date.now()) return null;
    const expected = Buffer.from(transferSignature(userId, sessionId, expiresAt));
    const given = Buffer.from(signature);
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
    let showerId = null;
    for (const [token, owner] of store.sessions) if (sessionIdOf(token) === sessionId) showerId = owner;
    const shower = showerId ? store.users.get(showerId) : null;
    const person = store.users.get(userId);
    if (!shower || !person || shower.status !== "active" || person.status !== "active" || person.role === "bot") return null;
    return shower.id === person.id || isAdministrator(shower) ? person : null;
  }

  route("POST", "/api/session/transfers", async (req, res) => {
    const body = await readBody(req);
    if (!isObject(body) || typeof body.transferId !== "string") return empty(res, 400);
    const person = transferTarget(body.transferId);
    if (!person) return empty(res, 400);
    reply(res, 201, { user: store.me(person) }, { "Set-Cookie": startSession(person) });
  });

  // Rooms

  const roomChoice = (value) => value === undefined || value === "" || (typeof value === "string" && value.length <= 64 && ROOM_ICON.test(value));
  const ICON_MESSAGE = 'Icon must be one of the room icons, or "" for the default';
  const MEMBERS_MESSAGE = `Members must be a list of at most ${MAX_LISTED_USERS} user ids`;
  const membersOk = (list) => Array.isArray(list) && list.length <= MAX_LISTED_USERS && list.every(isId);

  function parseNewRoom(body) {
    if (!isObject(body)) return "Expected a JSON object";
    if (body.kind !== "open" && body.kind !== "closed") return 'Kind must be "open" or "closed"';
    const name = text(body.name);
    if (name === "" || lengthOf(name) > MAX_ROOM_NAME_LENGTH) return `Name must be 1 to ${MAX_ROOM_NAME_LENGTH} characters`;
    if (!roomChoice(body.icon)) return ICON_MESSAGE;
    const memberIds = body.kind === "closed" ? (body.memberIds === undefined ? [] : body.memberIds) : [];
    if (!membersOk(memberIds)) return MEMBERS_MESSAGE;
    return { kind: body.kind, name, icon: body.icon ?? "", memberIds };
  }

  function parseRoomChanges(body) {
    if (!isObject(body)) return "Expected a JSON object";
    const changes = {};
    if (body.name !== undefined) {
      const name = text(body.name);
      if (name === "" || lengthOf(name) > MAX_ROOM_NAME_LENGTH) return `Name must be 1 to ${MAX_ROOM_NAME_LENGTH} characters`;
      changes.name = name;
    }
    if (body.icon !== undefined) {
      if (!roomChoice(body.icon)) return ICON_MESSAGE;
      changes.icon = body.icon;
    }
    if (body.kind !== undefined) {
      if (body.kind === "closed") {
        if (!membersOk(body.memberIds)) return MEMBERS_MESSAGE;
        changes.kind = "closed";
        changes.memberIds = body.memberIds;
      } else if (body.kind === "open") changes.kind = "open";
      else return 'Kind must be "open" or "closed"';
    }
    return changes;
  }

  const savedRoom = (room) => ({ id: room.id, kind: room.kind, name: room.name, icon: room.icon });
  /// A shared room the person is in, which they can read the settings of, or null.
  const settingsRoom = (user, roomId) => {
    const room = ROOM_ID.test(roomId) ? store.rooms.get(roomId) : undefined;
    return room && room.kind !== "direct" && room.members.has(user.id) ? room : null;
  };
  const mayAdminister = (user, room) => isAdministrator(user) || room.by === user.id;

  route("POST", "/api/rooms", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const parsed = parseNewRoom(await readBody(req));
    if (typeof parsed === "string") return fail(res, 422, parsed);
    reply(res, 201, { room: savedRoom(store.createRoom(user.id, parsed)) });
  });

  route("GET", "/api/rooms/new", (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    reply(res, 200, { people: store.activePeople().map(({ id, name }) => ({ id, name })) });
  });

  route("GET", "/api/rooms/([^/]+)/settings", (req, res, [roomId]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const room = settingsRoom(user, roomId);
    if (!room) return fail(res, 404, "Room not found or inaccessible");
    reply(res, 200, {
      room: savedRoom(room),
      canAdminister: mayAdminister(user, room),
      people: store.activePeople().map(({ id, name }) => ({ id, name, member: room.members.has(id) })),
    });
  });

  route("PATCH", "/api/rooms/([^/]+)", async (req, res, [roomId]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const room = settingsRoom(user, roomId);
    if (!room) return fail(res, 404, "Room not found or inaccessible");
    if (!mayAdminister(user, room)) return fail(res, 403, "Only administrators and the room's creator can change it");
    const changes = parseRoomChanges(await readBody(req));
    if (typeof changes === "string") return fail(res, 422, changes);
    if (changes.name !== undefined || changes.kind !== undefined || changes.icon !== undefined) store.changeRoom(room, changes);
    reply(res, 200, { room: savedRoom(room) });
  });

  route("DELETE", "/api/rooms/([^/]+)", (req, res, [roomId]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const room = ROOM_ID.test(roomId) ? store.rooms.get(roomId) : undefined;
    if (!room || !room.members.has(user.id)) return fail(res, 404, "Room not found or inaccessible");
    if (room.kind !== "direct" && !mayAdminister(user, room)) return fail(res, 403, "Only administrators and the room's creator can delete it");
    store.deleteRoom(room);
    reply(res, 204, null);
  });

  // Sidebar order

  /// The ids of a room order body, or the 400 message that refuses it.
  function parseRoomOrder(body, limit) {
    const ids = isObject(body) ? body.roomIds : undefined;
    if (!Array.isArray(ids)) return "roomIds must be an array";
    if (ids.length > limit) return "too many rooms";
    if (!ids.every((id) => typeof id === "string" && ROOM_ID.test(id)) || new Set(ids).size !== ids.length) return "room IDs must be unique and valid";
    return ids;
  }

  route("PUT", "/api/sidebar/order", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const ids = parseRoomOrder(await readBody(req), MAX_FAVORITES);
    if (typeof ids === "string") return fail(res, 400, ids);
    const favourites = store.favouritesOf(user.id);
    if (ids.length !== favourites.rooms.length || !ids.every((id) => favourites.rooms.includes(id))) return fail(res, 403, "Those aren't the rooms you've starred");
    favourites.rooms = [...ids];
    favourites.version += 1;
    const result = { rooms: [...favourites.rooms], version: favourites.version };
    store.hub.workspace(user.id, { type: "favorites.changed", favorites: result });
    reply(res, 200, { favorites: result });
  });

  route("PUT", "/api/account/room_order", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    if (!isAdministrator(user)) return fail(res, 403, SHARED_ORDER_FORBIDDEN);
    const ids = parseRoomOrder(await readBody(req), MAX_SHARED_ORDER);
    if (typeof ids === "string") return fail(res, 400, ids);
    const visible = new Set(store.roomsOf(user.id).filter((room) => room.kind !== "direct").map((room) => room.id));
    if (!ids.every((id) => visible.has(id))) return fail(res, 403, SHARED_ORDER_FORBIDDEN);
    // The mock keeps one list for everyone, so the ranks of rooms the administrator can't see stay as they were.
    const unseen = store.sharedOrder.filter((id) => !visible.has(id) && store.rooms.has(id));
    store.sharedOrder = ids.length === 0 ? unseen : [...ids, ...unseen];
    store.hub.everyone({ type: "rooms.reordered" });
    reply(res, 200, { sharedOrder: [...ids] });
  });

  // Profile

  const profileOf = (user, token) => ({
    profile: {
      name: user.name,
      emailAddress: user.email,
      bio: user.bio,
      avatarUrl: store.directoryUser(user, avatarToken).avatarUrl,
      avatar: user.avatar !== null,
      password: user.email !== null,
      membershipNeeded: false,
      memberful: null,
      assistant: null,
    },
    transferId: transferIdFor(user.id, token),
  });

  route("GET", "/api/users/me/profile", (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    reply(res, 200, profileOf(user, sessionToken(req)));
  });

  const PROFILE_FIELDS = { name: "Name", emailAddress: "Email address", password: "Password", bio: "Bio", currentPassword: "Current password", pushSubscriptionEndpoint: "Push subscription endpoint" };

  function parseProfileChanges(body) {
    if (!isObject(body)) return "Expected a JSON object";
    const changes = {};
    for (const [field, label] of Object.entries(PROFILE_FIELDS)) {
      if (body[field] === undefined) continue;
      if (typeof body[field] !== "string") return `${label} must be text`;
      changes[field] = body[field];
    }
    if (changes.name !== undefined && changes.name.length > MAX_USER_NAME_LENGTH) return NAME_TOO_LONG;
    if (changes.emailAddress !== undefined && changes.emailAddress.length > MAX_EMAIL_ADDRESS_LENGTH) return EMAIL_ADDRESS_TOO_LONG;
    if (changes.password !== undefined && changes.password.length > 72) return PASSWORD_TOO_LONG;
    if (changes.password && changes.password.length < 8) return PASSWORD_TOO_SHORT;
    if (changes.bio !== undefined && changes.bio.length > MAX_BIO_LENGTH) return `Bio must be at most ${MAX_BIO_LENGTH} characters`;
    return changes;
  }

  route("PATCH", "/api/users/me/profile", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const token = sessionToken(req);
    const changes = parseProfileChanges(await readBody(req));
    if (typeof changes === "string") return fail(res, 422, changes);
    const typedEmail = changes.emailAddress === undefined ? undefined : changes.emailAddress.trim().toLowerCase() || null;
    const changesEmail = typedEmail !== undefined && typedEmail !== user.email;
    const newPassword = changes.password ? changes.password : null;
    if (user.email !== null && (changesEmail || newPassword !== null)) {
      if (!changes.currentPassword) return fail(res, 422, CURRENT_PASSWORD_NEEDED);
      if (changes.currentPassword.length > 72 || !passwordMatches(changes.currentPassword, user)) return fail(res, 422, CURRENT_PASSWORD_WRONG);
    }
    const renamed = changes.name !== undefined && changes.name !== user.name;
    const rebio = changes.bio !== undefined && (changes.bio === "" ? null : changes.bio) !== user.bio;
    if (renamed && isReservedName(changes.name) && !isReservedName(user.name)) return fail(res, 422, NAME_RESERVED);
    if (changesEmail && typedEmail !== null && [...store.users.values()].some((other) => other.id !== user.id && other.email === typedEmail)) return fail(res, 422, "That email address has an account already");
    if (!renamed && !rebio && !changesEmail && newPassword === null) return reply(res, 200, profileOf(user, token));
    if (renamed) user.name = changes.name;
    if (rebio) user.bio = changes.bio === "" ? null : changes.bio;
    if (changesEmail) user.email = typedEmail;
    user.updatedAt = Math.max(Date.now(), user.updatedAt + 1);
    if (renamed || rebio) userUpdated(user);
    if (newPassword !== null) {
      user.passwordDigest = sha256(newPassword);
      endSessions(user.id, RECONNECT, "Reconnect", token);
    }
    reply(res, 200, profileOf(user, token));
  });

  route("PUT", "/api/users/me/avatar", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const length = contentLength(req);
    if (!Number.isSafeInteger(length)) return fail(res, 411, "A picture needs its Content-Length");
    if (length > MAX_PICTURE_REQUEST) {
      await readRaw(req, 0);
      return fail(res, 413, AVATAR_TOO_LARGE);
    }
    const { bytes } = await readRaw(req, MAX_PICTURE_REQUEST);
    if (!userOf(req)) return signedOut(res);
    const parts = parseForm(req.headers["content-type"], bytes);
    if (!parts) return fail(res, 400, "Expected a form");
    const file = parts.find((part) => part.name === "avatar" && part.filename !== undefined);
    if (!file) return fail(res, 400, "Choose a picture");
    if (file.bytes.length > MAX_AVATAR_SIZE) return fail(res, 413, AVATAR_TOO_LARGE);
    const sentVariant = parts.find((part) => part.name === "variant");
    let variant = null;
    if (sentVariant) {
      if (sentVariant.filename === undefined) return fail(res, 400, "A variant is a picture");
      const type = magicType(sentVariant.bytes);
      const size = type && type !== "image/gif" ? imageSize(sentVariant.bytes, type) : null;
      if (!size) return fail(res, 415, "A variant is a WebP, PNG or JPEG image");
      if (size.width > AVATAR_BOX || size.height > AVATAR_BOX) return fail(res, 422, `A variant fits within ${AVATAR_BOX}×${AVATAR_BOX}`);
      variant = { type, bytes: sentVariant.bytes };
    }
    const own = magicType(file.bytes);
    // Served as the variant when there is one; else as the file itself when it is a picture; else as initials, as for a type the real server doesn't resize.
    user.avatar = variant && own ? variant : own ? { type: own, bytes: file.bytes } : { type: null, bytes: Buffer.alloc(0) };
    if (user.avatar.type === null) user.avatar.initials = true;
    refreshed(user);
    userUpdated(user);
    reply(res, 200, profileOf(user, sessionToken(req)));
  });

  route("DELETE", "/api/users/me/avatar", (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    if (user.avatar !== null) {
      user.avatar = null;
      refreshed(user);
      userUpdated(user);
    }
    reply(res, 200, profileOf(user, sessionToken(req)));
  });

  // People

  route("GET", "/api/users/([^/]+)", (req, res, [id]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const person = store.users.get(id);
    if (!person) return fail(res, 404, "Not found");
    const answer = { person: store.directoryUser(person, avatarToken) };
    if (isAdministrator(user)) {
      answer.person.emailAddress = person.email;
      if (person.status === "active" && person.role !== "bot") answer.transferId = transferIdFor(person.id, sessionToken(req));
    }
    reply(res, 200, answer);
  });

  route("POST", "/api/users/([^/]+)/ban", (req, res, [id]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    if (!isAdministrator(user)) return fail(res, 403, "Only administrators can ban people");
    const person = store.users.get(id);
    if (!person || person.id === "ember") return fail(res, 404, "Not found");
    if (person.id === user.id) return fail(res, 403, "Administrators can't ban themselves");
    if (person.status !== "banned") {
      person.status = "banned";
      person.updatedAt = Math.max(Date.now(), person.updatedAt + 1);
      endSessions(person.id, REVOKED, "Revoked");
      // Their messages go from every room, as a person deletes their own.
      for (const room of store.rooms.values()) {
        for (const message of room.messages.filter((candidate) => candidate.creatorId === person.id && !candidate.deleted)) store.deleteMessage(room, person.id, message.id);
      }
      userUpdated(person);
    }
    reply(res, 200, { user: store.directoryUser(person, avatarToken) });
  });

  route("DELETE", "/api/users/([^/]+)/ban", (req, res, [id]) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    if (!isAdministrator(user)) return fail(res, 403, "Only administrators can lift bans");
    const person = store.users.get(id);
    if (!person || person.id === "ember") return fail(res, 404, "Not found");
    if (person.status === "banned") {
      person.status = "active";
      person.updatedAt = Math.max(Date.now(), person.updatedAt + 1);
      userUpdated(person);
    }
    reply(res, 200, { user: store.directoryUser(person, avatarToken) });
  });

  // Password resets. The mock never sends email: the code is printed as a RESET CODE line.

  function parseCode(value) {
    const digits = value.normalize("NFKC").replace(/[\s-]/g, "");
    return new RegExp(`^[0-9]{${RESET_CODE_DIGITS}}$`).test(digits) ? digits : null;
  }

  route("POST", "/api/password_resets", async (req, res) => {
    const body = await readBody(req);
    if (!isObject(body)) return fail(res, 422, "Expected a JSON object", { field: "emailAddress" });
    const given = typeof body.emailAddress === "string" ? body.emailAddress.trim() : "";
    if (given === "") return fail(res, 422, EMAIL_ADDRESS_NEEDED, { field: "emailAddress" });
    if (given.length > MAX_EMAIL_ADDRESS_LENGTH) return fail(res, 422, EMAIL_ADDRESS_TOO_LONG, { field: "emailAddress" });
    const person = store.userByEmail(given);
    if (person && person.status === "active" && person.role !== "bot") {
      const code = String(randomInt(0, 10 ** RESET_CODE_DIGITS)).padStart(RESET_CODE_DIGITS, "0");
      resets.set(person.email, { code, expiresAt: Date.now() + RESET_CODE_MS, tries: 0 });
      console.log(`RESET CODE ${person.email} ${code}`);
    }
    reply(res, 202, {});
  });

  route("PUT", "/api/password_resets", async (req, res) => {
    const body = await readBody(req);
    if (!isObject(body)) return fail(res, 400, "Expected a JSON object");
    if (typeof body.emailAddress !== "string" || typeof body.code !== "string" || typeof body.password !== "string" || body.emailAddress.trim() === "" || body.code === "" || body.password === "") {
      return fail(res, 400, "Email address, code and password are required");
    }
    const given = body.emailAddress.trim();
    if (given.length > MAX_EMAIL_ADDRESS_LENGTH) return fail(res, 422, EMAIL_ADDRESS_TOO_LONG, { field: "emailAddress" });
    const code = parseCode(body.code);
    if (code === null) return fail(res, 422, RESET_CODE_NEEDED, { field: "code" });
    if (body.password.length > 72) return fail(res, 422, PASSWORD_TOO_LONG, { field: "password" });
    if (body.password.length < 8) return fail(res, 422, PASSWORD_TOO_SHORT, { field: "password" });
    const person = store.userByEmail(given);
    const entry = person ? resets.get(person.email) : undefined;
    const wrong = () => fail(res, 422, RESET_CODE_WRONG, { field: "code" });
    if (!person || !entry || entry.expiresAt < Date.now() || entry.tries >= RESET_CODE_TRIES || person.status !== "active") return wrong();
    entry.tries += 1;
    const expected = Buffer.from(entry.code);
    const sent = Buffer.from(code);
    if (sent.length !== expected.length || !timingSafeEqual(sent, expected)) return wrong();
    resets.delete(person.email);
    person.passwordDigest = sha256(body.password);
    endSessions(person.id, RECONNECT, "Reconnect");
    reply(res, 201, { user: store.me(person) }, { "Set-Cookie": startSession(person) });
  });

  // Invitations. Only a digest of each link's token is kept, so a link is told once, in the answer and as an INVITATION LINK line.

  const tokenDigest = (token) => hex(`invitation:${token}`);
  const invitationWire = (invitation) => ({
    id: invitation.id,
    emailAddress: invitation.emailAddress,
    invitedBy: invitation.invitedBy,
    createdAt: new Date(invitation.createdAt).toISOString(),
    expiresAt: new Date(invitation.expiresAt).toISOString(),
    delivery: null,
  });
  const linkFor = (origin, token) => `${origin}/join/invitation#token=${token}`;

  /// Gives an invitation a new link, which replaces the old, and prints it.
  function issue(invitation, token, origin, inviter) {
    invitation.digest = tokenDigest(token);
    invitation.invitedBy = inviter.name;
    invitation.createdAt = Date.now();
    invitation.expiresAt = invitation.createdAt + INVITATION_DAYS * DAY;
    const link = linkFor(origin, token);
    console.log(`INVITATION LINK ${invitation.emailAddress} ${link}`);
    links.set(invitation.emailAddress.toLowerCase(), link);
    return link;
  }

  /// The pending invitations the real seed would have no equivalent of: two, so the settings have something to list.
  const admin = [...store.users.values()].find(isAdministrator);
  if (admin) {
    for (const [address, daysAgo] of [["first.guest@example.com", 2], ["second.guest@example.com", 1]]) {
      const invitation = { id: sortableId(Date.now() - daysAgo * DAY), emailAddress: address, digest: "", invitedBy: "", createdAt: 0, expiresAt: 0 };
      const token = createHash("sha256").update(`seed-invitation:${address}`).digest("base64url");
      issue(invitation, token, ctx.origin, admin);
      invitation.createdAt = Date.now() - daysAgo * DAY;
      invitation.expiresAt = invitation.createdAt + INVITATION_DAYS * DAY;
      store.emailInvitations.unshift(invitation);
    }
  }

  const administratorOnly = (req, res) => {
    const user = userOf(req);
    if (!user) return void signedOut(res);
    if (!isAdministrator(user)) return void fail(res, 403, "Only administrators can invite people");
    return user;
  };

  route("POST", "/api/invitations", async (req, res) => {
    const user = administratorOnly(req, res);
    if (!user) return;
    const body = await readBody(req);
    if (!isObject(body)) return fail(res, 422, "Expected a JSON object");
    const list = body.emailAddresses;
    if (!Array.isArray(list) || list.length === 0) return fail(res, 422, NO_EMAIL_ADDRESSES);
    if (list.length > INVITATIONS_AT_ONCE) return fail(res, 422, `Invite at most ${INVITATIONS_AT_ONCE} email addresses at once`);
    const addresses = [];
    for (const item of list) {
      const address = typeof item === "string" ? item.trim() : "";
      if (!EMAIL.test(address) || address.length > MAX_EMAIL_ADDRESS_LENGTH) return fail(res, 422, NOT_AN_EMAIL_ADDRESS);
      if (!addresses.some((kept) => kept.toLowerCase() === address.toLowerCase())) addresses.push(address);
    }
    const outcomes = addresses.map((address) => {
      if (store.userByEmail(address)) return { emailAddress: address, member: true };
      let invitation = store.emailInvitations.find((candidate) => candidate.emailAddress.toLowerCase() === address.toLowerCase());
      if (invitation) store.emailInvitations = store.emailInvitations.filter((candidate) => candidate !== invitation);
      else invitation = { id: sortableId(), emailAddress: address, digest: "", invitedBy: "", createdAt: 0, expiresAt: 0 };
      const link = issue(invitation, randomBytes(32).toString("base64url"), originOf(req), user);
      store.emailInvitations.unshift(invitation);
      return { emailAddress: address, invitation: invitationWire(invitation), link };
    });
    reply(res, 200, { outcomes });
  });

  route("POST", "/api/invitations/([^/]+)/resend", (req, res, [id]) => {
    const user = administratorOnly(req, res);
    if (!user) return;
    const invitation = store.emailInvitations.find((candidate) => candidate.id === id);
    if (!invitation) return fail(res, 404, "Not found");
    const link = issue(invitation, randomBytes(32).toString("base64url"), originOf(req), user);
    reply(res, 200, { invitation: invitationWire(invitation), link });
  });

  route("DELETE", "/api/invitations/([^/]+)", (req, res, [id]) => {
    const user = administratorOnly(req, res);
    if (!user) return;
    if (!store.emailInvitations.some((candidate) => candidate.id === id)) return fail(res, 404, "Not found");
    store.emailInvitations = store.emailInvitations.filter((candidate) => candidate.id !== id);
    reply(res, 204, null);
  });

  route("POST", "/api/email_links/lookup", async (req, res) => {
    const body = await readBody(req);
    const digest = isObject(body) && typeof body.token === "string" ? tokenDigest(body.token) : null;
    const invitation = digest ? store.emailInvitations.find((candidate) => candidate.digest === digest && candidate.expiresAt > Date.now()) : null;
    if (!invitation) return fail(res, 404, EMAIL_LINK_GONE);
    reply(res, 200, { kind: "invitation", emailAddress: invitation.emailAddress });
  });

  route("GET", "/api/account", (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const administrator = isAdministrator(user);
    reply(res, 200, {
      account: accountWire(),
      joinCode: administrator ? store.joinCode : null,
      canAdminister: administrator,
      memberfulSite: null,
      memberfulWebhooks: false,
      turnstile: null,
      email: { provider: null, resendKey: null, cloudflare: false, from: null },
      invitations: administrator ? store.emailInvitations.map(invitationWire) : [],
      emailDomains: [],
      addresses: { deployed: null, others: [] },
      assistant: null,
      cloudflareAccountId: null,
    });
  });

  // What the mock would have emailed, for a test to read in place of an inbox. Not on the real server.
  route("GET", "/mock/outbox", (req, res) => {
    const now = Date.now();
    reply(res, 200, {
      resetCodes: [...resets].filter(([, entry]) => entry.expiresAt > now).map(([emailAddress, entry]) => ({ emailAddress, code: entry.code, expiresAt: new Date(entry.expiresAt).toISOString() })),
      invitationLinks: store.emailInvitations.map((invitation) => ({ emailAddress: invitation.emailAddress, link: links.get(invitation.emailAddress.toLowerCase()) ?? null })),
    });
  });

  // Link previews

  route("POST", "/api/unfurl", async (req, res) => {
    const user = userOf(req);
    if (!user) return signedOut(res);
    const now = Date.now();
    let window = unfurls.get(user.id);
    if (!window || now - window.start >= UNFURL_WINDOW_MS) unfurls.set(user.id, (window = { start: now, count: 0 }));
    window.count += 1;
    if (window.count > UNFURLS) return fail(res, 429, "Too many link previews. Try again in a minute.");
    const body = await readBody(req);
    const url = isObject(body) ? body.url : undefined;
    const blank = url === undefined || url === null || (typeof url === "string" && url.trim() === "") || (Array.isArray(url) && url.length === 0) || (isObject(url) && Object.keys(url).length === 0);
    if (blank) return fail(res, 400, "param is missing or the value is empty: url");
    if (typeof url !== "string") return reply(res, 204, null);
    let address;
    try {
      address = new URL(url);
    } catch {
      return reply(res, 204, null);
    }
    if (address.host === req.headers.host || !/^https?:$/.test(address.protocol) || !CANNED_PREVIEW_HOST.test(address.hostname)) return reply(res, 204, null);
    reply(res, 200, {
      title: "Example Domain",
      url: address.href,
      image: null,
      description: "This domain is for use in illustrative examples in documents.",
    });
  });
}
