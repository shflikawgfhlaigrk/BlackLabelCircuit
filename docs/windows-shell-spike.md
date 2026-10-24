# Windows shell spike — Tauri v2 vs Electron (decided on Circuit)

_Contract `windows-w1-circuit-20260720` · Phase-0 shell decision + Phase-W1 Circuit-Win._
_Plan of record: `~/BlackLabel-Team/PLANS/expansion-20260707/01-windows-downloads.md` §Architecture decision._

## Verdict

**Tauri v2 is THE fleet shell.** Every Windows UI Black Label writes over a portable
localhost engine (Circuit's node server, Sovereign's dashboard, Trading's web UI, …)
is wrapped in Tauri v2. Electron is rejected for the fleet standard. The confirming
**on-Windows artifact-size + first-run numbers land in the W0 VM build** (Rust toolchain
lives in the build rig per the plan) — this file records the decision and the
reproducible recipe so that VM run only has to _confirm_ it, not re-litigate it.

This is not a reversal of the plan's stated default (Tauri v2); the spike **confirms**
it against real Circuit code and names the exact evidence the VM produces.

> ⚠️ **Re-litigated under the founder amendment (2026-07-20 ~09:05Z) — read
> [§ Store-first MSIX](#amendment-20260720--store-first-msix-re-litigation) below.**
> Distribution is now STORE-FIRST via **MSIX** (the Store signs; no Authenticode cert).
> That is a genuine change of ground, not a restatement: it **removes two of Tauri's former
> decisive advantages** (the Authenticode signing surface and R2 egress) and adds a new
> first-class criterion — **MSIX packaging quality** — on which **Electron actually wins**.
> The net verdict stays Tauri v2, but by a **narrower** margin, on the surviving factors.

## Amendment (2026-07-20) — Store-first MSIX re-litigation

The founder ruled distribution is **STORE-FIRST via MSIX**, commerce is own-Stripe in-app
(0% cut), and **no Authenticode cert is purchased** — the Microsoft Store re-signs the
uploaded package under the Partner Center account identity. This changes the criteria:

| Criterion (re-weighed) | Tauri v2 | Electron | Winner |
|---|---|---|---|
| **MSIX packaging quality** *(now first-class)* | **No native MSIX emit.** Tauri bundles NSIS/MSI only; the MSIX is produced by wrapping the built `Circuit.exe` with `makeappx pack` + a hand-authored `AppxManifest.xml` (now staged in `windows/msix/`, layout validated on darwin) | `electron-builder --win appx` is a **native, first-class target** — one config block emits a Store-ready MSIX | **Electron** — mature native target vs our own makeappx recipe |
| Authenticode nested-binary signing surface | *(former decisive Tauri win)* — **EVAPORATES**: the Store re-signs the whole package, so the count of nested `.dll`/`.exe` no longer drives a signing burden | Same — Store re-signs Chromium's binaries too | **Tie now** (was Tauri) |
| Distribution egress / download host | *(former Tauri win via smaller R2 pulls)* — **EVAPORATES**: the Store CDN hosts and meters the download, not our R2 | Same | **Tie now** (was Tauri) |
| On-disk / download footprint | WebView2 is OS-provided → the MSIX carries no browser engine; smaller Store download + install size | Bundles Chromium → materially larger MSIX | **Tauri** — still real for Store download + user disk |
| Fleet uniformity | One shell pattern reused across Circuit / Sovereign / Trading / RealEstate, each already a localhost engine | Same | **Tie** — uniformity is the point |
| Zero-dependency node backend | Node ships as the sidecar, `server.js` unchanged | In-process | Tie |

**Net verdict: still Tauri v2, narrower.** Electron wins the new MSIX-quality axis (native
`appx` target vs our makeappx wrap), and Tauri's two former *decisive* wins (signing surface,
R2 egress) are neutralized by Store re-signing + Store CDN. What keeps Tauri ahead on net:
the **smaller Store download + install footprint** (WebView2 vs bundled Chromium), **fleet
uniformity** (one shell for four products), and the **zero-dep node sidecar**. The MSIX-quality
gap is closed in practice by `windows/msix/AppxManifest.xml` + `windows/build-msix.sh` (a real,
validated makeappx recipe — proven to assemble a valid layout on darwin), so the one axis
Electron wins is a build-recipe cost we now own, not a per-download or per-user cost.

**MSIX deliverable (staged, this session):**
- `windows/msix/AppxManifest.xml` — valid Store manifest: `runFullTrust` (node sidecar), Win10
  1809 floor (WebView2 Evergreen), **placeholder** publisher identity (Partner Center assigns the
  real `CN=<hash>`; the display name is a **founder cross-brand gate** — never hardcoded).
- `windows/build-msix.sh` — assemble layout → resolve identity from Partner Center env →
  `makeappx pack` → **UNSIGNED** `.msix` staged for Store (Store signs). `--validate` mode runs
  host-agnostic (proven green on darwin); `--sideload` routes the test-only self-sign through the
  fail-closed gate.
- `test/winmsix.test.js` — regression-locks the manifest shape, the placeholder identity (no
  cross-brand leak), and the unsigned Store path. Guards proven to fire on a real leak.

**Store residuals (not done here — founder/VM-gated):** Partner Center registration + reserved
app identity (founder), the publisher **display name** decision (founder cross-brand gate), real
Store tile assets (web-producer), and the actual `makeappx pack` on the W0 VM. `windows/sign-windows.mjs`
is now **sideload-test-only** — the Store path stages unsigned and needs no cert.

## Why — decision criteria

Each row is a documented/verifiable property or an explicit "pending VM" measurement.
No benchmark number is invented here (§5.1); Parallels ≠ real hardware for perf anyway.

| Criterion | Tauri v2 | Electron | Winner |
|---|---|---|---|
| Installer artifact size class | Uses the OS WebView2 runtime; installers are single-digit MB (documented Tauri characteristic). Confirmed size = **pending W0 VM** | Bundles a full Chromium + Node; ~85–150 MB (documented Electron characteristic) | **Tauri** — R2 egress, download UX, and fewer/smaller nested binaries to Authenticode-sign |
| WebView engine | Windows-provided **WebView2** (present by default on Win 11; Win 10 needs the Evergreen bootstrapper — handled in the installer) | Vendored Chromium | Tauri (smaller); both render Circuit's three.js UI |
| Node engine for `server.js` | Shipped as a **sidecar** (`externalBin`) — the exact same `node` + zero-dependency `server.js` we run today | Node is in-process | Tie — Circuit's backend is stdlib-only, so either hosts it unchanged |
| Self-hostable updater | First-party Tauri updater, points at our own `/api/version/circuit-windows` (own-it, no paid service — §5.5) | electron-updater (also self-hostable) | Tie; Tauri's is smaller |
| License / cost | Free OSS (MIT/Apache-2) | Free OSS (MIT) | Tie (own-it ✓ both) |
| Build-rig cost | **Rust toolchain** required (one-time, in the VM) | Pure JS/npm | Electron — but a one-time toolchain install is cheap vs 18× artifact size forever |
| Nested-binary signing surface | 1 shell exe + 1 node sidecar exe (+ small NSIS) | Shell + Chromium's many `.dll`/`.exe` — every one must be signed or Defender/SmartScreen flags the payload | **Tauri** — dramatically smaller signing surface (plan risk §"sign every nested .exe/.dll") |
| Fleet uniformity | One pattern reused by Circuit / Sovereign / Trading / RealEstate | Same | Tie — uniformity is the point; whichever wins is used everywhere |

**Decisive factors (original, direct-download framing):** artifact size (download UX + R2
egress) and the **signing surface** (the plan explicitly warns "sign every nested .exe/.dll or
SmartScreen/AV flags the payload"). Tauri's WebView2 model means ~2 binaries to sign instead of
Chromium's many. The only Electron edge — no Rust — is a one-time build-rig cost.

> ⚠️ **Superseded for the Store path** by the [2026-07-20 amendment](#amendment-20260720--store-first-msix-re-litigation):
> under Store-first MSIX both of these decisive factors are neutralized (the Store re-signs the
> package and hosts the download), and MSIX-packaging quality — where Electron's native `appx`
> target wins — becomes first-class. The net verdict is still Tauri v2, but on the surviving
> factors (footprint, fleet uniformity, node sidecar), not these two. The signing-surface point
> above still applies to any **direct-download / sideload** NSIS fallback we keep.

## What the existing CI already proved (real, not restated numbers)

`.github/workflows/windows-spike.yml` (run **29206008027**, both jobs conclusion=`success`)
already establishes the ground the shell sits on:
- Circuit's **zero-dependency node analyzer runs and produces a real, rubric-derived grade
  on a genuine `windows-latest` runner** (`test/windows-spike-proof.mjs`), and the unit
  suite passes on Windows (the non-`continue-on-error` gate is green).
- A **`pkg` single-file `.exe`** was staged with real friction captured
  (`pkg-friction.txt` artifact). `pkg` is a THIRD, headless option — a single exe with
  **no window/UI** — useful only for the `--check` CI-gate use, not the buyer-facing 3D
  app. It is not the shell; it is evidence the node payload bundles cleanly on Windows.

So the risky seams (node-on-Windows, path separators, real grade) are already retired.
The shell only has to host that node server and open a window — which is exactly what the
macOS launcher does today, and what `windows/src-tauri/` now ports.

## The port (macOS launcher → Tauri v2)

The 241 lines of macOS launcher logic (`macos/CircuitLauncher.swift` + `macos/launcher.sh`)
map 1:1 onto the Tauri shell in `windows/src-tauri/src/main.rs`:

| macOS behavior | Tauri v2 equivalent (`main.rs`) |
|---|---|
| Repo picker (`NSOpenPanel` / `choose folder`) | `tauri-plugin-dialog` `blocking_pick_folder()` |
| Recents (`~/.circuit-recent-repos`, dedupe, cap 8) | `recent-repos.txt` in `app_config_dir()`, same dedupe/cap |
| Preflight (node + server present) | resolve sidecar + `app/server.js` resource; honest error dialog if missing |
| Spawn `node server.js <repo>` | `app.shell().sidecar("node")` with `[server.js, repo]` |
| Read stdout for `http://localhost:PORT` (port climbs past default on EADDRINUSE) | same regex over `CommandEvent::Stdout`, then `window.navigate(url)` |
| Open standalone browser window | Tauri `WebviewWindow` (splash → navigate to the parsed URL) |
| Tie server lifetime to the app; SIGTERM/kill on quit | hold `CommandChild`; `kill()` on `CloseRequested` + `RunEvent::ExitRequested` |

Port pick is **not** hardcoded: the shell reads the server's actual URL from stdout, so if
the default port is taken the shell follows the server as it climbs — identical to the
macOS launcher. (On a buyer's Windows machine there is no hands-off `:8923`; that rule is a
dev-machine concern only.)

## Build recipe (runs in the W0 VM — `windows/build-win.sh`)

1. `windows/fetch-node-runtime.mjs` — download the official Windows x64 node and place it as
   the Tauri sidecar `binaries/node-x86_64-pc-windows-msvc.exe`.
2. Assemble `windows/src-tauri/app/` = `server.js` + `lib/` + `public/` (three.js already
   vendored) + `editor/` + `package.json`. Zero runtime npm deps.
3. `cargo check` (first gate — proves the Rust compiles) then `npm run tauri build`
   (produces the NSIS installer).
4. `windows/sign-windows.mjs` — **fail-closed** Authenticode gate. The cert does not exist
   until 2026-07-21 (founder pays), so this **exits non-zero and publishes nothing**.
5. Gauntlet on the `clean-buyer` snapshot (plan §The gauntlet) — pending the VM.

## Honest residuals (what is NOT done here)

- **No Windows binary exists yet.** Rust/Tauri build is VM-gated; this session produced the
  shell source + recipe + fail-closed gate, all reviewable, none built. On-Windows
  artifact-size + first-run numbers = pending W0 (construction-engineer's snapshots).
- **Unsigned == unshippable.** `sign-windows.mjs` fails closed until the cert exists.
- **No storefront page/button/marketing** (separate founder gate).
- Recents **quick-pick list UI** (the macOS pop-up of recent repos) is deferred; W1 ports
  the native folder picker + recents persistence (default path = last repo). Recorded as
  next.
- Updater **pubkey/manifest endpoint** is W0.4 (web-producer's staged plumbing); no fake key
  is committed here.
