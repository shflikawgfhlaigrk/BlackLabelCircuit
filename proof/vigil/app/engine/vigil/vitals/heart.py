"""D3 — Heart-rate extractor (cardiac band 0.8–2.2 Hz). Frontier module.

Operating envelope: this is the frontier of what amplitude-only CSI can do.
It expects a node ≤ 1.5 m from a *still* subject (bed geometry) and windows
of ≥ 60 s at fs=100. Accuracy is NOT gated here — D4 gates display on the
confidence reported below, and the honest failure mode is a low-confidence
estimate, never an exception: `.estimate` ALWAYS returns a VitalsEstimate,
even on pure noise (bpm = best guess, confidence ≈ 0).

Stack
-----
1. If f_breath (Hz) is known, notch out f_breath and its 2nd/3rd harmonics
   per subcarrier (iirnotch cascade, Q≈8) — breathing harmonics are the
   dominant in-band contaminant (e.g. 18 bpm × 3 = 0.9 Hz).
2. Band-pass 0.8–2.2 Hz (Butterworth SOS, zero-phase).
3. Per node: subcarrier selection by cardiac-band SNR (in-band Welch peak /
   out-of-band median), top-k combined phase-robustly (first principal
   component, sign-aligned); VMD (k=4) on the combination, mode selected by
   in-band spectral concentration (ties broken by in-band energy).
4. Best node = highest mean top-k cardiac-band SNR across the fleet dict.
5. Two estimators on the selected mode: autocorrelation first-peak in the
   0.45–1.25 s lag range (48–133 bpm) and Welch PSD peak (parabolic
   interpolation). Voting: agreement within 3 bpm -> bpm = mean; else the
   PSD peak wins with slashed confidence.
6. Confidence formula (documented, terms in [0, 1]). snr is the combined
   signal's in-band PSD peak over the in-band median; because both
   estimators run on a narrowband VMD mode they can trivially agree on
   noise, so the agreement term is gated by SNR:

       snr_term    = max(0, snr - 5) / (snr + 15)
       agree_gate  = min(1, snr / 30)
       agree_term  = 1                      if |Δbpm| <= 3
                   = max(0, 1-(|Δbpm|-3)/9) otherwise
       resid_term  = 1 - P(f_breath ± 0.05 Hz after notching)
                         / (same + cardiac peak power)      (0.5 if f_breath
                                                             unknown)
       confidence  = clip(0.45*snr_term + 0.35*agree_term*agree_gate
                          + 0.20*resid_term, 0, 1)
"""

from __future__ import annotations

import numpy as np
from scipy import signal

from .gating import VitalsEstimate  # re-export per CONTRACTS §8
from .vmd import vmd

__all__ = ["HeartExtractor", "VitalsEstimate"]

BAND = (0.8, 2.2)          # Hz, cardiac
LAG_RANGE = (0.45, 1.25)   # s, autocorrelation first-peak search
TOP_K = 8
_EPS = 1e-12


def _psd_peak(f: np.ndarray, p: np.ndarray, lo: float, hi: float
              ) -> tuple[float, float, float]:
    """(peak_freq, snr, peak_power) of the dominant in-band peak."""
    band = (f >= lo) & (f <= hi)
    fb, pb = f[band], p[band]
    if fb.size == 0:
        return float("nan"), 0.0, 0.0
    i = int(np.argmax(pb))
    fpk = float(fb[i])
    if 0 < i < pb.size - 1:
        y0, y1, y2 = np.log(pb[i - 1: i + 2] + _EPS)
        denom = y0 - 2.0 * y1 + y2
        if abs(denom) > _EPS:
            d = float(np.clip(0.5 * (y0 - y2) / denom, -0.5, 0.5))
            fpk += d * float(fb[1] - fb[0])
    snr = float(pb[i] / (np.median(pb) + _EPS))
    return fpk, snr, float(pb[i])


