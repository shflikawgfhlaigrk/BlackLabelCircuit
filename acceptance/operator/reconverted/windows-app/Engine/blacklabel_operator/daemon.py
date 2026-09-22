import os
import signal
import threading
import time
import traceback
import uuid
from pathlib import Path

from . import __version__
from .adaptive_runtime import AdaptiveTaskRuntime
from .benchmark_receipt import source_identity
from .bridge import OperatorHTTPServer
from .codex_runner import CodexRunner, RunResult, UnconfirmedTerminationError
from .hooks import HookRunner
from .providers import ProviderRegistry
from .profiles import get_profile
from .settings import should_start_new_session
from .store import LeaseOwnershipError, Store
from .verification import VerificationRunner
from .workspace import WorkspaceManager
from .reliability import Reliability

try:
    import fcntl
except ImportError:  # pragma: no cover - exercised on Windows
    fcntl = None

try:
    import msvcrt
except ImportError:  # pragma: no cover - exercised on POSIX
    msvcrt = None


class AttemptLease:
    def __init__(self, store, task_id, owner, generation, lease_seconds, activity):
        self.store = store
        self.task_id = task_id
        self.owner = owner
        self.generation = int(generation)
        self.lease_seconds = lease_seconds
        self.activity = activity
        self.interval = max(0.1, min(5.0, float(lease_seconds) / 3.0))
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._lost = None
        self._last_pulse = 0.0
        self._thread = None

    def pulse(self, force=False):
        with self._lock:
            if self._lost:
                raise LeaseOwnershipError(self._lost)
            now = time.monotonic()
            if not force and now - self._last_pulse < self.interval / 2.0:
                return True
            try:
                owned = self.store.heartbeat(
                    self.task_id,
                    self.owner,
                    self.lease_seconds,
                    self.generation,
                )
            except Exception as exc:
                self._lost = "lease heartbeat failed: %s: %s" % (
                    type(exc).__name__,
                    exc,
                )
                raise LeaseOwnershipError(self._lost)
            if not owned:
                self._lost = "task lease ownership was lost"
                raise LeaseOwnershipError(self._lost)
            self._last_pulse = now
            self.activity(self.task_id)
            return True

    def _loop(self):
        while not self._stop.wait(self.interval):
            try:
                self.pulse(force=True)
            except LeaseOwnershipError:
                return

    def start(self):
        self.pulse(force=True)
        self._thread = threading.Thread(
            target=self._loop,
            name="operator-lease-%s" % self.task_id[:12],
            daemon=True,
        )
        self._thread.start()

    def ensure(self):
        return self.pulse()

    def owned(self):
        with self._lock:
            return self._lost is None

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=max(1.0, self.interval + 0.5))


