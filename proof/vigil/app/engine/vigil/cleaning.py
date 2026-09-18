"""Cleaning stage — outlier removal, band splitting, quiet-baseline z-norm (B2).

Operating envelope (CONTRACTS.md §6):

- Input is the ingest contract: uniform 100 Hz, [t,52] float32 amplitudes.
- Hampel filter per subcarrier (window 11, 3 sigma MAD-based) suppresses
  impulse interference; vectorized via sliding_window_view, edges handled by
  reflection padding (batch) / trailing window (streaming).
- Bands: MOTION = 10 Hz order-4 Butterworth lowpass (zero-phase sosfiltfilt
  in batch; per-subcarrier sosfilt state in streaming push()); VITALS =
  0.08-0.7 Hz order-3 Butterworth bandpass (SOS).
- Quiet baseline: motion-energy proxy = mean over subcarriers of the squared
  first difference of the Hampel output, smoothed over ~0.3 s. Timesteps with
  proxy below (rolling median of proxy history) * quiet_factor are "quiet".
  The per-subcarrier baseline/MAD are medians over a *time-bounded* deque of
  trailing quiet rows (default 60 s of quiet history), so a step change in
  the room (furniture move) flushes out of the baseline within 60 s of quiet.
- z-normalization: z = (hampel(x) - baseline) / (1.4826 * MAD_quiet + eps).
  On quiet input z is approximately N(0,1) per subcarrier.
- Baselines persist per room key to `baseline_path` (npz) via
  save_baseline(room)/load_baseline(room); recalibrate(room) clears state and
  refits from whatever flows through next.
- Batch `process()` is stateful across calls only for the baseline (filters
  are zero-phase per window); streaming `push()` is fully stateful and causal
  (Hampel uses the trailing 11 rows, IIR filters carry zi state).
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from scipy.ndimage import uniform_filter1d
from scipy.signal import butter, sosfilt, sosfilt_zi, sosfiltfilt

from .frame import N_SUB

_EPS = 1e-6
_MAD_SCALE = 1.4826
# Physical floor for the quiet-MAD (in raw CSI amplitude counts). Real boards
# ship near-dead subcarriers whose quiet MAD ~ 0; without a floor the z-norm
# explodes (|z| ~ 4e7 observed on the first real capture, 2026-07-03) and
# those dead channels drown real motion. Amplitudes are integer-ish counts,
# so MAD below a quarter count is quantization noise, not signal.
_MAD_FLOOR = 0.25
_HAMPEL_WINDOW = 11
_HAMPEL_K = 3.0
_PROXY_SMOOTH_S = 0.3
_PROXY_HIST_S = 120.0     # window for the rolling-median quiet threshold
_PROXY_SUBSAMPLE = 10
_MIN_QUIET_ROWS = 50


@dataclass
class CleanResult:
    motion: np.ndarray  # [t,52] float32 — 10 Hz lowpass band
    vitals: np.ndarray  # [t,52] float32 — 0.08–0.7 Hz bandpass
    z: np.ndarray       # [t,52] float32 — quiet-baseline z-normalized


def hampel(x: np.ndarray, window: int = _HAMPEL_WINDOW, k: float = _HAMPEL_K) -> np.ndarray:
    """Vectorized per-subcarrier Hampel filter (MAD-based, reflect-padded)."""
    x = np.asarray(x, np.float32)
    t = x.shape[0]
    if t < 3:
        return x.copy()
    if t < window:
        window = t if t % 2 == 1 else t - 1
    half = window // 2
    xp = np.pad(x, ((half, half), (0, 0)), mode="reflect")
    w = sliding_window_view(xp, window, axis=0)            # [t, 52, window]
    med = np.median(w, axis=-1)
    mad = np.median(np.abs(w - med[..., None]), axis=-1)
    out = np.where(np.abs(x - med) > k * _MAD_SCALE * mad + 1e-9, med, x)
    return out.astype(np.float32)


class CleaningStage:
    def __init__(self, fs: float = 100.0, baseline_path: str | None = None,
                 quiet_factor: float = 3.0, quiet_history_s: float = 60.0) -> None:
        self.fs = float(fs)
        self.baseline_path = Path(baseline_path) if baseline_path else None
        self.quiet_factor = float(quiet_factor)
        self.quiet_history_s = float(quiet_history_s)
        self._sos_motion = butter(4, 10.0, btype="lowpass", fs=fs, output="sos")
        self._sos_vitals = butter(3, [0.08, 0.7], btype="bandpass", fs=fs, output="sos")
        # baseline state
        self.baseline: np.ndarray | None = None   # [52] float32
        self.mad: np.ndarray | None = None        # [52] float32
        self._t = 0.0                              # internal signal clock (s)
        self._prev_h: np.ndarray | None = None     # last hampel row (proxy diff)
        self._quiet_chunks: deque[tuple[float, np.ndarray]] = deque()  # (t_end, rows)
        self._proxy_hist: deque[tuple[float, float]] = deque()
        # streaming state
        self._zi_motion: np.ndarray | None = None
        self._zi_vitals: np.ndarray | None = None
        self._ham_ring = np.zeros((_HAMPEL_WINDOW, N_SUB), np.float32)
        self._ham_n = 0
        self._proxy_ema: float | None = None
        self._push_count = 0
        self._pending_quiet: list[np.ndarray] = []
        self._pending_t: float = 0.0

    # -- batch API -----------------------------------------------------------

    def process(self, window: np.ndarray) -> CleanResult:
        h = hampel(np.asarray(window, np.float32))
        motion = self._batch_filter(self._sos_motion, h)
        vitals = self._batch_filter(self._sos_vitals, h)
        self._update_baseline_batch(h)
        b, m = self._baseline_or_fallback(h)
        z = ((h - b) / (_MAD_SCALE * m + _EPS)).astype(np.float32)
        return CleanResult(motion, vitals, z)

    @staticmethod
    def _batch_filter(sos: np.ndarray, x: np.ndarray) -> np.ndarray:
        padlen = 3 * (2 * sos.shape[0] + 1)
        if x.shape[0] <= padlen:
            return sosfilt(sos, x, axis=0).astype(np.float32)
        return sosfiltfilt(sos, x, axis=0).astype(np.float32)

    def _baseline_or_fallback(self, h: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        if self.baseline is not None and self.mad is not None:
            return self.baseline, np.maximum(self.mad, _MAD_FLOOR)
        b = np.median(h, axis=0)
        m = np.median(np.abs(h - b), axis=0)
        return b.astype(np.float32), np.maximum(m, _MAD_FLOOR).astype(np.float32)

    # -- baseline estimator ----------------------------------------------------

    def _update_baseline_batch(self, h: np.ndarray) -> None:
        t_len = h.shape[0]
        if t_len == 0:
            return
        prev = self._prev_h if self._prev_h is not None else h[0]
        d = np.diff(np.vstack([prev[None, :], h]).astype(np.float64), axis=0)
        proxy = (d ** 2).mean(axis=1)
        smooth_n = max(1, int(_PROXY_SMOOTH_S * self.fs))
        proxy = uniform_filter1d(proxy, size=smooth_n, mode="nearest")
        self._prev_h = h[-1].copy()
        times = self._t + (np.arange(t_len) + 1) / self.fs
        for tt, pv in zip(times[::_PROXY_SUBSAMPLE], proxy[::_PROXY_SUBSAMPLE]):
            self._proxy_hist.append((float(tt), float(pv)))
        self._t = float(times[-1])
        self._evict_proxy_hist()
        thr = self._quiet_threshold()
        quiet = proxy < thr
        if quiet.any():
            # bucket quiet rows into ~1 s chunks so eviction is fine-grained
            # (a single monolithic chunk would flush all at once and delay
            # step-change recovery past the 60 s budget)
            q_idx = np.flatnonzero(quiet)
            q_times = times[q_idx]
            buckets = np.floor(q_times).astype(np.int64)
            for bkt in np.unique(buckets):
                sel = q_idx[buckets == bkt]
                self._quiet_chunks.append((float(times[sel[-1]]), h[sel].copy()))
        self._evict_quiet()
        self._refit_baseline()

    def _quiet_threshold(self) -> float:
        if not self._proxy_hist:
            return np.inf
        vals = np.fromiter((v for _, v in self._proxy_hist), np.float64)
        return float(np.median(vals)) * self.quiet_factor + 1e-12

    def _evict_proxy_hist(self) -> None:
        cutoff = self._t - _PROXY_HIST_S
        while self._proxy_hist and self._proxy_hist[0][0] < cutoff:
            self._proxy_hist.popleft()

    def _evict_quiet(self) -> None:
        cutoff = self._t - self.quiet_history_s
        while self._quiet_chunks and self._quiet_chunks[0][0] < cutoff:
            self._quiet_chunks.popleft()

    def _refit_baseline(self) -> None:
        if not self._quiet_chunks:
            return
        rows = np.concatenate([r for _, r in self._quiet_chunks], axis=0)
        if rows.shape[0] < _MIN_QUIET_ROWS:
            return
        b = np.median(rows, axis=0)
        self.baseline = b.astype(np.float32)
        self.mad = np.median(np.abs(rows - b), axis=0).astype(np.float32)

    # -- streaming API -----------------------------------------------------------

    def push(self, row: np.ndarray) -> CleanResult:
        """Row-wise streaming variant. Causal Hampel over the trailing 11 rows,
        IIR band filters with carried state, baseline refit every 1 s."""
        row = np.asarray(row, np.float32).reshape(N_SUB)
        # causal hampel
        self._ham_ring[self._push_count % _HAMPEL_WINDOW] = row
        self._ham_n = min(self._ham_n + 1, _HAMPEL_WINDOW)
        buf = self._ham_ring[: self._ham_n]
        med = np.median(buf, axis=0)
        mad = np.median(np.abs(buf - med), axis=0)
        h = np.where(np.abs(row - med) > _HAMPEL_K * _MAD_SCALE * mad + 1e-9, med, row)
        h = h.astype(np.float32)
        # band filters with state
        if self._zi_motion is None:
            self._zi_motion = sosfilt_zi(self._sos_motion)[:, :, None] * h[None, None, :]
            self._zi_vitals = sosfilt_zi(self._sos_vitals)[:, :, None] * h[None, None, :]
        motion, self._zi_motion = sosfilt(self._sos_motion, h[None, :], axis=0,
                                          zi=self._zi_motion)
        vitals, self._zi_vitals = sosfilt(self._sos_vitals, h[None, :], axis=0,
                                          zi=self._zi_vitals)
        # baseline bookkeeping
        self._push_count += 1
        self._t += 1.0 / self.fs
        prev = self._prev_h if self._prev_h is not None else h
        d2 = float(np.mean((h.astype(np.float64) - prev) ** 2))
        self._prev_h = h.copy()
        alpha = 1.0 / max(1.0, _PROXY_SMOOTH_S * self.fs)
        self._proxy_ema = d2 if self._proxy_ema is None else (
            (1 - alpha) * self._proxy_ema + alpha * d2)
        if self._push_count % _PROXY_SUBSAMPLE == 0:
            self._proxy_hist.append((self._t, self._proxy_ema))
            self._evict_proxy_hist()
        if self._proxy_ema < self._quiet_threshold():
            self._pending_quiet.append(h.copy())
        if self._push_count % int(self.fs) == 0 and self._pending_quiet:
            self._quiet_chunks.append((self._t, np.stack(self._pending_quiet)))
            self._pending_quiet.clear()
            self._evict_quiet()
            self._refit_baseline()
        b, m = self._baseline_or_fallback(h[None, :])
        z = ((h - b) / (_MAD_SCALE * m + _EPS)).astype(np.float32)
        return CleanResult(motion[0].astype(np.float32), vitals[0].astype(np.float32), z)

    # -- baseline persistence -------------------------------------------------------

    def save_baseline(self, room: str) -> None:
        if self.baseline_path is None:
            raise ValueError("CleaningStage has no baseline_path")
        if self.baseline is None or self.mad is None:
            raise ValueError("no baseline fitted yet")
        store: dict[str, np.ndarray] = {}
        if self.baseline_path.exists():
            with np.load(self.baseline_path) as z:
                store = {k: z[k] for k in z.files}
        store[f"{room}__baseline"] = self.baseline
        store[f"{room}__mad"] = self.mad
        self.baseline_path.parent.mkdir(parents=True, exist_ok=True)
        np.savez(self.baseline_path, **store)

    def load_baseline(self, room: str) -> bool:
        if self.baseline_path is None or not self.baseline_path.exists():
            return False
        with np.load(self.baseline_path) as z:
            bk, mk = f"{room}__baseline", f"{room}__mad"
            if bk not in z.files or mk not in z.files:
                return False
            self.baseline = z[bk].astype(np.float32)
            self.mad = z[mk].astype(np.float32)
        return True

    def recalibrate(self, room: str = "") -> None:
        """Clear the quiet baseline; it refits from whatever flows through next."""
        self.baseline = None
        self.mad = None
        self._quiet_chunks.clear()
        self._proxy_hist.clear()
        self._pending_quiet.clear()
        self._proxy_ema = None
        if room and self.baseline_path is not None and self.baseline_path.exists():
            with np.load(self.baseline_path) as z:
                store = {k: z[k] for k in z.files
                         if k not in (f"{room}__baseline", f"{room}__mad")}
            np.savez(self.baseline_path, **store)
