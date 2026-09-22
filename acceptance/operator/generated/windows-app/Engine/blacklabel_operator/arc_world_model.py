"""Fail-closed executable world-model verification for ARC-AGI-3 plans.

The planner is allowed to propose actions.  This module is the separate gate that
proves an executable model predicts those actions deterministically and that each
settled observation matches the *entire* predicted frame and outcome before the
next action is released.
"""

import hashlib
import inspect
import json
import marshal
import math
import re
from dataclasses import dataclass
from typing import Any, Dict, Mapping, Optional, Protocol, Sequence, Tuple, runtime_checkable

from .arc_planner import ArcObservation, PlannedArcAction


ARC_VALIDATED_PLAN_SCHEMA = "black-label-operator/arc-validated-plan-v1"
ARC_ACTION_NAMES = frozenset(
    {
        "RESET",
        "ACTION1",
        "ACTION2",
        "ACTION3",
        "ACTION4",
        "ACTION5",
        "ACTION6",
        "ACTION7",
    }
)
_CANONICAL_ARC_OUTCOMES = {
    "GAME_OVER": (True, False),
    "NOT_FINISHED": (False, None),
    "WIN": (True, True),
}
_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ArcWorldModelContractError(ValueError):
    """The executable model or validated artifact violates its contract."""

    def __init__(self, code: str, message: str):
        super().__init__("%s: %s" % (code, message))
        self.code = code


class ArcPlanInvalidated(RuntimeError):
    """A previously validated plan is no longer safe to execute."""

    def __init__(self, code: str, message: str):
        super().__init__("%s: %s" % (code, message))
        self.code = code


class ArcPlanComplete(RuntimeError):
    """All actions in a validated plan have already settled."""


@dataclass(frozen=True)
class ArcWorldOutcome:
    """Observable outcome plus the model's terminality assertion."""

    state: str
    levels_completed: int
    terminal: bool = False
    success: Optional[bool] = None

    def __post_init__(self) -> None:
        if not isinstance(self.state, str) or not self.state.strip():
            raise ArcWorldModelContractError(
                "invalid_outcome", "outcome state must be a non-empty string"
            )
        if type(self.levels_completed) is not int or self.levels_completed < 0:
            raise ArcWorldModelContractError(
                "invalid_outcome",
                "levels_completed must be a non-negative integer",
            )
        if type(self.terminal) is not bool:
            raise ArcWorldModelContractError(
                "invalid_outcome", "terminal must be a boolean"
            )
        if self.success is not None and type(self.success) is not bool:
            raise ArcWorldModelContractError(
                "invalid_outcome", "success must be null or a boolean"
            )
        if self.success is not None and not self.terminal:
            raise ArcWorldModelContractError(
                "invalid_outcome", "a non-terminal outcome cannot declare success"
            )
        expected = _CANONICAL_ARC_OUTCOMES.get(self.state.upper())
        if expected is not None and (self.terminal, self.success) != expected:
            raise ArcWorldModelContractError(
                "invalid_outcome",
                "terminal and success disagree with canonical ARC state %s"
                % self.state,
            )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "levels_completed": self.levels_completed,
            "state": self.state,
            "success": self.success,
            "terminal": self.terminal,
        }

    @classmethod
    def from_dict(cls, value: object) -> "ArcWorldOutcome":
        payload = _strict_mapping(
            value,
            {"levels_completed", "state", "success", "terminal"},
            "outcome",
        )
        return cls(
            state=payload["state"],
            levels_completed=payload["levels_completed"],
            terminal=payload["terminal"],
            success=payload["success"],
        )


@runtime_checkable
class ArcExecutableWorldModel(Protocol):
    """Canonical interface required of an executable ARC world model.

    ``model_manifest`` must include every behavior-affecting configuration
    value. ``canonical_state`` must return JSON-compatible state with string
    mapping keys. The other four operations must be deterministic.
    """

    model_id: str
    model_revision: str

    def model_manifest(self) -> Mapping[str, Any]:
        ...

    def canonical_state(self, state: object) -> object:
        ...

    def init(self, observation: ArcObservation) -> object:
        ...

    def transition(self, state: object, action: PlannedArcAction) -> object:
        ...

    def render(self, state: object) -> Sequence[Sequence[int]]:
        ...

    def outcome(self, state: object) -> ArcWorldOutcome:
        ...


