import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { buildSarif, meetsMinGrade, isGrade, runCheck, GRADE_ORDER } from '../lib/report.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const FIXTURE = path.join(ROOT, 'test', 'fixtures', 'demo');

function emptyRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-check-empty-'));
  fs.writeFileSync(path.join(dir, 'README.md'), '# docs only\n');
  return dir;
}

// ---- grade ordering -------------------------------------------------------
test('meetsMinGrade ranks letter grades correctly', () => {
  assert.ok(meetsMinGrade('A', 'B'), 'A clears a B bar');
  assert.ok(meetsMinGrade('B', 'B'), 'B clears its own bar');
  assert.ok(!meetsMinGrade('B-', 'B'), 'B- is below B');
  assert.ok(!meetsMinGrade('F', 'D-'), 'F is below everything');
  assert.ok(meetsMinGrade('A+', 'F'), 'A+ clears the floor');
});

test('a null/empty grade never satisfies a threshold — honest, not a false pass', () => {
  assert.equal(meetsMinGrade(null, 'F'), false);
  assert.equal(meetsMinGrade(undefined, 'F'), false);
});

test('meetsMinGrade rejects a nonsense min grade', () => {
  assert.throws(() => meetsMinGrade('A', 'Z'), /Invalid --min-grade/);
});

test('isGrade guards the grade vocabulary', () => {
  assert.ok(GRADE_ORDER.every(isGrade));
  assert.ok(!isGrade('Z'));
  assert.ok(!isGrade(null));
});

// ---- SARIF shape ----------------------------------------------------------
test('buildSarif emits a valid 2.1.0 log with line-anchored results', () => {
  const graph = analyzeRepo(FIXTURE);
  const sarif = buildSarif(graph);
  assert.equal(sarif.version, '2.1.0');
  assert.ok(sarif.$schema.includes('sarif-2.1.0'));
  const run = sarif.runs[0];
  assert.equal(run.tool.driver.name, 'Circuit');
  assert.ok(Array.isArray(run.results) && run.results.length > 0, 'has results');
  for (const r of run.results) {
    assert.ok(typeof r.ruleId === 'string' && r.ruleId.startsWith('circuit/'), 'ruleId namespaced');
    assert.ok(['error', 'warning', 'note'].includes(r.level), 'valid SARIF level');
    assert.ok(typeof r.message.text === 'string' && r.message.text.length > 0, 'has message');
    const region = r.locations[0].physicalLocation.region;
    assert.ok(Number.isInteger(region.startLine) && region.startLine >= 1, '1-based startLine');
    assert.ok(typeof r.locations[0].physicalLocation.artifactLocation.uri === 'string', 'has file uri');
  }
  // Every ruleId used resolves to a declared rule.
  const declared = new Set(run.tool.driver.rules.map((rule) => rule.id));
  for (const r of run.results) assert.ok(declared.has(r.ruleId), `${r.ruleId} declared`);
});

test('buildSarif never anchors to a phantom missing node', () => {
  const graph = analyzeRepo(FIXTURE);
  const missingIds = new Set(graph.nodes.filter((n) => n.missing).map((n) => n.id));
  const sarif = buildSarif(graph);
  for (const r of sarif.runs[0].results) {
    assert.ok(!missingIds.has(r.locations[0].physicalLocation.artifactLocation.uri), 'no phantom uri');
  }
});

// ---- runCheck exit codes --------------------------------------------------
test('runCheck passes when the repo meets the minimum grade', () => {
  const r = runCheck({ root: FIXTURE, minGrade: 'F' });
  assert.equal(r.empty, false);
  assert.equal(r.pass, true);
  assert.equal(r.exitCode, 0);
  assert.ok(isGrade(r.grade));
});

test('runCheck fails (exit 1) when the repo is below the minimum grade', () => {
  const r = runCheck({ root: FIXTURE, minGrade: 'A' });
  assert.equal(r.pass, false);
  assert.equal(r.exitCode, 1);
});

test('runCheck with no min-grade is informational (exit 0, no pass/fail)', () => {
  const r = runCheck({ root: FIXTURE });
  assert.equal(r.exitCode, 0);
  assert.equal(r.pass, null);
  assert.ok(isGrade(r.grade));
});

test('runCheck on an empty repo stays honest — null grade, no fabricated pass (CI-14)', () => {
  const dir = emptyRepo();
  try {
    const informational = runCheck({ root: dir });
    assert.equal(informational.empty, true);
    assert.equal(informational.grade, null, 'no grade minted for an empty repo');
    assert.equal(informational.exitCode, 0, 'no threshold → informational exit 0');

    const gated = runCheck({ root: dir, minGrade: 'F' });
    assert.equal(gated.grade, null, 'still no grade under a threshold');
    assert.equal(gated.pass, false, 'a null grade cannot pass a threshold');
    assert.equal(gated.exitCode, 1, 'empty repo fails the gate honestly');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('runCheck writes a SARIF file whose result count matches the log', () => {
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-sarif-')), 'out.sarif');
  const r = runCheck({ root: FIXTURE, sarifPath: out });
  assert.ok(fs.existsSync(out), 'sarif file written');
  const written = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(written.version, '2.1.0');
  assert.equal(written.runs[0].results.length, r.sarifResults);
  fs.rmSync(path.dirname(out), { recursive: true, force: true });
});

test('runCheck rejects an invalid --min-grade before analysing', () => {
  assert.throws(() => runCheck({ root: FIXTURE, minGrade: 'Z' }), /Invalid --min-grade/);
});

// ---- end-to-end CLI exit codes (real process, no HTTP server, never binds 8923) ----
function runCli(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['server.js', '--check', ...args], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { out += c; });
    child.on('exit', (code) => resolve({ code, out }));
  });
}

test('CLI --check exits 0 on pass and 1 on fail-on-min-grade', async () => {
  const pass = await runCli([FIXTURE, '--min-grade', 'F']);
  assert.equal(pass.code, 0, pass.out);
  assert.match(pass.out, /PASS/);

  const fail = await runCli([FIXTURE, '--min-grade', 'A']);
  assert.equal(fail.code, 1, fail.out);
  assert.match(fail.out, /FAIL/);
});

test('CLI --check on an empty repo with a threshold exits 1 and reports no grade', async () => {
  const dir = emptyRepo();
  try {
    const r = await runCli([dir, '--min-grade', 'F']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /no gradeable source/i);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('CLI --check writes SARIF to the requested path', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-cli-sarif-'));
  const out = path.join(tmp, 'circuit.sarif');
  try {
    const r = await runCli([FIXTURE, '--sarif', out]);
    assert.equal(r.code, 0, r.out);
    assert.ok(fs.existsSync(out), 'sarif written by CLI');
    const j = JSON.parse(fs.readFileSync(out, 'utf8'));
    assert.equal(j.version, '2.1.0');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
