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

## Languages

Deep (wiring + language-specific signals): **JavaScript/TypeScript, Python, Swift,
Go, Rust, Java** (Swift wiring is type-reference based — no file imports in Swift —
so it's heuristic; Go resolves package paths via `go.mod`, Rust resolves `mod`/`use`
against the module layout, Java resolves fully-qualified imports via `package` + FQN).
Light (metrics + universal signals): Kotlin, Ruby, C/C++/Obj-C, shell,
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

## Test

```sh
npm test   # unit + integration tests over a fixture repo with known defects
```
