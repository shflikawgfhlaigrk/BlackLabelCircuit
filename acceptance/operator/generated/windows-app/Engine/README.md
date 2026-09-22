# Black Label Operator Engine

Operator Engine is the local, durable execution layer for Black Label Operator.
It can dispatch work to Codex, Claude Code, Gemini CLI, OpenCode, Grok Build,
Hermes, OpenClaw, or a custom argv-based CLI while keeping task state,
dependencies, checkpoints, verification, and artifacts in one local ledger.

## Execution Contracts

The local `adaptive` profile is a bounded
planner/executor/verifier/critic/arbiter loop. The independent critic always
runs, including after green verifier commands, and runs read-only. It must
return strict JSON with exactly `recommendation`, `summary`, `issues`, and
`evidence_refs`. Scalar and list types are exact, and non-finite JSON numbers
are rejected. A round is accepted only when execution completed, every required
verification receipt passed, the critic reported no issues, and the critic
cited every passing required receipt. A malformed verdict or critic veto
replans while budget remains, then stops fail-closed. Continued adaptive tasks
resume distinct planner, executor, and critic provider sessions through one
bounded opaque continuation token; a stage event cannot replace that parent
token.

The retained macOS source binds conversation intent before submission. New
conversations default to Codex CLI `gpt-5.6-sol`; explicitly selected alternate
Ask routes, attached-file Ask, automations, and custom-agent Ask stay on their
selected direct read-only adapter:

- Ask: profile `safe`, provider `codex`, model `gpt-5.6-sol`, effort `high`,
  read-only sandbox, shared isolation, one attempt, and no verifier.
- Act: profile `adaptive`, provider `codex`, model `gpt-5.6-sol`, effort `high`,
  workspace-write sandbox, worktree isolation, one attempt, and required
  `git diff --check`.

For Act, `git diff --check` is structural verification only. It catches patch
format defects but does not establish task-specific correctness; the mandatory
critic may still reject or replan the result.

Release acceptance is stricter than provider support: all five benchmark
families, including both the current and retained-comparability Terminal-Bench
lanes, run through Codex with the exact model `gpt-5.6-sol`. The
`sol-benchmark` profile rejects provider, model, or profile substitution before
a task starts.

## Benchmark Acceptance

Black Label Operator has **no full public benchmark score and no verified
leaderboard score yet**. Historical full attempts are source-mismatched or
provider-contaminated diagnostics and are not scores. A selected task reward of
`1.0` means that task passed; it does not mean the harness scored 100% on the
benchmark. HarnessBench is internal and is not comparable to a public
leaderboard.

`official_quality.good` is a separate fail-closed evidence gate. It is true
only when Operator holds exactly five organizer-issued or independently
organizer-verified scores, each natively reported by its organizer on a 0-100
scale and each at least 91: `terminal-bench-2-official`,
`terminal-bench-4-current`, `aider-polyglot-stock`,
`swe-bench-verified-500` over all 500 tasks, and
`arc-agi-3-standardized`. Every lane must pass independently. Operator does not
average the scores, rescale or convert another metric, or promote internal,
smoke, selected-task, partial, self-reported, or locally computed results. This
gate neither depends on nor changes `number_one`.

Each accepted organizer receipt has a closed, lane-specific full-suite schema.
The organizer signature covers the campaign ID and creation time, exact
`gpt-5.6-sol` provider/model/profile identity, complete frozen Operator source
identity, immutable benchmark identity and full score scope, accepted or
published status, and the direct organizer-reported score. Unknown fields and
duplicate JSON object keys are rejected. Verification must occur no earlier
than the campaign (allowing five minutes of clock skew), no more than five
minutes in the future, and no more than seven days before evaluation. For a
campaign-backed lane, the signed `score_scope.execution_config` must also equal
the campaign's pinned `reasoning_effort` and `review_passes`.

