#!/usr/bin/env node
// mcp/server.mjs — blbestate MCP stdio server.
//
// Read-only. Every tool here reads a public-records surface and reports what it
// actually found. No tool writes, harvests, recomputes, deploys, or spends.
//
// Backends
//   1. blbestate property API  — GET /v1/search, GET /v1/property-audit
//                                (base: BLBESTATE_API_BASE, default https://api.blbestate.com)
//   2. route optimizer service — POST BLBESTATE_ROUTE_URL
//                                (default http://127.0.0.1:8766/api/route)
//   3. ./arv.mjs               — the in-repo ARV engine. Imported, never reimplemented.
//
// Honesty contract
//   * A zero result is only ever emitted when the lookup RAN and genuinely found nothing.
//     Every failure path throws, so an error can never be mistaken for "no matching records".
//   * blbestate__get_comps filters `last_sale_price > 0` BEFORE any median is taken. A county
//     that publishes deed dates but no prices (assessed values only) yields an explicit empty
//     result carrying the drop accounting — never a median over nulls.
//   * blbestate__calc_arv delegates to arvFromRows(). Its refusals carry `arv: null` and a
//     machine-readable reason; callers branch on `ok`, never on `arv` being truthy.
//
// Credentials are read from a file at call time and registered with the redactor. No key is
// ever hardcoded, logged, echoed, or returned.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname as pathDirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  createServer,
  listResult,
  emptyResult,
  ToolError,
  loadSecret,
} from "./mcp-kit.mjs";

import {
  arvFromRows,
  money,
  dbl,
  medianInt,
  haversineMiles,
  saleYearMonth,
  MIN_SALE_PRICE,
  LOOKBACK_MONTHS,
} from "./arv.mjs";

const SERVER_NAME = "blbestate";
const SERVER_VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// Configuration — every knob is namespaced to this product alone.
// ---------------------------------------------------------------------------

const API_BASE = (process.env.BLBESTATE_API_BASE || "https://api.blbestate.com").replace(/\/+$/, "");
const ROUTE_URL = process.env.BLBESTATE_ROUTE_URL || "http://127.0.0.1:8766/api/route";
const TOKEN_FILE = process.env.BLBESTATE_TOKEN_FILE || join(homedir(), ".utah", "secrets", "realestate-founder-key.token");

/** Hard ceiling on stops per route request — mirrors the optimizer's own cap. */
const ROUTE_MAX_STOPS = 60;
/** Ceiling on rows any one tool will pull, however high `limit` is set. */
const MAX_ROWS = 2000;
/** The API caps per_page at the token's tier (preview 25 / pro 500 / founder 2000). */
const REQUEST_PAGE_SIZE = 500;
const MCP_MANIFEST_FILE = "mcp-manifest.json";
const MCP_REQUIRED_FILES = ["server.mjs", "mcp-kit.mjs", "arv.mjs"];

function sha256HexForFile(filePath) {
  const bytes = readFileSync(filePath);
  return createHash("sha256").update(bytes).digest("hex");
}

