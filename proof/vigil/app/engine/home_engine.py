"""
Homefront sensing engine — localhost sidecar for the Homefront macOS app.

Runs the WiFi-CSI pipeline and streams the result as JSON over loopback:

    GET /frame    -> latest sensing frame (presence, motion, vitals, 17 keypoints)
    GET /anomaly  -> latest predictive state (learning_baseline | nominal | anomaly)
    GET /baseline -> learned-baseline readiness (nights observed, rest/active buckets)
    GET /fall     -> eldercare fall/emergency state (inactive until live CSI sensing)
    GET /health   -> engine + model status
    GET /         -> human-readable status

Data sources (selected with --source):
    replay  : loop the bundled synthetic CSI capture (dev/demo opt-in; no hardware).
              Proves the full pipeline end-to-end on a developer Mac.
    vigil   : LIVE CSI from the Vigil ESP32 room fleet (udp :5566, real firmware
              wire format) — beacon-per-room links via vigil_source.py.

EVERYTHING is honestly labeled. With replay data there is no real person in the
room, so vitals only report a number when a genuine periodic signal is present
in the band; otherwise they report null (never a fabricated BPM). The pose model
is real (trained weights), but its input here is replay, so the skeleton is a
demo of the pipeline, not a measurement of your room. Plug in an ESP32-S3 and the
same code path becomes live sensing with zero changes above this layer.

The predictive layer (predict.py) ships EMPTY and learns the buyer's own room over
real nights. Until a learned baseline exists (>=3 distinct nights) /anomaly reports
"learning_baseline" and NEVER an anomaly — §5.1 zero-fabrication / §5.2 ship-no-data
honest by construction. The baseline persists to the buyer's local store only
(--store, default ~/Library/Application Support/Homefront/baseline.json); nothing
is bundled.

Clean-room Python port. Pose weights: ruvnet/RuView (MIT) — see NOTICE.
"""

try:
    from . import circuit_port
except ImportError:
    import circuit_port
import argparse
import atexit
import json
import os
import signal
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

import vigil_paths
from pose_infer import PoseNet, load_model, SKELETON_EDGES, KEYPOINT_NAMES
from predict import AnomalyDetector, BaselineModel
from fall_detect import FallMonitor, fall_signals_from_frame

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")


class VigilHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def support_base():
    """The Application Support surface holding the learned baseline (baseline.json),
    a byte-for-byte mirror of Swift's VigilDatabase.baseURL().

    Honors HOMEFRONT_DATA_DIR so a QA/test harness that isolates the workspace cannot
    have the baseline silently resolve to — and overwrite/read — the OWNER's real
    ~/Library/Application Support/Homefront. This is the Application-Support analogue of
    the escape vigil_paths closes for the ~/.vigil surface: a raw expanduser literal here
    routes through nothing and ignores the isolation knob. An empty value counts as UNSET
    (mirrors Swift's `!dir.isEmpty`), so HOMEFRONT_DATA_DIR= cannot redirect state to "".

    NOTE: for THIS surface the override maps to <dir> itself (baseline.json is a sibling of
    workspace.sqlite3, as Swift places it) — NOT <dir>/vigil, which is vigil_paths' mapping
    for the separate ~/.vigil surface. Resolved per-call so an in-process setenv is observed.
    """
    dir = os.environ.get("HOMEFRONT_DATA_DIR")
    if dir:  # empty string -> unset, matching Swift's `!dir.isEmpty`
        return dir
    return circuit_port.app_support("Homefront")


def default_store_path():
    """The buyer's own local store — learned baseline lives here, never bundled."""
    return os.path.join(support_base(), "baseline.json")


def existing_engine_health(host: str, port: int, timeout: float = 0.6):
    """Return /health from an already-running engine, or None.

    Called before constructing Engine so a second app launch can attach to the
    first sidecar without racing the live fleet UDP bind.
    """
    probe_host = "127.0.0.1" if host in ("", "0.0.0.0", "::") else host
    url = f"http://{probe_host}:{int(port)}/health"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            payload = json.loads(resp.read().decode("utf-8"))
            return payload if payload.get("ok") else None
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None


class CSIReplay:
    """Replays the bundled synthetic CSI capture as amplitude + complex CSI frames."""

    def __init__(self, path):
        with open(path) as f:
            doc = json.load(f)
        self.fs = float(doc.get("sampling_rate_hz", 100.0))
        self.subcarriers = int(doc.get("num_subcarriers", 56))
        self.bandwidth_hz = float(doc.get("bandwidth_hz", 20e6))
        frames = doc["frames"]
        amps, csis = [], []
        for fr in frames:
            a = np.asarray(fr["amplitude"], dtype=np.float32)   # [ant, sub]
            p = np.asarray(fr["phase"], dtype=np.float32)
            amps.append(a.mean(axis=0))
            # complex CSI per subcarrier, averaged across antennas
            csis.append((a * np.exp(1j * p)).mean(axis=0))
        self.amp = np.array(amps, dtype=np.float32)              # [T, sub]
        self.csi = np.array(csis, dtype=np.complex64)            # [T, sub]
        self.n = self.amp.shape[0]
        self.i = 0

    def next_frame(self):
        idx = self.i % self.n
        self.i += 1
        return self.amp[idx], self.csi[idx]


class RangeProfiler:
    """Single-link CSI -> range profile (CIR magnitude of the moving component).

    This is honest 'WiFi sonar': an IFFT across subcarriers turns the channel
    frequency response into a channel impulse response, whose taps are reflector
    delays = distances. We subtract a slow background so only MOVING reflectors
    (people) show up. Bearing is unknown from one link, so a peak means "a moving
    reflector at ~R metres", not a point on a map. Full 2D/3D room imaging needs a
    multi-node mesh (RF tomography).
    """

    def __init__(self, subcarriers, bandwidth_hz, nfft=128, keep=48):
        self.bg = None
        self.nfft = nfft
        self.keep = keep
        self.subcarriers = subcarriers
        # distance per IFFT bin ≈ (c/2) * (1 / (subcarrier_spacing * nfft))
        sub_spacing = bandwidth_hz / max(1, subcarriers)
        self.range_res_m = (3e8 / 2.0) / (sub_spacing * nfft)

    def push(self, csi_complex):
        if self.bg is None:
            self.bg = csi_complex.astype(np.complex128).copy()
        self.bg = 0.97 * self.bg + 0.03 * csi_complex
        moving = csi_complex - self.bg
        ir = np.fft.ifft(moving, n=self.nfft)
        mag = np.abs(ir[: self.keep])
        peak = int(np.argmax(mag)) if mag.size else 0
        strength = float(mag[peak] / (np.median(mag) + 1e-9)) if mag.size else 0.0
        m = mag.max()
        norm = (mag / m).tolist() if m > 0 else mag.tolist()
        return {
            "range_profile": [round(v, 4) for v in norm],
            "range_res_m": round(self.range_res_m, 3),
            "range_peak_m": round(peak * self.range_res_m, 2) if strength > 3.0 else None,
            "range_strength": round(strength, 2),
        }


class EngineVitalGate:
    """Accuracy-or-nothing honesty gate for ONE vital band (CHARTER §5.1/§5.2).

    The named, directly unit-testable home of the per-window significance gates and
    the temporal-persistence confirmation that keep a reported BPM honest. A number
    is emitted only when an in-band peak clears EVERY per-window gate AND holds
    (±tol_hz) across K consecutive windows; otherwise the reading is None ("no
    reliable reading"), never an interpolated or marginal value:

      R3a prominence    - in-band peak / in-band median  >= min_prominence.
      R3b SNR floor     - in-band peak / robust broadband median (DC, sub-physio
                          drift and the peak's own neighbourhood excluded) >= min_snr.
      R3c concentration - power in the peak ±1 bins / total in-band power. White
                          noise spreads energy across the band; a real tone
                          concentrates it — the strongest white-noise discriminator.
      R5  drift guard   - a slow non-cardiac oscillation (HVAC / body sway) below the
                          band edge that leaks through the Hann window into the lowest
                          in-band bin is rejected (drift_ref_hz=0 disables it).
      R2  persistence   - the peak frequency must hold (±tol_hz) across persist_k
                          consecutive confirmed windows before any BPM is emitted.

    Extracted verbatim from Vitals._band_candidate/_confirm; the arithmetic is
    byte-equivalent, so any spectrum the inline path accepted (or rejected) is
    accepted (or rejected) identically here. R1 occupancy stays in Vitals.snapshot
    (it resets the gate via reset() on an empty room)."""

    def __init__(self, lo_hz, hi_hz, min_prominence, min_snr, min_concentration,
                 tol_hz, persist_k, drift_ref_hz=0.0, subharmonic_guard=False):
        # subharmonic_guard: breathing only — see candidate(). The cardiac band
        # must NOT enable it (a real 2x heart rate is out of band anyway, and
        # re-picking there would fabricate tachycardia from a harmonic).
        self.subharmonic_guard = bool(subharmonic_guard)
        self.lo_hz = lo_hz
        self.hi_hz = hi_hz
        self.min_prominence = min_prominence
        self.min_snr = min_snr
        self.min_concentration = min_concentration
        self.tol_hz = tol_hz
        self.drift_ref_hz = drift_ref_hz
        self.persist_k = max(1, int(persist_k))
        self._hist = deque(maxlen=self.persist_k)

    def reset(self):
        """Clear the persistence history (an empty/unoccupied room, per R1) so a
        transient can never carry a stale BPM across a gap."""
        self._hist.clear()

    def candidate(self, freqs, spec, notch_hz=()):
        """Candidate (freq_hz, snr) for the dominant in-band peak that clears every
        per-window gate, else (None, snr). Persistence (R2) is applied by confirm().
        notch_hz: frequencies to excise (±half-width) before the pick — the heart
        band uses it to reject breathing harmonics (e.g. 18 br/min × 3 = 0.9 Hz
        lands mid-cardiac and reads as a plausible 54 bpm)."""
        lo_hz, hi_hz = self.lo_hz, self.hi_hz
        if notch_hz:
            spec = spec.copy()
            # notch half-width tracks the window's bin width: Hann leakage
            # puts harmonic power one bin off-centre, and a fixed ±0.06 Hz
            # missed the 0.875 bin of a 0.9 Hz harmonic at 8 s windows
            # (bin 0.125 Hz) — it read back as a fake 52.5 bpm (test-caught).
            half = max(0.06, 1.25 * float(freqs[1] - freqs[0])) \
                if freqs.size > 1 else 0.06
            for f0 in notch_hz:
                if f0 and lo_hz - 0.2 <= f0 <= hi_hz + 0.2:
                    spec[np.abs(freqs - f0) <= half] = 0.0
        band = (freqs >= lo_hz) & (freqs <= hi_hz)
        if not band.any():
            return None, 0.0
        band_spec = spec[band]
        if band_spec.max() <= 0:
            return None, 0.0
        peak_idx = int(np.where(band)[0][int(np.argmax(band_spec))])
        peak = float(spec[peak_idx])
        # R3a relative gate: prominence vs the in-band median (original behaviour)
        in_band_med = float(np.median(band_spec)) + 1e-9
        prominence = peak / in_band_med
        # R3b absolute gate: SNR vs a robust BROADBAND noise floor, excluding DC,
        # sub-physiological drift, and the peak own neighbourhood (so a strong
        # tone cannot inflate the floor it is measured against).
        ref = (freqs >= 0.05)
        ref[max(0, peak_idx - 2): peak_idx + 3] = False
        noise_floor = (float(np.median(spec[ref])) + 1e-9) if ref.any() else in_band_med
        snr = peak / noise_floor
        # R3c spectral concentration: fraction of in-band POWER in the peak +/-1 bins.
        power = band_spec.astype(np.float64) ** 2
        local = int(np.argmax(band_spec))
        lo_l, hi_l = max(0, local - 1), min(power.size, local + 2)
        concentration = float(power[lo_l:hi_l].sum() / (power.sum() + 1e-12))
        # Why a window was rejected is otherwise invisible from outside — and
        # tuning a gate you cannot see fail is how thresholds get guessed
        # (2026-07-26). Record every metric with its own verdict.
        self.last_metrics = {
            "peak_hz": round(float(freqs[peak_idx]), 4),
            "prominence": round(prominence, 2), "min_prominence": self.min_prominence,
            "snr": round(snr, 2), "min_snr": self.min_snr,
            "concentration": round(concentration, 3),
            "min_concentration": self.min_concentration,
            "fails": [k for k, bad in (
                ("prominence", prominence < self.min_prominence),
                ("snr", snr < self.min_snr),
                ("concentration", concentration < self.min_concentration)) if bad],
        }
        if (prominence < self.min_prominence or snr < self.min_snr
                or concentration < self.min_concentration):
            return None, snr        # no significant periodicity -> honest null
        # R5 sub-physiological drift guard. A slow non-cardiac oscillation (HVAC,
        # body sway) below the band edge leaks energy through the Hann window into
        # the adjacent lowest in-band bin and can masquerade as a slow breath. If
        # the accepted peak sits in the lowest in-band bin(s) AND the reference band
        # [drift_ref_hz, lo_hz) carries comparable-or-greater energy, it is drift
        # bleed, not a vital -> honest null. (drift_ref_hz=0 disables; heart off.)
        if self.drift_ref_hz > 0.0 and freqs.size > 1:
            bin_w = float(freqs[1] - freqs[0])
            if (float(freqs[peak_idx]) - lo_hz) <= 1.5 * bin_w:
                sub = (freqs >= self.drift_ref_hz) & (freqs < lo_hz)
                if sub.any() and float(spec[sub].max()) >= 0.8 * peak:
                    return None, snr
        return float(freqs[peak_idx]), snr

    def confirm(self, freq_hz):
        """R2: only emit a BPM after persist_k consecutive windows agree (±tol_hz)."""
        # HARMONIC FOLDING (Founder-caught 2026-07-26: breathing alternated
        # between 7.5 and 15.0 bpm — an exact 2:1 — and therefore CONFIRMED
        # ALMOST NEVER: consecutive windows disagreed by a factor of two, so
        # persistence rejected both and the reading dropped out for up to 18 s
        # at a time. Breathing is not sinusoidal, so window-to-window the
        # spectral peak can sit on f or on f/2. When the new pick is within
        # tolerance of exactly half or double the rate already established,
        # it is the SAME breath folded onto a harmonic — fold it back so
        # persistence sees agreement instead of a contradiction. Guarded to
        # the breathing gate: on the cardiac band this would fabricate a
        # doubled heart rate.
        if (self.subharmonic_guard and freq_hz and self._hist):
            prior = [f for f in self._hist if f]
            if prior:
                est = float(np.median(prior))
                # RATIO test, not absolute: an absolute window folded a real
                # 0.20 -> 0.30 Hz change because HALF of 0.30 landed within
                # tol of 0.20 (test-caught). A harmonic is a ratio of exactly
                # 2 or 1/2; 8% tolerance admits window jitter and nothing else
                # (1.5x, a real rate change, is 25% away and stays untouched).
                if est > 0:
                    ratio = freq_hz / est
                    if abs(ratio - 2.0) <= 0.16:
                        freq_hz = freq_hz * 0.5
                    elif abs(ratio - 0.5) <= 0.04:
                        freq_hz = freq_hz * 2.0
        self._hist.append(freq_hz)
        recent = list(self._hist)
        if (freq_hz is None or len(recent) < self.persist_k
                or any(f is None for f in recent[-self.persist_k:])):
            return None
        window = recent[-self.persist_k:]
        if max(window) - min(window) > self.tol_hz:
            return None
        return float(np.median(window) * 60.0)


