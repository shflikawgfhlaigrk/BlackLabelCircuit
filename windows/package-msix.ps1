<#
Black Label Circuit - Windows STORE-FIRST MSIX packaging (STAGED; fail-closed).

House channel law (inherited from the Academy windows lane, founder ruling 2026-07-20): STORE-FIRST
via MSIX. Partner Center registration is $0, Microsoft signs the MSIX for free on Store ingestion,
no Authenticode cert purchase (section 5.5: no new paid purchases - every step here costs $0).

What this script does, in order:
  1. Verifies the pkg-built exe exists (produced by the exact commands the proven windows-spike lane
     uses; this script builds nothing).
  2. Stages the unsigned MSIX payload layout at windows/dist/msix-layout/ - AppxManifest.xml
     (identity from WINDOWS_MSIX_* env, else the inert __PARTNER_CENTER_PENDING__ sentinel),
     BlackLabelCircuit.exe (staged copy of the pkg exe), Assets/ (spec + any real PNGs present).
     Writes windows/dist/SHA256SUMS.txt as evidence.
  3. GATE - FAIL-CLOSED, CLEAN: if PARTNER_CENTER_READY is absent (env var or
     windows/PARTNER_CENTER_READY marker file), prints "STAGED, AWAITING PARTNER CENTER" and exits 0.
     The unsigned payload layout is the ONLY artifact; no .msix is packed, nothing is signed or
     submitted. The sentinel manifest is not submittable by construction - we NEVER invent the
     founder-only publisher identity (Stripe-portal-class value).
  4. Armed path (ready flag present): requires the complete WINDOWS_MSIX_* identity and the real
     PNG assets (see Assets/REQUIRED-ASSETS.md - no fake placeholders, ever), resolves makeappx from
     the Windows SDK, packs windows/dist/BlackLabelCircuit-UNSIGNED.msix. Still UNSIGNED and still
     NOT submitted: Partner Center submission is a separate founder-gated action.

Runs under Windows PowerShell 5.1 and pwsh. Local use:
  powershell -ExecutionPolicy Bypass -File windows/package-msix.ps1
#>
[CmdletBinding()]
param(
  # The exe the proven lane produces at repo root (see .github/workflows/windows-msix.yml).
  [string]$ExePath = 'circuit-windows-UNSIGNED-STAGED-ONLY.exe',
  # Output root for the staged layout / hashes / (armed-only) msix.
  [string]$OutDir  = 'windows/dist'
)

$ErrorActionPreference = 'Stop'
$Sentinel = '__PARTNER_CENTER_PENDING__'

# Always operate from the repo root (this script lives in windows/).
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Resolve-MakeAppx {
  # makeappx.exe is NOT on PATH on windows-latest runners; it ships with the Windows SDK under
  # "...\Windows Kits\10\bin\<sdk-version>\x64\makeappx.exe". Pick the newest SDK that has it.
  $cmd = Get-Command makeappx.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $roots = @()
  $pf86 = ${env:ProgramFiles(x86)}
  if ($pf86) { $roots += (Join-Path $pf86 'Windows Kits\10\bin') }
  if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'Windows Kits\10\bin') }
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $vers = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^10\.' }
    $sorted = @($vers | Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending)
    foreach ($v in $sorted) {
      $exe = Join-Path $v.FullName 'x64\makeappx.exe'
      if (Test-Path $exe) { return $exe }
    }
  }
  return $null
}

# ---- [1/4] Verify the built exe -------------------------------------------------------------------
Write-Host '==> [1/4] Verify the pkg-built exe (this script packages; the proven lane builds)'
if (-not (Test-Path $ExePath)) {
  Write-Host "ERROR: built exe not found at '$ExePath'."
  Write-Host '       Build it first with the exact proven-lane commands (windows-spike package job):'
  Write-Host '         npm ci'
  Write-Host '         node build-vendor.mjs'
  Write-Host '         npx --yes pkg@5.8.1 server.js --targets node18-win-x64 \'
  Write-Host '           --output circuit-windows-UNSIGNED-STAGED-ONLY.exe --public'
  exit 1
}
$ExeInfo = Get-Item $ExePath
Write-Host ("    exe: {0} ({1} bytes)" -f $ExeInfo.FullName, $ExeInfo.Length)

