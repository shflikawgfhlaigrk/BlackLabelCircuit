"""Demo Mode — the live/replay product picture (Track E1).

Operating envelope: aggregates whatever the rest of the system publishes
(bus topics per CONTRACTS.md §4) plus caller-pushed motion/vitals samples
into a small JSON snapshot at ~10 Hz, and serves it over stdlib HTTP
(GET /, /snapshot, /events SSE) to a single self-contained viewer
(`vigil/static/demo.html`). Two sources drive it:

- live: the running pipeline pushes via `push_motion` / `push_vitals_wave`
  and publishes bus events;
- replay: `ReplaySource` walks a `.vigil` Session deterministically,
  computing motion energy through the real CleaningStage/SpectralStage when
  Track B is present, else a built-in scipy fallback (bandpass 0.5–10 Hz +
  moving RMS) so replay works standalone today.

Nothing here measures anything — it displays what the pipeline says. All
timing in snapshots is *fed* time (session or caller clock), never wall
clock, so tests and replay are deterministic. No third-party web deps.
"""

from __future__ import annotations

import argparse
import json
import math
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import numpy as np

from .bus import EventBus
from .config import VigilConfig
from .session import Session

FS = 100.0
SNAPSHOT_HZ = 10.0
TRAIL_S = 5.0          # motion trail span
TRAIL_POINTS = 50      # 5 s at 10 Hz
WAVE_S = 30.0          # vitals waveform span
WAVE_POINTS = 60       # 30 s downsampled to 60 points
FALL_FLASH_S = 5.0     # red flash active window after fall.confirmed
FALL_FLASH_KEEP_S = 30.0  # keep the (inactive) record this long, then null
HEARTBEAT_S = 5.0      # SSE comment heartbeat

STATIC_DIR = Path(__file__).resolve().parent / "static"


# ---------------------------------------------------------------------------
# Motion-energy computation (real stages when available, scipy fallback)
# ---------------------------------------------------------------------------

def _fallback_motion_energy(amps: np.ndarray, fs: float = FS) -> np.ndarray:
    """Built-in motion-energy estimate: per-subcarrier mean removal,
    band-pass 0.5–10 Hz, RMS across subcarriers, then a 0.3 s moving RMS."""
    from scipy import signal

    x = np.asarray(amps, dtype=np.float64)
    if x.ndim != 2 or x.shape[0] < 8:
        return np.zeros(x.shape[0] if x.ndim else 0, dtype=np.float32)
    x = x - x.mean(axis=0, keepdims=True)
    hi = min(10.0, 0.45 * fs)
    sos = signal.butter(4, [0.5, hi], btype="bandpass", fs=fs, output="sos")
    y = signal.sosfiltfilt(sos, x, axis=0)
    inst = (y ** 2).mean(axis=1)  # instantaneous power across subcarriers
    win = max(1, int(0.3 * fs))
    kernel = np.ones(win) / win
    e = np.sqrt(np.convolve(inst, kernel, mode="same"))
    return e.astype(np.float32)


def motion_energy_series(amps: np.ndarray, fs: float = FS) -> np.ndarray:
    """Motion energy [t] for an amplitude window [t,52].

    Prefers the real Track-B stages (CleaningStage + SpectralStage per
    CONTRACTS.md §6), lazily imported; falls back to the built-in scipy
    estimator when B isn't available or errors."""
    try:
        from .cleaning import CleaningStage  # lazy — Track B
        from .spectral import SpectralStage
    except ImportError:
        return _fallback_motion_energy(amps, fs)
    try:
        clean = CleaningStage(fs=fs).process(np.asarray(amps, np.float32))
        spectral = SpectralStage(fs=fs)
        calib_n = min(amps.shape[0], int(5 * fs))
        spectral.fit(np.asarray(amps[:calib_n], np.float32))
        out = spectral.transform(clean.motion)
        e = np.asarray(out.motion_energy, dtype=np.float32).ravel()
        if e.shape[0] != amps.shape[0] and e.shape[0] > 1:
            # resample onto the per-frame grid if the stage returns hop-rate
            src = np.linspace(0.0, amps.shape[0] - 1, e.shape[0])
            e = np.interp(np.arange(amps.shape[0]), src, e).astype(np.float32)
        return e
    except Exception:
        return _fallback_motion_energy(amps, fs)


