"""F2 — Guided-walk fingerprint calibration: the occupant IS the probe.

Idea: no anchors, no ranging. During a short guided tour ("walk to the
kitchen, tap, stand still 10 s") the occupant's body perturbs every RF link
in the house at once; the *vector of per-node responses* while the occupant
occupies room R is a fingerprint of R. Matching a live sample against the
stored fingerprints gives room-level localization with labels only — this
is the second layer of the F-track stack (labels first, fingerprints
second, geometry presentation-only; see mapping/registry.py design doc).

Per-room fingerprint (per node):
- mean + variance of motion energy while the occupant is present in R;
- normalized subcarrier-profile shape delta vs the empty-room baseline
  (unit-norm difference of the mean [52] amplitude profile).

Matching: diagonal-covariance (Mahalanobis-ish) distance on the energy
vector plus a weighted profile-delta term, softmax over rooms -> posterior;
optional HMM-lite temporal smoothing (sticky self-transition prior) for
streaming use.

Wizard call contract (E2 integration — plain injectable methods, no wizard
import here; an E2 step drives this object):

    tour = WalkTour(registry, baseline=empty_room_samples)   # or capture_baseline()
    for room in registry.rooms():
        tour.begin(room)                # -> prompt "walk to <room>, tap, stand still 10 s"
        for _ in range(dwell_s):        # once per second during the dwell
            tour.capture(samples)       # samples: {node_id: {"motion_energy": float,
                                        #                     "profile": np.ndarray[52]}}
        tour.end(room)                  # -> RoomFingerprint stored in tour.db
    tour.progress()                     # -> {"current", "done", "remaining", "n_samples"}
    tour.db.placement_report()          # -> relocation hints for deaf nodes
    tour.db.save(path)                  # npz + embedded JSON meta

Staleness: `FingerprintDB.mark_stale(rooms)` / `.stale` is the handshake
with F5 drift detection — drift flags rooms, the UI prompts a "2-minute
re-walk" of exactly those rooms, and a fresh `begin/capture/end` on a room
clears its stale flag.

Operating envelope: pure numerics on caller-supplied samples (motion energy
from the B-track spectral stage or any equivalent scalar; profiles are mean
[52] amplitude vectors). Accuracy numbers in tests are on synthetic
phenomenology (mapping/synth.py); real-home tour acceptance is
hardware-gated.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from ..frame import N_SUB
from .registry import ZoneRegistry

_EPS = 1e-9


@dataclass
class RoomFingerprint:
    """Per-room, per-node response fingerprint learned during the tour."""

    room: str
    node_ids: list[int]
    energy_mean: np.ndarray      # [n_nodes]
    energy_var: np.ndarray       # [n_nodes]
    profile_delta: np.ndarray    # [n_nodes, 52] unit-norm shape delta vs baseline
    n_samples: int = 0

    def response(self, node_id: int) -> float:
        return float(self.energy_mean[self.node_ids.index(int(node_id))])


class FingerprintDB:
    """Store, match, persist and staleness-track room fingerprints."""

    def __init__(self, baseline: dict[int, np.ndarray] | None = None,
                 profile_weight: float = 2.0, temperature: float = 1.0) -> None:
        self.fingerprints: dict[str, RoomFingerprint] = {}
        self.baseline: dict[int, np.ndarray] = {
            int(k): np.asarray(v, np.float64) for k, v in (baseline or {}).items()}
        self.profile_weight = float(profile_weight)
        self.temperature = float(temperature)
        self._stale: set[str] = set()

    # -- content ---------------------------------------------------------------

    def add(self, fp: RoomFingerprint) -> None:
        self.fingerprints[fp.room] = fp
        self._stale.discard(fp.room)

    @property
    def rooms(self) -> list[str]:
        return sorted(self.fingerprints)

    @property
    def node_ids(self) -> list[int]:
        ids: set[int] = set()
        for fp in self.fingerprints.values():
            ids.update(fp.node_ids)
        return sorted(ids)

    # -- staleness (F5 handshake) ------------------------------------------------

    def mark_stale(self, rooms) -> list[str]:
        """Flag rooms whose fingerprints need a re-walk (drift detected)."""
        touched = []
        for room in ([rooms] if isinstance(rooms, str) else rooms):
            if room in self.fingerprints:
                self._stale.add(room)
                touched.append(room)
        return touched

    @property
    def stale(self) -> list[str]:
        return sorted(self._stale)

    # -- matching -----------------------------------------------------------------

    def _sample_vectors(self, live_sample: dict) -> tuple[dict[int, float],
                                                          dict[int, np.ndarray]]:
        energies: dict[int, float] = {}
        deltas: dict[int, np.ndarray] = {}
        for nid, s in live_sample.items():
            nid = int(nid)
            energies[nid] = float(s["motion_energy"])
            prof = s.get("profile")
            if prof is not None:
                p = np.asarray(prof, np.float64)
                base = self.baseline.get(nid)
                d = p - base if base is not None else p - p.mean()
                n = np.linalg.norm(d)
                deltas[nid] = d / n if n > _EPS else d
        return energies, deltas

    def distances(self, live_sample: dict) -> dict[str, float]:
        """Per-room fingerprint distance for one live sample."""
        energies, deltas = self._sample_vectors(live_sample)
        out: dict[str, float] = {}
        for room, fp in self.fingerprints.items():
            d = 0.0
            n_terms = 0
            for i, nid in enumerate(fp.node_ids):
                if nid not in energies:
                    continue
                var = float(fp.energy_var[i]) + _EPS
                d += (energies[nid] - float(fp.energy_mean[i])) ** 2 / var
                if nid in deltas:
                    d += self.profile_weight * float(
                        np.sum((deltas[nid] - fp.profile_delta[i]) ** 2))
                n_terms += 1
            out[room] = d / max(n_terms, 1)
        return out

    def match(self, live_sample: dict) -> tuple[str, dict[str, float], float]:
        """Nearest-fingerprint match -> (room, posterior dict, confidence).

        Posterior = softmax(-0.5 * distance / temperature); confidence is
        the winning posterior mass."""
        if not self.fingerprints:
            raise ValueError("empty FingerprintDB — run the walk tour first")
        dist = self.distances(live_sample)
        rooms = sorted(dist)
        logits = np.array([-0.5 * dist[r] / self.temperature for r in rooms])
        logits -= logits.max()
        p = np.exp(logits)
        p /= p.sum()
        posterior = {r: float(pi) for r, pi in zip(rooms, p)}
        best = max(posterior, key=posterior.get)
        return best, posterior, posterior[best]

    def smoother(self, sticky: float = 0.85) -> "MatchSmoother":
        """Temporal smoothing option — HMM-lite sticky transition prior."""
        return MatchSmoother(self, sticky=sticky)

    # -- placement validation ---------------------------------------------------------

    def placement_report(self, registry: ZoneRegistry | None = None,
                         min_ratio: float = 2.0) -> list[dict]:
        """Flag nodes that barely respond in their own (assigned) room.

        For node n assigned to room r, response ratio = mean energy while
        the occupant is in r divided by the median of its energy across all
        other rooms. ratio < min_ratio -> relocation hint."""
        hints: list[dict] = []
        for room, fp in sorted(self.fingerprints.items()):
            for i, nid in enumerate(fp.node_ids):
                assigned = registry.room_of(nid) if registry is not None else room
                if assigned != room:
                    continue
                own = float(fp.energy_mean[i])
                elsewhere = [float(o.energy_mean[o.node_ids.index(nid)])
                             for r, o in self.fingerprints.items()
                             if r != room and nid in o.node_ids]
                ref = float(np.median(elsewhere)) if elsewhere else _EPS
                ratio = own / max(ref, _EPS)
                if ratio < min_ratio:
                    hints.append({
                        "node": nid, "room": room, "ratio": round(ratio, 2),
                        "hint": (f"node {nid} barely sees {room} "
                                 f"(response {ratio:.1f}x its elsewhere level, "
                                 f"need >{min_ratio:.0f}x) — suggest relocation"),
                    })
        return hints

    # -- persistence (npz + json meta) ----------------------------------------------

    def save(self, path: str | Path) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        arrays: dict[str, np.ndarray] = {}
        meta = {"version": 1, "profile_weight": self.profile_weight,
                "temperature": self.temperature, "stale": self.stale,
                "rooms": {}}
        for i, (room, fp) in enumerate(sorted(self.fingerprints.items())):
            key = f"fp{i}"
            meta["rooms"][key] = {"room": room, "node_ids": fp.node_ids,
                                  "n_samples": fp.n_samples}
            arrays[f"{key}_mean"] = np.asarray(fp.energy_mean, np.float64)
            arrays[f"{key}_var"] = np.asarray(fp.energy_var, np.float64)
            arrays[f"{key}_delta"] = np.asarray(fp.profile_delta, np.float64)
        meta["baseline_nodes"] = sorted(self.baseline)
        for nid in sorted(self.baseline):
            arrays[f"baseline_{nid}"] = self.baseline[nid]
        arrays["meta_json"] = np.frombuffer(
            json.dumps(meta).encode("utf-8"), dtype=np.uint8)
        np.savez_compressed(path, **arrays)

    @classmethod
    def load(cls, path: str | Path) -> "FingerprintDB":
        with np.load(path) as z:
            meta = json.loads(bytes(z["meta_json"]).decode("utf-8"))
            db = cls(profile_weight=meta["profile_weight"],
                     temperature=meta["temperature"])
            for nid in meta.get("baseline_nodes", []):
                db.baseline[int(nid)] = np.asarray(z[f"baseline_{nid}"],
                                                   np.float64)
            for key, info in meta["rooms"].items():
                db.fingerprints[info["room"]] = RoomFingerprint(
                    room=info["room"],
                    node_ids=[int(n) for n in info["node_ids"]],
                    energy_mean=np.asarray(z[f"{key}_mean"], np.float64),
                    energy_var=np.asarray(z[f"{key}_var"], np.float64),
                    profile_delta=np.asarray(z[f"{key}_delta"], np.float64),
                    n_samples=int(info["n_samples"]))
            db._stale = set(meta.get("stale", []))
        return db


class MatchSmoother:
    """HMM-lite temporal smoothing over FingerprintDB.match.

    Prior at step t: p_prior = sticky * p_{t-1} + (1-sticky) * uniform
    (a sticky self-transition matrix collapsed to its stationary mix);
    posterior ∝ likelihood(sample) * prior. Reset with `.reset()`."""

    def __init__(self, db: FingerprintDB, sticky: float = 0.85) -> None:
        self.db = db
        self.sticky = float(sticky)
        self._post: dict[str, float] | None = None

    def reset(self) -> None:
        self._post = None

    def update(self, live_sample: dict) -> tuple[str, dict[str, float], float]:
        _, like, _ = self.db.match(live_sample)
        rooms = sorted(like)
        if self._post is None:
            post = np.array([like[r] for r in rooms])
        else:
            prev = np.array([self._post.get(r, 0.0) for r in rooms])
            prior = self.sticky * prev + (1.0 - self.sticky) / len(rooms)
            post = prior * np.array([like[r] for r in rooms])
        post = post / max(post.sum(), _EPS)
        self._post = {r: float(p) for r, p in zip(rooms, post)}
        best = max(self._post, key=self._post.get)
        return best, dict(self._post), self._post[best]


class WalkTour:
    """Guided-walk calibration state machine (wizard-drivable, see module
    docstring for the E2 call contract)."""

    def __init__(self, registry: ZoneRegistry,
                 baseline: dict[int, dict] | None = None,
                 db: FingerprintDB | None = None,
                 min_samples: int = 4) -> None:
        self.registry = registry
        self.min_samples = int(min_samples)
        self.db = db or FingerprintDB()
        self._current: str | None = None
        self._buf: dict[int, list[tuple[float, np.ndarray | None]]] = {}
        if baseline:
            self.capture_baseline(baseline)

    # -- baseline ------------------------------------------------------------

    def capture_baseline(self, samples: dict[int, dict]) -> None:
        """Empty-room baseline: per-node mean [52] amplitude profile,
        captured before the tour (nobody moving)."""
        for nid, s in samples.items():
            prof = np.asarray(s["profile"], np.float64)
            if prof.shape[-1] != N_SUB:
                raise ValueError(f"profile must have {N_SUB} subcarriers")
            self.db.baseline[int(nid)] = prof.reshape(-1, N_SUB).mean(axis=0)

    # -- tour steps ------------------------------------------------------------

    def begin(self, room: str) -> str:
        if self._current is not None:
            raise RuntimeError(f"tour step for {self._current!r} still open")
        if room not in self.registry.rooms():
            raise KeyError(f"unknown room {room!r}; registry rooms: "
                           f"{self.registry.rooms()}")
        self._current = room
        self._buf = {}
        return f"walk to {room}, tap, stand still 10 s"

    def capture(self, samples: dict[int, dict]) -> int:
        """One dwell sample per node; call repeatedly during the 10 s dwell."""
        if self._current is None:
            raise RuntimeError("capture() outside begin()/end()")
        for nid, s in samples.items():
            prof = s.get("profile")
            self._buf.setdefault(int(nid), []).append(
                (float(s["motion_energy"]),
                 None if prof is None else np.asarray(prof, np.float64)))
        return min(len(v) for v in self._buf.values())

    def end(self, room: str) -> RoomFingerprint:
        if self._current != room:
            raise RuntimeError(f"end({room!r}) does not match open step "
                               f"{self._current!r}")
        n = min((len(v) for v in self._buf.values()), default=0)
        if n < self.min_samples:
            raise ValueError(f"only {n} dwell samples for {room!r}; need "
                             f">= {self.min_samples} (keep standing still)")
        node_ids = sorted(self._buf)
        mean = np.zeros(len(node_ids))
        var = np.zeros(len(node_ids))
        delta = np.zeros((len(node_ids), N_SUB))
        for i, nid in enumerate(node_ids):
            e = np.array([x[0] for x in self._buf[nid]], np.float64)
            mean[i], var[i] = e.mean(), max(e.var(), _EPS)
            profs = [x[1] for x in self._buf[nid] if x[1] is not None]
            if profs:
                p = np.mean(np.stack(profs), axis=0)
                base = self.db.baseline.get(nid, p * 0 + p.mean())
                d = p - base
                norm = np.linalg.norm(d)
                delta[i] = d / norm if norm > _EPS else d
        fp = RoomFingerprint(room=room, node_ids=node_ids, energy_mean=mean,
                             energy_var=var, profile_delta=delta,
                             n_samples=int(np.mean([len(v) for v in
                                                    self._buf.values()])))
        self.db.add(fp)
        self._current = None
        self._buf = {}
        return fp

    def progress(self) -> dict:
        """Wizard-facing progress snapshot."""
        done = sorted(self.db.fingerprints)
        remaining = [r for r in self.registry.rooms() if r not in done]
        n = min((len(v) for v in self._buf.values()), default=0)
        return {"current": self._current, "done": done,
                "remaining": remaining, "n_samples": n,
                "stale": self.db.stale}
