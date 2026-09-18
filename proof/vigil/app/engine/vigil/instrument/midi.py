"""Transport for Module 6 — MIDI / OSC sinks + the Performer pull loop.

Operating envelope: headless-first. `mido`/`python-rtmidi` are OPTIONAL
guarded imports — when they're absent (CI, tests) `MidiOut` degrades to a
recording NullSink with an identical interface, so everything here is fully
testable without audio hardware. `OscOut` is a minimal stdlib UDP OSC 1.0
encoder (fire-and-forget datagrams). Real-instrument sound is GATED on a
host synth; what is MEASURED here is message correctness (golden OSC bytes,
balanced note lifetimes).

Latency budget (default 30 ms, the edge of "instrument feel"):

    UDP CSI ingest + gap fill        ~10 ms   (measured, Track B)
    feature tick + FieldMapping      <1 ms    (pure numpy / dict math)
    sink dispatch (MIDI USB or OSC   ~1-5 ms  (OS + driver; OSC over
      loopback UDP)                            loopback is sub-ms)
    downstream synth voice onset     rest of budget — pick low-attack
                                     patches for percussive response

Performance-feel tuning notes: the 10 Hz tick quantizes onsets to 100 ms,
which reads as "ambient instrument", not drum pad. For tighter feel raise
`tick_hz` on the mapping (the pipeline sustains 20-50 Hz easily); keep
hysteresis >= 0.2 or fast ticks re-trigger neighbouring scale steps. If the
budget is exceeded (slow sink), the Performer never blocks the caller —
sinks are expected to be non-blocking (UDP send / rtmidi enqueue).
"""

from __future__ import annotations

import socket
import struct
from typing import Any, Iterable

from .mapping import FieldMapping, MusicFrame

CC_TIMBRE = 74   # brightness / filter cutoff
CC_PAN = 10


# ---------------------------------------------------------------------------
# OSC 1.0 encoding (stdlib only)
# ---------------------------------------------------------------------------

def _pad4(b: bytes) -> bytes:
    return b + b"\x00" * (-len(b) % 4)


def _osc_string(s: str) -> bytes:
    return _pad4(s.encode("ascii") + b"\x00")


def encode_osc(address: str, *args: Any) -> bytes:
    """Encode one OSC 1.0 message: padded address + ','-typetags + big-endian
    args. Supported types: int -> 'i' (int32), float -> 'f' (float32),
    str -> 's' (padded string), bytes -> 'b' (int32 size + padded blob),
    bool -> 'T'/'F' (no payload)."""
    if not address.startswith("/"):
        raise ValueError("OSC address must start with '/'")
    tags = ","
    payload = b""
    for a in args:
        if isinstance(a, bool):
            tags += "T" if a else "F"
        elif isinstance(a, int):
            tags += "i"
            payload += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            payload += struct.pack(">f", a)
        elif isinstance(a, str):
            tags += "s"
            payload += _osc_string(a)
        elif isinstance(a, (bytes, bytearray)):
            tags += "b"
            payload += struct.pack(">i", len(a)) + _pad4(bytes(a))
        else:
            raise TypeError(f"unsupported OSC arg type {type(a).__name__}")
    return _osc_string(address) + _osc_string(tags) + payload


# ---------------------------------------------------------------------------
# Sinks — one interface: note_on / note_off / cc / close
# ---------------------------------------------------------------------------

class NullSink:
    """Recording sink for tests and dry runs. `.messages` is a list of dicts
    like {"type": "note_on", "note": 57, "velocity": 90, "channel": 0}."""

    def __init__(self) -> None:
        self.messages: list[dict] = []

    def note_on(self, note: int, velocity: int, channel: int = 0) -> None:
        self.messages.append({"type": "note_on", "note": int(note),
                              "velocity": int(velocity), "channel": int(channel)})

    def note_off(self, note: int, channel: int = 0) -> None:
        self.messages.append({"type": "note_off", "note": int(note),
                              "channel": int(channel)})

    def cc(self, control: int, value: int, channel: int = 0) -> None:
        self.messages.append({"type": "cc", "control": int(control),
                              "value": int(value), "channel": int(channel)})

    def close(self) -> None:
        pass


