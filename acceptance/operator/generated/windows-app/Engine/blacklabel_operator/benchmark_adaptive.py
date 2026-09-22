"""Evidence-gated adaptive execution for custom Harbor benchmark agents.

The official benchmark instruction is an input artifact, never a prompt that is
rewritten in place.  The planner and critic can inspect the task only through a
read-only Sol invocation, while the executor is the sole writable Sol stage.
Planner-declared verification commands run deterministically between those
stages and every durable artifact is bound into a hash-chained episode journal.

This module intentionally uses :class:`AdaptiveExecutionEngine` directly.  It
does not use the daemon's adaptive runtime because benchmark trials need a
small, disclosure-complete orchestration layer whose model sessions Harbor can
merge into one ATIF trajectory.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence, Tuple

from .adaptive_execution import (
    AdaptiveExecutionCallbacks,
    AdaptiveExecutionEngine,
    ArbitrationResult,
    Artifact,
    BudgetLimits,
    CritiqueResult,
    Evidence,
    ExecutionResult,
    PlanResult,
    Usage,
    VerificationResult,
)


EPISODE_SCHEMA = "black-label-operator/benchmark-adaptive-v1"
PROVIDER_SCHEMA = "black-label-operator/benchmark-provider-v1"
COMMAND_SCHEMA = "black-label-operator/benchmark-command-v1"
RESULT_SCHEMA = "black-label-operator/benchmark-adaptive-result-v1"
MAX_COMMANDS = 16
MAX_COMMAND_BYTES = 8_000
MAX_COMMAND_OUTPUT_BYTES = 256 * 1024
MAX_PROVIDER_PROMPT_BYTES = 256 * 1024
MAX_VERIFIER_TIMEOUT_SECONDS = 1_800
_ZERO_SHA256 = "0" * 64
_TASK_ID = re.compile(r'"task_id"\s*:\s*"([^"\\]+)"')
_NUMERIC_SEMANTIC_HINT = re.compile(
    r"(?ix)\b(?:amount|concentration|count|detection\s+limit|duration|efficiency|"
    r"factor|mass|mean|median|percent(?:age)?|probability|quantity|rate|ratio|"
    r"score|speed|temperature|time|volume|weight)\b|(?:\b\d+(?:\.\d+)?\s*(?:%|"
    r"bq(?:/kg)?|bytes?|cpm|gb|hz|kg|mb|ms|s(?:ec(?:ond)?s?)?)\b)"
)
_CRITIC_CHECK_KINDS = {
    "output-contract",
    "semantic-invariants",
    "source-or-test",
    "cross-check",
}


class BenchmarkAdaptiveError(RuntimeError):
    """The custom benchmark lane could not preserve its evidence contract."""


def _plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_plain(item) for item in value]
    return value


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        _plain(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_json(value: Any) -> str:
    return _sha256_bytes(_canonical_bytes(value))


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BenchmarkAdaptiveError("invalid durable JSON artifact: %s" % path) from exc


def _write_once(path: Path, value: Any) -> str:
    """Create an immutable canonical JSON artifact, or verify the existing one."""

    path = Path(path)
    payload = _canonical_bytes(value) + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(
            str(path),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
    except FileExistsError:
        try:
            existing = path.read_bytes()
        except OSError as exc:
            raise BenchmarkAdaptiveError("cannot read durable artifact: %s" % path) from exc
        if existing != payload:
            raise BenchmarkAdaptiveError("durable artifact identity changed: %s" % path)
        return _sha256_bytes(existing)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        path.chmod(0o400)
    except BaseException:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise
    return _sha256_bytes(payload)


def _write_atomic(path: Path, value: Any) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = _canonical_bytes(value) + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(path))
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class HashChainJournal:
    """Append-only, replay-validated episode journal with idempotent event IDs."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._events = self._load()
        self._by_id = {event["event_id"]: event for event in self._events}

    def _load(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        events = []
        previous = _ZERO_SHA256
        try:
            lines = self.path.read_bytes().splitlines()
        except OSError as exc:
            raise BenchmarkAdaptiveError("cannot read episode journal") from exc
        for offset, line in enumerate(lines, start=1):
            try:
                event = json.loads(line.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise BenchmarkAdaptiveError(
                    "episode journal line %d is invalid" % offset
                ) from exc
            if not isinstance(event, dict):
                raise BenchmarkAdaptiveError("episode journal events must be objects")
            digest = event.get("event_sha256")
            body = dict(event)
            body.pop("event_sha256", None)
            if event.get("schema") != EPISODE_SCHEMA:
                raise BenchmarkAdaptiveError("episode journal schema mismatch")
            if event.get("seq") != offset or event.get("previous_sha256") != previous:
                raise BenchmarkAdaptiveError("episode journal chain discontinuity")
            if digest != _sha256_json(body):
                raise BenchmarkAdaptiveError("episode journal event hash mismatch")
            previous = str(digest)
            events.append(event)
        identifiers = [event.get("event_id") for event in events]
        if any(not isinstance(value, str) or not value for value in identifiers):
            raise BenchmarkAdaptiveError("episode journal event IDs are invalid")
        if len(set(identifiers)) != len(identifiers):
            raise BenchmarkAdaptiveError("episode journal event IDs are not unique")
        return events

    @property
    def events(self) -> Tuple[Mapping[str, Any], ...]:
        return tuple(self._events)

    def record_once(self, event_id: str, kind: str, payload: Mapping[str, Any]) -> str:
        body_payload = json.loads(_canonical_bytes(dict(payload)).decode("utf-8"))
        existing = self._by_id.get(event_id)
        if existing is not None:
            if existing.get("kind") != kind or existing.get("payload") != body_payload:
                raise BenchmarkAdaptiveError(
                    "episode event identity changed: %s" % event_id
                )
            return str(existing["event_sha256"])
        previous = (
            str(self._events[-1]["event_sha256"]) if self._events else _ZERO_SHA256
        )
        event = {
            "schema": EPISODE_SCHEMA,
            "seq": len(self._events) + 1,
            "event_id": str(event_id),
            "kind": str(kind),
            "previous_sha256": previous,
            "payload": body_payload,
        }
        event["event_sha256"] = _sha256_json(event)
        line = _canonical_bytes(event) + b"\n"
        descriptor = os.open(
            str(self.path),
            os.O_WRONLY
            | os.O_APPEND
            | os.O_CREAT
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        with os.fdopen(descriptor, "ab") as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
        self._events.append(event)
        self._by_id[event_id] = event
        return str(event["event_sha256"])


@dataclass(frozen=True)
class ProviderRequest:
    round_index: int
    stage: str
    prompt: str
    sandbox: str


@dataclass(frozen=True)
class ProviderOutcome:
    success: bool
    final_text: str
    task_id: str
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0
    state: str = "succeeded"

    @property
    def usage(self) -> Usage:
        return Usage(
            tokens=self.input_tokens + self.output_tokens,
            cost_micros=0,
        )


@dataclass(frozen=True)
class CommandRequest:
    round_index: int
    command_index: int
    command: str
    timeout_seconds: int
    cwd: Path


@dataclass(frozen=True)
class CommandOutcome:
    exit_code: int
    output: bytes
    timed_out: bool = False


def _provider_outcome(value: Any) -> ProviderOutcome:
    if isinstance(value, ProviderOutcome):
        return value
    if not isinstance(value, Mapping):
        raise BenchmarkAdaptiveError("provider must return ProviderOutcome or a mapping")
    state = str(value.get("state") or "failed")
    return ProviderOutcome(
        success=bool(value.get("success", state == "succeeded")),
        final_text=str(value.get("final_text") or ""),
        task_id=str(value.get("task_id") or value.get("id") or "unknown"),
        input_tokens=max(0, int(value.get("input_tokens") or 0)),
        cached_input_tokens=max(0, int(value.get("cached_input_tokens") or 0)),
        output_tokens=max(0, int(value.get("output_tokens") or 0)),
        state=state,
    )


def _outcome_payload(outcome: ProviderOutcome) -> dict[str, Any]:
    return {
        "schema": PROVIDER_SCHEMA,
        "success": outcome.success,
        "state": outcome.state,
        "task_id": outcome.task_id,
        "final_text": outcome.final_text,
        "input_tokens": outcome.input_tokens,
        "cached_input_tokens": outcome.cached_input_tokens,
        "output_tokens": outcome.output_tokens,
    }


class OperatorCliProvider:
    """Crash-resumable provider adapter backed by durable Operator task IDs."""

    def __init__(
        self,
        workspace: Path,
        state_dir: Path,
        effort: str,
        timeout_seconds: int,
    ) -> None:
        self.workspace = Path(workspace).resolve()
        self.state_dir = Path(state_dir).resolve() / "provider"
        self.effort = str(effort)
        self.timeout_seconds = int(timeout_seconds)

    @staticmethod
    def _task_id(path: Path) -> str:
        try:
            raw = path.read_text(encoding="utf-8")
            payload = json.loads(raw)
            value = payload.get("task_id")
            if isinstance(value, str) and value:
                return value
        except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
            try:
                raw = path.read_text(encoding="utf-8", errors="ignore")
            except OSError as exc:
                raise BenchmarkAdaptiveError("cannot recover provider task ID") from exc
        match = _TASK_ID.search(raw)
        if match:
            return match.group(1)
        raise BenchmarkAdaptiveError(
            "provider submission outcome is ambiguous; refusing to duplicate a stage"
        )

    @staticmethod
    def _run_to_new_file(
        argv: Sequence[str],
        path: Path,
        *,
        stdin: Optional[bytes] = None,
        timeout: Optional[float] = None,
    ) -> int:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            descriptor = os.open(
                str(path),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
        except FileExistsError as exc:
            raise BenchmarkAdaptiveError("provider output already exists: %s" % path) from exc
        try:
            with os.fdopen(descriptor, "wb") as output:
                completed = subprocess.run(
                    list(argv),
                    input=stdin,
                    stdout=output,
                    stderr=subprocess.PIPE,
                    cwd=None,
                    check=False,
                    timeout=timeout,
                )
                output.flush()
                os.fsync(output.fileno())
        except BaseException:
            # Preserve the direct output.  It can contain the only durable task
            # ID for a provider invocation that continued after this process.
            raise
        return int(completed.returncode)

    def __call__(self, request: ProviderRequest) -> ProviderOutcome:
        root = self.state_dir / ("round-%03d" % request.round_index) / request.stage
        root.mkdir(parents=True, exist_ok=True)
        request_payload = {
            "schema": PROVIDER_SCHEMA,
            "round_index": request.round_index,
            "stage": request.stage,
            "sandbox": request.sandbox,
            "model": "gpt-5.6-sol",
            "profile": "sol",
            "effort": self.effort,
            "prompt_sha256": _sha256_bytes(request.prompt.encode("utf-8")),
        }
        _write_once(root / "request.json", request_payload)

        submission_path = root / "submission.json"
        if not submission_path.exists():
            argv = [
                sys.executable,
                "-m",
                "blacklabel_operator",
                "submit",
                "--profile",
                "sol",
                "--provider",
                "codex",
                "--model",
                "gpt-5.6-sol",
                "--effort",
                self.effort,
                "--sandbox",
                request.sandbox,
                "--isolation",
                "shared",
                "--max-attempts",
                "1",
                "--cwd",
                str(self.workspace),
                "--json",
            ]
            return_code = self._run_to_new_file(
                argv,
                submission_path,
                stdin=request.prompt.encode("utf-8"),
                timeout=60,
            )
            if return_code != 0:
                raise BenchmarkAdaptiveError(
                    "provider submission failed for %s" % request.stage
                )
        task_id = self._task_id(submission_path)

        result_path = root / "result.json"
        if not result_path.exists():
            attempt = root / "wait.partial.json"
            try:
                attempt.unlink()
            except FileNotFoundError:
                pass
            argv = [
                sys.executable,
                "-m",
                "blacklabel_operator",
                "wait",
                task_id,
                "--timeout",
                str(self.timeout_seconds),
                "--json",
            ]
            return_code = self._run_to_new_file(
                argv,
                attempt,
                timeout=self.timeout_seconds + 30,
            )
            try:
                result_payload = _read_json(attempt)
            except BenchmarkAdaptiveError:
                # The task ID remains durable.  A later process can issue wait
                # for that exact task; it must never submit the stage again.
                raise
            if str(result_payload.get("id") or "") != task_id:
                raise BenchmarkAdaptiveError("provider task identity mismatch")
            os.replace(str(attempt), str(result_path))
            result_path.chmod(0o400)
            if return_code not in (0, 1):
                raise BenchmarkAdaptiveError("provider wait failed")
        payload = _read_json(result_path)
        if not isinstance(payload, Mapping) or str(payload.get("id") or "") != task_id:
            raise BenchmarkAdaptiveError("provider result identity mismatch")
        state = str(payload.get("state") or "failed")
        return ProviderOutcome(
            success=state == "succeeded",
            state=state,
            final_text=str(payload.get("final_text") or ""),
            task_id=task_id,
            input_tokens=max(0, int(payload.get("input_tokens") or 0)),
            cached_input_tokens=max(0, int(payload.get("cached_input_tokens") or 0)),
            output_tokens=max(0, int(payload.get("output_tokens") or 0)),
        )


def _default_command_runner(request: CommandRequest) -> CommandOutcome:
    try:
        completed = subprocess.run(
            ["bash", "-lc", request.command],
            cwd=str(request.cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=request.timeout_seconds,
        )
        return CommandOutcome(
            exit_code=int(completed.returncode),
            output=bytes(completed.stdout or b""),
            timed_out=False,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.output or b""
        if isinstance(output, str):
            output = output.encode("utf-8", "surrogateescape")
        return CommandOutcome(exit_code=124, output=bytes(output), timed_out=True)


def _strict_json_object(text: str, stage: str) -> dict[str, Any]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise BenchmarkAdaptiveError("%s returned invalid JSON" % stage) from exc
    if not isinstance(value, dict):
        raise BenchmarkAdaptiveError("%s must return a JSON object" % stage)
    return value


def _nonempty_string(value: Any, field: str, maximum: int = 32_000) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BenchmarkAdaptiveError("%s must be a non-empty string" % field)
    if len(value.encode("utf-8")) > maximum:
        raise BenchmarkAdaptiveError("%s exceeds its byte limit" % field)
    return value.strip()


def _string_list(value: Any, field: str, *, required: bool = False) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise BenchmarkAdaptiveError("%s must be a list of strings" % field)
    result = [_nonempty_string(item, "%s item" % field, 8_000) for item in value]
    if required and not result:
        raise BenchmarkAdaptiveError("%s must not be empty" % field)
    return result


def _normalize_plan(payload: Mapping[str, Any]) -> dict[str, Any]:
    required_keys = {
        "steps",
        "rationale",
        "hypotheses",
        "predicted_checks",
        "verifier_commands",
        "playbook",
    }
    if set(payload) != required_keys:
        raise BenchmarkAdaptiveError(
            "planner keys must be exactly: %s" % ", ".join(sorted(required_keys))
        )
    steps = _string_list(payload["steps"], "steps", required=True)
    rationale = _nonempty_string(payload["rationale"], "rationale")
    playbook = _string_list(payload["playbook"], "playbook", required=True)

    raw_commands = payload["verifier_commands"]
    if not isinstance(raw_commands, list) or not raw_commands:
        raise BenchmarkAdaptiveError("verifier_commands must be a non-empty list")
    if len(raw_commands) > MAX_COMMANDS:
        raise BenchmarkAdaptiveError("too many verifier commands")
    commands = []
    for index, raw in enumerate(raw_commands, start=1):
        if not isinstance(raw, dict) or set(raw) != {"command", "timeout_seconds"}:
            raise BenchmarkAdaptiveError("verifier command %d has invalid keys" % index)
        command = _nonempty_string(raw["command"], "verifier command", MAX_COMMAND_BYTES)
        timeout = raw["timeout_seconds"]
        if type(timeout) is not int or not 1 <= timeout <= MAX_VERIFIER_TIMEOUT_SECONDS:
            raise BenchmarkAdaptiveError("verifier timeout is outside its allowed range")
        command_spec = {"command": command, "timeout_seconds": timeout}
        command_spec["command_sha256"] = _sha256_json(command_spec)
        commands.append(command_spec)
    if len({item["command_sha256"] for item in commands}) != len(commands):
        raise BenchmarkAdaptiveError("verifier commands must be unique")

    raw_predictions = payload["predicted_checks"]
    if not isinstance(raw_predictions, list) or len(raw_predictions) != len(commands):
        raise BenchmarkAdaptiveError(
            "predicted_checks must correspond one-for-one with verifier_commands"
        )
    predictions = []
    for index, (raw, command) in enumerate(zip(raw_predictions, commands), start=1):
        if not isinstance(raw, dict) or set(raw) != {"command", "expected", "purpose"}:
            raise BenchmarkAdaptiveError("predicted check %d has invalid keys" % index)
        predicted_command = _nonempty_string(raw["command"], "predicted command", MAX_COMMAND_BYTES)
        if predicted_command != command["command"]:
            raise BenchmarkAdaptiveError("predicted check command does not match verifier command")
        predictions.append(
            {
                "command": predicted_command,
                "command_sha256": command["command_sha256"],
                "expected": _nonempty_string(raw["expected"], "predicted expected"),
                "purpose": _nonempty_string(raw["purpose"], "predicted purpose"),
            }
        )

    raw_hypotheses = payload["hypotheses"]
    if not isinstance(raw_hypotheses, list) or not raw_hypotheses:
        raise BenchmarkAdaptiveError("hypotheses must be a non-empty list")
    hypotheses = []
    seen = set()
    for index, raw in enumerate(raw_hypotheses, start=1):
        keys = {"id", "claim", "status", "support", "contradictions", "prediction"}
        if not isinstance(raw, dict) or set(raw) != keys:
            raise BenchmarkAdaptiveError("hypothesis %d has invalid keys" % index)
        hypothesis_id = _nonempty_string(raw["id"], "hypothesis id", 200)
        if hypothesis_id in seen:
            raise BenchmarkAdaptiveError("hypothesis IDs must be unique")
        seen.add(hypothesis_id)
        status = str(raw["status"] or "").lower()
        if status not in ("open", "supported", "refuted"):
            raise BenchmarkAdaptiveError("hypothesis status is invalid")
        support = _string_list(raw["support"], "hypothesis support")
        contradictions = _string_list(
            raw["contradictions"], "hypothesis contradictions"
        )
        if status == "supported" and not support:
            raise BenchmarkAdaptiveError("supported hypotheses require supporting evidence")
        if status == "refuted" and not contradictions:
            raise BenchmarkAdaptiveError("refuted hypotheses require contradictory evidence")
        hypotheses.append(
            {
                "id": hypothesis_id,
                "claim": _nonempty_string(raw["claim"], "hypothesis claim"),
                "status": status,
                "support": support,
                "contradictions": contradictions,
                "prediction": _nonempty_string(raw["prediction"], "hypothesis prediction"),
            }
        )
    return {
        "steps": steps,
        "rationale": rationale,
        "hypotheses": hypotheses,
        "predicted_checks": predictions,
        "verifier_commands": commands,
        "playbook": playbook,
    }


def _usage_payload(usage: Usage) -> dict[str, int]:
    return {"tokens": usage.tokens, "cost_micros": usage.cost_micros}


def _usage_from_payload(payload: Mapping[str, Any]) -> Usage:
    return Usage(
        tokens=max(0, int(payload.get("tokens") or 0)),
        cost_micros=max(0, int(payload.get("cost_micros") or 0)),
    )


class BenchmarkAdaptiveRunner:
    """Durable callback adapter around the pure adaptive execution engine."""

    def __init__(
        self,
        *,
        instruction: str,
        workspace: Path,
        state_dir: Path,
        effort: str = "high",
        benchmark_suite: str = "",
        max_rounds: int = 3,
        timeout_seconds: int = 7_200,
        read_only_sandbox: str = "read-only",
        provider: Optional[Callable[[ProviderRequest], Any]] = None,
        command_runner: Optional[Callable[[CommandRequest], CommandOutcome]] = None,
    ) -> None:
        if not isinstance(instruction, str) or not instruction:
            raise BenchmarkAdaptiveError("benchmark instruction must be non-empty")
        instruction_bytes = instruction.encode("utf-8")
        workspace = Path(workspace).resolve()
        state_dir = Path(state_dir).resolve()
        if not workspace.is_dir():
            raise BenchmarkAdaptiveError("benchmark workspace does not exist")
        try:
            state_dir.relative_to(workspace)
        except ValueError:
            pass
        else:
            raise BenchmarkAdaptiveError("benchmark state must be outside the graded workspace")
        self.instruction = instruction
        self.instruction_bytes = instruction_bytes
        self.instruction_sha256 = _sha256_bytes(instruction_bytes)
        self.workspace = workspace
        self.state_dir = state_dir
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.effort = str(effort)
        self.benchmark_suite = str(benchmark_suite or "")
        self.max_rounds = int(max_rounds)
        self.timeout_seconds = int(timeout_seconds)
        self.read_only_sandbox = str(read_only_sandbox)
        if self.read_only_sandbox not in ("read-only", "danger-full-access"):
            raise BenchmarkAdaptiveError("read-only stage sandbox is invalid")
        self.journal = HashChainJournal(self.state_dir / "episode.jsonl")
        self.provider = provider or OperatorCliProvider(
            workspace, state_dir, effort, timeout_seconds
        )
        self.command_runner = command_runner or _default_command_runner
        self._provider_outcomes: list[ProviderOutcome] = []
        self.journal.record_once(
            "instruction",
            "instruction.bound",
            {
                "instruction": instruction,
                "instruction_base64": base64.b64encode(instruction_bytes).decode("ascii"),
                "instruction_bytes": len(instruction_bytes),
                "instruction_sha256": self.instruction_sha256,
                "benchmark_suite": self.benchmark_suite,
                "read_only_sandbox": self.read_only_sandbox,
            },
        )

    def _normalized_path(self, round_index: int, stage: str) -> Path:
        return (
            self.state_dir
            / "normalized"
            / ("round-%03d-%s.json" % (round_index, stage))
        )

    def _load_normalized(self, round_index: int, stage: str) -> Optional[dict[str, Any]]:
        path = self._normalized_path(round_index, stage)
        if not path.exists():
            return None
        payload = _read_json(path)
        if not isinstance(payload, dict):
            raise BenchmarkAdaptiveError("normalized stage artifact is invalid")
        if payload.get("instruction_sha256") != self.instruction_sha256:
            raise BenchmarkAdaptiveError("normalized stage instruction identity mismatch")
        artifact_sha = _sha256_bytes(path.read_bytes())
        self.journal.record_once(
            "round-%03d/%s" % (round_index, stage),
            "stage.completed",
            {
                "round_index": round_index,
                "stage": stage,
                "artifact_sha256": artifact_sha,
                "value_sha256": _sha256_json(payload.get("value")),
            },
        )
        return payload

    def _save_normalized(
        self, round_index: int, stage: str, value: Mapping[str, Any]
    ) -> dict[str, Any]:
        payload = {
            "schema": EPISODE_SCHEMA,
            "round_index": round_index,
            "stage": stage,
            "instruction_sha256": self.instruction_sha256,
            "value": _plain(value),
        }
        artifact_sha = _write_once(self._normalized_path(round_index, stage), payload)
        self.journal.record_once(
            "round-%03d/%s" % (round_index, stage),
            "stage.completed",
            {
                "round_index": round_index,
                "stage": stage,
                "artifact_sha256": artifact_sha,
                "value_sha256": _sha256_json(value),
            },
        )
        return payload

    def _provider(self, request: ProviderRequest) -> ProviderOutcome:
        if len(request.prompt.encode("utf-8")) > MAX_PROVIDER_PROMPT_BYTES:
            raise BenchmarkAdaptiveError("provider prompt exceeds its byte limit")
        outcome = _provider_outcome(self.provider(request))
        self._provider_outcomes.append(outcome)
        return outcome

    def _read_only_provider(self, request: ProviderRequest) -> ProviderOutcome:
        before = self._workspace_identity()
        try:
            outcome = self._provider(request)
        except BaseException as exc:
            if self._workspace_identity() != before:
                raise BenchmarkAdaptiveError(
                    "%s modified the graded workspace" % request.stage
                ) from exc
            raise
        if self._workspace_identity() != before:
            raise BenchmarkAdaptiveError(
                "%s modified the graded workspace" % request.stage
            )
        return outcome

    def _objective_block(self) -> str:
        return (
            "The exact official instruction is between the byte-counted delimiters. "
            "Do not rewrite or broaden it.\n"
            "INSTRUCTION_SHA256=%s\nINSTRUCTION_UTF8_BYTES=%d\n"
            "<OFFICIAL_INSTRUCTION>\n%s\n</OFFICIAL_INSTRUCTION>"
            % (self.instruction_sha256, len(self.instruction_bytes), self.instruction)
        )

    def _planner_prompt(self, request: Any) -> str:
        feedback = _plain(request.feedback)
        prior_knowledge = []
        for round_index in range(1, request.round_index):
            path = self.state_dir / "knowledge" / ("round-%03d.json" % round_index)
            if path.is_file():
                prior_knowledge.append(_read_json(path))
        return """You are the read-only planning stage for a custom coding benchmark trial.
Inspect the current workspace and formulate the smallest evidence-driven plan. Do not
edit files or run commands that mutate the workspace. Return only one JSON object,
with exactly these keys and shapes:
{
  "steps": ["..."],
  "rationale": "...",
  "hypotheses": [{"id":"H1","claim":"...","status":"open|supported|refuted","support":[],"contradictions":[],"prediction":"..."}],
  "predicted_checks": [{"command":"...","expected":"...","purpose":"..."}],
  "verifier_commands": [{"command":"...","timeout_seconds":300}],
  "playbook": ["reusable evidence-grounded rule"]
}
Every predicted_checks command must exactly equal the corresponding verifier_commands
command. Declare public/local checks only; hidden benchmark graders run exactly once
after this agent exits. A check that only compares the deliverable to constants chosen
by this same plan proves formatting, not correctness. For derived numeric, scientific,
financial, or data-analysis outputs, plan source reconstruction, dimensional and sign
sanity checks, boundary checks, and an independently implemented second calculation.
Treat ambiguous, encrypted, damaged, or manually decoded source artifacts as unproven
until two independent extraction paths agree. Round: %d. Prior feedback: %s
Prior durable playbook and hypotheses: %s

%s""" % (
            request.round_index,
            json.dumps(feedback, sort_keys=True, separators=(",", ":")),
            json.dumps(prior_knowledge, sort_keys=True, separators=(",", ":")),
            self._objective_block(),
        )

    def _planner(self, request: Any) -> PlanResult:
        cached = self._load_normalized(request.round_index, "planner")
        if cached is not None:
            value = cached["value"]
            return PlanResult(
                steps=tuple(value["steps"]),
                rationale=value["rationale"],
                metadata=value["metadata"],
                usage=_usage_from_payload(value["usage"]),
            )
        outcome = self._read_only_provider(
            ProviderRequest(
                round_index=request.round_index,
                stage="planner",
                prompt=self._planner_prompt(request),
                sandbox=self.read_only_sandbox,
            )
        )
        if not outcome.success:
            raise BenchmarkAdaptiveError("planner provider task did not succeed")
        normalized = _normalize_plan(_strict_json_object(outcome.final_text, "planner"))
        knowledge = {
            "schema": EPISODE_SCHEMA,
            "round_index": request.round_index,
            "instruction_sha256": self.instruction_sha256,
            "playbook": normalized["playbook"],
            "hypotheses": normalized["hypotheses"],
            "predicted_checks": normalized["predicted_checks"],
            "verifier_commands": normalized["verifier_commands"],
        }
        knowledge_sha = _write_once(
            self.state_dir / "knowledge" / ("round-%03d.json" % request.round_index),
            knowledge,
        )
        metadata = {
            "knowledge_sha256": knowledge_sha,
            "playbook": normalized["playbook"],
            "hypotheses": normalized["hypotheses"],
            "predicted_checks": normalized["predicted_checks"],
            "verifier_commands": normalized["verifier_commands"],
            "provider_task_id": outcome.task_id,
        }
        value = {
            "steps": normalized["steps"],
            "rationale": normalized["rationale"],
            "metadata": metadata,
            "usage": _usage_payload(outcome.usage),
            "provider_tokens": {
                "input_tokens": outcome.input_tokens,
                "cached_input_tokens": outcome.cached_input_tokens,
                "output_tokens": outcome.output_tokens,
            },
        }
        self._save_normalized(request.round_index, "planner", value)
        return PlanResult(
            steps=tuple(value["steps"]),
            rationale=value["rationale"],
            metadata=metadata,
            usage=outcome.usage,
        )

    def _executor_prompt(self, request: Any) -> str:
        plan = {
            "steps": list(request.plan.steps),
            "rationale": request.plan.rationale,
            "hypotheses": _plain(request.plan.metadata["hypotheses"]),
            "predicted_checks": _plain(request.plan.metadata["predicted_checks"]),
            "playbook": _plain(request.plan.metadata["playbook"]),
        }
        return """You are the sole writable Sol stage for this custom benchmark trial.
Implement the exact official instruction in the current workspace. Use the evidence-
grounded plan below, inspect the real surrounding contracts, and finish the production
change. Do not access hidden grader material and do not rewrite the task. Public/local
verification is run separately after you exit.

PLAN=%s

%s""" % (
            json.dumps(plan, sort_keys=True, separators=(",", ":")),
            self._objective_block(),
        )

    def _workspace_identity(self) -> str:
        completed = subprocess.run(
            ["git", "diff", "--binary", "--no-ext-diff", "HEAD", "--", "."],
            cwd=str(self.workspace),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        payload = bytearray()
        if completed.returncode == 0:
            payload.extend(completed.stdout)
            untracked = subprocess.run(
                ["git", "ls-files", "--others", "--exclude-standard", "-z"],
                cwd=str(self.workspace),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if untracked.returncode == 0:
                for raw in sorted(item for item in untracked.stdout.split(b"\0") if item):
                    relative = os.fsdecode(raw)
                    candidate = self.workspace / relative
                    if candidate.is_file() and not candidate.is_symlink():
                        payload.extend(b"\0path\0" + raw + b"\0")
                        try:
                            with candidate.open("rb") as handle:
                                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                                    payload.extend(chunk)
                        except OSError:
                            payload.extend(b"<unreadable>")
            return _sha256_bytes(bytes(payload))
        # Non-Git benchmark workspaces are uncommon but valid.  Bind a bounded
        # deterministic walk without following symlinks.
        for candidate in sorted(self.workspace.rglob("*")):
            relative = candidate.relative_to(self.workspace).as_posix()
            if ".git" in candidate.relative_to(self.workspace).parts:
                continue
            payload.extend(relative.encode("utf-8", "surrogateescape") + b"\0")
            if candidate.is_file() and not candidate.is_symlink():
                try:
                    with candidate.open("rb") as handle:
                        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                            payload.extend(chunk)
                            if len(payload) > 64 * 1024 * 1024:
                                return _sha256_bytes(bytes(payload) + b"<bounded>")
                except OSError:
                    payload.extend(b"<unreadable>")
        return _sha256_bytes(bytes(payload))

    def _executor(self, request: Any) -> ExecutionResult:
        cached = self._load_normalized(request.round_index, "executor")
        if cached is not None:
            value = cached["value"]
            return ExecutionResult(
                completed=bool(value["completed"]),
                summary=value["summary"],
                output=value["output"],
                artifacts=tuple(
                    Artifact(
                        name=item["name"],
                        sha256=item["sha256"],
                        media_type=item["media_type"],
                        metadata=item.get("metadata") or {},
                    )
                    for item in value["artifacts"]
                ),
                usage=_usage_from_payload(value["usage"]),
            )
        outcome = self._provider(
            ProviderRequest(
                round_index=request.round_index,
                stage="executor",
                prompt=self._executor_prompt(request),
                sandbox="danger-full-access",
            )
        )
        workspace_sha = self._workspace_identity()
        artifact = Artifact(
            name="workspace-round-%03d" % request.round_index,
            sha256=workspace_sha,
            media_type="application/vnd.blacklabel.workspace-identity",
            metadata={"instruction_sha256": self.instruction_sha256},
        )
        summary = outcome.final_text.strip() or (
            "executor task %s ended in state %s" % (outcome.task_id, outcome.state)
        )
        value = {
            "completed": outcome.success,
            "summary": summary,
            "output": {
                "provider_task_id": outcome.task_id,
                "provider_state": outcome.state,
                "final_text_sha256": _sha256_bytes(outcome.final_text.encode("utf-8")),
                "workspace_sha256": workspace_sha,
            },
            "artifacts": [
                {
                    "name": artifact.name,
                    "sha256": artifact.sha256,
                    "media_type": artifact.media_type,
                    "metadata": dict(artifact.metadata),
                }
            ],
            "usage": _usage_payload(outcome.usage),
            "provider_tokens": {
                "input_tokens": outcome.input_tokens,
                "cached_input_tokens": outcome.cached_input_tokens,
                "output_tokens": outcome.output_tokens,
            },
        }
        # This immutable completion artifact is written before any later stage.
        # Replaying the pure engine therefore returns this exact result and can
        # never enqueue a completed writable provider task again.
        self._save_normalized(request.round_index, "executor", value)
        return ExecutionResult(
            completed=outcome.success,
            summary=summary,
            output=value["output"],
            artifacts=(artifact,),
            usage=outcome.usage,
        )

    @staticmethod
    def _command_outcome(value: Any) -> CommandOutcome:
        if isinstance(value, CommandOutcome):
            return value
        if not isinstance(value, Mapping):
            raise BenchmarkAdaptiveError("command runner returned an invalid value")
        output = value.get("output") or b""
        if isinstance(output, str):
            output = output.encode("utf-8", "surrogateescape")
        return CommandOutcome(
            exit_code=int(value.get("exit_code") or 0),
            output=bytes(output),
            timed_out=bool(value.get("timed_out", False)),
        )

    def _command_receipt(
        self, round_index: int, command_index: int, spec: Mapping[str, Any]
    ) -> dict[str, Any]:
        path = (
            self.state_dir
            / "commands"
            / ("round-%03d-command-%03d.json" % (round_index, command_index))
        )
        if path.exists():
            payload = _read_json(path)
            if (
                payload.get("schema") != COMMAND_SCHEMA
                or payload.get("instruction_sha256") != self.instruction_sha256
            ):
                raise BenchmarkAdaptiveError("verifier command receipt identity changed")
            if payload.get("command_sha256") != spec["command_sha256"]:
                raise BenchmarkAdaptiveError("verifier command identity changed on resume")
            payload = dict(payload)
            payload["artifact_sha256"] = _sha256_bytes(path.read_bytes())
            return payload
        outcome = self._command_outcome(
            self.command_runner(
                CommandRequest(
                    round_index=round_index,
                    command_index=command_index,
                    command=spec["command"],
                    timeout_seconds=spec["timeout_seconds"],
                    cwd=self.workspace,
                )
            )
        )
        full_output_sha = _sha256_bytes(outcome.output)
        bounded = outcome.output[:MAX_COMMAND_OUTPUT_BYTES]
        receipt = {
            "schema": COMMAND_SCHEMA,
            "round_index": round_index,
            "command_index": command_index,
            "instruction_sha256": self.instruction_sha256,
            "command": spec["command"],
            "command_sha256": spec["command_sha256"],
            "timeout_seconds": spec["timeout_seconds"],
            "exit_code": outcome.exit_code,
            "timed_out": outcome.timed_out,
            "passed": outcome.exit_code == 0 and not outcome.timed_out,
            "output_bytes": len(outcome.output),
            "output_sha256": full_output_sha,
            "output_truncated": len(outcome.output) > len(bounded),
            "output_base64": base64.b64encode(bounded).decode("ascii"),
        }
        artifact_sha = _write_once(path, receipt)
        receipt["artifact_sha256"] = artifact_sha
        self.journal.record_once(
            "round-%03d/command-%03d" % (round_index, command_index),
            "verification.command",
            {
                "round_index": round_index,
                "command_index": command_index,
                "command_sha256": spec["command_sha256"],
                "receipt_sha256": artifact_sha,
                "passed": receipt["passed"],
            },
        )
        return receipt

    def _verifier(self, request: Any) -> VerificationResult:
        cached = self._load_normalized(request.round_index, "verifier")
        if cached is not None:
            value = cached["value"]
            return VerificationResult(
                passed=bool(value["passed"]),
                summary=value["summary"],
                evidence=tuple(
                    Evidence(
                        evidence_id=item["evidence_id"],
                        kind=item["kind"],
                        passed=bool(item["passed"]),
                        summary=item["summary"],
                        source=item["source"],
                        required=bool(item["required"]),
                        artifact_sha256=item.get("artifact_sha256"),
                        metadata=item.get("metadata") or {},
                    )
                    for item in value["evidence"]
                ),
                usage=_usage_from_payload(value["usage"]),
            )
        commands = list(request.plan.metadata["verifier_commands"])
        predictions = list(request.plan.metadata["predicted_checks"])
        evidence = []
        serialized = []
        for index, (spec, prediction) in enumerate(zip(commands, predictions), start=1):
            receipt = self._command_receipt(request.round_index, index, spec)
            evidence_id = "round-%03d-command-%03d" % (request.round_index, index)
            passed = bool(receipt["passed"])
            item = Evidence(
                evidence_id=evidence_id,
                kind="planner-declared-command",
                passed=passed,
                summary=(
                    "command passed: %s" if passed else "command failed: %s"
                )
                % prediction["purpose"],
                source="planner-declared:%s" % spec["command_sha256"],
                required=True,
                artifact_sha256=receipt["artifact_sha256"],
                metadata={
                    "command_sha256": spec["command_sha256"],
                    "expected": prediction["expected"],
                    "exit_code": receipt["exit_code"],
                    "output_sha256": receipt["output_sha256"],
                    "timed_out": receipt["timed_out"],
                },
            )
            evidence.append(item)
            serialized.append(
                {
                    "evidence_id": item.evidence_id,
                    "kind": item.kind,
                    "passed": item.passed,
                    "summary": item.summary,
                    "source": item.source,
                    "required": item.required,
                    "artifact_sha256": item.artifact_sha256,
                    "metadata": _plain(item.metadata),
                }
            )
        passed = request.execution.completed and all(item.passed for item in evidence)
        summary = "%d/%d planner-declared checks passed" % (
            sum(1 for item in evidence if item.passed),
            len(evidence),
        )
        value = {
            "passed": passed,
            "summary": summary,
            "evidence": serialized,
            "usage": _usage_payload(Usage()),
        }
        self._save_normalized(request.round_index, "verifier", value)
        return VerificationResult(
            passed=passed,
            summary=summary,
            evidence=tuple(evidence),
            usage=Usage(),
        )

    def _critic_prompt(self, request: Any) -> str:
        evidence = [
            {
                "evidence_id": item.evidence_id,
                "passed": item.passed,
                "required": item.required,
                "summary": item.summary,
                "source": item.source,
                "artifact_sha256": item.artifact_sha256,
                "metadata": _plain(item.metadata),
            }
            for item in request.verification.evidence
        ]
        return """Act as an independent, read-only correctness critic. Inspect the current
workspace and the exact official instruction yourself. Do not edit files. Do not trust
the executor's claims or infer correctness merely from a zero exit status. Challenge
the plan, implementation, edge cases, and whether the declared checks actually prove
the contract. This independent review is mandatory even when every check passed.

Audit at least these independent dimensions:
1. output-contract: required paths, schema, formatting, and completeness;
2. source-or-test: reconstruct facts from the original inputs or run authoritative
   public tests rather than trusting executor-selected constants;
3. semantic-invariants: units, signs, ranges, conservation/ordering rules, boundary
   cases, and domain plausibility. Quantities named amount, concentration, count,
   duration, efficiency, factor, limit, mass, probability, quantity, rate, time,
   volume, or weight cannot be negative or non-finite unless the instruction or an
   original source explicitly permits it;
4. cross-check: for every derived numeric/scientific/financial result, recompute by a
   genuinely independent method with full precision. Reusing the same extracted value,
   formula, script, or hard-coded expected constant is not independent.
If an input is ambiguous, encrypted, damaged, manually decoded, or lacks a trusted
parser, require two independent extraction paths to agree. If any applicable dimension
is unproven, recommend replan. Do not call a self-consistent derivation correct merely
because the same interpretation reproduces its own output.

Return only one JSON object with exactly these keys:
{"recommendation":"accept|replan|stop","summary":"...","issues":["..."],"evidence_refs":["round-..."],"acceptance_checks":[{"kind":"output-contract|semantic-invariants|source-or-test|cross-check","description":"...","method":"...","outcome":"pass|fail|unproven"}]}
For replan or stop, evidence_refs must contain at least one ID from EVIDENCE. For
accept, cite every passing required receipt that supports acceptance, report no issues,
and include passing source-or-test and semantic-invariants checks. When the instruction
contains derived numeric or measured quantities, also include a passing cross-check.

ROUND=%d
PLAN=%s
EVIDENCE=%s

%s""" % (
            request.round_index,
            json.dumps(
                {
                    "steps": list(request.plan.steps),
                    "rationale": request.plan.rationale,
                    "hypotheses": _plain(request.plan.metadata["hypotheses"]),
                    "predicted_checks": _plain(request.plan.metadata["predicted_checks"]),
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            json.dumps(evidence, sort_keys=True, separators=(",", ":")),
            self._objective_block(),
        )

    def _critic(self, request: Any) -> CritiqueResult:
        cached = self._load_normalized(request.round_index, "critic")
        if cached is not None:
            value = cached["value"]
            return CritiqueResult(
                recommendation=value["recommendation"],
                summary=value["summary"],
                issues=tuple(value["issues"]),
                evidence_refs=tuple(value["evidence_refs"]),
                usage=_usage_from_payload(value["usage"]),
            )
        outcome = self._read_only_provider(
            ProviderRequest(
                round_index=request.round_index,
                stage="critic",
                prompt=self._critic_prompt(request),
                sandbox=self.read_only_sandbox,
            )
        )
        if not outcome.success:
            raise BenchmarkAdaptiveError("critic provider task did not succeed")
        raw = _strict_json_object(outcome.final_text, "critic")
        required = {
            "recommendation",
            "summary",
            "issues",
            "evidence_refs",
            "acceptance_checks",
        }
        if set(raw) != required:
            raise BenchmarkAdaptiveError("critic keys are invalid")
        recommendation = str(raw["recommendation"] or "").lower()
        if recommendation not in ("accept", "replan", "stop"):
            raise BenchmarkAdaptiveError("critic recommendation is invalid")
        issues = _string_list(raw["issues"], "critic issues")
        references = _string_list(raw["evidence_refs"], "critic evidence refs")
        raw_checks = raw["acceptance_checks"]
        if not isinstance(raw_checks, list):
            raise BenchmarkAdaptiveError("critic acceptance checks are invalid")
        acceptance_checks = []
        for index, item in enumerate(raw_checks, start=1):
            if not isinstance(item, Mapping) or set(item) != {
                "kind",
                "description",
                "method",
                "outcome",
            }:
                raise BenchmarkAdaptiveError(
                    "critic acceptance check %d is invalid" % index
                )
            kind = str(item["kind"] or "").strip().lower()
            outcome_value = str(item["outcome"] or "").strip().lower()
            if kind not in _CRITIC_CHECK_KINDS or outcome_value not in {
                "pass",
                "fail",
                "unproven",
            }:
                raise BenchmarkAdaptiveError(
                    "critic acceptance check %d is invalid" % index
                )
            acceptance_checks.append(
                {
                    "kind": kind,
                    "description": _nonempty_string(
                        item["description"],
                        "critic acceptance check description",
                    ),
                    "method": _nonempty_string(
                        item["method"],
                        "critic acceptance check method",
                    ),
                    "outcome": outcome_value,
                }
            )
        known = {item.evidence_id for item in request.verification.evidence}
        if any(reference not in known for reference in references):
            raise BenchmarkAdaptiveError("critic cited unknown evidence")
        if recommendation in ("replan", "stop") and not references:
            raise BenchmarkAdaptiveError("critic did not ground its rejection in evidence")
        if recommendation == "accept":
            passing_required = {
                item.evidence_id
                for item in request.verification.evidence
                if item.required and item.passed
            }
            if not passing_required or set(references) != passing_required:
                raise BenchmarkAdaptiveError(
                    "critic acceptance must cite all passing required evidence"
                )
            if issues:
                raise BenchmarkAdaptiveError("critic acceptance cannot report issues")
            passed_kinds = {
                item["kind"]
                for item in acceptance_checks
                if item["outcome"] == "pass"
            }
            if any(item["outcome"] != "pass" for item in acceptance_checks):
                raise BenchmarkAdaptiveError(
                    "critic acceptance checks must all pass"
                )
            required_kinds = {"source-or-test", "semantic-invariants"}
            if _NUMERIC_SEMANTIC_HINT.search(self.instruction):
                required_kinds.add("cross-check")
            if not required_kinds.issubset(passed_kinds):
                raise BenchmarkAdaptiveError(
                    "critic acceptance lacks independent semantic proof"
                )
        value = {
            "recommendation": recommendation,
            "summary": _nonempty_string(raw["summary"], "critic summary"),
            "issues": issues,
            "evidence_refs": references,
            "acceptance_checks": acceptance_checks,
            "usage": _usage_payload(outcome.usage),
            "provider_task_id": outcome.task_id,
            "provider_tokens": {
                "input_tokens": outcome.input_tokens,
                "cached_input_tokens": outcome.cached_input_tokens,
                "output_tokens": outcome.output_tokens,
            },
        }
        self._save_normalized(request.round_index, "critic", value)
        return CritiqueResult(
            recommendation=recommendation,
            summary=value["summary"],
            issues=tuple(issues),
            evidence_refs=tuple(references),
            usage=outcome.usage,
        )

    def _arbiter(self, request: Any) -> ArbitrationResult:
        cached = self._load_normalized(request.round_index, "arbiter")
        if cached is not None:
            value = cached["value"]
            return ArbitrationResult(
                decision=value["decision"],
                rationale=value["rationale"],
                evidence_refs=tuple(value["evidence_refs"]),
                usage=_usage_from_payload(value["usage"]),
            )
        references = [item.evidence_id for item in request.verification.evidence]
        verified = (
            request.execution.completed
            and request.verification.passed
            and all(item.passed for item in request.verification.evidence if item.required)
        )
        if verified and request.critique.recommendation == "accept":
            decision = "accept"
            rationale = "all required command receipts passed and the independent critic accepted"
            references = [
                item.evidence_id
                for item in request.verification.evidence
                if item.required and item.passed
            ]
        elif request.critique.recommendation == "stop":
            decision = "stop"
            rationale = "the independent critic requested an evidence-backed stop"
        elif request.round_index < self.max_rounds:
            decision = "replan"
            rationale = "acceptance evidence is incomplete; execute another bounded round"
        else:
            decision = "stop"
            rationale = "acceptance evidence is incomplete and the round budget is exhausted"
        value = {
            "decision": decision,
            "rationale": rationale,
            "evidence_refs": references,
            "usage": _usage_payload(Usage()),
        }
        self._save_normalized(request.round_index, "arbiter", value)
        return ArbitrationResult(
            decision=decision,
            rationale=rationale,
            evidence_refs=tuple(references),
            usage=Usage(),
        )

    def run(self) -> Any:
        callbacks = AdaptiveExecutionCallbacks(
            planner=self._planner,
            executor=self._executor,
            verifier=self._verifier,
            critic=self._critic,
            arbiter=self._arbiter,
        )
        receipt = AdaptiveExecutionEngine(
            callbacks,
            BudgetLimits(max_rounds=self.max_rounds, max_calls_per_stage=self.max_rounds),
        ).run(
            self.instruction,
            context={
                "benchmark_suite": self.benchmark_suite,
                "instruction_sha256": self.instruction_sha256,
                "orchestration": EPISODE_SCHEMA,
            },
        )
        receipt_payload = receipt.to_dict()
        receipt_artifact_sha = _write_once(self.state_dir / "receipt.json", receipt_payload)
        self.journal.record_once(
            "adaptive-receipt",
            "adaptive.completed",
            {
                "receipt_artifact_sha256": receipt_artifact_sha,
                "receipt_sha256": receipt.receipt_sha256,
                "status": receipt.status,
                "succeeded": receipt.succeeded,
            },
        )
        return receipt

    def result_payload(self, receipt: Any) -> dict[str, Any]:
        rounds = list(receipt.rounds)
        final_text = ""
        for item in reversed(rounds):
            if item.execution is not None:
                final_text = item.execution.summary
                break
        stage_calls = dict(receipt.usage.stage_calls)
        token_totals = {
            "input_tokens": 0,
            "cached_input_tokens": 0,
            "output_tokens": 0,
        }
        for round_index in range(1, len(rounds) + 1):
            for stage in ("planner", "executor", "critic"):
                path = self._normalized_path(round_index, stage)
                if not path.is_file():
                    continue
                stage_tokens = ((_read_json(path).get("value") or {}).get(
                    "provider_tokens"
                ) or {})
                for key in token_totals:
                    token_totals[key] += max(0, int(stage_tokens.get(key) or 0))
        return {
            "schema": RESULT_SCHEMA,
            "id": "benchmark-adaptive-%s" % self.instruction_sha256[:16],
            "state": "succeeded" if receipt.succeeded else receipt.status,
            "profile": "sol",
            "provider": "codex",
            "model": "gpt-5.6-sol",
            "final_text": final_text,
            "input_tokens": token_totals["input_tokens"],
            "cached_input_tokens": token_totals["cached_input_tokens"],
            "output_tokens": token_totals["output_tokens"],
            "instruction_sha256": self.instruction_sha256,
            "adaptive_receipt": receipt.to_dict(),
            "pipeline": {
                "kind": "adaptive",
                "total_passes": stage_calls.get("planner", 0)
                + stage_calls.get("executor", 0)
                + stage_calls.get("critic", 0),
                "rounds": len(rounds),
                "receipt_sha256": receipt.receipt_sha256,
                "episode_head_sha256": self.journal.events[-1]["event_sha256"],
                "read_only_sandbox": self.read_only_sandbox,
            },
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="blacklabel-benchmark-adaptive")
    parser.add_argument("--instruction-path", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--result-path", required=True)
    parser.add_argument("--effort", default="high")
    parser.add_argument("--benchmark-suite", default="")
    parser.add_argument("--max-rounds", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=7_200)
    parser.add_argument(
        "--read-only-sandbox",
        choices=("read-only", "danger-full-access"),
        default="read-only",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    instruction_path = Path(args.instruction_path).resolve()
    try:
        instruction = instruction_path.read_bytes().decode("utf-8")
    except (OSError, UnicodeError) as exc:
        raise BenchmarkAdaptiveError("official instruction is not valid UTF-8") from exc
    runner = BenchmarkAdaptiveRunner(
        instruction=instruction,
        workspace=Path(args.workspace),
        state_dir=Path(args.state_dir),
        effort=args.effort,
        benchmark_suite=args.benchmark_suite,
        max_rounds=args.max_rounds,
        timeout_seconds=args.timeout,
        read_only_sandbox=args.read_only_sandbox,
    )
    receipt = runner.run()
    _write_atomic(Path(args.result_path), runner.result_payload(receipt))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
