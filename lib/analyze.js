// Orchestrator: discover files → parse per language → wire the graph →
// detect cycles → grade every node → aggregate repo stats.
import fs from 'node:fs';
import path from 'node:path';
import { discoverFiles, gitChurn } from './walk.js';
import { analyzeJs } from './lang/javascript.js';
import { analyzePython } from './lang/python.js';
import { analyzeSwift, linkSwiftFiles } from './lang/swift.js';
import { analyzeGo, buildGoContext } from './lang/go.js';
import { analyzeRust } from './lang/rust.js';
import { analyzeJava, buildJavaContext } from './lang/java.js';
import { analyzeKotlin, buildKotlinContext } from './lang/kotlin.js';
import { analyzeRuby } from './lang/ruby.js';
import { analyzeC } from './lang/c.js';
import { analyzeGeneric } from './lang/generic.js';
import { scanSecrets } from './lang/common.js';
import { gradeFile, applyGraphFindings, applyRuleFindings, letterFor, DIMENSIONS } from './grade.js';
import { loadRules, findViolations, RULES_FILE } from './rules.js';

// Tarjan strongly-connected components over adjacency map. Iterative (no recursion limit).
export function stronglyConnected(adj) {
  const index = new Map(), low = new Map(), onStack = new Set();
  const stack = [], sccs = [];
  let counter = 0;
  for (const start of adj.keys()) {
    if (index.has(start)) continue;
    const work = [[start, 0]];
    while (work.length) {
      const frame = work[work.length - 1];
      const [v] = frame;
      if (frame[1] === 0) {
        index.set(v, counter); low.set(v, counter); counter++;
        stack.push(v); onStack.add(v);
      }
      const neighbors = adj.get(v) ?? [];
      let advanced = false;
      while (frame[1] < neighbors.length) {
        const w = neighbors[frame[1]++];
        if (!adj.has(w)) continue;
        if (!index.has(w)) { work.push([w, 0]); advanced = true; break; }
        if (onStack.has(w)) low.set(v, Math.min(low.get(v), index.get(w)));
      }
      if (advanced) continue;
      if (low.get(v) === index.get(v)) {
        const scc = [];
        let w;
        do { w = stack.pop(); onStack.delete(w); scc.push(w); } while (w !== v);
        if (scc.length > 1) sccs.push(scc);
      }
      work.pop();
      if (work.length) {
        const [parent] = work[work.length - 1];
        low.set(parent, Math.min(low.get(parent), low.get(v)));
      }
    }
  }
  return sccs;
}

