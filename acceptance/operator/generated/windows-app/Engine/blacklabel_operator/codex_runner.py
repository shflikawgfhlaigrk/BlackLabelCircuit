import ctypes
import errno
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import stat
import sys
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path

from .settings import should_start_new_session


MAX_CODEX_THREAD_ID_BYTES = 1024
MAX_CODEX_USAGE_TOKENS = 1_000_000_000


def _reject_duplicate_json_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON object key: %s" % key)
        value[key] = item
    return value


def _reject_json_constant(value):
    raise ValueError("invalid JSON constant: %s" % value)


def _strict_json_event(line):
    try:
        return json.loads(
            line,
            object_pairs_hook=_reject_duplicate_json_keys,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, ValueError) as exc:
        return {
            "type": "runner.invalid_json",
            "message": "Codex emitted invalid JSON event: %s" % exc,
            "line": str(line)[:4000],
        }


class _DarwinProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("open_files", ctypes.c_uint32),
        ("process_group", ctypes.c_uint32),
        ("job_control", ctypes.c_uint32),
        ("tty_device", ctypes.c_uint32),
        ("tty_group", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("started_seconds", ctypes.c_uint64),
        ("started_microseconds", ctypes.c_uint64),
    ]


@dataclass
class RunResult:
    success: bool
    exit_code: object = None
    final_text: str = ""
    error: object = None
    thread_id: object = None
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0
    timed_out: bool = False
    cancelled: bool = False
    pid: object = None
    process_may_be_alive: bool = False
    termination_confirmed: bool = True
    termination_detail: object = None
    leaked_descendants: bool = False
    usage_reported: bool = True
    containment_proven: bool = False
    containment_manifest: object = None

    def as_dict(self):
        return asdict(self)


@dataclass
class SupervisedProcessResult:
    returncode: object
    stdout: str
    stderr: str
    timed_out: bool = False
    cancelled: bool = False
    pid: object = None
    termination_confirmed: bool = True
    termination_detail: object = None
    leaked_descendants: bool = False
    containment_proven: bool = False
    containment_manifest: object = None


class UnconfirmedTerminationError(RuntimeError):
    def __init__(self, pid, detail):
        self.pid = pid
        self.detail = detail
        super().__init__(
            "process %s termination was not confirmed: %s" % (pid, detail)
        )


class EventAccumulator:
    def __init__(self):
        self.thread_id = None
        self.final_text = ""
        self.input_tokens = 0
        self.cached_input_tokens = 0
        self.output_tokens = 0
        self.usage_reported = False
        self.completed = False
        self.failure = None
        self._terminal_event = None

    def _fail(self, message, terminal=None):
        if self.failure is None:
            self.failure = str(message)
        if terminal is not None and self._terminal_event is None:
            self._terminal_event = terminal

    @staticmethod
    def _valid_thread_id(value):
        if not (
            type(value) is str
            and value
            and value == value.strip()
            and len(value.encode("utf-8")) <= MAX_CODEX_THREAD_ID_BYTES
            and not any(
                ord(character) < 32 or ord(character) == 127
                for character in value
            )
        ):
            return False
        try:
            return str(uuid.UUID(value)) == value
        except (AttributeError, TypeError, ValueError):
            return False

    @staticmethod
    def _failure_message(event):
        for field_name in ("message", "error"):
            value = event.get(field_name)
            if isinstance(value, str) and value.strip():
                return value
        return json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=True)

    def _complete(self, usage):
        if type(usage) is not dict:
            self._fail(
                "Codex emitted malformed turn.completed usage metadata",
                terminal="turn.completed",
            )
            return
        parsed = {}
        for field_name in ("input_tokens", "output_tokens"):
            if field_name not in usage:
                self._fail(
                    "Codex turn.completed usage is missing %s" % field_name,
                    terminal="turn.completed",
                )
                return
            value = usage[field_name]
            if (
                type(value) is not int
                or value < 0
                or value > MAX_CODEX_USAGE_TOKENS
            ):
                self._fail(
                    "Codex emitted malformed turn.completed usage metadata",
                    terminal="turn.completed",
                )
                return
            parsed[field_name] = value
        cached = usage.get("cached_input_tokens", 0)
        if (
            type(cached) is not int
            or cached < 0
            or cached > MAX_CODEX_USAGE_TOKENS
        ):
            self._fail(
                "Codex emitted malformed turn.completed usage metadata",
                terminal="turn.completed",
            )
            return
        self.input_tokens = parsed["input_tokens"]
        self.cached_input_tokens = cached
        self.output_tokens = parsed["output_tokens"]
        self.usage_reported = True
        self.completed = True
        self._terminal_event = "turn.completed"

    def add(self, event):
        if type(event) is not dict:
            self._fail("Codex emitted a non-object event", terminal="invalid event")
            return
        event_type = event.get("type")
        if not isinstance(event_type, str) or not event_type:
            self._fail("Codex emitted an event without a valid type", terminal="invalid event")
            return
        if self._terminal_event is not None:
            if event_type == "turn.completed" and self._terminal_event == "turn.completed":
                self._fail("Codex emitted duplicate turn.completed")
            else:
                self._fail(
                    "Codex emitted %s after terminal %s"
                    % (event_type, self._terminal_event)
                )
            return
        if event_type == "thread.started":
            thread_id = event.get("thread_id")
            if not self._valid_thread_id(thread_id):
                self._fail(
                    "Codex emitted an invalid thread.started identifier",
                    terminal="thread.started",
                )
                return
            if self.thread_id is None:
                self.thread_id = thread_id
            elif thread_id == self.thread_id:
                self._fail(
                    "Codex emitted duplicate thread.started",
                    terminal="thread.started",
                )
            else:
                self._fail(
                    "Codex emitted conflicting thread.started events",
                    terminal="thread.started",
                )
        elif event_type in ("turn.failed", "error"):
            self._fail(self._failure_message(event), terminal=event_type)
        elif event_type == "runner.invalid_json":
            self._fail(
                event.get("message") or "Codex emitted invalid JSON",
                terminal="runner.invalid_json",
            )
        elif self.thread_id is None:
            self._fail(
                "Codex emitted %s before thread.started" % event_type,
                terminal="lifecycle violation",
            )
        elif event_type == "item.completed":
            item = event.get("item")
            if type(item) is not dict:
                self._fail(
                    "Codex emitted malformed item.completed",
                    terminal="item.completed",
                )
                return
            if item.get("type") == "agent_message":
                text = item.get("text")
                if not isinstance(text, str):
                    self._fail(
                        "Codex emitted malformed agent_message text",
                        terminal="item.completed",
                    )
                    return
                if text:
                    self.final_text = text
        elif event_type == "turn.completed":
            self._complete(event.get("usage"))

    def result(
        self,
        exit_code=None,
        error=None,
        timed_out=False,
        cancelled=False,
        pid=None,
        process_may_be_alive=False,
        termination_confirmed=True,
        termination_detail=None,
        leaked_descendants=False,
        containment_proven=False,
        containment_manifest=None,
    ):
        failure = self.failure or error
        exact_zero_exit = type(exit_code) is int and exit_code == 0
        success = bool(
            self.thread_id is not None
            and self.completed
            and self._terminal_event == "turn.completed"
            and exact_zero_exit
            and not failure
            and not timed_out
            and not cancelled
        )
        if not success and not failure:
            if cancelled:
                failure = "task cancelled"
            elif timed_out:
                failure = "task timed out"
            elif not exact_zero_exit:
                failure = (
                    "Codex exit status was not confirmed"
                    if exit_code is None
                    else "Codex exited with status %s" % exit_code
                )
            elif self.thread_id is None:
                failure = "Codex exited without a valid thread.started event"
            else:
                failure = "Codex exited without a completed turn"
        return RunResult(
            success=success,
            exit_code=exit_code,
            final_text=self.final_text,
            error=failure,
            thread_id=self.thread_id,
            input_tokens=self.input_tokens,
            cached_input_tokens=self.cached_input_tokens,
            output_tokens=self.output_tokens,
            timed_out=timed_out,
            cancelled=cancelled,
            pid=pid,
            process_may_be_alive=process_may_be_alive,
            termination_confirmed=termination_confirmed,
            termination_detail=termination_detail,
            leaked_descendants=leaked_descendants,
            usage_reported=self.usage_reported,
            containment_proven=containment_proven,
            containment_manifest=containment_manifest,
        )


