"""RTI — radio-tomographic motion imaging on the dual-role fleet.

The fleet's ~20 directed links each report motion (mean |Δamp| EMA). A body
disturbing a link disturbs it most when it stands near the link's LINE — the
classic radio-tomography observation. Back-projecting every link's motion
EXCESS through an ellipse kernel onto a grid over the F6 layout produces a
live image of WHERE the motion is — sub-room localization from amplitude-only
hardware that can never do per-link ranging (20 MHz, no phase: c/2B ≈ 7.5 m).
The fleet geometry is the aperture; the map we learned is what makes the
image possible.

Pipeline per update:
1. Per-link quiet floor: rolling low-percentile of each link's motion over a
   physical-time window (a link's ambient flicker is ITS OWN constant);
   excess = motion − floor, clamped at 0.
2. Back-projection: image(p) = Σ_links excess · K_link(p), with
   K_link(p) = exp(−λ·((|p−a|+|p−b|)−|a−b|)) normalized per link — the
   standard RTI ellipse weight (a body ON the a–b path stretches it least).
3. Honest gate: a localization is only claimed when the peak stands out of
   the image (z-score ≥ z_gate) AND enough links are live. Otherwise the
   caller gets the raw (flat) field and NO peak — never a fabricated blob.

Envelope (stamped in output `basis`): this images MOTION, not presence — a
perfectly still sleeper fades from RTI (the room-level presence/vitals
layers own stillness); accuracy is ~0.5–1 grid-cell-scale in covered areas;
positions are the F6 relative frame, not meters. Presentation/localization
layer only: no alarm may gate on it (registry.py design rule).
"""

from __future__ import annotations

import math
from collections import deque

import numpy as np

GRID = 28                 # cells per side on the unit box
LAMBDA = 9.0              # ellipse sharpness (unit-box scale)
Z_GATE = 2.5              # peak z-score sanity floor (shape check only)
MIN_SIG = 3               # links that must AGREE before a peak is claimed:
                          # one ellipse has no unique point — a single
                          # significant link (noise) paints a sharp fake
                          # peak, while a real body lifts several links
                          # whose ellipses intersect (test-caught).
MIN_LINKS = 4             # min live links carrying excess geometry
FLOOR_WIN_S = 120.0       # per-link quiet-floor window (physical time)
FLOOR_PCT = 10            # floor = this percentile of the window
TRACK_SOFT_SIGMA = 2.2    # display-tracker link gate (detection stays at 3.0).
                          # NOTE the zero: excess is measured from the P10
                          # floor, so a RESTING link already reads ~+1.3σ —
                          # tiers below ~2σ are permanently lit (live-caught:
                          # 4–6 'soft links' glowing at a still desk).
TRACK_ANCHOR_SIGMA = 3.0  # ≥1 link must carry THIS much conviction — soft
                          # links alone are jitter-reachable (test-caught:
                          # a quiet house painted a track from soft noise)
TRACK_MIN_LINKS = 2       # links carrying soft excess for a track update
TRACK_STRONG_ANCHORS = 2  # ≥ this many 2σ links = walking-scale DISPLACEMENT;
                          # fewer = stationary micro-motion (typing, breathing)
                          # — Founder-caught 2026-07-26: "saying im moving when
                          # im not" — micro-motion wobbled the centroid ±cells
TRACK_ALPHA_STRONG = 0.5  # EMA prev-weight while displacing (responsive)
TRACK_ALPHA_WEAK = 0.9    # EMA prev-weight while stationary (converge only)
TRACK_DEADBAND = 0.03     # unit-box: below this, the displayed dot does not move
TRACK_MOVE_MIN = 0.06     # unit-box: a 'moving' claim requires the RAW centroid
                          # to have DISPLACED at least this far — anchor counts
                          # alone can't tell walking from vigorous typing
                          # (test-caught: a persistent 3σ desk link + one tick
                          # of coincident jitter read as walking)
TRACK_STALE_S = 3.0       # a track this old is gone, not held


