"""CSI frame wire codec — the firmware <-> ingest contract (CONTRACTS.md §1).

Operating envelope: 67-byte fixed frames, amplitude-only CSI over 52 HT20
information subcarriers. Serial framing carries a CRC-8 and resyncs on the
2-byte magic after corruption; UDP batches up to 10 frames per datagram and
relies on the UDP checksum. This module is pure stdlib + numpy and is the
single source of truth for the binary layout — firmware mirrors it in
`firmware/main/vigil_frame.h`.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

import numpy as np

N_SUB = 52
FRAME_SIZE = 67  # 1 + 4 + 1 + 8 + 1 + 52
SERIAL_MAGIC = b"\xa5\x5a"
UDP_MAGIC = b"\xa5\x5b"
SERIAL_FRAME_SIZE = 2 + FRAME_SIZE + 1  # magic + payload + crc8
UDP_MAX_BATCH = 10

_STRUCT = struct.Struct("<BIbQB52s")
assert _STRUCT.size == FRAME_SIZE


@dataclass(frozen=True)
class Frame:
    node_id: int
    seq: int
    rssi: int
    ts_us: int
    amps: np.ndarray  # uint8[52]

    def __post_init__(self) -> None:
        a = np.asarray(self.amps, dtype=np.uint8)
        if a.shape != (N_SUB,):
            raise ValueError(f"amps must be uint8[{N_SUB}], got {a.shape}")
        object.__setattr__(self, "amps", a)


def crc8(data: bytes, poly: int = 0x07, init: int = 0x00) -> int:
    """CRC-8/ATM (poly 0x07, init 0x00) — matches the firmware table."""
    crc = init
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def pack_frame(frame: Frame) -> bytes:
    """67-byte payload (no transport framing)."""
    return _STRUCT.pack(
        frame.node_id & 0xFF,
        frame.seq & 0xFFFFFFFF,
        int(frame.rssi),
        frame.ts_us & 0xFFFFFFFFFFFFFFFF,
        N_SUB,
        frame.amps.tobytes(),
    )


def unpack_frame(payload: bytes) -> Frame:
    if len(payload) != FRAME_SIZE:
        raise ValueError(f"payload must be {FRAME_SIZE} bytes, got {len(payload)}")
    node_id, seq, rssi, ts_us, n_sub, amps = _STRUCT.unpack(payload)
    if n_sub != N_SUB:
        raise ValueError(f"n_sub={n_sub}, expected {N_SUB}")
    return Frame(node_id, seq, rssi, ts_us, np.frombuffer(amps, dtype=np.uint8).copy())


def pack_serial(frame: Frame) -> bytes:
    payload = pack_frame(frame)
    return SERIAL_MAGIC + payload + bytes([crc8(payload)])


def pack_udp_batch(frames: list[Frame]) -> bytes:
    if not 1 <= len(frames) <= UDP_MAX_BATCH:
        raise ValueError(f"batch must be 1..{UDP_MAX_BATCH} frames")
    return UDP_MAGIC + bytes([len(frames)]) + b"".join(pack_frame(f) for f in frames)


def unpack_udp_batch(datagram: bytes) -> list[Frame]:
    if len(datagram) < 3 or datagram[:2] != UDP_MAGIC:
        raise ValueError("bad UDP magic")
    count = datagram[2]
    expected = 3 + count * FRAME_SIZE
    if count < 1 or count > UDP_MAX_BATCH or len(datagram) != expected:
        raise ValueError(f"bad UDP batch: count={count} len={len(datagram)}")
    return [
        unpack_frame(datagram[3 + i * FRAME_SIZE : 3 + (i + 1) * FRAME_SIZE])
        for i in range(count)
    ]


class SerialDeframer:
    """Incremental serial stream deframer with resync.

    Feed arbitrary byte chunks; yields Frames. Corrupt frames (bad CRC) are
    counted in `.corrupt` and skipped by resyncing on the next magic.
    """

    def __init__(self) -> None:
        self._buf = bytearray()
        self.corrupt = 0

    def feed(self, chunk: bytes) -> list[Frame]:
        self._buf.extend(chunk)
        frames: list[Frame] = []
        while True:
            idx = self._buf.find(SERIAL_MAGIC)
            if idx < 0:
                # keep last byte in case it's the first magic byte of a split pair
                del self._buf[:-1]
                break
            if idx > 0:
                del self._buf[:idx]
            if len(self._buf) < SERIAL_FRAME_SIZE:
                break
            payload = bytes(self._buf[2 : 2 + FRAME_SIZE])
            rx_crc = self._buf[2 + FRAME_SIZE]
            if crc8(payload) == rx_crc:
                try:
                    frames.append(unpack_frame(payload))
                except ValueError:
                    self.corrupt += 1
                del self._buf[:SERIAL_FRAME_SIZE]
            else:
                self.corrupt += 1
                del self._buf[:2]  # skip this magic, rescan
        return frames
