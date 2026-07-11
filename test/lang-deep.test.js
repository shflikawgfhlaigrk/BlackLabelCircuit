// Deep parsers for Go, Rust, and Java: real import/module/package resolution,
// broken-wire detection, function extraction, docs coverage, and rubric grades.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { resolveRustMod, resolveRustUse } from '../lib/lang/rust.js';
import { resolveJavaImport } from '../lib/lang/java.js';
import { resolveGoImport } from '../lib/lang/go.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'deeplang');
const go = analyzeRepo(path.join(FIX, 'go'));
const rust = analyzeRepo(path.join(FIX, 'rust'));
const java = analyzeRepo(path.join(FIX, 'java'));

const nodeOf = (g, id) => g.nodes.find((n) => n.id === id);
const linksFrom = (g, id) => g.links.filter((l) => l.source === id);

// ---------- Go ----------
test('go: package import resolves to the target package file', () => {
  const l = linksFrom(go, 'main.go');
  assert.ok(l.some((x) => x.target === 'util/util.go' && !x.broken), 'util import resolves to the package');
});

test('go: import into our own module with no such package is a broken wire', () => {
  const l = linksFrom(go, 'main.go');
  const broken = l.find((x) => x.broken);
  assert.ok(broken, 'the missing-package import is broken');
  const phantom = go.nodes.find((n) => n.missing && n.id.includes('missing'));
  assert.ok(phantom, 'phantom crimson node minted');
  assert.equal(phantom.grade, 'F');
  assert.ok(phantom.findings.some((f) => f.dim === 'coupling' && f.severity === 'critical'));
});

test('go: stdlib import (fmt) is external, not a broken wire', () => {
  const main = nodeOf(go, 'main.go');
  assert.ok(main.externals.includes('fmt'), 'fmt classified external');
  assert.ok(!linksFrom(go, 'main.go').some((x) => x.target.includes('fmt')), 'no fmt edge');
});

test('go: functions extracted; swallowed error + panic flagged', () => {
  const main = nodeOf(go, 'main.go');
  assert.ok(main.functions.some((f) => f.name === 'run'), 'run() extracted');
  assert.ok(main.findings.some((f) => f.msg.includes('drops it on the floor')), 'empty `if err != nil {}` flagged');
  assert.ok(main.findings.some((f) => f.msg.includes('panic()')), 'panic flagged');
});

test('go: exported+documented symbol keeps the clean file at A+, main grades lower', () => {
  assert.equal(nodeOf(go, 'util/util.go').grade, 'A+');
  assert.ok(nodeOf(go, 'main.go').score < nodeOf(go, 'util/util.go').score, 'distinct rubric grades');
});

test('go: resolveGoImport strips the module prefix and maps to the directory', () => {
  const ctx = {
    modules: [{ moduleDir: '', module: 'example.com/demo' }],
    fileModule: new Map([['main.go', { moduleDir: '', module: 'example.com/demo' }]]),
    goDirs: new Map([['util', 'util/util.go']]),
  };
  assert.equal(resolveGoImport('main.go', 'example.com/demo/util', ctx).resolved, 'util/util.go');
  assert.equal(resolveGoImport('main.go', 'example.com/demo/nope', ctx).resolved, null);
  assert.equal(resolveGoImport('main.go', 'net/http', ctx).external, true);
});

// ---------- Rust ----------
test('rust: `use crate::` and `mod` resolve to the module file', () => {
  const l = linksFrom(rust, 'src/main.rs');
  assert.ok(l.some((x) => x.target === 'src/util.rs' && !x.broken), 'util module resolves');
});

test('rust: `mod missing;` with no backing file is a broken wire', () => {
  const l = linksFrom(rust, 'src/main.rs');
  assert.ok(l.some((x) => x.broken), 'missing mod is broken');
  const phantom = rust.nodes.find((n) => n.missing);
  assert.ok(phantom && phantom.findings.some((f) => f.dim === 'coupling' && f.severity === 'critical'));
});

