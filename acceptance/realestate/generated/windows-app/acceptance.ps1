$ErrorActionPreference = 'Stop'
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
