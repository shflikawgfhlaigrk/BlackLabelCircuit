"""Vigil F5–F7 — the home maps, names, WALLS and predicts itself.

This is the differentiator (PATENT_NOTEBOOK F5/F6/F7): NO manual room
assignment, NO ranging hardware, NO floor plan. From a person simply living
in a home wired with commodity $5 nodes:

  1. ADJACENCY self-learns from motion handoffs (F5, vigil_transitions):
     presence pulse on B within a human traversal window of a departure
     from A = a directed A→B edge. The edges ARE the home's connectivity.

  2. ROOM NAMES self-assign from behavioral RF evidence: nightly breathing
     → bedroom; steam → bathroom; appliance + mealtime doors → kitchen;
     daytime transit centrality → living. Conflicts → "unlabeled", never a
     guess. (vigil_transitions.BehavioralLabeler)

  3. GEOMETRY fuses every measurement into ONE metric-ish map (F6,
     vigil_fuse): median handoff walk-times × 1.2 m/s (a human physically
     walked each doorway — the most trustworthy distance we own) + the mesh
     survey's pairwise RSSI (scale-fit onto the walk-time frame, obstructed
     links down-weighted), solved by weighted SMACOF and Procrustes-anchored
     so the map refines in place instead of spinning.

  4. WALLS come from physics × behavior (F6.5): every shared room boundary
     is classified by walked-adjacency × excess-RF-absorption —
     wall+door / open-passage / solid wall / open. Loss dB → material HINT.
     No loss measurement → no wall claimed, ever.

  5. WHO-IS-WHERE is a belief, not a guess (F7, vigil_tracker): an HMM
     whose transition prior is the learned graph itself — a one-tick RF
     ghost cannot teleport the occupant through a wall — with AWAY as a
     first-class state, a confidence-stamped trajectory, learned per-room
     dwell medians and hour-conditioned next-room prediction.

State persists to ~/.vigil/home_graph.json so it compounds over weeks.
Positions/walls are presentation only: detection never reads coordinates.
"""

from __future__ import annotations

import json
import math
import os
import time

import numpy as np

from vigil_transitions import TransitionGraph, BehavioralLabeler
from vigil_fuse import (FusedLayout, WALL_LOSS_DB, doors, excess_loss_map,
                        room_cells, wall_map)
from vigil_tracker import AWAY, NextRoomPredictor, RoomTracker

import vigil_paths

EVIDENCE_CAP = 20000

_STATE_FILES = {
    "GRAPH_PATH": "home_graph.json",
    "ROOMPLAN_PATH": "roomplan.json",
    "USER_WALLS_PATH": "user_walls.json",
}


# These resolve through vigil_paths on every ACCESS, never at import: a constant frozen at
# import time ignores an override set afterwards. PEP 562 module __getattr__ keeps the public
# names while making them honour VIGIL_HOME / HOMEFRONT_DATA_DIR. Note __getattr__ does NOT
# fire for bare global lookups inside this module, so code below calls state_path() directly.
def __getattr__(name):
    if name in _STATE_FILES:
        return vigil_paths.state_path(_STATE_FILES[name])
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def _clean_wall(wall: dict) -> dict | None:
    try:
        a, b = wall.get("a"), wall.get("b")
        if not (isinstance(a, list) and isinstance(b, list)
                and len(a) == 2 and len(b) == 2):
            return None
        aa = [min(1.0, max(0.0, float(a[0]))), min(1.0, max(0.0, float(a[1])))]
        bb = [min(1.0, max(0.0, float(b[0]))), min(1.0, max(0.0, float(b[1])))]
        if abs(aa[0] - bb[0]) < 0.0005 and abs(aa[1] - bb[1]) < 0.0005:
            return None
        return {"a": [round(aa[0], 4), round(aa[1], 4)],
                "b": [round(bb[0], 4), round(bb[1], 4)]}
    except Exception:
        return None


def load_user_walls(path: str | None = None) -> list:
    """Validated owner wall overlays from disk.

    The Swift app and engine both use this schema. Bad/corrupt files degrade to
    an empty overlay; they never block the live map.

    `path=None` resolves the override-aware default at CALL time. A default of
    `USER_WALLS_PATH` would bind at def time and pin the owner's real home for the
    life of the process, defeating VIGIL_HOME.
    """
    if path is None:
        path = vigil_paths.state_path("user_walls.json")
    try:
        with open(path) as f:
            raw = json.load(f)
    except Exception:
        return []
    if not isinstance(raw, list):
        return []
    walls = []
    seen = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        wall = _clean_wall(item)
        if wall is None:
            continue
        key = tuple(wall["a"] + wall["b"])
        if key in seen:
            continue
        seen.add(key)
        walls.append(wall)
    return walls