The primary status view selects the latest protocol-v2 campaign by creation
time among campaigns embedding the exact current official-quality contract. It
then requires that campaign's frozen source tree SHA-256 and file count to match
the current Engine source. A source change retires earlier evidence from the
current-quality view; historical campaigns remain audit records. Current
provenance readiness is **1/5**: only `terminal-bench-4-current` is ready.
Terminal-Bench 2 still lacks a pinned evaluator and runner revision; stock Aider
still lacks pinned edit format, reasoning effort, and concurrency; SWE-bench
Verified still lacks a pinned evaluator revision and immutable runtime; and
ARC-AGI-3 still lacks a standardized model-config ID and canonical hashes. All
five organizer trust roots are unconfigured, so the organizer-verified result
is still **0/5**, all five scores are `N/A`, and `official_quality.good` is
false. The prior campaign is stale and its LaunchAgent is unarmed.

Terminal-Bench 4 provenance separately binds the raw `tasks/dataset.toml` file
SHA-256
`ecd296ba053840bd4c0068e8f84e8a6fa829d184d0fd9852becdc19f4c895fcf`, the
resolved Harbor manifest SHA-256
`4740ea3d60ebef3843f149ee5f91be6c4caad869d4b111299b05a298c3f4e4be`, and the
comparable 66-task-name manifest SHA-256
`da42796db57719d0e8f6994c77231ce2ace97e5fd57fe5ca1c5eb44011bea6c5`. Its
official-quality score scope is exactly 66 tasks x 5 attempts with
`reasoning_effort: xhigh` and `review_passes: 2`.

Version `0.7.0` added an immutable, resumable five-suite campaign. It freezes the
exact source bytes, pins every official Harbor task identity, accepts the first
clean result for each task, rejects provider and source substitution, and
certifies only when all five thresholds are met. Quota and infrastructure
failures remain pending rather than becoming model failures or passes.

Version `0.7.1` hardens that evaluator: SWE-bench verifier dependencies are
prepared before scoring, time-sensitive leap-second data is pinned, known
verifier bootstrap faults stay incomplete, Terminal-Bench checks plausible
idiomatic interfaces when a task underspecifies its signature, and ARC-AGI-3
uses bounded concurrency with transport backoff.

Version `0.7.2` makes the persistent campaign resource-aware and fixes ARC game
continuity. The launchd supervisor waits above a CPU-scaled load ceiling, runs
one suite at a time, and caps Docker-heavy suites independently. ARC now routes
turns through official `previous_response_id` state, binds retrying requests to
the public game identifier, and preserves one durable planner workspace per
game. Campaign status uses suite-local receipt discovery instead of recursively
walking every trial artifact.

Version `0.7.3` bounds each Harbor invocation and rotates Aider, Terminal, and
SWE shards after HarnessBench passes. This prevents one large suite from
monopolizing the persistent supervisor while retaining suite-specific batch and
concurrency limits. ARC remains the final full-suite gate.

Version `0.7.4` retries official Harbor dataset-manifest resolution with a
bounded ten-minute attempt timeout. A transient registry or host-load timeout
cannot abandon campaign initialization after a single short probe.

Version `0.7.5` fixes ARC context rotation against Codex's cumulative token
accounting. Cached tokens no longer force a fresh thread after the first turn;
only uncached context growth contributes to the explicit rotation budget.

Version `0.7.6` runs every pinned public Harbor task through implementation,
independent correctness review, and final conservative arbitration. The
campaign receipt records all three exact-Sol passes while Harbor grades only
the resulting workspace.

Version `0.7.7` preserves the requested workspace root and sandbox policy when
resuming a Codex thread. ARC continuations can now update their durable
playbook, world model, and planner instead of silently falling back to a
read-only resumed session.

Version `0.7.8` keeps each top-level benchmark shard inside the dedicated
LaunchAgent process group.

