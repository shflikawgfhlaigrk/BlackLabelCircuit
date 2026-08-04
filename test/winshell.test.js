import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Contract tests for the STAGED Circuit-Win Tauri shell (windows/). The Rust build
// is VM-gated (no Rust toolchain on the authoring Mac), so these lock the parts that
// CAN be proven from a cold shell on darwin: the server->shell stdout URL contract,
// the Tauri config validity, and the fail-closed sign gate. The live hands-off port
// (documented in CLAUDE.md) is never bound — the live-server test uses a dev port.

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const WIN = path.join(ROOT, 'windows');
const DEV_PORT = 8934; // an explicit dev port, never the hands-off live instance

// Exact JS mirror of parse_localhost_url() in windows/src-tauri/src/main.rs. If the
// Rust changes, this mirror (and these cases) must change with it — that is the point.
function parseLocalhostUrl(buf) {
  const NEEDLE = 'http://localhost:';
  const start = buf.indexOf(NEEDLE);
  if (start === -1) return null;
  const after = buf.slice(start + NEEDLE.length);
  let i = 0;
  while (i < after.length && after[i] >= '0' && after[i] <= '9') i++;
  const digits = after.slice(0, i);
  if (digits.length === 0) return null;
  if (digits.length === after.length) return null; // ended on a digit: no boundary yet
  return NEEDLE + digits;
}

test('URL parser follows a climbed port and refuses a truncated one', () => {
  // Normal announcement with a trailing newline boundary.
  assert.equal(parseLocalhostUrl('[circuit] http://localhost:8971\n'), 'http://localhost:8971');
  // The port climbed past the default (EADDRINUSE) — the shell must follow it.
  assert.equal(parseLocalhostUrl('http://localhost:9100 offline\n'), 'http://localhost:9100');
  // First complete occurrence wins, stopping at the newline boundary.
  assert.equal(parseLocalhostUrl('a http://localhost:8971\nhttp://localhost:9100\n'), 'http://localhost:8971');
  // Chunk ended exactly on a digit run: port may be truncated mid-write — wait.
  assert.equal(parseLocalhostUrl('http://localhost:897'), null);
  // Needle present but no digits (partial write of the scheme) — nothing yet.
  assert.equal(parseLocalhostUrl('http://localhost:'), null);
  // No needle at all.
  assert.equal(parseLocalhostUrl('[circuit] grading /repo\n'), null);
});

test('server.js announces a localhost URL the shell can follow (dev port; live port untouched)', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-winshell-'));
  fs.writeFileSync(path.join(tmp, 'a.js'), 'export const x = 1;\n');

  const child = spawn(process.execPath, [path.join(ROOT, 'server.js'), tmp, '--port', String(DEV_PORT)], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  const url = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error(`no URL in stdout after 15s; got:\n${buf}`)), 15000);
    const onData = (d) => {
      buf += d.toString();
      const found = parseLocalhostUrl(buf);
      if (found) { clearTimeout(timer); resolve(found); }
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
  }).finally(() => { child.kill('SIGKILL'); });

  fs.rmSync(tmp, { recursive: true, force: true });
  assert.match(url, /^http:\/\/localhost:\d+$/);
  assert.equal(url, `http://localhost:${DEV_PORT}`);
});

test('tauri.conf.json is valid, bundles node as a sidecar + the app resource, and carries no signing/publish config', () => {
  const conf = JSON.parse(fs.readFileSync(path.join(WIN, 'src-tauri', 'tauri.conf.json'), 'utf8'));
  assert.equal(conf.identifier, 'com.blacklabel.circuit');
  assert.deepEqual(conf.bundle.externalBin, ['binaries/node'], 'node must be the bundled sidecar');
  assert.ok(conf.bundle.resources.includes('app'), 'the app/ resource (server.js + lib + public) must be bundled');
  assert.equal(conf.app.windows[0].label, 'main', 'main window label is what main.rs navigates');
  // Staged: no signing identity and no updater pubkey may be committed.
  const text = JSON.stringify(conf).toLowerCase();
  assert.ok(!text.includes('certificatethumbprint'), 'no signing identity may be committed (staged)');
  assert.ok(!text.includes('pubkey'), 'no updater pubkey may be committed here (W0.4/web-producer)');
});

test('sign gate fails closed when no certificate is present', () => {
  const env = { ...process.env };
  delete env.CIRCUIT_WIN_CERT;
  delete env.CIRCUIT_WIN_CERT_PASSWORD;
  const r = spawnSync(process.execPath, [path.join(WIN, 'sign-windows.mjs'), path.join(WIN, 'does-not-exist-setup.exe')], {
    env, encoding: 'utf8',
  });
  assert.equal(r.status, 3, `expected the gate to HOLD (exit 3), got ${r.status}\n${r.stderr}`);
  assert.match(r.stderr, /GATE HELD/);
  assert.match(r.stderr, /nothing was signed or published|not shippable|Unsigned == unshippable/i);
});

test('the Windows shell scaffold is present and pins Tauri v2', () => {
  for (const rel of [
    'src-tauri/src/main.rs', 'src-tauri/Cargo.toml', 'src-tauri/build.rs',
    'src-tauri/capabilities/default.json', 'ui/index.html',
    'fetch-node-runtime.mjs', 'sign-windows.mjs', 'build-win.sh',
  ]) {
    assert.ok(fs.existsSync(path.join(WIN, rel)), `missing windows/${rel}`);
  }
  const cargo = fs.readFileSync(path.join(WIN, 'src-tauri', 'Cargo.toml'), 'utf8');
  assert.match(cargo, /tauri = \{ version = "2"/, 'must pin Tauri v2');
});