@dataclass(frozen=True)
class ArcModelIdentity:
    model_id: str
    model_revision: str
    manifest_sha256: str
    implementation_sha256: str
    fingerprint_sha256: str

    def as_dict(self) -> Dict[str, str]:
        return {
            "fingerprint_sha256": self.fingerprint_sha256,
            "implementation_sha256": self.implementation_sha256,
            "manifest_sha256": self.manifest_sha256,
            "model_id": self.model_id,
            "model_revision": self.model_revision,
        }

    @classmethod
    def from_dict(cls, value: object) -> "ArcModelIdentity":
        payload = _strict_mapping(
            value,
            {
                "fingerprint_sha256",
                "implementation_sha256",
                "manifest_sha256",
                "model_id",
                "model_revision",
            },
            "model identity",
        )
        identity = cls(
            model_id=payload["model_id"],
            model_revision=payload["model_revision"],
            manifest_sha256=payload["manifest_sha256"],
            implementation_sha256=payload["implementation_sha256"],
            fingerprint_sha256=payload["fingerprint_sha256"],
        )
        identity.validate()
        return identity

    def validate(self) -> None:
        if not isinstance(self.model_id, str) or not self.model_id.strip():
            raise ArcWorldModelContractError(
                "invalid_model_identity", "model_id must be a non-empty string"
            )
        if not isinstance(self.model_revision, str) or not self.model_revision.strip():
            raise ArcWorldModelContractError(
                "invalid_model_identity",
                "model_revision must be a non-empty string",
            )
        for label, value in (
            ("manifest_sha256", self.manifest_sha256),
            ("implementation_sha256", self.implementation_sha256),
            ("fingerprint_sha256", self.fingerprint_sha256),
        ):
            _validate_sha256(value, label)


@dataclass(frozen=True)
class ArcStateSnapshot:
    state_sha256: str
    frame_sha256: str
    frame_height: int
    frame_width: int
    outcome: ArcWorldOutcome

    def as_dict(self) -> Dict[str, Any]:
        return {
            "frame_height": self.frame_height,
            "frame_sha256": self.frame_sha256,
            "frame_width": self.frame_width,
            "outcome": self.outcome.as_dict(),
            "state_sha256": self.state_sha256,
        }

    @classmethod
    def from_dict(cls, value: object) -> "ArcStateSnapshot":
        payload = _strict_mapping(
            value,
            {
                "frame_height",
                "frame_sha256",
                "frame_width",
                "outcome",
                "state_sha256",
            },
            "state snapshot",
        )
        snapshot = cls(
            state_sha256=payload["state_sha256"],
            frame_sha256=payload["frame_sha256"],
            frame_height=payload["frame_height"],
            frame_width=payload["frame_width"],
            outcome=ArcWorldOutcome.from_dict(payload["outcome"]),
        )
        snapshot.validate()
        return snapshot

    def validate(self) -> None:
        _validate_sha256(self.state_sha256, "state_sha256")
        _validate_sha256(self.frame_sha256, "frame_sha256")
        if type(self.frame_height) is not int or self.frame_height <= 0:
            raise ArcWorldModelContractError(
                "invalid_frame_shape", "frame_height must be positive"
            )
        if type(self.frame_width) is not int or self.frame_width <= 0:
            raise ArcWorldModelContractError(
                "invalid_frame_shape", "frame_width must be positive"
            )


@dataclass(frozen=True)
class ArcStepPrediction:
    index: int
    action: Mapping[str, Any]
    source_state_sha256: str
    result: ArcStateSnapshot

    def as_dict(self) -> Dict[str, Any]:
        return {
            "action": dict(self.action),
            "index": self.index,
            "result": self.result.as_dict(),
            "source_state_sha256": self.source_state_sha256,
        }

    @classmethod
    def from_dict(cls, value: object) -> "ArcStepPrediction":
        payload = _strict_mapping(
            value,
            {"action", "index", "result", "source_state_sha256"},
            "step prediction",
        )
        prediction = cls(
            index=payload["index"],
            action=_canonical_action_payload(payload["action"]),
            source_state_sha256=payload["source_state_sha256"],
            result=ArcStateSnapshot.from_dict(payload["result"]),
        )
        prediction.validate()
        return prediction

    def validate(self) -> None:
        if type(self.index) is not int or self.index <= 0:
            raise ArcWorldModelContractError(
                "invalid_step_index", "prediction index must be positive"
            )
        _canonical_action_payload(self.action)
        _validate_sha256(self.source_state_sha256, "source_state_sha256")
        self.result.validate()


