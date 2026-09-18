"""Vigil vitals subsystem (Track D).

Operating envelope: breathing (0.08–0.7 Hz) and heart rate (0.8–2.2 Hz)
from raw CSI amplitude windows [t, 52] at fs=100, extracted ONLY inside
qualifying still windows (windows.py) and displayed ONLY above per-metric
confidence gates (gating.py). Every estimate is logged with its confidence;
the display gate (D4) is the product rule that lets these frontier
estimators ship honestly.
"""

from .apnea import ApneaMonitor
from .breathing import BreathingExtractor
from .gating import DisplayState, NightlySummary, VitalsEstimate, VitalsGate
from .heart import HeartExtractor
from .vmd import vmd
from .windows import WindowManager, agreement

__all__ = [
    "ApneaMonitor",
    "BreathingExtractor",
    "DisplayState",
    "HeartExtractor",
    "NightlySummary",
    "VitalsEstimate",
    "VitalsGate",
    "WindowManager",
    "agreement",
    "vmd",
]
