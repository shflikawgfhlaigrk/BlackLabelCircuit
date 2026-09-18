"""Live Wallpaper feed — smoothed 10 Hz JSON snapshots for a visual client.

Operating envelope: display-only, headless-testable. Consumes the same
per-node feature ticks as `FieldMapping` (or wraps an existing snapshot
source such as `vigil.demo.DemoFeed`) and produces an eased visual state:
attack/release envelope followers make the picture *breathe* instead of
flicker — a step in motion energy ramps over ~attack_s and decays over
~release_s, never jumping instantaneously. Serving reuses the stdlib
HTTP+SSE pattern from `vigil.demo` (GET /field -> SSE stream,
GET /snapshot -> one JSON snapshot). Aesthetic quality on an actual wall
display is GATED on the Live Wallpaper client; what is MEASURED here is the
schema and the envelope dynamics.

JSON snapshot schema (the contract for the Live Wallpaper client — a
self-contained canvas client can consume this directly):

    {
      "t": <float s, fed time — never wall clock>,
      "intensity": <float 0..1, eased overall motion level>,
      "hue": <float degrees 0..360; calm blue ~230 sweeping to hot
              ~0 as the eased spectral centroid rises>,
      "per_node": [
        {"node_id": <int>, "energy": <float 0..1 eased level>,
         "xy": [<float 0..1>, <float 0..1>]}   # deterministic layout
      ],
      "palette_state": {"hue": <deg>, "saturation": <0..1>,
                        "lightness": <0..1>}
    }
"""

from __future__ import annotations

import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Mapping

from .mapping import TICK_HZ, FieldMapping

HEARTBEAT_S = 5.0

HUE_CALM = 230.0   # deep blue at centroid 0
HUE_HOT = 0.0      # red at full-brightness centroid


class EnvelopeFollower:
    """First-order attack/release envelope: fast up, slow down (or vice
    versa). Given tick period dt, y += (x - y) * (1 - exp(-dt/tau)) with tau
    chosen per direction. Never reaches the target in one tick unless
    tau -> 0, so a step input eases instead of jumping."""

    def __init__(self, attack_s: float = 0.15, release_s: float = 0.8,
                 tick_hz: float = TICK_HZ, y0: float = 0.0) -> None:
        dt = 1.0 / float(tick_hz)
        self._ka = 1.0 - math.exp(-dt / max(attack_s, 1e-6))
        self._kr = 1.0 - math.exp(-dt / max(release_s, 1e-6))
        self.y = float(y0)

    def push(self, x: float) -> float:
        k = self._ka if x > self.y else self._kr
        self.y += (float(x) - self.y) * k
        return self.y


