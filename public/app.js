// Circuit UI — 3D force graph of the codebase, graded and wired.
import { ForceGraph3D, SpriteText, THREE, UnrealBloomPass } from '/vendor/circuit-3d.bundle.mjs';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// ---------- grade colors (validated ramp: monotonic lightness on dark) ----------
const GRADE_COLORS = { A: '#86efac', B: '#a3e635', C: '#eab308', D: '#fb923c', F: '#f87171' };
const BROKEN = '#ff3355';
// Forbidden-dependency edges (CI-22): a solid red wire, distinct in hue from a
// broken wire but unmistakably "this crossing is not allowed".
const RULE_VIOLATION = '#ff2d78';
const DIM_NODE = '#1c2431';
// Windows port overlay: ready → green, Mac-only parts skipped → amber, needs a
// Windows part first → by the kind of part (screens pink, system services red,
// packages / commands / paths orange).
const PORT_COLORS = { ready: '#86efac', guarded: '#fbbf24', ui: '#f472b6', system: '#f87171', other: '#fb923c' };
const PORT_KIND_RANK = { ui: 3, system: 2, package: 1, unix: 1, command: 1, path: 1 };
// Convert overlay: what the conversion did with each file, as judged by the compiler.
const CONVERT_COLORS = { portable: '#86efac', converted: '#38bdf8', partial: '#fbbf24', 'needs-windows-part': '#f472b6', 'mac-only-skipped': '#fb923c', unverified: '#94a3b8', 'rewritten-unverified': '#94a3b8' };
// Stops aligned to letter boundaries: A≈green, B≈lime, C≈yellow, D≈orange, F≈red.
const SCORE_STOPS = [
  [100, [134, 239, 172]], [95, [134, 239, 172]], [84, [163, 230, 53]], [74, [234, 179, 8]],
  [63, [251, 146, 60]], [50, [248, 113, 113]], [0, [225, 29, 78]],
];
function scoreColor(score) {
  for (let i = 0; i < SCORE_STOPS.length - 1; i++) {
    const [s1, c1] = SCORE_STOPS[i], [s2, c2] = SCORE_STOPS[i + 1];
    if (score >= s2) {
      const t = s1 === s2 ? 0 : (s1 - score) / (s1 - s2);
      const mix = c1.map((v, k) => Math.round(v + (c2[k] - v) * t));
      return `rgb(${mix[0]},${mix[1]},${mix[2]})`;
    }
  }
  return `rgb(225,29,78)`;
}
const gradeColor = (grade) => GRADE_COLORS[grade?.[0]] ?? BROKEN;

// ---------- state ----------
// Respect the OS "reduce motion" setting: users who ask for calm start with the
// ambient flow particles off (broken-wiring + focused links still animate — that
// motion is signal, not decoration). The Flow toggle stays for everyone.
const prefersReducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
const state = {
  data: null,
  filters: { grades: new Set(['A', 'B', 'C', 'D', 'F']), langs: new Set(), brokenOnly: false },
  allLangs: [],
  selected: null,
  hover: null,
  labelsOn: true,
  flowOn: !prefersReducedMotion,
  is2d: false,
  topLabelIds: new Set(),
  adjacency: new Map(), // id → Set of neighbor ids
  // Grade-over-history replay (CI-20): when `on`, nodes recolor to `frame`'s
  // per-commit grades instead of the live HEAD grade.
  replay: { on: false, loading: false, data: null, idx: 0, frame: null, playing: false, timer: null },
  // Windows port overlay: when `on`, nodes recolor by whether the file runs on Windows as-is.
  port: { on: false, loading: false, data: null, byId: new Map() },
  // Convert: the last conversion result; when `on`, nodes recolor by its per-file verdict.
  convert: { on: false, running: false, result: null, byId: new Map() },
};

// ---------- graph setup ----------
const graphEl = $('graph');
const Graph = new ForceGraph3D(graphEl, { controlType: 'orbit' });

Graph
  .backgroundColor('#05070d')
  .nodeResolution(16)
  .nodeOpacity(0.92)
  .nodeVal((n) => (n.missing ? 3 : Math.min(42, 4 + n.loc / 25)))
  .nodeColor(nodeColorFn)
  .nodeLabel(tooltipHtml)
  .nodeThreeObjectExtend((n) => !n.missing)
  .nodeThreeObject(nodeObjectFn)
  .linkColor(linkColorFn)
  .linkOpacity(0.4)
  .linkWidth(linkWidthFn)
  .linkDirectionalParticles(particlesFn)
  .linkDirectionalParticleWidth(1.8)
  .linkDirectionalParticleSpeed((l) => (l.broken || l.ruleViolation ? 0.012 : 0.006))
  .linkDirectionalParticleColor((l) => (l.broken ? BROKEN : l.ruleViolation ? RULE_VIOLATION : '#6ea8d8'))
  .onNodeHover((n) => { state.hover = n ?? null; graphEl.style.cursor = n ? 'pointer' : ''; refreshStyles(); })
  .onNodeClick((n) => selectNode(n, true))
  .onBackgroundClick(() => { if (state.selected) { state.selected = null; hidePanel(); refreshStyles(); } });

Graph.d3Force('charge').strength(-140);
Graph.d3Force('link').distance((l) => (l.kind === 'import' ? 55 : 75));

// Bloom — the "better than Obsidian" glow. Dense graphs get less of it.
const bloom = new UnrealBloomPass(new THREE.Vector2(graphEl.clientWidth, graphEl.clientHeight), 0.9, 0.55, 0.12);
Graph.postProcessingComposer().addPass(bloom);
function tuneBloom(nodeCount) {
  bloom.strength = nodeCount > 800 ? 0.45 : nodeCount > 300 ? 0.65 : 0.9;
}

// Re-frame once the layout settles after a fresh load or a 2D/3D switch:
// fly back to the selection if there is one, otherwise fit the whole graph.
let needsFit = true;
Graph.onEngineStop(() => {
  if (needsFit) {
    needsFit = false;
    if (state.selected) selectNode(state.selected, true);
    else Graph.zoomToFit(800, 60);
  }
});

// Starfield backdrop.
{
  const positions = new Float32Array(900 * 3);
  for (let i = 0; i < 900; i++) {
    const r = 2200 + Math.random() * 2200;
    const theta = Math.random() * Math.PI * 2;
    const phi = Math.acos(2 * Math.random() - 1);
    positions[i * 3] = r * Math.sin(phi) * Math.cos(theta);
    positions[i * 3 + 1] = r * Math.sin(phi) * Math.sin(theta);
    positions[i * 3 + 2] = r * Math.cos(phi);
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  const stars = new THREE.Points(geo, new THREE.PointsMaterial({ color: 0x44506a, size: 1.6, transparent: true, opacity: 0.7, sizeAttenuation: false }));
  Graph.scene().add(stars);
}

// Pause rendering when the tab is hidden — no background CPU burn.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) Graph.pauseAnimation();
  else Graph.resumeAnimation();
});
window.addEventListener('resize', () => Graph.width(graphEl.clientWidth).height(graphEl.clientHeight));

// ---------- accessors ----------
function activeNeighborhood() {
  const focus = state.selected ?? state.hover;
  if (!focus) return null;
  const set = new Set([focus.id]);
  for (const nb of state.adjacency.get(focus.id) ?? []) set.add(nb);
  return set;
}

