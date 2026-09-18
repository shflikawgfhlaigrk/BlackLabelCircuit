#!/usr/bin/env node
// Sunset MCP server — exposes the Sunset mastering engine over MCP stdio.
//
// This is a thin, honest wrapper around the headless Sunset CLI (`sunset-cli`).
// It runs no DSP of its own: every number a tool returns comes straight out of a
// real render performed by the engine binary. Nothing here is a fixture.
//
// Tools
//   sunset__master_track      GATED. Masters an audio file and writes a new master into the
//                             server's own output directory. Additive only: it never
//                             overwrites, and it can only ever write inside SUNSET_OUT_DIR.
//                             Disabled by default because it is the one tool here that puts
//                             a file on disk; set SUNSET_ALLOW_GATED=1 to enable it.
//   sunset__analyze_reference Reports a reference track's Reference DNA (and, optionally,
//                             the moves needed to match a track to it). Leaves no file
//                             behind: the scratch render lives in a private temp
//                             directory that is removed before the tool returns.
//
// Environment
//   SUNSET_ALLOW_GATED Set to 1 to let sunset__master_track actually run. Unset = refusal
//                      plus a dry-run preview; nothing is written.
//   SUNSET_OUT_DIR     Directory every master is written to.  Default: ~/.sunset/mcp-masters
//                      This default is deliberately a directory this server owns. It is NOT a
//                      personal music library: an agent-driven tool must not deposit files into
//                      one by default. Point SUNSET_OUT_DIR wherever you like to override it.
//   SUNSET_CLI_PATH    Path to the sunset-cli binary.         Default: <repo>/.build-stage/bin/sunset-cli
//   SUNSET_TIMEOUT_MS  Per-tool deadline in ms.               Default: 900000 (15 min)
//   MCP_LOG_LEVEL      silent | error | warn | info | debug.  Default: info
//
// stdout is the JSON-RPC channel and carries nothing else; all logging goes to stderr.

import { spawn, execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  statSync,
  accessSync,
  realpathSync,
  openSync,
  writeFileSync,
  closeSync,
  unlinkSync,
  constants as FS,
} from "node:fs";
import { homedir, tmpdir, hostname } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createServer, ToolError, createLogger } from "./mcp-kit.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.dirname(HERE);

const SERVER_NAME = "sunset";
const SERVER_VERSION = "1.0.0";

const log = createLogger(SERVER_NAME);

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const DEFAULT_CLI = path.join(REPO_ROOT, ".build-stage", "bin", "sunset-cli");
const CLI_PATH = path.resolve(process.env.SUNSET_CLI_PATH?.trim() || DEFAULT_CLI);

// A directory this server owns, created on demand. Deliberately NOT ~/Music/Sunset Masters:
// that is the founder's personal music library, and a tool an agent can call must not write
// into a personal library by default. Overridable with SUNSET_OUT_DIR.
const DEFAULT_OUT_DIR = path.join(homedir(), ".sunset", "mcp-masters");
const OUT_DIR_IS_DEFAULT = !process.env.SUNSET_OUT_DIR?.trim();
const OUT_DIR_RAW = path.resolve(expandHome(process.env.SUNSET_OUT_DIR?.trim() || DEFAULT_OUT_DIR));

const TIMEOUT_MS = (() => {
  const raw = Number(process.env.SUNSET_TIMEOUT_MS);
  return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : 900_000; // 15 minutes
})();

// Extensions the engine's writer can produce (it picks its container from the path).
const ALLOWED_EXTENSIONS = new Set([".wav", ".aif", ".aiff", ".flac", ".m4a"]);

function expandHome(p) {
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return path.join(homedir(), p.slice(2));
  return p;
}

// ---------------------------------------------------------------------------
// Binary + path checks — every failure names the real reason
// ---------------------------------------------------------------------------

const BUILD_HINT = `Build it with:  cd ${REPO_ROOT} && BUILD_CLI=only ./build.sh`;

function requireCLI() {
  let st;
  try {
    st = statSync(CLI_PATH);
  } catch (err) {
    throw new ToolError(
      `The mastering engine binary is not at ${CLI_PATH} (${err?.code || err?.message}). ` +
        `It is a build artifact and does not exist until the build lane runs. ${BUILD_HINT}`,
      { code: "ENGINE_MISSING", details: { expected_path: CLI_PATH, build_hint: BUILD_HINT } }
    );
  }
  if (!st.isFile()) {
    throw new ToolError(`${CLI_PATH} exists but is not a file.`, { code: "ENGINE_NOT_A_FILE" });
  }
  try {
    accessSync(CLI_PATH, FS.X_OK);
  } catch {
    throw new ToolError(`${CLI_PATH} is not executable.`, { code: "ENGINE_NOT_EXECUTABLE" });
  }
  return { path: CLI_PATH, bytes: st.size, mtime: st.mtime.toISOString() };
}

