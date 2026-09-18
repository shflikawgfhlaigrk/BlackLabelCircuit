// Swift: no file-level imports, so wiring comes from type references —
// each file declares types; other files referencing those names get an edge.
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

const DECL_RE = /\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)/g;
const EXTENSION_RE = /\bextension\s+([A-Z][A-Za-z0-9_]*)/g;
const IDENT_RE = /\b[A-Z][A-Za-z0-9_]{2,}\b/g;

export function analyzeSwift(rel, content) {
  const clean = cleanSource(content, 'swift');
  const m = baseMetrics(clean, 'swift');
  m.functions = braceFunctions(clean.cleaned, /\bfunc\s+(\w+)|\bvar\s+(\w+)\s*:\s*[^={]+\{|\binit\s*(\()/, 'swift');

  const { rawLines, cleanedLines } = lineViews(clean);
  const lines = cleanedLines;
  const decls = [];       // type names declared in this file
  const extensions = [];  // type names extended (edge to their declaring file)
  const identCounts = new Map(); // capitalized identifier → occurrence count
  const signals = { forceTries: [], forceCasts: [], forceUnwrapDecls: [], debugLogs: [], emptyCatches: [], fatalErrors: [] };

  for (let i = 0; i < lines.length; i++) {
    const code = lines[i];

    let match;
    DECL_RE.lastIndex = 0;
    while ((match = DECL_RE.exec(code))) decls.push({ name: match[1], line: i + 1 });
    EXTENSION_RE.lastIndex = 0;
    while ((match = EXTENSION_RE.exec(code))) extensions.push({ name: match[1], line: i + 1 });

    IDENT_RE.lastIndex = 0;
    while ((match = IDENT_RE.exec(code))) {
      identCounts.set(match[0], (identCounts.get(match[0]) ?? 0) + 1);
    }

    if (/\btry!\s/.test(code)) signals.forceTries.push(i + 1);
    if (/\bas!\s/.test(code)) signals.forceCasts.push(i + 1);
    if (/:\s*[A-Z][A-Za-z0-9_.<>\[\]]*!\s*($|[,)=])/.test(code)) signals.forceUnwrapDecls.push(i + 1);
    if (/\bprint\s*\(|\bNSLog\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (/\bfatalError\s*\(/.test(code)) signals.fatalErrors.push(i + 1);
    const catchMatch = code.match(/\bcatch\s*\{/);
    if (catchMatch) {
      const tail = code.slice(code.indexOf(catchMatch[0]) + catchMatch[0].length);
      if (/^\s*\}/.test(tail)) signals.emptyCatches.push(i + 1);
      else if (tail.trim() === '') {
        for (let j = i + 1; j < Math.min(lines.length, i + 3); j++) {
          const t = lines[j].trim();
          if (!t) continue;
          if (t === '}') signals.emptyCatches.push(i + 1);
          break;
        }
      }
    }
  }

  // Documentation: public/open decls preceded by /// (check raw — comments are blanked in cleaned)
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*(public|open)\s+(class|struct|enum|protocol|actor|func|var|let|init)\b/.test(lines[i])) {
      publicSymbols++;
      for (let j = i - 1; j >= Math.max(0, i - 2); j--) {
        const t = rawLines[j].trim();
        if (!t) continue;
        if (t.startsWith('///') || t.startsWith('*/') || t.startsWith('@')) documented++;
        break;
      }
    }
  }
  m.docs = { publicSymbols, documented };

  // `import Foundation` etc. are module-level → external list only
  const imports = [];
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^\s*(?:@\w+\s+)?import\s+(\w+)/);
    if (match) imports.push({ spec: match[1], line: i + 1, external: true });
  }

  return { metrics: m, imports, signals, decls, extensions, identCounts };
}

// Second pass over all swift files: build typeref edges from identCounts × declaring file.
export function linkSwiftFiles(swiftResults) {
  // type name → declaring rel (first declaration wins; duplicates flagged)
  const declOwner = new Map();
  const duplicateDecls = [];
  for (const { rel, result } of swiftResults) {
    for (const d of result.decls) {
      if (declOwner.has(d.name)) duplicateDecls.push({ name: d.name, rel, line: d.line, firstIn: declOwner.get(d.name) });
      else declOwner.set(d.name, rel);
    }
  }
  const links = [];
  for (const { rel, result } of swiftResults) {
    const targets = new Map(); // targetRel → {count, viaExtension}
    for (const [name, count] of result.identCounts) {
      const owner = declOwner.get(name);
      if (!owner || owner === rel) continue;
      const t = targets.get(owner) ?? { count: 0, viaExtension: false };
      t.count += count;
      targets.set(owner, t);
    }
    for (const ext of result.extensions) {
      const owner = declOwner.get(ext.name);
      if (owner && owner !== rel) {
        const t = targets.get(owner) ?? { count: 0, viaExtension: false };
        t.viaExtension = true;
        targets.set(owner, t);
      }
    }
    for (const [target, t] of targets) {
      links.push({ source: rel, target, kind: t.viaExtension ? 'extension' : 'typeref', count: t.count });
    }
  }
  return { links, duplicateDecls };
}
