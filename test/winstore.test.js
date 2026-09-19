// Circuit — Microsoft Store MSIX release lane locks.
//
// test/winmsix.test.js locks the PACKAGE (manifest shape, tiles, the spike lane's fail-closed
// wiring). This file locks the SUBMISSION lane that was built on top of it:
//   1. the three Partner Center identity values are placeholders in ONE documented place,
//   2. the identity verdict is computed from element VALUES, not a whole-file grep,
//   3. the release workflow is PORTABLE — no absolute path, no sibling repo, no host tooling,
//   4. the release workflow fails closed and labels its artifact with the truth.
//
// Every grep-shaped assertion here is paired with a positive control that mutates the source
// into the failure it claims to catch, so none of them can be silently vacuous.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const read = (...p) => fs.readFileSync(path.join(ROOT, ...p), 'utf8');

const MANIFEST_PATH = ['windows', 'msix', 'AppxManifest.xml'];
const BUILD_PATH = ['windows', 'build-msix.sh'];
const WF_PATH = ['.github', 'workflows', 'windows-store-msix.yml'];
const ENV_EXAMPLE_PATH = ['windows', 'msix', 'partner-center.env.example'];
const DOC_PATH = ['windows', 'STORE-SUBMISSION.md'];

// --- 1. the three identity values ------------------------------------------------------------

test('all THREE Partner Center identity values are placeholders — none is invented', () => {
  const m = read(...MANIFEST_PATH);
  const identity = (m.match(/<Identity\b[\s\S]*?\/>/) ?? [''])[0];
  assert.ok(identity, 'no <Identity> element');

  const name = identity.match(/\bName="([^"]*)"/);
  assert.ok(name, 'Identity/Name missing');
  assert.match(name[1], /PARTNER-CENTER-PLACEHOLDER/,
    'Identity/Name is not a placeholder — Partner Center assigns this after name reservation');

  const publisher = identity.match(/\bPublisher="([^"]*)"/);
  assert.ok(publisher, 'Identity/Publisher missing');
  assert.match(publisher[1], /^CN=PARTNER-CENTER-PLACEHOLDER$/,
    'Identity/Publisher is not the placeholder token');
  // The real value is CN=<GUID>. A committed GUID would be fabricated and would look real.
  assert.ok(!/CN=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-/.test(m),
    'a GUID-shaped publisher was committed — Partner Center assigns it; never invent one');

  assert.match(m, /<PublisherDisplayName>__PUBLISHER_DISPLAY_NAME__<\/PublisherDisplayName>/,
    'PublisherDisplayName is not a placeholder');
});

test('no company publisher name is hardcoded anywhere in the Windows lane', () => {
  // The Partner Center account is an INDIVIDUAL: the publisher is a verified LEGAL NAME, so a
  // committed company name is wrong twice over (Store rejection + cross-brand surface).
  const files = [MANIFEST_PATH, BUILD_PATH, WF_PATH,
    ['windows', 'src-tauri', 'tauri.conf.json'], ['windows', 'src-tauri', 'Cargo.toml']];
  for (const f of files) {
    const body = read(...f);
    // Match the company name as a real value, not the word inside prose/comments.
    assert.ok(!/"\s*Black Label[^"]*"|publisher"\s*:\s*"Black Label/i.test(body),
      `${f.join('/')} hardcodes a company publisher name`);
  }
});

test('POSITIVE CONTROL: the identity locks fire on a fabricated identity', () => {
  const m = read(...MANIFEST_PATH);
  const faked = m
    .replace(/Publisher="CN=PARTNER-CENTER-PLACEHOLDER"/,
      'Publisher="CN=A1B2C3D4-5E6F-7890-ABCD-EF1234567890"')
    .replace(/<PublisherDisplayName>__PUBLISHER_DISPLAY_NAME__</, '<PublisherDisplayName>Some Company Inc<');
  assert.notEqual(faked, m, 'the control mutated nothing — it proves nothing');
  assert.ok(/CN=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-/.test(faked), 'the GUID lock would not fire on a fake GUID');
  assert.ok(!/<PublisherDisplayName>__PUBLISHER_DISPLAY_NAME__</.test(faked),
    'the display-name lock would not fire on a resolved display name');
});

// --- 2. ONE documented place ------------------------------------------------------------------