function requireReadableAudioFile(p, label) {
  if (typeof p !== "string" || !p.trim()) {
    throw new ToolError(`${label} must be a non-empty file path.`, { code: "BAD_PATH" });
  }
  const resolved = path.resolve(expandHome(p.trim()));
  let st;
  try {
    st = statSync(resolved);
  } catch (err) {
    throw new ToolError(`${label} does not exist or is unreadable: ${resolved} (${err?.code || err?.message})`, {
      code: "INPUT_MISSING",
      details: { path: resolved },
    });
  }
  if (!st.isFile()) {
    throw new ToolError(`${label} is not a regular file: ${resolved}`, { code: "INPUT_NOT_A_FILE" });
  }
  if (st.size === 0) {
    throw new ToolError(`${label} is a zero-byte file: ${resolved}`, { code: "INPUT_EMPTY" });
  }
  try {
    accessSync(resolved, FS.R_OK);
  } catch {
    throw new ToolError(`${label} is not readable: ${resolved}`, { code: "INPUT_UNREADABLE" });
  }
  return { path: resolved, bytes: st.size };
}

// ---------------------------------------------------------------------------
// Output directory confinement
// ---------------------------------------------------------------------------

/** Create (if needed) and resolve the single directory this server may write into. */
function ensureOutDir() {
  try {
    mkdirSync(OUT_DIR_RAW, { recursive: true });
  } catch (err) {
    throw new ToolError(`Cannot create the output directory ${OUT_DIR_RAW}: ${err?.code || err?.message}`, {
      code: "OUT_DIR_UNUSABLE",
      details: { out_dir: OUT_DIR_RAW, env_var: "SUNSET_OUT_DIR" },
    });
  }
  let real;
  try {
    real = realpathSync(OUT_DIR_RAW);
  } catch (err) {
    throw new ToolError(`Cannot resolve the output directory ${OUT_DIR_RAW}: ${err?.code || err?.message}`, {
      code: "OUT_DIR_UNRESOLVABLE",
    });
  }
  try {
    accessSync(real, FS.W_OK);
  } catch {
    throw new ToolError(`The output directory ${real} is not writable.`, { code: "OUT_DIR_NOT_WRITABLE" });
  }
  return real;
}

/** Read-only view of the output directory. Creates nothing — safe inside a dry run. */
function describeOutDir() {
  let resolved = null;
  let exists = false;
  let writable = false;
  let error = null;
  try {
    resolved = realpathSync(OUT_DIR_RAW);
    exists = true;
  } catch (err) {
    error = err?.code || err?.message || String(err);
  }
  if (exists) {
    try {
      accessSync(resolved, FS.W_OK);
      writable = true;
    } catch (err) {
      error = err?.code || err?.message || String(err);
    }
  }
  return {
    configured: OUT_DIR_RAW,
    resolved,
    exists,
    writable,
    created_on_demand_by_first_master: !exists,
    is_server_default: OUT_DIR_IS_DEFAULT,
    env_var: "SUNSET_OUT_DIR",
    stat_error: error,
  };
}

function fileExists(p) {
  try {
    statSync(p);
    return true;
  } catch {
    return false;
  }
}

function sanitizeStem(stem) {
  const cleaned = String(stem)
    .normalize("NFKD")
    .replace(/[^A-Za-z0-9._ -]+/g, "_")
    .replace(/\s+/g, " ")
    .replace(/^[._ -]+/, "")
    .replace(/[._ -]+$/, "")
    .slice(0, 96);
  return cleaned || "master";
}

