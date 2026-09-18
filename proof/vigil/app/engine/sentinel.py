#!/usr/bin/env python3
"""
Homefront Sentinel — multi-node CSI demux + per-room sensing + LAN phone view.

The single-node engine (home_engine.py) folds every radio into one slot, so two
nodes streaming at once corrupt each other. Sentinel owns UDP :5005, splits the
incoming CSI BY SENDER so each ESP32 becomes its own room with its own clean
presence / motion / breathing pipeline, and serves a mobile web page + JSON API
on 0.0.0.0 — open it in any phone browser on the same WiFi and watch the rooms
light up. Nodes auto-register the instant they power on; a node that goes quiet
flips OFFLINE (the "system is blind" signal, surfaced honestly, never hidden).

Reuses the proven, honesty-gated Vitals/RangeProfiler from home_engine — no
fabricated readings: a value is shown only when the signal genuinely clears the
gates, otherwise "—".

    python3 sentinel.py --csi-port 5005 --http-host 0.0.0.0 --http-port 8780
"""
import argparse
import json
import os
import socket
import sys
import threading
import time
from collections import OrderedDict, deque
from http.server import ThreadingHTTPServer
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from home_engine import Vitals, RangeProfiler  # proven, honesty-gated sensing
from csi_detect import NodeDetector, estimate_breathing   # SOTA motion/presence + validated breathing
from fall_detect import FallMonitor                        # eldercare fall/emergency safety layer

OFFLINE_AFTER = 6.0      # seconds without a packet -> node is OFFLINE (blind).
                         # Raised from 3s: on a congested 2.4GHz network 6 boards
                         # have brief RX gaps; 6s tolerates a dip without flapping
                         # while still catching a real unplug/power-loss quickly.
SUBCARRIERS = 56
BANDWIDTH_HZ = 20e6


class VigilHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def parse_csi(obj):
    """Wire {"csi":[i0,q0,...]} -> (amp[56], csi[56] complex). None on garbage."""
    raw = obj.get("csi")
    if not raw:
        return None, None
    arr = np.asarray(raw, dtype=np.float32)
    even = (arr.size // 2) * 2
    if even < 2:
        return None, None
    iq = arr[:even].reshape(-1, 2)
    csi = iq[:, 0] + 1j * iq[:, 1]
    n = SUBCARRIERS
    csi = csi[:n] if csi.size >= n else np.pad(csi, (0, n - csi.size))
    return np.abs(csi).astype(np.float32), csi.astype(np.complex64)


class Node:
    """One physical ESP32 = one room. Owns its own sensing pipeline."""

    def __init__(self, node_id, fs, addr_ip=None):
        self.node_id = node_id           # STABLE identity: board id from the hello, else sender IP.
        # Transport address (where to send keepalives). Decoupled from node_id so a board that
        # changes DHCP lease keeps its identity (room / calibration / floorplan position) while
        # the feeder follows it to its new IP. None until we've seen a packet from it.
        self.addr_ip = addr_ip
        self.room = None                 # assigned later (config / UI)
        self.tier = None                 # "Homefront-Pulse" etc, self-reported
        self.synthetic = False           # True = csi_sim provenance (vitals suppressed, never persisted)
        self.fs = fs
        self.frames = 0
        self.last_rx = 0.0
        self.first_rx = time.time()
        self.last_rssi = None
        self.vitals = Vitals(fs, SUBCARRIERS)               # breathing/heart (honesty-gated)
        self.ranger = RangeProfiler(SUBCARRIERS, BANDWIDTH_HZ)
        self.raw = deque(maxlen=4200)                        # (ts, amp[56]) ~70s, all detection from here
        self._breath_bpm = None; self._breath_conf = 0; self._breath_last = 0.0
        # frame-rate-ROBUST motion: live signal variance vs calibrated quiet variance.
        # Works at any/variable frame rate (the old NodeDetector assumed 30fps and
        # broke at the real 4-14fps — read 0 while the raw signal clearly moved).
        self._quiet_std = None        # baseline temporal std of an empty room
        self._quiet_samples = []      # collected during calibration window
        self._recal_until = 0.0       # collect quiet until this ts
        self._motion = 0.0; self._moving = False; self._hot_run = 0
        self._calc_last = 0.0
        # static presence: a still body changes the mean channel vs the empty room.
        # This distinguishes 'fell silently / lying still' from 'room empty' — the
        # signal the fall monitor needs to avoid both false alarms and misses.
        self._quiet_amp = None        # mean amplitude vector of the empty room
        self._quiet_amp_samples = []
        self._present_static = False
        self.fall = FallMonitor()     # the eldercare alert state machine
        self._lock = threading.Lock()
        self._snap = {"present": False, "motion": 0.0, "moving": False, "present_static": False,
                      "calibrated": False, "calibrating": 0.0, "fall": None,
                      "breathing_bpm": None, "breathing_conf": 0, "heart_bpm": None}

    MOVE_RATIO = 2.5      # live_std / quiet_std above this = movement
    CLEAR_RATIO = 1.8     # hysteresis: drop back to clear below this

    def recalibrate(self, settle=18.0):
        with self._lock:
            self._quiet_std = None
            self._quiet_samples = []
            self._quiet_amp = None
            self._quiet_amp_samples = []
            self._recal_until = time.time() + settle

    def _mean_amp(self, secs=2.0):
        """Mean amplitude vector over the last `secs` — for static-presence test."""
        if len(self.raw) < 8:
            return None
        t_end = self.raw[-1][0]
        w = [a for (t, a) in self.raw if t >= t_end - secs]
        if len(w) < 6:
            return None
        return np.mean(np.stack(w), axis=0)

    def _win_std(self, secs):
        """Doppler motion energy over the last `secs` of raw CSI (RuView ADR-012):
        power in the 0.5-3 Hz MOTION band, per subcarrier, then mean of the top-8
        responsive subcarriers. Isolating the motion frequencies (vs plain temporal
        std over all content) gives a much larger moving-vs-still separation, and
        top-k selection avoids diluting the few subcarriers that actually respond.
        Frame-rate agnostic (resamples by timestamp)."""
        if len(self.raw) < 16:
            return None
        t_end = self.raw[-1][0]
        w = [(t, a) for (t, a) in self.raw if t >= t_end - secs]
        if len(w) < 16:
            return None
        ts = np.array([t for t, _ in w], dtype=np.float64)
        A = np.stack([a for _, a in w]).astype(np.float64)   # [T, 56]
        span = ts[-1] - ts[0]
        if span < 1.5:
            return None
        fs = (ts.size - 1) / span
        n = int(span * fs)
        if n < 16:
            return None
        grid = np.linspace(ts[0], ts[-1], n)
        freqs = np.fft.rfftfreq(n, d=1.0 / fs)
        band = (freqs >= 0.5) & (freqs <= 3.0)               # human motion Doppler band
        if not band.any():
            return None
        win = np.hanning(n)
        energies = np.empty(A.shape[1])
        total = np.empty(A.shape[1])
        for j in range(A.shape[1]):
            s = np.interp(grid, ts, A[:, j]); s = s - s.mean()
            spec = np.abs(np.fft.rfft(s * win)) ** 2
            energies[j] = float(spec[band].sum())
            total[j] = float(spec.sum()) + 1e-9
        # FRACTION of each subcarrier's energy in the motion band (normalizes out
        # the frame-rate-dependent absolute scale that broke the raw-energy version),
        # weighted by motion-band power; mean of the top-8 responders.
        frac = energies / total
        score = energies * frac
        top = np.sort(score)[-8:]
        return float(np.mean(top))

    def ingest(self, amp, csi, rssi, tier):
        with self._lock:
            self.frames += 1
            self.last_rx = time.time()
            if tier:
                self.tier = tier
            if rssi is not None:
                self.last_rssi = rssi
            # CRITICAL PATH FIRST: raw buffer drives all motion detection. Nothing
            # below (vitals/breathing) may break it — they go in try/except.
            self.raw.append((self.last_rx, np.asarray(amp, dtype=np.float32)))
            try:
                self.vitals.push(amp, ts=self.last_rx)      # ts-aware if available
            except TypeError:
                try: self.vitals.push(amp)                  # old signature fallback
                except Exception: pass
            except Exception:
                pass

            # recompute robust motion ~4x/sec
            if self.last_rx - self._calc_last > 0.25:
                self._calc_last = self.last_rx
                recent = self._win_std(3.0)
                if recent is not None:
                    if self.last_rx < self._recal_until:
                        self._quiet_samples.append(recent)      # learning the empty-room floor
                    elif self._quiet_std is None and self._quiet_samples:
                        # finalize quiet baseline (median of the calm samples)
                        self._quiet_std = max(1e-6, float(np.median(self._quiet_samples)))
                    if self._quiet_std:
                        ratio = recent / self._quiet_std
                        self._motion = float(np.clip((ratio - 1.0) / 3.0, 0.0, 1.0))
                        # hysteresis so it doesn't flicker at the boundary
                        if not self._moving and ratio > self.MOVE_RATIO:
                            self._hot_run += 1
                            if self._hot_run >= 1: self._moving = True
                        elif self._moving and ratio < self.CLEAR_RATIO:
                            self._moving = False; self._hot_run = 0
                # static presence: mean-amplitude deviation from the empty-room baseline
                ma = self._mean_amp(2.0)
                if ma is not None:
                    if self.last_rx < self._recal_until:
                        self._quiet_amp_samples.append(ma)
                    elif self._quiet_amp is None and self._quiet_amp_samples:
                        self._quiet_amp = np.mean(np.stack(self._quiet_amp_samples), axis=0)
                    if self._quiet_amp is not None:
                        dev = float(np.linalg.norm(ma - self._quiet_amp) /
                                    (np.linalg.norm(self._quiet_amp) + 1e-9))
                        # "a body is here" — moving OR breathing (the reliable still-
                        # living-body signal) OR a clear mean-channel deviation. A
                        # perfectly still body barely shifts the mean, so breathing is
                        # what actually holds presence for a motionless fallen person.
                        breathing_now = (self._breath_bpm is not None and self._breath_conf >= 5)
                        self._present_static = bool(self._moving or breathing_now or dev > 0.08)

            # breathing only when still (and calibrated), throttled — never break motion
            try:
                if (self._quiet_std and not self._moving and (self.last_rx - self._breath_last) > 1.0
                        and len(self.raw) > 200):
                    self._breath_last = self.last_rx
                    win = [(t, a) for (t, a) in self.raw if t >= self.last_rx - 22.0]
                    if len(win) > 64:
                        tsw = np.array([t for t, _ in win]); ampw = np.stack([a for _, a in win])
                        bpm, conf = estimate_breathing(tsw, ampw)
                        self._breath_bpm, self._breath_conf = bpm, conf
                elif self._moving:
                    self._breath_bpm, self._breath_conf = None, 0
            except Exception:
                self._breath_bpm, self._breath_conf = None, 0

            try:
                vit = self.vitals.snapshot(occupied=self._moving)
            except Exception:
                vit = {"heart_bpm": None}
            calibrated = self._quiet_std is not None
            calibrating = 1.0 if calibrated else (
                min(0.99, len(self._quiet_samples) / 30.0) if self._recal_until else 0.0)
            # ---- fall/emergency monitor on the reliable signals ----
            breathing_detected = self._breath_bpm is not None and self._breath_conf >= 5
            fall_pub = self.fall.update(self.last_rx, self._moving, breathing_detected,
                                        self._present_static, calibrated)
            self._snap = {
                "present": self._present_static,
                "motion": round(self._motion, 3),
                "moving": self._moving,
                "present_static": self._present_static,
                "calibrated": calibrated,
                "calibrating": calibrating,
                "fall": fall_pub,                 # {state, alert, last_motion_s, last_breath_s}
                "breathing_bpm": round(self._breath_bpm, 1) if self._breath_bpm else None,
                "breathing_conf": self._breath_conf,
                "heart_bpm": vit.get("heart_bpm"),
            }

    def online(self):
        return self.frames > 0 and (time.time() - self.last_rx) < OFFLINE_AFTER

    def status(self):
        online = self.online()
        with self._lock:
            s = dict(self._snap)
        age = time.time() - self.last_rx if self.last_rx else None
        return {
            "node_id": self.node_id,
            "ip": self.addr_ip,          # current transport address (may differ from node_id when board id is used)
            "room": self.room,
            "tier": self.tier,
            "online": online,
            "frames": self.frames,
            "rssi": self.last_rssi,
            "last_rx_age_s": round(age, 2) if age is not None else None,
            # honest empty-state when blind: never carry a stale reading forward
            "present": bool(s.get("present")) if online else False,
            "moving": bool(s.get("moving")) if online else False,
            "motion": float(s.get("motion", 0.0)) if online else 0.0,
            "calibrated": bool(s.get("calibrated")) if online else False,
            "calibrating": float(s.get("calibrating", 0.0)),
            # Synthetic frames (the csi_sim "sim" flag) must NEVER surface a vital as a real reading
            # — that's the eldercare fabrication failure mode. Suppress BPM + mark demo, exactly like
            # home_engine.py does for the single-node path.
            "breathing_bpm": None if getattr(self, "synthetic", False) else (s.get("breathing_bpm") if online else None),
            "breathing_conf": 0 if getattr(self, "synthetic", False) else (s.get("breathing_conf", 0) if online else 0),
            "heart_bpm": None if getattr(self, "synthetic", False) else (s.get("heart_bpm") if online else None),
            "demo": bool(getattr(self, "synthetic", False)),
            # eldercare: live safety state + latched alert (or OFFLINE = blind alert)
            "fall": s.get("fall") if online else {"state": "OFFLINE", "alert": {
                "kind": "OFFLINE", "message": "Sensor offline — monitoring is blind", "acknowledged": False}},
        }


DATA_DIR = os.environ.get("HF_DATA", os.path.expanduser("~/.homefront"))
ROOMS_PATH = os.path.join(DATA_DIR, "rooms.json")
POS_PATH = os.path.join(DATA_DIR, "positions.json")     # node_id -> {x,y} on floorplan
SHAPE_PATH = os.path.join(DATA_DIR, "roomshapes.json")  # room -> [[x,y],...] traced polygon
NOTIFY_PATH = os.path.join(DATA_DIR, "notify.json")     # {"ntfy_topic": "..."} for remote push
KNOWN_NODES_PATH = os.path.join(DATA_DIR, "known_nodes.json")  # node_id -> last known rx/tier/rssi
FLOORPLAN_DIR = os.path.join(DATA_DIR, "floorplans")

# ---- alert history honesty gates (HF-2) --------------------------------------
ALERTS_MAX_AGE_S = 24 * 3600.0      # /alerts NEVER surfaces an alert older than this
ALERTS_LOG_MAX_BYTES = 512 * 1024   # rotate the incident log past this (dedup keeps it small anyway)
NOTIFY_CADENCE_S = 30.0             # re-push an un-acked emergency this often for the first few minutes
NOTIFY_HARD_WINDOW_S = 300.0       # after this long live, ease the push cadence (nag, don't hammer)
NOTIFY_BACKOFF_S = 300.0           # eased re-push cadence past the hard window


def load_alerts(path, now=None, max_age_s=ALERTS_MAX_AGE_S, limit=100):
    """Read the fall/emergency alert history for the app, HONESTLY.

      * AGE-FILTER — an alert older than `max_age_s` (default 24h) is never
        surfaced. A guardian that was offline for days must not replay a
        4-day-old FALL as if it were happening now: a stale reading presented as
        live is a fabrication (§5.1). This is the core HF-2 fix.
      * INCIDENT-DEDUP — a single un-acknowledged episode that re-notified N
        times collapses to ONE entry (with `count` = how many notifications it
        produced and `since_ts` = when it began), instead of N separate 'alerts'.
        That kills the re-notify storm the app would otherwise render as dozens
        of falls.

    Pure (path in, list out) so it unit-tests without HTTP. Newest incident first.
    Tolerant of the legacy log format (entries with only ts/title/body).
    """
    now = time.time() if now is None else now
    cutoff = (now - max_age_s) if (max_age_s and max_age_s > 0) else None
    groups = OrderedDict()
    try:
        with open(path) as f:
            lines = f.readlines()[-4000:]           # bound the tail scanned
    except Exception:
        return []
    for line in lines:
        try:
            e = json.loads(line)
        except Exception:
            continue
        ts = e.get("ts")
        if not isinstance(ts, (int, float)):
            continue
        if cutoff is not None and ts < cutoff:
            continue                                # stale — dropped (the HF-2 gate)
        key = e.get("incident") or "{}|{}".format(
            e.get("node_id", ""), e.get("kind") or e.get("title", ""))
        groups.setdefault(key, []).append(e)
    out = []
    for es in groups.values():
        es.sort(key=lambda r: r.get("ts", 0))
        newest = dict(es[-1])
        newest["count"] = len(es)                   # transparency: notifications collapsed into this incident
        newest["since_ts"] = es[0].get("ts")
        out.append(newest)
    out.sort(key=lambda r: r.get("ts", 0), reverse=True)
    return out[:limit]


class Sentinel:
    def __init__(self, csi_port=5005, fs=30.0, rooms_path=ROOMS_PATH,
                 feed_port=5006, feed_hz=60, known_nodes_path=KNOWN_NODES_PATH):
        self.csi_port = csi_port
        self.fs = fs
        self.feed_port = feed_port       # port we blast keepalive packets at
        self.feed_hz = feed_hz           # target RX rate per node (keeps CSI alive)
        self.nodes = OrderedDict()       # node_id -> Node
        self.rooms_path = rooms_path
        self.known_nodes_path = known_nodes_path
        self.known_nodes = self._load_known_nodes()
        self._known_nodes_last_save = 0.0
        self.rooms = self._load_rooms()  # node_id -> room name (persisted)
        self.positions = self._load_json(POS_PATH)   # node_id -> {"x":..,"y":..} on floorplan
        self.roomshapes = self._load_json(SHAPE_PATH) # room -> [[x,y],...] traced polygon
        self._lock = threading.Lock()
        self._seed_known_nodes()
        self._logged_incidents = self._preload_incident_keys()  # HF-2: one log line per episode
        self.started = time.time()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", csi_port))

    def _load_rooms(self):
        try:
            with open(self.rooms_path) as f:
                d = json.load(f)
            return {str(k): str(v) for k, v in d.items()} if isinstance(d, dict) else {}
        except Exception:
            return {}

    def _load_json(self, path):
        try:
            with open(path) as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def _load_known_nodes(self):
        d = self._load_json(self.known_nodes_path)
        known = {}
        for node_id, meta in d.items():
            if not isinstance(meta, dict):
                continue
            try:
                last_rx = float(meta.get("last_rx") or 0.0)
            except (TypeError, ValueError):
                last_rx = 0.0
            known[str(node_id)] = {
                "last_rx": last_rx,
                "tier": str(meta["tier"]) if meta.get("tier") is not None else None,
                "rssi": meta.get("rssi"),
                "ip": str(meta["ip"]) if meta.get("ip") is not None else None,
            }
        return known

    def _save_json(self, path, obj):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(obj, f, indent=2)
            os.replace(tmp, path)
        except Exception:
            pass

    def _save_known_nodes(self):
        self._save_json(self.known_nodes_path, self.known_nodes)

    def _seed_known_nodes(self):
        for node_id, meta in self.known_nodes.items():
            node = Node(node_id, self.fs, addr_ip=meta.get("ip"))
            node.tier = meta.get("tier")
            node.last_rssi = meta.get("rssi")
            node.last_rx = float(meta.get("last_rx") or 0.0)
            self.nodes[node_id] = node

    def _remember_node(self, node_id, tier=None, rssi=None, last_rx=None, ip=None,
                       synthetic=False):
        if synthetic:
            # A simulated node (csi_sim provenance) must NEVER persist to the roster:
            # on restart it would seed as a real-looking offline board — a fabricated
            # device record (§5.1). Forget any entry it transiently created, too.
            if node_id in self.known_nodes:
                del self.known_nodes[node_id]
                self._save_known_nodes()
            return
        now = time.time()
        meta = self.known_nodes.get(node_id, {})
        updated = {
            "last_rx": float(last_rx or now),
            "tier": tier if tier is not None else meta.get("tier"),
            "rssi": rssi if rssi is not None else meta.get("rssi"),
            "ip": ip if ip is not None else meta.get("ip"),
        }
        changed_identity = (
            node_id not in self.known_nodes
            or updated.get("tier") != meta.get("tier")
            or updated.get("ip") != meta.get("ip")
            or (rssi is not None and meta.get("rssi") is None)
        )
        self.known_nodes[node_id] = updated
        if changed_identity or now - self._known_nodes_last_save >= 5.0:
            self._known_nodes_last_save = now
            self._save_known_nodes()

    def set_position(self, node_id, x, y):
        """Place a node on the floorplan (x,y normalized 0..1). Persists."""
        node_id = str(node_id)
        with self._lock:
            if node_id not in self.nodes:
                return {"ok": False, "error": "unknown node", "node_id": node_id}
            self.positions[node_id] = {"x": float(x), "y": float(y)}
            self._save_json(POS_PATH, self.positions)
        return {"ok": True, "node_id": node_id, "x": x, "y": y}

    def set_roomshape(self, room, points):
        """Store a traced room polygon (list of [x,y] normalized 0..1). Persists."""
        room = str(room or "").strip()
        if not room:
            return {"ok": True, "room": None, "points": 0}
        pts = [[float(p[0]), float(p[1])] for p in points][:64]
        with self._lock:
            self.roomshapes[room] = pts
            self._save_json(SHAPE_PATH, self.roomshapes)
        return {"ok": True, "room": room, "points": len(pts)}

    def _save_rooms(self):
        try:
            os.makedirs(os.path.dirname(self.rooms_path), exist_ok=True)
            tmp = self.rooms_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.rooms, f, indent=2)
            os.replace(tmp, self.rooms_path)
        except Exception:
            pass   # naming is best-effort; never take the guardian down for it

    def raw_window(self, node_id, secs=60.0):
        """Return the last `secs` of raw (ts, amp[56]) for a node — for calibration."""
        with self._lock:
            node = self.nodes.get(str(node_id))
            rows = list(node.raw) if node else []
        if not rows:
            return {"node_id": node_id, "frames": 0, "ts": [], "amp": []}
        t_end = rows[-1][0]
        rows = [(t, a) for (t, a) in rows if t >= t_end - secs]
        return {
            "node_id": node_id,
            "frames": len(rows),
            "span_s": round(rows[-1][0] - rows[0][0], 2) if len(rows) > 1 else 0,
            "ts": [round(t, 4) for t, _ in rows],
            "amp": [a.tolist() for _, a in rows],
        }

    def recalibrate(self, node_id=None):
        """Re-learn the quiet baseline. node_id=None recalibrates every node.
        Use after placing/moving a node, with the room empty + still."""
        with self._lock:
            if node_id:
                if node_id not in self.nodes:
                    return {"ok": False, "error": "unknown node", "node_id": node_id}
                targets = [self.nodes[node_id]]
            else:
                targets = list(self.nodes.values())
        for n in targets:
            n.recalibrate()
        return {"ok": True, "recalibrated": [n.node_id for n in targets]}

    def assign_room(self, node_id, room):
        """Name (or rename) the room a node lives in. Persists immediately."""
        node_id = str(node_id)
        room = (room or "").strip()
        with self._lock:
            if node_id not in self.nodes:
                return {"ok": False, "error": "unknown node", "node_id": node_id}
            if room:
                self.rooms[node_id] = room
            else:
                self.rooms.pop(node_id, None)   # blank clears the name
            self._save_rooms()
        return {"ok": True, "node_id": node_id, "room": room or None}

    def acknowledge(self, node_id=None):
        """Acknowledge (silence) a live alert. node_id=None acknowledges all."""
        with self._lock:
            if node_id:
                if node_id not in self.nodes:
                    return {"ok": False, "error": "unknown node", "node_id": node_id}
                targets = [self.nodes[node_id]]
            else:
                targets = list(self.nodes.values())
        for n in targets:
            n.fall.acknowledge()
        return {"ok": True, "acknowledged": [n.node_id for n in targets]}

    def _node_for_addr(self, addr, tier=None, board=None, synthetic=None):
        ip = addr[0]
        # Stable identity: prefer the board's self-reported id (survives a DHCP lease change);
        # fall back to sender IP for boards/sims that don't report one (backward compatible).
        board_id = str(board).strip() if board else ""
        node_id = board_id or ip
        with self._lock:
            node = self.nodes.get(node_id)
            if node is None and board_id and ip in self.nodes:
                # Upgrade an old IP-keyed node in place once newer firmware reports
                # its stable board id. This preserves calibration and room/map state
                # instead of showing the same board twice after a firmware rollout.
                node = self.nodes.pop(ip)
                node.node_id = node_id
                if ip in self.rooms and node_id not in self.rooms:
                    self.rooms[node_id] = self.rooms.pop(ip)
                    self._save_rooms()
                if ip in self.positions and node_id not in self.positions:
                    self.positions[node_id] = self.positions.pop(ip)
                    self._save_json(POS_PATH, self.positions)
                self.known_nodes.pop(ip, None)
                self.nodes[node_id] = node
            if node is None:
                node = Node(node_id, self.fs, addr_ip=ip)
                self.nodes[node_id] = node
            else:
                node.addr_ip = ip        # follow the board if its IP moved
            if tier:
                node.tier = tier
            if synthetic is not None:
                node.synthetic = bool(synthetic)   # csi_sim provenance → vitals suppressed, never persisted
            self._remember_node(node_id, node.tier, ip=ip,
                                synthetic=getattr(node, "synthetic", False))
        return node

    def start(self):
        threading.Thread(target=self._recv_loop, daemon=True).start()
        threading.Thread(target=self._feeder_loop, daemon=True).start()
        threading.Thread(target=self._alert_loop, daemon=True).start()

    def _preload_incident_keys(self, tail=4000):
        """Seed the logged-incident set from the existing alert log so a restart
        mid-episode doesn't re-log an incident that's already in the history."""
        keys = set()
        try:
            with open(os.path.join(DATA_DIR, "alerts.log")) as f:
                for line in f.readlines()[-tail:]:
                    try:
                        inc = json.loads(line).get("incident")
                    except Exception:
                        continue
                    if inc:
                        keys.add(inc)
        except Exception:
            pass
        return keys

    def _record_alert(self, node_id, room, kind, message, since):
        """Append ONE line per fall/emergency EPISODE to the alert history (dedup by
        incident key = node|kind|start). Re-notifications of the same latched alert do
        NOT append again — that de-storms /alerts (HF-2). Bounded so it can't grow
        without limit. Never raises: the guardian must not die over a log write."""
        incident = f"{node_id}|{kind}|{int(since)}"
        with self._lock:
            if incident in self._logged_incidents:
                return
            self._logged_incidents.add(incident)
        entry = {
            "ts": time.time(), "node_id": node_id, "room": room, "kind": kind,
            "title": f"⚠ {str(kind).replace('_', ' ')} — {room}",
            "body": message, "incident": incident, "acknowledged": False,
        }
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
            path = os.path.join(DATA_DIR, "alerts.log")
            with open(path, "a") as f:
                f.write(json.dumps(entry) + "\n")
            self._rotate_alert_log(path)
        except Exception:
            pass

    @staticmethod
    def _rotate_alert_log(path, max_bytes=ALERTS_LOG_MAX_BYTES, keep=500):
        """Keep alerts.log bounded: past max_bytes, atomically rewrite it with only the
        newest `keep` lines. Incident-dedup makes appends rare so this seldom fires;
        it's a backstop against unbounded growth (the live log had reached >1MB)."""
        try:
            if os.path.getsize(path) <= max_bytes:
                return
            with open(path) as f:
                tail = f.readlines()[-keep:]
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                f.writelines(tail)
            os.replace(tmp, path)
        except Exception:
            pass

    def _alert_loop(self):
        """Watch every node's fall monitor; on a live, unacknowledged alert, notify
        (repeat on a cadence until acknowledged). Delivery: macOS notification on the
        always-on home computer + optional remote push so a caregiver is reached off
        the home network. Config in ~/.homefront/notify.json (token-based, no creds in code)."""
        while True:
            try:
                self._alert_tick(time.time())
            except Exception:
                pass
            time.sleep(2.0)

    def _alert_tick(self, now):
        """One pass over every node's fall monitor (extracted from _alert_loop so the
        alert/notify gating is unit-testable)."""
        with self._lock:
            items = [(nid, n) for nid, n in self.nodes.items()]
        for nid, n in items:
            if not n.online():
                continue
            # §5.1: a csi_sim (demo) node must NEVER push a real emergency to macOS /
            # the relay or persist one to /alerts. Its vitals are already suppressed in
            # status(); gate the alert/notify path the same way so replay data can't
            # mint a fall/no-breathing alarm from thin air.
            if getattr(n, "synthetic", False):
                continue
            a = n.fall.alert
            if not a or a.get("acknowledged"):
                continue
            room = self.rooms.get(nid) or nid
            # (1) persistent history — logged ONCE per episode (dedup), so an
            # un-acknowledged fall can't flood /alerts with one entry per tick.
            self._record_alert(nid, room, a["kind"], a["message"], a["since"])
            # (2) push reminder — repeats until acknowledged, but BACKS OFF after
            # the first few minutes (a fall alarm should nag, not fire Sosumi
            # every 30s for days as the live log showed it doing).
            live_s = max(0.0, now - a["since"])
            cadence = NOTIFY_CADENCE_S if live_s < NOTIFY_HARD_WINDOW_S else NOTIFY_BACKOFF_S
            if n.fall.needs_notify(now, cadence_s=cadence):
                self._notify(f"⚠ {a['kind'].replace('_',' ')} — {room}", a["message"])

    @staticmethod
    def _osa_escape(s):
        # Room names come from the UNAUTHENTICATED /assign endpoint (reachable over the public
        # tunnel). Never interpolate them raw into an `osascript -e` string literal — escape the
        # backslash + double-quote and strip newlines so a crafted room name can't break out of
        # the literal and run arbitrary AppleScript / shell on the home Mac.
        return (str(s).replace("\\", "\\\\").replace('"', '\\"')
                .replace("\n", " ").replace("\r", " "))

    def _notify(self, title, body):
        """Best-effort multi-channel alert. Never raises."""
        # 1) macOS local notification (the always-on home computer)
        try:
            import subprocess
            t, b = self._osa_escape(title), self._osa_escape(body)
            subprocess.run(["osascript", "-e",
                            f'display notification "{b}" with title "{t}" sound name "Sosumi"'],
                           timeout=5, check=False)
        except Exception:
            pass
        # 2) remote push (reaches a phone off the home WiFi) — ntfy.sh topic from config
        try:
            cfg = self._load_json(NOTIFY_PATH)
            topic = cfg.get("ntfy_topic")
            if topic:
                import urllib.request
                req = urllib.request.Request(f"https://ntfy.sh/{topic}",
                    data=body.encode(), method="POST",
                    headers={"Title": title, "Priority": "urgent", "Tags": "rotating_light"})
                urllib.request.urlopen(req, timeout=6)
        except Exception:
            pass
        # NOTE: the persistent alert history (alerts.log) is written by _record_alert —
        # ONCE per episode (dedup) — NOT here. _notify fires on the re-notify cadence, so
        # writing the log here is exactly what produced the ~59/hr storm the app rendered
        # as dozens of falls. Push channels above may repeat; the history must not.

    def _feeder_loop(self):
        """Keep every node's CSI flowing.

        A node only produces CSI when it RECEIVES WiFi packets. The firmware's
        router-ping starves (home routers rate-limit), collapsing every board to
        ~beacon rate (~2 frames/s) — far below the ~25-30/s the motion/vitals math
        needs. The engine knows each node's IP (they stream to us), so we feed each
        a steady unicast stream: their RX rate stays high, CSI flows, and it scales
        to any number of nodes independent of the router. Proven: 2/s -> 26/s.
        """
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        pkt = b"hf-csi-keepalive"
        per_node_hz = max(20, self.feed_hz)
        while True:
            with self._lock:
                # Feed each node at its CURRENT transport IP (node_id may be a board id, not an
                # address). Skip seeded-offline placeholders that have no known IP yet.
                targets = [n.addr_ip for n in self.nodes.values() if n.addr_ip]
            if not targets:
                time.sleep(0.2)
                continue
            # one burst to every known node, then sleep to hold the per-node rate
            for _ in range(4):                      # 4 packets/node/cycle
                for ip in targets:
                    try:
                        sock.sendto(pkt, (ip, self.feed_port))
                    except OSError:
                        pass
            time.sleep(4.0 / per_node_hz)

    def _recv_loop(self):
        while True:
            try:
                data, addr = self.sock.recvfrom(16384)
            except OSError:
                break
            try:
                obj = json.loads(data.decode("utf-8", "ignore"))
                amp, csi = parse_csi(obj)
                board = obj.get("board")
                sim = obj.get("sim")               # None when absent (real firmware)
                if obj.get("hello"):
                    self._node_for_addr(addr, obj.get("tier"), board, synthetic=sim)
                if amp is None:
                    continue
                node = self._node_for_addr(addr, obj.get("tier"), board,
                                           synthetic=bool(sim))
                node.ingest(amp, csi, obj.get("rssi"), obj.get("tier"))
                with self._lock:
                    self._remember_node(node.node_id, node.tier, node.last_rssi, node.last_rx,
                                        ip=node.addr_ip, synthetic=node.synthetic)
            except Exception:
                # a single bad datagram must NEVER take the guardian down
                continue

    def snapshot(self):
        with self._lock:
            nodes = [n.status() for n in self.nodes.values()]
            rooms = dict(self.rooms)
            positions = dict(self.positions)
        for n in nodes:
            n["room"] = rooms.get(n["node_id"])      # persisted name overrides
            n["pos"] = positions.get(n["node_id"])   # {x,y} on floorplan, or None
        # "moving now" = each node's OWN robust moving flag (variance-ratio vs its
        # calibrated quiet floor, hysteresis). Per-node so both corners can light up
        # and the view can weight position; an empty room shows none.
        for n in nodes:
            n["moving_now"] = bool(n["online"] and n.get("moving"))
        return {
            "ts": time.time(),
            "uptime_s": round(time.time() - self.started, 1),
            "node_count": len(nodes),
            "online_count": sum(1 for n in nodes if n["online"]),
            "any_present": any(n["present"] for n in nodes),
            "nodes": nodes,
            "roomshapes": dict(self.roomshapes),
        }