class MidiOut:
    """Real-time MIDI out when `mido` (+ a backend and an output port) is
    available; otherwise a NullSink-compatible recorder (`.real == False`,
    `.messages` populated). Never a hard import of the optional dep."""

    def __init__(self, port_name: str | None = None) -> None:
        self.real = False
        self.port_name: str | None = None
        self.messages: list[dict] = []
        self._mido = None
        self._port = None
        try:
            import mido  # optional dep — guarded per CONTRACTS.md §7
            names = mido.get_output_names()
            if port_name is not None:
                names = [n for n in names if port_name in n]
            if names:
                self._port = mido.open_output(names[0])
                self._mido = mido
                self.port_name = names[0]
                self.real = True
        except Exception:
            self.real = False   # headless: record instead, degrade quietly

    def note_on(self, note: int, velocity: int, channel: int = 0) -> None:
        if self.real:
            self._port.send(self._mido.Message(
                "note_on", note=int(note), velocity=int(velocity),
                channel=int(channel)))
        else:
            self.messages.append({"type": "note_on", "note": int(note),
                                  "velocity": int(velocity),
                                  "channel": int(channel)})

    def note_off(self, note: int, channel: int = 0) -> None:
        if self.real:
            self._port.send(self._mido.Message(
                "note_off", note=int(note), velocity=0, channel=int(channel)))
        else:
            self.messages.append({"type": "note_off", "note": int(note),
                                  "channel": int(channel)})

    def cc(self, control: int, value: int, channel: int = 0) -> None:
        if self.real:
            self._port.send(self._mido.Message(
                "control_change", control=int(control), value=int(value),
                channel=int(channel)))
        else:
            self.messages.append({"type": "cc", "control": int(control),
                                  "value": int(value), "channel": int(channel)})

    def close(self) -> None:
        if self._port is not None:
            try:
                self._port.close()
            finally:
                self._port = None
                self.real = False


class OscOut:
    """Minimal OSC-over-UDP sink (stdlib socket, non-blocking datagrams).

    Wire schema: /vigil/note (channel:i, note:i, velocity:i) — velocity 0 is
    note-off; /vigil/cc (channel:i, control:i, value:i)."""

    def __init__(self, host: str = "127.0.0.1", port: int = 9000) -> None:
        self.addr = (host, int(port))
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def _send(self, msg: bytes) -> None:
        try:
            self._sock.sendto(msg, self.addr)
        except OSError:
            pass  # receiver away — a performance must never crash

    def note_on(self, note: int, velocity: int, channel: int = 0) -> None:
        self._send(encode_osc("/vigil/note", int(channel), int(note),
                              int(velocity)))

    def note_off(self, note: int, channel: int = 0) -> None:
        self._send(encode_osc("/vigil/note", int(channel), int(note), 0))

    def cc(self, control: int, value: int, channel: int = 0) -> None:
        self._send(encode_osc("/vigil/cc", int(channel), int(control),
                              int(value)))

    def close(self) -> None:
        self._sock.close()


# ---------------------------------------------------------------------------
# Performer — MusicFrame stream -> note lifetimes
# ---------------------------------------------------------------------------

class Performer:
    """Converts the 10 Hz MusicFrame stream into note_on/note_off/cc with
    strict note-lifetime bookkeeping: every note_on is matched by exactly one
    note_off (frame diffing + `close()` flush), so no stuck notes ever reach
    the synth. Drivable by fed ticks (tests) or an external 10 Hz scheduler.
    """

    def __init__(self, mapping: FieldMapping, sink: Any,
                 latency_budget_ms: float = 30.0) -> None:
        self.mapping = mapping
        self.sink = sink
        self.latency_budget_ms = float(latency_budget_ms)
        self.active: dict[tuple[int, int], int] = {}   # (channel, note) -> vel
        self._last_cc: dict[tuple[int, int], int] = {}  # (channel, control) -> v
        self.notes_on_sent = 0
        self.notes_off_sent = 0

    # -- driving --------------------------------------------------------------

    def tick(self, t: float, node_inputs: dict) -> MusicFrame:
        """One pull-loop step: map features, then perform the frame."""
        frame = self.mapping.tick(t, node_inputs)
        self.play(frame)
        return frame

    def play(self, frame: MusicFrame) -> None:
        desired: dict[tuple[int, int], dict] = {
            (n["channel"], n["note"]): n for n in frame.notes}
        # releases first: frees voices before new attacks land
        for key in [k for k in self.active if k not in desired]:
            ch, note = key
            self.sink.note_off(note, channel=ch)
            self.notes_off_sent += 1
            del self.active[key]
        for key, n in desired.items():
            if key not in self.active:
                self._cc(n["channel"], CC_PAN,
                         int(round((n["pan"] + 1.0) / 2.0 * 127)))
                self.sink.note_on(n["note"], n["velocity"],
                                  channel=n["channel"])
                self.notes_on_sent += 1
                self.active[key] = n["velocity"]
        if frame.notes:
            brightness = int(frame.timbre.get("brightness", 0))
            for ch in sorted({n["channel"] for n in frame.notes}):
                self._cc(ch, CC_TIMBRE, brightness)

    def _cc(self, channel: int, control: int, value: int) -> None:
        key = (channel, control)
        if self._last_cc.get(key) != value:
            self.sink.cc(control, value, channel=channel)
            self._last_cc[key] = value

    # -- shutdown -------------------------------------------------------------

    def all_notes_off(self) -> None:
        for ch, note in list(self.active):
            self.sink.note_off(note, channel=ch)
            self.notes_off_sent += 1
        self.active.clear()

    def close(self) -> None:
        self.all_notes_off()
        self.sink.close()

    def perform(self, stream: Iterable[tuple[float, dict]]) -> None:
        """Run a whole fed stream, then release everything."""
        for t, nodes in stream:
            self.tick(t, nodes)
        self.all_notes_off()
