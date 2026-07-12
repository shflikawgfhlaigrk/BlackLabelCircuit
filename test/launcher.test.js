import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

// The ship build (build.command) pins Xcode's toolchain rather than CommandLineTools;
// the compile gate must type-check under the same SDK it will actually ship through.
const XCODE_DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer';

function swiftEnv() {
  const env = { ...process.env };
  if (fs.existsSync(XCODE_DEVELOPER_DIR)) env.DEVELOPER_DIR = XCODE_DEVELOPER_DIR;
  return env;
}

// A missing toolchain is a FAILURE, never a silent pass: "we could not compile the
// Swift" must never be reported as "the Swift compiles".
function macosSDKPath(env) {
  const probe = spawnSync('xcrun', ['--sdk', 'macosx', '--show-sdk-path'], { encoding: 'utf8', env });
  if (probe.error) {
    assert.fail(`Swift compile gate cannot run: xcrun is unavailable (${probe.error.message}). A missing toolchain is not a passing type-check — install Xcode/CommandLineTools.`);
  }
  if (probe.status !== 0) {
    assert.fail(`Swift compile gate cannot run: 'xcrun --sdk macosx --show-sdk-path' exited ${probe.status}.\n${probe.stderr}`);
  }
  const sdk = probe.stdout.trim();
  assert.ok(sdk && fs.existsSync(sdk), `Swift compile gate cannot run: macOS SDK path '${sdk}' does not exist.`);
  return sdk;
}

function typecheck(target) {
  const env = swiftEnv();
  const sdk = macosSDKPath(env);
  const result = spawnSync('xcrun', [
    'swiftc', '-typecheck', '-parse-as-library',
    '-sdk', sdk,
    '-target', target,
    '-framework', 'AppKit',
    path.join(ROOT, 'macos/CircuitLauncher.swift'),
  ], { encoding: 'utf8', env, timeout: 180_000 });
  if (result.error) {
    assert.fail(`Swift compile gate cannot run: swiftc failed to launch (${result.error.message}).`);
  }
  return result;
}

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

// THE LOAD-BEARING CHECK. Everything below this point asserts regexes over Swift
// SOURCE TEXT — those pin intent, but they stay green through a compile error, so on
// their own they can only ever prove that a string is present. These two tests compile
// the launcher for real, once per architecture the ship build produces, so a broken
// CircuitLauncher.swift turns `npm test` red without waiting for a human to run
// build.command. Both targets matter: requiresAppleSiliconGate() is #if arch(x86_64),
// so an arm64-only type-check would never look inside that branch.
//
// Skipped off-darwin (the Windows CI lane runs this same suite and has no macOS SDK —
// it also never builds the launcher, so there is nothing there to prove). That is a
// SKIP, not a pass. On darwin the gate is unconditional: a mac that cannot find its
// own toolchain fails loudly rather than reporting the Swift as compiling.
const IS_MACOS = process.platform === 'darwin';
for (const target of ['arm64-apple-macosx11.0', 'x86_64-apple-macosx11.0']) {
  test(`CircuitLauncher.swift type-checks against the macOS SDK (${target})`, {
    skip: IS_MACOS ? false : 'macOS launcher is only compiled on darwin',
  }, () => {
    const result = typecheck(target);
    assert.equal(
      result.status, 0,
      `swiftc -typecheck failed for ${target} (exit ${result.status}) — the macOS launcher does not compile:\n${result.stderr}`
    );
  });
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

test('drag-a-folder onboarding is wired end to end (CI-19)', () => {
  const src = read('macos/CircuitLauncher.swift');
  // Dock-icon / "Open With" folder open.
  assert.match(src, /func application\([^)]*openFiles/, 'launcher handles application(_:openFiles:)');
  // In-window drag well.
  assert.match(src, /registerForDraggedTypes/, 'a view registers for dragged file types');
  assert.match(src, /func draggingEntered/, 'drop target implements draggingEntered');
  assert.match(src, /func performDragOperation/, 'drop target implements performDragOperation');
  assert.match(src, /isDirectory/, 'drop only accepts a folder, not a file');
  const plist = read('macos/Info.plist');
  assert.match(plist, /CFBundleDocumentTypes/, 'Info.plist declares document types so folder drops route to the app');
  assert.match(plist, /public\.folder/, 'Info.plist accepts folders (public.folder)');
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
