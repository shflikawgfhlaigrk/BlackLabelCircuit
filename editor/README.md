# Circuit — editor integration (LSP)

In-editor live re-grade (CI-21). The same senior-engineer review that drives
Circuit's 3D graph, surfaced as diagnostics inside your editor and a repo grade
in the status bar. Save a file → Circuit re-grades and the squiggles update.

## What's here

| File | Role |
|---|---|
| `server.mjs` | Zero-dependency **stdio LSP language server**. Speaks the LSP JSON-RPC wire protocol by hand (Content-Length framing) — no `vscode-languageserver` package. On open/save it runs the real `../lib/analyze.js` and publishes diagnostics + a `circuit/status` grade. |
| `diagnostics.mjs` | Pure mapping `finding → LSP diagnostic` (range, severity, dimension, points) and `graph → status text`. Unit-tested in `../test/editor.test.js`. |
| `extension.js` | Thin VS Code client — spawns the server, forwards open/save, renders diagnostics into a `DiagnosticCollection` and the grade into a status-bar item. Only imports are the host `vscode` API + Node builtins. |
| `package.json` | The VS Code extension manifest. |

## How findings map to diagnostics

Every diagnostic is a genuine finding from `analyzeRepo` — nothing is invented.

- **Range** — the finding's 1-based line → 0-based whole-line range (the editor clamps the end column).
- **Severity** — `critical → Error`, `major → Warning`, `minor → Information`, `info → Hint`.
- **Message** — carries the **dimension**, **severity** and **point deduction**, e.g.
  `safety · critical · −12 pts — Empty catch block swallows the error silently…`
- **Code / source** — `code` is the dimension, `source` is `circuit`.

## Run the server standalone

```sh
node editor/server.mjs /path/to/repo      # stdin/stdout = the LSP stream
# or, via the main CLI:
node ../server.js --lsp /path/to/repo
```

## Use in VS Code

1. Copy (or symlink) this `editor/` folder into `~/.vscode/extensions/circuit-editor/`.
2. Reload VS Code. The extension activates on startup, spawns the server for your
   workspace, and starts grading on save. The status bar shows e.g. `Circuit: B (84)`.

The client runs the server on the Code binary in Node mode (`ELECTRON_RUN_AS_NODE`),
so no separate `node` install is required.

## Offline

The server is Node stdlib + Circuit's analyzer only. It opens **no** network
connection — `../test/editor.test.js` asserts the `editor/` source is free of any
egress API, the same guarantee `test/airgap.test.js` enforces for the backend.
