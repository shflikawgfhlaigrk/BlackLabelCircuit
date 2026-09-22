import hashlib
import fcntl
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path, PurePosixPath

WORKSPACE_ARTIFACT_SCHEMA = "black-label-operator/workspace-artifacts-v1"
WORKSPACE_INPUT_SCHEMA = "black-label-operator/workspace-input-v1"

# A workspace snapshot is evidence, not a backup product. These fixed ceilings keep
# an accidentally selected repository, generated tree, or model cache from filling
# the Operator state directory.
DEFAULT_MAX_FILES = 4096
DEFAULT_MAX_FILE_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 128 * 1024 * 1024
DEFAULT_MAX_PATCH_BYTES = 128 * 1024 * 1024
DEFAULT_WORKTREE_TTL_SECONDS = 24 * 60 * 60
DEFAULT_JANITOR_SCAN_LIMIT = 128

_EXCLUDED_COMPONENTS = {
    ".git",
    ".blacklabel-operator",
    ".aws",
    ".azure",
    ".operator",
    ".operator-state",
    ".codex",
    ".cache",
    ".gnupg",
    ".gradle",
    ".kube",
    ".mypy_cache",
    ".nox",
    ".pytest_cache",
    ".ruff_cache",
    ".terraform",
    ".tox",
    ".venv",
    ".ssh",
    "__pycache__",
    "node_modules",
    "venv",
}
_EXCLUDED_NAMES = {
    ".ds_store",
    ".git-credentials",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".envrc",
    "authorized_keys",
    "credentials.json",
    "kubeconfig",
    "secrets.json",
    "service-account.json",
    "service_account.json",
}
_EXCLUDED_SUFFIXES = {
    ".db",
    ".db-shm",
    ".db-wal",
    ".key",
    ".p12",
    ".pem",
    ".pfx",
    ".pyc",
    ".sqlite",
    ".sqlite-shm",
    ".sqlite-wal",
    ".sqlite3",
    ".secret",
    ".secrets",
    ".token",
}
_VERIFIED_EXCLUDED_COMPONENTS = {
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


def _git(cwd, *args, check=False, env=None, input_text=None):
    process_env = os.environ.copy()
    if env:
        process_env.update({str(key): str(value) for key, value in env.items()})
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        env=process_env,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="surrogateescape",
        check=check,
    )


def _git_root(cwd):
    completed = _git(cwd, "rev-parse", "--show-toplevel")
    if completed.returncode != 0:
        return None
    return Path(completed.stdout.strip()).resolve()


