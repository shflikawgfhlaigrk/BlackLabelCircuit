"""Isolated execution boundary for model-generated ARC world models.

The parent process never imports ``world_model.py``.  It verifies and stages the
exact source bytes, then asks a fresh isolated Python child to build or verify a
``ValidatedArcPlan``.  The child receives no ambient environment and emits one
bounded JSON envelope; any other output fails the request closed.
"""

import ast
import hashlib
import json
import math
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile
import types
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple, Union

from .arc_planner import ArcObservation, PlannedArcAction
from .arc_world_model import (
    ARC_VALIDATED_PLAN_SCHEMA,
    ArcModelIdentity,
    ArcPlanComplete,
    ArcPlanInvalidated,
    ArcStateSnapshot,
    ArcStepPrediction,
    ArcWorldModelContractError,
    ArcWorldOutcome,
    ValidatedArcNextAction,
    ValidatedArcPlan,
    frame_sha256,
    observation_sha256,
    validate_next_action_from_plan,
)


ARC_WORLD_MODEL_RUNTIME_SCHEMA = "black-label-operator/arc-world-model-runtime-v3"
_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_ARC_ACTION_NAMES = frozenset(
    ("RESET", "ACTION1", "ACTION2", "ACTION3", "ACTION4", "ACTION5", "ACTION6", "ACTION7")
)
_ABSOLUTE_MAX_SOURCE_BYTES = 1024 * 1024
_ABSOLUTE_MAX_REQUEST_BYTES = 4 * 1024 * 1024
_ABSOLUTE_MAX_OUTPUT_BYTES = 4 * 1024 * 1024
_DARWIN_ADDRESS_SPACE_FLOOR = 1024 * 1024 * 1024 * 1024
_CHILD_BOOTSTRAP = (
    "import sys; "
    "sys.path.insert(0, sys.argv[1]); "
    "from blacklabel_operator.arc_world_model_runtime import _child_main; "
    "raise SystemExit(_child_main())"
)


class ArcWorldModelRuntimeError(RuntimeError):
    """The isolated model process failed a containment or data-contract gate."""

    def __init__(self, code: str, message: str):
        super().__init__("%s: %s" % (code, message))
        self.code = code


@dataclass(frozen=True)
class ArcWorldModelRuntimeLimits:
    """Hard limits applied to every fresh model subprocess."""

    timeout_seconds: float = 5.0
    max_source_bytes: int = 512 * 1024
    max_request_bytes: int = 2 * 1024 * 1024
    max_output_bytes: int = 2 * 1024 * 1024
    max_address_space_bytes: int = 1024 * 1024 * 1024
    max_open_files: int = 64
    max_processes: int = 1

    def as_payload(self) -> Dict[str, object]:
        """Return the exact limits contract sent over the trusted child pipe."""

        self.validate()
        return {
            "max_address_space_bytes": self.max_address_space_bytes,
            "max_open_files": self.max_open_files,
            "max_output_bytes": self.max_output_bytes,
            "max_processes": self.max_processes,
            "max_request_bytes": self.max_request_bytes,
            "max_source_bytes": self.max_source_bytes,
            "timeout_seconds": float(self.timeout_seconds),
        }

    def validate(self) -> None:
        if (
            not isinstance(self.timeout_seconds, (int, float))
            or isinstance(self.timeout_seconds, bool)
            or not math.isfinite(float(self.timeout_seconds))
            or not 0.05 <= float(self.timeout_seconds) <= 300.0
        ):
            raise ArcWorldModelRuntimeError(
                "invalid_limits", "timeout_seconds must be in 0.05..300"
            )
        for name, value, lower, upper in (
            (
                "max_source_bytes",
                self.max_source_bytes,
                1024,
                _ABSOLUTE_MAX_SOURCE_BYTES,
            ),
            (
                "max_request_bytes",
                self.max_request_bytes,
                4096,
                _ABSOLUTE_MAX_REQUEST_BYTES,
            ),
            (
                "max_output_bytes",
                self.max_output_bytes,
                4096,
                _ABSOLUTE_MAX_OUTPUT_BYTES,
            ),
            (
                "max_address_space_bytes",
                self.max_address_space_bytes,
                128 * 1024 * 1024,
                2 * 1024 * 1024 * 1024 * 1024,
            ),
            ("max_open_files", self.max_open_files, 16, 256),
            ("max_processes", self.max_processes, 1, 32),
        ):
            if type(value) is not int or not lower <= value <= upper:
                raise ArcWorldModelRuntimeError(
                    "invalid_limits", "%s is outside its safe range" % name
                )

    @classmethod
    def from_payload(cls, value: object) -> "ArcWorldModelRuntimeLimits":
        payload = _strict_object(
            value,
            {
                "max_address_space_bytes",
                "max_open_files",
                "max_output_bytes",
                "max_processes",
                "max_request_bytes",
                "max_source_bytes",
                "timeout_seconds",
            },
            "limits",
        )
        if type(payload["timeout_seconds"]) is not float:
            raise ArcWorldModelRuntimeError(
                "invalid_limits", "timeout_seconds must use canonical float encoding"
            )
        limits = cls(
            timeout_seconds=payload["timeout_seconds"],
            max_source_bytes=payload["max_source_bytes"],
            max_request_bytes=payload["max_request_bytes"],
            max_output_bytes=payload["max_output_bytes"],
            max_address_space_bytes=payload["max_address_space_bytes"],
            max_open_files=payload["max_open_files"],
            max_processes=payload["max_processes"],
        )
        limits.validate()
        if limits.as_payload() != payload:
            raise ArcWorldModelRuntimeError(
                "invalid_limits", "limits payload is not canonical"
            )
        return limits


