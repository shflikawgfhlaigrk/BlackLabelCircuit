// Python mutable-default-argument safety rule. A list `[]` or dict `{}` literal
// default is shared across every call (the classic gotcha); an empty tuple `()`
// is IMMUTABLE and safe, and `=None` / a numeric default are the correct patterns.
// Regression-locks the rule AND the §5.1 guard against a fabricated defect: a
// safe `def f(x=())` must never be reported as a mutable default.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { analyzePython } from '../lib/lang/python.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'mutable');
const MUT_RE = /Mutable default argument/;

// The fixture def lines: with_list is line 5, with_dict is line 9. The tuple
// (line 12), None (line 15), and numeric (line 20) defaults must stay silent.
test('only [] and {} literal defaults flag, on their real def lines', () => {
  const graph = analyzeRepo(FIX);
  const node = graph.nodes.find((n) => n.id === 'defaults.py');
  const flagged = node.findings.filter((f) => MUT_RE.test(f.msg));
  assert.equal(flagged.length, 2, 'exactly the list and dict defaults flag');
  assert.deepEqual(flagged.map((f) => f.line).sort((a, b) => a - b), [5, 9]);
  for (const f of flagged) {
    assert.equal(f.dim, 'safety');
    assert.equal(f.severity, 'major');
  }
});

test('empty-tuple default `()` is immutable and is never flagged (§5.1)', () => {
  const s = analyzePython('t.py', 'def f(seen=()):\n    return seen\n', 'python', new Set(['t.py']), new Set()).signals;
  assert.deepEqual(s.mutableDefaults, [], 'an empty tuple is immutable — no fabricated defect');
});

test('list/dict literal defaults are detected at the signal level', () => {
  const list = analyzePython('a.py', 'def f(x=[]):\n    return x\n', 'python', new Set(['a.py']), new Set()).signals;
  assert.deepEqual(list.mutableDefaults, [1]);
  const dict = analyzePython('b.py', 'def f(x={}):\n    return x\n', 'python', new Set(['b.py']), new Set()).signals;
  assert.deepEqual(dict.mutableDefaults, [1]);
});

test('safe defaults (None, numeric) and a body assignment never flag', () => {
  const none = analyzePython('c.py', 'def f(x=None):\n    x = []\n    return x\n', 'python', new Set(['c.py']), new Set()).signals;
  assert.deepEqual(none.mutableDefaults, [], 'None default + `[]` in the body is not a mutable default');
  const num = analyzePython('d.py', 'def f(x=10):\n    return x\n', 'python', new Set(['d.py']), new Set()).signals;
  assert.deepEqual(num.mutableDefaults, []);
});

// A mutable default sitting AFTER an immutable tuple default used to hide behind
// the first close-paren of the `[^)]*` anchor. Parsing the whole signature fixes it.
test('a mutable default after a tuple default is no longer missed', () => {
  const s = analyzePython('e.py', 'def f(a=(), b=[]):\n    return a, b\n', 'python', new Set(['e.py']), new Set()).signals;
  assert.deepEqual(s.mutableDefaults, [1], 'b=[] must flag even though a=() comes first');
});

// Call-form constructors build a fresh shared object at def-time — same gotcha as
// the literal. `tuple()`/`frozenset()` are immutable and must stay silent (§5.1).
test('list()/dict()/set() constructor defaults flag; immutable constructors do not', () => {
  for (const ctor of ['list()', 'dict()', 'set()']) {
    const s = analyzePython('f.py', `def f(x=${ctor}):\n    return x\n`, 'python', new Set(['f.py']), new Set()).signals;
    assert.deepEqual(s.mutableDefaults, [1], `${ctor} is a mutable default`);
  }
  for (const ctor of ['tuple()', 'frozenset()', '()']) {
    const s = analyzePython('g.py', `def f(x=${ctor}):\n    return x\n`, 'python', new Set(['g.py']), new Set()).signals;
    assert.deepEqual(s.mutableDefaults, [], `${ctor} is immutable — never a fabricated defect`);
  }
});

// A non-empty list/dict literal is just as shared-mutable as an empty one.
test('non-empty [] / {} literal defaults also flag', () => {
  const lst = analyzePython('h.py', 'def f(x=[1, 2]):\n    return x\n', 'python', new Set(['h.py']), new Set()).signals;
  assert.deepEqual(lst.mutableDefaults, [1]);
  const dct = analyzePython('i.py', 'def f(x={"a": 1}):\n    return x\n', 'python', new Set(['i.py']), new Set()).signals;
  assert.deepEqual(dct.mutableDefaults, [1]);
});

// A method whose default merely calls something list-like on another object must
// not be mistaken for a builtin constructor (guards against a false positive).
test('an attribute call default (self.build()) is not flagged as a constructor', () => {
  const s = analyzePython('j.py', 'def f(x=obj.set()):\n    return x\n', 'python', new Set(['j.py']), new Set()).signals;
  assert.deepEqual(s.mutableDefaults, [], 'obj.set() is not the set() builtin');
});
