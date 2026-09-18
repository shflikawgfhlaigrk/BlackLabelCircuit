"""D2 — Breathing-rate extractor (respiration band 0.08–0.7 Hz).

Operating envelope: raw CSI amplitude windows [t, 52] float32 at fs=100 Hz,
taken from a qualifying still window (≥30 s, see windows.py) with the
subject within a few metres of a node. Accuracy is NOT gated here — D4
gates display on the confidence this module reports. Real-subject MAE
numbers come from recorded reference sessions, not from the synthetic tests.

Pipeline
--------
1. Per-subcarrier linear detrend, decimate to 10 Hz, band-pass 0.08–0.7 Hz
   (Butterworth SOS, zero-phase filtfilt).
2. Per-subcarrier periodicity score = in-band Welch PSD peak / in-band
   median (peak prominence SNR); pick the top-k (k=8) subcarriers.
3. Combine the k normalized filtered signals into one respiration signal.
   A plain mean can cancel (subcarriers carry the same frequency at random
   phases), so the combination is the first principal component of the
   normalized stack, sign-aligned to the best subcarrier — a phase-robust
   weighted average.
4. Primary path: Welch PSD of the combined signal (nperseg ≈ 30 s capped to
   the window), dominant in-band peak refined by parabolic interpolation of
   the log-PSD -> bpm_psd. Peak tracking over overlapping 20 s subwindows
   (10 s hop) gives a stability measure.
5. Secondary path: VMD (vmd.py, k=4) of the combined signal; the mode with
   an in-band center frequency and the highest in-band energy concentration
   is selected and its PSD peak gives bpm_vmd.
6. Report: |bpm_psd - bpm_vmd| <= 2 -> bpm = median of both, high
   confidence; else bpm = bpm_psd with reduced confidence.

Confidence formula (documented, all terms in [0, 1]):

    snr_term   = snr / (snr + 10)          snr = PSD peak / in-band median
    agree_term = 1                          if |Δbpm| <= 2
               = max(0, 1 - (|Δbpm|-2)/6)   otherwise (0 at Δ >= 8)
    band_term  = in-band power fraction of the selected (unfiltered)
                 subcarriers over 0.03–5 Hz
    stability  = 1 / (1 + 0.15 * max(0, std(track_bpm) - 1))

    confidence = clip((0.5*snr_term + 0.3*agree_term + 0.2*band_term)
                      * stability, 0, 1)
"""

from __future__ import annotations

import numpy as np
from scipy import signal

from .gating import VitalsEstimate  # re-export per CONTRACTS §8
from .vmd import vmd

__all__ = ["BreathingExtractor", "VitalsEstimate"]

BAND = (0.08, 0.7)  # Hz, respiration
TOP_K = 8
_EPS = 1e-12


def _psd_peak(f: np.ndarray, p: np.ndarray, lo: float, hi: float
              ) -> tuple[float, float]:
    """(peak_freq, snr) of the dominant in-band PSD peak with parabolic
    interpolation of the log-PSD; snr = peak / in-band median."""
    band = (f >= lo) & (f <= hi)
    fb, pb = f[band], p[band]
    if fb.size == 0:
        return float("nan"), 0.0
    i = int(np.argmax(pb))
    fpk = float(fb[i])
    if 0 < i < pb.size - 1:
        y0, y1, y2 = np.log(pb[i - 1: i + 2] + _EPS)
        denom = y0 - 2.0 * y1 + y2
        if abs(denom) > _EPS:
            d = float(np.clip(0.5 * (y0 - y2) / denom, -0.5, 0.5))
            fpk += d * float(fb[1] - fb[0]) if fb.size > 1 else 0.0
    snr = float(pb[i] / (np.median(pb) + _EPS))
    return fpk, snr


def _combine(sigs: np.ndarray) -> np.ndarray:
    """Phase-robust combination of [k, n] signals: first principal
    component of the unit-variance stack, sign-aligned to row 0."""
    s = sigs / (sigs.std(axis=1, keepdims=True) + _EPS)
    u, sv, _ = np.linalg.svd(s.T, full_matrices=False)
    pc = u[:, 0] * sv[0]
    if float(pc @ s[0]) < 0:
        pc = -pc
    return pc


def _vmd_band_freq(x: np.ndarray, fs: float, lo: float, hi: float,
                   k: int = 4) -> tuple[float, list[float]]:
    """VMD path: dominant frequency of the in-band mode with the highest
    in-band energy concentration. Returns (freq_hz or nan, center_freqs)."""
    modes, cfs = vmd(x, k=k, alpha=2000.0, fs=fs)
    best, best_score = None, -1.0
    for i, cf in enumerate(cfs):
        if not (lo <= cf <= hi):
            continue
        f, p = signal.welch(modes[i], fs=fs,
                            nperseg=min(modes.shape[1], int(30 * fs)))
        tot = float(p.sum()) + _EPS
        conc = float(p[(f >= lo) & (f <= hi)].sum()) / tot
        energy = float(np.sum(modes[i] ** 2))
        score = conc * energy
        if score > best_score:
            best_score, best = score, i
    if best is None:
        return float("nan"), [float(c) for c in cfs]
    f, p = signal.welch(modes[best], fs=fs,
                        nperseg=min(modes.shape[1], int(30 * fs)))
    fpk, _ = _psd_peak(f, p, lo, hi)
    if not np.isfinite(fpk):
        fpk = float(cfs[best])
    return fpk, [float(c) for c in cfs]


