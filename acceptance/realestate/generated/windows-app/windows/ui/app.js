// Black Label Real Estate — Windows web client · UI.
//
// Pure reach over the live worker (see api.js). Every row rendered here came back from
// https://api.blbestate.com; nothing is synthesized. Record fields are written with
// textContent (never innerHTML) so a county string can never inject markup, and an
// uncovered area / still-integrating category / unreachable database each render a
// distinct HONEST state instead of a fabricated parcel.

/* ---------- tiny DOM helpers (no framework, no build step) ---------- */
function el(tag, attrs = {}, kids = []) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v;
    else if (k === "text") n.textContent = v;           // record-safe
    else if (k === "html") n.innerHTML = v;             // ONLY for our own static markup
    else if (k.startsWith("on") && typeof v === "function") n.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) n.setAttribute(k, v);
  }
  for (const kid of [].concat(kids)) if (kid != null) n.append(kid.nodeType ? kid : document.createTextNode(kid));
  return n;
}
const $ = (sel, root = document) => root.querySelector(sel);
const clear = (n) => { while (n.firstChild) n.removeChild(n.firstChild); return n; };

const money = (v) => (v == null || v === "" || isNaN(Number(v))) ? "—" : "$" + Number(v).toLocaleString("en-US");
const num = (v) => (v == null || isNaN(Number(v))) ? "—" : Number(v).toLocaleString("en-US");
const txt = (v) => (v == null || String(v).trim() === "") ? "—" : String(v);

/* ---------- app state ---------- */
const State = {
  tab: "index",
  stats: null,
  coverage: null,           // [{state, counties, properties}]
  coveredStates: new Set(),
};

/* ================================================================= *
 *  BOOT
 * ================================================================= */
async function boot() {
  renderChrome();
  // Header truth pill + coverage come straight from the live worker.
  try {
    State.stats = await BLRE_API.stats();
    renderStatsPill();
  } catch (e) {
    $("#statsPill").textContent = "Live index unreachable — retrying on your next action";
  }
  try {
    const cov = await BLRE_API.coverage();
    State.coverage = cov.coverage || [];
    State.coveredStates = new Set(State.coverage.filter((c) => c.properties > 0).map((c) => c.state));
  } catch { /* coverage optional; state pickers fall back to all states */ }
  route();
}

function renderChrome() {
  const root = $("#app");
  clear(root);
  root.append(
    el("header", { class: "topbar" }, [
      el("div", { class: "brand", html: 'Black Label <span class="gold">Real Estate</span>' }),
      el("div", { class: "stat-pill", id: "statsPill", text: "Connecting to the live index…" }),
      el("nav", { class: "tabs", id: "tabs" }, [
        tabBtn("index", "Property Index"),
        tabBtn("map", "Map"),
        tabBtn("builder", "List Builder"),
        tabBtn("coverage", "Coverage"),
        tabBtn("settings", "Settings"),
      ]),
    ]),
    el("main", { id: "main" }),
    drawerScaffold(),
  );
}
function tabBtn(key, label) {
  return el("button", { class: State.tab === key ? "active" : "", "data-tab": key,
    onclick: () => { State.tab = key; route(); } }, [label]);
}
function renderStatsPill() {
  const s = State.stats;
  $("#statsPill").innerHTML = s
    ? `<b>${num(s.total_properties)}</b> parcels · <b>${num(s.states)}</b> states · <b>${num(s.counties)}</b> counties`
    : "";
}
function route() {
  $("#tabs") && [...$("#tabs").children].forEach((b) => b.classList.toggle("active", b.dataset.tab === State.tab));
  const main = clear($("#main"));
  if (State.tab === "index") viewIndex(main);
  else if (State.tab === "map") viewMap(main);
  else if (State.tab === "builder") viewBuilder(main);
  else if (State.tab === "coverage") viewCoverage(main);
  else if (State.tab === "settings") viewSettings(main);
}

