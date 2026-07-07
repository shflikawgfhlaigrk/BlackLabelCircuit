import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

test('macOS entry point is a native AppKit launcher with managed server lifecycle', () => {
  const src = read('macos/CircuitLauncher.swift');
  assert.match(src, /NSApplication\.shared\.delegate\s*=/, 'native app must install its delegate before NSApplication.run');
  assert.match(src, /NSApplication\.shared\.run\(\)/, 'native app must start the AppKit run loop explicitly');
  assert.match(src, /NSOpenPanel/, 'repo choice must use a native folder picker');
  assert.match(src, /Process\(\)/, 'server must run as a managed child process');
  assert.match(src, /terminationHandler/, 'launcher must observe child termination');
  assert.match(src, /terminateServer/, 'launcher must terminate the child on app quit');
  assert.match(src, /NSWorkspace\.shared\.open/, 'launcher must open the default browser');
  assert.match(src, /Application Support/, 'recents must live in user state, not the app bundle');
  assert.match(src, /requires Apple Silicon/, 'arm64-only Node runtime must be gated honestly');
  assert.doesNotMatch(src, /Google Chrome/, 'launcher must not depend on Chrome');
});

test('release build signs inside-out and ships no system-node fallback', () => {
  const build = read('build.command');
  assert.match(build, /DEVELOPER_DIR="\/Applications\/Xcode\.app\/Contents\/Developer"/, 'ship builds must avoid mismatched CommandLineTools SDKs');
  assert.match(build, /xcrun --kill-cache/, 'build must clear stale xcrun SDK cache after selecting Xcode');
  assert.match(build, /SDKROOT="\$\(xcrun --sdk macosx --show-sdk-path\)"/, 'build must pass an explicit macOS SDK to swiftc');
  assert.match(build, /xcrun swiftc/, 'build must compile through xcrun so SDK paths are configured');
  assert.match(build, /-sdk "\$SDKROOT"/, 'swiftc invocations must use the selected macOS SDK');
  assert.match(build, /-parse-as-library/, '@main launcher builds must pass -parse-as-library under Swift 6');
  assert.match(build, /xcrun lipo/, 'universal launcher assembly must use the selected Xcode toolchain');
  assert.match(build, /--options[ =]runtime/, 'build must use hardened runtime signing');
  assert.match(build, /Resources\/node\/node/, 'build must bundle a Node runtime inside the app');
  const nodeSign = build.indexOf('"$RESOURCES/node/node"');
  const appSign = build.indexOf('"$APP"', nodeSign + 1);
  assert.ok(nodeSign > 0, 'Node runtime must be signed explicitly');
  assert.ok(appSign > nodeSign, 'Node runtime must be signed before the app');
  assert.doesNotMatch(build, /command -v node/, 'release app must not fall back to system Node');
  assert.doesNotMatch(build, /\/opt\/homebrew\/bin\/node/, 'release app must not depend on Homebrew Node at runtime');
});
