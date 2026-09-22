// Circuit-Win MSIX packaging — regression lock (contract windows-w1-circuit-20260720,
// founder amendment ~09:05Z: STORE-FIRST via MSIX, the Store signs, NO Authenticode cert).
//
// These tests lock the STAGED Store-submission artifacts on darwin (the actual makeappx pack
// is Windows/VM-gated). They guard three things that would silently break a Store submission:
//   1. the AppxManifest is structurally what makeappx + the Store require,
//   2. the publisher identity is a PLACEHOLDER, never a hardcoded brand string
//      (Store publisher name is a cross-brand surface — founder/Partner-Center gate), and
//   3. the build recipe stages the Store artifact UNSIGNED (no self-sign on the Store path).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { TILES, encodePNG, readPngDims } from '../windows/msix/gen-assets.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const MANIFEST = path.join(ROOT, 'windows', 'msix', 'AppxManifest.xml');
const BUILD = path.join(ROOT, 'windows', 'build-msix.sh');
const ASSETS = path.join(ROOT, 'windows', 'msix', 'Assets');

const manifest = fs.readFileSync(MANIFEST, 'utf8');
const build = fs.readFileSync(BUILD, 'utf8');

test('AppxManifest.xml is present and structurally a Package', () => {
  assert.match(manifest, /<Package[\s>]/, 'missing <Package> root');
  assert.match(manifest, /<\/Package>\s*$/, 'Package root not closed at EOF');
  // XML comments must not contain a double hyphen — makeappx/xmllint reject it.
  const comments = manifest.match(/<!--[\s\S]*?-->/g) ?? [];
  for (const c of comments) {
    assert.ok(!c.slice(4, -3).includes('--'), `comment contains illegal "--": ${c.slice(0, 60)}…`);
  }
});

test('POSITIVE CONTROL: the Application entry point is exactly Circuit.exe / FullTrust', () => {
  // Fires on a real attribute value (not mere existence): if the manifest drifts to a
  // different executable or entry point the packaged app will not launch — catch it here.
  const exe = manifest.match(/<Application\b[^>]*\bExecutable="([^"]+)"/);
  assert.ok(exe, 'no <Application Executable="…">');
  assert.equal(exe[1], 'Circuit.exe');
  assert.match(manifest, /EntryPoint="Windows\.FullTrustApplication"/);
});

test('publisher identity is a PLACEHOLDER, never a hardcoded brand (cross-brand founder gate)', () => {
  const identity = manifest.match(/<Identity\b[\s\S]*?\/>/);
  assert.ok(identity, 'no <Identity> element');
  assert.match(identity[0], /Publisher="CN=[^"]*PLACEHOLDER[^"]*"/,
    'Publisher must stay a Partner-Center placeholder — the Store assigns the real CN=<hash>');
  // The display name is a founder cross-brand decision, resolved at submission — not baked in.
  assert.match(manifest, /<PublisherDisplayName>__PUBLISHER_DISPLAY_NAME__<\/PublisherDisplayName>/);
  // Hard stop: no RESOLVED brand string may be committed into the identity surface. A real
  // leak is a display-style CN with a space ("CN=Black Label Bots") or one naming the company
  // ("…Bots"); the placeholder token ("CN=BLACKLABEL-…-PLACEHOLDER") has neither, so this
  // fires on a real leak without flagging the intended placeholder.
  assert.ok(!/Publisher="CN=Black Label|Publisher="CN=[^"]*Bots/i.test(manifest),
    'a real brand publisher CN was hardcoded — that is a cross-brand leak (Stripe-portal class)');
});

test('targets the Win10-1809 floor (WebView2 Evergreen support) and does NOT fake a WebView2 dependency', () => {
  const tdf = manifest.match(/<TargetDeviceFamily\b[^>]*MinVersion="([^"]+)"/);
  assert.ok(tdf, 'no <TargetDeviceFamily>');
  assert.equal(tdf[1], '10.0.17763.0');
  // We deliberately did NOT invent a WebView2 <PackageDependency> (it is a system runtime,
  // not a Store framework package — a fabricated element would fail makeappx). Lock that.
  assert.ok(!/<PackageDependency\b[^>]*WebView2/i.test(manifest),
    'a WebView2 PackageDependency was fabricated — WebView2 is a system runtime, not declarable here');
});

