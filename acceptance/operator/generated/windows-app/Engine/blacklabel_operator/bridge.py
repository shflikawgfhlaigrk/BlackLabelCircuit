import hashlib
import json
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import __version__
from .arc_planner import ArcPlanRejected, ArcPlanningRegistry, ArcSessionCorruption


def _content_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if isinstance(part, str):
            parts.append(part)
        elif isinstance(part, dict):
            text = part.get("text")
            if isinstance(text, str):
                parts.append(text)
            elif part.get("type") in ("input_text", "output_text"):
                value = part.get("content")
                if isinstance(value, str):
                    parts.append(value)
    return "\n".join(parts)


_GRID_ROW = re.compile(r"^(?P<indent>\s*)\[(?P<values>\s*-?\d+(?:\s*,\s*-?\d+)*)\s*\]\s*$")
_FRAME_HEADER = re.compile(r"^\s*Frame\s+\d+\s*:\s*$", re.IGNORECASE)


def _rle_row(values):
    runs = []
    start = 0
    for index in range(1, len(values) + 1):
        if index < len(values) and values[index] == values[start]:
            continue
        coordinate = str(start) if start == index - 1 else "%d-%d" % (start, index - 1)
        runs.append("%d@%s" % (values[start], coordinate))
        start = index
    return " ".join(runs)


def compact_arc_text(text):
    """Losslessly encode numeric ARC grid rows as inclusive coordinate runs."""
    rendered = []
    row_index = 0
    in_frame = False
    for line in str(text).splitlines():
        if _FRAME_HEADER.match(line):
            in_frame = True
            row_index = 0
            rendered.append(line)
            continue
        match = _GRID_ROW.match(line) if in_frame else None
        if match:
            values = [int(value.strip()) for value in match.group("values").split(",")]
            rendered.append("%sy=%d: %s" % (match.group("indent"), row_index, _rle_row(values)))
            row_index += 1
            continue
        if in_frame and line.strip() and not line[:1].isspace():
            in_frame = False
        rendered.append(line)
    return "\n".join(rendered)


def extract_conversation(payload, compact_arc=False):
    raw_input = payload.get("input", "")
    if isinstance(raw_input, str):
        text = raw_input.strip()
        return compact_arc_text(text) if compact_arc else text
    if not isinstance(raw_input, list):
        return str(raw_input).strip()

    messages = []
    for item in raw_input[-40:]:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "message" or "role" in item:
            role = item.get("role", "user")
            text = _content_text(item.get("content"))
            if text:
                if compact_arc:
                    text = compact_arc_text(text)
                messages.append("%s:\n%s" % (role, text))
        elif item_type == "function_call_output":
            output = item.get("output")
            if output:
                messages.append("tool output:\n%s" % str(output))
    return "\n\n".join(messages)[-120000:].strip()


def _role_messages(payload):
    raw_input = payload.get("input", "")
    if isinstance(raw_input, str):
        return [("user", raw_input.strip())] if raw_input.strip() else []
    if not isinstance(raw_input, list):
        return []
    messages = []
    for item in raw_input:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message" and "role" not in item:
            continue
        text = _content_text(item.get("content"))
        if text:
            messages.append((item.get("role", "user"), text))
    return messages


