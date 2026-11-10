// Uploads and file serving as the real server does them: files held in memory, addressed by a key and an HMAC
// signature so a link works without a cookie, and served with the real server's headers, disposition rules and Range handling.

import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export const PART_SIZE = 10 * 1024 * 1024;
export const MAX_FILE_BYTES = 250_000_000;
export const MAX_PREVIEW_BYTES = 5 * 1024 * 1024;
export const PREVIEW_WIDTH = 1200;
export const PREVIEW_HEIGHT = 800;
const MAX_PIXELS = 250_000_000;
const MAX_RANGES = 49;

const KEY = /^[0-9a-z]{28}$/;

/// Served as plain bytes whatever they claim to be, because a browser would run them.
const UNSAFE_TYPES = new Set([
  "text/html",
  "image/svg+xml",
  "application/postscript",
  "application/x-shockwave-flash",
  "text/xml",
  "application/xml",
  "application/xhtml+xml",
  "application/mathml+xml",
  "text/cache-manifest",
]);

const INLINE_TYPES = new Set([
  "image/webp",
  "image/avif",
  "image/png",
  "image/gif",
  "image/jpeg",
  "image/tiff",
  "image/bmp",
  "image/x-ms-bmp",
  "image/vnd.adobe.photoshop",
  "image/vnd.microsoft.icon",
  "image/x-icon",
  "application/pdf",
]);

const PREVIEWED_TYPES = new Set(["image/png", "image/gif", "image/jpeg", "image/tiff", "image/webp", "image/avif", "image/heic", "image/heif"]);

const EXTENSIONS = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  heic: "image/heic",
  heif: "image/heif",
  tif: "image/tiff",
  tiff: "image/tiff",
  bmp: "image/bmp",
  ico: "image/vnd.microsoft.icon",
  psd: "image/vnd.adobe.photoshop",
  svg: "image/svg+xml",
  pdf: "application/pdf",
  txt: "text/plain",
  md: "text/markdown",
  csv: "text/csv",
  html: "text/html",
  htm: "text/html",
  xml: "application/xml",
  json: "application/json",
  zip: "application/zip",
  mp4: "video/mp4",
  mov: "video/quicktime",
  m4v: "video/mp4",
  mp3: "audio/mpeg",
  wav: "audio/wav",
};

const PREVIEW_EXTENSIONS = { "image/webp": "webp", "image/jpeg": "jpg", "image/png": "png" };

// Names

/// Ruby's `String#strip`: NUL and ASCII whitespace off both ends, but not Unicode spaces.
const stripped = (name) => name.replace(/^[\0\t\n\v\f\r ]+/, "").replace(/[\0\t\n\v\f\r ]+$/, "");

