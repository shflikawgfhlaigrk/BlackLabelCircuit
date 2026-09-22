import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Local analysis remains attestably offline. The single online conversion adapter is
// isolated and opt-in; no analyzer, compiler, session, or report module may gain egress.
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

test('no local-analysis backend source makes an outbound network call', () => {
  const offenders = [];
  for (const file of backendFiles()) {
    if (file.endsWith(`${path.sep}conversion-broker.js`) || file.endsWith(`${path.sep}server.js`)) continue;
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (line.includes('createServer')) return; // inbound local server — allowed
      if (EGRESS.test(line)) offenders.push(`${path.relative(ROOT, file)}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [], `local analysis must make zero outbound network calls, found:\n${offenders.join('\n')}`);
});

test('online egress is isolated to an explicitly configured conversion adapter', () => {
  const server = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
  const broker = fs.readFileSync(path.join(ROOT, 'lib', 'conversion-broker.js'), 'utf8');
  assert.match(server, /CIRCUIT_BROKER_URL/);
  assert.match(broker, /class OnlineBrokerClient/);
  assert.match(broker, /https:/);
  assert.match(broker, /minimized source bundle|source-bundle/);
});

test('the HTTP server binds loopback only (nothing exposed off-box)', () => {
  const server = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
  assert.ok(server.includes(`'127.0.0.1'`), 'server.listen binds 127.0.0.1');
  assert.ok(!/listen\([^)]*'0\.0\.0\.0'/.test(server), 'server never binds 0.0.0.0');
});

test('the UI distinguishes offline analysis from explicit online conversion', () => {
  const appJs = fs.readFileSync(path.join(ROOT, 'public', 'app.js'), 'utf8');
  const html = fs.readFileSync(path.join(ROOT, 'public', 'index.html'), 'utf8');
  assert.ok(html.includes('offlineChip'), 'index.html has the offline chip element');
  assert.ok(/local analysis — online converter disconnected/.test(appJs), 'app.js sets the disconnected chip text');
  assert.ok(/online conversion broker connected/.test(appJs), 'app.js exposes connected conversion state');
});

test('AIRGAP.md documents the local boundary and explicit online conversion', () => {
  const doc = fs.readFileSync(path.join(ROOT, 'AIRGAP.md'), 'utf8');
  assert.ok(/air-?gap/i.test(doc));
  assert.ok(/attestable/i.test(doc));
  assert.ok(doc.includes('local analysis makes zero outbound network'), 'AIRGAP.md carries the scoped no-network statement');
  assert.ok(doc.includes('CIRCUIT_BROKER_URL'));
});
