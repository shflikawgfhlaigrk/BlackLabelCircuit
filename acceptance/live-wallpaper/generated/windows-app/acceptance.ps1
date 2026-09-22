$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'BlackLabelLiveWallpaper.csproj'
$publish = Join-Path $root 'artifacts\publish'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\LiveWallpaper\AcceptanceInstall'
$evidence = Join-Path $root 'artifacts\windows-acceptance.json'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
if (Test-Path $install) { Remove-Item $install -Recurse -Force }
dotnet restore $project -r win-x64
dotnet build $project -c Release -r win-x64 --no-restore
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $publish --no-restore
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $publish '*') $install -Recurse -Force
$exe = Join-Path $install 'BlackLabelLiveWallpaper.exe'
$self = & $exe --self-test
if ($LASTEXITCODE -ne 0) { throw 'self-test failed' }
$smokeFile = Join-Path $root 'artifacts\smoke.txt'
$smokeProc = Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smokeFile -PassThru -Wait
if ($smokeProc.ExitCode -ne 0) { throw 'smoke launch failed' }
$smoke = Get-Content $smokeFile -Raw
if ($smoke -notmatch 'BLW_SMOKE\|.*windows=[1-9].*image_loaded=true') { throw "invalid smoke receipt: $smoke" }
$normal = Start-Process $exe -ArgumentList '--acceptance-run' -PassThru
Start-Sleep -Milliseconds 700
$launched = -not $normal.HasExited
$normal.WaitForExit(5000) | Out-Null
if (-not $launched -or $normal.ExitCode -ne 0) { throw 'installed normal launch failed' }
$zip = Join-Path $root 'artifacts\BlackLabelLiveWallpaper-win-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -CompressionLevel Optimal
$files = Get-ChildItem $publish -File -Recurse | Sort-Object FullName | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($publish.Length + 1); bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item $install -Recurse -Force
$uninstalled = -not (Test-Path $install)
$receipt = [ordered]@{ schema='circuit.windows-acceptance.v1'; os=[Environment]::OSVersion.VersionString; architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); dotnet=(dotnet --version); compiled=$true; installed=$true; launched=$launched; smoke=$smoke.Trim(); selfTest=($self | ConvertFrom-Json); files=$files; package=[ordered]@{ path='artifacts/BlackLabelLiveWallpaper-win-x64.zip'; bytes=(Get-Item $zip).Length; sha256=$zipHash }; uninstalled=$uninstalled; requiredResiduals=0 }
$receipt | ConvertTo-Json -Depth 12 | Set-Content $evidence -Encoding utf8
if (-not $uninstalled) { throw 'uninstall failed' }
Write-Output "ACCEPTANCE_PASS|package_sha256=$zipHash"
