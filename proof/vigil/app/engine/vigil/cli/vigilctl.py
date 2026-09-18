"""vigilctl — Vigil fleet management CLI (Track A3).

Operating envelope: runs on the host Mac, talks to ESP32 nodes over three
planes — BLE GATT for pairing (optional dep ``bleak``; a ``--fake-fleet``
JSON transport substitutes for tests/dev), a tiny UDP control protocol on
node port 5567 for channel/survey/OTA/status (byte-exact mirror of
``firmware/main/control.h``), and HTTP for the ingest daemon's Prometheus
stats. State lives in a JSON fleet manifest (default ``~/.vigil/fleet.json``)
plus ``vigil.config.VigilConfig`` for room/zone assignment. Everything is
stdlib + the vigil package; no sleeps or network beyond what a subcommand
explicitly does.

Control wire format (host side of firmware/main/control.h):

    request   0xA5 0x5C | cmd:u8 | arg bytes (little-endian)
    response  0xA5 0x5D | cmd:u8 | node_id:u8 | JSON utf-8

    cmd 0x01 SET_CHANNEL  arg = channel:u8
    cmd 0x02 SURVEY       arg = ()          reply = survey JSON (A4)
    cmd 0x03 OTA          arg = url_len:u16le | url bytes
    cmd 0x04 STATUS       arg = ()
    cmd 0x05 OTA_STATUS   arg = ()          reply = {"state","progress",...}
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from vigil.config import NodeConfig, VigilConfig

try:
    import vigil_paths
except ImportError:  # engine/ not on sys.path (vigil pkg imported standalone)
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    import vigil_paths

# ---------------------------------------------------------------------------
# Control-message codec (mirror of firmware/main/control.h)
# ---------------------------------------------------------------------------

CTRL_MAGIC = b"\xa5\x5c"
RESP_MAGIC = b"\xa5\x5d"

CMD_SET_CHANNEL = 0x01
CMD_SURVEY = 0x02
CMD_OTA = 0x03
CMD_STATUS = 0x04
CMD_OTA_STATUS = 0x05

CTRL_PORT = 5567

# BLE provisioning GATT map (mirror of firmware/main/pairing.h)
GATT_SERVICE_UUID = "56494731-a55a-4c00-8000-763167696c00"
GATT_CHAR = {
    "ssid": "56494731-a55a-4c00-8000-763167696c01",
    "psk": "56494731-a55a-4c00-8000-763167696c02",
    "channel": "56494731-a55a-4c00-8000-763167696c03",
    "role": "56494731-a55a-4c00-8000-763167696c04",
    "host_ip": "56494731-a55a-4c00-8000-763167696c05",
    "node_id": "56494731-a55a-4c00-8000-763167696c06",
    "room": "56494731-a55a-4c00-8000-763167696c07",
    "commit": "56494731-a55a-4c00-8000-763167696c08",
}


def pack_control(cmd: int, arg: bytes = b"") -> bytes:
    if not 0 <= cmd <= 0xFF:
        raise ValueError(f"bad cmd {cmd}")
    return CTRL_MAGIC + bytes([cmd]) + arg


def unpack_control(datagram: bytes) -> tuple[int, bytes]:
    if len(datagram) < 3 or datagram[:2] != CTRL_MAGIC:
        raise ValueError("bad control magic")
    return datagram[2], datagram[3:]


def pack_channel_arg(channel: int) -> bytes:
    if not 1 <= channel <= 13:
        raise ValueError(f"channel must be 1..13, got {channel}")
    return bytes([channel])


def pack_ota_arg(url: str) -> bytes:
    raw = url.encode("utf-8")
    if not 0 < len(raw) < 256:
        raise ValueError("url must be 1..255 bytes")
    return struct.pack("<H", len(raw)) + raw


def unpack_ota_arg(arg: bytes) -> str:
    (n,) = struct.unpack_from("<H", arg, 0)
    if len(arg) < 2 + n:
        raise ValueError("short OTA arg")
    return arg[2 : 2 + n].decode("utf-8")


def pack_response(cmd: int, node_id: int, payload: dict) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return RESP_MAGIC + bytes([cmd, node_id & 0xFF]) + body


def unpack_response(datagram: bytes) -> tuple[int, int, dict]:
    if len(datagram) < 4 or datagram[:2] != RESP_MAGIC:
        raise ValueError("bad response magic")
    return datagram[2], datagram[3], json.loads(datagram[4:].decode("utf-8"))


def send_control(
    addr: tuple[str, int],
    cmd: int,
    arg: bytes = b"",
    timeout: float = 2.0,
) -> tuple[int, dict]:
    """Send one control request, wait for the matching response.

    Returns (node_id, payload). Raises TimeoutError if the node stays quiet.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(pack_control(cmd, arg), addr)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response from {addr[0]}:{addr[1]} (cmd 0x{cmd:02x})")
            sock.settimeout(remaining)
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                raise TimeoutError(
                    f"no response from {addr[0]}:{addr[1]} (cmd 0x{cmd:02x})"
                ) from None
            try:
                rcmd, node_id, payload = unpack_response(data)
            except ValueError:
                continue  # stray datagram; keep waiting
            if rcmd == cmd:
                return node_id, payload


