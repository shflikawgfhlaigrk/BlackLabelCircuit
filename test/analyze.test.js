import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { analyzeRepo, readDiscoveredFile, stronglyConnected } from '../lib/analyze.js';
import { MAX_FILE_BYTES } from '../lib/walk.js';
import { gradeFile, letterFor, applyGraphFindings } from '../lib/grade.js';
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

test('tracked symlinks are excluded from parsing and counted as skipped', () => {
  // Git enumeration is required: before the fix, discoverFiles() used stat()
  // and followed the tracked file symlink.
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-symlink-'));
  const dir = path.join(workspace, 'project');
  const external = path.join(workspace, 'external');
  fs.mkdirSync(path.join(dir, 'nested'), { recursive: true });
  fs.mkdirSync(external);
  fs.writeFileSync(path.join(dir, 'real.js'), 'export const real = 1;\n');
  fs.writeFileSync(path.join(dir, 'nested', 'keep.js'), 'export const keep = 1;\n');
  fs.writeFileSync(path.join(external, 'linked.js'), 'export const external = 1;\n');
  fs.symlinkSync('../external/linked.js', path.join(dir, 'linked.js'));
  fs.symlinkSync('nested', path.join(dir, 'linked-tree'));
  const git = (...args) => execFileSync('git', [
    '-c', 'user.email=test@example.com', '-c', 'user.name=Circuit Test',
    '-c', 'commit.gpgsign=false', ...args,
  ], { cwd: dir, stdio: 'ignore' });
  git('init', '-q');
  git('add', '-A');
  git('commit', '-qm', 'generated symlink fixture');

  try {
    const graph = analyzeRepo(dir);
    const ids = graph.nodes.filter((n) => !n.missing).map((n) => n.id).sort();
    assert.deepEqual(ids, ['nested/keep.js', 'real.js']);
    assert.equal(graph.stats.skipped, 2, 'file and directory symlinks are visible as skipped');
    assert.equal(graph.nodes.some((n) => n.id === 'linked.js'), false, 'external target is not parsed');
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test('ancestor symlinks cannot escape the project root in Git or filesystem discovery', () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-ancestor-symlink-'));
  const external = path.join(workspace, 'external');
  const gitProject = path.join(workspace, 'git-project');
  const fsProject = path.join(workspace, 'fs-project');
  fs.mkdirSync(external);
  fs.mkdirSync(path.join(gitProject, 'src'), { recursive: true });
  fs.mkdirSync(path.join(fsProject, 'src'), { recursive: true });
  fs.writeFileSync(path.join(external, 'file.js'), 'export const escaped = 1;\n');
  fs.writeFileSync(path.join(gitProject, 'src', 'file.js'), 'export const project = 1;\n');
  fs.writeFileSync(path.join(fsProject, 'src', 'file.js'), 'export const project = 1;\n');

  const git = (...args) => execFileSync('git', [
    '-c', 'user.email=test@example.com', '-c', 'user.name=Circuit Test',
    '-c', 'commit.gpgsign=false', ...args,
  ], { cwd: gitProject, stdio: 'ignore' });
  git('init', '-q');
  git('add', '-A');
  git('commit', '-qm', 'generated ancestor fixture');
  fs.rmSync(path.join(gitProject, 'src'), { recursive: true, force: true });
  fs.symlinkSync(external, path.join(gitProject, 'src'));

  fs.rmSync(path.join(fsProject, 'src'), { recursive: true, force: true });
  fs.symlinkSync(external, path.join(fsProject, 'src'));

  try {
    const gitGraph = analyzeRepo(gitProject);
    assert.deepEqual(gitGraph.nodes.filter((n) => !n.missing), []);
    assert.equal(gitGraph.stats.skipped, 2, 'Git index entry and replaced ancestor are both counted');

    const fsGraph = analyzeRepo(fsProject);
    assert.deepEqual(fsGraph.nodes.filter((n) => !n.missing), []);
    assert.equal(fsGraph.stats.skipped, 1, 'filesystem walker counts the escaped ancestor symlink');
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test('descriptor reads reject overlimit metadata and same-inode size drift', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-read-guard-'));
  const filePath = path.join(dir, 'source.js');
  fs.writeFileSync(filePath, 'export const stable = 1;\n');
  const originalStat = fs.lstatSync(filePath);
  const descriptor = {
    abs: filePath,
    realPath: fs.realpathSync(filePath),
    dev: originalStat.dev,
    ino: originalStat.ino,
  };

  const originalOpen = fs.openSync;
  const originalFstat = fs.fstatSync;
  let openedFd;
  fs.openSync = (...args) => {
    openedFd = originalOpen(...args);
    return openedFd;
  };
  fs.fstatSync = (fd, ...args) => {
    const stat = originalFstat(fd, ...args);
    if (fd === openedFd) {
      return { dev: stat.dev, ino: stat.ino, size: MAX_FILE_BYTES + 1, isFile: () => true };
    }
    return stat;
  };
  try {
    assert.equal(readDiscoveredFile(descriptor), null, 'overlimit descriptor metadata is rejected');
  } finally {
    fs.openSync = originalOpen;
    fs.fstatSync = originalFstat;
  }

  const originalRead = fs.readSync;
  openedFd = undefined;
  let injected = false;
  fs.openSync = (...args) => {
    openedFd = originalOpen(...args);
    return openedFd;
  };
  fs.readSync = (fd, ...args) => {
    if (fd === openedFd && !injected) {
      injected = true;
      fs.appendFileSync(filePath, '// same inode grows during read\n');
    }
    return originalRead(fd, ...args);
  };
  try {
    assert.equal(readDiscoveredFile(descriptor), null, 'same-inode growth is rejected after bounded read');
    assert.equal(injected, true, 'the deterministic growth race ran');
  } finally {
    fs.openSync = originalOpen;
    fs.readSync = originalRead;
    fs.rmSync(dir, { recursive: true, force: true });
  }
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

test('analyzeRepo reports normal input and ten root, containment, and resource boundaries', () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-entry-boundaries-'));
  const result = (root) => {
    const graph = analyzeRepo(root);
    return {
      files: graph.stats.files,
      skipped: graph.stats.skipped,
      parseErrors: graph.stats.parseErrors,
      empty: graph.stats.empty,
      truncated: graph.truncated,
    };
  };
  const cases = [];
  const add = (name, setup, expected) => {
    const root = path.join(workspace, name);
    fs.mkdirSync(root, { recursive: true });
    setup(root);
    cases.push([name, result(root), expected]);
  };

  add('01-normal', (root) => {
    fs.writeFileSync(path.join(root, 'main.js'), 'const value = 1;\n');
  }, { files: 1, skipped: 0, parseErrors: 0, empty: false, truncated: false });

  cases.push(['02-missing-root', result(path.join(workspace, 'missing')), {
    files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false,
  }]);

  const fileRoot = path.join(workspace, '03-file-root');
  fs.writeFileSync(fileRoot, 'not a directory\n');
  cases.push(['03-file-root', result(fileRoot), {
    files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false,
  }]);

  add('04-empty-root', () => {}, {
    files: 0, skipped: 0, parseErrors: 0, empty: true, truncated: false,
  });

  add('05-external-leaf-link', (root) => {
    const external = path.join(workspace, 'external-leaf');
    fs.mkdirSync(external);
    fs.writeFileSync(path.join(external, 'outside.js'), 'const outside = 1;\n');
    fs.symlinkSync(path.join(external, 'outside.js'), path.join(root, 'linked.js'));
  }, { files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false });

  add('06-external-ancestor-link', (root) => {
    const external = path.join(workspace, 'external-ancestor');
    fs.mkdirSync(external);
    fs.writeFileSync(path.join(external, 'outside.js'), 'const outside = 1;\n');
    fs.symlinkSync(external, path.join(root, 'src'));
  }, { files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false });

  add('07-ignored-directory', (root) => {
    fs.mkdirSync(path.join(root, 'node_modules'));
    fs.writeFileSync(path.join(root, 'node_modules', 'ignored.js'), 'const ignored = 1;\n');
    fs.writeFileSync(path.join(root, 'kept.js'), 'const kept = 1;\n');
  }, { files: 1, skipped: 0, parseErrors: 0, empty: false, truncated: false });

  add('08-over-limit-file', (root) => {
    const fd = fs.openSync(path.join(root, 'large.js'), 'w');
    try { fs.ftruncateSync(fd, MAX_FILE_BYTES + 1); } finally { fs.closeSync(fd); }
  }, { files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false });

  add('09-binary-source', (root) => {
    fs.writeFileSync(path.join(root, 'binary.js'), Buffer.from('const value = 1;\0const other = 2;'));
  }, { files: 0, skipped: 1, parseErrors: 0, empty: true, truncated: false });

  add('10-invalid-json', (root) => {
    fs.writeFileSync(path.join(root, 'broken.json'), '{ invalid json');
  }, { files: 1, skipped: 0, parseErrors: 1, empty: false, truncated: false });

  add('11-max-files-boundary', (root) => {
    for (let i = 0; i < 4001; i++) {
      fs.writeFileSync(path.join(root, `f${String(i).padStart(4, '0')}.js`), 'const value = 1;\n');
    }
  }, { files: 4000, skipped: 0, parseErrors: 0, empty: false, truncated: true });

  try {
    for (const [name, actual, expected] of cases) assert.deepEqual(actual, expected, name);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
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

// ---- Cycle severity scales with cycle size (CI-23) ----
// A 2-file mutual import and a 30-file knot are not the same defect. These lock
// the ordering and the escalation, not the specific point values, so retuning the
// curve stays possible but flattening it back out cannot pass.

const CLEAN_DIMS = { complexity: 100, safety: 100, structure: 100, hygiene: 100, coupling: 100, docs: 100 };
const cleanNode = () => ({ findings: [], dimensions: { ...CLEAN_DIMS }, score: 100, grade: 'A+', parseFailed: false });
const gradeCycleOf = (size) => applyGraphFindings(cleanNode(), {
  cyclePeers: Array.from({ length: size - 1 }, (_, i) => `src/f${i}.js`),
  churn: 0,
});

test('cycle penalty is strictly monotonic in cycle size', () => {
  const sizes = [2, 3, 4, 5, 6, 10, 20];
  const scores = sizes.map((s) => gradeCycleOf(s).score);
  for (let i = 1; i < sizes.length; i++) {
    assert.ok(
      scores[i] < scores[i - 1],
      `a ${sizes[i]}-file cycle must grade strictly worse than a ${sizes[i - 1]}-file cycle (got ${scores[i]} vs ${scores[i - 1]})`
    );
  }
});

test('a cycle past 5 files escalates to critical; a small one stays major', () => {
  assert.equal(gradeCycleOf(2).findings[0].severity, 'major');
  assert.equal(gradeCycleOf(5).findings[0].severity, 'major');
  assert.equal(gradeCycleOf(6).findings[0].severity, 'critical');
  assert.equal(gradeCycleOf(12).findings[0].severity, 'critical');
});

test('the cycle finding names the real cycle size and stays capped', () => {
  assert.match(gradeCycleOf(7).findings[0].msg, /7-file import cycle/);
  assert.ok(gradeCycleOf(200).findings[0].points <= 30, 'penalty is capped, never unbounded');
  assert.ok(gradeCycleOf(200).dimensions.coupling >= 0, 'coupling never goes negative');
});

// ---- Blast radius: fan-in only counts against a file that already grades badly ----
// fanIn is a real graph fact the analyzer already measured. These lock the honesty
// property first — a clean hub must never be penalised for being depended upon —
// then the escalation, so the gate can be retuned but not inverted.

const WEAK_DIMS = { complexity: 70, safety: 70, structure: 70, hygiene: 70, coupling: 70, docs: 70 };
const weakNode = () => ({ findings: [], dimensions: { ...WEAK_DIMS }, score: 70, grade: letterFor(70), parseFailed: false });
const gradeFanIn = (fanIn, base = weakNode()) => applyGraphFindings(base, { cyclePeers: [], churn: 0, fanIn });

test('a clean hub is never penalised for being widely imported', () => {
  const hub = gradeFanIn(80, cleanNode());
  assert.equal(hub.findings.length, 0, 'being depended upon is not a defect — a clean hub must stay clean');
  assert.equal(hub.score, 100);
});

test('fan-in below the hub threshold raises nothing, even on a weak file', () => {
  assert.equal(gradeFanIn(9).findings.length, 0);
  assert.equal(gradeFanIn(10).findings.length, 1, 'a weak file with 10 dependents is a blast-radius hotspot');
});

test('blast radius is monotonic in fan-in and stays capped', () => {
  const fanIns = [10, 15, 20, 25, 26, 40, 100];
  const scores = fanIns.map((f) => gradeFanIn(f).score);
  for (let i = 1; i < fanIns.length; i++) {
    assert.ok(
      scores[i] < scores[i - 1],
      `${fanIns[i]} dependents must grade worse than ${fanIns[i - 1]} (got ${scores[i]} vs ${scores[i - 1]})`
    );
  }
  assert.ok(gradeFanIn(5000).findings[0].points <= 12, 'penalty is capped, never unbounded');
  assert.ok(gradeFanIn(5000).dimensions.coupling >= 0, 'coupling never goes negative');
});

test('a blast radius past 25 dependents escalates to major; a smaller one stays info', () => {
  assert.equal(gradeFanIn(10).findings[0].severity, 'info');
  assert.equal(gradeFanIn(25).findings[0].severity, 'info');
  assert.equal(gradeFanIn(26).findings[0].severity, 'major');
  assert.equal(gradeFanIn(60).findings[0].severity, 'major');
});

test('the blast-radius finding names the real dependent count and deducts from coupling', () => {
  const f = gradeFanIn(12).findings[0];
  assert.match(f.msg, /12 files import this/);
  assert.equal(f.dim, 'coupling');
});

test('analyzeRepo: a real weak hub is flagged with its real dependent count', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-fanin-'));
  try {
    // A genuinely bad hub — real defects the rubric already knows how to see
    // (swallowed errors, eval, a committed secret, deep nesting) drag it under
    // the gate, and 10 real importers give it a real fan-in of 10. Every number
    // asserted below is the analyzer's own output over this code.
    fs.writeFileSync(path.join(dir, 'hub.js'), [
      'export function go(cfg) {',
      '  const key = "sk_live_ABCDEF0123456789ABCDEF0123456789";',
      '  try { risky(); } catch (e) {}',
      '  try { more(); } catch (e) {}',
      '  try { again(); } catch (e) {}',
      '  eval(cfg.code);',
      '  if (cfg.a) { if (cfg.b) { if (cfg.c) { if (cfg.d) { if (cfg.e) { if (cfg.f) { if (cfg.g) { return key; } } } } } } }',
      '  return null;',
      '}',
      '',
    ].join('\n'));
    for (let i = 0; i < 10; i++) {
      fs.writeFileSync(path.join(dir, `leaf${i}.js`), `import { go } from './hub.js';\nexport const run${i} = () => go();\n`);
    }
    const g = analyzeRepo(dir);
    const hub = g.nodes.find((n) => n.id === 'hub.js');
    assert.equal(hub.fanIn, 10, 'fan-in is the real measured edge count');
    assert.ok(hub.score < 85, `the fixture must genuinely grade badly, not be asserted so (got ${hub.score})`);
    const blast = hub.findings.find((f) => /files import this/.test(f.msg));
    assert.ok(blast, `the weak hub must carry a blast-radius finding (grade ${hub.grade})`);
    assert.match(blast.msg, /10 files import this/);

    const leaf = g.nodes.find((n) => n.id === 'leaf0.js');
    assert.equal(leaf.findings.filter((f) => /files import this/.test(f.msg)).length, 0, 'a leaf has no dependents to endanger');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('analyzeRepo: a real 8-file knot grades worse than a real 2-file cycle', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-cycle-'));
  try {
    // Genuine on-disk repo: a↔b mutual import, plus an 8-file ring c0→c1→…→c7→c0.
    fs.writeFileSync(path.join(dir, 'a.js'), `import './b.js';\nexport const a = 1;\n`);
    fs.writeFileSync(path.join(dir, 'b.js'), `import './a.js';\nexport const b = 2;\n`);
    const RING = 8;
    for (let i = 0; i < RING; i++) {
      fs.writeFileSync(
        path.join(dir, `c${i}.js`),
        `import './c${(i + 1) % RING}.js';\nexport const c${i} = ${i};\n`
      );
    }
    const g = analyzeRepo(dir);
    const pick = (id) => g.nodes.find((n) => n.id === id);
    const small = pick('a.js');
    const knot = pick('c0.js');
    assert.ok(small.inCycle && knot.inCycle, 'both are detected as cyclic');
    assert.equal(g.stats.cycles, 2, 'two distinct strongly-connected components');

    const cycleFinding = (n) => n.findings.find((f) => /import cycle/.test(f.msg));
    assert.match(cycleFinding(small).msg, /2-file import cycle/);
    assert.match(cycleFinding(knot).msg, /8-file import cycle/);
    assert.equal(cycleFinding(small).severity, 'major');
    assert.equal(cycleFinding(knot).severity, 'critical');
    assert.ok(
      knot.score < small.score,
      `the 8-file knot must grade worse than the 2-file cycle (got ${knot.score} vs ${small.score})`
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
