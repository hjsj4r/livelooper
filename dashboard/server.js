// ============================================================
//  LIVE LOOPER · dashboard bridge   (pure Node — no npm install)
//
//  SuperCollider --OSC/UDP :57130--> this bridge --SSE--> browser
//  browser --HTTP POST /cmd--> this bridge --OSC/UDP :57120--> SuperCollider
//
//  Run:  node server.js      then open  http://localhost:3000
// ============================================================

const http  = require('http');
const dgram = require('dgram');
const fs    = require('fs');
const path  = require('path');

const HTTP_PORT   = 3000;
// Bound to localhost: this page can record, clear and re-level your tracks, so on a
// venue's open WiFi anyone could drive the rig. Set HTTP_HOST='0.0.0.0' (or run with
// DASH_HOST=0.0.0.0) when you deliberately want it reachable from a tablet on stage.
const HTTP_HOST   = process.env.DASH_HOST || '127.0.0.1';
const SC_HOST     = '127.0.0.1';
const SC_SEND_PORT = 57120;   // sclang listens here (same port SuperDirt uses)
const SC_RECV_PORT = 57130;   // this bridge listens here for SC state

// ---------- minimal OSC (types i, f, s) ----------
const align4 = n => n + ((4 - (n % 4)) % 4);

function decodeOSC(buf) {
  let i = 0;
  const readStr = () => {
    let end = i;
    while (end < buf.length && buf[end] !== 0) end++;
    const s = buf.toString('ascii', i, end);
    i = align4(end + 1);
    return s;
  };
  const address = readStr();
  let tags = '';
  if (buf[i] === 0x2c /* ',' */) { tags = readStr().slice(1); }
  const args = [];
  for (const t of tags) {
    if (t === 'i') { args.push(buf.readInt32BE(i)); i += 4; }
    else if (t === 'f') { args.push(buf.readFloatBE(i)); i += 4; }
    else if (t === 's') { args.push(readStr()); }
    else if (t === 'd') { args.push(buf.readDoubleBE(i)); i += 8; }
    else { break; }
  }
  return { address, args };
}

function encodeOSC(address, args = []) {
  const parts = [];
  const strBuf = s => { const b = Buffer.alloc(align4(s.length + 1)); b.write(s, 'ascii'); return b; };
  parts.push(strBuf(address));
  let tags = ',';
  const argBufs = [];
  for (const a of args) {
    if (typeof a === 'string') { tags += 's'; argBufs.push(strBuf(a)); }
    else if (Number.isInteger(a)) { tags += 'i'; const b = Buffer.alloc(4); b.writeInt32BE(a); argBufs.push(b); }
    else { tags += 'f'; const b = Buffer.alloc(4); b.writeFloatBE(a); argBufs.push(b); }
  }
  parts.push(strBuf(tags));
  return Buffer.concat([...parts, ...argBufs]);
}

// ---------- UDP: to/from SuperCollider ----------
const udp = dgram.createSocket('udp4');
udp.bind(SC_RECV_PORT, () => console.log(`[OSC] listening for SC on :${SC_RECV_PORT}`));

const sseClients = new Set();
udp.on('message', (msg) => {
  let decoded;
  try { decoded = decodeOSC(msg); } catch (e) { return; }
  const line = `data: ${JSON.stringify(decoded)}\n\n`;
  for (const res of sseClients) { try { res.write(line); } catch (e) {} }
});

function sendToSC(address, args) {
  const buf = encodeOSC(address, args);
  udp.send(buf, 0, buf.length, SC_SEND_PORT, SC_HOST);
}

// ---------- HTTP: serve dashboard, SSE stream, command intake ----------
const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    fs.readFile(path.join(__dirname, 'index.html'), (err, data) => {
      if (err) { res.writeHead(500); res.end('index.html not found'); return; }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(data);
    });
    return;
  }
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });
    res.write('retry: 1000\n\n');
    sseClients.add(res);
    req.on('close', () => sseClients.delete(res));
    return;
  }
  if (req.url === '/cmd' && req.method === 'POST') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { address, args } = JSON.parse(body);
        sendToSC(address, args || []);
        res.writeHead(200); res.end('ok');
      } catch (e) { res.writeHead(400); res.end('bad request'); }
    });
    return;
  }
  res.writeHead(404); res.end('not found');
});

server.listen(HTTP_PORT, HTTP_HOST, () => {
  console.log(`[HTTP] dashboard at  http://localhost:${HTTP_PORT}`);
  console.log(`[HTTP] bound to ${HTTP_HOST}` +
    (HTTP_HOST === '127.0.0.1' ? '  (this machine only — DASH_HOST=0.0.0.0 to open it up)'
                               : '  *** reachable from the network ***'));
  console.log(`[OSC]  sending commands to SC on :${SC_SEND_PORT}`);
});