# ---------------------------------------------------------------------------
# DemoFeed — the aggregated product picture
# ---------------------------------------------------------------------------

class DemoFeed:
    """Aggregates bus events + pushed samples into a JSON-able snapshot.

    Snapshot shape (extra keys are allowed; these are guaranteed):
    {t, rooms: {room: {rect, nodes: [{node_id, pos, rssi, rate}],
     motion_energy, motion_trail[50], fall_flash|null,
     vitals: {breathing: {text, show, quality, waveform[60]}, hr: {...}}}}}
    """

    def __init__(self, config: VigilConfig, bus: EventBus) -> None:
        self.config = config
        self.bus = bus
        self._lock = threading.RLock()
        self._t = 0.0
        self._rooms: dict[str, dict] = {}
        for room, ids in config.rooms.items():
            st = self._ensure_room(room)
            for nid in ids:
                self._ensure_node(st, nid)
        for n in config.nodes:
            if n.room:
                self._ensure_node(self._ensure_room(n.room), n.node_id)
        bus.subscribe("gate1.candidate", self._on_event)
        bus.subscribe("fall.*", self._on_event)
        bus.subscribe("vitals.*", self._on_event)
        bus.subscribe("node.health", self._on_event)

    # -- state helpers ------------------------------------------------------

    def _ensure_room(self, room: str) -> dict:
        if room not in self._rooms:
            self._rooms[room] = {
                "nodes": {},                 # node_id -> {"rssi","rate"}
                "energy": 0.0,
                "trail": deque(maxlen=400),  # (t, energy)
                "flash": None,               # {"t","confidence","downgraded"}
                "last_candidate_t": None,
                "vitals": {
                    kind: {"show": False, "text": "listening…", "quality": 0.0,
                           "wave": deque(maxlen=6000)}
                    for kind in ("breathing", "hr")
                },
            }
        return self._rooms[room]

    def _ensure_node(self, room_state: dict, node_id: int) -> dict:
        return room_state["nodes"].setdefault(
            int(node_id), {"rssi": -127, "rate": 0.0})

    def _room_of(self, node_id: int) -> str:
        room = self.config.room_of(node_id)
        if room:
            return room
        for name, st in self._rooms.items():
            if node_id in st["nodes"]:
                return name
        return "room"

    def _bump_t(self, t: Any) -> None:
        try:
            self._t = max(self._t, float(t))
        except (TypeError, ValueError):
            pass

    # -- inputs --------------------------------------------------------------

    def push_motion(self, room: str, t: float, energy: float) -> None:
        with self._lock:
            st = self._ensure_room(room)
            self._bump_t(t)
            st["energy"] = float(energy)
            st["trail"].append((float(t), float(energy)))

    def push_vitals_wave(self, room: str, samples, t0: float | None = None,
                         fs: float = FS, kind: str = "breathing") -> None:
        """Append vitals-band waveform samples for a room (default breathing).
        Samples are timestamped from t0 (defaults to the feed clock) at fs."""
        samples = np.asarray(samples, dtype=np.float64).ravel()
        with self._lock:
            st = self._ensure_room(room)
            start = self._t if t0 is None else float(t0)
            wave = st["vitals"][kind]["wave"]
            for i, s in enumerate(samples):
                wave.append((start + i / fs, float(s)))
            self._bump_t(start + samples.size / fs)

    def _on_event(self, topic: str, payload: dict) -> None:
        with self._lock:
            t = payload.get("t")
            if topic == "gate1.candidate":
                nid = payload.get("node_id")
                room = self._room_of(int(nid)) if nid is not None else "room"
                self._ensure_room(room)["last_candidate_t"] = t
                self._bump_t(t)
            elif topic == "fall.confirmed":
                st = self._ensure_room(payload.get("room", "room"))
                st["flash"] = {"t": float(t if t is not None else self._t),
                               "confidence": float(payload.get("confidence", 0.0)),
                               "downgraded": False}
                self._bump_t(t)
            elif topic == "fall.downgraded":
                st = self._ensure_room(payload.get("room", "room"))
                if st["flash"] is not None:
                    st["flash"]["downgraded"] = True
                self._bump_t(t)
            elif topic in ("vitals.breathing", "vitals.hr"):
                kind = topic.split(".", 1)[1]
                st = self._ensure_room(payload.get("room", "room"))
                disp = self._display(kind, float(payload.get("bpm", 0.0)),
                                     float(payload.get("confidence", 0.0)))
                st["vitals"][kind].update(disp)
                self._bump_t(t)
            elif topic == "node.health":
                nid = int(payload.get("node_id", -1))
                room = self._room_of(nid)
                node = self._ensure_node(self._ensure_room(room), nid)
                if "rssi" in payload:
                    node["rssi"] = int(payload["rssi"])
                if "rate_hz" in payload:
                    node["rate"] = float(payload["rate_hz"])

    def _display(self, kind: str, bpm: float, confidence: float) -> dict:
        """DisplayState per D4 (lazy VitalsGate; threshold fallback today)."""
        try:
            from .vitals.gating import VitalsEstimate, VitalsGate  # lazy — Track D
            gate = VitalsGate(self.config.thresholds)
            ds = gate.display(kind, VitalsEstimate(bpm=bpm, confidence=confidence,
                                                   detail={}))
            return {"show": bool(ds.show), "text": str(ds.text),
                    "quality": float(ds.quality)}
        except Exception:
            thr = (self.config.thresholds.breathing_min_confidence
                   if kind == "breathing"
                   else self.config.thresholds.hr_min_confidence)
            show = confidence >= thr
            text = f"{bpm:.0f} bpm" if show else "listening…"
            return {"show": bool(show), "text": text,
                    "quality": float(confidence)}

    # -- snapshot ------------------------------------------------------------

    def snapshot(self) -> dict:
        with self._lock:
            t = self._t
            layout = _compute_layout(sorted(self._rooms))
            rooms_out: dict[str, dict] = {}
            for room in sorted(self._rooms):
                st = self._rooms[room]
                rect = layout[room]
                node_ids = sorted(st["nodes"])
                nodes_out = []
                for j, nid in enumerate(node_ids):
                    nx = rect[0] + rect[2] * (j + 1) / (len(node_ids) + 1)
                    ny = rect[1] + rect[3] * 0.18
                    info = st["nodes"][nid]
                    nodes_out.append({"node_id": nid,
                                      "pos": [round(nx, 2), round(ny, 2)],
                                      "rssi": info["rssi"],
                                      "rate": info["rate"]})
                rooms_out[room] = {
                    "rect": list(rect),
                    "nodes": nodes_out,
                    "motion_energy": st["energy"],
                    "motion_trail": _resample_series(st["trail"], t, TRAIL_S,
                                                     TRAIL_POINTS),
                    "fall_flash": self._flash_state(st, t),
                    "last_candidate_t": st["last_candidate_t"],
                    "vitals": {
                        kind: {
                            "text": v["text"], "show": v["show"],
                            "quality": v["quality"],
                            "waveform": _resample_series(v["wave"], t, WAVE_S,
                                                         WAVE_POINTS),
                        }
                        for kind, v in st["vitals"].items()
                    },
                }
            return {"t": t, "rooms": rooms_out}

    @staticmethod
    def _flash_state(st: dict, t: float) -> dict | None:
        flash = st["flash"]
        if flash is None:
            return None
        age = t - flash["t"]
        if age > FALL_FLASH_KEEP_S:
            st["flash"] = None
            return None
        active = (not flash["downgraded"]) and 0.0 <= age < FALL_FLASH_S
        return {"active": bool(active), "t": flash["t"],
                "confidence": flash["confidence"]}