function nodeColorFn(n) {
  const hood = activeNeighborhood();
  if (hood && !hood.has(n.id)) return DIM_NODE;
  if (n.missing) return BROKEN;
  // In replay, a node's color is its grade AT THE SELECTED COMMIT. A file that
  // didn't exist yet (or was deleted) at that commit has no grade in the frame —
  // it dims, honestly showing it wasn't part of that snapshot.
  if (state.replay.on && state.replay.frame) {
    const g = state.replay.frame.nodes[n.id];
    return g ? scoreColor(g.score) : DIM_NODE;
  }
  if (state.convert.on && state.convert.result) {
    const c = state.convert.byId.get(n.id);
    return c ? (CONVERT_COLORS[c.status] ?? DIM_NODE) : DIM_NODE;
  }
  if (state.port.on && state.port.data) return portColor(state.port.byId.get(n.id));
  return scoreColor(n.score);
}

function convertLine(n) {
  if (!state.convert.on || !state.convert.result) return '';
  const c = state.convert.byId.get(n.id);
  if (!c) return `<div class="tt-line">Convert: not part of the converted app code</div>`;
  const text = c.status === 'portable' ? 'Convert: builds for Windows unchanged'
    : c.status === 'converted' ? `Convert: converted, builds for Windows (${esc([...new Set(c.changes.map((x) => x.module ?? x.hit).filter(Boolean))].slice(0, 4).join(', '))})`
      : c.status === 'partial' ? `Convert: builds for Windows; ${c.isolatedLoc} of ${c.loc} lines kept for the Mac`
        : c.status === 'needs-windows-part' ? `Convert: needs a Windows part — ${esc((c.guardedModules ?? []).slice(0, 4).join(', ') || 'uses isolated code')}`
          : c.status === 'mac-only-skipped' ? 'Convert: Mac-only parts skipped on Windows'
            : 'Convert: rewritten, not verified by a compiler';
  const why = c.errors?.[0] ? `<div class="tt-line muted">${esc(c.errors[0].slice(0, 120))}</div>` : '';
  return `<div class="tt-line" style="color:${CONVERT_COLORS[c.status] ?? '#94a3b8'}">${text}</div>${why}`;
}

function portColor(p) {
  if (!p) return DIM_NODE; // not source code the port check reads (docs, data, config)
  if (p.status === 'ready') return PORT_COLORS.ready;
  if (p.status === 'guarded') return PORT_COLORS.guarded;
  const worst = worstPortKind(p);
  return worst === 'ui' ? PORT_COLORS.ui : worst === 'system' ? PORT_COLORS.system : PORT_COLORS.other;
}

function worstPortKind(p) {
  let worst = null;
  for (const h of p.hits) {
    if (h.guarded) continue;
    if (!worst || (PORT_KIND_RANK[h.kind] ?? 0) > (PORT_KIND_RANK[worst] ?? 0)) worst = h.kind;
  }
  return worst;
}

function portLine(n) {
  if (!state.port.on || !state.port.data) return '';
  const p = state.port.byId.get(n.id);
  if (!p) return `<div class="tt-line">Windows: not source code</div>`;
  const ids = (guarded) => [...new Set(p.hits.filter((h) => h.guarded === guarded).map((h) => h.id))].slice(0, 4).join(', ');
  const text = p.status === 'ready'
    ? (p.handled ? 'Windows: runs as-is (has a Windows branch)' : 'Windows: runs as-is')
    : p.status === 'guarded'
      ? `Windows: builds, skips Mac-only ${esc(ids(true))}`
      : `Windows: needs ${esc(ids(false))}`;
  return `<div class="tt-line" style="color:${portColor(p)}">${text}</div>`;
}

function linkTouchesFocus(l) {
  const focus = state.selected ?? state.hover;
  if (!focus) return false;
  const sid = l.source.id ?? l.source, tid = l.target.id ?? l.target;
  return sid === focus.id || tid === focus.id;
}

function linkColorFn(l) {
  if (l.broken) return BROKEN;
  if (l.ruleViolation) return RULE_VIOLATION;
  const hood = activeNeighborhood();
  if (hood) return linkTouchesFocus(l) ? '#9ed4ff' : 'rgba(40,52,70,0.5)';
  return 'rgba(110,135,175,0.55)';
}

function linkWidthFn(l) {
  // A forbidden crossing is always drawn solid — it must read at a glance, not
  // only when its endpoints are focused.
  return (l.ruleViolation || linkTouchesFocus(l)) ? 1.6 : 0;
}

function particlesFn(l) {
  if (l.broken || l.ruleViolation) return 4;
  if (linkTouchesFocus(l)) return 3;
  if (state.flowOn && (state.data?.links.length ?? 0) < 1800) return 1;
  return 0;
}

function nodeObjectFn(n) {
  if (n.missing) {
    const mesh = new THREE.Mesh(
      new THREE.OctahedronGeometry(7),
      new THREE.MeshBasicMaterial({ color: BROKEN, wireframe: true })
    );
    return mesh;
  }
  if (state.labelsOn && state.topLabelIds.has(n.id)) {
    const sprite = new SpriteText(n.label);
    sprite.color = '#7e8da6';
    sprite.textHeight = 4.5;
    sprite.fontFace = 'ui-monospace, Menlo, monospace';
    const radius = Math.cbrt(Math.min(42, 4 + n.loc / 25)) * 4; // mirror nodeVal→radius
    sprite.position.set(0, -(radius + 6), 0);
    return sprite;
  }
  return undefined;
}

function tooltipHtml(n) {
  if (n.missing) {
    return `<div><span class="tt-grade" style="color:${BROKEN}">MISSING</span></div>
      <div class="tt-path">${esc(n.label)}</div>
      <div class="tt-line">${n.fanIn} broken wire${n.fanIn === 1 ? '' : 's'} point here</div>`;
  }
  const findings = n.findings.length;
  return `<div><span class="tt-grade" style="color:${gradeColor(n.grade)}">${n.grade}</span>
      <span style="color:#9aa7bd"> ${n.score}</span></div>
    <div class="tt-path">${esc(n.id)}</div>
    <div class="tt-line">${n.loc} loc · ${n.fanIn}↚ ${n.fanOut}↛ · ${findings === 0 ? 'clean' : findings + ' finding' + (findings === 1 ? '' : 's')}</div>${portLine(n)}${convertLine(n)}`;
}

function refreshStyles() {
  Graph.nodeColor(Graph.nodeColor());
  Graph.linkColor(Graph.linkColor());
  Graph.linkWidth(Graph.linkWidth());
  Graph.linkDirectionalParticles(Graph.linkDirectionalParticles());
}

// ---------- graph state overlay (analyzing / no-code-found) ----------
function showOverlay(mode, opts = {}) {
  const el = $('graphOverlay');
  el.classList.remove('hidden', 'analyzing', 'empty');
  el.classList.add(mode);
  const actions = $('goActions');
  if (mode === 'analyzing') {
    $('goTitle').textContent = opts.name ? `Analyzing ${opts.name}…` : 'Analyzing your codebase…';
    $('goBody').innerHTML = 'Reading and grading every source file. A large repository can take a few seconds — this view updates the moment it’s ready.';
    actions.classList.add('hidden');
  } else if (mode === 'empty') {
    $('goTitle').textContent = 'No source code found here';
    $('goBody').innerHTML = `Circuit didn’t find any files it can grade in <b>${esc(opts.name ?? 'this folder')}</b>. It reads source code — JavaScript/TypeScript, Python, Swift, Go, Rust, Java, Kotlin, Ruby, C/C++ and more — so point it at the root of a code repository.`;
    actions.classList.remove('hidden');
  }
}
function hideOverlay() { $('graphOverlay').classList.add('hidden'); }

