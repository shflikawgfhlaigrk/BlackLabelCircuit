import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileWindowsApplication } from '../lib/windows-app-compiler.js';

const LIVE_SOURCE = `import Cocoa
import SwiftUI
let asset = "wallpaper.png"
struct WallpaperView: View { var body: some View { TimelineView(.animation) { _ in Canvas { _, _ in } } } }
let BLWLetterbox = true
func toggleLetterbox() {}
func togglePause() {}
let pause = "Pause Animation"
let screens = NSScreen.screens
let level = CGWindowLevelForKey(.desktopWindow)
let ignoresMouseEvents = true
let statusItem = NSStatusBar.system.statusItem(withLength: 1)
let defaults = UserDefaults.standard
let display = NSApplication.didChangeScreenParametersNotification
let quit = "Quit Black Label Live Wallpaper"
NSApp.terminate(nil)
`;

test('recognized single-file live wallpaper generates a complete deterministic Windows project', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-live-source-'));
  const outOne = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-live-one-'));
  const outTwo = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-live-two-'));
  fs.mkdirSync(path.join(sourceRoot, 'assets'));
  fs.writeFileSync(path.join(sourceRoot, 'assets', 'wallpaper.png'), Buffer.from('locked-wallpaper'));
  const input = { files: [{ file: 'Sources/main.swift', source: LIVE_SOURCE }], sourceRoot };
  const one = compileWindowsApplication({ ...input, outDir: outOne });
  const two = compileWindowsApplication({ ...input, outDir: outTwo });
  assert.equal(one.generated, true);
  assert.equal(one.requiredResiduals, 0);
  assert.equal(one.featureMatrix.length, 10);
  assert.equal(one.asset.sha256, crypto.createHash('sha256').update('locked-wallpaper').digest('hex'));
  assert.deepEqual(one, two);
  for (const rel of ['BlackLabelLiveWallpaper.csproj', 'App.xaml.cs', 'WallpaperWindow.cs', 'acceptance.ps1', 'feature-matrix.json']) {
    assert.equal(fs.readFileSync(path.join(outOne, 'windows-app', rel), 'utf8'), fs.readFileSync(path.join(outTwo, 'windows-app', rel), 'utf8'));
  }
});

test('unrecognized app fails closed with explicit required residuals', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-other-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-other-out-'));
  const result = compileWindowsApplication({ files: [{ file: 'A.swift', source: 'struct A {}' }], sourceRoot, outDir: out });
  assert.equal(result.generated, false);
  assert.ok(result.residuals.length > 0);
});
