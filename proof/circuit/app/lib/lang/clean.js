// Source pre-pass: a small state machine that walks the file once and blanks
// out comment contents and string contents while preserving length and line
// structure. Everything downstream (metrics, import extraction, signals) works
// on the cleaned text or validates raw-regex matches against the spans, which
// kills the whole class of "code inside a string/comment" false positives.

const HASH_COMMENT_LANGS = new Set(['python', 'shell', 'ruby', 'yaml', 'toml']);
const NESTED_BLOCK_LANGS = new Set(['swift', 'rust']);

// Returns:
//   raw          original content
//   cleaned      same length; comment interiors and string interiors → spaces
//                (delimiters kept, newlines kept)
//   spans        sorted [{start, end, type: 'comment'|'string'}] (end exclusive)
//   lineOffsets  char offset of each line start
export function cleanSource(content, lang) {
  const hash = HASH_COMMENT_LANGS.has(lang);
  const nested = NESTED_BLOCK_LANGS.has(lang);
  const triple = lang === 'python' || lang === 'swift'; // '''/""" (py), """ (swift)
  const out = content.split(''); // mutable char array
  const spans = [];

  let i = 0;
  const n = content.length;
  let state = 'code';
  let quote = '';        // ' " ` """ '''
  let blockDepth = 0;
  let spanStart = 0;

  const blank = (from, to) => {
    for (let k = from; k < to; k++) if (out[k] !== '\n') out[k] = ' ';
  };
  const endSpan = (type, end) => spans.push({ start: spanStart, end, type });

  while (i < n) {
    const c = content[i];
    const c2 = content[i + 1];

    if (state === 'code') {
      if (!hash && c === '/' && c2 === '/') {
        state = 'line'; spanStart = i; i += 2; continue;
      }
      if (!hash && c === '/' && c2 === '*') {
        state = 'block'; blockDepth = 1; spanStart = i; i += 2; continue;
      }
      if (hash && c === '#') {
        state = 'line'; spanStart = i; i += 1; continue;
      }
      if (triple && (c === '"' || (lang === 'python' && c === "'")) && c2 === c && content[i + 2] === c) {
        state = 'string'; quote = c + c + c; spanStart = i; i += 3; continue;
      }
      if (c === '"' || c === "'" || (c === '`' && !hash)) {
        state = 'string'; quote = c; spanStart = i; i += 1; continue;
      }
      i++; continue;
    }

    if (state === 'line') {
      if (c === '\n') {
        endSpan('comment', i);
        blank(spanStart, i);
        state = 'code';
      }
      i++; continue;
    }

    if (state === 'block') {
      if (nested && c === '/' && c2 === '*') { blockDepth++; i += 2; continue; }
      if (c === '*' && c2 === '/') {
        blockDepth--;
        if (blockDepth <= 0) {
          endSpan('comment', i + 2);
          blank(spanStart, i + 2);
          state = 'code';
        }
        i += 2; continue;
      }
      i++; continue;
    }

    // string
    if (quote.length === 3) {
      if (c === quote[0] && c2 === quote[0] && content[i + 2] === quote[0]) {
        endSpan('string', i + 3);
        blank(spanStart + 3, i); // keep delimiters
        state = 'code'; i += 3; continue;
      }
      i++; continue;
    }
    if (c === '\\') { i += 2; continue; }
    if (c === quote || (c === '\n' && quote !== '`')) {
      // unterminated single-line string closes at newline (defensive)
      const end = c === quote ? i + 1 : i;
      endSpan('string', end);
      blank(spanStart + 1, c === quote ? i : i);
      state = 'code'; i++; continue;
    }
    i++; continue;
  }
  // EOF inside a span: close it
  if (state === 'line') { endSpan('comment', n); blank(spanStart, n); }
  else if (state === 'block') { endSpan('comment', n); blank(spanStart, n); }
  else if (state === 'string') { endSpan('string', n); blank(spanStart + quote.length, n); }

  const cleaned = out.join('');
  const lineOffsets = [0];
  for (let k = 0; k < n; k++) if (content[k] === '\n') lineOffsets.push(k + 1);

  return { raw: content, cleaned, spans, lineOffsets };
}

// Is a char offset inside any span (optionally of one type)?
export function inSpan(spans, offset, type) {
  // spans are sorted by start
  let lo = 0, hi = spans.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const s = spans[mid];
    if (offset < s.start) hi = mid - 1;
    else if (offset >= s.end) lo = mid + 1;
    else return type ? s.type === type : true;
  }
  return false;
}

export function lineOfOffset(lineOffsets, offset) {
  let lo = 0, hi = lineOffsets.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (lineOffsets[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return lo + 1; // 1-based
}

// Per-line views used by metrics: the cleaned line, whether the raw line had
// comment content, and the raw comment text on that line (for TODO scanning).
export function lineViews(clean) {
  const rawLines = clean.raw.split('\n');
  const cleanedLines = clean.cleaned.split('\n');
  const commentText = new Array(rawLines.length).fill('');
  for (const s of clean.spans) {
    if (s.type !== 'comment') continue;
    const startLine = lineOfOffset(clean.lineOffsets, s.start) - 1;
    const endLine = lineOfOffset(clean.lineOffsets, Math.max(s.start, s.end - 1)) - 1;
    for (let ln = startLine; ln <= endLine; ln++) {
      const lineStart = clean.lineOffsets[ln];
      const lineEnd = lineStart + rawLines[ln].length;
      const from = Math.max(s.start, lineStart);
      const to = Math.min(s.end, lineEnd);
      if (to > from) commentText[ln] += clean.raw.slice(from, to);
    }
  }
  return { rawLines, cleanedLines, commentText };
}
