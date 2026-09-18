"""M2 — Event graph: append-only JSONL life record + in-memory index.

Operating envelope: the single durable store behind the house ledger. One
JSON object per line, append-only by construction (in-place edits are
refused; external truncation/rewrites are detected and raise
LedgerIntegrityError; optional fsync per append). Consumes bus topics and
normalizes them into a fixed event vocabulary:

    {ts, kind, room, person, node_id, confidence, attrs{small scalars only}}

kinds: motion, transition (room A->B), door (open/close), steam, presence,
fall, vitals-summary.

Bus topic ``door.event`` (defined here; produced by the firmware hall-sensor
capture, which is hardware-gated and added separately):
    {node_id: int, state: "open"|"close", t: seconds}
It is normalized to kind="door" with attrs={"state": ...}.

Person attribution is an injectable PersonTagger (callback (event)->tag or
None). The default HeuristicTagger carries a deployment-supplied tag across
a continuous motion track within a room and across room transitions.
Documented limits: single-occupant confidence is high; multi-occupant
scenes are ambiguous and the tag degrades to None ("someone") — this is a
continuity heuristic, not identification.

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification.
"""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Callable

DOOR_TOPIC = "door.event"  # {node_id, state: "open"|"close", t}

KINDS = ("motion", "transition", "door", "steam", "presence", "fall",
         "vitals-summary")

DAY_S = 86400.0

PersonTagger = Callable[[dict], "str | None"]

_MAX_ATTRS = 16


class LedgerIntegrityError(RuntimeError):
    """The append-only invariant of the ledger file was violated."""


class HeuristicTagger:
    """Default person attribution: track continuity, not biometrics.

    Carries an opt-in, deployment-supplied tag (see ``.seed``) across a
    continuous motion track within a room and across transitions. Limits
    (documented, by design): single-occupant homes yield high-confidence
    tags; when motion appears in a second room faster than a person could
    traverse (< ``min_traversal_s``), the scene is multi-occupant and the
    tag degrades to None ("someone"). After ``track_timeout_s`` without
    events the tag is only kept if the track resumes in the same room.

    Privacy by design: emits opt-in label strings only — zero raw CSI, zero
    images by construction; household members must be informed; this is not
    covert biometric identification.
    """

    LOCATED_KINDS = ("motion", "transition", "presence")

    def __init__(self, default_tag: str | None = None,
                 min_traversal_s: float = 2.0,
                 track_timeout_s: float = 600.0) -> None:
        self.default_tag = default_tag
        self.min_traversal_s = float(min_traversal_s)
        self.track_timeout_s = float(track_timeout_s)
        self._track: list | None = None  # [tag, room, ts]

    def seed(self, tag: str | None, room: str, t: float) -> None:
        """Deployment-supplied identity anchor (e.g. resident confirmed at
        the front door). Tags are opt-in labels, never inferred."""
        self._track = [tag, room, float(t)]

    def __call__(self, event: dict) -> str | None:
        if event.get("kind") not in self.LOCATED_KINDS or not event.get("room"):
            return self._track[0] if self._track else self.default_tag
        ts, room = float(event["ts"]), event["room"]
        if self._track is None:
            self._track = [self.default_tag, room, ts]
            return self._track[0]
        tag, prev_room, prev_t = self._track
        dt = ts - prev_t
        if room != prev_room and dt < self.min_traversal_s:
            tag = None  # two rooms at once -> multi-occupant, ambiguous
        elif dt > self.track_timeout_s and room != prev_room:
            tag = None  # continuity lost
        self._track = [tag, room, ts]
        return tag


