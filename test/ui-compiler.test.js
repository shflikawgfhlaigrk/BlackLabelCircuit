import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileSwiftUIProject, extractSwiftUI, generateWinUI } from '../lib/ui-compiler.js';
import { convertRepo, formatConvertMarkdown, formatConvertReport } from '../lib/convert.js';

const temp = (prefix) => fs.mkdtempSync(path.join(os.tmpdir(), prefix));

const SOURCE = `import SwiftUI

struct SettingsView: View {
    @State private var name: String = ""
    @State private var enabled = true

    var body: some View {
        NavigationStack {
            VStack {
                Text("Settings")
                    .accessibilityLabel("Settings heading")
                HStack {
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $enabled)
                }
                Button("Save") { save() }
                    .keyboardShortcut("s")
            }
        }
        .navigationTitle("Preferences")
    }
}
`;

test('extracts nested layouts, controls, state, bindings, commands, accessibility, and navigation', () => {
  const ir = extractSwiftUI(SOURCE, { file: 'Sources/SettingsView.swift' });
  assert.equal(ir.views.length, 1);
  assert.deepEqual(ir.views[0].states.map((s) => [s.wrapper, s.name]), [['State', 'name'], ['State', 'enabled']]);
  assert.equal(ir.coverage.totalNodes, 7);
  assert.equal(ir.coverage.supportedNodes, 7);
  assert.deepEqual(ir.residuals, []);
  const [artifact] = generateWinUI(ir);
  assert.match(artifact.xaml, /NavigationView/);
  assert.match(artifact.xaml, /TextBox Header="Name" Text="\{x:Bind ViewModel.Name, Mode=TwoWay\}"/);
  assert.match(artifact.xaml, /AutomationProperties.Name="Settings heading"/);
  assert.match(artifact.xaml, /Text="Preferences"/);
  assert.match(artifact.xaml, /SaveCommand/);
  assert.match(artifact.xaml, /AccessKey="s"/);
  assert.match(artifact.csharp, /public string Name/);
  assert.match(artifact.csharp, /public bool Enabled/);
});

test('unsupported controls and modifiers remain explicit residuals', () => {
  const ir = extractSwiftUI('struct V: View { var body: some View { Map().blur(radius: 2) } }', { file: 'V.swift' });
  assert.deepEqual(ir.residuals.map((r) => r.kind), ['unsupported-control', 'unsupported-modifier']);
  assert.match(generateWinUI(ir)[0].xaml, /CIRCUIT RESIDUAL: unsupported SwiftUI control Map/);
});

test('project output is deterministic and carries a truthful verification boundary', () => {
  const one = temp('circuit-ui-one-');
  const two = temp('circuit-ui-two-');
  const files = [{ file: 'Sources/SettingsView.swift', source: SOURCE }];
  const a = compileSwiftUIProject(files, one);
  const b = compileSwiftUIProject(files, two);
  assert.deepEqual(a, b);
  assert.equal(a.verification.realWindows, false);
  for (const rel of ['Views/SettingsViewPage.xaml', 'ViewModels/SettingsViewViewModel.cs', 'circuit-ui-manifest.json']) {
    assert.equal(fs.readFileSync(path.join(one, rel), 'utf8'), fs.readFileSync(path.join(two, rel), 'utf8'));
  }
});

test('convertRepo writes WinUI workspace, manifest, coverage, residuals, and honest reports', () => {
  const source = temp('circuit-ui-source-');
  fs.mkdirSync(path.join(source, 'Sources'), { recursive: true });
  fs.writeFileSync(path.join(source, 'Sources', 'SettingsView.swift'), SOURCE);
  const out = temp('circuit-ui-convert-');
  const result = convertRepo(source, { out });
  assert.equal(result.ui.views.length, 1);
  assert.equal(result.ui.verification.realWindows, false);
  assert.ok(fs.existsSync(path.join(out, 'winui', 'Views', 'SettingsViewPage.xaml')));
  assert.ok(fs.existsSync(path.join(out, 'winui', 'ViewModels', 'SettingsViewViewModel.cs')));
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(out, 'winui', 'circuit-ui-manifest.json'), 'utf8')), result.ui);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(out, 'conversion.json'), 'utf8')).ui, result.ui);
  assert.match(formatConvertReport(result), /NOT real-Windows compiled, installed, launched, or parity verified/);
  assert.match(formatConvertMarkdown(result), /not a real-Windows compile, install, launch, accessibility, packaging, or feature-parity verification/i);
});
