"""M4.1 — appliance signature discovery from CSI mechanical spectral lines.

A running appliance (compressor, blower, fan, washer drum) vibrates the
apartment's RF environment: its mechanical fundamental and low harmonics
couple into the CSI amplitude as persistent narrowband lines. This module
continuously catalogs those lines per node and clusters recurring line-sets
into `ApplianceSignature` objects with a duty-rhythm channel (slow on/off of
the lines over minutes) — a passive appliance heartbeat monitor that needs
no plugs, clamps or per-appliance hardware.

Operating envelope:
- Input: gap-interpolated CSI amplitude [t,52] at fs = 100 Hz (CONTRACTS §2).
- Analysis band 10-50 Hz: above the human-motion band (~0.5-10 Hz consumed
  by Gate 1 / vitals) and up to Nyquist. **Aliasing caveat**: Nyquist is
  50 Hz (3000 RPM), so machines spinning faster alias into the band — we
  observe the low-frequency mechanical/vibration coupling and the on/off
  duty rhythm of an appliance, NOT its exact RPM. Line frequencies are
  fingerprints for re-identification, not tachometer readings.
- PSD: 10 s Hann periodogram per segment, incoherently averaged across the
  52 subcarriers (Welch-style averaging across the frequency-diverse
  subchannels), 0.1 Hz bin resolution. Presence/duty is judged at 10 s
  segment granularity.
- Clustering: greedy, deterministic — lines whose on/off presence patterns
  match (Jaccard >= threshold) are one appliance. Signature membership can
  be refined as patterns diverge (e.g. a fridge and a fan look identical
  until the fridge first cycles off), which may revise a signature's early
  history.
- Auto-labels are heuristic *suggestions* with confidence, renameable via
  `rename()` (renames stick). Real-appliance clustering accuracy is
  hardware-gated: synthetic tests validate the mechanism, not field recall.
- Bus topics (payloads are plain scalars, EventLog-safe):
  `machine.discovered` {signature_id, node_id, label, confidence, lines, t}
  `machine.state`      {signature_id, state: "on"|"off", t}
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

BAND_LO = 10.0
BAND_HI = 50.0
SEG_S = 10.0


@dataclass
class ApplianceSignature:
    """One discovered appliance: its spectral lines + duty statistics."""

    signature_id: str
    node_id: int
    line_ids: list[int]
    lines_hz: list[float] = field(default_factory=list)
    label: str = "unknown"
    confidence: float = 0.0
    user_labeled: bool = False
    on: bool = False
    first_seen: float = 0.0
    last_seen: float = 0.0
    duty_fraction: float = 0.0
    cycle_period_s: float = float("nan")
    n_on_starts: int = 0
    # one record per PSD segment since t0: {t, on, center_hz, width_hz, power}
    history: list[dict] = field(default_factory=list)


class _Line:
    """Tracker for one narrowband spectral line on one node."""

    __slots__ = ("id", "center", "width", "power", "first_idx",
                 "present", "freqs", "widths", "powers")

    def __init__(self, lid: int, idx: int, f: float, w: float, p: float) -> None:
        self.id = lid
        self.center, self.width, self.power = f, w, p
        self.first_idx = idx
        self.present = [False] * idx + [True]
        self.freqs = [0.0] * idx + [f]
        self.widths = [0.0] * idx + [w]
        self.powers = [0.0] * idx + [p]

    def update(self, f: float, w: float, p: float, a: float) -> None:
        self.center = (1 - a) * self.center + a * f
        self.width = (1 - a) * self.width + a * w
        self.power = (1 - a) * self.power + a * p
        self.present.append(True)
        self.freqs.append(f)
        self.widths.append(w)
        self.powers.append(p)

    def absent(self) -> None:
        self.present.append(False)
        self.freqs.append(0.0)
        self.widths.append(0.0)
        self.powers.append(0.0)

    @property
    def n_present(self) -> int:
        return sum(self.present)


class _NodeState:
    __slots__ = ("t0", "buf", "n_segs", "seg_times", "lines",
                 "next_line", "sigs", "sig_order", "next_sig")

    def __init__(self, t0: float) -> None:
        self.t0 = t0
        self.buf: np.ndarray | None = None
        self.n_segs = 0
        self.seg_times: list[float] = []
        self.lines: dict[int, _Line] = {}
        self.next_line = 0
        self.sigs: dict[str, ApplianceSignature] = {}
        self.sig_order: list[str] = []
        self.next_sig = 0


class SpectraProfiler:
    """Streaming appliance-signature profiler (see module docstring)."""

    def __init__(self, fs: float = 100.0, bus=None, seg_s: float = SEG_S,
                 snr_k: float = 8.0, match_tol_hz: float = 1.0,
                 min_present: int = 2, cluster_jaccard: float = 0.8,
                 ewma_alpha: float = 0.25) -> None:
        self.fs = float(fs)
        self.bus = bus
        self.seg_len = int(round(seg_s * fs))
        self.seg_s = self.seg_len / self.fs
        self.snr_k = float(snr_k)
        self.match_tol_hz = float(match_tol_hz)
        self.min_present = int(min_present)
        self.cluster_jaccard = float(cluster_jaccard)
        self.alpha = float(ewma_alpha)
        self._win = np.hanning(self.seg_len)
        freqs = np.fft.rfftfreq(self.seg_len, 1.0 / self.fs)
        self._band = (freqs >= BAND_LO) & (freqs <= BAND_HI)
        self._freqs = freqs[self._band]
        self._df = self.fs / self.seg_len
        self._nodes: dict[int, _NodeState] = {}

    # -- ingestion ----------------------------------------------------------

    def push(self, node_id: int, rows: np.ndarray,
             t0: float | None = None) -> list[tuple[str, dict]]:
        """Feed one row [52] or a chunk [m,52]; processes each completed
        10 s segment. Returns the (topic, payload) events generated (also
        published on the bus, if any). `t0` sets the time origin of the
        node's stream on first contact."""
        rows = np.atleast_2d(np.asarray(rows, np.float64))
        st = self._nodes.get(node_id)
        if st is None:
            st = _NodeState(0.0 if t0 is None else float(t0))
            self._nodes[node_id] = st
        st.buf = rows if st.buf is None or st.buf.size == 0 else np.vstack([st.buf, rows])
        events: list[tuple[str, dict]] = []
        while st.buf.shape[0] >= self.seg_len:
            seg = st.buf[: self.seg_len]
            st.buf = st.buf[self.seg_len:]
            t_seg = st.t0 + st.n_segs * self.seg_s
            events += self._process_segment(node_id, st, seg, t_seg)
        return events

    def process(self, node_id: int, window: np.ndarray,
                t0: float | None = None) -> list[tuple[str, dict]]:
        """Batch variant of push(); windows shorter than 10 s are buffered."""
        return self.push(node_id, window, t0=t0)

    # -- catalog ------------------------------------------------------------

    def catalog(self) -> list[ApplianceSignature]:
        """All discovered signatures across nodes (stable order)."""
        out: list[ApplianceSignature] = []
        for nid in sorted(self._nodes):
            st = self._nodes[nid]
            out.extend(st.sigs[sid] for sid in st.sig_order)
        return out

    def rename(self, signature_id: str, label: str) -> None:
        """User rename: pins the label (auto-labeling stops for this sig)."""
        for st in self._nodes.values():
            if signature_id in st.sigs:
                sig = st.sigs[signature_id]
                sig.label = label
                sig.user_labeled = True
                sig.confidence = 1.0
                return
        raise KeyError(f"unknown signature {signature_id!r}")

    # -- internals ----------------------------------------------------------

    def _process_segment(self, nid: int, st: _NodeState, seg: np.ndarray,
                         t_seg: float) -> list[tuple[str, dict]]:
        p = self._psd(seg)
        obs = self._peaks(p)
        idx = st.n_segs
        st.seg_times.append(t_seg)
        st.n_segs += 1
        updated: set[int] = set()
        for power, f0, width in sorted(obs, key=lambda o: (-o[0], o[1])):
            best, best_d = None, self.match_tol_hz
            for ln in st.lines.values():
                if ln.id in updated:
                    continue
                d = abs(ln.center - f0)
                if d < best_d:
                    best_d, best = d, ln
            if best is None:
                ln = _Line(st.next_line, idx, f0, width, power)
                st.lines[ln.id] = ln
                st.next_line += 1
                updated.add(ln.id)
            else:
                best.update(f0, width, power, self.alpha)
                updated.add(best.id)
        for ln in st.lines.values():
            if ln.id not in updated:
                ln.absent()
        return self._recluster(nid, st)

    def _psd(self, seg: np.ndarray) -> np.ndarray:
        """Band-restricted PSD: Hann periodogram averaged across subcarriers."""
        x = seg - seg.mean(axis=0, keepdims=True)
        X = np.fft.rfft(x * self._win[:, None], axis=0)
        P = (np.abs(X) ** 2).mean(axis=1)
        return P[self._band]

    def _peaks(self, p: np.ndarray) -> list[tuple[float, float, float]]:
        """Supra-threshold contiguous regions -> (power, centroid_hz, width)."""
        nf = float(np.median(p))
        thr = nf * self.snr_k + 1e-15
        mask = p > thr
        if not mask.any():
            return []
        d = np.diff(mask.astype(np.int8))
        starts = list(np.flatnonzero(d == 1) + 1)
        ends = list(np.flatnonzero(d == -1) + 1)
        if mask[0]:
            starts = [0] + starts
        if mask[-1]:
            ends = ends + [mask.size]
        obs = []
        for i0, i1 in zip(starts, ends):
            reg = p[i0:i1]
            pk = float(reg.max())
            sel = np.flatnonzero(reg >= 0.5 * pk) + i0
            w = p[sel]
            f0 = float((self._freqs[sel] * w).sum() / w.sum())
            width = float(max(self._df, sel.size * self._df))
            power = float(reg.sum() * self._df)
            obs.append((power, f0, width))
        return obs

    def _recluster(self, nid: int, st: _NodeState) -> list[tuple[str, dict]]:
        elig = [ln for ln in st.lines.values() if ln.n_present >= self.min_present]
        elig.sort(key=lambda ln: (ln.first_idx, ln.center))
        pres = {ln.id: np.asarray(ln.present, bool) for ln in elig}
        clusters: list[list[_Line]] = []
        used: set[int] = set()
        for ln in elig:
            if ln.id in used:
                continue
            cl = [ln]
            used.add(ln.id)
            a = pres[ln.id]
            for other in elig:
                if other.id in used:
                    continue
                b = pres[other.id]
                union = int(np.count_nonzero(a | b))
                if union and np.count_nonzero(a & b) / union >= self.cluster_jaccard:
                    cl.append(other)
                    used.add(other.id)
            clusters.append(cl)
        events: list[tuple[str, dict]] = []
        claimed: set[str] = set()
        for cl in clusters:
            lids = sorted(l.id for l in cl)
            best, best_ov = None, 0
            for sid in st.sig_order:
                if sid in claimed:
                    continue
                ov = len(set(lids) & set(st.sigs[sid].line_ids))
                if ov > best_ov:
                    best_ov, best = ov, sid
            created = best is None
            if created:
                sid = f"n{nid}-a{st.next_sig}"
                st.next_sig += 1
                sig = ApplianceSignature(signature_id=sid, node_id=nid, line_ids=lids)
                st.sigs[sid] = sig
                st.sig_order.append(sid)
            else:
                sid = best
                sig = st.sigs[sid]
                sig.line_ids = lids
            claimed.add(sid)
            events += self._refresh(st, sig, cl, created)
        return events

    def _refresh(self, st: _NodeState, sig: ApplianceSignature,
                 cl: list[_Line], created: bool) -> list[tuple[str, dict]]:
        n = st.n_segs
        m = len(cl)
        pres = np.zeros((m, n), bool)
        fr = np.zeros((m, n))
        wd = np.zeros((m, n))
        pw = np.zeros((m, n))
        for j, ln in enumerate(cl):
            pres[j] = ln.present
            fr[j] = ln.freqs
            wd[j] = ln.widths
            pw[j] = ln.powers
        cnt = pres.sum(axis=0)
        on = cnt >= max(1.0, m / 2.0)
        denom = np.maximum(cnt, 1)
        center = (fr * pres).sum(axis=0) / denom
        width = (wd * pres).sum(axis=0) / denom
        power = (pw * pres).sum(axis=0)
        times = np.asarray(st.seg_times)
        sig.history = [
            {"t": float(times[i]), "on": bool(on[i]), "center_hz": float(center[i]),
             "width_hz": float(width[i]), "power": float(power[i])}
            for i in range(n)
        ]
        sig.lines_hz = [float(ln.center) for ln in cl]
        sig.duty_fraction = float(on.mean()) if n else 0.0
        on_idx = np.flatnonzero(on)
        starts = [int(i) for i in on_idx if i == 0 or not on[i - 1]]
        sig.n_on_starts = len(starts)
        sig.cycle_period_s = (float(np.median(np.diff(times[starts])))
                              if len(starts) >= 2 else float("nan"))
        if on_idx.size:
            sig.first_seen = float(times[on_idx[0]])
            sig.last_seen = float(times[on_idx[-1]] + self.seg_s)
        mean_width = float((wd * pres).sum() / max(int(pres.sum()), 1))
        if not sig.user_labeled:
            sig.label, sig.confidence = self._auto_label(
                sig.duty_fraction, m, sig.n_on_starts, sig.cycle_period_s,
                mean_width, n * self.seg_s)
        cur = bool(on[-1]) if n else False
        t_now = float(times[-1]) if n else 0.0
        events: list[tuple[str, dict]] = []
        if created:
            events.append(self._publish("machine.discovered", {
                "signature_id": sig.signature_id, "node_id": sig.node_id,
                "label": sig.label, "confidence": round(sig.confidence, 2),
                "lines": [round(f, 2) for f in sig.lines_hz], "t": t_now}))
            if cur:
                events.append(self._publish("machine.state", {
                    "signature_id": sig.signature_id, "state": "on", "t": t_now}))
        elif cur != sig.on:
            events.append(self._publish("machine.state", {
                "signature_id": sig.signature_id,
                "state": "on" if cur else "off", "t": t_now}))
        sig.on = cur
        return events

    def _auto_label(self, duty: float, n_lines: int, n_on_starts: int,
                    period_s: float, width_hz: float,
                    obs_s: float) -> tuple[str, float]:
        """Duty-pattern label heuristics (suggestions, renameable):
        fridge = 15-45 min compressor cycles; HVAC blower = long steady +
        broadband; washer = multi-line multi-phase cycling (spin-up chirp
        detection is future work); fan = constant single narrow line."""
        if duty >= 0.9 and obs_s >= 3 * self.seg_s:
            if width_hz > 2.0 or n_lines >= 3:
                return "hvac-blower", 0.55
            if n_lines == 1:
                return "fan", 0.7
            return "hvac-blower", 0.5
        if n_on_starts >= 2 and math.isfinite(period_s):
            if 900.0 <= period_s <= 2700.0 and 0.15 <= duty <= 0.85:
                return "fridge", 0.75
            if n_lines >= 2:
                return "washer", 0.45
            return "unknown", 0.3
        return "unknown", 0.2

    def _publish(self, topic: str, payload: dict) -> tuple[str, dict]:
        if self.bus is not None:
            self.bus.publish(topic, payload)
        return (topic, payload)
