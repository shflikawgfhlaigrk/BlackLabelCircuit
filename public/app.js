// Circuit UI — 3D force graph of the codebase, graded and wired.
import { ForceGraph3D, SpriteText, THREE, UnrealBloomPass } from '/vendor/circuit-3d.bundle.mjs';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// ---------- grade colors (validated ramp: monotonic lightness on dark) ----------
const GRADE_COLORS = { A: '#86efac', B: '#a3e635', C: '#eab308', D: '#fb923c', F: '#f87171' };
const BROKEN = '#ff3355';
const DIM_NODE = '#1c2431';
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
  .linkDirectionalParticleSpeed((l) => (l.broken ? 0.012 : 0.006))
  .linkDirectionalParticleColor((l) => (l.broken ? BROKEN : '#6ea8d8'))
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
  return scoreColor(n.score);
}

function linkTouchesFocus(l) {
  const focus = state.selected ?? state.hover;
  if (!focus) return false;
  const sid = l.source.id ?? l.source, tid = l.target.id ?? l.target;
  return sid === focus.id || tid === focus.id;
}

function linkColorFn(l) {
  if (l.broken) return BROKEN;
  const hood = activeNeighborhood();
  if (hood) return linkTouchesFocus(l) ? '#9ed4ff' : 'rgba(40,52,70,0.5)';
  return 'rgba(110,135,175,0.55)';
}

function linkWidthFn(l) {
  return linkTouchesFocus(l) ? 1.6 : 0;
}

function particlesFn(l) {
  if (l.broken) return 4;
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
    <div class="tt-line">${n.loc} loc · ${n.fanIn}↚ ${n.fanOut}↛ · ${findings === 0 ? 'clean' : findings + ' finding' + (findings === 1 ? '' : 's')}</div>`;
}

function refreshStyles() {
  Graph.nodeColor(Graph.nodeColor());
  Graph.linkColor(Graph.linkColor());
  Graph.linkWidth(Graph.linkWidth());
  Graph.linkDirectionalParticles(Graph.linkDirectionalParticles());
}

// ---------- data ----------
async function loadGraph(preservePositions = false) {
  const res = await fetch('/api/graph');
  if (!res.ok) { setTimeout(() => loadGraph(preservePositions), 800); return; }
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

  const hero = $('heroGrade');
  hero.textContent = stats.grade;
  hero.style.color = gradeColor(stats.grade);
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
    return `<div class="dim-row">
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
  if (e.key === '/' && document.activeElement !== searchInput) { e.preventDefault(); searchInput.focus(); }
  if (e.key === 'Escape') {
    if (!$('codeModal').classList.contains('hidden')) $('codeModal').classList.add('hidden');
    else if (state.selected) { state.selected = null; hidePanel(); refreshStyles(); }
  }
});

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
let hadHello = false;
events.addEventListener('hello', () => {
  $('liveDot').classList.add('on');
  // On reconnect, re-fetch — a re-grade may have been broadcast while we were away.
  if (hadHello) loadGraph(true);
  hadHello = true;
});
events.addEventListener('graph', async (e) => {
  $('liveDot').classList.add('pulse');
  await loadGraph(true);
  $('rescanBtn').textContent = 'Re-scan';
  clearTimeout(rescanRestore);
  const { reason } = JSON.parse(e.data);
  const s = state.data.stats;
  toast(`Re-graded: ${s.grade} (${s.score}) — ${reason}`);
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

// ---------- go ----------
loadLicense();
loadGraph();