class Vitals:
    """Honest band-power vital-sign + presence/motion estimator over a CSI buffer.

    Accuracy-or-nothing (CHARTER 5.1/5.2). A BPM is reported only when a genuine
    periodic signal clears EVERY gate below; otherwise the value is None ("no
    reliable reading"), never an interpolated or marginal number:

      R1  occupancy     - the room must be genuinely occupied (the caller passes a
                          real occupancy signal: a moving reflector at range /
                          detected pose). A heart rate in an empty room is the
                          eldercare fabrication failure mode. An unoccupied room
                          also clears the persistence history so a transient can
                          never carry a stale BPM across an empty gap.
      R3a prominence    - in-band peak / in-band median  >= min_prominence.
      R3b SNR floor     - in-band peak / robust broadband median (DC, sub-physio
                          drift and the peak own neighbourhood excluded) >= min_snr.
      R3c concentration - power in the peak +/-1 bins / total in-band power.
                          White noise spreads energy across the band; a real tone
                          concentrates it. The strongest white-noise discriminator.
      R2  persistence   - the peak frequency must hold (+/-tol) across K consecutive
                          windows before any BPM is emitted; a single spurious
                          window never surfaces a number.

    Detrend is degree-2 (removes the curved sub-band drift a linear detrend leaves
    inside the breathing band - HVAC / slow body sway) under a Hann window.
    """

    def __init__(self, fs, subcarriers, buf_seconds=8.0, breath_seconds=16.0,
                 persist_k=3):
        self.fs = fs
        # Heart uses an 8 s window (fine resolution at 0.83-2.0 Hz). Breathing uses
        # a longer 16 s window: at fs=12 this halves the FFT bin width (0.125->0.0625
        # Hz) so the 0.1 Hz band edge is resolved from sub-physiological drift and a
        # sub-physio reference bin exists for the R5 drift guard. One deque sized for
        # the longer need; each band reads the most-recent slice it requires.
        self._buf_seconds = float(buf_seconds)
        self._breath_seconds = float(breath_seconds)
        self.heart_n = max(1, int(fs * buf_seconds))
        self.breath_n = max(self.heart_n, int(fs * breath_seconds))
        self.maxlen = self.breath_n
        self.scalar = deque(maxlen=self.maxlen)   # mean amplitude per frame
        self.prev = None
        self.motion_ema = 0.0
        # R2 temporal persistence lives in the per-band honesty gates. Each gate owns
        # its band config (R3a/R3b/R3c thresholds, R5 drift ref) + persistence window;
        # snapshot() drives them so the accuracy-or-nothing contract is one named type.
        self.persist_k = max(1, int(persist_k))
        self.breathing_gate = EngineVitalGate(
            0.1, 0.5, min_prominence=1.5, min_snr=4.0, min_concentration=0.55,
            tol_hz=0.06, persist_k=persist_k, drift_ref_hz=0.03, subharmonic_guard=True)   # 6-30 br/min
        self.heart_gate = EngineVitalGate(
            0.83, 2.0, min_prominence=4.0, min_snr=5.0, min_concentration=0.55,
            tol_hz=0.10, persist_k=persist_k, drift_ref_hz=0.0)    # 50-120 bpm

    # -- subcarrier selection (vital-band SNR beats blind averaging) ----------
    #
    # A vital modulates each subcarrier with its own gain/sign; the blind
    # 52-bin mean lets antiphase fading CANCEL the signal before the FFT
    # ever sees it. The engine periodically fits a top-k mask of the
    # subcarriers that actually carry vital-band power (set_mask) and push()
    # averages only those. On mask change the scalar buffer is REBUILT from
    # the raw ring so the spectrum never sees a mask-switch step.

    sub_mask = None
    sub_sign = None
    sub_weight = None

    @staticmethod
    def select_subcarriers(rows, fs, lo=0.08, hi=0.6, k=8):
        """(mask, signs): top-k subcarriers by vital-band SNR over rows
        [T, 52], with a coherence SIGN per pick — a vital modulates
        subcarriers with opposing phases, so an unsigned mean cancels the
        very signal the mask selected (synthetic-test-caught). Signs come
        from correlation against the strongest pick. None when the window
        is too short to judge (~8 s minimum)."""
        if rows is None or rows.shape[0] < int(8 * fs):
            return None
        x = rows.astype(np.float64)
        x = x - x.mean(axis=0, keepdims=True)
        spec = np.abs(np.fft.rfft(x * np.hanning(x.shape[0])[:, None], axis=0))
        freqs = np.fft.rfftfreq(x.shape[0], d=1.0 / fs)
        band = (freqs >= lo) & (freqs <= hi)
        if band.sum() < 3:
            return None
        bs = spec[band]
        snr = bs.max(axis=0) / (np.median(bs, axis=0) + 1e-9)
        order = np.argsort(snr)[-int(k):]
        # DROP NOISE-GRADE PICKS: "top k" always returns k subcarriers even
        # when only three carry anything, and the dead ones dilute the sum.
        # Keep a pick only if it clears the median subcarrier's SNR by a
        # clear margin; never fall below 3 (a combination needs diversity).
        floor = float(np.median(snr)) * 1.25
        keep = [int(j) for j in order if snr[j] >= floor]
        if len(keep) < 3:
            keep = [int(j) for j in order[-3:]]
        mask = np.sort(np.asarray(keep, dtype=int))
        ref = x[:, mask[int(np.argmax(snr[mask]))]]
        signs = np.array([1.0 if float(x[:, j] @ ref) >= 0 else -1.0
                          for j in mask])
        # SNR WEIGHTS: an unweighted mean lets a subcarrier carrying mostly
        # noise count exactly as much as one carrying a clean breath, which
        # throws away the very selectivity the mask just bought. Weight by
        # SNR excess over unity (a ratio of 1 IS noise) and normalise.
        w = np.clip(snr[mask] - 1.0, 0.0, None)
        w = (w / w.sum()) if w.sum() > 1e-9 else np.full(mask.size, 1.0 / mask.size)
        return mask, signs, w

    def set_mask(self, sel, recent_rows=None):
        """Adopt a (mask, signs) selection; rebuild the scalar history from
        the raw ring rows so the buffer stays step-free across the switch."""
        if sel is None:
            self.sub_mask = self.sub_sign = None
            return
        if len(sel) == 3:
            mask, signs, weights = sel
        else:                                   # legacy 2-tuple
            mask, signs = sel
            weights = np.full(len(mask), 1.0 / max(len(mask), 1))
        new = np.asarray(mask, dtype=int)
        sg = np.asarray(signs, dtype=np.float64)
        wt = np.asarray(weights, dtype=np.float64)
        if (self.sub_mask is not None and np.array_equal(self.sub_mask, new)
                and self.sub_sign is not None
                and np.array_equal(self.sub_sign, sg)):
            self.sub_weight = wt                # weights may refresh alone
            return
        self.sub_mask, self.sub_sign, self.sub_weight = new, sg, wt
        if recent_rows is not None and len(recent_rows):
            means = (recent_rows[:, new] * sg[None, :] * wt[None, :]).sum(axis=1)
            self.scalar.clear()
            for v in means[-self.maxlen:]:
                self.scalar.append(float(v))

    def set_rate(self, fs):
        """Adopt the link's ACTUAL measured sample rate.

        The vitals FFT was pinned to the source's nominal 100 Hz while the
        fleet really streams 92-180 Hz per node and DRIFTS (live-measured
        2026-07-26). Every frequency was therefore scaled by up to 1.8x, and
        because the rate wanders during a 16 s window the breathing peak
        SMEARS across bins — which fails the spectral-concentration gate by
        construction and is why heart never locked at all (narrower band,
        tighter tolerance). Rate is adopted only on a material change (>8%):
        the window lengths are derived from it, so churn would keep resizing
        the buffer. Buffered samples are kept — they were sampled at very
        nearly this rate, which is the whole point of the threshold."""
        try:
            fs = float(fs)
        except (TypeError, ValueError):
            return
        if not (20.0 <= fs <= 400.0):
            return                      # implausible: keep the current rate
        if abs(fs - self.fs) / max(self.fs, 1e-6) < 0.08:
            return
        self.fs = fs
        self.heart_n = max(1, int(fs * self._buf_seconds))
        self.breath_n = max(self.heart_n, int(fs * self._breath_seconds))
        # Keep every buffered sample: a shrinking window must not throw away
        # the history it is trying to accumulate (live-measured 2026-07-26 —
        # a dipping rate estimate chopped the buffer each time and the window
        # could never reach a target that kept moving).
        self.maxlen = self.breath_n
        keep = list(self.scalar)
        self.scalar = deque(keep[-self.maxlen:] if len(keep) > self.maxlen else keep,
                            maxlen=self.maxlen)

    def push(self, amp_frame):
        if self.sub_mask is None:
            val = float(np.mean(amp_frame))
        elif getattr(self, "sub_weight", None) is not None:
            val = float(np.sum(amp_frame[self.sub_mask] * self.sub_sign
                               * self.sub_weight))
        else:
            val = float(np.mean(amp_frame[self.sub_mask] * self.sub_sign))
        self.scalar.append(val)
        if self.prev is None:
            delta = 0.0
        else:
            delta = float(np.mean(np.abs(amp_frame - self.prev)))
        self.prev = amp_frame
        # normalized motion index, smoothed
        scale = (abs(val) + 1e-6)
        inst = min(1.0, delta / scale * 4.0)
        self.motion_ema = 0.85 * self.motion_ema + 0.15 * inst
        return self.motion_ema

    def _spectrum(self, n_window, min_samples):
        """Detrended, windowed amplitude spectrum over the most-recent n_window
        samples, or (None, None) below min_samples of buffered data."""
        if len(self.scalar) < min_samples:
            return None, None
        x = np.asarray(self.scalar, dtype=np.float64)
        if x.size > n_window:
            x = x[-n_window:]            # most-recent n_window samples
        n = x.size
        x = x - x.mean()
        t = np.arange(n)
        # degree-2 detrend: kill curved sub-band drift that a linear detrend leaves
        # inside the 0.1-0.5 Hz breathing band so drift cannot pose as breathing.
        x = x - np.polyval(np.polyfit(t, x, 2), t)
        win = np.hanning(n)
        spec = np.abs(np.fft.rfft(x * win))
        freqs = np.fft.rfftfreq(n, d=1.0 / self.fs)
        return freqs, spec

    def _reset_persistence(self):
        self.breathing_gate.reset()
        self.heart_gate.reset()

    def _empty(self, present):
        return {
            "present": bool(present),
            "motion": round(self.motion_ema, 3),
            "breathing_bpm": None, "breathing_strength": 0.0,
            "heart_bpm": None, "heart_strength": 0.0,
        }

    def snapshot(self, occupied=None):
        # R1: vitals require a genuinely occupied room. The Engine passes a real
        # occupancy signal (a moving reflector at range / detected pose); with no
        # external signal we fall back to an internal motion proxy. An unoccupied
        # room clears persistence so a transient cannot carry a stale BPM forward.
        internal_present = (self.motion_ema > 0.04
                            or (len(self.scalar) > 0 and float(np.std(self.scalar)) > 1e-3))
        occ = internal_present if occupied is None else bool(occupied)
        if not occ:
            self._reset_persistence()
            return self._empty(False)
        # Breathing FIRST: longer 16 s window (resolves the 0.1 Hz edge) + R5 —
        # the accepted breathing frequency then notches its own harmonics out
        # of the cardiac band below.
        br_freqs, br_spec = self._spectrum(self.breath_n, self.breath_n)
        if br_freqs is None:
            br_f, br_snr = None, 0.0
        else:
            br_f, br_snr = self.breathing_gate.candidate(br_freqs, br_spec)
        # Heart: most-recent 8 s window, breathing harmonics excised.
        notch = ()
        if br_f:
            # 2nd/3rd harmonics only: they carry the real leakage power, and
            # each notch costs 0.12 Hz of a 1.17 Hz cardiac band — notching
            # 4x/5x erased a true 75 bpm that sat on 4x18.75 (test-caught).
            notch = tuple(h * br_f for h in (2, 3) if 0.7 <= h * br_f <= 2.1)
        hr_freqs, hr_spec = self._spectrum(self.heart_n, int(self.fs * 4))
        if hr_freqs is None:
            hr_f, hr_snr = None, 0.0
        else:
            hr_f, hr_snr = self.heart_gate.candidate(hr_freqs, hr_spec, notch_hz=notch)
        breathing_bpm = self.breathing_gate.confirm(br_f)
        heart_bpm = self.heart_gate.confirm(hr_f)
        return {
            "present": bool(occ),
            "motion": round(self.motion_ema, 3),
            "breathing_bpm": round(breathing_bpm, 1) if breathing_bpm else None,
            "breathing_strength": round(br_snr, 2),
            "heart_bpm": round(heart_bpm, 1) if heart_bpm else None,
            "heart_strength": round(hr_snr, 2),
            "vitals_debug": {
                "fs": round(self.fs, 1),
                "buffered": len(self.scalar),
                "need": self.breath_n,
                "motion_ema": round(self.motion_ema, 3),
                "breathing": getattr(self.breathing_gate, "last_metrics", None),
                "heart": getattr(self.heart_gate, "last_metrics", None),
                "breathing_hist": [round(f, 4) if f else None
                                   for f in list(self.breathing_gate._hist)],
            },
        }


