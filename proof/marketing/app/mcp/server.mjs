#!/usr/bin/env node
// Marketing — MCP stdio server.
//
// Exposes nine tools over the vendored kit in ./mcp-kit.mjs, in three risk classes.
//
// READ-ONLY / DISK-ONLY — ungated, nothing leaves this machine:
//   marketing__list_connections    Social connection inventory; liveness from token expiry ONLY.
//   marketing__app_capabilities    Which headless paths the resolved binary was actually built
//                                  with, proven by marker bytes inside the binary.
//   marketing__generate_reel       Renders an .mp4 through `--render-reel`.
//   marketing__export_site         Writes a multi-page site pack through `--export-multipage`.
//   marketing__render_camera_take  Renders a recorded take through `--render-camera-take`.
//
// GATED — public, irreversible, or paid; off by default, each returns what it WOULD have done:
//   marketing__schedule_post      GATED (MKT_PUBLISH). Public + irreversible.
//   marketing__publish_due        GATED (MKT_PUBLISH_DUE) + per-call confirmation. Drains the
//                                 whole due queue to a real audience through `--publish-due`.
//   marketing__blitz_generate     GATED (MKT_BLITZ_SPEND) + per-call confirmation. SPENDS A PAID
//                                 CREDIT on every success.
//   marketing__send_message       GATED (MKT_MESSAGE_SEND). Public, irreversible, TCPA-regulated.
//
// Every headless tool declares the capability it needs in CAPABILITIES and is refused on a binary
// that predates that path, so a no-op is never reported as a success.
//
// Credentials are read from disk at call time and never hardcoded, never logged, never echoed.
// stdout carries JSON-RPC only; all logging goes to stderr through the kit's redacting logger.

import { spawn } from "node:child_process";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, openSync, readSync, closeSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import path from "node:path";

import { createServer, ToolError, listResult, okResult, loadSecret } from "./mcp-kit.mjs";

const SERVER_NAME = "marketing";
const SERVER_VERSION = "1.0.0";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = path.resolve(HERE, "..");

// ---------------------------------------------------------------------------
// Scheduling API (Fastlane) — base URL + credential file, both overridable by env.
// ---------------------------------------------------------------------------

const DEFAULT_API_BASE = "https://api.usefastlane.ai/api/v1";
const DEFAULT_CREDENTIALS_PATH = path.join(homedir(), ".utah", "secrets", "fastlane.json");

// TikTok delivery mode. "direct" publishes straight to the account; "inbox" drops the post
// into the TikTok app for a human to tap publish, and un-actioned inbox posts accumulate as
// "pending shares" until TikTok starts refusing new ones for that account.
const POSTING_MODES = ["direct", "inbox"];
const DEFAULT_POSTING_MODE = "direct";
const PRIVACY_LEVELS = ["PUBLIC_TO_EVERYONE", "MUTUAL_FOLLOW_FRIENDS", "FOLLOWER_OF_CREATOR", "SELF_ONLY"];
const DEFAULT_PRIVACY_LEVEL = "PUBLIC_TO_EVERYONE";
const USER_AGENT = `marketing-mcp/${SERVER_VERSION}`;

/** Instagram is not an available publish target in this build: Meta app review is still pending. */
const EXCLUDED_PLATFORMS = new Set(["instagram"]);
const SCHEDULABLE_PLATFORMS = ["tiktok", "youtube"];

function credentialsPath() {
  return process.env.MARKETING_SCHEDULER_CREDENTIALS || DEFAULT_CREDENTIALS_PATH;
}

/** Non-secret fields only. The API key is never read here. */
function credentialsMeta() {
  const file = credentialsPath();
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (err) {
    throw new ToolError(`Cannot read the scheduling credential file ${file}: ${err?.code || err?.message}`, {
      code: "CREDENTIALS_UNREADABLE",
    });
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new ToolError(`Scheduling credential file ${file} is not valid JSON: ${err?.message}`, { code: "CREDENTIALS_MALFORMED" });
  }
  return {
    file,
    base_url: (typeof parsed.base_url === "string" && parsed.base_url.trim()) || DEFAULT_API_BASE,
    workspace: typeof parsed.workspace === "string" ? parsed.workspace : null,
    key_name: typeof parsed.name === "string" ? parsed.name : null,
    has_api_key: typeof parsed.api_key === "string" && parsed.api_key.length > 0,
  };
}

/** Read the API key at call time. Registered with the redactor by the kit, so it can never print. */
function apiKey() {
  return loadSecret(credentialsPath(), { field: "api_key" });
}

async function apiRequest(method, endpoint, { body = null, signal = undefined } = {}) {
  const meta = credentialsMeta();
  const url = `${meta.base_url.replace(/\/+$/, "")}${endpoint}`;
  const headers = {
    Authorization: `Bearer ${apiKey()}`,
    Accept: "application/json",
    "User-Agent": USER_AGENT,
  };
  if (body !== null) headers["Content-Type"] = "application/json";

  let response;
  try {
    response = await fetch(url, {
      method,
      headers,
      body: body === null ? undefined : JSON.stringify(body),
      signal,
    });
  } catch (err) {
    throw new ToolError(`${method} ${url} failed at the network layer: ${err?.message || String(err)}`, {
      code: "API_UNREACHABLE",
      cause: err,
    });
  }

  const text = await response.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  if (!response.ok) {
    const detail = parsed?.error?.message || parsed?.message || text.slice(0, 400) || "(empty body)";
    throw new ToolError(`${method} ${url} returned HTTP ${response.status}: ${detail}`, {
      code: `API_HTTP_${response.status}`,
      details: {
        status: response.status,
        retry_after: response.headers.get("retry-after"),
        body: parsed ?? text.slice(0, 400),
      },
    });
  }
  if (parsed === null) {
    throw new ToolError(`${method} ${url} returned HTTP ${response.status} with a body that is not JSON: ${text.slice(0, 200)}`, {
      code: "API_BAD_BODY",
    });
  }
  return { status: response.status, json: parsed, url };
}

// ---------------------------------------------------------------------------
// Liveness — derived from token expiry and NOTHING else.
//
// The API's own `publishable` boolean is reported for comparison but is never used to decide
// liveness: it currently reads true for a credential whose token expired days ago, which is exactly
// how a schedule gets accepted and then fails silently at publish time.
// ---------------------------------------------------------------------------

function livenessFromExpiry(expiryMs, nowMs = Date.now()) {
  if (expiryMs === null || expiryMs === undefined || !Number.isFinite(Number(expiryMs))) return "unknown";
  return Number(expiryMs) > nowMs ? "live" : "expired";
}

function isoOrNull(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(Number(ms))) return null;
  return new Date(Number(ms)).toISOString();
}

// ---------------------------------------------------------------------------
// App bundle resolution — used by generate_reel and by the local credential probe.
// No product name is hardcoded: the bundle is discovered on disk and its own Info.plist is read.
// ---------------------------------------------------------------------------

// When this server runs from INSIDE a shipped bundle (Contents/Resources/mcp/server.mjs), the
// bundle it rides in is the app the buyer installed — so its parent directory is the first place
// to look. On a developer checkout this resolves to nothing and the build/Applications roots
// below carry on exactly as before.
const OWN_BUNDLE_MATCH = HERE.match(/^(.*)\/[^/]+\.app\/Contents\/Resources\/mcp$/);
const OWN_BUNDLE_ROOT = OWN_BUNDLE_MATCH ? OWN_BUNDLE_MATCH[1] : null;

const APP_SEARCH_ROOTS = [
  ...(OWN_BUNDLE_ROOT ? [OWN_BUNDLE_ROOT] : []),
  // A bundle built from the current sources and parked here for headless use. Nothing else writes
  // this directory, so it never collides with the Xcode/build lanes below it.
  path.join(REPO_ROOT, "build", "mcp-render"),
  path.join(REPO_ROOT, "build", "DerivedData", "Build", "Products", "Release"),
  path.join(REPO_ROOT, "build", "DerivedData", "Build", "Products", "Debug"),
  "/Applications",
];

const RENDER_FLAG = "--render-reel";
const RENDER_MARKER = "render_reel|state=Rendered";

/**
 * Headless capabilities this server drives, each keyed to a literal string the corresponding code
 * path in Sources/main.swift prints. The marker — not the flag name — is the probe: a flag name can
 * appear in an unrelated string table, whereas these markers only exist because the code path that
 * emits them was compiled in. A binary that predates a path is therefore rejected with a diagnosis
 * instead of being run and reported as a mysterious no-op.
 *
 * Adding a capability here is the ONLY place a new headless tool declares what build it requires.
 */
const CAPABILITIES = {
  render_reel: { flag: "--render-reel", marker: "render_reel|state=Rendered", source: "Sources/main.swift" },
  export_multipage: { flag: "--export-multipage", marker: "export-multipage: wrote ", source: "Sources/main.swift" },
  render_camera_take: { flag: "--render-camera-take", marker: "render_camera_take|state=", source: "Sources/main.swift" },
  publish_due: { flag: "--publish-due", marker: "publish_due|state=Error|reason=watchdog_timeout", source: "Sources/BackgroundPublish.swift" },
};

function appBundlesIn(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.endsWith(".app") && /marketing/i.test(e))
    .map((e) => path.join(dir, e))
    .filter((p) => {
      try {
        return statSync(p).isDirectory();
      } catch {
        return false;
      }
    });
}

function executableInBundle(bundlePath) {
  const macos = path.join(bundlePath, "Contents", "MacOS");
  let entries;
  try {
    entries = readdirSync(macos);
  } catch {
    return null;
  }
  for (const name of entries) {
    const full = path.join(macos, name);
    try {
      if (statSync(full).isFile()) return full;
    } catch {
      /* keep looking */
    }
  }
  return null;
}

function bundleIdentifier(bundlePath) {
  const plist = path.join(bundlePath, "Contents", "Info.plist");
  if (!existsSync(plist)) return null;
  try {
    const json = execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist], { encoding: "utf8" });
    const parsed = JSON.parse(json);
    return typeof parsed.CFBundleIdentifier === "string" ? parsed.CFBundleIdentifier : null;
  } catch {
    return null;
  }
}

/** True when this binary actually contains the code path that prints `marker`. */
function binaryContainsMarker(binaryPath, marker) {
  const needle = Buffer.from(marker, "utf8");
  const chunkSize = 4 * 1024 * 1024;
  const overlap = needle.length - 1;
  let fd;
  try {
    fd = openSync(binaryPath, "r");
  } catch {
    return false;
  }
  try {
    const buf = Buffer.alloc(chunkSize + overlap);
    let carried = 0;
    let position = 0;
    for (;;) {
      const bytes = readSync(fd, buf, carried, chunkSize, position);
      if (bytes <= 0) return false;
      position += bytes;
      const view = buf.subarray(0, carried + bytes);
      if (view.includes(needle)) return true;
      carried = Math.min(overlap, view.length);
      view.subarray(view.length - carried).copy(buf, 0);
    }
  } finally {
    closeSync(fd);
  }
}

/** True when this binary actually contains the headless render path (not just any build). */
function binarySupportsRenderFlag(binaryPath) {
  return binaryContainsMarker(binaryPath, RENDER_MARKER);
}

/**
 * Which of the declared headless capabilities this binary was actually built with. One pass per
 * capability; the answer is reported per capability rather than collapsed to a single boolean, so a
 * partially-updated build is diagnosable ("has the renderer, predates the site exporter") instead of
 * being rejected wholesale.
 */
function binaryCapabilities(binaryPath) {
  const out = {};
  for (const [key, spec] of Object.entries(CAPABILITIES)) {
    out[key] = binaryContainsMarker(binaryPath, spec.marker);
  }
  return out;
}

/**
 * Resolve the app bundle to drive. Explicit path wins, then MARKETING_APP_BINARY, then discovery.
 * Returns the candidates it rejected and why, so a failure is diagnosable instead of mysterious.
 */
function resolveApp({ binaryPath = null, requireRenderFlag = true, preferInstalled = false, capability = null } = {}) {
  const considered = [];
  // `capability` supersedes the older requireRenderFlag boolean: it names WHICH headless path the
  // caller needs. requireRenderFlag stays honoured so the existing reel lane behaves identically.
  if (capability !== null && !CAPABILITIES[capability]) {
    throw new ToolError(`Unknown headless capability ${JSON.stringify(capability)}. Declared: ${Object.keys(CAPABILITIES).join(", ")}.`, {
      code: "UNKNOWN_CAPABILITY",
    });
  }
  const required = capability ? CAPABILITIES[capability] : requireRenderFlag ? CAPABILITIES.render_reel : null;

  // An explicitly named binary is the ONLY candidate: silently rendering with a different build
  // than the caller asked for would make the result unattributable.
  const fromExplicit = binaryPath || process.env.MARKETING_APP_BINARY || null;
  const candidates = [];
  // Rendering wants the bundle built from CURRENT sources, so the build dirs come first.
  // Reading a user's stored credentials wants the bundle the user actually RUNS — the installed
  // /Applications copy. Those are different questions and must not share an answer: the build
  // copies are ad-hoc signed, the data-protection keychain add fails for an ad-hoc signature, and
  // so a probe aimed at a build copy reports every credential unreadable forever, no matter what
  // the user reconnects. See Sources/MarketingKeychain.swift (legacy fallback + build marker).
  const roots = preferInstalled
    ? ["/Applications", ...APP_SEARCH_ROOTS.filter((r) => r !== "/Applications")]
    : APP_SEARCH_ROOTS;
  if (fromExplicit) {
    candidates.push({ binary: path.resolve(fromExplicit), origin: binaryPath ? "argument" : "MARKETING_APP_BINARY" });
  } else {
    for (const root of roots) {
      for (const bundle of appBundlesIn(root)) {
        const exe = executableInBundle(bundle);
        if (exe) candidates.push({ binary: exe, bundle, origin: root });
      }
    }
  }

  for (const candidate of candidates) {
    if (!existsSync(candidate.binary)) {
      considered.push({ ...candidate, rejected: "file does not exist" });
      continue;
    }
    const supports = binarySupportsRenderFlag(candidate.binary);
    if (required && !binaryContainsMarker(candidate.binary, required.marker)) {
      considered.push({ ...candidate, rejected: `binary does not contain the ${required.flag} code path (${required.source})` });
      continue;
    }
    const bundle = candidate.bundle || path.resolve(path.dirname(candidate.binary), "..", "..");
    const st = statSync(candidate.binary);
    return {
      ok: true,
      binary: candidate.binary,
      bundle,
      bundle_id: bundleIdentifier(bundle),
      origin: candidate.origin,
      supports_render_flag: supports,
      capability: capability || (requireRenderFlag ? "render_reel" : null),
      capabilities: binaryCapabilities(candidate.binary),
      binary_bytes: st.size,
      binary_mtime_epoch: Math.floor(st.mtimeMs / 1000),
      considered,
    };
  }
  return { ok: false, considered, searched: APP_SEARCH_ROOTS };
}