@dataclass(frozen=True)
class ValidatedArcPlan:
    """Hash-bound, deterministic predictions for one ARC action plan."""

    model: ArcModelIdentity
    initial_observation_sha256: str
    initial: ArcStateSnapshot
    predictions: Tuple[ArcStepPrediction, ...]
    artifact_sha256: str
    schema: str = ARC_VALIDATED_PLAN_SCHEMA

    def unsigned_dict(self) -> Dict[str, Any]:
        return {
            "initial": self.initial.as_dict(),
            "initial_observation_sha256": self.initial_observation_sha256,
            "model": self.model.as_dict(),
            "predictions": [item.as_dict() for item in self.predictions],
            "schema": self.schema,
        }

    def as_dict(self) -> Dict[str, Any]:
        payload = self.unsigned_dict()
        payload["artifact_sha256"] = self.artifact_sha256
        return payload

    def to_json(self) -> str:
        return json.dumps(
            self.as_dict(),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )

    @classmethod
    def from_dict(cls, value: object) -> "ValidatedArcPlan":
        payload = _strict_mapping(
            value,
            {
                "artifact_sha256",
                "initial",
                "initial_observation_sha256",
                "model",
                "predictions",
                "schema",
            },
            "validated plan",
        )
        items = payload["predictions"]
        if not isinstance(items, list):
            raise ArcWorldModelContractError(
                "invalid_plan", "predictions must be a list"
            )
        plan = cls(
            model=ArcModelIdentity.from_dict(payload["model"]),
            initial_observation_sha256=payload["initial_observation_sha256"],
            initial=ArcStateSnapshot.from_dict(payload["initial"]),
            predictions=tuple(ArcStepPrediction.from_dict(item) for item in items),
            artifact_sha256=payload["artifact_sha256"],
            schema=payload["schema"],
        )
        plan.validate_integrity()
        return plan

    @classmethod
    def from_json(cls, value: str) -> "ValidatedArcPlan":
        try:
            payload = json.loads(
                value,
                object_pairs_hook=_reject_duplicate_json_pairs,
                parse_constant=_reject_nonfinite_json_constant,
            )
        except (TypeError, json.JSONDecodeError, ValueError) as exc:
            raise ArcWorldModelContractError(
                "invalid_plan_json", "validated plan JSON is invalid: %s" % exc
            )
        return cls.from_dict(payload)

    def validate_integrity(self) -> None:
        if self.schema != ARC_VALIDATED_PLAN_SCHEMA:
            raise ArcWorldModelContractError(
                "unsupported_plan_schema", "validated plan schema is unsupported"
            )
        self.model.validate()
        _validate_sha256(
            self.initial_observation_sha256, "initial_observation_sha256"
        )
        self.initial.validate()
        if not 1 <= len(self.predictions) <= 128:
            raise ArcWorldModelContractError(
                "invalid_plan", "a validated plan must contain 1-128 predictions"
            )
        expected_source = self.initial.state_sha256
        for offset, prediction in enumerate(self.predictions, 1):
            prediction.validate()
            if prediction.index != offset:
                raise ArcWorldModelContractError(
                    "invalid_step_index", "prediction indices are not contiguous"
                )
            if prediction.source_state_sha256 != expected_source:
                raise ArcWorldModelContractError(
                    "broken_state_chain", "prediction state hashes do not chain"
                )
            if prediction.result.outcome.terminal and offset != len(self.predictions):
                raise ArcWorldModelContractError(
                    "plan_crosses_terminal_outcome",
                    "a plan cannot execute actions after a terminal outcome",
                )
            expected_source = prediction.result.state_sha256
        _validate_sha256(self.artifact_sha256, "artifact_sha256")
        expected_hash = _sha256(self.unsigned_dict(), "validated plan")
        if self.artifact_sha256 != expected_hash:
            raise ArcWorldModelContractError(
                "artifact_hash_mismatch", "validated plan content was modified"
            )


@dataclass(frozen=True)
class ValidatedArcNextAction:
    """The only action released after validating the complete observed prefix."""

    action: PlannedArcAction
    prediction: ArcStepPrediction
    plan_sha256: str
    completed_actions: int

    def render(self) -> str:
        return self.action.render()


