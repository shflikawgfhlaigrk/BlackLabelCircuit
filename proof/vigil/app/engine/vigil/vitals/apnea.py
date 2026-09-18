"""D5 — Absence-of-breathing alarm (streaming state machine).

Operating envelope: runs on the vitals stream of a sleeping-room node. It
only ever alarms from an ESTABLISHED breathing trace (>= 60 s of
gate-passing breathing confidence inside a qualifying still window), so it
cannot alarm on an empty bed or before the pipeline has locked on. Alerting
itself is Track C's AlertModule, which subscribes to `vitals.apnea` — this
module only publishes.

Decision table (evaluated per pushed sample; conf = breathing confidence,
gate = Thresholds.breathing_min_confidence, floor = 0.5 * gate,
quality floor = 0.5):

| state    | present | motion burst | conf                    | quality   | action                          |
|----------|---------|--------------|-------------------------|-----------|---------------------------------|
| watching | yes     | no           | >= gate (accumulating)  | any       | establish after 60 s -> armed   |
| watching | no/any  | yes/any      | < gate                  | any       | reset establishment clock       |
| armed    | no      | any          | any                     | any       | -> watching (left bed)          |
| armed    | yes     | yes          | any                     | any       | -> watching (movement explains) |
| armed    | yes     | no           | < floor for >= loss_s   | healthy   | publish kind="alarm" -> post    |
| armed    | yes     | no           | < floor for >= loss_s   | collapsed | publish kind="health-warning"   |
|          |         |              |                         |           | (sensor problem, not apnea)     |
| post     | yes     | no           | >= gate for hysteresis  | any       | re-arm -> armed                 |
| post     | no/any  | yes/any      | any                     | any       | -> watching                     |

Hysteresis: after ANY alarm/health-warning, `apnea_hysteresis_s` of
continuously recovered (gate-passing) breathing is required before the
monitor re-arms; suppression path (a) resets to watching, which requires a
full 60 s re-establishment (strictly stronger than the hysteresis).

Motion bursts are judged against the monitor's own rolling quiet level
(median of the lower half of recent energies) times
`Thresholds.quiet_energy_factor` — same robust rule as windows.py.
"""

from __future__ import annotations

from collections import deque

import numpy as np

from ..bus import EventBus
from .gating import VitalsEstimate

ESTABLISH_S = 60.0       # gate-passing breathing needed before arming
QUALITY_FLOOR = 0.5      # below this, signal loss is a sensor problem
CONF_FLOOR_RATIO = 0.5   # collapse floor = ratio * breathing gate
_MAX_DT_S = 5.0          # clamp clock gaps

WATCHING, ARMED, POST = "watching", "armed", "post"


