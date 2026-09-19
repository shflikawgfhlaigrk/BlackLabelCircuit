import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  convertRepo, convertSwiftSource, convertPythonSource, convertJsSource, isolateSwiftSource,
  isolateSwiftDeclarations, swiftTopLevelChunks, isolatedLoc, xcodegenSources, detectSwiftSettings,
  formatConvertReport, formatConvertMarkdown, guardMissingImport, runKitSelfTest, writeKitSelfTest,
} from '../lib/convert.js';
import { SWIFT_IMPORT_RULES, SWIFT_PACKAGES, SIM_FLAG, ISOLATE_OPEN, ISOLATE_CLOSE } from '../lib/convert-rules.js';
import { portCheck } from '../lib/port.js';
import { APPLE_MODULES } from '../lib/port-map.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function fixture(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-convert-'));
  for (const [rel, body] of Object.entries(files)) {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, body);
  }
  return dir;
}
const outDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-convert-out-'));

test('convert rules: every drop-in names a real package product and every rule a note', () => {
  for (const [mod, rule] of Object.entries(SWIFT_IMPORT_RULES)) {
    assert.ok(['dropin', 'kit', 'platform', 'visible'].includes(rule.type), `${mod} type`);
    assert.ok(rule.note && rule.note.length > 5, `${mod} note`);
    for (const [, pkg] of rule.products ?? []) assert.ok(SWIFT_PACKAGES[pkg]?.url.startsWith('https://'), `${mod} → ${pkg}`);
    // a module Convert rewrites must be one the port check reports, or the before/after numbers lie
    assert.ok(APPLE_MODULES[mod] && APPLE_MODULES[mod].kind !== 'portable', `${mod} is in the port map as Mac-only`);
  }
});