// ---------- data ----------
async function loadGraph(preservePositions = false) {
  let res;
  try { res = await fetch('/api/graph'); }
  catch { if (!state.data) showOverlay('analyzing'); setTimeout(() => loadGraph(preservePositions), 800); return; }
  if (!res.ok) {
    if (!state.data) showOverlay('analyzing'); // first scan still running — show feedback, don't leave it blank
    setTimeout(() => loadGraph(preservePositions), 800);
    return;
  }
  const data = await res.json();

  if (!preservePositions) needsFit = true;
  if (preservePositions && state.data) {
    const old = new Map(state.data.nodes.map((n) => [n.id, n]));
    for (const n of data.nodes) {
      const prev = old.get(n.id);
      if (prev) { n.x = prev.x; n.y = prev.y; n.z = prev.z; n.vx = prev.vx; n.vy = prev.vy; n.vz = prev.vz; }
    }
  }
  state.data = data;

  // adjacency + top-degree labels
  state.adjacency = new Map();
  for (const l of data.links) {
    const s = l.source.id ?? l.source, t = l.target.id ?? l.target;
    if (!state.adjacency.has(s)) state.adjacency.set(s, new Set());
    if (!state.adjacency.has(t)) state.adjacency.set(t, new Set());
    state.adjacency.get(s).add(t);
    state.adjacency.get(t).add(s);
  }
  const byDegree = [...data.nodes].filter((n) => !n.missing).sort((a, b) => (b.fanIn + b.fanOut) - (a.fanIn + a.fanOut));
  state.topLabelIds = new Set(byDegree.slice(0, 30).map((n) => n.id));
  for (const n of data.nodes) if (n.missing) state.topLabelIds.add(n.id);

  // Language filters: newly-appearing languages are always shown; the user's
  // explicit deselections (langs in prevKnown but not in the filter) persist.
  const prevKnown = new Set(state.allLangs);
  state.allLangs = Object.keys(data.stats.languages).sort((a, b) => data.stats.languages[b] - data.stats.languages[a]);
  if (!prevKnown.size) {
    state.filters.langs = new Set(state.allLangs);
  } else {
    for (const l of state.allLangs) if (!prevKnown.has(l)) state.filters.langs.add(l);
    for (const l of [...state.filters.langs]) if (!state.allLangs.includes(l)) state.filters.langs.delete(l);
  }

  applyData();
  renderSidebar();
  if (data.stats.empty || data.stats.files === 0) showOverlay('empty', { name: data.name });
  else hideOverlay();
  // keep the panel in sync if the selected file still exists
  if (state.selected) {
    const again = data.nodes.find((n) => n.id === state.selected.id);
    if (again) { state.selected = again; renderPanel(again); }
    else { state.selected = null; hidePanel(); }
  }
}

function visibleData() {
  const { grades, langs, brokenOnly } = state.filters;
  const brokenIds = new Set();
  if (brokenOnly) {
    for (const l of state.data.links) {
      if (l.broken) {
        brokenIds.add(l.source.id ?? l.source);
        brokenIds.add(l.target.id ?? l.target);
      }
    }
  }
  const nodes = state.data.nodes.filter((n) => {
    if (n.missing) return true;
    if (!grades.has(n.grade[0])) return false;
    if (!langs.has(n.lang)) return false;
    if (brokenOnly && !brokenIds.has(n.id)) return false;
    return true;
  });
  const ids = new Set(nodes.map((n) => n.id));
  const links = state.data.links.filter((l) => ids.has(l.source.id ?? l.source) && ids.has(l.target.id ?? l.target));
  return { nodes, links };
}

function applyData() {
  const data = visibleData();
  tuneBloom(data.nodes.length);
  Graph.graphData(data);
}

// ---------- selection ----------
function selectNode(n, fly) {
  state.selected = n;
  refreshStyles();
  renderPanel(n);
  $('panel').classList.remove('hidden');
  if (fly && n.x != null) {
    const dist = 200;
    const nz = n.z ?? 0; // 2D mode deletes z — never let NaN reach the camera
    const len = Math.hypot(n.x, n.y, nz) || 1;
    const ratio = 1 + dist / len;
    Graph.cameraPosition(
      { x: n.x * ratio, y: n.y * ratio, z: nz * ratio + (state.is2d ? dist : 0) },
      { x: n.x, y: n.y, z: nz },
      1100
    );
  }
}
function hidePanel() { $('panel').classList.add('hidden'); }

function focusNodeById(id) {
  let n = Graph.graphData().nodes.find((x) => x.id === id);
  if (!n) {
    // The node is filtered out — widen the filters so the focus is visible.
    const hidden = state.data.nodes.find((x) => x.id === id);
    if (!hidden) return;
    state.filters.grades.add(hidden.grade[0]);
    state.filters.langs.add(hidden.lang);
    if (state.filters.brokenOnly) {
      state.filters.brokenOnly = false;
      $('tglBroken').classList.remove('on');
    }
    applyData();
    renderSidebar();
    n = Graph.graphData().nodes.find((x) => x.id === id) ?? hidden;
  }
  selectNode(n, true);
}

// ---------- sidebar ----------
function verdictLine(stats) {
  const { score, brokenEdges, cycles } = stats;
  const crit = state.data.nodes.reduce((sum, n) => sum + (n.missing ? 0 : n.findings.filter((f) => f.severity === 'critical').length), 0);
  if (brokenEdges > 0) return `${brokenEdges} broken wire${brokenEdges === 1 ? '' : 's'}${crit ? `, ${crit} critical finding${crit === 1 ? '' : 's'}` : ''} — fix the red before anything else.`;
  if (score >= 93) return 'Ship it. Clean wiring, tight modules.';
  if (score >= 85) return `Solid. ${crit ? `${crit} critical finding${crit === 1 ? '' : 's'} to clear, then` : 'A refactor pass and'} it's an A.`;
  if (score >= 75) return `Working, but carrying debt${cycles ? ` — ${cycles} import cycle${cycles === 1 ? '' : 's'}` : ''}. Budget a cleanup sprint.`;
  if (score >= 65) return 'This codebase fights back. Start with the worst offenders below.';
  return 'Significant rework needed. Triage by the red nodes.';
}

