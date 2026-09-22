"""Content-addressed, immutable local Operator releases."""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
import venv
from dataclasses import dataclass
from pathlib import Path

from . import __version__
from .benchmark_receipt import artifact_manifest, source_files, source_identity


ENTRYPOINTS = ("operator", "blacklabel-operator", "sol", "operator-mcp")
MANIFEST_NAME = "release.json"
MANIFEST_SCHEMA = "black-label-operator/release-v3"
EXCLUDED_DIRECTORIES = {
    ".git",
    ".aws",
    ".azure",
    ".gnupg",
    ".kube",
    ".ssh",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "build",
    "cache",
    "caches",
    "dist",
    "grok-clients",
    "logs",
    "schedules",
    "tasks",
    "worktrees",
}
EXCLUDED_FILENAMES = {
    ".env",
    ".envrc",
    ".npmrc",
    ".pypirc",
    "auth.json",
    "credentials.json",
    "kubeconfig",
    "id_rsa",
    "id_ed25519",
    "secrets.json",
    "state.db",
}
EXCLUDED_SUFFIXES = {
    ".db",
    ".db-shm",
    ".db-wal",
    ".key",
    ".p12",
    ".pem",
    ".pfx",
    ".pyc",
    ".pyo",
    ".sqlite",
    ".sqlite-shm",
    ".sqlite-wal",
    ".sqlite3",
    ".sqlite3-shm",
    ".sqlite3-wal",
    ".secret",
    ".secrets",
    ".token",
}

RUNTIME_PRUNED_DIRECTORIES = {"__pycache__", "test", "tests"}
RUNTIME_PRUNED_SUFFIXES = {".pyc", ".pyo"}
PRIVATE_KEY_MARKERS = (
    b"-----BEGIN " b"PRIVATE KEY-----",
    b"-----BEGIN " b"ENCRYPTED PRIVATE KEY-----",
    b"-----BEGIN " b"RSA PRIVATE KEY-----",
    b"-----BEGIN " b"EC PRIVATE KEY-----",
    b"-----BEGIN " b"DSA PRIVATE KEY-----",
    b"-----BEGIN " b"OPENSSH PRIVATE KEY-----",
)


@dataclass(frozen=True)
class InstalledRelease:
    path: Path
    version: str
    tree_sha256: str
    runtime_sha256: str
    manifest_sha256: str
    repo_root: Path
    import_root: Path

    @property
    def release_id(self):
        return self.path.name

    def entrypoint(self, name="operator"):
        if name not in ENTRYPOINTS:
            raise ValueError("unknown Operator entrypoint: %s" % name)
        return self.path / "bin" / name


def releases_dir(settings):
    return settings.resolved_install_root / "releases"


def current_path(settings):
    return settings.resolved_install_root / "current"


def _is_package_root(path):
    return path.name == "blacklabel_operator" and (path / "__init__.py").is_file()


def _excluded(relative):
    lowered_parts = tuple(part.lower() for part in relative.parts)
    name = relative.name.lower()
    return (
        any(part in EXCLUDED_DIRECTORIES or part.endswith(".egg-info") for part in lowered_parts)
        or name in EXCLUDED_FILENAMES
        or name.startswith(".env.")
        or any(marker in name for marker in ("credential", "private-key", "private_key"))
        or relative.suffix.lower() in EXCLUDED_SUFFIXES
    )


def _copy_source(source_root, staging):
    source_root = Path(source_root).expanduser().resolve()
    if not source_root.is_dir():
        raise RuntimeError("Operator source root does not exist: %s" % source_root)

    package_only = _is_package_root(source_root)
    if not package_only and not (source_root / "blacklabel_operator/__init__.py").is_file():
        raise RuntimeError("Operator source root does not contain blacklabel_operator: %s" % source_root)
    import_root = staging / "source"
    repo_root = import_root / "blacklabel_operator" if package_only else import_root
    repo_root.mkdir(parents=True, exist_ok=True)
    copied = 0
    for source in sorted(source_files(source_root), key=lambda item: str(item)):
        source = Path(source)
        if source.is_symlink() or not source.is_file():
            continue
        try:
            relative = source.resolve().relative_to(source_root)
        except ValueError:
            continue
        if _excluded(relative):
            continue
        target = repo_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(str(source), str(target))
        target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
        copied += 1
    if copied == 0 or not (import_root / "blacklabel_operator/__init__.py").is_file():
        raise RuntimeError("Operator release source did not contain the Python package")
    return repo_root, import_root


