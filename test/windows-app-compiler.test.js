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
  assert.equal(result.kind, 'unclassified');
  assert.equal(result.residuals[0].feature, 'windowsApplication');
  assert.ok(result.residuals.length > 0);
});

test('audio app with canvas and saved settings is not mislabeled as a Live Wallpaper', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-audio-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-audio-out-'));
  const source = 'struct SunsetApp { let waveform = Canvas { _, _ in }; let settings = UserDefaults.standard; let output = "master.wav" }';
  const result = compileWindowsApplication({ files: [{ file: 'UI/SunsetApp.swift', source }], sourceRoot, outDir: out });
  assert.equal(result.generated, false);
  assert.equal(result.kind, 'unclassified');
  assert.deepEqual(result.residuals.map((row) => row.feature), ['windowsApplication']);
  assert.equal(fs.existsSync(path.join(out, 'windows-app')), false);
});

test('partial Live Wallpaper reports the missing asset as a residual', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-partial-wallpaper-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-partial-wallpaper-out-'));
  const result = compileWindowsApplication({ files: [{ file: 'Sources/main.swift', source: LIVE_SOURCE }], sourceRoot, outDir: out });
  assert.equal(result.generated, false);
  assert.equal(result.kind, 'live-wallpaper');
  assert.ok(result.residuals.some((row) => row.feature === 'wallpaperAsset'));
});

test('Academy source and provenance-gated reader generate a complete offline Windows project', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-academy-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-academy-out-'));
  const payload = path.join(sourceRoot, 'windows', 'dist', 'reader');
  fs.mkdirSync(payload, { recursive: true });
  fs.writeFileSync(path.join(payload, 'index.html'), '<html>Academy</html>');
  fs.writeFileSync(path.join(payload, 'BlackLabelAcademy.sqlite'), 'SQLite format 3');
  fs.writeFileSync(path.join(payload, 'academy-reader.json'), JSON.stringify({
    pillars: ['niches'], offer: { trial_days: 7 }, entries: [{ title: 'Lesson', body_html: '<h1>Lesson</h1>', checkpoints: [{ prompt: 'p', answer: 'a' }], metrics: [{ key: 'tam', provenance: 'source' }] }],
  }));
  const result = compileWindowsApplication({ files: [{ file: 'Sources/AcademyApp.swift', source: 'struct BlackLabelAcademy {}' }], sourceRoot, outDir: out });
  assert.equal(result.generated, true);
  assert.equal(result.kind, 'academy');
  assert.equal(result.requiredResiduals, 0);
  assert.equal(result.featureMatrix.length, 9);
  for (const rel of ['BlackLabelAcademy.csproj', 'MainWindow.xaml', 'App.xaml.cs', 'acceptance.ps1', 'Payload/academy-reader.json']) assert.ok(fs.existsSync(path.join(out, 'windows-app', rel)), rel);
});

test('Trading source and its cross-platform runtime generate a ships-empty Windows package workspace', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-trading-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-trading-out-'));
  const files = {
    'windows/supervise.py': 'print("plan")',
    'windows/launch-trading.cmd': '@python supervise.py',
    'windows/python-embed.sha256': `${'a'.repeat(64)}\n`,
    'windows/msix/launcher/Launcher.cs': 'internal static class Launcher { static int Main(string[] args) => 0; }',
  };
  for (const name of ['bltd_alerts.py', 'bltd_analytics.py', 'bltd_api.py', 'bltd_browser.py', 'bltd_capture.py', 'bltd_feeds.py', 'bltd_optimizer.py', 'bltd_optimizer_cli.py', 'bltd_parsers.py', 'bltd_paths.py', 'bltd_rithmic.py', 'bltd_rprotocol.py', 'bltd_store.py', 'bltd_topstep_bridge.py', 'bltd_tradovate.py', 'bltd_projectx.py']) files[`backend/${name}`] = '# portable runtime\n';
  for (const [rel, body] of Object.entries(files)) {
    const target = path.join(sourceRoot, rel);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, body);
  }
  const result = compileWindowsApplication({ files: [{ file: 'Sources/main.swift', source: 'struct BlackLabelTrading { let signals = SignalCore() }' }], sourceRoot, outDir: out });
  assert.equal(result.generated, true);
  assert.equal(result.kind, 'trading');
  assert.equal(result.requiredResiduals, 0);
  assert.equal(result.featureMatrix.length, 10);
  for (const rel of ['BlackLabelTrading.csproj', 'acceptance.ps1', 'windows/supervise.py', 'windows/msix/launcher/Launcher.cs', 'backend/bltd_api.py']) assert.ok(fs.existsSync(path.join(out, 'windows-app', rel)), rel);
});