test('runFullTrust is requested (node sidecar) and is the ONLY capability', () => {
  assert.match(manifest, /<rescap:Capability\s+Name="runFullTrust"\s*\/>/);
  const caps = manifest.match(/<(?:\w+:)?Capability\b/g) ?? [];
  assert.equal(caps.length, 1, 'exactly one capability (runFullTrust) is expected');
});

test('every Store tile exists as a REAL PNG at its exact spec dimensions (makeappx would fail otherwise)', () => {
  // The prior recipe staged TEXT files named "*.png"; makeappx rejects those and the VM cargo
  // build would pack-fail. Lock that the committed tiles are genuine PNGs at the required sizes.
  for (const { name, w, h } of TILES) {
    const f = path.join(ASSETS, name);
    assert.ok(fs.existsSync(f), `missing Store tile ${name}`);
    const d = readPngDims(f);
    assert.ok(d.sigOk, `${name} is not a real PNG (no signature) — makeappx would reject it`);
    assert.equal(d.w, w, `${name} width ${d.w} != required ${w}`);
    assert.equal(d.h, h, `${name} height ${d.h} != required ${h}`);
  }
});

test('every Assets\\*.png the manifest references is backed by a real tile file', () => {
  const refs = [...new Set([...manifest.matchAll(/Assets\\([A-Za-z0-9._-]+\.png)/g)].map((m) => m[1]))];
  assert.ok(refs.length >= 4, `expected ≥4 asset references, got ${refs.length}`);
  for (const name of refs) {
    const d = readPngDims(path.join(ASSETS, name));
    assert.ok(d.sigOk, `manifest references ${name} but it is missing or not a real PNG`);
  }
});

test('POSITIVE CONTROL: the PNG signature/dimension check rejects a bad asset', () => {
  // Prove the guard is not vacuous: a text buffer has no PNG signature, and a real PNG at the
  // wrong size is caught by the dimension comparison. Both must be detectable.
  const tmpBad = path.join(ROOT, 'windows', 'msix', '.__test_bad.png');
  const tmpWrong = path.join(ROOT, 'windows', 'msix', '.__test_wrong.png');
  try {
    fs.writeFileSync(tmpBad, 'PNG placeholder — not a real image');
    assert.equal(readPngDims(tmpBad).sigOk, false, 'a text file must NOT pass the PNG signature check');
    fs.writeFileSync(tmpWrong, encodePNG(10, 10, Buffer.alloc(10 * 10 * 4, 0xff)));
    const d = readPngDims(tmpWrong);
    assert.ok(d.sigOk && (d.w !== 50 || d.h !== 50), 'a 10x10 PNG must be distinguishable from the 50x50 StoreLogo spec');
  } finally {
    for (const f of [tmpBad, tmpWrong]) if (fs.existsSync(f)) fs.unlinkSync(f);
  }
});

