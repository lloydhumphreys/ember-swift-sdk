// The stand-in server's state and rules, all in memory. Sockets and HTTP live in server.mjs, which plugs a
// `hub` in so this file can say who hears what without knowing how it's delivered.

import { createHash, randomBytes, randomUUID } from "node:crypto";

export const HISTORY_PAGE_SIZE = 40;
export const MAX_MESSAGE_LENGTH = 40_000;
export const MAX_MESSAGE_HTML_LENGTH = 100_000;
export const MAX_BOOST_LENGTH = 16;
export const MAX_SEARCH_LENGTH = 1000;
export const RECENT_SEARCHES = 10;
export const PARENT_TEXT_LENGTH = 150;
export const THREAD_FACES = 4;
/// How far behind a socket can be and still resume; further back it gets a welcome, as on the real server.
export const CHANGES_KEPT = 100;
export const ASSISTANT_ID = "ember";
/// The mentions that notify a room rather than a person, narrowest first.
export const SPECIAL_MENTIONS = ["here", "channel", "everyone"];
export const MAX_SECTIONS = 100;
export const MAX_SCHEDULED_MESSAGES = 30;
export const SCHEDULE_AHEAD_MS = 120 * 24 * 60 * 60_000;
/// How many due messages a room sends in one go.
export const SCHEDULED_SENT_AT_ONCE = 10;
export const MESSAGE_GONE = "That message no longer exists";
export const SCHEDULE_TIME_REFUSED = "Pick a time between now and 120 days from now.";
export const TOO_MANY_SCHEDULED = "You can have up to 30 messages scheduled here at once.";
export const SCHEDULED_GONE = "That message isn't scheduled any more.";
export const THREAD_DELETED = "Its thread's message has been deleted.";
export const SECTIONS_FORBIDDEN = "Only administrators can make, rename and delete sections";
export const TOO_MANY_SECTIONS = "There can be at most 100 sections";
const SEARCH_LIMIT = Number(process.env.EMBER_SEARCH_PAGE) > 0 ? Number(process.env.EMBER_SEARCH_PAGE) : 100;
const STAR_LIMIT = 20;

const BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz";

export function randomBase36(length) {
  const bytes = randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) out += BASE36[bytes[i] % 36];
  return out;
}

/// An id that sorts by time: ten base-36 digits of milliseconds, then six random ones. It is always greater than `after`.
export function sortableId(ms = Date.now(), after = "") {
  for (;;) {
    const id = ms.toString(36).padStart(10, "0") + randomBase36(6);
    if (id > after) return id;
    ms += 1;
  }
}

/// A stable 16-character id for something seeded, so a restart gives the same ids and live tests can name them.
export function stableId(seed) {
  const hex = createHash("sha256").update(seed).digest("hex");
  return BigInt("0x" + hex.slice(0, 20)).toString(36).padStart(16, "0").slice(0, 16);
}

export const htmlEscape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const decodeEntities = (text) =>
  text.replace(/&(#x?[0-9a-f]+|amp|lt|gt|quot|apos|nbsp);/gi, (whole, name) => {
    const lower = name.toLowerCase();
    if (lower === "amp") return "&";
    if (lower === "lt") return "<";
    if (lower === "gt") return ">";
    if (lower === "quot") return '"';
    if (lower === "apos") return "'";
    if (lower === "nbsp") return " ";
    const code = lower[1] === "x" ? parseInt(lower.slice(2), 16) : parseInt(lower.slice(1), 10);
    return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole;
  });

const VOID_TAGS = new Set(["br", "hr", "img", "input", "meta", "link"]);

