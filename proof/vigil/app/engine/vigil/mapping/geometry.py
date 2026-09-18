"""F3 — RF self-survey: relative geometry from pairwise link measurements.

The fleet measures every node from every other node (inter-node RSSI, and
optionally the mean CSI amplitude per link) and this module turns that into
a rotation/scale-free 2-D relative layout for *presentation only* — see the
mapping/registry.py design doc: nothing in detection reads coordinates.

Pipeline
--------
1. RSSI -> distance via the log-distance path-loss model
       d = 10 ** ((rssi_1m - rssi) / (10 * n))
   Assumptions (documented, calibratable): `rssi_1m` is the RSSI at 1 m
   (default -40 dBm for ESP32 on-board PCB antennas at 20 dBm TX) and `n`
   is the path-loss exponent (default 2.2; free space 2.0, cluttered indoor
   1.6-3.5). Both are per-home constants; errors in them scale/warp the
   layout but preserve rank order, which is all the downstream adjacency
   graph uses.
2. Classical MDS (Torgerson): double-centre the squared-distance matrix,
   eigendecompose with numpy (no sklearn), keep the top-2 components.
3. Adjacency graph: union of each node's k nearest neighbours on estimated
   distances (or a distance threshold).

Error envelope (be honest): RSSI log-distance ranging indoors is
*meters-scale* noisy (shadowing sigma 3-6 dB -> 30-60 % distance error).
The output is topology-correct, not metric — good for an auto-arranged
floor plan and adjacency sanity checks, not for measuring your hallway.

FTM note: the original ESP32 (WROOM-32, Track A hardware) does NOT support
Wi-Fi FTM / 802.11mc round-trip timing — that arrived with ESP32-S2/S3/C3
and later. RSSI log-distance therefore IS the floor implementation on
current hardware. `solve(ftm_matrix=...)` is the input path for future
silicon: pass metre-valued round-trip distances and they are used directly,
skipping the path-loss model.

Hardware collection (vigilctl fleet survey) is gated; this module takes the
measured matrices as injectable inputs.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .plan import Plan


def rssi_to_distance(rssi, rssi_1m: float = -40.0, exponent: float = 2.2):
    """Log-distance path-loss inversion (see module docstring assumptions)."""
    r = np.asarray(rssi, dtype=np.float64)
    return 10.0 ** ((rssi_1m - r) / (10.0 * exponent))


def classical_mds(dist: np.ndarray, n_dims: int = 2) -> np.ndarray:
    """Torgerson classical MDS via numpy eigendecomposition.

    dist: symmetric [n, n] distance matrix -> [n, n_dims] coordinates
    (centred; rotation/reflection/global-scale arbitrary)."""
    d = np.asarray(dist, np.float64)
    n = d.shape[0]
    d = 0.5 * (d + d.T)  # symmetrize measurement asymmetry
    j = np.eye(n) - np.ones((n, n)) / n
    b = -0.5 * j @ (d ** 2) @ j
    w, v = np.linalg.eigh(b)
    order = np.argsort(w)[::-1][:n_dims]
    w_top = np.clip(w[order], 0.0, None)
    return v[:, order] * np.sqrt(w_top)[None, :]


def procrustes(x: np.ndarray, ref: np.ndarray) -> tuple[np.ndarray, float]:
    """Align x to ref (translation + rotation/reflection + uniform scale).

    Returns (x_aligned, disparity) where disparity is the normalized RMS
    residual vs ref. Test helper — the product never needs absolute pose."""
    x = np.asarray(x, np.float64)
    ref = np.asarray(ref, np.float64)
    xc = x - x.mean(axis=0)
    rc = ref - ref.mean(axis=0)
    nx = np.linalg.norm(xc)
    nr = np.linalg.norm(rc)
    if nx < 1e-12 or nr < 1e-12:
        return x * 0 + ref.mean(axis=0), 1.0
    xc /= nx
    rc /= nr
    u, s, vt = np.linalg.svd(xc.T @ rc)
    rot = u @ vt
    scale = s.sum()
    aligned = scale * (xc @ rot) * nr + ref.mean(axis=0)
    disparity = float(np.sqrt(max(0.0, 1.0 - scale ** 2)))
    return aligned, disparity


def knn_adjacency(positions: dict[int, np.ndarray] | np.ndarray,
                  node_ids: list[int] | None = None,
                  k: int = 2) -> set[frozenset]:
    """Adjacency = union of each node's k nearest neighbours (symmetrized)."""
    if isinstance(positions, dict):
        node_ids = sorted(positions)
        pts = np.array([positions[i] for i in node_ids], np.float64)
    else:
        pts = np.asarray(positions, np.float64)
        node_ids = list(node_ids if node_ids is not None
                        else range(pts.shape[0]))
    n = pts.shape[0]
    d = np.linalg.norm(pts[:, None, :] - pts[None, :, :], axis=-1)
    np.fill_diagonal(d, np.inf)
    edges: set[frozenset] = set()
    for i in range(n):
        for j in np.argsort(d[i])[:min(k, n - 1)]:
            edges.add(frozenset((node_ids[i], node_ids[int(j)])))
    return edges


