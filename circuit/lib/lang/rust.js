// Rust: module graph from `mod` declarations + `use` paths, resolved against
// the on-disk module layout. A `mod foo;` with no foo.rs / foo/mod.rs is a
// genuine broken wire (it won't compile) — that's our crimson-node signal.
// `use crate::a::b`, `use super::x`, `use self::x` resolve to the deepest
// existing module file (longest-prefix, like Python) so re-exports don't mint
// false breaks; `use some_crate::...` is external.
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

const RUST_FN_RE = /\bfn\s+(\w+)/;

function posixDir(rel) {
  return rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
}

// The crate root src dir for a file: nearest ancestor `src` segment, else the
// file's own dir. `crate::` paths resolve relative to it.
function crateRoot(rel) {
  const parts = rel.split('/');
  const idx = parts.lastIndexOf('src');
  if (idx >= 0) return parts.slice(0, idx + 1).join('/');
  return posixDir(rel);
}

// Try foo.rs and foo/mod.rs under a base dir.
function moduleFile(baseDir, name, fileSet) {
  const p = baseDir ? baseDir + '/' + name : name;
  if (fileSet.has(p + '.rs')) return p + '.rs';
  if (fileSet.has(p + '/mod.rs')) return p + '/mod.rs';
  return null;
}

// `mod name;` — child module of the current file. For a mod-defining file the
// children live beside it (foo.rs → foo/) or in its own dir (mod.rs/lib.rs/main.rs).
export function resolveRustMod(rel, name, fileSet) {
  const dir = posixDir(rel);
  const base = rel.slice(rel.lastIndexOf('/') + 1);
  const bases = [];
  if (/^(mod|lib|main)\.rs$/.test(base)) bases.push(dir);
  else bases.push(dir ? dir + '/' + base.replace(/\.rs$/, '') : base.replace(/\.rs$/, ''));
  for (const b of bases) {
    const hit = moduleFile(b, name, fileSet);
    if (hit && hit !== rel) return { external: false, resolved: hit, spec: `mod ${name}`, target: name };
  }
  return { external: false, resolved: null, spec: `mod ${name}`, target: name };
}

// A `use` path. Only crate/self/super paths are first-party; everything else is
// an external crate. The LAST segment is the imported item (a type/fn/trait),
// not a module — so we resolve the module prefix that precedes it. To stay
// honest (§5.1) a `use` NEVER mints a broken wire: broken-module detection is
// `mod`'s job (compile-accurate). An unresolvable `use` returns resolved:null
// and the caller drops it rather than fabricating a crimson node.
export function resolveRustUse(rel, segs, fileSet) {
  const head = segs[0];
  const dir = posixDir(rel);
  const spec = segs.join('::');
  let baseDir, rootFile;
  if (head === 'crate') {
    baseDir = crateRoot(rel);
    rootFile = ['lib.rs', 'main.rs', 'mod.rs']
      .map((f) => (baseDir ? baseDir + '/' + f : f)).find((f) => fileSet.has(f)) ?? null;
  } else if (head === 'self') {
    baseDir = dir; rootFile = rel;
  } else if (head === 'super') {
    baseDir = dir.includes('/') ? dir.slice(0, dir.lastIndexOf('/')) : '';
    rootFile = [baseDir ? baseDir + '/mod.rs' : 'mod.rs', baseDir ? baseDir + '.rs' : null]
      .filter(Boolean).find((f) => fileSet.has(f)) ?? null;
  } else {
    return { external: true, spec };
  }
  const items = segs.slice(1).filter((s) => s && s !== '*' && s !== 'as' && !/[{}]/.test(s));
  // Longest module prefix (items minus the final item symbol): crate::a::b::Item → a/b, then a.
  for (let k = items.length - 1; k >= 1; k--) {
    let cur = baseDir, ok = true, hit = null;
    for (let j = 0; j < k; j++) {
      hit = moduleFile(cur, items[j], fileSet);
      if (!hit) { ok = false; break; }
      cur = hit.replace(/\/mod\.rs$/, '').replace(/\.rs$/, '');
    }
    if (ok && hit) return { external: false, resolved: hit === rel ? null : hit, spec };
  }
  // No sub-module in the path (`use crate::Item`, `use crate::*`) → the item is
  // re-exported at the base module root. Best-effort edge; never broken.
  if (items.length <= 1) return { external: false, resolved: rootFile && rootFile !== rel ? rootFile : null, spec };
  // A module path was present but its first segment isn't a module here — could
  // be a re-export we can't see. Drop it (resolved:null) rather than fabricate.
  return { external: false, resolved: null, spec };
}

export function extractRustImports(rel, clean, fileSet) {
  const { cleanedLines } = lineViews(clean);
  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    let m;
    if ((m = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;/))) {
      // `mod` is the compile-accurate broken-wire signal: keep resolved:null (crimson).
      imports.push({ line: i + 1, ...resolveRustMod(rel, m[1], fileSet) });
    } else if ((m = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?use\s+([^;]+);/))) {
      // Take the path up to the first `{` group or `as`; split on `::`.
      let pathPart = m[1].trim().replace(/\s+as\s+\w+$/, '');
      const brace = pathPart.indexOf('{');
      if (brace >= 0) pathPart = pathPart.slice(0, brace).replace(/::\s*$/, '');
      const segs = pathPart.split('::').map((s) => s.trim()).filter(Boolean);
      if (!segs.length) continue;
      const r = resolveRustUse(rel, segs, fileSet);
      if (r.external) imports.push({ line: i + 1, external: true, spec: r.spec });
      else if (r.resolved) imports.push({ line: i + 1, external: false, resolved: r.resolved, spec: r.spec });
      // else: unresolvable `use` — dropped, never a fabricated broken wire.
    }
  }
  return imports;
}

export function analyzeRust(rel, content, lang, fileSet) {
  const clean = cleanSource(content, 'rust');
  const m = baseMetrics(clean, 'rust');
  m.functions = braceFunctions(clean.cleaned, RUST_FN_RE, 'rust');

  const imports = extractRustImports(rel, clean, fileSet);

  const { rawLines, cleanedLines } = lineViews(clean);
  const signals = { debugLogs: [], emptyCatches: [], evals: [], panics: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/\b(println|print|eprintln|eprint|dbg)\s*!/.test(code)) signals.debugLogs.push(i + 1);
    if (/\.unwrap\s*\(\s*\)/.test(code) || /\.expect\s*\(/.test(code) ||
        /\bpanic\s*!/.test(code) || /\b(unimplemented|todo|unreachable)\s*!/.test(code)) {
      signals.panics.push(i + 1);
    }
  }

  // Docs: `pub` items preceded by a `///`, `//!` or `/** */` doc comment
  // (skipping `#[...]` attribute lines that sit between the doc and the item).
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    if (!/^\s*pub(?:\([^)]*\))?\s+(?:async\s+|unsafe\s+|extern\s+(?:"[^"]*"\s+)?)*(fn|struct|enum|trait|const|static|mod|type)\s+\w+/.test(cleanedLines[i])) continue;
    publicSymbols++;
    for (let j = i - 1; j >= Math.max(0, i - 4); j--) {
      const t = (rawLines[j] ?? '').trim();
      if (!t || t.startsWith('#[') || t.startsWith('#!')) continue;
      if (t.startsWith('///') || t.startsWith('//!') || t.startsWith('*/') || t.startsWith('/**')) documented++;
      break;
    }
  }
  m.docs = { publicSymbols, documented };

  return { metrics: m, imports, signals, decls: [] };
}