function stamp() {
  const d = new Date();
  const p = (n, w = 2) => String(n).padStart(w, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// ---------------------------------------------------------------------------
// Output-name reservation — atomic, and valid ACROSS processes
// ---------------------------------------------------------------------------
//
// Checking only the filesystem is not enough: the engine renders to a pid-scoped temp and
// only moves it into place at the very end, so a destination stays absent for the whole
// render. Two concurrent calls would therefore both see the name as free and both pick it;
// the loser's render is thrown away with an error after minutes of CPU, and both callers had
// already been handed the same path.
//
// An in-process Set closes that window for one server. It does nothing at all for two server
// processes pointed at the same SUNSET_OUT_DIR — each has its own Set and neither can see the
// other's. The claim therefore lives in the filesystem, where both can see it: a sidecar lock
// file created with O_EXCL ("wx"). The kernel guarantees exactly one creator of a given path,
// so exactly one render can ever hold a name, no matter how many processes are racing.
//
// The lock is a sidecar rather than the output file itself on purpose: the engine refuses any
// destination that already exists (exit 3), so a placeholder at the output path would make
// every render fail. The sidecar keeps the engine's own no-clobber guarantee intact.

const RESERVATION_SUFFIX = ".sunset-reserved";

/** Reservations this process currently holds, so they can be dropped when it exits. */
const heldReservations = new Set();

function reservationPathFor(outputPath) {
  return path.join(path.dirname(outputPath), `.${path.basename(outputPath)}${RESERVATION_SUFFIX}`);
}

/**
 * Try to claim `outputPath`. Returns true if this process now owns the name, false if some
 * other render (in this process or any other) already holds it. Any other failure throws —
 * a reservation that fails for an unexpected reason must never read as "the name is free".
 */
function tryReserveOutputPath(outputPath) {
  const lockPath = reservationPathFor(outputPath);
  let fd;
  try {
    // "wx" == O_CREAT | O_EXCL | O_WRONLY. Atomic: exactly one caller can succeed.
    fd = openSync(lockPath, "wx", 0o600);
  } catch (err) {
    if (err?.code === "EEXIST") return false;
    throw new ToolError(
      `Could not reserve the output name ${path.basename(outputPath)}: creating ${lockPath} failed (${err?.code || err?.message}). ` +
        `Refusing to render without a reservation — that is how two renders end up fighting over one file.`,
      { code: "RESERVATION_FAILED", details: { lock_path: lockPath, output_path: outputPath } }
    );
  }
  try {
    writeFileSync(
      fd,
      `${JSON.stringify(
        {
          note: "Sunset MCP output-name reservation. Safe to delete if no render is running.",
          output_path: outputPath,
          pid: process.pid,
          host: hostname(),
          reserved_at: new Date().toISOString(),
        },
        null,
        2
      )}\n`
    );
  } catch {
    // The lock's existence is the claim; its contents are a courtesy for a human reading it.
  } finally {
    try {
      closeSync(fd);
    } catch {
      /* fd already gone */
    }
  }
  heldReservations.add(outputPath);
  return true;
}

/** Release a reservation once the render that owns it has finished (success or failure). */
function releaseOutputPath(outputPath) {
  if (!outputPath) return;
  heldReservations.delete(outputPath);
  const lockPath = reservationPathFor(outputPath);
  try {
    unlinkSync(lockPath);
  } catch (err) {
    if (err?.code !== "ENOENT") log.warn(`could not remove reservation ${lockPath}: ${err?.code || err?.message}`);
  }
}

function releaseAllReservations() {
  for (const p of [...heldReservations]) releaseOutputPath(p);
}

// A lock left behind by a hard kill only costs a name (the next render takes the -2 suffix);
// it can never cause an overwrite. Still, drop them on the way out whenever we get the chance.
process.on("exit", releaseAllReservations);
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.once(sig, () => {
    releaseAllReservations();
    process.kill(process.pid, sig); // re-raise with the default disposition
  });
}

/**
 * Turn a requested name (or the input's name) into a path that is guaranteed to sit
 * directly inside outDir, to not already exist, and to not be reserved by a render that is
 * still in flight in ANY process sharing this directory. The returned path is reserved — the
 * caller MUST pass it to releaseOutputPath() when done.
 * Rejects anything containing a path separator — this tool has exactly one writable
 * directory and no way to escape it.
 *
 * With { reserve: false } it claims nothing and creates nothing: that mode is for the dry-run
 * preview, which must be able to say what it *would* write without touching the disk.
 */
function planOutputPath(outDir, inputPath, requestedName, { reserve = true } = {}) {
  let stem;
  let ext = ".wav";

  if (requestedName !== undefined && requestedName !== null && String(requestedName).trim() !== "") {
    const raw = String(requestedName).trim();
    if (raw.includes("/") || raw.includes("\\") || raw.includes("\0")) {
      throw new ToolError(
        `output_name must be a bare file name, not a path. Received ${JSON.stringify(raw)}. ` +
          `Every master is written inside ${outDir} and nowhere else; change SUNSET_OUT_DIR to write elsewhere.`,
        { code: "OUTPUT_NAME_HAS_PATH", details: { out_dir: outDir, env_var: "SUNSET_OUT_DIR" } }
      );
    }
    if (raw === "." || raw === "..") {
      throw new ToolError(`output_name ${JSON.stringify(raw)} is not a file name.`, { code: "OUTPUT_NAME_INVALID" });
    }
    const parsedExt = path.extname(raw).toLowerCase();
    if (parsedExt) {
      if (!ALLOWED_EXTENSIONS.has(parsedExt)) {
        throw new ToolError(
          `output_name extension "${parsedExt}" is not supported. Supported: ${[...ALLOWED_EXTENSIONS].join(", ")}.`,
          { code: "OUTPUT_EXT_UNSUPPORTED" }
        );
      }
      ext = parsedExt;
    }
    stem = sanitizeStem(path.basename(raw, path.extname(raw)));
  } else {
    stem = `${sanitizeStem(path.basename(inputPath, path.extname(inputPath)))}-master-${stamp()}`;
  }

  for (let n = 0; n < 200; n++) {
    const name = n === 0 ? `${stem}${ext}` : `${stem}-${n + 1}${ext}`;
    const candidate = path.join(outDir, name);
    // Belt and braces: the resolved path must still be a direct child of outDir.
    if (path.dirname(path.resolve(candidate)) !== outDir) {
      throw new ToolError(`Refusing to write outside ${outDir} (resolved to ${candidate}).`, {
        code: "OUTPUT_ESCAPES_DIR",
      });
    }
    if (fileExists(candidate)) continue; // already a master on disk under this name
    if (!reserve) return candidate; // dry run: report the name, claim nothing

    if (!tryReserveOutputPath(candidate)) continue; // a render in flight (any process) owns it

    // Won the lock — now re-check the destination. A file could have appeared between the
    // stat above and the claim, and losing that race must not hand back a name whose file
    // already exists.
    if (fileExists(candidate)) {
      releaseOutputPath(candidate);
      continue;
    }
    return candidate;
  }
  throw new ToolError(
    `Could not find an unused output name for "${stem}${ext}" in ${outDir} after 200 attempts — every candidate ` +
      `either exists on disk or is reserved by a render still in flight. Nothing was overwritten. Pass a different output_name.`,
    { code: "OUTPUT_NAME_EXHAUSTED", details: { out_dir: outDir, stem, ext } }
  );
}

// ---------------------------------------------------------------------------
// CLI invocation
// ---------------------------------------------------------------------------

function buildArgs({ input, output, reference, genre, platform, intensity, toneEq }) {
  const args = [input, output];
  if (reference) args.push("--reference", reference);
  if (genre) args.push("--genre", String(genre));
  if (platform) args.push("--platform", String(platform));
  if (intensity) args.push("--intensity", String(intensity));
  if (Array.isArray(toneEq) && toneEq.length) args.push("--eq", toneEq.join(","));
  args.push("--json");
  return args;
}

const EXIT_MEANING = {
  0: "ok",
  1: "runtime error",
  2: "usage error",
  3: "output already exists — the engine refused to overwrite it",
};

/**
 * Run the engine binary once. Never uses a shell. Returns the parsed JSON on success and
 * throws a ToolError carrying the real exit code and stderr on failure — no silent catches.
 */
function runEngine(args, { signal, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    let child;
    try {
      child = spawn(CLI_PATH, args, {
        cwd: cwd || REPO_ROOT,
        stdio: ["ignore", "pipe", "pipe"],
        signal,
      });
    } catch (err) {
      reject(new ToolError(`Could not launch the mastering engine at ${CLI_PATH}: ${err?.message}`, { code: "ENGINE_SPAWN_FAILED", cause: err }));
      return;
    }

    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (c) => {
      stdoutBytes += c.length;
      stdout += c;
    });
    child.stderr.on("data", (c) => {
      stderr += c;
      if (stderr.length > 512 * 1024) stderr = stderr.slice(-512 * 1024);
    });

    child.on("error", (err) => {
      reject(new ToolError(`The mastering engine failed to run: ${err?.message}`, { code: "ENGINE_RUN_FAILED", cause: err }));
    });

    child.on("close", (code, sigName) => {
      const duration_ms = Date.now() - started;
      // If the engine was killed mid-render it leaves its pid-scoped temp behind.
      // Its name is deterministic, so remove exactly that file and nothing else.
      if ((code !== 0 || sigName) && child.pid && args.length >= 2) {
        const outPath = args[1];
        const temp = path.join(path.dirname(outPath), `.sunset-cli-${child.pid}-${path.basename(outPath)}`);
        try {
          rmSync(temp, { force: true });
        } catch {
          /* nothing else to do; reported below alongside the real failure */
        }
      }

      if (sigName) {
        reject(
          new ToolError(
            `The mastering engine was terminated by signal ${sigName} after ${duration_ms}ms. No master was produced.` +
              (stderr.trim() ? `\nEngine stderr (tail):\n${stderr.trim().split("\n").slice(-12).join("\n")}` : ""),
            { code: "ENGINE_KILLED", details: { signal: sigName, duration_ms, args } }
          )
        );
        return;
      }
      if (code !== 0) {
        reject(
          new ToolError(
            `The mastering engine exited ${code} (${EXIT_MEANING[code] || "unknown exit code"}) after ${duration_ms}ms. No master was produced.` +
              (stderr.trim() ? `\nEngine stderr:\n${stderr.trim().split("\n").slice(-20).join("\n")}` : "\nThe engine printed nothing on stderr."),
            { code: `ENGINE_EXIT_${code}`, details: { exit_code: code, meaning: EXIT_MEANING[code] || null, duration_ms, args } }
          )
        );
        return;
      }

      let parsed;
      try {
        parsed = JSON.parse(stdout);
      } catch (err) {
        reject(
          new ToolError(
            `The mastering engine exited 0 but its stdout was not the expected JSON (${err?.message}). ` +
              `Received ${stdoutBytes} bytes starting: ${JSON.stringify(stdout.slice(0, 300))}`,
            { code: "ENGINE_BAD_JSON", details: { stdout_bytes: stdoutBytes, duration_ms } }
          )
        );
        return;
      }
      resolve({ analysis: parsed, stderr, duration_ms, exit_code: code, args });
    });
  });
}