class CodexRunner:
    provider_name = "codex"
    capabilities = frozenset(
        {
            "json_stream",
            "resume",
            "sandbox",
            "structured_output",
            "steer",
            "mcp",
        }
    )
    DISABLED_CONFIG = (
        "project_doc_max_bytes=0",
        "skills.include_instructions=false",
        "features.plugins=false",
        "features.skill_search=false",
        "features.memories=false",
        "features.multi_agent=false",
        "features.apps=false",
        "suppress_unstable_features_warning=true",
    )
    POLICY_STAGE_CONFIG = (
        "project_doc_fallback_filenames=[]",
        "features.hooks=false",
        "features.multi_agent_v2=false",
        "features.external_agent_memory_import=false",
    )

    def __init__(self, settings):
        self.settings = settings

    _CONTAINMENT_SCHEMA = "black-label-operator/macos-coalition-v1"
    _LAUNCHD_GATE = r"""
import ctypes
import json
import os
import subprocess
import sys
import time

release_path, environment_path, child_pid_path, exit_path = sys.argv[1:5]
command = sys.argv[5:]
while not os.path.exists(release_path):
    time.sleep(0.02)
with open(environment_path, "r", encoding="utf-8") as handle:
    environment = json.load(handle)
os.unlink(environment_path)
child = subprocess.Popen(command, env=environment)
descriptor = os.open(child_pid_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="ascii") as handle:
    handle.write(str(child.pid) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(child_pid_path, 0o400)
code = child.wait()
descriptor = os.open(exit_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="ascii") as handle:
    handle.write(str(code) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(exit_path, 0o400)
library = ctypes.CDLL(None, use_errno=True)
proc_info = library.proc_pidinfo
proc_info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
proc_info.restype = ctypes.c_int
coalitions = (ctypes.c_uint64 * 5)()
if proc_info(os.getpid(), 20, 0, ctypes.byref(coalitions), ctypes.sizeof(coalitions)) != ctypes.sizeof(coalitions):
    while True:
        time.sleep(60)
pid_list = library.coalition_info_pid_list
pid_list.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
pid_list.restype = ctypes.c_int
while True:
    values = (ctypes.c_int * 65536)()
    byte_count = ctypes.c_size_t(ctypes.sizeof(values))
    if pid_list(coalitions[0], ctypes.cast(values, ctypes.c_void_p), ctypes.byref(byte_count)) != 0:
        time.sleep(1)
        continue
    members = values[:byte_count.value // ctypes.sizeof(ctypes.c_int)]
    if not [value for value in members if value and value != os.getpid()]:
        break
    time.sleep(0.05)
raise SystemExit(code if 0 <= code <= 255 else 1)
""".strip()

    @staticmethod
    def _exclusive_bytes(path, payload, mode=0o600):
        path = Path(path)
        descriptor = os.open(
            str(path),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            mode,
        )
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except Exception:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            raise
        return path

    @classmethod
    def exact_containment_available(cls):
        """Return whether the exact macOS coalition APIs are callable."""
        if sys.platform != "darwin" or not Path("/bin/launchctl").is_file():
            return False
        try:
            library = ctypes.CDLL(None, use_errno=True)
            getattr(library, "proc_pidinfo")
            getattr(library, "coalition_info_pid_list")
        except (AttributeError, OSError):
            return False
        return True

    @staticmethod
    def _launchctl(*arguments):
        try:
            return subprocess.run(
                ["/bin/launchctl", *arguments],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return type(
                "LaunchctlFailure",
                (),
                {"returncode": 127, "stdout": "%s: %s" % (type(exc).__name__, exc)},
            )()

    @classmethod
    def _launchd_info(cls, domain, label):
        completed = cls._launchctl("print", "%s/%s" % (domain, label))
        if completed.returncode != 0:
            return {
                "loaded": False,
                "running": False,
                "pid": None,
                "exit_code": None,
                "detail": completed.stdout.strip(),
            }
        output = completed.stdout
        state_match = re.search(r"^\s*state\s*=\s*(.+?)\s*$", output, re.M)
        pid_match = re.search(r"^\s*pid\s*=\s*(\d+)\s*$", output, re.M)
        exit_match = re.search(
            r"^\s*last exit code\s*=\s*(-?\d+)\s*$", output, re.M
        )
        state = state_match.group(1).strip() if state_match else "unknown"
        return {
            "loaded": True,
            "running": state == "running",
            "pid": int(pid_match.group(1)) if pid_match else None,
            "exit_code": int(exit_match.group(1)) if exit_match else None,
            "detail": state,
        }

    @staticmethod
    def _process_coalitions(pid):
        library = ctypes.CDLL(None, use_errno=True)
        function = library.proc_pidinfo
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        function.restype = ctypes.c_int
        values = (ctypes.c_uint64 * 5)()
        ctypes.set_errno(0)
        written = function(
            int(pid),
            20,  # PROC_PIDCOALITIONINFO
            0,
            ctypes.byref(values),
            ctypes.sizeof(values),
        )
        if written != ctypes.sizeof(values):
            number = ctypes.get_errno() or errno.ESRCH
            raise OSError(number, "proc_pidinfo(PROC_PIDCOALITIONINFO) failed")
        return int(values[0]), int(values[1])

    @staticmethod
    def _coalition_members(coalition_id):
        """Return an exact resource-coalition PID snapshot.

        The kernel call silently truncates a full buffer. Grow until one call
        leaves spare capacity; only that snapshot is accepted as complete.
        """
        library = ctypes.CDLL(None, use_errno=True)
        function = library.coalition_info_pid_list
        function.argtypes = [
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_size_t),
        ]
        function.restype = ctypes.c_int
        capacity = 16
        while capacity <= 65536:
            values = (ctypes.c_int * capacity)()
            byte_count = ctypes.c_size_t(ctypes.sizeof(values))
            ctypes.set_errno(0)
            result = function(
                int(coalition_id),
                ctypes.cast(values, ctypes.c_void_p),
                ctypes.byref(byte_count),
            )
            if result != 0:
                number = ctypes.get_errno() or errno.EIO
                if number == errno.ESRCH:
                    return [], True
                raise OSError(number, "coalition_info_pid_list failed")
            if byte_count.value % ctypes.sizeof(ctypes.c_int):
                raise OSError(errno.EIO, "coalition PID list has invalid size")
            count = byte_count.value // ctypes.sizeof(ctypes.c_int)
            if count < capacity:
                return sorted(set(int(value) for value in values[:count] if value)), False
            capacity *= 2
        raise OSError(errno.EOVERFLOW, "coalition PID list exceeds hard limit")

    @classmethod
    def _write_containment_manifest(cls, path, payload):
        encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        cls._exclusive_bytes(path, encoded)
        Path(path).chmod(0o400)
        return str(Path(path).resolve())

    @classmethod
    def containment_binding(cls, path, tasks_root=None):
        raw = Path(path).expanduser()
        if raw.is_symlink():
            raise ValueError("containment manifest is a symlink")
        resolved = raw.resolve()
        if tasks_root is not None:
            trusted_root = Path(tasks_root).expanduser().resolve()
            if trusted_root not in resolved.parents:
                raise ValueError("containment manifest is outside task storage")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(str(resolved), flags)
        except OSError as exc:
            raise ValueError("containment manifest is missing") from exc
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or stat.S_IMODE(opened.st_mode) != 0o400
                or opened.st_size > 64 * 1024
            ):
                raise ValueError("containment manifest is not immutable")
            chunks = []
            remaining = 64 * 1024 + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(16384, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > 64 * 1024:
                raise ValueError("containment manifest exceeds size limit")
            finished = os.fstat(descriptor)
            current = resolved.stat()
            opened_identity = (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
                stat.S_IMODE(opened.st_mode),
            )
            if opened_identity != (
                finished.st_dev,
                finished.st_ino,
                finished.st_size,
                finished.st_mtime_ns,
                finished.st_ctime_ns,
                stat.S_IMODE(finished.st_mode),
            ) or opened_identity != (
                current.st_dev,
                current.st_ino,
                current.st_size,
                current.st_mtime_ns,
                current.st_ctime_ns,
                stat.S_IMODE(current.st_mode),
            ):
                raise ValueError("containment manifest changed while reading")
        finally:
            os.close(descriptor)
        payload = json.loads(data.decode("utf-8"))
        if (
            payload.get("schema") != cls._CONTAINMENT_SCHEMA
            or not payload.get("label")
            or not payload.get("domain")
            or int(payload.get("resource_coalition_id") or 0) <= 0
            or int(payload.get("pid") or 0) <= 0
            or not payload.get("process_identity")
        ):
            raise ValueError("containment manifest is malformed")
        return {
            "path": str(resolved),
            "sha256": hashlib.sha256(data).hexdigest(),
            "device": int(opened.st_dev),
            "inode": int(opened.st_ino),
            "bytes": len(data),
            "mode": stat.S_IMODE(opened.st_mode),
            "mtime_ns": int(opened.st_mtime_ns),
            "ctime_ns": int(opened.st_ctime_ns),
            "label": str(payload["label"]),
            "domain": str(payload["domain"]),
            "pid": int(payload["pid"]),
            "process_identity": str(payload["process_identity"]),
            "resource_coalition_id": int(payload["resource_coalition_id"]),
            "jetsam_coalition_id": int(payload.get("jetsam_coalition_id") or 0),
            "payload": payload,
        }

    @classmethod
    def _read_containment_manifest(
        cls, path, tasks_root=None, expected_binding=None
    ):
        binding = cls.containment_binding(path, tasks_root=tasks_root)
        expected = dict(expected_binding or {})
        for field in (
            "path",
            "sha256",
            "device",
            "inode",
            "bytes",
            "mode",
            "mtime_ns",
            "ctime_ns",
            "label",
            "domain",
            "pid",
            "process_identity",
            "resource_coalition_id",
            "jetsam_coalition_id",
        ):
            if field in expected and expected[field] != binding[field]:
                raise ValueError(
                    "containment manifest %s does not match task ledger" % field
                )
        payload = dict(binding["payload"])
        payload["manifest_path"] = binding["path"]
        payload["manifest_sha256"] = binding["sha256"]
        return payload

    @staticmethod
    def _containment_binding_from_metadata(metadata, prefix="active_process"):
        expected = {}
        for field in (
            "path",
            "sha256",
            "device",
            "inode",
            "bytes",
            "mode",
            "mtime_ns",
            "ctime_ns",
            "label",
            "domain",
            "pid",
            "process_identity",
            "resource_coalition_id",
            "jetsam_coalition_id",
        ):
            value = dict(metadata or {}).get("%s_containment_%s" % (prefix, field))
            if value is not None:
                expected[field] = value
        required = {
            "path",
            "sha256",
            "device",
            "inode",
            "bytes",
            "mode",
            "mtime_ns",
            "ctime_ns",
            "label",
            "domain",
            "pid",
            "process_identity",
            "resource_coalition_id",
        }
        if not required.issubset(expected):
            raise ValueError("containment binding is missing from task metadata")
        return expected

    @staticmethod
    def _contained_exit_code(job):
        path = Path(job["exit_path"]).expanduser()
        if path.is_symlink() or not path.is_file():
            return None
        try:
            return int(path.read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            return None

    @classmethod
    def _bootout_containment(cls, job):
        target = "%s/%s" % (job["domain"], job["label"])
        completed = cls._launchctl("bootout", target)
        for _attempt in range(20):
            if not cls._launchd_info(job["domain"], job["label"])["loaded"]:
                return True, completed.stdout.strip() or "launchd job unloaded"
            time.sleep(0.05)
        return False, completed.stdout.strip() or "launchd job remained loaded"

    @classmethod
    def _terminate_coalition(cls, job, members):
        expected = {}
        for candidate in members:
            identity = cls.process_identity(candidate)
            if identity is not None:
                expected[int(candidate)] = identity
        root = int(job.get("pid") or 0)
        if root not in expected and expected:
            root = next(iter(expected))
        if expected:
            cls.safe_terminate(
                root,
                extra_targets=sorted(expected),
                expected_identities=expected,
            )
        deadline = time.monotonic() + 10
        last = list(members)
        while time.monotonic() < deadline:
            try:
                last, gone = cls._coalition_members(job["resource_coalition_id"])
            except OSError as exc:
                return False, "coalition recheck failed: %s" % exc
            if gone or not last:
                return True, "coalition has no live members"
            time.sleep(0.05)
        return False, "live coalition members remain: %s" % sorted(last)

    @classmethod
    def terminate_bound_containment(
        cls, path, expected_binding, *, tasks_root=None
    ):
        """Terminate and unload one ledger-bound containment job exactly."""
        try:
            job = cls._read_containment_manifest(
                path,
                tasks_root=tasks_root,
                expected_binding=expected_binding,
            )
            members, _gone = cls._coalition_members(
                job["resource_coalition_id"]
            )
        except Exception as exc:
            return False, "containment binding/query failed: %s" % exc
        if members:
            confirmed, detail = cls._terminate_coalition(job, members)
            if not confirmed:
                return False, detail
        unloaded, detail = cls._bootout_containment(job)
        if not unloaded:
            return False, detail
        try:
            final_members, _gone = cls._coalition_members(
                job["resource_coalition_id"]
            )
        except OSError as exc:
            return False, "final coalition query failed: %s" % exc
        if final_members:
            return False, "live coalition members remain: %s" % final_members
        return True, detail or "contained process termination confirmed"

    @classmethod
    def _start_contained_job(
        cls,
        command,
        *,
        cwd,
        input_text,
        env,
        containment_dir,
        stdout_path,
        stderr_path,
        heartbeat=None,
    ):
        if not cls.exact_containment_available():
            raise RuntimeError("exact macOS process containment is unavailable")
        directory = Path(containment_dir).expanduser().resolve()
        directory.mkdir(parents=True, exist_ok=False, mode=0o700)
        directory.chmod(0o700)
        executable = str(command[0])
        if not Path(executable).is_absolute():
            executable = shutil.which(executable, path=dict(env).get("PATH"))
        if not executable:
            raise RuntimeError("contained executable could not be resolved")
        argv = [str(Path(executable).expanduser().resolve())]
        argv.extend(str(value) for value in command[1:])
        stdin_path = directory / "stdin.data"
        environment_path = directory / "environment.json"
        release_path = directory / "release"
        child_pid_path = directory / "child.pid"
        exit_path = directory / "exit.status"
        plist_path = directory / "job.plist"
        manifest_path = directory / "containment.json"
        output_path = Path(stdout_path).expanduser().resolve()
        error_path = Path(stderr_path).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        error_path.parent.mkdir(parents=True, exist_ok=True)
        cls._exclusive_bytes(
            stdin_path,
            (input_text or "").encode("utf-8", errors="surrogateescape"),
            mode=0o400,
        )
        cls._exclusive_bytes(
            environment_path,
            json.dumps(
                {str(key): str(value) for key, value in dict(env).items()},
                sort_keys=True,
            ).encode("utf-8"),
            mode=0o600,
        )
        label = "com.blacklabel.operator.containment.%s" % uuid.uuid4().hex
        domain = "gui/%d" % os.getuid()
        gate_argv = [
            str(Path(sys.executable).resolve()),
            "-c",
            cls._LAUNCHD_GATE,
            str(release_path),
            str(environment_path),
            str(child_pid_path),
            str(exit_path),
            *argv,
        ]
        plist = {
            "Label": label,
            "ProgramArguments": gate_argv,
            "WorkingDirectory": str(Path(cwd).expanduser().resolve()),
            "RunAtLoad": True,
            "KeepAlive": False,
            "AbandonProcessGroup": False,
            "ExitTimeOut": 1,
            "StandardInPath": str(stdin_path),
            "StandardOutPath": str(output_path),
            "StandardErrorPath": str(error_path),
        }
        cls._exclusive_bytes(plist_path, plistlib.dumps(plist), mode=0o600)
        bootstrapped = False
        pid = None
        try:
            completed = cls._launchctl("bootstrap", domain, str(plist_path))
            if completed.returncode != 0:
                raise RuntimeError(
                    "launchd bootstrap failed: %s" % completed.stdout.strip()
                )
            bootstrapped = True
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                info = cls._launchd_info(domain, label)
                pid = info.get("pid")
                if info.get("loaded") and info.get("running") and pid:
                    break
                if heartbeat:
                    heartbeat()
                time.sleep(0.05)
            if not pid:
                raise RuntimeError("launchd containment gate did not start")
            stable_identity = None
            stable_samples = 0
            identity_deadline = time.monotonic() + 5
            while time.monotonic() < identity_deadline:
                current_identity = cls.process_identity(pid)
                if current_identity and current_identity == stable_identity:
                    stable_samples += 1
                else:
                    stable_identity = current_identity
                    stable_samples = 1 if current_identity else 0
                if stable_samples >= 3:
                    break
                time.sleep(0.02)
            if not stable_identity or stable_samples < 3:
                raise RuntimeError(
                    "launchd containment gate identity did not stabilize"
                )
            resource_id, jetsam_id = cls._process_coalitions(pid)
            job = {
                "schema": cls._CONTAINMENT_SCHEMA,
                "label": label,
                "domain": domain,
                "pid": int(pid),
                "process_identity": stable_identity,
                "resource_coalition_id": int(resource_id),
                "jetsam_coalition_id": int(jetsam_id),
                "plist_path": str(plist_path),
                "stdout_path": str(output_path),
                "stderr_path": str(error_path),
                "stdin_path": str(stdin_path),
                "environment_path": str(environment_path),
                "release_path": str(release_path),
                "child_pid_path": str(child_pid_path),
                "exit_path": str(exit_path),
            }
            job["manifest_path"] = cls._write_containment_manifest(
                manifest_path, job
            )
            return job
        except Exception:
            detail = "containment setup failed"
            if pid:
                identity = cls.process_identity(pid)
                confirmed, detail = cls.safe_terminate(
                    pid,
                    expected_identities={pid: identity} if identity else None,
                )
                if not confirmed:
                    raise UnconfirmedTerminationError(pid, detail)
            if bootstrapped:
                cls._launchctl("bootout", "%s/%s" % (domain, label))
            raise

    @classmethod
    def _run_exact_contained(
        cls,
        command,
        *,
        cwd,
        input_text,
        timeout,
        heartbeat,
        cancelled,
        poll_seconds,
        env,
        containment_dir,
        stdout_path,
        stderr_path,
        on_start=None,
        tick=None,
    ):
        base = {
            "returncode": None,
            "pid": None,
            "timed_out": False,
            "cancelled": False,
            "termination_confirmed": True,
            "termination_detail": None,
            "leaked_descendants": False,
            "containment_proven": False,
            "containment_manifest": None,
            "callback_error": None,
            "callback_exception": None,
            "stop_reason": None,
        }
        started = time.monotonic()
        try:
            job = cls._start_contained_job(
                command,
                cwd=cwd,
                input_text=input_text,
                env=env,
                containment_dir=containment_dir,
                stdout_path=stdout_path,
                stderr_path=stderr_path,
                heartbeat=heartbeat,
            )
        except UnconfirmedTerminationError as exc:
            base.update(
                {
                    "pid": exc.pid,
                    "termination_confirmed": False,
                    "termination_detail": exc.detail,
                }
            )
            return base
        except Exception as exc:
            base["termination_detail"] = "%s: %s" % (type(exc).__name__, exc)
            return base
        base["pid"] = job["pid"]
        base["containment_manifest"] = job["manifest_path"]
        try:
            if on_start:
                on_start(
                    job["pid"],
                    job["pid"],
                    job["process_identity"],
                )
            cls._exclusive_bytes(Path(job["release_path"]), b"release\n", mode=0o400)
        except Exception as exc:
            base["callback_error"] = "%s: %s" % (type(exc).__name__, exc)
            base["callback_exception"] = exc

        last_heartbeat = 0.0
        info = cls._launchd_info(job["domain"], job["label"])
        while info.get("loaded") and info.get("running"):
            now = time.monotonic()
            try:
                if tick:
                    reason = tick()
                    if reason:
                        base["stop_reason"] = str(reason)
                if heartbeat and now - last_heartbeat >= 5:
                    heartbeat()
                    last_heartbeat = now
                if cancelled and cancelled():
                    base["cancelled"] = True
            except Exception as exc:
                base["callback_error"] = "%s: %s" % (type(exc).__name__, exc)
                base["callback_exception"] = exc
            if now - started >= float(timeout):
                base["timed_out"] = True
            if (
                base["callback_error"]
                or base["cancelled"]
                or base["timed_out"]
                or base["stop_reason"]
            ):
                break
            if Path(job["exit_path"]).is_file():
                break
            time.sleep(max(0.01, min(0.25, float(poll_seconds))))
            info = cls._launchd_info(job["domain"], job["label"])
        if tick:
            try:
                reason = tick()
                if reason and not base["stop_reason"]:
                    base["stop_reason"] = str(reason)
            except Exception as exc:
                base["callback_error"] = "%s: %s" % (type(exc).__name__, exc)
                base["callback_exception"] = exc

        try:
            members, coalition_gone = cls._coalition_members(
                job["resource_coalition_id"]
            )
        except OSError as exc:
            base["termination_confirmed"] = False
            base["termination_detail"] = "coalition query failed: %s" % exc
            return base

        interrupted = bool(
            base["callback_error"]
            or base["cancelled"]
            or base["timed_out"]
            or base["stop_reason"]
        )
        if not interrupted and members:
            # Allow the exited launchd gate a short kernel-reaping interval.
            deadline = time.monotonic() + 1
            while members and time.monotonic() < deadline:
                time.sleep(0.05)
                members, coalition_gone = cls._coalition_members(
                    job["resource_coalition_id"]
                )
            base["leaked_descendants"] = bool(
                [candidate for candidate in members if candidate != job["pid"]]
            )

        if members:
            confirmed, detail = cls._terminate_coalition(job, members)
            base["termination_detail"] = detail
            if not confirmed:
                base["termination_confirmed"] = False
                return base
            members = []

        unloaded, unload_detail = cls._bootout_containment(job)
        if not unloaded:
            base["termination_confirmed"] = False
            base["termination_detail"] = unload_detail
            return base
        try:
            final_members, final_gone = cls._coalition_members(
                job["resource_coalition_id"]
            )
        except OSError as exc:
            base["termination_confirmed"] = False
            base["termination_detail"] = "final coalition query failed: %s" % exc
            return base
        if final_members:
            base["termination_confirmed"] = False
            base["termination_detail"] = "live coalition members remain: %s" % final_members
            return base
        base["termination_confirmed"] = True
        base["containment_proven"] = bool(final_gone or not final_members)
        base["termination_detail"] = base["termination_detail"] or unload_detail
        base["returncode"] = cls._contained_exit_code(job)
        if base["returncode"] is None:
            base["returncode"] = info.get("exit_code")
        return base

    def command(self, task, resume=False):
        effort = task.get("effort") or self.settings.effort
        model = task.get("model") or self.settings.model
        if task.get("profile", "sol").startswith("sol") and model != "gpt-5.6-sol":
            raise ValueError("Sol profiles must remain pinned to gpt-5.6-sol")

        base = [
            str(self.settings.codex_bin),
            "exec",
            "-C",
            task["cwd"],
            "-s",
            task.get("sandbox") or self.settings.sandbox,
        ]
        if resume:
            if not EventAccumulator._valid_thread_id(task.get("thread_id")):
                raise ValueError(
                    "Codex resume requires a lowercase hyphenated canonical UUID"
                )
            base.append("resume")
        base.extend(["--ignore-user-config", "-m", model])
        base.extend(["-c", 'model_reasoning_effort="%s"' % effort])
        metadata = task.get("metadata") or {}
        if metadata.get("disable_customizations", True):
            for item in self.DISABLED_CONFIG:
                base.extend(["-c", item])
        if metadata.get("suppress_project_instructions") is True:
            for item in self.POLICY_STAGE_CONFIG:
                base.extend(["-c", item])
            base.append("--ignore-rules")
        base.extend(["--json", "--skip-git-repo-check"])
        if resume:
            base.extend([task["thread_id"], "-"])
        else:
            base.append("-")
        return base

    @staticmethod
    def resume_requested(task):
        metadata = task.get("metadata") or {}
        return bool(task.get("thread_id")) and (
            int(task.get("attempt") or 1) > 1
            or bool(metadata.get("continue_thread"))
        )

    def _task_paths(self, task):
        generation = max(0, int(task.get("lease_generation") or 0))
        task_dir = (
            self.settings.tasks_dir
            / task["id"]
            / ("generation-%08d" % generation)
            / "provider"
        )
        task_dir.mkdir(parents=True, exist_ok=True)
        return (
            task_dir,
            task_dir / "events.jsonl",
            task_dir / "stderr.log",
        )

    @staticmethod
    def _read_new_events(handle, accumulator, on_event):
        read_any = False
        while True:
            line = handle.readline()
            if not line:
                break
            read_any = True
            line = line.strip()
            if not line:
                continue
            event = _strict_json_event(line)
            accumulator.add(event)
            if on_event:
                on_event(event)
        return read_any

    @staticmethod
    def process_status(pid):
        if not pid:
            return None
        try:
            int(pid)
        except (TypeError, ValueError):
            return None
        try:
            output = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "stat=", "-o", "command="],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            return None
        if not output:
            return None
        status, _, command = output.partition(" ")
        if status.startswith("Z"):
            return None
        return command.strip()

    @classmethod
    def process_exists(cls, pid):
        return cls.process_status(pid) is not None

    @staticmethod
    def process_identity(pid):
        """Return a PID-reuse-resistant identity for a live local process."""
        if not pid:
            return None
        if sys.platform == "darwin":
            try:
                library = ctypes.CDLL(None, use_errno=True)
                function = library.proc_pidinfo
                function.argtypes = [
                    ctypes.c_int,
                    ctypes.c_int,
                    ctypes.c_uint64,
                    ctypes.c_void_p,
                    ctypes.c_int,
                ]
                function.restype = ctypes.c_int
                info = _DarwinProcBSDInfo()
                written = function(
                    int(pid),
                    3,  # PROC_PIDTBSDINFO
                    0,
                    ctypes.byref(info),
                    ctypes.sizeof(info),
                )
                if written != ctypes.sizeof(info) or int(info.pid) != int(pid):
                    return None
                # exec() changes the command name without creating a new process.
                # PID plus the kernel birth timestamp survives that transition
                # while still rejecting a recycled PID.
                return "darwin-v2:%d:%d:%d" % (
                    int(info.pid),
                    int(info.started_seconds),
                    int(info.started_microseconds),
                )
            except (AttributeError, OSError, TypeError, ValueError):
                return None
        try:
            output = subprocess.check_output(
                ["ps", "-p", str(int(pid)), "-o", "lstart=", "-o", "command="],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, ValueError, subprocess.CalledProcessError):
            return None
        return " ".join(output.split()) if output else None

    @classmethod
    def process_alive(cls, pid, task=None):
        command = cls.process_status(pid)
        if command is None:
            return False
        expected_identity = ((task or {}).get("metadata") or {}).get(
            "process_identity"
        )
        if expected_identity and cls.process_identity(pid) != expected_identity:
            return False
        if (task or {}).get("profile") == "adaptive":
            events = ((task or {}).get("metadata") or {}).get(
                "active_process_events_path"
            )
            if events:
                try:
                    expected = cls._containment_binding_from_metadata(
                        (task or {}).get("metadata") or {}
                    )
                    manifest_path = (
                        Path(events).expanduser().resolve().parent
                        / "containment"
                        / "containment.json"
                    )
                    manifest = cls._read_containment_manifest(
                        manifest_path, expected_binding=expected
                    )
                    members, gone = cls._coalition_members(
                        manifest["resource_coalition_id"]
                    )
                    return (
                        not gone
                        and int(pid) == int(manifest["pid"])
                        and int(pid) in members
                    )
                except (OSError, TypeError, ValueError, json.JSONDecodeError):
                    return False
        provider = (task or {}).get("provider", "codex")
        executable = ((task or {}).get("metadata") or {}).get("provider_executable")
        if executable:
            return Path(executable).name in command
        return provider == "codex" and "codex" in command and " exec" in command

    @classmethod
    def process_group_members(cls, process_group_id):
        if os.name == "nt" or not process_group_id:
            return []
        try:
            output = subprocess.check_output(
                ["ps", "-axo", "pid=,pgid="],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            return []
        members = []
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            try:
                pid, pgid = (int(field) for field in fields)
            except ValueError:
                continue
            if pgid == int(process_group_id) and cls.process_exists(pid):
                members.append(pid)
        return sorted(set(members))

    @classmethod
    def process_descendants(cls, root_pid):
        """Return the live descendant tree without relying on a shared group id."""
        if os.name == "nt" or not root_pid:
            return []
        try:
            output = subprocess.check_output(
                ["ps", "-axo", "pid=,ppid="],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            return []
        children = {}
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            try:
                pid, parent = (int(field) for field in fields)
            except ValueError:
                continue
            children.setdefault(parent, []).append(pid)
        descendants = []
        pending = list(children.get(int(root_pid), ()))
        seen = {int(root_pid)}
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            pending.extend(children.get(pid, ()))
            if cls.process_exists(pid):
                descendants.append(pid)
        return sorted(descendants)

    @staticmethod
    def process_snapshot():
        """Read one process-table snapshot for low-overhead descendant tracking."""
        if os.name == "nt":
            return {}
        try:
            output = subprocess.check_output(
                [
                    "ps",
                    "-axo",
                    "pid=,ppid=,pgid=,stat=,lstart=,command=",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            return {}
        snapshot = {}
        for line in output.splitlines():
            fields = line.split(None, 9)
            if len(fields) < 10:
                continue
            try:
                pid, parent, group = (int(fields[index]) for index in range(3))
            except ValueError:
                continue
            status = fields[3]
            if status.startswith("Z"):
                continue
            started = " ".join(fields[4:9])
            command = fields[9]
            snapshot[pid] = {
                "parent": parent,
                "group": group,
                "identity": " ".join(("%s %s" % (started, command)).split()),
            }
        return snapshot

    @classmethod
    def start_descendant_tracker(cls, root_pid, process_group_id=None, poll_seconds=0.25):
        """Best-effort leak detection; acceptance also relies on sealed verifier bytes."""
        observed = {}
        observed_lock = threading.Lock()
        tracker_stop = threading.Event()

        def observe():
            snapshot = cls.process_snapshot()
            children = {}
            for candidate, details in snapshot.items():
                children.setdefault(details["parent"], []).append(candidate)
            targets = {int(root_pid)}
            pending = list(children.get(int(root_pid), ()))
            while pending:
                target = pending.pop()
                if target in targets:
                    continue
                targets.add(target)
                pending.extend(children.get(target, ()))
            if process_group_id:
                targets.update(
                    candidate
                    for candidate, details in snapshot.items()
                    if details["group"] == int(process_group_id)
                )
            with observed_lock:
                for target in targets:
                    details = snapshot.get(target)
                    if details is not None:
                        identity = cls.process_identity(target)
                        if identity is not None:
                            observed.setdefault(int(target), identity)

        def track():
            interval = max(0.05, min(0.5, float(poll_seconds)))
            while not tracker_stop.is_set():
                observe()
                tracker_stop.wait(interval)

        observe()
        thread = threading.Thread(
            target=track,
            name="operator-provider-descendant-tracker",
            daemon=True,
        )
        thread.start()
        stopped = threading.Event()

        def stop():
            if not stopped.is_set():
                observe()
                tracker_stop.set()
                thread.join(timeout=1)
                observe()
                stopped.set()
            with observed_lock:
                return dict(observed)

        return stop

    @classmethod
    def safe_terminate(
        cls,
        pid,
        process_group_id=None,
        extra_targets=None,
        expected_identities=None,
    ):
        helper = Path.home() / ".codex/bin/safe-terminate-helper"
        if not helper.is_file():
            return False, "safe-terminate-helper is missing"
        expected_identities = {
            int(target): identity
            for target, identity in dict(expected_identities or {}).items()
        }
        root_pid = int(pid) if pid else None
        expected_root = expected_identities.get(root_pid)
        initial_root = cls.process_identity(root_pid) if root_pid else None
        if expected_root is not None and initial_root not in (None, expected_root):
            return False, "saved process identity no longer matches PID %s" % root_pid

        # Dynamic descendants are admitted only while the exact saved root is live.
        # Capture an identity for every PID so a recycled descendant is never passed
        # to the helper merely because it reused a sampled process-table slot.
        dynamic = []
        if root_pid and initial_root is not None:
            dynamic.append(root_pid)
            dynamic.extend(cls.process_descendants(root_pid))
            if process_group_id and int(process_group_id) == root_pid:
                dynamic.extend(cls.process_group_members(process_group_id))
        sampled_identities = {
            int(target): cls.process_identity(target) for target in set(dynamic)
        }

        exact = []
        for target in extra_targets or ():
            target = int(target)
            expected = expected_identities.get(target)
            current = cls.process_identity(target)
            if current is None or (expected is not None and current != expected):
                continue
            exact.append(target)

        # Close the discovery TOCTOU before invoking the external safety helper.
        current_root = cls.process_identity(root_pid) if root_pid else None
        if expected_root is not None:
            if initial_root == expected_root and current_root != expected_root:
                return False, "saved process identity changed before termination for PID %s" % root_pid
            if initial_root is None and current_root is not None:
                return False, "saved PID %s was reused before termination" % root_pid
        targets = []
        if initial_root is not None and current_root == initial_root:
            targets.extend(
                target
                for target, identity in sampled_identities.items()
                if identity is not None and cls.process_identity(target) == identity
            )
        for target in exact:
            current = cls.process_identity(target)
            expected = expected_identities.get(target)
            if current is not None and (expected is None or current == expected):
                targets.append(target)
        targets = sorted(set(targets))
        if not targets:
            return True, "PASS no live targets"
        final_root = cls.process_identity(root_pid) if root_pid else None
        if expected_root is not None:
            if initial_root == expected_root and final_root != expected_root:
                return False, "saved process identity changed before helper invocation for PID %s" % root_pid
            if initial_root is None and final_root is not None:
                return False, "saved PID %s was reused before helper invocation" % root_pid
        try:
            completed = subprocess.run(
                [str(helper), *[str(target) for target in targets]],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return False, str(exc)
        return completed.returncode == 0, completed.stdout.strip()

    @classmethod
    def terminate_spawned(
        cls,
        process,
        process_group_id=None,
        timeout=25,
        known_targets=None,
        expected_identities=None,
    ):
        outcome = []
        targets = [process.pid]
        targets.extend(cls.process_descendants(process.pid))
        if process_group_id:
            targets.extend(cls.process_group_members(process_group_id))
        targets.extend(known_targets or [])
        targets = sorted(set(targets))

        def terminate():
            outcome.append(
                cls.safe_terminate(
                    process.pid,
                    process_group_id,
                    extra_targets=targets,
                    expected_identities=expected_identities,
                )
            )

        thread = threading.Thread(target=terminate, name="operator-safe-terminate")
        thread.start()
        deadline = time.monotonic() + timeout
        while thread.is_alive() and time.monotonic() < deadline:
            process.poll()
            thread.join(timeout=0.05)
        if thread.is_alive():
            return False, "safe termination helper did not finish"
        process.poll()
        helper_ok, detail = outcome[0]
        remaining_group = cls.process_group_members(process_group_id)
        expected_identities = dict(expected_identities or {})
        remaining_targets = [
            pid
            for pid in targets
            if cls.process_exists(pid)
            and (
                pid not in expected_identities
                or cls.process_identity(pid) == expected_identities[pid]
            )
        ]
        remaining = sorted(set(remaining_group + remaining_targets))
        confirmed = process.poll() is not None and not remaining
        if confirmed:
            return True, detail or "termination confirmed"
        suffix = "live process group members: %s" % remaining if remaining else "root process remains live"
        return False, "%s; %s" % (detail or "termination failed", suffix)

    @classmethod
    def run_supervised(
        cls,
        command,
        *,
        cwd,
        input_text=None,
        timeout=60,
        heartbeat=None,
        cancelled=None,
        merge_stderr=False,
        poll_seconds=0.25,
        env=None,
        on_start=None,
        exact_containment=False,
        containment_dir=None,
    ):
        if exact_containment:
            if containment_dir is None:
                return SupervisedProcessResult(
                    returncode=None,
                    stdout="",
                    stderr="",
                    termination_confirmed=True,
                    termination_detail="exact containment requires a storage directory",
                    containment_proven=False,
                )
            directory = Path(containment_dir).expanduser().resolve()
            stdout_path = directory / "stdout.log"
            stderr_path = directory / "stderr.log"
            outcome = cls._run_exact_contained(
                command,
                cwd=cwd,
                input_text=input_text,
                timeout=timeout,
                heartbeat=heartbeat,
                cancelled=cancelled,
                poll_seconds=poll_seconds,
                env=os.environ.copy() if env is None else dict(env),
                containment_dir=directory,
                stdout_path=stdout_path,
                stderr_path=stderr_path,
                on_start=on_start,
            )
            if outcome["callback_exception"] is not None:
                if not outcome["termination_confirmed"]:
                    raise UnconfirmedTerminationError(
                        outcome["pid"], outcome["termination_detail"]
                    )
                raise outcome["callback_exception"]
            stdout = (
                stdout_path.read_text(encoding="utf-8", errors="surrogateescape")
                if stdout_path.is_file()
                else ""
            )
            stderr = (
                stderr_path.read_text(encoding="utf-8", errors="surrogateescape")
                if stderr_path.is_file()
                else ""
            )
            if merge_stderr and stderr:
                stdout += stderr
                stderr = ""
            return SupervisedProcessResult(
                returncode=outcome["returncode"],
                stdout=stdout,
                stderr=stderr,
                timed_out=outcome["timed_out"],
                cancelled=outcome["cancelled"],
                pid=outcome["pid"],
                termination_confirmed=outcome["termination_confirmed"],
                termination_detail=(
                    outcome["callback_error"] or outcome["termination_detail"]
                ),
                leaked_descendants=outcome["leaked_descendants"],
                containment_proven=outcome["containment_proven"],
                containment_manifest=outcome["containment_manifest"],
            )
        new_session = should_start_new_session()
        process_env = os.environ.copy() if env is None else dict(env)
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
            text=True,
            start_new_session=new_session,
            env=process_env,
        )
        process_group_id = process.pid if new_session and os.name != "nt" else None
        observed_identities = {}
        observed_lock = threading.Lock()
        tracker_stop = threading.Event()

        def observe_descendants():
            snapshot = cls.process_snapshot()
            children = {}
            for pid, details in snapshot.items():
                children.setdefault(details["parent"], []).append(pid)
            targets = {process.pid}
            pending = list(children.get(process.pid, ()))
            while pending:
                target = pending.pop()
                if target in targets:
                    continue
                targets.add(target)
                pending.extend(children.get(target, ()))
            if process_group_id:
                targets.update(
                    pid
                    for pid, details in snapshot.items()
                    if details["group"] == int(process_group_id)
                )
            with observed_lock:
                for target in targets:
                    details = snapshot.get(target)
                    if details is not None:
                        identity = cls.process_identity(target)
                        if identity is not None:
                            observed_identities.setdefault(int(target), identity)

        def track_descendants():
            interval = max(0.1, min(0.5, float(poll_seconds)))
            while not tracker_stop.is_set():
                observe_descendants()
                tracker_stop.wait(interval)

        observe_descendants()
        tracker = threading.Thread(
            target=track_descendants,
            name="operator-descendant-tracker",
            daemon=True,
        )
        tracker.start()

        def stop_tracking():
            observe_descendants()
            tracker_stop.set()
            tracker.join(timeout=1)
            observe_descendants()
            with observed_lock:
                return dict(observed_identities)

        if on_start:
            try:
                on_start(
                    process.pid,
                    process_group_id,
                    cls.process_identity(process.pid),
                )
            except Exception:
                identities = stop_tracking()
                confirmed, detail = cls.terminate_spawned(
                    process,
                    process_group_id,
                    known_targets=identities,
                    expected_identities=identities,
                )
                if not confirmed:
                    raise UnconfirmedTerminationError(process.pid, detail)
                raise

        started = time.monotonic()
        pending_input = input_text
        timed_out = False
        was_cancelled = False
        while True:
            remaining = max(0.0, float(timeout) - (time.monotonic() - started))
            try:
                stdout, stderr = process.communicate(
                    input=pending_input,
                    timeout=max(0.01, min(float(poll_seconds), remaining or 0.01)),
                )
                break
            except subprocess.TimeoutExpired:
                pending_input = None
                if heartbeat:
                    try:
                        heartbeat()
                    except Exception:
                        identities = stop_tracking()
                        confirmed, detail = cls.terminate_spawned(
                            process,
                            process_group_id,
                            known_targets=identities,
                            expected_identities=identities,
                        )
                        if not confirmed:
                            raise UnconfirmedTerminationError(process.pid, detail)
                        raise
                try:
                    was_cancelled = bool(cancelled and cancelled())
                except Exception:
                    identities = stop_tracking()
                    confirmed, detail = cls.terminate_spawned(
                        process,
                        process_group_id,
                        known_targets=identities,
                        expected_identities=identities,
                    )
                    if not confirmed:
                        raise UnconfirmedTerminationError(process.pid, detail)
                    raise
                timed_out = time.monotonic() - started >= float(timeout)
                if not (was_cancelled or timed_out):
                    continue
                identities = stop_tracking()
                confirmed, detail = cls.terminate_spawned(
                    process,
                    process_group_id,
                    known_targets=identities,
                    expected_identities=identities,
                )
                try:
                    stdout, stderr = process.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    stdout, stderr = "", ""
                return SupervisedProcessResult(
                    returncode=process.poll(),
                    stdout=stdout or "",
                    stderr=stderr or "",
                    timed_out=timed_out,
                    cancelled=was_cancelled,
                    pid=process.pid,
                    termination_confirmed=confirmed,
                    termination_detail=detail,
                    leaked_descendants=any(
                        pid != process.pid
                        and cls.process_identity(pid) == identity
                        for pid, identity in identities.items()
                    ),
                )
        identities = stop_tracking()
        live_observed = [
            pid
            for pid, identity in identities.items()
            if pid != process.pid and cls.process_identity(pid) == identity
        ]
        remaining_group = cls.process_group_members(process_group_id)
        termination_detail = None
        termination_confirmed = True
        leaked_descendants = bool(live_observed or remaining_group)
        if leaked_descendants:
            termination_confirmed, termination_detail = cls.terminate_spawned(
                process,
                process_group_id,
                known_targets=identities,
                expected_identities=identities,
            )
        return SupervisedProcessResult(
            returncode=process.returncode,
            stdout=stdout or "",
            stderr=stderr or "",
            pid=process.pid,
            termination_confirmed=termination_confirmed,
            termination_detail=termination_detail,
            leaked_descendants=leaked_descendants,
        )

    def run(
        self,
        task,
        on_start=None,
        on_event=None,
        heartbeat=None,
        cancelled=None,
    ):
        task_dir, events_path, stderr_path = self._task_paths(task)
        prompt_path = task_dir / "prompt.txt"
        prompt = task["prompt"]
        resume = self.resume_requested(task)
        if resume and int(task.get("attempt") or 1) > 1:
            prompt = (
                "The prior worker was interrupted. Inspect the current repository and "
                "continue the original task to completion. Do not repeat completed work.\n\n"
                "Original task:\n" + prompt
            )
        prompt_path.write_text(prompt, encoding="utf-8")
        command = self.command(task, resume=resume)
        command_path = task_dir / "command.json"
        command_path.write_text(
            json.dumps(
                {
                    "provider": self.provider_name,
                    "profile": task.get("profile"),
                    "requested_model": task.get("model") or self.settings.model,
                    "resolved_model": task.get("model") or self.settings.model,
                    "argv": command,
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        if task.get("profile") == "adaptive":
            accumulator = EventAccumulator()
            reader = None
            event_budget_exceeded = False

            def read_events():
                nonlocal reader, event_budget_exceeded
                if reader is None and events_path.is_file():
                    reader = events_path.open(
                        "r", encoding="utf-8", errors="surrogateescape"
                    )
                if reader is not None:
                    self._read_new_events(reader, accumulator, on_event)
                max_event_bytes = int(
                    (task.get("metadata") or {}).get("max_event_bytes") or 0
                )
                if (
                    max_event_bytes > 0
                    and events_path.is_file()
                    and events_path.stat().st_size > max_event_bytes
                ):
                    event_budget_exceeded = True
                    return "provider event output exceeded its hard byte budget"
                return None

            try:
                outcome = self._run_exact_contained(
                    command,
                    cwd=task["cwd"],
                    input_text=prompt,
                    timeout=self.settings.task_timeout_seconds,
                    heartbeat=heartbeat,
                    cancelled=cancelled,
                    poll_seconds=self.settings.poll_seconds,
                    env=os.environ.copy(),
                    containment_dir=task_dir / "containment",
                    stdout_path=events_path,
                    stderr_path=stderr_path,
                    on_start=(
                        (
                            lambda pid, _group, _identity: on_start(
                                pid, str(events_path), str(stderr_path)
                            )
                        )
                        if on_start
                        else None
                    ),
                    tick=read_events,
                )
                read_events()
            finally:
                if reader is not None:
                    reader.close()
            common = {
                "exit_code": outcome["returncode"],
                "timed_out": outcome["timed_out"],
                "cancelled": outcome["cancelled"],
                "pid": outcome["pid"],
                "process_may_be_alive": not outcome["termination_confirmed"],
                "termination_confirmed": outcome["termination_confirmed"],
                "termination_detail": outcome["termination_detail"],
                "leaked_descendants": outcome["leaked_descendants"],
                "containment_proven": outcome["containment_proven"],
                "containment_manifest": outcome["containment_manifest"],
            }
            if outcome["callback_error"]:
                return accumulator.result(
                    error="runner callback failed: %s" % outcome["callback_error"],
                    **common,
                )
            if not outcome["termination_confirmed"]:
                return accumulator.result(
                    error="process containment could not be confirmed: %s"
                    % (outcome["termination_detail"] or "unknown containment failure"),
                    **common,
                )
            if not outcome["containment_proven"]:
                return accumulator.result(
                    error="exact process containment was not proven",
                    **common,
                )
            if event_budget_exceeded or outcome["stop_reason"]:
                return accumulator.result(
                    error=(
                        outcome["stop_reason"]
                        or "provider event output exceeded its hard byte budget"
                    ),
                    **common,
                )
            if outcome["leaked_descendants"]:
                return accumulator.result(
                    error="provider leaked descendant processes",
                    **common,
                )
            return accumulator.result(**common)
        started = time.monotonic()
        last_heartbeat = 0.0
        timed_out = False
        was_cancelled = False
        termination_error = None
        termination_confirmed = True
        callback_error = None
        event_budget_exceeded = False
        process_group_id = None
        accumulator = EventAccumulator()

        with events_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open(
            "w", encoding="utf-8"
        ) as stderr_file:
            new_session = should_start_new_session()
            process = subprocess.Popen(
                command,
                cwd=task["cwd"],
                stdin=subprocess.PIPE,
                stdout=stdout_file,
                stderr=stderr_file,
                text=True,
                start_new_session=new_session,
                env=os.environ.copy(),
            )
            process_group_id = process.pid if new_session and os.name != "nt" else None
            stop_tracking = self.start_descendant_tracker(
                process.pid,
                process_group_id,
                self.settings.poll_seconds,
            )
            tracked_identities = None
            try:
                if on_start:
                    on_start(process.pid, str(events_path), str(stderr_path))
                process.stdin.write(prompt)
                process.stdin.close()

                with events_path.open("r", encoding="utf-8") as reader:
                    while True:
                        self._read_new_events(reader, accumulator, on_event)
                        now = time.monotonic()
                        if heartbeat and now - last_heartbeat >= 5:
                            heartbeat()
                            last_heartbeat = now
                        max_event_bytes = int(
                            (task.get("metadata") or {}).get("max_event_bytes") or 0
                        )
                        if (
                            max_event_bytes > 0
                            and events_path.stat().st_size > max_event_bytes
                        ):
                            event_budget_exceeded = True
                        if process.poll() is not None:
                            self._read_new_events(reader, accumulator, on_event)
                            if (
                                max_event_bytes > 0
                                and events_path.stat().st_size > max_event_bytes
                            ):
                                event_budget_exceeded = True
                            break
                        if cancelled and cancelled():
                            was_cancelled = True
                        if now - started >= self.settings.task_timeout_seconds:
                            timed_out = True
                        if was_cancelled or timed_out or event_budget_exceeded:
                            tracked_identities = stop_tracking()
                            termination_confirmed, detail = self.terminate_spawned(
                                process,
                                process_group_id,
                                known_targets=tracked_identities,
                                expected_identities=tracked_identities,
                            )
                            if not termination_confirmed:
                                termination_error = detail
                            self._read_new_events(reader, accumulator, on_event)
                            break
                        time.sleep(self.settings.poll_seconds)
            except Exception as exc:
                callback_error = "%s: %s" % (type(exc).__name__, exc)
                tracked_identities = stop_tracking()
                termination_confirmed, detail = self.terminate_spawned(
                    process,
                    process_group_id,
                    known_targets=tracked_identities,
                    expected_identities=tracked_identities,
                )
                if not termination_confirmed:
                    termination_error = detail

        if tracked_identities is None:
            tracked_identities = stop_tracking()
        exit_code = process.poll()
        live_observed = [
            target
            for target, identity in tracked_identities.items()
            if target != process.pid and self.process_identity(target) == identity
        ]
        remaining_group = self.process_group_members(process_group_id)
        leaked_descendants = bool(live_observed or remaining_group)
        if leaked_descendants and termination_confirmed:
            termination_confirmed, detail = self.terminate_spawned(
                process,
                process_group_id,
                known_targets=tracked_identities,
                expected_identities=tracked_identities,
            )
            remaining_group = self.process_group_members(process_group_id)
            if not termination_confirmed:
                termination_error = "%s; live process group members: %s" % (
                    detail,
                    remaining_group,
                )
        if callback_error:
            return accumulator.result(
                exit_code=exit_code,
                error="runner callback failed: %s" % callback_error,
                pid=process.pid,
                process_may_be_alive=not termination_confirmed,
                termination_confirmed=termination_confirmed,
                termination_detail=termination_error,
                leaked_descendants=leaked_descendants,
            )
        if termination_error:
            return accumulator.result(
                exit_code=exit_code,
                error="process termination refused or failed: %s" % termination_error,
                timed_out=timed_out,
                cancelled=was_cancelled,
                pid=process.pid,
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail=termination_error,
                leaked_descendants=leaked_descendants,
            )
        if event_budget_exceeded:
            return accumulator.result(
                exit_code=exit_code,
                error="provider event output exceeded its hard byte budget",
                pid=process.pid,
                process_may_be_alive=False,
                termination_confirmed=termination_confirmed,
                termination_detail="provider stopped at max_event_bytes",
                leaked_descendants=leaked_descendants,
            )
        if leaked_descendants:
            return accumulator.result(
                exit_code=exit_code,
                error="provider leaked descendant processes",
                pid=process.pid,
                process_may_be_alive=not termination_confirmed,
                termination_confirmed=termination_confirmed,
                termination_detail=(
                    termination_error or "detached provider descendants were terminated"
                ),
                leaked_descendants=True,
            )
        return accumulator.result(
            exit_code=exit_code,
            timed_out=timed_out,
            cancelled=was_cancelled,
            pid=process.pid,
            termination_confirmed=termination_confirmed,
            leaked_descendants=False,
        )

    def _monitor_exact_existing(
        self,
        task,
        events_path,
        accumulator,
        on_event,
        heartbeat,
        cancelled,
    ):
        manifest_path = events_path.parent / "containment" / "containment.json"
        try:
            expected_binding = self._containment_binding_from_metadata(
                task.get("metadata") or {}
            )
            job = self._read_containment_manifest(
                manifest_path,
                tasks_root=self.settings.tasks_dir,
                expected_binding=expected_binding,
            )
        except Exception as exc:
            return accumulator.result(
                error="adaptive containment manifest is untrusted: %s" % exc,
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail="adaptive descendants cannot be excluded",
                containment_proven=False,
            )
        if int(job["pid"]) != int(task.get("pid") or 0):
            return accumulator.result(
                error="adaptive containment PID does not match the task ledger",
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail="adaptive descendants cannot be excluded",
                containment_proven=False,
                containment_manifest=job["manifest_path"],
            )
        if job.get("process_identity") != (
            (task.get("metadata") or {}).get("process_identity")
        ):
            return accumulator.result(
                error="adaptive containment identity does not match the task ledger",
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail="adaptive descendants cannot be excluded",
                containment_proven=False,
                containment_manifest=job["manifest_path"],
            )
        last_heartbeat = 0.0
        was_cancelled = False
        callback_exception = None
        with events_path.open(
            "r", encoding="utf-8", errors="surrogateescape"
        ) as reader:
            while True:
                try:
                    self._read_new_events(reader, accumulator, on_event)
                    now = time.monotonic()
                    if heartbeat and now - last_heartbeat >= 5:
                        heartbeat()
                        last_heartbeat = now
                    if cancelled and cancelled():
                        was_cancelled = True
                except Exception as exc:
                    callback_exception = exc
                try:
                    members, gone = self._coalition_members(
                        job["resource_coalition_id"]
                    )
                except OSError as exc:
                    return accumulator.result(
                        error="adaptive coalition query failed: %s" % exc,
                        pid=task.get("pid"),
                        process_may_be_alive=True,
                        termination_confirmed=False,
                        termination_detail="adaptive descendants cannot be excluded",
                        containment_proven=False,
                        containment_manifest=job["manifest_path"],
                    )
                info = self._launchd_info(job["domain"], job["label"])
                gate_is_member = int(job["pid"]) in members
                live_identity = self.process_identity(job["pid"])
                if gate_is_member and live_identity is not None and live_identity != (
                    (task.get("metadata") or {}).get("process_identity")
                ):
                    return accumulator.result(
                        error="adaptive containment gate identity changed",
                        pid=task.get("pid"),
                        process_may_be_alive=True,
                        termination_confirmed=False,
                        termination_detail=(
                            "saved gate PID identity does not match; no signal was sent"
                        ),
                        containment_proven=False,
                        containment_manifest=job["manifest_path"],
                    )
                if info["running"] and not gate_is_member:
                    return accumulator.result(
                        error="adaptive launchd gate is outside its bound coalition",
                        pid=task.get("pid"),
                        process_may_be_alive=True,
                        termination_confirmed=False,
                        termination_detail=(
                            "launchd and coalition process identities disagree"
                        ),
                        containment_proven=False,
                        containment_manifest=job["manifest_path"],
                    )
                child_done = Path(job["exit_path"]).is_file()
                if (
                    was_cancelled
                    or callback_exception is not None
                    or child_done
                    or gone
                    or not info["running"]
                ):
                    break
                time.sleep(max(0.01, min(0.25, self.settings.poll_seconds)))
            self._read_new_events(reader, accumulator, on_event)

        leaked = False
        if not was_cancelled and callback_exception is None and members:
            deadline = time.monotonic() + 1
            while members and time.monotonic() < deadline:
                time.sleep(0.05)
                members, gone = self._coalition_members(
                    job["resource_coalition_id"]
                )
            leaked = bool(
                [candidate for candidate in members if candidate != job["pid"]]
            )
        if members:
            confirmed, detail = self._terminate_coalition(job, members)
            if not confirmed:
                return accumulator.result(
                    error="adaptive coalition termination failed",
                    cancelled=was_cancelled,
                    pid=task.get("pid"),
                    process_may_be_alive=True,
                    termination_confirmed=False,
                    termination_detail=detail,
                    leaked_descendants=leaked,
                    containment_proven=False,
                    containment_manifest=job["manifest_path"],
                )
        unloaded, detail = self._bootout_containment(job)
        if not unloaded:
            return accumulator.result(
                error="adaptive containment job could not be unloaded",
                cancelled=was_cancelled,
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail=detail,
                leaked_descendants=leaked,
                containment_proven=False,
                containment_manifest=job["manifest_path"],
            )
        try:
            final_members, _gone = self._coalition_members(
                job["resource_coalition_id"]
            )
        except OSError as exc:
            return accumulator.result(
                error="adaptive final coalition query failed: %s" % exc,
                cancelled=was_cancelled,
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail="adaptive descendants cannot be excluded",
                leaked_descendants=leaked,
                containment_proven=False,
                containment_manifest=job["manifest_path"],
            )
        if final_members:
            return accumulator.result(
                error="adaptive coalition members remain after unload",
                cancelled=was_cancelled,
                pid=task.get("pid"),
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail="live coalition members: %s" % final_members,
                leaked_descendants=leaked,
                containment_proven=False,
                containment_manifest=job["manifest_path"],
            )
        error = None
        if callback_exception is not None:
            error = "adopted runner callback failed: %s: %s" % (
                type(callback_exception).__name__,
                callback_exception,
            )
        elif leaked:
            error = "adopted adaptive provider leaked descendant processes"
        return accumulator.result(
            exit_code=self._contained_exit_code(job),
            error=error,
            cancelled=was_cancelled,
            pid=task.get("pid"),
            process_may_be_alive=False,
            termination_confirmed=True,
            termination_detail=detail,
            leaked_descendants=leaked,
            containment_proven=True,
            containment_manifest=job["manifest_path"],
        )

    def monitor_existing(
        self,
        task,
        on_event=None,
        heartbeat=None,
        cancelled=None,
    ):
        metadata = task.get("metadata") or {}
        pid = task.get("pid")
        expected_identity = metadata.get("process_identity")
        recorded_events = metadata.get("active_process_events_path")
        if recorded_events:
            raw_events = Path(str(recorded_events)).expanduser()
            events_path = raw_events.resolve()
            tasks_root = self.settings.tasks_dir.resolve()
            trusted = (
                events_path.name == "events.jsonl"
                and (events_path == tasks_root or tasks_root in events_path.parents)
                and not raw_events.is_symlink()
            )
            if not trusted:
                live = bool(
                    expected_identity
                    and self.process_identity(pid) == expected_identity
                    and self.process_exists(pid)
                )
                return EventAccumulator().result(
                    error="adopted process event log path is outside attempt storage",
                    pid=pid,
                    process_may_be_alive=live,
                    termination_confirmed=not live,
                    termination_detail=(
                        "live adopted process has an untrusted event log" if live else None
                    ),
                )
        else:
            _, events_path, _ = self._task_paths(task)
        accumulator = EventAccumulator()
        if not events_path.exists():
            live = bool(
                expected_identity
                and self.process_identity(pid) == expected_identity
                and self.process_exists(pid)
            )
            return accumulator.result(
                error="missing immutable event log for adopted process",
                pid=pid,
                process_may_be_alive=live,
                termination_confirmed=not live,
                termination_detail=(
                    "live adopted process has no bound event log" if live else None
                ),
            )
        process_group_id = metadata.get("process_group_id")
        if not expected_identity:
            return accumulator.result(
                error="adopted process identity is missing",
                pid=pid,
                process_may_be_alive=self.process_exists(pid),
                termination_confirmed=not self.process_exists(pid),
                termination_detail="saved process identity is missing",
            )
        if task.get("profile") == "adaptive":
            return self._monitor_exact_existing(
                task,
                events_path,
                accumulator,
                on_event,
                heartbeat,
                cancelled,
            )
        last_heartbeat = 0.0
        termination_detail = None
        termination_confirmed = True
        was_cancelled = False
        with events_path.open("r", encoding="utf-8") as reader:
            try:
                while (
                    self.process_identity(pid) == expected_identity
                    and self.process_alive(pid, task)
                ):
                    self._read_new_events(reader, accumulator, on_event)
                    now = time.monotonic()
                    if heartbeat and now - last_heartbeat >= 5:
                        heartbeat()
                        last_heartbeat = now
                    if cancelled and cancelled():
                        was_cancelled = True
                        termination_confirmed, termination_detail = self.safe_terminate(
                            pid,
                            process_group_id,
                            expected_identities={int(pid): expected_identity},
                        )
                        if not termination_confirmed and self.process_exists(pid):
                            break
                    time.sleep(self.settings.poll_seconds)
            except Exception as exc:
                termination_confirmed, termination_detail = self.safe_terminate(
                    pid,
                    process_group_id,
                    expected_identities={int(pid): expected_identity},
                )
                return accumulator.result(
                    error="adopted runner callback failed: %s: %s"
                    % (type(exc).__name__, exc),
                    pid=pid,
                    process_may_be_alive=(
                        self.process_exists(pid)
                        or bool(self.process_group_members(process_group_id))
                    ),
                    termination_confirmed=(
                        not self.process_exists(pid)
                        and not self.process_group_members(process_group_id)
                    ),
                    termination_detail=termination_detail,
                )
            self._read_new_events(reader, accumulator, on_event)
        identity_matches = self.process_identity(pid) == expected_identity
        process_may_be_alive = identity_matches and self.process_exists(pid)
        remaining_group = (
            self.process_group_members(process_group_id) if identity_matches else []
        )
        process_may_be_alive = process_may_be_alive or bool(remaining_group)
        if self.process_exists(pid) and not identity_matches:
            termination_confirmed = False
            termination_detail = (
                termination_detail
                or "saved PID was reused by a different process; no signal was sent"
            )
        elif process_may_be_alive and not self.process_alive(pid, task):
            termination_confirmed = False
            termination_detail = (
                termination_detail
                or "saved PID remains live but provider identity is unconfirmed"
            )
        return accumulator.result(
            exit_code=None,
            cancelled=was_cancelled,
            pid=pid,
            process_may_be_alive=process_may_be_alive,
            termination_confirmed=termination_confirmed and not process_may_be_alive,
            termination_detail=termination_detail,
        )

    @staticmethod
    def parse_log(path):
        accumulator = EventAccumulator()
        path = Path(path)
        if not path.exists():
            return accumulator.result(error="event log does not exist")
        with path.open(
            "r", encoding="utf-8", errors="surrogateescape"
        ) as handle:
            CodexRunner._read_new_events(handle, accumulator, None)
        return accumulator.result(exit_code=None)
