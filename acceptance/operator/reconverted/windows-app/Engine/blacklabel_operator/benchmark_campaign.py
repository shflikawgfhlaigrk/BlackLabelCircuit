import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from .benchmark_receipt import (
    SOL_BENCHMARK_PROFILE,
    require_exact_sol,
    source_files,
    source_identity,
)
from .codex_runner import CodexRunner
from .profiles import SOL_MODEL
from .quota import active_quota_block, probe_exact_sol, record_quota_available
from .settings import SUPERVISED_PROCESS_GROUP_ENV
from .standard_benchmark import (
    EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA,
    EXTERNAL_NUMBER_ONE_LANES,
    EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER,
    EXTERNAL_TARGET_MAX_AGE_SECONDS,
    HARBOR_SUITES,
    NUMBER_ONE_GATES,
    OFFICIAL_QUALITY_EVIDENCE_SCHEMA,
    OFFICIAL_QUALITY_LANES,
    OFFICIAL_QUALITY_MINIMUM_SCORE,
    OFFICIAL_QUALITY_SCORE_SCALE,
    OFFICIAL_QUALITY_STATUS_SCHEMA,
    TERMINAL_BENCH_SUITES,
    external_number_one_contract,
    official_quality_contract,
    strict_json_loads,
    validate_atif_trajectory,
)

LEGACY_CAMPAIGN_SCHEMA = "black-label-operator/benchmark-campaign-v1"
CAMPAIGN_SCHEMA = "black-label-operator/benchmark-campaign-v2"
CAMPAIGN_STATUS_SCHEMA = "black-label-operator/benchmark-campaign-status-v3"
EVENT_CHAIN_SCHEMA = "black-label-operator/benchmark-event-chain-v1"
EVENT_HEAD_SCHEMA = "black-label-operator/benchmark-event-head-v1"
SUPPORTED_CAMPAIGN_SCHEMAS = (LEGACY_CAMPAIGN_SCHEMA, CAMPAIGN_SCHEMA)
CAMPAIGN_SUITES = (
    "harnessbench",
    "terminal-bench",
    "terminal-bench-current",
    "aider-polyglot",
    "swe-bench",
    "arc-agi-3",
)
LEGACY_CAMPAIGN_SUITES = tuple(
    suite for suite in CAMPAIGN_SUITES if suite != "terminal-bench-current"
)
HARBOR_CAMPAIGN_SUITES = (
    "terminal-bench",
    "terminal-bench-current",
    "aider-polyglot",
    "swe-bench",
)
SUPERVISOR_HARBOR_ORDER = (
    "terminal-bench-current",
    "aider-polyglot",
    "terminal-bench",
    "swe-bench",
)
DEFAULT_THRESHOLD = 0.91
DEFAULT_MAX_LOAD_PER_CPU = 1.25
DEFAULT_DATASET_RESOLVER_TIMEOUT = 600
DEFAULT_DATASET_RESOLVER_ATTEMPTS = 3
SUPERVISOR_CONCURRENCY_LIMITS = {
    "aider-polyglot": 4,
    "terminal-bench": 1,
    "terminal-bench-current": 1,
    "swe-bench": 1,
}
SUPERVISOR_BATCH_LIMITS = {
    "aider-polyglot": 8,
    "terminal-bench": 2,
    "terminal-bench-current": 2,
    "swe-bench": 2,
}
CAMPAIGN_REVIEW_PASSES = 2
REDACTION_PATTERN = re.compile(r"(:\s*)\[REDACTED\](\s*[,}])")
OFFICIAL_QUALITY_EVIDENCE_KEYS = frozenset(
    {
        "schema",
        "lane",
        "protocol",
        "campaign",
        "operator_source",
        "identity",
        "score_scope",
        "official_score",
        "organizer_verification",
        "organizer_receipt",
    }
)
OFFICIAL_QUALITY_SCORE_KEYS = frozenset(
    {"value", "scale", "origin", "locally_derived"}
)
OFFICIAL_QUALITY_VERIFICATION_KEYS = frozenset(
    {
        "method",
        "signature_algorithm",
        "receipt_schema",
        "trust_root_id",
        "trust_root_sha256",
    }
)
OFFICIAL_QUALITY_ARTIFACT_KEYS = frozenset({"path", "sha256"})


DATASET_RESOLVER_SOURCE = r'''import asyncio
import json
import sys
from pathlib import Path

from harbor.registry.client.factory import RegistryClientFactory


async def main():
    repo = json.loads(sys.argv[2])
    registry_path = json.loads(sys.argv[3])
    if registry_path is not None:
        registry_path = Path(registry_path)
    client = RegistryClientFactory.create(
        **{
            key: value
            for key, value in (("repo", repo), ("registry_path", registry_path))
            if value is not None
        }
    )
    resolution_mode = "repo_registry_path" if repo else "registry"
    try:
        metadata = await client.get_dataset_metadata(sys.argv[1])
    except ValueError as exc:
        # Harbor 0.22 documents registry_path as registry.json-only in its Git
        # client even though current repositories publish dataset.toml. Keep the
        # requested factory path above, then use its equivalent implicit Git
        # dataset path on that installed generation.
        if (
            repo is None
            or registry_path is None
            or registry_path.suffix != ".toml"
            or "registry.json not found" not in str(exc)
        ):
            raise
        client = RegistryClientFactory.create(repo=repo, path=registry_path.parent)
        metadata = await client.get_dataset_metadata("")
        resolution_mode = "repo_dataset_manifest_compatibility"
    tasks = [
        {"name": task.get_name(), "identity": task.model_dump(mode="json")}
        for task in metadata.task_ids
    ]
    print(json.dumps({
        "name": metadata.name,
        "version": metadata.version,
        "tasks": tasks,
        "resolution_mode": resolution_mode,
    }, sort_keys=True))


asyncio.run(main())
'''


def _sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(payload):
    return _sha256_bytes(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )


def default_max_load():
    return round(max(1, int(os.cpu_count() or 1)) * DEFAULT_MAX_LOAD_PER_CPU, 2)


def resource_snapshot(max_load):
    max_load = float(max_load)
    if max_load <= 0:
        raise ValueError("campaign max load must be positive")
    try:
        load_1m = float(os.getloadavg()[0])
    except (AttributeError, OSError):
        load_1m = 0.0
    return {
        "load_1m": round(load_1m, 2),
        "max_load": round(max_load, 2),
        "logical_cpus": max(1, int(os.cpu_count() or 1)),
        "ready": load_1m <= max_load,
    }


def supervisor_concurrency(suite, requested):
    requested = max(1, int(requested))
    return min(requested, SUPERVISOR_CONCURRENCY_LIMITS.get(suite, requested))


def supervisor_batch_size(suite, requested):
    requested = max(1, int(requested))
    return min(requested, SUPERVISOR_BATCH_LIMITS.get(suite, requested))


def next_supervisor_suite(status, batch_size):
    suites = {item["suite"]: item for item in status["suites"]}
    harness = suites["harnessbench"]
    if not harness["threshold_met"]:
        return "harnessbench"

    pending_harbor = [
        suite
        for suite in SUPERVISOR_HARBOR_ORDER
        if suite in suites and not suites[suite]["threshold_met"]
    ]
    if pending_harbor:
        order = {suite: index for index, suite in enumerate(SUPERVISOR_HARBOR_ORDER)}
        return min(
            pending_harbor,
            key=lambda suite: (
                int(
                    suites[suite].get("completed_trials")
                    if suites[suite].get("completed_trials") is not None
                    else suites[suite].get("completed_tasks") or 0
                )
                // supervisor_batch_size(suite, batch_size),
                order[suite],
            ),
        )

    if not suites["arc-agi-3"]["threshold_met"]:
        return "arc-agi-3"
    return None


def _load_json(path):
    raw = Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        return strict_json_loads(raw)
    except json.JSONDecodeError:
        return strict_json_loads(
            REDACTION_PATTERN.sub(r'\1"[REDACTED]"\2', raw)
        )


def _write_json(path, payload):
    Path(path).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _write_json_atomic(path, payload):
    path = Path(path)
    staging = path.with_name(".%s.%s.tmp" % (path.name, uuid.uuid4().hex))
    try:
        _write_json(staging, payload)
        os.replace(staging, path)
    finally:
        if staging.exists():
            staging.unlink()


