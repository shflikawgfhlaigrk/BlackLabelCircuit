"""
Homefront CSI reader — the host half of "our own CSI reader".

A WiFi radio is hardware (you can't read radio waves in pure software), but the
*reader* is ours: this module receives Channel State Information streamed from a
CSI-capable radio over UDP, parses it into per-subcarrier complex CSI, and hands
it to the Homefront pipeline (pose / range / vitals) exactly like the replay
source — so the moment a real radio streams, everything goes live with no other
change.

Wire format (one datagram per CSI frame), kept deliberately simple so any
firmware can emit it:

    {"csi": [i0, q0, i1, q1, ...], "rssi": -45, "ts": 1779.2}

`csi` is interleaved I/Q (one (i,q) pair per subcarrier), ints or floats. An
ESP32 running esp_wifi CSI emits this via the sketch in ../firmware/; csi_sim.py
replays the bundled capture in this format to test the reader without hardware.
"""

import json
import socket
import threading
import time

import numpy as np


class UDPCSISource:
    """Live CSI frames from a UDP stream. Drop-in replacement for CSIReplay."""

    def __init__(self, host="0.0.0.0", port=5005, subcarriers=56,
                 bandwidth_hz=20e6, fs=100.0):
        self.subcarriers = subcarriers
        self.bandwidth_hz = bandwidth_hz
        self.fs = fs
        self.frames = 0
        self.last_rx = 0.0
        self.tier = None   # advertised Homefront sensor tier ("Homefront-Sentry"…)
        self.synthetic = False  # set True when frames carry the csi_sim "sim" stamp (demo, not a real node)
        self._amp = np.zeros(subcarriers, dtype=np.float32)
        self._csi = np.zeros(subcarriers, dtype=np.complex64)
        self._lock = threading.Lock()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        threading.Thread(target=self._recv_loop, daemon=True).start()

    def _recv_loop(self):
        while True:
            try:
                data, _ = self.sock.recvfrom(16384)
            except OSError:
                break
            try:
                obj = json.loads(data.decode("utf-8", "ignore"))
            except (ValueError, UnicodeDecodeError):
                continue
            raw = obj.get("csi")
            if not raw:
                continue
            tier = obj.get("tier")
            if tier:
                self.tier = str(tier)
            if obj.get("sim"):
                self.synthetic = True   # the csi_sim replayer; vitals must be suppressed downstream
            arr = np.asarray(raw, dtype=np.float32)
            even = (arr.size // 2) * 2
            iq = arr[:even].reshape(-1, 2)
            csi = iq[:, 0] + 1j * iq[:, 1]
            n = self.subcarriers
            csi = csi[:n] if csi.size >= n else np.pad(csi, (0, n - csi.size))
            with self._lock:
                self._csi = csi.astype(np.complex64)
                self._amp = np.abs(csi).astype(np.float32)
                self.frames += 1
                self.last_rx = time.time()

    def next_frame(self):
        with self._lock:
            return self._amp.copy(), self._csi.copy()

    @property
    def connected(self):
        return self.frames > 0 and (time.time() - self.last_rx) < 1.5

    def status(self):
        return {"frames": self.frames, "connected": self.connected,
                "subcarriers": self.subcarriers, "tier": self.tier}
