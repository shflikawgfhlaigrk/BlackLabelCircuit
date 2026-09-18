"""M2 — module-local synthetic generators for the house ledger.

Operating envelope: builds (a) CSI amplitude windows [t,52] float32 at
100 Hz carrying a steam-attenuation phenomenology (gradual mean drop +
high-band scatter-variance rise, then recovery) on top of vigil.synth
quiet-room baselines, and (b) fully scripted event-graph days for
scrubber/ADL tests. Phenomenology only — no accuracy claim on real hardware
follows from these (real-shower validation is hardware-gated; see
ENGINEERING_LOG).

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification. (The raw CSI
generated here exists only as test input to the detector; it is never
stored in the ledger.)
"""

from __future__ import annotations

import numpy as np

from ..synth import FS, add_motion, quiet_csi, rng_for
from .steam import HIGH_BAND

DAY_S = 86400.0
H = 3600.0


# -- steam CSI ------------------------------------------------------------------


def add_steam(x: np.ndarray, t0_s: float, dur_s: float, *, drop: float = 4.0,
              ramp_s: float = 60.0, var_rise: float = 1.0,
              shared_rise: float = 0.6, seed: int = 0) -> np.ndarray:
    """Superimpose a steam episode: gradual mean attenuation (0 -> `drop`
    amp units over `ramp_s`), held for `dur_s`, then symmetric recovery;
    plus a high-band scatter-variance rise (independent per-subcarrier noise
    of sigma `var_rise` and a shared component of sigma `shared_rise`) while
    the steam is present."""
    rng = rng_for(seed)
    x = x.copy()
    t = x.shape[0]
    n = np.arange(t) / FS
    env = np.clip((n - t0_s) / ramp_s, 0.0, 1.0) * np.clip(
        (t0_s + dur_s + ramp_s - n) / ramp_s, 0.0, 1.0)
    env = np.clip(env, 0.0, 1.0)
    x -= (env * drop)[:, None].astype(np.float32)
    hi = np.arange(HIGH_BAND.start, HIGH_BAND.stop)
    shared = rng.normal(0, shared_rise, t)
    x[:, hi] += (env[:, None] * (shared[:, None]
                                 + rng.normal(0, var_rise, (t, hi.size)))
                 ).astype(np.float32)
    return np.clip(x, 0, 255).astype(np.float32)


def shower_window(pre_s: float = 240.0, steam_min: float = 8.0,
                  post_s: float = 240.0, *, drop: float = 4.0,
                  ramp_s: float = 60.0, seed: int = 0
                  ) -> tuple[np.ndarray, float, float]:
    """Shower session: quiet bathroom, then a `steam_min`-minute steam hold.
    Returns (window[t,52], t0_true, t1_true) where t0_true is ramp onset and
    t1_true is end of recovery (attenuation fully gone)."""
    dur = steam_min * 60.0
    total = pre_s + ramp_s + dur + ramp_s + post_s
    x = quiet_csi(total, seed=seed)
    x = add_steam(x, pre_s, ramp_s + dur, drop=drop, ramp_s=ramp_s,
                  seed=seed + 1)
    return x, pre_s, pre_s + ramp_s + dur + ramp_s


def boil_window(pre_s: float = 240.0, boil_s: float = 90.0,
                post_s: float = 240.0, *, drop: float = 1.4,
                ramp_s: float = 30.0, seed: int = 0
                ) -> tuple[np.ndarray, float, float]:
    """Pot-boil session: smaller and shorter than a shower (below the 3 min
    sustain bar by default -> tracked internally, not emitted)."""
    total = pre_s + ramp_s + boil_s + ramp_s + post_s
    x = quiet_csi(total, seed=seed)
    x = add_steam(x, pre_s, ramp_s + boil_s, drop=drop, ramp_s=ramp_s,
                  var_rise=0.5, shared_rise=0.3, seed=seed + 1)
    return x, pre_s, pre_s + ramp_s + boil_s + ramp_s


def walking_window(duration_s: float = 600.0, *, n_walks: int = 5,
                   seed: int = 0) -> np.ndarray:
    """Empty room with a person walking through periodically — motion-band
    energy high; must NOT read as steam (walking veto)."""
    x = quiet_csi(duration_s, seed=seed)
    for i in range(n_walks):
        t0 = 60.0 + i * (duration_s - 120.0) / max(1, n_walks)
        x = add_motion(x, t0, 8.0, amp=12.0, seed=seed + 10 + i)
    return x.astype(np.float32)


