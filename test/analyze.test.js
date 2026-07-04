import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo, stronglyConnected } from '../lib/analyze.js';
import { gradeFile, letterFor } from '../lib/grade.js';
import { resolveJsImport } from '../lib/lang/javascript.js';

const FIXTURE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'demo');
const graph = analyzeRepo(FIXTURE);
const node = (id) => graph.nodes.find((n) => n.id === id);
const linksFrom = (id) => graph.links.filter((l) => l.source === id);

test('discovers all fixture files', () => {
  const ids = graph.nodes.filter((n) => !n.missing).map((n) => n.id).sort();
  assert.deepEqual(ids, [
    'Thing.swift', 'User.swift', 'broken.json',
    'pkg/__init__.py', 'pkg/mod.py',
    'src/a.js', 'src/b.js', 'src/helper.js', 'src/index.js',
  ]);
});

test('resolves JS imports and flags the broken one', () => {
  const out = linksFrom('src/index.js');
  const targets = out.map((l) => l.target).sort();
  assert.ok(targets.includes('src/helper.js'), 'helper import resolves');
  assert.ok(targets.includes('src/a.js'), 'a import resolves');
  const broken = out.find((l) => l.broken);
  assert.ok(broken, 'missing.js import is a broken wire');
  assert.equal(broken.target, 'missing:./missing.js');
  assert.ok(node('missing:./missing.js')?.missing, 'phantom node exists');
  assert.equal(node('missing:./missing.js').grade, 'F');
});

test('detects the a↔b import cycle', () => {
  assert.ok(node('src/a.js').inCycle);
  assert.ok(node('src/b.js').inCycle);
  assert.ok(!node('src/helper.js').inCycle);
  assert.ok(node('src/a.js').findings.some((f) => f.msg.includes('cycle')));
  assert.equal(graph.stats.cycles, 1);
});

test('empty catch + debug log + TODO are flagged on index.js', () => {
  const findings = node('src/index.js').findings;
  assert.ok(findings.some((f) => f.msg.includes('Empty catch')), 'empty catch flagged');
  assert.ok(findings.some((f) => f.msg.toLowerCase().includes('debug print')), 'console.log flagged');
  assert.ok(findings.some((f) => f.msg.includes('TODO')), 'TODO flagged');
});

test('clean helper file grades A+ with no findings', () => {
  const h = node('src/helper.js');
  assert.equal(h.findings.length, 0);
  assert.equal(h.grade, 'A+');
});

test('python: broken relative import, bare except swallow, god function', () => {
  const init = node('pkg/__init__.py');
  const initLinks = linksFrom('pkg/__init__.py');
  assert.ok(initLinks.some((l) => l.target === 'pkg/mod.py' && !l.broken), 'relative import resolves');
  assert.ok(initLinks.some((l) => l.broken), 'nothere import is broken');
  assert.ok(init.findings.some((f) => f.msg.includes("doesn't resolve")));

  const mod = node('pkg/mod.py');
  assert.ok(mod.findings.some((f) => f.msg.includes('swallows the error')), 'except:pass flagged');
  assert.ok(mod.findings.some((f) => f.msg.includes('`big`')), 'long function flagged');
  assert.ok(mod.score < 75, `god-function file should grade poorly, got ${mod.score}`);
});

test('swift: typeref edge User→Thing and try! flagged', () => {
  const links = linksFrom('User.swift');
  assert.ok(links.some((l) => l.target === 'Thing.swift' && l.kind === 'typeref'), 'User references Thing');
  assert.ok(node('User.swift').findings.some((f) => f.msg.includes('`try!`')));
});

test('invalid JSON is a critical parse finding', () => {
  const j = node('broken.json');
  assert.ok(j.findings.some((f) => f.severity === 'critical' && f.msg.includes('does not parse')));
  assert.equal(j.grade[0], 'F');
});

test('repo stats aggregate correctly', () => {
  assert.equal(graph.stats.files, 9);
  assert.equal(graph.stats.brokenEdges, 2);
  assert.ok(graph.stats.score > 0 && graph.stats.score < 100);
  assert.equal(graph.stats.grade, letterFor(graph.stats.score));
  const buckets = Object.values(graph.stats.byGrade).reduce((a, b) => a + b, 0);
  assert.equal(buckets, 9);
});

test('letterFor boundaries', () => {
  assert.equal(letterFor(100), 'A+');
  assert.equal(letterFor(93), 'A');
  assert.equal(letterFor(90), 'A-');
  assert.equal(letterFor(83), 'B');
  assert.equal(letterFor(59.9), 'F');
  assert.equal(letterFor(0), 'F');
});

test('gradeFile: pristine metrics yield 100', () => {
  const g = gradeFile({
    metrics: { lines: 10, loc: 8, commentLines: 2, todos: [], longLines: [], branchCount: 1, maxNesting: 1, maxNestingLine: 1, commentedOutBlocks: [], functions: [{ name: 'f', line: 1, length: 8 }], docs: { publicSymbols: 1, documented: 1 } },
    signals: {}, imports: [], lang: 'javascript',
  });
  assert.equal(g.score, 100);
  assert.equal(g.grade, 'A+');
});

test('resolveJsImport handles index files and ts-for-js', () => {
  const files = new Set(['src/lib/index.ts', 'src/util.ts']);
  assert.equal(resolveJsImport('src/main.ts', './lib', files).resolved, 'src/lib/index.ts');
  assert.equal(resolveJsImport('src/main.ts', './util.js', files).resolved, 'src/util.ts');
  assert.equal(resolveJsImport('src/main.ts', 'react', files).external, true);
  assert.equal(resolveJsImport('src/main.ts', './nope', files).resolved, null);
});

test('stronglyConnected finds cycles, ignores self-contained chains', () => {
  const adj = new Map([
    ['a', ['b']], ['b', ['c']], ['c', ['a']], // 3-cycle
    ['d', ['a']], ['e', []],
  ]);
  const sccs = stronglyConnected(adj);
  assert.equal(sccs.length, 1);
  assert.deepEqual(sccs[0].sort(), ['a', 'b', 'c']);
});

test('watch: fs.watch path exclusions do not hide fixture paths', () => {
  // guard against the server ignore regex swallowing real source dirs
  const WATCH_IGNORE = /(^|\/)(\.[^/]+|node_modules|dist|build|DerivedData|__pycache__|venv|coverage|Pods)(\/|$)/;
  assert.ok(!WATCH_IGNORE.test('src/index.js'));
  assert.ok(!WATCH_IGNORE.test('pkg/mod.py'));
  assert.ok(WATCH_IGNORE.test('node_modules/x/y.js'));
  assert.ok(WATCH_IGNORE.test('.git/HEAD'));
  assert.ok(WATCH_IGNORE.test('.cursor/debug-xyz.log'));
});
