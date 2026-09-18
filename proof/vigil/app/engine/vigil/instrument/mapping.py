"""Motion -> music mapping — the deterministic heart of Module 6.

Operating envelope: consumes *already computed* per-node motion features at
the 10 Hz tick rate (motion_energy from `vigil.spectral` conventions,
spectral_centroid from a short FFT of the recent motion band — see
`analyze_window` for the reference implementation, band_energies as coarse
FFT band sums). It emits `MusicFrame`s: pure, seeded functions of the input
history — the same input stream yields a byte-identical frame stream
(`MusicFrame.to_bytes`). Nothing here touches hardware, sockets or clocks;
musicality on real instruments (synth patch choice, perceived latency,
groove) is GATED on live hardware with a MIDI synth and is not claimed by
these tests.

Mapping semantics:

- motion energy -> pitch: energy is soft-compressed to a 0..1 level
  (``e / (e + energy_ref)``), gated below ``energy_floor`` (rest frames),
  then quantized onto a scale table (``base_note`` + ``octaves`` octaves of
  the chosen scale). A held-position hysteresis band keeps a steady level on
  one note instead of jittering between neighbours.
- motion energy -> velocity (24..127) with a tiny seeded, deterministic
  humanization (±2).
- spectral centroid -> timbre: normalized 0..1 against ``centroid_ref`` Hz
  and exposed as a CC74-style ``brightness`` value 0..127.
- multi-node -> pan: nodes (sorted by node_id) are spread across the stereo
  field: 1 node = center, 2 nodes = hard L/R, N nodes = linspace(-1, 1, N).
  Each active node contributes one voice, so note density scales with the
  number of nodes seeing motion.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping

import numpy as np

SCALES: dict[str, tuple[int, ...]] = {
    "pentatonic-minor": (0, 3, 5, 7, 10),
    "pentatonic-major": (0, 2, 4, 7, 9),
    "dorian": (0, 2, 3, 5, 7, 9, 10),
    "aeolian": (0, 2, 3, 5, 7, 8, 10),
    "chromatic": tuple(range(12)),
}

TICK_HZ = 10.0


def _round6(x: float) -> float:
    return round(float(x), 6)


@dataclass(frozen=True)
class MusicFrame:
    """One 10 Hz frame of musical intent.

    notes: list of {"note": int, "velocity": int, "channel": int,
    "pan": float in -1..1}. timbre: {"centroid_norm": 0..1,
    "brightness": 0..127}. intensity: 0..1 overall level.
    """

    t: float
    notes: tuple[dict, ...]
    timbre: dict
    intensity: float

    def to_json(self) -> str:
        return json.dumps(
            {"t": self.t, "notes": list(self.notes), "timbre": self.timbre,
             "intensity": self.intensity},
            sort_keys=True, separators=(",", ":"))

    def to_bytes(self) -> bytes:
        return self.to_json().encode("utf-8")

    @property
    def is_rest(self) -> bool:
        return not self.notes


def analyze_window(motion: np.ndarray, fs: float = 100.0,
                   n_bands: int = 8, f_max: float = 12.0) -> dict:
    """Reference per-node feature extractor: a short FFT of the recent
    motion-band signal (e.g. the last 0.5-1 s of PC1 from SpectralStage).

    Returns {"motion_energy": RMS, "spectral_centroid": Hz,
    "band_energies": [n_bands]} — exactly the per-node input `FieldMapping`
    expects each tick.
    """
    x = np.asarray(motion, dtype=np.float64).ravel()
    if x.size < 4:
        return {"motion_energy": 0.0, "spectral_centroid": 0.0,
                "band_energies": [0.0] * n_bands}
    energy = float(np.sqrt(np.mean(x ** 2)))
    spec = np.abs(np.fft.rfft(x - x.mean())) ** 2
    freqs = np.fft.rfftfreq(x.size, 1.0 / fs)
    p, fr = spec[1:], freqs[1:]                      # drop DC
    total = float(p.sum())
    centroid = float((p * fr).sum() / total) if total > 1e-12 else 0.0
    edges = np.linspace(0.0, min(f_max, fs / 2.0), n_bands + 1)
    bands = [float(p[(fr >= edges[i]) & (fr < edges[i + 1])].sum())
             for i in range(n_bands)]
    return {"motion_energy": energy, "spectral_centroid": centroid,
            "band_energies": bands}


class FieldMapping:
    """Deterministic motion-field -> MusicFrame mapper.

    Input per tick (10 Hz): ``{node_id: {"motion_energy": float,
    "spectral_centroid": float, "band_energies": [floats]}}``. State is only
    the per-node held scale position (hysteresis) and the tick counter, so
    the frame stream is a pure function of (input history, seed,
    constructor params).
    """

    def __init__(self, scale: str = "pentatonic-minor", base_note: int = 45,
                 fs: float = 100.0, tick_hz: float = TICK_HZ,
                 octaves: int = 2, energy_ref: float = 5.0,
                 energy_floor: float = 0.05, hysteresis: float = 0.25,
                 centroid_ref: float = 10.0, seed: int = 0) -> None:
        if scale not in SCALES:
            raise ValueError(f"unknown scale {scale!r}; know {sorted(SCALES)}")
        self.scale = scale
        self.base_note = int(base_note)
        self.fs = float(fs)
        self.tick_hz = float(tick_hz)
        self.octaves = int(octaves)
        self.energy_ref = float(energy_ref)
        self.energy_floor = float(energy_floor)   # on the 0..1 level, not raw
        self.hysteresis = float(hysteresis)
        self.centroid_ref = float(centroid_ref)
        self.seed = int(seed)
        degrees = SCALES[scale]
        self.note_table: tuple[int, ...] = tuple(
            self.base_note + 12 * o + d
            for o in range(self.octaves) for d in degrees
        ) + (self.base_note + 12 * self.octaves,)
        self._held: dict[int, int | None] = {}    # node_id -> position index
        self._tick = 0

    # -- pure helpers ---------------------------------------------------------

    def level(self, energy: float) -> float:
        """Soft-compress raw motion energy to a 0..1 level (monotonic)."""
        e = max(float(energy), 0.0)
        return e / (e + self.energy_ref)

    def centroid_norm(self, centroid_hz: float) -> float:
        return min(max(float(centroid_hz) / self.centroid_ref, 0.0), 1.0)

    def _position(self, lvl: float) -> float:
        """Continuous scale-table position for a gated level."""
        span = max(1.0 - self.energy_floor, 1e-9)
        frac = min(max((lvl - self.energy_floor) / span, 0.0), 1.0)
        return frac * (len(self.note_table) - 1)

    def _humanize(self, node_id: int) -> int:
        """Deterministic ±2 velocity nudge from (seed, tick, node)."""
        h = hashlib.blake2b(f"{self.seed}:{self._tick}:{node_id}".encode(),
                            digest_size=2).digest()
        return int.from_bytes(h, "big") % 5 - 2

    @staticmethod
    def _pans(n: int) -> list[float]:
        if n <= 1:
            return [0.0]
        return [round(-1.0 + 2.0 * j / (n - 1), 3) for j in range(n)]

    # -- state ---------------------------------------------------------------

    def reset(self) -> None:
        self._held.clear()
        self._tick = 0

    # -- the tick -------------------------------------------------------------

    def tick(self, t: float, node_inputs: Mapping[int, Mapping[str, Any]]
             ) -> MusicFrame:
        """Map one 10 Hz tick of per-node features to a MusicFrame."""
        node_ids = sorted(int(n) for n in node_inputs)
        pans = self._pans(len(node_ids))
        notes: list[dict] = []
        levels: list[float] = []
        cw_num = 0.0  # energy-weighted centroid accumulator
        cw_den = 0.0
        release = 0.8 * self.energy_floor  # gate off below this (Schmitt)
        for j, nid in enumerate(node_ids):
            feat = node_inputs[nid]
            lvl = self.level(float(feat.get("motion_energy", 0.0)))
            cn = self.centroid_norm(float(feat.get("spectral_centroid", 0.0)))
            held = self._held.get(nid)
            gate_on = lvl >= (release if held is not None else self.energy_floor)
            if not gate_on:
                self._held[nid] = None
                continue
            pos = self._position(lvl)
            if held is None or abs(pos - held) > 0.5 + self.hysteresis:
                held = int(math.floor(pos + 0.5))
            held = min(max(held, 0), len(self.note_table) - 1)
            self._held[nid] = held
            vel = int(round(24.0 + lvl * 103.0)) + self._humanize(nid)
            vel = min(max(vel, 1), 127)
            notes.append({"note": self.note_table[held],
                          "velocity": vel,
                          "channel": j % 16,
                          "pan": pans[j]})
            levels.append(lvl)
            cw_num += lvl * cn
            cw_den += lvl
        centroid_norm = _round6(cw_num / cw_den) if cw_den > 1e-12 else 0.0
        intensity = _round6(sum(levels) / len(levels)) if levels else 0.0
        frame = MusicFrame(
            t=_round6(t),
            notes=tuple(notes),
            timbre={"centroid_norm": centroid_norm,
                    "brightness": int(round(centroid_norm * 127))},
            intensity=intensity,
        )
        self._tick += 1
        return frame

    def run(self, stream: Iterable[tuple[float, Mapping[int, Mapping]]]
            ) -> list[MusicFrame]:
        """Convenience: map a whole (t, node_inputs) stream."""
        return [self.tick(t, nodes) for t, nodes in stream]