class LinkFloors:
    """Per-link rolling quiet floor over physical time (see module doc)."""

    def __init__(self, win_s: float = FLOOR_WIN_S, pct: int = FLOOR_PCT):
        self.win_s = float(win_s)
        self.pct = int(pct)
        self._hist: dict[tuple, deque] = {}

    def probe(self, link: tuple, motion: float, t: float) -> tuple | None:
        """Update the link's window; (raw_excess, sigma) once baselined, else
        None (≥ half the window span) — unbaselined links must not paint."""
        h = self._hist.setdefault(link, deque(maxlen=4096))
        h.append((float(t), float(motion)))
        while h and t - h[0][0] > self.win_s:
            h.popleft()
        if len(h) < 24 or t - h[0][0] < 0.5 * self.win_s:
            return None
        vals = np.array([v for _, v in h])
        floor = float(np.percentile(vals, self.pct))
        # QUIET-HALF SIGMA (Founder-caught 2026-07-26 "doesnt track"): a
        # two-sided MAD over the whole window is inflated by the occupant's
        # OWN excursions, so the 3-sigma significance bar rises with activity
        # and a moving body can never clear it — the same self-calibration
        # trap the room baselines hit. The window is "quiet floor + person
        # excursions": estimate the noise from the LOWER half only (deviations
        # below the median), which the person's motion cannot inflate.
        med = float(np.median(vals))
        low = vals[vals <= med]
        spread = float(np.median(np.abs(low - med))) if low.size else 0.0
        sigma = 1.4826 * spread
        return float(motion) - floor, max(sigma, 1e-9)

    def excess(self, link: tuple, motion: float, t: float) -> float | None:
        """SIGNIFICANCE GATE: a link contributes only when its excess clears 3
        robust sigmas (MAD-based) of its own quiet window — otherwise every
        link paints a little noise and the summed ellipse field grows fake
        structure that can out-z any image-level gate (test-caught)."""
        p = self.probe(link, motion, t)
        if p is None:
            return None
        ex, sigma = p
        return ex if ex > 3.0 * sigma else 0.0


