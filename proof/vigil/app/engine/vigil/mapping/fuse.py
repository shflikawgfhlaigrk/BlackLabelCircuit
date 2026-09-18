"""F6 — fused metric layout: every mapping signal solved into ONE map.

The home has been measured three independent ways and (before this module)
each drew its own, disagreeing picture:

- **F5 traversal times** (transitions.py): the median handoff Δt between two
  nodes is a PHYSICAL measurement — a human walked that gap. × walking speed
  (default 1.2 m/s) it is the most trustworthy inter-node distance we own:
  it needs no propagation model and no calibration constant.
- **F3 RSSI ranging** (geometry.py / the mesh survey): covers ALL pairs
  (traversal only covers walked doorways) but is meters-noisy indoors
  (shadowing 3-6 dB -> 30-60 % distance error) and wall-inflated.
- **Wall inference** (excess-absorption links): tells us which RSSI readings
  are lying (an obstructed link reads farther than it is).

This module solves them JOINTLY: weighted stress majorization (SMACOF,
Guttman transform, numpy only) over a per-pair distance/weight matrix where
traversal distances dominate, RSSI fills the unwalked pairs after a global
scale fit onto the traversal frame, obstructed links are down-weighted, and
pairs with no measurement at all get a low-weight shortest-path composite so
the layout stays connected. A previous solution warm-starts the solver and
the result is Procrustes-anchored back onto it, so the map never spins or
flips between refreshes — it refines in place.

On top of the fused positions:
- `room_cells()` — Voronoi partition of the unit box (half-plane clipping,
  exact) -> a drawable room polygon per node instead of a bare dot;
- `doors()` — every learned adjacency gets a portal placed on the shared
  cell boundary, carrying traffic, median walk seconds and peak hour.

HONESTY ENVELOPE: traversal Δt includes coverage-gap and reaction time, so
absolute scale is approximate everywhere; the fused layout is
topology-correct and *relatively* metric (walked pairs are rank- and
ratio-faithful), not a floor plan. Presentation only: detection never reads
coordinates (registry.py design rule). `FusedResult.provenance` says exactly
which signals were fused so no UI can oversell it.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .geometry import classical_mds, procrustes, rssi_to_distance
from .transitions import TransitionGraph

WALK_SPEED_MPS = 1.2          # indoor walking speed prior
W_TRAVERSAL = 1.0             # weight: a human walked it
W_RSSI = 0.25                 # weight: propagation model guess
W_RSSI_OBSTRUCTED = 0.08      # weight: propagation model known to be lying
W_COMPOSITE = 0.04            # weight: shortest-path fill (connectivity only)


# ---------------------------------------------------------------------------
# distance assembly
# ---------------------------------------------------------------------------

def traversal_distance_matrix(graph: TransitionGraph, node_ids: list[int],
                              speed_mps: float = WALK_SPEED_MPS,
                              t_now: float | None = None,
                              min_weight: float = 2.0
                              ) -> tuple[np.ndarray, np.ndarray]:
    """Walked-pair distances from median handoff Δt (see module docstring).

    Returns (dist, weight) [n, n]; weight 0 where the pair was never walked.
    Per-pair confidence grows with evidence: w = W_TRAVERSAL·log1p(sym_w)."""
    n = len(node_ids)
    dist = np.zeros((n, n))
    weight = np.zeros((n, n))
    for i, a in enumerate(node_ids):
        for j, b in enumerate(node_ids):
            if j <= i:
                continue
            sym = graph.weight(a, b, t_now) + graph.weight(b, a, t_now)
            if sym < min_weight:
                continue
            dt = graph.traversal_seconds(a, b)
            if dt is None:
                continue
            d = float(dt) * speed_mps
            w = W_TRAVERSAL * float(np.log1p(sym))
            dist[i, j] = dist[j, i] = d
            weight[i, j] = weight[j, i] = w
    return dist, weight


def _fit_scale(d_target: np.ndarray, w_target: np.ndarray,
               d_source: np.ndarray) -> float:
    """Least-squares scalar s minimizing Σ w (s·d_source − d_target)² over
    pairs measured in BOTH frames. 1.0 when the frames never overlap."""
    mask = (w_target > 0) & (d_source > 0)
    if not mask.any():
        return 1.0
    num = float(np.sum(w_target[mask] * d_source[mask] * d_target[mask]))
    den = float(np.sum(w_target[mask] * d_source[mask] ** 2))
    return num / den if den > 1e-12 else 1.0


def _shortest_path_fill(dist: np.ndarray, weight: np.ndarray
                        ) -> tuple[np.ndarray, np.ndarray]:
    """Floyd–Warshall composite distances for unmeasured pairs (low weight,
    connectivity only). Unreachable pairs stay weight-0 (SMACOF ignores)."""
    n = dist.shape[0]
    d = np.where(weight > 0, dist, np.inf)
    np.fill_diagonal(d, 0.0)
    for k in range(n):
        d = np.minimum(d, d[:, k:k + 1] + d[k:k + 1, :])
    out_d = dist.copy()
    out_w = weight.copy()
    fill = (weight <= 0) & np.isfinite(d) & ~np.eye(n, dtype=bool)
    out_d[fill] = d[fill]
    out_w[fill] = W_COMPOSITE
    return out_d, out_w


# ---------------------------------------------------------------------------
# weighted stress majorization (SMACOF)
# ---------------------------------------------------------------------------

def smacof(dist: np.ndarray, weight: np.ndarray, init: np.ndarray,
           iters: int = 200, eps: float = 1e-7) -> tuple[np.ndarray, float]:
    """Guttman-transform stress majorization. dist/weight symmetric [n, n]
    (weight 0 = ignore pair); init [n, 2]. Returns (positions, stress) with
    stress normalized by Σ w d² (0 = perfect fit)."""
    n = dist.shape[0]
    w = 0.5 * (weight + weight.T).astype(np.float64)
    d = 0.5 * (dist + dist.T).astype(np.float64)
    np.fill_diagonal(w, 0.0)
    x = np.asarray(init, np.float64).copy()
    v = -w.copy()
    np.fill_diagonal(v, w.sum(axis=1))
    v_pinv = np.linalg.pinv(v)
    denom = float(np.sum(w * d ** 2)) or 1.0
    stress = np.inf
    for _ in range(max(1, iters)):
        delta = x[:, None, :] - x[None, :, :]
        dx = np.linalg.norm(delta, axis=-1)
        np.fill_diagonal(dx, 1.0)
        ratio = np.where(dx > 1e-12, w * d / dx, 0.0)
        b = -ratio
        np.fill_diagonal(b, ratio.sum(axis=1))
        x_new = v_pinv @ (b @ x)
        new_stress = float(np.sum(w * (d - _pairwise(x_new)) ** 2)) / denom
        if abs(stress - new_stress) < eps:
            x = x_new
            stress = new_stress
            break
        x, stress = x_new, new_stress
    return x, float(stress)


def _pairwise(x: np.ndarray) -> np.ndarray:
    d = np.linalg.norm(x[:, None, :] - x[None, :, :], axis=-1)
    np.fill_diagonal(d, 0.0)
    return d


# ---------------------------------------------------------------------------
# the fused solver
# ---------------------------------------------------------------------------

@dataclass
class FusedResult:
    node_ids: list[int]
    positions: dict[int, np.ndarray]        # metric-ish frame (m-scale)
    unit_positions: dict[int, np.ndarray]   # 0..1 box, UI-ready
    stress: float                           # normalized SMACOF residual
    provenance: list[str] = field(default_factory=list)
    n_measured: dict[int, int] = field(default_factory=dict)  # constraints/node

    def confidence(self, node_id: int) -> float:
        """0..1: how pinned-down this node is (measured pairs vs possible)."""
        n = len(self.node_ids)
        if n <= 1:
            return 0.0
        return min(1.0, self.n_measured.get(int(node_id), 0) / (n - 1))


class FusedLayout:
    """Joint traversal + RSSI + walls layout solver (see module docstring)."""

    def __init__(self, speed_mps: float = WALK_SPEED_MPS,
                 rssi_1m: float = -40.0, exponent: float = 2.2,
                 min_edge_weight: float = 2.0) -> None:
        self.speed_mps = float(speed_mps)
        self.rssi_1m = float(rssi_1m)
        self.exponent = float(exponent)
        self.min_edge_weight = float(min_edge_weight)

    def solve(self, graph: TransitionGraph | None = None,
              t_now: float | None = None,
              rssi: np.ndarray | None = None,
              rssi_ids: list[int] | None = None,
              obstructed: set[frozenset] | None = None,
              prev: FusedResult | None = None,
              iters: int = 200) -> FusedResult | None:
        """Fuse whatever is available; None when under 3 nodes or nothing is
        measured (never a fabricated map). `obstructed` is the wall-inference
        pair set {frozenset((a, b)), ...}; `prev` anchors orientation."""
        ids: set[int] = set()
        if graph is not None:
            ids.update(graph.nodes())
        if rssi_ids:
            ids.update(int(i) for i in rssi_ids)
        node_ids = sorted(ids)
        n = len(node_ids)
        if n < 3:
            return None
        provenance: list[str] = []

        dist = np.zeros((n, n))
        weight = np.zeros((n, n))
        if graph is not None:
            dist, weight = traversal_distance_matrix(
                graph, node_ids, self.speed_mps, t_now, self.min_edge_weight)
            if (weight > 0).any():
                provenance.append(
                    f"traversal-times ({int((weight > 0).sum() // 2)} walked "
                    f"pairs × {self.speed_mps} m/s)")

        if rssi is not None and rssi_ids:
            d_r, w_r = self._rssi_matrices(rssi, rssi_ids, node_ids,
                                           obstructed)
            if (w_r > 0).any():
                s = _fit_scale(dist, weight, d_r)
                d_r *= s
                both = (w_r > 0) & (weight > 0)     # blend where both measured
                dist[both] = ((weight[both] * dist[both]
                               + w_r[both] * d_r[both])
                              / (weight[both] + w_r[both]))
                weight[both] += w_r[both]
                only = (w_r > 0) & ~both            # RSSI fills unwalked pairs
                dist[only] = d_r[only]
                weight[only] = w_r[only]
                provenance.append(
                    f"rssi-ranging (scale-fit ×{s:.2f}"
                    + (f", {len(obstructed)} obstructed links down-weighted"
                       if obstructed else "") + ")")

        if not (weight > 0).any():
            return None
        dist, weight = _shortest_path_fill(dist, weight)

        if prev is not None and set(prev.node_ids) >= set(node_ids):
            init = np.array([prev.positions[i] for i in node_ids])
            provenance.append("warm-start (anchored to previous solve)")
        else:
            seed = np.where(weight > 0, dist, float(dist[weight > 0].mean()
                                                    if (weight > 0).any()
                                                    else 1.0))
            np.fill_diagonal(seed, 0.0)
            init = classical_mds(seed, 2)

        pos, stress = smacof(dist, weight, init, iters=iters)
        if prev is not None:
            ref = np.array([prev.positions[i] for i in node_ids
                            if i in prev.positions])
            if ref.shape[0] == n:
                pos, _ = procrustes(pos, ref)

        positions = {nid: pos[i] for i, nid in enumerate(node_ids)}
        lo = pos.min(axis=0)
        span = max(float((pos.max(axis=0) - lo).max()), 1e-9)
        unit = {nid: (pos[i] - lo) / span * 0.84 + 0.08
                for i, nid in enumerate(node_ids)}
        measured = {nid: int(((weight[i] > W_COMPOSITE)).sum())
                    for i, nid in enumerate(node_ids)}
        return FusedResult(node_ids=node_ids, positions=positions,
                           unit_positions=unit, stress=stress,
                           provenance=provenance, n_measured=measured)

    def _rssi_matrices(self, rssi: np.ndarray, rssi_ids: list[int],
                       node_ids: list[int],
                       obstructed: set[frozenset] | None
                       ) -> tuple[np.ndarray, np.ndarray]:
        """RSSI matrix (indexed by rssi_ids) -> (dist, weight) on node_ids."""
        r = np.asarray(rssi, np.float64)
        pos_of = {int(nid): k for k, nid in enumerate(rssi_ids)}
        n = len(node_ids)
        dist = np.zeros((n, n))
        weight = np.zeros((n, n))
        obstructed = obstructed or set()
        for i, a in enumerate(node_ids):
            for j, b in enumerate(node_ids):
                if j <= i or a not in pos_of or b not in pos_of:
                    continue
                va, vb = r[pos_of[a], pos_of[b]], r[pos_of[b], pos_of[a]]
                vals = [v for v in (va, vb) if np.isfinite(v) and v != 0.0]
                if not vals:
                    continue
                d = float(rssi_to_distance(float(np.mean(vals)),
                                           self.rssi_1m, self.exponent))
                w = (W_RSSI_OBSTRUCTED if frozenset((a, b)) in obstructed
                     else W_RSSI)
                dist[i, j] = dist[j, i] = d
                weight[i, j] = weight[j, i] = w
        return dist, weight


# ---------------------------------------------------------------------------
# room cells: a drawable polygon per node (exact Voronoi in the unit box)
# ---------------------------------------------------------------------------

UNIT_BOX = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]


def room_cells(unit_positions: dict[int, np.ndarray],
               box: list[list[float]] | None = None
               ) -> dict[int, list[list[float]]]:
    """Voronoi cell per node via half-plane clipping (Sutherland–Hodgman
    against every bisector). Exact for the ≤ tens of nodes a home has."""
    ids = sorted(unit_positions)
    box = box or UNIT_BOX
    cells: dict[int, list[list[float]]] = {}
    for a in ids:
        pa = np.asarray(unit_positions[a], np.float64)
        poly = [list(map(float, p)) for p in box]
        for b in ids:
            if b == a or not poly:
                continue
            pb = np.asarray(unit_positions[b], np.float64)
            nvec = pb - pa                      # keep points with n·x <= c
            c = float(nvec @ (pa + pb) / 2.0)
            poly = _clip_halfplane(poly, nvec, c)
        cells[a] = [[round(x, 4), round(y, 4)] for x, y in poly]
    return cells


def _clip_halfplane(poly: list, nvec: np.ndarray, c: float) -> list:
    """Sutherland–Hodgman: keep {x : n·x <= c}."""
    out: list = []
    m = len(poly)
    for k in range(m):
        p, q = np.asarray(poly[k]), np.asarray(poly[(k + 1) % m])
        dp, dq = float(nvec @ p) - c, float(nvec @ q) - c
        if dp <= 1e-12:
            out.append([float(p[0]), float(p[1])])
        if (dp < -1e-12 < dq) or (dq < -1e-12 < dp):
            t = dp / (dp - dq)
            hit = p + t * (q - p)
            out.append([float(hit[0]), float(hit[1])])
    return out


# ---------------------------------------------------------------------------
# doors: portals on shared cell boundaries, from the learned adjacency
# ---------------------------------------------------------------------------

def doors(graph: TransitionGraph, cells: dict[int, list[list[float]]],
          unit_positions: dict[int, np.ndarray],
          t_now: float | None = None,
          min_weight: float = 2.0) -> list[dict]:
    """One portal per learned adjacency edge: positioned at the midpoint of
    the shared Voronoi boundary (fallback: midpoint of the node segment),
    carrying traffic, median walk seconds and the peak transit hour."""
    out: list[dict] = []
    for pair in graph.adjacency(min_weight=min_weight, t_now=t_now):
        a, b = sorted(pair)
        if a not in unit_positions or b not in unit_positions:
            continue
        seg = _shared_boundary(cells.get(a, []), cells.get(b, []))
        if seg is not None:
            mid = [(seg[0][0] + seg[1][0]) / 2, (seg[0][1] + seg[1][1]) / 2]
        else:
            pa, pb = unit_positions[a], unit_positions[b]
            mid = [float((pa[0] + pb[0]) / 2), float((pa[1] + pb[1]) / 2)]
        traffic = graph.weight(a, b, t_now) + graph.weight(b, a, t_now)
        tod = np.zeros(24)
        for key in ((a, b), (b, a)):
            e = graph.edges.get(key)
            if e is not None:
                tod += e.tod
        entry = {"a": a, "b": b, "pos": [round(mid[0], 4), round(mid[1], 4)],
                 "traffic": round(float(traffic), 2),
                 "walk_s": graph.traversal_seconds(a, b),
                 "peak_hour": int(np.argmax(tod)) if tod.sum() else None}
        if seg is not None:
            entry["boundary"] = [[round(v, 4) for v in seg[0]],
                                 [round(v, 4) for v in seg[1]]]
        out.append(entry)
    out.sort(key=lambda d: -d["traffic"])
    return out


# ---------------------------------------------------------------------------
# walls: real wall segments from physics + the learned adjacency
# ---------------------------------------------------------------------------

WALL_LOSS_DB = 6.0            # excess absorption that means "something solid"
MATERIAL_HINTS = (            # (upper loss dB, honest hint)
    (9.0, "light partition (drywall / hollow door)"),
    (14.0, "dense wall (brick / masonry)"),
    (float("inf"), "heavy structure (concrete / multiple walls)"),
)


def excess_loss_map(rssi: np.ndarray, rssi_ids: list[int],
                    positions: dict[int, np.ndarray],
                    ) -> dict[frozenset, float]:
    """Per-link excess absorption (dB) against THIS home's own path-loss fit.

    Fit rssi ~ slope·log10(d) + intercept over all links using the solved
    (metric-ish) positions, then loss = fit − measured. Positive loss means
    the link is eating more signal than free air at that distance — a wall,
    a floor, a fridge. Self-calibrating: no absolute model constants."""
    ids = [int(i) for i in rssi_ids if int(i) in positions]
    if len(ids) < 3:
        return {}
    r = np.asarray(rssi, np.float64)
    at = {int(nid): k for k, nid in enumerate(rssi_ids)}
    pairs, x, y = [], [], []
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            va, vb = r[at[a], at[b]], r[at[b], at[a]]
            vals = [v for v in (va, vb) if np.isfinite(v) and v != 0.0]
            if not vals:
                continue
            d = max(float(np.linalg.norm(positions[a] - positions[b])), 1e-3)
            pairs.append(frozenset((a, b)))
            x.append(10.0 * math.log10(d))
            y.append(float(np.mean(vals)))
    if len(pairs) < 3:
        return {}
    xa = np.array(x)
    ya = np.array(y)
    A = np.vstack([xa, np.ones_like(xa)]).T
    (slope, intercept), *_ = np.linalg.lstsq(A, ya, rcond=None)
    return {p: round(float((slope * xi + intercept) - yi), 1)
            for p, xi, yi in zip(pairs, xa, ya)}


def footprint(unit_positions: dict[int, np.ndarray],
              pad: float = 0.10) -> list[list[float]]:
    """Coverage outline: convex hull of the node positions inflated by
    `pad`, clipped to the unit box. An honest footprint for room_cells —
    the map covers what the fleet senses, it does not invent the house."""
    pts = np.array([unit_positions[i] for i in sorted(unit_positions)],
                   np.float64)
    if pts.shape[0] < 3:
        return [list(p) for p in UNIT_BOX]
    hull = _hull(pts)
    if len(hull) < 3:
        return [list(p) for p in UNIT_BOX]
    centre = np.mean(np.array(hull), axis=0)
    out = []
    for p in hull:
        v = np.array(p) - centre
        norm = float(np.linalg.norm(v)) or 1.0
        q = np.array(p) + v / norm * pad
        out.append([float(np.clip(q[0], 0.0, 1.0)),
                    float(np.clip(q[1], 0.0, 1.0))])
    return out


def _hull(pts: np.ndarray) -> list[list[float]]:
    """Andrew monotone chain, CCW."""
    p = sorted({(round(float(a), 9), round(float(b), 9)) for a, b in pts})
    if len(p) <= 2:
        return [[a, b] for a, b in p]

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lo, hi = [], []
    for q in p:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], q) <= 0:
            lo.pop()
        lo.append(q)
    for q in reversed(p):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], q) <= 0:
            hi.pop()
        hi.append(q)
    return [[a, b] for a, b in lo[:-1] + hi[:-1]]


def material_hint(loss_db: float) -> str:
    for cap, hint in MATERIAL_HINTS:
        if loss_db <= cap:
            return hint
    return MATERIAL_HINTS[-1][1]


def wall_map(graph: TransitionGraph, cells: dict[int, list[list[float]]],
             unit_positions: dict[int, np.ndarray],
             losses: dict[frozenset, float] | None = None,
             t_now: float | None = None, min_weight: float = 2.0,
             wall_db: float = WALL_LOSS_DB) -> dict:
    """THE WALL MAP: classify every shared room boundary from two
    independent facts — was it WALKED (learned adjacency: people pass
    here) and is it OBSTRUCTED (excess RF absorption: something solid
    stands here)?

        walked + obstructed  -> "wall+door"   wall drawn with a door gap
        walked + clear       -> "open-passage" no wall claimed, passage mark
        unwalked + obstructed-> "wall"         solid wall, full boundary
        unwalked + clear     -> "open"         nothing drawn (open plan)

    HONESTY: without loss measurements nothing is ever labeled a wall —
    walked boundaries render as passages and the rest as open. Every wall
    carries its measured loss_db and a material HINT (labeled a hint)."""
    losses = losses or {}
    walked = {frozenset(p) for p in
              graph.adjacency(min_weight=min_weight, t_now=t_now)}
    door_of = {frozenset((d["a"], d["b"])): d
               for d in doors(graph, cells, unit_positions,
                              t_now=t_now, min_weight=min_weight)}
    ids = sorted(unit_positions)
    walls: list[dict] = []
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            seg = _shared_boundary(cells.get(a, []), cells.get(b, []))
            if seg is None:
                continue
            pair = frozenset((a, b))
            loss = float(losses.get(pair, 0.0))
            is_walked = pair in walked
            is_wall = loss >= wall_db
            if is_walked and is_wall:
                kind = "wall+door"
            elif is_walked:
                kind = "open-passage"
            elif is_wall:
                kind = "wall"
            else:
                kind = "open"
            entry: dict = {
                "a": a, "b": b, "kind": kind,
                "boundary": [[round(v, 4) for v in seg[0]],
                             [round(v, 4) for v in seg[1]]],
                "loss_db": round(loss, 1),
            }
            if is_wall:
                entry["material_hint"] = material_hint(loss)
            door = door_of.get(pair)
            if kind == "wall+door":
                entry["door"] = door
                entry["segments"] = _carve_door(seg, door["pos"])
            elif kind == "wall":
                entry["segments"] = [entry["boundary"]]
            elif kind == "open-passage":
                entry["passage"] = door
                entry["segments"] = []
            else:
                entry["segments"] = []
            walls.append(entry)
    walls.sort(key=lambda w: (-w["loss_db"], w["a"], w["b"]))
    return {
        "walls": walls,
        "outline": footprint(unit_positions),
        "basis": ("walls = walked-adjacency × excess-RF-absorption; "
                  "material labels are hints, outline is sensing coverage "
                  "— not architecture"),
    }


def _carve_door(seg, door_pos, gap: float = 0.05):
    """Split a boundary segment into two wall pieces around the door gap.
    The door is projected onto the segment and the gap clamped inside it."""
    p0 = np.asarray(seg[0], np.float64)
    p1 = np.asarray(seg[1], np.float64)
    v = p1 - p0
    length = float(np.linalg.norm(v))
    if length < 1e-9:
        return [[[float(p0[0]), float(p0[1])], [float(p1[0]), float(p1[1])]]]
    u = v / length
    t = float(np.clip((np.asarray(door_pos) - p0) @ u, 0.0, length))
    half = min(gap, 0.35 * length)
    lo, hi = max(0.0, t - half), min(length, t + half)
    segs = []
    if lo > 0.02 * length:
        q = p0 + u * lo
        segs.append([[round(float(p0[0]), 4), round(float(p0[1]), 4)],
                     [round(float(q[0]), 4), round(float(q[1]), 4)]])
    if hi < 0.98 * length:
        q = p0 + u * hi
        segs.append([[round(float(q[0]), 4), round(float(q[1]), 4)],
                     [round(float(p1[0]), 4), round(float(p1[1]), 4)]])
    return segs


def _shared_boundary(pa: list, pb: list, eps: float = 1e-3):
    """Longest segment of vertices the two cell polygons share (the bisector
    edge). None when the cells don't touch."""
    if not pa or not pb:
        return None
    shared = []
    for v in pa:
        for u in pb:
            if abs(v[0] - u[0]) < eps and abs(v[1] - u[1]) < eps:
                shared.append(v)
                break
    if len(shared) < 2:
        return None
    best, best_d = None, -1.0
    for i in range(len(shared)):
        for j in range(i + 1, len(shared)):
            d = ((shared[i][0] - shared[j][0]) ** 2
                 + (shared[i][1] - shared[j][1]) ** 2)
            if d > best_d:
                best, best_d = (shared[i], shared[j]), d
    return best
