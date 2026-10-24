// Go: package-path import graph + review signals. Go packages are directories,
// so resolution maps an import path (module prefix stripped) to the repo
// directory that holds it; an import into our own module that lands on a
// directory with no .go files is a broken wire (crimson node), exactly like a
// dead JS import. Standard-library and third-party paths are external.
import fs from 'node:fs';
import path from 'node:path';
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

const GO_FN_RE = /\bfunc\s+(?:\([^)]*\)\s*)?(\w+)/;

// Walk up from a directory to the nearest go.mod, reading its `module` path.
// Memoized per directory so a big repo reads each go.mod once.
function findModule(root, relDir, cache) {
  const key = relDir || '.';
  if (cache.has(key)) return cache.get(key);
  let res = null;
  const abs = path.join(root, relDir === '.' ? '' : relDir, 'go.mod');
  try {
    const txt = fs.readFileSync(abs, 'utf8');
    const m = txt.match(/^\s*module\s+(\S+)/m);
    if (m) res = { moduleDir: relDir === '.' ? '' : relDir, module: m[1] };
  } catch { /* no go.mod here */ }
  if (!res && key !== '.') {
    const parent = relDir.includes('/') ? relDir.slice(0, relDir.lastIndexOf('/')) : '.';
    res = findModule(root, parent, cache);
  }
  cache.set(key, res);
  return res;
}

// Repo-level context: for each .go file its owning module, the set of module
// declarations, and a directory → representative .go file map (the edge target).
export function buildGoContext(root, files) {
  const goDirs = new Map();   // dir → first (sorted) .go file rel — the package's stand-in node
  const fileModule = new Map();
  const modules = [];
  const modSeen = new Set();
  const cache = new Map();
  for (const f of files) {
    if (f.lang !== 'go') continue;
    const dir = f.rel.includes('/') ? f.rel.slice(0, f.rel.lastIndexOf('/')) : '.';
    if (!goDirs.has(dir)) goDirs.set(dir, f.rel); // files arrive sorted → lexicographically first
    const mod = findModule(root, dir, cache);
    fileModule.set(f.rel, mod);
    if (mod) {
      const k = mod.moduleDir + '\0' + mod.module;
      if (!modSeen.has(k)) { modSeen.add(k); modules.push(mod); }
    }
  }
  return { goDirs, fileModule, modules };
}

export function resolveGoImport(rel, spec, ctx) {
  // Longest matching module path wins (nested modules); the file's own module
  // is preferred on a tie so a vendored copy can't hijack resolution.
  let best = null;
  const own = ctx.fileModule.get(rel);
  for (const m of ctx.modules) {
    if (spec === m.module || spec.startsWith(m.module + '/')) {
      if (!best || m.module.length > best.module.length) best = m;
    }
  }
  if (own && (spec === own.module || spec.startsWith(own.module + '/'))) best = own;
  if (!best) return { external: true, spec }; // stdlib or third-party
  let sub = spec.slice(best.module.length).replace(/^\//, '');
  const targetDir = sub
    ? (best.moduleDir ? best.moduleDir + '/' + sub : sub)
    : (best.moduleDir || '.');
  const target = ctx.goDirs.get(targetDir);
  if (target && target !== rel) return { external: false, resolved: target, spec, target: targetDir };
  if (target === rel) return { external: false, resolved: target, spec, target: targetDir }; // own package (skipped upstream)
  return { external: false, resolved: null, spec, target: targetDir }; // first-party, no such package
}

export function extractGoImports(clean) {
  // Structure (`import`, `(`, `)`) is read from the cleaned line so a string or
  // comment can't fake it; the quoted path itself lives in a string literal
  // (blanked by the cleaner), so it's pulled from the RAW line at that index.
  const { rawLines, cleanedLines } = lineViews(clean);
  const specs = [];
  let inBlock = false;
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (!inBlock) {
      if (/^\s*import\s*\(/.test(code)) { inBlock = true; continue; }
      if (/^\s*import\s+(?:[\w.]+\s+|\.\s+)?"\s*"/.test(code)) {
        const m = rawLines[i].match(/^\s*import\s+(?:[\w.]+\s+|\.\s+)?"([^"]+)"/);
        if (m) specs.push({ spec: m[1], line: i + 1 });
      }
    } else {
      if (/^\s*\)/.test(code)) { inBlock = false; continue; }
      if (/"\s*"/.test(code)) { // a blanked string literal sits on this line
        const m = rawLines[i].match(/(?:[\w.]+\s+|\.\s+)?"([^"]+)"/);
        if (m) specs.push({ spec: m[1], line: i + 1 });
      }
    }
  }
  return specs;
}

export function analyzeGo(rel, content, lang, fileSet, ctx) {
  const clean = cleanSource(content, 'go');
  const m = baseMetrics(clean, 'go');
  m.functions = braceFunctions(clean.cleaned, GO_FN_RE, 'go');

  const imports = extractGoImports(clean).map((f) => ({ ...f, ...resolveGoImport(rel, f.spec, ctx) }));

  const { rawLines, cleanedLines } = lineViews(clean);
  const signals = { debugLogs: [], emptyCatches: [], evals: [], panics: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/\bfmt\.Print(ln|f)?\s*\(/.test(code) || /\bprintln\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (/\bpanic\s*\(/.test(code)) signals.panics.push(i + 1);
    // Checked-then-swallowed error: `if err != nil { }` (empty body, same line or next).
    if (/\bif\s+[\w.]*[eE]rr\w*\s*!=\s*nil\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
    else if (/\bif\s+[\w.]*[eE]rr\w*\s*!=\s*nil\s*\{\s*$/.test(code)) {
      const next = (cleanedLines[i + 1] ?? '').trim();
      if (next === '}') signals.emptyCatches.push(i + 1);
    }
  }

  // Docs: exported (capitalized) top-level symbols with a preceding `//` comment.
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    const decl = code.match(/^func\s+(?:\([^)]*\)\s+)?([A-Z]\w*)/) || code.match(/^(?:type|var|const)\s+([A-Z]\w*)\b/);
    if (!decl) continue;
    publicSymbols++;
    const prev = (rawLines[i - 1] ?? '').trim();
    if (prev.startsWith('//')) documented++;
  }
  m.docs = { publicSymbols, documented };

  return { metrics: m, imports, signals, decls: [] };
}