# ----------------------------------------------------------------------------
# LAN phone view — a self-refreshing mobile page any phone on the WiFi can open.
# ----------------------------------------------------------------------------
PHONE_PAGE = """<!DOCTYPE html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Homefront</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0b0d;color:#e8e8ea;font:15px -apple-system,system-ui,sans-serif;
 padding:env(safe-area-inset-top) 14px 40px;-webkit-font-smoothing:antialiased}
header{display:flex;align-items:center;justify-content:space-between;padding:18px 2px 14px}
.brand{font-weight:700;letter-spacing:.14em;font-size:13px}
.brand b{color:#c8a04a}.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px}
.sub{font-size:11px;color:#6b6f76;letter-spacing:.04em}
.grid{display:grid;gap:12px}
.card{background:#141519;border:1px solid #20222a;border-radius:16px;padding:16px 16px 14px;
 position:relative;overflow:hidden}
.card.on{border-color:#2c5f3a}.card.present{border-color:#c8a04a;box-shadow:0 0 0 1px #c8a04a55,0 8px 30px #c8a04a18}
.card.offline{opacity:.55;border-color:#3a2230}
.card.moving{border-color:#5fb8ff;box-shadow:0 0 0 2px #5fb8ff66,0 8px 30px #5fb8ff22}
.room{font-size:18px;font-weight:650;cursor:pointer}
.room .pen{font-size:12px;color:#5a5e66;margin-left:7px;font-weight:400}
.moving-tag{position:absolute;left:16px;bottom:13px;font-size:11px;font-weight:600;color:#5fb8ff;letter-spacing:.05em}
.tier{font-size:11px;color:#7a7f88;letter-spacing:.05em;margin-top:1px}
.idbar{background:#11202b;border:1px solid #244a5e;color:#9fd3ee;border-radius:12px;
 padding:11px 14px;font-size:13px;margin-bottom:12px;line-height:1.45}
.state{position:absolute;top:16px;right:16px;font-size:11px;font-weight:600;letter-spacing:.06em;
 padding:4px 9px;border-radius:20px}
.s-present{background:#c8a04a;color:#1a1206}.s-clear{background:#1e2a20;color:#5fb878}
.s-off{background:#2a1820;color:#d06a8a}
.row{display:flex;gap:18px;margin-top:14px}
.metric{flex:1}.mlabel{font-size:10px;color:#6b6f76;letter-spacing:.08em;text-transform:uppercase}
.mval{font-size:22px;font-weight:600;margin-top:3px;font-variant-numeric:tabular-nums}
.mval .u{font-size:11px;color:#7a7f88;font-weight:400}
.bar{height:5px;background:#22242c;border-radius:3px;margin-top:9px;overflow:hidden}
.bar>i{display:block;height:100%;background:linear-gradient(90deg,#5fb878,#c8a04a);width:0;transition:width .4s}
.empty{color:#4a4e56}
footer{text-align:center;color:#4a4e56;font-size:11px;margin-top:22px;line-height:1.5}
</style></head><body>
<header><div><div class=brand>HOME<b>FRONT</b></div><div class=sub id=sub>connecting…</div></div>
<div style="text-align:right"><div class=sub>NODES</div><div style="font-size:22px;font-weight:600" id=nc>–</div></div>
</header>
<div class=idbar>To name a room: tap a card's title and type the room. To tell which board is which — <b>walk up to it and wave</b>; the one sensing you turns <b style="color:#5fb8ff">blue</b>. Then name it.</div>
<div class=grid id=grid></div>
<footer>Live presence over your home WiFi · on-device · readings are best-effort,<br>not a medical device. Keep a worn fall alarm as the primary safety net.</footer>
<script>
function fmtbpm(v){return v==null?'<span class=empty>—</span>':(Math.round(v)+' <span class=u>bpm</span>')}
async function rename(nid,cur){
 const name=prompt('Room name for this sensor:',cur||'');
 if(name===null)return;
 try{await fetch('/assign',{method:'POST',headers:{'Content-Type':'application/json',
   'X-Homefront-Token':(new URLSearchParams(location.search).get('token')||'')},
   body:JSON.stringify({node_id:nid,room:name.trim()})});}catch(e){}
 tick();
}
async function tick(){
 try{
  const r=await fetch('/nodes',{cache:'no-store'});const d=await r.json();
  document.getElementById('nc').textContent=d.online_count+'/'+d.node_count;
  document.getElementById('sub').textContent=d.any_present?'PRESENCE DETECTED':'all clear · '+d.online_count+' online';
  const g=document.getElementById('grid');
  const esc=s=>String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
  if(!d.nodes.length){g.innerHTML='<div class=card><div class=room>No nodes yet</div><div class=tier>plug a sensor into power on this WiFi</div></div>';return}
  g.innerHTML=d.nodes.map(n=>{
   const off=!n.online, pres=n.present, mv=n.moving_now, cal=n.calibrated;
   const cls=off?'offline':(!cal?'on':(mv?'moving':(pres?'present':'on')));
   const badge=off?'<span class="state s-off">OFFLINE</span>'
     :(!cal?`<span class="state s-clear">CALIBRATING ${Math.round((n.calibrating||0)*100)}%</span>`
     :(pres?'<span class="state s-present">PRESENT</span>':'<span class="state s-clear">CLEAR</span>'));
   const mot=Math.min(100,Math.round((n.motion||0)*100));
   const named=n.room, room=named||('Node '+(n.node_id||'').split('.').pop());
   const tier=(n.tier||'sensor').replace('Homefront-','');
   const idlast=(n.node_id||'').split('.').pop();
   return `<div class="card ${cls}">${badge}
    <div class=room data-nid="${esc(n.node_id)}" data-room="${esc(named||'')}">${esc(room)}<span class=pen>✎</span></div>
    <div class=tier>${tier} · id ${idlast}${off?' · no signal':''}</div>
    <div class=row>
     <div class=metric><div class=mlabel>Motion</div><div class=mval>${off?'<span class=empty>—</span>':mot+'<span class=u>%</span>'}</div>
      <div class=bar><i style="width:${off?0:mot}%"></i></div></div>
     <div class=metric><div class=mlabel>Breathing</div><div class=mval>${off?'<span class=empty>—</span>':fmtbpm(n.breathing_bpm)}</div></div>
     <div class=metric><div class=mlabel>Heart</div><div class=mval>${off?'<span class=empty>—</span>':fmtbpm(n.heart_bpm)}</div></div>
    </div>${mv?'<div class=moving-tag>◂ MOVING NOW</div>':''}</div>`}).join('');
  // Attach the rename handler from escaped data-* attrs (no inline onclick = no JS-string injection).
  g.querySelectorAll('.room[data-nid]').forEach(el=>el.onclick=()=>rename(el.dataset.nid,el.dataset.room));
 }catch(e){document.getElementById('sub').textContent='reconnecting…'}
}
tick();setInterval(tick,1000);
</script></body></html>"""


