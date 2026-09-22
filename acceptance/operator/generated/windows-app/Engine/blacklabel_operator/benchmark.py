import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import replace

from .benchmark_receipt import require_exact_sol, write_receipt
from .codex_runner import CodexRunner
from .profiles import SOL_MODEL
from .quota import quota_info_from_text, require_quota_available
from .settings import should_start_new_session
from .store import Store
from .standard_benchmark import (
    EXTERNAL_NUMBER_ONE_LANES,
    OFFICIAL_QUALITY_LANES,
    official_quality_contract,
)


CASES = {
    "slugify": {
        "prompt": """Fix slugify.py so slugify(value) passes the full contract: normalize Unicode to ASCII where possible, lowercase it, replace every run of non-alphanumeric characters with one hyphen, and strip edge hyphens. Keep the public function name. Run relevant tests before finishing.""",
        "files": {
            "slugify.py": """import re


def slugify(value):
    return re.sub(r"[^a-z0-9]", "-", value.lower())
""",
        },
        "test": """import unittest
from slugify import slugify


class SlugifyTests(unittest.TestCase):
    def test_contract(self):
        self.assertEqual(slugify("Hello,   World!"), "hello-world")
        self.assertEqual(slugify("  Cafe deja vu  "), "cafe-deja-vu")
        self.assertEqual(slugify("Already--Slugged"), "already-slugged")
        self.assertEqual(slugify("___"), "")


if __name__ == "__main__":
    unittest.main()
""",
    },
    "ledger": {
        "prompt": """Repair ledger.py. summarize(lines, tax_rate) must use Decimal arithmetic, reject negative quantity or unit_price with ValueError, round each line subtotal to cents using ROUND_HALF_UP, calculate tax from the rounded subtotal and round it the same way, and return Decimal subtotal, tax, and total values. Do not change the function signature. Verify the implementation.""",
        "files": {
            "ledger.py": """def summarize(lines, tax_rate):
    subtotal = sum(item["quantity"] * item["unit_price"] for item in lines)
    tax = subtotal * tax_rate
    return {"subtotal": subtotal, "tax": tax, "total": subtotal + tax}
""",
        },
        "test": """import unittest
from decimal import Decimal
from ledger import summarize


class LedgerTests(unittest.TestCase):
    def test_decimal_rounding(self):
        result = summarize([
            {"quantity": 3, "unit_price": Decimal("0.335")},
            {"quantity": 1, "unit_price": Decimal("2.005")},
        ], Decimal("0.0825"))
        self.assertEqual(result, {
            "subtotal": Decimal("3.02"),
            "tax": Decimal("0.25"),
            "total": Decimal("3.27"),
        })

    def test_rejects_negative_values(self):
        with self.assertRaises(ValueError):
            summarize([{"quantity": -1, "unit_price": Decimal("2.00")}], Decimal("0"))
        with self.assertRaises(ValueError):
            summarize([{"quantity": 1, "unit_price": Decimal("-2.00")}], Decimal("0"))


if __name__ == "__main__":
    unittest.main()
""",
    },
    "scheduler": {
        "prompt": """Implement dependency_order(graph) in scheduler.py. graph maps a task to its dependencies. Return every task, including dependency-only nodes, in a deterministic topological order with lexical tie breaking. Raise ValueError when a cycle exists. Do not mutate the input. Verify the implementation.""",
        "files": {
            "scheduler.py": """def dependency_order(graph):
    return list(graph)
""",
        },
        "test": """import unittest
from scheduler import dependency_order


class SchedulerTests(unittest.TestCase):
    def test_order_and_dependency_only_nodes(self):
        graph = {"deploy": ["test", "build"], "test": ["build"], "docs": []}
        snapshot = {key: list(value) for key, value in graph.items()}
        self.assertEqual(dependency_order(graph), ["build", "docs", "test", "deploy"])
        self.assertEqual(graph, snapshot)

    def test_cycle(self):
        with self.assertRaises(ValueError):
            dependency_order({"a": ["b"], "b": ["a"]})


if __name__ == "__main__":
    unittest.main()
""",
    },
}


