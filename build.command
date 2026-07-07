#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Circuit.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
IDENTITY="${SIGN_IDENTITY:-05494FC15FB97F422400BC32DF6D67FC2D28855B}"
NODE_VERSION="${CIRCUIT_NODE_VERSION:-25.9.0}"
NODE_CACHE="$HOME/Library/Caches/CircuitBuild/node-v$NODE_VERSION-darwin-arm64/bin/node"
INSTALL=0

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SWIFTC=(xcrun swiftc)
LIPO=(xcrun lipo)

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

require_file() {
  if [[ ! -e "$1" ]]; then
    echo "missing: $1" >&2
    exit 1
  fi
}

node_source() {
  if [[ -n "${CIRCUIT_NODE_SOURCE:-}" ]]; then
    printf '%s\n' "$CIRCUIT_NODE_SOURCE"
    return
  fi
  if [[ -x "$NODE_CACHE" ]]; then
    printf '%s\n' "$NODE_CACHE"
    return
  fi
  if [[ -x "/Applications/Circuit.app/Contents/Resources/node/node" ]]; then
    printf '%s\n' "/Applications/Circuit.app/Contents/Resources/node/node"
    return
  fi

  local cache_dir archive extract_dir
  cache_dir="$HOME/Library/Caches/CircuitBuild"
  archive="$cache_dir/node-v$NODE_VERSION-darwin-arm64.tar.gz"
  extract_dir="$cache_dir/node-v$NODE_VERSION-darwin-arm64"
  mkdir -p "$cache_dir"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.gz" -o "$archive"
  rm -rf "$extract_dir"
  tar -xzf "$archive" -C "$cache_dir"
  require_file "$NODE_CACHE"
  printf '%s\n' "$NODE_CACHE"
}

rm -rf "$APP" "$BUILD_DIR/launcher-arm64" "$BUILD_DIR/launcher-x86_64"
mkdir -p "$MACOS" "$RESOURCES/app" "$RESOURCES/node" "$BUILD_DIR"

"${SWIFTC[@]}" -O -parse-as-library -target arm64-apple-macos11 -framework AppKit \
  "$ROOT/macos/CircuitLauncher.swift" \
  -o "$BUILD_DIR/launcher-arm64"
"${SWIFTC[@]}" -O -parse-as-library -target x86_64-apple-macos11 -framework AppKit \
  "$ROOT/macos/CircuitLauncher.swift" \
  -o "$BUILD_DIR/launcher-x86_64"
"${LIPO[@]}" -create "$BUILD_DIR/launcher-arm64" "$BUILD_DIR/launcher-x86_64" -output "$MACOS/Circuit"
chmod 755 "$MACOS/Circuit"

cp "$ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/macos/Circuit.icns" ]]; then
  cp "$ROOT/macos/Circuit.icns" "$RESOURCES/Circuit.icns"
elif [[ -f "/Applications/Circuit.app/Contents/Resources/Circuit.icns" ]]; then
  cp "/Applications/Circuit.app/Contents/Resources/Circuit.icns" "$RESOURCES/Circuit.icns"
fi
printf 'APPL????' > "$CONTENTS/PkgInfo"

rsync -a --delete \
  "$ROOT/server.js" \
  "$ROOT/package.json" \
  "$ROOT/lib" \
  "$ROOT/public" \
  "$RESOURCES/app/"

NODE_SRC="$(node_source)"
cp "$NODE_SRC" "$RESOURCES/node/node"
chmod 755 "$RESOURCES/node/node"

codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  --entitlements "$ROOT/macos/node.entitlements" \
  "$RESOURCES/node/node"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  --entitlements "$ROOT/macos/app.entitlements" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
file "$MACOS/Circuit"
file "$RESOURCES/node/node"
lipo -archs "$MACOS/Circuit"
lipo -archs "$RESOURCES/node/node"

if [[ "$INSTALL" -eq 1 ]]; then
  rm -rf "/Applications/Circuit.app"
  ditto "$APP" "/Applications/Circuit.app"
  codesign --verify --deep --strict --verbose=2 "/Applications/Circuit.app"
  echo "installed: /Applications/Circuit.app"
else
  echo "built: $APP"
fi
