# ⏚ Circuit

**Grade your codebase like a senior engineer. See the wiring in 3D.**

Point Circuit at any repo. It parses every file, maps what's wired to what
(imports, type references), grades each file across six dimensions the way a
senior reviewer would, and renders the whole thing as a live 3D force graph —
Obsidian's graph view, but 3D, glowing, and it knows where your code is broken.

![grade ramp](https://img.shields.io/badge/A-green) → red, per file. Broken wires glow crimson.

## Run

```sh
node ~/Circuit/server.js /path/to/repo        # default port 8923 (auto-increments if taken)
node ~/Circuit/server.js /path/to/repo --port 9000
```

Open the printed URL. Leave it running while you code — Circuit watches the
repo and re-grades live on every save (the toast tells you the new grade).

## CI / headless grade gate

Run Circuit in a pipeline with `--check` — it grades the repo, prints the result,
and exits without ever starting the HTTP server:

```sh
node ~/Circuit/server.js --check /path/to/repo                      # print grade, exit 0
node ~/Circuit/server.js --check /path/to/repo --min-grade B        # exit 1 if the repo grades below B
node ~/Circuit/server.js --check /path/to/repo --sarif circuit.sarif  # write SARIF findings for annotations
```

- `--check` runs `analyzeRepo` once and exits — no server, no file watching.
- `--min-grade <G>` gates the build: exit `0` when the repo grade is at least `<G>`
  (`A+` … `F`), exit `1` when it is below. An empty repo (no gradeable source) has
  **no grade** and therefore never passes a threshold — it fails honestly rather
  than being minted a pass.
- `--sarif <file>` writes a [SARIF 2.1.0](https://sariftools.github.io/sarif/) log:
  every file-level finding becomes a line-anchored result (rule `circuit/<dimension>`,
  level error/warning/note), so GitHub code scanning / PR checks render them inline.
  Passing `--min-grade` or `--sarif` implies `--check`.

Example GitHub Actions step:

```yaml
- run: node Circuit/server.js --check . --min-grade B --sarif circuit.sarif
- uses: github/codeql-action/upload-sarif@v3
  if: always()
  with: { sarif_file: circuit.sarif }
```

## What you see

- **Nodes** = files. Size ∝ lines of code. Color = grade (green A → red F, validated ramp).
- **Wires** = imports (JS/TS/Python/Go/Rust/Java) and type references (Swift). Particles flow in the dependency direction.
- **Red octahedra** = phantom nodes: files that are imported but don't exist. Every red wire is a broken import.
- **Click a node** → the report card: grade, six dimension scores, findings written
  as review comments with line numbers, everything it's wired to (both directions),
  external packages, and a source view with finding lines highlighted.
- **Sidebar** → repo grade + verdict, grade histogram (click to filter), language
  filters, worst offenders, view toggles (labels / flow / 2D / broken-only).
- `/` to search. `Esc` to close. Click background to deselect.

## The rubric

Six weighted dimensions, each 0–100:

| Dimension | Weight | Looks at |
|---|---|---|
| Complexity | 25% | nesting depth, branch density |
| Safety | 20% | empty catches, `try!`/`as!`, bare `except`, `any`, `@ts-ignore`, eval, mutable defaults, parse errors |
| Structure | 15% | god files, god functions |
| Hygiene | 15% | TODOs, debug prints, commented-out code, long lines |
| Coupling | 15% | broken imports, fan-out, import cycles (Tarjan SCC) |
| Docs | 10% | documented public symbols, comment coverage |

Severity compounds: criticals and majors drag the whole grade beyond their
dimension — a senior engineer doesn't average away a critical. A file that
doesn't parse can't grade above F. Repo grade is the LOC-weighted mean minus
a penalty per broken wire. Churn hotspots (git history × bad grade) get called
out as the place refactoring pays off first.

## Architecture rules

Drop a `.circuit-rules.json` at the repo root to declare **forbidden dependencies**
between parts of your codebase. Circuit resolves them over the real import graph it
already builds — a violation is a genuine resolved import that crosses a boundary you
declared off-limits, never a heuristic guess.

```json
{
  "forbidden": [
    { "from": "src/ui/**", "to": "src/db/**",
      "name": "UI must not reach into the DB layer",
      "severity": "critical", "points": 25 },
    { "from": "src/**", "to": "test/**" }
  ]
}
```

- `from` / `to` are POSIX path globs (`*` within a segment, `**` across segments,
  `**/` for any leading segments). Both are required.
- `name` (optional) prefixes the finding; `severity` (`critical`|`major`|`minor`|`info`,
  default `critical`) and `points` (1–100 coupling deduction, default 20) are optional.
- Each violation becomes a **line-anchored Coupling finding** on the offending file
  (it drags the grade through the same critical/major compounding as any other finding)
  and a **red edge** in the 3D graph, so you can see the forbidden crossing at a glance.
- **Zero violations → zero findings.** No rules file → the analysis is exactly as it
  is without one. Rules are enforced in `--check` / SARIF CI mode too.

## Editor integration (live re-grade)

Circuit ships a **language server** so the same review shows up *in your editor*,
not just the 3D view. It's a zero-dependency stdio **LSP** server driven by the
exact same `analyzeRepo` — save a file and Circuit re-grades the repo, surfaces
each finding as a line-anchored diagnostic (carrying its dimension, severity and
point deduction), and shows the repo grade in the status bar.

```sh
node ~/Circuit/server.js --lsp /path/to/repo   # stdin/stdout speak LSP
```

The VS Code client is in [`editor/`](editor/) — see [editor/README.md](editor/README.md).
Like the rest of Circuit it makes **zero network calls**; your source never leaves
the machine.

## Languages

Deep (wiring + language-specific signals): **JavaScript/TypeScript, Python, Swift,
Go, Rust, Java, Kotlin, Ruby** (Swift wiring is type-reference based — no file
imports in Swift — so it's heuristic; Go resolves package paths via `go.mod`, Rust
resolves `mod`/`use` against the module layout, Java resolves fully-qualified
imports via `package` + FQN, Kotlin resolves `import` against declared packages and
top-level symbols, Ruby resolves `require_relative` against the on-disk layout).
Light (metrics + universal signals): C/C++/Obj-C, shell,
CSS, HTML, JSON (validity-checked), YAML, TOML.

## Design notes

- Zero runtime dependencies server-side; the 3D stack (three + 3d-force-graph +
  spritetext + bloom) is bundled once into `public/vendor/circuit-3d.bundle.mjs`
  (`node build-vendor.mjs` to rebuild). Fully offline.
- Analysis is regex-heuristic by design: ~1200 files in <1s, no compilers, no
  language servers. It grades like a reviewer skimming, not a type checker.
- Repos >4000 files are truncated (surfaced as a `truncated` chip in the UI
  stats); files that can't be parsed or read are counted and shown too, so a
  grade is never silently computed over a partial view of the repo.
- Rendering pauses when the tab is hidden — zero background CPU.

## Air-gapped / offline use

Circuit is **offline by default** and safe for regulated, air-gapped environments —
your source code never leaves the machine:

- **Zero outbound network calls.** The backend is Node stdlib only; it opens no HTTP
  client, no socket, no DNS. This is an *attestable* claim, not a promise: the CI-15
  source scan and `npm test` (`test/airgap.test.js`) fail the build if any
  network-egress API appears in the backend source.
- **Loopback-only.** The server binds `127.0.0.1` — nothing is exposed off-box.
- **No CDN, no telemetry, no license phone-home.** The 3D stack is vendored into
  `public/vendor/`; licensing fails *closed* to demo mode with no network required.
- **In-app indicator.** The top bar shows an always-on `⏚ offline — no code leaves
  this machine` chip so an auditor can confirm the posture at a glance.
- **One scoped exception: the macOS app's update check.** The desktop wrapper (not
  the server) checks `blacklabelbots.com` for app updates on launch/daily — version
  metadata only, never source. Turn it off via **Circuit → Automatically Check for
  Updates**; running `node server.js` directly involves no updater at all.

See **[AIRGAP.md](AIRGAP.md)** for offline install steps and the full attestable
no-network statement.

## Test

```sh
npm test   # unit + integration tests over a fixture repo with known defects
```

### Local access and sign-in

Private repository APIs require an authenticated per-launch session. Circuit prints a one-use sign-in URL (valid for 60 seconds); the macOS and Windows launchers open that exact URL. The browser clears its fragment immediately and exchanges it for an HttpOnly, SameSite=Strict cookie that expires after one hour. Sign out revokes the session and closes its live event stream. To sign in again, open Circuit and select the repository again (command-line users restart their server), then open or paste the fresh link. Previously opened plain localhost URLs do not grant access.

Native API integrations may supply a fresh unpredictable `CIRCUIT_OWNER_KEY` (32–256 URL-safe characters) in the server environment and send it as a Bearer header. Never put that key in a URL. JSON mutations also require `X-Circuit-Request: 1`. Only exact localhost/127.0.0.1 authority and port are accepted; browser mutations require the same Origin. Headless `--check`, SARIF and stdio `--lsp` remain local command-line operations without HTTP authentication.

The startup capability is short-lived and should be kept private. The native macOS launcher redacts it from its persistent log; the legacy shell launcher uses a private temporary log. The HTTP shell never supplies a capability. The server binds only loopback and adds no outbound calls.