Version `0.7.9` extends that supervised process-group contract through nested
Codex, external CLI, Harbor, HarnessBench, and ARC subprocesses while preserving
independent recovery sessions for ordinary 24/7 Operator tasks.

Version `0.8.0` adds the evidence-gated adaptive execution profile, continuous
generation-fenced leases, attempt-fenced state transitions, shared-workspace
writer serialization, process-group recovery quarantine, task-attributable
workspace evidence, and a content-addressed immutable install. It also makes
the pinned Terminal-Bench 4.0 protocol mandatory alongside the retained
Terminal-Bench 2 comparison lane and hardens ARC sessions for deterministic,
idempotent continuation. No `0.8.0` public score is claimed until the frozen
source completes every required trial.

Version `0.8.1` removes guessed ARC actions and makes interactive planning
fail closed. Every action now binds to competing receipt-backed hypotheses, a
hash-locked executable world model, two matching fresh-process full-frame
traces, and a parent-computed immutable plan. Model code cannot choose or forge
the released action: the trusted parent replays the exact source, checks the
complete observed prefix, and releases one action at a time. Durable ledgers
also reject duplicate keys and non-canonical JSON. No `0.8.1` public score is
claimed before a frozen full-suite run completes.

Version `0.8.2` makes the installed Python runtime self-contained and
relocatable, binds every internal runtime symlink, and admits only the exact
interpreter chain and runtime roots needed by isolated verification. A release
therefore survives removal of the temporary wheel environment that created it,
while verifier commands still fail closed outside their admitted source,
runtime, and output roots. No `0.8.2` public score is claimed before a frozen
full-suite run and organizer-backed benchmark submission complete.

Version `0.8.3` adds app-safe, exclusive idempotent submission. MCP callers may
send a canonical `client_request_id` UUID and `require_idle: true`; one SQLite
write transaction either returns the exact existing task, admits one task only
when no queued or running work exists, or returns `state: "busy"` without
enqueuing. Reusing an idempotency key with any changed request field fails
closed, and task/list responses preserve the client request identity.

Version `0.8.5` adds explicit conversation continuation to `operator_submit`.
Callers may bind an existing provider `thread_id` and set `continue_thread: true`;
both values are included in the idempotent request identity, validated before
admission, and passed to the existing durable Codex resume path. Continuation
without an exact thread ID fails closed.

Run `operator benchmark status` for the machine-derived coverage record. See
[CURRENT-BENCHMARK-STATUS.md](docs/CURRENT-BENCHMARK-STATUS.md) for the dated
evidence snapshot.

## Core Commands

```sh
./bin/operator install
operator doctor --live
operator providers
operator ide --cwd ~/repo
operator tui --cwd ~/repo
operator run --profile sol --cwd ~/repo "Fix the defect and run the tests"
operator submit --profile build --isolation worktree --verify "make test" \
  --cwd ~/repo "Implement the queued feature"
operator submit --profile adaptive --isolation worktree --verify "make test" \
  --cwd ~/repo "Implement, verify, critique, and conservatively accept the change"
operator submit --profile adaptive \
  --verify-spec '{"command":"npm test","writable_paths":["dist","coverage"]}' \
  --cwd ~/repo "Ship the change with isolated build outputs"
operator list
operator schedule add --name nightly --every 1d --cwd ~/repo \
  "Review failures and repair verified regressions"
operator benchmark campaign init --threshold 91
operator benchmark campaign status
operator benchmark official-quality ingest \
  --campaign <campaign-id-or-path> \
  --lane <one-of-the-five-contracted-lanes> \
  --organizer-receipt /absolute/path/to/signed-organizer-receipt.json
operator benchmark campaign arm --batch-size 8 --n-concurrent 1
operator benchmark campaign armed
operator benchmark campaign certify
```

`operator install` builds and activates one verified, content-addressed release
tree and creates the dedicated LaunchAgent `com.blacklabel.operator`. It does
not restart or signal the shared Codex app server. Durable state defaults to
`~/.blacklabel-operator`.