function assertBundledMcpIntegrity() {
  const bundleDir = pathDirname(fileURLToPath(import.meta.url));
  const manifestPath = join(bundleDir, MCP_MANIFEST_FILE);
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (err) {
    throw new ToolError(
      `Blocked MCP startup: MCP manifest is missing or unreadable at ${manifestPath}. This build has no verified MCP integrity baseline.`,
      { code: "MCP_MANIFEST_MISSING", cause: err }
    );
  }

  const files = manifest?.files;
  if (!files || typeof files !== "object") {
    throw new ToolError(
      `Blocked MCP startup: MCP manifest at ${manifestPath} is malformed (no 'files' map).`,
      { code: "MCP_MANIFEST_MALFORMED" }
    );
  }

  if (manifest.algorithm && manifest.algorithm !== "sha256") {
    throw new ToolError(`Blocked MCP startup: MCP manifest uses unsupported algorithm ${manifest.algorithm}.`, {
      code: "MCP_MANIFEST_UNSUPPORTED_ALG",
    });
  }

  for (const name of MCP_REQUIRED_FILES) {
    const wanted = files[name];
    if (typeof wanted !== "string" || !/^[0-9a-f]{64}$/i.test(wanted)) {
      throw new ToolError(
        `Blocked MCP startup: MCP manifest is missing a valid SHA-256 entry for ${name}.`,
        { code: "MCP_MANIFEST_BAD_ENTRY" }
      );
    }
    const got = sha256HexForFile(join(bundleDir, name));
    if (got !== wanted) {
      throw new ToolError(`Blocked MCP startup: local MCP file ${name} failed manifest integrity check.`, {
        code: "MCP_MANIFEST_MISMATCH",
        details: { file: name, expected_sha256: wanted, actual_sha256: got },
      });
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/**
 * Read the subscriber token from disk, if one is present. Absence is NOT an error:
 * the API serves an anonymous preview tier. The tier actually granted is echoed in
 * every result so a caller can never mistake a 25-row preview cap for the whole county.
 */
function authHeader() {
  const token = loadSecret(TOKEN_FILE, { json: false, required: false });
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function apiGet(path, params, signal) {
  const url = new URL(API_BASE + path);
  for (const [k, v] of Object.entries(params || {})) {
    if (v === undefined || v === null || v === "") continue;
    url.searchParams.set(k, String(v));
  }
  const shown = `${path}?${url.searchParams.toString()}`;

  let res;
  try {
    res = await fetch(url, { headers: { Accept: "application/json", ...authHeader() }, signal });
  } catch (err) {
    throw new ToolError(
      `Property API request to ${shown} failed at the network layer: ${err?.message || String(err)}. ` +
        `No data was retrieved — this is a failure, not an empty result.`,
      { code: "API_UNREACHABLE", cause: err, details: { base: API_BASE, path } }
    );
  }

  const text = await res.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    throw new ToolError(
      `Property API returned HTTP ${res.status} for ${shown} with a non-JSON body (first 200 chars): ${text.slice(0, 200)}`,
      { code: "API_BAD_RESPONSE", details: { http_status: res.status } }
    );
  }

  if (res.status === 404 && body?.error === "not_found") return { notFound: true, body };
  if (!res.ok) {
    throw new ToolError(
      `Property API returned HTTP ${res.status} for ${shown}: ${body?.message || body?.error || "no message"}`,
      { code: "API_HTTP_ERROR", details: { http_status: res.status, api_error: body?.error, api_message: body?.message } }
    );
  }
  return { notFound: false, body };
}

/**
 * Page /v1/search until `limit` rows are collected or the source is exhausted.
 * Returns the real per-page cap the tier granted, so a truncated pull is visible.
 */
async function searchRows(params, { limit, signal }) {
  const want = Math.min(Math.max(1, limit | 0), MAX_ROWS);
  const rows = [];
  let total = null;
  let tier = null;
  let masked = null;
  let pages = 0;
  let grantedPageSize = null;

  for (let page = 1; rows.length < want; page += 1) {
    const per = Math.min(REQUEST_PAGE_SIZE, want - rows.length);
    const { notFound, body } = await apiGet("/v1/search", { ...params, per_page: per, page }, signal);

    // A 404 not_found on the SEARCH route is a broken lookup (wrong base URL, renamed route,
    // a gateway answering for the API), never "this area holds no parcels" — the search route
    // answers an empty area with HTTP 200 and results: []. Only /v1/property-audit legitimately
    // 404s. Swallowing this would turn a failed request into a confident zero result.
    if (notFound) {
      throw new ToolError(
        `Property API returned HTTP 404 not_found for /v1/search (page ${page}). The search route reports an ` +
          `empty area as HTTP 200 with results: [], so a 404 here means the request did not reach a working ` +
          `search endpoint. No data was retrieved — this is a failure, not an empty result.`,
        { code: "API_ROUTE_NOT_FOUND", details: { base: API_BASE, path: "/v1/search", page } }
      );
    }
    pages += 1;

    // An absent/garbage `total` means UNKNOWN, not zero. Coercing it to 0 both ended the page
    // loop after the first page and reported the truncated pull as complete (truncated: false).
    const rawTotal = body?.total;
    const parsedTotal =
      rawTotal === undefined || rawTotal === null || rawTotal === "" || !Number.isFinite(Number(rawTotal))
        ? null
        : Number(rawTotal);
    if (parsedTotal !== null) total = parsedTotal;

    tier = body?.tier ?? tier;
    masked = body?.masked ?? masked;

    // `results` must actually be a list. Coercing a null/object payload to [] would report a
    // malformed response as a verified zero result — the one thing this server must never do.
    if (!Array.isArray(body?.results)) {
      throw new ToolError(
        `Property API returned HTTP 200 for /v1/search (page ${page}) but "results" was ${
          body?.results === null ? "null" : typeof body?.results
        }, not an array. No rows were retrieved — reporting that as an empty area would be a lie.`,
        { code: "API_BAD_RESPONSE", details: { path: "/v1/search", page, results_type: body?.results === null ? "null" : typeof body?.results } }
      );
    }
    const got = body.results;
    // The tier caps per_page below what we asked for (preview 25 / pro 500 / founder 2000).
    // Exhaustion must be judged against the page size the API actually GRANTED — comparing
    // against the size we requested would stop after one short page and silently report a
    // 25-row slice of a 21,000-row county as the whole answer.
    if (grantedPageSize === null) grantedPageSize = Number(body?.per_page) || got.length || per;
    rows.push(...got);
    const effectivePer = Math.min(per, grantedPageSize || per);
    if (!got.length || got.length < effectivePer) break;
    if (total !== null && rows.length >= total) break;
    if (pages >= 100) break; // bounded even at the 25-row preview page size
  }

  return { rows: rows.slice(0, want), total, tier, masked, pages, page_size_granted: grantedPageSize };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const AREA_KEYS = ["county", "city", "zip", "address", "owner_name", "q"];

/** The API refuses category/value filters without an area. Say so before spending a request. */
function requireArea(args) {
  const hasArea = args.state || AREA_KEYS.some((k) => args[k]);
  if (!hasArea) {
    throw new ToolError(
      "A location is required: supply at least one of state, county, city, zip, address, owner_name, or q. " +
        "An unbounded scan of the national roll is refused.",
      { code: "AREA_REQUIRED" }
    );
  }
}

/** ISO day `monthsBack` before `now`, used as the API's server-side sold_after filter. */
function soldAfterDay(monthsBack, now = new Date()) {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - monthsBack, now.getUTCDate()));
  return d.toISOString().slice(0, 10);
}

function searchParamsFrom(a) {
  return {
    state: a.state ? String(a.state).toUpperCase() : undefined,
    county: a.county,
    city: a.city,
    zip: a.zip,
    address: a.address,
    owner_name: a.owner_name,
    q: a.q,
    category: a.category,
    min_value: a.min_value,
    max_value: a.max_value,
    sold_before: a.sold_before,
    sold_after: a.sold_after,
    absentee: a.absentee ? "1" : undefined,
    owner_occupied: a.owner_occupied ? "1" : undefined,
  };
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

const searchParcels = {
  name: "blbestate__search_parcels",
  description:
    "Search the public-records parcel index by location, owner, address, category or assessed-value band. " +
    "Returns real county rows only — it never geocodes, infers, or invents a parcel. `total` is the true " +
    "match count in the index; `count` is how many rows this call actually retrieved under the tier's row cap.",
  timeoutMs: 120_000,
  inputSchema: {
    type: "object",
    properties: {
      state: { type: "string", description: "Two-letter state code, e.g. AZ." },
      county: { type: "string", description: "County name, substring match." },
      city: { type: "string", description: "Situs city, substring match." },
      zip: { type: "string", description: "Situs ZIP, exact match." },
      address: { type: "string", description: "Situs or mailing address, substring match." },
      owner_name: { type: "string", description: "Owner name, substring match." },
      q: { type: "string", description: "Free text across owner name, situs address and mailing address." },
      category: { type: "string", description: "Whitelisted list category. An unknown value is rejected by the API, never silently widened." },
      min_value: { type: "integer", description: "Minimum assessed value." },
      max_value: { type: "integer", description: "Maximum assessed value." },
      sold_after: { type: "string", description: "Recorded sale on/after this YYYY-MM-DD." },
      sold_before: { type: "string", description: "Recorded sale on/before this YYYY-MM-DD." },
      absentee: { type: "boolean", description: "Only parcels whose mailing address is away from the situs address." },
      owner_occupied: { type: "boolean", description: "Only parcels whose mailing address matches the situs address." },
      limit: { type: "integer", description: `Rows to retrieve, 1-${MAX_ROWS}. Default 25. The API also caps per-page by tier.` },
    },
    required: [],
  },
  async handler(args, { signal }) {
    requireArea(args);
    const params = searchParamsFrom(args);
    const r = await searchRows(params, { limit: args.limit ?? 25, signal });

    return listResult(r.rows, {
      what: "parcel records",
      source: `${API_BASE}/v1/search`,
      query: Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== "")),
      total_matching_in_index: r.total, // null = the API did not report one; unknown, not zero
      retrieved: r.rows.length,
      truncated: r.total === null ? null : r.rows.length < r.total, // null = unknowable without a total
      access_tier: r.tier,
      fields_masked: r.masked,
      pages_fetched: r.pages,
      page_size_granted: r.page_size_granted,
      reason:
        r.rows.length === 0
          ? r.total === null
            ? `The index was queried successfully and returned no rows; the API reported no total, so the true match count is unknown.`
            : `The index was queried successfully and holds ${r.total} rows matching these filters.`
          : undefined,
    });
  },
};

const getComps = {
  name: "blbestate__get_comps",
  description:
    "Recorded sold comparables near a subject, from the county deed roll. Rows whose last_sale_price is " +
    "null, zero or negative are dropped BEFORE any median is computed. When no priced sale survives, the " +
    "tool returns an explicit verified-empty result with the full drop accounting — it never medians over " +
    "nulls and never reports 0 as a price. Distance is filled only when both the subject and the row carry " +
    "coordinates; it is never estimated. When a radius is enforced, a row with no coordinates is DROPPED and " +
    "counted — the ring is only ever labelled over rows that were actually measured.",
  timeoutMs: 180_000,
  inputSchema: {
    type: "object",
    properties: {
      state: { type: "string", description: "Two-letter state code, e.g. AZ. Strongly recommended." },
      county: { type: "string" },
      city: { type: "string" },
      zip: { type: "string" },
      address: { type: "string", description: "Substring match, to pull comps on a specific street." },
      subject_lat: { type: "number", description: "Subject latitude. With subject_lng, enables real distance and the radius filter." },
      subject_lng: { type: "number", description: "Subject longitude." },
      radius_miles: { type: "number", description: "Drop comps beyond this ring, and comps with no coordinates (they cannot be shown to be inside it). Requires subject_lat and subject_lng; ignored without them, and the result then says so." },
      lookback_months: { type: "integer", description: `Recorded-sale window, applied server-side as sold_after. Default ${LOOKBACK_MONTHS}. 0 disables it.` },
      min_sale_price: { type: "integer", description: `Arm's-length floor. Default ${MIN_SALE_PRICE}; sub-floor nominal transfers are dropped and counted.` },
      limit: { type: "integer", description: `Rows to pull from the index before filtering, 1-${MAX_ROWS}. Default 200.` },
    },
    required: [],
  },
  async handler(args, { signal }) {
    requireArea(args);

    const lookback = Number.isInteger(args.lookback_months) ? args.lookback_months : LOOKBACK_MONTHS;
    const floor = Number.isInteger(args.min_sale_price) ? args.min_sale_price : MIN_SALE_PRICE;
    const now = new Date();
    const soldAfter = lookback > 0 ? soldAfterDay(lookback, now) : undefined;

    const params = { ...searchParamsFrom(args), sold_after: args.sold_after || soldAfter };
    const pulled = await searchRows(params, { limit: args.limit ?? 200, signal });

    const sLat = dbl(args.subject_lat);
    const sLng = dbl(args.subject_lng);
    const haveSubjectCoords = sLat !== null && sLng !== null;
    const radius = dbl(args.radius_miles);

    // A ring is only a ring if every row in it was measured. `radius_enforced` is the single
    // switch: when it is on, a row that cannot be placed is DROPPED, never kept at unknown
    // distance under a `radius_miles: n` label. Same rule as arv.mjs assessedAreaEstimate()
    // (`withoutLocation += 1; continue;`), which this used to disagree with.
    // Live magnitude (psql :5433, blacklabel, 2026-08-03): national_property_records_fl holds
    // 392,715 rows priced >$10,000, of which 11,868 (3.0%) carry no lat — those are the rows that
    // used to pass an unenforced ring. AZ: 19. GA/CA/AL: 0 today.
    const radiusEnforced = haveSubjectCoords && radius !== null && radius > 0;

    const dropped = { no_sale_price: 0, below_price_floor: 0, no_coordinates: 0, outside_radius: 0, undated: 0 };
    const comps = [];

    for (const row of pulled.rows) {
      // ── the price gate runs FIRST, before anything is aggregated ──────────────
      const price = money(row?.last_sale_price); // null for null / "" / 0 / sub-dollar / non-finite
      if (price === null) {
        dropped.no_sale_price += 1;
        continue;
      }
      if (price < floor) {
        dropped.below_price_floor += 1;
        continue;
      }

      const lat = dbl(row?.lat);
      const lng = dbl(row?.lng);
      let miles = null;
      if (lat === null || lng === null) {
        // Unplaceable row. Under an enforced ring it cannot be shown to be inside it, so it goes.
        if (radiusEnforced) {
          dropped.no_coordinates += 1;
          continue;
        }
        // No ring asked for: the row is kept with distance_miles null, and the window says so.
      } else if (haveSubjectCoords) {
        miles = haversineMiles(sLat, sLng, lat, lng);
        if (radiusEnforced && miles > radius) {
          dropped.outside_radius += 1;
          continue;
        }
      }

      const ym = saleYearMonth(row?.last_sale_date);
      if (!ym) dropped.undated += 1;

      comps.push({
        record_id: row?.id ?? null,
        parcel_id: row?.parcel_id ?? null,
        state: row?.state ?? null,
        county: row?.county ?? null,
        situs_address: row?.situs_address ?? null,
        situs_zip: row?.situs_zip ?? null,
        sale_price: price,
        sale_year: ym?.year ?? null,
        sale_month: ym?.month ?? null,
        sale_date_raw: row?.last_sale_date ?? null,
        assessed_value: row?.assessed_value ?? null,
        lat,
        lng,
        distance_miles: miles === null ? null : Number(miles.toFixed(4)),
      });
    }

    comps.sort((a, b) => {
      if (a.distance_miles === null && b.distance_miles !== null) return 1;
      if (b.distance_miles === null && a.distance_miles !== null) return -1;
      if (a.distance_miles !== null && b.distance_miles !== null && a.distance_miles !== b.distance_miles) {
        return a.distance_miles - b.distance_miles;
      }
      return (b.sale_year ?? 0) - (a.sale_year ?? 0) || (b.sale_month ?? 0) - (a.sale_month ?? 0);
    });

    const considered = pulled.rows.length;
    const kept = comps.length;
    const accounting = {
      rows_considered: considered,
      rows_kept: kept,
      dropped,
      accounting_balances: kept + Object.values(dropped).reduce((s, n) => s + n, 0) - dropped.undated === considered,
    };

    const window = {
      lookback_months: lookback,
      sold_after: params.sold_after ?? null,
      min_sale_price: floor,
      // radius_miles is stated only when the ring was actually ENFORCED on every kept row.
      // A ring requested without subject coordinates is reported as requested-but-not-applied
      // rather than silently echoed back as if it had filtered anything.
      radius_miles: radiusEnforced ? radius : null,
      radius_enforced: radiusEnforced,
      radius_miles_requested: radius ?? null,
      distance_available: haveSubjectCoords,
    };

    const meta = {
      query: Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== "")),
      total_matching_in_index: pulled.total,
      access_tier: pulled.tier,
      pages_fetched: pulled.pages,
      window,
      selection: accounting,
    };

    // ── verified honest-empty: the pull RAN, and no priced sale survived ────────
    if (kept === 0) {
      const parts = [];
      if (dropped.no_sale_price) parts.push(`${dropped.no_sale_price} carried no recorded sale price`);
      if (dropped.below_price_floor) parts.push(`${dropped.below_price_floor} were below the $${floor.toLocaleString("en-US")} arm's-length floor`);
      if (dropped.outside_radius) parts.push(`${dropped.outside_radius} fell outside the ${radius}-mile ring`);
      if (dropped.no_coordinates) parts.push(`${dropped.no_coordinates} carried no coordinates and so could not be shown to be inside the ${radius}-mile ring`);
      return emptyResult({
        what: "priced sold comparables",
        source: `${API_BASE}/v1/search`,
        reason: considered === 0
          ? "The index returned no rows at all for this area and sale window."
          : `${considered} nearby recorded row(s) were retrieved and every one was rejected before any median was taken (${parts.join("; ")}). No median was computed over nulls, and no price was reported as 0.`,
        median_sale_price: null,
        ...meta,
      });
    }

    const prices = comps.map((c) => c.sale_price);
    return listResult(comps, {
      what: "priced sold comparables",
      source: `${API_BASE}/v1/search`,
      median_sale_price: medianInt(prices), // integer median, over the priced set only
      min_sale_price_seen: Math.min(...prices),
      max_sale_price_seen: Math.max(...prices),
      priced_comps: kept,
      ...meta,
    });
  },
};