test('swift: drop-in imports become per-platform imports, Apple-only imports are hidden off Apple platforms', () => {
  const src = ['// header', 'import Foundation', 'import SwiftUI', 'import Combine', '@preconcurrency import CryptoKit', 'import os.log', '',
    'final class M: ObservableObject { @Published var n = 0 }', ''].join('\n');
  const r = convertSwiftSource(src);
  assert.ok(r.changed);
  assert.match(r.text, new RegExp(`#if canImport\\(Combine\\) && !${SIM_FLAG}\\nimport Combine\\n#else\\nimport OpenCombine\\nimport OpenCombineFoundation\\nimport OpenCombineDispatch\\n#endif`));
  assert.match(r.text, /#else\n@preconcurrency import Crypto\n#endif/, 'attributes travel with the import');
  assert.match(r.text, new RegExp(`#if canImport\\(os\\) && !${SIM_FLAG}\\nimport os\\.log\\n#else\\nimport CircuitPortKit\\n#endif`));
  assert.match(r.text, new RegExp(`#if canImport\\(SwiftUI\\) && !${SIM_FLAG}\\nimport SwiftUI\\n#endif`));
  assert.deepEqual(r.guardedModules, ['SwiftUI']);
  assert.ok(r.needsKit);
  assert.deepEqual([...r.products.keys()].sort(), ['Crypto', 'OpenCombine', 'OpenCombineDispatch', 'OpenCombineFoundation']);
  assert.ok(r.text.includes('final class M: ObservableObject { @Published var n = 0 }'), 'code is untouched');
});

test('swift: imports already inside a platform conditional are left exactly as written', () => {
  const src = '#if canImport(AppKit)\nimport AppKit\n#endif\nimport Foundation\nstruct S {}\n';
  const r = convertSwiftSource(src);
  assert.equal(r.text, src);
  assert.equal(r.changed, false);
});

test('swift: URLSession users get FoundationNetworking; a file that leaned on SwiftUI for Foundation gets it spelled out', () => {
  const net = convertSwiftSource('import Foundation\nfunc f() { _ = URLSession.shared }\n');
  assert.match(net.text, /import Foundation\n#if canImport\(FoundationNetworking\)\nimport FoundationNetworking\n#endif/);
  const already = convertSwiftSource('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\nfunc f() { _ = URLSession.shared }\n');
  assert.equal(already.changed, false);
  const ui = convertSwiftSource('import SwiftUI\nstruct P { let when: Date }\n');
  assert.match(ui.text, /^import Foundation$/m);
  const comment = convertSwiftSource('import Foundation\n// URLSession is mentioned only here\nstruct S {}\n');
  assert.equal(comment.changed, false, 'a name inside a comment is not a use');
});

test('swift: an import inside an embedded script (multi-line string) is never mistaken for one of the file', () => {
  const src = ['import AppKit', '', 'func script() -> String {', '    let s = """', '        python3 - <<PY', 'import json', 'import sys', '        PY', '        """', '    return s', '}', 'func net() { _ = URLSession.shared }', ''].join('\n');
  const r = convertSwiftSource(src);
  const lines = r.text.split('\n');
  const at = lines.indexOf('import Foundation');
  assert.ok(at >= 0 && at < lines.indexOf('func script() -> String {'), 'injected imports sit with the real imports, above the code');
  assert.ok(r.text.includes('        python3 - <<PY\nimport json\nimport sys\n        PY'), 'the embedded script is byte-for-byte');
});

test('swift: Combine schedulers and Foundation publishers go through the kit, never inside comments or strings', () => {
  const src = ['import Foundation', 'import Combine', 'func f(p: AnyPublisher<Int, Never>) -> AnyCancellable {',
    '  // p.receive(on: DispatchQueue.main) stays a comment',
    '  let s = "x.receive(on: DispatchQueue.main)"',
    '  _ = NotificationCenter.default.publisher(for: .init("n"))',
    '  return p.debounce(for: .seconds(1), scheduler: RunLoop.main).receive(on: DispatchQueue.main).sink { _ in _ = s }',
    '}', ''].join('\n');
  const r = convertSwiftSource(src);
  assert.ok(r.text.includes('.receive(on: DispatchQueue.main.circuitScheduler).sink'));
  assert.ok(r.text.includes('scheduler: RunLoop.main.circuitScheduler)'));
  assert.ok(r.text.includes('NotificationCenter.default.circuitCombine.publisher('));
  assert.ok(r.text.includes('// p.receive(on: DispatchQueue.main) stays a comment'));
  assert.ok(r.text.includes('"x.receive(on: DispatchQueue.main)"'));
  assert.match(r.text, /^import CircuitPortKit$/m, 'the bridge lives in the kit on every platform');
  // converting the converted text again changes nothing (idempotent)
  assert.equal(convertSwiftSource(r.text).text, r.text);
});

test('swift: Security becomes the kit Keychain; a file using Keychain names without the import gets the kit', () => {
  const explicit = convertSwiftSource('import Foundation\nimport Security\n\nfunc wipe() -> OSStatus { SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary) }\n');
  assert.match(explicit.text, new RegExp(`#if canImport\\(Security\\) && !${SIM_FLAG}\\nimport Security\\n#else\\nimport CircuitPortKit\\n#endif`));
  assert.deepEqual(explicit.kitModules, ['Security']);
  assert.deepEqual(explicit.guardedModules, [], 'Security is converted, not hidden');
  assert.ok(explicit.needsKit);
  // On the Mac, Foundation re-exports Security, so a file can use the names without importing it.
  const names = convertSwiftSource('import Foundation\n\nlet key = kSecAttrAccount as String\n');
  assert.match(names.text, /^import CircuitPortKit$/m);
  assert.deepEqual(names.kitModules, ['Security']);
  assert.equal(convertSwiftSource(names.text).text, names.text, 'idempotent');
  // Already importing the kit off Apple platforms (here through the os rule) is enough.
  const viaOs = convertSwiftSource('import Foundation\nimport os\n\nlet key = kSecAttrAccount as String\n');
  assert.equal(viaOs.text.match(/import CircuitPortKit/g).length, 1);
  const comment = convertSwiftSource('import Foundation\n// kSecAttrAccount only in a comment\nstruct S {}\n');
  assert.equal(comment.changed, false, 'a name inside a comment is not a use');
});

test('swift: Combine used without an import (SwiftUI / Foundation re-export it on the Mac) gets OpenCombine', () => {
  const src = 'import SwiftUI\n\nfinal class Model: ObservableObject { @Published var n = 0 }\nfunc f(p: PassthroughSubject<Int, Never>) { _ = p.receive(on: DispatchQueue.main) }\n';
  const r = convertSwiftSource(src);
  assert.match(r.text, new RegExp(`#if canImport\\(Combine\\) && !${SIM_FLAG}\\nimport Combine\\n#else\\nimport OpenCombine\\nimport OpenCombineFoundation\\nimport OpenCombineDispatch\\n#endif`));
  assert.match(r.text, /^import CircuitPortKit$/m, 'the scheduler bridge');
  assert.ok(r.text.includes('.receive(on: DispatchQueue.main.circuitScheduler)'));
  assert.deepEqual([...r.products.keys()].sort(), ['OpenCombine', 'OpenCombineDispatch', 'OpenCombineFoundation']);
  assert.equal(convertSwiftSource(r.text).text, r.text, 'idempotent');
  const explicit = convertSwiftSource('import Combine\nimport os\nlet l = Logger()\nfunc f(p: AnyPublisher<Int, Never>) { _ = p.receive(on: RunLoop.main) }\n');
  const lines = explicit.text.split('\n');
  assert.ok(lines.some((l, i) => l === 'import CircuitPortKit' && lines[i - 1] !== '#else'), 'the bridge needs an import on every platform, not only in the os rule\'s #else branch');
  assert.equal(convertSwiftSource('import Foundation\n// ObservableObject in a comment\nstruct S {}\n').changed, false);
});

test('swift: CoreGraphics stays visible in the Mac simulation (Foundation has its geometry on Windows)', () => {
  const r = convertSwiftSource('import CoreGraphics\n\nfunc area(_ r: CGRect) -> CGFloat { r.width * r.height }\n');
  assert.match(r.text, /#if canImport\(CoreGraphics\)\nimport CoreGraphics\n#endif/);
  assert.ok(!r.text.includes(`canImport(CoreGraphics) && !${SIM_FLAG}`), 'never hidden while simulating: that hides members Windows has');
  assert.match(r.text, /^import Foundation$/m, 'Foundation brings the geometry off Apple platforms');
  assert.deepEqual(r.guardedModules, ['CoreGraphics'], 'drawing code isolated later still reports what it waits for');
  assert.equal(convertSwiftSource(r.text).text, r.text, 'idempotent');
});

test('swift: Darwin becomes ucrt on Windows, never WinSDK (its UUID makes Foundation\'s ambiguous)', () => {
  const r = convertSwiftSource('import Foundation\nimport Darwin\nlet id = UUID()\n');
  assert.match(r.text, /#elseif canImport\(ucrt\)\nimport ucrt\n#elseif canImport\(Glibc\)/);
  assert.ok(!/WinSDK/.test(r.text));
});

test('verify: an import of a module the platform lacks is hidden, never the whole file', () => {
  const src = ['import Foundation', '@preconcurrency import Accelerate.vecLib', '', 'func fft() { vDSP_create_fftsetup(4, 2) }', 'func keep() -> Int { 1 }', ''].join('\n');
  const next = guardMissingImport(src, 2, 'Accelerate.vecLib');
  assert.equal(next, ['import Foundation', `#if canImport(Accelerate) && !${SIM_FLAG}`, '@preconcurrency import Accelerate.vecLib', '#endif', '', 'func fft() { vDSP_create_fftsetup(4, 2) }', 'func keep() -> Int { 1 }', ''].join('\n'));
  assert.equal(guardMissingImport(src, 4, 'Accelerate'), null, 'only an import line of that module is touched');
  for (const mod of ['Accelerate', 'FoundationModels', 'simd', 'ImagePlayground']) assert.ok(APPLE_MODULES[mod] && APPLE_MODULES[mod].kind !== 'portable', `${mod} is in the port map`);
});

test('verify: the compiler loop hides a missing module, then isolates only what uses it; Keychain code converts', { timeout: 600_000 }, (t) => {
  const swift = spawnSync('swift', ['--version'], { encoding: 'utf8' });
  if (swift.error || swift.status !== 0) { t.skip('no swift toolchain on this host'); return; }
  const dir = fixture({
    'Sources/Engine.swift': 'import Foundation\nimport CircuitNoSuchModule\n\nfunc engine() -> Int { CircuitNoSuchModule.value }\nfunc plain() -> Int { 2 }\n',
    'Sources/Secrets.swift': 'import Foundation\nimport Security\n\nfunc token(_ account: String) -> Data? {\n    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "demo", kSecAttrAccount as String: account]\n    q[kSecReturnData as String] = true\n    var out: AnyObject?\n    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }\n    return out as? Data\n}\n',
  });
  const out = outDir();
  const r = convertRepo(dir, { out, verify: true });
  assert.equal(r.verification.ok, true, r.verification.failure ?? '');
  const by = Object.fromEntries(r.files.map((f) => [f.id, f]));
  assert.equal(by['Sources/Engine.swift'].status, 'partial', 'plain() still builds');
  assert.ok(by['Sources/Engine.swift'].guardedModules.includes('CircuitNoSuchModule'));
  assert.ok(r.verification.passes.some((p) => p.hiddenImports), 'the pass that hid the import is on record');
  assert.equal(by['Sources/Secrets.swift'].status, 'converted', 'Keychain code builds in the Windows configuration (Apple\'s names on a Mac, the kit on Windows)');
  assert.ok(fs.existsSync(path.join(out, 'kit', 'CircuitPortKit', 'Keychain.swift')));
  assert.match(r.source.sha256, /^[0-9a-f]{64}$/);
  assert.equal(r.source.files, 2);
  assert.match(formatConvertMarkdown(r), /Source read: 2 files, sha256 `[0-9a-f]{16}`/);
});

test('kit self-test: the Keychain calls exactly as converted apps make them', { timeout: 600_000 }, (t) => {
  const swift = spawnSync('swift', ['--version'], { encoding: 'utf8' });
  if (swift.error || swift.status !== 0) { t.skip('no swift toolchain on this host'); return; }
  const r = runKitSelfTest(outDir());
  assert.equal(r.ok, true, r.output);
  assert.ok(r.passed >= 30, `${r.passed} checks passed`);
  assert.equal(r.failed, 0);
});

test('kit: the Security parts stay empty wherever Apple\'s Security exists (no ambiguity in the Mac simulation)', () => {
  const kit = path.join(ROOT, 'lib', 'convert-kit', 'CircuitPortKit');
  assert.match(fs.readFileSync(path.join(kit, 'Security.swift'), 'utf8'), /^#if !canImport\(Security\) \|\| CIRCUIT_KIT_SELFTEST$/m);
  assert.match(fs.readFileSync(path.join(kit, 'Keychain.swift'), 'utf8'), /^#if os\(Windows\) \|\| CIRCUIT_KIT_SELFTEST$/m);
  // on Windows the self-test uses the kit as its own module, exactly as a converted package does
  const win = outDir();
  writeKitSelfTest(win, { platform: 'win32' });
  const manifest = fs.readFileSync(path.join(win, 'Package.swift'), 'utf8');
  assert.ok(manifest.includes('.target(name: "CircuitPortKit", path: "kit/CircuitPortKit")') && manifest.includes('dependencies: ["CircuitPortKit"]'));
  assert.ok(!manifest.includes('CIRCUIT_KIT_SELFTEST'), 'the real store, not the in-memory one');
});

test('swift: top-level declarations are found with their attributes and doc comments', () => {
  const src = ['import Foundation', '', '/// A model.', '@MainActor', 'final class Model {', '  var n = 0', '  func f() {', '    if n > 0 { n -= 1 }', '  }', '}', '',
    '#if os(macOS)', 'let onlyMac = 1', '#endif', '', 'extension Model {', '  var label: String {', '    "n"', '  }', '}', '',
    'let table: [String: Int] = [', '  "a": 1,', ']', ''].join('\n');
  const chunks = swiftTopLevelChunks(src);
  const text = (c) => src.split('\n').slice(c.start, c.end + 1).join('\n');
  assert.equal(chunks.length, 5);
  assert.equal(text(chunks[0]), 'import Foundation');
  assert.ok(text(chunks[1]).startsWith('/// A model.\n@MainActor\nfinal class Model {') && text(chunks[1]).endsWith('}'));
  assert.equal(text(chunks[2]), '#if os(macOS)\nlet onlyMac = 1\n#endif');
  assert.ok(text(chunks[3]).startsWith('extension Model {'));
  assert.equal(text(chunks[4]), 'let table: [String: Int] = [\n  "a": 1,\n]');
});

test('swift: only the rejected declarations are isolated; the rest of the file is byte-for-byte', () => {
  const src = ['import Foundation', '', 'struct Keep { let a = 1 }', '', '// the view', 'struct Screen: View {', '  var body: some View { Text("x") }', '}', '', 'func alsoKeep() {}', ''].join('\n');
  const next = isolateSwiftDeclarations(src, [7, 6]);
  assert.equal(next, ['import Foundation', '', 'struct Keep { let a = 1 }', '', ISOLATE_OPEN, '// the view', 'struct Screen: View {', '  var body: some View { Text("x") }', '}', ISOLATE_CLOSE, '', 'func alsoKeep() {}', ''].join('\n'));
  assert.equal(isolatedLoc(next), 4);
  assert.equal(next.split('\n').filter((l) => l !== ISOLATE_OPEN && l !== ISOLATE_CLOSE).join('\n'), src, 'removing the markers gives back the original');
  assert.equal(isolateSwiftDeclarations(src, [2]), null, 'an error outside every declaration means the whole file');
  const whole = isolateSwiftSource(next);
  assert.ok(whole.startsWith(`${ISOLATE_OPEN}\nimport Foundation`) && whole.trimEnd().endsWith(ISOLATE_CLOSE));
  assert.equal(whole.split('\n').filter((l) => l === ISOLATE_OPEN).length, 1, 'declaration markers are folded into the whole-file one');
  assert.equal(isolateSwiftSource(whole), whole);
});

test('python: exact macOS call shapes become portable helper calls; docstrings and comments are left alone', () => {
  const src = ['"""Stores under ~/Library/Application Support/Demo."""', 'from __future__ import annotations', 'import os, subprocess', 'import fcntl', '',
    '# os.path.expanduser("~/Library/Application Support/Demo") in a comment', 'def home():', '    return os.path.expanduser("~/Library/Application Support/Demo/db")', '',
    'def show(u, lock):', '    subprocess.run(["open", u])', '    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)', ''].join('\n');
  const r = convertPythonSource(src);
  assert.ok(r.text.includes('return circuit_port.app_support("Demo/db")'));
  assert.ok(r.text.includes('circuit_port.open_path(u)'));
  assert.ok(r.text.includes('fcntl = circuit_port.fcntl_compat'));
  assert.ok(r.text.includes('# os.path.expanduser("~/Library/Application Support/Demo") in a comment'));
  assert.ok(r.text.startsWith('"""Stores under ~/Library/Application Support/Demo."""\nfrom __future__ import annotations\ntry:\n    from . import circuit_port\nexcept ImportError:\n    import circuit_port\n'));
  assert.deepEqual(r.helpers.sort(), ['app_support', 'fcntl_compat', 'open_path']);
  const other = convertPythonSource('import fcntl\nfcntl.ioctl(0, 1)\n');
  assert.equal(other.changed, false, 'fcntl is only converted when every use is flock');
  const flags = convertPythonSource('import subprocess\nsubprocess.run(["open", "-a", "Safari", u])\n');
  assert.equal(flags.changed, false, '`open -a App` has no portable meaning and is not rewritten');
});

test('the python helper really runs: paths per OS and flock through the compat object', () => {
  const kit = path.join(ROOT, 'lib', 'convert-kit');
  const code = 'import sys; sys.path.insert(0, sys.argv[1]); import circuit_port as c, tempfile\n'
    + 'assert c.app_support("Demo").endswith("Demo")\n'
    + 'f = tempfile.TemporaryFile(); c.fcntl_compat.flock(f, c.fcntl_compat.LOCK_EX | c.fcntl_compat.LOCK_NB); c.fcntl_compat.flock(f, c.fcntl_compat.LOCK_UN); print("ok")\n';
  const py = spawnSync('python3', ['-c', code, kit], { encoding: 'utf8' });
  if (py.error) return; // no python on this host: nothing to run
  assert.equal(py.status, 0, py.stderr);
  assert.equal(py.stdout.trim(), 'ok');
});

test('javascript: ESM home-Library joins become circuitPort calls; CommonJS is reported, not half-converted', () => {
  const esm = "import os from 'node:os';\nimport path from 'node:path';\nexport const dir = path.join(os.homedir(), 'Library', 'Application Support', 'Demo', 'x');\n";
  const r = convertJsSource(esm, 'app/paths.mjs');
  assert.ok(r.text.includes("export const dir = circuitPort.appSupport('Demo', 'x');"));
  assert.ok(r.text.includes("import * as circuitPort from './circuit-port.mjs';"));
  const cjs = "const os = require('os');\nconst path = require('path');\nmodule.exports = path.join(os.homedir(), 'Library', 'Application Support', 'Demo');\n";
  assert.equal(convertJsSource(cjs, 'app/paths.js').changed, false);
});

test('xcodegen: the macOS application target names the module sources', () => {
  const dir = fixture({
    'project.yml': ['name: Demo', 'targets:', '  DemoiOS:', '    type: application', '    platform: iOS', '    sources:', '      - path: ios', '  Demo:', '    type: application', '    platform: macOS',
      '    sources:', '      - path: Sources', '        excludes: [ "Info.plist" ]', '      - path: Shared/Kit.swift', '      - path: missing', '    settings:', '      base:', '        X: y', ''].join('\n'),
    'Sources/A.swift': 'struct A {}\n', 'Shared/Kit.swift': 'struct K {}\n', 'ios/B.swift': 'struct B {}\n',
  });
  assert.deepEqual(xcodegenSources(dir), { target: 'Demo', sources: ['Sources', 'Shared/Kit.swift'] });
  assert.equal(xcodegenSources(fixture({ 'a.txt': 'x' })), null);
});

test('swift settings are read from the Xcode project so the package is judged by the same rules', () => {
  const dir = fixture({ 'App.xcodeproj/project.pbxproj': 'SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;\nSWIFT_APPROACHABLE_CONCURRENCY = YES;\n', 'Sources/A.swift': 'import Combine\nstruct A {}\n' });
  assert.deepEqual(detectSwiftSettings(dir), { defaultIsolationMainActor: true, approachableConcurrency: true, memberImportVisibility: false });
  const out = outDir();
  convertRepo(dir, { out });
  const manifest = fs.readFileSync(path.join(out, 'Package.swift'), 'utf8');
  assert.ok(manifest.startsWith('// swift-tools-version: 6.2'));
  assert.ok(manifest.includes('.defaultIsolation(MainActor.self)') && manifest.includes('.swiftLanguageMode(.v5)'));
});

const APP = {
  'Sources/Model.swift': 'import Foundation\nimport os\n\nstruct Model: Codable { var name: String }\n\nlet log = Logger(subsystem: "demo", category: "model")\n\nfunc describe(_ m: Model) -> String {\n    log.info("describe \\(m.name, privacy: .public)")\n    return m.name.uppercased()\n}\n',
  'Sources/Plain.swift': 'import Foundation\n\nfunc double(_ x: Int) -> Int { x * 2 }\n',
  'Sources/Screen.swift': 'import SwiftUI\n\nfunc title(_ m: Model) -> String { describe(m) }\n\nstruct Screen: View {\n    let model: Model\n    var body: some View { Text(title(model)) }\n}\n',
  'Sources/UsesScreen.swift': 'import Foundation\n\nfunc makeScreen(_ m: Model) -> Any { Screen(model: m) }\n',
  'ios/Phone.swift': 'import UIKit\nfinal class Phone: UIViewController {}\n',
  'engine/paths.py': 'import os\n\ndef home():\n    return os.path.expanduser("~/Library/Application Support/Demo")\n',
  'Tests/ModelTests.swift': 'import XCTest\nfinal class ModelTests: XCTestCase {}\n',
};

test('convert writes a buildable package outside the repo, never touches the source, and refuses to claim unverified work', () => {
  const dir = fixture(APP);
  const snapshot = Object.fromEntries(Object.keys(APP).map((rel) => [rel, fs.readFileSync(path.join(dir, rel), 'utf8')]));
  assert.throws(() => convertRepo(dir, { out: path.join(dir, 'out') }), /outside the source repo/);
  assert.throws(() => convertRepo(dir, {}), /output folder/);
  assert.throws(() => convertRepo(dir, { out: outDir(), target: 'plan9' }), /Unsupported convert target/);

  const out = outDir();
  const r = convertRepo(dir, { out });
  for (const [rel, body] of Object.entries(snapshot)) assert.equal(fs.readFileSync(path.join(dir, rel), 'utf8'), body, `${rel} untouched`);
  assert.equal(r.verification.ran, false);
  assert.equal(r.totals.buildsLoc, 0, 'nothing is counted as building until a compiler says so');
  assert.match(formatConvertReport(r), /NOT verified/);
  const manifest = fs.readFileSync(path.join(out, 'Package.swift'), 'utf8');
  assert.ok(manifest.includes('"Sources/Model.swift"') && manifest.includes('"Sources/Screen.swift"'));
  assert.ok(!manifest.includes('Phone.swift') && !manifest.includes('ModelTests.swift'), 'the iOS target and the tests stay out of the desktop module');
  assert.ok(r.skipped.some((s) => s.id === 'ios/Phone.swift'));
  assert.ok(fs.existsSync(path.join(out, 'kit', 'CircuitPortKit', 'Logging.swift')));
  assert.ok(fs.existsSync(path.join(out, '.github', 'workflows', 'circuit-windows-build.yml')));
  assert.ok(fs.readFileSync(path.join(out, 'app', 'engine', 'paths.py'), 'utf8').includes('circuit_port.app_support("Demo")'));
  assert.ok(fs.existsSync(path.join(out, 'app', 'engine', 'circuit_port.py')));
  const py = r.files.find((f) => f.id === 'engine/paths.py');
  assert.equal(py.status, 'converted');
  // the port check agrees with what Convert claims about the python file
  const after = portCheck(path.join(out, 'app'));
  assert.equal(after.files.find((f) => f.id === 'engine/paths.py').status, 'ready');
  assert.ok(fs.existsSync(path.join(out, 'conversion.json')) && fs.existsSync(path.join(out, 'CONVERSION.md')));
});

test('convert --verify: the compiler decides — logic builds, the SwiftUI view and what depends on it are isolated', { timeout: 600_000 }, (t) => {
  const swift = spawnSync('swift', ['--version'], { encoding: 'utf8' });
  if (swift.error || swift.status !== 0) { t.skip('no swift toolchain on this host'); return; }
  const dir = fixture(APP);
  const out = outDir();
  const r = convertRepo(dir, { out, verify: true });
  assert.equal(r.verification.ok, true, r.verification.failure ?? '');
  const by = Object.fromEntries(r.files.map((f) => [f.id, f]));
  assert.equal(by['Sources/Plain.swift'].status, 'portable');
  assert.equal(by['Sources/Model.swift'].status, 'converted', 'os.Logger → CircuitPortKit Logger compiles');
  assert.equal(by['Sources/Screen.swift'].status, 'partial', 'the view is isolated, the plain function beside it builds');
  assert.ok(by['Sources/Screen.swift'].isolatedLoc > 0 && by['Sources/Screen.swift'].isolatedLoc < by['Sources/Screen.swift'].loc);
  assert.ok(by['Sources/UsesScreen.swift'].isolatedLoc > 0 && by['Sources/UsesScreen.swift'].isolatedInPass >= 1, 'code that needs the isolated view is isolated in a later pass');
  assert.match(fs.readFileSync(path.join(out, 'app', 'Sources', 'UsesScreen.swift'), 'utf8'), new RegExp(`${ISOLATE_OPEN.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\nfunc makeScreen`));
  assert.ok(r.verification.passes.length >= 3);
  assert.ok(r.totals.buildsLoc > 0 && r.totals.buildsLoc < r.totals.all.loc);
  assert.ok(r.windowsPartsNeeded.some((p) => p.id === 'SwiftUI'));
  const screen = fs.readFileSync(path.join(out, 'app', 'Sources', 'Screen.swift'), 'utf8');
  assert.ok(screen.includes(ISOLATE_OPEN) && screen.includes('func title(_ m: Model) -> String { describe(m) }'));
  // the converted package builds again from cold with no further changes
  const again = spawnSync('swift', ['build', '--package-path', out, '-Xswiftc', `-D${SIM_FLAG}`], { encoding: 'utf8' });
  assert.equal(again.status, 0, again.stderr);
});

// ---- CLI + HTTP API ----
test('cli: --convert needs --out, prints the report and writes the JSON', () => {
  const dir = fixture(APP);
  const bad = spawnSync(process.execPath, ['server.js', '--convert', dir], { cwd: ROOT, encoding: 'utf8' });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--out <dir>/);
  const out = outDir();
  const json = path.join(out, 'report.json');
  const ok = spawnSync(process.execPath, ['server.js', '--convert', dir, '--out', out, '--json', json], { cwd: ROOT, encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /Convert for windows/);
  assert.match(ok.stdout, /NOT verified/);
  assert.equal(JSON.parse(fs.readFileSync(json, 'utf8')).moduleName.endsWith('Core'), true);
});

// A dedicated port: never the hands-off live port, never one another test file uses.
const CONVERT_API_PORT = 8961;

test('api: POST /api/convert runs the conversion out of process and GET reports the result', { timeout: 60_000 }, async (t) => {
  const { spawn } = await import('node:child_process');
  const dir = fixture(APP);
  const base = outDir();
  const child = spawn(process.execPath, ['server.js', dir, '--port', String(CONVERT_API_PORT)], {
    cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, CIRCUIT_CONVERT_DIR: base },
  });
  t.after(() => child.kill('SIGTERM'));
  const url = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error(`server did not start: ${buf}`)), 15_000);
    child.stdout.on('data', (d) => {
      buf += d;
      const m = buf.match(/http:\/\/localhost:(\d+)/);
      if (m) { clearTimeout(timer); resolve(`http://localhost:${m[1]}`); }
    });
  });
  const idle = await (await fetch(`${url}/api/convert`)).json();
  assert.equal(idle.running, false);
  assert.equal(idle.result, null);
  const started = await fetch(`${url}/api/convert?verify=0`, { method: 'POST' });
  assert.equal(started.status, 202);
  const body = await started.json();
  assert.ok(body.out.startsWith(base), 'the converted copy goes under the output root, not into the repo');
  let state;
  for (let i = 0; i < 200; i++) {
    state = await (await fetch(`${url}/api/convert`)).json();
    if (!state.running) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(state.running, false);
  assert.equal(state.error, null);
  assert.equal(state.result.verification.ran, false);
  assert.ok(state.result.files.some((f) => f.id === 'Sources/Model.swift' && f.status === 'rewritten-unverified'));
  assert.ok(fs.existsSync(path.join(body.out, 'Package.swift')));
  assert.ok(state.log.some((l) => /NOT verified/.test(l)));
  // the report the panel's "View report" button reads
  const report = await fetch(`${url}/api/convert/report`);
  assert.equal(report.status, 200);
  assert.match(await report.text(), /converted for windows by Circuit/);
  // "Open output folder" only ever opens Convert's own folder: a GET is not an open,
  // and the request cannot name a path
  assert.equal((await fetch(`${url}/api/convert/open?dir=/etc`)).status, 404, 'GET falls through to static, which has no such file');
});

test('api: a failed conversion reaches the page as a fixed message and an id, never the child\'s error text', { timeout: 60_000 }, async (t) => {
  // The output root is inside the repo, so the convert child refuses and prints its error,
  // which quotes the repo's path, to its stderr.
  const { spawn } = await import('node:child_process');
  const dir = fixture(APP);
  const child = spawn(process.execPath, ['server.js', dir, '--port', '8965'], {
    cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, CIRCUIT_CONVERT_DIR: path.join(dir, 'inside-the-repo') },
  });
  t.after(() => child.kill('SIGTERM'));
  let serverLog = '';
  child.stderr.on('data', (d) => { serverLog += d; });
  const url = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error(`server did not start: ${buf}`)), 15_000);
    child.stdout.on('data', (d) => {
      buf += d;
      const m = buf.match(/http:\/\/localhost:(\d+)/);
      if (m) { clearTimeout(timer); resolve(`http://localhost:${m[1]}`); }
    });
  });
  assert.equal((await fetch(`${url}/api/convert?verify=0`, { method: 'POST' })).status, 202);
  let state;
  for (let i = 0; i < 200; i++) {
    state = await (await fetch(`${url}/api/convert`)).json();
    if (!state.running) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(state.error, 'conversion failed — see the Circuit server log for details');
  assert.match(state.errorId, /^[0-9a-f-]{36}$/);
  // `out` is the folder the server chose and shows on purpose; the error and the streamed log
  // must not carry the child's exception text (it quotes the repo path).
  const told = JSON.stringify({ error: state.error, log: state.log });
  assert.ok(!/outside the source repo/.test(told) && !told.includes(dir), 'no exception text and no repo path in what the page is told');
  assert.ok(serverLog.includes(state.errorId) && /outside the source repo/.test(serverLog), 'the cause is in the server log under the id');
});