`operator benchmark campaign arm` creates the separate
`com.blacklabel.operator.benchmark-campaign` LaunchAgent. It sleeps until a
recorded Codex quota reset, resumes pinned shards from the first pending task,
and exits only when every required lane certifies or the frozen source must be
revised.

`operator benchmark official-quality ingest` validates the signed receipt
before creating one read-only, hash-addressed artifact and its exclusive
evidence wrapper. Each campaign lane can be ingested only once; any second
attempt is rejected. With the current organizer trust roots unconfigured, the
command fails closed without creating score evidence.

## Surfaces

- CLI for foreground, detached, scheduled, and dependency-linked work.
- Local MCP stdio server for Antigravity, Codex, Claude, and other MCP clients.
- Antigravity workspace launcher with the installed Codex extension API grant.
- Local Responses-compatible bridge for an optional Grok Build TUI and ARC.
- SQLite WAL task, event, client, artifact, dependency, and schedule ledger.
- Shared-directory or isolated git-worktree execution with explicit apply.
- Lifecycle hooks and ordered verification commands that fail closed.
- Restart recovery for resumable sessions and conservative failure for
interrupted providers whose side effects cannot be replayed safely.

The hosted Cloudflare harness is a separate product surface. The current source
candidate can return one synchronous `verified_single_pass` receipt with
command-only verification and pre/post workspace manifests; it does not run
this Engine's adaptive rounds. That source candidate is not a production claim
until deployed and remotely verified.

The local MCP exposes `operator_adaptive_start`, `operator_adaptive_status`,
and `operator_adaptive_cancel`. Both `operator_submit.verify` and
`operator_adaptive_start.verification` accept command strings or structured
objects shaped as
`{"command":"npm test","writable_paths":["dist"]}`. Writable paths are
relative verifier-sandbox outputs; they never make accepted source paths or
host paths writable.

Both MCP submission tools also accept the optional fields
`client_request_id` (a lowercase canonical UUID) and `require_idle` (a boolean).
With `require_idle: true`, a new request returns
`{"task_id":null,"state":"busy","profile":"...","client_request_id":"...","duplicate":false}`
instead of creating overlapping work. An exact retry returns the original task
ID with its current state and `duplicate: true`, including after that task has
started or finished.

## Provider Contract

Built-in discovery covers `codex`, `claude`, `gemini`, `opencode`, `grok`,
`hermes`, and `openclaw`. Additional providers are configured in
`~/.blacklabel-operator/providers.json` with an executable, argv templates, and
declared capabilities. Operator validates requested capabilities before launch.

The built-in Grok Build adapter declares exactly `json_stream`, `resume`, and
`sandbox`. Success requires exit status zero and exactly one valid terminal
`end` event whose `stopReason` is `end_turn`; any other stop reason fails closed.
Its bounded session/request/stop, usage, and compaction fields are provider
metadata. Tool locations and memory-flush paths are locators only, labeled
`locations_only_not_content_verified`; streaming JSON exposes no checkpoint
identity, recorded as `not_exposed_by_streaming_json`. None of those fields is
a verifier or artifact receipt.

Provider breadth never changes the acceptance identity:

```text
provider        codex
profile         sol-benchmark
requested model gpt-5.6-sol
resolved model  gpt-5.6-sol
```

Every benchmark receipt records that identity, the Codex version and command,
the Operator revision, scope, result, and SHA-256 hashes for its artifacts.

## Tests

```sh
python3 -m unittest discover -s tests -v
operator benchmark list
operator benchmark status
operator benchmark campaign status
operator benchmark run harnessbench --agents sol --cases all --effort high
```

See [BENCHMARKS.md](docs/BENCHMARKS.md) for the acceptance matrix and
[HARNESS-SYNTHESIS.md](docs/HARNESS-SYNTHESIS.md) for the design provenance.
