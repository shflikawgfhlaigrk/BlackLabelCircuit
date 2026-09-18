"""M4.2 — appliance drift watch: predictive-maintenance alarms from duty
and spectral-line baselines.

Consumes the per-segment signature history maintained by
`vigil.machines.spectra.SpectraProfiler` and builds per-signature EWMA
baselines of: duty-cycle fraction, cycle period, on-run duration, line
center frequency, center-frequency wobble variance, and line width. It then
alarms on deviations that map to known failure modes:

- ``duty-high``: duty fraction >= `duty_ratio` (default 1.3, i.e. +30%) x
  baseline — a compressor running longer to hold temperature (dying seal /
  low refrigerant / blocked coil proxy).
- ``wobble``: within-cycle variance of the line center frequency exceeds
  `wobble_ratio` (default 3x) x baseline variance — mechanical looseness /
  bearing-wear proxy.
- ``stuck``: a cycle started but never completed — the current on-run
  exceeds `stuck_factor` (default 3x) x baseline on-run duration.

Honest arming: a signature must contribute >= `min_cycles` completed cycles
of baseline before any rule arms; until then `state()` reports "learning"
and nothing fires. Alarming cycles do NOT update the baseline (the baseline
must not chase the fault). Emits `machine.drift` {signature_id, rule,
severity, t, evidence: scalars} on the bus.

Operating envelope: cycle statistics are quantized at the profiler's 10 s
segment resolution; failure-mode mapping is a heuristic validated on
synthetic phenomenology — real-appliance thresholds are hardware-gated.
"""

from __future__ import annotations

import numpy as np

_BASE_KEYS = ("duty", "period_s", "on_s", "center_hz", "wobble_hz2", "width_hz")


class _Tracker:
    __slots__ = ("cursor", "state", "on_start", "last_on_start", "run_centers",
                 "run_widths", "pending", "stuck_fired", "base", "n_cycles",
                 "armed")

    def __init__(self) -> None:
        self.cursor = 0
        self.state: bool | None = None
        self.on_start: float | None = None
        self.last_on_start: float | None = None
        self.run_centers: list[float] = []
        self.run_widths: list[float] = []
        self.pending: dict | None = None
        self.stuck_fired = False
        self.base: dict[str, float] = {}
        self.n_cycles = 0
        self.armed = False