@contextmanager
def _campaign_lock(campaign_dir, shared=False):
    lock_path = Path(campaign_dir) / "campaign.lock"
    with lock_path.open("a+") as handle:
        operation = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        fcntl.flock(handle.fileno(), operation)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def freeze_source(source_root, sources_dir):
    source_root = Path(source_root).resolve()
    sources_dir = Path(sources_dir).resolve()
    identity_before = source_identity(source_root)
    tree_hash = identity_before["tree_sha256"]
    destination = sources_dir / ("operator-" + tree_hash)
    if destination.exists():
        identity = source_identity(destination)
        if identity["tree_sha256"] != tree_hash:
            raise RuntimeError("existing frozen source does not match its path identity")
        return destination, identity

    sources_dir.mkdir(parents=True, exist_ok=True)
    staging = sources_dir / (".operator-%s-%s" % (tree_hash, uuid.uuid4().hex))
    staging.mkdir()
    try:
        for source in source_files(source_root):
            relative = source.relative_to(source_root)
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            source_mode = source.stat().st_mode & 0o777
            target.chmod(0o444 | (source_mode & 0o111))
        identity_after = source_identity(source_root)
        if identity_after["tree_sha256"] != tree_hash:
            raise RuntimeError("Operator source changed while it was being frozen")
        frozen_identity = source_identity(staging)
        if frozen_identity["tree_sha256"] != tree_hash:
            raise RuntimeError("frozen Operator source failed byte-for-byte verification")
        for directory in sorted(
            (path for path in staging.rglob("*") if path.is_dir()),
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            directory.chmod(0o555)
        staging.chmod(0o555)
        os.replace(staging, destination)
        return destination, source_identity(destination)
    except Exception:
        if staging.exists():
            for path in staging.rglob("*"):
                if path.is_dir():
                    path.chmod(0o755)
                elif path.is_file():
                    path.chmod(0o644)
            staging.chmod(0o755)
            shutil.rmtree(staging)
        raise


def _harbor_interpreter(harbor_executable=None):
    executable = Path(harbor_executable or shutil.which("harbor") or "")
    if not executable.is_file():
        raise RuntimeError("Harbor is not installed")
    first_line = executable.read_text(encoding="utf-8", errors="replace").splitlines()[0]
    if not first_line.startswith("#!"):
        raise RuntimeError("unable to resolve Harbor's Python interpreter")
    interpreter = Path(first_line[2:].strip())
    if not interpreter.is_file():
        raise RuntimeError("Harbor's Python interpreter is missing")
    return interpreter, executable.resolve()


def resolve_harbor_dataset(
    dataset,
    harbor_executable=None,
    timeout=DEFAULT_DATASET_RESOLVER_TIMEOUT,
    attempts=DEFAULT_DATASET_RESOLVER_ATTEMPTS,
    repo=None,
    registry_path=None,
    expected_commit=None,
):
    interpreter, executable = _harbor_interpreter(harbor_executable)
    timeout = float(timeout)
    attempts = int(attempts)
    if timeout <= 0 or attempts <= 0:
        raise ValueError("dataset resolver timeout and attempts must be positive")
    completed = None
    failure = None
    for attempt in range(1, attempts + 1):
        try:
            completed = subprocess.run(
                [
                    str(interpreter),
                    "-c",
                    DATASET_RESOLVER_SOURCE,
                    str(dataset),
                    json.dumps(repo),
                    json.dumps(registry_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failure = "timed out after %.1f seconds" % timeout
        else:
            if completed.returncode == 0:
                break
            failure = (
                completed.stderr.strip() or completed.stdout.strip() or "no output"
            )[-2000:]
        if attempt < attempts:
            time.sleep(min(5 * (2 ** (attempt - 1)), 30))
    if completed is None or completed.returncode != 0:
        raise RuntimeError(
            "Harbor dataset resolution failed after %d attempts: %s"
            % (attempts, failure)
        )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor returned invalid dataset metadata: %s" % exc)
    tasks = sorted(payload.get("tasks") or [], key=lambda item: item.get("name", ""))
    names = [str(item.get("name") or "") for item in tasks]
    if not names or any(not name for name in names) or len(names) != len(set(names)):
        raise RuntimeError("Harbor dataset task names are empty or duplicated")
    normalized = {
        "requested": str(dataset),
        "name": payload.get("name"),
        "version": payload.get("version"),
        "tasks": tasks,
        "harbor_executable": str(executable),
        "repo": repo,
        "registry_path": registry_path,
        "resolution_mode": payload.get("resolution_mode"),
    }
    if expected_commit is not None:
        commits = {
            (item.get("identity") or {}).get("git_commit_id") for item in tasks
        }
        if commits != {expected_commit}:
            raise RuntimeError(
                "Harbor dataset resolved commits %s; expected %s"
                % (sorted(str(item) for item in commits), expected_commit)
            )
        normalized["repository_commit"] = expected_commit
    normalized["manifest_sha256"] = _canonical_sha256(
        {
            key: normalized[key]
            for key in (
                "requested",
                "name",
                "version",
                "repo",
                "registry_path",
                "resolution_mode",
                "repository_commit",
                "tasks",
            )
            if key in normalized
        }
    )
    return normalized


def initialize_campaign(settings, threshold=DEFAULT_THRESHOLD, resolver=None):
    require_exact_sol(
        "codex", SOL_MODEL, settings.model, SOL_BENCHMARK_PROFILE
    )
    threshold = float(threshold)
    if not 0 < threshold <= 1:
        raise ValueError("campaign threshold must be in (0, 1]")
    frozen, frozen_identity = freeze_source(
        settings.repo_root, settings.home / "sources"
    )
    current_source_identity = source_identity(settings.repo_root)
    if current_source_identity["tree_sha256"] != frozen_identity["tree_sha256"]:
        raise RuntimeError("Operator source changed after it was frozen")
    resolver = resolver or resolve_harbor_dataset
    suites = {
        "harnessbench": {
            "kind": "internal_acceptance",
            "required_cases": ["ledger", "scheduler", "slugify"],
        },
        "arc-agi-3": {"kind": "official_full_run", "official_games": 25},
    }
    for suite in HARBOR_CAMPAIGN_SUITES:
        config = HARBOR_SUITES[suite]
        number_one_gate = dict(NUMBER_ONE_GATES[suite])
        resolver_kwargs = {}
        if config.get("registry_repo"):
            resolver_kwargs["repo"] = config["registry_repo"]
        if config.get("registry_path"):
            resolver_kwargs["registry_path"] = config["registry_path"]
        if config.get("repository_commit"):
            resolver_kwargs["expected_commit"] = config["repository_commit"]
        manifest = resolver(config["dataset"], **resolver_kwargs)
        if len(manifest["tasks"]) != config["official_size"]:
            raise RuntimeError(
                "%s manifest has %d tasks; expected %d"
                % (suite, len(manifest["tasks"]), config["official_size"])
            )
        expected_manifest_sha256 = config.get("official_manifest_sha256")
        if (
            expected_manifest_sha256 is not None
            and manifest.get("manifest_sha256") != expected_manifest_sha256
        ):
            raise RuntimeError(
                "%s resolved manifest does not match the pinned official identity"
                % suite
            )
        official_tasks = int(config["official_size"])
        official_attempts = int(config.get("official_attempts") or 1)
        official_trials = official_tasks * official_attempts
        if int(number_one_gate["target_trials"]) != official_trials:
            raise RuntimeError(
                "%s number-one gate targets %d trials; official protocol has %d"
                % (suite, number_one_gate["target_trials"], official_trials)
            )
        threshold_passes = int(math.ceil(threshold * official_trials))
        number_one_passes = int(number_one_gate["target_passes"])
        suites[suite] = {
            "kind": (
                "custom_harbor_non_comparable_full_run"
                if not number_one_gate["comparable"]
                else "official_harbor_comparable_full_run"
            ),
            "official_tasks": official_tasks,
            "official_attempts": official_attempts,
            "official_trials": official_trials,
            "required_passes": max(threshold_passes, number_one_passes),
            "threshold_required_passes": threshold_passes,
            "number_one_gate": number_one_gate,
            "mandatory_current_generation": bool(
                number_one_gate.get("mandatory_current_generation")
            ),
            "stock_leaderboard_comparable": bool(number_one_gate["comparable"]),
            "comparison_statement": (
                "Custom Black Label Operator Harbor results are not comparable "
                "to the stock Aider two-try model leaderboard."
                if suite == "aider-polyglot"
                else (
                    "Pinned Terminal-Bench 4.0 official Harbor results are the "
                    "current strict-beat comparison lane; local evidence still "
                    "requires an accepted organizer submission."
                    if suite == "terminal-bench-current"
                    else "This frozen Harbor protocol is eligible for lane comparison."
                )
            ),
            "dataset_source": {
                "name": config.get("dataset_name"),
                "revision": config.get("dataset_revision"),
                "digest": config.get("dataset_digest"),
                "repository": config.get("repository_url"),
                "repo": config.get("registry_repo"),
                "registry_path": config.get("registry_path"),
                "repository_tag": config.get("repository_tag"),
                "repository_commit": config.get("repository_commit"),
                "dataset_file_sha256": config.get("dataset_file_sha256"),
                "task_manifest_sha256": config.get("task_manifest_sha256"),
            },
            "dataset": manifest,
            "review_passes": CAMPAIGN_REVIEW_PASSES,
            "reasoning_effort": config.get("official_reasoning_effort") or "max",
        }
    campaign_id = "%s-%s" % (
        time.strftime("%Y%m%d-%H%M%S"),
        current_source_identity["tree_sha256"][:12],
    )
    campaign_dir = settings.benchmark_dir / "campaigns" / campaign_id
    campaign_dir.mkdir(parents=True, exist_ok=False)
    payload = {
        "schema": CAMPAIGN_SCHEMA,
        "protocol_version": 2,
        "certification_eligible": True,
        "id": campaign_id,
        "created_at": time.time(),
        "threshold": threshold,
        "identity": {
            "provider": "codex",
            "profile": SOL_BENCHMARK_PROFILE,
            "requested_model": SOL_MODEL,
            "resolved_model": SOL_MODEL,
            "exact_sol": True,
        },
        "operator_source": current_source_identity,
        "frozen_operator_source": frozen_identity,
        "operator_source_path": str(frozen),
        "certification_contracts": {
            "internal_release": {
                "scope": "internal_release",
                "required_suites": list(CAMPAIGN_SUITES),
            },
            "external_number_one": external_number_one_contract(),
            "official_quality": official_quality_contract(),
        },
        "suites": suites,
    }
    _write_json(campaign_dir / "campaign.json", payload)
    (campaign_dir / "events.jsonl").touch(mode=0o600)
    (campaign_dir / "external-evidence").mkdir(mode=0o700)
    (campaign_dir / "official-quality-evidence").mkdir(mode=0o700)
    _initialize_event_chain(campaign_dir, payload)
    return campaign_dir, payload


def find_campaign(settings, campaign=None):
    if campaign:
        path = Path(campaign).expanduser()
        if not path.is_absolute():
            path = settings.benchmark_dir / "campaigns" / path
        path = path.resolve()
        if path.name == "campaign.json":
            path = path.parent
        if not (path / "campaign.json").is_file():
            raise RuntimeError("benchmark campaign not found: %s" % campaign)
        return path
    roots = sorted(
        (
            path.parent
            for path in (settings.benchmark_dir / "campaigns").glob(
                "*/campaign.json"
            )
        ),
        key=lambda path: path.name,
    )
    if not roots:
        raise RuntimeError("no benchmark campaign exists")
    return roots[-1]


def load_campaign(campaign_dir):
    payload = _load_json(Path(campaign_dir) / "campaign.json")
    if payload.get("schema") not in SUPPORTED_CAMPAIGN_SCHEMAS:
        raise RuntimeError("unsupported benchmark campaign schema")
    return payload


def _is_v2_campaign(campaign):
    return campaign.get("schema") == CAMPAIGN_SCHEMA


def _campaign_harbor_suites(campaign):
    configured = campaign.get("suites") or {}
    return tuple(suite for suite in HARBOR_CAMPAIGN_SUITES if suite in configured)


def _event_genesis(campaign):
    return _canonical_sha256(
        {
            "schema": EVENT_CHAIN_SCHEMA,
            "campaign": campaign["id"],
            "operator_source_sha256": campaign["operator_source"]["tree_sha256"],
        }
    )


def _event_head_payload(campaign, event_count, last_event_sha256):
    payload = {
        "schema": EVENT_HEAD_SCHEMA,
        "campaign": campaign["id"],
        "operator_source_sha256": campaign["operator_source"]["tree_sha256"],
        "genesis_sha256": _event_genesis(campaign),
        "event_count": int(event_count),
        "last_event_sha256": last_event_sha256,
    }
    payload["head_sha256"] = _canonical_sha256(payload)
    return payload


def _initialize_event_chain(campaign_dir, campaign=None):
    campaign_dir = Path(campaign_dir)
    campaign = campaign or load_campaign(campaign_dir)
    if not _is_v2_campaign(campaign):
        return
    events_path = campaign_dir / "events.jsonl"
    if events_path.is_file() and events_path.stat().st_size:
        raise RuntimeError("cannot initialize an event head over an existing ledger")
    _write_json_atomic(
        campaign_dir / "events.head.json",
        _event_head_payload(campaign, 0, _event_genesis(campaign)),
    )


def _events(campaign_dir):
    campaign_dir = Path(campaign_dir)
    campaign = load_campaign(campaign_dir)
    path = Path(campaign_dir) / "events.jsonl"
    if not path.is_file():
        if _is_v2_campaign(campaign):
            raise RuntimeError("v2 campaign event ledger is missing")
        return []
    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            raise RuntimeError("campaign event ledger contains invalid JSON")
    if not _is_v2_campaign(campaign):
        return events

    source_hash = campaign["operator_source"]["tree_sha256"]
    previous = _event_genesis(campaign)
    for sequence, event in enumerate(events, start=1):
        if not isinstance(event, dict):
            raise RuntimeError("campaign event ledger entry is not an object")
        try:
            recorded_sequence = int(event.get("sequence") or 0)
        except (TypeError, ValueError):
            recorded_sequence = 0
        if recorded_sequence != sequence:
            raise RuntimeError("campaign event ledger sequence is discontinuous")
        if event.get("campaign_source_sha256") != source_hash:
            raise RuntimeError("campaign event ledger source binding is invalid")
        if event.get("previous_event_sha256") != previous:
            raise RuntimeError("campaign event ledger hash chain is discontinuous")
        recorded_hash = event.get("event_sha256")
        unhashed = dict(event)
        unhashed.pop("event_sha256", None)
        if recorded_hash != _canonical_sha256(unhashed):
            raise RuntimeError("campaign event ledger hash is invalid")
        previous = recorded_hash

    head_path = campaign_dir / "events.head.json"
    if not head_path.is_file():
        raise RuntimeError("v2 campaign event head is missing")
    head = _load_json(head_path)
    recorded_head_hash = head.get("head_sha256")
    unhashed_head = dict(head)
    unhashed_head.pop("head_sha256", None)
    if recorded_head_hash != _canonical_sha256(unhashed_head):
        raise RuntimeError("campaign event head hash is invalid")
    expected_head = _event_head_payload(campaign, len(events), previous)
    if head != expected_head:
        raise RuntimeError("campaign event ledger does not match its head")
    return events


def _append_event(campaign_dir, event):
    campaign_dir = Path(campaign_dir)
    event = dict(event)
    event.setdefault("recorded_at", time.time())
    campaign = load_campaign(campaign_dir)
    existing = _events(campaign_dir)
    if _is_v2_campaign(campaign):
        for reserved in (
            "sequence",
            "campaign_source_sha256",
            "previous_event_sha256",
            "event_sha256",
        ):
            event.pop(reserved, None)
        previous = (
            existing[-1]["event_sha256"]
            if existing
            else _event_genesis(campaign)
        )
        event.update(
            {
                "sequence": len(existing) + 1,
                "campaign_source_sha256": campaign["operator_source"][
                    "tree_sha256"
                ],
                "previous_event_sha256": previous,
            }
        )
        event["event_sha256"] = _canonical_sha256(event)
    with (campaign_dir / "events.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    if _is_v2_campaign(campaign):
        _write_json_atomic(
            campaign_dir / "events.head.json",
            _event_head_payload(campaign, len(existing) + 1, event["event_sha256"]),
        )


def _append_supervisor_event(campaign_dir, event):
    event = dict(event)
    event.setdefault("recorded_at", time.time())
    path = Path(campaign_dir) / "supervisor.jsonl"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def _record_unconfirmed_termination(campaign_dir, suite, process, detail, launcher_run):
    with _campaign_lock(campaign_dir):
        _append_event(
            campaign_dir,
            {
                "type": "termination_unconfirmed",
                "suite": suite,
                "pid": process.pid,
                "detail": detail,
                "launcher_run": str(launcher_run),
            },
        )


def _artifact_entry(receipt, relative):
    return next(
        (item for item in receipt.get("artifacts") or [] if item.get("path") == relative),
        None,
    )


def _verified_artifact(run_dir, receipt, relative):
    root = Path(run_dir).resolve()
    relative_path = Path(relative)
    if (
        not relative_path.parts
        or relative_path.is_absolute()
        or ".." in relative_path.parts
    ):
        raise RuntimeError("receipt contains an unsafe artifact path")
    entries = [
        item
        for item in receipt.get("artifacts") or []
        if isinstance(item, dict) and item.get("path") == str(relative_path)
    ]
    path = root / relative_path
    cursor = root
    for part in relative_path.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise RuntimeError("receipt artifact traverses a symbolic link")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError("receipt artifact is missing: %s" % relative) from exc
    if (
        len(entries) != 1
        or root not in resolved.parents
        or path.is_symlink()
        or not path.is_file()
    ):
        raise RuntimeError("receipt artifact is missing: %s" % relative)
    entry = entries[0]
    if (
        path.stat().st_size != entry.get("bytes", path.stat().st_size)
        or _sha256_file(path) != entry.get("sha256")
    ):
        raise RuntimeError("receipt artifact hash mismatch: %s" % relative)
    return resolved


def _external_evidence_artifact(campaign_dir, lane, entry, label):
    if not isinstance(entry, dict):
        raise RuntimeError("%s is missing" % label)
    relative = Path(str(entry.get("path") or ""))
    if not relative.parts or relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("%s path is unsafe" % label)
    expected_root = (Path(campaign_dir) / "external-evidence" / lane).resolve()
    path = Path(campaign_dir) / relative
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("%s artifact is missing or symbolic" % label)
    resolved = path.resolve()
    if resolved.parent != expected_root:
        raise RuntimeError("%s must be stored in its lane directory" % label)
    expected_hash = entry.get("sha256")
    if (
        not isinstance(expected_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)
        or _sha256_file(resolved) != expected_hash
    ):
        raise RuntimeError("%s artifact hash mismatch" % label)
    return resolved


def _external_score_meets_contract(score, contract):
    if not isinstance(score, dict):
        raise RuntimeError("score is missing")
    target = contract["target_value"]
    if contract["score_kind"] == "passes":
        passed = score.get("passed")
        total = score.get("total")
        if (
            isinstance(passed, bool)
            or isinstance(total, bool)
            or not isinstance(passed, int)
            or not isinstance(total, int)
            or total != int(contract["total"])
            or not 0 <= passed <= total
        ):
            raise RuntimeError("pass score does not match the required protocol")
        value = passed
    else:
        value = score.get("value")
        completed = score.get("completed_units")
        scale = score.get("scale")
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or not 0 <= float(value) <= 100
            or isinstance(completed, bool)
            or not isinstance(completed, int)
            or completed != int(contract["total"])
            or scale != 100
        ):
            raise RuntimeError("scalar score does not match the required protocol")
    if contract["target_operator"] == "gt":
        return bool(value > target)
    if contract["target_operator"] == "gte":
        return bool(value >= target)
    raise RuntimeError("external evidence contract has an unknown target operator")


def _external_timestamp(value, label):
    if isinstance(value, bool):
        raise RuntimeError("%s timestamp is invalid" % label)
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    if isinstance(value, str) and value.strip():
        normalized = value.strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError as exc:
            raise RuntimeError("%s timestamp is invalid" % label) from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    raise RuntimeError("%s timestamp is invalid" % label)


def _external_target_snapshot(campaign_dir, lane, evidence, contract):
    from .comparable_benchmark import TARGET_SNAPSHOT_SCHEMA

    target = evidence.get("target_snapshot")
    path = _external_evidence_artifact(
        campaign_dir, lane, target, "target snapshot"
    )
    source_url = str((target or {}).get("source_url") or "")
    if source_url != contract["target_source_url"]:
        raise RuntimeError("target snapshot source URL does not match the contract")
    captured_at = _external_timestamp(
        (target or {}).get("captured_at"), "target snapshot capture"
    )
    expires_at = _external_timestamp(
        (target or {}).get("expires_at"), "target snapshot expiry"
    )
    now = time.time()
    if captured_at > now + 300:
        raise RuntimeError("target snapshot capture time is in the future")
    if now - captured_at > EXTERNAL_TARGET_MAX_AGE_SECONDS or expires_at <= now:
        raise RuntimeError("target snapshot is stale or expired")
    if expires_at - captured_at > EXTERNAL_TARGET_MAX_AGE_SECONDS:
        raise RuntimeError("target snapshot expiry exceeds the contract maximum")
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError("target snapshot is not JSON") from exc
    expected = {
        "schema": TARGET_SNAPSHOT_SCHEMA,
        "lane": lane,
        "source_url": source_url,
        "captured_at": (target or {}).get("captured_at"),
        "leader_value": contract["leader_value"],
        "leader_value_kind": contract["leader_value_kind"],
    }
    if any(snapshot.get(key) != value for key, value in expected.items()):
        raise RuntimeError("target snapshot content does not match its contract")
    raw = snapshot.get("raw_snapshot")
    raw_path = _external_evidence_artifact(
        campaign_dir, lane, raw, "raw target snapshot"
    )
    if (
        raw_path == path
        or raw_path.stat().st_size != (raw or {}).get("bytes")
        or (raw or {}).get("http_status") != 200
    ):
        raise RuntimeError("raw target snapshot metadata is invalid")
    final_url = urlparse(str(snapshot.get("final_url") or ""))
    allowed_hosts = set(contract["submission_hosts"])
    allowed_hosts.add(urlparse(contract["target_source_url"]).hostname)
    if final_url.scheme != "https" or final_url.hostname not in allowed_hosts:
        raise RuntimeError("raw target snapshot final URL is not approved")
    return path, raw_path


def _external_lane_evidence(campaign_dir, campaign, lane, contract):
    lane_dir = Path(campaign_dir) / "external-evidence" / lane
    evidence_path = lane_dir / "evidence.json"
    base = {
        "lane": lane,
        "protocol": contract["protocol"],
        "organizer": contract["organizer"],
        "requires_stock_or_standardized_runner": bool(
            contract["requires_stock_or_standardized_runner"]
        ),
        "evidence_path": str(evidence_path.resolve()),
        "state": "missing",
        "numeric_target_met": False,
        "run_receipt_verified": False,
        "submission_receipt_verified": False,
        "verified": False,
        "reason": "external evidence file is missing",
    }
    if evidence_path.is_symlink() or not evidence_path.is_file():
        return base
    try:
        if evidence_path.stat().st_size > 1024 * 1024:
            raise RuntimeError("external evidence file exceeds 1 MiB")
        evidence = strict_json_loads(evidence_path.read_text(encoding="utf-8"))
        if evidence.get("schema") != EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA:
            raise RuntimeError("external evidence schema is unsupported")
        if evidence.get("lane") != lane:
            raise RuntimeError("external evidence lane does not match its path")
        if evidence.get("protocol") != contract["protocol"]:
            raise RuntimeError("external evidence protocol does not match")
        if (evidence.get("operator_source") or {}).get(
            "tree_sha256"
        ) != campaign["operator_source"]["tree_sha256"]:
            raise RuntimeError("external evidence source does not match the campaign")
        numeric_target_met = _external_score_meets_contract(
            evidence.get("score"), contract
        )
        run_receipt = _external_evidence_artifact(
            campaign_dir, lane, evidence.get("run_receipt"), "run receipt"
        )
        from .comparable_benchmark import validate_comparable_run_receipt

        comparable_run = validate_comparable_run_receipt(
            run_receipt, lane, campaign
        )
        if _canonical_sha256(comparable_run.get("score")) != _canonical_sha256(
            evidence.get("score")
        ):
            raise RuntimeError("external score does not match its run receipt")
        target_snapshot, raw_target_snapshot = _external_target_snapshot(
            campaign_dir, lane, evidence, contract
        )
        submission = evidence.get("submission_receipt")
        submission_artifact = _external_evidence_artifact(
            campaign_dir, lane, submission, "submission receipt"
        )
        if len(
            {
                run_receipt,
                submission_artifact,
                target_snapshot,
                raw_target_snapshot,
            }
        ) != 4:
            raise RuntimeError(
                "run, target, and submission receipts must be separate artifacts"
            )
        parsed_url = urlparse(str(submission.get("url") or ""))
        verified_at = submission.get("verified_at")
        if (
            submission.get("organizer") != contract["organizer"]
            or submission.get("status") not in ("accepted", "published")
            or submission.get("independently_verified") is not True
            or not str(submission.get("receipt_id") or "").strip()
            or parsed_url.scheme != "https"
            or not parsed_url.netloc
            or parsed_url.hostname not in set(contract["submission_hosts"])
            or (
                not isinstance(verified_at, (str, int, float))
                or isinstance(verified_at, bool)
                or not str(verified_at).strip()
            )
        ):
            raise RuntimeError(
                "submission receipt lacks accepted organizer verification"
            )
        if not numeric_target_met:
            raise RuntimeError("external result does not clear its numeric target")
        raise RuntimeError(
            "organizer certification is ineligible: %s"
            % EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER
        )
    except (OSError, TypeError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        base.update({"state": "invalid", "reason": str(exc)})
        return base
    base.update(
        {
            "state": "verified",
            "numeric_target_met": True,
            "run_receipt_verified": True,
            "submission_receipt_verified": True,
            "verified": True,
            "reason": None,
        }
    )
    return base


def _external_number_one_status(
    campaign_dir, campaign, internal_release_certified
):
    expected_contract = external_number_one_contract()
    embedded_contract = (campaign.get("certification_contracts") or {}).get(
        "external_number_one"
    )
    contract_embedded = embedded_contract == expected_contract
    lanes = [
        _external_lane_evidence(campaign_dir, campaign, lane, contract)
        for lane, contract in EXTERNAL_NUMBER_ONE_LANES.items()
    ]
    missing = []
    if not internal_release_certified:
        missing.append("internal_release_not_certified")
    if not contract_embedded:
        missing.append("external_number_one_contract_missing_or_changed")
    for lane in lanes:
        if not lane["verified"]:
            missing.append("external_evidence:%s:%s" % (lane["lane"], lane["state"]))
    all_external_evidence_verified = bool(lanes) and all(
        lane["verified"] for lane in lanes
    )
    number_one = bool(
        internal_release_certified
        and contract_embedded
        and all_external_evidence_verified
    )
    arc_tie_only = any(
        lane.get("verified")
        and EXTERNAL_NUMBER_ONE_LANES[lane["lane"]].get("claim_policy")
        == "tie_for_number_one_only"
        for lane in lanes
    )
    return {
        "scope": "external_comparable_number_one",
        "state": (
            "verified_tie_for_number_one"
            if number_one and arc_tie_only
            else "verified_strict_number_one"
            if number_one
            else "evidence_incomplete"
        ),
        "number_one": number_one,
        "tie_for_number_one": bool(number_one and arc_tie_only),
        "strict_number_one": bool(number_one and not arc_tie_only),
        "sole_number_one": False,
        "claim_label": (
            "verified_tie_for_number_one"
            if number_one and arc_tie_only
            else "verified_strict_number_one" if number_one else None
        ),
        "contract_embedded": contract_embedded,
        "requires_internal_release_certification": True,
        "internal_release_certified": bool(internal_release_certified),
        "all_external_evidence_verified": all_external_evidence_verified,
        "verified_lanes": sum(lane["verified"] for lane in lanes),
        "required_lanes": len(lanes),
        "stock_aider_evidence_verified": next(
            lane["verified"]
            for lane in lanes
            if lane["lane"] == "aider-polyglot-stock"
        ),
        "standardized_arc_evidence_verified": next(
            lane["verified"]
            for lane in lanes
            if lane["lane"] == "arc-agi-3-standardized"
        ),
        "missing_requirements": missing,
        "lanes": lanes,
    }


def _official_quality_evidence_artifact(campaign_dir, lane, entry):
    if not isinstance(entry, dict) or set(entry) != OFFICIAL_QUALITY_ARTIFACT_KEYS:
        raise RuntimeError("official organizer receipt artifact is missing")
    relative = Path(str(entry.get("path") or ""))
    if not relative.parts or relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("official organizer receipt path is unsafe")
    expected_root = (
        Path(campaign_dir) / "official-quality-evidence" / lane
    ).resolve()
    path = Path(campaign_dir) / relative
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("official organizer receipt artifact is missing or symbolic")
    resolved = path.resolve()
    if resolved.parent != expected_root:
        raise RuntimeError("official organizer receipt must be in its lane directory")
    expected_hash = entry.get("sha256")
    if (
        not isinstance(expected_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)
        or _sha256_file(resolved) != expected_hash
    ):
        raise RuntimeError("official organizer receipt artifact hash mismatch")
    return resolved


def _official_quality_direct_score(score):
    if not isinstance(score, dict):
        raise RuntimeError("official quality score is missing")
    if any(key in score for key in ("passed", "total", "numerator", "denominator")):
        raise RuntimeError("local pass counts cannot be converted into official scores")
    if set(score) != OFFICIAL_QUALITY_SCORE_KEYS:
        raise RuntimeError("official quality score does not match the closed schema")
    value = score.get("value")
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or not 0 <= float(value) <= OFFICIAL_QUALITY_SCORE_SCALE
        or score.get("scale") != OFFICIAL_QUALITY_SCORE_SCALE
        or score.get("origin") != "organizer_reported"
        or score.get("locally_derived") is not False
    ):
        raise RuntimeError("official quality score is not a direct 0-100 score")
    return float(value)


def _validate_official_quality_terminal_bench_4_source(
    suite, manifest, source_identity
):
    """Bind each Terminal-Bench 4 source representation to its own pin."""
    dataset_source = suite.get("dataset_source") or {}
    repository = source_identity.get("repository")
    repository_tag = source_identity.get("repository_tag")
    repository_revision = source_identity.get("repository_revision")
    registry_path = source_identity.get("registry_path")
    tagged_repository = "%s@%s" % (repository, repository_tag)

    if manifest.get("requested") != source_identity.get("dataset"):
        raise RuntimeError("campaign dataset does not match official quality source")
    if manifest.get("manifest_sha256") != source_identity.get(
        "harbor_manifest_sha256"
    ):
        raise RuntimeError(
            "campaign resolved Harbor manifest does not match official quality pin"
        )
    resolved_manifest = {
        key: manifest[key]
        for key in (
            "requested",
            "name",
            "version",
            "repo",
            "registry_path",
            "resolution_mode",
            "repository_commit",
            "tasks",
        )
        if key in manifest
    }
    if _canonical_sha256(resolved_manifest) != manifest.get("manifest_sha256"):
        raise RuntimeError(
            "campaign resolved Harbor manifest content does not match its hash"
        )
    if dataset_source.get("dataset_file_sha256") != source_identity.get(
        "dataset_file_sha256"
    ):
        raise RuntimeError(
            "campaign dataset file hash does not match official quality pin"
        )
    if dataset_source.get("task_manifest_sha256") != source_identity.get(
        "task_manifest_sha256"
    ):
        raise RuntimeError(
            "campaign comparable task manifest does not match official quality pin"
        )
    if (
        dataset_source.get("repository") != repository
        or dataset_source.get("repo") != tagged_repository
        or dataset_source.get("repository_tag") != repository_tag
        or dataset_source.get("repository_commit") != repository_revision
        or dataset_source.get("registry_path") != registry_path
        or manifest.get("repo") != tagged_repository
        or manifest.get("repository_commit") != repository_revision
        or manifest.get("registry_path") != registry_path
    ):
        raise RuntimeError(
            "campaign Terminal-Bench repository identity does not match official quality pin"
        )

    official_tasks = source_identity.get("official_tasks")
    official_attempts = source_identity.get("official_attempts")
    official_trials = source_identity.get("official_trials")
    tasks = manifest.get("tasks")
    if (
        suite.get("official_tasks") != official_tasks
        or suite.get("official_attempts") != official_attempts
        or suite.get("official_trials") != official_trials
        or official_trials != official_tasks * official_attempts
        or not isinstance(tasks, list)
        or len(tasks) != official_tasks
    ):
        raise RuntimeError(
            "campaign Terminal-Bench task, attempt, or trial scope does not match"
        )
    names = []
    for task in tasks:
        if not isinstance(task, dict) or set(task) != {"name", "identity"}:
            raise RuntimeError("campaign Terminal-Bench task identity is malformed")
        name = task.get("name")
        identity = task.get("identity")
        if (
            not isinstance(name, str)
            or not name
            or not isinstance(identity, dict)
            or set(identity) != {"git_url", "git_commit_id", "path"}
            or identity.get("git_url") != repository
            or identity.get("git_commit_id") != repository_revision
            or identity.get("path") != "tasks/%s" % name
        ):
            raise RuntimeError("campaign Terminal-Bench task identity is malformed")
        names.append(name)
    if names != sorted(names) or len(names) != len(set(names)):
        raise RuntimeError("campaign Terminal-Bench task identities are not canonical")


def _official_quality_lane_evidence(campaign_dir, campaign, lane, contract):
    lane_dir = Path(campaign_dir) / "official-quality-evidence" / lane
    evidence_path = lane_dir / "evidence.json"
    verification = contract["organizer_verification"]
    provenance_ready = bool(
        contract.get("provenance_ready") is True
        and not contract.get("provenance_blockers")
    )
    base = {
        "lane": lane,
        "display_name": contract["display_name"],
        "protocol": contract["protocol"],
        "organizer": contract["organizer"],
        "score": None,
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "status": "missing",
        "state": "missing",
        "organizer_verified": False,
        "verified": False,
        "score_meets_minimum": False,
        "provenance_ready": provenance_ready,
        "provenance_blockers": list(contract.get("provenance_blockers") or []),
        "trust_configured": bool(
            verification.get("trust_root_id")
            and re.fullmatch(
                r"[0-9a-f]{64}",
                str(verification.get("trust_root_sha256") or ""),
            )
        ),
        "evidence_path": str(evidence_path.resolve()),
        "reason": (
            "organizer-verified official score evidence is missing"
            if provenance_ready
            else "official benchmark provenance is incomplete: %s"
            % "; ".join(
                contract.get("provenance_blockers")
                or ["contract is not marked provenance-ready"]
            )
        ),
    }
    if not provenance_ready:
        base.update({"status": "provenance_blocked", "state": "provenance_blocked"})
        return base
    if evidence_path.is_symlink() or not evidence_path.is_file():
        return base
    try:
        if evidence_path.stat().st_size > 1024 * 1024:
            raise RuntimeError("official-quality evidence file exceeds 1 MiB")
        evidence = strict_json_loads(evidence_path.read_text(encoding="utf-8"))
        if not isinstance(evidence, dict):
            raise RuntimeError("official-quality evidence must be an object")
        if set(evidence) != OFFICIAL_QUALITY_EVIDENCE_KEYS:
            raise RuntimeError("official-quality evidence does not match closed schema")
        if evidence.get("schema") != OFFICIAL_QUALITY_EVIDENCE_SCHEMA:
            raise RuntimeError("official-quality evidence schema is unsupported")
        if evidence.get("lane") != lane:
            raise RuntimeError("official-quality evidence lane does not match its path")
        if evidence.get("protocol") != contract["protocol"]:
            raise RuntimeError("official-quality evidence protocol does not match")
        expected_campaign = {
            "id": campaign.get("id"),
            "created_at": campaign.get("created_at"),
        }
        if evidence.get("campaign") != expected_campaign:
            raise RuntimeError("official-quality evidence campaign binding does not match")
        if evidence.get("operator_source") != campaign.get("operator_source"):
            raise RuntimeError("official-quality evidence source does not match campaign")
        if evidence.get("identity") != campaign.get("identity"):
            raise RuntimeError("official-quality evidence identity does not match campaign")
        if evidence.get("score_scope") != contract.get("score_scope"):
            raise RuntimeError("official-quality evidence is not the exact full-suite scope")
        if any(
            key in evidence
            for key in (
                "independently_verified",
                "organizer_verified",
                "caller_attested",
                "verified",
            )
        ):
            raise RuntimeError(
                "caller verification flags are not official-quality evidence"
            )
        expected_verification = {
            key: verification.get(key)
            for key in (
                "method",
                "signature_algorithm",
                "receipt_schema",
                "trust_root_id",
                "trust_root_sha256",
            )
        }
        if (
            not isinstance(evidence.get("organizer_verification"), dict)
            or set(evidence["organizer_verification"])
            != OFFICIAL_QUALITY_VERIFICATION_KEYS
            or evidence["organizer_verification"] != expected_verification
        ):
            raise RuntimeError("organizer verification metadata does not match contract")
        campaign_suite = contract.get("campaign_suite")
        if campaign_suite:
            suite = (campaign.get("suites") or {}).get(campaign_suite) or {}
            manifest = suite.get("dataset") or {}
            source_identity = contract.get("source_identity") or {}
            if lane == "terminal-bench-4-current":
                _validate_official_quality_terminal_bench_4_source(
                    suite, manifest, source_identity
                )
            else:
                expected_dataset = source_identity.get("dataset")
                if manifest.get("requested") != expected_dataset:
                    raise RuntimeError(
                        "campaign dataset does not match official quality source"
                    )
                expected_manifest = source_identity.get("harbor_manifest_sha256")
                if (
                    expected_manifest is not None
                    and manifest.get("manifest_sha256") != expected_manifest
                ):
                    raise RuntimeError(
                        "campaign manifest does not match official quality pin"
                    )
            execution_config = (contract.get("score_scope") or {}).get(
                "execution_config"
            )
            if execution_config is not None and (
                not isinstance(execution_config, dict)
                or suite.get("reasoning_effort")
                != execution_config.get("reasoning_effort")
                or suite.get("review_passes")
                != execution_config.get("review_passes")
            ):
                raise RuntimeError(
                    "campaign execution config does not match official quality scope"
                )
        score = _official_quality_direct_score(evidence.get("official_score"))
        receipt_path = _official_quality_evidence_artifact(
            campaign_dir, lane, evidence.get("organizer_receipt")
        )
        from .comparable_benchmark import (
            validate_official_quality_organizer_receipt,
        )

        validated = validate_official_quality_organizer_receipt(
            receipt_path, lane, contract, campaign
        )
        if validated.get("organizer_verified") is not True:
            raise RuntimeError("organizer receipt was not independently verified")
        if validated.get("operator_source") != evidence.get("operator_source"):
            raise RuntimeError("organizer receipt source does not match evidence")
        if validated.get("identity") != evidence.get("identity"):
            raise RuntimeError("organizer receipt identity does not match evidence")
        if validated.get("campaign") != evidence.get("campaign"):
            raise RuntimeError("organizer receipt campaign does not match evidence")
        if validated.get("score_scope") != evidence.get("score_scope"):
            raise RuntimeError("organizer receipt score scope does not match evidence")
        if float(validated.get("score")) != score:
            raise RuntimeError("official score does not match organizer receipt")
        meets = score >= float(contract["minimum_score"])
    except (OSError, TypeError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        base.update({"status": "invalid", "state": "invalid", "reason": str(exc)})
        return base
    base.update(
        {
            "score": score,
            "status": "meets_minimum" if meets else "below_minimum",
            "state": "verified" if meets else "verified_below_minimum",
            "organizer_verified": True,
            "verified": True,
            "score_meets_minimum": meets,
            "receipt_id": validated["receipt_id"],
            "verified_at": validated["verified_at"],
            "source_url": validated["source_url"],
            "trust_method": validated["trust_method"],
            "trust_root_id": validated["trust_root_id"],
            "reason": None if meets else "official score is below 91/100",
        }
    )
    return base


def _official_quality_current_source_matches(campaign, current_operator_source):
    expected = campaign.get("operator_source") or {}
    current = current_operator_source or {}
    if not isinstance(expected, dict) or not isinstance(current, dict):
        return False
    return bool(
        re.fullmatch(r"[0-9a-f]{64}", str(expected.get("tree_sha256") or ""))
        and current == expected
    )


def _official_quality_status(
    campaign_dir, campaign, current_operator_source=None
):
    expected_contract = official_quality_contract()
    embedded_contract = (campaign.get("certification_contracts") or {}).get(
        "official_quality"
    )
    contract_embedded = embedded_contract == expected_contract
    lanes = [
        _official_quality_lane_evidence(campaign_dir, campaign, lane, contract)
        for lane, contract in OFFICIAL_QUALITY_LANES.items()
    ]
    verified = sum(item.get("organizer_verified") is True for item in lanes)
    qualified = sum(item.get("score_meets_minimum") is True for item in lanes)
    provenance_ready = sum(item.get("provenance_ready") is True for item in lanes)
    current_source_checked = isinstance(current_operator_source, dict)
    current_source_match = _official_quality_current_source_matches(
        campaign, current_operator_source
    )
    missing = []
    if not contract_embedded:
        missing.append("official_quality_contract_missing_or_changed")
    for item in lanes:
        if item.get("provenance_ready") is not True:
            missing.append("provenance:%s:incomplete" % item["lane"])
        elif item.get("organizer_verified") is not True:
            missing.append(
                "organizer_verification:%s:%s"
                % (item["lane"], item.get("state") or "invalid")
            )
        elif item.get("score_meets_minimum") is not True:
            missing.append("score_below_minimum:%s" % item["lane"])
    if not current_source_checked:
        missing.append("current_operator_source_identity_unverified")
    elif not current_source_match:
        missing.append("current_operator_source_mismatch")
    required = len(OFFICIAL_QUALITY_LANES)
    evidence_good = bool(
        contract_embedded
        and required == 5
        and provenance_ready == required
        and verified == required
        and qualified == required
        and all(
            item.get("score") is not None
            and float(item["score"]) >= OFFICIAL_QUALITY_MINIMUM_SCORE
            for item in lanes
        )
    )
    good = bool(evidence_good and current_source_match)
    return {
        "schema": OFFICIAL_QUALITY_STATUS_SCHEMA,
        "scope": "organizer_verified_official_quality",
        "state": (
            "good"
            if good
            else "legacy_uncontracted"
            if not contract_embedded
            else "current_source_unverified"
            if evidence_good and not current_source_checked
            else "current_source_mismatch"
            if evidence_good and not current_source_match
            else "provenance_blocked"
            if provenance_ready < required
            else "below_minimum"
            if verified == required and qualified < required
            else "evidence_incomplete"
        ),
        "good": good,
        "evidence_good": evidence_good,
        "historical_evidence_good": evidence_good,
        "contract_embedded": contract_embedded,
        "legacy_non_certifying": not contract_embedded,
        "required": required,
        "verified": verified,
        "min": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "required_lanes": required,
        "verified_lanes": verified,
        "qualified_lanes": qualified,
        "provenance_ready_lanes": provenance_ready,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "averaging_allowed": False,
        "average_score": None,
        "all_individual_scores_meet_minimum": qualified == required,
        "current_source_checked": current_source_checked,
        "current_source_match": current_source_match,
        "current_operator_source": current_operator_source,
        "independent_from_number_one": True,
        "missing_requirements": missing,
        "lanes": lanes,
    }


def _task_map(campaign, suite):
    tasks = campaign["suites"][suite]["dataset"]["tasks"]
    return {item["name"]: item for item in tasks}


def _is_exact_sol_receipt(receipt):
    identity = receipt.get("identity") or {}
    return (
        identity.get("provider") == "codex"
        and identity.get("profile") == SOL_BENCHMARK_PROFILE
        and identity.get("requested_model") == SOL_MODEL
        and identity.get("resolved_model") == SOL_MODEL
        and identity.get("exact_sol") is True
    )


def _validate_trial_lock(run_dir, receipt, trial, expected):
    result_relative = Path(trial["path"])
    _verified_artifact(run_dir, receipt, str(result_relative))
    lock_relative = result_relative.parent / "lock.json"
    lock_path = _verified_artifact(run_dir, receipt, str(lock_relative))
    task = (_load_json(lock_path).get("task") or {})
    identity = expected.get("identity") or {}
    # Harbor's lock.json wraps the TaskId fields with documented execution
    # metadata. Compare the complete pinned TaskId byte-for-byte after removing
    # only that envelope; unknown lock fields are not silently discarded.
    envelope_keys = {"name", "type", "digest", "source"}
    unknown = set(task) - set(identity) - envelope_keys
    if unknown:
        raise RuntimeError(
            "trial task identity contains undocumented lock fields for %s: %s"
            % (trial.get("task_name"), sorted(unknown))
        )
    normalized_task_identity = {key: task.get(key) for key in identity}
    if _canonical_sha256(normalized_task_identity) != _canonical_sha256(identity):
        raise RuntimeError(
            "trial task identity mismatch for %s"
            % trial.get("task_name")
        )
    if task.get("name") is not None and task.get("name") != expected.get("name"):
        raise RuntimeError(
            "trial task lock name mismatch for %s" % trial.get("task_name")
        )
    if "git_url" in identity and task.get("type") not in (None, "git"):
        raise RuntimeError(
            "trial task lock type mismatch for %s" % trial.get("task_name")
        )
    return task


def _validate_terminal_receipt_atif(run_dir, receipt, trial, scope):
    result_relative = Path(str(trial.get("path") or ""))
    atif_relative = result_relative.parent / "agent" / "trajectory.json"
    atif_path = _verified_artifact(run_dir, receipt, str(atif_relative))
    declared = Path(str(trial.get("atif_trajectory") or ""))
    if not declared.is_absolute():
        declared = Path(run_dir) / declared
    if declared.resolve() != atif_path:
        raise RuntimeError("receipt ATIF path does not match its trial")
    validate_atif_trajectory(
        atif_path,
        expected_operator_version=scope.get("operator_version"),
        expected_codex_version=scope.get("codex_version"),
        expected_model=SOL_MODEL,
    )
    return str(atif_path)


def _official_attempts(campaign, suite):
    if not _is_v2_campaign(campaign):
        return 1
    return int(campaign["suites"][suite].get("official_attempts") or 1)


def _terminal_trial_keys(campaign, events, suite):
    """Return the first clean result for every campaign trial slot."""
    task_map = _task_map(campaign, suite)
    names = set(task_map)
    attempts = _official_attempts(campaign, suite)
    terminal = {}
    for event in events:
        if event.get("type") != "harbor_receipt" or event.get("suite") != suite:
            continue
        for trial in event.get("trials") or []:
            name = trial.get("task_name")
            if name not in names:
                continue
            try:
                slot = int(trial.get("trial_slot") or 1)
            except (TypeError, ValueError):
                continue
            if not 1 <= slot <= attempts:
                continue
            if _is_v2_campaign(campaign) and trial.get(
                "pinned_task_identity_sha256"
            ) != _canonical_sha256(task_map[name].get("identity") or {}):
                continue
            key = (name, slot)
            if key in terminal or trial.get("status") not in ("passed", "failed"):
                continue
            terminal[key] = trial
    return terminal


def _next_open_slot(campaign, events, suite, task_name):
    terminal = _terminal_trial_keys(campaign, events, suite)
    for slot in range(1, _official_attempts(campaign, suite) + 1):
        if (task_name, slot) not in terminal:
            return slot
    return None


def ingest_receipt(campaign_dir, receipt_path, trial_slots=None):
    campaign_dir = Path(campaign_dir)
    campaign = load_campaign(campaign_dir)
    receipt_path = Path(receipt_path).expanduser().resolve()
    receipt_hash = _sha256_file(receipt_path)
    receipt = _load_json(receipt_path)
    suite = receipt.get("suite")
    if suite not in _campaign_harbor_suites(campaign):
        raise RuntimeError("campaign ingestion accepts Harbor suite receipts only")
    if not _is_exact_sol_receipt(receipt):
        raise RuntimeError("receipt is not exact-Sol evidence")
    source_hash = (receipt.get("operator_source") or {}).get("tree_sha256")
    if source_hash != campaign["operator_source"]["tree_sha256"]:
        raise RuntimeError("receipt Operator source does not match the campaign")
    scope = receipt.get("scope") or {}
    if scope.get("termination_confirmed") is False:
        raise RuntimeError("receipt process termination was not confirmed")
    expected_suite = campaign["suites"][suite]
    if scope.get("dataset") != expected_suite["dataset"]["requested"]:
        raise RuntimeError("receipt dataset does not match the pinned campaign")
    if _is_v2_campaign(campaign):
        for key in (
            "registry_repo",
            "registry_path",
            "repository_tag",
            "repository_commit",
        ):
            expected_value = (expected_suite.get("dataset_source") or {}).get(key)
            if expected_value is not None and scope.get(key) != expected_value:
                raise RuntimeError(
                    "receipt %s does not match the pinned campaign" % key
                )
    if int(scope.get("review_passes", -1)) != int(expected_suite["review_passes"]):
        raise RuntimeError("receipt review-pass policy does not match the campaign")
    if scope.get("reasoning_effort") != expected_suite["reasoning_effort"]:
        raise RuntimeError("receipt reasoning effort does not match the campaign")
    if _is_v2_campaign(campaign) and int(scope.get("n_attempts", -1)) != 1:
        raise RuntimeError("campaign shards require exactly one Harbor attempt")

    slot_targets = {}
    for target in trial_slots or []:
        if isinstance(target, dict):
            name = target.get("task_name")
            slot = target.get("trial_slot")
        else:
            name, slot = target
        if name in slot_targets:
            raise RuntimeError("campaign shard contains duplicate task slot targets")
        slot_targets[name] = int(slot)

    run_dir = receipt_path.parent
    expected_tasks = _task_map(campaign, suite)
    prepared_trials = []
    receipt_names = set()
    for trial in (receipt.get("result") or {}).get("trials") or []:
        name = trial.get("task_name")
        if name not in expected_tasks:
            raise RuntimeError("receipt contains a task outside the pinned manifest")
        if name in receipt_names:
            raise RuntimeError("campaign receipt contains duplicate task trials")
        receipt_names.add(name)
        receipt_task_identity = _validate_trial_lock(
            run_dir, receipt, trial, expected_tasks[name]
        )
        exception = trial.get("exception")
        atif_valid = trial.get("atif_valid")
        atif_trajectory = trial.get("atif_trajectory")
        if (
            _is_v2_campaign(campaign)
            and suite in TERMINAL_BENCH_SUITES
            and exception is None
            and atif_valid is True
        ):
            try:
                atif_trajectory = _validate_terminal_receipt_atif(
                    run_dir, receipt, trial, scope
                )
            except RuntimeError as exc:
                atif_valid = False
                exception = {
                    "exception_type": "InvalidATIFTrajectory",
                    "message": str(exc),
                }
        if (
            _is_v2_campaign(campaign)
            and suite in TERMINAL_BENCH_SUITES
            and exception is None
            and atif_valid is not True
        ):
            exception = {
                "exception_type": "InvalidATIFTrajectory",
                "message": (
                    "Terminal-Bench campaign trials require a valid ATIF trajectory"
                ),
            }
        prepared_trials.append(
            {
                "task_name": name,
                "status": (
                    "incomplete"
                    if exception
                    else "passed" if trial.get("passed") else "failed"
                ),
                "exception": exception,
                "trial_path": trial.get("path"),
                "trial_name": trial.get("trial_name"),
                "atif_valid": atif_valid,
                "atif_trajectory": atif_trajectory,
                "pinned_task_identity": expected_tasks[name].get("identity") or {},
                "pinned_task_identity_sha256": _canonical_sha256(
                    expected_tasks[name].get("identity") or {}
                ),
                "receipt_task_identity": receipt_task_identity,
            }
        )
    if not prepared_trials:
        raise RuntimeError("receipt contains no campaign trials")
    if trial_slots is not None and receipt_names != set(slot_targets):
        raise RuntimeError(
            "receipt task names do not exactly match the assigned trial slots"
        )
    with _campaign_lock(campaign_dir):
        events = _events(campaign_dir)
        if any(item.get("receipt_sha256") == receipt_hash for item in events):
            return {"duplicate": True, "receipt": str(receipt_path)}
        terminal = _terminal_trial_keys(campaign, events, suite)
        trials = []
        for trial in prepared_trials:
            name = trial["task_name"]
            slot = slot_targets.get(name)
            if slot is None:
                slot = _next_open_slot(campaign, events, suite, name)
            attempts = _official_attempts(campaign, suite)
            if slot is None:
                # Preserve later evidence, but never let it replace a first clean slot.
                slot = attempts
                trial["ignored_after_first_clean"] = True
            if not 1 <= int(slot) <= attempts:
                raise RuntimeError(
                    "%s trial slot %s is outside 1..%d" % (suite, slot, attempts)
                )
            trial["trial_slot"] = int(slot)
            if (name, int(slot)) in terminal:
                trial["ignored_after_first_clean"] = True
            elif trial["status"] in ("passed", "failed"):
                terminal[(name, int(slot))] = trial
            trials.append(trial)
        event = {
            "type": "harbor_receipt",
            "suite": suite,
            "receipt": str(receipt_path),
            "receipt_sha256": receipt_hash,
            "trials": trials,
        }
        _append_event(campaign_dir, event)
    return {
        "duplicate": False,
        "suite": suite,
        "trials": len(trials),
        "trial_slots": [
            {"task_name": trial["task_name"], "trial_slot": trial["trial_slot"]}
            for trial in trials
        ],
    }


def _harbor_suite_status(campaign, events, suite):
    suite_config = campaign["suites"][suite]
    names = [item["name"] for item in suite_config["dataset"]["tasks"]]
    attempts = _official_attempts(campaign, suite)
    terminal = _terminal_trial_keys(campaign, events, suite)
    incomplete_attempts = 0
    exception_types = {}
    for event in events:
        if event.get("type") != "harbor_receipt" or event.get("suite") != suite:
            continue
        for trial in event.get("trials") or []:
            name = trial.get("task_name")
            if name not in names:
                continue
            if trial.get("ignored_after_first_clean"):
                continue
            status = trial.get("status")
            if status in ("passed", "failed"):
                continue
            incomplete_attempts += 1
            exception_type = (trial.get("exception") or {}).get("exception_type")
            if exception_type:
                exception_types[exception_type] = exception_types.get(exception_type, 0) + 1
    passed = sum(1 for trial in terminal.values() if trial.get("status") == "passed")
    failed = sum(1 for trial in terminal.values() if trial.get("status") == "failed")
    total_tasks = len(names)
    total_trials = total_tasks * attempts
    completed_trials = len(terminal)
    complete = completed_trials == total_trials
    score = round(passed / total_trials, 6) if complete else None
    required = int(suite_config["required_passes"])
    maximum_failures = total_trials - required
    fully_completed_tasks = sum(
        all((name, slot) in terminal for slot in range(1, attempts + 1))
        for name in names
    )
    touched_tasks = len({name for name, _slot in terminal})
    passed_task_count = sum(
        all(
            terminal.get((name, slot), {}).get("status") == "passed"
            for slot in range(1, attempts + 1)
        )
        for name in names
    )
    failed_task_count = len(
        {
            name
            for (name, _slot), trial in terminal.items()
            if trial.get("status") == "failed"
        }
    )
    atif_valid_trials = sum(
        trial.get("atif_valid") is True for trial in terminal.values()
    )
    atif_complete = (
        suite not in TERMINAL_BENCH_SUITES
        or atif_valid_trials == total_trials
    )
    if failed > maximum_failures:
        state = "failed_requires_new_source"
    elif complete and passed >= required and atif_complete:
        state = "passed"
    elif complete:
        state = "failed_requires_new_source"
    else:
        state = "in_progress"
    v2 = _is_v2_campaign(campaign)
    gate = dict(suite_config.get("number_one_gate") or NUMBER_ONE_GATES[suite])
    comparison_eligible = bool(v2 and gate.get("comparable"))
    comparison_numeric_target_met = (
        bool(complete and atif_complete and passed >= int(gate["target_passes"]))
        if comparison_eligible
        else None
    )
    local_target_met = bool(
        complete
        and atif_complete
        and passed >= int(gate["target_passes"])
    )
    return {
        "suite": suite,
        "state": state,
        "protocol_version": 2 if v2 else 1,
        "official_tasks": total_tasks,
        "official_attempts": attempts,
        "official_trials": total_trials,
        "completed_tasks": fully_completed_tasks,
        "touched_tasks": touched_tasks,
        "pending_tasks": total_tasks - fully_completed_tasks,
        "passed_tasks": passed_task_count,
        "failed_tasks": failed_task_count,
        "completed_trials": completed_trials,
        "pending_trials": total_trials - completed_trials,
        "passed_trials": passed,
        "failed_trials": failed,
        "required_passes": required,
        "threshold_required_passes": int(
            suite_config.get("threshold_required_passes") or required
        ),
        "required_pass_rate": round(required / total_trials, 6),
        "maximum_failures": maximum_failures,
        "incomplete_attempts": incomplete_attempts,
        "incomplete_by_type": exception_types,
        "benchmark_score": score,
        "certification_scope": "internal_release",
        "threshold_met": state == "passed",
        "coverage_fraction": round(completed_trials / total_trials, 6),
        "coverage_percent": round(completed_trials / total_trials * 100, 4),
        "first_clean_result_key": (
            "pinned_task_and_trial_slot" if v2 else "pinned_task"
        ),
        "atif_required": bool(v2 and suite in TERMINAL_BENCH_SUITES),
        "atif_valid_trials": (
            atif_valid_trials if suite in TERMINAL_BENCH_SUITES else None
        ),
        "number_one_gate": gate,
        "stock_leaderboard_comparable": comparison_eligible,
        "comparison_statement": suite_config.get("comparison_statement") or (
            "Legacy v1 campaign evidence is not comparable v2 evidence."
            if not v2
            else None
        ),
        "comparison_numeric_target_met": comparison_numeric_target_met,
        "number_one_target_met": False,
        "number_one": False,
        "external_evidence_required": True,
        "local_target_met": local_target_met,
        "mandatory_current_generation": bool(
            v2
            and (
                suite_config.get("mandatory_current_generation")
                or gate.get("mandatory_current_generation")
            )
        ),
        "pending_trial_slots": [
            {"task_name": name, "trial_slot": slot}
            for slot in range(1, attempts + 1)
            for name in names
            if (name, slot) not in terminal
        ],
        "pending_task_names": [
            name
            for name in names
            if any((name, slot) not in terminal for slot in range(1, attempts + 1))
        ],
    }


def _matching_receipts(benchmark_dir, source_hash, suite):
    matches = []
    root = Path(benchmark_dir) if suite == "harnessbench" else Path(benchmark_dir) / suite
    for path in root.glob("*/receipt.json"):
        try:
            receipt = _load_json(path)
        except (OSError, json.JSONDecodeError, RuntimeError):
            continue
        if receipt.get("suite") != suite:
            continue
        if (receipt.get("operator_source") or {}).get("tree_sha256") != source_hash:
            continue
        if not _is_exact_sol_receipt(receipt):
            continue
        matches.append((float(receipt.get("finished_at") or 0), path, receipt))
    return sorted(matches, key=lambda item: item[0])


def _harness_status(settings, campaign):
    receipts = _matching_receipts(
        settings.benchmark_dir,
        campaign["operator_source"]["tree_sha256"],
        "harnessbench",
    )
    complete_receipt = next(
        (
            item
            for item in receipts
            if int((item[2].get("result") or {}).get("total") or 0) == 3
            and (item[2].get("result") or {}).get("clean") is True
            and item[2].get("status") in ("passed", "failed")
        ),
        None,
    )
    receipt = complete_receipt or (receipts[-1] if receipts else None)
    result = complete_receipt[2].get("result") or {} if complete_receipt else {}
    passed = int(result.get("passed") or 0)
    total = int(result.get("total") or 0)
    accepted = bool(
        complete_receipt
        and complete_receipt[2].get("status") == "passed"
        and passed == total == 3
    )
    return {
        "suite": "harnessbench",
        "state": (
            "passed"
            if accepted
            else "failed_requires_new_source" if complete_receipt else "pending"
        ),
        "completed_tasks": total,
        "passed_tasks": passed,
        "required_passes": 3,
        "benchmark_score": None,
        "certification_scope": "internal_release",
        "number_one": False,
        "threshold_met": accepted,
        "receipt": str(receipt[1]) if receipt else None,
    }


def _arc_status(settings, campaign):
    receipts = _matching_receipts(
        settings.benchmark_dir,
        campaign["operator_source"]["tree_sha256"],
        "arc-agi-3",
    )
    accepted_receipt = None
    diagnostic_receipt = receipts[-1] if receipts else None
    for candidate in receipts:
        receipt = candidate[2]
        scope = receipt.get("scope") or {}
        result = receipt.get("result") or {}
        if (
            receipt.get("status") == "passed"
            and scope.get("run_kind") == "full"
            and scope.get("score_eligible")
            and isinstance(result.get("benchmark_score"), (int, float))
            and int(result.get("completed_games") or 0) == 25
            and (result.get("operator_tasks") or {}).get("clean") is True
        ):
            accepted_receipt = candidate
            break
    candidate = accepted_receipt or diagnostic_receipt
    score = (
        float(accepted_receipt[2]["result"]["benchmark_score"])
        if accepted_receipt
        else None
    )
    accepted = score is not None and score >= campaign["threshold"] * 100
    return {
        "suite": "arc-agi-3",
        "state": (
            "passed"
            if accepted
            else "failed_requires_new_source" if accepted_receipt else "pending"
        ),
        "completed_tasks": (
            int(accepted_receipt[2]["result"].get("completed_games") or 0)
            if accepted_receipt
            else 0
        ),
        "passed_tasks": None,
        "required_passes": None,
        "benchmark_score": score,
        "certification_scope": "internal_release",
        "stock_leaderboard_comparable": False,
        "comparison_statement": (
            "The internal ARC custom-planner score is not the standardized "
            "general-purpose-model protocol."
        ),
        "number_one": False,
        "external_evidence_required": True,
        "threshold_met": accepted,
        "receipt": str(candidate[1]) if candidate else None,
    }


def campaign_status(
    settings, campaign_dir, current_operator_source=None
):
    with _campaign_lock(campaign_dir, shared=True):
        campaign = load_campaign(campaign_dir)
        events = _events(campaign_dir)
    statuses = [_harness_status(settings, campaign)]
    statuses.extend(
        _harbor_suite_status(campaign, events, suite)
        for suite in _campaign_harbor_suites(campaign)
    )
    statuses.append(_arc_status(settings, campaign))
    unconfirmed = {}
    for event in events:
        if event.get("type") == "termination_unconfirmed":
            unconfirmed[event.get("suite")] = event
    for status in statuses:
        event = unconfirmed.get(status["suite"])
        if event is None:
            continue
        status["state"] = "failed_requires_new_source"
        status["threshold_met"] = False
        status["termination_confirmed"] = False
        status["termination_detail"] = event.get("detail")
        status["termination_launcher_run"] = event.get("launcher_run")
    passed = sum(1 for status in statuses if status["threshold_met"])
    failed = [
        status["suite"]
        for status in statuses
        if status["state"] == "failed_requires_new_source"
    ]
    v2 = _is_v2_campaign(campaign)
    required_suites = CAMPAIGN_SUITES if v2 else LEGACY_CAMPAIGN_SUITES
    certification_eligible = bool(
        v2 and campaign.get("certification_eligible", True)
    )
    comparable_lanes = [
        status
        for status in statuses
        if status["suite"] in HARBOR_CAMPAIGN_SUITES
        and status.get("stock_leaderboard_comparable")
    ]
    current_generation_lanes = [
        status
        for status in statuses
        if status.get("mandatory_current_generation")
    ]
    internal_release_certified = bool(
        certification_eligible and passed == len(required_suites)
    )
    external_number_one = _external_number_one_status(
        campaign_dir, campaign, internal_release_certified
    )
    if current_operator_source is None:
        current_root = getattr(settings, "repo_root", None)
        if current_root is not None:
            try:
                current_operator_source = source_identity(current_root)
            except (OSError, RuntimeError, ValueError):
                current_operator_source = None
    official_quality = _official_quality_status(
        campaign_dir,
        campaign,
        current_operator_source=current_operator_source,
    )
    comparable_numeric_targets_met = sum(
        status.get("comparison_numeric_target_met") is True
        for status in comparable_lanes
    )
    return {
        "schema": CAMPAIGN_STATUS_SCHEMA,
        "campaign_schema": campaign.get("schema"),
        "protocol_version": 2 if v2 else 1,
        "campaign": campaign["id"],
        "campaign_path": str(Path(campaign_dir).resolve()),
        "operator_source": campaign["operator_source"],
        "operator_source_path": campaign["operator_source_path"],
        "threshold": campaign["threshold"],
        "passed_suites": passed,
        "required_suites": len(required_suites),
        "certification_eligible": certification_eligible,
        "legacy_non_certifying": not v2,
        "certification_scope": "internal_release",
        "internal_release_certified": internal_release_certified,
        # Backward-compatible alias.  Its scope is explicit above and it must
        # never be interpreted as an external leaderboard certification.
        "certified": internal_release_certified,
        "comparable_numeric_target_lanes": len(comparable_lanes),
        "comparable_numeric_targets_met": comparable_numeric_targets_met,
        "all_comparable_numeric_targets_met": bool(
            comparable_lanes
            and all(
                status.get("comparison_numeric_target_met") is True
                for status in comparable_lanes
            )
        ),
        "comparable_number_one_lanes": external_number_one["required_lanes"],
        "number_one_lanes_met": external_number_one["verified_lanes"],
        "all_comparable_number_one_lanes_met": external_number_one[
            "all_external_evidence_verified"
        ],
        "number_one": external_number_one["number_one"],
        "number_one_missing_requirements": external_number_one[
            "missing_requirements"
        ],
        "external_number_one": external_number_one,
        "official_quality": official_quality,
        "certification": {
            "internal_release": {
                "scope": "internal_release",
                "certified": internal_release_certified,
                "passed_suites": passed,
                "required_suites": len(required_suites),
            },
            "external_number_one": external_number_one,
            "official_quality": official_quality,
        },
        "mandatory_current_generation_lanes": len(current_generation_lanes),
        "current_generation_lanes_met": sum(
            status.get("local_target_met") is True
            for status in current_generation_lanes
        ),
        "all_current_generation_lanes_met": bool(
            current_generation_lanes
            and all(
                status.get("local_target_met") is True
                for status in current_generation_lanes
            )
        ),
        "failed_requires_new_source": failed,
        "suites": statuses,
    }


def next_trial_slots(settings, campaign_dir, suite, batch_size):
    campaign = load_campaign(campaign_dir)
    if suite not in _campaign_harbor_suites(campaign):
        raise ValueError("task shards are available only for Harbor suites")
    batch_size = max(1, int(batch_size))
    status = campaign_status(settings, campaign_dir)
    suite_status = next(item for item in status["suites"] if item["suite"] == suite)
    if suite_status["state"] == "failed_requires_new_source":
        raise RuntimeError(
            "%s already exceeded its %.1f%% failure budget"
            % (suite, status["threshold"] * 100)
        )
    selected = []
    selected_names = set()
    for target in suite_status["pending_trial_slots"]:
        # A Harbor shard receives each selected task once with n_attempts=1.
        # Later official slots are separate Harbor invocations.
        if target["task_name"] in selected_names:
            continue
        selected.append(target)
        selected_names.add(target["task_name"])
        if len(selected) >= batch_size:
            break
    return selected


def next_task_names(settings, campaign_dir, suite, batch_size):
    return [
        target["task_name"]
        for target in next_trial_slots(settings, campaign_dir, suite, batch_size)
    ]


def shard_command(
    settings,
    campaign_dir,
    suite,
    task_names,
    n_concurrent=1,
    timeout=604800,
    trial_slots=None,
):
    campaign = load_campaign(campaign_dir)
    source = Path(campaign["operator_source_path"])
    current_identity = source_identity(source)
    if current_identity["tree_sha256"] != campaign["operator_source"]["tree_sha256"]:
        raise RuntimeError("frozen campaign source identity changed")
    task_names = list(task_names)
    if not task_names:
        return []
    command = [
        str(source / "bin/operator"),
        "benchmark",
        "run",
        suite,
        "--n-tasks",
        str(len(task_names)),
        "--n-concurrent",
        str(max(1, int(n_concurrent))),
        "--max-retries",
        "0",
        "--review-passes",
        str(int(campaign["suites"][suite]["review_passes"])),
        "--effort",
        campaign["suites"][suite]["reasoning_effort"],
        "--timeout",
        str(float(timeout)),
    ]
    if _is_v2_campaign(campaign):
        command.extend(["--n-attempts", "1"])
    if trial_slots is not None:
        expected_names = [target["task_name"] for target in trial_slots]
        if expected_names != task_names:
            raise RuntimeError("campaign shard task names do not match trial slots")
    for task_name in task_names:
        command.extend(["--include-task", task_name])
    return command


def gate_command(settings, campaign_dir, suite, timeout=604800):
    if suite not in ("harnessbench", "arc-agi-3"):
        raise ValueError("gate command requires harnessbench or arc-agi-3")
    campaign = load_campaign(campaign_dir)
    source = Path(campaign["operator_source_path"])
    current_identity = source_identity(source)
    if current_identity["tree_sha256"] != campaign["operator_source"]["tree_sha256"]:
        raise RuntimeError("frozen campaign source identity changed")
    command = [str(source / "bin/operator"), "benchmark", "run", suite]
    if suite == "harnessbench":
        command.extend(
            [
                "--agents",
                "sol",
                "--cases",
                "all",
                "--effort",
                "high",
                "--timeout",
                str(float(timeout)),
            ]
        )
    else:
        command.extend(["--all-games", "--timeout", str(float(timeout))])
    return command


def _receipt_paths(benchmark_dir, suite, source_hash=None):
    root = Path(benchmark_dir) / suite
    paths = set()
    for path in root.glob("*/receipt.json"):
        try:
            receipt = _load_json(path)
        except (OSError, json.JSONDecodeError, RuntimeError):
            continue
        if source_hash is not None and (
            (receipt.get("operator_source") or {}).get("tree_sha256")
            != source_hash
            or not _is_exact_sol_receipt(receipt)
        ):
            continue
        paths.add(path.resolve())
    return paths


def _suite_receipt_paths(benchmark_dir, suite, source_hash=None):
    paths = set()
    root = Path(benchmark_dir) if suite == "harnessbench" else Path(benchmark_dir) / suite
    for path in root.glob("*/receipt.json"):
        try:
            receipt = _load_json(path)
        except (OSError, json.JSONDecodeError, RuntimeError):
            continue
        if receipt.get("suite") != suite:
            continue
        if source_hash is not None and (
            (receipt.get("operator_source") or {}).get("tree_sha256")
            != source_hash
            or not _is_exact_sol_receipt(receipt)
        ):
            continue
        paths.add(path.resolve())
    return paths


def _launch_supervised_process(command, cwd, environment, stdout, stderr):
    environment = dict(environment)
    environment[SUPERVISED_PROCESS_GROUP_ENV] = "1"
    return subprocess.Popen(
        command,
        cwd=str(cwd),
        env=environment,
        stdout=stdout,
        stderr=stderr,
        text=True,
        start_new_session=False,
    )


def run_gate(settings, campaign_dir, suite, timeout=604800):
    command = gate_command(settings, campaign_dir, suite, timeout=timeout)
    campaign = load_campaign(campaign_dir)
    source_hash = campaign["operator_source"]["tree_sha256"]
    before = _suite_receipt_paths(settings.benchmark_dir, suite, source_hash)
    launch_dir = Path(campaign_dir) / "launcher-runs" / (
        time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    )
    launch_dir.mkdir(parents=True)
    _write_json(launch_dir / "command.json", {"argv": command})
    environment = os.environ.copy()
    environment.update(
        {
            "OPERATOR_HOME": str(settings.home),
            "OPERATOR_CODEX_BIN": str(settings.codex_bin),
            "OPERATOR_MODEL": SOL_MODEL,
            "OPERATOR_REPO": str(campaign["operator_source_path"]),
        }
    )
    timed_out = False
    termination = None
    termination_confirmed = True
    with (launch_dir / "stdout.log").open("w", encoding="utf-8") as stdout, (
        launch_dir / "stderr.log"
    ).open("w", encoding="utf-8") as stderr:
        process = _launch_supervised_process(
            command,
            campaign["operator_source_path"],
            environment,
            stdout,
            stderr,
        )
        try:
            process.wait(timeout=float(timeout) + 900)
        except subprocess.TimeoutExpired:
            timed_out = True
            termination_confirmed, termination = CodexRunner.terminate_spawned(
                process
            )
    if timed_out and not termination_confirmed:
        _record_unconfirmed_termination(
            campaign_dir, suite, process, termination, launch_dir
        )
    after = _suite_receipt_paths(settings.benchmark_dir, suite, source_hash)
    created = sorted(after - before, key=lambda path: path.stat().st_mtime)
    status = campaign_status(settings, campaign_dir)
    suite_status = next(item for item in status["suites"] if item["suite"] == suite)
    result = {
        "suite": suite,
        "status": suite_status["state"] if created else "blocked",
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "termination": termination,
        "termination_confirmed": termination_confirmed,
        "termination_detail": termination,
        "receipt": str(created[-1]) if created else None,
        "launcher_run": str(launch_dir),
    }
    _write_json(launch_dir / "result.json", result)
    return result


def run_next_shard(
    settings,
    campaign_dir,
    suite,
    batch_size=8,
    n_concurrent=1,
    timeout=604800,
):
    slots = next_trial_slots(settings, campaign_dir, suite, batch_size)
    names = [target["task_name"] for target in slots]
    if not slots:
        return {
            "suite": suite,
            "status": "complete",
            "tasks": [],
            "trial_slots": [],
        }
    command = shard_command(
        settings,
        campaign_dir,
        suite,
        names,
        n_concurrent=n_concurrent,
        timeout=timeout,
        trial_slots=slots,
    )
    campaign = load_campaign(campaign_dir)
    source_hash = campaign["operator_source"]["tree_sha256"]
    before = _receipt_paths(settings.benchmark_dir, suite, source_hash)
    launch_dir = Path(campaign_dir) / "launcher-runs" / (
        time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    )
    launch_dir.mkdir(parents=True)
    _write_json(
        launch_dir / "command.json",
        {"argv": command, "tasks": names, "trial_slots": slots},
    )
    environment = os.environ.copy()
    environment.update(
        {
            "OPERATOR_HOME": str(settings.home),
            "OPERATOR_CODEX_BIN": str(settings.codex_bin),
            "OPERATOR_MODEL": SOL_MODEL,
            "OPERATOR_REPO": str(campaign["operator_source_path"]),
        }
    )
    timed_out = False
    termination = None
    termination_confirmed = True
    with (launch_dir / "stdout.log").open("w", encoding="utf-8") as stdout, (
        launch_dir / "stderr.log"
    ).open("w", encoding="utf-8") as stderr:
        process = _launch_supervised_process(
            command,
            campaign["operator_source_path"],
            environment,
            stdout,
            stderr,
        )
        try:
            process.wait(timeout=float(timeout) + 900)
        except subprocess.TimeoutExpired:
            timed_out = True
            termination_confirmed, termination = CodexRunner.terminate_spawned(
                process
            )
    if timed_out and not termination_confirmed:
        _record_unconfirmed_termination(
            campaign_dir, suite, process, termination, launch_dir
        )
    after = _receipt_paths(settings.benchmark_dir, suite, source_hash)
    created = sorted(after - before, key=lambda path: path.stat().st_mtime)
    ingested = None
    if created and termination_confirmed:
        ingested = ingest_receipt(campaign_dir, created[-1], trial_slots=slots)
    result = {
        "suite": suite,
        "status": "recorded" if ingested else "blocked",
        "tasks": names,
        "trial_slots": slots,
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "termination": termination,
        "termination_confirmed": termination_confirmed,
        "termination_detail": termination,
        "receipt": str(created[-1]) if created else None,
        "ingested": ingested,
        "launcher_run": str(launch_dir),
    }
    _write_json(launch_dir / "result.json", result)
    return result


def supervisor_step(
    settings,
    campaign_dir,
    batch_size=8,
    n_concurrent=1,
    timeout=604800,
    max_load=None,
):
    status = campaign_status(settings, campaign_dir)
    if status["internal_release_certified"]:
        return {"state": "internal_release_certified", "status": status}
    if status["failed_requires_new_source"]:
        return {"state": "failed_requires_new_source", "status": status}
    if max_load is not None:
        resources = resource_snapshot(max_load)
        if not resources["ready"]:
            return {
                "state": "resource_wait",
                "resources": resources,
                "status": status,
            }
    quota = active_quota_block(settings.benchmark_dir)
    if quota:
        probe = probe_exact_sol(settings)
        if probe["ok"]:
            record_quota_available(settings.benchmark_dir, probe)
        else:
            return {
                "state": "quota_wait",
                "quota": quota,
                "probe": probe,
                "status": status,
            }

    suite = next_supervisor_suite(status, batch_size)
    if suite is None:
        return {"state": "idle", "status": status}
    suite_before = next(item for item in status["suites"] if item["suite"] == suite)
    if suite in HARBOR_CAMPAIGN_SUITES:
        run = run_next_shard(
            settings,
            campaign_dir,
            suite,
            batch_size=supervisor_batch_size(suite, batch_size),
            n_concurrent=supervisor_concurrency(suite, n_concurrent),
            timeout=timeout,
        )
    else:
        run = run_gate(settings, campaign_dir, suite, timeout=timeout)
    after = campaign_status(settings, campaign_dir)
    suite_after = next(item for item in after["suites"] if item["suite"] == suite)
    progressed = (
        suite_after.get("completed_trials", suite_after.get("completed_tasks", 0))
        > suite_before.get("completed_trials", suite_before.get("completed_tasks", 0))
        or suite_after["state"] != suite_before["state"]
    )
    return {
        "state": "ran",
        "suite": suite,
        "progressed": progressed,
        "run": run,
        "status": after,
    }


def supervise_campaign(
    settings,
    campaign_dir,
    batch_size=8,
    n_concurrent=1,
    timeout=604800,
    poll_seconds=900,
    max_load=None,
    once=False,
    event_sink=None,
):
    campaign_dir = Path(campaign_dir).resolve()
    max_load = default_max_load() if max_load is None else float(max_load)
    if max_load <= 0:
        raise ValueError("campaign max load must be positive")
    lock_path = campaign_dir / "supervisor.lock"
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another campaign supervisor already owns %s" % lock_path)
        while True:
            event = supervisor_step(
                settings,
                campaign_dir,
                batch_size=batch_size,
                n_concurrent=n_concurrent,
                timeout=timeout,
                max_load=max_load,
            )
            _append_supervisor_event(campaign_dir, event)
            if event_sink:
                event_sink(event)
            if event["state"] in (
                "internal_release_certified",
                "failed_requires_new_source",
            ):
                return event
            if once:
                return event
            if event["state"] == "quota_wait":
                retry_at = float((event.get("quota") or {}).get("retry_at") or 0)
                delay = max(60.0, retry_at - time.time() + 30.0)
            elif event["state"] == "resource_wait":
                delay = max(60.0, float(poll_seconds))
            elif event["state"] == "ran" and event.get("progressed"):
                delay = 1.0
            else:
                delay = max(60.0, float(poll_seconds))
            time.sleep(delay)


def render_campaign_status(payload):
    lines = [
        "Internal release campaign %s (protocol v%d): %d/%d suites at >= %.1f%%"
        % (
            payload["campaign"],
            payload.get("protocol_version", 1),
            payload["passed_suites"],
            payload["required_suites"],
            payload["threshold"] * 100,
        ),
        "Comparable local numeric targets: %d/%d met"
        % (
            payload.get("comparable_numeric_targets_met", 0),
            payload.get("comparable_numeric_target_lanes", 0),
        ),
        "Mandatory current-generation local lanes: %d/%d met"
        % (
            payload.get("current_generation_lanes_met", 0),
            payload.get("mandatory_current_generation_lanes", 0),
        ),
        "Internal release certified: %s"
        % ("yes" if payload.get("internal_release_certified") else "no"),
        "External verified number one: %s (%d/%d evidence lanes verified)"
        % (
            "yes" if payload.get("number_one") else "no",
            (payload.get("external_number_one") or {}).get("verified_lanes", 0),
            (payload.get("external_number_one") or {}).get("required_lanes", 0),
        ),
        "Official quality good: %s (%d/%d organizer-verified scores; each must be >= %.1f/100)"
        % (
            "yes" if (payload.get("official_quality") or {}).get("good") else "no",
            (payload.get("official_quality") or {}).get("verified_lanes", 0),
            (payload.get("official_quality") or {}).get("required_lanes", 5),
            (payload.get("official_quality") or {}).get(
                "minimum_score", OFFICIAL_QUALITY_MINIMUM_SCORE
            ),
        ),
        "",
        "SUITE             STATE                       RESULT",
    ]
    for item in payload["suites"]:
        if item["suite"] in HARBOR_CAMPAIGN_SUITES:
            result = "%d/%d trial pass; %d pending; need %d (%d tasks x %d)" % (
                item["passed_trials"],
                item["official_trials"],
                item["pending_trials"],
                item["required_passes"],
                item["official_tasks"],
                item["official_attempts"],
            )
            if not item.get("stock_leaderboard_comparable"):
                result += (
                    "; custom-agent submissions not currently accepted; "
                    "non-leaderboard local evidence"
                    if item["suite"] == "terminal-bench-current"
                    else "; non-comparable to stock leaderboard"
                )
        elif item["suite"] == "arc-agi-3":
            result = (
                "%.4f" % item["benchmark_score"]
                if item["benchmark_score"] is not None
                else "no clean full score"
            )
        else:
            result = "%d/3 pass" % item["passed_tasks"]
        lines.append("%-17s %-27s %s" % (item["suite"], item["state"], result))
    if payload.get("legacy_non_certifying"):
        lines.append("")
        lines.append("Legacy v1 evidence is readable but cannot certify protocol v2.")
    if not payload.get("number_one"):
        lines.append("")
        lines.append(
            "Internal release certification is not a leaderboard or number-one claim."
        )
        missing = payload.get("number_one_missing_requirements") or []
        if missing:
            lines.append("External evidence missing: %s" % ", ".join(missing))
    quality = payload.get("official_quality") or {}
    lines.extend(["", "OFFICIAL QUALITY (no averaging)"])
    for item in quality.get("lanes") or []:
        score = "unreported" if item.get("score") is None else "%.4f/100" % item["score"]
        lines.append(
            "%-28s %-24s %s"
            % (item["lane"], item.get("state") or "missing", score)
        )
    if not quality.get("good"):
        missing = quality.get("missing_requirements") or []
        if missing:
            lines.append("Official quality missing: %s" % ", ".join(missing))
    return "\n".join(lines)
