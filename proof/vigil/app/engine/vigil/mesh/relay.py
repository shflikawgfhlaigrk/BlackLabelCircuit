"""M3 — host side of the door-event / ESP-NOW relay path.

Operating envelope: byte-exact mirror of ``firmware/main/hall.h`` (the
0xA5 0x5E event frame, UDP host port 5569) and ``firmware/main/
espnow_relay.h`` (the 0xA5 0x5F signed ESP-NOW frame). Layout constants
here are cross-checked against the C headers by
``tests/test_m3_event_frame.py`` / ``test_m3_relay.py`` — keep in
lockstep. Also holds the pure-python reference of the firmware's
dedupe/TTL relay policy (``RelayDeduper`` / ``relay_action``), tested
host-side so the C mirror has one executable truth, and the fleet-PSK
management helper (generate / store 0600 / provision over the vigilctl
control plane, cmd 0x06 — mirrored in ``control.h``).

Everything is stdlib; no firmware or radio is required (the actual ESP-NOW
hop is hardware-gated).
"""

from __future__ import annotations

import hmac
import hashlib
import os
import secrets
import socket
import struct
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from ..bus import EventBus

# Sentinel so RelayListener(psk=None) can explicitly request unauthenticated mode,
# distinct from "argument omitted" (which loads the provisioned fleet PSK).
_UNSET = object()

# ---------------------------------------------------------------------------
# Event frame (0xA5 0x5E) — mirror of firmware/main/hall.h
# ---------------------------------------------------------------------------

EVT_MAGIC = b"\xa5\x5e"
EVT_SIZE = 14
EVT_DGRAM_SIZE = 2 + EVT_SIZE          # 16
EVENT_PORT = 5569
_EVT_FMT = "<BBhQBB"                   # node_id, event, value, ts_us, flags, hops

EVT_FLAG_RELAYED = 0x01

EVT_DOOR_OPEN = 1
EVT_DOOR_CLOSE = 2
EVT_HALL_RAW = 3
EVT_FALL = 4
EVT_APNEA = 5
EVT_HEALTH = 6

EVENT_NAMES = {
    EVT_DOOR_OPEN: "door-open",
    EVT_DOOR_CLOSE: "door-close",
    EVT_HALL_RAW: "hall-raw",
    EVT_FALL: "fall",
    EVT_APNEA: "apnea",
    EVT_HEALTH: "health",
}

assert struct.calcsize(_EVT_FMT) == EVT_SIZE


@dataclass
class RelayEvent:
    """One decoded node event (direct or mesh-relayed)."""

    origin: int          # node_id of the node that saw the event
    event: int           # EVT_* code
    value: int           # event-specific i16
    ts_us: int           # origin node clock (us since boot)
    relayed: bool = False
    hops: int = 0

    @property
    def event_name(self) -> str:
        return EVENT_NAMES.get(self.event, f"event-{self.event}")

    @property
    def t(self) -> float:
        return self.ts_us / 1e6


def encode_event_dgram(evt: RelayEvent) -> bytes:
    flags = EVT_FLAG_RELAYED if evt.relayed else 0
    return EVT_MAGIC + struct.pack(
        _EVT_FMT, evt.origin & 0xFF, evt.event & 0xFF, evt.value,
        evt.ts_us, flags, evt.hops & 0xFF,
    )


def decode_event_dgram(dgram: bytes) -> RelayEvent:
    # Tolerate the authenticated 24-byte form (16-byte frame + 8-byte tag): the tag is
    # verified separately by event_dgram_authentic(); here we decode the leading frame.
    if len(dgram) not in (EVT_DGRAM_SIZE, EVT_SIGNED_DGRAM_SIZE) or dgram[:2] != EVT_MAGIC:
        raise ValueError("bad event frame")
    node_id, event, value, ts_us, flags, hops = struct.unpack(_EVT_FMT, dgram[2:EVT_DGRAM_SIZE])
    return RelayEvent(origin=node_id, event=event, value=value, ts_us=ts_us,
                      relayed=bool(flags & EVT_FLAG_RELAYED), hops=hops)


# ---------------------------------------------------------------------------
# Host uplink authentication (0xA5 0x5E on :5569)
# ---------------------------------------------------------------------------
# The node→host event frame was UNSIGNED, so any LAN peer could send a forged
# `fall`/`apnea` datagram to :5569 and fan out a real emergency (iMessage-to-owner,
# Sosumi, spoken alert). The ESP-NOW relay plane (0xA5 0x5F) is already HMAC-signed
# with the fleet PSK; authenticate the host uplink with the SAME key. When a fleet
# PSK is provisioned host-side, a valid 8-byte tag (over the 16-byte frame) is
# REQUIRED and forged/unsigned frames are dropped (fail-closed on the emergency path).
# With NO PSK the frame check cannot fail-close, so the listener fails closed at the
# socket instead: it binds loopback only (see unauth_bind_host) so the un-provisioned
# demo never exposes the emergency fan-out to the LAN.

