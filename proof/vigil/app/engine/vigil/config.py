"""Vigil configuration tree (CONTRACTS.md §5).

Operating envelope: one JSON file describes the whole installation — fleet
(nodes, rooms, zones), radio channel, host, detection thresholds, vitals
confidence gates and alert contacts. All code paths take an explicit path,
and the DEFAULT resolves through vigil_paths — so VIGIL_HOME / HOMEFRONT_DATA_DIR
isolate a test or QA run instead of it writing the owner's live ~/.vigil.
Secrets (Twilio) are env-var *names*, never values, so the config file is safe to sync.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

try:
    import vigil_paths
except ImportError:  # engine/ not on sys.path (vigil pkg imported standalone)
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import vigil_paths


def default_path() -> Path:
    """The config file's override-aware default, resolved at CALL time.

    A module constant would freeze at import (and `Path.home()` honours $HOME but NOT
    VIGIL_HOME), so `save()` — which mkdirs its parent — could still create and write the
    owner's real ~/.vigil during a QA run.
    """
    return Path(vigil_paths.state_path("config.json"))


def __getattr__(name):
    # Back-compat for `from vigil.config import DEFAULT_PATH`, resolved per access.
    if name == "DEFAULT_PATH":
        return default_path()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


@dataclass
class NodeConfig:
    node_id: int
    room: str = ""
    zone: str = ""  # e.g. "bed" for the vitals zone node
    mac: str = ""
    transport: str = "udp"  # "udp" | "serial"
    serial_port: str = ""


@dataclass
class Thresholds:
    # C1 — Gate 1 energy trigger
    gate1_mad_k: float = 6.0          # trigger at median + k*MAD of motion energy
    gate1_rise_ms: float = 800.0
    gate1_refractory_s: float = 2.0
    # C4 — stillness confirmation
    stillness_window_s: float = 15.0
    stillness_factor: float = 2.0     # "near baseline" = energy < factor * quiet level
    # D1 — vitals qualifying windows
    quiet_energy_factor: float = 3.0
    breathing_min_still_s: float = 30.0
    hr_min_still_s: float = 60.0
    # D4 — confidence gates (per metric)
    breathing_min_confidence: float = 0.5
    hr_min_confidence: float = 0.6
    # D5 — absence-of-breathing alarm
    apnea_loss_s: float = 30.0
    apnea_hysteresis_s: float = 10.0


@dataclass
class AlertsConfig:
    contacts: list[dict] = field(default_factory=list)  # {name, phone, priority}
    escalation_s: float = 60.0
    twilio_sid_env: str = "TWILIO_ACCOUNT_SID"
    twilio_token_env: str = "TWILIO_AUTH_TOKEN"
    twilio_from_env: str = "TWILIO_FROM_NUMBER"


@dataclass
class VigilConfig:
    nodes: list[NodeConfig] = field(default_factory=list)
    rooms: dict[str, list[int]] = field(default_factory=dict)  # room -> node_ids
    vitals_zone: dict[str, int] = field(default_factory=dict)  # room -> node_id
    channel: int = 6
    host_ip: str = "0.0.0.0"
    udp_port: int = 5566
    ring_buffer_s: float = 300.0
    thresholds: Thresholds = field(default_factory=Thresholds)
    alerts: AlertsConfig = field(default_factory=AlertsConfig)

    def node(self, node_id: int) -> NodeConfig:
        for n in self.nodes:
            if n.node_id == node_id:
                return n
        raise KeyError(f"unknown node_id {node_id}")

    def room_of(self, node_id: int) -> str:
        for room, ids in self.rooms.items():
            if node_id in ids:
                return room
        return ""

    def save(self, path: str | Path | None = None) -> None:
        # path=None resolves at CALL time: a DEFAULT_PATH default arg binds at def time and
        # would mkdir + write the owner's real ~/.vigil regardless of VIGIL_HOME.
        p = Path(path) if path is not None else default_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path | None = None) -> "VigilConfig":
        raw = json.loads(Path(path if path is not None else default_path()).read_text(encoding="utf-8"))
        cfg = cls(
            nodes=[NodeConfig(**n) for n in raw.get("nodes", [])],
            rooms={k: list(v) for k, v in raw.get("rooms", {}).items()},
            vitals_zone=dict(raw.get("vitals_zone", {})),
            channel=raw.get("channel", 6),
            host_ip=raw.get("host_ip", "0.0.0.0"),
            udp_port=raw.get("udp_port", 5566),
            ring_buffer_s=raw.get("ring_buffer_s", 300.0),
            thresholds=Thresholds(**raw.get("thresholds", {})),
            alerts=AlertsConfig(**raw.get("alerts", {})),
        )
        return cfg