function renderSidebar() {
  const { stats, name, root } = state.data;
  $('repoName').textContent = name;
  $('repoPath').textContent = root;

  // No gradeable source: never render a grade (the analyzer reports null, not A+).
  if (stats.empty || stats.files === 0) {
    document.title = `Circuit — ${name}`;
    $('statFiles').textContent = '0';
    $('statLoc').textContent = '0';
    $('statEdges').textContent = '0';
    $('statBroken').classList.add('hidden');
    $('statCycles').classList.add('hidden');
    $('statParse').classList.add('hidden');
    $('statTruncated').classList.add('hidden');
    const hero = $('heroGrade');
    hero.textContent = '–';
    hero.style.color = 'var(--ink-3)';
    hero.title = '';
    $('heroScore').textContent = '–';
    $('heroVerdict').textContent = 'No source files to grade in this folder.';
    $('histogram').innerHTML = '';
    $('langChips').innerHTML = '';
    $('worst').innerHTML = '<div class="muted small" style="padding:2px 4px">—</div>';
    return;
  }

  document.title = `Circuit — ${name} (${stats.grade})`;
  $('statFiles').textContent = stats.files.toLocaleString();
  $('statLoc').textContent = stats.loc.toLocaleString();
  $('statEdges').textContent = stats.edges.toLocaleString();
  const brokenBtn = $('statBroken');
  brokenBtn.classList.toggle('hidden', stats.brokenEdges === 0);
  brokenBtn.textContent = `${stats.brokenEdges} broken`;
  const cyc = $('statCycles');
  cyc.classList.toggle('hidden', stats.cycles === 0);
  cyc.textContent = `${stats.cycles} cycle${stats.cycles === 1 ? '' : 's'}`;

  // Honesty (H3): show the reader what grading could NOT cover — files that
  // could not be parsed, and whether the repo was truncated at the file limit —
  // so the headline grade is never mistaken for a full-repo verdict.
  const parse = $('statParse');
  const unparsed = stats.parseErrors ?? 0;
  parse.classList.toggle('hidden', unparsed === 0);
  parse.textContent = `${unparsed} file${unparsed === 1 ? '' : 's'} could not be parsed`;
  const trunc = $('statTruncated');
  trunc.classList.toggle('hidden', !state.data.truncated);
  trunc.textContent = `>4,000 files — truncated`;

  const hero = $('heroGrade');
  hero.textContent = stats.grade;
  hero.style.color = gradeColor(stats.grade);
  hero.title = 'Overall grade — the size-weighted average of every file’s grade, minus a penalty for broken wiring.';
  $('heroScore').textContent = stats.score;
  $('heroVerdict').textContent = verdictLine(stats);

  // histogram
  const counts = { A: 0, B: 0, C: 0, D: 0, F: 0 };
  for (const n of state.data.nodes) if (!n.missing) counts[n.grade[0]]++;
  const max = Math.max(1, ...Object.values(counts));
  $('histogram').innerHTML = Object.entries(counts).map(([g, c]) => `
    <div class="hist-row ${state.filters.grades.has(g) ? '' : 'off'}" data-grade="${g}">
      <span class="hist-letter" style="color:${GRADE_COLORS[g]}">${g}</span>
      <div class="hist-track"><div class="hist-bar" style="width:${(c / max) * 100}%;background:${GRADE_COLORS[g]}"></div></div>
      <span class="hist-count">${c}</span>
    </div>`).join('');
  for (const row of $('histogram').querySelectorAll('.hist-row')) {
    row.onclick = () => {
      const g = row.dataset.grade;
      if (state.filters.grades.has(g)) state.filters.grades.delete(g);
      else state.filters.grades.add(g);
      if (state.filters.grades.size === 0) state.filters.grades = new Set(['A', 'B', 'C', 'D', 'F']);
      applyData(); renderSidebar();
    };
  }

  // language chips
  $('langChips').innerHTML = state.allLangs.map((l) => `
    <button class="chip toggle ${state.filters.langs.has(l) ? 'on' : ''}" data-lang="${esc(l)}">${esc(l)} <span class="muted">${state.data.stats.languages[l]}</span></button>`).join('');
  for (const chip of $('langChips').querySelectorAll('.chip')) {
    chip.onclick = () => {
      const l = chip.dataset.lang;
      if (state.filters.langs.has(l)) state.filters.langs.delete(l);
      else state.filters.langs.add(l);
      if (state.filters.langs.size === 0) state.filters.langs = new Set(state.allLangs);
      applyData(); renderSidebar();
    };
  }

  // worst offenders
  const worst = state.data.nodes
    .filter((n) => !n.missing && n.loc >= 10)
    .sort((a, b) => a.score - b.score)
    .slice(0, 8);
  $('worst').innerHTML = worst.map((n) => `
    <div class="row" data-id="${esc(n.id)}">
      <span class="g" style="color:${gradeColor(n.grade)}">${n.grade}</span>
      <span class="n" title="${esc(n.id)}">${esc(n.label)}</span>
      <span class="s">${n.score}</span>
    </div>`).join('');
  for (const row of $('worst').querySelectorAll('.row')) {
    row.onclick = () => focusNodeById(row.dataset.id);
  }
}

// ---------- report panel ----------
const DIM_LABELS = { complexity: 'Complexity', safety: 'Safety', structure: 'Structure', hygiene: 'Hygiene', coupling: 'Coupling', docs: 'Docs' };
// Plain-language explanation of each dimension (with its weight in the grade),
// surfaced as a hover tooltip so the numbers aren't a mystery.
const DIM_HELP = {
  complexity: 'Complexity (25% of the grade) — nesting depth and branch density: how hard the file is to hold in your head.',
  safety: 'Safety (20%) — swallowed errors, force-unwraps and casts, bare excepts, any-types, @ts-ignore, eval, parse failures.',
  structure: 'Structure (15%) — god files and over-long functions: whether responsibilities are split.',
  hygiene: 'Hygiene (15%) — TODOs, stray debug prints, commented-out code, over-long lines.',
  coupling: 'Coupling (15%) — broken imports, fan-out, and import cycles: how entangled the file is.',
  docs: 'Docs (10%) — documented public symbols and overall comment coverage.',
};
const SEV_ORDER = { critical: 0, major: 1, minor: 2, info: 3 };

function mdCode(msg) {
  return esc(msg).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/“([^”]*)”/g, '<em>“$1”</em>');
}

