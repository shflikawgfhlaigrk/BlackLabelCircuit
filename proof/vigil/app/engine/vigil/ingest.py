"""Ingest daemon — UDP/serial CSI intake onto per-node 100 Hz ring buffers (B1).

Operating envelope:

- Nominal rate is 100 Hz per node (CONTRACTS.md §2). Frames are placed on a
  uniform 100 Hz grid using per-node sequence-number deltas, not arrival time.
- Loss handling: a gap of <=3 missing frames is linearly interpolated between
  the neighbouring frames; longer gaps hold the last row (fill capped at
  ``HOLD_CAP_S`` seconds of rows so a dead node cannot spin the CPU) and every
  missing frame is counted as loss in ``stats()``.
- Reboots: seq is u32 and wraps; a small backwards step is treated as a
  duplicate/reorder and dropped, a large backwards jump (> ``REBOOT_DELTA``)
  is a node reboot — the node's timeline restarts at the next grid row, its
  clock fit is discarded, and ``reboots`` is incremented.
- Corrupt/undecodable datagrams and serial CRC failures are dropped and
  counted; the datagram handler never raises.
- Memory bound: all hot-path storage is preallocated ring buffers of
  ``config.ring_buffer_s * 100`` rows per node ([t,52] float32 plus parallel
  seq/rssi/ts arrays). No dynamic growth, no per-frame heap growth; buffer
  ``nbytes`` is constant for the life of the daemon.
- Unified clock: per node we keep a trailing window of (arrival monotonic,
  unwrapped seq) pairs and maintain a linear fit (drift-corrected);
  ``node_time(node_id, seq)`` maps a node seq to host seconds
  (``time.monotonic`` domain).
- pyserial is an optional dependency: serial nodes degrade with a recorded
  error message if it is missing (never a hard import at module top level).
"""

from __future__ import annotations

import asyncio
import json
import socket
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

from .config import VigilConfig
from .frame import N_SUB, Frame, SerialDeframer, unpack_udp_batch

FS = 100.0
MAX_INTERP_GAP = 3          # missing frames; <= this -> linear interpolation
HOLD_CAP_S = 2.0            # max seconds of held rows written per long gap
REBOOT_DELTA = 100          # backwards seq jump larger than this -> reboot
CLOCK_WINDOW = 512          # trailing (arrival, seq) pairs for the drift fit
CLOCK_REFIT_EVERY = 64      # frames between linear-fit refreshes


