// JavaScript / TypeScript: import graph + language-specific review signals.
import path from 'node:path';
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, inSpan, lineOfOffset, lineViews } from './clean.js';

// Run over the WHOLE raw file (multiline imports are the default style for
// long named-import lists); each match is validated to start outside strings
// and comments via the cleaner's spans.
const IMPORT_RES = [
  /\bimport\s+(?:type\s+)?[\w${},*\s]*?\s*from\s*['"]([^'"\n]+)['"]/g, // import x from 'y' (multiline ok)
  /\bimport\s*['"]([^'"\n]+)['"]/g,                                     // import 'y' (side effect)
  /\bexport\s+(?:type\s+)?[\w${},*\s]*?\s*from\s*['"]([^'"\n]+)['"]/g, // export { x } from 'y'
  /\brequire\s*\(\s*['"]([^'"\n]+)['"]\s*\)/g,                          // require('y')
  /\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)/g,                           // import('y')
];

const RESOLVE_EXTS = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts', '.cts', '.json', '.css'];

export function resolveJsImport(fromRel, spec, fileSet) {
  if (!spec.startsWith('.') && !spec.startsWith('/')) return { external: true, spec };
  const baseDir = path.posix.dirname(fromRel.split(path.sep).join('/'));
  let target = path.posix.normalize(path.posix.join(baseDir, spec));
  if (target.startsWith('/')) target = target.slice(1);
  target = target.replace(/[?#].*$/, ''); // vite-style ?raw suffixes
  const candidates = [target];
  // TS often imports './x.js' meaning './x.ts'
  if (/\.(js|mjs|cjs)$/.test(target)) {
    candidates.push(target.replace(/\.(js|mjs|cjs)$/, '.ts'), target.replace(/\.(js|mjs|cjs)$/, '.tsx'));
  }
  for (const ext of RESOLVE_EXTS) candidates.push(target + ext);
  for (const ext of RESOLVE_EXTS) candidates.push(path.posix.join(target, 'index' + ext));
  for (const c of candidates) {
    if (fileSet.has(c)) return { external: false, resolved: c, spec };
  }
  return { external: false, resolved: null, spec, target }; // broken wire
}

export function extractJsImports(clean) {
  const found = [];
  const seen = new Set();
  for (const re of IMPORT_RES) {
    re.lastIndex = 0;
    let match;
    while ((match = re.exec(clean.raw))) {
      if (inSpan(clean.spans, match.index)) continue; // inside string/comment
      const line = lineOfOffset(clean.lineOffsets, match.index);
      const key = match[1] + '@' + line;
      if (seen.has(key)) continue;
      seen.add(key);
      found.push({ spec: match[1], line });
    }
  }
  return found.sort((a, b) => a.line - b.line);
}

export function analyzeJs(rel, content, lang, fileSet) {
  const clean = cleanSource(content, lang);
  const m = baseMetrics(clean, lang);
  m.functions = braceFunctions(
    clean.cleaned,
    /(?:^|\s)(?:async\s+)?function\s*\*?\s*(\w+)|(?:^|\s)(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:function|\([^)]*\)\s*=>|\w+\s*=>)|^\s{2,}(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/,
    lang
  );

  const imports = extractJsImports(clean).map((f) => ({ ...f, ...resolveJsImport(rel, f.spec, fileSet) }));

  // Language-specific signals, over cleaned lines (strings/comments blanked).
  const { rawLines, cleanedLines } = lineViews(clean);
  const signals = { debugLogs: [], emptyCatches: [], anyTypes: [], tsIgnores: [], evals: [] };
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (/\bconsole\.(log|debug)\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (/\beval\s*\(|new\s+Function\s*\(/.test(code)) signals.evals.push(i + 1);
    if (lang === 'typescript') {
      const anyMatches = code.match(/:\s*any\b|as\s+any\b|<any[,>]/g);
      if (anyMatches) signals.anyTypes.push(...Array(anyMatches.length).fill(i + 1));
      if (/@ts-(ignore|nocheck|expect-error)/.test(rawLines[i])) signals.tsIgnores.push(i + 1);
    }
    const catchMatch = code.match(/\bcatch\s*(\([^)]*\))?\s*\{/);
    if (catchMatch) {
      const tail = code.slice(code.indexOf(catchMatch[0]) + catchMatch[0].length);
      if (/^\s*\}/.test(tail)) signals.emptyCatches.push(i + 1);
      else if (tail.trim() === '') {
        let j = i + 1, body = '';
        while (j < cleanedLines.length && j < i + 4) {
          const t = cleanedLines[j].trim();
          if (t === '}') { if (body.trim() === '') signals.emptyCatches.push(i + 1); break; }
          body += t; j++;
        }
      }
    }
  }

  // Documented exports: exported declarations preceded by a comment.
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < rawLines.length; i++) {
    if (/^\s*export\s+(default\s+)?(async\s+)?(function|class|const|let|interface|type|enum)\b/.test(cleanedLines[i])) {
      publicSymbols++;
      for (let j = i - 1; j >= Math.max(0, i - 3); j--) {
        const t = rawLines[j].trim();
        if (!t) continue;
        if (t.startsWith('*/') || t.startsWith('*') || t.startsWith('/**') || t.startsWith('//')) { documented++; }
        break;
      }
    }
  }
  m.docs = { publicSymbols, documented };
  return { metrics: m, imports, signals, decls: [] };
}
