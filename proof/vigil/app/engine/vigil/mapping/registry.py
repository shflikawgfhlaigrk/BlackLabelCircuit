"""F1 — Zone registry: the authoritative *label* layer of home mapping.

Design doc (binding for the whole F track)
------------------------------------------
Vigil's answer to "where is everything" is layered, and the layers are
strictly ordered:

    F1 labels  ->  F2 fingerprints  ->  F3/F4 geometry (presentation only)

* A **room is a name**. A **zone is a name**. The entire detection stack
  (gates, falls, vitals, ledger, alerts) is scoped by *room label* from day
  one: every event, alert and log line carries a room string obtained by
  looking up the emitting node's label here (or in `VigilConfig`, which this
  registry writes through to).
* **Geometry is presentation-only.** Coordinates, floor plans, MDS layouts
  and RoomPlan imports (F3/F4) exist to *draw* the house; nothing in
  detection reads them. Detection NEVER depends on layers above F1 — if
  every polygon in the system were deleted, every alert would still fire
  with the same room label. The F1 test proves this by running a full
  room-scoped event flow with zero geometric information in the process.
* **No second store.** The registry does not persist anything itself:
  `assign()` writes through to the `VigilConfig` it was constructed with
  (`config.rooms`, `NodeConfig.room/.zone`, `config.vitals_zone`), and
  `save()` simply delegates to `config.save()`. One config file remains the
  single source of truth (CONTRACTS.md §5).

Operating envelope: pure label bookkeeping — no IO beyond the delegated
config save, no numerics, no hardware assumptions. Validation is advisory
(warnings list), never blocking.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ..config import NodeConfig, VigilConfig


class ZoneRegistry:
    """Authoritative node -> room/zone label map, backed by a VigilConfig.

    All reads and writes go through the config object; constructing a
    registry never copies label state, so concurrent users of the same
    config (wizard, pipelines) always agree.
    """

    def __init__(self, config: VigilConfig) -> None:
        self.config = config

    # -- writes (write-through to VigilConfig) --------------------------------

    def assign(self, node_id: int, room: str, zone: str | None = None) -> None:
        """Assign a node to a room (and optional zone), write-through.

        Creates the NodeConfig if the node is unknown; removes the node from
        any previously assigned room list. Empty-but-known rooms are kept so
        `validate()` can warn about them.
        """
        node_id = int(node_id)
        room = str(room)
        # detach from any previous room
        for ids in self.config.rooms.values():
            while node_id in ids:
                ids.remove(node_id)
        self.config.rooms.setdefault(room, [])
        if node_id not in self.config.rooms[room]:
            self.config.rooms[room].append(node_id)
        try:
            node = self.config.node(node_id)
        except KeyError:
            node = NodeConfig(node_id=node_id)
            self.config.nodes.append(node)
        node.room = room
        if zone is not None:
            node.zone = str(zone)
            if node.zone == "bed":
                self.config.vitals_zone[room] = node_id

    # -- reads -----------------------------------------------------------------

    def room_of(self, node_id: int) -> str:
        return self.config.room_of(int(node_id))

    def nodes_of(self, room: str) -> list[int]:
        return list(self.config.rooms.get(room, []))

    def rooms(self) -> list[str]:
        return sorted(self.config.rooms)

    def node_ids(self) -> list[int]:
        return sorted(n.node_id for n in self.config.nodes)

    # -- room-scoping of the event flow -----------------------------------------

    def scope(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Return a copy of an event payload with the room label attached.

        The only lookup is node_id -> room *name*; no geometry exists or is
        consulted (see module docstring — this is the point of F1)."""
        out = dict(payload)
        nid = out.get("node_id")
        if "room" not in out or not out.get("room"):
            out["room"] = self.room_of(int(nid)) if nid is not None else ""
        return out

    def attach(self, bus, in_topic: str = "gate1.candidate",
               out_topic: str = "room.motion") -> None:
        """Re-publish node-tagged events as room-label-scoped events.

        Subscribes `in_topic`, publishes `out_topic` with the same payload
        plus `room` (minus any bulky `context` handle, per bus log rules)."""
        def _relay(topic: str, payload: dict) -> None:
            scoped = self.scope(payload)
            scoped.pop("context", None)
            bus.publish(out_topic, scoped)
        bus.subscribe(in_topic, _relay)

    # -- validation ---------------------------------------------------------------

    def validate(self) -> list[str]:
        """Advisory label-consistency warnings (never raises).

        Checks: orphan nodes (no room), empty rooms (no nodes), missing or
        inconsistent vitals zone (sleeping rooms should have a bed node)."""
        warnings: list[str] = []
        for n in self.config.nodes:
            if not n.room or n.node_id not in self.config.rooms.get(n.room, []):
                warnings.append(
                    f"orphan node {n.node_id}: not assigned to any room")
        for room, ids in self.config.rooms.items():
            if not ids:
                warnings.append(f"empty room {room!r}: no nodes assigned")
        for room, nid in self.config.vitals_zone.items():
            if room not in self.config.rooms:
                warnings.append(
                    f"vitals zone references unknown room {room!r}")
            elif nid not in self.config.rooms[room]:
                warnings.append(
                    f"vitals zone node {nid} is not in room {room!r}")
        for room in self.config.rooms:
            if "bed" in room.lower() and room not in self.config.vitals_zone:
                warnings.append(
                    f"missing vitals zone: sleeping room {room!r} has no "
                    "bed node — vitals will not run there")
        return warnings

    # -- persistence (piggybacks on VigilConfig — no second store) -----------------

    def save(self, path: str | Path) -> None:
        self.config.save(path)

    @classmethod
    def load(cls, path: str | Path) -> "ZoneRegistry":
        return cls(VigilConfig.load(path))
