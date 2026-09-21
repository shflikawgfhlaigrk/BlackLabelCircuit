// Deterministic SwiftUI -> UI IR -> WinUI 3 source compiler.
//
// This is intentionally a compiler stage, not a rewrite rule. Every recognized
// node has a source anchor. Anything outside the supported grammar is retained as
// an explicit residual and therefore cannot silently earn a parity verdict.
import fs from 'node:fs';
import path from 'node:path';

export const UI_IR_SCHEMA = 'circuit.ui-ir.v1';
export const WINUI_SCHEMA = 'circuit.winui-source.v1';

const CONTAINERS = new Set(['VStack', 'HStack', 'ZStack', 'Group', 'Form', 'Section', 'ScrollView', 'NavigationStack', 'NavigationView', 'List', 'LazyVStack', 'LazyHStack']);
const CONTROLS = new Set(['Text', 'Label', 'Button', 'TextField', 'SecureField', 'Toggle', 'Slider', 'ProgressView', 'Image', 'Spacer', 'Divider', 'Link', 'NavigationLink', 'ForEach']);
const SUPPORTED = new Set([...CONTAINERS, ...CONTROLS]);
const SUPPORTED_MODIFIERS = new Set(['padding', 'navigationTitle', 'accessibilityLabel', 'accessibilityHint', 'keyboardShortcut', 'disabled']);

function lineAt(source, offset) { return source.slice(0, offset).split('\n').length; }

function findMatching(text, start, open = '{', close = '}') {
  let depth = 0, quote = null, escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === open) depth++;
    else if (ch === close && --depth === 0) return i;
  }
  return -1;
}

function splitTopLevel(text, delimiter = ',') {
  const out = []; let start = 0, round = 0, square = 0, curly = 0, quote = null, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) { if (escaped) escaped = false; else if (ch === '\\') escaped = true; else if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '(') round++; else if (ch === ')') round--;
    else if (ch === '[') square++; else if (ch === ']') square--;
    else if (ch === '{') curly++; else if (ch === '}') curly--;
    else if (ch === delimiter && round === 0 && square === 0 && curly === 0) { out.push(text.slice(start, i).trim()); start = i + 1; }
  }
  const tail = text.slice(start).trim(); if (tail) out.push(tail); return out;
}

function splitBuilder(text) {
  const out = []; let start = 0, round = 0, square = 0, curly = 0, quote = null, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) { if (escaped) escaped = false; else if (ch === '\\') escaped = true; else if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '(') round++; else if (ch === ')') round--;
    else if (ch === '[') square++; else if (ch === ']') square--;
    else if (ch === '{') curly++; else if (ch === '}') curly--;
    else if ((ch === '\n' || ch === ';') && round === 0 && square === 0 && curly === 0) {
      if (ch === '\n' && /^\s*\./.test(text.slice(i + 1))) continue;
      const value = text.slice(start, i).trim(); if (value) out.push({ value, offset: start }); start = i + 1;
    }
  }
  const value = text.slice(start).trim(); if (value) out.push({ value, offset: start }); return out;
}

function literal(value) {
  const v = String(value ?? '').trim();
  if (/^"(?:[^"\\]|\\.)*"$/.test(v)) return { kind: 'literal', value: v.slice(1, -1).replace(/\\"/g, '"') };
  if (/^(true|false|-?\d+(?:\.\d+)?)$/.test(v)) return { kind: 'literal', value: v };
  return { kind: 'binding', value: v.replace(/^\$/, '') || 'value' };
}

function parseArguments(text) {
  const args = [];
  for (const part of splitTopLevel(text)) {
    const match = part.match(/^([A-Za-z_]\w*)\s*:\s*([\s\S]+)$/);
    args.push(match ? { label: match[1], ...literal(match[2]) } : { label: null, ...literal(part) });
  }
  return args;
}

function peelModifiers(expression) {
  let end = expression.length, start = -1, round = 0, curly = 0, quote = null, escaped = false;
  for (let i = 0; i < expression.length; i++) {
    const ch = expression[i];
    if (quote) { if (escaped) escaped = false; else if (ch === '\\') escaped = true; else if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '(') round++; else if (ch === ')') round--;
    else if (ch === '{') curly++; else if (ch === '}') curly--;
    else if (ch === '.' && round === 0 && curly === 0) { start = i; end = i; break; }
  }
  if (start < 0) return { base: expression.trim(), modifiers: [] };
  const modifiers = []; let cursor = start;
  while (cursor < expression.length) {
    const m = expression.slice(cursor).match(/^\.([A-Za-z_]\w*)\s*/); if (!m) break;
    cursor += m[0].length; let argText = '';
    if (expression[cursor] === '(') { const close = findMatching(expression, cursor, '(', ')'); if (close < 0) break; argText = expression.slice(cursor + 1, close); cursor = close + 1; }
    modifiers.push({ name: m[1], arguments: parseArguments(argText) });
    while (/\s/.test(expression[cursor] ?? '')) cursor++;
  }
  return { base: expression.slice(0, end).trim(), modifiers };
}

