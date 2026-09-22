import hashlib
import json
import os
import re
import stat
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path


ACTION_TOKEN_PATTERN = re.compile(r"\b(RESET|ACTION[1-7])\b", re.IGNORECASE)
EMITTED_ACTION_PATTERN = re.compile(
    r"\AMEMORY:[^\r\n]*\r?\n"
    r"(RESET|ACTION[1-7])(?:\s+(\d+)\s+(\d+))?\s*\Z",
    re.IGNORECASE,
)
FRAME_HEADER_PATTERN = re.compile(r"^\s*Frame\s+\d+\s*:\s*$", re.IGNORECASE)
RAW_ROW_PATTERN = re.compile(r"^\s*\[(\s*-?\d+(?:\s*,\s*-?\d+)*)\s*\]\s*$")
STATE_PATTERN = re.compile(r"^\s*State:\s*(\S+)", re.MULTILINE)
LEVELS_PATTERN = re.compile(r"^\s*Levels completed:\s*(\d+)", re.MULTILINE)
AVAILABLE_PATTERN = re.compile(
    r"^\s*-\s*(RESET|ACTION[1-7])(?:\s|$)", re.MULTILINE | re.IGNORECASE
)
GAME_PATTERN = re.compile(
    r"\bgame(?:\s+identifier)?\s*[:=]?\s*['\"]?([a-z0-9]{4}(?:-[0-9a-z]{8,64})?)",
    re.IGNORECASE,
)
ARC_CONTEXT_RESET_TOKENS = 120000
ARC_CONTEXT_RESET_INVOCATIONS = 48
ARC_ESCALATE_ACTIONS = 300
ARC_ESCALATE_RESETS = 2
ARC_SESSION_SCHEMA = 3
ARC_LEDGER_SCHEMA = 1


class ArcSessionCorruption(RuntimeError):
    """Raised when durable ARC state cannot be verified without guessing."""


class ArcPlanRejected(ValueError):
    """Raised when a model plan cannot be proven safe enough to execute."""


ARC_WORKSPACE_GUIDE = """# Black Label Operator ARC workspace

You are solving one unknown ARC-AGI-3 interactive game. All reasoning must be
game-general: do not inspect the game implementation, benchmark source, or files
outside this workspace. The environment actions are expensive; computation over
recorded observations is free.

## Ground truth

- `observations.jsonl` is append-only and contains every settled board, action,
  state, level count, available action, and derived board diff. Each row is
  hash-chained and names the exact emitted action it settles.
- `actions.jsonl` and `responses.jsonl` are append-only receipts for actions and
  HTTP responses. Never rewrite them; they make retries safe after a restart.
- `observations/step-*.txt` preserves the original observation text.
- `log.txt` is a compact index. Read its latest entries before acting.
- `arc_workspace.py` loads the JSONL into Python objects and provides `diff`,
  `objects`, and `expectation_errors`. Use it instead of eyeballing 64x64 grids.
- `hypotheses.json` is the current competing-hypothesis ledger. It must use
  schema version 2, name the latest evidence receipt in
  `updated_through_receipt`, and keep at least two competing explanations.
  Evidence IDs must come from the authoritative observation chain. Candidate,
  confirmed, and falsified states are checked by the controller; confirmation
  requires a replayed matching transition and falsification requires a replayed
  mismatch. Never promote a claim from prose alone.

## Durable reasoning

Maintain `playbook.md` as a compact briefing that survives context resets:

- **Working model:** controls, entities, mechanics, objective, hazards, and timer
  behavior. Mark claims as verified or assumed. Raw observations win conflicts.
- **Working memory:** current level, attempt, plan, unresolved evidence, and ruled
  out hypotheses. Compact it; do not turn it into a chronological journal.

Each `hypotheses.json` entry has exactly these fields:

```
{
  "id":"h-left", "claim":"ACTION1 moves the controlled object left",
  "state":"candidate", "updated_through_receipt":"<current receipt>",
  "supporting_receipts":["<authoritative receipt>"],
  "contradicting_receipts":[],
  "discriminating_prediction":{
    "action":{"action":"ACTION1"},
    "expected":{"cells":[[3,7,2]]},
    "distinguishes_from":["h-rotate"]
  },
  "replay_evidence":[]
}
```

Every `distinguishes_from` link must be reciprocal: the paired hypothesis uses
the same action but predicts a different outcome. `expected` may contain only
`state`, `levels_completed`, `cells`, and `diff`. Replay rows are exact adjacent
receipt pairs: `{"before_receipt":"...","after_receipt":"..."}`.

Build an executable `world_model.py` (or a model beneath `scratch/`) exporting
exactly one `WORLD_MODEL` object. It must implement `model_id`, `model_revision`,
`model_manifest()`, `canonical_state(state)`, `init(observation)`,
`transition(state, action)`, `render(state)`, and `outcome(state)`. Import
`ArcWorldOutcome` from `blacklabel_operator.arc_world_model`. The controller
runs two independent deterministic replays and hashes the complete predicted
frame after every action. Store search code separately in `planner.py`.

## Method

1. Inspect the newest diff and current board programmatically.
2. Form competing hypotheses and reject any contradicted by the log.
3. Rank probes by expected information gain divided by action cost. A probe is
   exactly one action tied to a named candidate hypothesis and its reciprocal
   discriminating prediction in `hypotheses.json`.
4. Once a mechanic is verified, forward-simulate and use bounded BFS, A*, or
   dynamic programming to find the shortest robust plan.
5. Hash `world_model.py` after its final write and cite that exact SHA-256 in the
   action contract. Any source drift, full-frame mismatch, state mismatch,
   evidence drift, or hypothesis drift stops the queue before another action.
6. Treat changing full-width/full-height edge strips as likely timers or budgets,
   not gameplay objects, unless evidence says otherwise.
7. RESET discards the attempt. Prefer undo when available; never repeat RESET on
   an already fresh attempt.

## Output contract

End every reply with one final block and no material after its JSON object:

```
[ACTIONS]
{"mode":"probe","hypothesis_id":"h-controls-left","world_model":{"path":"world_model.py","sha256":"<64 lowercase hex>"},"plan":[{"action":"ACTION1"}],"reasoning":"discriminate left from rotate"}
```

Use `mode:"probe"` for exactly one information-gain action. Use
`mode:"validated_plan"` for 1-128 searched actions only when the selected
hypothesis is already receipt-confirmed. `ACTION6` additionally requires exact
integer `x` and `y` fields in 0..63; no other action accepts extra fields. The
controller, not prose or sparse cells, generates and seals the full-frame plan.
All object keys are exact; unknown or duplicate keys reject the whole turn.
"""


ARC_WORKSPACE_HELPER = r'''"""Structured access to Black Label Operator ARC observations."""

import hashlib
import json
from collections import deque
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Step:
    step: int
    action: dict
    state: str
    levels_completed: int
    available: tuple
    frame: tuple
    diff: tuple
    receipt_id: str = ""
    action_receipt_id: object = None

    def cell(self, x, y):
        return self.frame[y][x]


@dataclass(frozen=True)
class Object:
    color: int
    cells: tuple
    bbox: tuple
    size: int
    centroid: tuple
    shape_hash: str


def load(path="observations.jsonl"):
    steps = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        steps.append(
            Step(
                step=int(item["step"]),
                action=dict(item["action"]),
                state=str(item["state"]),
                levels_completed=int(item["levels_completed"]),
                available=tuple(item["available"]),
                frame=tuple(tuple(row) for row in item["frame"]),
                diff=tuple(tuple(cell) for cell in item.get("diff", [])),
                receipt_id=str(item.get("receipt_sha256") or ""),
                action_receipt_id=item.get("action_receipt_id"),
            )
        )
    return steps


def diff(before, after):
    a = before.frame if isinstance(before, Step) else before
    b = after.frame if isinstance(after, Step) else after
    if len(a) != len(b) or any(len(x) != len(y) for x, y in zip(a, b)):
        raise ValueError("frames must have the same dimensions")
    return [
        (x, y, int(a[y][x]), int(b[y][x]))
        for y in range(len(a))
        for x in range(len(a[y]))
        if a[y][x] != b[y][x]
    ]


def objects(board, colors=None, connectivity=4):
    grid = board.frame if isinstance(board, Step) else board
    wanted = None if colors is None else ({colors} if isinstance(colors, int) else set(colors))
    offsets = ((1, 0), (-1, 0), (0, 1), (0, -1))
    if connectivity == 8:
        offsets += ((1, 1), (1, -1), (-1, 1), (-1, -1))
    elif connectivity != 4:
        raise ValueError("connectivity must be 4 or 8")
    height = len(grid)
    width = len(grid[0]) if height else 0
    seen = set()
    result = []
    for y in range(height):
        for x in range(width):
            color = int(grid[y][x])
            if (x, y) in seen or (wanted is None and color == 0) or (wanted is not None and color not in wanted):
                continue
            queue = deque([(x, y)])
            seen.add((x, y))
            cells = []
            while queue:
                cx, cy = queue.popleft()
                cells.append((cx, cy))
                for dx, dy in offsets:
                    nx, ny = cx + dx, cy + dy
                    if not (0 <= nx < width and 0 <= ny < height) or (nx, ny) in seen:
                        continue
                    if int(grid[ny][nx]) != color:
                        continue
                    seen.add((nx, ny))
                    queue.append((nx, ny))
            xs = [cell[0] for cell in cells]
            ys = [cell[1] for cell in cells]
            x0, y0 = min(xs), min(ys)
            normalized = sorted((cx - x0, cy - y0) for cx, cy in cells)
            digest = hashlib.sha256(repr((color, normalized)).encode()).hexdigest()[:16]
            result.append(Object(color, tuple(sorted(cells)), (x0, y0, max(xs), max(ys)), len(cells), (sum(xs) / len(xs), sum(ys) / len(ys)), digest))
    return result


def expectation_errors(step, cells=(), levels=None):
    errors = []
    if levels is not None and step.levels_completed != levels:
        errors.append("levels=%s expected=%s" % (step.levels_completed, levels))
    for x, y, color in cells:
        actual = step.cell(int(x), int(y))
        if actual != int(color):
            errors.append("cell(%s,%s)=%s expected=%s" % (x, y, actual, color))
    return errors


def transition_index(steps):
    """Index settled transitions by action and prior board hash."""
    result = {}
    for before, after in zip(steps, steps[1:]):
        key = (before.receipt_id, str(after.action.get("action") or ""))
        result[key] = after
    return result


def shortest_plan(initial, goal, expand, max_nodes=100000):
    """Generic bounded BFS for a verified deterministic world model."""
    queue = deque([(initial, ())])
    seen = {repr(initial)}
    while queue and len(seen) <= int(max_nodes):
        state, plan = queue.popleft()
        if goal(state):
            return list(plan)
        for action, successor in expand(state):
            key = repr(successor)
            if key in seen:
                continue
            seen.add(key)
            queue.append((successor, plan + (action,)))
    return None
'''


