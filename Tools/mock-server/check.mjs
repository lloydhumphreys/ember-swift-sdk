#!/usr/bin/env node
// Exercises a running stand-in server end to end: `node check.mjs http://127.0.0.1:8790`. It starts nothing,
// prints a line per check, and exits 1 if any failed. It signs in with the shared password, read the way the
// server reads it (EMBER_SEED_PASSWORD, or the file under .dev), and prints neither it nor any cookie.
// Run it against a freshly started server: a first run reads the seeded unread marks, so a second can't see them.

import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const origin = process.argv[2]?.replace(/\/+$/, "");
if (!origin) {
  console.error("Usage: node check.mjs <origin>, e.g. http://127.0.0.1:8790");
  process.exit(2);
}

const PASSWORD_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.dev/seed-password");
let password = process.env.EMBER_SEED_PASSWORD;
if (!password && existsSync(PASSWORD_FILE)) password = readFileSync(PASSWORD_FILE, "utf8");
password = password?.trim();
if (!password) {
  console.error(`No seed password. Set EMBER_SEED_PASSWORD, or put one in ${PASSWORD_FILE}.`);
  process.exit(2);
}

// HTTP

function request(method, pathAndQuery, { cookie, headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(origin);
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const sent = { ...headers };
    if (cookie) sent.Cookie = cookie;
    if (payload !== undefined) {
      sent["Content-Type"] = "application/json";
      sent["Content-Length"] = Buffer.byteLength(payload);
    }
    const req = http.request({ host: url.hostname, port: url.port, path: pathAndQuery, method, headers: sent }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {}
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on("error", reject);
    req.end(payload);
  });
}

/// Signs in as `email` and answers the session cookie, ready for a Cookie header.
async function signIn(email) {
  const res = await request("POST", "/api/session", { body: { emailAddress: email, password } });
  if (res.status !== 201) throw new Error(`Signing in as ${email} answered ${res.status}`);
  const cookie = (res.headers["set-cookie"] ?? []).map((line) => line.split(";")[0]).find((pair) => pair.startsWith("session_token="));
  if (!cookie) throw new Error("No session cookie came back");
  return cookie;
}

// A WebSocket client, by hand: the handshake over node:http's upgrade, masked text frames out, and frames in.

class Client {
  frames = [];
  closed = null;
  #waiting = [];
  #closeWaiters = [];
  #buffer = Buffer.alloc(0);
  #socket;

  constructor(socket, head) {
    this.#socket = socket;
    socket.on("data", (chunk) => this.#read(chunk));
    socket.on("close", () => this.#finish({ code: this.closed?.code ?? 1006, reason: this.closed?.reason ?? "" }));
    socket.on("error", () => {});
    if (head.length > 0) this.#read(head);
  }

  #finish(close) {
    this.closed = close;
    for (const waiter of this.#closeWaiters.splice(0)) waiter(close);
    for (const waiter of this.#waiting.splice(0)) waiter.reject(new Error(`The socket closed (${close.code}) while waiting for ${waiter.what}`));
  }

  #read(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    for (;;) {
      const buffer = this.#buffer;
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      if (buffer.length < offset + length) return;
      const payload = buffer.subarray(offset, offset + length);
      this.#buffer = buffer.subarray(offset + length);
      if (opcode === 0x1) this.#deliver(JSON.parse(payload.toString("utf8")));
      else if (opcode === 0x9) this.#write(0xa, payload);
      else if (opcode === 0x8) {
        this.closed = { code: payload.length >= 2 ? payload.readUInt16BE(0) : 1005, reason: payload.subarray(2).toString("utf8") };
        this.#write(0x8, payload.subarray(0, 2));
        this.#socket.end();
      }
    }
  }

  #deliver(frame) {
    const index = this.#waiting.findIndex((waiter) => waiter.test(frame));
    if (index >= 0) {
      const [waiter] = this.#waiting.splice(index, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(frame);
    } else this.frames.push(frame);
  }

  #write(opcode, payload) {
    const mask = randomBytes(4);
    const length = payload.length;
    const header = length < 126 ? Buffer.from([0x80 | opcode, 0x80 | length]) : Buffer.from([0x80 | opcode, 0x80 | 126, length >> 8, length & 0xff]);
    const masked = Buffer.from(payload);
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
    this.#socket.write(Buffer.concat([header, mask, masked]));
  }

  sendRaw(text) {
    this.#write(0x1, Buffer.from(text, "utf8"));
  }

  send(frame) {
    this.sendRaw(JSON.stringify(frame));
  }

  /// The next frame `test` accepts: one already received, or the first to arrive.
  next(test, what = "a frame", ms = 5000) {
    const index = this.frames.findIndex(test);
    if (index >= 0) return Promise.resolve(this.frames.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { test, resolve, reject, what };
      waiter.timer = setTimeout(() => {
        this.#waiting.splice(this.#waiting.indexOf(waiter), 1);
        reject(new Error(`Timed out waiting for ${what}`));
      }, ms);
      this.#waiting.push(waiter);
    });
  }

  nextOfType = (type, ms) => this.next((frame) => frame.type === type, type, ms);

  /// Whether no frame `test` accepts arrives within `ms`.
  async quiet(test, ms = 600) {
    await new Promise((resolve) => setTimeout(resolve, ms));
    return !this.frames.some(test);
  }

  whenClosed(ms = 3000) {
    if (this.closed && this.#socket.destroyed) return Promise.resolve(this.closed);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Timed out waiting for the socket to close")), ms);
      this.#closeWaiters.push((close) => {
        clearTimeout(timer);
        resolve(close);
      });
    });
  }

  close() {
    this.#socket.destroy();
  }
}

/// Opens a socket, answering `{ status: 101, client }` or, when the server refused the upgrade, `{ status, json }`.
function openSocket(pathAndQuery, { cookie, originHeader = origin } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(origin);
    const headers = { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Key": randomBytes(16).toString("base64"), "Sec-WebSocket-Version": "13" };
    if (originHeader) headers.Origin = originHeader;
    if (cookie) headers.Cookie = cookie;
    const req = http.request({ host: url.hostname, port: url.port, path: pathAndQuery, headers });
    req.on("upgrade", (res, socket, head) => {
      const expected = createHash("sha1").update(headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      if (res.headers["sec-websocket-accept"] !== expected) return reject(new Error("Sec-WebSocket-Accept is wrong"));
      resolve({ status: 101, client: new Client(socket, head) });
    });
    req.on("response", (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        let json = null;
        try {
          json = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch {}
        resolve({ status: res.statusCode, json });
      });
    });
    req.on("error", reject);
    req.end();
  });
}

async function connect(pathAndQuery, options) {
  const result = await openSocket(pathAndQuery, options);
  if (result.status !== 101) throw new Error(`The upgrade was refused with ${result.status}`);
  return result.client;
}

// The harness

