// Mac-first conversion intake and durable session state.
//
// The selected source tree is read-only. Circuit stores session records under the
// conversion output root, never in the app being converted. Target/profile/output
// identity is immutable after creation; only bounded runtime status may change.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto, { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const SESSION_SCHEMA = 'circuit.conversion-session.v1';
export const INTAKE_SCHEMA = 'circuit.conversion-intake.v1';

export const TARGET_PROFILES = {
  winui3: { id: 'winui3', targetPlatform: 'windows', label: 'Native Windows (WinUI 3)', description: 'Generate a Windows-native UI and Windows App SDK lifecycle.' },
  'tauri2-webview2': { id: 'tauri2-webview2', targetPlatform: 'windows', label: 'Tauri + WebView2', description: 'Reuse an existing web UI with a small native desktop shell.' },
  electron: { id: 'electron', targetPlatform: 'windows', label: 'Electron for Windows', description: 'Keep the Electron UI and port native modules.' },
  'flutter-windows': { id: 'flutter-windows', targetPlatform: 'windows', label: 'Flutter Windows', description: 'Keep the Dart UI and replace macOS-only plugins.' },
  'qt6-windows': { id: 'qt6-windows', targetPlatform: 'windows', label: 'Qt 6 for Windows', description: 'Keep the Qt UI and generate Windows platform adapters.' },
  'native-cli': { id: 'native-cli', targetPlatform: 'windows', label: 'Native Windows executable', description: 'Build a Windows command-line or background executable without a rich UI.' },
  swiftui: { id: 'swiftui', targetPlatform: 'macos', label: 'Native Mac (SwiftUI)', description: 'Generate a native SwiftUI application and macOS lifecycle.' },
  appkit: { id: 'appkit', targetPlatform: 'macos', label: 'Native Mac (AppKit)', description: 'Generate an AppKit application for desktop-specific behavior.' },
  'tauri2-wkwebview': { id: 'tauri2-wkwebview', targetPlatform: 'macos', label: 'Tauri + WKWebView', description: 'Reuse an existing web UI with a small native Mac shell.' },
  'electron-macos': { id: 'electron-macos', targetPlatform: 'macos', label: 'Electron for Mac', description: 'Keep the Electron UI and port Windows-native modules.' },
  'native-cli-macos': { id: 'native-cli-macos', targetPlatform: 'macos', label: 'Native Mac executable', description: 'Build a macOS command-line or background executable.' },
};

export function profilesForPlatform(targetPlatform) {
  if (!['macos', 'windows'].includes(targetPlatform)) throw new Error('target platform must be macos or windows');
  return Object.values(TARGET_PROFILES).filter((profile) => profile.targetPlatform === targetPlatform);
}

const IGNORE_DIRS = new Set(['.git', '.build', 'build', 'DerivedData', 'node_modules', 'Pods', 'dist', 'vendor']);
const MUTABLE_SESSION_FIELDS = new Set(['status', 'progress', 'result', 'error', 'errorId', 'startedAt', 'finishedAt', 'updatedAt', 'remoteJob']);

function readText(file, limit = 2 * 1024 * 1024) {
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size > limit) return '';
  return fs.readFileSync(file, 'utf8');
}

function hashFileSync(file) {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.allocUnsafe(1024 * 1024);
  try {
    let read;
    while ((read = fs.readSync(fd, buf, 0, buf.length, null)) > 0) hash.update(buf.subarray(0, read));
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}

function safeSegment(value, fallback = 'app') {
  const out = String(value ?? '').normalize('NFKD').replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80);
  return out || fallback;
}

function canonicalPath(value) {
  const tail = [];
  let cursor = path.resolve(value);
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    tail.unshift(path.basename(cursor));
    cursor = parent;
  }
  const base = fs.existsSync(cursor) ? fs.realpathSync(cursor) : cursor;
  return path.join(base, ...tail);
}

