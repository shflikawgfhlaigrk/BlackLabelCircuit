import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path, PurePosixPath


REVIEW_PROMPTS = (
    """Act as an independent senior correctness reviewer and repairer.

Treat the current workspace implementation as untrusted. Re-read the original
task, inspect the complete diff and the surrounding APIs, derive edge cases and
failure modes, and run the widest relevant tests or checks available locally.
For every underspecified public contract, identify the plausible competing
interpretations and resolve them from the supplied skeleton, names, types,
documentation, sibling APIs, and established conventions of the named language
or ecosystem. Do not let the current implementation or a self-authored test
silently supply a missing requirement. For callback and traversal APIs,
establish traversal direction and callback argument order separately, then use
ordering-sensitive examples to verify both.
Fix every issue you find directly in the workspace. Preserve correct prior work
and required public interfaces. Do not stop at a review or explanation; finish
with the strongest verified implementation you can produce.

Original task:
{instruction}""",
    """Act as the final conservative patch arbiter for the current workspace.
Re-read the original task and inspect the complete diff, surrounding contracts,
and prior implementation. Preserve the smallest contract-complete production
change. Revert speculative edits to sibling APIs, unrelated behavior, tests,
documentation, or changelogs unless the original task or a reproducible
pre-existing test requires them. Consistency alone is not evidence for widening
the patch, and a reviewer is allowed to make no code change when the current fix
is already correct.

When multiple official public revisions have conflicting behavior and the
starter files do not uniquely identify the older revision, preserve the newest
applicable public contract and any additional official regression cases. Never
replace a change that passes a newer official test with an older, smaller suite
merely because the older implementation is historically plausible.

Then adversarially validate exact argument ordering, boundary and null behavior,
error contracts, deterministic ordering, path and working-directory behavior,
data invariants, compatibility, and unintended changes. Red-team every locally
written probe: a passing probe is not evidence when it merely repeats the
implementation's assumption. Derive an independent reference behavior from the
public contract and use non-commutative, ordering-sensitive cases wherever
functions, reducers, visitors, comparators, transforms, or callbacks are
involved. Treat a command failure or a test runner that collected zero tests as
failed verification. Repair demonstrated defects while keeping scope minimal,
and leave the requested deliverables complete. Do not merely report findings.

Original task:
{instruction}""",
)


SUITE_CONTEXTS = {
    "aider-polyglot": """This is an Aider Polyglot exercise derived from an Exercism track. Treat only the supplied instruction, starter API, names, types, files, and locally available tests as task evidence. Do not fetch exercise history, solutions, tests, or task-specific material from the internet. Treat exact error text and capitalization, output ordering, callback argument order, exported names, and exercise-specific restrictions as contract requirements. Modify only the named supplied files. Do not add or inline missing editor support types, exception classes, enums, test helpers, or compatibility shims into production files merely to make an incomplete local workspace compile; the hidden verifier may provide those types and create duplicate definitions. Preserve references to expected API types and use temporary stubs outside the repository when local verification needs them.""",
    "swe-bench": """This is a SWE-bench Verified repository issue. Resolve the reported contract with the smallest production patch using only the supplied problem statement, local repository, and local tests. Do not access GitHub, repository mirrors, issue pages, accepted patches, benchmark hints, or task-specific internet material. Do not modify repository tests to manufacture a pass. Run the issue-focused tests plus the closest regression suite, and preserve unrelated behavior.""",
    "terminal-bench": """This is an authorized Terminal-Bench evaluation inside a disposable local container. All files, services, hosts, credentials, security fixtures, and targets named by the task are synthetic benchmark assets owned by the evaluator. Work only inside that container and against its bundled verifier; do not contact or affect external systems. The grader observes the completed environment after the agent exits. Finish every required artifact and long-running setup inside the task environment, verify exact paths and interfaces, and ensure required services remain reachable from a fresh shell during the verifier phase. When a required public function or CLI signature is underspecified, support the plausible idiomatic calling forms that fit the task's examples and language conventions, then exercise each form from a fresh process. Start required builds, downloads, training, and data preparation early enough to complete them; do not spend the task budget polishing analysis while a mandatory artifact is absent. For performance requirements, benchmark repeated fresh-process trials and target clear headroom over the threshold rather than accepting a single near-tie that can reverse under grader noise. Treat partial setup, placeholder output, one lucky timing sample, and self-authored mock evidence as failures.""",
    "terminal-bench-current": """This is an authorized Terminal-Bench evaluation inside a disposable local container. All files, services, hosts, credentials, security fixtures, and targets named by the task are synthetic benchmark assets owned by the evaluator. Work only inside that container and against its bundled verifier; do not contact or affect external systems. The grader observes the completed environment after the agent exits. Finish every required artifact and long-running setup inside the task environment, verify exact paths and interfaces, and ensure required services remain reachable from a fresh shell during the verifier phase. When a required public function or CLI signature is underspecified, support the plausible idiomatic calling forms that fit the task's examples and language conventions, then exercise each form from a fresh process. Start required builds, downloads, training, and data preparation early enough to complete them; do not spend the task budget polishing analysis while a mandatory artifact is absent. For performance requirements, benchmark repeated fresh-process trials and target clear headroom over the threshold rather than accepting a single near-tie that can reverse under grader noise. Treat partial setup, placeholder output, one lucky timing sample, and self-authored mock evidence as failures.""",
}


