"""D4 — Confidence gating + honest display for vitals.

Operating envelope: this is the product rule that lets vitals ship. The
extractors (breathing.py, heart.py) are frontier estimators whose accuracy
is NOT guaranteed on arbitrary signals; what IS guaranteed is honesty:

- Every estimate is logged (bus + event log) with bpm AND confidence,
  regardless of quality — the record is never gated.
- Display is gated per metric on `Thresholds.breathing_min_confidence` /
  `Thresholds.hr_min_confidence`. Below threshold the UI shows exactly
  "listening…" and a signal-quality meter driven by `DisplayState.quality`;
  it never shows a number the pipeline does not believe.

Nothing here touches raw CSI; payloads are scalars only (bus.EventLog safe).
"""

from __future__ import annotations

import time
from collections import defaultdict
from dataclasses import dataclass, field

import numpy as np

LISTENING_TEXT = "listening…"

_METRIC_TOPICS = {"breathing": "vitals.breathing", "hr": "vitals.hr"}


@dataclass
class VitalsEstimate:
    """A single vitals estimate: rate in BPM, confidence in [0, 1], and a
    detail dict documenting how the number was obtained (paths, SNRs, ...)."""

    bpm: float
    confidence: float
    detail: dict = field(default_factory=dict)


@dataclass
class DisplayState:
    show: bool
    text: str
    quality: float  # confidence in [0,1]; drives the signal-quality meter


class VitalsGate:
    """Per-metric confidence gate between estimator and display."""

    def __init__(self, thresholds) -> None:
        self.thresholds = thresholds

    def _threshold(self, metric: str) -> float:
        if metric == "breathing":
            return float(self.thresholds.breathing_min_confidence)
        if metric == "hr":
            return float(self.thresholds.hr_min_confidence)
        raise ValueError(f"unknown vitals metric {metric!r}")

    def display(self, metric: str, est: VitalsEstimate) -> DisplayState:
        thr = self._threshold(metric)
        quality = float(np.clip(est.confidence, 0.0, 1.0))
        if est.confidence >= thr:
            return DisplayState(True, f"{est.bpm:.0f} bpm", quality)
        return DisplayState(False, LISTENING_TEXT, quality)

    def log_event(self, bus, room: str, metric: str, est: VitalsEstimate,
                  t: float | None = None) -> dict:
        """Publish vitals.<metric> with bpm + confidence ALWAYS.

        The event log stores both so nightly analysis can re-gate offline;
        only *display* is gated (see .display)."""
        self._threshold(metric)  # validate metric name
        payload = {
            "room": room,
            "t": time.time() if t is None else float(t),
            "bpm": float(est.bpm),
            "confidence": float(est.confidence),
        }
        bus.publish(_METRIC_TOPICS[metric], payload)
        return payload


class NightlySummary:
    """Accumulates per-window vitals estimates over a night and reports
    coverage, median rates and the confidence distribution.

    Feed `.add(t, metric, est, window_coverage)` once per qualifying window
    estimate (window_coverage = WindowManager.coverage for that metric at
    that time). `.report()` returns, per metric:

    - coverage_pct: mean window_coverage * 100
    - median_bpm: median of all estimates (gated and ungated — honesty over
      cosmetics; the confidence histogram tells you how much to trust it)
    - median_confidence
    - confidence_hist: 10 equal bins over [0, 1]
    - n_windows: number of samples fed
    """

    def __init__(self) -> None:
        self._rows: dict[str, list[tuple[float, float, float, float]]] = defaultdict(list)

    def add(self, t: float, metric: str, est: VitalsEstimate,
            window_coverage: float) -> None:
        self._rows[metric].append(
            (float(t), float(est.bpm), float(est.confidence), float(window_coverage))
        )

    def report(self) -> dict:
        out: dict[str, dict] = {}
        for metric, rows in sorted(self._rows.items()):
            bpms = np.array([r[1] for r in rows], float)
            confs = np.array([r[2] for r in rows], float)
            covs = np.array([r[3] for r in rows], float)
            hist, _ = np.histogram(np.clip(confs, 0.0, 1.0), bins=10, range=(0.0, 1.0))
            out[metric] = {
                "coverage_pct": float(covs.mean() * 100.0) if rows else 0.0,
                "median_bpm": float(np.median(bpms)) if rows else float("nan"),
                "median_confidence": float(np.median(confs)) if rows else float("nan"),
                "confidence_hist": hist.tolist(),
                "n_windows": len(rows),
            }
        return out

    def render_text(self) -> str:
        rep = self.report()
        lines = ["VIGIL — nightly vitals summary", "=" * 40]
        if not rep:
            lines.append("(no vitals windows recorded)")
        for metric, r in rep.items():
            lines.append(
                f"{metric:>9}: median {r['median_bpm']:6.1f} bpm | "
                f"coverage {r['coverage_pct']:5.1f}% | windows {r['n_windows']}"
            )
            bars = "".join(
                " .:-=+*#%@"[min(9, int(round(9 * c / max(1, max(r["confidence_hist"])))))]
                for c in r["confidence_hist"]
            )
            lines.append(f"           confidence 0[{bars}]1  "
                         f"(median {r['median_confidence']:.2f})")
        return "\n".join(lines)
