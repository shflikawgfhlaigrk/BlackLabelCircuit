// Long-parameter-list rule: a top-level `params` count on every function object,
// and a Structure/maintainability finding at the measured-clean threshold >=6.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { gradeFile } from '../lib/grade.js';
import { braceFunctions, indentFunctions, countCommaParams } from '../lib/lang/common.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'params');
const graph = analyzeRepo(FIX);
const wide = graph.nodes.find((n) => n.id === 'wide.js');
const PARAM_RE = /takes \d+ parameters/;

test('param count threads onto every function object via analyzeRepo', () => {
  const byName = Object.fromEntries(wide.functions.map((f) => [f.name, f.params]));
  assert.equal(byName.sixArgs, 6);
  assert.equal(byName.fiveArgs, 5);
  assert.equal(byName.withGeneric, 5, 'a comma in a generic type must not inflate the count');
});

test('a >=6-parameter function flags; a 5-parameter one does not', () => {
  const flagged = wide.findings.filter((f) => PARAM_RE.test(f.msg));
  assert.equal(flagged.length, 1, 'exactly the six-arg function flags');
  const f = flagged[0];
  assert.equal(f.dim, 'structure');
  assert.match(f.msg, /`sixArgs` takes 6 parameters/);
  // The five-arg and generic (5) functions must never appear.
  assert.ok(!wide.findings.some((x) => /`fiveArgs`|`withGeneric`/.test(x.msg) && PARAM_RE.test(x.msg)));
});

test('the finding lands in Structure and deducts, boundary is exactly 6', () => {
  const base = { loc: 20, functions: [], todos: [], commentedOutBlocks: [], longLines: [], commentLines: 0, branchCount: 0, maxNesting: 1 };
  const flags = (params) => {
    const g = gradeFile({ metrics: { ...base, functions: [{ name: 'f', line: 1, length: 3, params }] }, signals: {}, imports: [], lang: 'javascript' });
    return g.findings.filter((x) => PARAM_RE.test(x.msg));
  };
  assert.equal(flags(5).length, 0, '5 params is silent');
  assert.equal(flags(6).length, 1, '6 params flags');
  assert.equal(flags(6)[0].dim, 'structure');
  // A function object with no params field (older callers) must not throw or flag.
  const g0 = gradeFile({ metrics: { ...base, functions: [{ name: 'f', line: 1, length: 3 }] }, signals: {}, imports: [], lang: 'javascript' });
  assert.equal(g0.findings.filter((x) => PARAM_RE.test(x.msg)).length, 0);
});

test('countCommaParams: top-level only, generics/subscripts/nesting do not split', () => {
  assert.equal(countCommaParams(''), 0);
  assert.equal(countCommaParams('   '), 0);
  assert.equal(countCommaParams('a'), 1);
  assert.equal(countCommaParams('a, b, c'), 3);
  assert.equal(countCommaParams('a: Map<string, number>, b: number'), 2);
  assert.equal(countCommaParams('a: number[], b: [x, y]'), 2);
  assert.equal(countCommaParams('a = f(1, 2), b'), 2);
});

test('braceFunctions and indentFunctions both carry a params field', () => {
  const js = braceFunctions('function g(a, b, c) {\n  return a;\n}\n', /(?:^|\s)function\s+(\w+)/, 'javascript');
  assert.equal(js[0].params, 3);
  const py = indentFunctions('def h(a, b):\n    return a\n');
  assert.equal(py[0].params, 2);
});
