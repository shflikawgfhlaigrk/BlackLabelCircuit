import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { portCheck, formatPortReport, fileRole } from '../lib/port.js';
import { discoverFiles } from '../lib/walk.js';
import { APPLE_MODULES, PYTHON_MODULES, JS_MODULES, MAC_COMMANDS, MAC_PATHS } from '../lib/port-map.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function fixture(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-port-'));
  for (const [rel, body] of Object.entries(files)) {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, body);
  }
  return dir;
}

const REPO = {
  'Package.swift': 'import PackageDescription\nlet package = Package(name: "Demo", targets: [.target(name: "Core"), .executableTarget(name: "App")])\n',
  'Sources/Core/Model.swift': 'import Foundation\n// we used to shell out to osascript here\nstruct Model { let name: String }\n',
  'Sources/App/MainView.swift': 'import SwiftUI\nimport Core\nimport Sparkle\nimport SomeThirdParty\nstruct MainView: View { var body: some View { Text("hi") } }\n',
  'Sources/App/Calendar.swift': 'import Foundation\nimport EventKit\nfinal class Cal { let store = EKEventStore() }\n',
  'Sources/App/Guarded.swift': '#if canImport(AppKit)\nimport AppKit\n#endif\nstruct Guarded {}\n',
  'Sources/App/Handled.swift': '#if os(macOS)\nimport AppKit\n#elseif os(Windows)\nimport WinSDK\n#endif\nstruct Handled {}\n',
  'Sources/App/Shell.swift': 'import Foundation\nfunc run() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript") }\n',
  'Tests/AppTests/ModelTests.swift': 'import XCTest\nfinal class ModelTests: XCTestCase {}\n',
  'scripts/release.sh': '#!/bin/sh\n# sign it\ncodesign --sign "Developer ID" App.app\n',
  'engine/mac.py': 'import AppKit\n',
  'engine/guarded.py': 'import sys\nif sys.platform == "darwin":\n    import Quartz\nx = 1\n',
  'engine/handled.py': 'import sys\nif sys.platform == "darwin":\n    import Quartz\nelif sys.platform == "win32":\n    import ctypes\n',
  'engine/else_branch.py': 'import sys\nif sys.platform != "darwin":\n    pass\nelse:\n    import AppKit\n',
  'engine/cmd.py': 'import subprocess, os\ndef speak(script):\n    subprocess.run(["osascript", "-e", script])\nHOME = os.path.expanduser("~/Library/Application Support/Demo")\n',
  'engine/posix.py': 'import fcntl\n',
  'app/perm.js': "const perms = require('node-mac-permissions');\n",
  'app/ok.js': "import fs from 'node:fs';\nexport const x = fs;\n",
  'app/guard.js': "import { execSync } from 'node:child_process';\nif (process.platform === 'darwin') {\n  execSync('pbcopy');\n}\n",
};

test('port map: every non-portable entry names its Windows counterpart and a size', () => {
  const tables = [APPLE_MODULES, PYTHON_MODULES, JS_MODULES];
  for (const t of tables) {
    for (const [id, e] of Object.entries(t)) {
      assert.ok(['portable', 'ui', 'system', 'package', 'unix'].includes(e.kind), `${id} kind`);
      if (e.kind === 'portable') continue;
      assert.ok(typeof e.windows === 'string' && e.windows.length > 3, `${id} windows`);
      assert.ok(['S', 'M', 'L'].includes(e.effort), `${id} effort`);
    }
  }
  for (const c of [...MAC_COMMANDS, ...MAC_PATHS]) {
    assert.ok(c.re instanceof RegExp && c.id && c.windows && ['S', 'M', 'L'].includes(c.effort), c.id);
  }
});

test('file roles: tests and tooling are counted apart from app code', () => {
  assert.equal(fileRole('Tests/AppTests/ModelTests.swift', 'swift'), 'test');
  assert.equal(fileRole('engine/test_parser.py', 'python'), 'test');
  assert.equal(fileRole('scripts/release.sh', 'shell'), 'tooling');
  assert.equal(fileRole('Sources/App/MainView.swift', 'swift'), 'app');
});

