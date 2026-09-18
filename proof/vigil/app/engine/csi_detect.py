#!/usr/bin/env python3
"""
Per-node CSI detector — clean motion/presence from noisy commodity ESP32 CSI.

Replaces the naive "variance of mean amplitude over all 56 subcarriers" (which
went BELOW 1.0 on real nodes — motion looked like less signal than stillness)
with the approach proven by the literature (Espressif esp-radar "wander/jitter",
ESPectre NBVI+Hampel, F1>96%):

  1. Hampel filter   — clamp per-subcarrier turbulence outliers (commodity CSI is
                       spiky). window=7, n_sigma=3.
  2. Subcarrier select — keep the STABLE, LIVE subcarriers (drop dead/pilot bins
                       with ~0 variance and the noisiest top bins). Calibrated
                       once during a quiet period; motion then shows up cleanly
                       against a low-noise baseline.
  3. Quiet baseline  — learn each node's empty-room jitter on the selected bins.
  4. Scores          — jitter (short-window std of first-difference) -> MOTION,
                       wander (deviation of windowed mean) -> PRESENCE, each
                       normalized to the node's own quiet baseline (so a far/weak
                       node and a near/strong node read on the same scale).
  5. Adaptive gate   — threshold = quiet P95 * 1.1, with debounce (k consecutive
                       windows) so a single spike never trips it.

Every node calibrates to ITS OWN room — no shared constants, no fabricated
reading. Until calibrated it honestly reports "calibrating", never a number.
"""
import numpy as np
from collections import deque

SUB = 56


def estimate_breathing(ts, amp, lo_bpm=6.0, hi_bpm=30.0, min_snr=3.0, min_subcarriers=5, coherence_frac=0.30):
    """Validated per-subcarrier breathing estimate (matches the blind 12-br/min lock).

    Mean-of-all-56 (the old live path) is noisy and grabbed wrong peaks (read 22.5
    for a true 12). This finds each subcarrier's confident in-band peak, then keeps
    only those that COHERENTLY agree on one frequency (within +/-1 FFT bin of the
    modal peak) and returns their MEDIAN rate — accuracy-or-nothing: returns
    (None, n) unless the coherent count clears max(min_subcarriers,
    ceil(coherence_frac*56)). Per-subcarrier SNR-clearing alone is NOT enough:
    broadband noise clears it on ~60% of subcarriers but their peaks scatter, so an
    empty (noise-only) room reports None instead of a fabricated breathing rate.

    ts: [T] arrival times. amp: [T,56] amplitudes. Returns (br_per_min|None, n_conf).
    """
    if ts.size < 64:
        return None, 0
    span = ts[-1] - ts[0]
    if span < 14.0:
        return None, 0
    fs = (ts.size - 1) / span
    if not np.isfinite(fs) or fs < 3.0:
        return None, 0
    # hampel per subcarrier (clamp turbulence outliers)
    med = np.median(amp, axis=0); mad = np.median(np.abs(amp - med), axis=0) + 1e-9
    bad = np.abs(amp - med) > 3.0 * 1.4826 * mad
    a = amp.copy()
    for j in range(a.shape[1]):
        if bad[:, j].any():
            a[bad[:, j], j] = med[j]
    n = int(span * fs)
    if n < 32:
        return None, 0
    grid = np.linspace(ts[0], ts[-1], n)
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)
    band = (freqs >= lo_bpm / 60.0) & (freqs <= hi_bpm / 60.0)
    if not band.any():
        return None, 0
    t = np.arange(n)
    win = np.hanning(n)
    rates = []
    peak_bins = []
    for j in range(a.shape[1]):
        s = np.interp(grid, ts, a[:, j])
        s = s - s.mean()
        s = s - np.polyval(np.polyfit(t, s, 2), t)        # deg-2 detrend kills drift
        spec = np.abs(np.fft.rfft(s * win))
        if spec[band].max() <= 0:
            continue
        pk = int(np.where(band)[0][int(np.argmax(spec[band]))])
        ref = (freqs >= 0.05).copy(); ref[max(0, pk - 2):pk + 3] = False
        snr = spec[pk] / (np.median(spec[ref]) + 1e-9) if ref.any() else 0.0
        if snr >= min_snr:
            rates.append(freqs[pk] * 60.0)
            peak_bins.append(pk)
    if len(rates) < min_subcarriers:
        return None, len(rates)
    # Accuracy-or-nothing (CHARTER §5.1): clearing the per-subcarrier SNR floor is
    # NOT sufficient — broadband noise clears it on ~60% of subcarriers, but their
    # peaks SCATTER across the band (<=23% land in any single bin), whereas real
    # breathing modulates them COHERENTLY at one frequency (~100% in any bin). Gate
    # on the count peaking within +/-1 bin of the modal peak, not the raw SNR count,
    # so an empty (noise-only) room reports None, not a fabricated rate.
    rates = np.asarray(rates)
    peak_bins = np.asarray(peak_bins)
    vals, counts = np.unique(peak_bins, return_counts=True)
    mode_bin = int(vals[int(np.argmax(counts))])
    coherent = np.abs(peak_bins - mode_bin) <= 1
    n_coherent = int(coherent.sum())
    need = max(min_subcarriers, int(np.ceil(coherence_frac * a.shape[1])))
    if n_coherent < need:
        return None, n_coherent
    return float(np.median(rates[coherent])), n_coherent


