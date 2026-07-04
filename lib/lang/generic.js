// Light-touch analysis for everything without a deep module:
// Go/Rust/Java/Kotlin/Ruby/C/shell get metrics + a few universal signals;
// JSON/YAML get validity checks.
import { baseMetrics, braceFunctions, stripStringsAndComments, isCommentLine } from './common.js';

const FN_RES = {
  go: /\bfunc\s+(?:\([^)]*\)\s*)?(\w+)/,
  rust: /\bfn\s+(\w+)/,
  java: /(?:public|private|protected|static|\s)+[\w<>\[\]]+\s+(\w+)\s*\([^)]*\)\s*\{/,
  kotlin: /\bfun\s+(\w+)/,
  c: /^[\w*\s]+\s(\w+)\s*\([^;]*\)\s*\{/,
  cpp: /^[\w:*&<>\s]+\s(\w+)\s*\([^;]*\)\s*(?:const\s*)?\{/,
  objc: /^\s*[-+]\s*\([^)]+\)\s*(\w+)/,
  ruby: /\bdef\s+([\w.?!]+)/,
  shell: /^(?:function\s+)?(\w+)\s*\(\)\s*\{/,
};

export function analyzeGeneric(rel, content, lang) {
  const m = baseMetrics(content, lang);
  const fnRe = FN_RES[lang];
  if (fnRe) m.functions = braceFunctions(content, fnRe, lang);

  const signals = { debugLogs: [], emptyCatches: [], evals: [], parseErrors: [] };
  const lines = content.split('\n');

  if (lang === 'json') {
    try { JSON.parse(content); } catch (e) {
      const lineMatch = /position (\d+)/.exec(e.message);
      let line = 1;
      if (lineMatch) line = content.slice(0, +lineMatch[1]).split('\n').length;
      signals.parseErrors.push({ line, message: e.message.slice(0, 100) });
    }
    return { metrics: m, imports: [], signals, decls: [] };
  }

  for (let i = 0; i < lines.length; i++) {
    if (isCommentLine(lines[i], lang)) continue;
    const code = stripStringsAndComments(lines[i], lang);
    if (lang === 'go' && /\bfmt\.Println\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'rust' && /\bprintln!\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if ((lang === 'java' || lang === 'kotlin') && /\bSystem\.out\.print/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'ruby' && /^\s*puts\s/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'shell' && /\beval\s/.test(code)) signals.evals.push(i + 1);
    if ((lang === 'java' || lang === 'cpp' || lang === 'c') && /\bcatch\s*\([^)]*\)\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
  }

  // Imports listed as external-only (no resolution for these languages yet)
  const imports = [];
  for (let i = 0; i < lines.length; i++) {
    let match;
    if (lang === 'go' && (match = lines[i].match(/^\s*(?:import\s+)?"([^"]+)"/)) && /import|^\s*"/.test(lines[i])) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if (lang === 'rust' && (match = lines[i].match(/^\s*use\s+([\w:]+)/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if ((lang === 'java' || lang === 'kotlin') && (match = lines[i].match(/^\s*import\s+([\w.]+)/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if (lang === 'ruby' && (match = lines[i].match(/^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    }
  }
  return { metrics: m, imports, signals, decls: [] };
}