# The fall monitor stays in CALIBRATING for this long after live sensing (re)starts,
# covering the vitals/range warmup (breath window ~16 s) so a cold-start transient
# can never mint an alert before the room baseline settles (CHARTER §5.1).
FALL_CALIB_SECS = 20.0


# Eldercare fall safety: after motion-gated occupancy drops, keep the vitals
# engine computing for this long so a motionless-but-present (fallen) body's
# breathing is still measured. Motion-gated presence collapses in seconds; the
# fall monitor's stillness thresholds are in tens of seconds, so without this
# bridge a fallen resident reads as "room empty" before FALL/NO_BREATHING can
# ever fire. Longer than fall_still_secs (45 s) so a FALL can accrue. This does
# NOT weaken §5.1: the EngineVitalGate gates every emitted number, so an empty
# room yields None during the bridge and no vital is invented.
VITALS_STILL_BRIDGE_SECS = 75.0
# Phase-EMA units (radians) are ~2 orders below the amplitude EMA's; this gain
# lands them in the same working range so the RTI floors/sigmas behave
# identically for mixed 0.2.x/0.3.0 fleets. Not a fudge factor: the imager
# normalizes per link, so the gain only matters for cross-link comparability.
_PHASE_GAIN = 100.0


def _fall_inactive(reason):
    """Honest empty fall state when the monitor isn't running on real sensing
    (no CSI reader, or synthetic demo data): never an alert, never a fabricated
    'safe' (CHARTER §5.1)."""
    return {"active": False, "state": "INACTIVE", "alert": None,
            "last_motion_s": None, "last_breath_s": None, "note": reason}


