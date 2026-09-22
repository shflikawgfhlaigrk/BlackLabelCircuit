import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath

from .codex_runner import CodexRunner, UnconfirmedTerminationError
from .workspace import (
    DEFAULT_MAX_FILE_BYTES,
    DEFAULT_MAX_FILES,
    DEFAULT_MAX_TOTAL_BYTES,
    WorkspaceManager,
    git_inventory_path,
)


_VERIFIER_SECRET_COMPONENTS = {
    ".aws",
    ".azure",
    ".blacklabel-operator",
    ".codex",
    ".git",
    ".gnupg",
    ".kube",
    ".operator",
    ".operator-state",
    ".ssh",
}
_VERIFIER_SECRET_NAMES = {
    ".env",
    ".envrc",
    ".git-credentials",
    ".netrc",
    ".npmrc",
    ".pypirc",
    "credentials.json",
    "kubeconfig",
    "secrets.json",
    "service-account.json",
    "service_account.json",
}
_VERIFIER_SECRET_SUFFIXES = {
    ".db",
    ".db-shm",
    ".db-wal",
    ".key",
    ".p12",
    ".pem",
    ".pfx",
    ".secret",
    ".secrets",
    ".sqlite",
    ".sqlite-shm",
    ".sqlite-wal",
    ".sqlite3",
    ".token",
}


def _run(command, cwd):
    return subprocess.run(
        command,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="surrogateescape",
        check=False,
    )


def _write_immutable(path, payload):
    path = Path(path)
    data = payload if isinstance(payload, bytes) else str(payload).encode("utf-8")
    descriptor = os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise
    path.chmod(0o400)
    return hashlib.sha256(data).hexdigest()


