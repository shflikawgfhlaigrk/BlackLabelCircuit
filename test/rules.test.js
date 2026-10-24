import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { analyzeRepo } from '../lib/analyze.js';
import { globToRegExp, loadRules, findViolations } from '../lib/rules.js';

// Build a throwaway repo on disk and return its path.
function mkRepo(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-rules-'));
  for (const [rel, content] of Object.entries(files)) {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content);
  }
  return dir;
}
const rm = (d) => fs.rmSync(d, { recursive: true, force: true });

const nodeOf = (g, id) => g.nodes.find((n) => n.id === id);
const linkOf = (g, s, t) => g.links.find((l) => l.source === s && l.target === t);

// The same three source files reused across the violated/satisfied/no-rules cases.
// The import sits on line 2 so we can prove the finding is anchored to its real line.
const SRC = {
  'src/ui/button.js': `// ui button\nimport { query } from '../db/query.js';\nexport const b = query();\n`,
  'src/db/query.js': `export function query() { return 1; }\n`,
};

test('violated rule → weighted coupling finding + red edge + stats', () => {
  const dir = mkRepo({
    ...SRC,
    '.circuit-rules.json': JSON.stringify({
      forbidden: [{ from: 'src/ui/**', to: 'src/db/**', name: 'UI must not touch DB', severity: 'critical', points: 25 }],
    }),
  });
  try {
    const g = analyzeRepo(dir);
    const button = nodeOf(g, 'src/ui/button.js');

    const finding = button.findings.find((f) => f.rule);
    assert.ok(finding, 'a rule violation finding is attached to the offending file');
    assert.equal(finding.dim, 'coupling', 'it is a coupling finding');
    assert.equal(finding.severity, 'critical', 'severity honored from the rule');
    assert.equal(finding.points, 25, 'points honored from the rule');
    assert.equal(finding.line, 2, 'line-anchored to the offending import (line 2)');
    assert.ok(finding.msg.includes('forbidden dependency'), 'reads as a forbidden-dependency review comment');
    assert.ok(finding.msg.includes('UI must not touch DB'), 'includes the rule name');
    assert.ok(finding.msg.includes('src/db/**'), 'names the forbidden target glob');
    assert.ok(finding.msg.includes('../db/query.js'), 'names the actual offending import spec');

    const edge = linkOf(g, 'src/ui/button.js', 'src/db/query.js');
    assert.ok(edge, 'the import edge exists');
    assert.equal(edge.ruleViolation, true, 'the offending edge is marked for a red render');
    assert.equal(edge.broken, false, 'a rule violation is NOT a broken wire — the file resolves');

    assert.equal(g.stats.rules.count, 1, 'one rule loaded');
    assert.equal(g.stats.rules.violations, 1, 'one violation counted at repo level');

    // The violation must actually drag the grade, not just annotate.
    const clean = analyzeRepo(mkRepo(SRC)); // identical repo, no rules file
    assert.ok(
      nodeOf(g, 'src/ui/button.js').score < nodeOf(clean, 'src/ui/button.js').score,
      'the violating file scores lower than it would with no rule',
    );
    rm(clean.root);
  } finally { rm(dir); }
});

test('satisfied rule → nothing (no finding, no red edge, zero violations)', () => {
  // Same files, but the rule forbids the OTHER direction (db → ui), which nobody does.
  const dir = mkRepo({
    ...SRC,
    '.circuit-rules.json': JSON.stringify({ forbidden: [{ from: 'src/db/**', to: 'src/ui/**' }] }),
  });
  try {
    const g = analyzeRepo(dir);
    assert.ok(!nodeOf(g, 'src/ui/button.js').findings.some((f) => f.rule), 'no rule finding when satisfied');
    const edge = linkOf(g, 'src/ui/button.js', 'src/db/query.js');
    assert.ok(!edge.ruleViolation, 'no edge marked as a violation');
    assert.equal(g.stats.rules.violations, 0, 'zero violations reported');
    assert.equal(g.stats.rules.count, 1, 'the rule was still loaded — it just did not fire');
  } finally { rm(dir); }
});

