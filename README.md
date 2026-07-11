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
- Repos >4000 files are truncated (noted in the UI stats).
- Rendering pauses when the tab is hidden — zero background CPU.

## Test

```sh
npm test   # 14 tests over a fixture repo with known defects
```