test('ui: the Convert button and the output button are in the page and wired', () => {
  const html = fs.readFileSync(path.join(ROOT, 'public', 'index.html'), 'utf8');
  const js = fs.readFileSync(path.join(ROOT, 'public', 'app.js'), 'utf8');
  for (const id of ['convertOpenBtn', 'convertRun', 'convertOpenOut', 'convertReport', 'convertShow', 'convertModal']) {
    assert.ok(html.includes(`id="${id}"`), `${id} is in index.html`);
    assert.ok(js.includes(`$('${id}')`), `${id} is wired in app.js`);
  }
  assert.ok(js.includes("fetch('/api/convert/open', { method: 'POST' })"), 'the output button asks the server to open the folder');
  const server = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
  assert.ok(/convert\/open' && req\.method === 'POST'/.test(server), 'opening is POST-only');
  assert.ok(!/convert\/open[\s\S]{0,400}searchParams/.test(server), 'the folder to open never comes from the request');
});

test('a server started by the app shell leaves when the shell goes away (no orphan holding the port)', { timeout: 30_000 }, async () => {
  const { spawn } = await import('node:child_process');
  const dir = fixture(APP);
  const child = spawn(process.execPath, ['server.js', dir, '--port', '8963'], {
    cwd: ROOT, stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, CIRCUIT_PARENT_WATCH: '1' },
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start')), 15_000);
    child.stdout.on('data', (d) => { if (/http:\/\/localhost:\d+/.test(String(d))) { clearTimeout(timer); resolve(); } });
  });
  const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
  child.stdin.end(); // what the OS does to the pipe when the parent process dies
  assert.equal(await exited, 0);
});

