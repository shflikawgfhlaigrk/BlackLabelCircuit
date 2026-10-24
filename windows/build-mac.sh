#!/usr/bin/env bash
# Circuit for macOS, built from the SAME Tauri shell as Windows (src-tauri/): one
# native app window, the same folder picker + recents, the same bundled node server
# and the same 3D UI — so the Mac and Windows apps are one codebase, not two.
#
# Produces an ad-hoc-signed Circuit.app for this Mac. Developer ID signing and
# notarization for distribution stay a release step (owner-gated).
#
#   bash windows/build-mac.sh [path/to/node]      (or CIRCUIT_NODE=/path/to/node)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC_TAURI="$HERE/src-tauri"
APP="$SRC_TAURI/app"
TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"

echo "== [1/4] node runtime for the sidecar ($TRIPLE) =="
NODE_BIN="${1:-${CIRCUIT_NODE:-}}"
if [ -z "$NODE_BIN" ] && [ -x /Applications/Circuit.app/Contents/Resources/node/node ]; then
  NODE_BIN=/Applications/Circuit.app/Contents/Resources/node/node
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "No node runtime to bundle. Pass a self-contained node binary or set CIRCUIT_NODE." >&2
  exit 1
fi
# A Homebrew node links against Homebrew's own dylibs and would not run on another Mac.
if otool -L "$NODE_BIN" | grep -Eq '/opt/homebrew|/usr/local/(opt|Cellar)'; then
  echo "Refusing $NODE_BIN: it is linked against Homebrew libraries, not self-contained." >&2
  exit 1
fi
mkdir -p "$SRC_TAURI/binaries"
cp "$NODE_BIN" "$SRC_TAURI/binaries/node-$TRIPLE"
echo "   node $("$NODE_BIN" --version) from $NODE_BIN"

echo "== [2/4] assemble the app resource (zero-runtime-dependency backend) =="
rm -rf "$APP"
mkdir -p "$APP"
cp "$REPO/server.js" "$REPO/package.json" "$APP/"
cp -R "$REPO/lib" "$REPO/public" "$REPO/editor" "$APP/"
if [ -d "$REPO/node_modules/esbuild" ]; then
  node "$REPO/build-vendor.mjs"
  cp -R "$REPO/public/." "$APP/public/"
fi
du -sh "$APP" | sed 's/^/   /'

echo "== [3/4] tauri build (macOS .app) =="
( cd "$SRC_TAURI" && npx --yes @tauri-apps/cli@2 build --bundles app )
BUNDLE="$SRC_TAURI/target/release/bundle/macos/Circuit.app"
[ -d "$BUNDLE" ] || { echo "no Circuit.app produced" >&2; exit 1; }

echo "== [4/4] ad-hoc sign + verify =="
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
echo "   $BUNDLE"