def append_user_wall(a, b, path: str | None = None) -> list:
    """Append one owner wall correction atomically and return the full store.

    `path=None` resolves the override-aware default at CALL time (see load_user_walls).
    """
    if path is None:
        path = vigil_paths.state_path("user_walls.json")
    wall = _clean_wall({"a": list(a), "b": list(b)})
    if wall is None:
        return load_user_walls(path)
    walls = load_user_walls(path)
    if tuple(wall["a"] + wall["b"]) not in {tuple(w["a"] + w["b"]) for w in walls}:
        walls.append(wall)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(walls, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
    return walls


class HomeModel:
    """Live wrapper: feed presence pulses + behavioral events + survey RSSI
    + per-tick room scores; get the self-learned, self-labeled, self-walled
    home with occupancy belief and habit prediction."""

    def __init__(self):
        # real time (wall clock) so night/meal-hour behavioral priors are correct.
        self.graph = TransitionGraph(fs=1.0)
        self.evidence: list[dict] = []
        self.tracker = RoomTracker(self.graph)
        self._present = {}            # node_id -> bool (last state, for edges)
        self._pulses = 0
        self._survey = None           # (node_ids, rssi_matrix) latest mesh survey
        self._fused = None            # last FusedResult (warm start + anchor)
        self._obstructed = set()      # wall pairs fed back into the next solve
        self.room_names = {}          # node -> paired room name (fleet manifest
                                      # ground truth beats a behavioral guess)
        self._load()

    # -- inputs (called by the engine each tick) -----------------------------

    def observe(self, node_id: int, present: bool, t: float):
        """Rising edge of room presence = a motion pulse on that node."""
        was = self._present.get(node_id, False)
        if present and not was:
            self.graph.pulse(int(node_id), float(t))
            self._pulses += 1
        self._present[node_id] = present

    def observe_scores(self, scores: dict, t: float):
        """Per-tick excess-over-baseline per LIVE node -> F7 belief update."""
        try:
            self.tracker.update({int(k): float(v) for k, v in scores.items()},
                                float(t))
        except Exception:
            pass   # belief is additive intelligence; never take sensing down

    def add_evidence(self, topic: str, node_id: int, t: float, label: str = ""):
        """A behavioral RF event that helps name a room (breathing at night,
        steam, fridge signature, mealtime door). Node ids + timestamps only."""
        self.evidence.append({"topic": topic, "node_id": int(node_id),
                              "t": float(t), "label": label})
        if len(self.evidence) > EVIDENCE_CAP:
            del self.evidence[:EVIDENCE_CAP // 4]

    def set_survey_links(self, links: dict, node_ids):
        """Latest mesh survey: {'a-b': rssi_dbm} symmetric link readings
        (vigil_map geometry JSON shape) -> the F6 fusion input."""
        try:
            ids = sorted(int(i) for i in node_ids)
            at = {nid: k for k, nid in enumerate(ids)}
            m = np.zeros((len(ids), len(ids)))
            n_links = 0
            for key, val in (links or {}).items():
                a, b = (int(x) for x in str(key).split("-", 1))
                if a in at and b in at:
                    m[at[a], at[b]] = m[at[b], at[a]] = float(val)
                    n_links += 1
            if len(ids) >= 3 and n_links >= 3:
                self._survey = (ids, m)
        except Exception:
            pass

    # -- output (served in /frame) -------------------------------------------

    def learned_map(self, t_now: float | None = None) -> dict:
        """The self-learned home: labeled nodes, fused metric-ish positions,
        room cells, WALLS with doors and material hints, occupancy belief,
        trajectory and next-room prediction. `learning:true` until adjacency
        is meaningful. All keys additive over the b5 contract."""
        t_now = time.time() if t_now is None else t_now
        adj = self.graph.adjacency(min_weight=1.5, t_now=t_now)
        nodes = self.graph.nodes()
        weights = self.graph.weights(t_now)

        labels = {}
        if nodes:
            try:
                labels = BehavioralLabeler(self.graph, self.evidence).label()
            except Exception:
                labels = {}

        # F6: fused layout (walk-times + survey RSSI); spring fallback
        fused = None
        try:
            rssi_ids, rssi = self._survey if self._survey else (None, None)
            fused = FusedLayout(min_edge_weight=1.5).solve(
                graph=self.graph, t_now=t_now, rssi=rssi, rssi_ids=rssi_ids,
                obstructed=self._obstructed, prev=self._fused)
        except Exception:
            fused = None
        if fused is not None:
            self._fused = fused
            pos = {n: fused.unit_positions[n] for n in fused.node_ids}
            all_nodes = fused.node_ids
        else:
            pos = self._layout(nodes, adj, weights)
            all_nodes = nodes

        # F6.5: cells + walls + doors (needs >= 3 placed nodes)
        cells, wm, door_list, losses = {}, None, [], {}
        if len(pos) >= 3:
            try:
                cells = room_cells(pos)
                if fused is not None and self._survey is not None:
                    losses = excess_loss_map(self._survey[1], self._survey[0],
                                             fused.positions)
                    self._obstructed = {p for p, v in losses.items()
                                        if v >= WALL_LOSS_DB}
                wm = wall_map(self.graph, cells, pos, losses,
                              t_now=t_now, min_weight=1.5)
                door_list = doors(self.graph, cells, pos,
                                  t_now=t_now, min_weight=1.5)
            except Exception:
                cells, wm, door_list = {}, None, []

        edges = []
        seen = set()
        for pair in adj:
            a, b = sorted(pair)
            if (a, b) in seen:
                continue
            seen.add((a, b))
            edges.append({"a": a, "b": b,
                          "w": round(weights.get((a, b), 0) + weights.get((b, a), 0), 2)})

        node_out = {}
        display_of = {}
        for n in all_nodes:
            lab = labels.get(n, {})
            name = lab.get("label", "unlabeled")
            display = (self.room_names.get(n)
                       or self._display_name(n, name, lab.get("confidence", 0.0)))
            display_of[n] = display
            p = pos.get(n)
            node_out[str(n)] = {
                "label": name,
                "display": display,
                "confidence": round(float(lab.get("confidence", 0.0)), 2),
                "hypotheses": lab.get("hypotheses", []),
                "pos": ([round(float(p[0]), 4), round(float(p[1]), 4)]
                        if p is not None else [0.5, 0.5]),
                "cell": cells.get(n, []),
                "placement": (round(fused.confidence(n), 2)
                              if fused is not None else 0.0),
            }

        # F7: occupancy belief + habit prediction
        occupancy, predict = None, []
        try:
            occupancy = self.tracker.snapshot(
                room_name=lambda n: display_of.get(n, f"node-{n}"))
            best = occupancy["best"]["state"]
            if best != AWAY:
                predict = [
                    {**e, "room": display_of.get(e["node"], f"node-{e['node']}")}
                    for e in NextRoomPredictor(self.graph, self.tracker)
                    .predict(int(best), t_now)]
        except Exception:
            occupancy, predict = None, []

        out = {
            "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(t_now)),
            "source": ("F5–F7 self-mapping — walk-time × RSSI fused layout, "
                       "physics-classified walls, belief-tracked occupancy"),
            "envelope": ("learned from movement + this home's own RF physics; "
                         "no manual setup, no floor plan — walls/materials are "
                         "measured hints, not architecture"),
            "learning": len(edges) == 0,
            "pulses": self._pulses,
            "handoffs": len(self.graph.edges),
            "metric": fused is not None,
            "nodes": node_out,
            "edges": edges,
            "doors": door_list,
            "occupancy": occupancy,
            "predict": predict,
        }
        if fused is not None:
            out["map_basis"] = fused.provenance
            out["stress"] = round(fused.stress, 4)
        if wm is not None:
            out["walls"] = wm["walls"]
            out["outline"] = wm["outline"]
            out["walls_basis"] = wm["basis"]
        scan = self._roomplan_layer()
        if scan is not None:
            out["scan"] = scan
        user = self._user_walls()
        if user:
            out["user_walls"] = user
        return out

    def _user_walls(self) -> list:
        """Owner-drawn wall corrections (the app writes ~/.vigil/
        user_walls.json when RF misses a wall). Unit coords; mtime-cached;
        rendered as their own labeled layer — never mixed into measured."""
        user_walls_path = vigil_paths.state_path("user_walls.json")
        try:
            mtime = os.path.getmtime(user_walls_path)
        except OSError:
            return []
        cached = getattr(self, "_uw_cache", None)
        if cached is not None and cached[0] == mtime:
            return cached[1]
        walls = load_user_walls(user_walls_path)
        self._uw_cache = (mtime, walls)
        return walls

    # -- optional ground truth: an Apple RoomPlan scan the owner exported ----

    def _roomplan_layer(self) -> dict | None:
        """If the owner drops a RoomPlan JSON export (Reality Composer /
        RoomPlan apps) at ~/.vigil/roomplan.json, serve its REAL walls as a
        reference layer, bbox-scaled to the map's unit box. Cached by mtime;
        absent or corrupt -> None (never blocks the learned map)."""
        roomplan_path = vigil_paths.state_path("roomplan.json")
        try:
            mtime = os.path.getmtime(roomplan_path)
        except OSError:
            return None
        cached = getattr(self, "_scan_cache", None)
        if cached is not None and cached[0] == mtime:
            return cached[1]
        try:
            from vigil_plan import from_roomplan_json
            plan = from_roomplan_json(roomplan_path)
            x0, y0, w, h = plan.bbox()
            s = 0.92 / max(w, h)

            def tx(p):
                return [round((p[0] - x0) * s + 0.04, 4),
                        round((p[1] - y0) * s + 0.04, 4)]

            layer = {
                "source": "apple-roomplan scan (owner-provided export)",
                "walls": [[tx(a), tx(b)] for a, b in plan.walls],
                "rooms": [{"name": r["name"],
                           "polygon": [tx(p) for p in r["polygon"]]}
                          for r in plan.rooms],
            }
        except Exception:
            layer = None
        self._scan_cache = (mtime, layer)
        return layer

    # -- deterministic spring layout fallback (no distances learned yet) ------

    @staticmethod
    def _layout(nodes, adj, weights, iters: int = 240):
        """Fruchterman–Reingold on the LEARNED graph → topology-true positions
        in a unit box. Deterministic (seeded by node id) so the map is stable."""
        n = len(nodes)
        if n == 0:
            return {}
        if n == 1:
            return {nodes[0]: np.array([0.5, 0.5])}
        idx = {nid: i for i, nid in enumerate(nodes)}
        # deterministic ring seed (no RNG — stable across runs)
        p = np.array([[0.5 + 0.35 * math.cos(2 * math.pi * i / n),
                       0.5 + 0.35 * math.sin(2 * math.pi * i / n)]
                      for i in range(n)], dtype=float)
        k = 0.9 / math.sqrt(n)
        adj_pairs = [(idx[a], idx[b]) for pair in adj for a, b in [tuple(sorted(pair))]]
        for step in range(iters):
            disp = np.zeros_like(p)
            for i in range(n):                      # repulsion (all pairs)
                d = p[i] - p
                dist = np.linalg.norm(d, axis=1)
                dist[i] = 1.0
                f = (k * k) / dist
                disp[i] = (d.T * (f / dist)).T.sum(axis=0)
            for i, j in adj_pairs:                  # attraction (learned edges)
                d = p[i] - p[j]
                dist = max(np.linalg.norm(d), 1e-6)
                a = (dist * dist) / k
                disp[i] -= d / dist * a
                disp[j] += d / dist * a
            temp = 0.1 * (1 - step / iters)
            for i in range(n):
                dl = max(np.linalg.norm(disp[i]), 1e-6)
                p[i] += disp[i] / dl * min(dl, temp)
            p = np.clip(p, 0.05, 0.95)
        lo, span = p.min(axis=0), np.ptp(p, axis=0)
        span[span < 1e-6] = 1.0
        p = 0.08 + 0.84 * (p - lo) / span
        return {nid: p[idx[nid]] for nid in nodes}

    @staticmethod
    def _display_name(node_id, label, confidence):
        if label and label != "unlabeled" and confidence >= 0.15:
            return label.capitalize()
        # honest discovery name until behavior earns a real label
        return f"Room {chr(ord('A') + (int(node_id) - 1) % 26)}"

    # -- persistence ---------------------------------------------------------

    def save(self):
        try:
            graph_path = vigil_paths.state_path("home_graph.json")
            os.makedirs(os.path.dirname(graph_path), exist_ok=True)
            doc = {
                "pulses": self._pulses,
                "edges": [{"a": a, "b": b, "weight": e.weight, "last_t": e.last_t,
                           "tod": e.tod.tolist(),
                           "dts": [round(x, 2) for x in list(e.dts)[-256:]]}
                          for (a, b), e in self.graph.edges.items()],
                "last_pulse": {str(k): v for k, v in self.graph._last_pulse.items()},
                "evidence": self.evidence[-EVIDENCE_CAP:],
                "tracker": self.tracker.to_dict(),
            }
            tmp = graph_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(doc, f)
            os.replace(tmp, graph_path)
        except Exception:
            pass

    def _load(self):
        try:
            with open(vigil_paths.state_path("home_graph.json")) as f:
                doc = json.load(f)
        except Exception:
            return
        from vigil_transitions import Edge
        self._pulses = int(doc.get("pulses", 0))
        for e in doc.get("edges", []):
            edge = Edge(weight=float(e["weight"]), last_t=float(e["last_t"]))
            edge.tod = np.array(e.get("tod", [0] * 24), dtype=float)
            for dt in e.get("dts", []):
                edge.dts.append(float(dt))
            self.graph.edges[(int(e["a"]), int(e["b"]))] = edge
        self.graph._last_pulse = {int(k): float(v) for k, v in doc.get("last_pulse", {}).items()}
        self.evidence = list(doc.get("evidence", []))
        try:
            self.tracker.load_dict(doc.get("tracker") or {})
        except Exception:
            pass
