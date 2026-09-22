"""Fail-closed parsing and source binding for live ARC plans.

This module deliberately does not import or execute a proposed world model.  It
only validates the model response's final contract object and binds the named
source file to the exact bytes covered by its SHA-256 digest.
"""

import hashlib
import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Optional, Tuple


_ACTIONS_MARKER = "[ACTIONS]"
_ACTION_NAMES = frozenset(
    ("RESET", "ACTION1", "ACTION2", "ACTION3", "ACTION4", "ACTION5", "ACTION6", "ACTION7")
)
_TOP_LEVEL_KEYS = frozenset(
    ("mode", "hypothesis_id", "world_model", "plan", "reasoning")
)
_WORLD_MODEL_KEYS = frozenset(("path", "sha256"))
_SHA256_CHARS = frozenset("0123456789abcdef")
_MAX_WORLD_MODEL_SOURCE_BYTES = 512 * 1024
_SOURCE_READ_CHUNK_BYTES = 64 * 1024


class ArcPlanContractError(ValueError):
    """A live ARC response or its bound source failed the strict contract."""

    def __init__(self, code: str, message: str):
        super().__init__("%s: %s" % (code, message))
        self.code = code


@dataclass(frozen=True)
class WorldModelReference:
    """Content-addressed reference to an allowed workspace source file."""

    path: str
    sha256: str

    def as_dict(self) -> Dict[str, str]:
        return {"path": self.path, "sha256": self.sha256}


@dataclass(frozen=True)
class ArcPlanAction:
    """One canonical ARC action payload."""

    action: str
    x: Optional[int] = None
    y: Optional[int] = None

    @property
    def canonical_payload(self) -> Tuple[Tuple[str, object], ...]:
        if self.action == "ACTION6":
            return (("action", self.action), ("x", self.x), ("y", self.y))
        return (("action", self.action),)

    def as_dict(self) -> Dict[str, object]:
        return dict(self.canonical_payload)


@dataclass(frozen=True)
class ArcPlanContract:
    """Validated, immutable output contract for one live ARC decision."""

    mode: str
    hypothesis_id: str
    world_model: WorldModelReference
    plan: Tuple[ArcPlanAction, ...]
    reasoning: str

    def as_dict(self) -> Dict[str, object]:
        return {
            "mode": self.mode,
            "hypothesis_id": self.hypothesis_id,
            "world_model": self.world_model.as_dict(),
            "plan": [action.as_dict() for action in self.plan],
            "reasoning": self.reasoning,
        }


def _reject_constant(value: str) -> object:
    raise ArcPlanContractError(
        "invalid_json", "non-finite JSON number %s is not permitted" % value
    )


def _strict_object(pairs: Iterable[Tuple[str, object]]) -> Dict[str, object]:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ArcPlanContractError(
                "duplicate_key", "duplicate JSON object key %r" % key
            )
        value[key] = item
    return value


def _exact_keys(value: object, expected: frozenset, label: str) -> Dict[str, object]:
    if not isinstance(value, dict):
        raise ArcPlanContractError("invalid_%s" % label, "%s must be an object" % label)
    actual = frozenset(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ArcPlanContractError(
            "invalid_%s_keys" % label,
            "%s keys must be exact; missing=%r extra=%r" % (label, missing, extra),
        )
    return value


def _validate_reference_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise ArcPlanContractError(
            "invalid_world_model_path", "world_model.path must be a normalized relative POSIX path"
        )
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in ("", ".", "..") for part in path.parts):
        raise ArcPlanContractError(
            "invalid_world_model_path", "world_model.path must be a normalized relative POSIX path"
        )
    if value != "world_model.py" and not (len(path.parts) > 1 and path.parts[0] == "scratch"):
        raise ArcPlanContractError(
            "invalid_world_model_path",
            "world_model.path must be world_model.py or a descendant of scratch/",
        )
    return value


def _validate_sha256(value: object) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in _SHA256_CHARS for character in value)
    ):
        raise ArcPlanContractError(
            "invalid_world_model_sha256",
            "world_model.sha256 must be a lowercase hexadecimal SHA-256",
        )
    return value


def _parse_action(
    value: object, available: frozenset, require_current_availability: bool
) -> ArcPlanAction:
    if not isinstance(value, dict):
        raise ArcPlanContractError("invalid_action", "each plan item must be an object")
    name = value.get("action")
    expected_keys = frozenset(("action", "x", "y")) if name == "ACTION6" else frozenset(("action",))
    _exact_keys(value, expected_keys, "action")
    if not isinstance(name, str) or name not in _ACTION_NAMES:
        raise ArcPlanContractError("invalid_action_name", "action name is not canonical")
    if require_current_availability and name not in available:
        raise ArcPlanContractError(
            "action_unavailable", "action %s is not currently available" % name
        )
    if name != "ACTION6":
        return ArcPlanAction(name)
    x = value["x"]
    y = value["y"]
    if type(x) is not int or type(y) is not int or not (0 <= x <= 63 and 0 <= y <= 63):
        raise ArcPlanContractError(
            "invalid_action_coordinates", "ACTION6 requires integer x/y in 0..63"
        )
    return ArcPlanAction(name, x, y)


