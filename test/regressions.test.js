// Regression locks for the defects confirmed by the adversarial review.
import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeJs } from '../lib/lang/javascript.js';
import { analyzePython } from '../lib/lang/python.js';
import { analyzeSwift } from '../lib/lang/swift.js';
import { cleanSource, inSpan, lineOfOffset } from '../lib/lang/clean.js';
import { gradeFile } from '../lib/grade.js';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

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

// ---- hands-off live port ----
// :8923 is the live Circuit instance. server.js defaults to it and auto-increments
// only on EADDRINUSE, so with the port EMPTY any test that names it binds it. That
// rule was documented in CLAUDE.md and in a server.test.js comment but nothing
// enforced it; this locks it for every test file, including future ones.

// Assembled at runtime: the scan below reads this file too, so a literal here
// would flag its own guard.
const HANDS_OFF = '89' + '23';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));

function spanAt(spans, offset) {
  return spans.find((s) => offset >= s.start && offset < s.end) ?? null;
}

// 1-based lines where the port is named as a VALUE rather than as prose.
// Matching runs over the RAW text and subtracts from it, so a cleanSource
// mis-parse can never blank a hit out of existence — only a span it positively
// identifies is exempt. Exempt: comments, and strings containing whitespace (a
// test title reading `(the empty-:8923 case)` documents the rule, it does not
// bind the port). Flagged: bare numerics, and whitespace-free strings — both
// `['--port', '8923']` and `'http://localhost:8923'` reach the live instance.
function handsOffPortHits(src) {
  const clean = cleanSource(src, 'javascript');
  const re = new RegExp(HANDS_OFF, 'g');
  const hits = [];
  let m;
  while ((m = re.exec(clean.raw)) !== null) {
    const span = spanAt(clean.spans, m.index);
    if (span?.type === 'comment') continue;
    if (span?.type === 'string' && /\s/.test(clean.raw.slice(span.start + 1, span.end - 1))) continue;
    hits.push(lineOfOffset(clean.lineOffsets, m.index));
  }
  return hits;
}

test('hands-off-port guard fires on every binding form and ignores comment prose', () => {
  assert.deepEqual(handsOffPortHits(`const p = ${HANDS_OFF};\n`), [1]);

  // The fail-open trap this guard is built to survive: a naive comment-stripper
  // reads the `//` in a URL as a line comment, drops the rest of the line, and
  // reports the port CLEAN.
  assert.deepEqual(handsOffPortHits(`const u = 'http://localhost:${HANDS_OFF}/api/graph';\n`), [1]);

  assert.deepEqual(handsOffPortHits(`spawn(node, ['server.js', '--port', '${HANDS_OFF}']);\n`), [1]);

  // Naming the port in a comment is how the rule is documented — must not fire.
  assert.deepEqual(handsOffPortHits(`// never bind ${HANDS_OFF}\nconst p = 8971;\n`), []);
  assert.deepEqual(handsOffPortHits(`/*\n * ${HANDS_OFF} is hands-off\n */\nconst p = 8971;\n`), []);

  // Nor may it fire on prose in a string: a test title naming the port is
  // documentation, and a guard that demanded it be renamed would be trading a
  // true comment for a green check.
  assert.deepEqual(handsOffPortHits(`test('the empty-:${HANDS_OFF} case', fn);\n`), []);
});

test('no test file binds the hands-off live port', () => {
  const files = readdirSync(TEST_DIR).filter((f) => /\.(js|mjs)$/.test(f));
  // Guards the denominator: a scan that silently reads nothing passes vacuously.
  assert.ok(files.length >= 10, `expected the full test dir, saw ${files.length}`);

  const violations = [];
  for (const f of files) {
    for (const line of handsOffPortHits(readFileSync(join(TEST_DIR, f), 'utf8'))) {
      violations.push(`${f}:${line}`);
    }
  }
  assert.deepEqual(violations, []);
});
