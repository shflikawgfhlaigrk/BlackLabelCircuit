"""Field audio — the debug instrument: node health you can *hear*.

Operating envelope: setup/placement aid, not an alarm channel. Consumes the
same per-node health stats the rest of the system already publishes
(`node.health` topic / `IngestDaemon.stats()`: rate_hz, rssi, loss_pct,
plus optional corrupt_pct and congestion) and renders them as audible
semantics through the Module-6 sink abstraction (MIDI or OSC):

- per-node carrier tone: node *index* -> fixed pitch (a stack of fourths),
  so each node keeps a recognizable voice as you walk the house;
- amplitude = link quality (rate x RSSI norm) -> a weak node is quiet;
- roughness/detune = frame loss -> a lossy node wobbles (mod-wheel CC1 +
  detune CC94);
- noise burst = corrupt frames (CC71 noise-mix amount);
- rhythmic ticking = channel congestion (CC80 tick-rate, 0..8 Hz).

A badly placed node is therefore audibly obvious: a weak, wobbly, hissy
tone. `describe()` is a pure function (stats in -> AudioState out) and
carries every claim tested here; how *legible* the sound is to an installer
is GATED on live hardware + a synth patch and is not claimed by tests.

Setup-wizard integration (documented hook — no wizard import): the
placement step calls, at ~1 Hz while the installer walks the room,

    callback(node_stats: dict[int, dict]) -> AudioState

where node_stats is `IngestDaemon.stats()["nodes"]`-shaped
({node_id: {"rate_hz": float, "rssi": int, "loss_pct": float, ...}}).
Build one with `placement_callback(FieldAudio(...))` and pass it to the
wizard's UI layer; call `FieldAudio.stop()` when the step completes.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any, Callable, Mapping

from .mapping import FieldMapping
from .midi import NullSink

CC_ROUGHNESS = 1     # mod wheel: LFO depth -> audible wobble
CC_NOISE = 71        # noise-mix amount
CC_TICK = 80         # rhythmic tick rate (0..127 ~ 0..8 Hz)
CC_DETUNE = 94       # celeste/detune depth
CC_VOLUME = 7

PITCH_STEP = 5       # stack of fourths — distinct, consonant carriers
TICK_HZ_MAX = 8.0

# link-quality normalization anchors (WROOM-32 fleet, CONTRACTS.md rates)
RATE_FULL_HZ = 100.0     # nominal frame rate = full amplitude
RSSI_FLOOR = -90.0       # unusable
RSSI_FULL = -50.0        # saturated link
LOSS_ROUGH_MAX = 25.0    # >= 25 % loss = maximum wobble
CORRUPT_NOISE_MAX = 10.0  # >= 10 % corrupt frames = full noise bed


def _clip01(x: float) -> float:
    return min(max(float(x), 0.0), 1.0)


@dataclass(frozen=True)
class NodeVoice:
    node_id: int
    pitch: int          # MIDI note, fixed per node index
    amplitude: float    # 0..1 link quality
    roughness: float    # 0..1 frame loss
    noise: float        # 0..1 corrupt frames
    tick_hz: float      # 0..8 Hz channel-congestion ticking
    channel: int


@dataclass(frozen=True)
class AudioState:
    voices: tuple[NodeVoice, ...]

    def voice(self, node_id: int) -> NodeVoice | None:
        for v in self.voices:
            if v.node_id == node_id:
                return v
        return None

    def to_json(self) -> str:
        return json.dumps([asdict(v) for v in self.voices],
                          sort_keys=True, separators=(",", ":"))


def describe(node_stats: Mapping[int, Mapping[str, Any]],
             base_pitch: int = 48) -> AudioState:
    """Pure stats -> AudioState mapping (no I/O, no state, deterministic).

    node_stats: {node_id: {"rate_hz": float, "rssi": int dBm,
    "loss_pct": float, "corrupt_pct": optional float,
    "congestion": optional 0..1}}. Input is not mutated.
    """
    voices = []
    for idx, nid in enumerate(sorted(int(n) for n in node_stats)):
        st = node_stats[nid]
        rate_norm = _clip01(float(st.get("rate_hz", 0.0)) / RATE_FULL_HZ)
        rssi_norm = _clip01((float(st.get("rssi", RSSI_FLOOR)) - RSSI_FLOOR)
                            / (RSSI_FULL - RSSI_FLOOR))
        amplitude = round(rate_norm * rssi_norm, 6)
        roughness = round(_clip01(float(st.get("loss_pct", 0.0))
                                  / LOSS_ROUGH_MAX), 6)
        noise = round(_clip01(float(st.get("corrupt_pct", 0.0))
                              / CORRUPT_NOISE_MAX), 6)
        tick_hz = round(TICK_HZ_MAX * _clip01(float(st.get("congestion", 0.0))),
                        6)
        voices.append(NodeVoice(node_id=nid,
                                pitch=int(base_pitch + PITCH_STEP * idx),
                                amplitude=amplitude, roughness=roughness,
                                noise=noise, tick_hz=tick_hz,
                                channel=idx % 16))
    return AudioState(voices=tuple(voices))


class FieldAudio:
    """Drives an audio sink from node health stats via `describe()`.

    Voice lifetime bookkeeping mirrors `Performer`: one carrier note_on per
    node while it is present in the stats, matched note_off when the node
    disappears or `stop()` is called — balanced on/off always.
    """

    def __init__(self, mapping: FieldMapping | None = None,
                 sink: Any | None = None) -> None:
        # mapping only lends its register (base_note + an octave up keeps the
        # debug carriers clear of the instrument's melodic range)
        self.base_pitch = (int(mapping.base_note) + 12) if mapping is not None else 48
        self.sink = sink if sink is not None else NullSink()
        self.state: AudioState = AudioState(voices=())
        self._active: dict[int, NodeVoice] = {}   # node_id -> last voice
        self.notes_on_sent = 0
        self.notes_off_sent = 0

    def update(self, node_stats: Mapping[int, Mapping[str, Any]]
               ) -> AudioState:
        """Render the latest stats. Call at ~1 Hz during placement."""
        state = describe(node_stats, base_pitch=self.base_pitch)
        present = {v.node_id for v in state.voices}
        for nid in [n for n in self._active if n not in present]:
            v = self._active.pop(nid)
            self.sink.note_off(v.pitch, channel=v.channel)
            self.notes_off_sent += 1
        for v in state.voices:
            prev = self._active.get(v.node_id)
            if prev is None:
                self.sink.note_on(v.pitch, self._vel(v.amplitude),
                                  channel=v.channel)
                self.notes_on_sent += 1
            if prev is None or prev.amplitude != v.amplitude:
                self.sink.cc(CC_VOLUME, self._cc7(v.amplitude),
                             channel=v.channel)
            if prev is None or prev.roughness != v.roughness:
                self.sink.cc(CC_ROUGHNESS, self._cc7(v.roughness),
                             channel=v.channel)
                self.sink.cc(CC_DETUNE, self._cc7(v.roughness),
                             channel=v.channel)
            if prev is None or prev.noise != v.noise:
                self.sink.cc(CC_NOISE, self._cc7(v.noise), channel=v.channel)
            if prev is None or prev.tick_hz != v.tick_hz:
                self.sink.cc(CC_TICK, self._cc7(v.tick_hz / TICK_HZ_MAX),
                             channel=v.channel)
            self._active[v.node_id] = v
        self.state = state
        return state

    def stop(self) -> None:
        """Release every carrier (balanced with the note_ons)."""
        for v in list(self._active.values()):
            self.sink.note_off(v.pitch, channel=v.channel)
            self.notes_off_sent += 1
        self._active.clear()

    def close(self) -> None:
        self.stop()
        self.sink.close()

    @staticmethod
    def _vel(amplitude: float) -> int:
        return min(max(int(round(1 + amplitude * 126)), 1), 127)

    @staticmethod
    def _cc7(x: float) -> int:
        return min(max(int(round(_clip01(x) * 127)), 0), 127)


def placement_callback(field_audio: FieldAudio
                       ) -> Callable[[Mapping[int, Mapping]], AudioState]:
    """Setup-wizard placement-step hook (signature documented in the module
    docstring): returns `cb(node_stats) -> AudioState` bound to the given
    FieldAudio. The wizard's UI layer calls it with
    `IngestDaemon.stats()["nodes"]` at ~1 Hz while the installer walks."""
    def cb(node_stats: Mapping[int, Mapping]) -> AudioState:
        return field_audio.update(node_stats)
    return cb