EVT_TAG_LEN = 8                             # matches ESPNOW_TAG_LEN (relay plane truncation)
EVT_SIGNED_DGRAM_SIZE = EVT_DGRAM_SIZE + EVT_TAG_LEN   # 24


def event_tag(psk: bytes, dgram: bytes) -> bytes:
    """HMAC-SHA256/8 over the 16-byte host event frame, keyed by the fleet PSK.
    Firmware (firmware/main/hall.h) must append this tag to the 0xA5 0x5E frame."""
    if len(psk) != PSK_LEN:
        raise ValueError("fleet PSK must be 32 bytes")
    return hmac.new(psk, bytes(dgram[:EVT_DGRAM_SIZE]), hashlib.sha256).digest()[:EVT_TAG_LEN]


def event_dgram_authentic(dgram: bytes, psk: bytes | None) -> bool:
    """Whether a :5569 datagram may be acted on.

    psk is None (no fleet PSK provisioned host-side) => unauthenticated/legacy mode:
    accept a well-formed frame (16- or 24-byte) so an un-provisioned demo keeps
    working. psk set => REQUIRE the 24-byte signed form with a matching tag; drop
    anything else (forged, unsigned, wrong key). constant-time compare.
    """
    if len(dgram) < EVT_DGRAM_SIZE or dgram[:2] != EVT_MAGIC:
        return False
    if psk is None:
        return len(dgram) in (EVT_DGRAM_SIZE, EVT_SIGNED_DGRAM_SIZE)
    if len(dgram) != EVT_SIGNED_DGRAM_SIZE:
        return False
    return hmac.compare_digest(dgram[EVT_DGRAM_SIZE:EVT_SIGNED_DGRAM_SIZE], event_tag(psk, dgram))


def default_psk_path():
    """Canonical host-side fleet-PSK file (via VigilPaths, honoring VIGIL_HOME)."""
    try:
        import vigil_paths
        return vigil_paths.state_path("fleet.psk")
    except Exception:
        return None


def legacy_psk_path():
    """Pre-b14 provisioning wrote the key as ``fleet_psk.hex`` (same directory, same
    hex format). Real installs carry ONLY that filename, so a loader that knows just
    the canonical ``fleet.psk`` never finds a key and every :5569 uplink silently
    runs unauthenticated — the exact VIGIL-6 release failure. The loader below falls
    back to this name so an already-provisioned fleet authenticates without being
    re-provisioned."""
    try:
        import vigil_paths
        return vigil_paths.state_path("fleet_psk.hex")
    except Exception:
        return None


def load_fleet_psk(path=None):
    """Load the 32-byte fleet PSK, or None if not provisioned. None => the :5569
    listeners run in unauthenticated/legacy mode, warn once, and bind loopback-only
    (see ``unauth_bind_host``). With no explicit ``path`` the canonical file is
    tried first, then the legacy ``fleet_psk.hex`` name existing installs carry.

    Startup is deliberately file-only. It never invokes the macOS Keychain or any
    credential subprocess, so a background sidecar/watchdog cannot open SecurityAgent.
    Provisioning writes the private 0600 file explicitly; older Keychain items are left
    untouched and are never deleted or queried from this background path.
    """
    try:
        p = path or default_psk_path()
        if p and os.path.exists(p):
            return FleetPsk.load(p).psk
        if path is None:
            legacy = legacy_psk_path()
            if legacy and os.path.exists(legacy):
                return FleetPsk.load(legacy).psk
    except Exception:
        return None
    return None


# Wildcard binds: every interface, i.e. reachable from the whole LAN.
_WILDCARD_HOSTS = ("", "0.0.0.0", "::", "*")

#: Escape hatch for an un-provisioned bring-up on a trusted lab LAN. Anything other
#: than "1" keeps the fail-closed loopback bind.
UNAUTH_LAN_ENV = "VIGIL_RELAY_UNAUTH_LAN"


def unauth_bind_host(host: str, psk: bytes | None, env=None) -> str:
    """The host a :5569 listener may actually bind.

    With a fleet PSK provisioned, forged frames are dropped by
    ``event_dgram_authentic`` and a wildcard bind is fine. WITHOUT one the listener
    accepts any well-formed unsigned frame — including ``fall``, which fans out a real
    emergency (iMessage-to-owner, Sosumi, spoken alert) and is never refractory-gated.
    Binding every interface would hand that primitive to any LAN peer, so an
    unauthenticated listener is downgraded to loopback: the accepted risk stays bounded
    to code already running on this host. Set ``VIGIL_RELAY_UNAUTH_LAN=1`` to opt back
    into the wildcard bind on a trusted lab LAN.
    """
    env = os.environ if env is None else env
    if psk is not None or host not in _WILDCARD_HOSTS:
        return host
    if env.get(UNAUTH_LAN_ENV, "") == "1":
        return host
    return "::1" if host == "::" else "127.0.0.1"


