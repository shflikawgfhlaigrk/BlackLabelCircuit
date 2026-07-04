// Shared, language-agnostic source metrics, computed over the cleaned source
// (comments and string interiors blanked by clean.js) so strings and block
// comments can't masquerade as code.
import { cleanSource, lineViews } from './clean.js';

const TODO_RE = /\b(TODO|FIXME|HACK|XXX)\b[:\s]?(.{0,60})/;
const BRANCH_RE = /\b(if|else if|elif|for|while|case|when|catch|except|guard)\b|&&|\|\||\?\s*[^:.]+:/g;

// Does comment text look like disabled code rather than prose?
function looksLikeCode(text) {
  return /[;{}()=]|\breturn\b|\bif\s*\(|\.\w+\(/.test(text) && !/^\s*[A-Z][a-z].*[.!?]\s*$/.test(text);
}

// clean: result of cleanSource(). Returns the metric bundle grade.js consumes.
export function baseMetrics(clean, lang) {
  const { rawLines, cleanedLines, commentText } = lineViews(clean);
  const m = {
    lines: rawLines.length,
    loc: 0,
    commentLines: 0,
    commentedOutLines: 0,
    todos: [],
    longLines: [],
    branchCount: 0,
    maxNesting: 0,
    maxNestingLine: 1,
    commentedOutBlocks: [],
    functions: [],
  };

  let depth = 0;
  let runCommentCode = 0;
  let runStart = 0;
  const flushRun = () => {
    if (runCommentCode >= 3) {
      m.commentedOutBlocks.push({ line: runStart, length: runCommentCode });
      m.commentedOutLines += runCommentCode;
    }
    runCommentCode = 0;
  };

  for (let i = 0; i < rawLines.length; i++) {
    const code = cleanedLines[i];
    const codeTrim = code.trim();
    const comment = commentText[i];
    const hasCode = codeTrim.length > 0 && !/^["'`]+$/.test(codeTrim);

    if (comment) {
      m.commentLines++;
      const body = comment.replace(/^\s*(\/\/|#|\*+|\/\*+)/, '').trim();
      const todo = body.match(TODO_RE);
      if (todo) m.todos.push({ line: i + 1, tag: todo[1], text: todo[2].trim() });
      if (!hasCode) {
        if (looksLikeCode(body)) {
          if (runCommentCode === 0) runStart = i + 1;
          runCommentCode++;
        } else flushRun();
      }
    } else if (!codeTrim) {
      flushRun();
    }

    if (!hasCode) continue;
    flushRun();
    m.loc++;
    if (rawLines[i].length > 160) m.longLines.push(i + 1);

    const branches = code.match(BRANCH_RE);
    if (branches) m.branchCount += branches.length;

    if (lang === 'python') {
      const indent = code.match(/^[ \t]*/)[0].replace(/\t/g, '    ').length;
      const level = Math.floor(indent / 4);
      if (level > m.maxNesting) { m.maxNesting = level; m.maxNestingLine = i + 1; }
    } else {
      for (const ch of code) {
        if (ch === '{') { depth++; if (depth > m.maxNesting) { m.maxNesting = depth; m.maxNestingLine = i + 1; } }
        else if (ch === '}') depth = Math.max(0, depth - 1);
      }
    }
  }
  flushRun();
  return m;
}

const NOT_A_FUNCTION = new Set(['if', 'else', 'for', 'while', 'switch', 'catch', 'return', 'do', 'try', 'guard', 'defer', 'with', 'unless', 'until']);

// Brace-language function extraction over CLEANED content: find declaration
// lines, measure to the matching close brace.
export function braceFunctions(cleanedContent, declRe, lang) {
  const lines = cleanedContent.split('\n');
  const fns = [];
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(declRe);
    if (!match) continue;
    const name = match[1] ?? match[2] ?? match[3] ?? '(anonymous)';
    if (NOT_A_FUNCTION.has(name)) continue;
    let depth = 0, opened = false, end = i;
    outer:
    for (let j = i; j < Math.min(lines.length, i + 2000); j++) {
      for (const ch of lines[j]) {
        if (ch === '{') { depth++; opened = true; }
        else if (ch === '}') {
          depth--;
          if (opened && depth <= 0) { end = j; break outer; }
        }
      }
      if (!opened && j > i + 3) break; // declaration without a body
    }
    if (opened) fns.push({ name, line: i + 1, length: end - i + 1 });
  }
  return fns;
}

// Indent-language (Python) function extraction over cleaned content.
export function indentFunctions(cleanedContent) {
  const lines = cleanedContent.split('\n');
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

export { cleanSource, lineViews };