def _sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_bytes(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")


def _atomic_json(path, payload):
    path = Path(path)
    temporary = path.with_name(".%s.%d.tmp" % (path.name, os.getpid()))
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(str(temporary), str(path))


def _atomic_bytes(path, payload):
    path = Path(path)
    temporary = path.with_name(".%s.%d.tmp" % (path.name, os.getpid()))
    with temporary.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(str(temporary), str(path))


def _relative_path(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise RuntimeError("workspace artifact contains an invalid path")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        raise RuntimeError("workspace artifact contains an unsafe path: %r" % value)
    normalized = str(pure)
    if normalized != value:
        raise RuntimeError("workspace artifact path is not canonical: %r" % value)
    return normalized


def _join_safe(root, relative, create_parents=False):
    root = Path(root).resolve()
    relative = _relative_path(relative)
    current = root
    parts = PurePosixPath(relative).parts
    for component in parts[:-1]:
        current = current / component
        if current.exists() or current.is_symlink():
            if current.is_symlink() or not current.is_dir():
                raise RuntimeError(
                    "workspace path traverses a non-directory: %s" % current
                )
        elif create_parents:
            current.mkdir()
        else:
            break
    destination = root.joinpath(*parts)
    try:
        destination.relative_to(root)
    except ValueError as exc:
        raise RuntimeError("workspace path escapes its root") from exc
    return destination


def _exclusion_reason(relative):
    pure = PurePosixPath(_relative_path(relative))
    lowered = [part.lower() for part in pure.parts]
    if any(part in _EXCLUDED_COMPONENTS or part.endswith(".egg-info") for part in lowered):
        return "cache-or-state"
    name = lowered[-1]
    if name == ".env" or name.startswith(".env."):
        return "secret"
    if name in _EXCLUDED_NAMES:
        return "secret"
    if name.startswith("id_rsa") or name.startswith("id_ed25519"):
        return "secret"
    if any(marker in name for marker in ("credential", "private-key", "private_key")):
        return "secret"
    if any(name.endswith(suffix) for suffix in _EXCLUDED_SUFFIXES):
        return "secret-or-state"
    return None


def _verified_exclusion_reason(relative):
    """Match the verifier's admitted-byte boundary, including tracked caches."""
    pure = PurePosixPath(_relative_path(relative))
    lowered = [part.lower() for part in pure.parts]
    if any(part in _VERIFIED_EXCLUDED_COMPONENTS for part in lowered):
        return "secret-or-state"
    reason = _exclusion_reason(relative)
    return reason if reason in ("secret", "secret-or-state") else None


def _name_status(cwd, reference, env=None):
    completed = _git(
        cwd,
        "diff",
        "--name-status",
        "-z",
        "--no-renames",
        reference,
        "--",
        env=env,
    )
    if completed.returncode != 0:
        raise RuntimeError("git diff failed: %s" % completed.stdout)
    values = completed.stdout.split("\0")
    if values and values[-1] == "":
        values.pop()
    if len(values) % 2:
        raise RuntimeError("git returned a malformed changed-path list")
    result = []
    for index in range(0, len(values), 2):
        status_value = values[index]
        relative = _relative_path(values[index + 1])
        status_code = status_value[:1]
        if status_code in ("R", "C"):
            raise RuntimeError("git rename detection was unexpectedly enabled")
        result.append((status_code, relative))
    return result


def _cached_name_status(cwd, reference, env=None):
    completed = _git(
        cwd,
        "diff",
        "--cached",
        "--name-status",
        "-z",
        "--no-renames",
        reference,
        "--",
        env=env,
    )
    if completed.returncode != 0:
        raise RuntimeError("git cached diff failed: %s" % completed.stdout)
    values = completed.stdout.split("\0")
    if values and values[-1] == "":
        values.pop()
    if len(values) % 2:
        raise RuntimeError("git returned a malformed cached changed-path list")
    return [
        (values[index][:1], _relative_path(values[index + 1]))
        for index in range(0, len(values), 2)
    ]


def git_inventory_path(cwd, value):
    """Decode Git's directory marker without weakening artifact path checks.

    ls-files collapses an untracked nested repository to ``path/``, including
    repositories with no commits yet. It is a separate project, not a file to
    copy into the outer repository's snapshot.
    """
    if not value.endswith("/"):
        return _relative_path(value), False
    relative = _relative_path(value[:-1])
    path = _join_safe(cwd, relative)
    if path.is_symlink() or not path.is_dir() or _git_root(path) != path:
        raise RuntimeError("unexpected Git directory entry: %r" % value)
    return relative, True


def _untracked(cwd, env=None):
    completed = _git(
        cwd,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        env=env,
    )
    if completed.returncode != 0:
        raise RuntimeError("git untracked-file scan failed: %s" % completed.stdout)
    files, repositories = [], []
    for value in completed.stdout.split("\0"):
        if value:
            relative, repository = git_inventory_path(cwd, value)
            (repositories if repository else files).append(relative)
    return sorted(set(files)), sorted(set(repositories))


class WorkspaceManager:
    def __init__(
        self,
        settings,
        store,
        max_files=DEFAULT_MAX_FILES,
        max_file_bytes=DEFAULT_MAX_FILE_BYTES,
        max_total_bytes=DEFAULT_MAX_TOTAL_BYTES,
        max_patch_bytes=DEFAULT_MAX_PATCH_BYTES,
    ):
        self.settings = settings
        self.store = store
        self.max_files = int(max_files)
        self.max_file_bytes = int(max_file_bytes)
        self.max_total_bytes = int(max_total_bytes)
        self.max_patch_bytes = int(max_patch_bytes)
        if min(
            self.max_files,
            self.max_file_bytes,
            self.max_total_bytes,
            self.max_patch_bytes,
        ) <= 0:
            raise ValueError("workspace evidence limits must be positive")

    def _task_dir(self, task):
        resolver = getattr(self.store, "attempt_path", None)
        if resolver is not None:
            path = resolver(self.settings.tasks_dir, "workspace")
        else:
            path = self.settings.tasks_dir / task["id"]
        path.mkdir(parents=True, exist_ok=True)
        return path.resolve()

    def _attempt_generation(self):
        generation = getattr(self.store, "generation", None)
        return int(generation) if generation is not None else None

    def _record_artifact(self, task, kind, path, metadata=None):
        path = Path(path).resolve()
        details = dict(metadata or {})
        generation = self._attempt_generation()
        if generation is not None:
            details.setdefault("lease_generation", generation)
        details.update(
            {
                "bytes": path.stat().st_size,
                "sha256": _sha256_file(path),
            }
        )
        self.store.add_artifact(task["id"], kind, path, details)
        return details

    def _remove_worktree(self, origin, target, branch=None):
        """Remove one Operator-created worktree and its private branch."""
        worktrees_root = Path(self.settings.worktrees_dir).resolve()
        target = Path(target).resolve()
        if target == worktrees_root or worktrees_root not in target.parents:
            raise RuntimeError("refusing to clean a worktree outside Operator state")
        if target.exists() or target.is_symlink():
            detected = _git(target, "branch", "--show-current")
            detected_branch = detected.stdout.strip() if detected.returncode == 0 else ""
            expected_branch = str(branch or detected_branch)
            if not expected_branch.startswith("operator/task-"):
                raise RuntimeError("refusing to clean a non-Operator worktree")
            if detected_branch and detected_branch != expected_branch:
                raise RuntimeError("worktree branch identity changed before cleanup")
            origin = Path(origin).resolve() if origin else None
            if origin is not None and origin.is_dir() and _git_root(origin) == origin:
                removed = _git(
                    origin,
                    "worktree",
                    "remove",
                    "--force",
                    str(target),
                )
            else:
                removed = _git(
                    target,
                    "worktree",
                    "remove",
                    "--force",
                    str(target),
                )
            if removed.returncode != 0 and (target.exists() or target.is_symlink()):
                raise RuntimeError("git worktree cleanup failed: %s" % removed.stdout)
        if target.exists() or target.is_symlink():
            if target.is_symlink() or target.is_file():
                target.unlink()
            else:
                shutil.rmtree(str(target))
        if branch and origin:
            branch_ref = "refs/heads/%s" % branch
            if _git(origin, "show-ref", "--verify", "--quiet", branch_ref).returncode == 0:
                deleted = _git(origin, "branch", "-D", branch)
                if deleted.returncode != 0:
                    raise RuntimeError(
                        "worktree branch cleanup failed: %s" % deleted.stdout
                    )

    def cleanup(self, task, reason="terminal"):
        """Clean a prepared isolated worktree after its terminal capture."""
        current = self.store.get(task["id"]) or task
        if (current.get("isolation") or "shared") != "worktree":
            return {"removed": False, "reason": "shared-workspace"}
        metadata = current.get("metadata") or {}
        target_value = metadata.get("worktree_root")
        origin_value = metadata.get("origin_git_root")
        branch = metadata.get("worktree_branch")
        if not target_value:
            return {"removed": False, "reason": "no-worktree"}
        generation = self._attempt_generation()
        prepared_generation = metadata.get("workspace_lease_generation")
        if (
            generation is not None
            and prepared_generation is not None
            and int(prepared_generation) != generation
        ):
            raise RuntimeError("refusing to clean another lease generation's worktree")
        target = Path(target_value).resolve()
        existed = target.exists() or target.is_symlink()
        self._remove_worktree(origin_value, target, branch=branch)
        cleaned_at = time.time()
        self.store.update_metadata(
            current["id"],
            {
                "workspace_prepared": False,
                "worktree_cleaned_at": cleaned_at,
                "worktree_cleanup_reason": str(reason),
            },
        )
        self.store.add_event(
            current["id"],
            "workspace.cleaned",
            {
                "path": str(target),
                "reason": str(reason),
                "removed": bool(existed),
            },
        )
        return {"removed": bool(existed), "path": str(target), "reason": str(reason)}

    def _remove_verified_snapshot(self, target):
        tasks_root = Path(self.settings.tasks_dir).resolve()
        target = Path(target)
        lexical = Path(os.path.abspath(str(target)))
        if (
            lexical.name != "verified-source"
            or lexical.parent.name != "verification"
            or not lexical.parent.parent.name.startswith("generation-")
            or tasks_root not in lexical.parents
        ):
            raise RuntimeError("refusing to clean an untrusted verifier snapshot path")
        if lexical.is_symlink():
            lexical.unlink()
            return
        if not lexical.exists():
            return
        resolved = lexical.resolve()
        if tasks_root not in resolved.parents:
            raise RuntimeError("verified snapshot resolves outside task evidence")
        for current, directories, _files in os.walk(str(resolved), topdown=False):
            current_path = Path(current)
            # File permissions do not gate unlink and chmod on a hard link would
            # affect an inode outside this tree. Only directories need restoring.
            for name in directories:
                candidate = current_path / name
                if not candidate.is_symlink():
                    candidate.chmod(0o700)
            if not current_path.is_symlink():
                current_path.chmod(0o700)
        shutil.rmtree(str(resolved))

    def _verified_snapshot_candidates(self):
        tasks_root = Path(self.settings.tasks_dir).resolve()
        if not tasks_root.is_dir():
            return
        for task_dir in sorted(tasks_root.iterdir(), key=lambda path: path.name):
            if task_dir.is_symlink() or not task_dir.is_dir():
                continue
            for generation_dir in sorted(
                task_dir.glob("generation-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"),
                key=lambda path: path.name,
            ):
                if generation_dir.is_symlink() or not generation_dir.is_dir():
                    continue
                target = generation_dir / "verification" / "verified-source"
                if target.exists() or target.is_symlink():
                    yield task_dir.name, generation_dir.name, target

    def janitor(
        self,
        now=None,
        ttl_seconds=DEFAULT_WORKTREE_TTL_SECONDS,
        max_entries=DEFAULT_JANITOR_SCAN_LIMIT,
    ):
        """Bounded cleanup for stale Operator worktrees left by hard crashes."""
        ttl_seconds = float(ttl_seconds)
        max_entries = int(max_entries)
        if ttl_seconds < 0 or max_entries <= 0:
            raise ValueError("worktree janitor bounds must be positive")
        now = float(time.time() if now is None else now)
        root = Path(self.settings.worktrees_dir).resolve()
        root.mkdir(parents=True, exist_ok=True)
        candidates = []
        for path in root.iterdir():
            try:
                modified = path.lstat().st_mtime
            except OSError:
                continue
            candidates.append((modified, path))
        candidates.sort(key=lambda item: (item[0], item[1].name))
        catalog = getattr(self.store, "_store", self.store)
        removed = []
        verified_removed = []
        scanned = 0
        for modified, target in candidates:
            if scanned >= max_entries:
                break
            scanned += 1
            if now - modified < ttl_seconds:
                continue
            if target.is_symlink() or not target.is_dir():
                continue
            task = catalog.get(target.name)
            if task is not None and task.get("state") not in (
                "succeeded",
                "failed",
                "cancelled",
                "blocked",
            ):
                continue
            detected = _git(target, "branch", "--show-current")
            branch = detected.stdout.strip() if detected.returncode == 0 else ""
            if not branch.startswith("operator/task-"):
                continue
            metadata = (task or {}).get("metadata") or {}
            origin = metadata.get("origin_git_root")
            if not origin:
                common = _git(target, "rev-parse", "--git-common-dir")
                if common.returncode != 0:
                    continue
                common_path = Path(common.stdout.strip())
                if not common_path.is_absolute():
                    common_path = (target / common_path).resolve()
                origin = common_path.parent
            self._remove_worktree(origin, target, branch=branch)
            removed.append(str(target))
        terminal_states = {"succeeded", "failed", "cancelled", "blocked"}
        for task_id, generation_name, target in self._verified_snapshot_candidates():
            if scanned >= max_entries:
                break
            scanned += 1
            try:
                modified = target.lstat().st_mtime
            except OSError:
                continue
            if now - modified < ttl_seconds:
                continue
            generation = int(generation_name.split("-", 1)[1])
            task = catalog.get(task_id)
            eligible = task is None or task.get("state") in terminal_states
            if task is not None and task.get("state") == "queued":
                eligible = True
            if task is not None and task.get("state") == "running":
                eligible = generation < int(task.get("lease_generation") or 0)
            if not eligible:
                continue
            self._remove_verified_snapshot(target)
            verified_removed.append(str(target))
        return {
            "scanned": scanned,
            "removed": removed,
            "verified_removed": verified_removed,
        }

    def checkpoint(self, task, cwd, name):
        cwd = Path(cwd).resolve()
        root = _git_root(cwd)
        payload = {
            "name": name,
            "created_at": time.time(),
            "cwd": str(cwd),
            "git_root": str(root or ""),
            "head": None,
            "status": None,
        }
        if root:
            head = _git(root, "rev-parse", "HEAD")
            status_result = _git(
                root, "status", "--porcelain=v1", "--untracked-files=all"
            )
            payload["head"] = head.stdout.strip() if head.returncode == 0 else None
            payload["status"] = status_result.stdout
            payload["status_sha256"] = _sha256_bytes(
                status_result.stdout.encode("utf-8", "surrogateescape")
            )
        path = self._task_dir(task) / ("checkpoint-%s.json" % name)
        _atomic_json(path, payload)
        self._record_artifact(task, "checkpoint", path, {"name": name})
        return payload

    def verification_identity(self, cwd, reference):
        """Hash accepted source bytes without persisting sensitive workspace data.

        Tracked changes and non-ignored untracked files are included. Ignored build
        outputs may change during deterministic verification, but source changes
        cannot silently become part of an accepted executor result.
        """
        cwd = Path(cwd).resolve()
        root = _git_root(cwd)
        if root is None:
            raise RuntimeError("verification source fencing requires a git repository")
        resolved = _git(root, "rev-parse", str(reference))
        if resolved.returncode != 0 or not resolved.stdout.strip():
            raise RuntimeError(
                "verification source reference is invalid: %s" % resolved.stdout
            )
        descriptor, index_name = tempfile.mkstemp(
            prefix="verification-index-", dir=str(self.settings.home)
        )
        os.close(descriptor)
        index_path = Path(index_name)
        index_path.unlink()
        env = {
            "GIT_INDEX_FILE": str(index_path),
            "GIT_WORK_TREE": str(root),
        }
        try:
            loaded = _git(root, "read-tree", resolved.stdout.strip(), env=env)
            if loaded.returncode != 0:
                raise RuntimeError(
                    "verification baseline index failed: %s" % loaded.stdout
                )
            # Read from the fresh baseline index. Mutable assume-unchanged and
            # skip-worktree bits in the task's own index therefore cannot hide bytes.
            untracked, repositories = _untracked(root, env=env)
            exclusions = [":(top,exclude,literal)%s" % path for path in repositories]
            staged = _git(root, "add", "-A", "--", ".", *exclusions, env=env)
            if staged.returncode != 0:
                raise RuntimeError(
                    "verification source staging failed: %s" % staged.stdout
                )
            changed = _git(
                root,
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                resolved.stdout.strip(),
                "--",
                env=env,
            )
            if changed.returncode != 0:
                raise RuntimeError(
                    "verification source diff failed: %s" % changed.stdout
                )
        finally:
            if index_path.exists() or index_path.is_symlink():
                index_path.unlink()
        changed_bytes = changed.stdout.encode("utf-8", "surrogateescape")
        if len(changed_bytes) > self.max_patch_bytes:
            raise RuntimeError(
                "verification source patch exceeds %d-byte limit"
                % self.max_patch_bytes
            )
        if len(untracked) > self.max_files:
            raise RuntimeError(
                "verification source contains %d untracked files; limit is %d"
                % (len(untracked), self.max_files)
            )
        digest = hashlib.sha256()
        digest.update(resolved.stdout.strip().encode("ascii") + b"\0")
        digest.update(changed_bytes)
        digest.update(_canonical_bytes({"nested_repositories": repositories}))
        total_bytes = 0
        for relative in untracked:
            path = _join_safe(root, relative)
            before = path.lstat()
            if stat.S_ISLNK(before.st_mode):
                payload = os.fsencode(os.readlink(str(path)))
                kind = b"symlink"
            elif stat.S_ISREG(before.st_mode):
                if before.st_size > self.max_file_bytes:
                    raise RuntimeError(
                        "verification source file exceeds %d-byte limit: %s"
                        % (self.max_file_bytes, relative)
                    )
                payload = path.read_bytes()
                kind = b"regular"
            else:
                raise RuntimeError(
                    "unsupported verification source file type: %s" % relative
                )
            after = path.lstat()
            if (
                before.st_ino != after.st_ino
                or before.st_size != after.st_size
                or before.st_mtime_ns != after.st_mtime_ns
            ):
                raise RuntimeError(
                    "verification source changed during fencing: %s" % relative
                )
            total_bytes += len(payload)
            if total_bytes > self.max_total_bytes:
                raise RuntimeError(
                    "verification source exceeds %d-byte total limit"
                    % self.max_total_bytes
                )
            digest.update(relative.encode("utf-8", "surrogateescape") + b"\0")
            digest.update(kind + b"\0")
            digest.update(str(stat.S_IMODE(before.st_mode)).encode("ascii") + b"\0")
            digest.update(hashlib.sha256(payload).digest())
        return {
            "reference": resolved.stdout.strip(),
            "source_identity": digest.hexdigest(),
            "untracked_files": len(untracked),
            "untracked_bytes": total_bytes,
        }

    def _read_entry(self, root, status_code, relative, snapshot_root, category):
        source = _join_safe(root, relative)
        if status_code == "D" or (not source.exists() and not source.is_symlink()):
            return {
                "path": relative,
                "category": category,
                "status": "D",
                "file_type": "deleted",
                "mode": None,
                "bytes": 0,
                "sha256": None,
            }

        before = source.lstat()
        if stat.S_ISLNK(before.st_mode):
            data = os.fsencode(os.readlink(str(source)))
            file_type = "symlink"
            git_mode = "120000"
        elif stat.S_ISREG(before.st_mode):
            if before.st_size > self.max_file_bytes:
                raise RuntimeError(
                    "workspace file exceeds %d-byte limit: %s"
                    % (self.max_file_bytes, relative)
                )
            data = source.read_bytes()
            file_type = "regular"
            git_mode = "100755" if before.st_mode & stat.S_IXUSR else "100644"
        else:
            raise RuntimeError("unsupported workspace file type: %s" % relative)
        after = source.lstat()
        if (
            before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise RuntimeError("workspace file changed during snapshot: %s" % relative)
        if len(data) > self.max_file_bytes:
            raise RuntimeError(
                "workspace file exceeds %d-byte limit: %s"
                % (self.max_file_bytes, relative)
            )
        digest = _sha256_bytes(data)
        entry = {
            "path": relative,
            "category": category,
            "status": status_code,
            "file_type": file_type,
            "mode": git_mode,
            "bytes": len(data),
            "sha256": digest,
        }
        if snapshot_root is not None:
            blob_name = "%s-%s.blob" % (
                _sha256_bytes(relative.encode("utf-8", "surrogateescape")),
                digest,
            )
            blob_path = (Path(snapshot_root) / "blobs" / blob_name).resolve()
            blob_path.parent.mkdir(parents=True, exist_ok=True)
            _atomic_bytes(blob_path, data)
            entry["blob"] = str(blob_path.relative_to(self._task_dir_root(snapshot_root)))
        return entry

    @staticmethod
    def _task_dir_root(snapshot_root):
        snapshot_root = Path(snapshot_root).resolve()
        return snapshot_root.parent

    def _capture_state(self, root, reference, snapshot_root=None, env=None):
        root = Path(root).resolve()
        changed = _name_status(root, reference, env=env)
        untracked, repositories = _untracked(root, env=env)
        candidates = [(status_code, relative, "tracked") for status_code, relative in changed]
        candidates.extend(("A", relative, "untracked") for relative in untracked)
        candidates.sort(key=lambda item: (item[1], item[2]))
        if len(candidates) > self.max_files:
            raise RuntimeError(
                "workspace contains %d changed files; limit is %d"
                % (len(candidates), self.max_files)
            )

        entries = []
        excluded = [
            {"path": relative, "category": "untracked", "status": "A",
             "reason": _exclusion_reason(relative) or "nested-repository"}
            for relative in repositories
        ]
        total_bytes = 0
        for status_code, relative, category in candidates:
            reason = _exclusion_reason(relative)
            if reason:
                excluded.append(
                    {
                        "path": relative,
                        "category": category,
                        "status": status_code,
                        "reason": reason,
                    }
                )
                continue
            entry = self._read_entry(
                root,
                status_code,
                relative,
                snapshot_root,
                category,
            )
            total_bytes += int(entry["bytes"])
            if total_bytes > self.max_total_bytes:
                raise RuntimeError(
                    "workspace snapshot exceeds %d-byte total limit"
                    % self.max_total_bytes
                )
            entries.append(entry)

        head = _git(root, "rev-parse", reference, env=env)
        if head.returncode != 0:
            raise RuntimeError("git reference resolution failed: %s" % head.stdout)
        identity_entries = [
            {key: value for key, value in entry.items() if key != "blob"}
            for entry in entries
        ]
        identity = {
            "reference": head.stdout.strip(),
            "entries": identity_entries,
            # Excluded bytes never enter an artifact or the apply contract. Their
            # path/status still records why the task did not receive them.
            "excluded": excluded,
        }
        return {
            "reference": head.stdout.strip(),
            "source_identity": _sha256_bytes(_canonical_bytes(identity)),
            "entries": entries,
            "excluded": excluded,
            "files": len(entries),
            "bytes": total_bytes,
        }

    def _capture_full_snapshot(self, root, snapshot_root):
        """Capture every admitted byte from an immutable verifier source copy."""
        root = Path(root).resolve()
        listed = _git(
            root,
            "ls-files",
            "-c",
            "-o",
            "--exclude-standard",
            "-z",
        )
        if listed.returncode != 0:
            raise RuntimeError(
                "verified source inventory failed: %s" % listed.stdout
            )
        candidates = []
        excluded = []
        for value in sorted(set(listed.stdout.split("\0"))):
            if not value:
                continue
            relative, repository = git_inventory_path(root, value)
            reason = _verified_exclusion_reason(relative) or (
                "nested-repository" if repository else None
            )
            if reason:
                excluded.append(
                    {
                        "path": relative,
                        "category": "verified",
                        "status": "excluded",
                        "reason": reason,
                    }
                )
                continue
            candidates.append(relative)
            if len(candidates) > self.max_files:
                raise RuntimeError(
                    "verified source contains more than %d files" % self.max_files
                )
        entries = []
        total_bytes = 0
        for relative in sorted(candidates):
            entry = self._read_entry(
                root,
                "A",
                relative,
                snapshot_root,
                "verified",
            )
            total_bytes += int(entry["bytes"])
            if total_bytes > self.max_total_bytes:
                raise RuntimeError(
                    "verified source snapshot exceeds %d-byte total limit"
                    % self.max_total_bytes
                )
            entries.append(entry)
        identity_entries = [
            {key: value for key, value in entry.items() if key != "blob"}
            for entry in entries
        ]
        identity = {"entries": identity_entries}
        return {
            "content_identity": _sha256_bytes(_canonical_bytes(identity)),
            "entries": entries,
            "excluded": excluded,
            "files": len(entries),
            "bytes": total_bytes,
        }

    def _index_verified_snapshot(self, root, env, baseline_head, snapshot, task_dir):
        listed = _git(root, "ls-tree", "-r", "--name-only", "-z", baseline_head)
        if listed.returncode != 0:
            raise RuntimeError("verified baseline listing failed: %s" % listed.stdout)
        baseline_paths = {
            _relative_path(value)
            for value in listed.stdout.split("\0")
            if value and not _verified_exclusion_reason(value)
        }
        final_entries = {entry["path"]: entry for entry in snapshot["entries"]}
        for relative in sorted(baseline_paths - set(final_entries)):
            updated = _git(
                root,
                "update-index",
                "--force-remove",
                "--",
                relative,
                env=env,
            )
            if updated.returncode != 0:
                raise RuntimeError(
                    "verified deletion index update failed: %s" % updated.stdout
                )
        for relative, entry in sorted(final_entries.items()):
            blob = self._verify_blob(task_dir, entry)
            hashed = _git(root, "hash-object", "-w", str(blob), env=env)
            if hashed.returncode != 0:
                raise RuntimeError("verified blob import failed: %s" % hashed.stdout)
            updated = _git(
                root,
                "update-index",
                "--add",
                "--cacheinfo",
                entry["mode"],
                hashed.stdout.strip(),
                relative,
                env=env,
            )
            if updated.returncode != 0:
                raise RuntimeError(
                    "verified snapshot index update failed: %s" % updated.stdout
                )
        changes = []
        for status_code, relative in _cached_name_status(root, baseline_head, env=env):
            entry = final_entries.get(relative)
            if entry is None:
                changes.append(
                    {
                        "path": relative,
                        "category": "tracked",
                        "status": "D",
                        "file_type": "deleted",
                        "mode": None,
                        "bytes": 0,
                        "sha256": None,
                    }
                )
                continue
            item = dict(entry)
            item["status"] = status_code
            item["category"] = (
                "tracked" if relative in baseline_paths else "untracked"
            )
            changes.append(item)
        return changes

    def _write_input_snapshot(self, task, root, head):
        task_dir = self._task_dir(task)
        snapshot_root = task_dir / "input"
        snapshot_root.mkdir(parents=True, exist_ok=True)
        captured = self._capture_state(
            root,
            head,
            snapshot_root=snapshot_root,
        )
        payload = {
            "schema": WORKSPACE_INPUT_SCHEMA,
            "task_id": task["id"],
            "created_at": time.time(),
            "git_root": str(Path(root).resolve()),
            "base_head": head,
            "source_identity": captured["source_identity"],
            "files": captured["files"],
            "bytes": captured["bytes"],
            "entries": captured["entries"],
            "excluded": captured["excluded"],
            "limits": {
                "max_files": self.max_files,
                "max_file_bytes": self.max_file_bytes,
                "max_total_bytes": self.max_total_bytes,
                "max_patch_bytes": self.max_patch_bytes,
            },
        }
        manifest_path = task_dir / "workspace-input.json"
        _atomic_json(manifest_path, payload)
        details = self._record_artifact(
            task,
            "workspace-input-manifest",
            manifest_path,
            {
                "source_identity": captured["source_identity"],
                "base_head": head,
                "files": captured["files"],
            },
        )
        return payload, manifest_path, details["sha256"]

    def _verify_blob(self, task_dir, entry):
        relative = entry.get("blob")
        if not relative:
            raise RuntimeError("workspace snapshot entry is missing its blob")
        blob = _join_safe(task_dir, relative)
        if not blob.is_file() or blob.is_symlink():
            raise RuntimeError("workspace snapshot blob is missing: %s" % relative)
        if blob.stat().st_size != int(entry["bytes"]):
            raise RuntimeError("workspace snapshot blob size mismatch: %s" % relative)
        if _sha256_file(blob) != entry["sha256"]:
            raise RuntimeError("workspace snapshot blob hash mismatch: %s" % relative)
        return blob

    def _create_baseline(self, task, root, head, input_payload):
        task_dir = self._task_dir(task)
        index_path = task_dir / "baseline.index"
        if index_path.exists() or index_path.is_symlink():
            index_path.unlink()
        env = {
            "GIT_INDEX_FILE": str(index_path),
            "GIT_WORK_TREE": str(Path(root).resolve()),
        }
        loaded = _git(root, "read-tree", head, env=env)
        if loaded.returncode != 0:
            raise RuntimeError("baseline index creation failed: %s" % loaded.stdout)
        for entry in input_payload["entries"]:
            relative = _relative_path(entry["path"])
            if entry["file_type"] == "deleted":
                updated = _git(
                    root,
                    "update-index",
                    "--force-remove",
                    "--",
                    relative,
                    env=env,
                )
            else:
                blob_path = self._verify_blob(task_dir, entry)
                hashed = _git(root, "hash-object", "-w", str(blob_path), env=env)
                if hashed.returncode != 0:
                    raise RuntimeError("baseline blob import failed: %s" % hashed.stdout)
                updated = _git(
                    root,
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    entry["mode"],
                    hashed.stdout.strip(),
                    relative,
                    env=env,
                )
            if updated.returncode != 0:
                raise RuntimeError("baseline index update failed: %s" % updated.stdout)
        tree = _git(root, "write-tree", env=env)
        if tree.returncode != 0:
            raise RuntimeError("baseline tree creation failed: %s" % tree.stdout)
        committed = _git(
            root,
            "-c",
            "user.name=Black Label Operator",
            "-c",
            "user.email=operator@localhost",
            "-c",
            "commit.gpgsign=false",
            "commit-tree",
            tree.stdout.strip(),
            "-p",
            head,
            env=env,
            input_text="Operator input snapshot %s\n" % task["id"],
        )
        if committed.returncode != 0:
            raise RuntimeError("baseline commit creation failed: %s" % committed.stdout)
        return committed.stdout.strip()

    def _overlay_input(self, task, target, input_payload):
        task_dir = self._task_dir(task)
        for entry in input_payload["entries"]:
            destination = _join_safe(target, entry["path"], create_parents=True)
            if entry["file_type"] == "deleted":
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                elif destination.exists():
                    raise RuntimeError(
                        "refusing to replace workspace directory: %s" % destination
                    )
                continue
            blob = self._verify_blob(task_dir, entry)
            if destination.exists() or destination.is_symlink():
                if destination.is_dir() and not destination.is_symlink():
                    raise RuntimeError(
                        "refusing to replace workspace directory: %s" % destination
                    )
                destination.unlink()
            if entry["file_type"] == "symlink":
                destination.symlink_to(os.fsdecode(blob.read_bytes()))
            else:
                _atomic_bytes(destination, blob.read_bytes())
                os.chmod(destination, int(entry["mode"], 8) & 0o777)

    def prepare(self, task):
        current = self.store.get(task["id"]) or task
        metadata = current.get("metadata") or {}
        origin = Path(current["cwd"]).resolve()
        isolation = current.get("isolation") or "shared"

        # Every pass does only bounded janitorial work. Active task records are
        # never eligible, so this is safe in multi-worker daemons.
        self.janitor()

        if isolation == "worktree" and metadata.get("workspace_prepared"):
            execution = Path(metadata["execution_cwd"]).resolve()
            expected_root = Path(metadata["worktree_root"]).resolve()
            if not execution.is_dir() or _git_root(execution) != expected_root:
                raise RuntimeError("prepared worktree identity is no longer valid")
            generation = self._attempt_generation()
            prepared_generation = metadata.get("workspace_lease_generation")
            if (
                generation is None
                or prepared_generation is None
                or int(prepared_generation) == generation
            ):
                return execution
            if int(prepared_generation) >= generation:
                raise RuntimeError("prepared worktree belongs to a newer lease generation")
            self._remove_worktree(
                metadata.get("origin_git_root"),
                expected_root,
                branch=metadata.get("worktree_branch"),
            )
            reclaimed_at = time.time()
            self.store.update_metadata(
                current["id"],
                {
                    "workspace_prepared": False,
                    "worktree_cleaned_at": reclaimed_at,
                    "worktree_cleanup_reason": "superseded-generation",
                },
            )
            self.store.add_event(
                current["id"],
                "workspace.generation_reclaimed",
                {
                    "prior_generation": int(prepared_generation),
                    "lease_generation": generation,
                    "path": str(expected_root),
                },
            )
            current = self.store.get(task["id"]) or current
            metadata = current.get("metadata") or {}

        before = self.checkpoint(current, origin, "before")
        root = _git_root(origin)
        if not root:
            if isolation == "worktree":
                raise RuntimeError("worktree isolation requires a git repository")
            self.store.update_metadata(
                current["id"],
                {"origin_cwd": str(origin), "execution_cwd": str(origin)},
            )
            return origin
        head = before.get("head")
        if not head:
            raise RuntimeError("workspace repository has no resolvable HEAD")

        input_payload, input_path, input_sha256 = self._write_input_snapshot(
            current, root, head
        )
        baseline_head = self._create_baseline(current, root, head, input_payload)
        common_metadata = {
            "workspace_prepared": True,
            "origin_cwd": str(origin),
            "origin_git_root": str(root),
            "origin_base_head": head,
            "origin_source_identity": input_payload["source_identity"],
            "input_manifest": str(input_path),
            "input_manifest_sha256": input_sha256,
            "baseline_head": baseline_head,
            "origin_dirty": bool(before.get("status")),
            # A fresh attempt cannot inherit a prior generation's accepted
            # output. These become non-null only after a stable collection.
            "workspace_collected_source_identity": None,
            "workspace_collected_source_reference": None,
            "workspace_collected_content_identity": None,
            "workspace_collection_mode": None,
            "workspace_manifest_path": None,
            "workspace_manifest_sha256": None,
            "workspace_manifest_generation": None,
        }
        generation = self._attempt_generation()
        if generation is not None:
            common_metadata["workspace_lease_generation"] = generation

        if isolation == "shared":
            reference = "refs/blacklabel-operator/baselines/%s" % current["id"]
            retained = _git(root, "update-ref", reference, baseline_head)
            if retained.returncode != 0:
                raise RuntimeError("baseline retention failed: %s" % retained.stdout)
            common_metadata.update(
                {
                    "execution_cwd": str(origin),
                    "baseline_ref": reference,
                }
            )
            self.store.update_metadata(current["id"], common_metadata)
            self.store.add_event(
                current["id"],
                "workspace.prepared",
                {
                    "isolation": isolation,
                    "cwd": str(origin),
                    "input_files": input_payload["files"],
                    "excluded": len(input_payload["excluded"]),
                },
            )
            return origin
        if isolation != "worktree":
            raise ValueError("unsupported workspace isolation: %s" % isolation)

        target = self.settings.worktrees_dir / current["id"]
        if target.exists() or target.is_symlink():
            raise RuntimeError("worktree target already exists without matching metadata")
        branch = "operator/task-%s" % current["id"].replace("-", "")
        branch_ref = "refs/heads/%s" % branch
        if _git(root, "show-ref", "--verify", "--quiet", branch_ref).returncode == 0:
            raise RuntimeError("worktree branch already exists: %s" % branch)
        created = False
        try:
            completed = _git(
                root,
                "worktree",
                "add",
                "-b",
                branch,
                str(target),
                head,
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    "git worktree creation failed: %s" % completed.stdout
                )
            created = True
            self._overlay_input(current, target, input_payload)
            moved = _git(target, "update-ref", "HEAD", baseline_head, head)
            if moved.returncode != 0:
                raise RuntimeError(
                    "worktree baseline activation failed: %s" % moved.stdout
                )
            indexed = _git(target, "read-tree", baseline_head)
            if indexed.returncode != 0:
                raise RuntimeError(
                    "worktree baseline index failed: %s" % indexed.stdout
                )
            clean = _git(target, "status", "--porcelain=v1", "--untracked-files=all")
            if clean.returncode != 0 or clean.stdout:
                raise RuntimeError(
                    "worktree input snapshot is not byte-faithful: %s" % clean.stdout
                )
        except Exception:
            if created:
                try:
                    self._remove_worktree(root, target, branch=branch)
                except Exception:
                    pass
            raise
        relative = origin.relative_to(root)
        execution = (target / relative).resolve()
        common_metadata.update(
            {
                "execution_cwd": str(execution),
                "worktree_root": str(target.resolve()),
                "worktree_branch": branch,
            }
        )
        self.store.update_metadata(current["id"], common_metadata)
        self.store.add_event(
            current["id"],
            "workspace.prepared",
            {
                "isolation": isolation,
                "cwd": str(execution),
                "input_files": input_payload["files"],
                "excluded": len(input_payload["excluded"]),
            },
        )
        return execution

    def _collection_index(self, root, task_dir, baseline_head):
        index_path = task_dir / "collection.index"
        if index_path.exists() or index_path.is_symlink():
            index_path.unlink()
        env = {
            "GIT_INDEX_FILE": str(index_path),
            "GIT_WORK_TREE": str(Path(root).resolve()),
        }
        loaded = _git(root, "read-tree", baseline_head, env=env)
        if loaded.returncode != 0:
            raise RuntimeError("collection baseline failed: %s" % loaded.stdout)
        return env

    def _write_collection_index(self, root, env, entries, task_dir):
        for entry in entries:
            relative = _relative_path(entry["path"])
            if entry["file_type"] == "deleted":
                updated = _git(
                    root,
                    "update-index",
                    "--force-remove",
                    "--",
                    relative,
                    env=env,
                )
            else:
                blob = self._verify_blob(task_dir, entry)
                hashed = _git(root, "hash-object", "-w", str(blob), env=env)
                if hashed.returncode != 0:
                    raise RuntimeError(
                        "evidence blob import failed: %s" % hashed.stdout
                    )
                updated = _git(
                    root,
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    entry["mode"],
                    hashed.stdout.strip(),
                    relative,
                    env=env,
                )
            if updated.returncode != 0:
                raise RuntimeError("evidence index update failed: %s" % updated.stdout)

    def collect(
        self,
        task,
        cwd,
        result=None,
        verified_source=None,
        verified_reference=None,
        verified_identity=None,
    ):
        """Seal task output, optionally exclusively from a passed verifier copy.

        When ``verified_source`` is supplied, no output bytes are read from the
        executor worktree. The patch and full content snapshot are derived from
        that isolated Git copy and the prepared baseline object tree.
        """
        del result
        current = self.store.get(task["id"]) or task
        metadata = current.get("metadata") or {}
        cwd = Path(cwd).resolve()
        root = _git_root(cwd)
        task_dir = self._task_dir(current)
        if not root:
            after = self.checkpoint(current, cwd, "after")
            self.store.add_event(
                current["id"],
                "workspace.collected",
                {"cwd": str(cwd), "head": after.get("head"), "artifacts": 0},
            )
            return []

        baseline_head = metadata.get("baseline_head")
        if not baseline_head:
            raise RuntimeError("workspace baseline identity is missing")
        if current.get("isolation") == "worktree":
            expected_root = Path(metadata.get("worktree_root") or "").resolve()
            if root != expected_root:
                raise RuntimeError("collection cwd is not the prepared task worktree")

        env = self._collection_index(root, task_dir, baseline_head)
        evidence_root = task_dir / "evidence"
        evidence_root.mkdir(parents=True, exist_ok=True)
        verified_snapshot = None
        collection_source = root
        collection_reference = baseline_head
        collection_mode = "live-worktree"
        if verified_source is not None:
            collection_source = Path(verified_source).resolve()
            if not collection_source.is_dir() or _git_root(collection_source) != collection_source:
                raise RuntimeError("verified collection source is not a Git root")
            collection_reference = str(verified_reference or "HEAD")
            collection_mode = "isolated-verifier-snapshot"
        identity_before = self.verification_identity(
            collection_source, collection_reference
        )
        expected_identity = verified_identity
        if isinstance(expected_identity, dict):
            expected_identity = expected_identity.get("source_identity")
        if verified_source is not None:
            if not isinstance(expected_identity, str) or not expected_identity:
                raise RuntimeError("verified collection source identity is required")
            if identity_before["source_identity"] != expected_identity:
                raise RuntimeError("verified collection source identity mismatch")
            verified_snapshot = self._capture_full_snapshot(
                collection_source, evidence_root
            )
            changes = self._index_verified_snapshot(
                root,
                env,
                baseline_head,
                verified_snapshot,
                task_dir,
            )
            captured = {
                "entries": changes,
                "excluded": verified_snapshot["excluded"],
                "files": len(changes),
                "bytes": sum(int(entry["bytes"]) for entry in changes),
            }
        else:
            captured = self._capture_state(
                root,
                baseline_head,
                snapshot_root=evidence_root,
                env=env,
            )
        untracked_entries = [
            entry for entry in captured["entries"] if entry["category"] == "untracked"
        ]
        if verified_snapshot is None:
            self._write_collection_index(root, env, captured["entries"], task_dir)
        if captured["entries"]:
            diff = _git(
                root,
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                baseline_head,
                "--",
                env=env,
            )
            if diff.returncode != 0:
                raise RuntimeError("workspace diff failed: %s" % diff.stdout)
            patch_bytes = diff.stdout.encode("utf-8", "surrogateescape")
        else:
            patch_bytes = b""
        if len(patch_bytes) > self.max_patch_bytes:
            raise RuntimeError(
                "workspace patch exceeds %d-byte limit" % self.max_patch_bytes
            )
        patch_path = task_dir / "changes.patch"
        _atomic_bytes(patch_path, patch_bytes)

        untracked_payload = [dict(entry) for entry in untracked_entries]
        untracked_path = task_dir / "untracked.json"
        _atomic_json(untracked_path, untracked_payload)

        workspace_payload = {
            "schema": WORKSPACE_ARTIFACT_SCHEMA,
            "task_id": current["id"],
            "created_at": time.time(),
            "isolation": current.get("isolation") or "shared",
            "origin": {
                "git_root": metadata.get("origin_git_root"),
                "base_head": metadata.get("origin_base_head"),
                "source_identity": metadata.get("origin_source_identity"),
                "input_manifest": metadata.get("input_manifest"),
                "input_manifest_sha256": metadata.get("input_manifest_sha256"),
            },
            "baseline_head": baseline_head,
            "collection": {
                "mode": collection_mode,
                "source_reference": identity_before["reference"],
                "source_identity": identity_before["source_identity"],
            },
            "artifacts": {
                "patch": {
                    "path": str(patch_path),
                    "bytes": patch_path.stat().st_size,
                    "sha256": _sha256_file(patch_path),
                },
                "untracked_manifest": {
                    "path": str(untracked_path),
                    "bytes": untracked_path.stat().st_size,
                    "sha256": _sha256_file(untracked_path),
                },
            },
            "changes": [
                {key: value for key, value in entry.items() if key != "blob"}
                for entry in captured["entries"]
            ],
            "excluded": captured["excluded"],
            "limits": {
                "max_files": self.max_files,
                "max_file_bytes": self.max_file_bytes,
                "max_total_bytes": self.max_total_bytes,
                "max_patch_bytes": self.max_patch_bytes,
            },
        }
        if verified_snapshot is not None:
            workspace_payload["verified_source_snapshot"] = {
                "content_identity": verified_snapshot["content_identity"],
                "files": verified_snapshot["files"],
                "bytes": verified_snapshot["bytes"],
                "entries": verified_snapshot["entries"],
                "excluded": verified_snapshot["excluded"],
            }
        workspace_path = task_dir / "workspace-artifacts.json"
        _atomic_json(workspace_path, workspace_payload)

        identity_after = self.verification_identity(
            collection_source, identity_before["reference"]
        )
        if identity_after["source_identity"] != identity_before["source_identity"]:
            raise RuntimeError("workspace source changed during collection")

        collected_identity = identity_before["source_identity"]
        self._record_artifact(
            current,
            "patch",
            patch_path,
            {
                "base_head": metadata.get("origin_base_head"),
                "baseline_head": baseline_head,
                "source_identity": metadata.get("origin_source_identity"),
                "collected_source_identity": collected_identity,
                "collection_mode": collection_mode,
            },
        )
        self._record_artifact(
            current,
            "untracked-manifest",
            untracked_path,
            {
                "files": len(untracked_payload),
                "collected_source_identity": collected_identity,
                "collection_mode": collection_mode,
            },
        )
        workspace_details = self._record_artifact(
            current,
            "workspace-manifest",
            workspace_path,
            {
                "changes": len(workspace_payload["changes"]),
                "excluded": len(workspace_payload["excluded"]),
                "collected_source_identity": collected_identity,
                "collected_source_reference": identity_before["reference"],
                "collection_mode": collection_mode,
                "content_identity": (
                    verified_snapshot["content_identity"]
                    if verified_snapshot is not None
                    else None
                ),
            },
        )
        collection_metadata = {
            "workspace_collected_source_identity": collected_identity,
            "workspace_collected_source_reference": identity_before["reference"],
            "workspace_collection_mode": collection_mode,
            "workspace_manifest_path": str(workspace_path),
            "workspace_manifest_sha256": workspace_details["sha256"],
            "workspace_manifest_generation": self._attempt_generation(),
        }
        if verified_snapshot is not None:
            collection_metadata["workspace_collected_content_identity"] = (
                verified_snapshot["content_identity"]
            )
        self.store.update_metadata(current["id"], collection_metadata)

        after = self.checkpoint(current, cwd, "after")
        artifacts = [patch_path, untracked_path, workspace_path]
        self.store.add_event(
            current["id"],
            "workspace.collected",
            {
                "cwd": str(cwd),
                "head": after.get("head"),
                "artifacts": len(artifacts),
                "changes": len(workspace_payload["changes"]),
                "excluded": len(workspace_payload["excluded"]),
                "manifest_sha256": workspace_details["sha256"],
                "manifest_path": str(workspace_path),
                "source_identity": collected_identity,
                "source_reference": identity_before["reference"],
                "collection_mode": collection_mode,
                "content_identity": (
                    verified_snapshot["content_identity"]
                    if verified_snapshot is not None
                    else None
                ),
            },
        )
        if current.get("isolation") == "worktree":
            self.cleanup(current, reason="collected")
        return artifacts

    def write_result(self, task, result, collection_error=None):
        task_dir = self._task_dir(task)
        result_path = task_dir / "result.json"
        current = self.store.get(task["id"]) or task
        payload = result.as_dict() if result and hasattr(result, "as_dict") else result or {}
        payload = dict(payload)
        payload.update(
            {
                "task_id": task["id"],
                "recorded_at": time.time(),
                "verification_required": bool(current.get("verification_required")),
                "verification_status": current.get(
                    "verification_status", "not_requested"
                ),
                "collection_error": collection_error,
            }
        )
        _atomic_json(result_path, payload)
        digest = _sha256_file(result_path)
        self.store.add_artifact(
            task["id"],
            "result",
            result_path,
            {"sha256": digest, "bytes": result_path.stat().st_size, "final": True},
        )
        self.store.add_event(
            task["id"],
            "result.recorded",
            {"path": str(result_path), "sha256": digest},
        )
        return result_path

    def _expected_artifact(self, task, kind, path):
        expected = Path(path).resolve()
        records = [
            item
            for item in self.store.artifacts(task["id"])
            if item["kind"] == kind and Path(item["path"]).resolve() == expected
        ]
        if len(records) != 1:
            raise RuntimeError("trusted %s artifact record is missing" % kind)
        recorded = records[0].get("metadata") or {}
        digest = recorded.get("sha256")
        if not digest:
            raise RuntimeError("trusted %s artifact hash is missing" % kind)
        if not expected.is_file() or expected.is_symlink():
            raise RuntimeError("%s artifact is missing" % kind)
        if int(recorded.get("bytes", -1)) != expected.stat().st_size:
            raise RuntimeError("%s artifact size mismatch" % kind)
        if _sha256_file(expected) != digest:
            raise RuntimeError("%s artifact hash mismatch" % kind)
        return recorded

    def _validate_manifest_blobs(self, task_dir, payload):
        task_dir = Path(task_dir).resolve()
        total = 0
        entries = payload.get("entries") or []
        if len(entries) > self.max_files:
            raise RuntimeError("workspace artifact file-count limit exceeded")
        for entry in entries:
            _relative_path(entry.get("path"))
            if entry.get("file_type") == "deleted":
                continue
            blob = self._verify_blob(task_dir, entry)
            if blob.stat().st_size > self.max_file_bytes:
                raise RuntimeError("workspace artifact file limit exceeded")
            total += blob.stat().st_size
            if total > self.max_total_bytes:
                raise RuntimeError("workspace artifact total limit exceeded")

    def _trusted_workspace_manifest(self, task):
        metadata = task.get("metadata") or {}
        expected_path = metadata.get("workspace_manifest_path")
        expected_sha256 = metadata.get("workspace_manifest_sha256")
        expected_generation = metadata.get("workspace_manifest_generation")
        if not expected_path or not expected_sha256:
            raise RuntimeError("trusted workspace manifest metadata is missing")
        records = [
            item
            for item in self.store.artifacts(task["id"])
            if item.get("kind") == "workspace-manifest"
        ]
        resolved = Path(expected_path).resolve()
        records = [
            item for item in records if Path(item["path"]).resolve() == resolved
        ]
        if not records:
            raise RuntimeError("trusted workspace-manifest artifact record is missing")
        record = max(records, key=lambda item: int(item.get("id") or 0))
        path = Path(record["path"]).resolve()
        task_root = (Path(self.settings.tasks_dir) / task["id"]).resolve()
        if path.name != "workspace-artifacts.json" or task_root not in path.parents:
            raise RuntimeError("workspace manifest path is outside task evidence")
        recorded = record.get("metadata") or {}
        generation = recorded.get("lease_generation")
        if generation is not None:
            generation_root = (
                task_root
                / ("generation-%08d" % int(generation))
                / "workspace"
            ).resolve()
            if path.parent != generation_root:
                raise RuntimeError("workspace manifest generation path mismatch")
        if expected_generation is not None and int(expected_generation) != int(
            generation if generation is not None else -1
        ):
            raise RuntimeError("workspace manifest generation metadata mismatch")
        if expected_sha256 and recorded.get("sha256") != expected_sha256:
            raise RuntimeError("workspace manifest metadata hash mismatch")
        self._expected_artifact(task, "workspace-manifest", path)
        return path, record

    def _validate_final_changes(self, origin, changes):
        for entry in changes:
            destination = _join_safe(origin, entry["path"])
            if entry["file_type"] == "deleted":
                if destination.exists() or destination.is_symlink():
                    raise RuntimeError(
                        "applied workspace deletion did not match evidence: %s"
                        % entry["path"]
                    )
                continue
            if not destination.exists() and not destination.is_symlink():
                raise RuntimeError(
                    "applied workspace file is missing: %s" % entry["path"]
                )
            if entry["file_type"] == "symlink":
                if not destination.is_symlink():
                    raise RuntimeError(
                        "applied workspace file type mismatch: %s" % entry["path"]
                    )
                data = os.fsencode(os.readlink(str(destination)))
            else:
                if destination.is_symlink() or not destination.is_file():
                    raise RuntimeError(
                        "applied workspace file type mismatch: %s" % entry["path"]
                    )
                data = destination.read_bytes()
                actual_mode = "100755" if destination.stat().st_mode & stat.S_IXUSR else "100644"
                if actual_mode != entry["mode"]:
                    raise RuntimeError(
                        "applied workspace file mode mismatch: %s" % entry["path"]
                    )
            if len(data) != int(entry["bytes"]) or _sha256_bytes(data) != entry["sha256"]:
                raise RuntimeError(
                    "applied workspace bytes do not match evidence: %s" % entry["path"]
                )

    def apply(self, task, preview=False, expected_sha256=None):
        current = self.store.get(task["id"]) or task
        origin = (current.get("metadata") or {}).get("origin_git_root") or ""
        lock_root = self.settings.home / "apply-locks"
        lock_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_path = lock_root / (hashlib.sha256(origin.encode()).hexdigest() + ".lock")
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError("another patch operation is using this repository") from exc
            return self._apply_checked(task, preview, expected_sha256)

    def _apply_checked(self, task, preview, expected_sha256):
        current = self.store.get(task["id"]) or task
        if (current.get("isolation") or "shared") != "worktree":
            raise RuntimeError("only isolated worktree artifacts can be applied")
        metadata = current.get("metadata") or {}
        already_applied = bool(metadata.get("workspace_applied_at"))
        if already_applied and not preview:
            raise RuntimeError("workspace artifacts were already applied")
        origin = Path(metadata.get("origin_git_root") or "").resolve()
        if not origin.is_dir() or _git_root(origin) != origin:
            raise RuntimeError("origin repository identity is invalid")
        workspace_path, _workspace_record = self._trusted_workspace_manifest(current)
        task_dir = workspace_path.parent.resolve()
        try:
            workspace_payload = json.loads(workspace_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("workspace manifest is unreadable") from exc
        if workspace_payload.get("schema") != WORKSPACE_ARTIFACT_SCHEMA:
            raise RuntimeError("workspace manifest schema mismatch")
        if workspace_payload.get("task_id") != current["id"]:
            raise RuntimeError("workspace manifest task identity mismatch")
        if workspace_payload.get("isolation") != "worktree":
            raise RuntimeError("workspace manifest is not an isolated worktree")

        origin_evidence = workspace_payload.get("origin") or {}
        comparisons = {
            "git_root": str(origin),
            "base_head": metadata.get("origin_base_head"),
            "source_identity": metadata.get("origin_source_identity"),
            "input_manifest": metadata.get("input_manifest"),
            "input_manifest_sha256": metadata.get("input_manifest_sha256"),
        }
        for field, expected in comparisons.items():
            if origin_evidence.get(field) != expected:
                raise RuntimeError("workspace manifest %s mismatch" % field)
        if workspace_payload.get("baseline_head") != metadata.get("baseline_head"):
            raise RuntimeError("workspace manifest baseline mismatch")
        collection_evidence = workspace_payload.get("collection") or {}
        collection_comparisons = {
            "source_identity": metadata.get("workspace_collected_source_identity"),
            "source_reference": metadata.get("workspace_collected_source_reference"),
            "mode": metadata.get("workspace_collection_mode"),
        }
        for field, expected in collection_comparisons.items():
            if not expected or collection_evidence.get(field) != expected:
                raise RuntimeError("workspace collection %s mismatch" % field)

        input_path = Path(metadata.get("input_manifest") or "").resolve()
        self._expected_artifact(current, "workspace-input-manifest", input_path)
        if _sha256_file(input_path) != metadata.get("input_manifest_sha256"):
            raise RuntimeError("workspace input manifest hash mismatch")
        try:
            input_payload = json.loads(input_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("workspace input manifest is unreadable") from exc
        if (
            input_payload.get("schema") != WORKSPACE_INPUT_SCHEMA
            or input_payload.get("task_id") != current["id"]
            or input_payload.get("base_head") != metadata.get("origin_base_head")
            or input_payload.get("source_identity")
            != metadata.get("origin_source_identity")
        ):
            raise RuntimeError("workspace input identity mismatch")
        self._validate_manifest_blobs(input_path.parent, input_payload)

        artifact_evidence = workspace_payload.get("artifacts") or {}
        patch_path = Path((artifact_evidence.get("patch") or {}).get("path") or "").resolve()
        if patch_path != (task_dir / "changes.patch").resolve():
            raise RuntimeError("workspace patch path mismatch")
        patch_record = self._expected_artifact(current, "patch", patch_path)
        patch_evidence = artifact_evidence.get("patch") or {}
        if (
            patch_evidence.get("path") != str(patch_path)
            or patch_evidence.get("sha256") != patch_record["sha256"]
            or int(patch_evidence.get("bytes", -1)) != patch_record["bytes"]
        ):
            raise RuntimeError("workspace patch evidence mismatch")
        if patch_path.stat().st_size > self.max_patch_bytes:
            raise RuntimeError("workspace patch exceeds the apply limit")
        if expected_sha256 is not None and expected_sha256 != patch_record["sha256"]:
            raise RuntimeError("patch changed since preview; review the current patch")

        untracked_path = Path(
            (artifact_evidence.get("untracked_manifest") or {}).get("path") or ""
        ).resolve()
        if untracked_path != (task_dir / "untracked.json").resolve():
            raise RuntimeError("workspace untracked path mismatch")
        untracked_record = self._expected_artifact(
            current, "untracked-manifest", untracked_path
        )
        untracked_evidence = artifact_evidence.get("untracked_manifest") or {}
        if (
            untracked_evidence.get("path") != str(untracked_path)
            or untracked_evidence.get("sha256") != untracked_record["sha256"]
            or int(untracked_evidence.get("bytes", -1)) != untracked_record["bytes"]
        ):
            raise RuntimeError("workspace untracked evidence mismatch")
        try:
            untracked_payload = json.loads(untracked_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("untracked manifest is unreadable") from exc
        self._validate_manifest_blobs(task_dir, {"entries": untracked_payload})
        verified_snapshot = workspace_payload.get("verified_source_snapshot")
        if verified_snapshot is not None:
            self._validate_manifest_blobs(task_dir, verified_snapshot)
            identity_entries = [
                {key: value for key, value in entry.items() if key != "blob"}
                for entry in verified_snapshot.get("entries") or []
            ]
            content_identity = _sha256_bytes(
                _canonical_bytes({"entries": identity_entries})
            )
            if content_identity != verified_snapshot.get("content_identity"):
                raise RuntimeError("verified source snapshot identity mismatch")

        result = {
            "task_id": current["id"],
            "patch": str(patch_path),
            "copied": [],
            "changes": len(workspace_payload.get("changes") or []),
            "files": [entry["path"] for entry in workspace_payload.get("changes") or []],
            "destination": str(origin),
            "sha256": patch_record["sha256"],
            "workspace_manifest_sha256": metadata["workspace_manifest_sha256"],
            "already_applied": already_applied,
        }
        if preview:
            if patch_path.stat().st_size > 1024 * 1024:
                raise RuntimeError("patch exceeds the 1 MB native preview limit; inspect it with the CLI")
            result["diff"] = patch_path.read_text(encoding="utf-8", errors="replace")
        if already_applied:
            if metadata.get("workspace_applied_patch_sha256") != patch_record["sha256"]:
                raise RuntimeError("applied patch identity does not match the retained patch")
            result["applied_at"] = metadata["workspace_applied_at"]
            return result

        base_head = metadata.get("origin_base_head")
        head = _git(origin, "rev-parse", "HEAD")
        if head.returncode != 0 or head.stdout.strip() != base_head:
            raise RuntimeError("origin HEAD changed after workspace preparation")
        current_state = self._capture_state(origin, base_head)
        if current_state["source_identity"] != metadata.get("origin_source_identity"):
            raise RuntimeError("origin source bytes changed after workspace preparation")

        if patch_path.stat().st_size:
            checked = _git(origin, "apply", "--check", "--binary", str(patch_path))
            if checked.returncode != 0:
                raise RuntimeError("patch preflight failed: %s" % checked.stdout)
        if preview:
            return result
        if patch_path.stat().st_size:
            completed = _git(origin, "apply", "--binary", str(patch_path))
            if completed.returncode != 0:
                raise RuntimeError("patch apply failed: %s" % completed.stdout)
        self._validate_final_changes(origin, workspace_payload.get("changes") or [])
        if verified_snapshot is not None:
            self._validate_final_changes(
                origin, verified_snapshot.get("entries") or []
            )
        applied_at = time.time()
        self.store.update_metadata(
            current["id"],
            {
                "workspace_applied_at": applied_at,
                "workspace_applied_patch_sha256": patch_record["sha256"],
            },
        )
        self.store.add_event(
            current["id"],
            "workspace.applied",
            {
                "patch_sha256": patch_record["sha256"],
                "changes": len(workspace_payload.get("changes") or []),
            },
        )
        result["already_applied"] = True
        result["applied_at"] = applied_at
        return result
