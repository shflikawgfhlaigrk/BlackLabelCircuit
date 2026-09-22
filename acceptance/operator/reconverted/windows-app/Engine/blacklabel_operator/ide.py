import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


SERVER_NAME = "black-label-operator"


def config_path():
    configured = os.environ.get("OPERATOR_ANTIGRAVITY_MCP_CONFIG")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path.home() / ".gemini/config/mcp_config.json"


def mcp_spec(settings, cwd):
    return {
        # This path is stable across upgrades while its `current` indirection
        # resolves to the fully verified immutable release.
        "command": str(settings.resolved_bin_dir / "operator-mcp"),
        "args": [],
        "cwd": str(Path(cwd).expanduser().resolve()),
        "env": {
            "OPERATOR_HOME": str(settings.home),
            "OPERATOR_REPO": str(settings.repo_root),
            "OPERATOR_CODEX_BIN": str(settings.codex_bin),
            "OPERATOR_MODEL": settings.model,
            "OPERATOR_PROVIDER": settings.provider,
            "OPERATOR_PROFILE": settings.profile,
        },
    }


def _read_config(path):
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("Antigravity MCP config must contain a JSON object")
    servers = value.get("mcpServers")
    if servers is not None and not isinstance(servers, dict):
        raise ValueError("Antigravity mcpServers must contain a JSON object")
    return value


def install(settings, cwd):
    target = config_path()
    value = _read_config(target)
    servers = dict(value.get("mcpServers") or {})
    servers[SERVER_NAME] = mcp_spec(settings, cwd)
    value["mcpServers"] = servers
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.chmod(0o600)
    temporary.replace(target)
    return status(settings, cwd)


def uninstall():
    target = config_path()
    value = _read_config(target)
    servers = dict(value.get("mcpServers") or {})
    removed = servers.pop(SERVER_NAME, None) is not None
    value["mcpServers"] = servers
    if removed:
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        temporary.chmod(0o600)
        temporary.replace(target)
    return {"configured": False, "removed": removed, "config": str(target)}


def status(settings, cwd):
    target = config_path()
    value = _read_config(target)
    actual = (value.get("mcpServers") or {}).get(SERVER_NAME)
    expected = mcp_spec(settings, cwd)
    return {
        "configured": actual == expected,
        "config": str(target),
        "server": SERVER_NAME,
        "command": expected["command"],
        "cwd": expected["cwd"],
        "current": actual,
    }


def find_launcher():
    configured = os.environ.get("OPERATOR_IDE_BIN")
    candidates = [
        Path(configured).expanduser() if configured else None,
        Path(shutil.which("antigravity-ide")) if shutil.which("antigravity-ide") else None,
        Path(shutil.which("antigravity")) if shutil.which("antigravity") else None,
    ]
    if sys.platform == "darwin":
        for name in ("Antigravity IDE.app", "Antigravity.app"):
            candidates.append(
                Path("/Applications")
                / name
                / "Contents/Resources/app/bin/antigravity-ide"
            )
    for candidate in candidates:
        if candidate and candidate.is_file() and os.access(str(candidate), os.X_OK):
            return candidate.resolve()
    return None


def open_workspace(settings, cwd):
    result = install(settings, cwd)
    launcher = find_launcher()
    if not launcher:
        raise RuntimeError(
            "Antigravity launcher was not found; set OPERATOR_IDE_BIN to its executable"
        )
    subprocess.run([str(launcher), "--new-window", str(Path(cwd).resolve())], check=True)
    result.update({"opened": str(Path(cwd).resolve()), "launcher": str(launcher)})
    return result