@dataclass(frozen=True)
class ArcObservation:
    text: str
    state: str
    levels_completed: int
    available: tuple
    frame: tuple


@dataclass(frozen=True)
class PlannedArcAction:
    name: str
    x: object = None
    y: object = None
    expect_cells: tuple = ()
    expect_levels: object = None
    receipt_id: object = None

    def as_dict(self):
        item = {"action": self.name}
        if self.name == "ACTION6":
            item.update({"x": self.x, "y": self.y})
        if self.expect_cells:
            item["expect"] = [list(cell) for cell in self.expect_cells]
        if self.expect_levels is not None:
            item["expect_levels"] = self.expect_levels
        return item

    def render(self):
        if self.name == "ACTION6":
            return "ACTION6 %d %d" % (self.x, self.y)
        return self.name


@dataclass
class ArcPlanningSession:
    id: str
    workspace: Path
    state_dir: Path
    game_id: str
    thread_id: object = None
    queue: deque = field(default_factory=deque)
    pending_action: object = None
    last_observation: object = None
    last_emitted_action: object = None
    trigger: str = "initial observation"
    model_invocations: int = 0
    fresh_sessions: int = 0
    context_tokens: int = 0
    step: int = 0
    level_started_step: int = 0
    self_resets: int = 0
    escalation_tier: int = 0
    observation_receipt: object = None
    last_response_text: object = None
    active_request_id: object = None
    replay_response: object = None
    responses: dict = field(default_factory=dict)
    emitted_action_ids: set = field(default_factory=set)
    settled_action_receipts: dict = field(default_factory=dict)
    action_ledger_hash: object = None
    response_ledger_hash: object = None
    hypothesis_ledger_hash: object = None
    epistemic_snapshot_sha256: object = None
    active_plan_sha256: object = None
    active_plan_source_receipt: object = None
    active_plan_source_step: object = None
    active_plan_cursor: int = 0
    active_plan_hypothesis_id: object = None
    active_epistemic_snapshot_sha256: object = None
    active_world_model_path: object = None
    active_world_model_sha256: object = None
    active_hypotheses_file_sha256: object = None
    active_playbook_sha256: object = None
    recovery_note: object = None
    lock: threading.RLock = field(default_factory=threading.RLock)


def _parse_frame(text):
    frames = []
    current = None
    for line in str(text).splitlines():
        if FRAME_HEADER_PATTERN.match(line):
            current = []
            frames.append(current)
            continue
        if current is None:
            continue
        match = RAW_ROW_PATTERN.match(line)
        if match:
            current.append([int(value.strip()) for value in match.group(1).split(",")])
            continue
        if line.strip() and not line[:1].isspace():
            current = None
    frame = next((item for item in reversed(frames) if item), [])
    if frame and len({len(row) for row in frame}) != 1:
        raise ValueError("ARC observation contains ragged frame rows")
    return tuple(tuple(row) for row in frame)


def parse_arc_observation(text):
    text = str(text or "")
    state_match = STATE_PATTERN.search(text)
    levels_match = LEVELS_PATTERN.search(text)
    if not state_match or not levels_match:
        raise ValueError("ARC observation is missing state or level count")
    available = tuple(match.upper() for match in AVAILABLE_PATTERN.findall(text))
    frame = _parse_frame(text)
    if not frame:
        raise ValueError("ARC observation contains no frame")
    return ArcObservation(
        text=text,
        state=state_match.group(1),
        levels_completed=int(levels_match.group(1)),
        available=available,
        frame=frame,
    )


def _valid_coordinate(value):
    return type(value) is int and 0 <= value <= 63


def _parse_action_item(item, available):
    if not isinstance(item, dict):
        raise ValueError("each planned action must be an object")
    name = str(item.get("action") or item.get("action_type") or "").upper()
    if name not in available:
        raise ValueError("planned action %s is not currently available" % (name or "<missing>"))
    x = item.get("x")
    y = item.get("y")
    if name == "ACTION6":
        if not _valid_coordinate(x) or not _valid_coordinate(y):
            raise ValueError("ACTION6 requires integer x/y in 0..63")
    elif x is not None or y is not None:
        raise ValueError("only ACTION6 accepts x/y")
    cells = []
    for cell in item.get("expect") or []:
        if (
            not isinstance(cell, list)
            or len(cell) != 3
            or not all(type(value) is int for value in cell)
            or not (0 <= cell[0] <= 63 and 0 <= cell[1] <= 63)
        ):
            raise ValueError("expect cells must be integer [x,y,color] triples")
        cells.append(tuple(cell))
    expect_levels = item.get("expect_levels")
    if expect_levels is not None and (type(expect_levels) is not int or expect_levels < 0):
        raise ValueError("expect_levels must be a non-negative integer")
    return PlannedArcAction(name, x, y, tuple(cells), expect_levels)


def parse_arc_plan(text, available):
    marker_at = str(text).rfind("[ACTIONS]")
    if marker_at < 0:
        raise ValueError("response has no final [ACTIONS] block")
    fragment = str(text)[marker_at + len("[ACTIONS]") :]
    object_at = fragment.find("{")
    if object_at < 0:
        raise ValueError("[ACTIONS] block has no JSON object")
    try:
        payload, end_at = json.JSONDecoder().raw_decode(fragment[object_at:])
    except json.JSONDecodeError as exc:
        raise ValueError("invalid [ACTIONS] JSON: %s" % exc)
    if fragment[object_at + end_at :].strip():
        raise ValueError("[ACTIONS] block contains trailing material")
    items = payload.get("plan") if isinstance(payload, dict) else None
    if not isinstance(items, list) or not 1 <= len(items) <= 128:
        raise ValueError("plan must contain 1-128 actions")
    actions = [_parse_action_item(item, set(available)) for item in items]
    final_levels = payload.get("expect_levels")
    if final_levels is not None:
        if type(final_levels) is not int or final_levels < 0:
            raise ValueError("expect_levels must be a non-negative integer")
        final = actions[-1]
        actions[-1] = PlannedArcAction(
            final.name,
            final.x,
            final.y,
            final.expect_cells,
            final_levels,
        )
    return actions, str(payload.get("reasoning") or "").strip()


def _frame_diff(before, after):
    if not before or not after or len(before) != len(after):
        return []
    return [
        (x, y, int(before[y][x]), int(after[y][x]))
        for y in range(len(before))
        for x in range(min(len(before[y]), len(after[y])))
        if before[y][x] != after[y][x]
    ]


def _game_id(messages):
    for _role, text in messages:
        match = GAME_PATTERN.search(str(text))
        if match:
            return match.group(1)
    return "unknown"


def _action_from_assistant(text, available):
    del available  # Availability after settlement cannot validate the prior action.
    match = EMITTED_ACTION_PATTERN.fullmatch(str(text or ""))
    if not match:
        return None
    name = match.group(1).upper()
    x_text, y_text = match.group(2), match.group(3)
    if name == "ACTION6":
        if x_text is None or y_text is None:
            return None
        x, y = int(x_text), int(y_text)
        if not _valid_coordinate(x) or not _valid_coordinate(y):
            return None
        return PlannedArcAction(name, x, y)
    if x_text is not None or y_text is not None:
        return None
    return PlannedArcAction(name)


