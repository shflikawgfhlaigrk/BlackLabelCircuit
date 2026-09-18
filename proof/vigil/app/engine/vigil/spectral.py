"""Spectral stage — PCA projection + STFT spectrograms + motion energy (B3).

Operating envelope (CONTRACTS.md §6):

- Input is MOTION-band data from CleaningStage ([t,52] float32, 100 Hz).
- fit(): PCA across subcarriers (mean-center over time, thin SVD, top
  `n_components`=4 right-singular vectors, deterministic sign convention).
  Explained-variance ratio is exposed for calibration sanity checks.
  Persistable via save()/load() (npz). refit() is an alias.
- transform(): projects to PCs, then STFT per component with a 0.5 s Hann
  window (50 samples @ 100 Hz), 0.1 s hop (10 samples), one-sided rFFT,
  POWER spectrogram [n_frames, n_bins, n_components] with
  n_frames = (t - 50)//10 + 1 and n_bins = 26; `freqs` and `frame_times`
  (window centers, seconds) are returned alongside.
- motion_energy (exact definition — Gate 1 in Track C consumes this at
  100 Hz): PC1 is bandpassed 0.5-10 Hz (order-4 Butterworth, zero-phase
  sosfiltfilt), then motion_energy[i] = RMS of that signal over a centered
  0.5 s (50-sample) rectangular window (edge samples use nearest-edge
  padding). Length equals the input length t, sample-aligned at 100 Hz.
- Self-calibration: transform() on an unfitted stage first fits PCA on the
  given window and flags `self_calibrated=True` in the result. All math is
  deterministic: same input -> byte-identical outputs.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from scipy.ndimage import uniform_filter1d
from scipy.signal import butter, sosfilt, sosfiltfilt
from scipy.signal.windows import hann


@dataclass
class SpectralResult:
    spectrogram: np.ndarray   # [n_frames, n_bins, n_components] float32 power
    motion_energy: np.ndarray  # [t] float32, 100 Hz, see module docstring
    pcs: np.ndarray            # [t, n_components] float32
    freqs: np.ndarray          # [n_bins] Hz
    frame_times: np.ndarray    # [n_frames] s (window centers)
    self_calibrated: bool = False


class SpectralStage:
    def __init__(self, fs: float = 100.0, n_components: int = 4) -> None:
        self.fs = float(fs)
        self.n_components = int(n_components)
        self.win = int(round(0.5 * fs))    # 50 samples
        self.hop = int(round(0.1 * fs))    # 10 samples
        self._window = hann(self.win, sym=False)
        hi = min(10.0, 0.45 * fs)
        self._sos_energy = butter(4, [0.5, hi], btype="bandpass", fs=fs, output="sos")
        self.mean_: np.ndarray | None = None                  # [52]
        self.components_: np.ndarray | None = None            # [52, k]
        self.explained_variance_ratio_: np.ndarray | None = None

    # -- calibration --------------------------------------------------------

    @property
    def fitted(self) -> bool:
        return self.components_ is not None

    def fit(self, calib: np.ndarray) -> "SpectralStage":
        """PCA across subcarriers on MOTION-band data (mean-center + SVD)."""
        X = np.asarray(calib, np.float64)
        if X.ndim != 2 or X.shape[0] < self.n_components:
            raise ValueError(f"calib must be [t,52] with t >= {self.n_components}")
        self.mean_ = X.mean(axis=0)
        Xc = X - self.mean_
        _, S, Vt = np.linalg.svd(Xc, full_matrices=False)
        comps = Vt[: self.n_components].copy()
        # deterministic sign: largest-magnitude loading is positive
        signs = np.sign(comps[np.arange(comps.shape[0]), np.abs(comps).argmax(axis=1)])
        signs[signs == 0] = 1.0
        comps *= signs[:, None]
        self.components_ = comps.T                                # [52, k]
        var = S ** 2
        self.explained_variance_ratio_ = var / max(var.sum(), 1e-30)
        return self

    def refit(self, calib: np.ndarray) -> "SpectralStage":
        return self.fit(calib)

    def save(self, path: str | Path) -> None:
        if not self.fitted:
            raise ValueError("stage not fitted")
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        np.savez(p, mean=self.mean_, components=self.components_,
                 evr=self.explained_variance_ratio_,
                 fs=np.float64(self.fs), n_components=np.int64(self.n_components))

    def load(self, path: str | Path) -> "SpectralStage":
        with np.load(path) as z:
            self.mean_ = z["mean"]
            self.components_ = z["components"]
            self.explained_variance_ratio_ = z["evr"]
            self.fs = float(z["fs"])
            self.n_components = int(z["n_components"])
        return self

    # -- transform -----------------------------------------------------------

    def transform(self, motion: np.ndarray) -> SpectralResult:
        motion = np.asarray(motion, np.float64)
        self_calibrated = False
        if not self.fitted:
            self.fit(motion)
            self_calibrated = True
        pcs = (motion - self.mean_) @ self.components_             # [t, k]
        t = pcs.shape[0]
        k = self.n_components
        n_bins = self.win // 2 + 1
        freqs = np.fft.rfftfreq(self.win, 1.0 / self.fs)
        if t >= self.win:
            frames = sliding_window_view(pcs, self.win, axis=0)[:: self.hop]  # [n,k,win]
            spec = np.abs(np.fft.rfft(frames * self._window, axis=-1)) ** 2
            spectrogram = np.ascontiguousarray(
                spec.transpose(0, 2, 1)).astype(np.float32)       # [n, bins, k]
            n_frames = spectrogram.shape[0]
            frame_times = (np.arange(n_frames) * self.hop + self.win / 2.0) / self.fs
        else:
            spectrogram = np.zeros((0, n_bins, k), np.float32)
            frame_times = np.zeros(0, np.float64)
        motion_energy = self._motion_energy(pcs[:, 0]) if t else np.zeros(0, np.float32)
        return SpectralResult(spectrogram, motion_energy, pcs.astype(np.float32),
                              freqs, frame_times, self_calibrated)

    def _motion_energy(self, pc1: np.ndarray) -> np.ndarray:
        """Band-integrated (0.5-10 Hz) PC1 power as a per-sample RMS series."""
        padlen = 3 * (2 * self._sos_energy.shape[0] + 1)
        if pc1.shape[0] <= padlen:
            bp = sosfilt(self._sos_energy, pc1)
        else:
            bp = sosfiltfilt(self._sos_energy, pc1)
        rms = np.sqrt(uniform_filter1d(bp ** 2, size=self.win, mode="nearest"))
        return rms.astype(np.float32)