def _strict_object(value: object, keys: set, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ArcWorldModelRuntimeError(
            "invalid_%s" % label.replace(" ", "_"), "%s must be an object" % label
        )
    if set(value) != keys:
        raise ArcWorldModelRuntimeError(
            "invalid_%s" % label.replace(" ", "_"),
            "%s keys differ from the runtime contract" % label,
        )
    return dict(value)


def _validate_sha256(value: object) -> str:
    if not isinstance(value, str) or not _SHA256_PATTERN.fullmatch(value):
        raise ArcWorldModelRuntimeError(
            "invalid_source_hash", "source_sha256 must be a lowercase SHA-256"
        )
    return value


def _canonical_json_bytes(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_request", "runtime request is not canonical JSON: %s" % exc
        )


def _reject_duplicate_pairs(pairs: Sequence[Tuple[str, object]]) -> Dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key %s" % key)
        result[key] = value
    return result


def _reject_nonfinite_constant(value: str) -> None:
    raise ValueError("non-finite JSON number %s" % value)


def _parse_exact_json(data: bytes, limit: int, label: str) -> object:
    if not data or len(data) > limit:
        code = "output_oversize" if len(data) > limit else "invalid_child_output"
        raise ArcWorldModelRuntimeError(code, "%s has an invalid size" % label)
    if data != data.strip():
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "%s contains surrounding noise" % label
        )
    try:
        text = data.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "%s is not one exact JSON value: %s" % (label, exc)
        )


def _path_is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _prepare_paths(
    workspace: Union[str, os.PathLike],
    authoritative_state_dir: Union[str, os.PathLike],
) -> Tuple[Path, Path]:
    raw_workspace = Path(workspace)
    raw_state = Path(authoritative_state_dir)
    if raw_workspace.is_symlink() or raw_state.is_symlink():
        raise ArcWorldModelRuntimeError(
            "unsafe_runtime_path", "workspace and authoritative state cannot be symlinks"
        )
    try:
        work = raw_workspace.resolve(strict=True)
        state_dir = raw_state.resolve(strict=True)
    except OSError as exc:
        raise ArcWorldModelRuntimeError(
            "unsafe_runtime_path", "runtime paths must already exist: %s" % exc
        )
    if not work.is_dir() or not state_dir.is_dir():
        raise ArcWorldModelRuntimeError(
            "unsafe_runtime_path", "runtime paths must be directories"
        )
    if _path_is_within(work, state_dir) or _path_is_within(state_dir, work):
        raise ArcWorldModelRuntimeError(
            "state_workspace_overlap",
            "per-game workspace must be disjoint from authoritative state",
        )
    if work == Path(work.anchor):
        raise ArcWorldModelRuntimeError(
            "unsafe_runtime_path", "filesystem root is not a per-game workspace"
        )
    return work, state_dir


def _read_source(
    source: Union[bytes, bytearray, memoryview, str, os.PathLike],
    expected_sha256: str,
    max_bytes: int,
) -> bytes:
    if isinstance(source, (bytes, bytearray, memoryview)):
        data = bytes(source)
    else:
        try:
            path = Path(source).resolve(strict=True)
            descriptor = os.open(
                str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            )
        except (OSError, TypeError, ValueError) as exc:
            raise ArcWorldModelRuntimeError(
                "invalid_source", "verified source path cannot be opened: %s" % exc
            )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise ArcWorldModelRuntimeError(
                    "invalid_source", "verified source must be a regular file"
                )
            if metadata.st_size > max_bytes:
                raise ArcWorldModelRuntimeError(
                    "source_oversize", "verified source exceeds its byte limit"
                )
            chunks = []
            remaining = max_bytes + 1
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
        finally:
            os.close(descriptor)
    if not data or len(data) > max_bytes:
        raise ArcWorldModelRuntimeError(
            "source_oversize", "verified source is empty or exceeds its byte limit"
        )
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise ArcWorldModelRuntimeError(
            "source_hash_mismatch", "world-model source changed after verification"
        )
    return data


def _write_staged_source(directory: Path, source: bytes, digest: str) -> Path:
    destination = directory / ("world_model-%s.py" % digest)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(str(destination), flags, 0o400)
    try:
        view = memoryview(source)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return destination


def _observation_payload(observation: ArcObservation) -> Dict[str, object]:
    observation_sha256(observation)
    if not isinstance(observation.text, str):
        raise ArcWorldModelRuntimeError(
            "invalid_observation", "observation text must be a string"
        )
    return {
        "available": list(observation.available),
        "frame": [list(row) for row in observation.frame],
        "levels_completed": observation.levels_completed,
        "state": observation.state,
        "text": observation.text,
    }


def _observation_from_payload(value: object) -> ArcObservation:
    payload = _strict_object(
        value,
        {"available", "frame", "levels_completed", "state", "text"},
        "observation",
    )
    if not isinstance(payload["available"], list) or not isinstance(
        payload["frame"], list
    ):
        raise ArcWorldModelRuntimeError(
            "invalid_observation", "observation arrays are invalid"
        )
    try:
        observation = ArcObservation(
            text=payload["text"],
            state=payload["state"],
            levels_completed=payload["levels_completed"],
            available=tuple(payload["available"]),
            frame=tuple(tuple(row) for row in payload["frame"]),
        )
        observation_sha256(observation)
    except (TypeError, ArcWorldModelContractError) as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_observation", "observation payload is invalid: %s" % exc
        )
    return observation