def parse_arc_plan_contract(text: str, available: Iterable[str]) -> ArcPlanContract:
    """Parse the final ``[ACTIONS]`` object without fallback or coercion.

    Any ambiguity, unknown key, duplicate key, unavailable action, or trailing
    non-whitespace material rejects the entire response.
    """

    if not isinstance(text, str):
        raise ArcPlanContractError("invalid_response", "model response must be text")
    marker_at = text.rfind(_ACTIONS_MARKER)
    if marker_at < 0:
        raise ArcPlanContractError("missing_actions", "response has no final [ACTIONS] block")
    fragment = text[marker_at + len(_ACTIONS_MARKER) :]
    stripped = fragment.lstrip()
    if not stripped.startswith("{"):
        raise ArcPlanContractError(
            "invalid_actions", "final [ACTIONS] marker must be followed only by its JSON object"
        )
    decoder = json.JSONDecoder(
        object_pairs_hook=_strict_object,
        parse_constant=_reject_constant,
    )
    try:
        payload, end_at = decoder.raw_decode(stripped)
    except ArcPlanContractError:
        raise
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ArcPlanContractError("invalid_json", "invalid [ACTIONS] JSON: %s" % exc)
    if stripped[end_at:].strip():
        raise ArcPlanContractError(
            "trailing_material", "final [ACTIONS] JSON has trailing non-whitespace material"
        )

    payload = _exact_keys(payload, _TOP_LEVEL_KEYS, "contract")
    mode = payload["mode"]
    if mode not in ("probe", "validated_plan"):
        raise ArcPlanContractError(
            "invalid_mode", "mode must be probe or validated_plan"
        )
    hypothesis_id = payload["hypothesis_id"]
    if not isinstance(hypothesis_id, str) or not hypothesis_id.strip():
        raise ArcPlanContractError(
            "invalid_hypothesis_id", "hypothesis_id must be a nonempty string"
        )
    reasoning = payload["reasoning"]
    if not isinstance(reasoning, str):
        raise ArcPlanContractError("invalid_reasoning", "reasoning must be a string")

    world_model = _exact_keys(payload["world_model"], _WORLD_MODEL_KEYS, "world_model")
    reference = WorldModelReference(
        path=_validate_reference_path(world_model["path"]),
        sha256=_validate_sha256(world_model["sha256"]),
    )

    plan = payload["plan"]
    if not isinstance(plan, list):
        raise ArcPlanContractError("invalid_plan", "plan must be an array")
    required_count = 1 if mode == "probe" else None
    if required_count is not None and len(plan) != required_count:
        raise ArcPlanContractError("invalid_plan_length", "probe mode requires exactly one action")
    if mode == "validated_plan" and not 1 <= len(plan) <= 128:
        raise ArcPlanContractError(
            "invalid_plan_length", "validated_plan mode requires 1-128 actions"
        )

    try:
        available_names = frozenset(available)
    except TypeError as exc:
        raise ArcPlanContractError("invalid_available", "available actions are invalid: %s" % exc)
    actions = tuple(
        _parse_action(item, available_names, index == 0)
        for index, item in enumerate(plan)
    )
    return ArcPlanContract(mode, hypothesis_id, reference, actions, reasoning)


def _stable_stat_identity(value: os.stat_result) -> Tuple[int, ...]:
    return (
        int(value.st_dev),
        int(value.st_ino),
        int(value.st_mode),
        int(value.st_size),
        int(getattr(value, "st_mtime_ns", int(value.st_mtime * 1_000_000_000))),
        int(getattr(value, "st_ctime_ns", int(value.st_ctime * 1_000_000_000))),
    )


def _check_no_symlink_components(root: Path, relative: PurePosixPath) -> os.stat_result:
    current = root
    result = None
    try:
        for index, part in enumerate(relative.parts):
            current = current / part
            result = current.lstat()
            if stat.S_ISLNK(result.st_mode):
                raise ArcPlanContractError(
                    "world_model_symlink", "world model path contains a symbolic link"
                )
            if index < len(relative.parts) - 1 and not stat.S_ISDIR(result.st_mode):
                raise ArcPlanContractError(
                    "invalid_world_model_file", "world model parent is not a directory"
                )
    except ArcPlanContractError:
        raise
    except OSError as exc:
        raise ArcPlanContractError(
            "world_model_unreadable", "cannot resolve world model source: %s" % exc
        )
    if result is None or not stat.S_ISREG(result.st_mode):
        raise ArcPlanContractError(
            "invalid_world_model_file", "world model source must be a regular file"
        )
    return result


