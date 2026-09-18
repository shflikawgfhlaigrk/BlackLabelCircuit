"""M1 — TiltEngine: self-referential stress vs rule-break lead-lag.

COMPLIANCE LINE (binding): this module analyzes only the trader themself
against their own pre-committed rules; it makes zero market predictions
and touches no market data feed beyond the user's own session tape.

Operating envelope: inputs are (a) the user's own session tape — JSONL
records {ts, event: "order"|"stop_out"|"cancel"|"size_change", symbol,
size, account_risk_pct, latency_ms (user reaction latency), rule_flags:
[..]} at an injectable path or as a list of dicts — and (b) the desk
vitals history ({t, breathing_bpm, breathing_confidence, hr_bpm,
hr_confidence} dicts). Baselines are per-user, per time-of-day
(median/MAD); HR contributes only above its confidence gate. The
lead-lag estimate cross-correlates the user's OWN stress-onset series
against their OWN rule-break event train — nothing else. Honesty: below
`min_events` (default 10) rule breaks the profile is flagged
"insufficient history" and no lead-time claim is made; real trader
lead-lag numbers are subject-gated and come from real history, never
from the synthetic tests.
"""

from __future__ import annotations

import json
import time
from bisect import bisect_left, bisect_right
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

_MAD_SCALE = 1.4826
_EPS = 1e-12

#: Pre-committed rule-break precursors (config list — the user commits to
#: these up front; the engine never invents new rules mid-session).
DEFAULT_PRECURSORS = ["early_stopouts", "oversize", "impulsive_latency"]


@dataclass
class TiltState:
    """Live output: stress flag, first firing precursor (or None), risk."""

    stress: bool
    precursor: str | None
    risk: float
    detail: dict = field(default_factory=dict)


@dataclass
class TiltProfile:
    """History analysis: baselines + lead-lag with CI honesty."""

    baselines: dict
    n_events: int
    sufficient: bool
    lead_time_s: float | None   # None unless history is sufficient
    correlation: float | None   # None unless history is sufficient
    note: str
    detail: dict = field(default_factory=dict)


def _median_mad(vals) -> tuple[float, float]:
    a = np.asarray(vals, dtype=float)
    med = float(np.median(a))
    return med, float(np.median(np.abs(a - med)))


def _pearson(a: np.ndarray, b: np.ndarray) -> float:
    if a.size < 3:
        return 0.0
    sa, sb = a.std(), b.std()
    if sa < _EPS or sb < _EPS:
        return 0.0
    return float(((a - a.mean()) * (b - b.mean())).mean() / (sa * sb))


