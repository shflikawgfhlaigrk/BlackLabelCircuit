// The senior-engineer rubric. Six dimensions, each 0–100, weighted into a
// file score. Every deduction carries a finding written like a review comment.

export const DIMENSIONS = {
  complexity: { weight: 0.25, label: 'Complexity' },
  safety:     { weight: 0.20, label: 'Safety' },
  structure:  { weight: 0.15, label: 'Structure' },
  hygiene:    { weight: 0.15, label: 'Hygiene' },
  coupling:   { weight: 0.15, label: 'Coupling' },
  docs:       { weight: 0.10, label: 'Documentation' },
};

const GRADE_SCALE = [
  [97, 'A+'], [93, 'A'], [90, 'A-'], [87, 'B+'], [83, 'B'], [80, 'B-'],
  [77, 'C+'], [73, 'C'], [70, 'C-'], [67, 'D+'], [63, 'D'], [60, 'D-'], [0, 'F'],
];

export function letterFor(score) {
  for (const [min, letter] of GRADE_SCALE) if (score >= min) return letter;
  return 'F';
}

function plural(n, word) { return `${n} ${word}${n === 1 ? '' : 's'}`; }

// Each rule returns findings: {dim, severity, points, line?, msg}
// severity: critical | major | minor | info. points are deducted from that dimension.
export function gradeFile(file) {
  const { metrics: m, signals: s = {}, imports = [], lang } = file;
  const findings = [];
  const add = (dim, severity, points, msg, line) => findings.push({ dim, severity, points, msg, ...(line ? { line } : {}) });

  // ---- Structure (file shape) ----
  // Points scale within tiers so one extra line never moves a full letter grade.
  if (m.loc > 800) add('structure', 'major', Math.min(35, 25 + Math.round((m.loc - 800) / 200)), `${m.loc} lines of code in one file — this is a god file. Split it along its responsibilities.`, 1);
  else if (m.loc > 400) add('structure', 'minor', 6 + Math.round(6 * (m.loc - 400) / 400), `${m.loc} lines of code — getting heavy. Consider splitting before it becomes a god file.`, 1);
  const hugeFns = m.functions.filter((f) => f.length > 120);
  const longFns = m.functions.filter((f) => f.length > 60 && f.length <= 120);
  for (const f of hugeFns.slice(0, 3)) add('structure', 'major', Math.min(20, 12 + Math.round((f.length - 120) / 15)), `\`${f.name}\` runs ${f.length} lines — a function this long is doing several jobs. Extract the distinct steps.`, f.line);
  for (const f of longFns.slice(0, 3)) add('structure', 'minor', 3 + Math.round(4 * (f.length - 60) / 60), `\`${f.name}\` is ${f.length} lines. Anything past ~60 usually wants extracting.`, f.line);
  // Long parameter lists are a maintainability smell: past ~5 arguments a call is
  // hard to read and easy to mis-order, and the count usually signals the function
  // is juggling too many concerns. Threshold measured clean at >=6 (Circuit's own
  // tree fires zero). Group related arguments into an object/struct.
  const wideFns = m.functions.filter((f) => (f.params ?? 0) >= 6);
  for (const f of wideFns.slice(0, 3)) add('structure', 'minor', Math.min(9, 3 + (f.params - 6)), `\`${f.name}\` takes ${f.params} parameters. A long parameter list is hard to call correctly and usually means the function is doing too much — group related arguments into an object or struct.`, f.line);
  // Boolean flag arguments are the "boolean-trap" smell: a call reads as a
  // mystery `render(x, true, false)`, and each flag usually selects between two
  // behaviours the function should split apart. Threshold measured clean at >=2
  // (Circuit's own tree fires zero — its lone flag param, loadGraph's, sits at 1).
  const flagFns = m.functions.filter((f) => (f.boolFlags ?? 0) >= 2);
  for (const f of flagFns.slice(0, 3)) add('structure', 'minor', Math.min(8, 3 + (f.boolFlags - 2)), `\`${f.name}\` takes ${f.boolFlags} boolean flag parameters. Boolean arguments make call sites unreadable and usually mean the function bundles several behaviours behind on/off switches — split them into separate functions.`, f.line);

  // ---- Complexity ----
  if (m.maxNesting > 8) add('complexity', 'critical', 30, `Nesting reaches ${m.maxNesting} levels deep. This needs restructuring, not patching.`, m.maxNestingLine);
  else if (m.maxNesting > 6) add('complexity', 'major', 20, `Nesting reaches ${m.maxNesting} levels deep. Invert conditions, use early returns, or extract helpers.`, m.maxNestingLine);
  else if (m.maxNesting > 4) add('complexity', 'minor', 8, `Nesting hits ${m.maxNesting} levels. Early returns would flatten this.`, m.maxNestingLine);
  const branchDensity = m.loc > 0 ? m.branchCount / m.loc : 0;
  if (m.loc > 60 && branchDensity > 0.6) add('complexity', 'critical', 35, `${m.branchCount} branch points across ${m.loc} lines — decisions on most lines. Nobody can hold this file in their head; restructure it.`);
  else if (m.loc > 60 && branchDensity > 0.45) add('complexity', 'critical', 25, `${m.branchCount} branch points across ${m.loc} lines — a decision on nearly every other line. Nobody can hold this file in their head; restructure it.`);
  else if (m.loc > 60 && branchDensity > 0.35) add('complexity', 'major', 15, `${m.branchCount} branch points across ${m.loc} lines — roughly one decision every ${Math.max(1, Math.round(1 / branchDensity))} lines. This file is hard to hold in your head.`);
  else if (m.loc > 60 && branchDensity > 0.22) add('complexity', 'minor', 7, `High branch density (${m.branchCount} decisions in ${m.loc} lines). Watch the conditional sprawl.`);

  // ---- Safety ----
  const emptyCatchMsg = lang === 'python'
    ? `\`except: pass\` swallows the error silently. Log it or handle it.`
    : lang === 'go'
      ? `\`if err != nil { }\` checks the error then drops it on the floor. Handle it or return it.`
      : `Empty catch block swallows the error silently. Log it, rethrow it, or handle it.`;
  for (const line of (s.emptyCatches ?? []).slice(0, 4)) add('safety', 'critical', 12, emptyCatchMsg, line);
  for (const line of (s.bareExcepts ?? []).slice(0, 3)) add('safety', 'major', 8, `Bare \`except:\` catches everything including KeyboardInterrupt. Catch specific exceptions.`, line);
  for (const line of (s.forceTries ?? []).slice(0, 4)) add('safety', 'major', 8, `\`try!\` here will crash the app if this throws. Handle the error or use \`try?\` with a fallback.`, line);
  for (const line of (s.forceCasts ?? []).slice(0, 3)) add('safety', 'major', 6, `\`as!\` force cast — one unexpected type and this crashes. Use \`as?\` and handle the miss.`, line);
  for (const u of (s.unsafeCalls ?? []).slice(0, 4)) add('safety', 'critical', 12, `\`${u.fn}()\` writes without a bounds argument — a classic buffer-overflow vector. Use a bounded variant (\`snprintf\`, \`strlcpy\`, \`strlcat\`).`, u.line);
  for (const line of (s.forceUnwrapDecls ?? []).slice(0, 3)) add('safety', 'minor', 4, `Implicitly-unwrapped optional declaration. Every use is a latent crash.`, line);
  // Kotlin `!!` — force-unwrap that throws NullPointerException on null. Density-
  // scaled like `any` so an idiomatic one-off stays minor but sprawl reads as risk.
  if ((s.notNullAsserts ?? []).length > 4) add('safety', 'major', 10, `${plural(s.notNullAsserts.length, '\`!!\` not-null assertion')} — each throws a NullPointerException on null instead of handling it. Prefer \`?.\`, \`?:\`, or a checked \`if\`.`, s.notNullAsserts[0]);
  else for (const line of (s.notNullAsserts ?? []).slice(0, 2)) add('safety', 'minor', 4, `\`!!\` not-null assertion — a latent NullPointerException. Use \`?.\`/\`?:\` or check for null.`, line);
  for (const line of (s.evals ?? []).slice(0, 2)) add('safety', 'critical', 15, `\`eval\`/dynamic code execution — an injection vector and a debugging nightmare. Almost never necessary.`, line);
  for (const sec of (s.hardcodedSecrets ?? []).slice(0, 4)) add('safety', 'critical', 15, `Hardcoded ${sec.kind} in source. Move it to an environment variable or a secret manager and rotate it — a committed credential must be treated as already compromised.`, sec.line);
  for (const line of (s.mutableDefaults ?? []).slice(0, 3)) add('safety', 'major', 8, `Mutable default argument — shared across every call. Use \`None\` and create inside.`, line);
  for (const line of (s.tsIgnores ?? []).slice(0, 3)) add('safety', 'major', 6, `\`@ts-ignore\` hides a type error instead of fixing it. The error is still there at runtime.`, line);
  if ((s.anyTypes ?? []).length > 5) add('safety', 'major', 10, `${plural(s.anyTypes.length, '\`any\` type')} — the type checker is switched off across much of this file.`, s.anyTypes[0]);
  else if ((s.anyTypes ?? []).length > 0) add('safety', 'minor', 3, `${plural(s.anyTypes.length, '\`any\` type')} here. Each one is a hole in the type checking.`, s.anyTypes[0]);
  if ((s.fatalErrors ?? []).length > 2) add('safety', 'minor', 5, `${s.fatalErrors.length} \`fatalError\` calls — each is a deliberate crash. Fine for unreachable code, risky elsewhere.`, s.fatalErrors[0]);
  // Aborts-on-failure: Go `panic()`, Rust `unwrap()`/`expect()`/`panic!`. Density-scaled
  // like `any` types so idiomatic one-offs stay minor but sprawl reads as a real risk.
  const panics = s.panics ?? [];
  const panicNoun = lang === 'go' ? '`panic()` call' : '`unwrap()`/`expect()`/`panic!` call';
  const panicFix = lang === 'go' ? 'Return an `error` and let the caller decide.' : 'Handle the `Result`/`Option` instead of crashing.';
  if (panics.length > 6) add('safety', 'major', 12, `${plural(panics.length, panicNoun)} — each aborts the whole program on an unexpected value. ${panicFix}`, panics[0]);
  else if (panics.length > 0) add('safety', 'minor', 3, `${plural(panics.length, panicNoun)} that abort on failure. ${panicFix}`, panics[0]);
  for (const pe of (s.parseErrors ?? []).slice(0, 1)) add('safety', 'critical', 60, `This file does not parse: ${pe.message}`, pe.line);

  // ---- Hygiene ----
  for (const t of m.todos.slice(0, 4)) add('hygiene', 'minor', 3, `${t.tag} left at line ${t.line}${t.text ? `: “${t.text}”` : ''}. Track it or fix it — comments aren't a backlog.`, t.line);
  if (m.todos.length > 4) add('hygiene', 'minor', 4, `${m.todos.length} TODO/FIXME markers in one file — this is a backlog hiding in comments.`);
  const dbg = s.debugLogs ?? [];
  if (dbg.length > 3) add('hygiene', 'minor', 6, `${plural(dbg.length, 'debug print')} left in. Move to a real logger or delete them.`, dbg[0]);
  else for (const line of dbg.slice(0, 2)) add('hygiene', 'minor', 2, `Stray debug print. Delete it or route it through a logger.`, line);
  for (const b of m.commentedOutBlocks.slice(0, 3)) add('hygiene', 'minor', 4, `${b.length} lines of commented-out code. Version control remembers — delete it.`, b.line);
  if (m.longLines.length > 8) add('hygiene', 'minor', 4, `${m.longLines.length} lines exceed 160 characters. Wrap them — horizontal scrolling hides bugs.`, m.longLines[0]);
  // An import that binds a name the file never uses again is dead weight: it
  // misreports the file's real dependencies and slows every reader tracing them.
  // Scaled like the other hygiene rules — a stray one is minor, sprawl reads worse.
  const unusedImports = s.unusedImports ?? [];
  const unusedNames = unusedImports.flatMap((u) => u.names);
  if (unusedNames.length > 3) add('hygiene', 'minor', 6, `${plural(unusedNames.length, 'unused import')} (${unusedNames.slice(0, 3).map((n) => `\`${n}\``).join(', ')}, …) — none are referenced anywhere in this file. Delete them; the import list should state what this file actually depends on.`, unusedImports[0].line);
  else for (const u of unusedImports.slice(0, 3)) add('hygiene', 'minor', 2, `${u.names.map((n) => `\`${n}\``).join(', ')} ${u.names.length === 1 ? 'is imported but never' : 'are imported but never'} used in this file. Delete the import.`, u.line);

  // ---- Coupling ----
  const internal = imports.filter((i) => !i.external);
  const broken = internal.filter((i) => !i.resolved);
  for (const b of broken.slice(0, 3)) add('coupling', 'critical', 15, `Import of \`${b.spec}\` doesn't resolve to any file — this wire is broken. Dead code or a missing file.`, b.line);
  if (broken.length > 3) add('coupling', 'major', 8, `${broken.length - 3} more unresolved imports beyond the ones above.`, broken[3].line);
  const fanOut = new Set(internal.filter((i) => i.resolved).map((i) => i.resolved)).size;
  if (fanOut > 20) add('coupling', 'major', 12, `${fanOut} internal dependencies — this module knows about too much of the codebase. High blast radius on change.`);
  else if (fanOut > 12) add('coupling', 'minor', 6, `${fanOut} internal dependencies. Consider whether this module has one job.`);
  const externals = new Set(imports.filter((i) => i.external).map((i) => i.spec.split('/')[0])).size;
  if (externals > 15) add('coupling', 'minor', 4, `${externals} external packages imported by one file — heavy surface area.`);

  // ---- Docs ----
  const docs = m.docs ?? { publicSymbols: 0, documented: 0 };
  if (docs.publicSymbols >= 3) {
    const ratio = docs.documented / docs.publicSymbols;
    if (ratio < 0.2) add('docs', 'minor', 25, `${docs.documented} of ${docs.publicSymbols} public symbols documented. The public surface is where docs pay for themselves.`);
    else if (ratio < 0.5) add('docs', 'minor', 12, `Only ${docs.documented} of ${docs.publicSymbols} public symbols carry docs.`);
  }
  // Commented-out code doesn't count as documentation — deleting it (which the
  // hygiene rule asks for) must never lower the docs score.
  const proseComments = Math.max(0, m.commentLines - (m.commentedOutLines ?? 0));
  if (m.loc > 200 && proseComments / (m.loc + proseComments) < 0.02) {
    add('docs', 'info', 8, `${m.loc} lines with almost no comments. The next reader gets no map of the non-obvious parts.`);
  }

  // ---- Score the dimensions ----
  const dims = {};
  for (const key of Object.keys(DIMENSIONS)) {
    const deducted = findings.filter((f) => f.dim === key).reduce((sum, f) => sum + f.points, 0);
    dims[key] = Math.max(0, Math.round(100 - Math.min(100, deducted)));
  }
  const parseFailed = (s.parseErrors ?? []).length > 0;
  const score = computeScore(dims, findings, parseFailed);
  return { score, grade: letterFor(score), dimensions: dims, findings, parseFailed };
}