/** Best-effort container/format read-back straight from the written file. */
function probeAudioFile(p) {
  try {
    const text = execFileSync("/usr/bin/afinfo", [p], { encoding: "utf8", timeout: 20_000 });
    const line = text.split("\n").find((l) => l.includes("Data format")) || "";
    const dur = text.split("\n").find((l) => l.trim().startsWith("estimated duration")) || "";
    return {
      probed_with: "/usr/bin/afinfo",
      data_format: line.replace(/^\s*Data format:\s*/, "").trim() || null,
      estimated_duration: dur.trim() || null,
    };
  } catch (err) {
    return { probed_with: "/usr/bin/afinfo", error: `probe failed: ${err?.message || String(err)}` };
  }
}

// ---------------------------------------------------------------------------
// Target discovery — real values from the binary, not a hardcoded list
// ---------------------------------------------------------------------------

function discoverTargets() {
  try {
    const text = execFileSync(CLI_PATH, ["--list-targets"], { encoding: "utf8", timeout: 15_000 });
    const genres = [];
    const platforms = [];
    let section = null;
    for (const raw of text.split("\n")) {
      if (/^genres:/.test(raw)) { section = "g"; continue; }
      if (/^platforms:/.test(raw)) { section = "p"; continue; }
      const line = raw.trim();
      if (!line) continue;
      if (section === "g") genres.push(line);
      else if (section === "p") platforms.push(line.replace(/\s{2,}[-+0-9].*$/, "").trim());
    }
    return { ok: true, genres, platforms };
  } catch (err) {
    return { ok: false, error: err?.message || String(err), genres: [], platforms: [] };
  }
}

