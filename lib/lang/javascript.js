// JavaScript / TypeScript: import graph + language-specific review signals.
import path from 'node:path';
import fs from 'node:fs';
import { baseMetrics, braceFunctions, stripStringsAndComments, isCommentLine } from './common.js';

const IMPORT_RES = [
  /\bimport\s+(?:[\w${},*\s]+\s+from\s+)?['"]([^'"]+)['"]/g,   // import x from 'y' / import 'y'
  /\bexport\s+(?:[\w${},*\s]+\s+)?from\s+['"]([^'"]+)['"]/g,   // export { x } from 'y'
  /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g,                    // require('y')
  /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g,                     // import('y')
];

const RESOLVE_EXTS = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts', '.cts', '.json', '.css'];

export function resolveJsImport(fromRel, spec, fileSet) {
  if (!spec.startsWith('.') && !spec.startsWith('/')) return { external: true, spec };
  const baseDir = path.posix.dirname(fromRel.split(path.sep).join('/'));
  let target = path.posix.normalize(path.posix.join(baseDir, spec));
  if (target.startsWith('/')) target = target.slice(1);
  // strip query/hash (vite-style ?raw imports)
  target = target.replace(/[?#].*$/, '');
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
  return { external: false, resolved: null, spec }; // relative but unresolvable → broken wire
}

export function analyzeJs(rel, content, lang, fileSet) {
  const m = baseMetrics(content, lang);
  m.functions = braceFunctions(
    content,
    /(?:^|\s)(?:async\s+)?function\s*\*?\s*(\w+)|(?:^|\s)(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:function|\([^)]*\)\s*=>|\w+\s*=>)|(?:^|\s)(\w+)\s*\([^)]*\)\s*\{/,
    lang
  );

  const imports = [];
  const seen = new Set();
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (isCommentLine(lines[i], lang)) continue;
    for (const re of IMPORT_RES) {
      re.lastIndex = 0;
      let match;
      while ((match = re.exec(lines[i]))) {
        const spec = match[1];
        const key = spec + '@' + i;
        if (seen.has(key)) continue;
        seen.add(key);
        imports.push({ spec, line: i + 1, ...resolveJsImport(rel, spec, fileSet) });
      }
    }
  }

  // Language-specific signals
  const signals = { debugLogs: [], emptyCatches: [], anyTypes: [], tsIgnores: [], evals: [] };
  const stripped = lines.map((l) => (isCommentLine(l, lang) ? '' : stripStringsAndComments(l, lang)));
  for (let i = 0; i < stripped.length; i++) {
    const code = stripped[i];
    if (/\bconsole\.(log|debug)\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (/\beval\s*\(|new\s+Function\s*\(/.test(code)) signals.evals.push(i + 1);
    if (lang === 'typescript') {
      const anyMatches = code.match(/:\s*any\b|as\s+any\b|<any[,>]/g);
      if (anyMatches) signals.anyTypes.push(...Array(anyMatches.length).fill(i + 1));
      if (/@ts-(ignore|nocheck|expect-error)/.test(lines[i])) signals.tsIgnores.push(i + 1);
    }
    // empty catch: `catch {...}` or `catch (e) {}` with nothing but whitespace/comments inside
    const catchMatch = code.match(/\bcatch\s*(\([^)]*\))?\s*\{/);
    if (catchMatch) {
      const tail = code.slice(code.indexOf(catchMatch[0]) + catchMatch[0].length);
      if (/^\s*\}/.test(tail)) signals.emptyCatches.push(i + 1);
      else if (tail.trim() === '') {
        // multi-line: check next non-blank lines for immediate close or bare comment-only body
        let j = i + 1, body = '';
        while (j < lines.length && j < i + 4) {
          const t = stripped[j].trim();
          if (t === '}') { if (body.trim() === '') signals.emptyCatches.push(i + 1); break; }
          body += t; j++;
        }
      }
    }
  }

  // Documented exports: exported declarations preceded by /** */ or //
  let publicSymbols = 0, documented = 0;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*export\s+(default\s+)?(async\s+)?(function|class|const|let|interface|type|enum)\b/.test(lines[i])) {
      publicSymbols++;
      for (let j = i - 1; j >= Math.max(0, i - 3); j--) {
        const t = lines[j].trim();
        if (!t) continue;
        if (t.startsWith('*/') || t.startsWith('*') || t.startsWith('/**') || t.startsWith('//')) { documented++; }
        break;
      }
    }
  }
  m.docs = { publicSymbols, documented };
  return { metrics: m, imports, signals, decls: [] };
}