class WallpaperFeed:
    """Eased visual state for the Live Wallpaper client.

    `source` is either a `FieldMapping` (features are pushed per tick via
    `push(t, node_inputs)`) or any object with a DemoFeed-style
    `.snapshot()` (pull mode via `refresh()`; energy only — no centroid, hue
    stays calm). Default: a fresh FieldMapping."""

    def __init__(self, source: Any | None = None,
                 tick_hz: float = TICK_HZ) -> None:
        if source is None:
            source = FieldMapping()
        self.tick_hz = float(tick_hz)
        self.mapping: FieldMapping | None = None
        self._wrapped: Any | None = None
        if isinstance(source, FieldMapping) or (
                hasattr(source, "level") and hasattr(source, "tick")):
            self.mapping = source
        elif hasattr(source, "snapshot"):
            self._wrapped = source
            self.mapping = FieldMapping()   # for level normalization only
        else:
            raise TypeError("source must be a FieldMapping or expose .snapshot()")
        self._lock = threading.RLock()
        self._t = 0.0
        self._intensity = EnvelopeFollower(0.15, 0.8, self.tick_hz)
        self._hue_drive = EnvelopeFollower(0.5, 1.5, self.tick_hz)
        self._node_env: dict[int, EnvelopeFollower] = {}
        self._node_order: list[int] = []

    # -- inputs ---------------------------------------------------------------

    def push(self, t: float, node_inputs: Mapping[int, Mapping[str, Any]]
             ) -> dict:
        """Feed one 10 Hz tick of per-node features; returns the snapshot."""
        m = self.mapping
        with self._lock:
            self._t = float(t)
            levels = []
            cw_num = cw_den = 0.0
            seen = set()
            for nid in sorted(int(n) for n in node_inputs):
                feat = node_inputs[nid]
                lvl = m.level(float(feat.get("motion_energy", 0.0)))
                cn = m.centroid_norm(float(feat.get("spectral_centroid", 0.0)))
                env = self._node_env.get(nid)
                if env is None:
                    env = self._node_env[nid] = EnvelopeFollower(
                        0.1, 0.6, self.tick_hz)
                    self._node_order.append(nid)
                env.push(lvl)
                levels.append(lvl)
                cw_num += lvl * cn
                cw_den += lvl
                seen.add(nid)
            for nid, env in self._node_env.items():   # unheard nodes decay
                if nid not in seen:
                    env.push(0.0)
            raw_intensity = sum(levels) / len(levels) if levels else 0.0
            self._intensity.push(raw_intensity)
            self._hue_drive.push(cw_num / cw_den if cw_den > 1e-12 else 0.0)
            return self._snapshot_locked()

    def refresh(self) -> dict:
        """Pull mode: derive a tick from a wrapped DemoFeed-style snapshot
        (room motion_energy per node; centroid unavailable -> calm hue)."""
        if self._wrapped is None:
            with self._lock:
                return self._snapshot_locked()
        snap = self._wrapped.snapshot()
        nodes: dict[int, dict] = {}
        for room in snap.get("rooms", {}).values():
            for nd in room.get("nodes", []):
                nodes[int(nd["node_id"])] = {
                    "motion_energy": float(room.get("motion_energy", 0.0)),
                    "spectral_centroid": 0.0, "band_energies": []}
        return self.push(float(snap.get("t", self._t)), nodes)

    # -- snapshot ---------------------------------------------------------------

    def snapshot(self) -> dict:
        with self._lock:
            return self._snapshot_locked()

    def _snapshot_locked(self) -> dict:
        intensity = min(max(self._intensity.y, 0.0), 1.0)
        hue_norm = min(max(self._hue_drive.y, 0.0), 1.0)
        hue = HUE_CALM + (HUE_HOT - HUE_CALM) * hue_norm
        n = len(self._node_order)
        per_node = []
        for j, nid in enumerate(self._node_order):
            x = (j + 1) / (n + 1)
            per_node.append({
                "node_id": nid,
                "energy": round(min(max(self._node_env[nid].y, 0.0), 1.0), 6),
                "xy": [round(x, 4), 0.5],
            })
        return {
            "t": round(self._t, 6),
            "intensity": round(intensity, 6),
            "hue": round(hue % 360.0, 3),
            "per_node": per_node,
            "palette_state": {
                "hue": round(hue % 360.0, 3),
                "saturation": round(0.35 + 0.55 * intensity, 6),
                "lightness": round(0.22 + 0.38 * intensity, 6),
            },
        }


# ---------------------------------------------------------------------------
# WallpaperServer — stdlib HTTP + SSE (same pattern as vigil.demo)
# ---------------------------------------------------------------------------

class _WallpaperHandler(BaseHTTPRequestHandler):
    server_version = "VigilWallpaper/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):   # keep tests/console quiet
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
            if path == "/snapshot":
                body = json.dumps(self.server.feed.snapshot()).encode()
                self._send(200, "application/json", body)
            elif path == "/field":
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
            time.sleep(1.0 / self.server.feed.tick_hz)


class WallpaperServer:
    """Threaded stdlib HTTP server for the wallpaper client.

    GET /field    -> SSE stream of snapshots at the feed's tick rate
    GET /snapshot -> one JSON snapshot (schema in module docstring)
    """

    def __init__(self, feed: WallpaperFeed, port: int = 8898,
                 host: str = "127.0.0.1") -> None:
        self.feed = feed
        self._httpd = ThreadingHTTPServer((host, port), _WallpaperHandler)
        self._httpd.daemon_threads = True
        self._httpd.feed = feed
        self._httpd.stopping = False
        self.port = self._httpd.server_address[1]
        self._thread: threading.Thread | None = None

    def start(self) -> "WallpaperServer":
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        name="vigil-wallpaper-http",
                                        daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._httpd.stopping = True
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