/// A small HTML tree: strings and `{ tag, attrs, children }`. Forgiving of stray closing tags, since clients send whatever their editor wrote.
function parseHtml(html) {
  const root = { tag: "#root", attrs: "", children: [] };
  const stack = [root];
  const token = /<!--[\s\S]*?-->|<\/([a-z0-9-]+)\s*>|<([a-z0-9-]+)((?:[^>"']|"[^"]*"|'[^']*')*)>|([^<]+|<)/gi;
  let match;
  while ((match = token.exec(html))) {
    const top = stack[stack.length - 1];
    if (match[0].startsWith("<!--")) continue;
    if (match[1]) {
      const tag = match[1].toLowerCase();
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tag === tag) {
          stack.length = i;
          break;
        }
      }
    } else if (match[2]) {
      const tag = match[2].toLowerCase();
      const node = { tag, attrs: match[3], children: [] };
      top.children.push(node);
      if (!VOID_TAGS.has(tag) && !match[3].trimEnd().endsWith("/")) stack.push(node);
    } else top.children.push(match[4]);
  }
  return root;
}

const attribute = (attrs, name) => new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i").exec(attrs)?.slice(1).find((value) => value !== undefined);

const isMention = (node) =>
  node.tag === "action-text-attachment" && attribute(node.attrs, "content-type") === "application/vnd.campfire.mention" && attribute(node.attrs, "sgid") !== undefined;

const isRoomMention = (node) =>
  node.tag === "action-text-attachment" && attribute(node.attrs, "content-type") === "application/vnd.campfire.room" && attribute(node.attrs, "sgid") !== undefined;

/// The special mentions a body makes, narrowest first.
export function specialMentionsOf(html) {
  const made = mentionIdsOf(html);
  return SPECIAL_MENTIONS.filter((mention) => made.includes(mention));
}

/// The body with each of the `refused` special mentions as the text it reads as, which notifies nobody.
export function specialMentionsAsText(html, refused) {
  if (refused.length === 0) return html;
  return html.replace(/<action-text-attachment((?:[^>"']|"[^"]*"|'[^']*')*)>(?:[^<]*<\/action-text-attachment\s*>)?/gi, (whole, attrs) => {
    const sgid = attribute(attrs, "sgid");
    return attribute(attrs, "content-type") === "application/vnd.campfire.mention" && refused.includes(sgid) ? `@${sgid}` : whole;
  });
}

/// The ids a body mentions, once each, in order: people's, and the special mentions.
export function mentionIdsOf(html) {
  const ids = [];
  const walk = (node) => {
    if (typeof node === "string") return;
    if (isMention(node)) {
      const id = attribute(node.attrs, "sgid");
      if (!ids.includes(id)) ids.push(id);
    }
    node.children.forEach(walk);
  };
  walk(parseHtml(html));
  return ids;
}

/// Action Text's plain text of a body: what search matches, and what a notification would say. A mention of a
/// room reads as `#` and what `roomNameOf` answers, or "private room" when it answers nothing.
export function plainTextOf(html, nameOf, roomNameOf = () => undefined) {
  const render = (node, listDepth, counter) => {
    if (typeof node === "string") return decodeEntities(node);
    const inner = (depth = listDepth, count = counter) => node.children.map((child) => render(child, depth, count)).join("");
    switch (node.tag) {
      case "br":
        return "\n";
      case "p":
      case "h1":
      case "h2":
      case "h3":
      case "h4":
      case "h5":
      case "h6":
      case "pre":
        return inner() + "\n\n";
      case "div":
        return inner() + "\n";
      case "blockquote":
        return `“${inner().replace(/\n+$/, "")}”\n\n`;
      case "ul":
      case "ol": {
        const items = { ordered: node.tag === "ol", n: 0 };
        return (listDepth > 0 ? "\n" : "") + inner(listDepth + 1, items) + (listDepth > 0 ? "" : "\n");
      }
      case "li": {
        const bullet = counter?.ordered ? `${++counter.n}.` : "•";
        return `${"  ".repeat(Math.max(listDepth - 1, 0))}${bullet} ${inner().replace(/\n+$/, "")}\n`;
      }
      case "figcaption":
        return `[${inner()}]`;
      case "script":
      case "style":
        return "";
      case "action-text-attachment": {
        const sgid = attribute(node.attrs, "sgid");
        if (isMention(node)) return SPECIAL_MENTIONS.includes(sgid) ? `@${sgid}` : `@${nameOf(sgid) ?? "someone"}`;
        return isRoomMention(node) ? `#${roomNameOf(sgid) ?? "private room"}` : "";
      }
      default:
        return inner();
    }
  };
  return render(parseHtml(html), 0, null).replace(/\n+$/, "");
}

const WORD_SPLIT = /[^\p{L}\p{M}\p{N}\p{Pc}‌‍]+/u;
const wordsOf = (text) => text.split(WORD_SPLIT).filter(Boolean);
const hasLinkable = (text) => /\bhttps?:\/\/\S+|\bwww\.\S+\.\S+/i.test(text);

const iso = (ms) => new Date(ms).toISOString();
const versionOf = (ms) => iso(ms).slice(0, 19).replace(/\D/g, "");
/// A section's name as no two can have it: ASCII letters in either case alike.
const sectionKey = (name) => name.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
const isSchedulable = (time, now) => time > now && time <= now + SCHEDULE_AHEAD_MS;
const soonestFirst = (a, b) => a.sendAt - b.sendAt || (a.id < b.id ? -1 : 1);
const scheduledWire = (message) => ({
  id: message.id,
  clientMessageId: message.clientMessageId,
  body: message.body,
  sendAt: iso(message.sendAt),
  ...(message.parentId !== undefined && { parentId: message.parentId, alsoSend: message.alsoSend === true }),
  ...(message.failure !== undefined && { failure: message.failure }),
});

export class Store {
  users = new Map();
  rooms = new Map();
  sessions = new Map();
  favourites = new Map();
  searches = new Map();
  sharedOrder = [];
  /// The sections shared rooms are listed under, in order: { id, name }. A room names its own in `sectionId`.
  sections = [];
  /// The id of the room made last, so that two made in one millisecond keep that order, which a sidebar lists them by.
  madeLast = "";
  invitations = new Map();
  account = { name: process.env.EMBER_WORKSPACE_NAME || "Fernwood", tagline: "Calm software, made together" };
  joinCode = "";
  /// Replaced by server.mjs: who hears what, and who is where.
  hub = { room() {}, person() {}, workspace() {}, everyone() {}, closeRoom() {}, viewers: () => new Set(), present: () => [], active: () => [], typing: () => {} };
  /// People invited by email and not yet joined, newest first: { id, emailAddress, invitedBy, createdAt, expiresAt, delivery, digest }.
  emailInvitations = [];

  // People

  addUser({ id, name, email = null, bio = null, role = "member", createdAt }) {
    const user = { id, name, email, bio, role, createdAt, updatedAt: createdAt, status: "active", passwordDigest: null, avatar: null };
    this.users.set(id, user);
    return user;
  }

  userByEmail(email) {
    const wanted = email.trim().toLowerCase();
    for (const user of this.users.values()) if (user.email === wanted) return user;
    return null;
  }

  me = (user) => ({ id: user.id, name: user.name, administrator: user.role === "administrator" });
  ref = (userId) => {
    const user = this.users.get(userId);
    return { id: userId, name: user?.name ?? "Someone" };
  };
  nameOf = (userId) => this.users.get(userId)?.name;
  /// A room's name as a mention of it reads: an open room's, and nothing for any other.
  roomNameOf = (roomId) => {
    const room = this.rooms.get(roomId);
    return room?.kind === "open" ? room.name : undefined;
  };

  directoryUser(user, avatarToken) {
    return {
      id: user.id,
      name: user.name,
      bio: user.bio,
      role: user.role,
      status: user.status ?? "active",
      avatarUrl: `/users/${avatarToken(user.id)}/avatar?v=${versionOf(user.updatedAt)}`,
      // Only while it lasts, and only for someone active.
      ...((user.status ?? "active") === "active" && user.pausedUntil > Date.now() && { pausedUntil: iso(user.pausedUntil) }),
    };
  }

  // Rooms

  addRoom({ id, kind, name = null, icon = null, memberIds, createdAt, by, sectionId = null }) {
    const room = {
      id,
      kind,
      name,
      icon,
      createdAt,
      by,
      members: new Map(),
      messages: [],
      seq: 0,
      changes: [],
      activeAt: createdAt,
      channelMentions: true,
      sectionId,
      /// Messages to send later: { id, creatorId, clientMessageId, body, sendAt, parentId?, alsoSend?, failure? }, `sendAt` in milliseconds.
      scheduled: [],
      /// Messages only one person sees, kept until they're answered: { forUserId, message }.
      ephemeral: [],
    };
    // `since` is when each member was put in the room, which their sidebar lists their rooms by.
    for (const userId of memberIds) room.members.set(userId, { unread: false, involvement: kind === "direct" ? "everything" : "mentions", since: createdAt });
    this.rooms.set(id, room);
    return room;
  }

  roomWire(room) {
    if (room.kind === "direct") return { id: room.id, kind: "direct", members: [...room.members.keys()].map(this.ref), activeAt: iso(room.activeAt) };
    return { id: room.id, kind: room.kind, name: room.name, icon: room.icon, ...(room.channelMentions === false && { channelMentions: false }) };
  }

  /// The rooms `userId` is in, in the order they were put in them, then oldest first, as the real
  /// server lists them (`ORDER BY memberships.created_at, rooms.created_at, rooms.id`).
  roomsOf(userId) {
    return [...this.rooms.values()]
      .filter((room) => room.members.has(userId))
      .sort((a, b) => a.members.get(userId).since - b.members.get(userId).since || a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
  }

  favouritesOf(userId) {
    let favourites = this.favourites.get(userId);
    if (!favourites) this.favourites.set(userId, (favourites = { rooms: [], version: 0 }));
    return favourites;
  }

  sidebar(userId) {
    const rooms = this.roomsOf(userId);
    const favourites = this.favouritesOf(userId);
    const invitation = this.users.get(userId)?.role === "administrator" && !this.invitations.get(userId) ? { roomId: this.originalRoom().id, joinCode: this.joinCode } : null;
    const sections = this.sidebarSections(userId, this.users.get(userId)?.role === "administrator");
    return {
      rooms: rooms.map((room) => {
        const state = room.members.get(userId);
        return { ...this.roomWire(room), ...this.markOf(room, state), involvement: state.involvement };
      }),
      favorites: { rooms: [...favourites.rooms], version: favourites.version },
      sharedOrder: this.sharedOrder.filter((id) => rooms.some((room) => room.id === id)),
      invitation,
      ...(sections.length > 0 && { sections }),
    };
  }

  /// A member's unread mark as the sidebar lists it: when the first message they haven't seen came and, in a DM, how
  /// many have come since, or in any other room, how many of them mention the member, if any do.
  markOf(room, state) {
    if (!state.unread) return { unread: false };
    return {
      unread: true,
      ...(state.unreadAt !== undefined && { unreadSince: iso(state.unreadAt) }),
      ...(room.kind === "direct" && { unreadCount: Math.max(state.unreadCount ?? 0, 1) }),
      ...(room.kind !== "direct" && state.mentionCount > 0 && { mentionCount: state.mentionCount }),
    };
  }

  // Sections

  administrators = () => [...this.users.values()].filter((user) => user.role === "administrator" && user.status === "active");

  /// The section a room is in, or null.
  sectionOf(room) {
    const section = this.sections.find((candidate) => candidate.id === room.sectionId);
    return section ? { id: section.id, name: section.name } : null;
  }

  sectionNamed(name) {
    const key = sectionKey(name);
    return this.sections.find((section) => sectionKey(section.name) === key) ?? null;
  }

  /// The sections in order, each with which of `userId`'s rooms are in it: every one for `every`, as for an
  /// administrator, or else those with a room.
  sidebarSections(userId, every) {
    const rooms = this.roomsOf(userId);
    return this.sections
      .map(({ id, name }) => ({ id, name, roomIds: rooms.filter((room) => room.sectionId === id).map((room) => room.id) }))
      .filter((section) => every || section.roomIds.length > 0);
  }

  /// Every section, in order, with how many of `userId`'s rooms are in it, as New room and a room's settings offer them.
  sectionOptions(userId) {
    return this.sidebarSections(userId, true).map(({ roomIds, ...section }) => ({ ...section, rooms: roomIds.length }));
  }

  /// A new section, last. Administrators hear that the sidebar's layout changed.
  addSection(name) {
    const section = { id: sortableId(), name };
    this.sections.push(section);
    for (const user of this.administrators()) this.hub.workspace(user.id, { type: "rooms.reordered" });
    return section;
  }

  renameSection(section, name) {
    if (section.name === name) return;
    section.name = name;
    this.hub.everyone({ type: "rooms.reordered" });
  }

  /// Removes a section, leaving its rooms in none.
  deleteSection(section) {
    this.sections = this.sections.filter((candidate) => candidate !== section);
    for (const room of this.rooms.values()) if (room.sectionId === section.id) room.sectionId = null;
    this.hub.everyone({ type: "rooms.reordered" });
  }

  /// What a room's `section` comes to for `user`: `{ sectionId }`, undefined to leave the room where it is and null for
  /// none, or `{ status, error }`. A new section is made here, so ask last, once nothing else can refuse the change.
  chooseSection(user, choice) {
    if (choice === undefined || choice === null) return { sectionId: choice };
    if (typeof choice === "string") return this.sections.some((section) => section.id === choice) ? { sectionId: choice } : { status: 422, error: "Section not found" };
    const named = this.sectionNamed(choice.name);
    if (named) return { sectionId: named.id };
    if (user.role !== "administrator") return { status: 403, error: SECTIONS_FORBIDDEN };
    if (this.sections.length >= MAX_SECTIONS) return { status: 422, error: TOO_MANY_SECTIONS };
    return { sectionId: this.addSection(choice.name).id };
  }

  /// Puts the sections in the order a layout lists them, the ones it doesn't list after them as they were, and each of
  /// `roomIds` in the section that lists it, or in none. A room in a section the layout doesn't list stays there, and
  /// so does one put in a section that isn't there.
  placeRooms(roomIds, sections) {
    const listed = new Set(sections.map((section) => section.id));
    const placed = sections.map((section) => this.sections.find((candidate) => candidate.id === section.id)).filter(Boolean);
    this.sections = [...placed, ...this.sections.filter((section) => !placed.includes(section))];
    const sectionOf = new Map(sections.flatMap((section) => section.roomIds.map((roomId) => [roomId, section.id])));
    for (const roomId of roomIds) {
      const room = this.rooms.get(roomId);
      const target = sectionOf.get(roomId) ?? null;
      if (!room || (target !== null && !this.sections.some((section) => section.id === target))) continue;
      if (room.sectionId === null || listed.has(room.sectionId)) room.sectionId = target;
    }
  }

  /// Everyone active, by name, as a room's settings list them.
  activePeople() {
    return [...this.users.values()].filter((user) => user.status === "active").sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()) || (a.id < b.id ? -1 : 1));
  }

  /// A new open or closed room. An open room has everyone active; a closed one just the people named who exist, as on the real server, which does not add the creator.
  createRoom(creatorId, { kind, name, icon, memberIds, sectionId = null }) {
    const now = Date.now();
    const ids = kind === "closed" ? [...new Set(memberIds)].filter((id) => this.users.has(id)) : this.activePeople().map((user) => user.id);
    this.madeLast = sortableId(now, this.madeLast);
    const room = this.addRoom({ id: this.madeLast, kind, name, icon: icon || null, memberIds: ids, createdAt: now, by: creatorId, sectionId });
    const wire = this.roomWire(room);
    const section = this.sectionOf(room);
    for (const id of ids) this.hub.workspace(id, { type: "room.saved", room: wire, ...(section && { section }) });
    return room;
  }

  /// Renames, re-icons, opens or closes a room, turns its room-wide mentions on or off, or puts it in a section (`sectionId`
  /// null for none). Answers whether it changed. Opening adds everyone active; closing keeps exactly `memberIds`.
  changeRoom(room, { name, icon, kind, memberIds, channelMentions, sectionId }) {
    const before = this.roomWire(room);
    const sectionBefore = room.sectionId;
    if (name !== undefined) room.name = name;
    if (icon !== undefined) room.icon = icon || null;
    if (channelMentions !== undefined) room.channelMentions = channelMentions;
    if (sectionId !== undefined) room.sectionId = sectionId;
    const was = new Set(room.members.keys());
    let wanted = was;
    if (kind === "open") wanted = new Set([...was, ...this.activePeople().map((user) => user.id)]);
    else if (kind === "closed") wanted = new Set(memberIds.filter((id) => this.users.has(id)));
    if (kind !== undefined) room.kind = kind;
    const added = [...wanted].filter((id) => !was.has(id));
    const removed = [...was].filter((id) => !wanted.has(id));
    const now = Date.now();
    for (const id of added) room.members.set(id, { unread: false, involvement: "mentions", since: now });
    for (const id of removed) {
      room.members.delete(id);
      // What they had waiting here goes with them.
      room.scheduled = room.scheduled.filter((message) => message.creatorId !== id);
      room.ephemeral = room.ephemeral.filter((kept) => kept.forUserId !== id);
      const favourites = this.favouritesOf(id);
      if (favourites.rooms.includes(room.id)) {
        favourites.rooms = favourites.rooms.filter((candidate) => candidate !== room.id);
        favourites.version += 1;
        this.hub.workspace(id, { type: "favorites.changed", favorites: { rooms: [...favourites.rooms], version: favourites.version } });
      }
    }
    const wire = this.roomWire(room);
    const moved = room.sectionId !== sectionBefore;
    const changed = JSON.stringify(before) !== JSON.stringify(wire) || moved;
    for (const id of removed) {
      this.hub.workspace(id, { type: "room.gone", roomId: room.id });
      this.hub.closeRoom(room.id, id, 4004, "NotFound");
    }
    // The room's section goes with it whenever it has one, and null when it has just left one.
    const section = this.sectionOf(room);
    const saved = { type: "room.saved", room: wire, ...(section ? { section } : moved && { section: null }) };
    for (const id of changed ? room.members.keys() : added) this.hub.workspace(id, saved);
    if (added.length > 0 && this.sharedOrder.includes(room.id)) for (const id of added) this.hub.workspace(id, { type: "rooms.reordered" });
    return changed;
  }

  /// Puts people in a closed room and takes others out, everyone else staying as they are.
  changeMembers(room, addedIds, removedIds) {
    const members = new Set([...room.members.keys(), ...addedIds]);
    for (const id of removedIds) members.delete(id);
    return this.changeRoom(room, { kind: "closed", memberIds: [...members] });
  }

  /// The special mentions that notify `room` when `userId` makes them, narrowest first: none in a DM, in a room with them
  /// turned off, or from Ember's own assistant, and @everyone only in an open room.
  notifyingMentions(room, userId) {
    if (room.kind === "direct" || room.channelMentions === false || userId === ASSISTANT_ID) return [];
    return room.kind === "open" ? [...SPECIAL_MENTIONS] : ["here", "channel"];
  }

  /// How many people `room` has, and how many each special mention would notify from `userId`: everyone else in it who
  /// is active and no bot, or for @here, those of them active now.
  notified(room, userId) {
    const everyone = [...room.members.keys()].filter((id) => {
      const user = this.users.get(id);
      return id !== userId && user?.status === "active" && user.role !== "bot";
    });
    const active = new Set(this.hub.active());
    const here = everyone.filter((id) => active.has(id)).length;
    return { members: everyone.length + 1, mentions: Object.fromEntries(this.notifyingMentions(room, userId).map((mention) => [mention, mention === "here" ? here : everyone.length])) };
  }

  /// Removes a room and its messages, telling its members and closing its sockets.
  deleteRoom(room) {
    const members = [...room.members.keys()];
    this.rooms.delete(room.id);
    this.sharedOrder = this.sharedOrder.filter((id) => id !== room.id);
    for (const id of members) {
      const favourites = this.favouritesOf(id);
      if (favourites.rooms.includes(room.id)) {
        favourites.rooms = favourites.rooms.filter((candidate) => candidate !== room.id);
        favourites.version += 1;
      }
      this.hub.workspace(id, { type: "room.gone", roomId: room.id });
    }
    this.hub.closeRoom(room.id, null, 4004, "NotFound");
  }

  originalRoom() {
    return [...this.rooms.values()].sort((a, b) => a.createdAt - b.createdAt)[0];
  }

  /// Answers the new favourites, or null when the room can't be starred: a DM, a hidden room, or one the person isn't in.
  setFavourite(userId, roomId, favourite) {
    const room = this.rooms.get(roomId);
    const state = room?.members.get(userId);
    if (!room || !state || room.kind === "direct" || state.involvement === "invisible") return null;
    const favourites = this.favouritesOf(userId);
    const has = favourites.rooms.includes(roomId);
    if (favourite && !has) {
      if (favourites.rooms.length >= STAR_LIMIT) return null;
      favourites.rooms.push(roomId);
      favourites.version += 1;
    } else if (!favourite && has) {
      favourites.rooms = favourites.rooms.filter((id) => id !== roomId);
      favourites.version += 1;
    }
    const result = { rooms: [...favourites.rooms], version: favourites.version };
    this.hub.workspace(userId, { type: "favorites.changed", favorites: result });
    return result;
  }

  setInvolvement(userId, roomId, involvement) {
    const state = this.rooms.get(roomId)?.members.get(userId);
    if (!state) return null;
    state.involvement = involvement;
    const favourites = this.favouritesOf(userId);
    if (involvement === "invisible" && favourites.rooms.includes(roomId)) {
      favourites.rooms = favourites.rooms.filter((id) => id !== roomId);
      favourites.version += 1;
      this.hub.workspace(userId, { type: "favorites.changed", favorites: { rooms: [...favourites.rooms], version: favourites.version } });
    }
    this.hub.workspace(userId, { type: "room.involvement", roomId, involvement });
    return involvement;
  }

  /// The DM of exactly these people, made if there isn't one. `started` says whether it's new.
  startDirect(creatorId, userIds) {
    const people = [...new Set([creatorId, ...userIds])].sort();
    const key = people.join(",");
    for (const room of this.rooms.values()) {
      if (room.kind === "direct" && [...room.members.keys()].sort().join(",") === key) return { room, started: false };
    }
    const now = Date.now();
    const room = this.addRoom({ id: sortableId(now), kind: "direct", memberIds: people, createdAt: now, by: creatorId });
    const wire = this.roomWire(room);
    for (const id of people) this.hub.workspace(id, { type: "room.saved", room: wire });
    return { room, started: true };
  }

  // Messages

  nextSeq(room, kind, messageId) {
    room.seq += 1;
    room.changes.push({ seq: room.seq, kind, messageId });
    return room.seq;
  }

  repliesOf(room, parentId) {
    return room.messages.filter((message) => message.parentId === parentId && !message.deleted);
  }

  wire(room, message) {
    const wire = {
      id: message.id,
      clientMessageId: message.clientMessageId,
      roomId: room.id,
      creator: this.ref(message.creatorId),
      body: message.body,
      plainText: message.plainText,
      mentions: message.mentionIds.map(this.ref),
      createdAt: iso(message.createdAt),
      updatedAt: iso(message.updatedAt),
      editedAt: message.editedAt === null ? null : iso(message.editedAt),
      boosts: message.boosts.map((boost) => ({ id: boost.id, messageId: message.id, booster: this.ref(boost.userId), content: boost.content, createdAt: iso(boost.createdAt) })),
    };
    if (message.attachment) wire.attachment = message.attachment;
    if (message.cards) wire.cards = message.cards;
    if (message.parentId) {
      wire.parentId = message.parentId;
      wire.alsoSent = message.alsoSent === true;
      const parent = room.messages.find((candidate) => candidate.id === message.parentId);
      if (parent) wire.parentText = Array.from(parent.plainText).slice(0, PARENT_TEXT_LENGTH).join("");
    }
    const replies = this.repliesOf(room, message.id);
    if (replies.length > 0) {
      const people = [];
      for (const reply of [...replies].reverse()) if (!people.includes(reply.creatorId)) people.push(reply.creatorId);
      wire.thread = { count: replies.length, latestAt: iso(replies[replies.length - 1].createdAt), people: people.slice(0, THREAD_FACES).map(this.ref) };
    }
    if (message.notifies) wire.notifies = message.notifies;
    if (message.deleted) wire.deleted = true;
    return wire;
  }

  timeline = (room) => room.messages.filter((message) => !message.parentId || message.alsoSent);

  newestPage(room) {
    const timeline = this.timeline(room);
    const messages = timeline.slice(-HISTORY_PAGE_SIZE);
    return { messages: messages.map((message) => this.wire(room, message)), hasMore: timeline.length > messages.length, hasNewer: false, around: null };
  }

  aroundPage(room, messageId) {
    const timeline = this.timeline(room);
    const index = timeline.findIndex((message) => message.id === messageId);
    if (index < 0) return this.newestPage(room);
    const start = Math.max(0, index - HISTORY_PAGE_SIZE);
    const end = Math.min(timeline.length, index + HISTORY_PAGE_SIZE + 1);
    return { messages: timeline.slice(start, end).map((message) => this.wire(room, message)), hasMore: start > 0, hasNewer: end < timeline.length, around: messageId };
  }

  before(room, before, limit) {
    const older = this.timeline(room).filter((message) => message.id < before);
    const messages = older.slice(-limit);
    return { type: "history", before, messages: messages.map((message) => this.wire(room, message)), hasMore: older.length > messages.length };
  }

  after(room, after, limit) {
    const newer = this.timeline(room).filter((message) => message.id > after);
    const messages = newer.slice(0, limit);
    return { type: "history.after", after, messages: messages.map((message) => this.wire(room, message)), hasNewer: newer.length > messages.length };
  }

  /// What a socket that names the latest change it saw gets in place of a welcome, or null when it must have a welcome.
  resumedSince(room, since) {
    if (!Number.isInteger(since) || since < 0 || since > room.seq || room.seq - since > CHANGES_KEPT) return null;
    const upserted = new Set();
    const deleted = new Set();
    for (const change of room.changes) {
      if (change.seq <= since) continue;
      if (change.kind === "delete") {
        upserted.delete(change.messageId);
        deleted.add(change.messageId);
      } else if (!deleted.has(change.messageId)) upserted.add(change.messageId);
    }
    const messages = this.timeline(room)
      .filter((message) => upserted.has(message.id))
      .map((message) => this.wire(room, message));
    return { messages, deletedIds: [...deleted] };
  }

  /// Checks and stores a body: its markup, plain text and mentions, or the reason it was refused.
  prepareBody(body) {
    if (typeof body !== "string" || body.length > MAX_MESSAGE_HTML_LENGTH) return { error: "That message couldn’t be saved." };
    const html = body.replace(/<(script|style)[\s\S]*?<\/\1\s*>/gi, "");
    const mentionIds = mentionIdsOf(html).filter((id) => this.users.has(id));
    const plainText = plainTextOf(html, this.nameOf, this.roomNameOf);
    if (plainText.trim() === "" && mentionIds.length === 0) return { error: "Your message is empty." };
    if (plainText.length > MAX_MESSAGE_LENGTH) return { error: `Messages can be up to ${MAX_MESSAGE_LENGTH.toLocaleString("en-US")} characters.` };
    return { html, plainText, mentionIds, specialMentions: specialMentionsOf(html) };
  }

  /// Which of a new message's special mentions notifies the room: the widest of those `userId` may make there. The
  /// rest are left in its body as the text they read as. A reply in a thread notifies nobody, and stays as written.
  #notifying(room, userId, prepared, inThread) {
    const made = prepared.specialMentions ?? [];
    if (made.length === 0 || inThread) return undefined;
    const allowed = this.notifyingMentions(room, userId);
    prepared.html = specialMentionsAsText(prepared.html, made.filter((mention) => !allowed.includes(mention)));
    return made.filter((mention) => allowed.includes(mention)).at(-1);
  }

  /// Adds a message for `userId`, tells everyone, and answers it, or `{ error }` with the frame to send back.
  /// A file's message has no body: its plain text is the file's name. Nothing is de-duplicated by `clientMessageId`, as on the real server:
  /// a create sent twice is stored twice, and only `message.check` tells a client what's already stored.
  /// `bot` is for the server's own scripted bots, never a client's frame: `{ cards, cardsText }`, cards as `keptCards` answers them.
  /// A message with cards may have no text; its plain text is the text's, then the cards'.
  createMessage(room, userId, { clientMessageId, body, parentId, alsoSend, attachment }, at = Date.now(), bot = {}) {
    const fail = (message) => ({ error: { type: "error", message, clientMessageId, failed: "message.create" } });
    let parent = null;
    if (parentId !== undefined && parentId !== null) {
      parent = room.messages.find((message) => message.id === parentId);
      if (!parent || parent.parentId) return fail(MESSAGE_GONE);
    }
    let prepared;
    if (attachment) prepared = { html: "", plainText: attachment.name, mentionIds: [] };
    else if (bot.cards?.length > 0) {
      prepared = body === "" ? { html: "", plainText: "", mentionIds: [] } : this.prepareBody(body);
      if (prepared.error) return fail(prepared.error);
      prepared.plainText = [prepared.plainText, bot.cardsText ?? ""].filter((line) => line !== "").join("\n");
      if (prepared.plainText.length > MAX_MESSAGE_LENGTH) return fail(`Messages can be up to ${MAX_MESSAGE_LENGTH.toLocaleString("en-US")} characters.`);
    } else {
      prepared = this.prepareBody(body);
      if (prepared.error) return fail(prepared.error);
    }
    const notifies = this.#notifying(room, userId, prepared, parent !== null);
    const id = sortableId(at, room.messages.at(-1)?.id ?? "");
    const message = {
      id,
      clientMessageId,
      creatorId: userId,
      body: prepared.html,
      plainText: prepared.plainText,
      mentionIds: prepared.mentionIds,
      createdAt: at,
      updatedAt: at,
      editedAt: null,
      boosts: [],
      parentId: parent?.id,
      alsoSent: parent ? alsoSend === true : undefined,
      deleted: false,
    };
    if (notifies) message.notifies = notifies;
    if (attachment) message.attachment = attachment;
    if (bot.cards?.length > 0) message.cards = bot.cards;
    room.messages.push(message);
    this.#announceCreated(room, message, parent);
    return { message };
  }

  #announceCreated(room, message, parent) {
    const seq = this.nextSeq(room, "upsert", message.id);
    this.hub.room(room.id, { type: "message.created", message: this.wire(room, message), seq });
    this.hub.typing(room.id, message.creatorId, false);
    if (parent) {
      const parentSeq = this.nextSeq(room, "upsert", parent.id);
      this.hub.room(room.id, { type: "message.updated", message: this.wire(room, parent), seq: parentSeq });
    }
    const inRoom = !parent || message.alsoSent;
    if (inRoom) {
      const viewers = this.hub.viewers(room.id);
      const direct = room.kind === "direct";
      // @channel and @everyone mention everyone in the room, and @here those active now, besides the people named.
      const everyone = message.notifies === "channel" || message.notifies === "everyone";
      const mentioned = new Set(message.notifies === "here" ? [...message.mentionIds, ...this.hub.active()] : message.mentionIds);
      for (const [memberId, state] of room.members) {
        if (memberId === message.creatorId || viewers.has(memberId) || state.involvement === "invisible") continue;
        // A room is marked once, and counts the messages that mention the member; a DM counts every message, as on the real server.
        const marked = !state.unread || direct;
        const counted = !direct && (everyone || mentioned.has(memberId));
        if (!marked && !counted) continue;
        if (!state.unread) Object.assign(state, { unread: true, unreadAt: message.createdAt, unreadCount: 0, mentionCount: 0 });
        if (marked) state.unreadCount = (state.unreadCount ?? 0) + 1;
        if (counted) state.mentionCount = (state.mentionCount ?? 0) + 1;
        const { unreadSince, unreadCount, mentionCount } = this.markOf(room, state);
        this.hub.workspace(memberId, { type: "room.unread", roomId: room.id, at: unreadSince, ...(unreadCount !== undefined && { count: unreadCount }), ...(mentionCount !== undefined && { mentions: mentionCount }) });
      }
    }
    if (room.kind === "direct" && inRoom) {
      room.activeAt = message.createdAt;
      for (const memberId of room.members.keys()) this.hub.workspace(memberId, { type: "room.active", roomId: room.id, at: iso(message.createdAt) });
    }
  }

  /// Marks the room read for `userId`, and tells their sockets if it wasn't already.
  markRead(room, userId) {
    const state = room.members.get(userId);
    if (state?.unread) {
      Object.assign(state, { unread: false, unreadAt: undefined, unreadCount: 0, mentionCount: 0 });
      this.hub.workspace(userId, { type: "room.read", roomId: room.id });
    }
  }

  updateMessage(room, userId, { messageId, body }) {
    const message = room.messages.find((candidate) => candidate.id === messageId);
    const administrator = this.users.get(userId)?.role === "administrator";
    if (!message || message.deleted || (message.creatorId !== userId && !administrator)) return { error: { type: "error", message: "You can only edit your own messages" } };
    if (message.cards) return { error: { type: "error", message: "Messages with cards can't be edited.", failed: "message.update" } };
    const prepared = this.prepareBody(body);
    if (prepared.error) return { error: { type: "error", message: prepared.error, failed: "message.update" } };
    if (prepared.html === message.body) return {};
    message.body = prepared.html;
    message.plainText = prepared.plainText;
    message.mentionIds = prepared.mentionIds;
    // An edit can only narrow what the message notified, or take it away: its body is left as written.
    if (message.notifies) {
      const widest = prepared.specialMentions.at(-1);
      if (widest === undefined) delete message.notifies;
      else message.notifies = SPECIAL_MENTIONS[Math.min(SPECIAL_MENTIONS.indexOf(message.notifies), SPECIAL_MENTIONS.indexOf(widest))];
    }
    message.updatedAt = message.editedAt = Date.now();
    const seq = this.nextSeq(room, "upsert", message.id);
    this.hub.room(room.id, { type: "message.updated", message: this.wire(room, message), seq });
    return {};
  }

  /// A bot replaces its own message's text, as a bot's PUT does on the real server: the cards go, the message is marked
  /// edited, and everyone hears `message.updated`. Answers false when there is no such message of the bot's.
  replaceBotMessage(room, botId, messageId, body) {
    const message = room.messages.find((candidate) => candidate.id === messageId);
    if (!message || message.deleted || message.creatorId !== botId) return false;
    const prepared = this.prepareBody(body);
    if (prepared.error) return false;
    if (prepared.html === message.body && !message.cards) return true;
    message.body = prepared.html;
    message.plainText = prepared.plainText;
    message.mentionIds = prepared.mentionIds;
    delete message.cards;
    message.updatedAt = message.editedAt = Date.now();
    const seq = this.nextSeq(room, "upsert", message.id);
    this.hub.room(room.id, { type: "message.updated", message: this.wire(room, message), seq });
    return true;
  }

  /// A message with replies is blanked rather than removed. Removing a reply tells the room first, then refreshes its parent, or removes the parent too when it was a blank with no replies left.
  deleteMessage(room, userId, messageId) {
    const message = room.messages.find((candidate) => candidate.id === messageId);
    const administrator = this.users.get(userId)?.role === "administrator";
    if (!message || message.deleted || (message.creatorId !== userId && !administrator)) return { error: { type: "error", message: "You can only delete your own messages" } };
    if (this.repliesOf(room, message.id).length > 0) {
      message.deleted = true;
      message.body = "";
      message.plainText = "";
      message.mentionIds = [];
      message.boosts = [];
      delete message.attachment;
      delete message.cards;
      delete message.notifies;
      const seq = this.nextSeq(room, "upsert", message.id);
      this.hub.room(room.id, { type: "message.updated", message: this.wire(room, message), seq });
      return {};
    }
    room.messages = room.messages.filter((candidate) => candidate.id !== message.id);
    const seq = this.nextSeq(room, "delete", message.id);
    this.hub.room(room.id, { type: "message.deleted", messageId: message.id, seq });
    const parent = message.parentId ? room.messages.find((candidate) => candidate.id === message.parentId) : null;
    if (parent && parent.deleted && this.repliesOf(room, parent.id).length === 0) {
      room.messages = room.messages.filter((candidate) => candidate.id !== parent.id);
      const parentSeq = this.nextSeq(room, "delete", parent.id);
      this.hub.room(room.id, { type: "message.deleted", messageId: parent.id, seq: parentSeq });
    } else if (parent) {
      const parentSeq = this.nextSeq(room, "upsert", parent.id);
      this.hub.room(room.id, { type: "message.updated", message: this.wire(room, parent), seq: parentSeq });
    }
    return {};
  }

  createBoost(room, userId, { messageId, content }) {
    const message = room.messages.find((candidate) => candidate.id === messageId);
    if (!message || message.deleted) return { error: { type: "error", message: "That message no longer exists", failed: "boost.create" } };
    if (typeof content !== "string" || content.trim() === "") return { error: { type: "error", message: "Boosts can’t be empty.", failed: "boost.create" } };
    if (content.length > MAX_BOOST_LENGTH) return { error: { type: "error", message: `Boosts can be up to ${MAX_BOOST_LENGTH} characters.`, failed: "boost.create" } };
    if (message.boosts.some((boost) => boost.userId === userId && boost.content === content)) return {};
    const boost = { id: sortableId(Date.now()), userId, content, createdAt: Date.now() };
    message.boosts.push(boost);
    const seq = this.nextSeq(room, "upsert", message.id);
    this.hub.room(room.id, {
      type: "boost.created",
      boost: { id: boost.id, messageId, booster: this.ref(userId), content, createdAt: iso(boost.createdAt) },
      seq,
    });
    return {};
  }

  deleteBoost(room, userId, boostId) {
    const message = room.messages.find((candidate) => candidate.boosts.some((boost) => boost.id === boostId));
    const boost = message?.boosts.find((candidate) => candidate.id === boostId);
    if (!message || !boost || boost.userId !== userId) return { error: { type: "error", message: "You can only remove your own reactions", failed: "boost.delete" } };
    message.boosts = message.boosts.filter((candidate) => candidate.id !== boostId);
    const seq = this.nextSeq(room, "upsert", message.id);
    this.hub.room(room.id, { type: "boost.deleted", boostId, messageId: message.id, seq });
    return {};
  }

  /// A thread as it opens for `userId`, with the messages only they see in it, if there are any. Leave `userId` out for a
  /// socket that is sent none.
  threadOpened(room, parentId, userId) {
    const only = userId === undefined ? [] : this.ephemeralOf(room, userId, parentId);
    const ephemeral = only.length > 0 && { ephemeral: only };
    const parent = room.messages.find((message) => message.id === parentId && !message.parentId);
    if (!parent) return { type: "thread.opened", parentId, parent: null, messages: [], hasMore: false, ...ephemeral };
    const replies = this.repliesOf(room, parentId);
    const messages = replies.slice(-HISTORY_PAGE_SIZE);
    return { type: "thread.opened", parentId, parent: this.wire(room, parent), messages: messages.map((message) => this.wire(room, message)), hasMore: replies.length > messages.length, ...ephemeral };
  }

  threadBefore(room, parentId, before, limit) {
    const older = this.repliesOf(room, parentId).filter((message) => message.id < before);
    const messages = older.slice(-limit);
    return { type: "thread.history", parentId, before, messages: messages.map((message) => this.wire(room, message)), hasMore: older.length > messages.length };
  }

  // Scheduled messages

  /// What `userId` has scheduled in `room`, soonest first, as the room lists it to them.
  scheduledOf(room, userId) {
    return room.scheduled.filter((message) => message.creatorId === userId).sort(soonestFirst).map(scheduledWire);
  }

  /// Keeps a message for `userId` to send at `sendAt`, in milliseconds, and answers why not, if it doesn't. One sent
  /// again with the same `clientMessageId` is kept once.
  schedule(room, userId, { clientMessageId, body, sendAt, parentId, alsoSend }, now = Date.now()) {
    if (!isSchedulable(sendAt, now)) return SCHEDULE_TIME_REFUSED;
    const theirs = room.scheduled.filter((message) => message.creatorId === userId);
    if (theirs.some((message) => message.clientMessageId === clientMessageId)) return null;
    if (theirs.length >= MAX_SCHEDULED_MESSAGES) return TOO_MANY_SCHEDULED;
    if (parentId !== undefined && !room.messages.some((message) => message.id === parentId && !message.parentId)) return MESSAGE_GONE;
    const prepared = this.prepareBody(body);
    if (prepared.error) return prepared.error;
    room.scheduled.push({ id: randomUUID(), creatorId: userId, clientMessageId, body: prepared.html, sendAt, ...(parentId !== undefined && { parentId, alsoSend: alsoSend === true }) });
    return null;
  }

  /// Edits, moves, sends or deletes the scheduled message a `scheduled.*` frame names, if it's `userId`'s, and answers
  /// why nothing changed, if nothing did. A reschedule's `sendAt` is in milliseconds.
  changeScheduled(room, userId, frame, now = Date.now()) {
    const message = room.scheduled.find((candidate) => candidate.id === frame.scheduledId);
    if (!message || message.creatorId !== userId) return SCHEDULED_GONE;
    switch (frame.type) {
      case "scheduled.edit": {
        const prepared = this.prepareBody(frame.body);
        if (prepared.error) return prepared.error;
        message.body = prepared.html;
        return null;
      }
      case "scheduled.reschedule":
        if (!isSchedulable(frame.sendAt, now)) return SCHEDULE_TIME_REFUSED;
        message.sendAt = frame.sendAt;
        delete message.failure;
        return null;
      case "scheduled.send":
        return this.sendScheduled(room, message);
      default:
        room.scheduled = room.scheduled.filter((candidate) => candidate !== message);
        return null;
    }
  }

  /// Sends a scheduled message now, as `message.create` would have, and forgets it, or keeps it saying why it couldn't
  /// be sent, which it answers. One that's stored already isn't sent again.
  sendScheduled(room, scheduled) {
    const sent = room.messages.some((message) => message.creatorId === scheduled.creatorId && message.clientMessageId === scheduled.clientMessageId);
    const { error } = sent ? {} : this.createMessage(room, scheduled.creatorId, { clientMessageId: scheduled.clientMessageId, body: scheduled.body, parentId: scheduled.parentId, alsoSend: scheduled.alsoSend });
    const failure = error === undefined ? null : error.message === MESSAGE_GONE ? THREAD_DELETED : error.message;
    if (failure === null) room.scheduled = room.scheduled.filter((candidate) => candidate !== scheduled);
    else scheduled.failure = failure;
    return failure;
  }

  /// Sends the scheduled messages that are due, the soonest few in each room, and answers whose lists changed, as
  /// `[room, userId]` pairs. A writer who isn't in the room any more has theirs forgotten.
  sendDue(now = Date.now()) {
    const changed = [];
    for (const room of this.rooms.values()) {
      const due = room.scheduled.filter((message) => message.failure === undefined && message.sendAt <= now).sort(soonestFirst).slice(0, SCHEDULED_SENT_AT_ONCE);
      const writers = new Set();
      for (const message of due) {
        if (room.members.has(message.creatorId) && this.users.get(message.creatorId)?.status === "active") this.sendScheduled(room, message);
        else room.scheduled = room.scheduled.filter((candidate) => candidate !== message);
        writers.add(message.creatorId);
      }
      for (const userId of writers) changed.push([room, userId]);
    }
    return changed;
  }

  // Messages only one person sees

  /// The messages only `userId` sees in `room`: the room's own, or with `parentId`, that thread's.
  ephemeralOf(room, userId, parentId) {
    return room.ephemeral.filter((kept) => kept.forUserId === userId && kept.message.parentId === parentId).map((kept) => kept.message);
  }

  /// Shows `userId` alone a message from `botId`, with cards as `keptCards` answers them, and keeps it until it's answered.
  showOnly(room, userId, botId, { body = "", cards, cardsText = "", parentId }, at = Date.now()) {
    const plainText = [body === "" ? "" : plainTextOf(body, this.nameOf, this.roomNameOf), cardsText].filter((line) => line !== "").join("\n");
    const message = { id: randomUUID(), roomId: room.id, creator: this.ref(botId), body, plainText, cards, createdAt: iso(at), ...(parentId !== undefined && { parentId }) };
    room.ephemeral.push({ forUserId: userId, message });
    this.hub.person(room.id, userId, { type: "message.ephemeral", message });
    return message;
  }

  /// The kept message with this id that `userId` can answer, if there is one.
  keptEphemeral(room, userId, messageId) {
    return room.ephemeral.find((kept) => kept.forUserId === userId && kept.message.id === messageId) ?? null;
  }

  /// Stops keeping an answered message, and shows its asker what came of it in its place: the same message, with these cards.
  decideEphemeral(room, kept, { cards, cardsText = "" }) {
    room.ephemeral = room.ephemeral.filter((candidate) => candidate !== kept);
    const text = kept.message.body === "" ? "" : plainTextOf(kept.message.body, this.nameOf, this.roomNameOf);
    const message = { ...kept.message, cards, plainText: [text, cardsText].filter((line) => line !== "").join("\n") };
    this.hub.person(room.id, kept.forUserId, { type: "message.ephemeral", message });
    return message;
  }

  // Search

  recentSearches = (userId) => this.searches.get(userId) ?? [];

  /// Answers what `searchOf` made of a request, or `{ error }` (a 422's message).
  normaliseSearch(input) {
    if (input.q !== undefined && typeof input.q !== "string") return { error: "Searches have to be text" };
    const q = (input.q ?? "").trim().replace(/\s+/g, " ");
    if (q.length > MAX_SEARCH_LENGTH) return { error: "Searches can be up to 1,000 characters." };
    if (input.in !== undefined && input.in !== null && typeof input.in !== "string") return { error: "A search can only be in a room" };
    if (input.from !== undefined && input.from !== null && typeof input.from !== "string") return { error: "A search can only be from a person" };
    if (input.sort !== undefined && input.sort !== null && input.sort !== "newest" && input.sort !== "oldest") return { error: "Search results are sorted by newest or oldest" };
    for (const flag of ["withMe", "hasLink", "hasFile", "inThread"]) {
      if (input[flag] !== undefined && typeof input[flag] !== "boolean") return { error: "A search’s filters are on or off" };
    }
    const search = { q };
    if (input.in) search.in = input.in;
    if (input.from) search.from = input.from;
    for (const flag of ["withMe", "hasLink", "hasFile", "inThread"]) if (input[flag] === true) search[flag] = true;
    return { search, sort: input.sort ?? "newest" };
  }

  isSearchable = (search) => wordsOf(search.q).length > 0 || Boolean(search.in || search.from || search.withMe || search.hasLink || search.hasFile || search.inThread);

  record(userId, search) {
    if (!this.isSearchable(search)) return;
    const key = JSON.stringify(search);
    const recent = this.recentSearches(userId).filter((candidate) => JSON.stringify(candidate) !== key);
    this.searches.set(userId, [search, ...recent].slice(0, RECENT_SEARCHES));
  }

  clearSearches = (userId) => this.searches.set(userId, []);

  search(userId, search, sort, cursor) {
    const recent = this.recentSearches(userId);
    if (!this.isSearchable(search)) return { search: null, matches: [], next: null, rooms: [], recent };
    const words = wordsOf(search.q).map((word) => word.toLowerCase());
    const hits = [];
    for (const room of this.roomsOf(userId)) {
      if (search.in && room.id !== search.in) continue;
      // Each room is read once for which messages have replies, and which threads are yours, so a
      // search stays linear in the room's length.
      const parents = new Set();
      const yourThreads = new Set();
      for (const message of room.messages) {
        if (message.parentId && !message.deleted) parents.add(message.parentId);
        if (message.creatorId === userId) yourThreads.add(message.parentId ?? message.id);
      }
      for (const message of room.messages) {
        if (message.deleted) continue;
        if (search.from && message.creatorId !== search.from) continue;
        const threadId = message.parentId ?? (parents.has(message.id) ? message.id : null);
        if (search.inThread && threadId === null) continue;
        if (search.hasFile && !message.attachment) continue;
        if (search.hasLink && (message.attachment || !(hasLinkable(message.plainText) || /<a\s[^>]*\bhref=/i.test(message.body) || (message.cards !== undefined && (/<a\s[^>]*\bhref=/i.test(JSON.stringify(message.cards)) || hasLinkable(JSON.stringify(message.cards))))))) continue;
        if (search.withMe) {
          const mine =
            message.mentionIds.includes(userId) ||
            room.kind === "direct" ||
            (threadId !== null && yourThreads.has(threadId));
          if (!mine) continue;
        }
        let matched = [];
        if (words.length > 0) {
          const tokens = wordsOf(message.plainText);
          const found = words.map((word) => tokens.filter((token) => token.toLowerCase().startsWith(word)));
          if (found.some((tokensFor) => tokensFor.length === 0)) continue;
          const seen = new Set();
          for (const token of found.flat()) {
            const lower = token.toLowerCase();
            if (!seen.has(lower)) {
              seen.add(lower);
              matched.push(token);
            }
          }
        }
        hits.push({ room, message, words: matched });
      }
    }
    hits.sort((a, b) => (a.message.id < b.message.id ? -1 : 1));
    if (sort !== "oldest") hits.reverse();
    const first = cursor === null || cursor === undefined ? 0 : cursor + 1;
    const page = hits.slice(first, first + SEARCH_LIMIT);
    const last = first + page.length - 1;
    const rooms = [];
    for (const { room } of page) if (!rooms.some((known) => known.id === room.id)) rooms.push(room);
    return {
      search,
      matches: page.map(({ room, message, words: matched }) => ({ message: this.wire(room, message), words: matched })),
      next: page.length > 0 && last < hits.length - 1 ? last : null,
      rooms: rooms.map((room) => this.roomWire(room)),
      recent,
    };
  }
}