/* ---------- shared: honest state callouts ---------- */
function calloutError(err) {
  const offline = err && err.offline;
  return el("div", { class: "callout bad" }, [
    el("div", { class: "h", text: offline ? "Can't reach the property database" : "The database rejected that query" }),
    el("div", { class: "m", text: err ? err.message : "Unknown error." }),
  ]);
}
function calloutEmpty(msg) {
  return el("div", { class: "callout" }, [
    el("div", { class: "h", text: "No matching public records" }),
    el("div", { class: "m", text: msg }),
  ]);
}
function stateSelect(id, value) {
  const opts = [el("option", { value: "", text: "State…" })];
  const list = State.coverage && State.coverage.length
    ? State.coverage.map((c) => c.state)
    : US_STATES;
  for (const s of list) opts.push(el("option", { value: s, text: s, ...(s === value ? { selected: "" } : {}) }));
  return el("select", { id }, opts);
}

/* ================================================================= *
 *  PROPERTY INDEX (search)
 * ================================================================= */
function viewIndex(main) {
  const v = el("div", { class: "view" });
  v.append(
    el("h1", { text: "Property Index" }),
    el("p", { class: "sub", text: "Search the live public-records index by place, owner, category, and value. Every result is a real county record." }),
  );
  const catOpts = [el("option", { value: "", text: "Any category" })];
  for (const c of BLRE_CATEGORIES.filter((c) => c.available && c.api)) catOpts.push(el("option", { value: c.api, text: c.label }));

  const form = el("div", { class: "panel" }, [
    el("div", { class: "row" }, [
      wrap("Where (a location is required for category/value filters)",
        el("div", { class: "row" }, [ stateSelect("f_state"), inp("f_county", "County"), inp("f_city", "City"), inp("f_zip", "ZIP") ])),
    ]),
    el("div", { class: "row" }, [
      wrap("Category", el("select", { id: "f_cat" }, catOpts)),
      wrap("Owner name contains", inp("f_owner", "e.g. SMITH")),
      wrap("Min assessed $", inp("f_min", "", "number")),
      wrap("Max assessed $", inp("f_max", "", "number")),
    ]),
    el("div", { class: "row", style: "margin-top:14px; flex:0" }, [
      el("button", { class: "btn", id: "f_go", onclick: runSearch }, ["Search the index"]),
    ]),
  ]);
  v.append(form, el("div", { id: "searchOut" }));
  main.append(v, footer());
}
function wrap(label, node) { return el("div", {}, [el("label", { class: "field", text: label }), node]); }
function inp(id, ph, type = "text") { return el("input", { id, placeholder: ph || "", type }); }

async function runSearch() {
  const out = clear($("#searchOut"));
  const p = {
    state: $("#f_state").value, county: $("#f_county").value, city: $("#f_city").value, zip: $("#f_zip").value,
    category: $("#f_cat").value, owner_name: $("#f_owner").value,
    min_value: $("#f_min").value, max_value: $("#f_max").value, per_page: 25,
  };
  const hasArea = p.state || p.county || p.city || p.zip;
  const usesFilter = p.category || p.min_value || p.max_value;
  if (usesFilter && !hasArea) {
    out.append(el("div", { class: "callout warn" }, [
      el("div", { class: "h", text: "Add a location" }),
      el("div", { class: "m", text: "Category and value filters run against a place. Add a state, county, city, or ZIP so the search stays bounded to real coverage." }),
    ]));
    return;
  }
  out.append(el("div", { class: "spinner", text: "Counting matching public records…" }));
  try {
    const r = await BLRE_API.search(p);
    clear(out);
    renderCount(out, r, "search");
    if (!r.results.length) { out.append(calloutEmpty("The index has no servable rows for those criteria yet — try a broader area or a different category. No placeholder rows are ever shown.")); return; }
    out.append(resultsTable(r.results));
  } catch (e) {
    clear(out); out.append(calloutError(e));
  }
}

