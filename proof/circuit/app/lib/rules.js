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

// Translate a POSIX, repo-relative path glob into an anchored RegExp.
//   *   → any run of non-separator chars   (src/*.js  matches src/a.js, not src/x/a.js)
//   **  → any run including separators      (src/**    matches src/x/y/a.js)
//   **/ → zero or more leading segments      (**/util.js matches util.js and a/b/util.js)
//   ?   → a single non-separator char
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') { i++; re += '(?:[^/]+/)*'; }
        else re += '.*';
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else if ('.+^$()[]{}|\\'.includes(c)) {
      re += '\\' + c;
    } else {
      re += c;
    }
  }
  return new RegExp('^' + re + '$');
}

// Load and compile the repo's forbidden-dependency rules. Returns
// `{ rules }` where rules is null when there is nothing to enforce, plus an
// optional `error` string when a rules file exists but is unusable — surfaced
// honestly rather than silently ignored (§5.1). Never throws.
export function loadRules(root) {
  const file = path.join(root, RULES_FILE);
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); }
  catch { return { rules: null }; } // no file → no rules (today's behavior)

  let parsed;
  try { parsed = JSON.parse(raw); }
  catch (e) { return { rules: null, error: `${RULES_FILE} is not valid JSON: ${e.message}` }; }

  if (!Array.isArray(parsed?.forbidden)) {
    return { rules: null, error: `${RULES_FILE} must contain a "forbidden" array of {from,to} rules.` };
  }

  const forbidden = [];
  for (const entry of parsed.forbidden) {
    if (!entry || typeof entry.from !== 'string' || typeof entry.to !== 'string') continue;
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
  for (const e of edges) {
    for (const rule of rules.forbidden) {
      if (rule.fromRe.test(e.source) && rule.toRe.test(e.target)) {
        out.push({ ...e, rule });
        break; // first matching rule owns the violation
      }
    }
  }
  return out;
}
