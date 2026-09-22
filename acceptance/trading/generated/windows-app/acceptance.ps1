$ErrorActionPreference = 'Stop'
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