function renderCount(out, r, kind) {
  const total = r.total, cap = r.per_page, tier = r.tier || "preview";
  const capped = total > cap;
  // The tier comes straight from the worker's response — it is the honest, verified
  // truth about which per-request cap is in force, not a client guess.
  const capNote = !capped
    ? `Showing all ${num(total)}.`
    : tier === "preview"
      ? `Anonymous preview shows the first ${num(cap)}. Add a subscriber token in Settings to raise the per-request cap — the total above is already the real, uncapped count.`
      : `Subscriber tier “${txt(tier)}” — showing the first ${num(cap)}. The total above is the real, uncapped count.`;
  out.append(el("div", { class: "panel" }, [
    el("div", { class: "count-hero", html: `${num(total)} <small>matching parcels in the public-records index</small>` }),
    el("div", { class: "map-note", text: capNote }),
  ]));
}

function resultsTable(rows) {
  const tbl = el("table", {}, [
    el("thead", {}, el("tr", {}, [
      th("Owner"), th("Situs address"), th("City"), th("ST"), th("Assessed"), th("Last sale"),
    ])),
  ]);
  const body = el("tbody");
  for (const r of rows) {
    const tr = el("tr", { class: "clickable", onclick: () => openDetail(r) }, [
      td(txt(r.owner_name)), td(txt(r.situs_address)), td(txt(r.situs_city)), td(txt(r.state)),
      tdNum(money(r.assessed_value)), td(txt(r.last_sale_date)),
    ]);
    body.append(tr);
  }
  tbl.append(body);
  return el("div", { class: "panel" }, [tbl]);
}
const th = (t) => el("th", { text: t });
const td = (t) => el("td", { text: t });
const tdNum = (t) => el("td", { class: "num", text: t });

/* ================================================================= *
 *  MAP (Leaflet + OSM tiles — free, vendored lib)
 * ================================================================= */
let _map = null, _layer = null, _mapDebounce = null;
function viewMap(main) {
  const v = el("div", { class: "view" });
  v.append(
    el("h1", { text: "Map" }),
    el("p", { class: "sub", text: "Real public-record pins for the visible area — the worker only returns parcels that already carry county lat/lng; it never geocodes or invents a point." }),
    el("div", { class: "panel", style: "padding:0; overflow:hidden" }, [ el("div", { id: "map" }) ]),
    el("div", { class: "map-note", id: "mapNote", text: "Pan or zoom to load pins for that area." }),
  );
  main.append(v, footer());
  // Leaflet is vendored (BSD, own-it). Tiles are OpenStreetMap's free public tile server.
  _map = L.map("map", { zoomControl: true }).setView([39.5, -98.35], 4); // continental US
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19, attribution: "© OpenStreetMap contributors",
  }).addTo(_map);
  _layer = L.layerGroup().addTo(_map);
  _map.on("moveend", () => { clearTimeout(_mapDebounce); _mapDebounce = setTimeout(loadMapPins, 350); });
  loadMapPins();
}
async function loadMapPins() {
  if (!_map) return;
  const note = $("#mapNote"); if (note) note.textContent = "Loading pins for the visible area…";
  const b = _map.getBounds();
  const params = {
    north: b.getNorth(), south: b.getSouth(), east: b.getEast(), west: b.getWest(),
    per_page: _map.getZoom() >= 6 ? 500 : 250,
  };
  try {
    const r = await BLRE_API.map(params);
    _layer.clearLayers();
    for (const p of r.results) {
      if (p.lat == null || p.lng == null) continue;
      const m = L.marker([Number(p.lat), Number(p.lng)]);
      m.on("click", () => openDetail(p));
      m.bindPopup(popupHtml(p));
      m.addTo(_layer);
    }
    if (note) note.textContent = r.results.length
      ? `${num(r.results.length)} real public-record pins in view` + (r.results.length >= params.per_page ? ` (preview cap — zoom in for the rest)` : "")
      : "No geocoded public records in this view. Pan to a covered area (see the Coverage tab).";
  } catch (e) {
    if (note) note.textContent = e.offline ? "Can't reach the property database." : (e.message || "Map query failed.");
  }
}
function popupHtml(p) {
  // Build with DOM to keep record fields record-safe, then return the element.
  return el("div", {}, [
    el("div", { style: "font-weight:700", text: txt(p.owner_name) }),
    el("div", { text: [txt(p.situs_address), txt(p.situs_city)].filter((x) => x !== "—").join(", ") }),
    el("div", { style: "color:#8b90a0;font-size:12px", text: `Assessed ${money(p.assessed_value)}` }),
  ]);
}

