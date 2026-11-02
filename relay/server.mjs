/**
 * PitHub Relay
 * -------------
 * iPhone 主动用 WebSocket 连到这里（无需公网 IP），relay 分配一个公网地址：
 *
 *   https://relay.example.com/t/<slug>/
 *
 * 公网请求会被转发到 iPhone 的内置 HTTP 服务，响应再按原路返回。
 * 这是“隧道只转发流量、不存储数据”的最小实现，适合自建 VPS。
 *
 * 运行：
 *   RELAY_TOKEN=xxx PUBLIC_BASE_URL=https://relay.example.com PORT=8787 npm start
 *
 * 反向代理需支持 WebSocket（Nginx: proxy_set_header Upgrade $http_upgrade; 等）。
 */

import http from 'node:http';
import { randomBytes, randomUUID } from 'node:crypto';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 8787);
const RELAY_TOKEN = process.env.RELAY_TOKEN || '';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/+$/, '');
const MAX_BODY = Number(process.env.MAX_BODY_BYTES || 24 * 1024 * 1024);
const REQUEST_TIMEOUT_MS = Number(process.env.REQUEST_TIMEOUT_MS || 90000);

if (!RELAY_TOKEN) {
  console.warn('[PitHub Relay] 警告：未设置 RELAY_TOKEN，任何人都可以连接。生产环境必须设置。');
}

/** @type {Map<string, {ws: import('ws').WebSocket, name: string, pending: Map<string, {resolve: Function, timer: NodeJS.Timeout}>, lastSeen: number}>} */
const tunnels = new Map();

const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY * 2 });

function makeSlug() {
  return randomBytes(12).toString('hex');
}

function baseURLFor(req) {
  if (PUBLIC_BASE_URL) return PUBLIC_BASE_URL;
  const proto = (req.headers['x-forwarded-proto'] || 'http').split(',')[0].trim();
  const host = req.headers['x-forwarded-host'] || req.headers.host || `localhost:${PORT}`;
  return `${proto}://${host}`;
}

function sendJSON(ws, object) {
  if (ws.readyState !== ws.OPEN) return;
  ws.send(JSON.stringify(object), (error) => {
    if (error) console.error('[PitHub Relay] send failed:', error.message);
  });
}

/* ---------------- WebSocket 隧道 ---------------- */

wss.on('connection', (ws, req, slug) => {
  const tunnel = {
    ws,
    name: req.tunnelName || 'PitHub',
    pending: new Map(),
    lastSeen: Date.now()
  };
  tunnels.set(slug, tunnel);

  const readyURL = `${baseURLFor(req)}/t/${slug}/`;
  sendJSON(ws, { type: 'ready', url: readyURL });
  console.log(`[PitHub Relay] tunnel online: ${tunnel.name} -> ${readyURL}`);

  ws.on('message', (data) => {
    tunnel.lastSeen = Date.now();
    let message;
    try {
      message = JSON.parse(data.toString());
    } catch {
      return;
    }

    if (message.type === 'ping') {
      sendJSON(ws, { type: 'pong' });
      return;
    }
    if (message.type === 'pong') return;

    if (message.type === 'response' && typeof message.id === 'string') {
      const pending = tunnel.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      tunnel.pending.delete(message.id);
      pending.resolve(message);
    }
  });

  ws.on('pong', () => { tunnel.lastSeen = Date.now(); });

  ws.on('close', () => {
    console.log(`[PitHub Relay] tunnel offline: ${tunnel.name}`);
    tunnels.delete(slug);
    for (const [, pending] of tunnel.pending) {
      clearTimeout(pending.timer);
      pending.resolve({ status: 502, headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: '' });
    }
    tunnel.pending.clear();
  });

  ws.on('error', (error) => {
    console.error('[PitHub Relay] websocket error:', error.message);
  });
});

setInterval(() => {
  const now = Date.now();
  for (const [slug, tunnel] of tunnels) {
    if (now - tunnel.lastSeen > 90000) {
      console.warn(`[PitHub Relay] heartbeat timeout: ${slug}`);
      try { tunnel.ws.terminate(); } catch {}
      tunnels.delete(slug);
      continue;
    }
    if (tunnel.ws.readyState === tunnel.ws.OPEN) {
      try { tunnel.ws.ping(); } catch {}
    }
  }
}, 30000).unref();

