// C / C++: the include graph from `#include "…"` (quoted = first-party) resolved
// against the on-disk layout, plus the safety signals a C reviewer actually looks
// for — unbounded libc buffer writes and swallowed C++ exceptions.
//
// Honesty rule (§5.1): a quoted `#include "foo.h"` conventionally resolves
// relative to the including file, but C compilers also fall back to `-I` include
// search paths we cannot see from source. So a quoted include that resolves
// on-disk (file-relative or repo-root-relative) becomes a real edge; one that
// does NOT is DROPPED, never minted as a broken/crimson wire — we won't fabricate
// a break that might just be an `-I` header. Angle-bracket `#include <…>` is
// always external (a system/library header), never an edge.
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

// A function definition line: a return type, a name, a parenthesized parameter
// list, then the end of the line (optionally an opening brace). No `;` (that is a
// prototype) and no `=`/`{` inside the params (that is a call or initializer).
// braceFunctions still requires a real `{…}` body before it counts the match, so
// prototypes and stray calls that slip past the regex are dropped downstream.
const C_FN_RE = /^[A-Za-z_][\w\s*&:<>,~]*?\b([A-Za-z_]\w*)\s*\([^;{}=]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{?\s*$/;

// libc calls that write without a bounds argument — the classic overflow set.
const UNSAFE_RE = /\b(gets|strcpy|strcat|sprintf|vsprintf)\s*\(/g;

// Collapse `.`/`..` in a POSIX path. Leaves leading `..` in place (escapes root).
function normalizePosix(p) {
  const parts = [];
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (parts.length && parts[parts.length - 1] !== '..') parts.pop(); else parts.push('..'); }
    else parts.push(seg);
  }
  return parts.join('/');
}

function posixDir(rel) {
  return rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
}

// Resolve a quoted include target to a real repo file, or null if none exists.
// Tries file-relative first (the C convention), then repo-root-relative (common
// with `-Iinclude` project layouts). Never returns the importer itself.
export function resolveInclude(rel, target, fileSet) {
  const dir = posixDir(rel);
  const candidates = [normalizePosix(dir ? dir + '/' + target : target), normalizePosix(target)];
  for (const c of candidates) {
    if (c && c !== rel && fileSet.has(c)) return c;
  }
  return null;
}

// Extract `#include` directives. The directive is detected on the CLEANED line
// (so an include commented out with /* … */ is already blanked and ignored), but
// the target is read from the RAW line because cleanSource blanks string interiors
// — the `"foo.h"` payload only survives in raw text.
export function extractIncludes(rel, clean, fileSet) {
  const { rawLines, cleanedLines } = lineViews(clean);
  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    if (!/^\s*#\s*include\b/.test(cleanedLines[i])) continue;
    const m = rawLines[i].match(/#\s*include\s*(?:"([^"]+)"|<([^>]+)>)/);
    if (!m) continue;
    if (m[2] != null) { imports.push({ line: i + 1, external: true, spec: m[2] }); continue; }
    const target = m[1];
    const resolved = resolveInclude(rel, target, fileSet);
    // Resolved → real edge. Unresolved quoted include → dropped (may be an -I
    // header); we never fabricate a broken wire for it.
    if (resolved) imports.push({ line: i + 1, external: false, resolved, spec: target });
  }
  return imports;
}

export function analyzeC(rel, content, lang, fileSet) {
  const clean = cleanSource(content, lang);
  const m = baseMetrics(clean, lang);
  m.functions = braceFunctions(clean.cleaned, C_FN_RE, lang);

  const imports = extractIncludes(rel, clean, fileSet);

  const { cleanedLines } = lineViews(clean);
  const signals = { unsafeCalls: [], emptyCatches: [], debugLogs: [], evals: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    UNSAFE_RE.lastIndex = 0;
    let u;
    while ((u = UNSAFE_RE.exec(code))) signals.unsafeCalls.push({ line: i + 1, fn: u[1] });
    if (lang === 'cpp' && /\bcatch\s*\([^)]*\)\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
  }

  return { metrics: m, imports, signals, decls: [] };
}
