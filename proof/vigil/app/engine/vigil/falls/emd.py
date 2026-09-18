"""C3 — Empirical Mode Decomposition + physically-plausible augmentation.

Operating envelope: classic EMD by sifting with cubic-spline envelopes over
local extrema (scipy CubicSpline), SD stopping criterion (< 0.3) or a
monotone residual. Used to multiply the tiny labeled fall corpus: each IMF
gets an independent amplitude jitter (uniform 0.7-1.3) and a small circular
time-shift (±10% of the window) plus a time-warp (resample factor 0.9-1.1,
np.interp with circular wrap), then IMFs are recombined. The residual
(trend) is passed through unscaled so baselines stay physical. EMD operates
on 1-D time series; for spectrogram tensors `augment` applies the
*equivalent* jitter directly along the time axis (per-channel amplitude
scale + circular shift + warp), which preserves per-bin spectral structure
— documented approximation, not an inverse-STFT round trip. All outputs are
deterministic per seed and real samples always occupy indices [0, n) of the
returned arrays (validation must slice reals only, CONTRACTS §8).
Augmentation gains quoted from tests are synthetic-data numbers.
"""

from __future__ import annotations

import numpy as np


# ---------------------------------------------------------------------------
# EMD
# ---------------------------------------------------------------------------

def _extrema(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Interior local maxima / minima indices (strict on the left to break
    plateau ties deterministically)."""
    mid = x[1:-1]
    mx = np.where((mid > x[:-2]) & (mid >= x[2:]))[0] + 1
    mn = np.where((mid < x[:-2]) & (mid <= x[2:]))[0] + 1
    return mx, mn


def _is_monotone(x: np.ndarray) -> bool:
    d = np.diff(x)
    return bool(np.all(d >= 0) or np.all(d <= 0))


def emd(x: np.ndarray, max_imfs: int = 8, max_siftings: int = 50,
        sd_thresh: float = 0.3) -> np.ndarray:
    """Decompose 1-D `x` into IMFs by sifting -> imfs[k, t]; the residual is
    the last row, so `imfs.sum(axis=0) == x` exactly (up to float error).

    Envelopes are cubic splines through the extrema with the series
    endpoints appended as knots (simple boundary handling). Sifting stops
    when SD = sum((h_prev-h)^2)/sum(h_prev^2) < `sd_thresh` or after
    `max_siftings`; decomposition stops when the residual is monotone, has
    fewer than 2 maxima + 2 minima, or `max_imfs` rows (incl. residual) are
    reached.
    """
    from scipy.interpolate import CubicSpline

    x = np.asarray(x, dtype=np.float64)
    t = np.arange(x.shape[0])
    imfs: list[np.ndarray] = []
    resid = x.copy()
    while len(imfs) < max_imfs - 1:
        mx, mn = _extrema(resid)
        if len(mx) < 2 or len(mn) < 2 or _is_monotone(resid):
            break
        h = resid.copy()
        for _ in range(max_siftings):
            mx, mn = _extrema(h)
            if len(mx) < 2 or len(mn) < 2:
                break
            ux = np.concatenate(([0], mx, [len(h) - 1]))
            lx = np.concatenate(([0], mn, [len(h) - 1]))
            upper = CubicSpline(ux, h[ux])(t)
            lower = CubicSpline(lx, h[lx])(t)
            mean = 0.5 * (upper + lower)
            hn = h - mean
            sd = float(np.sum((h - hn) ** 2) / (np.sum(h ** 2) + 1e-12))
            h = hn
            if sd < sd_thresh:
                break
        imfs.append(h)
        resid = resid - h
    imfs.append(resid)
    return np.stack(imfs)


# ---------------------------------------------------------------------------
# augmentation
# ---------------------------------------------------------------------------

_AMP_LO, _AMP_HI = 0.7, 1.3
_WARP_LO, _WARP_HI = 0.9, 1.1
_SHIFT_FRAC = 0.1  # circular time-shift bound, fraction of window length


def _jitter_params(rng: np.random.Generator, t: int) -> tuple[float, float, float]:
    amp = float(rng.uniform(_AMP_LO, _AMP_HI))
    shift = float(rng.uniform(-_SHIFT_FRAC, _SHIFT_FRAC) * t)
    warp = float(rng.uniform(_WARP_LO, _WARP_HI))
    return amp, shift, warp


def augment_signal(x: np.ndarray, rng: np.random.Generator,
                   max_imfs: int = 8) -> np.ndarray:
    """EMD-domain augmentation of one 1-D series: per-IMF amplitude jitter
    (0.7-1.3) + circular time-shift (±10%) + time-warp (resample 0.9-1.1 via
    np.interp, circular); residual/trend added back unscaled."""
    x = np.asarray(x, dtype=np.float64)
    t = x.shape[0]
    ts = np.arange(t, dtype=np.float64)
    imfs = emd(x, max_imfs=max_imfs)
    out = imfs[-1].copy()  # residual passes through
    for imf in imfs[:-1]:
        amp, shift, warp = _jitter_params(rng, t)
        pos = np.mod(ts * warp + shift, t)
        out += amp * np.interp(pos, ts, imf, period=t)
    return out


def _circ_time_interp(arr: np.ndarray, pos: np.ndarray) -> np.ndarray:
    """Linear circular interpolation of arr[t, ...] at fractional positions."""
    t = arr.shape[0]
    i0 = np.floor(pos).astype(int) % t
    i1 = (i0 + 1) % t
    frac = (pos - np.floor(pos)).reshape((-1,) + (1,) * (arr.ndim - 1))
    return (1.0 - frac) * arr[i0] + frac * arr[i1]


def _augment_spec_window(w: np.ndarray, rng: np.random.Generator,
                         time_axis: int = 0) -> np.ndarray:
    """Spectrogram-tensor equivalent of the EMD jitter (documented
    approximation, see module docstring): per channel (last axis), one
    amplitude scale + circular shift + warp applied along `time_axis`, the
    same transform for every frequency bin of that channel."""
    v = np.moveaxis(np.asarray(w, dtype=np.float64), time_axis, 0)
    t = v.shape[0]
    ts = np.arange(t, dtype=np.float64)
    out = np.empty_like(v)
    for c in range(v.shape[-1]):
        amp, shift, warp = _jitter_params(rng, t)
        pos = np.mod(ts * warp + shift, t)
        out[..., c] = amp * _circ_time_interp(v[..., c], pos)
    return np.moveaxis(out, 0, time_axis).astype(w.dtype, copy=False)


def augment(X: np.ndarray, y: np.ndarray, factor: int = 10, seed: int = 0,
            time_axis: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """Multiply a labeled set by `factor` (total). Real samples occupy
    indices [0, n) of the outputs; the (factor-1)*n synthetic samples are
    appended after. Deterministic per seed.

    - X[n, t] (1-D series per sample): true EMD augmentation.
    - X[n, ...time..., c] (e.g. spectrogram tensors [n, f_frames, bins, c]):
      equivalent time-axis jitter per channel; `time_axis` is the time axis
      *within one sample window* (default 0, i.e. the frame axis of
      [frames, bins, c] windows).
    """
    X = np.asarray(X)
    y = np.asarray(y)
    n = X.shape[0]
    if factor <= 1 or n == 0:
        return X.copy(), y.copy()
    rng = np.random.default_rng(seed)
    outs = [X.copy()]
    for _ in range(factor - 1):
        Xc = np.empty_like(X)
        for i in range(n):
            if X.ndim == 2:
                Xc[i] = augment_signal(X[i], rng)
            else:
                Xc[i] = _augment_spec_window(X[i], rng, time_axis=time_axis)
        outs.append(Xc)
    return np.concatenate(outs, axis=0), np.tile(y, factor)


def augment_timeseries(windows: np.ndarray, factor: int = 10, seed: int = 0,
                       max_imfs: int = 8) -> np.ndarray:
    """EMD-augment raw time-series windows [n, t] or [n, t, c] (per channel).
    Returns [n*factor, ...] with reals at [0, n). Deterministic per seed."""
    W = np.asarray(windows, dtype=np.float64)
    n = W.shape[0]
    if factor <= 1 or n == 0:
        return W.copy()
    rng = np.random.default_rng(seed)
    outs = [W.copy()]
    for _ in range(factor - 1):
        Wc = np.empty_like(W)
        for i in range(n):
            if W.ndim == 2:
                Wc[i] = augment_signal(W[i], rng, max_imfs=max_imfs)
            else:
                for c in range(W.shape[2]):
                    Wc[i, :, c] = augment_signal(W[i, :, c], rng, max_imfs=max_imfs)
        outs.append(Wc)
    return np.concatenate(outs, axis=0)


def augment_motion_to_spectrograms(windows: np.ndarray, factor: int = 10,
                                   seed: int = 0, fs: float = 100.0,
                                   nperseg: int = 50, hop: int = 10,
                                   max_imfs: int = 8) -> np.ndarray:
    """Helper for the raw-signal route: EMD-augment time-domain motion
    windows [n, t] or [n, t, c], then re-STFT each channel (0.5 s Hann /
    0.1 s hop by default) -> spectrogram tensors [n*factor, frames, bins, c]
    (c=1 for 1-D input), log1p magnitude, reals at [0, n)."""
    from scipy import signal

    W = augment_timeseries(windows, factor=factor, seed=seed, max_imfs=max_imfs)
    if W.ndim == 2:
        W = W[:, :, None]
    specs = []
    for i in range(W.shape[0]):
        chans = []
        for c in range(W.shape[2]):
            _, _, Z = signal.stft(W[i, :, c], fs=fs, window="hann",
                                  nperseg=nperseg, noverlap=nperseg - hop,
                                  boundary=None, padded=False)
            chans.append(np.log1p(np.abs(Z)).T)
        specs.append(np.stack(chans, axis=-1))
    return np.stack(specs).astype(np.float32)
