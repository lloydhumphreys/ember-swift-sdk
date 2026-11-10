// Bot cards for the stand-in: the shape the real server keeps (packages/protocol/src/cards.ts) and the plain
// text it adds to a message (apps/worker/src/cards.ts), with the generated pictures the seeded cards show.
// The Slack translator and the /slack webhook are not ported: cards are written here already translated.

import { deflateSync } from "node:zlib";
import { plainTextOf } from "./store.mjs";

const MAX_MESSAGE_HTML_LENGTH = 100_000;
const MAX_CARDS = 101;
const MAX_PARTS = 60;
const MAX_ITEMS = 100;
const MAX_COLUMNS = 20;
const MAX_TILE_BUTTONS = 3;
const COLOR = /^(?:good|warning|danger|#[0-9a-f]{6})$/i;
const ALIGNMENTS = new Set(["left", "center", "right"]);

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const listOf = (value) => (Array.isArray(value) ? value : []);
const textOf = (value) => (typeof value === "string" && value.trim() !== "" && value.length <= 3000 ? value : undefined);
const htmlOf = (value) => (typeof value === "string" && value !== "" && value.length <= MAX_MESSAGE_HTML_LENGTH ? value : undefined);
const urlOf = (value) => (typeof value === "string" && value.length <= 3000 ? value : undefined);
const momentOf = (value) => (typeof value === "number" && !Number.isNaN(new Date(value * 1000).getTime()) ? value : undefined);
const itemsOf = (value, parse) => listOf(value).slice(0, MAX_ITEMS).map(parse).filter((item) => item !== null && item !== undefined);
const showsAnything = (parts) => parts.some((part) => part.kind !== "divider");
const linked = (key, value) => (urlOf(value) === undefined ? {} : { [key]: value });

/// Rich text as a body keeps it, with its plain text; undefined when it holds nothing.
function keptText(html) {
  if (htmlOf(html) === undefined) return undefined;
  const plainText = plainTextOf(html, () => undefined);
  return plainText.trim() === "" ? undefined : { html, plainText };
}

function imageOf(value) {
  if (!isRecord(value)) return undefined;
  const url = urlOf(value.url);
  return url === undefined ? undefined : { url, alt: textOf(value.alt) ?? "" };
}

function buttonOf(value) {
  if (!isRecord(value)) return undefined;
  const text = textOf(value.text);
  const href = urlOf(value.href);
  if (text === undefined || href === undefined) return undefined;
  return { text, href, ...(value.style === "primary" || value.style === "danger" ? { style: value.style } : {}) };
}

function fieldOf(value) {
  if (!isRecord(value)) return null;
  const title = textOf(value.title);
  const html = htmlOf(value.html);
  if (title === undefined && html === undefined) return null;
  return { ...(title && { title }), html: html ?? "", short: value.short === true };
}

/// A part as the room parses it, then keeps it with its text checked; `lines` are the plain text it adds.
function keptPart(value) {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "author": {
      const name = textOf(value.name);
      return name === undefined ? null : { part: { kind: "author", name, ...linked("href", value.href), ...linked("icon", value.icon) }, lines: [name] };
    }
    case "title": {
      const text = textOf(value.text);
      return text === undefined ? null : { part: { kind: "title", text, ...linked("href", value.href) }, lines: [text] };
    }
    case "header": {
      const text = textOf(value.text);
      return text === undefined ? null : { part: { kind: "header", text }, lines: [text] };
    }
    case "text": {
      const text = keptText(value.html);
      return text ? { part: { kind: "text", html: text.html }, lines: [text.plainText] } : null;
    }
    case "section": {
      const text = keptText(value.html);
      const fields = keptFields(value.fields);
      if (!text && fields.fields.length === 0) return null;
      const thumb = imageOf(value.thumb);
      const button = buttonOf(value.button);
      return {
        part: { kind: "section", ...(text && { html: text.html }), ...(fields.fields.length > 0 && { fields: fields.fields }), ...(thumb && { thumb }), ...(button && { button }) },
        lines: [...(text ? [text.plainText] : []), ...fields.lines, ...(button ? [button.text] : [])],
      };
    }
    case "fields": {
      const fields = keptFields(value.fields);
      return fields.fields.length === 0 ? null : { part: { kind: "fields", fields: fields.fields }, lines: fields.lines };
    }
    case "image": {
      const image = imageOf(value.image);
      const title = textOf(value.title);
      return image ? { part: { kind: "image", image, ...(title && { title }) }, lines: title ? [title] : [] } : null;
    }
    case "context": {
      const kept = itemsOf(value.items, (item) => {
        if (!isRecord(item)) return null;
        if ("image" in item) {
          const image = imageOf(item.image);
          return image ? { item: { image } } : null;
        }
        const text = keptText(item.html);
        return text ? { item: { html: text.html }, line: text.plainText } : null;
      });
      if (kept.length === 0) return null;
      const line = kept.flatMap(({ line }) => line ?? []).join(" ");
      return { part: { kind: "context", items: kept.map(({ item }) => item) }, lines: line === "" ? [] : [line] };
    }
    case "divider":
      return { part: { kind: "divider" }, lines: [] };
    case "buttons": {
      const buttons = itemsOf(value.buttons, buttonOf);
      return buttons.length === 0 ? null : { part: { kind: "buttons", buttons }, lines: [buttons.map(({ text }) => text).join(" · ")] };
    }
    case "table": {
      const rows = itemsOf(value.rows, (row) => (Array.isArray(row) && row.length > 0 ? row.slice(0, MAX_COLUMNS).map((cell) => htmlOf(cell) ?? "") : null));
      if (rows.length === 0) return null;
      const columns = listOf(value.columns)
        .slice(0, MAX_COLUMNS)
        .map((column) => ({ align: isRecord(column) && ALIGNMENTS.has(column.align) ? column.align : "left", wrap: isRecord(column) && column.wrap === true }));
      const cells = rows.map((row) => row.map((cell) => (cell === "" ? undefined : keptText(cell))));
      if (!cells.some((row) => row.some((cell) => cell !== undefined))) return null;
      const oneLine = (text) => text.replace(/\s+/g, (space) => (space.includes("\n") ? " " : space));
      return {
        part: { kind: "table", rows: cells.map((row) => row.map((cell) => cell?.html ?? "")), columns },
        lines: cells.map((row) => row.map((cell) => (cell ? oneLine(cell.plainText) : "")).join(" | ")),
      };
    }
    case "tiles": {
      const kept = itemsOf(value.tiles, (tile) => {
        if (!isRecord(tile)) return null;
        const hero = imageOf(tile.hero);
        const icon = imageOf(tile.icon);
        const title = textOf(tile.title);
        const subtitle = textOf(tile.subtitle);
        const body = keptText(tile.body);
        const subtext = keptText(tile.subtext);
        const buttons = itemsOf(tile.buttons, buttonOf).slice(0, MAX_TILE_BUTTONS);
        const result = {
          ...(hero && { hero }),
          ...(icon && { icon }),
          ...(title && { title }),
          ...(subtitle && { subtitle }),
          ...(body && { body: body.html }),
          ...(subtext && { subtext: subtext.html }),
          ...(buttons.length > 0 && { buttons }),
        };
        if (!(hero || title || subtitle || body || subtext || buttons.length > 0)) return null;
        const lines = [title, subtitle, body?.plainText, subtext?.plainText, buttons.length > 0 ? buttons.map(({ text }) => text).join(" · ") : undefined].filter((line) => line !== undefined);
        return { tile: result, lines };
      });
      return kept.length === 0 ? null : { part: { kind: "tiles", tiles: kept.map(({ tile }) => tile) }, lines: kept.flatMap(({ lines }) => lines) };
    }
    case "footer": {
      const text = textOf(value.text);
      const at = momentOf(value.at);
      if (text === undefined && at === undefined) return null;
      return { part: { kind: "footer", ...(text && { text }), ...linked("icon", value.icon), ...(at !== undefined && { at }) }, lines: text ? [text] : [] };
    }
    default:
      return null;
  }
}

