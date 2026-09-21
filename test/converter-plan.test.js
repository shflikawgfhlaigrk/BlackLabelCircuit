import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const planPath = path.join(root, 'docs', 'MAC-FIRST-WINDOWS-CONVERTER-PLAN.md');
const contractPath = path.join(root, 'docs', 'mac-first-windows-converter-plan.json');
const plan = fs.readFileSync(planPath, 'utf8');
const contract = JSON.parse(fs.readFileSync(contractPath, 'utf8'));

test('the product is Mac-first and Windows is the conversion target', () => {
  assert.equal(contract.primaryPlatform, 'macos');
  assert.equal(contract.conversionTarget, 'windows');
  assert.match(plan, /Circuit is a Mac-first desktop application/);
  assert.match(plan, /Windows is the conversion target/i);
});

test('source is immutable and binary-only apps are not falsely promised', () => {
  assert.equal(contract.sourceMutation, 'forbidden');
  assert.equal(contract.inputScope, 'source-available-mac-apps');
  assert.match(plan, /never edits the source project in place/);
  assert.match(plan, /binary-only third-party `.app`/);
});

test('the plan covers the full build pipeline and dominant UI gap', () => {
  for (const heading of [
    'Supported input contract', 'Conversion architecture', 'Compatibility packs',
    'UI conversion', 'Compiler-guided conversion loop', 'Windows build and packaging',
    'Mac application workflow', 'Execution phases', 'Verification matrix', 'Terminal verdicts',
  ]) assert.match(plan, new RegExp(`#{2,3}(?: \\d+\\.)? ${heading}`));
  assert.ok(contract.requirements.includes('UI-COMPILER-001'));
  assert.equal(contract.phases[4].name, 'swiftui-appkit-to-winui-compiler');
});

test('every required compatibility family is explicit', () => {
  const required = [
    'ui', 'foundation', 'posix', 'security', 'crypto', 'database', 'logging',
    'types-assets', 'networking', 'ipc-services', 'notifications', 'browser-auth',
    'clipboard-share', 'media', 'devices', 'accessibility', 'updates',
  ];
  assert.deepEqual(contract.compatibilityPacks, required);
});

test('completion belongs to a real Windows run and shortcuts are forbidden', () => {
  assert.equal(contract.completionAuthority, 'real-windows');
  for (const gate of ['compile', 'install', 'launch', 'features', 'accessibility', 'reproduction']) {
    assert.ok(contract.requiredWindowsGates.includes(gate), `missing ${gate}`);
  }
  for (const shortcut of ['mac-simulation-only', 'whole-file-apple-only-isolation', 'silent-feature-omission']) {
    assert.ok(contract.forbiddenSuccessShortcuts.includes(shortcut), `missing ${shortcut}`);
  }
});

test('only complete verdicts are shippable', () => {
  assert.equal(contract.terminalVerdicts.complete.shippable, true);
  assert.equal(contract.terminalVerdicts['complete-with-approved-differences'].shippable, true);
  for (const verdict of ['partial', 'held', 'failed']) {
    assert.equal(contract.terminalVerdicts[verdict].shippable, false);
  }
});

test('phases are ordered and stable', () => {
  assert.deepEqual(contract.phases.map(({ id }) => id), ['P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7']);
});
