"""Session file format — record / replay / label container (CONTRACTS.md §3).

Operating envelope: a `.vigil` session is a compressed NPZ (zip) holding
gap-interpolated per-node CSI amplitude at a uniform 100 Hz, plus JSON
members for metadata, hotkey labels, and reference vitals series. It is the
single format shared by the recorder (B4), the fall/vitals benchmarks
(C4/E3) and Demo Mode replay (E1). Replay is deterministic: same file, same
frame sequence, no wall-clock dependence.
"""

from __future__ import annotations

import io
import json
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

import numpy as np

from .frame import Frame, N_SUB

LABELS = [
    "fall-fast",
    "fall-slow",
    "fall-slide",
    "sit-hard",
    "object-drop",
    "pet",
    "walk",
    "still",
    "breathing-ref",
    "hr-ref",
]
FALL_LABELS = {"fall-fast", "fall-slow", "fall-slide"}
CONFOUNDER_LABELS = {"sit-hard", "object-drop", "pet", "walk"}


@dataclass
class Label:
    t0: float
    t1: float
    label: str
    node_id: int | None = None

    def to_dict(self) -> dict:
        d = {"t0": self.t0, "t1": self.t1, "label": self.label}
        if self.node_id is not None:
            d["node_id"] = self.node_id
        return d


