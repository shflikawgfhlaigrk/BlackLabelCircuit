import json
import os
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from .codex_runner import CodexRunner, RunResult
from .grok_adapter import find_binary as find_grok_binary
from .settings import should_start_new_session


@dataclass(frozen=True)
class ProviderSpec:
    name: str
    display_name: str
    executable: object
    capabilities: frozenset
    prompt_transport: str = "stdin"
    builtin: bool = True

    def as_dict(self):
        payload = asdict(self)
        payload["capabilities"] = sorted(self.capabilities)
        payload["executable"] = str(self.executable or "")
        payload["available"] = bool(self.executable)
        return payload


def _which(*names):
    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found).resolve()
    return None


class ExternalEventAccumulator:
    def __init__(self):
        self.thread_id = None
        self.final_text = ""
        self.input_tokens = 0
        self.cached_input_tokens = 0
        self.output_tokens = 0
        self.failure = None
        self.raw_text = []

    def add_line(self, line):
        self.raw_text.append(line)
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            if line.strip():
                self.final_text = line.strip()
            return {"type": "provider.output", "text": line}

        event_type = event.get("type") or event.get("event") or "provider.event"
        self.thread_id = (
            event.get("session_id")
            or event.get("sessionId")
            or event.get("thread_id")
            or self.thread_id
        )
        usage = event.get("usage") or event.get("stats") or {}
        self.input_tokens = int(
            usage.get("input_tokens")
            or usage.get("inputTokens")
            or self.input_tokens
            or 0
        )
        self.cached_input_tokens = int(
            usage.get("cached_input_tokens")
            or usage.get("cachedInputTokens")
            or self.cached_input_tokens
            or 0
        )
        self.output_tokens = int(
            usage.get("output_tokens")
            or usage.get("outputTokens")
            or self.output_tokens
            or 0
        )
        for key in ("result", "text", "content", "message", "response"):
            value = event.get(key)
            if isinstance(value, str) and value.strip():
                self.final_text = value
            elif isinstance(value, dict):
                nested = value.get("text") or value.get("content")
                if isinstance(nested, str) and nested.strip():
                    self.final_text = nested
        if event_type in ("error", "failed", "turn.failed"):
            self.failure = event.get("error") or event.get("message") or line
        return event

    def result(
        self,
        exit_code=None,
        timed_out=False,
        cancelled=False,
        error=None,
        pid=None,
        process_may_be_alive=False,
        termination_confirmed=True,
        termination_detail=None,
    ):
        error = error or self.failure
        if timed_out:
            error = "provider task timed out"
        elif cancelled:
            error = "provider task cancelled"
        elif exit_code not in (0, None) and not error:
            error = "provider exited with status %s" % exit_code
        if not self.final_text and self.raw_text:
            self.final_text = "\n".join(self.raw_text)[-16000:].strip()
        return RunResult(
            success=exit_code == 0 and not error and not timed_out and not cancelled,
            exit_code=exit_code,
            final_text=self.final_text,
            error=error,
            thread_id=self.thread_id,
            input_tokens=self.input_tokens,
            cached_input_tokens=self.cached_input_tokens,
            output_tokens=self.output_tokens,
            timed_out=timed_out,
            cancelled=cancelled,
            pid=pid,
            process_may_be_alive=process_may_be_alive,
            termination_confirmed=termination_confirmed,
            termination_detail=termination_detail,
        )


def _reject_duplicate_json_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON object key: %s" % key)
        value[key] = item
    return value


