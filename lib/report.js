// Headless reporting for CI: run analyzeRepo, gate on a minimum grade, and emit
// SARIF so findings show up as annotations in a PR / code-scanning UI.
// Zero-dependency (Node stdlib only) — SARIF is hand-built from the grade output.
import fs from 'node:fs';
import { analyzeRepo } from './analyze.js';
import { DIMENSIONS } from './grade.js';

// Letter grades from worst to best. Index gives an orderable rank so a
// `--min-grade` threshold can be compared without re-deriving score cutoffs.
export const GRADE_ORDER = [
  'F', 'D-', 'D', 'D+', 'C-', 'C', 'C+', 'B-', 'B', 'B+', 'A-', 'A', 'A+',
];

export function isGrade(g) {
  return typeof g === 'string' && GRADE_ORDER.includes(g);
}

// True iff `grade` is at least as good as `min`. A null/empty grade (no gradeable
// source — see CI-14) NEVER satisfies a threshold: honesty over a false pass.
export function meetsMinGrade(grade, min) {
  if (!isGrade(min)) throw new Error(`Invalid --min-grade "${min}". Use one of: ${GRADE_ORDER.join(', ')}`);
  if (!isGrade(grade)) return false;
  return GRADE_ORDER.indexOf(grade) >= GRADE_ORDER.indexOf(min);
}

// Finding severity → SARIF result level.
const SARIF_LEVEL = { critical: 'error', major: 'error', minor: 'warning', info: 'note' };

// Build a SARIF 2.1.0 log from an analyzeRepo() graph. Every file-level finding
// becomes a line-anchored result; phantom "missing" nodes have no file to anchor
// to, so they are skipped (their broken-wire finding is already on the importer).
export function buildSarif(graph) {
  const rules = new Map();
  const results = [];
  for (const n of graph.nodes ?? []) {
    if (n.missing) continue;
    for (const f of n.findings ?? []) {
      const ruleId = `circuit/${f.dim}`;
      if (!rules.has(ruleId)) {
        const dim = DIMENSIONS[f.dim];
        rules.set(ruleId, {
          id: ruleId,
          name: dim ? dim.label.replace(/\s+/g, '') : f.dim,
          shortDescription: { text: dim ? `${dim.label} (${Math.round(dim.weight * 100)}% of the grade)` : f.dim },
        });
      }
      // SARIF regions are 1-based; default to line 1 for file-level findings.
      const startLine = Number.isInteger(f.line) && f.line >= 1 ? f.line : 1;
      results.push({
        ruleId,
        level: SARIF_LEVEL[f.severity] ?? 'warning',
        message: { text: f.msg },
        locations: [{
          physicalLocation: {
            artifactLocation: { uri: n.id },
            region: { startLine },
          },
        }],
        properties: { dim: f.dim, severity: f.severity, points: f.points, fileGrade: n.grade, fileScore: n.score },
      });
    }
  }
  return {
    $schema: 'https://json.schemastore.org/sarif-2.1.0.json',
    version: '2.1.0',
    runs: [{
      tool: {
        driver: {
          name: 'Circuit',
          informationUri: 'https://blacklabelbots.com',
          rules: [...rules.values()],
        },
      },
      results,
    }],
  };
}

// Headless grade check. Analyses `root`, optionally writes SARIF to `sarifPath`,
// and — when `minGrade` is set — decides the exit code by comparing the repo
// grade against it. Returns a plain result object; the CLI does the printing.
export function runCheck({ root, minGrade = null, sarifPath = null }) {
  if (minGrade != null && !isGrade(minGrade)) {
    throw new Error(`Invalid --min-grade "${minGrade}". Use one of: ${GRADE_ORDER.join(', ')}`);
  }
  const graph = analyzeRepo(root);
  const { empty, grade, score } = graph.stats;

  let sarifResults = null;
  if (sarifPath) {
    const sarif = buildSarif(graph);
    sarifResults = sarif.runs[0].results.length;
    fs.writeFileSync(sarifPath, JSON.stringify(sarif, null, 2));
  }

  // With no threshold the check is informational (exit 0). With a threshold, an
  // empty repo (null grade) fails honestly rather than being minted a pass.
  let pass = null;
  let exitCode = 0;
  if (minGrade != null) {
    pass = meetsMinGrade(grade, minGrade);
    exitCode = pass ? 0 : 1;
  }

  return { empty, grade, score, minGrade, pass, exitCode, sarifPath, sarifResults, stats: graph.stats };
}