class TiltEngine:
    """Per-user physiological tilt engine over own tape + own vitals."""

    def __init__(self, tape, vitals_history, precursors: list[str] | None = None,
                 k_mad: float = 2.5, stress_sustain_s: float = 60.0,
                 grid_s: float = 10.0, roll_s: float = 60.0,
                 oversize_factor: float = 1.5, latency_factor: float = 0.5,
                 early_stopout_n: int = 2, early_hour: int = 10,
                 breathing_min_conf: float = 0.3, hr_min_conf: float = 0.6,
                 min_events: int = 10, max_lag_s: float = 600.0) -> None:
        self.tape = self._load_tape(tape)
        self.vitals = sorted((dict(v) for v in vitals_history),
                             key=lambda v: float(v["t"]))
        self.precursors = list(precursors) if precursors is not None \
            else list(DEFAULT_PRECURSORS)
        self.k_mad = float(k_mad)
        self.stress_sustain_s = float(stress_sustain_s)
        self.grid_s = float(grid_s)
        self.roll_s = float(roll_s)
        self.oversize_factor = float(oversize_factor)
        self.latency_factor = float(latency_factor)
        self.early_stopout_n = int(early_stopout_n)
        self.early_hour = int(early_hour)
        self.breathing_min_conf = float(breathing_min_conf)
        self.hr_min_conf = float(hr_min_conf)
        self.min_events = int(min_events)
        self.max_lag_s = float(max_lag_s)
        self.baselines = self._compute_baselines()
        # history medians for precursor thresholds (pre-committed rules
        # reference the user's own historical norms)
        sizes = [e["size"] for e in self.tape
                 if e.get("event") == "order" and e.get("size") is not None]
        lats = [e["latency_ms"] for e in self.tape
                if e.get("event") == "order" and e.get("latency_ms") is not None]
        self.median_size = float(np.median(sizes)) if sizes else float("nan")
        self.median_latency_ms = float(np.median(lats)) if lats else float("nan")

    # -- inputs ----------------------------------------------------------------

    @staticmethod
    def _load_tape(tape) -> list[dict]:
        if isinstance(tape, (str, Path)):
            entries = []
            with Path(tape).open(encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        entries.append(json.loads(line))
        else:
            entries = [dict(e) for e in tape]
        return sorted(entries, key=lambda e: float(e["ts"]))

    def _metric_samples(self, metric: str) -> tuple[np.ndarray, np.ndarray]:
        key, ckey, gate = {
            "breathing": ("breathing_bpm", "breathing_confidence",
                          self.breathing_min_conf),
            "hr": ("hr_bpm", "hr_confidence", self.hr_min_conf),
        }[metric]
        ts, vs = [], []
        for v in self.vitals:
            x = v.get(key)
            if x is None or not np.isfinite(x):
                continue
            if float(v.get(ckey, 0.0)) < gate:
                continue
            ts.append(float(v["t"]))
            vs.append(float(x))
        return np.asarray(ts), np.asarray(vs)

    # -- baselines (per time-of-day) --------------------------------------------

    def _compute_baselines(self) -> dict:
        out: dict = {}
        for metric in ("breathing", "hr"):
            ts, vs = self._metric_samples(metric)
            by_hour: dict[int, list[float]] = defaultdict(list)
            for t, v in zip(ts, vs):
                by_hour[time.localtime(t).tm_hour].append(v)
            hours = {h: _median_mad(v) for h, v in by_hour.items() if len(v) >= 5}
            glob = _median_mad(vs) if vs.size else (float("nan"), float("nan"))
            out[metric] = {"global": glob, "by_hour": hours, "n": int(vs.size)}
        return out

    def _baseline_for(self, metric: str, t: float) -> tuple[float, float]:
        b = self.baselines[metric]
        return b["by_hour"].get(time.localtime(t).tm_hour, b["global"])

    def _roll_z(self, metric: str, t: float, ts: np.ndarray, vs: np.ndarray,
                floor: float) -> float:
        """z of the trailing `roll_s` rolling median vs the time-of-day
        baseline (MAD units)."""
        lo = bisect_left(ts, t - self.roll_s)
        hi = bisect_right(ts, t)
        if hi - lo < 2:
            return float("nan")
        med, mad = self._baseline_for(metric, t)
        if not np.isfinite(med):
            return float("nan")
        roll = float(np.median(vs[lo:hi]))
        return (roll - med) / (_MAD_SCALE * mad + floor)

    # -- stress series ------------------------------------------------------------

    def stress_series(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """(grid_t, z_breathing, stress_bool) on a uniform `grid_s` grid.

        Stress = sustained breathing elevation (> k*MAD for the trailing
        sustain window) OR rising breathing trend + HR elevation when HR
        is confidently available.
        """
        bts, bvs = self._metric_samples("breathing")
        hts, hvs = self._metric_samples("hr")
        if bts.size == 0:
            z = np.zeros(0)
            return np.zeros(0), z, np.zeros(0, dtype=bool)
        grid = np.arange(bts[0], bts[-1] + self.grid_s, self.grid_s)
        z = np.array([self._roll_z("breathing", t, bts, bvs, 0.3) for t in grid])
        zh = np.array([self._roll_z("hr", t, hts, hvs, 2.0) for t in grid]) \
            if hts.size else np.full(grid.size, np.nan)
        zf = np.where(np.isfinite(z), z, -np.inf)
        zhf = np.where(np.isfinite(zh), zh, -np.inf)
        n_sus = max(1, int(round(self.stress_sustain_s / self.grid_s)))
        sustained = zf > self.k_mad
        for i in range(1, n_sus + 1):
            prev = np.concatenate([np.full(i, -np.inf), zf[:-i]])
            sustained &= prev > 0.7 * self.k_mad
        trend_prev = np.concatenate([np.full(n_sus, np.inf), zf[:-n_sus]])
        rising = (zf > 0.7 * self.k_mad) & (zf > trend_prev) \
            & (zhf > self.k_mad)
        return grid, z, (sustained | rising)

    # -- lead-lag learning ----------------------------------------------------------

    def _lead_lag(self, grid: np.ndarray, stress: np.ndarray,
                  break_ts: list[float]) -> tuple[float, float, dict]:
        """Cross-correlate the stress-ONSET train against the rule-break
        train. Positive lead time = stress precedes the break. Onsets are
        used (not the sustained state) so a long stress plateau does not
        smear the peak."""
        onset = np.zeros(grid.size)
        st = stress.astype(np.int8)
        idx = np.flatnonzero(np.diff(st, prepend=0) == 1)
        onset[idx] = 1.0
        brk = np.zeros(grid.size)
        for tb in break_ts:
            j = int(np.clip(np.searchsorted(grid, tb), 0, grid.size - 1))
            brk[j] = 1.0
        # gaussian smoothing (sigma = 2 bins) so near-misses still correlate
        k = np.exp(-0.5 * (np.arange(-6, 7) / 2.0) ** 2)
        k /= k.sum()
        s = np.convolve(onset, k, mode="same")
        b = np.convolve(brk, k, mode="same")
        max_lag = int(round(self.max_lag_s / self.grid_s))
        best_lag, best_corr = 0, -np.inf
        for lag in range(-max_lag, max_lag + 1):
            if lag > 0:
                c = _pearson(s[:-lag], b[lag:])
            elif lag < 0:
                c = _pearson(s[-lag:], b[:lag])
            else:
                c = _pearson(s, b)
            if c > best_corr:
                best_corr, best_lag = c, lag
        detail = {"n_onsets": int(idx.size), "n_grid": int(grid.size),
                  "grid_s": self.grid_s, "max_lag_s": self.max_lag_s}
        return best_lag * self.grid_s, float(best_corr), detail

    def analyze_history(self) -> TiltProfile:
        """Learn the user's own stress -> rule-break lead-lag from history."""
        break_ts = [float(e["ts"]) for e in self.tape if e.get("rule_flags")]
        n = len(break_ts)
        grid, _z, stress = self.stress_series()
        lead_s, corr, detail = (float("nan"), float("nan"), {})
        if grid.size and n:
            lead_s, corr, detail = self._lead_lag(grid, stress, break_ts)
        detail.update({"raw_lead_time_s": lead_s, "raw_correlation": corr})
        sufficient = n >= self.min_events and grid.size > 0
        if sufficient:
            note = (f"lead-lag from n={n} rule-break events: stress leads by "
                    f"{lead_s:.0f} s (corr {corr:.2f})")
            return TiltProfile(self.baselines, n, True, float(lead_s),
                               float(corr), note, detail)
        note = (f"insufficient history (n={n} < {self.min_events} rule-break "
                f"events) — no lead-time claim; raw numbers in detail only")
        return TiltProfile(self.baselines, n, False, None, None, note, detail)

    # -- precursors (pre-committed rules) ---------------------------------------------

    def detect_precursors(self, entries: list[dict], now_t: float) -> list[str]:
        """Which pre-committed precursors fire on `entries` as of `now_t`."""
        fired: list[str] = []
        now_lt = time.localtime(now_t)
        if "early_stopouts" in self.precursors:
            n = 0
            for e in entries:
                if e.get("event") != "stop_out":
                    continue
                lt = time.localtime(float(e["ts"]))
                if (lt.tm_year, lt.tm_yday) == (now_lt.tm_year, now_lt.tm_yday) \
                        and lt.tm_hour < self.early_hour:
                    n += 1
            if n >= self.early_stopout_n:
                fired.append("early_stopouts")
        if "oversize" in self.precursors and np.isfinite(self.median_size):
            for e in reversed(entries):
                if e.get("event") in ("order", "size_change") \
                        and e.get("size") is not None:
                    if float(e["size"]) > self.oversize_factor * self.median_size:
                        fired.append("oversize")
                    break
        if "impulsive_latency" in self.precursors \
                and np.isfinite(self.median_latency_ms):
            for e in reversed(entries):
                if e.get("latency_ms") is not None:
                    if float(e["latency_ms"]) < \
                            self.latency_factor * self.median_latency_ms:
                        fired.append("impulsive_latency")
                    break
        return fired

    # -- live -------------------------------------------------------------------------

    def live(self, t: float, vitals: list[dict], recent_tape: list[dict]
             ) -> TiltState:
        """Live tilt check at time `t` from recent own vitals + own tape."""
        samples = sorted((dict(v) for v in vitals), key=lambda v: float(v["t"]))
        bts = np.array([float(v["t"]) for v in samples
                        if v.get("breathing_bpm") is not None
                        and np.isfinite(v["breathing_bpm"])
                        and float(v.get("breathing_confidence", 0.0))
                        >= self.breathing_min_conf])
        bvs = np.array([float(v["breathing_bpm"]) for v in samples
                        if v.get("breathing_bpm") is not None
                        and np.isfinite(v["breathing_bpm"])
                        and float(v.get("breathing_confidence", 0.0))
                        >= self.breathing_min_conf])
        hts = np.array([float(v["t"]) for v in samples
                        if v.get("hr_bpm") is not None
                        and float(v.get("hr_confidence", 0.0)) >= self.hr_min_conf])
        hvs = np.array([float(v["hr_bpm"]) for v in samples
                        if v.get("hr_bpm") is not None
                        and float(v.get("hr_confidence", 0.0)) >= self.hr_min_conf])
        z_now = self._roll_z("breathing", t, bts, bvs, 0.3) if bts.size else float("nan")
        z_prev = self._roll_z("breathing", t - self.stress_sustain_s, bts, bvs, 0.3) \
            if bts.size else float("nan")
        z_hr = self._roll_z("hr", t, hts, hvs, 2.0) if hts.size else float("nan")
        sustained = (np.isfinite(z_now) and z_now > self.k_mad
                     and np.isfinite(z_prev) and z_prev > 0.7 * self.k_mad)
        rising = (np.isfinite(z_now) and z_now > 0.7 * self.k_mad
                  and np.isfinite(z_prev) and z_now > z_prev
                  and np.isfinite(z_hr) and z_hr > self.k_mad)
        stress = bool(sustained or rising)
        fired = self.detect_precursors(recent_tape, t)
        zr = 0.0 if not np.isfinite(z_now) else \
            float(np.clip(max(z_now, 0.0) / (2.0 * self.k_mad), 0.0, 1.0))
        risk = float(np.clip(0.6 * zr + 0.4 * (1.0 if fired else 0.0), 0.0, 1.0))
        detail = {"z_breathing": None if not np.isfinite(z_now) else round(z_now, 2),
                  "z_breathing_prev": None if not np.isfinite(z_prev) else round(z_prev, 2),
                  "z_hr": None if not np.isfinite(z_hr) else round(z_hr, 2),
                  "precursors": fired, "sustained": sustained, "rising": rising}
        return TiltState(stress, fired[0] if fired else None, risk, detail)
