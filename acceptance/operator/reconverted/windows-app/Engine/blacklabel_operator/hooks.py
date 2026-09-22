import json
import os
import shlex
from pathlib import Path

from .codex_runner import CodexRunner, UnconfirmedTerminationError


HOOK_NAMES = (
    "before_task",
    "after_task",
    "on_success",
    "on_failure",
    "before_verify",
    "after_verify",
)


def _read_json(path):
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("Operator config must be a JSON object: %s" % path)
    return value


def load_operator_config(settings, cwd, include_repo_config=True):
    merged = {"hooks": {}}
    paths = [settings.home / "config.json"]
    if include_repo_config:
        paths.append(Path(cwd).expanduser().resolve() / ".operator/config.json")
    for path in paths:
        value = _read_json(path)
        for key, item in value.items():
            if key == "hooks" and isinstance(item, dict):
                merged["hooks"].update(item)
            else:
                merged[key] = item
    return merged


def _generation(store, task):
    value = getattr(store, "generation", None)
    if value is None:
        value = task.get("lease_generation") or 0
    return max(0, int(value))


def _write_immutable(path, text):
    payload = str(text).encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        path.chmod(0o400)
    except FileExistsError as exc:
        raise RuntimeError("hook artifact path already exists: %s" % path) from exc


class HookRunner:
    def __init__(self, settings, store):
        self.settings = settings
        self.store = store

    @staticmethod
    def _commands(config, hook_name):
        raw = (config.get("hooks") or {}).get(hook_name, [])
        if isinstance(raw, (str, dict)):
            raw = [raw]
        commands = []
        for item in raw:
            if isinstance(item, str):
                commands.append({"argv": shlex.split(item)})
            elif isinstance(item, list):
                commands.append({"argv": [str(part) for part in item]})
            elif isinstance(item, dict):
                command = dict(item)
                argv = command.get("argv") or command.get("command")
                if isinstance(argv, str):
                    argv = shlex.split(argv)
                command["argv"] = [str(part) for part in argv or []]
                commands.append(command)
            else:
                raise ValueError("invalid %s hook entry" % hook_name)
        return commands

    def run(self, hook_name, task, payload=None, heartbeat=None, cancelled=None):
        if hook_name not in HOOK_NAMES:
            raise ValueError("unknown Operator hook: %s" % hook_name)
        adaptive = task.get("profile") == "adaptive"
        if adaptive:
            self.store.add_event(
                task["id"],
                "hook.skipped",
                {
                    "hook": hook_name,
                    "profile": "adaptive",
                    "reason": "adaptive executor-only mutation boundary",
                },
            )
            return []
        config = load_operator_config(
            self.settings,
            task["cwd"],
            include_repo_config=False,
        )
        results = []
        resolver = getattr(self.store, "attempt_path", None)
        if resolver is not None:
            task_dir = resolver(self.settings.tasks_dir, "hooks")
        else:
            task_dir = (
                self.settings.tasks_dir
                / task["id"]
                / ("generation-%08d" % _generation(self.store, task))
                / "hooks"
            )
        task_dir.mkdir(parents=True, exist_ok=True)
        envelope = {
            "hook": hook_name,
            "task": task,
            "payload": payload or {},
        }
        for index, command in enumerate(self._commands(config, hook_name), start=1):
            argv = command["argv"]
            if not argv:
                raise ValueError("%s hook has an empty command" % hook_name)
            timeout = max(1, float(command.get("timeout_seconds", 60)))
            completed = CodexRunner.run_supervised(
                argv,
                cwd=task["cwd"],
                input_text=json.dumps(envelope, sort_keys=True),
                timeout=timeout,
                heartbeat=heartbeat,
                cancelled=cancelled,
                poll_seconds=self.settings.poll_seconds,
                on_start=lambda pid, group, identity, command_index=index: (
                    self.store.update_metadata(
                        task["id"],
                        {
                            "active_subprocess_kind": "hook:%s" % hook_name,
                            "active_subprocess_index": command_index,
                            "active_subprocess_pid": pid,
                            "active_subprocess_group_id": group,
                            "active_subprocess_identity": identity,
                        },
                    )
                ),
            )
            if not completed.termination_confirmed:
                raise UnconfirmedTerminationError(
                    completed.pid, completed.termination_detail
                )
            if not getattr(completed, "leaked_descendants", False):
                self.store.update_metadata(
                    task["id"],
                    {
                        "active_subprocess_kind": None,
                        "active_subprocess_index": None,
                        "active_subprocess_pid": None,
                        "active_subprocess_group_id": None,
                        "active_subprocess_identity": None,
                    },
                )
            if heartbeat:
                heartbeat()
            stdout_path = task_dir / ("%s-%02d.stdout.log" % (hook_name, index))
            stderr_path = task_dir / ("%s-%02d.stderr.log" % (hook_name, index))
            _write_immutable(stdout_path, completed.stdout)
            _write_immutable(stderr_path, completed.stderr)
            self.store.add_artifact(task["id"], "hook-log", stdout_path)
            self.store.add_artifact(task["id"], "hook-log", stderr_path)
            result = {
                "argv": argv,
                "exit_code": completed.returncode,
                "stdout": completed.stdout[-4000:],
                "stderr": completed.stderr[-4000:],
                "timed_out": completed.timed_out,
                "cancelled": completed.cancelled,
                "termination_confirmed": completed.termination_confirmed,
                "leaked_descendants": bool(
                    getattr(completed, "leaked_descendants", False)
                ),
            }
            results.append(result)
            self.store.add_event(task["id"], "hook.%s" % hook_name, result)
            if (
                completed.timed_out
                or completed.cancelled
                or completed.returncode != 0
                or getattr(completed, "leaked_descendants", False)
            ):
                raise RuntimeError(
                    "%s hook %s"
                    % (
                        hook_name,
                        "timed out"
                        if completed.timed_out
                        else "was cancelled"
                        if completed.cancelled
                        else "failed with status %s" % completed.returncode,
                    )
                )
            if completed.stdout.strip():
                try:
                    decision = json.loads(completed.stdout)
                except json.JSONDecodeError:
                    decision = None
                if isinstance(decision, dict) and decision.get("decision") == "deny":
                    raise RuntimeError(
                        "%s hook denied task: %s"
                        % (hook_name, decision.get("reason", "no reason supplied"))
                    )
        return results