const getPropertyAudit = {
  name: "blbestate__get_property_audit",
  description:
    "Fetch the latest stored public-record audit for one parcel: 3-mile neighbour statistics, assessed/" +
    "component consistency flags, and the explicit list of reasons a field is unknown. Read-only — it " +
    "returns an audit that was already computed and stored; it never recomputes or backfills one. A parcel " +
    "with no stored audit reports that plainly instead of returning an empty-looking object.",
  timeoutMs: 60_000,
  inputSchema: {
    type: "object",
    properties: {
      state: { type: "string", description: "Two-letter state code. Required." },
      record_id: { type: "integer", description: "Numeric record id from search results. Supply this or parcel_id." },
      parcel_id: { type: "string", description: "County parcel id. Supply this or record_id." },
    },
    required: ["state"],
  },
  async handler(args, { signal }) {
    const state = String(args.state || "").toUpperCase();
    if (!state) throw new ToolError("state is required.", { code: "STATE_REQUIRED" });
    if (!args.record_id && !args.parcel_id) {
      throw new ToolError("Supply record_id or parcel_id — an audit is per parcel, not per area.", { code: "IDENTIFIER_REQUIRED" });
    }

    const params = { state, record_id: args.record_id, parcel_id: args.parcel_id };
    const { notFound, body } = await apiGet("/v1/property-audit", params, signal);

    if (notFound) {
      return {
        ok: true,
        status: "empty",
        what: "stored public-record audit",
        source: `${API_BASE}/v1/property-audit`,
        found: false,
        audit: null,
        query: { state, record_id: args.record_id ?? null, parcel_id: args.parcel_id ?? null },
        reason:
          "The lookup ran and the API returned not_found: no audit row is stored for this parcel in this state. " +
          "That is a genuine absence, not a request failure. This tool does not compute audits.",
        note: "Verified zero result: the lookup ran successfully and found nothing. This is not a failure and not a placeholder.",
      };
    }

    const audit = body?.audit;
    if (!audit || typeof audit !== "object") {
      throw new ToolError(
        `Property API returned HTTP 200 for the audit lookup but no audit object. Reporting that as "no audit" would be a lie.`,
        { code: "AUDIT_MALFORMED", details: { keys_returned: Object.keys(body || {}) } }
      );
    }

    return {
      ok: true,
      status: "ok",
      what: "stored public-record audit",
      source: `${API_BASE}/v1/property-audit`,
      found: true,
      access_tier: body?.tier ?? null,
      fields_masked: body?.masked ?? null,
      query: { state, record_id: args.record_id ?? null, parcel_id: args.parcel_id ?? null },
      audit,
    };
  },
};

