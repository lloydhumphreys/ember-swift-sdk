// A WebSocket server end of RFC 6455, enough for text frames, on `node:http`'s upgrade event. It is
// hand-written because the stand-in server takes no dependencies.

import { createHash } from "node:crypto";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Frames bigger than this close the socket (1009), so a stray client can't make the server buffer without end.
const MAX_PAYLOAD = 4 * 1024 * 1024;

/// Completes the handshake on `socket` and answers a connection to talk to, or null (after writing a 400) when the request isn't a valid upgrade.
export function acceptWebSocket(req, socket) {
  const key = req.headers["sec-websocket-key"];
  if (typeof key !== "string" || req.headers["sec-websocket-version"] !== "13") {
    socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return null;
  }
  const accept = createHash("sha1").update(key + GUID).digest("base64");
  socket.write(["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${accept}`, "", ""].join("\r\n"));
  return new Connection(socket);
}

/// Refuses an upgrade with a plain HTTP answer, as the real server does for a request it won't upgrade.
export function refuseUpgrade(socket, status, reason, json) {
  const body = JSON.stringify(json);
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
}

export class Connection {
  /// Called with each complete text message.
  onText = () => {};
  /// Called once, with the close code the peer sent (1006 when the connection dropped without one).
  onClose = () => {};

  #socket;
  #buffer = Buffer.alloc(0);
  #fragments = [];
  #fragmentBytes = 0;
  #opcode = 0;
  #closed = false;
  #closeSent = false;

  constructor(socket) {
    this.#socket = socket;
    socket.setNoDelay(true);
    socket.on("data", (chunk) => this.#read(chunk));
    socket.on("error", () => {});
    // The HTTP server allows half-open sockets, so a peer that just vanishes would never produce a close without this.
    socket.on("end", () => socket.end());
    socket.on("close", () => this.#finish(1006));
  }

  get isOpen() {
    return !this.#closed && !this.#closeSent;
  }

  send(text) {
    if (this.isOpen) this.#write(0x1, Buffer.from(text, "utf8"));
  }

  /// Sends a close frame, then ends the connection once the peer has echoed it (or after a second, if it doesn't).
  close(code = 1000, reason = "") {
    if (this.#closed || this.#closeSent) return;
    this.#closeSent = true;
    const reasonBytes = Buffer.from(reason, "utf8");
    const payload = Buffer.alloc(2 + reasonBytes.length);
    payload.writeUInt16BE(code, 0);
    reasonBytes.copy(payload, 2);
    this.#write(0x8, payload);
    setTimeout(() => this.#socket.destroy(), 1000).unref();
  }

  #write(opcode, payload) {
    const length = payload.length;
    let header;
    if (length < 126) header = Buffer.from([0x80 | opcode, length]);
    else if (length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 126;
      header.writeUInt16BE(length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(length), 2);
    }
    if (!this.#socket.destroyed) this.#socket.write(Buffer.concat([header, payload]));
  }

  #finish(code) {
    if (this.#closed) return;
    this.#closed = true;
    this.onClose(code);
  }

  #read(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    for (;;) {
      const buffer = this.#buffer;
      if (buffer.length < 2) return;
      const fin = (buffer[0] & 0x80) !== 0;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        const big = buffer.readBigUInt64BE(2);
        if (big > BigInt(MAX_PAYLOAD)) return this.#fail(1009);
        length = Number(big);
        offset = 10;
      }
      if (length > MAX_PAYLOAD) return this.#fail(1009);
      // Clients must mask what they send; an unmasked frame is a protocol error.
      if (!masked) return this.#fail(1002);
      if (buffer.length < offset + 4 + length) return;
      const mask = buffer.subarray(offset, offset + 4);
      const payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      this.#buffer = buffer.subarray(offset + 4 + length);
      if (!this.#frame(fin, opcode, payload)) return;
    }
  }

  /// Answers whether to keep reading.
  #frame(fin, opcode, payload) {
    if (opcode >= 0x8) {
      if (opcode === 0x9) this.#write(0xa, payload);
      else if (opcode === 0x8) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        if (!this.#closeSent) {
          this.#closeSent = true;
          this.#write(0x8, payload.subarray(0, 2));
        }
        this.#socket.end();
        this.#finish(code);
        return false;
      }
      return true;
    }
    if (opcode === 0x1 || opcode === 0x2) {
      this.#opcode = opcode;
      this.#fragments = [payload];
      this.#fragmentBytes = payload.length;
    } else if (opcode === 0x0) {
      // The cap is on the whole message, not on each piece.
      this.#fragmentBytes += payload.length;
      if (this.#fragmentBytes > MAX_PAYLOAD) {
        this.#fail(1009);
        return false;
      }
      this.#fragments.push(payload);
    } else {
      this.#fail(1002);
      return false;
    }
    if (fin) {
      const whole = Buffer.concat(this.#fragments);
      this.#fragments = [];
      this.#fragmentBytes = 0;
      if (this.#opcode === 0x1 && this.isOpen) this.onText(whole.toString("utf8"));
    }
    return true;
  }

  #fail(code) {
    this.close(code);
    this.#buffer = Buffer.alloc(0);
  }
}