class GrokEventAccumulator(ExternalEventAccumulator):
    """Reduce Grok Build's documented ``streaming-json`` wire format.

    Grok emits response text as chunks and certifies a completed headless turn
    with a terminal ``end`` object.  Tool locations and memory-flush paths are
    useful provenance, but they are locators only; observing one does not prove
    that an artifact exists or contains the requested change.
    """

    SUCCESS_STOP_REASONS = frozenset(("end_turn",))
    MAX_METADATA_ITEMS = 64
    MAX_METADATA_TEXT = 1024
    COMPACTION_EVENT_TYPES = frozenset(
        {
            "auto_compact_started",
            "auto_compact_completed",
            "auto_compact_failed",
            "auto_compact_cancelled",
            "auto_continue_completed",
        }
    )
    USAGE_FIELDS = (
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "output_tokens",
        "reasoning_tokens",
        "total_tokens",
    )

    def __init__(self):
        super().__init__()
        self.request_id = None
        self.stop_reason = None
        self.completed = False
        self.usage_reported = False
        self.usage = {}
        self.usage_source = None
        self.compaction_events = []
        self.compaction_events_dropped = 0
        self.tool_locations = []
        self.tool_locations_dropped = 0
        self.memory_flush_paths = []
        self.memory_flush_paths_dropped = 0
        self._text_chunks = []
        self._seen_locations = set()
        self._seen_memory_paths = set()

    @classmethod
    def _bounded_text(cls, value):
        if not isinstance(value, str):
            return None
        return value[: cls.MAX_METADATA_TEXT]

    def _fail(self, message):
        if not self.failure:
            self.failure = message

    @classmethod
    def _required_identifier(cls, event, name):
        value = event.get(name)
        if (
            not isinstance(value, str)
            or not value.strip()
            or value != value.strip()
            or len(value) > cls.MAX_METADATA_TEXT
        ):
            return None
        if any(ord(character) < 32 for character in value):
            return None
        return value

    def _record_session_id(self, session_id):
        if (
            not isinstance(session_id, str)
            or not session_id.strip()
            or session_id != session_id.strip()
            or len(session_id) > self.MAX_METADATA_TEXT
            or any(ord(character) < 32 for character in session_id)
        ):
            self._fail("Grok emitted an invalid sessionId")
            return
        if self.thread_id is not None and self.thread_id != session_id:
            self._fail("Grok emitted conflicting sessionId values")
            return
        self.thread_id = session_id

    def _record_request_id(self, request_id):
        if (
            not isinstance(request_id, str)
            or not request_id.strip()
            or request_id != request_id.strip()
            or len(request_id) > self.MAX_METADATA_TEXT
            or any(ord(character) < 32 for character in request_id)
        ):
            self._fail("Grok emitted an invalid requestId")
            return
        if self.request_id is not None and self.request_id != request_id:
            self._fail("Grok emitted conflicting requestId values")
            return
        self.request_id = request_id

    def _event_identifier(self, event, canonical_name, alias_name):
        values = []
        for name in (canonical_name, alias_name):
            if name not in event:
                continue
            value = self._required_identifier(event, name)
            if value is None:
                self._fail("Grok emitted an invalid %s" % canonical_name)
                return None
            values.append(value)
        if len(set(values)) > 1:
            self._fail("Grok emitted conflicting %s values" % canonical_name)
            return None
        return values[0] if values else None

    def _parse_usage(self, value, source, accumulate=False):
        if value is None:
            return
        if not isinstance(value, dict):
            self._fail("Grok emitted malformed %s usage metadata" % source)
            return
        parsed = {}
        for name in self.USAGE_FIELDS:
            if name not in value:
                continue
            amount = value.get(name)
            if isinstance(amount, bool) or not isinstance(amount, int) or amount < 0:
                self._fail("Grok emitted malformed %s usage metadata" % source)
                return
            parsed[name] = amount
        if not parsed:
            return
        self.usage_reported = True
        if accumulate:
            for name, amount in parsed.items():
                self.usage[name] = self.usage.get(name, 0) + amount
        else:
            self.usage = parsed
        self.usage_source = source
        self.input_tokens = int(self.usage.get("input_tokens") or 0)
        self.cached_input_tokens = int(
            self.usage.get("cache_read_input_tokens") or 0
        )
        self.output_tokens = int(self.usage.get("output_tokens") or 0)

    def _append_bounded(self, values, value, dropped_name):
        if len(values) < self.MAX_METADATA_ITEMS:
            values.append(value)
        else:
            setattr(self, dropped_name, getattr(self, dropped_name) + 1)

    def _record_locations(self, locations):
        if locations is None:
            return
        if not isinstance(locations, list):
            self._fail("Grok emitted malformed tool location metadata")
            return
        for location in locations:
            normalized = None
            if isinstance(location, str):
                path = self._bounded_text(location)
                if path:
                    normalized = {"path": path}
            elif isinstance(location, dict):
                path = self._bounded_text(location.get("path"))
                if path:
                    normalized = {"path": path}
                    line = location.get("line")
                    if isinstance(line, int) and not isinstance(line, bool) and line >= 0:
                        normalized["line"] = line
            if normalized is None:
                continue
            identity = json.dumps(normalized, sort_keys=True, separators=(",", ":"))
            if identity in self._seen_locations:
                continue
            self._seen_locations.add(identity)
            self._append_bounded(
                self.tool_locations,
                normalized,
                "tool_locations_dropped",
            )

    def _record_memory_path(self, path):
        normalized = self._bounded_text(path)
        if not normalized or normalized in self._seen_memory_paths:
            return
        self._seen_memory_paths.add(normalized)
        self._append_bounded(
            self.memory_flush_paths,
            normalized,
            "memory_flush_paths_dropped",
        )

    def _record_compaction(self, event_type, event):
        compact = {"type": event_type}
        for name in ("percentage", "total_tokens"):
            value = event.get(name)
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                compact[name] = value
        error = self._bounded_text(event.get("error"))
        if error:
            compact["error"] = error
        self._append_bounded(
            self.compaction_events,
            compact,
            "compaction_events_dropped",
        )

    def add_line(self, line):
        try:
            event = json.loads(line, object_pairs_hook=_reject_duplicate_json_keys)
        except ValueError:
            if line.strip():
                self._fail("Grok emitted malformed streaming-json")
            return {"type": "provider.output", "text": line}
        if not isinstance(event, dict):
            self._fail("Grok emitted a non-object streaming-json event")
            return {"type": "provider.event", "value": event}

        event_type = event.get("type")
        if not isinstance(event_type, str) or not event_type:
            self._fail("Grok emitted a streaming-json event without a type")
            return event
        if self.completed and event_type != "end":
            self._fail("Grok emitted data after its terminal end event")

        session_id = self._event_identifier(event, "sessionId", "session_id")
        request_id = self._event_identifier(event, "requestId", "request_id")
        if session_id is not None:
            self._record_session_id(session_id)
        if request_id is not None:
            self._record_request_id(request_id)

        if event_type == "text":
            data = event.get("data")
            if not isinstance(data, str):
                self._fail("Grok emitted malformed text data")
            else:
                self._text_chunks.append(data)
                self.final_text = "".join(self._text_chunks)
        elif event_type == "usage":
            self._parse_usage(event.get("usage"), "response", accumulate=True)
        elif event_type in ("tool_call", "tool_call_update"):
            self._record_locations(event.get("locations"))
        elif event_type == "memory_flush_completed":
            self._record_memory_path(event.get("path"))
        elif event_type in self.COMPACTION_EVENT_TYPES:
            self._record_compaction(event_type, event)
        elif event_type == "error":
            message = event.get("message")
            self._fail(
                message
                if isinstance(message, str) and message.strip()
                else "Grok emitted an error event"
            )
        elif event_type == "end":
            session_id = self._required_identifier(event, "sessionId")
            request_id = self._required_identifier(event, "requestId")
            stop_reason = self._required_identifier(event, "stopReason")
            if session_id is None or request_id is None or stop_reason is None:
                self._fail("Grok emitted malformed terminal end metadata")
            else:
                self._record_session_id(session_id)
                self._record_request_id(request_id)
                if self.stop_reason is not None and self.stop_reason != stop_reason:
                    self._fail("Grok emitted conflicting stopReason values")
                if (
                    self.completed
                    and self.thread_id == session_id
                    and self.request_id == request_id
                    and self.stop_reason == stop_reason
                ):
                    self._fail("Grok emitted multiple terminal end events")
                self.request_id = request_id
                self.stop_reason = stop_reason
                self.completed = True
                if "usage" in event:
                    self._parse_usage(event.get("usage"), "terminal", accumulate=False)
                if stop_reason not in self.SUCCESS_STOP_REASONS:
                    self._fail(
                        "Grok ended with non-success stopReason: %s" % stop_reason
                    )

        return event

    def metadata_event(self):
        return {
            "type": "provider.metadata",
            "provider": "grok",
            "session_id": self.thread_id,
            "request_id": self.request_id,
            "stop_reason": self.stop_reason,
            "terminal_end_observed": self.completed,
            "usage": dict(self.usage),
            "usage_source": self.usage_source,
            "compaction_events": list(self.compaction_events),
            "compaction_events_dropped": self.compaction_events_dropped,
            "artifact_metadata": {
                "status": "locations_only_not_content_verified",
                "tool_locations": list(self.tool_locations),
                "tool_locations_dropped": self.tool_locations_dropped,
                "memory_flush_paths": list(self.memory_flush_paths),
                "memory_flush_paths_dropped": self.memory_flush_paths_dropped,
            },
            "checkpoint_metadata": "not_exposed_by_streaming_json",
        }

    def result(
        self,
        exit_code=None,
        timed_out=False,
        cancelled=False,
        error=None,
        pid=None,
        process_may_be_alive=False,
        termination_confirmed=True,
        termination_detail=None,
    ):
        error = error or self.failure
        if timed_out:
            error = "provider task timed out"
        elif cancelled:
            error = "provider task cancelled"
        elif exit_code not in (0, None) and not error:
            error = "provider exited with status %s" % exit_code
        elif not self.completed and not error:
            error = "Grok exited without a terminal end event"
        return RunResult(
            success=(
                exit_code == 0
                and self.completed
                and not error
                and not timed_out
                and not cancelled
            ),
            exit_code=exit_code,
            final_text=self.final_text,
            error=error,
            thread_id=self.thread_id,
            input_tokens=self.input_tokens,
            cached_input_tokens=self.cached_input_tokens,
            output_tokens=self.output_tokens,
            timed_out=timed_out,
            cancelled=cancelled,
            pid=pid,
            process_may_be_alive=process_may_be_alive,
            termination_confirmed=termination_confirmed,
            termination_detail=termination_detail,
            usage_reported=self.usage_reported,
        )


