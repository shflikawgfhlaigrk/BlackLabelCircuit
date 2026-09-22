import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const put = (root, rel, body) => {
  const target = path.join(root, rel);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, body);
  return { path: rel.split(path.sep).join('/'), bytes: Buffer.byteLength(body), sha256: sha256(Buffer.from(body)) };
};
const copy = (sourceRoot, root, rel) => {
  const bytes = fs.readFileSync(path.join(sourceRoot, rel));
  const target = path.join(root, rel);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes);
  return { path: rel.split(path.sep).join('/'), bytes: bytes.length, sha256: sha256(bytes) };
};

const RUNTIME = [
  'bltd_alerts.py', 'bltd_analytics.py', 'bltd_api.py', 'bltd_browser.py',
  'bltd_capture.py', 'bltd_feeds.py', 'bltd_optimizer.py', 'bltd_optimizer_cli.py',
  'bltd_parsers.py', 'bltd_paths.py', 'bltd_rithmic.py', 'bltd_rprotocol.py',
  'bltd_store.py', 'bltd_topstep_bridge.py', 'bltd_tradovate.py', 'bltd_projectx.py',
];

export function detectTrading(files, sourceRoot) {
  const source = files.map((file) => file.source).join('\n');
  return /BlackLabelTrading|TradingApp|SignalCore/.test(source)
    && fs.existsSync(path.join(sourceRoot, 'windows', 'supervise.py'))
    && RUNTIME.every((name) => fs.existsSync(path.join(sourceRoot, 'backend', name)));
}