def _resample_series(points, t_now: float, span_s: float, n: int) -> list[float]:
    """Resample (t, value) points from the last span_s onto a fixed n grid."""
    pts = [(pt, pv) for pt, pv in points if pt >= t_now - span_s]
    grid = np.linspace(t_now - span_s, t_now, n)
    if not pts:
        return [0.0] * n
    ts = np.array([p[0] for p in pts])
    vs = np.array([p[1] for p in pts])
    return [float(x) for x in np.interp(grid, ts, vs, left=0.0, right=vs[-1])]


def _compute_layout(rooms: list[str]) -> dict[str, tuple[float, float, float, float]]:
    """Deterministic floor-plan layout: rooms on a grid in 0..100 units."""
    if not rooms:
        return {}
    cols = math.ceil(math.sqrt(len(rooms)))
    rows = math.ceil(len(rooms) / cols)
    margin = 4.0
    w = (100.0 - margin * (cols + 1)) / cols
    h = (100.0 - margin * (rows + 1)) / rows
    out = {}
    for i, room in enumerate(rooms):
        r, c = divmod(i, cols)
        out[room] = (round(margin + c * (w + margin), 2),
                     round(margin + r * (h + margin), 2),
                     round(w, 2), round(h, 2))
    return out


# ---------------------------------------------------------------------------
# ReplaySource — drive the feed (and a pipeline stub) from a .vigil session
# ---------------------------------------------------------------------------

