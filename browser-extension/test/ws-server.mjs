// Minimal RFC 6455 WebSocket server (text frames, ping/pong, close) so the
// tests can stand in for the Mac app without adding a dependency.
import net from "node:net";
import crypto from "node:crypto";
import { EventEmitter } from "node:events";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export class WSServer extends EventEmitter {
  constructor() {
    super();
    this.clients = new Set();
    this.server = net.createServer((sock) => this._accept(sock));
  }
  listen() {
    return new Promise((r) => this.server.listen(0, "127.0.0.1", () => r(this.server.address().port)));
  }
  close() { for (const c of this.clients) c.sock.destroy(); this.server.close(); }

  _accept(sock) {
    let buf = Buffer.alloc(0);
    let upgraded = false;
    const client = { sock, send: (obj) => sock.write(encodeText(JSON.stringify(obj))), headers: {} };
    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (!upgraded) {
        const end = buf.indexOf("\r\n\r\n");
        if (end < 0) return;
        const head = buf.slice(0, end).toString();
        buf = buf.slice(end + 4);
        const lines = head.split("\r\n");
        for (const l of lines.slice(1)) { const i = l.indexOf(":"); if (i > 0) client.headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim(); }
        const key = client.headers["sec-websocket-key"];
        const accept = crypto.createHash("sha1").update(key + GUID).digest("base64");
        sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        upgraded = true;
        this.clients.add(client);
        this.emit("connection", client);
      }
      for (;;) {
        const f = decodeFrame(buf);
        if (!f) break;
        buf = buf.slice(f.size);
        if (f.opcode === 1) this.emit("message", client, f.payload.toString());
        else if (f.opcode === 9) sock.write(encodeFrame(0xA, f.payload));
        else if (f.opcode === 8) { sock.end(encodeFrame(0x8, Buffer.alloc(0))); }
      }
    });
    sock.on("close", () => { this.clients.delete(client); this.emit("close", client); });
    sock.on("error", () => {});
  }
}

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) header = Buffer.from([0x80 | opcode, len]);
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([header, payload]);
}
export function encodeText(s) { return encodeFrame(0x1, Buffer.from(s)); }

function decodeFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let len = buf[1] & 0x7f;
  let off = 2;
  if (len === 126) { if (buf.length < 4) return null; len = buf.readUInt16BE(2); off = 4; }
  else if (len === 127) { if (buf.length < 10) return null; len = Number(buf.readBigUInt64BE(2)); off = 10; }
  const maskKey = masked ? buf.slice(off, off + 4) : null;
  if (masked) off += 4;
  if (buf.length < off + len) return null;
  const payload = Buffer.from(buf.slice(off, off + len));
  if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= maskKey[i % 4];
  return { opcode, payload, size: off + len };
}