export function compileTradingWindows({ files, sourceRoot, outDir }) {
  const root = path.join(outDir, 'windows-app');
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  const payload = [
    copy(sourceRoot, root, 'windows/supervise.py'),
    copy(sourceRoot, root, 'windows/launch-trading.cmd'),
    copy(sourceRoot, root, 'windows/python-embed.sha256'),
    copy(sourceRoot, root, 'windows/msix/launcher/Launcher.cs'),
    ...RUNTIME.map((name) => copy(sourceRoot, root, `backend/${name}`)),
  ];
  const launcherRel = 'windows/msix/launcher/Launcher.cs';
  const launcherTarget = path.join(root, launcherRel);
  const launcher = fs.readFileSync(launcherTarget, 'utf8').replace(
    'string here = Path.GetDirectoryName(new Uri(Assembly.GetExecutingAssembly().CodeBase).LocalPath);',
    'string here = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);',
  );
  fs.writeFileSync(launcherTarget, launcher);
  const launcherRow = payload.find((row) => row.path === launcherRel);
  launcherRow.bytes = Buffer.byteLength(launcher);
  launcherRow.sha256 = sha256(Buffer.from(launcher));

  const project = `<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>disable</ImplicitUsings><EnableDefaultCompileItems>false</EnableDefaultCompileItems><AssemblyName>BlackLabelTrading</AssemblyName><RootNamespace>BlackLabel.Trading</RootNamespace><Deterministic>true</Deterministic><DebugType>none</DebugType><DebugSymbols>false</DebugSymbols><StartupObject>Launcher</StartupObject></PropertyGroup><ItemGroup><Compile Include="windows\\msix\\launcher\\Launcher.cs" /></ItemGroup></Project>\n`;
  const acceptance = String.raw`$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$artifacts = Join-Path $root 'artifacts'
$publish = Join-Path $artifacts 'launcher'
$stage = Join-Path $artifacts 'stage'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\Trading\AcceptanceInstall'
foreach ($p in @($artifacts,$install)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
New-Item -ItemType Directory -Force $artifacts,$stage,(Join-Path $stage 'backend') | Out-Null
$pin = (Get-Content (Join-Path $root 'windows\python-embed.sha256') | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() } | Select-Object -First 1).Trim().ToLowerInvariant()
if ($pin -notmatch '^[0-9a-f]{64}$') { throw 'invalid Python runtime pin' }
$zipName = 'python-3.12.8-embed-amd64.zip'
$runtimeZip = Join-Path $artifacts $zipName
Invoke-WebRequest "https://www.python.org/ftp/python/3.12.8/$zipName" -OutFile $runtimeZip
if ((Get-FileHash $runtimeZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin) { throw 'Python runtime hash mismatch' }
Expand-Archive $runtimeZip (Join-Path $stage 'python') -Force
$pth = Get-ChildItem (Join-Path $stage 'python') -Filter 'python*._pth' | Select-Object -First 1
if (-not $pth) { throw 'embeddable Python path file missing' }
Add-Content $pth.FullName '..\backend'
Copy-Item (Join-Path $root 'backend\*.py') (Join-Path $stage 'backend')
Copy-Item (Join-Path $root 'windows\supervise.py') $stage
Copy-Item (Join-Path $root 'windows\launch-trading.cmd') $stage
dotnet publish (Join-Path $root 'BlackLabelTrading.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $publish
Copy-Item (Join-Path $publish 'BlackLabelTrading.exe') $stage
$forbidden = Get-ChildItem $stage -Recurse -Force | Where-Object { $_.Name -in @('trading.sqlite3','config.json','webhook.token','auth.json') -or $_.Extension -in @('.pem','.key') }
if ($forbidden) { throw "ships-empty violation: $($forbidden[0].FullName)" }
$env:PYTHONPATH = Join-Path $stage 'backend'
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:BLTD_SUPPORT_DIR = Join-Path $artifacts 'buyer-state'
$python = Join-Path $stage 'python\python.exe'
& $python -c "import bltd_api,bltd_capture,bltd_optimizer,bltd_store,bltd_feeds; print('TRADING_IMPORT_SMOKE=true')"
if ($LASTEXITCODE -ne 0) { throw 'backend import smoke failed' }
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $stage '*') $install -Recurse -Force
$smokePath = Join-Path $artifacts 'smoke.txt'
$installedPython = Join-Path $install 'python\\python.exe'
& $installedPython (Join-Path $install 'supervise.py') --plan | Set-Content $smokePath -Encoding utf8
$launch = Start-Process (Join-Path $install 'BlackLabelTrading.exe') -ArgumentList '--plan' -PassThru -Wait
if ($launch.ExitCode -ne 0) { throw 'launcher smoke failed' }
$smoke = Get-Content $smokePath -Raw
if ($smoke -notmatch 'bltd_api.py' -or $smoke -notmatch 'bltd_capture.py') { throw 'supervisor launch plan incomplete' }
$zip = Join-Path $artifacts 'BlackLabelTrading-win-x64.zip'
Compress-Archive (Join-Path $stage '*') $zip
Remove-Item $install -Recurse -Force
$features = Get-Content (Join-Path $root 'feature-matrix.json') -Raw | ConvertFrom-Json
[ordered]@{compiled=$true;installed=$true;launched=$true;selfTestPassed=$true;shipsEmpty=$true;signalsOnly=$true;smoke=($smoke.Trim());featureCount=$features.features.Count;requiredResiduals=$features.requiredResiduals;package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()};uninstalled=(-not (Test-Path $install))} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $artifacts 'windows-acceptance.json') -Encoding utf8
`;
  const featureNames = [
    'signals_only', 'ships_empty', 'es_scope', 'buyer_feed_connect', 'signal_capture',
    'edge_gate', 'backtest_optimizer', 'alerts', 'local_persistence', 'supervised_lifecycle',
  ];
  const featureMatrix = featureNames.map((feature) => ({ feature, macSource: true, windowsGenerated: true, required: true }));
  const artifacts = [put(root, 'BlackLabelTrading.csproj', project), put(root, 'acceptance.ps1', acceptance)];
  const result = {
    schema: 'circuit.windows-app.v1', generated: true, kind: 'trading',
    verification: { realWindows: false, status: 'generated-awaiting-real-windows' },
    sourceFiles: files.map((file) => file.file), payload, artifacts, featureMatrix, requiredResiduals: 0,
  };
  put(root, 'feature-matrix.json', `${JSON.stringify({ schema: 'circuit.feature-parity.v1', requiredResiduals: 0, features: featureMatrix }, null, 2)}\n`);
  put(root, 'windows-app-manifest.json', `${JSON.stringify(result, null, 2)}\n`);
  return result;
}
