import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRepo, stronglyConnected } from '../lib/analyze.js';
import { gradeFile, letterFor } from '../lib/grade.js';
import { resolveJsImport } from '../lib/lang/javascript.js';
import { scanSecrets } from '../lib/lang/common.js';

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
  assert.equal(broken.target, 'missing:src/missing.js');
  assert.ok(node('missing:src/missing.js')?.missing, 'phantom node exists');
  assert.equal(node('missing:src/missing.js').grade, 'F');
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
  assert.ok(mod.score < 78, `god-function file should grade C+ or worse, got ${mod.score}`);
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

test('stats roll up parse errors and skipped files honestly (CI-17)', () => {
  // The demo fixture ships one unparseable file (broken.json) and no binaries.
  assert.equal(graph.stats.parseErrors, 1, 'broken.json rolls into parseErrors');
  assert.equal(graph.stats.skipped, 0, 'nothing skipped in the clean fixture');

  // A file that is binary masquerading as .js is skipped, not graded — and the
  // roll-up counts it without inflating the file count or the grade.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-skip-'));
  fs.writeFileSync(path.join(dir, 'ok.js'), 'export const a = 1;\n');
  fs.writeFileSync(path.join(dir, 'blob.js'), Buffer.from([0x00, 0x01, 0x02, 0x00, 0xff]));
  const g = analyzeRepo(dir);
  assert.equal(g.stats.files, 1, 'only the real source file is graded');
  assert.equal(g.stats.skipped, 1, 'the binary blob is counted as skipped');
  assert.equal(g.stats.parseErrors, 0, 'a skipped binary is not a parse error');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a folder with no gradeable source is reported empty — never a fake A+', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-empty-'));
  fs.writeFileSync(path.join(dir, 'README.md'), '# docs only, no source\n');
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'not code\n');
  const g = analyzeRepo(dir);
  assert.equal(g.stats.files, 0, 'no source files discovered');
  assert.equal(g.stats.empty, true, 'flagged empty');
  assert.equal(g.stats.grade, null, 'no letter grade minted for an empty repo');
  assert.equal(g.stats.score, null, 'no score minted for an empty repo');
  assert.equal(g.nodes.length, 0);
  fs.rmSync(dir, { recursive: true, force: true });
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

// ---- Hardcoded-secret detection (safety) ----

test('scanSecrets flags high-signal vendor key formats', () => {
  const hits = scanSecrets([
    'const a = 1;',
    'const awsKey = "AKIAIOSFODNN7EXAMPLE";',
    'slack = "xoxb-123456789012-abcdefghijkl";',
    'const gh = "ghp_abcdefghijklmnopqrstuvwxyz0123456789";',
  ].join('\n'));
  const kinds = hits.map((h) => h.kind);
  assert.ok(kinds.includes('AWS access key id'));
  assert.ok(kinds.includes('Slack token'));
  assert.ok(kinds.includes('GitHub token'));
  assert.equal(hits.find((h) => h.kind === 'AWS access key id').line, 2);
});

test('scanSecrets flags a credential assigned a literal, any language', () => {
  assert.equal(scanSecrets('password = "s3cr3t-live-value"').length, 1);
  assert.equal(scanSecrets('let apiKey: String = "8f3ac0b1d9e7"').length, 1);
  assert.equal(scanSecrets('client_secret: "9a8b7c6d5e4f3021"').length, 1);
});

test('scanSecrets does NOT flag env references, placeholders, or short values', () => {
  assert.equal(scanSecrets('password = process.env.DB_PASSWORD').length, 0);
  assert.equal(scanSecrets('password = os.environ["PW"]').length, 0);
  assert.equal(scanSecrets('const apiKey = `${API_KEY}`').length, 0);
  assert.equal(scanSecrets('password = "changeme"').length, 0);
  assert.equal(scanSecrets('password: "your-password-here"').length, 0);
  assert.equal(scanSecrets('api_key = "xxxx"').length, 0);       // placeholder
  assert.equal(scanSecrets('secret = "1234"').length, 0);         // too short
  assert.equal(scanSecrets('const password = "";').length, 0);    // empty
});

test('scanSecrets flags a connection string carrying an inline password', () => {
  const hits = scanSecrets([
    'const db = "postgres://admin:Pr0d-P4ssw0rd@10.2.3.4:5432/app";',
    'MONGO = "mongodb+srv://svc:8f3ac0b1d9e7@cluster0.abcd.mongodb.net"',
    'url = "mysql://root:hunter2secret@db.internal:3306/main"',
    'REDIS = "redis://:s3cr3tCacheKey@10.0.0.5:6379"',
    'broker = "amqp://rabbit:R4bb1tPass@broker:5672"',
  ].join('\n'));
  assert.equal(hits.length, 5);
  assert.match(hits[0].kind, /^postgres connection string/);
  assert.match(hits[1].kind, /^mongodb\+srv connection string/);
  assert.match(hits[3].kind, /^redis connection string/);  // empty user half
  assert.equal(hits[4].line, 5);
});

