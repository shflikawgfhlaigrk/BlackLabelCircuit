import { OWNER_KEY, ownerHeaders, stopServer } from './server-harness.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveLicense, isLicensed, productUrl, PRODUCT_URL_DEFAULT } from '../lib/license.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const FIXTURE = path.join(ROOT, 'test', 'fixtures', 'demo');

// A license claim is only allowed to contain a currency figure if it never does.
// This guards the founder rule: no price is minted anywhere in the app until
// Michael rules the price model.
function assertNoPrice(...strings) {
  for (const s of strings) {
    if (s == null) continue;
    assert.ok(!/[$£€]/.test(s), `price symbol leaked into copy: ${JSON.stringify(s)}`);
    assert.ok(!/\b\d+\s*(?:\/\s*(?:mo|month|yr|year)|dollars?|usd)\b/i.test(s), `price phrase leaked into copy: ${JSON.stringify(s)}`);
  }
}

test('fail-closed: no env => demo mode with a CTA', () => {
  const lic = resolveLicense({});
  assert.equal(lic.mode, 'demo');
  assert.equal(lic.licensed, false);
  assert.equal(lic.product, 'Circuit');
  assert.ok(lic.notice && lic.cta, 'demo build must surface a notice and CTA');
  assert.equal(lic.productUrl, PRODUCT_URL_DEFAULT);
});

test('fail-closed: blank / placeholder keys resolve to demo', () => {
  for (const k of ['', '   ', 'demo', 'TRIAL', 'none', 'test', 'changeme', 'false', '0', 'short']) {
    assert.equal(isLicensed({ CIRCUIT_LICENSE: k }), false, `expected demo for ${JSON.stringify(k)}`);
    assert.equal(resolveLicense({ CIRCUIT_LICENSE: k }).mode, 'demo');
  }
});

test('a real, non-placeholder key activates licensed mode with no CTA', () => {
  const env = { CIRCUIT_LICENSE: 'CIRC-9F3A-77KD-2210' };
  assert.equal(isLicensed(env), true);
  const lic = resolveLicense(env);
  assert.equal(lic.mode, 'licensed');
  assert.equal(lic.licensed, true);
  assert.equal(lic.notice, null);
  assert.equal(lic.cta, null);
});

test('product URL is config-driven and defaults price-free', () => {
  assert.equal(productUrl({}), PRODUCT_URL_DEFAULT);
  assert.equal(productUrl({ CIRCUIT_PRODUCT_URL: 'https://x.example/buy' }), 'https://x.example/buy');
  assert.match(PRODUCT_URL_DEFAULT, /blacklabelbots\.com\/circuit$/);
});

test('NO PRICE is minted anywhere in license copy (demo or licensed)', () => {
  const demo = resolveLicense({});
  const licensed = resolveLicense({ CIRCUIT_LICENSE: 'CIRC-9F3A-77KD-2210' });
  assertNoPrice(demo.notice, demo.cta, demo.product, demo.productUrl, demo.mode);
  assertNoPrice(licensed.product, licensed.productUrl, licensed.mode);
});

function getJson(url) {
  return new Promise((resolve, reject) => {
    http.get(url, { headers: ownerHeaders }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => { try { resolve({ status: res.statusCode, body: JSON.parse(body) }); } catch (e) { reject(e); } });
    }).on('error', reject);
  });
}

function waitForUrl(child) {
  return new Promise((resolve, reject) => {
    let out = '';
    const timer = setTimeout(() => reject(new Error(`no URL; output:\n${out}`)), 8000);
    const onData = (chunk) => {
      out += chunk.toString();
      const m = out.match(/http:\/\/localhost:(\d+)/);
      if (!m) return;
      clearTimeout(timer);
      resolve(m[0]);
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code, sig) => { clearTimeout(timer); reject(new Error(`exit ${code}/${sig}\n${out}`)); });
  });
}

test('GET /api/license serves demo state (live :8923 untouched — server picks a free port)', async (t) => {
  // No CIRCUIT_LICENSE in env => the server must report demo, fail-closed.
  const env = { ...process.env, CIRCUIT_OWNER_KEY: OWNER_KEY };
  delete env.CIRCUIT_LICENSE;
  // Pin a far, explicit port so this never contends with server.test.js's
  // 8923→8924 auto-increment assertion when node runs the files in parallel.
  // (Never :8923 — that is the hands-off live instance.)
  const child = spawn(process.execPath, ['server.js', FIXTURE, '--port', '8951'], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe', 'ipc'], env });
  t.after(() => stopServer(child));
  const url = await waitForUrl(child);
  const lic = await getJson(`${url}/api/license`);
  assert.equal(lic.status, 200);
  assert.equal(lic.body.mode, 'demo');
  assert.equal(lic.body.licensed, false);
  assert.equal(lic.body.product, 'Circuit');
  assertNoPrice(lic.body.notice, lic.body.cta, lic.body.productUrl);
});
