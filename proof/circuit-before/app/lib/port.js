// Windows port check: which files run on Windows unchanged, which already skip
// or replace their Mac-only parts, and which need a Windows counterpart built —
// with what that counterpart is (lib/port-map.js).
//
// Deterministic: framework imports, macOS-only command-line tools and hard-coded
// macOS paths, matched against a fixed table. No model and no network — the same
// air-gap posture as the grader (AIRGAP.md).
//
// Per file:
//   ready          nothing Mac-only (portable), or Mac-only parts with a Windows branch (handled)
//   guarded        Mac-only parts behind a platform check with no Windows branch:
//                  it builds on Windows, but those features are simply absent there
//   needs-windows  at least one Mac-only part with no guard: it will not build or
//                  run on Windows until the listed counterpart exists
import fs from 'node:fs';
import path from 'node:path';
import { discoverFiles } from './walk.js';
import { cleanSource, lineViews, inSpan, lineOfOffset } from './lang/clean.js';
import { APPLE_MODULES, PYTHON_MODULES, JS_MODULES, MAC_COMMANDS, MAC_PATHS } from './port-map.js';

export const PORT_TARGETS = ['windows'];

const CODE_LANGS = new Set(['swift', 'objc', 'c', 'cpp', 'python', 'javascript', 'typescript', 'shell', 'go', 'rust', 'java', 'kotlin', 'ruby']);
const TEST_RE = /(^|\/)(tests?|Tests|UITests|__tests__|spec|specs)(\/|$)|[._-](test|spec)s?\.[a-z]+$|Tests?\.swift$|(^|\/)test_[^/]+\.py$/;
const TOOLING_RE = /(^|\/)(scripts?|tools?|bin|ci|\.github|packaging|release|fastlane)(\/|$)|(^|\/)(Package|Makefile|Dangerfile)\.swift$|(^|\/)(build|deploy|release|notarize|sign|package)[^/]*\.(sh|zsh|bash|command|py|mjs|js)$/;

export function fileRole(rel, lang) {
  if (TEST_RE.test(rel)) return 'test';
  if (lang === 'shell' || TOOLING_RE.test(rel)) return 'tooling';
  return 'app';
}

// ---------- compile-time guards (Swift, Objective-C, C/C++) ----------
const WINDOWS_COND = /\bos\(Windows\)|\b_WIN(32|64)\b|canImport\((WinSDK|ucrt|WinUI)\)/;
const OTHER_OS_COND = /\bos\((macOS|OSX|iOS|tvOS|watchOS|visionOS|Linux|Android|FreeBSD|OpenBSD|WASI)\)|\b(TARGET_OS_(OSX|MAC|IPHONE|IOS)|__APPLE__|__MACH__)\b/;

