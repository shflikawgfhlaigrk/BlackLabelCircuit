"""Track F — home mapping: the layered answer to "where is everything".

Layer order is strict (see registry.py design doc): F1 labels first,
F2 fingerprints second, F3/F4 geometry as presentation only. Detection
NEVER depends on layers above F1. F5 (transitions.py) is the zero-setup
path: the home maps and labels itself from ordinary living.
"""

from .fingerprint import FingerprintDB, MatchSmoother, RoomFingerprint, WalkTour
from .fuse import (FusedLayout, FusedResult, doors, excess_loss_map,
                   footprint, material_hint, room_cells, smacof, wall_map)
from .geometry import (SelfSurvey, SurveyResult, classical_mds, knn_adjacency,
                       procrustes, rssi_to_distance)
from .plan import Plan, from_rects, from_roomplan_json, from_walk_trace
from .registry import ZoneRegistry
from .tracker import AWAY, NextRoomPredictor, RoomTracker
from .transitions import (DRIFT_TOPIC, BehavioralLabeler, TransitionGraph)

__all__ = [
    "ZoneRegistry",
    "WalkTour", "FingerprintDB", "RoomFingerprint", "MatchSmoother",
    "SelfSurvey", "SurveyResult", "rssi_to_distance", "classical_mds",
    "procrustes", "knn_adjacency",
    "Plan", "from_roomplan_json", "from_walk_trace", "from_rects",
    "TransitionGraph", "BehavioralLabeler", "DRIFT_TOPIC",
    "FusedLayout", "FusedResult", "room_cells", "doors", "smacof",
    "wall_map", "excess_loss_map", "footprint", "material_hint",
    "RoomTracker", "NextRoomPredictor", "AWAY",
]