function keptFields(value) {
  const kept = itemsOf(value, (raw) => {
    const field = fieldOf(raw);
    if (!field) return null;
    const text = field.html === "" ? undefined : keptText(field.html);
    if (field.title === undefined && !text) return null;
    return { field: { ...field, html: text?.html ?? "" }, lines: [field.title ?? "", text?.plainText ?? ""].filter((line) => line !== "") };
  });
  return { fields: kept.map(({ field }) => field), lines: kept.flatMap(({ lines }) => lines) };
}

/// The cards `value` lists as the room keeps them (parts it can't read go, so does a card left with nothing,
/// and keys with nothing in them are left out), with the plain text they add to their message's: a line for each part.
export function keptCards(value) {
  const lines = [];
  const cards = [];
  if (!Array.isArray(value)) return { cards, plainText: "" };
  for (const card of value.slice(0, MAX_CARDS)) {
    if (!isRecord(card) || (card.source !== "attachment" && card.source !== "blocks")) continue;
    const parts = listOf(card.parts).slice(0, MAX_PARTS).flatMap((part) => keptPart(part) ?? []);
    const shown = showsAnything(parts.map(({ part }) => part));
    if (card.source === "blocks") {
      if (!shown) continue;
      cards.push({ source: "blocks", parts: parts.map(({ part }) => part) });
      lines.push(...parts.flatMap(({ lines }) => lines));
      continue;
    }
    const pretext = keptText(card.pretext);
    if (!shown && !pretext) continue;
    const color = typeof card.color === "string" && COLOR.test(card.color) ? card.color.toLowerCase() : undefined;
    const thumb = imageOf(card.thumb);
    cards.push({ source: "attachment", ...(color && { color }), ...(pretext && { pretext: pretext.html }), ...(thumb && { thumb }), parts: parts.map(({ part }) => part) });
    if (pretext) lines.push(pretext.plainText);
    lines.push(...parts.flatMap(({ lines }) => lines));
  }
  return { cards, plainText: lines.join("\n") };
}

/// A message's plain text: its text's, then its cards', each on a line of its own.
export const plainTextWithCards = (text, cardsText) => [text, cardsText].filter((line) => line !== "").join("\n");

// Pictures

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "latin1");
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, tail]);
}

/// An RGB PNG whose colour runs from `from` (top left) to `to` (bottom right).
export function gradientPng(width, height, from, to) {
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const t = (x / (width - 1) + y / (height - 1)) / 2;
      for (let channel = 0; channel < 3; channel++) rows[row + 1 + x * 3 + channel] = Math.round(from[channel] + (to[channel] - from[channel]) * t);
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}

const PICTURES = {
  avatar: [64, 64, [124, 58, 237], [236, 72, 153]],
  icon: [64, 64, [14, 165, 233], [16, 185, 129]],
  thumb: [150, 150, [245, 158, 11], [239, 68, 68]],
  chart: [720, 400, [30, 64, 175], [56, 189, 248]],
  "hero-1": [640, 320, [79, 70, 229], [217, 70, 239]],
  "hero-2": [640, 320, [5, 150, 105], [163, 230, 53]],
};
const made = new Map();

/// The PNG `/card-media/<name>.png` answers, or undefined for a name it doesn't know.
export function cardPicture(name) {
  if (!Object.hasOwn(PICTURES, name)) return undefined;
  if (!made.has(name)) made.set(name, gradientPng(...PICTURES[name]));
  return made.get(name);
}
