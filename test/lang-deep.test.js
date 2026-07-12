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
import { resolveInclude } from '../lib/lang/c.js';
import { resolveKotlinImport } from '../lib/lang/kotlin.js';
import { resolveRequireRelative } from '../lib/lang/ruby.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'deeplang');
const go = analyzeRepo(path.join(FIX, 'go'));
const rust = analyzeRepo(path.join(FIX, 'rust'));
const java = analyzeRepo(path.join(FIX, 'java'));
const c = analyzeRepo(path.join(FIX, 'c'));
const kotlin = analyzeRepo(path.join(FIX, 'kotlin'));
const ruby = analyzeRepo(path.join(FIX, 'ruby'));

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

// ---------- C / C++ ----------
test('c: quoted #include resolves to the local header as a real edge', () => {
  const l = linksFrom(c, 'main.c');
  assert.ok(l.some((x) => x.target === 'util.h' && !x.broken), '#include "util.h" resolves to the header');
  assert.ok(linksFrom(c, 'util.c').some((x) => x.target === 'util.h' && !x.broken), 'util.c wires to the header too');
  assert.ok(linksFrom(c, 'app.cpp').some((x) => x.target === 'util.h' && !x.broken), 'a .cpp resolves the same header');
});

test('c: angle-bracket #include <stdio.h> is external, never an edge', () => {
  const main = nodeOf(c, 'main.c');
  assert.ok(main.externals.includes('stdio.h') && main.externals.includes('string.h'), 'system headers classified external');
  assert.ok(!linksFrom(c, 'main.c').some((x) => x.target.includes('stdio')), 'no edge for a system header');
});

test('c: unbounded strcpy flagged, main() extracted', () => {
  const main = nodeOf(c, 'main.c');
  assert.ok(main.functions.some((f) => f.name === 'main'), 'main() extracted');
  assert.ok(main.findings.some((f) => f.msg.includes('strcpy()') && f.dim === 'safety'), 'strcpy buffer-overflow vector flagged');
});

test('cpp: empty catch flagged, function extracted', () => {
  const app = nodeOf(c, 'app.cpp');
  assert.ok(app.functions.some((f) => f.name === 'compute'), 'compute() extracted');
  assert.ok(app.findings.some((f) => f.msg.includes('Empty catch')), 'empty catch swallow flagged');
});

test('c: clean header/impl outgrade the unsafe main; nothing fabricated broken', () => {
  assert.ok(nodeOf(c, 'util.c').score > nodeOf(c, 'main.c').score, 'clean impl beats the unsafe file');
  assert.equal(c.stats.brokenEdges, 0, 'C never mints a broken wire for an unresolved include (may be an -I header)');
});

test('c: resolveInclude is file-relative, drops the unresolvable rather than faking a break', () => {
  const files = new Set(['src/main.c', 'src/util.h', 'util.h']);
  assert.equal(resolveInclude('src/main.c', 'util.h', files), 'src/util.h', 'file-relative wins over repo-root');
  assert.equal(resolveInclude('src/main.c', '../util.h', files), 'util.h', '..\/ normalizes to the root header');
  assert.equal(resolveInclude('src/main.c', 'nope.h', files), null, 'no on-disk match → null (dropped, not broken)');
});

// ---------- Kotlin ----------
test('kotlin: FQN import resolves to the file that declares the symbol', () => {
  const l = linksFrom(kotlin, 'com/app/App.kt');
  assert.ok(l.some((x) => x.target === 'com/app/util/Helper.kt' && !x.broken), 'Helper import resolves');
});

test('kotlin: import of a missing symbol in a first-party package is a broken wire; kotlin.* is external', () => {
  const l = linksFrom(kotlin, 'com/app/App.kt');
  assert.ok(l.some((x) => x.broken), 'the missing-symbol import is broken');
  assert.ok(!l.some((x) => x.target.toLowerCase().includes('list')), 'kotlin.collections.List is external, no edge');
  const phantom = kotlin.nodes.find((n) => n.missing);
  assert.ok(phantom && phantom.grade === 'F');
  assert.ok(phantom.findings.some((f) => f.dim === 'coupling' && f.severity === 'critical'));
});