def _arc_continuation_key(user_text, assistant_text):
    material = "arc-continuation-v1\0%s\0%s" % (user_text, assistant_text)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _arc_request_id(payload):
    """Stable identity for one semantic ARC turn across transport retries."""
    material = dict(payload)
    # Streaming changes delivery, not the environment turn being requested.
    material.pop("stream", None)
    encoded = json.dumps(
        material,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(("arc-request-v2\0" + encoded).encode("utf-8")).hexdigest()


class ArcThreadRegistry:
    """Route an ARC observation to the Codex thread that produced its prior action."""

    def __init__(self, max_entries=50000):
        self.max_entries = int(max_entries)
        self._threads = {}
        self._responses = {}
        self._lock = threading.Lock()

    def lookup(self, payload):
        previous_response_id = payload.get("previous_response_id")
        if previous_response_id:
            with self._lock:
                thread_id = self._responses.get(str(previous_response_id))
            if thread_id:
                return thread_id
        messages = _role_messages(payload)
        for index in range(len(messages) - 1, -1, -1):
            role, assistant_text = messages[index]
            if role != "assistant":
                continue
            user_text = next(
                (
                    text
                    for prior_role, text in reversed(messages[:index])
                    if prior_role == "user"
                ),
                None,
            )
            if user_text is None:
                return None
            key = _arc_continuation_key(user_text, assistant_text)
            with self._lock:
                return self._threads.get(key)
        return None

    def record(self, payload, assistant_text, thread_id, response_id=None):
        user_text = next(
            (
                text
                for role, text in reversed(_role_messages(payload))
                if role == "user"
            ),
            None,
        )
        if not user_text or not assistant_text or not thread_id:
            return
        key = _arc_continuation_key(user_text, assistant_text)
        with self._lock:
            self._threads[key] = thread_id
            if response_id:
                self._responses[str(response_id)] = thread_id
            while len(self._threads) + len(self._responses) > self.max_entries:
                collection = self._threads if self._threads else self._responses
                collection.pop(next(iter(collection)))


def _latest_arc_observation(payload):
    text = next(
        (
            value
            for role, value in reversed(_role_messages(payload))
            if role == "user"
        ),
        "",
    )
    return compact_arc_text(text).strip()


def requested_effort(payload, default):
    reasoning = payload.get("reasoning") or {}
    effort = reasoning.get("effort") if isinstance(reasoning, dict) else None
    if effort in ("low", "medium", "high", "xhigh", "max", "ultra"):
        return effort
    return default


def execution_prompt(payload, client_label="operator-client", continuation=False):
    if client_label == "arc-agi-3" and continuation:
        conversation = _latest_arc_observation(payload)
    else:
        conversation = extract_conversation(
            payload, compact_arc=client_label == "arc-agi-3"
        )
    if client_label == "arc-agi-3":
        instructions = payload.get("instructions") or ""
        context_label = (
            "New observation after your prior action"
            if continuation
            else "Conversation"
        )
        return (
            "You are the exact gpt-5.6-sol inference engine for an official "
            "ARC-AGI-3 benchmark turn. Do not inspect or modify local files and do "
            "not call tools. Reason deeply from the supplied game transcript. Track "
            "spatial structure, animation changes, prior actions and their effects. "
            "Grid rows are losslessly encoded as `y=N: value@x value@x0-x1`; x and "
            "y are zero-based and ranges are inclusive. Compare frames and action "
            "effects explicitly. Begin with one compact `MEMORY:` line containing "
            "the current hypothesis, evidence, observed effects, and next plan so it "
            "survives into the next turn. Avoid repeating actions that had no effect "
            "and use RESET only when the evidence supports it. Do not put any valid "
            "action syntax in the MEMORY line. End with exactly one valid action in "
            "the response form requested by the benchmark; the final mentioned "
            "action is executed.\n\n"
            "System instructions:\n%s\n\n%s:\n%s"
            % (instructions, context_label, conversation)
        )
    return (
        "You are an execution engine behind a Black Label Operator interface. Work "
        "directly in the current repository using your coding tools. Complete the "
        "user's latest request end to end, including implementation and verification. "
        "Treat the conversation below as user-visible context; do not describe this "
        "bridge.\n\n"
        + conversation
    )


def response_object(task, response_id, model):
    text = task.get("final_text") or ""
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(task.get("created_at") or time.time()),
        "model": model,
        "status": "completed",
        "output": [
            {
                "type": "message",
                "id": "msg_" + task["id"].replace("-", "")[:20],
                "role": "assistant",
                "status": "completed",
                "content": [
                    {"type": "output_text", "text": text, "annotations": []}
                ],
            }
        ],
        "usage": {
            "input_tokens": int(task.get("input_tokens") or 0),
            "output_tokens": int(task.get("output_tokens") or 0),
            "total_tokens": int(task.get("input_tokens") or 0)
            + int(task.get("output_tokens") or 0),
            "input_tokens_details": {
                "cached_tokens": int(task.get("cached_input_tokens") or 0)
            },
            "output_tokens_details": {"reasoning_tokens": 0},
        },
    }


class OperatorHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, settings, started_at, runtime_status=None):
        super().__init__(address, OperatorRequestHandler)
        self.store = store
        self.settings = settings
        self.started_at = started_at
        self.runtime_status = runtime_status or (lambda: {"ok": True})
        self.arc_threads = ArcThreadRegistry()
        self.arc_planner = ArcPlanningRegistry(Path(settings.home) / "arc-sessions")