def _contains_private_key(path):
    """Recognize private-key payloads without rejecting public CA certificates."""
    try:
        if path.stat().st_size > 16 * 1024 * 1024:
            return False
        payload = path.read_bytes()
    except OSError as exc:
        raise RuntimeError(
            "Operator release could not inspect runtime payload: %s" % path
        ) from exc
    return any(marker in payload for marker in PRIVATE_KEY_MARKERS)


def _materialize_runtime_symlinks(runtime):
    """Replace release-local links with exact regular bytes for app notarization."""
    runtime = Path(runtime).expanduser().resolve()
    links = sorted(
        (path for path in runtime.rglob("*") if path.is_symlink()),
        key=lambda item: len(item.parts),
        reverse=True,
    )
    for link in links:
        try:
            target = link.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise RuntimeError(
                "Operator release Python contains a broken symlink: %s" % link
            ) from exc
        if not _inside(target, runtime):
            raise RuntimeError(
                "Operator release Python symlink escapes its immutable root: %s" % link
            )
        link.unlink()
        if target.is_dir():
            shutil.copytree(str(target), str(link), symlinks=False)
        else:
            shutil.copy2(str(target), str(link))


def _prune_runtime_payload(runtime):
    """Remove development fixtures, bytecode caches, and all private keys.

    The standalone Python distributions include upstream test trees that are
    irrelevant to Operator execution and sometimes contain well-known TLS test
    private keys. Public certificate bundles remain intact so HTTPS validation
    continues to work.
    """
    runtime = Path(runtime).expanduser().resolve()
    if not runtime.is_dir():
        raise RuntimeError("Operator release Python root is missing: %s" % runtime)

    for path in sorted(runtime.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_symlink():
            continue
        if path.is_dir() and path.name.lower() in RUNTIME_PRUNED_DIRECTORIES:
            shutil.rmtree(str(path))

    for path in sorted(runtime.rglob("*"), key=lambda item: str(item)):
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix.lower() in RUNTIME_PRUNED_SUFFIXES or _contains_private_key(path):
            path.unlink()

    _materialize_runtime_symlinks(runtime)

    for path in runtime.rglob("*"):
        if path.is_symlink():
            raise RuntimeError(
                "Operator release Python still contains a symbolic link: %s" % path
            )
        if not path.is_file():
            continue
        if path.suffix.lower() in RUNTIME_PRUNED_SUFFIXES or _contains_private_key(path):
            raise RuntimeError(
                "Operator release Python still contains a forbidden runtime payload: %s"
                % path
            )


def _create_python(staging, python_executable=None):
    runtime = staging / ".venv"
    if python_executable is not None:
        executable = Path(python_executable).expanduser().resolve()
    elif sys.platform == "darwin":
        # A venv created by a wheel-installed command inherits that wheel venv's
        # temporary symlink as sys.executable. Build a slim relocatable runtime
        # from the framework binary and stdlib so the release survives /tmp
        # cleanup without embedding an executed .app bundle that macOS seals
        # against later uninstall.
        source_root = Path(sys.base_prefix).expanduser().resolve()
        source_executable = (
            source_root / "Resources/Python.app/Contents/MacOS/Python"
        )
        source_library = source_root / "Python3"
        source_stdlib = source_root / "lib"
        framework_runtime = all(
            item.exists()
            and _inside(item.resolve(), source_root)
            for item in (source_executable, source_library, source_stdlib)
        )
        (runtime / "bin").mkdir(parents=True)
        try:
            if framework_runtime:
                shutil.copy2(str(source_library), str(runtime / "Python3"))
                shutil.copy2(str(source_executable), str(runtime / "bin/python"))
                shutil.copytree(str(source_stdlib), str(runtime / "lib"), symlinks=True)
                executable = runtime / "bin/python"
                subprocess.run(
                    [
                        "install_name_tool",
                        "-change",
                        "@executable_path/../../../../Python3",
                        "@executable_path/../Python3",
                        str(executable),
                    ],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                signed_files = (runtime / "Python3", executable)
            else:
                # uv/python-build-standalone runtimes use a sibling lib directory
                # instead of a Python.framework. Preserve that complete stdlib and
                # bind its executable to the copied libpython, never the mutable
                # cache it was installed from.
                version = "%d.%d" % (sys.version_info.major, sys.version_info.minor)
                source_executable = source_root / "bin" / ("python" + version)
                source_library = source_root / "lib" / ("libpython%s.dylib" % version)
                source_stdlib = source_root / "lib" / ("python" + version)
                if not all(
                    item.exists()
                    and _inside(item.resolve(), source_root)
                    for item in (source_executable, source_library, source_stdlib)
                ):
                    raise RuntimeError(
                        "Operator release Python runtime is not portable: %s"
                        % source_root
                    )
                shutil.copy2(str(source_executable), str(runtime / "bin/python"))
                shutil.copytree(
                    str(source_root / "lib"), str(runtime / "lib"), symlinks=True
                )
                executable = runtime / "bin/python"
                copied_library = runtime / "lib" / source_library.name
                linked = subprocess.run(
                    ["otool", "-L", str(executable)],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                ).stdout
                rpaths = subprocess.run(
                    ["otool", "-l", str(executable)],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                ).stdout
                absolute_dependency = str(source_library)
                relative_dependency = "@rpath/%s" % source_library.name
                sibling_dependency = "@executable_path/../lib/%s" % source_library.name
                if absolute_dependency in linked:
                    subprocess.run(
                        [
                            "install_name_tool",
                            "-change",
                            absolute_dependency,
                            sibling_dependency,
                            str(executable),
                        ],
                        check=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                elif relative_dependency in linked:
                    if "path @executable_path/../lib " not in rpaths:
                        raise RuntimeError(
                            "standalone Python has no release-local library rpath"
                        )
                elif sibling_dependency not in linked:
                    # Newer python-build-standalone/uv builds can ship an executable
                    # without an explicit libpython load command. Keep the copied
                    # stdlib/lib payload bound in the release manifest and let the
                    # runtime identity probe below prove the copied interpreter works.
                    pass
                subprocess.run(
                    [
                        "install_name_tool",
                        "-id",
                        relative_dependency,
                        str(copied_library),
                    ],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                signed_files = (copied_library, executable)
            _prune_runtime_payload(runtime)
            signing_identity = os.environ.get(
                "OPERATOR_RELEASE_CODESIGN_IDENTITY", ""
            ).strip()
            if signing_identity:
                signed_files = tuple(
                    sorted(
                        set(signed_files).union(
                            path
                            for path in runtime.rglob("*")
                            if path.is_file()
                            and not path.is_symlink()
                            and path.suffix.lower() in {".so", ".dylib"}
                        ),
                        key=lambda path: str(path),
                    )
                )
            for signed in signed_files:
                command = ["codesign", "--force"]
                if signing_identity:
                    command.extend(["--options", "runtime", "--timestamp"])
                command.extend(["--sign", signing_identity or "-", str(signed)])
                subprocess.run(
                    command,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
        except (OSError, subprocess.CalledProcessError) as exc:
            raise RuntimeError(
                "Operator release Python relocation failed: %s" % exc
            ) from exc
        _runtime_symlink_manifest(runtime)
        # macOS records provenance when the copied framework is first executed;
        # make it immutable before that first probe so later sealing is idempotent.
        _make_read_only(runtime)
    else:
        builder = venv.EnvBuilder(with_pip=False, symlinks=False)
        builder.create(str(runtime))
        executable = runtime / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not executable.is_file():
        raise RuntimeError("Operator release Python was not created: %s" % executable)
    return executable


def _runtime_symlink_manifest(root):
    """Bind every runtime link and reject links escaping the immutable root."""
    root = Path(root).expanduser().resolve()
    entries = []
    for path in sorted(root.rglob("*"), key=lambda item: str(item)):
        if not path.is_symlink():
            continue
        relative = path.relative_to(root)
        target = os.readlink(str(path))
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise RuntimeError(
                "Operator release Python contains a broken symlink: %s" % relative
            ) from exc
        if not _inside(resolved, root):
            raise RuntimeError(
                "Operator release Python symlink escapes its immutable root: %s"
                % relative
            )
        entries.append({"path": str(relative), "target": target})
    return entries


def _verify_runtime_symlinks(root, entries):
    root = Path(root).expanduser().resolve()
    expected = {
        str(item.get("path") or ""): str(item.get("target") or "")
        for item in (entries or [])
    }
    if "" in expected:
        raise RuntimeError("Operator release Python symlink manifest is invalid")
    actual = {item["path"]: item["target"] for item in _runtime_symlink_manifest(root)}
    if actual != expected:
        changed = sorted(set(actual).symmetric_difference(expected))
        if not changed:
            changed = sorted(path for path in actual if actual[path] != expected[path])
        raise RuntimeError(
            "Operator release Python symlink manifest mismatch: %s"
            % ", ".join(changed[:10])
        )


def _launcher_text(python, import_root, module, staging, final_path=None):
    try:
        python_relative = python.relative_to(staging)
        python_command = '"$release_root"/%s' % shlex.quote(str(python_relative))
    except ValueError:
        python_command = shlex.quote(str(python))
    import_relative = import_root.relative_to(staging)
    # Resolve from the launcher on every invocation. The exact immutable release
    # can therefore move from a notarized app bundle into the user's release
    # store without rewriting a single manifest-bound byte.
    bootstrap = (
        "import os,sys; root=os.environ.pop('OPERATOR_RELEASE_LAUNCH_ROOT'); "
        "sys.path.insert(0, os.path.join(root, %r)); "
        "from %s import main; raise SystemExit(main())"
        % (str(import_relative), module)
    )
    return (
        "#!/bin/sh\n"
        "launcher=$0\n"
        "if [ -L \"$launcher\" ]; then\n"
        "  target=$(readlink \"$launcher\") || exit 126\n"
        "  case $target in /*) launcher=$target ;; *) "
        "launcher=$(dirname \"$launcher\")/$target ;; esac\n"
        "fi\n"
        "release_root=$(CDPATH= cd -- \"$(dirname -- \"$launcher\")/..\" && pwd -P) "
        "|| exit 126\n"
        "OPERATOR_RELEASE_LAUNCH_ROOT=\"$release_root\" "
        "exec %s -I -c %s \"$@\"\n"
    ) % (
        python_command,
        shlex.quote(bootstrap),
    )


def _write_launchers(staging, final_path, python, import_root):
    target = staging / "bin"
    target.mkdir(parents=True, exist_ok=True)
    modules = {
        "operator": "blacklabel_operator.cli",
        "blacklabel-operator": "blacklabel_operator.cli",
        "sol": "blacklabel_operator.cli",
        "operator-mcp": "blacklabel_operator.mcp_server",
    }
    for name, module in modules.items():
        launcher = target / name
        launcher.write_text(
            _launcher_text(python, import_root, module, staging, final_path),
            encoding="utf-8",
        )
        launcher.chmod(0o755)


def _sha256_text(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _runtime_identity(executable):
    executable = Path(executable).expanduser()
    if not executable.is_file():
        raise RuntimeError("Operator release Python is missing: %s" % executable)
    resolved = executable.resolve()
    try:
        completed = subprocess.run(
            [
                str(executable),
                "-I",
                "-c",
                (
                    "import json,platform,sys;print(json.dumps({"
                    "'implementation':platform.python_implementation(),"
                    "'version':platform.python_version(),"
                    "'cache_tag':sys.implementation.cache_tag}))"
                ),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("Operator release Python probe failed: %s" % exc)
    if completed.returncode != 0:
        raise RuntimeError(
            "Operator release Python probe failed: %s" % completed.stdout.strip()
        )
    try:
        metadata = json.loads(completed.stdout)
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Operator release Python returned invalid metadata: %s" % exc)
    identity = {
        "implementation": str(metadata.get("implementation") or ""),
        "version": str(metadata.get("version") or ""),
        "cache_tag": str(metadata.get("cache_tag") or ""),
        "binary_sha256": _file_sha256(resolved),
    }
    if not all(identity.values()):
        raise RuntimeError("Operator release Python metadata is incomplete")
    identity["identity_sha256"] = _sha256_text(
        json.dumps(identity, sort_keys=True, separators=(",", ":"))
    )
    return identity


def _write_manifest(
    staging,
    version,
    identity,
    runtime_identity,
    runtime_relative,
    runtime_external,
    repo_root,
    import_root,
):
    payload = {
        "schema": MANIFEST_SCHEMA,
        "version": version,
        "tree_sha256": identity["tree_sha256"],
        "files": identity["files"],
        "runtime": runtime_identity,
        "runtime_relative": runtime_relative,
        "runtime_external": runtime_external,
        "runtime_manifest": (
            artifact_manifest(
                staging / Path(runtime_relative).parts[0], read_only_modes=True
            )
            if runtime_relative
            else []
        ),
        "runtime_symlinks": (
            _runtime_symlink_manifest(staging / Path(runtime_relative).parts[0])
            if runtime_relative
            else []
        ),
        "repo_relative": str(repo_root.relative_to(staging)),
        "import_relative": str(import_root.relative_to(staging)),
        "entrypoints": list(ENTRYPOINTS),
        "source_manifest": artifact_manifest(staging / "source", read_only_modes=True),
        "entrypoint_manifest": artifact_manifest(staging / "bin", read_only_modes=True),
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    payload["manifest_sha256"] = _sha256_text(canonical)
    manifest = staging / MANIFEST_NAME
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def _read_release(path):
    path = Path(path).expanduser().resolve()
    manifest_path = path / MANIFEST_NAME
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError("invalid Operator release manifest at %s: %s" % (path, exc))
    if payload.get("schema") != MANIFEST_SCHEMA:
        raise RuntimeError("unsupported Operator release manifest at %s" % path)
    supplied_manifest_sha = payload.pop("manifest_sha256", None)
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    if supplied_manifest_sha != _sha256_text(canonical):
        raise RuntimeError("Operator release manifest verification failed: %s" % path)
    payload["manifest_sha256"] = supplied_manifest_sha
    repo_root = (path / payload["repo_relative"]).resolve()
    import_root = (path / payload["import_relative"]).resolve()
    if not _inside(repo_root, path) or not _inside(import_root, path):
        raise RuntimeError("Operator release manifest escapes its immutable root: %s" % path)
    identity = source_identity(repo_root)
    if identity["tree_sha256"] != payload.get("tree_sha256"):
        raise RuntimeError("Operator release source verification failed: %s" % path)
    _verify_artifacts(
        path / "source", payload.get("source_manifest") or [], exact=True
    )
    _verify_artifacts(path / "bin", payload.get("entrypoint_manifest") or [], exact=True)
    runtime_relative = payload.get("runtime_relative")
    runtime_external = payload.get("runtime_external")
    if bool(runtime_relative) == bool(runtime_external):
        raise RuntimeError("Operator release manifest has an invalid Python runtime path")
    if runtime_relative:
        relative_runtime = Path(str(runtime_relative))
        if relative_runtime.is_absolute() or ".." in relative_runtime.parts:
            raise RuntimeError("Operator release Python path is invalid")
        runtime_path = path / relative_runtime
        _verify_artifacts(
            path / relative_runtime.parts[0],
            payload.get("runtime_manifest") or [],
            exact=True,
        )
        _verify_runtime_symlinks(
            path / relative_runtime.parts[0], payload.get("runtime_symlinks") or []
        )
    else:
        if payload.get("runtime_symlinks"):
            raise RuntimeError("external Operator Python cannot declare runtime symlinks")
        runtime_path = Path(str(runtime_external)).expanduser().resolve()
    runtime_identity = _runtime_identity(runtime_path)
    if runtime_identity != payload.get("runtime"):
        raise RuntimeError("Operator release Python runtime verification failed: %s" % path)
    runtime_hash = runtime_identity["identity_sha256"][:12]
    expected_name = "%s-%s-py%s" % (
        payload.get("version"),
        payload.get("tree_sha256"),
        runtime_hash,
    )
    if path.name != expected_name:
        raise RuntimeError("Operator release directory identity mismatch: %s" % path)
    for name in ENTRYPOINTS:
        if not (path / "bin" / name).is_file():
            raise RuntimeError("Operator release is missing entrypoint %s" % name)
    return InstalledRelease(
        path=path,
        version=str(payload["version"]),
        tree_sha256=str(payload["tree_sha256"]),
        runtime_sha256=str(runtime_identity["identity_sha256"]),
        manifest_sha256=str(payload["manifest_sha256"]),
        repo_root=repo_root,
        import_root=import_root,
    )


def _make_read_only(root):
    for path in sorted(Path(root).rglob("*"), reverse=True):
        if path.is_symlink():
            continue
        if path.is_dir():
            desired = 0o555
        elif path.stat().st_mode & 0o111:
            desired = 0o555
        else:
            desired = 0o444
        if path.stat().st_mode & 0o777 != desired:
            path.chmod(desired)
    root = Path(root)
    if root.stat().st_mode & 0o777 != 0o555:
        root.chmod(0o555)


def _atomic_symlink(target, link):
    link = Path(link)
    link.parent.mkdir(parents=True, exist_ok=True)
    temporary = link.parent / (".%s.tmp-%s" % (link.name, uuid.uuid4().hex))
    os.symlink(str(target), str(temporary))
    try:
        os.replace(str(temporary), str(link))
    finally:
        if os.path.lexists(str(temporary)):
            temporary.unlink()


def _inside(path, parent):
    try:
        Path(path).resolve(strict=False).relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return False


def _file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_artifacts(root, entries, exact=False, allow_external_symlinks=False):
    root = Path(root).resolve()
    if not entries:
        raise RuntimeError("Operator release manifest has no artifacts for %s" % root)
    expected_paths = set()
    for entry in entries:
        relative = Path(str(entry.get("path") or ""))
        unresolved_candidate = root / relative
        candidate = unresolved_candidate.resolve()
        if (
            not str(relative)
            or relative.is_absolute()
            or ".." in relative.parts
            or (
                not _inside(candidate, root)
                and not (allow_external_symlinks and unresolved_candidate.is_symlink())
            )
            or not unresolved_candidate.is_file()
        ):
            raise RuntimeError("Operator release artifact path is invalid: %s" % relative)
        if unresolved_candidate.stat().st_size != int(entry.get("bytes", -1)):
            raise RuntimeError(
                "Operator release artifact size mismatch: %s" % unresolved_candidate
            )
        if unresolved_candidate.stat().st_mode & 0o777 != int(entry.get("mode", -1)):
            raise RuntimeError(
                "Operator release artifact mode mismatch: %s" % unresolved_candidate
            )
        if _file_sha256(unresolved_candidate) != entry.get("sha256"):
            raise RuntimeError(
                "Operator release artifact hash mismatch: %s" % unresolved_candidate
            )
        expected_paths.add(str(relative))
    if exact:
        actual_paths = {
            str(candidate.relative_to(root))
            for candidate in root.rglob("*")
            if candidate.is_file()
        }
        if actual_paths != expected_paths:
            changed = sorted(actual_paths.symmetric_difference(expected_paths))
            raise RuntimeError(
                "Operator release artifact set mismatch: %s"
                % ", ".join(changed[:10])
            )


def _owned_entrypoint(path, settings):
    path = Path(path)
    if not path.is_symlink():
        return False
    raw = Path(os.readlink(str(path)))
    candidate = raw if raw.is_absolute() else path.parent / raw
    return _inside(candidate, settings.resolved_install_root)


@dataclass(frozen=True)
class ActivationState:
    """The exact mutable activation state that an install may replace."""

    current_target: object
    entrypoints: tuple


def capture_activation(settings):
    """Capture enough state to undo activation without copying immutable releases."""
    pointer = current_path(settings)
    if os.path.lexists(str(pointer)):
        if not pointer.is_symlink():
            raise RuntimeError("Operator current activation path is not a symlink: %s" % pointer)
        current_target = os.readlink(str(pointer))
    else:
        current_target = None

    backup_dir = settings.resolved_install_root / "backups/entrypoints"
    entrypoints = []
    for name in ENTRYPOINTS:
        destination = settings.resolved_bin_dir / name
        backup = backup_dir / name
        if not os.path.lexists(str(destination)):
            kind = "missing"
            target = None
        elif _owned_entrypoint(destination, settings):
            kind = "owned-symlink"
            target = os.readlink(str(destination))
        else:
            if os.path.lexists(str(backup)):
                raise RuntimeError(
                    "entrypoint conflict while a backup is retained: %s" % destination
                )
            kind = "external"
            target = None
        entrypoints.append((name, kind, target))
    return ActivationState(current_target=current_target, entrypoints=tuple(entrypoints))


def _remove_owned_entrypoint(destination, settings):
    if not os.path.lexists(str(destination)):
        return
    if not _owned_entrypoint(destination, settings):
        raise RuntimeError(
            "refusing to replace an unexpected entrypoint during rollback: %s"
            % destination
        )
    destination.unlink()


def restore_activation(settings, state):
    """Restore a previously captured current pointer and public entrypoints."""
    if not isinstance(state, ActivationState):
        raise TypeError("an Operator ActivationState is required")
    backup_dir = settings.resolved_install_root / "backups/entrypoints"
    errors = []
    for name, kind, target in reversed(state.entrypoints):
        destination = settings.resolved_bin_dir / name
        backup = backup_dir / name
        try:
            if kind == "external":
                if os.path.lexists(str(backup)):
                    _remove_owned_entrypoint(destination, settings)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(str(backup), str(destination))
                elif _owned_entrypoint(destination, settings):
                    raise RuntimeError(
                        "original entrypoint backup is missing: %s" % backup
                    )
            elif kind == "owned-symlink":
                _remove_owned_entrypoint(destination, settings)
                _atomic_symlink(target, destination)
            elif kind == "missing":
                _remove_owned_entrypoint(destination, settings)
            else:
                raise RuntimeError("unknown entrypoint activation state: %s" % kind)
        except (OSError, RuntimeError) as exc:
            errors.append("%s: %s" % (name, exc))

    pointer = current_path(settings)
    try:
        if os.path.lexists(str(pointer)):
            if not pointer.is_symlink():
                raise RuntimeError(
                    "Operator current activation path changed type during rollback: %s"
                    % pointer
                )
            pointer.unlink()
        if state.current_target is not None:
            _atomic_symlink(state.current_target, pointer)
    except (OSError, RuntimeError) as exc:
        errors.append("current: %s" % exc)
    if errors:
        raise RuntimeError("Operator activation rollback failed: %s" % "; ".join(errors))


def _install_entrypoints(installed, settings):
    bin_dir = settings.resolved_bin_dir
    backup_dir = settings.resolved_install_root / "backups/entrypoints"
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name in ENTRYPOINTS:
        destination = bin_dir / name
        backup = backup_dir / name
        if (
            os.path.lexists(str(destination))
            and not _owned_entrypoint(destination, settings)
            and os.path.lexists(str(backup))
        ):
            raise RuntimeError("entrypoint conflict while a backup is retained: %s" % destination)
    for name in ENTRYPOINTS:
        destination = bin_dir / name
        backup = backup_dir / name
        if os.path.lexists(str(destination)) and not _owned_entrypoint(destination, settings):
            backup.parent.mkdir(parents=True, exist_ok=True)
            os.replace(str(destination), str(backup))
        # Every public command follows one stable indirection. Upgrades switch
        # all four commands together when the single `current` pointer moves.
        stable_target = current_path(settings) / "bin" / name
        _atomic_symlink(stable_target, destination)


def install(settings, source_root=None, version=None, python_executable=None):
    """Build or reuse an exact release, then atomically activate every entrypoint."""
    _validate_layout(settings)
    version = str(version or __version__)
    source_root = Path(source_root or settings.repo_root).expanduser().resolve()
    releases = releases_dir(settings)
    releases.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=str(releases)))
    try:
        repo_root, import_root = _copy_source(source_root, staging)
        python = _create_python(staging, python_executable=python_executable)
        identity = source_identity(repo_root)
        runtime_identity = _runtime_identity(python)
        release_id = "%s-%s-py%s" % (
            version,
            identity["tree_sha256"],
            runtime_identity["identity_sha256"][:12],
        )
        final_path = releases / release_id
        _write_launchers(staging, final_path, python, import_root)
        try:
            runtime_relative = str(python.relative_to(staging))
            runtime_external = None
        except ValueError:
            runtime_relative = None
            runtime_external = str(python.resolve())
        _write_manifest(
            staging,
            version,
            identity,
            runtime_identity,
            runtime_relative,
            runtime_external,
            repo_root,
            import_root,
        )
        _make_read_only(staging)
        if final_path.exists():
            _remove_tree(staging)
        else:
            os.replace(str(staging), str(final_path))
        installed = _read_release(final_path)
        activation = capture_activation(settings)
        try:
            _install_entrypoints(installed, settings)
            _atomic_symlink(Path("releases") / release_id, current_path(settings))
        except Exception:
            restore_activation(settings, activation)
            raise
        return installed
    finally:
        if staging.exists():
            _remove_tree(staging)


def activate_prebuilt(settings, release_id):
    """Verify and atomically activate one already-copied immutable release."""
    _validate_layout(settings)
    release_id = str(release_id or "")
    if (
        not release_id
        or release_id != Path(release_id).name
        or release_id in {".", ".."}
        or "/" in release_id
        or "\\" in release_id
    ):
        raise RuntimeError("prebuilt Operator release ID is invalid")
    releases = releases_dir(settings)
    candidate = releases / release_id
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError(
            "prebuilt Operator release does not exist: %s" % release_id
        ) from exc
    if resolved.parent != releases.resolve() or resolved.name != release_id:
        raise RuntimeError("prebuilt Operator release escapes the release store")
    installed = _read_release(resolved)
    _install_entrypoints(installed, settings)
    _atomic_symlink(Path("releases") / release_id, current_path(settings))
    return installed


def current(settings, required=False):
    pointer = current_path(settings)
    if not pointer.is_symlink():
        if required:
            raise RuntimeError("Black Label Operator has no active immutable release")
        return None
    try:
        return _read_release(pointer.resolve(strict=True))
    except (OSError, RuntimeError) as exc:
        if required:
            raise RuntimeError("Black Label Operator current release is invalid: %s" % exc)
        return None


def _remove_tree(path):
    path = Path(path)
    if not path.exists():
        return
    for target in path.rglob("*"):
        if target.is_symlink():
            continue
        try:
            target.chmod(0o700 if target.is_dir() else 0o600)
        except OSError:
            pass
    path.chmod(0o700)
    shutil.rmtree(str(path))


def _restore_entrypoints(settings):
    backup_dir = settings.resolved_install_root / "backups/entrypoints"
    retained = []
    for name in ENTRYPOINTS:
        destination = settings.resolved_bin_dir / name
        backup = backup_dir / name
        if _owned_entrypoint(destination, settings):
            destination.unlink()
        if os.path.lexists(str(backup)):
            if os.path.lexists(str(destination)):
                retained.append(str(backup))
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                os.replace(str(backup), str(destination))
    return retained


def _purge_state(settings):
    state = settings.home.expanduser().resolve()
    forbidden = {
        Path("/").resolve(),
        settings.resolved_user_home,
        settings.resolved_install_root,
    }
    if state in forbidden:
        raise RuntimeError("refusing to purge unsafe Operator state path: %s" % state)
    if _inside(settings.resolved_user_home, state):
        raise RuntimeError("refusing to purge an ancestor of the user home: %s" % state)
    existed = state.exists()
    if existed:
        _remove_tree(state)
    return existed


def uninstall(settings, purge_state=False):
    _validate_layout(settings)
    retained = _restore_entrypoints(settings)
    pointer = current_path(settings)
    if pointer.is_symlink() or pointer.exists():
        pointer.unlink()
    removed_install = False
    if settings.resolved_install_root.exists() and not retained:
        _remove_tree(settings.resolved_install_root)
        removed_install = True
    state_purged = _purge_state(settings) if purge_state else False
    return {
        "entrypoints": list(ENTRYPOINTS),
        "install_removed": removed_install,
        "retained_backups": retained,
        "state_preserved": not purge_state,
        "state_purged": state_purged,
    }


def _validate_layout(settings):
    install_root = settings.resolved_install_root
    user_home = settings.resolved_user_home
    forbidden = {Path("/").resolve(), user_home, user_home / ".local"}
    if install_root in forbidden or _inside(user_home, install_root):
        raise RuntimeError("unsafe Operator install root: %s" % install_root)
