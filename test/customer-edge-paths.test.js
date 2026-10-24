import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { convertPythonSource } from '../lib/convert.js';
import { buildHistory } from '../lib/history.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-edges-'));
  t.after(() => fs.rmSync(dir, { force: true, recursive: true }));
  return dir;
};

test('conversion retains async and checked subprocess semantics as unported source', () => {
  for (const command of ['open', 'say', 'afplay']) {
    for (const call of [`subprocess.Popen(["${command}", value])`, `subprocess.call(["${command}", value])`,
      `subprocess.check_call(["${command}", value])`, `subprocess.run(["${command}", value], check=True)`]) {
      const result = convertPythonSource(`import subprocess\n${call}\n`);
      assert.equal(result.changed, false, call);
      assert.ok(result.text.includes(call));
    }
    assert.equal(convertPythonSource(`subprocess.run(["${command}", value], check=False)\n`).changed, true);
  }
});

test('history grades local archives without requiring checkout filters', (t) => {
  const dir = temp(t);
  const git = (...args) => execFileSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    '-c', 'commit.gpgsign=false', '-C', dir, ...args], { stdio: 'pipe' });
  git('init', '-q');
  fs.writeFileSync(path.join(dir, '.gitattributes'), '*.js filter=unavailable\n');
  fs.writeFileSync(path.join(dir, 'app.js'), 'export const value = 1;\n');
  git('add', '.'); git('commit', '-qm', 'first');
  fs.writeFileSync(path.join(dir, 'app.js'), 'export const value = 2;\n');
  git('commit', '-qam', 'second');
  git('config', 'filter.unavailable.required', 'true');
  git('config', 'filter.unavailable.smudge', '/nonexistent-circuit-fixture-filter');
  git('config', 'core.hooksPath', '/nonexistent-circuit-fixture-hooks');
  const original = fs.readFileSync(path.join(dir, 'app.js'));
  const history = buildHistory(dir);
  assert.equal(history.commits.length, 2);
  assert.ok(history.commits.every((commit) => commit.files > 0 && !commit.error));
  assert.deepEqual(fs.readFileSync(path.join(dir, 'app.js')), original);
});

test('installed editor includes the analyzer and starts its actual LSP entry point', (t) => {
  const dir = temp(t), dest = path.join(dir, 'extension');
  const installed = spawnSync(process.execPath, ['editor/install.mjs', dest], { cwd: ROOT, encoding: 'utf8' });
  assert.equal(installed.status, 0, installed.stderr);
  const request = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
  const result = spawnSync(process.execPath, [path.join(dest, 'server.mjs'), dir], {
    input: `Content-Length: ${Buffer.byteLength(request)}\r\n\r\n${request}`, encoding: 'utf8', timeout: 10_000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /"capabilities"/);
  const again = spawnSync(process.execPath, ['editor/install.mjs', dest], { cwd: ROOT, encoding: 'utf8' });
  assert.notEqual(again.status, 0, 'existing install must be preserved');
});

async function serverFor(t, repo, out, port) {
  const child = spawn(process.execPath, ['server.js', repo, '--port', String(port)], {
    cwd: ROOT, env: { ...process.env, CIRCUIT_CONVERT_DIR: out }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));
  return await new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(output)), 15_000);
    child.stdout.on('data', (data) => {
      output += data;
      const match = output.match(/http:\/\/localhost:(\d+)/);
      if (match) { clearTimeout(timer); resolve(`http://localhost:${match[1]}`); }
    });
    child.once('exit', (code) => { clearTimeout(timer); reject(new Error(`server exited ${code}: ${output}`)); });
  });
}

test('loopback server rejects foreign browser origins and separates same-name repositories', async (t) => {
  const dir = temp(t), out = path.join(dir, 'converted');
  const a = path.join(dir, 'a', 'app'), b = path.join(dir, 'b', 'app');
  for (const repo of [a, b]) { fs.mkdirSync(repo, { recursive: true }); fs.writeFileSync(path.join(repo, 'app.js'), 'export const a=1;'); }
  const first = await serverFor(t, a, out, 8972);
  const second = await serverFor(t, b, out, 8973);
  assert.equal((await fetch(first + '/api/license')).status, 200);
  assert.equal((await fetch(first + '/api/license', { headers: { Origin: 'https://example.invalid' } })).status, 403);
  // Node fetch normalizes Host in some runtimes. Send the actual invalid header
  // through the HTTP client so this checks the server's boundary.
  const foreignHostStatus = await new Promise((resolve, reject) => {
    const req = http.get(first + '/api/license', { headers: { Host: 'example.invalid' } }, (res) => {
      res.resume(); resolve(res.statusCode);
    });
    req.on('error', reject);
  });
  assert.equal(foreignHostStatus, 403);
  assert.equal((await fetch(first + '/api/history')).status, 403);
  assert.equal((await fetch(first + '/api/convert', { method: 'POST' })).status, 403);
  assert.equal((await fetch(first + '/api/history', { headers: { 'X-Circuit-Request': '1' } })).status, 200);
  const stateA = await (await fetch(first + '/api/convert')).json();
  const stateB = await (await fetch(second + '/api/convert')).json();
  assert.notEqual(stateA.out, stateB.out);
  assert.equal(stateA.result, null); assert.equal(stateB.result, null);
  fs.mkdirSync(stateA.out, { recursive: true });
  fs.writeFileSync(path.join(stateA.out, 'conversion.json'), JSON.stringify({ root: b, verified: true }));
  assert.equal((await (await fetch(first + '/api/convert')).json()).result, null);
});
