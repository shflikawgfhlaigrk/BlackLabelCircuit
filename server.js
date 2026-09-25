#!/usr/bin/env node
// Circuit server: analyzes a repo, serves the 3D UI, re-grades live on file changes.
//   node server.js [repoPath] [--port 8901]
// Headless CI mode (no HTTP server):
//   node server.js --check [repoPath] [--min-grade B] [--sarif circuit.sarif]
// Editor mode — the stdio LSP language server for in-editor live re-grade (CI-21):
//   node server.js --lsp [repoPath]   (stdin/stdout speak LSP; see editor/README.md)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from './lib/analyze.js';
import { LANG_BY_EXT } from './lib/walk.js';
import { resolveLicense } from './lib/license.js';
import { runCheck } from './lib/report.js';
import { buildHistory, headSha } from './lib/history.js';
import { createAccess, requestBoundary, readMutation } from './lib/access.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(__dirname, 'public');

const args = process.argv.slice(2);
let root = process.cwd();
let port = 8923;
let checkMode = false;      // headless CI grade-gate mode (--check)
let minGrade = null;        // --min-grade B: fail (exit 1) if repo grades below this
let sarifPath = null;       // --sarif out.sarif: write SARIF findings for CI annotations
let lspMode = false;        // --lsp: run the editor language server on stdin/stdout
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port') port = Number(args[++i]);
  else if (args[i] === '--check') checkMode = true;
  else if (args[i] === '--lsp') lspMode = true;
  else if (args[i] === '--min-grade') minGrade = args[++i];
  else if (args[i] === '--sarif') sarifPath = path.resolve(args[++i]);
  else if (!args[i].startsWith('-')) root = path.resolve(args[i]);
}
// --min-grade / --sarif imply the headless check — you never want a long-lived
// HTTP server in a CI gate.
if (minGrade != null || sarifPath != null) checkMode = true;
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`Invalid --port value. Usage: circuit [repoPath] [--port 1-65535]`);
  process.exit(1);
}
if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
  console.error(`Not a directory: ${root}`);
  process.exit(1);
}

// ---- Editor mode (CI-21): hand stdin/stdout to the stdio LSP language server. ----
// The `await` blocks the module here for the life of the LSP session, so the HTTP
// bootstrap below never runs; when the editor disconnects, the session resolves
// and we exit. The language server itself lives in editor/server.js.
if (lspMode) {
  const { startLsp } = await import('./editor/server.mjs');
  await startLsp({ root });
  process.exit(0);
}

// ---- Headless CI mode: grade, optionally emit SARIF, exit 0/1. No HTTP server. ----
if (checkMode) {
  let r;
  try {
    r = runCheck({ root, minGrade, sarifPath });
  } catch (e) {
    console.error(`[circuit] ${e.message}`);
    process.exit(2);
  }
  if (r.empty) {
    console.log(`[circuit] ${root}: no gradeable source files found — no grade.`);
  } else {
    console.log(`[circuit] ${root}: grade ${r.grade} (${r.score})`);
  }
  if (r.stats.parseErrors > 0) console.log(`[circuit] ${r.stats.parseErrors} file(s) could not be parsed.`);
  if (r.sarifPath) console.log(`[circuit] wrote ${r.sarifResults} finding(s) to ${r.sarifPath}`);
  if (r.minGrade != null) {
    console.log(r.pass
      ? `[circuit] PASS — grade meets minimum ${r.minGrade}.`
      : `[circuit] FAIL — grade is below the minimum ${r.minGrade}.`);
  }
  process.exit(r.exitCode);
}

const realRoot = fs.realpathSync(root);
const access = createAccess({ ownerKey: process.env.CIRCUIT_OWNER_KEY });

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon',
};

let graph = null;
let lastError = null;
const sseClients = new Map();
// Grade-over-history "refactor movie" (CI-20). Building it materializes N commits
// into throwaway worktrees and grades each — expensive, so compute lazily on the
// first /api/history hit and cache it keyed on HEAD (invalidated when new commits
// land). analyzeRepo/buildHistory are synchronous, so no concurrent recompute is
// possible: a second request simply waits behind the first.
let history = null;

// analyzeRepo is synchronous — requests queue behind it for the few hundred ms
// a scan takes, which also makes re-entrancy impossible.
function analyze(reason = 'startup') {
  try {
    graph = analyzeRepo(root);
    lastError = null;
    const g = graph.stats.empty
      ? `no source files to grade`
      : `grade ${graph.stats.grade} (${graph.stats.score})`;
    console.log(`[circuit] analyzed ${graph.stats.files} files, ${graph.stats.edges} edges (${graph.stats.brokenEdges} broken) — ${g} in ${graph.tookMs}ms [${reason}]`);
    broadcast('graph', { generatedAt: graph.generatedAt, reason });
  } catch (e) {
    lastError = String(e?.message ?? e);
    console.error('[circuit] analyze failed:', e);
    broadcast('error', { message: lastError, reason });
  }
}

function broadcast(event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const [res, principal] of sseClients) {
    if (!access.valid(principal)) { res.end(); sseClients.delete(res); }
    else res.write(payload);
  }
}
const sessionTimer = setInterval(() => broadcast('heartbeat', {}), 5000);
sessionTimer.unref();

