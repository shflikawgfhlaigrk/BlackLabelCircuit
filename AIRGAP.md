# ⏚ Circuit — Air-Gapped / Offline Deployment

Circuit is built to run in the most locked-down environments there are: no internet,
no telemetry, no code ever leaving the machine. This document is the install guide for
air-gapped hosts **and** the attestable no-network statement your security team can
verify for themselves.

## Attestable no-network statement

> **Circuit makes zero outbound network connections. Your source code is analyzed
> entirely on the local machine and is never transmitted anywhere.**

This is not a marketing promise — it is a property you can prove from the source, in
under a minute, before you trust the tool with a single file:

1. **Source scan (the CI-15 proof).** Grep the entire backend for any network-egress
   API. The result is empty:

   ```sh
   grep -rnE 'https?\.request|fetch\(|net\.connect|dns\.|XMLHttpRequest|WebSocket' \
     server.js lib/ | grep -v createServer || echo "NONE — no outbound network"
   ```

   The only networking call in the codebase is `http.createServer(...)` — an inbound
   local server, never an outbound client.

2. **Automated attestation.** The same scan runs as a test, so the guarantee cannot
   silently regress:

   ```sh
   npm test            # includes test/airgap.test.js
   ```

   `test/airgap.test.js` fails the build if any egress API (`fetch`, `http.request`,
   `net.connect`, `dns.*`, `WebSocket`, `XMLHttpRequest`, …) ever appears in the
   backend source.

3. **Loopback-only binding.** The server binds `127.0.0.1` only (`server.js`), so the
   UI is reachable from the host and nowhere else. Confirm at runtime:

   ```sh
   lsof -iTCP -sTCP:LISTEN -n -P | grep circuit   # bound to 127.0.0.1, not 0.0.0.0
   ```

4. **No third-party runtime dependencies.** The backend is Node standard library only.
   The 3D frontend stack (three.js + 3d-force-graph + spritetext + bloom) is vendored
   into `public/vendor/circuit-3d.bundle.mjs` — no CDN fetch, no npm install at run
   time. Verify:

   ```sh
   grep -rhoE "from '[^']+'" server.js lib/ | grep -vE "node:|\./" \
     || echo "ZERO third-party backend imports"
   ```

5. **Fail-closed licensing.** License resolution never phones home; with no valid key
   it fails *closed* to a local demo mode. Nothing about running Circuit requires a
   network.

## Offline install

Circuit has **no build or install step that needs the internet** once you have the
repository on the host. The 3D bundle is committed, so there is nothing to download.

### 1. Move the repository onto the air-gapped host

Transfer the whole `Circuit/` directory over your approved channel (physical media,
one-way data diode, internal artifact mirror). Everything needed to run is in the tree:

- `server.js`, `lib/` — the zero-dependency Node backend.
- `public/` including `public/vendor/circuit-3d.bundle.mjs` — the pre-bundled 3D UI.

`node_modules/` is **only** needed to *rebuild* the vendor bundle (`esbuild`); it is
not needed to run. You can delete it on the air-gapped host.

### 2. Requirement: Node.js ≥ 18

Circuit uses only Node's standard library and the built-in test runner. Any Node 18+
already approved in your environment works — no packages to install.

```sh
node --version    # v18 or newer
```

### 3. Run

```sh
node server.js /path/to/repo            # grade a repo; open the printed localhost URL
node server.js /path/to/repo --port 9000
```

Or headless, for an offline CI runner:

```sh
node server.js --check /path/to/repo --min-grade B --sarif circuit.sarif
```

### 4. (Optional) Rebuild the vendor bundle on a connected host

Only if you are upgrading the 3D stack. Do this on a network-connected build host,
then ship the resulting `public/vendor/circuit-3d.bundle.mjs` to the air-gapped host:

```sh
npm install          # pulls esbuild + three (build-time only)
node build-vendor.mjs
```

## In-app confirmation

When Circuit is running, the top bar shows a persistent
**`⏚ offline — no code leaves this machine`** chip. Hover it for the full posture
statement. It is always on because the offline guarantee is unconditional — there is
no online mode to switch out of.

## Summary for auditors

| Property | How to verify | Result |
|---|---|---|
| No outbound network calls | source grep (step 1) / `npm test` (step 2) | none |
| Bound to localhost only | `lsof` (step 3) | `127.0.0.1` |
| No third-party runtime deps | import grep (step 4) | zero |
| No license phone-home | fail-closed demo mode | offline |
| No install-time downloads | vendored `public/vendor/` bundle | committed |
