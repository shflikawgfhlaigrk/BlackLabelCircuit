// blbestate — sold-comps + ARV engine, headless Node ESM port.
//
// This is a FIDELITY PORT of the macOS engine's `CompsEngine.derive` (Comps.swift:263) plus the
// upstream row selection that feeds it (`parseSales` :206 / `apiSaleComps` :529). Same arithmetic,
// same filters, same ordering, same rounding, same note strings. Where this file deliberately
// differs from the Swift, the deviation is marked `PORT DEVIATION` with the reason. Every
// deviation is either (a) restating a guarantee the Swift type system gives for free but loose
// JSON does not, or (b) parsing a real date shape the Swift's per-county field registry supplies
// out-of-band and a type-sniffing port cannot. NO deviation changes a number the Swift computes
// from input the Swift can actually receive.
//
// HONESTY LADDER (the rule that outranks everything else here): a wrong ARV is a real financial
// decision made on a fake number. When the data is too thin, this module returns an explicit
// { ok: false, reason, comps_considered, comps_usable } — never 0, never 1, never a null coerced
// into a number, never a valuation derived from rows whose sale price is missing, non-positive,
// or a nominal sub-floor transfer.
//
// Zero dependencies. Pure: no I/O, no clock reads except the injectable `now`.

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Constants (verbatim from CompsEngine)
// ─────────────────────────────────────────────────────────────────────────────────────────────

export const DEFAULT_RADIUS_METERS = 4828; // ~3 miles (same ring as the area-value pull)
// Ports CompsEngine.maxComps. Not used by derive — it is the county SALE-QUERY payload cap, and
// is exported so a caller building that query uses the same bound. Nothing in THIS module caps
// the number of rows it will consider.
export const MAX_COMPS = 400;
export const LOOKBACK_MONTHS = 36; // recent sales only — older deeds drift from market
export const MIN_COMPS_FOR_PER_SQFT = 4; // need a few real comps before trusting $/sqft
export const SQFT_SIMILARITY_BAND = 0.4; // $/sqft comps must be within ±40% of subject GLA
export const MIN_SALE_PRICE = 10_000; // $0/$1 non-arm's-length transfers drop (Swift: :226/:324/:539)
export const MAX_SHOWN_COMPS = 25; // display slice; the arithmetic uses the FULL trimmed set
export const MIN_SQFT_FOR_PER_SQFT = 200; // pricePerSqft's own guard — ignore garbage tiny areas
export const METERS_PER_MILE = 1609.344;
// Advisory only — a subject GLA above this is flagged in `warnings`, never silently rejected and
// never used to alter the number (the Swift has no ceiling; adding one would change buyer output).
export const MAX_PLAUSIBLE_SUBJECT_SQFT = 25_000;

/** How the ARV was arrived at — drives the honest label the buyer reads in the deal screen. */
export const ARV_BASIS = {
  soldCompsPerSqft: 'soldCompsPerSqft', // median $/sqft of nearby sales × subject sqft
  soldCompsMedian: 'soldCompsMedian', // median nearby sale price (no subject sqft to scale by)
  parcelOwnSaleAnchor: 'parcelOwnSaleAnchor', // the subject parcel's OWN recorded sale(s)
  assessedAVM: 'assessedAVM', // labeled estimate from the 3-mile county-assessed average
  assessedAreaEstimate: 'assessedAreaEstimate', // labeled estimate from a ZIP/area records read
  none: 'none', // gated — no source
};

const BASIS_LABELS = {
  soldCompsPerSqft: 'Sold comps ($/sqft median)',
  soldCompsMedian: 'Sold comps (median sale)',
  parcelOwnSaleAnchor: "Anchor — parcel's own recorded sale (not neighborhood comps)",
  assessedAVM: 'Estimate — county-assessed (not sold comps)',
  assessedAreaEstimate: 'Assessed-value estimate (area read, not sold comps)',
  none: 'No comps source',
};

/** Where the comps/estimate came from. `derive` never sets this — it defaults to `none`. */
export const COMPS_SOURCE = {
  countyArcGIS: 'countyArcGIS',
  leadDatabase: 'leadDatabase',
  countyAssessed: 'countyAssessed',
  none: 'none',
};

const SOURCE_LABELS = {
  countyArcGIS: 'County deed roll (ArcGIS)',
  leadDatabase: 'Public-records index',
  countyAssessed: 'County-assessed (3-mi avg)',
  none: 'No source',
};

export function basisLabel(basis) {
  return BASIS_LABELS[basis] ?? BASIS_LABELS.none;
}
export function sourceLabel(source) {
  return SOURCE_LABELS[source] ?? SOURCE_LABELS.none;
}
/** True ONLY for real recorded arm's-length NEIGHBORHOOD sales. */
export function isCompBasis(basis) {
  return basis === ARV_BASIS.soldCompsPerSqft || basis === ARV_BASIS.soldCompsMedian;
}

/** Machine-readable refusal reasons (there is no numeric sentinel — ever). */
export const REFUSAL = {
  noCompsSupplied: 'no_comps_supplied',
  noPricedComps: 'no_priced_comps',
  allBelowPriceFloor: 'all_comps_below_price_floor',
  noSelectableComps: 'no_selectable_comps',
  noUsablePrice: 'no_usable_price',
};

/** Why the $/sqft basis did not fire (machine-readable; the buyer-facing note stays verbatim). */
export const PER_SQFT_GATE = {
  noSubjectSqft: 'no_subject_sqft', // subject GLA absent / 0 / < 200
  noCompSqft: 'no_comp_sqft', // NO comp carries a usable living area at all
  tooFewSqftComps: 'too_few_sqft_comps', // some do, but fewer than MIN_COMPS_FOR_PER_SQFT
};

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Numeric coercion (county/API fields arrive String OR Number) — ports CompsEngine.money / .dbl
// ─────────────────────────────────────────────────────────────────────────────────────────────

/**
 * Port of CompsEngine.money (Comps.swift:133): positive whole dollars, or null.
 *
 * PORT DEVIATION (fabrication guard — the reason this function is not a literal transcription):
 * Swift checks positivity BEFORE truncating (`d > 0 ? Int(d) : nil`), so Swift's money(0.4) is the
 * Int 0. That 0 is harmless in Swift ONLY because every call site binds it inseparably to the
 * floor in one guard — `guard let price = money(a[priceF]), price >= 10_000 else { continue }`
 * (Comps.swift:226, :324, :539) — so a truncated 0 can never reach derive. This port exposes
 * money() and calcARV() as public entry points, so the check is moved AFTER the truncation: a
 * value that truncates to 0 (any sub-dollar price) is null, not 0. Without this, three $0.40
 * rows plus one real $400k sale returned `{ ok: true, isComp: true, arv: 0 }` — a $0 valuation
 * presented as a sold-comp figure. Also rejects magnitudes past Number.MAX_SAFE_INTEGER, where
 * integer arithmetic silently stops being exact (Swift traps with SIGILL on the same input).
 */
