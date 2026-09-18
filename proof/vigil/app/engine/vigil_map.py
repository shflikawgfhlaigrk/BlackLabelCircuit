"""Vigil house self-mapping — the fleet measures itself, MDS draws the layout.

Every node broadcasts a signed ESP-NOW survey ping (5 s cadence) and records
the RSSI of every peer it hears (firmware espnow_relay.c); the control-plane
STATUS reply carries that table as `peers`. This module collects the full
pairwise matrix over one UDP broadcast, turns RSSI into distance via the
log-distance path-loss model, and solves a relative 2-D layout with classical
MDS — the same math as the research tree's vigil/mapping/geometry.py, vendored
so the shipped app stands alone.

HONESTY ENVELOPE (mirrors mapping/registry.py): indoor RSSI ranging is
meters-noisy (shadowing 3–6 dB → 30–60 % distance error). The layout is
TOPOLOGY-correct (who is near whom), not metric — and it is presentation
only: detection never reads coordinates. The JSON stamps `source` and
`error_envelope` so no UI can oversell it.
"""

from __future__ import annotations
import json
import math
import os
import socket
import time

import numpy as np

import vigil_paths

CTRL_PORT = 5567
STATUS = bytes([0xA5, 0x5C, 0x04])


# GEOMETRY_PATH / FLEET_PATH resolve through vigil_paths on every ACCESS, never at import:
# a constant frozen at import time ignores an override set afterwards (and this module is
# imported lazily from home_engine, so import order is not something a test can rely on).
# PEP 562 module __getattr__ keeps the public names while making them honour VIGIL_HOME /
# HOMEFRONT_DATA_DIR. A raw "~/.vigil/…" literal here would escape the override.
def __getattr__(name):
    if name == "GEOMETRY_PATH":
        return vigil_paths.state_path("geometry.json")
    if name == "FLEET_PATH":
        return vigil_paths.state_path("fleet.json")
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def _rssi_to_distance(rssi, rssi_1m=-40.0, exponent=2.2):
    r = np.asarray(rssi, np.float64)
    return 10.0 ** ((rssi_1m - r) / (10.0 * exponent))


def _classical_mds(dist, n_dims=2):
    d = np.asarray(dist, np.float64)
    n = d.shape[0]
    d = 0.5 * (d + d.T)
    j = np.eye(n) - np.ones((n, n)) / n
    b = -0.5 * j @ (d ** 2) @ j
    w, v = np.linalg.eigh(b)
    order = np.argsort(w)[::-1][:n_dims]
    w_top = np.clip(w[order], 0.0, None)
    return v[:, order] * np.sqrt(w_top)