const TARGETS = discoverTargets();
if (TARGETS.ok) {
  log.info(`targets discovered from the engine: ${TARGETS.genres.length} genres, ${TARGETS.platforms.length} platforms`);
} else {
  log.warn(`could not enumerate targets from ${CLI_PATH}: ${TARGETS.error}`);
}

const genreHint = TARGETS.ok && TARGETS.genres.length
  ? `Genres the engine reports: ${TARGETS.genres.join(" | ")}.`
  : `Genre names could not be read from the engine (${TARGETS.error}); run the binary with --list-targets.`;
const platformHint = TARGETS.ok && TARGETS.platforms.length
  ? `Platforms the engine reports: ${TARGETS.platforms.join(" | ")}.`
  : `Platform names could not be read from the engine (${TARGETS.error}); run the binary with --list-targets.`;

// ---------------------------------------------------------------------------
// Shared argument shapes
// ---------------------------------------------------------------------------

const INTENSITIES = ["gentle", "balanced", "loud", "max"];

const commonProps = {
  genre: {
    type: "string",
    description: `Tonal target used when no reference track is supplied. Matched case-insensitively, substring allowed. ${genreHint} Default: Melodic Techno / EDM.`,
  },
  platform: {
    type: "string",
    description: `Delivery target (sets loudness and true-peak ceiling). Matched case-insensitively, substring allowed. ${platformHint} Default: Club / DJ.`,
  },
  intensity: {
    type: "string",
    enum: INTENSITIES,
    description: "How hard the chain pushes. Default: balanced.",
  },
  tone_eq_db: {
    type: "array",
    items: { type: "number" },
    description: "Exactly 5 tone-control gains in dB, in order: sub, low, mid, presence, air. Omit for flat.",
  },
};

function validateToneEQ(toneEq) {
  if (toneEq === undefined || toneEq === null) return null;
  if (!Array.isArray(toneEq) || toneEq.length !== 5 || toneEq.some((n) => typeof n !== "number" || !Number.isFinite(n))) {
    throw new ToolError(
      `tone_eq_db must be exactly 5 finite numbers (sub, low, mid, presence, air) in dB. Received: ${JSON.stringify(toneEq)}`,
      { code: "TONE_EQ_INVALID" }
    );
  }
  return toneEq;
}