class CsiRingBuffer:
    """Preallocated circular buffer: [capacity, 52] float32 amps + parallel
    seq (unwrapped, int64), rssi (int8) and host-timestamp (float64) arrays.

    Writes cast uint8 rows in place (no per-frame allocation); reads return
    copies ordered oldest->newest.
    """

    def __init__(self, capacity: int) -> None:
        self.capacity = int(capacity)
        self.amps = np.zeros((self.capacity, N_SUB), np.float32)
        self.seq = np.zeros(self.capacity, np.int64)
        self.rssi = np.zeros(self.capacity, np.int8)
        self.ts = np.zeros(self.capacity, np.float64)
        self.idx = 0        # next write slot
        self.count = 0      # valid rows (saturates at capacity)
        self.lock = threading.Lock()

    @property
    def nbytes(self) -> int:
        return self.amps.nbytes + self.seq.nbytes + self.rssi.nbytes + self.ts.nbytes

    def write(self, amps, seq: int, rssi: int, ts: float) -> None:
        with self.lock:
            i = self.idx
            self.amps[i] = amps  # casting assignment, no allocation
            self.seq[i] = seq
            self.rssi[i] = rssi
            self.ts[i] = ts
            self.idx = (i + 1) % self.capacity
            if self.count < self.capacity:
                self.count += 1

    def tail(self, n: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """Most recent n rows, oldest first (copies)."""
        with self.lock:
            n = min(int(n), self.count)
            if n <= 0:
                return (np.zeros((0, N_SUB), np.float32), np.zeros(0, np.int64),
                        np.zeros(0, np.int8), np.zeros(0, np.float64))
            start = (self.idx - n) % self.capacity
            idxs = (start + np.arange(n)) % self.capacity
            return (self.amps[idxs], self.seq[idxs], self.rssi[idxs], self.ts[idxs])


class _NodeState:
    __slots__ = (
        "node_id", "ring", "lock", "last_raw", "unwrapped", "last_amps",
        "last_arrival", "received", "interp", "held", "lost", "dups",
        "reboots", "corrupt", "last_rssi", "arrivals", "fit", "fit_at",
    )

    def __init__(self, node_id: int, capacity: int) -> None:
        self.node_id = node_id
        self.ring = CsiRingBuffer(capacity)
        self.lock = threading.Lock()
        self.last_raw: int | None = None   # last raw u32 seq
        self.unwrapped = 0                 # monotonically increasing seq
        self.last_amps = np.zeros(N_SUB, np.float32)
        self.last_arrival: float | None = None
        self.received = 0
        self.interp = 0      # frames filled by interpolation
        self.held = 0        # frames filled by hold-last
        self.lost = 0        # total missing frames (interp + held + unfilled)
        self.dups = 0
        self.reboots = 0
        self.corrupt = 0     # serial CRC failures attributed to this node
        self.last_rssi = 0
        self.arrivals: deque[tuple[float, int]] = deque(maxlen=CLOCK_WINDOW)
        self.fit: tuple[float, float] | None = None  # t = a*seq + b
        self.fit_at = 0


class _UdpProtocol(asyncio.DatagramProtocol):
    def __init__(self, daemon: "IngestDaemon") -> None:
        self.daemon = daemon

    def datagram_received(self, data: bytes, addr) -> None:  # never raises
        d = self.daemon
        d._datagrams += 1
        try:
            frames = unpack_udp_batch(data)
        except Exception:
            d._udp_corrupt += 1
            return
        arrival = time.monotonic()
        for f in frames:
            try:
                d._dispatch(f, arrival)
            except Exception:
                d._udp_corrupt += 1

    def error_received(self, exc) -> None:
        pass


class IngestDaemon:
    """Fleet intake: UDP batches + optional serial nodes -> per-node rings."""

    def __init__(self, config: VigilConfig) -> None:
        self.config = config
        self.fs = FS
        self._capacity = max(1, int(config.ring_buffer_s * FS))
        self._hold_cap = max(1, int(HOLD_CAP_S * FS))
        self._nodes: dict[int, _NodeState] = {}
        self._nodes_lock = threading.Lock()
        self._udp_corrupt = 0
        self._datagrams = 0
        self.serial_errors: list[str] = []
        self._transport: asyncio.DatagramTransport | None = None
        self._serial_threads: list[threading.Thread] = []
        self._stop_evt = threading.Event()
        self._http: ThreadingHTTPServer | None = None
        self._http_thread: threading.Thread | None = None
        self._own_loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self.udp_port: int = config.udp_port
        for n in config.nodes:
            self._add_node(n.node_id)

    # -- node registry -----------------------------------------------------

    def _add_node(self, node_id: int) -> _NodeState:
        with self._nodes_lock:
            st = self._nodes.get(node_id)
            if st is None:
                st = _NodeState(node_id, self._capacity)
                self._nodes[node_id] = st
            return st

    def buffer_nbytes(self, node_id: int) -> int:
        return self._nodes[node_id].ring.nbytes

    # -- dispatch (hot path) -------------------------------------------------

    def _dispatch(self, frame: Frame, arrival: float) -> None:
        st = self._nodes.get(frame.node_id)
        if st is None:
            st = self._add_node(frame.node_id)
        with st.lock:
            st.last_rssi = int(frame.rssi)
            if st.last_raw is None:
                self._accept(st, frame, arrival, first=True)
                return
            delta = ((frame.seq - st.last_raw + 0x80000000) & 0xFFFFFFFF) - 0x80000000
            if delta <= 0:
                if delta < -REBOOT_DELTA:
                    st.reboots += 1
                    st.arrivals.clear()
                    st.fit = None
                    st.fit_at = st.received
                    self._accept(st, frame, arrival, first=False, delta=1)
                else:
                    st.dups += 1
                return
            missing = delta - 1
            if 1 <= missing <= MAX_INTERP_GAP:
                new_f = frame.amps.astype(np.float32)
                t0 = st.last_arrival if st.last_arrival is not None else arrival
                for j in range(1, delta):
                    w = j / delta
                    row = st.last_amps * (1.0 - w) + new_f * w
                    st.ring.write(row, st.unwrapped + j, st.last_rssi,
                                  t0 + w * (arrival - t0))
                st.interp += missing
                st.lost += missing
            elif missing > MAX_INTERP_GAP:
                fill = min(missing, self._hold_cap)
                t0 = st.last_arrival if st.last_arrival is not None else arrival
                for j in range(1, fill + 1):
                    st.ring.write(st.last_amps, st.unwrapped + j, st.last_rssi,
                                  t0 + (j / delta) * (arrival - t0))
                st.held += fill
                st.lost += missing
            self._accept(st, frame, arrival, first=False, delta=delta)

    def _accept(self, st: _NodeState, frame: Frame, arrival: float,
                first: bool, delta: int = 0) -> None:
        if first:
            st.unwrapped = int(frame.seq)
        else:
            st.unwrapped += delta
        st.last_raw = int(frame.seq)
        st.last_arrival = arrival
        st.received += 1
        np.copyto(st.last_amps, frame.amps, casting="unsafe")
        st.ring.write(frame.amps, st.unwrapped, frame.rssi, arrival)
        st.arrivals.append((arrival, st.unwrapped))
        if len(st.arrivals) >= 8 and st.received - st.fit_at >= CLOCK_REFIT_EVERY:
            self._refit_clock(st)

    @staticmethod
    def _refit_clock(st: _NodeState) -> None:
        arr = np.asarray(st.arrivals, np.float64)
        t, s = arr[:, 0], arr[:, 1]
        s0 = s[0]
        denom = np.sum((s - s0 - np.mean(s - s0)) ** 2)
        if denom <= 0:
            return
        sm, tm = np.mean(s - s0), np.mean(t)
        a = np.sum((s - s0 - sm) * (t - tm)) / denom
        b = tm - a * (sm + s0)
        st.fit = (float(a), float(b))
        st.fit_at = st.received

    # -- unified clock -------------------------------------------------------

    def node_time(self, node_id: int, seq: int) -> float:
        """Map a node's (raw u32) seq to host seconds (time.monotonic domain).

        Uses the drift-corrected linear fit over the trailing arrival window;
        falls back to nominal-rate extrapolation from the last arrival before
        the fit is warm.
        """
        st = self._nodes[node_id]
        with st.lock:
            if st.last_raw is None or st.last_arrival is None:
                raise ValueError(f"node {node_id} has no frames yet")
            rel = ((int(seq) - st.last_raw + 0x80000000) & 0xFFFFFFFF) - 0x80000000
            unwr = st.unwrapped + rel
            if st.fit is not None:
                a, b = st.fit
                return a * unwr + b
            return st.last_arrival + rel / self.fs

    # -- public read API (thread-safe snapshots) ------------------------------

    def stream(self, node_id: int, seconds: float) -> np.ndarray:
        """Most-recent `seconds` window, uniform 100 Hz grid, [t,52] float32."""
        st = self._nodes.get(node_id)
        if st is None:
            return np.zeros((0, N_SUB), np.float32)
        amps, _, _, _ = st.ring.tail(int(seconds * self.fs))
        return amps

    def snapshot(self, node_id: int, seconds: float) -> dict[str, np.ndarray]:
        """Most-recent window with parallel arrays (recorder consumption)."""
        st = self._nodes.get(node_id)
        if st is None:
            raise KeyError(f"unknown node {node_id}")
        amps, seq, rssi, ts = st.ring.tail(int(seconds * self.fs))
        return {"amps": amps, "seq": seq, "rssi": rssi, "ts": ts}

    def frames_rate(self, node_id: int) -> float:
        st = self._nodes.get(node_id)
        if st is None:
            return 0.0
        with st.lock:
            if len(st.arrivals) < 2:
                return 0.0
            span = st.arrivals[-1][0] - st.arrivals[0][0]
            return (len(st.arrivals) - 1) / span if span > 0 else 0.0

    def stats(self) -> dict:
        nodes = {}
        for nid, st in list(self._nodes.items()):
            expected = st.received + st.lost
            nodes[nid] = {
                "rate_hz": round(self.frames_rate(nid), 3),
                "loss_pct": round(100.0 * st.lost / expected, 4) if expected else 0.0,
                "corrupt": st.corrupt,
                "reboots": st.reboots,
                "last_rssi": st.last_rssi,
                "buffer_fill": round(st.ring.count / st.ring.capacity, 4),
                "received": st.received,
                "interpolated": st.interp,
                "held": st.held,
                "lost": st.lost,
                "dups": st.dups,
            }
        return {"nodes": nodes, "udp_corrupt": self._udp_corrupt,
                "udp_datagrams": self._datagrams,
                "serial_errors": list(self.serial_errors)}

    def stats_text(self) -> str:
        """Prometheus exposition format for /metrics."""
        s = self.stats()
        lines = [
            "# TYPE vigil_udp_corrupt_total counter",
            f"vigil_udp_corrupt_total {s['udp_corrupt']}",
            "# TYPE vigil_udp_datagrams_total counter",
            f"vigil_udp_datagrams_total {s['udp_datagrams']}",
        ]
        gauges = [
            ("vigil_node_rate_hz", "gauge", "rate_hz"),
            ("vigil_node_loss_pct", "gauge", "loss_pct"),
            ("vigil_node_corrupt_total", "counter", "corrupt"),
            ("vigil_node_reboots_total", "counter", "reboots"),
            ("vigil_node_last_rssi_dbm", "gauge", "last_rssi"),
            ("vigil_node_buffer_fill", "gauge", "buffer_fill"),
            ("vigil_node_received_total", "counter", "received"),
        ]
        for name, kind, key in gauges:
            lines.append(f"# TYPE {name} {kind}")
            for nid, ns in sorted(s["nodes"].items()):
                lines.append(f'{name}{{node="{nid}"}} {ns[key]}')
        return "\n".join(lines) + "\n"

    # -- stats HTTP endpoint ---------------------------------------------------

    def start_stats_server(self, port: int = 0, host: str | None = None) -> int:
        """Serve /metrics (Prometheus) and /stats.json; returns bound port."""
        daemon = self

        class _Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.path == "/metrics":
                    body = daemon.stats_text().encode()
                    ctype = "text/plain; version=0.0.4"
                elif self.path == "/stats.json":
                    body = json.dumps(daemon.stats()).encode()
                    ctype = "application/json"
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args) -> None:  # keep tests quiet
                pass

        bind = host if host is not None else (
            self.config.host_ip if self.config.host_ip else "0.0.0.0")
        self._http = ThreadingHTTPServer((bind, port), _Handler)
        self._http_thread = threading.Thread(
            target=self._http.serve_forever, daemon=True, name="vigil-stats-http")
        self._http_thread.start()
        return self._http.server_address[1]

    # -- serial transport --------------------------------------------------------

    def _serial_worker(self, node_id: int, port_name: str, baud: int = 921600) -> None:
        try:
            import serial  # optional dependency (guarded)
        except ImportError:
            self.serial_errors.append(
                f"node {node_id}: pyserial not installed, serial transport disabled")
            return
        try:
            port = serial.Serial(port_name, baud, timeout=0.2)
        except Exception as exc:
            self.serial_errors.append(f"node {node_id}: cannot open {port_name}: {exc}")
            return
        st = self._add_node(node_id)
        deframer = SerialDeframer()
        try:
            while not self._stop_evt.is_set():
                chunk = port.read(4096)
                if not chunk:
                    continue
                for f in deframer.feed(chunk):
                    try:
                        self._dispatch(f, time.monotonic())
                    except Exception:
                        st.corrupt += 1
                st.corrupt = deframer.corrupt
        finally:
            port.close()

    # -- lifecycle -----------------------------------------------------------------

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(
            lambda: _UdpProtocol(self),
            local_addr=(self.config.host_ip or "0.0.0.0", self.config.udp_port),
        )
        self._transport = transport
        sock = transport.get_extra_info("socket")
        if sock is not None:
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
            except OSError:
                pass
            self.udp_port = sock.getsockname()[1]
        self._stop_evt.clear()
        for n in self.config.nodes:
            if n.transport == "serial" and n.serial_port:
                t = threading.Thread(
                    target=self._serial_worker, args=(n.node_id, n.serial_port),
                    daemon=True, name=f"vigil-serial-{n.node_id}")
                t.start()
                self._serial_threads.append(t)

    async def stop(self) -> None:
        self._stop_evt.set()
        if self._transport is not None:
            self._transport.close()
            self._transport = None
        for t in self._serial_threads:
            t.join(timeout=1.0)
        self._serial_threads.clear()
        if self._http is not None:
            self._http.shutdown()
            self._http.server_close()
            self._http = None

    def run_in_thread(self) -> "IngestDaemon":
        """Spin the event loop in a daemon thread for sync consumers."""
        started = threading.Event()
        error: list[BaseException] = []

        def _run() -> None:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            self._own_loop = loop
            try:
                loop.run_until_complete(self.start())
            except BaseException as exc:  # surfaced to caller
                error.append(exc)
                started.set()
                return
            started.set()
            loop.run_forever()
            loop.close()

        self._thread = threading.Thread(target=_run, daemon=True, name="vigil-ingest")
        self._thread.start()
        if not started.wait(10):
            raise RuntimeError("ingest loop failed to start")
        if error:
            raise error[0]
        return self

    def stop_sync(self, timeout: float = 5.0) -> None:
        loop = self._own_loop
        if loop is None:
            return
        fut = asyncio.run_coroutine_threadsafe(self.stop(), loop)
        fut.result(timeout)
        loop.call_soon_threadsafe(loop.stop)
        if self._thread is not None:
            self._thread.join(timeout)
        self._own_loop = None