def _run_process(command, cwd, prompt, timeout, stdout_path, stderr_path):
    started = time.monotonic()
    with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open(
        "w", encoding="utf-8"
    ) as stderr:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdin=subprocess.PIPE if prompt is not None else subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            text=True,
            start_new_session=should_start_new_session(),
            env=os.environ.copy(),
        )
        try:
            process.communicate(input=prompt, timeout=timeout)
        except subprocess.TimeoutExpired:
            ok, detail = CodexRunner.terminate_spawned(process)
            return {
                "exit_code": None,
                "timed_out": True,
                "termination": detail,
                "termination_ok": ok,
                "duration_seconds": time.monotonic() - started,
            }
    return {
        "exit_code": process.returncode,
        "timed_out": False,
        "duration_seconds": time.monotonic() - started,
    }


def _adapter_command(agent, settings, prompt):
    if agent == "claude":
        binary = shutil.which("claude")
        return (
            [
                binary,
                "-p",
                prompt,
                "--dangerously-skip-permissions",
                "--disable-slash-commands",
                "--effort",
                "high",
                "--output-format",
                "json",
            ]
            if binary
            else None
        )
    if agent == "gemini":
        binary = shutil.which("gemini")
        return [binary, "-p", prompt, "--yolo", "-o", "json"] if binary else None
    if agent == "opencode":
        binary = shutil.which("opencode")
        return [binary, "run", "--auto", "--pure", "--format", "json", prompt] if binary else None
    return None


def _prepare_case(run_dir, agent, case_name):
    case = CASES[case_name]
    root = run_dir / agent / case_name
    workspace = root / "workspace"
    grader = root / "grader"
    workspace.mkdir(parents=True, exist_ok=True)
    grader.mkdir(parents=True, exist_ok=True)
    for relative, content in case["files"].items():
        path = workspace / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    (grader / "test_solution.py").write_text(case["test"], encoding="utf-8")
    (workspace / "TASK.md").write_text(case["prompt"] + "\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=str(workspace), check=True)
    subprocess.run(["git", "add", "."], cwd=str(workspace), check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Sol Benchmark",
            "-c",
            "user.email=benchmark@localhost",
            "commit",
            "-qm",
            "fixture",
        ],
        cwd=str(workspace),
        check=True,
    )
    return root, workspace, grader


def _run_agent(agent, settings, store, workspace, prompt, timeout, effort, root):
    started = time.monotonic()
    if agent == "sol":
        from .daemon import TaskExecutor

        task_id = store.enqueue(
            prompt=prompt,
            cwd=workspace,
            model=SOL_MODEL,
            effort=effort,
            sandbox="workspace-write",
            max_attempts=1,
            priority=25,
            source="benchmark",
            metadata={
                "suite": "harnessbench",
                "required_capabilities": ["json_stream", "sandbox"],
                "disable_customizations": True,
            },
            provider="codex",
            profile="sol-benchmark",
            isolation="shared",
        )
        owner = "harnessbench-%s" % uuid.uuid4().hex[:10]
        task = store.claim(owner, settings.lease_seconds)
        if not task or task["id"] != task_id:
            raise RuntimeError("isolated HarnessBench task was not claimable")
        TaskExecutor(settings, store, owner).execute(task)
        task = store.get(task_id)
        return {
            "exit_code": task.get("exit_code"),
            "timed_out": False,
            "duration_seconds": time.monotonic() - started,
            "task_id": task_id,
            "task_state": task["state"],
            "task_error": task.get("error"),
            "input_tokens": task.get("input_tokens", 0),
            "cached_input_tokens": task.get("cached_input_tokens", 0),
            "output_tokens": task.get("output_tokens", 0),
        }
    if agent == "codex":
        runner = CodexRunner(settings)
        task = {
            "id": "bench-" + uuid.uuid4().hex,
            "prompt": prompt,
            "cwd": str(workspace),
            "model": settings.model,
            "effort": effort,
            "sandbox": "workspace-write",
            "attempt": 1,
        }
        result = runner.run(task)
        return {
            "exit_code": result.exit_code,
            "timed_out": result.timed_out,
            "duration_seconds": time.monotonic() - started,
            "input_tokens": result.input_tokens,
            "cached_input_tokens": result.cached_input_tokens,
            "output_tokens": result.output_tokens,
            "success": result.success,
            "error": result.error,
        }
    command = _adapter_command(agent, settings, prompt)
    if not command:
        return {"skipped": True, "reason": "%s CLI is not installed" % agent}
    return _run_process(
        command,
        workspace,
        None,
        timeout,
        root / "agent.stdout.log",
        root / "agent.stderr.log",
    )