const planRoute = {
  name: "blbestate__plan_route",
  description:
    `Order up to ${ROUTE_MAX_STOPS} stops into a drive route via the local optimizer service, returning ` +
    "per-driver legs, miles, minutes and a maps link. Stops that carry lat/lng are preferred: they are sent " +
    "as structured {lat,lng} and placed exactly as supplied — no geocoder is consulted, so they cost no " +
    "network, cannot drift, and cannot be made unroutable by a Nominatim error. Address-only stops go to " +
    "Nominatim at ~1 request/second and can miss outright. " +
    "The optimizer never fabricates a coordinate — a stop it cannot place is returned in `unroutable`.",
  timeoutMs: 240_000,
  inputSchema: {
    type: "object",
    properties: {
      stops: {
        type: "array",
        description:
          `The places to visit, max ${ROUTE_MAX_STOPS}. Each: { label?, address?, lat?, lng? }. ` +
          "Supply lat/lng whenever you have them — search results carry both.",
      },
      config: { type: "string", enum: ["canvasser", "fleet"], description: "canvasser = one driver (default). fleet = split across vehicles." },
      vehicles: { type: "integer", description: "Drivers when config=fleet, 2-8." },
      depot: { type: "string", description: "Optional start/end address for the fleet round trip." },
    },
    required: ["stops"],
  },
  async handler(args, { signal }) {
    const stops = Array.isArray(args.stops) ? args.stops : [];
    if (!stops.length) throw new ToolError("stops is empty — there is nothing to route.", { code: "NO_STOPS" });
    if (stops.length > ROUTE_MAX_STOPS) {
      throw new ToolError(
        `${stops.length} stops exceeds the ${ROUTE_MAX_STOPS}-stop hard cap. Refusing rather than silently ` +
          `dropping the tail: split the list and route it in batches.`,
        { code: "STOP_CAP_EXCEEDED", details: { supplied: stops.length, cap: ROUTE_MAX_STOPS } }
      );
    }

    // Build what each stop is sent as. Coordinates win over free text, and a coordinate is sent
    // STRUCTURED ({lat,lng,label}) rather than as a "lat,lng" text line: /api/route places a
    // structured stop directly, where a text line used to be searched by Nominatim and came back
    // snapped to the nearest named feature (measured 2026-08-03 over the optimizer's own cache:
    // 89 coordinate-shaped keys, median 20.3 m of drift, max 230.2 m). `label` is still the
    // "lat,lng" line because the service echoes labels and the mapping below claims them by it.
    const sent = [];
    const prepared = [];
    let byCoord = 0;
    let byAddress = 0;
    for (const [i, s] of stops.entries()) {
      const lat = dbl(s?.lat);
      const lng = dbl(s?.lng);
      const addr = typeof s?.address === "string" ? s.address.trim() : "";
      let line;
      if (lat !== null && lng !== null) {
        line = `${lat.toFixed(6)},${lng.toFixed(6)}`;
        sent.push({ lat, lng, label: line });
        byCoord += 1;
      } else if (addr) {
        line = addr;
        sent.push(addr);
        byAddress += 1;
      } else {
        throw new ToolError(
          `stops[${i}] has neither lat/lng nor a non-empty address. A stop cannot be placed from a label alone, ` +
            `and inventing a coordinate is not an option.`,
          { code: "STOP_NOT_LOCATABLE", details: { index: i, label: s?.label ?? null } }
        );
      }
      prepared.push({
        index: i,
        label: typeof s?.label === "string" && s.label.trim() ? s.label.trim() : line,
        sent_as: line,
        located_by: lat !== null && lng !== null ? "coordinates" : "address_geocode",
      });
    }

    const payload = { source: "paste", config: args.config === "fleet" ? "fleet" : "canvasser", addresses: sent };
    if (payload.config === "fleet") payload.vehicles = Math.max(2, Math.min(Number(args.vehicles) || 2, 8));
    if (typeof args.depot === "string" && args.depot.trim()) payload.depot = args.depot.trim();

    let res;
    try {
      res = await fetch(ROUTE_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal,
      });
    } catch (err) {
      throw new ToolError(
        `BLOCKER — the route optimizer service at ${ROUTE_URL} is unreachable (${err?.message || String(err)}). ` +
          `No route was produced. This tool will not start or restart that service; bring it up out of band and retry.`,
        { code: "ROUTE_SERVICE_DOWN", cause: err, details: { route_url: ROUTE_URL, stops_supplied: stops.length } }
      );
    }

    const text = await res.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      throw new ToolError(
        `Route service returned HTTP ${res.status} with a non-JSON body (first 200 chars): ${text.slice(0, 200)}`,
        { code: "ROUTE_BAD_RESPONSE", details: { http_status: res.status } }
      );
    }
    if (!res.ok || body?.error) {
      throw new ToolError(`Route service refused the request (HTTP ${res.status}): ${body?.error || "no message"}`, {
        code: "ROUTE_REFUSED",
        details: { http_status: res.status, route_error: body?.error ?? null },
      });
    }

    // Map the service's echoed lines back to the caller's own stops.
    const pool = new Map();
    for (const p of prepared) {
      if (!pool.has(p.sent_as)) pool.set(p.sent_as, []);
      pool.get(p.sent_as).push(p);
    }
    const claim = (line) => pool.get(line)?.shift() ?? null;

    const routes = (Array.isArray(body.routes) ? body.routes : []).map((r) => ({
      driver: r.driver,
      miles: r.miles,
      minutes: r.minutes,
      maps_url: r.maps_url,
      stops: (Array.isArray(r.stops) ? r.stops : []).map((s) => {
        const p = claim(s.label);
        return {
          order_label: p ? p.label : s.label,
          sent_as: s.label,
          input_index: p ? p.index : null,
          located_by: p ? p.located_by : null,
        };
      }),
    }));

    const unroutable = (Array.isArray(body.unroutable) ? body.unroutable : []).map((line) => {
      const p = claim(line);
      return { order_label: p ? p.label : line, sent_as: line, input_index: p ? p.index : null, located_by: p ? p.located_by : null };
    });

    return {
      ok: true,
      status: routes.length ? "ok" : "empty",
      what: "optimized drive route",
      source: ROUTE_URL,
      config: body.config,
      vehicles: body.vehicles,
      stops_in: body.stops_in,
      routable: body.routable,
      unroutable,
      total_miles: body.total_miles,
      total_minutes: body.total_minutes,
      max_driver_minutes: body.max_driver_minutes,
      naive_miles: body.naive_miles ?? null,
      saved_miles: body.saved_miles ?? null,
      saved_pct: body.saved_pct ?? null,
      routes,
      geocoding: {
        stops_placed_by_coordinates: byCoord,
        stops_needing_address_geocode: byAddress,
        stop_cap: ROUTE_MAX_STOPS,
        note:
          "Coordinate stops are sent structured ({lat,lng,label}) and placed exactly as supplied: no " +
          "Nominatim call, no cache entry, no drift, and they cannot be made unroutable by a geocoder " +
          "outage. Before 2026-08-03 they were sent as a 6-decimal 'lat,lng' text line and Nominatim " +
          "searched it, returning the nearest named feature instead (median 20.3 m off, max 230.2 m " +
          "over the optimizer's own 89 coordinate-shaped cache keys). Address-only stops still pay " +
          "~1s each and can miss outright (unit-numbered addresses commonly do).",
      },
    };
  },
};