def _action_payload(action: PlannedArcAction) -> Dict[str, object]:
    if not isinstance(action, PlannedArcAction):
        raise ArcWorldModelRuntimeError(
            "invalid_action", "actions must be PlannedArcAction values"
        )
    if action.name not in _ARC_ACTION_NAMES:
        raise ArcWorldModelRuntimeError(
            "invalid_action", "action name is not canonical"
        )
    if action.name == "ACTION6":
        if (
            type(action.x) is not int
            or type(action.y) is not int
            or not 0 <= action.x <= 63
            or not 0 <= action.y <= 63
        ):
            raise ArcWorldModelRuntimeError(
                "invalid_action", "ACTION6 requires integer coordinates in 0..63"
            )
        return {"action": action.name, "x": action.x, "y": action.y}
    if action.x is not None or action.y is not None:
        raise ArcWorldModelRuntimeError(
            "invalid_action", "only ACTION6 accepts coordinates"
        )
    return {"action": action.name}


def _action_from_payload(value: object) -> PlannedArcAction:
    if not isinstance(value, dict):
        raise ArcWorldModelRuntimeError("invalid_action", "action must be an object")
    name = value.get("action")
    expected = {"action", "x", "y"} if name == "ACTION6" else {"action"}
    payload = _strict_object(value, expected, "action")
    action = PlannedArcAction(name, payload.get("x"), payload.get("y"))
    normalized = _action_payload(action)
    if normalized != payload:
        raise ArcWorldModelRuntimeError("invalid_action", "action is not canonical")
    return action


def _sandbox_quote(path: Path) -> str:
    return str(path).replace("\\", "\\\\").replace('"', '\\"')


def _existing_resolved(path: Union[str, os.PathLike]) -> Optional[Path]:
    try:
        return Path(path).resolve(strict=True)
    except OSError:
        return None


def _resolved_python_executable() -> str:
    """Return a real executable path so sandbox launch never traverses venv links."""

    try:
        executable = Path(sys.executable).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ArcWorldModelRuntimeError(
            "python_runtime_unavailable",
            "isolated Python executable cannot be resolved: %s" % exc,
        )
    try:
        metadata = executable.stat()
    except OSError as exc:
        raise ArcWorldModelRuntimeError(
            "python_runtime_unavailable",
            "isolated Python executable cannot be inspected: %s" % exc,
        )
    if not stat.S_ISREG(metadata.st_mode) or not os.access(executable, os.X_OK):
        raise ArcWorldModelRuntimeError(
            "python_runtime_unavailable",
            "isolated Python executable is not a regular executable file",
        )
    return str(executable)


def _macos_runtime_read_paths(workspace: Path) -> Tuple[Tuple[Path, ...], Tuple[Path, ...]]:
    package_root = Path(__file__).resolve().parent
    recursive = {workspace, package_root}
    literal = {package_root.parent}
    raw_executable = Path(sys.executable).absolute()
    if raw_executable.exists():
        literal.add(raw_executable)
    for candidate in (sys.prefix, sys.base_prefix):
        resolved = _existing_resolved(candidate)
        if resolved is not None:
            recursive.add(resolved)
    for candidate in (
        sys.executable,
        Path(sys.executable).resolve(),
        "/private/etc/localtime",
        "/dev/null",
        "/dev/urandom",
    ):
        resolved = _existing_resolved(candidate)
        if resolved is not None:
            literal.add(resolved)
    for candidate in (
        "/System",
        "/usr/lib",
        "/usr/share/locale",
        "/usr/share/zoneinfo",
        "/private/var/db/timezone",
    ):
        resolved = _existing_resolved(candidate)
        if resolved is not None:
            recursive.add(resolved)
    return tuple(sorted(recursive, key=str)), tuple(sorted(literal, key=str))


def build_macos_sandbox_profile(
    workspace: Union[str, os.PathLike],
    write_root: Optional[Union[str, os.PathLike]] = None,
) -> str:
    """Return the exact workspace-scoped sandbox policy used on macOS."""

    resolved = Path(workspace).resolve(strict=True)
    resolved_write_root = (
        Path(write_root).resolve(strict=True) if write_root is not None else resolved
    )
    if not _path_is_within(resolved_write_root, resolved):
        raise ArcWorldModelRuntimeError(
            "unsafe_runtime_path", "sandbox write root must stay inside workspace"
        )
    recursive, literal = _macos_runtime_read_paths(resolved)
    lines = [
        "(version 1)",
        "(deny default)",
        '(import "dyld-support.sb")',
        "(deny network*)",
        "(allow file-read*",
    ]
    lines.extend(
        '    (subpath "%s")' % _sandbox_quote(path) for path in recursive
    )
    lines.extend('    (literal "%s")' % _sandbox_quote(path) for path in literal)
    lines.extend(
        (
            ")",
            "(allow file-read-metadata file-test-existence",
        )
    )
    lines.extend(
        '    (path-ancestors "%s")' % _sandbox_quote(path)
        for path in recursive + literal
    )
    lines.extend(
        (
            ")",
            '(allow file-write* (subpath "%s"))'
            % _sandbox_quote(resolved_write_root),
            "(allow process-exec)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
        )
    )
    return "\n".join(lines)


def _sandboxed_command(
    command: Sequence[str],
    workspace: Path,
    write_root: Path,
    require_macos_sandbox: bool,
    sandbox_executable: Union[str, os.PathLike],
) -> Sequence[str]:
    is_macos = platform.system() == "Darwin"
    executable = Path(sandbox_executable)
    available = is_macos and executable.is_absolute() and executable.is_file()
    if require_macos_sandbox and not available:
        raise ArcWorldModelRuntimeError(
            "isolation_unavailable", "required macOS sandbox-exec is unavailable"
        )
    if not available:
        return tuple(command)
    return (
        str(executable),
        "-p",
        build_macos_sandbox_profile(workspace, write_root=write_root),
        *command,
    )


