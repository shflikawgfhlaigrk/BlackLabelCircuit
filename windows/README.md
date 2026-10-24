# Circuit-Win — the Windows shell (STAGED)

Contract `windows-w1-circuit-20260720` · Phase-W1 Circuit-Win + the Phase-0 shell spike.
Decision + evidence: **`../docs/windows-shell-spike.md`** (Tauri v2 wins the fleet — narrower
under the 2026-07-20 Store-first amendment).

## Distribution = STORE-FIRST MSIX (founder amendment 2026-07-20 ~09:05Z)

The deliverable is an **MSIX package staged for Microsoft Store submission**, not a raw signed
exe. The **Store re-signs** the uploaded package — **no Authenticode cert is purchased**, and
commerce is own-Stripe in-app (0% cut). Tauri has no native MSIX emit, so the MSIX is produced
by wrapping the built `Circuit.exe` with `makeappx`:

| File | Role |
|---|---|
| `msix/AppxManifest.xml` | Store manifest — `runFullTrust` (node sidecar), Win10-1809 floor (WebView2 Evergreen), **placeholder** publisher identity (Partner Center assigns the real `CN=<hash>`; display name = founder cross-brand gate) |
| `build-msix.sh` | assemble layout → resolve identity from Partner Center env → `makeappx pack` → **UNSIGNED** `.msix` for Store. `--validate` runs host-agnostic (green on darwin); `--sideload` = test-only self-sign via the fail-closed gate |
| `../test/winmsix.test.js` | regression-locks the manifest shape, placeholder identity (no cross-brand leak), and the unsigned Store path |

Run `bash windows/build-msix.sh --validate` on any host to assemble + validate the layout.
The real `makeappx pack` is W0-VM-gated (Windows SDK).

Circuit is already cross-platform where it counts: the zero-dependency node analyzer +
`server.js` + the three.js browser UI run unchanged on Windows (proven green by
`.github/workflows/windows-spike.yml`, run 29206008027). The only Apple lock-in was the
241-line Swift launcher. This directory ports that launcher into a **Tauri v2** shell.

## What is here

| File | Role |
|---|---|
| `src-tauri/src/main.rs` | The ported launcher: repo picker + recents, node sidecar spawn, follow-stdout-to-URL, navigate window, kill child on exit |
| `src-tauri/tauri.conf.json` | Tauri v2 config — node as `externalBin` sidecar, `app/` as a bundled resource, NSIS installer, no signing block |
| `src-tauri/Cargo.toml`, `build.rs`, `capabilities/default.json` | Rust crate + Tauri v2 permission capabilities |
| `ui/index.html` | Offline splash shown while the server boots (window navigates to the real URL) |
| `fetch-node-runtime.mjs` | Downloads the official Windows node.exe as the sidecar |
| `sign-windows.mjs` | **Fail-closed** Authenticode gate — holds until the cert exists |
| `build-win.sh` | VM orchestration: fetch → assemble → `cargo check` → `tauri build` → sign-gate |

## How it is built (in the W0 Windows VM)

The Rust toolchain lives in the build rig, not on the authoring Mac (plan §Architecture
decision). Once construction-engineer lands the `builder` snapshot:

```bash
# in the VM, after: rustup, `cargo install tauri-cli`, Node LTS
bash windows/build-win.sh
```

`build-win.sh` runs `cargo check` as the FIRST gate (proves the Rust compiles), then
`cargo tauri build`. The installer is then handed to `sign-windows.mjs`, which **holds
(exit 3)** because the cert does not exist yet — that hold is the gate working.

## Laws in force (contract)

- **Everything stages.** No published artifact, no storefront button/marketing.
- **Store path stages UNSIGNED** — the Microsoft Store re-signs the MSIX under the Partner
  Center identity, so no Authenticode cert is bought or applied. `sign-windows.mjs` is now
  **sideload-test-only** and still **fails closed** (a missing/empty/non-Windows cert never
  yields a "signed" artifact) for the optional local-sideload path.
- **Ships empty / zero fabrication / brand-isolation** — inherited from the shared `app/`
  (the same `server.js` + `lib/` as the Mac gold master; the shell adds no data and no
  claims).

## Proven on darwin now (see `../test/winshell.test.js`)

The Rust build is VM-gated, but the fragile cross-language seam — the shell keying on the
server's stdout URL — plus the config validity and the fail-closed gate are all locked by
tests that pass from a cold shell on this Mac:

- `parse_localhost_url` (Rust) has an exact JS mirror; the tests prove it follows a climbed
  port and refuses a port truncated mid-write.
- `server.js` really does print a `http://localhost:PORT` line the shell can follow (spawned
  on a dev port, stdout captured — the live `:8923` is never touched).
- `tauri.conf.json` is valid, declares the node sidecar + `app` resource, and carries **no**
  signing/publish config.
- `sign-windows.mjs` exits non-zero (holds) with no cert present.

## Honest residuals

- No Windows binary exists yet (VM-gated). On-Windows artifact-size + first-run numbers land
  with the W0 build.
- Recents **quick-pick list** UI is deferred; W1 ships the native folder picker + recents
  persistence. Updater pubkey/manifest = W0.4 (web-producer) — no fake key committed here.
