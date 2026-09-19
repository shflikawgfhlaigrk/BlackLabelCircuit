#!/usr/bin/env bash
# Circuit-Win MSIX packaging — STORE-FIRST (contract windows-w1-circuit-20260720,
# founder amendment ~09:05Z). Produces an UNSIGNED .msix staged for Microsoft Store
# submission: the Store re-signs the package under the Partner Center account identity,
# so NO Authenticode cert is purchased or applied on the Store path.
#
#   bash windows/build-msix.sh            # VM: assemble layout -> makeappx pack -> unsigned .msix
#   bash windows/build-msix.sh --validate # ANY host (darwin ok): assemble layout + validate manifest, no pack
#   bash windows/build-msix.sh --sideload # VM only: additionally self-sign for LOCAL sideload testing
#
# The unsigned Store artifact is the deliverable. --sideload is a test-only convenience that
# routes through the FAIL-CLOSED sign gate (windows/sign-windows.mjs) and is never the Store path.
set -euo pipefail

MODE="${1:-pack}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MSIX="$HERE/msix"
SRC_TAURI="$HERE/src-tauri"
# Layout and output dirs default into windows/, but are overridable so two concurrent runs (e.g.
# parallel test files, or a matrix job) cannot rm -rf each other's layout mid-build. Both defaults
# are derived from this script's own location — never from a caller's cwd or an absolute path.
LAYOUT="${CIRCUIT_MSIX_LAYOUT:-$HERE/msix-layout}"   # package root handed to makeappx
DIST="${CIRCUIT_MSIX_DIST:-$HERE/dist}"
OUT="$DIST/Circuit.msix"

# --- Partner Center identity -----------------------------------------------------------------
# The three Store identity values are ASSIGNED by Partner Center after the app name is reserved.
# They are NEVER guessed here. They live in exactly ONE place, windows/msix/partner-center.env
# (gitignored; template at partner-center.env.example). Real environment variables win over the
# file, so CI can inject them as secrets without a file on disk.
PC_ENV="$MSIX/partner-center.env"
if [ -f "$PC_ENV" ]; then
  # shellcheck disable=SC1090
  set -a; . "$PC_ENV"; set +a
  echo "== identity: loaded $PC_ENV =="
fi
PC_NAME="${PARTNER_CENTER_IDENTITY_NAME:-}"
PC_IDENTITY="${PARTNER_CENTER_IDENTITY:-}"
PC_DISPLAY="${PARTNER_CENTER_PUBLISHER_DISPLAY:-}"
# An EMPTY value must not silently blank the manifest — fall back to the visible placeholder token
# so a half-filled env file cannot produce a manifest that looks resolved but is not.
[ -n "$PC_NAME" ]     || PC_NAME="PARTNER-CENTER-PLACEHOLDER.Circuit"
[ -n "$PC_IDENTITY" ] || PC_IDENTITY="CN=PARTNER-CENTER-PLACEHOLDER"
[ -n "$PC_DISPLAY" ]  || PC_DISPLAY="__PUBLISHER_DISPLAY_NAME__"
PC_VERSION="${PARTNER_CENTER_PACKAGE_VERSION:-}"

echo "== [1/4] assemble the MSIX package layout =="
rm -rf "$LAYOUT"
mkdir -p "$LAYOUT/Assets"

# The Tauri shell exe (built by build-win.sh -> cargo tauri build) is the package entry point.
# On the VM this lands under target/release; on --validate we allow a placeholder so the layout
# and manifest can be checked on darwin without a Windows build.
SHELL_EXE="$(find "$SRC_TAURI/target/release" -maxdepth 1 -name 'Circuit.exe' 2>/dev/null | head -1 || true)"
if [ -n "$SHELL_EXE" ]; then
  cp "$SHELL_EXE" "$LAYOUT/Circuit.exe"
elif [ "$MODE" = "--validate" ] || [ "$MODE" = "--pack-layout" ]; then
  printf 'MZ placeholder — real Circuit.exe is produced by cargo tauri build in the W0 VM' > "$LAYOUT/Circuit.exe"
  echo "   ($MODE) no built Circuit.exe present; wrote a placeholder to exercise the layout"
else
  echo "   ERROR: Circuit.exe not found under $SRC_TAURI/target/release — run build-win.sh first." >&2
  exit 1
fi

# The zero-dependency node payload + sidecar (same app/ that build-win.sh assembles).
node "$REPO/build-vendor.mjs"
mkdir -p "$LAYOUT/app"
cp "$REPO/server.js" "$REPO/package.json" "$LAYOUT/app/"
cp -R "$REPO/lib" "$REPO/public" "$REPO/editor" "$LAYOUT/app/"
if [ -f "$SRC_TAURI/binaries/node-x86_64-pc-windows-msvc.exe" ]; then
  cp "$SRC_TAURI/binaries/node-x86_64-pc-windows-msvc.exe" "$LAYOUT/node.exe"