class ReplaySource:
    """Walks a Session at frame rate and drives a DemoFeed (+ optional
    pipeline object with a `.push(node_id, t, energy)` method).

    realtime=False (default) runs as fast as possible and is deterministic;
    realtime=True paces snapshots by session time / speed for a live-looking
    demo. Motion energy comes from `motion_energy_series` (real B stages
    when importable, scipy fallback otherwise)."""

    def __init__(self, session: Session, feed: DemoFeed, speed: float = 1.0,
                 realtime: bool = False, pipeline: Any | None = None) -> None:
        self.session = session
        self.feed = feed
        self.speed = float(speed)
        self.realtime = bool(realtime)
        self.pipeline = pipeline

    def _room_of(self, nid: int) -> str:
        room = self.feed.config.room_of(nid)
        if room:
            return room
        for n in self.session.meta.get("nodes", []):
            if n.get("node_id") == nid and n.get("room"):
                return n["room"]
        return "room"

    def run(self) -> None:
        s = self.session
        fs = s.fs
        energies = {nid: motion_energy_series(s.amps[nid], fs)
                    for nid in s.node_ids}
        waves = {nid: self._vitals_wave(s.amps[nid], fs) for nid in s.node_ids}
        rooms: dict[str, list[int]] = {}
        for nid in s.node_ids:
            rooms.setdefault(self._room_of(nid), []).append(nid)
        bed = {room: self.feed.config.vitals_zone.get(room, ids[0])
               for room, ids in rooms.items()}
        step = max(1, int(round(fs / SNAPSHOT_HZ)))
        n = max((a.shape[0] for a in s.amps.values()), default=0)
        for i in range(0, n, step):
            t = i / fs
            for room, ids in rooms.items():
                vals = [float(energies[nid][i]) for nid in ids
                        if i < energies[nid].shape[0]]
                if vals:
                    self.feed.push_motion(room, t, max(vals))
                bnid = bed[room]
                if bnid in waves and i < waves[bnid].shape[0]:
                    chunk = waves[bnid][i:i + step]
                    self.feed.push_vitals_wave(room, chunk, t0=t, fs=fs)
            if self.pipeline is not None and hasattr(self.pipeline, "push"):
                for nid in s.node_ids:
                    if i < energies[nid].shape[0]:
                        self.pipeline.push(nid, t, float(energies[nid][i]))
            if int(t) != int(t - step / fs):  # once per session-second
                for nid in s.node_ids:
                    rssi = (int(s.rssi[nid][min(i, s.rssi[nid].shape[0] - 1)])
                            if nid in s.rssi and s.rssi[nid].size else -60)
                    self.feed.bus.publish("node.health",
                                          {"node_id": nid, "rate_hz": fs,
                                           "rssi": rssi, "loss_pct": 0.0})
            if self.realtime and self.speed > 0:
                time.sleep(step / fs / self.speed)

    @staticmethod
    def _vitals_wave(amps: np.ndarray, fs: float) -> np.ndarray:
        """Respiratory-band waveform for display: subcarrier mean, 0.08–0.8 Hz."""
        from scipy import signal
        x = np.asarray(amps, np.float64).mean(axis=1)
        if x.shape[0] < 32:
            return np.zeros_like(x, dtype=np.float32)
        x = x - x.mean()
        sos = signal.butter(2, [0.08, 0.8], btype="bandpass", fs=fs,
                            output="sos")
        return signal.sosfiltfilt(sos, x).astype(np.float32)


