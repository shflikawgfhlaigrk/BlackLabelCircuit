"""M4 — "The Machine Whisperer": passive appliance monitoring over CSI.

Operating envelope: consumes the shared 100 Hz [t,52] CSI amplitude contract
(CONTRACTS.md §2) and works in the 10-50 Hz mechanical band, above the human
motion/vitals bands used by Tracks C/D. Nyquist is 50 Hz: machines spinning
faster than 3000 RPM alias — we see low-frequency mechanical/vibration
coupling and on/off duty rhythms, not exact RPM (line frequencies are
fingerprints, not tachometer readings).

Submodules:
- spectra: `SpectraProfiler` — appliance signature discovery + duty rhythms.
- drift:   `DriftWatch` — EWMA baselines + predictive-maintenance alarms.
- safety:  `SafetyRules` — presence-aware stove-unattended rule (bus only).
- survey:  `SurveyGrid` — walk-survey attenuation heatmap, anomaly TRIAGE.
- synth:   module-local synthetic generators for tests (real-appliance
  clustering accuracy and the wet-wall delta are hardware-gated).
"""

from .drift import DriftWatch
from .safety import MachineSafetyConfig, SafetyRules, ZoneBinding
from .spectra import ApplianceSignature, SpectraProfiler
from .survey import SurveyGrid, SurveyPoint, point_features

__all__ = [
    "ApplianceSignature",
    "DriftWatch",
    "MachineSafetyConfig",
    "SafetyRules",
    "SpectraProfiler",
    "SurveyGrid",
    "SurveyPoint",
    "ZoneBinding",
    "point_features",
]