MAP_PAGE = """<!DOCTYPE html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>Homefront Map</title><style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
body{background:#070809;color:#e8e8ea;font:14px -apple-system,system-ui,sans-serif;overflow:hidden}
header{display:flex;align-items:center;justify-content:space-between;padding:14px 16px 10px}
.brand{font-weight:700;letter-spacing:.14em;font-size:12px}.brand b{color:#c8a04a}
.sub{font-size:11px;color:#6b6f76}
.wrap{position:relative;margin:0 auto;touch-action:none}
#fp{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;opacity:.85}
.node{position:absolute;width:54px;height:54px;margin:-27px 0 0 -27px;border-radius:50%;
 display:flex;align-items:center;justify-content:center;cursor:grab;transition:background .3s,box-shadow .3s;
 background:#1a2733cc;border:2px solid #3a4654;backdrop-filter:blur(2px)}
.node .lbl{font-size:10px;font-weight:600;color:#cfd6de;text-align:center;line-height:1.1;pointer-events:none}
.node.present{background:#c8a04acc;border-color:#ffd680;box-shadow:0 0 26px #c8a04a}
.node.present .lbl{color:#1a1206}
.node.moving{background:#5fb8ffcc;border-color:#bfe4ff;box-shadow:0 0 30px #5fb8ff}
.node.off{opacity:.4;border-color:#5a2233}
.node .ring{position:absolute;inset:-8px;border-radius:50%;border:2px solid #c8a04a;opacity:0;animation:none}
.node.present .ring{animation:pulse 1.6s ease-out infinite}
@keyframes pulse{0%{transform:scale(.7);opacity:.7}100%{transform:scale(1.5);opacity:0}}
.bar{position:fixed;left:0;right:0;bottom:0;background:#0d0f12;border-top:1px solid #1c1f26;
 padding:12px 16px calc(12px + env(safe-area-inset-bottom));display:flex;gap:10px;align-items:center;font-size:12px;color:#8a9099}
.bar b{color:#c8a04a}.hint{position:fixed;top:54px;left:0;right:0;text-align:center;font-size:11px;color:#5a5e66}
a.tog{color:#5fb8ff;text-decoration:none;font-size:12px}
</style></head><body>
<header><div class=brand>HOME<b>FRONT</b> · MAP</div>
 <div><a class=tog id=traceBtn href="javascript:toggleTrace()">✏️ trace room</a> &nbsp; <a class=tog href="/">list →</a></div></header>
<div class=hint id=hint>Drag a node to where its board sits. Walk to a board &amp; wave — it turns <b style="color:#5fb8ff">blue</b>.</div>
<div class=wrap id=wrap>
 <img id=fp src="/floorplans/living_room.jpg" alt="">
 <svg id=poly viewBox="0 0 100 100" preserveAspectRatio=none style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none"></svg>
 <div id=layer></div>
</div>
<div class=bar><span id=stat>…</span></div>
<script>
const wrap=document.getElementById('wrap'),layer=document.getElementById('layer'),fp=document.getElementById('fp'),poly=document.getElementById('poly');
let W=0,H=0,drag=null,nodes=[],tracing=false,tracePts=[],shapes={};
function fit(){const ar=1,vw=innerWidth,vh=innerHeight-150;let w=vw,h=vw/ar;if(h>vh){h=vh;w=h*ar}
 W=w;H=h;wrap.style.width=w+'px';wrap.style.height=h+'px'}
addEventListener('resize',fit);fit();
function defPos(i,n){return {x:.2+.6*((i+.5)/Math.max(n,1)), y:.5}}
async function save(id,x,y){try{await fetch('/position',{method:'POST',headers:{'Content-Type':'application/json'},
 body:JSON.stringify({node_id:id,x:Math.max(0,Math.min(1,x)),y:Math.max(0,Math.min(1,y))})})}catch(e){}}
function drawPoly(){
 const pts = tracing ? tracePts : (shapes.living_room||[]);
 if(!pts.length){poly.innerHTML='';return;}
 const pp=pts.map(p=>(p[0]*100)+','+(p[1]*100)).join(' ');
 const dots = tracing ? pts.map(p=>`<circle cx=${p[0]*100} cy=${p[1]*100} r=1.4 fill="#5fb8ff"/>`).join('') : '';
 const close = tracing?'':'Z';
 poly.innerHTML=`<polygon points="${pp}" fill="#c8a04a14" stroke="#c8a04a" stroke-width=".5" stroke-linejoin=round/>${dots}`;
}
function toggleTrace(){
 tracing=!tracing;
 document.getElementById('traceBtn').textContent=tracing?'✓ done':'✏️ trace room';
 document.getElementById('hint').innerHTML=tracing
   ?'Tap each corner of the room, walking the walls. Tap <b>✓ done</b> to save. Tap a dot to undo.'
   :'Drag a node to where its board sits. Walk to a board &amp; wave — it turns <b style="color:#5fb8ff">blue</b>.';
 if(!tracing && tracePts.length>=3){
   fetch('/roomshape',{method:'POST',headers:{'Content-Type':'application/json'},
     body:JSON.stringify({room:'living_room',points:tracePts})});
   shapes.living_room=tracePts.slice();
 }
 if(tracing){tracePts=[];}
 drawPoly();
}
wrap.addEventListener('click',e=>{
 if(!tracing)return;
 if(e.target.closest('.node'))return;
 const r=wrap.getBoundingClientRect();
 const x=(e.clientX-r.left)/W, y=(e.clientY-r.top)/H;
 // tap near an existing point = undo it
 const near=tracePts.findIndex(p=>Math.hypot(p[0]-x,p[1]-y)<0.03);
 if(near>=0)tracePts.splice(near,1); else tracePts.push([x,y]);
 drawPoly();
});
function render(d){
 const stat=d.any_present?'PRESENCE DETECTED':(d.online_count+'/'+d.node_count+' online · clear');
 document.getElementById('stat').innerHTML='<b>'+stat+'</b>';
 if(d.roomshapes){shapes=d.roomshapes; if(!tracing)drawPoly();}
 nodes=d.nodes;
 layer.querySelectorAll('.node').forEach(e=>{if(!nodes.find(n=>n.node_id===e.dataset.id))e.remove()});
 nodes.forEach((n,i)=>{
  let el=layer.querySelector('.node[data-id="'+n.node_id+'"]');
  if(!el){el=document.createElement('div');el.className='node';el.dataset.id=n.node_id;
   el.innerHTML='<div class=ring></div><div class=lbl></div>';layer.appendChild(el);bindDrag(el)}
  const p=n.pos||defPos(i,nodes.length);
  if(el!==drag){el.style.left=(p.x*W)+'px';el.style.top=(p.y*H)+'px'}
  el.className='node'+(!n.online?' off':(n.moving_now?' moving':(n.present?' present':'')));
  const last=n.node_id.split('.').pop();
  el.querySelector('.lbl').textContent=(n.room||('·'+last));
 });
}
function bindDrag(el){
 const down=e=>{e.preventDefault();drag=el;el.style.cursor='grabbing'};
 const move=e=>{if(drag!==el)return;const t=e.touches?e.touches[0]:e;const r=wrap.getBoundingClientRect();
  let x=(t.clientX-r.left),y=(t.clientY-r.top);el.style.left=x+'px';el.style.top=y+'px'};
 const up=e=>{if(drag!==el)return;const r=wrap.getBoundingClientRect();const t=(e.changedTouches?e.changedTouches[0]:e);
  let x=(t.clientX-r.left)/W,y=(t.clientY-r.top)/H;save(el.dataset.id,x,y);drag=null;el.style.cursor='grab'};
 el.addEventListener('mousedown',down);el.addEventListener('touchstart',down,{passive:false});
 addEventListener('mousemove',move);addEventListener('touchmove',move,{passive:false});
 addEventListener('mouseup',up);addEventListener('touchend',up);
}
async function tick(){try{const r=await fetch('/nodes',{cache:'no-store'});render(await r.json())}catch(e){}}
tick();setInterval(tick,800);
</script></body></html>"""


