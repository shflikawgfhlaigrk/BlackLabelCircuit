import json
import os
import sys
import unicodedata
from pathlib import Path

from . import __version__
from .cli import normalize_verification, require_daemon
from .profiles import require_explicit_verification, resolve_execution
from .providers import ProviderRegistry
from .settings import Settings
from .store import Store
from .reliability import OPERATIONS, Reliability, preflight_verification


VERIFICATION_ENTRY_SCHEMA = {
    "oneOf": [
        {"type": "string", "minLength": 1, "maxLength": 8000},
        {
            "type": "object",
            "properties": {
                "command": {"type": "string", "minLength": 1, "maxLength": 8000},
                "writable_paths": {
                    "type": "array",
                    "items": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 240,
                        "pattern": r"^(?!/)(?!.*(?:^|/)\.{1,2}(?:/|$))(?!.*//)(?!.*\\)(?!.*\/$).+$",
                    },
                    "maxItems": 64,
                },
            },
            "required": ["command"],
            "additionalProperties": False,
        },
    ]
}


THREAD_ID_MAX_LENGTH = 512


def _validated_thread_id(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("thread_id must be a string")
    if not value or value != value.strip():
        raise ValueError("thread_id must be a nonempty string without outer whitespace")
    if len(value) > THREAD_ID_MAX_LENGTH:
        raise ValueError(
            "thread_id must be at most %d characters" % THREAD_ID_MAX_LENGTH
        )
    if any(unicodedata.category(character) == "Cc" for character in value):
        raise ValueError("thread_id must not contain control characters")
    return value


TOOLS = [
    {
        "name": "operator_reliability",
        "description": (
            "Manage local project reliability. configure input: outcomes [{name,command,writable_paths?}], "
            "budget {wall_seconds,max_tokens,max_attempts,max_rounds,effort,escalate_effort}, "
            "actions {name:{perform:[argv],reconcile:[argv],timeout_seconds}}. "
            "remember: {key,value,source,ttl_seconds?}; forget: {key}. "
            "action: {key,name,payload,retry?}; reconciles before any replay. "
            "trigger: {key,event_type,prompt,enabled?}; emit: {id,type,payload?}. "
            "playbook: {key,match,steps,failure_task,success_task,conditions:[file paths]}. "
            "ack: {id}. status, memory, actions, triggers, playbooks, metrics, notifications need no input."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"operation": {"enum": list(OPERATIONS)}, "project": {"type": "string"},
                           "input": {"type": "object"}},
            "required": ["operation", "project"], "additionalProperties": False,
        },
    },
    {
        "name": "operator_submit",
        "description": "Queue durable work in Black Label Operator and return its task ID.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "cwd": {"type": "string"},
                "profile": {
                    "enum": [
                        "sol",
                        "sol-benchmark",
                        "safe",
                        "build",
                        "adaptive",
                        "full",
                    ],
                    "default": "sol",
                },
                "provider": {"type": "string"},
                "model": {"type": "string"},
                "priority": {"type": "integer", "default": 0},
                "isolation": {"enum": ["shared", "worktree"]},
                "after": {"type": "array", "items": {"type": "string"}},
                "client_request_id": {
                    "type": "string",
                    "format": "uuid",
                    "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                },
                "require_idle": {"type": "boolean", "default": False},
                "thread_id": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": THREAD_ID_MAX_LENGTH,
                    "pattern": r"^[^\u0000-\u001F\u007F-\u009F]+$",
                },
                "continue_thread": {"type": "boolean", "default": False},
                "verify": {
                    "type": "array",
                    "items": VERIFICATION_ENTRY_SCHEMA,
                    "maxItems": 32,
                },
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_adaptive_start",
        "description": (
            "Start a bounded adaptive task in a worktree with deterministic, "
            "isolated verification."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "cwd": {"type": "string"},
                "priority": {"type": "integer", "default": 0},
                "after": {"type": "array", "items": {"type": "string"}},
                "client_request_id": {
                    "type": "string",
                    "format": "uuid",
                    "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                },
                "require_idle": {"type": "boolean", "default": False},
                "verification": {
                    "type": "array",
                    "items": VERIFICATION_ENTRY_SCHEMA,
                    "minItems": 1,
                    "maxItems": 32,
                },
            },
            "required": ["prompt", "verification"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_adaptive_status",
        "description": "Read one adaptive task, including verification and final result.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_adaptive_cancel",
        "description": "Request cancellation of one queued or running adaptive task.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_task",
        "description": "Read one Operator task, including state and final result.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_list",
        "description": "List recent durable Operator tasks.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string"},
                "limit": {"type": "integer", "default": 20},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_events",
        "description": "Read the admitted event stream for one Operator task.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string"},
                "after": {"type": "integer", "default": 0},
            },
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_cancel",
        "description": "Request cancellation of a queued or running Operator task.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_artifacts",
        "description": "List checkpoints, patches, verifier logs, and result artifacts.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "operator_providers",
        "description": "Inspect available CLI providers and their declared capabilities.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]


class OperatorMCP:
    def __init__(self):
        self.settings = Settings.load()
        self.settings.ensure_dirs()
        self.store = Store(self.settings.db_path)

    @staticmethod
    def _content(value, is_error=False):
        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(value, indent=2, sort_keys=True, default=str),
                }
            ],
            "isError": is_error,
        }

    def _enqueue(self, arguments, adaptive=False):
        with self.store.admission():
            return self._enqueue_admitted(arguments, adaptive=adaptive)

    def _enqueue_admitted(self, arguments, adaptive=False):
        if adaptive and ({"thread_id", "continue_thread"} & set(arguments)):
            raise ValueError("adaptive submissions do not accept conversation threads")
        require_idle = arguments.get("require_idle", False)
        if not isinstance(require_idle, bool):
            raise ValueError("require_idle must be a boolean")
        continue_thread = arguments.get("continue_thread", False)
        if not isinstance(continue_thread, bool):
            raise ValueError("continue_thread must be a boolean")
        thread_id = _validated_thread_id(arguments.get("thread_id"))
        if continue_thread and thread_id is None:
            raise ValueError("continue_thread requires a nonempty thread_id")
        prompt = str(arguments.get("prompt") or "").strip()
        if not prompt:
            raise RuntimeError("prompt is empty")
        cwd = Path(arguments.get("cwd") or os.getcwd()).expanduser().resolve()
        verification = normalize_verification(
            arguments.get("verification")
            if adaptive
            else arguments.get("verify")
        )
        execution = resolve_execution(
            "adaptive" if adaptive else arguments.get("profile", "sol"),
            provider=None if adaptive else arguments.get("provider"),
            model=None if adaptive else arguments.get("model"),
            isolation=None if adaptive else arguments.get("isolation"),
        )
        require_explicit_verification(execution, preflight_verification(self.store, cwd, verification))
        metadata = {
            "required_capabilities": execution["required_capabilities"],
            "disable_customizations": execution["disable_customizations"],
        }
        if continue_thread:
            metadata["continue_thread"] = True
        submission = {
            "prompt": prompt,
            "cwd": cwd,
            "model": execution["model"],
            "effort": execution["effort"],
            "sandbox": execution["sandbox"],
            "priority": int(arguments.get("priority", 0)),
            "max_attempts": execution["max_attempts"],
            "source": "mcp-adaptive" if adaptive else "mcp",
            "metadata": metadata,
            "provider": execution["provider"],
            "profile": execution["profile"],
            "isolation": execution["isolation"],
            "verification": verification,
            "verification_required": (
                bool(verification) or execution["require_verification"]
            ),
            "dependencies": arguments.get("after", []),
            "thread_id": thread_id,
            "client_request_id": arguments.get("client_request_id"),
            "require_idle": require_idle,
        }
        reconciled = self.store.reconcile_submission(**submission)
        if reconciled is not None:
            return self._content(reconciled)

        if not cwd.is_dir():
            raise RuntimeError("working directory does not exist: %s" % cwd)
        require_daemon(self.settings, self.store)
        ProviderRegistry(self.settings).validate(
            {
                "provider": execution["provider"],
                "metadata": {
                    "required_capabilities": execution["required_capabilities"]
                },
            }
        )
        result = self.store.submit(**submission)
        return self._content(result)

    def _adaptive_task(self, task_id):
        task = self.store.get(task_id)
        if not task:
            raise ValueError("task not found")
        if task.get("profile") != "adaptive":
            raise ValueError("task is not an adaptive task")
        return task

    def call(self, name, arguments):
        if name == "operator_reliability":
            return self._content(Reliability(self.store).call(
                arguments["operation"], arguments["project"], arguments.get("input")
            ))
        if name == "operator_submit":
            return self._enqueue(arguments)
        if name == "operator_adaptive_start":
            return self._enqueue(arguments, adaptive=True)
        if name == "operator_adaptive_status":
            return self._content(self._adaptive_task(arguments["task_id"]))
        if name == "operator_adaptive_cancel":
            task = self._adaptive_task(arguments["task_id"])
            changed = self.store.request_cancel(task["id"])
            return self._content({"task_id": task["id"], "cancel_requested": changed})
        if name == "operator_task":
            task = self.store.get(arguments["task_id"])
            if not task:
                raise ValueError("task not found")
            return self._content(task)
        if name == "operator_list":
            return self._content(
                self.store.list(
                    limit=int(arguments.get("limit", 20)), state=arguments.get("state")
                )
            )
        if name == "operator_events":
            return self._content(
                self.store.events(
                    arguments["task_id"], after=int(arguments.get("after", 0))
                )
            )
        if name == "operator_cancel":
            changed = self.store.request_cancel(arguments["task_id"])
            return self._content({"cancel_requested": changed})
        if name == "operator_artifacts":
            return self._content(self.store.artifacts(arguments["task_id"]))
        if name == "operator_providers":
            return self._content(ProviderRegistry(self.settings).report())
        raise ValueError("unknown tool: %s" % name)

    def handle(self, message):
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "black-label-operator", "version": __version__},
                },
            }
        if method in ("notifications/initialized", "initialized"):
            return None
        if method == "ping":
            return {"jsonrpc": "2.0", "id": request_id, "result": {}}
        if method == "tools/list":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"tools": TOOLS},
            }
        if method == "tools/call":
            params = message.get("params") or {}
            try:
                result = self.call(params.get("name"), params.get("arguments") or {})
            except Exception as exc:
                result = self._content(
                    {"error": "%s: %s" % (type(exc).__name__, exc)}, is_error=True
                )
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        if request_id is None:
            return None
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "method not found"},
        }


def main():
    server = OperatorMCP()
    for raw in sys.stdin:
        try:
            message = json.loads(raw)
            response = server.handle(message)
        except Exception as exc:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": "%s: %s" % (type(exc).__name__, exc)},
            }
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