@dataclass
class Session:
    """In-memory session: per-node uniform-rate arrays + labels + refs."""

    fs: float = 100.0
    meta: dict = field(default_factory=dict)
    amps: dict[int, np.ndarray] = field(default_factory=dict)     # [t,52] float32
    rssi: dict[int, np.ndarray] = field(default_factory=dict)     # [t] int8
    seq: dict[int, np.ndarray] = field(default_factory=dict)      # [t] uint32
    ts_us: dict[int, np.ndarray] = field(default_factory=dict)    # [t] uint64
    labels: list[Label] = field(default_factory=list)
    refs: dict[str, list[dict]] = field(default_factory=lambda: {"breathing": [], "hr": []})

    @property
    def node_ids(self) -> list[int]:
        return sorted(self.amps)

    @property
    def duration_s(self) -> float:
        if not self.amps:
            return 0.0
        return max(a.shape[0] for a in self.amps.values()) / self.fs

    def add_label(self, t0: float, t1: float, label: str, node_id: int | None = None) -> None:
        if label not in LABELS:
            raise ValueError(f"unknown label {label!r}; vocabulary: {LABELS}")
        self.labels.append(Label(t0, t1, label, node_id))

    def add_ref(self, kind: str, t: float, bpm: float) -> None:
        if kind not in ("breathing", "hr"):
            raise ValueError("ref kind must be 'breathing' or 'hr'")
        self.refs[kind].append({"t": float(t), "bpm": float(bpm)})

    def import_ref_csv(self, kind: str, path: str | Path, t_col: int = 0, bpm_col: int = 1) -> int:
        """Import timestamped reference CSV (phone metronome / pulse-ox export).

        Expects numeric columns; header lines are skipped. Returns rows added.
        """
        added = 0
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            parts = [p.strip() for p in line.replace(";", ",").split(",")]
            try:
                t, bpm = float(parts[t_col]), float(parts[bpm_col])
            except (ValueError, IndexError):
                continue  # header or malformed line
            self.add_ref(kind, t, bpm)
            added += 1
        return added

    def labels_of(self, *names: str) -> list[Label]:
        want = set(names)
        return [lb for lb in self.labels if lb.label in want]

    def window(self, node_id: int, t0: float, t1: float) -> np.ndarray:
        """Amplitude window [t,52] for a node between t0 and t1 seconds."""
        a = self.amps[node_id]
        i0, i1 = max(0, int(t0 * self.fs)), min(a.shape[0], int(t1 * self.fs))
        return a[i0:i1]

    # -- persistence ------------------------------------------------------

    def save(self, path: str | Path) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        arrays: dict[str, np.ndarray] = {}
        for nid in self.node_ids:
            arrays[f"node{nid}_amps"] = self.amps[nid].astype(np.float32)
            arrays[f"node{nid}_rssi"] = self.rssi.get(nid, np.zeros(0, np.int8))
            arrays[f"node{nid}_seq"] = self.seq.get(nid, np.zeros(0, np.uint32))
            arrays[f"node{nid}_ts_us"] = self.ts_us.get(nid, np.zeros(0, np.uint64))
        buf = io.BytesIO()
        np.savez_compressed(buf, **arrays)
        meta = dict(self.meta)
        meta.update({"version": 1, "fs": self.fs, "duration_s": self.duration_s})
        meta.setdefault("created_utc", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            with zipfile.ZipFile(buf) as npz:
                for name in npz.namelist():
                    z.writestr(name, npz.read(name))
            z.writestr("meta.json", json.dumps(meta, indent=2))
            z.writestr("labels.json", json.dumps([lb.to_dict() for lb in self.labels]))
            z.writestr("refs.json", json.dumps(self.refs))

    @classmethod
    def load(cls, path: str | Path) -> "Session":
        s = cls()
        with zipfile.ZipFile(path) as z:
            meta = json.loads(z.read("meta.json"))
            s.fs = float(meta.get("fs", 100.0))
            s.meta = meta
            s.labels = [
                Label(d["t0"], d["t1"], d["label"], d.get("node_id"))
                for d in json.loads(z.read("labels.json"))
            ]
            s.refs = json.loads(z.read("refs.json"))
            for name in z.namelist():
                if not (name.startswith("node") and name.endswith(".npy")):
                    continue
                key = name[:-4]
                nid_str, kind = key[4:].split("_", 1)
                nid = int(nid_str)
                arr = np.load(io.BytesIO(z.read(name)), allow_pickle=False)
                getattr(s, kind if kind != "amps" else "amps")[nid] = arr
        return s

    # -- replay -----------------------------------------------------------

    def replay(self) -> Iterator[tuple[float, int, Frame]]:
        """Deterministic frame replay: yields (t_seconds, node_id, Frame) in
        global time order. Amplitudes are re-quantized to uint8 as on the wire."""
        heads = []
        for nid in self.node_ids:
            a = self.amps[nid]
            for i in range(a.shape[0]):
                heads.append((i / self.fs, nid, i))
        heads.sort()
        for t, nid, i in heads:
            amps = np.clip(np.round(self.amps[nid][i]), 0, 255).astype(np.uint8)
            rssi = int(self.rssi[nid][i]) if nid in self.rssi and self.rssi[nid].size else -60
            seq = int(self.seq[nid][i]) if nid in self.seq and self.seq[nid].size else i
            ts = int(self.ts_us[nid][i]) if nid in self.ts_us and self.ts_us[nid].size else int(t * 1e6)
            yield t, nid, Frame(nid, seq, rssi, ts, amps)


class SessionWriter:
    """Streaming recorder: append frames per node, hotkey labels, then finalize.

    Frames are accumulated per node and resampled to the uniform grid on
    `finalize()` (nearest-frame; gaps ≤3 frames linearly interpolated, longer
    gaps held at last value and counted in `gap_stats`).
    """

    def __init__(self, fs: float = 100.0, meta: dict | None = None) -> None:
        self.fs = fs
        self.meta = meta or {}
        self._frames: dict[int, list[Frame]] = {}
        self._t0: dict[int, float] = {}
        self._labels: list[Label] = []
        self._refs: dict[str, list[dict]] = {"breathing": [], "hr": []}
        self.gap_stats: dict[int, int] = {}

    def add_frame(self, t: float, frame: Frame) -> None:
        self._frames.setdefault(frame.node_id, []).append(frame)
        self._t0.setdefault(frame.node_id, t)

    def add_label(self, t0: float, t1: float, label: str, node_id: int | None = None) -> None:
        if label not in LABELS:
            raise ValueError(f"unknown label {label!r}")
        self._labels.append(Label(t0, t1, label, node_id))

    def add_ref(self, kind: str, t: float, bpm: float) -> None:
        self._refs[kind].append({"t": float(t), "bpm": float(bpm)})

    def finalize(self) -> Session:
        s = Session(fs=self.fs, meta=dict(self.meta))
        s.labels = list(self._labels)
        s.refs = {k: list(v) for k, v in self._refs.items()}
        for nid, frames in self._frames.items():
            frames.sort(key=lambda f: f.seq)
            n = len(frames)
            amps = np.zeros((n, N_SUB), np.float32)
            rssi = np.zeros(n, np.int8)
            seq = np.zeros(n, np.uint32)
            ts = np.zeros(n, np.uint64)
            gaps = 0
            for i, f in enumerate(frames):
                amps[i] = f.amps
                rssi[i] = f.rssi
                seq[i] = f.seq
                ts[i] = f.ts_us
                if i and f.seq > frames[i - 1].seq + 1:
                    gaps += int(f.seq - frames[i - 1].seq - 1)
            s.amps[nid], s.rssi[nid], s.seq[nid], s.ts_us[nid] = amps, rssi, seq, ts
            self.gap_stats[nid] = gaps
        return s
