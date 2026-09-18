"""M1 — module-local synthetic scenario generators (tests only).

Operating envelope: like `vigil.synth`, these produce *plausible* CSI and
session-tape scenarios for plumbing tests — they are NOT a channel
simulator and NOT real traders. No biometric-separation or lead-lag
accuracy claim on real subjects follows from tests built on them; those
numbers are hardware/subject-gated. Reuses the shared generators
(`quiet_csi`, `add_breathing`, `add_heartbeat`, `add_motion`) and adds a
seated micro-motion envelope plus a scripted revenge-trade tape.
"""

from __future__ import annotations

import time

import numpy as np
from scipy import signal

from ..frame import N_SUB
from ..synth import FS, add_breathing, add_heartbeat, add_motion, quiet_csi

#: Two distinct synthetic "bodies" for presence tests: different static
#: reflection profiles, breathing rates and micro-motion textures.
BODY_OWNER = {"body_seed": 11, "breathing_bpm": 13.5, "hr_bpm": 62.0, "sway": 1.0}
BODY_OTHER = {"body_seed": 47, "breathing_bpm": 19.0, "hr_bpm": 74.0, "sway": 1.6}


def body_profile(body_seed: int) -> np.ndarray:
    """Static per-subcarrier reflection offset for one body (its 'shape')."""
    rng = np.random.default_rng(1000 + body_seed)
    return rng.normal(0.0, 12.0, N_SUB)


def _add_sway(x: np.ndarray, sway: float, body_seed: int, seed: int) -> np.ndarray:
    """Seated micro-motion (posture sway/fidget): common band-limited
    (0.3-4 Hz) drive scaled by a body-specific per-subcarrier gain map."""
    rng = np.random.default_rng(seed)
    gains = np.random.default_rng(4000 + body_seed).uniform(0.3, 1.0, N_SUB)
    n = x.shape[0]
    sos = signal.butter(4, (0.3, 4.0), btype="bandpass", fs=FS, output="sos")
    s = signal.sosfilt(sos, rng.normal(0.0, 1.0, n))
    s = s / (s.std() + 1e-12) * sway
    return x + s[:, None] * gains[None, :]


def empty_csi(duration_s: float, seed: int = 0) -> np.ndarray:
    """Empty desk: shared quiet-room generator."""
    return quiet_csi(duration_s, seed=seed)


def seated_csi(duration_s: float, seed: int = 0, body_seed: int = 11,
               breathing_bpm: float = 13.5, hr_bpm: float = 62.0,
               sway: float = 1.0) -> np.ndarray:
    """Seated subject: quiet CSI + body profile + breathing + heartbeat +
    seated micro-motion envelope. `seed` varies noise between windows;
    `body_seed` fixes the body (profile, breathing subcarriers, sway map)."""
    x = quiet_csi(duration_s, seed=seed).astype(float)
    x = x + body_profile(body_seed)[None, :]
    x = add_breathing(x, bpm=breathing_bpm, depth=1.8, k_sub=14,
                      seed=2000 + body_seed)
    x = add_heartbeat(x, bpm=hr_bpm, seed=3000 + body_seed)
    x = _add_sway(x, sway=sway, body_seed=body_seed, seed=seed + 7)
    return np.clip(x, 0, 255).astype(np.float32)


def active_csi(duration_s: float, seed: int = 0, body_seed: int = 11,
               breathing_bpm: float = 13.5, hr_bpm: float = 62.0,
               sway: float = 1.0) -> np.ndarray:
    """Seated + typing/reaching motion covering most of the window."""
    x = seated_csi(duration_s, seed=seed, body_seed=body_seed,
                   breathing_bpm=breathing_bpm, hr_bpm=hr_bpm, sway=sway)
    x = add_motion(x.astype(float), t0_s=0.2, dur_s=max(0.5, duration_s - 0.5),
                   amp=10.0, f_lo=2.0, f_hi=8.0, seed=seed + 13)
    return np.clip(x, 0, 255).astype(np.float32)


def body_windows(body: dict, n: int, duration_s: float = 30.0,
                 seed0: int = 0) -> list[np.ndarray]:
    """n seated windows of one body with varying noise realizations."""
    return [seated_csi(duration_s, seed=seed0 + i, **body) for i in range(n)]


# -- scripted revenge-trade scenario ------------------------------------------------


def revenge_trade_history(n_days: int = 12, seed: int = 0, year: int = 2026,
                          month: int = 3, day0: int = 2
                          ) -> tuple[list[dict], list[dict], dict]:
    """Scripted tape + vitals history: each day is a calm morning, then two
    quick stop-outs (~09:31/09:33 local), a physiological stress rise
    ~30 s later, and an oversize revenge order 3 min after the stop-outs
    (the rule break, flagged in `rule_flags`). Stress onset precedes the
    break by ~150 s by construction.

    Returns (tape, vitals, meta) where meta carries the scripted
    day_starts / stress_onset_ts / break_ts for assertions.
    """
    rng = np.random.default_rng(seed)
    tape: list[dict] = []
    vitals: list[dict] = []
    meta: dict = {"day_starts": [], "stress_onset_ts": [], "break_ts": []}
    for d in range(n_days):
        t9 = time.mktime((year, month, day0 + d, 9, 0, 0, 0, 0, -1))
        onset = t9 + 2010.0 + float(rng.uniform(-20, 20))
        brk = t9 + 2160.0 + float(rng.uniform(-20, 20))
        meta["day_starts"].append(t9)
        meta["stress_onset_ts"].append(onset)
        meta["break_ts"].append(brk)
        tape += [
            {"ts": t9 + 300.0, "event": "order", "symbol": "ES", "size": 100,
             "account_risk_pct": 1.0,
             "latency_ms": float(480 + rng.normal(0, 25)), "rule_flags": []},
            {"ts": t9 + 720.0, "event": "order", "symbol": "ES", "size": 110,
             "account_risk_pct": 1.1,
             "latency_ms": float(515 + rng.normal(0, 25)), "rule_flags": []},
            {"ts": t9 + 1860.0, "event": "stop_out", "symbol": "ES", "size": 100,
             "account_risk_pct": 1.0, "latency_ms": None, "rule_flags": []},
            {"ts": t9 + 1980.0, "event": "stop_out", "symbol": "ES", "size": 110,
             "account_risk_pct": 1.1, "latency_ms": None, "rule_flags": []},
            {"ts": brk - 5.0, "event": "size_change", "symbol": "ES", "size": 320,
             "account_risk_pct": 4.5, "latency_ms": None, "rule_flags": []},
            {"ts": brk, "event": "order", "symbol": "ES", "size": 320,
             "account_risk_pct": 4.5,
             "latency_ms": float(175 + rng.normal(0, 10)),
             "rule_flags": ["oversize", "revenge_window"]},
        ]
        for k in range(0, 3601, 10):
            t = t9 + k
            if onset <= t <= onset + 390.0:
                frac = min(1.0, (t - onset) / 90.0)
            elif onset + 390.0 < t <= onset + 510.0:
                frac = max(0.0, 1.0 - (t - onset - 390.0) / 120.0)
            else:
                frac = 0.0
            bpm = 13.5 + 6.5 * frac + float(rng.normal(0, 0.3))
            hr = 62.0 + 26.0 * frac + float(rng.normal(0, 1.5))
            vitals.append({"t": float(t), "breathing_bpm": float(bpm),
                           "breathing_confidence": 0.8, "hr_bpm": float(hr),
                           "hr_confidence": 0.7})
    return tape, vitals, meta