// Weighted dimensions + severity compounding: a senior engineer doesn't
// average away critical problems — each critical/major drags the whole grade,
// on top of its dimension. A file that doesn't parse cannot grade above F.
function computeScore(dims, findings, parseFailed) {
  let score = 0;
  for (const [key, { weight }] of Object.entries(DIMENSIONS)) score += dims[key] * weight;
  const criticals = findings.filter((f) => f.severity === 'critical').length;
  const majors = findings.filter((f) => f.severity === 'major').length;
  score -= Math.min(35, criticals * 5 + majors * 2);
  if (parseFailed) score = Math.min(score, 25);
  return Math.max(0, Math.round(score * 10) / 10);
}

// A cycle's cost scales with how many files are trapped in it: breaking a mutual
// import is an afternoon, untangling a 12-file knot is a project. Points scale
// within tiers (like the loc/nesting rules) so one extra file never moves a full
// letter grade, and a tangle past 5 files reads as critical — at that size no
// member can be read, tested, or moved on its own.
function cyclePenalty(size) {
  if (size > 5) return { severity: 'critical', points: Math.min(30, 16 + Math.round((size - 6) * 1.5)) };
  return { severity: 'major', points: 10 + (size - 2) * 2 };
}

function cycleAdvice(size) {
  if (size > 5) return `A knot this size can't be untangled file-by-file — find the one dependency that closes the loop (usually a shared type or a back-reference to a parent) and lift it into its own module.`;
  return `Cycles make modules impossible to reason about in isolation — break the loop.`;
}