class TaskExecutor:
    def __init__(self, settings, store, owner, activity=None):
        self.settings = settings
        self.store = store
        self.owner = owner
        self.providers = ProviderRegistry(settings)
        self.hooks = HookRunner(settings, store)
        self.workspaces = WorkspaceManager(settings, store)
        self.verifier = VerificationRunner(settings, store)
        self.activity = activity or (lambda _task_id=None: None)

    def _on_event(self, task_id, generation, event):
        self.activity(task_id)
        thread_id = (
            event.get("thread_id") or event.get("session_id") or event.get("sessionId")
        )
        if event.get("type") == "thread.started" and thread_id:
            changed = self.store.set_runtime(
                task_id,
                self.owner,
                generation,
                thread_id=thread_id,
            )
        elif thread_id:
            changed = self.store.set_runtime(
                task_id,
                self.owner,
                generation,
                thread_id=thread_id,
            )
        else:
            changed = True
        if not changed:
            raise LeaseOwnershipError(
                "task lease ownership was lost during provider event"
            )
        if not self.store.add_event(
            task_id,
            event.get("type", "provider.event"),
            event,
            owner=self.owner,
            generation=generation,
        ):
            raise LeaseOwnershipError(
                "task lease ownership was lost during provider event"
            )

    def execute(self, task, adopted=False):
        task_id = task["id"]
        generation = int(task["lease_generation"])
        execution_cwd = task["cwd"]
        lease = AttemptLease(
            self.store,
            task_id,
            self.owner,
            generation,
            self.settings.lease_seconds,
            self.activity,
        )
        attempt_store = self.store.for_attempt(task_id, self.owner, generation)
        hooks = HookRunner(self.settings, attempt_store)
        workspaces = WorkspaceManager(self.settings, attempt_store)
        verifier = VerificationRunner(self.settings, attempt_store)
        adaptive = None
        adaptive_outcome = None
        sealed_snapshot = None
        reliability = Reliability(self.store)
        contract = (task.get("metadata") or {}).get("reliability") or {}
        budget = contract.get("budget") or {}
        attempt_started = time.monotonic()
        budget_reason = None
        reported_tokens = 0
        prior_usage = [v for v in reliability.metrics(contract["project"])["attempts"]
                       if v["task_id"] == task_id] if contract else []
        prior_tokens = max(sum((v["input_tokens"] or 0) + (v["output_tokens"] or 0) for v in prior_usage),
                           int((task.get("metadata") or {}).get("reliability_reported_tokens", 0)))
        deadline = float(task.get("started_at") or time.time()) + budget.get("wall_seconds", 864000000)

        def observe(event):
            nonlocal reported_tokens
            if event.get("type") == "turn.completed":
                usage = event.get("usage") or {}
                values = [usage.get(k) for k in ("input_tokens", "output_tokens")]
                if all(type(v) is int and v >= 0 for v in values):
                    reported_tokens += sum(values)
                    if contract:
                        attempt_store.update_metadata(task_id, {"reliability_reported_tokens": prior_tokens + reported_tokens})
            self._on_event(task_id, generation, event)

        def heartbeat():
            lease.ensure()

        def cancelled():
            nonlocal budget_reason
            if budget.get("wall_seconds") and time.time() >= deadline:
                budget_reason = "project wall-time budget exhausted"
            if budget.get("max_tokens") and prior_tokens + reported_tokens > budget["max_tokens"]:
                budget_reason = "project reported-token budget exhausted"
            current = self.store.get(task_id)
            return bool(budget_reason) or not current or current["cancel_requested"]

        def cleanup_retained_snapshot():
            nonlocal sealed_snapshot
            candidate = sealed_snapshot or verifier.verified_snapshot
            if candidate and candidate.get("path"):
                verifier.cleanup_verified_snapshot(candidate)
            sealed_snapshot = None

        lease.start()
        try:
            heartbeat()
            if cancelled():
                raise RuntimeError(budget_reason or "task cancelled")
            spec = self.providers.validate(task)
            attempt_store.update_metadata(
                task_id,
                {
                    "provider_executable": str(spec.executable),
                    "provider_capabilities": sorted(spec.capabilities),
                },
            )
            task = self.store.get(task_id) or task
            if not adopted:
                hooks.run(
                    "before_task",
                    task,
                    heartbeat=heartbeat,
                    cancelled=cancelled,
                )
                execution_cwd = str(workspaces.prepare(task))
                task = self.store.get(task_id) or task
                task = dict(task)
                task["cwd"] = execution_cwd
            else:
                execution_cwd = (task.get("metadata") or {}).get(
                    "execution_cwd", task["cwd"]
                )
                task = dict(task)
                task["cwd"] = execution_cwd
            task = reliability.context(task)
            if task["attempt"] > 1 and budget.get("escalate_effort") and prior_usage and not prior_usage[-1]["success"]:
                task["effort"] = budget["escalate_effort"]
                attempt_store.add_event(task_id, "reliability.escalated", {"effort": task["effort"], "reason": "previous attempt failed"})
            if contract:
                attempt_store.add_event(task_id, "reliability.started", {
                    "policy_sha256": contract["policy_sha256"],
                    "outcomes": [o["name"] for o in contract["outcomes"]], "budget": budget,
                })
            if task.get("profile") == "adaptive":
                adaptive_profile = get_profile("adaptive")
                adaptive = AdaptiveTaskRuntime(
                    self.settings,
                    self.providers,
                    attempt_store,
                    heartbeat=heartbeat,
                    cancelled=cancelled,
                    on_start=lambda pid, events, stderr: self._started(
                        task_id, generation, pid, events, stderr
                    ),
                    on_event=observe,
                    max_rounds=budget.get("max_rounds", adaptive_profile.adaptive_max_rounds),
                    max_tokens=min(budget.get("max_tokens", adaptive_profile.adaptive_max_tokens) - prior_tokens,
                                   adaptive_profile.adaptive_max_tokens),
                )
                adaptive_outcome = adaptive.run(
                    task,
                    execution_cwd,
                    adopted=adopted,
                )
                result = adaptive_outcome.result
                if adaptive_outcome.receipt.succeeded:
                    sealed_snapshot = {
                        "path": adaptive_outcome.verified_source,
                        "reference": adaptive_outcome.verified_reference,
                        "identity": adaptive_outcome.verified_identity,
                    }
                if not self.store.set_verification(
                    task_id,
                    self.owner,
                    generation,
                    adaptive_outcome.verification_status,
                ):
                    raise LeaseOwnershipError(
                        "task lease ownership was lost during adaptive verification"
                    )
                attempt_store.add_event(
                    task_id,
                    "verification.status",
                    {
                        "status": adaptive_outcome.verification_status,
                        "required": True,
                        "commands": len(task.get("verification") or []),
                        "adaptive": True,
                        "receipt_phase": "provisional",
                        "provisional_receipt_sha256": (
                            adaptive_outcome.receipt.receipt_sha256
                        ),
                        "adaptive_acceptance_succeeded": (
                            adaptive_outcome.receipt.succeeded
                        ),
                    },
                )
            else:
                runner = self.providers.runner(task)
                if adopted:
                    result = runner.monitor_existing(
                        task,
                        on_event=observe,
                        heartbeat=heartbeat,
                        cancelled=cancelled,
                    )
                else:
                    result = runner.run(
                        task,
                        on_start=lambda pid, events, stderr: self._started(
                            task_id, generation, pid, events, stderr
                        ),
                        on_event=observe,
                        heartbeat=heartbeat,
                        cancelled=cancelled,
                    )
                if result.termination_confirmed and not result.process_may_be_alive:
                    attempt_store.update_metadata(
                        task_id,
                        {
                            "process_group_id": None,
                            "process_identity": None,
                            "active_process_events_path": None,
                            "active_process_stderr_path": None,
                        },
                    )
                if result.success:
                    hooks.run(
                        "before_verify",
                        task,
                        result.as_dict(),
                        heartbeat=heartbeat,
                        cancelled=cancelled,
                    )
                    verifications, verified = verifier.run(
                        task,
                        execution_cwd,
                        heartbeat=heartbeat,
                        cancelled=cancelled,
                        isolated=True,
                        reference=(task.get("metadata") or {}).get("baseline_head"),
                    )
                    if verified is True:
                        sealed_snapshot = verifier.verified_snapshot
                    hooks.run(
                        "after_verify",
                        task,
                        {"verified": verified, "results": verifications},
                        heartbeat=heartbeat,
                        cancelled=cancelled,
                    )
                    if verified is None:
                        verification_status = "not_requested"
                    else:
                        verification_status = "passed" if verified else "failed"
                    if not self.store.set_verification(
                        task_id,
                        self.owner,
                        generation,
                        verification_status,
                    ):
                        raise RuntimeError(
                            "task lease ownership was lost during verification"
                        )
                    attempt_store.add_event(
                        task_id,
                        "verification.status",
                        {
                            "status": verification_status,
                            "required": bool(task.get("verification_required")),
                            "commands": len(verifications),
                        },
                    )
                    if verified is False or (
                        verified is None and task.get("verification_required")
                    ):
                        result.success = False
                        result.error = (
                            "required verification was not configured"
                            if verified is None
                            else "verification gate failed"
                        )
                        result.exit_code = next(
                            (
                                item.get("exit_code")
                                for item in verifications
                                if not item.get("passed")
                            ),
                            1,
                        )
                    elif verified is True:
                        sealed_snapshot = verifier.verified_snapshot
        except UnconfirmedTerminationError as exc:
            result = RunResult(
                success=False,
                error=str(exc),
                pid=exc.pid,
                process_may_be_alive=True,
                termination_confirmed=False,
                termination_detail=exc.detail,
            )
        except Exception as exc:
            result = RunResult(
                success=False,
                error="%s: %s" % (type(exc).__name__, exc),
            )
            if lease.owned():
                try:
                    attempt_store.add_event(
                        task_id,
                        "runner.exception",
                        {"error": result.error, "traceback": traceback.format_exc()},
                    )
                except LeaseOwnershipError:
                    pass

        if contract:
            reported_tokens = max(reported_tokens, int(result.input_tokens or 0) + int(result.output_tokens or 0))
            cancelled()
            if budget.get("max_tokens") and not result.usage_reported and result.success:
                budget_reason = "provider did not report usage for the project token budget"
        if budget_reason:
            result.success = False
            result.cancelled = False
            result.error = budget_reason
            result.exit_code = 1
        if not lease.owned():
            cleanup_retained_snapshot()
            lease.stop()
            return "stale"
        if result.process_may_be_alive or not result.termination_confirmed:
            try:
                return self.store.quarantine(
                    task_id,
                    result.error
                    or result.termination_detail
                    or "process may remain alive",
                    self.owner,
                    generation,
                    pid=result.pid,
                )
            finally:
                cleanup_retained_snapshot()
                lease.stop()

        try:
            hooks.run(
                "on_success" if result.success else "on_failure",
                task,
                result.as_dict(),
                heartbeat=heartbeat,
                cancelled=cancelled,
            )
            hooks.run(
                "after_task",
                task,
                result.as_dict(),
                heartbeat=heartbeat,
                cancelled=cancelled,
            )
        except UnconfirmedTerminationError as exc:
            result.success = False
            result.error = str(exc)
            result.pid = exc.pid
            result.process_may_be_alive = True
            result.termination_confirmed = False
            result.termination_detail = exc.detail
        except Exception as exc:
            if isinstance(exc, LeaseOwnershipError):
                cleanup_retained_snapshot()
                lease.stop()
                return "stale"
            if result.success:
                result.success = False
                result.error = "post-task hook failed: %s" % exc
            try:
                attempt_store.add_event(
                    task_id,
                    "hook.failure",
                    {"error": "%s: %s" % (type(exc).__name__, exc)},
                )
            except LeaseOwnershipError:
                cleanup_retained_snapshot()
                lease.stop()
                return "stale"

        if result.process_may_be_alive or not result.termination_confirmed:
            try:
                return self.store.quarantine(
                    task_id,
                    result.error
                    or result.termination_detail
                    or "hook process may remain alive",
                    self.owner,
                    generation,
                    pid=result.pid,
                )
            finally:
                cleanup_retained_snapshot()
                lease.stop()

        collection_error = None
        collected_source_identity = None
        collected_content_identity = None
        collection_mode = None
        artifact_floor = max(
            (int(item.get("id") or 0) for item in attempt_store.artifacts(task_id)),
            default=0,
        )

        def new_artifact_digest(kind):
            for item in reversed(attempt_store.artifacts(task_id)):
                if int(item.get("id") or 0) <= artifact_floor:
                    break
                if item.get("kind") != kind:
                    continue
                digest = str((item.get("metadata") or {}).get("sha256") or "")
                digest = digest.strip().lower()
                if len(digest) == 64 and all(
                    character in "0123456789abcdef" for character in digest
                ):
                    return digest
            return None

        try:
            heartbeat()
            if adaptive_outcome is not None and adaptive_outcome.receipt.succeeded:
                if not all(
                    (
                        sealed_snapshot,
                        sealed_snapshot.get("path") if sealed_snapshot else None,
                        sealed_snapshot.get("reference") if sealed_snapshot else None,
                        sealed_snapshot.get("identity") if sealed_snapshot else None,
                    )
                ):
                    raise RuntimeError(
                        "adaptive success has no retained isolated verifier snapshot"
                    )
            try:
                if sealed_snapshot:
                    workspaces.collect(
                        task,
                        execution_cwd,
                        result,
                        verified_source=sealed_snapshot.get("path"),
                        verified_reference=sealed_snapshot.get("reference"),
                        verified_identity=sealed_snapshot.get("identity"),
                    )
                else:
                    workspaces.collect(task, execution_cwd, result)
            finally:
                cleanup_retained_snapshot()
        except Exception as exc:
            if isinstance(exc, LeaseOwnershipError):
                lease.stop()
                return "stale"
            collection_error = "%s: %s" % (type(exc).__name__, exc)
            result.success = False
            result.exit_code = result.exit_code if result.exit_code is not None else 1
            result.error = (
                "%s; workspace collection failed: %s" % (result.error, collection_error)
                if result.error
                else "workspace collection failed: %s" % collection_error
            )
            try:
                attempt_store.add_event(
                    task_id,
                    "workspace.collection_failed",
                    {"error": collection_error},
                )
                workspaces.cleanup(task, reason="collection-failed")
            except LeaseOwnershipError:
                lease.stop()
                return "stale"

        if contract:
            cancelled()
            if budget_reason:
                result.success = False
                result.cancelled = False
                result.error = budget_reason
                result.exit_code = 1
        workspace_manifest_sha256 = new_artifact_digest("workspace-manifest")
        current_after_collection = self.store.get(task_id) or task
        collection_metadata = current_after_collection.get("metadata") or {}
        collected_source_identity = collection_metadata.get(
            "workspace_collected_source_identity"
        )
        collected_content_identity = collection_metadata.get(
            "workspace_collected_content_identity"
        )
        collection_mode = collection_metadata.get("workspace_collection_mode")
        if (
            adaptive_outcome is not None
            and adaptive_outcome.receipt.succeeded
            and result.success
            and workspace_manifest_sha256 is None
        ):
            result.success = False
            result.exit_code = result.exit_code if result.exit_code is not None else 1
            result.error = "adaptive finalization found no workspace manifest"
        if (
            adaptive_outcome is not None
            and adaptive_outcome.receipt.succeeded
            and result.success
            and collection_mode != "isolated-verifier-snapshot"
        ):
            result.success = False
            result.exit_code = result.exit_code if result.exit_code is not None else 1
            result.error = "adaptive finalization did not use isolated verifier bytes"

        terminal_artifact = None
        adaptive_failure_receipted = False
        if adaptive_outcome is not None and adaptive_outcome.receipt.succeeded:
            try:
                finalized_receipt = adaptive.finalize_receipt(
                    adaptive_outcome.receipt,
                    result,
                    workspace_manifest_sha256=workspace_manifest_sha256,
                    verified_source_identity=(
                        (adaptive_outcome.verified_identity or {}).get(
                            "source_identity"
                        )
                    ),
                    collected_source_identity=collected_source_identity,
                    collected_content_identity=collected_content_identity,
                )
                if finalized_receipt.succeeded:
                    terminal_artifact = adaptive.prepare_terminal_receipt(
                        finalized_receipt
                    )
                else:
                    adaptive._persist_receipt(finalized_receipt)
                    adaptive_failure_receipted = True
            except Exception as exc:
                if isinstance(exc, LeaseOwnershipError):
                    lease.stop()
                    return "stale"
                result.success = False
                result.exit_code = (
                    result.exit_code if result.exit_code is not None else 1
                )
                result.error = (
                    "%s; adaptive receipt finalization failed: %s" % (result.error, exc)
                    if result.error
                    else "adaptive receipt finalization failed: %s" % exc
                )

        try:
            heartbeat()
            workspaces.write_result(
                task,
                result,
                collection_error=collection_error,
            )
            heartbeat()
        except Exception as exc:
            if isinstance(exc, LeaseOwnershipError):
                lease.stop()
                return "stale"
            result.success = False
            result.exit_code = result.exit_code if result.exit_code is not None else 1
            result.error = (
                "%s; result recording failed: %s" % (result.error, exc)
                if result.error
                else "result recording failed: %s" % exc
            )
            if terminal_artifact is not None:
                terminal_artifact = None
                if not adaptive_failure_receipted:
                    try:
                        failed_receipt = adaptive.finalize_receipt(
                            adaptive_outcome.receipt,
                            result,
                            workspace_manifest_sha256=(workspace_manifest_sha256),
                            verified_source_identity=(
                                (adaptive_outcome.verified_identity or {}).get(
                                    "source_identity"
                                )
                            ),
                            collected_source_identity=collected_source_identity,
                            collected_content_identity=collected_content_identity,
                        )
                        adaptive._persist_receipt(failed_receipt)
                        adaptive_failure_receipted = True
                    except LeaseOwnershipError:
                        lease.stop()
                        return "stale"
                    except Exception:
                        pass

        try:
            current = self.store.get(task_id) or task
            if contract:
                reliability.finish_attempt(task, generation, result, time.monotonic() - attempt_started, budget_reason)
                attempt_store.add_event(task_id, "reliability.completed", {
                    "success": result.success, "budget_reason": budget_reason,
                    "outcomes": [o["name"] for o in contract["outcomes"]],
                    "verification_status": current.get("verification_status"),
                })
        except Exception:
            lease.stop()
            raise
        try:
            if (
                result.success
                or budget_reason
                or result.cancelled
                or current["attempt"] >= current["max_attempts"]
            ):
                return self.store.finish(
                    task_id,
                    result,
                    self.owner,
                    generation,
                    terminal_artifact=terminal_artifact,
                )
            return self.store.retry_or_fail(
                task_id,
                result.error,
                result.exit_code,
                self.owner,
                generation,
            )
        finally:
            # Keep the generation-bound heartbeat active through the terminal
            # state transition. Stopping it first creates a small but real race
            # where a slow SQLite commit can outlive the lease and be reclaimed.
            lease.stop()

    def _started(self, task_id, generation, pid, events_path, stderr_path):
        self.activity(task_id)
        if not self.store.set_runtime(task_id, self.owner, generation, pid=pid):
            raise RuntimeError("task lease ownership was lost before provider start")
        process_group_id = (
            int(pid) if should_start_new_session() and os.name != "nt" else None
        )
        process_identity = CodexRunner.process_identity(pid)
        runtime_metadata = {
            "process_group_id": process_group_id,
            "process_identity": process_identity,
            "active_process_events_path": str(Path(events_path).resolve()),
            "active_process_stderr_path": str(Path(stderr_path).resolve()),
        }
        current_task = self.store.get(task_id) or {}
        if current_task.get("profile") == "adaptive":
            binding = CodexRunner.containment_binding(
                Path(events_path).resolve().parent
                / "containment"
                / "containment.json",
                tasks_root=self.settings.tasks_dir,
            )
            if int(binding["pid"]) != int(pid):
                raise RuntimeError(
                    "adaptive containment gate PID does not match runner start"
                )
            if binding["process_identity"] != CodexRunner.process_identity(pid):
                raise RuntimeError(
                    "adaptive containment gate identity does not match runner start"
                )
            runtime_metadata["process_identity"] = binding["process_identity"]
            for field in (
                "path",
                "sha256",
                "device",
                "inode",
                "bytes",
                "mode",
                "mtime_ns",
                "ctime_ns",
                "label",
                "domain",
                "pid",
                "process_identity",
                "resource_coalition_id",
                "jetsam_coalition_id",
            ):
                runtime_metadata[
                    "active_process_containment_%s" % field
                ] = binding[field]
        if not self.store.update_metadata(
            task_id,
            runtime_metadata,
            owner=self.owner,
            generation=generation,
        ):
            raise LeaseOwnershipError(
                "task lease ownership was lost before process-group recording"
            )
        if not self.store.add_event(
            task_id,
            "runner.started",
            {
                "pid": pid,
                "process_group_id": process_group_id,
                "events_path": events_path,
                "stderr_path": stderr_path,
            },
            owner=self.owner,
            generation=generation,
        ):
            raise LeaseOwnershipError(
                "task lease ownership was lost before provider start"
            )