class OperatorRequestHandler(BaseHTTPRequestHandler):
    server_version = "BlackLabelOperator/%s" % __version__
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _json(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
            return False
        return True

    def _token(self):
        value = self.headers.get("Authorization", "")
        if value.lower().startswith("bearer "):
            return value[7:].strip()
        return (
            self.headers.get("X-Operator-Token", "").strip()
            or self.headers.get("X-Sol-Token", "").strip()
        )

    def _client(self):
        token = self._token()
        return self.server.store.resolve_client(token) if token else None

    def do_GET(self):
        if self.path == "/health":
            try:
                runtime = dict(self.server.runtime_status())
                runtime_ok = bool(runtime.pop("ok", False))
                counts = self.server.store.counts()
            except Exception as exc:
                self._json(
                    503,
                    {
                        "ok": False,
                        "service": "blacklabel-operator",
                        "error": "%s: %s" % (type(exc).__name__, exc),
                    },
                )
                return
            self._json(
                200 if runtime_ok else 503,
                dict(
                    {
                    "ok": runtime_ok,
                    "service": "blacklabel-operator",
                    "version": __version__,
                    "database_id": getattr(self.server.store, "instance_id", None),
                    "model": self.server.settings.model,
                    "uptime_seconds": int(time.time() - self.server.started_at),
                    "tasks": counts,
                    },
                    **runtime,
                ),
            )
            return
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            if not self._client():
                self._json(401, {"error": {"message": "invalid local client token"}})
                return
            self._json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": self.server.settings.model,
                            "object": "model",
                            "created": int(self.server.started_at),
                            "owned_by": "blacklabel-operator",
                        }
                    ],
                },
            )
            return
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/responses", "/responses"):
            self._json(404, {"error": {"message": "not found"}})
            return
        client = self._client()
        if not client:
            self._json(401, {"error": {"message": "invalid local client token"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 16 * 1024 * 1024:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError) as exc:
            self._json(400, {"error": {"message": str(exc)}})
            return

        is_arc = client["label"] == "arc-agi-3"
        continued_thread = self.server.arc_threads.lookup(payload) if is_arc else None
        arc_session = None
        arc_request_id = _arc_request_id(payload) if is_arc else None
        if is_arc:
            arc_messages = _role_messages(payload)
            instructions = payload.get("instructions")
            if instructions:
                arc_messages.insert(0, ("system", str(instructions)))
            try:
                arc_session = self.server.arc_planner.prepare(
                    arc_messages,
                    continued_thread,
                    request_id=arc_request_id,
                    previous_response_id=payload.get("previous_response_id"),
                )
            except ArcSessionCorruption as exc:
                self._json(409, {"error": {"message": str(exc)}})
                return
            claim = self.server.arc_planner.claim_request(
                arc_session, arc_request_id
            )
            if claim == "wait":
                replay = self.server.arc_planner.wait_for_response(
                    arc_session,
                    arc_request_id,
                    self.server.settings.task_timeout_seconds + 86400,
                )
                if replay is None:
                    self._json(
                        500,
                        {"error": {"message": "duplicate ARC request did not finalize"}},
                    )
                    return
                task = self.server.arc_planner.response_task(replay)
                self._deliver_arc_completed(
                    payload,
                    task,
                    replay["response_id"],
                    arc_session,
                    arc_request_id,
                    replayed=True,
                )
                return
            if claim in ("replay", "recover"):
                replay = arc_session.replay_response
                task = self.server.arc_planner.response_task(replay)
                response_id = replay.get("response_id") or (
                    "resp_" + uuid.uuid4().hex
                )
                self._deliver_arc_completed(
                    payload,
                    task,
                    response_id,
                    arc_session,
                    arc_request_id,
                    replayed=(claim == "replay"),
                )
                return
            queued_text = self.server.arc_planner.take_queued(arc_session)
            if queued_text:
                task_id = "queued-" + uuid.uuid4().hex
                task = {
                    "id": task_id,
                    "state": "succeeded",
                    "created_at": time.time(),
                    "final_text": queued_text,
                    "thread_id": arc_session.thread_id or continued_thread,
                    "input_tokens": 0,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                }
                response_id = "resp_" + uuid.uuid4().hex
                if payload.get("stream", False):
                    self._stream_task(
                        task_id,
                        response_id,
                        client["label"],
                        payload,
                        arc_session=arc_session,
                        completed_task=task,
                        arc_request_id=arc_request_id,
                        arc_output_prepared=True,
                    )
                else:
                    self._blocking_task(
                        task_id,
                        response_id,
                        client["label"],
                        payload,
                        arc_session=arc_session,
                        completed_task=task,
                        arc_request_id=arc_request_id,
                        arc_output_prepared=True,
                    )
                return

        prompt = (
            self.server.arc_planner.model_prompt(arc_session)
            if arc_session and arc_session.last_observation
            else execution_prompt(
                payload, client["label"], continuation=bool(continued_thread)
            )
        )
        if not prompt.strip():
            self._json(400, {"error": {"message": "request contains no text input"}})
            return
        task_id = self.server.store.enqueue(
            prompt=prompt,
            cwd=str(arc_session.workspace) if arc_session else client["cwd"],
            model=self.server.settings.model,
            effort=(
                requested_effort(payload, self.server.settings.effort)
                if client["label"] == "arc-agi-3"
                else self.server.settings.effort
            ),
            sandbox=(
                "workspace-write"
                if is_arc and arc_session
                else self.server.settings.sandbox
            ),
            priority=100,
            max_attempts=1 if is_arc else 2,
            source="operator-responses",
            metadata={
                "client": client["label"],
                "continue_thread": bool(continued_thread),
                "arc_session": arc_session.id if arc_session else None,
                "disable_customizations": True,
                "required_capabilities": ["json_stream", "resume", "sandbox"],
            },
            provider="codex",
            profile="sol",
            isolation="shared",
            thread_id=(arc_session.thread_id if arc_session else continued_thread),
        )
        response_id = "resp_" + uuid.uuid4().hex
        if payload.get("stream", False):
            self._stream_task(
                task_id,
                response_id,
                client["label"],
                payload,
                arc_session=arc_session,
                arc_request_id=arc_request_id,
            )
        else:
            self._blocking_task(
                task_id,
                response_id,
                client["label"],
                payload,
                arc_session=arc_session,
                arc_request_id=arc_request_id,
            )

    def _deliver_arc_completed(
        self,
        payload,
        task,
        response_id,
        arc_session,
        arc_request_id,
        replayed,
    ):
        kwargs = {
            "arc_session": arc_session,
            "completed_task": task,
            "arc_request_id": arc_request_id,
            "arc_output_prepared": True,
            "arc_replayed": replayed,
        }
        if payload.get("stream", False):
            self._stream_task(
                task["id"],
                response_id,
                "arc-agi-3",
                payload,
                **kwargs,
            )
        else:
            self._blocking_task(
                task["id"],
                response_id,
                "arc-agi-3",
                payload,
                **kwargs,
            )

    def _wait(self, task_id, keepalive=None):
        deadline = time.monotonic() + self.server.settings.task_timeout_seconds + 86400
        while time.monotonic() < deadline:
            task = self.server.store.get(task_id)
            if task and task["state"] in ("succeeded", "failed", "cancelled"):
                return task
            if keepalive:
                keepalive()
            time.sleep(1)
        return self.server.store.get(task_id)

    def _remember_arc_thread(
        self,
        client_label,
        payload,
        task,
        response_id,
        arc_session=None,
        arc_request_id=None,
        replayed=False,
    ):
        if client_label == "arc-agi-3":
            self.server.arc_threads.record(
                payload,
                task.get("final_text") or "",
                task.get("thread_id"),
                response_id=response_id,
            )
            if arc_session is not None and arc_request_id and not replayed:
                self.server.arc_planner.complete_request(
                    arc_session, arc_request_id, response_id, task
                )

    def _finalize_arc_task(
        self, client_label, task, arc_session, output_prepared=False
    ):
        if client_label != "arc-agi-3" or arc_session is None or output_prepared:
            return task
        task = dict(task)
        task["final_text"] = self.server.arc_planner.accept_model_response(
            arc_session,
            task.get("final_text") or "",
            task.get("thread_id"),
            task.get("input_tokens") or 0,
            task.get("cached_input_tokens") or 0,
        )
        return task

    def _blocking_task(
        self,
        task_id,
        response_id,
        client_label,
        payload,
        arc_session=None,
        completed_task=None,
        arc_request_id=None,
        arc_output_prepared=False,
        arc_replayed=False,
    ):
        task = completed_task or self._wait(task_id)
        if not task or task["state"] != "succeeded":
            if arc_session is not None:
                self.server.arc_planner.fail_request(arc_session, arc_request_id)
            message = (task or {}).get("error") or "task did not complete"
            self._json(500, {"error": {"message": message}})
            return
        try:
            task = self._finalize_arc_task(
                client_label, task, arc_session, arc_output_prepared
            )
            self._remember_arc_thread(
                client_label,
                payload,
                task,
                response_id,
                arc_session,
                arc_request_id,
                arc_replayed,
            )
        except ArcPlanRejected as exc:
            if arc_session is not None:
                self.server.arc_planner.fail_request(arc_session, arc_request_id)
            self._json(
                502,
                {
                    "error": {
                        "code": "arc_plan_rejected",
                        "type": "arc_plan_rejected",
                        "message": str(exc),
                    }
                },
            )
            return
        except Exception as exc:
            if arc_session is not None:
                self.server.arc_planner.fail_request(arc_session, arc_request_id)
            self._json(500, {"error": {"message": str(exc)}})
            return
        self._json(
            200,
            response_object(task, response_id, self.server.settings.model),
        )

    def _sse(self, payload):
        data = payload if isinstance(payload, str) else json.dumps(payload, separators=(",", ":"))
        self.wfile.write(("data: %s\n\n" % data).encode("utf-8"))
        self.wfile.flush()

    def _stream_task(
        self,
        task_id,
        response_id,
        client_label,
        payload,
        arc_session=None,
        completed_task=None,
        arc_request_id=None,
        arc_output_prepared=False,
        arc_replayed=False,
    ):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        sequence = 0
        created = {
            "type": "response.created",
            "sequence_number": sequence,
            "response": {
                "id": response_id,
                "object": "response",
                "created_at": int(time.time()),
                "model": self.server.settings.model,
                "status": "in_progress",
                "output": [],
            },
        }
        try:
            self._sse(created)
            last_keepalive = [time.monotonic()]

            def keepalive():
                if time.monotonic() - last_keepalive[0] >= 10:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_keepalive[0] = time.monotonic()

            task = completed_task or self._wait(task_id, keepalive=keepalive)
            if not task or task["state"] != "succeeded":
                if arc_session is not None:
                    self.server.arc_planner.fail_request(
                        arc_session, arc_request_id
                    )
                sequence += 1
                self._sse(
                    {
                        "type": "response.failed",
                        "sequence_number": sequence,
                        "response": {
                            "id": response_id,
                            "object": "response",
                            "status": "failed",
                            "error": {
                                "message": (task or {}).get("error")
                                or "task did not complete"
                            },
                        },
                    }
                )
                self._sse("[DONE]")
                return

            try:
                task = self._finalize_arc_task(
                    client_label, task, arc_session, arc_output_prepared
                )
            except ArcPlanRejected as exc:
                if arc_session is not None:
                    self.server.arc_planner.fail_request(
                        arc_session, arc_request_id
                    )
                sequence += 1
                self._sse(
                    {
                        "type": "response.failed",
                        "sequence_number": sequence,
                        "response": {
                            "id": response_id,
                            "object": "response",
                            "status": "failed",
                            "error": {
                                "code": "arc_plan_rejected",
                                "type": "arc_plan_rejected",
                                "message": str(exc),
                            },
                        },
                    }
                )
                self._sse("[DONE]")
                return
            text = task.get("final_text") or ""
            self._remember_arc_thread(
                client_label,
                payload,
                task,
                response_id,
                arc_session,
                arc_request_id,
                arc_replayed,
            )
            item_id = "msg_" + task_id.replace("-", "")[:20]
            for offset in range(0, len(text), 512):
                sequence += 1
                self._sse(
                    {
                        "type": "response.output_text.delta",
                        "sequence_number": sequence,
                        "item_id": item_id,
                        "output_index": 0,
                        "content_index": 0,
                        "delta": text[offset : offset + 512],
                    }
                )
            sequence += 1
            self._sse(
                {
                    "type": "response.completed",
                    "sequence_number": sequence,
                    "response": response_object(
                        task, response_id, self.server.settings.model
                    ),
                }
            )
            self._sse("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception:
            if arc_session is not None:
                self.server.arc_planner.fail_request(arc_session, arc_request_id)
            raise
