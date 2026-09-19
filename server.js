#!/usr/bin/env node
// Circuit server: analyzes a repo, serves the 3D UI, re-grades live on file changes.
//   node server.js [repoPath] [--port 8901]
// Headless CI mode (no HTTP server):
//   node server.js --check [repoPath] [--min-grade B] [--sarif circuit.sarif]
// Editor mode — the stdio LSP language server for in-editor live re-grade (CI-21):
//   node server.js --lsp [repoPath]   (stdin/stdout speak LSP; see editor/README.md)
// Windows port check (no HTTP server): what runs on Windows as-is and which Windows
// parts are needed first. --min-ready N fails (exit 1) below N% ready app code:
//   node server.js --port-check [repoPath] [--json port.json] [--min-ready 80]
// Convert for Windows (no HTTP server): writes a converted, buildable copy of the app
// code to --out (the repo itself is never modified). --verify has the Swift compiler
// decide, file by file, what really builds in the Windows configuration:
//   node server.js --convert [repoPath] --out <dir> [--verify] [--sources Sources,Shared]
//                  [--exclude path,…] [--module Name] [--json convert.json]
// Re-check an already converted package with this machine's compiler (what a Windows
// PC or CI runner runs — the native verdict):
//   node server.js --reverify <convertedDir> [--json convert.json]
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from './lib/analyze.js';
import { LANG_BY_EXT } from './lib/walk.js';
import { resolveLicense } from './lib/license.js';
import { runCheck } from './lib/report.js';
import { buildHistory, headSha } from './lib/history.js';
import { portCheck, formatPortReport } from './lib/port.js';
import { convertRepo, reverifyConverted, recountConverted, formatConvertReport } from './lib/convert.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(__dirname, 'public');

