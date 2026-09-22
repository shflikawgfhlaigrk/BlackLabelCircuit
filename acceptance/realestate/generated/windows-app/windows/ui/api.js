// Black Label Real Estate — Windows web client · API layer (single source of truth).
//
// This client is PURE REACH: the product engine is the live Cloudflare Worker over the
// 28M+ public-records index (https://api.blbestate.com). This file is the ONLY place a
// base URL or endpoint path is spelled — never hard-code either at a call site. It mirrors
// the macOS app's APIConfig.swift resolution order exactly so the two clients stay in lock-step.
//
// LAWS honored here:
//   * ZERO FABRICATION — every function returns exactly what the worker returned. No client
//     ever invents a parcel, owner, comp, or ARV. An uncovered area returns count 0 and the
//     UI shows an honest empty state; it does not synthesize rows.
//   * SHIPS EMPTY — no records are bundled. The app is a window onto the live index.
//   * Only PUBLIC query params (state/county/city/zip/parcel/owner/category/value) leave the
//     machine. There is no buyer PII to send — the corpus is public-records-pure.
//
// Base-URL resolution (first usable http(s) URL wins), mirroring APIConfig.swift:
//   1. runtime override   — localStorage["blre.apiBaseURL"]  (Settings field / QA)
//   2. dev env override   — ?apiBase=... query param          (wrangler dev testing)
//   3. shipped prod default — https://api.blbestate.com
//
// Subscriber token: a stored token (localStorage["blre.token"], set in Settings) is
// auto-attached as `Authorization: Bearer <token>` to every request. It is the ONLY
// authenticated surface, and per the worker it does exactly ONE thing — raise the
// per-request ROW CAP (preview 25 → pro 500 → founder 2000; map 500 → 2000 → 5000).
// It does NOT unmask, add, or alter any field: the total count and every field are the
// same with or without a token. The UI never claims more than that (zero fabrication).

const BLRE_API = (() => {
  const PROD_DEFAULT = "https://api.blbestate.com";
  const OVERRIDE_KEY = "blre.apiBaseURL";
  const TOKEN_KEY = "blre.token";

  function usableURL(raw) {
    const s = (raw || "").trim();
    if (!s) return null;
    try {
      const u = new URL(s);
      if (u.protocol !== "http:" && u.protocol !== "https:") return null;
      if (!u.host) return null;
      return u.origin + u.pathname.replace(/\/+$/, "");
    } catch {
      return null;
    }
  }

  function resolveBase() {
    let override = null;
    try { override = localStorage.getItem(OVERRIDE_KEY); } catch { /* private mode */ }
    const env = new URLSearchParams(location.search).get("apiBase");
    for (const cand of [override, env]) {
      const u = usableURL(cand);
      if (u) return u;
    }
    return PROD_DEFAULT;
  }

  function setBaseOverride(value) {
    const raw = (value || "").trim();
    try {
      if (!raw) { localStorage.removeItem(OVERRIDE_KEY); return null; }
      if (!usableURL(raw)) return "Enter a full URL including http(s):// and a host.";
      localStorage.setItem(OVERRIDE_KEY, raw);
      return null;
    } catch {
      return "This browser blocked local storage; the override can't be saved.";
    }
  }

  function storedToken() {
    try { return (localStorage.getItem(TOKEN_KEY) || "").trim(); } catch { return ""; }
  }
  function setToken(value) {
    const raw = (value || "").trim();
    try {
      if (!raw) { localStorage.removeItem(TOKEN_KEY); return null; }
      // No format is invented/enforced beyond "non-empty" — the worker is the sole
      // authority on validity (it returns tier:'preview' for an unknown token, never
      // an error), so we never pre-judge or fabricate a rejection here.
      localStorage.setItem(TOKEN_KEY, raw);
      return null;
    } catch {
      return "This browser blocked local storage; the token can't be saved.";
    }
  }

  const base = () => resolveBase();

  // A typed failure so the UI can tell "the database is unreachable" (retry) apart from
  // "the database answered and rejected the query" (fix the inputs) — mirrors the Mac
  // app's `offline` vs `rejected` split in the List Builder.
  class ApiError extends Error {
    constructor(message, { offline = false, status = 0 } = {}) {
      super(message);
      this.name = "ApiError";
      this.offline = offline;
      this.status = status;
    }
  }

  async function get(path, params, { token } = {}) {
    const url = new URL(base() + path);
    for (const [k, v] of Object.entries(params || {})) {
      if (v !== undefined && v !== null && String(v).trim() !== "") url.searchParams.set(k, v);
    }
    const headers = {};
    const auth = token || storedToken();          // explicit opt wins; else the saved subscriber token
    if (auth) headers.Authorization = "Bearer " + auth;
    let res;
    try {
      res = await fetch(url.toString(), { headers });
    } catch (e) {
      // Network / DNS / CORS-block / TLS — the worker was never reached.
      throw new ApiError("Can't reach the property database. Check your connection and try again.", { offline: true });
    }
    let body = null;
    try { body = await res.json(); } catch { /* non-JSON */ }
    if (!res.ok) {
      const msg = (body && (body.message || body.error)) || `Request failed (${res.status}).`;
      throw new ApiError(msg, { status: res.status });
    }
    return body;
  }

  return {
    ApiError,
    base,
    setBaseOverride,
    getOverride() { try { return localStorage.getItem(OVERRIDE_KEY) || ""; } catch { return ""; } },
    setToken,
    getToken() { return storedToken(); },
    hasToken() { return storedToken() !== ""; },

    // --- Read-only public endpoints (see ~/BlackLabelRealEstateAPI/src/index.js) ---
    health()   { return get("/v1/health"); },
    stats()    { return get("/v1/stats"); },
    coverage() { return get("/v1/coverage"); },
    // area+category search. `params` = { state, county, city, zip, category, owner_name,
    //   min_value, max_value, sold_before, sold_after, north/south/east/west, page, per_page }
    search(params, opts) { return get("/v1/search", params, opts); },
    map(params, opts)    { return get("/v1/map", params, opts); },
    owner(params, opts)  { return get("/v1/owner", params, opts); },
    parcel(params, opts) { return get("/v1/parcel", params, opts); },
    audit(params, opts)  { return get("/v1/property-audit", params, opts); },
  };
})();