class ApneaMonitor:
    """Streaming absence-of-breathing monitor; publishes `vitals.apnea`."""

    def __init__(self, thresholds, bus: EventBus, room: str,
                 presence_fn=None) -> None:
        self.thresholds = thresholds
        self.bus = bus
        self.room = room
        self.presence_fn = presence_fn
        self.state = WATCHING
        self._last_t: float | None = None
        self._est_s = 0.0        # establishment clock
        self._loss_s = 0.0       # confidence-collapse clock
        self._recover_s = 0.0    # hysteresis clock
        self._loss_quality: list[float] = []
        self._energies: deque[float] = deque(maxlen=300)
        self.events: list[dict] = []  # local copy of published events

    # -- helpers ------------------------------------------------------------

    def _is_burst(self, energy: float) -> bool:
        if len(self._energies) >= 10:
            lo = sorted(self._energies)[: max(1, len(self._energies) // 2)]
            quiet = float(np.median(lo))
            burst = energy > float(self.thresholds.quiet_energy_factor) * quiet
        else:
            burst = False  # not enough history to judge
        self._energies.append(float(energy))
        return burst

    def _publish(self, t: float, kind: str) -> None:
        payload = {"room": self.room, "t": float(t), "kind": kind}
        self.events.append(payload)
        self.bus.publish("vitals.apnea", payload)

    def _to_watching(self) -> None:
        self.state = WATCHING
        self._est_s = 0.0
        self._loss_s = 0.0
        self._recover_s = 0.0
        self._loss_quality = []

    # -- streaming ----------------------------------------------------------

    def push(self, t: float, breathing_est: VitalsEstimate | None,
             motion_energy: float, signal_quality: float,
             present: bool | None = None) -> str:
        """Feed one sample; returns the (possibly new) state name."""
        if present is None:
            present = bool(self.presence_fn(t)) if self.presence_fn else True
        dt = 0.0
        if self._last_t is not None:
            dt = float(np.clip(t - self._last_t, 0.0, _MAX_DT_S))
        self._last_t = t

        conf = float(breathing_est.confidence) if breathing_est is not None else 0.0
        gate = float(self.thresholds.breathing_min_confidence)
        floor = CONF_FLOOR_RATIO * gate
        burst = self._is_burst(motion_energy)

        if self.state == WATCHING:
            if present and not burst and conf >= gate:
                self._est_s += dt
                if self._est_s >= ESTABLISH_S:
                    self.state = ARMED
                    self._loss_s = 0.0
                    self._loss_quality = []
            else:
                self._est_s = 0.0

        elif self.state == ARMED:
            if not present or burst:
                self._to_watching()  # suppression (a): person left / moved
            elif conf < floor:
                self._loss_s += dt
                self._loss_quality.append(float(signal_quality))
                if self._loss_s >= float(self.thresholds.apnea_loss_s):
                    healthy = float(np.median(self._loss_quality)) >= QUALITY_FLOOR
                    self._publish(t, "alarm" if healthy else "health-warning")
                    self.state = POST
                    self._recover_s = 0.0
                    self._loss_s = 0.0
                    self._loss_quality = []
            else:
                self._loss_s = 0.0
                self._loss_quality = []

        elif self.state == POST:
            if not present or burst:
                self._to_watching()
            elif conf >= gate:
                self._recover_s += dt
                if self._recover_s >= float(self.thresholds.apnea_hysteresis_s):
                    self.state = ARMED
                    self._loss_s = 0.0
                    self._loss_quality = []
                    self._recover_s = 0.0
            else:
                self._recover_s = 0.0

        return self.state

    # -- self-test ----------------------------------------------------------

    def self_test(self) -> dict:
        """Signal-injection self-test on a private bus (never publishes to
        the live bus): establish a trace, hold breath, expect one alarm;
        then a leave-bed replay, expect suppression. Returns {"ok", ...}."""
        bus = EventBus()
        seen: list[dict] = []
        bus.subscribe("vitals.apnea", lambda _t, p: seen.append(p))
        probe = ApneaMonitor(self.thresholds, bus, room="self-test")
        good = VitalsEstimate(14.0, 0.95, {})
        bad = VitalsEstimate(0.0, 0.02, {})
        t = 0.0
        for _ in range(int(ESTABLISH_S) + 10):
            probe.push(t, good, 1.0, 0.9, True)
            t += 1.0
        for _ in range(int(self.thresholds.apnea_loss_s) + 5):
            probe.push(t, bad, 1.0, 0.9, True)
            t += 1.0
        alarm_ok = len(seen) == 1 and seen[0]["kind"] == "alarm"
        # leave-bed suppression
        probe2 = ApneaMonitor(self.thresholds, bus, room="self-test")
        seen2_before = len(seen)
        t = 0.0
        for _ in range(int(ESTABLISH_S) + 10):
            probe2.push(t, good, 1.0, 0.9, True)
            t += 1.0
        for _ in range(int(self.thresholds.apnea_loss_s) + 5):
            probe2.push(t, bad, 50.0, 0.9, False)
            t += 1.0
        suppress_ok = len(seen) == seen2_before and probe2.state == WATCHING
        return {"ok": alarm_ok and suppress_ok, "alarm_ok": alarm_ok,
                "suppress_ok": suppress_ok, "events": seen}
