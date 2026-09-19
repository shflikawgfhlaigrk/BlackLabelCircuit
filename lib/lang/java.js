// Java: fully-qualified import graph. Every file declares a `package` and its
// public type matches the filename, so we build a FQN → file map and a set of
// first-party packages. An import of a class in one of OUR packages that has no
// backing file is a broken wire (crimson node); imports into java.* / third-
// party packages are external.
import fs from 'node:fs';
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

const JAVA_FN_RE = /(?:public|private|protected|static|final|abstract|synchronized|\s)+[\w<>\[\],.\s]+\s+(\w+)\s*\([^;{]*\)\s*(?:throws[\w,\s.]+)?\{/;

function typeName(rel) {
  return rel.slice(rel.lastIndexOf('/') + 1).replace(/\.java$/, '');
}

// Repo-level context: FQN → file, the set of first-party packages, and a
// package → representative file map (for wildcard imports).
export function buildJavaContext(root, files) {
  const fqn = new Map();
  const packages = new Set();
  const pkgFirst = new Map();
  for (const f of files) {
    if (f.lang !== 'java') continue;
    let content;
    try { content = fs.readFileSync(f.abs, 'utf8'); } catch { continue; }
    content = content.replace(/\r\n?/g, '\n');
    const clean = cleanSource(content, 'java');
    const pm = clean.cleaned.match(/^\s*package\s+([\w.]+)\s*;/m);
    const pkg = pm ? pm[1] : '';
    packages.add(pkg);
    const name = typeName(f.rel);
    fqn.set(pkg ? pkg + '.' + name : name, f.rel);
    if (!pkgFirst.has(pkg)) pkgFirst.set(pkg, f.rel);
  }
  return { fqn, packages, pkgFirst };
}

export function resolveJavaImport(spec, ctx) {
  const s = spec.replace(/^static\s+/, '').trim();
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
  // First-party package but no such class → a broken import (dead reference).
  if (ctx.packages.has(pkg)) return { external: false, resolved: null, spec, target: s };
  return { external: true, spec };
}

export function analyzeJava(rel, content, lang, fileSet, ctx) {
  const clean = cleanSource(content, 'java');
  const m = baseMetrics(clean, 'java');
  m.functions = braceFunctions(clean.cleaned, JAVA_FN_RE, 'java');

  const { rawLines, cleanedLines } = lineViews(clean);
  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    const im = cleanedLines[i].match(/^\s*import\s+(static\s+)?([\w.]+(?:\.\*)?)\s*;/);
    if (im) imports.push({ spec: (im[1] ?? '') + im[2], line: i + 1, ...resolveJavaImport((im[1] ?? '') + im[2], ctx) });
  }

  const signals = { debugLogs: [], emptyCatches: [], evals: [], panics: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/\bSystem\.(out|err)\.print/.test(code) || /\.printStackTrace\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (/\bcatch\s*\([^)]*\)\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
    else if (/\bcatch\s*\([^)]*\)\s*\{\s*$/.test(code) && (cleanedLines[i + 1] ?? '').trim() === '}') signals.emptyCatches.push(i + 1);
  }

  // Docs: public types/methods preceded by a Javadoc block (`*/`), skipping
  // annotation lines (`@Override`, `@Deprecated`, …) between doc and symbol.
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    if (!/^\s*public\s+(?:static\s+|final\s+|abstract\s+|synchronized\s+)*(?:(?:class|interface|enum|record)\s+\w+|[\w<>\[\],.\s]+\s+\w+\s*\()/.test(cleanedLines[i])) continue;
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