def _apply_resource_limits(limits: ArcWorldModelRuntimeLimits) -> None:
    """Irreversibly apply validated hard limits inside the isolated child.

    This runs only after the child has parsed the parent-authored request and
    before any staged model source is read, compiled, or executed. Keeping it
    out of ``Popen(preexec_fn=...)`` avoids running Python in the unsafe
    post-fork window of a multithreaded parent.
    """

    limits.validate()
    try:
        import resource

        def set_limit(name: str, value: int) -> None:
            kind = getattr(resource, name, None)
            if kind is None:
                raise RuntimeError("%s is unavailable" % name)
            _soft, hard = resource.getrlimit(kind)
            target = value
            if hard != resource.RLIM_INFINITY:
                target = min(target, int(hard))
            resource.setrlimit(kind, (target, target))

        set_limit("RLIMIT_CPU", max(1, int(math.ceil(limits.timeout_seconds))))
        address_space_limit = limits.max_address_space_bytes
        # Darwin maps a several-hundred-gigabyte shared address region into
        # even an idle Python process. A conventional 1 GiB RLIMIT_AS is below
        # the process's existing virtual size, so keep a finite compatible cap.
        if platform.system() == "Darwin":
            address_space_limit = max(
                address_space_limit, _DARWIN_ADDRESS_SPACE_FLOOR
            )
        set_limit("RLIMIT_AS", address_space_limit)
        set_limit("RLIMIT_FSIZE", limits.max_output_bytes)
        set_limit("RLIMIT_NPROC", limits.max_processes)
        set_limit("RLIMIT_NOFILE", limits.max_open_files)
        if hasattr(resource, "RLIMIT_CORE"):
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except Exception as exc:
        raise ArcWorldModelRuntimeError(
            "resource_limit_failed", "child could not apply hard limits: %s" % exc
        )


def _sanitized_environment(workspace: Path, temp_dir: Path) -> Dict[str, str]:
    return {
        "HOME": str(workspace),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0",
        "PYTHONNOUSERSITE": "1",
        "TMPDIR": str(temp_dir),
    }


def _terminate_child(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.communicate(timeout=1.0)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _run_child(
    request: Mapping[str, object],
    source: Union[bytes, bytearray, memoryview, str, os.PathLike],
    source_sha256: str,
    workspace: Union[str, os.PathLike],
    authoritative_state_dir: Union[str, os.PathLike],
    limits: Optional[ArcWorldModelRuntimeLimits],
    require_macos_sandbox: bool,
    sandbox_executable: Union[str, os.PathLike],
) -> Dict[str, object]:
    checked_limits = limits or ArcWorldModelRuntimeLimits()
    checked_limits.validate()
    digest = _validate_sha256(source_sha256)
    work, _state_dir = _prepare_paths(workspace, authoritative_state_dir)
    source_bytes = _read_source(source, digest, checked_limits.max_source_bytes)
    engine_root = Path(__file__).resolve().parent.parent

    with tempfile.TemporaryDirectory(prefix=".arc-world-model-", dir=str(work)) as raw:
        invocation_dir = Path(raw).resolve()
        runtime_temp = invocation_dir / "tmp"
        runtime_temp.mkdir(mode=0o700)
        source_path = _write_staged_source(invocation_dir, source_bytes, digest)
        payload = dict(request)
        payload.update(
            {
                "limits": checked_limits.as_payload(),
                "schema": ARC_WORLD_MODEL_RUNTIME_SCHEMA,
                "source_path": str(source_path),
                "source_sha256": digest,
            }
        )
        request_bytes = _canonical_json_bytes(payload)
        request_sha256 = hashlib.sha256(request_bytes).hexdigest()
        if len(request_bytes) > checked_limits.max_request_bytes:
            raise ArcWorldModelRuntimeError(
                "request_oversize", "world-model runtime request exceeds its limit"
            )
        command = (
            _resolved_python_executable(),
            "-I",
            "-S",
            "-c",
            _CHILD_BOOTSTRAP,
            str(engine_root),
        )
        command = _sandboxed_command(
            command,
            work,
            invocation_dir,
            require_macos_sandbox,
            sandbox_executable,
        )
        stdout_path = invocation_dir / "stdout.bin"
        stderr_path = invocation_dir / "stderr.bin"
        with stdout_path.open("w+b") as stdout_handle, stderr_path.open(
            "w+b"
        ) as stderr_handle:
            try:
                process = subprocess.Popen(
                    command,
                    cwd=str(work),
                    env=_sanitized_environment(work, runtime_temp),
                    stdin=subprocess.PIPE,
                    stdout=stdout_handle,
                    stderr=stderr_handle,
                    close_fds=True,
                    start_new_session=True,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise ArcWorldModelRuntimeError(
                    "child_start_failed", "isolated Python could not start: %s" % exc
                )
            try:
                process.communicate(
                    input=request_bytes,
                    timeout=float(checked_limits.timeout_seconds),
                )
            except subprocess.TimeoutExpired:
                _terminate_child(process)
                raise ArcWorldModelRuntimeError(
                    "child_timeout", "world-model process exceeded its wall timeout"
                )
            stdout_handle.flush()
            stderr_handle.flush()
            if (
                stdout_path.stat().st_size > checked_limits.max_output_bytes
                or stderr_path.stat().st_size > checked_limits.max_output_bytes
            ):
                raise ArcWorldModelRuntimeError(
                    "output_oversize", "world-model process exceeded its output limit"
                )
            stdout_handle.seek(0)
            stderr_handle.seek(0)
            stdout = stdout_handle.read(checked_limits.max_output_bytes + 1)
            stderr = stderr_handle.read(checked_limits.max_output_bytes + 1)
        if stderr:
            raise ArcWorldModelRuntimeError(
                "child_noise", "world-model process wrote to stderr"
            )
        if process.returncode != 0 and not stdout:
            raise ArcWorldModelRuntimeError(
                "child_failed",
                "isolated world model exited with status %d" % process.returncode,
            )
        envelope = _parse_exact_json(
            stdout, checked_limits.max_output_bytes, "child stdout"
        )
        if process.returncode != 0:
            detail = "isolated world model exited with status %d" % process.returncode
            if isinstance(envelope, dict) and isinstance(envelope.get("error"), dict):
                error = envelope["error"]
                detail = "%s: %s" % (
                    str(error.get("code", "child_error"))[:80],
                    str(error.get("message", "isolated model rejected"))[:500],
                )
            raise ArcWorldModelRuntimeError("child_failed", detail)
        root = _strict_object(
            envelope,
            {
                "ok",
                "operation",
                "request_sha256",
                "result",
                "schema",
                "source_sha256",
            },
            "child_envelope",
        )
        if (
            root["schema"] != ARC_WORLD_MODEL_RUNTIME_SCHEMA
            or root["ok"] is not True
            or root["operation"] != request["operation"]
            or root["request_sha256"] != request_sha256
            or root["source_sha256"] != digest
            or not isinstance(root["result"], dict)
        ):
            raise ArcWorldModelRuntimeError(
                "invalid_child_output", "child response identity does not match request"
            )
        return dict(root["result"])


def _trusted_sha256(value: object) -> str:
    return hashlib.sha256(_canonical_json_bytes(value)).hexdigest()


def _canonical_trace_value(value: object, label: str) -> object:
    try:
        encoded = _canonical_json_bytes(value)
        return json.loads(encoded.decode("utf-8"))
    except (ArcWorldModelRuntimeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "%s is not canonical JSON: %s" % (label, exc)
        )


def _trace_frame(value: object, label: str) -> Tuple[Tuple[int, ...], ...]:
    if not isinstance(value, list) or not 1 <= len(value) <= 64:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "%s must have 1-64 rows" % label
        )
    rows = []
    width = None
    for row in value:
        if not isinstance(row, list) or not 1 <= len(row) <= 64:
            raise ArcWorldModelRuntimeError(
                "invalid_child_output", "%s rows must have 1-64 cells" % label
            )
        if width is None:
            width = len(row)
        elif len(row) != width:
            raise ArcWorldModelRuntimeError(
                "invalid_child_output", "%s must be rectangular" % label
            )
        if any(type(cell) is not int for cell in row):
            raise ArcWorldModelRuntimeError(
                "invalid_child_output", "%s cells must be integers" % label
            )
        rows.append(tuple(row))
    return tuple(rows)


def _snapshot_from_trace(
    value: object, label: str
) -> Tuple[ArcStateSnapshot, Tuple[Tuple[int, ...], ...]]:
    payload = _strict_object(value, {"frame", "outcome", "state"}, label)
    state = _canonical_trace_value(payload["state"], "%s state" % label)
    frame = _trace_frame(payload["frame"], "%s frame" % label)
    try:
        outcome = ArcWorldOutcome.from_dict(payload["outcome"])
    except ArcWorldModelContractError as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "%s outcome is invalid: %s" % (label, exc)
        )
    snapshot = ArcStateSnapshot(
        state_sha256=_trusted_sha256(state),
        frame_sha256=frame_sha256(frame),
        frame_height=len(frame),
        frame_width=len(frame[0]),
        outcome=outcome,
    )
    snapshot.validate()
    return snapshot, frame


