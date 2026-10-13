// Servidor de suporte remoto — SEM dependências externas (só Node puro).
// Serve as páginas e faz a sinalização WebRTC. Rode com: node server.js
// Publique em qualquer host Node (Render, Railway, Fly, Glitch) ou numa VPS.

import http from "http";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;
const PUBLIC = path.join(__dirname, "public");

// ---------- STUN/TURN entregues ao navegador ----------
function iceServers() {
  const list = [{ urls: "stun:stun.l.google.com:19302" }];
  if (process.env.TURN_URL) {
    list.push({
      urls: process.env.TURN_URL.split(","),
      username: process.env.TURN_USER || "",
      credential: process.env.TURN_PASS || "",
    });
  }
  return list;
}

// ---------- Sessões em memória (produção séria: Redis com TTL) ----------
const ALPHA = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const sessions = new Map();
function makeCode() {
  const b = crypto.randomBytes(8);
  let s = "";
  for (let i = 0; i < 8; i++) s += ALPHA[b[i] % ALPHA.length];
  return s.slice(0, 4) + "-" + s.slice(4, 8);
}
setInterval(() => {
  const now = Date.now();
  for (const [c, s] of sessions) if (s.expiresAt < now && s.status !== "connected") sessions.delete(c);
}, 30000);

// ---------- HTTP: páginas + API ----------
const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml", ".ico": "image/x-icon" };

function sendFile(res, file) {
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("Não encontrado"); return; }
    res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
    res.end(data);
  });
}
function json(res, code, obj) { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(obj)); }

const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://" + (req.headers.host || "localhost"));
  const p = u.pathname;

  // API: criar convite
  if (p === "/api/sessions" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => { body += c; if (body.length > 1e4) req.destroy(); });
    req.on("end", () => {
      let d = {}; try { d = JSON.parse(body || "{}"); } catch {}
      const minutes = Math.min(60, Math.max(1, parseInt(d.minutes, 10) || 15));
      const code = makeCode();
      sessions.set(code, { createdAt: Date.now(), expiresAt: Date.now() + minutes * 60000, label: String(d.label || "cliente").slice(0, 80), status: "pending" });
      const base = (req.headers["x-forwarded-proto"] || "http") + "://" + req.headers.host;
      json(res, 200, { code, url: base + "/s/" + code, expiresInMin: minutes });
    });
    return;
  }
  if (p.startsWith("/api/sessions/") && req.method === "GET") {
    const s = sessions.get(p.split("/").pop());
    return s ? json(res, 200, { status: s.status, label: s.label, expiresAt: s.expiresAt }) : json(res, 404, { error: "not_found" });
  }
  if (p === "/api/ice") return json(res, 200, { iceServers: iceServers() });

  // Página do cliente: /s/CODIGO
  if (p.startsWith("/s/")) return sendFile(res, path.join(PUBLIC, "cliente.html"));

  // Estáticos
  let file = p === "/" ? "index.html" : p.replace(/^\/+/, "");
  file = path.normalize(file).replace(/^(\.\.(\/|\\|$))+/, ""); // anti path traversal
  const full = path.join(PUBLIC, file);
  if (!full.startsWith(PUBLIC)) { res.writeHead(403); return res.end("proibido"); }
  sendFile(res, full);
});

// ---------- WebSocket (RFC 6455) sem biblioteca ----------
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const rooms = new Map(); // code -> { publisher, viewer }

function wsSend(sock, obj) {
  if (!sock || sock.destroyed) return;
  const data = Buffer.from(JSON.stringify(obj));
  const len = data.length;
  let header;
  if (len < 126) { header = Buffer.from([0x81, len]); }
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
  sock.write(Buffer.concat([header, data]));
}

server.on("upgrade", (req, socket) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname !== "/signal") { socket.destroy(); return; }
  const key = req.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1").update(key + GUID).digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
  );

  const conn = { socket, role: null, code: null };
  let buf = Buffer.alloc(0);

  socket.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    // Parse de frames de texto mascarados (cliente -> servidor)
    while (buf.length >= 2) {
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f, offset = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); offset = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); offset = 10; }
      const need = offset + (masked ? 4 : 0) + len;
      if (buf.length < need) return;
      let payload;
      if (masked) {
        const mask = buf.slice(offset, offset + 4);
        payload = Buffer.alloc(len);
        for (let i = 0; i < len; i++) payload[i] = buf[offset + 4 + i] ^ mask[i & 3];
      } else payload = buf.slice(offset, offset + len);
      buf = buf.slice(need);

      if (opcode === 0x8) { socket.end(); return; }        // close
      if (opcode === 0x9) { continue; }                     // ping (ignorado)
      if (opcode === 0x1) onMessage(conn, payload.toString("utf8"));
    }
  });

  socket.on("close", () => onClose(conn));
  socket.on("error", () => onClose(conn));
});

function onMessage(conn, raw) {
  let m; try { m = JSON.parse(raw); } catch { return; }

  if (m.t === "join") {
    const s = sessions.get(m.code);
    if (!s) return wsSend(conn.socket, { t: "error", reason: "Sessão inexistente ou expirada" });
    if (s.expiresAt < Date.now() && s.status !== "connected") return wsSend(conn.socket, { t: "error", reason: "Link expirado" });
    if (m.role !== "publisher" && m.role !== "viewer") return wsSend(conn.socket, { t: "error", reason: "papel inválido" });
    const room = rooms.get(m.code) || {};
    if (room[m.role]) return wsSend(conn.socket, { t: "error", reason: "Já há um " + m.role + " nesta sessão" });
    room[m.role] = conn; rooms.set(m.code, room);
    conn.role = m.role; conn.code = m.code;
    wsSend(conn.socket, { t: "joined", role: m.role, iceServers: iceServers() });
    if (room.publisher && room.viewer) {
      s.status = "connected";
      wsSend(room.publisher.socket, { t: "viewer-ready" });
      wsSend(room.viewer.socket, { t: "peer-online" });
    }
    return;
  }

  if (["offer", "answer", "ice", "bye", "stats"].includes(m.t) && conn.code) {
    const room = rooms.get(conn.code);
    if (!room) return;
    const peer = conn.role === "publisher" ? room.viewer : room.publisher;
    if (peer) wsSend(peer.socket, m);
  }
}

function onClose(conn) {
  if (!conn.code) return;
  const room = rooms.get(conn.code);
  if (!room) return;
  const peer = conn.role === "publisher" ? room.viewer : room.publisher;
  if (peer) wsSend(peer.socket, { t: "bye", reason: conn.role === "publisher" ? "cliente saiu" : "atendente saiu" });
  if (room[conn.role] === conn) delete room[conn.role];
  if (!room.publisher && !room.viewer) {
    rooms.delete(conn.code);
    const s = sessions.get(conn.code);
    if (s) s.status = "ended";
  }
}

server.listen(PORT, () => console.log("Suporte Remoto no ar em http://localhost:" + PORT));