// ---------------------------------------------------------------------------
// List-Builder categories — a 1:1 mirror of the macOS app's DatabaseListEngine
// (Sources/DatabaseListEngine.swift). `api` is the worker's honest category
// predicate; `available:false` types are the ones the national index is still
// integrating — they render an HONEST "still integrating" state with a real
// adjacent list, never placeholder rows (LAW: zero fabrication).
// ---------------------------------------------------------------------------
const BLRE_CATEGORIES = [
  { key: "investor",      label: "Investor leads",  api: "absentee_long_hold", available: true,
    blurb: "Absentee owners with 10+ years since the last recorded sale — the classic motivated-seller cut." },
  { key: "absentee",      label: "Absentee owners", api: "absentee", available: true,
    blurb: "Owner's mailing address differs from the property address in the county record." },
  { key: "probate",       label: "Probate",         api: "estate_owner", available: true,
    blurb: "Estate-style recorded owner names (ESTATE OF / EXECUTOR / HEIRS) straight from county rolls." },
  { key: "distressed",    label: "Distressed",      api: "value_spread", available: true,
    blurb: "Last recorded sale sits 25%+ below the current assessed value — a public-record value spread." },
  { key: "vacant",        label: "Vacant land",     api: "vacant_land", available: true,
    blurb: "The assessor carries land value with zero improvement value — vacant land parcels." },
  { key: "teardown",      label: "Teardown lots",   api: "teardown", available: true,
    blurb: "Structure worth far less than the dirt under it — the assessor's own improvement-to-land split." },
  { key: "highEquity",    label: "High equity",     api: "long_hold", available: true,
    blurb: "10+ years since the last recorded sale — the public-record long-tenure equity proxy." },
  { key: "cashBuyers",    label: "Cash buyers",     api: "entity_owner", available: true,
    blurb: "Entity-recorded owners (LLC / trust / corp) — parcels bought and held by investors." },
  { key: "custom",        label: "Custom criteria", api: null, available: true,
    blurb: "Start from the whole index for an area, then narrow with your own filters." },
  { key: "taxDelinquent", label: "Tax delinquent",  api: null, available: false,
    blurb: "County delinquency rolls publish per county; the national index is still integrating them." },
  { key: "preForeclosure", label: "Pre-foreclosure", api: null, available: false,
    blurb: "Lis pendens / notices record at the county clerk; the national index is still integrating them." },
];

if (typeof module !== "undefined" && module.exports) {
  module.exports = { BLRE_API, BLRE_CATEGORIES };
}