LIVE_PAGE = """<!DOCTYPE html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>Homefront Live</title><style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-user-select:none;user-select:none}
body{background:#06070a;color:#e8e8ea;font:14px -apple-system,system-ui,sans-serif;overflow:hidden;
 padding:env(safe-area-inset-top) 0 0}
header{display:flex;justify-content:space-between;align-items:center;padding:12px 16px}
.brand{font-weight:700;letter-spacing:.14em;font-size:12px}.brand b{color:#c8a04a}
.stat{font-size:12px;font-weight:600;letter-spacing:.05em;padding:4px 10px;border-radius:20px;background:#161922;color:#6b7280}
.stat.move{background:#5fb8ff;color:#04121f}
a.tog{color:#5fb8ff;text-decoration:none;font-size:12px}
.room{position:relative;margin:8px 16px;border:2px solid #232734;border-radius:18px;
 background:radial-gradient(circle at 50% 50%,#0d1018,#070809);overflow:hidden}
.sensor{position:absolute;width:16px;height:16px;margin:-8px;border-radius:50%;background:#3a4150;
 box-shadow:0 0 0 4px #3a415033;transition:background .2s,box-shadow .2s;z-index:3}
.sensor.hot{background:#c8a04a;box-shadow:0 0 0 6px #c8a04a44,0 0 24px #c8a04a}
.sensor .tag{position:absolute;top:18px;left:50%;transform:translateX(-50%);font-size:10px;color:#8a9099;white-space:nowrap}
.blob{position:absolute;width:120px;height:120px;margin:-60px;border-radius:50%;z-index:2;
 background:radial-gradient(circle,#5fb8ffcc,#5fb8ff22 60%,transparent 72%);
 filter:blur(4px);opacity:0;transition:left .25s linear,top .25s linear,opacity .3s,transform .3s}
.grid{position:absolute;inset:0;background-image:linear-gradient(#ffffff08 1px,transparent 1px),linear-gradient(90deg,#ffffff08 1px,transparent 1px);background-size:28px 28px;z-index:1}
.foot{position:fixed;bottom:0;left:0;right:0;padding:14px 16px calc(14px + env(safe-area-inset-bottom));
 text-align:center;color:#5a5e66;font-size:11px;line-height:1.5}
.big{font-size:15px;font-weight:600;color:#9fb4c9;margin-bottom:3px}
</style></head><body>
<header><div class=brand>HOME<b>FRONT</b> · LIVE</div>
 <span class=stat id=stat>…</span><a class=tog href="/map">map →</a></header>
<div class=room id=room>
 <div class=grid></div>
 <div class=blob id=blob></div>
</div>
<div class=foot><div class=big id=big>watching the room…</div>
 through-wall motion · 2 corner sensors · coarse position (left↔right)</div>
<script>
const room=document.getElementById('room'),blob=document.getElementById('blob');
function fit(){const w=innerWidth-32, h=innerHeight-150; room.style.width=w+'px'; room.style.height=h+'px';}
addEventListener('resize',fit);fit();
let sensors={};
function place(){ // create sensor dots from positions
 room.querySelectorAll('.sensor').forEach(e=>e.remove());
 for(const id in sensors){const s=sensors[id];
  const el=document.createElement('div');el.className='sensor';el.id='s_'+id;
  el.style.left=(s.x*100)+'%';el.style.top=(s.y*100)+'%';
  el.innerHTML='<div class=tag>'+(s.room||id.split('.').pop())+'</div>';
  room.appendChild(el);}
}
async function tick(){
 try{
  const d=await (await fetch('/nodes',{cache:'no-store'})).json();
  const ns=d.nodes.filter(n=>n.online);
  // build/refresh sensor map
  let changed=false;
  const cur={};
  ns.forEach((n,i)=>{const p=n.pos||{x:0.2+0.6*i,y:0.5};cur[n.node_id]={x:p.x,y:p.y,room:n.room};});
  if(Object.keys(cur).join()!=Object.keys(sensors).join()){sensors=cur;place();}
  else sensors=cur;
  // GATED motion only: drive everything off moving_now (adaptive-threshold +
  // debounced — proven 0 false positives on an empty room). Raw amplified motion
  // false-triggered on baseline noise, so it is NOT used as the gate.
  let wx=0,wsum=0,anyMove=false;
  ns.forEach(n=>{
   const moving = !!n.moving_now;                 // the trustworthy gate
   const el=document.getElementById('s_'+n.node_id);
   if(el) el.classList.toggle('hot', moving);
   if(moving){const p=n.pos||{x:0.5,y:0.5}; const w=Math.max(0.2,n.motion||0.2); wx+=p.x*w; wsum+=w; anyMove=true;}
  });
  const stat=document.getElementById('stat'), big=document.getElementById('big');
  if(anyMove && wsum>0){
   const px=wx/wsum;
   blob.style.left=(px*100)+'%'; blob.style.top='50%';
   blob.style.opacity=0.9; blob.style.transform='scale(1)';
   stat.textContent='MOVEMENT'; stat.classList.add('move');
   big.textContent = px<0.4?'movement — LEFT side':(px>0.6?'movement — RIGHT side':'movement — center');
  } else {
   blob.style.opacity=0; stat.textContent=ns.length+' sensors · clear'; stat.classList.remove('move');
   big.textContent='room clear';
  }
 }catch(e){}
}
tick();setInterval(tick,400);
</script></body></html>"""


