import json
import hashlib
import math
import os
import secrets
import shutil
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path
from urllib import request
from urllib.parse import urlsplit

from .benchmark_receipt import require_exact_sol, source_revision, write_receipt
from .codex_runner import CodexRunner
from .profiles import SOL_MODEL
from .quota import quota_info_from_text, require_quota_available
from .settings import should_start_new_session


ARC_REPOSITORY = "https://github.com/arcprize/arc-agi-3-benchmarking.git"
ARC_CONFIG_ID = "black-label-operator-gpt-5-6-sol"
ARC_OFFICIAL_GAMES = 25
ARC_FULL_CONCURRENCY = 4
ARC_REQUEST_RETRIES = 10
ARC_OFFICIAL_HOSTS = frozenset(("arcprize.org", "three.arcprize.org"))


def _run_id():
    return time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def _official_arc_origin(base_url):
    parsed = urlsplit(str(base_url))
    return (
        parsed.scheme == "https"
        and parsed.hostname in ARC_OFFICIAL_HOSTS
        and parsed.port in (None, 443)
        and parsed.path.rstrip("/") == ""
        and not parsed.query
        and not parsed.fragment
    )


def find_arc_harness(settings):
    configured = os.environ.get("OPERATOR_ARC_HARNESS")
    candidates = [
        Path(configured).expanduser() if configured else None,
        settings.repo_root / "benchmarks/vendor/arc-agi-3-benchmarking",
        settings.home / "sources/arc-agi-3-benchmarking",
    ]
    for candidate in candidates:
        if candidate and (candidate / "benchmarking/model_config.py").is_file():
            return candidate.resolve()
    return None