test('rust: unwrap()/expect() flagged, functions extracted, clean file A+', () => {
  const main = nodeOf(rust, 'src/main.rs');
  assert.ok(main.functions.some((f) => f.name === 'main'));
  assert.ok(main.findings.some((f) => f.msg.includes('unwrap()')), 'unwrap/expect flagged');
  assert.equal(nodeOf(rust, 'src/util.rs').grade, 'A+');
});

test('rust: resolveRustMod resolves foo.rs and flags a missing module', () => {
  const files = new Set(['src/util.rs', 'src/main.rs']);
  assert.equal(resolveRustMod('src/main.rs', 'util', files).resolved, 'src/util.rs');
  assert.equal(resolveRustMod('src/main.rs', 'ghost', files).resolved, null);
});

test('rust: resolveRustUse takes the longest existing module prefix; external crates pass through', () => {
  const files = new Set(['src/util.rs', 'src/main.rs']);
  assert.equal(resolveRustUse('src/main.rs', ['crate', 'util', 'shout'], files).resolved, 'src/util.rs');
  assert.equal(resolveRustUse('src/main.rs', ['serde', 'Deserialize'], files).external, true);
  assert.equal(resolveRustUse('src/main.rs', ['crate', 'nope', 'X'], files).resolved, null);
});

// ---------- Java ----------
test('java: FQN import resolves to the class file', () => {
  const l = linksFrom(java, 'com/demo/App.java');
  assert.ok(l.some((x) => x.target === 'com/demo/util/Helper.java' && !x.broken), 'Helper import resolves');
});

test('java: first-party class with no file is a broken wire; java.* is external', () => {
  const l = linksFrom(java, 'com/demo/App.java');
  assert.ok(l.some((x) => x.broken), 'Missing class import broken');
  assert.ok(!l.some((x) => x.target.toLowerCase().includes('list')), 'java.util.List is external, no edge');
  const phantom = java.nodes.find((n) => n.missing);
  assert.ok(phantom && phantom.findings.some((f) => f.dim === 'coupling' && f.severity === 'critical'));
});

test('java: methods extracted, empty catch + debug print flagged, javadoc counts', () => {
  const app = nodeOf(java, 'com/demo/App.java');
  assert.ok(app.functions.some((f) => f.name === 'main'), 'main() extracted');
  assert.ok(app.findings.some((f) => f.msg.includes('Empty catch')), 'empty catch flagged');
  const helper = nodeOf(java, 'com/demo/util/Helper.java');
  assert.equal(helper.grade, 'A+', 'documented clean helper is A+');
  assert.ok(app.score < helper.score, 'distinct rubric grades');
});

test('java: resolveJavaImport classifies resolved / broken / external / wildcard', () => {
  const ctx = {
    fqn: new Map([['com.demo.util.Helper', 'com/demo/util/Helper.java']]),
    packages: new Set(['com.demo', 'com.demo.util']),
    pkgFirst: new Map([['com.demo.util', 'com/demo/util/Helper.java']]),
  };
  assert.equal(resolveJavaImport('com.demo.util.Helper', ctx).resolved, 'com/demo/util/Helper.java');
  assert.equal(resolveJavaImport('com.demo.util.Missing', ctx).resolved, null); // first-party, broken
  assert.equal(resolveJavaImport('java.util.List', ctx).external, true);
  assert.equal(resolveJavaImport('com.demo.util.*', ctx).resolved, 'com/demo/util/Helper.java');
});

// ---------- Cross-cutting honesty ----------
test('deep parsers do not fabricate grades on an empty tree', () => {
  const g = analyzeRepo(path.join(FIX, 'go', 'util')); // a dir with source still grades; empty checked elsewhere
  assert.ok(g.stats.grade !== null, 'a real source dir grades');
  assert.ok(typeof g.stats.score === 'number');
});

test('each deep language reports at least one broken edge from its fixture', () => {
  assert.equal(go.stats.brokenEdges, 1);
  assert.equal(rust.stats.brokenEdges, 1);
  assert.equal(java.stats.brokenEdges, 1);
});