class Engine:
    def __init__(self, source, rate_hz, csi_port=5005, vigil_port=5566, store_path=None, save_every=300):
        self.source = source
        self.rate = rate_hz
        from vigil_heartbeat import VigilHeartbeat
        self._heartbeat = VigilHeartbeat()
        self._heartbeat_next = 0.0
        self.latest_heartbeat = self._heartbeat.status()
        self.model = load_model(os.path.join(ASSETS, "pose_v1.safetensors"))
        if source == "udp":
            from csi_reader import UDPCSISource
            self.src = UDPCSISource(port=csi_port)
        elif source == "vigil":
            from vigil_source import VigilFleetSource
            self.src = VigilFleetSource(port=vigil_port)   # the real ESP32 room fleet (udp :5566 by default)
            self.room_of = self._load_fleet_rooms()
            self._map = None
            from vigil_home import HomeModel
            from vigil_steam import SteamDetector
            from vigil_spectra import SpectraProfiler
            self.home = HomeModel()        # F5–F7: self-mapping/-labeling/-walls
            self.home.room_names = dict(self.room_of)   # paired names win
            import vigil_rti
            self._rti = vigil_rti.RTImager()   # 20-link motion imaging (dot)
            self._home_view = None
            # M2/M4 evidence engines: steam (bathroom) + appliance signatures
            # (kitchen) run per-room on the full-rate rings; their events feed
            # the F5 labeler so rooms can NAME themselves in a real house.
            self._steam = {}               # node_id -> SteamDetector
            self._spectra = SpectraProfiler(fs=100.0)
            # M4 life-safety half: stove-unattended watchdog. Heat-class
            # appliance signatures auto-bind to the room of the node that
            # hears them; alarm when ON for unattended_min with nobody home.
            from vigil_bus import EventBus as _VB
            from vigil_safety import SafetyRules, MachineSafetyConfig, ZoneBinding
            self._vbus = _VB()
            self._safety_cfg = MachineSafetyConfig()
            self._safety = SafetyRules(self._safety_cfg, self._vbus,
                                       room_of=lambda nid: self.room_of.get(int(nid), f"node-{nid}"))
            self._ZoneBinding = ZoneBinding
            self._ev_cursor = {}           # node_id -> ring cursor
            self._events = deque(maxlen=200)   # surfaced life-safety/door feed
            threading.Thread(target=self._event_listener, daemon=True,
                             name="vigil-events").start()
            threading.Thread(target=self._evidence_loop, daemon=True,
                             name="vigil-evidence").start()
            threading.Thread(target=self._map_loop, daemon=True,
                             name="vigil-map").start()
            threading.Thread(target=self._home_loop, daemon=True,
                             name="vigil-home").start()
            self._room_state = {}       # node_id -> {"baseline": float}
            self._occupant = None       # current occupant node_id
            self._challenger = (None, 0)  # (node_id, consecutive ticks)
            self._occ_evidence_mono = 0.0  # monotonic ts of last live excess for the occupant
            self._occ_vitals_mono = 0.0    # monotonic ts of last gate-confirmed vital (frame loop)
            self._occ_mode = None          # occupant provenance: "live" | "holding" | None
        else:
            self.src = CSIReplay(os.path.join(ASSETS, "replay_csi.json"))
        self.vitals = Vitals(self._vitals_fs(), self.src.subcarriers)
        self.ranger = RangeProfiler(self.src.subcarriers, self.src.bandwidth_hz)
        self.window = deque(maxlen=20)   # 20-frame CSI window for the pose net
        self.tick = 0
        self.latest = {"status": "starting"}
        # Pre-serialized /frame body: the 10 Hz app poll must never wait on a
        # ~23 KB json.dumps racing the compute tick for the GIL — serialize once
        # per tick, serve cached bytes (stall-proof under host load).
        self.latest_json = json.dumps(self.latest).encode()
        # --- predictive layer: learns the buyer's own room, ships empty ---
        self.store_path = store_path
        self.save_every = max(0, int(save_every))
        self.detector = self._load_detector()
        self.latest_anomaly = {
            "state": None, "status": "learning_baseline",
            "nights_observed": self.detector.model.nights_observed,
            "nights_required": self.detector.model.min_nights,
            "detail": "no observations yet",
        }
        self.latest_baseline = self.detector.model.summary()
        # --- eldercare fall/emergency layer: real signals only, ships inactive ---
        self.fall = FallMonitor()
        self._fall_feeding = False     # are we feeding the monitor live sensing yet?
        self._fall_feed_start = 0.0    # ts live feeding began (for the calibration warmup)
        self.latest_fall = _fall_inactive("starting — no sensing observation yet")
        self._lock = threading.Lock()
        self._stop = False

    def stop(self):
        self._stop = True
        close = getattr(self.src, "close", None)
        if callable(close):
            close()

    def _heartbeat_tick(self, normal: bool = True, force: bool = False) -> dict:
        """Call the pact heartbeat on startup and then periodically.

        The heartbeat is product state, not display state, so it is wired to the
        sidecar loop instead of a Swift view lifecycle. Failures are persisted
        as status and never take sensing down.
        """
        now = time.time()
        if not force and now < self._heartbeat_next:
            return self.latest_heartbeat
        self._heartbeat_next = now + 300.0
        status = self._heartbeat.tick(normal=normal, force=force)
        self.latest_heartbeat = status
        return status

    _VITALS_STICKY_S = 25.0     # a challenger must lead this long to take over

    def _pick_vitals_node(self, occ_node):
        """The node the vitals buffer follows — deliberately STICKY.

        Vitals need 16 UNBROKEN seconds on ONE link. The occupant election is
        the wrong clock for that: it flips between same-room nodes every few
        seconds, and each flip swaps to a buffer that has aged out and is
        rebuilt, so the window walks backwards instead of filling (measured
        live 2026-07-26: 1583 -> 1329 samples against a 2880 requirement,
        exactly 1 full window in 150 s of solid presence).

        So the vitals node changes only when a DIFFERENT node has held the
        election continuously for _VITALS_STICKY_S — a real room change — and
        never merely because presence blinked. While the occupant is held
        through stillness (occ_node None), the current node is kept: that is
        precisely when a breath is measurable."""
        cur = getattr(self, "_vitals_node", None)
        if occ_node is None:
            return cur                      # hold: stillness is when vitals work
        if cur is None:
            self._vitals_node = occ_node
            self._vit_challenger = (None, 0.0)
            return occ_node
        if occ_node == cur:
            self._vit_challenger = (None, 0.0)
            return cur
        name, since = getattr(self, "_vit_challenger", (None, 0.0))
        now = time.monotonic()
        if name != occ_node:
            self._vit_challenger = (occ_node, now)
            return cur
        if now - since >= self._VITALS_STICKY_S:
            self._vitals_node = occ_node
            self._vit_challenger = (None, 0.0)
            return occ_node
        return cur

    def _vitals_fs(self):
        """Sample rate of the stream Vitals actually sees. The vigil source now
        feeds the FULL 100 Hz rx ring (stream_since), not a per-tick subsample —
        wire-rate resolution is what makes a real breathing/heart peak
        resolvable. replay/udp still push one recorded sample per tick."""
        return float(self.src.fs)

    @staticmethod
    def _load_fleet_rooms():
        """node_id -> room name for beacon links, from the fleet manifest.
        Missing/corrupt manifest degrades to node-N labels — never crashes."""
        path = vigil_paths.state_path("fleet.json")
        rooms = {}
        try:
            with open(path) as f:
                entries = [n for n in json.load(f) if n.get("room")]
            # MULTI-NODE ROOMS (Founder truth 2026-07-26: two pucks share his
            # living room): rooms_view is keyed by room NAME, so duplicate
            # names silently swallow all but one node. When a room name is
            # shared, qualify each with its zone (or node id) — "living ·
            # desk" — so every physical node keeps a visible card and the
            # occupant readout says WHERE in the room.
            by_room = {}
            for n in entries:
                by_room.setdefault(str(n["room"]), []).append(n)
            for room, ns in by_room.items():
                for n in ns:
                    if len(ns) == 1:
                        label = room
                    else:
                        zone = str(n.get("zone") or "").strip()
                        label = f"{room} · {zone}" if zone \
                            else f"{room} · node {int(n['node_id'])}"
                    rooms[int(n["node_id"])] = label
        except Exception:
            pass
        return rooms

    def _map_loop(self):
        """House self-mapping: refresh the MDS layout from the mesh survey
        every 60 s (vigil_map.py). Failures leave the last good map. Uses
        getattr for _stop — this thread starts from __init__ BEFORE the
        engine finishes constructing, and an AttributeError here silently
        killed the thread (app map stayed empty forever)."""
        import vigil_map
        # serve the last persisted layout immediately (restart continuity)
        try:
            with open(vigil_map.GEOMETRY_PATH) as f:
                self._map = json.load(f)
        except Exception:
            pass
        if self._map is not None:      # persisted survey feeds F6 immediately
            try:
                self.home.set_survey_links(
                    self._map.get("links") or {},
                    [int(k) for k in (self._map.get("nodes") or {})])
            except Exception:
                pass
        while not getattr(self, "_stop", False):
            try:
                m = vigil_map.refresh_geometry()
                if m is not None:
                    self._map = m
                    try:
                        # F6 fusion input: the mesh survey's pairwise RSSI
                        self.home.set_survey_links(
                            m.get("links") or {},
                            [int(k) for k in (m.get("nodes") or {})])
                    except Exception:
                        pass
                try:
                    self._home_view = self.home.learned_map()
                    self.home.save()
                except Exception:
                    pass
                # Room names are OWNER data now (app rename writes fleet.json,
                # Founder ask 2026-07-26) — re-read them each map tick so a
                # rename lands without an app restart. Same loader, so the
                # zone-qualification of multi-node rooms is preserved.
                try:
                    rooms = self._load_fleet_rooms()
                    if rooms and rooms != self.room_of:
                        self.room_of = rooms
                        self.home.room_names = dict(rooms)
                except Exception:
                    pass
                self._save_baselines()
            except Exception:
                pass
            for _ in range(60):
                if getattr(self, "_stop", False):
                    return
                time.sleep(1.0)

    _DOT_HOLD_TTL_S = 900.0   # stillness hold ages out after 15 min

    @staticmethod
    def _nearest_node(pos, fused):
        """Mapped node closest to a unit-box position (RTI peak -> room)."""
        if fused is None or not getattr(fused, "unit_positions", None):
            return None
        px, py = float(pos[0]), float(pos[1])
        node, best = None, None
        for nid, p in fused.unit_positions.items():
            d = (float(p[0]) - px) ** 2 + (float(p[1]) - py) ** 2
            if best is None or d < best:
                node, best = nid, d
        return node

    def _occupant_dot(self, rti, view, fused):
        """THE DOT — one continuous 'you are here' marker (Founder ask):
        - 'live'    RTI fix while there is motion (sub-room, links agree);
        - 'holding' motion faded -> the dot stays put (a still person has
                    not moved: that IS the accurate position). Held while
                    the room belief agrees, and past that until presence
                    fires in ANOTHER room or the hold ages out — belief
                    alone cannot tell a still body from an empty room, so
                    quiet is not evidence of departure (the dot vanished
                    on the Founder sitting still, 2026-07-03 pm);
        - 'room'    belief places the occupant in a room with no RTI fix
                    yet -> dot at that room's node (honest, coarser);
        - None      house reads empty."""
        occ = (view.get("occupancy") or {}).get("best") or {}
        state, conf = occ.get("state"), float(occ.get("confidence") or 0.0)
        believed = state if (state not in (None, "away") and conf >= 0.55) else None
        prev = getattr(self, "_dot", None)
        now = time.time()
        dot = None
        if rti is not None and rti.get("localized") and rti.get("peak"):
            node = believed if believed is not None \
                else self._nearest_node(rti["peak"], fused)
            dot = {"pos": rti["peak"], "mode": "live", "node": node, "t": now}
        elif (rti is not None and rti.get("track")
              and getattr(self, "_occupant", None) is not None):
            # 'tracking' — between-node display track riding the soft
            # tomographic field (Founder 2026-07-26: the dot must move WITH
            # him, not snap to the nearest puck). Only while a REAL occupant
            # is established (election/hold) — the empty-house guard for the
            # display-grade tier (§5.1).
            node = believed if believed is not None \
                else self._nearest_node(rti["track"]["pos"], fused)
            # weak (micro-motion) tracks only refine the held position — the
            # display keeps saying 'still'; only walking-scale evidence may
            # claim movement (Founder-caught: 'saying im moving when im not')
            dot = {"pos": rti["track"]["pos"],
                   "mode": "tracking" if rti["track"].get("strong") else "holding",
                   "node": node, "t": now}
        elif believed is not None:
            same_room = prev is not None and prev.get("node") == believed
            if same_room and prev.get("pos"):
                dot = {**prev, "mode": "holding", "node": believed, "t": now}
            else:
                p = fused.unit_positions.get(int(believed)) if fused else None
                if p is not None:
                    dot = {"pos": [round(float(p[0]), 4), round(float(p[1]), 4)],
                           "mode": "room", "node": believed, "t": now}
        elif prev is not None and prev.get("pos"):
            # stillness hold: keep the last fix until contradicted. `t` is
            # NOT refreshed here — only live/belief-backed states reset the
            # clock, so an actually-empty room clears within the TTL.
            elsewhere = [nid for nid, st
                         in getattr(self, "_room_state", {}).items()
                         if st.get("present_state") and nid != prev.get("node")]
            if elsewhere:
                # presence latched in another room: hand the dot off to it
                # instead of clearing — belief lags the walk by a few
                # seconds and the dot must not blink out mid-transition
                p = fused.unit_positions.get(int(elsewhere[0])) if fused else None
                if p is not None:
                    dot = {"pos": [round(float(p[0]), 4), round(float(p[1]), 4)],
                           "mode": "room", "node": elsewhere[0], "t": now}
            elif now - float(prev.get("t") or 0.0) <= self._DOT_HOLD_TTL_S:
                dot = {**prev, "mode": "holding"}
        self._dot = dot
        return dot

    def _occupant_dots(self, primary, fused):
        """ROOM-LEVEL MULTI-OCCUPANCY (Founder ask 2026-07-05: two people home).

        HONESTY ENVELOPE — read before trusting the count: this RF fleet has no
        per-person signal. We resolve how many ROOMS are independently occupied,
        NOT how many bodies. Two people in the SAME room read as one; identity is
        never claimed. So `count` is a FLOOR on occupancy (>= this many people),
        never an exact headcount, and it is honest to say '2 rooms active' but a
        lie to say 'person A vs person B'. The per-room presence gate reused here
        (`_room_state[nid]['present_state']`) is the same one the single-dot
        hand-off already trusts — we are exposing evidence the engine already
        had, not fabricating new sensing.

        Returns a list of dots; the single-target RTI/belief dot leads (kind
        'primary'), then every OTHER room whose presence gate is latched
        (kind 'presence')."""
        dots, seen = [], set()
        if primary is not None and primary.get("node") is not None:
            dots.append({**primary, "kind": "primary"})
            seen.add(int(primary["node"]))
        pos_of = getattr(fused, "unit_positions", None) or {}
        for nid, st in getattr(self, "_room_state", {}).items():
            nid = int(nid)
            if nid in seen or not st.get("present_state"):
                continue
            p = pos_of.get(nid)
            if p is None:
                continue
            dots.append({"pos": [round(float(p[0]), 4), round(float(p[1]), 4)],
                         "mode": "room", "node": nid, "kind": "presence",
                         "t": time.time()})
            seen.add(nid)
        return dots

    def _occupancy_summary(self, dots):
        """Distinct occupied ROOMS (not nodes) → the honest floor on headcount."""
        rooms = sorted({self.room_of.get(int(d["node"]), f"node-{d['node']}")
                        for d in dots if d.get("node") is not None})
        return {"rooms_present": rooms, "count": len(rooms),
                "multi": len(rooms) >= 2,
                "basis": "rooms-occupied (floor on people; same-room bodies unresolved)"}

    def _apply_occupancy_summary(self, view, fused):
        """Ensure every home view carries explicit room-count truth.

        RTI enrichment is best-effort; the count must not disappear just because
        imaging skipped a frame. Existing dots win, otherwise derive them from
        the primary dot plus latched per-room presence when positions are known.
        """
        dots = view.get("dots")
        if not isinstance(dots, list):
            dots = self._occupant_dots(view.get("dot"), fused)
            view["dots"] = dots
        occ = view.get("occupancy")
        if isinstance(occ, dict):
            occ.update(self._occupancy_summary(dots))
        else:
            view["occupancy"] = self._occupancy_summary(dots)
        return view

    def _ensure_frame_home_occupancy(self, frame):
        """Normalize `/frame.home` before publication.

        The high-rate frame loop can beat the slower home-render thread during
        startup. Even then, Swift must receive a decodable home object and an
        integer occupancy count, never a transient null.
        """
        if self.source != "vigil":
            return frame
        view = frame.get("home")
        if not isinstance(view, dict):
            view = {
                "source": "vigil-home",
                "envelope": "startup",
                "learning": True,
                "pulses": 0,
                "handoffs": 0,
                "metric": False,
                "nodes": {},
                "edges": [],
            }
            frame["home"] = view
        self._apply_occupancy_summary(
            view, getattr(getattr(self, "home", None), "_fused", None))
        occ = view.get("occupancy")
        if not isinstance(occ, dict):
            occ = {}
            view["occupancy"] = occ
        room = frame.get("occupant_room")
        if room and not occ.get("rooms_present"):
            occ.update({
                "rooms_present": [room],
                "count": 1,
                "multi": False,
                "basis": "rooms-occupied (floor on people; same-room bodies unresolved)",
            })
        elif not isinstance(occ.get("count"), int):
            occ.update({
                "rooms_present": [],
                "count": 0,
                "multi": False,
                "basis": "rooms-occupied (floor on people; same-room bodies unresolved)",
            })
        return frame

    def recalibrate(self, node=None):
        """RF run (per room or whole house): drop the quiet floors, persisted
        entries, RTI link floors and occupancy belief so calibration restarts
        on CURRENT link physics. Served at GET /recalibrate[?node=N]."""
        targets = [int(node)] if node is not None else list(self._room_state)
        cleared = []
        for nid in targets:
            st = self._room_state.get(nid)
            if st is not None:
                st["baseline"] = None
                st["win"] = deque(maxlen=2400)
                st["present_state"] = False
                st.pop("above_hist", None)
                cleared.append(nid)
        try:
            self._save_baselines()
        except Exception:
            pass
        try:
            fl = self._rti.floors._hist
            if node is None:
                fl.clear()
            else:
                for k in [k for k in fl if int(node) in k]:
                    del fl[k]
        except Exception:
            pass
        try:
            self.home.tracker._belief = {}
        except Exception:
            pass
        room = self.room_of.get(int(node), f"node-{node}") if node is not None else "all rooms"
        return {"ok": True, "cleared": cleared, "scope": room,
                "note": "floors relearn on 90 s calm windows — keep the room quiet ~2 min"}

    # A property, not a class attribute: a class-level constant evaluates at import and would
    # pin the owner's real home for the life of the process, escaping VIGIL_HOME. Resolved per
    # access instead, so the override is honoured however late it is set.
    @property
    def _BASELINES_PATH(self):
        return vigil_paths.state_path("baselines.json")

    _CAL_VERSION = 2   # bump when floor semantics/link physics change

    def _cal_era(self):
        """Calibration-era signature: floors are only valid for the fleet
        that produced them. Any firmware/roster change (dual-role migration!)
        changes every link's amplitude physics — persisted floors from
        another era silently poison presence (Founder-caught tonight).
        NOTE: only catches fw swaps whose version string was bumped."""
        try:
            with open(vigil_paths.state_path("fleet.json")) as f:
                sig = sorted((int(n["node_id"]), str(n.get("fw_version", "")))
                             for n in json.load(f))
        except Exception:
            sig = []
        return f"v{self._CAL_VERSION}|" + ",".join(f"{a}:{b}" for a, b in sig)

    def _load_baselines(self):
        try:
            with open(self._BASELINES_PATH) as f:
                doc = json.load(f)
            if not isinstance(doc, dict) or "floors" not in doc:
                return {}          # pre-era format: treat as another era
            if doc.get("_era") != self._cal_era():
                return {}          # different fleet/firmware: relearn
            return {int(k): float(v) for k, v in doc["floors"].items()}
        except Exception:
            return {}

    def _save_baselines(self):
        try:
            os.makedirs(os.path.dirname(self._BASELINES_PATH), exist_ok=True)
            tmp = self._BASELINES_PATH + ".tmp"
            floors = {str(n): st["baseline"] for n, st in self._room_state.items()
                      if st.get("baseline") is not None}
            with open(tmp, "w") as f:
                json.dump({"_era": self._cal_era(), "floors": floors}, f)
            os.replace(tmp, self._BASELINES_PATH)
        except Exception:
            pass   # persistence is best-effort

    def _home_loop(self):
        """Render the self-learned home graph every 2 s so the map visibly
        assembles as someone walks room to room (F5). Persist every ~minute."""
        import vigil_home
        n = 0
        while not getattr(self, "_stop", False):
            try:
                view = self.home.learned_map()
                # RTI: back-project every live link's motion excess through
                # the fused layout -> the sub-room dot + heat field.
                try:
                    fused = getattr(self.home, "_fused", None)
                    if fused is not None and hasattr(self.src, "links_summary"):
                        ls = self.src.links_summary()
                        # PHASE-PREFERRED EVIDENCE (fw >= 0.3.0, R1): a body
                        # displacing a fraction of a wavelength swings the
                        # sanitized phase long before |csi| moves — feeding
                        # the imager phase (scaled into the amplitude EMA's
                        # working range) is what makes between-node tracking
                        # sensitive enough for the standard. Amplitude-only
                        # links (fw 0.2.x, mixed fleets during rollout) keep
                        # their motion value; the imager's per-link floors
                        # normalize the two channels either way.
                        links = {k: (v["phase"] * _PHASE_GAIN
                                     if v.get("phase") is not None else v["motion"])
                                 for k, v in ls.items() if v["live"]}
                        r = self._rti.update(links, time.monotonic(),
                                             positions=fused.unit_positions)
                        if r is not None:
                            view["rti"] = r
                            # rooms tick reads this for field-attributed
                            # presence (one body must not light two rooms)
                            self._last_rti = {"r": r, "mono": time.monotonic()}
                            if r.get("localized") and r.get("peak"):
                                # an RTI fix is a hard-gated DETECTION
                                # (3-robust-sigma + >=3 links agree) — hand
                                # it to the belief tracker so the room state
                                # flips with the dot instead of lagging it
                                node = self._nearest_node(r["peak"], fused)
                                if node is not None:
                                    self._rti_fix = {"node": int(node),
                                                     "t": time.time()}
                        view["dot"] = self._occupant_dot(r, view, fused)
                except Exception:
                    pass
                # room-level multi-occupancy: one dot per occupied room + an
                # honest floor-count. This runs even when RTI enrichment above
                # skips/fails, so `/frame.home.occupancy.count` never vanishes.
                self._apply_occupancy_summary(
                    view, getattr(self.home, "_fused", None))
                self._home_view = view
                n += 1
                if n % 30 == 0:
                    self.home.save()
            except Exception:
                pass
            for _ in range(2):
                if getattr(self, "_stop", False):
                    return
                time.sleep(1.0)

    @staticmethod
    def _notify_alarm(title, body):
        """Deliver an alarm to the HUMAN (macOS notification + alert sound).
        The event feed is history, not delivery — an alarm nobody hears is a
        gate to nowhere (Founder-caught)."""
        import subprocess
        try:
            # banner (needs the one-time macOS notification permission)…
            subprocess.Popen(["osascript", "-e",
                              f'display notification {json.dumps(body)} with title {json.dumps(title)} sound name "Sosumi"'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # …but life-safety must be HEARD regardless of any permission:
            subprocess.Popen(["afplay", "/System/Library/Sounds/Sosumi.aiff"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.Popen(["say", "-r", "190", title],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # every Apple device the owner has: iMessage-to-self fans out to
            # iPhone/iPad/Watch/Mac natively — no server, no push service.
            _msg = f"{title} — {body}"
            subprocess.Popen(["osascript", "-e",
                              'tell application "Messages" to send ' + json.dumps(_msg) +
                              ' to buddy "mtuburnsbarber@gmail.com" of (1st account whose service type is iMessage)'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    def _event_listener(self):
        """M3 host intake: hall/door + relayed life-safety events (UDP 5569,
        0xA5 0x5E + 14B payload: node,event,value,ts_us,flags,hops). Door
        events feed the F5 kitchen labeler; everything lands in the feed."""
        import socket as _sk, struct as _st
        # Authenticate the host uplink with the fleet PSK. A `fall` event here fans out
        # a real emergency (iMessage-to-owner + Sosumi + spoken alert), so a LAN peer
        # forging a 0xA5 0x5E datagram must not be able to trigger it. With a PSK
        # provisioned, only a validly-tagged frame is acted on; without one we warn and
        # run legacy (the firmware co-change is firmware/main/hall.h appending the tag).
        try:
            from vigil.mesh import relay as _relay
        except Exception:
            _relay = None
        _psk = _relay.load_fleet_psk() if _relay is not None else None
        if _psk is None:
            sys.stderr.write("[home_engine] WARNING :5569 host uplink is UNAUTHENTICATED "
                             "(no fleet PSK) — a LAN peer can forge a fall event. Provision "
                             "a fleet PSK + re-flash nodes to enforce.\n")
        # Without a PSK the frame check cannot fail closed, so fail closed at the socket:
        # bind loopback only, keeping the emergency fan-out off the LAN. A provisioned
        # fleet (or VIGIL_RELAY_UNAUTH_LAN=1 on a trusted lab LAN) still binds wildcard.
        _bind_host = "0.0.0.0"
        if _relay is not None:
            try:
                _bind_host = _relay.unauth_bind_host("0.0.0.0", _psk)
            except AttributeError:
                pass
        elif _psk is None:
            _bind_host = "127.0.0.1"
        try:
            sk = _sk.socket(_sk.AF_INET, _sk.SOCK_DGRAM)
            sk.setsockopt(_sk.SOL_SOCKET, _sk.SO_REUSEADDR, 1)
            sk.bind((_bind_host, 5569)); sk.settimeout(1.0)
        except OSError:
            return
        while not getattr(self, "_stop", False):
            try:
                d, _ = sk.recvfrom(64)
            except _sk.timeout:
                continue
            except OSError:
                return
            if _relay is not None:
                if not _relay.event_dgram_authentic(d, _psk):
                    continue      # forged / unsigned / wrong-key uplink — drop (fail-closed)
            elif len(d) < 16 or d[0] != 0xA5 or d[1] != 0x5E:
                continue
            nid, evt, val = d[2], d[3], _st.unpack("<h", d[4:6])[0]
            relayed = bool(d[14] & 1)
            now = time.time()
            kind = {1: "door_open", 2: "door_close", 3: "hall_raw",
                    4: "fall", 5: "mesh_ping"}.get(evt, f"evt{evt}")
            if kind == "mesh_ping":
                continue
            if kind in ("door_open", "door_close") and not self._door_nodes().get(nid):
                # NO MAGNET, NO DOOR EVENTS (Founder-caught 2026-07-26, twice:
                # "says doors open when they dont"). The door sensor IS the
                # ESP32's built-in hall element, and hall.h is explicit that it
                # only reads a door with a magnet mounted within 1-2 cm — the
                # effect is "tens of LSB". With no magnet fitted, the reading is
                # thermal/ADC noise and EVERY door event it produces is false.
                # So door events are OPT-IN per node: set "door_sensor": true in
                # the fleet manifest for a node that actually has a magnet on
                # its door. Unconfigured nodes drop them at ingest — a rate
                # gate can only thin an all-false stream, never make it true.
                continue
            if kind in ("door_open", "door_close"):
                # DOOR CHATTER GATE (Founder-caught 2026-07-26 "buggy": 30
                # door events in 2 min at 4 AM — node fw over-fires its door
                # classifier on ordinary in-room motion, spamming the new
                # ACTIVITY feed and poisoning the F5 labeler's door evidence;
                # fw reflash is bench-blocked, so the engine gates ingest).
                # Physics: a real door cannot cycle every few seconds all
                # night. Refractory: one door event per node per 20 s. A node
                # that still produces 6 gated events inside 3 min is chatter:
                # mute its DOOR lane 5 min and surface ONE honest
                # door_sensor_noisy marker instead of silently eating events.
                # Fall events are NEVER gated.
                gates = getattr(self, "_door_gate", None)
                if gates is None:
                    gates = self._door_gate = {}
                verdict = self._door_gate_decide(
                    gates.setdefault(
                        nid, {"last": {}, "recent": deque(), "mute_until": 0.0}),
                    kind, now)
                if verdict == "mute_start":
                    self._events.appendleft({"t": now, "node_id": nid,
                                             "kind": "door_sensor_noisy",
                                             "value": val, "relayed": relayed})
                    continue
                if verdict != "pass":
                    continue
            self._events.appendleft({"t": now, "node_id": nid, "kind": kind,
                                     "value": val, "relayed": relayed})
            if kind == "fall":
                self._notify_alarm("Vigil EMERGENCY: fall detected",
                                   f"node {nid}" + (" (relayed by mesh)" if relayed else ""))
            if kind in ("door_open", "door_close"):
                self.home.add_evidence("door.event", nid, now)

    _DOOR_NODES_TTL_S = 30.0

    def _door_nodes(self):
        """node_id -> bool: does this node have a door magnet fitted?

        Read from the fleet manifest ("door_sensor": true), cached briefly so
        the owner can enable one without restarting. Absent key = false: a
        node with no magnet must never emit door events."""
        now = time.monotonic()
        cached = getattr(self, "_door_nodes_cache", None)
        if cached is not None and now - cached[0] <= self._DOOR_NODES_TTL_S:
            return cached[1]
        out = {}
        try:
            with open(vigil_paths.state_path("fleet.json")) as f:
                for n in json.load(f):
                    out[int(n["node_id"])] = bool(n.get("door_sensor"))
        except Exception:
            pass
        self._door_nodes_cache = (now, out)
        return out

    _DOOR_REFRACTORY_S = 20.0   # per KIND — the close following a real open passes
    _DOOR_CHATTER_N = 12        # raw events in the window = chatter (a real swing
                                # is TWO events; grocery runs stay well under this)
    _DOOR_CHATTER_WIN_S = 180.0
    _DOOR_MUTE_S = 300.0        # mute that node's door lane this long

    @staticmethod
    def _door_gate_decide(st, kind, now):
        """Door-lane ingest verdict for one node: 'pass' | 'drop' |
        'mute_start'. Pure state-dict transition — regression-locked by
        tests/test_door_chatter_gate.py. A real swing pair (open, then close
        seconds later) passes — refractory is per KIND. Sustained chatter
        (tonight's failure: ~15 events/min all night) trips the window count
        and mutes with one honest marker."""
        if now < st["mute_until"]:
            return "drop"
        st["recent"].append(now)
        while st["recent"] and now - st["recent"][0] > Engine._DOOR_CHATTER_WIN_S:
            st["recent"].popleft()
        if len(st["recent"]) >= Engine._DOOR_CHATTER_N:
            st["mute_until"] = now + Engine._DOOR_MUTE_S
            st["recent"].clear()
            return "mute_start"
        if now - st["last"].get(kind, 0.0) < Engine._DOOR_REFRACTORY_S:
            return "drop"
        st["last"][kind] = now
        return "pass"

    def _airflow_tick(self, fleet, now):
        """Setup from the house's own breathing (Founder: airflow only).
        Air is RF-invisible, but what it moves is not: an HVAC blower cycle
        raises low-level micro-motion in EVERY vented room within seconds of
        each other — a simultaneity signature no person or appliance makes.
        Correlated onset across >=2 rooms sustained >=60 s = an hvac cycle;
        per-room response amplitude becomes zone/character evidence."""
        st = getattr(self, "_airflow", None)
        if st is None:
            st = self._airflow = {"lift_since": {}, "cycle_on": False, "t_on": 0.0}
        lifted = []
        for nid_s, v in fleet.items():
            nid = int(nid_s)
            base = self._room_state.get(nid, {}).get("baseline") or 0.0
            m = float(v.get("motion") or 0.0)
            if v.get("live") and base > 0 and 1.05 * base < m < 1.30 * base:
                st["lift_since"].setdefault(nid, now)
                lifted.append(nid)
            else:
                st["lift_since"].pop(nid, None)
        sustained = [n for n in lifted if now - st["lift_since"][n] >= 60.0]
        onsets = [st["lift_since"][n] for n in sustained]
        simultaneous = (len(sustained) >= 2 and max(onsets) - min(onsets) <= 8.0)
        if simultaneous and not st["cycle_on"]:
            st["cycle_on"] = True; st["t_on"] = now
            for n in sustained:
                self.home.add_evidence("machine.discovered", n, now, "hvac")
            self._events.appendleft({"t": now, "node_id": 0, "kind":
                                     f"hvac_cycle_on:{len(sustained)} rooms",
                                     "value": 0, "relayed": False})
        elif st["cycle_on"] and len(sustained) == 0:
            st["cycle_on"] = False
            self._events.appendleft({"t": now, "node_id": 0, "kind": "hvac_cycle_off",
                                     "value": int(now - st["t_on"]), "relayed": False})

    def _evidence_loop(self):
        """M2/M4: run steam + appliance-signature engines on each live room's
        full-rate ring every 5 s; emit behavioral evidence to the F5 labeler."""
        from vigil_steam import SteamDetector
        while not getattr(self, "_stop", False):
            try:
                fleet = self.src.fleet_summary() if hasattr(self.src, "fleet_summary") else {}
                now = time.time()
                for nid_s, st in fleet.items():
                    nid = int(nid_s)
                    if not st.get("live"):
                        continue
                    rows, self._ev_cursor[nid] = self.src.stream_since(nid, self._ev_cursor.get(nid, 0))
                    if len(rows) == 0:
                        continue
                    det = self._steam.setdefault(nid, SteamDetector(fs=100.0))
                    for ev in det.push(rows):
                        self.home.add_evidence("steam", nid, now)
                        self._events.appendleft({"t": now, "node_id": nid,
                                                 "kind": "steam", "value": 0, "relayed": False})
                    for topic, payload in self._spectra.push(nid, rows, t0=now):
                        try:
                            self._vbus.publish(topic, dict(payload))
                            if topic == "machine.discovered" and \
                                    str(payload.get("label", "")) in ("stove", "oven", "heater", "kettle"):
                                sid = str(payload.get("signature_id", payload.get("id", "")))
                                if sid and sid not in {b.signature_id for b in self._safety_cfg.bindings}:
                                    room = self.room_of.get(nid, f"node-{nid}")
                                    self._safety_cfg.bindings.append(self._ZoneBinding(room=room, signature_id=sid))
                                    self._safety._by_sig[sid] = self._safety_cfg.bindings[-1]
                        except Exception:
                            pass
                        if topic == "machine.discovered":
                            label = str(payload.get("label", "")) or "appliance"
                            self.home.add_evidence("machine.discovered", nid, now, label)
                            self._events.appendleft({"t": now, "node_id": nid,
                                                     "kind": f"appliance:{label}",
                                                     "value": 0, "relayed": False})
                self._airflow_tick(fleet, now)
                # stove-unattended: presence + periodic tick
                try:
                    occ = getattr(self, "_occupant", None)
                    if occ is not None:
                        self._safety.presence(self.room_of.get(occ, f"node-{occ}"), now)
                    for alarm in self._safety.tick(now):
                        self._events.appendleft({"t": now, "node_id": 0,
                                                 "kind": f"SAFETY:{alarm.get('rule','stove-unattended')}",
                                                 "value": 0, "relayed": False,
                                                 "room": alarm.get("room")})
                        self._notify_alarm(f"Vigil safety: {alarm.get('rule','stove unattended')}",
                                           f"{alarm.get('room','a room')} — heat source running with nobody home")
                except Exception:
                    pass
                # night breathing evidence: a gated real reading during night hours
                f = self.latest if isinstance(self.latest, dict) else {}
                if f.get("breathing_bpm") is not None:
                    hour = time.localtime().tm_hour
                    occ = getattr(self, "_vit_node", None)
                    if occ is not None and (hour >= 22 or hour < 6):
                        self.home.add_evidence("vitals.breathing", occ, time.time())
            except Exception:
                pass
            for _ in range(5):
                if getattr(self, "_stop", False):
                    return
                time.sleep(1.0)

    def _vigil_rooms_tick(self):
        """Per-room presence + occupant election from live link motion.

        Presence: a link's fast motion EMA sits above its own slow quiet
        baseline (learned per node, adapts over minutes). Occupant: the room
        with the largest excess-over-baseline; switching requires beating the
        incumbent for 3 consecutive ticks (hysteresis, no flicker). Returns
        (rooms_view, occupant_room, occupant_node).
        """
        fleet = self.src.fleet_summary()
        rooms_view = {}
        excesses = {}
        live_ms = [float(x.get("motion") or 0.0) for x in fleet.values() if x.get("live")]
        fleet_med = sorted(live_ms)[len(live_ms) // 2] if live_ms else 0.0
        for nid, st in fleet.items():
            nid = int(nid)
            room = self.room_of.get(nid, f"node-{nid}")
            if not self._room_state and not getattr(self, "_baselines_loaded", False):
                self._baselines_loaded = True
                for k, v in self._load_baselines().items():
                    self._room_state[k] = {"baseline": v, "win": deque(maxlen=2400)}
            state = self._room_state.setdefault(
                nid, {"baseline": None, "win": deque(maxlen=2400)})
            state.setdefault("win", deque(maxlen=2400))
            m = float(st.get("motion") or 0.0)
            now_cal = time.monotonic()
            if st.get("live") and m > 0:
                # Quiet-envelope calibration: ambient RF motion on an empty link
                # is a NOISE BAND, not a point — presence must clear the band's
                # upper envelope, not its minimum. The envelope (p95 of a 90 s
                # PHYSICAL-TIME window) is only accepted while the window is
                # statistically CALM (tight spread = nobody moving), so occupied
                # hours can never inflate the floor. Window is TIME-based, not
                # sample-based: at 12 Hz the old 40-sample gate meant a 3-second
                # dip could set a poisoned running-min floor for hours (live-
                # caught: 4/5 rooms read present in a still house, Founder:
                # 'maxing out without any movement').
                if state.get("win") and (
                        not isinstance(state["win"][0], tuple)
                        or len(state["win"][0]) != 3):
                    state["win"] = deque(maxlen=2400)   # migrate old win formats
                if state["win"].maxlen != 2400:
                    state["win"] = deque(state["win"], maxlen=2400)
                state["win"].append((now_cal, m, m - fleet_med))
                w = [v for tt, v, _ in state["win"] if now_cal - tt <= 90.0]
                sp_w = [sp for tt, _, sp in state["win"] if now_cal - tt <= 90.0]
                t_old = min(tt for tt, _, _ in state["win"])
                if len(w) >= 240 and now_cal - t_old >= 60.0:
                    arr = sorted(w)
                    p05 = arr[int(0.05 * len(arr))]
                    p50 = arr[len(arr) // 2]
                    p95 = arr[int(0.95 * len(arr))]
                    # A room whose link rode ABOVE the fleet during the window
                    # had a body in it — the spread test alone passed occupied
                    # windows under dual-role fw (motion scale grew, so 0.6*p50
                    # tolerated a moving person) and the occupant's own motion
                    # became the floor: he read absent in his own room
                    # (Founder-caught live, 2026-07-03 pm). Spatial lift is the
                    # person signature (presence uses 0.55) — a calm window
                    # must stay under it for its FULL 90 s.
                    sp_arr = sorted(sp_w)
                    sp95 = sp_arr[int(0.95 * len(sp_arr))]
                    calm = ((p95 - p05) < 0.6 * max(p50, 1e-6)
                            and sp95 < 0.45)
                    if calm:
                        env = p95 * 1.10
                        b = state["baseline"]
                        if b is None or env < b:
                            # only genuine quiet can SET the floor (running min of
                            # calm envelopes) — a busy afternoon baked floors so
                            # high a walking person read as nothing (Founder-caught:
                            # 'no data being entailed'). Down: immediate.
                            state["baseline"] = env
                        else:
                            # Up: ~2%/hour relaxation so a permanent RF change
                            # eventually re-baselines without ever chasing people.
                            state["baseline"] = min(b * 1.000006, env)
            base = state["baseline"] or 0.0
            excess = max(0.0, m - base)
            # SPATIAL CONTRAST (placed fleet): a person in a room lifts THAT
            # room's link above the rest of the house. Fleet-median-relative
            # detection self-normalizes — no absolute floor to mis-learn.
            spatial = m - fleet_med
            # AIR IS NEVER A PERSON (Founder): while an hvac cycle is live,
            # both presence bars rise ABOVE anything airflow produces
            # (airflow band tops at 1.30x baseline / diffuse spatial lift);
            # only a body clears 1.55x or a sharp spatial spike.
            hvac_on = bool(getattr(self, "_airflow", {}).get("cycle_on"))
            abs_k = 1.55 if hvac_on else 1.30
            sp_k = 1.10 if hvac_on else 0.55
            above = bool(st.get("live")) and (
                (base > 0 and m > base * abs_k) or (spatial > sp_k and m > fleet_med * 1.20))
            # Presence is a PHYSICAL-TIME property: humans persist for minutes,
            # RF noise bursts for fractions of a second. A room reads present
            # only after 2.0 s continuously above threshold, and stays present
            # until 3.0 s continuously below — 250 ms correlated bursts (which
            # leaked 22 ghost pulses/min from an EMPTY house) cannot register.
            now_m = time.monotonic()
            # duty-cycle sustain: a WALKING body flickers above/below threshold
            # tick to tick — continuous-2s never latched on a real person
            # (live-caught with Founder walking). Enter when >=60% of the last
            # 2 s is above; leave when <=20% of the last 3 s. Noise bursts
            # can't hold 60% for 2 s; a person easily does.
            hist = state.setdefault("above_hist", deque(maxlen=64))
            hist.append((now_m, above))
            def _frac(win):
                pts = [a for t, a in hist if now_m - t <= win]
                return (sum(pts) / len(pts)) if pts else 0.0
            was_present = state.get("present_state", False)
            if not was_present and _frac(2.0) >= 0.6 and len(hist) >= 8:
                state["present_state"] = True
            elif was_present and _frac(3.0) <= 0.2:
                state["present_state"] = False
            present = state.get("present_state", False)
            # FIELD-ATTRIBUTED PRESENCE (Founder-caught 2026-07-26: rooms
            # false-flag because per-node motion averages links that CROSS
            # the occupant's room — his body lights other rooms' geometry,
            # and extra nodes only add more crossing links). When the
            # tomographic field has a fresh view of WHERE the disturbance
            # is, a room may claim presence only if a field region sits
            # nearest ITS node. One body can never light two rooms; a real
            # second person is a second disjoint region and still latches.
            # No field view (warmup/quiet) ⇒ raw behavior, unchanged.
            lr = getattr(self, "_last_rti", None)
            if (present and lr is not None and now_m - lr["mono"] <= 3.0
                    and lr["r"].get("localized")):
                # FAIL-OPEN UNLESS THE FIELD IS A REAL DETECTION (live-caught
                # 2026-07-26, founder at his desk reading no_presence 54/75):
                # regions are computed from the SOFT field, so with 0-1
                # significant links the centroid is noise and its nearest node
                # is arbitrary — it pointed at the living room while he sat in
                # the bedroom, and this gate then suppressed the CORRECT room.
                # Only a `localized` field (3-sigma peak, MIN_SIG links whose
                # ellipses agree) may veto a room's latch; anything weaker is
                # not evidence about WHERE, so presence stands on its own
                # per-room gates. Bleed suppression is preserved exactly when
                # it was justified, and never suppresses on noise.
                region_nodes = {rg.get("node")
                                for rg in (lr["r"].get("regions") or [])}
                if region_nodes and nid not in region_nodes:
                    present = False
                    state["present_state"] = False
            if present:
                excesses[nid] = excess
            rooms_view[room] = {
                "node_id": nid, "live": bool(st.get("live")),
                "rate_hz": st.get("rate_hz"), "rssi": st.get("rssi"),
                "motion": m, "baseline": round(base, 4), "present": present,
                "spatial": round(spatial, 3),
                "spectrum": st.get("spectrum"),
            }
        now_m = time.monotonic()
        if not excesses:
            # STILLNESS ≠ VACANCY (dot doctrine; Founder-caught 2026-07-03 and
            # again 2026-07-25 — 'not finding exactly where i am'). A person at
            # a desk stops producing excess within seconds; the old 5 s clear
            # read the house empty around him, starved the vitals lane of its
            # node, and let the F5 belief rot to 'away'. The believed room now
            # HOLDS: quiet is not evidence of departure. The hold refreshes on
            # live excess (else-branch below) or a gate-confirmed vital on the
            # held link (_occ_vitals_mono — real measurements only, never
            # synthetic), and ages out after _DOT_HOLD_TTL_S with no evidence,
            # so an actually-empty house still reads empty (§5.1): occupancy
            # here is bounded belief with provenance (the frame carries
            # occupant_mode "live"|"holding"), never a fabricated measurement.
            # Per-room `present` stays strictly motion-gated throughout, and
            # the fall monitor keeps its strict view (see fall_frame).
            fix = getattr(self, "_rti_fix", None)
            fix_fresh = fix is not None and time.time() - float(fix.get("t") or 0.0) <= 10.0
            if self._occupant is None and fix_fresh:
                # a 3σ RTI fix is a HARD-GATED detection of a body (MIN_SIG
                # links agree + z gate) — it elects directly, so the room
                # state flips with the dot instead of lagging it. Live-caught
                # 2026-07-26: after a restart the per-room excess gates never
                # latched while RTI was landing clean fixes, occupant stayed
                # None, and the empty-house guard kept the between-node
                # tracker dark with the Founder moving in plain view.
                self._occupant = int(fix["node"])
                self._challenger = (None, 0)
                self._occ_evidence_mono = now_m
            elif self._occupant is not None:
                ev = max(getattr(self, "_occ_evidence_mono", 0.0),
                         getattr(self, "_occ_vitals_mono", 0.0))
                if fix_fresh:
                    self._occ_evidence_mono = ev = now_m   # detection refreshes the hold
                if ev <= 0.0 or now_m - ev > self._DOT_HOLD_TTL_S:
                    self._occupant, self._challenger = None, (None, 0)
        else:
            self._occ_evidence_mono = now_m
        if excesses:
            top = max(excesses, key=excesses.get)
            if self._occupant is None:
                # presence already requires 2 s sustained signal — elect directly.
                self._occupant, self._challenger = top, (None, 0)
            elif self._occupant not in excesses:
                self._occupant, self._challenger = top, (None, 0)
            elif top != self._occupant:
                name, n = self._challenger
                n = n + 1 if name == top else 1
                self._challenger = (top, n)
                if n >= 3:
                    self._occupant, self._challenger = top, (None, 0)
                    # NOTE: no vitals reset here. The frame loop owns the vitals
                    # buffer and now keeps one PER NODE (see _vitals_by_node) —
                    # wiping it on every election was half of why breathing and
                    # heart never locked (Founder-caught 2026-07-26).
            else:
                self._challenger = (None, 0)
        if self._occupant is None:
            self._occ_mode = None
        elif self._occupant in excesses:
            self._occ_mode = "live"
        else:
            self._occ_mode = "holding"
        occupant_room = self.room_of.get(self._occupant, f"node-{self._occupant}") if self._occupant is not None else None
        return rooms_view, occupant_room, self._occupant

    def _load_detector(self):
        """Resume the learned baseline from the buyer's store if present; else start empty.

        Never crashes the sidecar on a corrupt/unreadable store — falls back to a
        fresh (empty) model, which honestly reports learning_baseline.
        """
        if self.store_path and os.path.exists(self.store_path):
            try:
                with open(self.store_path) as f:
                    doc = json.load(f)
                return AnomalyDetector(model=BaselineModel.from_dict(doc))
            except Exception:
                pass
        return AnomalyDetector()

    def _save_model(self):
        """Best-effort atomic persist of the learned baseline to the buyer's store."""
        if not self.store_path:
            return
        try:
            os.makedirs(os.path.dirname(self.store_path), exist_ok=True)
            tmp = self.store_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.detector.model.to_dict(), f)
            os.replace(tmp, self.store_path)
        except Exception:
            pass   # persistence is best-effort; never take the sidecar down for it

    def _loop(self):
        period = 1.0 / self.rate
        while not self._stop:
            connected = bool(getattr(self.src, "connected", False))
            # replay always senses; a UDP source only senses once a reader streams
            sensing = (self.source not in ("udp", "vigil")) or connected
            anomaly = None
            frame = {
                "tick": self.tick,
                "ts": time.time(),
                "source": self.source,
                "live": connected if self.source in ("udp", "vigil") else False,
                "csi_connected": connected,
                "csi_frames": int(getattr(self.src, "frames", 0)),
                "csi_tier": getattr(self.src, "tier", None),
                "model": "wifi-densepose pose_v1 (MIT, numpy port)",
                "fleet": (self.src.fleet_summary()
                          if hasattr(self.src, "fleet_summary") else None),
                "model_pck50": 0.185,
                "edges": SKELETON_EDGES,
            }
            # Synthetic provenance: the bundled replay capture (--source replay) or the csi_sim
            # replayer streaming over UDP (carries the "sim" stamp). Its data contains a deliberate
            # ~1.25 Hz cardiac tone, so the accuracy gates (which reject NOISE) would happily emit a
            # plausible 75 BPM. Presenting that as a live vital IS the eldercare fabrication failure
            # mode (CHARTER 5.1), so synthetic frames are marked demo and their vitals are suppressed.
            synthetic = (self.source == "replay") or bool(getattr(self.src, "synthetic", False))
            frame["demo"] = synthetic
            if sensing:
                if self.source == "vigil":
                    rooms_view, occupant_room, occ_node = self._vigil_rooms_tick()
                    # full-rate vitals: push EVERY wire frame from the occupant's
                    # link since the last tick (lossless 100 Hz), not a subsample.
                    vit_node = self._pick_vitals_node(occ_node)
                    if vit_node is not None:
                        if getattr(self, "_vit_node", None) != vit_node:
                            # PER-NODE VITALS BUFFERS (Founder-caught 2026-07-26:
                            # "my breathing pattern and heart" are glitchy — 4 of
                            # 31 s produced a breathing number, heart never
                            # locked). Breathing needs 16 UNBROKEN seconds plus
                            # agreement across consecutive windows, but the
                            # buffer was rebuilt from empty on every occupant
                            # change — and with two nodes per room the election
                            # flaps between same-room nodes, so the window was
                            # never allowed to fill. Keep one buffer PER NODE and
                            # resume it: a flap back to a node recovers its
                            # history instead of restarting the clock, while a
                            # genuine room change still reads that room's own
                            # link. Cursors are per node for the same reason.
                            self._vit_node = vit_node
                            self._vit_rate_ema = None      # new link, new clock
                            self._vit_rate_t = None
                            self._vit_rate_n = 0
                            store = getattr(self, "_vitals_by_node", None)
                            if store is None:
                                store = self._vitals_by_node = {}
                            # A buffer may only be RESUMED across a short gap:
                            # the spectrum assumes contiguous samples, so
                            # stitching across a real absence builds a
                            # discontinuity that destroys the respiratory peak
                            # (measured live 2026-07-26: naive resume took
                            # breathing from 4/31 frames to 0/33). Fast
                            # same-room flaps — the case this fix exists for —
                            # are well inside the window; anything longer
                            # starts clean.
                            cursors = getattr(self, "_vit_cursors", None)
                            seen = getattr(self, "_vit_seen", None)
                            if seen is None:
                                seen = self._vit_seen = {}
                            gap = time.monotonic() - seen.get(vit_node, 0.0)
                            if vit_node not in store or gap > 2.0:
                                store[vit_node] = Vitals(self._vitals_fs(),
                                                         self.src.subcarriers)
                            self.vitals = store[vit_node]
                            if cursors is None:
                                cursors = self._vit_cursors = {}
                            self._vit_cursor = cursors.get(vit_node, 0)
                        # the link's REAL rate, not the source's nominal one
                        try:
                            # MEASURE the rate of what we ACTUALLY push, never
                            # the node's advertised rate: stream_since filters
                            # to the node's DOMINANT PEER LINK, so the series
                            # carries roughly 1/n_peers of the node's frames.
                            # Feeding the aggregate rate made the FFT believe
                            # ~147 Hz for a ~37 Hz series — a 4x scale error
                            # that pushes a real 15 br/min breath to ~1 Hz,
                            # clean out of the breathing band, which is why the
                            # only peak ever seen sat at the 0.5 Hz band edge
                            # (live-measured 2026-07-26).
                            live_fs = None
                            now_r = time.monotonic()
                            prev_r = getattr(self, "_vit_rate_t", None)
                            if prev_r is not None and now_r > prev_r:
                                pushed = getattr(self, "_vit_rate_n", 0)
                                if pushed > 0 and now_r - prev_r >= 2.0:
                                    live_fs = pushed / (now_r - prev_r)
                                    self._vit_rate_t = now_r
                                    self._vit_rate_n = 0
                            else:
                                self._vit_rate_t = now_r
                                self._vit_rate_n = 0
                            if live_fs and live_fs > 0:
                                # The per-node rate is a 2 s estimate and swings
                                # 92-180 Hz. Feeding it raw made the window
                                # length oscillate, so the buffer was chopped on
                                # every dip and never filled. Smooth hard (~50 s
                                # time constant): the true wire rate is stable,
                                # the ESTIMATE is what is noisy.
                                ema = getattr(self, "_vit_rate_ema", None)
                                ema = float(live_fs) if ema is None \
                                    else 0.98 * ema + 0.02 * float(live_fs)
                                self._vit_rate_ema = ema
                                self.vitals.set_rate(ema)
                        except Exception:
                            pass
                        chunk, self._vit_cursor = self.src.stream_since(vit_node, getattr(self, "_vit_cursor", 0))
                        cursors = getattr(self, "_vit_cursors", None)
                        if cursors is None:
                            cursors = self._vit_cursors = {}
                        cursors[vit_node] = self._vit_cursor
                        self._vit_rate_n = getattr(self, "_vit_rate_n", 0) + len(chunk)
                        seen = getattr(self, "_vit_seen", None)
                        if seen is None:
                            seen = self._vit_seen = {}
                        seen[vit_node] = time.monotonic()
                        # refit the vital-band subcarrier mask ~every 6 s of
                        # wire data (see Vitals.select_subcarriers) — blind
                        # 52-bin averaging let antiphase fading cancel vitals.
                        self._vit_pushes = getattr(self, "_vit_pushes", 0) + len(chunk)
                        if self._vit_pushes >= 600:
                            self._vit_pushes = 0
                            rows = self.src.recent_rows(vit_node, seconds=16.0)
                            mask = Vitals.select_subcarriers(rows, self._vitals_fs())
                            if mask is not None:
                                self.vitals.set_mask(mask, rows)
                        for row in chunk[:-1]:
                            self.vitals.push(row)   # last row pushed below as `amp`
                    frame["rooms"] = rooms_view
                    frame["occupant_room"] = occupant_room
                    frame["occupant_mode"] = getattr(self, "_occ_mode", None)
                    frame["map"] = self._map
                    # F5: the learner hears OCCUPANT TRANSITIONS only — the
                    # occupant election carries 3-tick persistence + vacancy
                    # decay, so a sub-second RF blip can never mint a pulse.
                    # (Raw per-room rising edges fed 320 ghost pulses / 11 fake
                    # edges from an EMPTY house — Founder-caught, 2026-07-03.)
                    now = time.time()
                    for rm, rv in rooms_view.items():
                        self.home.observe(rv["node_id"], occ_node == rv["node_id"], now)
                    # F7: the belief tracker hears every live room's raw
                    # excess each tick — the learned topology (not a hard
                    # argmax) decides where the person plausibly is.
                    try:
                        # Score = excess over the room's own floor, OR its
                        # spatial lift above the fleet (past the noise band).
                        # Floor-only scoring went all-zero whenever floors were
                        # stale/unlearned (fw-era change) and belief drained to
                        # AWAY with the Founder sitting in the room — spatial
                        # contrast needs no floor, so tracking survives bad
                        # calibration (2026-07-03 pm).
                        scores = {rv["node_id"]: max(
                                0.0,
                                (rv["motion"] - rv["baseline"])
                                if rv["baseline"] > 0 else 0.0,
                                rv["spatial"] - 0.45)
                             for rv in rooms_view.values() if rv["live"]}
                        # a fresh RTI fix (hard-gated detection) is worth a
                        # full-strength emission for 10 s — a brief burst of
                        # motion could localize the dot but never flip the
                        # belief out of AWAY, so 'holding' had nothing to
                        # hold onto (live-caught, 2026-07-03 pm)
                        fix = getattr(self, "_rti_fix", None)
                        if fix and now - fix["t"] <= 10.0 \
                                and fix["node"] in scores:
                            scores[fix["node"]] = max(scores[fix["node"]], 1.0)
                        self.home.observe_scores(scores, now)
                    except Exception:
                        pass
                    frame["home"] = self._home_view
                    frame["events"] = list(self._events)[:30]
                    amp = self.src.frame_of(vit_node) if vit_node is not None else None
                    if amp is None:
                        amp, csi = self.src.next_frame()
                    else:
                        csi = amp.astype(np.complex64)
                else:
                    amp, csi = self.src.next_frame()    # [56], [56] complex
                self.vitals.push(amp)
                range_info = self.ranger.push(csi)
                # R1: vitals require genuine occupancy - a moving reflector detected
                # at range, not the raw-amplitude motion proxy. A vital in an empty
                # room is the eldercare fabrication failure mode (CHARTER 5.1).
                if self.source == "vigil":
                    # room-level election is the occupancy truth for the fleet:
                    # RF noise on an amplitude link must not read as a person.
                    # occupant_room now carries the HELD belief ("live"|"holding",
                    # see _vigil_rooms_tick) — the fall monitor alone keeps the
                    # strict live-excess view (fall_frame below).
                    occupied = frame.get("occupant_room") is not None
                    # Vitals stillness bridge (eldercare fall safety): keep the vitals
                    # engine computing for a bounded window after a CONFIRMED occupancy
                    # so a motionless-but-present (fallen) body's breathing is still
                    # measured — and can refresh the occupant hold. See VITALS_STILL_BRIDGE_SECS.
                    if occupied:
                        self._occ_bridge_until = time.monotonic() + VITALS_STILL_BRIDGE_SECS
                    occ_for_vitals = occupied or (time.monotonic()
                                                  < getattr(self, "_occ_bridge_until", 0.0))
                    # end-to-end vitals state: ARMED the instant you walk in;
                    # ACQUIRING whenever you pause (micro-stillness on the live
                    # link); LOCKED only when a gate-passing number exists.
                    still = occupied and self.vitals.motion_ema < 0.35
                    if not occupied:
                        frame["vitals_state"] = "no_presence"
                    elif frame.get("breathing_bpm") is not None or frame.get("heart_bpm") is not None:
                        frame["vitals_state"] = "locked"
                    elif still:
                        frame["vitals_state"] = "acquiring"
                    else:
                        frame["vitals_state"] = "armed_waiting_stillness"
                else:
                    occupied = (range_info.get("range_peak_m") is not None
                                or self.vitals.motion_ema > 0.04)
                    occ_for_vitals = occupied
                frame.update(self.vitals.snapshot(occupied=occ_for_vitals))
                if self.source == "vigil":
                    frame["present"] = occupied
                frame.update(range_info)
                if synthetic:
                    # Never let synthetic data surface a vital as a real measurement. Suppress the
                    # numbers (UI shows an honest "—") and force live=False so no "THROUGH-WALL /
                    # Live" badge claims a real person. Motion/presence may still light the pipeline.
                    frame["heart_bpm"] = None
                    frame["breathing_bpm"] = None
                    frame["live"] = False
                    frame["demo_note"] = "synthetic replay capture — vitals suppressed (no real person)"
                if (self.source == "vigil" and not synthetic
                        and (frame.get("breathing_bpm") is not None
                             or frame.get("heart_bpm") is not None)):
                    # a gate-confirmed vital is real evidence of a body on the
                    # held link — refresh the occupant hold (stillness ≠ vacancy)
                    self._occ_vitals_mono = time.monotonic()
                # pose net is a fixed 56-subcarrier model; resample narrower
                # live spectra (vigil fleet: 52) onto its grid — same physical
                # spectrum, standard interpolation, no invented energy.
                if amp.shape[0] != 56:
                    pose_amp = np.interp(np.linspace(0.0, 1.0, 56),
                                         np.linspace(0.0, 1.0, amp.shape[0]), amp
                                         ).astype(np.float32)
                else:
                    pose_amp = amp
                self.window.append(pose_amp)
                if len(self.window) == 20:
                    win = np.stack(self.window, axis=1)
                    frame["keypoints"] = self.model.keypoints(win)
                    frame["pose_ready"] = True
                else:
                    frame["keypoints"] = []; frame["pose_ready"] = False
                # only learn/classify from a real sensing observation — no data, no learning
                anomaly = self.detector.update(
                    frame["ts"], bool(frame.get("present")),
                    float(frame.get("motion", 0.0)), learn=True)
            else:
                # waiting for a CSI reader — honest empty state, no fabricated pose
                self.window.clear()
                frame.update({
                    "present": False, "motion": 0.0, "breathing_bpm": None, "heart_bpm": None,
                    "breathing_strength": 0.0, "heart_strength": 0.0,
                    "range_profile": [], "range_res_m": 0.0, "range_peak_m": None, "range_strength": 0.0,
                    "keypoints": [], "pose_ready": False,
                })
            # --- eldercare fall/emergency: feed ONLY real sensing observations.
            # Synthetic / demo frames suppress vitals (breathing -> None), which would
            # otherwise read as 'not breathing' and mint a false emergency, so the
            # monitor stays inactive (and is reset) whenever we are not live (§5.1).
            if sensing and not synthetic:
                fall_frame = frame
                if self.source == "vigil":
                    # The fall monitor was designed around STRICT motion-gated
                    # presence — its NO_BREATHING arm fires on present + still +
                    # no breath, so feeding it the HELD belief would mint a
                    # false emergency for a still person whose vitals haven't
                    # locked (§5.1). Fallen-resident coverage is unchanged:
                    # breathing-credited presence inside fall_signals_from_frame
                    # plus the vitals bridge/hold keep a downed body's breathing
                    # measured and counted.
                    fall_frame = {**frame,
                                  "present": getattr(self, "_occ_mode", None) == "live"}
                moving, breathing, present_static = fall_signals_from_frame(fall_frame)
                if not self._fall_feeding:
                    self.fall = FallMonitor()     # fresh clock on (re)entering live sensing
                    self._fall_feeding = True
                    self._fall_feed_start = frame["ts"]
                calibrated = (frame["ts"] - self._fall_feed_start) >= FALL_CALIB_SECS
                fall_state = self.fall.update(frame["ts"], moving=moving,
                                              breathing_detected=breathing,
                                              present_static=present_static, calibrated=calibrated)
                fall_state["active"] = True
                fall_state["note"] = ("live CSI sensing" if calibrated
                                      else "live CSI sensing — calibrating room baseline")
            else:
                self._fall_feeding = False
                fall_state = _fall_inactive(
                    "synthetic replay — fall monitoring inactive (no real person)"
                    if synthetic else "no live CSI reader — fall monitoring inactive")
            heartbeat = self._heartbeat_tick(
                normal=not bool(fall_state.get("alert"))
                and not (isinstance(anomaly, dict) and anomaly.get("state") == "anomaly")
            )
            frame["heartbeat"] = heartbeat
            self._ensure_frame_home_occupancy(frame)
            try:
                frame_json = json.dumps(frame).encode()
            except (TypeError, ValueError):
                frame_json = None    # handler falls back to per-request dumps
            with self._lock:
                self.latest = frame
                if frame_json is not None:
                    self.latest_json = frame_json
                self.latest_fall = fall_state
                self.latest_heartbeat = heartbeat
                if anomaly is not None:
                    self.latest_anomaly = anomaly
                    self.latest_baseline = self.detector.model.summary()
            self.tick += 1
            if self.save_every and self.tick % self.save_every == 0:
                self._save_model()
            time.sleep(period)

    def start(self):
        # Supervisor: a bug that raises inside the sensing loop must NOT
        # permanently stop detection on a safety product. If _loop unwinds we
        # record the fault (surfaced on /health) and restart it — engine state
        # (vitals/detector/baseline) lives on self, so sensing resumes instead
        # of dying silently behind a frozen last frame.
        def _supervised():
            while not self._stop:
                try:
                    self._loop()
                    return  # clean exit: self._stop was set
                except Exception as e:  # noqa: BLE001 - last-resort crash guard
                    self._loop_errors = getattr(self, "_loop_errors", 0) + 1
                    self._loop_last_error = f"{type(e).__name__}: {e}"
                    self._loop_last_error_ts = time.time()
                    traceback.print_exc()
                    time.sleep(1.0)
        threading.Thread(target=_supervised, daemon=True).start()

    def get(self):
        with self._lock:
            return dict(self.latest)

    def get_json(self):
        with self._lock:
            return self.latest_json

    def anomaly(self):
        with self._lock:
            return dict(self.latest_anomaly)

    def fall_status(self):
        with self._lock:
            return dict(self.latest_fall)

    def baseline(self):
        with self._lock:
            b = dict(self.latest_baseline)
        b["store"] = self.store_path or None
        return b

    def heartbeat_status(self, force: bool = False, normal: bool = True):
        if force:
            status = self._heartbeat_tick(normal=normal, force=True)
            with self._lock:
                self.latest_heartbeat = status
            return status
        with self._lock:
            return dict(self.latest_heartbeat)


def make_handler(engine):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):      # quiet
            pass

        def _send(self, code, payload, ctype="application/json"):
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # No Access-Control-Allow-Origin: the only client is the native SwiftUI
            # app (URLSession, same host, no CORS needed). Advertising ACAO:* let any
            # web page a buyer visited READ /frame,/anomaly,/fall,/baseline cross-origin
            # (occupancy/pose/fall/rPPG exfiltration). Omitting it makes the browser
            # discard those responses. Cross-context requests are additionally rejected
            # in _local_client_only() so drive-by pages can't drive /recalibrate either.
            try:
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def _local_client_only(self):
            """Reject browser-originated (drive-by / DNS-rebinding) requests.

            The native SwiftUI client sends a bare URLSession request with a
            loopback Host and no Origin/Referer. A web page attacking this
            loopback port ALWAYS carries an Origin (fetch/XHR) or a Referer
            (img/form navigation) pointing at its own site, and a rebinding
            attack forges a non-loopback Host. Rejecting either closes both the
            cross-origin read of sensing data and CSRF to the state-mutating
            /recalibrate route, without changing anything for the native app.
            """
            if self.headers.get("Origin") or self.headers.get("Referer"):
                return False
            host = (self.headers.get("Host") or "").strip()
            if not host:
                return True  # HTTP/1.0 loopback probe (e.g. urllib health check)
            if host.startswith("["):                       # [::1]:port
                hostname = host[1:host.index("]")] if "]" in host else host
            else:
                hostname = host.split(":", 1)[0]
            return hostname in ("127.0.0.1", "localhost", "::1")

        def do_GET(self):
            if not self._local_client_only():
                self._send(403, {"ok": False, "detail": "forbidden"})
                return
            if self.path.startswith("/frame"):
                body = engine.get_json()
                self._send(200, body if body is not None else engine.get())
            elif self.path.startswith("/anomaly"):
                self._send(200, engine.anomaly())
            elif self.path.startswith("/baseline"):
                self._send(200, engine.baseline())
            elif self.path.startswith("/fall"):
                self._send(200, engine.fall_status())
            elif self.path.startswith("/heartbeat"):
                try:
                    from urllib.parse import parse_qs, urlparse
                    q = parse_qs(urlparse(self.path).query)
                    force = str(q.get("force", ["0"])[0]).lower() in ("1", "true", "yes")
                    normal = str(q.get("normal", ["1"])[0]).lower() not in ("0", "false", "no")
                    self._send(200, engine.heartbeat_status(force=force, normal=normal))
                except Exception as e:
                    self._send(500, {"ok": False, "detail": str(e)})
            elif self.path.startswith("/recalibrate"):
                # RF run: per-room (?node=N) or whole-house floor relearn —
                # clears the quiet-envelope floor(s), the persisted entry,
                # the RTI link floors and the occupancy belief so every
                # calibration restarts on CURRENT link physics (Founder ask:
                # a per-room RF run button).
                try:
                    from urllib.parse import parse_qs, urlparse
                    q = parse_qs(urlparse(self.path).query)
                    node = int(q["node"][0]) if q.get("node") else None
                    self._send(200, engine.recalibrate(node))
                except Exception as e:
                    self._send(400, {"ok": False, "detail": str(e)})
            elif self.path.startswith("/health"):
                self._send(200, {
                    "ok": True,
                    "source": engine.source,
                    "model": "wifi-densepose pose_v1 (MIT, numpy port)",
                    "fleet": (engine.src.fleet_summary()
                              if hasattr(engine.src, "fleet_summary") else None),
                    "rate_hz": engine.rate,
                    "predict": {
                        "ready": engine.detector.model.ready,
                        "nights_observed": engine.detector.model.nights_observed,
                        "store": engine.store_path or None,
                    },
                    "heartbeat": engine.heartbeat_status(),
                    "note": ("replay data — not a live room measurement"
                             if engine.source == "replay" else
                             "live measurement — honesty-gated (vitals shown only above confidence)"),
                })
            else:
                self._send(200, b"Homefront sensing engine. GET /frame, /anomaly, /baseline, /fall, /heartbeat, or /health.\n",
                           ctype="text/plain")
    return H


def build_parser():
    ap = argparse.ArgumentParser()
    # Ship empty on the buyer OWN radio (CHARTER 5.2): the default source is the
    # live UDP CSI feed, never the bundled synthetic replay capture. "--source
    # replay" is an explicit dev/demo opt-in; the shipped app launches with udp.
    ap.add_argument("--source", default="vigil", choices=["replay", "udp", "vigil"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--csi-port", type=int, default=5005, help="UDP port the CSI reader listens on")
    ap.add_argument("--vigil-port", type=int, default=5566, help="UDP port the Vigil fleet source listens on")
    ap.add_argument("--rate", type=float, default=10.0)
    ap.add_argument("--store", default=default_store_path(),
                    help="learned-baseline store path (buyer's own data; empty by default)")
    ap.add_argument("--no-store", action="store_true", help="disable baseline persistence")
    ap.add_argument("--save-every", type=int, default=300, help="persist the baseline every N ticks")
    ap.add_argument("--no-attach-existing", action="store_true",
                    help="do not exit cleanly when an engine is already serving this host/port")
    return ap


def main():
    args = build_parser().parse_args()
    if not args.no_attach_existing:
        health = existing_engine_health(args.host, args.port)
        if health is not None:
            print(f"Homefront engine already serving on {args.host}:{args.port}; attaching to existing engine.", flush=True)
            return 0
    store_path = None if args.no_store else args.store
    engine = Engine(args.source, args.rate, csi_port=args.csi_port,
                    vigil_port=args.vigil_port, store_path=store_path,
                    save_every=args.save_every)
    srv = None

    def cleanup():
        if srv is not None:
            try:
                srv.server_close()
            except OSError:
                pass
        engine.stop()

    def handle_signal(_signum, _frame):
        cleanup()
        raise SystemExit(0)

    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, handle_signal)
    engine.start()
    srv = VigilHTTPServer((args.host, args.port), make_handler(engine))
    print(f"Homefront engine on http://{args.host}:{args.port}  source={args.source} rate={args.rate}Hz")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