elif [ "$MODE" != "--validate" ] && [ "$MODE" != "--pack-layout" ]; then
  echo "   ERROR: node sidecar missing — run windows/fetch-node-runtime.mjs first." >&2
  exit 1
fi

# Store tile/logo assets. These are REAL, format+dimension-valid placeholder PNGs (brand-neutral
# Circuit node-graph motif) so makeappx cannot fail the pack on the assets; final Store art is a
# web-producer + founder deliverable that drops in over the same filenames. The prior recipe wrote
# TEXT files named "*.png" here — makeappx rejects those, so a full VM cargo build would pack-fail.
#
# Bootstrap ONLY when a tile is absent or is not a real PNG. Regenerating on any --check failure
# would silently overwrite founder-approved final art with the placeholder motif and pack THAT —
# a drifted-but-real tile must stop the pack loudly, never be papered over.
if ! node "$MSIX/gen-assets.mjs" --check-basic >/dev/null 2>&1; then
  echo "   staging tiles missing/unusable — minting spec-dimension placeholder PNGs"
  node "$MSIX/gen-assets.mjs"
fi
# Hard gate on whatever art is actually present: spec dimensions + no text-bearing metadata chunks.
if ! node "$MSIX/gen-assets.mjs" --check; then
  echo "   ERROR: Store tile gate failed (see above). Refusing to pack." >&2
  exit 1
fi
cp "$MSIX/Assets/"*.png "$LAYOUT/Assets/"

echo "== [2/4] resolve manifest identity (Partner Center) =="
sed -e "s|Name=\"PARTNER-CENTER-PLACEHOLDER.Circuit\"|Name=\"$PC_NAME\"|" \
    -e "s|CN=PARTNER-CENTER-PLACEHOLDER|$PC_IDENTITY|" \
    -e "s|__PUBLISHER_DISPLAY_NAME__|$PC_DISPLAY|" \
    "$MSIX/AppxManifest.xml" > "$LAYOUT/AppxManifest.xml"
if [ -n "$PC_VERSION" ]; then
  case "$PC_VERSION" in
    *.*.*.0) sed -i.bak -e "s|Version=\"[0-9.]*\"|Version=\"$PC_VERSION\"|" "$LAYOUT/AppxManifest.xml" && rm -f "$LAYOUT/AppxManifest.xml.bak" ;;
    *) echo "   ERROR: PARTNER_CENTER_PACKAGE_VERSION must be 4 parts with revision 0 (e.g. 1.2.3.0); got '$PC_VERSION'" >&2; exit 1 ;;
  esac
fi

# The identity verdict is written to a file so CI (and a human reading an artifact) can tell a
# submittable package from a placeholder one WITHOUT opening the manifest. A green pack is not
# evidence of a submittable package — only resolved identity is.
mkdir -p "$DIST"
# The status MUST be derived from the three identity ELEMENT VALUES, never from a grep over the
# whole file: the manifest carries a documentation comment that names the placeholder tokens, so
# a whole-file grep reports PLACEHOLDER forever and STORE-READY becomes unreachable. <Identity>
# also spans several lines, which a line-oriented grep silently misses. Parse the document.
node -e '
  const fs = require("fs");
  const m = fs.readFileSync(process.argv[1], "utf8");
  const id = (m.match(/<Identity\b[\s\S]*?\/>/) || [""])[0];
  const g = (re, s) => { const x = s.match(re); return x ? x[1] : null; };
  const vals = {
    "Identity/Name": g(/\bName="([^"]*)"/, id),
    "Identity/Publisher": g(/\bPublisher="([^"]*)"/, id),
    "PublisherDisplayName": g(/<PublisherDisplayName>([^<]*)<\/PublisherDisplayName>/, m),
  };
  const version = g(/\bVersion="([^"]*)"/, id);
  const unresolved = Object.entries(vals).filter(
    ([, v]) => v === null || /PARTNER-CENTER-PLACEHOLDER|__PUBLISHER_DISPLAY_NAME__/.test(v));
  const status = unresolved.length ? "IDENTITY-PLACEHOLDER" : "STORE-READY";
  const lines = [status];
  for (const [k, v] of Object.entries(vals)) lines.push(k.padEnd(20) + " = " + (v === null ? "<MISSING>" : v));
  lines.push("Identity/Version".padEnd(20) + " = " + (version === null ? "<MISSING>" : version));
  if (unresolved.length) lines.push("unresolved: " + unresolved.map(([k]) => k).join(", "));
  fs.writeFileSync(process.argv[2], lines.join("\n") + "\n");
  console.log(lines.map((l) => "   " + l).join("\n"));