/** Compact, high-signal digest of the engine's own analysis object. */
function summarize(analysis) {
  const m = analysis?.master || {};
  const d = analysis?.doctor || {};
  return {
    loudness_before: m.before ?? null,
    loudness_after: m.after ?? null,
    multiband_gr_db: m.multiband_gr_db ?? null,
    limiter_gr_db: m.limiter_gr_db ?? null,
    eq_bands_moved: Array.isArray(m.applied_eq) ? m.applied_eq.length : null,
    what_it_did: analysis?.target_match?.notes ?? null,
    doctor_score: d.score ?? null,
    doctor_summary: d.summary ?? null,
    doctor_issues: Array.isArray(d.issues) ? d.issues.map((i) => `[${i.severity}] ${i.title}: ${i.detail}`) : null,
    release_checks: d.proof?.release_checks ?? null,
    reference_traits: d.proof?.reference_dna ?? null,
    platform_playback: m.platform_report ?? null,
  };
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

const masterTrack = {
  name: "sunset__master_track",
  description:
    "Master an audio file end to end through the Sunset engine and write the result as a new audio file. " +
    `Every master is written inside one directory this server owns (currently ${OUT_DIR_RAW}, set by SUNSET_OUT_DIR) — the tool cannot write anywhere else, ` +
    "and it does not write into any personal music library unless SUNSET_OUT_DIR is explicitly pointed at one. " +
    "It never overwrites: a name that is already taken gets a numeric suffix, the name is reserved against every other render on the machine for the duration, " +
    "and the engine itself refuses to clobber a destination. " +
    "Returns the real output path, its size on disk, a read-back of the written file, and the engine's full analysis JSON. " +
    "Mastering is CPU-bound and roughly real-time-ish; a long track can take minutes.",
  // This is the only tool here that puts a file on disk, so it is off unless explicitly enabled.
  gated: true,
  timeoutMs: TIMEOUT_MS,
  inputSchema: {
    type: "object",
    properties: {
      input_path: { type: "string", description: "Absolute path to the audio file to master (wav, aiff, mp3, m4a, flac — anything the system decoder reads)." },
      reference_path: { type: "string", description: "Optional reference track. When given, the master is matched to this track's Reference DNA instead of the genre target." },
      output_name: {
        type: "string",
        description:
          "Optional bare file name for the master (no directories). Extension may be .wav (default), .aif, .aiff, .flac or .m4a. " +
          "If the name is taken, a numeric suffix is added — nothing is ever overwritten.",
      },
      ...commonProps,
      full_analysis: { type: "boolean", description: "Include the engine's complete analysis JSON. Default: true." },
    },
    required: ["input_path"],
  },
  /**
   * What the gated refusal shows instead of running. Creates nothing, reserves nothing,
   * touches nothing — not even the output directory, which stays uncreated until a real
   * master is rendered.
   */
  async dryRun(args) {
    const dir = describeOutDir();
    const planningDir = dir.resolved || OUT_DIR_RAW;

    let engine = null;
    let engineError = null;
    try {
      engine = requireCLI();
    } catch (err) {
      engineError = err?.message || String(err);
    }

    let input = null;
    let inputError = null;
    try {
      input = requireReadableAudioFile(args.input_path, "input_path");
    } catch (err) {
      inputError = err?.message || String(err);
    }

    let reference = null;
    let referenceError = null;
    if (args.reference_path) {
      try {
        reference = requireReadableAudioFile(args.reference_path, "reference_path");
      } catch (err) {
        referenceError = err?.message || String(err);
      }
    }

    let toneEqError = null;
    try {
      validateToneEQ(args.tone_eq_db);
    } catch (err) {
      toneEqError = err?.message || String(err);
    }

    let plannedPath = null;
    let planError = null;
    if (input) {
      try {
        plannedPath = planOutputPath(planningDir, input.path, args.output_name, { reserve: false });
      } catch (err) {
        planError = err?.message || String(err);
      }
    }

    return {
      preview_available: true,
      tool: "sunset__master_track",
      wrote_nothing: true,
      dry_run_side_effects: "none — no directory created, no name reserved, no engine process started",
      would_execute: `one run of ${engine?.path || CLI_PATH}, producing exactly one new audio file`,
      would_write_to_directory: dir,
      would_write_path: plannedPath,
      would_write_path_note: plannedPath
        ? "Computed from the current directory contents. The default name embeds a timestamp, so a real run started later carries that later second; if the name were taken by then it would gain a numeric suffix instead."
        : "Not computable — see the errors below.",
      would_overwrite_anything: false,
      preconditions: {
        engine_present: Boolean(engine),
        engine_error: engineError,
        input_readable: Boolean(input),
        input_error: inputError,
        input: input ? { path: input.path, bytes: input.bytes } : null,
        reference_readable: args.reference_path ? Boolean(reference) : null,
        reference_error: referenceError,
        tone_eq_error: toneEqError,
        output_name_error: planError,
      },
      would_run_with: args,
    };
  },
  async handler(args, { signal }) {
    const engine = requireCLI();
    const input = requireReadableAudioFile(args.input_path, "input_path");
    const reference = args.reference_path ? requireReadableAudioFile(args.reference_path, "reference_path") : null;
    const toneEq = validateToneEQ(args.tone_eq_db);
    const outDir = ensureOutDir();
    // Reserves the name for the duration of this render; released in the finally below.
    const outputPath = planOutputPath(outDir, input.path, args.output_name);
    try {
      return await renderInto({ outputPath, outDir, input, reference, toneEq, args, engine, signal });
    } finally {
      releaseOutputPath(outputPath);
    }
  },
};

/** The body of sunset__master_track, split out so the path reservation is always released. */
async function renderInto({ outputPath, outDir, input, reference, toneEq, args, engine, signal }) {
    const cliArgs = buildArgs({
      input: input.path,
      output: outputPath,
      reference: reference?.path,
      genre: args.genre,
      platform: args.platform,
      intensity: args.intensity,
      toneEq,
    });

    log.info(`mastering ${path.basename(input.path)} -> ${path.basename(outputPath)}`);
    const run = await runEngine(cliArgs, { signal });

    // Read the file back from disk. The engine claiming success is not proof a file exists.
    let st;
    try {
      st = statSync(outputPath);
    } catch (err) {
      throw new ToolError(
        `The engine exited 0 but no file is present at ${outputPath} (${err?.code || err?.message}). Reporting success here would be a lie.`,
        { code: "OUTPUT_MISSING_AFTER_RUN", details: { expected_path: outputPath } }
      );
    }
    if (st.size === 0) {
      throw new ToolError(`The engine exited 0 but ${outputPath} is zero bytes.`, { code: "OUTPUT_EMPTY" });
    }
    if (run.analysis?.output && path.resolve(run.analysis.output) !== outputPath) {
      throw new ToolError(
        `The engine reported writing ${run.analysis.output} but this tool asked for ${outputPath}. Refusing to report a path that was not verified.`,
        { code: "OUTPUT_PATH_MISMATCH" }
      );
    }

    const result = {
      ok: true,
      status: "ok",
      executed: true,
      tool: "sunset__master_track",
      output: {
        path: outputPath,
        bytes: st.size,
        directory: outDir,
        confined_to: { env_var: "SUNSET_OUT_DIR", directory: outDir, is_server_default: OUT_DIR_IS_DEFAULT },
        overwrote_existing_file: false,
        no_overwrite_basis:
          "The name was absent from disk when it was chosen; it was then claimed with an O_EXCL sidecar lock " +
          `(${path.basename(reservationPathFor(outputPath))}) that no other render on this machine could create, ` +
          "re-checked as still absent after the claim, held for the whole render, and the engine independently " +
          "refuses a destination that already exists.",
        reservation: { lock_path: reservationPathFor(outputPath), mechanism: "O_EXCL exclusive create", scope: "all processes sharing this directory" },
        verified: `stat() on the written file: ${st.size} bytes, mtime ${st.mtime.toISOString()}`,
        read_back: probeAudioFile(outputPath),
      },
      input: { path: input.path, bytes: input.bytes },
      reference: reference ? { path: reference.path, bytes: reference.bytes } : null,
      settings: run.analysis?.settings ?? null,
      source: run.analysis?.source ?? null,
      summary: summarize(run.analysis),
      engine: {
        binary: engine.path,
        binary_bytes: engine.bytes,
        binary_mtime: engine.mtime,
        argv: cliArgs,
        exit_code: run.exit_code,
        duration_ms: run.duration_ms,
        stderr_tail: run.stderr.trim().split("\n").slice(-6).join("\n"),
      },
    };
    if (args.full_analysis !== false) result.analysis = run.analysis;
    else result.analysis_omitted = "full_analysis was set to false; re-run with full_analysis true for the engine's complete JSON.";
    return result;
}

const analyzeReference = {
  name: "sunset__analyze_reference",
  description:
    "Read-only analysis of a reference track: captures its Reference DNA (integrated loudness, true peak, side/mid ratio, " +
    "30-band spectral fingerprint) and verifies the saved-DNA round trip reproduces the live match. " +
    "Optionally pass track_path to also get the exact moves needed to match that track to the reference, plus the release checks. " +
    "Writes nothing you can see: the engine needs a render to produce its analysis, so the render goes to a private temporary " +
    "directory that is deleted before this tool returns. It never touches the master output directory and never modifies any input.",
  timeoutMs: TIMEOUT_MS,
  inputSchema: {
    type: "object",
    properties: {
      reference_path: { type: "string", description: "Absolute path to the reference track to analyze." },
      track_path: {
        type: "string",
        description:
          "Optional track to compare against the reference. When omitted the reference is analyzed against itself, " +
          "which yields its DNA plus a self-match sanity check.",
      },
      platform: commonProps.platform,
      intensity: commonProps.intensity,
      full_analysis: { type: "boolean", description: "Include the engine's complete analysis JSON. Default: false — the DNA and match sections are returned either way." },
    },
    required: ["reference_path"],
  },
  async handler(args, { signal }) {
    const engine = requireCLI();
    const reference = requireReadableAudioFile(args.reference_path, "reference_path");
    const track = args.track_path ? requireReadableAudioFile(args.track_path, "track_path") : null;

    let scratch;
    try {
      scratch = mkdtempSync(path.join(tmpdir(), "sunset-analyze-"));
    } catch (err) {
      throw new ToolError(`Cannot create a private scratch directory under ${tmpdir()}: ${err?.code || err?.message}`, {
        code: "SCRATCH_UNAVAILABLE",
      });
    }

    const scratchOut = path.join(scratch, "analysis-render.wav");
    const cliArgs = buildArgs({
      input: (track || reference).path,
      output: scratchOut,
      reference: reference.path,
      platform: args.platform,
      intensity: args.intensity,
    });

    let run;
    let cleanup = { removed: false, error: null };
    try {
      log.info(`analyzing reference ${path.basename(reference.path)}${track ? ` against ${path.basename(track.path)}` : " (self)"}`);
      run = await runEngine(cliArgs, { signal });
    } finally {
      try {
        rmSync(scratch, { recursive: true, force: true });
        let stillThere = true;
        try {
          statSync(scratch);
        } catch {
          stillThere = false;
        }
        cleanup = { removed: !stillThere, error: stillThere ? `${scratch} still exists after removal` : null };
      } catch (err) {
        cleanup = { removed: false, error: err?.message || String(err) };
      }
    }

    const ref = run.analysis?.reference;
    if (!ref || !ref.dna) {
      throw new ToolError(
        `The engine ran and exited 0 but its JSON contained no reference section, so there is no Reference DNA to report. ` +
          `Top-level keys present: ${Object.keys(run.analysis || {}).join(", ") || "(none)"}.`,
        { code: "NO_REFERENCE_SECTION" }
      );
    }

    const fingerprint = Array.isArray(ref.dna.fingerprint_db) ? ref.dna.fingerprint_db : [];
    const centers = Array.isArray(ref.dna.band_centers_hz) ? ref.dna.band_centers_hz : [];

    const result = {
      ok: true,
      status: "ok",
      executed: true,
      read_only: true,
      tool: "sunset__analyze_reference",
      reference: { path: reference.path, bytes: reference.bytes },
      compared_track: track ? { path: track.path, bytes: track.bytes } : null,
      mode: track ? "track-vs-reference" : "reference-vs-itself",
      dna: {
        integrated_lufs: ref.dna.integrated_lufs,
        true_peak_dbtp: ref.dna.true_peak_dbtp,
        side_mid_ratio: ref.dna.side_mid_ratio,
        band_count: fingerprint.length,
        spectrum: centers.map((hz, i) => ({ center_hz: hz, level_db: fingerprint[i] ?? null })),
      },
      dna_roundtrip_identical: ref.dna_roundtrip_identical,
      dna_roundtrip_note:
        ref.dna_roundtrip_identical === true
          ? "The match computed live from the reference audio and the match recomputed from the saved DNA profile are field-for-field identical, so a saved profile reproduces this match exactly."
          : "The live match and the saved-DNA match DIVERGED — a saved DNA profile would not reproduce this match. Reported as measured.",
      match_to_reference: ref.live_match ?? null,
      release_checks: run.analysis?.doctor?.proof?.release_checks ?? null,
      reference_traits: run.analysis?.doctor?.proof?.reference_dna ?? null,
      doctor: { score: run.analysis?.doctor?.score ?? null, summary: run.analysis?.doctor?.summary ?? null },
      source: run.analysis?.source ?? null,
      wrote_nothing_persistent: {
        note: "The engine only produces analysis as part of a render. That render was written to a private temp directory and deleted.",
        scratch_dir: scratch,
        scratch_removed: cleanup.removed,
        scratch_removal_error: cleanup.error,
        master_output_dir_touched: false,
      },
      engine: {
        binary: engine.path,
        argv: cliArgs,
        exit_code: run.exit_code,
        duration_ms: run.duration_ms,
        stderr_tail: run.stderr.trim().split("\n").slice(-6).join("\n"),
      },
    };
    if (args.full_analysis === true) result.analysis = run.analysis;
    return result;
  },
};

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

log.info(`engine binary: ${CLI_PATH}`);
log.info(
  `master output directory (SUNSET_OUT_DIR): ${OUT_DIR_RAW}` +
    (OUT_DIR_IS_DEFAULT ? " [server default — created on demand, not a personal music library]" : " [set by SUNSET_OUT_DIR]")
);
log.info(`sunset__master_track is gated: set SUNSET_ALLOW_GATED=1 to let it write`);
log.info(`per-tool timeout: ${TIMEOUT_MS}ms`);

createServer({
  name: SERVER_NAME,
  version: SERVER_VERSION,
  timeoutMs: TIMEOUT_MS,
  instructions:
    `Sunset mastering. sunset__master_track is GATED (SUNSET_ALLOW_GATED=1) because it writes a file; when enabled it renders a new master into ` +
    `${OUT_DIR_RAW} (SUNSET_OUT_DIR — a directory this server owns and creates on demand, not a personal music library) and never overwrites an existing file: ` +
    `names are reserved with an exclusive lock that holds across every process sharing that directory. ` +
    `sunset__analyze_reference is read-only and leaves no file behind. Mastering is CPU-bound: expect seconds to minutes depending on track length.`,
  tools: [masterTrack, analyzeReference],
});