export function money(v) {
  let d = null;
  if (typeof v === 'number') {
    d = Number.isFinite(v) ? v : null; // Swift's Int/Double can't be NaN here; loose JSON can.
  } else if (typeof v === 'string') {
    const c = v.replaceAll(',', '').replaceAll('$', '').trim();
    if (c === '') return null;
    const n = Number(c);
    d = Number.isFinite(n) ? n : null;
  }
  if (d === null) return null;
  const t = Math.trunc(d);
  if (!(t > 0) || !Number.isSafeInteger(t)) return null;
  return t;
}

/** Port of CompsEngine.dbl (Comps.swift:144): a finite Double, or null. */
export function dbl(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') {
    const t = v.trim();
    if (t === '') return null;
    const d = Number(t);
    return Number.isFinite(d) ? d : null;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Medians — two overloads, two different truncation behaviours. Do NOT collapse them.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/**
 * Port of `median(_ xs: [Int]) -> Int?`. The even case is INTEGER division in Swift, which
 * truncates toward zero: [100001, 100002] → 100001 (not 100001.5, not 100002).
 */
export function medianInt(xs) {
  if (!Array.isArray(xs) || !xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 === 1 ? s[(n / 2) | 0] : Math.trunc((s[n / 2 - 1] + s[n / 2]) / 2);
}

/** Port of `median(_ xs: [Double]) -> Double?`. The even case is a floating average. */
export function medianDouble(xs) {
  if (!Array.isArray(xs) || !xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 === 1 ? s[(n / 2) | 0] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

/**
 * Swift's `.rounded()` is schoolbook rounding — half AWAY FROM ZERO. JS `Math.round` is
 * half toward +∞, which differs for negative halves only. Sign-aware so the port matches.
 */
export function roundedHalfAwayFromZero(x) {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// SaleComp — one real recorded sale near the subject (from the county's own deed roll)
// ─────────────────────────────────────────────────────────────────────────────────────────────

const MONTH_NAMES = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Port of SaleComp.pricePerSqft — the `sqft >= 200` guard lives HERE, not in derive. */
export function pricePerSqft(comp) {
  const s = comp?.sqft;
  if (typeof s !== 'number' || !Number.isFinite(s) || s < MIN_SQFT_FOR_PER_SQFT) return null;
  const p = comp.salePrice;
  if (typeof p !== 'number' || !Number.isFinite(p)) return null;
  return p / s;
}

/**
 * Port of SaleComp.dateLabel.
 *
 * PORT DEVIATION (display honesty, Swift-unreachable input only): Swift interpolates the raw Int,
 * so an undated comp would render the literal string "0". parseSales/apiSaleComps guard `year > 0`
 * before constructing a SaleComp, so the Swift can never reach that state; a JS caller handing raw
 * rows straight to calcARV can. "0" would be a false date on a buyer-facing comp row, so an
 * undated comp says so.
 */
export function dateLabel(comp) {
  const y = comp?.saleYear;
  if (typeof y !== 'number' || !Number.isFinite(y) || y <= 0) return 'date not on record';
  const m = comp?.saleMonth;
  if (typeof m === 'number' && m >= 1 && m <= 12) return `${MONTH_NAMES[m]} ${y}`;
  return `${y}`;
}

const FIRST = (row, keys) => {
  if (!row || typeof row !== 'object') return null;
  for (const k of keys) if (row[k] !== undefined && row[k] !== null) return row[k];
  return null;
};

/**
 * Like FIRST, but returns the first key whose value SURVIVES coercion.
 *
 * PORT DEVIATION (the alias list is itself a port invention — Swift reads one registry-DECLARED
 * field name per role, with no fallback chain — so the chain must not introduce a new data-loss
 * mode). A plain FIRST returns the first non-null value, so a `salePrice` column defined
 * `NOT NULL DEFAULT 0` masks the real figure sitting in `last_sale_price` and the whole comp is
 * discarded. Coercing as we scan means a placeholder never shadows a real value.
 */
const firstUsable = (row, keys, coerce) => {
  if (!row || typeof row !== 'object') return null;
  for (const k of keys) {
    const raw = row[k];
    if (raw === undefined || raw === null) continue;
    const v = coerce(raw);
    if (v !== null) return v;
  }
  return null;
};

/** A strictly-positive finite Double, else null. Used where 0 means "absent", not "zero". */
const positiveDbl = (v) => {
  const d = dbl(v);
  return d !== null && d > 0 ? d : null;
};

const PRICE_KEYS = ['salePrice', 'sale_price', 'last_sale_price', 'lastSalePrice', 'price', 'amount'];
const SQFT_KEYS = ['sqft', 'living_area', 'livingArea', 'heated_sqft', 'heatedSqft', 'gla', 'building_sqft', 'buildingSqft'];
const DIST_KEYS = ['distanceMiles', 'distance_miles', 'distance'];
const ASSESSED_KEYS = ['assessedValue', 'assessed_value', 'value'];
const ADDR_KEYS = ['address', 'situs_address', 'situsAddress', 'mailing_address', 'mailingAddress'];
const DATE_KEYS = ['saleDate', 'sale_date', 'last_sale_date', 'lastSaleDate', 'saleDateString', 'recordedDate', 'recorded_date', 'date'];
// PORT DEVIATION: a bare `year` column is NOT read as the recorded-sale year. In property data
// `year` overwhelmingly means year BUILT; reading 1978 as a sale year silently mis-dates the comp
// (it is then discarded as `too_old`, or — worse, on a long lookback — anchors the recency label).
// A sale year must be named as one.
const YEAR_KEYS = ['saleYear', 'sale_year', 'saleyear', 'last_sale_year', 'lastSaleYear'];
const MONTH_KEYS = ['saleMonth', 'sale_month', 'salemonth', 'last_sale_month', 'lastSaleMonth'];
const SUBJECT_SQFT_KEYS = ['sqft', 'subjectSqft', 'subject_sqft', 'living_area', 'livingArea', 'gla'];
const LAT_KEYS = ['lat', 'latitude', 'subjectLat', 'y'];
const LNG_KEYS = ['lng', 'lon', 'long', 'longitude', 'subjectLng', 'x'];

/** First date-ish key that actually PARSES. A garbage primary key cannot shadow a good one. */
const firstSaleYearMonth = (row, keys) => {
  if (!row || typeof row !== 'object') return null;
  for (const k of keys) {
    const raw = row[k];
    if (raw === undefined || raw === null) continue;
    const ym = saleYearMonth(raw);
    if (ym) return ym;
  }
  return null;
};

const plausibleYear = (y) => typeof y === 'number' && Number.isFinite(y) && y > 1900 && y < 3000;

/**
 * Normalize one loose row into a SaleComp shape, or null when the price is not a real recorded
 * dollar figure.
 *
 * PORT DEVIATION (deliberate): Swift's `SaleComp.salePrice` is a non-optional `Int`, so "a comp
 * with a null price" cannot exist in the Swift type system — the upstream parsers guarantee it.
 * JS fed loose JSON has no such guarantee, so the guard is restated here: a row whose price is
 * null / undefined / NaN / unparseable / <= 0 (including any sub-dollar value that truncates to
 * zero) is DROPPED and can never reach a median. The $10k arm's-length floor is applied by
 * selectComps and by calcARV (see `options.minSalePrice`), matching where the Swift binds it.
 *
 * PORT DEVIATION (dating): the recorded DATE is parsed here rather than only in selectComps, so
 * a comp handed straight to calcARV carries a truthful `dateLabel` instead of year 0. Precedence
 * follows the Swift's own order (Comps.swift:226-236: date field, then the split year/month
 * fields) — safe now that the parser refuses implausible input instead of guessing.
 */
export function normalizeComp(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return null;
  const salePrice = money(firstUsable(row, PRICE_KEYS, money));
  if (salePrice === null || !(salePrice > 0)) return null;

  // parseSales treats a 0/absent area as absent, so a `sqft: 0` placeholder must not shadow a real
  // `living_area` in a later alias — the same masking that discarded genuinely priced comps.
  const sqftRaw = firstUsable(row, SQFT_KEYS, positiveDbl);
  const distRaw = firstUsable(row, DIST_KEYS, dbl);
  const assessed = firstUsable(row, ASSESSED_KEYS, money);
  const addrRaw = FIRST(row, ADDR_KEYS);
  const addr = typeof addrRaw === 'string' ? addrRaw.trim() : '';

  const ymFromDate = firstSaleYearMonth(row, DATE_KEYS);
  const yearRaw = firstUsable(row, YEAR_KEYS, dbl);
  const monthRaw = firstUsable(row, MONTH_KEYS, dbl);
  const explicitMonth =
    monthRaw !== null && Math.trunc(monthRaw) >= 1 && Math.trunc(monthRaw) <= 12 ? Math.trunc(monthRaw) : null;

  let saleYear = 0;
  let saleMonth = null;
  if (ymFromDate) {
    saleYear = ymFromDate.year;
    saleMonth = ymFromDate.month ?? explicitMonth;
  } else if (yearRaw !== null && plausibleYear(Math.trunc(yearRaw))) {
    // PORT DEVIATION: Swift's `guard year > 0` accepts e.g. 20250601 in a declared saleYear field
    // and calls it "recent". A type-sniffing port applies the same 1900<y<3000 plausibility the
    // Swift's own string parsers use, so an out-of-range value is refused, never guessed.
    saleYear = Math.trunc(yearRaw);
    saleMonth = explicitMonth;
  }

  return {
    address: addr === '' ? '(address on record)' : addr,
    salePrice,
    saleYear,
    saleMonth,
    // parseSales: `sqft: (sqft ?? 0) > 0 ? sqft : nil` — a zero/absent area stays absent.
    sqft: sqftRaw !== null && sqftRaw > 0 ? sqftRaw : null,
    distanceMiles: distRaw,
    assessedValue: assessed,
  };
}

/** Attach the two computed properties the Swift struct exposes, without mutating the input. */
function decorate(comp) {
  return { ...comp, pricePerSqft: pricePerSqft(comp), dateLabel: dateLabel(comp) };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Dates — ports stringSaleYearMonth (:162) / apiSaleYearMonth (:511) / oracleDMY
// ─────────────────────────────────────────────────────────────────────────────────────────────

/** Port of CompsEngine.haversineMiles. */
export function haversineMiles(aLat, aLng, bLat, bLng) {
  const R = 3958.7613;
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLng = ((bLng - aLng) * Math.PI) / 180;
  const s1 = Math.sin(dLat / 2);
  const s2 = Math.sin(dLng / 2);
  const h = s1 * s1 + Math.cos((aLat * Math.PI) / 180) * Math.cos((bLat * Math.PI) / 180) * s2 * s2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Port of TitleChainEngine.oracleDMY — Oracle "DD-MON-YY" with the stable 49/50 pivot. */
export function oracleDMY(raw) {
  const s = String(raw ?? '').trim().toUpperCase();
  const parts = s.split('-').filter((p) => p !== '');
  const months = { JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12 };
  if (parts.length !== 3) return null;
  if (!/^\d+$/.test(parts[0])) return null;
  const d = Number(parts[0]);
  if (!(d >= 1 && d <= 31)) return null;
  const m = months[parts[1]];
  if (!m) return null;
  if (parts[2].length !== 2 || !/^\d{2}$/.test(parts[2])) return null;
  const yy = Number(parts[2]);
  return { year: yy <= 49 ? 2000 + yy : 1900 + yy, month: m, day: d };
}

const MONTH_TOKEN = /(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*/i;
const MONTH_INDEX = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };

const fromEpochMs = (ms) => {
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return null;
  const y = d.getFullYear();
  if (!plausibleYear(y)) return null;
  return { year: y, month: d.getMonth() + 1 };
};

/**
 * Classify a NUMERIC date by magnitude. Swift never needs this: parseSales is told by the county
 * registry which field is epoch-ms (`reg.saleDateField`), which is a date string
 * (`reg.saleDateStringField`) and which are split integers (`reg.saleYearField`) — Comps.swift:229-238.
 *
 * PORT DEVIATION (required, and a bug fix): a type-sniffing port has no registry, and the previous
 * version treated EVERY finite number as epoch-MILLISECONDS. That read the packed integer date
 * 20250601 — the ordinary shape of an ArcGIS integer date field — as 20.25 million ms after the
 * epoch, i.e. December 1969, which was then silently discarded as `too_old`. Quoting the identical
 * value worked. The ranges below do not overlap, so nothing is guessed; anything outside them is
 * refused (null) rather than mis-dated.
 *   1900…2999            → a bare sale YEAR (no month)
 *   190001…299912        → packed YYYYMM
 *   19000101…29991231    → packed YYYYMMDD
 *   1e8…<1e11            → epoch SECONDS (1973-03 … 5138; the year guard trims the tail)
 *   >=1e11               → epoch MILLISECONDS (1973-03 onward)
 */
function numericSaleYearMonth(n) {
  if (!Number.isFinite(n) || n <= 0) return null;
  if (!Number.isInteger(n)) {
    // A fractional value is only ever an epoch stamp (Swift's `Double(raw)` accepts "…000.0").
    return n >= 1e11 ? fromEpochMs(n) : n >= 1e8 ? fromEpochMs(n * 1000) : null;
  }
  if (n >= 1900 && n <= 2999) return { year: n, month: null };
  if (n >= 190001 && n <= 299912) {
    const y = Math.trunc(n / 100);
    const m = n % 100;
    if (!plausibleYear(y)) return null;
    return { year: y, month: m >= 1 && m <= 12 ? m : null };
  }
  if (n >= 19000101 && n <= 29991231) {
    const y = Math.trunc(n / 10000);
    const m = Math.trunc(n / 100) % 100;
    if (!plausibleYear(y)) return null;
    return { year: y, month: m >= 1 && m <= 12 ? m : null };
  }
  if (n >= 1e8 && n < 1e11) return fromEpochMs(n * 1000); // epoch SECONDS
  if (n >= 1e11) return fromEpochMs(n); // epoch MILLISECONDS
  return null;
}

/**
 * Textual month forms.
 *
 * PORT DEVIATION (required to work against this product's OWN API): the live Worker serializes
 * `last_sale_date` through project()→cleanText()→String(pgDate) (src/index.js:137,219), which
 * yields JS `Date.prototype.toString()` output —
 * "Sun Dec 01 2024 00:00:00 GMT+0000 (Coordinated Universal Time)". Neither this port's earlier
 * parser NOR the Swift's apiSaleYearMonth (Comps.swift:511) can read that, so 100% of live rows
 * were dropped as `no_date` and every valuation refused with a note claiming the county roll had
 * no recent sales. The year must appear AFTER the month token, which is what excludes the "0000"
 * inside a "GMT+0000" offset and a leading street number.
 * Covers: "Sun Dec 01 2024 …", "Dec 2024", "December 1, 2024", "01 Dec 2024".
 */
function textualSaleYearMonth(s) {
  const hit = MONTH_TOKEN.exec(s);
  if (!hit) return null;
  const month = MONTH_INDEX[hit[0].slice(0, 3).toLowerCase()];
  if (!month) return null;
  const tail = s.slice(hit.index + hit[0].length);
  for (const m of tail.matchAll(/\d{4}/g)) {
    const y = Number(m[0]);
    if (plausibleYear(y)) return { year: y, month };
  }
  return null;
}

/**
 * US-format MM/DD/YYYY.
 *
 * PORT DEVIATION (additive; Swift returns nil here, so no Swift-produced number changes): the most
 * common US county-recorder date format was unparseable, which silently discarded every comp from
 * such a source. Only fires for [1-2 digits][sep][1-2 digits][sep][exactly 4 digits] with a
 * plausible year. AMBIGUITY, stated: 05/06/2025 is read as MAY 2025 (US convention). Day-first
 * sources would be off by a month — which can only shift the display tie-break, or the recency
 * decision for a sale sitting exactly on the 36-month boundary. Never the ARV itself.
 */
function usSlashSaleYearMonth(parts) {
  if (parts.length !== 3) return null;
  if (parts[2].length !== 4) return null;
  if (parts[0].length > 2 || parts[1].length > 2) return null;
  const y = Number(parts[2]);
  if (!plausibleYear(y)) return null;
  const a = Number(parts[0]);
  const b = Number(parts[1]);
  const month = a >= 1 && a <= 12 ? a : b >= 1 && b <= 12 ? b : null;
  return { year: y, month };
}

/** Port of CompsEngine.stringSaleYearMonth (+ the epoch-ms rule from apiSaleYearMonth). */
export function saleYearMonth(raw) {
  if (typeof raw === 'number') return numericSaleYearMonth(raw);
  if (typeof raw === 'boolean') return null;
  const s = String(raw ?? '').trim();
  if (s === '') return null;

  // ── Swift-verified branches first: wherever the Swift produces a value, the Swift wins. ──
  // apiSaleYearMonth: a long numeric string is epoch-ms, not a packed date. Swift only requires
  // `count >= 12` + `Double(raw)`, so a decimal tail ("1683676800000.0") parses there too.
  if (s.length >= 12 && /^\d+(\.\d+)?$/.test(s)) {
    const hit = fromEpochMs(Number(s));
    if (hit) return hit;
  }
  // Packed YYYYMMDD (exactly 8 digits).
  if (s.length === 8 && /^\d{8}$/.test(s)) {
    const y = Number(s.slice(0, 4));
    if (!plausibleYear(y)) return null;
    const m = Number(s.slice(4, 6));
    return { year: y, month: m >= 1 && m <= 12 ? m : null };
  }
  // Delimited: first 4-digit run = year, an immediately-following 1–2 digit run = month.
  const parts = s.split(/\D+/).filter((p) => p !== '');
  if (parts.length && parts[0].length === 4) {
    const y = Number(parts[0]);
    if (plausibleYear(y)) {
      let month = null;
      if (parts.length >= 2) {
        const m = Number(parts[1]);
        if (Number.isInteger(m) && m >= 1 && m <= 12) month = m;
      }
      return { year: y, month };
    }
  }
  // Oracle "DD-MON-YY".
  const o = oracleDMY(s);
  if (o) return { year: o.year, month: o.month };

  // ── Port-added branches: reached ONLY where the Swift returns nil. ──
  const textual = textualSaleYearMonth(s);
  if (textual) return textual;
  const us = usSlashSaleYearMonth(parts);
  if (us) return us;
  // An all-digit string the Swift's branches rejected (a bare year, YYYYMM, epoch seconds) —
  // classify it exactly as the numeric form of the same value.
  if (/^\d+$/.test(s)) {
    const n = numericSaleYearMonth(Number(s));
    if (n) return n;
  }
  return null; // No sane year ⇒ the row is DROPPED. A sale's date is never guessed.
}

/** Port of CompsEngine.cutoff — the (year, month) `monthsBack` before `now`. */
export function cutoff({ monthsBack = LOOKBACK_MONTHS, now = new Date() } = {}) {
  const d = now instanceof Date && !Number.isNaN(now.getTime()) ? now : new Date();
  const mb = Number.isFinite(monthsBack) ? monthsBack : LOOKBACK_MONTHS;
  const total = d.getFullYear() * 12 + d.getMonth() - mb;
  return { year: Math.floor(total / 12), month: ((total % 12) + 12) % 12 + 1 };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// selectComps — the upstream row selection that feeds derive (parseSales / apiSaleComps)
// ─────────────────────────────────────────────────────────────────────────────────────────────

/**
 * The selection that runs BEFORE derive in the macOS engine (parseSales / apiSaleComps /
 * compsFromTitleChain all share it). Porting derive alone would silently change results, because
 * derive itself applies NO price floor and NO recency window.
 *
 * Gates, in the Swift's own order:
 *   1. a real recorded price >= $10,000        (skips $0/$1 non-arm's-length transfers)
 *   2. a parseable recorded date               (an undated row is never treated as recent)
 *   3. recency: within the 36-month lookback   (`month ?? 12` — a year-only sale gets the benefit)
 *   4. PORT DEVIATION — not dated in the FUTURE. The Swift's recency guard is lower-bound only, so
 *      a forward-dated typo, or a source that puts a LISTING / pending / contract date in the
 *      sale-date column, produced a fully green-sealed ARV out of sales that have not happened
 *      (a 2099 date was accepted as a "recent recorded sale"). A sale recorded after today is not
 *      a recorded sale. This can only ever REMOVE rows the Swift would have kept, and on real
 *      county data — where deeds are recorded in the past — it removes none.
 * Distance is filled only when subject AND row carry lat/lng; absence stays null, never faked.
 */
export function selectComps(args) {
  const { subject = {}, rows = [], options = {} } = args ?? {};
  const opts = options ?? {};
  const now = opts.now instanceof Date && !Number.isNaN(opts.now.getTime()) ? opts.now : new Date();
  const monthsBack = Number.isFinite(opts.lookbackMonths) ? opts.lookbackMonths : LOOKBACK_MONTHS;
  const minPrice = Number.isFinite(opts.minSalePrice) ? opts.minSalePrice : MIN_SALE_PRICE;
  const cut = cutoff({ monthsBack, now });
  const nowYear = now.getFullYear();
  const nowMonth = now.getMonth() + 1;

  const subj = subject ?? {};
  const sLat = firstUsable(subj, LAT_KEYS, dbl);
  const sLng = firstUsable(subj, LNG_KEYS, dbl);

  const list = Array.isArray(rows) ? rows : [];
  const dropped = { no_price: 0, below_price_floor: 0, no_date: 0, too_old: 0, future: 0, malformed: 0 };
  const comps = [];

  for (const row of list) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) {
      dropped.malformed += 1;
      continue;
    }
    const c = normalizeComp(row);
    if (!c) {
      dropped.no_price += 1;
      continue;
    }
    if (c.salePrice < minPrice) {
      dropped.below_price_floor += 1;
      continue;
    }
    if (!(c.saleYear > 0)) {
      dropped.no_date += 1;
      continue;
    }
    const recent = c.saleYear > cut.year || (c.saleYear === cut.year && (c.saleMonth ?? 12) >= cut.month);
    if (!recent) {
      dropped.too_old += 1;
      continue;
    }
    // `month ?? 1` mirrors the lower bound's `month ?? 12`: a year-only sale in the current year
    // gets the benefit of the doubt in both directions.
    const isFuture = c.saleYear > nowYear || (c.saleYear === nowYear && (c.saleMonth ?? 1) > nowMonth);
    if (isFuture) {
      dropped.future += 1;
      continue;
    }

    let distanceMiles = c.distanceMiles;
    if (distanceMiles === null && sLat !== null && sLng !== null) {
      const rLat = firstUsable(row, ['lat', 'latitude', 'y'], dbl);
      const rLng = firstUsable(row, ['lng', 'lon', 'long', 'longitude', 'x'], dbl);
      if (rLat !== null && rLng !== null) distanceMiles = haversineMiles(sLat, sLng, rLat, rLng);
    }

    comps.push({ ...c, distanceMiles });
  }

  return {
    comps,
    considered: list.length,
    kept: comps.length,
    dropped,
    cutoff: cut,
    minSalePrice: minPrice,
    lookbackMonths: monthsBack,
  };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// calcARV — the port of CompsEngine.derive
// ─────────────────────────────────────────────────────────────────────────────────────────────

function result(fields) {
  // Every return carries the full CompsResult shape (including the three Swift-defaulted fields)
  // plus the port's honesty envelope. `arv` is null — never 0 — on every refusal path.
  return {
    ok: fields.ok,
    reason: fields.reason ?? null,
    available: fields.available,
    basis: fields.basis,
    basisLabel: basisLabel(fields.basis),
    isComp: isCompBasis(fields.basis),
    arv: fields.arv,
    perSqft: fields.perSqft,
    comps: fields.comps,
    radiusMiles: fields.radiusMiles,
    note: fields.note,
    source: fields.source ?? COMPS_SOURCE.none, // derive never sets this; callers overwrite it
    sourceLabel: sourceLabel(fields.source ?? COMPS_SOURCE.none),
    // derive never sets it — struct default. Only the tier-3 assessed AREA read overrides it.
    isAreaRead: fields.isAreaRead ?? false,
    fromParcelOwnHistory: false, // derive never sets it — struct default
    comps_considered: fields.comps_considered,
    comps_usable: fields.comps_usable,
    comps_in_basis: fields.comps_in_basis ?? 0,
    comps_below_floor: fields.comps_below_floor ?? 0,
    // Machine-readable reason the $/sqft basis did not fire. The buyer-facing `note` stays
    // verbatim-Swift ("no subject sqft to scale by $/sqft") even when the real cause is that no
    // COMP carries a living area — this field is how a caller learns which it was.
    perSqftGate: fields.perSqftGate ?? null,
    // Only the tier-3 assessed area read populates this; every comp path leaves it null.
    assessed: fields.assessed ?? null,
    warnings: fields.warnings ?? [],
    selection: fields.selection ?? null,
  };
}

/**
 * Derive ARV + the comp set from recorded sales (pure port of CompsEngine.derive).
 *
 * @param {object}   args
 * @param {object}   [args.subject]  the subject parcel; `sqft` (GLA) is the only field read.
 * @param {object[]} [args.comps]    recorded sales (loose rows are normalized here).
 * @param {object}   [args.options]
 * @param {number}   [args.options.radiusMiles]   pass-through only, never arithmetic.
 * @param {number}   [args.options.minSalePrice]  arm's-length floor, default $10,000. Pass 0 to
 *                   reproduce raw Swift `derive` semantics for a differential harness.
 * @param {Date}     [args.options.now]           OPTIONAL, warnings only — never changes a number.
 * @param {object}   [args.options.selection]     a selectComps envelope, carried into `selection`
 *                   so a refusal can still report how many rows were considered upstream.
 * @returns {object} CompsResult + { ok, reason, comps_considered, comps_usable, comps_in_basis,
 *                   comps_below_floor, perSqftGate, warnings, selection }.
 */
export function calcARV(args) {
  const { subject = {}, comps: input = [], options = {} } = args ?? {};
  const opts = options ?? {};
  const radiusMiles = Number.isFinite(opts.radiusMiles) ? opts.radiusMiles : DEFAULT_RADIUS_METERS / METERS_PER_MILE;
  const minPrice = Number.isFinite(opts.minSalePrice) ? opts.minSalePrice : MIN_SALE_PRICE;
  const selection = opts.selection ?? null;
  const warnings = [];

  const rows = Array.isArray(input) ? input : [];
  const considered = rows.length;

  // PORT GUARD (see normalizeComp / money): rows without a real positive recorded price cannot
  // reach a median. In Swift this is structurally impossible; in JS it is the difference between
  // an honest refusal and a fabricated valuation built out of nulls and sub-dollar deeds.
  const priced = [];
  for (const r of rows) {
    const c = normalizeComp(r);
    if (c) priced.push(c);
  }
  const usable = priced.length;

  // PORT DEVIATION (fabrication guard): the arm's-length floor. Swift's `derive` has no floor
  // because it is unreachable without one — all three call sites bind it to the money() call
  // (Comps.swift:226, :324, :539) and the county SQL filters `price > 10000` (:343). calcARV is a
  // public entry point that does its own row normalization, so it carries the same floor; without
  // it, five $1 quitclaim deeds returned `{ ok: true, isComp: true, arv: 1 }`. Overridable
  // (`minSalePrice: 0`) so a differential harness can still exercise raw derive semantics.
  const sales = minPrice > 0 ? priced.filter((c) => c.salePrice >= minPrice) : priced;
  const belowFloor = usable - sales.length;
  if (belowFloor > 0) warnings.push(`dropped_${belowFloor}_below_price_floor`);

  const refuse = (reason, note) =>
    result({
      ok: false,
      reason,
      available: false,
      basis: ARV_BASIS.none,
      arv: null,
      perSqft: null,
      comps: [],
      radiusMiles,
      note,
      comps_considered: selection?.considered ?? considered,
      comps_usable: usable,
      comps_below_floor: belowFloor,
      warnings,
      selection,
    });

  // STEP 0 — EMPTY GUARD (verbatim note).
  if (considered === 0) {
    return refuse(REFUSAL.noCompsSupplied, 'No recent recorded sales near this address in the county roll.');
  }
  // Rows arrived but none carried a usable recorded price (the NC/Alamance shape). Distinct reason
  // and note from the empty case: claiming "no recent recorded sales" would be false — the sales
  // exist, their prices do not.
  if (usable === 0) {
    return refuse(
      REFUSAL.noPricedComps,
      `${considered} nearby recorded row(s) carry no usable sale price — ARV gated, nothing invented.`,
    );
  }
  // Rows were priced, but every price is a nominal / non-arm's-length transfer.
  if (sales.length === 0) {
    return refuse(
      REFUSAL.allBelowPriceFloor,
      `${usable} nearby recorded sale(s) are all below the $${minPrice.toLocaleString('en-US')} arm's-length floor (nominal transfers) — ARV gated, nothing invented.`,
    );
  }

  // STEP 1 — AREA MEDIAN FOR THE OUTLIER BAND (integer median over EVERY sale).
  const med = medianInt(sales.map((s) => s.salePrice)) ?? 0;

  // STEP 2 — PRICE-BAND OUTLIER TRIM. Inclusive both ends; med == 0 ⇒ pass-through.
  // This is the ONLY outlier rejection: no IQR, no stddev, no z-score. (The `med === 0`
  // pass-through is now unreachable — every price is >= 1 — but it is ported verbatim.)
  const band = sales.filter((s) => (med === 0 ? true : s.salePrice >= med * 0.25 && s.salePrice <= med * 4.0));

  // STEP 3 — BAND FALLBACK: never over-filter into no-data.
  const comps = band.length === 0 ? sales : band;

  // STEP 4 — DISPLAY ORDERING (display list only; ZERO effect on any ARV number).
  // Primary: distanceMiles ASC, nil → greatestFiniteMagnitude (distance-less comps sink).
  // Tie-break: (saleYear, saleMonth ?? 0) DESC — most recent first, nil month = oldest in its year.
  // PORT NOTE: Swift's `sorted` is not documented as stable and JS's is; ties on BOTH keys can
  // therefore differ in order between the two. That can only reorder the shown list, never a value.
  const ordered = [...comps].sort((a, b) => {
    const da = a.distanceMiles ?? Number.MAX_VALUE;
    const db = b.distanceMiles ?? Number.MAX_VALUE;
    if (da !== db) return da < db ? -1 : 1;
    const ay = a.saleYear;
    const by = b.saleYear;
    if (ay !== by) return by - ay;
    const am = a.saleMonth ?? 0;
    const bm = b.saleMonth ?? 0;
    if (am !== bm) return bm - am;
    return 0;
  });

  // STEP 5 — DISPLAY TRUNCATION. The arithmetic below still uses the FULL `comps` set.
  const shown = ordered.slice(0, MAX_SHOWN_COMPS).map(decorate);

  // Provenance warnings — advisory only, computed over the set that actually backs the number.
  if (comps.some((c) => !(c.saleYear > 0))) warnings.push('comps_undated');
  if (opts.now instanceof Date && !Number.isNaN(opts.now.getTime())) {
    const ny = opts.now.getFullYear();
    const nm = opts.now.getMonth() + 1;
    if (comps.some((c) => c.saleYear > ny || (c.saleYear === ny && (c.saleMonth ?? 1) > nm))) {
      warnings.push('comps_dated_in_future');
    }
  }

  // STEP 6 — $/SQFT PATH GATE.
  const subjRaw = firstUsable(subject ?? {}, SUBJECT_SQFT_KEYS, dbl);
  let perSqftGate = null;
  if (subjRaw === null || subjRaw < MIN_SQFT_FOR_PER_SQFT) {
    perSqftGate = PER_SQFT_GATE.noSubjectSqft;
  } else {
    const subj = subjRaw;
    if (subj > MAX_PLAUSIBLE_SUBJECT_SQFT) warnings.push('subject_sqft_implausible');
    // STEP 7 — SANE-$/SQFT FILTER. Strict bounds: exactly 5 or exactly 2000 is rejected.
    const sqftComps = comps.filter((c) => {
      const p = pricePerSqft(c) ?? 0;
      return p > 5 && p < 2000;
    });
    // STEP 8 — SIZE-SIMILARITY WINDOW (inclusive), re-reading raw sqft with its own `?? 0`.
    const lo = subj * (1 - SQFT_SIMILARITY_BAND);
    const hi = subj * (1 + SQFT_SIMILARITY_BAND);
    const similar = sqftComps.filter((c) => {
      const s = c.sqft ?? 0;
      return s >= lo && s <= hi;
    });
    // STEP 9 — HARD SWITCH between two sets (no blending, no per-comp weighting anywhere:
    // no distance weight, no recency weight, no condition/time-trend adjustment).
    const sizeMatched = similar.length >= MIN_COMPS_FOR_PER_SQFT;
    const used = sizeMatched ? similar : sqftComps;
    // STEP 10 — CENTRAL TENDENCY = MEDIAN (never a mean).
    const perSqftVals = used.map((c) => pricePerSqft(c)).filter((p) => p !== null);
    const mps = perSqftVals.length >= MIN_COMPS_FOR_PER_SQFT ? medianDouble(perSqftVals) : null;
    if (mps !== null) {
      // STEP 11 — $/SQFT ARV. Round half away from zero; Int(...) then truncates (a no-op).
      const arv = roundedHalfAwayFromZero(mps * subj);
      const sizeNote =
        sizeMatched && similar.length < sqftComps.length
          ? `, size-matched within ±${Math.trunc(SQFT_SIMILARITY_BAND * 100)}% of ${Math.trunc(subj)} sqft`
          : '';
      return result({
        ok: true,
        available: true,
        basis: ARV_BASIS.soldCompsPerSqft,
        arv,
        perSqft: mps,
        comps: shown,
        radiusMiles,
        // Int(mps) TRUNCATES here — the note's dollar figure and `perSqft` can differ by up to $1.
        note: `ARV from the median $${Math.trunc(mps)}/sqft of ${perSqftVals.length} recent nearby sales${sizeNote} × ${Math.trunc(subj)} sqft.`,
        comps_considered: selection?.considered ?? considered,
        comps_usable: usable,
        comps_in_basis: perSqftVals.length,
        comps_below_floor: belowFloor,
        warnings,
        selection,
      });
    }
    // The subject size WAS known — say which side of the $/sqft gate actually failed, because the
    // verbatim-Swift note below blames the subject and would be misleading on its own.
    perSqftGate = sqftComps.length === 0 ? PER_SQFT_GATE.noCompSqft : PER_SQFT_GATE.tooFewSqftComps;
    if (sqftComps.length === 0) warnings.push('no_comp_carries_living_area');
  }

  // STEP 12 — MEDIAN SALE-PRICE FALLBACK: the INTEGER median over the FULL band-trimmed set.
  const medSale = medianInt(comps.map((c) => c.salePrice));
  if (medSale !== null) {
    return result({
      ok: true,
      available: true,
      basis: ARV_BASIS.soldCompsMedian,
      arv: medSale,
      perSqft: null,
      comps: shown,
      radiusMiles,
      // comps.length is the FULL trimmed set — it may exceed the 25 shown.
      note: `ARV from the median of ${comps.length} recent nearby recorded sales (no subject sqft to scale by $/sqft).`,
      comps_considered: selection?.considered ?? considered,
      comps_usable: usable,
      comps_in_basis: comps.length,
      comps_below_floor: belowFloor,
      perSqftGate,
      warnings,
      selection,
    });
  }

  // STEP 13 — FINAL GATE. Unreachable (`comps` is provably non-empty after STEP 3) but ported so
  // the branch exists; it refuses with a null ARV rather than becoming a live 0-returning path.
  return refuse(REFUSAL.noUsablePrice, 'Recent sales found but no usable price — nothing invented.');
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// arvFromRows — the ONE-SHOT entry a caller should use on raw county / API rows
// ─────────────────────────────────────────────────────────────────────────────────────────────

const DROP_SENTENCES = {
  no_price: (n) => `${n} with no recorded sale price`,
  below_price_floor: (n, floor) => `${n} below the $${floor.toLocaleString('en-US')} arm's-length floor`,
  no_date: (n) => `${n} with no parseable recorded sale date`,
  too_old: (n, _f, months) => `${n} older than the ${months}-month window`,
  future: (n) => `${n} dated after today`,
  malformed: (n) => `${n} malformed`,
};

/**
 * selectComps → calcARV in one call, with the honesty envelope preserved ACROSS the boundary.
 *
 * Calling the two separately loses information: when selection drops every row, calcARV receives
 * [] and can only report `comps_considered: 0` under the note "No recent recorded sales near this
 * address in the county roll." — which is affirmatively FALSE when the county roll returned 100
 * priced sales that were dropped for, say, an unparseable date format. This wrapper keeps the
 * upstream counts and replaces that note with what actually happened.
 */
/**
 * TIER 3 — the county-appraised AREA estimate. NOT a comp, and never presented as one.
 *
 * Alabama, Texas, Utah and the other NON-DISCLOSURE states do not make recorded sale prices
 * public, so the sold-comp tiers above can NEVER fire there no matter how much is harvested. The
 * Jefferson County AL parcel layer proves it: 74 fields, `AssdValue` among them, and not one
 * sale/price/deed column — `search_parcels(sold_after=...)` matches 0 rows in the whole index.
 * Refusing forever in those states is honest but useless; inventing a sale is worse. The middle
 * path is the county's OWN published appraisal, clearly labeled as an estimate.
 *
 * The Swift engine already carries this tier (`ARVBasis.assessedAVM`, Comps.swift step 3) and
 * both basis constants were reserved here from the start — only the wiring was missing.
 *
 * Honesty rules kept:
 *   - `isComp` is FALSE (assessedAreaEstimate is not a comp basis) so no caller can render the
 *     green comp seal off this figure.
 *   - MEDIAN, not mean: one civic parcel assessed at $8M cannot drag a residential street.
 *   - ONE basis only: appraised = land + improvement, which IS the county's fair-market appraisal.
 *     A bare `assessed_value` is a statutory RATIO of market value (AL Class II is 20%; the
 *     measured median assessed/sale on this corpus is 0.083 in CO, 0.64 in AZ, 0.79 in MI), so
 *     publishing it as `arv` understates by a state-specific multiple. Un-ratioing needs a
 *     per-state assessment-ratio table that does not exist here and would be a new claim surface,
 *     so a ratio-only row set is REFUSED, never valued. There is no second basis to fall back to,
 *     which is also why no row count can flip the basis (and the ARV) out from under a caller.
 *   - LOCALIZED to the subject when the subject carries lat/lng: this is a ring read around the
 *     parcel, not a median of whatever page of the county roll the caller happened to pull.
 *     Without subject coordinates the estimate is still returned, but flagged
 *     `assessed_estimate_not_localized_to_subject` and worded so it cannot be read as a valuation
 *     of any one parcel. A localized read never silently widens back to the whole set.
 *   - A minimum row count, so this can never be a median-of-one dressed as an area read.
 *
 * NOTE on `radiusMiles`: the sold-comp tiers treat it as a pass-through label and never filter on
 * it. This tier DOES filter on it — an area read with no area is the defect this rule exists to
 * stop — and states the ring it actually used in `note` and `radius_miles`.
 */
export function assessedAreaEstimate({ subject = {}, rows = [], options = {} } = {}) {
  const minRows = Number.isFinite(options.minRows) ? options.minRows : 5;
  const radiusMiles =
    Number.isFinite(options.radiusMiles) && options.radiusMiles > 0
      ? options.radiusMiles
      : DEFAULT_RADIUS_METERS / METERS_PER_MILE;

  const subj = subject ?? {};
  const sLat = firstUsable(subj, LAT_KEYS, dbl);
  const sLng = firstUsable(subj, LNG_KEYS, dbl);
  const localized = sLat !== null && sLng !== null;

  const appraised = [];
  let ratioOnlyRows = 0; // rows carrying ONLY a statutory assessed value — never valued
  let outsideRadius = 0;
  let withoutLocation = 0;

  for (const row of Array.isArray(rows) ? rows : []) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) continue;

    if (localized) {
      let miles = firstUsable(row, DIST_KEYS, dbl);
      if (miles === null) {
        const rLat = firstUsable(row, ['lat', 'latitude', 'y'], dbl);
        const rLng = firstUsable(row, ['lng', 'lon', 'long', 'longitude', 'x'], dbl);
        if (rLat === null || rLng === null) { withoutLocation += 1; continue; }
        miles = haversineMiles(sLat, sLng, rLat, rLng);
      }
      if (!(miles <= radiusMiles)) { outsideRadius += 1; continue; }
    }

    const land = money(row.land_value ?? row.landValue);
    const imp = money(row.improvement_value ?? row.improvementValue);
    if (land !== null && imp !== null && land + imp > 0) { appraised.push(land + imp); continue; }
    if (money(firstUsable(row, ASSESSED_KEYS, money)) !== null) ratioOnlyRows += 1;
  }

  const counts = {
    rows_with_appraised_value: appraised.length,
    rows_with_assessed_ratio_only: ratioOnlyRows,
    rows_outside_radius: outsideRadius,
    rows_without_location: withoutLocation,
    min_rows: minRows,
    localized,
    radius_miles: localized ? radiusMiles : null,
  };

  if (appraised.length < minRows) {
    const ratioOnly = ratioOnlyRows >= minRows;
    return {
      ok: false,
      reason: ratioOnly ? 'assessed_ratio_not_a_valuation' : 'insufficient_appraised_rows',
      arv: null,
      ...counts,
      note: ratioOnly
        ? `${ratioOnlyRows} row(s) here publish only a statutory ASSESSED value, which is a fixed ` +
          `RATIO of market value (Alabama Class II is 20%), not market value itself. Converting it ` +
          `would require a per-state ratio table this engine does not have, so no estimate is ` +
          `returned — nothing invented.`
        : `Only ${appraised.length} row(s) carried a county APPRAISED value (land + improvement); ` +
          `${minRows} required for an area estimate — nothing invented.`,
    };
  }

  const sorted = [...appraised].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const median = sorted.length % 2 ? sorted[mid] : Math.round((sorted[mid - 1] + sorted[mid]) / 2);
  const kind = 'county appraised (land + improvement)';

  return {
    ok: true,
    reason: null,
    arv: median,
    basis_values: sorted.length,
    value_kind: kind,
    low: sorted[0],
    high: sorted[sorted.length - 1],
    ...counts,
    warnings: localized ? [] : ['assessed_estimate_not_localized_to_subject'],
    note: localized
      ? `Estimate from the MEDIAN ${kind} of ${sorted.length} parcels within ` +
        `${radiusMiles.toFixed(1)} miles of the subject — NOT recorded sold comps, and not an ` +
        `appraisal of the subject itself. Treat as an area read.`
      : `Estimate from the MEDIAN ${kind} of the ${sorted.length} supplied parcels — NOT recorded ` +
        `sold comps, and NOT localized: no subject lat/lng was given, so this is a read of whatever ` +
        `rows were pulled and is NOT a valuation of any one property. Pass subject.lat/lng to scope ` +
        `it to a ${radiusMiles.toFixed(1)}-mile ring around the parcel.`,
  };
}

export function arvFromRows(args) {
  const { subject = {}, rows = [], options = {} } = args ?? {};
  const opts = options ?? {};
  const selection = selectComps({ subject, rows, options: opts });
  const r = calcARV({ subject, comps: selection.comps, options: { ...opts, selection } });
  if (r.ok) return r;

  // TIER 3 fallback, OPT-IN ONLY. Default-off so every existing caller's bytes are unchanged and
  // no one silently starts receiving `ok: true` off a non-comp basis where they used to get a
  // refusal. Only reachable once the sold-comp tiers have actually failed.
  if (opts.allowAssessedEstimate) {
    const est = assessedAreaEstimate({ subject, rows, options: opts });
    if (est.ok) {
      return result({
        ok: true,
        reason: null,
        available: true,
        basis: ARV_BASIS.assessedAreaEstimate,   // isComp === false by construction
        arv: est.arv,
        perSqft: null,
        comps: [],
        radiusMiles: est.radius_miles ?? dbl(opts.radiusMiles) ?? 0,
        note: est.note,
        source: COMPS_SOURCE.countyAssessed,
        // This basis IS an area read, and the flag is how a caller's UI knows not to render it as
        // a valuation of the subject parcel. Every comp path leaves it false (derive never sets it).
        isAreaRead: true,
        comps_considered: selection.considered,
        comps_usable: 0,
        comps_in_basis: 0,
        // The estimator's own envelope — how many parcels, which ring, how wide the spread. Without
        // it a caller cannot tell a 5-parcel read from a 500-parcel one.
        assessed: est,
        warnings: [...(r.warnings ?? []), 'assessed_area_estimate_not_sold_comps', ...(est.warnings ?? [])],
        selection,
      });
    }
  }

  if (selection.considered === 0) return r;

  const parts = [];
  for (const [key, n] of Object.entries(selection.dropped)) {
    if (n > 0) parts.push(DROP_SENTENCES[key](n, selection.minSalePrice, selection.lookbackMonths));
  }
  if (!parts.length) return r;
  return {
    ...r,
    reason: REFUSAL.noSelectableComps,
    note: `${selection.considered} nearby recorded row(s) found, none usable as a comp (${parts.join('; ')}) — ARV gated, nothing invented.`,
    comps_considered: selection.considered,
  };
}

export default { calcARV, selectComps, arvFromRows };