@dataclass
class SurveyResult:
    node_ids: list[int]
    positions: dict[int, np.ndarray]           # node -> [2] relative coords
    distances: np.ndarray                      # [n, n] estimated distances
    adjacency: set[frozenset] = field(default_factory=set)
    source: str = "rssi"                       # "rssi" | "ftm"


class SelfSurvey:
    """Solve a relative 2-D layout from fleet pairwise measurements."""

    def __init__(self, node_ids: list[int], rssi_1m: float = -40.0,
                 exponent: float = 2.2, k_adjacent: int = 2) -> None:
        self.node_ids = [int(n) for n in node_ids]
        self.rssi_1m = float(rssi_1m)
        self.exponent = float(exponent)
        self.k_adjacent = int(k_adjacent)
        self.result: SurveyResult | None = None

    def solve(self, rssi_matrix: np.ndarray | None = None,
              csi_amp_matrix: np.ndarray | None = None,
              ftm_matrix: np.ndarray | None = None) -> SurveyResult:
        """rssi_matrix[i, j] = RSSI of node j heard at node i (dBm).
        csi_amp_matrix optionally refines the distance estimate (mean CSI
        amplitude falls with path loss; used as a second RSSI-like reading).
        ftm_matrix (metres) bypasses the path-loss model entirely — future
        silicon input path (see module docstring)."""
        n = len(self.node_ids)
        if ftm_matrix is not None:
            dist = np.asarray(ftm_matrix, np.float64)
            source = "ftm"
        else:
            if rssi_matrix is None:
                raise ValueError("need rssi_matrix (or ftm_matrix)")
            dist = rssi_to_distance(rssi_matrix, self.rssi_1m, self.exponent)
            if csi_amp_matrix is not None:
                # mean CSI amplitude ~ received power: convert to a pseudo-RSSI
                # scale and geometric-mean the two distance estimates
                amp = np.clip(np.asarray(csi_amp_matrix, np.float64), 1e-6, None)
                pseudo = 20.0 * np.log10(amp / amp.max()) + self.rssi_1m
                d2 = rssi_to_distance(pseudo, self.rssi_1m, self.exponent)
                dist = np.sqrt(dist * d2)
            source = "rssi"
        if dist.shape != (n, n):
            raise ValueError(f"matrix must be [{n},{n}] for nodes "
                             f"{self.node_ids}, got {dist.shape}")
        dist = 0.5 * (dist + dist.T)
        np.fill_diagonal(dist, 0.0)
        coords = classical_mds(dist, 2)
        positions = {nid: coords[i] for i, nid in enumerate(self.node_ids)}
        self.result = SurveyResult(
            node_ids=list(self.node_ids), positions=positions, distances=dist,
            adjacency=knn_adjacency(positions, k=self.k_adjacent),
            source=source)
        return self.result

    # -- cross-layer consistency ------------------------------------------------

    def sanity_check(self, fingerprint_db, registry=None,
                     top_frac: float = 0.34) -> dict:
        """Fingerprint clusters should respect geometric adjacency.

        Rooms whose fingerprints are most similar (cosine similarity of the
        per-node mean-energy response vectors) should be adjacent in the
        surveyed layout. Returns {"score": fraction of the most-similar room
        pairs that are adjacent, "contradictions": [...]}. A corrupted or
        swapped fingerprint shows up as a similar-but-far pair."""
        if self.result is None:
            raise RuntimeError("call solve() first")
        fps = fingerprint_db.fingerprints
        rooms = sorted(fps)
        if len(rooms) < 3:
            return {"score": 1.0, "contradictions": []}
        node_ids = fingerprint_db.node_ids
        vecs = {}
        for room in rooms:
            fp = fps[room]
            v = np.array([fp.energy_mean[fp.node_ids.index(n)]
                          if n in fp.node_ids else 0.0 for n in node_ids])
            vecs[room] = v / max(np.linalg.norm(v), 1e-12)
        # room adjacency from node adjacency (room of each node)
        room_of = {}
        for nid in self.node_ids:
            if registry is not None:
                room_of[nid] = registry.room_of(nid)
            else:  # fall back: the room where this node responds strongest
                best, best_e = "", -np.inf
                for r in rooms:
                    fp = fps[r]
                    if nid in fp.node_ids:
                        e = float(fp.energy_mean[fp.node_ids.index(nid)])
                        if e > best_e:
                            best, best_e = r, e
                room_of[nid] = best
        room_adj: set[frozenset] = set()
        for edge in self.result.adjacency:
            a, b = tuple(edge)
            ra, rb = room_of.get(a, ""), room_of.get(b, "")
            if ra and rb and ra != rb:
                room_adj.add(frozenset((ra, rb)))
        pairs = [(float(vecs[a] @ vecs[b]), a, b)
                 for i, a in enumerate(rooms) for b in rooms[i + 1:]]
        pairs.sort(reverse=True)
        n_top = max(1, int(round(top_frac * len(pairs))))
        contradictions = []
        hits = 0
        for sim, a, b in pairs[:n_top]:
            if frozenset((a, b)) in room_adj:
                hits += 1
            else:
                contradictions.append({
                    "rooms": [a, b], "similarity": round(sim, 3),
                    "hint": (f"fingerprints of {a!r} and {b!r} look alike "
                             f"(cos {sim:.2f}) but the rooms are not adjacent "
                             "— re-walk both or check node placement")})
        return {"score": hits / n_top, "contradictions": contradictions}

    # -- presentation ---------------------------------------------------------------

    def to_plan(self, registry=None, units: float = 100.0) -> Plan:
        """Auto-arranged floor plan (F4 format): node positions scaled into a
        0..units box, one Voronoi-ish rectangle per node (half-size = 0.45 x
        distance to nearest neighbour — deliberately simple; presentation
        only). Rooms named from the registry when available."""
        if self.result is None:
            raise RuntimeError("call solve() first")
        ids = self.result.node_ids
        pts = np.array([self.result.positions[i] for i in ids], np.float64)
        lo = pts.min(axis=0)
        span = max(float((pts.max(axis=0) - lo).max()), 1e-9)
        pts = (pts - lo) / span * (0.8 * units) + 0.1 * units
        plan = Plan(meta={"source": f"rf-survey-{self.result.source}",
                          "units": "relative"})
        d = np.linalg.norm(pts[:, None, :] - pts[None, :, :], axis=-1)
        np.fill_diagonal(d, np.inf)
        for i, nid in enumerate(ids):
            half = 0.45 * float(d[i].min()) if len(ids) > 1 else 0.4 * units
            x, y = float(pts[i, 0]), float(pts[i, 1])
            room = (registry.room_of(nid) if registry is not None else "") \
                or f"room-{nid}"
            plan.rooms.append({"name": room,
                               "polygon": [[x - half, y - half],
                                           [x + half, y - half],
                                           [x + half, y + half],
                                           [x - half, y + half]]})
            plan.nodes.append({"node_id": int(nid), "xy": [x, y],
                               "room": room})
        return plan
