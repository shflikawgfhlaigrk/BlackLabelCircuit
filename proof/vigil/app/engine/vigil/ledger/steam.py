"""M2 — Steam / hot-water attenuation channel (slow timescale).

Operating envelope: detects the sustained RF attenuation signature of steam
and hot-water use (shower, pot boiling) on [t,52] float32 CSI amplitude at
fs=100 Hz. This is a *minutes*-timescale channel, deliberately distinct from
the motion band (0.5-10 Hz) and below the breathing band (>0.1 Hz):

- features are computed on 1 s decimated blocks;
- the current level is a <0.02 Hz trend (trailing moving median over
  ``trend_win_s`` >= 50 s of block means);
- (a) sustained mean-amplitude attenuation drop vs a rolling *pre-window*
  baseline (median of clean blocks ``baseline_lag_s``..``baseline_span_s``
  ago, frozen while a candidate is active), and
- (b) rise in high-band scatter variance (per-block temporal variance of the
  upper-subcarrier mean) corroborate the detection.

Confidence-gated per the D4 pattern (vitals/gating.py): only events with
duration >= ``min_duration_s`` (3 min) sustained AND an effect size vs the
baseline MAD above the bar are emitted; below-bar activity is tracked in
``.suppressed`` but never reported. A person walking drives motion-band
energy high and vetoes the block (steam must not be inferred while the mean
shift could be occupancy); veto counts are carried in the event detail.

Emitted events publish bus topic ``ledger.steam``
{room, t0, t1, confidence} — scalars only, EventLog-safe.

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification.

Hardware note: real-shower validation is hardware-gated; the synthetic
generators in ledger/synth.py model the phenomenology only.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import numpy as np

STEAM_TOPIC = "ledger.steam"

HIGH_BAND = slice(26, 52)  # upper half of the 52 information subcarriers


@dataclass
class SteamEvent:
    """One detected steam episode. t0/t1 in seconds on the stream clock."""

    t0: float
    t1: float
    kind: str = "steam"
    confidence: float = 0.0
    detail: dict = field(default_factory=dict)


class SteamDetector:
    """Streaming + batch detector for the slow steam-attenuation channel.

    ``push(row_or_block)`` accepts a single [52] row or an [n,52] block of
    CSI amplitude at ``fs`` and returns any newly *emitted* (above-bar)
    SteamEvents. ``process(window)`` is the batch variant on a fresh state.
    Below-bar candidates land in ``.suppressed`` (D4: track internally,
    never report).

    Privacy by design: stores derived events only (room, timestamps,
    confidence, scalar detail) — zero raw CSI, zero images by construction;
    household members must be informed; person-tags are opt-in deployment
    labels, not covert biometric identification.
    """

    def __init__(self, fs: float = 100.0, *, bus=None, room: str = "",
                 trend_win_s: float = 61.0, baseline_lag_s: float = 90.0,
                 baseline_span_s: float = 360.0, baseline_min_blocks: int = 30,
                 drop_k: float = 4.0, min_drop: float = 1.0,
                 mad_floor: float = 0.05, min_duration_s: float = 180.0,
                 close_hysteresis_s: float = 10.0, veto_ratio: float = 3.0,
                 veto_abs: float = 2.5, confidence_bar: float = 0.5) -> None:
        self.fs = float(fs)
        self.bus = bus
        self.room = room
        self.trend_win = max(3, int(round(trend_win_s)))
        self.baseline_lag = int(round(baseline_lag_s))
        self.baseline_span = int(round(baseline_span_s))
        self.baseline_min_blocks = int(baseline_min_blocks)
        self.drop_k = float(drop_k)
        self.min_drop = float(min_drop)
        self.mad_floor = float(mad_floor)
        self.min_duration_s = float(min_duration_s)
        self.close_hyst = max(1, int(round(close_hysteresis_s)))
        self.veto_ratio = float(veto_ratio)
        self.veto_abs = float(veto_abs)
        self.confidence_bar = float(confidence_bar)

        self.block_len = max(1, int(round(self.fs)))  # 1 s decimation
        self.events: list[SteamEvent] = []
        self.suppressed: list[SteamEvent] = []

        self._rows: list[np.ndarray] = []
        self._n_rows = 0
        self._i = 0  # completed 1 s blocks
        self._trend: deque[float] = deque(maxlen=self.trend_win)
        # clean (no candidate active, not vetoed) blocks: (i, m, scatter, motion)
        self._clean: deque[tuple[int, float, float, float]] = deque(
            maxlen=self.baseline_span + self.baseline_lag + 8)
        # short-median mean history for boundary refinement: (i, m3)
        self._m_hist: deque[tuple[int, float]] = deque(maxlen=2400)
        self._m3: deque[float] = deque(maxlen=3)
        self._base: dict | None = None  # {baseline, mad, scatter, motion}
        self._run: dict | None = None

    # -- public API ---------------------------------------------------------

    def push(self, x) -> list[SteamEvent]:
        """Feed one [52] row or an [n,52] block; returns newly emitted events."""
        x = np.asarray(x, dtype=np.float32)
        if x.ndim == 1:
            x = x[None, :]
        if x.ndim != 2:
            raise ValueError(f"expected [52] row or [n,52] block, got shape {x.shape}")
        self._rows.append(x)
        self._n_rows += x.shape[0]
        n_before = len(self.events)
        while self._n_rows >= self.block_len:
            buf = np.concatenate(self._rows, axis=0)
            block, rest = buf[: self.block_len], buf[self.block_len:]
            self._rows = [rest] if rest.size else []
            self._n_rows = rest.shape[0] if rest.size else 0
            self._block(block)
        return self.events[n_before:]

    def process(self, window: np.ndarray) -> list[SteamEvent]:
        """Batch: run the identical causal stream over `window` [t,52] on a
        fresh detector state and return the emitted events."""
        d = SteamDetector(
            self.fs, bus=self.bus, room=self.room,
            trend_win_s=self.trend_win, baseline_lag_s=self.baseline_lag,
            baseline_span_s=self.baseline_span,
            baseline_min_blocks=self.baseline_min_blocks, drop_k=self.drop_k,
            min_drop=self.min_drop, mad_floor=self.mad_floor,
            min_duration_s=self.min_duration_s,
            close_hysteresis_s=self.close_hyst, veto_ratio=self.veto_ratio,
            veto_abs=self.veto_abs, confidence_bar=self.confidence_bar)
        d.push(window)
        d.flush()
        self.suppressed.extend(d.suppressed)
        self.events.extend(d.events)
        return list(d.events)

    def flush(self) -> list[SteamEvent]:
        """Close any candidate still open at end of stream."""
        n_before = len(self.events)
        if self._run is not None:
            self._close_run(self._i)
        return self.events[n_before:]

    # -- internals ------------------------------------------------------------

    def _block(self, block: np.ndarray) -> None:
        i = self._i
        m = float(block.mean())
        hi = block[:, HIGH_BAND].mean(axis=1)
        scatter = float(hi.var())
        motion = float(block.std(axis=0).mean())  # motion-band proxy at 1 Hz

        self._m3.append(m)
        self._m_hist.append((i, float(np.median(self._m3))))
        self._trend.append(m)
        trend = float(np.median(self._trend)) if len(self._trend) == self.trend_win else None

        # rolling pre-window baseline from clean, lagged blocks (held while
        # too few candidates — this freezes it through a long steam episode)
        cand = [c for c in self._clean
                if i - self.baseline_span <= c[0] <= i - self.baseline_lag]
        if self._run is None and len(cand) >= self.baseline_min_blocks:
            ms = np.array([c[1] for c in cand])
            baseline = float(np.median(ms))
            self._base = {
                "baseline": baseline,
                "mad": max(float(np.median(np.abs(ms - baseline))), self.mad_floor),
                "scatter": max(float(np.median([c[2] for c in cand])), 1e-9),
                "motion": float(np.median([c[3] for c in cand])),
            }

        base = self._base
        veto = base is not None and motion > max(self.veto_abs,
                                                 self.veto_ratio * base["motion"])
        thresh = (max(self.drop_k * base["mad"], self.min_drop)
                  if base is not None else None)
        cond = (base is not None and trend is not None and not veto
                and (base["baseline"] - trend) >= thresh)

        if cond:
            if self._run is None:
                self._run = {"open_i": i, "last_true": i, "drops": [],
                             "scatters": [], "veto_blocks": 0, "miss": 0,
                             "base": dict(base)}
            r = self._run
            r["last_true"] = i
            r["miss"] = 0
            r["drops"].append(r["base"]["baseline"] - m)
            r["scatters"].append(scatter / r["base"]["scatter"])
        elif self._run is not None:
            r = self._run
            r["miss"] += 1
            if veto:
                r["veto_blocks"] += 1
            if r["miss"] > self.close_hyst:
                self._close_run(i)

        if self._run is None and not veto:
            self._clean.append((i, m, scatter, motion))
        self._i = i + 1

    def _close_run(self, i_now: int) -> None:
        r, self._run = self._run, None
        assert r is not None
        base = r["base"]
        floor = base["baseline"] - self.min_drop
        hist = dict(self._m_hist)
        # refine boundaries on the short-median mean: expand the run outward
        # while the mean stays >= min_drop below the pre-window baseline.
        i0 = r["open_i"]
        while (i0 - 1) in hist and hist[i0 - 1] <= floor:
            i0 -= 1
        i1 = r["last_true"]
        while (i1 + 1) in hist and (i1 + 1) < i_now and hist[i1 + 1] <= floor:
            i1 += 1
        # the trend lags on recovery: shrink back to the last block that was
        # actually attenuated >= min_drop below baseline
        while i1 > i0 and hist.get(i1, floor - 1.0) > floor:
            i1 -= 1
        t0, t1 = i0 * 1.0, (i1 + 1) * 1.0  # 1 s blocks
        duration = t1 - t0
        med_drop = float(np.median(r["drops"])) if r["drops"] else 0.0
        effect = med_drop / base["mad"]
        scat_ratio = float(np.median(r["scatters"])) if r["scatters"] else 1.0
        n_blocks = len(r["drops"])
        veto_frac = r["veto_blocks"] / max(1, n_blocks + r["veto_blocks"])
        confidence = float(np.clip(
            0.45 * min(1.0, effect / (3.0 * self.drop_k))
            + 0.25 * min(1.0, max(0.0, scat_ratio - 1.0) / 2.0)
            + 0.30 * min(1.0, duration / 600.0), 0.0, 1.0))
        ev = SteamEvent(t0=t0, t1=t1, kind="steam", confidence=confidence,
                        detail={"drop": round(med_drop, 3),
                                "effect": round(effect, 2),
                                "scatter_ratio": round(scat_ratio, 2),
                                "duration_s": duration,
                                "n_blocks": n_blocks,
                                "veto_blocks": r["veto_blocks"],
                                "baseline": round(base["baseline"], 3),
                                "baseline_mad": round(base["mad"], 4)})
        qualifies = (duration >= self.min_duration_s
                     and med_drop >= max(self.drop_k * base["mad"], self.min_drop)
                     and veto_frac < 0.3
                     and confidence >= self.confidence_bar)
        if qualifies:
            self.events.append(ev)
            if self.bus is not None:
                self.bus.publish(STEAM_TOPIC, {"room": self.room, "t0": t0,
                                               "t1": t1,
                                               "confidence": confidence})
        else:
            self.suppressed.append(ev)  # tracked internally, never reported
