"""Synthetic CSI generators — shared test fixture factory.

Operating envelope: these generators produce *plausible* CSI amplitude
windows (uint8-range, 52 subcarriers, 100 Hz) with controllable events for
unit tests, training-pipeline smoke tests and benchmark plumbing. They model
the phenomenology (multipath baseline per subcarrier, motion as band-limited
energy bursts, vitals as tiny periodic modulation) — they are NOT a channel
simulator, and no accuracy claim on real hardware follows from passing tests
built on them. Real acceptance numbers come from recorded B4 sessions.
"""

from __future__ import annotations

import numpy as np

from .frame import N_SUB
from .session import Session

FS = 100.0


def rng_for(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def quiet_csi(duration_s: float, seed: int = 0, noise: float = 0.8,
              drift: float = 0.0) -> np.ndarray:
    """Empty-room CSI: static multipath profile per subcarrier + sensor noise.

    `drift` adds a slow linear mean shift (thermal / AGC creep) in amp units
    over the whole window.
    """
    rng = rng_for(seed)
    t = int(duration_s * FS)
    profile = 80 + 40 * np.sin(np.linspace(0, 3 * np.pi, N_SUB)) + rng.normal(0, 5, N_SUB)
    x = profile[None, :] + rng.normal(0, noise, (t, N_SUB))
    if drift:
        x += np.linspace(0, drift, t)[:, None]
    return np.clip(x, 0, 255).astype(np.float32)


def _motion_envelope(t_len: int, t0: int, rise: int, hold: int, fall: int,
                     amp: float) -> np.ndarray:
    env = np.zeros(t_len)
    r_end = min(t0 + rise, t_len)
    env[t0:r_end] = np.linspace(0, amp, r_end - t0)
    h_end = min(r_end + hold, t_len)
    env[r_end:h_end] = amp
    f_end = min(h_end + fall, t_len)
    if f_end > h_end:
        env[h_end:f_end] = np.linspace(amp, 0, f_end - h_end)
    return env


def add_motion(x: np.ndarray, t0_s: float, dur_s: float, amp: float = 12.0,
               f_lo: float = 0.5, f_hi: float = 8.0, seed: int = 1) -> np.ndarray:
    """Add band-limited motion energy (walking-like) starting at t0_s."""
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    n = int(dur_s * FS)
    t0 = int(t0_s * FS)
    env = _motion_envelope(t, t0, n // 4, n // 2, n // 4, amp)
    for k in range(N_SUB):
        f = rng.uniform(f_lo, f_hi)
        phase = rng.uniform(0, 2 * np.pi)
        gain = rng.uniform(0.3, 1.0)
        x[:, k] += env * gain * np.sin(2 * np.pi * f * np.arange(t) / FS + phase)
    return np.clip(x, 0, 255)


def add_fall(x: np.ndarray, t0_s: float, kind: str = "fall-fast",
             seed: int = 2) -> np.ndarray:
    """Fall signature: sharp high-energy broadband burst (<800 ms rise) then
    stillness. `fall-slow` and `fall-slide` stretch the burst but keep the
    post-event stillness."""
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    t0 = int(t0_s * FS)
    rise, hold = {"fall-fast": (25, 30), "fall-slow": (60, 50), "fall-slide": (70, 80)}[kind]
    env = _motion_envelope(t, t0, rise, hold, 20, 35.0)
    for k in range(N_SUB):
        f = rng.uniform(2.0, 10.0)
        phase = rng.uniform(0, 2 * np.pi)
        x[:, k] += env * rng.uniform(0.5, 1.0) * np.sin(2 * np.pi * f * np.arange(t) / FS + phase)
    return np.clip(x, 0, 255)


def add_confounder(x: np.ndarray, t0_s: float, kind: str, seed: int = 3) -> np.ndarray:
    """sit-hard: medium burst then stillness; object-drop: very short spike
    then prior activity resumes; pet: low-amplitude sustained wander; walk:
    alias of add_motion."""
    if kind == "walk":
        return add_motion(x, t0_s, 4.0, amp=10.0, seed=seed)
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    t0 = int(t0_s * FS)
    if kind == "sit-hard":
        env = _motion_envelope(t, t0, 40, 20, 30, 22.0)
        f_lo, f_hi = 1.5, 7.0
    elif kind == "object-drop":
        env = _motion_envelope(t, t0, 6, 6, 8, 28.0)
        f_lo, f_hi = 5.0, 12.0
    elif kind == "pet":
        env = _motion_envelope(t, t0, 100, int(2.5 * FS), 100, 5.0)
        f_lo, f_hi = 0.5, 4.0
    else:
        raise ValueError(f"unknown confounder {kind!r}")
    for k in range(N_SUB):
        f = rng.uniform(f_lo, f_hi)
        phase = rng.uniform(0, 2 * np.pi)
        x[:, k] += env * rng.uniform(0.4, 1.0) * np.sin(2 * np.pi * f * np.arange(t) / FS + phase)
    return np.clip(x, 0, 255)


def add_breathing(x: np.ndarray, bpm: float = 14.0, depth: float = 1.5,
                  k_sub: int = 12, seed: int = 4) -> np.ndarray:
    """Superimpose respiratory modulation on `k_sub` random subcarriers.
    depth is in raw amplitude units (breathing on real hardware is ~1-3 LSB)."""
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    f = bpm / 60.0
    subs = rng.choice(N_SUB, size=k_sub, replace=False)
    for k in subs:
        phase = rng.uniform(0, 2 * np.pi)
        gain = rng.uniform(0.5, 1.0)
        x[:, k] += depth * gain * np.sin(2 * np.pi * f * np.arange(t) / FS + phase)
    return np.clip(x, 0, 255)


def add_heartbeat(x: np.ndarray, bpm: float = 66.0, depth: float = 0.35,
                  k_sub: int = 8, seed: int = 5) -> np.ndarray:
    """Cardiac micro-modulation: far smaller than breathing, slightly pulsed
    (fundamental + weak 2nd harmonic)."""
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    f = bpm / 60.0
    subs = rng.choice(N_SUB, size=k_sub, replace=False)
    n = np.arange(t) / FS
    for k in subs:
        phase = rng.uniform(0, 2 * np.pi)
        gain = rng.uniform(0.5, 1.0)
        x[:, k] += depth * gain * (np.sin(2 * np.pi * f * n + phase)
                                   + 0.3 * np.sin(4 * np.pi * f * n + 2 * phase))
    return np.clip(x, 0, 255)


def make_session(duration_s: float = 60.0, node_ids: tuple[int, ...] = (1,),
                 events: list[dict] | None = None, seed: int = 0,
                 breathing_bpm: float | None = None,
                 hr_bpm: float | None = None) -> Session:
    """Build a labeled Session. `events` entries:
    {"t": s, "kind": <label>, "node_id": optional} — fall/confounder kinds.
    If breathing_bpm/hr_bpm set, modulation + reference labels are added
    across the whole session (bed-geometry style).
    """
    s = Session(fs=FS, meta={"synthetic": True, "seed": seed})
    events = events or []
    for j, nid in enumerate(node_ids):
        x = quiet_csi(duration_s, seed=seed + 17 * j)
        if breathing_bpm:
            x = add_breathing(x, bpm=breathing_bpm, seed=seed + 100 + j)
        if hr_bpm:
            x = add_heartbeat(x, bpm=hr_bpm, seed=seed + 200 + j)
        for i, ev in enumerate(events):
            if ev.get("node_id") not in (None, nid):
                continue
            kind, t0 = ev["kind"], ev["t"]
            if kind.startswith("fall"):
                x = add_fall(x, t0, kind, seed=seed + 300 + 7 * i + j)
            elif kind == "walk":
                x = add_motion(x, t0, ev.get("dur", 4.0), seed=seed + 400 + 7 * i + j)
            elif kind in ("sit-hard", "object-drop", "pet"):
                x = add_confounder(x, t0, kind, seed=seed + 500 + 7 * i + j)
        s.amps[nid] = x.astype(np.float32)
        n = x.shape[0]
        s.rssi[nid] = np.full(n, -55, np.int8)
        s.seq[nid] = np.arange(n, dtype=np.uint32)
        s.ts_us[nid] = (np.arange(n) * 1e6 / FS).astype(np.uint64)
    for ev in events:
        dur = {"fall-fast": 1.0, "fall-slow": 1.8, "fall-slide": 2.2}.get(
            ev["kind"], ev.get("dur", 2.0))
        s.add_label(ev["t"], ev["t"] + dur, ev["kind"], ev.get("node_id"))
    if breathing_bpm:
        s.add_label(0, duration_s, "breathing-ref")
        for t in np.arange(0, duration_s, 10.0):
            s.add_ref("breathing", float(t), breathing_bpm)
    if hr_bpm:
        s.add_label(0, duration_s, "hr-ref")
        for t in np.arange(0, duration_s, 10.0):
            s.add_ref("hr", float(t), hr_bpm)
    if not events:
        s.add_label(0, duration_s, "still")
    return s