def _strict_mapping(value: object, keys: set, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise ArcWorldModelContractError(
            "invalid_%s" % label.replace(" ", "_"), "%s must be an object" % label
        )
    if not all(isinstance(key, str) for key in value):
        raise ArcWorldModelContractError(
            "invalid_%s" % label.replace(" ", "_"),
            "%s keys must be strings" % label,
        )
    actual = set(value)
    if actual != keys:
        missing = sorted(keys - actual)
        extra = sorted(actual - keys)
        raise ArcWorldModelContractError(
            "invalid_%s" % label.replace(" ", "_"),
            "%s keys differ (missing=%s extra=%s)" % (label, missing, extra),
        )
    return dict(value)


def _reject_duplicate_json_pairs(pairs: Sequence[Tuple[str, object]]) -> Dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key %s" % key)
        result[key] = value
    return result


def _reject_nonfinite_json_constant(value: str) -> None:
    raise ValueError("non-finite JSON number %s" % value)


def _canonical_value(value: object, label: str) -> object:
    if value is None or type(value) in (bool, int, str):
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise ArcWorldModelContractError(
                "noncanonical_%s" % label, "%s contains a non-finite float" % label
            )
        return value
    if isinstance(value, (list, tuple)):
        return [_canonical_value(item, label) for item in value]
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise ArcWorldModelContractError(
                "noncanonical_%s" % label,
                "%s mapping keys must be strings" % label,
            )
        return {
            key: _canonical_value(value[key], label) for key in sorted(value)
        }
    raise ArcWorldModelContractError(
        "noncanonical_%s" % label,
        "%s contains unsupported value type %s"
        % (label, type(value).__name__),
    )


def _canonical_bytes(value: object, label: str) -> bytes:
    normalized = _canonical_value(value, label)
    try:
        text = json.dumps(
            normalized,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise ArcWorldModelContractError(
            "noncanonical_%s" % label, "%s cannot be canonicalized: %s" % (label, exc)
        )
    return text.encode("utf-8")


def _sha256(value: object, label: str) -> str:
    return hashlib.sha256(_canonical_bytes(value, label)).hexdigest()


def _validate_sha256(value: object, label: str) -> None:
    if not isinstance(value, str) or not _SHA256_PATTERN.fullmatch(value):
        raise ArcWorldModelContractError(
            "invalid_hash", "%s must be a lowercase SHA-256 digest" % label
        )


def _normalize_frame(value: object) -> Tuple[Tuple[int, ...], ...]:
    if not isinstance(value, (list, tuple)) or not value:
        raise ArcWorldModelContractError(
            "invalid_frame", "render must return a non-empty full frame"
        )
    rows = []
    width = None
    for row in value:
        if not isinstance(row, (list, tuple)) or not row:
            raise ArcWorldModelContractError(
                "invalid_frame", "rendered frame rows must be non-empty sequences"
            )
        normalized = tuple(row)
        if not all(type(cell) is int for cell in normalized):
            raise ArcWorldModelContractError(
                "invalid_frame", "rendered frame cells must be integers"
            )
        if width is None:
            width = len(normalized)
        elif len(normalized) != width:
            raise ArcWorldModelContractError(
                "invalid_frame", "render must return a rectangular full frame"
            )
        rows.append(normalized)
    return tuple(rows)


def frame_sha256(frame: object) -> str:
    """Hash every cell and the exact dimensions of a non-empty frame."""

    normalized = _normalize_frame(frame)
    return _sha256(
        {
            "cells": normalized,
            "height": len(normalized),
            "width": len(normalized[0]),
        },
        "frame",
    )


def _validate_observation(observation: object) -> ArcObservation:
    if not isinstance(observation, ArcObservation):
        raise ArcWorldModelContractError(
            "invalid_observation", "observation must be ArcObservation"
        )
    _normalize_frame(observation.frame)
    if not isinstance(observation.state, str) or not observation.state.strip():
        raise ArcWorldModelContractError(
            "invalid_observation", "observation state must be non-empty"
        )
    if type(observation.levels_completed) is not int or observation.levels_completed < 0:
        raise ArcWorldModelContractError(
            "invalid_observation", "observation level count is invalid"
        )
    available = tuple(observation.available)
    if any(action not in ARC_ACTION_NAMES for action in available):
        raise ArcWorldModelContractError(
            "invalid_observation", "observation contains an unknown action"
        )
    if len(set(available)) != len(available):
        raise ArcWorldModelContractError(
            "invalid_observation", "observation repeats an available action"
        )
    return observation


def observation_sha256(observation: ArcObservation) -> str:
    """Hash all semantic observation fields, including the complete frame."""

    item = _validate_observation(observation)
    frame = _normalize_frame(item.frame)
    return _sha256(
        {
            "available": sorted(item.available),
            "frame": frame,
            "levels_completed": item.levels_completed,
            "state": item.state,
        },
        "observation",
    )


def _canonical_action_payload(value: object) -> Dict[str, Any]:
    if isinstance(value, PlannedArcAction):
        name = value.name
        x = value.x
        y = value.y
    elif isinstance(value, dict):
        keys = set(value)
        name = value.get("action")
        x = value.get("x")
        y = value.get("y")
        allowed = {"action", "x", "y"} if name == "ACTION6" else {"action"}
        if keys != allowed:
            raise ArcWorldModelContractError(
                "invalid_action", "artifact action keys are not canonical"
            )
    else:
        raise ArcWorldModelContractError(
            "invalid_action", "action must be PlannedArcAction or an object"
        )
    if not isinstance(name, str) or name not in ARC_ACTION_NAMES:
        raise ArcWorldModelContractError(
            "invalid_action", "action name is not canonical"
        )
    if name == "ACTION6":
        if (
            type(x) is not int
            or type(y) is not int
            or not 0 <= x <= 63
            or not 0 <= y <= 63
        ):
            raise ArcWorldModelContractError(
                "invalid_action", "ACTION6 requires integer x/y in 0..63"
            )
        return {"action": name, "x": x, "y": y}
    if x is not None or y is not None:
        raise ArcWorldModelContractError(
            "invalid_action", "only ACTION6 accepts coordinates"
        )
    return {"action": name}


def _action_from_payload(payload: Mapping[str, Any]) -> PlannedArcAction:
    item = _canonical_action_payload(dict(payload))
    return PlannedArcAction(item["action"], item.get("x"), item.get("y"))


def _callable_fingerprint(value: object, label: str) -> Dict[str, str]:
    function = getattr(value, "__func__", value)
    material = {
        "module": str(getattr(function, "__module__", "")),
        "qualname": str(getattr(function, "__qualname__", "")),
    }
    try:
        source = inspect.getsource(function)
    except (OSError, TypeError):
        code = getattr(function, "__code__", None)
        if code is None:
            raise ArcWorldModelContractError(
                "unverifiable_model_implementation",
                "%s has neither inspectable source nor bytecode" % label,
            )
        source = marshal.dumps(code).hex()
    material["implementation"] = source
    source_file = inspect.getsourcefile(function)
    if source_file:
        try:
            with open(source_file, "rb") as handle:
                material["module_source_sha256"] = hashlib.sha256(
                    handle.read()
                ).hexdigest()
        except OSError as exc:
            raise ArcWorldModelContractError(
                "unverifiable_model_implementation",
                "%s source file cannot be hashed: %s" % (label, exc),
            )
    return material


def model_identity(model: ArcExecutableWorldModel) -> ArcModelIdentity:
    """Bind a model's declared config and executable implementation."""

    model_id = getattr(model, "model_id", None)
    revision = getattr(model, "model_revision", None)
    if not isinstance(model_id, str) or not model_id.strip():
        raise ArcWorldModelContractError(
            "invalid_model_identity", "model_id must be a non-empty string"
        )
    if not isinstance(revision, str) or not revision.strip():
        raise ArcWorldModelContractError(
            "invalid_model_identity", "model_revision must be a non-empty string"
        )
    required = (
        "model_manifest",
        "canonical_state",
        "init",
        "transition",
        "render",
        "outcome",
    )
    callables = {}
    for name in required:
        candidate = getattr(model, name, None)
        if not callable(candidate):
            raise ArcWorldModelContractError(
                "missing_model_operation", "model has no callable %s" % name
            )
        callables[name] = _callable_fingerprint(candidate, name)
    first_manifest = _canonical_value(model.model_manifest(), "model_manifest")
    second_manifest = _canonical_value(model.model_manifest(), "model_manifest")
    if first_manifest != second_manifest:
        raise ArcWorldModelContractError(
            "nondeterministic_model_manifest",
            "model_manifest changed between consecutive reads",
        )
    if not isinstance(first_manifest, dict):
        raise ArcWorldModelContractError(
            "invalid_model_manifest", "model_manifest must return an object"
        )
    manifest_hash = _sha256(first_manifest, "model_manifest")
    implementation_hash = _sha256(callables, "model_implementation")
    fingerprint = _sha256(
        {
            "implementation_sha256": implementation_hash,
            "manifest_sha256": manifest_hash,
            "model_id": model_id,
            "model_revision": revision,
        },
        "model_fingerprint",
    )
    return ArcModelIdentity(
        model_id=model_id,
        model_revision=revision,
        manifest_sha256=manifest_hash,
        implementation_sha256=implementation_hash,
        fingerprint_sha256=fingerprint,
    )


def _state_material(model: ArcExecutableWorldModel, state: object) -> object:
    try:
        material = model.canonical_state(state)
    except Exception as exc:
        raise ArcWorldModelContractError(
            "canonical_state_failed", "canonical_state raised: %s" % exc
        )
    return _canonical_value(material, "state")


def _snapshot(
    model: ArcExecutableWorldModel, state: object
) -> Tuple[ArcStateSnapshot, Tuple[Tuple[int, ...], ...]]:
    before = _state_material(model, state)
    before_hash = _sha256(before, "state")
    try:
        frame = _normalize_frame(model.render(state))
    except ArcWorldModelContractError:
        raise
    except Exception as exc:
        raise ArcWorldModelContractError(
            "render_failed", "render raised: %s" % exc
        )
    try:
        outcome = model.outcome(state)
    except ArcWorldModelContractError:
        raise
    except Exception as exc:
        raise ArcWorldModelContractError(
            "outcome_failed", "outcome raised: %s" % exc
        )
    if not isinstance(outcome, ArcWorldOutcome):
        raise ArcWorldModelContractError(
            "invalid_outcome", "outcome must return ArcWorldOutcome"
        )
    after = _state_material(model, state)
    if before != after:
        raise ArcWorldModelContractError(
            "impure_model_observer",
            "canonical_state, render, or outcome mutated model state",
        )
    snapshot = ArcStateSnapshot(
        state_sha256=before_hash,
        frame_sha256=frame_sha256(frame),
        frame_height=len(frame),
        frame_width=len(frame[0]),
        outcome=outcome,
    )
    snapshot.validate()
    return snapshot, frame


def _check_initial_snapshot(
    snapshot: ArcStateSnapshot,
    frame: Tuple[Tuple[int, ...], ...],
    observation: ArcObservation,
) -> None:
    observed_frame = _normalize_frame(observation.frame)
    if frame != observed_frame:
        raise ArcWorldModelContractError(
            "initial_model_observation_drift",
            "model render does not equal the complete initial observation frame",
        )
    if (
        snapshot.outcome.state != observation.state
        or snapshot.outcome.levels_completed != observation.levels_completed
    ):
        raise ArcWorldModelContractError(
            "initial_outcome_drift",
            "model outcome does not equal the initial observation outcome",
        )


def _run_replay(
    model: ArcExecutableWorldModel,
    initial_observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
) -> Tuple[ArcStateSnapshot, Tuple[ArcStepPrediction, ...]]:
    try:
        state = model.init(initial_observation)
    except Exception as exc:
        raise ArcWorldModelContractError("init_failed", "init raised: %s" % exc)
    initial, initial_frame = _snapshot(model, state)
    _check_initial_snapshot(initial, initial_frame, initial_observation)
    predictions = []
    prior = initial
    for index, action in enumerate(actions, 1):
        if prior.outcome.terminal:
            raise ArcWorldModelContractError(
                "plan_crosses_terminal_outcome",
                "action %d follows a terminal outcome" % index,
            )
        try:
            next_state = model.transition(state, action)
        except Exception as exc:
            raise ArcWorldModelContractError(
                "transition_failed", "transition %d raised: %s" % (index, exc)
            )
        if next_state is None:
            raise ArcWorldModelContractError(
                "transition_failed", "transition %d returned null state" % index
            )
        state = next_state
        result, _frame = _snapshot(model, state)
        predictions.append(
            ArcStepPrediction(
                index=index,
                action=_canonical_action_payload(action),
                source_state_sha256=prior.state_sha256,
                result=result,
            )
        )
        prior = result
    return initial, tuple(predictions)


def _verified_replay(
    model: ArcExecutableWorldModel,
    initial_observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
) -> Tuple[ArcStateSnapshot, Tuple[ArcStepPrediction, ...]]:
    first = _run_replay(model, initial_observation, actions)
    second = _run_replay(model, initial_observation, actions)
    if first != second:
        raise ArcWorldModelContractError(
            "nondeterministic_replay",
            "two independent model replays produced different state, frame, or outcome hashes",
        )
    return first


def build_validated_plan(
    model: ArcExecutableWorldModel,
    initial_observation: ArcObservation,
    actions: Sequence[PlannedArcAction],
) -> ValidatedArcPlan:
    """Create a hash-bound plan only after two identical full model replays."""

    observation = _validate_observation(initial_observation)
    if not isinstance(actions, (list, tuple)) or not 1 <= len(actions) <= 128:
        raise ArcWorldModelContractError(
            "invalid_plan", "actions must contain 1-128 PlannedArcAction values"
        )
    normalized_actions = []
    for action in actions:
        payload = _canonical_action_payload(action)
        normalized_actions.append(_action_from_payload(payload))
    if normalized_actions[0].name not in observation.available:
        raise ArcWorldModelContractError(
            "unavailable_initial_action",
            "the first planned action is not available in the initial observation",
        )
    identity_before = model_identity(model)
    initial, predictions = _verified_replay(
        model, observation, tuple(normalized_actions)
    )
    identity_after = model_identity(model)
    if identity_before != identity_after:
        raise ArcWorldModelContractError(
            "model_drift_during_validation",
            "model identity or configuration changed during plan replay",
        )
    unsigned = {
        "initial": initial.as_dict(),
        "initial_observation_sha256": observation_sha256(observation),
        "model": identity_before.as_dict(),
        "predictions": [item.as_dict() for item in predictions],
        "schema": ARC_VALIDATED_PLAN_SCHEMA,
    }
    artifact = ValidatedArcPlan(
        model=ArcModelIdentity.from_dict(unsigned["model"]),
        initial_observation_sha256=unsigned["initial_observation_sha256"],
        initial=initial,
        predictions=predictions,
        artifact_sha256=_sha256(unsigned, "validated plan"),
    )
    artifact.validate_integrity()
    return artifact


def verify_validated_plan(
    plan: ValidatedArcPlan,
    model: ArcExecutableWorldModel,
    initial_observation: ArcObservation,
) -> None:
    """Recompute identity and every prediction; any drift invalidates the plan."""

    if not isinstance(plan, ValidatedArcPlan):
        raise ArcWorldModelContractError(
            "invalid_plan", "plan must be ValidatedArcPlan"
        )
    plan.validate_integrity()
    observation = _validate_observation(initial_observation)
    if observation_sha256(observation) != plan.initial_observation_sha256:
        raise ArcPlanInvalidated(
            "initial_observation_drift",
            "initial observation no longer matches the validated plan",
        )
    current_identity = model_identity(model)
    if current_identity != plan.model:
        raise ArcPlanInvalidated(
            "model_drift", "model identity, configuration, or implementation changed"
        )
    actions = tuple(_action_from_payload(item.action) for item in plan.predictions)
    try:
        initial, predictions = _verified_replay(model, observation, actions)
    except ArcWorldModelContractError as exc:
        raise ArcPlanInvalidated(
            "model_replay_invalid", "current model replay failed: %s" % exc
        )
    if initial != plan.initial or predictions != plan.predictions:
        raise ArcPlanInvalidated(
            "model_prediction_drift",
            "current deterministic replay differs from the validated predictions",
        )


def _assert_observation_matches(
    observation: ArcObservation,
    expected: ArcStateSnapshot,
    index: int,
) -> None:
    frame = _normalize_frame(observation.frame)
    actual_hash = frame_sha256(frame)
    if (
        len(frame) != expected.frame_height
        or len(frame[0]) != expected.frame_width
        or actual_hash != expected.frame_sha256
    ):
        raise ArcPlanInvalidated(
            "full_frame_prediction_mismatch",
            "observation %d differs from the complete predicted frame" % index,
        )
    if (
        observation.state != expected.outcome.state
        or observation.levels_completed != expected.outcome.levels_completed
    ):
        raise ArcPlanInvalidated(
            "outcome_prediction_mismatch",
            "observation %d state or level count differs from prediction" % index,
        )


def validate_next_action(
    plan: ValidatedArcPlan,
    model: ArcExecutableWorldModel,
    observations: Sequence[ArcObservation],
    executed_actions: Sequence[PlannedArcAction],
    proposed_action: Optional[PlannedArcAction] = None,
) -> ValidatedArcNextAction:
    """Validate the entire settled prefix, then release exactly one next action.

    The history must contain the initial observation plus one settled observation
    per executed action. Every settled frame is checked by a full-frame hash; the
    sparse ``expect_cells`` field on ``PlannedArcAction`` is never consulted.
    """

    if not isinstance(observations, (list, tuple)) or not observations:
        raise ArcWorldModelContractError(
            "invalid_observation_history", "observation history cannot be empty"
        )
    checked_observations = tuple(_validate_observation(item) for item in observations)
    verify_validated_plan(plan, model, checked_observations[0])
    return validate_next_action_from_plan(
        plan,
        checked_observations,
        executed_actions,
        proposed_action=proposed_action,
    )


def validate_next_action_from_plan(
    plan: ValidatedArcPlan,
    observations: Sequence[ArcObservation],
    executed_actions: Sequence[PlannedArcAction],
    proposed_action: Optional[PlannedArcAction] = None,
) -> ValidatedArcNextAction:
    """Release one action using only a trusted, already revalidated plan.

    This is the parent-side gate for isolated world-model execution. The model
    process never receives the sealed plan and never chooses the released action.
    """

    if not isinstance(plan, ValidatedArcPlan):
        raise ArcWorldModelContractError(
            "invalid_plan", "plan must be ValidatedArcPlan"
        )
    plan.validate_integrity()
    if not isinstance(observations, (list, tuple)) or not observations:
        raise ArcWorldModelContractError(
            "invalid_observation_history", "observation history cannot be empty"
        )
    if not isinstance(executed_actions, (list, tuple)):
        raise ArcWorldModelContractError(
            "invalid_action_history", "executed action history must be a sequence"
        )
    if len(observations) != len(executed_actions) + 1:
        raise ArcPlanInvalidated(
            "history_length_mismatch",
            "history must contain one settled observation per executed action",
        )
    if len(executed_actions) > len(plan.predictions):
        raise ArcPlanInvalidated(
            "history_exceeds_plan", "executed action history exceeds the plan"
        )
    checked_observations = tuple(_validate_observation(item) for item in observations)
    if observation_sha256(checked_observations[0]) != plan.initial_observation_sha256:
        raise ArcPlanInvalidated(
            "initial_observation_drift",
            "initial observation no longer matches the validated plan",
        )
    _assert_observation_matches(checked_observations[0], plan.initial, 0)
    for offset, action in enumerate(executed_actions):
        actual = _canonical_action_payload(action)
        expected = dict(plan.predictions[offset].action)
        if actual != expected:
            raise ArcPlanInvalidated(
                "executed_action_drift",
                "executed action %d is not the validated plan prefix" % (offset + 1),
            )
        _assert_observation_matches(
            checked_observations[offset + 1],
            plan.predictions[offset].result,
            offset + 1,
        )
    completed = len(executed_actions)
    if completed == len(plan.predictions):
        raise ArcPlanComplete("validated ARC plan is complete")
    prediction = plan.predictions[completed]
    next_action = _action_from_payload(prediction.action)
    current_observation = checked_observations[-1]
    if next_action.name not in current_observation.available:
        raise ArcPlanInvalidated(
            "next_action_unavailable",
            "validated next action is not available in the current observation",
        )
    if next_action.name == "ACTION6":
        height = len(current_observation.frame)
        width = len(current_observation.frame[0])
        if next_action.x >= width or next_action.y >= height:
            raise ArcPlanInvalidated(
                "next_action_out_of_frame",
                "ACTION6 coordinate is outside the current complete frame",
            )
    if proposed_action is not None:
        proposed = _canonical_action_payload(proposed_action)
        if proposed != dict(prediction.action):
            raise ArcPlanInvalidated(
                "proposed_action_drift",
                "proposed action is not the validated next action",
            )
    return ValidatedArcNextAction(
        action=next_action,
        prediction=prediction,
        plan_sha256=plan.artifact_sha256,
        completed_actions=completed,
    )


__all__ = [
    "ARC_VALIDATED_PLAN_SCHEMA",
    "ArcExecutableWorldModel",
    "ArcModelIdentity",
    "ArcPlanComplete",
    "ArcPlanInvalidated",
    "ArcStateSnapshot",
    "ArcStepPrediction",
    "ArcWorldModelContractError",
    "ArcWorldOutcome",
    "ValidatedArcNextAction",
    "ValidatedArcPlan",
    "build_validated_plan",
    "frame_sha256",
    "model_identity",
    "observation_sha256",
    "validate_next_action",
    "validate_next_action_from_plan",
    "verify_validated_plan",
]