class EventGraph:
    """Append-only JSONL event store with an in-memory query index.

    Privacy by design: stores derived events only (room, person-tag,
    timestamps, confidence, small scalar attrs) — zero raw CSI, zero images
    by construction; household members must be informed; person-tags are
    opt-in labels supplied by the deployment, not covert biometric
    identification.
    """

    def __init__(self, path: str | Path, *, config=None,
                 tagger: PersonTagger | None = None, fsync: bool = False,
                 transition_gap_s: float = 60.0) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.config = config
        self.tagger = tagger
        self.fsync = bool(fsync)
        self.transition_gap_s = float(transition_gap_s)
        self._lock = threading.Lock()
        self._events: list[dict] = []
        self._last_motion: dict[str | None, tuple[str, float]] = {}
        if self.path.exists():
            with self.path.open(encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        self._events.append(json.loads(line))
            self._expected_size = self.path.stat().st_size
        else:
            self._expected_size = 0

    # -- append-only write path --------------------------------------------

    def append(self, event: dict) -> dict:
        """Validate, tag, persist and index one event. Returns the record."""
        rec = self._normalize(event)
        line = json.dumps(rec, separators=(",", ":")) + "\n"
        with self._lock:
            self._check_integrity()
            with self.path.open("a", encoding="utf-8") as f:
                f.write(line)
                if self.fsync:
                    f.flush()
                    os.fsync(f.fileno())
            self._expected_size += len(line.encode("utf-8"))
            self._events.append(rec)
        return dict(rec)

    def _check_integrity(self) -> None:
        actual = self.path.stat().st_size if self.path.exists() else 0
        if actual != self._expected_size:
            raise LedgerIntegrityError(
                f"ledger file {self.path} changed outside append "
                f"(expected {self._expected_size} bytes, found {actual}); "
                "the ledger is append-only — refusing to write")

    def _normalize(self, event: dict) -> dict:
        if "ts" not in event or "kind" not in event:
            raise ValueError("event requires at least {ts, kind}")
        kind = str(event["kind"])
        if kind not in KINDS:
            raise ValueError(f"unknown event kind {kind!r}; vocabulary: {KINDS}")
        attrs = dict(event.get("attrs") or {})
        if len(attrs) > _MAX_ATTRS or not all(
                isinstance(k, str) and _is_small_scalar(v) for k, v in attrs.items()):
            raise ValueError("attrs must be <=16 small scalars (no arrays, "
                             "no raw signal data — the ledger is derived-only)")
        rec = {
            "ts": float(event["ts"]),
            "kind": kind,
            "room": str(event.get("room") or ""),
            "person": event.get("person"),
            "node_id": event.get("node_id"),
            "confidence": float(event.get("confidence", 1.0)),
            "attrs": attrs,
        }
        if rec["person"] is None and self.tagger is not None:
            rec["person"] = self.tagger(rec)
        return rec

    # -- bus ingestion --------------------------------------------------------

    def attach(self, bus) -> None:
        """Subscribe to the live topics and normalize them into the graph:
        gate1.candidate, fall.*, vitals.*, ledger.steam, door.event."""
        bus.subscribe("gate1.candidate", self._on_gate1)
        bus.subscribe("fall.*", self._on_fall)
        bus.subscribe("vitals.*", self._on_vitals)
        bus.subscribe("ledger.steam", self._on_steam)
        bus.subscribe(DOOR_TOPIC, self._on_door)

    def _room_of(self, payload: dict) -> str:
        room = payload.get("room")
        if room:
            return str(room)
        nid = payload.get("node_id")
        if self.config is not None and nid is not None:
            try:
                return self.config.room_of(int(nid))
            except Exception:
                return ""
        return ""

    def _on_gate1(self, topic: str, p: dict) -> None:
        ev = self.append({
            "ts": p.get("t", 0.0), "kind": "motion", "room": self._room_of(p),
            "node_id": p.get("node_id"), "confidence": 0.9,
            "attrs": {"energy": float(p.get("energy", 0.0))},
        })
        self._note_motion(ev)

    def _note_motion(self, ev: dict) -> None:
        """Derive room A->B transition events from cross-room motion."""
        person = ev.get("person")
        room, ts = ev["room"], ev["ts"]
        if not room:
            return
        last = self._last_motion.get(person)
        if last is not None and last[0] != room and 0.0 < ts - last[1] <= self.transition_gap_s:
            self.append({
                "ts": ts, "kind": "transition", "room": room,
                "person": person, "confidence": ev.get("confidence", 0.9),
                "attrs": {"from": last[0], "to": room,
                          "traversal_s": round(ts - last[1], 3)},
            })
        self._last_motion[person] = (room, ts)

    def _on_fall(self, topic: str, p: dict) -> None:
        status = "confirmed" if topic.endswith("confirmed") else "downgraded"
        attrs = {"status": status}
        if p.get("reason"):
            attrs["reason"] = str(p["reason"])
        self.append({"ts": p.get("t", 0.0), "kind": "fall",
                     "room": self._room_of(p),
                     "confidence": float(p.get("confidence", 1.0)),
                     "attrs": attrs})

    def _on_vitals(self, topic: str, p: dict) -> None:
        metric = topic.split(".", 1)[1]
        attrs: dict = {"metric": metric}
        if "bpm" in p:
            attrs["bpm"] = float(p["bpm"])
        if "kind" in p:
            attrs["kind"] = str(p["kind"])
        self.append({"ts": p.get("t", 0.0), "kind": "vitals-summary",
                     "room": self._room_of(p),
                     "confidence": float(p.get("confidence", 1.0)),
                     "attrs": attrs})

    def _on_steam(self, topic: str, p: dict) -> None:
        self.append({"ts": float(p.get("t0", 0.0)), "kind": "steam",
                     "room": self._room_of(p),
                     "confidence": float(p.get("confidence", 0.0)),
                     "attrs": {"t0": float(p.get("t0", 0.0)),
                               "t1": float(p.get("t1", 0.0))}})

    def _on_door(self, topic: str, p: dict) -> None:
        state = str(p.get("state", ""))
        if state not in ("open", "close"):
            raise ValueError(f"door.event state must be open|close, got {state!r}")
        self.append({"ts": float(p.get("t", 0.0)), "kind": "door",
                     "room": self._room_of(p), "node_id": p.get("node_id"),
                     "confidence": 1.0, "attrs": {"state": state}})

    # -- query ---------------------------------------------------------------

    def query(self, t0: float, t1: float, person: str | None = None,
              room: str | None = None, kind: str | None = None) -> list[dict]:
        """Events with t0 <= ts < t1, optionally filtered, sorted by ts.
        Returns copies — the index itself is append-only."""
        out = [dict(e) for e in self._events
               if t0 <= e["ts"] < t1
               and (person is None or e.get("person") == person)
               and (room is None or e.get("room") == room)
               and (kind is None or e.get("kind") == kind)]
        out.sort(key=lambda e: (e["ts"], e["kind"]))
        return out

    def day(self, day_t0: float, **kw) -> list[dict]:
        """Day slice helper: events in [day_t0, day_t0 + 24 h)."""
        return self.query(day_t0, day_t0 + DAY_S, **kw)

    def persons(self) -> list[str]:
        return sorted({e["person"] for e in self._events if e.get("person")})

    def rooms(self) -> list[str]:
        return sorted({e["room"] for e in self._events if e.get("room")})

    def __len__(self) -> int:
        return len(self._events)


def _is_small_scalar(v) -> bool:
    return isinstance(v, (str, int, float, bool)) or v is None