const args = process.argv.slice(2);
let root = process.cwd();
let port = 8923;
let checkMode = false;      // headless CI grade-gate mode (--check)
let minGrade = null;        // --min-grade B: fail (exit 1) if repo grades below this
let sarifPath = null;       // --sarif out.sarif: write SARIF findings for CI annotations
let lspMode = false;        // --lsp: run the editor language server on stdin/stdout
let portMode = false;       // --port-check: Windows port report, no HTTP server
let portJson = null;        // --json out.json: write the full port report
let minReady = null;        // --min-ready 80: fail (exit 1) below this % of ready app code
let portTarget = 'windows'; // --target: the platform the port check measures against
let convertMode = false;    // --convert: write a converted copy for the target, no HTTP server
let convertOut = null;      // --out <dir>: where the converted copy goes (outside the repo)
let convertVerify = false;  // --verify: build it; the compiler decides what converted
let convertSources = null;  // --sources a,b: the folders that make up the desktop app module
let convertExclude = [];    // --exclude a,b: paths to leave out of the module
let convertModule = null;   // --module Name: the Swift module name of the converted package
let reverifyMode = false;   // --reverify <convertedDir>: compiler check on an existing conversion
let recountMode = false;    // --recount <convertedDir>: rewrite the report from the files, no build
let kitSelfTestMode = false; // --kit-selftest --out <dir> [-- args]: build + run the CircuitPortKit self-test
let kitSelfTestArgs = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port') port = Number(args[++i]);
  else if (args[i] === '--check') checkMode = true;
  else if (args[i] === '--lsp') lspMode = true;
  else if (args[i] === '--min-grade') minGrade = args[++i];
  else if (args[i] === '--sarif') sarifPath = path.resolve(args[++i]);
  else if (args[i] === '--port-check') portMode = true;
  else if (args[i] === '--json') portJson = path.resolve(args[++i]);
  else if (args[i] === '--min-ready') minReady = Number(args[++i]);
  else if (args[i] === '--target') portTarget = args[++i];
  else if (args[i] === '--convert') convertMode = true;
  else if (args[i] === '--reverify') reverifyMode = true;
  else if (args[i] === '--recount') recountMode = true;
  else if (args[i] === '--kit-selftest') kitSelfTestMode = true;
  else if (args[i] === '--') { kitSelfTestArgs = args.slice(i + 1); break; }
  else if (args[i] === '--out') convertOut = path.resolve(args[++i]);
  else if (args[i] === '--verify') convertVerify = true;
  else if (args[i] === '--sources') convertSources = args[++i].split(',').map((x) => x.trim()).filter(Boolean);
  else if (args[i] === '--exclude') convertExclude = args[++i].split(',').map((x) => x.trim()).filter(Boolean);
  else if (args[i] === '--module') convertModule = args[++i];
  else if (!args[i].startsWith('-')) root = path.resolve(args[i]);
}
// ---- The kit's own test: the Keychain calls as converted apps make them, on this platform. ----
if (kitSelfTestMode) {
  const { runKitSelfTest } = await import('./lib/convert.js');
  const dir = convertOut ?? fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-kit-selftest-'));
  const r = runKitSelfTest(dir, { args: kitSelfTestArgs, log: (m) => console.log(`[circuit] ${m}`) });
  console.log(r.output.trimEnd());
  if (r.spawnError) console.error(`[circuit] swift could not be run: ${r.spawnError}`);
  console.log(`[circuit] kit self-test ${r.ok ? 'PASSED' : 'FAILED'} — ${r.passed} passed, ${r.failed} failed (${r.store})`);
  process.exit(r.ok ? 0 : 1);
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

// ---- Recount: the report of a converted package, recomputed from its files (no build). ----
if (recountMode) {
  try {
    console.log(formatConvertReport(recountConverted(root)));
  } catch (e) {
    console.error(`[circuit] ${e.message}`);
    process.exit(2);
  }
  process.exit(0);
}

// ---- Re-verify a converted package natively (the Windows-side half of Convert). ----
if (reverifyMode) {
  let r;
  try {
    r = reverifyConverted(root, { log: (m) => console.log(`[circuit] ${m}`) });
  } catch (e) {
    console.error(`[circuit] ${e.message}`);
    process.exit(2);
  }
  console.log(formatConvertReport(r));
  if (portJson) fs.writeFileSync(portJson, JSON.stringify(r, null, 2));
  process.exit(r.verification.ok ? 0 : 1);
}

// ---- Convert: converted copy + compiler verdict. Exit 0 only when what it claims builds. ----
if (convertMode) {
  if (!convertOut) {
    console.error('Usage: circuit --convert [repoPath] --out <dir> [--verify] [--sources a,b] [--exclude a,b] [--module Name]');
    process.exit(2);
  }
  let r;
  try {
    r = convertRepo(root, {
      target: portTarget, out: convertOut, verify: convertVerify, sources: convertSources,
      exclude: convertExclude, moduleName: convertModule, log: (m) => console.log(`[circuit] ${m}`),
    });
  } catch (e) {
    console.error(`[circuit] ${e.message}`);
    process.exit(2);
  }
  console.log(formatConvertReport(r));
  if (portJson) {
    fs.writeFileSync(portJson, JSON.stringify(r, null, 2));
    console.log(`[circuit] wrote the full conversion report to ${portJson}`);
  }
  process.exit(r.verification.ran && !r.verification.ok ? 1 : 0);
}

// ---- Windows port check: report, optional JSON, optional gate. No HTTP server. ----
if (portMode) {
  if (minReady != null && !(Number.isFinite(minReady) && minReady >= 0 && minReady <= 100)) {
    console.error('Invalid --min-ready value (0-100).');
    process.exit(2);
  }
  let r;
  try {
    r = portCheck(root, { target: portTarget });
  } catch (e) {
    console.error(`[circuit] ${e.message}`);
    process.exit(2);
  }
  console.log(formatPortReport(r));
  if (portJson) {
    fs.writeFileSync(portJson, JSON.stringify(r, null, 2));
    console.log(`[circuit] wrote the full port report to ${portJson}`);
  }
  if (minReady != null) {
    const ready = r.summary.app.readyPct ?? 0;
    const pass = ready >= minReady;
    console.log(pass
      ? `[circuit] PASS — ${ready}% of app code runs on ${portTarget} as-is (minimum ${minReady}%).`
      : `[circuit] FAIL — ${ready}% of app code runs on ${portTarget} as-is, below the minimum ${minReady}%.`);
    process.exit(pass ? 0 : 1);
  }
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

// Started by the app shell (CIRCUIT_PARENT_WATCH=1): the shell holds the other end of
// our stdin. If it goes away without its exit handler running — a kill, a crash — the
// pipe closes and we leave with it, so no orphaned server keeps the port. A terminal
// run never sets the variable, so piping or closing stdin there changes nothing.
if (process.env.CIRCUIT_PARENT_WATCH === '1') {
  const leave = () => process.exit(0);
  process.stdin.on('end', leave);
  process.stdin.on('close', leave);
  process.stdin.on('error', leave);
  process.stdin.resume();
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon',
};

let graph = null;
// Client-safe failure record: a correlation id ONLY. Nothing derived from the
// exception is kept here — see analyze().
let lastFailure = null;
const sseClients = new Set();
// Grade-over-history "refactor movie" (CI-20). Building it materializes N commits
// into throwaway worktrees and grades each — expensive, so compute lazily on the
// first /api/history hit and cache it keyed on HEAD (invalidated when new commits
// land). analyzeRepo/buildHistory are synchronous, so no concurrent recompute is
// possible: a second request simply waits behind the first.
let history = null;
// Windows port report (lazy, cached per analyzed graph — a rescan invalidates it).
let portReport = null;
// Convert run started from the UI. It runs as a child process of this same program
// (`--convert … --verify`), so minutes of compiling never block the server; its
// output lines are streamed to the page and the result is read back from its JSON.
const convertJob = { running: false, log: [], result: null, error: null, out: null, startedAt: null };

function convertOutDir() {
  // CIRCUIT_CONVERT_DIR moves the output root (tests, shared build machines).
  const base = process.env.CIRCUIT_CONVERT_DIR || path.join(os.homedir(), 'Circuit Converted');
  return path.join(base, `${path.basename(root)}-windows`);
}

function startConvert({ verify }) {
  const out = convertOutDir();
  fs.mkdirSync(out, { recursive: true });
  const resultPath = path.join(out, 'conversion.json');
  Object.assign(convertJob, { running: true, log: [], result: null, error: null, out, startedAt: Date.now() });
  const childArgs = [fileURLToPath(import.meta.url), '--convert', root, '--out', out];
  if (verify) childArgs.push('--verify');
  const child = spawn(process.execPath, childArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
  const onData = (buf) => {
    for (const line of String(buf).split('\n')) {
      const text = line.replace(/^\[circuit\] /, '').trimEnd();
      if (!text || text.startsWith('swift build ')) continue;
      convertJob.log.push(text);
      if (convertJob.log.length > 400) convertJob.log.shift();
      broadcast('convert', { line: text });
    }
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  child.on('error', (e) => {
    const f = failed('starting the conversion', e);
    convertJob.running = false;
    convertJob.error = f.message;
    broadcast('convert-done', { ok: false, error: f.message, errorId: f.errorId });
  });
  child.on('close', (code) => {
    convertJob.running = false;
    try { convertJob.result = JSON.parse(fs.readFileSync(resultPath, 'utf8')); } catch { convertJob.result = null; }
    if (code === 2 || !convertJob.result) convertJob.error = convertJob.log[convertJob.log.length - 1] ?? `convert exited with code ${code}`;
    broadcast('convert-done', { ok: !convertJob.error, error: convertJob.error });
  });
}

// The single message any client is allowed to see when a scan fails. The real
// cause (with stack) is on the server console under the correlation id.
const ANALYZE_FAILED_MESSAGE = 'analysis failed — see the Circuit server log for details';

// Every other endpoint fails the same way: the full error goes to the server console
// under a correlation id; the client gets a fixed message and the id, never text
// derived from the exception (see analyze()).
function failed(what, e) {
  const errorId = randomUUID();
  console.error(`[circuit] ${what} failed [${errorId}]:`, e);
  return { message: `${what} failed — see the Circuit server log for details`, errorId };
}

// analyzeRepo is synchronous — requests queue behind it for the few hundred ms
// a scan takes, which also makes re-entrancy impossible.
function analyze(reason = 'startup') {
  try {
    graph = analyzeRepo(root);
    portReport = null;
    lastFailure = null;
    const g = graph.stats.empty
      ? `no source files to grade`
      : `grade ${graph.stats.grade} (${graph.stats.score})`;
    console.log(`[circuit] analyzed ${graph.stats.files} files, ${graph.stats.edges} edges (${graph.stats.brokenEdges} broken) — ${g} in ${graph.tookMs}ms [${reason}]`);
    broadcast('graph', { generatedAt: graph.generatedAt, reason });
  } catch (e) {
    // CodeQL js/stack-trace-exposure: NOTHING derived from the exception may reach
    // a client — not e.stack, not e.message, not String(e). An earlier attempt kept
    // `e instanceof Error ? e.message : String(e)`, which still leaked: analyzer
    // messages quote absolute repo paths, and String(e) on a non-Error throw can
    // carry a whole stack. The full error goes to the server console under a
    // correlation id; the client gets the id and a fixed message, nothing else.
    const errorId = randomUUID();
    lastFailure = { errorId };
    console.error(`[circuit] analyze failed [${errorId}] [${reason}]:`, e);
    broadcast('error', { message: ANALYZE_FAILED_MESSAGE, errorId, reason });
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

  if (url.pathname === '/api/license') {
    // Fail-closed: resolves to demo mode unless a valid license key is set.
    return send(res, 200, resolveLicense());
  }

  if (url.pathname === '/api/graph') {
    if (!graph) {
      return lastFailure
        ? send(res, 500, { error: ANALYZE_FAILED_MESSAGE, errorId: lastFailure.errorId })
        : send(res, 503, { error: 'analyzing' });
    }
    return send(res, 200, graph);
  }

  // Windows port check (per-file status + the Windows parts needed), computed on
  // first request after each analysis. Same offline posture as the grader.
  if (url.pathname === '/api/port') {
    if (!portReport || portReport.generatedAtGraph !== graph?.generatedAt) {
      try {
        portReport = { ...portCheck(root, { target: 'windows' }), generatedAtGraph: graph?.generatedAt ?? null };
      } catch (e) {
        const f = failed('port check', e);
        return send(res, 500, { error: f.message, errorId: f.errorId });
      }
    }
    return send(res, 200, portReport);
  }

  // Convert for Windows. POST starts a run (one at a time); GET reports it. The
  // converted copy is written under ~/Circuit Converted — never into the repo.
  if (url.pathname === '/api/convert') {
    if (req.method === 'POST') {
      if (convertJob.running) return send(res, 409, { error: 'a conversion is already running' });
      const verify = url.searchParams.get('verify') !== '0';
      startConvert({ verify });
      return send(res, 202, { started: true, out: convertJob.out, verify });
    }
    if (!convertJob.running && !convertJob.result) {
      // a conversion finished in an earlier launch is still on disk: show it
      try { convertJob.result = JSON.parse(fs.readFileSync(path.join(convertOutDir(), 'conversion.json'), 'utf8')); convertJob.out = convertOutDir(); } catch { /* none yet */ }
    }
    return send(res, 200, {
      running: convertJob.running, out: convertJob.out ?? convertOutDir(), startedAt: convertJob.startedAt,
      log: convertJob.log.slice(-60), error: convertJob.error, result: convertJob.result,
    });
  }

  // Reveal the converted copy in the file manager. Only ever opens Convert's own
  // output folder — the path is not taken from the request.
  if (url.pathname === '/api/convert/open' && req.method === 'POST') {
    const dir = convertJob.out ?? convertOutDir();
    if (!fs.existsSync(dir)) return send(res, 404, { error: 'nothing has been converted yet' });
    const opener = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'explorer.exe' : 'xdg-open';
    try {
      spawn(opener, [dir], { detached: true, stdio: 'ignore' }).on('error', () => {}).unref();
    } catch (e) {
      const f = failed('opening the output folder', e);
      return send(res, 500, { error: f.message, errorId: f.errorId });
    }
    return send(res, 200, { ok: true, dir });
  }

  // The written report (CONVERSION.md) of the last conversion.
  if (url.pathname === '/api/convert/report') {
    const file = path.join(convertJob.out ?? convertOutDir(), 'CONVERSION.md');
    try {
      return send(res, 200, fs.readFileSync(file, 'utf8'), 'text/plain; charset=utf-8');
    } catch {
      return send(res, 404, { error: 'nothing has been converted yet' });
    }
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
      const f = failed('history', e);
      return send(res, 500, { supported: false, reason: f.message, errorId: f.errorId, commits: [] });
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
// Air-gap / offline-mode posture (CI-18): bind to loopback only. Circuit makes no
// outbound network calls (attestable via the CI-15 source scan / test/airgap.test.js)
// — source code never leaves the machine. Safe for regulated, air-gapped installs.
server.listen(port, '127.0.0.1', () => {
  console.log(`[circuit] grading ${root}`);
  console.log(`[circuit] http://localhost:${port}`);
  console.log(`[circuit] offline: loopback-only, no outbound network (air-gap ready — see AIRGAP.md)`);
  // Defer the first scan to the next tick so the HTTP server can serve the UI
  // shell (and the first /api/graph poll → "analyzing…") immediately. On a large
  // repo the synchronous scan would otherwise block the very first paint, leaving
  // the freshly-opened window blank with no feedback until the scan finished.
  setImmediate(analyze);
});
