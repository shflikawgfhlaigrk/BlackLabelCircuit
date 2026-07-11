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
  for (const line of (s.evals ?? []).slice(0, 2)) add('safety', 'critical', 15, `\`eval\`/dynamic code execution — an injection vector and a debugging nightmare. Almost never necessary.`, line);
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

// Post-pass findings that need whole-graph context (cycles, churn hotspots).
// Cycle penalty applies first; the churn hotspot gate reads the post-cycle score.
export function applyGraphFindings(node, { cyclePeers, churn }) {
  let current = node;
  if (cyclePeers?.length) {
    const preview = cyclePeers.slice(0, 3).map((p) => p.split('/').pop()).join(' → ');
    current = withExtra(current, { dim: 'coupling', severity: 'major', points: 10, msg: `Part of an import cycle (${preview}${cyclePeers.length > 3 ? ' → …' : ''}). Cycles make modules impossible to reason about in isolation — break the loop.` });
  }
  if (churn >= 10 && current.score < 85) {
    current = withExtra(current, { dim: 'structure', severity: 'info', points: 5, msg: `Touched in ${churn} commits over 90 days while grading ${current.grade} — a churn hotspot. This is where refactoring pays off first.` });
  }
  return current;
}

function withExtra(node, extra) {
  const findings = [...node.findings, extra];
  const dims = { ...node.dimensions };
  dims[extra.dim] = Math.max(0, dims[extra.dim] - extra.points);
  const score = computeScore(dims, findings, node.parseFailed);
  return { ...node, findings, dimensions: dims, score, grade: letterFor(score) };
}
