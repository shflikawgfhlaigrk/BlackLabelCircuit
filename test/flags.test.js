// Boolean-flag ("boolean-trap") rule: a top-level `boolFlags` count on every
// function object, and a Structure/maintainability finding at the measured-clean
// threshold >=2. Reuses the same signature path as the long-parameter rule.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { gradeFile } from '../lib/grade.js';
import { braceFunctions, indentFunctions, countBoolFlags, splitTopLevelParams } from '../lib/lang/common.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'flags');
const graph = analyzeRepo(FIX);
const flag = graph.nodes.find((n) => n.id === 'flag.js');
const FLAG_RE = /boolean flag parameters/;

test('boolFlags count threads onto every function object via analyzeRepo', () => {
  const byName = Object.fromEntries(flag.functions.map((f) => [f.name, f.boolFlags]));
  assert.equal(byName.twoFlags, 2);
  assert.equal(byName.oneFlag, 1);
  assert.equal(byName.noFlags, 0);
  assert.equal(byName.comparisonDefault, 0, 'a numeric default and a "truthy" param name are not flags');
});

test('a >=2-flag function flags; a single-flag one does not', () => {
  const flagged = flag.findings.filter((f) => FLAG_RE.test(f.msg));
  assert.equal(flagged.length, 1, 'exactly the two-flag function flags');
  const f = flagged[0];
  assert.equal(f.dim, 'structure');
  assert.match(f.msg, /`twoFlags` takes 2 boolean flag parameters/);
  // The single-flag (loadGraph-shaped) function must never appear.
  assert.ok(!flag.findings.some((x) => /`oneFlag`/.test(x.msg) && FLAG_RE.test(x.msg)));
});

test('the finding lands in Structure and deducts, boundary is exactly 2', () => {
  const base = { loc: 20, functions: [], todos: [], commentedOutBlocks: [], longLines: [], commentLines: 0, branchCount: 0, maxNesting: 1 };
  const flags = (boolFlags) => {
    const g = gradeFile({ metrics: { ...base, functions: [{ name: 'f', line: 1, length: 3, boolFlags }] }, signals: {}, imports: [], lang: 'javascript' });
    return g.findings.filter((x) => FLAG_RE.test(x.msg));
  };
  assert.equal(flags(1).length, 0, '1 flag is silent');
  assert.equal(flags(2).length, 1, '2 flags fires');
  assert.equal(flags(2)[0].dim, 'structure');
  // A function object with no boolFlags field (older callers) must not throw or flag.
  const g0 = gradeFile({ metrics: { ...base, functions: [{ name: 'f', line: 1, length: 3 }] }, signals: {}, imports: [], lang: 'javascript' });
  assert.equal(g0.findings.filter((x) => FLAG_RE.test(x.msg)).length, 0);
});

test('countBoolFlags: boolean-literal defaults across languages, guards on ==/>=', () => {
  assert.equal(countBoolFlags(''), 0);
  assert.equal(countBoolFlags('a, b, c'), 0);
  assert.equal(countBoolFlags('a, verbose = false'), 1);
  assert.equal(countBoolFlags('verbose = true, dryRun = false'), 2);
  assert.equal(countBoolFlags('verbose=True, x=False'), 2, 'Python True/False');
  assert.equal(countBoolFlags('flag: Bool = true'), 1, 'Swift typed default');
  assert.equal(countBoolFlags('a = trueColor, b = falsey'), 0, 'word-boundary: not a bare literal');
  assert.equal(countBoolFlags('n = 3, m = 10'), 0, 'numeric defaults are not flags');
});

test('splitTopLevelParams keeps generics/subscripts/nesting inside one segment', () => {
  assert.deepEqual(splitTopLevelParams(''), []);
  assert.deepEqual(splitTopLevelParams('a, b'), ['a', ' b']);
  assert.equal(splitTopLevelParams('a: Map<string, number>, b').length, 2);
  assert.equal(splitTopLevelParams('a = f(1, 2), b').length, 2);
});

test('braceFunctions and indentFunctions both carry a boolFlags field', () => {
  const js = braceFunctions('function g(a, verbose = true, dry = false) {\n  return a;\n}\n', /(?:^|\s)function\s+(\w+)/, 'javascript');
  assert.equal(js[0].boolFlags, 2);
  const py = indentFunctions('def h(a, verbose=True):\n    return a\n');
  assert.equal(py[0].boolFlags, 1);
});