// Watch for changes (macOS/Windows support recursive fs.watch), debounce, re-analyze.
const WATCH_IGNORE = /(^|\/)(\.[^/]+|node_modules|dist|build|DerivedData|__pycache__|venv|coverage|Pods)(\/|$)/;
let watchTimer = null;
let watcher;
try {
  watcher = fs.watch(root, { recursive: true }, (_evt, filename) => {
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
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(buf);
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Content-Security-Policy', "frame-ancestors 'none'");
  try {
    await handle(req, res);
  } catch (e) {
    // Never echo/log submitted credentials or private request data.
    if (!res.headersSent) send(res, e.status ?? 400, { error: 'bad request' });
    else res.end();
  }
});

async function handle(req, res) {
  if (!requestBoundary(req, port)) return send(res, 403, { error: 'untrusted request origin' });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.origin !== `http://${req.headers.host}`) return send(res, 403, { error: 'untrusted authority' });

  if (url.pathname.startsWith('/api/')) {
    if (url.pathname === '/api/session' && req.method === 'POST') {
      if (req.headers.origin !== `http://${req.headers.host}`) return send(res, 403, { error: 'same-origin sign-in required' });
      const body = await readMutation(req);
      const cookie = access.exchange(body.handoff);
      if (!cookie) return send(res, 401, { error: 'Open Circuit again for a fresh sign-in link' });
      res.setHeader('Set-Cookie', cookie);
      return send(res, 200, { ok: true });
    }
    const principal = access.principal(req);
    if (!principal) return send(res, 401, { error: 'Sign in to Circuit' });
    req.circuitPrincipal = principal;
    if (req.method !== 'GET') {
      if (req.method !== 'POST' || !['/api/rescan', '/api/logout'].includes(url.pathname)) return send(res, 405, { error: 'method not allowed' });
      if (principal.kind === 'session' && req.headers.origin !== `http://${req.headers.host}`) return send(res, 403, { error: 'same-origin request required' });
      await readMutation(req);
      // Recheck after reading the body: logout/expiry may have happened while waiting.
      if (!access.valid(principal)) return send(res, 401, { error: 'Sign in to Circuit' });
    }
    if (url.pathname === '/api/session') return send(res, 200, { authenticated: true });
    if (url.pathname === '/api/logout' && req.method === 'POST') {
      access.logout(principal);
      res.setHeader('Set-Cookie', access.clearCookie);
      broadcast('heartbeat', {});
      return send(res, 200, { ok: true });
    }
    if (url.pathname === '/api/rescan' && req.method !== 'POST') return send(res, 405, { error: 'use POST' });
  } else if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method not allowed' });

  if (url.pathname === '/api/license') {
    // Fail-closed: resolves to demo mode unless a valid license key is set.
    return send(res, 200, resolveLicense());
  }

  if (url.pathname === '/api/graph') {
    if (!graph) return send(res, lastError ? 500 : 503, { error: lastError ?? 'analyzing' });
    return send(res, 200, graph);
  }

  if (url.pathname === '/api/rescan' && req.method === 'POST') {
    analyze('manual rescan');
    return send(res, 200, { ok: true });
  }

  // Grade-over-history timeline (CI-20). Returns { supported:false, reason } for
  // repos with no/one commit, so the UI can honestly say "nothing to replay".
  if (url.pathname === '/api/history') {
    const head = headSha(root);
    if (head && history && history.head === head) return send(res, 200, history);
    try {
      history = buildHistory(root, { log: (m) => console.log(m) });
      return send(res, 200, history);
    } catch (e) {
      console.error('[circuit] history failed:', e.message);
      return send(res, 500, { supported: false, reason: e.message, commits: [] });
    }
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
    sseClients.set(res, req.circuitPrincipal);
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
// Private parent IPC supports graceful lifecycle management of isolated children;
// there is deliberately no HTTP shutdown endpoint.
if (process.send) process.on('message', (message) => {
  if (message?.type !== 'circuit:shutdown') return;
  watcher?.close();
  clearTimeout(watchTimer);
  clearInterval(sessionTimer);
  for (const res of sseClients.keys()) res.end();
  server.closeAllConnections();
  server.close(() => process.exit(0));
});
// Air-gap / offline-mode posture (CI-18): bind to loopback only. Circuit makes no
// outbound network calls (attestable via the CI-15 source scan / test/airgap.test.js)
// — source code never leaves the machine. Safe for regulated, air-gapped installs.
server.listen(port, '127.0.0.1', () => {
  console.log(`[circuit] grading ${root}`);
  console.log(`[circuit] ${access.launchURL(port)}`);
  console.log(`[circuit] offline: loopback-only, no outbound network (air-gap ready — see AIRGAP.md)`);
  // Defer the first scan to the next tick so the HTTP server can serve the UI
  // shell (and the first /api/graph poll → "analyzing…") immediately. On a large
  // repo the synchronous scan would otherwise block the very first paint, leaving
  // the freshly-opened window blank with no feedback until the scan finished.
  setImmediate(analyze);
});
