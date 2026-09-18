"""Setup wizard backend — resumable first-run state machine (Track E2).

Operating envelope: pure logic, no BLE/serial/socket IO here — every side
effect goes through an injected interface so any UI (CLI, web, tests) can
drive it and tests can run on fakes today:

- ``fleet``:   ``discover() -> list[dict]``, ``pair(name, **params) -> dict``
               (node_id at minimum). When None, the vigil.cli.vigilctl
               fleet API is imported lazily at the pairing step.
- ``ingest``:  ``stats() -> dict`` with per-node ``rate_hz`` / ``rssi``.
- ``surveyor``: ``survey() -> dict[channel, score]`` — higher = cleaner air.
- ``capture``: ``capture(node_id, seconds) -> array of motion energy`` for
               placement validation; alternatively the UI passes the
               captured series in ``next({"energy": {node_id: [...]}})``.

Steps: welcome -> pairing -> signal_preview -> room_assignment ->
placement_validation -> channel_survey -> vitals_zone -> done. Each step
validates before advancing; ``skip(step)`` is allowed where safe. State
round-trips through ``serialize()`` / ``resume()`` so a UI can stop and
continue later.

Acceptance target: a non-developer completes the full flow in <30 minutes
on real hardware (to be measured on hardware later — this module only has
to never be the bottleneck and always say what to do next).
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

import numpy as np

from .config import AlertsConfig, NodeConfig, Thresholds, VigilConfig

STEPS = [
    "welcome",
    "pairing",
    "signal_preview",
    "room_assignment",
    "placement_validation",
    "channel_survey",
    "vitals_zone",
    "done",
]

# Steps that may be skipped without leaving the config unusable. Pairing and
# room assignment are structural; skipping vitals_zone just disables vitals.
SKIPPABLE = {"signal_preview", "placement_validation", "channel_survey",
             "vitals_zone"}

# Placement validation thresholds
MIN_PEAK_QUIET_RATIO = 3.0
RSSI_SANE_MIN = -85
RSSI_SANE_MAX = -20
MIN_RATE_HZ = 50.0  # half of nominal 100 Hz


@dataclass
class StepResult:
    step: str          # the step that was just processed
    ok: bool           # True => wizard advanced (or is done)
    prompts: list[str] = field(default_factory=list)
    data: dict = field(default_factory=dict)


class SetupWizard:
    """Resumable setup state machine. Drive with .next(input dict)."""

    def __init__(self, config_path: str | Path, fleet: Any = None,
                 ingest: Any = None, surveyor: Any = None,
                 capture: Callable[[int, float], Any] | None = None,
                 config: VigilConfig | None = None) -> None:
        self.config_path = Path(config_path)
        self.config = config or VigilConfig()
        self._fleet = fleet
        self._ingest = ingest
        self._surveyor = surveyor
        self._capture = capture
        self._state = STEPS[0]
        self._skipped: list[str] = []
        self._notes: dict[str, Any] = {}  # JSON-safe per-step memory (rssi…)

    # -- public API ----------------------------------------------------------

    @property
    def state(self) -> str:
        return self._state

    def next(self, input: dict | None = None) -> StepResult:  # noqa: A002
        inp = dict(input or {})
        step = self._state
        ok, prompts, data = getattr(self, f"_step_{step}")(inp)
        if ok and step != "done":
            self._advance()
            prompts = list(prompts) + self._intro(self._state)
        return StepResult(step=step, ok=ok, prompts=list(prompts), data=data)

    def skip(self, step: str) -> StepResult:
        if step != self._state:
            raise ValueError(f"cannot skip {step!r}: current step is "
                             f"{self._state!r}")
        if step not in SKIPPABLE:
            raise ValueError(f"step {step!r} is required and cannot be "
                             f"skipped")
        self._skipped.append(step)
        self._advance()
        return StepResult(step=step, ok=True,
                          prompts=[f"skipped {step}"] + self._intro(self._state),
                          data={"skipped": True})

    def serialize(self, path: str | Path | None = None) -> Path:
        """Persist wizard state (including the config draft) as JSON."""
        p = Path(path) if path else self.config_path.with_suffix(
            ".wizard.json")
        p.parent.mkdir(parents=True, exist_ok=True)
        blob = {
            "version": 1,
            "state": self._state,
            "skipped": self._skipped,
            "notes": self._notes,
            "config_path": str(self.config_path),
            "config": asdict(self.config),
        }
        p.write_text(json.dumps(blob, indent=2), encoding="utf-8")
        return p

    @classmethod
    def resume(cls, path: str | Path, fleet: Any = None, ingest: Any = None,
               surveyor: Any = None,
               capture: Callable[[int, float], Any] | None = None
               ) -> "SetupWizard":
        blob = json.loads(Path(path).read_text(encoding="utf-8"))
        wiz = cls(blob["config_path"], fleet=fleet, ingest=ingest,
                  surveyor=surveyor, capture=capture,
                  config=_config_from_dict(blob.get("config", {})))
        state = blob.get("state", STEPS[0])
        if state not in STEPS:
            raise ValueError(f"corrupt wizard state {state!r}")
        wiz._state = state
        wiz._skipped = list(blob.get("skipped", []))
        wiz._notes = dict(blob.get("notes", {}))
        return wiz

    # -- machinery -----------------------------------------------------------

    def _advance(self) -> None:
        self._state = STEPS[STEPS.index(self._state) + 1]
        if self._state == "done":
            self._finish()

    def _finish(self) -> None:
        self.config.save(self.config_path)
        self._notes["summary"] = self._summary()

    def _summary(self) -> dict:
        return {
            "config_path": str(self.config_path),
            "nodes": len(self.config.nodes),
            "rooms": {r: list(ids) for r, ids in self.config.rooms.items()},
            "channel": self.config.channel,
            "vitals_zone": dict(self.config.vitals_zone),
            "skipped": list(self._skipped),
        }

    @staticmethod
    def _intro(step: str) -> list[str]:
        intros = {
            "pairing": ["Plug in each Vigil node, then continue to discover "
                        "and pair them."],
            "signal_preview": ["Checking each node's frame rate and signal "
                               "strength…"],
            "room_assignment": ["Assign each node to a room, e.g. "
                                '{"rooms": {"living": [1, 2]}}.'],
            "placement_validation": ["Walk through each room now — we'll "
                                     "capture 10 s of motion per node."],
            "channel_survey": ["Scanning Wi-Fi channels for the cleanest "
                               "air…"],
            "vitals_zone": ["Pick the node nearest each bed, e.g. "
                            '{"vitals_zone": {"bedroom": 3}}.'],
            "done": ["Setup complete — config saved."],
        }
        return intros.get(step, [])

    # -- injected-interface access -------------------------------------------

    def _require_fleet(self) -> Any:
        if self._fleet is not None:
            return self._fleet
        try:
            from .cli import vigilctl  # lazy — Track owner: CLI
        except ImportError as e:
            raise RuntimeError(
                "no fleet interface injected and vigil.cli.vigilctl is not "
                f"available yet ({e}); pass fleet= to SetupWizard") from e
        for attr in ("fleet", "Fleet", "FleetManager"):
            obj = getattr(vigilctl, attr, None)
            if obj is not None:
                fleet = obj() if isinstance(obj, type) or callable(obj) else obj
                self._fleet = fleet
                return fleet
        raise RuntimeError("vigil.cli.vigilctl exposes no fleet API "
                           "(expected fleet/Fleet); pass fleet= explicitly")

    # -- steps ----------------------------------------------------------------
    # Each returns (ok, prompts, data). ok=True advances the machine.

    def _step_welcome(self, inp: dict) -> tuple[bool, list[str], dict]:
        return True, ["Welcome to Vigil setup."], {
            "config_path": str(self.config_path), "steps": STEPS}

    def _step_pairing(self, inp: dict) -> tuple[bool, list[str], dict]:
        fleet = self._require_fleet()
        if inp.get("action") == "discover":
            found = list(fleet.discover())
            return False, ["Nodes in range — send an empty input (or "
                           "{'select': [names]}) to pair."], {
                "discovered": found}
        discovered = list(fleet.discover())
        select = inp.get("select")
        if select:
            discovered = [d for d in discovered if d.get("name") in select
                          or d.get("mac") in select]
        paired = []
        known = {n.node_id for n in self.config.nodes}
        for i, d in enumerate(discovered):
            name = d.get("name") or d.get("mac") or f"node{i + 1}"
            params = {k: v for k, v in d.items() if k != "name"}
            info = fleet.pair(name, **params)
            info = info if isinstance(info, dict) else {"node_id": int(info)}
            nid = int(info["node_id"])
            if nid not in known:
                self.config.nodes.append(NodeConfig(
                    node_id=nid,
                    mac=str(info.get("mac", d.get("mac", ""))),
                    transport=str(info.get("transport", "udp")),
                ))
                known.add(nid)
            paired.append({"name": name, "node_id": nid})
        if not self.config.nodes:
            return False, ["No nodes paired yet — plug nodes in and retry, "
                           "or check power/BLE."], {"paired": []}
        return True, [f"Paired {len(paired)} node(s)."], {"paired": paired}

    def _step_signal_preview(self, inp: dict) -> tuple[bool, list[str], dict]:
        stats = inp.get("stats")
        if stats is None and self._ingest is not None:
            stats = self._ingest.stats()
        if stats is None:
            return False, ["No ingest stats available — inject ingest= or "
                           "pass {'stats': ...}; skip(step) if you must."], {}
        per_node = stats.get("nodes", stats)
        results: dict[int, dict] = {}
        prompts: list[str] = []
        all_ok = True
        rssi_notes = self._notes.setdefault("rssi", {})
        for n in self.config.nodes:
            st = per_node.get(n.node_id) or per_node.get(str(n.node_id)) or {}
            rate = float(st.get("rate_hz", 0.0))
            rssi = int(st.get("rssi", -127))
            rssi_notes[str(n.node_id)] = rssi
            node_ok = rate >= MIN_RATE_HZ and rssi > RSSI_SANE_MIN
            results[n.node_id] = {"rate_hz": rate, "rssi": rssi,
                                  "ok": node_ok}
            if not node_ok:
                all_ok = False
                if rate < MIN_RATE_HZ:
                    prompts.append(f"node {n.node_id}: only {rate:.0f} Hz "
                                   f"(need ≥{MIN_RATE_HZ:.0f}) — check power "
                                   "and Wi-Fi association")
                if rssi <= RSSI_SANE_MIN:
                    prompts.append(f"move node {n.node_id} closer to the "
                                   f"host (RSSI {rssi} dBm)")
        if all_ok:
            prompts.insert(0, "All nodes streaming healthily.")
        return all_ok, prompts, {"nodes": results}

    def _step_room_assignment(self, inp: dict) -> tuple[bool, list[str], dict]:
        rooms = inp.get("rooms")
        if not rooms:
            return False, ["Provide {'rooms': {room_name: [node_ids]}} "
                           "covering every paired node."], {
                "nodes": [n.node_id for n in self.config.nodes]}
        known = {n.node_id for n in self.config.nodes}
        assigned: set[int] = set()
        for room, ids in rooms.items():
            for nid in ids:
                if int(nid) not in known:
                    return False, [f"unknown node_id {nid} in room "
                                   f"{room!r}"], {}
                if int(nid) in assigned:
                    return False, [f"node {nid} assigned to more than one "
                                   "room"], {}
                assigned.add(int(nid))
        missing = sorted(known - assigned)
        if missing:
            return False, [f"nodes {missing} not assigned to any room"], {}
        self.config.rooms = {room: [int(i) for i in ids]
                             for room, ids in rooms.items()}
        for n in self.config.nodes:
            n.room = self.config.room_of(n.node_id)
        return True, [f"{len(rooms)} room(s) configured."], {
            "rooms": self.config.rooms}

    def _step_placement_validation(self, inp: dict
                                   ) -> tuple[bool, list[str], dict]:
        energies = inp.get("energy")
        if energies is None and self._capture is not None:
            energies = {n.node_id: self._capture(n.node_id, 10.0)
                        for n in self.config.nodes}
        if energies is None:
            return False, ["Walk through each room now, then pass "
                           "{'energy': {node_id: [10 s of motion energy]}} "
                           "(or inject capture=)."], {}
        energies = {int(k): v for k, v in energies.items()}
        rssi_notes = self._notes.get("rssi", {})
        report: dict[int, dict] = {}
        prompts: list[str] = []
        all_ok = True
        for n in self.config.nodes:
            e = np.asarray(energies.get(n.node_id, []), dtype=np.float64)
            entry: dict[str, Any] = {"ok": False, "hint": ""}
            if e.size < 4:
                entry["hint"] = (f"node {n.node_id}: no motion capture "
                                 "received — is it streaming?")
            else:
                peak = float(e.max())
                quiet = float(max(np.median(e), 1e-9))
                ratio = peak / quiet
                rssi = int(rssi_notes.get(str(n.node_id), -60))
                rssi_ok = RSSI_SANE_MIN <= rssi <= RSSI_SANE_MAX
                energy_ok = ratio > MIN_PEAK_QUIET_RATIO
                entry.update({"peak": peak, "quiet": quiet,
                              "ratio": round(ratio, 2), "rssi": rssi,
                              "ok": energy_ok and rssi_ok})
                if not energy_ok:
                    entry["hint"] = (f"move node {n.node_id} closer to the "
                                     f"walking path — it barely saw the walk "
                                     f"(peak/quiet {ratio:.1f}x, need "
                                     f">{MIN_PEAK_QUIET_RATIO:.0f}x)")
                elif not rssi_ok:
                    entry["hint"] = (f"move node {n.node_id} closer to the "
                                     f"host — RSSI {rssi} dBm out of range")
            report[n.node_id] = entry
            if not entry["ok"]:
                all_ok = False
                prompts.append(entry["hint"])
        if all_ok:
            prompts.insert(0, "All nodes see motion clearly.")
        return all_ok, prompts, {"nodes": report}

    def _step_channel_survey(self, inp: dict) -> tuple[bool, list[str], dict]:
        scores = inp.get("scores")
        if scores is None:
            if self._surveyor is None:
                return False, ["No surveyor injected — pass "
                               "{'scores': {channel: score}} or "
                               "skip(step)."], {}
            scores = self._surveyor.survey()
        scores = {int(k): float(v) for k, v in scores.items()}
        if not scores:
            return False, ["Channel survey returned nothing — retry or "
                           "skip(step)."], {}
        best = max(scores, key=scores.get)  # higher score = cleaner channel
        self.config.channel = int(best)
        return True, [f"Channel {best} selected (cleanest of "
                      f"{len(scores)})."], {"scores": scores,
                                            "channel": best}

    def _step_vitals_zone(self, inp: dict) -> tuple[bool, list[str], dict]:
        vz = inp.get("vitals_zone")
        if not vz:
            return False, ["Provide {'vitals_zone': {room: node_id}} — the "
                           "node nearest the bed in each sleeping room."], {
                "rooms": list(self.config.rooms)}
        for room, nid in vz.items():
            if room not in self.config.rooms:
                return False, [f"unknown room {room!r}"], {}
            if int(nid) not in self.config.rooms[room]:
                return False, [f"node {nid} is not in room {room!r}"], {}
        self.config.vitals_zone = {room: int(nid) for room, nid in vz.items()}
        for n in self.config.nodes:
            if self.config.vitals_zone.get(n.room) == n.node_id:
                n.zone = "bed"
        return True, ["Vitals zones set."], {
            "vitals_zone": self.config.vitals_zone}

    def _step_done(self, inp: dict) -> tuple[bool, list[str], dict]:
        return True, ["Setup complete."], {
            "summary": self._notes.get("summary", self._summary())}


def _config_from_dict(raw: dict) -> VigilConfig:
    """Rebuild a VigilConfig from its asdict() form (mirrors VigilConfig.load)."""
    return VigilConfig(
        nodes=[NodeConfig(**n) for n in raw.get("nodes", [])],
        rooms={k: [int(i) for i in v] for k, v in raw.get("rooms", {}).items()},
        vitals_zone={k: int(v) for k, v in raw.get("vitals_zone", {}).items()},
        channel=raw.get("channel", 6),
        host_ip=raw.get("host_ip", "0.0.0.0"),
        udp_port=raw.get("udp_port", 5566),
        ring_buffer_s=raw.get("ring_buffer_s", 300.0),
        thresholds=Thresholds(**raw.get("thresholds", {})),
        alerts=AlertsConfig(**raw.get("alerts", {})),
    )
