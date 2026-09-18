"""M3 — The Guardian Mesh: door events, ESP-NOW relay ingest, the mutual
vigil pact, the Ember presence surface and the deadman escalator.

Host side of firmware Forge M2/M3 (firmware/main/hall.[ch],
espnow_relay.[ch]); wire layouts are mirrored byte-for-byte in
``vigil.mesh.relay`` and cross-checked by tests/test_m3_*.py.
"""

from .deadman import Deadman, DeadmanThresholds
from .ember import Ember, EmberServer
from .pact import (
    FileDropTransport,
    LoopbackTransport,
    Pact,
    PactChannel,
    PactError,
    PactIdentity,
    SmtpImapTransport,
    generate_identity,
)
from .relay import (
    FleetPsk,
    RelayDeduper,
    RelayEvent,
    RelayListener,
    decode_event_dgram,
    encode_event_dgram,
    pack_espnow_frame,
    relay_action,
    unauth_bind_host,
    unpack_espnow_frame,
)

__all__ = [
    "Deadman", "DeadmanThresholds", "Ember", "EmberServer",
    "FileDropTransport", "LoopbackTransport", "Pact", "PactChannel",
    "PactError", "PactIdentity", "SmtpImapTransport", "generate_identity",
    "FleetPsk", "RelayDeduper", "RelayEvent", "RelayListener",
    "decode_event_dgram", "encode_event_dgram", "pack_espnow_frame",
    "relay_action", "unauth_bind_host", "unpack_espnow_frame",
]
