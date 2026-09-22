import os
import plistlib
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, replace
from pathlib import Path


LABEL = "com.blacklabel.operator"
LEGACY_LABEL = "com.blacklabel.sol-harness"
SYSTEMD_UNIT = "blacklabel-operator.service"


@dataclass(frozen=True)
class ServiceState:
    backend: str
    path: Path
    existed: bool
    content: object
    mode: object
    loaded: bool
    legacy_loaded: bool


def backend_name(platform=None):
    platform = platform or sys.platform
    if platform == "darwin":
        return "launchd"
    if platform.startswith("linux"):
        return "systemd"
    raise RuntimeError(
        "24/7 service installation supports macOS launchd and Linux systemd; "
        "run `operator daemon` under the platform service manager on this host"
    )


def domain():
    return "gui/%d" % os.getuid()


def _user_home(settings=None):
    return settings.resolved_user_home if settings is not None else Path.home().resolve()


def plist_path(label=LABEL, settings=None):
    return _user_home(settings) / ("Library/LaunchAgents/%s.plist" % label)


def systemd_path(settings=None):
    return _user_home(settings) / ".config/systemd/user" / SYSTEMD_UNIT


def service_path(platform=None, settings=None):
    return (
        plist_path(settings=settings)
        if backend_name(platform) == "launchd"
        else systemd_path(settings=settings)
    )


def service_target(label=LABEL):
    return "%s/%s" % (domain(), label)


