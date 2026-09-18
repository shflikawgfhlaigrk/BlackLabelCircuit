"""D1 — Stationarity detector + vitals window manager.

Operating envelope: consumes the motion-energy series produced by the
spectral stage (any non-negative per-sample activity measure at fs) and
finds "qualifying windows" — maximal runs where the subject is still enough
for vitals extraction. Stillness is judged against a *rolling quiet level*:
the trailing median of the lower half of recent 1-s block energies (robust
to bursts occupying up to half the trailing history). A sample qualifies
when energy < `Thresholds.quiet_energy_factor` × quiet level; a run
qualifies when it lasts ≥ `breathing_min_still_s` (kind="breathing") or
≥ `hr_min_still_s` (kind="hr").

Fully causal: the quiet level for a sample uses only completed blocks
strictly before it, so streaming `push()` and batch `find()` produce
identical windows (find() runs the same stream internally). The first block
(1 s) is never qualifying — no quiet level exists yet.
"""

from __future__ import annotations

from collections import deque
from typing import Iterable

import numpy as np

BLOCK_S = 1.0          # quiet-level block length
HISTORY_BLOCKS = 120   # trailing history for the rolling quiet level


class _QuietStream:
    """Causal stillness stream for one window kind."""

    def __init__(self, factor: float, min_s: float, fs: float) -> None:
        self.factor = factor
        self.min_s = min_s
        self.fs = fs
        self.block_len = max(1, int(round(BLOCK_S * fs)))
        self._block: list[float] = []
        self._blocks: deque[float] = deque(maxlen=HISTORY_BLOCKS)
        self.quiet: float | None = None
        self._run_t0: float | None = None
        self._opened = False
        self.last_t: float | None = None

    def _update_quiet(self, e: float) -> None:
        self._block.append(e)
        if len(self._block) >= self.block_len:
            self._blocks.append(float(np.median(self._block)))
            self._block = []
            lo = sorted(self._blocks)[: max(1, len(self._blocks) // 2)]
            self.quiet = float(np.median(lo))

    def push(self, t: float, e: float) -> list[dict]:
        events: list[dict] = []
        ok = self.quiet is not None and e < self.factor * self.quiet
        if ok:
            if self._run_t0 is None:
                self._run_t0 = t
                self._opened = False
            if not self._opened and (t - self._run_t0) >= self.min_s:
                self._opened = True
                events.append({"event": "open", "t0": self._run_t0})
        else:
            events.extend(self._close(t))
        self._update_quiet(e)
        self.last_t = t
        return events

    def _close(self, t_end: float) -> list[dict]:
        events: list[dict] = []
        if self._run_t0 is not None and (t_end - self._run_t0) >= self.min_s:
            events.append({"event": "close", "t0": self._run_t0, "t1": t_end})
        self._run_t0 = None
        self._opened = False
        return events

    def flush(self, t_end: float | None = None) -> list[dict]:
        if t_end is None:
            t_end = (self.last_t + 1.0 / self.fs) if self.last_t is not None else 0.0
        return self._close(t_end)


class WindowManager:
    """Finds/streams qualifying vitals windows from motion energy (§8)."""

    def __init__(self, thresholds, fs: float = 100.0) -> None:
        self.thresholds = thresholds
        self.fs = fs
        self._streams: dict[str, _QuietStream] = {}

    def _min_s(self, kind: str) -> float:
        if kind == "breathing":
            return float(self.thresholds.breathing_min_still_s)
        if kind == "hr":
            return float(self.thresholds.hr_min_still_s)
        raise ValueError(f"unknown window kind {kind!r}")

    def _new_stream(self, kind: str) -> _QuietStream:
        return _QuietStream(float(self.thresholds.quiet_energy_factor),
                            self._min_s(kind), self.fs)

    # -- batch -------------------------------------------------------------

    def find(self, motion_energy: np.ndarray, kind: str = "breathing",
             quiet_level: float | np.ndarray | None = None
             ) -> list[tuple[float, float]]:
        """Qualifying windows as [(t0, t1)] in seconds.

        If `quiet_level` (scalar or per-sample array) is given it is used
        directly; otherwise the rolling quiet level is computed causally."""
        e = np.asarray(motion_energy, dtype=float).ravel()
        min_s = self._min_s(kind)
        if quiet_level is not None:
            mask = e < float(self.thresholds.quiet_energy_factor) * np.asarray(
                quiet_level, dtype=float)
            return _runs_from_mask(mask, self.fs, min_s)
        st = self._new_stream(kind)
        wins: list[tuple[float, float]] = []
        for i, v in enumerate(e):
            for ev in st.push(i / self.fs, float(v)):
                if ev["event"] == "close":
                    wins.append((ev["t0"], ev["t1"]))
        for ev in st.flush(e.size / self.fs):
            if ev["event"] == "close":
                wins.append((ev["t0"], ev["t1"]))
        return wins

    def coverage(self, motion_energy: np.ndarray, kind: str = "breathing") -> float:
        """Fraction of total time inside qualifying windows (nightly summary)."""
        e = np.asarray(motion_energy, dtype=float).ravel()
        if e.size == 0:
            return 0.0
        total = e.size / self.fs
        covered = sum(t1 - t0 for t0, t1 in self.find(e, kind))
        return float(covered / total)

    # -- streaming ----------------------------------------------------------

    def push(self, t: float, energy: float, kind: str = "breathing") -> list[dict]:
        """Streaming variant: feed one (t, energy) sample; returns 0..n
        window events {"event": "open"|"close", "t0": ..[, "t1": ..]}."""
        if kind not in self._streams:
            self._min_s(kind)  # validate
            self._streams[kind] = self._new_stream(kind)
        return self._streams[kind].push(float(t), float(energy))

    def flush(self, kind: str = "breathing", t_end: float | None = None) -> list[dict]:
        """Close any still-open run at end of stream; returns close events."""
        if kind not in self._streams:
            return []
        return self._streams[kind].flush(t_end)

    def reset(self) -> None:
        self._streams.clear()


# -- validation helpers ------------------------------------------------------


def _runs_from_mask(mask: np.ndarray, fs: float, min_s: float
                    ) -> list[tuple[float, float]]:
    wins: list[tuple[float, float]] = []
    m = np.asarray(mask, dtype=bool)
    if m.size == 0:
        return wins
    edges = np.flatnonzero(np.diff(m.astype(np.int8)))
    starts = list(edges[~m[edges]] + 1)
    ends = list(edges[m[edges]] + 1)
    if m[0]:
        starts = [0] + starts
    if m[-1]:
        ends = ends + [m.size]
    for i0, i1 in zip(starts, ends):
        if (i1 - i0) / fs >= min_s:
            wins.append((i0 / fs, i1 / fs))
    return wins


def _as_intervals(items: Iterable) -> list[tuple[float, float]]:
    out = []
    for it in items:
        if hasattr(it, "t0") and hasattr(it, "t1"):
            out.append((float(it.t0), float(it.t1)))
        else:
            out.append((float(it[0]), float(it[1])))
    return _merge(out)


def _merge(intervals: list[tuple[float, float]]) -> list[tuple[float, float]]:
    merged: list[list[float]] = []
    for t0, t1 in sorted(intervals):
        if merged and t0 <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], t1)
        else:
            merged.append([t0, t1])
    return [(a, b) for a, b in merged]


def agreement(windows: Iterable, labels: Iterable) -> float:
    """Jaccard agreement between qualifying windows and labeled still
    segments: |windows ∩ labels| / |windows ∪ labels| (in seconds).

    `labels` may be (t0, t1) tuples or objects with .t0/.t1 (session.Label).
    Returns 1.0 when both are empty."""
    w = _as_intervals(windows)
    lb = _as_intervals(labels)
    len_w = sum(b - a for a, b in w)
    len_l = sum(b - a for a, b in lb)
    inter = 0.0
    for a0, a1 in w:
        for b0, b1 in lb:
            inter += max(0.0, min(a1, b1) - max(a0, b0))
    union = len_w + len_l - inter
    return float(inter / union) if union > 0 else 1.0