test('Real Estate source and its byte-pinned Electron lane generate an installable Windows workspace', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-realestate-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-realestate-out-'));
  const files = {
    'windows-electron/main.js': 'require("electron")', 'windows-electron/serve.js': 'module.exports={}',
    'windows-electron/package.json': '{}', 'windows-electron/package-lock.json': '{}',
    'windows-electron/electron-builder.config.js': 'module.exports={}',
    'windows-electron/scripts/stage.mjs': '', 'windows-electron/scripts/smoke.js': '',
    'windows/src-tauri/icons/icon.ico': 'ico', 'windows/ui/index.html': '<div id="app"></div>',
    'windows/ui/api.js': 'const BLRE_API={}', 'windows/ui/app.js': 'function PropertyIndex(){}',
    'windows/ui/styles.css': 'body{}', 'windows/ui/vendor/leaflet/leaflet.js': 'window.L={}',
  };
  for (const [rel, body] of Object.entries(files)) {
    const target = path.join(sourceRoot, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, body);
  }
  const result = compileWindowsApplication({ files: [{ file: 'Sources/main.swift', source: 'struct BLRealEstateApp { let screen = PropertyIndexScreen() }' }], sourceRoot, outDir: out });
  assert.equal(result.generated, true);
  assert.equal(result.kind, 'real-estate');
  assert.equal(result.requiredResiduals, 0);
  assert.equal(result.featureMatrix.length, 8);
  for (const rel of ['acceptance.ps1', 'windows-electron/main.js', 'windows-electron/package-lock.json', 'windows/ui/index.html']) assert.ok(fs.existsSync(path.join(out, 'windows-app', rel)), rel);
});

test('Marketing source generates the complete offline-first Windows workspace', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-marketing-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-marketing-out-'));
  const result = compileWindowsApplication({ files: [{ file: 'Sources/main.swift', source: 'struct BlackLabelMarketing { let os = MarketingOSScreen(); let reel = ReelProject() }' }], sourceRoot, outDir: out });
  assert.equal(result.generated, true);
  assert.equal(result.kind, 'marketing');
  assert.equal(result.requiredResiduals, 0);
  assert.equal(result.featureMatrix.length, 16);
  const html = fs.readFileSync(path.join(out, 'windows-app', 'Payload', 'index.html'), 'utf8');
  for (const label of ['Marketing OS', 'Reel Studio', 'Email Builder', 'Design Studio', 'SEO Toolkit', 'Settings']) assert.match(html, new RegExp(label));
});

test('Operator source and Python Engine generate a native ships-empty Windows workspace', () => {
  const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-operator-source-'));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-operator-out-'));
  const engine = path.join(sourceRoot, 'Engine', 'blacklabel_operator');
  fs.mkdirSync(engine, { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, 'Engine', 'pyproject.toml'), '[project]\nname="blacklabel-operator"\n');
  fs.writeFileSync(path.join(engine, '__init__.py'), '__version__="test"\n');
  fs.writeFileSync(path.join(engine, 'store.py'), 'class Store: pass\n');
  fs.writeFileSync(path.join(engine, 'upgrade_lock.py'), 'import fcntl\n');
  const result = compileWindowsApplication({ files: [{ file: 'Sources/main.swift', source: 'let title = "Black Label Operator"; enum OperatorDestination {}' }], sourceRoot, outDir: out });
  assert.equal(result.generated, true);
  assert.equal(result.kind, 'operator');
  assert.equal(result.requiredResiduals, 0);
  assert.equal(result.featureMatrix.length, 18);
  assert.equal(result.identity.canonical, 'operator');
  for (const rel of ['BlackLabelOperator.csproj', 'MainWindow.xaml', 'acceptance.ps1', 'Engine/blacklabel_operator/store.py', 'Engine/blacklabel_operator/upgrade_lock.py']) assert.ok(fs.existsSync(path.join(out, 'windows-app', rel)), rel);
  assert.match(fs.readFileSync(path.join(out, 'windows-app', 'Engine/blacklabel_operator/upgrade_lock.py'), 'utf8'), /msvcrt/);
});

test('Ace Build 87 source generates a native privacy-gated Windows workspace', () => {
  const sourceRoot=fs.mkdtempSync(path.join(os.tmpdir(),'circuit-ace-source-'));const out=fs.mkdtempSync(path.join(os.tmpdir(),'circuit-ace-out-'));
  fs.mkdirSync(path.join(sourceRoot,'leanring-buddy'),{recursive:true});fs.writeFileSync(path.join(sourceRoot,'MODERNIZATION-87.md'),'Build 87');fs.writeFileSync(path.join(sourceRoot,'leanring-buddy','MeetingNotetaker.swift'),'struct MeetingNotetaker {}');
  const result=compileWindowsApplication({files:[{file:'leanring-buddy/main.swift',source:'struct leanring_buddyApp { let manager=CompanionManager(); let privacy=StealthMode() }'}],sourceRoot,outDir:out});
  assert.equal(result.generated,true);assert.equal(result.kind,'ace');assert.equal(result.requiredResiduals,0);assert.equal(result.featureMatrix.length,12);assert.equal(result.sourceIdentity.build,87);
  for(const rel of ['Ace.csproj','AceCore.cs','MainWindow.xaml','acceptance.ps1','feature-matrix.json'])assert.ok(fs.existsSync(path.join(out,'windows-app',rel)),rel);
});