# ---------------------------------------------------------------------------
# ESP-NOW relay frame (0xA5 0x5F) — mirror of firmware/main/espnow_relay.h
# ---------------------------------------------------------------------------

ESPNOW_MAGIC = b"\xa5\x5f"
ESPNOW_FRAME_SIZE = 25
ESPNOW_TAG_LEN = 8
ESPNOW_TTL = 4
ESPNOW_DEDUPE_N = 16
PSK_LEN = 32
_ESPNOW_BODY_FMT = "<BBHBhQ"           # ttl, origin, seq, event, value, ts_us

assert 2 + struct.calcsize(_ESPNOW_BODY_FMT) + ESPNOW_TAG_LEN == ESPNOW_FRAME_SIZE


def espnow_tag(psk: bytes, frame: bytes) -> bytes:
    """HMAC-SHA256/8 over the pre-tag bytes with the ttl byte zeroed
    (ttl mutates per hop; everything else is authenticated)."""
    if len(psk) != PSK_LEN:
        raise ValueError("fleet PSK must be 32 bytes")
    macd = frame[:2] + b"\x00" + frame[3 : ESPNOW_FRAME_SIZE - ESPNOW_TAG_LEN]
    return hmac.new(psk, macd, hashlib.sha256).digest()[:ESPNOW_TAG_LEN]


def pack_espnow_frame(psk: bytes, origin: int, seq: int, event: int,
                      value: int, ts_us: int, ttl: int = ESPNOW_TTL) -> bytes:
    body = struct.pack(_ESPNOW_BODY_FMT, ttl & 0xFF, origin & 0xFF,
                       seq & 0xFFFF, event & 0xFF, value, ts_us)
    frame = ESPNOW_MAGIC + body + b"\x00" * ESPNOW_TAG_LEN
    return ESPNOW_MAGIC + body + espnow_tag(psk, frame)


def unpack_espnow_frame(psk: bytes, frame: bytes) -> tuple[int, RelayEvent, int]:
    """Verify + decode one ESP-NOW frame.

    Returns (ttl, RelayEvent, seq). Raises ValueError on bad magic/length
    and on tag mismatch (tamper or wrong fleet PSK).
    """
    if len(frame) != ESPNOW_FRAME_SIZE or frame[:2] != ESPNOW_MAGIC:
        raise ValueError("bad espnow frame")
    if not hmac.compare_digest(frame[-ESPNOW_TAG_LEN:], espnow_tag(psk, frame)):
        raise ValueError("bad espnow tag")
    ttl, origin, seq, event, value, ts_us = struct.unpack(
        _ESPNOW_BODY_FMT, frame[2 : ESPNOW_FRAME_SIZE - ESPNOW_TAG_LEN]
    )
    evt = RelayEvent(origin=origin, event=event, value=value, ts_us=ts_us,
                     relayed=True, hops=ESPNOW_TTL - ttl)
    return ttl, evt, seq


# ---------------------------------------------------------------------------
# Dedupe/TTL policy — pure-python reference of espnow_relay.c
# ---------------------------------------------------------------------------

class RelayDeduper:
    """(origin, seq) LRU, newest first — the firmware mirrors this exactly.

    ``check(origin, seq)`` returns True when the pair is fresh and inserts
    it at the head; a repeat refreshes its LRU position and returns False.
    """

    def __init__(self, capacity: int = ESPNOW_DEDUPE_N) -> None:
        self.capacity = int(capacity)
        self._lru: list[tuple[int, int]] = []

    def check(self, origin: int, seq: int) -> bool:
        key = (int(origin), int(seq))
        fresh = key not in self._lru
        if not fresh:
            self._lru.remove(key)
        self._lru.insert(0, key)
        del self._lru[self.capacity:]
        return fresh


def relay_action(ttl: int, fresh: bool, uplink_ok: bool,
                 own_frame: bool = False) -> str:
    """The firmware's relay decision, as one pure function.

    Returns "drop" | "forward" (to host, relayed=1) | "rebroadcast"
    (ttl-1). Mirrors espnow_relay.c::relay_task.
    """
    if own_frame or not fresh:
        return "drop"
    if uplink_ok:
        return "forward"
    return "rebroadcast" if ttl > 1 else "drop"


