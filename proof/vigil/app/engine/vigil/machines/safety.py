"""M4.3 — presence-aware stove/heat safety rules.

Rule: a machine signature flagged as a stove/heat source (config-driven
zone -> signature binding) is ACTIVE while no human presence has been seen
in that room for N minutes -> publish `machine.safety`
{rule: "stove-unattended", room, minutes, signature_id, t}. Escalation
happens over the existing alert path: the alerts module (or anything else)
subscribes to `machine.safety` on the bus — this module never imports
`vigil.falls.alerts`, bus only.

Inputs (all event-time driven, no wall clock — deterministic in tests):
- `machine.state` events from the SpectraProfiler for the bound signatures.
- Presence from the motion-energy path: `gate1.candidate` (node_id mapped to
  a room via the injectable `room_of` callable) and/or any topic whose
  payload carries a `room`. Presence is also directly injectable via the
  `presence(room, t)` callback for integrators/tests.
- `tick(t)` drives evaluation (call it from the ingest loop / a timer on
  hardware; tests call it explicitly).

Semantics: the unattended timer counts from the LATER of stove-on and last
presence in the room; it fires once per unattended episode and re-arms when
presence returns or the machine turns off. `test_alert()` publishes a
`machine.safety` test event through the same path.

Config additions live here as a module-local dataclass (`MachineSafetyConfig`)
— `vigil.config.VigilConfig` is not modified.

Operating envelope: "stove on" is inferred from the appliance's RF spectral
signature, so binding quality is only as good as the discovered signature
(hardware-gated); this is a nudge/alert layer, not a certified safety
interlock.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable


@dataclass
class ZoneBinding:
    """Bind one discovered signature to a room as a stove/heat source."""

    room: str
    signature_id: str
    kind: str = "stove"


@dataclass
class MachineSafetyConfig:
    bindings: list[ZoneBinding] = field(default_factory=list)
    unattended_min: float = 10.0        # minutes without presence -> alarm
    presence_topics: tuple[str, ...] = ("gate1.candidate", "presence.motion")


class SafetyRules:
    """Stove-unattended watchdog (see module docstring)."""

    def __init__(self, config: MachineSafetyConfig, bus,
                 room_of: Callable[[int], str] | None = None) -> None:
        self.config = config
        self.bus = bus
        self.room_of = room_of
        self._by_sig = {b.signature_id: b for b in config.bindings}
        self._active: dict[str, float] = {}         # signature_id -> t_on
        self._last_presence: dict[str, float] = {}  # room -> t
        self._fired: set[str] = set()               # per-episode latch
        self.fired: list[dict] = []                 # everything published
        bus.subscribe("machine.state", self._on_state)
        for topic in config.presence_topics:
            bus.subscribe(topic, self._on_presence)

    # -- inputs --------------------------------------------------------------

    def presence(self, room: str, t: float) -> None:
        """Injectable presence callback: a human was seen in `room` at `t`."""
        t = float(t)
        self._last_presence[room] = max(t, self._last_presence.get(room, t))
        for sid in list(self._fired):  # presence re-arms the episode latch
            if self._by_sig[sid].room == room:
                self._fired.discard(sid)

    def _on_presence(self, topic: str, payload: dict) -> None:
        room = payload.get("room")
        if not room and self.room_of is not None and "node_id" in payload:
            room = self.room_of(payload["node_id"])
        if room:
            self.presence(room, float(payload.get("t", 0.0)))

    def _on_state(self, topic: str, payload: dict) -> None:
        sid = payload.get("signature_id")
        if sid not in self._by_sig:
            return
        t = float(payload.get("t", 0.0))
        if payload.get("state") == "on":
            self._active.setdefault(sid, t)
        else:
            self._active.pop(sid, None)
            self._fired.discard(sid)
        self.tick(t)

    # -- evaluation ------------------------------------------------------------

    def tick(self, t: float) -> list[dict]:
        """Evaluate all bound signatures at event-time `t`; returns fires."""
        t = float(t)
        out: list[dict] = []
        for sid, t_on in self._active.items():
            if sid in self._fired:
                continue
            b = self._by_sig[sid]
            ref = max(t_on, self._last_presence.get(b.room, t_on))
            minutes = (t - ref) / 60.0
            if minutes >= self.config.unattended_min:
                self._fired.add(sid)
                out.append(self._publish({
                    "rule": f"{b.kind}-unattended", "room": b.room,
                    "signature_id": sid, "minutes": round(minutes, 2),
                    "t": t}))
        return out

    def test_alert(self, room: str = "test", t: float = 0.0) -> dict:
        """Exercise the alert path end-to-end with a test event."""
        return self._publish({"rule": "test-alert", "room": room,
                              "minutes": 0.0, "t": float(t)})

    def _publish(self, payload: dict) -> dict:
        self.bus.publish("machine.safety", payload)
        self.fired.append(payload)
        return payload