# ---- [2/4] Stage the payload layout ---------------------------------------------------------------
Write-Host '==> [2/4] Stage unsigned MSIX payload layout'
$Layout = Join-Path $OutDir 'msix-layout'
if (Test-Path $Layout) { Remove-Item -Recurse -Force $Layout }
New-Item -ItemType Directory -Force -Path (Join-Path $Layout 'Assets') | Out-Null

Copy-Item -Path $ExePath -Destination (Join-Path $Layout 'BlackLabelCircuit.exe') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'Assets\*') -Destination (Join-Path $Layout 'Assets') -Recurse -Force

# Identity: env values (exact Partner Center strings) or the inert sentinel. Never invented.
$IdentityName     = $env:WINDOWS_MSIX_IDENTITY_NAME
$Publisher        = $env:WINDOWS_MSIX_PUBLISHER
$PublisherDisplay = $env:WINDOWS_MSIX_PUBLISHER_DISPLAY
$PkgVersion       = $env:WINDOWS_MSIX_VERSION
if ([string]::IsNullOrWhiteSpace($IdentityName))     { $IdentityName     = $Sentinel }
if ([string]::IsNullOrWhiteSpace($Publisher))        { $Publisher        = $Sentinel }
if ([string]::IsNullOrWhiteSpace($PublisherDisplay)) { $PublisherDisplay = $Sentinel }
if ([string]::IsNullOrWhiteSpace($PkgVersion))       { $PkgVersion       = '1.0.0.0' }

# -Encoding UTF8 is load-bearing: the template is BOM-less UTF-8 and Windows PowerShell 5.1 would
# otherwise decode it as ANSI, corrupting the em dash in the app Description.
$Manifest = Get-Content -Raw -Encoding UTF8 -Path (Join-Path $PSScriptRoot 'AppxManifest.xml')
$Manifest = $Manifest.Replace('__WINDOWS_MSIX_IDENTITY_NAME__', $IdentityName)
$Manifest = $Manifest.Replace('__WINDOWS_MSIX_PUBLISHER__', $Publisher)
$Manifest = $Manifest.Replace('__WINDOWS_MSIX_PUBLISHER_DISPLAY__', $PublisherDisplay)
$Manifest = $Manifest.Replace('__WINDOWS_MSIX_VERSION__', $PkgVersion)
$LayoutFull = (Resolve-Path $Layout).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $LayoutFull 'AppxManifest.xml'), $Manifest, $Utf8NoBom)

