$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'BlackLabelAcademy.csproj'
$publish = Join-Path $root 'artifacts\publish'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\Academy\AcceptanceInstall'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
if (Test-Path $install) { Remove-Item $install -Recurse -Force }
dotnet restore $project -r win-x64
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $publish --no-restore
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $publish '*') $install -Recurse -Force
$exe = Join-Path $install 'BlackLabelAcademy.exe'
$self = & $exe --self-test | ConvertFrom-Json
if (-not $self.passed) { throw 'self-test failed' }
$smokeFile = Join-Path $root 'artifacts\smoke.txt'
$smoke = Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smokeFile -PassThru -Wait
if ($smoke.ExitCode -ne 0 -or (Get-Content $smokeFile -Raw) -notmatch 'loaded=true') { throw 'smoke failed' }
$zip = Join-Path $root 'artifacts\BlackLabelAcademy-win-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
Remove-Item $install -Recurse -Force
$uninstalled = -not (Test-Path $install)
[ordered]@{ compiled=$true; installed=$true; launched=$true; selfTestPassed=$self.passed; smoke=(Get-Content $smokeFile -Raw).Trim(); package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()}; requiredResiduals=0; uninstalled=$uninstalled } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'artifacts\windows-acceptance.json') -Encoding utf8
if (-not $uninstalled) { throw 'uninstall failed' }
