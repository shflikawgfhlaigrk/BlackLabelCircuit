import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// The attestable no-network guarantee (CI-18 / CI-15). These tests fail the build
// if any outbound-network API ever appears in the BACKEND source, so the offline
// posture Circuit markets to air-gapped / regulated buyers cannot silently regress.
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

// Every .js file the server actually runs: server.js + everything under lib/.
function backendFiles() {
  const out = [path.join(ROOT, 'server.js')];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) walk(abs);
      else if (e.name.endsWith('.js')) out.push(abs);
    }
  };
  walk(path.join(ROOT, 'lib'));
  return out;
}

// Outbound-egress APIs. `http.createServer` is an INBOUND local server and is the
// one allowed use of the http module — it is excluded on the line that has it.
const EGRESS = /\bfetch\s*\(|\bhttps?\.request\s*\(|\bhttps?\.get\s*\(|\bnet\.connect\s*\(|\bnet\.createConnection\s*\(|\bdns\.[a-zA-Z]|\bXMLHttpRequest\b|\bnew\s+WebSocket\b|\bWebSocket\s*\(/;

test('no backend source makes an outbound network call (attestable, air-gap)', () => {
  const offenders = [];
  for (const file of backendFiles()) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (line.includes('createServer')) return; // inbound local server — allowed
      if (EGRESS.test(line)) offenders.push(`${path.relative(ROOT, file)}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [], `backend must make zero outbound network calls, found:\n${offenders.join('\n')}`);
});

test('the HTTP server binds loopback only (nothing exposed off-box)', () => {
  const server = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
  assert.ok(server.includes(`'127.0.0.1'`), 'server.listen binds 127.0.0.1');
  assert.ok(!/listen\([^)]*'0\.0\.0\.0'/.test(server), 'server never binds 0.0.0.0');
});

test('the UI carries an always-on offline / air-gap indicator (CI-18)', () => {
  const appJs = fs.readFileSync(path.join(ROOT, 'public', 'app.js'), 'utf8');
  const html = fs.readFileSync(path.join(ROOT, 'public', 'index.html'), 'utf8');
  assert.ok(html.includes('offlineChip'), 'index.html has the offline chip element');
  assert.ok(/offline — no code leaves this machine/.test(appJs), 'app.js sets the offline chip text');
  assert.ok(/air-gap|offline-mode|attestable/i.test(appJs), 'app.js documents the offline posture');
});

test('AIRGAP.md ships and states the attestable no-network claim', () => {
  const doc = fs.readFileSync(path.join(ROOT, 'AIRGAP.md'), 'utf8');
  assert.ok(/air-?gap/i.test(doc));
  assert.ok(/attestable/i.test(doc));
  assert.ok(doc.includes('zero outbound network'), 'AIRGAP.md carries the no-network statement');
});