export function analyzeRepo(root) {
  const startedAt = Date.now();
  root = path.resolve(root);
  const { files, truncated } = discoverFiles(root);
  // Forbidden-dependency rules (CI-22): a repo-root `.circuit-rules.json`, if present.
  // No file → rules is null and nothing below this line changes.
  const { rules, error: rulesError } = loadRules(root);
  const fileSet = new Set(files.map((f) => f.rel.split(path.sep).join('/')));
  const topPackages = new Set(
    [...fileSet].filter((f) => f.endsWith('/__init__.py')).map((f) => f.split('/')[0])
  );
  // Deep-parser resolution contexts (built once): Go module map, Java FQN map.
  const goCtx = buildGoContext(root, files);
  const javaCtx = buildJavaContext(root, files);
  const kotlinCtx = buildKotlinContext(root, files);

  const parsed = [];        // {rel, lang, bytes, result}
  const swiftResults = [];
  let skipped = 0;          // discovered files we could not read/grade (unreadable or binary)
  for (const f of files) {
    let content;
    try { content = fs.readFileSync(f.abs, 'utf8'); } catch { skipped++; continue; }
    if (content.includes('\0')) { skipped++; continue; } // binary masquerading as text
    // Normalize line endings so parsing is identical regardless of the source
    // OS. Windows checkouts (or any CRLF-authored repo) otherwise leave a
    // trailing \r that breaks anchored line regexes — e.g. `import` extraction.
    content = content.replace(/\r\n?/g, '\n');
    const rel = f.rel.split(path.sep).join('/');
    let result;
    try {
      if (f.lang === 'javascript' || f.lang === 'typescript') result = analyzeJs(rel, content, f.lang, fileSet);
      else if (f.lang === 'python') result = analyzePython(rel, content, f.lang, fileSet, topPackages);
      else if (f.lang === 'swift') { result = analyzeSwift(rel, content); swiftResults.push({ rel, result }); }
      else if (f.lang === 'go') result = analyzeGo(rel, content, f.lang, fileSet, goCtx);
      else if (f.lang === 'rust') result = analyzeRust(rel, content, f.lang, fileSet);
      else if (f.lang === 'java') result = analyzeJava(rel, content, f.lang, fileSet, javaCtx);
      else if (f.lang === 'kotlin') result = analyzeKotlin(rel, content, f.lang, fileSet, kotlinCtx);
      else if (f.lang === 'ruby') result = analyzeRuby(rel, content, f.lang, fileSet);
      else if (f.lang === 'c' || f.lang === 'cpp') result = analyzeC(rel, content, f.lang, fileSet);
      else result = analyzeGeneric(rel, content, f.lang);
    } catch (e) {
      result = { metrics: { lines: 0, loc: 0, commentLines: 0, todos: [], longLines: [], branchCount: 0, maxNesting: 0, maxNestingLine: 1, commentedOutBlocks: [], functions: [] }, imports: [], signals: {}, decls: [], error: String(e) };
    }
    // Cross-language credential scan over RAW content (string values are blanked
    // in the per-language cleaned view, so this can only run here). Merged into
    // the file's signals so grade.js treats it like any other safety signal.
    try {
      const secrets = scanSecrets(content);
      if (secrets.length) {
        result.signals = result.signals ?? {};
        result.signals.hardcodedSecrets = secrets;
      }
    } catch { /* never let a secret scan break the analysis */ }
    parsed.push({ rel, lang: f.lang, bytes: f.bytes, result });
  }

  // ---- Wire the graph ----
  const links = [];
  const phantoms = new Map(); // phantom node id → display spec
  const resolvedEdgeMap = new Map(); // "source→target" → {source,target,spec,line} for rule checks
  for (const p of parsed) {
    for (const imp of p.result.imports ?? []) {
      if (imp.external) continue;
      if (imp.resolved) {
        if (imp.resolved !== p.rel) {
          links.push({ source: p.rel, target: imp.resolved, kind: 'import', count: 1, broken: false });
          const k = `${p.rel}→${imp.resolved}`;
          // Keep the first import occurrence so the finding anchors to its line.
          if (!resolvedEdgeMap.has(k)) resolvedEdgeMap.set(k, { source: p.rel, target: imp.resolved, spec: imp.spec, line: imp.line });
        }
      } else {
        // Key phantoms by the normalized target (or importer dir + spec) so two
        // files missing "./util.js" in different directories stay distinct.
        const dir = p.rel.includes('/') ? p.rel.slice(0, p.rel.lastIndexOf('/')) : '.';
        const id = `missing:${imp.target ?? `${dir}::${imp.spec}`}`;
        phantoms.set(id, imp.spec);
        links.push({ source: p.rel, target: id, kind: 'import', count: 1, broken: true });
      }
    }
  }
  const swiftLinkResult = linkSwiftFiles(swiftResults);
  for (const l of swiftLinkResult.links) links.push({ ...l, broken: false });

  // Merge duplicate links (same source→target)
  const linkMap = new Map();
  for (const l of links) {
    const key = `${l.source}→${l.target}`;
    const existing = linkMap.get(key);
    if (existing) existing.count += l.count;
    else linkMap.set(key, { ...l });
  }
  const mergedLinks = [...linkMap.values()];

  // ---- Architecture-rule violations (CI-22) ----
  // Resolve forbidden-dependency rules over the real import edges. Each violation
  // marks its edge red in the payload and attaches a coupling finding to the source
  // node during grading. Zero rules / zero matches → no edges marked, no findings.
  const violations = findViolations([...resolvedEdgeMap.values()], rules);
  const violationsBySource = new Map();
  const violationEdgeKeys = new Set();
  for (const v of violations) {
    if (!violationsBySource.has(v.source)) violationsBySource.set(v.source, []);
    violationsBySource.get(v.source).push(v);
    violationEdgeKeys.add(`${v.source}→${v.target}`);
  }
  for (const l of mergedLinks) {
    if (violationEdgeKeys.has(`${l.source}→${l.target}`)) l.ruleViolation = true;
  }

  // ---- Cycles (imports only; swift typerefs are too heuristic for cycle blame) ----
  const adj = new Map();
  for (const p of parsed) adj.set(p.rel, []);
  for (const l of mergedLinks) {
    if (l.kind === 'import' && !l.broken && adj.has(l.source)) adj.get(l.source).push(l.target);
  }
  const sccs = stronglyConnected(adj);
  const cycleOf = new Map();
  for (const scc of sccs) for (const member of scc) cycleOf.set(member, scc);

  // ---- Degrees ----
  const fanIn = new Map(), fanOut = new Map();
  for (const l of mergedLinks) {
    fanOut.set(l.source, (fanOut.get(l.source) ?? 0) + 1);
    fanIn.set(l.target, (fanIn.get(l.target) ?? 0) + 1);
  }

  // ---- Grade ----
  const churn = gitChurn(root);
  const nodes = [];
  let parseErrors = 0;      // files the analyzer could discover but not parse (roll-up of per-file parse findings)
  for (const p of parsed) {
    const graded = gradeFile({ metrics: p.result.metrics, signals: p.result.signals, imports: p.result.imports, lang: p.lang });
    // A per-file parse finding is either a language parser reporting a syntax
    // error (graded.parseFailed) or the parser itself throwing (result.error).
    if (graded.parseFailed || p.result.error) parseErrors++;
    const dir = p.rel.includes('/') ? p.rel.slice(0, p.rel.lastIndexOf('/')) : '.';
    let node = {
      id: p.rel,
      label: p.rel.split('/').pop(),
      dir,
      lang: p.lang,
      loc: p.result.metrics.loc,
      lines: p.result.metrics.lines,
      fanIn: fanIn.get(p.rel) ?? 0,
      fanOut: fanOut.get(p.rel) ?? 0,
      churn: churn.get(p.rel) ?? 0,
      missing: false,
      inCycle: cycleOf.has(p.rel),
      externals: [...new Set((p.result.imports ?? []).filter((i) => i.external).map((i) => i.spec))].slice(0, 40),
      functions: p.result.metrics.functions.slice(0, 100),
      ...graded,
    };
    node = applyGraphFindings(node, {
      cyclePeers: cycleOf.get(p.rel)?.filter((m) => m !== p.rel),
      churn: node.churn,
      fanIn: node.fanIn,
    });
    node = applyRuleFindings(node, violationsBySource.get(p.rel));
    nodes.push(node);
  }
  for (const [id, spec] of phantoms) {
    nodes.push({
      id, label: spec, dir: '∅ missing', lang: 'missing', loc: 0, lines: 0,
      fanIn: fanIn.get(id) ?? 0, fanOut: 0, churn: 0, missing: true, inCycle: false,
      externals: [], functions: [], score: 0, grade: 'F',
      dimensions: Object.fromEntries(Object.keys(DIMENSIONS).map((k) => [k, 0])),
      findings: [{ dim: 'coupling', severity: 'critical', points: 100, msg: `\`${spec}\` is imported but no such file exists. Every wire into this node is broken.` }],
    });
  }

  // ---- Aggregate ----
  const real = nodes.filter((n) => !n.missing);
  const totalLoc = real.reduce((sum, n) => sum + n.loc, 0);
  const brokenEdges = mergedLinks.filter((l) => l.broken).length;
  // Honesty: a folder with no source Circuit can grade is NOT an "A+". Minting a
  // 100/A+ over an empty graph reads as a fabricated score (§5.1) and is the
  // classic "pointed it at the wrong folder" first impression. Report emptiness
  // as emptiness — score/grade are null and the UI shows a "no code found" state.
  const empty = real.length === 0;
  let repoScore = null;
  let grade = null;
  if (!empty) {
    repoScore = totalLoc > 0
      ? real.reduce((sum, n) => sum + n.score * n.loc, 0) / totalLoc
      : 100;
    repoScore = Math.max(0, repoScore - Math.min(10, brokenEdges * 0.75));
    repoScore = Math.round(repoScore * 10) / 10;
    grade = letterFor(repoScore);
  }

  const byGrade = {};
  for (const n of real) {
    const bucket = n.grade[0];
    byGrade[bucket] = (byGrade[bucket] ?? 0) + 1;
  }
  const languages = {};
  for (const n of real) languages[n.lang] = (languages[n.lang] ?? 0) + 1;

  return {
    root,
    name: path.basename(root),
    generatedAt: Date.now(),
    tookMs: Date.now() - startedAt,
    truncated,
    stats: {
      files: real.length,
      loc: totalLoc,
      edges: mergedLinks.length,
      brokenEdges,
      cycles: sccs.length,
      empty,
      score: repoScore,
      grade,
      byGrade,
      languages,
      duplicateTypes: swiftLinkResult.duplicateDecls.length,
      // Honesty roll-ups (H3): surface what the analysis could NOT fully cover so
      // a grade is never silently computed over a partial view of the repo.
      parseErrors,
      skipped,
      // Architecture rules (CI-22): only present when the repo ships a usable
      // `.circuit-rules.json`, so a repo without rules keeps today's exact shape.
      ...(rules ? { rules: { file: RULES_FILE, count: rules.forbidden.length, violations: violations.length } } : {}),
      ...(rulesError ? { rulesError } : {}),
    },
    nodes,
    links: mergedLinks,
  };
}
