#!/usr/bin/env node
// Circuit server: analyzes a repo, serves the 3D UI, re-grades live on file changes.
//   node server.js [repoPath] [--port 8901]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from './lib/analyze.js';
import { LANG_BY_EXT } from './lib/walk.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(__dirname, 'public');

const args = process.argv.slice(2);
let root = process.cwd();
let port = 8923;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port') port = Number(args[++i]);
  else if (!args[i].startsWith('-')) root = path.resolve(args[i]);
}
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`Invalid --port value. Usage: circuit [repoPath] [--port 1-65535]`);
  process.exit(1);
}
if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
  console.error(`Not a directory: ${root}`);
  process.exit(1);
}
const realRoot = fs.realpathSync(root);

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon',
};

let graph = null;
let lastError = null;
const sseClients = new Set();

// analyzeRepo is synchronous — requests queue behind it for the few hundred ms
// a scan takes, which also makes re-entrancy impossible.
function analyze(reason = 'startup') {
  try {
    graph = analyzeRepo(root);
    lastError = null;
    console.log(`[circuit] analyzed ${graph.stats.files} files, ${graph.stats.edges} edges (${graph.stats.brokenEdges} broken) — grade ${graph.stats.grade} (${graph.stats.score}) in ${graph.tookMs}ms [${reason}]`);
    broadcast('graph', { generatedAt: graph.generatedAt, reason });
  } catch (e) {
    // Only the message string may reach clients — never the exception object
    // itself (CodeQL js/stack-trace-exposure: stack frames leak file paths).
    lastError = e instanceof Error ? e.message : String(e ?? 'analyze failed');
    console.error('[circuit] analyze failed:', e);
    broadcast('error', { message: lastError, reason });
  }
}

function broadcast(event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of sseClients) res.write(payload);
}

// Watch for changes (macOS/Windows support recursive fs.watch), debounce, re-analyze.
const WATCH_IGNORE = /(^|\/)(\.[^/]+|node_modules|dist|build|DerivedData|__pycache__|venv|coverage|Pods)(\/|$)/;
let watchTimer = null;
try {
  fs.watch(root, { recursive: true }, (_evt, filename) => {
    if (!filename || WATCH_IGNORE.test(filename)) return;
    if (!(path.extname(filename).toLowerCase() in LANG_BY_EXT)) return;
    clearTimeout(watchTimer);
    watchTimer = setTimeout(() => analyze(`change: ${filename}`), 1200);
  });
} catch (e) {
  console.warn('[circuit] file watching unavailable:', e.message);
}

function send(res, status, body, type = 'application/json') {
  const buf = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
  res.end(buf);
}

const server = http.createServer((req, res) => {
  try {
    handle(req, res);
  } catch (e) {
    console.error('[circuit] request error:', e.message);
    if (!res.headersSent) send(res, 400, { error: 'bad request' });
    else res.end();
  }
});

function handle(req, res) {
  const url = new URL(req.url, `http://localhost:${port}`);

  if (url.pathname === '/api/graph') {
    if (!graph) return send(res, lastError ? 500 : 503, { error: lastError ?? 'analyzing' });
    return send(res, 200, graph);
  }

  if (url.pathname === '/api/rescan' && req.method === 'POST') {
    analyze('manual rescan');
    return send(res, 200, { ok: true });
  }

  if (url.pathname === '/api/file') {
    const rel = url.searchParams.get('path') ?? '';
    const abs = path.resolve(root, rel);
    if (!abs.startsWith(root + path.sep) && abs !== root) return send(res, 403, { error: 'outside repo' });
    try {
      // resolve symlinks before the containment check — a link inside the repo
      // must not read files outside it
      const real = fs.realpathSync(abs);
      if (!real.startsWith(realRoot + path.sep) && real !== realRoot) return send(res, 403, { error: 'outside repo' });
      const st = fs.statSync(real);
      if (!st.isFile() || st.size > 2_000_000) return send(res, 413, { error: 'too large' });
      return send(res, 200, fs.readFileSync(real, 'utf8'), 'text/plain; charset=utf-8');
    } catch {
      return send(res, 404, { error: 'not found' });
    }
  }

  if (url.pathname === '/api/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive',
    });
    res.write('event: hello\ndata: {}\n\n');
    sseClients.add(res);
    req.on('close', () => sseClients.delete(res));
    return;
  }

  // Static
  let filePath = url.pathname === '/' ? '/index.html' : url.pathname;
  filePath = path.normalize(filePath).replace(/^(\.\.[/\\])+/, '');
  const abs = path.join(PUBLIC, filePath);
  if (!abs.startsWith(PUBLIC)) return send(res, 403, 'forbidden', 'text/plain');
  fs.readFile(abs, (err, buf) => {
    if (err) return send(res, 404, 'not found', 'text/plain');
    send(res, 200, buf, MIME[path.extname(abs).toLowerCase()] ?? 'application/octet-stream');
  });
}

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE' && port < 8999) {
    port++;
    server.listen(port, '127.0.0.1');
  } else {
    console.error('[circuit]', e.message);
    process.exit(1);
  }
});
server.listen(port, '127.0.0.1', () => {
  console.log(`[circuit] grading ${root}`);
  console.log(`[circuit] http://localhost:${port}`);
  analyze();
});