# -- scripted event-graph days ------------------------------------------------


ROOMS = {"bed": "bedroom", "bath": "bathroom", "kitchen": "kitchen",
         "living": "living room"}


def scripted_day(graph, date_t0: float, *, person: str = "resident",
                 traversal_s: float = 10.0) -> dict:
    """Append one canonical day of derived events to `graph` (date_t0 =
    local midnight): sleep 23:00-07:00 with 3 restless bursts and 2 night
    bathroom excursions, 2 meals (kitchen + steam), 1 shower, 5 bathroom
    visits (3 day / 2 night), daytime sitting in the living room. Returns
    the ground-truth expectations dict for assertions."""
    bed, bath, kit, liv = (ROOMS["bed"], ROOMS["bath"], ROOMS["kitchen"],
                           ROOMS["living"])

    def tr(h: float, room: str, frm: str) -> None:
        graph.append({"ts": date_t0 + h * H, "kind": "transition",
                      "room": room, "person": person, "confidence": 0.9,
                      "attrs": {"from": frm, "to": room,
                                "traversal_s": traversal_s}})

    def mo(h: float, room: str) -> None:
        graph.append({"ts": date_t0 + h * H, "kind": "motion", "room": room,
                      "person": person, "confidence": 0.9,
                      "attrs": {"energy": 4.0}})

    def steam(h0: float, h1: float, room: str, conf: float) -> None:
        graph.append({"ts": date_t0 + h0 * H, "kind": "steam", "room": room,
                      "confidence": conf,
                      "attrs": {"t0": date_t0 + h0 * H, "t1": date_t0 + h1 * H}})

    tr(-1.0, bed, liv)                     # 23:00 to bed
    mo(1.5, bed)                           # restless x3
    tr(2.0, bath, bed); tr(2.083, bed, bath)    # 02:00 night visit 1
    mo(3.5, bed)
    tr(4.5, bath, bed); tr(4.583, bed, bath)    # 04:30 night visit 2
    mo(5.0, bed)
    tr(7.0, bath, bed)                     # 07:00 up (day visit 1)
    steam(7.083, 7.417, bath, 0.85)        # 07:05-07:25 shower
    tr(7.5, kit, bath)                     # 07:30 breakfast
    steam(7.583, 7.833, kit, 0.6)          # boil
    tr(8.0, liv, kit)
    tr(12.5, bath, liv); tr(12.583, liv, bath)  # 12:30 day visit 2
    tr(18.0, bath, liv)                    # 18:00 day visit 3
    tr(18.083, kit, bath)                  # dinner
    steam(18.167, 18.5, kit, 0.65)
    tr(19.0, liv, kit)
    tr(22.0, bed, liv)                     # 22:00 next night begins

    return {
        "person": person,
        "sleep": {"t0": date_t0 - 1.0 * H, "t1": date_t0 + 7.0 * H,
                  "duration_s": 8.0 * H, "restlessness": 3},
        "meals": 2,
        "showers": 1,
        "bathroom": {"total": 5, "day": 3, "night": 2},
        "chair_longest_s": (18.0 - 12.583) * H,  # 12:35 -> 18:00 living stay
        "traversal_s": traversal_s,
    }


def scripted_transitions(graph, t0: float = 0.0, *, person: str = "resident",
                         step_s: float = 10.0,
                         rooms: tuple[str, ...] = ("bedroom", "hallway",
                                                   "kitchen")) -> list[tuple[float, str]]:
    """Minimal scripted walk for scrubber dot tests: enter each room in
    sequence, `step_s` apart. Returns [(ts, room)] ground truth."""
    truth = []
    prev = rooms[0]
    for i, room in enumerate(rooms):
        ts = t0 + i * step_s
        graph.append({"ts": ts, "kind": "transition", "room": room,
                      "person": person, "confidence": 0.9,
                      "attrs": {"from": prev, "to": room,
                                "traversal_s": 8.0}})
        truth.append((ts, room))
        prev = room
    return truth