function excludesWindows(cond) {
  if (/!\s*os\(Windows\)/.test(cond) || /!\s*defined\s*\(?\s*_WIN(32|64)/.test(cond)) return true;
  if (WINDOWS_COND.test(cond)) return false;
  if (OTHER_OS_COND.test(cond)) return true;
  for (const m of cond.matchAll(/canImport\((\w+)\)/g)) {
    const entry = APPLE_MODULES[m[1]];
    if ((entry && entry.kind !== 'portable') || /Kit$/.test(m[1])) return true;
  }
  return false;
}

// Returns, per line, whether that line is compiled out on Windows. `alt` is set on
// the array when an Apple-only `#if` carries an `#else` that Windows compiles — the
// shape a converted drop-in import has (`#if canImport(Combine) … #else import
// OpenCombine`): the Mac-only part is handled, not just skipped.
function preprocessorGuards(lines) {
  const guarded = new Array(lines.length).fill(false);
  guarded.alt = false;
  const stack = []; // { guarded, sawWindows }
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    let m;
    if ((m = t.match(/^#\s*if(n?def)?\b\s*(.*)$/))) {
      const cond = m[1] === 'ndef' ? `!defined(${m[2]})` : m[2];
      stack.push({ guarded: excludesWindows(cond), sawWindows: WINDOWS_COND.test(cond) && !/!\s*os\(Windows\)/.test(cond) });
    } else if (/^#\s*(elif|elseif)\b/.test(t) && stack.length) {
      const cond = t.replace(/^#\s*(elif|elseif)\b/, '');
      const top = stack[stack.length - 1];
      top.guarded = excludesWindows(cond);
      if (WINDOWS_COND.test(cond)) top.sawWindows = true;
    } else if (/^#\s*else\b/.test(t) && stack.length) {
      const top = stack[stack.length - 1];
      if (top.guarded && !top.sawWindows && hasCode(lines, i + 1)) guarded.alt = true;
      top.guarded = top.sawWindows;
    } else if (/^#\s*endif\b/.test(t)) {
      stack.pop();
    }
    guarded[i] = stack.some((f) => f.guarded);
  }
  return guarded;
}

// Is there a real line of code between `from` and the matching #endif / #elif?
function hasCode(lines, from) {
  let depth = 0;
  for (let i = from; i < lines.length; i++) {
    const t = lines[i].trim();
    if (/^#\s*if/.test(t)) depth++;
    else if (/^#\s*endif\b/.test(t)) { if (depth === 0) return false; depth--; }
    else if (depth === 0 && /^#\s*(else|elif|elseif)\b/.test(t)) return false;
    else if (t) return true;
  }
  return false;
}

// ---------- runtime guards (Python / JS / shell): platform checks ----------
const DARWIN_CHECK = /sys\.platform\s*(==|!=|\.startswith\()\s*\(?\s*["']darwin|platform\.system\(\)\s*==\s*["']Darwin|process\.platform\s*===?\s*["']darwin|os\.platform\(\)\s*===?\s*["']darwin|\bIS_MAC(OS)?\b|\bisMac(OS)?\b|OSTYPE.*darwin|uname.*Darwin/;
const WINDOWS_CHECK = /["']win32["']|platform\.system\(\)\s*==\s*["']Windows["']|os\.name\s*==\s*["']nt["']|\bIS_WINDOWS\b|\bisWindows\b|OSTYPE.*(msys|cygwin|win32)/;

function pythonGuards(rawLines) {
  const guarded = new Array(rawLines.length).fill(false);
  const stack = []; // { indent, guarded, sawWindows, negDarwin }
  const indentOf = (s) => s.match(/^\s*/)[0].replace(/\t/g, '    ').length;
  for (let i = 0; i < rawLines.length; i++) {
    const raw = rawLines[i];
    const t = raw.trim();
    if (!t || t.startsWith('#')) { guarded[i] = stack.some((f) => f.guarded); continue; }
    const ind = indentOf(raw);
    const isBranch = /^(elif\b|else\s*:|except\b|finally\s*:)/.test(t);
    while (stack.length && (ind < stack[stack.length - 1].indent || (ind === stack[stack.length - 1].indent && !isBranch))) stack.pop();
    const top = stack[stack.length - 1];
    if (top && ind === top.indent && isBranch) {
      if (/^elif\b/.test(t)) { top.guarded = DARWIN_CHECK.test(t) && !/!=/.test(t); if (WINDOWS_CHECK.test(t)) top.sawWindows = true; }
      else if (/^else\s*:/.test(t)) top.guarded = top.sawWindows || top.negDarwin;
      else top.guarded = false; // except/finally bodies run everywhere
      guarded[i] = stack.slice(0, -1).some((f) => f.guarded);
      continue;
    }
    guarded[i] = stack.some((f) => f.guarded);
    const inline = t.match(/^if\b(.*?):\s*(\S.*)$/); // `if darwin: import AppKit`
    if (/^if\b.*:\s*$/.test(t)) {
      const darwin = DARWIN_CHECK.test(t);
      stack.push({ indent: ind, guarded: darwin && !/!=/.test(t), sawWindows: WINDOWS_CHECK.test(t), negDarwin: darwin && /!=/.test(t) });
    } else if (inline && DARWIN_CHECK.test(inline[1]) && !/!=/.test(inline[1])) {
      guarded[i] = true;
    } else if (/^try\s*:\s*$/.test(t)) {
      stack.push({ indent: ind, guarded: true, sawWindows: false, negDarwin: false }); // optional import: degrades if missing
    } else if (/:\s*$/.test(t)) {
      stack.push({ indent: ind, guarded: false, sawWindows: false, negDarwin: false });
    }
  }
  return guarded;
}

// JS / shell / other: a hit is guarded when one of the six lines above it
// (or the line itself) is a macOS platform check.
function proximityGuards(rawLines) {
  const guarded = new Array(rawLines.length).fill(false);
  let lastCheck = -100;
  for (let i = 0; i < rawLines.length; i++) {
    if (DARWIN_CHECK.test(rawLines[i])) lastCheck = i;
    guarded[i] = i - lastCheck <= 6;
  }
  return guarded;
}

// ---------- per-language import extraction ----------
function importsOf(lang, cleanedLines, rawLines, spans, lineOffsets) {
  const out = []; // { module, line }
  if (lang === 'swift') {
    cleanedLines.forEach((l, i) => {
      const m = l.match(/^\s*(?:@[\w()]+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/);
      if (m) out.push({ module: m[1], line: i + 1 });
    });
  } else if (lang === 'objc' || lang === 'c' || lang === 'cpp') {
    cleanedLines.forEach((l, i) => {
      const m = l.match(/^\s*#\s*(?:import|include)\s*<(\w+)\//) || l.match(/^\s*@import\s+(\w+)/);
      if (m) out.push({ module: m[1], line: i + 1 });
    });
  } else if (lang === 'python') {
    cleanedLines.forEach((l, i) => {
      let m = l.match(/^\s*from\s+([\w.]+)\s+import\b/);
      if (m) { out.push({ module: m[1].split('.')[0], line: i + 1 }); return; }
      m = l.match(/^\s*import\s+(.+)$/);
      if (m) for (const part of m[1].split(',')) {
        const name = part.trim().split(/\s+/)[0].split('.')[0];
        if (/^\w+$/.test(name)) out.push({ module: name, line: i + 1 });
      }
    });
  } else if (lang === 'javascript' || lang === 'typescript') {
    const re = /(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*|^\s*import\s+)(["'`])([^"'`]+)\1/gm;
    const raw = rawLines.join('\n');
    for (const m of raw.matchAll(re)) {
      const offset = m.index + m[0].lastIndexOf(m[2]);
      if (inSpan(spans, offset, 'comment')) continue;
      const spec = m[2];
      const pkg = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
      out.push({ module: pkg, line: lineOfOffset(lineOffsets, offset) });
    }
  }
  return out;
}

function moduleTable(lang) {
  if (lang === 'swift' || lang === 'objc' || lang === 'c' || lang === 'cpp') return APPLE_MODULES;
  if (lang === 'python') return PYTHON_MODULES;
  if (lang === 'javascript' || lang === 'typescript') return JS_MODULES;
  return null;
}

// Module names the repo defines itself (SwiftPM targets, Sources/<Name>/ dirs) —
// imports of those are internal, not third-party.
export function internalModules(root, files) {
  const names = new Set();
  for (const f of files) {
    const parts = f.rel.split('/');
    const idx = parts.indexOf('Sources');
    if (idx >= 0 && parts.length > idx + 2) names.add(parts[idx + 1]);
    if (parts[parts.length - 1] === 'Package.swift') {
      try {
        const src = fs.readFileSync(f.abs, 'utf8');
        for (const m of src.matchAll(/\.(?:target|executableTarget|testTarget|macro|plugin|systemLibrary|binaryTarget)\s*\(\s*name:\s*"([^"]+)"/g)) names.add(m[1]);
      } catch { /* unreadable manifest: just no names from it */ }
    }
  }
  return names;
}

export function scanFile(rel, lang, content, internal) {
  const clean = cleanSource(content, lang);
  const { rawLines, cleanedLines } = lineViews(clean);
  const guards = (lang === 'swift' || lang === 'objc' || lang === 'c' || lang === 'cpp')
    ? preprocessorGuards(cleanedLines)
    : lang === 'python' ? pythonGuards(rawLines) : proximityGuards(rawLines);
  const hasWindowsBranch = guards.alt === true || rawLines.some((l) => WINDOWS_COND.test(l) || WINDOWS_CHECK.test(l));

  const hits = [];
  const unknown = new Set();
  const table = moduleTable(lang);
  if (table) {
    for (const imp of importsOf(lang, cleanedLines, rawLines, clean.spans, clean.lineOffsets)) {
      const entry = table[imp.module];
      if (!entry) {
        if (lang === 'swift' && !internal.has(imp.module)) unknown.add(imp.module);
        continue;
      }
      if (entry.kind === 'portable') continue;
      hits.push({ kind: entry.kind, id: imp.module, line: imp.line, windows: entry.windows, effort: entry.effort, guarded: guards[imp.line - 1] });
    }
  }

  // macOS-only command-line tools and paths: inside strings (or anywhere outside
  // comments, for shell scripts, where commands are code).
  const probes = [...MAC_COMMANDS.map((c) => ({ ...c, kind: 'command' })), ...MAC_PATHS.map((p) => ({ ...p, kind: 'path' }))];
  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    for (const p of probes) {
      const m = p.re.exec(line);
      if (!m) continue;
      const offset = clean.lineOffsets[i] + m.index + Math.max(0, m[0].search(/[^"'`\s]/));
      if (inSpan(clean.spans, offset, 'comment')) continue;
      if (lang !== 'shell' && !inSpan(clean.spans, offset, 'string')) continue;
      if (hits.some((h) => h.id === p.id && h.line === i + 1)) continue;
      hits.push({ kind: p.kind, id: p.id, line: i + 1, windows: p.windows, effort: p.effort, guarded: guards[i] });
    }
  }

  let status = 'ready';
  if (hits.some((h) => !h.guarded)) status = 'needs-windows';
  else if (hits.length) status = hasWindowsBranch ? 'ready' : 'guarded';
  return { status, handled: hits.length > 0 && status === 'ready', hits, unknown: [...unknown] };
}

function emptyBucket() {
  return { files: 0, loc: 0, ready: { files: 0, loc: 0 }, guarded: { files: 0, loc: 0 }, needsWindows: { files: 0, loc: 0 }, readyPct: null };
}

function locOf(content) {
  let n = 0;
  for (const l of content.split('\n')) if (l.trim()) n++;
  return n;
}

export function portCheck(root, { target = 'windows' } = {}) {
  if (!PORT_TARGETS.includes(target)) throw new Error(`Unsupported port target "${target}" (supported: ${PORT_TARGETS.join(', ')})`);
  const startedAt = Date.now();
  root = path.resolve(root);
  const { files, truncated } = discoverFiles(root);
  const internal = internalModules(root, files);

  const summary = { app: emptyBucket(), test: emptyBucket(), tooling: emptyBucket() };
  const blockers = new Map();   // id → { id, kind, windows, effort, files:Set, loc }
  const skipped = new Map();    // guarded Mac-only features with no Windows branch
  const unknownModules = new Map(); // module → file count
  const out = [];

  for (const f of files) {
    if (!CODE_LANGS.has(f.lang)) continue;
    let content;
    try { content = fs.readFileSync(f.abs, 'utf8'); } catch { continue; }
    if (content.includes('\0')) continue;
    content = content.replace(/\r\n?/g, '\n');
    const rel = f.rel.split(path.sep).join('/');
    const role = fileRole(rel, f.lang);
    const loc = locOf(content);
    let r;
    try { r = scanFile(rel, f.lang, content, internal); }
    catch (e) { r = { status: 'ready', handled: false, hits: [], unknown: [], error: String(e?.message ?? e) }; }

    const b = summary[role];
    b.files++; b.loc += loc;
    const bucket = r.status === 'needs-windows' ? b.needsWindows : r.status === 'guarded' ? b.guarded : b.ready;
    bucket.files++; bucket.loc += loc;

    if (role === 'app') {
      for (const h of r.hits) {
        const into = h.guarded ? (r.handled ? null : skipped) : blockers;
        if (!into) continue;
        const key = `${h.kind}:${h.id}`;
        if (!into.has(key)) into.set(key, { id: h.id, kind: h.kind, windows: h.windows, effort: h.effort, files: new Set(), loc: 0 });
        const agg = into.get(key);
        if (!agg.files.has(rel)) { agg.files.add(rel); agg.loc += loc; }
      }
      for (const u of r.unknown) unknownModules.set(u, (unknownModules.get(u) ?? 0) + 1);
    }
    out.push({ id: rel, lang: f.lang, role, loc, status: r.status, handled: r.handled, hits: r.hits.slice(0, 40), ...(r.error ? { error: r.error } : {}) });
  }

  for (const b of Object.values(summary)) {
    b.readyPct = b.loc > 0 ? Math.round((b.ready.loc / b.loc) * 1000) / 10 : null;
  }
  const effortRank = { L: 3, M: 2, S: 1 };
  const list = (m) => [...m.values()]
    .map((a) => ({ ...a, files: a.files.size }))
    .sort((x, y) => y.loc - x.loc || (effortRank[y.effort] ?? 0) - (effortRank[x.effort] ?? 0) || x.id.localeCompare(y.id));

  return {
    root,
    name: path.basename(root),
    target,
    generatedAt: Date.now(),
    tookMs: Date.now() - startedAt,
    truncated,
    summary,
    blockers: list(blockers),
    skipped: list(skipped),
    unknownModules: [...unknownModules.entries()].map(([id, files]) => ({ id, files })).sort((a, b) => b.files - a.files || a.id.localeCompare(b.id)),
    files: out,
  };
}

// Plain-text report for the CLI (`--port-check`).
export function formatPortReport(r) {
  const pct = (n, d) => (d > 0 ? `${(Math.round((n / d) * 1000) / 10).toFixed(1)}%` : '—');
  const lines = [];
  const a = r.summary.app;
  lines.push(`[circuit] Windows port check — ${r.name}`);
  if (a.files === 0) {
    lines.push('  No app source files found — nothing to check.');
  } else {
    lines.push(`  App code: ${a.loc.toLocaleString('en-US')} lines in ${a.files} files`);
    lines.push(`    runs on Windows as-is ............... ${pct(a.ready.loc, a.loc).padStart(6)}  (${a.ready.files} files)`);
    lines.push(`    builds, but Mac-only parts are skipped ${pct(a.guarded.loc, a.loc).padStart(6)}  (${a.guarded.files} files)`);
    lines.push(`    needs a Windows part first .......... ${pct(a.needsWindows.loc, a.loc).padStart(6)}  (${a.needsWindows.files} files)`);
  }
  for (const role of ['test', 'tooling']) {
    const b = r.summary[role];
    if (b.files) lines.push(`  ${role === 'test' ? 'Tests' : 'Tooling'}: ${b.files} files, ${pct(b.ready.loc, b.loc)} run on Windows as-is`);
  }
  if (r.blockers.length) {
    lines.push('  Windows parts needed (each built once, then reused by every app):');
    for (const x of r.blockers.slice(0, 25)) {
      lines.push(`    ${x.id.padEnd(22)} ${x.kind.padEnd(8)} ${String(x.files).padStart(4)} files  [${x.effort}]  → ${x.windows}`);
    }
    if (r.blockers.length > 25) lines.push(`    … and ${r.blockers.length - 25} more`);
  }
  if (r.skipped.length) {
    lines.push('  Mac-only features that are skipped on Windows (no Windows branch yet):');
    for (const x of r.skipped.slice(0, 12)) lines.push(`    ${x.id.padEnd(22)} ${String(x.files).padStart(4)} files  → ${x.windows}`);
  }
  if (r.unknownModules.length) {
    lines.push(`  Modules not in the port map (confirm they build on Windows): ${r.unknownModules.slice(0, 15).map((u) => u.id).join(', ')}${r.unknownModules.length > 15 ? ', …' : ''}`);
  }
  if (r.truncated) lines.push('  Note: the repo is larger than the scan limit — this is a partial view.');
  return lines.join('\n');
}