function parseNode(expression, source, sourceOffset, residuals) {
  expression = expression.trim().replace(/^return\s+/, '');
  const { base, modifiers } = peelModifiers(expression);
  const nameMatch = base.match(/^([A-Za-z_]\w*)/);
  if (!nameMatch) { residuals.push({ kind: 'unparsed-expression', line: lineAt(source, sourceOffset), source: expression.slice(0, 200) }); return null; }
  const type = nameMatch[1];
  let cursor = nameMatch[0].length, args = [], closure = null;
  while (/\s/.test(base[cursor] ?? '')) cursor++;
  if (base[cursor] === '(') { const close = findMatching(base, cursor, '(', ')'); if (close >= 0) { args = parseArguments(base.slice(cursor + 1, close)); cursor = close + 1; } }
  while (/\s/.test(base[cursor] ?? '')) cursor++;
  if (base[cursor] === '{') { const close = findMatching(base, cursor); if (close >= 0) closure = base.slice(cursor + 1, close).trim(); }
  const node = { type, arguments: args, modifiers, children: [], source: { line: lineAt(source, sourceOffset) }, supported: SUPPORTED.has(type) };
  if (!node.supported) residuals.push({ kind: 'unsupported-control', control: type, line: node.source.line, source: expression.slice(0, 200) });
  for (const mod of modifiers) if (!SUPPORTED_MODIFIERS.has(mod.name)) residuals.push({ kind: 'unsupported-modifier', modifier: mod.name, line: node.source.line });
  if (closure) {
    if (type === 'Button') node.action = closure;
    else {
      const builder = type === 'ForEach' && /\bin\b/.test(closure) ? closure.slice(closure.indexOf(' in ') + 4) : closure;
      for (const part of splitBuilder(builder)) {
        const child = parseNode(part.value, source, sourceOffset + base.indexOf(closure) + part.offset, residuals);
        if (child) node.children.push(child);
      }
    }
  }
  return node;
}

function extractStates(source) {
  const states = [];
  const re = /@(State|Binding|StateObject|ObservedObject|EnvironmentObject)\b(?:\([^)]*\))?\s+(?:private\s+)?var\s+([A-Za-z_]\w*)\s*(?::\s*([^=\n{]+))?(?:\s*=\s*([^\n]+))?/g;
  for (const m of source.matchAll(re)) states.push({ wrapper: m[1], name: m[2], swiftType: m[3]?.trim() ?? null, initialValue: m[4]?.trim() ?? null, source: { line: lineAt(source, m.index) } });
  return states;
}