# ---------------------------------------------------------------------------
# Fleet manifest
# ---------------------------------------------------------------------------

def default_manifest() -> Path:
    """The fleet manifest's override-aware default, resolved at CALL time.

    `Path.home()` honours $HOME but NOT VIGIL_HOME, so a constant here let a QA run
    read/write the owner's real fleet.json. See vigil_paths.
    """
    return Path(vigil_paths.state_path("fleet.json"))


def default_config() -> Path:
    """The config file's override-aware default, resolved at CALL time."""
    return Path(vigil_paths.state_path("config.json"))


def __getattr__(name):
    # Back-compat for `from vigil.cli.vigilctl import DEFAULT_MANIFEST`, resolved per access.
    if name == "DEFAULT_MANIFEST":
        return default_manifest()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


MANIFEST_FIELDS = (
    "node_id", "name", "mac", "room", "zone", "role", "channel",
    "last_seen", "fw_version", "ip", "ctrl_port",
)


class FleetManifest:
    """JSON list of node records at a configurable path.

    Record schema (CONTRACTS-adjacent, Track A owned): {node_id, name, mac,
    room, zone, role, channel, last_seen, fw_version} plus reachability
    extras {ip, ctrl_port} used by the UDP control plane.
    """

    def __init__(self, path: str | Path | None = None) -> None:
        # path=None resolves at CALL time; a DEFAULT_MANIFEST default arg would bind at def
        # time and pin the owner's real fleet.json for the life of the process.
        self.path = Path(path) if path is not None else default_manifest()
        self.nodes: list[dict] = []
        if self.path.exists():
            self.nodes = json.loads(self.path.read_text(encoding="utf-8"))

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(self.nodes, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def get(self, node_id: int) -> dict | None:
        for n in self.nodes:
            if n.get("node_id") == node_id:
                return n
        return None

    def upsert(self, node_id: int, **fields) -> dict:
        unknown = set(fields) - set(MANIFEST_FIELDS)
        if unknown:
            raise ValueError(f"unknown manifest fields: {sorted(unknown)}")
        rec = self.get(node_id)
        if rec is None:
            rec = {
                "node_id": node_id, "name": "", "mac": "", "room": "",
                "zone": "", "role": "", "channel": 0, "last_seen": 0.0,
                "fw_version": "", "ip": "", "ctrl_port": CTRL_PORT,
            }
            self.nodes.append(rec)
            self.nodes.sort(key=lambda r: r["node_id"])
        rec.update(fields)
        return rec

    def addr(self, node_id: int) -> tuple[str, int]:
        rec = self.get(node_id)
        if rec is None or not rec.get("ip"):
            raise KeyError(f"node {node_id} has no ip in the manifest")
        return rec["ip"], int(rec.get("ctrl_port") or CTRL_PORT)

    def reachable(self) -> list[dict]:
        return [n for n in self.nodes if n.get("ip")]


# ---------------------------------------------------------------------------
# Pairing transports: fake fleet (tests/dev) and bleak (real hardware)
# ---------------------------------------------------------------------------

class FakeFleet:
    """File-backed stand-in for the BLE plane.

    JSON shape: {"devices": [{"name","mac", ...}], "gatt": {name: {...}}}.
    ``pair`` records the staged characteristic writes plus committed=True —
    tests assert on that record instead of real GATT traffic.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        self.devices: list[dict] = raw.get("devices", [])
        self.gatt: dict[str, dict] = raw.get("gatt", {})

    def save(self) -> None:
        self.path.write_text(
            json.dumps({"devices": self.devices, "gatt": self.gatt}, indent=2) + "\n",
            encoding="utf-8",
        )

    def scan(self) -> list[dict]:
        return list(self.devices)

    def find(self, name: str) -> dict:
        for d in self.devices:
            if d.get("name") == name:
                return d
        raise KeyError(f"no advertising device named {name!r} in fake fleet")

    def write_gatt(self, name: str, values: dict) -> None:
        self.find(name)  # raises if unknown
        rec = self.gatt.setdefault(name, {})
        rec.update(values)
        rec["committed"] = True
        self.save()


class Fleet:
    """Programmatic fleet facade — the interface the setup wizard (E2) binds
    to when no fleet is injected: ``discover() -> list[dict]`` and
    ``pair(name, **params) -> dict``.

    Backed by BLE (bleak) in production or a ``FakeFleet`` JSON file for
    dev/tests; pairing writes through to the fleet manifest exactly like
    ``vigilctl pair``.
    """

    def __init__(self, manifest_path: str | Path | None = None,
                 fake_fleet: str | Path | None = None,
                 ble_timeout: float = 8.0) -> None:
        self.manifest = (FleetManifest(manifest_path) if manifest_path
                         else FleetManifest())
        self._fake = FakeFleet(fake_fleet) if fake_fleet else None
        self.ble_timeout = ble_timeout

    def discover(self) -> list[dict]:
        if self._fake is not None:
            return self._fake.scan()
        return _ble_scan(self.ble_timeout)

    def pair(self, name: str, **params) -> dict:
        values = {
            "ssid": params.get("ssid", ""), "psk": params.get("psk", ""),
            "channel": int(params.get("channel", 6)),
            "role": params.get("role", "receiver"),
            "host_ip": params.get("host", params.get("host_ip", "")),
            "node_id": int(params["node_id"]), "room": params.get("room", ""),
        }
        if self._fake is not None:
            device = self._fake.find(name)
            self._fake.write_gatt(name, values)
            mac = device.get("mac", "")
        else:
            mac = _ble_pair(name, values, self.ble_timeout)
        self.manifest.upsert(
            values["node_id"], name=name, mac=mac, room=values["room"],
            role=values["role"], channel=values["channel"],
            last_seen=time.time(),
        )
        self.manifest.save()
        return {"node_id": values["node_id"], "name": name, "mac": mac,
                "room": values["room"], "role": values["role"]}


_BLEAK_HINT = (
    "bleak is not installed — BLE scanning/pairing is unavailable.\n"
    "Fix: pip install bleak   (or pass --fake-fleet <json> for dev/tests)"
)


def _require_bleak():
    try:
        import bleak  # noqa: PLC0415 — optional dep, lazy by contract
    except ImportError:
        print(_BLEAK_HINT, file=sys.stderr)
        raise SystemExit(2) from None
    return bleak


def _ble_scan(timeout: float) -> list[dict]:
    bleak = _require_bleak()
    import asyncio

    async def scan():
        devices = await bleak.BleakScanner.discover(timeout=timeout)
        return [
            {"name": d.name, "mac": d.address}
            for d in devices
            if d.name and d.name.startswith("vigil-")
        ]

    return asyncio.run(scan())


def _ble_pair(name: str, values: dict, timeout: float) -> str:
    """Write the provisioning characteristics over GATT. Returns the MAC."""
    bleak = _require_bleak()
    import asyncio

    async def pair():
        device = await bleak.BleakScanner.find_device_by_name(name, timeout=timeout)
        if device is None:
            raise SystemExit(f"device {name!r} not found (is it in pairing mode?)")
        client = bleak.BleakClient(device)
        connected = False
        committed = False
        error = None
        try:
            await client.connect()
            connected = True
            for key in ("ssid", "psk", "channel", "role", "host_ip", "node_id", "room"):
                val = values[key]
                data = bytes([val]) if isinstance(val, int) else str(val).encode("utf-8")
                await client.write_gatt_char(GATT_CHAR[key], data, response=True)
            await client.write_gatt_char(GATT_CHAR["commit"], b"\x01", response=True)
            committed = True
        except Exception as exc:  # noqa: BLE001 - preserve real write/connect failure below
            error = exc
        finally:
            if connected:
                try:
                    await client.disconnect()
                except Exception as exc:  # noqa: BLE001 - Bleak raises here after some successful commits
                    if not committed and error is None:
                        error = exc
        if error is not None:
            raise error
        return device.address

    return asyncio.run(pair())


# ---------------------------------------------------------------------------
# Survey scoring
# ---------------------------------------------------------------------------

def pick_cleanest_channel(node_results: list[dict]) -> int:
    """Pick the cleanest 2.4 GHz channel from per-node survey payloads.

    ``node_results`` are firmware survey JSON payloads:
    {"node_id": n, "survey": [{"ch", "busy", "pkts", "rssi", "noise", "aps"}]}.
    Score per channel = mean busy fraction across the nodes that measured
    it; deterministic tiebreak on (busy, mean aps, channel number).
    """
    per_ch: dict[int, list[dict]] = {}
    for res in node_results:
        for row in res.get("survey", []):
            per_ch.setdefault(int(row["ch"]), []).append(row)
    if not per_ch:
        raise ValueError("no survey rows to score")

    def score(ch: int) -> tuple[float, float, int]:
        rows = per_ch[ch]
        busy = sum(float(r.get("busy", 0.0)) for r in rows) / len(rows)
        aps = sum(float(r.get("aps", 0)) for r in rows) / len(rows)
        return (round(busy, 6), round(aps, 6), ch)

    return min(per_ch, key=score)


# ---------------------------------------------------------------------------
# Prometheus stats parsing (ingest daemon `stats_text()`)
# ---------------------------------------------------------------------------

def parse_prometheus(text: str) -> dict[int, dict[str, float]]:
    """Parse Prometheus exposition text into {node_id: {metric: value}}.

    Accepts any metric family carrying a node_id label, e.g.
    ``vigil_node_rate_hz{node_id="3"} 99.7``. Lines without a node_id
    label and comments are ignored.
    """
    out: dict[int, dict[str, float]] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            head, value_s = line.rsplit(None, 1)
            value = float(value_s)
        except ValueError:
            continue
        if "{" not in head or "node_id=" not in head:
            continue
        metric = head.split("{", 1)[0]
        labels = head.split("{", 1)[1].rstrip("}")
        node_id = None
        for item in labels.split(","):
            k, _, v = item.partition("=")
            if k.strip() == "node_id":
                try:
                    node_id = int(v.strip().strip('"'))
                except ValueError:
                    node_id = None
        if node_id is None:
            continue
        out.setdefault(node_id, {})[metric] = value
    return out


# ---------------------------------------------------------------------------
# OTA host side
# ---------------------------------------------------------------------------

def _local_ip_towards(host: str, port: int) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((host, port))
        return s.getsockname()[0]


def serve_firmware(bin_path: Path, bind_ip: str = "") -> tuple[http.server.ThreadingHTTPServer, str]:
    """Serve ``bin_path``'s directory over HTTP on a random port.

    Returns (server, path-relative URL suffix). Caller composes the full
    URL with the IP the *node* can reach and must ``shutdown()`` the server.
    """
    bin_path = Path(bin_path).resolve()
    if not bin_path.is_file():
        raise FileNotFoundError(bin_path)
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=str(bin_path.parent)
    )
    handler.log_message = lambda *a, **k: None  # type: ignore[attr-defined]
    server = http.server.ThreadingHTTPServer((bind_ip, 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, bin_path.name


def ota_node(
    addr: tuple[str, int],
    url: str,
    timeout: float = 120.0,
    poll_interval: float = 1.0,
) -> dict:
    """Drive one node through an OTA: start, poll progress, return final status.

    Returns the node's last OTA_STATUS payload; ``{"state": "done"}`` means
    the node accepted the image and is rebooting into it.
    """
    node_id, resp = send_control(addr, CMD_OTA, pack_ota_arg(url), timeout=max(poll_interval * 4, 2.0))
    if not resp.get("ok"):
        return {"state": "error", "progress": 0, "detail": resp.get("detail", "rejected"), "node_id": node_id}

    deadline = time.monotonic() + timeout
    last: dict = {"state": "downloading", "progress": 0}
    while time.monotonic() < deadline:
        try:
            node_id, status = send_control(
                addr, CMD_OTA_STATUS, timeout=max(poll_interval * 4, 0.2)
            )
        except TimeoutError:
            # node may be mid-reboot after "done"
            if last.get("state") == "done":
                break
            time.sleep(min(poll_interval, 0.2))
            continue
        status["node_id"] = node_id
        last = status
        if status.get("state") in ("done", "error"):
            break
        time.sleep(min(poll_interval, 0.2))
    return last


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def _targets(manifest: FleetManifest, args) -> list[tuple[int, tuple[str, int]]]:
    """Resolve (node_id, addr) targets from --node/--addr or the manifest."""
    if getattr(args, "addr", None):
        host, _, port = args.addr.partition(":")
        addr = (host, int(port) if port else CTRL_PORT)
        return [(getattr(args, "node", None) or -1, addr)]
    if getattr(args, "node", None) is not None:
        return [(args.node, manifest.addr(args.node))]
    return [(n["node_id"], (n["ip"], int(n.get("ctrl_port") or CTRL_PORT)))
            for n in manifest.reachable()]


def cmd_discover(args) -> int:
    if args.fake_fleet:
        devices = FakeFleet(args.fake_fleet).scan()
    else:
        devices = _ble_scan(args.timeout)
    for d in devices:
        print(f"{d['name']}  {d.get('mac', '?')}")
    if not devices:
        print("no vigil-* devices found (are nodes in pairing mode?)", file=sys.stderr)
    return 0


def cmd_pair(args) -> int:
    values = {
        "ssid": args.ssid, "psk": args.psk, "channel": args.channel,
        "role": args.role, "host_ip": args.host, "node_id": args.node_id,
        "room": args.room,
    }
    if args.fake_fleet:
        fleet = FakeFleet(args.fake_fleet)
        device = fleet.find(args.name)
        fleet.write_gatt(args.name, values)
        mac = device.get("mac", "")
    else:
        mac = _ble_pair(args.name, values, args.timeout)

    manifest = FleetManifest(args.manifest)
    manifest.upsert(
        args.node_id, name=args.name, mac=mac, room=args.room,
        role=args.role, channel=args.channel, last_seen=time.time(),
    )
    manifest.save()
    print(f"paired {args.name} as node {args.node_id} ({args.role}, {args.room})")
    return 0


def cmd_assign(args) -> int:
    manifest = FleetManifest(args.manifest)
    rec = manifest.upsert(args.node_id, room=args.room, zone=args.zone or "")
    manifest.save()

    cfg_path = Path(args.config)
    cfg = VigilConfig.load(cfg_path) if cfg_path.exists() else VigilConfig()
    try:
        node = cfg.node(args.node_id)
    except KeyError:
        node = NodeConfig(node_id=args.node_id)
        cfg.nodes.append(node)
    node.room = args.room
    node.zone = args.zone or ""
    node.mac = rec.get("mac", "") or node.mac
    for ids in cfg.rooms.values():
        if args.node_id in ids:
            ids.remove(args.node_id)
    cfg.rooms.setdefault(args.room, [])
    if args.node_id not in cfg.rooms[args.room]:
        cfg.rooms[args.room].append(args.node_id)
    cfg.rooms = {room: ids for room, ids in cfg.rooms.items() if ids}
    if args.zone == "bed":
        cfg.vitals_zone[args.room] = args.node_id
    cfg.save(cfg_path)
    print(f"node {args.node_id} -> room={args.room} zone={args.zone or '-'}")
    return 0


def cmd_channel(args) -> int:
    manifest = FleetManifest(args.manifest)
    rc = 0
    for node_id, addr in _targets(manifest, args):
        try:
            resp_node, payload = send_control(
                addr, CMD_SET_CHANNEL, pack_channel_arg(args.n), timeout=args.timeout
            )
        except (TimeoutError, OSError) as exc:
            print(f"node {node_id}: FAILED ({exc})", file=sys.stderr)
            rc = 1
            continue
        ok = payload.get("ok", False)
        print(f"node {resp_node}: channel -> {args.n} "
              f"({'ok' if ok else payload.get('detail', 'error')}"
              f"{', rebooting' if payload.get('reboot') else ''})")
        if ok:
            manifest.upsert(resp_node, channel=args.n, last_seen=time.time())
    manifest.save()
    return rc


def cmd_ota(args) -> int:
    manifest = FleetManifest(args.manifest)
    targets = _targets(manifest, args)
    if not targets:
        print("no reachable nodes in the manifest", file=sys.stderr)
        return 1

    server, name = serve_firmware(Path(args.firmware))
    port = server.server_address[1]
    rc = 0
    try:
        for node_id, addr in targets:
            host_ip = args.serve_ip or _local_ip_towards(addr[0], addr[1])
            url = f"http://{host_ip}:{port}/{name}"
            print(f"node {node_id}: OTA {url}")
            status = ota_node(addr, url, timeout=args.timeout,
                              poll_interval=args.poll_interval)
            state = status.get("state")
            print(f"node {node_id}: {state} ({status.get('progress', 0)}%)"
                  + (f" — {status['detail']}" if status.get("detail") else ""))
            if state == "done":
                manifest.upsert(
                    status.get("node_id", node_id) if node_id == -1 else node_id,
                    fw_version=status.get("fw", ""), last_seen=time.time(),
                )
            else:
                rc = 1
    finally:
        server.shutdown()
        server.server_close()
    manifest.save()
    return rc


def cmd_health(args) -> int:
    manifest = FleetManifest(args.manifest)
    stats: dict[int, dict[str, float]] = {}
    source = "ingest"
    try:
        with urllib.request.urlopen(args.stats_url, timeout=args.timeout) as resp:
            stats = parse_prometheus(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        source = f"manifest (ingest stats unavailable: {exc})"

    print(f"# source: {source}")
    node_ids = sorted(set(stats) | {n["node_id"] for n in manifest.nodes})
    if not node_ids:
        print("no nodes known", file=sys.stderr)
        return 1
    for node_id in node_ids:
        rec = manifest.get(node_id) or {}
        m = stats.get(node_id, {})
        rate = next((v for k, v in m.items() if "rate" in k), None)
        rssi = next((v for k, v in m.items() if "rssi" in k), None)
        loss = next((v for k, v in m.items() if "loss" in k), None)
        print(
            f"node {node_id:3d}  {rec.get('name', '') or '-':12s} "
            f"room={rec.get('room', '') or '-':10s} "
            f"rate={rate if rate is not None else '?':>6}Hz "
            f"rssi={rssi if rssi is not None else '?':>5}dBm "
            f"loss={loss if loss is not None else '?':>5}% "
            f"fw={rec.get('fw_version', '') or '?'}"
        )
    return 0


def cmd_survey(args) -> int:
    manifest = FleetManifest(args.manifest)
    targets = _targets(manifest, args)
    if not targets:
        print("no reachable nodes in the manifest", file=sys.stderr)
        return 1

    results: list[dict] = []
    for node_id, addr in targets:
        try:
            resp_node, payload = send_control(addr, CMD_SURVEY, timeout=args.timeout)
        except (TimeoutError, OSError) as exc:
            print(f"node {node_id}: survey FAILED ({exc})", file=sys.stderr)
            continue
        print(f"node {resp_node}: {len(payload.get('survey', []))} channels surveyed")
        results.append(payload)
    if not results:
        print("no survey results collected", file=sys.stderr)
        return 1

    best = pick_cleanest_channel(results)
    print(f"cleanest channel: {best}")
    if args.dry_run:
        return 0

    # Push fleet-wide via the channel command machinery. Surveyed receivers
    # reboot back into their role, so give them a beat only in real life —
    # the control send itself retries nothing and returns fast.
    rc = 0
    for node_id, addr in targets:
        try:
            resp_node, payload = send_control(
                addr, CMD_SET_CHANNEL, pack_channel_arg(best), timeout=args.timeout
            )
        except (TimeoutError, OSError) as exc:
            print(f"node {node_id}: channel push FAILED ({exc})", file=sys.stderr)
            rc = 1
            continue
        if payload.get("ok"):
            manifest.upsert(resp_node, channel=best, last_seen=time.time())
            print(f"node {resp_node}: channel -> {best}")
        else:
            print(f"node {resp_node}: rejected ({payload.get('detail')})", file=sys.stderr)
            rc = 1
    manifest.save()
    return rc


# ---------------------------------------------------------------------------
# argparse wiring
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="vigilctl", description="Vigil fleet management (Track A3)"
    )
    # help shows the RESOLVED default: under VIGIL_HOME a hardcoded "~/.vigil/fleet.json"
    # would misreport where the CLI is actually reading/writing.
    p.add_argument("--manifest", default=str(default_manifest()),
                   help=f"fleet manifest path (default: {default_manifest()})")
    sub = p.add_subparsers(dest="command", required=True)

    d = sub.add_parser("discover", help="BLE-scan for vigil-* nodes in pairing mode")
    d.add_argument("--timeout", type=float, default=5.0)
    d.add_argument("--fake-fleet", help="JSON fake BLE plane (tests/dev)")
    d.set_defaults(fn=cmd_discover)

    pr = sub.add_parser("pair", help="provision a node over BLE GATT")
    pr.add_argument("name", help="advertised name, e.g. vigil-AB12")
    pr.add_argument("--ssid", required=True)
    pr.add_argument("--psk", required=True)
    pr.add_argument("--channel", type=int, required=True, choices=range(1, 14),
                    metavar="1..13")
    pr.add_argument("--role", required=True, choices=("beacon", "receiver", "survey"))
    pr.add_argument("--host", required=True, help="ingest host IP")
    pr.add_argument("--node-id", type=int, required=True)
    pr.add_argument("--room", required=True)
    pr.add_argument("--timeout", type=float, default=15.0)
    pr.add_argument("--fake-fleet", help="JSON fake BLE plane (tests/dev)")
    pr.set_defaults(fn=cmd_pair)

    a = sub.add_parser("assign", help="assign a node to a room/zone")
    a.add_argument("node_id", type=int)
    a.add_argument("--room", required=True)
    a.add_argument("--zone", default="")
    a.add_argument("--config", default=str(default_config()))
    a.set_defaults(fn=cmd_assign)

    c = sub.add_parser("channel", help="push a Wi-Fi channel to node(s)")
    c.add_argument("n", type=int, choices=range(1, 14), metavar="1..13")
    c.add_argument("--node", type=int, help="single node_id (default: all reachable)")
    c.add_argument("--addr", help="host[:port] override, bypasses the manifest")
    c.add_argument("--timeout", type=float, default=2.0)
    c.set_defaults(fn=cmd_channel)

    o = sub.add_parser("ota", help="OTA-update node(s) from a local .bin")
    o.add_argument("firmware", help="path to firmware .bin")
    o.add_argument("--node", type=int, help="single node_id (default: all reachable)")
    o.add_argument("--addr", help="host[:port] override, bypasses the manifest")
    o.add_argument("--serve-ip", help="IP to advertise in the OTA URL "
                                      "(default: auto-detect per node)")
    o.add_argument("--timeout", type=float, default=180.0)
    o.add_argument("--poll-interval", type=float, default=1.0)
    o.set_defaults(fn=cmd_ota)

    h = sub.add_parser("health", help="per-node rate/RSSI/loss")
    h.add_argument("--stats-url", default="http://127.0.0.1:5568/metrics",
                   help="ingest daemon Prometheus endpoint")
    h.add_argument("--timeout", type=float, default=2.0)
    h.set_defaults(fn=cmd_health)

    s = sub.add_parser("survey", help="fleet channel survey; pick + push cleanest")
    s.add_argument("--node", type=int, help="survey a single node")
    s.add_argument("--addr", help="host[:port] override, bypasses the manifest")
    s.add_argument("--timeout", type=float, default=40.0,
                   help="per-node survey wait (full sweep is ~25 s)")
    s.add_argument("--dry-run", action="store_true", help="pick but do not push")
    s.set_defaults(fn=cmd_survey)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
