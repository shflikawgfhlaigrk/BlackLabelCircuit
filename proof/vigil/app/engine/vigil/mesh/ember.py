"""M3 — Ember: the Presence Economy surface over a vigil pact.

One glanceable state for "the other house", computed from nothing but the
pact's one-bit heartbeats and their timestamps — no rooms, no vitals, no
counts cross the wire by design (privacy is structural, not policy):

- ``warm``    last normal-day heartbeat < 24 h old AND the morning pattern
              is fresh (today's "normal" seen, or today's expected-activity
              window — default 06:00-10:00 UTC — hasn't closed yet)
- ``cooling`` overdue: the window closed with no normal-today bit, or the
              last normal is going stale
- ``cold``    deadman territory: nothing heard at all for ``cold_after_s``
              (default 48 h), or no heartbeat ever received
- ``alarm``   the peer's escalation payload arrived (deadman/fall/apnea);
              sticky until ``ack()``

Feed it either directly (``note_heartbeat`` / ``note_alarm``) or from a
``PactChannel`` via ``poll()``. All clocks are injectable (``now_fn``) and
interpreted in UTC — configure ``window_h`` for the peer's local morning
expressed in UTC hours. ``EmberServer`` exposes ``/snapshot`` (JSON) and
``/events`` (SSE) for a Live Wallpaper / menubar client — the same tiny
stdlib pattern as vigil/demo.py, deliberately not imported from it.
"""

from __future__ import annotations

import json
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

WARM, COOLING, COLD, ALARM = "warm", "cooling", "cold", "alarm"

SNAPSHOT_HZ = 2.0
HEARTBEAT_S = 5.0


class Ember:
    """Warm/cooling/cold/alarm state machine over peer heartbeats."""

    def __init__(self, channel=None, peer_name: str = "Peer",
                 window_h: tuple[float, float] = (6.0, 10.0),
                 warm_horizon_s: float = 24 * 3600.0,
                 cold_after_s: float = 48 * 3600.0,
                 now_fn: Callable[[], float] = time.time) -> None:
        self.channel = channel          # PactChannel-like (.poll()) or None
        self.peer_name = peer_name
        self.window_h = (float(window_h[0]), float(window_h[1]))
        self.warm_horizon_s = float(warm_horizon_s)
        self.cold_after_s = float(cold_after_s)
        self.now_fn = now_fn

        self._last_hb_ts: float | None = None      # any heartbeat
        self._last_normal_ts: float | None = None  # normal=True heartbeat
        self._normal_days: set[str] = set()        # days reported normal
        self._alarm: dict | None = None            # sticky until ack()

    # -- feeding --------------------------------------------------------------

    def note_heartbeat(self, day: str, normal: bool, ts: float | None = None) -> None:
        t = float(ts if ts is not None else self.now_fn())
        self._last_hb_ts = max(self._last_hb_ts or 0.0, t)
        if normal:
            self._last_normal_ts = max(self._last_normal_ts or 0.0, t)
            self._normal_days.add(str(day))

    def note_alarm(self, msg: dict) -> None:
        self._alarm = dict(msg)

    def poll(self) -> list[dict]:
        """Drain the pact channel (if any) into the state machine."""
        msgs = self.channel.poll() if self.channel is not None else []
        for m in msgs:
            if m.get("type") == "heartbeat":
                self.note_heartbeat(m.get("day", ""), bool(m.get("normal")),
                                    m.get("ts"))
            elif m.get("type") == "alarm":
                self.note_alarm(m)
        return msgs

    def ack(self) -> None:
        """Owner acknowledged the alarm — back to data-driven state."""
        self._alarm = None

    # -- state ----------------------------------------------------------------

    def _day_and_hour(self, now: float) -> tuple[str, float]:
        dt = datetime.fromtimestamp(now, tz=timezone.utc)
        return dt.date().isoformat(), dt.hour + dt.minute / 60.0 + dt.second / 3600.0

    def _morning_fresh(self, now: float) -> bool:
        today, hour = self._day_and_hour(now)
        if today in self._normal_days:
            return True
        return hour < self.window_h[1]   # window still open — not overdue yet

    def state(self, now: float | None = None) -> str:
        now = float(now if now is not None else self.now_fn())
        if self._alarm is not None:
            return ALARM
        if self._last_hb_ts is None or now - self._last_hb_ts >= self.cold_after_s:
            return COLD
        warm = (self._last_normal_ts is not None
                and now - self._last_normal_ts < self.warm_horizon_s
                and self._morning_fresh(now))
        return WARM if warm else COOLING

    # -- surfaces ---------------------------------------------------------------

    @staticmethod
    def _clock(ts: float) -> str:
        s = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%I:%M%p").lower()
        return s.lstrip("0")

    def render_text(self, now: float | None = None) -> str:
        now = float(now if now is not None else self.now_fn())
        st = self.state(now)
        today, _ = self._day_and_hour(now)
        if st == ALARM:
            kind = (self._alarm or {}).get("kind", "alarm")
            return f"{self.peer_name}: ALARM — {kind} (ack to clear)"
        if st == COLD:
            return f"{self.peer_name}: no word — check in"
        if st == WARM:
            if today in self._normal_days and self._last_normal_ts is not None:
                return (f"{self.peer_name}: normal morning ✓ "
                        f"{self._clock(self._last_normal_ts)}")
            return f"{self.peer_name}: quiet so far (morning window open)"
        end_h = int(self.window_h[1])
        return (f"{self.peer_name}: no morning pattern yet "
                f"(expected by {end_h:02d}:{int((self.window_h[1] % 1) * 60):02d})")

    def snapshot(self, now: float | None = None) -> dict:
        now = float(now if now is not None else self.now_fn())
        today, _ = self._day_and_hour(now)
        return {
            "peer": self.peer_name,
            "state": self.state(now),
            "text": self.render_text(now),
            "last_heartbeat_ts": self._last_hb_ts,
            "last_normal_ts": self._last_normal_ts,
            "normal_today": today in self._normal_days,
            "alarm": self._alarm,
            "t": now,
        }


# ---------------------------------------------------------------------------
# EmberServer — stdlib JSON/SSE feed (pattern from vigil/demo.py, not imported)
# ---------------------------------------------------------------------------

class _EmberHandler(BaseHTTPRequestHandler):
    server_version = "VigilEmber/0.1"
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
            if path == "/snapshot":
                body = json.dumps(self.server.ember.snapshot()).encode()
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
            payload = json.dumps(self.server.ember.snapshot())
            self.wfile.write(f"data: {payload}\n\n".encode())
            if time.monotonic() - last_beat > HEARTBEAT_S:
                self.wfile.write(b": heartbeat\n\n")
                last_beat = time.monotonic()
            self.wfile.flush()
            time.sleep(1.0 / SNAPSHOT_HZ)


class EmberServer:
    """Threaded stdlib feed for wallpaper/menubar clients.

    GET /snapshot -> one JSON snapshot (state/text/timestamps — one bit
                     plus timestamps by design, nothing else exists here)
    GET /events   -> SSE stream of snapshots at ~2 Hz with heartbeats
    """

    def __init__(self, ember: Ember, port: int = 8898,
                 host: str = "0.0.0.0") -> None:
        self.ember = ember
        self._httpd = ThreadingHTTPServer((host, port), _EmberHandler)
        self._httpd.daemon_threads = True
        self._httpd.ember = ember
        self._httpd.stopping = False
        self.port = self._httpd.server_address[1]
        self._thread: threading.Thread | None = None

    def start(self) -> "EmberServer":
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        name="vigil-ember-http", daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._httpd.stopping = True
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
