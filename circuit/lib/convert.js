// Convert: rewrite a macOS codebase so it builds for Windows, and prove it.
//
// What "converted" means here is decided by a compiler, not by this file:
//   1. Deterministic rewrites (lib/convert-rules.js): Apple-only imports become a
//      per-platform import of the same-API package or a CircuitPortKit part, Foundation
//      networking gets its non-Apple import, hard-coded macOS paths and commands in
//      Python / JS become portable helper calls. No model, no network.
//   2. The result is written to a separate output folder as a buildable Swift package
//      (the source repo is never touched).
//   3. --verify builds that package in the Windows configuration. Every file the
//      compiler rejects is isolated to Apple platforms (kept byte-for-byte for the Mac
//      build, compiled out elsewhere) and recorded with its exact errors; the build
//      repeats until what remains compiles. Only files that survive count as converted.
//
// On a Mac the Windows configuration is simulated (-D CIRCUIT_WINDOWS_SIM hides every
// Apple-only module); the generated CI workflow runs the same build on a real Windows
// runner, which is the final word.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { portCheck, scanFile, fileRole, internalModules } from './port.js';
import { discoverFiles } from './walk.js';
import { cleanSource, lineViews, inSpan } from './lang/clean.js';
import { APPLE_MODULES } from './port-map.js';
import {
  SIM_FLAG, SWIFT_PACKAGES, SWIFT_IMPORT_RULES, NETWORKING_SYMBOLS, NETWORKING_BLOCK, KEYCHAIN_SYMBOLS, COMBINE_SYMBOLS,
  swiftImportBlock, swiftGuardedImport, ISOLATE_OPEN, ISOLATE_CLOSE,
  PYTHON_RULES, PY_FCNTL_IMPORT, PY_FCNTL_OTHER_USE, JS_RULES,
} from './convert-rules.js';

const KIT_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'convert-kit');
export const CONVERT_TARGETS = ['windows'];

// Directories that hold another target (iOS app, widget, watch app, marketing
// renders, command-line twins) rather than the desktop app being converted.
const SECONDARY_DIR = /(^|\/)(ios|iOS|[^/]*iOS[^/]*|widget|widgets|[^/]*Widget[^/]*|watch|[^/]*Watch[^/]*|[^/]*Remote|marketing|appstore[^/]*|screenshots?|Playgrounds?|Examples?|Demo|archive|vendor)(\/|$)/;

const IMPORT_RE = /^(\s*)((?:@\w+(?:\([^)]*\))?\s+)*)import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/;