def _model_identity_from_trace(value: object, source_sha256: str) -> ArcModelIdentity:
    payload = _strict_object(
        value, {"manifest", "model_id", "model_revision"}, "trace model"
    )
    manifest = _canonical_trace_value(payload["manifest"], "trace model manifest")
    if not isinstance(manifest, dict):
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "trace model manifest must be an object"
        )
    manifest_sha256 = _trusted_sha256(
        {
            "runtime_schema": ARC_WORLD_MODEL_RUNTIME_SCHEMA,
            "source_sha256": source_sha256,
            "world_model": manifest,
        }
    )
    identity_material = {
        "implementation_sha256": source_sha256,
        "manifest_sha256": manifest_sha256,
        "model_id": payload["model_id"],
        "model_revision": payload["model_revision"],
    }
    identity = ArcModelIdentity(
        model_id=payload["model_id"],
        model_revision=payload["model_revision"],
        manifest_sha256=manifest_sha256,
        implementation_sha256=source_sha256,
        fingerprint_sha256=_trusted_sha256(identity_material),
    )
    try:
        identity.validate()
    except ArcWorldModelContractError as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "trace model identity is invalid: %s" % exc
        )
    return identity


def _plan_from_trace(
    trace: object,
    source_sha256: str,
    initial_observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
) -> ValidatedArcPlan:
    payload = _strict_object(trace, {"initial", "model", "steps"}, "trace")
    identity = _model_identity_from_trace(payload["model"], source_sha256)
    initial, initial_frame = _snapshot_from_trace(payload["initial"], "trace initial")
    observed_frame = tuple(tuple(row) for row in initial_observation.frame)
    if initial_frame != observed_frame:
        raise ArcWorldModelRuntimeError(
            "initial_model_observation_drift",
            "trace initial frame differs from the complete observation",
        )
    if (
        initial.outcome.state != initial_observation.state
        or initial.outcome.levels_completed != initial_observation.levels_completed
    ):
        raise ArcWorldModelRuntimeError(
            "initial_outcome_drift",
            "trace initial outcome differs from the observation",
        )
    steps = payload["steps"]
    if not isinstance(steps, list) or len(steps) != len(actions):
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "trace must contain exactly one step per action"
        )
    if actions[0].name not in initial_observation.available:
        raise ArcWorldModelRuntimeError(
            "unavailable_initial_action",
            "the first planned action is not currently available",
        )
    predictions = []
    prior = initial
    for index, (raw_step, action) in enumerate(zip(steps, actions), 1):
        step = _strict_object(raw_step, {"action", "result"}, "trace step")
        action_payload = _action_payload(action)
        trace_action = _action_from_payload(step["action"])
        if _action_payload(trace_action) != action_payload:
            raise ArcWorldModelRuntimeError(
                "invalid_child_output", "trace action sequence differs from the request"
            )
        if prior.outcome.terminal:
            raise ArcWorldModelRuntimeError(
                "plan_crosses_terminal_outcome",
                "trace contains an action after a terminal outcome",
            )
        if action.name == "ACTION6" and (
            action.x >= prior.frame_width or action.y >= prior.frame_height
        ):
            raise ArcWorldModelRuntimeError(
                "next_action_out_of_frame",
                "ACTION6 coordinate is outside the complete prior frame",
            )
        result, _frame = _snapshot_from_trace(
            step["result"], "trace step %d result" % index
        )
        predictions.append(
            ArcStepPrediction(
                index=index,
                action=action_payload,
                source_state_sha256=prior.state_sha256,
                result=result,
            )
        )
        prior = result
    unsigned = {
        "initial": initial.as_dict(),
        "initial_observation_sha256": observation_sha256(initial_observation),
        "model": identity.as_dict(),
        "predictions": [item.as_dict() for item in predictions],
        "schema": ARC_VALIDATED_PLAN_SCHEMA,
    }
    plan = ValidatedArcPlan(
        model=identity,
        initial_observation_sha256=unsigned["initial_observation_sha256"],
        initial=initial,
        predictions=tuple(predictions),
        artifact_sha256=_trusted_sha256(unsigned),
    )
    try:
        plan.validate_integrity()
    except ArcWorldModelContractError as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_child_output", "trace produced an invalid plan: %s" % exc
        )
    return plan


