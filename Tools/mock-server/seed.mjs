// Fernwood, the team Ember's own seed (apps/worker/scripts/seed.ts) makes up, as the stand-in server holds
// it: the same people and rooms, with conversations written to show what a client has to draw.

import { keptCards, plainTextWithCards } from "./cards.mjs";
import { files } from "./files.mjs";
import { ASSISTANT_ID, htmlEscape, plainTextOf, mentionIdsOf, sortableId, stableId } from "./store.mjs";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export const PEOPLE = [
  { key: "maya", name: "Maya Chen", email: "maya@example.com", bio: "Product lead. Ask me about the roadmap.", role: "administrator" },
  { key: "sam", name: "Sam Rivera", email: "sam@example.com", bio: "Backend and infrastructure. Probably deploying something." },
  { key: "priya", name: "Priya Patel", email: "priya@example.com", bio: "Design systems, type and the occasional illustration." },
  { key: "leo", name: "Leo Park", email: "leo@example.com", bio: "Front end. Will trade code reviews for coffee." },
  { key: "jordan", name: "Jordan Lee", email: "jordan@example.com", bio: "Marketing and community." },
  { key: "amara", name: "Amara Okafor", email: "amara@example.com", bio: "Support lead, here for the customers." },
  { key: "tomas", name: "Tomás García", email: "tomas@example.com", bio: "QA and releases. Hiking most weekends." },
];

