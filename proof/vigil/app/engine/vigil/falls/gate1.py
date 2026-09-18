"""C1 — Gate 1: cheap adaptive energy trigger on the motion-energy series.

Operating envelope: consumes a 100 Hz motion-energy series (from
SpectralStage.motion_energy, or any bandpassed-RMS equivalent). The
threshold is rolling median + `gate1_mad_k` * rolling MAD over a trailing
window (default 30 s) that *excludes* the most recent 1 s, so the burst
under evaluation cannot lift its own threshold. A crossing becomes a
Candidate only if (a) the 10%→90% rise time of the burst is under
`gate1_rise_ms`, (b) the burst peak clears the threshold with margin, and
(c) the energy stays above threshold for a minimum dwell — this is a
*recall-first* trigger; precision is Gate 2/3's job. Per-sample cost is
amortized O(1): deques plus a median/MAD refresh every `stats_stride`
samples over a bounded window. Streaming `.push()` and batch `.process()`
share one code path and return identical results on the same series.
Tuned on vigil.synth; real-hardware thresholds await recorded B4 sessions.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import numpy as np

from ..config import Thresholds


@dataclass
class Candidate:
    """Gate-1 trigger. `t` = peak time (s), `energy` = peak motion energy,
    `i0`/`i1` = indices of a ±2 s context window around the peak (i0 clamped
    to 0; i1 may exceed the current series length — callers clamp)."""

    t: float
    energy: float
    i0: int
    i1: int


class Gate1:
    def __init__(
        self,
        thresholds: Thresholds,
        fs: float = 100.0,
        window_s: float = 30.0,
        exclude_s: float = 1.0,
        eval_s: float = 1.5,
        lookback_s: float = 1.5,
        context_s: float = 2.0,
        warmup_s: float = 2.0,
        stats_stride: int = 10,
        min_above_s: float = 0.1,
        accept_margin: float = 1.5,
    ) -> None:
        self.thresholds = thresholds
        self.fs = float(fs)
        self.k = float(thresholds.gate1_mad_k)
        self.rise_ms = float(thresholds.gate1_rise_ms)
        self._kw = dict(
            window_s=window_s, exclude_s=exclude_s, eval_s=eval_s,
            lookback_s=lookback_s, context_s=context_s, warmup_s=warmup_s,
            stats_stride=stats_stride, min_above_s=min_above_s,
            accept_margin=accept_margin,
        )
        self.exclude_n = int(exclude_s * fs)
        self.eval_n = int(eval_s * fs)
        self.lookback_n = int(lookback_s * fs)
        self.context_n = int(context_s * fs)
        self.warmup_n = int(warmup_s * fs)
        self.refractory_n = int(thresholds.gate1_refractory_s * fs)
        self.stats_stride = int(stats_stride)
        self.min_above = max(1, int(min_above_s * fs))
        self.accept_margin = float(accept_margin)
        stats_n = max(self.warmup_n, int((window_s - exclude_s) * fs))
        # state
        self._delay: deque[float] = deque()                     # last `exclude_s` of samples
        self._stats: deque[float] = deque(maxlen=stats_n)       # trailing stats window
        self._hist: deque[float] = deque(maxlen=self.lookback_n)  # pre-crossing history
        self._median = 0.0
        self._mad = 0.0
        self._ready = False
        self._prev: float | None = None
        self._refractory_until = -1
        self._pending: dict | None = None
        self._n = 0

    # -- streaming ---------------------------------------------------------

    def push(self, value: float) -> Candidate | None:
        """Feed one motion-energy sample; returns a Candidate when a burst
        that started ~`eval_s` earlier is accepted (decision latency ≈
        eval_s minus time-to-peak)."""
        v = float(value)
        i = self._n
        out: Candidate | None = None
        thr = self.threshold
        if self._pending is not None:
            self._pending["buf"].append(v)
            if len(self._pending["buf"]) >= self.eval_n:
                out = self._finalize(i)
        elif (
            self._ready
            and i >= self._refractory_until
            and self._prev is not None
            and self._prev <= thr < v
        ):
            self._pending = {
                "cross": i,
                "thr": thr,
                "base": self._median,
                "pre": list(self._hist),
                "buf": [v],
            }
        # bookkeeping (current sample enters the stats window only after
        # the exclude_s delay, so the burst can't lift its own threshold)
        self._hist.append(v)
        self._delay.append(v)
        if len(self._delay) > self.exclude_n:
            self._stats.append(self._delay.popleft())
        if len(self._stats) >= self.warmup_n and (
            not self._ready or i % self.stats_stride == 0
        ):
            arr = np.asarray(self._stats)
            self._median = float(np.median(arr))
            self._mad = float(np.median(np.abs(arr - self._median)))
            self._ready = True
        self._prev = v
        self._n += 1
        return out

    def flush(self) -> Candidate | None:
        """Finalize a pending evaluation at end-of-series (needs >=0.5 s of
        post-crossing samples, else the pending burst is discarded)."""
        if self._pending is not None and len(self._pending["buf"]) >= int(0.5 * self.fs):
            return self._finalize(self._n)
        self._pending = None
        return None

    @property
    def threshold(self) -> float:
        """Current adaptive threshold (inf until warmed up)."""
        if not self._ready:
            return math.inf
        return self._median + self.k * max(self._mad, 1e-9)

    # -- batch --------------------------------------------------------------

    def process(self, motion_energy: np.ndarray) -> list[Candidate]:
        """Batch API: run a fresh detector over the whole series. Identical
        results to streaming push()+flush() on the same series (shared code
        path); does not disturb this instance's streaming state."""
        g = Gate1(self.thresholds, fs=self.fs, **self._kw)
        out: list[Candidate] = []
        for v in np.asarray(motion_energy, dtype=float):
            c = g.push(v)
            if c is not None:
                out.append(c)
        c = g.flush()
        if c is not None:
            out.append(c)
        return out

    # -- internals -----------------------------------------------------------

    def _finalize(self, i: int) -> Candidate | None:
        p = self._pending
        assert p is not None
        self._pending = None
        self._refractory_until = i + self.refractory_n
        buf = np.asarray(p["buf"])
        pre = np.asarray(p["pre"]) if p["pre"] else np.zeros(0)
        peak_rel = int(np.argmax(buf))
        peak = float(buf[peak_rel])
        base = float(p["base"])
        thr = float(p["thr"])
        amp = peak - base
        if amp <= 0:
            return None
        # peak must clear the threshold with margin (kills grazing noise)
        if peak < base + self.accept_margin * (thr - base):
            return None
        # minimum dwell above threshold
        if int(np.sum(buf >= thr)) < self.min_above:
            return None
        # 10% -> 90% rise time, walking back from the peak
        arr = np.concatenate([pre, buf])
        pk = len(pre) + peak_rel
        lvl90 = base + 0.9 * amp
        lvl10 = base + 0.1 * amp
        j = pk
        while j > 0 and arr[j - 1] >= lvl90:
            j -= 1
        i90 = j
        while j > 0 and arr[j - 1] >= lvl10:
            j -= 1
        i10 = j
        if i10 == 0 and arr[0] >= lvl10:
            # never below 10% inside the lookback: slow ramp, unbounded rise
            rise_s = math.inf
        else:
            rise_s = (i90 - i10) / self.fs
        if rise_s * 1000.0 >= self.rise_ms:
            return None
        peak_idx = p["cross"] + peak_rel
        return Candidate(
            t=peak_idx / self.fs,
            energy=peak,
            i0=max(0, peak_idx - self.context_n),
            i1=peak_idx + self.context_n,
        )
