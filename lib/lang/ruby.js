// Ruby: `require_relative` resolved against the on-disk layout is the wiring
// signal. `require_relative './util'` maps file-relative to `util.rb`; a target
// that doesn't exist is a genuine broken wire (LoadError at runtime) → crimson
// node. Plain `require 'json'` is a stdlib/gem load — external, never resolved.
// Ruby has no braces for blocks, so nesting and method extraction walk the
// def/do…end block structure instead of counting `{ }`.
import { baseMetrics } from './common.js';
import { cleanSource, lineViews } from './clean.js';

// Statement-position block openers. A trailing modifier (`return x if y`) does
// NOT start with the keyword, so anchoring to line start excludes it.
const BLOCK_OPEN_RE = /^\s*(?:def|class|module|if|unless|while|until|for|case|begin)\b/;
const DO_OPEN_RE = /\bdo(\s*\|[^|]*\|)?\s*$/;      // trailing `do` / `do |args|`
const END_RE = /^\s*end\b/;
const DEF_RE = /^\s*def\s+(?:self\.)?([A-Za-z_]\w*[!?=]?)/;

// Does a line net-open a block? (def/class/if/... or a trailing `do`.) One-line
// forms like `def foo; end` net to zero and are handled by the caller.
function opensBlock(line) {
  return BLOCK_OPEN_RE.test(line) || DO_OPEN_RE.test(line);
}

// Single pass over cleaned lines: block-depth nesting + def…end functions.
function rubyStructure(cleanedLines) {
  let depth = 0, maxNesting = 0, maxNestingLine = 1;
  const functions = [];
  const open = []; // stack of { name, line, depthBefore } for active defs
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    const closes = END_RE.test(line);
    const def = line.match(DEF_RE);
    const oneLiner = def && /;\s*end\b/.test(line); // `def foo; ...; end`

    if (oneLiner) { functions.push({ name: def[1], line: i + 1, length: 1 }); continue; }
    if (closes) {
      depth = Math.max(0, depth - 1);
      const top = open[open.length - 1];
      if (top && depth === top.depthBefore) { open.pop(); functions.push({ name: top.name, line: top.line, length: i - top.line + 1 }); }
      continue;
    }
    if (opensBlock(line)) {
      if (def) open.push({ name: def[1], line: i + 1, depthBefore: depth });
      depth++;
      if (depth > maxNesting) { maxNesting = depth; maxNestingLine = i + 1; }
    }
  }
  // Unterminated defs (truncated / unparsed): close them at EOF so they still count.
  for (const t of open) functions.push({ name: t.name, line: t.line, length: cleanedLines.length - t.line + 1 });
  return { maxNesting, maxNestingLine, functions };
}

function posixDir(rel) { return rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : ''; }

// Resolve a `require_relative` spec against the requiring file's directory.
// Returns the matched repo-relative path, or null (broken — no such file).
export function resolveRequireRelative(rel, spec, fileSet) {
  const dir = posixDir(rel);
  let p = spec.replace(/^\.\//, '');
  const joined = dir ? dir + '/' + p : p;
  const parts = [];
  for (const seg of joined.split('/')) {
    if (seg === '..') parts.pop();
    else if (seg !== '.' && seg !== '') parts.push(seg);
  }
  const base = parts.join('/');
  const candidates = base.endsWith('.rb') ? [base] : [base + '.rb', base];
  for (const c of candidates) if (fileSet.has(c) && c !== rel) return c;
  return null;
}

export function analyzeRuby(rel, content, lang, fileSet) {
  const clean = cleanSource(content, 'ruby');
  const m = baseMetrics(clean, 'ruby');
  const { rawLines, cleanedLines } = lineViews(clean);

  // Override brace-based metrics with Ruby's block structure.
  const struct = rubyStructure(cleanedLines);
  m.maxNesting = struct.maxNesting;
  m.maxNestingLine = struct.maxNestingLine;
  m.functions = struct.functions;

  const imports = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    // The path is a string literal (blanked by the cleaner) — read it from raw.
    const rr = code.match(/^\s*require_relative\s+['"]/);
    if (rr) {
      const raw = rawLines[i].match(/require_relative\s+['"]([^'"]+)['"]/);
      if (raw) {
        const resolved = resolveRequireRelative(rel, raw[1], fileSet);
        imports.push({ spec: `require_relative '${raw[1]}'`, line: i + 1, external: false, resolved, target: raw[1] });
      }
      continue;
    }
    // Plain require / require gem → external (stdlib or a gem on $LOAD_PATH).
    if (/^\s*require\s+['"]/.test(code)) {
      const raw = rawLines[i].match(/require\s+['"]([^'"]+)['"]/);
      if (raw) imports.push({ spec: raw[1], line: i + 1, external: true });
    }
  }

  const signals = { debugLogs: [], emptyCatches: [], evals: [], panics: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/^\s*(?:puts|pp|print)\b/.test(code) || /\bSTDOUT\.(puts|print)\b/.test(code)) signals.debugLogs.push(i + 1);
    if (/\b(?:instance_|class_|module_)?eval\s*[( ]/.test(code)) signals.evals.push(i + 1);
    // Swallowed rescue: `rescue` with an empty body (next is end/ensure/another
    // rescue), or the inline `x rescue nil` form that drops the error.
    if (/^\s*rescue\b/.test(code)) {
      const next = (cleanedLines[i + 1] ?? '').trim();
      if (next === 'end' || next === 'ensure' || /^rescue\b/.test(next)) signals.emptyCatches.push(i + 1);
    }
    if (/\brescue\s+nil\b/.test(code)) signals.emptyCatches.push(i + 1);
  }

  // Ruby has no enforced public-symbol doc convention — leave symbol-level docs
  // out (comment-coverage still applies via baseMetrics) rather than fabricate a
  // signal we can't measure honestly.
  m.docs = { publicSymbols: 0, documented: 0 };

  return { metrics: m, imports, signals, decls: [] };
}