test('scanSecrets does NOT flag credential-free, placeholder, or env-ref connection strings', () => {
  assert.equal(scanSecrets('const db = "postgres://localhost:5432/app";').length, 0);      // no credentials
  assert.equal(scanSecrets('DSN = "postgres://user:<password>@host:5432/db"').length, 0);  // angle placeholder
  assert.equal(scanSecrets('uri = "mongodb+srv://user:password@cluster0.net"').length, 0); // placeholder word
  assert.equal(scanSecrets('const u = `postgres://${USER}:${PASS}@${HOST}/db`').length, 0); // env ref
  assert.equal(scanSecrets('DB = os.environ["postgres://u:p@h/db"]').length, 0);            // env ref
  assert.equal(scanSecrets('url = "mysql://root:test@localhost:3306/testdb"').length, 0);   // test fixture value
});

test('scanSecrets flags a JWT only when its header really decodes to a token', () => {
  const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    + '.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ'
    + '.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
  const hits = scanSecrets(`const token = "${jwt}";`);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].kind, 'JWT');
  assert.equal(hits[0].line, 1);
});

test('scanSecrets does NOT flag env-ref JWTs or base64-shaped strings that are not tokens', () => {
  const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    + '.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ'
    + '.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
  assert.equal(scanSecrets('const token = process.env.JWT_TOKEN').length, 0);
  assert.equal(scanSecrets(`const auth = \`Bearer \${${'token'}}\`; // ${jwt.slice(0, 0)}`).length, 0);
  // header decodes to JSON but carries no `alg` — not a JWT
  const notAlg = Buffer.from('{"hi":"there","x":1}').toString('base64url');
  assert.equal(scanSecrets(`const s = "${notAlg}.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijkl";`).length, 0);
  // three dot-separated base64url-ish segments that are not a token at all
  assert.equal(scanSecrets('const id = "eyJhbGciOiJ.notrealjson.xxxxxxxxxxxx";').length, 0);
});

test('analyzeRepo grades a connection string and a JWT as critical safety findings', () => {
  const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    + '.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ'
    + '.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-conn-'));
  fs.writeFileSync(path.join(dir, 'db.js'),
    `export const DSN = "postgres://admin:Pr0d-P4ssw0rd@10.2.3.4:5432/app";\nexport const TOKEN = "${jwt}";\n`);
  try {
    const g = analyzeRepo(dir);
    const n = g.nodes.find((x) => x.id === 'db.js');
    const conn = n.findings.find((f) => /connection string/.test(f.msg));
    const tok = n.findings.find((f) => /Hardcoded JWT/.test(f.msg));
    assert.ok(conn, 'connection-string finding is attached');
    assert.equal(conn.dim, 'safety');
    assert.equal(conn.severity, 'critical');
    assert.equal(conn.line, 1);
    assert.ok(tok, 'JWT finding is attached');
    assert.equal(tok.severity, 'critical');
    assert.equal(tok.line, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('analyzeRepo reports NO secret findings for a clean, env-driven config', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-clean-'));
  fs.writeFileSync(path.join(dir, 'cfg.js'),
    'export const DSN = process.env.DATABASE_URL;\n'
    + 'export const FALLBACK = "postgres://localhost:5432/app";\n'
    + 'export const SAMPLE = "mongodb+srv://user:<password>@cluster0.net";\n');
  try {
    const g = analyzeRepo(dir);
    const n = g.nodes.find((x) => x.id === 'cfg.js');
    const secretFindings = n.findings.filter((f) => /Hardcoded/.test(f.msg));
    assert.equal(secretFindings.length, 0, 'clean config produces zero secret findings');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('analyzeRepo grades a hardcoded secret as a critical safety finding', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-secret-'));
  fs.writeFileSync(path.join(dir, 'config.js'),
    'export const cfg = {\n  password: "prod-live-2f8e91ac",\n};\n');
  try {
    const g = analyzeRepo(dir);
    const n = g.nodes.find((x) => x.id === 'config.js');
    assert.ok(n, 'config.js node exists');
    const finding = n.findings.find((f) => /Hardcoded/.test(f.msg));
    assert.ok(finding, 'a hardcoded-credential finding is attached');
    assert.equal(finding.dim, 'safety');
    assert.equal(finding.severity, 'critical');
    assert.equal(finding.line, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