test('port check classifies every file and aggregates the Windows parts needed', () => {
  const dir = fixture(REPO);
  const r = portCheck(dir);
  const status = Object.fromEntries(r.files.map((f) => [f.id, f.status]));

  assert.equal(status['Sources/Core/Model.swift'], 'ready', 'Foundation-only, comment mention ignored');
  assert.equal(status['Sources/App/MainView.swift'], 'needs-windows');
  assert.equal(status['Sources/App/Calendar.swift'], 'needs-windows');
  assert.equal(status['Sources/App/Guarded.swift'], 'guarded', 'compiled out on Windows, no Windows branch');
  assert.equal(status['Sources/App/Handled.swift'], 'ready', 'has an os(Windows) branch');
  assert.equal(status['Sources/App/Shell.swift'], 'needs-windows', 'shells out to osascript');
  assert.equal(status['Tests/AppTests/ModelTests.swift'], 'ready');
  assert.equal(status['scripts/release.sh'], 'needs-windows');
  assert.equal(status['engine/mac.py'], 'needs-windows');
  assert.equal(status['engine/guarded.py'], 'guarded');
  assert.equal(status['engine/handled.py'], 'ready');
  assert.equal(status['engine/else_branch.py'], 'guarded', 'else of a != darwin check is the Mac branch');
  assert.equal(status['engine/cmd.py'], 'needs-windows');
  assert.equal(status['engine/posix.py'], 'needs-windows');
  assert.equal(status['app/perm.js'], 'needs-windows');
  assert.equal(status['app/ok.js'], 'ready');
  assert.equal(status['app/guard.js'], 'guarded');

  const handled = r.files.find((f) => f.id === 'Sources/App/Handled.swift');
  assert.equal(handled.handled, true);

  const blockerIds = r.blockers.map((b) => b.id);
  for (const id of ['SwiftUI', 'EventKit', 'Sparkle', 'osascript', 'AppKit', 'fcntl', 'node-mac-permissions', '~/Library']) {
    assert.ok(blockerIds.includes(id), `blocker ${id} in ${blockerIds.join(', ')}`);
  }
  assert.ok(!blockerIds.includes('codesign/notarytool'), 'tooling hits are not app blockers');
  const osa = r.blockers.find((b) => b.id === 'osascript');
  assert.equal(osa.kind, 'command');
  assert.equal(osa.files, 2, 'Shell.swift and cmd.py');
  const skippedIds = r.skipped.map((s) => s.id);
  assert.ok(skippedIds.includes('Quartz') && skippedIds.includes('pbcopy/pbpaste'), skippedIds.join(', '));

  const unknown = r.unknownModules.map((u) => u.id);
  assert.ok(unknown.includes('SomeThirdParty'));
  assert.ok(!unknown.includes('Core'), 'SwiftPM targets are internal');

  const app = r.summary.app;
  assert.equal(app.files, app.ready.files + app.guarded.files + app.needsWindows.files);
  assert.equal(app.loc, app.ready.loc + app.guarded.loc + app.needsWindows.loc);
  assert.ok(app.readyPct > 0 && app.readyPct < 100);
  assert.equal(r.summary.test.files, 1);
  assert.equal(r.summary.tooling.files, 2, 'release.sh and the Package.swift build manifest');
  assert.equal(r.files.find((f) => f.id === 'Package.swift').role, 'tooling');

  const text = formatPortReport(r);
  assert.match(text, /Windows port check/);
  assert.match(text, /EventKit/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('port check on an empty folder reports nothing to check, not a score', () => {
  const dir = fixture({ 'README.md': '# nothing\n' });
  const r = portCheck(dir);
  assert.equal(r.summary.app.files, 0);
  assert.equal(r.summary.app.readyPct, null);
  assert.match(formatPortReport(r), /nothing to check/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('port check rejects an unsupported target', () => {
  assert.throws(() => portCheck(os.tmpdir(), { target: 'amiga' }), /Unsupported port target/);
});

test('CLI --port-check prints the report, writes JSON and gates on --min-ready', () => {
  const dir = fixture(REPO);
  const json = path.join(dir, 'port.json');
  const ok = spawnSync(process.execPath, [path.join(ROOT, 'server.js'), '--port-check', dir, '--json', json], { encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /Windows port check/);
  const parsed = JSON.parse(fs.readFileSync(json, 'utf8'));
  assert.equal(parsed.target, 'windows');
  assert.ok(Array.isArray(parsed.blockers));

  const gate = spawnSync(process.execPath, [path.join(ROOT, 'server.js'), '--port-check', dir, '--min-ready', '99'], { encoding: 'utf8' });
  assert.equal(gate.status, 1, 'below the minimum fails the gate');
  assert.match(gate.stdout, /FAIL/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('port check never runs git or the network for a plain folder', () => {
  // Air-gap posture: the module imports nothing that can open a socket.
  const src = fs.readFileSync(path.join(ROOT, 'lib', 'port.js'), 'utf8');
  assert.ok(!/node:(http|https|net|dns|tls)/.test(src));
  assert.doesNotThrow(() => execFileSync(process.execPath, ['--check', path.join(ROOT, 'lib', 'port.js')]));
});

test('a folder inside a parent repo that ignores it is still scanned (git lists nothing there)', () => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-parent-'));
  execFileSync('git', ['init', '-q', parent]);
  fs.writeFileSync(path.join(parent, '.gitignore'), 'nested/\n');
  const nested = path.join(parent, 'nested', 'app');
  fs.mkdirSync(path.join(nested, 'Sources'), { recursive: true });
  fs.writeFileSync(path.join(nested, 'Sources', 'View.swift'), 'import SwiftUI\nstruct V {}\n');
  const { files } = discoverFiles(nested);
  assert.deepEqual(files.map((f) => f.rel), ['Sources/View.swift']);
  assert.equal(portCheck(nested).summary.app.files, 1);
  fs.rmSync(parent, { recursive: true, force: true });
});