def _grade(workspace, grader, root):
    env = os.environ.copy()
    env["PYTHONPATH"] = str(workspace)
    completed = subprocess.run(
        [sys.executable, str(grader / "test_solution.py")],
        cwd=str(workspace),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
        check=False,
    )
    (root / "grader.log").write_text(completed.stdout, encoding="utf-8")
    diff = subprocess.run(
        ["git", "diff", "--no-ext-diff"],
        cwd=str(workspace),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    ).stdout
    (root / "patch.diff").write_text(diff, encoding="utf-8")
    return {
        "passed": completed.returncode == 0,
        "grader_exit_code": completed.returncode,
        "patch_bytes": len(diff.encode("utf-8")),
    }


def _write_report(run_dir, report):
    (run_dir / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True), encoding="utf-8"
    )
    lines = [
        "# HarnessBench",
        "",
        "Model: `%s`" % report["model"],
        "",
        "| Agent | Case | Pass | Seconds | Input | Output |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for result in report["results"]:
        lines.append(
            "| %s | %s | %s | %.1f | %s | %s |"
            % (
                result["agent"],
                result["case"],
                "yes" if result.get("passed") else "no",
                float(result.get("duration_seconds") or 0),
                result.get("input_tokens", ""),
                result.get("output_tokens", ""),
            )
        )
    lines.extend(["", "Passed: %d/%d" % (report["passed"], report["total"]), ""])
    (run_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def run_benchmark(args, settings):
    if args.suite != "harnessbench":
        if args.suite == "arc-agi-3":
            from .arc_agi3_benchmark import run_arc_agi3

            return run_arc_agi3(args, settings)
        from .standard_benchmark import run_harbor

        return run_harbor(args, settings)

    require_exact_sol("codex", SOL_MODEL, settings.model, "sol-benchmark")
    require_quota_available(settings.benchmark_dir)
    agents = [item.strip() for item in args.agents.split(",") if item.strip()]
    cases = list(CASES) if args.cases == "all" else [item.strip() for item in args.cases.split(",")]
    unknown_agents = sorted(set(agents) - {"sol"})
    unknown_cases = sorted(set(cases) - set(CASES))
    if unknown_agents:
        raise RuntimeError("unknown benchmark agents: %s" % ", ".join(unknown_agents))
    if unknown_cases:
        raise RuntimeError("unknown benchmark cases: %s" % ", ".join(unknown_cases))
    started_at = time.time()
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    run_dir = settings.benchmark_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    isolated_settings = replace(
        settings,
        home=run_dir / "operator-home",
        port=0,
        workers=1,
        task_timeout_seconds=max(30, int(args.timeout)),
    )
    isolated_settings.ensure_dirs()
    store = Store(isolated_settings.db_path)
    results = []
    for agent in agents:
        for case_name in cases:
            root, workspace, grader = _prepare_case(run_dir, agent, case_name)
            runtime = _run_agent(
                agent,
                isolated_settings,
                store,
                workspace,
                CASES[case_name]["prompt"],
                args.timeout,
                args.effort,
                root,
            )
            graded = _grade(workspace, grader, root)
            result = {"agent": agent, "case": case_name}
            result.update(runtime)
            result.update(graded)
            results.append(result)
            print(
                "%s/%s: %s (%.1fs)"
                % (
                    agent,
                    case_name,
                    "PASS" if result["passed"] else "FAIL",
                    result.get("duration_seconds", 0),
                ),
                file=sys.stderr,
            )
    report = {
        "suite": "harnessbench-v1",
        "run_kind": "internal_acceptance",
        "benchmark_score": None,
        "leaderboard_score": None,
        "score_statement": (
            "HarnessBench is an internal acceptance suite; its pass count is "
            "not a public benchmark or leaderboard score."
        ),
        "run_id": run_id,
        "created_at": started_at,
        "model": SOL_MODEL,
        "effort": args.effort,
        "agents": agents,
        "cases": cases,
        "daemon_health": {
            "ok": True,
            "isolated": True,
            "tasks": store.counts(),
            "workers": isolated_settings.workers,
        },
        "passed": sum(1 for item in results if item.get("passed")),
        "total": len(results),
        "results": results,
        "artifact_dir": str(run_dir),
    }
    provider_failures = [
        {
            "case": item["case"],
            "task_state": item.get("task_state"),
            "error": item.get("task_error"),
            "quota": quota_info_from_text(item.get("task_error")) is not None,
        }
        for item in results
        if item.get("task_state") not in (None, "succeeded")
    ]
    report["clean"] = not provider_failures
    report["provider_failures"] = provider_failures
    _write_report(run_dir, report)
    evidence_status = (
        "incomplete"
        if provider_failures
        else "passed" if report["passed"] == report["total"] else "failed"
    )
    write_receipt(
        run_dir,
        suite="harnessbench",
        status=evidence_status,
        settings=settings,
        command=[
            "operator",
            "benchmark",
            "run",
            "harnessbench",
            "--agents",
            args.agents,
            "--cases",
            args.cases,
            "--effort",
            args.effort,
            "--timeout",
            str(args.timeout),
        ],
        scope={
            "cases": cases,
            "total": len(cases),
            "run_kind": "internal_acceptance",
            "score_eligible": False,
        },
        result={
            "passed": report["passed"],
            "total": report["total"],
            "clean": report["clean"],
            "provider_failures": provider_failures,
            "benchmark_score": None,
            "leaderboard_score": None,
            "statement": report["score_statement"],
        },
        started_at=started_at,
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if evidence_status == "passed" else 1


def list_benchmark(_args, _settings):
    from .comparable_benchmark import (
        EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER,
        SWE_PRO_CERTIFICATION_BLOCKERS,
    )

    payload = {
        "score_statement": (
            "Selected-task passes are smoke evidence, not full benchmark or "
            "leaderboard scores."
        ),
        "acceptance_identity": {
            "provider": "codex",
            "profile": "sol-benchmark",
            "model": SOL_MODEL,
            "substitution_allowed": False,
        },
        "local_suite": {
            "name": "harnessbench-v1",
            "cases": sorted(CASES),
            "provider": "codex",
            "model": SOL_MODEL,
        },
        "standard_suites": {
            "arc-agi-3": {
                "url": "https://github.com/arcprize/arc-agi-3-benchmarking",
                "model": SOL_MODEL,
            },
            "swe-bench": {
                "url": "https://github.com/SWE-bench/SWE-bench",
                "official_tasks": 500,
                "grader": "swebench eval verified -p PREDICTIONS --run-id RUN_ID",
            },
            "terminal-bench": {
                "url": "https://github.com/harbor-framework/terminal-bench",
                "official_tasks": 89,
                "grader": "harbor run --help",
            },
            "terminal-bench-current": {
                "url": "https://github.com/harbor-framework/terminal-bench/tree/v4.0.0",
                "official_tasks": 66,
                "official_trials": 5,
                "grader": "harbor run --help",
                "leaderboard_submission": "official Harbor job and organizer receipt",
                "comparable_eligible": False,
                "blocker": (
                    "no contract-pinned isolated Harbor interpreter, dependencies, "
                    "and startup-runtime attestation"
                ),
            },
            "swe-bench-pro-public": {
                "url": "https://github.com/scaleapi/SWE-bench_Pro-os",
                "official_tasks": 731,
                "comparable_eligible": False,
                "blockers": list(SWE_PRO_CERTIFICATION_BLOCKERS),
                "legacy_swe_bench_500_task_lane": False,
            },
            "aider-polyglot": {
                "url": "https://aider.chat/docs/leaderboards/",
                "official_tasks": 225,
            },
        },
        "comparable_external_contracts": {
            "plan_commands": [
                "plan-terminal-bench-4-current",
                "plan-swe-bench-pro",
            ],
            "run_commands": [
                "run-terminal-bench-4-current",
                "run-swe-bench-pro",
            ],
            "organizer_certification_eligible": False,
            "organizer_blocker": EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER,
        },
        "official_quality": {
            "good": False,
            "contract": official_quality_contract(),
            "required_lanes": list(OFFICIAL_QUALITY_LANES),
            "statement": (
                "Good requires five organizer-verified official 0-100 scores, "
                "each individually at least 91; local conversions and averaging "
                "do not count."
            ),
            "independent_from_number_one": True,
        },
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


def status_benchmark(args, settings):
    from .benchmark_status import benchmark_status, render_status

    payload = benchmark_status(settings.benchmark_dir, settings=settings)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_status(payload))
    return 0


def comparable_benchmark(args, settings):
    from .comparable_benchmark import (
        aider_stock,
        arc_standardized,
        capture_target_snapshot,
        ingest_external_evidence,
        swe_bench_pro,
        terminal_bench_4_current,
    )

    if args.external_command == "plan-aider-stock":
        payload = aider_stock(args, settings, execute=False)
        exit_code = 0
    elif args.external_command == "run-aider-stock":
        payload = aider_stock(args, settings, execute=True)
        exit_code = 0 if payload["status"] == "completed" else 1
    elif args.external_command == "plan-arc-standardized":
        payload = arc_standardized(args, settings, execute=False)
        exit_code = 0
    elif args.external_command == "run-arc-standardized":
        payload = arc_standardized(args, settings, execute=True)
        exit_code = 0 if payload["status"] == "completed" else 1
    elif args.external_command == "plan-terminal-bench-4-current":
        payload = terminal_bench_4_current(args, settings, execute=False)
        exit_code = 0
    elif args.external_command == "run-terminal-bench-4-current":
        payload = terminal_bench_4_current(args, settings, execute=True)
        exit_code = 0 if payload["status"] == "completed" else 1
    elif args.external_command == "plan-swe-bench-pro":
        payload = swe_bench_pro(args, settings, execute=False)
        exit_code = 0
    elif args.external_command == "run-swe-bench-pro":
        payload = swe_bench_pro(args, settings, execute=True)
        exit_code = 0 if payload["status"] == "completed" else 1
    elif args.external_command == "capture-target":
        payload = capture_target_snapshot(args, settings)
        exit_code = 0
    elif args.external_command == "ingest":
        payload = ingest_external_evidence(args, settings)
        exit_code = 0
    else:
        raise RuntimeError("unknown external benchmark command")
    print(json.dumps(payload, indent=2, sort_keys=True))
    return exit_code


def official_quality_benchmark(args, settings):
    from .comparable_benchmark import ingest_official_quality_evidence

    if args.official_quality_command != "ingest":
        raise RuntimeError("unknown official-quality benchmark command")
    payload = ingest_official_quality_evidence(args, settings)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def campaign_benchmark(args, settings):
    from . import benchmark_service
    from .benchmark_campaign import (
        campaign_status,
        find_campaign,
        ingest_receipt,
        initialize_campaign,
        load_campaign,
        next_task_names,
        render_campaign_status,
        run_gate,
        run_next_shard,
        shard_command,
        supervise_campaign,
    )

    if args.campaign_command == "init":
        campaign_dir, _campaign = initialize_campaign(
            settings, threshold=args.threshold / 100.0
        )
        payload = campaign_status(settings, campaign_dir)
    elif args.campaign_command == "disarm":
        benchmark_service.stop()
        payload = {
            "armed": False,
            "plist": str(benchmark_service.plist_path()),
        }
    elif args.campaign_command == "armed":
        code, output = benchmark_service.details()
        payload = {
            "armed": code == 0,
            "plist": str(benchmark_service.plist_path()),
            "launchctl": output.strip(),
        }
    else:
        campaign_dir = find_campaign(settings, args.campaign)
        if args.campaign_command == "arm":
            path = benchmark_service.install(
                settings,
                campaign_dir,
                batch_size=args.batch_size,
                n_concurrent=args.n_concurrent,
                timeout=args.timeout,
                poll_seconds=args.poll_seconds,
                max_load=args.max_load,
            )
            payload = {
                "armed": True,
                "campaign": load_campaign(campaign_dir)["id"],
                "plist": str(path),
                "status": campaign_status(settings, campaign_dir),
            }
        elif args.campaign_command == "supervise":
            def supervisor_event(event):
                print(json.dumps(event, sort_keys=True), flush=True)

            supervise_campaign(
                settings,
                campaign_dir,
                batch_size=args.batch_size,
                n_concurrent=args.n_concurrent,
                timeout=args.timeout,
                poll_seconds=args.poll_seconds,
                max_load=args.max_load,
                once=args.once,
                event_sink=supervisor_event,
            )
            return 0
        elif args.campaign_command == "ingest":
            ingested = [
                ingest_receipt(campaign_dir, receipt) for receipt in args.receipt
            ]
            payload = {
                "campaign": load_campaign(campaign_dir)["id"],
                "ingested": ingested,
                "status": campaign_status(settings, campaign_dir),
            }
        elif args.campaign_command == "next":
            names = next_task_names(
                settings, campaign_dir, args.suite, args.batch_size
            )
            payload = {
                "campaign": load_campaign(campaign_dir)["id"],
                "suite": args.suite,
                "tasks": names,
                "command": shard_command(
                    settings,
                    campaign_dir,
                    args.suite,
                    names,
                    n_concurrent=args.n_concurrent,
                    timeout=args.timeout,
                ),
            }
        elif args.campaign_command == "run":
            if args.suite in ("harnessbench", "arc-agi-3"):
                run = run_gate(
                    settings,
                    campaign_dir,
                    args.suite,
                    timeout=args.timeout,
                )
                payload = {
                    "runs": [run],
                    "status": campaign_status(settings, campaign_dir),
                }
            else:
                runs = []
                while True:
                    before = campaign_status(settings, campaign_dir)
                    before_suite = next(
                        item for item in before["suites"] if item["suite"] == args.suite
                    )
                    run = run_next_shard(
                        settings,
                        campaign_dir,
                        args.suite,
                        batch_size=args.batch_size,
                        n_concurrent=args.n_concurrent,
                        timeout=args.timeout,
                    )
                    runs.append(run)
                    after = campaign_status(settings, campaign_dir)
                    after_suite = next(
                        item for item in after["suites"] if item["suite"] == args.suite
                    )
                    # Campaign v2 certifies independent trial slots (Terminal-Bench
                    # is 89 tasks x 5 slots). A later slot can complete without
                    # increasing the unique-task count, so progress must be measured
                    # in trials. Keep the fallback solely for readable v1 ledgers.
                    progressed = int(
                        after_suite.get(
                            "completed_trials", after_suite.get("completed_tasks", 0)
                        )
                    ) > int(
                        before_suite.get(
                            "completed_trials", before_suite.get("completed_tasks", 0)
                        )
                    )
                    if (
                        not args.until_blocked
                        or run["status"] in ("blocked", "complete")
                        or not progressed
                        or after_suite["state"] != "in_progress"
                    ):
                        break
                payload = {"runs": runs, "status": campaign_status(settings, campaign_dir)}
        else:
            payload = campaign_status(settings, campaign_dir)

    if args.json or args.campaign_command in (
        "init",
        "ingest",
        "next",
        "run",
        "arm",
        "disarm",
        "armed",
    ):
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_campaign_status(payload))
    if args.campaign_command == "certify":
        return 0 if payload["certified"] else 1
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="operator benchmark")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument(
        "suite",
        nargs="?",
        default="harnessbench",
        choices=(
            "harnessbench",
            "arc-agi-3",
            "swe-bench",
            "terminal-bench-current",
            "terminal-bench",
            "aider-polyglot",
        ),
    )
    run.add_argument("--agents", default="sol")
    run.add_argument("--cases", default="all")
    run.add_argument("--effort", default="high", choices=("low", "medium", "high", "xhigh", "max", "ultra"))
    run.add_argument("--timeout", type=float, default=1200)
    run.add_argument("--n-tasks", type=int, default=1)
    run.add_argument("--n-concurrent", type=int, default=1)
    run.add_argument("--n-attempts", type=int)
    run.add_argument("--max-retries", type=int, default=0)
    run.add_argument("--review-passes", type=int, choices=(0, 1, 2))
    run.add_argument("--include-task", action="append", default=[])
    run.add_argument("--dataset")
    run.add_argument("--game", default="ls20")
    run.add_argument("--all-games", action="store_true")
    sub.add_parser("list")
    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true")
    external = sub.add_parser(
        "external", help="run and ingest leaderboard-comparable evidence"
    )
    external_sub = external.add_subparsers(
        dest="external_command", required=True
    )

    def add_aider_arguments(item):
        item.add_argument("--campaign")
        item.add_argument("--aider-source", required=True)
        item.add_argument("--aider-revision", required=True)
        item.add_argument("--polyglot-source", required=True)
        item.add_argument("--polyglot-revision", required=True)
        item.add_argument("--model", required=True)
        item.add_argument("--expected-resolved-model", required=True)
        item.add_argument("--edit-format", required=True)
        item.add_argument("--reasoning-effort")
        item.add_argument("--threads", type=int, default=1)
        item.add_argument("--credential-env", action="append", default=[])
        item.add_argument("--run-id")
        item.add_argument("--build-timeout", type=float, default=3600)
        item.add_argument("--timeout", type=float, default=604800)

    add_aider_arguments(external_sub.add_parser("plan-aider-stock"))
    add_aider_arguments(external_sub.add_parser("run-aider-stock"))

    def add_arc_arguments(item):
        item.add_argument("--campaign")
        item.add_argument("--arc-source", required=True)
        item.add_argument("--arc-revision", required=True)
        item.add_argument("--config", required=True)
        item.add_argument("--run-id")
        item.add_argument("--timeout", type=float, default=604800)

    add_arc_arguments(external_sub.add_parser("plan-arc-standardized"))
    add_arc_arguments(external_sub.add_parser("run-arc-standardized"))

    def add_terminal_4_arguments(item):
        item.add_argument("--campaign")
        item.add_argument("--terminal-source", required=True)
        item.add_argument(
            "--terminal-revision",
            default="452bf305c6daa62fc59061d22133a7cbc7c1572e",
        )
        item.add_argument("--codex-version", required=True)
        item.add_argument(
            "--harbor-executable",
            help="dedicated Harbor 0.22 executable; official wheel RECORD must match",
        )
        item.add_argument("--n-concurrent", type=int, default=1)
        item.add_argument("--run-id")
        item.add_argument("--timeout", type=float, default=604800)

    add_terminal_4_arguments(
        external_sub.add_parser("plan-terminal-bench-4-current")
    )
    add_terminal_4_arguments(
        external_sub.add_parser("run-terminal-bench-4-current")
    )

    def add_swe_pro_arguments(item):
        item.add_argument("--campaign")
        item.add_argument("--swe-pro-source", required=True)
        item.add_argument(
            "--swe-pro-revision",
            default="ca10a60a5fcae51e6948ffe1485d4153d421e6c5",
        )
        item.add_argument("--dataset-source", required=True)
        item.add_argument(
            "--dataset-revision",
            default="7ab5114912baf22bb098818e604c02fe7ad2c11f",
        )
        item.add_argument("--patches", required=True)
        item.add_argument("--generation-receipt", required=True)
        item.add_argument("--model", required=True)
        item.add_argument("--expected-resolved-model", required=True)
        item.add_argument("--evaluator-image", required=True)
        item.add_argument("--docker-socket", required=True)
        item.add_argument("--workers", type=int, default=8)
        item.add_argument("--run-id")
        item.add_argument("--timeout", type=float, default=604800)

    add_swe_pro_arguments(external_sub.add_parser("plan-swe-bench-pro"))
    add_swe_pro_arguments(external_sub.add_parser("run-swe-bench-pro"))
    external_ingest = external_sub.add_parser("ingest")
    external_ingest.add_argument(
        "--lane", choices=tuple(EXTERNAL_NUMBER_ONE_LANES), required=True
    )
    external_ingest.add_argument("--campaign")
    external_ingest.add_argument("--run-receipt", required=True)
    external_ingest.add_argument("--submission-receipt", required=True)
    external_ingest.add_argument("--target-snapshot", required=True)
    external_ingest.add_argument("--receipt-id", required=True)
    external_ingest.add_argument("--url", required=True)
    external_ingest.add_argument("--verified-at", required=True)
    external_ingest.add_argument(
        "--status", choices=("accepted", "published"), required=True
    )
    external_ingest.add_argument(
        "--independently-verified", action="store_true"
    )
    external_capture = external_sub.add_parser("capture-target")
    external_capture.add_argument(
        "--lane", choices=tuple(EXTERNAL_NUMBER_ONE_LANES), required=True
    )
    external_capture.add_argument("--campaign")
    external_capture.add_argument("--timeout", type=float, default=30)
    official_quality = sub.add_parser(
        "official-quality",
        help="ingest organizer-signed official 0-100 quality scores",
    )
    official_quality_sub = official_quality.add_subparsers(
        dest="official_quality_command", required=True
    )
    official_quality_ingest = official_quality_sub.add_parser("ingest")
    official_quality_ingest.add_argument(
        "--lane", choices=tuple(OFFICIAL_QUALITY_LANES), required=True
    )
    official_quality_ingest.add_argument("--campaign")
    official_quality_ingest.add_argument("--organizer-receipt", required=True)
    campaign = sub.add_parser("campaign", help="manage immutable resumable score campaigns")
    campaign_sub = campaign.add_subparsers(dest="campaign_command", required=True)
    campaign_init = campaign_sub.add_parser("init")
    campaign_init.add_argument("--threshold", type=float, default=91.0)
    campaign_init.add_argument("--json", action="store_true")
    for action in ("status", "certify"):
        item = campaign_sub.add_parser(action)
        item.add_argument("--campaign")
        item.add_argument("--json", action="store_true")
    campaign_ingest = campaign_sub.add_parser("ingest")
    campaign_ingest.add_argument("receipt", nargs="+")
    campaign_ingest.add_argument("--campaign")
    campaign_ingest.add_argument("--json", action="store_true")
    campaign_next = campaign_sub.add_parser("next")
    campaign_next.add_argument(
        "suite",
        choices=(
            "terminal-bench-current",
            "terminal-bench",
            "aider-polyglot",
            "swe-bench",
        ),
    )
    for item in (campaign_next,):
        item.add_argument("--campaign")
        item.add_argument("--batch-size", type=int, default=8)
        item.add_argument("--n-concurrent", type=int, default=1)
        item.add_argument("--timeout", type=float, default=604800)
        item.add_argument("--json", action="store_true")
    campaign_run = campaign_sub.add_parser("run")
    campaign_run.add_argument(
        "suite",
        choices=(
            "harnessbench",
            "terminal-bench-current",
            "terminal-bench",
            "aider-polyglot",
            "swe-bench",
            "arc-agi-3",
        ),
    )
    campaign_run.add_argument("--campaign")
    campaign_run.add_argument("--batch-size", type=int, default=8)
    campaign_run.add_argument("--n-concurrent", type=int, default=1)
    campaign_run.add_argument("--timeout", type=float, default=604800)
    campaign_run.add_argument("--json", action="store_true")
    campaign_run.add_argument("--until-blocked", action="store_true")
    campaign_arm = campaign_sub.add_parser("arm")
    campaign_arm.add_argument("--campaign")
    campaign_arm.add_argument("--batch-size", type=int, default=8)
    campaign_arm.add_argument("--n-concurrent", type=int, default=1)
    campaign_arm.add_argument("--timeout", type=float, default=604800)
    campaign_arm.add_argument("--poll-seconds", type=float, default=900)
    campaign_arm.add_argument("--max-load", type=float)
    campaign_arm.add_argument("--json", action="store_true")
    campaign_supervise = campaign_sub.add_parser("supervise")
    campaign_supervise.add_argument("--campaign")
    campaign_supervise.add_argument("--batch-size", type=int, default=8)
    campaign_supervise.add_argument("--n-concurrent", type=int, default=1)
    campaign_supervise.add_argument("--timeout", type=float, default=604800)
    campaign_supervise.add_argument("--poll-seconds", type=float, default=900)
    campaign_supervise.add_argument("--max-load", type=float)
    campaign_supervise.add_argument("--once", action="store_true")
    campaign_supervise.add_argument("--json", action="store_true")
    campaign_sub.add_parser("disarm").add_argument("--json", action="store_true")
    campaign_sub.add_parser("armed").add_argument("--json", action="store_true")
    return parser


def main(argv, settings):
    args = build_parser().parse_args(argv)
    if args.command == "run":
        return run_benchmark(args, settings)
    if args.command == "status":
        return status_benchmark(args, settings)
    if args.command == "external":
        return comparable_benchmark(args, settings)
    if args.command == "official-quality":
        return official_quality_benchmark(args, settings)
    if args.command == "campaign":
        return campaign_benchmark(args, settings)
    return list_benchmark(args, settings)
