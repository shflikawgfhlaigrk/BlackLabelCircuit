import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildHistory, listCommits, sampleIndices } from '../lib/history.js';

// Build a throwaway git repo with hand-authored commits so the timeline is
// deterministic. Commit config is passed inline so the test never depends on the
// machine's global git identity.
function git(cwd, ...args) {
  execFileSync('git', ['-c', 'user.email=t@example.com', '-c', 'user.name=Test', '-c', 'commit.gpgsign=false', ...args], { cwd, stdio: 'ignore' });
}

function makeRepo(commits) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-histtest-'));
  git(dir, 'init', '-q');
  git(dir, 'checkout', '-q', '-b', 'main');
  for (const c of commits) {
    // Reset tracked files so a commit's tree is exactly what it declares.
    for (const f of fs.readdirSync(dir)) {
      if (f === '.git') continue;
      fs.rmSync(path.join(dir, f), { recursive: true, force: true });
    }
    for (const [rel, body] of Object.entries(c.files)) {
      const abs = path.join(dir, rel);
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, body);
    }
    git(dir, 'add', '-A');
    git(dir, 'commit', '-q', '-m', c.msg);
  }
  return dir;
}

// A deliberately awful file: deep nesting, an eval, a swallowed error.
const BAD = `function handle(a){try{if(a){if(a>1){if(a>2){if(a>3){if(a>4){return eval(a);}}}}}}catch(e){}}\nmodule.exports={handle};\n`;
// A clean, documented, flat function.
const CLEAN = `// Add two numbers.\nexport function add(a, b) {\n  return a + b;\n}\n`;

test('sampleIndices spans endpoints and never exceeds the sample size', () => {
  assert.deepEqual(sampleIndices(3, 10), [0, 1, 2]); // fewer commits than the sample → all
  const s = sampleIndices(100, 5);
  assert.equal(s[0], 0);
  assert.equal(s[s.length - 1], 99);
  assert.ok(s.length <= 5);
});

test('grades three synthetic commits, oldest→newest, with grades that actually differ', () => {
  const dir = makeRepo([
    { msg: 'bad', files: { 'src/app.js': BAD } },
    { msg: 'improve', files: { 'src/app.js': BAD, 'src/util.js': CLEAN } },
    { msg: 'clean', files: { 'src/app.js': CLEAN } },
  ]);
  try {
    const notes = [];
    const hist = buildHistory(dir, { sample: 10, log: (m) => notes.push(m) });
    assert.equal(hist.supported, true);
    assert.equal(hist.commits.length, 3);
    // Chronological: past → HEAD.
    assert.deepEqual(hist.commits.map((c) => c.subject), ['bad', 'improve', 'clean']);
    // Every frame is a real grade (not null) since each commit has source.
    for (const c of hist.commits) assert.ok(c.grade != null && c.score != null, `commit ${c.subject} graded`);
    // The grade is genuinely different across the refactor — the whole point.
    const scores = hist.commits.map((c) => c.score);
    assert.ok(new Set(scores).size > 1, `scores should differ across commits, got ${scores}`);
    // The clean tip must out-grade the awful first commit.
    assert.ok(hist.commits[2].score > hist.commits[0].score, 'clean commit out-grades the bad one');
    // Per-node grades are present and keyed by repo-relative path.
    assert.ok(hist.commits[2].nodes['src/app.js'], 'HEAD frame carries per-node grade for src/app.js');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('sampling a larger history logs exactly what was dropped (CI-17 honesty)', () => {
  const dir = makeRepo([
    { msg: 'c1', files: { 'a.js': CLEAN } },
    { msg: 'c2', files: { 'a.js': BAD } },
    { msg: 'c3', files: { 'a.js': CLEAN } },
    { msg: 'c4', files: { 'a.js': BAD } },
  ]);
  try {
    const notes = [];
    const hist = buildHistory(dir, { sample: 2, log: (m) => notes.push(m) });
    assert.equal(hist.sampled, 2);
    assert.equal(hist.dropped, 2);
    assert.equal(hist.totalCommits, 4);
    // The drop is disclosed, not silently swallowed.
    assert.ok(hist.notes.some((n) => /Sampled 2 of 4/.test(n)), `notes disclose the sample: ${hist.notes}`);
    assert.ok(notes.some((m) => /Sampled 2 of 4/.test(m)), 'the log() sink received the honesty note');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a commit with no gradeable source gets a null grade, never a fabricated A+ (CI-14)', () => {
  const dir = makeRepo([
    { msg: 'docs only', files: { 'README.md': '# hello\n' } },
    { msg: 'add code', files: { 'README.md': '# hello\n', 'main.js': CLEAN } },
  ]);
  try {
    const hist = buildHistory(dir, { sample: 10 });
    assert.equal(hist.commits.length, 2);
    const first = hist.commits[0];
    assert.equal(first.subject, 'docs only');
    assert.equal(first.empty, true);
    assert.equal(first.grade, null, 'empty commit must not be minted a grade');
    assert.equal(first.score, null);
    // The next commit, which has source, grades for real.
    assert.ok(hist.commits[1].grade != null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a single-commit repo reports "nothing to replay" honestly', () => {
  const dir = makeRepo([{ msg: 'only', files: { 'a.js': CLEAN } }]);
  try {
    const hist = buildHistory(dir, { sample: 10 });
    assert.equal(hist.supported, false);
    assert.match(hist.reason, /one commit/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('listCommits returns first-parent commits newest-first with metadata', () => {
  const dir = makeRepo([
    { msg: 'first', files: { 'a.js': CLEAN } },
    { msg: 'second', files: { 'a.js': BAD } },
  ]);
  try {
    const commits = listCommits(dir);
    assert.equal(commits.length, 2);
    assert.equal(commits[0].subject, 'second'); // newest first
    assert.equal(commits[1].subject, 'first');
    assert.ok(commits[0].sha.length >= 40);
    assert.ok(Number.isFinite(commits[0].ts));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
