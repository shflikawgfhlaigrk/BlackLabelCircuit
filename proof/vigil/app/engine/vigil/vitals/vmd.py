"""Variational Mode Decomposition (VMD) in pure numpy.

Reference: K. Dragomiretskiy, D. Zosso, "Variational Mode Decomposition",
IEEE Transactions on Signal Processing, 62(3):531-544, 2014.

Operating envelope: offline decomposition of short (seconds..minutes),
uniformly sampled 1-D signals into k narrow-band modes — used by the vitals
extractors to separate respiratory / cardiac components from residual noise.
Deterministic: center frequencies are initialized uniformly spread over the
positive half-band (no RNG). The signal is mirror-extended by half its
length on each side to suppress boundary artifacts, decomposed with the
FFT-domain ADMM updates of the paper, then cropped back.
"""

from __future__ import annotations

import numpy as np

_EPS = 1e-12


def vmd(x: np.ndarray, k: int = 4, alpha: float = 2000.0, tau: float = 0.0,
        tol: float = 1e-6, max_iter: int = 300, fs: float = 1.0
        ) -> tuple[np.ndarray, np.ndarray]:
    """Decompose `x` into `k` modes.

    Parameters
    ----------
    x : [t] real signal.
    k : number of modes.
    alpha : bandwidth constraint (larger = narrower modes).
    tau : dual ascent step (0 = noise-tolerant, no exact reconstruction
        constraint — the paper's recommendation for noisy data).
    tol : ADMM convergence tolerance.
    max_iter : maximum ADMM iterations.
    fs : sample rate, used only to express center frequencies in Hz.

    Returns
    -------
    (modes[k, t], center_freqs[k]) — modes in time domain (same length as
    the input, cropped from the mirror extension), center frequencies in Hz,
    sorted ascending.
    """
    x = np.asarray(x, dtype=float).ravel()
    n0 = x.size
    if n0 < 4:
        raise ValueError("vmd needs at least 4 samples")
    trimmed = n0 % 2 == 1
    if trimmed:  # even length keeps the spectrum mirror exact
        x = x[:-1]
        n0 = x.size

    # Mirror extension: half the signal reflected on each side.
    half = n0 // 2
    xe = np.concatenate([x[:half][::-1], x, x[-half:][::-1]])
    n = xe.size  # == 2 * n0, even

    freqs = np.arange(n) / n - 0.5  # normalized, after fftshift
    f_hat = np.fft.fftshift(np.fft.fft(xe))
    f_hat_plus = f_hat.copy()
    f_hat_plus[: n // 2] = 0.0  # keep positive half-spectrum only

    u_hat = np.zeros((k, n), dtype=complex)
    # Deterministic init: spread center freqs uniformly over (0, 0.5).
    omega = 0.5 * (np.arange(k) + 0.5) / k
    lam = np.zeros(n, dtype=complex)

    pos = slice(n // 2, n)
    fpos = freqs[pos]

    for _ in range(max_iter):
        u_prev = u_hat.copy()
        sum_u = u_hat.sum(axis=0)
        for i in range(k):
            sum_u = sum_u - u_hat[i]
            u_hat[i] = (f_hat_plus - sum_u + lam / 2.0) / (
                1.0 + 2.0 * alpha * (freqs - omega[i]) ** 2
            )
            p = np.abs(u_hat[i, pos]) ** 2
            omega[i] = float((fpos @ p) / (p.sum() + _EPS))
            sum_u = sum_u + u_hat[i]
        lam = lam + tau * (u_hat.sum(axis=0) - f_hat_plus)
        num = np.sum(np.abs(u_hat - u_prev) ** 2)
        den = np.sum(np.abs(u_prev) ** 2) + _EPS
        if num / den < tol:
            break

    # Back to time domain: rebuild the conjugate-symmetric full spectrum.
    modes = np.zeros((k, n))
    for i in range(k):
        full = np.zeros(n, dtype=complex)
        full[n // 2:] = u_hat[i, n // 2:]
        full[1: n // 2] = np.conj(u_hat[i, n // 2 + 1:][::-1])
        modes[i] = np.real(np.fft.ifft(np.fft.ifftshift(full)))

    modes = modes[:, half: half + n0]
    if trimmed:  # restore original length by repeating the last sample
        modes = np.concatenate([modes, modes[:, -1:]], axis=1)

    order = np.argsort(omega)
    center_freqs = np.abs(omega[order]) * fs
    return modes[order], center_freqs