# ---------------------------------------------------------------------------
# DemoServer — stdlib HTTP + SSE
# ---------------------------------------------------------------------------

class _DemoHandler(BaseHTTPRequestHandler):
    server_version = "VigilDemo/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep tests/console quiet
        pass

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (stdlib API)
        path = self.path.split("?", 1)[0]
        try:
            if path in ("/", "/index.html"):
                html = self.server.html_path.read_bytes()
                self._send(200, "text/html; charset=utf-8", html)
            elif path == "/snapshot":
                body = json.dumps(self.server.feed.snapshot()).encode()
                self._send(200, "application/json", body)
            elif path == "/events":
                self._sse()
            else:
                self._send(404, "text/plain", b"not found")
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            pass  # client went away — never take the server down

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        last_beat = time.monotonic()
        while not self.server.stopping:
            payload = json.dumps(self.server.feed.snapshot())
            self.wfile.write(f"data: {payload}\n\n".encode())
            if time.monotonic() - last_beat > HEARTBEAT_S:
                self.wfile.write(b": heartbeat\n\n")
                last_beat = time.monotonic()
            self.wfile.flush()
            time.sleep(1.0 / SNAPSHOT_HZ)


class DemoServer:
    """Threaded stdlib HTTP server for the demo viewer.

    GET /         -> vigil/static/demo.html (self-contained)
    GET /snapshot -> one JSON snapshot
    GET /events   -> SSE stream of snapshots at ~10 Hz with heartbeats
    """

    def __init__(self, feed: DemoFeed, port: int = 8899,
                 host: str = "0.0.0.0",
                 html_path: str | Path | None = None) -> None:
        self.feed = feed
        self._httpd = ThreadingHTTPServer((host, port), _DemoHandler)
        self._httpd.daemon_threads = True
        self._httpd.feed = feed
        self._httpd.stopping = False
        self._httpd.html_path = Path(html_path) if html_path else (
            STATIC_DIR / "demo.html")
        self.port = self._httpd.server_address[1]
        self._thread: threading.Thread | None = None

    def start(self) -> "DemoServer":
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        name="vigil-demo-http", daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._httpd.stopping = True
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)


# ---------------------------------------------------------------------------
# CLI: python3 -m vigil.demo --replay session.vigil [--port 8899] [--config p]
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m vigil.demo",
                                 description="Vigil Demo Mode server")
    ap.add_argument("--replay", metavar="SESSION.vigil",
                    help="replay a recorded session in a loop")
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--config", metavar="PATH", default=None)
    ap.add_argument("--speed", type=float, default=1.0)
    args = ap.parse_args(argv)

    config = VigilConfig.load(args.config) if args.config else VigilConfig()
    bus = EventBus()
    feed = DemoFeed(config, bus)
    server = DemoServer(feed, port=args.port).start()
    print(f"vigil demo: http://127.0.0.1:{server.port}/  "
          f"(snapshot: /snapshot, stream: /events)")
    try:
        if args.replay:
            session = Session.load(args.replay)
            print(f"replaying {args.replay} "
                  f"({session.duration_s:.0f} s, nodes {session.node_ids}) — Ctrl-C to stop")
            while True:
                ReplaySource(session, feed, speed=args.speed,
                             realtime=True).run()
        else:
            print("live mode: waiting for pushed data — Ctrl-C to stop")
            while True:
                time.sleep(1.0)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
