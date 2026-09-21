import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createConversionSession, discoverMacProject, loadConversionSession,
  loadCurrentConversionSession, previewConversionOutput, sourceIdentity,
  updateConversionSession,
} from '../lib/conversion-session.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function tempDir(t, prefix = 'circuit-session-') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function write(root, rel, contents) {
  const file = path.join(root, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
  return file;
}

function xcodegenProject(t) {
  const root = tempDir(t);
  write(root, 'project.yml', `name: Sample\ntargets:\n  Main App:\n    type: application\n    platform: macOS\n    sources:\n      - path: Sources/Main\n  Menu Helper:\n    type: application\n    platform: macOS\n    sources:\n      - Sources/Helper\n  Shared Library:\n    type: framework\n    platform: macOS\n    sources:\n      - Sources/Shared\n`);
  write(root, 'Sources/Main/App.swift', 'import SwiftUI\n@main struct App: SwiftUI.App {}\n');
  write(root, 'Sources/Helper/main.swift', 'print("helper")\n');
  return root;
}

function initGit(root) {
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['config', 'user.email', 'circuit@example.invalid'], { cwd: root });
  execFileSync('git', ['config', 'user.name', 'Circuit Test'], { cwd: root });
  execFileSync('git', ['add', '.'], { cwd: root });
  execFileSync('git', ['commit', '-qm', 'fixture'], { cwd: root });
}

test('discovers every XcodeGen macOS application target and its source roots', (t) => {
  const intake = discoverMacProject(xcodegenProject(t));
  assert.deepEqual(intake.targets.map((item) => item.name), ['Main App', 'Menu Helper']);
  assert.deepEqual(intake.targets[0].sources, ['Sources/Main']);
  assert.deepEqual(intake.targets[1].sources, ['Sources/Helper']);
  assert.equal(intake.targets[0].recommendedProfile, 'winui3');
  assert.ok(intake.targets[0].profiles.includes('tauri2-webview2'));
});

test('source identity binds the revision, dirty bytes, deletion state, and non-Git files', (t) => {
  const root = xcodegenProject(t);
  const nonGitBefore = sourceIdentity(root);
  write(root, 'Sources/Main/App.swift', 'changed before git\n');
  const nonGitAfter = sourceIdentity(root);
  assert.notEqual(nonGitAfter.sha256, nonGitBefore.sha256);
  assert.ok(nonGitAfter.dirty.some((item) => item.path === 'Sources/Main/App.swift' && item.sha256));

  initGit(root);
  const clean = sourceIdentity(root);
  assert.ok(clean.commit);
  assert.deepEqual(clean.dirty, []);
  write(root, 'Sources/Main/App.swift', 'changed after git\n');
  const modified = sourceIdentity(root);
  assert.notEqual(modified.sha256, clean.sha256);
  assert.equal(modified.dirty[0].sha256, sourceIdentity(root).dirty[0].sha256);
  fs.rmSync(path.join(root, 'Sources/Main/App.swift'));
  const deleted = sourceIdentity(root);
  assert.ok(deleted.dirty.some((item) => item.path === 'Sources/Main/App.swift' && item.kind === 'deleted'));
});

test('creates, loads, resumes, and mutates only runtime session state', (t) => {
  const root = xcodegenProject(t);
  const base = tempDir(t, 'circuit-output-');
  const intake = discoverMacProject(root);
  const chosen = intake.targets[1];
  const session = createConversionSession({ root, base, targetId: chosen.id, profileId: 'winui3' });

  assert.equal(session.target.name, 'Menu Helper');
  assert.equal(session.output.path, previewConversionOutput({ appName: intake.app.name, targetName: chosen.name, profileId: 'winui3', base }));
  assert.ok(!session.output.path.startsWith(`${root}${path.sep}`));
  assert.deepEqual(loadConversionSession(base, session.id), session);
  assert.equal(loadCurrentConversionSession(base).id, session.id);

  const running = updateConversionSession(base, session.id, {
    status: 'running', progress: { stage: 'convert', completed: 0, total: 1, message: 'Converting' },
  });
  assert.equal(running.status, 'running');
  assert.equal(running.source.sha256, session.source.sha256);
  assert.throws(() => updateConversionSession(base, session.id, { output: { path: '/tmp/replaced' } }), /immutable/);
  assert.equal(loadConversionSession(base, session.id).output.path, session.output.path);
});