function renderPanel(n) {
  $('panelName').textContent = n.label;
  $('panelDir').textContent = n.missing ? 'referenced but does not exist' : n.dir === '.' ? '' : n.dir + '/';
  const g = $('panelGrade');
  g.innerHTML = `${n.grade}<span class="sc">${n.score} / 100</span>`;
  g.style.color = n.missing ? BROKEN : gradeColor(n.grade);

  $('panelDims').innerHTML = Object.entries(DIM_LABELS).map(([key, label]) => {
    const v = n.dimensions[key] ?? 0;
    return `<div class="dim-row" title="${esc(DIM_HELP[key] ?? '')}">
      <span class="dim-label">${label}</span>
      <div class="dim-track"><div class="dim-bar" style="width:${v}%;background:${scoreColor(v)}"></div></div>
      <span class="dim-val">${v}</span>
    </div>`;
  }).join('');

  $('panelMeta').innerHTML = n.missing
    ? `<span><b>${n.fanIn}</b> broken wire${n.fanIn === 1 ? '' : 's'} point at this missing file</span>`
    : `<span><b>${n.loc}</b> loc</span>
       <span><b>${n.fanIn}</b> in</span>
       <span><b>${n.fanOut}</b> out</span>
       ${n.churn ? `<span><b>${n.churn}</b> commits/90d</span>` : ''}
       <span>${esc(n.lang)}</span>
       ${n.inCycle ? `<span class="chip warn" style="cursor:default">in cycle</span>` : ''}`;

  const findings = [...n.findings].sort((a, b) => (SEV_ORDER[a.severity] - SEV_ORDER[b.severity]) || (b.points - a.points));
  $('findingCount').textContent = findings.length ? `${findings.length}` : '';
  $('panelFindings').innerHTML = findings.length
    ? findings.map((f) => `
      <div class="finding">
        <span class="sev ${f.severity}">${f.severity}</span>
        <span class="msg">${mdCode(f.msg)}</span>
        ${f.line ? `<span class="ln" data-line="${f.line}">L${f.line}</span>` : ''}
      </div>`).join('')
    : `<div class="all-clear">✓ Nothing to flag. This file would pass review.</div>`;
  for (const ln of $('panelFindings').querySelectorAll('.ln')) {
    ln.onclick = () => openCode(n, Number(ln.dataset.line));
  }

  const links = state.data.links;
  const outs = links.filter((l) => (l.source.id ?? l.source) === n.id);
  const ins = links.filter((l) => (l.target.id ?? l.target) === n.id);
  const nodeById = new Map(state.data.nodes.map((x) => [x.id, x]));
  const wireRow = (id, kind, broken) => {
    const t = nodeById.get(id);
    const color = t ? (t.missing ? BROKEN : scoreColor(t.score)) : '#555';
    return `<div class="row ${broken ? 'broken' : ''}" data-id="${esc(id)}">
      <span class="dot" style="background:${color}"></span>
      <span>${esc(t?.label ?? id)}</span>
      <span class="kind">${broken ? 'BROKEN' : kind}</span>
    </div>`;
  };
  $('outCount').textContent = outs.length ? `(${outs.length})` : '';
  $('inCount').textContent = ins.length ? `(${ins.length})` : '';
  $('wiresOut').innerHTML = outs.length ? outs.map((l) => wireRow(l.target.id ?? l.target, l.kind, l.broken)).join('') : `<div class="muted small" style="padding:2px 6px">none</div>`;
  $('wiresIn').innerHTML = ins.length ? ins.map((l) => wireRow(l.source.id ?? l.source, l.kind, l.broken)).join('') : `<div class="muted small" style="padding:2px 6px">none</div>`;
  for (const row of $('panel').querySelectorAll('.wire-list .row')) {
    row.onclick = () => focusNodeById(row.dataset.id);
  }

  $('externalsSection').classList.toggle('hidden', !n.externals?.length);
  $('panelExternals').innerHTML = (n.externals ?? []).map((e) => `<span class="chip">${esc(e)}</span>`).join('');

  $('viewSourceBtn').classList.toggle('hidden', n.missing);
  $('viewSourceBtn').onclick = () => openCode(n, n.findings.find((f) => f.line)?.line);
}

// ---------- code modal ----------
async function openCode(n, focusLine) {
  const res = await fetch(`/api/file?path=${encodeURIComponent(n.id)}`);
  if (!res.ok) { toast('Could not load file'); return; }
  const text = await res.text();
  const hits = new Map(); // line → severity class
  for (const f of n.findings) {
    if (!f.line) continue;
    const cls = f.severity === 'critical' || f.severity === 'major' ? 'hit' : 'hit-minor';
    if (hits.get(f.line) !== 'hit') hits.set(f.line, cls);
  }
  $('codeTitle').textContent = `${n.id} — grade ${n.grade}`;
  $('codeBody').innerHTML = text.split('\n').map((line, i) => {
    const no = i + 1;
    const cls = hits.get(no) ?? '';
    return `<div class="cl ${cls}" id="cl-${no}"><span class="no">${no}</span><span>${esc(line) || ' '}</span></div>`;
  }).join('');
  $('codeModal').classList.remove('hidden');
  if (focusLine) {
    requestAnimationFrame(() => {
      document.getElementById(`cl-${focusLine}`)?.scrollIntoView({ block: 'center' });
    });
  }
}

// ---------- search ----------
const searchInput = $('search');
const searchResults = $('searchResults');
let searchIdx = -1;
searchInput.addEventListener('input', () => {
  const q = searchInput.value.trim().toLowerCase();
  searchIdx = -1;
  if (!q || !state.data) { searchResults.classList.add('hidden'); return; }
  const matches = state.data.nodes
    .filter((n) => !n.missing && n.id.toLowerCase().includes(q))
    .sort((a, b) => a.label.length - b.label.length)
    .slice(0, 12);
  if (!matches.length) { searchResults.classList.add('hidden'); return; }
  searchResults.innerHTML = matches.map((n) => `
    <div class="row" data-id="${esc(n.id)}">
      <span class="hist-letter" style="color:${gradeColor(n.grade)}">${n.grade}</span>
      <span>${esc(n.label)}</span>
      <span class="path">${esc(n.dir)}</span>
    </div>`).join('');
  searchResults.classList.remove('hidden');
  for (const row of searchResults.querySelectorAll('.row')) {
    row.onclick = () => { focusNodeById(row.dataset.id); searchResults.classList.add('hidden'); searchInput.blur(); };
  }
});
searchInput.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.stopPropagation(); // dismiss the dropdown only — not the panel behind it
    searchResults.classList.add('hidden');
    searchInput.blur();
    return;
  }
  if (searchResults.classList.contains('hidden')) return; // stale rows must not react
  const rows = [...searchResults.querySelectorAll('.row')];
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    searchIdx = e.key === 'ArrowDown' ? Math.min(rows.length - 1, searchIdx + 1) : Math.max(0, searchIdx - 1);
    rows.forEach((r, i) => r.classList.toggle('active', i === searchIdx));
  } else if (e.key === 'Enter' && rows.length) {
    rows[Math.max(0, searchIdx)].click();
  }
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('.searchwrap')) searchResults.classList.add('hidden');
});

// ---------- toolbar ----------
$('tglLabels').onclick = (e) => {
  state.labelsOn = !state.labelsOn;
  e.currentTarget.classList.toggle('on', state.labelsOn);
  Graph.nodeThreeObject(Graph.nodeThreeObject());
};
$('tglParticles').onclick = (e) => {
  state.flowOn = !state.flowOn;
  e.currentTarget.classList.toggle('on', state.flowOn);
  Graph.linkDirectionalParticles(Graph.linkDirectionalParticles());
};
// Sync the Flow chip's lit state to the reduced-motion-aware default on load.
$('tglParticles').classList.toggle('on', state.flowOn);
$('tgl2d').onclick = (e) => {
  state.is2d = !state.is2d;
  e.currentTarget.classList.toggle('on', state.is2d);
  needsFit = true; // dimension switch re-heats the layout — re-frame when it settles
  Graph.numDimensions(state.is2d ? 2 : 3);
};
$('tglBroken').onclick = (e) => {
  state.filters.brokenOnly = !state.filters.brokenOnly;
  e.currentTarget.classList.toggle('on', state.filters.brokenOnly);
  applyData();
};
$('statBroken').onclick = () => $('tglBroken').click();
$('tglWindows').onclick = async (e) => {
  const btn = e.currentTarget;
  if (state.port.on) {
    state.port.on = false;
    btn.classList.remove('on');
    $('portSummary').classList.add('hidden');
    return refreshStyles();
  }
  if (state.port.loading) return;
  state.port.loading = true;
  btn.textContent = 'Checking…';
  try {
    const res = await fetch('/api/port');
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
    state.port.data = data;
    state.port.byId = new Map(data.files.map((f) => [f.id, f]));
    state.port.on = true;
    if (state.convert.on) setConvertOverlay(false); // one overlay at a time
    btn.classList.add('on');
    const a = data.summary.app;
    const needed = data.blockers.length;
    $('portSummary').textContent = a.files === 0
      ? 'No app source files to check.'
      : `${a.readyPct}% of app code runs on Windows as-is · ${needed} Windows part${needed === 1 ? '' : 's'} needed`;
    $('portSummary').classList.remove('hidden');
    refreshStyles();
  } catch (err) {
    toast(`Windows port check failed: ${err.message}`);
  } finally {
    state.port.loading = false;
    btn.textContent = 'Windows port';
  }
};
// ---------- Convert for Windows ----------
// The run happens in a separate process of the same program; progress lines arrive
// over the event stream and the verdict is read back when it finishes. The panel has
// the two things a person needs: a button that converts, and a button that opens what
// came out.
const CONVERT_ROWS = [
  ['portable', 'Builds for Windows unchanged'],
  ['converted', 'Converted — builds for Windows'],
  ['partial', 'Builds, with some declarations kept for the Mac'],
  ['needs-windows-part', 'Needs a Windows part (kept for the Mac build)'],
];

