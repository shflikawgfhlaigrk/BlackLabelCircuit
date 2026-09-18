"""M1 — Presence signatures + lock-only presence authentication.

SECURITY ENVELOPE (binding): presence signatures LOCK the machine and GATE
vault access; they never auto-UNLOCK — unlocking always goes through the
OS's own authentication (password / Touch ID). CSI presence signatures are
a coarse biometric; treat them as a convenience / second factor, never a
primary authenticator. There is deliberately NO unlock API anywhere in
this module: the failure mode of a spoofed or mis-matched signature is a
lock (fail-closed), never an unlock.

Operating envelope: signatures are built from seated CSI windows [t, 52]
at fs = 100 Hz in the desk geometry. The feature vector is (a) the
52-dim normalized subcarrier amplitude profile shape, (b) the breathing-
band spectral shape (0.08–0.7 Hz, 16 fixed bins), and (c) micro-motion
texture stats (2–10 Hz per-subcarrier energy distribution moments).
Separation numbers measured on synthetic bodies do NOT transfer to real
subjects — real biometric separation is hardware/subject-gated.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy import signal, stats

BREATH_BAND = (0.08, 0.7)   # Hz — breathing-band spectral shape
TEXTURE_BAND = (2.0, 10.0)  # Hz — micro-motion texture
N_SHAPE_BINS = 16
_EPS = 1e-12


class PresenceSignature:
    """A coarse RF biometric template: per-dimension mean + diagonal
    variance over enrollment windows, with npz persistence.

    `match` returns (score in [0, 1], is_owner). Score is a Gaussian
    kernel over the mean per-dimension squared z-distance to the template.
    """

    def __init__(self, mu: np.ndarray, var: np.ndarray, tag: str,
                 threshold: float = 0.5, fs: float = 100.0,
                 n_enrolled: int = 0) -> None:
        self.mu = np.asarray(mu, dtype=float)
        self.var = np.asarray(var, dtype=float)
        self.tag = str(tag)
        self.threshold = float(threshold)
        self.fs = float(fs)
        self.n_enrolled = int(n_enrolled)

    # -- features ------------------------------------------------------------

    @staticmethod
    def features(window: np.ndarray, fs: float = 100.0) -> np.ndarray:
        """Feature vector from one seated window [t, 52]."""
        x = np.asarray(window, dtype=float)
        # (a) subcarrier amplitude profile shape, 52-dim normalized
        prof = x.mean(axis=0)
        v = prof - prof.mean()
        v = v / (np.linalg.norm(v) + _EPS)
        # (b) breathing-band spectral shape
        xd = signal.detrend(x, axis=0)
        q = max(1, int(round(fs / 10.0)))
        fs_d = fs / q
        y = signal.decimate(xd, q, axis=0, zero_phase=True) if q > 1 else xd
        f, p = signal.welch(y, fs=fs_d, nperseg=min(y.shape[0], 200), axis=0)
        pm = p.mean(axis=1)
        grid = np.linspace(BREATH_BAND[0], BREATH_BAND[1], N_SHAPE_BINS)
        shape = np.interp(grid, f, pm)
        shape = shape / (shape.sum() + _EPS)
        # (c) micro-motion texture: 2-10 Hz energy distribution moments
        sos = signal.butter(4, TEXTURE_BAND, btype="bandpass", fs=fs,
                            output="sos")
        z = signal.sosfiltfilt(sos, xd, axis=0)
        e = z.var(axis=0)
        tex = np.array([
            float(np.log(e.sum() + _EPS)),
            float(e.std() / (e.mean() + _EPS)),
            float(stats.skew(e)),
            float(stats.kurtosis(e)),
        ])
        return np.concatenate([v, shape, tex])

    # -- enrollment / matching ------------------------------------------------

    @classmethod
    def enroll(cls, windows: list[np.ndarray], tag: str, fs: float = 100.0,
               threshold: float = 0.5) -> "PresenceSignature":
        """Build a template from >= 2 seated windows of the same subject."""
        if len(windows) < 2:
            raise ValueError("enrollment needs at least 2 windows")
        feats = np.stack([cls.features(w, fs) for w in windows])
        mu = feats.mean(axis=0)
        var = feats.var(axis=0)
        # variance floor: guard against degenerate per-dim variances
        var = np.maximum(var, (0.05 * np.abs(mu)) ** 2)
        var = np.maximum(var, 1e-10)
        return cls(mu, var, tag, threshold=threshold, fs=fs,
                   n_enrolled=len(windows))

    def match(self, window: np.ndarray) -> tuple[float, bool]:
        """(score in [0, 1], is_owner). Coarse biometric — see module
        docstring; a low score can only LOCK, never unlock."""
        f = self.features(window, self.fs)
        z2 = float(((f - self.mu) ** 2 / self.var).mean())
        score = float(np.exp(-z2 / 16.0))
        return score, score >= self.threshold

    # -- persistence -----------------------------------------------------------

    def save(self, path: str | Path) -> None:
        np.savez_compressed(Path(path), mu=self.mu, var=self.var,
                            tag=np.array(self.tag),
                            threshold=np.array(self.threshold),
                            fs=np.array(self.fs),
                            n_enrolled=np.array(self.n_enrolled))

    @classmethod
    def load(cls, path: str | Path) -> "PresenceSignature":
        with np.load(Path(path), allow_pickle=False) as z:
            return cls(z["mu"], z["var"], str(z["tag"]),
                       threshold=float(z["threshold"]), fs=float(z["fs"]),
                       n_enrolled=int(z["n_enrolled"]))


def _default_macos_lock() -> bool:
    """Default lock hook: macOS display sleep (forces the OS lock screen
    when 'require password immediately' is set). Returns True if invoked.
    NEVER paired with any unlock — unlock is the OS's job."""
    if sys.platform == "darwin":
        subprocess.run(["/usr/bin/pmset", "displaysleepnow"], check=False)
        return True
    return False