class DriftWatch:
    """Per-signature baseline + drift alarms (see module docstring)."""

    LEARNING = "learning"
    ARMED = "armed"

    def __init__(self, profiler, bus=None, min_cycles: int = 5,
                 duty_ratio: float = 1.3, wobble_ratio: float = 3.0,
                 stuck_factor: float = 3.0, wobble_floor_hz2: float = 2e-3,
                 alpha: float = 0.3) -> None:
        self.profiler = profiler
        self.bus = bus if bus is not None else getattr(profiler, "bus", None)
        self.min_cycles = int(min_cycles)
        self.duty_ratio = float(duty_ratio)
        self.wobble_ratio = float(wobble_ratio)
        self.stuck_factor = float(stuck_factor)
        self.wobble_floor_hz2 = float(wobble_floor_hz2)
        self.alpha = float(alpha)
        self._trk: dict[str, _Tracker] = {}
        self.alarms: list[dict] = []

    # -- public -------------------------------------------------------------

    def poll(self) -> list[dict]:
        """Consume any new signature history; returns alarms fired now."""
        out: list[dict] = []
        for sig in self.profiler.catalog():
            tr = self._trk.setdefault(sig.signature_id, _Tracker())
            hist = sig.history
            for rec in hist[tr.cursor:]:
                out += self._step(sig, tr, rec)
            tr.cursor = len(hist)
        self.alarms.extend(out)
        return out

    def state(self, signature_id: str) -> str:
        """"learning" | "armed" | "unknown" (never seen)."""
        tr = self._trk.get(signature_id)
        if tr is None:
            return "unknown"
        return self.ARMED if tr.armed else self.LEARNING

    def states(self) -> dict[str, str]:
        return {sid: self.state(sid) for sid in self._trk}

    def baseline(self, signature_id: str) -> dict[str, float]:
        tr = self._trk.get(signature_id)
        return dict(tr.base) if tr is not None else {}

    # -- internals ----------------------------------------------------------

    def _step(self, sig, tr: _Tracker, rec: dict) -> list[dict]:
        out: list[dict] = []
        t = float(rec["t"])
        on = bool(rec["on"])
        if on:
            if tr.state is not True:  # off/None -> on
                if tr.pending is not None and tr.last_on_start is not None:
                    period = t - tr.last_on_start
                    if period > 0:
                        cyc = dict(tr.pending)
                        cyc["period_s"] = period
                        cyc["duty"] = cyc["on_s"] / period
                        out += self._on_cycle(sig, tr, cyc, t)
                tr.pending = None
                tr.last_on_start = t
                tr.on_start = t
                tr.run_centers = []
                tr.run_widths = []
                tr.stuck_fired = False
            tr.run_centers.append(float(rec["center_hz"]))
            tr.run_widths.append(float(rec["width_hz"]))
            if (tr.armed and not tr.stuck_fired and tr.on_start is not None
                    and tr.base.get("on_s", 0.0) > 0.0
                    and (t - tr.on_start) > self.stuck_factor * tr.base["on_s"]):
                tr.stuck_fired = True
                out.append(self._alarm(sig, "stuck", 0.9, {
                    "on_s": round(t - tr.on_start, 3),
                    "baseline_on_s": round(tr.base["on_s"], 3)}, t))
        else:
            if tr.state is True and tr.on_start is not None:  # on -> off
                tr.pending = {
                    "on_s": t - tr.on_start,
                    "center_hz": float(np.mean(tr.run_centers)) if tr.run_centers else 0.0,
                    "wobble_hz2": float(np.var(tr.run_centers)) if tr.run_centers else 0.0,
                    "width_hz": float(np.mean(tr.run_widths)) if tr.run_widths else 0.0,
                }
                tr.on_start = None
                tr.stuck_fired = False
        tr.state = on
        return out

    def _on_cycle(self, sig, tr: _Tracker, cyc: dict, t: float) -> list[dict]:
        if not tr.armed:
            self._blend(tr, cyc)
            tr.n_cycles += 1
            if tr.n_cycles >= self.min_cycles:
                tr.armed = True
            return []
        out: list[dict] = []
        base = tr.base
        if base.get("duty", 0.0) > 0.0 and cyc["duty"] > self.duty_ratio * base["duty"]:
            sev = float(min(1.0, cyc["duty"] / base["duty"] - 1.0))
            out.append(self._alarm(sig, "duty-high", sev, {
                "duty": round(cyc["duty"], 4),
                "baseline_duty": round(base["duty"], 4),
                "period_s": round(cyc["period_s"], 3)}, t))
        wfloor = max(base.get("wobble_hz2", 0.0), self.wobble_floor_hz2)
        if cyc["wobble_hz2"] > self.wobble_ratio * wfloor:
            sev = float(min(1.0, cyc["wobble_hz2"] / (10.0 * wfloor)))
            out.append(self._alarm(sig, "wobble", sev, {
                "wobble_hz2": round(cyc["wobble_hz2"], 6),
                "baseline_wobble_hz2": round(wfloor, 6),
                "center_hz": round(cyc["center_hz"], 3)}, t))
        if not out:  # only healthy cycles refine the baseline
            self._blend(tr, cyc)
        return out

    def _blend(self, tr: _Tracker, cyc: dict) -> None:
        for k in _BASE_KEYS:
            v = float(cyc.get(k, 0.0))
            tr.base[k] = v if k not in tr.base else (
                (1.0 - self.alpha) * tr.base[k] + self.alpha * v)

    def _alarm(self, sig, rule: str, severity: float, evidence: dict,
               t: float) -> dict:
        payload = {"signature_id": sig.signature_id, "rule": rule,
                   "severity": round(float(severity), 3), "t": float(t),
                   "evidence": evidence}
        if self.bus is not None:
            self.bus.publish("machine.drift", payload)
        return payload
