"""C4 — Gate 3 fusion: gate1 → room vote → gate2 → stillness → alerts bus.

Operating envelope: streaming state machine per room. Gate-1 candidates per
node are associated across the room's nodes within a 1 s window and put to
a strict majority vote (single-node rooms: 1 vote suffices; 2-of-3 passes,
1-of-3 does not). The best-SNR node (highest mean RSSI over the candidate
window, energy as tie-break/fallback) is classified by Gate 2; a "fall"
verdict then enters stillness confirmation: motion energy must stay below
`stillness_factor` × pre-event quiet level for `stillness_window_s` (15 s).
Motion resuming inside that window downgrades the event
(reason="motion-resumed"). confidence = classifier fall-probability ×
stillness fraction. Publishes gate1.candidate, gate2.classified,
fall.confirmed, fall.downgraded (CONTRACTS §4).

`run_session` is the benchmark harness entry (E3): vigil.cleaning /
vigil.spectral are imported lazily inside it per CONTRACTS §8; while Track
B is in flight it degrades to a local bandpass+RMS motion-energy fallback
(and gate2.spectrogram_window's own fallback) so replay works standalone —
the fallback is not the production feature path. With `classifier=None`
Gate 2 is bypassed (label "fall", prob 1.0): gate1+gate3 only, for plumbing
tests. All numbers from synthetic replay are synthetic-data numbers; real
acceptance awaits recorded B4 sessions.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import numpy as np

from ..bus import EventBus
from ..config import VigilConfig
from ..session import FALL_LABELS, Session
from .gate1 import Candidate, Gate1
from .gate2 import CLASSES

ASSOCIATION_WINDOW_S = 1.0
STILL_FRAC_CONFIRM = 0.9       # fraction of stillness window below threshold
QUIET_LOOKBACK_S = (12.0, 2.0)  # quiet level from [t-12 s, t-2 s]
POST_BURST_GAP_S = 2.0          # stillness window starts this long after peak


def _fallback_motion_energy(amps: np.ndarray, fs: float = 100.0) -> np.ndarray:
    """Standalone motion-energy: static-profile removal, 0.5-12 Hz bandpass,
    RMS across subcarriers, 0.2 s moving average. Mirrors what
    SpectralStage.motion_energy provides in the integrated pipeline."""
    from scipy import signal

    x = np.asarray(amps, dtype=np.float64)
    x = x - np.median(x, axis=0, keepdims=True)
    sos = signal.butter(4, [0.5, 12.0], btype="bandpass", fs=fs, output="sos")
    y = signal.sosfiltfilt(sos, x, axis=0)
    e = np.sqrt(np.mean(y * y, axis=1))
    w = max(1, int(0.2 * fs))
    return np.convolve(e, np.ones(w) / w, mode="same").astype(np.float64)


def _motion_energy_for(amps: np.ndarray, fs: float) -> np.ndarray:
    """Per-node motion energy: B-track CleaningStage+SpectralStage when
    importable (lazy, CONTRACTS §8), else the local fallback."""
    try:
        from ..cleaning import CleaningStage
        from ..spectral import SpectralStage
    except ImportError:
        return _fallback_motion_energy(amps, fs)
    try:
        clean = CleaningStage(fs=fs).process(np.asarray(amps, dtype=np.float32))
        stage = SpectralStage(fs=fs)
        calib_n = min(amps.shape[0], int(10 * fs))
        stage.fit(clean.motion[:calib_n])
        res = stage.transform(clean.motion)
        me = np.asarray(res.motion_energy, dtype=np.float64)
        if me.shape[0] != amps.shape[0]:  # hop-rate series: upsample to 1/sample
            me = np.interp(np.arange(amps.shape[0]),
                           np.linspace(0, amps.shape[0] - 1, me.shape[0]), me)
        return me
    except Exception:
        return _fallback_motion_energy(amps, fs)


def _still_fraction(energy: np.ndarray, fs: float, t_peak: float,
                    window_s: float, factor: float) -> tuple[float, float]:
    """(stillness fraction, quiet level) for the window after `t_peak`."""
    lb0, lb1 = QUIET_LOOKBACK_S
    q0 = max(0, int((t_peak - lb0) * fs))
    q1 = max(0, int((t_peak - lb1) * fs))
    quiet_seg = energy[q0:q1]
    if quiet_seg.size >= int(2 * fs):
        quiet = float(np.median(quiet_seg))
    else:
        quiet = float(np.percentile(energy, 25)) if energy.size else 0.0
    w0 = int((t_peak + POST_BURST_GAP_S) * fs)
    w1 = min(energy.shape[0], w0 + int(window_s * fs))
    seg = energy[w0:w1]
    if seg.size == 0:
        return 0.0, quiet
    thr = max(factor * quiet, quiet + 1e-9)
    return float(np.mean(seg < thr)), quiet


@dataclass
class _Cluster:
    room: str
    t0: float
    cands: dict[int, Candidate] = field(default_factory=dict)  # node -> best cand
    voted: bool = False


class FallPipeline:
    """Gate1 → room-majority vote → Gate2 → stillness gate → bus events."""

    def __init__(self, config: VigilConfig, bus: EventBus,
                 classifier=None, fs: float = 100.0) -> None:
        self.config = config
        self.bus = bus
        self.classifier = classifier
        self.fs = float(fs)
        self.thresholds = config.thresholds
        # streaming state
        self._gates: dict[int, Gate1] = {}
        self._ebuf: dict[int, deque] = {}
        self._n: dict[int, int] = {}
        self._clusters: list[_Cluster] = []
        self._pending_stillness: list[dict] = []
        # optional streaming hook: callable(node_id, t_center) -> spec window
        self.spectrogram_provider = None

    # -- shared helpers -----------------------------------------------------

    def _rooms(self, node_ids: list[int]) -> dict[str, list[int]]:
        if self.config.rooms:
            rooms = {r: [n for n in ids if n in node_ids]
                     for r, ids in self.config.rooms.items()}
            rooms = {r: ids for r, ids in rooms.items() if ids}
            leftover = [n for n in node_ids
                        if not any(n in ids for ids in rooms.values())]
            if leftover:
                rooms.setdefault("room", []).extend(leftover)
            return rooms
        return {"room": list(node_ids)}

    @staticmethod
    def _majority(votes: int, n_nodes: int) -> bool:
        return 2 * votes > n_nodes  # single-node room: 1 vote suffices

    def _emit(self, events: list[dict], topic: str, payload: dict) -> None:
        self.bus.publish(topic, payload)
        events.append({"topic": topic, **payload})

    def _classify(self, events: list[dict], node_id: int, t: float,
                  window) -> tuple[str, float]:
        """Gate 2 on one window; returns (label, fall_prob). classifier=None
        bypasses Gate 2 (documented: gate1+gate3 plumbing only)."""
        if self.classifier is None or window is None:
            return "fall", 1.0
        label, probs = self.classifier.classify(window)
        self._emit(events, "gate2.classified", {
            "node_id": int(node_id), "t": float(t), "label": str(label),
            "probs": [round(float(p), 4) for p in np.asarray(probs).ravel()],
        })
        try:
            fall_prob = float(np.asarray(probs).ravel()[CLASSES.index("fall")])
        except Exception:
            fall_prob = 1.0 if label == "fall" else 0.0
        return str(label), fall_prob

    # -- batch / benchmark entry ---------------------------------------------

    def run_session(self, session: Session) -> list[dict]:
        """Replay a Session through the full chain; publishes bus topics as
        it goes and returns the emitted events as dicts (benchmark entry)."""
        from . import gate2 as gate2_mod  # lazy: pulls scipy only when used

        fs = float(session.fs or self.fs)
        events: list[dict] = []
        energies = {nid: _motion_energy_for(session.amps[nid], fs)
                    for nid in session.node_ids}
        rooms = self._rooms(session.node_ids)
        for room, nids in sorted(rooms.items()):
            all_cands: list[tuple[float, int, Candidate]] = []
            for nid in nids:
                for c in Gate1(self.thresholds, fs=fs).process(energies[nid]):
                    all_cands.append((c.t, nid, c))
                    self._emit(events, "gate1.candidate", {
                        "node_id": int(nid), "t": float(c.t),
                        "energy": round(float(c.energy), 3),
                        "context": f"node{nid}[{c.i0}:{c.i1}]",
                    })
            all_cands.sort(key=lambda x: (x[0], x[1]))
            # associate within 1 s windows
            clusters: list[list[tuple[float, int, Candidate]]] = []
            for item in all_cands:
                if clusters and item[0] - clusters[-1][0][0] <= ASSOCIATION_WINDOW_S:
                    clusters[-1].append(item)
                else:
                    clusters.append([item])
            for cl in clusters:
                votes = {nid for _, nid, _ in cl}
                if not self._majority(len(votes), len(nids)):
                    continue
                # best-SNR node: highest mean RSSI over the context window,
                # candidate energy as fallback/tie-break
                def snr_key(item):
                    t, nid, c = item
                    r = session.rssi.get(nid)
                    if r is not None and r.size:
                        i0, i1 = max(0, c.i0), min(r.size, c.i1)
                        rssi = float(np.mean(r[i0:i1])) if i1 > i0 else -128.0
                    else:
                        rssi = -128.0
                    return (rssi, c.energy)
                t_ev, best_nid, best_c = max(cl, key=snr_key)
                window = None
                if self.classifier is not None:
                    window = gate2_mod.spectrogram_window(session, best_nid, t_ev, fs=fs)
                label, fall_prob = self._classify(events, best_nid, t_ev, window)
                if label != "fall":
                    continue
                frac, quiet = _still_fraction(
                    energies[best_nid], fs, t_ev,
                    self.thresholds.stillness_window_s,
                    self.thresholds.stillness_factor)
                if frac >= STILL_FRAC_CONFIRM:
                    self._emit(events, "fall.confirmed", {
                        "room": room, "t": float(t_ev),
                        "confidence": round(float(fall_prob * frac), 4),
                    })
                else:
                    self._emit(events, "fall.downgraded", {
                        "room": room, "t": float(t_ev),
                        "reason": "motion-resumed",
                    })
        return events

    # -- streaming ------------------------------------------------------------

    def push(self, node_id: int, value: float) -> list[dict]:
        """Streaming variant: feed one motion-energy sample for one node
        (nodes of a room are assumed pushed in lockstep at fs). Gate-2 in
        streaming mode uses `self.spectrogram_provider(node_id, t_center)`
        when set, else Gate 2 is bypassed. Returns events emitted now."""
        events: list[dict] = []
        fs = self.fs
        nid = int(node_id)
        room = self.config.room_of(nid) or "room"
        gate = self._gates.setdefault(nid, Gate1(self.thresholds, fs=fs))
        buf = self._ebuf.setdefault(
            nid, deque(maxlen=int((self.thresholds.stillness_window_s + 45) * fs)))
        buf.append(float(value))
        self._n[nid] = self._n.get(nid, 0) + 1
        now = self._n[nid] / fs
        cand = gate.push(value)
        if cand is not None:
            self._emit(events, "gate1.candidate", {
                "node_id": nid, "t": float(cand.t),
                "energy": round(float(cand.energy), 3),
                "context": f"node{nid}[{cand.i0}:{cand.i1}]",
            })
            for cl in self._clusters:
                if cl.room == room and not cl.voted and cand.t - cl.t0 <= ASSOCIATION_WINDOW_S:
                    cl.cands.setdefault(nid, cand)
                    break
            else:
                self._clusters.append(_Cluster(room=room, t0=cand.t, cands={nid: cand}))
        # mature clusters -> vote -> gate2 -> schedule stillness check
        room_nodes = self.config.rooms.get(room) or [nid]
        for cl in [c for c in self._clusters if c.room == room and not c.voted]:
            if now - cl.t0 <= ASSOCIATION_WINDOW_S + 0.5:
                continue
            cl.voted = True
            if not self._majority(len(cl.cands), len(room_nodes)):
                continue
            best_nid, best_c = max(cl.cands.items(), key=lambda kv: kv[1].energy)
            window = None
            if self.classifier is not None and self.spectrogram_provider is not None:
                window = self.spectrogram_provider(best_nid, best_c.t)
            label, fall_prob = self._classify(events, best_nid, best_c.t, window)
            if label != "fall":
                continue
            self._pending_stillness.append({
                "room": room, "nid": best_nid, "t": best_c.t,
                "fall_prob": fall_prob,
                "deadline": best_c.t + POST_BURST_GAP_S + self.thresholds.stillness_window_s,
            })
        self._clusters = [c for c in self._clusters
                          if not c.voted or now - c.t0 < 60.0]
        for p in [p for p in self._pending_stillness if p["nid"] == nid]:
            if now < p["deadline"]:
                continue
            self._pending_stillness.remove(p)
            base_idx = self._n[nid] - len(buf)
            e = np.asarray(buf)

            def seg(t0: float, t1: float) -> np.ndarray:
                a = max(0, int(t0 * fs) - base_idx)
                b = max(0, min(len(e), int(t1 * fs) - base_idx))
                return e[a:b]

            lb0, lb1 = QUIET_LOOKBACK_S
            quiet_seg = seg(p["t"] - lb0, p["t"] - lb1)
            quiet = float(np.median(quiet_seg)) if quiet_seg.size else float(
                np.percentile(e, 25))
            still = seg(p["t"] + POST_BURST_GAP_S, p["deadline"])
            thr = max(self.thresholds.stillness_factor * quiet, quiet + 1e-9)
            frac = float(np.mean(still < thr)) if still.size else 0.0
            if frac >= STILL_FRAC_CONFIRM:
                self._emit(events, "fall.confirmed", {
                    "room": p["room"], "t": float(p["t"]),
                    "confidence": round(float(p["fall_prob"] * frac), 4),
                })
            else:
                self._emit(events, "fall.downgraded", {
                    "room": p["room"], "t": float(p["t"]),
                    "reason": "motion-resumed",
                })
        return events


# ---------------------------------------------------------------------------
# labeled-session scoring
# ---------------------------------------------------------------------------

def score_session(session: Session, events: list[dict],
                  tolerance_s: float = 5.0) -> dict:
    """Match fall.confirmed events to FALL_LABELS intervals (± tolerance).
    Returns {tp, fp, fn, per_type} — per_type maps each fall label present
    in the session to its {tp, fn}."""
    falls = [lb for lb in session.labels if lb.label in FALL_LABELS]
    confirmed = [e for e in events if e.get("topic") == "fall.confirmed"]
    used = [False] * len(confirmed)
    per_type: dict[str, dict[str, int]] = {}
    tp = fn = 0
    for lb in falls:
        d = per_type.setdefault(lb.label, {"tp": 0, "fn": 0})
        hit = None
        for i, ev in enumerate(confirmed):
            if used[i]:
                continue
            if lb.t0 - tolerance_s <= float(ev["t"]) <= lb.t1 + tolerance_s:
                hit = i
                break
        if hit is None:
            fn += 1
            d["fn"] += 1
        else:
            used[hit] = True
            tp += 1
            d["tp"] += 1
    fp = int(np.sum(~np.asarray(used, dtype=bool))) if confirmed else 0
    return {"tp": tp, "fp": fp, "fn": fn, "per_type": per_type}
