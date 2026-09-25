// User-defined architecture rules (CI-22). A repo may ship a `.circuit-rules.json`
// at its root declaring FORBIDDEN dependencies between path globs. Circuit resolves
// those rules over the REAL import graph it already builds — a violation is a genuine
// resolved import edge that crosses a boundary the author declared off-limits, never a
// heuristic guess. No rules file (or an empty `forbidden` list) → no rules → the
// analysis is byte-for-byte identical to today's.
//
// Schema (`.circuit-rules.json`):
//   {
//     "forbidden": [
//       { "from": "src/ui/**", "to": "src/db/**",
//         "name": "UI must not touch the DB layer",   // optional label
//         "severity": "critical",                       // optional: critical|major|minor|info
//         "points": 25 }                                // optional: coupling deduction (1–100)
//     ]
//   }
import fs from 'node:fs';
import path from 'node:path';

export const RULES_FILE = '.circuit-rules.json';
const SEVERITIES = new Set(['critical', 'major', 'minor', 'info']);
export const RULE_LIMITS = Object.freeze({ bytes: 262144, count: 128, pattern: 512, totalPatterns: 8192 });

// Compile a POSIX, repo-relative path glob with a RegExp-compatible .test().
// Two prefix tables give O(pattern length * path length) time and O(path length)
// space. Repository input never becomes a backtracking regular expression.
//   *   → any run of non-separator chars   (src/*.js  matches src/a.js, not src/x/a.js)
//   **  → any run including separators      (src/**    matches src/x/y/a.js)
//   **/ → zero or more leading segments      (**/util.js matches util.js and a/b/util.js)
//   ?   → a single non-separator char
export function globToRegExp(glob) {
  if (typeof glob !== 'string' || glob.length > RULE_LIMITS.pattern) {
    throw new Error(`Rule patterns must be strings of at most ${RULE_LIMITS.pattern} characters.`);
  }
  const tokens = [];
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') { i++; tokens.push('**/'); }
        else tokens.push('**');
      } else {
        tokens.push('*');
      }
    } else {
      tokens.push(c);
    }
  }
  return Object.freeze({ test(value) {
    if (typeof value !== 'string') return false;
    let previous = new Uint8Array(value.length + 1);
    let current = new Uint8Array(value.length + 1);
    previous[0] = 1;
    for (const token of tokens) {
      current.fill(0);
      let segmentReachable = 0;
      if (token === '*' || token === '**' || token === '**/') current[0] = previous[0];
      for (let j = 1; j <= value.length; j++) {
        const char = value[j - 1];
        if (token === '*') current[j] = previous[j] || (char !== '/' && current[j - 1]);
        else if (token === '**') current[j] = previous[j] || current[j - 1];
        else if (token === '**/') {
          // Zero or more NONEMPTY segments ending in '/', including zero.
          if (char === '/') {
            current[j] = previous[j] || segmentReachable;
            segmentReachable = 0;
          } else {
            segmentReachable ||= previous[j - 1] || current[j - 1];
            current[j] = previous[j];
          }
        } else current[j] = previous[j - 1] && (token === '?' ? char !== '/' : token === char);
      }
      [previous, current] = [current, previous];
    }
    return previous[value.length] === 1;
  } });
}

// Load and compile the repo's forbidden-dependency rules. Returns
// `{ rules }` where rules is null when there is nothing to enforce, plus an
// optional `error` string when a rules file exists but is unusable — surfaced
// honestly rather than silently ignored (§5.1). Never throws.
export function loadRules(root) {
  const file = path.join(root, RULES_FILE);
  let raw, fd;
  try {
    // Bound the actual read, even if the file changes after fstat. O_NONBLOCK
    // prevents a repository FIFO from hanging the reader before type checking.
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK ?? 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > RULE_LIMITS.bytes) throw new Error(`must be a regular file of at most ${RULE_LIMITS.bytes} bytes`);
    const buffer = Buffer.alloc(RULE_LIMITS.bytes + 1);
    let size = 0, read;
    while (size < buffer.length && (read = fs.readSync(fd, buffer, size, buffer.length - size, null)) > 0) size += read;
    if (size > RULE_LIMITS.bytes) throw new Error(`exceeds ${RULE_LIMITS.bytes} bytes`);
    raw = buffer.subarray(0, size).toString('utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return { rules: null };
    return { rules: null, error: `${RULES_FILE}: ${e.message}` };
  } finally { if (fd !== undefined) fs.closeSync(fd); }

  let parsed;
  try { parsed = JSON.parse(raw); }
  catch (e) { return { rules: null, error: `${RULES_FILE} is not valid JSON: ${e.message}` }; }

  if (!Array.isArray(parsed?.forbidden)) {
    return { rules: null, error: `${RULES_FILE} must contain a "forbidden" array of {from,to} rules.` };
  }
  if (parsed.forbidden.length > RULE_LIMITS.count) {
    return { rules: null, error: `${RULES_FILE} permits at most ${RULE_LIMITS.count} rules.` };
  }

  const forbidden = [];
  let totalPatterns = 0;
  for (const entry of parsed.forbidden) {
    if (!entry || typeof entry.from !== 'string' || typeof entry.to !== 'string') continue;
    totalPatterns += entry.from.length + entry.to.length;
    if (entry.from.length > RULE_LIMITS.pattern || entry.to.length > RULE_LIMITS.pattern || totalPatterns > RULE_LIMITS.totalPatterns) {
      return { rules: null, error: `${RULES_FILE} permits ${RULE_LIMITS.pattern} characters per pattern and ${RULE_LIMITS.totalPatterns} pattern characters in total.` };
    }
    forbidden.push({
      from: entry.from,
      to: entry.to,
      fromRe: globToRegExp(entry.from),
      toRe: globToRegExp(entry.to),
      severity: SEVERITIES.has(entry.severity) ? entry.severity : 'critical',
      points: Number.isFinite(entry.points) && entry.points > 0 ? Math.min(100, entry.points) : 20,
      name: typeof entry.name === 'string' && entry.name.trim() ? entry.name.trim() : null,
    });
  }
  // An explicitly empty `forbidden` list is legitimate ("no rules yet") — not an error.
  if (!forbidden.length) return { rules: null };
  return { rules: { forbidden } };
}

// Given RESOLVED internal import edges [{source, target, spec, line}], return the
// subset that violate a forbidden rule, each tagged with the rule that caught it.
// Zero rules or zero matches → [] (honesty: no rules file behaves exactly as today).
export function findViolations(edges, rules) {
  if (!rules?.forbidden?.length) return [];
  const out = [];
  // A graph can repeat a source/target many times. Evaluate each path once per
  // matcher per analysis; caches are discarded with this call, never global.
  const caches = new Map();
  const matches = (matcher, value) => {
    let cache = caches.get(matcher);
    if (!cache) caches.set(matcher, cache = new Map());
    if (!cache.has(value)) cache.set(value, matcher.test(value));
    return cache.get(value);
  };
  for (const e of edges) {
    for (const rule of rules.forbidden) {
      if (matches(rule.fromRe, e.source) && matches(rule.toRe, e.target)) {
        out.push({ ...e, rule });
        break; // first matching rule owns the violation
      }
    }
  }
  return out;
}
