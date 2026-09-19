# Circuit MCP server

Exposes Circuit's code-grading engine over MCP (JSON-RPC 2.0 over stdio).

Two tools, both **read-only**:

| Tool | What it does |
|---|---|
| `circuit__grade_repo` | Grades a directory tree — letter grade, weighted score, and full stats (files, LOC, edges, broken edges, cycles, grade histogram, language mix, parse errors, skipped files). Optional `min_grade` threshold returns `pass` + the CI exit code. |
| `circuit__get_graph` | Returns the dependency graph — nodes (per file: grade, score, LOC, fan-in/fan-out, churn, cycle membership, findings) and links (import edges, broken ones first). |

## Configuration

Add this to your MCP client config (`claude_desktop_config.json`, or `.mcp.json` for
Claude Code). Paths must be absolute.

```json
{
  "mcpServers": {
    "circuit": {
      "command": "node",
      "args": ["/Users/michaelbarber/Circuit/mcp/server.mjs"]
    }
  }
}
```

No environment variables are required. Neither tool is gated, because neither has a
side effect to gate — there is nothing to unlock.

Optional: set `MCP_LOG_LEVEL` to `silent`, `error`, `warn`, `info` (default) or `debug`
to control the server's stderr logging. stdout carries the protocol only.

## Tool reference

### `circuit__grade_repo`

| Argument | Type | Required | Notes |
|---|---|---|---|
| `root` | string | yes | Absolute (or `~`-relative) path to the tree to grade. |
| `min_grade` | string | no | One of `F, D-, D, D+, C-, C, C+, B-, B, B+, A-, A, A+`. When set, the result adds `pass` and `exit_code`. |

The result always carries `walk_truncated`. When it is `true` a `partial_view_warning`
is included as well: the grade covers only the files the walker read, so `pass` is a
pass over part of the tree.

```jsonc
// arguments
{ "root": "/Users/michaelbarber/Circuit", "min_grade": "B" }
```

### `circuit__get_graph`

| Argument | Type | Required | Notes |
|---|---|---|---|
| `root` | string | yes | Absolute (or `~`-relative) path to the tree to analyze. |
| `max_nodes` | integer | no | Default 100. `0` = no cap. Nodes are sorted worst score first, so a truncated view still shows the problems. |
| `max_links` | integer | no | Default 200. `0` = no cap. Broken edges are sorted first. |
| `include_findings` | boolean | no | Default `true`. Set `false` for a lighter payload (`findingCount` is always present). |

The response always states `node_count` / `link_count` alongside `nodes_returned` /
`links_returned` and the `nodes_truncated` / `links_truncated` flags, so a capped view
can never be mistaken for the whole graph.

## Design notes

**Backed by the modules, not the HTTP server.** `server.mjs` imports
`../lib/analyze.js` (`analyzeRepo`) and `../lib/report.js` (`meetsMinGrade`) directly.
Circuit's HTTP server is pinned to one repo at process start; calling the modules lets
every tool call target a different tree. This MCP server never binds or contacts a
port, so the hands-off instance on `:8923` is untouched.

`grade_repo` deliberately does *not* call `runCheck()`: that wrapper drops the walker's
`truncated` flag, and its only other job — writing SARIF — is dead here because
`sarifPath` is forced to `null`. The handler inlines the remaining threshold logic
(`meetsMinGrade` + exit code), which is byte-for-byte equivalent to `runCheck` on
`empty` / `grade` / `score` / `pass` / `exitCode` / `stats` (verified across 28
tree × `min_grade` combinations) and additionally exposes truncation.

**`root` must be absolute.** A relative `root` is refused (`ROOT_NOT_ABSOLUTE`) rather
than resolved against the server process's working directory — that directory is chosen
by whichever client spawned the server, so the same argument would otherwise grade
different trees in different clients. `~` and `~/…` are expanded.

**A partial view is never reported as a whole one.** Circuit's walker caps how many
source files it reads. When that cap trips, both tools set `walk_truncated: true`, and
`grade_repo` also returns a `partial_view_warning` stating that the grade, score, stats
and any `pass`/`exit_code` describe only the files that were read. Without it a large
repo can come back `A+ / pass: true` while the files that would have sunk it were
dropped before analysis.

**Never writes.** `runCheck` is always called with `sarifPath: null`. A caller-supplied
output path (`sarif_path`, `sarifPath`, `sarif`, `out`, `output`, `output_path`,
`write_to`) is *refused* with a `WRITE_PATH_REFUSED` error rather than silently
ignored. Use Circuit's CLI if you need a SARIF file on disk.

**One analysis at a time.** `analyzeRepo` is CPU-bound and fully synchronous, so calls
are queued behind one another (concurrency limit 1). Every response carries a
`concurrency` block — `limit`, `in_flight_during_this_call`, `queued_behind_this_call`,
`max_in_flight_observed_since_start` — plus `queue_wait_ms` and `analysis_ms`, so the
cap is observable rather than asserted. Per-call timeout is 10 minutes.

**Empty is empty, not an A+.** A tree with no gradeable source comes back as a
verified zero result (`status: "empty"`, `grade: null`, `score: null`) with the real
reason attached — never a fabricated passing grade, and never a bare empty list from
an error path. Failures return `isError: true` with the actual error message and code.

## Files

- `server.mjs` — the server (tool definitions + handlers).
- `mcp-kit.mjs` — vendored MCP stdio kit, copied verbatim, imported by relative path.
  Do not edit it here; it is a copy, not a fork.