function walkDescriptors(root, maxDepth = 3) {
  const found = [];
  function visit(dir, depth) {
    if (depth > maxDepth) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory() && IGNORE_DIRS.has(entry.name)) continue;
      const abs = path.join(dir, entry.name);
      const rel = path.relative(root, abs).split(path.sep).join('/');
      if (entry.isDirectory()) {
        if (entry.name.endsWith('.xcodeproj')) {
          const pbx = path.join(abs, 'project.pbxproj');
          if (fs.existsSync(pbx)) found.push({ kind: 'xcodeproj', rel, file: pbx });
          continue;
        }
        if (!entry.name.endsWith('.xcworkspace')) visit(abs, depth + 1);
      } else if (['project.yml', 'Package.swift', 'package.json', 'pubspec.yaml', 'CMakeLists.txt'].includes(entry.name)) {
        found.push({ kind: entry.name, rel, file: abs });
      }
    }
  }
  visit(root, 0);
  return found.sort((a, b) => a.rel.localeCompare(b.rel));
}

function target(kind, name, descriptor, profiles, recommendedProfile, detail = '', sources = null) {
  const id = `${safeSegment(name, 'target')}-${crypto.createHash('sha256').update(`${kind}:${name}:${descriptor}`).digest('hex').slice(0, 8)}`;
  return { id, kind, name, descriptor, detail, profiles, recommendedProfile, sources };
}