def _safe_relative(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("verification writable path must be a non-empty string")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        raise ValueError("verification writable path must stay inside the sandbox")
    if str(pure) != value:
        raise ValueError("verification writable path must be canonical")
    if ".git" in pure.parts:
        raise ValueError("verification cannot make Git metadata writable")
    return value


def _secret_path(relative):
    pure = PurePosixPath(relative)
    lowered = [part.lower() for part in pure.parts]
    if any(part in _VERIFIER_SECRET_COMPONENTS for part in lowered):
        return True
    name = lowered[-1]
    if name == ".env" or name.startswith(".env."):
        return True
    if name in _VERIFIER_SECRET_NAMES:
        return True
    if name.startswith("id_rsa") or name.startswith("id_ed25519"):
        return True
    if any(marker in name for marker in ("credential", "private-key", "private_key")):
        return True
    return any(name.endswith(suffix) for suffix in _VERIFIER_SECRET_SUFFIXES)


def _lexical_absolute(path):
    """Return an absolute path without dereferencing any symlink component."""
    return Path(os.path.abspath(os.path.expanduser(os.fspath(path))))


def _symlink_chain(path, limit=40):
    """Bind every lexical hop needed to execute a symlinked interpreter."""
    current = _lexical_absolute(path)
    chain = []
    seen = set()
    for _index in range(limit + 1):
        identity = os.path.normcase(str(current))
        if identity in seen:
            raise RuntimeError("verification interpreter symlink loop: %s" % current)
        seen.add(identity)
        chain.append(current)
        if not current.is_symlink():
            if not current.exists():
                raise RuntimeError(
                    "verification interpreter symlink chain is broken: %s" % current
                )
            return chain
        target = Path(os.readlink(str(current)))
        if not target.is_absolute():
            target = current.parent / target
        current = _lexical_absolute(target)
    raise RuntimeError("verification interpreter symlink chain is too deep")


def _selected_developer_directory():
    """Resolve Apple's selected toolchain before entering the verifier sandbox."""
    if platform.system() != "Darwin":
        return None
    try:
        selected = subprocess.run(
            ["/usr/bin/xcode-select", "--print-path"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
        if selected.returncode != 0 or not selected.stdout.strip():
            return None
        directory = Path(selected.stdout.strip()).resolve(strict=True)
        return directory if directory.is_dir() else None
    except (OSError, subprocess.SubprocessError):
        return None


class VerificationRunner:
    def __init__(self, settings, store):
        self.settings = settings
        self.store = store
        self._active_container = None
        self.verified_snapshot = None

    def _task_dir(self, task):
        resolver = getattr(self.store, "attempt_path", None)
        if resolver is not None:
            path = resolver(self.settings.tasks_dir, "verification")
        else:
            path = self.settings.tasks_dir / task["id"] / "verification"
        path.mkdir(parents=True, exist_ok=True)
        return path.resolve()

    @staticmethod
    def _make_tree_read_only(root):
        root = Path(root)
        for current, directories, files in os.walk(str(root), topdown=False):
            current_path = Path(current)
            for name in files:
                candidate = current_path / name
                if not candidate.is_symlink():
                    # Removing write permission must not destroy an executable
                    # bit that is part of the accepted Git tree identity.  A
                    # blanket 0400 chmod turns 100755 entries into 100644 and
                    # makes the later verified-source identity fence reject an
                    # otherwise valid snapshot.
                    mode = stat.S_IMODE(candidate.stat().st_mode)
                    candidate.chmod((mode & ~0o222) | 0o400)
            for name in directories:
                candidate = current_path / name
                if not candidate.is_symlink():
                    mode = stat.S_IMODE(candidate.stat().st_mode)
                    candidate.chmod((mode & ~0o222) | 0o500)
            if not current_path.is_symlink():
                mode = stat.S_IMODE(current_path.stat().st_mode)
                current_path.chmod((mode & ~0o222) | 0o500)

    def _retain_verified_snapshot(self, task, isolation, output_dir, identity):
        source = Path(isolation["source"]).resolve()
        target = (Path(output_dir).resolve() / "verified-source").resolve()
        if target.exists() or target.is_symlink():
            raise RuntimeError("verified source retention path already exists")
        if not source.is_dir() or source.is_symlink():
            raise RuntimeError("isolated verifier source is unavailable")
        shutil.move(str(source), str(target))
        retained = WorkspaceManager(self.settings, self.store).verification_identity(
            target, isolation["snapshot_head"]
        )
        if retained["source_identity"] != identity["source_identity"]:
            raise RuntimeError("retained verifier source identity mismatch")
        self._make_tree_read_only(target)
        self.verified_snapshot = {
            "path": str(target),
            "reference": retained["reference"],
            "identity": retained,
        }
        self.store.update_metadata(
            task["id"],
            {
                "verified_source_path": str(target),
                "verified_source_reference": retained["reference"],
                "verified_source_identity": retained["source_identity"],
            },
        )
        self.store.add_event(
            task["id"],
            "verification.snapshot.sealed",
            {
                "path": str(target),
                "reference": retained["reference"],
                "source_identity": retained["source_identity"],
            },
        )

    def cleanup_verified_snapshot(self, snapshot=None):
        snapshot = snapshot or self.verified_snapshot
        path = (snapshot or {}).get("path") if isinstance(snapshot, dict) else snapshot
        if not path:
            return False
        target = Path(path).expanduser().resolve()
        tasks_root = self.settings.tasks_dir.resolve()
        if target.name != "verified-source" or tasks_root not in target.parents:
            raise RuntimeError("refusing to clean an untrusted verifier snapshot path")
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            for current, directories, files in os.walk(str(target), topdown=False):
                current_path = Path(current)
                for name in files:
                    candidate = current_path / name
                    if not candidate.is_symlink():
                        candidate.chmod(0o600)
                for name in directories:
                    candidate = current_path / name
                    if not candidate.is_symlink():
                        candidate.chmod(0o700)
                if not current_path.is_symlink():
                    current_path.chmod(0o700)
            shutil.rmtree(str(target))
        if self.verified_snapshot and self.verified_snapshot.get("path") == str(target):
            self.verified_snapshot = None
        return True

    def _copy_source(self, source, target, reference):
        source = Path(source).resolve()
        target = Path(target).resolve()
        try:
            target.relative_to(source)
        except ValueError:
            pass
        else:
            raise RuntimeError("verification sandbox cannot live inside its source")
        if target.exists() or target.is_symlink():
            raise RuntimeError("verification sandbox path already exists")
        target.mkdir(parents=True)
        try:
            state_relative = self.settings.home.resolve().relative_to(source)
        except ValueError:
            state_relative = None
        if reference:
            baseline = self._git_paths(
                source,
                ["git", "ls-tree", "-r", "--name-only", "-z", str(reference)],
            )
            admitted = self._git_paths(
                source,
                ["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"],
            )
            admitted = [
                relative
                for value in admitted
                for relative, repository in [git_inventory_path(source, value)]
                if not repository
            ]
            relatives = sorted(set(baseline + admitted))
        else:
            relatives = []
            for current, directories, files in os.walk(str(source), topdown=True):
                current_path = Path(current)
                relative_root = current_path.relative_to(source)
                if state_relative is not None and (
                    relative_root == state_relative
                    or state_relative in relative_root.parents
                ):
                    directories[:] = []
                    continue
                for name in list(directories):
                    relative = PurePosixPath(*relative_root.parts, name).as_posix()
                    candidate = current_path / name
                    if _secret_path(relative) or (
                        state_relative is not None
                        and candidate.resolve() == self.settings.home.resolve()
                    ):
                        directories.remove(name)
                for name in files:
                    relative = PurePosixPath(*relative_root.parts, name).as_posix()
                    if not _secret_path(relative):
                        relatives.append(relative)
                if len(relatives) > DEFAULT_MAX_FILES:
                    break
            relatives = sorted(set(relatives))
        if len(relatives) > DEFAULT_MAX_FILES:
            raise RuntimeError(
                "verification snapshot contains %d files; limit is %d"
                % (len(relatives), DEFAULT_MAX_FILES)
            )
        total_bytes = 0
        for relative in relatives:
            relative = _safe_relative(relative)
            if _secret_path(relative):
                continue
            origin = source.joinpath(*PurePosixPath(relative).parts)
            state_home = self.settings.home.resolve()
            if state_relative is not None and (
                origin == state_home or state_home in origin.parents
            ):
                continue
            if not origin.exists() and not origin.is_symlink():
                continue
            destination = target.joinpath(*PurePosixPath(relative).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if origin.is_symlink():
                payload = os.fsencode(os.readlink(str(origin)))
                destination.symlink_to(os.fsdecode(payload))
            elif origin.is_file():
                size = origin.stat().st_size
                if size > DEFAULT_MAX_FILE_BYTES:
                    raise RuntimeError(
                        "verification snapshot file exceeds %d-byte limit: %s"
                        % (DEFAULT_MAX_FILE_BYTES, relative)
                    )
                total_bytes += size
                if total_bytes > DEFAULT_MAX_TOTAL_BYTES:
                    raise RuntimeError(
                        "verification snapshot exceeds %d-byte total limit"
                        % DEFAULT_MAX_TOTAL_BYTES
                    )
                shutil.copy2(str(origin), str(destination), follow_symlinks=False)
            else:
                raise RuntimeError(
                    "unsupported verification snapshot file: %s" % relative
                )

    @staticmethod
    def _git_paths(cwd, command):
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                "verification snapshot Git command failed: %s"
                % completed.stdout.decode("utf-8", "surrogateescape")
            )
        return [
            value.decode("utf-8", "surrogateescape")
            for value in completed.stdout.split(b"\0")
            if value
        ]

    def _prepare_isolated(self, task, cwd, output_dir, reference, writable_paths):
        cwd = Path(cwd).resolve()
        root_result = _run(["git", "rev-parse", "--show-toplevel"], cwd=cwd)
        if root_result.returncode == 0:
            source_root = Path(root_result.stdout.strip()).resolve()
            try:
                relative_cwd = cwd.relative_to(source_root)
            except ValueError as exc:
                raise RuntimeError("verification cwd is outside its Git workspace") from exc
            if reference:
                resolved = _run(["git", "rev-parse", str(reference)], cwd=source_root)
                if resolved.returncode != 0 or not resolved.stdout.strip():
                    raise RuntimeError("verification baseline reference is invalid")
                reference = resolved.stdout.strip()
            else:
                head = _run(["git", "rev-parse", "HEAD"], cwd=source_root)
                reference = head.stdout.strip() if head.returncode == 0 else None
        else:
            source_root = cwd
            relative_cwd = Path(".")
            reference = None

        temporary_root = (
            Path("/private/var/tmp")
            if platform.system() == "Darwin" and Path("/private/var/tmp").is_dir()
            else None
        )
        container = Path(
            tempfile.mkdtemp(
                prefix="blacklabel-verifier-",
                dir=str(temporary_root) if temporary_root else None,
            )
        ).resolve()
        self._active_container = container
        source = container / "source"
        home = container / "home"
        temporary = container / "tmp"
        self._copy_source(source_root, source, reference)
        home.mkdir(mode=0o700)
        temporary.mkdir(mode=0o700)

        initialized = _run(["git", "init", "-q"], cwd=source)
        if initialized.returncode != 0:
            raise RuntimeError("verification snapshot Git init failed: %s" % initialized.stdout)
        tracked = (
            self._git_paths(
                source_root,
                ["git", "ls-tree", "-r", "--name-only", "-z", reference],
            )
            if reference
            else []
        )
        staged = _run(["git", "add", "-A", "--", "."], cwd=source)
        if staged.returncode != 0:
            raise RuntimeError("verification snapshot staging failed: %s" % staged.stdout)
        existing_tracked = [
            relative
            for relative in tracked
            if not _secret_path(relative)
            and (
                (source / relative).exists()
                or (source / relative).is_symlink()
            )
        ]
        for offset in range(0, len(existing_tracked), 200):
            forced = _run(
                ["git", "add", "-f", "--", *existing_tracked[offset : offset + 200]],
                cwd=source,
            )
            if forced.returncode != 0:
                raise RuntimeError("verification tracked-file staging failed: %s" % forced.stdout)
        committed = _run(
            [
                "git",
                "-c",
                "user.name=Black Label Operator",
                "-c",
                "user.email=operator@localhost",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--allow-empty",
                "-qm",
                "immutable verification input",
            ],
            cwd=source,
        )
        if committed.returncode != 0:
            raise RuntimeError("verification snapshot commit failed: %s" % committed.stdout)
        snapshot = _run(["git", "rev-parse", "HEAD"], cwd=source)
        snapshot_head = snapshot.stdout.strip()

        admitted = self._git_paths(source, ["git", "ls-files", "-z"])
        admitted_set = set(admitted)
        writable = []
        for value in sorted(set(writable_paths)):
            relative = _safe_relative(value)
            prefix = relative.rstrip("/") + "/"
            conflicts = [
                item
                for item in admitted_set
                if item == relative or item.startswith(prefix)
            ]
            if conflicts:
                raise ValueError(
                    "verification writable path overlaps accepted source: %s" % relative
                )
            destination = source.joinpath(*PurePosixPath(relative).parts)
            cursor = source
            for component in PurePosixPath(relative).parts:
                cursor = cursor / component
                if cursor.exists() or cursor.is_symlink():
                    if cursor.is_symlink() or not cursor.is_dir():
                        raise ValueError(
                            "verification writable path traverses a non-directory: %s"
                            % relative
                        )
                else:
                    cursor.mkdir()
            writable.append(destination.resolve())

        if writable:
            exclude_path = source / ".git" / "info" / "exclude"
            with exclude_path.open("a", encoding="utf-8") as handle:
                for path in writable:
                    relative = path.relative_to(source).as_posix().rstrip("/")
                    handle.write("/%s/\n" % relative)

        execution = (source / relative_cwd).resolve()
        if not execution.exists():
            execution.mkdir(parents=True)
        if not execution.is_dir():
            raise RuntimeError("verification cwd was not copied into the sandbox")
        identity = WorkspaceManager(self.settings, self.store).verification_identity(
            source, snapshot_head
        )
        return {
            "container": container.resolve(),
            "source": source.resolve(),
            "cwd": execution,
            "home": home.resolve(),
            "tmp": temporary.resolve(),
            "writable": writable,
            "snapshot_head": snapshot_head,
            "identity": identity,
            "developer_directory": _selected_developer_directory(),
        }

    @staticmethod
    def _sandbox_profile(isolation):
        if platform.system() != "Darwin" or not Path("/usr/bin/sandbox-exec").is_file():
            raise RuntimeError(
                "isolated verification requires the macOS sandbox-exec containment backend"
            )
        import json as _json

        writable = [isolation["home"], isolation["tmp"], *isolation["writable"]]
        write_filters = " ".join(
            "(subpath %s)" % _json.dumps(str(path.resolve())) for path in writable
        )
        readable = [
            isolation["source"],
            isolation["home"],
            isolation["tmp"],
            Path("/System"),
            Path("/usr"),
            Path("/bin"),
            Path("/sbin"),
            Path("/Library"),
            Path("/opt/homebrew"),
            Path("/usr/local"),
            Path("/Applications/Xcode.app"),
            Path("/private/var/select/sh"),
            Path("/private/var/db/dyld"),
            Path("/private/var/db/timezone"),
            Path("/dev"),
        ]
        virtual_env = os.environ.get("VIRTUAL_ENV")
        if virtual_env:
            readable.append(Path(virtual_env).expanduser())
        for name in ("SDKROOT", "DEVELOPER_DIR"):
            value = os.environ.get(name)
            if value:
                candidate = Path(value).expanduser()
                readable.append(candidate)
                readable.extend(
                    parent for parent in candidate.parents if parent.suffix == ".app"
                )
        developer_directory = isolation.get("developer_directory")
        if developer_directory is not None:
            readable.append(developer_directory)
            readable.extend(
                parent for parent in developer_directory.parents if parent.suffix == ".app"
            )
        interpreter_chain = _symlink_chain(sys.executable)
        interpreter = interpreter_chain[0]
        readable.extend(interpreter_chain)
        readable.extend(
            candidate.parent
            for candidate in interpreter_chain
            if candidate.is_symlink()
        )
        readable.append(interpreter.resolve(strict=True))
        for candidate in interpreter_chain:
            readable.extend(
                parent for parent in candidate.parents if parent.suffix == ".app"
            )
        for runtime_root in (
            sys.prefix,
            sys.exec_prefix,
            sys.base_prefix,
            sys.base_exec_prefix,
        ):
            candidate = _lexical_absolute(runtime_root)
            if candidate.exists():
                readable.append(candidate)
        for item in os.environ.get("PATH", "").split(os.pathsep):
            if not item:
                continue
            candidate = Path(item).expanduser()
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if resolved.name in ("bin", "sbin"):
                readable.append(resolved)
        read_filters = " ".join(
            "(subpath %s)" % _json.dumps(str(path.resolve()))
            for path in readable
            if path.exists()
        )
        shell_selection = Path("/private/var/select/sh")
        parent_literals = {Path("/"), shell_selection, *shell_selection.parents}
        for path in readable:
            if path.exists():
                lexical = _lexical_absolute(path)
                parent_literals.add(lexical)
                parent_literals.update(lexical.parents)
                parent_literals.update(path.resolve().parents)
        read_literals = " ".join(
            "(literal %s)" % _json.dumps(str(path))
            for path in sorted(parent_literals, key=lambda item: str(item))
        )
        return "\n".join(
            (
                "(version 1)",
                "(deny default)",
                "(allow file-read* %s %s (literal \"/dev/null\"))"
                % (read_filters, read_literals),
                "(allow process*)",
                "(allow sysctl-read)",
                "(allow mach-lookup)",
                "(allow ipc-posix*)",
                "(allow signal (target self))",
                "(allow file-write* %s (literal \"/dev/null\"))" % write_filters,
            )
        )

    @staticmethod
    def _sandbox_env(isolation):
        source = isolation["source"]
        environment = {}
        for name in (
            "PATH",
            "VIRTUAL_ENV",
            "SDKROOT",
            "DEVELOPER_DIR",
            "LANG",
            "LC_ALL",
            "TERM",
        ):
            value = os.environ.get(name)
            if value:
                environment[name] = value
        developer_directory = isolation.get("developer_directory")
        if developer_directory is not None:
            # Apple launchers otherwise consult /var/select inside the sandbox.
            # Pin the exact selection whose toolchain received read access.
            environment["DEVELOPER_DIR"] = str(developer_directory)
            # Run the selected developer tools directly. Apple's /usr/bin
            # launchers attempt to create lookup caches outside the sandbox.
            tool_bins = [
                developer_directory / "Toolchains/XcodeDefault.xctoolchain/usr/bin",
                developer_directory / "usr/bin",
            ]
            environment["PATH"] = os.pathsep.join(
                [str(path) for path in tool_bins if path.is_dir()]
                + [environment.get("PATH", os.defpath)]
            )
        environment.update(
            {
                "HOME": str(isolation["home"]),
                "TMPDIR": str(isolation["tmp"]),
                "TMP": str(isolation["tmp"]),
                "TEMP": str(isolation["tmp"]),
                "XDG_CACHE_HOME": str(isolation["home"] / ".cache"),
                "PIP_CACHE_DIR": str(isolation["home"] / ".cache" / "pip"),
                "npm_config_cache": str(isolation["home"] / ".cache" / "npm"),
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_ATTR_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "NO_COLOR": "1",
                "OPERATOR_VERIFICATION_SANDBOX": str(source),
            }
        )
        return environment

    def _run_unprotected(
        self,
        task,
        cwd,
        heartbeat=None,
        cancelled=None,
        isolated=False,
        reference=None,
    ):
        commands = list(task.get("verification") or [])
        results = []
        output_dir = self._task_dir(task)
        if not commands:
            summary = output_dir / "summary.json"
            digest = _write_immutable(summary, "[]\n")
            self.store.add_artifact(
                task["id"],
                "verification-summary",
                summary,
                {"sha256": digest, "bytes": summary.stat().st_size},
            )
            return [], None
        writable_paths = []
        for item in commands:
            if isinstance(item, dict):
                raw = item.get("writable_paths") or []
                if not isinstance(raw, list):
                    raise ValueError("verification writable_paths must be a list")
                writable_paths.extend(_safe_relative(str(value)) for value in raw)
        isolation = None
        execution_cwd = Path(cwd).resolve()
        if isolated:
            isolation = self._prepare_isolated(
                task,
                execution_cwd,
                output_dir,
                reference,
                writable_paths,
            )
            execution_cwd = isolation["cwd"]
            profile = self._sandbox_profile(isolation)
            child_env = self._sandbox_env(isolation)
        else:
            profile = None
            child_env = None
        for index, command in enumerate(commands, start=1):
            if isinstance(command, str):
                value = {"command": command}
            elif isinstance(command, dict):
                value = dict(command)
            else:
                raise ValueError("verification entries must be strings or objects")
            script = str(value.get("command", "")).strip()
            if not script:
                raise ValueError("verification command is empty")
            timeout = max(1, float(value.get("timeout_seconds", 1200)))
            started = time.monotonic()
            if os.name == "nt":
                command_argv = [
                    os.environ.get("COMSPEC", "cmd.exe"),
                    "/d",
                    "/s",
                    "/c",
                    script,
                ]
            else:
                shell = shutil.which("bash") or shutil.which("sh")
                if not shell:
                    raise RuntimeError("verification requires a POSIX shell")
                command_argv = (
                    [shell, "--noprofile", "--norc", "-c", script]
                    if Path(shell).name == "bash"
                    else [shell, "-c", script]
                )
            if profile is not None:
                command_argv = [
                    "/usr/bin/sandbox-exec",
                    "-p",
                    profile,
                    *command_argv,
                ]
            exact_containment = task.get("profile") == "adaptive"
            containment_dir = output_dir / (
                "command-%02d-containment" % index
            )

            def subprocess_started(
                pid, group, identity, command_index=index
            ):
                values = {
                    "active_subprocess_kind": "verification",
                    "active_subprocess_index": command_index,
                    "active_subprocess_pid": pid,
                    "active_subprocess_group_id": group,
                    "active_subprocess_identity": identity,
                }
                if exact_containment:
                    binding = CodexRunner.containment_binding(
                        containment_dir / "containment.json",
                        tasks_root=self.settings.tasks_dir,
                    )
                    if int(binding["pid"]) != int(pid):
                        raise RuntimeError(
                            "verifier containment PID does not match subprocess"
                        )
                    if binding["process_identity"] != identity:
                        raise RuntimeError(
                            "verifier containment identity does not match subprocess"
                        )
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
                        values[
                            "active_subprocess_containment_%s" % field
                        ] = binding[field]
                self.store.update_metadata(task["id"], values)

            completed = CodexRunner.run_supervised(
                command_argv,
                cwd=str(execution_cwd),
                timeout=timeout,
                heartbeat=heartbeat,
                cancelled=cancelled,
                merge_stderr=True,
                poll_seconds=self.settings.poll_seconds,
                env=child_env,
                on_start=subprocess_started,
                exact_containment=exact_containment,
                containment_dir=containment_dir if exact_containment else None,
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
                        "active_subprocess_containment_path": None,
                        "active_subprocess_containment_sha256": None,
                        "active_subprocess_containment_device": None,
                        "active_subprocess_containment_inode": None,
                        "active_subprocess_containment_bytes": None,
                        "active_subprocess_containment_mode": None,
                        "active_subprocess_containment_mtime_ns": None,
                        "active_subprocess_containment_ctime_ns": None,
                        "active_subprocess_containment_label": None,
                        "active_subprocess_containment_domain": None,
                        "active_subprocess_containment_pid": None,
                        "active_subprocess_containment_process_identity": None,
                        "active_subprocess_containment_resource_coalition_id": None,
                        "active_subprocess_containment_jetsam_coalition_id": None,
                    },
                )
            if heartbeat:
                heartbeat()
            exit_code = completed.returncode
            output = completed.stdout
            timed_out = completed.timed_out
            path = output_dir / ("%02d.log" % index)
            log_sha256 = _write_immutable(path, output)
            self.store.add_artifact(
                task["id"],
                "verification-log",
                path,
                {"sha256": log_sha256, "bytes": path.stat().st_size},
            )
            result = {
                "command": script,
                "exit_code": exit_code,
                "timed_out": timed_out,
                "cancelled": completed.cancelled,
                "termination_confirmed": completed.termination_confirmed,
                "containment_proven": bool(
                    getattr(completed, "containment_proven", False)
                ),
                "containment_manifest": getattr(
                    completed, "containment_manifest", None
                ),
                "leaked_descendants": bool(
                    getattr(completed, "leaked_descendants", False)
                ),
                "duration_seconds": round(time.monotonic() - started, 3),
                "log": str(path),
                "log_sha256": log_sha256,
                "log_bytes": path.stat().st_size,
                "passed": (
                    exit_code == 0
                    and not timed_out
                    and not completed.cancelled
                    and completed.termination_confirmed
                    and not getattr(completed, "leaked_descendants", False)
                    and (
                        not exact_containment
                        or getattr(completed, "containment_proven", False)
                    )
                ),
            }
            results.append(result)
            self.store.add_event(task["id"], "verification.completed", result)
            if not result["passed"]:
                break
        if isolation is not None:
            identity_after = WorkspaceManager(
                self.settings, self.store
            ).verification_identity(
                isolation["source"], isolation["snapshot_head"]
            )
            if (
                identity_after["source_identity"]
                != isolation["identity"]["source_identity"]
            ):
                mutation = {
                    "command": "<immutable-source-fence>",
                    "exit_code": 1,
                    "timed_out": False,
                    "cancelled": False,
                    "termination_confirmed": True,
                    "leaked_descendants": False,
                    "duration_seconds": 0.0,
                    "log": None,
                    "passed": False,
                    "error": "verification changed accepted source bytes",
                }
                results.append(mutation)
                self.store.add_event(
                    task["id"], "verification.source_mutation_rejected", mutation
                )
        passed = bool(results) and all(item["passed"] for item in results)
        if isolation is not None and passed:
            self._retain_verified_snapshot(
                task,
                isolation,
                output_dir,
                identity_after,
            )
        summary = output_dir / "summary.json"
        summary_sha256 = _write_immutable(
            summary,
            json.dumps(results, indent=2, sort_keys=True),
        )
        self.store.add_artifact(
            task["id"],
            "verification-summary",
            summary,
            {"sha256": summary_sha256, "bytes": summary.stat().st_size},
        )
        if isolation is not None:
            shutil.rmtree(str(isolation["container"]))
            self._active_container = None
        if not results:
            return results, None
        return results, passed

    def run(
        self,
        task,
        cwd,
        heartbeat=None,
        cancelled=None,
        isolated=False,
        reference=None,
    ):
        self.verified_snapshot = None
        try:
            return self._run_unprotected(
                task,
                cwd,
                heartbeat=heartbeat,
                cancelled=cancelled,
                isolated=isolated,
                reference=reference,
            )
        finally:
            if isolated and self._active_container is not None:
                container = self._active_container
                if container.is_symlink():
                    container.unlink()
                elif container.exists():
                    shutil.rmtree(str(container))
                self._active_container = None
