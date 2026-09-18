"""Module 6 — "The room is an instrument": CSI motion as music, visuals
and debug audio.

Operating envelope: everything in this package is deterministic and
headless-testable (numpy + stdlib; `mido`/`python-rtmidi` are optional,
guarded). It converts per-node motion features (10 Hz ticks) into:

- `mapping.FieldMapping` -> `MusicFrame` streams (scale-quantized pitch,
  velocity, CC74 timbre, multi-node pan) — the deterministic heart;
- `midi.Performer` + sinks (`MidiOut`, `OscOut`, `NullSink`) — transport
  with strict note-lifetime bookkeeping and a documented ~30 ms latency
  budget;
- `wallpaper.WallpaperFeed`/`WallpaperServer` — eased JSON snapshots over
  SSE for the Live Wallpaper client;
- `field_audio.FieldAudio` — node health audification for the setup
  wizard's placement step.

Perceptual latency and musicality on real hardware (ESP32 fleet + host
synth) are GATED on live measurement; MEASURED here: determinism, message
correctness, envelope dynamics.
"""

from .field_audio import AudioState, FieldAudio, NodeVoice, describe, placement_callback
from .mapping import SCALES, FieldMapping, MusicFrame, analyze_window
from .midi import MidiOut, NullSink, OscOut, Performer, encode_osc
from .wallpaper import EnvelopeFollower, WallpaperFeed, WallpaperServer

__all__ = [
    "AudioState", "EnvelopeFollower", "FieldAudio", "FieldMapping",
    "MidiOut", "MusicFrame", "NodeVoice", "NullSink", "OscOut", "Performer",
    "SCALES", "WallpaperFeed", "WallpaperServer", "analyze_window",
    "describe", "encode_osc", "placement_callback",
]
