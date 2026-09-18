// Light-touch analysis for everything without a deep module:
// Go/Rust/Java/Kotlin/Ruby/C/shell get metrics + a few universal signals;
// JSON/YAML get validity checks.
import { baseMetrics, braceFunctions } from './common.js';
import { cleanSource, lineViews } from './clean.js';

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
  const clean = cleanSource(content, lang);
  const m = baseMetrics(clean, lang);
  const fnRe = FN_RES[lang];
  if (fnRe) m.functions = braceFunctions(clean.cleaned, fnRe, lang);

  const signals = { debugLogs: [], emptyCatches: [], evals: [], parseErrors: [] };

  if (lang === 'json') {
    try { JSON.parse(content); } catch (e) {
      const lineMatch = /position (\d+)/.exec(e.message);
      let line = 1;
      if (lineMatch) line = content.slice(0, +lineMatch[1]).split('\n').length;
      signals.parseErrors.push({ line, message: e.message.slice(0, 100) });
    }
    return { metrics: m, imports: [], signals, decls: [] };
  }

  const { cleanedLines } = lineViews(clean);
  for (let i = 0; i < cleanedLines.length; i++) {
    const code = cleanedLines[i];
    if (lang === 'go' && /\bfmt\.Println\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'rust' && /\bprintln!\s*\(/.test(code)) signals.debugLogs.push(i + 1);
    if ((lang === 'java' || lang === 'kotlin') && /\bSystem\.out\.print/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'ruby' && /^\s*puts\s/.test(code)) signals.debugLogs.push(i + 1);
    if (lang === 'shell' && /\beval\s/.test(code)) signals.evals.push(i + 1);
    if ((lang === 'java' || lang === 'cpp' || lang === 'c') && /\bcatch\s*\([^)]*\)\s*\{\s*\}/.test(code)) signals.emptyCatches.push(i + 1);
  }

  // Imports listed as external-only (no resolution for these languages yet)
  const imports = [];
  const rawLines = content.split('\n');
  for (let i = 0; i < rawLines.length; i++) {
    let match;
    if (lang === 'go' && (match = rawLines[i].match(/^\s*(?:import\s+)?"([^"]+)"/)) && /import|^\s*"/.test(rawLines[i])) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if (lang === 'rust' && (match = rawLines[i].match(/^\s*use\s+([\w:]+)/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if ((lang === 'java' || lang === 'kotlin') && (match = rawLines[i].match(/^\s*import\s+([\w.]+)/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    } else if (lang === 'ruby' && (match = rawLines[i].match(/^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/))) {
      imports.push({ spec: match[1], line: i + 1, external: true });
    }
  }
  return { metrics: m, imports, signals, decls: [] };
}