test('POSITIVE CONTROL: --check rejects a tile carrying text-bearing metadata chunks', () => {
  // External rasterisers (sips, rsvg) add eXIf/tEXt routinely, and those chunks are a place a
  // cross-brand string or a source path can ride into a shipped Store tile. Prove the gate FIRES:
  // a clean tile passes, the SAME tile with a tEXt chunk spliced in front of IEND must not.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-tile-'));
  try {
    fs.mkdirSync(path.join(dir, 'Assets'));
    fs.copyFileSync(path.join(ROOT, 'windows/msix/gen-assets.mjs'), path.join(dir, 'gen-assets.mjs'));
    for (const { name } of TILES) {
      fs.copyFileSync(path.join(ROOT, 'windows/msix/Assets', name), path.join(dir, 'Assets', name));
    }
    const check = () => spawnSync(process.execPath, [path.join(dir, 'gen-assets.mjs'), '--check'], { encoding: 'utf8' });

    const clean = check();
    // mkdtemp hands back a symlinked path on macOS (/var -> /private/var). The entrypoint guard must
    // compare REAL paths; a `file://${argv[1]}` compare silently skips main() and exits 0 — fail-open.
    assert.equal(clean.status, 0, `clean tiles must pass --check: ${clean.stderr}`);
    assert.match(clean.stdout, /^ok /m, '--check exited 0 without checking anything (entrypoint guard did not fire)');

    const f = path.join(dir, 'Assets', TILES[0].name);
    const b = fs.readFileSync(f);
    const data = Buffer.from('Software test-taint', 'latin1');
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
    const td = Buffer.concat([Buffer.from('tEXt', 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td), 0);
    fs.writeFileSync(f, Buffer.concat([b.subarray(0, b.length - 12), len, td, crc, b.subarray(b.length - 12)]));

    const tainted = check();
    assert.notEqual(tainted.status, 0, '--check accepted a tile carrying a tEXt metadata chunk');
    assert.match(tainted.stderr, /METADATA CHUNKS/, 'the tainted tile was rejected for the wrong reason');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the pack lane bootstraps on existence only, so drifted final art can never be overwritten', () => {
  // If regeneration were still triggered by a failed --check, any drift in founder-approved final
  // art would be silently replaced by the placeholder motif and THAT would ship. Bootstrap must
  // key off --check-basic (existence), and a failed --check must abort the pack.
  assert.match(build, /gen-assets\.mjs" --check-basic/,
    'placeholder bootstrap is not gated by --check-basic — a drifted real tile would be overwritten');
  assert.match(build, /Refusing to pack/, 'a failed tile gate does not abort the pack');
  assert.ok(build.indexOf('--check-basic') < build.lastIndexOf('--check'),
    'the hard --check gate must run after the bootstrap step');
});

test('build-msix.sh stages REAL tiles (no text-file placeholder) and runs the pre-pack asset gate', () => {
  // The old fallback wrote `printf '…placeholder…' > *.png` — a makeappx trap. It must be gone,
  // replaced by real asset staging + a validation gate that checks every referenced PNG.
  assert.ok(!/printf[^\n]*>\s*"\$LAYOUT\/Assets/.test(build),
    'build-msix.sh still writes a TEXT placeholder into a *.png — makeappx would reject it');
  assert.match(build, /gen-assets\.mjs/, 'assets are not generated/validated from gen-assets.mjs');
  assert.match(build, /manifest-referenced Assets/, 'the pre-pack asset-existence gate is missing');
});

test('build-msix.sh stages the Store artifact UNSIGNED (Store signs) and packs with makeappx', () => {
  assert.match(build, /makeappx pack/, 'no makeappx pack step');
  // Git Bash hands makeappx POSIX paths (/d/a/...) which it reads relative to the current drive
  // (run 33730563460: "\\?\D:\d\a\...: The system cannot find the path specified"). The pack
  // call must pass cygpath-converted native paths, never $LAYOUT/$OUT raw.
  assert.match(build, /PACK_DIR="\$\(cygpath -w "\$LAYOUT"\)"/, 'the layout path is not converted to a native Windows path for makeappx');
  assert.match(build, /makeappx pack \/d "\$PACK_DIR" \/p "\$PACK_OUT"/, 'makeappx must receive the converted paths');
  // The Store path must not run signtool — signing is only in the explicit --sideload test mode.
  const storeSectionOnly = build.split('--sideload')[0];
  assert.ok(!/signtool|sign-windows\.mjs/.test(storeSectionOnly),
    'the Store path must stage UNSIGNED — no self-signing before makeappx/sideload');
  // Identity is resolved from Partner Center env, never guessed.
  assert.match(build, /PARTNER_CENTER_IDENTITY/);
  // A host-agnostic validate mode must exist so the layout+manifest are provable off-Windows.
  assert.match(build, /--validate/);
});

test('--pack-layout fails CLOSED when makeappx is absent: nonzero exit and NO .msix left behind', () => {
  // The trap this locks: a pack step that reports success (or leaves a truncated/fake file) on a
  // host with no Windows SDK would let "the layout is green" be read as "the Store package exists".
  // On darwin makeappx cannot exist, so the only honest outcome is a hard failure with no artifact.
  if (spawnSync('command', ['-v', 'makeappx'], { shell: true }).status === 0) return; // real Windows rig: not this test's host
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-pack-fail-'));
  const out = path.join(tmp, 'dist', 'Circuit.msix');
  const r = spawnSync('bash', [BUILD, '--pack-layout'], {
    cwd: ROOT,
    encoding: 'utf8',
    env: {
      ...process.env,
      CIRCUIT_MSIX_LAYOUT: path.join(tmp, 'layout'),
      CIRCUIT_MSIX_DIST: path.join(tmp, 'dist'),
    },
  });
  assert.notEqual(r.status, 0, '--pack-layout exited 0 without makeappx — a vacuous pack "success"');
  assert.match(String(r.stderr), /makeappx/, 'the failure must name the missing makeappx, not fail silently');
  assert.ok(!fs.existsSync(out), 'a failed pack left a Circuit.msix behind — that file would be a fake Store package');
  fs.rmSync(tmp, { recursive: true, force: true });
});

const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'windows-spike.yml');
const readMsixJob = () => {
  const wf = fs.readFileSync(WORKFLOW, 'utf8');
  return wf.slice(wf.indexOf('\n  msix:'));
};

test('CI msix job proves the packed artifact by magic bytes, not by mere presence', () => {
  // A workflow run's green check is not evidence of a package. The only thing that proves a real
  // pack is the artifact itself: makeappx writes an APPX/MSIX zip container, so the job must
  // assert the PK header + a sha256, never just `ls`.
  const msixJob = readMsixJob();
  assert.ok(msixJob.includes('build-msix.sh --pack-layout'), 'the msix job no longer invokes the pack step');
  assert.match(msixJob, /b\[:2\]\s*==\s*b'PK'/, 'the msix job stopped proving the PK/zip magic bytes of the packed .msix');
  assert.match(msixJob, /sha256sum windows\/dist\/Circuit\.msix/, 'the msix job stopped hashing the staged artifact');
  // Staged-only invariant: nothing in this job may sign, submit, or record a ship.
  assert.ok(!/signtool|sign-windows|ships\.jsonl|partner.*submit/i.test(msixJob),
    'the staged msix job must not sign, submit, or write a ship record');
});

// --- Fail-open lock (2026-07-22) ------------------------------------------------------------
// The hazard this closes: the msix job used to carry `continue-on-error: true` plus an upload with
// `if-no-files-found: warn`. Under that wiring a run where makeappx never packed anything reported
// SUCCESS and still uploaded an artifact whose NAME promised a Store package. "The Windows lane is
// green" then reads as "the .msix exists" — a claim nothing in the run had established.
const assertMsixFailsClosed = (job) => {
  assert.ok(!/^\s*continue-on-error:\s*true/m.test(job),
    'the msix job swallows its own failure (continue-on-error) — a run that packed nothing would report green');
  assert.match(job, /VERDICT/, 'no terminal verdict step: a run with no .msix would end silently');
  assert.match(job, /NOT-PACKED/, 'the job never emits a NOT-PACKED verdict');
  assert.match(job, /if-no-files-found:\s*error/,
    'the upload still tolerates a missing file — an empty artifact must be an error, not a warning');
  assert.ok(!/if-no-files-found:\s*warn/.test(job), 'an if-no-files-found: warn upload remains');
  // The artifact name must carry the outcome, so a downloader who never opens the zip cannot read
  // a bundle of logs as a package.
  assert.match(job, /name:\s*circuit-store-msix-UNSIGNED-STAGED-ONLY-\$\{\{[^}]*steps\.pack\.outcome/,
    'the artifact name does not carry the pack outcome');
};

test('CI msix job FAILS CLOSED: no continue-on-error, terminal verdict, outcome-tagged artifact', () => {
  assertMsixFailsClosed(readMsixJob());
});

test('POSITIVE CONTROL: the fail-closed lock actually fires on the old fail-open wiring', () => {
  // A grep-shaped assertion that never fails is worthless. Reconstruct the exact prior wiring and
  // prove each arm of the lock rejects it — otherwise this test is decoration.
  const job = readMsixJob();
  const reopened = job
    .replace(/\n    runs-on: windows-latest/, '\n    runs-on: windows-latest\n    continue-on-error: true')
    .replace(/if-no-files-found:\s*error/, 'if-no-files-found: warn')
    .replace(/name:\s*circuit-store-msix-UNSIGNED-STAGED-ONLY-\$\{\{[^\n]*/, 'name: circuit-store-msix-UNSIGNED-STAGED-ONLY');
  assert.notEqual(reopened, job, 'the positive control mutated nothing — it cannot prove anything');
  assert.throws(() => assertMsixFailsClosed(reopened), /continue-on-error/,
    'the lock accepted the historical fail-open job — it is vacuous');
  // Each remaining arm, isolated, must also fire.
  assert.throws(() => assertMsixFailsClosed(job.replace(/if-no-files-found:\s*error/, 'if-no-files-found: warn')),
    /tolerates a missing file/);
  assert.throws(() => assertMsixFailsClosed(job.replace(/VERDICT/g, 'NOTE').replace(/NOT-PACKED/g, 'nope')),
    /verdict/);
});