# ---------------------------------------------------------------------------
# RelayListener — UDP ingest of event frames -> bus topics
# ---------------------------------------------------------------------------

class RelayListener:
    """Listens on the host event port (hall.h: 5569) and publishes:

    - ``door.event``   {origin, event, value, t, relayed, hops} for direct
      door/hall events
    - ``mesh.relayed`` {origin, hops, event, t, value} for anything that
      arrived via the ESP-NOW mesh (relayed=1)
    - ``mesh.event``   for direct non-door events (fall/apnea/health from
      a node's own uplink)

    ``t`` is the origin node's boot-relative clock in seconds (same
    convention as the CSI frames' ts_us).
    """

    def __init__(self, bus: EventBus, port: int = EVENT_PORT,
                 host: str = "0.0.0.0", psk: "bytes | None | object" = _UNSET) -> None:
        self.bus = bus
        # Authenticate the host uplink: default to the provisioned fleet PSK so an
        # un-signed / forged :5569 event is dropped. Pass psk=None explicitly to run
        # legacy/unauthenticated (tests, un-provisioned bring-up).
        self.psk = load_fleet_psk() if psk is _UNSET else psk
        bind_host = unauth_bind_host(host, self.psk)
        if self.psk is None:
            sys.stderr.write("[vigil.relay] WARNING :5569 host uplink is UNAUTHENTICATED "
                             "(no fleet PSK) — bound %s only%s. Provision a fleet PSK + "
                             "re-flash nodes to accept node uplinks off-host.\n"
                             % (bind_host,
                                "" if bind_host == host
                                else " (refusing the LAN-wide bind on %s)" % (host or "*")))
        self.bind_host = bind_host
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((bind_host, port))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.seen: list[RelayEvent] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> "RelayListener":
        self._thread = threading.Thread(target=self._run, name="vigil-relay-rx",
                                        daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        self.sock.close()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                data, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            if not event_dgram_authentic(data, self.psk):
                continue      # forged / unsigned / wrong-key uplink — drop (fail-closed)
            try:
                evt = decode_event_dgram(data)
            except ValueError:
                continue
            self.seen.append(evt)
            payload = {"origin": evt.origin, "event": evt.event_name,
                       "value": evt.value, "t": evt.t,
                       "relayed": evt.relayed, "hops": evt.hops}
            if evt.relayed:
                self.bus.publish("mesh.relayed", payload)
            elif evt.event in (EVT_DOOR_OPEN, EVT_DOOR_CLOSE, EVT_HALL_RAW):
                self.bus.publish("door.event", payload)
            else:
                self.bus.publish("mesh.event", payload)


# ---------------------------------------------------------------------------
# Fleet PSK management (generate / store 0600 / provision via control plane)
# ---------------------------------------------------------------------------

CMD_SET_FLEET_PSK = 0x06   # mirror of control.h


def pack_psk_arg(psk: bytes) -> bytes:
    if len(psk) != PSK_LEN:
        raise ValueError("fleet PSK must be 32 bytes")
    return bytes([PSK_LEN]) + psk


def unpack_psk_arg(arg: bytes) -> bytes:
    if len(arg) < 1 or arg[0] != PSK_LEN or len(arg) < 1 + PSK_LEN:
        raise ValueError("bad fleet PSK arg")
    return arg[1 : 1 + PSK_LEN]


class FleetPsk:
    """32-byte ESP-NOW fleet key, stored hex in a config-adjacent file.

    The file is chmod 0600 — it is a symmetric key for the life-safety
    relay plane; anyone holding it can forge relay events for this fleet.
    """

    def __init__(self, psk: bytes) -> None:
        if len(psk) != PSK_LEN:
            raise ValueError("fleet PSK must be 32 bytes")
        self.psk = psk

    @classmethod
    def generate(cls) -> "FleetPsk":
        return cls(secrets.token_bytes(PSK_LEN))

    @classmethod
    def load(cls, path: str | Path) -> "FleetPsk":
        return cls(bytes.fromhex(Path(path).read_text(encoding="utf-8").strip()))

    def save(self, path: str | Path) -> Path:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(self.psk.hex() + "\n")
        os.chmod(p, 0o600)   # in case the file pre-existed
        return p

    def provision(self, addr: tuple[str, int], timeout: float = 2.0) -> dict:
        """Push the PSK to one node over the vigilctl control plane
        (cmd 0x06; layout mirrored in control.h). Returns the node's JSON
        reply. Provision on a trusted LAN only — the key travels in the
        clear, same trust level as BLE pairing."""
        from ..cli.vigilctl import send_control  # local import: keeps relay stdlib-light

        _node_id, payload = send_control(addr, CMD_SET_FLEET_PSK,
                                         pack_psk_arg(self.psk), timeout=timeout)
        return payload