def ensure_arc_harness(settings):
    existing = find_arc_harness(settings)
    if existing:
        return existing
    destination = settings.home / "sources/arc-agi-3-benchmarking"
    destination.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["git", "clone", "--depth", "1", ARC_REPOSITORY, str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=300,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("ARC-AGI-3 harness clone failed: %s" % completed.stdout[-2000:])
    return destination.resolve()


def _model_config(settings, _token, timeout):
    return """- id: \"{config_id}\"
  agent:
    MAX_ACTIONS_BASELINE_MULTIPLIER: 5.0
    MAX_CONTEXT_LENGTH: 120000
    MAX_RETRIES: {retries}
    MAX_RUNTIME_SECONDS: {timeout}
  runtime:
    sdk: \"openai-python\"
    api: \"responses\"
    state: \"previous_response_id\"
  client:
    base_url: \"http://127.0.0.1:{port}/v1\"
    api_key_env: \"OPERATOR_ARC_TOKEN\"
  request:
    model: \"{model}\"
    max_output_tokens: 64000
    reasoning:
      effort: \"max\"
  pricing:
    input: 0.0
    output: 0.0
""".format(
        config_id=ARC_CONFIG_ID,
        timeout=max(60, int(timeout) - 30),
        port=settings.port,
        model=SOL_MODEL,
        retries=ARC_REQUEST_RETRIES,
    )


def _wrapper_source(max_concurrency=ARC_FULL_CONCURRENCY):
    return """import sys
import threading
import time
from pathlib import Path

harness = Path(sys.argv.pop(1)).resolve()
config = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(harness))
from benchmarking import model_config
from benchmarking.agent import BenchmarkingAgent
model_config.MODEL_CONFIG_PATH = config

_original_system_prompt = BenchmarkingAgent._build_system_prompt
_original_agent_main = BenchmarkingAgent.main
_original_call_api = BenchmarkingAgent._call_api
_game_gate = threading.BoundedSemaphore(__ARC_CONCURRENCY__)

def _operator_system_prompt(self):
    return _original_system_prompt(self) + "\\nPublic game identifier: %s." % self.game_id

def _bounded_agent_main(self):
    with _game_gate:
        return _original_agent_main(self)

def _backoff_call_api(self, model_request):
    try:
        response = _original_call_api(self, model_request)
    except Exception:
        failures = getattr(self, "_operator_transport_failures", 0) + 1
        self._operator_transport_failures = failures
        time.sleep(min(30, 2 ** min(failures, 4)))
        raise
    self._operator_transport_failures = 0
    return response

BenchmarkingAgent._build_system_prompt = _operator_system_prompt
BenchmarkingAgent.main = _bounded_agent_main
BenchmarkingAgent._call_api = _backoff_call_api
import main as arc_main
arc_main.main()
""".replace("__ARC_CONCURRENCY__", str(max(1, int(max_concurrency))))


def _recording_summary(recordings_dir):
    summaries = []
    for path in sorted(Path(recordings_dir).glob("*.recording.jsonl")):
        events = []
        invalid_lines = []
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                invalid_lines.append(len(events) + len(invalid_lines) + 1)
                continue
            if not isinstance(event, dict):
                invalid_lines.append(len(events) + len(invalid_lines) + 1)
                continue
            events.append(event)
        last = (events[-1].get("data") if events else None) or {}
        final_frame = next(
            (
                data
                for event in reversed(events)
                for data in [event.get("data")]
                if isinstance(data, dict)
                and data.get("win_levels") is not None
                and data.get("levels_completed") is not None
            ),
            last,
        )
        game_ids = sorted(
            {
                str(data.get("game_id"))
                for event in events
                for data in [event.get("data")]
                if isinstance(data, dict) and data.get("game_id")
            }
        )
        guids = sorted(
            {
                str(data.get("guid"))
                for event in events
                for data in [event.get("data")]
                if isinstance(data, dict) and data.get("guid")
            }
        )
        summaries.append(
            {
                "path": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "events": len(events),
                "invalid_lines": invalid_lines,
                "game_ids": game_ids,
                "guids": guids,
                "levels_completed": final_frame.get("levels_completed"),
                "win_levels": final_frame.get("win_levels"),
                "scorecard": last,
            }
        )
    return summaries


def _available_games(base_url, arc_key):
    api_request = request.Request(
        "%s/api/games" % base_url.rstrip("/"),
        headers={"Accept": "application/json", "X-API-Key": arc_key},
    )
    with request.urlopen(api_request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, list):
        raise RuntimeError("ARC games endpoint returned an unexpected payload")
    return sorted(
        str(item["game_id"])
        for item in payload
        if isinstance(item, dict) and item.get("game_id")
    )


def _anonymous_arc_key(base_url):
    api_request = request.Request(
        "%s/api/games/anonkey" % base_url.rstrip("/"),
        headers={"Accept": "application/json"},
    )
    with request.urlopen(api_request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    key = payload.get("api_key") if isinstance(payload, dict) else None
    if not isinstance(key, str) or not key.strip():
        raise RuntimeError("ARC anonymous key endpoint returned no API key")
    return key.strip()


def _arc_subprocess_env(token, recordings, base_url, arc_key):
    env = os.environ.copy()
    env["OPERATOR_ARC_TOKEN"] = token
    env["OPENAI_API_KEY"] = token
    env["RECORDINGS_DIR"] = str(recordings)
    env["ARC_BASE_URL"] = base_url
    env["ARC_API_KEY"] = arc_key
    return env


@contextmanager
def isolated_arc_daemon(settings, run_dir, workers):
    from .daemon import OperatorDaemon

    isolated_settings = replace(
        settings,
        home=Path(run_dir) / "operator-home",
        port=0,
        workers=max(1, int(workers)),
    )
    isolated_settings.ensure_dirs()
    daemon = OperatorDaemon(isolated_settings)
    failures = []

    def serve():
        try:
            daemon.serve()
        except BaseException as exc:
            failures.append(exc)

    thread = threading.Thread(target=serve, name="arc-operator-daemon", daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while daemon.http is None and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.05)
    if daemon.http is None:
        daemon.stop()
        thread.join(timeout=5)
        detail = str(failures[0]) if failures else "startup timed out"
        raise RuntimeError("isolated ARC daemon failed: %s" % detail)

    active_settings = replace(
        isolated_settings,
        port=int(daemon.http.server_address[1]),
    )
    try:
        yield daemon, active_settings
    finally:
        for state in ("queued", "running"):
            for task in daemon.store.list(limit=100000, state=state):
                daemon.store.request_cancel(task["id"])
        daemon.stop()
        thread.join(timeout=15)
        if thread.is_alive():
            raise RuntimeError("isolated ARC daemon did not stop gracefully")
        if failures:
            raise RuntimeError("isolated ARC daemon failed: %s" % failures[0])


def _scorecard_from_log(log_text):
    marker = "--- FINAL SCORECARD REPORT ---"
    marker_at = log_text.rfind(marker)
    if marker_at < 0:
        return None
    fragment = log_text[marker_at + len(marker) :]
    object_at = fragment.find("{")
    if object_at < 0:
        return None
    try:
        scorecard, _ = json.JSONDecoder().raw_decode(fragment[object_at:])
    except json.JSONDecodeError:
        return None
    if not isinstance(scorecard, dict):
        return None
    scorecard.pop("api_key", None)
    return scorecard


def _scorecard_game_count(scorecard):
    if not scorecard:
        return 0
    environments = scorecard.get("environments")
    return len(environments) if isinstance(environments, list) else 0


def _number(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _scorecard_game_ids(scorecard):
    environments = scorecard.get("environments") if isinstance(scorecard, dict) else None
    if not isinstance(environments, list):
        return []
    return [
        str(environment.get("id"))
        for environment in environments
        if isinstance(environment, dict) and environment.get("id")
    ]


def _scorecard_integrity(
    scorecard,
    expected_games,
    recordings,
    required_tags=("black-label-operator", "exact-sol", "full-public-set"),
):
    """Fail-closed validation of the official scorecard and local recordings."""
    errors = []
    expected = [str(game) for game in expected_games]
    if len(expected) != ARC_OFFICIAL_GAMES:
        errors.append(
            "public game snapshot has %d entries, expected %d"
            % (len(expected), ARC_OFFICIAL_GAMES)
        )
    if len(set(expected)) != len(expected):
        errors.append("public game snapshot contains duplicate game IDs")
    if not isinstance(scorecard, dict):
        return {
            "valid": False,
            "errors": errors + ["official scorecard is missing"],
            "expected_game_ids": sorted(set(expected)),
            "scorecard_game_ids": [],
            "recording_game_ids": [],
            "recomputed_score": None,
        }
    if not isinstance(scorecard.get("card_id"), str) or not scorecard.get(
        "card_id"
    ):
        errors.append("scorecard card_id is missing")
    tags = scorecard.get("tags")
    if not isinstance(tags, list) or not set(required_tags).issubset(
        {str(tag) for tag in tags}
    ):
        errors.append("scorecard is missing required run-identity tags")
    environments = scorecard.get("environments")
    if not isinstance(environments, list):
        environments = []
        errors.append("scorecard environments is not a list")
    scorecard_ids = _scorecard_game_ids(scorecard)
    if len(scorecard_ids) != len(environments):
        errors.append("one or more scorecard environments has no ID")
    if len(set(scorecard_ids)) != len(scorecard_ids):
        errors.append("scorecard contains duplicate environment IDs")
    if set(scorecard_ids) != set(expected):
        errors.append("scorecard environment IDs do not match the public snapshot")

    environment_scores = []
    scorecard_guids = set()
    for environment in environments:
        if not isinstance(environment, dict):
            errors.append("scorecard environment is not an object")
            continue
        environment_id = environment.get("id")
        environment_score = environment.get("score")
        if not _number(environment_score) or not 0 <= float(environment_score) <= 100:
            errors.append("environment %s has an invalid score" % environment_id)
        else:
            environment_scores.append(float(environment_score))
        runs = environment.get("runs")
        if not isinstance(runs, list) or not runs:
            errors.append("environment %s contains no scored runs" % environment_id)
            continue
        computed_run_scores = []
        for run in runs:
            if not isinstance(run, dict):
                errors.append("environment %s contains a malformed run" % environment_id)
                continue
            if run.get("id") != environment_id:
                errors.append("environment %s contains a run for another ID" % environment_id)
            run_score = run.get("score")
            if not _number(run_score) or not 0 <= float(run_score) <= 100:
                errors.append("environment %s contains an invalid run score" % environment_id)
            else:
                computed_run_scores.append(float(run_score))
            for field in ("levels_completed", "actions"):
                value = run.get(field)
                if type(value) is not int or value < 0:
                    errors.append(
                        "environment %s contains invalid %s" % (environment_id, field)
                    )
            guid = run.get("guid")
            if guid:
                scorecard_guids.add(str(guid))
        if computed_run_scores and _number(environment_score):
            if not math.isclose(
                max(computed_run_scores),
                float(environment_score),
                rel_tol=0,
                abs_tol=1e-7,
            ):
                errors.append(
                    "environment %s score does not equal its best run" % environment_id
                )

    official_score = scorecard.get("score")
    recomputed_score = (
        sum(environment_scores) / len(environment_scores)
        if len(environment_scores) == len(environments) and environments
        else None
    )
    if not _number(official_score) or not 0 <= float(official_score) <= 100:
        errors.append("scorecard aggregate score is invalid")
    elif recomputed_score is None or not math.isclose(
        float(official_score), recomputed_score, rel_tol=0, abs_tol=1e-7
    ):
        errors.append("scorecard aggregate does not match its environment scores")

    recording_ids = set()
    recording_guids = set()
    if not recordings:
        errors.append("no official recordings were preserved")
    for recording in recordings:
        if recording.get("invalid_lines"):
            errors.append("recording %s contains invalid JSON lines" % recording.get("path"))
        game_ids = recording.get("game_ids") or []
        if len(game_ids) != 1:
            errors.append("recording %s does not identify exactly one game" % recording.get("path"))
        recording_ids.update(str(game) for game in game_ids)
        recording_guids.update(str(guid) for guid in (recording.get("guids") or []))
        if not recording.get("events"):
            errors.append("recording %s contains no events" % recording.get("path"))
        if not isinstance(recording.get("sha256"), str):
            errors.append("recording %s has no content hash" % recording.get("path"))
    if recording_ids != set(expected):
        errors.append("recording game IDs do not match the public snapshot")
    if scorecard_guids and not scorecard_guids.issubset(recording_guids):
        errors.append("scorecard run GUIDs are missing from preserved recordings")

    return {
        "valid": not errors,
        "errors": errors,
        "expected_game_ids": sorted(set(expected)),
        "scorecard_game_ids": sorted(set(scorecard_ids)),
        "recording_game_ids": sorted(recording_ids),
        "recomputed_score": recomputed_score,
        "scorecard_sha256": hashlib.sha256(
            json.dumps(scorecard, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
        ).hexdigest(),
    }


def _operator_task_summary(store):
    counts = store.counts()
    failed_by_type = {}
    for task in store.list(limit=100000, state="failed"):
        error = str(task.get("error") or "")
        failure_type = (
            "ProviderQuotaExceeded"
            if quota_info_from_text(error) is not None
            else "ProviderTurnFailed"
        )
        failed_by_type[failure_type] = failed_by_type.get(failure_type, 0) + 1
    incomplete_states = {
        state: int(counts.get(state) or 0)
        for state in ("failed", "cancelled", "queued", "running")
        if int(counts.get(state) or 0) > 0
    }
    return {
        "counts": counts,
        "failed_by_type": failed_by_type,
        "clean": not incomplete_states,
        "incomplete_states": incomplete_states,
    }


def _full_run_complete(
    *,
    all_games,
    timed_out,
    exit_code,
    available_games,
    scorecard_games,
    benchmark_score,
    operator_tasks,
    score_integrity,
    termination_confirmed,
):
    return bool(
        all_games
        and not timed_out
        and exit_code == 0
        and len(available_games) == ARC_OFFICIAL_GAMES
        and len(set(available_games)) == ARC_OFFICIAL_GAMES
        and scorecard_games == ARC_OFFICIAL_GAMES
        and _number(benchmark_score)
        and operator_tasks.get("clean") is True
        and score_integrity.get("valid") is True
        and termination_confirmed is True
    )


def _blocked_receipt(run_dir, settings, harness, game, reason, started):
    marker = {
        "blocked": True,
        "reason": reason,
        "required": "ARC_API_KEY or the official anonymous key endpoint",
        "benchmark_score": None,
        "leaderboard_score": None,
        "statement": "No ARC-AGI-3 game ran; no benchmark score exists.",
    }
    (run_dir / "blocked.json").write_text(
        json.dumps(marker, indent=2, sort_keys=True), encoding="utf-8"
    )
    receipt = write_receipt(
        run_dir,
        suite="arc-agi-3",
        status="blocked",
        settings=settings,
        command=[],
        scope={
            "game": game,
            "harness": str(harness),
            "harness_revision": source_revision(harness),
            "run_kind": "blocked",
            "score_eligible": False,
        },
        result=marker,
        started_at=started,
    )
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 1


def run_arc_agi3(args, settings):
    require_quota_available(settings.benchmark_dir)
    require_exact_sol("codex", SOL_MODEL, settings.model, "sol-benchmark")
    harness = ensure_arc_harness(settings)
    run_dir = settings.benchmark_dir / "arc-agi-3" / _run_id()
    run_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    base_url = os.environ.get("ARC_BASE_URL", "https://arcprize.org").rstrip("/")
    try:
        arc_key = os.environ.get("ARC_API_KEY", "").strip() or _anonymous_arc_key(
            base_url
        )
    except Exception as exc:
        return _blocked_receipt(
            run_dir,
            settings,
            harness,
            args.game,
            "ARC access-key acquisition failed: %s" % exc,
            started,
        )

    all_games = bool(getattr(args, "all_games", False))
    if all_games and args.game not in (None, "", "ls20"):
        raise RuntimeError("--all-games cannot be combined with --game")
    available_games = _available_games(base_url, arc_key)
    if not available_games or len(set(available_games)) != len(available_games):
        raise RuntimeError(
            "ARC games endpoint returned an empty or duplicate public-game set"
        )
    if all_games and len(available_games) != ARC_OFFICIAL_GAMES:
        raise RuntimeError(
            "ARC full run requires %d public games; credential exposes %d"
            % (ARC_OFFICIAL_GAMES, len(available_games))
        )
    public_snapshot = {
        "captured_at": time.time(),
        "base_url": base_url,
        "game_ids": available_games,
        "count": len(available_games),
        "game_ids_sha256": hashlib.sha256(
            "\n".join(available_games).encode("utf-8")
        ).hexdigest(),
        "harness_revision": source_revision(harness),
    }
    (run_dir / "public-games.json").write_text(
        json.dumps(public_snapshot, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    worker_count = ARC_FULL_CONCURRENCY if all_games else 1
    with isolated_arc_daemon(settings, run_dir, worker_count) as (
        daemon,
        arc_settings,
    ):
        token = secrets.token_urlsafe(32)
        daemon.store.register_client(
            token,
            settings.repo_root,
            ttl_seconds=max(3600, int(args.timeout) + 600),
            label="arc-agi-3",
        )
        config_path = run_dir / "model-configs.yaml"
        config_path.write_text(
            _model_config(arc_settings, token, args.timeout), encoding="utf-8"
        )
        wrapper_path = run_dir / "run_official.py"
        wrapper_path.write_text(
            _wrapper_source(worker_count),
            encoding="utf-8",
        )
        recordings = run_dir / "recordings"
        recordings.mkdir()
        uv = shutil.which("uv")
        if not uv:
            raise RuntimeError("uv is required for ARC-AGI-3")
        command = [
            uv,
            "run",
            "--project",
            str(harness),
            "python",
            str(wrapper_path),
            str(harness),
            str(config_path),
        ]
        if not all_games:
            command.extend(["--game", args.game])
        command.extend(
            [
                "--config",
                ARC_CONFIG_ID,
                "--tags",
                "black-label-operator,exact-sol,"
                + ("full-public-set" if all_games else "smoke"),
            ]
        )
        (run_dir / "command.json").write_text(
            json.dumps(
                {
                    "provider": "codex",
                    "profile": "sol-benchmark",
                    "requested_model": SOL_MODEL,
                    "resolved_model": SOL_MODEL,
                    "operator_workers": worker_count,
                    "game_concurrency": worker_count,
                    "argv": command,
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        env = _arc_subprocess_env(token, recordings, base_url, arc_key)
        timed_out = False
        termination_confirmed = True
        termination_detail = None
        with (run_dir / "arc.stdout.log").open("w", encoding="utf-8") as stdout, (
            run_dir / "arc.stderr.log"
        ).open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(
                command,
                cwd=str(run_dir),
                env=env,
                stdout=stdout,
                stderr=stderr,
                text=True,
                start_new_session=should_start_new_session(),
            )
            try:
                process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                termination_confirmed, termination_detail = (
                    CodexRunner.terminate_spawned(process)
                )
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    termination_confirmed = False
                    termination_detail = (
                        (termination_detail + "; ") if termination_detail else ""
                    ) + "ARC harness root process remained live after termination"
        operator_tasks = _operator_task_summary(daemon.store)

    recording_summary = _recording_summary(recordings)
    log_text = (run_dir / "arc.stdout.log").read_text(
        encoding="utf-8", errors="replace"
    )
    scorecard = _scorecard_from_log(log_text)
    if scorecard:
        (run_dir / "scorecard.json").write_text(
            json.dumps(scorecard, indent=2, sort_keys=True), encoding="utf-8"
        )
    scorecard_games = _scorecard_game_count(scorecard)
    benchmark_score = scorecard.get("score") if scorecard else None
    score_integrity = (
        _scorecard_integrity(scorecard, available_games, recording_summary)
        if all_games
        else {
            "valid": False,
            "errors": ["single-game smoke runs are not full-set score eligible"],
            "expected_game_ids": available_games,
            "scorecard_game_ids": _scorecard_game_ids(scorecard or {}),
            "recording_game_ids": sorted(
                {
                    game_id
                    for recording in recording_summary
                    for game_id in recording.get("game_ids") or []
                }
            ),
            "recomputed_score": None,
        }
    )
    if all_games and not _official_arc_origin(base_url):
        score_integrity["errors"].append(
            "full-set score did not come from an official ARC Prize HTTPS origin"
        )
        score_integrity["valid"] = False
    full_complete = _full_run_complete(
        all_games=all_games,
        timed_out=timed_out,
        exit_code=process.returncode,
        available_games=available_games,
        scorecard_games=scorecard_games,
        benchmark_score=benchmark_score,
        operator_tasks=operator_tasks,
        score_integrity=score_integrity,
        termination_confirmed=termination_confirmed,
    )
    won = any(
        item.get("levels_completed") == item.get("win_levels")
        and item.get("win_levels") not in (None, 0)
        for item in recording_summary
    )
    if timed_out:
        status = "incomplete"
    elif process.returncode not in (0, None) and not recording_summary:
        status = "blocked"
    elif all_games:
        status = "passed" if full_complete else "incomplete"
    else:
        status = "passed" if won else "failed"
    result = {
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "termination_confirmed": termination_confirmed,
        "termination_detail": termination_detail,
        "won": won,
        "recordings": recording_summary,
        "available_games": available_games,
        "completed_games": scorecard_games,
        "scorecard": scorecard,
        "score_integrity": score_integrity,
        "public_game_snapshot": public_snapshot,
        "benchmark_score": benchmark_score if full_complete else None,
        "leaderboard_score": None,
        "statement": (
            "Complete local ARC-AGI-3 public-set score from one official "
            "25-game scorecard; no leaderboard claim."
            if full_complete
            else (
                "ARC-AGI-3 scorecard is diagnostic only because the run was "
                "incomplete or contained failed provider turns."
                if all_games
                else "Single-game ARC-AGI-3 evidence is a smoke run, not a full "
                "benchmark or leaderboard score."
            )
        ),
        "operator_tasks": operator_tasks,
    }
    receipt = write_receipt(
        run_dir,
        suite="arc-agi-3",
        status=status,
        settings=settings,
        command=command,
        scope={
            "game": None if all_games else args.game,
            "available_games": len(available_games),
            "official_games": ARC_OFFICIAL_GAMES,
            "harness": str(harness),
            "harness_revision": source_revision(harness),
            "run_kind": "full" if all_games else "smoke",
            "score_eligible": full_complete,
            "operator_workers": worker_count,
            "game_concurrency": worker_count,
            "request_retries": ARC_REQUEST_RETRIES,
        },
        result=result,
        started_at=started,
    )
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if status == "passed" else 1