class RTImager:
    """Ellipse-kernel back-projection imager (see module docstring)."""

    def __init__(self, grid: int = GRID, lam: float = LAMBDA,
                 z_gate: float = Z_GATE, min_links: int = MIN_LINKS):
        self.grid = int(grid)
        self.lam = float(lam)
        self.z_gate = float(z_gate)
        self.min_links = int(min_links)
        self.floors = LinkFloors()
        self._kernels: dict[tuple, np.ndarray] = {}
        self._geom_sig: tuple | None = None
        xs = (np.arange(self.grid) + 0.5) / self.grid
        self._px = np.stack(np.meshgrid(xs, xs), axis=-1)   # [g, g, 2] (x=col)

    def _nearest_pos_node(self, x: float, y: float):
        """Mapped node id closest to a unit-box position (region -> room)."""
        pos = getattr(self, "_positions", None) or {}
        best, best_d = None, None
        for nid, (px, py) in pos.items():
            d = (px - x) ** 2 + (py - y) ** 2
            if best_d is None or d < best_d:
                best, best_d = int(nid), d
        return best

    # -- geometry -------------------------------------------------------------

    def set_geometry(self, positions: dict[int, np.ndarray]) -> None:
        """(Re)build per-pair kernels when the F6 layout moves meaningfully."""
        sig = tuple(sorted((int(n), round(float(p[0]), 2), round(float(p[1]), 2))
                           for n, p in positions.items()))
        self._positions = {int(n): (float(p[0]), float(p[1]))
                           for n, p in positions.items()}
        if sig == self._geom_sig:
            return
        self._geom_sig = sig
        self._kernels = {}
        ids = sorted(positions)
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                pa = np.asarray(positions[a], np.float64)
                pb = np.asarray(positions[b], np.float64)
                base = float(np.linalg.norm(pb - pa))
                if base < 1e-6:
                    continue
                da = np.linalg.norm(self._px - pa[None, None, :], axis=-1)
                db = np.linalg.norm(self._px - pb[None, None, :], axis=-1)
                k = np.exp(-self.lam * (da + db - base))
                s = float(k.sum())
                if s > 1e-12:
                    self._kernels[frozenset((int(a), int(b)))] = k / s

    # -- imaging ---------------------------------------------------------------

    def update(self, link_motion: dict, t: float,
               positions: dict[int, np.ndarray] | None = None) -> dict | None:
        """link_motion: {(rx, tx): motion_ema} directed; positions: latest F6
        unit layout (optional if geometry already set). Returns the image
        dict, or None when geometry/links are insufficient (never a guess)."""
        if positions is not None:
            self.set_geometry(positions)
        if not self._kernels:
            return None
        # symmetrize directed links, take the stronger direction's motion
        sym: dict[frozenset, float] = {}
        for (rx, tx), m in link_motion.items():
            pair = frozenset((int(rx), int(tx)))
            if len(pair) != 2:
                continue
            sym[pair] = max(sym.get(pair, 0.0), float(m))
        img = np.zeros((self.grid, self.grid))
        img_soft = np.zeros((self.grid, self.grid))
        n_active = 0
        n_sig = 0
        n_soft = 0
        n_anchor = 0
        for pair, motion in sym.items():
            k = self._kernels.get(pair)
            if k is None:
                continue
            p = self.floors.probe(tuple(sorted(pair)), motion, t)
            if p is None:
                continue
            ex, sigma = p
            n_active += 1
            if ex > 3.0 * sigma:
                img += ex * k
                n_sig += 1
            if ex > TRACK_SOFT_SIGMA * sigma:
                img_soft += ex * k
                n_soft += 1
                if ex > TRACK_ANCHOR_SIGMA * sigma:
                    n_anchor += 1
        if n_active < self.min_links:
            return None
        med = float(np.median(img))
        std = float(img.std())
        peak_flat = int(np.argmax(img))
        r, c = divmod(peak_flat, self.grid)
        z = (float(img.max()) - med) / (std + 1e-12) if std > 1e-15 else 0.0
        localized = n_sig >= MIN_SIG and z >= self.z_gate
        top = float(img.max())
        norm = (img / top) if top > 0 else img
        out = {
            "grid": self.grid,
            "image": [[round(float(v), 3) for v in row] for row in norm],
            "links_active": n_active,
            "links_significant": n_sig,
            "z": round(z, 2),
            "localized": bool(localized),
            "basis": ("radio-tomographic MOTION imaging — link-excess "
                      "back-projection on the learned layout; a still body "
                      "fades (presence/vitals own stillness); relative "
                      "frame, not meters"),
        }
        if localized:
            out["peak"] = [round((c + 0.5) / self.grid, 4),
                           round((r + 0.5) / self.grid, 4)]
        # DISPLAY TRACKER (Founder 2026-07-26: "not if im between, or 6 inches
        # closer" — the 3σ gated fix fires rarely, so the dot parked on nodes
        # and read as nearest-puck mapping): a continuous weighted-centroid
        # track over the SOFT field's hot region, EMA-smoothed, snapped onto
        # any gated fix. Display-grade only — detection/alerts stay on the 3σ
        # peak above; the caller gates the track behind an ESTABLISHED
        # occupant so an empty house can never grow a wandering dot (§5.1).
        qualifies = (n_soft >= TRACK_MIN_LINKS and n_anchor >= 1
                     and float(img_soft.max()) > 1e-12)
        # PERSISTENCE: real movement sustains across ticks; a single tick of
        # jitter reaching 2σ on one link does not (test-caught: a quiet house
        # painted a one-tick track). Two consecutive qualifying ticks to emit.
        self._track_streak = (getattr(self, "_track_streak", 0) + 1) if qualifies else 0
        # a 3σ localized fix has already beaten noise (MIN_SIG links + z gate)
        # — it emits immediately; soft-only evidence needs the 2-tick streak
        if qualifies and (localized or self._track_streak >= 2):
            # STILLNESS ≠ MOVEMENT (Founder-caught: 'saying im moving when im
            # not'): walking-scale displacement lifts MANY links far past
            # their floors; a still body's typing/breathing reaches an anchor
            # or two at most. Weak evidence may only CONVERGE the dot (heavy
            # EMA + deadband) and is stamped strong=False so the display
            # keeps saying 'still'. Even a 3σ fix obeys the blend while the
            # world is weak — one fix must not teleport a sitting person.
            # movement claims persist like tracks do: one tick of ≥2 anchors
            # is reachable by coincident jitter at a still desk (test-caught)
            # — two consecutive strong ticks before the display says 'moving'
            strong_now = n_anchor >= TRACK_STRONG_ANCHORS
            self._strong_streak = (getattr(self, "_strong_streak", 0) + 1) if strong_now else 0
            if localized:
                cx, cy = out["peak"][0], out["peak"][1]
            else:
                hot = img_soft >= 0.6 * float(img_soft.max())
                wsum = float(img_soft[hot].sum())
                cx = float((img_soft[hot] * self._px[..., 0][hot]).sum() / wsum)
                cy = float((img_soft[hot] * self._px[..., 1][hot]).sum() / wsum)
            prev = getattr(self, "_track", None)
            prev_fresh = prev is not None and t - prev["t"] <= TRACK_STALE_S
            # WALKING = the SMOOTHED track travels; desk micro-motion flaps
            # DIFFERENT links (arm/leg/torso) so even the raw centroid jumps
            # between link geometries (test-caught) — but the pinned smoothed
            # track goes nowhere. Travel over the last 4 s is the only
            # discriminator that held; walk-start latches in ~3 ticks.
            path = [p for (tt, p) in getattr(self, "_track_path", [])
                    if t - tt <= 4.0]
            if prev_fresh and path:
                travel = math.hypot(prev["pos"][0] - path[0][0],
                                    prev["pos"][1] - path[0][1])
            else:
                travel = TRACK_MOVE_MIN + 1.0   # no history — trust the streak
            strong = self._strong_streak >= 2 and travel > TRACK_MOVE_MIN
            if prev_fresh:
                if localized and strong:
                    pass                    # detection while displacing: snap
                else:
                    a = TRACK_ALPHA_STRONG if strong else TRACK_ALPHA_WEAK
                    cx = a * prev["pos"][0] + (1 - a) * cx
                    cy = a * prev["pos"][1] + (1 - a) * cy
            # INTERNAL track keeps integrating (walk-start must accrue travel
            # to latch strong) — the DISPLAYED position pins to a stillness
            # anchor so weak evidence can never creep the dot (test-caught:
            # the weak EMA random-walked a 'pinned' dot ~a meter across 16 s
            # of desk micro-motion; a per-tick deadband can't stop cumulative
            # drift). The anchor converges toward the internal track at
            # ~3%/tick, so a slightly-off anchor heals without visible motion.
            self._track = {"pos": [round(cx, 4), round(cy, 4)], "t": t}
            tp = getattr(self, "_track_path", None)
            if tp is None:
                tp = self._track_path = deque()
            tp.append((t, tuple(self._track["pos"])))
            while tp and t - tp[0][0] > 6.0:
                tp.popleft()
            if strong:
                self._still_anchor = None
                shown = self._track["pos"]
            else:
                anchor = getattr(self, "_still_anchor", None)
                if anchor is None:
                    anchor = list(self._track["pos"])
                else:
                    anchor = [0.97 * anchor[0] + 0.03 * cx,
                              0.97 * anchor[1] + 0.03 * cy]
                self._still_anchor = anchor
                shown = [round(anchor[0], 4), round(anchor[1], 4)]
            out["track"] = {"pos": shown, "links": n_soft,
                            "strong": bool(strong),
                            "basis": "soft-field centroid — display-grade "
                                     "between-node interpolation, not a detection"}
            # FIELD-ATTRIBUTED REGIONS (Founder 2026-07-26: rooms false-flag
            # because per-node motion averages links that physically CROSS the
            # occupant's room — his body lights other rooms' geometry, and
            # extra nodes only add more crossing links). The field says WHERE
            # the disturbance is: emit each disjoint hot region with its
            # nearest node so room presence can be attributed to actual
            # positions. A second region (second person) needs distance from
            # the first AND real conviction (n_anchor ≥ 3) — one body must
            # never mint two.
            regions = [{"pos": [round(cx, 4), round(cy, 4)],
                        "node": self._nearest_pos_node(cx, cy)}]
            if n_anchor >= 3:
                far = (img_soft >= 0.6 * float(img_soft.max()))
                fy, fx = np.nonzero(far)
                if fx.size:
                    px = (fx + 0.5) / self.grid
                    py = (fy + 0.5) / self.grid
                    dist = np.hypot(px - cx, py - cy)
                    j = int(np.argmax(dist))
                    if dist[j] > 0.30:
                        regions.append({"pos": [round(float(px[j]), 4),
                                                round(float(py[j]), 4)],
                                        "node": self._nearest_pos_node(
                                            float(px[j]), float(py[j]))})
            out["regions"] = regions
        elif getattr(self, "_track", None) is not None \
                and t - self._track["t"] > TRACK_STALE_S:
            self._track = None
        return out