function runBinary(binary, args, { signal, timeoutMs = 300_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { stdio: ["ignore", "pipe", "pipe"], signal });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* already gone */
      }
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      stdout += d;
    });
    child.stderr.on("data", (d) => {
      stderr += d;
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(new ToolError(`Failed to execute ${binary}: ${err?.message || String(err)}`, { code: "SPAWN_FAILED", cause: err }));
    });
    child.on("close", (code, sig) => {
      clearTimeout(timer);
      resolve({ code, signal: sig, stdout, stderr });
    });
  });
}

/** Parse the app's `key=value|key=value` result line into an object. */
function parseResultLine(stdout, prefix) {
  const line = stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith(`${prefix}|`))
    .pop();
  if (!line) return null;
  const out = { _line: line };
  for (const part of line.split("|").slice(1)) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    out[part.slice(0, eq)] = part.slice(eq + 1);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Local (on-device) social credential probe.
//
// KNOWN LIMITATION, reported rather than papered over: the tokens live in the app's Keychain,
// whose access control admits the app — not this Node process — so no headless process can read
// the token bytes. This probe therefore reads only non-secret UserDefaults records (the app's
// legacy-readable markers + expiry store) and states plainly what it could not determine.
//
// The marker rule below matches the SHIPPED reader (Sources/MarketingKeychain.swift, DOD-7.4):
// the app honours a legacy marker written by ANY build of this app (bundle-identifier prefix
// match) and re-stamps it to the current build on a successful read. The old exact-match rule
// (marker === current build's marker) is gone — it orphaned every credential on every update.
// `token_readable_headlessly` therefore answers "would the APP's silent, no-prompt read path
// accept this row?", never "can this server read it" (it never can).
// ---------------------------------------------------------------------------

const LEGACY_MARKER_PREFIX = "blm.keychain.legacy-readable."; // the app's own UserDefaults key prefix
const EXPIRY_PREFIX = "SocialTokenExpiry.v1."; // written by the app beside every token it saves

