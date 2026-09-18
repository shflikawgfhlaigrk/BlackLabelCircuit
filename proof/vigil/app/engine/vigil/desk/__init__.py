"""M1 — THE SENTINEL DESK.

Presence-authenticated desk + physiological risk gate for a trader's own
pre-committed rules. Seated-at-Mac CSI geometry (short range, stationary
subject — the best case for amplitude-only vitals).

Sub-modules
-----------
- node:         DeskNode — occupancy + desk-tuned vitals (desk.* bus topics)
- presence:     PresenceSignature / PresenceAuth — lock-only presence gating
- tilt:         TiltEngine — self-referential stress vs rule-break lead-lag
- intervention: Intervention — pre-committed rule enforcement with override
- synth:        module-local synthetic scenario generators (tests only)
"""

from .intervention import Intervention
from .node import DeskNode, DeskSample
from .presence import PresenceAuth, PresenceSignature
from .tilt import TiltEngine, TiltProfile, TiltState

__all__ = [
    "DeskNode",
    "DeskSample",
    "PresenceAuth",
    "PresenceSignature",
    "TiltEngine",
    "TiltProfile",
    "TiltState",
    "Intervention",
]