class BreathingExtractor:
    """Breathing-rate estimator over a still-window [t, 52] at fs=100."""

    def __init__(self, fs: float = 100.0) -> None:
        self.fs = fs
        self._q = max(1, int(round(fs / 10.0)))
        self.fs_d = fs / self._q

    def estimate(self, window: np.ndarray) -> VitalsEstimate:
        try:
            return self._estimate(np.asarray(window, dtype=float))
        except Exception as exc:  # never raise on poor signal
            return VitalsEstimate(float("nan"), 0.0, {"error": repr(exc)})

    # -----------------------------------------------------------------

    def _estimate(self, x: np.ndarray) -> VitalsEstimate:
        fs_d = self.fs_d
        xd = signal.detrend(x, axis=0)
        y = signal.decimate(xd, self._q, axis=0, zero_phase=True) \
            if self._q > 1 else xd
        n = y.shape[0]
        sos = signal.butter(4, BAND, btype="bandpass", fs=fs_d, output="sos")
        yf = signal.sosfiltfilt(sos, y, axis=0)

        # Per-subcarrier periodicity score.
        nps = min(n, int(30 * fs_d))
        f, p = signal.welch(yf, fs=fs_d, nperseg=nps, axis=0)
        band = (f >= BAND[0]) & (f <= BAND[1])
        pb = p[band]
        scores = pb.max(axis=0) / (np.median(pb, axis=0) + _EPS)
        top = np.argsort(scores)[-TOP_K:][::-1]

        comb = _combine(yf[:, top].T)

        # Primary path: Welch peak of the combined signal.
        fc, pc = signal.welch(comb, fs=fs_d, nperseg=nps)
        f_psd, snr = _psd_peak(fc, pc, *BAND)
        bpm_psd = 60.0 * f_psd

        # Peak tracking over overlapping subwindows.
        sub = int(20 * fs_d)
        hop = int(10 * fs_d)
        track: list[float] = []
        if n >= sub + hop:
            for i0 in range(0, n - sub + 1, hop):
                fw, pw = signal.welch(comb[i0: i0 + sub], fs=fs_d, nperseg=sub)
                fpk, _ = _psd_peak(fw, pw, *BAND)
                if np.isfinite(fpk):
                    track.append(60.0 * fpk)
        track_std = float(np.std(track)) if len(track) >= 2 else 0.0

        # Secondary path: VMD.
        f_vmd, cfs = _vmd_band_freq(comb, fs_d, *BAND)
        bpm_vmd = 60.0 * f_vmd if np.isfinite(f_vmd) else float("nan")

        # Vote.
        delta = abs(bpm_psd - bpm_vmd) if np.isfinite(bpm_vmd) else float("inf")
        if delta <= 2.0:
            bpm = float(np.median([bpm_psd, bpm_vmd]))
            agree_term, path = 1.0, "agree"
        else:
            bpm = float(bpm_psd)
            agree_term = max(0.0, 1.0 - (min(delta, 1e6) - 2.0) / 6.0)
            path = "psd-only"

        # In-band power fraction of the selected subcarriers (unfiltered).
        fw, pw = signal.welch(y[:, top], fs=fs_d, nperseg=nps, axis=0)
        pm = pw.mean(axis=1)
        total = float(pm[(fw >= 0.03) & (fw <= 5.0)].sum()) + _EPS
        band_ratio = float(pm[(fw >= BAND[0]) & (fw <= BAND[1])].sum()) / total

        snr_term = snr / (snr + 10.0)
        stability = 1.0 / (1.0 + 0.15 * max(0.0, track_std - 1.0))
        confidence = float(np.clip(
            (0.5 * snr_term + 0.3 * agree_term + 0.2 * band_ratio) * stability,
            0.0, 1.0))

        detail = {
            "bpm_psd": float(bpm_psd),
            "bpm_vmd": float(bpm_vmd),
            "delta_bpm": float(delta) if np.isfinite(delta) else None,
            "path": path,
            "subcarriers": [int(k) for k in top],
            "snr": float(snr),
            "band_ratio": band_ratio,
            "track_bpm": [round(v, 2) for v in track],
            "track_std": track_std,
            "vmd_center_freqs_hz": [round(c, 4) for c in cfs],
            "f_hz": float(bpm / 60.0),
        }
        return VitalsEstimate(float(bpm), confidence, detail)