function showConvertResult(r) {
  state.convert.result = r;
  state.convert.byId = new Map((r?.files ?? []).map((f) => [f.id, f]));
  const side = $('convertStatus');
  const has = Boolean(r && r.totals.all.files);
  for (const id of ['convertOpenOut', 'convertReport']) $(id).disabled = !r;
  $('convertShow').disabled = !has;
  $('tglConverted').classList.toggle('hidden', !has);
  $('convertResult').classList.toggle('hidden', !r);
  side.classList.toggle('hidden', !r);
  if (!r) return;
  const t = r.totals;
  $('convertOutPath').textContent = r.out;
  const verified = r.verification.ran && r.verification.ok;
  const pct = $('convertPct');
  if (!has) {
    pct.textContent = '—'; $('convertPctLabel').textContent = 'No app source files to convert.';
    $('convertTable').innerHTML = ''; $('convertParts').innerHTML = ''; side.textContent = 'Nothing to convert.';
    return;
  }
  pct.classList.toggle('warn', !verified);
  if (verified) {
    pct.textContent = `${t.buildsForWindowsPct}%`;
    $('convertPctLabel').innerHTML = `of the app code builds for Windows — ${t.buildsLoc.toLocaleString()} of ${t.all.loc.toLocaleString()} lines.<br>Measured by your Swift compiler (${esc(r.verification.configuration)}).`;
    side.innerHTML = `<b>${t.buildsForWindowsPct}%</b> of the app code builds for Windows.`;
  } else {
    pct.textContent = 'Not verified';
    $('convertPctLabel').textContent = r.verification.ran
      ? `The compiler check did not finish: ${r.verification.failure ?? 'unknown'}. Nothing is counted as converted.`
      : 'The rewrites were applied, but no compiler has checked them, so nothing is counted as converted.';
    side.textContent = 'Converted copy written — not verified by a compiler.';
  }
  $('convertTable').innerHTML = CONVERT_ROWS.map(([key, label]) => {
    const b = key === 'needs-windows-part' ? t.needsWindowsPart : t[key];
    const lines = key === 'partial' ? `${t.partial.buildsLoc.toLocaleString()} build · ${t.partial.isolatedLoc.toLocaleString()} kept for Mac` : `${b.loc.toLocaleString()} lines`;
    return `<tr><td><span class="dot" style="background:${CONVERT_COLORS[key]}"></span>${label}</td><td class="num">${b.files} file${b.files === 1 ? '' : 's'}</td><td class="num">${lines}</td></tr>`;
  }).join('');
  const parts = r.windowsPartsNeeded.filter((p) => p.windows).slice(0, 6);
  $('convertParts').innerHTML = parts.length
    ? `<b>Windows parts the rest is waiting for:</b><br>${parts.map((p) => `${esc(p.id)} → ${esc(p.windows)} <span class="muted">(${p.loc.toLocaleString()} lines)</span>`).join('<br>')}`
    : '';
}

function setConvertRunning(on) {
  state.convert.running = on;
  $('convertRun').textContent = on ? 'Converting…' : (state.convert.result ? 'Convert again' : 'Convert for Windows');
  $('convertRun').disabled = on;
  $('convertOpenBtn').textContent = on ? 'Converting…' : 'Convert';
}

function openConvertPanel() {
  $('convertRepo').textContent = state.data?.name ? `— ${state.data.name}` : '';
  $('convertModal').classList.remove('hidden');
}
$('convertOpenBtn').onclick = openConvertPanel;
$('convertBtn').onclick = openConvertPanel;
$('convertClose').onclick = () => $('convertModal').classList.add('hidden');
$('convertModal').addEventListener('click', (e) => { if (e.target === $('convertModal')) $('convertModal').classList.add('hidden'); });

