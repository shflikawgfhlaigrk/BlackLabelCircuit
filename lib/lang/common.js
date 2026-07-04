// Shared, language-agnostic source metrics. Regex-heuristic by design — fast,
// dependency-free, and good enough to grade like a reviewer skimming a diff.

const TODO_RE = /\b(TODO|FIXME|HACK|XXX)\b[:\s]?(.{0,60})/;
const BRANCH_RE = /\b(if|else if|elif|for|while|case|when|catch|except|guard)\b|&&|\|\||\?\s*[^:.]+:/g;

export function stripStringsAndComments(line, lang) {
  // Coarse: blank out string literals so keywords inside strings don't count.
  let s = line.replace(/(["'`])(?:\\.|(?!\1).)*\1/g, (m) => m[0] + '_'.repeat(Math.max(0, m.length - 2)) + m[0]);
  const commentIdx = lang === 'python' || lang === 'shell' || lang === 'yaml' || lang === 'ruby'
    ? s.indexOf('#')
    : s.indexOf('//');
  if (commentIdx >= 0) s = s.slice(0, commentIdx);
  return s;
}

export function isCommentLine(line, lang) {
  const t = line.trim();
  if (!t) return false;
  if (lang === 'python' || lang === 'shell' || lang === 'yaml' || lang === 'ruby') return t.startsWith('#');
  return t.startsWith('//') || t.startsWith('/*') || t.startsWith('*') || t.startsWith('*/');
}

// Does a comment line look like disabled code rather than prose?
function looksLikeCode(text) {
  return /[;{}()=]|\breturn\b|\bif\s*\(|\.\w+\(/.test(text) && !/^\s*[A-Z][a-z].*[.!?]\s*$/.test(text);
}

export function baseMetrics(content, lang) {
  const lines = content.split('\n');
  const m = {
    lines: lines.length,
    loc: 0,
    commentLines: 0,
    todos: [],            // {line, tag, text}
    longLines: [],        // line numbers > 160 chars
    branchCount: 0,
    maxNesting: 0,
    maxNestingLine: 1,
    commentedOutBlocks: [], // {line, length}
    functions: [],        // {name, line, length} — filled per-language below
  };

  let depth = 0;
  let runCommentCode = 0;
  let runStart = 0;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const trimmed = raw.trim();
    if (!trimmed) { runCommentCode = 0; continue; }

    if (isCommentLine(raw, lang)) {
      m.commentLines++;
      const body = trimmed.replace(/^(\/\/|#|\*|\/\*)+/, '').trim();
      const todo = body.match(TODO_RE) ?? trimmed.match(TODO_RE);
      if (todo) m.todos.push({ line: i + 1, tag: todo[1], text: todo[2].trim() });
      if (looksLikeCode(body)) {
        if (runCommentCode === 0) runStart = i + 1;
        runCommentCode++;
      } else {
        if (runCommentCode >= 3) m.commentedOutBlocks.push({ line: runStart, length: runCommentCode });
        runCommentCode = 0;
      }
      continue;
    }
    if (runCommentCode >= 3) m.commentedOutBlocks.push({ line: runStart, length: runCommentCode });
    runCommentCode = 0;

    m.loc++;
    if (raw.length > 160) m.longLines.push(i + 1);

    const code = stripStringsAndComments(raw, lang);
    const branches = code.match(BRANCH_RE);
    if (branches) m.branchCount += branches.length;

    if (lang === 'python') {
      const indent = raw.match(/^[ \t]*/)[0].replace(/\t/g, '    ').length;
      const level = Math.floor(indent / 4);
      if (level > m.maxNesting) { m.maxNesting = level; m.maxNestingLine = i + 1; }
    } else {
      for (const ch of code) {
        if (ch === '{') { depth++; if (depth > m.maxNesting) { m.maxNesting = depth; m.maxNestingLine = i + 1; } }
        else if (ch === '}') depth = Math.max(0, depth - 1);
      }
    }
  }
  if (runCommentCode >= 3) m.commentedOutBlocks.push({ line: runStart, length: runCommentCode });
  return m;
}

// Brace-language function extraction: find declaration lines, measure to the
// matching close brace. Works for JS/TS/Swift/Go/Java/C-family well enough.
export function braceFunctions(content, declRe, lang) {
  const lines = content.split('\n');
  const fns = [];
  for (let i = 0; i < lines.length; i++) {
    if (isCommentLine(lines[i], lang)) continue;
    const match = stripStringsAndComments(lines[i], lang).match(declRe);
    if (!match) continue;
    const name = match[1] ?? match[2] ?? '(anonymous)';
    // Walk forward to the opening brace, then to its match.
    let depth = 0, opened = false, end = i;
    outer:
    for (let j = i; j < Math.min(lines.length, i + 2000); j++) {
      const code = stripStringsAndComments(lines[j], lang);
      for (const ch of code) {
        if (ch === '{') { depth++; opened = true; }
        else if (ch === '}') {
          depth--;
          if (opened && depth <= 0) { end = j; break outer; }
        }
      }
      if (!opened && j > i + 3) break; // declaration without a body (protocol, abstract)
    }
    if (opened) fns.push({ name, line: i + 1, length: end - i + 1 });
  }
  return fns;
}

// Indent-language (Python) function extraction.
export function indentFunctions(content) {
  const lines = content.split('\n');
  const fns = [];
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^([ \t]*)(?:async\s+)?def\s+(\w+)/);
    if (!match) continue;
    const baseIndent = match[1].replace(/\t/g, '    ').length;
    let end = i;
    for (let j = i + 1; j < lines.length; j++) {
      const t = lines[j].trim();
      if (!t) continue;
      const indent = lines[j].match(/^[ \t]*/)[0].replace(/\t/g, '    ').length;
      if (indent <= baseIndent) break;
      end = j;
    }
    fns.push({ name: match[2], line: i + 1, length: end - i + 1 });
  }
  return fns;
}