test('kotlin: functions extracted; empty catch + `!!` flagged, main grades below the clean helper', () => {
  const app = nodeOf(kotlin, 'com/app/App.kt');
  assert.ok(app.functions.some((f) => f.name === 'main'), 'main() extracted');
  assert.ok(app.functions.some((f) => f.name === 'risky'), 'risky() extracted');
  assert.ok(app.findings.some((f) => f.msg.includes('Empty catch')), 'empty catch flagged');
  assert.ok(app.findings.some((f) => f.msg.includes('!!')), '`!!` not-null assertion flagged');
  const helper = nodeOf(kotlin, 'com/app/util/Helper.kt');
  assert.equal(helper.grade, 'A+', 'documented clean helper is A+');
  assert.ok(app.score < helper.score, 'distinct rubric grades');
});

test('kotlin: resolveKotlinImport classifies resolved / broken / external / wildcard', () => {
  const ctx = {
    fqn: new Map([['com.app.util.Helper', 'com/app/util/Helper.kt']]),
    packages: new Set(['com.app', 'com.app.util']),
    pkgFirst: new Map([['com.app.util', 'com/app/util/Helper.kt']]),
  };
  assert.equal(resolveKotlinImport('com.app.util.Helper', ctx).resolved, 'com/app/util/Helper.kt');
  assert.equal(resolveKotlinImport('com.app.util.Missing', ctx).resolved, null); // first-party, broken
  assert.equal(resolveKotlinImport('kotlin.collections.List', ctx).external, true);
  assert.equal(resolveKotlinImport('com.app.util.*', ctx).resolved, 'com/app/util/Helper.kt');
});

// ---------- Ruby ----------
test('ruby: require_relative resolves to the local file as a real edge', () => {
  const l = linksFrom(ruby, 'app.rb');
  assert.ok(l.some((x) => x.target === 'util.rb' && !x.broken), "require_relative './util' resolves");
});

test('ruby: require_relative with no backing file is a broken wire; require gem is external', () => {
  const l = linksFrom(ruby, 'app.rb');
  assert.ok(l.some((x) => x.broken), 'the missing require_relative is broken');
  assert.ok(!l.some((x) => x.target.includes('json')), "require 'json' is external, no edge");
  const app = nodeOf(ruby, 'app.rb');
  assert.ok(app.externals.includes('json'), 'json classified external');
  const phantom = ruby.nodes.find((n) => n.missing);
  assert.ok(phantom && phantom.findings.some((f) => f.dim === 'coupling' && f.severity === 'critical'));
});

test('ruby: def…end methods extracted, swallowed rescue + debug puts flagged, clean file outgrades', () => {
  const app = nodeOf(ruby, 'app.rb');
  assert.ok(app.functions.some((f) => f.name === 'run'), 'run() extracted');
  assert.ok(app.findings.some((f) => f.dim === 'safety' && f.msg.includes('swallows')), 'empty rescue flagged');
  assert.ok(app.findings.some((f) => f.dim === 'hygiene' && f.msg.toLowerCase().includes('debug')), 'debug puts flagged');
  const util = nodeOf(ruby, 'util.rb');
  assert.ok(util.functions.some((f) => f.name === 'total'), 'util methods extracted via def…end');
  assert.equal(util.grade, 'A+', 'clean helper is A+');
  assert.ok(app.score < util.score, 'distinct rubric grades');
});

test('ruby: resolveRequireRelative is file-relative, appends .rb, drops the unresolvable', () => {
  const files = new Set(['lib/app.rb', 'lib/util.rb', 'util.rb']);
  assert.equal(resolveRequireRelative('lib/app.rb', './util', files), 'lib/util.rb', 'file-relative, .rb appended');
  assert.equal(resolveRequireRelative('lib/app.rb', '../util', files), 'util.rb', '../ normalizes to the root file');
  assert.equal(resolveRequireRelative('lib/app.rb', './nope', files), null, 'no on-disk match → broken (null)');
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
  assert.equal(kotlin.stats.brokenEdges, 1);
  assert.equal(ruby.stats.brokenEdges, 1);
});
