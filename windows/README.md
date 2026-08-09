# Black Label Circuit — Windows MSIX lane (STAGED, fail-closed)

Additive lane on top of the proven `circuit-windows-spike` CI lane (2026-07-08 spike: green on
windows-latest, 33/33 tests, real unsigned exe produced). This directory delivers Windows-port plan
item #3 — "exe proven, needs MSIX". Nothing here signs, submits, or ships, and nothing in the
existing repo was modified: `windows-spike.yml` and every other pre-existing file are untouched.

## Channel — STORE-FIRST MSIX (house law, inherited)

Same channel law as the Academy windows lane (founder ruling 2026-07-20): package MSIX, publish via
Partner Center (registration is $0, Microsoft signs the MSIX for free on Store ingestion), sell via
our own in-app commerce. No Authenticode cert purchase — that fallback stays dormant elsewhere, and
§5.5 (no new paid purchases) holds: every step in this lane costs $0.

## Pieces

- `AppxManifest.xml` — template. Identity fields carry `__WINDOWS_MSIX_*__` placeholders that
  `package-msix.ps1` fills from `WINDOWS_MSIX_*` environment values; absent those it stamps the
  inert `__PARTNER_CENTER_PENDING__` sentinel, so the manifest is not submittable by construction.
  The publisher identity is a founder-only, Stripe-portal-class value — never invented.
- `package-msix.ps1` — packaging script (PowerShell 5.1 + pwsh):
  1. Verifies the pkg-built exe (`circuit-windows-UNSIGNED-STAGED-ONLY.exe`, built by the exact
     proven-lane commands) and stages `windows/dist/msix-layout/` = substituted `AppxManifest.xml`
     + `BlackLabelCircuit.exe` + `Assets/`, with `windows/dist/SHA256SUMS.txt` as evidence.
  2. GATE, fail-closed and clean: without `PARTNER_CENTER_READY` (env var, or a
     `windows/PARTNER_CENTER_READY` marker file) it prints **"STAGED, AWAITING PARTNER CENTER"**
     and exits 0 — the unsigned payload layout is the only artifact; no `.msix`, no signing, no
     submission.
  3. Armed path: requires the complete identity (`WINDOWS_MSIX_PUBLISHER`,
     `WINDOWS_MSIX_IDENTITY_NAME`, `WINDOWS_MSIX_PUBLISHER_DISPLAY` — exact Partner Center values;
     optional `WINDOWS_MSIX_VERSION`, default `1.0.0.0`) and the real PNGs per
     `Assets/REQUIRED-ASSETS.md`, then runs Windows-SDK `makeappx pack` →
     `windows/dist/BlackLabelCircuit-UNSIGNED.msix`. Still unsigned (Microsoft signs on Store
     ingestion) and still NOT submitted — Partner Center submission stays a founder-gated action.
- `Assets/REQUIRED-ASSETS.md` — asset SPEC. No fake/placeholder PNGs, ever; `makeappx` fails
  loudly when they are missing, which correctly forces the real design step.
- CI: `.github/workflows/windows-msix.yml` (windows-latest) — rebuilds the exe with the exact
  steps copied from the proven `windows-spike.yml` package job (plus the proof job's `npm test`
  gate), runs this packaging script, uploads `windows/dist/` as the artifact. Triggers: push to
  `claude/windows-full-build-*` branches, and manual `workflow_dispatch`.

## Founder actions (all $0) to arm the lane

1. Register Partner Center: https://partner.microsoft.com/dashboard/registration
2. Set repo secrets `WINDOWS_MSIX_PUBLISHER` (the exact `CN=...` string Partner Center assigns),
   `WINDOWS_MSIX_IDENTITY_NAME`, `WINDOWS_MSIX_PUBLISHER_DISPLAY`; set repo variable
   `PARTNER_CENTER_READY=1`.
3. Deliver the three real PNGs into `windows/Assets/` (see `Assets/REQUIRED-ASSETS.md`).
4. Store submission itself remains founder-gated; neither the script nor CI ever submits.

## Local run (Windows)

    npm ci
    node build-vendor.mjs
    npx --yes pkg@5.8.1 server.js --targets node18-win-x64 --output circuit-windows-UNSIGNED-STAGED-ONLY.exe --public
    powershell -ExecutionPolicy Bypass -File windows/package-msix.ps1
