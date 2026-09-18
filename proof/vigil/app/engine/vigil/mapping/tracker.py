"""F7 — probabilistic occupant tracking + habit prediction on the learned map.

The engine's occupant election is a hard argmax with hysteresis: one winner,
no memory of the home's structure. This module upgrades it to an HMM forward
filter whose *transition prior is the learned F5 graph itself* — the map the
home taught us is what makes tracking smart:

- **States**: every mapped node + AWAY (empty house is a first-class state,
  never a fabricated room).
- **Transitions**: hazard-rate dwell model (P(leave) = 1 − exp(−Δt/dwell))
  distributed over the *learned* adjacency, hour-conditioned by the per-edge
  time-of-day histograms. Teleporting to a non-adjacent room gets only the
  tiny mixing floor — a one-tick RF ghost spike CANNOT move the posterior,
  because the home's own topology says you can't get there from here.
- **Emissions**: the per-node excess-over-baseline scores the engine already
  computes. Score share (Laplace-floored) for rooms; a quiet house emits
  AWAY with likelihood exp(−Σscores/κ).
- **Outputs**: full posterior {state: p}, best (state, confidence), a
  trajectory of confident room entries (the walkable track the UI draws),
  and per-room dwell statistics learned from the occupant's own life.

`NextRoomPredictor` closes the loop: P(next room | current room, hour) from
the same decayed, hour-conditioned edge statistics, with expected remaining
dwell from the tracker's learned dwell medians. This is the F5 time-of-day
data (collected since day one, previously unread) finally doing work.

HONESTY ENVELOPE: single-occupant semantics (same as F5 — multi-occupant
evidence blurs the posterior instead of resolving identities); probabilities
are beliefs conditioned on the learned graph, not measurements. Serialized
output stamps `basis` so no UI can present a prediction as a detection.
"""

from __future__ import annotations

import math
from collections import deque

import numpy as np

from .transitions import TransitionGraph

AWAY = "away"

MIX_FLOOR = 1e-4          # ergodicity floor: filter can always recover
AWAY_EXIT_P = 0.02        # hazard share routed to leaving the house
AWAY_DWELL_S = 1800.0     # dwell prior for being out of the house
DEFAULT_DWELL_S = 240.0   # dwell prior before the home teaches us better
QUIET_KAPPA = 0.35        # AWAY emission scale: e^(-Σscores/κ)
TOD_ALPHA = 1.0           # Laplace smoothing over the 24 tod bins
TRACK_CONF = 0.55         # posterior needed to append to the trajectory
EMIT_REF_S = 5.0          # emission evidence is calibrated for ~5 s ticks