function xcodegenTargets(text, descriptor) {
  const lines = text.split(/\r?\n/);
  const records = [];
  let inTargets = false, current = null, inSources = false;
  for (const line of lines) {
    if (/^targets:\s*$/.test(line)) { inTargets = true; continue; }
    if (inTargets && /^\S/.test(line)) { inTargets = false; current = null; inSources = false; }
    if (!inTargets) continue;
    const name = line.match(/^ {2}([^ :#][^:]*):\s*$/);
    if (name) { current = { name: name[1].trim(), type: '', platform: '', sources: [] }; records.push(current); inSources = false; continue; }
    if (!current) continue;
    const type = line.match(/^\s{4,}type:\s*([^#]+?)(?:\s+#.*)?$/);
    const platform = line.match(/^\s{4,}platform:\s*([^#]+?)(?:\s+#.*)?$/);
    if (type) current.type = type[1].trim();
    if (platform) current.platform = platform[1].trim();
    if (/^\s{4,}sources:\s*$/.test(line)) { inSources = true; continue; }
    if (inSources) {
      const source = line.match(/^\s{6,}-\s*(?:path:\s*)?([^#]+?)(?:\s+#.*)?$/);
      if (source) current.sources.push(source[1].trim().replace(/^['"]|['"]$/g, ''));
      else if (/^\s{4}\S/.test(line)) inSources = false;
    }
  }
  return records.filter((r) => /application/i.test(r.type) && /macos/i.test(r.platform))
    .map((r) => target('swiftui-appkit', r.name, descriptor, ['winui3', 'tauri2-webview2'], 'winui3', 'XcodeGen macOS application', r.sources));
}

function xcodeTargets(text, descriptor) {
  const out = [];
  const block = /[A-F0-9]{12,}\s+\/\*\s*([^*]+?)\s*\*\/\s*=\s*\{([\s\S]*?)\n\s*\};/g;
  let match;
  while ((match = block.exec(text))) {
    if (!/isa\s*=\s*PBXNativeTarget\s*;/.test(match[2])) continue;
    if (!/productType\s*=\s*"?com\.apple\.product-type\.application"?\s*;/.test(match[2])) continue;
    const explicit = match[2].match(/\bname\s*=\s*"?([^";]+)"?\s*;/)?.[1]?.trim();
    const name = explicit || match[1].trim();
    out.push(target('swiftui-appkit', name, descriptor, ['winui3', 'tauri2-webview2'], 'winui3', 'Xcode macOS application'));
  }
  return out;
}

function packageTargets(text, descriptor) {
  const out = [];
  for (const match of text.matchAll(/\.executable\s*\(\s*name:\s*"([^"]+)"/g)) {
    out.push(target('swift-cli', match[1], descriptor, ['native-cli'], 'native-cli', 'Swift package executable'));
  }
  return out;
}

function descriptorTargets(descriptor) {
  const text = readText(descriptor.file);
  if (!text) return [];
  if (descriptor.kind === 'project.yml') return xcodegenTargets(text, descriptor.rel);
  if (descriptor.kind === 'xcodeproj') return xcodeTargets(text, descriptor.rel);
  if (descriptor.kind === 'Package.swift') return packageTargets(text, descriptor.rel);
  if (descriptor.kind === 'package.json') {
    try {
      const pkg = JSON.parse(text);
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };
      if (deps.electron || pkg.main) return [target('electron', pkg.productName || pkg.name || 'Electron app', descriptor.rel, ['electron'], 'electron', 'Electron desktop application')];
    } catch { /* invalid package files remain descriptors, not targets */ }
  }
  if (descriptor.kind === 'pubspec.yaml' && /^\s*flutter:\s*$/m.test(text)) {
    const name = text.match(/^name:\s*([^\s#]+)/m)?.[1] || 'Flutter app';
    return [target('flutter', name, descriptor.rel, ['flutter-windows'], 'flutter-windows', 'Flutter desktop application')];
  }
  if (descriptor.kind === 'CMakeLists.txt' && /\b(?:find_package\s*\(\s*Qt6|qt_add_executable\s*\()/i.test(text)) {
    const name = text.match(/qt_add_executable\s*\(\s*([^\s)]+)/i)?.[1] || path.basename(path.dirname(descriptor.file));
    return [target('qt', name, descriptor.rel, ['qt6-windows'], 'qt6-windows', 'Qt desktop application')];
  }
  return [];
}

function dirtyFiles(root) {
  try {
    const changed = execFileSync('git', ['diff', '--name-only', '-z', 'HEAD'], { cwd: root, encoding: 'buffer', maxBuffer: 8 * 1024 * 1024 });
    const untracked = execFileSync('git', ['ls-files', '--others', '--exclude-standard', '-z'], { cwd: root, encoding: 'buffer', maxBuffer: 8 * 1024 * 1024 });
    return [...new Set(Buffer.concat([changed, untracked]).toString('utf8').split('\0').filter(Boolean))].sort();
  } catch { return []; }
}

function nonGitFiles(root) {
  const found = [];
  function visit(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory() && IGNORE_DIRS.has(entry.name)) continue;
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(abs);
      else if (entry.isFile() || entry.isSymbolicLink()) found.push(path.relative(root, abs).split(path.sep).join('/'));
    }
  }
  visit(root);
  return found.sort();
}

export function sourceIdentity(root) {
  const realRoot = fs.realpathSync(root);
  let commit = null;
  try { commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: realRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { /* non-Git input */ }
  const dirty = [];
  const changed = commit ? dirtyFiles(realRoot) : nonGitFiles(realRoot);
  for (const rel of changed) {
    const abs = path.resolve(realRoot, rel);
    if (!(abs === realRoot || abs.startsWith(`${realRoot}${path.sep}`))) continue;
    if (!fs.existsSync(abs)) {
      dirty.push({ path: rel, sha256: null, kind: 'deleted' });
      continue;
    }
    const stat = fs.lstatSync(abs);
    if (stat.isSymbolicLink()) dirty.push({ path: rel, sha256: crypto.createHash('sha256').update(fs.readlinkSync(abs)).digest('hex'), kind: 'symlink' });
    else if (stat.isFile()) dirty.push({ path: rel, sha256: hashFileSync(abs), size: stat.size, kind: 'file' });
  }
  const descriptors = walkDescriptors(realRoot).map((d) => ({ path: d.rel, sha256: hashFileSync(d.file) }));
  const content = JSON.stringify({ root: realRoot, commit, dirty, descriptors });
  return { root: realRoot, commit, dirty, descriptors, sha256: crypto.createHash('sha256').update(content).digest('hex') };
}

export function discoverMacProject(root) {
  const source = sourceIdentity(root);
  const descriptors = walkDescriptors(source.root);
  const seen = new Map();
  for (const descriptor of descriptors) {
    for (const item of descriptorTargets(descriptor)) if (!seen.has(item.id)) seen.set(item.id, item);
  }
  if (!seen.size) {
    const name = path.basename(source.root);
    const fallback = target('unclassified-source', name, '.', ['winui3', 'tauri2-webview2', 'native-cli'], 'winui3', 'No canonical desktop target was declared; confirm the intended product.');
    seen.set(fallback.id, fallback);
  }
  return {
    schema: INTAKE_SCHEMA,
    generatedAt: new Date().toISOString(),
    app: { name: path.basename(source.root), source: source.root },
    source,
    targets: [...seen.values()],
    profiles: TARGET_PROFILES,
  };
}

export function defaultConversionBase(env = process.env) {
  return path.resolve(env.CIRCUIT_CONVERT_DIR || path.join(os.homedir(), 'Circuit Converted'));
}

export function previewConversionOutput({ appName, targetName, profileId, targetPlatform = TARGET_PROFILES[profileId]?.targetPlatform, base = defaultConversionBase() }) {
  if (!TARGET_PROFILES[profileId]) throw new Error('unknown target profile');
  if (TARGET_PROFILES[profileId].targetPlatform !== targetPlatform) throw new Error('target profile does not match target platform');
  return path.join(path.resolve(base), `${safeSegment(appName)}-${safeSegment(targetName)}-${safeSegment(profileId)}-${targetPlatform}`);
}

function statePaths(base) {
  const state = path.join(path.resolve(base), '.circuit');
  return { state, sessions: path.join(state, 'sessions'), current: path.join(state, 'current.json') };
}

function sessionFile(base, id) {
  if (!/^[0-9a-f-]{36}$/.test(id)) throw new Error('invalid conversion session id');
  return path.join(statePaths(base).sessions, `${id}.json`);
}

export function createConversionSession({ root, base = defaultConversionBase(), targetId, profileId, sourcePlatform = 'macos', targetPlatform = 'windows' }) {
  if (!['macos', 'windows'].includes(sourcePlatform) || !['macos', 'windows'].includes(targetPlatform) || sourcePlatform === targetPlatform) throw new Error('conversion direction must be macos to windows or windows to macos');
  const intake = discoverMacProject(root);
  const selected = intake.targets.find((item) => item.id === targetId);
  if (!selected) throw new Error('selected target was not discovered in this Mac project');
  if (!TARGET_PROFILES[profileId] || TARGET_PROFILES[profileId].targetPlatform !== targetPlatform) throw new Error('selected target profile is not valid for the target platform');
  if (targetPlatform === 'windows' && !selected.profiles.includes(profileId)) throw new Error('selected target profile is not valid for this target');
  const realBase = path.resolve(base);
  const output = previewConversionOutput({ appName: intake.app.name, targetName: selected.name, profileId, targetPlatform, base: realBase });
  const canonicalOutput = canonicalPath(output);
  if (canonicalOutput === intake.source.root || canonicalOutput.startsWith(`${intake.source.root}${path.sep}`)) throw new Error('conversion output must be outside the source project');
  const now = new Date().toISOString();
  const session = {
    schema: SESSION_SCHEMA,
    id: randomUUID(),
    createdAt: now,
    updatedAt: now,
    status: 'ready',
    source: intake.source,
    direction: { sourcePlatform, targetPlatform },
    target: selected,
    profile: TARGET_PROFILES[profileId],
    output: { path: output, base: realBase },
    progress: { stage: 'ready', completed: 0, total: 1, message: 'Ready to convert' },
    result: null,
    remoteJob: null,
    error: null,
    errorId: null,
    startedAt: null,
    finishedAt: null,
  };
  atomicJson(sessionFile(realBase, session.id), session);
  atomicJson(statePaths(realBase).current, { schema: SESSION_SCHEMA, id: session.id });
  return session;
}

export function loadConversionSession(base, id) {
  try {
    const value = JSON.parse(fs.readFileSync(sessionFile(base, id), 'utf8'));
    return value?.schema === SESSION_SCHEMA && value.id === id ? value : null;
  } catch { return null; }
}

export function loadCurrentConversionSession(base = defaultConversionBase()) {
  try {
    const pointer = JSON.parse(fs.readFileSync(statePaths(base).current, 'utf8'));
    return pointer?.schema === SESSION_SCHEMA ? loadConversionSession(base, pointer.id) : null;
  } catch { return null; }
}

export function updateConversionSession(base, id, patch) {
  const current = loadConversionSession(base, id);
  if (!current) throw new Error('conversion session does not exist');
  for (const key of Object.keys(patch)) if (!MUTABLE_SESSION_FIELDS.has(key)) throw new Error(`conversion session field is immutable: ${key}`);
  const next = { ...current, ...patch, updatedAt: new Date().toISOString() };
  atomicJson(sessionFile(base, id), next);
  return next;
}
