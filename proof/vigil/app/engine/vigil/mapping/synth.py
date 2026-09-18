"""Mapping-track synthetic home generator (module-local test fixtures).

Simulates a small home with ground truth: floor plan (rooms + adjacency +
node positions), an occupant living ordinary days (night in the bedroom
with breathing events, morning shower with steam, kitchen meals with fridge
door bursts, daytime transit through the living hub), emitting:

- per-node motion-presence pulses (the F5 TransitionGraph input),
- bus-style evidence event streams (vitals.breathing / ledger.steam /
  machine.discovered / door.event) tagged only by node_id,
- walk-tour dwell samples for F2 (per-node motion energy + [52] profiles),
- pairwise RSSI matrices for F3 (log-distance + shadowing noise).

A "furniture move" perturbation re-routes one room's doorway from a given
day onward (its transition edges change distribution), which is what F5's
drift detector must catch.

Like vigil/synth.py: this models phenomenology for tests — no accuracy
claim on real homes follows from it (real tours / 2-week field data are
hardware-gated). All randomness is seeded.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from ..frame import N_SUB

DAY_S = 86400.0
HOUR_S = 3600.0


@dataclass
class SimHome:
    rooms: list[str]
    hub: str
    node_of: dict[str, int]                  # room -> node_id
    adjacency: set[frozenset]                # ground-truth room adjacency
    positions: dict[int, np.ndarray]         # node -> [x, y] meters

    @property
    def room_of(self) -> dict[int, str]:
        return {v: k for k, v in self.node_of.items()}

    def node_adjacency(self) -> set[frozenset]:
        return {frozenset(self.node_of[r] for r in e) for e in self.adjacency}


def make_home(seed: int = 0, n_rooms: int = 4) -> SimHome:
    """Star-topology home: living is the hub, leaves hang off it.
    4 rooms: bedroom/bathroom/kitchen/living (+hall, study for 5-6)."""
    names = ["living", "bedroom", "bathroom", "kitchen", "hall", "study"]
    rooms = names[:max(4, min(6, n_rooms))]
    rng = np.random.default_rng(seed)
    hub = "living"
    node_of = {room: i + 1 for i, room in enumerate(sorted(rooms))}
    adjacency = {frozenset((hub, r)) for r in rooms if r != hub}
    # leaf positions around the hub, jittered
    pos = {node_of[hub]: np.array([5.0, 4.0])}
    angles = np.linspace(0, 2 * np.pi, len(rooms) - 1, endpoint=False)
    for a, room in zip(angles, [r for r in rooms if r != hub]):
        radius = rng.uniform(3.2, 4.5)
        jitter = rng.uniform(-0.3, 0.3, 2)
        pos[node_of[room]] = pos[node_of[hub]] + radius * np.array(
            [np.cos(a), np.sin(a)]) + jitter
    return SimHome(rooms=rooms, hub=hub, node_of=node_of,
                   adjacency=adjacency, positions=pos)


# ---------------------------------------------------------------------------
# Day-schedule simulation (F5)
# ---------------------------------------------------------------------------

@dataclass
class SimLog:
    pulses: list = field(default_factory=list)   # (t, node_id) sorted
    events: list = field(default_factory=list)   # bus-style evidence dicts
    dwells: list = field(default_factory=list)   # (t0, t1, room) debug


def _bfs_route(adjacency: set[frozenset], a: str, b: str) -> list[str]:
    if a == b:
        return [a]
    frontier = [[a]]
    seen = {a}
    while frontier:
        path = frontier.pop(0)
        for edge in adjacency:
            if path[-1] in edge:
                (nxt,) = set(edge) - {path[-1]} or {path[-1]}
                if nxt == b:
                    return path + [b]
                if nxt not in seen:
                    seen.add(nxt)
                    frontier.append(path + [nxt])
    return [a, b]  # disconnected fallback


def simulate(home: SimHome, days: int = 14, seed: int = 0,
             furniture_move: dict | None = None) -> SimLog:
    """Simulate `days` of single-occupant living.

    furniture_move: {"day": d, "room": r, "via": r2} — from day d onward the
    doorway of room r connects through r2 instead of the hub (its handoff
    edges change), modelling a furniture/layout change.
    """
    rng = np.random.default_rng(seed)
    log = SimLog()
    leaf_rooms = [r for r in home.rooms if r != home.hub]
    bed = "bedroom" if "bedroom" in home.rooms else leaf_rooms[0]
    bath = "bathroom" if "bathroom" in home.rooms else leaf_rooms[-1]
    kitchen = "kitchen" if "kitchen" in home.rooms else leaf_rooms[1 % len(leaf_rooms)]

    def adjacency_for(day: int) -> set[frozenset]:
        adj = set(home.adjacency)
        if furniture_move is not None and day >= int(furniture_move["day"]):
            room = furniture_move["room"]
            via = furniture_move.get("via", bed)
            adj = {e for e in adj if room not in e}
            adj.add(frozenset((room, via)))
        return adj

    # fridge signature discovered on day 0 and re-confirmed weekly
    for d in range(0, days, 7):
        log.events.append({"topic": "machine.discovered",
                           "t": d * DAY_S + 2 * HOUR_S,
                           "node_id": home.node_of[kitchen],
                           "label": "fridge", "confidence": 0.8})

    t = 0.0  # current clock; occupant starts asleep in bed
    cur = bed
    for day in range(days):
        base = day * DAY_S
        adj = adjacency_for(day)

        def move_to(room: str, t_arrive_by: float | None = None) -> None:
            """Emit departure/arrival pulse bursts along the route. Walk time
            is PHYSICAL: hop distance / 1.2 m/s + reaction jitter (this is
            the mechanism F6 fuse.py inverts back into geometry), floored to
            stay inside the F5 handoff window."""
            nonlocal t, cur
            if room == cur:
                return
            for hop in _bfs_route(adj, cur, room)[1:]:
                d = float(np.linalg.norm(home.positions[home.node_of[hop]]
                                         - home.positions[home.node_of[cur]]))
                t += max(2.2, d / 1.2) + rng.uniform(0.2, 0.8)
                nid = home.node_of[hop]
                for k in range(3):                   # arrival burst
                    log.pulses.append((t + k, nid))
                t += 2.0                             # burst spans 2 s
                cur = hop

        def dwell(until: float, mode: str = "active") -> None:
            """Stay in `cur` until absolute time `until`, emitting sparse
            motion pulses; ends with a departure burst (the last pulses)."""
            nonlocal t
            nid = home.node_of[cur]
            step = 600.0 if mode == "sleep" else 30.0
            t0 = t
            tt = t + step
            while tt < until - 5.0:
                log.pulses.append((tt, nid))
                tt += step * rng.uniform(0.9, 1.1)
            for k in (-2.0, -1.0, 0.0):              # departure burst
                log.pulses.append((until + k, nid))
            log.dwells.append((t0, until, cur))
            if mode == "sleep":
                bt = t0 + 900.0
                while bt < until - 600.0:
                    log.events.append({
                        "topic": "vitals.breathing", "t": bt,
                        "node_id": nid, "bpm": float(rng.uniform(12, 16)),
                        "confidence": 0.8})
                    bt += 1800.0
            t = until

        def doors(n_pairs: int) -> None:
            nid = home.node_of[kitchen]
            for _ in range(n_pairs):
                td = t + rng.uniform(30.0, 900.0)
                log.events.append({"topic": "door.event", "t": td,
                                   "node_id": nid, "state": "open"})
                log.events.append({"topic": "door.event", "t": td + 8.0,
                                   "node_id": nid, "state": "close"})

        # -- one day ---------------------------------------------------------
        dwell(base + 7.0 * HOUR_S, mode="sleep")             # night in bed
        move_to(bath)                                        # morning shower
        shower0 = t + 120.0
        log.events.append({"topic": "ledger.steam", "t": shower0,
                           "t0": shower0, "t1": shower0 + 900.0,
                           "node_id": home.node_of[bath], "confidence": 0.9})
        dwell(base + 7.45 * HOUR_S)
        move_to(kitchen)                                     # breakfast
        doors(3)
        dwell(base + 8.0 * HOUR_S)

        def daytime(until_h: float) -> None:
            nonlocal t
            while t < base + (until_h - 0.3) * HOUR_S:
                move_to(home.hub)
                dwell(min(t + rng.uniform(0.35, 0.65) * HOUR_S,
                          base + until_h * HOUR_S))
                if t >= base + (until_h - 0.3) * HOUR_S:
                    break
                move_to(str(rng.choice(leaf_rooms)))
                dwell(min(t + rng.uniform(0.08, 0.16) * HOUR_S,
                          base + until_h * HOUR_S))
            move_to(home.hub)

        daytime(12.5)
        move_to(kitchen)                                     # lunch
        doors(2)
        dwell(base + 13.0 * HOUR_S)
        daytime(18.5)
        move_to(kitchen)                                     # dinner
        doors(3)
        dwell(base + 19.2 * HOUR_S)
        move_to(home.hub)                                    # evening
        dwell(base + 22.9 * HOUR_S)
        move_to(bed)                                         # to sleep
        # sleep until next day's 07:00 is emitted at the top of the loop;
        # the final night runs to end-of-simulation
    dwell_end = days * DAY_S - 60.0
    if t < dwell_end:
        nid = home.node_of[cur]
        tt = t + 600.0
        while tt < dwell_end:
            log.pulses.append((tt, nid))
            tt += 600.0
        t = dwell_end
    log.pulses.sort()
    log.events.sort(key=lambda e: e["t"])
    return log


def gate1_events(pulses, energy: float = 6.0) -> list[dict]:
    """Fake gate1-style bus events from presence pulses — tagged ONLY by
    node_id (zero geometric info; F1's zero-geometry pipeline input)."""
    return [{"node_id": int(nid), "t": float(t), "energy": float(energy)}
            for t, nid in pulses]


# ---------------------------------------------------------------------------
# Walk-tour dwell samples (F2)
# ---------------------------------------------------------------------------

def _baseline_profile(node_id: int) -> np.ndarray:
    rng = np.random.default_rng(1000 + node_id)
    return (80 + 40 * np.sin(np.linspace(0, 3 * np.pi, N_SUB))
            + rng.normal(0, 5, N_SUB))


def _delta_direction(node_id: int, room: str) -> np.ndarray:
    rng = np.random.default_rng(abs(hash((node_id, room))) % (2 ** 32))
    d = rng.normal(0, 1, N_SUB)
    return d / np.linalg.norm(d)


def response_level(home: SimHome, node_id: int, occupied_room: str,
                   deaf_nodes=()) -> float:
    """Ground-truth mean motion-energy response of a node while the occupant
    stands in `occupied_room`: strong in its own room, moderate one room
    away, weak elsewhere; a 'deaf' node barely sees even its own room."""
    own = home.room_of[node_id]
    if own == occupied_room:
        return 1.1 if node_id in set(deaf_nodes) else 8.0
    if frozenset((own, occupied_room)) in home.adjacency:
        return 2.5
    return 0.6


def baseline_samples(home: SimHome) -> dict[int, dict]:
    """Empty-room baseline capture: {node: {'profile': [52]}}."""
    return {nid: {"profile": _baseline_profile(nid)}
            for nid in home.node_of.values()}


def tour_samples(home: SimHome, occupied_room: str, n: int, seed: int = 0,
                 deaf_nodes=(), noise: float = 0.35) -> list[dict]:
    """`n` dwell samples (one per second of standing still in a room):
    [{node: {'motion_energy': float, 'profile': [52]}}, ...]."""
    rng = np.random.default_rng(seed)
    out = []
    for _ in range(n):
        sample = {}
        for room, nid in home.node_of.items():
            resp = response_level(home, nid, occupied_room, deaf_nodes)
            e = max(float(rng.normal(resp, noise)), 0.0)
            prof = (_baseline_profile(nid)
                    + 0.5 * resp * _delta_direction(nid, occupied_room)
                    + rng.normal(0, 0.4, N_SUB))
            sample[nid] = {"motion_energy": e, "profile": prof}
        out.append(sample)
    return out


# ---------------------------------------------------------------------------
# Pairwise RF measurements (F3)
# ---------------------------------------------------------------------------

def rssi_matrix(positions: dict[int, np.ndarray], rssi_1m: float = -40.0,
                exponent: float = 2.2, sigma_db: float = 1.0,
                seed: int = 0) -> tuple[list[int], np.ndarray]:
    """Inter-node RSSI from the log-distance model + shadowing noise.
    Returns (node_ids, [n, n] matrix); diagonal is 0 (unused)."""
    rng = np.random.default_rng(seed)
    ids = sorted(positions)
    n = len(ids)
    m = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            d = max(float(np.linalg.norm(positions[ids[i]] - positions[ids[j]])),
                    0.1)
            m[i, j] = (rssi_1m - 10.0 * exponent * np.log10(d)
                       + rng.normal(0, sigma_db))
    return ids, m
