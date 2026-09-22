import hashlib
import json
import os
import sqlite3
import stat
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .upgrade_lock import (
    UPGRADE_MESSAGE,
    UpgradeInProgressError,
    admission_lock,
    exclusive_upgrade_lock,
)

TERMINAL_STATES = ("succeeded", "failed", "cancelled", "blocked")
_INITIALIZE_LOCK = threading.Lock()
_SCHEMA_VERSION = 5
_CLIENT_REQUEST_INDEX = "idx_tasks_client_request"
_CLIENT_REQUEST_INDEX_SQL = (
    "CREATE UNIQUE INDEX idx_tasks_client_request "
    "ON tasks(source, client_request_id) "
    "WHERE client_request_id IS NOT NULL"
)
_UPGRADE_META_KEY = "upgrade_admission_closed"


class LeaseOwnershipError(RuntimeError):
    """Raised when an attempt tries to write after losing its lease generation."""


def _canonical_workspace_key(cwd):
    path = Path(cwd).expanduser().resolve()
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            try:
                identity = candidate.stat()
            except OSError:
                break
            return "filesystem:%d:%d" % (identity.st_dev, identity.st_ino)
    try:
        identity = path.stat()
    except OSError:
        # A queued path is allowed to be created later. Anchor its case-folded
        # suffix to the nearest existing directory's filesystem identity so
        # aliases cannot evade shared-workspace serialization on APFS.
        for ancestor in path.parents:
            try:
                identity = ancestor.stat()
            except OSError:
                continue
            suffix = str(path.relative_to(ancestor)).casefold()
            return "missing:%d:%d:%s" % (
                identity.st_dev,
                identity.st_ino,
                suffix,
            )
        return "missing-path:%s" % str(path).casefold()
    return "filesystem:%d:%d" % (identity.st_dev, identity.st_ino)


def _text_value(value):
    if value is None or isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, default=str)


def _canonical_client_request_id(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("client_request_id must be a canonical UUID string")
    try:
        canonical = str(uuid.UUID(value))
    except (AttributeError, ValueError) as exc:
        raise ValueError("client_request_id must be a canonical UUID string") from exc
    if value != canonical:
        raise ValueError("client_request_id must be a canonical UUID string")
    return canonical


def _canonical_submission_request(
    *,
    prompt,
    cwd,
    model,
    effort,
    sandbox,
    priority,
    max_attempts,
    source,
    metadata,
    provider,
    profile,
    isolation,
    verification,
    verification_required,
    dependencies,
    thread_id,
    require_idle,
):
    """Serialize every caller-controlled enqueue field for exact retries."""
    return json.dumps(
        {
            "prompt": prompt,
            "cwd": str(Path(cwd).expanduser().resolve()),
            "model": model,
            "effort": effort,
            "sandbox": sandbox,
            "priority": int(priority),
            "max_attempts": max(1, int(max_attempts)),
            "source": source,
            "metadata": metadata or {},
            "provider": provider,
            "profile": profile,
            "isolation": isolation,
            "verification": verification or [],
            "verification_required": bool(verification_required),
            "dependencies": list(dependencies or []),
            "thread_id": thread_id,
            "require_idle": require_idle,
        },
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _valid_sha256(value):
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value.lower())
    )


def _read_bound_regular_file(path, *, maximum_bytes):
    """Read one immutable evidence file without following a final symlink.

    The caller still binds the resolved parent to an attempt-owned directory.
    Comparing the descriptor and final path identities closes a replacement
    race while the bytes are being hashed.
    """
    raw = Path(path).expanduser()
    if raw.is_symlink():
        raise ValueError("evidence file is not a regular file")
    resolved = raw.resolve()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(str(resolved), flags)
    except OSError as exc:
        raise ValueError("evidence file is unreadable") from exc
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError("evidence file is not a regular file")
        if opened.st_size > int(maximum_bytes):
            raise ValueError("evidence file exceeds size limit")
        chunks = []
        remaining = int(maximum_bytes) + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > int(maximum_bytes):
            raise ValueError("evidence file exceeds size limit")
        try:
            current = resolved.stat()
        except OSError as exc:
            raise ValueError("evidence file changed during validation") from exc
        if (opened.st_dev, opened.st_ino, opened.st_size) != (
            current.st_dev,
            current.st_ino,
            current.st_size,
        ):
            raise ValueError("evidence file changed during validation")
        return resolved, opened, payload
    finally:
        os.close(descriptor)


