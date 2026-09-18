"""M2 — Timeline scrubber: deterministic replay of the house ledger.

Operating envelope: read-only view over an EventGraph. ``.at(t)`` renders
who-was-where at any instant (moving dots on a floor plan), ``.range()``
produces deterministic frames for replay, ``.reel()`` produces an ordered,
plain-English event list ("kitchen entered", "front door opened") filterable
by person or room, and ``.entries()`` answers "every time <tag> entered the
kitchen this week". Room coordinates come from VigilConfig rooms; when the
config carries no floor-plan coordinates a stable grid layout is
synthesized (sorted room names on a ceil(sqrt(n)) grid).

Determinism: everything is a pure function of the graph contents — same
graph, same frames, no wall clock.

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

SOMEONE = "someone"  # display key for events whose person-tag is None


class Scrubber:
    """Timeline scrubber over an EventGraph (see module docstring).

    Privacy by design: renders derived events only (room, person-tag,
    timestamps, confidence) — zero raw CSI, zero images by construction;
    household members must be informed; person-tags are opt-in deployment
    labels, not covert biometric identification.
    """

    LOCATED_KINDS = ("motion", "transition", "presence")

    def __init__(self, graph, config=None, *,
                 layout: dict[str, tuple[float, float]] | None = None,
                 active_window_s: float = 30.0) -> None:
        self.graph = graph
        self.config = config
        self.active_window_s = float(active_window_s)
        rooms = sorted(set(
            (list(config.rooms) if config is not None and config.rooms else [])
            + graph.rooms()))
        self.layout = dict(layout) if layout else _grid_layout(rooms)

    # -- instantaneous state -------------------------------------------------

    def at(self, t: float) -> dict:
        """State at instant t: {"persons": {tag: {room, xy}}, "active_events"}."""
        persons: dict[str, dict] = {}
        active: list[dict] = []
        for e in self.graph.query(float("-inf"), t + 1e-9):
            if e["kind"] in self.LOCATED_KINDS and e["room"]:
                tag = e["person"] if e["person"] is not None else SOMEONE
                persons[tag] = {"room": e["room"],
                                "xy": self.layout.get(e["room"], (0.5, 0.5))}
            if e["kind"] == "steam" and e["attrs"].get("t0", e["ts"]) <= t <= e["attrs"].get("t1", e["ts"]):
                active.append(e)
            elif e["kind"] != "steam" and t - self.active_window_s <= e["ts"] <= t:
                active.append(e)
        return {"persons": persons, "active_events": active}

    def range(self, t0: float, t1: float, step: float) -> list[dict]:
        """Deterministic replay frames [{t, persons, active_events}, ...]."""
        if step <= 0:
            raise ValueError("step must be > 0")
        n = int(math.floor((t1 - t0) / step + 1e-9)) + 1
        frames = []
        for k in range(n):
            t = t0 + k * step
            frames.append({"t": t, **self.at(t)})
        return frames

    # -- reels ----------------------------------------------------------------

    def reel(self, t0: float, t1: float, person: str | None = None,
             room: str | None = None) -> list[dict]:
        """Ordered event list with plain-English descriptions."""
        events = self.graph.query(t0, t1, person=person, room=room)
        return [{**e, "text": describe(e)} for e in events]

    def entries(self, person: str | None, room: str,
                t0: float, t1: float) -> list[dict]:
        """Every time <person> entered <room> in [t0, t1) — transition
        events into the room (e.g. 'kitchen this week')."""
        return self.graph.query(t0, t1, person=person, room=room,
                                kind="transition")

    # -- reel persistence ------------------------------------------------------

    @staticmethod
    def export_reel(reel: list[dict], path: str | Path) -> None:
        """Persist a reel as JSON (derived events + text only)."""
        Path(path).write_text(
            json.dumps({"version": 1, "events": reel}, indent=1),
            encoding="utf-8")

    @staticmethod
    def import_reel(path: str | Path) -> list[dict]:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        if doc.get("version") != 1:
            raise ValueError("unknown reel version")
        return list(doc["events"])


def describe(e: dict) -> str:
    """One plain-English line per event, count-honest and template-stable."""
    room = e.get("room") or "unknown room"
    kind = e["kind"]
    attrs = e.get("attrs", {})
    if kind == "transition":
        return f"{room} entered"
    if kind == "door":
        state = "opened" if attrs.get("state") == "open" else "closed"
        return f"{room} door {state}"
    if kind == "motion":
        return f"movement in {room}"
    if kind == "presence":
        return f"presence in {room}"
    if kind == "steam":
        return f"steam in {room}"
    if kind == "fall":
        status = attrs.get("status", "confirmed")
        return f"fall {status} in {room}"
    if kind == "vitals-summary":
        metric = attrs.get("metric", "vitals")
        if "bpm" in attrs:
            return f"{metric} {attrs['bpm']:.0f} bpm in {room}"
        return f"{metric} summary in {room}"
    return f"{kind} in {room}"


def _grid_layout(rooms: list[str]) -> dict[str, tuple[float, float]]:
    """Stable synthesized floor plan: sorted rooms on a square-ish grid,
    unit cells, dot at the cell center."""
    if not rooms:
        return {}
    cols = max(1, int(math.ceil(math.sqrt(len(rooms)))))
    return {r: (float(i % cols) + 0.5, float(i // cols) + 0.5)
            for i, r in enumerate(sorted(rooms))}
