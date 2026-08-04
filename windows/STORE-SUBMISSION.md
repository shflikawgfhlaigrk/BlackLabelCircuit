# Circuit — Microsoft Store submission

Everything needed to submit Circuit to the Microsoft Store the moment the Partner Center
account finishes verifying. Read top to bottom once; after that only §2 matters.

---

## 0. What the lane produces, and what it is not

| | |
|---|---|
| Artifact | `windows/dist/Circuit.msix` |
| Signature | **NONE — unsigned, by design** |
| Good for | Uploading to Partner Center. The Store re-signs the package under the account certificate. |
| **NOT good for** | **Sideloading. An unsigned MSIX cannot be installed by double-click.** Sideload install requires an Authenticode signature and no Authenticode cert has been purchased. |

If someone needs to install Circuit on a Windows box outside the Store, that is a *different*
artifact and it is blocked on buying a cert (see §6). Do not hand anyone this `.msix` and call
it an installer.

---

## 1. Reserve the app name (do this first)

1. Sign in to Partner Center → **Apps and games** → **New product** → **MSIX or PWA app**.
2. Reserve the name **Circuit**. If taken, reserve the closest available name and use it
   consistently everywhere below — the reserved name is what appears in the Store.
3. After reservation, open the product → **Product management** → **Product identity**.
   That page shows exactly three values. They are the three placeholders in this repo.

The account is registered as an **individual, not a company**. The publisher display name will
therefore be the owner's **verified legal name**. Nothing in this repo hardcodes a company
publisher name, and nothing should.

---

## 2. Where the three identity values get pasted — ONE file

```bash
cp windows/msix/partner-center.env.example windows/msix/partner-center.env
$EDITOR windows/msix/partner-center.env
```

`windows/msix/partner-center.env` is the **only** place these values are written. It is
gitignored (account identity, not source). Three lines, quoted:

