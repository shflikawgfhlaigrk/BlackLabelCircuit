"""Vigil fleet source — live CSI from the ESP32 room fleet (the real hardware).

Drop-in source for home_engine (same contract as CSIReplay/UDPCSISource):
binds the fleet's UDP data port and parses the REAL firmware wire format —
`\\xa5\\x5b` + count + count x 67-byte frames, frame = <BIbQB52s>
(node_id u8, seq u32, rssi i8, ts_us u64, n_sub u8, amps u8[52]) — the same
layout as products/homefront/vigil/frame.py (CONTRACTS.md §1), vendored here
so the shipped app has no dependency on the research tree.

Multi-room: every beacon node is one room-link. next_frame() follows the
PRIMARY node (most frames in the last 2 s; ties -> lowest node_id, so the
selection is stable), and fleet_summary() exposes every node's rate/rssi so
the app can render per-room state. Amplitude-only CSI: the complex return is
amp+0j — vitals/motion/fall paths are amplitude-driven and fully live; the
range profile (needs phase) is honestly degraded and the frame is tiered
"vigil-amplitude" so no layer can mistake it for phase-true CSI.
"""

import socket
import struct
import threading
import time

import numpy as np

VIGIL_UDP_PORT = 5566
UDP_MAGIC = b"\xa5\x5b"        # v1 batch: amplitude only (fw <= 0.2.x)
UDP2_MAGIC = b"\xa5\x57"       # v2 batch: amplitude + PHASE (fw >= 0.3.0)
FRAME_SIZE = 67
FRAME2_SIZE = 119               # 67 + i8[52] phases
N_SUB = 52
_FRAME = struct.Struct("<BIbQB52s")
_FRAME2 = struct.Struct("<BIbQB52s52s")
PHASE_SCALE = 40.4255           # firmware VIGIL_PHASE_SCALE (127 / pi)

_STALE_S = 2.0     # a node with no frames for this long is not live
_PRIMARY_WIN = 2.0 # window for primary-node election


def _sanitize_phase(ph):
    """Linear-detrend one frame's unwrapped phase across subcarriers.

    Raw CSI phase carries a per-packet common offset (CFO) and a slope
    (SFO/PDD) that dwarf the body-induced curvature; the textbook fix is to
    unwrap and remove the least-squares line. What survives is the residual
    shape a body imposes on the channel — the signal amplitude cannot see.
    """
    ph = np.unwrap(np.asarray(ph, dtype=np.float64))
    k = np.arange(ph.size, dtype=np.float64)
    slope = ((ph[-1] - ph[0]) / max(ph.size - 1, 1))
    return (ph - (slope * k + ph.mean() - slope * k.mean())).astype(np.float32)


def _readopt_candidates(manifest, fresh_ids, adopts, now, cooldown):
    """Manifest nodes owed a SET_HOST_IP push: known ip, not currently
    streaming to us, past their per-node cooldown. Pure — regression-locked
    by tests/test_readopt_sweep.py. Malformed manifest entries are skipped,
    never fatal (the sweep must survive a hand-edited fleet.json)."""
    out = []
    for entry in manifest:
        if not isinstance(entry, dict):
            continue
        try:
            nid = int(entry.get("node_id"))
        except (TypeError, ValueError):
            continue
        ip = str(entry.get("ip") or "")
        if not ip or nid in fresh_ids:
            continue
        if now - adopts.get(nid, 0.0) < cooldown:
            continue
        out.append((nid, ip))
    return out


class _Link:
    """One directed rx<-tx CSI link: its own delta chain and motion EMA.
    Per-LINK prev-frames matter: a node hears several peers interleaved, and
    a delta across two DIFFERENT links is a constant bias, not motion."""
    __slots__ = ("prev_amps", "motion_ema", "last_ts", "rssi",
                 "prev_phase", "phase_ema", "phase_seen")

    def __init__(self):
        self.prev_amps = None
        self.motion_ema = 0.0
        self.last_ts = 0.0
        self.rssi = None
        # PHASE LANE (fw >= 0.3.0, VIGIL-TRACKING-STANDARD R1). Raw CSI phase
        # is corrupted by per-packet CFO/SFO — the standard sanitization is a
        # LINEAR DETREND across subcarriers, which cancels the common offset
        # and slope while preserving the body-induced curvature. The residual
        # delta between consecutive frames on the SAME link is displacement
        # evidence amplitude cannot see (a body moving a fraction of a
        # wavelength swings phase long before |csi| changes).
        self.prev_phase = None
        self.phase_ema = 0.0
        self.phase_seen = False