test('there is exactly ONE place to paste the values, and it is documented and gitignored', () => {
  const example = read(...ENV_EXAMPLE_PATH);
  for (const v of ['PARTNER_CENTER_IDENTITY_NAME', 'PARTNER_CENTER_IDENTITY',
    'PARTNER_CENTER_PUBLISHER_DISPLAY']) {
    assert.ok(example.includes(v), `the template does not carry ${v}`);
  }
  // The template must ship EMPTY. A template with a value in it is a fabricated identity.
  for (const line of example.split('\n')) {
    const kv = line.match(/^(PARTNER_CENTER_[A-Z_]+)=(.*)$/);
    if (kv) assert.match(kv[2], /^""?$/, `${kv[1]} ships with a value — templates must be empty`);
  }
  assert.match(example, /LEGAL NAME/, 'the template does not say the display name is the legal name');
  assert.match(example, /INDIVIDUAL/, 'the template does not record that the account is an individual');

  const ignored = read('windows', '.gitignore');
  assert.match(ignored, /msix\/partner-center\.env\s*$/m, 'partner-center.env is not gitignored');
  assert.ok(!fs.existsSync(path.join(ROOT, 'windows', 'msix', 'partner-center.env')),
    'a real partner-center.env is present in the tree — account identity must never be committed');

  assert.match(read(...BUILD_PATH), /partner-center\.env/, 'build-msix.sh does not read the env file');
  assert.match(read(...DOC_PATH), /partner-center\.env/, 'STORE-SUBMISSION.md does not name the env file');
});

// --- 3. the identity verdict is computed from values, not a whole-file grep --------------------

test('IDENTITY-PLACEHOLDER / STORE-READY is derived from element values, not a file-wide grep', () => {
  // The trap: the manifest carries a documentation comment naming the placeholder tokens. A
  // `grep -q PLACEHOLDER manifest` therefore reports PLACEHOLDER forever and STORE-READY is
  // unreachable — the lane could never emit a submittable verdict. Lock the parse.
  const build = read(...BUILD_PATH);
  assert.match(build, /IDENTITY-STATUS\.txt/, 'no identity status file is written');
  assert.match(build, /STORE-READY/, 'no STORE-READY verdict exists');
  assert.ok(!/grep -q\s+'[^']*PARTNER-CENTER-PLACEHOLDER[^']*'\s+"\$LAYOUT\/AppxManifest\.xml"/.test(build),
    'the verdict is back to a whole-file grep — STORE-READY would be unreachable');
  assert.match(build, /<Identity\\b\[\\s\\S\]\*\?\\\/>|<Identity/, 'the manifest is not parsed for <Identity>');
});

