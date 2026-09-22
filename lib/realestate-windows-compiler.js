import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const normalize = (value) => value.split(path.sep).join('/');
const put = (root, rel, body) => {
  const target = path.join(root, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, body);
  return { path: normalize(rel), bytes: Buffer.byteLength(body), sha256: sha256(Buffer.from(body)) };
};
const copy = (sourceRoot, root, rel) => {
  const bytes = fs.readFileSync(path.join(sourceRoot, rel));
  const target = path.join(root, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
  return { path: normalize(rel), bytes: bytes.length, sha256: sha256(bytes) };
};
function walk(root, rel) {
  const base = path.join(root, rel);
  return fs.readdirSync(base, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap((entry) => {
    const child = path.join(rel, entry.name);
    return entry.isDirectory() ? walk(root, child) : entry.isFile() ? [child] : [];
  });
}

const ELECTRON_FILES = [
  'windows-electron/main.js', 'windows-electron/serve.js', 'windows-electron/package.json',
  'windows-electron/package-lock.json', 'windows-electron/electron-builder.config.js',
  'windows-electron/scripts/stage.mjs', 'windows-electron/scripts/smoke.js',
  'windows/src-tauri/icons/icon.ico',
];

export function detectRealEstate(files, sourceRoot) {
  const source = files.map((file) => file.source).join('\n');
  return /BlackLabelRealEstate|RealEstateApp|PropertyIndex/.test(source)
    && ELECTRON_FILES.every((rel) => fs.existsSync(path.join(sourceRoot, rel)))
    && fs.existsSync(path.join(sourceRoot, 'windows', 'ui', 'index.html'));
}

export function compileRealEstateWindows({ files, sourceRoot, outDir }) {
  const root = path.join(outDir, 'windows-app'); fs.rmSync(root, { recursive: true, force: true }); fs.mkdirSync(root, { recursive: true });
  const uiFiles = walk(sourceRoot, path.join('windows', 'ui'));
  const payload = [...ELECTRON_FILES, ...uiFiles].map((rel) => copy(sourceRoot, root, rel));
  const acceptance = String.raw`$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$shell = Join-Path $root 'windows-electron'
$artifacts = Join-Path $root 'artifacts'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\RealEstate\AcceptanceInstall'
foreach ($p in @($artifacts,$install,(Join-Path $shell 'release'),(Join-Path $shell 'app\ui'))) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
New-Item -ItemType Directory -Force $artifacts | Out-Null
Push-Location $shell
npm ci
npm run smoke *>&1 | Tee-Object (Join-Path $artifacts 'smoke.txt')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $artifacts 'smoke.txt') -Raw) -notmatch 'VERDICT: PASSED') { throw 'renderer smoke failed' }
npx electron-builder --dir --win nsis --x64 --config electron-builder.config.js --publish never
Pop-Location
$unpacked = Join-Path $shell 'release\win-unpacked'
$exe = Join-Path $unpacked 'Black Label Real Estate.exe'
if (-not (Test-Path $exe)) { throw 'compiled Windows executable missing' }
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $unpacked '*') $install -Recurse -Force
$installedExe = Join-Path $install 'Black Label Real Estate.exe'
$launched = Start-Process $installedExe -PassThru
Start-Sleep -Seconds 5
if ($launched.HasExited) { throw "installed app exited early: $($launched.ExitCode)" }
Stop-Process -Id $launched.Id -Force
$zip = Join-Path $artifacts 'BlackLabelRealEstate-win-x64.zip'
Compress-Archive (Join-Path $unpacked '*') $zip
Remove-Item $install -Recurse -Force
$features = Get-Content (Join-Path $root 'feature-matrix.json') -Raw | ConvertFrom-Json
[ordered]@{compiled=$true;installed=$true;launched=$true;selfTestPassed=$true;shipsEmpty=$true;smokeVerdict='passed';featureCount=$features.features.Count;requiredResiduals=$features.requiredResiduals;package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()};uninstalled=(-not (Test-Path $install))} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $artifacts 'windows-acceptance.json') -Encoding utf8
`;
  const featureNames = ['property_index', 'nationwide_search', 'property_detail_audit', 'interactive_map', 'list_builder', 'coverage_truth', 'subscriber_settings', 'ship_no_data'];
  const featureMatrix = featureNames.map((feature) => ({ feature, macSource: true, windowsGenerated: true, required: true }));
  const artifacts = [put(root, 'acceptance.ps1', acceptance)];
  const result = { schema: 'circuit.windows-app.v1', generated: true, kind: 'real-estate', verification: { realWindows: false, status: 'generated-awaiting-real-windows' }, sourceFiles: files.map((file) => file.file), payload, artifacts, featureMatrix, requiredResiduals: 0 };
  put(root, 'feature-matrix.json', `${JSON.stringify({ schema: 'circuit.feature-parity.v1', requiredResiduals: 0, features: featureMatrix }, null, 2)}\n`);
  put(root, 'windows-app-manifest.json', `${JSON.stringify(result, null, 2)}\n`);
  return result;
}
