import os
import shutil
import subprocess
from pathlib import Path


GROK_REPOSITORY = "https://github.com/xai-org/grok-build.git"


def _is_grok_source(path):
    path = Path(path)
    return (path / "Cargo.toml").is_file() and (
        path / "crates/codegen/xai-grok-pager-bin/Cargo.toml"
    ).is_file()


def find_source(settings):
    configured = os.environ.get("OPERATOR_GROK_SOURCE")
    candidates = [
        Path(configured).expanduser() if configured else None,
        settings.repo_root,
        settings.home / "sources/grok-build",
    ]
    for candidate in candidates:
        if candidate and _is_grok_source(candidate):
            return candidate.resolve()
    return None


def ensure_source(settings):
    existing = find_source(settings)
    if existing:
        return existing
    destination = settings.home / "sources/grok-build"
    destination.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["git", "clone", "--depth", "1", GROK_REPOSITORY, str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=600,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("Grok Build clone failed: %s" % completed.stdout[-2000:])
    return destination.resolve()


def find_binary(settings):
    source = find_source(settings)
    candidates = []
    if source:
        candidates.extend(
            [
                source / "target/release/xai-grok-pager",
                source / "target/debug/xai-grok-pager",
            ]
        )
    installed = shutil.which("grok")
    if installed:
        candidates.append(Path(installed))
    for candidate in candidates:
        if candidate.is_file() and os.access(str(candidate), os.X_OK):
            return candidate.resolve()
    return None


def build(settings, release=False):
    source = ensure_source(settings)
    command = ["cargo", "build", "-p", "xai-grok-pager-bin"]
    if release:
        command.append("--release")
    completed = subprocess.run(command, cwd=str(source), check=False)
    if completed.returncode != 0:
        return completed.returncode, source, None
    binary = source / "target" / ("release" if release else "debug") / "xai-grok-pager"
    if not binary.is_file():
        raise RuntimeError("Grok Build completed without the expected binary")
    install_dir = Path.home() / ".local/bin"
    install_dir.mkdir(parents=True, exist_ok=True)
    link = install_dir / "grok"
    if not link.exists() and not link.is_symlink():
        link.symlink_to(binary.resolve())
    return 0, source, binary.resolve()