class RoomTracker:
    """HMM forward filter over the learned home (see module docstring)."""

    def __init__(self, graph: TransitionGraph,
                 default_dwell_s: float = DEFAULT_DWELL_S,
                 quiet_kappa: float = QUIET_KAPPA,
                 track_maxlen: int = 512) -> None:
        self.graph = graph
        self.default_dwell_s = float(default_dwell_s)
        self.quiet_kappa = float(quiet_kappa)
        self._belief: dict = {}            # state -> p (lazy init on update)
        self._last_t: float | None = None
        self.track: deque = deque(maxlen=track_maxlen)  # (t, node, conf)
        self._dwell: dict[int, list[float]] = {}        # node -> dwell samples
        self._cur: tuple[int, float] | None = None      # (node, entered_t)

    # -- state space ---------------------------------------------------------

    def states(self) -> list:
        return list(self.graph.nodes()) + [AWAY]

    def _ensure_belief(self) -> None:
        states = self.states()
        known = set(self._belief)
        if known != set(states):
            # keep existing mass, spread the rest over new states
            missing = [s for s in states if s not in known]
            keep = sum(self._belief.get(s, 0.0) for s in states)
            spread = max(0.0, 1.0 - keep) / max(1, len(missing))
            self._belief = {s: self._belief.get(s, spread) for s in states}
            self._normalize()

    def _normalize(self) -> None:
        z = sum(self._belief.values()) or 1.0
        self._belief = {s: p / z for s, p in self._belief.items()}

    # -- model pieces ----------------------------------------------------------

    def dwell_median_s(self, node: int) -> float:
        samples = self._dwell.get(int(node))
        if samples:
            return float(np.median(samples))
        return self.default_dwell_s

    def _out_rates(self, node: int, hour: int,
                   t_now: float) -> dict[int, float]:
        """Hour-conditioned relative rates over the learned neighbors."""
        rates: dict[int, float] = {}
        for (a, b), e in self.graph.edges.items():
            if a != node or b == node:
                continue
            w = self.graph.weight(a, b, t_now)
            if w <= 0:
                continue
            tod_share = ((float(e.tod[hour]) + TOD_ALPHA)
                         / (float(e.tod.sum()) + 24 * TOD_ALPHA))
            rates[b] = w * tod_share
        return rates

    def _predict(self, dt: float, t_now: float) -> dict:
        """One transition step of dt seconds applied to the belief."""
        hour = int((t_now % 86400.0) // 3600)
        states = self.states()
        nodes = [s for s in states if s != AWAY]
        prior = {s: MIX_FLOOR for s in states}
        for s, p in self._belief.items():
            if p <= 0 or s not in self._belief:
                continue
            if s == AWAY:
                stay = math.exp(-max(dt, 0.0) / AWAY_DWELL_S)
                prior[AWAY] += p * stay
                if nodes:
                    enter = (1.0 - stay) / len(nodes)
                    for b in nodes:
                        prior[b] += p * enter
                continue
            leave = 1.0 - math.exp(-max(dt, 0.0) / self.dwell_median_s(s))
            prior[s] += p * (1.0 - leave)
            rates = self._out_rates(int(s), hour, t_now)
            z = sum(rates.values())
            moved = p * leave
            prior[AWAY] += moved * AWAY_EXIT_P
            if z > 0:
                for b, r in rates.items():
                    prior[b] = prior.get(b, MIX_FLOOR) \
                        + moved * (1.0 - AWAY_EXIT_P) * (r / z)
            else:  # unmapped node: it can only stay or leave the house
                prior[s] += moved * (1.0 - AWAY_EXIT_P)
        return prior

    def _emission(self, scores: dict[int, float]) -> dict:
        """Likelihood of the score vector under each state."""
        states = self.states()
        total = sum(max(0.0, v) for v in scores.values())
        lik: dict = {}
        for s in states:
            if s == AWAY:
                lik[s] = math.exp(-total / self.quiet_kappa)
            else:
                share = max(0.0, float(scores.get(int(s), 0.0)))
                lik[s] = (share + 0.02 * max(total, 1e-6)) \
                    / (total + 0.02 * max(total, 1e-6) * len(states)) \
                    if total > 0 else 1.0 / len(states)
        return lik

    # -- the filter -------------------------------------------------------------

    def update(self, scores: dict[int, float], t: float) -> dict:
        """One tick: scores = per-node excess-over-baseline (≥0, absent ok).
        Returns the posterior {state: p} (AWAY key is the string 'away')."""
        t = float(t)
        self._ensure_belief()
        if not self._belief:
            return {}
        first = self._last_t is None
        dt = 0.0 if first else max(0.0, t - self._last_t)
        self._last_t = t
        prior = self._predict(dt, t) if dt > 0 else dict(self._belief)
        lik = self._emission({int(k): float(v) for k, v in scores.items()})
        # TIME-NORMALIZED evidence: emissions at 12 Hz are the SAME correlated
        # observation, not 12 independent ones — unweighted, a quiet dip drove
        # the posterior to AWAY in under a second and the occupant dot vanished
        # on a still person (Founder-caught live, 2026-07-03). Fractional
        # Bayesian update: one full emission per EMIT_REF_S of real time, so
        # belief dynamics depend on elapsed time, not on the caller's tick
        # rate. dt==EMIT_REF_S (the tests' cadence) is exactly the old update.
        w = 1.0 if first else min(1.0, dt / EMIT_REF_S)
        post = {s: prior.get(s, MIX_FLOOR) * (lik.get(s, MIX_FLOOR) ** w)
                for s in self.states()}
        z = sum(post.values()) or 1.0
        self._belief = {s: p / z for s, p in post.items()}
        self._observe_track(t)
        return dict(self._belief)

    def best(self) -> tuple:
        """(state, confidence); ('away', …) for an empty house."""
        if not self._belief:
            return AWAY, 0.0
        s = max(self._belief, key=self._belief.get)
        return s, float(self._belief[s])

    def posterior(self) -> dict:
        return dict(self._belief)

    def _observe_track(self, t: float) -> None:
        s, conf = self.best()
        if s == AWAY or conf < TRACK_CONF:
            if s == AWAY and conf >= TRACK_CONF and self._cur is not None:
                self._close_dwell(t)
            return
        node = int(s)
        if self._cur is None or self._cur[0] != node:
            if self._cur is not None:
                self._close_dwell(t)
            self._cur = (node, t)
            self.track.append((t, node, round(conf, 3)))

    def _close_dwell(self, t: float) -> None:
        node, entered = self._cur
        dwell = t - entered
        if 5.0 <= dwell <= 6 * 3600.0:      # sane human dwell only
            self._dwell.setdefault(node, []).append(dwell)
            if len(self._dwell[node]) > 512:
                del self._dwell[node][:256]
        self._cur = None

    # -- serialization ------------------------------------------------------------

    def snapshot(self, room_name=None, n_track: int = 24) -> dict:
        """UI-ready dict: posterior, best, recent track, dwell medians."""
        name = room_name or (lambda n: f"node-{n}")
        s, conf = self.best()
        return {
            "basis": "hmm on the learned home graph — belief, not detection",
            "best": {"state": (AWAY if s == AWAY else int(s)),
                     "room": (AWAY if s == AWAY else name(int(s))),
                     "confidence": round(conf, 3)},
            "posterior": {str(k): round(v, 4)
                          for k, v in sorted(self._belief.items(),
                                             key=lambda kv: -kv[1])
                          if v >= 0.01},
            "track": [{"t": round(t, 1), "node": n, "room": name(n),
                       "confidence": c}
                      for t, n, c in list(self.track)[-n_track:]],
            "dwell_s": {str(n): round(self.dwell_median_s(n), 1)
                        for n in self._dwell},
        }

    def to_dict(self) -> dict:
        return {"dwell": {str(k): v[-128:] for k, v in self._dwell.items()}}

    def load_dict(self, doc: dict) -> None:
        for k, v in (doc.get("dwell") or {}).items():
            try:
                self._dwell[int(k)] = [float(x) for x in v]
            except (TypeError, ValueError):
                continue


class NextRoomPredictor:
    """P(next room | current room, hour) from the learned edge statistics."""

    def __init__(self, graph: TransitionGraph,
                 tracker: RoomTracker | None = None) -> None:
        self.graph = graph
        self.tracker = tracker

    def predict(self, node: int, t_now: float, k: int = 3) -> list[dict]:
        """Top-k next rooms with probabilities; [] when the node has no
        learned exits (honesty: no habit data -> no prediction)."""
        node = int(node)
        hour = int((float(t_now) % 86400.0) // 3600)
        rates: dict[int, float] = {}
        for (a, b), e in self.graph.edges.items():
            if a != node or b == node:
                continue
            w = self.graph.weight(a, b, t_now)
            if w <= 0:
                continue
            tod_share = ((float(e.tod[hour]) + TOD_ALPHA)
                         / (float(e.tod.sum()) + 24 * TOD_ALPHA))
            rates[b] = w * tod_share
        z = sum(rates.values())
        if z <= 0:
            return []
        ranked = sorted(rates.items(), key=lambda kv: -kv[1])[:max(1, k)]
        out = [{"node": b, "p": round(r / z, 3)} for b, r in ranked]
        if self.tracker is not None:
            for entry in out:
                entry["expected_dwell_s"] = round(
                    self.tracker.dwell_median_s(entry["node"]), 1)
        return out