// Post-pass findings that need whole-graph context (cycles, churn hotspots,
// blast radius). Cycle penalty applies first; the churn and fan-in gates both
// read the post-cycle score.
export function applyGraphFindings(node, { cyclePeers, churn, fanIn }) {
  let current = node;
  if (cyclePeers?.length) {
    const preview = cyclePeers.slice(0, 3).map((p) => p.split('/').pop()).join(' → ');
    const size = cyclePeers.length + 1;
    current = withExtra(current, { dim: 'coupling', ...cyclePenalty(size), msg: `Part of a ${size}-file import cycle (${preview}${cyclePeers.length > 3 ? ' → …' : ''}). ${cycleAdvice(size)}` });
  }
  if (churn >= 10 && current.score < 85) {
    current = withExtra(current, { dim: 'structure', severity: 'info', points: 5, msg: `Touched in ${churn} commits over 90 days while grading ${current.grade} — a churn hotspot. This is where refactoring pays off first.` });
  }
  // Blast radius: fan-in is a real graph fact, but being depended upon is NOT a
  // defect — a clean, widely-imported utility is good design, and penalising it
  // would grade the codebase's best modules down. What the rubric flags is the
  // conjunction: a file that many others import AND that grades poorly, where
  // every defect is multiplied by the number of modules exposed to it. Same
  // shape as the churn gate: a prioritisation signal, not a new accusation.
  if (fanIn >= 10 && current.score < 85) {
    current = withExtra(current, { dim: 'coupling', ...blastRadiusPenalty(fanIn), msg: `${fanIn} files import this while it grades ${current.grade} — every defect above is inherited by ${fanIn} dependents. Fix this before any leaf file.` });
  }
  return current;
}

