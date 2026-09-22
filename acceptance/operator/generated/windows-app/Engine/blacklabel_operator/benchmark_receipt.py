import hashlib
import json
import subprocess
import time
from pathlib import Path

from . import __version__
from .profiles import SOL_MODEL


SOL_PROVIDER = "codex"
SOL_BENCHMARK_PROFILE = "sol-benchmark"
SOURCE_EXCLUDED_DIRS = {
    ".aws",
    ".azure",
    ".gnupg",
    ".kube",
    ".ssh",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "build",
    "dist",
}
SOURCE_EXCLUDED_FILENAMES = {
    ".env",
    ".envrc",
    ".npmrc",
    ".pypirc",
    "auth.json",
    "credentials.json",
    "id_ed25519",
    "id_rsa",
    "kubeconfig",
    "secrets.json",
}
SOURCE_EXCLUDED_SUFFIXES = {
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
    ".sqlite3-shm",
    ".sqlite3-wal",
    ".token",
}


def require_exact_sol(provider, requested_model, resolved_model, profile):
    identity = {
        "provider": provider,
        "requested_model": requested_model,
        "resolved_model": resolved_model,
        "profile": profile,
    }
    expected = {
        "provider": SOL_PROVIDER,
        "requested_model": SOL_MODEL,
        "resolved_model": SOL_MODEL,
        "profile": SOL_BENCHMARK_PROFILE,
    }
    mismatches = [
        "%s=%r (expected %r)" % (key, identity[key], expected[key])
        for key in expected
        if identity[key] != expected[key]
    ]
    if mismatches:
        raise ValueError("Sol benchmark identity rejected: %s" % "; ".join(mismatches))
    return identity


def command_version(executable):
    try:
        completed = subprocess.run(
            [str(executable), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "unavailable: %s" % exc
    return completed.stdout.strip()


def source_revision(root):
    root = Path(root)
    try:
        tracked = subprocess.run(
            ["git", "ls-files", "--cached", "--", "."],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if tracked.returncode != 0 or not tracked.stdout.strip():
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def source_files(root):
    root = Path(root).resolve()
    try:
        listed = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "."],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        listed = None

    if listed is not None and listed.returncode == 0 and listed.stdout.strip():
        return tuple(
            root / line
            for line in listed.stdout.splitlines()
            if (
                line
                and not _excluded_source_path(Path(line))
                and (root / line).is_file()
                and not (root / line).is_symlink()
            )
        )
    return tuple(
        path
        for path in root.rglob("*")
        if (
            path.is_file()
            and not path.is_symlink()
            and not _excluded_source_path(path.relative_to(root))
        )
    )


def _excluded_source_path(path):
    lowered_parts = tuple(part.lower() for part in path.parts)
    name = path.name.lower()
    return (
        any(
            part in SOURCE_EXCLUDED_DIRS or part.endswith(".egg-info")
            for part in lowered_parts
        )
        or name in SOURCE_EXCLUDED_FILENAMES
        or name.startswith(".env.")
        or path.suffix.lower() in SOURCE_EXCLUDED_SUFFIXES
        or path.suffix.lower() in (".pyc", ".pyo")
    )


def source_identity(root):
    root = Path(root).resolve()
    try:
        status = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=all", "--", "."],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        status = None

    digest = hashlib.sha256()
    file_count = 0
    for path in sorted(source_files(root), key=lambda item: str(item.relative_to(root))):
        if not path.is_file():
            continue
        relative = str(path.relative_to(root))
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(bytes.fromhex(_sha256(path)))
        file_count += 1

    status_text = status.stdout if status is not None and status.returncode == 0 else ""
    return {
        "revision": source_revision(root),
        "dirty": bool(status_text.strip()),
        "status_sha256": hashlib.sha256(status_text.encode("utf-8")).hexdigest(),
        "tree_sha256": digest.hexdigest(),
        "files": file_count,
    }


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_manifest(root, excluded=None, read_only_modes=False):
    root = Path(root).resolve()
    excluded = {str(item) for item in (excluded or ())}
    files = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = str(path.relative_to(root))
        if relative in excluded:
            continue
        mode = path.stat().st_mode & 0o777
        if read_only_modes and not path.is_symlink():
            mode = 0o555 if mode & 0o111 else 0o444
        files.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "mode": mode,
                "sha256": _sha256(path),
            }
        )
    return files


def write_receipt(
    run_dir,
    suite,
    status,
    settings,
    command=None,
    scope=None,
    result=None,
    started_at=None,
):
    run_dir = Path(run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    identity = require_exact_sol(
        provider="codex",
        requested_model=SOL_MODEL,
        resolved_model=settings.model,
        profile=SOL_BENCHMARK_PROFILE,
    )
    now = time.time()
    payload = {
        "schema": "black-label-operator/benchmark-receipt-v1",
        "operator_version": __version__,
        "suite": suite,
        "status": status,
        "started_at": float(started_at or now),
        "finished_at": now,
        "duration_seconds": round(now - float(started_at or now), 3),
        "identity": dict(identity, exact_sol=True),
        "codex": {
            "executable": str(settings.codex_bin),
            "version": command_version(settings.codex_bin),
        },
        "operator_revision": source_revision(settings.repo_root),
        "operator_source": source_identity(settings.repo_root),
        "command": list(command or []),
        "scope": scope or {},
        "result": result or {},
    }
    payload["artifacts"] = artifact_manifest(run_dir, excluded={"receipt.json"})
    receipt = run_dir / "receipt.json"
    receipt.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return payload