/* ================================================================= *
 *  LIST BUILDER — guided 4-step (What / Where / Filters / Results),
 *  a mirror of the macOS ListBuilderScreen flow.
 * ================================================================= */
const Builder = { step: 1, cat: null, where: {}, filters: {} };
function viewBuilder(main) {
  const v = el("div", { class: "view" });
  v.append(
    el("h1", { text: "List Builder" }),
    el("p", { class: "sub", text: "Pick a type, pick a place, get real parcels — straight from the live public-records database. No paste, no upload." }),
    stepChrome(),
    el("div", { id: "builderBody" }),
  );
  main.append(v, footer());
  renderStep();
}
function stepChrome() {
  const names = ["What", "Where", "Filters", "Results"];
  return el("div", { class: "steps", id: "steps" }, names.map((nm, i) => {
    const n = i + 1;
    const cls = n === Builder.step ? "step on" : (n < Builder.step ? "step done" : "step");
    return el("div", { class: cls, onclick: () => { if (n < Builder.step) { Builder.step = n; renderStep(); } } },
      [ el("div", { class: "dot", text: String(n) }), nm ]);
  }));
}
function renderStep() {
  $("#steps").replaceWith(stepChrome());
  const body = clear($("#builderBody"));
  if (Builder.step === 1) body.append(stepWhat());
  else if (Builder.step === 2) body.append(stepWhere());
  else if (Builder.step === 3) body.append(stepFilters());
  else body.append(stepResults());
}
function stepWhat() {
  const p = el("div", { class: "panel" }, [
    el("h2", { text: "1 · What type of list?" }),
    el("p", { class: "sub", text: "Every type maps to a real public-record signal — no signal, no list, and it says so." }),
  ]);
  const grid = el("div", { class: "cat-grid" });
  for (const c of BLRE_CATEGORIES) {
    const card = el("button", { class: "cat", onclick: () => pickCat(c) }, [
      el("div", { class: "t", text: c.label }),
      el("div", { class: "b", text: c.blurb }),
    ]);
    if (!c.available) card.append(el("div", { class: "badge", text: "INDEXING" }));
    grid.append(card);
  }
  p.append(grid);
  return p;
}
function pickCat(c) {
  Builder.cat = c;
  if (!c.available) { Builder.step = 4; renderStep(); return; } // honest indexing state on results step
  Builder.step = 2; renderStep();
}
function stepWhere() {
  const w = Builder.where;
  const p = el("div", { class: "panel" }, [
    el("h2", { text: `2 · Where?  (${Builder.cat.label})` }),
    el("p", { class: "sub", text: "A location keeps the list bounded to real coverage. State is the minimum." }),
    el("div", { class: "row" }, [
      wrap("State", stateSelect("b_state", w.state)),
      wrap("County", inp("b_county", "optional")),
      wrap("City", inp("b_city", "optional")),
      wrap("ZIP", inp("b_zip", "optional")),
    ]),
    el("div", { class: "row", style: "margin-top:14px; flex:0" }, [
      el("button", { class: "btn", onclick: () => {
        Builder.where = { state: $("#b_state").value, county: $("#b_county").value, city: $("#b_city").value, zip: $("#b_zip").value };
        if (!Builder.where.state && !Builder.where.county && !Builder.where.city && !Builder.where.zip) {
          alert("Pick at least a state so the list stays bounded to real coverage."); return;
        }
        Builder.step = 3; renderStep();
      } }, ["Next: filters"]),
    ]),
  ]);
  return p;
}
function stepFilters() {
  const f = Builder.filters;
  return el("div", { class: "panel" }, [
    el("h2", { text: "3 · Optional filters" }),
    el("p", { class: "sub", text: "Only fields the index really has. Leave blank to skip." }),
    el("div", { class: "row" }, [
      wrap("Min assessed $", inp("b_min", "", "number")),
      wrap("Max assessed $", inp("b_max", "", "number")),
      wrap("Owner name contains", inp("b_owner", "optional")),
    ]),
    el("div", { class: "row", style: "margin-top:14px; flex:0; gap:10px" }, [
      el("button", { class: "btn ghost", onclick: () => { Builder.step = 2; renderStep(); } }, ["Back"]),
      el("button", { class: "btn", onclick: () => {
        Builder.filters = { min_value: $("#b_min").value, max_value: $("#b_max").value, owner_name: $("#b_owner").value };
        Builder.step = 4; renderStep();
      } }, ["Build the list"]),
    ]),
  ]);
}
function stepResults() {
  const body = el("div", {});
  // Honest state for a still-integrating category — never placeholder rows.
  if (Builder.cat && !Builder.cat.available) {
    const adj = BLRE_CATEGORIES.filter((c) => c.available && c.api).slice(0, 4);
    body.append(el("div", { class: "callout warn" }, [
      el("div", { class: "h", text: `${Builder.cat.label} is still integrating nationally` }),
      el("div", { class: "m", text: Builder.cat.blurb }),
      el("div", { class: "m", style: "margin-top:8px", text: "Rather than show placeholder rows, here are real adjacent lists you can build right now:" }),
      el("div", { class: "chips" }, adj.map((c) => el("button", { class: "chip", onclick: () => { Builder.cat = c; Builder.step = 2; renderStep(); } }, [c.label]))),
    ]));
    return body;
  }
  body.append(el("div", { class: "spinner", text: "Counting real parcels…" }));
  (async () => {
    const p = { ...Builder.where, ...Builder.filters, per_page: 25 };
    if (Builder.cat.api) p.category = Builder.cat.api;
    try {
      const r = await BLRE_API.search(p);
      clear(body);
      renderCount(body, r, "builder");
      if (!r.results.length) {
        body.append(calloutEmpty(`No ${Builder.cat.label.toLowerCase()} in that area yet. Try a broader location or a different type — the builder never invents rows.`));
      } else {
        body.append(resultsTable(r.results));
      }
      body.append(el("div", { class: "row", style: "flex:0; gap:10px; margin-top:6px" }, [
        el("button", { class: "btn ghost", onclick: () => { Builder.step = 1; Builder.cat = null; renderStep(); } }, ["Start over"]),
        el("button", { class: "btn ghost", onclick: () => { State.tab = "map"; route(); } }, ["Open the map"]),
      ]));
    } catch (e) {
      clear(body); body.append(calloutError(e));
    }
  })();
  return body;
}