test('rejects output inside source and safely ignores corrupt current state', (t) => {
  const root = xcodegenProject(t);
  const target = discoverMacProject(root).targets[0];
  assert.throws(() => createConversionSession({ root, base: path.join(root, 'Converted'), targetId: target.id, profileId: 'winui3' }), /outside the source/);

  const base = tempDir(t, 'circuit-corrupt-');
  write(base, '.circuit/current.json', '{bad json');
  assert.equal(loadCurrentConversionSession(base), null);
  write(base, '.circuit/current.json', JSON.stringify({ schema: 'circuit.conversion-session.v1', id: '../../escape' }));
  assert.equal(loadCurrentConversionSession(base), null);
});

function requestJson(url, { method = 'GET', body } = {}) {
  return new Promise((resolve, reject) => {
    const data = body == null ? null : JSON.stringify(body);
    const req = http.request(url, {
      method,
      headers: data ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } : {},
    }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { text += chunk; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(text) }); }
        catch (error) { reject(error); }
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startServer(t, source, base) {
  const port = await freePort();
  const child = spawn(process.execPath, ['server.js', source, '--port', String(port)], {
    cwd: ROOT,
    env: { ...process.env, CIRCUIT_CONVERT_DIR: base },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = [];
  child.stdout.on('data', (chunk) => output.push(String(chunk)));
  child.stderr.on('data', (chunk) => output.push(String(chunk)));
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`server start timeout\n${output.join('')}`)), 8000);
    const poll = setInterval(() => {
      if (output.join('').includes(`http://localhost:${port}`)) {
        clearInterval(poll); clearTimeout(timeout); resolve();
      }
    }, 20);
    child.once('exit', (code) => { clearInterval(poll); clearTimeout(timeout); reject(new Error(`server exited ${code}\n${output.join('')}`)); });
  });
  const stop = async () => {
    if (child.exitCode != null || child.signalCode != null) return;
    await new Promise((resolve) => {
      child.once('exit', resolve);
      child.kill('SIGTERM');
    });
  };
  t.after(stop);
  return { url: `http://127.0.0.1:${port}`, stop };
}

test('session API creates server-derived state and resumes it after a restart', async (t) => {
  const source = xcodegenProject(t);
  initGit(source);
  const base = tempDir(t, 'circuit-api-output-');
  const first = await startServer(t, source, base);
  const setup = await requestJson(`${first.url}/api/conversion/session`);
  assert.equal(setup.status, 200);
  assert.equal(setup.body.session, null);
  const target = setup.body.intake.targets[0];
  assert.equal(setup.body.outputPreviews[target.id].winui3, previewConversionOutput({
    appName: setup.body.intake.app.name, targetName: target.name, profileId: 'winui3', base,
  }));

  const created = await requestJson(`${first.url}/api/conversion/session`, {
    method: 'POST', body: { targetId: target.id, profileId: 'winui3', output: '/tmp/client-controlled' },
  });
  assert.equal(created.status, 201);
  assert.equal(created.body.session.output.path, setup.body.outputPreviews[target.id].winui3);
  const id = created.body.session.id;
  await first.stop();

  const second = await startServer(t, source, base);
  const resumed = await requestJson(`${second.url}/api/conversion/session`);
  assert.equal(resumed.status, 200);
  assert.equal(resumed.body.session.id, id);
  assert.equal(resumed.body.session.status, 'ready');
});

test('conversion intake markup is semantic, announced, and keyboard styled', () => {
  const html = fs.readFileSync(path.join(ROOT, 'public', 'index.html'), 'utf8');
  const css = fs.readFileSync(path.join(ROOT, 'public', 'style.css'), 'utf8');
  assert.match(html, /<form id="convertSetup"/);
  assert.match(html, /<nav class="convert-steps" aria-label=/);
  assert.match(html, /aria-live="polite"/);
  assert.match(html, /<fieldset class="convert-fieldset">[\s\S]*?<legend>/);
  assert.match(html, /type="submit"/);
  assert.doesNotMatch(html, /on(?:click|change|submit)=/i);
  assert.match(css, /\.convert-choice input:focus-visible \+ span/);
  assert.match(css, /min-height:\s*48px/);
  assert.match(css, /@media \(max-width:\s*620px\)/);
  assert.match(css, /@media \(prefers-reduced-motion:\s*reduce\)/);
  assert.match(css, /\.visually-hidden/);
});