class OperatorDaemon:
    def __init__(self, settings):
        self.settings = settings
        self.settings.ensure_dirs()
        self.store = Store(settings.db_path)
        self.daemon_id = str(uuid.uuid4())
        self.source_identity = source_identity(settings.repo_root)
        # Capture immutable release identity once at process birth. Health must
        # describe the daemon that answered, not a later-mutated environment.
        self.release_identity = {
            "release_id": os.environ.get("OPERATOR_RELEASE_ID"),
            "release_manifest_sha256": os.environ.get(
                "OPERATOR_RELEASE_MANIFEST_SHA256"
            ),
            "runtime_sha256": os.environ.get("OPERATOR_RUNTIME_SHA256"),
        }
        self.stop_event = threading.Event()
        self.started_at = time.time()
        self.threads = []
        self._runtime_lock = threading.RLock()
        self._worker_threads = {}
        self._worker_status = {}
        self._worker_generation = {}
        self._scheduler_thread = None
        self._scheduler_heartbeat = 0.0
        self._scheduler_last_success_at = 0.0
        self._scheduler_consecutive_errors = 0
        self._supervisor_thread = None
        self._supervisor_heartbeat = 0.0
        self._supervisor_consecutive_errors = 0
        self.lock_handle = None
        self.http = None

    @staticmethod
    def _lock_file(handle):
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if msvcrt is None:  # pragma: no cover - no supported runtime reaches this
            raise RuntimeError("this platform has no supported file locking API")
        handle.seek(0)
        if not handle.read(1):
            handle.seek(0)
            handle.write("0")
            handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)

    @staticmethod
    def _unlock_file(handle):
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return
        if msvcrt is not None:  # pragma: no branch - Windows only
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)

    def acquire_lock(self):
        lock_path = self.settings.home / "daemon.lock"
        self.lock_handle = lock_path.open("a+")
        try:
            self._lock_file(self.lock_handle)
        except (BlockingIOError, OSError):
            self.lock_handle.close()
            self.lock_handle = None
            raise RuntimeError(
                "another Black Label Operator daemon already owns %s" % lock_path
            )
        self.lock_handle.seek(0)
        self.lock_handle.truncate()
        self.lock_handle.write(str(os.getpid()))
        self.lock_handle.flush()

    def _log_runtime_error(self, component, detail=None):
        error_path = self.settings.logs_dir / (component + ".error.log")
        rendered = detail or traceback.format_exc()
        with error_path.open("a", encoding="utf-8") as handle:
            handle.write(
                "[%s]\n%s\n"
                % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), rendered)
            )

    def recover(self, expired_only=False):
        providers = ProviderRegistry(self.settings)
        lease_expired_before = time.time() if expired_only else None
        tasks = (
            self.store.expired_running(lease_expired_before)
            if expired_only
            else self.store.running()
        )
        for task in tasks:
            metadata = task.get("metadata") or {}
            active_kind = metadata.get("active_subprocess_kind")
            if active_kind:
                active_pid = metadata.get("active_subprocess_pid")
                active_group = metadata.get("active_subprocess_group_id")
                active_identity = metadata.get("active_subprocess_identity")
                live_identity = CodexRunner.process_identity(active_pid)
                termination_detail = "no matching live subprocess"
                if task.get("profile") == "adaptive":
                    try:
                        binding = CodexRunner._containment_binding_from_metadata(
                            metadata, prefix="active_subprocess"
                        )
                        confirmed, termination_detail = (
                            CodexRunner.terminate_bound_containment(
                                binding["path"],
                                binding,
                                tasks_root=self.settings.tasks_dir,
                            )
                        )
                    except Exception as exc:
                        confirmed = False
                        termination_detail = (
                            "adaptive containment binding is untrusted: %s" % exc
                        )
                    if not confirmed:
                        termination_detail = (
                            termination_detail
                            or "active adaptive subprocess termination was not confirmed"
                        )
                elif active_pid and active_identity and live_identity == active_identity:
                    confirmed, termination_detail = CodexRunner.safe_terminate(
                        active_pid,
                        active_group,
                        expected_identities={int(active_pid): active_identity},
                    )
                    if not confirmed:
                        termination_detail = (
                            termination_detail
                            or "active subprocess termination was not confirmed"
                        )
                elif live_identity is not None:
                    termination_detail = (
                        "saved subprocess PID identity changed; no signal was sent"
                    )
                self.store.quarantine(
                    task["id"],
                    "daemon interrupted %s subprocess: %s"
                    % (active_kind, termination_detail),
                    task["lease_owner"],
                    task["lease_generation"],
                    pid=active_pid,
                    lease_expired_before=lease_expired_before,
                )
                continue
            if (
                task.get("profile") == "adaptive"
                and metadata.get("adaptive_active_stage")
                and metadata.get("adaptive_active_stage") != "verifier"
            ):
                try:
                    binding = CodexRunner._containment_binding_from_metadata(
                        metadata
                    )
                    CodexRunner._read_containment_manifest(
                        binding["path"],
                        tasks_root=self.settings.tasks_dir,
                        expected_binding=binding,
                    )
                except Exception as exc:
                    self.store.quarantine(
                        task["id"],
                        "adaptive recovery containment is untrusted: %s" % exc,
                        task["lease_owner"],
                        task["lease_generation"],
                        pid=task.get("pid"),
                        lease_expired_before=lease_expired_before,
                    )
                    continue
                owner = "adopt-%s" % uuid.uuid4().hex[:10]
                if self.store.adopt(
                    task["id"],
                    owner,
                    self.settings.lease_seconds,
                    only_if_expired=expired_only,
                ):
                    adopted = self.store.get(task["id"])
                    thread = threading.Thread(
                        target=self._execute_adopted,
                        args=(adopted, owner),
                        name=owner,
                        daemon=True,
                    )
                    thread.start()
                    self.threads.append(thread)
                continue
            pid = task.get("pid")
            saved_identity = metadata.get("process_identity")
            live_identity = CodexRunner.process_identity(pid)
            if (
                saved_identity
                and live_identity == saved_identity
                and CodexRunner.process_alive(pid, task)
            ):
                owner = "adopt-%s" % uuid.uuid4().hex[:10]
                if self.store.adopt(
                    task["id"],
                    owner,
                    self.settings.lease_seconds,
                    only_if_expired=expired_only,
                ):
                    adopted = self.store.get(task["id"])
                    thread = threading.Thread(
                        target=self._execute_adopted,
                        args=(adopted, owner),
                        name=owner,
                        daemon=True,
                    )
                    thread.start()
                    self.threads.append(thread)
            elif live_identity is not None:
                self.store.quarantine(
                    task["id"],
                    (
                        "saved provider PID is live but its start identity does not match; "
                        "no signal was sent"
                    ),
                    task["lease_owner"],
                    task["lease_generation"],
                    pid=pid,
                    lease_expired_before=lease_expired_before,
                )
            elif (
                task.get("profile") == "adaptive"
                and (task.get("metadata") or {}).get("adaptive_active_stage")
                == "verifier"
            ):
                # A daemon interruption can sever our handle to the verifier's
                # supervised process group. Its PID is intentionally not guessed:
                # quarantine the attempt so no retry can overlap a process whose
                # termination cannot be established.
                self.store.quarantine(
                    task["id"],
                    "interrupted adaptive verifier termination is unconfirmed",
                    task["lease_owner"],
                    task["lease_generation"],
                    pid=None,
                    lease_expired_before=lease_expired_before,
                )
            else:
                try:
                    capabilities = providers.get(
                        task.get("provider") or "codex"
                    ).capabilities
                except ValueError:
                    capabilities = frozenset()
                if task.get("thread_id") and "resume" in capabilities:
                    self.store.recover_dead(
                        task,
                        "worker disappeared; resuming provider session",
                        lease_expired_before=lease_expired_before,
                    )
                else:
                    self.store.fail_interrupted(
                        task,
                        "worker disappeared and provider has no resumable session",
                        lease_expired_before=lease_expired_before,
                    )

    def _execute_adopted(self, task, owner):
        try:
            TaskExecutor(self.settings, self.store, owner).execute(task, True)
        except Exception:
            self._log_runtime_error("adoption")

    def _touch_worker(
        self,
        index,
        owner,
        task_id=None,
        error=None,
        successful_poll=False,
        completed=False,
    ):
        with self._runtime_lock:
            current = self._worker_status.get(index, {})
            if current.get("owner") != owner:
                return
            current.update(
                {
                    "owner": owner,
                    "heartbeat_at": time.time(),
                    "task_id": task_id,
                }
            )
            if error is not None:
                current["last_error"] = error
                current["last_error_at"] = time.time()
                current["consecutive_errors"] = (
                    int(current.get("consecutive_errors") or 0) + 1
                )
            if successful_poll:
                current["last_successful_poll_at"] = time.time()
                current["consecutive_errors"] = 0
                if task_id:
                    current["last_claim_at"] = time.time()
            if completed:
                current["last_completion_at"] = time.time()
            self._worker_status[index] = current

    def worker_loop(self, index):
        with self._runtime_lock:
            owner = self._worker_status[index]["owner"]
        executor = TaskExecutor(
            self.settings,
            self.store,
            owner,
            activity=lambda task_id=None: self._touch_worker(index, owner, task_id),
        )
        while not self.stop_event.is_set():
            self._touch_worker(index, owner)
            try:
                task = self.store.claim(owner, self.settings.lease_seconds)
                self._touch_worker(
                    index,
                    owner,
                    task["id"] if task else None,
                    successful_poll=True,
                )
                if task is None:
                    self.stop_event.wait(0.5)
                    continue
                self._touch_worker(index, owner, task["id"])
                executor.execute(task)
                self._touch_worker(index, owner, completed=True)
            except Exception as exc:
                detail = "%s: %s" % (type(exc).__name__, exc)
                self._touch_worker(index, owner, error=detail)
                self._log_runtime_error("worker-%d" % index)
                self.stop_event.wait(0.5)

    def scheduler_loop(self):
        while not self.stop_event.is_set():
            self._scheduler_heartbeat = time.time()
            try:
                self.store.fire_due_schedules()
                Reliability(self.store).poll_watches()
                Reliability(self.store).process_completions()
                self._scheduler_last_success_at = time.time()
                self._scheduler_consecutive_errors = 0
            except Exception:
                self._scheduler_consecutive_errors += 1
                self._log_runtime_error("scheduler")
            self.stop_event.wait(1.0)

    def _start_worker(self, index):
        with self._runtime_lock:
            current = self._worker_threads.get(index)
            if current is not None and current.is_alive():
                return current
            generation = self._worker_generation.get(index, 0) + 1
            self._worker_generation[index] = generation
            owner = "worker-%d-%s" % (index, uuid.uuid4().hex[:10])
            self._worker_status[index] = {
                "owner": owner,
                "generation": generation,
                "heartbeat_at": time.time(),
                "task_id": None,
                "consecutive_errors": 0,
                "last_successful_poll_at": 0.0,
            }
            thread = threading.Thread(
                target=self.worker_loop,
                args=(index,),
                name="operator-worker-%d" % index,
                daemon=True,
            )
            self._worker_threads[index] = thread
            self.threads.append(thread)
            thread.start()
            return thread

    def _start_scheduler(self):
        with self._runtime_lock:
            if self._scheduler_thread is not None and self._scheduler_thread.is_alive():
                return self._scheduler_thread
            self._scheduler_heartbeat = time.time()
            thread = threading.Thread(
                target=self.scheduler_loop,
                name="operator-scheduler",
                daemon=True,
            )
            self._scheduler_thread = thread
            self.threads.append(thread)
            thread.start()
            return thread

    def supervisor_loop(self):
        recovery_interval = max(1.0, min(10.0, self.settings.lease_seconds / 3.0))
        while not self.stop_event.is_set():
            self._supervisor_heartbeat = time.time()
            try:
                self._start_scheduler()
                for index in range(self.settings.workers):
                    self._start_worker(index)
                self.recover(expired_only=True)
                self._supervisor_consecutive_errors = 0
            except Exception:
                self._supervisor_consecutive_errors += 1
                self._log_runtime_error("supervisor")
            self.stop_event.wait(recovery_interval)

    def runtime_status(self):
        now = time.time()
        stale_after = max(5.0, float(self.settings.lease_seconds))
        metrics = self.store.runtime_metrics(now)
        with self._runtime_lock:
            workers = []
            live_workers = 0
            for index in range(self.settings.workers):
                thread = self._worker_threads.get(index)
                status = dict(self._worker_status.get(index) or {})
                heartbeat = float(status.get("heartbeat_at") or 0)
                age = max(0.0, now - heartbeat) if heartbeat else None
                alive = bool(
                    thread
                    and thread.is_alive()
                    and age is not None
                    and age <= stale_after
                )
                live_workers += int(alive)
                workers.append(
                    {
                        "index": index,
                        "alive": alive,
                        "generation": status.get("generation", 0),
                        "owner": status.get("owner"),
                        "task_id": status.get("task_id"),
                        "heartbeat_age_seconds": round(age, 3)
                        if age is not None
                        else None,
                        "last_error": status.get("last_error"),
                        "consecutive_errors": int(
                            status.get("consecutive_errors") or 0
                        ),
                        "last_successful_poll_at": status.get(
                            "last_successful_poll_at"
                        ),
                        "last_claim_at": status.get("last_claim_at"),
                        "last_completion_at": status.get("last_completion_at"),
                    }
                )
            scheduler_age = (
                max(0.0, now - self._scheduler_heartbeat)
                if self._scheduler_heartbeat
                else None
            )
            scheduler_alive = bool(
                self._scheduler_thread
                and self._scheduler_thread.is_alive()
                and scheduler_age is not None
                and scheduler_age <= stale_after
            )
            supervisor_age = (
                max(0.0, now - self._supervisor_heartbeat)
                if self._supervisor_heartbeat
                else None
            )
            supervisor_alive = bool(
                self._supervisor_thread
                and self._supervisor_thread.is_alive()
                and supervisor_age is not None
                and supervisor_age <= stale_after
            )
        reasons = []
        if live_workers != self.settings.workers:
            reasons.append("worker capacity is degraded")
        if not scheduler_alive:
            reasons.append("scheduler is not live")
        if not supervisor_alive:
            reasons.append("supervisor is not live")
        failed_workers = [
            item["index"] for item in workers if item["consecutive_errors"] >= 3
        ]
        if failed_workers:
            reasons.append(
                "workers have repeated runtime errors: %s"
                % ",".join(str(index) for index in failed_workers)
            )
        if self._scheduler_consecutive_errors >= 3:
            reasons.append("scheduler has repeated runtime errors")
        if self._supervisor_consecutive_errors >= 3:
            reasons.append("supervisor has repeated runtime errors")
        if metrics["expired_running"]:
            reasons.append("expired task leases require recovery")
        return {
            "ok": not reasons and not self.stop_event.is_set(),
            "version": __version__,
            "daemon_id": self.daemon_id,
            "database_id": self.store.instance_id,
            "database_schema_version": self.store.identity()["schema_version"],
            "source_revision": self.source_identity.get("revision"),
            "source_tree_sha256": self.source_identity.get("tree_sha256"),
            "source_dirty": self.source_identity.get("dirty"),
            "release_id": self.release_identity["release_id"],
            "release_manifest_sha256": self.release_identity[
                "release_manifest_sha256"
            ],
            "runtime_sha256": self.release_identity["runtime_sha256"],
            "configured_workers": self.settings.workers,
            "live_workers": live_workers,
            "workers": workers,
            "scheduler_alive": scheduler_alive,
            "scheduler_consecutive_errors": self._scheduler_consecutive_errors,
            "scheduler_last_success_at": self._scheduler_last_success_at,
            "scheduler_heartbeat_age_seconds": (
                round(scheduler_age, 3) if scheduler_age is not None else None
            ),
            "supervisor_alive": supervisor_alive,
            "supervisor_consecutive_errors": self._supervisor_consecutive_errors,
            "supervisor_heartbeat_age_seconds": (
                round(supervisor_age, 3) if supervisor_age is not None else None
            ),
            "degraded_reasons": reasons,
            "progress": metrics,
        }

    def serve(self):
        self.acquire_lock()
        self.recover()
        self._start_scheduler()
        for index in range(self.settings.workers):
            self._start_worker(index)
        self._supervisor_heartbeat = time.time()
        self._supervisor_thread = threading.Thread(
            target=self.supervisor_loop,
            name="operator-supervisor",
            daemon=True,
        )
        self.threads.append(self._supervisor_thread)
        self._supervisor_thread.start()
        self.http = OperatorHTTPServer(
            ("127.0.0.1", self.settings.port),
            self.store,
            self.settings,
            self.started_at,
            runtime_status=self.runtime_status,
        )
        try:
            self.http.serve_forever(poll_interval=0.5)
        finally:
            self.stop_event.set()
            self.http.server_close()
            for thread in list(self.threads):
                thread.join(timeout=5)
            if self.lock_handle is not None:
                self._unlock_file(self.lock_handle)
                self.lock_handle.close()
                self.lock_handle = None

    def stop(self):
        self.stop_event.set()
        if self.http:
            threading.Thread(target=self.http.shutdown, daemon=True).start()


def run_daemon(settings):
    daemon = OperatorDaemon(settings)

    def handle_signal(_signum, _frame):
        daemon.stop()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    daemon.serve()