# ---- [3/4] Hash evidence --------------------------------------------------------------------------
Write-Host '==> [3/4] SHA256SUMS of the staged layout'
$Lines = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-ChildItem -Recurse -File -Path $Layout | Sort-Object FullName)) {
  $hash = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash.ToLower()
  $rel  = $f.FullName.Substring($LayoutFull.Length + 1).Replace('\', '/')
  $Lines.Add(('{0}  {1}' -f $hash, $rel))
}
$OutDirFull = (Resolve-Path $OutDir).Path
[System.IO.File]::WriteAllLines((Join-Path $OutDirFull 'SHA256SUMS.txt'), $Lines)
foreach ($line in $Lines) { Write-Host ("    " + $line) }

# ---- [4/4] Partner Center gate (fail-closed) ------------------------------------------------------
Write-Host '==> [4/4] Partner Center gate'
$Ready = $false
if (-not [string]::IsNullOrWhiteSpace($env:PARTNER_CENTER_READY)) { $Ready = $true }
if (Test-Path (Join-Path $PSScriptRoot 'PARTNER_CENTER_READY'))   { $Ready = $true }

if (-not $Ready) {
  Write-Host ''
  Write-Host 'STAGED, AWAITING PARTNER CENTER.'
  Write-Host '  The founder-only Partner Center publisher identity does not exist yet, so the manifest'
  Write-Host ("  carries the inert {0} sentinel and is NOT submittable. No .msix was" -f $Sentinel)
  Write-Host '  packed, nothing was signed, nothing was submitted. The unsigned payload layout is the'
  Write-Host '  only artifact produced:'
  Write-Host ("    {0}" -f $LayoutFull)
  Write-Host '  To arm this step (founder action, $0): register at'
  Write-Host '    https://partner.microsoft.com/dashboard/registration'
  Write-Host '  then set PARTNER_CENTER_READY=1 (or create windows/PARTNER_CENTER_READY) plus the'
  Write-Host '  WINDOWS_MSIX_PUBLISHER / WINDOWS_MSIX_IDENTITY_NAME / WINDOWS_MSIX_PUBLISHER_DISPLAY'
  Write-Host '  values exactly as Partner Center assigns them.'
  exit 0
}

# Armed path - the ready flag is set, so the identity must be COMPLETE and real.
$Missing = @()
if ([string]::IsNullOrWhiteSpace($env:WINDOWS_MSIX_PUBLISHER))         { $Missing += 'WINDOWS_MSIX_PUBLISHER' }
if ([string]::IsNullOrWhiteSpace($env:WINDOWS_MSIX_IDENTITY_NAME))     { $Missing += 'WINDOWS_MSIX_IDENTITY_NAME' }
if ([string]::IsNullOrWhiteSpace($env:WINDOWS_MSIX_PUBLISHER_DISPLAY)) { $Missing += 'WINDOWS_MSIX_PUBLISHER_DISPLAY' }
if ($Missing.Count -gt 0) {
  Write-Host ('ERROR: PARTNER_CENTER_READY is set but identity values are missing: ' + ($Missing -join ', '))
  Write-Host '       Fail-closed: the publisher identity is founder-only and never invented. Either unset'
  Write-Host '       the ready flag or provide the exact Partner-Center-assigned values.'
  exit 1
}

# Asset preflight: makeappx requires every manifest-referenced file to exist. Placeholder art is
# banned (fabrication-adjacent) - absence fails loudly and forces the real design step.
$RequiredAssets = @('Assets\StoreLogo.png', 'Assets\Square150x150Logo.png', 'Assets\Square44x44Logo.png')
$MissingAssets = @()
foreach ($a in $RequiredAssets) {
  if (-not (Test-Path (Join-Path $Layout $a))) { $MissingAssets += $a }
}
if ($MissingAssets.Count -gt 0) {
  Write-Host ('ERROR: required MSIX assets missing from the layout: ' + ($MissingAssets -join ', '))
  Write-Host '       See windows/Assets/REQUIRED-ASSETS.md - real PNGs are a design deliverable; this lane'
  Write-Host '       never fakes them. Fail-closed: no .msix packed.'
  exit 1
}

$MakeAppx = Resolve-MakeAppx
if (-not $MakeAppx) {
  Write-Host 'ERROR: makeappx.exe not found. It ships with the Windows SDK (on windows-latest runners:'
  Write-Host '       "C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64\makeappx.exe").'
  exit 1
}
Write-Host ("    makeappx: {0}" -f $MakeAppx)

$MsixPath = Join-Path $OutDirFull 'BlackLabelCircuit-UNSIGNED.msix'
if (Test-Path $MsixPath) { Remove-Item -Force $MsixPath }
& $MakeAppx pack /d $LayoutFull /p $MsixPath /o
if ($LASTEXITCODE -ne 0) {
  Write-Host ("ERROR: makeappx pack failed (exit {0})." -f $LASTEXITCODE)
  exit 1
}
$MsixHash = (Get-FileHash -Algorithm SHA256 -Path $MsixPath).Hash.ToLower()
Write-Host ''
Write-Host 'PACKED (UNSIGNED), NOT SUBMITTED.'
Write-Host ("  {0}" -f $MsixPath)
Write-Host ("  sha256: {0}" -f $MsixHash)
Write-Host '  Microsoft signs on Store ingestion (store-first MSIX path - no local signtool, no cert'
Write-Host '  purchase). Submission to Partner Center is a separate founder-gated action this script'
Write-Host '  never performs.'
exit 0