def _run_trace(
    request: Mapping[str, object],
    source: Union[bytes, bytearray, memoryview, str, os.PathLike],
    source_sha256: str,
    workspace: Union[str, os.PathLike],
    authoritative_state_dir: Union[str, os.PathLike],
    limits: Optional[ArcWorldModelRuntimeLimits],
    require_macos_sandbox: bool,
    sandbox_executable: Union[str, os.PathLike],
) -> object:
    result = _run_child(
        request,
        source,
        source_sha256,
        workspace,
        authoritative_state_dir,
        limits,
        require_macos_sandbox,
        sandbox_executable,
    )
    payload = _strict_object(result, {"trace"}, "trace result")
    return payload["trace"]


def build_validated_plan_isolated(
    source: Union[bytes, bytearray, memoryview, str, os.PathLike],
    source_sha256: str,
    initial_observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
    *,
    workspace: Union[str, os.PathLike],
    authoritative_state_dir: Union[str, os.PathLike],
    limits: Optional[ArcWorldModelRuntimeLimits] = None,
    require_macos_sandbox: bool = False,
    sandbox_executable: Union[str, os.PathLike] = "/usr/bin/sandbox-exec",
) -> ValidatedArcPlan:
    """Build a plan from two fresh child traces, entirely in the trusted parent."""

    if not isinstance(actions, (list, tuple)) or not 1 <= len(actions) <= 128:
        raise ArcWorldModelRuntimeError(
            "invalid_action_history", "actions must contain 1-128 values"
        )
    normalized_actions = tuple(
        _action_from_payload(_action_payload(item)) for item in actions
    )
    request = {
        "actions": [_action_payload(item) for item in normalized_actions],
        "initial_observation": _observation_payload(initial_observation),
        "operation": "trace",
    }
    first = _run_trace(
        request,
        source,
        source_sha256,
        workspace,
        authoritative_state_dir,
        limits,
        require_macos_sandbox,
        sandbox_executable,
    )
    second = _run_trace(
        request,
        source,
        source_sha256,
        workspace,
        authoritative_state_dir,
        limits,
        require_macos_sandbox,
        sandbox_executable,
    )
    if _canonical_json_bytes(first) != _canonical_json_bytes(second):
        raise ArcWorldModelRuntimeError(
            "nondeterministic_replay",
            "fresh world-model processes returned different complete traces",
        )
    return _plan_from_trace(
        first, _validate_sha256(source_sha256), initial_observation, normalized_actions
    )


def validate_next_action_isolated(
    source: Union[bytes, bytearray, memoryview, str, os.PathLike],
    source_sha256: str,
    plan: ValidatedArcPlan,
    observations: Sequence[ArcObservation],
    executed_actions: Sequence[PlannedArcAction],
    proposed_action: Optional[PlannedArcAction] = None,
    *,
    workspace: Union[str, os.PathLike],
    authoritative_state_dir: Union[str, os.PathLike],
    limits: Optional[ArcWorldModelRuntimeLimits] = None,
    require_macos_sandbox: bool = False,
    sandbox_executable: Union[str, os.PathLike] = "/usr/bin/sandbox-exec",
) -> ValidatedArcNextAction:
    """Rebuild in fresh children; the trusted parent alone releases one action."""

    if not isinstance(plan, ValidatedArcPlan):
        raise ArcWorldModelRuntimeError("invalid_plan", "plan must be ValidatedArcPlan")
    try:
        plan.validate_integrity()
    except ArcWorldModelContractError as exc:
        raise ArcWorldModelRuntimeError("invalid_plan", str(exc))
    if (
        not isinstance(observations, (list, tuple))
        or not observations
        or not isinstance(executed_actions, (list, tuple))
    ):
        raise ArcWorldModelRuntimeError(
            "invalid_history", "observation and action histories must be sequences"
        )
    actions = tuple(_action_from_payload(dict(item.action)) for item in plan.predictions)
    rebuilt = build_validated_plan_isolated(
        source,
        source_sha256,
        observations[0],
        actions,
        workspace=workspace,
        authoritative_state_dir=authoritative_state_dir,
        limits=limits,
        require_macos_sandbox=require_macos_sandbox,
        sandbox_executable=sandbox_executable,
    )
    if rebuilt != plan:
        raise ArcWorldModelRuntimeError(
            "model_drift", "fresh complete traces differ from the sealed plan"
        )
    try:
        return validate_next_action_from_plan(
            plan,
            observations,
            executed_actions,
            proposed_action=proposed_action,
        )
    except (ArcWorldModelContractError, ArcPlanInvalidated, ArcPlanComplete) as exc:
        raise ArcWorldModelRuntimeError(
            str(getattr(exc, "code", "plan_invalidated")), str(exc)
        )