export function extractSwiftUI(source, { file = 'View.swift' } = {}) {
  const views = [], residuals = [], viewRe = /struct\s+([A-Za-z_]\w*)\s*:\s*(?:[A-Za-z_]\w*\s*&\s*)*View\b/g;
  for (const match of source.matchAll(viewRe)) {
    const structOpen = source.indexOf('{', match.index + match[0].length); if (structOpen < 0) continue;
    const structClose = findMatching(source, structOpen); if (structClose < 0) { residuals.push({ kind: 'unclosed-view', view: match[1], line: lineAt(source, match.index) }); continue; }
    const bodyText = source.slice(structOpen + 1, structClose);
    const bodyMatch = /var\s+body\s*:\s*some\s+View\s*\{/.exec(bodyText);
    if (!bodyMatch) { residuals.push({ kind: 'missing-body', view: match[1], line: lineAt(source, match.index) }); continue; }
    const bodyOpen = structOpen + 1 + bodyMatch.index + bodyMatch[0].lastIndexOf('{');
    const bodyClose = findMatching(source, bodyOpen); if (bodyClose < 0) continue;
    const expression = source.slice(bodyOpen + 1, bodyClose);
    const parts = splitBuilder(expression);
    const root = parts.length === 1 ? parseNode(parts[0].value, source, bodyOpen + 1 + parts[0].offset, residuals)
      : { type: 'VStack', arguments: [], modifiers: [], children: parts.map((part) => parseNode(part.value, source, bodyOpen + 1 + part.offset, residuals)).filter(Boolean), source: { line: lineAt(source, bodyOpen) }, supported: true, synthesized: true };
    views.push({ name: match[1], file, source: { line: lineAt(source, match.index), bodyLine: lineAt(source, bodyOpen) }, states: extractStates(source.slice(structOpen, structClose + 1)), root });
  }
  let totalNodes = 0, supportedNodes = 0;
  const visit = (node) => { if (!node) return; totalNodes++; if (node.supported) supportedNodes++; for (const child of node.children) visit(child); };
  for (const view of views) visit(view.root);
  return { schema: UI_IR_SCHEMA, file, views, residuals, coverage: { totalNodes, supportedNodes, percent: totalNodes ? Math.round(supportedNodes / totalNodes * 1000) / 10 : null } };
}

const xml = (value) => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const pascal = (value) => String(value || 'Action').replace(/[^A-Za-z0-9]+(.)?/g, (_, c) => c ? c.toUpperCase() : '').replace(/^./, (c) => c.toUpperCase());
const binding = (arg) => arg?.kind === 'literal' ? xml(arg.value) : `{x:Bind ViewModel.${pascal(arg?.value)}, Mode=TwoWay}`;

function xamlNode(node, depth, commands) {
  const pad = '  '.repeat(depth), first = node.arguments[0], label = binding(first), mods = Object.fromEntries(node.modifiers.map((m) => [m.name, m.arguments[0]]));
  const accessibility = mods.accessibilityLabel ? ` AutomationProperties.Name="${binding(mods.accessibilityLabel)}"` : '';
  const helpText = mods.accessibilityHint ? ` AutomationProperties.HelpText="${binding(mods.accessibilityHint)}"` : '';
  const accessKey = mods.keyboardShortcut?.kind === 'literal' ? ` AccessKey="${xml(mods.keyboardShortcut.value)}"` : '';
  const disabled = mods.disabled ? ` IsEnabled="${mods.disabled.value === 'true' ? 'False' : 'True'}"` : '';
  const margin = mods.padding ? ' Margin="12"' : '';
  const children = () => node.children.map((child) => xamlNode(child, depth + 1, commands)).join('\n');
  switch (node.type) {
    case 'VStack': case 'LazyVStack': return `${pad}<StackPanel Orientation="Vertical" Spacing="8"${margin}>\n${children()}\n${pad}</StackPanel>`;
    case 'HStack': case 'LazyHStack': return `${pad}<StackPanel Orientation="Horizontal" Spacing="8"${margin}>\n${children()}\n${pad}</StackPanel>`;
    case 'ZStack': case 'Group': return `${pad}<Grid${margin}>\n${children()}\n${pad}</Grid>`;
    case 'Form': case 'Section': return `${pad}<StackPanel Spacing="8"${margin}>\n${node.type === 'Section' && first ? `${pad}  <TextBlock Text="${label}" Style="{StaticResource SubtitleTextBlockStyle}" />\n` : ''}${children()}\n${pad}</StackPanel>`;
    case 'ScrollView': return `${pad}<ScrollViewer${margin}>\n${children()}\n${pad}</ScrollViewer>`;
    case 'NavigationStack': case 'NavigationView': return `${pad}<NavigationView PaneDisplayMode="Left"${margin}>\n${children()}\n${pad}</NavigationView>`;
    case 'List': case 'ForEach': return `${pad}<ListView ItemsSource="${binding(first)}"${accessibility}${helpText}${margin}>${node.children.length ? `\n${children()}\n${pad}` : ''}</ListView>`;
    case 'Text': return `${pad}<TextBlock Text="${label}"${accessibility}${helpText}${margin} />`;
    case 'Label': return `${pad}<TextBlock Text="${label}"${accessibility}${helpText}${margin} />`;
    case 'Button': { const command = `${pascal(first?.value)}Command`; commands.add(command); return `${pad}<Button Content="${label}" Command="{x:Bind ViewModel.${command}}"${accessibility}${helpText}${accessKey}${disabled}${margin} />`; }
    case 'TextField': case 'SecureField': { const value = node.arguments.find((a) => a.label === 'text') ?? node.arguments[1]; const property = node.type === 'SecureField' ? 'Password' : 'Text'; return `${pad}<${node.type === 'SecureField' ? 'PasswordBox' : 'TextBox'} Header="${label}" ${property}="${binding(value)}"${accessibility}${helpText}${disabled}${margin} />`; }
    case 'Toggle': { const value = node.arguments.find((a) => a.label === 'isOn') ?? node.arguments[1]; return `${pad}<ToggleSwitch Header="${label}" IsOn="${binding(value)}"${accessibility}${helpText}${disabled}${margin} />`; }
    case 'Slider': return `${pad}<Slider Value="${binding(first)}"${accessibility}${helpText}${disabled}${margin} />`;
    case 'ProgressView': return `${pad}<ProgressBar Value="${binding(first)}"${accessibility}${helpText}${margin} />`;
    case 'Image': return `${pad}<Image Source="${label}"${accessibility}${helpText}${margin} />`;
    case 'Spacer': return `${pad}<Grid MinHeight="8" MinWidth="8" />`;
    case 'Divider': return `${pad}<Rectangle Height="1" Fill="{ThemeResource DividerStrokeColorDefaultBrush}" />`;
    case 'Link': case 'NavigationLink': return `${pad}<HyperlinkButton Content="${label}"${accessibility}${helpText}${accessKey}${margin} />`;
    default: return `${pad}<!-- CIRCUIT RESIDUAL: unsupported SwiftUI control ${xml(node.type)} at line ${node.source.line} -->`;
  }
}

function csType(state) {
  const swift = state.swiftType ?? '';
  if (/Bool/.test(swift) || /^(true|false)$/.test(state.initialValue ?? '')) return 'bool';
  if (/Double|Float|CGFloat/.test(swift)) return 'double';
  if (/Int/.test(swift) || /^-?\d+$/.test(state.initialValue ?? '')) return 'int';
  return 'string';
}

export function generateWinUI(ir, { namespace = 'CircuitGenerated' } = {}) {
  const artifacts = [];
  for (const view of ir.views) {
    const commands = new Set(); const body = xamlNode(view.root, 3, commands);
    const title = view.root.modifiers.find((m) => m.name === 'navigationTitle')?.arguments[0];
    const xaml = [`<?xml version="1.0" encoding="utf-8"?>`, `<Page x:Class="${namespace}.${view.name}Page"`, `  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"`, `  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"`, `  xmlns:local="using:${namespace}"`, `  Background="{ThemeResource ApplicationPageBackgroundThemeBrush}">`, `  <Grid>`, title ? `    <StackPanel><TextBlock Text="${binding(title)}" Style="{StaticResource TitleTextBlockStyle}" />\n${body}\n    </StackPanel>` : body, `  </Grid>`, `</Page>`, ''].join('\n');
    const properties = view.states.map((s) => `    public ${csType(s)} ${pascal(s.name)} { get; set; }`).join('\n');
    const relay = `${view.name}RelayCommand`;
    const commandRows = [...commands].map((name) => `    public ICommand ${name} { get; } = new ${relay}(() => { });`).join('\n');
    const csharp = [`using System;`, `using System.Windows.Input;`, ``, `namespace ${namespace};`, ``, `public sealed class ${view.name}ViewModel`, `{`, properties || '    // No SwiftUI state properties were declared.', commandRows, `}`, ``, `public sealed class ${relay} : ICommand`, `{`, `    private readonly Action action;`, `    public ${relay}(Action action) => this.action = action;`, `    public bool CanExecute(object? parameter) => true;`, `    public void Execute(object? parameter) => action();`, `    public event EventHandler? CanExecuteChanged;`, `}`, ''].filter((line) => line !== undefined).join('\n');
    artifacts.push({ schema: WINUI_SCHEMA, view: view.name, file: ir.file, xaml, csharp, xamlPath: `Views/${view.name}Page.xaml`, csharpPath: `ViewModels/${view.name}ViewModel.cs`, commands: [...commands] });
  }
  return artifacts;
}

export function compileSwiftUIProject(files, outDir, options = {}) {
  const fileResults = files.map(({ file, source }) => extractSwiftUI(source, { file }));
  const artifacts = fileResults.flatMap((ir) => generateWinUI(ir, options));
  const residuals = fileResults.flatMap((ir) => ir.residuals.map((r) => ({ file: ir.file, ...r })));
  const totalNodes = fileResults.reduce((n, ir) => n + ir.coverage.totalNodes, 0);
  const supportedNodes = fileResults.reduce((n, ir) => n + ir.coverage.supportedNodes, 0);
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  for (const artifact of artifacts) {
    for (const [rel, content] of [[artifact.xamlPath, artifact.xaml], [artifact.csharpPath, artifact.csharp]]) {
      const target = path.join(outDir, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, content);
    }
  }
  const manifest = { schema: WINUI_SCHEMA, verification: { realWindows: false, status: 'source-generated-not-windows-verified' }, views: artifacts.map(({ view, file, xamlPath, csharpPath, commands }) => ({ view, file, xamlPath, csharpPath, commands })), coverage: { totalNodes, supportedNodes, percent: totalNodes ? Math.round(supportedNodes / totalNodes * 1000) / 10 : null }, residuals };
  fs.writeFileSync(path.join(outDir, 'circuit-ui-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}
