// Python: module import graph + review signals, over cleaned source
// (docstrings and strings blanked — they can't fake imports or functions).
import path from 'node:path';
import { baseMetrics, indentFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

// Resolve a python module path to a repo file: pkg.mod → pkg/mod.py | pkg/mod/__init__.py
function moduleToFile(parts, fileSet) {
  const base = parts.join('/');
  if (fileSet.has(base + '.py')) return base + '.py';
  if (fileSet.has(base + '/__init__.py')) return base + '/__init__.py';
  return null;
}

export function resolvePyImport(fromRel, stmt, fileSet, topPackages) {
  // stmt: {module, level, names, raw} — level = leading dots on relative imports
  const fromDirParts = path.posix.dirname(fromRel.split(path.sep).join('/')).split('/').filter((p) => p !== '.');
  if (stmt.level > 0) {
    // `from .` strips 0 dirs, `from ..` strips 1, etc. More dots than dirs → escapes the repo.
    if (stmt.level - 1 > fromDirParts.length) return { external: false, resolved: null, spec: stmt.raw };
    const baseParts = fromDirParts.slice(0, fromDirParts.length - (stmt.level - 1));
    if (stmt.module) {
      const resolved = moduleToFile([...baseParts, ...stmt.module.split('.')], fileSet);
      return { external: false, resolved, spec: stmt.raw };
    }
    // `from . import a, b` — prefer sibling modules a.py over the package __init__.
    for (const name of stmt.names ?? []) {
      const hit = moduleToFile([...baseParts, name], fileSet);
      if (hit) return { external: false, resolved: hit, spec: stmt.raw };
    }
    const initPath = baseParts.length ? baseParts.join('/') + '/__init__.py' : '__init__.py';
    return { external: false, resolved: fileSet.has(initPath) ? initPath : null, spec: stmt.raw };
  }
  // absolute: only internal when the path exists in this repo
  const parts = stmt.module.split('.');
  const candidates = [parts];
  if (fromDirParts.length) candidates.push([...fromDirParts, ...parts]);
  for (const cand of candidates) {
    for (let k = cand.length; k >= 1; k--) {
      const hit = moduleToFile(cand.slice(0, k), fileSet);
      if (hit) return { external: false, resolved: hit, spec: stmt.raw };
    }
  }
  if (topPackages.has(parts[0])) {
    return { external: false, resolved: null, spec: stmt.raw }; // local package, missing file
  }
  return { external: true, spec: stmt.raw };
}

export function analyzePython(rel, content, lang, fileSet, topPackages) {
  const clean = cleanSource(content, 'python');
  const m = baseMetrics(clean, 'python');
  m.functions = indentFunctions(clean.cleaned);

  const { rawLines, cleanedLines } = lineViews(clean);
  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    let match;
    if ((match = line.match(/^\s*from\s+(\.*)([\w.]*)\s+import\s+(.*)$/))) {
      const names = match[3].replace(/[()#].*$/, '').split(',').map((s) => s.trim().split(/\s+as\s+/)[0]).filter((s) => /^\w+$/.test(s));
      const stmt = { level: match[1].length, module: match[2], names, raw: rawLines[i].trim().slice(0, 60) };
      imports.push({ spec: (match[1] + match[2]) || '.', line: i + 1, ...resolvePyImport(rel, stmt, fileSet, topPackages) });
    } else if ((match = line.match(/^\s*import\s+([\w.]+(?:\s*,\s*[\w.]+)*)/))) {
      for (const mod of match[1].split(',').map((s) => s.trim().split(/\s+as\s+/)[0])) {
        const stmt = { level: 0, module: mod, names: [], raw: `import ${mod}` };
        imports.push({ spec: mod, line: i + 1, ...resolvePyImport(rel, stmt, fileSet, topPackages) });
      }
    }
  }

  const signals = { debugLogs: [], bareExcepts: [], evals: [], mutableDefaults: [], emptyCatches: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    if (/^\s*print\s*\(/.test(line)) signals.debugLogs.push(i + 1);
    if (/\beval\s*\(|\bexec\s*\(/.test(line)) signals.evals.push(i + 1);
    // Mutable default argument (the classic Python shared-state gotcha): only a
    // list `[]` or dict `{}` literal is mutable. An empty tuple `()` is IMMUTABLE,
    // so `def f(x=())` is safe and must never be flagged — that would be a
    // fabricated defect (§5.1). The `[^)]*` keeps the match inside the signature.
    if (/def\s+\w+\s*\([^)]*=\s*(\[\]|\{\})/.test(line)) signals.mutableDefaults.push(i + 1);
    if (/^\s*except\b.*:\s*$/.test(line)) {
      // swallowed error (except ...: pass) counts once; a bare `except:` that
      // does real work is the lesser, separate finding — never both.
      let swallowed = false;
      for (let j = i + 1; j < Math.min(cleanedLines.length, i + 3); j++) {
        const nt = cleanedLines[j].trim();
        if (!nt) continue;
        if (nt === 'pass' || nt === '...') swallowed = true;
        break;
      }
      if (swallowed) signals.emptyCatches.push(i + 1);
      else if (/^\s*except\s*:/.test(line)) signals.bareExcepts.push(i + 1);
    }
  }

  // Docstrings: def/class followed by a string literal (check raw — cleaner keeps delimiters)
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    const match = cleanedLines[i].match(/^\s*(?:async\s+)?(?:def|class)\s+(\w+)/);
    if (!match || match[1].startsWith('_')) continue;
    publicSymbols++;
    for (let j = i + 1; j < Math.min(rawLines.length, i + 4); j++) {
      const t = rawLines[j].trim();
      if (!t) continue;
      if (t.startsWith('"""') || t.startsWith("'''") || t.startsWith('"') || t.startsWith("'")) documented++;
      break;
    }
  }
  m.docs = { publicSymbols, documented };
  return { metrics: m, imports, signals, decls: [] };
}
