// Kotlin: fully-qualified import graph, resolved against declared packages and
// top-level symbols. A file declares a `package` and defines top-level symbols
// (classes/objects/interfaces/funs); we build a FQN → file map plus a set of
// first-party packages. An `import com.app.Missing` into one of OUR packages that
// names no defined symbol is a broken wire (crimson node); `kotlin.*`, `java.*`
// and third-party imports are external. Wildcard imports resolve to the package.
import fs from 'node:fs';
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

// Name immediately before the `(` so receiver funcs (`fun String.foo()`) and
// generic funcs (`fun <T> foo()`) both capture the method name, not the receiver.
const KOTLIN_FN_RE = /\bfun\s+[^(){}=;]*?(\w+)\s*\(/;
const DECL_RE = /^\s*(?:(?:public|internal|private|protected|open|final|abstract|sealed|data|inner|enum|annotation|value|external|expect|actual|companion)\s+)*(?:class|interface|object)\s+(\w+)/;
const TOP_FUN_RE = /^\s*(?:(?:public|internal|private|protected|open|final|abstract|external|expect|actual|inline|suspend|operator|infix|tailrec)\s+)*fun\s+(?:<[^>]*>\s*)?(?:[\w.<>,\s]+?\.)?(\w+)\s*\(/;

// Top-level symbols declared by a file: type declarations and top-level funs
// (funs indented under a class are members, not top-level — indentation 0 only).
function topLevelSymbols(cleanedLines) {
  const syms = [];
  for (const line of cleanedLines) {
    const d = line.match(DECL_RE);
    if (d) { syms.push(d[1]); continue; }
    // A top-level fun sits at column 0 (a member fun is indented inside a class).
    if (/^fun\s|^(?:public|internal|private|inline|suspend|operator|infix|tailrec)\s+fun\s/.test(line)) {
      const f = line.match(TOP_FUN_RE);
      if (f) syms.push(f[1]);
    }
  }
  return syms;
}

// Repo-level context: FQN (pkg.Symbol) → file, first-party packages, and a
// package → representative file map (for wildcard imports).
export function buildKotlinContext(root, files) {
  const fqn = new Map();
  const packages = new Set();
  const pkgFirst = new Map();
  for (const f of files) {
    if (f.lang !== 'kotlin') continue;
    let content;
    try { content = fs.readFileSync(f.abs, 'utf8'); } catch { continue; }
    content = content.replace(/\r\n?/g, '\n');
    const clean = cleanSource(content, 'kotlin');
    const { cleanedLines } = lineViews(clean);
    const pm = clean.cleaned.match(/^\s*package\s+([\w.]+)/m);
    const pkg = pm ? pm[1] : '';
    packages.add(pkg);
    if (!pkgFirst.has(pkg)) pkgFirst.set(pkg, f.rel);
    for (const s of topLevelSymbols(cleanedLines)) {
      fqn.set(pkg ? pkg + '.' + s : s, f.rel);
    }
  }
  return { fqn, packages, pkgFirst };
}

export function resolveKotlinImport(spec, ctx) {
  const s = spec.trim();
  if (s.endsWith('.*')) {
    const pkg = s.slice(0, -2);
    if (ctx.packages.has(pkg)) {
      const rep = ctx.pkgFirst.get(pkg);
      return rep ? { external: false, resolved: rep, spec } : { external: false, resolved: null, spec, target: pkg };
    }
    return { external: true, spec };
  }
  if (ctx.fqn.has(s)) return { external: false, resolved: ctx.fqn.get(s), spec };
  const pkg = s.includes('.') ? s.slice(0, s.lastIndexOf('.')) : '';
  // First-party package but no such top-level symbol → a broken import.
  if (ctx.packages.has(pkg)) return { external: false, resolved: null, spec, target: s };
  return { external: true, spec };
}

export function analyzeKotlin(rel, content, lang, fileSet, ctx) {
  const clean = cleanSource(content, 'kotlin');
  const m = baseMetrics(clean, 'kotlin');
  m.functions = braceFunctions(clean.cleaned, KOTLIN_FN_RE, 'kotlin');

  const { rawLines, cleanedLines } = lineViews(clean);

  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    // `import com.app.Foo` or `import com.app.Foo as Bar` or `import com.app.*`
    const im = cleanedLines[i].match(/^\s*import\s+([\w.]+(?:\.\*)?)(?:\s+as\s+\w+)?\s*$/);
    if (im) imports.push({ spec: im[1], line: i + 1, ...resolveKotlinImport(im[1], ctx) });
  }

  const signals = { debugLogs: [], emptyCatches: [], evals: [], panics: [], notNullAsserts: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/^\s*(?:println|print)\s*\(/.test(code) || /\bSystem\.(out|err)\.print/.test(code)) signals.debugLogs.push(i + 1);
    if (/\bcatch\s*\([^)]*\)\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
    else if (/\bcatch\s*\([^)]*\)\s*\{\s*$/.test(code) && (cleanedLines[i + 1] ?? '').trim() === '}') signals.emptyCatches.push(i + 1);
    // `!!` not-null assertion — Kotlin's force-unwrap. Ignore `!=` / `!!=`.
    if (/[\w)\]]\s*!!(?![=!])/.test(code)) signals.notNullAsserts.push(i + 1);
  }

  // Docs: non-private top-level / class declarations preceded by a KDoc block.
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    const isDecl = DECL_RE.test(line) || TOP_FUN_RE.test(line);
    if (!isDecl || /^\s*(?:private|internal)\b/.test(line)) continue;
    publicSymbols++;
    for (let j = i - 1; j >= Math.max(0, i - 4); j--) {
      const t = (rawLines[j] ?? '').trim();
      if (!t || t.startsWith('@')) continue;
      if (t.endsWith('*/') || t.startsWith('/**')) documented++;
      break;
    }
  }
  m.docs = { publicSymbols, documented };

  return { metrics: m, imports, signals, decls: [] };
}