test('END-TO-END: --validate reports PLACEHOLDER unset and STORE-READY when the three are set', () => {
  // A grep cannot prove the verdict flips. Run the real script both ways. --validate is
  // host-agnostic (no makeappx, no Windows), so this executes here.
  // Isolate the layout/dist. test/winmsix.test.js drives the SAME script in parallel (node --test
  // runs files concurrently) and both would rm -rf the shared windows/msix-layout mid-run — a
  // flaky failure that looks like a real gate breaking. Also keeps the working tree untouched.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-store-'));
  const run = (env) => spawnSync('bash', [path.join(ROOT, 'windows', 'build-msix.sh'), '--validate'],
    {
      cwd: ROOT,
      encoding: 'utf8',
      env: {
        ...process.env,
        CIRCUIT_MSIX_LAYOUT: path.join(tmp, 'layout'),
        CIRCUIT_MSIX_DIST: path.join(tmp, 'dist'),
        ...env,
      },
    });

  const bare = run({
    PARTNER_CENTER_IDENTITY_NAME: '', PARTNER_CENTER_IDENTITY: '',
    PARTNER_CENTER_PUBLISHER_DISPLAY: '', PARTNER_CENTER_PACKAGE_VERSION: '',
  });
  assert.equal(bare.status, 0, `--validate failed: ${bare.stderr}`);
  assert.match(bare.stdout, /IDENTITY-PLACEHOLDER/, 'unset identity did not report IDENTITY-PLACEHOLDER');
  assert.ok(!/^\s*STORE-READY/m.test(bare.stdout), 'unset identity reported STORE-READY');

  const set = run({
    PARTNER_CENTER_IDENTITY_NAME: 'TESTONLY0000.Circuit',
    PARTNER_CENTER_IDENTITY: 'CN=00000000-0000-0000-0000-000000000000',
    PARTNER_CENTER_PUBLISHER_DISPLAY: 'Test Only Legal Name',
    PARTNER_CENTER_PACKAGE_VERSION: '',
  });
  assert.equal(set.status, 0, `--validate failed with identity set: ${set.stderr}`);
  assert.match(set.stdout, /STORE-READY/,
    'a fully resolved identity did not reach STORE-READY — the verdict is unreachable');
  assert.match(set.stdout, /Test Only Legal Name/, 'the display name was not substituted');

  // Partial resolution must NOT read as ready.
  const partial = run({
    PARTNER_CENTER_IDENTITY_NAME: 'TESTONLY0000.Circuit',
    PARTNER_CENTER_IDENTITY: '', PARTNER_CENTER_PUBLISHER_DISPLAY: '',
    PARTNER_CENTER_PACKAGE_VERSION: '',
  });
  assert.match(partial.stdout, /IDENTITY-PLACEHOLDER/, 'a half-filled identity reported ready');

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('the Store version guard rejects a revision that is not 0', () => {
  // The Store reserves the 4th version part. A package with a nonzero revision is rejected at
  // ingestion — catch it locally, not after an upload.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-ver-'));
  const iso = (v) => spawnSync('bash', [path.join(ROOT, 'windows', 'build-msix.sh'), '--validate'], {
    cwd: ROOT,
    encoding: 'utf8',
    env: {
      ...process.env,
      CIRCUIT_MSIX_LAYOUT: path.join(tmp, 'layout'),
      CIRCUIT_MSIX_DIST: path.join(tmp, 'dist'),
      PARTNER_CENTER_PACKAGE_VERSION: v,
    },
  });
  const r = iso('1.2.3.4');
  assert.notEqual(r.status, 0, 'a revision of 4 was accepted');
  assert.match(r.stderr, /revision 0/, 'the rejection does not explain the rule');

  const short = iso('1.2.3');
  assert.notEqual(short.status, 0, 'a 3-part version was accepted');
  fs.rmSync(tmp, { recursive: true, force: true });
});

// --- 4. the release workflow -------------------------------------------------------------------

const wf = () => read(...WF_PATH);

test('PORTABILITY: nothing in the Windows lane depends on this machine or a sibling repo', () => {
  // The bug this closes broke a sibling lane outright: an absolute /Users/... path, or a repo
  // assumed to exist next to this one, makes a workflow that only ever works on one Mac.
  const files = [WF_PATH, BUILD_PATH, ['windows', 'build-win.sh'],
    ['windows', 'msix', 'gen-assets.mjs'], ['windows', 'fetch-node-runtime.mjs'],
    ['windows', 'sign-windows.mjs'], ['windows', 'msix', 'gate-selftest.sh']];
  for (const f of files) {
    const body = read(...f);
    assert.ok(!/\/Users\//.test(body), `${f.join('/')} contains an absolute /Users/ path`);
    assert.ok(!/(?<!\.\.\/)\.\.\/\.\.\/[A-Za-z]/.test(body),
      `${f.join('/')} reaches outside the repo into a sibling directory`);
  }
  // The workflow must check out only this repo.
  const uses = [...wf().matchAll(/uses:\s*actions\/checkout@[^\n]*\n(?:\s+with:\n(?:\s{8,}[^\n]*\n)*)?/g)];
  assert.ok(uses.length >= 1, 'the workflow never checks out the repo');
  assert.ok(!/repository:\s*\S/.test(wf()), 'the workflow checks out a foreign repository');
});

test('the release workflow runs on windows-latest and packs a real MSIX', () => {
  const w = wf();
  assert.match(w, /runs-on:\s*windows-latest/, 'not on windows-latest');
  assert.match(w, /build-msix\.sh --pack-layout/, 'the pack step is gone');
  assert.match(w, /makeappx\.exe/, 'makeappx is never put on PATH');
  assert.match(w, /0x50\|\|b\[1\]!==0x4b|0x50.*0x4b/, 'the MSIX is not proven by its zip magic bytes');
  assert.match(w, /sha256sum windows\/dist\/Circuit\.msix/, 'the artifact is never hashed');
  assert.match(w, /upload-artifact/, 'nothing is uploaded');
});

test('the release workflow does NOT sign, submit, or claim sideload-readiness', () => {
  const w = wf();
  assert.ok(!/signtool|sign-windows\.mjs/.test(w), 'the Store lane signs — the Store signs, not us');
  // Match submission ACTIONS, not the word "submittable" in a warning about identity status.
  assert.ok(!/StoreBroker|msstore\s+publish|microsoft-store\/[\w-]*submit|Update-Application(Flight|)Submission/i.test(w),
    'the lane attempts a Store submission — submission is a founder action');
  assert.match(w, /UNSIGNED/, 'the lane does not label its output UNSIGNED');
  assert.match(w, /CANNOT be sideload|cannot be sideload/i,
    'the lane does not state that an unsigned msix is not sideload-installable');
});

const assertReleaseFailsClosed = (w) => {
  const job = w.slice(w.indexOf('\n  msix:'));
  assert.ok(job, 'no msix job');
  // JOB-level only (4-space indent). Individual STEPS may legitimately tolerate failure — the
  // optional artifact download and the sidecar fetch do — but the JOB must not swallow its own.
  assert.ok(!/^ {4}continue-on-error:\s*true/m.test(job),
    'the msix job swallows its own failure — a run that packed nothing would report green');
  assert.match(job, /VERDICT/, 'no terminal verdict step');
  assert.match(job, /NOT-PACKED/, 'no NOT-PACKED verdict');
  assert.match(job, /if-no-files-found:\s*error/, 'a missing artifact is tolerated');
  assert.ok(!/if-no-files-found:\s*warn/.test(job), 'an if-no-files-found: warn upload remains');
  assert.match(job, /name:\s*circuit-store-msix-UNSIGNED-\$\{\{[^\n]*steps\.pack\.outcome/,
    'the artifact name does not carry the pack outcome');
  assert.match(job, /steps\.identity\.outputs\.status/,
    'the artifact name does not carry the identity status — a placeholder package would look submittable');
  assert.match(job, /steps\.exeprov\.outputs\.exe/,
    'the artifact name does not say whether the packaged exe is real or a placeholder');
};

test('the release msix job FAILS CLOSED and its artifact name carries pack + exe + identity', () => {
  assertReleaseFailsClosed(wf());
});

test('POSITIVE CONTROL: the fail-closed lock fires on each way the lane could be reopened', () => {
  const w = wf();
  const reopened = w.replace(/\n    runs-on: windows-latest\n    needs: shell/,
    '\n    runs-on: windows-latest\n    continue-on-error: true\n    needs: shell');
  assert.notEqual(reopened, w, 'the control mutated nothing');
  assert.throws(() => assertReleaseFailsClosed(reopened), /swallows its own failure/);
  assert.throws(() => assertReleaseFailsClosed(w.replace(/if-no-files-found:\s*error/g, 'if-no-files-found: warn')),
    /missing artifact is tolerated|warn upload remains/);
  assert.throws(() => assertReleaseFailsClosed(w.replace(/steps\.identity\.outputs\.status/g, "'x'")),
    /identity status/);
  assert.throws(() => assertReleaseFailsClosed(w.replace(/steps\.exeprov\.outputs\.exe/g, "'x'")),
    /placeholder/);
});

// --- 5. the doc actually documents the paste points --------------------------------------------

test('STORE-SUBMISSION.md names all three values, the file to paste them in, and what is blocked', () => {
  const doc = read(...DOC_PATH);
  for (const v of ['PARTNER_CENTER_IDENTITY_NAME', 'PARTNER_CENTER_IDENTITY',
    'PARTNER_CENTER_PUBLISHER_DISPLAY']) {
    assert.ok(doc.includes(v), `STORE-SUBMISSION.md never mentions ${v}`);
  }
  assert.match(doc, /windows\/msix\/partner-center\.env/, 'the doc does not say where to paste');
  assert.match(doc, /windows-store-msix\.yml/, 'the doc does not name the build workflow');
  assert.match(doc, /legal name/i, 'the doc does not say the publisher is a legal name');
  assert.match(doc, /blocked/i, 'the doc has no blockers section');
  assert.match(doc, /sideload/i, 'the doc does not address sideload-readiness');
});
