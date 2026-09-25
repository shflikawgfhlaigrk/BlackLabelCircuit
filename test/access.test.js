import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { createAccess } from '../lib/access.js';
import { OWNER_KEY, ownerHeaders, stopServer } from './server-harness.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PORT = 8961;
const origin = `http://localhost:${PORT}`;
const jsonHeaders = { 'Content-Type': 'application/json', 'X-Circuit-Request': '1', Origin: origin };
function request(route, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(`${origin}${route}`, { method, headers }, res => {
      let text = '';
      res.on('data', chunk => { text += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, text, headers: res.headers }));
    });
    req.on('error', reject);
    req.end(body);
  });
}
test('one-use sign-in expiry, revocation and native identity fail closed', () => {
  let now = 100;
  const access = createAccess({ ownerKey: OWNER_KEY, now: () => now, handoffMs: 100, sessionMs: 2000 });
  const link = access.launchURL(PORT);
  const key = new URLSearchParams(new URL(link).hash.slice(1)).get('handoff');
  assert.equal(access.exchange('wrong'), null);
  const cookie = access.exchange(key).split(';')[0];
  assert.equal(access.exchange(key), null);
  const p = access.principal({ headers: { cookie } });
  assert.ok(access.valid(p));
  now += 2000;
  assert.equal(access.valid(p), false);
  assert.equal(access.principal({ headers: { cookie } }), null);
  assert.equal(access.principal({ headers: { authorization: 'Bearer wrong', cookie } }), null);
  assert.ok(access.principal({ headers: { authorization: `Bearer ${OWNER_KEY}` } }));
  const expired = createAccess({ now: () => now, handoffMs: 100 });
  const expiredKey = new URLSearchParams(new URL(expired.launchURL(PORT)).hash.slice(1)).get('handoff');
  now += 100;
  assert.equal(expired.exchange(expiredKey), null);
  assert.throws(() => createAccess({ ownerKey: 'weak' }));
});

test('real HTTP protects files, graph, history, events and controls; preserves authenticated use', async t => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-access-'));
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-outside-'));
  fs.writeFileSync(path.join(fixture, 'private.js'), 'export const syntheticPrivate = "fixture-only";\n');
  fs.writeFileSync(path.join(outside, 'outside.txt'), 'OUTSIDE SYNTHETIC');
  fs.symlinkSync(path.join(outside, 'outside.txt'), path.join(fixture, 'escape.txt'));
  fs.writeFileSync(path.join(fixture, 'oversize.txt'), Buffer.alloc(2_000_001));
  const child = spawn(process.execPath, ['server.js', fixture, '--port', String(PORT)], {
    cwd: ROOT, env: { ...process.env, CIRCUIT_OWNER_KEY: OWNER_KEY }, stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
  });
  t.after(async () => { await stopServer(child); fs.rmSync(fixture, { recursive: true }); fs.rmSync(outside, { recursive: true }); });
  const link = await new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('No Circuit startup link')), 10_000);
    child.stdout.on('data', chunk => {
      output += chunk;
      const m = output.match(/http:\/\/localhost:\d+\/#handoff=[A-Za-z0-9_-]{43}\n/);
      if (m) { clearTimeout(timer); resolve(m[0].trim()); }
    });
    child.on('error', reject);
  });
  assert.equal(new URL(link).origin, origin);
  const key = new URLSearchParams(new URL(link).hash.slice(1)).get('handoff');
  for (const route of ['/api/file?path=private.js', '/api/graph', '/api/history', '/api/license', '/api/events', '/api/session']) {
    const r = await request(route);
    assert.equal(r.status, 401, route);
    assert.ok(!r.text.includes('fixture-only'));
  }
  const shell = await request('/');
  assert.equal(shell.status, 200);
  assert.ok(!shell.text.includes(key) && !shell.text.includes(OWNER_KEY));
  assert.equal(shell.headers['set-cookie'], undefined);
  assert.equal(shell.headers['cache-control'], 'no-store');
  for (const headers of [
    { Host: `rebound.invalid:${PORT}` }, { Host: 'localhost:1' },
    { Origin: 'http://evil.invalid' }, { Origin: 'null' },
    { Referer: 'http://evil.invalid/' }, { 'Sec-Fetch-Site': 'same-site' }, { 'Sec-Fetch-Site': 'cross-site' },
  ]) assert.equal((await request('/api/file?path=private.js', { headers: { ...ownerHeaders, ...headers } })).status, 403);
  assert.equal((await request('/api/rescan', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '{}' })).status, 401);
  assert.equal((await request('/api/rescan', { headers: ownerHeaders })).status, 405);
  assert.equal((await request('/api/rescan', { method: 'POST', headers: ownerHeaders, body: '{}' })).status, 415);
  assert.equal((await request('/api/file?path=private.js', { method: 'HEAD', headers: ownerHeaders })).status, 405);
  assert.equal((await request('/api/session', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ handoff: 'wrong' }) })).status, 401);
  assert.equal((await request('/api/session', { method: 'POST', headers: { ...jsonHeaders, 'Content-Length': '2049' }, body: ' '.repeat(2049) })).status, 413);
  const signedIn = await request('/api/session', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ handoff: key }) });
  assert.equal(signedIn.status, 200);
  assert.match(signedIn.headers['set-cookie'][0], /HttpOnly; SameSite=Strict/);
  const Cookie = signedIn.headers['set-cookie'][0].split(';')[0];
  assert.equal((await request('/api/session', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ handoff: key }) })).status, 401);
  assert.equal((await request('/api/file?path=private.js', { headers: { Cookie } })).text, 'export const syntheticPrivate = "fixture-only";\n');
  for (const headers of [ownerHeaders, { Cookie }]) {
    assert.equal((await request('/api/file?path=escape.txt', { headers })).status, 403);
    assert.equal((await request('/api/file?path=../../etc/passwd', { headers })).status, 403);
    assert.equal((await request('/api/file?path=oversize.txt', { headers })).status, 413);
    assert.equal((await request('/api/graph', { headers })).status, 200);
    assert.equal((await request('/api/history', { headers })).status, 200);
    assert.equal((await request('/api/rescan', { method: 'POST', headers: { ...headers, ...jsonHeaders }, body: '{}' })).status, 200);
  }
  assert.equal((await request('/api/rescan', { method: 'POST', headers: { Cookie, 'Content-Type': 'application/json', 'X-Circuit-Request': '1' }, body: '{}' })).status, 403);
  const stream = await new Promise((resolve, reject) => {
    const req = http.get(`${origin}/api/events`, { headers: { Cookie } }, res => {
      res.once('data', bytes => resolve({ res, first: String(bytes) }));
    });
    req.on('error', reject);
  });
  assert.equal(stream.res.statusCode, 200);
  assert.match(stream.first, /event: hello/);
  const ended = new Promise(resolve => stream.res.once('end', resolve));
  stream.res.resume();
  assert.equal((await request('/api/logout', { method: 'POST', headers: { ...jsonHeaders, Cookie }, body: '{}' })).status, 200);
  await ended;
  assert.equal((await request('/api/file?path=private.js', { headers: { Cookie } })).status, 401);
  assert.equal((await request('/api/events', { headers: { Cookie } })).status, 401);
  assert.equal((await request('/api/session', { headers: ownerHeaders })).status, 200);
});
