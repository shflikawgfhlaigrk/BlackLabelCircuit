#!/usr/bin/env bash
# Circuit-Win build orchestration — runs in the W0 Windows VM (needs the Rust
# toolchain + Tauri CLI + a Windows node). STAGED: it builds an UNSIGNED installer
# and then calls the fail-closed sign gate, which HOLDS until the cert exists
# (2026-07-21). Nothing here publishes or ships.
#
#   bash windows/build-win.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC_TAURI="$HERE/src-tauri"
APP="$SRC_TAURI/app"

echo "== [1/5] fetch the Windows node runtime (Tauri sidecar) =="
node "$HERE/fetch-node-runtime.mjs"

echo "== [2/5] assemble the app resource (zero-runtime-dependency backend) =="
rm -rf "$APP"
mkdir -p "$APP"
cp "$REPO/server.js" "$APP/"
cp "$REPO/package.json" "$APP/"
cp -R "$REPO/lib" "$APP/lib"
cp -R "$REPO/public" "$APP/public"
cp -R "$REPO/editor" "$APP/editor"
# public/ must already carry the vendored three.js bundle:
node "$REPO/build-vendor.mjs"
cp -R "$REPO/public/." "$APP/public/"
echo "   staged app resource:"
du -sh "$APP" 2>/dev/null || true

echo "== [3/5] cargo check (first build gate — proves the Rust compiles) =="
( cd "$SRC_TAURI" && cargo check )

echo "== [4/5] tauri build (UNSIGNED NSIS installer) =="
( cd "$SRC_TAURI" && cargo tauri build )
INSTALLER="$(find "$SRC_TAURI/target/release/bundle" -name '*-setup.exe' | head -1 || true)"
echo "   installer: ${INSTALLER:-<none produced>}"

echo "== [5/5] sign gate (FAIL-CLOSED until the cert exists) =="
if [ -n "${INSTALLER:-}" ]; then
  # This is EXPECTED to hold (exit 3) today — that is the gate working, not a bug.
  node "$HERE/sign-windows.mjs" "$INSTALLER" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "== sign gate HELD (rc=3) — unsigned installer staged, NOT published. Expected. =="
      exit 0
    fi
    echo "== sign gate errored (rc=$rc) =="
    exit "$rc"
  }
  echo "== signed — ready for the gauntlet on the clean-buyer snapshot =="
else
  echo "== no installer produced — nothing to sign =="
  exit 1
fi