def _count_world_model_exports(tree: ast.Module) -> int:
    count = 0
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = list(node.targets)
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        for target in targets:
            for candidate in ast.walk(target):
                if isinstance(candidate, ast.Name) and candidate.id == "WORLD_MODEL":
                    count += 1
    return count


def _load_verified_world_model(
    source_path: str, expected_sha256: str, max_source_bytes: int
) -> object:
    path = Path(source_path)
    try:
        resolved = path.resolve(strict=True)
        workspace = Path.cwd().resolve(strict=True)
    except OSError as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_source", "staged source cannot be resolved: %s" % exc
        )
    if not _path_is_within(resolved, workspace) or path.is_symlink():
        raise ArcWorldModelRuntimeError(
            "invalid_source", "staged source must be a non-symbolic workspace file"
        )
    descriptor = os.open(
        str(resolved), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
            raise ArcWorldModelRuntimeError(
                "invalid_source", "staged source is not a regular file"
            )
        if metadata.st_size > max_source_bytes:
            raise ArcWorldModelRuntimeError(
                "source_oversize", "staged source exceeds the authenticated limit"
            )
        data = b""
        while len(data) <= max_source_bytes:
            chunk = os.read(descriptor, min(65536, max_source_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(descriptor)
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ArcWorldModelRuntimeError(
            "source_hash_mismatch", "staged source digest does not match request"
        )
    try:
        tree = ast.parse(data, filename=str(resolved), mode="exec")
    except (SyntaxError, ValueError) as exc:
        raise ArcWorldModelRuntimeError(
            "invalid_source", "world-model source does not parse: %s" % exc
        )
    if _count_world_model_exports(tree) != 1:
        raise ArcWorldModelRuntimeError(
            "invalid_world_model_export",
            "source must assign exactly one module-level WORLD_MODEL",
        )
    module_name = "_blacklabel_arc_world_model_%s" % expected_sha256
    module = types.ModuleType(module_name)
    module.__file__ = str(resolved)
    module.__package__ = ""
    module.__loader__ = None
    module.__spec__ = None
    sys.modules[module_name] = module
    try:
        code = compile(tree, str(resolved), "exec", dont_inherit=True, optimize=0)
        exec(code, module.__dict__, module.__dict__)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    if "WORLD_MODEL" not in module.__dict__:
        raise ArcWorldModelRuntimeError(
            "invalid_world_model_export", "WORLD_MODEL was not exported"
        )
    exported = module.__dict__.get("__all__")
    if exported is not None and exported != ["WORLD_MODEL"] and exported != (
        "WORLD_MODEL",
    ):
        raise ArcWorldModelRuntimeError(
            "invalid_world_model_export", "__all__ must export only WORLD_MODEL"
        )
    return module.__dict__["WORLD_MODEL"]


def _child_request(data: bytes) -> Dict[str, object]:
    value = _parse_exact_json(data, _ABSOLUTE_MAX_REQUEST_BYTES, "child request")
    payload = _strict_object(
        value,
        {
            "actions",
            "initial_observation",
            "limits",
            "operation",
            "schema",
            "source_path",
            "source_sha256",
        },
        "request",
    )
    if payload["operation"] != "trace":
        raise ArcWorldModelRuntimeError(
            "invalid_operation", "runtime operation is unsupported"
        )
    if payload["schema"] != ARC_WORLD_MODEL_RUNTIME_SCHEMA:
        raise ArcWorldModelRuntimeError(
            "invalid_request", "runtime request schema is unsupported"
        )
    _validate_sha256(payload["source_sha256"])
    if not isinstance(payload["source_path"], str):
        raise ArcWorldModelRuntimeError(
            "invalid_source", "source_path must be a string"
        )
    if not isinstance(payload["actions"], list):
        raise ArcWorldModelRuntimeError(
            "invalid_request", "actions must be an array"
        )
    ArcWorldModelRuntimeLimits.from_payload(payload["limits"])
    return payload


def _child_snapshot(model: object, state: object) -> Dict[str, object]:
    try:
        before = model.canonical_state(state)
    except Exception as exc:
        raise ArcWorldModelContractError(
            "canonical_state_failed", "canonical_state raised: %s" % exc
        )
    try:
        frame = model.render(state)
    except Exception as exc:
        raise ArcWorldModelContractError("render_failed", "render raised: %s" % exc)
    try:
        outcome = model.outcome(state)
    except Exception as exc:
        raise ArcWorldModelContractError(
            "outcome_failed", "outcome raised: %s" % exc
        )
    try:
        after = model.canonical_state(state)
    except Exception as exc:
        raise ArcWorldModelContractError(
            "canonical_state_failed", "canonical_state raised: %s" % exc
        )
    if _canonical_json_bytes(before) != _canonical_json_bytes(after):
        raise ArcWorldModelContractError(
            "impure_model_observer",
            "canonical_state, render, or outcome mutated model state",
        )
    if not isinstance(frame, (list, tuple)):
        raise ArcWorldModelContractError(
            "invalid_frame", "render must return a complete frame"
        )
    rendered = []
    for row in frame:
        if not isinstance(row, (list, tuple)):
            raise ArcWorldModelContractError(
                "invalid_frame", "rendered frame rows must be sequences"
            )
        rendered.append(list(row))
    if not isinstance(outcome, ArcWorldOutcome):
        raise ArcWorldModelContractError(
            "invalid_outcome", "outcome must return ArcWorldOutcome"
        )
    return {"frame": rendered, "outcome": outcome.as_dict(), "state": before}


def _trace_world_model(
    model: object,
    observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
) -> Dict[str, object]:
    required = (
        "model_manifest",
        "canonical_state",
        "init",
        "transition",
        "render",
        "outcome",
    )
    for name in required:
        if not callable(getattr(model, name, None)):
            raise ArcWorldModelContractError(
                "missing_model_operation", "WORLD_MODEL has no callable %s" % name
            )
    model_id = getattr(model, "model_id", None)
    model_revision = getattr(model, "model_revision", None)
    try:
        first_manifest = model.model_manifest()
        second_manifest = model.model_manifest()
    except Exception as exc:
        raise ArcWorldModelContractError(
            "model_manifest_failed", "model_manifest raised: %s" % exc
        )
    if _canonical_json_bytes(first_manifest) != _canonical_json_bytes(second_manifest):
        raise ArcWorldModelContractError(
            "nondeterministic_model_manifest",
            "model_manifest changed between consecutive reads",
        )
    try:
        state = model.init(observation)
    except Exception as exc:
        raise ArcWorldModelContractError("init_failed", "init raised: %s" % exc)
    if state is None:
        raise ArcWorldModelContractError("init_failed", "init returned null state")
    initial = _child_snapshot(model, state)
    steps = []
    for index, action in enumerate(actions, 1):
        try:
            state = model.transition(state, action)
        except Exception as exc:
            raise ArcWorldModelContractError(
                "transition_failed", "transition %d raised: %s" % (index, exc)
            )
        if state is None:
            raise ArcWorldModelContractError(
                "transition_failed", "transition returned null state"
            )
        steps.append(
            {"action": _action_payload(action), "result": _child_snapshot(model, state)}
        )
    return {
        "initial": initial,
        "model": {
            "manifest": first_manifest,
            "model_id": model_id,
            "model_revision": model_revision,
        },
        "steps": steps,
    }


def _child_execute(request: Mapping[str, object]) -> Dict[str, object]:
    payload = _strict_object(
        request,
        {
            "actions",
            "initial_observation",
            "limits",
            "operation",
            "schema",
            "source_path",
            "source_sha256",
        },
        "request",
    )
    if payload["operation"] != "trace":
        raise ArcWorldModelRuntimeError(
            "invalid_operation", "runtime operation is unsupported"
        )
    if payload["schema"] != ARC_WORLD_MODEL_RUNTIME_SCHEMA:
        raise ArcWorldModelRuntimeError(
            "invalid_request", "runtime request schema is unsupported"
        )
    limits = ArcWorldModelRuntimeLimits.from_payload(payload["limits"])
    digest = _validate_sha256(payload["source_sha256"])
    if not isinstance(payload["source_path"], str):
        raise ArcWorldModelRuntimeError(
            "invalid_source", "source_path must be a string"
        )
    if not isinstance(payload["actions"], list):
        raise ArcWorldModelRuntimeError(
            "invalid_request", "actions must be an array"
        )
    actions = tuple(_action_from_payload(item) for item in payload["actions"])
    observation = _observation_from_payload(payload["initial_observation"])
    model = _load_verified_world_model(
        payload["source_path"], digest, limits.max_source_bytes
    )
    return {"trace": _trace_world_model(model, observation, actions)}


def _safe_error(exc: BaseException) -> Dict[str, str]:
    code = getattr(exc, "code", exc.__class__.__name__)
    message = str(exc).replace("\x00", "?").replace("\r", " ").replace("\n", " ")
    return {"code": str(code)[:80], "message": message[:500]}


def _child_main() -> int:
    operation = "unknown"
    digest = "0" * 64
    request_sha256 = "0" * 64
    try:
        data = sys.stdin.buffer.read(_ABSOLUTE_MAX_REQUEST_BYTES + 1)
        request = _child_request(data)
        request_sha256 = hashlib.sha256(data).hexdigest()
        operation = str(request.get("operation", "unknown"))
        digest = str(request.get("source_sha256", digest))
        limits = ArcWorldModelRuntimeLimits.from_payload(request.get("limits"))
        if len(data) > limits.max_request_bytes:
            raise ArcWorldModelRuntimeError(
                "request_oversize", "child request exceeds the authenticated limit"
            )
        _apply_resource_limits(limits)
        result = _child_execute(request)
        envelope = {
            "ok": True,
            "operation": operation,
            "request_sha256": request_sha256,
            "result": result,
            "schema": ARC_WORLD_MODEL_RUNTIME_SCHEMA,
            "source_sha256": digest,
        }
        sys.stdout.buffer.write(_canonical_json_bytes(envelope))
        sys.stdout.buffer.flush()
        return 0
    except BaseException as exc:
        envelope = {
            "error": _safe_error(exc),
            "ok": False,
            "operation": operation,
            "request_sha256": request_sha256,
            "schema": ARC_WORLD_MODEL_RUNTIME_SCHEMA,
            "source_sha256": digest,
        }
        try:
            sys.stdout.buffer.write(_canonical_json_bytes(envelope))
            sys.stdout.buffer.flush()
        except BaseException:
            pass
        return 70


__all__ = [
    "ARC_WORLD_MODEL_RUNTIME_SCHEMA",
    "ArcWorldModelRuntimeError",
    "ArcWorldModelRuntimeLimits",
    "build_macos_sandbox_profile",
    "build_validated_plan_isolated",
    "validate_next_action_isolated",
]