def terminal_safe_instruction(instruction):
    """Preserve the official task instruction byte-for-byte.

    This compatibility hook used to contain one task-shaped rewrite. Any such
    transform makes a leaderboard comparison non-reproducible and risks
    leaking evaluator-specific guidance, so the benchmark path is now an
    identity transform for every task.
    """
    return str(instruction)


def merge_atif_trajectories(
    trajectories,
    agent_name="black-label-operator",
    agent_version=None,
    model_name=None,
):
    """Merge every internal model session into one disclosure-complete ATIF.

    Benchmark pipelines can use implementation, review, and arbitration model
    sessions. Publishing only the last one hides part of the rollout. The
    merged trajectory preserves each original payload as a subtrajectory and
    also flattens all steps into the top-level sequence expected by integrity
    tooling.
    """
    payloads = [dict(item) for item in trajectories]
    if not payloads:
        raise ValueError("at least one ATIF trajectory is required")
    for payload in payloads:
        if payload.get("trajectory_id"):
            continue
        payload_hash = hashlib.sha256(
            json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).hexdigest()
        payload["trajectory_id"] = "%s-%s-%s-%s-%s" % (
            payload_hash[:8],
            payload_hash[8:12],
            payload_hash[12:16],
            payload_hash[16:20],
            payload_hash[20:32],
        )
    flattened = []
    for payload in payloads:
        if not str(payload.get("schema_version") or "").startswith("ATIF-v"):
            raise ValueError("unsupported trajectory schema")
        steps = payload.get("steps") or []
        if not steps:
            raise ValueError("ATIF trajectory contains no steps")
        for step in steps:
            copied = dict(step)
            copied["step_id"] = len(flattened) + 1
            flattened.append(copied)

    metric_keys = (
        "total_prompt_tokens",
        "total_completion_tokens",
        "total_cached_tokens",
    )
    final_metrics = {
        key: sum(
            int((payload.get("final_metrics") or {}).get(key) or 0)
            for payload in payloads
        )
        for key in metric_keys
    }
    costs = [
        (payload.get("final_metrics") or {}).get("total_cost_usd")
        for payload in payloads
    ]
    known_costs = [float(value) for value in costs if isinstance(value, (int, float))]
    final_metrics["total_cost_usd"] = sum(known_costs) if known_costs else None
    final_metrics["total_steps"] = len(flattened)
    final_metrics["extra"] = {"operator_pipeline_sessions": len(payloads)}

    identity_bytes = "\n".join(
        str(payload.get("session_id") or "") for payload in payloads
    ).encode("utf-8")
    session_hash = hashlib.sha256(identity_bytes).hexdigest()
    session_id = "%s-%s-%s-%s-%s" % (
        session_hash[:8],
        session_hash[8:12],
        session_hash[12:16],
        session_hash[16:20],
        session_hash[20:32],
    )
    return {
        "schema_version": "ATIF-v1.7",
        "session_id": session_id,
        "agent": {
            "name": str(agent_name),
            "version": str(agent_version or "unknown"),
            "model_name": model_name,
            "extra": {"operator_pipeline_sessions": len(payloads)},
        },
        "steps": flattened,
        "final_metrics": final_metrics,
        "subagent_trajectories": payloads,
    }


