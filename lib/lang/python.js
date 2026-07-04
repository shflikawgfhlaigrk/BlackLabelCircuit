// Python: module import graph + review signals.
import path from 'node:path';
import { baseMetrics, indentFunctions } from './common.js';

// Resolve a python module path to a repo file: pkg.mod → pkg/mod.py | pkg/mod/__init__.py
function moduleToFile(parts, fileSet) {
  const base = parts.join('/');
  if (fileSet.has(base + '.py')) return base + '.py';
  if (fileSet.has(base + '/__init__.py')) return base + '/__init__.py';
  return null;
}

export function resolvePyImport(fromRel, stmt, fileSet, topPackages) {
  // stmt: {module, level} — level = number of leading dots for relative imports
  const fromDirParts = path.posix.dirname(fromRel.split(path.sep).join('/')).split('/').filter((p) => p !== '.');
  if (stmt.level > 0) {
    // relative: strip (level-1) dirs off the current package
    const baseParts = fromDirParts.slice(0, fromDirParts.length - (stmt.level - 1));
    if (baseParts.length < 0) return { external: false, resolved: null, spec: stmt.raw };
    const parts = stmt.module ? [...baseParts, ...stmt.module.split('.')] : baseParts;
    const resolved = moduleToFile(parts, fileSet) ?? (stmt.module ? null : moduleToFile([...parts, '__init__'], fileSet));
    return { external: false, resolved, spec: stmt.raw };
  }
  // absolute: only treat as internal when the top package exists in this repo
  const parts = stmt.module.split('.');
  const candidates = [];
  // try from repo root
  candidates.push(parts);
  // try relative to the importing file's directory (flat-script style repos)
  if (fromDirParts.length) candidates.push([...fromDirParts, ...parts]);
  for (const cand of candidates) {
    // try full path then progressively shorter (from pkg.mod.symbol imports)
    for (let n = cand.length; n >= 1; n--) {
      const hit = moduleToFile(cand.slice(0, n), fileSet);
      if (hit) return { external: false, resolved: hit, spec: stmt.raw };
    }
  }
  if (topPackages.has(parts[0])) {
    // names a local top-level package but no file matched → broken wire
    return { external: false, resolved: null, spec: stmt.raw };
  }
  return { external: true, spec: stmt.raw };
}

export function analyzePython(rel, content, lang, fileSet, topPackages) {
  const m = baseMetrics(content, 'python');
  m.functions = indentFunctions(content);

  const imports = [];
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let match;
    if ((match = line.match(/^\s*from\s+(\.*)([\w.]*)\s+import\s+/))) {
      const stmt = { level: match[1].length, module: match[2], raw: line.trim().slice(0, 60) };
      imports.push({ spec: (match[1] + match[2]) || '.', line: i + 1, ...resolvePyImport(rel, stmt, fileSet, topPackages) });
    } else if ((match = line.match(/^\s*import\s+([\w.]+(?:\s*,\s*[\w.]+)*)/))) {
      for (const mod of match[1].split(',').map((s) => s.trim().split(/\s+as\s+/)[0])) {
        const stmt = { level: 0, module: mod, raw: `import ${mod}` };
        imports.push({ spec: mod, line: i + 1, ...resolvePyImport(rel, stmt, fileSet, topPackages) });
      }
    }
  }

  const signals = { debugLogs: [], bareExcepts: [], evals: [], mutableDefaults: [], emptyCatches: [] };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const t = line.trim();
    if (t.startsWith('#')) continue;
    if (/^\s*print\s*\(/.test(line)) signals.debugLogs.push(i + 1);
    if (/\beval\s*\(|\bexec\s*\(/.test(line) && !/["'].*\beval\b.*["']/.test(line)) signals.evals.push(i + 1);
    if (/^\s*except\s*:/.test(line)) signals.bareExcepts.push(i + 1);
    if (/^\s*except\b.*:\s*$/.test(line)) {
      // except ...: followed only by pass → swallowed error
      for (let j = i + 1; j < Math.min(lines.length, i + 3); j++) {
        const nt = lines[j].trim();
        if (!nt || nt.startsWith('#')) continue;
        if (nt === 'pass' || nt === '...') signals.emptyCatches.push(i + 1);
        break;
      }
    }
    if (/def\s+\w+\s*\([^)]*=\s*(\[\]|\{\}|\(\))/.test(line)) signals.mutableDefaults.push(i + 1);
  }

  // Docstrings: def/class followed by a string literal
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^\s*(?:async\s+)?(?:def|class)\s+(\w+)/);
    if (!match || match[1].startsWith('_')) continue;
    publicSymbols++;
    for (let j = i + 1; j < Math.min(lines.length, i + 4); j++) {
      const t = lines[j].trim();
      if (!t) continue;
      if (t.startsWith('"""') || t.startsWith("'''") || t.startsWith('"') || t.startsWith("'")) documented++;
      break;
    }
  }
  m.docs = { publicSymbols, documented };
  return { metrics: m, imports, signals, decls: [] };
}
