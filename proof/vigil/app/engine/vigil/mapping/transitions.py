"""F5 — Self-labeling transition graph: zero-setup continuous home mapping.

THE INVENTION (see PATENT_NOTEBOOK for the formal disclosure): the home
maps itself. No tour, no floor plan, no manual room naming.

1. **Motion-handoff adjacency learning** — `TransitionGraph`: when one
   node's motion presence ends and another node's begins within a human
   traversal window (Δt default 2–8 s), the occupant walked from A to B:
   directed edge A->B weight++, with a time-of-day histogram per edge.
   Weeks of ordinary living accumulate the adjacency structure of the home;
   exponential decay (configurable half-life) lets furniture moves and
   re-plumbed habits fade old edges instead of poisoning them.

2. **Behavioral room labeling** — `BehavioralLabeler`: room *identities*
   fall out of the already-landed signal layers, all attributed only to a
   node id:
   - bedroom: sustained nightly stillness with a breathing trace
     (`vitals.breathing` events at night, D-track);
   - bathroom: steam signatures (`ledger.steam`, M2);
   - kitchen: fridge machine-signature (`machine.discovered` label
     "fridge", M4) and/or `door.event` bursts at mealtimes;
   - living/hall: peak *daytime transit centrality* on the transition graph.
   Every label carries evidence counts + confidence. Honesty rule:
   conflicting evidence -> "unlabeled" with the competing hypotheses listed,
   never a confident guess.

3. **Drift-triggered partial re-calibration** — rolling-window edge-
   distribution divergence (Jensen–Shannon vs a trailing baseline) per node;
   above threshold the node is flagged, a `mapping.drift` bus event is
   published, the affected rooms' F2 fingerprints are marked stale, and the
   payload carries the "2-minute re-walk of affected rooms" prompt. Only the
   affected rooms re-calibrate — never the whole house.

Inputs are per-node motion-presence pulses: feed `pulse(node_id, t)` from
`gate1.candidate` bus events (`attach(bus)`), or `consume_series()` for
binary presence arrays. All timestamps are seconds on one shared clock;
time-of-day uses `t % 86400`.

Operating envelope: single-occupant motion handoffs are the learning
signal; multi-occupant intervals produce contradictory handoffs that
average out as noise (weight floor + decay), they are not resolved.
Validated on >= 14 simulated days (mapping/synth.py); 2-week real-home
field acceptance is hardware-gated.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

DAY_S = 86400.0
DRIFT_TOPIC = "mapping.drift"

# behavioral evidence windows (hours of day)
NIGHT_HOURS = set(range(22, 24)) | set(range(0, 6))
DAY_HOURS = set(range(8, 21))
MEAL_HOURS = {7, 8, 12, 13, 18, 19}


@dataclass
class Edge:
    """One directed A->B handoff edge."""

    weight: float = 0.0            # decayed accumulation
    last_t: float = 0.0            # last decay-anchor time
    tod: np.ndarray = field(default_factory=lambda: np.zeros(24))
    events: deque = field(default_factory=lambda: deque(maxlen=8192))  # ts
    # traversal Δt (arrival - departure, s) per handoff: a PHYSICAL walk-time
    # measurement — F6 (fuse.py) turns its median into a metric-ish edge
    # length (× walking speed). Bounded deque; old persisted graphs without
    # it degrade to the handoff-window midpoint.
    dts: deque = field(default_factory=lambda: deque(maxlen=2048))


class TransitionGraph:
    """Directed motion-handoff graph with decay + drift detection."""

    def __init__(self, fs: float = 1.0, dt_min: float = 2.0,
                 dt_max: float = 8.0, half_life_s: float = 14 * DAY_S,
                 bus=None) -> None:
        self.fs = float(fs)
        self.dt_min = float(dt_min)
        self.dt_max = float(dt_max)
        self.half_life_s = float(half_life_s)
        self.bus = bus
        self.edges: dict[tuple[int, int], Edge] = {}
        self._last_pulse: dict[int, float] = {}
        self.n_pulses = 0

    # -- inputs ------------------------------------------------------------------

    def pulse(self, node_id: int, t: float) -> tuple[int, int] | None:
        """One motion-presence pulse on a node. A pulse after > dt_min of
        local quiet is an *arrival*; the freshest other-node pulse whose age
        falls in [dt_min, dt_max] is the matching *departure* -> edge.
        Returns the new (from, to) handoff if one was learned."""
        node_id, t = int(node_id), float(t)
        self.n_pulses += 1
        made = None
        last_here = self._last_pulse.get(node_id)
        if last_here is None or t - last_here > self.dt_min:  # arrival
            best_a, best_t = None, -math.inf
            for a, ta in self._last_pulse.items():
                if a != node_id and self.dt_min <= t - ta <= self.dt_max \
                        and ta > best_t:
                    best_a, best_t = a, ta
            if best_a is not None:
                self._bump(best_a, node_id, t, dt=t - best_t)
                made = (best_a, node_id)
        self._last_pulse[node_id] = t
        return made

    def attach(self, bus, topic: str = "gate1.candidate") -> None:
        """Learn from live motion events ({node_id, t, ...})."""
        bus.subscribe(topic, lambda _t, p: self.pulse(p["node_id"], p["t"]))

    def consume_series(self, series: dict[int, np.ndarray], t0: float = 0.0,
                       fs: float | None = None, threshold: float = 0.5) -> None:
        """Binary/energy presence series per node -> pulses in time order."""
        fs = self.fs if fs is None else float(fs)
        pulses: list[tuple[float, int]] = []
        for nid, x in series.items():
            on = np.flatnonzero(np.asarray(x, np.float64) > threshold)
            pulses.extend((t0 + i / fs, int(nid)) for i in on)
        pulses.sort()
        for t, nid in pulses:
            self.pulse(nid, t)

    # -- edge store ------------------------------------------------------------------

    def _decay_factor(self, dt: float) -> float:
        return 0.5 ** (max(dt, 0.0) / self.half_life_s)

    def _bump(self, a: int, b: int, t: float, dt: float | None = None) -> None:
        e = self.edges.setdefault((a, b), Edge(last_t=t))
        e.weight = e.weight * self._decay_factor(t - e.last_t) + 1.0
        e.last_t = t
        e.tod[int((t % DAY_S) // 3600)] += 1
        e.events.append(t)
        if dt is not None:
            e.dts.append(float(dt))

    def traversal_seconds(self, a: int, b: int) -> float | None:
        """Median walk time between a and b (either direction), seconds.
        None when the pair has no recorded handoffs; graphs persisted before
        dts existed fall back to the handoff-window midpoint."""
        samples: list[float] = []
        n_events = 0
        for key in ((int(a), int(b)), (int(b), int(a))):
            e = self.edges.get(key)
            if e is not None:
                samples.extend(e.dts)
                n_events += len(e.events) or int(e.weight)
        if samples:
            return float(np.median(samples))
        if n_events:
            return 0.5 * (self.dt_min + self.dt_max)
        return None

    def weight(self, a: int, b: int, t_now: float | None = None) -> float:
        e = self.edges.get((int(a), int(b)))
        if e is None:
            return 0.0
        if t_now is None:
            return e.weight
        return e.weight * self._decay_factor(float(t_now) - e.last_t)

    def weights(self, t_now: float | None = None) -> dict[tuple[int, int], float]:
        return {k: self.weight(*k, t_now=t_now) for k in self.edges}

    def adjacency(self, min_weight: float = 2.0,
                  t_now: float | None = None) -> set[frozenset]:
        """Symmetrized adjacency: w(A->B) + w(B->A) >= min_weight."""
        w = self.weights(t_now)
        out: set[frozenset] = set()
        for (a, b), wa in w.items():
            if a == b:
                continue
            if wa + w.get((b, a), 0.0) >= min_weight:
                out.add(frozenset((a, b)))
        return out

    def nodes(self) -> list[int]:
        ids = set(self._last_pulse)
        for a, b in self.edges:
            ids.update((a, b))
        return sorted(ids)

    def daytime_centrality(self, node_id: int) -> float:
        """Transit throughput touching a node during DAY_HOURS (labeling
        evidence for living/hall)."""
        hours = np.array(sorted(DAY_HOURS))
        total = 0.0
        for (a, b), e in self.edges.items():
            if node_id in (a, b) and a != b:
                total += float(e.tod[hours].sum())
        return total

    # -- drift detection ------------------------------------------------------------------

    def check_drift(self, t_now: float, recent_s: float = 2 * DAY_S,
                    baseline_s: float = 7 * DAY_S, threshold: float = 0.35,
                    min_events: int = 5) -> list[dict]:
        """Per-node edge-distribution divergence, recent vs trailing baseline.

        For each node, the distribution over its incident directed edges in
        [t_now - recent, t_now) is compared (Jensen–Shannon, natural log,
        max ln 2) against [t_now - recent - baseline, t_now - recent).
        Nodes above `threshold` with enough events in both windows are
        flagged, strongest first."""
        r1, r0 = float(t_now) - recent_s, float(t_now) - recent_s - baseline_s
        per_node: dict[int, dict[tuple, list[int]]] = {}
        for key, e in self.edges.items():
            recent = sum(1 for ts in e.events if ts >= r1)
            base = sum(1 for ts in e.events if r0 <= ts < r1)
            for nid in set(key):
                per_node.setdefault(nid, {})[key] = [base, recent]
        flagged = []
        for nid, dists in per_node.items():
            base = np.array([v[0] for v in dists.values()], np.float64)
            recent = np.array([v[1] for v in dists.values()], np.float64)
            if base.sum() < min_events or recent.sum() < min_events:
                continue
            js = _jensen_shannon(base / base.sum(), recent / recent.sum())
            if js > threshold:
                flagged.append({"node": nid, "js": round(js, 3),
                                "n_recent": int(recent.sum()),
                                "n_baseline": int(base.sum())})
        flagged.sort(key=lambda d: -d["js"])
        return flagged

    def report_drift(self, t_now: float, fingerprint_db=None,
                     room_of: Callable[[int], str] | None = None,
                     **drift_kw) -> dict | None:
        """Full drift loop: detect -> publish `mapping.drift` -> mark the
        affected rooms' fingerprints stale -> return the re-walk prompt
        payload (None when no drift)."""
        flagged = self.check_drift(t_now, **drift_kw)
        if not flagged:
            return None
        nodes = [f["node"] for f in flagged]
        rooms = []
        for nid in nodes:
            room = room_of(nid) if room_of is not None else f"node-{nid}"
            if room and room not in rooms:
                rooms.append(room)
        payload = {
            "t": float(t_now), "nodes": nodes, "rooms": rooms,
            "js": [f["js"] for f in flagged],
            "prompt": ("layout change detected — please do a 2-minute "
                       f"re-walk of affected rooms: {', '.join(rooms)}"),
        }
        if fingerprint_db is not None:
            fingerprint_db.mark_stale(rooms)
        if self.bus is not None:
            self.bus.publish(DRIFT_TOPIC, payload)
        return payload


def _jensen_shannon(p: np.ndarray, q: np.ndarray) -> float:
    m = 0.5 * (p + q)

    def _kl(a, b):
        mask = a > 0
        return float(np.sum(a[mask] * np.log(a[mask] / b[mask])))

    return 0.5 * _kl(p, m) + 0.5 * _kl(q, m)


# ---------------------------------------------------------------------------
# Behavioral room labeling
# ---------------------------------------------------------------------------

LABEL_CHANNELS = ("bedroom", "bathroom", "kitchen", "living")


class BehavioralLabeler:
    """Label transition-graph nodes from multi-band RF behavioral evidence.

    `evidence` is a list of bus-style events, each at minimum
    {"topic": str, "t": seconds, "node_id": int} (steam events may carry
    t0 instead of t; machine events carry "label"). Only node ids and
    timestamps are consumed — zero manual input, zero geometry.
    """

    def __init__(self, graph: TransitionGraph, evidence: list[dict],
                 min_score: float = 0.15, margin: float = 0.6) -> None:
        self.graph = graph
        self.evidence = list(evidence)
        self.min_score = float(min_score)
        self.margin = float(margin)

    # -- evidence extraction -------------------------------------------------

    def _counts(self) -> dict[int, dict[str, float]]:
        nodes = self.graph.nodes()
        counts = {n: {"night_breathing": 0.0, "steam": 0.0, "fridge": 0.0,
                      "meal_doors": 0.0, "day_transit": 0.0} for n in nodes}
        for ev in self.evidence:
            nid = ev.get("node_id")
            if nid is None or int(nid) not in counts:
                continue
            nid = int(nid)
            topic = str(ev.get("topic", ev.get("kind", "")))
            t = float(ev.get("t", ev.get("t0", ev.get("ts", 0.0))))
            hour = int((t % DAY_S) // 3600)
            if topic == "vitals.breathing" and hour in NIGHT_HOURS:
                counts[nid]["night_breathing"] += 1.0
            elif topic in ("ledger.steam", "steam"):
                counts[nid]["steam"] += 1.0
            elif topic == "machine.discovered" \
                    and str(ev.get("label", "")) == "fridge":
                counts[nid]["fridge"] += 1.0
            elif topic in ("door.event", "door") and hour in MEAL_HOURS:
                counts[nid]["meal_doors"] += 1.0
        for n in nodes:
            counts[n]["day_transit"] = self.graph.daytime_centrality(n)
        return counts

    @staticmethod
    def _scores(counts: dict[int, dict[str, float]]) -> dict[int, dict[str, float]]:
        """Per-node label scores, each evidence channel max-normalized across
        nodes so counts and centrality are commensurable."""
        nodes = sorted(counts)

        def norm(key):
            top = max(counts[n][key] for n in nodes) or 1.0
            return {n: counts[n][key] / top for n in nodes}

        breath = norm("night_breathing")
        steam = norm("steam")
        fridge = norm("fridge")
        doors = norm("meal_doors")
        transit = norm("day_transit")
        return {n: {"bedroom": breath[n],
                    "bathroom": steam[n],
                    "kitchen": 0.6 * fridge[n] + 0.4 * doors[n],
                    "living": transit[n]} for n in nodes}

    # -- labeling ----------------------------------------------------------------

    def label(self) -> dict[int, dict]:
        """-> {node_id: {"label", "confidence", "evidence", "hypotheses"}}.

        Two-pass: specific behavioral channels (bedroom/bathroom/kitchen)
        beat generic transit centrality; `living` goes to the remaining
        transit peak. Honesty rule: near-tied competing evidence yields
        "unlabeled" with the hypotheses listed."""
        counts = self._counts()
        scores = self._scores(counts)
        out: dict[int, dict] = {}
        for n in sorted(scores):
            sc = scores[n]
            specific = {k: v for k, v in sc.items() if k != "living"}
            ranked = sorted(specific.items(), key=lambda kv: -kv[1])
            (top_lbl, top), (_, second) = ranked[0], ranked[1]
            hypotheses = [{"label": k, "score": round(v, 3)}
                          for k, v in sorted(sc.items(), key=lambda kv: -kv[1])
                          if v > 0]
            entry = {"label": "unlabeled", "confidence": 0.0,
                     "evidence": {k: round(v, 1) for k, v in counts[n].items()},
                     "hypotheses": hypotheses}
            if top >= self.min_score and second <= self.margin * top:
                entry["label"] = top_lbl
                entry["confidence"] = round(top / (top + second + 1e-9), 3)
            elif top >= self.min_score:  # conflicting specific evidence
                entry["label"] = "unlabeled"
            out[n] = entry
        # living: the transit peak among nodes without a specific label
        living_pool = [n for n in out if out[n]["label"] == "unlabeled"]
        if living_pool:
            best = max(living_pool, key=lambda n: scores[n]["living"])
            sc = scores[best]
            top = sc["living"]
            second = max(v for k, v in sc.items() if k != "living")
            if top >= self.min_score and second <= self.margin * top:
                out[best]["label"] = "living"
                out[best]["confidence"] = round(top / (top + second + 1e-9), 3)
        return out

    def table(self) -> str:
        """Human-readable label table with evidence counts (for logs/tests)."""
        rows = ["node  label      conf   evidence"]
        for n, e in self.label().items():
            ev = ", ".join(f"{k}={v:g}" for k, v in e["evidence"].items()
                           if v)
            extra = ""
            if e["label"] == "unlabeled" and e["hypotheses"]:
                extra = " | hypotheses: " + ", ".join(
                    f"{h['label']}:{h['score']}" for h in e["hypotheses"][:3])
            rows.append(f"{n:<5} {e['label']:<10} {e['confidence']:<6} "
                        f"{ev}{extra}")
        return "\n".join(rows)