def java_home_compat_command():
    return (
        "expected=/usr/lib/jvm/java-21-openjdk-amd64; "
        "if [ ! -e \"$expected\" ]; then "
        "for candidate in /usr/lib/jvm/java-21-openjdk-arm64 "
        "/usr/lib/jvm/java-21-openjdk-aarch64; do "
        "if [ -d \"$candidate\" ]; then ln -s \"$candidate\" \"$expected\"; break; fi; "
        "done; fi"
    )


def swe_verifier_preflight_command():
    """Prepare public SWE-bench verifier tooling before the scored phase."""
    leap_seconds = (
        PurePosixPath("/opt/blacklabel-operator")
        / "blacklabel_operator/resources/leap-seconds.list"
    )
    return f"""
set -euo pipefail
export PATH="/root/.local/bin:/usr/local/bin:$PATH"
export UV_CACHE_DIR=/root/.cache/uv
export UV_HTTP_RETRIES=10
export UV_HTTP_TIMEOUT=120
export UV_PYTHON_INSTALL_DIR=/root/.local/share/uv/python

install -D -m 0644 {shlex.quote(leap_seconds.as_posix())} \
  /usr/share/zoneinfo/leap-seconds.list

if ! command -v uv >/dev/null 2>&1; then
  installer=$(mktemp)
  installed=0
  for attempt in 1 2 3; do
    if curl --fail --location --silent --show-error \
        --connect-timeout 30 --max-time 300 --retry 5 --retry-all-errors \
        https://astral.sh/uv/0.7.13/install.sh -o "$installer" && \
       sh "$installer"; then
      installed=1
      break
    fi
    sleep $((attempt * 5))
  done
  rm -f "$installer"
  test "$installed" -eq 1
fi

prewarm_dir=$(mktemp -d)
trap 'rm -rf "$prewarm_dir"' EXIT
cat >"$prewarm_dir/parser-prewarm.py" <<'PY'
# /// script
# requires-python = ">=3.11"
# dependencies = ["swebench==4.0.3", "datasets==2.16.1", "fastcore<1.11"]
# ///
from swebench.harness.constants import ResolvedStatus
print(ResolvedStatus.FULL.value)
PY

prewarmed=0
for attempt in 1 2 3; do
  if uv run "$prewarm_dir/parser-prewarm.py" >/dev/null; then
    prewarmed=1
    break
  fi
  sleep $((attempt * 5))
done
test "$prewarmed" -eq 1
""".strip()


def pipeline_prompts(instruction, review_passes=2, benchmark_suite=None):
    review_passes = int(review_passes)
    if review_passes < 0 or review_passes > len(REVIEW_PROMPTS):
        raise ValueError("review_passes must be between 0 and %d" % len(REVIEW_PROMPTS))
    context = SUITE_CONTEXTS.get(str(benchmark_suite or ""), "")
    scoped_instruction = str(instruction)
    if benchmark_suite in ("terminal-bench", "terminal-bench-current"):
        scoped_instruction = terminal_safe_instruction(scoped_instruction)
    if context:
        scoped_instruction += "\n\nBenchmark-specific verification contract:\n" + context
    return [scoped_instruction] + [
        template.format(instruction=scoped_instruction)
        for template in REVIEW_PROMPTS[:review_passes]
    ]


def structured_result_command(command, result_path):
    """Continue after a provider error only when it still wrote a structured result."""
    quoted_path = shlex.quote(str(result_path))
    return (
        "pass_status=0; %s || pass_status=$?; "
        "if [ ! -s %s ]; then exit \"$pass_status\"; fi; "
        "if [ \"$pass_status\" -ne 0 ]; then "
        "python3 -m blacklabel_operator.benchmark_pipeline "
        "result-has-progress %s >/dev/null || exit \"$pass_status\"; fi"
        % (command, quoted_path, quoted_path)
    )