/// A name with its edges stripped, and the characters it can't carry into a path or a shell swapped for hyphens
/// (apps/worker/src/files/filename.ts).
export const sanitizedFilename = (name) => stripped(name).replace(/[‮%$|:;/<>?*"\t\r\n\\]/g, "-");

/// A name as it goes in a URL: path-escaped, with nothing that could climb out of its segment.
export function addressName(name) {
  if (name === "" || name === "." || name === "..") return "-";
  let out = "";
  for (const byte of Buffer.from(name, "utf8")) {
    const char = String.fromCharCode(byte);
    out += byte < 0x80 && /[A-Za-z0-9\-._~!$&'()*+,;=:@/]/.test(char) ? char : "%" + byte.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

const percentEscape = (text, keep) =>
  [...text].map((char) => (keep.test(char) ? char : [...Buffer.from(char, "utf8")].map((byte) => "%" + byte.toString(16).toUpperCase().padStart(2, "0")).join(""))).join("");

const LIGATURES = { ß: "ss", æ: "ae", Æ: "AE", ø: "o", Ø: "O", đ: "d", Đ: "D", ł: "l", Ł: "L", œ: "oe", Œ: "OE" };

/// A rough match for Rails' transliteration: accents dropped, a few letters spelled out, anything else a question mark.
const transliterated = (name) =>
  [...name.normalize("NFKD").replace(/\p{M}/gu, "")].map((char) => (char.charCodeAt(0) < 128 ? char : LIGATURES[char] ?? "?")).join("");

export function contentDisposition(disposition, name) {
  const ascii = percentEscape(transliterated(name), /[ A-Za-z0-9!#$+.^_`|~-]/);
  const utf8 = percentEscape(name, /[A-Za-z0-9!#$&+.^_`|~-]/);
  return `${disposition}; filename="${ascii}"; filename*=UTF-8''${utf8}`;
}

const previewName = (name, contentType) => `${name.replace(/(?<=.)\.[^.]*$/, "")}.${PREVIEW_EXTENSIONS[contentType]}`;

// Reading what a file is

const startsWith = (bytes, signature, at = 0) => signature.every((byte, index) => bytes[at + index] === byte);
const ascii = (bytes, from, to) => bytes.subarray(from, to).toString("latin1");

function magicType(bytes) {
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (ascii(bytes, 0, 6) === "GIF87a" || ascii(bytes, 0, 6) === "GIF89a") return "image/gif";
  if (ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 12) === "WEBP") return "image/webp";
  if (ascii(bytes, 0, 4) === "%PDF") return "application/pdf";
  if (startsWith(bytes, [0x49, 0x49, 0x2a, 0x00]) || startsWith(bytes, [0x4d, 0x4d, 0x00, 0x2a])) return "image/tiff";
  if (startsWith(bytes, [0x50, 0x4b, 0x03, 0x04])) return "application/zip";
  if (ascii(bytes, 4, 8) === "ftyp") {
    const brand = ascii(bytes, 8, 12);
    if (brand === "avif" || brand === "avis") return "image/avif";
    if (["heic", "heix", "hevc", "hevx"].includes(brand)) return "image/heic";
    if (brand === "mif1" || brand === "msf1") return "image/heif";
    if (brand === "qt  ") return "video/quicktime";
    return "video/mp4";
  }
  return null;
}

/// What a file is, from its first bytes, then what the client said, then its extension. Marcel's finer precedence between related types isn't mirrored.
export function sniff(bytes, declaredType, name) {
  const magic = magicType(bytes);
  if (magic) return magic;
  const declared = typeof declaredType === "string" ? declaredType.split(";")[0].trim().toLowerCase() : "";
  if (declared.includes("/") && declared !== "application/octet-stream") return declared;
  const extension = /\.([^.]+)$/.exec(name)?.[1]?.toLowerCase();
  return (extension && EXTENSIONS[extension]) || "application/octet-stream";
}

/// Width and height from a header, or null. EXIF orientation, TIFF, HEIF and AVIF aren't read.
export function imageSize(bytes, contentType) {
  const size = (width, height) => (width > 0 && height > 0 ? { width, height } : null);
  if (contentType === "image/png" && bytes.length >= 24) return size(bytes.readUInt32BE(16), bytes.readUInt32BE(20));
  if (contentType === "image/gif" && bytes.length >= 10) return size(bytes.readUInt16LE(6), bytes.readUInt16LE(8));
  if (contentType === "image/jpeg") {
    let at = 2;
    while (at + 9 < bytes.length) {
      if (bytes[at] !== 0xff) return null;
      const marker = bytes[at + 1];
      if (marker === 0xff) {
        at += 1;
        continue;
      }
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return size(bytes.readUInt16BE(at + 7), bytes.readUInt16BE(at + 5));
      at += 2 + bytes.readUInt16BE(at + 2);
    }
    return null;
  }
  if (contentType === "image/webp" && bytes.length >= 30) {
    const chunk = ascii(bytes, 12, 16);
    if (chunk === "VP8 ") return size(bytes.readUInt16LE(26) & 0x3fff, bytes.readUInt16LE(28) & 0x3fff);
    if (chunk === "VP8L" && bytes[20] === 0x2f) {
      const bits = bytes.readUInt32LE(21);
      return size((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
    }
    if (chunk === "VP8X") return size(1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)), 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)));
  }
  return null;
}

// Ranges

/// Rack's reading of a Range header: null for the whole file, otherwise the inclusive `[start, end]` pairs, which are empty when unsatisfiable.
export function byteRanges(header, size) {
  if (typeof header !== "string" || size === 0) return null;
  const spec = /bytes=([^;]+)/.exec(header);
  if (!spec) return null;
  if ((spec[1].match(/,/g) ?? []).length >= 100) return null;
  const ranges = [];
  for (const part of spec[1].split(/,\s*/)) {
    const match = /(\d*)-(\d*)/.exec(part);
    if (!match) return null;
    let [, first, last] = match;
    if (first === "") {
      if (last === "") return null;
      first = Math.max(size - Number(last), 0);
      last = size - 1;
    } else {
      first = Number(first);
      if (last === "") last = size - 1;
      else {
        last = Number(last);
        if (last < first) return null;
        if (last >= size) last = size - 1;
      }
    }
    if (first <= last) ranges.push([first, last]);
  }
  const total = ranges.reduce((sum, [first, last]) => sum + last - first + 1, 0);
  return total > size ? [] : ranges;
}

// The store

export class Files {
  secret = randomBytes(32);
  /// Finished files by key.
  objects = new Map();
  /// Uploads by id, finished or not.
  uploads = new Map();

  sign = (key) => createHmac("sha256", this.secret).update(`file:${key}`).digest().subarray(0, 16).toString("base64url");

  isSignature(key, signature) {
    const expected = Buffer.from(this.sign(key));
    const given = Buffer.from(signature);
    return given.length === expected.length && timingSafeEqual(given, expected);
  }

  /// Keeps a finished file and answers the `StoredFile` a message carries.
  keep({ key, name, contentType, bytes, uploadedAt, preview = null }) {
    this.objects.set(key, { key, name, contentType, bytes, uploadedAt, preview });
    const signature = this.sign(key);
    const url = `/files/${key}/${signature}/${addressName(name)}`;
    const stored = { id: key, name, contentType, byteSize: bytes.length };
    const dimensions = imageSize(bytes, contentType);
    const previewed = preview !== null && (PREVIEWED_TYPES.has(contentType) || contentType.startsWith("video"));
    const sized = dimensions ?? (contentType.startsWith("video") && preview ? { width: preview.width, height: preview.height } : null);
    if (sized) Object.assign(stored, sized);
    stored.url = url;
    stored.downloadUrl = `${url}?disposition=attachment`;
    const kept = previewed && sized && (contentType.startsWith("video") || (dimensions && dimensions.width * dimensions.height <= MAX_PIXELS));
    if (kept) stored.previewUrl = `/previews/${key}/${signature}/${addressName(previewName(name, preview.contentType))}`;
    else this.objects.get(key).preview = null;
    return stored;
  }

  /// A new upload for `input`, or `{ status, error }` for what's wrong with it.
  start(roomId, userId, input) {
    const refuse = (status, error) => ({ status, error });
    if (typeof input !== "object" || input === null || Array.isArray(input)) return refuse(422, "Expected a JSON object");
    if (typeof input.name !== "string" || input.name.trim() === "") return refuse(422, "A file needs a name");
    if (input.name.length > 255 || !input.name.isWellFormed()) return refuse(422, "That file's name can't be kept");
    if (typeof input.type !== "string" || input.type.length > 255) return refuse(422, "A file's type must be text");
    if (!Number.isSafeInteger(input.size) || input.size < 0) return refuse(422, "A file's size must be a number of bytes");
    if (input.size > MAX_FILE_BYTES) return refuse(413, "Files must be 250 MB or smaller.");
    const isId = (value) => typeof value === "string" && value.length >= 1 && value.length <= 64;
    if (!isId(input.clientMessageId)) return refuse(422, "A file needs an id for its message");
    if (input.parentId !== undefined && !isId(input.parentId)) return refuse(422, "A reply's thread must be a message's id");
    let id;
    do id = randomKey();
    while (this.uploads.has(id));
    const upload = {
      id,
      roomId,
      uploaderId: userId,
      name: input.name,
      declaredType: input.type,
      size: input.size,
      clientMessageId: input.clientMessageId,
      parentId: input.parentId,
      alsoSend: input.parentId !== undefined && input.alsoSend === true,
      parts: Math.max(1, Math.ceil(input.size / PART_SIZE)),
      received: new Map(),
      preview: null,
      completed: false,
      messageId: null,
    };
    this.uploads.set(id, upload);
    return { upload };
  }

  /// The upload, if `userId` started it in `roomId`.
  find(roomId, userId, id) {
    const upload = this.uploads.get(id);
    return upload && upload.roomId === roomId && upload.uploaderId === userId ? upload : undefined;
  }

  expectedLength = (upload, n) => Math.min(PART_SIZE, upload.size - (n - 1) * PART_SIZE);

  /// A preview image checked as the real server does, answering `{ preview }` or `{ status, error }`.
  checkPreview(bytes) {
    const contentType = magicType(bytes);
    const size = contentType && PREVIEW_EXTENSIONS[contentType] ? imageSize(bytes, contentType) : null;
    if (!size) return { status: 415, error: "A preview is a WebP, JPEG or PNG image" };
    if (size.width > PREVIEW_WIDTH || size.height > PREVIEW_HEIGHT) return { status: 422, error: "A preview fits within 1200×800" };
    return { preview: { bytes, contentType, ...size } };
  }

  /// Joins the parts, keeps the file and answers its `StoredFile`.
  finish(upload, at = Date.now()) {
    const parts = [];
    for (let n = 1; n <= upload.parts; n++) parts.push(upload.received.get(n));
    // One part is the file already; copying it would hold the file twice.
    const bytes = parts.length === 1 ? parts[0] : Buffer.concat(parts);
    const name = sanitizedFilename(upload.name);
    const contentType = sniff(upload.received.get(1).subarray(0, 4096), upload.declaredType, upload.name);
    return this.keep({ key: upload.id, name, contentType, bytes, uploadedAt: at, preview: upload.preview });
  }

  // Serving

  /// Answers `/files/:key/:signature/:name` and `/previews/...`, for GET and HEAD. Anything wrong is the same empty 404.
  serve(req, res, kind, key, signature, url) {
    const missing = () => {
      res.writeHead(404, { "Content-Type": "text/html" });
      res.end();
    };
    if (!KEY.test(key) || !this.isSignature(key, signature) || (req.method !== "GET" && req.method !== "HEAD")) return missing();
    const object = this.objects.get(key);
    const source = kind === "previews" ? object?.preview : object;
    if (!source) return missing();
    const name = kind === "previews" ? previewName(object.name, source.contentType) : object.name;
    const wanted = url.searchParams.getAll("disposition").at(-1) ?? "inline";
    const unsafe = UNSAFE_TYPES.has(source.contentType);
    const disposition = wanted === "attachment" || unsafe || !INLINE_TYPES.has(source.contentType) ? "attachment" : "inline";
    const contentType = unsafe ? "application/octet-stream" : source.contentType;
    const lastModified = new Date(object.uploadedAt).toUTCString();
    const headers = { "Content-Type": contentType, "Content-Disposition": contentDisposition(disposition, name), "Cache-Control": "max-age=3600, public" };
    const bytes = source.bytes;
    const size = bytes.length;
    const send = (status, extra, body) => {
      res.writeHead(status, { ...extra, "Content-Length": body.length });
      res.end(req.method === "HEAD" || body.length === 0 ? undefined : body);
    };

    if (req.headers["if-modified-since"] === lastModified) {
      res.writeHead(304, headers);
      return res.end();
    }
    const ranges = byteRanges(req.headers.range, size);
    if (ranges && ranges.length === 0) {
      return send(416, { ...headers, "Content-Range": `bytes */${size}` }, Buffer.from("Byte range unsatisfiable\n"));
    }
    if (ranges && ranges.length === 1) {
      const [first, last] = ranges[0];
      return send(206, { ...headers, "Content-Range": `bytes ${first}-${last}/${size}` }, bytes.subarray(first, last + 1));
    }
    if (ranges && ranges.length <= MAX_RANGES) {
      const boundary = randomBytes(16).toString("hex");
      const pieces = ranges.map(([first, last]) =>
        Buffer.concat([Buffer.from(`\r\n--${boundary}\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${first}-${last}/${size}\r\n\r\n`), bytes.subarray(first, last + 1)]),
      );
      pieces.push(Buffer.from(`\r\n--${boundary}--\r\n`));
      return send(206, { ...headers, "Content-Type": `multipart/byteranges; boundary=${boundary}` }, Buffer.concat(pieces));
    }
    const modified = Date.parse(req.headers["if-modified-since"] ?? "");
    if (!Number.isNaN(modified) && modified >= Math.floor(object.uploadedAt / 1000) * 1000 && req.headers["if-none-match"] === undefined) {
      const { "Content-Type": _dropped, ...withoutType } = headers;
      res.writeHead(304, { ...withoutType, "Last-Modified": lastModified });
      return res.end();
    }
    send(200, { ...headers, "Last-Modified": lastModified }, bytes);
  }
}

function randomKey() {
  const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
  const bytes = randomBytes(28);
  let out = "";
  for (let i = 0; i < 28; i++) out += alphabet[bytes[i] % 36];
  return out;
}

/// One store for the process, shared by the seed and the routes, so the seeded file's link is signed with the key the server checks.
export const files = new Files();