/* ---------------- HTTP 服务 ---------------- */

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(Object.assign(new Error('body too large'), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function rewriteLocation(value, slug) {
  if (!value) return value;
  const prefix = `/t/${slug}`;
  try {
    if (value.startsWith('/')) {
      return value.startsWith(prefix) ? value : prefix + value;
    }
    const url = new URL(value);
    if (url.pathname.startsWith('/t/')) return value;
    url.pathname = prefix + url.pathname;
    return url.toString();
  } catch {
    return value;
  }
}

async function handlePublicRequest(req, res, slug) {
  const tunnel = tunnels.get(slug);
  if (!tunnel || tunnel.ws.readyState !== tunnel.ws.OPEN) {
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('PitHub tunnel is offline');
    return;
  }

  const prefix = `/t/${slug}`;
  let path = req.url || '/';
  if (!path.startsWith(prefix)) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }
  path = path.slice(prefix.length) || '/';
  if (!path.startsWith('/')) path = '/' + path;

  let body = Buffer.alloc(0);
  const method = req.method || 'GET';
  if (method !== 'GET' && method !== 'HEAD') {
    try {
      body = await readBody(req);
    } catch (error) {
      res.writeHead(error.statusCode || 400, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Request body too large');
      return;
    }
  }

  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    if (['host', 'connection', 'content-length', 'transfer-encoding', 'upgrade', 'sec-websocket-key', 'sec-websocket-version'].includes(key)) continue;
    if (Array.isArray(value)) headers[key] = value.join(', ');
    else headers[key] = String(value);
  }
  headers['x-forwarded-for'] = String(req.socket.remoteAddress || '');
  headers['x-pithub-tunnel'] = '1';

  const id = randomUUID();
  const responsePromise = new Promise((resolve) => {
    const timer = setTimeout(() => {
      tunnel.pending.delete(id);
      resolve({ status: 504, headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: Buffer.from('PitHub device timeout').toString('base64') });
    }, REQUEST_TIMEOUT_MS);
    tunnel.pending.set(id, { resolve, timer });
  });

  sendJSON(tunnel.ws, {
    type: 'request',
    id,
    method,
    path,
    headers,
    body: body.toString('base64'),
    remote: req.socket.remoteAddress || ''
  });

  const response = await responsePromise;
  const status = Number(response.status) || 502;
  const outHeaders = {};
  for (const [key, value] of Object.entries(response.headers || {})) {
    const lower = key.toLowerCase();
    if (['content-length', 'transfer-encoding', 'connection', 'keep-alive'].includes(lower)) continue;
    if (lower === 'location') {
      outHeaders[key] = rewriteLocation(value, slug);
    } else {
      outHeaders[key] = value;
    }
  }

  let bodyBuffer = Buffer.alloc(0);
  if (response.body) {
    try { bodyBuffer = Buffer.from(response.body, 'base64'); } catch {}
  }
  if (status === 204 || status === 304) bodyBuffer = Buffer.alloc(0);

  outHeaders['Content-Length'] = String(bodyBuffer.length);
  outHeaders['X-PitHub-Relay'] = '1';
  res.writeHead(status, outHeaders);
  if (method === 'HEAD') res.end();
  else res.end(bodyBuffer);
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, tunnels: tunnels.size, time: new Date().toISOString() }));
    return;
  }

  const match = (req.url || '').match(/^\/t\/([a-f0-9]{16,64})(\/.*|\/?)$/);
  if (!match) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('PitHub Relay');
    return;
  }
  const slug = match[1];
  const rest = req.url.slice(`/t/${slug}`.length);
  if (rest === '') {
    res.writeHead(302, { Location: `/t/${slug}/` });
    res.end();
    return;
  }
  handlePublicRequest(req, res, slug).catch((error) => {
    console.error('[PitHub Relay] request failed:', error);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Relay error');
    }
  });
});

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  if (url.pathname !== '/tunnel') {
    socket.destroy();
    return;
  }
  const token = url.searchParams.get('token') || '';
  if (RELAY_TOKEN && token !== RELAY_TOKEN) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  req.tunnelName = (url.searchParams.get('name') || 'PitHub').slice(0, 40);
  const slug = makeSlug();
  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit('connection', ws, req, slug);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[PitHub Relay] listening on :${PORT}`);
  console.log(`[PitHub Relay] public base: ${PUBLIC_BASE_URL || '(auto from request host)'}`);
});