class _Node:
    __slots__ = ("amps", "rssi", "last_ts", "frames", "arrivals",
                 "motion_ema", "ring", "ring_tx", "ring_n", "peers",
                 "peers_seen", "links")

    RING = 3000                   # 30 s @ 100 Hz full-rate window

    def __init__(self):
        self.ring = np.zeros((self.RING, N_SUB), dtype=np.float32)
        self.ring_tx = np.zeros(self.RING, dtype=np.uint8)  # which peer each row came from
        self.ring_n = 0           # total frames ever written (cursor)
        self.peers = set()        # dual-role: which peers THIS node hears
        self.peers_seen = set()
        self.amps = None          # np.float32[52], latest
        self.rssi = None
        self.last_ts = 0.0        # host monotonic of last frame
        self.frames = 0
        self.arrivals = []        # recent arrival stamps (pruned to _PRIMARY_WIN)
        self.motion_ema = 0.0     # mean of this node's live link EMAs
        self.links: dict = {}     # tx node_id -> _Link (per-peer delta chain)


class VigilFleetSource:
    """Live CSI frames from the Vigil ESP32 fleet. Same surface as CSIReplay."""

    fs = 100.0
    subcarriers = N_SUB
    bandwidth_hz = 20e6
    synthetic = False
    tier = "vigil-amplitude"

    def __init__(self, port: int = VIGIL_UDP_PORT):
        self.port = port
        self.frames = 0            # total accepted frames (all nodes)
        self.corrupt = 0
        self._nodes: dict[int, _Node] = {}
        self._lock = threading.Lock()
        self._last_amp = np.zeros(N_SUB, dtype=np.float32)
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("0.0.0.0", port))
        self._sock.settimeout(0.5)
        self._stop = False
        self._thread = threading.Thread(target=self._rx_loop, daemon=True,
                                        name="vigil-fleet-rx")
        self._thread.start()
        threading.Thread(target=self._readopt_loop, daemon=True,
                         name="vigil-fleet-readopt").start()

    # -- discovery hello (fw >= 0.2.0) ---------------------------------------
    # Node broadcasts 0xA5 0x58 {node_id, has_host, fw_lo, fw_hi} every 5 s.
    # If the node has no host configured, or we are not receiving its frames
    # (stale host_ip — the 2026-07-02 outage), push SET_HOST_IP (cmd 0x07)
    # with OUR address over the control plane. Rate-limited per node.

    _CTRL_PORT = 5567
    _ADOPT_COOLDOWN_S = 30.0

    def _on_hello(self, dgram: bytes, addr) -> None:
        node_id = dgram[2]
        has_host = bool(dgram[3])
        now = time.monotonic()
        with self._lock:
            st = self._nodes.get(node_id)
            fresh = st is not None and (now - st.last_ts) <= _STALE_S
            adopts = getattr(self, "_adopts", {})
            self._adopts = adopts
            last = adopts.get(node_id, 0.0)
        if has_host and fresh:
            return                      # streaming to us already — nothing to do
        if now - last < self._ADOPT_COOLDOWN_S:
            return
        if self._push_host_ip(addr[0]):
            self._adopts[node_id] = now

    def _push_host_ip(self, node_ip: str) -> bool:
        """Push SET_HOST_IP (cmd 0x07) with OUR address over the control plane."""
        try:
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            probe.connect((node_ip, self._CTRL_PORT))
            my_ip = probe.getsockname()[0]
            probe.send(b"\xa5\x5c\x07" + my_ip.encode("ascii"))
            probe.close()
            return True
        except OSError:
            return False

    # -- proactive re-adoption sweep ------------------------------------------
    # The hello-triggered adopt above only heals a node whose hello REACHES us.
    # A node that reboots with a stale persisted host_ip streams (and hellos)
    # at the OLD address and stays silently dark forever — node 5 was live at
    # 288 Hz TX with the receiver hearing it at -66 dBm while this engine read
    # it 0.0 Hz and the app called the living room dead (Founder-caught
    # 2026-07-25; same class as the 2026-07-02 outage). So every sweep period
    # we push SET_HOST_IP to every MANIFEST node we are not receiving from: a
    # no-op for healthy nodes (fresh check + per-node cooldown), a permanent
    # self-heal for stale ones. One 17-byte datagram per dark node per cooldown.

    _READOPT_EVERY_S = 30.0

    def _readopt_loop(self):
        try:
            import vigil_paths
            manifest_path = vigil_paths.state_path("fleet.json")
        except Exception:
            return                      # no path isolation available — stay quiet
        import json
        while not self._stop:
            for _ in range(int(self._READOPT_EVERY_S * 2)):
                if self._stop:
                    return
                time.sleep(0.5)
            try:
                with open(manifest_path) as f:
                    manifest = json.load(f)
            except (OSError, ValueError):
                continue                # no/corrupt manifest — nothing to sweep
            if not isinstance(manifest, list):
                continue
            now = time.monotonic()
            with self._lock:
                fresh = {nid for nid, st in self._nodes.items()
                         if now - st.last_ts <= _STALE_S}
                self._adopts = getattr(self, "_adopts", {})
                adopts = dict(self._adopts)
            for nid, ip in _readopt_candidates(manifest, fresh, adopts, now,
                                               self._ADOPT_COOLDOWN_S):
                if self._push_host_ip(ip):
                    with self._lock:
                        self._adopts[nid] = now

    # -- receive path --------------------------------------------------------

    def _rx_loop(self):
        while not self._stop:
            try:
                dgram, addr = self._sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(dgram) == 6 and dgram[:2] == b"\xa5\x58":
                self._on_hello(dgram, addr)
                continue
            v2 = dgram[:2] == UDP2_MAGIC
            if len(dgram) < 3 or (not v2 and dgram[:2] != UDP_MAGIC):
                self.corrupt += 1
                continue
            fsize = FRAME2_SIZE if v2 else FRAME_SIZE
            count = dgram[2]
            body = dgram[3:]
            if count == 0 or len(body) < count * fsize:
                self.corrupt += 1
                continue
            now = time.monotonic()
            with self._lock:
                for i in range(count):
                    raw = body[i * fsize:(i + 1) * fsize]
                    phases = None
                    try:
                        if v2:
                            (node_id, _seq, rssi, _ts_us, n_sub, amps,
                             phases) = _FRAME2.unpack(raw)
                        else:
                            node_id, _seq, rssi, _ts_us, n_sub, amps = _FRAME.unpack(raw)
                    except struct.error:
                        self.corrupt += 1
                        continue
                    if n_sub != N_SUB:
                        self.corrupt += 1
                        continue
                    rx = (node_id >> 4) & 0x0F
                    tx = node_id & 0x0F
                    key = rx if rx != 0 else tx   # dual: the sensing node; legacy: the beacon
                    st = self._nodes.setdefault(key, _Node())
                    new = np.frombuffer(amps, dtype=np.uint8).astype(np.float32)
                    lk = st.links.setdefault(tx, _Link())
                    if lk.prev_amps is not None:
                        delta = float(np.mean(np.abs(new - lk.prev_amps)))
                        lk.motion_ema = 0.92 * lk.motion_ema + 0.08 * delta
                    lk.prev_amps = new
                    if phases is not None:
                        ph = _sanitize_phase(
                            np.frombuffer(phases, dtype=np.int8
                                          ).astype(np.float32) / PHASE_SCALE)
                        if lk.prev_phase is not None:
                            d = np.angle(np.exp(1j * (ph - lk.prev_phase)))
                            pd = float(np.mean(np.abs(d)))
                            lk.phase_ema = 0.92 * lk.phase_ema + 0.08 * pd
                        lk.prev_phase = ph
                        lk.phase_seen = True
                    lk.rssi = int(rssi)
                    lk.last_ts = now
                    live_emas = [l.motion_ema for l in st.links.values()
                                 if now - l.last_ts <= _STALE_S]
                    if live_emas:
                        st.motion_ema = float(np.mean(live_emas))
                    st.amps = new
                    st.ring[st.ring_n % st.RING] = new
                    st.ring_tx[st.ring_n % st.RING] = tx
                    st.ring_n += 1
                    st.peers = getattr(st, "peers_seen", None) or set()
                    if rx != 0:
                        st.peers_seen = getattr(st, "peers_seen", set()) | {tx}
                    st.rssi = int(rssi)
                    st.last_ts = now
                    st.frames += 1
                    st.arrivals.append(now)
                    if len(st.arrivals) > 400:
                        del st.arrivals[:200]
                    self.frames += 1

    # -- source contract -----------------------------------------------------

    @property
    def connected(self) -> bool:
        now = time.monotonic()
        with self._lock:
            return any(now - st.last_ts <= _STALE_S for st in self._nodes.values())

    def _primary(self, now: float):
        """Most active live node in the last window; ties -> lowest id (stable)."""
        best, best_n = None, -1
        with self._lock:
            for nid in sorted(self._nodes):
                st = self._nodes[nid]
                if now - st.last_ts > _STALE_S or st.amps is None:
                    continue
                st.arrivals = [t for t in st.arrivals if now - t <= _PRIMARY_WIN]
                if len(st.arrivals) > best_n:
                    best, best_n = st, len(st.arrivals)
        return best

    def next_frame(self):
        """Latest (amp[52] float32, csi[52] complex64) from the primary node.

        Amplitude-only hardware: the complex return is amp+0j (no phase) — see
        module docstring; holds the last frame between arrivals (engine paces).
        """
        st = self._primary(time.monotonic())
        if st is not None and st.amps is not None:
            self._last_amp = st.amps
        amp = self._last_amp
        return amp, amp.astype(np.complex64)

    def frame_of(self, node_id: int):
        """Latest amp[52] float32 for one node, or None if unknown/stale."""
        now = time.monotonic()
        with self._lock:
            st = self._nodes.get(node_id)
            if st is None or st.amps is None or now - st.last_ts > _STALE_S:
                return None
            return st.amps

    def stream_since(self, node_id: int, cursor: int):
        """Full-rate frames written since `cursor` (up to one ring), filtered
        to the node's DOMINANT peer link — a dual-role node hears several
        peers interleaved, and mixing links in one spectral buffer injects
        link-switch steps that pose as low-frequency (breathing-band) power.
        Returns (rows, new_cursor)."""
        with self._lock:
            st = self._nodes.get(node_id)
            if st is None:
                return np.empty((0, N_SUB), dtype=np.float32), cursor
            n = st.ring_n
            take = min(n - cursor, st.RING)
            if take <= 0:
                return np.empty((0, N_SUB), dtype=np.float32), n
            idx = (np.arange(n - take, n) % st.RING)
            rows = st.ring[idx]
            txs = st.ring_tx[idx]
            vals, counts = np.unique(txs, return_counts=True)
            dom = vals[int(np.argmax(counts))]
            return rows[txs == dom].copy(), n

    def recent_rows(self, node_id: int, seconds: float = 16.0):
        """Last `seconds` of dominant-link rows for one node (mask fitting)."""
        with self._lock:
            st = self._nodes.get(node_id)
            if st is None or st.ring_n == 0:
                return np.empty((0, N_SUB), dtype=np.float32)
            take = min(st.ring_n, st.RING, int(self.fs * seconds * 1.5))
            idx = (np.arange(st.ring_n - take, st.ring_n) % st.RING)
            rows = st.ring[idx]
            txs = st.ring_tx[idx]
            vals, counts = np.unique(txs, return_counts=True)
            dom = vals[int(np.argmax(counts))]
            return rows[txs == dom].copy()

    def links_summary(self) -> dict:
        """Per-directed-link motion for RTI: {(rx, tx): {motion, rssi, live}}.
        rx is the capturing node, tx the peer it heard."""
        now = time.monotonic()
        out = {}
        with self._lock:
            for rx, st in self._nodes.items():
                for tx, lk in st.links.items():
                    if tx == rx:
                        continue
                    out[(int(rx), int(tx))] = {
                        "motion": round(lk.motion_ema, 4),
                        "phase": round(lk.phase_ema, 5) if lk.phase_seen else None,
                        "rssi": lk.rssi,
                        "live": (now - lk.last_ts) <= _STALE_S,
                    }
        return out

    def fleet_summary(self) -> dict:
        """Per-room-link liveness for the app UI: {node_id: {rate_hz, rssi, live}}."""
        now = time.monotonic()
        out = {}
        with self._lock:
            for nid, st in sorted(self._nodes.items()):
                recent = [t for t in st.arrivals if now - t <= _PRIMARY_WIN]
                rate = len(recent) / _PRIMARY_WIN if recent else 0.0
                spec = self._spectral_signature(st)
                out[nid] = {"rate_hz": round(rate, 1), "rssi": st.rssi,
                            "senses": sorted(getattr(st, "peers_seen", set())),
                            "links": len(getattr(st, "peers_seen", set())),
                            "spectrum": spec,
                            "frames": st.frames,
                            "motion": round(st.motion_ema, 4),
                            "live": (now - st.last_ts) <= _STALE_S}
        return out

    @staticmethod
    def _spectral_signature(st):
        """What the MATERIALS on this link do to the 52 frequencies (empty or
        occupied alike): frequency-selectivity, null depth, multipath ripple —
        metal carves deep nulls; wood/drywall absorb smoothly; open air is flat.
        Computed on the last ~2 s of full-rate frames. Honest first-order
        classification, stamped with its own metrics."""
        n = min(st.ring_n, 200)
        if n < 50:
            return None
        idx = (np.arange(st.ring_n - n, st.ring_n) % st.RING)
        prof = st.ring[idx].mean(axis=0)              # mean 52-bin profile
        pk = float(prof.max())
        if pk <= 1e-6:
            return None
        norm = prof / pk
        null_db = float(-20.0 * np.log10(max(float(norm.min()), 1e-3)))
        selectivity = float(norm.std())
        d2 = np.diff(np.sign(np.diff(norm)))
        ripples = int(np.sum(d2 != 0))
        if null_db > 14.0 and selectivity > 0.18:
            material = "metal-rich"
        elif ripples >= 18:
            material = "dense-clutter"
        elif selectivity < 0.08:
            material = "open"
        else:
            material = "absorptive"     # wood / drywall class
        return {"selectivity": round(selectivity, 3), "null_db": round(null_db, 1),
                "ripples": ripples, "material": material}

    def close(self):
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass
