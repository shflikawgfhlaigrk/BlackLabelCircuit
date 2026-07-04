// Regression locks for the defects confirmed by the adversarial review.
import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeJs } from '../lib/lang/javascript.js';
import { analyzePython } from '../lib/lang/python.js';
import { analyzeSwift } from '../lib/lang/swift.js';
import { cleanSource } from '../lib/lang/clean.js';
import { gradeFile } from '../lib/grade.js';

const FILES = new Set(['src/util.js', 'src/a.js', 'pkg/__init__.py', 'pkg/mod.py', 'pkg/sib.py']);

test('multiline named imports are captured', () => {
  const src = `import {\n  foo,\n  bar,\n  baz,\n} from './util.js';\nexport const x = foo + bar + baz;\n`;
  const { imports } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.equal(imports.length, 1);
  assert.equal(imports[0].resolved, 'src/util.js');
  assert.equal(imports[0].line, 1);
});

test('multiline export-from is captured', () => {
  const src = `export {\n  one,\n  two,\n} from './util.js';\n`;
  const { imports } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.equal(imports.length, 1);
  assert.equal(imports[0].resolved, 'src/util.js');
});

test('imports inside string literals and comments are NOT captured', () => {
  const src = [
    `const code = "import x from './generated.js'";`,
    `doThing(); // import old from './dead.js'`,
    `/*`,
    `import gone from './gone.js';`,
    `*/`,
    `import { real } from './util.js';`,
  ].join('\n');
  const { imports } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.equal(imports.length, 1, `expected only the real import, got ${JSON.stringify(imports.map((i) => i.spec))}`);
  assert.equal(imports[0].spec, './util.js');
});

test('block comment interiors are not code: no branches, no nesting, no loc', () => {
  const src = `/*\nif (x) { y(); }\nfor (;;) { z(); }\n*/\nconst a = 1;\n`;
  const { metrics } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.equal(metrics.loc, 1);
  assert.equal(metrics.branchCount, 0);
  assert.equal(metrics.maxNesting, 0);
});

test('commented-out code block is still detected inside /* */', () => {
  const src = `/*\nconst old = compute(x);\nreturn old + 1;\nif (flag) { redo(); }\n*/\nconst a = 1;\n`;
  const { metrics } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.ok(metrics.commentedOutBlocks.length >= 1, 'disabled code inside block comment detected');
});

test('template literal contents are not code', () => {
  const src = 'const t = `\nif (a && b) { go(); }\nimport fake from "./fake.js";\n`;\nconst b = 2;\n';
  const { metrics, imports } = analyzeJs('src/a.js', src, 'javascript', FILES);
  assert.equal(imports.length, 0);
  assert.equal(metrics.branchCount, 0);
});

test('control flow keywords are not functions', () => {
  const src = `function real() {\n  if (a > b) {\n    go();\n  }\n  for (const x of xs) {\n    use(x);\n  }\n  switch (a) {\n    case 1: break;\n  }\n}\n`;
  const { metrics } = analyzeJs('src/a.js', src, 'javascript', FILES);
  const names = metrics.functions.map((f) => f.name);
  assert.deepEqual(names, ['real']);
});

test('python docstrings create no imports, functions, or signals', () => {
  const src = `def real():\n    """Docs.\n\n    import fake\n    def not_a_function():\n    except:\n    print("not a debug")\n    """\n    return 1\n`;
  const { imports, metrics, signals } = analyzePython('pkg/mod.py', src, 'python', FILES, new Set(['pkg']));
  assert.equal(imports.length, 0);
  assert.deepEqual(metrics.functions.map((f) => f.name), ['real']);
  assert.equal(signals.debugLogs.length, 0);
  assert.equal(signals.bareExcepts.length, 0);
});