class PresenceAuth:
    """Continuous lock-only presence gate fed by the DeskSample stream.

    States: owner seated -> "owner-present" (the OS *may* stay unlocked;
    we never unlock anything); empty chair >= `empty_grace_s` -> lock hook
    fires; unknown signature seated -> lock hook + `desk.intruder` event.

    Every lock invocation is recorded in `.actions` (for tests and audit),
    whether or not a platform hook actually ran. `vault_gate()` is the
    Sovereign integration point: True only while the owner is live at the
    desk. There is NO unlock method by design (see module docstring).
    """

    def __init__(self, node, signature: PresenceSignature,
                 lock_cmd=None, empty_grace_s: float = 2.0, bus=None) -> None:
        self.node = node
        self.signature = signature
        self.lock_cmd = lock_cmd  # injectable callable; None -> macOS default
        self.empty_grace_s = float(empty_grace_s)
        self.bus = bus if bus is not None else getattr(node, "bus", None)
        self.actions: list[dict] = []
        self.state = "unknown"
        self._empty_since: float | None = None
        self._lock_fired = False

    # -- stream ---------------------------------------------------------------

    def step(self, sample, window: np.ndarray | None = None) -> str:
        """Feed one DeskSample (and, when available, its raw window for
        signature matching). All timing comes from `sample.t` — no wall
        clock, no sleeps. Returns the new state."""
        t = float(sample.t)
        if sample.occupancy == "empty":
            self.state = "empty"
            if self._empty_since is None:
                self._empty_since = t
            if not self._lock_fired and (t - self._empty_since) >= self.empty_grace_s:
                self._lock(t, "empty-desk")
            return self.state
        self._empty_since = None
        if window is None:
            # occupancy without identity: state unchanged; never an unlock
            return self.state
        score, is_owner = self.signature.match(window)
        if is_owner:
            self.state = "owner-present"
            # re-arm the lock trigger for the *next* departure/intrusion.
            # This is NOT an unlock — unlocking is the OS's job.
            self._lock_fired = False
        else:
            self.state = "intruder"
            if self.bus is not None:
                self.bus.publish("desk.intruder", {
                    "t": t, "score": round(score, 4),
                    "confidence": round(1.0 - score, 4),
                })
            if not self._lock_fired:
                self._lock(t, "unknown-presence")
        return self.state

    def process_window(self, window: np.ndarray, t: float | None = None) -> str:
        """Convenience: run the node then step the auth loop."""
        sample = self.node.process(window, t)
        return self.step(sample, window)

    # -- lock (the ONLY actuator) -----------------------------------------------

    def _lock(self, t: float, reason: str) -> None:
        self._lock_fired = True
        if self.lock_cmd is not None:
            self.lock_cmd()
            executed = True
        else:
            executed = _default_macos_lock()
        self.actions.append({"t": float(t), "action": "lock",
                             "reason": reason, "executed": executed})
        if self.bus is not None:
            self.bus.publish("desk.lock", {"t": float(t), "reason": reason,
                                           "confidence": 1.0})

    # -- Sovereign integration ---------------------------------------------------

    def vault_gate(self) -> bool:
        """True only while the owner is live at the desk right now. Gates
        vault access; grants nothing else. Never unlocks anything."""
        return self.state == "owner-present"