/* ================================================================= *
 *  COVERAGE (honest map of what the index actually holds)
 * ================================================================= */
async function viewCoverage(main) {
  const v = el("div", { class: "view" });
  v.append(el("h1", { text: "Coverage" }), el("p", { class: "sub", text: "Exactly which states and counties the national index holds today — the honest empty states you'll hit elsewhere are grounded here." }));
  const out = el("div", { id: "covOut" }, [el("div", { class: "spinner", text: "Loading coverage…" })]);
  v.append(out); main.append(v, footer());
  try {
    const cov = State.coverage || (await BLRE_API.coverage()).coverage;
    clear(out);
    const withData = cov.filter((c) => c.properties > 0).sort((a, b) => b.properties - a.properties);
    out.append(el("div", { class: "panel" }, [
      el("div", { class: "count-hero", html: `${num(withData.length)} <small>states with servable public records</small>` }),
    ]));
    const tbl = el("table", {}, [ el("thead", {}, el("tr", {}, [th("State"), th("Counties"), th("Parcels")])) ]);
    const b = el("tbody");
    for (const c of withData) b.append(el("tr", {}, [ td(txt(c.state)), tdNum(num(c.counties)), tdNum(num(c.properties)) ]));
    tbl.append(b);
    out.append(el("div", { class: "panel" }, [tbl]));
  } catch (e) {
    clear(out); out.append(calloutError(e));
  }
}