let failures = 0;
const sockets = [];
async function check(name, run) {
  try {
    await run();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}: ${error.message}`);
  }
}

function expect(condition, message) {
  if (!condition) throw new Error(message);
}
const expectStatus = (res, status) => expect(res.status === status, `expected ${status}, got ${res.status}${res.json?.error ? ` (${res.json.error})` : ""}`);

const tracked = async (pathAndQuery, options) => {
  const client = await connect(pathAndQuery, options);
  sockets.push(client);
  return client;
};
const roomSocket = (roomId, cookie, query = "visible=1&protocol=4") => tracked(`/api/rooms/${roomId}/socket?${query}`, { cookie });

// The checks

const state = {};
const emails = { maya: "maya@example.com", sam: "sam@example.com", leo: "leo@example.com", tomas: "tomas@example.com" };

await check("a write from another origin is refused with 422", async () => {
  const res = await request("POST", "/api/session", { headers: { Origin: "http://evil.example" }, body: { emailAddress: emails.maya, password } });
  expectStatus(res, 422);
  expect(res.json?.error === "Requests from other sites are refused", "wrong message");
  const cross = await request("POST", "/api/session", { headers: { "Sec-Fetch-Site": "cross-site" }, body: { emailAddress: emails.maya, password } });
  expectStatus(cross, 422);
  const same = await request("POST", "/api/session", { headers: { Origin: origin }, body: { emailAddress: emails.maya, password: "not the password" } });
  expectStatus(same, 401);
});

await check("an unknown API path is 404", async () => {
  expectStatus(await request("GET", "/api/nothing"), 404);
});

await check("a wrong password is 401 with the standard message", async () => {
  const res = await request("POST", "/api/session", { body: { emailAddress: emails.maya, password: password + "x" } });
  expectStatus(res, 401);
  expect(res.json?.error === "Incorrect email or password. Please try again.", "wrong message");
  expectStatus(await request("POST", "/api/session", { body: { emailAddress: "nobody@example.com", password } }), 401);
  expectStatus(await request("POST", "/api/session", { body: { emailAddress: emails.maya, password: "" } }), 401);
});

await check("signing in answers 201 with a user and an HttpOnly cookie", async () => {
  const res = await request("POST", "/api/session", { body: { emailAddress: emails.maya, password } });
  expectStatus(res, 201);
  expect(res.json?.user?.administrator === true && res.json.user.name === "Maya Chen", "Maya should be the administrator");
  const line = (res.headers["set-cookie"] ?? []).find((value) => value.startsWith("session_token="));
  expect(line && /HttpOnly/i.test(line) && /Path=\//.test(line) && /SameSite=Lax/i.test(line), "the cookie is missing a flag");
  state.maya = line.split(";")[0];
  state.mayaId = res.json.user.id;
  state.sam = await signIn(emails.sam);
  state.leo = await signIn(emails.leo);
  state.tomas = await signIn(emails.tomas);
});

await check("guest sign-in follows the bootstrap's flag", async () => {
  const boot = await request("GET", "/api/bootstrap");
  expectStatus(boot, 200);
  expect(boot.json.user === null && boot.json.account?.name, "a signed-out bootstrap has no user and has the account");
  const guest = await request("POST", "/api/session", { body: { name: "Visitor" } });
  if (boot.json.guestSignIn) {
    expectStatus(guest, 201);
    expect(guest.json.user.administrator === false, "a guest isn't an administrator");
    expectStatus(await request("POST", "/api/session", { body: { name: "" } }), 422);
    const reserved = await request("POST", "/api/session", { body: { name: "Ember" } });
    expectStatus(reserved, 422);
  } else {
    expectStatus(guest, 403);
    expect(guest.json?.error === "Signing in with just a name is turned off", "wrong message");
  }
});

await check("me answers the user, and 401 when signed out", async () => {
  const res = await request("GET", "/api/me", { cookie: state.maya });
  expectStatus(res, 200);
  expect(res.json.user.id === state.mayaId, "wrong user");
  const out = await request("GET", "/api/me");
  expectStatus(out, 401);
  expect(out.json?.error === "Not signed in", "wrong message");
  const boot = await request("GET", "/api/bootstrap", { cookie: state.maya });
  expect(boot.json.user?.id === state.mayaId, "bootstrap should name the signed-in user");
});

let sidebar;
await check("the sidebar lists rooms, DMs, favourites and unread marks", async () => {
  const res = await request("GET", "/api/sidebar", { cookie: state.maya });
  expectStatus(res, 200);
  sidebar = res.json;
  const names = sidebar.rooms.filter((room) => room.kind !== "direct").map((room) => room.name);
  for (const name of ["general", "random", "Launch", "Design", "Engineering", "Support", "Leadership"]) expect(names.includes(name), `no ${name} room`);
  expect(sidebar.rooms.filter((room) => room.kind === "direct").length >= 3, "expected the seeded DMs");
  const group = sidebar.rooms.find((room) => room.kind === "direct" && room.members.length === 3);
  expect(group, "expected a group DM");
  expect(sidebar.rooms.find((room) => room.name === "Leadership").kind === "closed", "Leadership is closed");
  state.rooms = Object.fromEntries(sidebar.rooms.filter((room) => room.kind !== "direct").map((room) => [room.name, room.id]));
  state.samDm = sidebar.rooms.find((room) => room.kind === "direct" && room.members.length === 2 && room.members.some((member) => member.name === "Sam Rivera")).id;
  expect(sidebar.favorites.rooms.includes(state.rooms.Launch), "Launch should be starred");
  expect(sidebar.rooms.filter((room) => room.unread).length >= 2, "expected a couple of unread rooms");
  expect(Array.isArray(sidebar.sharedOrder) && Array.isArray(sidebar.suggestions), "sharedOrder and suggestions are lists");
  expect(sidebar.invitation === null || (sidebar.invitation.roomId && sidebar.invitation.joinCode), "the invitation is null or has a room and a code");
  const etag = res.headers.etag;
  expect(etag, "no ETag");
  const again = await request("GET", "/api/sidebar", { cookie: state.maya, headers: { "If-None-Match": etag } });
  expectStatus(again, 304);
  expectStatus(await request("GET", "/api/sidebar"), 401);
});

await check("users lists the directory, with the assistant", async () => {
  const res = await request("GET", "/api/users", { cookie: state.maya });
  expectStatus(res, 200);
  const users = res.json.users;
  expect(users.some((user) => user.id === "ember" && user.name === "Ember"), "no assistant");
  expect(users.filter((user) => user.role === "member" || user.role === "administrator").length >= 7, "expected the seeded people");
  expect(users.every((user) => user.status === "active" && /^\/users\/.+\/avatar\?v=\d+/.test(user.avatarUrl)), "an entry is missing its avatar address");
  const avatar = await request("GET", users[0].avatarUrl, { cookie: state.maya });
  expectStatus(avatar, 200);
  expect(avatar.headers["content-type"]?.startsWith("image/svg+xml"), "the avatar is an SVG");
  expectStatus(await request("GET", "/api/users"), 401);
});

await check("search finds messages, records, pages and clears", async () => {
  const found = await request("GET", `/api/searches?q=${encodeURIComponent("checklist")}`, { cookie: state.maya });
  expectStatus(found, 200);
  expect(found.json.matches.length >= 1 && found.json.matches[0].words.some((word) => word.toLowerCase() === "checklist"), "expected a match for checklist");
  expect(found.json.rooms.some((room) => room.id === state.rooms.Launch), "the room of the match comes back");
  const recorded = await request("POST", "/api/searches", { cookie: state.maya, body: { q: "  launch   checklist " } });
  expectStatus(recorded, 200);
  expect(recorded.json.search.q === "launch checklist" && recorded.json.recent[0].q === "launch checklist", "the search is normalised and recorded");
  const filtered = await request("GET", `/api/searches?q=&from=${state.mayaId}&has=link`, { cookie: state.maya });
  expect(filtered.json.search !== null && filtered.json.matches.every((match) => match.message.creator.id === state.mayaId), "from filters by author");
  const empty = await request("GET", "/api/searches", { cookie: state.maya });
  expect(empty.json.search === null && empty.json.matches.length === 0 && empty.json.recent.length >= 1, "an empty search is no search, with the recents");
  const oldest = await request("GET", "/api/searches?q=the&sort=oldest", { cookie: state.maya });
  const newest = await request("GET", "/api/searches?q=the&sort=newest", { cookie: state.maya });
  expect(oldest.json.matches[0].message.id < newest.json.matches[0].message.id, "sort=oldest starts earlier than newest");
  const tooLong = await request("GET", `/api/searches?q=${"a".repeat(1001)}`, { cookie: state.maya });
  expectStatus(tooLong, 422);
  expectStatus(await request("POST", "/api/searches", { cookie: state.maya, body: { q: 5 } }), 422);
  const cleared = await request("DELETE", "/api/searches", { cookie: state.maya });
  expectStatus(cleared, 204);
  expect((await request("GET", "/api/searches", { cookie: state.maya })).json.recent.length === 0, "recents are cleared");
  expectStatus(await request("GET", "/api/searches?q=x"), 401);
});

await check("favouriting and un-favouriting bumps the version", async () => {
  const off = await request("PUT", `/api/rooms/${state.rooms.Design}/favorite`, { cookie: state.maya, body: { favorite: true } });
  expectStatus(off, 200);
  expect(off.json.favorites.rooms.includes(state.rooms.Design), "Design should be starred");
  const back = await request("PUT", `/api/rooms/${state.rooms.Design}/favorite`, { cookie: state.maya, body: { favorite: false } });
  expect(back.json.favorites.version > off.json.favorites.version && !back.json.favorites.rooms.includes(state.rooms.Design), "un-starring bumps the version");
  expectStatus(await request("PUT", `/api/rooms/${state.samDm}/favorite`, { cookie: state.maya, body: { favorite: true } }), 403);
  expectStatus(await request("PUT", `/api/rooms/${state.rooms.Design}/favorite`, { cookie: state.maya, body: { favorite: "yes" } }), 400);
  expectStatus(await request("PUT", "/api/rooms/Not_An_Id/favorite", { cookie: state.maya, body: { favorite: true } }), 400);
  expectStatus(await request("PUT", `/api/rooms/${state.rooms.Design}/favorite`, { body: { favorite: true } }), 401);
});

await check("involvement changes a room's level", async () => {
  const set = await request("PUT", `/api/rooms/${state.rooms.Support}/involvement`, { cookie: state.maya, body: { involvement: "nothing" } });
  expectStatus(set, 200);
  expect(set.json.involvement === "nothing", "wrong level");
  const read = await request("GET", "/api/sidebar", { cookie: state.maya });
  expect(read.json.rooms.find((room) => room.id === state.rooms.Support).involvement === "nothing", "the sidebar shows the new level");
  expectStatus(await request("PUT", `/api/rooms/${state.rooms.Support}/involvement`, { cookie: state.maya, body: { involvement: "loud" } }), 422);
  expectStatus(await request("PUT", `/api/rooms/${state.rooms.Leadership}/involvement`, { cookie: state.leo, body: { involvement: "nothing" } }), 404);
  await request("PUT", `/api/rooms/${state.rooms.Support}/involvement`, { cookie: state.maya, body: { involvement: "mentions" } });
});

await check("a DM starts once, and answers the same room again", async () => {
  const people = (await request("GET", "/api/users", { cookie: state.maya })).json.users;
  const tomasId = people.find((user) => user.name.startsWith("Tom")).id;
  const first = await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: [tomasId] } });
  expect(first.status === 201 || first.status === 200, `expected 201 or 200, got ${first.status}`);
  expect(first.json.room.kind === "direct" && first.json.room.members.length === 2, "a DM has the two people");
  const again = await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: [tomasId] } });
  expectStatus(again, 200);
  expect(again.json.room.id === first.json.room.id, "the same DM comes back");
  expectStatus(await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: "nobody" } }), 422);
  expectStatus(await request("POST", "/api/directs", { body: { userIds: [] } }), 401);
});

await check("the workspace socket welcomes, pongs, and refuses the wrong origin or no cookie", async () => {
  const client = await tracked("/api/socket", { cookie: state.maya });
  const welcome = await client.nextOfType("welcome");
  expect(welcome.you.id === state.mayaId && welcome.account?.name, "welcome has you and the account");
  client.send({ type: "ping" });
  await client.nextOfType("pong");
  const foreign = await openSocket("/api/socket", { cookie: state.maya, originHeader: "http://evil.example" });
  expect(foreign.status === 404, `a foreign origin should get 404, got ${foreign.status}`);
  const noOrigin = await openSocket("/api/socket", { cookie: state.maya, originHeader: null });
  expect(noOrigin.status === 404, `no origin should get 404, got ${noOrigin.status}`);
  const anonymous = await openSocket("/api/socket");
  expect(anonymous.status === 401, `no cookie should get 401, got ${anonymous.status}`);
});

await check("a room socket refuses the wrong origin, no cookie and a bad id, and closes 4004 for a stranger", async () => {
  const path = `/api/rooms/${state.rooms.Launch}/socket?visible=1&protocol=4`;
  expect((await openSocket(path, { cookie: state.maya, originHeader: "http://evil.example" })).status === 404, "a foreign origin is 404");
  expect((await openSocket(path)).status === 401, "no cookie is 401");
  expect((await openSocket("/api/rooms/Bad_Id/socket?visible=1&protocol=4", { cookie: state.maya })).status === 404, "a bad room id is 404");
  const stranger = await connect(`/api/rooms/${state.rooms.Leadership}/socket?visible=1&protocol=4`, { cookie: state.leo });
  const close = await stranger.whenClosed();
  expect(close.code === 4004, `expected close 4004, got ${close.code}`);
});

await check("a room's welcome has the newest page, and history pages back to the start", async () => {
  const client = await roomSocket(state.rooms.general, state.maya);
  const welcome = await client.nextOfType("welcome");
  expect(welcome.messages.length === 40 && welcome.hasMore === true && welcome.hasNewer === false && welcome.around === null, "the first page is 40 messages with more behind");
  expect(Number.isInteger(welcome.seq) && welcome.present.some((user) => user.id === state.mayaId), "seq and present");
  const ids = welcome.messages.map((message) => message.id);
  expect(ids.every((id, index) => index === 0 || ids[index - 1] < id), "messages are oldest first");
  let total = welcome.messages.length;
  let oldest = ids[0];
  let more = welcome.hasMore;
  let pages = 0;
  const authors = new Set(welcome.messages.map((message) => message.creator.id));
  while (more && pages < 20) {
    client.send({ type: "history.before", before: oldest });
    const page = await client.nextOfType("history");
    expect(page.before === oldest && page.messages.length > 0, "a page answers for the id asked");
    expect(page.messages.every((message) => message.id < oldest), "the page is older");
    total += page.messages.length;
    oldest = page.messages[0].id;
    more = page.hasMore;
    pages += 1;
    page.messages.forEach((message) => authors.add(message.creator.id));
  }
  expect(total >= 100 && !more, `expected a long history that ends, got ${total}`);
  expect(authors.size >= 4, "several authors");
  client.send({ type: "history.around", messageId: oldest });
  const around = await client.nextOfType("history.around");
  expect(around.around === oldest && around.hasMore === false && around.hasNewer === true, "around the oldest has nothing older and more newer");
  client.send({ type: "history.after", after: oldest, limit: 10 });
  const after = await client.nextOfType("history.after");
  expect(after.messages.length === 10 && after.hasNewer === true, "history.after pages forward");
});

await check("a message sent comes back created to the sender and the other person, with unread to a third", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  const sam = await roomSocket(state.rooms.Launch, state.sam);
  const welcome = await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const tomasWorkspace = await tracked("/api/socket", { cookie: state.tomas });
  await tomasWorkspace.nextOfType("welcome");
  const clientMessageId = `check-${randomBytes(4).toString("hex")}`;
  maya.send({ type: "message.create", clientMessageId, body: "<p>Hello <strong>everyone</strong></p>" });
  const created = await maya.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === clientMessageId, "message.created");
  expect(created.seq === welcome.seq + 1, "seq counts on from the welcome");
  expect(created.message.plainText === "Hello everyone" && created.message.creator.id === state.mayaId, "the stored message");
  expect(Date.parse(created.message.createdAt) > 0 && created.message.editedAt === null && Array.isArray(created.message.boosts), "the message's dates and boosts");
  await sam.next((frame) => frame.type === "message.created" && frame.message.id === created.message.id, "message.created for Sam");
  await tomasWorkspace.next((frame) => frame.type === "room.unread" && frame.roomId === state.rooms.Launch, "room.unread for someone not viewing");
  state.sent = created.message;
  state.seqAfter = created.seq;
});

await check("an edit, a boost and a delete are broadcast, and others' messages are protected", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  const sam = await roomSocket(state.rooms.Launch, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const body = { clientMessageId: `check-${randomBytes(4).toString("hex")}`, body: "<p>Edit me</p>" };
  maya.send({ type: "message.create", ...body });
  const { message } = await maya.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === body.clientMessageId, "created");
  maya.send({ type: "message.update", messageId: message.id, body: "<p>Edited</p>" });
  const updated = await sam.next((frame) => frame.type === "message.updated" && frame.message.id === message.id, "message.updated");
  expect(updated.message.plainText === "Edited" && updated.message.editedAt !== null, "edited text and time");
  const samId = (await request("GET", "/api/me", { cookie: state.sam })).json.user.id;
  const mentioning = `<p>Edited <strong>for <action-text-attachment content-type="application/vnd.campfire.mention" sgid="${samId}"></action-text-attachment></strong></p>`;
  maya.send({ type: "message.update", messageId: message.id, body: mentioning });
  const mentioned = await sam.next((frame) => frame.type === "message.updated" && frame.message.id === message.id, "message.updated with a mention");
  expect(mentioned.message.body === mentioning && mentioned.message.plainText === `Edited for @${mentioned.message.mentions[0]?.name}`, "an edit adds a mention, kept as sent");
  expect(mentioned.message.mentions.length === 1 && mentioned.message.mentions[0].id === samId, "the edit's mention is listed");
  sam.send({ type: "message.update", messageId: message.id, body: "<p>Not yours</p>" });
  const refused = await sam.nextOfType("error");
  expect(refused.message === "You can only edit your own messages", "refused with the real message");
  sam.send({ type: "boost.create", messageId: message.id, content: "👍" });
  const boost = await maya.nextOfType("boost.created");
  expect(boost.boost.messageId === message.id && boost.boost.booster.id !== state.mayaId, "boost.created names the booster");
  sam.send({ type: "boost.delete", boostId: boost.boost.id });
  const gone = await maya.nextOfType("boost.deleted");
  expect(gone.boostId === boost.boost.id && gone.messageId === message.id, "boost.deleted");
  sam.send({ type: "message.delete", messageId: message.id });
  expect((await sam.nextOfType("error")).message === "You can only delete your own messages", "deleting another's is refused");
  maya.send({ type: "message.delete", messageId: message.id });
  const deleted = await sam.nextOfType("message.deleted");
  expect(deleted.messageId === message.id, "message.deleted");
  maya.send({ type: "message.create", clientMessageId: "check-empty", body: "<p></p>" });
  const empty = await maya.nextOfType("error");
  expect(empty.failed === "message.create" && empty.clientMessageId === "check-empty" && empty.message === "Your message is empty.", "an empty message is refused with the id");
});

await check("typing is passed between two signed-in people", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  const sam = await roomSocket(state.rooms.Launch, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  maya.send({ type: "typing.start" });
  const started = await sam.next((frame) => frame.type === "typing" && frame.typing === true, "typing true");
  expect(started.user.id === state.mayaId, "it names Maya");
  maya.send({ type: "typing.stop" });
  const stopped = await sam.next((frame) => frame.type === "typing" && frame.typing === false, "typing false");
  expect(stopped.user.id === state.mayaId, "it names Maya");
  expect(await maya.quiet((frame) => frame.type === "typing", 300), "the typist isn't told about their own typing");
});

await check("presence is announced when someone joins and leaves", async () => {
  // Leo has no other socket open, so his arrival is news; Sam, who has several, would not be.
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  await maya.nextOfType("welcome");
  const sam = await roomSocket(state.rooms.Launch, state.leo);
  const welcome = await sam.nextOfType("welcome");
  expect(welcome.present.some((user) => user.name === "Maya Chen"), "present lists who is there");
  const joined = await maya.nextOfType("presence.joined");
  expect(joined.user.name === "Leo Park", "presence.joined");
  sam.close();
  const left = await maya.nextOfType("presence.left");
  expect(typeof left.userId === "string", "presence.left");
});

await check("since resumes with what changed, and ping gets a pong", async () => {
  const sam = await roomSocket(state.rooms.Launch, state.sam);
  const first = await sam.nextOfType("welcome");
  sam.close();
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  await maya.nextOfType("welcome");
  const clientMessageId = `check-${randomBytes(4).toString("hex")}`;
  maya.send({ type: "message.create", clientMessageId, body: "<p>While you were away</p>" });
  await maya.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === clientMessageId, "created");
  const again = await roomSocket(state.rooms.Launch, state.sam, `visible=1&protocol=4&since=${first.seq}`);
  const resumed = await again.nextOfType("resumed");
  expect(resumed.messages.some((message) => message.clientMessageId === clientMessageId) && resumed.seq > first.seq, "resumed has the new message and a later seq");
  expect(Array.isArray(resumed.deletedIds) && resumed.you.id !== undefined, "resumed has deletedIds and you");
  again.send({ type: "ping" });
  await again.nextOfType("pong");
  again.sendRaw("{not json");
  expect((await again.nextOfType("error")).message === "Unrecognized frame", "an unreadable frame is an error");
  const ahead = await roomSocket(state.rooms.Launch, state.sam, "visible=1&protocol=4&since=999999");
  await ahead.nextOfType("welcome");
});

await check("message.check says which messages the room stored", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  await maya.nextOfType("welcome");
  maya.send({ type: "message.check", clientMessageIds: [state.sent.clientMessageId, "never-sent"] });
  const checked = await maya.nextOfType("message.checked");
  expect(checked.stored.includes(state.sent.clientMessageId) && checked.missing.includes("never-sent"), "stored and missing");
});

await check("a create sent twice under one id is stored twice, as on the real server", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  await maya.nextOfType("welcome");
  const clientMessageId = `check-${randomBytes(4).toString("hex")}`;
  const isMine = (frame) => frame.type === "message.created" && frame.message.clientMessageId === clientMessageId;
  maya.send({ type: "message.create", clientMessageId, body: "<p>Twice</p>" });
  const first = await maya.next(isMine, "the first");
  maya.send({ type: "message.create", clientMessageId, body: "<p>Twice</p>" });
  const second = await maya.next(isMine, "the second");
  expect(first.message.id !== second.message.id, "two messages");
  maya.send({ type: "message.check", clientMessageIds: [clientMessageId] });
  const checked = await maya.nextOfType("message.checked");
  expect(checked.stored.includes(clientMessageId) && checked.missing.length === 0, "the check says it's stored");
});

await check("the scripted person types, then replies, in a DM", async () => {
  const maya = await roomSocket(state.samDm, state.maya);
  await maya.nextOfType("welcome");
  const clientMessageId = `check-${randomBytes(4).toString("hex")}`;
  maya.send({ type: "message.create", clientMessageId, body: "<p>Are you there?</p>" });
  const typing = await maya.next((frame) => frame.type === "typing" && frame.typing === true, "the replier typing", 6000);
  expect(typing.user.name === "Sam Rivera", "Sam is the replier");
  const reply = await maya.next((frame) => frame.type === "message.created" && frame.message.creator.name === "Sam Rivera", "the reply", 8000);
  expect(reply.message.plainText.length > 0, "the reply has text");
  await maya.next((frame) => frame.type === "typing" && frame.typing === false, "typing stops", 2000);
});

await check("a thread opens with its replies", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  const welcome = await maya.nextOfType("welcome");
  const parent = welcome.messages.find((message) => message.thread);
  expect(parent && parent.thread.count >= 2, "the seeded thread is in the timeline");
  maya.send({ type: "thread.open", parentId: parent.id });
  const opened = await maya.nextOfType("thread.opened");
  expect(opened.parent?.id === parent.id && opened.messages.length === parent.thread.count && opened.messages.every((message) => message.parentId === parent.id), "the thread's replies");
});

await check("an outdated protocol is warned, and refused creates and edits", async () => {
  const fresh = await roomSocket(state.rooms.Launch, state.maya);
  await fresh.nextOfType("welcome");
  const own = `check-${randomBytes(4).toString("hex")}`;
  fresh.send({ type: "message.create", clientMessageId: own, body: "<p>Mine</p>" });
  const { message } = await fresh.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === own, "created");
  const old = await roomSocket(state.rooms.Launch, state.maya, "visible=1&protocol=3");
  const warning = await old.nextOfType("error");
  expect(warning.message === "Ember has been updated. Reload the page to keep chatting.", "the warning");
  old.send({ type: "message.create", clientMessageId: "check-old", body: "<p>Late</p>" });
  const refusedCreate = await old.nextOfType("error");
  expect(refusedCreate.failed === "message.create" && refusedCreate.clientMessageId === "check-old" && refusedCreate.message === warning.message, "create is refused with its id");
  old.send({ type: "message.update", messageId: message.id, body: "<p>Changed</p>" });
  const refusedEdit = await old.nextOfType("error");
  expect(refusedEdit.failed === "message.update" && refusedEdit.message === warning.message, "update is refused");
  expect(await fresh.quiet((frame) => frame.type === "message.created" || frame.type === "message.updated", 300), "nothing was stored");
});

await check("a DM takes bots, ignores unknown ids, and allows long lists", async () => {
  const res = await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: ["ember", "nobodyatall"] } });
  expect(res.status === 201 || res.status === 200, `expected 201 or 200, got ${res.status}`);
  expect(res.json.room.members.length === 2 && res.json.room.members.some((member) => member.id === "ember"), "the assistant is the other member");
  const many = Array.from({ length: 1000 }, (_, i) => `unknown${i}`);
  expect((await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: many } })).status < 300, "1,000 ids are fine");
  expectStatus(await request("POST", "/api/directs", { cookie: state.maya, body: { userIds: [...many, "one-more"] } }), 422);
});

await check("lengths count UTF-16 units, and boosts are trimmed", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  await maya.nextOfType("welcome");
  const wave = "\u{1F44D}";
  maya.send({ type: "message.create", clientMessageId: "check-long", body: `<p>${wave.repeat(5001)}</p>` });
  const long = await maya.nextOfType("error");
  expect(long.failed === "message.create" && long.message === "Messages can be up to 10,000 characters.", "10,002 units are too long");
  const ok = `check-${randomBytes(4).toString("hex")}`;
  maya.send({ type: "message.create", clientMessageId: ok, body: `<p>${wave.repeat(5000)}</p>` });
  await maya.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === ok, "10,000 units are fine");
  const own = `check-${randomBytes(4).toString("hex")}`;
  maya.send({ type: "message.create", clientMessageId: own, body: "<p>React to me</p>" });
  const { message } = await maya.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === own, "created");
  maya.send({ type: "boost.create", messageId: message.id, content: wave.repeat(9) });
  expect((await maya.nextOfType("error")).message === "Unrecognized frame", "nine astral emoji are refused");
  maya.send({ type: "boost.create", messageId: message.id, content: `  ${wave}  ` });
  const boost = await maya.nextOfType("boost.created");
  expect(boost.boost.content === wave, "the boost is stored trimmed");
});

await check("room ids follow the real pattern", async () => {
  expectStatus(await request("PUT", "/api/rooms/some-room-1/favorite", { cookie: state.maya, body: { favorite: true } }), 403);
  expectStatus(await request("PUT", "/api/rooms/Bad_Room/favorite", { cookie: state.maya, body: { favorite: true } }), 400);
  expectStatus(await request("PUT", "/api/rooms/-nope/favorite", { cookie: state.maya, body: { favorite: true } }), 400);
  const stranger = await connect("/api/rooms/some-room-1/socket?visible=1&protocol=4", { cookie: state.maya });
  expect((await stranger.whenClosed()).code === 4004, "an unknown but well-formed room closes 4004");
  expect((await openSocket("/api/rooms/Bad_Room/socket?visible=1&protocol=4", { cookie: state.maya })).status === 404, "a malformed id is 404");
});

// Threads, as the real server keeps them

/// A new top-level message from `client`, answered as the `message.created` frame's message.
async function post(client, html, extra = {}) {
  const clientMessageId = `check-${randomBytes(5).toString("hex")}`;
  client.send({ type: "message.create", clientMessageId, body: html, ...extra });
  const { message } = await client.next((frame) => frame.type === "message.created" && frame.message.clientMessageId === clientMessageId, "created");
  return message;
}

const reply = (client, parent, html, extra = {}) => post(client, html, { parentId: parent.id, ...extra });

await check("replies always say alsoSent, parents list repliers newest first, and the timeline leaves out thread-only replies", async () => {
  const maya = await roomSocket(state.rooms.Support, state.maya);
  const sam = await roomSocket(state.rooms.Support, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const parent = await post(maya, "<p>Thread people</p>");
  expect(parent.thread === undefined && parent.parentId === undefined && parent.alsoSent === undefined, "a fresh parent has no thread and no alsoSent");
  const first = await reply(sam, parent, "<p>one</p>");
  expect(first.alsoSent === false && first.parentText === "Thread people", "a reply says alsoSent: false and quotes its parent");
  const second = await reply(maya, parent, "<p>two</p>", { alsoSend: true });
  expect(second.alsoSent === true, "alsoSend: true is alsoSent: true");
  await reply(sam, parent, "<p>three</p>");
  maya.send({ type: "thread.open", parentId: parent.id });
  const opened = await maya.nextOfType("thread.opened");
  expect(opened.parent.thread.count === 3, "three replies");
  expect(opened.parent.thread.people.map((person) => person.name).join() === "Sam Rivera,Maya Chen", "people are newest replier first, once each");
  const fresh = await roomSocket(state.rooms.Support, state.leo);
  const welcome = await fresh.nextOfType("welcome");
  const ids = welcome.messages.map((message) => message.id);
  expect(ids.includes(parent.id) && ids.includes(second.id) && !ids.includes(first.id), "the timeline has the parent and the also-sent reply, not the other replies");
  state.threadParent = parent;
});

await check("a deleted parent with replies stays as a tombstone that still takes replies", async () => {
  const maya = await roomSocket(state.rooms.Support, state.maya);
  const sam = await roomSocket(state.rooms.Support, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const parent = await post(maya, "<p>Soon a tombstone</p>");
  const kept = await reply(sam, parent, "<p>I stay</p>");
  maya.send({ type: "message.delete", messageId: parent.id });
  const updated = await sam.next((frame) => frame.type === "message.updated" && frame.message.id === parent.id && frame.message.deleted === true, "message.updated");
  expect(updated.message.deleted === true && updated.message.body === "" && updated.message.plainText === "" && updated.message.thread.count === 1, "a tombstone is blank, deleted, and keeps its thread");
  expect(await sam.quiet((frame) => frame.type === "message.deleted", 300), "no message.deleted for it");
  const late = await reply(sam, parent, "<p>Still here</p>");
  expect(late.parentId === parent.id && late.parentText === "", "a tombstone takes a reply, quoting nothing");
  maya.send({ type: "message.update", messageId: parent.id, body: "<p>Back</p>" });
  expect((await maya.nextOfType("error")).message === "You can only edit your own messages", "a tombstone can't be edited");
  maya.send({ type: "message.delete", messageId: parent.id });
  expect((await maya.nextOfType("error")).message === "You can only delete your own messages", "a tombstone can't be deleted again");
  maya.send({ type: "boost.create", messageId: parent.id, content: "👍" });
  expect((await maya.nextOfType("error")).message === "That message no longer exists", "a tombstone can't be boosted");
  maya.send({ type: "thread.open", parentId: parent.id });
  const opened = await maya.nextOfType("thread.opened");
  expect(opened.parent?.deleted === true && opened.messages.length === 2, "a tombstone opens, with its replies");
  state.tombstone = { parent, replies: [kept, late] };
});

await check("deleting replies tells the room in order, and the last reply of a tombstone takes the tombstone with it", async () => {
  const maya = await roomSocket(state.rooms.Support, state.maya);
  const sam = await roomSocket(state.rooms.Support, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const { parent, replies } = state.tombstone;
  sam.send({ type: "message.delete", messageId: replies[0].id });
  const gone = await maya.nextOfType("message.deleted");
  const refreshed = await maya.nextOfType("message.updated");
  expect(gone.messageId === replies[0].id && refreshed.message.id === parent.id && refreshed.seq === gone.seq + 1 && refreshed.message.thread.count === 1, "message.deleted for the reply, then message.updated for the parent");
  sam.send({ type: "message.delete", messageId: replies[1].id });
  const lastGone = await maya.nextOfType("message.deleted");
  const parentGone = await maya.nextOfType("message.deleted");
  expect(lastGone.messageId === replies[1].id && parentGone.messageId === parent.id && parentGone.seq === lastGone.seq + 1, "message.deleted for the reply, then for the tombstone");
  expect(await maya.quiet((frame) => frame.type === "message.updated", 300), "no message.updated for the emptied tombstone");
  const open = await roomSocket(state.rooms.Support, state.maya);
  const welcome = await open.nextOfType("welcome");
  expect(!welcome.messages.some((message) => message.id === parent.id), "the tombstone is gone from the timeline");
  // A parent with no replies is removed outright, and one with replies is only updated.
  const plain = await post(maya, "<p>No replies</p>");
  maya.send({ type: "message.delete", messageId: plain.id });
  expect((await maya.nextOfType("message.deleted")).messageId === plain.id, "a parent with no replies is deleted");
});

await check("since leaves out thread-only replies but sends their parent, and falls back to a welcome past 100 changes", async () => {
  const watcher = await roomSocket(state.rooms.Engineering, state.sam);
  const first = await watcher.nextOfType("welcome");
  const maya = await roomSocket(state.rooms.Engineering, state.maya);
  await maya.nextOfType("welcome");
  const parent = await post(maya, "<p>Resume me</p>");
  const quiet = await reply(maya, parent, "<p>thread only</p>");
  const loud = await reply(maya, parent, "<p>also sent</p>", { alsoSend: true });
  const resumed = await (await roomSocket(state.rooms.Engineering, state.leo, `visible=1&protocol=4&since=${first.seq}`)).nextOfType("resumed");
  const ids = resumed.messages.map((message) => message.id);
  expect(ids.includes(parent.id) && ids.includes(loud.id) && !ids.includes(quiet.id), "the parent and the also-sent reply, not the thread-only one");
  expect(ids.every((id, index) => index === 0 || ids[index - 1] < id), "sorted by id");
  const start = (await (await roomSocket(state.rooms.Engineering, state.leo)).nextOfType("welcome")).seq;
  for (let i = 0; i < 101; i++) maya.send({ type: "message.create", clientMessageId: `check-bulk-${randomBytes(4).toString("hex")}`, body: `<p>bulk ${i}</p>` });
  await maya.next((frame) => frame.type === "message.created" && frame.message.plainText === "bulk 100", "the last bulk message", 8000);
  const edge = await roomSocket(state.rooms.Engineering, state.leo, `visible=1&protocol=4&since=${start + 1}`);
  expect((await edge.next((frame) => frame.type === "resumed" || frame.type === "welcome", "a resume")).type === "resumed", "100 changes behind still resumes");
  const far = await roomSocket(state.rooms.Engineering, state.leo, `visible=1&protocol=4&since=${start}`);
  expect((await far.next((frame) => frame.type === "resumed" || frame.type === "welcome", "a welcome")).type === "welcome", "101 changes behind gets a welcome");
});

await check("page limits are floored and held to 1..100, and a limit that isn't a number is the default", async () => {
  const maya = await roomSocket(state.rooms.Support, state.maya);
  await maya.nextOfType("welcome");
  const parent = await post(maya, "<p>Many replies</p>");
  for (let i = 0; i < 5; i++) await reply(maya, parent, `<p>r${i}</p>`);
  const asked = async (limit) => {
    maya.send({ type: "thread.before", parentId: parent.id, before: "zzzzzzzzzzzzzzzz", ...(limit === undefined ? {} : { limit }) });
    return (await maya.nextOfType("thread.history")).messages.length;
  };
  expect((await asked(0)) === 1 && (await asked(-4)) === 1, "0 and negatives are 1");
  expect((await asked(2.9)) === 2, "a fraction is floored");
  expect((await asked(1000)) === 5, "a big limit is held to 100, then to what exists");
  expect((await asked("3")) === 5 && (await asked(undefined)) === 5, "a string or nothing is the default of 40");
  maya.send({ type: "history.before", before: "zzzzzzzzzzzzzzzz", limit: 0 });
  expect((await maya.nextOfType("history")).messages.length === 1, "history.before clamps the same way");
});

await check("thread, create and check frames are validated as the real parser does", async () => {
  const maya = await roomSocket(state.rooms.Support, state.maya);
  await maya.nextOfType("welcome");
  const unrecognised = async (frame, what) => {
    maya.send(frame);
    expect((await maya.nextOfType("error")).message === "Unrecognized frame", what);
  };
  await unrecognised({ type: "message.create", clientMessageId: "check-null-parent", body: "<p>x</p>", parentId: null }, "a null parentId");
  await unrecognised({ type: "message.create", clientMessageId: "check-empty-parent", body: "<p>x</p>", parentId: "" }, "an empty parentId");
  await unrecognised({ type: "message.check", clientMessageIds: [] }, "no ids to check");
  await unrecognised({ type: "message.check", clientMessageIds: Array.from({ length: 51 }, (_, i) => `id${i}`) }, "51 ids to check");
  await unrecognised({ type: "message.check", clientMessageIds: ["fine", ""] }, "an empty id to check");
  await unrecognised({ type: "thread.close" }, "thread.close with no parent");
  maya.send({ type: "message.check", clientMessageIds: Array.from({ length: 50 }, (_, i) => `id${i}`) });
  expect((await maya.nextOfType("message.checked")).missing.length === 50, "50 ids are fine");
  maya.send({ type: "message.create", clientMessageId: "check-no-parent", body: "<p>x</p>", parentId: "no-such-message" });
  const missing = await maya.nextOfType("error");
  expect(missing.message === "That message no longer exists" && missing.failed === "message.create", "a missing parent");
  maya.send({ type: "thread.open", parentId: "no-such-message" });
  const none = await maya.nextOfType("thread.opened");
  expect(none.parent === null && none.messages.length === 0 && none.hasMore === false, "an unknown thread opens empty");
  const reply1 = (await (async () => { maya.send({ type: "thread.open", parentId: state.threadParent.id }); return maya.nextOfType("thread.opened"); })()).messages[0];
  maya.send({ type: "thread.open", parentId: reply1.id });
  expect((await maya.nextOfType("thread.opened")).parent === null, "a reply is not a thread");
  maya.send({ type: "message.create", clientMessageId: "check-reply-to-reply", body: "<p>x</p>", parentId: reply1.id });
  expect((await maya.nextOfType("error")).message === "That message no longer exists", "no replies to replies");
  maya.send({ type: "thread.close", parentId: reply1.id });
  expect(await maya.quiet(() => true, 300), "thread.close sends nothing back");
});

// Uploads and serving

const MIB = 1024 * 1024;

/// A request with a Buffer body and whatever headers are given. `chunked` sends no Content-Length.
function raw(method, pathAndQuery, { cookie, headers = {}, body, chunked = false, json } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(origin);
    const sent = { ...headers };
    if (cookie) sent.Cookie = cookie;
    const payload = json === undefined ? body : Buffer.from(JSON.stringify(json));
    if (payload !== undefined && !chunked) sent["Content-Length"] = payload.length;
    const req = http.request({ host: url.hostname, port: url.port, path: pathAndQuery, method, headers: sent }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const bytes = Buffer.concat(chunks);
        let parsed = null;
        try {
          parsed = JSON.parse(bytes.toString("utf8"));
        } catch {}
        resolve({ status: res.statusCode, headers: res.headers, bytes, text: bytes.toString("utf8"), json: parsed });
      });
    });
    req.on("error", reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

/// A PNG's signature and header, which is all the server reads of one, padded to `length` bytes.
function png(width, height, length = 64) {
  const header = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header);
  header.writeUInt32BE(13, 8);
  header.write("IHDR", 12, "latin1");
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  return Buffer.concat([header, Buffer.alloc(Math.max(0, length - 33), 7)]);
}

const uploadsPath = (roomId) => `/api/rooms/${roomId}/uploads`;
const startUpload = (roomId, cookie, file) => raw("POST", uploadsPath(roomId), { cookie, json: file });
const putPart = (roomId, cookie, id, n, bytes, options = {}) => raw("PUT", `${uploadsPath(roomId)}/${id}/parts/${n}`, { cookie, body: bytes, ...options });
const newFile = (name, size, extra = {}) => ({ name, type: "", size, clientMessageId: `check-${randomBytes(5).toString("hex")}`, ...extra });

/// Uploads `bytes` in one request and answers the message it posts.
async function uploadWhole(roomId, cookie, name, bytes, extra = {}) {
  const started = await startUpload(roomId, cookie, newFile(name, bytes.length, extra));
  expectStatus(started, 201);
  const done = await putPart(roomId, cookie, started.json.id, 1, bytes);
  expectStatus(done, 201);
  return { started: started.json, message: done.json };
}

await check("starting an upload answers its id, part size and part count, and checks the caller and the file", async () => {
  const room = state.rooms.Launch;
  const ok = await startUpload(room, state.maya, { ...newFile("notes.txt", 5), type: "text/plain", ignored: "yes" });
  expectStatus(ok, 201);
  expect(/^[0-9a-z]{28}$/.test(ok.json.id) && ok.json.partSize === 10 * MIB && ok.json.parts === 1, "id, partSize and parts");
  expect((await startUpload(room, state.maya, newFile("empty", 0))).json.parts === 1, "an empty file is one part");
  expect((await startUpload(room, state.maya, newFile("exact", 10 * MIB))).json.parts === 1, "exactly one part's worth is one part");
  expect((await startUpload(room, state.maya, newFile("over", 10 * MIB + 1))).json.parts === 2, "one byte more is two");
  expectStatus(await raw("POST", uploadsPath(room), { json: newFile("a", 1) }), 401);
  const stranger = await startUpload(state.samDm, state.leo, newFile("a", 1));
  expect(stranger.status === 404 && stranger.json.error === "Room not found or inaccessible", "a non-member is 404");
  expectStatus(await startUpload("Bad_Room", state.maya, newFile("a", 1)), 404);
  const refusal = async (file, status, message) => {
    const res = await startUpload(room, state.maya, file);
    expect(res.status === status && res.json?.error === message, `${message}: got ${res.status} ${res.json?.error}`);
  };
  await refusal(null, 422, "Expected a JSON object");
  await refusal([], 422, "Expected a JSON object");
  await refusal(newFile("   ", 1), 422, "A file needs a name");
  await refusal({ ...newFile("a", 1), name: 7 }, 422, "A file needs a name");
  await refusal(newFile("n".repeat(256), 1), 422, "That file's name can't be kept");
  await refusal(newFile("bad\ud800name", 1), 422, "That file's name can't be kept");
  await refusal({ ...newFile("a", 1), type: 5 }, 422, "A file's type must be text");
  await refusal({ ...newFile("a", 1), type: "t".repeat(256) }, 422, "A file's type must be text");
  await refusal({ ...newFile("a", 1), size: -1 }, 422, "A file's size must be a number of bytes");
  await refusal({ ...newFile("a", 1), size: 1.5 }, 422, "A file's size must be a number of bytes");
  await refusal({ ...newFile("a", 1), size: "5" }, 422, "A file's size must be a number of bytes");
  await refusal(newFile("a", 250_000_001), 413, "Files must be 250 MB or smaller.");
  await refusal({ ...newFile("a", 1), clientMessageId: "" }, 422, "A file needs an id for its message");
  await refusal({ ...newFile("a", 1), clientMessageId: "x".repeat(65) }, 422, "A file needs an id for its message");
  await refusal(newFile("a", 1, { parentId: "" }), 422, "A reply's thread must be a message's id");
  await refusal(newFile("a", 1, { parentId: "no-such-message" }), 422, "That message no longer exists");
  expect((await startUpload(room, state.maya, newFile("big", 250_000_000))).json.parts === 24, "250,000,000 bytes is allowed, in 24 parts");
  const huge = await raw("POST", uploadsPath(room), { cookie: state.maya, body: Buffer.alloc(MIB + 1, 32) });
  expect(huge.status === 413 && huge.json.error === "A request's body can be at most 1 MiB", "a JSON body past 1 MiB is 413");
  const notJson = await raw("POST", uploadsPath(room), { cookie: state.maya, body: Buffer.from("{nope") });
  expect(notJson.status === 422 && notJson.json.error === "Expected a JSON object", "unreadable JSON is not an object");
});

await check("a one-part upload posts its message with the stored file, to the room and in the answer", async () => {
  const maya = await roomSocket(state.rooms.Launch, state.maya);
  const sam = await roomSocket(state.rooms.Launch, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const bytes = png(640, 480, 200);
  const clientMessageId = `check-${randomBytes(5).toString("hex")}`;
  const started = await startUpload(state.rooms.Launch, state.maya, { name: "photo.png", type: "application/octet-stream", size: bytes.length, clientMessageId });
  const done = await putPart(state.rooms.Launch, state.maya, started.json.id, 1, bytes);
  expectStatus(done, 201);
  const message = done.json;
  expect(message.body === "" && message.plainText === "photo.png" && message.clientMessageId === clientMessageId && message.mentions.length === 0 && message.parentId === undefined, "a file's message has no body, and its name as plain text");
  const file = message.attachment;
  expect(file.id === started.json.id && file.name === "photo.png" && file.byteSize === 200 && file.contentType === "image/png", "the stored file, identified by its bytes");
  expect(file.width === 640 && file.height === 480, "its size, from the header");
  expect(file.url.startsWith(`/files/${file.id}/`) && file.url.endsWith("/photo.png") && file.downloadUrl === `${file.url}?disposition=attachment` && file.previewUrl === undefined, "its addresses, with no preview");
  expect(/^\/files\/[0-9a-z]{28}\/[A-Za-z0-9_-]{22}\/photo\.png$/.test(file.url), "the address is key, a 22-character signature, then the name");
  const broadcast = await sam.next((frame) => frame.type === "message.created" && frame.message.id === message.id, "message.created");
  expect(broadcast.message.attachment.url === file.url, "the room hears of it");
  const again = await putPart(state.rooms.Launch, state.maya, started.json.id, 1, bytes);
  expect(again.status === 200 && again.json.id === message.id, "the part again is 200 with the same message");
  const check1 = await putPart(state.rooms.Launch, state.maya, started.json.id, 1, Buffer.alloc(0), { chunked: true });
  expect(check1.status === 200, "a posted upload answers before it looks at the part");
  state.photo = { message, file };
});

await check("a multi-part upload takes parts in any order, checks each, and posts when the last arrives", async () => {
  const room = state.rooms.Launch;
  const size = 2 * 10 * MIB + 100;
  const pdf = Buffer.alloc(size, 0x61);
  pdf.write("%PDF-1.7\n", 0, "latin1");
  pdf.write("TAIL", size - 4, "latin1");
  const started = await startUpload(room, state.maya, newFile("big report.pdf", size, { type: "application/pdf" }));
  expect(started.json.parts === 3, "three parts");
  const id = started.json.id;
  const part = (n) => pdf.subarray((n - 1) * 10 * MIB, Math.min(n * 10 * MIB, size));
  const early = await putPart(room, state.maya, id, 3, part(3));
  expect(early.status === 409 && early.json.error === "The first part goes first", "a later part before the first is 409");
  const short = await putPart(room, state.maya, id, 1, part(1).subarray(0, 5));
  expect(short.status === 400 && short.json.error === `Part 1 is ${10 * MIB} bytes`, "a short part is 400");
  const long = await putPart(room, state.maya, id, 3, Buffer.alloc(101));
  expect(long.status === 413 && long.json.error === "Part 3 is 100 bytes", "a long part is 413");
  const unsized = await putPart(room, state.maya, id, 1, part(1), { chunked: true });
  expect(unsized.status === 411 && unsized.json.error === "A part needs its Content-Length", "no Content-Length is 411");
  expectStatus(await putPart(room, state.maya, id, 4, part(3)), 404);
  expectStatus(await putPart(room, state.maya, "doesnotexist", 1, part(1)), 404);
  const theirs = await putPart(room, state.sam, id, 1, part(1));
  expect(theirs.status === 404 && theirs.json.error === "Upload not found", "someone else's upload is not found");
  expectStatus(await putPart(room, undefined, id, 1, part(1)), 401);
  expectStatus(await raw("PUT", `${uploadsPath(room)}/${id}/parts/0`, { cookie: state.maya, body: part(1) }), 404);
  expectStatus(await putPart(room, state.maya, id, 1, part(1)), 204);
  expectStatus(await putPart(room, state.maya, id, 1, part(1)), 204);
  expectStatus(await putPart(room, state.maya, id, 3, part(3)), 204);
  const last = await putPart(room, state.maya, id, 2, part(2));
  expectStatus(last, 201);
  expect(last.json.attachment.contentType === "application/pdf" && last.json.attachment.byteSize === size && last.json.attachment.previewUrl === undefined, "identified from the first part");
  const repeat = await putPart(room, state.maya, id, 2, part(2));
  expect(repeat.status === 200 && repeat.json.id === last.json.id, "the last part again is 200");
  const served = await raw("GET", last.json.attachment.url);
  expect(served.status === 200 && served.bytes.length === size && served.bytes.equals(pdf), "the file is served whole, parts joined in order");
});

await check("a preview is kept for an image, checked on its way in, and is refused once the file is posted", async () => {
  const room = state.rooms.Launch;
  const big = png(2000, 1500, 300);
  const started = await startUpload(room, state.maya, newFile("wide.png", big.length));
  const id = started.json.id;
  const previewTo = (bytes, options = {}) => raw("PUT", `${uploadsPath(room)}/${id}/preview`, { cookie: state.maya, body: bytes, ...options });
  expectStatus(await raw("PUT", `${uploadsPath(room)}/doesnotexist/preview`, { cookie: state.maya, body: png(10, 10) }), 404);
  const unsized = await previewTo(png(10, 10), { chunked: true });
  expect(unsized.status === 411 && unsized.json.error === "A preview needs its Content-Length", "no Content-Length is 411");
  const heavy = await previewTo(Buffer.alloc(5 * MIB + 1));
  expect(heavy.status === 413 && heavy.json.error === "A preview is at most 5 MiB", "past 5 MiB is 413");
  const text = await previewTo(Buffer.from("not an image"));
  expect(text.status === 415 && text.json.error === "A preview is a WebP, JPEG or PNG image", "other bytes are 415");
  const gif = await previewTo(Buffer.concat([Buffer.from("GIF89a"), Buffer.alloc(20)]));
  expect(gif.status === 415, "a GIF is not a preview");
  const wide = await previewTo(png(1201, 800));
  expect(wide.status === 422 && wide.json.error === "A preview fits within 1200×800", "too wide is 422");
  expectStatus(await previewTo(png(800, 801)), 422);
  expectStatus(await previewTo(png(1200, 800, 100)), 204);
  expectStatus(await previewTo(png(600, 400, 150)), 204);
  const done = await putPart(room, state.maya, id, 1, big);
  expectStatus(done, 201);
  const file = done.json.attachment;
  expect(file.width === 2000 && file.height === 1500, "the file's own size, not the preview's");
  expect(/^\/previews\/[0-9a-z]{28}\/[A-Za-z0-9_-]{22}\/wide\.png$/.test(file.previewUrl), "a preview address, named for the preview's type");
  const shown = await raw("GET", file.previewUrl);
  expect(shown.status === 200 && shown.bytes.length === 150 && shown.headers["content-type"] === "image/png", "the later preview replaced the earlier");
  const late = await previewTo(png(10, 10));
  expect(late.status === 409 && late.json.error === "The file is posted already", "after the post it is 409");
  const pdf = await uploadWhole(room, state.maya, "doc.pdf", Buffer.concat([Buffer.from("%PDF-1.4\n"), Buffer.alloc(40)]));
  const unseen = await startUpload(room, state.maya, newFile("doc2.pdf", 20));
  expectStatus(await raw("PUT", `${uploadsPath(room)}/${unseen.json.id}/preview`, { cookie: state.maya, body: png(10, 10) }), 204);
  const posted = await putPart(room, state.maya, unseen.json.id, 1, Buffer.concat([Buffer.from("%PDF-1.4\n"), Buffer.alloc(11)]));
  expect(posted.json.attachment.previewUrl === undefined && pdf.message.attachment.previewUrl === undefined, "a type that isn't previewed drops the preview");
});

/// A request whose body goes in two goes: the first half now, the rest when `finish()` is called, which answers like `raw`.
function inTwoGoes(method, pathAndQuery, { cookie, body }) {
  const url = new URL(origin);
  const half = Math.floor(body.length / 2);
  let settle;
  const answered = new Promise((resolve, reject) => (settle = { resolve, reject }));
  const req = http.request(
    { host: url.hostname, port: url.port, path: pathAndQuery, method, headers: { Cookie: cookie, "Content-Length": body.length } },
    (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const bytes = Buffer.concat(chunks);
        let json = null;
        try {
          json = JSON.parse(bytes.toString("utf8"));
        } catch {}
        settle.resolve({ status: res.statusCode, json });
      });
    },
  );
  req.on("error", (error) => settle.reject(error));
  req.write(body.subarray(0, half));
  return { finish: () => (req.end(body.subarray(half)), answered) };
}

/// The server has read the first half by the time it answers a request made after it was sent (its handler runs
/// as far as reading the body as soon as the headers arrive), so this is the point to change things.
const afterHeaders = async (cookie) => expectStatus(await request("GET", "/api/me", { cookie }), 200);

await check("a part and a preview are checked again once they have arrived: sign-out, and a post by another request", async () => {
  const room = state.rooms.Launch;
  const cookie = await signIn(emails.tomas);
  const started = await startUpload(room, cookie, newFile("late.png", 200));
  expectStatus(started, 201);
  const id = started.json.id;
  const target = (suffix) => `${uploadsPath(room)}/${id}/${suffix}`;

  // A preview whose sender signs out while it arrives is refused, and kept nowhere.
  const preview = inTwoGoes("PUT", target("preview"), { cookie, body: png(10, 10) });
  await afterHeaders(cookie);
  expectStatus(await request("DELETE", "/api/session", { cookie }), 204);
  expectStatus(await preview.finish(), 401);

  // A part likewise, and the upload is still there to be sent again from a new session.
  const second = await signIn(emails.tomas);
  const bytes = png(10, 10, 200);
  const part = inTwoGoes("PUT", target("parts/1"), { cookie: second, body: bytes });
  await afterHeaders(second);
  expectStatus(await request("DELETE", "/api/session", { cookie: second }), 204);
  expectStatus(await part.finish(), 401);
  const third = await signIn(emails.tomas);
  const slowPreview = inTwoGoes("PUT", target("preview"), { cookie: third, body: png(10, 10) });
  await afterHeaders(third);
  // Another request posts the file while the preview is still arriving: the preview comes too late.
  const posted = await putPart(room, third, id, 1, bytes);
  expectStatus(posted, 201);
  const late = await slowPreview.finish();
  expect(late.status === 409 && late.json.error === "The file is posted already", `a preview that arrives after the post is 409, got ${late.status}`);
  expect(posted.json.attachment.previewUrl === undefined, "and the message shows no preview");

  // A part that arrives after another request posted the file answers that message, as a part sent after the post does.
  const twin = await startUpload(room, third, newFile("twin.png", 200));
  const slowPart = inTwoGoes("PUT", `${uploadsPath(room)}/${twin.json.id}/parts/1`, { cookie: third, body: bytes });
  await afterHeaders(third);
  const first = await putPart(room, third, twin.json.id, 1, bytes);
  expectStatus(first, 201);
  const again = await slowPart.finish();
  expect(again.status === 200 && again.json.id === first.json.id, `a part that arrives after the post is 200 with its message, got ${again.status}`);
});

await check("cards the server's parsers would drop are dropped, and a file name loses its edges", async () => {
  const { keptCards } = await import("./cards.mjs");
  const { sanitizedFilename } = await import("./files.mjs");
  // packages/protocol/src/cards.ts: rich text over MAX_MESSAGE_HTML_LENGTH (100 000) is not a part, a field, a cell or a pretext.
  const html = (length) => "x".repeat(length);
  const kept = (parts, extra = {}) => keptCards([{ source: "attachment", ...extra, parts: [{ kind: "title", text: "T" }, ...parts] }]).cards[0];
  expect(kept([{ kind: "text", html: html(100_000) }]).parts.length === 2, "text of exactly the limit is kept");
  expect(kept([{ kind: "text", html: html(100_001) }]).parts.length === 1, "text over the limit is dropped");
  expect(kept([{ kind: "fields", fields: [{ title: "A", html: html(100_001) }] }]).parts[1].fields[0].html === "", "a field's text over the limit is dropped");
  expect(kept([]).pretext === undefined && kept([], { pretext: html(100_001) }).pretext === undefined, "a pretext over the limit is dropped");
  expect(kept([], { pretext: html(100_000) }).pretext === html(100_000), "a pretext at the limit is kept");
  const table = kept([{ kind: "table", rows: [[html(100_001), "b"]] }]).parts[1];
  expect(table.rows[0][0] === "", "a cell over the limit is empty");
  // apps/worker/src/files/filename.ts: Ruby's strip first (NUL and ASCII whitespace), then hyphens for the unsafe characters.
  expect(sanitizedFilename(" \t\0 a b.txt \n\0") === "a b.txt", "the name's edges are stripped");
  expect(sanitizedFilename("a\tb/c.txt") === "a-b-c.txt", "unsafe characters inside become hyphens");
  expect(sanitizedFilename(" a.txt") === " a.txt", "Unicode spaces stay");
});

await check("a file name's edges are stripped in the posted message too", async () => {
  const done = await uploadWhole(state.rooms.Launch, state.maya, "  padded name.txt\n", Buffer.from("hello"));
  expect(done.message.attachment.name === "padded name.txt", `got ${JSON.stringify(done.message.attachment.name)}`);
});

await check("a reply upload goes into its thread, and alsoSend puts it in the room too", async () => {
  const room = state.rooms.Support;
  const maya = await roomSocket(room, state.maya);
  const sam = await roomSocket(room, state.sam);
  await maya.nextOfType("welcome");
  await sam.nextOfType("welcome");
  const parent = await post(maya, "<p>Files in a thread</p>");
  const quiet = await uploadWhole(room, state.sam, "quiet.png", png(10, 10), { parentId: parent.id });
  expect(quiet.message.parentId === parent.id && quiet.message.alsoSent === false && quiet.message.parentText === "Files in a thread", "a reply file");
  const created = await maya.next((frame) => frame.type === "message.created" && frame.message.id === quiet.message.id, "message.created");
  const updated = await maya.nextOfType("message.updated");
  expect(created.message.attachment.name === "quiet.png" && updated.message.id === parent.id && updated.message.thread.count === 1 && updated.seq === created.seq + 1, "the reply, then its parent updated");
  const loud = await uploadWhole(room, state.sam, "loud.png", png(10, 10), { parentId: parent.id, alsoSend: true });
  expect(loud.message.alsoSent === true, "alsoSend: true");
  const lone = await uploadWhole(room, state.sam, "lone.png", png(10, 10), { alsoSend: true });
  expect(lone.message.parentId === undefined && lone.message.alsoSent === undefined, "alsoSend without a parent is ignored");
  const fresh = await roomSocket(room, state.leo);
  const ids = (await fresh.nextOfType("welcome")).messages.map((message) => message.id);
  expect(ids.includes(loud.message.id) && ids.includes(lone.message.id) && !ids.includes(quiet.message.id), "the timeline has the also-sent file, not the thread-only one");
  maya.send({ type: "thread.open", parentId: parent.id });
  expect((await maya.nextOfType("thread.opened")).messages.length === 2, "the thread has both");
});

await check("a file is served by its address with no cookie, as inline or attachment by what it is", async () => {
  const { file, message } = state.photo;
  const shown = await raw("GET", file.url);
  expect(shown.status === 200 && shown.bytes.length === 200 && shown.headers["content-type"] === "image/png", "the bytes and type");
  expect(shown.headers["content-disposition"] === `inline; filename="photo.png"; filename*=UTF-8''photo.png`, `inline disposition: ${shown.headers["content-disposition"]}`);
  expect(shown.headers["cache-control"] === "max-age=3600, public" && shown.headers["content-length"] === "200" && shown.headers["last-modified"], "caching and length headers");
  expect(shown.headers["set-cookie"] === undefined, "no cookie asked for or set");
  const download = await raw("GET", file.downloadUrl);
  expect(download.headers["content-disposition"].startsWith("attachment; filename="), "downloadUrl is an attachment");
  const last = await raw("GET", `${file.url}?disposition=attachment&disposition=inline`);
  expect(last.headers["content-disposition"].startsWith("inline;"), "the last disposition wins");
  const named = await uploadWhole(state.rooms.Launch, state.maya, "Résumé v2/final:draft.png", png(5, 5, 40));
  const stored = named.message.attachment;
  expect(stored.name === "Résumé v2-final-draft.png", `the name is sanitised: ${stored.name}`);
  expect(stored.url.endsWith("/R%C3%A9sum%C3%A9%20v2-final-draft.png"), `the address escapes the name: ${stored.url}`);
  const unicode = await raw("GET", stored.url);
  expect(unicode.headers["content-disposition"] === `inline; filename="Resume v2-final-draft.png"; filename*=UTF-8''R%C3%A9sum%C3%A9%20v2-final-draft.png`, `a name with accents: ${unicode.headers["content-disposition"]}`);
  const html = await uploadWhole(state.rooms.Launch, state.maya, "page.html", Buffer.from("<script>alert(1)</script>"));
  const page = await raw("GET", html.message.attachment.url);
  expect(page.headers["content-type"] === "application/octet-stream" && page.headers["content-disposition"].startsWith("attachment;"), "HTML is served as bytes, never shown");
  const svg = await uploadWhole(state.rooms.Launch, state.maya, "drawing.svg", Buffer.from("<svg xmlns='http://www.w3.org/2000/svg'/>"));
  const drawing = await raw("GET", svg.message.attachment.url + "?disposition=inline");
  expect(svg.message.attachment.contentType === "image/svg+xml" && drawing.headers["content-type"] === "application/octet-stream" && drawing.headers["content-disposition"].startsWith("attachment;"), "SVG is served as bytes even when asked inline");
  const text = await uploadWhole(state.rooms.Launch, state.maya, "notes.txt", Buffer.from("hello"), { type: "text/plain; charset=utf-8" });
  const notes = await raw("GET", text.message.attachment.url);
  expect(text.message.attachment.contentType === "text/plain" && notes.headers["content-disposition"].startsWith("attachment;"), "text is always a download");
  const empty = await uploadWhole(state.rooms.Launch, state.maya, "empty.bin", Buffer.alloc(0));
  const nothing = await raw("GET", empty.message.attachment.url);
  expect(nothing.status === 200 && nothing.bytes.length === 0 && nothing.headers["content-length"] === "0", "an empty file is served empty");
  expect(message.attachment.contentType === "image/png", "sniffed over the declared type");
});

await check("a bad key, signature or method is an empty 404 as HTML", async () => {
  const { file } = state.photo;
  const [, , key, signature, name] = file.url.split("/");
  const bad = [
    `/files/${key}/${"A".repeat(22)}/${name}`,
    `/files/${key}/${signature.slice(0, 21)}/${name}`,
    `/files/${"0".repeat(28)}/${signature}/${name}`,
    `/files/${key.slice(1)}/${signature}/${name}`,
    `/previews/${key}/${signature}/${name}`,
  ];
  for (const path of bad) {
    const res = await raw("GET", path);
    expect(res.status === 404 && res.bytes.length === 0 && res.headers["content-type"] === "text/html", `${path.slice(0, 20)}… should be an empty 404`);
  }
  const write = await raw("POST", file.url, { body: Buffer.alloc(0) });
  expect(write.status === 404 && write.headers["content-type"] === "text/html", "a write is 404");
  expectStatus(await raw("DELETE", file.url), 404);
  const other = await raw("GET", `/files/${key}/${signature}/another-name.png`);
  expect(other.status === 200, "the name in the address is only for show");
});

await check("ranges, HEAD and If-Modified-Since are answered as Rack does", async () => {
  const bytes = Buffer.from("0123456789abcdefghij");
  const { message } = await uploadWhole(state.rooms.Launch, state.maya, "ranged.png", Buffer.concat([png(2, 2, 33), bytes]).subarray(0, 53));
  const { url } = message.attachment;
  const whole = (await raw("GET", url)).bytes;
  expect(whole.length === 53, "53 bytes");
  const one = await raw("GET", url, { headers: { Range: "bytes=2-5" } });
  expect(one.status === 206 && one.headers["content-range"] === "bytes 2-5/53" && one.headers["content-length"] === "4" && one.bytes.equals(whole.subarray(2, 6)), "one range");
  const suffix = await raw("GET", url, { headers: { Range: "bytes=-5" } });
  expect(suffix.status === 206 && suffix.headers["content-range"] === "bytes 48-52/53" && suffix.bytes.equals(whole.subarray(48)), "a suffix range");
  const open = await raw("GET", url, { headers: { Range: "bytes=50-" } });
  expect(open.status === 206 && open.headers["content-range"] === "bytes 50-52/53", "an open range");
  const clamped = await raw("GET", url, { headers: { Range: "bytes=50-9999" } });
  expect(clamped.status === 206 && clamped.headers["content-range"] === "bytes 50-52/53", "an end past the file is clamped");
  const multi = await raw("GET", url, { headers: { Range: "bytes=0-1, 10-12" } });
  const boundary = /^multipart\/byteranges; boundary=([0-9a-f]{32})$/.exec(multi.headers["content-type"])?.[1];
  expect(multi.status === 206 && boundary, "several ranges are multipart/byteranges");
  const expected = `\r\n--${boundary}\r\nContent-Type: image/png\r\nContent-Range: bytes 0-1/53\r\n\r\n` + whole.subarray(0, 2).toString("latin1") +
    `\r\n--${boundary}\r\nContent-Type: image/png\r\nContent-Range: bytes 10-12/53\r\n\r\n` + whole.subarray(10, 13).toString("latin1") + `\r\n--${boundary}--\r\n`;
  expect(multi.bytes.toString("latin1") === expected && multi.headers["content-length"] === String(expected.length), "the multipart body");
  const gone = await raw("GET", url, { headers: { Range: "bytes=100-200" } });
  expect(gone.status === 416 && gone.text === "Byte range unsatisfiable\n" && gone.headers["content-range"] === "bytes */53", "past the end is 416");
  const backwards = await raw("GET", url, { headers: { Range: "bytes=5-2" } });
  expect(backwards.status === 200 && backwards.bytes.length === 53, "a backwards range is ignored");
  const overlap = await raw("GET", url, { headers: { Range: "bytes=0-40,0-40" } });
  expect(overlap.status === 416, "ranges adding up to more than the file are 416");
  const head = await raw("HEAD", url);
  expect(head.status === 200 && head.bytes.length === 0 && head.headers["content-length"] === "53" && head.headers["content-type"] === "image/png", "HEAD has the headers and no body");
  const headRange = await raw("HEAD", url, { headers: { Range: "bytes=0-3" } });
  expect(headRange.status === 206 && headRange.bytes.length === 0 && headRange.headers["content-length"] === "4", "HEAD with a range");
  const modified = head.headers["last-modified"];
  const same = await raw("GET", url, { headers: { "If-Modified-Since": modified } });
  expect(same.status === 304 && same.bytes.length === 0 && same.headers["cache-control"] === "max-age=3600, public" && same.headers["last-modified"] === undefined, "an exact If-Modified-Since is 304");
  const later = await raw("GET", url, { headers: { "If-Modified-Since": new Date(Date.parse(modified) + 86_400_000).toUTCString() } });
  expect(later.status === 304 && later.headers["content-type"] === undefined, "a later date is 304 without a type");
  const earlier = await raw("GET", url, { headers: { "If-Modified-Since": new Date(Date.parse(modified) - 86_400_000).toUTCString() } });
  expect(earlier.status === 200, "an earlier date gets the file");
});

await check("the seeded file in Design is a signed address that serves its picture as a download", async () => {
  const maya = await roomSocket(state.rooms.Design, state.maya);
  const welcome = await maya.nextOfType("welcome");
  const file = welcome.messages.find((message) => message.attachment)?.attachment;
  expect(file && file.name === "palette.svg" && file.contentType === "image/svg+xml" && /^[0-9a-z]{28}$/.test(file.id), "the seeded StoredFile");
  expect(/^\/files\/[0-9a-z]{28}\/[A-Za-z0-9_-]{22}\/palette\.svg$/.test(file.url) && file.downloadUrl === `${file.url}?disposition=attachment` && file.previewUrl === undefined, "its addresses");
  const served = await raw("GET", file.url);
  expect(served.status === 200 && served.text.startsWith("<svg") && served.bytes.length === file.byteSize, "its bytes");
  expect(served.headers["content-type"] === "application/octet-stream" && served.headers["content-disposition"].startsWith("attachment;"), "SVG is served as a download");
});

// Bot cards. The stand-in stores them already translated; the Slack translator and webhook are not ported.

const cardKinds = (message) => message.cards.flatMap((card) => card.parts.map((part) => part.kind)).join();
const engineeringWelcome = async (cookie) => {
  const socket = await roomSocket(state.rooms.Engineering, cookie);
  const welcome = await socket.nextOfType("welcome");
  // Earlier checks post enough into Engineering to push the seeds past the newest page, so page back to the first card.
  let messages = welcome.messages;
  let more = welcome.hasMore;
  for (let pages = 0; more && pages < 20 && !messages.some((message) => message.plainText.startsWith("Deployed message-api v2.4.2 to production")); pages += 1) {
    socket.send({ type: "history.before", before: messages[0].id });
    const page = await socket.nextOfType("history");
    messages = [...page.messages, ...messages];
    more = page.hasMore;
  }
  return { socket, welcome: { ...welcome, messages } };
};

await check("Engineering's history ends with seven card messages in order, carrying every kind of part", async () => {
  const { welcome } = await engineeringWelcome(state.maya);
  const start = welcome.messages.findIndex((message) => message.plainText.startsWith("Deployed message-api v2.4.2 to production"));
  expect(start >= 0, "the first card message is in the newest page");
  const seven = welcome.messages.slice(start, start + 7);
  expect(seven.length === 7 && seven.every((message) => Array.isArray(message.cards) && message.cards.length > 0), "seven card messages in a row");
  const [c1, c2, c3, c4, c5, c6, c7] = seven;
  const names = seven.map((message) => message.creator.name).join();
  expect(names === "Deploy Bot,Uptime,Uptime,Deploy Bot,Deploy Bot,Deploy Bot,Uptime", `the bots, got ${names}`);
  expect(seven.map((message) => message.body).join("|") === "|<p>Message API errors are up</p>|<p>Message API errors are back to normal</p>||||<p>Certificate for status.fernwood.example expires in 9 days</p>", "the bodies");
  expect(cardKinds(c1) === "header,section,section,context" && c1.cards[0].source === "blocks", "C1 parts");
  expect(cardKinds(c2) === "title,text,fields,buttons,footer" && c2.cards[0].source === "attachment" && c2.cards[0].color === "danger", "C2 parts");
  expect(cardKinds(c3) === "title,text,fields,footer" && c3.cards[0].color === "good", "C3 parts");
  expect(cardKinds(c4) === "header,section,table,divider,context", "C4 parts");
  expect(cardKinds(c5) === "author,title,text,fields,image,footer" && c5.cards[0].color === "#7c3aed" && c5.cards[0].pretext === "<p>Pipeline <strong>#1042</strong> finished</p>" && c5.cards[0].thumb.alt === "web", "C5 parts");
  expect(cardKinds(c6) === "section,tiles" && c6.cards[0].parts[1].tiles.length === 3, "C6 parts");
  expect(cardKinds(c7) === "title,text,footer" && c7.cards[0].color === "warning", "C7 parts");
  const all = new Set(seven.flatMap((message) => message.cards.flatMap((card) => card.parts.map((part) => part.kind))));
  for (const kind of ["author", "title", "header", "text", "section", "fields", "image", "context", "divider", "buttons", "table", "tiles", "footer"]) expect(all.has(kind), `no ${kind} part`);
  const times = seven.map((message) => Date.parse(message.createdAt));
  expect(times.every((time, index) => index === 0 || time > times[index - 1]), "oldest first");
  const ageHours = (message) => (Date.now() - Date.parse(message.createdAt)) / 3_600_000;
  expect(Math.abs(ageHours(c1) - 26) < 0.5 && Math.abs(ageHours(c4) - 6) < 0.5 && Math.abs(ageHours(c7) - 1.5) < 0.5, "seeded 26 h, 6 h and 90 min ago");
  expect(c2.cards[0].parts[4].at === Math.floor(Date.parse(c2.createdAt) / 1000), "a footer's time is the message's, in seconds");
  expect(c5.cards[0].parts.find((part) => part.kind === "fields").fields.map((field) => field.short).join() === "true,true,false", "C5's notes field is not short");
  const image = c5.cards[0].parts.find((part) => part.kind === "image");
  expect(image.image.alt === "" && image.title === "Coverage by package" && image.image.url.endsWith("/card-media/chart.png") && /^http:\/\/[^/]+\.localhost:\d+\//.test(image.image.url), "C5's image");
  expect(c6.cards[0].parts[1].tiles[0].buttons.map((button) => button.style ?? "default").join() === "primary,default,danger" && c6.cards[0].parts[1].tiles[2].buttons === undefined, "C6's buttons");
  const table = c4.cards[0].parts[2];
  expect(table.rows.length === 4 && table.rows.every((row) => row.length === 3) && table.columns.map((column) => `${column.align}:${column.wrap}`).join() === "left:true,right:false,right:false", "C4's table");
  expect(c4.cards[0].parts[4].items[0].image.alt === "Maya Chen", "C4's context image");
});

await check("a message without cards has no cards key, and a card message's plain text is its text then its cards, a line per part", async () => {
  const { welcome } = await engineeringWelcome(state.maya);
  const plain = welcome.messages.filter((message) => !message.cards);
  expect(plain.length > 0 && plain.every((message) => !("cards" in message)), "no cards key, not null and not []");
  const find = (start) => welcome.messages.find((message) => message.plainText.startsWith(start));
  expect(
    find("Deployed message-api v2.4.2").plainText ===
      "Deployed message-api v2.4.2 to production\nSmoke tests passed in 2m 14s. Nothing to roll back.\nRelease notes\nCommit\n8a1969f\nStarted by\nMaya Chen\nTook 4m 31s · Deploy #1874",
    "C1's plain text",
  );
  expect(
    find("Nightly deploy summary").plainText ===
      "Nightly deploy summary\n3 services are live in production.\nRelease notes\nService | Took | Errors\nmessage-api | 1m 12s | 0\nweb | 48s | 0\nworkers | 2m 3s | 2\nStarted by Maya Chen",
    "C4's plain text",
  );
  expect(
    find("Message API errors are up\n[FIRING]").plainText ===
      "Message API errors are up\n[FIRING] HighErrorRate message-api\n5xx rate is 4.2% over the last 5 minutes (threshold 1%).\nSeverity\ncritical\nRegion\nfra1\nRunbook\nUptime",
    "C2's plain text",
  );
});

await check("card images are PNGs that need no session, and an unknown name is 404", async () => {
  const mediaHost = `media.localhost:${new URL(origin).port}`;
  for (const [name, width, height] of [["avatar", 64, 64], ["icon", 64, 64], ["thumb", 150, 150], ["chart", 720, 400], ["hero-1", 640, 320], ["hero-2", 640, 320]]) {
    const res = await raw("GET", `/card-media/${name}.png`, { headers: { Host: mediaHost } });
    expect(res.status === 200 && res.headers["content-type"] === "image/png", `${name} is image/png`);
    expect(res.bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), `${name} has the PNG signature`);
    expect(res.bytes.readUInt32BE(16) === width && res.bytes.readUInt32BE(20) === height, `${name} is ${width}×${height}`);
  }
  expect((await raw("GET", "/card-media/nothing.png")).status === 404, "an unknown name is 404");
  expect((await raw("GET", "/card-media/avatar.jpg")).status === 404, "only .png");
  expect((await raw("HEAD", "/card-media/avatar.png")).status === 200, "HEAD is answered");
});

await check("search finds the alert cards by their text", async () => {
  const res = await request("GET", `/api/searches?q=${encodeURIComponent("HighErrorRate")}`, { cookie: state.maya });
  expectStatus(res, 200);
  const titles = res.json.matches.map((match) => match.message.plainText.split("\n").find((line) => line.includes("HighErrorRate")));
  expect(titles.length === 2 && titles.some((line) => line.startsWith("[FIRING]")) && titles.some((line) => line.startsWith("[RESOLVED]")), `C2 and C3, got ${titles.length}`);
  expect(res.json.matches.every((match) => Array.isArray(match.message.cards)), "the matches carry their cards");
});

await check("a person's edit of a card message is refused, a boost and an administrator's delete work", async () => {
  const { socket: maya, welcome } = await engineeringWelcome(state.maya);
  const c1 = welcome.messages.find((message) => message.plainText.startsWith("Deployed message-api v2.4.2"));
  maya.send({ type: "message.update", messageId: c1.id, body: "<p>Mine now</p>" });
  const refusal = await maya.nextOfType("error");
  expect(refusal.message === "Messages with cards can't be edited." && refusal.failed === "message.update" && !("clientMessageId" in refusal), `the refusal frame, got ${JSON.stringify(refusal)}`);
  const leo = await roomSocket(state.rooms.Engineering, state.leo);
  await leo.nextOfType("welcome");
  leo.send({ type: "message.update", messageId: c1.id, body: "<p>Mine now</p>" });
  expect((await leo.nextOfType("error")).message === "You can only edit your own messages", "someone else's is refused for the usual reason first");
  expect(await maya.quiet((frame) => frame.type === "message.updated"), "nothing changed");
  maya.send({ type: "boost.create", messageId: c1.id, content: "🚀" });
  expect((await maya.nextOfType("boost.created")).boost.content === "🚀", "a card message takes a boost");
  maya.send({ type: "message.delete", messageId: c1.id });
  expect((await maya.nextOfType("message.deleted")).messageId === c1.id, "an administrator deletes a bot's card message");
});

await check("saying deploy in Engineering brings a card message from Deploy Bot", async () => {
  const { socket: maya } = await engineeringWelcome(state.maya);
  maya.send({ type: "message.create", clientMessageId: `check-${randomBytes(4).toString("hex")}`, body: "<p>Time to DEPLOY?</p>" });
  const bot = await maya.next((frame) => frame.type === "message.created" && frame.message.creator.name === "Deploy Bot", "the deploy card", 10_000);
  expect(bot.message.body === "" && cardKinds(bot.message) === "header,section,section,context" && bot.message.cards[0].parts[0].text === "Deployed message-api v2.4.3 to production", "the card");
  expect(bot.message.plainText.startsWith("Deployed message-api v2.4.3 to production\n"), "its plain text");
  maya.send({ type: "message.delete", messageId: bot.message.id });
  expect((await maya.nextOfType("message.deleted")).messageId === bot.message.id, "an administrator deletes the scripted card message");
});

await check("saying alert in Engineering brings Uptime's alert, which Uptime then replaces with plain text", async () => {
  const { socket: maya } = await engineeringWelcome(state.maya);
  const watcher = await roomSocket(state.rooms.Engineering, state.leo);
  await watcher.nextOfType("welcome");
  maya.send({ type: "message.create", clientMessageId: `check-${randomBytes(4).toString("hex")}`, body: "<p>Is that an Alert?</p>" });
  const created = await maya.next((frame) => frame.type === "message.created" && frame.message.creator.name === "Uptime", "the alert", 10_000);
  expect(created.message.body === "<p>Message API errors are up</p>" && cardKinds(created.message) === "title,text,fields,buttons,footer" && created.message.cards[0].color === "danger", "the alert card");
  for (const socket of [maya, watcher]) {
    const updated = await socket.next((frame) => frame.type === "message.updated" && frame.message.id === created.message.id && !("cards" in frame.message), "the replacement without cards", 15_000);
    expect(updated.message.body === "<p>Message API errors are back to normal</p>" && updated.message.plainText === "Message API errors are back to normal", "its new text");
    expect(updated.message.editedAt !== null && updated.message.updatedAt === updated.message.editedAt, "it is marked edited");
  }
  maya.send({ type: "message.delete", messageId: created.message.id });
  await maya.nextOfType("message.deleted");
});

// The keyed bot API

const botKeys = {};
const botMessages = () => `/rooms/${state.rooms.Engineering}/${botKeys.deploy}/messages`;
const multipart = (parts) => {
  const boundary = `check-${randomBytes(6).toString("hex")}`;
  const chunks = parts.flatMap(({ name, filename, type, bytes }) => [
    Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"${filename === undefined ? "" : `; filename="${filename}"`}\r\n${type ? `Content-Type: ${type}\r\n` : ""}\r\n`),
    bytes,
    Buffer.from("\r\n"),
  ]);
  return { headers: { "Content-Type": `multipart/form-data; boundary=${boundary}` }, body: Buffer.concat([...chunks, Buffer.from(`--${boundary}--\r\n`)]) };
};
const permalinkId = (res) => /\/rooms\/[^/]+\/@([^/?#]+)$/.exec(res.headers.location ?? "")?.[1];

await check("an administrator lists the bots with their keys and rooms, and a member can't", async () => {
  const res = await request("GET", "/api/account/bots", { cookie: state.maya });
  expectStatus(res, 200);
  const deploy = res.json.bots.find((bot) => bot.name === "Deploy Bot");
  expect(deploy && /^[^-]+-[a-z0-9]{12}$/.test(deploy.key) && deploy.role === "bot", "Deploy Bot has a key");
  expect(deploy.rooms.some((room) => room.id === state.rooms.Engineering && room.name === "Engineering"), "it is in Engineering");
  botKeys.deploy = deploy.key;
  expectStatus(await request("GET", "/api/account/bots", { cookie: state.leo }), 403);
  expectStatus(await request("GET", "/api/account/bots"), 401);
});

await check("a bot posts markup to a room with only its key, and the answer's Location is the message's permalink", async () => {
  const watcher = await roomSocket(state.rooms.Engineering, state.leo);
  await watcher.nextOfType("welcome");
  const res = await raw("POST", botMessages(), { headers: { "Content-Type": "text/plain" }, body: Buffer.from("Deploy <b>finished</b>") });
  expectStatus(res, 201);
  const id = permalinkId(res);
  expect(id && res.headers.location.startsWith(`${origin}/rooms/${state.rooms.Engineering}/@`), "a permalink");
  expect(res.bytes.toString("utf8") === "null" || res.bytes.length === 0, "no body worth reading");
  const created = await watcher.next((frame) => frame.type === "message.created" && frame.message.id === id, "the message");
  expect(created.message.creator.name === "Deploy Bot" && created.message.body.includes("<b>finished</b>"), "posted as the bot, markup kept");
});

await check("a bot posts a file as a multipart attachment", async () => {
  const bytes = Buffer.from("build log line 1\nbuild log line 2\n");
  const form = multipart([{ name: "attachment", filename: "build.log", type: "text/plain", bytes }]);
  const res = await raw("POST", botMessages(), form);
  expectStatus(res, 201);
  const id = permalinkId(res);
  expect(id, "a permalink");
  const welcome = await (async () => {
    const socket = await roomSocket(state.rooms.Engineering, state.leo, `visible=1&protocol=4&around=${id}`);
    return socket.nextOfType("welcome");
  })();
  const message = welcome.messages.find((candidate) => candidate.id === id);
  expect(message?.attachment?.name === "build.log" && message.attachment.byteSize === bytes.length, "the attachment");
  const served = await raw("GET", message.attachment.url);
  expect(served.status === 200 && served.bytes.equals(bytes), "its bytes are served");
});

await check("a bot's file field that isn't a file is refused, and a form with no attachment is too", async () => {
  const text = multipart([{ name: "attachment", bytes: Buffer.from("not a file") }]);
  const refused = await raw("POST", botMessages(), text);
  expect(refused.status === 422 && refused.json?.error === "An attachment has to be a file", `a field is not a file (${refused.status})`);
  const other = multipart([{ name: "other", filename: "a.txt", type: "text/plain", bytes: Buffer.from("x") }]);
  expectStatus(await raw("POST", botMessages(), other), 422);
});

await check("a bot's blank message is refused with no body", async () => {
  const res = await raw("POST", botMessages(), { body: Buffer.from("  \n") });
  expect(res.status === 422 && res.bytes.length === 0, `got ${res.status}`);
});

await check("a bot boosts a message and the answer is the boost with its booster and message", async () => {
  const posted = await raw("POST", botMessages(), { body: Buffer.from("Boost me") });
  const id = permalinkId(posted);
  const watcher = await roomSocket(state.rooms.Engineering, state.leo);
  await watcher.nextOfType("welcome");
  const res = await raw("POST", `/rooms/${state.rooms.Engineering}/${botKeys.deploy}/messages/${id}/boosts`, { body: Buffer.from(" ship it ") });
  expectStatus(res, 201);
  expect(res.json.content === "ship it" && res.json.booster.name === "Deploy Bot" && res.json.message.id === id, "the boost");
  expect(res.json.message.url === `${origin}/rooms/${state.rooms.Engineering}/@${id}` && typeof res.json.created_at === "string", "its links and time");
  const frame = await watcher.nextOfType("boost.created");
  expect(frame.boost.messageId === id && frame.boost.content === "ship it", "everyone in the room sees it");
});

await check("a boost on a missing message is 404, and a blank or long one is refused", async () => {
  const posted = await raw("POST", botMessages(), { body: Buffer.from("Another") });
  const id = permalinkId(posted);
  const boosts = (target) => `/rooms/${state.rooms.Engineering}/${botKeys.deploy}/messages/${target}/boosts`;
  expectStatus(await raw("POST", boosts("nothing"), { body: Buffer.from("hi") }), 404);
  expectStatus(await raw("POST", boosts(id), { body: Buffer.from("   ") }), 422);
  const long = await raw("POST", boosts(id), { body: Buffer.from("x".repeat(17)) });
  expect(long.status === 422 && /16 characters/.test(long.json?.error ?? ""), "too long");
});

await check("an unknown key is 401, a bot that isn't in the room is an empty 404, and no session is read", async () => {
  const wrongToken = `${botKeys.deploy.split("-")[0]}-${"z".repeat(12)}`;
  for (const key of ["nobody", wrongToken, `${botKeys.deploy}x`]) {
    const res = await raw("POST", `/rooms/${state.rooms.Engineering}/${key}/messages`, { cookie: state.maya, body: Buffer.from("hi") });
    expect(res.status === 401 && res.json?.error === "Unknown bot key", `${res.status} for a bad key`);
  }
  const elsewhere = await raw("POST", `/rooms/${state.rooms.Design}/${botKeys.deploy}/messages`, { body: Buffer.from("hi") });
  expect(elsewhere.status === 404 && elsewhere.bytes.length === 0 && /text\/html/.test(elsewhere.headers["content-type"] ?? ""), "not in that room");
  const unknownRoom = await raw("POST", `/rooms/nowhere/${botKeys.deploy}/messages`, { body: Buffer.from("hi") });
  expectStatus(unknownRoom, 404);
});

await check("signing out answers 204, forgets the session and revokes its sockets", async () => {
  const cookie = await signIn(emails.tomas);
  const socket = await tracked("/api/socket", { cookie });
  await socket.nextOfType("welcome");
  const out = await request("DELETE", "/api/session", { cookie });
  expectStatus(out, 204);
  expect((out.headers["set-cookie"] ?? []).some((line) => /Max-Age=0/i.test(line)), "the cookie is expired");
  expect((await socket.whenClosed()).code === 4003, "the socket closes 4003");
  expectStatus(await request("GET", "/api/me", { cookie }), 401);
});

for (const client of sockets) client.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check${failures === 1 ? "" : "s"} failed.`);
process.exit(failures === 0 ? 0 : 1);
