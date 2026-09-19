import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const FIXTURE = path.join(ROOT, 'test', 'fixtures', 'demo');

function getJson(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(body) });
        } catch (error) {
          reject(error);
        }
      });
    }).on('error', reject);
  });
}

function listenOn(port) {
  return new Promise((resolve, reject) => {
    const blocker = net.createServer();
    blocker.on('error', reject);
    blocker.listen(port, '127.0.0.1', () => resolve(blocker));
  });
}

function waitForUrl(child) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => {
      reject(new Error(`server did not print URL; output was:\n${output}`));
    }, 8000);

    const onData = (chunk) => {
      output += chunk.toString();
      const match = output.match(/http:\/\/localhost:(\d+)/);
      if (!match) return;
      clearTimeout(timer);
      resolve({ url: match[0], output });
    };

    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code, signal) => {
      clearTimeout(timer);
      reject(new Error(`server exited before URL: code=${code} signal=${signal}\n${output}`));
    });
  });
}

// 8923 is the hands-off live-instance port: no test may bind it, and no test may
// assume something else already holds it. Auto-increment is a property of any
// occupied port, so exercise it on a dedicated test port instead.
// Ports must not collide with other test files — `node --test` runs them in
// parallel, and a collision shows up as a flaky off-by-one port assertion.
// Taken elsewhere: 8923/8924 (live + its neighbour), 8951 (license.test.js).
const BUSY_PORT = 8971;
const FREE_PORT = 8981;

test('auto-increment fires ONLY on EADDRINUSE: an occupied port steps to the next one', async (t) => {
  const blocker = await listenOn(BUSY_PORT);
  t.after(() => blocker.close());

  const child = spawn(process.execPath, ['server.js', FIXTURE, '--port', String(BUSY_PORT)], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));

  const { url } = await waitForUrl(child);
  assert.equal(url, `http://localhost:${BUSY_PORT + 1}`);

  // The first scan is deferred (setImmediate) so the UI shell paints before the
  // analysis blocks the event loop; poll until the graph is ready (503 → 200).
  let graph;
  for (let i = 0; i < 40; i++) {
    graph = await getJson(`${url}/api/graph`);
    if (graph.status === 200) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(graph.status, 200);
  assert.equal(graph.body.name, 'demo');
  assert.equal(graph.body.stats.files, 9);
  assert.equal(graph.body.stats.brokenEdges, 2);
});

// The EMPTY-port case. Auto-increment is NOT a safety net: it fires only on
// EADDRINUSE, so a server pointed at a free port BINDS that port. Applied to the
// default, this is why `node server.js <repo>` with :8923 empty seizes the
// hands-off live port — the dev command must always pass an explicit --port.
test('a FREE port is bound as-is — auto-increment is not a safety net (the empty-:8923 case)', async (t) => {
  // Positive control: prove the port is genuinely free first, so a pass cannot
  // come from something else already holding it and pushing us elsewhere.
  const probe = await listenOn(FREE_PORT);
  await new Promise((r) => probe.close(r));

  const child = spawn(process.execPath, ['server.js', FIXTURE, '--port', String(FREE_PORT)], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));

  const { url } = await waitForUrl(child);
  assert.equal(url, `http://localhost:${FREE_PORT}`);
});

test('no response carries text derived from an exception: a fixed message and a correlation id only', () => {
  // CodeQL js/stack-trace-exposure (main 6c23f3a): exception text quotes absolute paths and
  // stacks. Every send()/broadcast() that reports a failure goes through a fixed message.
  const server = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
  const calls = [...server.matchAll(/\b(?:send|broadcast)\([^;]*?\);/g)].map((m) => m[0]);
  const leaking = calls.filter((c) => /\b(?:e|err|error)\??\.(?:message|stack)\b|String\(\s*(?:e|err|error)\b/.test(c));
  assert.deepEqual(leaking, []);
  assert.match(server, /function failed\(what, e\)/, 'the one failure path');
  const history = fs.readFileSync(path.join(ROOT, 'lib', 'history.js'), 'utf8');
  assert.ok(!/error: [^\n]*\be\??\.message/.test(history) && !/error: [^\n]*String\(e\b/.test(history), 'history frames served to the page carry a fixed reason');
});