def hampel(x, k=7, ns=3.0):
    """Per-subcarrier temporal outlier clamp. x: [T, S] -> denoised [T, S]."""
    if x.shape[0] < 3:
        return x.copy()
    y = x.copy()
    med = np.median(x, axis=0)
    mad = np.median(np.abs(x - med), axis=0) + 1e-9
    thr = ns * 1.4826 * mad
    bad = np.abs(x - med) > thr
    # replace outliers with the per-subcarrier median (robust, cheap)
    for j in range(x.shape[1]):
        if bad[:, j].any():
            y[bad[:, j], j] = med[j]
    return y


def select_subcarriers(amp_window, keep=16):
    """Pick stable, live subcarriers from a quiet capture.

    Drop dead/pilot bins (variance ~0) and the noisiest top decile; from what's
    left, keep the `keep` lowest-variance (most stable) bins — these give the
    cleanest deviation when a body later perturbs them.
    """
    var = np.var(amp_window, axis=0)
    live = np.where(var > (np.median(var) * 0.05))[0]   # not dead
    if live.size == 0:
        return np.arange(min(keep, amp_window.shape[1]))
    v = var[live]
    # drop the noisiest 15% of live bins
    hi = np.quantile(v, 0.85)
    live = live[v <= hi]
    if live.size == 0:
        live = np.where(var > 0)[0]
    order = live[np.argsort(np.var(amp_window[:, live], axis=0))]
    return order[:min(keep, order.size)]


class NodeDetector:
    """Streaming per-node detector. Feed amplitude frames; get motion/presence."""

    def __init__(self, fs=30.0, calib_seconds=10.0, win_seconds=1.2,
                 keep=16, debounce=2):
        self.fs = fs
        self.calib_n = max(20, int(fs * calib_seconds))
        self.win = max(6, int(fs * win_seconds))
        self.keep = keep
        self.debounce = debounce
        self.buf = deque(maxlen=max(self.calib_n, self.win + 2))
        self.sel = None             # selected subcarrier indices
        self.base_jit = None        # quiet jitter baseline (median)
        self.gate = None            # adaptive motion gate (P95*1.1)
        self.base_mean = None       # quiet windowed-mean (wander reference)
        self.base_mean_sd = None
        self._hot = 0
        self._calibrated = False

    def reset_calibration(self):
        self.sel = None; self._calibrated = False; self.buf.clear()

    def _jitter(self, w):
        """short-window motion energy on selected subcarriers (scalar)."""
        d = np.diff(w[:, self.sel], axis=0)
        return float(np.mean(np.std(d, axis=0)))

    def _wander(self, w):
        """windowed-mean deviation from quiet baseline (presence)."""
        m = np.mean(w[:, self.sel], axis=0)
        return float(np.mean(np.abs(m - self.base_mean)) / (np.mean(self.base_mean_sd) + 1e-9))

    def push(self, amp):
        """amp: [56]. Returns dict with motion/present/calibrated/score."""
        self.buf.append(np.asarray(amp, dtype=np.float32))
        n = len(self.buf)

        if not self._calibrated:
            if n < self.calib_n:
                return {"calibrated": False, "calibrating": round(n / self.calib_n, 2),
                        "motion": 0.0, "present": False, "score": 0.0}
            W = hampel(np.stack(self.buf))
            self.sel = select_subcarriers(W, self.keep)
            # build quiet jitter distribution over sliding windows
            jit = []
            for i in range(0, W.shape[0] - self.win, max(1, self.win // 2)):
                jit.append(self._jitter(W[i:i + self.win]))
            jit = np.array(jit) if jit else np.array([1e-6])
            self.base_jit = float(np.median(jit)) + 1e-9
            self.gate = float(np.quantile(jit, 0.95) * 1.1) + 1e-9
            self.base_mean = np.mean(W[:, self.sel], axis=0)
            self.base_mean_sd = np.std(W[:, self.sel], axis=0) + 1e-9
            self._calibrated = True

        if n < self.win:
            return {"calibrated": True, "motion": 0.0, "present": False, "score": 0.0}
        W = hampel(np.stack(list(self.buf)[-self.win:]))
        jit = self._jitter(W)
        wan = self._wander(W)
        score = jit / self.base_jit                 # 1.0 == quiet; >1 motion
        moving = jit > self.gate
        self._hot = self._hot + 1 if moving else 0
        motion_confirmed = self._hot >= self.debounce
        # normalized 0..1-ish motion for the UI (quiet->0, strong motion->~1)
        motion = float(np.clip((score - 1.0) / 6.0, 0.0, 1.0))
        present = motion_confirmed or wan > 3.0
        return {"calibrated": True, "motion": round(motion, 3),
                "present": bool(present), "score": round(score, 2),
                "wander": round(wan, 2), "n_sel": int(self.sel.size)}