def _safe_memory(text):
    value = ""
    for line in str(text).splitlines():
        if line.strip().upper().startswith("MEMORY:"):
            value = line.split(":", 1)[1].strip()
            break
    if not value:
        value = str(text).split("[ACTIONS]", 1)[0].strip().replace("\n", " ")
    value = ACTION_TOKEN_PATTERN.sub("input", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value[:600] or "plan selected from the verified workspace state"


def _canonical_json(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def _reject_duplicate_json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key %s" % key)
        result[key] = value
    return result


def _reject_json_constant(value):
    raise ValueError("non-finite JSON number %s" % value)


def _strict_json_loads(material):
    return json.loads(
        material,
        object_pairs_hook=_reject_duplicate_json_pairs,
        parse_constant=_reject_json_constant,
    )


def _digest(value):
    return hashlib.sha256(_canonical_json(value)).hexdigest()


def _ledger_entry(payload, previous_hash):
    entry = dict(payload)
    entry["ledger_schema"] = ARC_LEDGER_SCHEMA
    entry["previous_receipt_sha256"] = previous_hash
    entry["receipt_sha256"] = _digest(entry)
    return entry


def _verify_ledger(entries, label):
    previous_hash = None
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise ArcSessionCorruption("%s row %d is not an object" % (label, index))
        if entry.get("ledger_schema") != ARC_LEDGER_SCHEMA:
            raise ArcSessionCorruption(
                "%s row %d has an unsupported schema" % (label, index)
            )
        if entry.get("previous_receipt_sha256") != previous_hash:
            raise ArcSessionCorruption(
                "%s row %d breaks the receipt chain" % (label, index)
            )
        claimed = entry.get("receipt_sha256")
        material = dict(entry)
        material.pop("receipt_sha256", None)
        try:
            actual = _digest(material)
        except (TypeError, ValueError) as exc:
            raise ArcSessionCorruption(
                "%s row %d contains non-canonical JSON: %s" % (label, index, exc)
            )
        if not isinstance(claimed, str) or claimed != actual:
            raise ArcSessionCorruption(
                "%s row %d has an invalid receipt hash" % (label, index)
            )
        previous_hash = claimed
    return previous_hash


def _read_jsonl(path, label):
    if not path.is_file():
        return []
    entries = []
    for index, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        if not line.strip():
            continue
        try:
            entries.append(_strict_json_loads(line))
        except (json.JSONDecodeError, ValueError) as exc:
            raise ArcSessionCorruption(
                "%s row %d is invalid JSON: %s" % (label, index, exc)
            )
    _verify_ledger(entries, label)
    return entries


def _append_jsonl(path, entry):
    path.parent.mkdir(parents=True, exist_ok=True)
    previous = None
    if path.is_file() and path.stat().st_size:
        with path.open("rb") as existing:
            existing.seek(0, os.SEEK_END)
            position = existing.tell()
            chunk = b""
            while position > 0 and b"\n" not in chunk.rstrip(b"\n"):
                read_size = min(8192, position)
                position -= read_size
                existing.seek(position)
                chunk = existing.read(read_size) + chunk
            lines = [line for line in chunk.splitlines() if line.strip()]
        try:
            tail = _strict_json_loads(lines[-1])
        except (IndexError, json.JSONDecodeError, ValueError) as exc:
            raise ArcSessionCorruption("ledger tail is invalid: %s" % exc)
        claimed = tail.get("receipt_sha256") if isinstance(tail, dict) else None
        material = dict(tail) if isinstance(tail, dict) else {}
        material.pop("receipt_sha256", None)
        try:
            actual = _digest(material)
        except (TypeError, ValueError) as exc:
            raise ArcSessionCorruption(
                "ledger tail contains non-canonical JSON: %s" % exc
            )
        if not isinstance(claimed, str) or claimed != actual:
            raise ArcSessionCorruption("ledger tail receipt hash is invalid")
        if claimed == entry.get("receipt_sha256"):
            return False
        previous = claimed
    if entry.get("previous_receipt_sha256") != previous:
        raise ArcSessionCorruption("ledger append does not extend its durable tail")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    return True


def _atomic_json(path, payload):
    material = dict(payload)
    material["manifest_sha256"] = _digest(material)
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(material, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(str(temporary), str(path))


def _read_manifest(path):
    try:
        payload = _strict_json_loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        raise ArcSessionCorruption("session manifest is unreadable: %s" % exc)
    if not isinstance(payload, dict):
        raise ArcSessionCorruption("session manifest is not an object")
    claimed = payload.pop("manifest_sha256", None)
    try:
        actual = _digest(payload)
    except (TypeError, ValueError) as exc:
        raise ArcSessionCorruption("session manifest is non-canonical: %s" % exc)
    if not isinstance(claimed, str) or claimed != actual:
        raise ArcSessionCorruption("session manifest hash mismatch")
    if payload.get("schema_version") != ARC_SESSION_SCHEMA:
        raise ArcSessionCorruption("session manifest schema is unsupported")
    return payload


def _read_canonical_epistemic_snapshot(path, label):
    from .arc_epistemic import (
        ArcEpistemicValidationError,
        render_arc_epistemic_snapshot,
    )

    try:
        material = path.read_text(encoding="utf-8")
        snapshot = _strict_json_loads(material)
        canonical = render_arc_epistemic_snapshot(snapshot)
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        ValueError,
        ArcEpistemicValidationError,
    ) as exc:
        raise ArcSessionCorruption("%s is unreadable: %s" % (label, exc))
    if material != canonical:
        raise ArcSessionCorruption("%s bytes are not canonical" % label)
    return snapshot


def _internal_action(action):
    if action is None:
        return None
    payload = action.as_dict()
    if action.receipt_id:
        payload["receipt_id"] = action.receipt_id
    return payload


def _restore_action(payload):
    if payload is None:
        return None
    if not isinstance(payload, dict):
        raise ArcSessionCorruption("persisted action is not an object")
    name = str(payload.get("action") or "").upper()
    if name not in {"RESET", "ACTION1", "ACTION2", "ACTION3", "ACTION4", "ACTION5", "ACTION6", "ACTION7"}:
        raise ArcSessionCorruption("persisted action name is invalid")
    action = _parse_action_item(payload, {name})
    receipt_id = payload.get("receipt_id")
    if receipt_id is not None and not isinstance(receipt_id, str):
        raise ArcSessionCorruption("persisted action receipt is invalid")
    return PlannedArcAction(
        action.name,
        action.x,
        action.y,
        action.expect_cells,
        action.expect_levels,
        receipt_id,
    )


class ArcPlanningRegistry:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.state_root = self.root / ".operator-state"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self._by_thread = {}
        self._by_game = {}
        self._by_response = {}
        self._sessions = {}
        self._corrupt_games = {}
        self._inflight = {}
        self._lock = threading.RLock()
        self._load_existing()

    def _load_existing(self):
        for state_dir in sorted(self.state_root.iterdir()):
            if not state_dir.is_dir():
                continue
            try:
                session = self._load_workspace(state_dir)
            except ArcSessionCorruption as exc:
                game_id = self._recover_game_id(state_dir)
                if game_id != "unknown":
                    self._corrupt_games[game_id] = "%s: %s" % (state_dir.name, exc)
                continue
            if session is None:
                continue
            self._sessions[session.id] = session
            if session.thread_id:
                self._by_thread[session.thread_id] = session
            for response in session.responses.values():
                response_id = response.get("response_id")
                if response_id:
                    self._by_response[response_id] = session
            if session.game_id == "unknown":
                continue
            prior = self._by_game.get(session.game_id)
            if prior is not None and prior.id != session.id:
                self._by_game.pop(session.game_id, None)
                self._corrupt_games[session.game_id] = (
                    "multiple durable workspaces exist for one public game"
                )
            elif session.game_id not in self._corrupt_games:
                self._by_game[session.game_id] = session

    @staticmethod
    def _recover_game_id(workspace):
        manifest = workspace / "session.json"
        try:
            payload = _strict_json_loads(manifest.read_text(encoding="utf-8"))
            game_id = payload.get("game_id") if isinstance(payload, dict) else None
            if isinstance(game_id, str) and game_id:
                return game_id
        except (OSError, json.JSONDecodeError, ValueError):
            pass
        for filename in (
            "observations.jsonl",
            "actions.jsonl",
            "responses.jsonl",
            "hypothesis_receipts.jsonl",
        ):
            path = workspace / filename
            try:
                for line in path.read_text(encoding="utf-8").splitlines():
                    payload = _strict_json_loads(line)
                    game_id = payload.get("game_id") if isinstance(payload, dict) else None
                    if isinstance(game_id, str) and game_id:
                        return game_id
            except (OSError, json.JSONDecodeError, ValueError):
                continue
        return "unknown"

    def _load_workspace(self, state_dir):
        workspace = self.root / state_dir.name
        (state_dir / "plans").mkdir(exist_ok=True)
        (state_dir / "epistemic").mkdir(exist_ok=True)
        manifest_path = state_dir / "session.json"
        if not manifest_path.is_file():
            # Pre-v2 workspaces had no recoverable game/session identity. They are
            # retained on disk but are not eligible for automatic continuation.
            return None
        manifest_error = None
        try:
            manifest = _read_manifest(manifest_path)
        except ArcSessionCorruption as exc:
            manifest = None
            manifest_error = exc

        observations = _read_jsonl(state_dir / "observations.jsonl", "observations")
        actions = _read_jsonl(state_dir / "actions.jsonl", "actions")
        responses = _read_jsonl(state_dir / "responses.jsonl", "responses")
        hypotheses = _read_jsonl(
            state_dir / "hypothesis_receipts.jsonl", "hypothesis receipts"
        )
        game_ids = {
            entry.get("game_id")
            for entry in observations + actions + responses + hypotheses
            if isinstance(entry.get("game_id"), str)
        }
        session_ids = {
            entry.get("session_id")
            for entry in observations + actions + responses + hypotheses
            if isinstance(entry.get("session_id"), str)
        }
        if len(game_ids) > 1 or len(session_ids) > 1:
            raise ArcSessionCorruption("durable ledgers mix session identities")
        for entry in hypotheses:
            epistemic_sha = entry.get("epistemic_snapshot_sha256")
            snapshot_sha = epistemic_sha or entry.get("hypothesis_snapshot_sha256")
            snapshot_dir = "epistemic" if epistemic_sha else "hypotheses"
            snapshot_path = state_dir / snapshot_dir / (str(snapshot_sha) + ".json")
            if epistemic_sha:
                snapshot = _read_canonical_epistemic_snapshot(
                    snapshot_path, "hypothesis receipt epistemic snapshot"
                )
            else:
                try:
                    snapshot = _strict_json_loads(
                        snapshot_path.read_text(encoding="utf-8")
                    )
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    raise ArcSessionCorruption(
                        "hypothesis receipt has no valid snapshot: %s" % exc
                    )
            valid_snapshot = False
            if isinstance(snapshot_sha, str) and epistemic_sha:
                from .arc_epistemic import canonical_sha256

                material = {
                    "schema_version": snapshot.get("schema_version"),
                    "kind": snapshot.get("kind"),
                    "body": snapshot.get("body"),
                }
                try:
                    actual_snapshot_sha = canonical_sha256(material)
                except ValueError as exc:
                    raise ArcSessionCorruption(
                        "hypothesis snapshot is non-canonical: %s" % exc
                    )
                valid_snapshot = (
                    snapshot.get("snapshot_sha256") == snapshot_sha
                    and actual_snapshot_sha == snapshot_sha
                )
            elif isinstance(snapshot_sha, str):
                valid_snapshot = _digest(snapshot) == snapshot_sha
            if not valid_snapshot:
                raise ArcSessionCorruption("hypothesis snapshot hash mismatch")
        game_id = next(iter(game_ids), None) or (
            manifest.get("game_id") if manifest else None
        )
        session_id = next(iter(session_ids), None) or (
            manifest.get("id") if manifest else None
        )
        if not isinstance(game_id, str) or not game_id:
            raise ArcSessionCorruption("durable ledgers contain no game identity")
        if not isinstance(session_id, str) or session_id != state_dir.name:
            raise ArcSessionCorruption("durable session identity does not match its path")
        if manifest and (
            manifest.get("id") != session_id or manifest.get("game_id") != game_id
        ):
            raise ArcSessionCorruption("manifest and ledger identities disagree")

        for index, entry in enumerate(observations):
            if entry.get("step") != index:
                raise ArcSessionCorruption("observation steps are not contiguous")
            raw_relative = entry.get("raw_path")
            if not isinstance(raw_relative, str):
                raise ArcSessionCorruption("observation raw path is missing")
            raw_path = (state_dir / raw_relative).resolve()
            try:
                raw_path.relative_to(state_dir.resolve())
            except ValueError:
                raise ArcSessionCorruption("observation raw path escapes workspace")
            try:
                raw_text = raw_path.read_text(encoding="utf-8")
            except OSError as exc:
                raise ArcSessionCorruption("observation raw text is missing: %s" % exc)
            if hashlib.sha256(raw_text.encode()).hexdigest() != entry.get(
                "observation_sha256"
            ):
                raise ArcSessionCorruption("observation raw text hash mismatch")

        last_observation = None
        if observations:
            raw_path = state_dir / observations[-1]["raw_path"]
            try:
                last_observation = parse_arc_observation(
                    raw_path.read_text(encoding="utf-8")
                )
            except (OSError, ValueError) as exc:
                raise ArcSessionCorruption("latest observation is invalid: %s" % exc)

        response_map = {}
        for entry in responses:
            request_id = entry.get("request_id")
            response_id = entry.get("response_id")
            if not isinstance(request_id, str) or not isinstance(response_id, str):
                raise ArcSessionCorruption("response receipt identity is invalid")
            prior = response_map.get(request_id)
            if prior and prior.get("response_id") != response_id:
                raise ArcSessionCorruption("one request has conflicting responses")
            response_map[request_id] = entry

        emitted = []
        emitted_ids = set()
        for entry in actions:
            action_id = entry.get("action_id")
            if not isinstance(action_id, str) or action_id in emitted_ids:
                raise ArcSessionCorruption("action receipt identity is invalid")
            restored = _restore_action(dict(entry.get("action") or {}, receipt_id=action_id))
            emitted.append((entry, restored))
            emitted_ids.add(action_id)
        settled_ids = {
            entry.get("action_receipt_id")
            for entry in observations
            if entry.get("action_receipt_id")
        }
        unknown_settled = settled_ids - emitted_ids
        if unknown_settled:
            raise ArcSessionCorruption("observation settles an unknown action receipt")
        pending = [item for item in emitted if item[0]["action_id"] not in settled_ids]
        if len(pending) > 1:
            raise ArcSessionCorruption("multiple emitted actions remain unsettled")

        session = ArcPlanningSession(
            id=session_id,
            workspace=workspace,
            state_dir=state_dir,
            game_id=game_id,
            thread_id=manifest.get("thread_id") if manifest else None,
            last_observation=last_observation,
            last_emitted_action=pending[-1][1] if pending else None,
            pending_action=pending[-1][1] if pending else None,
            step=len(observations),
            observation_receipt=(
                observations[-1].get("receipt_sha256") if observations else None
            ),
            responses=response_map,
            emitted_action_ids=emitted_ids,
            settled_action_receipts={
                entry["action_receipt_id"]: entry.get("observation_sha256")
                for entry in observations
                if entry.get("action_receipt_id")
            },
            action_ledger_hash=actions[-1].get("receipt_sha256") if actions else None,
            response_ledger_hash=(
                responses[-1].get("receipt_sha256") if responses else None
            ),
            hypothesis_ledger_hash=(
                hypotheses[-1].get("receipt_sha256") if hypotheses else None
            ),
            epistemic_snapshot_sha256=(
                (
                    hypotheses[-1].get("epistemic_snapshot_sha256")
                    or hypotheses[-1].get("hypothesis_snapshot_sha256")
                )
                if hypotheses
                else None
            ),
            recovery_note=(
                "manifest recovered from verified ledgers: %s" % manifest_error
                if manifest_error
                else None
            ),
        )
        if manifest:
            session.queue = deque(
                _restore_action(item) for item in (manifest.get("queue") or [])
            )
            session.model_invocations = max(0, int(manifest.get("model_invocations") or 0))
            session.fresh_sessions = max(0, int(manifest.get("fresh_sessions") or 0))
            session.context_tokens = max(0, int(manifest.get("context_tokens") or 0))
            session.level_started_step = max(
                0, min(session.step, int(manifest.get("level_started_step") or 0))
            )
            session.self_resets = max(0, int(manifest.get("self_resets") or 0))
            session.escalation_tier = max(
                0, min(2, int(manifest.get("escalation_tier") or 0))
            )
            session.trigger = str(manifest.get("trigger") or "durable restart")
            session.active_plan_sha256 = manifest.get("active_plan_sha256")
            session.active_plan_source_receipt = manifest.get(
                "active_plan_source_receipt"
            )
            source_step = manifest.get("active_plan_source_step")
            session.active_plan_source_step = (
                int(source_step) if type(source_step) is int and source_step >= 0 else None
            )
            session.active_plan_cursor = max(
                0, int(manifest.get("active_plan_cursor") or 0)
            )
            session.active_plan_hypothesis_id = manifest.get(
                "active_plan_hypothesis_id"
            )
            session.active_epistemic_snapshot_sha256 = manifest.get(
                "active_epistemic_snapshot_sha256"
            )
            session.active_world_model_path = manifest.get("active_world_model_path")
            session.active_world_model_sha256 = manifest.get(
                "active_world_model_sha256"
            )
            session.active_hypotheses_file_sha256 = manifest.get(
                "active_hypotheses_file_sha256"
            )
            session.active_playbook_sha256 = manifest.get("active_playbook_sha256")
            if session.queue and not session.active_plan_sha256:
                session.queue.clear()
                session.trigger = (
                    "durable restart dropped an unbound action queue"
                )
        else:
            self._derive_progress(session, observations)
            session.trigger = "durable state recovered; revalidate before acting"
        if responses:
            session.last_response_text = responses[-1].get("text")
        elif pending:
            session.last_response_text = pending[-1][0].get("response_text")
        self._restore_workspace(session, observations)
        self._persist(session)
        return session

    @staticmethod
    def _derive_progress(session, observations):
        last_levels = None
        session.level_started_step = 0
        session.self_resets = 0
        for entry in observations:
            levels = entry.get("levels_completed")
            if last_levels is None or levels != last_levels:
                session.level_started_step = int(entry["step"])
                session.self_resets = 0
                last_levels = levels
            elif (entry.get("action") or {}).get("action") == "RESET":
                session.self_resets += 1
        actions = max(0, session.step - session.level_started_step)
        if actions >= ARC_ESCALATE_ACTIONS * 2:
            session.escalation_tier = 2
        elif actions >= ARC_ESCALATE_ACTIONS or session.self_resets >= ARC_ESCALATE_RESETS:
            session.escalation_tier = 1

    @staticmethod
    def _clear_active_plan(session, clear_queue=True):
        if clear_queue:
            session.queue.clear()
        session.active_plan_sha256 = None
        session.active_plan_source_receipt = None
        session.active_plan_source_step = None
        session.active_plan_cursor = 0
        session.active_plan_hypothesis_id = None
        session.active_epistemic_snapshot_sha256 = None
        session.active_world_model_path = None
        session.active_world_model_sha256 = None
        session.active_hypotheses_file_sha256 = None
        session.active_playbook_sha256 = None

    @staticmethod
    def _manifest_payload(session):
        return {
            "schema_version": ARC_SESSION_SCHEMA,
            "id": session.id,
            "game_id": session.game_id,
            "thread_id": session.thread_id,
            "step": session.step,
            "model_invocations": session.model_invocations,
            "fresh_sessions": session.fresh_sessions,
            "context_tokens": session.context_tokens,
            "level_started_step": session.level_started_step,
            "self_resets": session.self_resets,
            "escalation_tier": session.escalation_tier,
            "trigger": session.trigger,
            "queue": [_internal_action(action) for action in session.queue],
            "pending_action": _internal_action(session.pending_action),
            "observation_receipt": session.observation_receipt,
            "epistemic_snapshot_sha256": session.epistemic_snapshot_sha256,
            "active_plan_sha256": session.active_plan_sha256,
            "active_plan_source_receipt": session.active_plan_source_receipt,
            "active_plan_source_step": session.active_plan_source_step,
            "active_plan_cursor": session.active_plan_cursor,
            "active_plan_hypothesis_id": session.active_plan_hypothesis_id,
            "active_epistemic_snapshot_sha256": (
                session.active_epistemic_snapshot_sha256
            ),
            "active_world_model_path": session.active_world_model_path,
            "active_world_model_sha256": session.active_world_model_sha256,
            "active_hypotheses_file_sha256": session.active_hypotheses_file_sha256,
            "active_playbook_sha256": session.active_playbook_sha256,
            "updated_at": time.time(),
        }

    def _persist(self, session):
        payload = self._manifest_payload(session)
        _atomic_json(session.state_dir / "session.json", payload)
        # This copy is informational for the reasoning workspace. The daemon
        # only trusts the sibling state directory, which is outside the Codex
        # workspace-write boundary.
        try:
            _atomic_json(session.workspace / "session.json", payload)
        except OSError:
            pass

    @staticmethod
    def _sync_mirror(session, filename):
        authoritative = session.state_dir / filename
        mirror = session.workspace / filename
        mirror.parent.mkdir(parents=True, exist_ok=True)
        material = authoritative.read_bytes() if authoritative.exists() else b""
        temporary = mirror.with_name(mirror.name + ".tmp-" + uuid.uuid4().hex)
        with temporary.open("wb") as handle:
            handle.write(material)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(mirror))

    def _append_ledger(self, session, filename, entry):
        _append_jsonl(session.state_dir / filename, entry)
        try:
            self._sync_mirror(session, filename)
        except OSError:
            pass

    def _restore_workspace(self, session, observations):
        workspace = session.workspace
        workspace.mkdir(parents=True, exist_ok=True)
        for child in ("observations", "plans", "scratch"):
            (workspace / child).mkdir(exist_ok=True)
        guide = workspace / "ARC_WORKSPACE.md"
        helper = workspace / "arc_workspace.py"
        if not guide.is_file():
            guide.write_text(ARC_WORKSPACE_GUIDE, encoding="utf-8")
        if not helper.is_file():
            helper.write_text(ARC_WORKSPACE_HELPER, encoding="utf-8")
        playbook = workspace / "playbook.md"
        if not playbook.is_file():
            playbook.write_text(
                "# Working model\n\n- Recovered receipts; mechanics must be rederived.\n\n"
                "# Working memory\n\n- Inspect the latest observation.\n",
                encoding="utf-8",
            )
        hypothesis_path = workspace / "hypotheses.json"
        if not hypothesis_path.is_file():
            hypothesis_path.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "game_id": session.game_id,
                        "updated_through_receipt": session.observation_receipt,
                        "hypotheses": [],
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
        for entry in observations:
            relative = entry["raw_path"]
            source = session.state_dir / relative
            target = session.workspace / relative
            if not target.is_file() or target.read_bytes() != source.read_bytes():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
        for filename in (
            "observations.jsonl",
            "actions.jsonl",
            "responses.jsonl",
            "hypothesis_receipts.jsonl",
        ):
            self._sync_mirror(session, filename)

    def _new_session(self, messages, thread_id=None):
        session_id = uuid.uuid4().hex
        workspace = self.root / session_id
        state_dir = self.state_root / session_id
        workspace.mkdir(parents=True, exist_ok=False)
        state_dir.mkdir(parents=True, exist_ok=False)
        (state_dir / "observations").mkdir()
        (state_dir / "plans").mkdir()
        (state_dir / "epistemic").mkdir()
        (workspace / "observations").mkdir()
        (workspace / "plans").mkdir()
        (workspace / "scratch").mkdir()
        (workspace / "ARC_WORKSPACE.md").write_text(ARC_WORKSPACE_GUIDE, encoding="utf-8")
        (workspace / "arc_workspace.py").write_text(ARC_WORKSPACE_HELPER, encoding="utf-8")
        (workspace / "playbook.md").write_text(
            "# Working model\n\n- No verified mechanics yet.\n\n"
            "# Working memory\n\n- Inspect the latest observation.\n",
            encoding="utf-8",
        )
        (workspace / "hypotheses.json").write_text(
            json.dumps(
                {
                    "schema_version": 2,
                    "game_id": _game_id(messages),
                    "updated_through_receipt": None,
                    "hypotheses": [],
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        session = ArcPlanningSession(
            id=session_id,
            workspace=workspace,
            state_dir=state_dir,
            game_id=_game_id(messages),
            thread_id=thread_id,
        )
        self._sessions[session_id] = session
        if session.game_id != "unknown":
            self._by_game[session.game_id] = session
        if thread_id:
            self._by_thread[thread_id] = session
        self._persist(session)
        return session

    def prepare(
        self,
        messages,
        thread_id=None,
        request_id=None,
        previous_response_id=None,
    ):
        with self._lock:
            game_id = _game_id(messages)
            if game_id in self._corrupt_games:
                raise ArcSessionCorruption(
                    "refusing to continue corrupt ARC state for %s: %s"
                    % (game_id, self._corrupt_games[game_id])
                )
            session = (
                self._by_response.get(str(previous_response_id))
                if previous_response_id
                else None
            )
            if session is None and thread_id:
                session = self._by_thread.get(thread_id)
            if session is None and game_id != "unknown":
                session = self._by_game.get(game_id)
            if (
                session is not None
                and game_id != "unknown"
                and session.game_id != game_id
            ):
                raise ArcSessionCorruption(
                    "request game identity conflicts with durable session"
                )
            is_new = session is None
            if session is None:
                session = self._new_session(messages, thread_id=thread_id)
        with session.lock:
            session.active_request_id = request_id
            session.replay_response = (
                session.responses.get(request_id) if request_id else None
            )
            if session.replay_response:
                return session
            if not is_new and previous_response_id:
                parent = next(
                    (
                        response
                        for response in session.responses.values()
                        if response.get("response_id")
                        == str(previous_response_id)
                    ),
                    None,
                )
                if parent is None:
                    raise ArcSessionCorruption(
                        "ARC continuation references an unknown parent response"
                    )
                if (
                    session.pending_action is not None
                    and parent.get("action_receipt_id")
                    != session.pending_action.receipt_id
                ):
                    raise ArcSessionCorruption(
                        "ARC continuation forks from a stale parent response"
                    )
            has_assistant = any(role == "assistant" for role, _text in messages)
            if not is_new and has_assistant and session.pending_action is not None:
                last_assistant = next(
                    text
                    for role, text in reversed(messages)
                    if role == "assistant"
                )
                if session.last_response_text and last_assistant != session.last_response_text:
                    raise ArcSessionCorruption(
                        "ARC continuation assistant text conflicts with the durable response"
                    )
            latest_observation = self._latest_observation(messages)
            if (
                not is_new
                and session.pending_action is not None
                and latest_observation is not None
                and session.last_observation is not None
                and latest_observation.text == session.last_observation.text
                and not previous_response_id
                and not has_assistant
            ):
                # The action was durably emitted but the caller has repeated the
                # request that produced it. Re-emit it; do not consume the next
                # queued action or pretend the unchanged board settled it.
                session.replay_response = {
                    "request_id": request_id,
                    "response_id": None,
                    "text": session.last_response_text
                    or self._render_emitted(session.pending_action),
                    "thread_id": session.thread_id,
                    "task_id": "arc-recovered-" + session.pending_action.receipt_id[:20],
                    "created_at": time.time(),
                    "input_tokens": 0,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "pending_replay": True,
                }
                return session
            if is_new:
                self._reconstruct_messages(session, messages)
            else:
                self._ingest_pending_messages(session, messages)
            self._persist(session)
        return session

    @staticmethod
    def _latest_observation(messages):
        for role, text in reversed(messages):
            if role != "user":
                continue
            try:
                return parse_arc_observation(text)
            except ValueError:
                continue
        return None

    def bind(self, session, thread_id):
        if not thread_id:
            return
        with self._lock:
            session.thread_id = thread_id
            self._by_thread[thread_id] = session
            self._persist(session)

    def claim_request(self, session, request_id):
        if not request_id:
            raise ValueError("ARC request identity is required")
        key = (session.id, request_id)
        with session.lock:
            if request_id in session.responses:
                session.replay_response = session.responses[request_id]
                return "replay"
            with self._lock:
                if key in self._inflight:
                    return "wait"
                self._inflight[key] = threading.Event()
            if session.replay_response and session.replay_response.get(
                "pending_replay"
            ):
                return "recover"
            return "owner"

    def wait_for_response(self, session, request_id, timeout):
        key = (session.id, request_id)
        with self._lock:
            event = self._inflight.get(key)
        if event is None:
            with session.lock:
                return session.responses.get(request_id)
        if not event.wait(max(0.0, float(timeout))):
            return None
        with session.lock:
            return session.responses.get(request_id)

    @staticmethod
    def response_task(response):
        if not response:
            return None
        return {
            "id": response.get("task_id") or "arc-replay",
            "state": "succeeded",
            "created_at": response.get("created_at") or time.time(),
            "final_text": response.get("text") or "",
            "thread_id": response.get("thread_id"),
            "input_tokens": int(response.get("input_tokens") or 0),
            "cached_input_tokens": int(response.get("cached_input_tokens") or 0),
            "output_tokens": int(response.get("output_tokens") or 0),
        }

    def complete_request(self, session, request_id, response_id, task):
        if not request_id or not response_id:
            raise ValueError("ARC request and response identities are required")
        key = (session.id, request_id)
        with session.lock:
            existing = session.responses.get(request_id)
            text = str(task.get("final_text") or "")
            if existing:
                if existing.get("text") != text:
                    raise ArcSessionCorruption(
                        "one ARC request produced conflicting finalized responses"
                    )
                response = existing
            else:
                payload = {
                    "session_id": session.id,
                    "game_id": session.game_id,
                    "request_id": request_id,
                    "response_id": response_id,
                    "task_id": str(task.get("id") or "arc-response"),
                    "created_at": float(task.get("created_at") or time.time()),
                    "text": text,
                    "thread_id": task.get("thread_id") or session.thread_id,
                    "input_tokens": int(task.get("input_tokens") or 0),
                    "cached_input_tokens": int(
                        task.get("cached_input_tokens") or 0
                    ),
                    "output_tokens": int(task.get("output_tokens") or 0),
                    "action_receipt_id": (
                        session.last_emitted_action.receipt_id
                        if session.last_emitted_action
                        else None
                    ),
                    "finalized_at": time.time(),
                }
                response = _ledger_entry(payload, session.response_ledger_hash)
                self._append_ledger(session, "responses.jsonl", response)
                session.response_ledger_hash = response["receipt_sha256"]
                session.responses[request_id] = response
                session.last_response_text = text
                session.replay_response = response
                with self._lock:
                    self._by_response[response_id] = session
                self._persist(session)
        with self._lock:
            event = self._inflight.pop(key, None)
        if event:
            event.set()
        return response

    def fail_request(self, session, request_id):
        if not session or not request_id:
            return
        key = (session.id, request_id)
        with self._lock:
            event = self._inflight.pop(key, None)
        if event:
            event.set()

    def _reconstruct_messages(self, session, messages):
        previous_assistant = None
        observations_after_assistant = 0
        for role, text in messages:
            if role == "assistant":
                previous_assistant = text
                observations_after_assistant = 0
                continue
            if role != "user":
                continue
            try:
                observation = parse_arc_observation(text)
            except ValueError:
                continue
            if previous_assistant and observations_after_assistant == 0:
                action = _action_from_assistant(
                    previous_assistant, observation.available
                )
            else:
                action = None
            self._append_observation(session, observation, action)
            if previous_assistant:
                observations_after_assistant += 1

    def _ingest_pending_messages(self, session, messages):
        last_assistant = max(
            (index for index, (role, _text) in enumerate(messages) if role == "assistant"),
            default=-1,
        )
        pending = [
            text
            for role, text in messages[last_assistant + 1 :]
            if role == "user"
        ]
        for index, text in enumerate(pending):
            try:
                observation = parse_arc_observation(text)
            except ValueError:
                continue
            action = session.last_emitted_action if index == 0 else None
            self._append_observation(session, observation, action)
        if pending:
            session.last_emitted_action = None

    def _append_observation(self, session, observation, action):
        previous = session.last_observation
        pending = session.pending_action
        observation_sha = hashlib.sha256(observation.text.encode()).hexdigest()
        if action is not None:
            action = self._ensure_action_receipt(
                session, action, source="reconstructed-history"
            )
            settled_sha = session.settled_action_receipts.get(action.receipt_id)
            if settled_sha == observation_sha:
                return False
            if settled_sha is not None:
                raise ArcSessionCorruption(
                    "one action receipt produced conflicting observations"
                )
        elif previous and previous.text == observation.text:
            return False
        if pending is not None:
            if action is None or action.receipt_id != pending.receipt_id:
                raise ArcSessionCorruption(
                    "observation does not settle the exact pending action receipt"
                )
        diff = _frame_diff(previous.frame, observation.frame) if previous else []
        causal_outcome = self._evaluate_active_prediction(
            session, observation, action
        )
        trigger = None
        level_changed = bool(
            previous and observation.levels_completed != previous.levels_completed
        )
        if previous is None:
            session.level_started_step = session.step
        elif level_changed:
            session.level_started_step = session.step
            session.self_resets = 0
            session.escalation_tier = 0
        elif (
            action
            and action.name == "RESET"
            and previous.state != "GAME_OVER"
        ):
            session.self_resets += 1
        if causal_outcome and not causal_outcome["matched"]:
            trigger = "prediction mismatch: " + "; ".join(
                causal_outcome["errors"][:8]
            )
        elif action and pending and causal_outcome is None:
            errors = self._expectation_errors(pending, observation)
            if errors:
                trigger = "prediction mismatch: " + "; ".join(errors[:8])
        elif action is None and previous is not None:
            trigger = "unattributed observation invalidated the active plan"
        if trigger:
            pass
        elif level_changed:
            trigger = "level counter changed"
        elif previous and observation.state != previous.state:
            trigger = "game state changed from %s to %s" % (
                previous.state,
                observation.state,
            )
        actions_this_level = max(0, session.step - session.level_started_step + 1)
        escalation_tier = 0
        if actions_this_level >= ARC_ESCALATE_ACTIONS * 2:
            escalation_tier = 2
        elif (
            actions_this_level >= ARC_ESCALATE_ACTIONS
            or session.self_resets >= ARC_ESCALATE_RESETS
        ):
            escalation_tier = 1
        if escalation_tier > session.escalation_tier:
            session.escalation_tier = escalation_tier
            if trigger is None:
                trigger = "stuck-level escalation tier %d" % escalation_tier
        if trigger:
            session.queue.clear()
            session.trigger = trigger
        elif not session.queue and session.step:
            session.trigger = "action queue exhausted"

        raw_relative = Path("observations") / ("step-%04d.txt" % session.step)
        raw_path = session.state_dir / raw_relative
        if raw_path.exists():
            if raw_path.read_text(encoding="utf-8") != observation.text:
                raise ArcSessionCorruption(
                    "observation path already contains different evidence"
                )
        else:
            raw_path.write_text(observation.text, encoding="utf-8")
        mirror_raw_path = session.workspace / raw_relative
        try:
            mirror_raw_path.write_text(observation.text, encoding="utf-8")
        except OSError:
            pass
        action_payload = (
            action.as_dict()
            if action
            else {"action": "INIT" if previous is None else "UNATTRIBUTED"}
        )
        payload = {
            "session_id": session.id,
            "game_id": session.game_id,
            "step": session.step,
            "action": action_payload,
            "action_receipt_id": action.receipt_id if action else None,
            "state": observation.state,
            "levels_completed": observation.levels_completed,
            "available": list(observation.available),
            "frame": [list(row) for row in observation.frame],
            "diff": [list(cell) for cell in diff],
            "observation_sha256": observation_sha,
            "raw_path": str(raw_relative),
        }
        if causal_outcome is not None:
            payload["causal_outcome"] = causal_outcome
        entry = _ledger_entry(payload, session.observation_receipt)
        self._append_ledger(session, "observations.jsonl", entry)
        try:
            self._append_log(session, entry)
        except OSError:
            pass
        session.last_observation = observation
        session.pending_action = None
        if action:
            session.settled_action_receipts[action.receipt_id] = observation_sha
        session.step += 1
        session.observation_receipt = entry["receipt_sha256"]
        if causal_outcome is not None:
            if causal_outcome["matched"]:
                session.active_plan_cursor += 1
                plan = self._load_validated_plan(session)
                if session.active_plan_cursor >= len(plan.predictions):
                    self._clear_active_plan(session)
                    session.trigger = "validated plan completed"
            else:
                self._clear_active_plan(session)
        self._persist(session)
        return True

    def _ensure_action_receipt(self, session, action, source, response_text=None):
        if action.receipt_id and action.receipt_id in session.emitted_action_ids:
            return action
        action_payload = action.as_dict()
        action_id = action.receipt_id or _digest(
            {
                "kind": "arc-action-v2",
                "session_id": session.id,
                "source": source,
                "step": session.step,
                "evidence": session.observation_receipt,
                "action": action_payload,
            }
        )
        restored = PlannedArcAction(
            action.name,
            action.x,
            action.y,
            action.expect_cells,
            action.expect_levels,
            action_id,
        )
        if action_id in session.emitted_action_ids:
            return restored
        payload = {
            "session_id": session.id,
            "game_id": session.game_id,
            "action_id": action_id,
            "source": source,
            "step_before": session.step,
            "evidence_receipt": session.observation_receipt,
            "validated_plan_sha256": session.active_plan_sha256,
            "validated_plan_index": session.active_plan_cursor,
            "epistemic_snapshot_sha256": (
                session.active_epistemic_snapshot_sha256
            ),
            "world_model_sha256": session.active_world_model_sha256,
            "action": action_payload,
            "response_text": response_text,
            "emitted_at": time.time(),
        }
        entry = _ledger_entry(payload, session.action_ledger_hash)
        self._append_ledger(session, "actions.jsonl", entry)
        session.action_ledger_hash = entry["receipt_sha256"]
        session.emitted_action_ids.add(action_id)
        return restored

    @staticmethod
    def _render_emitted(action, memory="durably replaying the prior action receipt"):
        return "MEMORY: %s\n%s" % (_safe_memory(memory), action.render())

    @staticmethod
    def _append_log(session, entry):
        diff = entry["diff"]
        if not diff:
            diff_text = "none"
        elif len(diff) <= 64:
            diff_text = "%d cells: %s" % (
                len(diff),
                " ".join("(%d,%d) %d>%d" % tuple(cell) for cell in diff),
            )
        else:
            xs = [cell[0] for cell in diff]
            ys = [cell[1] for cell in diff]
            diff_text = "%d cells in bbox (%d,%d)-(%d,%d)" % (
                len(diff),
                min(xs),
                min(ys),
                max(xs),
                max(ys),
            )
        action = entry["action"]
        action_text = action["action"]
        if action_text == "ACTION6":
            action_text += " x=%d y=%d" % (action["x"], action["y"])
        block = (
            "[STEP {step}]\n[ACTION] {action}\n[STATE] {state}\n"
            "[LEVELS] {levels}\n[AVAILABLE] {available}\n[DIFF] {diff}\n"
            "[OBSERVATION] {raw}\n\n"
        ).format(
            step=entry["step"],
            action=action_text,
            state=entry["state"],
            levels=entry["levels_completed"],
            available=" ".join(entry["available"]),
            diff=diff_text,
            raw=entry["raw_path"],
        )
        with (session.workspace / "log.txt").open("a", encoding="utf-8") as handle:
            handle.write(block)

    @staticmethod
    def _expectation_errors(action, observation):
        errors = []
        if (
            action.expect_levels is not None
            and observation.levels_completed != action.expect_levels
        ):
            errors.append(
                "levels=%d expected=%d"
                % (observation.levels_completed, action.expect_levels)
            )
        for x, y, color in action.expect_cells:
            if y >= len(observation.frame) or x >= len(observation.frame[y]):
                errors.append("cell(%d,%d) outside observed frame" % (x, y))
                continue
            actual = observation.frame[y][x]
            if actual != color:
                errors.append("cell(%d,%d)=%d expected=%d" % (x, y, actual, color))
        return errors

    def take_queued(self, session):
        with session.lock:
            if session.replay_response:
                return str(session.replay_response.get("text") or "") or None
            if (
                not session.queue
                or not session.last_observation
                or session.pending_action is not None
            ):
                return None
            action = session.queue[0]
            try:
                self._validate_active_action_release(session, action)
            except (ArcSessionCorruption, OSError, ValueError, RuntimeError) as exc:
                self._clear_active_plan(session)
                session.trigger = "queued plan invalidated before action: %s" % exc
                self._persist(session)
                return None
            session.queue.popleft()
            response = self._emit(
                session, action, "executing a prediction-checked queued plan"
            )
            self._persist(session)
            return response

    def model_prompt(self, session):
        with session.lock:
            hypothesis_sha = session.epistemic_snapshot_sha256 or "none"
            session.model_invocations += 1
            first = session.model_invocations == 1
            rotate_context = not first and (
                session.context_tokens >= ARC_CONTEXT_RESET_TOKENS
                or session.model_invocations % ARC_CONTEXT_RESET_INVOCATIONS == 0
            )
            if rotate_context:
                session.thread_id = None
                session.context_tokens = 0
                session.fresh_sessions += 1
            escalation = self._escalation_directive(session)
            if first:
                prompt = (
                    "You are the exact gpt-5.6-sol reasoning core for an official "
                    "ARC-AGI-3 run. Work only in this per-game workspace. Read "
                    "ARC_WORKSPACE.md first, then inspect log.txt, playbook.md, and "
                    "hypotheses.json plus the structured observations with "
                    "arc_workspace.py. Build and verify a durable world model, "
                    "rank competing hypotheses by evidence and information gain, "
                    "update the playbook and hypothesis ledger, and finish "
                    "with the required [ACTIONS] plan. Game identifier: %s. "
                    "Current trigger: %s."
                    % (session.game_id, session.trigger)
                )
            elif rotate_context:
                prompt = (
                    "Join the existing ARC-AGI-3 game in a fresh Codex context. "
                    "Your predecessor's durable state is in this workspace through "
                    "step %d. Trigger: %s. Read ARC_WORKSPACE.md and playbook.md, "
                    "then verify hypotheses.json and the current state from log.txt and "
                    "observations.jsonl. Preserve confirmed knowledge, repair any "
                    "contradiction, and finish with a prediction-checked [ACTIONS] "
                    "plan."
                    % (max(0, session.step - 1), session.trigger)
                )
            else:
                prompt = (
                    "Continue the same ARC-AGI-3 game from the durable workspace. "
                    "New observations are appended through step %d. Trigger: %s. "
                    "Read the latest [DIFF] entries first, verify or repair the "
                    "competing hypotheses and world model against observations.jsonl, "
                    "run bounded search before spending a live action, update "
                    "playbook.md and hypotheses.json, "
                    "and finish with a new prediction-checked [ACTIONS] plan."
                    % (max(0, session.step - 1), session.trigger)
                )
            self._persist(session)
            return (
                prompt
                + " Evidence receipt: %s. Prior epistemic snapshot: %s."
                % (session.observation_receipt or "none", hypothesis_sha)
                + escalation
            )

    @staticmethod
    def _stable_workspace_file(path, label, maximum_bytes=1024 * 1024):
        try:
            before = path.lstat()
        except OSError as exc:
            raise ArcSessionCorruption("%s is unreadable: %s" % (label, exc))
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise ArcSessionCorruption("%s must be a regular non-symlink file" % label)
        if before.st_size > maximum_bytes:
            raise ArcSessionCorruption("%s exceeds its size limit" % label)
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = None
        try:
            descriptor = os.open(str(path), flags)
            opened_before = os.fstat(descriptor)
            material = b""
            while True:
                chunk = os.read(descriptor, min(65536, maximum_bytes + 1 - len(material)))
                if not chunk:
                    break
                material += chunk
                if len(material) > maximum_bytes:
                    raise ArcSessionCorruption("%s exceeds its size limit" % label)
            opened_after = os.fstat(descriptor)
        except ArcSessionCorruption:
            raise
        except OSError as exc:
            raise ArcSessionCorruption("%s is unreadable: %s" % (label, exc))
        finally:
            if descriptor is not None:
                os.close(descriptor)
        identity = lambda item: (
            item.st_dev,
            item.st_ino,
            item.st_mode,
            item.st_size,
            getattr(item, "st_mtime_ns", int(item.st_mtime * 1000000000)),
        )
        try:
            after = path.lstat()
        except OSError as exc:
            raise ArcSessionCorruption("%s changed while reading: %s" % (label, exc))
        if not (
            identity(before)
            == identity(opened_before)
            == identity(opened_after)
            == identity(after)
        ):
            raise ArcSessionCorruption("%s changed while reading" % label)
        return material

    def _candidate_epistemic_snapshot(self, session):
        from .arc_epistemic import (
            ArcEpistemicValidationError,
            seal_arc_epistemic_snapshot,
        )

        path = session.workspace / "hypotheses.json"
        try:
            hypothesis_bytes = self._stable_workspace_file(
                path, "hypothesis ledger"
            )
            payload = _strict_json_loads(hypothesis_bytes.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise ArcSessionCorruption("hypothesis ledger is unreadable: %s" % exc)
        if not isinstance(payload, dict) or set(payload) != {
            "schema_version",
            "game_id",
            "updated_through_receipt",
            "hypotheses",
        }:
            raise ArcSessionCorruption("hypothesis ledger schema or identity is invalid")
        if (
            payload.get("schema_version") != 2
            or payload.get("game_id") != session.game_id
            or payload.get("updated_through_receipt") != session.observation_receipt
            or not isinstance(payload.get("hypotheses"), list)
        ):
            raise ArcSessionCorruption("hypothesis ledger schema or identity is invalid")
        playbook_bytes = self._stable_workspace_file(
            session.workspace / "playbook.md", "ARC playbook"
        )
        try:
            playbook = playbook_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ArcSessionCorruption("ARC playbook is not UTF-8: %s" % exc)
        observations = _read_jsonl(
            session.state_dir / "observations.jsonl", "observations"
        )
        previous_snapshot = None
        if session.epistemic_snapshot_sha256:
            previous_path = session.state_dir / "epistemic" / (
                session.epistemic_snapshot_sha256 + ".json"
            )
            previous_snapshot = _read_canonical_epistemic_snapshot(
                previous_path, "prior epistemic snapshot"
            )
        if (
            previous_snapshot is not None
            and previous_snapshot["body"].get("updated_through_receipt")
            == session.observation_receipt
        ):
            previous_snapshot = self._validate_epistemic_chain(
                session, session.epistemic_snapshot_sha256, observations
            )
            previous_body = previous_snapshot["body"]
            if (
                previous_body.get("hypotheses") != payload["hypotheses"]
                or previous_body.get("playbook", {}).get("content") != playbook
            ):
                raise ArcSessionCorruption(
                    "epistemic reasoning changed without new authoritative evidence"
                )
            by_id = {
                hypothesis["id"]: hypothesis
                for hypothesis in previous_body["hypotheses"]
            }
            return {
                "snapshot": previous_snapshot,
                "hypotheses": by_id,
                "hypotheses_file_sha256": hashlib.sha256(
                    hypothesis_bytes
                ).hexdigest(),
                "playbook_sha256": hashlib.sha256(playbook_bytes).hexdigest(),
            }
        try:
            snapshot = seal_arc_epistemic_snapshot(
                game_id=session.game_id,
                hypotheses=payload["hypotheses"],
                playbook_markdown=playbook,
                authoritative_receipts=observations,
                current_receipt_id=session.observation_receipt,
                previous_snapshot=previous_snapshot,
            )
        except ArcEpistemicValidationError as exc:
            raise ArcSessionCorruption("hypothesis ledger is unproven: %s" % exc)
        by_id = {
            hypothesis["id"]: hypothesis
            for hypothesis in snapshot["body"]["hypotheses"]
        }
        return {
            "snapshot": snapshot,
            "hypotheses": by_id,
            "hypotheses_file_sha256": hashlib.sha256(hypothesis_bytes).hexdigest(),
            "playbook_sha256": hashlib.sha256(playbook_bytes).hexdigest(),
        }

    @staticmethod
    def _commit_epistemic_snapshot(session, candidate):
        from .arc_epistemic import write_arc_epistemic_snapshot

        snapshot = candidate["snapshot"]
        durable = write_arc_epistemic_snapshot(
            session.state_dir / "epistemic", snapshot
        )
        mirror_dir = session.workspace / "epistemic"
        mirror_dir.mkdir(exist_ok=True)
        mirror = mirror_dir / durable.name
        rendered = durable.read_bytes()
        if mirror.exists() and mirror.read_bytes() != rendered:
            raise ArcSessionCorruption("epistemic snapshot mirror path collision")
        if not mirror.exists():
            temporary = mirror.with_name(mirror.name + ".tmp-" + uuid.uuid4().hex)
            with temporary.open("wb") as handle:
                handle.write(rendered)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(str(temporary), str(mirror))
        return snapshot["snapshot_sha256"]

    @staticmethod
    def _commit_validated_plan(session, plan):
        plan.validate_integrity()
        path = session.state_dir / "plans" / (plan.artifact_sha256 + ".json")
        rendered = (plan.to_json() + "\n").encode("utf-8")
        if path.exists():
            if path.read_bytes() != rendered:
                raise ArcSessionCorruption("validated plan path collision")
            return path
        temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
        with temporary.open("xb") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(path))
        return path

    @staticmethod
    def _load_validated_plan(session):
        from .arc_world_model import ArcWorldModelContractError, ValidatedArcPlan

        if not session.active_plan_sha256:
            raise ArcSessionCorruption("ARC action queue has no validated plan binding")
        path = session.state_dir / "plans" / (
            session.active_plan_sha256 + ".json"
        )
        try:
            material = path.read_text(encoding="utf-8")
            plan = ValidatedArcPlan.from_json(material)
        except (OSError, UnicodeDecodeError, ArcWorldModelContractError) as exc:
            raise ArcSessionCorruption("validated plan is unreadable: %s" % exc)
        if plan.artifact_sha256 != session.active_plan_sha256:
            raise ArcSessionCorruption("validated plan identity drifted")
        if material != plan.to_json() + "\n":
            raise ArcSessionCorruption("validated plan bytes are not canonical")
        return plan

    @staticmethod
    def _executable_action_payload(action):
        if action is None:
            return None
        payload = {"action": action.name}
        if action.name == "ACTION6":
            payload.update({"x": action.x, "y": action.y})
        return payload

    def _evaluate_active_prediction(self, session, observation, action):
        from .arc_world_model import frame_sha256, observation_sha256

        if not session.active_plan_sha256:
            if session.queue:
                raise ArcSessionCorruption(
                    "ARC action queue exists without a validated plan"
                )
            return None
        plan = self._load_validated_plan(session)
        cursor = session.active_plan_cursor
        if not 0 <= cursor < len(plan.predictions):
            raise ArcSessionCorruption("validated plan cursor is outside the plan")
        prediction = plan.predictions[cursor]
        errors = []
        if self._executable_action_payload(action) != dict(prediction.action):
            errors.append("settled action does not match validated plan")
        observed_frame_sha = frame_sha256(observation.frame)
        if observed_frame_sha != prediction.result.frame_sha256:
            errors.append("complete frame differs from world-model prediction")
        if observation.state != prediction.result.outcome.state:
            errors.append(
                "state=%s expected=%s"
                % (observation.state, prediction.result.outcome.state)
            )
        if (
            observation.levels_completed
            != prediction.result.outcome.levels_completed
        ):
            errors.append(
                "levels=%d expected=%d"
                % (
                    observation.levels_completed,
                    prediction.result.outcome.levels_completed,
                )
            )
        return {
            "plan_sha256": plan.artifact_sha256,
            "world_model_sha256": session.active_world_model_sha256,
            "hypothesis_id": session.active_plan_hypothesis_id,
            "prediction_index": cursor,
            "action_receipt_id": action.receipt_id if action else None,
            "predicted_frame_sha256": prediction.result.frame_sha256,
            "observed_frame_sha256": observed_frame_sha,
            "observed_observation_sha256": observation_sha256(observation),
            "matched": not errors,
            "errors": errors,
        }

    @staticmethod
    def _observation_from_entry(entry):
        return ArcObservation(
            text="",
            state=str(entry["state"]),
            levels_completed=int(entry["levels_completed"]),
            available=tuple(entry["available"]),
            frame=tuple(tuple(row) for row in entry["frame"]),
        )

    @staticmethod
    def _validate_epistemic_chain(session, snapshot_sha, observations):
        from .arc_epistemic import (
            ArcEpistemicValidationError,
            validate_arc_epistemic_snapshot,
        )

        by_receipt = {
            item.get("receipt_sha256"): index
            for index, item in enumerate(observations)
        }
        chain = []
        seen = set()
        current_sha = snapshot_sha
        while current_sha is not None:
            if current_sha in seen or len(chain) >= 512:
                raise ArcSessionCorruption("epistemic snapshot chain is cyclic or excessive")
            seen.add(current_sha)
            path = session.state_dir / "epistemic" / (str(current_sha) + ".json")
            snapshot = _read_canonical_epistemic_snapshot(
                path, "epistemic snapshot chain"
            )
            if snapshot.get("snapshot_sha256") != current_sha:
                raise ArcSessionCorruption("epistemic snapshot path identity mismatch")
            chain.append(snapshot)
            body = snapshot.get("body")
            if not isinstance(body, dict):
                raise ArcSessionCorruption("epistemic snapshot body is invalid")
            current_sha = body.get("parent_snapshot_sha256")
        chain.reverse()
        previous = None
        for snapshot in chain:
            receipt = snapshot["body"].get("updated_through_receipt")
            if receipt not in by_receipt:
                raise ArcSessionCorruption(
                    "epistemic snapshot references non-authoritative evidence"
                )
            prefix = observations[: by_receipt[receipt] + 1]
            try:
                validate_arc_epistemic_snapshot(
                    snapshot,
                    authoritative_receipts=prefix,
                    current_receipt_id=receipt,
                    previous_snapshot=previous,
                )
            except ArcEpistemicValidationError as exc:
                raise ArcSessionCorruption(
                    "epistemic snapshot chain is invalid: %s" % exc
                )
            previous = snapshot
        if not chain or chain[-1].get("snapshot_sha256") != snapshot_sha:
            raise ArcSessionCorruption("active epistemic snapshot chain is incomplete")
        return chain[-1]

    def _active_plan_context(self, session):
        from .arc_plan_contract import (
            WorldModelReference,
            read_bound_world_model_source,
        )
        from .arc_world_model import observation_sha256

        plan = self._load_validated_plan(session)
        required = (
            session.active_plan_source_receipt,
            session.active_plan_hypothesis_id,
            session.active_epistemic_snapshot_sha256,
            session.active_world_model_path,
            session.active_world_model_sha256,
            session.active_hypotheses_file_sha256,
            session.active_playbook_sha256,
        )
        if any(not isinstance(value, str) or not value for value in required):
            raise ArcSessionCorruption("validated plan binding is incomplete")
        if type(session.active_plan_source_step) is not int:
            raise ArcSessionCorruption("validated plan source step is invalid")

        hypothesis_bytes = self._stable_workspace_file(
            session.workspace / "hypotheses.json", "hypothesis ledger"
        )
        playbook_bytes = self._stable_workspace_file(
            session.workspace / "playbook.md", "ARC playbook"
        )
        if (
            hashlib.sha256(hypothesis_bytes).hexdigest()
            != session.active_hypotheses_file_sha256
        ):
            raise ArcSessionCorruption(
                "hypothesis ledger changed while a plan was active"
            )
        if (
            hashlib.sha256(playbook_bytes).hexdigest()
            != session.active_playbook_sha256
        ):
            raise ArcSessionCorruption("playbook changed while a plan was active")

        reference = WorldModelReference(
            session.active_world_model_path,
            session.active_world_model_sha256,
        )
        source_path, source_bytes = read_bound_world_model_source(
            session.workspace, reference
        )
        observations = _read_jsonl(
            session.state_dir / "observations.jsonl", "observations"
        )
        snapshot = self._validate_epistemic_chain(
            session, session.active_epistemic_snapshot_sha256, observations
        )
        body = snapshot["body"]
        if body.get("updated_through_receipt") != session.active_plan_source_receipt:
            raise ArcSessionCorruption("active epistemic evidence binding drifted")
        hypotheses = {
            item.get("id"): item
            for item in body.get("hypotheses", [])
            if isinstance(item, dict)
        }
        selected = hypotheses.get(session.active_plan_hypothesis_id)
        if not selected or selected.get("state") == "falsified":
            raise ArcSessionCorruption("active plan hypothesis is absent or falsified")
        source_step = session.active_plan_source_step
        if not 0 <= source_step < len(observations):
            raise ArcSessionCorruption("active plan source step is outside evidence")
        if observations[source_step].get("receipt_sha256") != session.active_plan_source_receipt:
            raise ArcSessionCorruption("active plan source receipt is not authoritative")
        history = tuple(
            self._observation_from_entry(item) for item in observations[source_step:]
        )
        settled = len(history) - 1
        if settled != session.active_plan_cursor:
            raise ArcSessionCorruption("active plan cursor disagrees with evidence history")
        if observation_sha256(history[0]) != plan.initial_observation_sha256:
            raise ArcSessionCorruption("active plan initial observation drifted")
        executed = tuple(
            PlannedArcAction(
                prediction.action["action"],
                prediction.action.get("x"),
                prediction.action.get("y"),
            )
            for prediction in plan.predictions[:settled]
        )
        return {
            "plan": plan,
            "source_path": source_path,
            "source_bytes": source_bytes,
            "history": history,
            "executed": executed,
            "selected_hypothesis": selected,
        }

    def _validate_active_action_release(self, session, action):
        from .arc_world_model_runtime import validate_next_action_isolated

        context = self._active_plan_context(session)
        released = validate_next_action_isolated(
            context["source_bytes"],
            session.active_world_model_sha256,
            context["plan"],
            context["history"],
            context["executed"],
            proposed_action=action,
            workspace=session.workspace,
            authoritative_state_dir=session.state_dir,
            require_macos_sandbox=True,
        )
        if self._executable_action_payload(
            released.action
        ) != self._executable_action_payload(action):
            raise ArcSessionCorruption(
                "isolated world model released a different action"
            )
        return released

    @staticmethod
    def _escalation_directive(session):
        if not session.escalation_tier:
            return ""
        actions = max(0, session.step - session.level_started_step)
        directive = (
            "\n\n[ESCALATION] This directive is binding until the level changes. "
            "You have spent %d actions and issued %d voluntary RESETs on this "
            "level. Stop open-ended live probing. In playbook.md, inventory both "
            "unexplained transitions and reachable regions or states never "
            "visited. Promote only log-checked rules into a bounded executable "
            "step(state, action) simulator under scratch/, retrodict every recorded "
            "transition for this level, and search it for a shortest route. Emit "
            "only searched actions with computed expectations, except for one "
            "discriminating probe when the log cannot choose between simulators."
            % (actions, session.self_resets)
        )
        if session.escalation_tier >= 2:
            directive += (
                "\n[ESCALATION 2] The first simulator/search pass did not finish "
                "the level. Treat a rule as wrong or territory as unvisited. "
                "Enumerate the reachable-state frontier, prioritize unseen board "
                "states, and re-derive any rule that claims the goal is unreachable."
            )
        return directive

    def accept_model_response(
        self,
        session,
        text,
        thread_id=None,
        context_tokens=0,
        cached_input_tokens=0,
    ):
        with session.lock:
            self.bind(session, thread_id)
            input_tokens = max(0, int(context_tokens or 0))
            cached_tokens = max(0, int(cached_input_tokens or 0))
            # Codex reports turn-wide totals across its internal model calls.
            # Only uncached growth is useful for deciding when to rotate context.
            session.context_tokens += max(0, input_tokens - cached_tokens)
            available = (
                session.last_observation.available if session.last_observation else ()
            )
            try:
                from .arc_plan_contract import (
                    parse_arc_plan_contract,
                    read_bound_world_model_source,
                )
                from .arc_world_model_runtime import (
                    build_validated_plan_isolated,
                )
                from .arc_world_model import validate_next_action_from_plan

                if session.last_observation is None or not session.observation_receipt:
                    raise ArcSessionCorruption(
                        "model plan has no authoritative source observation"
                    )
                contract = parse_arc_plan_contract(str(text), available)
                actions = [
                    PlannedArcAction(item.action, item.x, item.y)
                    for item in contract.plan
                ]
                epistemic = self._candidate_epistemic_snapshot(session)
                selected = epistemic["hypotheses"].get(contract.hypothesis_id)
                if selected is None or selected.get("state") == "falsified":
                    raise ArcSessionCorruption(
                        "selected hypothesis is absent or falsified"
                    )
                selected_action = selected["discriminating_prediction"]["action"]
                if (
                    contract.mode == "probe"
                    and self._executable_action_payload(actions[0]) != selected_action
                ):
                    raise ArcSessionCorruption(
                        "probe action does not match the selected hypothesis prediction"
                    )
                if (
                    contract.mode == "validated_plan"
                    and selected.get("state") != "confirmed"
                ):
                    raise ArcSessionCorruption(
                        "multi-step execution requires a receipt-confirmed hypothesis"
                    )
                _source_path, source_bytes = read_bound_world_model_source(
                    session.workspace, contract.world_model
                )
                require_sandbox = True
                plan = build_validated_plan_isolated(
                    source_bytes,
                    contract.world_model.sha256,
                    session.last_observation,
                    actions,
                    workspace=session.workspace,
                    authoritative_state_dir=session.state_dir,
                    require_macos_sandbox=require_sandbox,
                )
                validate_next_action_from_plan(
                    plan,
                    [session.last_observation],
                    [],
                    proposed_action=actions[0],
                )
                initial_outcome = plan.initial.outcome
                for prediction in plan.predictions[:-1]:
                    outcome = prediction.result.outcome
                    if (
                        outcome.state != initial_outcome.state
                        or outcome.levels_completed
                        != initial_outcome.levels_completed
                    ):
                        raise ArcSessionCorruption(
                            "validated plan crosses an outcome boundary before its final action"
                        )
                _current_source_path, current_source_bytes = (
                    read_bound_world_model_source(
                        session.workspace, contract.world_model
                    )
                )
                if current_source_bytes != source_bytes:
                    raise ArcSessionCorruption(
                        "world-model source changed during isolated validation"
                    )
                current_hypotheses = self._stable_workspace_file(
                    session.workspace / "hypotheses.json", "hypothesis ledger"
                )
                current_playbook = self._stable_workspace_file(
                    session.workspace / "playbook.md", "ARC playbook"
                )
                if (
                    hashlib.sha256(current_hypotheses).hexdigest()
                    != epistemic["hypotheses_file_sha256"]
                    or hashlib.sha256(current_playbook).hexdigest()
                    != epistemic["playbook_sha256"]
                ):
                    raise ArcSessionCorruption(
                        "ARC reasoning evidence changed during isolated validation"
                    )
                self._commit_validated_plan(session, plan)
                hypothesis_sha = self._commit_epistemic_snapshot(
                    session, epistemic
                )
            except (ArcSessionCorruption, OSError, ValueError, RuntimeError) as exc:
                self._clear_active_plan(session)
                session.trigger = "model plan rejected: %s" % exc
                self._persist(session)
                raise ArcPlanRejected(session.trigger) from exc

            plan_id = plan.artifact_sha256
            identified_actions = []
            for index, action in enumerate(actions):
                action_id = _digest(
                    {
                        "kind": "arc-action-v3",
                        "plan_id": plan_id,
                        "index": index,
                        "source_observation_receipt": session.observation_receipt,
                        "epistemic_snapshot_sha256": hypothesis_sha,
                        "world_model_sha256": contract.world_model.sha256,
                        "action": self._executable_action_payload(action),
                    }
                )
                identified_actions.append(
                    PlannedArcAction(
                        action.name,
                        action.x,
                        action.y,
                        (),
                        None,
                        action_id,
                    )
                )
            actions = identified_actions
            created_at = time.time()
            hypothesis_entry = _ledger_entry(
                {
                    "session_id": session.id,
                    "game_id": session.game_id,
                    "plan_id": plan_id,
                    "request_id": session.active_request_id,
                    "evidence_receipt": session.observation_receipt,
                    "epistemic_snapshot_sha256": hypothesis_sha,
                    "selected_hypothesis_id": contract.hypothesis_id,
                    "world_model_path": contract.world_model.path,
                    "world_model_sha256": contract.world_model.sha256,
                    "model_output_sha256": hashlib.sha256(
                        str(text).encode("utf-8")
                    ).hexdigest(),
                    "reasoning": contract.reasoning,
                    "planned_action_receipts": [
                        action.receipt_id for action in actions
                    ],
                    "full_frame_prediction_count": len(plan.predictions),
                    "created_at": created_at,
                },
                session.hypothesis_ledger_hash,
            )
            first, remaining = actions[0], actions[1:]
            session.queue = deque(remaining)
            session.active_plan_sha256 = plan_id
            session.active_plan_source_receipt = session.observation_receipt
            session.active_plan_source_step = session.step - 1
            session.active_plan_cursor = 0
            session.active_plan_hypothesis_id = contract.hypothesis_id
            session.active_epistemic_snapshot_sha256 = hypothesis_sha
            session.active_world_model_path = contract.world_model.path
            session.active_world_model_sha256 = contract.world_model.sha256
            session.active_hypotheses_file_sha256 = epistemic[
                "hypotheses_file_sha256"
            ]
            session.active_playbook_sha256 = epistemic["playbook_sha256"]
            try:
                self._validate_active_action_release(session, first)
            except (ArcSessionCorruption, OSError, ValueError, RuntimeError) as exc:
                self._clear_active_plan(session)
                session.trigger = "model plan rejected before first action: %s" % exc
                self._persist(session)
                raise ArcPlanRejected(session.trigger) from exc
            session.trigger = "model supplied a sealed full-frame plan"
            self._append_ledger(
                session, "hypothesis_receipts.jsonl", hypothesis_entry
            )
            session.hypothesis_ledger_hash = hypothesis_entry["receipt_sha256"]
            session.epistemic_snapshot_sha256 = hypothesis_sha
            try:
                with (session.workspace / "log.txt").open(
                    "a", encoding="utf-8"
                ) as handle:
                    handle.write(
                        "[PLAN] %s actions; sealed=%s; hypothesis=%s\n"
                        "[END PLAN]\n\n"
                        % (len(actions), plan_id, contract.hypothesis_id)
                    )
            except OSError:
                pass
            response = self._emit(
                session,
                first,
                contract.reasoning or "executing a verified world-model action",
            )
            self._persist(session)
            return response

    def _emit(self, session, action, memory):
        if not action.receipt_id or not session.active_plan_sha256:
            raise ArcSessionCorruption(
                "refusing to emit an action without a validated plan receipt"
            )
        clean_memory = _safe_memory(memory)
        response = self._render_emitted(action, clean_memory)
        action = self._ensure_action_receipt(
            session,
            action,
            source="validated-plan",
            response_text=response,
        )
        session.pending_action = action
        session.last_emitted_action = action
        session.last_response_text = response
        return response