def make_handler(sentinel):
    from http.server import BaseHTTPRequestHandler

    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _send(self, code, payload, ctype="application/json"):
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # No Access-Control-Allow-Origin: the clients are the native SwiftUI app
            # (URLSession, same host, no CORS) and the same-origin dashboard. ACAO:*
            # let any web page a buyer visited READ /nodes, /alerts (fall history) and
            # /raw (raw CSI) cross-origin — presence/vitals/incident exfiltration.
            # Omitting it makes the browser discard those cross-origin responses.
            try:
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def _mutator_status(self, result):
            return 404 if isinstance(result, dict) and result.get("error") == "unknown node" else 200

        def _client_is_loopback(self):
            # The REAL peer address, which a client CANNOT forge — unlike the Host
            # header, which a LAN peer could set to 127.0.0.1 against a 0.0.0.0-bound
            # port. This is the trust boundary between the same-machine app/dashboard
            # and any remote (LAN / operator tunnel) caller.
            peer = self.client_address[0] if getattr(self, "client_address", None) else ""
            return peer in ("127.0.0.1", "::1", "::ffff:127.0.0.1") or peer.startswith("127.")

        def _token_present_and_valid(self):
            # Tri-state: None = no HOMEFRONT_TOKEN configured; True = a configured
            # token was presented (header or ?token=); False = configured but the
            # request did not present it.
            tok = os.environ.get("HOMEFRONT_TOKEN", "").strip()
            if not tok:
                return None
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            return (self.headers.get("X-Homefront-Token") == tok) or (q.get("token", [""])[0] == tok)

        def _csrf_safe(self):
            # Block drive-by CSRF from a LOCAL browser to this loopback port: a
            # cross-origin page can still SEND a simple POST (no CORS preflight) to
            # /acknowledge and silence a live alarm. The same-origin dashboard sends
            # Origin whose host == our Host; a cross-origin attacker sends a different
            # Origin. No Origin => a non-browser client (native app / curl) — allowed.
            origin = self.headers.get("Origin")
            if not origin:
                return True
            from urllib.parse import urlparse
            return urlparse(origin).netloc == (self.headers.get("Host") or "").strip()

        def _authz(self, mutating):
            """Central authorization. Returns (allowed, http_code, message).

            Loopback peers (native app + same-machine dashboard) are trusted for
            reads, and for mutations too UNLESS a token is configured. Any real
            remote peer (LAN / operator tunnel) MUST present a valid HOMEFRONT_TOKEN.
            Fail-closed: with no token configured, remote access is refused — never
            silently open. This closes the unauthenticated remote read of vitals /
            fall-history and the remote POST /acknowledge that could silence a live
            fall alarm.
            """
            loopback = self._client_is_loopback()
            tok = self._token_present_and_valid()   # None | True | False
            if mutating:
                if tok is False:
                    return (False, 401, "auth required (HOMEFRONT_TOKEN)")
                if not (tok is True or loopback):
                    return (False, 403, "forbidden (remote requires HOMEFRONT_TOKEN)")
                if not self._csrf_safe():
                    return (False, 403, "cross-origin POST refused")
                return (True, 200, "")
            # Reads: loopback is always allowed (the native app must keep reading
            # /nodes over loopback even after the operator sets a tunnel token);
            # a remote read requires a valid token.
            if loopback or tok is True:
                return (True, 200, "")
            return (False, 403, "forbidden (remote requires HOMEFRONT_TOKEN)")

        def do_GET(self):
            ok, code, msg = self._authz(mutating=False)
            if not ok:
                self._send(code, {"ok": False, "error": msg}); return
            if self.path.startswith("/nodes"):
                self._send(200, sentinel.snapshot())
            elif self.path.startswith("/health"):
                snap = sentinel.snapshot()
                self._send(200, {"ok": True, "uptime_s": snap["uptime_s"],
                                 "nodes": snap["node_count"], "online": snap["online_count"]})
            elif self.path.startswith("/map"):
                self._send(200, MAP_PAGE.encode(), ctype="text/html; charset=utf-8")
            elif self.path.startswith("/live"):
                self._send(200, LIVE_PAGE.encode(), ctype="text/html; charset=utf-8")
            elif self.path.startswith("/raw"):
                from urllib.parse import urlparse, parse_qs
                q = parse_qs(urlparse(self.path).query)
                nid = q.get("node", [None])[0]
                secs = float(q.get("secs", ["60"])[0])
                self._send(200, sentinel.raw_window(nid, secs))
            elif self.path.startswith("/alerts"):
                # Recent alert history for the app (newest incident first). AGE-FILTERED
                # (default 24h) + INCIDENT-DEDUPED so a days-old FALL is never replayed as
                # live and a re-notify storm collapses to one entry (HF-2). ?hours= overrides.
                from urllib.parse import urlparse, parse_qs
                q = parse_qs(urlparse(self.path).query)
                try:
                    hours = float(q.get("hours", [""])[0])
                except (TypeError, ValueError):
                    hours = ALERTS_MAX_AGE_S / 3600.0
                path = os.path.join(DATA_DIR, "alerts.log")
                self._send(200, {"alerts": load_alerts(path, max_age_s=max(0.0, hours) * 3600.0)})
            elif self.path.startswith("/floorplans/"):
                # CONTAINMENT: the request path is attacker-controlled (this server is
                # reachable by anything on the WiFi). basename() alone still lets a
                # symlink inside the dir point anywhere, so resolve the candidate and
                # require it to stay UNDER FLOORPLAN_DIR before it is opened.
                name = os.path.basename(self.path.split("?")[0])
                root = Path(FLOORPLAN_DIR).resolve()
                try:
                    fp = (root / name).resolve()
                    fp.relative_to(root)
                except (ValueError, OSError):
                    fp = None
                if fp is not None and fp.is_file():
                    with open(fp, "rb") as f:
                        self._send(200, f.read(), ctype="image/jpeg")
                else:
                    self._send(404, b"no floorplan", ctype="text/plain")
            else:
                self._send(200, PHONE_PAGE.encode(), ctype="text/html; charset=utf-8")

        def do_POST(self):
            ok, code, msg = self._authz(mutating=True)
            if not ok:
                self._send(code, {"ok": False, "error": msg}); return
            if self.path.startswith("/assign"):
                try:
                    n = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(n).decode() or "{}")
                    res = sentinel.assign_room(body.get("node_id"), body.get("room"))
                    self._send(self._mutator_status(res), res)
                except Exception as e:
                    self._send(400, {"ok": False, "error": str(e)})
            elif self.path.startswith("/recalibrate"):
                try:
                    n = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(n).decode() or "{}") if n else {}
                    res = sentinel.recalibrate(body.get("node_id"))
                    self._send(self._mutator_status(res), res)
                except Exception as e:
                    self._send(400, {"ok": False, "error": str(e)})
            elif self.path.startswith("/acknowledge"):
                try:
                    n = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(n).decode() or "{}") if n else {}
                    res = sentinel.acknowledge(body.get("node_id"))
                    self._send(self._mutator_status(res), res)
                except Exception as e:
                    self._send(400, {"ok": False, "error": str(e)})
            elif self.path.startswith("/position"):
                try:
                    n = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(n).decode() or "{}")
                    res = sentinel.set_position(body["node_id"], body["x"], body["y"])
                    self._send(self._mutator_status(res), res)
                except Exception as e:
                    self._send(400, {"ok": False, "error": str(e)})
            elif self.path.startswith("/roomshape"):
                try:
                    n = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(n).decode() or "{}")
                    self._send(200, sentinel.set_roomshape(body.get("room"), body.get("points", [])))
                except Exception as e:
                    self._send(400, {"ok": False, "error": str(e)})
            else:
                self._send(404, {"ok": False})

    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csi-port", type=int, default=5005)
    # Loopback by default: the native app + same-machine dashboard are the only
    # first-party clients. Exposing the hub on the LAN (0.0.0.0) is an explicit,
    # opt-in choice (install_hub.sh, for the operator tunnel) — and when it is made
    # WITHOUT a HOMEFRONT_TOKEN, all remote callers are refused (see the warning below).
    ap.add_argument("--http-host", default="127.0.0.1")
    ap.add_argument("--http-port", type=int, default=8780)
    ap.add_argument("--fs", type=float, default=30.0, help="approx CSI frame rate per node")
    ap.add_argument("--feed-port", type=int, default=5006, help="port the engine blasts CSI-keepalive packets at")
    ap.add_argument("--feed-hz", type=int, default=60, help="per-node RX feed rate that keeps CSI flowing")
    args = ap.parse_args()

    sentinel = Sentinel(csi_port=args.csi_port, fs=args.fs,
                        feed_port=args.feed_port, feed_hz=args.feed_hz)
    sentinel.start()
    httpd = VigilHTTPServer((args.http_host, args.http_port), make_handler(sentinel))
    ip = socket.gethostbyname(socket.gethostname())
    _bound_remote = args.http_host not in ("127.0.0.1", "localhost", "::1")
    _has_token = bool(os.environ.get("HOMEFRONT_TOKEN", "").strip())
    print(f"Homefront Sentinel up.")
    print(f"  CSI in : udp/{args.csi_port}  (nodes auto-register by sender)")
    if _bound_remote:
        print(f"  Phone  : http://{ip}:{args.http_port}/   (open on a phone on this WiFi)")
        if not _has_token:
            # Fail-closed and SAY SO: bound to the LAN with no token means every
            # remote caller (LAN peer + operator tunnel) is refused by _authz. The
            # operator must set HOMEFRONT_TOKEN for the tunnel/phone to work at all —
            # which is the point: no token, no remote alarm-silencing.
            print("  WARN   : bound to a non-loopback interface with NO HOMEFRONT_TOKEN set —")
            print("           remote reads/mutations are REFUSED (fail-closed). Set")
            print("           HOMEFRONT_TOKEN to enable the phone/tunnel, then use ?token=…")
    else:
        print(f"  Local  : http://127.0.0.1:{args.http_port}/   (loopback only; set --http-host + HOMEFRONT_TOKEN to expose)")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