def _combine(sigs: np.ndarray) -> np.ndarray:
    s = sigs / (sigs.std(axis=1, keepdims=True) + _EPS)
    u, sv, _ = np.linalg.svd(s.T, full_matrices=False)
    pc = u[:, 0] * sv[0]
    if float(pc @ s[0]) < 0:
        pc = -pc
    return pc


def _autocorr_bpm(x: np.ndarray, fs: float) -> float:
    """First prominent autocorrelation peak in LAG_RANGE, with parabolic
    sub-sample interpolation. Returns nan if no peak found."""
    x = x - x.mean()
    r = signal.correlate(x, x, mode="full")[x.size - 1:]
    r = r / (r[0] + _EPS)
    i0 = max(1, int(round(LAG_RANGE[0] * fs)))
    i1 = min(r.size - 2, int(round(LAG_RANGE[1] * fs)))
    if i1 <= i0:
        return float("nan")
    seg = r[i0: i1 + 1]
    peaks, props = signal.find_peaks(seg, prominence=0.0)
    if peaks.size == 0:
        idx = i0 + int(np.argmax(seg))
    else:
        heights = seg[peaks]
        # "first peak": earliest peak that is at least 60% of the tallest.
        good = peaks[heights >= 0.6 * heights.max()]
        idx = i0 + int(good[0])
    y0, y1, y2 = r[idx - 1], r[idx], r[idx + 1]
    denom = y0 - 2.0 * y1 + y2
    d = float(np.clip(0.5 * (y0 - y2) / denom, -0.5, 0.5)) if abs(denom) > _EPS else 0.0
    lag = (idx + d) / fs
    return 60.0 / lag