/* ================================================================= *
 *  SETTINGS — subscriber token + data-source (API base) override.
 *  Both are pure client config stored in localStorage; neither invents
 *  data. The token only raises the worker's per-request row cap.
 * ================================================================= */
function viewSettings(main) {
  const v = el("div", { class: "view" });
  v.append(
    el("h1", { text: "Settings" }),
    el("p", { class: "sub", text: "Local settings for this machine only — nothing here changes what the database returns except your per-request row cap." }),
  );

  /* --- Subscriber token --- */
  const tokMsg = el("div", { class: "map-note", id: "tokMsg" });
  const tokInput = el("input", { id: "s_token", type: "password", placeholder: "blre_…", value: BLRE_API.getToken() });
  const tokStatus = () => {
    tokMsg.className = "map-note";
    tokMsg.textContent = BLRE_API.hasToken()
      ? "A subscriber token is saved on this machine. Run a search to confirm the tier the worker reports."
      : "No token saved — you're on the anonymous preview (25 rows per request). The total count is always real and uncapped.";
  };
  const tokPanel = el("div", { class: "panel" }, [
    el("h2", { text: "Subscriber token" }),
    el("p", { class: "sub", text: "A token raises ONLY the per-request row cap (preview 25 → pro 500 → founder 2000). It does not unlock, add, or change any field — every parcel and the total count are identical with or without it." }),
    el("div", { class: "row" }, [ wrap("Token", tokInput) ]),
    el("div", { class: "row", style: "flex:0; gap:10px; margin-top:12px" }, [
      el("button", { class: "btn", onclick: () => {
        const err = BLRE_API.setToken($("#s_token").value);
        if (err) { tokMsg.className = "map-note bad-inline"; tokMsg.textContent = err; return; }
        tokStatus();
      } }, ["Save token"]),
      el("button", { class: "btn ghost", onclick: () => { BLRE_API.setToken(""); $("#s_token").value = ""; tokStatus(); } }, ["Clear"]),
      el("button", { class: "btn ghost", onclick: () => testConnection(tokMsg) }, ["Test connection"]),
    ]),
    tokMsg,
  ]);

  /* --- Data source (API base URL) override --- */
  const srcMsg = el("div", { class: "map-note", id: "srcMsg" });
  const srcInput = el("input", { id: "s_base", type: "text", placeholder: "https://api.blbestate.com", value: BLRE_API.getOverride() });
  const srcStatus = () => {
    srcMsg.className = "map-note";
    const ov = BLRE_API.getOverride();
    srcMsg.textContent = ov
      ? `Override active. Effective data source: ${BLRE_API.base()}`
      : `Using the shipped default. Effective data source: ${BLRE_API.base()}`;
  };
  const srcPanel = el("div", { class: "panel", style: "margin-top:16px" }, [
    el("h2", { text: "Data source" }),
    el("p", { class: "sub", text: "Advanced / QA only. Point the client at a different worker (e.g. a local wrangler dev). Leave blank to use the shipped live index." }),
    el("div", { class: "row" }, [ wrap("API base URL", srcInput) ]),
    el("div", { class: "row", style: "flex:0; gap:10px; margin-top:12px" }, [
      el("button", { class: "btn", onclick: () => {
        const err = BLRE_API.setBaseOverride($("#s_base").value);
        if (err) { srcMsg.className = "map-note bad-inline"; srcMsg.textContent = err; return; }
        srcStatus();
      } }, ["Save data source"]),
      el("button", { class: "btn ghost", onclick: () => { BLRE_API.setBaseOverride(""); $("#s_base").value = ""; srcStatus(); } }, ["Reset to default"]),
    ]),
    srcMsg,
  ]);

  v.append(tokPanel, srcPanel);
  main.append(v, footer());
  tokStatus();
  srcStatus();
}