def _lease_expiry_guard(expired_before):
    if expired_before is None:
        return "", ()
    return (
        " AND (lease_expires_at IS NULL OR lease_expires_at < ?)",
        (float(expired_before),),
    )


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with _INITIALIZE_LOCK:
            self.initialize()

    @contextmanager
    def connection(self):
        conn = sqlite3.connect(str(self.path), timeout=30, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=30000")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
        finally:
            conn.close()

    def initialize(self):
        with self.connection() as conn:
            # Refuse an unknown database before any CREATE/ALTER statement can
            # silently downgrade or partially mutate it.
            schema_version = self._schema_version(conn)
            if schema_version >= _SCHEMA_VERSION:
                self._validate_client_request_index(conn)
            conn.executescript(
                """
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                PRAGMA foreign_keys=ON;

                CREATE TABLE IF NOT EXISTS operator_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    state TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    prompt TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    model TEXT NOT NULL,
                    effort TEXT NOT NULL,
                    sandbox TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'cli',
                    attempt INTEGER NOT NULL DEFAULT 0,
                    max_attempts INTEGER NOT NULL DEFAULT 2,
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    lease_generation INTEGER NOT NULL DEFAULT 0,
                    pid INTEGER,
                    thread_id TEXT,
                    started_at REAL,
                    finished_at REAL,
                    exit_code INTEGER,
                    final_text TEXT,
                    error TEXT,
                    cancel_requested INTEGER NOT NULL DEFAULT 0,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    metadata TEXT NOT NULL DEFAULT '{}',
                    provider TEXT NOT NULL DEFAULT 'codex',
                    profile TEXT NOT NULL DEFAULT 'sol',
                    isolation TEXT NOT NULL DEFAULT 'shared',
                    workspace_key TEXT NOT NULL DEFAULT '',
                    verification TEXT NOT NULL DEFAULT '[]',
                    verification_required INTEGER NOT NULL DEFAULT 0,
                    verification_status TEXT NOT NULL DEFAULT 'not_requested',
                    verified_at REAL,
                    client_request_id TEXT,
                    client_request_payload TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_tasks_queue
                    ON tasks(state, priority DESC, created_at ASC);
                CREATE INDEX IF NOT EXISTS idx_tasks_lease
                    ON tasks(state, lease_expires_at);

                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id, seq);

                CREATE TABLE IF NOT EXISTS clients (
                    token TEXT PRIMARY KEY,
                    cwd TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    label TEXT NOT NULL DEFAULT 'operator-client'
                );

                CREATE TABLE IF NOT EXISTS task_dependencies (
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    depends_on_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(task_id, depends_on_id),
                    CHECK(task_id != depends_on_id)
                );
                CREATE INDEX IF NOT EXISTS idx_task_dependencies_parent
                    ON task_dependencies(depends_on_id, task_id);

                CREATE TABLE IF NOT EXISTS artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    path TEXT NOT NULL,
                    metadata TEXT NOT NULL DEFAULT '{}',
                    UNIQUE(task_id, kind, path)
                );
                CREATE INDEX IF NOT EXISTS idx_artifacts_task
                    ON artifacts(task_id, id);

                CREATE TABLE IF NOT EXISTS schedules (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    name TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    prompt TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    profile TEXT NOT NULL,
                    effort TEXT NOT NULL,
                    sandbox TEXT NOT NULL,
                    isolation TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    max_attempts INTEGER NOT NULL DEFAULT 1,
                    verification TEXT NOT NULL DEFAULT '[]',
                    verification_required INTEGER NOT NULL DEFAULT 0,
                    interval_seconds REAL,
                    next_run_at REAL NOT NULL,
                    delete_after_run INTEGER NOT NULL DEFAULT 0,
                    last_run_at REAL,
                    last_task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
                    metadata TEXT NOT NULL DEFAULT '{}'
                );
                CREATE INDEX IF NOT EXISTS idx_schedules_due
                    ON schedules(enabled, next_run_at);

                CREATE TRIGGER IF NOT EXISTS block_task_insert_during_upgrade
                BEFORE INSERT ON tasks
                WHEN EXISTS (
                    SELECT 1 FROM operator_meta
                    WHERE key = 'upgrade_admission_closed'
                )
                BEGIN
                    SELECT RAISE(
                        ABORT,
                        'Operator upgrade is in progress; task admission is closed'
                    );
                END;

                CREATE TRIGGER IF NOT EXISTS block_task_claim_during_upgrade
                BEFORE UPDATE OF state ON tasks
                WHEN NEW.state IN ('queued', 'running')
                  AND OLD.state != NEW.state
                  AND EXISTS (
                    SELECT 1 FROM operator_meta
                    WHERE key = 'upgrade_admission_closed'
                  )
                BEGIN
                    SELECT RAISE(
                        ABORT,
                        'Operator upgrade is in progress; task admission is closed'
                    );
                END;
                """
            )
            if schema_version == 0:
                conn.execute(
                    "INSERT OR IGNORE INTO operator_meta(key, value) "
                    "VALUES ('schema_version', '0')"
                )
            self._ensure_columns(conn)
            from .reliability import initialize as initialize_reliability
            initialize_reliability(conn)
        self.instance_id = self.meta("instance_id")

    @staticmethod
    def _schema_version(conn):
        table = conn.execute(
            "SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = 'operator_meta'"
        ).fetchone()
        if table is None:
            return 0
        try:
            row = conn.execute(
                "SELECT value FROM operator_meta WHERE key = 'schema_version'"
            ).fetchone()
        except sqlite3.DatabaseError as exc:
            raise RuntimeError("operator schema metadata is malformed") from exc
        if row is None:
            raise RuntimeError("operator schema version metadata is missing")
        raw = row["value"]
        if (
            not isinstance(raw, str)
            or not raw.isascii()
            or not raw.isdecimal()
            or len(raw) > 20
            or (len(raw) > 1 and raw.startswith("0"))
        ):
            raise RuntimeError("operator schema version is malformed")
        version = int(raw)
        if version > _SCHEMA_VERSION:
            raise RuntimeError(
                "operator schema version %d is newer than supported version %d"
                % (version, _SCHEMA_VERSION)
            )
        return version

    @staticmethod
    def _validate_client_request_index(conn):
        catalog = conn.execute(
            "SELECT type, tbl_name, sql FROM sqlite_master WHERE name = ?",
            (_CLIENT_REQUEST_INDEX,),
        ).fetchone()
        index_rows = {
            row["name"]: row
            for row in conn.execute("PRAGMA index_list(tasks)").fetchall()
        }
        index = index_rows.get(_CLIENT_REQUEST_INDEX)
        expected_sql = " ".join(_CLIENT_REQUEST_INDEX_SQL.lower().split())
        actual_sql = (
            " ".join(catalog["sql"].strip().rstrip(";").lower().split())
            if catalog is not None and isinstance(catalog["sql"], str)
            else None
        )
        columns = [
            row["name"]
            for row in conn.execute(
                "PRAGMA index_info('%s')" % _CLIENT_REQUEST_INDEX
            ).fetchall()
        ]
        keyed = [
            (row["name"], row["desc"], row["coll"])
            for row in conn.execute(
                "PRAGMA index_xinfo('%s')" % _CLIENT_REQUEST_INDEX
            ).fetchall()
            if row["key"]
        ]
        valid = (
            catalog is not None
            and catalog["type"] == "index"
            and catalog["tbl_name"] == "tasks"
            and index is not None
            and index["unique"] == 1
            and index["origin"] == "c"
            and index["partial"] == 1
            and columns == ["source", "client_request_id"]
            and keyed
            == [
                ("source", 0, "BINARY"),
                ("client_request_id", 0, "BINARY"),
            ]
            and actual_sql == expected_sql
        )
        if not valid:
            raise RuntimeError(
                "operator schema invariant is invalid: %s" % _CLIENT_REQUEST_INDEX
            )

    @staticmethod
    def _refresh_live_workspace_keys(conn):
        """Bind shared claims to the filesystem objects that exist right now."""
        rows = conn.execute(
            "SELECT id, cwd, workspace_key FROM tasks "
            "WHERE state IN ('queued', 'running') AND isolation = 'shared'"
        ).fetchall()
        for row in rows:
            current = _canonical_workspace_key(row["cwd"])
            if current != row["workspace_key"]:
                conn.execute(
                    "UPDATE tasks SET workspace_key = ? WHERE id = ?",
                    (current, row["id"]),
                )

    @staticmethod
    def _ensure_columns(conn):
        conn.execute("BEGIN IMMEDIATE")
        try:
            schema_version = Store._schema_version(conn)
            columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(tasks)").fetchall()
            }
            additions = {
                "provider": "TEXT NOT NULL DEFAULT 'codex'",
                "profile": "TEXT NOT NULL DEFAULT 'sol'",
                "isolation": "TEXT NOT NULL DEFAULT 'shared'",
                "workspace_key": "TEXT NOT NULL DEFAULT ''",
                "verification": "TEXT NOT NULL DEFAULT '[]'",
                "lease_generation": "INTEGER NOT NULL DEFAULT 0",
                "verification_required": "INTEGER NOT NULL DEFAULT 0",
                "verification_status": "TEXT NOT NULL DEFAULT 'not_requested'",
                "verified_at": "REAL",
                "client_request_id": "TEXT",
                "client_request_payload": "TEXT",
            }
            for name, declaration in additions.items():
                if name not in columns:
                    conn.execute(
                        "ALTER TABLE tasks ADD COLUMN %s %s" % (name, declaration)
                    )
            if schema_version < 4:
                rows = conn.execute("SELECT id, cwd FROM tasks").fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, cwd FROM tasks "
                    "WHERE workspace_key IS NULL OR workspace_key = ''"
                ).fetchall()
            for row in rows:
                conn.execute(
                    "UPDATE tasks SET workspace_key = ? WHERE id = ?",
                    (_canonical_workspace_key(row["cwd"]), row["id"]),
                )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_tasks_workspace "
                "ON tasks(state, isolation, workspace_key)"
            )
            conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_client_request "
                "ON tasks(source, client_request_id) "
                "WHERE client_request_id IS NOT NULL"
            )
            Store._validate_client_request_index(conn)
            schedule_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(schedules)").fetchall()
            }
            if "verification_required" not in schedule_columns:
                conn.execute(
                    "ALTER TABLE schedules ADD COLUMN verification_required "
                    "INTEGER NOT NULL DEFAULT 0"
                )
            conn.execute(
                "INSERT OR IGNORE INTO operator_meta(key, value) VALUES ('instance_id', ?)",
                (str(uuid.uuid4()),),
            )
            conn.execute(
                "INSERT INTO operator_meta(key, value) VALUES ('schema_version', ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (str(_SCHEMA_VERSION),),
            )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

    @staticmethod
    def _task(row):
        if row is None:
            return None
        item = dict(row)
        try:
            item["metadata"] = json.loads(item.get("metadata") or "{}")
        except json.JSONDecodeError:
            item["metadata"] = {}
        try:
            item["verification"] = json.loads(item.get("verification") or "[]")
        except json.JSONDecodeError:
            item["verification"] = []
        item["cancel_requested"] = bool(item.get("cancel_requested"))
        item["verification_required"] = bool(item.get("verification_required"))
        item.pop("client_request_payload", None)
        return item

    @staticmethod
    def _insert_event(conn, task_id, event_type, payload, created_at=None):
        conn.execute(
            "INSERT INTO events(task_id, created_at, event_type, payload) VALUES (?, ?, ?, ?)",
            (
                task_id,
                float(created_at or time.time()),
                event_type,
                json.dumps(payload, sort_keys=True, default=str),
            ),
        )

    def meta(self, key, default=None):
        with self.connection() as conn:
            row = conn.execute(
                "SELECT value FROM operator_meta WHERE key = ?", (key,)
            ).fetchone()
        return row["value"] if row else default

    def identity(self):
        return {
            "database_id": self.instance_id,
            "schema_version": int(self.meta("schema_version", "0")),
        }

    @contextmanager
    def admission(self):
        """Hold a shared gate from preflight through one task admission."""
        with admission_lock(self.path):
            with self.connection() as conn:
                closed = conn.execute(
                    "SELECT 1 FROM operator_meta WHERE key = ?",
                    (_UPGRADE_META_KEY,),
                ).fetchone()
            if closed is not None:
                raise UpgradeInProgressError(UPGRADE_MESSAGE)
            yield

    @contextmanager
    def upgrade_transaction(self):
        """Close admissions and serialize one complete runtime upgrade."""
        with exclusive_upgrade_lock(self.path):
            token = str(uuid.uuid4())
            with self.connection() as conn:
                conn.execute("BEGIN IMMEDIATE")
                try:
                    conn.execute(
                        "INSERT INTO operator_meta(key, value) VALUES (?, ?) "
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        (_UPGRADE_META_KEY, token),
                    )
                    conn.execute("COMMIT")
                except Exception:
                    conn.execute("ROLLBACK")
                    raise
            try:
                yield token
            finally:
                with self.connection() as conn:
                    conn.execute("BEGIN IMMEDIATE")
                    try:
                        cleared = conn.execute(
                            "DELETE FROM operator_meta WHERE key = ? AND value = ?",
                            (_UPGRADE_META_KEY, token),
                        ).rowcount
                        if cleared != 1:
                            raise RuntimeError(
                                "Operator upgrade admission ownership was lost"
                            )
                        conn.execute("COMMIT")
                    except Exception:
                        conn.execute("ROLLBACK")
                        raise

    def require_upgrade_idle(self):
        """Prove the canonical database idle while the upgrade barrier is held."""
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                barrier = conn.execute(
                    "SELECT value FROM operator_meta WHERE key = ?",
                    (_UPGRADE_META_KEY,),
                ).fetchone()
                if barrier is None:
                    raise RuntimeError(
                        "Operator upgrade idle check requires an exclusive transaction"
                    )
                counts = conn.execute(
                    """
                    SELECT
                        SUM(CASE WHEN state = 'queued' THEN 1 ELSE 0 END) AS queued,
                        SUM(CASE WHEN state = 'running' THEN 1 ELSE 0 END) AS running
                    FROM tasks
                    """
                ).fetchone()
                claimable = conn.execute(
                    """
                    SELECT COUNT(*) AS count
                    FROM tasks
                    WHERE state = 'queued'
                      AND cancel_requested = 0
                      AND attempt < max_attempts
                      AND NOT EXISTS (
                        SELECT 1
                        FROM task_dependencies d
                        JOIN tasks dependency ON dependency.id = d.depends_on_id
                        WHERE d.task_id = tasks.id
                          AND dependency.state != 'succeeded'
                      )
                    """
                ).fetchone()["count"]
                queued = int(counts["queued"] or 0)
                running = int(counts["running"] or 0)
                if queued or running or claimable:
                    raise RuntimeError(
                        "Operator runtime is not idle while upgrade admission is closed "
                        "(queued=%d running=%d claimable=%d)"
                        % (queued, running, int(claimable))
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return {"queued": 0, "running": 0, "claimable": 0}

    def _enqueue_in_transaction(
        self,
        conn,
        *,
        prompt,
        cwd,
        model,
        effort,
        sandbox,
        priority,
        max_attempts,
        source,
        metadata,
        provider,
        profile,
        isolation,
        verification,
        verification_required,
        dependencies,
        thread_id,
        client_request_id=None,
        client_request_payload=None,
        task_id=None,
        now=None,
    ):
        now = float(now or time.time())
        task_id = task_id or str(uuid.uuid4())
        from .reliability import bind_submission
        metadata, verification, max_attempts, effort = bind_submission(
            conn, cwd, profile, sandbox, metadata, verification, max_attempts, effort
        )
        verification_required = verification_required or bool(
            (metadata.get("reliability") or {}).get("outcomes")
        )
        dependencies = list(dependencies or [])
        for dependency in dependencies:
            if not conn.execute(
                "SELECT 1 FROM tasks WHERE id = ?", (dependency,)
            ).fetchone():
                raise ValueError("dependency task not found: %s" % dependency)
        conn.execute(
            """
            INSERT INTO tasks (
                id, created_at, updated_at, state, priority, prompt, cwd,
                model, effort, sandbox, source, max_attempts, metadata,
                provider, profile, isolation, workspace_key, verification, verification_required,
                verification_status, thread_id, client_request_id, client_request_payload
            ) VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                task_id,
                now,
                now,
                int(priority),
                prompt,
                str(Path(cwd).expanduser().resolve()),
                model,
                effort,
                sandbox,
                source,
                max(1, int(max_attempts)),
                json.dumps(metadata or {}, sort_keys=True),
                provider,
                profile,
                isolation,
                _canonical_workspace_key(cwd),
                json.dumps(verification or []),
                int(bool(verification_required)),
                "pending" if verification else "not_requested",
                thread_id,
                client_request_id,
                client_request_payload,
            ),
        )
        for dependency in dependencies:
            conn.execute(
                """
                INSERT INTO task_dependencies(task_id, depends_on_id, created_at)
                VALUES (?, ?, ?)
                """,
                (task_id, dependency, now),
            )
        self._insert_event(
            conn,
            task_id,
            "task.queued",
            {
                "source": source,
                "priority": priority,
                "provider": provider,
                "profile": profile,
                "dependencies": dependencies,
                "client_request_id": client_request_id,
            },
            created_at=now,
        )
        return task_id

    @staticmethod
    def _reconciled_submission(row, request_payload):
        if row is None:
            return None
        if row["client_request_payload"] != request_payload:
            raise ValueError(
                "client_request_id was already used with a different request"
            )
        return {
            "task_id": row["id"],
            "state": row["state"],
            "profile": row["profile"],
            "client_request_id": row["client_request_id"],
            "duplicate": True,
        }

    def reconcile_submission(
        self,
        prompt,
        cwd,
        model="gpt-5.6-sol",
        effort="high",
        sandbox="workspace-write",
        priority=0,
        max_attempts=2,
        source="cli",
        metadata=None,
        provider="codex",
        profile="sol",
        isolation="shared",
        verification=None,
        verification_required=False,
        dependencies=None,
        thread_id=None,
        client_request_id=None,
        require_idle=False,
    ):
        """Return an exact prior admission without touching volatile runtime state."""
        if not isinstance(require_idle, bool):
            raise ValueError("require_idle must be a boolean")
        client_request_id = _canonical_client_request_id(client_request_id)
        dependencies = list(dependencies or [])
        request_payload = _canonical_submission_request(
            prompt=prompt,
            cwd=cwd,
            model=model,
            effort=effort,
            sandbox=sandbox,
            priority=priority,
            max_attempts=max_attempts,
            source=source,
            metadata=metadata,
            provider=provider,
            profile=profile,
            isolation=isolation,
            verification=verification,
            verification_required=verification_required,
            dependencies=dependencies,
            thread_id=thread_id,
            require_idle=require_idle,
        )
        if client_request_id is None:
            return None
        with self.connection() as conn:
            existing = conn.execute(
                "SELECT * FROM tasks WHERE source = ? AND client_request_id = ?",
                (source, client_request_id),
            ).fetchone()
        return self._reconciled_submission(existing, request_payload)

    def submit(
        self,
        prompt,
        cwd,
        model="gpt-5.6-sol",
        effort="high",
        sandbox="workspace-write",
        priority=0,
        max_attempts=2,
        source="cli",
        metadata=None,
        provider="codex",
        profile="sol",
        isolation="shared",
        verification=None,
        verification_required=False,
        dependencies=None,
        thread_id=None,
        client_request_id=None,
        require_idle=False,
    ):
        with self.admission():
            return self._submit_admitted(
                prompt=prompt,
                cwd=cwd,
                model=model,
                effort=effort,
                sandbox=sandbox,
                priority=priority,
                max_attempts=max_attempts,
                source=source,
                metadata=metadata,
                provider=provider,
                profile=profile,
                isolation=isolation,
                verification=verification,
                verification_required=verification_required,
                dependencies=dependencies,
                thread_id=thread_id,
                client_request_id=client_request_id,
                require_idle=require_idle,
            )

    def _submit_admitted(
        self,
        prompt,
        cwd,
        model="gpt-5.6-sol",
        effort="high",
        sandbox="workspace-write",
        priority=0,
        max_attempts=2,
        source="cli",
        metadata=None,
        provider="codex",
        profile="sol",
        isolation="shared",
        verification=None,
        verification_required=False,
        dependencies=None,
        thread_id=None,
        client_request_id=None,
        require_idle=False,
    ):
        if not isinstance(require_idle, bool):
            raise ValueError("require_idle must be a boolean")
        client_request_id = _canonical_client_request_id(client_request_id)
        dependencies = list(dependencies or [])
        request_payload = _canonical_submission_request(
            prompt=prompt,
            cwd=cwd,
            model=model,
            effort=effort,
            sandbox=sandbox,
            priority=priority,
            max_attempts=max_attempts,
            source=source,
            metadata=metadata,
            provider=provider,
            profile=profile,
            isolation=isolation,
            verification=verification,
            verification_required=verification_required,
            dependencies=dependencies,
            thread_id=thread_id,
            require_idle=require_idle,
        )
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                if client_request_id is not None:
                    existing = conn.execute(
                        "SELECT * FROM tasks WHERE source = ? AND client_request_id = ?",
                        (source, client_request_id),
                    ).fetchone()
                    result = self._reconciled_submission(existing, request_payload)
                    if result is not None:
                        conn.execute("COMMIT")
                        return result

                if require_idle:
                    active = conn.execute(
                        "SELECT id FROM tasks "
                        "WHERE state IN ('queued', 'running') LIMIT 1"
                    ).fetchone()
                    if active is not None:
                        result = {
                            "task_id": None,
                            "state": "busy",
                            "profile": profile,
                            "client_request_id": client_request_id,
                            "duplicate": False,
                        }
                        conn.execute("COMMIT")
                        return result

                task_id = self._enqueue_in_transaction(
                    conn,
                    prompt=prompt,
                    cwd=cwd,
                    model=model,
                    effort=effort,
                    sandbox=sandbox,
                    priority=priority,
                    max_attempts=max_attempts,
                    source=source,
                    metadata=metadata,
                    provider=provider,
                    profile=profile,
                    isolation=isolation,
                    verification=verification,
                    verification_required=verification_required,
                    dependencies=dependencies,
                    thread_id=thread_id,
                    client_request_id=client_request_id,
                    client_request_payload=(
                        request_payload if client_request_id is not None else None
                    ),
                )
                result = {
                    "task_id": task_id,
                    "state": "queued",
                    "profile": profile,
                    "client_request_id": client_request_id,
                    "duplicate": False,
                }
                conn.execute("COMMIT")
                return result
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def enqueue(
        self,
        prompt,
        cwd,
        model="gpt-5.6-sol",
        effort="high",
        sandbox="workspace-write",
        priority=0,
        max_attempts=2,
        source="cli",
        metadata=None,
        provider="codex",
        profile="sol",
        isolation="shared",
        verification=None,
        verification_required=False,
        dependencies=None,
        thread_id=None,
    ):
        return self.submit(
            prompt=prompt,
            cwd=cwd,
            model=model,
            effort=effort,
            sandbox=sandbox,
            priority=priority,
            max_attempts=max_attempts,
            source=source,
            metadata=metadata,
            provider=provider,
            profile=profile,
            isolation=isolation,
            verification=verification,
            verification_required=verification_required,
            dependencies=dependencies,
            thread_id=thread_id,
        )["task_id"]

    def get(self, task_id):
        with self.connection() as conn:
            row = conn.execute(
                "SELECT * FROM tasks WHERE id = ?", (task_id,)
            ).fetchone()
        return self._task(row)

    def list(self, limit=20, state=None):
        sql = "SELECT * FROM tasks"
        args = []
        if state:
            sql += " WHERE state = ?"
            args.append(state)
        sql += " ORDER BY created_at DESC LIMIT ?"
        args.append(int(limit))
        with self.connection() as conn:
            rows = conn.execute(sql, args).fetchall()
        return [self._task(row) for row in rows]

    def claim(self, owner, lease_seconds):
        try:
            with self.admission():
                return self._claim_admitted(owner, lease_seconds)
        except UpgradeInProgressError:
            return None

    def _claim_admitted(self, owner, lease_seconds):
        self.resolve_blocked()
        now = time.time()
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                self._refresh_live_workspace_keys(conn)
                row = conn.execute(
                    """
                    SELECT id FROM tasks
                    WHERE state = 'queued'
                      AND cancel_requested = 0
                      AND attempt < max_attempts
                      AND (
                        tasks.isolation != 'shared'
                        OR NOT EXISTS (
                            SELECT 1 FROM tasks active
                            WHERE active.state = 'running'
                              AND active.isolation = 'shared'
                              AND active.workspace_key = tasks.workspace_key
                        )
                      )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM task_dependencies d
                        JOIN tasks dependency ON dependency.id = d.depends_on_id
                        WHERE d.task_id = tasks.id
                          AND dependency.state != 'succeeded'
                      )
                    ORDER BY priority DESC, created_at ASC
                    LIMIT 1
                    """
                ).fetchone()
                if row is None:
                    conn.execute("COMMIT")
                    return None
                task_id = row["id"]
                conn.execute(
                    """
                    UPDATE tasks
                    SET state = 'running', attempt = attempt + 1,
                        lease_owner = ?, lease_expires_at = ?,
                        lease_generation = lease_generation + 1,
                        started_at = COALESCE(started_at, ?), updated_at = ?, error = NULL,
                        verification_status = CASE
                            WHEN verification != '[]' THEN 'pending'
                            ELSE 'not_requested'
                        END,
                        verified_at = NULL
                    WHERE id = ? AND state = 'queued' AND cancel_requested = 0
                    """,
                    (owner, now + lease_seconds, now, now, task_id),
                )
                row = conn.execute(
                    "SELECT * FROM tasks WHERE id = ?", (task_id,)
                ).fetchone()
                self._insert_event(
                    conn,
                    task_id,
                    "task.started",
                    {
                        "owner": owner,
                        "attempt": row["attempt"],
                        "lease_generation": row["lease_generation"],
                    },
                    created_at=now,
                )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return self._task(row)

    def heartbeat(self, task_id, owner, lease_seconds, generation):
        now = time.time()
        with self.connection() as conn:
            changed = conn.execute(
                """
                UPDATE tasks SET lease_expires_at = ?, updated_at = ?
                WHERE id = ? AND state = 'running' AND lease_owner = ?
                  AND lease_generation = ?
                """,
                (now + lease_seconds, now, task_id, owner, int(generation)),
            ).rowcount
        return changed == 1

    def set_runtime(self, task_id, owner, generation, pid=None, thread_id=None):
        fields = ["updated_at = ?"]
        values = [time.time()]
        if pid is not None:
            fields.append("pid = ?")
            values.append(int(pid))
        if thread_id:
            fields.append("thread_id = ?")
            values.append(thread_id)
        values.extend([task_id, owner, int(generation)])
        with self.connection() as conn:
            changed = conn.execute(
                "UPDATE tasks SET %s WHERE id = ? AND state = 'running' "
                "AND lease_owner = ? AND lease_generation = ?" % ", ".join(fields),
                values,
            ).rowcount
        return changed == 1

    def set_verification(self, task_id, owner, generation, status):
        if status not in ("not_requested", "pending", "passed", "failed"):
            raise ValueError("unsupported verification status: %s" % status)
        now = time.time()
        with self.connection() as conn:
            changed = conn.execute(
                """
                UPDATE tasks SET verification_status = ?,
                    verified_at = CASE WHEN ? IN ('passed', 'failed') THEN ? ELSE NULL END,
                    updated_at = ?
                WHERE id = ? AND state = 'running' AND lease_owner = ?
                  AND lease_generation = ?
                """,
                (
                    status,
                    status,
                    now,
                    now,
                    task_id,
                    owner,
                    int(generation),
                ),
            ).rowcount
        return changed == 1

    def finish(
        self,
        task_id,
        result,
        owner,
        generation,
        terminal_artifact=None,
    ):
        now = time.time()
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                task = conn.execute(
                    """
                    SELECT cancel_requested, verification_required, verification_status
                    FROM tasks
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """,
                    (task_id, owner, int(generation)),
                ).fetchone()
                if task is None:
                    conn.execute("ROLLBACK")
                    return False
                cancelled = bool(task["cancel_requested"]) or bool(result.cancelled)
                verification_missing = bool(task["verification_required"]) and (
                    task["verification_status"] != "passed"
                )
                if cancelled:
                    state = "cancelled"
                elif result.success and verification_missing:
                    state = "failed"
                elif result.success:
                    state = "succeeded"
                else:
                    state = "failed"
                error = result.error
                if verification_missing and not cancelled:
                    error = error or "required verification did not pass"
                if state == "cancelled" and not error:
                    error = "task cancelled"
                changed = conn.execute(
                    """
                    UPDATE tasks SET state = ?, updated_at = ?, finished_at = ?,
                        lease_owner = NULL, lease_expires_at = NULL, pid = NULL,
                        exit_code = ?, final_text = ?, error = ?,
                        thread_id = COALESCE(?, thread_id), input_tokens = ?,
                        cached_input_tokens = ?, output_tokens = ?
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """,
                    (
                        state,
                        now,
                        now,
                        result.exit_code,
                        _text_value(result.final_text),
                        _text_value(error),
                        _text_value(result.thread_id),
                        result.input_tokens,
                        result.cached_input_tokens,
                        result.output_tokens,
                        task_id,
                        owner,
                        int(generation),
                    ),
                ).rowcount
                if changed != 1:
                    conn.execute("ROLLBACK")
                    return False
                payload = result.as_dict()
                payload["lease_generation"] = int(generation)
                payload["cancel_requested"] = bool(task["cancel_requested"])
                self._insert_event(
                    conn, task_id, "task.%s" % state, payload, created_at=now
                )
                if terminal_artifact is not None:
                    expected_state = str(terminal_artifact.get("expected_state") or "")
                    if expected_state != state:
                        raise RuntimeError(
                            "terminal artifact expected task.%s but outcome is task.%s"
                            % (expected_state, state)
                        )
                    kind = str(terminal_artifact.get("kind") or "").strip()
                    path = str(terminal_artifact.get("path") or "").strip()
                    event_type = str(terminal_artifact.get("event_type") or "").strip()
                    if not kind or not path or not event_type:
                        raise ValueError("terminal artifact record is incomplete")
                    metadata = terminal_artifact.get("metadata") or {}
                    if kind != "adaptive-receipt" or event_type != "adaptive.receipt":
                        raise ValueError("unsupported terminal artifact type")
                    if expected_state != "succeeded" or not metadata.get("succeeded"):
                        raise ValueError(
                            "terminal adaptive receipt must certify task success"
                        )
                    if metadata.get("task_id") != task_id or int(
                        metadata.get("lease_generation", -1)
                    ) != int(generation):
                        raise ValueError("terminal artifact attempt identity mismatch")
                    artifact_source = Path(path).expanduser()
                    if artifact_source.is_symlink():
                        raise ValueError("terminal artifact is not a regular file")
                    artifact_path = artifact_source.resolve()
                    attempt_root = (
                        self.path.parent
                        / "tasks"
                        / task_id
                        / ("generation-%08d" % int(generation))
                    ).resolve()
                    if attempt_root not in artifact_path.parents:
                        raise ValueError("terminal artifact is outside its attempt")
                    if not artifact_path.is_file():
                        raise ValueError("terminal artifact is not a regular file")
                    if artifact_path.stat().st_size > 10 * 1024 * 1024:
                        raise ValueError("terminal artifact exceeds size limit")
                    artifact_bytes = artifact_path.read_bytes()
                    file_sha256 = hashlib.sha256(artifact_bytes).hexdigest()
                    if file_sha256 != metadata.get("file_sha256"):
                        raise ValueError("terminal artifact file hash mismatch")
                    try:
                        receipt_payload = json.loads(artifact_bytes)
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        raise ValueError(
                            "terminal adaptive receipt is unreadable"
                        ) from exc
                    receipt_context = receipt_payload.get("context") or {}
                    finalization = receipt_context.get("finalization") or {}
                    receipt_body = dict(receipt_payload)
                    claimed_receipt_sha256 = receipt_body.pop("receipt_sha256", None)
                    computed_receipt_sha256 = hashlib.sha256(
                        json.dumps(
                            receipt_body,
                            sort_keys=True,
                            separators=(",", ":"),
                            ensure_ascii=True,
                            allow_nan=False,
                        ).encode("utf-8")
                    ).hexdigest()
                    computed_outcome_sha256 = hashlib.sha256(
                        json.dumps(
                            result.as_dict(),
                            sort_keys=True,
                            separators=(",", ":"),
                            ensure_ascii=True,
                            allow_nan=False,
                        ).encode("utf-8")
                    ).hexdigest()
                    if (
                        receipt_payload.get("schema")
                        != "black-label-operator/adaptive-execution-v1"
                        or claimed_receipt_sha256 != metadata.get("receipt_sha256")
                        or computed_receipt_sha256 != claimed_receipt_sha256
                        or not receipt_payload.get("succeeded")
                        or receipt_context.get("task_id") != task_id
                        or receipt_context.get("process_containment")
                        != "macos-launchd-resource-coalition-v1"
                        or int(receipt_context.get("lease_generation", -1))
                        != int(generation)
                        or finalization.get("phase") != "final"
                        or finalization.get("task_outcome") != "succeeded"
                        or not _valid_sha256(finalization.get("task_outcome_sha256"))
                        or finalization.get("task_outcome_sha256")
                        != computed_outcome_sha256
                        or not _valid_sha256(
                            finalization.get("workspace_manifest_sha256")
                        )
                        or not _valid_sha256(
                            finalization.get("verified_source_identity")
                        )
                        or not _valid_sha256(
                            finalization.get("collected_source_identity")
                        )
                        or not _valid_sha256(
                            finalization.get("collected_content_identity")
                        )
                        or finalization.get("source_identity_match") is not True
                        or finalization.get("verified_source_identity")
                        != finalization.get("collected_source_identity")
                        or getattr(result, "containment_proven", False) is not True
                    ):
                        raise ValueError("terminal adaptive receipt contract mismatch")
                    rounds = receipt_payload.get("rounds")
                    if not isinstance(rounds, list) or not rounds:
                        raise ValueError(
                            "terminal adaptive receipt has no verification evidence"
                        )
                    verified_logs = 0
                    accepted_required = 0
                    accepted_verified_logs = 0
                    for round_payload in rounds:
                        if not isinstance(round_payload, dict):
                            raise ValueError(
                                "terminal adaptive receipt round is malformed"
                            )
                        try:
                            round_index = int(round_payload.get("round_index"))
                        except (TypeError, ValueError) as exc:
                            raise ValueError(
                                "terminal adaptive receipt round is malformed"
                            ) from exc
                        verification = round_payload.get("verification")
                        if verification is None:
                            continue
                        if not isinstance(verification, dict) or not isinstance(
                            verification.get("evidence"), list
                        ):
                            raise ValueError(
                                "terminal adaptive receipt verification is malformed"
                            )
                        is_accepted_round = round_payload is rounds[-1]
                        for evidence in verification["evidence"]:
                            if not isinstance(evidence, dict):
                                raise ValueError(
                                    "terminal adaptive receipt evidence is malformed"
                                )
                            if (
                                evidence.get("kind") != "verification-command"
                                or evidence.get("required") is not True
                            ):
                                continue
                            if is_accepted_round:
                                accepted_required += 1
                                if evidence.get("passed") is not True:
                                    raise ValueError(
                                        "terminal adaptive receipt accepted failed evidence"
                                    )
                            digest = evidence.get("artifact_sha256")
                            details = evidence.get("metadata") or {}
                            # A failed synthetic source-fence entry has no log.
                            # A passing command can never be accepted without one.
                            if digest is None and evidence.get("passed") is False:
                                continue
                            if not _valid_sha256(digest) or not isinstance(
                                details, dict
                            ):
                                raise ValueError(
                                    "terminal adaptive receipt verifier log is unbound"
                                )
                            artifact_kind = details.get("artifact_kind")
                            artifact_source = details.get("artifact_path")
                            stage_task_id = details.get("adaptive_stage_task_id")
                            if (
                                artifact_kind
                                != "adaptive-verifier-verification-log"
                                or not isinstance(artifact_source, str)
                                or not artifact_source
                                or not isinstance(stage_task_id, str)
                                or not stage_task_id
                                or int(details.get("lease_generation", -1))
                                != int(generation)
                                or details.get("containment_proven") is not True
                            ):
                                raise ValueError(
                                    "terminal adaptive receipt verifier log identity mismatch"
                                )
                            raw_log = Path(artifact_source).expanduser()
                            if raw_log.is_symlink():
                                raise ValueError(
                                    "terminal adaptive receipt verifier log is untrusted"
                                )
                            log_path = raw_log.resolve()
                            expected_log_root = (
                                attempt_root
                                / "adaptive"
                                / ("round-%02d" % round_index)
                                / "verifier"
                                / "verification"
                            )
                            if (
                                log_path.parent != expected_log_root
                                or log_path.suffix != ".log"
                            ):
                                raise ValueError(
                                    "terminal adaptive receipt verifier log is outside its stage"
                                )
                            artifact_row = conn.execute(
                                """
                                SELECT path, metadata FROM artifacts
                                WHERE task_id = ? AND kind = ? AND path = ?
                                """,
                                (task_id, artifact_kind, str(log_path)),
                            ).fetchone()
                            if artifact_row is None:
                                raise ValueError(
                                    "terminal adaptive receipt verifier log is unregistered"
                                )
                            try:
                                artifact_metadata = json.loads(
                                    artifact_row["metadata"] or "{}"
                                )
                            except json.JSONDecodeError as exc:
                                raise ValueError(
                                    "terminal adaptive receipt verifier artifact is malformed"
                                ) from exc
                            if (
                                artifact_metadata.get("sha256") != digest
                                or artifact_metadata.get("adaptive_stage") != "verifier"
                                or int(
                                    artifact_metadata.get("adaptive_round", -1)
                                )
                                != round_index
                                or artifact_metadata.get("adaptive_stage_task_id")
                                != stage_task_id
                                or int(
                                    artifact_metadata.get("lease_generation", -1)
                                )
                                != int(generation)
                            ):
                                raise ValueError(
                                    "terminal adaptive receipt verifier artifact mismatch"
                                )
                            checked_path, checked_stat, checked_bytes = (
                                _read_bound_regular_file(
                                    log_path,
                                    maximum_bytes=10 * 1024 * 1024,
                                )
                            )
                            if (
                                checked_path != log_path
                                or stat.S_IMODE(checked_stat.st_mode) != 0o400
                                or int(artifact_metadata.get("bytes", -1))
                                != len(checked_bytes)
                                or int(details.get("artifact_bytes", -1))
                                != len(checked_bytes)
                                or hashlib.sha256(checked_bytes).hexdigest() != digest
                            ):
                                raise ValueError(
                                    "terminal adaptive receipt verifier log hash mismatch"
                                )
                            verified_logs += 1
                            if is_accepted_round:
                                accepted_verified_logs += 1
                    if (
                        accepted_required < 1
                        or accepted_verified_logs != accepted_required
                        or verified_logs < accepted_verified_logs
                    ):
                        raise ValueError(
                            "terminal adaptive receipt lacks sealed verifier logs"
                        )
                    manifest_rows = conn.execute(
                        """
                        SELECT path, metadata FROM artifacts
                        WHERE task_id = ? AND kind = 'workspace-manifest'
                        ORDER BY id DESC
                        """,
                        (task_id,),
                    ).fetchall()
                    matched_manifest = None
                    for manifest_row in manifest_rows:
                        manifest_metadata = json.loads(manifest_row["metadata"] or "{}")
                        if (
                            manifest_metadata.get("sha256")
                            == finalization.get("workspace_manifest_sha256")
                            and int(manifest_metadata.get("lease_generation", -1))
                            == int(generation)
                        ):
                            matched_manifest = (manifest_row, manifest_metadata)
                            break
                    if matched_manifest is None:
                        raise ValueError(
                            "terminal adaptive receipt workspace manifest is untrusted"
                        )
                    manifest_row, manifest_metadata = matched_manifest
                    if (
                        manifest_metadata.get("collection_mode")
                        != "isolated-verifier-snapshot"
                        or manifest_metadata.get("collected_source_identity")
                        != finalization.get("collected_source_identity")
                        or manifest_metadata.get("content_identity")
                        != finalization.get("collected_content_identity")
                    ):
                        raise ValueError(
                            "terminal adaptive receipt workspace identity mismatch"
                        )
                    manifest_path = Path(manifest_row["path"]).expanduser()
                    if manifest_path.is_symlink():
                        raise ValueError("workspace manifest is not a regular file")
                    manifest_path = manifest_path.resolve()
                    expected_manifest_root = attempt_root / "workspace"
                    if (
                        manifest_path.parent != expected_manifest_root
                        or not manifest_path.is_file()
                        or hashlib.sha256(manifest_path.read_bytes()).hexdigest()
                        != finalization.get("workspace_manifest_sha256")
                    ):
                        raise ValueError("workspace manifest file identity mismatch")
                    event_payload = terminal_artifact.get("event_payload") or {}
                    if any(
                        event_payload.get(field) != metadata.get(field)
                        for field in (
                            "receipt_sha256",
                            "file_sha256",
                            "succeeded",
                            "finalization",
                            "task_id",
                            "lease_generation",
                        )
                    ):
                        raise ValueError("terminal adaptive receipt event mismatch")
                    conn.execute(
                        """
                        INSERT INTO artifacts(
                            task_id, created_at, kind, path, metadata
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            task_id,
                            now,
                            kind,
                            str(artifact_path),
                            json.dumps(
                                metadata,
                                sort_keys=True,
                            ),
                        ),
                    )
                    self._insert_event(
                        conn,
                        task_id,
                        event_type,
                        event_payload,
                        created_at=now,
                    )
                conn.execute("COMMIT")
                return state
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def retry_or_fail(
        self,
        task_id,
        error,
        exit_code,
        owner,
        generation,
        lease_expired_before=None,
    ):
        now = time.time()
        expiry_guard, expiry_values = _lease_expiry_guard(lease_expired_before)
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                task = conn.execute(
                    """
                    SELECT attempt, max_attempts, cancel_requested FROM tasks
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """
                    + expiry_guard,
                    (task_id, owner, int(generation)) + expiry_values,
                ).fetchone()
                if not task:
                    conn.execute("ROLLBACK")
                    return "stale"
                if task["cancel_requested"]:
                    next_state = "cancelled"
                elif task["attempt"] < task["max_attempts"]:
                    next_state = "queued"
                else:
                    next_state = "failed"
                changed = conn.execute(
                    """
                    UPDATE tasks SET state = ?, updated_at = ?,
                        finished_at = CASE WHEN ? IN ('failed', 'cancelled') THEN ? ELSE NULL END,
                        lease_owner = NULL, lease_expires_at = NULL, pid = NULL,
                        exit_code = ?, error = ?
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """
                    + expiry_guard,
                    (
                        next_state,
                        now,
                        next_state,
                        now,
                        exit_code,
                        _text_value(error),
                        task_id,
                        owner,
                        int(generation),
                    )
                    + expiry_values,
                ).rowcount
                if changed != 1:
                    conn.execute("ROLLBACK")
                    return "stale"
                self._insert_event(
                    conn,
                    task_id,
                    "task.%s" % next_state,
                    {
                        "error": error,
                        "owner": owner,
                        "lease_generation": int(generation),
                    },
                    created_at=now,
                )
                conn.execute("COMMIT")
                return next_state
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def quarantine(
        self,
        task_id,
        error,
        owner,
        generation,
        pid=None,
        lease_expired_before=None,
    ):
        """Fail closed while retaining a PID that may still be alive."""
        now = time.time()
        expiry_guard, expiry_values = _lease_expiry_guard(lease_expired_before)
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                row = conn.execute(
                    """
                    SELECT metadata, pid FROM tasks
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """
                    + expiry_guard,
                    (task_id, owner, int(generation)) + expiry_values,
                ).fetchone()
                if row is None:
                    conn.execute("ROLLBACK")
                    return False
                try:
                    metadata = json.loads(row["metadata"] or "{}")
                except json.JSONDecodeError:
                    metadata = {}
                retained_pid = int(pid or row["pid"] or 0) or None
                metadata.update(
                    {
                        "quarantined": True,
                        "quarantine_reason": _text_value(error),
                        "quarantined_at": now,
                        "possibly_live_pid": retained_pid,
                    }
                )
                changed = conn.execute(
                    """
                    UPDATE tasks SET state = 'blocked', updated_at = ?, finished_at = ?,
                        lease_owner = NULL, lease_expires_at = NULL,
                        pid = COALESCE(?, pid), exit_code = NULL, error = ?, metadata = ?
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """
                    + expiry_guard,
                    (
                        now,
                        now,
                        retained_pid,
                        _text_value(error),
                        json.dumps(metadata, sort_keys=True),
                        task_id,
                        owner,
                        int(generation),
                    )
                    + expiry_values,
                ).rowcount
                if changed != 1:
                    conn.execute("ROLLBACK")
                    return False
                self._insert_event(
                    conn,
                    task_id,
                    "task.quarantined",
                    {
                        "error": _text_value(error),
                        "pid": retained_pid,
                        "lease_generation": int(generation),
                    },
                    created_at=now,
                )
                conn.execute("COMMIT")
                return "blocked"
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def request_cancel(self, task_id):
        now = time.time()
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                task = conn.execute(
                    "SELECT state FROM tasks WHERE id = ?", (task_id,)
                ).fetchone()
                if task is None or task["state"] not in ("queued", "running"):
                    conn.execute("ROLLBACK")
                    return False
                if task["state"] == "queued":
                    conn.execute(
                        """
                        UPDATE tasks SET state = 'cancelled', cancel_requested = 1,
                            updated_at = ?, finished_at = ?
                        WHERE id = ? AND state = 'queued'
                        """,
                        (now, now, task_id),
                    )
                else:
                    conn.execute(
                        """
                        UPDATE tasks SET cancel_requested = 1, updated_at = ?
                        WHERE id = ? AND state = 'running'
                        """,
                        (now, task_id),
                    )
                self._insert_event(
                    conn, task_id, "task.cancel_requested", {}, created_at=now
                )
                if task["state"] == "queued":
                    self._insert_event(
                        conn,
                        task_id,
                        "task.cancelled",
                        {"error": "cancelled before execution"},
                        created_at=now,
                    )
                conn.execute("COMMIT")
                return True
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def expired_running(self, expired_before=None):
        expired_before = (
            time.time() if expired_before is None else float(expired_before)
        )
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT * FROM tasks
                WHERE state = 'running'
                  AND (lease_expires_at IS NULL OR lease_expires_at < ?)
                ORDER BY created_at ASC
                """,
                (expired_before,),
            ).fetchall()
        return [self._task(row) for row in rows]

    def running(self):
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT * FROM tasks WHERE state = 'running' ORDER BY created_at ASC"
            ).fetchall()
        return [self._task(row) for row in rows]

    def adopt(self, task_id, owner, lease_seconds, only_if_expired=True):
        now = time.time()
        expiry_guard = (
            " AND (lease_expires_at IS NULL OR lease_expires_at < ?)"
            if only_if_expired
            else ""
        )
        values = [owner, now + lease_seconds, now, task_id]
        if only_if_expired:
            values.append(now)
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                changed = conn.execute(
                    """
                    UPDATE tasks SET lease_owner = ?, lease_expires_at = ?,
                        updated_at = ?, lease_generation = lease_generation + 1
                    WHERE id = ? AND state = 'running'
                    """
                    + expiry_guard,
                    values,
                ).rowcount
                if changed:
                    row = conn.execute(
                        "SELECT lease_generation FROM tasks WHERE id = ?", (task_id,)
                    ).fetchone()
                    self._insert_event(
                        conn,
                        task_id,
                        "task.adopted",
                        {
                            "owner": owner,
                            "lease_generation": row["lease_generation"],
                        },
                        created_at=now,
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return changed == 1

    def recover_dead(
        self,
        task,
        reason="worker lease expired",
        lease_expired_before=None,
    ):
        return self.retry_or_fail(
            task["id"],
            reason,
            None,
            task["lease_owner"],
            task["lease_generation"],
            lease_expired_before=lease_expired_before,
        )

    def fail_interrupted(
        self,
        task,
        reason="interrupted provider cannot resume",
        lease_expired_before=None,
    ):
        now = time.time()
        expiry_guard, expiry_values = _lease_expiry_guard(lease_expired_before)
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                changed = conn.execute(
                    """
                    UPDATE tasks SET state = 'failed', updated_at = ?, finished_at = ?,
                        lease_owner = NULL, lease_expires_at = NULL, pid = NULL, error = ?
                    WHERE id = ? AND state = 'running' AND lease_owner = ?
                      AND lease_generation = ?
                    """
                    + expiry_guard,
                    (
                        now,
                        now,
                        reason,
                        task["id"],
                        task["lease_owner"],
                        task["lease_generation"],
                    )
                    + expiry_values,
                ).rowcount
                if changed:
                    self._insert_event(
                        conn,
                        task["id"],
                        "task.failed",
                        {
                            "error": reason,
                            "lease_generation": task["lease_generation"],
                        },
                        created_at=now,
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return changed == 1

    def resolve_blocked(self):
        now = time.time()
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute(
                    """
                    SELECT DISTINCT task.id
                    FROM tasks task
                    JOIN task_dependencies d ON d.task_id = task.id
                    JOIN tasks dependency ON dependency.id = d.depends_on_id
                    WHERE task.state = 'queued'
                      AND dependency.state IN ('failed', 'cancelled', 'blocked')
                    """
                ).fetchall()
                task_ids = [row["id"] for row in rows]
                for task_id in task_ids:
                    changed = conn.execute(
                        """
                        UPDATE tasks SET state = 'blocked', updated_at = ?, finished_at = ?,
                            error = 'dependency did not succeed'
                        WHERE id = ? AND state = 'queued'
                        """,
                        (now, now, task_id),
                    ).rowcount
                    if changed:
                        self._insert_event(
                            conn,
                            task_id,
                            "task.blocked",
                            {"error": "dependency did not succeed"},
                            created_at=now,
                        )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return task_ids

    def dependencies(self, task_id):
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT task.* FROM tasks task
                JOIN task_dependencies d ON d.depends_on_id = task.id
                WHERE d.task_id = ? ORDER BY d.created_at ASC
                """,
                (task_id,),
            ).fetchall()
        return [self._task(row) for row in rows]

    def dependents(self, task_id):
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT task.* FROM tasks task
                JOIN task_dependencies d ON d.task_id = task.id
                WHERE d.depends_on_id = ? ORDER BY d.created_at ASC
                """,
                (task_id,),
            ).fetchall()
        return [self._task(row) for row in rows]

    def graph(self, task_id):
        task = self.get(task_id)
        if not task:
            return None
        return {
            "task": task,
            "dependencies": self.dependencies(task_id),
            "dependents": self.dependents(task_id),
        }

    @staticmethod
    def _attempt_owned(conn, task_id, owner, generation):
        return (
            conn.execute(
                """
            SELECT 1 FROM tasks
            WHERE id = ? AND state = 'running' AND lease_owner = ?
              AND lease_generation = ?
            """,
                (task_id, owner, int(generation)),
            ).fetchone()
            is not None
        )

    def owns_attempt(self, task_id, owner, generation):
        with self.connection() as conn:
            return self._attempt_owned(conn, task_id, owner, generation)

    def for_attempt(self, task_id, owner, generation):
        return AttemptStore(self, task_id, owner, generation)

    def update_metadata(self, task_id, values, owner=None, generation=None):
        now = time.time()
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                if owner is not None and not self._attempt_owned(
                    conn, task_id, owner, generation
                ):
                    conn.execute("ROLLBACK")
                    return False
                row = conn.execute(
                    "SELECT metadata FROM tasks WHERE id = ?", (task_id,)
                ).fetchone()
                if not row:
                    conn.execute("ROLLBACK")
                    return False
                try:
                    metadata = json.loads(row["metadata"] or "{}")
                except json.JSONDecodeError:
                    metadata = {}
                metadata.update(values)
                guard = ""
                args = [json.dumps(metadata, sort_keys=True), now, task_id]
                if owner is not None:
                    guard = (
                        " AND state = 'running' AND lease_owner = ? "
                        "AND lease_generation = ?"
                    )
                    args.extend([owner, int(generation)])
                changed = conn.execute(
                    "UPDATE tasks SET metadata = ?, updated_at = ? WHERE id = ?"
                    + guard,
                    args,
                ).rowcount
                conn.execute("COMMIT")
                return changed == 1
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def add_artifact(
        self, task_id, kind, path, metadata=None, owner=None, generation=None
    ):
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                if owner is not None and not self._attempt_owned(
                    conn, task_id, owner, generation
                ):
                    conn.execute("ROLLBACK")
                    return False
                conn.execute(
                    """
                    INSERT OR REPLACE INTO artifacts(task_id, created_at, kind, path, metadata)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        task_id,
                        time.time(),
                        kind,
                        str(Path(path).expanduser().resolve()),
                        json.dumps(metadata or {}, sort_keys=True),
                    ),
                )
                conn.execute("COMMIT")
                return True
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def artifacts(self, task_id):
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT id, task_id, created_at, kind, path, metadata
                FROM artifacts WHERE task_id = ? ORDER BY id ASC
                """,
                (task_id,),
            ).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            try:
                item["metadata"] = json.loads(item["metadata"] or "{}")
            except json.JSONDecodeError:
                item["metadata"] = {}
            result.append(item)
        return result

    @staticmethod
    def _schedule(row):
        if row is None:
            return None
        item = dict(row)
        for field, fallback in (("verification", []), ("metadata", {})):
            try:
                item[field] = json.loads(item.get(field) or json.dumps(fallback))
            except json.JSONDecodeError:
                item[field] = fallback
        item["enabled"] = bool(item["enabled"])
        item["delete_after_run"] = bool(item["delete_after_run"])
        item["verification_required"] = bool(item.get("verification_required"))
        return item

    def add_schedule(
        self,
        name,
        prompt,
        cwd,
        provider,
        model,
        profile,
        effort,
        sandbox,
        isolation,
        next_run_at,
        interval_seconds=None,
        delete_after_run=False,
        priority=0,
        max_attempts=1,
        verification=None,
        verification_required=False,
        metadata=None,
    ):
        schedule_id = str(uuid.uuid4())
        now = time.time()
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO schedules(
                    id, created_at, updated_at, name, prompt, cwd, provider,
                    model, profile, effort, sandbox, isolation, priority,
                    max_attempts, verification, verification_required,
                    interval_seconds, next_run_at,
                    delete_after_run, metadata
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    schedule_id,
                    now,
                    now,
                    name,
                    prompt,
                    str(Path(cwd).expanduser().resolve()),
                    provider,
                    model,
                    profile,
                    effort,
                    sandbox,
                    isolation,
                    int(priority),
                    max(1, int(max_attempts)),
                    json.dumps(verification or []),
                    int(bool(verification_required)),
                    float(interval_seconds) if interval_seconds else None,
                    float(next_run_at),
                    int(bool(delete_after_run)),
                    json.dumps(metadata or {}, sort_keys=True),
                ),
            )
        return schedule_id

    def list_schedules(self, include_disabled=True):
        sql = "SELECT * FROM schedules"
        if not include_disabled:
            sql += " WHERE enabled = 1"
        sql += " ORDER BY next_run_at ASC"
        with self.connection() as conn:
            rows = conn.execute(sql).fetchall()
        return [self._schedule(row) for row in rows]

    def get_schedule(self, schedule_id):
        with self.connection() as conn:
            row = conn.execute(
                "SELECT * FROM schedules WHERE id = ?", (schedule_id,)
            ).fetchone()
        return self._schedule(row)

    def set_schedule_enabled(self, schedule_id, enabled):
        with self.connection() as conn:
            changed = conn.execute(
                "UPDATE schedules SET enabled = ?, updated_at = ? WHERE id = ?",
                (int(bool(enabled)), time.time(), schedule_id),
            ).rowcount
        return changed == 1

    def remove_schedule(self, schedule_id):
        with self.connection() as conn:
            changed = conn.execute(
                "DELETE FROM schedules WHERE id = ?", (schedule_id,)
            ).rowcount
        return changed == 1

    def fire_due_schedules(self, now=None):
        try:
            with self.admission():
                return self._fire_due_schedules_admitted(now=now)
        except UpgradeInProgressError:
            return []

    def _fire_due_schedules_admitted(self, now=None):
        now = float(now or time.time())
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute(
                    """
                    SELECT * FROM schedules
                    WHERE enabled = 1 AND next_run_at <= ?
                    ORDER BY next_run_at ASC
                    """,
                    (now,),
                ).fetchall()
                schedules = [self._schedule(row) for row in rows]
                fired = []
                for schedule in schedules:
                    due_at = float(schedule["next_run_at"])
                    task_id = self._enqueue_in_transaction(
                        conn,
                        prompt=schedule["prompt"],
                        cwd=schedule["cwd"],
                        model=schedule["model"],
                        effort=schedule["effort"],
                        sandbox=schedule["sandbox"],
                        priority=schedule["priority"],
                        max_attempts=schedule["max_attempts"],
                        source="schedule:%s" % schedule["id"],
                        metadata=dict(
                            schedule.get("metadata") or {},
                            schedule_id=schedule["id"],
                            schedule_due_at=due_at,
                        ),
                        provider=schedule["provider"],
                        profile=schedule["profile"],
                        isolation=schedule["isolation"],
                        verification=schedule["verification"],
                        verification_required=schedule["verification_required"],
                        dependencies=[],
                        thread_id=None,
                        now=now,
                    )
                    self._insert_event(
                        conn,
                        task_id,
                        "schedule.fired",
                        {"schedule_id": schedule["id"], "due_at": due_at},
                        created_at=now,
                    )
                    interval = schedule.get("interval_seconds")
                    if interval:
                        next_run = max(now, due_at) + float(interval)
                        enabled = 1
                    else:
                        next_run = due_at
                        enabled = 0
                    conn.execute(
                        """
                        UPDATE schedules SET updated_at = ?, enabled = ?,
                            next_run_at = ?, last_run_at = ?, last_task_id = ?
                        WHERE id = ? AND enabled = 1 AND next_run_at = ?
                        """,
                        (
                            now,
                            enabled,
                            next_run,
                            now,
                            task_id,
                            schedule["id"],
                            due_at,
                        ),
                    )
                    if schedule["delete_after_run"]:
                        conn.execute(
                            "DELETE FROM schedules WHERE id = ?", (schedule["id"],)
                        )
                    fired.append({"schedule_id": schedule["id"], "task_id": task_id})
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return fired

    def add_event(self, task_id, event_type, payload, owner=None, generation=None):
        with self.connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                if owner is not None and not self._attempt_owned(
                    conn, task_id, owner, generation
                ):
                    conn.execute("ROLLBACK")
                    return False
                self._insert_event(conn, task_id, event_type, payload)
                conn.execute("COMMIT")
                return True
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def events(self, task_id, after=0, limit=1000):
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT seq, created_at, event_type, payload FROM events
                WHERE task_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?
                """,
                (task_id, int(after), int(limit)),
            ).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            try:
                item["payload"] = json.loads(item["payload"])
            except json.JSONDecodeError:
                pass
            result.append(item)
        return result

    def register_client(self, token, cwd, ttl_seconds=86400, label="operator-client"):
        now = time.time()
        with self.connection() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO clients(token, cwd, created_at, expires_at, label)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    token,
                    str(Path(cwd).expanduser().resolve()),
                    now,
                    now + ttl_seconds,
                    label,
                ),
            )

    def resolve_client(self, token):
        now = time.time()
        with self.connection() as conn:
            conn.execute("DELETE FROM clients WHERE expires_at < ?", (now,))
            row = conn.execute(
                "SELECT cwd, label, expires_at FROM clients WHERE token = ? AND expires_at >= ?",
                (token, now),
            ).fetchone()
        return dict(row) if row else None

    def counts(self):
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT state, COUNT(*) AS count FROM tasks GROUP BY state"
            ).fetchall()
        counts = {state: 0 for state in ("queued", "running") + TERMINAL_STATES}
        counts.update({row["state"]: row["count"] for row in rows})
        return counts

    def runtime_metrics(self, now=None):
        now = float(now or time.time())
        with self.connection() as conn:
            row = conn.execute(
                """
                SELECT
                    SUM(CASE WHEN state = 'queued' THEN 1 ELSE 0 END) AS queued,
                    SUM(CASE WHEN state = 'running' THEN 1 ELSE 0 END) AS running,
                    SUM(CASE WHEN state = 'running' AND
                        (lease_expires_at IS NULL OR lease_expires_at < ?)
                        THEN 1 ELSE 0 END) AS expired_running,
                    MIN(CASE WHEN state = 'queued' THEN created_at END) AS oldest_queued_at,
                    MAX(CASE WHEN state IN ('succeeded', 'failed', 'cancelled', 'blocked')
                        THEN finished_at END) AS last_completion_at
                FROM tasks
                """,
                (now,),
            ).fetchone()
            claimable = conn.execute(
                """
                SELECT COUNT(*) AS count, MIN(tasks.created_at) AS oldest_at
                FROM tasks
                WHERE state = 'queued' AND cancel_requested = 0
                  AND attempt < max_attempts
                  AND (
                    tasks.isolation != 'shared'
                    OR NOT EXISTS (
                        SELECT 1 FROM tasks active
                        WHERE active.state = 'running'
                          AND active.isolation = 'shared'
                          AND active.workspace_key = tasks.workspace_key
                    )
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM task_dependencies d
                    JOIN tasks dependency ON dependency.id = d.depends_on_id
                    WHERE d.task_id = tasks.id
                      AND dependency.state != 'succeeded'
                  )
                """
            ).fetchone()
        oldest_queued_at = row["oldest_queued_at"]
        oldest_claimable_at = claimable["oldest_at"]
        return {
            "queued": int(row["queued"] or 0),
            "running": int(row["running"] or 0),
            "expired_running": int(row["expired_running"] or 0),
            "claimable": int(claimable["count"] or 0),
            "oldest_queued_age_seconds": (
                round(max(0.0, now - oldest_queued_at), 3)
                if oldest_queued_at is not None
                else None
            ),
            "oldest_claimable_age_seconds": (
                round(max(0.0, now - oldest_claimable_at), 3)
                if oldest_claimable_at is not None
                else None
            ),
            "last_completion_at": row["last_completion_at"],
        }