class HeartExtractor:
    """Heart-rate estimator over a fleet of still-window views [t, 52]."""

    def __init__(self, fs: float = 100.0) -> None:
        self.fs = fs
        self._q = max(1, int(round(fs / 25.0)))
        self.fs_d = fs / self._q

    def estimate(self, windows: dict[int, np.ndarray],
                 f_breath: float | None = None) -> VitalsEstimate:
        try:
            return self._estimate(windows, f_breath)
        except Exception as exc:  # never raise on poor signal
            return VitalsEstimate(60.0, 0.0, {"error": repr(exc)})

    # -----------------------------------------------------------------

    def _prep_node(self, x: np.ndarray, f_breath: float | None
                   ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """detrend + decimate + notch; returns (y, f, psd[nf, 52])."""
        fs_d = self.fs_d
        xd = signal.detrend(np.asarray(x, dtype=float), axis=0)
        y = signal.decimate(xd, self._q, axis=0, zero_phase=True) \
            if self._q > 1 else xd
        if f_breath is not None and f_breath > 0:
            for h in (1, 2, 3):
                f0 = h * f_breath
                if 0.02 < f0 < 0.45 * fs_d:
                    b, a = signal.iirnotch(f0, Q=8.0, fs=fs_d)
                    y = signal.filtfilt(b, a, y, axis=0)
        nps = min(y.shape[0], int(60 * fs_d))
        f, p = signal.welch(y, fs=fs_d, nperseg=nps, axis=0)
        return y, f, p

    def _estimate(self, windows: dict[int, np.ndarray],
                  f_breath: float | None) -> VitalsEstimate:
        if not windows:
            return VitalsEstimate(60.0, 0.0, {"error": "no windows"})
        fs_d = self.fs_d

        # Per-node subcarrier SNR + selection (steps 1-4).
        node_info: dict[int, dict] = {}
        for nid, win in windows.items():
            y, f, p = self._prep_node(win, f_breath)
            inb = (f >= BAND[0]) & (f <= BAND[1])
            outb = ((f >= 0.25) & (f <= 0.7)) | ((f >= 2.5) & (f <= 5.0))
            peak = p[inb].max(axis=0)
            floor = np.median(p[outb], axis=0) + _EPS
            snr_sub = peak / floor
            top = np.argsort(snr_sub)[-TOP_K:][::-1]
            node_info[nid] = {
                "y": y, "f": f, "p": p, "top": top,
                "snr": float(snr_sub[top].mean()),
            }
        best_node = max(node_info, key=lambda k: node_info[k]["snr"])
        info = node_info[best_node]
        y, top = info["y"], info["top"]

        # Band-pass + phase-robust combination.
        sos = signal.butter(4, BAND, btype="bandpass", fs=fs_d, output="sos")
        yf = signal.sosfiltfilt(sos, y[:, top], axis=0)
        comb = _combine(yf.T)

        # VMD mode selection: highest in-band concentration; near-ties
        # (within 20% of the best concentration) broken by in-band energy so
        # the fundamental beats its (equally concentrated) 2nd harmonic.
        modes, cfs = vmd(comb, k=4, alpha=2000.0, fs=fs_d)
        nps = min(comb.size, int(60 * fs_d))
        concs: list[float] = []
        energies: list[float] = []
        for i in range(modes.shape[0]):
            fm, pm = signal.welch(modes[i], fs=fs_d, nperseg=nps)
            tot = float(pm.sum()) + _EPS
            concs.append(float(pm[(fm >= BAND[0]) & (fm <= BAND[1])].sum()) / tot)
            energies.append(float(np.sum(modes[i] ** 2)))
        best_conc = max(concs)
        candidates = [i for i in range(modes.shape[0]) if concs[i] >= 0.8 * best_conc]
        best_mode = max(candidates, key=lambda i: energies[i])
        mode = modes[best_mode]

        # Two estimators + voting (step 5).
        bpm_ac = _autocorr_bpm(mode, fs_d)
        fm, pm = signal.welch(mode, fs=fs_d, nperseg=nps)
        f_psd, snr_mode, p_peak = _psd_peak(fm, pm, *BAND)
        # SNR of the combined (pre-VMD) signal — the headline quality number.
        fc, pcomb = signal.welch(comb, fs=fs_d, nperseg=nps)
        _, snr_comb, p_peak_comb = _psd_peak(fc, pcomb, *BAND)
        bpm_psd = 60.0 * f_psd if np.isfinite(f_psd) else 60.0

        delta = abs(bpm_ac - bpm_psd) if np.isfinite(bpm_ac) else float("inf")
        if delta <= 3.0:
            bpm = 0.5 * (bpm_ac + bpm_psd)
            agree_term, path = 1.0, "vote-agree"
        else:
            bpm = bpm_psd
            agree_term = max(0.0, 1.0 - (min(delta, 1e6) - 3.0) / 9.0)
            path = "psd-only"

        # Breathing-removal residual (step 6).
        if f_breath is not None and f_breath > 0:
            fn, pn = info["f"], info["p"][:, top].mean(axis=1)
            near = (fn >= f_breath - 0.05) & (fn <= f_breath + 0.05)
            p_resid = float(pn[near].sum())
            resid_term = 1.0 - p_resid / (p_resid + p_peak_comb + _EPS)
        else:
            resid_term = 0.5

        snr_term = max(0.0, snr_comb - 5.0) / (snr_comb + 15.0)
        agree_gate = min(1.0, snr_comb / 30.0)
        confidence = float(np.clip(
            0.45 * snr_term + 0.35 * agree_term * agree_gate
            + 0.20 * resid_term, 0.0, 1.0))

        detail = {
            "node": int(best_node),
            "node_snr": {int(k): round(v["snr"], 2) for k, v in node_info.items()},
            "subcarriers": [int(k) for k in top],
            "bpm_autocorr": float(bpm_ac) if np.isfinite(bpm_ac) else None,
            "bpm_psd": float(bpm_psd),
            "delta_bpm": float(delta) if np.isfinite(delta) else None,
            "path": path,
            "snr": float(snr_comb),
            "snr_mode": float(snr_mode),
            "resid_term": float(resid_term),
            "vmd_center_freqs_hz": [round(float(c), 4) for c in cfs],
            "vmd_concentrations": [round(c, 3) for c in concs],
            "f_hz": float(bpm / 60.0),
        }
        return VitalsEstimate(float(bpm), confidence, detail)