// Scales within tiers like the cycle/loc rules, capped so blast radius sharpens
// the priority order without swamping the defects it is amplifying.
function blastRadiusPenalty(fanIn) {
  if (fanIn > 25) return { severity: 'major', points: Math.min(12, 8 + Math.round((fanIn - 25) / 10)) };
  return { severity: 'info', points: 4 + Math.round(3 * (fanIn - 10) / 15) };
}

// ---- Architecture rules (CI-22) ----
// A user's `.circuit-rules.json` declares FORBIDDEN dependencies between path
// globs. Each violation resolved over the real import graph (lib/rules.js) becomes
// a weighted coupling finding, line-anchored to the offending import. This is a
// genuine graph fact, never a heuristic — zero violations yield zero findings.
export function ruleViolationFinding(v) {
  const { spec, line, rule } = v;
  const label = rule?.name ? `${rule.name}: ` : '';
  return {
    dim: 'coupling',
    severity: rule?.severity ?? 'critical',
    points: rule?.points ?? 20,
    rule: true,
    line,
    msg: `${label}forbidden dependency — this file must not import \`${rule?.to ?? v.target}\` (\`${spec}\`). You declared this boundary off-limits in \`.circuit-rules.json\`; break the wire or move the code.`,
  };
}

// Apply the forbidden-rule violations for one node: each deducts from Coupling and
// drags the grade through the same critical/major compounding as any other finding.
export function applyRuleFindings(node, violations) {
  let current = node;
  for (const v of violations ?? []) current = withExtra(current, ruleViolationFinding(v));
  return current;
}

function withExtra(node, extra) {
  const findings = [...node.findings, extra];
  const dims = { ...node.dimensions };
  dims[extra.dim] = Math.max(0, dims[extra.dim] - extra.points);
  const score = computeScore(dims, findings, node.parseFailed);
  return { ...node, findings, dimensions: dims, score, grade: letterFor(score) };
}
