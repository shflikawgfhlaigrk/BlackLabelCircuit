import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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

test('server auto-increments when the default port is occupied and grades the real fixture repo', async (t) => {
  // Occupy 8923 so the server must auto-increment. On a dev machine a LIVE
  // Circuit instance already holds 8923 — that provides the exact same
  // "default port busy" condition, so tolerate EADDRINUSE and never disturb it.
  let blocker = null;
  try {
    blocker = await listenOn(8923);
    t.after(() => blocker.close());
  } catch (e) {
    if (e.code !== 'EADDRINUSE') throw e;
  }

  const child = spawn(process.execPath, ['server.js', FIXTURE], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));

  const { url } = await waitForUrl(child);
  assert.equal(url, 'http://localhost:8924');

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