const calcArv = {
  name: "blbestate__calc_arv",
  description:
    "Derive ARV from recorded sold comps for a subject property, using this repo's verified comps engine. " +
    "Supply `rows` (raw county rows) or `search` (pull them live). Refuses with arv:null and a machine-readable " +
    "reason when the data is too thin — it never returns 0, never invents a figure, and never claims the county " +
    "roll was empty when rows arrived and were dropped. Branch on `ok`, never on `arv` being truthy. " +
    "NON-DISCLOSURE STATES (AL, TX, UT, ...) publish no sale prices at all, so the sold-comp basis can never " +
    "fire there; pass allow_assessed_estimate:true to fall back to a clearly-labeled median of the county's " +
    "OWN published appraisals. That result carries isComp:false and basis 'assessedAreaEstimate' — it is an " +
    "area read, never a comp, and must never be rendered with a comp seal.",
  timeoutMs: 180_000,
  inputSchema: {
    type: "object",
    properties: {
      subject: {
        type: "object",
        description: "{ sqft?, lat?, lng? }. sqft below 200 disables the $/sqft basis. lat/lng enable real comp distances.",
      },
      rows: { type: "array", description: "Raw county / public-records rows, as returned by blbestate__search_parcels." },
      allow_assessed_estimate: {
        type: "boolean",
        description:
          "Default false. A FALLBACK ONLY: it can never change a sold-comp answer. The rows are always pulled " +
          "sold-filtered first; only if the comp tiers then refuse is the roll re-pulled unfiltered, and that " +
          "second pass can produce nothing but the assessed estimate. The estimate is the MEDIAN county APPRAISED " +
          "value (land + improvement) — a bare assessed_value is a statutory ratio of market value (AL Class II is " +
          "20%) and is REFUSED with reason 'assessed_ratio_not_a_valuation' rather than published as an ARV. " +
          "Returns isComp:false, isAreaRead:true and basis 'assessedAreaEstimate' — a labeled area read, NOT a " +
          "comp and NOT an appraisal. Pass subject.lat/lng to scope it to a ring around the parcel; without them " +
          "it is a read of the supplied rows, warns 'assessed_estimate_not_localized_to_subject', and is not a " +
          "valuation of any one property.",
      },
      search: {
        type: "object",
        description:
          "Pull the rows live instead of pasting them: { state, county?, city?, zip?, address?, limit? }. " +
          "A sold_after filter for the lookback window is applied automatically.",
      },
      radius_miles: {
        type: "number",
        description:
          "The ring stated on the result. On the SOLD-COMP tiers the engine ECHOES this and never uses it in " +
          "arithmetic — it does not drop a far comp; to value on a real ring, pull rows through " +
          "blbestate__get_comps with radius_miles set and pass those rows here. The tier-3 assessed area read " +
          "DOES filter on it (default ~3 miles) whenever subject.lat/lng are supplied.",
      },
      lookback_months: { type: "integer", description: `Recorded-sale window, enforced. Default ${LOOKBACK_MONTHS}.` },
    },
    required: [],
  },
  async handler(args, { signal }) {
    const subject = args.subject && typeof args.subject === "object" && !Array.isArray(args.subject) ? args.subject : {};
    const lookback = Number.isInteger(args.lookback_months) ? args.lookback_months : LOOKBACK_MONTHS;

    const wantAssessed = args.allow_assessed_estimate === true;
    const value = (rowSet, allowAssessed) =>
      arvFromRows({
        subject,
        rows: rowSet,
        options: {
          radiusMiles: args.radius_miles,
          lookbackMonths: lookback,
          now: new Date(), // drives the 36-month window AND the future-date guard
          // OPT-IN tier 3. Off unless the caller asks, so a refusal never silently becomes an
          // `ok: true` off a non-comp basis. Reachable only after the sold-comp tiers fail.
          allowAssessedEstimate: allowAssessed,
        },
      });

    let rows = Array.isArray(args.rows) ? args.rows : null;
    let provenance;
    let r;

    if (rows === null && args.search && typeof args.search === "object") {
      const s = args.search;
      requireArea(s);
      // A caller-supplied `sold_after` is an explicit instruction and is never re-pulled around;
      // only OUR automatic lookback filter may be lifted for the tier-3 fallback.
      const autoSoldAfter = !s.sold_after && lookback > 0;
      const soldAfter = s.sold_after || (autoSoldAfter ? soldAfterDay(lookback) : undefined);
      const params = { ...searchParamsFrom(s), sold_after: soldAfter };
      const queryOf = (p) => Object.fromEntries(Object.entries(p).filter(([, v]) => v !== undefined && v !== ""));

      // PASS 1 — always sold-filtered. Dropping `sold_after` up front (the previous behaviour when
      // allow_assessed_estimate was set) corrupted the SOLD-COMP tiers in disclosure states: the
      // comp tiers then fired off an arbitrary unfiltered remnant and returned basis
      // `soldCompsMedian` with `isComp: true`, so the flag silently re-valued a real comp result
      // (AZ/PHOENIX 603,490 → 275,000, -54%) with nothing naming the flag as the cause. The flag
      // is a FALLBACK; it must never be able to change a comp answer.
      const pulled = await searchRows(params, { limit: s.limit ?? 200, signal });
      rows = pulled.rows;
      provenance = {
        rows_source: `${API_BASE}/v1/search`,
        query: queryOf(params),
        rows_retrieved: rows.length,
        total_matching_in_index: pulled.total,
        access_tier: pulled.tier,
        pages_fetched: pulled.pages,
      };
      r = value(rows, wantAssessed && !autoSoldAfter);

      // PASS 2 — only after the comp tiers have actually refused, and only to reach tier 3. In a
      // non-disclosure state `sold_after` matches 0 rows, so the estimator would otherwise be
      // handed an empty set and blamed for a filter the caller never wanted. A comp result off
      // this unfiltered pull is exactly the corruption pass 1 exists to prevent, so it is
      // discarded: pass 2 can only ever contribute an `assessedAreaEstimate`.
      if (!r.ok && wantAssessed && autoSoldAfter) {
        const wide = { ...searchParamsFrom(s), sold_after: undefined };
        const pulled2 = await searchRows(wide, { limit: s.limit ?? 200, signal });
        const r2 = value(pulled2.rows, true);
        const adopted = r2.ok && r2.basis === "assessedAreaEstimate";

        // The fallback pull is recorded WHENEVER it runs, adopted or not. Attaching it only on
        // adoption made a second HTTP call invisible: a caller could not tell an `ok:false` that
        // never tried the fallback from one that tried, pulled real rows, and declined them —
        // and the refusal it was handed came from pass 1, computed over the (usually empty)
        // sold-filtered remnant.
        const fallback = {
          reason:
            "sold-comp tiers refused on the sold-filtered pull; re-pulled without sold_after for the tier-3 assessed area read only",
          query: queryOf(wide),
          rows_retrieved: pulled2.rows.length,
          total_matching_in_index: pulled2.total,
          pages_fetched: pulled2.pages,
          outcome: adopted ? "adopted" : "declined",
        };
        if (!adopted && r2.ok) {
          // Pass 2 produced something — just not something this pass is allowed to publish. Name
          // the basis and stop: its note/arv describe a valuation taken off an unfiltered pull,
          // and echoing that prose here would put the discarded answer back in front of a caller.
          fallback.declined_because =
            `the widened pull produced basis '${r2.basis}', not an assessed area read — a comp basis off an ` +
            `unfiltered pull is discarded by design (it would let a fallback flag re-value a comp answer)`;
          fallback.declined_basis = r2.basis ?? null;
        } else if (!adopted) {
          // Pass 2 refused too. Its reason/note are the only honest description of the rows that
          // actually arrived, so they travel with the pull that fetched them.
          fallback.declined_because = "the widened pull could not produce an assessed area read either";
          fallback.result_reason = r2.reason ?? null;
          fallback.result_note = r2.note ?? null;
          fallback.comps_considered = r2.comps_considered ?? null;
        }
        // The top-level pull fields keep describing PULL 1 — overwriting `rows_retrieved` with
        // pull 2's count left it sitting next to pull 1's `query` and `total_matching_in_index: 0`,
        // a count that belonged to neither pull. `answered_by` is how a caller knows which of the
        // two blocks produced the result it is holding.
        provenance = { ...provenance, answered_by: "sold_filtered_pull", assessed_fallback_pull: fallback };

        if (adopted) {
          r = r2;
          provenance.answered_by = "assessed_fallback_pull";
        } else if (!r2.ok && pulled2.rows.length > 0) {
          // Pass 1 refused over the sold-filtered remnant — in a non-disclosure state that set is
          // EMPTY, so its note ("No recent recorded sales near this address in the county roll")
          // is affirmatively false the moment the unfiltered pull returns rows. Adopt pass 2's
          // refusal, which was computed over the rows that actually arrived, and keep pass 1's
          // under provenance. Both results are ok:false / arv:null, so this can never turn a
          // refusal into a valuation — it only stops the tool claiming an empty roll it saw fill.
          provenance.sold_filtered_refusal = {
            reason: r.reason ?? null,
            note: r.note ?? null,
            rows_retrieved: rows.length,
            comps_considered: r.comps_considered ?? null,
          };
          r = r2;
          provenance.answered_by = "assessed_fallback_pull";
        }
      }
    } else if (rows !== null) {
      provenance = { rows_source: "caller-supplied rows", rows_retrieved: rows.length };
      r = value(rows, wantAssessed);
    } else {
      throw new ToolError("Supply either `rows` (raw county rows) or `search` (pull them live). Nothing to value.", {
        code: "NO_ROWS_INPUT",
      });
    }

    const out = { ...r, provenance };
    return {
      content: [{ type: "text", text: JSON.stringify(out, null, 2) }],
      // Surface the refusal to the MCP client rather than letting a null ARV read as success.
      isError: !r.ok,
    };
  },
};

// The tool objects, so a test can drive a handler directly instead of speaking stdio JSON-RPC.
// Exporting them changes nothing at runtime — the stdio server below still owns the process.
export const tools = [searchParcels, getComps, getPropertyAudit, planRoute, calcArv];

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

// Boot ONLY when this file is the process entry point (`node mcp/server.mjs`, which is exactly how
// ~/.mcp.json launches it). Importing it — which a test must do — would otherwise seize stdin and
// install the stdout guard. `import.meta.main` is a boolean on Node >= 24.2; the argv comparison is
// the equivalent for older runtimes, so this can never leave the real server un-booted.
const isEntryPoint =
  typeof import.meta.main === "boolean"
    ? import.meta.main
    : import.meta.url === pathToFileURL(process.argv[1] ?? "").href;

if (isEntryPoint) {
  assertBundledMcpIntegrity();
  createServer({
    name: SERVER_NAME,
    version: SERVER_VERSION,
    instructions:
      "Read-only public-records tools. Every result carries its own provenance and drop accounting. " +
      "A zero result is always explicitly marked verified-empty; a failure always throws. Never read " +
      "`arv` without first checking `ok`, and never read a comp count without checking `selection.dropped`.",
    tools,
  });
}