// ---------------------------------------------------------------- Swift rewrite
export function convertSwiftSource(content) {
  const clean = cleanSource(content, 'swift');
  const { rawLines, cleanedLines } = lineViews(clean);
  const changes = [];
  const products = new Map(); // product → package
  const guardedModules = [];
  const kitModules = [];      // Apple modules this file now gets from CircuitPortKit
  let needsKit = false;
  let combineSwapped = false;
  let hasFoundation = false;
  let hasNetworkingImport = false;
  let hasCombineImport = false;
  let uiSwapped = false;          // SwiftUI → SwiftCrossUI (the kit bridges SwiftUI's names)
  let hasKitImport = false;       // the kit is imported somewhere off Apple platforms
  let hasPlainKitImport = false;  // … and on every platform (the Combine bridge needs that)
  let foundationLine = -1;
  let firstImportLine = -1;
  let depth = 0;
  const out = [];
  // An author's `#if canImport(M)` region with no #else, for a module Convert has a replacement
  // for, is opened to it (`canImport(M) || canImport(R)`) and `import M` inside gets the
  // per-platform import. Left closed, Windows never compiles that code at all. A region with an
  // #else is left as written: the author already wrote the path for platforms without M.
  const regions = conditionalRegions(cleanedLines);
  const opened = []; // { end, modules }
  const useRule = (module, rule, line) => {
    if (rule.kit) needsKit = true;
    if (rule.type === 'kit') { hasKitImport = true; if (!kitModules.includes(module)) kitModules.push(module); }
    for (const [product, pkg] of rule.products ?? []) products.set(product, pkg);
    if (module === 'Combine') { combineSwapped = true; hasCombineImport = true; }
    if (module === 'SwiftUI') uiSwapped = true;
    changes.push({ line, kind: rule.type, module, to: rule.note });
  };

  for (let i = 0; i < rawLines.length; i++) {
    const c = cleanedLines[i].trim();
    while (opened.length && i > opened[opened.length - 1].end) opened.pop();
    if (/^#\s*if\b/.test(c)) {
      depth++;
      const region = regions.get(i);
      const open = region && !region.hasElse ? openCondition(rawLines[i]) : null;
      if (open) {
        out.push(open.line);
        opened.push({ end: region.end, modules: open.modules });
        for (const module of open.modules) useRule(module, SWIFT_IMPORT_RULES[module], i + 1);
        changes.push({ line: i + 1, kind: 'opened-conditional', module: [...open.modules].join(', '), to: 'the app\'s own #if now also holds where the replacement exists' });
        continue;
      }
    }
    const found = cleanedLines[i].match(IMPORT_RE);
    const inOpened = found && depth > 0 && opened.some((r) => r.modules.has(found[3]));
    const m = depth === 0 || inOpened ? found : null;
    if (!m) {
      const inner = cleanedLines[i].match(IMPORT_RE);
      if (inner && inner[3] === 'FoundationNetworking') hasNetworkingImport = true;
      if (inner && inner[3] === 'Foundation' && depth === 0) hasFoundation = true;
      if (inner && (inner[3] === 'Combine' || inner[3] === 'OpenCombine')) hasCombineImport = true;
      if (inner && inner[3] === 'CircuitPortKit') hasKitImport = true;
      out.push(rawLines[i]);
      if (/^#\s*endif\b/.test(c)) depth = Math.max(0, depth - 1);
      continue;
    }
    const [, indent, attrs, module] = m;
    if (firstImportLine < 0) firstImportLine = out.length;
    if (module === 'Foundation') { hasFoundation = true; foundationLine = out.length; out.push(rawLines[i]); continue; }
    if (module === 'FoundationNetworking') { hasNetworkingImport = true; out.push(rawLines[i]); continue; }
    if (module === 'CircuitPortKit') { hasKitImport = true; hasPlainKitImport = true; }
    if (module === 'OpenCombine') hasCombineImport = true;

    const rule = SWIFT_IMPORT_RULES[module];
    if (rule) {
      out.push(...swiftImportBlock(module, rule, rawLines[i].trim(), attrs).map((l) => `${indent}${l}`));
      if (rule.type === 'visible') guardedModules.push(module);   // still what drawing code waits for
      useRule(module, rule, i + 1);
      continue;
    }
    const entry = APPLE_MODULES[module];
    if (entry && entry.kind !== 'portable') {
      out.push(...swiftGuardedImport(rawLines[i], module).map((l, k) => (k === 1 ? l : `${indent}${l}`)));
      guardedModules.push(module);
      changes.push({ line: i + 1, kind: 'guarded-import', module, to: entry.windows });
      continue;
    }
    out.push(rawLines[i]);
  }

  let text = out.join('\n');

  // Names the Mac supplies without an import: Foundation and SwiftUI re-export Combine and the
  // Keychain there. Off the Mac the file needs the imports spelled out.
  let implicitCombine = false;
  if (!hasCombineImport && COMBINE_SYMBOLS.test(clean.cleaned)) {
    const rule = SWIFT_IMPORT_RULES.Combine;
    implicitCombine = true;
    combineSwapped = true;
    needsKit = true;
    for (const [product, pkg] of rule.products) products.set(product, pkg);
    changes.push({ line: 0, kind: 'dropin', module: 'Combine', to: `${rule.note}; the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)` });
  }
  let keychainNames = false;
  if (!hasKitImport && KEYCHAIN_SYMBOLS.test(clean.cleaned)) {
    keychainNames = true;
    needsKit = true;
    kitModules.push('Security');
    changes.push({ line: 0, kind: 'kit', module: 'Security', to: 'CircuitPortKit Keychain names (the Mac gets them through Foundation)' });
  }

  // Foundation: the frameworks hidden above re-export it on Apple platforms, so a
  // file that leaned on that needs the import spelled out to build anywhere else.
  const injected = [];
  if (!hasFoundation && (guardedModules.length || changes.length)) injected.push('import Foundation');
  if (!hasNetworkingImport && NETWORKING_SYMBOLS.test(clean.cleaned)) {
    injected.push(...NETWORKING_BLOCK);
    changes.push({ line: foundationLine + 1 || 1, kind: 'networking', module: 'FoundationNetworking', to: 'URLSession lives in FoundationNetworking off Apple platforms' });
  }

  // Combine call sites that differ between Combine and OpenCombine: schedulers and
  // the Foundation publishers. One spelling (CircuitPortKit) that is right on both.
  if (combineSwapped) {
    const before = text;
    text = rewriteOutsideSpans(text, 'swift', [
      [/(\.(?:receive|subscribe)\(\s*on:\s*)(DispatchQueue\.main|DispatchQueue\.global\((?:[^()]|\([^()]*\))*\)|RunLoop\.main|RunLoop\.current|OperationQueue\.main)(?!\.circuitScheduler)\b/g, '$1$2.circuitScheduler'],
      [/(\.(?:debounce|throttle|delay|timeout|measureInterval)\((?:[^()]|\([^()]*\))*?scheduler:\s*)(DispatchQueue\.main|DispatchQueue\.global\((?:[^()]|\([^()]*\))*\)|RunLoop\.main|RunLoop\.current|OperationQueue\.main)(?!\.circuitScheduler)\b/g, '$1$2.circuitScheduler'],
      [/\bNotificationCenter\.default\.publisher\(/g, 'NotificationCenter.default.circuitCombine.publisher('],
      [/\bURLSession\.shared\.dataTaskPublisher\(/g, 'URLSession.shared.circuitCombine.dataTaskPublisher('],
    ]);
    if (text !== before) changes.push({ line: 0, kind: 'combine-bridge', module: 'Combine', to: 'schedulers and Foundation publishers through CircuitPortKit' });
  }
  if (implicitCombine) injected.push(...swiftImportBlock('Combine', SWIFT_IMPORT_RULES.Combine));
  if ((needsKit && (combineSwapped || uiSwapped) && !hasPlainKitImport) || keychainNames) injected.push('import CircuitPortKit');

  if (injected.length) {
    const lines = text.split('\n');
    // Decide on the cleaned view: an `import json` inside an embedded script (a
    // multi-line string) is not an import of this file.
    const at = insertionLine(lineViews(cleanSource(text, 'swift')).cleanedLines);
    lines.splice(at, 0, ...injected);
    text = lines.join('\n');
  }

  return { text, changed: text !== content, changes, products, needsKit, guardedModules, kitModules };
}

// Every `#if` of a file (by line) with its matching `#endif` and whether it has an #else/#elseif.
export function conditionalRegions(cleanedLines) {
  const regions = new Map();
  const stack = [];
  for (let i = 0; i < cleanedLines.length; i++) {
    const t = cleanedLines[i].trim();
    if (/^#\s*if\b/.test(t)) stack.push({ start: i, hasElse: false });
    else if (/^#\s*(else|elseif)\b/.test(t)) { if (stack.length) stack[stack.length - 1].hasElse = true; }
    else if (/^#\s*endif\b/.test(t)) {
      const top = stack.pop();
      if (top) regions.set(top.start, { end: i, hasElse: top.hasElse });
    }
  }
  return regions;
}

// `#if canImport(M)` (not negated) for a module with a drop-in or kit replacement R becomes
// `#if (canImport(M) || canImport(R))`. Null when there is nothing to open.
export function openCondition(rawLine) {
  const modules = new Set();
  const line = rawLine.replace(/(^|[^!\w])canImport\(\s*(\w+)\s*\)/g, (all, before, module) => {
    const rule = SWIFT_IMPORT_RULES[module];
    if (!rule || !['dropin', 'kit'].includes(rule.type) || !rule.imports?.length) return all;
    const replacement = rule.imports[0];
    if (new RegExp(`canImport\\(\\s*${replacement}\\s*\\)`).test(rawLine)) return all;
    modules.add(module);
    return `${before}(canImport(${module}) || canImport(${replacement}))`;
  });
  return modules.size ? { line, modules } : null;
}

// Where injected imports go: after the last top-level import, else after the
// leading comment block.
function insertionLine(lines) {
  let depth = 0;
  let last = -1;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (/^#\s*if\b/.test(t)) depth++;
    if (depth === 0 && /^(?:@\w+(?:\([^)]*\))?\s+)*import\s+\w/.test(t)) last = i;
    if (/^#\s*endif\b/.test(t)) { depth = Math.max(0, depth - 1); if (depth === 0 && last >= 0 && i > last && blockIsImportsOnly(lines, last, i)) last = i; }
  }
  if (last >= 0) return last + 1;
  // No import at all: after the leading comment block (blank in the cleaned view).
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  return i;
}

function blockIsImportsOnly(lines, from, to) {
  for (let i = from + 1; i < to; i++) {
    const t = lines[i].trim();
    if (t && !/^#/.test(t) && !/^(?:@\w+(?:\([^)]*\))?\s+)*import\s+\w/.test(t)) return false;
  }
  return true;
}

function rewriteOutsideSpans(text, lang, rules) {
  for (const [re, to] of rules) {
    const clean = cleanSource(text, lang);
    text = text.replace(re, (...args) => {
      const offset = args[args.length - 2];
      if (inSpan(clean.spans, offset)) return args[0];
      return to.replace(/\$(\d)/g, (_m, d) => args[Number(d)] ?? '');
    });
  }
  return text;
}

export function isolateSwiftSource(text) {
  if (text.startsWith(ISOLATE_OPEN)) return text;
  // Drop any declaration-level markers first: the whole file is going out.
  const body = text.split('\n').filter((l) => l !== ISOLATE_OPEN && l !== ISOLATE_CLOSE).join('\n');
  return `${ISOLATE_OPEN}\n${body}${body.endsWith('\n') ? '' : '\n'}${ISOLATE_CLOSE}\n`;
}

// Top-level declarations of a Swift file as line ranges [start, end] (0-based,
// inclusive). A declaration starts at column 0 with a declaration keyword or an
// attribute while no brace, bracket or #if is open; a top-level #if…#endif region is
// one chunk. Leading `//` comment lines travel with the declaration they describe.
const DECL_START = /^(@\w+|import\b|public\b|private\b|fileprivate\b|internal\b|open\b|package\b|final\b|indirect\b|nonisolated\b|static\b|class\b|struct\b|enum\b|protocol\b|extension\b|func\b|let\b|var\b|typealias\b|actor\b|precedencegroup\b|infix\b|prefix\b|postfix\b|macro\b|#\s*if\b)/;
const ATTR_ONLY = /^@\w+(\([^)]*\))?(\s+@\w+(\([^)]*\))?)*\s*$/;

export function swiftTopLevelChunks(text) {
  const clean = cleanSource(text, 'swift');
  const { rawLines, cleanedLines } = lineViews(clean);
  const starts = [];
  let brace = 0, paren = 0, cond = 0;
  for (let i = 0; i < cleanedLines.length; i++) {
    const line = cleanedLines[i];
    const t = line.trim();
    const open = brace === 0 && paren === 0 && cond === 0;
    if (open && DECL_START.test(line)) starts.push(i);
    if (/^#\s*if\b/.test(t)) cond++;
    else if (/^#\s*endif\b/.test(t)) cond = Math.max(0, cond - 1);
    for (const ch of line) {
      if (ch === '{') brace++;
      else if (ch === '}') brace = Math.max(0, brace - 1);
      else if (ch === '(' || ch === '[') paren++;
      else if (ch === ')' || ch === ']') paren = Math.max(0, paren - 1);
    }
  }
  const chunks = [];
  for (let k = 0; k < starts.length; k++) {
    let start = starts[k];
    let end = (k + 1 < starts.length ? starts[k + 1] : cleanedLines.length) - 1;
    // an attribute on its own line belongs to the declaration under it
    while (k + 1 < starts.length && cleanedLines.slice(start, end + 1).every((l) => !l.trim() || ATTR_ONLY.test(l.trim()))) {
      k++;
      end = (k + 1 < starts.length ? starts[k + 1] : cleanedLines.length) - 1;
    }
    // give the comment block right above the next declaration to that declaration
    while (end > start && (/^\s*\/\//.test(rawLines[end]) || !rawLines[end].trim())) end--;
    chunks.push({ start, end });
  }
  for (const c of chunks) {
    while (c.start > 0 && /^\s*\/\//.test(rawLines[c.start - 1]) && !chunks.some((o) => o !== c && c.start - 1 >= o.start && c.start - 1 <= o.end)) c.start--;
  }
  return chunks;
}

// Isolate only the declarations the compiler rejected. Returns null when an error
// falls outside every declaration (the caller then isolates the whole file).
export function isolateSwiftDeclarations(text, errorLines) {
  const chunks = swiftTopLevelChunks(text);
  const hit = new Set();
  for (const ln of errorLines) {
    const idx = chunks.findIndex((c) => ln - 1 >= c.start && ln - 1 <= c.end);
    if (idx < 0) return null;
    hit.add(idx);
  }
  const lines = text.split('\n');
  for (const idx of [...hit].sort((a, b) => b - a)) {
    const c = chunks[idx];
    if (lines[c.start] === ISOLATE_OPEN) continue;
    lines.splice(c.end + 1, 0, ISOLATE_CLOSE);
    lines.splice(c.start, 0, ISOLATE_OPEN);
  }
  return lines.join('\n');
}

// ---- What the Windows compiler never sees because the app's own #if leaves it out ----
// A converted package is compiled for Windows by SwiftPM with no custom flags beyond DEBUG, so
// its #if conditions can be decided here: canImport of an Apple-only module is false, of the
// package's own replacements true; os(Windows) true, every other os false; x86_64 true; an
// undefined flag false. Only what is decided false is counted; anything undecidable
// (hasFeature, …) counts as compiled. Circuit's own isolation markers are left to isolatedLoc.
const WINDOWS_IMPORTABLE = new Set([
  'Swift', 'Foundation', 'FoundationNetworking', 'FoundationEssentials', 'FoundationXML', 'Dispatch', 'XCTest', 'Testing',
  'Observation', 'RegexBuilder', 'Distributed', 'Synchronization', '_Concurrency', 'ucrt', 'WinSDK', 'CRT', 'vcruntime',
  'CircuitPortKit', 'OpenCombine', 'OpenCombineFoundation', 'OpenCombineDispatch', 'Crypto', 'SwiftToolchainCSQLite', 'SwiftCrossUI',
]);

export function evalCondition(expr) {
  const tokens = expr.replace(/\/\/.*$/, '').match(/&&|\|\||!|\(|\)|[A-Za-z_][\w.]*\s*\([^()]*\)|[A-Za-z_]\w*|\S/g) ?? [];
  let pos = 0;
  const atom = (t) => {
    const call = t.match(/^([A-Za-z_]\w*)\s*\(\s*([^()]*?)\s*\)$/);
    if (call) {
      const [, fn, arg] = call;
      const first = arg.split(',')[0].trim();
      if (fn === 'canImport') return WINDOWS_IMPORTABLE.has(first.split('.')[0]);
      if (fn === 'os') return first === 'Windows';
      if (fn === 'arch') return first === 'x86_64';
      if (fn === 'targetEnvironment') return false;
      if (fn === '_runtime') return first === '_Native';
      if (fn === '_endian') return first === 'little';
      if (fn === '_pointerBitWidth') return first === '_64';
      if (fn === 'compiler' || fn === 'swift') {
        const v = first.match(/^(>=|<)\s*(\d+)(?:\.(\d+))?/);
        if (!v) return null;
        const want = Number(v[2]) + Number(v[3] ?? 0) / 100;
        return v[1] === '>=' ? 6.02 >= want : 6.02 < want;
      }
      return null; // hasFeature, hasAttribute, …
    }
    if (t === 'true') return true;
    if (t === 'false') return false;
    if (t === 'DEBUG') return true;
    return /^[A-Za-z_]\w*$/.test(t) ? false : null; // an undefined flag is false
  };
  const unary = () => {
    const t = tokens[pos++];
    if (t === '!') { const v = unary(); return v == null ? null : !v; }
    if (t === '(') { const v = or(); pos++; return v; }
    return t == null ? null : atom(t);
  };
  const and = () => {
    let v = unary();
    while (tokens[pos] === '&&') { pos++; const w = unary(); v = v === false || w === false ? false : v == null || w == null ? null : true; }
    return v;
  };
  const or = () => {
    let v = and();
    while (tokens[pos] === '||') { pos++; const w = and(); v = v === true || w === true ? true : v == null || w == null ? null : false; }
    return v;
  };
  return or();
}

export function windowsInactiveLoc(text) {
  const frames = []; // { isolation, active: true|false|null, taken: true|false|null }
  let count = 0;
  for (const raw of text.split('\n')) {
    const t = raw.trim();
    if (raw === ISOLATE_OPEN) { frames.push({ isolation: true, active: true, taken: true }); continue; }
    if (raw === ISOLATE_CLOSE) { if (frames.length) frames.pop(); continue; }
    const d = t.match(/^#\s*(if|elseif|else|endif)\b\s*(.*)$/);
    if (d) {
      const [, kw, cond] = d;
      // Circuit's own per-platform import blocks carry the simulation flag: the import they
      // replace is served on Windows by its replacement, so they are not the app's own #if.
      if (kw === 'if' && cond.includes(SIM_FLAG)) { frames.push({ isolation: true, active: true, taken: true }); continue; }
      if (kw === 'if') { const v = evalCondition(cond); frames.push({ isolation: false, active: v, taken: v }); }
      else if (kw === 'elseif' && frames.length) {
        const f = frames[frames.length - 1];
        const v = evalCondition(cond);
        f.active = f.taken === true ? false : f.taken == null || v == null ? null : v;
        f.taken = f.taken === true || v === true ? true : f.taken == null || v == null ? null : false;
      } else if (kw === 'else' && frames.length) {
        const f = frames[frames.length - 1];
        f.active = f.taken == null ? null : !f.taken;
        f.taken = true;
      } else if (kw === 'endif' && frames.length) frames.pop();
      continue;
    }
    if (!t || frames.some((f) => f.isolation)) continue; // Circuit's isolation is counted as isolated
    if (frames.some((f) => f.active === false)) count++;
  }
  return count;
}

// Lines of code inside circuit-convert isolation markers.
export function isolatedLoc(text) {
  let depth = 0, inner = 0, count = 0;
  for (const l of text.split('\n')) {
    if (l === ISOLATE_OPEN) { depth++; continue; }
    if (depth > 0) {
      const t = l.trim();
      if (l === ISOLATE_CLOSE && inner === 0) { depth--; continue; }
      if (/^#\s*if\b/.test(t)) inner++;
      else if (/^#\s*endif\b/.test(t)) inner = Math.max(0, inner - 1);
      if (t) count++;
    }
  }
  return count;
}

// ---------------------------------------------------------------- Python rewrite
export function convertPythonSource(content) {
  const helpers = new Set();
  const changes = [];
  let text = content;
  for (const rule of PYTHON_RULES) {
    const clean = cleanSource(text, 'python');
    text = text.replace(rule.re, (...args) => {
      const offset = args[args.length - 2];
      if (inSpan(clean.spans, offset)) return args[0];
      helpers.add(rule.helper);
      changes.push({ kind: 'python-helper', hit: rule.hit, to: `circuit_port.${rule.helper}` });
      return rule.to(...args);
    });
  }
  const fc = text.match(PY_FCNTL_IMPORT);
  if (fc && !PY_FCNTL_OTHER_USE.test(cleanSource(text, 'python').cleaned)) {
    text = text.replace(PY_FCNTL_IMPORT, `${fc[1]}fcntl = circuit_port.fcntl_compat  # flock on every OS`);
    helpers.add('fcntl_compat');
    changes.push({ kind: 'python-helper', hit: 'fcntl', to: 'circuit_port.fcntl_compat' });
  }
  if (helpers.size) {
    const lines = text.split('\n');
    lines.splice(pythonImportLine(lines), 0,
      'try:',
      '    from . import circuit_port',
      'except ImportError:',
      '    import circuit_port');
    text = lines.join('\n');
  }
  return { text, changed: text !== content, changes, helpers: [...helpers] };
}

// After the module docstring / __future__ imports, before everything else — the
// helper has to be bound before a rewritten `fcntl = circuit_port…` line runs.
function pythonImportLine(lines) {
  let i = 0;
  while (i < lines.length && (/^\s*(#.*)?$/.test(lines[i]))) i++;
  const doc = lines[i]?.match(/^\s*[rRuUbB]?("""|''')/);
  if (doc) {
    const q = doc[1];
    if ((lines[i].split(q).length - 1) >= 2) i++;
    else { i++; while (i < lines.length && !lines[i].includes(q)) i++; i++; }
  }
  while (i < lines.length && (/^\s*(#.*)?$/.test(lines[i]) || /^from\s+__future__\s+import\b/.test(lines[i]))) i++;
  return i;
}

// ---------------------------------------------------------------- JS rewrite
export function convertJsSource(content, rel = '') {
  const isEsm = /\.mjs$/.test(rel) || /^\s*(import\s.+from\s+['"]|import\s+['"]|export\s)/m.test(content);
  const helpers = new Set();
  const changes = [];
  let text = content;
  if (!isEsm) return { text, changed: false, changes, helpers: [] };
  for (const rule of JS_RULES) {
    const clean = cleanSource(text, 'javascript');
    text = text.replace(rule.re, (...args) => {
      const offset = args[args.length - 2];
      if (inSpan(clean.spans, offset)) return args[0];
      helpers.add(rule.helper);
      changes.push({ kind: 'js-helper', hit: rule.hit, to: `circuitPort.${rule.helper}` });
      return rule.to(...args);
    });
  }
  if (helpers.size) {
    const lines = text.split('\n');
    let at = 0;
    for (let i = 0; i < lines.length; i++) if (/^\s*import\s/.test(lines[i])) at = i + 1;
    if (at === 0 && lines[0]?.startsWith('#!')) at = 1;
    lines.splice(at, 0, "import * as circuitPort from './circuit-port.mjs';");
    text = lines.join('\n');
  }
  return { text, changed: text !== content, changes, helpers: [...helpers] };
}

// ---------------------------------------------------------------- module selection
// An XcodeGen project.yml names the desktop app target's sources outright. Read just
// that: the first `type: application` target whose platform includes macOS.
export function xcodegenSources(root) {
  let text;
  try { text = fs.readFileSync(path.join(root, 'project.yml'), 'utf8'); } catch { return null; }
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let inTargets = false;
  let cur = null;
  let inSources = false;
  const targets = [];
  for (const raw of lines) {
    if (/^\S/.test(raw)) { inTargets = /^targets:\s*$/.test(raw); cur = null; inSources = false; continue; }
    if (!inTargets) continue;
    const t = raw.match(/^ {2}([^\s:#][^:]*):\s*$/);
    if (t) { cur = { name: t[1].trim(), type: '', platform: '', sources: [] }; targets.push(cur); inSources = false; continue; }
    if (!cur) continue;
    const kv = raw.match(/^ {4}(\w+):\s*(.*)$/);
    if (kv) {
      inSources = kv[1] === 'sources';
      if (kv[1] === 'type') cur.type = kv[2].trim();
      if (kv[1] === 'platform') cur.platform = kv[2].trim();
      if (inSources && kv[2].trim().startsWith('[')) cur.sources.push(...kv[2].replace(/[\[\]"']/g, '').split(',').map((x) => x.trim()).filter(Boolean));
      continue;
    }
    if (!inSources) continue;
    const item = raw.match(/^ {4,8}-\s*(?:path:\s*)?(["']?)([^"'#\n]+?)\1\s*$/);
    if (item && !/^\w+:\s/.test(item[2])) cur.sources.push(item[2].trim());
  }
  const app = targets.find((x) => x.type === 'application' && /macOS/i.test(x.platform) && x.sources.length);
  if (!app) return null;
  const out = app.sources.filter((p) => {
    try { const st = fs.statSync(path.join(root, p)); return st.isDirectory() || p.endsWith('.swift'); } catch { return false; }
  });
  return out.length ? { target: app.name, sources: out } : null;
}

function pickSwiftModule(files, { sources, exclude }) {
  const chosen = [];
  const skipped = [];
  const want = sources?.length ? sources.map((s) => s.replace(/\/+$/, '')) : null;
  for (const f of files) {
    if (path.basename(f.rel) === 'Package.swift') { skipped.push({ id: f.rel, why: 'package manifest' }); continue; }
    // main.swift is the Mac app's entry point (top-level code); a library has none.
    if (path.basename(f.rel) === 'main.swift') { skipped.push({ id: f.rel, why: 'the Mac entry point — the Windows app brings its own' }); continue; }
    if (want) {
      if (!want.some((d) => d === '.' || f.rel === d || f.rel.startsWith(`${d}/`))) { skipped.push({ id: f.rel, why: 'outside --sources' }); continue; }
    } else if (SECONDARY_DIR.test(`${path.posix.dirname(f.rel)}/`)) { skipped.push({ id: f.rel, why: 'another target (iOS, widget, marketing, …)' }); continue; }
    if (exclude?.some((g) => f.rel === g || f.rel.startsWith(`${g.replace(/\/+$/, '')}/`))) { skipped.push({ id: f.rel, why: 'excluded' }); continue; }
    chosen.push(f);
  }
  // swiftc refuses two files with the same name in one module: keep the one nearest
  // the root of the larger tree, report the other.
  const byName = new Map();
  for (const f of chosen) {
    const name = path.basename(f.rel);
    const prev = byName.get(name);
    if (!prev) { byName.set(name, f); continue; }
    const keep = prev.rel.split('/').length <= f.rel.split('/').length ? prev : f;
    const drop = keep === prev ? f : prev;
    byName.set(name, keep);
    skipped.push({ id: drop.rel, why: `same file name as ${keep.rel} (one module cannot hold both)` });
  }
  const kept = new Set([...byName.values()].map((f) => f.rel));
  return { chosen: chosen.filter((f) => kept.has(f.rel)), skipped };
}

// The Swift language settings the app is built with in Xcode, so the converted
// package is judged under the same rules (default MainActor isolation changes what
// compiles). Read from every project.pbxproj in the repo; the strictest wins.
export function detectSwiftSettings(root) {
  const settings = { defaultIsolationMainActor: false, approachableConcurrency: false, memberImportVisibility: false };
  const stack = [root];
  let seen = 0;
  while (stack.length && seen < 4000) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      seen++;
      if (e.isDirectory()) {
        if (e.name.endsWith('.xcodeproj')) {
          try {
            const pbx = fs.readFileSync(path.join(dir, e.name, 'project.pbxproj'), 'utf8');
            if (/SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor/.test(pbx)) settings.defaultIsolationMainActor = true;
            if (/SWIFT_APPROACHABLE_CONCURRENCY = YES/.test(pbx)) settings.approachableConcurrency = true;
            if (/SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES/.test(pbx)) settings.memberImportVisibility = true;
          } catch { /* unreadable project: defaults */ }
        } else if (!e.name.startsWith('.') && !['node_modules', 'build', 'DerivedData', 'dist', 'Pods'].includes(e.name) && dir.split(path.sep).length - root.split(path.sep).length < 2) {
          stack.push(path.join(dir, e.name));
        }
      }
    }
  }
  return settings;
}

// Names two imported modules both declare, settled in OpenCombine's favour by module-level
// aliases (they win over imported names): on a Mac simulating Windows, Foundation re-exports
// Combine; wherever SwiftCrossUI stands in for SwiftUI, it has its own ObservableObject,
// Published, Publisher and Cancellable. The app's code was written for Combine's.
const COMBINE_NAMES = ['Published', 'ObservableObject', 'ObservableObjectPublisher', 'AnyCancellable', 'Cancellable', 'AnyPublisher',
  'Publisher', 'Publishers', 'Subscriber', 'Subscribers', 'Subscription', 'Subscriptions', 'Subject', 'PassthroughSubject',
  'CurrentValueSubject', 'Just', 'Future', 'Deferred', 'Empty', 'Fail', 'Record', 'Scheduler', 'ImmediateScheduler',
  'ConnectablePublisher', 'CombineIdentifier', 'CustomCombineIdentifierConvertible', 'TopLevelDecoder', 'TopLevelEncoder', 'AnySubscriber'];
const SIM_COMBINE_FILE = '_CircuitConvert/CombineNamesForSimulation.swift';
function simCombineNames() {
  return [
    '// Generated by Circuit Convert. Combine names that another imported module also declares:',
    `// Foundation's re-exported Combine on a Mac simulating Windows (-D${SIM_FLAG}), SwiftCrossUI's`,
    "// own ObservableObject / Published / Publisher / Cancellable wherever it stands in for SwiftUI.",
    "// The app's code means Combine's, so OpenCombine's names win. Elsewhere this file is empty.",
    `#if canImport(OpenCombine) && (${SIM_FLAG} || (canImport(SwiftCrossUI) && !canImport(SwiftUI)))`,
    'import OpenCombine',
    ...COMBINE_NAMES.map((nm) => `typealias ${nm} = OpenCombine.${nm}`),
    '#endif',
    '',
    "// SwiftUI names CircuitPortKit provides where SwiftCrossUI stands in for SwiftUI (SwiftCrossUI's",
    "// own Image draws image files only; the kit's also draws SF Symbols).",
    `#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || ${SIM_FLAG})`,
    'import CircuitPortKit',
    'typealias Image = CircuitPortKit.CircuitImage',
    '#endif',
    '',
  ].join('\n');
}

function moduleNameFor(root, override) {
  if (override) return override;
  const base = path.basename(root).replace(/[^A-Za-z0-9_]/g, '_').replace(/^(\d)/, '_$1');
  return `${base || 'App'}Core`;
}

// ---------------------------------------------------------------- package manifest
function packageManifest({ moduleName, swiftRels, products, needsKit, settings }) {
  const pkgs = [...new Set([...products.values()])];
  const deps = pkgs.map((p) => `        .package(url: "${SWIFT_PACKAGES[p].url}", ${SWIFT_PACKAGES[p].requirement ?? `from: "${SWIFT_PACKAGES[p].from}"`}),`);
  const targetDeps = [
    ...(needsKit ? ['                "CircuitPortKit",'] : []),
    ...[...products.entries()].map(([product, pkg]) => `                .product(name: "${product}", package: "${SWIFT_PACKAGES[pkg].package}"),`),
  ];
  const kitDeps = [...products.entries()].filter(([, pkg]) => pkg === 'OpenCombine' || pkg === 'swift-cross-ui')
    .map(([product, pkg]) => `                .product(name: "${product}", package: "${SWIFT_PACKAGES[pkg].package}"),`);
  const modern = settings?.defaultIsolationMainActor || settings?.approachableConcurrency;
  const swiftSettings = [];
  if (modern) swiftSettings.push('.swiftLanguageMode(.v5)');
  if (settings?.defaultIsolationMainActor) swiftSettings.push('.defaultIsolation(MainActor.self)');
  if (settings?.approachableConcurrency) swiftSettings.push('.enableUpcomingFeature("NonisolatedNonsendingByDefault")', '.enableUpcomingFeature("InferIsolatedConformances")');
  if (settings?.memberImportVisibility) swiftSettings.push('.enableUpcomingFeature("MemberImportVisibility")');
  const lines = [
    `// swift-tools-version: ${modern ? '6.2' : '5.9'}`,
    '// Generated by Circuit Convert. Builds the converted sources for Windows, Linux and macOS.',
    `// Simulate the Windows configuration on a Mac:  swift build -Xswiftc -D${SIM_FLAG}`,
    'import PackageDescription',
    '',
    'let package = Package(',
    `    name: "${moduleName}",`,
    '    platforms: [.macOS("15.0")],',
    `    products: [.library(name: "${moduleName}", targets: ["${moduleName}"])],`,
    '    dependencies: [',
    ...deps,
    '    ],',
    '    targets: [',
  ];
  if (needsKit) {
    lines.push(
      '        .target(',
      '            name: "CircuitPortKit",',
      '            dependencies: [',
      ...kitDeps,
      '            ],',
      '            path: "kit/CircuitPortKit"',
      '        ),',
    );
  }
  lines.push(
    '        .target(',
    `            name: "${moduleName}",`,
    '            dependencies: [',
    ...targetDeps,
    '            ],',
    '            path: "app",',
    '            sources: [',
    ...swiftRels.map((r) => `                ${JSON.stringify(r)},`),
    `            ]${swiftSettings.length ? ',' : ''}`,
    ...(swiftSettings.length ? ['            swiftSettings: [', ...swiftSettings.map((x) => `                ${x},`), '            ]'] : []),
    '        ),',
    '    ]',
    ')',
    '',
  );
  return lines.join('\n');
}

function windowsWorkflow(moduleName) {
  return `# Generated by Circuit Convert: builds the converted package on a real Windows runner.
name: circuit-windows-build
on:
  workflow_dispatch:
  push:
    paths: ['Package.swift', 'app/**', 'kit/**', '.github/workflows/circuit-windows-build.yml']
permissions:
  contents: read
jobs:
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: compnerd/gha-setup-swift@main
        with:
          branch: swift-6.2-release
          tag: 6.2-RELEASE
      # The -D switch lets a Visual Studio newer than the toolchain's clang compile C++ dependencies (STL1000).
      - name: swift build (${moduleName})
        run: swift build -c debug -Xcxx -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH -Xcc -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH
`;
}

// ---------------------------------------------------------------- verify loop
const ERROR_RE = /^((?:[A-Za-z]:)?[^:\n]+\.swift):(\d+):(\d+): error: (.*)$/gm;
export const WINDOWS_TOOLCHAIN_FLAGS = ['-Xcxx', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH', '-Xcc', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH'];
// The build system reports some diagnostics (parse-phase ones) in its own shape.
const ERROR_RE_ALT = /^error: ((?:[A-Za-z]:)?[^:\n]+\.swift):(\d+):(\d+):? (.*)$/gm;
const MAX_DECL_ROUNDS = 10; // after this many declaration-level rounds a file is isolated whole
// "no such module" (the Windows toolchain's compiler) / "unable to resolve module dependency"
// (the dependency scanner of explicit-module builds, the Mac toolchain).
const NO_MODULE_RE = /(?:no such module|unable to resolve module dependency:) '([\w.]+)'/;

// A module this platform does not have and the port map does not know yet: hide its import the
// way a known Apple-only import is hidden, so the compiler judges the file declaration by
// declaration instead of the whole file failing at its import line.
export function guardMissingImport(text, lineNo, module) {
  const lines = text.split('\n');
  const i = lineNo - 1;
  const top = module.split('.')[0];
  const m = lines[i]?.match(IMPORT_RE);
  if (!m || m[3] !== top) return null;
  lines.splice(i, 1, ...swiftGuardedImport(lines[i], top).map((l, k) => (k === 1 ? l : `${m[1]}${l}`)));
  return lines.join('\n');
}

// The Mac toolchain's default build system (swift-build) stops at the first file that fails, so
// each pass would learn about one file. The native build system type-checks every file of the
// module and reports all their errors in one pass, as the Windows toolchain does by default.
let nativeBuildSystem = null;
function supportsNativeBuildSystem() {
  if (nativeBuildSystem == null) {
    const help = spawnSync('swift', ['build', '--help'], { encoding: 'utf8' });
    nativeBuildSystem = process.platform === 'darwin' && /--build-system[\s\S]*\bnative\b/.test(`${help.stdout ?? ''}`);
  }
  return nativeBuildSystem;
}

function runSwiftBuild(outDir, { sim, log }) {
  const args = ['build', '--package-path', outDir, '-Xswiftc', '-continue-building-after-errors', '-Xswiftc', '-suppress-warnings'];
  if (supportsNativeBuildSystem()) args.splice(1, 0, '--build-system', 'native');
  if (sim) args.push('-Xswiftc', `-D${SIM_FLAG}`);
  // Windows: a Visual Studio newer than the Swift toolchain's bundled clang makes the
  // MSVC STL refuse to compile any C++ dependency (STL1000). This is Microsoft's own
  // switch for exactly that pairing; it changes no code.
  if (process.platform === 'win32') args.push(...WINDOWS_TOOLCHAIN_FLAGS);
  log(`swift ${args.join(' ')}`);
  const r = spawnSync('swift', args, { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024, env: { ...process.env, NO_COLOR: '1', TERM: 'dumb' } });
  // eslint-disable-next-line no-control-regex
  const output = `${r.stdout ?? ''}\n${r.stderr ?? ''}`.replace(/\x1b\[[0-9;]*m/g, '');
  return { ok: r.status === 0, status: r.status, output, spawnError: r.error ? String(r.error.message ?? r.error) : null };
}

function errorsByFile(output, outDir) {
  // Compare on forward slashes, case-insensitively on Windows (drive letters vary).
  const norm = (p) => { const x = p.split('\\').join('/'); return process.platform === 'win32' ? x.toLowerCase() : x; };
  let real = outDir;
  try { real = fs.realpathSync(outDir); } catch { /* keep */ }
  const bases = [...new Set([norm(real), norm(outDir)])];
  const map = new Map();
  for (const m of [...output.matchAll(ERROR_RE), ...output.matchAll(ERROR_RE_ALT)]) {
    let abs = m[1].trim();
    try { abs = fs.realpathSync(abs); } catch { /* keep as printed */ }
    const full = abs.split('\\').join('/');
    const base = bases.find((b) => norm(full).startsWith(`${b}/`));
    const rel = base ? full.slice(base.length + 1) : full;
    if (!map.has(rel)) map.set(rel, []);
    const list = map.get(rel);
    const msg = `${m[2]}:${m[3]} ${m[4]}`;
    if (!list.includes(msg)) list.push(msg);
  }
  return map;
}

function verifySwift(outDir, swiftRels, { log, maxPasses }) {
  const isolated = new Map(); // app-relative path → { pass, errors }
  const guarded = new Map();  // app-relative path → modules whose import was hidden on this platform
  const passes = [];
  let ok = false;
  let failure = null;
  for (let pass = 1; pass <= maxPasses; pass++) {
    const r = runSwiftBuild(outDir, { sim: process.platform === 'darwin', log });
    if (r.spawnError) { failure = `swift could not be run: ${r.spawnError}`; break; }
    if (r.ok) { ok = true; passes.push({ pass, isolated: 0 }); break; }
    const errs = errorsByFile(r.output, outDir);
    const appErrs = [...errs.entries()].filter(([rel]) => rel.startsWith('app/'));
    const other = [...errs.entries()].filter(([rel]) => !rel.startsWith('app/'));
    if (other.length && !appErrs.length) {
      failure = `build failed outside the converted sources: ${other[0][0]}: ${other[0][1][0]}`;
      break;
    }
    if (!appErrs.length) {
      // A dependency, the linker or a C compiler (MSVC-style "error C1083:", "LNK1181") failed: show
      // the tail of the build, which is where that cause is, instead of only the exit code.
      const lines = r.output.split('\n');
      log(`the build failed outside the converted sources; last lines of the build:\n${lines.filter((l) => l.trim()).slice(-40).join('\n')}`);
      failure = `build failed without a source error: ${lines.filter((l) => /\berror\b[^:\n]{0,24}:|\bfatal error\b/i.test(l)).slice(0, 3).join(' | ') || `exit ${r.status}`}`;
      break;
    }
    let newly = 0;
    let hidden = 0;
    for (const [rel, list] of appErrs) {
      const appRel = rel.slice('app/'.length);
      const prev = isolated.get(appRel);
      if (prev?.whole) continue;
      const abs = path.join(outDir, rel);
      const text = readLf(abs);
      // A missing module first: hide its import and let the next pass judge the declarations.
      const missing = list.map((e) => ({ line: Number(e.split(':')[0]), module: e.match(NO_MODULE_RE)?.[1] })).filter((x) => x.module);
      if (missing.length) {
        let next = text;
        const done = [];
        for (const { line, module } of missing.sort((a, b) => b.line - a.line)) {
          const g = guardMissingImport(next, line, module);
          if (g != null) { next = g; done.push(module.split('.')[0]); }
        }
        if (done.length) {
          fs.writeFileSync(abs, next);
          guarded.set(appRel, [...new Set([...(guarded.get(appRel) ?? []), ...done])]);
          hidden++;
          continue;
        }
      }
      const total = locOf(text);
      const lines = list.map((e) => Number(e.split(':')[0]));
      let next = (prev?.rounds ?? 0) < MAX_DECL_ROUNDS ? isolateSwiftDeclarations(text, lines) : null;
      if (next != null && (next === text || isolatedLoc(next) > total * 0.85)) next = null;
      const whole = next == null;
      fs.writeFileSync(abs, whole ? isolateSwiftSource(text) : next);
      const info = prev ?? { pass, errors: [], errorCount: 0, rounds: 0 };
      for (const e of list) if (info.errors.length < 8 && !info.errors.includes(e)) info.errors.push(e);
      info.errorCount += list.length;
      info.rounds++;
      info.whole = whole;
      isolated.set(appRel, info);
      newly++;
    }
    passes.push({ pass, isolated: newly, ...(hidden ? { hiddenImports: hidden } : {}) });
    log(`pass ${pass}: the compiler rejected code in ${newly} file(s) — isolated (${isolated.size}/${swiftRels.length} files touched so far)${hidden ? `; hid a missing module's import in ${hidden} file(s)` : ''}`);
    if (!newly && !hidden) { failure = 'the compiler kept failing on files that were already isolated'; break; }
  }
  if (!ok && !failure) failure = `did not converge in ${maxPasses} passes`;
  return { ok, failure, passes, isolated, guarded };
}

// A Windows checkout can hand back CRLF; the isolation markers and the line counts are
// defined on LF text, so everything read back from a converted package goes through here.
function readLf(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n?/g, '\n');
}

function locOf(text) {
  let n = 0;
  for (const l of text.split('\n')) if (l.trim()) n++;
  return n;
}

function toolVersion(cmd, args) {
  try { return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim().split('\n')[0]; } catch { return null; }
}

function verificationRecord(v) {
  return {
    ran: true, ok: v.ok, failure: v.failure, passes: v.passes,
    configuration: process.platform === 'darwin' ? `simulated Windows configuration on macOS (-D${SIM_FLAG})` : `native ${process.platform === 'win32' ? 'Windows' : process.platform} build`,
    native: process.platform !== 'darwin',
    platform: process.platform,
    swift: toolVersion('swift', ['--version']),
  };
}

// Fold a verify run into the per-file records. What is isolated is read back from
// the files on disk, so the numbers always describe the package as it stands.
function applyVerification(records, v, outDir) {
  for (const [rel, modules] of v.guarded ?? []) {
    const rec = records.get(rel);
    if (!rec) continue;
    rec.guardedModules = [...new Set([...(rec.guardedModules ?? []), ...modules])];
    rec.hiddenOnVerify = [...new Set([...(rec.hiddenOnVerify ?? []), ...modules])];
  }
  for (const [rel, info] of v.isolated) {
    const rec = records.get(rel);
    if (!rec) continue;
    rec.isolated = true;
    rec.errors = [...(rec.errors ?? []), ...info.errors.filter((e) => !(rec.errors ?? []).includes(e))].slice(0, 10);
    rec.errorCount = (rec.errorCount ?? 0) + info.errorCount;
    rec.isolatedInPass = rec.isolatedInPass ?? info.pass;
    if (process.platform !== 'darwin') rec.isolatedOn = [...new Set([...(rec.isolatedOn ?? []), process.platform])];
  }
  for (const rec of records.values()) {
    if (rec.lang !== 'swift') continue;
    let text;
    try { text = readLf(path.join(outDir, 'app', rec.id)); } catch { continue; }
    rec.whole = text.startsWith(ISOLATE_OPEN);
    rec.isolatedLoc = rec.whole ? rec.loc : Math.min(rec.loc, isolatedLoc(text));
    if (rec.isolatedLoc > 0) rec.isolated = true;
    rec.inactiveLoc = rec.whole ? 0 : Math.min(rec.loc - rec.isolatedLoc, windowsInactiveLoc(text));
  }
}

// The API names of a module the kit covers in part, as they appear in compiler errors.
const KIT_API_NAMES = { Security: /'(?:Sec[A-Z]\w*|kSec\w+|CF[A-Z]\w*)'/ };

// Final status per file + the totals. `partial` = the file builds for Windows with
// some of its declarations isolated to the Mac; its lines are split between the two.
function summarize(records, verification, hasSwift) {
  for (const rec of records.values()) {
    rec.isolatedLoc = rec.isolatedLoc ?? 0;
    rec.inactiveLoc = rec.inactiveLoc ?? 0;
    if (rec.lang !== 'swift') {
      rec.status = rec.after === 'ready' ? (rec.rewritten ? 'converted' : 'portable') : rec.after === 'guarded' ? 'mac-only-skipped' : 'needs-windows-part';
      rec.isolatedLoc = rec.status === 'needs-windows-part' ? rec.loc : 0;
      continue;
    }
    if (!verification.ran) rec.status = rec.rewritten ? 'rewritten-unverified' : 'unverified';
    else if (!verification.ok) rec.status = 'unverified';
    else if (rec.isolated && (rec.whole || rec.isolatedLoc >= rec.loc)) { rec.status = 'needs-windows-part'; rec.isolatedLoc = rec.loc; }
    else if (rec.isolated) rec.status = 'partial';
    else rec.status = rec.rewritten ? 'converted' : 'portable';
  }
  const fileList = [...records.values()].sort((a, b) => a.id.localeCompare(b.id));
  const sum = (pred) => fileList.filter(pred).reduce((acc, r) => ({ files: acc.files + 1, loc: acc.loc + r.loc }), { files: 0, loc: 0 });
  const verified = verification.ran && verification.ok;
  const totals = {
    all: sum(() => true),
    portable: sum((r) => r.status === 'portable'),
    converted: sum((r) => r.status === 'converted'),
    partial: sum((r) => r.status === 'partial'),
    needsWindowsPart: sum((r) => r.status === 'needs-windows-part'),
    macOnlySkipped: sum((r) => r.status === 'mac-only-skipped'),
    unverified: sum((r) => r.status === 'unverified' || r.status === 'rewritten-unverified'),
  };
  totals.partial.isolatedLoc = fileList.filter((r) => r.status === 'partial').reduce((a, r) => a + r.isolatedLoc, 0);
  totals.partial.buildsLoc = totals.partial.loc - totals.partial.isolatedLoc;
  // Lines in files that build but sit in a branch of the app's own #if that Windows never compiles.
  const compiled = fileList.filter((r) => r.status === 'portable' || r.status === 'converted' || r.status === 'partial');
  totals.appIf = { files: compiled.filter((r) => r.inactiveLoc > 0).length, loc: compiled.reduce((a, r) => a + r.inactiveLoc, 0) };
  totals.buildsLoc = verified || !hasSwift ? totals.portable.loc + totals.converted.loc + totals.partial.buildsLoc - totals.appIf.loc : 0;
  totals.isolatedLoc = totals.needsWindowsPart.loc + totals.partial.isolatedLoc;
  totals.buildsForWindowsPct = totals.all.loc ? Math.round((totals.buildsLoc / totals.all.loc) * 1000) / 10 : null;

  // What the isolated code is waiting for: the Apple-only modules those files import. A file
  // whose only Apple module came from the kit, and whose errors name that module's API, is
  // waiting for the part of it the kit does not cover (Security: code signing, trust, keys).
  const missing = new Map();
  for (const r of fileList) {
    if (!r.isolatedLoc) continue;
    const beyondKit = (r.kitModules ?? []).filter((m) => KIT_API_NAMES[m]?.test((r.errors ?? []).join('\n'))).map((m) => `${m} (beyond CircuitPortKit)`);
    const mods = r.guardedModules?.length ? r.guardedModules : beyondKit.length ? beyondKit : ['(uses code that was isolated)'];
    for (const mod of mods) {
      if (!missing.has(mod)) missing.set(mod, { id: mod, windows: APPLE_MODULES[mod]?.windows ?? null, effort: APPLE_MODULES[mod]?.effort ?? null, files: 0, loc: 0 });
      const a = missing.get(mod); a.files++; a.loc += r.isolatedLoc;
    }
  }
  return { fileList, totals, windowsPartsNeeded: [...missing.values()].sort((a, b) => b.loc - a.loc) };
}

// Recompute the report of a converted package from the files as they stand — no build.
// For a package whose verdict came from another machine (a CI artifact): the verdict is
// kept, the per-file line counts are read back from disk.
export function recountConverted(outDir) {
  outDir = path.resolve(outDir);
  const prior = JSON.parse(fs.readFileSync(path.join(outDir, 'conversion.json'), 'utf8'));
  const records = new Map(prior.files.map((f) => [f.id, f]));
  applyVerification(records, { isolated: new Map() }, outDir);
  const hasSwift = prior.files.some((f) => f.lang === 'swift');
  const { fileList, totals, windowsPartsNeeded } = summarize(records, prior.verification, hasSwift);
  const result = { ...prior, out: outDir, totals, windowsPartsNeeded, files: fileList, recountedAt: Date.now() };
  fs.writeFileSync(path.join(outDir, 'conversion.json'), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(outDir, 'CONVERSION.md'), formatConvertMarkdown(result));
  return result;
}

// Re-run the compiler check on an already converted package — the step a Windows
// machine (or CI runner) performs. Anything the real Windows compiler rejects that
// the Mac simulation let through is isolated the same way, and the report rewritten.
export function reverifyConverted(outDir, { log = () => {}, maxPasses = 120 } = {}) {
  outDir = path.resolve(outDir);
  const prior = JSON.parse(fs.readFileSync(path.join(outDir, 'conversion.json'), 'utf8'));
  const records = new Map(prior.files.map((f) => [f.id, f]));
  const swiftRels = prior.files.filter((f) => f.lang === 'swift').map((f) => f.id);
  const v = verifySwift(outDir, swiftRels, { log, maxPasses });
  const verification = { ...verificationRecord(v), previous: prior.verification };
  applyVerification(records, v, outDir);
  const { fileList, totals, windowsPartsNeeded } = summarize(records, verification, swiftRels.length > 0);
  const result = { ...prior, out: outDir, generatedAt: Date.now(), verification, totals, windowsPartsNeeded, files: fileList };
  fs.writeFileSync(path.join(outDir, 'conversion.json'), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(outDir, 'CONVERSION.md'), formatConvertMarkdown(result));
  return result;
}

// ---------------------------------------------------------------- kit self-test
// Builds and runs lib/convert-kit/selftest/main.swift: the Keychain calls exactly as converted
// apps make them. On Windows the kit is its own module (as in every converted package, Swift 6
// language mode) over the real Credential Manager. Elsewhere the kit files and the test are one
// module built with CIRCUIT_KIT_SELFTEST, where the kit's declarations shadow Apple's and the store
// is in memory with Credential Manager's rules.
const SELFTEST_KIT_FILES = ['Security.swift', 'Keychain.swift'];

export function writeKitSelfTest(outDir, { platform = process.platform } = {}) {
  outDir = path.resolve(outDir);
  const native = platform === 'win32';
  for (const d of ['Sources', 'kit']) fs.rmSync(path.join(outDir, d), { recursive: true, force: true });
  const testDir = path.join(outDir, 'Sources', 'KitSelfTest');
  fs.mkdirSync(testDir, { recursive: true });
  fs.copyFileSync(path.join(KIT_DIR, 'selftest', 'main.swift'), path.join(testDir, 'main.swift'));
  let manifest;
  if (native) {
    const kitOut = path.join(outDir, 'kit', 'CircuitPortKit');
    fs.mkdirSync(kitOut, { recursive: true });
    for (const name of fs.readdirSync(path.join(KIT_DIR, 'CircuitPortKit'))) fs.copyFileSync(path.join(KIT_DIR, 'CircuitPortKit', name), path.join(kitOut, name));
    manifest = [
      '// swift-tools-version: 6.2',
      '// Generated by Circuit: the CircuitPortKit self-test, the kit as its own module (as in a converted package).',
      'import PackageDescription',
      '',
      'let package = Package(',
      '    name: "KitSelfTest",',
      '    targets: [',
      '        .target(name: "CircuitPortKit", path: "kit/CircuitPortKit"),',
      '        .executableTarget(name: "KitSelfTest", dependencies: ["CircuitPortKit"], path: "Sources/KitSelfTest"),',
      '    ]',
      ')',
      '',
    ].join('\n');
  } else {
    for (const name of SELFTEST_KIT_FILES) fs.copyFileSync(path.join(KIT_DIR, 'CircuitPortKit', name), path.join(testDir, name));
    manifest = [
      '// swift-tools-version: 5.9',
      '// Generated by Circuit: the CircuitPortKit self-test, kit + test in one module, in-memory store.',
      'import PackageDescription',
      '',
      'let package = Package(',
      '    name: "KitSelfTest",',
      '    targets: [',
      '        .executableTarget(',
      '            name: "KitSelfTest",',
      '            path: "Sources/KitSelfTest",',
      '            swiftSettings: [.define("CIRCUIT_KIT_SELFTEST"), .define("CIRCUIT_KIT_SELFTEST_SINGLE")]',
      '        ),',
      '    ]',
      ')',
      '',
    ].join('\n');
  }
  fs.writeFileSync(path.join(outDir, 'Package.swift'), manifest);
  return { outDir, store: native ? 'Windows Credential Manager' : 'in-memory store with Credential Manager rules' };
}

export function runKitSelfTest(outDir, { args = [], log = () => {} } = {}) {
  const info = writeKitSelfTest(outDir);
  log(`kit self-test in ${info.outDir} — ${info.store}`);
  const r = spawnSync('swift', ['run', '--package-path', info.outDir, 'KitSelfTest', ...args], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, env: { ...process.env, NO_COLOR: '1', TERM: 'dumb' },
  });
  const output = `${r.stdout ?? ''}${r.stderr ? `\n${r.stderr}` : ''}`;
  const passed = (output.match(/^PASS /gm) ?? []).length;
  const failed = (output.match(/^FAIL /gm) ?? []).length;
  return { ...info, ok: r.status === 0 && failed === 0 && passed > 0, status: r.status, passed, failed, output, spawnError: r.error ? String(r.error.message ?? r.error) : null };
}

// ---------------------------------------------------------------- the conversion
export function convertRepo(root, opts = {}) {
  const {
    target = 'windows', out, verify = false, sources = null, exclude = [], moduleName: moduleOverride = null,
    maxPasses = 120, log = () => {},
  } = opts;
  if (!CONVERT_TARGETS.includes(target)) throw new Error(`Unsupported convert target "${target}" (supported: ${CONVERT_TARGETS.join(', ')})`);
  if (!out) throw new Error('convert needs an output folder (--out <dir>)');
  root = path.resolve(root);
  const outDir = path.resolve(out);
  const rootReal = fs.realpathSync(root);
  if (outDir === root || outDir.startsWith(`${root}${path.sep}`) || outDir === rootReal || outDir.startsWith(`${rootReal}${path.sep}`)) {
    throw new Error('the output folder must be outside the source repo (the source is never modified)');
  }
  const startedAt = Date.now();
  const before = portCheck(root, { target });
  const { files } = discoverFiles(root);
  const internal = internalModules(root, files);
  const byRel = new Map(before.files.map((f) => [f.id, f]));

  fs.rmSync(path.join(outDir, 'app'), { recursive: true, force: true });
  fs.rmSync(path.join(outDir, 'kit'), { recursive: true, force: true });
  fs.mkdirSync(path.join(outDir, 'app'), { recursive: true });

  const appFiles = files.filter((f) => byRel.get(f.rel.split(path.sep).join('/'))?.role === 'app');
  const swiftAll = appFiles.filter((f) => f.lang === 'swift');
  const fromProject = sources?.length ? null : xcodegenSources(root);
  const moduleSources = sources?.length ? sources : fromProject?.sources ?? null;
  const { chosen: swiftChosen, skipped } = pickSwiftModule(swiftAll, { sources: moduleSources, exclude });
  const moduleName = moduleNameFor(root, moduleOverride);

  const products = new Map();
  let needsKit = false;
  const records = new Map(); // rel → record

  const writeOut = (rel, text) => {
    const abs = path.join(outDir, 'app', rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, text);
  };

  for (const f of swiftChosen) {
    const content = fs.readFileSync(f.abs, 'utf8').replace(/\r\n?/g, '\n');
    const c = convertSwiftSource(content);
    for (const [p, pkg] of c.products) products.set(p, pkg);
    if (c.needsKit) needsKit = true;
    writeOut(f.rel, c.text);
    records.set(f.rel, {
      id: f.rel, lang: 'swift', loc: locOf(content), before: byRel.get(f.rel)?.status ?? 'ready',
      rewritten: c.changed, changes: c.changes, guardedModules: c.guardedModules, kitModules: c.kitModules,
    });
  }

  // Python / JS app files: rewrite, then re-scan; a file only counts when nothing
  // Mac-only is left unguarded AND it still parses.
  const helperDirs = { py: new Set(), js: new Set() };
  for (const f of appFiles) {
    if (f.lang !== 'python' && f.lang !== 'javascript' && f.lang !== 'typescript') continue;
    if (SECONDARY_DIR.test(`${path.posix.dirname(f.rel)}/`) && !sources) continue;
    const content = fs.readFileSync(f.abs, 'utf8').replace(/\r\n?/g, '\n');
    const c = f.lang === 'python' ? convertPythonSource(content) : convertJsSource(content, f.rel);
    writeOut(f.rel, c.text);
    const rec = { id: f.rel, lang: f.lang, loc: locOf(content), before: byRel.get(f.rel)?.status ?? 'ready', rewritten: c.changed, changes: c.changes, guardedModules: [] };
    if (c.changed) {
      const dir = path.dirname(path.join(outDir, 'app', f.rel));
      if (f.lang === 'python') { helperDirs.py.add(dir); } else { helperDirs.js.add(dir); }
      const abs = path.join(outDir, 'app', f.rel);
      const check = f.lang === 'python'
        ? spawnSync('python3', ['-c', 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())', abs], { encoding: 'utf8' })
        : f.lang === 'javascript' ? spawnSync(process.execPath, ['--check', abs], { encoding: 'utf8' }) : { status: 0 };
      rec.parses = check.status === 0;
      if (!rec.parses) { rec.parseError = (check.stderr || '').trim().split('\n').slice(-2).join(' '); writeOut(f.rel, content); rec.rewritten = false; rec.changes = []; }
    }
    const after = scanFile(f.rel, f.lang, fs.readFileSync(path.join(outDir, 'app', f.rel), 'utf8'), internal);
    rec.after = after.status;
    rec.remaining = after.hits.filter((h) => !h.guarded).map((h) => h.id);
    records.set(f.rel, rec);
  }
  for (const dir of helperDirs.py) fs.copyFileSync(path.join(KIT_DIR, 'circuit_port.py'), path.join(dir, 'circuit_port.py'));
  for (const dir of helperDirs.js) fs.copyFileSync(path.join(KIT_DIR, 'circuit-port.mjs'), path.join(dir, 'circuit-port.mjs'));

  // The Swift package around the converted sources.
  const swiftRels = swiftChosen.map((f) => f.rel);
  let verification = { ran: false };
  if (swiftRels.length) {
    // The kit always ships: it is where the next Windows part goes, and the module
    // depends on it as soon as one converted file needs it.
    if (needsKit) {
      const kitOut = path.join(outDir, 'kit', 'CircuitPortKit');
      fs.mkdirSync(kitOut, { recursive: true });
      for (const name of fs.readdirSync(path.join(KIT_DIR, 'CircuitPortKit'))) {
        if (name === 'CombineBridge.swift' && !products.has('OpenCombine')) continue;
        fs.copyFileSync(path.join(KIT_DIR, 'CircuitPortKit', name), path.join(kitOut, name));
      }
    }
    const settings = detectSwiftSettings(root);
    const manifestRels = [...swiftRels];
    if (products.has('OpenCombine')) {
      writeOut(SIM_COMBINE_FILE, simCombineNames());
      manifestRels.push(SIM_COMBINE_FILE);
    }
    fs.writeFileSync(path.join(outDir, 'Package.swift'), packageManifest({ moduleName, swiftRels: manifestRels, products, needsKit, settings }));
    fs.mkdirSync(path.join(outDir, '.github', 'workflows'), { recursive: true });
    fs.writeFileSync(path.join(outDir, '.github', 'workflows', 'circuit-windows-build.yml'), windowsWorkflow(moduleName));
    fs.writeFileSync(path.join(outDir, '.gitignore'), '.build/\n*.pyc\n__pycache__/\n');
    fs.writeFileSync(path.join(outDir, '.gitattributes'), '* text=auto eol=lf\n');

    if (verify) {
      const v = verifySwift(outDir, swiftRels, { log, maxPasses });
      verification = verificationRecord(v);
      applyVerification(records, v, outDir);
    }
  }

  const after = fs.existsSync(path.join(outDir, 'app')) ? portCheck(path.join(outDir, 'app'), { target }) : null;
  const { fileList, totals, windowsPartsNeeded } = summarize(records, verification, swiftRels.length > 0);

  const result = {
    root, name: path.basename(root), target, out: outDir, moduleName,
    source: sourceFingerprint(root, [...swiftChosen, ...appFiles.filter((f) => records.has(f.rel) && f.lang !== 'swift')]),
    moduleSources: moduleSources ? { from: sources?.length ? '--sources' : `project.yml target ${fromProject.target}`, paths: moduleSources } : { from: 'every app Swift file outside iOS / widget / marketing folders', paths: null },
    generatedAt: Date.now(), tookMs: Date.now() - startedAt,
    before: { readyPct: before.summary.app.readyPct, files: before.summary.app.files, loc: before.summary.app.loc },
    after: after ? { readyPct: after.summary.app.readyPct, guardedLoc: after.summary.app.guarded.loc, needsWindowsLoc: after.summary.app.needsWindows.loc } : null,
    verification, totals,
    packages: [...new Set(products.values())].map((p) => ({ package: p, ...SWIFT_PACKAGES[p] })),
    kit: needsKit,
    windowsPartsNeeded,
    skipped,
    files: fileList,
  };
  fs.writeFileSync(path.join(outDir, 'conversion.json'), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(outDir, 'CONVERSION.md'), formatConvertMarkdown(result));
  return result;
}

// What the conversion read, so two runs can be shown to have judged the same code: a SHA-256
// over every file taken in (path + bytes, in path order), and the git commit when the folder is
// a repository's root (with how many paths had uncommitted changes).
export function sourceFingerprint(root, files) {
  const hash = crypto.createHash('sha256');
  const sorted = [...files].sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
  for (const f of sorted) {
    hash.update(f.rel);
    hash.update('\0');
    hash.update(fs.readFileSync(f.abs));
    hash.update('\0');
  }
  let git = null;
  const run = (args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  try {
    if (fs.realpathSync(run(['rev-parse', '--show-toplevel']).trim()) === fs.realpathSync(root)) {
      git = { head: run(['rev-parse', 'HEAD']).trim(), uncommitted: run(['status', '--porcelain']).split('\n').filter(Boolean).length };
    }
  } catch { /* not a repository, or no commit yet */ }
  return { sha256: hash.digest('hex'), files: sorted.length, git };
}

// ---------------------------------------------------------------- reports
const n = (x) => x.toLocaleString('en-US');

export function formatConvertReport(r) {
  const lines = [];
  lines.push(`[circuit] Convert for ${r.target} — ${r.name}`);
  lines.push(`  Output: ${r.out}`);
  const t = r.totals;
  if (!t.all.files) { lines.push('  No app source files found — nothing to convert.'); return lines.join('\n'); }
  lines.push(`  App code considered: ${n(t.all.loc)} lines in ${t.all.files} files`);
  if (r.verification.ran) {
    lines.push(`  Compiler check: ${r.verification.ok ? 'PASSED' : 'FAILED'} — ${r.verification.configuration}${r.verification.ok ? `, ${r.verification.passes.length} build pass(es)` : ` (${r.verification.failure})`}`);
    lines.push(`    builds for Windows unchanged ........ ${String(t.portable.files).padStart(4)} files  ${n(t.portable.loc).padStart(8)} lines`);
    lines.push(`    converted, builds for Windows ....... ${String(t.converted.files).padStart(4)} files  ${n(t.converted.loc).padStart(8)} lines`);
    lines.push(`    builds with some parts kept for Mac . ${String(t.partial.files).padStart(4)} files  ${n(t.partial.buildsLoc).padStart(8)} lines build, ${n(t.partial.isolatedLoc)} isolated`);
    lines.push(`    needs a Windows part (kept for Mac) . ${String(t.needsWindowsPart.files).padStart(4)} files  ${n(t.needsWindowsPart.loc).padStart(8)} lines`);
    if (t.macOnlySkipped.files) lines.push(`    Mac-only parts skipped on Windows ... ${String(t.macOnlySkipped.files).padStart(4)} files  ${n(t.macOnlySkipped.loc).padStart(8)} lines`);
    if (t.appIf?.loc) lines.push(`    left off Windows by the app's own #if ${String(t.appIf.files).padStart(4)} files  ${n(t.appIf.loc).padStart(8)} lines (not counted as building)`);
    if (t.unverified.files) lines.push(`    not verified ........................ ${String(t.unverified.files).padStart(4)} files  ${n(t.unverified.loc).padStart(8)} lines`);
    if (r.verification.ok) {
      lines.push(`  ${t.buildsForWindowsPct}% of the app code (${n(t.buildsLoc)} of ${n(t.all.loc)} lines) builds for Windows — measured by the compiler.`);
      lines.push(`  (Port check estimate before converting: ${r.before.readyPct ?? '—'}% of lines had no Mac-only parts. It reads imports; it cannot see code that leans on a Mac-only file.)`);
    }
  } else {
    lines.push(`  Rewritten: ${r.files.filter((f) => f.rewritten).length} files. NOT verified — run again with --verify to have the compiler decide what converted.`);
  }
  if (r.windowsPartsNeeded.length) {
    lines.push('  Windows parts the remaining files are waiting for:');
    for (const p of r.windowsPartsNeeded.slice(0, 20)) lines.push(`    ${p.id.padEnd(26)} ${String(p.files).padStart(4)} files ${n(p.loc).padStart(8)} lines${p.effort ? `  [${p.effort}]` : ''}${p.windows ? `  → ${p.windows}` : ''}`);
  }
  if (r.skipped.length) lines.push(`  Left out of the module: ${r.skipped.length} file(s) (see conversion.json → skipped).`);
  return lines.join('\n');
}

export function formatConvertMarkdown(r) {
  const t = r.totals;
  const md = [];
  md.push(`# ${r.name} — converted for ${r.target} by Circuit`, '');
  md.push(`Generated ${new Date(r.generatedAt).toISOString()} from \`${r.root}\`. The source repo was not modified.`, '');
  if (r.source) md.push(`Source read: ${r.source.files} files, sha256 \`${r.source.sha256.slice(0, 16)}\`${r.source.git ? ` (git ${r.source.git.head.slice(0, 9)}${r.source.git.uncommitted ? ` + ${r.source.git.uncommitted} uncommitted change(s)` : ''})` : ''}.`, '');
  if (r.verification.ran) {
    md.push(`**Compiler check: ${r.verification.ok ? 'passed' : 'FAILED'}** — ${r.verification.configuration}; ${r.verification.swift ?? 'swift'}.`);
    if (!r.verification.ok) md.push('', `Failure: ${r.verification.failure}`);
  } else {
    md.push('**Not verified.** The rewrites were applied but no compiler has judged them. Run `--convert … --verify`.');
  }
  md.push('', '| | Files | Lines |', '|---|---:|---:|');
  md.push(`| Builds for Windows unchanged | ${t.portable.files} | ${n(t.portable.loc)} |`);
  md.push(`| Converted, builds for Windows | ${t.converted.files} | ${n(t.converted.loc)} |`);
  md.push(`| Builds for Windows with some declarations kept for the Mac | ${t.partial.files} | ${n(t.partial.buildsLoc)} build · ${n(t.partial.isolatedLoc)} isolated |`);
  md.push(`| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | ${t.needsWindowsPart.files} | ${n(t.needsWindowsPart.loc)} |`);
  if (t.macOnlySkipped.files) md.push(`| Mac-only parts skipped on Windows | ${t.macOnlySkipped.files} | ${n(t.macOnlySkipped.loc)} |`);
  if (t.appIf?.loc) md.push(`| Left off Windows by the app's own \`#if\` (in files that build; not counted as building) | ${t.appIf.files} | ${n(t.appIf.loc)} |`);
  if (t.unverified.files) md.push(`| Not verified | ${t.unverified.files} | ${n(t.unverified.loc)} |`);
  md.push(`| **Total app code considered** | **${t.all.files}** | **${n(t.all.loc)}** |`, '');
  if (r.verification.ran && r.verification.ok) md.push(`**${t.buildsForWindowsPct}% of the app code builds for Windows** (${n(t.buildsLoc)} of ${n(t.all.loc)} lines) — measured by the compiler. The port check's estimate before converting was ${r.before.readyPct ?? '—'}% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.`, '');
  md.push('## Build it', '', '```sh', 'swift build                                   # Windows, Linux or macOS', `swift build -Xswiftc -D${SIM_FLAG}       # on a Mac: the Windows configuration`, '```', '');
  md.push('`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.', '');
  if (r.packages.length || r.kit) {
    md.push('## What replaced the Apple-only parts', '');
    for (const p of r.packages) md.push(`- \`${p.package}\` — ${p.url} (from ${p.from})`);
    if (r.kit) md.push('- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes');
    md.push('');
  }
  if (r.windowsPartsNeeded.length) {
    md.push('## Windows parts still needed', '', '| Apple part | Files | Lines | Size | Windows counterpart |', '|---|---:|---:|---|---|');
    for (const p of r.windowsPartsNeeded) md.push(`| ${p.id} | ${p.files} | ${n(p.loc)} | ${p.effort ?? ''} | ${p.windows ?? ''} |`);
    md.push('');
  }
  const isolated = r.files.filter((f) => f.isolated);
  if (isolated.length) {
    md.push('## Code kept for the Mac only, with the compiler\'s reason', '');
    for (const f of isolated.slice(0, 600)) md.push(`- \`${f.id}\` — ${f.whole || f.isolatedLoc >= f.loc ? `whole file (${n(f.loc)} lines)` : `${n(f.isolatedLoc)} of ${n(f.loc)} lines`} — ${f.errors?.[0] ?? ''}${f.errorCount > 1 ? ` (+${f.errorCount - 1} more)` : ''}`);
    md.push('');
  }
  const converted = r.files.filter((f) => f.status === 'converted');
  if (converted.length) {
    md.push('## Converted files', '');
    for (const f of converted) md.push(`- \`${f.id}\` — ${[...new Set(f.changes.map((c) => c.module ? `${c.module} → ${c.to}` : c.to))].join('; ')}`);
    md.push('');
  }
  return md.join('\n');
}