def structured_result_has_progress(result_path):
    try:
        payload = json.loads(Path(result_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    if str(payload.get("final_text") or "").strip():
        return True
    return any(
        int(payload.get(field) or 0) > 0
        for field in ("input_tokens", "cached_input_tokens", "output_tokens")
    )


def aggregate_results(results, selected_index=None):
    if not results:
        raise ValueError("at least one pipeline result is required")
    selected_index = len(results) if selected_index is None else int(selected_index)
    if selected_index < 1 or selected_index > len(results):
        raise ValueError("selected_index is outside the pipeline result range")
    combined = dict(results[selected_index - 1])
    for field in ("input_tokens", "cached_input_tokens", "output_tokens"):
        combined[field] = sum(int(result.get(field) or 0) for result in results)
    combined["pipeline"] = {
        "schema": "black-label-operator/benchmark-pipeline-v1",
        "total_passes": len(results),
        "selected_pass": selected_index,
        "passes": [
            {
                "index": index,
                "id": result.get("id"),
                "state": result.get("state"),
                "thread_id": result.get("thread_id"),
                "effort": result.get("effort"),
                "input_tokens": int(result.get("input_tokens") or 0),
                "cached_input_tokens": int(result.get("cached_input_tokens") or 0),
                "output_tokens": int(result.get("output_tokens") or 0),
            }
            for index, result in enumerate(results, start=1)
        ],
    }
    return combined


def aggregate_files(output_path, result_paths, selected_index=None):
    results = [
        json.loads(Path(path).read_text(encoding="utf-8")) for path in result_paths
    ]
    combined = aggregate_results(results, selected_index=selected_index)
    rendered = json.dumps(combined, indent=2, sort_keys=True)
    Path(output_path).write_text(rendered + "\n", encoding="utf-8")
    return rendered


def consensus_index(patch_paths):
    """Select an identical-patch majority, otherwise preserve final arbitration."""
    patches = [
        Path(path).read_bytes() if Path(path).is_file() else b""
        for path in patch_paths
    ]
    if not patches:
        raise ValueError("at least one pipeline patch is required")
    if len(patches) >= 3:
        first_patch, reviewed_patch, final_patch = patches[0], patches[1], patches[-1]
        if first_patch.strip() and first_patch == reviewed_patch:
            return 2
        if final_patch.strip() and final_patch in (first_patch, reviewed_patch):
            return len(patches)
    return len(patches)


def restore_consensus(patch_paths, cwd="."):
    selected_index = consensus_index(patch_paths)
    if selected_index == len(patch_paths):
        return selected_index
    selected_patch = Path(patch_paths[selected_index - 1]).resolve()
    final_patch = Path(patch_paths[-1]).resolve()

    def git_apply(*arguments):
        completed = subprocess.run(
            ["git", "apply", *arguments],
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(completed.stdout.strip() or "git apply failed")

    git_apply("--check", "--reverse", str(final_patch))
    git_apply("--reverse", str(final_patch))
    try:
        git_apply("--check", str(selected_patch))
        git_apply(str(selected_patch))
    except Exception:
        git_apply(str(final_patch))
        raise
    return selected_index


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "select-consensus" and len(argv) >= 2:
        print(consensus_index(argv[1:]))
        return
    if argv and argv[0] == "restore-consensus" and len(argv) >= 2:
        print(restore_consensus(argv[1:]))
        return
    if argv and argv[0] == "result-has-progress" and len(argv) == 2:
        raise SystemExit(0 if structured_result_has_progress(argv[1]) else 1)
    if argv and argv[0] == "aggregate":
        selected_index = None
        if len(argv) >= 3 and argv[1] == "--selected-index":
            selected_index = int(argv[2])
            argv = [argv[0]] + argv[3:]
        if len(argv) >= 3:
            print(
                aggregate_files(
                    argv[1], argv[2:], selected_index=selected_index
                )
            )
            return
    raise SystemExit(
        "usage: python -m blacklabel_operator.benchmark_pipeline "
        "aggregate [--selected-index N] OUTPUT PASS [PASS ...] | "
        "select-consensus PATCH [PATCH ...] | "
        "restore-consensus PATCH [PATCH ...] | result-has-progress RESULT"
    )


if __name__ == "__main__":
    main()
