"""M2 — THE HOUSE LEDGER: ambient life record built from derived events.

Operating envelope: consumes bus events (gate1.candidate, fall.*, vitals.*,
ledger.steam, door.event) and [t,52] float32 CSI amplitude windows at
fs=100 Hz; produces an append-only event graph, a timeline scrubber and
daily ADL rollups. Runs headless on the host, numpy/scipy + stdlib only.

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification.
"""

from .adl import ADLReport, DailyRollup
from .graph import DOOR_TOPIC, EventGraph, HeuristicTagger, LedgerIntegrityError
from .scrubber import Scrubber
from .steam import STEAM_TOPIC, SteamDetector, SteamEvent

__all__ = [
    "ADLReport",
    "DailyRollup",
    "DOOR_TOPIC",
    "EventGraph",
    "HeuristicTagger",
    "LedgerIntegrityError",
    "Scrubber",
    "STEAM_TOPIC",
    "SteamDetector",
    "SteamEvent",
]
