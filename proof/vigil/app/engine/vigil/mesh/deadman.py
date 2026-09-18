"""M3 — Deadman: no-normal-pattern-by-deadline escalation through the mesh.

Operating envelope: runs on the host next to the pipeline. Something
upstream (motion in the expected window, a door event, the wizard's
morning routine detector) calls ``note_normal()`` when the household's
morning pattern is observed; if no such call has happened by the
configured deadline, the deadman escalates: it publishes
``mesh.escalate`` on the bus (AlertModule subscribes there — no import,
bus only) and, when a ``PactChannel`` is attached, sends the sealed
alarm payload to the peer household.

Signal-died vs person-died (the D5 pattern, reused deliberately): before
alarming, the deadman judges its OWN observability — recent ``node.health``
rates from the bus plus an optional ingest-liveness callback. If the local
system's senses have collapsed (nodes silent, ingest dead), a missing
morning pattern is evidence of a broken sensor net, not a person down:
it enters ``suppressed-unhealthy`` and publishes kind="health-warning"
instead of a human alarm (and does NOT page the peer). If health then
recovers for ``hysteresis_s`` while the pattern is still missing, the
suppression lifts and the real alarm fires — exactly once, until ``ack()``.

States: armed -> quiet-normal (pattern seen today)
        armed -> overdue (deadline passed) -> escalated (healthy)
                                            | suppressed-unhealthy (collapsed)
        suppressed-unhealthy -> escalated (health recovered, still no pattern)
        escalated -> armed via ack(); any state -> quiet-normal on note_normal.
A new day re-arms everything except an un-acked escalation.

All clocks are fed (``tick(t)``/``note_normal(t)``, unix seconds, days in
UTC); nothing sleeps. ``self_test()`` replays both scenarios on a private
bus, like ApneaMonitor's.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from statistics import median
from typing import Callable

from ..bus import EventBus

ARMED = "armed"
QUIET = "quiet-normal"
OVERDUE = "overdue"
ESCALATED = "escalated"
SUPPRESSED = "suppressed-unhealthy"

NOMINAL_RATE_HZ = 100.0     # per-node CSI rate (CONTRACTS.md §2)
TOPIC = "mesh.escalate"


@dataclass
class DeadmanThresholds:
    deadline_h: float = 12.0       # UTC hour by which the pattern must appear
    grace_s: float = 1800.0        # overdue dwell before deciding
    hysteresis_s: float = 3600.0   # health recovery needed to lift suppression
    health_floor: float = 0.5      # median quality below this = signal died
    health_window_s: float = 600.0 # how far back health samples count


class Deadman:
    """No-morning-pattern deadman with signal-died discrimination."""

    def __init__(self, thresholds, bus: EventBus, room: str = "home",
                 pact_channel=None,
                 liveness_fn: Callable[[], bool] | None = None) -> None:
        # Accept DeadmanThresholds or any object (e.g. config.Thresholds)
        # carrying a subset of the fields; missing ones take the defaults.
        d = DeadmanThresholds()
        for f in ("deadline_h", "grace_s", "hysteresis_s",
                  "health_floor", "health_window_s"):
            setattr(d, f, float(getattr(thresholds, f, getattr(d, f))))
        self.thresholds = d
        self.bus = bus
        self.room = room
        self.pact_channel = pact_channel
        self.liveness_fn = liveness_fn

        self.state = ARMED
        self.events: list[dict] = []          # local copy of published events
        self._day: str | None = None          # current day (UTC)
        self._normal_day: str | None = None   # last day the pattern was seen
        self._overdue_since: float | None = None
        self._recover_since: float | None = None
        self._health: deque[tuple[float, float]] = deque(maxlen=600)

        bus.subscribe("node.health", self._on_health)

    # -- inputs ---------------------------------------------------------------

    def _on_health(self, _topic: str, payload: dict) -> None:
        try:
            rate = float(payload.get("rate_hz", 0.0))
        except (TypeError, ValueError):
            return
        q = max(0.0, min(1.0, rate / NOMINAL_RATE_HZ))
        # Timestamped with the payload's t if present, else last tick time.
        t = float(payload.get("t", self._last_t))
        self._health.append((t, q))

    _last_t: float = 0.0

    def note_normal(self, t: float) -> str:
        """The household's expected pattern was observed at ``t``."""
        self._last_t = float(t)
        self._normal_day = self._day_of(t)
        if self.state != ESCALATED:   # an un-acked alarm needs a human ack
            self._to_quiet()
        return self.state

    # -- helpers ----------------------------------------------------------------

    @staticmethod
    def _day_of(t: float) -> str:
        return datetime.fromtimestamp(t, tz=timezone.utc).date().isoformat()

    @staticmethod
    def _hour_of(t: float) -> float:
        dt = datetime.fromtimestamp(t, tz=timezone.utc)
        return dt.hour + dt.minute / 60.0 + dt.second / 3600.0

    def _healthy(self, t: float) -> bool:
        if self.liveness_fn is not None and not self.liveness_fn():
            return False
        recent = [q for (ts, q) in self._health
                  if t - ts <= self.thresholds.health_window_s]
        if not recent:
            # No node.health evidence either way: trust the liveness
            # callback (already passed above) / assume observable.
            return True
        return median(recent) >= self.thresholds.health_floor

    def _publish(self, t: float, kind: str, reason: str) -> None:
        payload = {"room": self.room, "t": float(t), "kind": kind,
                   "reason": reason}
        self.events.append(payload)
        self.bus.publish(TOPIC, payload)
        if kind == "alarm" and self.pact_channel is not None:
            # Peer household gets the sealed escalation payload; health
            # warnings stay local (a broken sensor net is our problem).
            self.pact_channel.send_alarm(kind="deadman", room=self.room,
                                         t=float(t), confidence=1.0)

    def _to_quiet(self) -> None:
        self.state = QUIET
        self._overdue_since = None
        self._recover_since = None

    def ack(self) -> str:
        """Human acknowledged the escalation/suppression."""
        if self.state in (ESCALATED, SUPPRESSED):
            self._overdue_since = None
            self._recover_since = None
            self.state = QUIET if self._normal_day == self._day else ARMED
        return self.state

    # -- clock ------------------------------------------------------------------

    def tick(self, t: float) -> str:
        """Advance the deadman to time ``t`` (unix seconds). Idempotent per
        call; feed it as often as you like (no sleeps anywhere)."""
        t = float(t)
        self._last_t = t
        day = self._day_of(t)
        if day != self._day:
            self._day = day
            # New day: everything re-arms except an un-acked escalation.
            if self.state != ESCALATED:
                self.state = ARMED
                self._overdue_since = None
                self._recover_since = None

        normal_today = self._normal_day == day
        th = self.thresholds

        if self.state == ARMED:
            if normal_today:
                self._to_quiet()
            elif self._hour_of(t) >= th.deadline_h:
                self.state = OVERDUE
                self._overdue_since = t

        elif self.state == OVERDUE:
            if normal_today:
                self._to_quiet()
            elif t - (self._overdue_since or t) >= th.grace_s:
                if self._healthy(t):
                    self.state = ESCALATED
                    self._publish(t, "alarm", "no-morning-pattern")
                else:
                    self.state = SUPPRESSED
                    self._recover_since = None
                    self._publish(t, "health-warning",
                                  "no-morning-pattern-but-signal-died")

        elif self.state == SUPPRESSED:
            if normal_today:
                self._to_quiet()
            elif self._healthy(t):
                if self._recover_since is None:
                    self._recover_since = t
                elif t - self._recover_since >= th.hysteresis_s:
                    # Senses are back and the pattern is still missing:
                    # this is now a human alarm. Fires exactly once.
                    self.state = ESCALATED
                    self._publish(t, "alarm",
                                  "no-morning-pattern-after-recovery")
            else:
                self._recover_since = None

        elif self.state == ESCALATED:
            pass   # sticky until ack()

        elif self.state == QUIET:
            pass   # new-day rollover above re-arms

        return self.state

    # -- self-test ---------------------------------------------------------------

    def self_test(self) -> dict:
        """Signal-injection self-test on a private bus (never publishes to
        the live bus): (a) healthy + no pattern -> exactly one alarm, ack
        re-arms; (b) collapsed health -> health-warning, not alarm."""
        day0 = 1_700_000_000 - (1_700_000_000 % 86400)   # UTC midnight

        bus_a = EventBus()
        seen_a: list[dict] = []
        bus_a.subscribe(TOPIC, lambda _t, p: seen_a.append(p))
        probe = Deadman(self.thresholds, bus_a, room="self-test")
        t = day0
        while t < day0 + 20 * 3600:
            probe.push_health(t, 1.0)
            probe.tick(t)
            t += 600.0
        alarm_ok = (len(seen_a) == 1 and seen_a[0]["kind"] == "alarm"
                    and probe.state == ESCALATED)
        probe.ack()
        ack_ok = probe.state in (ARMED, QUIET)

        bus_b = EventBus()
        seen_b: list[dict] = []
        bus_b.subscribe(TOPIC, lambda _t, p: seen_b.append(p))
        probe2 = Deadman(self.thresholds, bus_b, room="self-test",
                         liveness_fn=lambda: False)
        t = day0
        while t < day0 + 20 * 3600:
            probe2.push_health(t, 0.0)
            probe2.tick(t)
            t += 600.0
        suppress_ok = (len(seen_b) == 1
                       and seen_b[0]["kind"] == "health-warning"
                       and probe2.state == SUPPRESSED)
        return {"ok": alarm_ok and ack_ok and suppress_ok,
                "alarm_ok": alarm_ok, "ack_ok": ack_ok,
                "suppress_ok": suppress_ok}

    # Direct health injection (tests / callers without a bus feed).
    def push_health(self, t: float, quality: float) -> None:
        self._health.append((float(t), max(0.0, min(1.0, float(quality)))))