test('no rules file → analysis is exactly as today', () => {
  const dir = mkRepo(SRC);
  try {
    const g = analyzeRepo(dir);
    assert.ok(!g.nodes.some((n) => n.findings.some((f) => f.rule)), 'no rule findings anywhere');
    assert.ok(!g.links.some((l) => l.ruleViolation), 'no edge carries a violation flag');
    assert.equal('rules' in g.stats, false, 'stats has no rules key — byte-for-byte todays shape');
    assert.equal('rulesError' in g.stats, false, 'no rules error either');
  } finally { rm(dir); }
});

test('default severity/points when omitted (critical / 20)', () => {
  const dir = mkRepo({
    ...SRC,
    '.circuit-rules.json': JSON.stringify({ forbidden: [{ from: 'src/ui/**', to: 'src/db/**' }] }),
  });
  try {
    const finding = nodeOf(analyzeRepo(dir), 'src/ui/button.js').findings.find((f) => f.rule);
    assert.equal(finding.severity, 'critical');
    assert.equal(finding.points, 20);
  } finally { rm(dir); }
});

test('malformed rules file is surfaced honestly, never crashes analysis', () => {
  const dir = mkRepo({ ...SRC, '.circuit-rules.json': '{ this is not json' });
  try {
    const g = analyzeRepo(dir); // must not throw
    assert.ok(typeof g.stats.rulesError === 'string', 'the parse error is surfaced in stats');
    assert.ok(!g.nodes.some((n) => n.findings.some((f) => f.rule)), 'no rules enforced from a broken file');
    assert.equal('rules' in g.stats, false, 'no rules object when the file is unusable');
  } finally { rm(dir); }
});

test('globToRegExp: segment vs cross-segment vs leading-segments', () => {
  const star = globToRegExp('src/*.js');
  assert.ok(star.test('src/a.js'));
  assert.ok(!star.test('src/x/a.js'), 'single * does not cross a path separator');

  const dstar = globToRegExp('src/**');
  assert.ok(dstar.test('src/a.js'));
  assert.ok(dstar.test('src/x/y/a.js'), '** crosses separators');
  assert.ok(!dstar.test('lib/a.js'));

  const lead = globToRegExp('**/util.js');
  assert.ok(lead.test('util.js'), '**/ matches zero leading segments');
  assert.ok(lead.test('a/b/util.js'), '**/ matches many leading segments');
  assert.ok(!lead.test('a/util.ts'));
});

test('loadRules ignores malformed entries and empty forbidden lists', () => {
  const dir = mkRepo({ 'a.js': 'export const a=1;\n' });
  try {
    fs.writeFileSync(path.join(dir, '.circuit-rules.json'), JSON.stringify({ forbidden: [] }));
    assert.equal(loadRules(dir).rules, null, 'an empty forbidden list is not an error, just no rules');

    fs.writeFileSync(path.join(dir, '.circuit-rules.json'), JSON.stringify({ forbidden: [{ from: 'x/**' }, { from: 'a/**', to: 'b/**' }] }));
    const { rules } = loadRules(dir);
    assert.equal(rules.forbidden.length, 1, 'entry missing "to" is dropped; valid entry kept');

    assert.equal(loadRules(dir).error, undefined);
    fs.writeFileSync(path.join(dir, '.circuit-rules.json'), JSON.stringify({ rules: [] }));
    assert.ok(loadRules(dir).error, 'a file with no forbidden array is a surfaced error');
  } finally { rm(dir); }
});

test('findViolations: first matching rule owns the edge, no rules → []', () => {
  const edges = [{ source: 'src/ui/a.js', target: 'src/db/b.js', spec: '../db/b.js', line: 1 }];
  assert.deepEqual(findViolations(edges, null), []);
  assert.deepEqual(findViolations(edges, { forbidden: [] }), []);
  const rules = loadRulesFromObject([{ from: 'src/ui/**', to: 'src/db/**' }]);
  const hits = findViolations(edges, rules);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].rule.to, 'src/db/**');
});

// helper: compile a rules object without touching disk
function loadRulesFromObject(forbidden) {
  return { forbidden: forbidden.map((e) => ({ ...e, fromRe: globToRegExp(e.from), toRe: globToRegExp(e.to), severity: 'critical', points: 20, name: e.name ?? null })) };
}
