// Pure mapping from Circuit's real grading output → LSP diagnostics. This is the
// contract between the analyzer (lib/analyze.js → gradeFile findings) and any
// editor client. It computes nothing itself and invents no findings — every
// diagnostic is a genuine finding from `analyzeRepo`, carrying its dimension,
// severity and point deduction. Kept dependency-free and side-effect-free so it
// can be unit-tested in isolation and reused by the stdio LSP server.

// LSP DiagnosticSeverity: 1 Error · 2 Warning · 3 Information · 4 Hint.
// Circuit severities map so a critical is a red squiggle, an info is a hint.
export const LSP_SEVERITY = { critical: 1, major: 2, minor: 3, info: 4 };

// LSP ranges are 0-based; findings are 1-based lines (some carry no line — a
// file-level finding anchors to the first line). We span the whole line so the
// squiggle is visible; the editor clamps the end column to the real line length.
const EOL_COL = 2 ** 31 - 1;

export function findingToDiagnostic(f) {
  const line = Math.max(0, (Number(f.line) || 1) - 1);
  const points = Number(f.points) || 0;
  return {
    range: {
      start: { line, character: 0 },
      end: { line, character: EOL_COL },
    },
    severity: LSP_SEVERITY[f.severity] ?? 3,
    source: 'circuit',
    code: f.dim,
    // Dimension + severity + points are all carried, per the finding contract.
    message: `${f.dim} · ${f.severity} · −${points} pts — ${f.msg}`,
  };
}

// All diagnostics for one graded node (file). A missing/phantom node or a node
// with no findings yields an empty array — an editor should clear its squiggles.
export function nodeToDiagnostics(node) {
  if (!node || !Array.isArray(node.findings)) return [];
  return node.findings.map(findingToDiagnostic);
}

// The status-bar summary for the whole repo. Honest about an empty repo: an
// ungradeable tree has no grade, never a fabricated A+.
export function repoStatus(graph) {
  if (!graph || !graph.stats) return 'Circuit: —';
  const s = graph.stats;
  if (s.empty || s.grade == null) return 'Circuit: no gradeable source';
  return `Circuit: ${s.grade} (${s.score})`;
}

// Find the graded node for a repo-relative (POSIX) path in an analyzeRepo graph.
export function nodeForRel(graph, rel) {
  if (!graph || !Array.isArray(graph.nodes)) return null;
  return graph.nodes.find((n) => !n.missing && n.id === rel) ?? null;
}