def _search_path(settings=None):
    candidates = list(os.environ.get("PATH", "").split(os.pathsep))
    candidates.extend(
        [
            str(
                settings.resolved_bin_dir
                if settings is not None
                else Path.home() / ".local/bin"
            ),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    )
    return os.pathsep.join(dict.fromkeys(item for item in candidates if item))


def _runtime_path(runtime):
    path = getattr(runtime, "path", runtime)
    if path is None:
        raise RuntimeError("an immutable Operator release is required")
    return Path(path).expanduser().resolve()


def _daemon_argv(runtime):
    launcher = (_runtime_path(runtime) / "bin/operator").resolve()
    if not launcher.is_file():
        raise RuntimeError("immutable Operator daemon entrypoint is missing: %s" % launcher)
    return [str(launcher), "daemon"]


def service_environment(settings, runtime):
    runtime_path = _runtime_path(runtime)
    runtime_repo = getattr(runtime, "repo_root", runtime_path / "source")
    return {
        "HOME": str(settings.resolved_user_home),
        "PATH": _search_path(settings),
        "PYTHONUNBUFFERED": "1",
        "OPERATOR_HOME": str(settings.home),
        "OPERATOR_REPO": str(runtime_repo),
        "OPERATOR_RUNTIME_REPO": str(runtime_repo),
        "OPERATOR_CODEX_BIN": str(settings.codex_bin),
        "OPERATOR_MODEL": settings.model,
        "OPERATOR_PROVIDER": settings.provider,
        "OPERATOR_PROFILE": settings.profile,
        "OPERATOR_EFFORT": settings.effort,
        "OPERATOR_SANDBOX": settings.sandbox,
        "OPERATOR_PORT": str(settings.port),
        "OPERATOR_WORKERS": str(settings.workers),
        "OPERATOR_LEASE_SECONDS": str(settings.lease_seconds),
        "OPERATOR_TASK_TIMEOUT_SECONDS": str(settings.task_timeout_seconds),
        "OPERATOR_RELEASE_ID": str(runtime.release_id),
        "OPERATOR_RELEASE_MANIFEST_SHA256": str(runtime.manifest_sha256),
        "OPERATOR_RUNTIME_SHA256": str(runtime.runtime_sha256),
    }


def render_plist(settings, runtime):
    return {
        "Label": LABEL,
        "ProgramArguments": _daemon_argv(runtime),
        "WorkingDirectory": str(settings.home),
        "EnvironmentVariables": service_environment(settings, runtime),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Background",
        "ThrottleInterval": 5,
        "StandardOutPath": str(settings.logs_dir / "daemon.stdout.log"),
        "StandardErrorPath": str(settings.logs_dir / "daemon.stderr.log"),
        "SoftResourceLimits": {"NumberOfFiles": 8192},
    }


def _systemd_quote(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def render_systemd_unit(settings, runtime):
    lines = [
        "[Unit]",
        "Description=Black Label Operator",
        "After=network-online.target",
        "Wants=network-online.target",
        "",
        "[Service]",
        "Type=simple",
        "WorkingDirectory=%s" % _systemd_quote(settings.home),
        "ExecStart=%s"
        % " ".join(
            '"%s"' % _systemd_quote(arg) for arg in _daemon_argv(runtime)
        ),
        "Restart=on-failure",
        "RestartSec=5",
        "LimitNOFILE=8192",
    ]
    for key, value in service_environment(settings, runtime).items():
        lines.append('Environment="%s=%s"' % (key, _systemd_quote(value)))
    lines.extend(["", "[Install]", "WantedBy=default.target", ""])
    return "\n".join(lines)


def _run(command, capture=False):
    return subprocess.run(
        command,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.STDOUT if capture else subprocess.DEVNULL,
        text=True,
        check=False,
    )


def is_loaded(label=LABEL, settings=None, platform=None):
    backend = backend_name(platform)
    if backend == "launchd":
        return _run(["launchctl", "print", service_target(label)]).returncode == 0
    if label != LABEL:
        return False
    return (
        _run(["systemctl", "--user", "is-active", "--quiet", SYSTEMD_UNIT]).returncode
        == 0
    )


def wait_for_loaded(expected, timeout=10.0, settings=None, platform=None, label=LABEL):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if is_loaded(label=label, settings=settings, platform=platform) is expected:
            return True
        time.sleep(0.1)
    return is_loaded(label=label, settings=settings, platform=platform) is expected


def _write_launchd(settings, runtime):
    target = plist_path(settings=settings)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".plist.tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(render_plist(settings, runtime), handle, sort_keys=True)
    temporary.chmod(0o600)
    temporary.replace(target)
    return target


def _write_systemd(settings, runtime):
    if not shutil.which("systemctl"):
        raise RuntimeError("systemctl is required for Linux 24/7 installation")
    target = systemd_path(settings=settings)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".service.tmp")
    temporary.write_text(render_systemd_unit(settings, runtime), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(target)
    completed = _run(["systemctl", "--user", "daemon-reload"], capture=True)
    if completed.returncode != 0:
        raise RuntimeError("systemd daemon-reload failed: %s" % completed.stdout.strip())
    return target


def _existing_environment(settings, platform=None):
    backend = backend_name(platform)
    target = service_path(platform=platform, settings=settings)
    if not target.is_file():
        return {}
    if backend == "launchd":
        try:
            with target.open("rb") as handle:
                payload = plistlib.load(handle)
        except (OSError, ValueError):
            return {}
        environment = payload.get("EnvironmentVariables", {})
        return environment if isinstance(environment, dict) else {}
    environment = {}
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError:
        return environment
    for line in lines:
        if not line.startswith('Environment="') or not line.endswith('"'):
            continue
        assignment = line[len('Environment="') : -1]
        if "=" in assignment:
            key, value = assignment.split("=", 1)
            environment[key] = value
    return environment


def preserve_existing_settings(settings, platform=None):
    """Carry forward an installed worker count unless this invocation overrides it."""
    if "OPERATOR_WORKERS" in os.environ or "SOL_WORKERS" in os.environ:
        return settings
    value = _existing_environment(settings, platform=platform).get("OPERATOR_WORKERS")
    try:
        workers = max(1, int(value))
    except (TypeError, ValueError):
        return settings
    return replace(settings, workers=workers)


def capture_state(settings, platform=None):
    """Capture the exact service file and loaded state for transaction rollback."""
    backend = backend_name(platform)
    target = service_path(platform=platform, settings=settings)
    existed = target.is_file()
    content = target.read_bytes() if existed else None
    mode = target.stat().st_mode & 0o777 if existed else None
    return ServiceState(
        backend=backend,
        path=target,
        existed=existed,
        content=content,
        mode=mode,
        loaded=is_loaded(settings=settings, platform=platform),
        legacy_loaded=(
            is_loaded(LEGACY_LABEL, settings=settings, platform=platform)
            if backend == "launchd"
            else False
        ),
    )


def suspend_state(settings, state):
    """Stop captured jobs and close their old restart path for the transaction."""
    if not isinstance(state, ServiceState):
        raise TypeError("an Operator ServiceState is required")
    platform = "darwin" if state.backend == "launchd" else "linux"
    if is_loaded(settings=settings, platform=platform):
        _deactivate(settings, state.backend)
    if state.backend == "launchd" and is_loaded(
        LEGACY_LABEL, settings=settings, platform="darwin"
    ):
        _deactivate(settings, state.backend, label=LEGACY_LABEL)

    if is_loaded(settings=settings, platform=platform):
        raise RuntimeError("Black Label Operator service remained active")
    if state.backend == "launchd" and is_loaded(
        LEGACY_LABEL, settings=settings, platform="darwin"
    ):
        raise RuntimeError("legacy Black Label Operator service remained active")

    if os.path.lexists(str(state.path)):
        if not state.existed or not state.path.is_file():
            raise RuntimeError(
                "Operator service file changed after lifecycle capture: %s"
                % state.path
            )
        if state.path.read_bytes() != state.content:
            raise RuntimeError(
                "Operator service file changed after lifecycle capture: %s"
                % state.path
            )
        state.path.unlink()
    elif state.existed:
        raise RuntimeError(
            "Operator service file disappeared after lifecycle capture: %s"
            % state.path
        )
    if state.backend == "systemd":
        completed = _run(["systemctl", "--user", "daemon-reload"], capture=True)
        if completed.returncode != 0:
            raise RuntimeError(
                "systemd daemon-reload failed while suspending Operator: %s"
                % completed.stdout.strip()
            )


def _bootout(settings, label=LABEL):
    subprocess.run(["launchctl", "bootout", service_target(label)], check=True)
    if not wait_for_loaded(False, settings=settings, platform="darwin", label=label):
        raise RuntimeError("Black Label Operator service did not leave the active state")


def _bootstrap(settings, label=LABEL, path=None):
    path = path or plist_path(label=label, settings=settings)
    subprocess.run(
        ["launchctl", "bootstrap", domain(), str(path)],
        check=True,
    )
    if not wait_for_loaded(True, settings=settings, platform="darwin", label=label):
        raise RuntimeError("Black Label Operator service did not enter the active state")


def _deactivate(settings, backend, label=LABEL):
    if backend == "launchd":
        _bootout(settings, label=label)
        return
    subprocess.run(["systemctl", "--user", "stop", SYSTEMD_UNIT], check=True)
    if not wait_for_loaded(False, settings=settings, platform="linux"):
        raise RuntimeError("Black Label Operator service did not leave the active state")


def _activate(settings, backend, label=LABEL, path=None):
    if backend == "launchd":
        _bootstrap(settings, label=label, path=path)
        return
    subprocess.run(
        ["systemctl", "--user", "enable", "--now", SYSTEMD_UNIT], check=True
    )
    if not wait_for_loaded(True, settings=settings, platform="linux"):
        raise RuntimeError("Black Label Operator service did not enter the active state")


def _atomic_restore_file(target, content, mode):
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / (".%s.rollback-%s" % (target.name, uuid.uuid4().hex))
    try:
        temporary.write_bytes(content)
        temporary.chmod(mode)
        os.replace(str(temporary), str(target))
    finally:
        if temporary.exists():
            temporary.unlink()


def resume_state(settings, state):
    """Recreate the loaded jobs recorded in a captured service state."""
    if state.loaded:
        _activate(settings, state.backend, path=state.path)
    if state.backend == "launchd" and state.legacy_loaded and not is_loaded(
        LEGACY_LABEL, settings=settings, platform="darwin"
    ):
        _activate(
            settings,
            state.backend,
            label=LEGACY_LABEL,
            path=plist_path(label=LEGACY_LABEL, settings=settings),
        )


def restore_state(settings, state, start=True):
    """Restore a captured service file and cached service-manager state."""
    if not isinstance(state, ServiceState):
        raise TypeError("an Operator ServiceState is required")
    backend = state.backend
    if is_loaded(settings=settings, platform=("darwin" if backend == "launchd" else "linux")):
        _deactivate(settings, backend)
    if backend == "launchd" and is_loaded(
        LEGACY_LABEL, settings=settings, platform="darwin"
    ) and not state.legacy_loaded:
        _deactivate(settings, backend, label=LEGACY_LABEL)

    if state.existed:
        _atomic_restore_file(state.path, state.content, state.mode)
    elif state.path.exists() or state.path.is_symlink():
        state.path.unlink()
    if backend == "systemd":
        completed = _run(["systemctl", "--user", "daemon-reload"], capture=True)
        if completed.returncode != 0:
            raise RuntimeError(
                "systemd daemon-reload failed during rollback: %s"
                % completed.stdout.strip()
            )

    if start:
        resume_state(settings, state)


def install(settings, runtime, start=True):
    settings.ensure_dirs()
    backend = backend_name()
    previous = capture_state(settings)
    try:
        # A plist rewrite does not update launchd's cached ProgramArguments.
        # Always boot out the old job first, including --no-start upgrades.
        if previous.loaded:
            _deactivate(settings, backend)
        if backend == "launchd" and previous.legacy_loaded:
            _deactivate(settings, backend, label=LEGACY_LABEL)
        target = (
            _write_launchd(settings, runtime)
            if backend == "launchd"
            else _write_systemd(settings, runtime)
        )
        if start:
            _activate(settings, backend, path=target)
        return target
    except Exception as exc:
        try:
            restore_state(settings, previous)
        except Exception as rollback_exc:
            raise RuntimeError(
                "Operator service install failed (%s); rollback failed (%s)"
                % (exc, rollback_exc)
            ) from exc
        raise


def start(settings=None):
    backend = backend_name()
    if backend == "launchd":
        if is_loaded(settings=settings):
            subprocess.run(
                ["launchctl", "kickstart", "-k", service_target()], check=True
            )
        else:
            _activate(settings, backend, path=plist_path(settings=settings))
    else:
        _activate(settings, backend)
    if not wait_for_loaded(True, settings=settings, platform=sys.platform):
        raise RuntimeError("Black Label Operator service did not enter the active state")


def stop(settings=None):
    if not is_loaded(settings=settings):
        return
    _deactivate(settings, backend_name())


def restart(settings=None):
    stop(settings)
    start(settings)


def details(settings=None):
    if backend_name() == "launchd":
        completed = _run(["launchctl", "print", service_target()], capture=True)
    else:
        completed = _run(
            ["systemctl", "--user", "status", "--no-pager", SYSTEMD_UNIT],
            capture=True,
        )
    return completed.returncode, completed.stdout


def uninstall(settings):
    backend = backend_name()
    stop(settings)
    target = service_path(settings=settings)
    removed = target.exists()
    if removed:
        target.unlink()
    if backend == "systemd":
        _run(["systemctl", "--user", "disable", SYSTEMD_UNIT], capture=True)
        _run(["systemctl", "--user", "daemon-reload"], capture=True)
    return {"backend": backend, "service_file": str(target), "removed": removed}