' "$LAYOUT/AppxManifest.xml" "$DIST/IDENTITY-STATUS.txt"
IDENTITY_STATUS="$(head -1 "$DIST/IDENTITY-STATUS.txt")"
if [ "$IDENTITY_STATUS" != "STORE-READY" ]; then
  echo "   NOTE: identity is still a PLACEHOLDER. This .msix is NOT submittable."
  echo "         Fill windows/msix/partner-center.env (see partner-center.env.example)."
fi

echo "== [3/4] validate the manifest is well-formed XML =="
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$LAYOUT/AppxManifest.xml"
  echo "   xmllint: AppxManifest.xml is well-formed"
else
  node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8"); if(!/<Package[\s>]/.test(s)||!/<\/Package>\s*$/.test(s)) throw new Error("manifest not well-formed"); console.log("   node check: AppxManifest.xml has a Package root")' "$LAYOUT/AppxManifest.xml"
fi

echo "== [3b/4] pre-pack gate: every manifest-referenced Assets\\*.png exists in the layout as a real PNG =="
# makeappx fails the pack if a referenced logo is missing or is not a real PNG. Catch that on ANY
# host (darwin included) so a VM cargo-build round-trip is never spent to discover a bad asset.
node - "$LAYOUT" <<'NODE'
const fs = require('fs'), path = require('path');
const layout = process.argv[2];
const man = fs.readFileSync(path.join(layout, 'AppxManifest.xml'), 'utf8');
const refs = [...man.matchAll(/(?:Assets\\|Assets\/)([A-Za-z0-9._-]+\.png)/g)].map(m => m[1]);
const uniq = [...new Set(refs)];
if (!uniq.length) { console.error('   ERROR: manifest references no Assets\\*.png — VisualElements/Logo broken'); process.exit(1); }
let bad = 0;
for (const name of uniq) {
  const f = path.join(layout, 'Assets', name);
  if (!fs.existsSync(f)) { console.error(`   MISSING layout asset: ${name}`); bad++; continue; }
  const b = fs.readFileSync(f);
  const sigOk = b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  if (!sigOk) { console.error(`   NOT A PNG (would fail makeappx): ${name}`); bad++; continue; }
  console.log(`   ok ${name} ${b.readUInt32BE(16)}x${b.readUInt32BE(20)}`);
}
process.exit(bad ? 1 : 0);
NODE

if [ "$MODE" = "--validate" ]; then
  echo "== [4/4] --validate: layout assembled + manifest valid. No .msix packed (host-agnostic). =="
  du -sh "$LAYOUT" 2>/dev/null || true
  exit 0
fi

# --pack-layout: pack the already-assembled+validated layout with makeappx and STOP. This isolates
# the makeappx pack STEP (construction-engineer W02's named W1 dependency) from the heavier Rust/
# Tauri exe bring-up, so the Store-MSIX pack can be proven green on a real Windows runner (the
# windows-latest CI job) even before the Tauri toolchain lands. Still UNSIGNED + staged-only.

echo "== [4/4] makeappx pack -> UNSIGNED .msix (staged for Store) =="
command -v makeappx >/dev/null 2>&1 || { echo "   ERROR: makeappx (Windows SDK) not on PATH — run in the W0 VM." >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
# Git Bash on a Windows runner resolves this script's paths as POSIX (/d/a/...). With argument
# conversion off (MSYS_NO_PATHCONV keeps the /d /p /overwrite switches intact) makeappx received
# them verbatim and read them relative to the current drive — "\\?\D:\d\a\...: The system cannot
# find the path specified" (run 33730563460). Hand it native Windows paths explicitly: cygpath
# ships with Git for Windows; on a host without it (darwin) this step never runs anyway.
if command -v cygpath >/dev/null 2>&1; then
  PACK_DIR="$(cygpath -w "$LAYOUT")"; PACK_OUT="$(cygpath -w "$OUT")"
else
  PACK_DIR="$LAYOUT"; PACK_OUT="$OUT"
fi
MSYS_NO_PATHCONV=1 makeappx pack /d "$PACK_DIR" /p "$PACK_OUT" /overwrite
echo "   staged (UNSIGNED, Store-ready): $OUT"

if [ "$MODE" = "--sideload" ]; then
  echo "== [sideload] self-sign for LOCAL testing only (fail-closed; NOT the Store path) =="
  node "$HERE/sign-windows.mjs" "$OUT" || {
    rc=$?
    [ "$rc" -eq 3 ] && { echo "== sign gate HELD (rc=3) — no test cert; unsigned .msix staged. Expected. =="; exit 0; }
    exit "$rc"
  }
fi
echo "== done — upload $OUT to Partner Center; the Store signs it. =="
