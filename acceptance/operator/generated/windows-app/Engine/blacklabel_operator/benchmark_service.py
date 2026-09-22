import os
import plistlib
import subprocess
import time
from pathlib import Path

from .benchmark_campaign import default_max_load, load_campaign


LABEL = "com.blacklabel.operator.benchmark-campaign"


def domain():
    return "gui/%d" % os.getuid()


def plist_path():
    return Path.home() / ("Library/LaunchAgents/%s.plist" % LABEL)


def service_target():
    return "%s/%s" % (domain(), LABEL)


def render_plist(
    settings,
    campaign_dir,
    batch_size=8,
    n_concurrent=1,
    timeout=604800,
    poll_seconds=900,
    max_load=None,
):
    campaign_dir = Path(campaign_dir).resolve()
    campaign = load_campaign(campaign_dir)
    source = Path(campaign["operator_source_path"])
    operator = source / "bin/operator"
    resolved_max_load = default_max_load() if max_load is None else float(max_load)
    if resolved_max_load <= 0:
        raise ValueError("campaign max load must be positive")
    path = ":".join(
        [
            str(Path.home() / ".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    )
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(operator),
            "benchmark",
            "campaign",
            "supervise",
            "--campaign",
            str(campaign_dir),
            "--batch-size",
            str(max(1, int(batch_size))),
            "--n-concurrent",
            str(max(1, int(n_concurrent))),
            "--timeout",
            str(float(timeout)),
            "--poll-seconds",
            str(max(60.0, float(poll_seconds))),
            "--max-load",
            str(resolved_max_load),
        ],
        "WorkingDirectory": str(source),
        "EnvironmentVariables": {
            "HOME": str(Path.home()),
            "PATH": path,
            "PYTHONPATH": str(source),
            "PYTHONUNBUFFERED": "1",
            "OPERATOR_HOME": str(settings.home),
            "OPERATOR_REPO": str(source),
            "OPERATOR_CODEX_BIN": str(settings.codex_bin),
            "OPERATOR_MODEL": "gpt-5.6-sol",
        },
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "AbandonProcessGroup": False,
        "ProcessType": "Background",
        "ThrottleInterval": 60,
        "StandardOutPath": str(campaign_dir / "supervisor.stdout.log"),
        "StandardErrorPath": str(campaign_dir / "supervisor.stderr.log"),
        "SoftResourceLimits": {"NumberOfFiles": 65536},
    }


def is_loaded():
    completed = subprocess.run(
        ["launchctl", "print", service_target()],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return completed.returncode == 0


def _wait_for_loaded(expected, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if is_loaded() is expected:
            return True
        time.sleep(0.1)
    return is_loaded() is expected


def stop():
    if is_loaded():
        subprocess.run(["launchctl", "bootout", service_target()], check=True)
        if not _wait_for_loaded(False):
            raise RuntimeError("benchmark campaign LaunchAgent did not stop")


def install(
    settings,
    campaign_dir,
    batch_size=8,
    n_concurrent=1,
    timeout=604800,
    poll_seconds=900,
    max_load=None,
    start=True,
):
    target = plist_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = render_plist(
        settings,
        campaign_dir,
        batch_size=batch_size,
        n_concurrent=n_concurrent,
        timeout=timeout,
        poll_seconds=poll_seconds,
        max_load=max_load,
    )
    temporary = target.with_suffix(".plist.tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=True)
    temporary.chmod(0o600)
    temporary.replace(target)
    if start:
        stop()
        subprocess.run(["launchctl", "bootstrap", domain(), str(target)], check=True)
        if not _wait_for_loaded(True):
            raise RuntimeError("benchmark campaign LaunchAgent did not start")
    return target


def details():
    completed = subprocess.run(
        ["launchctl", "print", service_target()],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return completed.returncode, completed.stdout