/// Small and repeatable, so every run of the server tells the same story.
function random(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const p = (...parts) => `<p>${parts.join("")}</p>`;
const text = (value) => htmlEscape(value);
const strong = (value) => `<strong>${text(value)}</strong>`;
const em = (value) => `<em>${text(value)}</em>`;
const strike = (value) => `<s>${text(value)}</s>`;
const code = (value) => `<code>${text(value)}</code>`;
const link = (href, label = href) => `<a href="${htmlEscape(href)}">${text(label)}</a>`;
const mention = (id) => `<action-text-attachment content-type="application/vnd.campfire.mention" sgid="${id}"></action-text-attachment>`;
const list = (tag, items) => `<${tag}>${items.map((item) => `<li>${item}</li>`).join("")}</${tag}>`;
const quote = (value) => `<blockquote>${text(value)}</blockquote>`;
const codeBlock = (language, lines) => `<pre data-language="${language}">${lines.map(text).join("<br>")}</pre>`;

/// The deploy card Deploy Bot posts, as the seed and the scripted bot both write it.
export function deployCards(version) {
  return [
    {
      source: "blocks",
      parts: [
        { kind: "header", text: `Deployed message-api ${version} to production` },
        { kind: "section", html: p("Smoke tests passed in ", strong("2m 14s"), ". Nothing to roll back."), button: { text: "Release notes", href: `https://fernwood.example/releases/${version}`, style: "primary" } },
        {
          kind: "section",
          fields: [
            { html: p(strong("Commit"), "<br>", code("8a1969f")), short: true },
            { html: p(strong("Started by"), "<br>", "Maya Chen"), short: true },
          ],
        },
        { kind: "context", items: [{ html: p("Took 4m 31s · ", link("https://fernwood.example/deploys/1874", "Deploy #1874")) }] },
      ],
    },
  ];
}

/// Builds the workspace into `store`. Answers the keys the server needs to know: people and rooms by name.
export function seed(store, now = Date.now(), { mediaOrigin = "http://media.localhost:8787" } = {}) {
  const people = {};
  const start = now - 30 * DAY;
  PEOPLE.forEach((person, index) => {
    people[person.key] = store.addUser({ id: stableId(`user:${person.email}`), ...person, createdAt: start + index * MINUTE });
  });
  store.addUser({ id: ASSISTANT_ID, name: "Ember", bio: null, role: "bot", createdAt: start });
  const deployBot = store.addUser({ id: stableId("bot:deploy"), name: "Deploy Bot", role: "bot", createdAt: start + 10 * MINUTE });
  const uptime = store.addUser({ id: stableId("bot:uptime"), name: "Uptime", role: "bot", createdAt: start + 11 * MINUTE });
  const everyone = PEOPLE.map(({ key }) => people[key].id);
  store.joinCode = stableId("join-code").slice(0, 12);

  const rooms = {};
  const shared = (key, name, icon, kind, memberIds, by, offset) => {
    rooms[key] = store.addRoom({ id: stableId(`room:${key}`), kind, name, icon, memberIds, createdAt: start + offset * MINUTE, by: people[by].id });
  };
  shared("general", "general", null, "open", everyone, "maya", 20);
  shared("random", "random", null, "open", everyone, "maya", 21);
  shared("launch", "Launch", "rocket", "open", everyone, "maya", 60);
  shared("design", "Design", "palette", "open", everyone, "priya", 61);
  shared("engineering", "Engineering", "code", "open", everyone, "sam", 62);
  shared("support", "Support", "life-buoy", "open", everyone, "amara", 63);
  shared("leadership", "Leadership", "briefcase", "closed", [people.maya.id, people.sam.id, people.priya.id], "maya", 64);
  const direct = (key, by, ...others) => {
    rooms[key] = store.addRoom({ id: stableId(`room:${key}`), kind: "direct", memberIds: [people[by].id, ...others.map((name) => people[name].id)], createdAt: start + 100 * MINUTE, by: people[by].id });
  };
  direct("samAndMaya", "sam", "maya");
  direct("priyaAndMaya", "priya", "maya");
  direct("leoMayaJordan", "leo", "maya", "jordan");
  store.sharedOrder = [rooms.launch, rooms.design, rooms.engineering, rooms.support, rooms.general, rooms.random].map((room) => room.id);
  store.setFavourite(people.maya.id, rooms.launch.id, true);

  const say = (room, who, html, at, extra = {}) => {
    const creatorId = typeof who === "string" ? people[who].id : who.id;
    const id = sortableId(at, room.messages.at(-1)?.id ?? "");
    const kept = extra.cards ? keptCards(extra.cards) : null;
    const plain = extra.plainText ?? (kept ? plainTextWithCards(plainTextOf(html, store.nameOf), kept.plainText) : plainTextOf(html, store.nameOf));
    const message = {
      id,
      clientMessageId: id,
      creatorId,
      body: html,
      plainText: plain,
      mentionIds: mentionIdsOf(html),
      createdAt: at,
      updatedAt: extra.editedAt ?? at,
      editedAt: extra.editedAt ?? null,
      boosts: [],
      parentId: extra.parent?.id,
      alsoSent: extra.parent ? extra.alsoSent === true : undefined,
      deleted: false,
      attachment: extra.attachment,
    };
    if (kept && kept.cards.length > 0) message.cards = kept.cards;
    room.messages.push(message);
    store.nextSeq(room, "upsert", id);
    for (const [index, [booster, content]] of (extra.boosts ?? []).entries()) {
      message.boosts.push({ id: sortableId(at + (index + 1) * MINUTE), userId: people[booster].id, content, createdAt: at + (index + 1) * MINUTE });
      store.nextSeq(room, "upsert", id);
    }
    return message;
  };

  // The long history: a week in general, several voices, a few hundred words to search.
  const lines = [
    "Morning all.",
    "Has anyone seen the latest numbers?",
    "Looking at it now.",
    "Can we move the standup to ten tomorrow?",
    "Works for me.",
    "I’ll bring the coffee.",
    "The staging deploy is green again.",
    "Thanks for flagging that.",
    "Lunch plans, anyone?",
    "Reminder: the quarterly review is on Friday.",
    "Just pushed the fix for the login redirect.",
    "Nice, I’ll take a look after this call.",
    "Customers are asking about dark mode again.",
    "It’s on the roadmap for next month.",
    "Who owns the onboarding emails?",
    "That’s mine, I’ll update them this week.",
    "Quick question about the release notes.",
    "Draft is in the shared folder.",
    "Heading out for a bit, back at two.",
    "The new icons look great.",
    "Can someone review my pull request?",
    "On it.",
    "We crossed a thousand sign-ups overnight.",
    "That calls for cake.",
    "Rolling back the last change, it was noisy.",
    "Good call.",
    "Can we talk about the pricing page copy?",
    "Let’s do it in the afternoon.",
    "Documentation is updated.",
    "Great work this week, everyone.",
  ];
  const rng = random(42);
  let at = now - 6 * DAY;
  let count = 0;
  while (at < now - 2 * HOUR) {
    const who = PEOPLE[Math.floor(rng() * PEOPLE.length)].key;
    const line = lines[Math.floor(rng() * lines.length)];
    say(rooms.general, who, p(text(line)), at, { boosts: rng() < 0.08 ? [[PEOPLE[Math.floor(rng() * PEOPLE.length)].key, "👍"]] : [] });
    count += 1;
    at += (3 + Math.floor(rng() * 22)) * MINUTE;
    if (rng() < 0.08) at += (3 + Math.floor(rng() * 6)) * HOUR;
  }
  if (count < 130) throw new Error(`The seed's long history came to only ${count} messages`);
  say(rooms.general, "maya", p("Welcome to ", strong("Fernwood"), ". Say hello in ", mention(people.sam.id), "’s favourite channel."), now - HOUR);

  // Launch: every kind of body a client has to draw.
  const base = now - 3 * DAY;
  say(rooms.launch, "maya", `<p>Launch checklist for ${strong("Thursday")}:</p>${list("ol", [text("Freeze the build"), text("Final QA pass"), `Publish the ${em("release notes")}`])}`, base);
  say(rooms.launch, "sam", `${p("Before then, on my side:")}${list("ul", [`Migrate the ${code("sessions")} table`, `Warm the ${code("search")} index`, text("Check the dashboards")])}`, base + 20 * MINUTE, { boosts: [["maya", "👍"], ["tomas", "🙏"]] });
  say(rooms.launch, "priya", p("New hero art is up: ", link("https://example.com/launch/hero")), base + 1 * HOUR);
  say(rooms.launch, "leo", `${p("The flag check, for anyone who wants it:")}${codeBlock("javascript", ["const ready = await flags.ready(“launch”);", "if (!ready) rollback();"])}`, base + 2 * HOUR);
  say(rooms.launch, "tomas", `${quote("Ship it when it’s ready, not before.")}${p("Agreed. I’d add a day for QA.")}`, base + 3 * HOUR);
  say(rooms.launch, "maya", p("Thanks ", mention(people.priya.id), ", the copy looks great. ", mention(people.leo.id), " can you check it on mobile?"), base + 4 * HOUR);
  say(rooms.launch, "jordan", p("🎉🚀"), base + 5 * HOUR, { boosts: [["maya", "🎉"], ["sam", "🚀"], ["amara", "👏"]] });
  say(rooms.launch, "leo", p("The date is ", strike("Wednesday"), " Thursday."), base + 6 * HOUR, { editedAt: base + 6 * HOUR + 3 * MINUTE });
  const thread = say(rooms.launch, "amara", p("Do we have a status page for launch day?"), now - 20 * HOUR);
  say(rooms.launch, "sam", p("Yes: ", link("https://status.example.com")), now - 19 * HOUR, { parent: thread });
  say(rooms.launch, "maya", p("Great, please link it in the announcement."), now - 18 * HOUR, { parent: thread, alsoSent: true });
  say(rooms.launch, "amara", p("Will do."), now - 17 * HOUR, { parent: thread });
  say(rooms.launch, "tomas", p("Smoke tests passed on staging. Booking the final run for tomorrow."), now - 5 * HOUR);

  // Design: a picture.
  // An SVG is kept and served but never previewed or measured, as on the real server.
  const palette = Buffer.from(paletteSvg());
  const attachment = files.keep({
    key: (stableId("file:palette") + stableId("file:palette:key")).slice(0, 28),
    name: "palette.svg",
    contentType: "image/svg+xml",
    bytes: palette,
    uploadedAt: now - 2 * DAY + 2 * MINUTE,
  });
  say(rooms.design, "priya", p("Palette options for the new brand colours."), now - 2 * DAY);
  say(rooms.design, "priya", "", now - 2 * DAY + 2 * MINUTE, { plainText: "palette.svg", attachment });
  say(rooms.design, "leo", p("The second row works best in dark mode."), now - 2 * DAY + 30 * MINUTE);
  say(rooms.design, "maya", p("Agreed. ", mention(people.priya.id), " can you export the tokens?"), now - 47 * HOUR);

  // Engineering: bots, and unread for the administrator.
  say(rooms.engineering, deployBot, p("Deployed ", code("v2.4.1"), " to production."), now - 30 * HOUR);
  say(rooms.engineering, uptime, p("All checks passing. 99.98% over the last 30 days."), now - 29 * HOUR);
  // The three below ran at 3 h and 2 h ago; the bots' cards come after them, so they moved to the day before.
  say(rooms.engineering, "sam", p("Index rebuild is running, expect search to be slow for a few minutes."), now - 28 * HOUR);
  say(rooms.engineering, "leo", p("Anything I should watch while it runs?"), now - 28 * HOUR + 4 * MINUTE);
  say(rooms.engineering, "sam", p("Just the queue depth, it should drain by itself."), now - 27 * HOUR);

  // Engineering's bot cards (what Slack-shaped payloads become), oldest first and the newest things in the room.
  const media = (name) => `${mediaOrigin}/card-media/${name}.png`;
  const button = (label, href, style) => ({ text: label, href, ...(style && { style }) });
  const seconds = (ms) => Math.floor(ms / 1000);
  const cardsRoom = rooms.engineering;
  say(cardsRoom, deployBot, "", now - 26 * HOUR, { cards: deployCards("v2.4.2") });

  const alertLink = "https://status.fernwood.example/alerts/high-error-rate";
  const alertCard = (at, color, state, html, severity, buttons) => [
    {
      source: "attachment",
      color,
      parts: [
        { kind: "title", text: `[${state}] HighErrorRate message-api`, href: alertLink },
        { kind: "text", html },
        { kind: "fields", fields: [{ title: "Severity", html: p(severity), short: true }, { title: "Region", html: p("fra1"), short: true }] },
        ...(buttons ? [{ kind: "buttons", buttons }] : []),
        { kind: "footer", text: "Uptime", at: seconds(at) },
      ],
    },
  ];
  const firing = now - 20 * HOUR;
  say(cardsRoom, uptime, p("Message API errors are up"), firing, {
    cards: alertCard(firing, "danger", "FIRING", p("5xx rate is ", strong("4.2%"), " over the last 5 minutes (threshold 1%)."), "critical", [button("Runbook", "https://runbooks.fernwood.example/high-error-rate", "danger")]),
  });
  const resolved = now - 19 * HOUR;
  say(cardsRoom, uptime, p("Message API errors are back to normal"), resolved, {
    cards: alertCard(resolved, "good", "RESOLVED", p("5xx rate is back under 1%."), "resolved"),
  });

  say(cardsRoom, deployBot, "", now - 6 * HOUR, {
    cards: [
      {
        source: "blocks",
        parts: [
          { kind: "header", text: "Nightly deploy summary" },
          { kind: "section", html: p(strong("3 services"), " are live in ", strong("production"), "."), button: button("Release notes", "https://fernwood.example/releases/nightly", "primary") },
          {
            kind: "table",
            rows: [
              ["Service", "Took", "Errors"].map((cell) => p(text(cell))),
              ["message-api", "1m 12s", "0"].map((cell) => p(text(cell))),
              ["web", "48s", "0"].map((cell) => p(text(cell))),
              [p(link("https://fernwood.example/workers", "workers")), p("2m 3s"), p("2")],
            ],
            columns: [{ align: "left", wrap: true }, { align: "right", wrap: false }, { align: "right", wrap: false }],
          },
          { kind: "divider" },
          { kind: "context", items: [{ image: { url: media("avatar"), alt: "Maya Chen" } }, { html: p("Started by ", strong("Maya Chen")) }] },
        ],
      },
    ],
  });

  const pipeline = now - 4 * HOUR;
  const jobs = ["lint", "unit", "integration", "e2e", "build", "bundle size", "accessibility", "deploy preview"];
  const outcomes = ["passed in 21s", "passed in 1m 48s", "passed in 3m 2s", "passed with 2 retries in 6m 40s", "passed in 2m 5s", "grew by 4 KB", "passed in 54s", "ready"];
  say(cardsRoom, deployBot, "", pipeline, {
    cards: [
      {
        source: "attachment",
        color: "#7c3aed",
        pretext: p("Pipeline ", strong("#1042"), " finished"),
        thumb: { url: media("thumb"), alt: "web" },
        parts: [
          { kind: "author", name: "Priya Patel", href: "https://git.fernwood.example/priya", icon: media("avatar") },
          { kind: "title", text: "Pipeline #1042 passed with warnings", href: "https://git.fernwood.example/web/pipelines/1042" },
          { kind: "text", html: jobs.map((job, index) => p(strong(job), ": ", text(outcomes[index]))).join("") },
          {
            kind: "fields",
            fields: [
              { title: "Branch", html: p(link("https://git.fernwood.example/web/tree/main", "main")), short: true },
              { title: "Commit", html: p(link("https://git.fernwood.example/web/commit/3f9c2ab", "Fix the sign-in redirect")), short: true },
              { title: "Notes", html: p("Two flaky e2e tests were retried."), short: false },
            ],
          },
          { kind: "image", image: { url: media("chart"), alt: "" }, title: "Coverage by package" },
          { kind: "footer", text: "web", icon: media("icon"), at: seconds(pipeline) },
        ],
      },
    ],
  });

  say(cardsRoom, deployBot, "", now - 2 * HOUR, {
    cards: [
      {
        source: "blocks",
        parts: [
          { kind: "section", html: p("Preview environments for open pull requests") },
          {
            kind: "tiles",
            tiles: [
              {
                hero: { url: media("hero-1"), alt: "Thread drafts preview" },
                title: "web #482",
                subtitle: "feature/thread-drafts · Priya Patel",
                body: p("Built ", strong("12 minutes ago")),
                subtext: p("Expires in 3 days"),
                buttons: [button("Open", "https://preview-482.fernwood.example/", "primary"), button("Logs", "https://fernwood.example/deploys/482"), button("Tear down", "https://fernwood.example/deploys/482/teardown", "danger")],
              },
              {
                hero: { url: media("hero-2"), alt: "" },
                title: "web #479",
                subtitle: "fix/upload-retry · Tomás García",
                body: p("Built ", strong("2 hours ago")),
                buttons: [button("Open", "https://preview-479.fernwood.example/", "primary")],
              },
              {
                icon: { url: media("icon"), alt: "" },
                title: "message-api #233",
                subtitle: "chore/bump-runtime · Leo Park",
                body: p("Build failed"),
                subtext: p("Exit code 1 in ", code("test")),
              },
            ],
          },
        ],
      },
    ],
  });

  const expiry = now - 90 * MINUTE;
  say(cardsRoom, uptime, p("Certificate for status.fernwood.example expires in 9 days"), expiry, {
    cards: [
      {
        source: "attachment",
        color: "warning",
        parts: [
          { kind: "title", text: "Certificate expires in 9 days", href: "https://status.fernwood.example/certificates" },
          { kind: "text", html: p("Renewal is scheduled for Thursday.") },
          { kind: "footer", text: "Uptime", at: seconds(expiry) },
        ],
      },
    ],
  });
  rooms.engineering.members.get(people.maya.id).unread = true;

  // Support and the rest.
  say(rooms.support, "amara", p("Three tickets about password resets this morning, all the same cause."), now - 26 * HOUR);
  say(rooms.support, "sam", p("Found it, the reset email was landing in spam. Fix is going out now."), now - 25 * HOUR);
  say(rooms.support, "amara", p("Thank you. I’ll reply to each of them."), now - 24 * HOUR, { boosts: [["sam", "🙌"]] });
  say(rooms.random, "jordan", p("Anyone have a good book to recommend?"), now - 2 * DAY);
  say(rooms.random, "tomas", p("Try the one about lighthouses. Sounds dull, isn’t."), now - 2 * DAY + 10 * MINUTE);
  say(rooms.random, "leo", p("Adding it to the list."), now - 2 * DAY + 20 * MINUTE);
  say(rooms.leadership, "maya", p("Budget draft is ready for review before Friday."), now - 2 * DAY);
  say(rooms.leadership, "sam", p("I’ll read it tonight."), now - 2 * DAY + 5 * MINUTE);
  say(rooms.leadership, "priya", p("Can we talk about the design hiring plan?"), now - DAY);

  // DMs. Sam’s is unread for Maya.
  say(rooms.samAndMaya, "maya", p("Do you have ten minutes for the infra review?"), now - 2 * DAY);
  say(rooms.samAndMaya, "sam", p("Sure, after lunch?"), now - 2 * DAY + 3 * MINUTE);
  say(rooms.samAndMaya, "maya", p("Perfect."), now - 2 * DAY + 4 * MINUTE);
  say(rooms.samAndMaya, "sam", p("Notes from the review are in the wiki. One follow-up for you."), now - 90 * MINUTE);
  rooms.samAndMaya.members.get(people.maya.id).unread = true;
  rooms.samAndMaya.activeAt = rooms.samAndMaya.messages.at(-1).createdAt;
  say(rooms.priyaAndMaya, "priya", p("Sent you the revised moodboard."), now - 4 * HOUR);
  say(rooms.priyaAndMaya, "maya", p("Looks lovely. Let’s use the second one."), now - 3 * HOUR);
  rooms.priyaAndMaya.activeAt = rooms.priyaAndMaya.messages.at(-1).createdAt;
  say(rooms.leoMayaJordan, "leo", p("Which of us is writing the launch post?"), now - 6 * HOUR);
  say(rooms.leoMayaJordan, "jordan", p("I can draft it tonight."), now - 6 * HOUR + 2 * MINUTE);
  say(rooms.leoMayaJordan, "maya", p("Thanks ", mention(people.jordan.id), ". Send it to us both."), now - 6 * HOUR + 5 * MINUTE);
  rooms.leoMayaJordan.activeAt = rooms.leoMayaJordan.messages.at(-1).createdAt;

  return { people, rooms, bots: { deployBot, uptime } };
}

/// The picture the design room's file message shows.
export function paletteSvg() {
  const colours = ["#2f6fed", "#e8590c", "#2b8a3e", "#ae3ec9", "#f59f00", "#0c8599"];
  const swatches = colours.map((colour, index) => `<rect x="${20 + index * 100}" y="40" width="90" height="120" rx="12" fill="${colour}"/>`).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360"><rect width="640" height="360" fill="#f4f1ea"/>${swatches}</svg>`;
}