$('convertRun').onclick = async () => {
  if (state.convert.running) return;
  setConvertRunning(true);
  $('convertLog').textContent = '';
  $('convertLog').classList.remove('hidden');
  try {
    const res = await fetch('/api/convert', { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
  } catch (err) {
    setConvertRunning(false);
    toast(`Convert could not start: ${err.message}`);
  }
};

$('convertOpenOut').onclick = async () => {
  try {
    const res = await fetch('/api/convert/open', { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
    toast('Opened the converted code in your file manager.');
  } catch (err) {
    toast(`Could not open the output folder: ${err.message}`);
  }
};

$('convertReport').onclick = async () => {
  try {
    const res = await fetch('/api/convert/report');
    if (!res.ok) throw new Error((await res.json()).error ?? `HTTP ${res.status}`);
    const text = await res.text();
    $('codeTitle').textContent = 'CONVERSION.md';
    $('codeBody').innerHTML = text.split('\n').map((l, i) => `<div class="cl"><span class="no">${i + 1}</span><span>${esc(l) || ' '}</span></div>`).join('');
    $('convertModal').classList.add('hidden');
    $('codeModal').classList.remove('hidden');
  } catch (err) {
    toast(`No report yet: ${err.message}`);
  }
};

function setConvertOverlay(on) {
  state.convert.on = on;
  $('tglConverted').classList.toggle('on', on);
  $('convertShow').textContent = on ? 'Hide on graph' : 'Show on graph';
  if (on && state.port.on) $('tglWindows').click(); // one overlay at a time
  refreshStyles();
}
$('tglConverted').onclick = () => setConvertOverlay(!state.convert.on);
$('convertShow').onclick = () => { setConvertOverlay(!state.convert.on); if (state.convert.on) $('convertModal').classList.add('hidden'); };

async function loadConvertState() {
  try {
    const data = await (await fetch('/api/convert')).json();
    if (data.running) { setConvertRunning(true); $('convertLog').classList.remove('hidden'); $('convertLog').textContent = data.log.join('\n'); }
    showConvertResult(data.result ?? null);
    if (!data.running) setConvertRunning(false);
  } catch { /* the panel just stays empty */ }
}

let rescanRestore;
$('rescanBtn').onclick = async () => {
  $('rescanBtn').textContent = 'Scanning…';
  clearTimeout(rescanRestore);
  rescanRestore = setTimeout(() => { $('rescanBtn').textContent = 'Re-scan'; }, 15000);
  try { await fetch('/api/rescan', { method: 'POST' }); }
  catch { $('rescanBtn').textContent = 'Re-scan'; toast('Re-scan failed — is the server up?'); }
};
$('panelClose').onclick = () => { state.selected = null; hidePanel(); refreshStyles(); };
$('codeClose').onclick = () => $('codeModal').classList.add('hidden');
$('codeModal').addEventListener('click', (e) => { if (e.target === $('codeModal')) $('codeModal').classList.add('hidden'); });

document.addEventListener('keydown', (e) => {
  if (e.key === '/' && document.activeElement !== searchInput && $('welcome').classList.contains('hidden')) { e.preventDefault(); searchInput.focus(); }
  // Replay transport: space toggles play, ←/→ step frames (when not typing).
  if (state.replay.on && document.activeElement !== searchInput) {
    if (e.key === ' ') { e.preventDefault(); if (state.replay.playing) stopPlay(); else playReplay(); return; }
    if (e.key === 'ArrowLeft') { e.preventDefault(); stopPlay(); stepReplay(-1); return; }
    if (e.key === 'ArrowRight') { e.preventDefault(); stopPlay(); stepReplay(1); return; }
  }
  // Tour transport: ←/→ step stops when the tour is running (and not typing).
  if (tour.on && document.activeElement !== searchInput) {
    if (e.key === 'ArrowLeft') { e.preventDefault(); tourStep(-1); return; }
    if (e.key === 'ArrowRight') { e.preventDefault(); tourStep(1); return; }
  }
  if (e.key === 'Escape') {
    if (!$('welcome').classList.contains('hidden')) closeWelcome();
    else if (!$('codeModal').classList.contains('hidden')) $('codeModal').classList.add('hidden');
    else if (!$('convertModal').classList.contains('hidden')) $('convertModal').classList.add('hidden');
    else if (tour.on) exitTour();
    else if (state.replay.on) exitReplay();
    else if (state.selected) { state.selected = null; hidePanel(); refreshStyles(); }
  }
});

// ---------- grade-over-history replay (CI-20 "refactor movie") ----------
// Fetch the per-commit timeline once, then scrub/play it: the SAME 3D graph
// recolors to each commit's real per-node grade. All data comes from
// /api/history (genuine analyzeRepo output per commit) — nothing is synthesized
// client-side, and commits the backend couldn't grade show ∅/— not a fake A.
const REPLAY_FRAME_MS = 900;
function fmtDate(ts) { try { return new Date(ts).toISOString().slice(0, 10); } catch { return ''; } }

async function enterReplay() {
  if (state.replay.loading) return;
  state.replay.loading = true;
  $('tglReplay').textContent = 'Loading…';
  let data;
  try {
    const res = await fetch('/api/history');
    data = await res.json();
  } catch {
    state.replay.loading = false;
    $('tglReplay').textContent = '▶ Refactor movie';
    toast('Could not load history');
    return;
  }
  state.replay.loading = false;
  $('tglReplay').textContent = '▶ Refactor movie';
  if (!data.supported || !data.commits?.length) {
    $('tglReplay').classList.remove('on');
    toast(data.reason ? `No replay — ${data.reason}` : 'No history to replay');
    return;
  }
  state.replay.data = data;
  state.replay.on = true;
  $('tglReplay').classList.add('on');
  const scrub = $('replayScrub');
  scrub.max = String(data.commits.length - 1);
  $('replayBar').classList.remove('hidden');
  if (data.dropped > 0) toast(`Replaying ${data.sampled} of ${data.totalCommits} commits — sampled evenly`);
  showFrame(data.commits.length - 1); // start at HEAD (rightmost)
}

function exitReplay() {
  stopPlay();
  state.replay.on = false;
  state.replay.frame = null;
  $('replayBar').classList.add('hidden');
  $('tglReplay').classList.remove('on');
  refreshStyles();
}

function showFrame(i) {
  const commits = state.replay.data.commits;
  i = Math.max(0, Math.min(commits.length - 1, i));
  state.replay.idx = i;
  const c = commits[i];
  state.replay.frame = c;
  $('replayScrub').value = String(i);
  const gradeEl = $('replayGrade');
  if (c.grade == null) {
    gradeEl.textContent = c.error ? '—' : '∅';
    gradeEl.style.color = '#7e8da6';
    gradeEl.title = c.error ? `Not gradeable — ${c.error}` : 'No source files to grade at this commit';
  } else {
    gradeEl.textContent = c.grade;
    gradeEl.style.color = gradeColor(c.grade);
    gradeEl.title = `${c.score} / 100 · ${c.files} file${c.files === 1 ? '' : 's'}`;
  }
  const scoreTxt = c.grade == null ? '' : ` (${c.score})`;
  $('replayMeta').textContent = `${i + 1}/${commits.length} · ${c.shortSha} · ${fmtDate(c.ts)}${scoreTxt} · ${c.subject}`.slice(0, 150);
  refreshStyles();
}

function stepReplay(delta) { showFrame(state.replay.idx + delta); }

function playReplay() {
  if (state.replay.playing) return;
  if (state.replay.idx >= state.replay.data.commits.length - 1) showFrame(0); // restart from the start
  state.replay.playing = true;
  $('replayPlay').textContent = '⏸';
  state.replay.timer = setInterval(() => {
    if (state.replay.idx >= state.replay.data.commits.length - 1) { stopPlay(); return; }
    stepReplay(1);
  }, REPLAY_FRAME_MS);
}
function stopPlay() {
  state.replay.playing = false;
  clearInterval(state.replay.timer);
  state.replay.timer = null;
  $('replayPlay').textContent = '▶';
}

function exportTimeline() {
  const d = state.replay.data;
  if (!d) return;
  const blob = new Blob([JSON.stringify(d, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${d.name}-grade-timeline.json`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

$('tglReplay').onclick = () => { if (state.replay.on) exitReplay(); else enterReplay(); };
$('replayPlay').onclick = () => { if (state.replay.playing) stopPlay(); else playReplay(); };
$('replayScrub').oninput = () => { stopPlay(); showFrame(Number($('replayScrub').value)); };
$('replayExport').onclick = exportTimeline;
$('replayClose').onclick = exitReplay;

// ---------- guided 3D tour (CI-23 "walkthrough") ----------
// An auto-seeded fly-through: the camera flies node-to-node, opening each file's
// REAL report card as it lands. Stops are chosen from genuine graph facts —
// entry points (roots that import others but nothing imports them) and churn
// hotspots (git commits/90d, already computed per node) — with dependency hubs
// and worst offenders as honest fallbacks so a repo with no roots/history still
// gets a tour. Every word of narration is assembled from computed metrics
// (grade, dimensions, findings, fan-in/out, churn); nothing is canned prose that
// asserts a fact the analyzer didn't produce.
const tour = { on: false, stops: [], idx: 0 };

function weakestDim(n) {
  const entries = Object.entries(n.dimensions ?? {});
  if (!entries.length) return null;
  return entries.reduce((a, b) => (b[1] < a[1] ? b : a));
}

function buildTourStops() {
  const nodes = state.data?.nodes?.filter((n) => !n.missing) ?? [];
  const stops = [];
  const seen = new Set();
  const push = (n, reason) => { if (n && !seen.has(n.id)) { seen.add(n.id); stops.push({ id: n.id, reason }); } };
  // Entry points: fan-in 0, fan-out > 0 — the code the repo starts from.
  for (const n of nodes.filter((n) => n.fanIn === 0 && n.fanOut > 0).sort((a, b) => b.fanOut - a.fanOut).slice(0, 4)) push(n, 'entry');
  // Churn hotspots: most-edited files over the last 90 days (real git churn).
  for (const n of nodes.filter((n) => n.churn > 0).sort((a, b) => b.churn - a.churn).slice(0, 4)) push(n, 'churn');
  // Fallbacks (still real graph facts) so the tour is never empty.
  if (stops.length < 3) for (const n of [...nodes].sort((a, b) => (b.fanIn + b.fanOut) - (a.fanIn + a.fanOut)).slice(0, 3)) push(n, 'hub');
  if (stops.length < 3) for (const n of [...nodes].filter((n) => n.loc >= 10).sort((a, b) => a.score - b.score).slice(0, 3)) push(n, 'worst');
  return stops.slice(0, 7);
}

function tourNarration(stop) {
  const n = state.data.nodes.find((x) => x.id === stop.id);
  if (!n) return '';
  const reason = {
    entry: `Entry point — nothing imports it; it wires out to ${n.fanOut} file${n.fanOut === 1 ? '' : 's'}.`,
    churn: `Churn hotspot — ${n.churn} commit${n.churn === 1 ? '' : 's'} in the last 90 days.`,
    hub: `Dependency hub — ${n.fanIn} in, ${n.fanOut} out.`,
    worst: `Among the lowest-graded files here.`,
  }[stop.reason] ?? '';
  const w = weakestDim(n);
  const weak = w ? ` Weakest dimension: ${DIM_LABELS[w[0]] ?? w[0]} ${w[1]}.` : '';
  const top = [...n.findings].sort((a, b) => (SEV_ORDER[a.severity] - SEV_ORDER[b.severity]) || (b.points - a.points))[0];
  const issue = n.findings.length ? ` Top issue (${top.severity}): ${top.msg.replace(/`/g, '')}` : ' Clean — nothing to flag.';
  return `${n.id} — grades ${n.grade} (${n.score}). ${reason}${weak}${issue}`;
}

function enterTour() {
  if (!state.data || state.data.stats.empty) { toast('Nothing to tour — no gradeable files.'); return; }
  const stops = buildTourStops();
  if (!stops.length) { toast('Nothing to tour — no gradeable files.'); return; }
  tour.on = true;
  tour.stops = stops;
  $('tglTour').classList.add('on');
  $('tourBar').classList.remove('hidden');
  showTourStop(0);
}

function exitTour() {
  tour.on = false;
  $('tourBar').classList.add('hidden');
  $('tglTour').classList.remove('on');
}

function showTourStop(i) {
  i = Math.max(0, Math.min(tour.stops.length - 1, i));
  tour.idx = i;
  const stop = tour.stops[i];
  focusNodeById(stop.id);            // flies the camera in and opens the real report card
  $('tourNarration').textContent = tourNarration(stop);
  $('tourProgress').textContent = `${i + 1} / ${tour.stops.length}`;
  $('tourPrev').disabled = i === 0;
  $('tourNext').textContent = i === tour.stops.length - 1 ? 'Done' : 'Next →';
}

function tourStep(delta) {
  if (delta > 0 && tour.idx === tour.stops.length - 1) { exitTour(); return; }
  showTourStop(tour.idx + delta);
}

$('tglTour').onclick = () => { if (tour.on) exitTour(); else enterTour(); };
$('tourPrev').onclick = () => tourStep(-1);
$('tourNext').onclick = () => tourStep(1);
$('tourClose').onclick = exitTour;

// ---------- first-run welcome / help ----------
const WELCOME_KEY = 'circuit.welcomed.v1';
function openWelcome() { $('welcome').classList.remove('hidden'); }
function closeWelcome() {
  $('welcome').classList.add('hidden');
  try { localStorage.setItem(WELCOME_KEY, '1'); } catch { /* private mode — just don't persist */ }
}
$('welcomeGo').onclick = closeWelcome;
$('welcomeClose').onclick = closeWelcome;
$('helpBtn').onclick = openWelcome;
$('welcome').addEventListener('click', (e) => { if (e.target === $('welcome')) closeWelcome(); });
let alreadyWelcomed = false;
try { alreadyWelcomed = localStorage.getItem(WELCOME_KEY) === '1'; } catch { /* ignore */ }
if (!alreadyWelcomed) openWelcome();

// ---------- toast & live ----------
let toastTimer;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add('hidden'), 3200);
}

const events = new EventSource('/api/events');
loadConvertState();
let hadHello = false;
events.addEventListener('hello', () => {
  $('liveDot').classList.add('on');
  // On reconnect, re-fetch — a re-grade may have been broadcast while we were away.
  if (hadHello) loadGraph(true);
  hadHello = true;
});
events.addEventListener('convert', (e) => {
  const { line } = JSON.parse(e.data);
  const log = $('convertLog');
  log.classList.remove('hidden');
  log.textContent += `${log.textContent ? '\n' : ''}${line}`;
  log.scrollTop = log.scrollHeight;
});
events.addEventListener('convert-done', async (e) => {
  const { ok, error } = JSON.parse(e.data);
  setConvertRunning(false);
  await loadConvertState();
  if (!ok) toast(`Convert failed: ${error}`);
  else toast('Converted. Open output folder to get the code.');
});
events.addEventListener('graph', async (e) => {
  $('liveDot').classList.add('pulse');
  await loadGraph(true);
  $('rescanBtn').textContent = 'Re-scan';
  clearTimeout(rescanRestore);
  const { reason } = JSON.parse(e.data);
  const s = state.data.stats;
  toast(s.empty ? `Re-scanned — no source files found (${reason})` : `Re-graded: ${s.grade} (${s.score}) — ${reason}`);
  setTimeout(() => $('liveDot').classList.remove('pulse'), 1200);
});
events.addEventListener('error', (e) => {
  $('rescanBtn').textContent = 'Re-scan';
  clearTimeout(rescanRestore);
  try { toast(`Analysis failed: ${JSON.parse(e.data).message}`); } catch { /* connection-level error */ }
});
events.onerror = () => $('liveDot').classList.remove('on');

// ---------- licensing (honest demo/trial CTA — fail-closed, price-free) ----------
async function loadLicense() {
  let lic;
  try {
    const res = await fetch('/api/license');
    if (!res.ok) throw new Error(res.status);
    lic = await res.json();
  } catch {
    // Fail-closed on the client too: if we can't confirm a license, show demo.
    lic = { mode: 'demo', notice: 'Demo build — Circuit needs a paid license for continued use.',
            cta: 'Get a license', productUrl: 'https://blacklabelbots.com/circuit' };
  }
  const banner = $('demoBanner');
  if (!banner) return;
  if (lic.mode === 'licensed') { banner.classList.add('hidden'); return; }
  $('demoNotice').textContent = lic.notice ?? 'Demo build — paid license required.';
  const cta = $('demoCta');
  cta.textContent = lic.cta ?? 'Get a license';
  cta.href = lic.productUrl ?? 'https://blacklabelbots.com/circuit';
  banner.classList.remove('hidden');
}

// ---------- air-gap / offline-mode posture (CI-18) ----------
// Circuit's backend makes zero outbound network calls (provable via the CI-15
// source scan) and binds loopback-only. Surface that as an always-on, honest chip
// so regulated / air-gapped buyers can see at a glance that their source never
// leaves the machine. This is a standing fact, not a runtime measurement — see
// AIRGAP.md for the attestable no-network statement.
function showOfflineChip() {
  const chip = $('offlineChip');
  if (!chip) return;
  chip.textContent = '⏚ offline — no code leaves this machine';
  chip.title = 'Air-gap ready: Circuit runs fully on this machine. Your source is never uploaded — the backend makes zero outbound network calls and binds to localhost only. See AIRGAP.md for the attestable no-network statement (verified by the CI-15 source scan).';
}

// ---------- go ----------
showOverlay('analyzing'); // instant feedback while the first scan runs — never a blank window
showOfflineChip();
loadLicense();
loadGraph();