class AttemptStore:
    """Store view that generation-fences every attempt-owned mutation."""

    def __init__(self, store, task_id, owner, generation):
        self._store = store
        self.task_id = task_id
        self.owner = owner
        self.generation = int(generation)

    def _check_task(self, task_id):
        if task_id != self.task_id:
            raise LeaseOwnershipError(
                "attempt store for %s cannot mutate %s" % (self.task_id, task_id)
            )

    @staticmethod
    def _required(changed):
        if not changed:
            raise LeaseOwnershipError("task lease ownership was lost")
        return changed

    def attempt_path(self, base, *parts):
        """Resolve a path isolated to this lease generation without creating it."""
        base = Path(base).expanduser().resolve()
        task_part = Path(self.task_id)
        if task_part.is_absolute() or len(task_part.parts) != 1:
            raise ValueError("task id is not a safe path component")
        root = (base / self.task_id / ("generation-%08d" % self.generation)).resolve()
        if root != base and base not in root.parents:
            raise ValueError("attempt path escapes its base directory")
        candidate = root
        for part in parts:
            item = Path(part)
            if item.is_absolute():
                raise ValueError("attempt path parts must be relative")
            candidate /= item
        candidate = candidate.resolve()
        if candidate != root and root not in candidate.parents:
            raise ValueError("attempt path escapes its generation directory")
        return candidate

    def get(self, task_id):
        self._check_task(task_id)
        return self._store.get(task_id)

    def artifacts(self, task_id):
        self._check_task(task_id)
        return self._store.artifacts(task_id)

    def update_metadata(self, task_id, values):
        self._check_task(task_id)
        return self._required(
            self._store.update_metadata(
                task_id,
                values,
                owner=self.owner,
                generation=self.generation,
            )
        )

    def add_artifact(self, task_id, kind, path, metadata=None):
        self._check_task(task_id)
        return self._required(
            self._store.add_artifact(
                task_id,
                kind,
                path,
                metadata,
                owner=self.owner,
                generation=self.generation,
            )
        )

    def add_event(self, task_id, event_type, payload):
        self._check_task(task_id)
        return self._required(
            self._store.add_event(
                task_id,
                event_type,
                payload,
                owner=self.owner,
                generation=self.generation,
            )
        )
