import argparse
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
import re
from dataclasses import replace
from pathlib import Path

from . import __version__
from .benchmark_receipt import source_identity, source_revision
from .daemon import run_daemon
from .profiles import (
    PROFILES,
    require_explicit_verification,
    resolve_execution,
)
from .providers import ProviderRegistry
from .grok_adapter import build as build_grok, find_binary as discover_grok_binary
from . import ide as ide_integration
from .settings import Settings
from .store import Store, TERMINAL_STATES
from .workspace import WorkspaceManager
from . import service
from . import release


def emit(value, as_json=False):
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True, default=str))
    elif isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value, indent=2, sort_keys=True, default=str))


def health(settings, timeout=2):
    try:
        with urllib.request.urlopen(settings.health_url, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            return json.load(exc)
        except (OSError, json.JSONDecodeError):
            return None
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return None


def _active_release(settings):
    try:
        pointer = release.current_path(settings)
    except (AttributeError, TypeError):
        return None
    if not os.path.lexists(str(pointer)):
        return None
    return release.current(settings, required=True)


def daemon_identity_errors(settings, store, status, expected_release=None):
    if not isinstance(status, dict):
        return ["health endpoint did not return an object"]
    if expected_release is None:
        expected_release = _active_release(settings)
    errors = []
    if status.get("ok") is not True:
        errors.append("daemon reports degraded health")
    expected_version = (
        expected_release.version if expected_release is not None else __version__
    )
    if status.get("version") != expected_version:
        errors.append(
            "version=%r expected %r" % (status.get("version"), expected_version)
        )
    if status.get("database_id") != store.instance_id:
        errors.append(
            "database_id=%r expected %r"
            % (status.get("database_id"), store.instance_id)
        )
    expected_source = source_identity(settings.repo_root).get("tree_sha256")
    if status.get("source_tree_sha256") != expected_source:
        errors.append("running source bytes do not match the invoking CLI")
    if expected_release is not None:
        expected = {
            "release_id": expected_release.release_id,
            "release_manifest_sha256": expected_release.manifest_sha256,
            "runtime_sha256": expected_release.runtime_sha256,
        }
        for key, value in expected.items():
            if status.get(key) != value:
                errors.append("%s=%r expected %r" % (key, status.get(key), value))
    return errors


def validate_daemon(settings, store, status, expected_release=None):
    errors = daemon_identity_errors(
        settings, store, status, expected_release=expected_release
    )
    if errors:
        raise RuntimeError("Operator daemon identity mismatch: %s" % "; ".join(errors))
    return status


def wait_for_task(store, task_id, timeout=None, follow=False):
    started = time.monotonic()
    last_seq = 0
    while True:
        task = store.get(task_id)
        if task is None:
            raise RuntimeError("task not found: %s" % task_id)
        if follow:
            for event in store.events(task_id, after=last_seq):
                last_seq = event["seq"]
                event_type = event["event_type"]
                if event_type in (
                    "task.started",
                    "task.queued",
                    "task.succeeded",
                    "task.failed",
                    "task.cancelled",
                    "runner.started",
                ):
                    print("[%s] %s" % (task_id[:8], event_type), file=sys.stderr)
        if task["state"] in TERMINAL_STATES:
            return task
        if timeout is not None and time.monotonic() - started > timeout:
            raise TimeoutError("timed out waiting for task %s" % task_id)
        time.sleep(0.5)


def require_daemon(settings, store):
    status = health(settings)
    if status:
        return validate_daemon(settings, store, status)
    if service.service_path(settings=settings).exists():
        service.start(settings)
        for _ in range(30):
            time.sleep(0.25)
            status = health(settings)
            if status:
                return validate_daemon(settings, store, status)
    raise RuntimeError(
        "Black Label Operator daemon is not running; run `operator install`"
    )


def prompt_value(args):
    if getattr(args, "prompt", None):
        return " ".join(args.prompt).strip()
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    raise RuntimeError("a prompt argument or stdin is required")


def parse_duration(value):
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*", value or "")
    if not match:
        raise ValueError("duration must look like 30s, 15m, 2h, or 1d")
    amount = float(match.group(1))
    multiplier = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[
        match.group(2)
    ]
    return amount * multiplier


def _verification_writable_path(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("verification writable paths must be non-empty strings")
    if len(value) > 240 or "\\" in value:
        raise ValueError(
            "verification writable paths must be canonical relative POSIX paths"
        )
    path = Path(value)
    if path.is_absolute() or not path.parts or value != path.as_posix():
        raise ValueError(
            "verification writable paths must be canonical relative POSIX paths"
        )
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(
            "verification writable paths must stay inside the verifier sandbox"
        )
    return value


def normalize_verification(values):
    values = list(values or [])
    if len(values) > 32:
        raise ValueError("at most 32 verification entries are supported")
    normalized = []
    for item in values:
        if isinstance(item, str):
            if not item.strip() or len(item) > 8000:
                raise ValueError(
                    "verification commands must be 1 to 8000 characters"
                )
            normalized.append(item)
            continue
        if not isinstance(item, dict):
            raise ValueError("verification entries must be strings or objects")
        if set(item) - {"command", "writable_paths"}:
            raise ValueError(
                "verification objects support only command and writable_paths"
            )
        command = item.get("command")
        if (
            not isinstance(command, str)
            or not command.strip()
            or len(command) > 8000
        ):
            raise ValueError(
                "verification object command must be 1 to 8000 characters"
            )
        writable_paths = item.get("writable_paths", [])
        if not isinstance(writable_paths, list):
            raise ValueError("verification writable_paths must be a list")
        if len(writable_paths) > 64:
            raise ValueError("at most 64 verification writable_paths are supported")
        normalized.append(
            {
                "command": command,
                "writable_paths": [
                    _verification_writable_path(value) for value in writable_paths
                ],
            }
        )
    return normalized


def verification_from_args(args):
    values = list(getattr(args, "verify", None) or [])
    for raw in list(getattr(args, "verify_spec", None) or []):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError("--verify-spec must be a JSON object") from exc
        if not isinstance(value, dict):
            raise ValueError("--verify-spec must be a JSON object")
        values.append(value)
    return normalize_verification(values)


def enqueue_from_args(args, settings, store):
    prompt = prompt_value(args)
    if not prompt:
        raise RuntimeError("prompt is empty")
    cwd = Path(args.cwd or os.getcwd()).expanduser().resolve()
    if not cwd.is_dir():
        raise RuntimeError("working directory does not exist: %s" % cwd)
    execution = resolve_execution(
        getattr(args, "profile", None) or settings.profile,
        provider=getattr(args, "provider", None),
        model=getattr(args, "model", None),
        effort=getattr(args, "effort", None),
        sandbox=getattr(args, "sandbox", None),
        isolation=getattr(args, "isolation", None),
        max_attempts=getattr(args, "max_attempts", None),
    )
    verification = verification_from_args(args)
    from .reliability import preflight_verification
    require_explicit_verification(execution, preflight_verification(store, cwd, verification))
    ProviderRegistry(settings).validate(
        {
            "provider": execution["provider"],
            "metadata": {
                "required_capabilities": execution["required_capabilities"]
            },
        }
    )
    return store.enqueue(
        prompt=prompt,
        cwd=cwd,
        model=execution["model"],
        effort=execution["effort"],
        sandbox=execution["sandbox"],
        priority=args.priority,
        max_attempts=execution["max_attempts"],
        source="cli",
        metadata={
            "required_capabilities": execution["required_capabilities"],
            "disable_customizations": execution["disable_customizations"],
        },
        provider=execution["provider"],
        profile=execution["profile"],
        isolation=execution["isolation"],
        verification=verification,
        verification_required=(
            bool(verification) or execution["require_verification"]
        ),
        dependencies=getattr(args, "after", None),
    )


def _require_canonical_upgrade_store(settings, store):
    expected = settings.db_path.expanduser().resolve()
    actual = Path(store.path).expanduser().resolve()
    if actual != expected:
        raise RuntimeError(
            "Operator upgrade store mismatch: %s expected %s" % (actual, expected)
        )


def _rollback_upgrade(settings, service_state, activation_state):
    rollback_errors = []
    service_restored = False
    try:
        service.restore_state(settings, service_state, start=False)
        service_restored = True
    except Exception as rollback_exc:
        rollback_errors.append("service: %s" % rollback_exc)
    try:
        release.restore_activation(settings, activation_state)
    except Exception as rollback_exc:
        rollback_errors.append("activation: %s" % rollback_exc)
    if service_restored:
        try:
            service.resume_state(settings, service_state)
        except Exception as rollback_exc:
            rollback_errors.append("service restart: %s" % rollback_exc)
    return rollback_errors


def command_install(args, settings, store):
    settings = service.preserve_existing_settings(settings)
    _require_canonical_upgrade_store(settings, store)
    with store.upgrade_transaction():
        activation_state = release.capture_activation(settings)
        service_state = service.capture_state(settings)
        # Do not interrupt work that won the race immediately before the
        # barrier. The second check below proves the stopped canonical state.
        store.require_upgrade_idle()
        try:
            service.suspend_state(settings, service_state)
            store.require_upgrade_idle()
            installed = release.install(settings)
            runtime_settings = replace(settings, repo_root=installed.repo_root)
            path = service.install(
                runtime_settings, installed, start=not args.no_start
            )
            result = {
                "installed": True,
                "backend": service.backend_name(),
                "service_file": str(path),
                "release": str(installed.path),
                "release_id": installed.release_id,
                "release_manifest_sha256": installed.manifest_sha256,
                "source_tree_sha256": installed.tree_sha256,
                "runtime_sha256": installed.runtime_sha256,
                "workers": settings.workers,
                "entrypoints": [
                    "operator", "blacklabel-operator", "sol", "operator-mcp"
                ],
            }
            if not args.no_start:
                for _ in range(40):
                    result["health"] = health(settings)
                    if result["health"] and not daemon_identity_errors(
                        runtime_settings,
                        store,
                        result["health"],
                        expected_release=installed,
                    ):
                        break
                    time.sleep(0.25)
                if not result.get("health"):
                    raise RuntimeError(
                        "Operator service started without a healthy daemon"
                    )
                validate_daemon(
                    runtime_settings,
                    store,
                    result["health"],
                    expected_release=installed,
                )
        except Exception as exc:
            rollback_errors = _rollback_upgrade(
                settings, service_state, activation_state
            )
            if rollback_errors:
                raise RuntimeError(
                    "Operator install failed (%s); rollback failed (%s)"
                    % (exc, "; ".join(rollback_errors))
                ) from exc
            raise
    emit(result, args.json)


def command_activate_prebuilt(args, settings, store):
    """Activate the exact notarized release copied from the desktop app."""
    settings = service.preserve_existing_settings(settings)
    _require_canonical_upgrade_store(settings, store)
    with store.upgrade_transaction():
        activation_state = release.capture_activation(settings)
        service_state = service.capture_state(settings)
        # Preserve a task that was admitted immediately before the barrier,
        # then prove the same database remains idle after the old daemon stops.
        store.require_upgrade_idle()
        try:
            service.suspend_state(settings, service_state)
            store.require_upgrade_idle()
            installed = release.activate_prebuilt(settings, args.release_id)
            runtime_settings = replace(settings, repo_root=installed.repo_root)
            path = service.install(runtime_settings, installed, start=True)
            result = {
                "installed": True,
                "prebuilt": True,
                "backend": service.backend_name(),
                "service_file": str(path),
                "release": str(installed.path),
                "release_id": installed.release_id,
                "release_manifest_sha256": installed.manifest_sha256,
                "source_tree_sha256": installed.tree_sha256,
                "runtime_sha256": installed.runtime_sha256,
                "workers": settings.workers,
                "entrypoints": [
                    "operator", "blacklabel-operator", "sol", "operator-mcp"
                ],
            }
            for _ in range(40):
                result["health"] = health(settings)
                if result["health"] and not daemon_identity_errors(
                    runtime_settings,
                    store,
                    result["health"],
                    expected_release=installed,
                ):
                    break
                time.sleep(0.25)
            if not result.get("health"):
                raise RuntimeError(
                    "Operator service started without a healthy daemon"
                )
            validate_daemon(
                runtime_settings,
                store,
                result["health"],
                expected_release=installed,
            )
        except Exception as exc:
            rollback_errors = _rollback_upgrade(
                settings, service_state, activation_state
            )
            if rollback_errors:
                raise RuntimeError(
                    "Operator prebuilt activation failed (%s); rollback failed (%s)"
                    % (exc, "; ".join(rollback_errors))
                ) from exc
            raise
    emit(result, args.json)


def command_uninstall(args, settings):
    service_result = service.uninstall(settings)
    release_result = release.uninstall(settings, purge_state=args.purge_state)
    result = {"uninstalled": True, "service": service_result}
    result.update(release_result)
    emit(result, args.json)
    return 0


def command_run(args, settings, store):
    with store.admission():
        require_daemon(settings, store)
        task_id = enqueue_from_args(args, settings, store)
    task = wait_for_task(store, task_id, timeout=args.timeout, follow=not args.json)
    if args.json:
        emit(task, True)
    else:
        if task.get("final_text"):
            print(task["final_text"])
        print(
            "task=%s state=%s tokens=%d/%d"
            % (
                task_id,
                task["state"],
                task.get("input_tokens", 0),
                task.get("output_tokens", 0),
            ),
            file=sys.stderr,
        )
    return 0 if task["state"] == "succeeded" else 1


def command_submit(args, settings, store):
    with store.admission():
        require_daemon(settings, store)
        task_id = enqueue_from_args(args, settings, store)
    emit({"task_id": task_id, "state": "queued"}, args.json)


def command_wait(args, _settings, store):
    task = wait_for_task(store, args.task_id, timeout=args.timeout, follow=args.follow)
    emit(task, args.json)
    return 0 if task["state"] == "succeeded" else 1


def command_list(args, _settings, store):
    tasks = store.list(limit=args.limit, state=args.state)
    if args.json:
        emit(tasks, True)
        return
    print("STATE       TASK ID                               AGE       CWD")
    now = time.time()
    for task in tasks:
        age = int(now - task["created_at"])
        print("%-11s %-36s %6ss  %s" % (task["state"], task["id"], age, task["cwd"]))


def command_show(args, _settings, store):
    task = store.get(args.task_id)
    if not task:
        raise RuntimeError("task not found: %s" % args.task_id)
    emit(task, args.json)


def command_events(args, _settings, store):
    events = store.events(args.task_id, after=args.after, limit=args.limit)
    if args.json:
        emit(events, True)
        return
    for event in events:
        print("%d %.3f %s %s" % (event["seq"], event["created_at"], event["event_type"], json.dumps(event["payload"], sort_keys=True)))


def command_cancel(args, _settings, store):
    if not store.request_cancel(args.task_id):
        raise RuntimeError("task is missing or already finished")
    emit({"task_id": args.task_id, "cancel_requested": True}, args.json)


def command_schedule(args, settings, store):
    if args.schedule_command == "list":
        emit(store.list_schedules(include_disabled=True), args.json)
        return 0
    if args.schedule_command in ("enable", "disable"):
        changed = store.set_schedule_enabled(
            args.schedule_id, args.schedule_command == "enable"
        )
        if not changed:
            raise RuntimeError("schedule not found: %s" % args.schedule_id)
        emit(
            {"schedule_id": args.schedule_id, "enabled": args.schedule_command == "enable"},
            args.json,
        )
        return 0
    if args.schedule_command == "remove":
        if not store.remove_schedule(args.schedule_id):
            raise RuntimeError("schedule not found: %s" % args.schedule_id)
        emit({"schedule_id": args.schedule_id, "removed": True}, args.json)
        return 0

    prompt = prompt_value(args)
    cwd = Path(args.cwd or os.getcwd()).expanduser().resolve()
    execution = resolve_execution(
        args.profile or settings.profile,
        provider=args.provider,
        model=args.model,
        effort=args.effort,
        sandbox=args.sandbox,
        isolation=args.isolation,
        max_attempts=args.max_attempts,
    )
    verification = verification_from_args(args)
    require_explicit_verification(execution, verification)
    ProviderRegistry(settings).validate(
        {
            "provider": execution["provider"],
            "metadata": {
                "required_capabilities": execution["required_capabilities"]
            },
        }
    )
    interval = parse_duration(args.every) if args.every else None
    delay = parse_duration(args.delay) if args.delay else interval
    if delay is None:
        raise ValueError("schedule add requires --delay or --every")
    schedule_id = store.add_schedule(
        name=args.name,
        prompt=prompt,
        cwd=cwd,
        provider=execution["provider"],
        model=execution["model"],
        profile=execution["profile"],
        effort=execution["effort"],
        sandbox=execution["sandbox"],
        isolation=execution["isolation"],
        next_run_at=time.time() + delay,
        interval_seconds=interval,
        delete_after_run=not bool(interval),
        priority=args.priority,
        max_attempts=execution["max_attempts"],
        verification=verification,
        verification_required=(
            bool(verification) or execution["require_verification"]
        ),
        metadata={
            "required_capabilities": execution["required_capabilities"],
            "disable_customizations": execution["disable_customizations"],
        },
    )
    emit(store.get_schedule(schedule_id), args.json)
    return 0


def command_status(args, settings, store):
    loaded = service.is_loaded(settings=settings)
    status = health(settings)
    identity_errors = daemon_identity_errors(settings, store, status)
    emit(
        {
            "version": __version__,
            "model": settings.model,
            "provider": settings.provider,
            "profile": settings.profile,
            "service_loaded": loaded,
            "health": status,
            "identity_match": not identity_errors,
            "identity_errors": identity_errors,
            "database_id": store.instance_id,
            "database": str(settings.db_path),
            "tasks": store.counts(),
        },
        args.json,
    )
    return 0 if status and not identity_errors else 1


def command_service(args, settings):
    if args.action == "start":
        service.start(settings)
    elif args.action == "stop":
        service.stop(settings)
    elif args.action == "restart":
        service.restart(settings)
    code, output = service.details(settings)
    print(output.rstrip())
    return code


def _live_probe(settings):
    from .quota import probe_exact_sol

    return probe_exact_sol(settings)


def find_grok_binary(settings):
    return discover_grok_binary(settings)


def command_doctor(args, settings, store):
    providers = ProviderRegistry(settings).report()
    daemon_status = health(settings)
    identity_errors = daemon_identity_errors(settings, store, daemon_status)
    current_source = source_identity(settings.repo_root)
    release_pointer = release.current_path(settings)
    active_release = None
    active_release_error = None
    if os.path.lexists(str(release_pointer)):
        try:
            installed = release.current(settings, required=True)
            active_release = {
                "release_id": installed.release_id,
                "release_manifest_sha256": installed.manifest_sha256,
                "version": installed.version,
                "source_tree_sha256": installed.tree_sha256,
                "runtime_sha256": installed.runtime_sha256,
                "path": str(installed.path),
            }
            if installed.tree_sha256 != current_source.get("tree_sha256"):
                active_release_error = (
                    "active release source bytes do not match the invoking CLI"
                )
        except RuntimeError as exc:
            active_release_error = str(exc)
    checks = {
        "codex_binary": settings.codex_bin.is_file(),
        "codex_auth": (Path.home() / ".codex/auth.json").is_file(),
        "model": settings.model,
        "providers": providers,
        "daemon": daemon_status,
        "daemon_identity_errors": identity_errors,
        "grok_binary": str(find_grok_binary(settings) or ""),
        "source_revision": (
            (settings.repo_root / "SOURCE_REV").read_text(encoding="utf-8").strip()
            if (settings.repo_root / "SOURCE_REV").is_file()
            else source_revision(settings.repo_root)
        ),
        "source_identity": current_source,
        "active_release": active_release,
        "active_release_error": active_release_error,
    }
    if args.live:
        checks["live_model_probe"] = _live_probe(settings)
    checks["ok"] = bool(
        checks["codex_binary"]
        and checks["codex_auth"]
        and checks["daemon"]
        and not identity_errors
        and not active_release_error
        and (not args.live or checks["live_model_probe"]["ok"])
    )
    emit(checks, args.json)
    return 0 if checks["ok"] else 1


def write_grok_client(settings, store, cwd):
    token = secrets.token_urlsafe(32)
    store.register_client(token, cwd, ttl_seconds=7 * 86400, label="grok-tui")
    client_home = settings.grok_clients_dir / token
    client_home.mkdir(parents=True, exist_ok=True)
    config = """[models]
default = "gpt-5.6-sol"
default_reasoning_effort = "high"
inference_idle_timeout_secs = 7500

[model."gpt-5.6-sol"]
model = "gpt-5.6-sol"
name = "GPT-5.6 Sol via Black Label Operator"
description = "Persistent exact-Sol execution through Black Label Operator"
base_url = "http://127.0.0.1:{port}/v1"
api_backend = "responses"
api_key = "{token}"
context_window = 400000
max_completion_tokens = 64000
max_retries = 1
inference_idle_timeout_secs = 7500
stream_tool_calls = false

[cli]
use_leader = false
""".format(port=settings.port, token=token)
    path = client_home / "config.toml"
    path.write_text(config, encoding="utf-8")
    path.chmod(0o600)
    return client_home


def passthrough_args(values):
    values = list(values or [])
    return values[1:] if values[:1] == ["--"] else values


def command_tui(args, settings, store):
    with store.admission():
        require_daemon(settings, store)
    binary = find_grok_binary(settings)
    if not binary:
        raise RuntimeError("Grok TUI is not built; run `operator build-grok`")
    cwd = Path(args.cwd or os.getcwd()).expanduser().resolve()
    client_home = write_grok_client(settings, store, cwd)
    env = os.environ.copy()
    env["GROK_HOME"] = str(client_home)
    command = [str(binary), "--cwd", str(cwd), "-m", settings.model, "--no-auto-update"]
    command.extend(passthrough_args(args.grok_args))
    return subprocess.call(command, env=env)


def command_build_grok(args, settings):
    code, source, binary = build_grok(settings, release=args.release)
    if code == 0:
        emit({"source": str(source), "binary": str(binary)}, args.json)
    return code


def command_ide(args, settings):
    target = Path(args.cwd or settings.repo_root).expanduser().resolve()
    if not target.is_dir():
        raise RuntimeError("IDE workspace does not exist: %s" % target)
    if args.action == "install":
        result = ide_integration.install(settings, target)
    elif args.action == "status":
        result = ide_integration.status(settings, target)
    elif args.action == "uninstall":
        result = ide_integration.uninstall()
    else:
        result = ide_integration.open_workspace(settings, target)
    emit(result, args.json)
    return 0 if args.action != "status" or result["configured"] else 1


def add_prompt_options(parser):
    parser.add_argument("prompt", nargs="*")
    parser.add_argument("--cwd")
    parser.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max", "ultra"))
    parser.add_argument("--profile", choices=tuple(PROFILES), default=None)
    parser.add_argument("--provider")
    parser.add_argument("--model")
    parser.add_argument("--sandbox", choices=("read-only", "workspace-write", "danger-full-access"))
    parser.add_argument("--isolation", choices=("shared", "worktree"))
    parser.add_argument("--priority", type=int, default=0)
    parser.add_argument("--max-attempts", type=int)
    parser.add_argument("--after", action="append", default=[])
    parser.add_argument("--verify", action="append", default=[])
    parser.add_argument(
        "--verify-spec",
        action="append",
        default=[],
        metavar="JSON",
        help=(
            "structured verifier entry, for example "
            "'{\"command\":\"npm test\",\"writable_paths\":[\"dist\"]}'"
        ),
    )
    parser.add_argument("--json", action="store_true")


def build_parser():
    parser = argparse.ArgumentParser(
        prog="operator",
        description="Black Label Operator: durable orchestration for coding-agent CLIs",
    )
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    from .reliability import OPERATIONS
    reliability = sub.add_parser("reliability", help="project outcomes, memory, actions, events, playbooks and budgets")
    reliability.add_argument("operation", choices=OPERATIONS)
    reliability.add_argument("--project", default=os.getcwd())
    reliability.add_argument("--input", help="JSON input file; use - to read stdin")
    reliability.add_argument("--json", action="store_true")

    install = sub.add_parser("install", help="install and start the native 24/7 service")
    install.add_argument("--no-start", action="store_true")
    install.add_argument("--json", action="store_true")

    activate_prebuilt = sub.add_parser(
        "activate-prebuilt", help=argparse.SUPPRESS
    )
    activate_prebuilt.add_argument("--release-id", required=True)
    activate_prebuilt.add_argument("--json", action="store_true")

    uninstall = sub.add_parser("uninstall", help="remove Operator while preserving state")
    uninstall.add_argument("--purge-state", action="store_true")
    uninstall.add_argument("--json", action="store_true")

    sub.add_parser("daemon", help=argparse.SUPPRESS)

    run = sub.add_parser("run", help="queue a task and wait for completion")
    add_prompt_options(run)
    run.add_argument("--timeout", type=float)

    submit = sub.add_parser("submit", help="queue a task and return immediately")
    add_prompt_options(submit)

    wait = sub.add_parser("wait", help="wait for a queued task")
    wait.add_argument("task_id")
    wait.add_argument("--timeout", type=float)
    wait.add_argument("--follow", action="store_true")
    wait.add_argument("--json", action="store_true")

    listing = sub.add_parser("list", help="list durable tasks")
    listing.add_argument("--state")
    listing.add_argument("--limit", type=int, default=20)
    listing.add_argument("--json", action="store_true")

    show = sub.add_parser("show", help="show one task")
    show.add_argument("task_id")
    show.add_argument("--json", action="store_true")

    events = sub.add_parser("events", help="show a task event stream")
    events.add_argument("task_id")
    events.add_argument("--after", type=int, default=0)
    events.add_argument("--limit", type=int, default=1000)
    events.add_argument("--json", action="store_true")

    cancel = sub.add_parser("cancel", help="cancel a queued or running task")
    cancel.add_argument("task_id")
    cancel.add_argument("--json", action="store_true")

    graph = sub.add_parser("graph", help="show dependencies and dependents")
    graph.add_argument("task_id")
    graph.add_argument("--json", action="store_true")

    artifacts = sub.add_parser("artifacts", help="list captured task artifacts")
    artifacts.add_argument("task_id")
    artifacts.add_argument("--json", action="store_true")

    apply_task = sub.add_parser("apply", help="apply an isolated task patch")
    apply_task.add_argument("task_id")
    apply_task.add_argument("--json", action="store_true")
    apply_task.add_argument("--preview", action="store_true", help="validate and show the patch without applying")
    apply_task.add_argument("--expected-sha256", help="require the patch hash shown in the preview")

    providers = sub.add_parser("providers", help="show discovered CLI providers")
    providers.add_argument("--json", action="store_true")

    profiles = sub.add_parser("profiles", help="show execution guarantee profiles")
    profiles.add_argument("--json", action="store_true")

    schedule = sub.add_parser("schedule", help="manage durable one-shot and recurring work")
    schedule_sub = schedule.add_subparsers(dest="schedule_command", required=True)
    schedule_add = schedule_sub.add_parser("add", help="create a durable schedule")
    add_prompt_options(schedule_add)
    schedule_add.add_argument("--name", required=True)
    timing = schedule_add.add_mutually_exclusive_group(required=True)
    timing.add_argument("--delay", help="run once after a duration such as 10m")
    timing.add_argument("--every", help="run repeatedly at an interval such as 6h")
    schedule_list = schedule_sub.add_parser("list")
    schedule_list.add_argument("--json", action="store_true")
    for action in ("enable", "disable", "remove"):
        item = schedule_sub.add_parser(action)
        item.add_argument("schedule_id")
        item.add_argument("--json", action="store_true")

    status = sub.add_parser("status", help="show daemon and queue health")
    status.add_argument("--json", action="store_true")

    control = sub.add_parser("service", help="control the dedicated 24/7 service")
    control.add_argument("action", choices=("start", "stop", "restart", "status"))

    doctor = sub.add_parser("doctor", help="verify runtime, auth, and exact model access")
    doctor.add_argument("--live", action="store_true")
    doctor.add_argument("--json", action="store_true")

    tui = sub.add_parser("tui", help="open the optional Grok Build frontend backed by Sol")
    tui.add_argument("--cwd")
    tui.add_argument("grok_args", nargs=argparse.REMAINDER)

    build = sub.add_parser("build-grok", help="build the upstream Grok Build TUI")
    build.add_argument("--release", action="store_true")
    build.add_argument("--json", action="store_true")

    ide = sub.add_parser("ide", help="install, inspect, or open the Antigravity MCP integration")
    ide.add_argument(
        "action", nargs="?", choices=("open", "install", "status", "uninstall"), default="open"
    )
    ide.add_argument("--cwd")
    ide.add_argument("--json", action="store_true")

    benchmark = sub.add_parser("benchmark", help="run deterministic coding-agent benchmarks")
    benchmark.add_argument("benchmark_args", nargs=argparse.REMAINDER)
    return parser


def dispatch(args, settings, store):
    if args.command == "reliability":
        from .reliability import Reliability, strict_json
        data = {}
        if args.input:
            raw = sys.stdin.read(128001) if args.input == "-" else Path(args.input).read_text()
            if len(raw) > 128000:
                raise ValueError("reliability input exceeds 128000 characters")
            data = strict_json(raw)
        emit(Reliability(store).call(args.operation, args.project, data), args.json)
        return 0
    if args.command == "install":
        return command_install(args, settings, store)
    if args.command == "activate-prebuilt":
        return command_activate_prebuilt(args, settings, store)
    if args.command == "uninstall":
        return command_uninstall(args, settings)
    if args.command == "daemon":
        return run_daemon(settings)
    if args.command == "run":
        return command_run(args, settings, store)
    if args.command == "submit":
        return command_submit(args, settings, store)
    if args.command == "wait":
        return command_wait(args, settings, store)
    if args.command == "list":
        return command_list(args, settings, store)
    if args.command == "show":
        return command_show(args, settings, store)
    if args.command == "events":
        return command_events(args, settings, store)
    if args.command == "cancel":
        return command_cancel(args, settings, store)
    if args.command == "graph":
        value = store.graph(args.task_id)
        if value is None:
            raise RuntimeError("task not found: %s" % args.task_id)
        emit(value, args.json)
        return 0
    if args.command == "artifacts":
        if not store.get(args.task_id):
            raise RuntimeError("task not found: %s" % args.task_id)
        emit(store.artifacts(args.task_id), args.json)
        return 0
    if args.command == "apply":
        task = store.get(args.task_id)
        if not task:
            raise RuntimeError("task not found: %s" % args.task_id)
        if task["state"] != "succeeded":
            raise RuntimeError("only succeeded task artifacts can be applied")
        if task.get("verification_required") and task.get("verification_status") != "passed":
            raise RuntimeError("required verification must pass before applying a patch")
        emit(WorkspaceManager(settings, store).apply(
            task, preview=args.preview, expected_sha256=args.expected_sha256
        ), args.json)
        return 0
    if args.command == "providers":
        emit(ProviderRegistry(settings).report(), args.json)
        return 0
    if args.command == "profiles":
        emit({name: profile.as_dict() for name, profile in PROFILES.items()}, args.json)
        return 0
    if args.command == "schedule":
        return command_schedule(args, settings, store)
    if args.command == "status":
        return command_status(args, settings, store)
    if args.command == "service":
        return command_service(args, settings)
    if args.command == "doctor":
        return command_doctor(args, settings, store)
    if args.command == "tui":
        return command_tui(args, settings, store)
    if args.command == "build-grok":
        return command_build_grok(args, settings)
    if args.command == "ide":
        return command_ide(args, settings)
    if args.command == "benchmark":
        from .benchmark import main as benchmark_main

        return benchmark_main(args.benchmark_args, settings)
    raise RuntimeError("unknown command: %s" % args.command)


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        settings = Settings.load()
        settings.ensure_dirs()
        store = Store(settings.db_path)
        result = dispatch(args, settings, store)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print("operator: %s" % exc, file=sys.stderr)
        return_code = 1
    else:
        return_code = int(result or 0)
    if argv is None:
        raise SystemExit(return_code)
    return return_code
