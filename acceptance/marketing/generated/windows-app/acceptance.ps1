$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;$art=Join-Path $root 'artifacts';$pub=Join-Path $art 'publish';$install=Join-Path $env:LOCALAPPDATA 'BlackLabel\Marketing\AcceptanceInstall'
foreach($p in @($art,$install)){if(Test-Path $p){Remove-Item $p -Recurse -Force}}
dotnet publish (Join-Path $root 'BlackLabelMarketing.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $pub
New-Item -ItemType Directory -Force $install|Out-Null;Copy-Item (Join-Path $pub '*') $install -Recurse -Force;$exe=Join-Path $install 'BlackLabelMarketing.exe'
$self=& $exe --self-test|ConvertFrom-Json;if(-not $self.passed -or -not $self.shipsEmpty -or $self.surfaceCount -ne 49){throw 'self-test failed'}
$smokeFile=Join-Path $art 'smoke.txt';$p=Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smokeFile -PassThru -Wait;if($p.ExitCode -ne 0 -or (Get-Content $smokeFile -Raw)-notmatch 'loaded=true'){throw 'smoke failed'}
$zip=Join-Path $art 'BlackLabelMarketing-win-x64.zip';Compress-Archive (Join-Path $pub '*') $zip;Remove-Item $install -Recurse -Force
[ordered]@{compiled=$true;installed=$true;launched=$true;selfTestPassed=$self.passed;shipsEmpty=$self.shipsEmpty;surfaceCount=$self.surfaceCount;requiredResiduals=0;package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()};uninstalled=(-not(Test-Path $install))}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $art 'windows-acceptance.json') -Encoding utf8