test('kit: anything that extends URLSession imports FoundationNetworking (found by the real Windows compiler)', () => {
  // On Windows/Linux `URLSession` in Foundation is an unavailable placeholder; the class lives in
  // FoundationNetworking. Native run 35367555545 rejected the kit for exactly this.
  const dir = path.join(ROOT, 'lib', 'convert-kit', 'CircuitPortKit');
  for (const name of fs.readdirSync(dir)) {
    const text = fs.readFileSync(path.join(dir, name), 'utf8');
    if (/extension\s+URLSession\b/.test(text)) {
      assert.match(text, /#if canImport\(FoundationNetworking\)\nimport FoundationNetworking\n#endif/, `${name} extends URLSession`);
    }
  }
});

test('line counts are the same whether a converted package comes back with LF or CRLF endings', async () => {
  const { recountConverted } = await import('../lib/convert.js');
  const out = outDir();
  fs.mkdirSync(path.join(out, 'app', 'Sources'), { recursive: true });
  const body = ['import Foundation', '', 'struct Keep {}', '', ISOLATE_OPEN, 'struct Screen: View {', '  var body: some View { Text("x") }', '}', ISOLATE_CLOSE, ''].join('\n');
  const record = { id: 'Sources/A.swift', lang: 'swift', loc: 5, rewritten: true, changes: [], guardedModules: ['SwiftUI'], isolated: true };
  const report = { name: 'demo', target: 'windows', root: '/x', out, generatedAt: Date.now(), windowsPartsNeeded: [], verification: { ran: true, ok: true, passes: [{ pass: 1 }], configuration: 'native Windows build' }, before: { readyPct: 0 }, packages: [], kit: false, skipped: [], files: [record] };
  const counts = {};
  for (const [label, text] of [['lf', body], ['crlf', body.replace(/\n/g, '\r\n')]]) {
    fs.writeFileSync(path.join(out, 'app', 'Sources', 'A.swift'), text);
    fs.writeFileSync(path.join(out, 'conversion.json'), JSON.stringify(report));
    const r = recountConverted(out);
    counts[label] = [r.files[0].isolatedLoc, r.files[0].status, r.totals.buildsLoc];
  }
  assert.deepEqual(counts.lf, [3, 'partial', 2]);
  assert.deepEqual(counts.crlf, counts.lf, 'a CRLF checkout (Windows runners) must not shrink the isolated count');
});