// Live probe against the effective data source — reports the real health/stats the
// worker returns; it never fabricates a "connected" state.
async function testConnection(msgNode) {
  msgNode.className = "map-note";
  msgNode.textContent = "Testing the live index…";
  try {
    const s = await BLRE_API.stats();
    msgNode.textContent = `Connected — ${num(s.total_properties)} parcels across ${num(s.states)} states at ${BLRE_API.base()}.`;
  } catch (e) {
    msgNode.className = "map-note bad-inline";
    msgNode.textContent = e && e.offline ? "Can't reach the property database from this machine." : (e && e.message) || "Connection test failed.";
  }
}

/* ================================================================= *
 *  LEAD DETAIL DRAWER
 * ================================================================= */
function drawerScaffold() {
  return el("div", { class: "drawer-back", id: "drawerBack", onclick: (e) => { if (e.target.id === "drawerBack") closeDetail(); } }, [
    el("aside", { class: "drawer", id: "drawer" }),
  ]);
}
function closeDetail() { $("#drawerBack").classList.remove("open"); }
async function openDetail(rec) {
  const back = $("#drawerBack"); back.classList.add("open");
  const d = clear($("#drawer"));
  d.append(
    el("div", { class: "row", style: "flex:0; justify-content:space-between; align-items:center" }, [
      el("div", { style: "font-weight:700; color:var(--ink); font-size:16px", text: txt(rec.owner_name) }),
      el("button", { class: "btn ghost", onclick: closeDetail }, ["Close"]),
    ]),
    kv("Parcel ID", txt(rec.parcel_id)),
    kv("State / County", `${txt(rec.state)} · ${txt(rec.county)}`),
    kv("Situs", [txt(rec.situs_address), txt(rec.situs_city), txt(rec.situs_state), txt(rec.situs_zip)].filter((x) => x !== "—").join(", ") || "—"),
    kv("Mailing", [txt(rec.mailing_address), txt(rec.mailing_city), txt(rec.mailing_state), txt(rec.mailing_zip)].filter((x) => x !== "—").join(", ") || "—"),
    kv("Assessed value", money(rec.assessed_value)),
    kv("Land / Improvement", `${money(rec.land_value)} / ${money(rec.improvement_value)}`),
    kv("Last sale", `${money(rec.last_sale_price)} · ${txt(rec.last_sale_date)}`),
  );
  if (rec.source_url) d.append(el("div", { class: "src", html: `Source: <a href="${encodeURI(rec.source_url)}" target="_blank" rel="noopener">county record</a>` }));
  // 3-mile public-record audit context, if one has been generated for this parcel.
  const auditBox = el("div", { class: "panel", style: "margin-top:16px" }, [el("div", { class: "spinner", text: "Checking for a public-record audit…" })]);
  d.append(auditBox);
  try {
    const a = await BLRE_API.audit({ state: rec.state, id: rec.id, parcel_id: rec.parcel_id });
    clear(auditBox);
    auditBox.append(el("h2", { text: "Public-record audit (3-mi context)" }));
    const au = a.audit || {};
    for (const [k, label] of [["audit_date", "Audit date"], ["nearby_count", "Parcels within 3 mi"], ["median_assessed", "Median assessed (3 mi)"], ["assessed_value", "This parcel assessed"]]) {
      if (au[k] != null) auditBox.append(kv(label, /value|assessed/i.test(label) ? money(au[k]) : num(au[k])));
    }
    auditBox.append(el("div", { class: "map-note", text: "Dated public-record context only — no appraisal, ARV, or profit claim is fabricated." }));
  } catch (e) {
    clear(auditBox);
    auditBox.append(el("div", { class: "map-note", text: e.offline ? "Audit unavailable — database unreachable." : "No dated audit has been generated for this parcel yet." }));
  }
}
function kv(k, v) { return el("div", { class: "kv" }, [ el("div", { class: "k", text: k }), el("div", { class: "v", text: v }) ]); }

function footer() {
  return el("div", { class: "footer-note", text: "Black Label Real Estate · live public-records index · results are real county records — never fabricated." });
}

/* Fallback state list if /v1/coverage is unavailable (matches the Mac app's USStates). */
const US_STATES = ["AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT","VA","WA","WV","WI","WY","DC"];

document.addEventListener("DOMContentLoaded", boot);