def collect_peers(broadcast="192.168.88.255", wait_s=4.0):
    """One broadcast STATUS sweep -> {node_id: {"peers": {...}, "rssi": int}}."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(1.0)
    found = {}
    t0 = time.time()
    s.sendto(STATUS, (broadcast, CTRL_PORT))
    while time.time() - t0 < wait_s:
        try:
            d, _ = s.recvfrom(2048)
            if d[:3] == bytes([0xA5, 0x5D, 0x04]):
                j = json.loads(d[4:].decode("utf-8", "replace"))
                found[int(j["node_id"])] = j
        except (socket.timeout, ValueError, KeyError):
            if time.time() - t0 < wait_s - 1:
                try:
                    s.sendto(STATUS, (broadcast, CTRL_PORT))
                except OSError:
                    pass
    s.close()
    return found


def _room_names():
    rooms = {}
    try:
        with open(vigil_paths.state_path("fleet.json")) as f:
            for n in json.load(f):
                rooms[int(n["node_id"])] = str(n.get("room") or f"node-{n['node_id']}")
    except Exception:
        pass
    return rooms


def solve_map(status_by_node):
    """Pairwise peers tables -> relative 2-D layout. None if under 3 nodes
    or the matrix is too sparse to mean anything (never a fabricated map)."""
    ids = sorted(status_by_node)
    n = len(ids)
    if n < 3:
        return None
    idx = {nid: i for i, nid in enumerate(ids)}
    rssi = np.full((n, n), np.nan)
    links = 0
    for nid, st in status_by_node.items():
        for peer, val in (st.get("peers") or {}).items():
            p = int(peer)
            if p in idx:
                rssi[idx[nid], idx[p]] = float(val)
                links += 1
    if links < n * (n - 1) * 0.6:      # too sparse — no honest layout
        return None
    # fill the rare missing direction with its reciprocal, else the worst RSSI
    worst = np.nanmin(rssi)
    for i in range(n):
        for j in range(n):
            if i != j and np.isnan(rssi[i, j]):
                rssi[i, j] = rssi[j, i] if not np.isnan(rssi[j, i]) else worst
    np.fill_diagonal(rssi, 0.0)
    dist = _rssi_to_distance(rssi)
    np.fill_diagonal(dist, 0.0)
    coords = _classical_mds(dist)
    # normalize to a unit box for the UI (relative layout by design)
    span = max(1e-9, float(np.ptp(coords, axis=0).max()))
    coords = (coords - coords.min(axis=0)) / span
    rooms = _room_names()
    return {
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source": "mesh-rssi (ESP-NOW survey pings, log-distance + classical MDS)",
        "error_envelope": "topology-correct relative layout; not metric floor-plan",
        "nodes": {
            str(nid): {
                "room": rooms.get(nid, f"node-{nid}"),
                "pos": [round(float(coords[idx[nid], 0]), 4),
                        round(float(coords[idx[nid], 1]), 4)],
                "role": status_by_node[nid].get("role"),
            } for nid in ids
        },
        "links": {
            f"{a}-{b}": int(rssi[idx[a], idx[b]])
            for a in ids for b in ids if a < b
        },
        "walls": _infer_walls(ids, idx, rssi, coords),
    }


def _infer_walls(ids, idx, rssi, coords):
    """Material inference from propagation: fit THIS home's own log-distance
    path-loss model over all links, then links whose measured RSSI falls >=6 dB
    below the fit (excess absorption) are classified obstructed — a wall/floor
    between those nodes. First-order and honest: it flags separations, it does
    not draw architecture. Rendered as wall ticks across the link midpoint."""
    import itertools
    pairs = [(a, b) for a, b in itertools.combinations(ids, 2)]
    if len(pairs) < 3:
        return []
    d = {p: max(1e-3, float(np.linalg.norm(coords[idx[p[0]]] - coords[idx[p[1]]])))
         for p in pairs}
    x = np.array([10.0 * math.log10(d[p]) for p in pairs])
    y = np.array([0.5 * (rssi[idx[a], idx[b]] + rssi[idx[b], idx[a]]) for a, b in pairs])
    A = np.vstack([x, np.ones_like(x)]).T
    (slope, intercept), *_ = np.linalg.lstsq(A, y, rcond=None)
    walls = []
    for k, p in enumerate(pairs):
        residual = y[k] - (slope * x[k] + intercept)
        if residual <= -6.0:
            a, b = p
            mid = (coords[idx[a]] + coords[idx[b]]) / 2.0
            walls.append({"a": a, "b": b, "loss_db": round(float(-residual), 1),
                          "mid": [round(float(mid[0]), 4), round(float(mid[1]), 4)]})
    return walls


def refresh_geometry(broadcast="192.168.88.255"):
    """Collect + solve + persist. Returns the map dict or None."""
    status = collect_peers(broadcast)
    m = solve_map(status)
    if m is not None:
        geometry_path = vigil_paths.state_path("geometry.json")
        os.makedirs(os.path.dirname(geometry_path), exist_ok=True)
        tmp = geometry_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(m, f, indent=2)
        os.replace(tmp, geometry_path)
    return m


if __name__ == "__main__":
    result = refresh_geometry()
    print(json.dumps(result, indent=2) if result else "no map (need ≥3 meshed nodes)")
