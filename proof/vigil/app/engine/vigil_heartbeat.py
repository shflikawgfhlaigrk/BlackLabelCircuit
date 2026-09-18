"""Runtime heartbeat for the shipped Vigil sidecar.

The pact crypto/transport layer already exists in ``vigil.mesh.pact``. This
module is the missing runtime glue: the app calls ``PactChannel.send_heartbeat``
on startup and then once per UTC day, persists proof in ``~/.vigil/heartbeat.json``,
and exposes that status through the sidecar.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

import vigil_paths
from vigil.mesh.pact import FileDropTransport, Pact, PactChannel, PactIdentity, generate_identity


class VigilHeartbeat:
    """Daily pact heartbeat with local proof when no peer is configured yet."""

    def __init__(self, root: str | Path | None = None, now_fn=time.time,
                 interval_s: float = 24 * 3600) -> None:
        # Engine.__init__ constructs this with no root on EVERY sidecar start, and it WRITES
        # (pact identity, outbox, heartbeat.json). A bare "~/.vigil" default escaped
        # VIGIL_HOME and put those writes in the owner's real home; route the default through
        # vigil_paths. An explicit root still wins, so injection in tests is unchanged.
        self.root = Path(root).expanduser() if root else Path(vigil_paths.base())
        self.now_fn = now_fn
        self.interval_s = float(interval_s)
        self.identity_path = self.root / "pact_identity.json"
        self.peer_path = self.root / "pact_peer.hex"
        self.outbox = self.root / "pact_outbox"
        self.status_path = self.root / "heartbeat.json"

    def status(self) -> dict:
        try:
            return json.loads(self.status_path.read_text(encoding="utf-8"))
        except Exception:
            return {
                "ok": False,
                "sent": False,
                "paired": False,
                "detail": "no heartbeat sent yet",
                "status_path": str(self.status_path),
            }

    def tick(self, normal: bool = True, force: bool = False) -> dict:
        """Send if needed. Returns a persisted, JSON-serializable status."""
        now = float(self.now_fn())
        day = self._day(now)
        prior = self.status()
        if (not force
                and prior.get("ok") is True
                and prior.get("last_day") == day
                and now - float(prior.get("last_attempt_ts") or 0.0) < self.interval_s):
            return {**prior, "sent": False, "detail": "heartbeat already sent for UTC day"}

        try:
            self.root.mkdir(parents=True, exist_ok=True)
            os.chmod(self.root, 0o700)
        except OSError:
            pass

        try:
            identity = self._identity()
            peer_pubkey, paired = self._peer_pubkey(identity)
            transport = FileDropTransport(self.outbox, me="home", peer=("peer" if paired else "self"))
            channel = PactChannel(Pact(identity, peer_pubkey, now_fn=self.now_fn), transport)
            before = set(self.outbox.glob("*.pact"))
            channel.send_heartbeat(normal=normal, day=day)
            after = sorted(set(self.outbox.glob("*.pact")) - before,
                           key=lambda p: p.stat().st_mtime)
            path = str(after[-1]) if after else None
            status = {
                "ok": True,
                "sent": True,
                "paired": paired,
                "last_day": day,
                "last_attempt_ts": now,
                "last_success_ts": now,
                "normal": bool(normal),
                "call": "PactChannel.send_heartbeat",
                "transport": "filedrop",
                "outbox": str(self.outbox),
                "envelope": path,
                "status_path": str(self.status_path),
                "detail": "heartbeat sent" if paired else "local heartbeat proof sent; add pact_peer.hex to pair a remote home",
            }
        except Exception as exc:  # noqa: BLE001 - status must survive any transport issue
            status = {
                "ok": False,
                "sent": False,
                "paired": False,
                "last_day": day,
                "last_attempt_ts": now,
                "normal": bool(normal),
                "call": "PactChannel.send_heartbeat",
                "status_path": str(self.status_path),
                "detail": str(exc),
            }
        self._write_status(status)
        return status

    def _identity(self) -> PactIdentity:
        if self.identity_path.exists():
            return PactIdentity.load(self.identity_path)
        identity = generate_identity(force_stdlib=True)
        identity.save(self.identity_path)
        return identity

    def _peer_pubkey(self, identity: PactIdentity) -> tuple[bytes, bool]:
        try:
            raw = self.peer_path.read_text(encoding="utf-8").strip()
            peer = bytes.fromhex(raw)
            if len(peer) == 32:
                return peer, True
        except Exception:
            pass
        return identity.public, False

    def _write_status(self, status: dict) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.status_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(status, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, self.status_path)

    @staticmethod
    def _day(ts: float) -> str:
        return datetime.fromtimestamp(ts, tz=timezone.utc).date().isoformat()
