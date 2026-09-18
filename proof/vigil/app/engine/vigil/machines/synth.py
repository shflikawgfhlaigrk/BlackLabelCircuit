"""Module-local synthetic generators for the M4 machine-whisperer tests.

Operating envelope: these produce *plausible* appliance phenomenology on top
of the shared quiet-room CSI from `vigil.synth` — a running appliance shows
up as one or more narrowband mechanical/vibration lines (10-50 Hz) on a
subset of subcarriers, duty-cycled by a schedule, with optional slow center
frequency wobble (bearing wear proxy) or drift. The wet-wall survey walk
models moisture as an attenuation delta + deeper frequency-selective fading
at a subset of measurement points. None of this is a channel simulator; real
appliance clustering accuracy and the real wet-wall attenuation delta are
hardware-gated (recorded walks / recorded appliance sessions).

Aliasing caveat (fs = 100 Hz, Nyquist = 50 Hz): generators only place lines
inside 10-50 Hz because that is all the real pipeline can see — machines
spinning faster than 3000 RPM alias; on hardware we observe low-frequency
mechanical/vibration coupling and on/off duty rhythms, not exact RPM.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

from ..frame import N_SUB
from ..synth import FS, quiet_csi, rng_for


def duty_schedule(duration_s: float, period_s: float, on_s: float,
                  t0: float = 0.0) -> list[tuple[float, float]]:
    """Periodic on/off schedule as [(t_on, t_off), ...] within duration_s."""
    out: list[tuple[float, float]] = []
    t = float(t0)
    while t < duration_s:
        out.append((t, min(t + on_s, duration_s)))
        t += period_s
    return out


def add_appliance(x: np.ndarray, freq_hz: float,
                  schedule: list[tuple[float, float]] | None = None,
                  amp: float = 4.0, k_sub: int = 20, seed: int = 10,
                  wobble_hz: float = 0.0, wobble_period_s: float = 45.0,
                  drift_hz_per_s: float = 0.0, broadband: float = 0.0,
                  ramp_s: float = 0.5, fs: float = FS) -> np.ndarray:
    """Superimpose one appliance line on a CSI window.

    - `schedule=None` = always on (fan-like); otherwise a list of
      (t_on, t_off) intervals with `ramp_s` linear ramps *inside* each
      interval (so duty is exact at the interval edges).
    - `wobble_hz` = sinusoidal center-frequency wobble amplitude with period
      `wobble_period_s` (bearing-wear proxy); `drift_hz_per_s` = slow slew.
    - `broadband` adds band-limited rumble around the line (HVAC blower).
    """
    rng = rng_for(seed)
    x = np.asarray(x, np.float64).copy()
    t = x.shape[0]
    tt = np.arange(t) / fs

    env = np.zeros(t)
    if schedule is None:
        env[:] = 1.0
    else:
        for t_on, t_off in schedule:
            i0 = max(0, int(round(t_on * fs)))
            i1 = min(t, int(round(t_off * fs)))
            if i1 <= i0:
                continue
            seg = np.ones(i1 - i0)
            n = min(int(ramp_s * fs), (i1 - i0) // 2)
            if n > 0:
                seg[:n] = np.linspace(0.0, 1.0, n, endpoint=False)
                seg[-n:] = np.linspace(1.0, 0.0, n, endpoint=False)[::-1]
            env[i0:i1] = seg

    f_inst = freq_hz + drift_hz_per_s * tt
    if wobble_hz:
        f_inst = f_inst + wobble_hz * np.sin(2 * np.pi * tt / wobble_period_s)
    phase = 2 * np.pi * np.cumsum(f_inst) / fs

    subs = rng.choice(N_SUB, size=k_sub, replace=False)
    for k in subs:
        ph0 = rng.uniform(0, 2 * np.pi)
        gain = rng.uniform(0.5, 1.0)
        x[:, k] += env * amp * gain * np.sin(phase + ph0)

    if broadband:
        lo = max(10.0, freq_hz - 8.0)
        hi = min(0.49 * fs, freq_hz + 8.0)
        sos = butter(4, [lo, hi], btype="bandpass", fs=fs, output="sos")
        noise = sosfiltfilt(sos, rng.normal(0, 1.0, (t, k_sub)), axis=0)
        for j, k in enumerate(subs):
            x[:, k] += env * broadband * noise[:, j]

    return np.clip(x, 0, 255).astype(np.float32)


def machine_scene(duration_s: float, appliances: list[dict],
                  seed: int = 0, fs: float = FS) -> np.ndarray:
    """Quiet room + a list of appliances (kwargs for `add_appliance`)."""
    x = quiet_csi(duration_s, seed=seed)
    for i, ap in enumerate(appliances):
        x = add_appliance(x, seed=seed + 11 * (i + 1), fs=fs, **ap)
    return x


def survey_walk(nx: int = 6, ny: int = 4, spacing_m: float = 0.5,
                wet_cells: tuple | list = (), wet_delta: float = -14.0,
                dur_s: float = 2.0, seed: int = 7, fs: float = FS) -> list[dict]:
    """Ordered survey walk over an nx x ny grid; returns
    [{"xy": (x, y), "window": [t,52]}, ...].

    Dry wall = base multipath profile + mild attenuation gradient away from
    the TX. Wet cells get `wet_delta` mean-amplitude shift (extra attenuation)
    and deeper frequency-selective fading across the 52 subcarriers.
    """
    rng = rng_for(seed)
    wet = {tuple(c) for c in wet_cells}
    base_profile = 90 + 30 * np.sin(np.linspace(0, 3 * np.pi, N_SUB))
    n = int(dur_s * fs)
    pts: list[dict] = []
    for iy in range(ny):
        for ix in range(nx):
            xy = (ix * spacing_m, iy * spacing_m)
            mean_shift = -2.0 * ix  # gentle attenuation trend away from TX
            fade = 1.0
            if (ix, iy) in wet:
                mean_shift += wet_delta
                fade = 2.2
            ripple = 6.0 * fade * np.sin(np.linspace(0, 5 * np.pi, N_SUB) + 0.3 * ix)
            w = (base_profile + mean_shift + ripple)[None, :] + rng.normal(0, 0.8, (n, N_SUB))
            pts.append({"xy": xy, "window": np.clip(w, 0, 255).astype(np.float32)})
    return pts
