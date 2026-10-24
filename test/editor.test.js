// CI-21 editor integration: the diagnostics mapping (finding → LSP range/severity)
// and an end-to-end drive of the real stdio LSP server over a fixture repo.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { findingToDiagnostic, nodeToDiagnostics, repoStatus, nodeForRel, LSP_SEVERITY } from '../editor/diagnostics.mjs';
import { analyzeRepo } from '../lib/analyze.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const KOTLIN_FIX = path.join(ROOT, 'test', 'fixtures', 'deeplang', 'kotlin');

// ---------- diagnostics mapping (the tested unit) ----------
test('findingToDiagnostic: 1-based line → 0-based range, severity, dimension + points in message', () => {
  const d = findingToDiagnostic({ dim: 'safety', severity: 'critical', points: 12, line: 15, msg: 'Empty catch block swallows the error.' });
  assert.equal(d.range.start.line, 14, '1-based 15 → 0-based 14');
  assert.equal(d.range.start.character, 0);
  assert.ok(d.range.end.character > d.range.start.character, 'spans the line');
  assert.equal(d.severity, LSP_SEVERITY.critical, 'critical → LSP Error (1)');
  assert.equal(d.source, 'circuit');
  assert.equal(d.code, 'safety', 'code carries the dimension');
  assert.match(d.message, /safety/, 'message carries the dimension');
  assert.match(d.message, /critical/, 'message carries the severity');
  assert.match(d.message, /−12 pts/, 'message carries the point deduction');
});

test('findingToDiagnostic: severity ladder maps critical/major/minor/info → 1/2/3/4', () => {
  assert.equal(findingToDiagnostic({ dim: 'x', severity: 'critical', points: 1 }).severity, 1);
  assert.equal(findingToDiagnostic({ dim: 'x', severity: 'major', points: 1 }).severity, 2);
  assert.equal(findingToDiagnostic({ dim: 'x', severity: 'minor', points: 1 }).severity, 3);
  assert.equal(findingToDiagnostic({ dim: 'x', severity: 'info', points: 1 }).severity, 4);
});

test('findingToDiagnostic: a finding with no line anchors to the first line', () => {
  const d = findingToDiagnostic({ dim: 'complexity', severity: 'major', points: 15, msg: 'branch density' });
  assert.equal(d.range.start.line, 0);
});

test('nodeToDiagnostics maps every finding; a clean/missing node yields none', () => {
  const graph = analyzeRepo(KOTLIN_FIX);
  const app = nodeForRel(graph, 'com/app/App.kt');
  const diags = nodeToDiagnostics(app);
  assert.equal(diags.length, app.findings.length, 'one diagnostic per finding');
  assert.ok(diags.length > 0, 'the flawed file has findings');
  assert.ok(diags.every((d) => d.source === 'circuit'));
  assert.deepEqual(nodeToDiagnostics(null), [], 'no node → no diagnostics');
  assert.deepEqual(nodeToDiagnostics({ missing: true }), [], 'phantom → no diagnostics');
});

test('repoStatus is honest: a graded repo shows its grade, never a fake A+ on empty', () => {
  const graph = analyzeRepo(KOTLIN_FIX);
  assert.match(repoStatus(graph), /^Circuit: [A-F][+-]? \(\d/, 'shows grade (score)');
  assert.equal(repoStatus({ stats: { empty: true } }), 'Circuit: no gradeable source');
  assert.equal(repoStatus({ stats: { grade: null } }), 'Circuit: no gradeable source');
});

// ---------- end-to-end: the real stdio LSP server ----------
// Drive editor/server.js exactly as an editor would: framed JSON-RPC in, framed
// diagnostics out — proving the REAL analyzeRepo powers the language server.
function frame(msg) {
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...msg }), 'utf8');
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}

test('LSP server: didSave re-grades via analyzeRepo and publishes line-anchored diagnostics + a status grade', async () => {
  const serverPath = path.join(ROOT, 'editor', 'server.mjs');
  const proc = spawn(process.execPath, [serverPath, KOTLIN_FIX], { stdio: ['pipe', 'pipe', 'pipe'] });
  const appUri = pathToFileURL(path.join(KOTLIN_FIX, 'com', 'app', 'App.kt')).href;

  const seen = { diags: null, status: null };
  const done = new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => reject(new Error('timed out waiting for diagnostics')), 15000);
    proc.stdout.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      for (;;) {
        const he = buf.indexOf('\r\n\r\n');
        if (he === -1) break;
        const m = buf.slice(0, he).toString('utf8').match(/Content-Length:\s*(\d+)/i);
        if (!m) { buf = buf.slice(he + 4); continue; }
        const len = Number(m[1]); const start = he + 4;
        if (buf.length < start + len) break;
        let msg; try { msg = JSON.parse(buf.slice(start, start + len).toString('utf8')); } catch { msg = null; }
        buf = buf.slice(start + len);
        if (!msg) continue;
        if (msg.method === 'circuit/status') seen.status = msg.params?.text ?? null;
        if (msg.method === 'textDocument/publishDiagnostics' && msg.params?.uri === appUri && msg.params.diagnostics.length) {
          seen.diags = msg.params.diagnostics;
        }
        if (seen.diags && seen.status) { clearTimeout(timer); resolve(); }
      }
    });
    proc.on('error', reject);
  });

  proc.stdin.write(frame({ id: 1, method: 'initialize', params: { rootUri: pathToFileURL(KOTLIN_FIX).href } }));
  proc.stdin.write(frame({ method: 'initialized', params: {} }));
  proc.stdin.write(frame({ method: 'textDocument/didSave', params: { textDocument: { uri: appUri } } }));

  try {
    await done;
  } finally {
    proc.stdin.write(frame({ method: 'exit' }));
    proc.kill();
  }

  assert.ok(seen.diags.length > 0, 'published diagnostics for the saved file');
  assert.ok(seen.diags.every((d) => d.source === 'circuit' && d.range && typeof d.range.start.line === 'number'), 'line-anchored circuit diagnostics');
  assert.ok(seen.diags.some((d) => /−\d+ pts/.test(d.message)), 'diagnostics carry the point deduction');
  assert.match(seen.status, /Circuit: [A-F]/, 'status bar carries the repo grade');
});

// ---------- offline posture: the editor code makes zero network calls ----------
const EGRESS = /\bfetch\s*\(|\bhttps?\.request\s*\(|\bhttps?\.get\s*\(|\bnet\.connect\s*\(|\bnet\.createConnection\s*\(|\bdns\.[a-zA-Z]|\bXMLHttpRequest\b|\bnew\s+WebSocket\b/;
test('editor/ source makes no outbound network call (offline, like the backend)', () => {
  const dir = path.join(ROOT, 'editor');
  const offenders = [];
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.js') && !name.endsWith('.mjs')) continue;
    fs.readFileSync(path.join(dir, name), 'utf8').split('\n').forEach((line, i) => {
      if (EGRESS.test(line)) offenders.push(`editor/${name}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [], `editor code must make zero outbound network calls, found:\n${offenders.join('\n')}`);
});