class ExternalCliRunner:
    def __init__(self, settings, spec, custom=None):
        self.settings = settings
        self.spec = spec
        self.custom = custom or {}

    @property
    def capabilities(self):
        return self.spec.capabilities

    def _command(self, task, resume=False):
        executable = str(self.spec.executable)
        model = task.get("model") or ""
        effort = task.get("effort") or self.settings.effort
        prompt = task["prompt"]
        provider = self.spec.name

        if self.custom:
            key = "resume_command" if resume else "command"
            template = self.custom.get(key) or self.custom.get("command")
            if not isinstance(template, list) or not template:
                raise ValueError("custom provider %s requires an argv command list" % provider)
            values = {
                "executable": executable,
                "model": model,
                "effort": effort,
                "cwd": task["cwd"],
                "thread_id": task.get("thread_id") or "",
                "prompt": prompt,
            }
            command = [str(part).format(**values) for part in template]
            return command, None if "{prompt}" in json.dumps(template) else prompt

        if provider == "claude":
            command = [
                executable,
                "-p",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "bypassPermissions",
                "--effort",
                effort if effort != "ultra" else "max",
                "--safe-mode",
            ]
            if model:
                command.extend(["--model", model])
            if resume and task.get("thread_id"):
                command.extend(["--resume", task["thread_id"]])
            return command, prompt
        if provider == "gemini":
            command = [
                executable,
                "--prompt",
                "",
                "--output-format",
                "stream-json",
                "--approval-mode",
                "yolo",
                "--skip-trust",
            ]
            if model:
                command.extend(["--model", model])
            if resume and task.get("thread_id"):
                command.extend(["--resume", task["thread_id"]])
            return command, prompt
        if provider == "opencode":
            command = [executable, "run", "--auto", "--pure", "--format", "json"]
            if model:
                command.extend(["--model", model])
            if resume and task.get("thread_id"):
                command.extend(["--session", task["thread_id"]])
            command.append(prompt)
            return command, None
        if provider == "hermes":
            command = [executable, "chat", "-q", prompt]
            if resume and task.get("thread_id"):
                command.extend(["--resume", task["thread_id"]])
            return command, None
        if provider == "openclaw":
            return [executable, "agent", "--message", prompt, "--json"], None
        if provider == "grok":
            command = [
                executable,
                "--single",
                prompt,
                "--output-format",
                "streaming-json",
                "--permission-mode",
                "auto",
                "--sandbox",
                "strict",
                "--reasoning-effort",
                effort,
            ]
            if model:
                command.extend(["--model", model])
            if resume and task.get("thread_id"):
                command.extend(["--resume", task["thread_id"]])
            return command, None
        raise ValueError("provider command is not implemented: %s" % provider)

    def _accumulator(self):
        if self.spec.name == "grok" and not self.custom:
            return GrokEventAccumulator()
        return ExternalEventAccumulator()

    @staticmethod
    def _emit_completion_metadata(accumulator, on_event):
        if on_event and isinstance(accumulator, GrokEventAccumulator):
            on_event(accumulator.metadata_event())

    def _task_paths(self, task):
        task_dir = self.settings.tasks_dir / task["id"]
        task_dir.mkdir(parents=True, exist_ok=True)
        attempt = int(task.get("attempt") or 1)
        return (
            task_dir / ("attempt-%d.events.jsonl" % attempt),
            task_dir / ("attempt-%d.stderr.log" % attempt),
        )

    def run(
        self,
        task,
        on_start=None,
        on_event=None,
        heartbeat=None,
        cancelled=None,
    ):
        resume = (
            "resume" in self.capabilities
            and bool(task.get("thread_id"))
            and int(task.get("attempt") or 1) > 1
        )
        command, stdin_prompt = self._command(task, resume=resume)
        events_path, stderr_path = self._task_paths(task)
        accumulator = self._accumulator()
        started = time.monotonic()
        last_heartbeat = 0.0
        timed_out = False
        was_cancelled = False
        termination_confirmed = True
        termination_detail = None
        callback_error = None

        metadata = dict(task.get("metadata") or {})
        metadata["provider_executable"] = str(self.spec.executable)
        task["metadata"] = metadata
        with events_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open(
            "w", encoding="utf-8"
        ) as stderr_file:
            new_session = should_start_new_session()
            process = subprocess.Popen(
                command,
                cwd=task["cwd"],
                stdin=subprocess.PIPE if stdin_prompt is not None else subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
                text=True,
                start_new_session=new_session,
                env=os.environ.copy(),
            )
            process_group_id = process.pid if new_session and os.name != "nt" else None
            try:
                if on_start:
                    on_start(process.pid, str(events_path), str(stderr_path))
                if stdin_prompt is not None:
                    process.stdin.write(stdin_prompt)
                    process.stdin.close()

                with events_path.open("r", encoding="utf-8") as reader:
                    while True:
                        for line in reader.readlines():
                            event = accumulator.add_line(line.rstrip("\n"))
                            if on_event:
                                on_event(event)
                        now = time.monotonic()
                        if heartbeat and now - last_heartbeat >= 5:
                            heartbeat()
                            last_heartbeat = now
                        if process.poll() is not None:
                            for line in reader.readlines():
                                event = accumulator.add_line(line.rstrip("\n"))
                                if on_event:
                                    on_event(event)
                            break
                        was_cancelled = bool(cancelled and cancelled())
                        timed_out = now - started >= self.settings.task_timeout_seconds
                        if was_cancelled or timed_out:
                            termination_confirmed, termination_detail = (
                                CodexRunner.terminate_spawned(
                                    process, process_group_id
                                )
                            )
                            break
                        time.sleep(self.settings.poll_seconds)
            except Exception as exc:
                callback_error = "%s: %s" % (type(exc).__name__, exc)
                termination_confirmed, termination_detail = (
                    CodexRunner.terminate_spawned(process, process_group_id)
                )
        if callback_error is None:
            try:
                self._emit_completion_metadata(accumulator, on_event)
            except Exception as exc:
                callback_error = "%s: %s" % (type(exc).__name__, exc)
        remaining_group = CodexRunner.process_group_members(process_group_id)
        if remaining_group:
            _, detail = CodexRunner.safe_terminate(process.pid, process_group_id)
            remaining_group = CodexRunner.process_group_members(process_group_id)
            termination_confirmed = not remaining_group
            termination_detail = detail
        return accumulator.result(
            process.poll(),
            timed_out,
            was_cancelled,
            error=("runner callback failed: %s" % callback_error if callback_error else None),
            pid=process.pid,
            process_may_be_alive=not termination_confirmed,
            termination_confirmed=termination_confirmed,
            termination_detail=termination_detail,
        )

    def monitor_existing(self, task, on_event=None, heartbeat=None, cancelled=None):
        events_path, _ = self._task_paths(task)
        accumulator = self._accumulator()
        if not events_path.exists():
            return accumulator.result(exit_code=1)
        pid = task.get("pid")
        process_group_id = (task.get("metadata") or {}).get("process_group_id")
        termination_confirmed = True
        termination_detail = None
        was_cancelled = False
        with events_path.open("r", encoding="utf-8") as reader:
            try:
                while CodexRunner.process_alive(pid, task):
                    for line in reader.readlines():
                        event = accumulator.add_line(line.rstrip("\n"))
                        if on_event:
                            on_event(event)
                    if heartbeat:
                        heartbeat()
                    if cancelled and cancelled():
                        was_cancelled = True
                        termination_confirmed, termination_detail = (
                            CodexRunner.safe_terminate(pid, process_group_id)
                        )
                        if not termination_confirmed and CodexRunner.process_exists(pid):
                            break
                    time.sleep(self.settings.poll_seconds)
            except Exception as exc:
                termination_confirmed, termination_detail = CodexRunner.safe_terminate(
                    pid, process_group_id
                )
                return accumulator.result(
                    exit_code=1,
                    error="adopted runner callback failed: %s: %s"
                    % (type(exc).__name__, exc),
                    pid=pid,
                    process_may_be_alive=(
                        CodexRunner.process_exists(pid)
                        or bool(CodexRunner.process_group_members(process_group_id))
                    ),
                    termination_confirmed=(
                        not CodexRunner.process_exists(pid)
                        and not CodexRunner.process_group_members(process_group_id)
                    ),
                    termination_detail=termination_detail,
                )
            for line in reader.readlines():
                event = accumulator.add_line(line.rstrip("\n"))
                if on_event:
                    on_event(event)
        try:
            self._emit_completion_metadata(accumulator, on_event)
        except Exception as exc:
            return accumulator.result(
                exit_code=1,
                error="adopted runner callback failed: %s: %s"
                % (type(exc).__name__, exc),
                pid=pid,
                process_may_be_alive=(
                    CodexRunner.process_exists(pid)
                    or bool(CodexRunner.process_group_members(process_group_id))
                ),
                termination_confirmed=(
                    not CodexRunner.process_exists(pid)
                    and not CodexRunner.process_group_members(process_group_id)
                ),
                termination_detail=termination_detail,
            )
        process_may_be_alive = CodexRunner.process_exists(pid) or bool(
            CodexRunner.process_group_members(process_group_id)
        )
        return accumulator.result(
            0 if not accumulator.failure and not process_may_be_alive else 1,
            cancelled=was_cancelled,
            pid=pid,
            process_may_be_alive=process_may_be_alive,
            termination_confirmed=not process_may_be_alive,
            termination_detail=termination_detail,
        )