| Partner Center field | Variable in `partner-center.env` | Shape |
|---|---|---|
| Package/Identity/**Name** | `PARTNER_CENTER_IDENTITY_NAME` | `<AssignedPrefix>.Circuit` |
| Package/Identity/**Publisher** | `PARTNER_CENTER_IDENTITY` | `CN=<GUID assigned to the account>` |
| Package/**Publisher display name** | `PARTNER_CENTER_PUBLISHER_DISPLAY` | the owner's verified legal name |

**Quote every value.** The legal name contains spaces and an unquoted value silently truncates
at the first space.

`windows/build-msix.sh` substitutes these into the packed layout's manifest at build time.
`windows/msix/AppxManifest.xml` keeps the placeholder tokens forever — **do not hand-edit it.**

Verify the paste took, on any host including this Mac:

```bash
bash windows/build-msix.sh --validate
```

It prints the resolved identity and a one-word verdict:

- `STORE-READY` — all three resolved. Submittable.
- `IDENTITY-PLACEHOLDER` — at least one is still a token. It names which. **Not submittable.**

The same verdict is written to `windows/dist/IDENTITY-STATUS.txt` and is carried in the CI
artifact **name**, so a placeholder package cannot be mistaken for a submittable one by anyone
who never opens the zip.

### In CI

Add the same three as repository **secrets** with the identical names:
`PARTNER_CENTER_IDENTITY_NAME`, `PARTNER_CENTER_IDENTITY`, `PARTNER_CENTER_PUBLISHER_DISPLAY`.
The workflow reads them from `secrets.*`. Real environment variables take precedence over the
file, so CI needs no file on disk.

---

## 3. How to build

### In CI (the lane that is meant to produce the submission artifact)

`.github/workflows/windows-store-msix.yml`, on `windows-latest`.

- **Trigger:** `workflow_dispatch` (optional `package_version` input, 4 parts, revision `0`),
  or pushing a `circuit-win-v*` tag.
- **Job `shell`:** builds the real Tauri exe. `continue-on-error` — the Rust/Tauri bring-up is
  heavier than the pack and must not be able to block the packaging proof.
- **Job `msix`:** runs the packaging regression tests, puts the Windows SDK `makeappx.exe` on
  PATH, packs the layout, proves the output is a real MSIX by its PK/zip magic bytes, hashes
  it, and **fails closed** — a run that packs nothing ends red.
- **Artifact name** carries three facts:
  `circuit-store-msix-UNSIGNED-<PACKED|NOT-PACKED>-<REALEXE|PLACEHOLDEREXE>-<STORE-READY|IDENTITY-PLACEHOLDER>`

Download the artifact, confirm the name says `PACKED-REALEXE-STORE-READY`, and upload
`Circuit.msix` to Partner Center → **Packages**.

Modelled directly on the proven `circuit-windows-spike` msix job — the one lane known to work
on a real GitHub-hosted Windows runner. That workflow is left untouched.

### Locally

```bash
bash windows/build-msix.sh --validate      # any host, macOS included. Layout + manifest only.
bash windows/build-msix.sh --pack-layout   # Windows only. Packs with a placeholder exe.
bash windows/build-msix.sh                 # Windows only. Requires a real built Circuit.exe.
bash windows/build-msix.sh --sideload      # Test only. Routes through the fail-closed sign gate.
```

`--sideload` is **not** the Store path and will hold (exit 3) with no cert.

**Portability:** every path in the lane is derived from the script's own location or the repo
checkout. No absolute paths, no sibling repositories, no host-specific tooling beyond the
`windows-latest` image. Verified by grep and by a test that fails on any `/Users/` string.

---

## 4. Store assets

### Shipped and wired (in the package)

The manifest declares four tiles and all four exist as real PNGs at exact spec dimensions,
gated before every pack (`windows/msix/gen-assets.mjs --check`):

| File | Size | Manifest reference |
|---|---|---|
| `StoreLogo.png` | 50×50 | `Properties/Logo` |
| `Square44x44Logo.png` | 44×44 | `VisualElements/Square44x44Logo` |
| `Square150x150Logo.png` | 150×150 | `VisualElements/Square150x150Logo` |
| `Wide310x150Logo.png` | 310×150 | `DefaultTile/Wide310x150Logo` |

The gate is not decorative — `windows/msix/gate-selftest.sh` proves it *fires* by injecting a
tainted tile and requiring the check to reject it.

### Missing — state plainly

1. **The tiles are placeholder art.** A brand-neutral node-graph motif, generated by
   `gen-assets.mjs`. Format- and dimension-correct so the pack cannot fail on assets, but it is
   not final product art. Final art drops in over the same four filenames; the pack will then
   refuse to overwrite it (bootstrap keys off existence, the hard gate keys off drift).
2. **`assets/app-mark.svg` is NOT wired in.** It is the real Circuit hex-chip mark, but it
   carries `aria-label="Black Label Circuit"` — a cross-brand string in a file destined to
   become Store-facing art. Strip that before rasterizing. No SVG rasterizer is installed on
   this machine, so nothing was rasterized rather than guess at the output.
3. **Store listing assets do not exist at all.** These are uploaded in the Partner Center
   listing, not packed into the MSIX:
   - **Screenshots — required.** Minimum 1, 1366×768 or 1920×1080 PNG. Not produced.
     The spike lane already screenshots the running UI on a Windows runner
     (`circuit-ui-windows.png` at 1400×900) — that is the obvious source, but it is the wrong
     dimensions as configured and has never been reviewed as a listing asset.
   - **Store display logo — recommended.** 300×300 PNG. Not produced.
   - Description, short description, privacy policy URL, age rating questionnaire,
     support contact: all unwritten.

---

## 5. Manifest facts a reviewer will ask about

- `TargetDeviceFamily Windows.Desktop MinVersion 10.0.17763.0` — Win10 1809, the floor where
  the WebView2 Evergreen Runtime is supported.
- **No WebView2 `<PackageDependency>`.** WebView2 is a *system* runtime, not a Store framework
  package; declaring it would fail `makeappx`. Provisioning WebView2 on clean Win10 images is
  the one tracked residual.
- `rescap:Capability runFullTrust` is the **only** capability. Circuit is a packaged Win32
  (Tauri) app that spawns a bundled `node.exe` sidecar, which requires it. The app makes no
  outbound network calls and touches no data broker, so no networking or broadFileSystem
  capabilities are requested. Expect the restricted-capability justification prompt at
  submission; the answer is the node sidecar.
- `Version` revision (4th part) must be `0` — the Store reserves it. `build-msix.sh` rejects
  any `PARTNER_CENTER_PACKAGE_VERSION` that violates this.

---

## 5b. One placeholder outside the MSIX path

`windows/src-tauri/tauri.conf.json` → `bundle.publisher` and `windows/src-tauri/Cargo.toml` →
`authors` both carry `__PUBLISHER_DISPLAY_NAME__`. They previously held a hardcoded company
name, which is wrong for an individual Partner Center account.

Neither affects the Store MSIX — they only surface in the **NSIS direct-download installer**
(`build-win.sh`), which is the cert-blocked fallback path, not the Store path. If that path is
ever revived, replace both with the same legal name before building; the literal token would
otherwise appear in installer metadata. It is deliberately loud rather than quietly wrong.

---

## 6. What is still blocked

| Blocker | Blocks | Owner |
|---|---|---|
| Partner Center account not verified | Everything. No app name reserved ⇒ no identity values ⇒ every package is `IDENTITY-PLACEHOLDER`. | Owner |
| The three identity values | A submittable package. The lane is complete and waiting for §2. | Owner, after verification |
| Store listing assets (screenshots, description, privacy URL, age rating) | Submission — Partner Center will not let the submission proceed without them. | Owner / producer |
| Final tile art + `app-mark.svg` cross-brand label | Nothing technically; the placeholders pack. Ships ugly. | Producer |
| No Authenticode cert | **Sideload / direct-download distribution only.** Does not block the Store path — the Store signs. | Owner (money gate) |
| Tauri shell build never run on a Windows runner | A `REALEXE` package. Until the `shell` job goes green, the `msix` job packs a placeholder exe and labels the artifact `PLACEHOLDEREXE`. Never submit a `PLACEHOLDEREXE` package. | Engineering |

---

## 7. Note on the `winapp` CLI

Microsoft's `winapp` CLI (public preview) supports Tauri and can do MSIX packaging, manifest
generation, and cert generate/sign, and is installable in CI via the `setup-WinAppCli` action.
It was **not** adopted here, deliberately:

- The `makeappx` path in this repo is *proven* on a real GitHub-hosted Windows runner
  (Circuit run `30873216479`). Replacing a proven lane with an unproven one, in a lane whose
  whole purpose is to be ready the moment the account verifies, trades certainty for nothing.
- Its exact flag syntax is not something to reproduce from memory. Writing plausible-looking
  flags into a workflow that has never run is how a lane looks finished and is not.

If it is adopted later, do it as a *second* job alongside the `makeappx` job, compare the two
outputs on a real runner, and only then delete anything. Verify the action name, version, and
every flag against current Microsoft docs before committing — none of that is asserted here.