def _inside(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
    except ValueError:
        return False
    return True


def _check_source_size(size: int) -> None:
    if size > _MAX_WORLD_MODEL_SOURCE_BYTES:
        raise ArcPlanContractError(
            "world_model_too_large",
            "world model source exceeds the %d-byte limit"
            % _MAX_WORLD_MODEL_SOURCE_BYTES,
        )


def read_bound_world_model_source(
    workspace: object, reference: WorldModelReference
) -> Tuple[Path, bytes]:
    """Stable-read and digest-check a referenced world-model source file.

    The function performs no import, compilation, or execution.  Symbolic links
    and non-regular files are rejected before bytes can be accepted.
    """

    if not isinstance(reference, WorldModelReference):
        raise ArcPlanContractError(
            "invalid_world_model_reference", "reference must be a WorldModelReference"
        )
    relative = PurePosixPath(_validate_reference_path(reference.path))
    _validate_sha256(reference.sha256)
    try:
        root = Path(workspace).resolve(strict=True)
    except (OSError, RuntimeError, TypeError, ValueError) as exc:
        raise ArcPlanContractError(
            "invalid_workspace", "workspace cannot be resolved: %s" % exc
        )
    if not root.is_dir():
        raise ArcPlanContractError("invalid_workspace", "workspace must be a directory")

    candidate = root.joinpath(*relative.parts)
    path_stat_before = _check_no_symlink_components(root, relative)
    _check_source_size(path_stat_before.st_size)
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ArcPlanContractError(
            "world_model_unreadable", "world model path cannot be resolved: %s" % exc
        )
    if not _inside(root, resolved):
        raise ArcPlanContractError(
            "world_model_escape", "world model path resolves outside the workspace"
        )

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = None
    try:
        descriptor = os.open(str(candidate), flags)
        opened_before = os.fstat(descriptor)
        if not stat.S_ISREG(opened_before.st_mode):
            raise ArcPlanContractError(
                "invalid_world_model_file", "world model source must be a regular file"
            )
        _check_source_size(opened_before.st_size)
        if _stable_stat_identity(opened_before) != _stable_stat_identity(
            path_stat_before
        ):
            raise ArcPlanContractError(
                "world_model_changed", "world model path changed before it was opened"
            )
        chunks = []
        source_size = 0
        while True:
            remaining = _MAX_WORLD_MODEL_SOURCE_BYTES - source_size
            chunk = os.read(
                descriptor,
                min(_SOURCE_READ_CHUNK_BYTES, remaining + 1),
            )
            if not chunk:
                break
            if len(chunk) > remaining:
                raise ArcPlanContractError(
                    "world_model_too_large",
                    "world model source exceeds the %d-byte limit"
                    % _MAX_WORLD_MODEL_SOURCE_BYTES,
                )
            chunks.append(chunk)
            source_size += len(chunk)
        opened_after = os.fstat(descriptor)
    except ArcPlanContractError:
        raise
    except OSError as exc:
        raise ArcPlanContractError(
            "world_model_unreadable", "world model source cannot be read: %s" % exc
        )
    finally:
        if descriptor is not None:
            os.close(descriptor)

    if _stable_stat_identity(opened_before) != _stable_stat_identity(opened_after):
        raise ArcPlanContractError(
            "world_model_changed", "world model source changed while it was read"
        )
    path_stat_after = _check_no_symlink_components(root, relative)
    if _stable_stat_identity(opened_after) != _stable_stat_identity(path_stat_after):
        raise ArcPlanContractError(
            "world_model_changed", "world model path changed while it was read"
        )
    try:
        resolved_after = candidate.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ArcPlanContractError(
            "world_model_changed", "world model path changed after reading: %s" % exc
        )
    if resolved_after != resolved or not _inside(root, resolved_after):
        raise ArcPlanContractError(
            "world_model_changed", "world model path changed while it was read"
        )

    source = b"".join(chunks)
    if len(source) != opened_after.st_size:
        raise ArcPlanContractError(
            "world_model_changed", "world model size changed while it was read"
        )
    digest = hashlib.sha256(source).hexdigest()
    if digest != reference.sha256:
        raise ArcPlanContractError(
            "world_model_hash_mismatch",
            "world model SHA-256 mismatch: expected %s, got %s"
            % (reference.sha256, digest),
        )
    return resolved, source