class ProviderRegistry:
    def __init__(self, settings):
        self.settings = settings
        self._custom = self._load_custom()

    def _load_custom(self):
        path = self.settings.home / "providers.json"
        if not path.is_file():
            return {}
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
        providers = payload.get("providers", payload)
        if not isinstance(providers, dict):
            raise ValueError("providers.json must contain an object")
        return providers

    def _grok_binary(self):
        return find_grok_binary(self.settings)

    def specs(self):
        specs = {
            "codex": ProviderSpec(
                "codex",
                "Codex CLI",
                self.settings.codex_bin if self.settings.codex_bin.is_file() else None,
                CodexRunner.capabilities,
            ),
            "claude": ProviderSpec(
                "claude",
                "Claude Code",
                _which("claude"),
                frozenset({"json_stream", "resume", "sandbox", "worktree", "mcp", "structured_output"}),
            ),
            "gemini": ProviderSpec(
                "gemini",
                "Gemini CLI",
                _which("gemini"),
                frozenset({"json_stream", "resume", "sandbox", "worktree", "mcp", "acp"}),
            ),
            "opencode": ProviderSpec(
                "opencode",
                "OpenCode",
                _which("opencode"),
                frozenset({"json_stream", "resume", "mcp"}),
                prompt_transport="argv",
            ),
            "grok": ProviderSpec(
                "grok",
                "Grok Build",
                self._grok_binary(),
                frozenset({"json_stream", "resume", "sandbox"}),
                prompt_transport="argv",
            ),
            "hermes": ProviderSpec(
                "hermes",
                "Hermes Agent",
                _which("hermes"),
                frozenset({"resume", "worktree", "mcp", "gateway", "cron"}),
                prompt_transport="argv",
            ),
            "openclaw": ProviderSpec(
                "openclaw",
                "OpenClaw",
                _which("openclaw"),
                frozenset({"json_stream", "mcp", "gateway", "cron", "tool_restriction"}),
                prompt_transport="argv",
            ),
        }
        for name, config in self._custom.items():
            executable = config.get("executable")
            if executable:
                executable = Path(executable).expanduser()
                if not executable.is_absolute():
                    executable = _which(str(executable))
                elif not executable.is_file():
                    executable = None
            specs[name] = ProviderSpec(
                name=name,
                display_name=config.get("display_name", name),
                executable=executable,
                capabilities=frozenset(config.get("capabilities", [])),
                prompt_transport=config.get("prompt_transport", "stdin"),
                builtin=False,
            )
        return specs

    def get(self, name):
        spec = self.specs().get(name)
        if not spec:
            raise ValueError("unknown provider: %s" % name)
        return spec

    def validate(self, task):
        spec = self.get(task.get("provider") or "codex")
        if not spec.executable:
            raise RuntimeError("provider CLI is not installed: %s" % spec.name)
        required = set((task.get("metadata") or {}).get("required_capabilities", []))
        missing = sorted(required - set(spec.capabilities))
        if missing:
            raise RuntimeError(
                "provider %s lacks required capabilities: %s"
                % (spec.name, ", ".join(missing))
            )
        return spec

    def runner(self, task):
        spec = self.validate(task)
        if spec.name == "codex":
            return CodexRunner(self.settings)
        return ExternalCliRunner(self.settings, spec, self._custom.get(spec.name))

    def report(self):
        return [spec.as_dict() for spec in self.specs().values()]
