"""Recorder / labeler — capture sessions with hotkey labels and refs (B4).

Operating envelope:

- Sources: either a live `vigil.ingest.IngestDaemon` (trailing-window
  snapshot capture via its ring buffers) or a deterministic replay iterator
  (`Session.replay()` yielding (t, node_id, Frame)). Frames land in a
  `vigil.session.SessionWriter`; the resulting `.vigil` file holds RAW
  amplitudes only — cleaning/spectral stages re-run deterministically on
  replay, and only small scalar stage SUMMARIES are stored in
  `Session.meta["stages"]` (never stage tensors).
- Hotkey labeler: `run_cli()` reads single keypresses in termios cbreak mode
  when stdin is a tty; otherwise (pipes, tests, headless) it degrades to
  line mode where each line is a key, a `ref breathing 14.5` command, or
  `quit`. A label key toggles: first press opens the interval at the current
  record time, second press closes it. Open intervals are closed at
  `finish()`. Keymap: f=fall-fast F=fall-slow s=fall-slide h=sit-hard
  o=object-drop p=pet w=walk q=still b=breathing-ref r=hr-ref. In cbreak
  mode `:` opens a line command; ESC/Ctrl-D quits.
- Reference vitals: `ref breathing 14.5` / `ref hr 62` line commands, or CSV
  import via `Session.import_ref_csv`; `export_ref_csv` writes the matching
  CSV for round-trips.
- `replay_through_pipeline(session)` is the canonical meaning of "replays
  deterministically through the full pipeline": fresh CleaningStage +
  SpectralStage (self-calibrated) per node over the stored uniform-rate
  amplitudes. Same file in -> byte-identical stage outputs (used by tests
  and by Tracks C/E).
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .cleaning import CleaningStage, CleanResult
from .frame import Frame
from .session import Session, SessionWriter
from .spectral import SpectralResult, SpectralStage

KEYMAP = {
    "f": "fall-fast",
    "F": "fall-slow",
    "s": "fall-slide",
    "h": "sit-hard",
    "o": "object-drop",
    "p": "pet",
    "w": "walk",
    "q": "still",
    "b": "breathing-ref",
    "r": "hr-ref",
}


@dataclass
class PipelineResult:
    clean: CleanResult
    spectral: SpectralResult
    evr: np.ndarray  # PCA explained-variance ratio from the fitted stage


def replay_through_pipeline(session: Session, fs: float | None = None
                            ) -> dict[int, PipelineResult]:
    """Run a saved session through CleaningStage + SpectralStage per node.

    Fresh stages each call (spectral self-calibrates on the motion window),
    so the mapping session -> results is pure and deterministic.
    """
    fs = float(fs or session.fs)
    out: dict[int, PipelineResult] = {}
    for nid in session.node_ids:
        clean = CleaningStage(fs=fs).process(session.amps[nid])
        stage = SpectralStage(fs=fs)
        spectral = stage.transform(clean.motion)
        out[nid] = PipelineResult(clean, spectral, stage.explained_variance_ratio_)
    return out


def export_ref_csv(session: Session, kind: str, path: str | Path) -> int:
    """Write a `t_s,bpm` CSV of a reference series; returns rows written.
    Round-trips with Session.import_ref_csv."""
    if kind not in ("breathing", "hr"):
        raise ValueError("ref kind must be 'breathing' or 'hr'")
    rows = session.refs.get(kind, [])
    lines = ["t_s,bpm"] + [f"{r['t']},{r['bpm']}" for r in rows]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(rows)


class Recorder:
    """Record raw frames from a source, label live, summarize stages in meta."""

    def __init__(self, source, fs: float = 100.0, meta: dict | None = None) -> None:
        self.source = source
        self.fs = float(fs)
        self.writer = SessionWriter(fs=self.fs, meta=meta)
        self.now = 0.0                    # current record time (s)
        self.frames = 0
        self._open: dict[str, float] = {}  # label -> t_open

    # -- capture ---------------------------------------------------------

    def record(self, max_seconds: float | None = None) -> int:
        """Consume the source. Replay iterators are drained (optionally up to
        max_seconds); an IngestDaemon source snapshots its trailing
        max_seconds (default: full ring) at call time."""
        if hasattr(self.source, "snapshot") and hasattr(self.source, "stats"):
            return self._record_daemon(max_seconds)
        for t, _nid, frame in self.source:
            if max_seconds is not None and t > max_seconds:
                break
            self.writer.add_frame(t, frame)
            self.now = t
            self.frames += 1
        return self.frames

    def _record_daemon(self, seconds: float | None) -> int:
        daemon = self.source
        seconds = seconds if seconds is not None else daemon.config.ring_buffer_s
        for nid in sorted(daemon.stats()["nodes"]):
            snap = daemon.snapshot(nid, seconds)
            amps, seq, rssi, ts = snap["amps"], snap["seq"], snap["rssi"], snap["ts"]
            n = amps.shape[0]
            for i in range(n):
                amps_u8 = np.clip(np.round(amps[i]), 0, 255).astype(np.uint8)
                f = Frame(nid, int(seq[i]) & 0xFFFFFFFF, int(rssi[i]),
                          int(max(ts[i], 0) * 1e6), amps_u8)
                self.writer.add_frame(i / self.fs, f)
                self.frames += 1
            self.now = max(self.now, n / self.fs)
        return self.frames

    # -- labeling ----------------------------------------------------------

    def toggle_label(self, label: str, t: float | None = None) -> tuple[float, float] | None:
        """Open the label if closed; close it (writing the interval) if open.
        Returns the (t0, t1) interval when closing, else None."""
        t = self.now if t is None else float(t)
        if label in self._open:
            t0 = self._open.pop(label)
            self.writer.add_label(min(t0, t), max(t0, t), label)
            return (min(t0, t), max(t0, t))
        self._open[label] = t
        return None

    def add_ref(self, kind: str, bpm: float, t: float | None = None) -> None:
        self.writer.add_ref(kind, self.now if t is None else float(t), float(bpm))

    def handle_key(self, ch: str, t: float | None = None) -> str | None:
        """Map a hotkey to its label toggle; returns the label or None."""
        label = KEYMAP.get(ch)
        if label is None:
            return None
        self.toggle_label(label, t)
        return label

    def handle_line(self, line: str, t: float | None = None) -> bool:
        """One line-mode command. Returns False when the CLI should exit."""
        line = line.strip()
        if not line:
            return True
        if line in ("quit", "exit"):
            return False
        parts = line.split()
        if parts[0] == "ref" and len(parts) == 3:
            try:
                self.add_ref(parts[1], float(parts[2]), t)
            except (ValueError, KeyError):
                pass
            return True
        if len(line) == 1:
            self.handle_key(line, t)
        return True

    def run_cli(self, stdin=None, stdout=None) -> None:
        """Hotkey loop. termios cbreak single-keypress mode on a tty;
        line mode otherwise (each line = key / `ref kind bpm` / `quit`)."""
        stdin = stdin if stdin is not None else sys.stdin
        stdout = stdout if stdout is not None else sys.stdout
        try:
            is_tty = stdin.isatty()
        except (AttributeError, OSError):
            is_tty = False
        if not is_tty:
            for line in stdin:
                if not self.handle_line(line.rstrip("\n")):
                    break
            return
        import termios
        import tty
        fd = stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setcbreak(fd)
            stdout.write("vigil recorder — keys: " + " ".join(
                f"{k}={v}" for k, v in KEYMAP.items()) + "  :=command  ESC=quit\r\n")
            stdout.flush()
            while True:
                ch = stdin.read(1)
                if not ch or ch in ("\x1b", "\x04"):
                    break
                if ch == ":":
                    buf = ""
                    while True:
                        c2 = stdin.read(1)
                        if not c2 or c2 in ("\n", "\r"):
                            break
                        buf += c2
                    if not self.handle_line(buf):
                        break
                    continue
                label = self.handle_key(ch)
                if label:
                    state = "open" if label in self._open else "closed"
                    stdout.write(f"[{self.now:8.2f}s] {label} {state}\r\n")
                    stdout.flush()
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

    # -- finalize -------------------------------------------------------------

    def finish(self) -> Session:
        """Close open labels, finalize the session, and attach stage summaries
        (scalars only) to Session.meta['stages']."""
        for label in list(self._open):
            self.toggle_label(label, self.now)
        session = self.writer.finalize()
        results = replay_through_pipeline(session, fs=self.fs)
        summaries: dict[str, dict] = {}
        for nid, r in results.items():
            me = r.spectral.motion_energy
            summaries[str(nid)] = {
                "motion_energy_mean": float(me.mean()) if me.size else 0.0,
                "motion_energy_p95": float(np.percentile(me, 95)) if me.size else 0.0,
                "motion_energy_max": float(me.max()) if me.size else 0.0,
                "z_abs_mean": float(np.mean(np.abs(r.clean.z))),
                "pc1_evr": float(r.evr[0]) if r.evr is not None and r.evr.size else 0.0,
                "n_spec_frames": int(r.spectral.spectrogram.shape[0]),
                "self_calibrated": bool(r.spectral.self_calibrated),
            }
        session.meta["stages"] = summaries
        return session

    def save(self, path: str | Path) -> Session:
        session = self.finish()
        session.save(path)
        return session
