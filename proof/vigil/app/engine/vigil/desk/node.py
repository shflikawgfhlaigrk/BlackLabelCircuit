"""M1 — DeskNode: the seated-at-Mac CSI geometry profile.

Operating envelope: one node within ~1 m of a seated, mostly-stationary
subject — the best-case geometry for amplitude-only CSI vitals, which is
why the desk profile can use shorter qualifying windows than the bedroom
profile (breathing windows >= 15 s by default vs 30 s; both are
parameters). Input windows are float32 [t, 52] at fs = 100 Hz
(CONTRACTS.md §2). Occupancy is judged from band-limited (0.5–10 Hz)
energy against an empty-desk baseline: `empty` | `seated` | `active`.
Vitals (BreathingExtractor / HeartExtractor) run only on `seated` windows
whose motion-energy passes the WindowManager stillness test.

Honesty: accuracy is NOT gated here. Every estimate is published with its
confidence attached (D4 style, `desk.vitals` / `desk.occupancy` topics);
downstream gates decide what to display. Synthetic tests prove plumbing,
not real-subject accuracy — real numbers are hardware/subject-gated.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

import numpy as np
from scipy import signal

from ..config import Thresholds
from ..vitals.breathing import BreathingExtractor
from ..vitals.gating import VitalsEstimate
from ..vitals.heart import HeartExtractor
from ..vitals.windows import WindowManager

OCC_BAND = (0.5, 10.0)  # Hz — occupancy band energy
_EPS = 1e-12


@dataclass
class DeskSample:
    """One processed desk window: occupancy + optional vitals estimates."""

    t: float                            # window start time, seconds
    occupancy: str                      # "empty" | "seated" | "active"
    breathing: VitalsEstimate | None = None
    hr: VitalsEstimate | None = None


class DeskNode:
    """Occupancy + desk-tuned vitals over CSI windows [t, 52] at fs.

    Parameters
    ----------
    fs : sample rate (CONTRACTS §2: 100 Hz).
    thresholds : base `vigil.config.Thresholds`; the desk profile overrides
        the vitals still-window minima with the desk-tuned params below
        (the passed object is never mutated).
    bus : optional `vigil.bus.EventBus`; when given, `desk.occupancy` and
        `desk.vitals` events are published with confidence always attached.
    breathing_min_still_s : desk-tuned qualifying window for breathing
        (seated stillness is high quality — 15 s default).
    hr_min_still_s : desk-tuned qualifying window for HR.
    seated_ratio / active_ratio : occupancy band-energy ratios vs the
        empty-desk baseline separating empty|seated and seated|active.
    """

    def __init__(self, fs: float = 100.0, thresholds: Thresholds | None = None,
                 bus=None, breathing_min_still_s: float = 15.0,
                 hr_min_still_s: float = 45.0, seated_ratio: float = 1.8,
                 active_ratio: float = 12.0) -> None:
        base = thresholds if thresholds is not None else Thresholds()
        self.thresholds = replace(base,
                                  breathing_min_still_s=float(breathing_min_still_s),
                                  hr_min_still_s=float(hr_min_still_s))
        self.fs = float(fs)
        self.bus = bus
        self.seated_ratio = float(seated_ratio)
        self.active_ratio = float(active_ratio)
        self.windows = WindowManager(self.thresholds, fs=self.fs)
        self.breathing = BreathingExtractor(fs=self.fs)
        self.heart = HeartExtractor(fs=self.fs)
        self._occ_sos = signal.butter(4, OCC_BAND, btype="bandpass",
                                      fs=self.fs, output="sos")
        self._baseline: float | None = None
        self._t = 0.0

    # -- occupancy -----------------------------------------------------------

    def _band_energy(self, window: np.ndarray) -> float:
        x = signal.detrend(np.asarray(window, dtype=float), axis=0)
        y = signal.sosfiltfilt(self._occ_sos, x, axis=0)
        return float(np.mean(y ** 2))

    def calibrate_empty(self, window: np.ndarray) -> float:
        """Set the empty-desk baseline band energy from a known-empty window."""
        self._baseline = self._band_energy(window)
        return self._baseline

    def _occupancy(self, e_band: float) -> tuple[str, float, float]:
        """(state, ratio, confidence). First window auto-calibrates as empty."""
        if self._baseline is None:
            self._baseline = e_band
            return "empty", 1.0, 0.0
        ratio = e_band / (self._baseline + _EPS)
        lr = math.log(max(ratio, 1e-9))
        lo, hi = math.log(self.seated_ratio), math.log(self.active_ratio)
        if ratio < self.seated_ratio:
            state, margin = "empty", lo - lr
            # slow EMA adaptation of the empty baseline (thermal drift)
            self._baseline = 0.9 * self._baseline + 0.1 * e_band
        elif ratio <= self.active_ratio:
            state, margin = "seated", min(lr - lo, hi - lr)
        else:
            state, margin = "active", lr - hi
        conf = float(np.clip(margin / math.log(4.0), 0.0, 1.0))
        return state, float(ratio), conf

    # -- processing ----------------------------------------------------------

    @staticmethod
    def _motion_energy(window: np.ndarray) -> np.ndarray:
        """Per-sample motion energy: mean squared first difference."""
        x = np.asarray(window, dtype=float)
        d = np.diff(x, axis=0, prepend=x[:1])
        return (d ** 2).mean(axis=1)

    def _best_slice(self, wins: list[tuple[float, float]]
                    ) -> tuple[int, int] | None:
        if not wins:
            return None
        t0, t1 = max(wins, key=lambda w: w[1] - w[0])
        return int(round(t0 * self.fs)), int(round(t1 * self.fs))

    def process(self, window: np.ndarray, t: float | None = None) -> DeskSample:
        """Process one CSI window [t, 52]; returns a DeskSample and publishes
        `desk.occupancy` (always) and `desk.vitals` (when estimated) with
        confidence attached."""
        window = np.asarray(window, dtype=np.float32)
        dur = window.shape[0] / self.fs
        if t is None:
            t = self._t
        self._t = t + dur

        occ, ratio, occ_conf = self._occupancy(self._band_energy(window))
        if self.bus is not None:
            self.bus.publish("desk.occupancy", {
                "t": float(t), "occupancy": occ,
                "energy_ratio": round(ratio, 3), "confidence": round(occ_conf, 3),
            })

        breathing = hr = None
        if occ == "seated":
            e = self._motion_energy(window)
            sl = self._best_slice(self.windows.find(e, "breathing"))
            if sl is not None:
                breathing = self.breathing.estimate(window[sl[0]:sl[1]])
            f_breath = None
            if breathing is not None and np.isfinite(breathing.bpm) \
                    and breathing.confidence >= 0.3:
                f_breath = breathing.bpm / 60.0
            if dur >= self.thresholds.hr_min_still_s:
                slh = self._best_slice(self.windows.find(e, "hr"))
                if slh is not None:
                    hr = self.heart.estimate({0: window[slh[0]:slh[1]]}, f_breath)
            if self.bus is not None and (breathing is not None or hr is not None):
                self.bus.publish("desk.vitals", {
                    "t": float(t),
                    "breathing_bpm": None if breathing is None else round(float(breathing.bpm), 2),
                    "breathing_confidence": None if breathing is None else round(float(breathing.confidence), 3),
                    "hr_bpm": None if hr is None else round(float(hr.bpm), 2),
                    "hr_confidence": None if hr is None else round(float(hr.confidence), 3),
                })
        return DeskSample(float(t), occ, breathing, hr)

    def push(self, window: np.ndarray, t: float | None = None) -> DeskSample:
        """Streaming alias of `process` (internal clock advances per window)."""
        return self.process(window, t)
