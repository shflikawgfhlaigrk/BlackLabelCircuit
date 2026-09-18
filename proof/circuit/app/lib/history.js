// Grade-over-history "refactor movie" (CI-20). Walk a repo's local git history,
// materialize a sample of commits into throwaway worktrees, grade each with the
// real analyzeRepo, and return a per-commit timeline of per-node grades the UI
// can scrub through. Zero-dependency: git + node stdlib only, no network.
//
// Honesty rules that bite here:
//   - CI-17: large histories are SAMPLED, never faked. `dropped`/`notes` report
//     exactly how many commits were not graded, so a 20-frame movie over a
//     3,000-commit repo can never read as "every commit graded".
//   - CI-14 / §5.1: an empty or unparseable commit gets a null grade, never a
//     fabricated A+. Per-commit grades are the genuine analyzeRepo output only.
//   - The live working tree is NEVER touched — every commit is checked out into
//     an isolated `git worktree` under the OS temp dir and removed afterward.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { analyzeRepo } from './analyze.js';

// Hard ceilings. `sample` frames keep the on-screen replay interactive and the
// (synchronous, per-commit) grading pass bounded; `maxScan` caps how far back we
// read the log so listing history itself never runs away on a huge repo.
export const MAX_SAMPLE = 40;
export const DEFAULT_SAMPLE = 24;
const MAX_SCAN = 4000;
const UNIT = '\x1f'; // field sep unlikely to appear in a subject line

function git(root, args, opts = {}) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'], ...opts,
  });
}

export function isGitRepo(root) {
  try { git(root, ['rev-parse', '--git-dir']); return true; } catch { return false; }
}

export function headSha(root) {
  try { return git(root, ['rev-parse', 'HEAD']).trim(); } catch { return null; }
}

// Newest→oldest list of commits on the current branch's first-parent line.
// First-parent keeps the movie a clean spine instead of interleaving every merged
// side branch. Returns [{ sha, ts, author, subject }].
export function listCommits(root, maxScan = MAX_SCAN) {
  const fmt = ['%H', '%at', '%an', '%s'].join(UNIT);
  const out = git(root, ['log', '--first-parent', `-n${maxScan}`, `--pretty=format:${fmt}`]);
  if (!out.trim()) return [];
  return out.split('\n').map((line) => {
    const [sha, ts, author, subject] = line.split(UNIT);
    return { sha, ts: Number(ts) * 1000, author: author ?? '', subject: subject ?? '' };
  }).filter((c) => c.sha);
}

// Pick `sample` indices evenly across [0, n-1], always including both endpoints
// (oldest commit and HEAD) so the movie spans the repo's whole life.
export function sampleIndices(n, sample) {
  if (n <= sample) return Array.from({ length: n }, (_, i) => i);
  const idx = new Set();
  for (let k = 0; k < sample; k++) idx.add(Math.round((k * (n - 1)) / (sample - 1)));
  return [...idx].sort((a, b) => a - b);
}

// Grade one commit in an isolated worktree. Returns { grade, score, empty,
// files, parseErrors, nodes: { id: {score, grade} } }. Any failure (bad checkout,
// analyzer throw) yields a null-graded frame rather than aborting the movie.
function gradeCommit(root, base, sha) {
  const wt = path.join(base, sha.slice(0, 12));
  try {
    git(root, ['worktree', 'add', '--detach', '--force', wt, sha]);
  } catch (e) {
    return { error: `checkout failed: ${String(e?.message ?? e).split('\n')[0]}`, grade: null, score: null, empty: true, files: 0, parseErrors: 0, nodes: {} };
  }
  try {
    const g = analyzeRepo(wt);
    const nodes = {};
    for (const node of g.nodes) {
      if (node.missing) continue;
      nodes[node.id] = { score: node.score, grade: node.grade };
    }
    return {
      grade: g.stats.grade, score: g.stats.score, empty: g.stats.empty,
      files: g.stats.files, parseErrors: g.stats.parseErrors ?? 0, nodes,
    };
  } catch (e) {
    return { error: String(e?.message ?? e).split('\n')[0], grade: null, score: null, empty: true, files: 0, parseErrors: 0, nodes: {} };
  } finally {
    try { git(root, ['worktree', 'remove', '--force', wt]); }
    catch { try { fs.rmSync(wt, { recursive: true, force: true }); } catch { /* best effort */ } }
  }
}

// Build the timeline. `log(msg)` receives honesty roll-ups (what was dropped).
export function buildHistory(root, { sample = DEFAULT_SAMPLE, maxScan = MAX_SCAN, log = () => {} } = {}) {
  root = path.resolve(root);
  if (!isGitRepo(root)) return { supported: false, reason: 'not a git repository', commits: [] };
  sample = Math.max(2, Math.min(MAX_SAMPLE, sample | 0));

  const all = listCommits(root, maxScan);
  if (all.length === 0) return { supported: false, reason: 'no commits in history', commits: [] };
  if (all.length === 1) return { supported: false, reason: 'only one commit — nothing to replay', commits: [] };

  const scanTruncated = all.length >= maxScan;
  const picked = sampleIndices(all.length, sample);
  const dropped = all.length - picked.length;
  const notes = [];
  if (dropped > 0) {
    notes.push(`Sampled ${picked.length} of ${all.length} commits (evenly spaced across history) — ${dropped} commit(s) not graded.`);
  } else {
    notes.push(`Graded all ${all.length} commits in history.`);
  }
  if (scanTruncated) notes.push(`History scan capped at ${maxScan} commits — older commits were not considered.`);
  for (const n of notes) log(`[circuit] history: ${n}`);

  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-hist-'));
  const commits = [];
  try {
    // picked is newest→oldest (log order); walk oldest→newest so the resulting
    // timeline reads left(past)→right(HEAD) for the scrubber.
    for (const i of [...picked].reverse()) {
      const c = all[i];
      const graded = gradeCommit(root, base, c.sha);
      if (graded.error) log(`[circuit] history: commit ${c.sha.slice(0, 8)} not gradeable (${graded.error}) — null grade.`);
      commits.push({
        sha: c.sha, shortSha: c.sha.slice(0, 8), ts: c.ts, author: c.author, subject: c.subject,
        grade: graded.grade, score: graded.score, empty: graded.empty,
        files: graded.files, parseErrors: graded.parseErrors, nodes: graded.nodes,
        ...(graded.error ? { error: graded.error } : {}),
      });
    }
  } finally {
    try { fs.rmSync(base, { recursive: true, force: true }); } catch { /* best effort */ }
  }

  return {
    supported: true,
    root, name: path.basename(root),
    head: headSha(root),
    totalCommits: all.length,
    sampled: commits.length,
    dropped,
    scanTruncated,
    notes,
    commits,
  };
}
