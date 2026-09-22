import json
import os
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

from .codex_runner import EventAccumulator


QUOTA_MARKER = "You've hit your usage limit"
QUOTA_AVAILABILITY_FILE = ".exact-sol-available.json"
QUOTA_RESET_PATTERN = re.compile(
    r"try again at\s+([A-Za-z]{3}\s+\d{1,2}(?:st|nd|rd|th)?,\s+"
    r"\d{4}\s+\d{1,2}:\d{2}\s+[AP]M)",
    re.IGNORECASE,
)


def quota_info_from_text(text):
    text = str(text or "")
    if QUOTA_MARKER.lower() not in text.lower():
        return None
    match = QUOTA_RESET_PATTERN.search(text)
    retry_at = None
    retry_at_local = None
    if match:
        normalized = re.sub(r"(\d{1,2})(?:st|nd|rd|th)", r"\1", match.group(1))
        parsed = datetime.strptime(normalized, "%b %d, %Y %I:%M %p")
        retry_at = time.mktime(parsed.timetuple())
        retry_at_local = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(retry_at))
    return {
        "exception_type": "ProviderQuotaExceeded",
        "message": "Codex subscription quota exhausted",
        "retry_at": retry_at,
        "retry_at_local": retry_at_local,
    }


def quota_info_from_result(path):
    path = Path(path)
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    info = quota_info_from_text(raw)
    if info is None:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        payload = {}
    info["task_state"] = payload.get("state")
    return info


def quota_info_for_trial(trial_dir):
    trial_dir = Path(trial_dir)
    for path in sorted((trial_dir / "agent").glob("operator-pass-*.json")):
        info = quota_info_from_result(path)
        if info is not None:
            return info
    return None


def _availability_marker(benchmark_dir):
    path = Path(benchmark_dir) / QUOTA_AVAILABILITY_FILE
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        verified_at = float(payload.get("verified_at") or 0)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None
    return payload if verified_at > 0 else None


def record_quota_available(benchmark_dir, probe, now=None):
    benchmark_dir = Path(benchmark_dir)
    benchmark_dir.mkdir(parents=True, exist_ok=True)
    path = benchmark_dir / QUOTA_AVAILABILITY_FILE
    payload = {
        "schema": "black-label-operator/exact-sol-availability-v1",
        "verified_at": time.time() if now is None else float(now),
        "model": "gpt-5.6-sol",
        "thread_id": probe.get("thread_id"),
        "input_tokens": int(probe.get("input_tokens") or 0),
        "output_tokens": int(probe.get("output_tokens") or 0),
    }
    temporary = path.with_name(path.name + ".tmp-%d" % os.getpid())
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    return payload


def probe_exact_sol(settings, timeout=180):
    command = [
        str(settings.codex_bin),
        "exec",
        "--ignore-user-config",
        "--ephemeral",
        "--skip-git-repo-check",
        "-C",
        str(settings.repo_root),
        "-m",
        "gpt-5.6-sol",
        "-s",
        "read-only",
        "-c",
        'model_reasoning_effort="low"',
    ]
    for item in (
        "skills.include_instructions=false",
        "features.plugins=false",
        "features.skill_search=false",
        "features.memories=false",
        "features.multi_agent=false",
        "features.apps=false",
        "suppress_unstable_features_warning=true",
    ):
        command.extend(["-c", item])
    command.extend(["--json", "Reply with exactly SOL_DOCTOR_OK"])
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=float(timeout),
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        return {
            "ok": False,
            "reply": "",
            "thread_id": None,
            "input_tokens": 0,
            "output_tokens": 0,
            "stderr": str(error),
        }
    accumulator = EventAccumulator()
    for line in completed.stdout.splitlines():
        try:
            accumulator.add(json.loads(line))
        except json.JSONDecodeError:
            continue
    result = accumulator.result(completed.returncode)
    return {
        "ok": result.success and result.final_text.strip() == "SOL_DOCTOR_OK",
        "reply": result.final_text.strip(),
        "thread_id": result.thread_id,
        "input_tokens": result.input_tokens,
        "output_tokens": result.output_tokens,
        "stderr": completed.stderr[-2000:],
    }


def active_quota_block(benchmark_dir, now=None):
    benchmark_dir = Path(benchmark_dir)
    now = time.time() if now is None else float(now)
    marker = _availability_marker(benchmark_dir) or {}
    verified_at = float(marker.get("verified_at") or 0)
    active = None
    if not benchmark_dir.is_dir():
        return None
    for path in benchmark_dir.rglob("operator-pass-*.json"):
        try:
            if path.stat().st_mtime <= verified_at:
                continue
        except OSError:
            continue
        info = quota_info_from_result(path)
        retry_at = (info or {}).get("retry_at")
        if retry_at is None or retry_at <= now:
            continue
        if active is None or retry_at > active["retry_at"]:
            active = dict(info)
            active["evidence_path"] = str(path)
    return active


def require_quota_available(benchmark_dir, now=None):
    block = active_quota_block(benchmark_dir, now=now)
    if block is None:
        return None
    raise RuntimeError(
        "Codex subscription quota is unavailable until %s; benchmark was not started"
        % (block.get("retry_at_local") or "the provider reset")
    )