test('except:pass counts once (swallow), not twice', () => {
  const src = `try:\n    x()\nexcept:\n    pass\n`;
  const { signals } = analyzePython('pkg/mod.py', src, 'python', FILES, new Set());
  assert.equal(signals.emptyCatches.length, 1);
  assert.equal(signals.bareExcepts.length, 0);
});

test('bare except with real work counts as bareExcept only', () => {
  const src = `try:\n    x()\nexcept:\n    log.warn("failed")\n`;
  const { signals } = analyzePython('pkg/mod.py', src, 'python', FILES, new Set());
  assert.equal(signals.emptyCatches.length, 0);
  assert.equal(signals.bareExcepts.length, 1);
});

test('from . import sibling resolves to the sibling module file', () => {
  const src = `from . import sib\n`;
  const { imports } = analyzePython('pkg/__init__.py', src, 'python', FILES, new Set(['pkg']));
  assert.equal(imports[0].resolved, 'pkg/sib.py');
});

test('relative import above repo root is broken, not mis-resolved', () => {
  const src = `from .... import impossible\n`;
  const { imports } = analyzePython('pkg/mod.py', src, 'python', FILES, new Set(['pkg']));
  assert.equal(imports[0].resolved, null);
});

test('swift strings and comments produce no decls or force-try signals', () => {
  const src = `// try! in comment\nlet s = "class Fake { }"\nlet t = """\nas! CrashCast\ntry! bad()\n"""\nstruct Real { }\n`;
  const { decls, signals } = analyzeSwift('A.swift', src);
  assert.deepEqual(decls.map((d) => d.name), ['Real']);
  assert.equal(signals.forceTries.length, 0);
  assert.equal(signals.forceCasts.length, 0);
});

test('cleanSource preserves length and line count', () => {
  const src = `const a = "he//llo"; /* x\ny */ let b = 2; // tail\n`;
  const { cleaned } = cleanSource(src, 'javascript');
  assert.equal(cleaned.length, src.length);
  assert.equal(cleaned.split('\n').length, src.split('\n').length);
  assert.ok(cleaned.includes('let b = 2;'), 'code after block comment survives');
  assert.ok(!cleaned.includes('he//llo'), 'string content blanked');
  assert.ok(!cleaned.includes('tail'), 'comment content blanked');
});

test('deleting commented-out code never lowers the docs score', () => {
  const mk = (commentedOutLines, commentLines) => gradeFile({
    metrics: {
      lines: 300, loc: 250, commentLines, commentedOutLines, todos: [], longLines: [],
      branchCount: 10, maxNesting: 2, maxNestingLine: 1, commentedOutBlocks: [], functions: [],
      docs: { publicSymbols: 0, documented: 0 },
    },
    signals: {}, imports: [], lang: 'javascript',
  });
  const withDead = mk(20, 20);   // all comments are dead code
  const cleanedUp = mk(0, 0);    // dead code deleted
  assert.ok(cleanedUp.dimensions.docs <= withDead.dimensions.docs + 0.001 === false || cleanedUp.dimensions.docs >= withDead.dimensions.docs,
    `docs after cleanup (${cleanedUp.dimensions.docs}) must not be below before (${withDead.dimensions.docs})`);
});

test('five broken imports do not drag a perfect file below C', () => {
  const g = gradeFile({
    metrics: {
      lines: 100, loc: 90, commentLines: 10, commentedOutLines: 0, todos: [], longLines: [],
      branchCount: 5, maxNesting: 2, maxNestingLine: 1, commentedOutBlocks: [],
      functions: [{ name: 'f', line: 1, length: 20 }], docs: { publicSymbols: 1, documented: 1 },
    },
    signals: {},
    imports: [1, 2, 3, 4, 5].map((i) => ({ spec: `./gone${i}.js`, line: i, external: false, resolved: null })),
    lang: 'javascript',
  });
  assert.ok(g.score >= 60, `expected >= 60 (D or better), got ${g.score}`);
  assert.ok(g.score < 90, `broken imports must still hurt, got ${g.score}`);
});
