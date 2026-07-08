#!/usr/bin/env node
// Windows spike proof harness — runs the Circuit analyzer HEADLESSLY against a
// real repo on whatever OS the job runs on, asserts the grade output is REAL
// (not empty, not fabricated), prints a summary, and writes the grade JSON to
// disk for upload as a CI artifact.
//
//   node test/windows-spike-proof.mjs <repoPath> <outJsonPath>
//
// Exit codes: 0 = real grade produced and all assertions passed.
//             1 = grade missing / empty / fabricated (proof FAILS).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { letterFor, DIMENSIONS } from '../lib/grade.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const repoArg = process.argv[2] ?? path.resolve(__dirname, '..');
const outArg = process.argv[3] ?? path.resolve(process.cwd(), 'grade-output.json');
const repo = path.resolve(repoArg);
const out = path.resolve(outArg);

const fail = (msg) => { console.error(`[proof] FAIL: ${msg}`); process.exit(1); };

console.log(`[proof] RUNNER_OS=${process.env.RUNNER_OS ?? '(unset)'} platform=${os.platform()} arch=${os.arch()} node=${process.version}`);
console.log(`[proof] grading repo: ${repo}`);
if (!fs.existsSync(repo) || !fs.statSync(repo).isDirectory()) fail(`repo path is not a directory: ${repo}`);

const started = Date.now();
let g;
try {
  g = analyzeRepo(repo);
} catch (e) {
  fail(`analyzeRepo threw: ${e && e.stack ? e.stack : e}`);
}
const wall = Date.now() - started;

// ---- Assertions: the grade must be REAL, not a stub ----
const s = g && g.stats;
if (!s) fail('no stats object returned');
if (!Array.isArray(g.nodes) || g.nodes.length === 0) fail('no nodes — analyzer graded zero files');
const realNodes = g.nodes.filter((n) => !n.missing);
if (realNodes.length === 0) fail('zero real (non-phantom) files graded');
if (!(s.files > 0)) fail(`stats.files is not positive: ${s.files}`);
if (!(s.loc > 0)) fail(`stats.loc is not positive: ${s.loc}`);
// Score must be a real number in range, and its letter must match the rubric —
// this catches a hardcoded/fabricated grade that doesn't derive from the score.
if (typeof s.score !== 'number' || Number.isNaN(s.score) || s.score < 0 || s.score > 100) fail(`stats.score out of range: ${s.score}`);
const validGrades = new Set(['A+','A','A-','B+','B','B-','C+','C','C-','D+','D','D-','F']);
if (!validGrades.has(s.grade)) fail(`stats.grade not a valid letter: ${s.grade}`);
if (s.grade !== letterFor(s.score)) fail(`grade ${s.grade} does not derive from score ${s.score} (expected ${letterFor(s.score)}) — fabrication guard tripped`);
// Every real node must carry the full six-dimension rubric with in-range values —
// proves the grade came from the real rubric, not a placeholder.
const dimKeys = Object.keys(DIMENSIONS);
for (const n of realNodes) {
  if (!n.dimensions) fail(`node ${n.id} has no dimensions`);
  for (const k of dimKeys) {
    const v = n.dimensions[k];
    if (typeof v !== 'number' || v < 0 || v > 100) fail(`node ${n.id} dimension ${k} invalid: ${v}`);
  }
  if (typeof n.score !== 'number' || n.score < 0 || n.score > 100) fail(`node ${n.id} score invalid: ${n.score}`);
}
// A non-trivial repo should have real wiring (edges) and at least some findings —
// a stub that "grades everything A+ with no findings" would be a lie.
const totalFindings = realNodes.reduce((a, n) => a + (n.findings ? n.findings.length : 0), 0);

const summary = {
  proof: 'circuit-windows-spike',
  runnerOs: process.env.RUNNER_OS ?? null,
  platform: os.platform(),
  arch: os.arch(),
  node: process.version,
  repo,
  wallMs: wall,
  analyzerMs: g.tookMs,
  grade: s.grade,
  score: s.score,
  files: s.files,
  loc: s.loc,
  edges: s.edges,
  brokenEdges: s.brokenEdges,
  cycles: s.cycles,
  byGrade: s.byGrade,
  languages: s.languages,
  totalFindings,
  worstFiles: realNodes.slice().sort((a, b) => a.score - b.score).slice(0, 5).map((n) => ({ id: n.id, grade: n.grade, score: n.score })),
};

fs.writeFileSync(out, JSON.stringify({ summary, stats: s }, null, 2));

console.log('[proof] ===== REAL GRADE SUMMARY =====');
console.log(`[proof] repo=${path.basename(repo)}  GRADE=${s.grade}  score=${s.score}`);
console.log(`[proof] files=${s.files} loc=${s.loc} edges=${s.edges} broken=${s.brokenEdges} cycles=${s.cycles}`);
console.log(`[proof] languages=${JSON.stringify(s.languages)}`);
console.log(`[proof] byGrade=${JSON.stringify(s.byGrade)}`);
console.log(`[proof] totalFindings=${totalFindings} (real review comments across ${realNodes.length} files)`);
console.log('[proof] worst 5 files:');
for (const w of summary.worstFiles) console.log(`[proof]   ${w.grade}  ${w.score}  ${w.id}`);
console.log(`[proof] wrote grade JSON -> ${out}`);
console.log('[proof] ===== PROOF PASSED: real, rubric-derived grade produced on this OS =====');
process.exit(0);