function decodeXmlEntities(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

/**
 * Enumerate the keys of a preference file. The file is converted to XML rather than JSON because
 * these preferences legitimately contain `data` blobs, which have no JSON representation — asking
 * plutil for JSON fails outright on this exact file.
 */
function preferenceKeys(file) {
  const xml = execFileSync("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", file], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const keys = new Set();
  const re = /<key>([\s\S]*?)<\/key>/g;
  let m;
  while ((m = re.exec(xml)) !== null) keys.add(decodeXmlEntities(m[1]));
  return [...keys];
}

/** Read one preference value as a raw scalar. Returns null when the key is absent or non-scalar. */
function preferenceValue(file, key) {
  try {
    return execFileSync("/usr/bin/plutil", ["-extract", key.replace(/\./g, "\\."), "raw", "-o", "-", file], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

function readPreferences(bundleId) {
  const file = path.join(homedir(), "Library", "Preferences", `${bundleId}.plist`);
  if (!existsSync(file)) return { file, present: false, keys: [] };
  try {
    return { file, present: true, keys: preferenceKeys(file) };
  } catch (err) {
    throw new ToolError(`Cannot decode the app preference file ${file}: ${err?.message || String(err)}`, {
      code: "PREFERENCES_UNREADABLE",
    });
  }
}

function localCredentialReport(now = Date.now()) {
  // preferInstalled: report on the copy the user actually runs, not a build artifact.
  const app = resolveApp({ requireRenderFlag: false, preferInstalled: true });
  if (!app.ok) {
    return {
      available: false,
      reason: "No installed or built app bundle was found, so neither the bundle identifier nor the build marker could be determined.",
      searched: app.searched,
    };
  }
  const bundleId = app.bundle_id;
  if (!bundleId) {
    return { available: false, reason: `Could not read CFBundleIdentifier from ${app.bundle}.` };
  }

  const prefs = readPreferences(bundleId);
  const currentMarker = `${bundleId}|${app.binary_mtime_epoch}|${app.binary_bytes}`;

  // Accounts are discovered from BOTH the legacy-readable markers and the expiry store, so a
  // credential recorded by only one of them is still reported instead of quietly vanishing.
  const accounts = new Map(); // account -> { markerKey?, expiryKey? }
  for (const key of prefs.keys) {
    let account = null;
    let field = null;
    if (key.startsWith(LEGACY_MARKER_PREFIX)) {
      account = key.slice(LEGACY_MARKER_PREFIX.length);
      field = "markerKey";
    } else if (key.startsWith(EXPIRY_PREFIX)) {
      account = key.slice(EXPIRY_PREFIX.length);
      field = "expiryKey";
    }
    if (!account || !/\.social\.[a-z0-9_]+$/i.test(account)) continue;
    const normalized = account.toLowerCase();
    const entry = accounts.get(normalized) || { account };
    entry[field] = key;
    accounts.set(normalized, entry);
  }

  const rows = [];
  for (const { account, markerKey, expiryKey } of accounts.values()) {
    const platform = account.match(/\.social\.([a-z0-9_]+)$/i)[1].toLowerCase();
    const marker = markerKey ? preferenceValue(prefs.file, markerKey) : null;
    const rawExpiry = expiryKey ? preferenceValue(prefs.file, expiryKey) : null;
    const seconds = rawExpiry === null || rawExpiry === "" ? null : Number(rawExpiry);
    const expiryMs = seconds !== null && Number.isFinite(seconds) ? seconds * 1000 : null;
    // Mirror of the shipped reader's rule (per-bundle, DOD-7.4): a marker written by ANY build
    // of this app is honoured; the build components (mtime|size) are provenance, not a gate.
    const markerFromThisApp = marker !== null && marker.startsWith(`${bundleId}|`);
    rows.push({
      source: "local_device",
      platform,
      keychain_account: account,
      token_expiry: isoOrNull(expiryMs),
      liveness: livenessFromExpiry(expiryMs, now),
      liveness_basis:
        expiryMs === null
          ? "no expiry was ever recorded on this device -> unknown, never assumed live"
          : "recorded expiry vs now",
      token_readable_headlessly: markerFromThisApp,
      marker_recorded_by:
        marker === null
          ? null
          : marker === currentMarker
            ? "this build"
            : markerFromThisApp
              ? "a previous build of this app (the reader accepts it and re-stamps on read)"
              : "not this app",
      token_read_blocker: markerFromThisApp
        ? null
        : marker === null
          ? "No legacy-readable marker is recorded for this account, so a headless process cannot confirm the token is present, let alone read it."
          : `The recorded marker (${marker}) was not written by this app (bundle ${bundleId}), so the app's Keychain reader never probes this row. Reconnect the account in the app to store the token under this app's identity.`,
      schedulable: false,
      schedulable_reason:
        "Device-stored credentials drive the app's own in-app publish path, not this server's scheduling API. Listed for visibility only.",
    });
  }
  rows.sort((a, b) => a.platform.localeCompare(b.platform));

  return {
    available: true,
    bundle_id: bundleId,
    bundle: app.bundle,
    preferences_file: prefs.file,
    current_build_marker: currentMarker,
    rows,
    note:
      rows.length === 0
        ? "No device-stored social credential markers were found in this app's preferences. Verified zero, not an error."
        : "Expiry values come from the app's own non-secret expiry store. No token bytes were requested.",
  };
}

// ---------------------------------------------------------------------------
// Tool: marketing__list_connections
// ---------------------------------------------------------------------------

async function listConnections(_args, { signal } = {}) {
  const now = Date.now();
  const meta = credentialsMeta();
  const { json, url } = await apiRequest("GET", "/connections", { signal });
  const raw = Array.isArray(json?.data) ? json.data : Array.isArray(json) ? json : null;
  if (raw === null) {
    throw new ToolError(`GET ${url} returned a body with no connection array (keys: ${Object.keys(json || {}).join(", ") || "none"}).`, {
      code: "UNEXPECTED_SHAPE",
    });
  }

  const perPlatformCount = {};
  for (const c of raw) {
    const p = String(c.platform || "unknown").toLowerCase();
    perPlatformCount[p] = (perPlatformCount[p] || 0) + 1;
  }

  const items = raw.map((c) => {
    const platform = String(c.platform || "unknown").toLowerCase();
    const expiryMs = Number.isFinite(Number(c.tokenExpiry)) ? Number(c.tokenExpiry) : null;
    const liveness = livenessFromExpiry(expiryMs, now);
    const excluded = EXCLUDED_PLATFORMS.has(platform);
    const schedulableHere = SCHEDULABLE_PLATFORMS.includes(platform);
    return {
      source: "scheduling_api",
      id: c._id ?? c.id ?? null,
      platform,
      username: c.platformUsername ?? null,
      platform_user_id: c.platformUserId ?? null,
      token_expiry: isoOrNull(expiryMs),
      liveness,
      liveness_basis:
        expiryMs === null
          ? "the API reported no tokenExpiry -> unknown, never assumed live"
          : "tokenExpiry vs now (the ONLY input; the API's publishable flag is not consulted)",
      api_publishable_flag: c.publishable ?? null,
      flag_contradicts_expiry: c.publishable === true && liveness === "expired",
      scopes: Array.isArray(c.scopes) ? c.scopes : [],
      connection_id_required_to_schedule: (perPlatformCount[platform] || 0) > 1,
      schedulable: !excluded && schedulableHere && liveness !== "expired",
      schedulable_reason: excluded
        ? "excluded: Instagram is not an available publish target in this build (Meta app review pending)"
        : !schedulableHere
          ? `platform "${platform}" is not a supported scheduling target of this server`
          : liveness === "expired"
            ? "credential expired — scheduling would be accepted and then fail at publish time; reconnect first"
            : liveness === "unknown"
              ? "no expiry on record — allowed, but liveness is unverified"
              : "credential live",
      created_at: isoOrNull(c.createdAt),
      updated_at: isoOrNull(c.updatedAt),
    };
  });

  const warnings = [];
  for (const item of items) {
    if (item.flag_contradicts_expiry) {
      warnings.push(
        `${item.platform} "${item.username}" is DEAD: its token expired ${item.token_expiry}, yet the API still reports publishable=true. Any post scheduled against it will fail at publish time. Reconnect it.`
      );
    } else if (item.liveness === "expired") {
      warnings.push(`${item.platform} "${item.username}" token expired ${item.token_expiry}.`);
    }
  }

  let local;
  try {
    local = localCredentialReport(now);
  } catch (err) {
    local = { available: false, reason: err?.message || String(err) };
  }
  for (const row of local.rows || []) {
    if (row.token_read_blocker) {
      warnings.push(`local ${row.platform}: ${row.token_read_blocker}`);
    }
  }

  const all = [...items, ...(local.rows || [])];
  return listResult(all, {
    what: "social connections",
    source: `${meta.base_url}/connections + on-device credential records`,
    checked_at: new Date(now).toISOString(),
    workspace: meta.workspace,
    summary: {
      scheduling_api: {
        total: items.length,
        live: items.filter((i) => i.liveness === "live").length,
        expired: items.filter((i) => i.liveness === "expired").length,
        unknown: items.filter((i) => i.liveness === "unknown").length,
        per_platform: perPlatformCount,
      },
      local_device: {
        total: (local.rows || []).length,
        readable_headlessly: (local.rows || []).filter((r) => r.token_readable_headlessly).length,
      },
    },
    liveness_rule:
      "liveness is computed ONLY from token expiry vs now. A missing expiry is reported as unknown, never as live. The API's publishable flag is reported for comparison and is never used.",
    excluded_platforms: [...EXCLUDED_PLATFORMS],
    local_device_probe: local.available ? { ...local, rows: undefined } : local,
    warnings,
  });
}

// ---------------------------------------------------------------------------
// Music: making a supplied track actually reach the audio pass, and proving it did.
//
// The renderer's audio pass only runs when the PROJECT asks for it — a supplied --music file is
// the source, never the switch. A project that does not set music.enabled renders silently while
// the renderer still reports `music=loaded`, meaning only "the file was found and handed over".
// So: when a caller supplies music, this server turns the project's own music switch on and points
// its source at the supplied track, and afterwards it reads the finished .mp4 to confirm an audio
// track really exists. "Handed to the renderer" is not evidence; a track in the container is.
// ---------------------------------------------------------------------------

/** Raw values of the app's own MusicSource enum, as the project JSON encodes them. */
const MUSIC_SOURCE_SUPPLIED_FILE = "My track";
const MUSIC_SOURCE_GENERATED_BED = "Built-in bed";

function absPath(raw) {
  return path.resolve(String(raw).replace(/^~(?=$|\/)/, homedir()));
}

/**
 * Return the project the renderer must receive so that a supplied track is actually mixed in,
 * plus the exact list of switches this server had to flip. An empty `changes` array means the
 * caller's project already asked for the track and nothing was rewritten.
 */
function projectWithSuppliedTrackEnabled(projectObject) {
  const before = projectObject && typeof projectObject.music === "object" && projectObject.music !== null ? projectObject.music : null;
  const music = { ...(before || {}) };
  const changes = [];
  if (music.enabled !== true) {
    changes.push(`music.enabled: ${JSON.stringify(before?.enabled ?? null)} -> true`);
    music.enabled = true;
  }
  if (music.source !== MUSIC_SOURCE_SUPPLIED_FILE) {
    changes.push(`music.source: ${JSON.stringify(before?.source ?? null)} -> ${JSON.stringify(MUSIC_SOURCE_SUPPLIED_FILE)}`);
    music.source = MUSIC_SOURCE_SUPPLIED_FILE;
  }
  // Level and fades are deliberately NOT invented here: absent keys keep the app's own defaults.
  return { project: { ...projectObject, music }, changes };
}

/** One ISO-BMFF box header at `offset`. Handles 32-bit, 64-bit (size==1) and to-EOF (size==0). */
function readBoxHeader(fd, offset, fileSize) {
  const head = Buffer.alloc(16);
  const read = readSync(fd, head, 0, 16, offset);
  if (read < 8) return null;
  let size = head.readUInt32BE(0);
  const type = head.toString("latin1", 4, 8);
  let headerBytes = 8;
  if (size === 1) {
    if (read < 16) return null;
    size = head.readUInt32BE(8) * 2 ** 32 + head.readUInt32BE(12);
    headerBytes = 16;
  } else if (size === 0) {
    size = fileSize - offset;
  }
  if (size < headerBytes || offset + size > fileSize) return null;
  return { size, type, headerBytes };
}

/** Iterate the child boxes inside an already-loaded container payload. */
function* boxesIn(buf) {
  let at = 0;
  while (at + 8 <= buf.length) {
    let size = buf.readUInt32BE(at);
    const type = buf.toString("latin1", at + 4, at + 8);
    let headerBytes = 8;
    if (size === 1) {
      if (at + 16 > buf.length) return;
      size = buf.readUInt32BE(at + 8) * 2 ** 32 + buf.readUInt32BE(at + 12);
      headerBytes = 16;
    } else if (size === 0) {
      size = buf.length - at;
    }
    if (size < headerBytes || at + size > buf.length) return;
    yield { type, payload: buf.subarray(at + headerBytes, at + size) };
    at += size;
  }
}

const HANDLER_CONTAINERS = new Set(["trak", "mdia", "minf", "stbl", "edts", "udta"]);

/** Count the `hdlr` handler types under a moov payload: 'soun' = audio track, 'vide' = video. */
function countHandlers(payload, counts) {
  for (const box of boxesIn(payload)) {
    if (box.type === "hdlr") {
      // FullBox: version(1) flags(3) pre_defined(4) handler_type(4)
      if (box.payload.length >= 12) {
        const kind = box.payload.toString("latin1", 8, 12);
        counts[kind] = (counts[kind] || 0) + 1;
      }
    } else if (HANDLER_CONTAINERS.has(box.type)) {
      countHandlers(box.payload, counts);
    }
  }
}

/**
 * Read the finished container and report how many audio/video tracks it declares. Self-contained:
 * no ffprobe, no external tool, no network. A file it cannot parse comes back parsed:false with the
 * reason — never as "zero audio tracks", because unparsed and silent are different facts.
 */
function mp4TrackCensus(filePath) {
  let fd;
  let fileSize;
  try {
    fileSize = statSync(filePath).size;
    fd = openSync(filePath, "r");
  } catch (err) {
    return { parsed: false, reason: `cannot open ${filePath}: ${err?.code || err?.message}` };
  }
  try {
    let offset = 0;
    let sawAnyBox = false;
    while (offset < fileSize) {
      const box = readBoxHeader(fd, offset, fileSize);
      if (!box) return { parsed: false, reason: sawAnyBox ? `malformed box at byte ${offset}` : "not an ISO-BMFF/MP4 container" };
      sawAnyBox = true;
      if (box.type === "moov") {
        const bodyBytes = box.size - box.headerBytes;
        if (bodyBytes > 128 * 1024 * 1024) return { parsed: false, reason: `moov is implausibly large (${bodyBytes} bytes)` };
        const body = Buffer.alloc(bodyBytes);
        const got = readSync(fd, body, 0, bodyBytes, offset + box.headerBytes);
        if (got !== bodyBytes) return { parsed: false, reason: `moov truncated (${got}/${bodyBytes} bytes)` };
        const counts = {};
        countHandlers(body, counts);
        return { parsed: true, audio: counts.soun || 0, video: counts.vide || 0, handlers: counts };
      }
      offset += box.size;
    }
    return { parsed: false, reason: "no moov box found (the file declares no tracks at all)" };
  } catch (err) {
    return { parsed: false, reason: `read failed: ${err?.message || String(err)}` };
  } finally {
    try {
      closeSync(fd);
    } catch {
      /* already closed */
    }
  }
}

// ---------------------------------------------------------------------------
// Tool: marketing__generate_reel
// ---------------------------------------------------------------------------

async function generateReel(args, { signal } = {}) {
  const { project = null, project_path = null, output_path, assets_dir = null, logo_path = null, music_path = null, binary_path = null } = args;

  if (!project && !project_path) {
    throw new ToolError(`generate_reel needs either "project" (an inline reel project object) or "project_path" (a .json file). Neither was supplied.`, {
      code: "NO_PROJECT",
    });
  }
  if (project && project_path) {
    throw new ToolError(`generate_reel received both "project" and "project_path". Supply exactly one so it is unambiguous which one rendered.`, {
      code: "AMBIGUOUS_PROJECT",
    });
  }

  const app = resolveApp({ binaryPath: binary_path, requireRenderFlag: true });
  if (!app.ok) {
    // An explicitly named binary is the only candidate, and in that case NOTHING was searched —
    // saying otherwise would misdescribe what the server actually did.
    const explicit = app.considered.find((c) => c.origin === "argument" || c.origin === "MARKETING_APP_BINARY");
    const whereClause = explicit
      ? `Only the explicitly supplied binary was considered (via ${explicit.origin}); the default search roots were NOT consulted.`
      : `Searched ${app.searched.join(", ")}.`;
    throw new ToolError(
      `No app binary containing the ${RENDER_FLAG} path was found. ${whereClause} ` +
        `Set MARKETING_APP_BINARY (or pass binary_path) to a binary built from the current sources, or build one first. ` +
        `Candidates rejected: ${app.considered.length ? app.considered.map((c) => `${c.binary} (${c.rejected})`).join("; ") : "none found"}`,
      {
        code: "APP_BINARY_NOT_FOUND",
        details: { considered: app.considered, searched: explicit ? [] : app.searched, explicit_binary_only: Boolean(explicit) },
      }
    );
  }

  // Music is resolved BEFORE anything is spawned: a track that cannot be read is a failure of the
  // call, not something to discover after burning a render.
  let musicResolved = null;
  if (music_path) {
    musicResolved = absPath(music_path);
    if (!existsSync(musicResolved)) {
      throw new ToolError(`music_path does not exist: ${musicResolved}. Nothing was rendered — a reel that silently loses the requested track is not the reel that was asked for.`, {
        code: "MUSIC_FILE_NOT_FOUND",
      });
    }
    let musicStat;
    try {
      musicStat = statSync(musicResolved);
    } catch (err) {
      throw new ToolError(`music_path cannot be read: ${musicResolved} (${err?.code || err?.message}).`, { code: "MUSIC_FILE_UNREADABLE" });
    }
    if (!musicStat.isFile()) {
      throw new ToolError(`music_path is not a file: ${musicResolved}.`, { code: "MUSIC_FILE_UNREADABLE" });
    }
    if (musicStat.size <= 0) {
      throw new ToolError(`music_path is zero bytes: ${musicResolved}. An empty file cannot be mixed.`, { code: "MUSIC_FILE_EMPTY" });
    }
  }

  // The project object, when this server can see it. Needed both to flip the music switch and to
  // know whether audio is expected at all.
  let projectObject = project || null;
  let projectPathResolved = null;
  if (project_path) {
    projectPathResolved = absPath(project_path);
    if (!existsSync(projectPathResolved)) {
      throw new ToolError(`project_path does not exist: ${projectPathResolved}`, { code: "PROJECT_NOT_FOUND" });
    }
    try {
      projectObject = JSON.parse(readFileSync(projectPathResolved, "utf8"));
      if (projectObject === null || typeof projectObject !== "object" || Array.isArray(projectObject)) {
        throw new Error(`the file contains ${Array.isArray(projectObject) ? "an array" : typeof projectObject}, not a reel project object`);
      }
    } catch (err) {
      // Only fatal here when the file must be rewritten to honour a supplied track. Otherwise the
      // renderer reports `unreadable_project` itself and that reason is the better one to surface.
      if (musicResolved) {
        throw new ToolError(
          `project_path is not readable JSON (${err?.message}), so the music switch it needs could not be set: ${projectPathResolved}. ` +
            `Rendering anyway would have produced a silent reel reported as success.`,
          { code: "PROJECT_UNREADABLE" }
        );
      }
      projectObject = null;
    }
  } else if (!Array.isArray(project.scenes) || project.scenes.length === 0) {
    throw new ToolError(
      `The inline project has no scenes. The renderer requires at least one scene; rendering an empty project would produce nothing.`,
      { code: "PROJECT_NO_SCENES" }
    );
  }

  // Flip the project's own music switch when a track was supplied. Without this the renderer's
  // audio pass never runs and the reel ships silent while still reporting `music=loaded`.
  let musicSwitchChanges = [];
  let renderProject = projectObject;
  if (musicResolved && projectObject) {
    const patched = projectWithSuppliedTrackEnabled(projectObject);
    renderProject = patched.project;
    musicSwitchChanges = patched.changes;
  }

  const projectMusic = renderProject && typeof renderProject.music === "object" ? renderProject.music : null;
  const musicExpected = Boolean(musicResolved) || projectMusic?.enabled === true;
  const musicKind = musicResolved
    ? "supplied file"
    : projectMusic?.enabled === true
      ? projectMusic?.source === MUSIC_SOURCE_SUPPLIED_FILE
        ? "project asks for a supplied file but none was given"
        : MUSIC_SOURCE_GENERATED_BED
      : "none";

  // A project asking for a supplied track with no track supplied can only render silent. Say so now.
  if (!musicResolved && projectMusic?.enabled === true && projectMusic?.source === MUSIC_SOURCE_SUPPLIED_FILE) {
    throw new ToolError(
      `The project sets music.enabled with music.source ${JSON.stringify(MUSIC_SOURCE_SUPPLIED_FILE)} but no music_path was supplied, ` +
        `so the renderer would have had no track to mix and would have shipped a silent reel. ` +
        `Supply music_path, or set music.source to ${JSON.stringify(MUSIC_SOURCE_GENERATED_BED)} to use the on-device bed.`,
      { code: "MUSIC_SOURCE_WITHOUT_FILE" }
    );
  }

  // Write the project the renderer will actually read. A caller-supplied file is only copied when
  // this server had to change something in it; the caller's own file is never modified.
  let inputPath;
  let tempDir = null;
  if (projectPathResolved && musicSwitchChanges.length === 0) {
    inputPath = projectPathResolved;
  } else {
    tempDir = mkdtempSync(path.join(tmpdir(), "reel-project-"));
    inputPath = path.join(tempDir, "project.json");
    writeFileSync(inputPath, JSON.stringify(renderProject, null, 2), "utf8");
  }

  const outPath = absPath(output_path);
  const argv = [RENDER_FLAG, inputPath, outPath];
  if (assets_dir) argv.push("--assets", absPath(assets_dir));
  if (logo_path) argv.push("--logo", absPath(logo_path));
  if (musicResolved) argv.push("--music", musicResolved);

  const started = Date.now();
  let run;
  let elapsedMs;
  try {
    run = await runBinary(app.binary, argv, { signal });
    elapsedMs = Date.now() - started;
  } finally {
    // The renderer has exited (or failed to start); the scratch project is dead either way.
    // Leaving these behind is how 18 reel-project-* directories accumulated in the temp dir.
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  }
  const parsed = parseResultLine(run.stdout, "render_reel");

  if (run.code !== 0 || !parsed || parsed.state !== "Rendered") {
    throw new ToolError(
      `Reel render FAILED (exit ${run.code}${run.signal ? `, signal ${run.signal}` : ""}). ` +
        `Renderer said: ${parsed?._line || run.stdout.trim() || run.stderr.trim() || "(no output)"}`,
      {
        code: parsed?.reason ? `RENDER_${String(parsed.reason).toUpperCase()}` : "RENDER_FAILED",
        details: {
          exit_code: run.code,
          reason: parsed?.reason ?? null,
          stdout: run.stdout.trim().slice(0, 2000),
          stderr: run.stderr.trim().slice(0, 2000),
          command: [app.binary, ...argv],
        },
      }
    );
  }

  // Prove the artifact instead of trusting the exit code.
  if (!existsSync(outPath)) {
    throw new ToolError(`The renderer reported success but no file exists at ${outPath}.`, { code: "OUTPUT_MISSING" });
  }
  const bytes = statSync(outPath).size;
  if (bytes <= 0) {
    throw new ToolError(`The renderer reported success but ${outPath} is zero bytes.`, { code: "OUTPUT_EMPTY" });
  }

  // Prove the SOUND too. The renderer's `music=loaded` means only that the file was found and
  // handed over; when the mix fails it ships the silent video and still reports Rendered. The one
  // fact that settles it is whether the finished container declares an audio track.
  const census = mp4TrackCensus(outPath);
  if (musicExpected) {
    if (!census.parsed) {
      throw new ToolError(
        `Music was requested but the rendered file could not be inspected to confirm it: ${census.reason}. ` +
          `An unverifiable render is not a successful one, so this is reported as a failure rather than as sound that is probably there. File left at ${outPath}.`,
        { code: "MUSIC_UNVERIFIED", details: { output_path: outPath, bytes, renderer_line: parsed._line, probe: census } }
      );
    }
    if (census.audio === 0) {
      throw new ToolError(
        `SILENT RENDER: music was requested${musicResolved ? ` (${musicResolved})` : ""} and the renderer reported music=${parsed.music}, ` +
          `but the finished file declares ${census.audio} audio tracks and ${census.video} video tracks — the audio mix did not survive. ` +
          `The renderer falls back to shipping the silent video when the mix fails, so "Rendered" alone does not mean the track is in there. ` +
          `The silent file is left at ${outPath} for inspection; it is NOT a successful result. ` +
          `Most likely the supplied track is not decodable by the system audio stack (try a .m4a/.aac/.wav/.mp3 that opens in a player).`,
        {
          code: "MUSIC_NOT_RENDERED",
          details: {
            output_path: outPath,
            bytes,
            music_path: musicResolved,
            music_switch_changes: musicSwitchChanges,
            renderer_line: parsed._line,
            track_census: census,
          },
        }
      );
    }
  }

  return okResult(
    {
      output_path: outPath,
      bytes,
      scenes: Number(parsed.scenes),
      frames: Number(parsed.frames),
      seconds: Number(parsed.seconds),
      fps: Number(parsed.fps),
      format: parsed.format,
      logo: parsed.logo,
      backgrounds: parsed.backgrounds,
      missing_backgrounds: parsed.missing_backgrounds === "none" ? [] : String(parsed.missing_backgrounds).split(","),
      // What the renderer said about the FILE (found and handed over) …
      music_file: parsed.music,
      music_requested: musicExpected,
      music_kind: musicKind,
      // … and what the finished container actually contains.
      audio_tracks: census.parsed ? census.audio : null,
      video_tracks: census.parsed ? census.video : null,
      music_in_output: census.parsed ? census.audio > 0 : null,
      output_inspection: census.parsed ? "read from the file's own track table" : `not inspectable: ${census.reason}`,
      renderer_line: parsed._line,
    },
    {
      what: "rendered reel",
      source: `${app.binary} ${RENDER_FLAG}`,
      binary_origin: app.origin,
      project_input: inputPath,
      project_input_was_temporary: Boolean(tempDir),
      project_input_removed_after_render: Boolean(tempDir),
      music_switch_changes: musicSwitchChanges,
      elapsed_ms: elapsedMs,
      note:
        parsed.missing_backgrounds === "none"
          ? "Every requested background was loaded."
          : `Scenes referencing ${parsed.missing_backgrounds} rendered on the style gradient because those files were not found in assets_dir.`,
      audio_note: musicExpected
        ? `Music was requested and ${census.audio} audio track(s) were found in the finished file. music_in_output is read from the container, not from the renderer's own report.`
        : census.parsed && census.audio > 0
          ? `No music was requested; the file still carries ${census.audio} audio track(s) (narration or clip sound).`
          : "No music was requested and the file carries no audio track — this reel is silent by design.",
    }
  );
}

// ---------------------------------------------------------------------------
// Tool: marketing__schedule_post  (GATED — public and irreversible)
// ---------------------------------------------------------------------------

function schedulePayload(args) {
  const body = {
    platform: args.platform,
    utc_datetime: args.utc_datetime,
    caption: args.caption,
    // Measured 2026-08-18 over the full 127-post history: posting_mode "direct" produced
    // 23 posts, 0 failures, 0 stranded. Omitting it defaults the API to "inbox", which
    // produced 74 posts, 29 still sitting unpublished in TikTok inboxes, and 4 rejections
    // with spam_risk_too_many_pending_share once that backlog built up. Direct is the
    // default here for that reason; "inbox" stays reachable but must be asked for.
    posting_mode: args.posting_mode || DEFAULT_POSTING_MODE,
  };
  // TikTok's direct-post path requires an explicit privacy level. Every direct post that
  // succeeded carried PUBLIC_TO_EVERYONE; the failed inbox posts carried none.
  if (body.posting_mode === "direct") {
    body.privacy_level = args.privacy_level || DEFAULT_PRIVACY_LEVEL;
  }
  if (args.description) body.description = args.description;
  if (args.connection_id) body.connectionId = args.connection_id;
  return body;
}

function scheduleRequestShape(args) {
  const meta = credentialsMeta();
  return {
    method: "POST",
    url: `${meta.base_url.replace(/\/+$/, "")}/content/${encodeURIComponent(args.content_id)}/schedule`,
    headers: {
      Authorization: `Bearer <api_key read from ${meta.file} at call time — never printed, never stored here>`,
      "Content-Type": "application/json",
      Accept: "application/json",
      "User-Agent": USER_AGENT,
    },
    body: schedulePayload(args),
    workspace: meta.workspace,
    credential_file: meta.file,
    credential_file_has_api_key: meta.has_api_key,
  };
}

async function schedulePreflight(args, { signal } = {}) {
  // Read-only lookup. Reports what it found; a failure here is reported, not swallowed.
  try {
    const { json } = await apiRequest("GET", "/connections", { signal });
    const rows = Array.isArray(json?.data) ? json.data : [];
    const platformRows = rows.filter((r) => String(r.platform).toLowerCase() === String(args.platform).toLowerCase());
    // With no connectionId the API posts from the sole connection when there is exactly one — so
    // that one is the account whose liveness actually decides whether this schedule can succeed.
    const matched = args.connection_id
      ? platformRows.find((r) => r._id === args.connection_id) || null
      : platformRows.length === 1
        ? platformRows[0]
        : null;
    const expiryMs = matched && Number.isFinite(Number(matched.tokenExpiry)) ? Number(matched.tokenExpiry) : null;
    const problems = [];
    if (platformRows.length === 0) {
      problems.push(`No ${args.platform} connection exists on this workspace. The schedule call would fail.`);
    }
    if (platformRows.length > 1 && !args.connection_id) {
      problems.push(
        `${platformRows.length} ${args.platform} connections exist, so connectionId is MANDATORY. Without it the API cannot tell which account to post from.`
      );
    }
    if (args.connection_id && !matched) {
      problems.push(`connection_id "${args.connection_id}" does not match any ${args.platform} connection on this workspace.`);
    }
    if (matched && livenessFromExpiry(expiryMs) === "expired") {
      problems.push(
        `The chosen connection's token expired ${isoOrNull(expiryMs)} (its publishable flag reads ${matched.publishable}). Scheduling would be accepted and then fail at publish time.`
      );
    }
    return {
      checked: true,
      platform_connection_count: platformRows.length,
      connection_id_required: platformRows.length > 1,
      chosen_connection: matched
        ? {
            id: matched._id,
            selected_by: args.connection_id ? "connection_id argument" : "sole connection for this platform",
            username: matched.platformUsername,
            token_expiry: isoOrNull(expiryMs),
            liveness: livenessFromExpiry(expiryMs),
            api_publishable_flag: matched.publishable,
          }
        : null,
      available_connections: platformRows.map((r) => ({
        id: r._id,
        username: r.platformUsername,
        token_expiry: isoOrNull(r.tokenExpiry),
        liveness: livenessFromExpiry(Number(r.tokenExpiry)),
      })),
      problems,
    };
  } catch (err) {
    return {
      checked: false,
      error: err?.message || String(err),
      note: "The read-only connection lookup failed, so connection validity could NOT be confirmed. This is reported rather than assumed fine.",
      problems: [],
    };
  }
}

async function scheduleDryRun(args, { signal } = {}) {
  const request = scheduleRequestShape(args);
  const preflight = await schedulePreflight(args, { signal });
  return {
    executed: false,
    network_calls_made: ["GET /connections (read-only preflight)"],
    would_send: request,
    undo_path: {
      endpoint: "POST /posts/cancel",
      body: { postIds: ["<id returned by this call, or found via GET /posts>"] },
      note: "Cancel only works while the post is still SCHEDULED. Once published it is public and cannot be recalled through the API.",
    },
    preflight,
    // A copy, not the same array reference: sharing it would serialize as "[circular]".
    blocked_by: [...(preflight.problems || [])],
    would_this_call_succeed_if_enabled: preflight.checked
      ? preflight.problems.length === 0
        ? "the preflight found no blocker; the POST would be attempted"
        : "NO — the preflight blockers above would make this refuse before any POST"
      : "NO — the read-only preflight itself failed (see preflight.error), and an unverifiable preflight refuses rather than posting blind",
  };
}

// ---------------------------------------------------------------------------
// Tool: marketing__fleet_status  (READ-ONLY)
//
// Answers the question that prevents the next spam_risk rejection: for each connected
// account, how many posts are already sitting UNPUBLISHED in its TikTok inbox?
//
// TikTok counts un-actioned inbox posts as "pending shares". Once an account accumulates
// enough of them it refuses new ones with spam_risk_too_many_pending_share — which is what
// happened to four posts on 2026-08-18. Direct-mode posts never enter that backlog.
// ---------------------------------------------------------------------------

const PENDING_STATUS = "IN_USER_INBOX";

async function fetchAllPosts({ signal } = {}) {
  const out = [];
  let cursor = null;
  let pages = 0;
  do {
    const qs = `?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
    const { json } = await apiRequest("GET", `/posts${qs}`, { signal });
    const batch = Array.isArray(json?.data) ? json.data : [];
    out.push(...batch);
    cursor = json?.pagination?.hasMore ? json.pagination.cursor : null;
    pages += 1;
  } while (cursor && pages < 50);
  return { posts: out, pages, complete: cursor === null };
}

async function fleetStatus(args, { signal } = {}) {
  const sinceHours = Number.isFinite(args?.since_hours) ? Math.max(1, Math.min(720, args.since_hours)) : 24;
  const windowMs = sinceHours * 3600_000;
  const now = Date.now();

  const { json: connJson } = await apiRequest("GET", "/connections", { signal });
  const connections = Array.isArray(connJson?.data) ? connJson.data : [];
  const { posts, pages, complete } = await fetchAllPosts({ signal });

  // The API returns tokenExpiry as epoch milliseconds on /connections, and post timestamps
  // the same way, but ISO-8601 turns up in other shapes. Parse both; anything else is null
  // and is reported as "unknown" — never assumed live.
  const parseInstant = (v) => {
    if (typeof v === "number" && Number.isFinite(v)) return v;
    if (typeof v === "string") { const p = Date.parse(v); return Number.isNaN(p) ? null : p; }
    return null;
  };
  const at = (x) => parseInstant(x?.scheduled_utc_datetime);

  const byAccount = new Map();
  for (const c of connections) {
    if (c.platform !== "tiktok") continue;
    const expiry = parseInstant(c.tokenExpiry);
    byAccount.set(c._id, {
      connection_id: c._id,
      username: c.platformUsername ?? null,
      platform: c.platform,
      // Liveness from expiry ONLY — the API's publishable flag is currently true for
      // credentials whose tokens have already lapsed, so it is never consulted.
      token_expiry: expiry === null ? null : new Date(expiry).toISOString(),
      liveness: expiry === null ? "unknown" : expiry > now ? "live" : "expired",
      pending_in_inbox: 0,
      posted_in_window: 0,
      failed_in_window: 0,
      last_rejection: null,
      recent_modes: {},
    });
  }

  let unmatched = 0;
  for (const x of posts) {
    const row = byAccount.get(x.connectionId);
    if (!row) { unmatched += 1; continue; }
    if (x.status === PENDING_STATUS) row.pending_in_inbox += 1;
    const t = at(x);
    const inWindow = t !== null && now - t <= windowMs;
    if (inWindow) {
      if (x.status === "POSTED") row.posted_in_window += 1;
      if (x.status === "FAILED") {
        row.failed_in_window += 1;
        const prev = row.last_rejection ? Date.parse(row.last_rejection.at) : -1;
        if (t > prev) row.last_rejection = { at: new Date(t).toISOString(), code: x.errorCode ?? null, posting_mode: x.posting_mode ?? null };
      }
      const m = x.posting_mode || "unset";
      row.recent_modes[m] = (row.recent_modes[m] || 0) + 1;
    }
  }

  const items = [...byAccount.values()].sort((a, b) => b.pending_in_inbox - a.pending_in_inbox);
  for (const r of items) {
    r.blocked = r.liveness !== "live" || r.failed_in_window > 0;
    r.blocked_reason = r.liveness !== "live"
      ? `credential ${r.liveness} — scheduling would be accepted and then fail at publish time`
      : r.failed_in_window > 0
        ? `${r.failed_in_window} rejection(s) in the last ${sinceHours}h (${r.last_rejection?.code ?? "unknown"}) — let this account cool off`
        : null;
  }

  const totalPending = items.reduce((n, r) => n + r.pending_in_inbox, 0);
  const totalFailed = items.reduce((n, r) => n + r.failed_in_window, 0);

  return listResult(items, {
    what: "tiktok fleet status",
    source: "GET /connections + full cursor sweep of GET /posts",
    checked_at: new Date(now).toISOString(),
    window_hours: sinceHours,
    posts_swept: posts.length,
    pages_swept: pages,
    sweep_complete: complete,
    posts_with_no_matching_connection: unmatched,
    summary: {
      accounts: items.length,
      live: items.filter((r) => r.liveness === "live").length,
      pending_in_inbox_total: totalPending,
      rejections_in_window: totalFailed,
      cooling_off: items.filter((r) => r.blocked).length,
    },
    reading_it:
      "pending_in_inbox is the number that predicts a spam_risk_too_many_pending_share rejection: those posts were delivered to the TikTok app and never published by a human. " +
      "They do not clear themselves. Direct-mode posts never enter this backlog, which is why posting_mode now defaults to \"direct\".",
    incomplete_note: complete ? undefined : "The post sweep hit its 50-page ceiling; counts are a floor, not a total.",
  });
}

async function schedulePost(args, { signal } = {}) {
  const preflight = await schedulePreflight(args, { signal });
  // FAIL CLOSED. A preflight that could not run has NOT cleared this call: it means the
  // connection's existence, uniqueness and token validity are all unknown. Publishing on an
  // unverifiable preflight is public and irreversible, so an unreadable preflight refuses just
  // like a failing one.
  if (!preflight.checked) {
    throw new ToolError(
      `Refusing to schedule: the read-only preflight could not run (${preflight.error}), so this call's connection and token validity are UNKNOWN. ` +
        `Publishing is public and irreversible, so an unverifiable preflight refuses rather than posting blind. NOTHING WAS SENT.`,
      { code: "PREFLIGHT_UNAVAILABLE", details: { executed: false, preflight, would_have_sent: scheduleRequestShape(args) } }
    );
  }
  if (preflight.problems.length) {
    throw new ToolError(
      `Refusing to schedule: ${preflight.problems.join(" ")} NOTHING WAS SENT — the only call made was the read-only GET /connections preflight.`,
      { code: "PREFLIGHT_FAILED", details: { executed: false, preflight, would_have_sent: scheduleRequestShape(args) } }
    );
  }
  const request = scheduleRequestShape(args);
  const { status, json } = await apiRequest("POST", `/content/${encodeURIComponent(args.content_id)}/schedule`, {
    body: schedulePayload(args),
    signal,
  });
  return okResult(json?.data ?? json, {
    what: "scheduled post",
    executed: true,
    http_status: status,
    sent: { ...request, headers: undefined },
    preflight,
    undo_path: "POST /posts/cancel with { postIds: [<id>] } — only while the post is still SCHEDULED.",
  });
}

// ---------------------------------------------------------------------------
// Tool: marketing__blitz_generate  (GATED — SPENDS A PAID CREDIT per successful call)
// ---------------------------------------------------------------------------

async function blitzGenerate(args, { signal } = {}) {
  if (args?.confirm_paid_credit !== true) {
    throw new ToolError(
      `Refusing to run: this call spends one paid generation credit and confirm_paid_credit was not set to true. Nothing was sent.`,
      { code: "PAID_CREDIT_NOT_CONFIRMED" }
    );
  }
  const meta = credentialsMeta();
  const { status, json } = await apiRequest("POST", "/blitz", { body: null, signal });
  return okResult(json?.data ?? json, {
    what: "blitz generation",
    executed: true,
    http_status: status,
    credit_spent: 1,
    workspace: meta.workspace,
  });
}

function blitzDryRun(args) {
  const meta = credentialsMeta();
  return {
    executed: false,
    network_calls_made: [],
    would_send: {
      method: "POST",
      url: `${meta.base_url.replace(/\/+$/, "")}/blitz`,
      headers: {
        Authorization: `Bearer <api_key read from ${meta.file} at call time — never printed>`,
        Accept: "application/json",
        "User-Agent": USER_AGENT,
      },
      body: null,
      body_note: "This endpoint takes NO body. It pops one suggestion from the queue and starts an async media build.",
    },
    cost: "ONE PAID GENERATION CREDIT per successful call. There is no free/dry mode on the endpoint itself and no refund.",
    second_lock: `Besides the gate, the call also requires confirm_paid_credit: true (received: ${JSON.stringify(args?.confirm_paid_credit ?? null)}).`,
    workspace: meta.workspace,
  };
}

// ---------------------------------------------------------------------------
// Tool: marketing__send_message  (GATED — a text is public, irreversible, and TCPA-regulated)
// ---------------------------------------------------------------------------
//
// TWO LANES, chosen at call time and always REPORTED in the result:
//
//   "app"  (default) — spawn the app binary's own `--send-message` path. The Sendblue credential
//          lives in the app's data-protection Keychain, whose ACL is keyed to the app's code-sign
//          identifier; this Node process is a different identifier and CANNOT read it (the same
//          headless-Keychain blocker documented above for social tokens). Routing through the app
//          binary reads the credential IN-PROCESS, so this server never holds the secret at all.
//
//   "file" — an operator credential file (`~/.utah/secrets/sendblue.json`, or
//          MARKETING_SENDBLUE_CREDENTIALS). Read at call time via the kit's loadSecret, which
//          registers both halves with the redactor so they can never be logged or echoed. Used
//          only when the file exists; the placeholder in the dry-run names the file, never a value.
//
// The gate (MKT_MESSAGE_SEND) is closed by default. Closed → the exact unsent payload, NO network.

const SEND_MESSAGE_FLAG = "--send-message";
const SEND_MESSAGE_MARKER = "send_message|state=";
const SENDBLUE_API_BASE = "https://api.sendblue.com";
const SENDBLUE_SEND_PATH = "/api/send-message";
const SENDBLUE_CONTENT_LIMIT = 18996;
const DEFAULT_SENDBLUE_CREDENTIALS_PATH = path.join(homedir(), ".utah", "secrets", "sendblue.json");

function sendblueCredentialsPath() {
  return process.env.MARKETING_SENDBLUE_CREDENTIALS || DEFAULT_SENDBLUE_CREDENTIALS_PATH;
}

/** Non-secret facts about the operator credential file. Never reads a key value. */
function sendblueCredentialsMeta() {
  const file = sendblueCredentialsPath();
  if (!existsSync(file)) return { file, exists: false, has_key_id: false, has_secret: false, base_url: SENDBLUE_API_BASE };
  let parsed = null;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return { file, exists: true, malformed: true, has_key_id: false, has_secret: false, base_url: SENDBLUE_API_BASE };
  }
  return {
    file,
    exists: true,
    has_key_id: typeof parsed?.api_key_id === "string" && parsed.api_key_id.length > 0,
    has_secret: typeof parsed?.api_secret === "string" && parsed.api_secret.length > 0,
    base_url: (typeof parsed?.base_url === "string" && parsed.base_url.trim()) || SENDBLUE_API_BASE,
  };
}

/** True when the binary carries the headless send path (a marker string, same technique as render). */
function binarySupportsSendMessage(binaryPath) {
  const needle = Buffer.from(SEND_MESSAGE_MARKER, "utf8");
  const chunkSize = 4 * 1024 * 1024;
  const overlap = needle.length - 1;
  let fd;
  try {
    fd = openSync(binaryPath, "r");
  } catch {
    return false;
  }
  try {
    const buf = Buffer.alloc(chunkSize + overlap);
    let carried = 0;
    let position = 0;
    for (;;) {
      const bytes = readSync(fd, buf, carried, chunkSize, position);
      if (bytes <= 0) return false;
      position += bytes;
      const view = buf.subarray(0, carried + bytes);
      if (view.includes(needle)) return true;
      carried = Math.min(overlap, view.length);
      view.subarray(view.length - carried).copy(buf, 0);
    }
  } finally {
    closeSync(fd);
  }
}

/** Resolve an app binary that actually contains the --send-message path. */
function resolveSendMessageApp(binaryPath = null) {
  const considered = [];
  const fromExplicit = binaryPath || process.env.MARKETING_APP_BINARY || null;
  const candidates = [];
  if (fromExplicit) {
    candidates.push({ binary: path.resolve(fromExplicit), origin: binaryPath ? "argument" : "MARKETING_APP_BINARY" });
  } else {
    for (const root of APP_SEARCH_ROOTS) {
      for (const bundle of appBundlesIn(root)) {
        const exe = executableInBundle(bundle);
        if (exe) candidates.push({ binary: exe, bundle, origin: root });
      }
    }
  }
  for (const candidate of candidates) {
    if (!existsSync(candidate.binary)) {
      considered.push({ ...candidate, rejected: "file does not exist" });
      continue;
    }
    if (!binarySupportsSendMessage(candidate.binary)) {
      considered.push({ ...candidate, rejected: `binary does not contain the ${SEND_MESSAGE_FLAG} code path` });
      continue;
    }
    const bundle = candidate.bundle || path.resolve(path.dirname(candidate.binary), "..", "..");
    return { ok: true, binary: candidate.binary, bundle, bundle_id: bundleIdentifier(bundle), origin: candidate.origin, considered };
  }
  return { ok: false, considered, searched: fromExplicit ? [] : APP_SEARCH_ROOTS };
}

/** E.164 normalizer mirroring Sources/Sendblue.swift `PhoneNumber.e164`. */
function toE164(raw) {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return null;
  const hadPlus = trimmed.startsWith("+");
  const digits = trimmed.replace(/\D/g, "");
  if (!digits) return null;
  if (hadPlus) return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : null;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}

/** The exact Sendblue body, byte-for-byte what Sources/Sendblue.swift `SendbluePayload.json` builds. */
function sendMessagePayload(args, number) {
  const body = { number };
  if (args.from_number) {
    const line = toE164(args.from_number);
    if (line) body.from_number = line;
  }
  if (args.content) body.content = args.content;
  if (args.media_url) body.media_url = args.media_url;
  if (args.send_style) body.send_style = args.send_style;
  if (args.status_callback) body.status_callback = args.status_callback;
  return body;
}

function sendMessageValidate(args) {
  const problems = [];
  const number = toE164(args.number);
  if (!number) problems.push(`"${args.number}" is not a dialable E.164 number — nothing was built or sent.`);
  if (!args.content && !args.media_url) problems.push("Neither content nor media_url was supplied; there is nothing to send.");
  if (typeof args.content === "string" && args.content.length > SENDBLUE_CONTENT_LIMIT) {
    problems.push(`content is ${args.content.length} characters, over Sendblue's ${SENDBLUE_CONTENT_LIMIT}-character ceiling.`);
  }
  return { number, problems };
}

/** Which lane this call would use, and why. Reported in BOTH dry-run and live output. */
function sendMessageLane(args) {
  const requested = args.credential_lane || "auto";
  const meta = sendblueCredentialsMeta();
  const fileUsable = meta.exists && meta.has_key_id && meta.has_secret;
  if (requested === "file") {
    return {
      lane: "file",
      usable: fileUsable,
      credential_file: meta.file,
      reason: fileUsable
        ? `credential_lane:"file" was requested and ${meta.file} carries both halves.`
        : `credential_lane:"file" was requested but ${meta.file} ${meta.exists ? "is missing api_key_id/api_secret" : "does not exist"}.`,
      meta,
    };
  }
  if (requested === "app") {
    return { lane: "app", usable: true, credential_file: null, reason: 'credential_lane:"app" was requested — the app binary reads its own Keychain in-process.', meta };
  }
  // auto: the app lane is the default because this Node process CANNOT read the app's Keychain.
  return {
    lane: "app",
    usable: true,
    credential_file: null,
    reason:
      "auto → app. The Sendblue credential lives in the app's data-protection Keychain, whose ACL is keyed to the app's code-sign identifier; this Node process is a different identifier and cannot read it. " +
      (fileUsable
        ? `An operator credential file also exists at ${meta.file}; pass credential_lane:"file" to POST directly from here instead.`
        : `No operator credential file at ${meta.file}, so the file lane is unavailable anyway.`),
    meta,
  };
}

function sendMessageRequestShape(args, number, lane) {
  const base = (lane.lane === "file" ? lane.meta.base_url : SENDBLUE_API_BASE).replace(/\/+$/, "");
  return {
    method: "POST",
    url: `${base}${SENDBLUE_SEND_PATH}`,
    headers: {
      "sb-api-key-id":
        lane.lane === "file"
          ? `<api_key_id read from ${lane.meta.file} at call time — never printed, never stored here>`
          : "<read in-process by the app binary from its own Keychain — this server never sees it>",
      "sb-api-secret-key":
        lane.lane === "file"
          ? `<api_secret read from ${lane.meta.file} at call time — never printed, never stored here>`
          : "<read in-process by the app binary from its own Keychain — this server never sees it>",
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: sendMessagePayload(args, number),
  };
}

/**
 * Ask the APP for the gate verdict without sending. `--send-message` without `--confirm-send`
 * makes NO network call — it reads the local consent/opt-out/ledger state and prints the payload.
 */
async function sendMessageAppPreflight(args, number, { signal } = {}) {
  const app = resolveSendMessageApp(args.binary_path || null);
  if (!app.ok) {
    return {
      checked: false,
      error: `No app binary containing the ${SEND_MESSAGE_FLAG} path was found.`,
      considered: app.considered,
      searched: app.searched,
      note: "Without the app binary the TCPA gate verdict is UNKNOWN. That is reported, not assumed clear.",
    };
  }
  const argv = [SEND_MESSAGE_FLAG, number, String(args.content ?? "")];
  if (args.media_url) argv.push("--media", args.media_url);
  if (args.send_style) argv.push("--style", args.send_style);
  if (args.allow_quiet_hours === true) argv.push("--allow-quiet-hours");
  let run;
  try {
    run = await runBinary(app.binary, argv, { signal, timeoutMs: 60_000 });
  } catch (err) {
    return { checked: false, error: err?.message || String(err), binary: app.binary };
  }
  const fields = parseResultLine(run.stdout || "", "send_message") || {};
  const line = fields._line || "";
  const blocked = fields.blocked && fields.blocked !== "none" ? fields.blocked : null;
  return {
    checked: run.code === 0 && fields.state === "DryRun",
    binary: app.binary,
    bundle_id: app.bundle_id,
    exit_code: run.code,
    raw: line || (run.stdout || run.stderr || "").slice(0, 400),
    app_configured: fields.configured === "true",
    line: fields.line ?? null,
    gate_verdict: blocked ? `BLOCKED: ${blocked}` : "clear",
    blocked_by: blocked ? [`The app's TCPA gate refuses this send: ${blocked}.`] : [],
    network_calls_made: [],
  };
}

async function sendMessageDryRun(args, { signal } = {}) {
  const { number, problems } = sendMessageValidate(args);
  const lane = sendMessageLane(args);
  const preflight = number ? await sendMessageAppPreflight(args, number, { signal }) : { checked: false, error: "no valid number" };
  const blockers = [...problems, ...(preflight.blocked_by || [])];
  if (!lane.usable) blockers.push(lane.reason);
  return {
    executed: false,
    network_calls_made: [],
    network_note:
      "NOTHING left this machine. The app-binary preflight runs the same TCPA gate the UI runs and opens no socket; the file lane was not contacted.",
    credential_lane: lane.lane,
    credential_lane_reason: lane.reason,
    would_send: number ? sendMessageRequestShape(args, number, lane) : null,
    normalized_number: number,
    preflight,
    undo_path: {
      note: "NONE. A delivered text cannot be recalled. Sendblue exposes no unsend, and the recipient's device keeps it.",
    },
    compliance: {
      regime: "TCPA / 10DLC",
      enforced_in_app: [
        "prior express consent must be recorded for the number",
        "a number that replied STOP is blocked outright",
        "the buyer's do-not-contact list is honored",
        "8am–9pm local calling window",
        "the buyer's per-line daily cap",
      ],
      note: "These gates live in the app (Sources/Sendblue.swift MessagingGate) and apply to this tool because it drives the app's own send path — there is no bypass lane.",
    },
    blocked_by: blockers,
    would_this_call_succeed_if_enabled: preflight.checked
      ? blockers.length === 0
        ? "the gate is clear; the send would be attempted"
        : "NO — the blockers above would refuse before anything is sent"
      : "UNKNOWN — the app-binary preflight could not run, so the TCPA gate verdict was not obtained. A live call would refuse rather than send blind.",
  };
}

async function sendMessage(args, { signal } = {}) {
  const { number, problems } = sendMessageValidate(args);
  if (problems.length) {
    throw new ToolError(`Refusing to send: ${problems.join(" ")}`, { code: "INVALID_MESSAGE", details: { problems } });
  }
  const lane = sendMessageLane(args);

  if (lane.lane === "app") {
    const app = resolveSendMessageApp(args.binary_path || null);
    if (!app.ok) {
      throw new ToolError(
        `No app binary containing the ${SEND_MESSAGE_FLAG} path was found, and this Node process cannot read the app's Keychain credential itself. ` +
          `Set MARKETING_APP_BINARY to a binary built from the current sources, or supply an operator credential file at ${sendblueCredentialsPath()} and pass credential_lane:"file". ` +
          `Candidates rejected: ${app.considered.length ? app.considered.map((c) => `${c.binary} (${c.rejected})`).join("; ") : "none found"}`,
        { code: "APP_BINARY_NOT_FOUND", details: { considered: app.considered, searched: app.searched } }
      );
    }
    const argv = [SEND_MESSAGE_FLAG, number, String(args.content ?? "")];
    if (args.media_url) argv.push("--media", args.media_url);
    if (args.send_style) argv.push("--style", args.send_style);
    if (args.allow_quiet_hours === true) argv.push("--allow-quiet-hours");
    argv.push("--confirm-send");
    const run = await runBinary(app.binary, argv, { signal, timeoutMs: 120_000 });
    const fields = parseResultLine(run.stdout || "", "send_message") || {};
    const line = fields._line || "";
    const state = fields.state || "Error";
    if (state !== "Sent") {
      throw new ToolError(
        `The app did not send this message (state=${state}). ${fields.detail || fields.reason || run.stderr || "no detail"}`,
        { code: `SEND_${String(state).toUpperCase()}`, details: { raw: line, exit_code: run.code, binary: app.binary } }
      );
    }
    return okResult({
      executed: true,
      credential_lane: "app",
      via: `${app.binary} ${SEND_MESSAGE_FLAG}`,
      bundle_id: app.bundle_id,
      number,
      status: fields.status ?? null,
      service: fields.service ?? null,
      message_handle: fields.message_handle ?? null,
      detail: fields.detail ?? null,
      proof: line,
      note: "status/service/message_handle come from Sendblue's response body as the app parsed it — not from an exit code.",
    });
  }

  // file lane — POST from here with the operator credential, read at call time.
  const meta = lane.meta;
  if (!lane.usable) throw new ToolError(lane.reason, { code: "CREDENTIALS_UNAVAILABLE" });
  const keyID = loadSecret(meta.file, { field: "api_key_id" });
  const secret = loadSecret(meta.file, { field: "api_secret" });
  const url = `${meta.base_url.replace(/\/+$/, "")}${SENDBLUE_SEND_PATH}`;
  let response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: {
        "sb-api-key-id": keyID,
        "sb-api-secret-key": secret,
        "Content-Type": "application/json",
        Accept: "application/json",
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify(sendMessagePayload(args, number)),
      signal,
    });
  } catch (err) {
    throw new ToolError(`POST ${url} failed at the network layer: ${err?.message || String(err)}`, { code: "API_UNREACHABLE", cause: err });
  }
  const text = await response.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  const data = parsed?.data ?? parsed ?? {};
  const status = typeof data.status === "string" ? data.status.toUpperCase() : null;
  // HTTP 200 alone is NOT a send: Sendblue returns ERROR/DECLINED inside a 200.
  if (!response.ok || !status || status === "ERROR" || status === "DECLINED") {
    throw new ToolError(
      `Sendblue did not accept this message (HTTP ${response.status}, status ${status ?? "absent"}): ${parsed?.message || text.slice(0, 300) || "(empty body)"}`,
      { code: `SEND_HTTP_${response.status}`, details: { http_status: response.status, sendblue_status: status, body: parsed ?? text.slice(0, 400) } }
    );
  }
  return okResult({
    executed: true,
    credential_lane: "file",
    credential_file: meta.file,
    number,
    status,
    service: typeof data.service === "string" ? data.service : null,
    message_handle: data.message_handle ?? data.messageHandle ?? null,
    http_status: response.status,
    note: "status/service/message_handle are read from Sendblue's response body, never inferred from the HTTP code alone.",
    warning:
      "The file lane bypasses the app's local consent/STOP/quiet-hours ledger, because those records live in the app's own store. Use the app lane unless you have separately verified consent.",
  });
}

// ---------------------------------------------------------------------------
// Shared: resolve a binary for one named headless capability
// ---------------------------------------------------------------------------

/**
 * Resolve the app binary for `capability`, or throw the diagnosis. Factored out of generateReel's
 * inline version so every headless tool fails the same way: naming what was searched, what was
 * rejected, and why — never "not found".
 */
function requireApp(capability, { binary_path = null, preferInstalled = false } = {}) {
  const spec = CAPABILITIES[capability];
  const app = resolveApp({ binaryPath: binary_path, requireRenderFlag: false, capability, preferInstalled });
  if (app.ok) return app;

  // An explicitly named binary is the only candidate, and in that case NOTHING was searched —
  // saying otherwise would misdescribe what the server actually did.
  const explicit = app.considered.find((c) => c.origin === "argument" || c.origin === "MARKETING_APP_BINARY");
  const whereClause = explicit
    ? `Only the explicitly supplied binary was considered (via ${explicit.origin}); the default search roots were NOT consulted.`
    : `Searched ${app.searched.join(", ")}.`;
  throw new ToolError(
    `No app binary containing the ${spec.flag} path was found. ${whereClause} ` +
      `Set MARKETING_APP_BINARY (or pass binary_path) to a binary built from sources that include ${spec.source}, or build one first. ` +
      `Candidates rejected: ${app.considered.length ? app.considered.map((c) => `${c.binary} (${c.rejected})`).join("; ") : "none found"}`,
    {
      code: "APP_BINARY_NOT_FOUND",
      details: { capability, required_flag: spec.flag, considered: app.considered, searched: explicit ? [] : app.searched, explicit_binary_only: Boolean(explicit) },
    }
  );
}

// ---------------------------------------------------------------------------
// Tool: marketing__app_capabilities  (read-only, ungated)
// ---------------------------------------------------------------------------

async function appCapabilities(args) {
  const { binary_path = null } = args || {};
  const app = resolveApp({ binaryPath: binary_path, requireRenderFlag: false });
  if (!app.ok) {
    return emptyResult({
      what: "app binaries",
      source: "bundle discovery",
      reason: "no Marketing .app bundle was found to inspect",
      checked: app.searched,
      considered: app.considered,
    });
  }
  const caps = app.capabilities;
  const missing = Object.entries(caps).filter(([, present]) => !present).map(([key]) => key);
  return okResult(
    {
      binary: app.binary,
      bundle: app.bundle,
      bundle_id: app.bundle_id,
      origin: app.origin,
      binary_bytes: app.binary_bytes,
      binary_mtime_epoch: app.binary_mtime_epoch,
      capabilities: Object.fromEntries(
        Object.entries(CAPABILITIES).map(([key, spec]) => [key, { present: caps[key], flag: spec.flag, source: spec.source }])
      ),
      missing_capabilities: missing,
    },
    {
      source: `marker probe of ${app.binary}`,
      note:
        "Presence is proven by finding the literal string that code path prints inside the binary itself — not by the flag name, and never by mtime. " +
        (missing.length
          ? `This build PREDATES: ${missing.join(", ")}. Tools needing those will refuse rather than run and report a no-op as success.`
          : "This build carries every declared headless path."),
    }
  );
}

// ---------------------------------------------------------------------------
// Tool: marketing__export_site  (ungated, disk-only)
// ---------------------------------------------------------------------------

/** Placeholders the Swift path hardcodes today; the caller is told rather than left to find them. */
const SITE_PLACEHOLDERS = ["hello@example.com", "https://example.com"];

async function exportSite(args, { signal } = {}) {
  const {
    output_dir,
    business_name = "Demo Business",
    business_type = "Local Services",
    city = "",
    phone = "",
    photos_dir = null,
    binary_path = null,
  } = args;

  const outDir = absPath(output_dir);
  const app = requireApp("export_multipage", { binary_path });

  // Photos are validated BEFORE the export runs: a gallery directory that cannot be read yields a
  // site with no Projects gallery, and the Swift path swallows that as an empty list rather than an
  // error. Discovering it afterwards means shipping a site missing a section that was asked for.
  let photosResolved = "";
  let photoCandidates = 0;
  if (photos_dir) {
    photosResolved = absPath(photos_dir);
    if (!existsSync(photosResolved)) {
      throw new ToolError(`photos_dir does not exist: ${photosResolved}. Nothing was exported — a site silently missing its gallery is not the site that was asked for.`, {
        code: "PHOTOS_DIR_NOT_FOUND",
      });
    }
    let entries;
    try {
      entries = readdirSync(photosResolved);
    } catch (err) {
      throw new ToolError(`photos_dir cannot be read: ${photosResolved} (${err?.code || err?.message}).`, { code: "PHOTOS_DIR_UNREADABLE" });
    }
    photoCandidates = entries.filter((e) => ["jpg", "jpeg", "png", "heic", "webp"].includes(path.extname(e).slice(1).toLowerCase())).length;
    if (photoCandidates === 0) {
      throw new ToolError(
        `photos_dir contains no images the exporter can use: ${photosResolved}. It accepts jpg, jpeg, png, heic, webp. ` +
          `Exporting anyway would have produced a site with an empty Projects gallery and reported success.`,
        { code: "PHOTOS_DIR_EMPTY" }
      );
    }
  }

  // Positional contract: --export-multipage <dir> <name> <type> <city> <phone> <photosDir>.
  // Every earlier slot must be filled to reach a later one, so they are always all passed.
  const argv = [CAPABILITIES.export_multipage.flag, outDir, String(business_name), String(business_type), String(city), String(phone), photosResolved];
  const run = await runBinary(app.binary, argv, { signal, timeoutMs: 180_000 });
  const stdout = String(run.stdout || "").trim();

  if (run.code !== 0) {
    const failLine = stdout.split("\n").find((l) => l.startsWith("export-multipage: FAILED")) || stdout || String(run.stderr || "").trim();
    throw new ToolError(`The exporter refused: ${failLine || `exit ${run.code}`}. Nothing usable was written.`, {
      code: "EXPORT_FAILED",
      details: { exit_code: run.code, signal: run.signal, stdout, binary: app.binary },
    });
  }

  // The printed count is the renderer's claim. The directory is the fact — read it back, the same
  // way the reel lane reads the finished .mp4's track table instead of trusting the report.
  let written;
  try {
    written = readdirSync(outDir);
  } catch (err) {
    throw new ToolError(`The exporter reported success but ${outDir} cannot be read (${err?.code || err?.message}).`, { code: "OUTPUT_DIR_UNREADABLE" });
  }
  const pages = written.filter((f) => f.toLowerCase().endsWith(".html")).sort();
  if (pages.length === 0) {
    throw new ToolError(
      `The exporter reported success but wrote no .html page into ${outDir} (found: ${written.join(", ") || "nothing"}). ` +
        `An empty site directory is never returned as a successful export.`,
      { code: "NO_PAGES_WRITTEN", details: { stdout, entries: written } }
    );
  }

  const imagesDir = path.join(outDir, "images");
  const galleryFiles = existsSync(imagesDir) ? readdirSync(imagesDir).sort() : [];
  if (photoCandidates > 0 && galleryFiles.length === 0) {
    throw new ToolError(
      `${photoCandidates} image(s) were supplied in ${photosResolved} but the export wrote no images/ directory into ${outDir}. ` +
        `The gallery the caller asked for is absent, so this is not reported as a success.`,
      { code: "GALLERY_NOT_WRITTEN" }
    );
  }

  // The Swift path hardcodes a contact email and site URL. Surfacing which pages carry a
  // placeholder is the difference between a site the caller can ship and one that leaks
  // example.com into a buyer-facing page.
  const placeholderHits = [];
  for (const page of pages) {
    let body;
    try {
      body = readFileSync(path.join(outDir, page), "utf8");
    } catch {
      continue;
    }
    for (const needle of SITE_PLACEHOLDERS) {
      if (body.includes(needle)) placeholderHits.push({ page, placeholder: needle });
    }
  }

  const totalBytes = pages.reduce((sum, p) => {
    try {
      return sum + statSync(path.join(outDir, p)).size;
    } catch {
      return sum;
    }
  }, 0);

  return okResult(
    {
      output_dir: outDir,
      pages,
      page_count: pages.length,
      total_html_bytes: totalBytes,
      gallery_images: galleryFiles,
      gallery_image_count: galleryFiles.length,
      photos_supplied: photoCandidates,
      inputs: { business_name, business_type, city: city || null, phone: phone || null, photos_dir: photosResolved || null },
      placeholder_hits: placeholderHits,
      binary: app.binary,
      renderer_stdout: stdout,
    },
    {
      source: `${app.binary} ${CAPABILITIES.export_multipage.flag}`,
      note: "Pages, byte counts, and gallery images are read back off disk after the run — the exporter's own printed count is reported separately as renderer_stdout and is never the evidence.",
      warning: placeholderHits.length
        ? `This build's exporter HARDCODES ${SITE_PLACEHOLDERS.join(" and ")} (they are not parameters of --export-multipage). ${placeholderHits.length} occurrence(s) are present and MUST be replaced before this site faces a buyer.`
        : undefined,
    }
  );
}

// ---------------------------------------------------------------------------
// Tool: marketing__render_camera_take  (ungated, disk-only)
// ---------------------------------------------------------------------------

async function renderCameraTake(args, { signal } = {}) {
  const { take_path, output_path, format = "vertical", page_framing = "fillcrop", camera_framing = "readable", site = null, binary_path = null } = args;

  const takeResolved = absPath(take_path);
  if (!existsSync(takeResolved)) {
    throw new ToolError(`take_path does not exist: ${takeResolved}`, { code: "TAKE_NOT_FOUND" });
  }
  const outPath = absPath(output_path);
  const app = requireApp("render_camera_take", { binary_path });

  const argv = [CAPABILITIES.render_camera_take.flag, takeResolved, outPath, "--format", String(format), "--page-framing", String(page_framing), "--camera-framing", String(camera_framing)];
  if (site) argv.push("--site", String(site));

  const run = await runBinary(app.binary, argv, { signal, timeoutMs: 600_000 });
  const stdout = String(run.stdout || "").trim();
  const marker = stdout.split("\n").reverse().find((l) => l.startsWith("render_camera_take|")) || null;

  if (run.code !== 0) {
    // The binary's own reason is always better than a generic exit code — surface it verbatim.
    throw new ToolError(`The take renderer refused: ${marker || stdout || `exit ${run.code}`}`, {
      code: "CAMERA_TAKE_FAILED",
      details: { exit_code: run.code, signal: run.signal, marker, stdout, binary: app.binary },
    });
  }

  if (!existsSync(outPath)) {
    throw new ToolError(`The renderer exited 0 but no file exists at ${outPath}. A missing output is never returned as a success.`, {
      code: "OUTPUT_MISSING",
      details: { marker, stdout },
    });
  }
  const st = statSync(outPath);
  if (st.size <= 0) {
    throw new ToolError(`The renderer exited 0 but ${outPath} is zero bytes. An empty file is never returned as a success.`, {
      code: "OUTPUT_EMPTY",
      details: { marker, stdout },
    });
  }

  return okResult(
    {
      output_path: outPath,
      output_bytes: st.size,
      take_path: takeResolved,
      format,
      page_framing,
      camera_framing,
      site: site || null,
      renderer_marker: marker,
      binary: app.binary,
    },
    {
      source: `${app.binary} ${CAPABILITIES.render_camera_take.flag}`,
      note: "Existence and byte count are stat'd off disk after the run; the renderer's marker line is reported alongside but is not the evidence.",
      warning: site ? "A --site capture loads that URL in a real web view on this machine. Only pass a site you control or trust." : undefined,
    }
  );
}

// ---------------------------------------------------------------------------
// Tool: marketing__publish_due  (GATED — public and irreversible)
// ---------------------------------------------------------------------------

function parsePublishDue(stdout) {
  const line = String(stdout || "").split("\n").reverse().find((l) => l.startsWith("publish_due|")) || null;
  if (!line) return { line: null, state: null, due: null, published: null, failed: null, reason: null, detail: null };
  const fields = Object.fromEntries(
    line
      .split("|")
      .slice(1)
      .map((part) => {
        const i = part.indexOf("=");
        return i === -1 ? [part, true] : [part.slice(0, i), part.slice(i + 1)];
      })
  );
  const num = (v) => (v === undefined ? null : Number.isFinite(Number(v)) ? Number(v) : null);
  return {
    line,
    state: fields.state ?? null,
    due: num(fields.due),
    published: num(fields.published),
    failed: num(fields.failed),
    reason: fields.reason ?? null,
    detail: fields.detail ?? null,
  };
}

async function publishDueDryRun(args) {
  const { binary_path = null } = args || {};
  let app = null;
  let resolveError = null;
  try {
    app = requireApp("publish_due", { binary_path, preferInstalled: true });
  } catch (err) {
    resolveError = err?.message || String(err);
  }
  return okResult(
    {
      would_run: app ? `${app.binary} ${CAPABILITIES.publish_due.flag}` : null,
      binary: app?.binary || null,
      binary_resolution_error: resolveError,
      published: 0,
      network_calls_made: 0,
    },
    {
      source: "dry run — the gate MKT_PUBLISH_DUE is closed",
      note:
        "Nothing was published and no network call was made. This path drains the app's OWN publish queue: every item already due goes out to a real audience the moment it runs. " +
        "It reads the queue from the installed app's store, so the installed bundle is preferred over a build copy.",
    }
  );
}

async function publishDue(args, { signal } = {}) {
  const { confirm_publishes_queue, binary_path = null } = args || {};
  if (confirm_publishes_queue !== true) {
    throw new ToolError(
      `publish_due requires confirm_publishes_queue: true. This drains the app's publish queue — every item already due is posted to a real audience and cannot be recalled.`,
      { code: "CONFIRMATION_REQUIRED" }
    );
  }
  // The queue lives in the installed app's store, so drive the bundle the user actually runs.
  const app = requireApp("publish_due", { binary_path, preferInstalled: true });
  const run = await runBinary(app.binary, [CAPABILITIES.publish_due.flag], { signal, timeoutMs: 300_000 });
  const stdout = String(run.stdout || "").trim();
  const parsed = parsePublishDue(stdout);

  if (parsed.state === "Error") {
    throw new ToolError(`The publisher errored: ${parsed.reason || parsed.line || `exit ${run.code}`}. Queue state is unchanged only if the reason says so — check the app.`, {
      code: "PUBLISH_DUE_ERROR",
      details: { exit_code: run.code, marker: parsed.line, stdout },
    });
  }
  if (!parsed.line) {
    throw new ToolError(
      `The publisher printed no publish_due marker (exit ${run.code}). Without its own report there is no evidence of what was or was not posted, so this is not returned as a success.`,
      { code: "NO_PUBLISH_MARKER", details: { exit_code: run.code, stdout, stderr: String(run.stderr || "").trim() } }
    );
  }
  if (parsed.state === "Skipped") {
    return emptyResult({
      what: "published posts",
      source: `${app.binary} ${CAPABILITIES.publish_due.flag}`,
      reason: `the publisher skipped the run: ${parsed.reason || "no reason given"}`,
      checked: [app.binary],
      marker: parsed.line,
    });
  }
  if (parsed.due === 0) {
    return emptyResult({
      what: "due posts",
      source: `${app.binary} ${CAPABILITIES.publish_due.flag}`,
      reason: "the queue held nothing due at this moment",
      checked: [app.binary],
      marker: parsed.line,
    });
  }

  return okResult(
    { due: parsed.due, published: parsed.published, failed: parsed.failed, detail: parsed.detail, marker: parsed.line, binary: app.binary },
    {
      source: `${app.binary} ${CAPABILITIES.publish_due.flag}`,
      note: "Counts are the publisher's own tallies from its marker line. Anything counted in `published` is public and cannot be recalled.",
      warning: parsed.failed > 0 ? `${parsed.failed} item(s) FAILED to publish and remain in the queue. Their next run will retry them.` : undefined,
    }
  );
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

createServer({
  name: SERVER_NAME,
  version: SERVER_VERSION,
  instructions:
    "Marketing app tools. Connection liveness is derived from token expiry only — an expired credential is reported as dead even when the upstream API claims it is publishable. " +
    "Reel rendering, site export, and take rendering run locally through the app binary's own headless paths and touch no network (except an explicitly requested site capture). " +
    "Every one of those reads its result back off disk afterwards, so a renderer that exits 0 having written nothing fails instead of reporting success. " +
    "Anything public, irreversible, or paid — scheduling, draining the publish queue, blitz generation, texting — is gated off by default and returns the exact action it would have taken. " +
    "Call marketing__app_capabilities first if a headless tool reports APP_BINARY_NOT_FOUND: it separates 'no bundle' from 'a bundle that predates this path'.",
  tools: [
    {
      name: "marketing__list_connections",
      description:
        "List every social connection this workspace can post from, plus the credential records stored on this device. " +
        "READ-ONLY: performs one GET against the scheduling API and reads non-secret local preference records. Nothing is published, changed, or spent. " +
        "Liveness is computed ONLY from each connection's token expiry against now: future expiry = live, past expiry = expired, no expiry on record = unknown (never assumed live). " +
        "The upstream 'publishable' boolean is reported for comparison but is never used, because it currently reads true for credentials whose tokens have already lapsed; " +
        "such a connection is flagged with flag_contradicts_expiry and a warning. " +
        "Instagram is excluded as a publish target in this build (Meta app review pending) and is never reported as schedulable.",
      inputSchema: { type: "object", properties: {}, required: [] },
      timeoutMs: 45_000,
      handler: listConnections,
    },
    {
      name: "marketing__generate_reel",
      description:
        "Render a reel to an .mp4 on local disk by driving the app binary's own headless --render-reel path (the exact renderer the in-app Reel Studio button uses). " +
        "Disk only: no network call, no credential is read, nothing is queued, scheduled, or published. " +
        "Supply either 'project' (an inline reel project object with at least one scene) or 'project_path' (a .json file the app wrote). " +
        "Optional assets_dir resolves each scene's imageName; any name that cannot be loaded is NAMED in missing_backgrounds and that scene renders on the style gradient instead of silently substituting. " +
        "MUSIC: supplying music_path turns the project's own music switch on (music.enabled=true, music.source='My track') — the renderer treats --music as the source only, so without that switch it renders SILENT while still reporting music=loaded. " +
        "The switches this server had to flip are listed in music_switch_changes; a project_path file is never modified, a patched copy is rendered instead. " +
        "After rendering, the finished .mp4's own track table is read: audio_tracks and music_in_output come from the container, not from the renderer's report. " +
        "If music was requested and no audio track is present, the call FAILS with MUSIC_NOT_RENDERED and names the silent file — it is never returned as a success. " +
        "Fails loudly with the renderer's own reason (input_not_found, unreadable_project, no_scenes, unreadable_logo, music_not_found, render_failed, empty_output) rather than returning a placeholder. " +
        "The binary is resolved from binary_path, then MARKETING_APP_BINARY, then built/installed bundles; a binary that predates the --render-reel path is rejected with a diagnosis instead of being run.",
      inputSchema: {
        type: "object",
        properties: {
          project: {
            type: "object",
            description:
              "Inline reel project. Shape: { name, format: 'Vertical 9:16'|'Square 1:1'|'Wide 16:9', fps, styleID: 'Spotlight'|'Editorial'|'Luxe'|'Minimal'|'Bold', scenes: [{ eyebrow, headline, subtitle, seconds, imageName }] }. " +
              "Optional music: { enabled, source: 'My track'|'Built-in bed', mood: 'Ambient'|'Uplift'|'Cinematic'|'Calm', gain, fadeIn, fadeOut } — you do NOT need to set it to use music_path, which turns it on for you; set it yourself only to use the on-device bed ('Built-in bed') or to choose gain/fades.",
          },
          project_path: { type: "string", description: "Path to a reel project .json file. Mutually exclusive with 'project'." },
          output_path: { type: "string", description: "Absolute path for the .mp4 to write. Parent directories are created." },
          assets_dir: { type: "string", description: "Directory holding the scene background images referenced by each scene's imageName." },
          logo_path: { type: "string", description: "Optional logo image. A supplied-but-unreadable file is an error, not a silent skip." },
          music_path: {
            type: "string",
            description:
              "Optional audio track to mix under the reel. Supplying it also switches the project's music on (music.enabled=true, music.source='My track'), because the renderer treats this flag as the source and NOT as the switch. " +
              "A missing, unreadable, or zero-byte path is rejected before anything renders (MUSIC_FILE_NOT_FOUND / MUSIC_FILE_UNREADABLE / MUSIC_FILE_EMPTY). " +
              "A file that exists but the audio stack cannot decode makes the renderer ship the silent video while still reporting Rendered; that case is caught afterwards by reading the finished file's track table and fails as MUSIC_NOT_RENDERED. Either way you never get a silent reel reported as success.",
          },
          binary_path: { type: "string", description: "Override the app binary to drive." },
        },
        required: ["output_path"],
      },
      timeoutMs: 600_000,
      handler: generateReel,
    },
    {
      name: "marketing__app_capabilities",
      description:
        "Report which headless code paths the resolved app binary was actually built with. " +
        "READ-ONLY: reads bytes off the binary on disk. Nothing is run, spawned, published, or spent. " +
        "Presence is proven by finding the literal string each code path prints INSIDE the binary — never by the flag name (which can appear in an unrelated string table) and never by file mtime (which proves nothing about contents). " +
        "Use this first when another tool reports APP_BINARY_NOT_FOUND: it distinguishes 'no bundle at all' from 'a bundle that predates this path'.",
      inputSchema: {
        type: "object",
        properties: { binary_path: { type: "string", description: "Override the app binary to inspect." } },
        required: [],
      },
      timeoutMs: 30_000,
      handler: appCapabilities,
    },
    {
      name: "marketing__export_site",
      description:
        "Generate a multi-page website pack onto local disk by driving the app binary's own headless --export-multipage path (the SAME SiteDeploy.multiPack the in-app Site Studio button uses). " +
        "Disk only: no network call, no credential is read, nothing is deployed or published. No app data is read or written — the content comes only from the arguments. " +
        "Supplying photos_dir builds a real Projects gallery from the images inside it (jpg, jpeg, png, heic, webp); a directory that is missing, unreadable, or holds no usable image is REFUSED before the export runs, because the Swift path treats it as an empty gallery and would report success on a site missing the section that was asked for. " +
        "After the run the output directory is read back off disk: the pages, their byte counts, and the copied gallery images are facts from the filesystem, while the exporter's own printed count is returned separately as renderer_stdout and is never the evidence. " +
        "An export that writes no .html, or that drops a supplied gallery, FAILS rather than returning success. " +
        "KNOWN LIMITATION of this build: the exporter hardcodes the contact email hello@example.com and the site URL https://example.com — they are NOT parameters. Every page carrying one is named in placeholder_hits and must be corrected before the site faces a buyer.",
      inputSchema: {
        type: "object",
        properties: {
          output_dir: { type: "string", description: "Directory to write the site pack into. Created if absent." },
          business_name: { type: "string", description: 'Business name. Defaults to "Demo Business".' },
          business_type: { type: "string", description: 'Business category. Defaults to "Local Services".' },
          city: { type: "string", description: "City used in the site copy." },
          phone: { type: "string", description: "Contact phone used in the site copy." },
          photos_dir: { type: "string", description: "Directory of images to copy in as the Projects gallery. Refused if it holds no usable image." },
          binary_path: { type: "string", description: "Override the app binary to drive." },
        },
        required: ["output_dir"],
      },
      timeoutMs: 180_000,
      handler: exportSite,
    },
    {
      name: "marketing__render_camera_take",
      description:
        "Render a recorded camera take to video through the app binary's own headless --render-camera-take path. " +
        "Disk only: no network call unless you pass 'site', no credential is read, nothing is published. " +
        "The page is captured at the REEL's aspect rather than a fixed desktop shape — the same derivation the Studio uses, so a crop here is a crop there. " +
        "Passing 'site' loads that URL in a real web view on this machine to composite the page behind the take; only pass a site you control or trust. " +
        "After the run the output file is stat'd off disk: a renderer that exits 0 while writing nothing, or writing a zero-byte file, FAILS rather than returning success. " +
        "The binary's own marker line (render_camera_take|state=…) is surfaced verbatim on failure — take_not_found, bad_format, and bad_site are its reasons, not this server's guesses.",
      inputSchema: {
        type: "object",
        properties: {
          take_path: { type: "string", description: "Path to the recorded take the app wrote." },
          output_path: { type: "string", description: "Absolute path for the rendered video." },
          format: { type: "string", enum: ["vertical", "square", "wide"], description: 'Reel aspect. Defaults to "vertical".' },
          page_framing: { type: "string", enum: ["fillcrop", "fullpage"], description: 'How the captured page is fitted. Defaults to "fillcrop".' },
          camera_framing: { type: "string", enum: ["readable", "entire"], description: 'How the camera feed is fitted. "entire" preserves the whole frame. Defaults to "readable".' },
          site: { type: "string", description: "Optional URL to capture as the virtual background." },
          binary_path: { type: "string", description: "Override the app binary to drive." },
        },
        required: ["take_path", "output_path"],
      },
      timeoutMs: 600_000,
      handler: renderCameraTake,
    },
    {
      name: "marketing__publish_due",
      description:
        "Drain the app's OWN publish queue by driving the headless --publish-due path: every queued item whose scheduled time has already passed is posted. " +
        "PUBLIC AND IRREVERSIBLE — a published post goes to a real audience and cannot be recalled. There is no per-item selection: this runs the whole due set. " +
        "Two locks guard it: the gate env MKT_PUBLISH_DUE, and an explicit confirm_publishes_queue: true on every call. With the gate closed it reports the exact command it would run, publishes nothing, and makes no network call. " +
        "It drives the INSTALLED bundle by preference, because the queue lives in the installed app's store — a build copy has a different store and would drain the wrong queue (or none). " +
        "A run that prints no publish_due marker FAILS: without the publisher's own report there is no evidence of what was or was not posted. A run with nothing due returns an honest empty result rather than a success with zeroes.",
      inputSchema: {
        type: "object",
        properties: {
          confirm_publishes_queue: {
            type: "boolean",
            description: "Must be exactly true. Acknowledges that every due item in the queue is published to a real audience and cannot be recalled.",
          },
          binary_path: { type: "string", description: "Override the app binary to drive." },
        },
        required: ["confirm_publishes_queue"],
      },
      gated: true,
      gateEnv: "MKT_PUBLISH_DUE",
      timeoutMs: 300_000,
      dryRun: publishDueDryRun,
      handler: publishDue,
    },
    {
      name: "marketing__fleet_status",
      description:
        "Per-account posting health for the TikTok fleet. READ-ONLY: one GET /connections plus a full cursor sweep of GET /posts. Nothing is scheduled, published, or spent. " +
        "The number to read first is pending_in_inbox — posts that were delivered to the TikTok app in \"inbox\" mode and never published by a human. They do not clear themselves, " +
        "and once enough accumulate TikTok refuses new posts for that account with spam_risk_too_many_pending_share (which is what rejected four posts on 2026-08-18). " +
        "Liveness is computed from token expiry ONLY, never from the API's publishable flag, which currently reads true for lapsed credentials. " +
        "An account is reported blocked if its credential is not live or it was rejected inside the window.",
      inputSchema: {
        type: "object",
        properties: {
          since_hours: { type: "number", description: "Window for posted/failed counts, in hours. Defaults to 24, clamped to 1..720. pending_in_inbox is always all-time, because the backlog is all-time." },
        },
      },
      timeoutMs: 60_000,
      handler: fleetStatus,
    },
    {
      name: "marketing__schedule_post",
      description:
        "Schedule an existing content item to a social account (POST /content/{content_id}/schedule). " +
        "PUBLIC AND IRREVERSIBLE once the scheduled time passes — the post goes out to a real audience. " +
        "connectionId is MANDATORY for TikTok: 6 TikTok connections exist on this workspace, and the API only omits it when exactly one connection exists for the platform. " +
        "Undo path: POST /posts/cancel with { postIds: [<id>] }, and only while the post is still SCHEDULED; after publication nothing can recall it. " +
        "Instagram is NOT an available target in this build (Meta app review pending) — the platform enum deliberately excludes it. " +
        "Before sending, this runs a read-only preflight and REFUSES if the platform has no connection, if connectionId is missing when several accounts exist, or if the chosen credential's token has already expired (regardless of what the upstream publishable flag claims). " +
        "It also refuses when the preflight itself could not run, because an unverifiable preflight has cleared nothing.",
      inputSchema: {
        type: "object",
        properties: {
          content_id: { type: "string", description: "Id of the content item to schedule (from GET /content)." },
          platform: { type: "string", enum: SCHEDULABLE_PLATFORMS, description: "Target platform. Instagram is excluded in this build." },
          utc_datetime: { type: "string", description: "ISO-8601 UTC instant, e.g. 2026-08-01T18:00:00Z." },
          caption: { type: "string", description: "Post caption." },
          description: { type: "string", description: "Optional longer description (YouTube)." },
          connection_id: { type: "string", description: "Which account to post from. MANDATORY for TikTok (6 connections exist)." },
          posting_mode: {
            type: "string",
            enum: POSTING_MODES,
            description:
              'How the post is delivered. "direct" (the default) publishes straight to the account. "inbox" drops it into the TikTok app for a human to tap publish, ' +
              "and un-actioned inbox posts pile up as pending shares until TikTok refuses new ones for that account with spam_risk_too_many_pending_share. " +
              "Measured over this workspace's full 127-post history: direct = 23 sent, 0 failed, 0 stranded; inbox = 74 sent, 29 still unpublished, 4 rejected. " +
              'Only pass "inbox" when a human is deliberately reviewing each post in the app.',
          },
          privacy_level: {
            type: "string",
            enum: PRIVACY_LEVELS,
            description:
              'Required by TikTok for direct posts; sent only when posting_mode is "direct". Defaults to PUBLIC_TO_EVERYONE, which is what every successful direct post in this workspace used.',
          },
        },
        required: ["content_id", "platform", "utc_datetime", "caption"],
      },
      gated: true,
      gateEnv: "MKT_PUBLISH",
      timeoutMs: 60_000,
      dryRun: scheduleDryRun,
      handler: schedulePost,
    },
    {
      name: "marketing__blitz_generate",
      description:
        "Pop one suggestion off the generation queue and start an async media build (POST /blitz). " +
        "COSTS MONEY: every successful call SPENDS ONE PAID GENERATION CREDIT. There is no dry mode on the endpoint and no refund. " +
        "The endpoint accepts no body. Two locks guard it: its own gate env MKT_BLITZ_SPEND, and an explicit confirm_paid_credit: true argument on every call. " +
        "With the gate closed it returns the exact request it would send and spends nothing.",
      inputSchema: {
        type: "object",
        properties: {
          confirm_paid_credit: {
            type: "boolean",
            description: "Must be exactly true. Acknowledges that this call spends one paid generation credit.",
          },
        },
        required: ["confirm_paid_credit"],
      },
      gated: true,
      gateEnv: "MKT_BLITZ_SPEND",
      timeoutMs: 60_000,
      dryRun: blitzDryRun,
      handler: blitzGenerate,
    },
    {
      name: "marketing__send_message",
      description:
        "Send one iMessage/RCS/SMS to a phone number through the buyer's OWN Sendblue line (POST /api/send-message). " +
        "PUBLIC AND IRREVERSIBLE: a delivered text cannot be recalled — Sendblue exposes no unsend and the handset keeps it. " +
        "TCPA/10DLC-REGULATED: by default this drives the app binary's own headless send path, so the app's gate runs unchanged — prior express consent must be recorded for the number, a number that replied STOP is refused, the do-not-contact list is honored, the 8am–9pm local window applies, and the per-line daily cap applies. There is no bypass lane. " +
        'credential_lane defaults to "app" because this Node process CANNOT read the app\'s data-protection Keychain (the same headless-Keychain blocker documented in mcp/README.md); the app binary reads its own credential in-process, so this server never holds the secret. ' +
        'credential_lane:"file" POSTs from here using an operator credential file instead — that lane does NOT consult the app\'s consent ledger and says so in its result. ' +
        "With the gate closed it returns the exact unsent payload plus the app's real gate verdict, and makes NO network call.",
      inputSchema: {
        type: "object",
        properties: {
          number: { type: "string", description: "Recipient phone number. Normalized to E.164; a number that cannot be normalized is refused rather than guessed." },
          content: { type: "string", description: `Message text. Sendblue's ceiling is ${SENDBLUE_CONTENT_LIMIT} characters.` },
          media_url: { type: "string", description: "Optional https media URL (100 MB iMessage / 5 MB SMS). Either content or media_url is required." },
          from_number: { type: "string", description: "Which of the buyer's Sendblue lines to send from. Omit to let the account's default line answer." },
          send_style: {
            type: "string",
            enum: ["celebration", "shooting_star", "fireworks", "lasers", "love", "confetti", "balloons", "spotlight", "echo", "invisible", "gentle", "loud", "slam"],
            description: "One of the 13 iMessage bubble effects. Dropped silently by an SMS/RCS fallback — Sendblue picks the transport, so this is never a guarantee.",
          },
          status_callback: { type: "string", description: "Optional https callback the buyer owns for delivery status." },
          allow_quiet_hours: { type: "boolean", description: "Send outside the 8am–9pm local TCPA window. Off by default; turning it on is a compliance decision." },
          credential_lane: { type: "string", enum: ["auto", "app", "file"], description: 'Where the Sendblue credential is read. "auto" (default) resolves to "app".' },
          binary_path: { type: "string", description: "Override the app binary to drive (app lane)." },
        },
        required: ["number"],
      },
      gated: true,
      gateEnv: "MKT_MESSAGE_SEND",
      timeoutMs: 150_000,
      dryRun: sendMessageDryRun,
      handler: sendMessage,
    },
  ],
});
