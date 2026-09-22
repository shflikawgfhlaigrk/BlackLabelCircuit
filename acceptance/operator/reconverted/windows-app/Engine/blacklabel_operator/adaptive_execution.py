"""Deterministic, evidence-gated adaptive execution orchestration.

This module deliberately contains no provider, database, filesystem, or daemon
dependencies. Integrators supply five callbacks and can persist the returned
receipt wherever their generation-fenced runtime requires.
"""

import hashlib
import json
import math
from dataclasses import dataclass, field, fields, is_dataclass
from types import MappingProxyType
from typing import Any, Callable, Mapping, Optional, Sequence, Tuple


RECEIPT_SCHEMA = "black-label-operator/adaptive-execution-v1"
STAGES = ("planner", "executor", "verifier", "critic", "arbiter")
DECISIONS = ("accept", "replan", "stop")
RECOMMENDATIONS = ("accept", "replan", "stop")


class AdaptiveExecutionContractError(ValueError):
    """A callback returned a value that violates the execution contract."""


class AdaptiveBudgetExhausted(RuntimeError):
    """A callback could not reserve a bounded provider invocation."""


class AdaptiveCallbackFailure(RuntimeError):
    """A trusted adapter's bounded, user-readable failure diagnosis."""


def _require_nonempty(value, field_name):
    if not isinstance(value, str) or not value.strip():
        raise AdaptiveExecutionContractError("%s must be a non-empty string" % field_name)
    return value.strip()


def _string(value, field_name, allow_empty=True):
    if not isinstance(value, str):
        raise AdaptiveExecutionContractError("%s must be a string" % field_name)
    if not allow_empty and not value.strip():
        raise AdaptiveExecutionContractError("%s must be a non-empty string" % field_name)
    return value


def _require_integer(value, field_name, minimum=0):
    if type(value) is not int or value < minimum:
        raise AdaptiveExecutionContractError(
            "%s must be an integer >= %d" % (field_name, minimum)
        )
    return value


def _encode(value):
    if is_dataclass(value):
        return {item.name: _encode(getattr(value, item.name)) for item in fields(value)}
    if isinstance(value, Mapping):
        if any(not isinstance(key, str) for key in value):
            raise AdaptiveExecutionContractError("receipt mappings require string keys")
        result = {}
        for key in sorted(value):
            result[key] = _encode(value[key])
        return result
    if isinstance(value, (tuple, list)):
        return [_encode(item) for item in value]
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    raise AdaptiveExecutionContractError(
        "receipt values must be deterministic JSON values, got %s"
        % type(value).__name__
    )


def _canonical_json(value):
    return json.dumps(
        _encode(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def _freeze(value):
    if isinstance(value, dict):
        return MappingProxyType({key: _freeze(item) for key, item in value.items()})
    if isinstance(value, list):
        return tuple(_freeze(item) for item in value)
    return value


def _mapping(value, field_name):
    if value is None:
        return {}
    if not isinstance(value, Mapping):
        raise AdaptiveExecutionContractError("%s must be a mapping" % field_name)
    try:
        encoded = _encode(value)
        normalized = json.loads(
            json.dumps(
                encoded,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
                allow_nan=False,
            )
        )
    except AdaptiveExecutionContractError:
        raise
    except Exception as exc:
        raise AdaptiveExecutionContractError(
            "%s is not deterministic JSON: %s" % (field_name, type(exc).__name__)
        )
    return _freeze(normalized)


def _strings(value, field_name, require_nonempty=False):
    if isinstance(value, str) or not isinstance(value, Sequence):
        raise AdaptiveExecutionContractError("%s must be a sequence of strings" % field_name)
    result = tuple(
        _require_nonempty(item, "%s item" % field_name) for item in value
    )
    if require_nonempty and not result:
        raise AdaptiveExecutionContractError("%s must not be empty" % field_name)
    return result


def _sha256(value, field_name):
    if value is None:
        return None
    rendered = _require_nonempty(value, field_name).lower()
    if len(rendered) != 64 or any(character not in "0123456789abcdef" for character in rendered):
        raise AdaptiveExecutionContractError("%s must be a SHA-256 hex digest" % field_name)
    return rendered


@dataclass(frozen=True)
class Usage:
    tokens: int = 0
    cost_micros: int = 0


@dataclass(frozen=True)
class BudgetLimits:
    max_rounds: int = 3
    max_calls_per_stage: Optional[int] = None
    max_tokens: Optional[int] = None
    max_cost_micros: Optional[int] = None

    def validated(self):
        max_rounds = _require_integer(self.max_rounds, "max_rounds", 1)
        values = {}
        for name in ("max_calls_per_stage", "max_tokens", "max_cost_micros"):
            value = getattr(self, name)
            values[name] = (
                None if value is None else _require_integer(value, name, 0)
            )
        return BudgetLimits(max_rounds=max_rounds, **values)


@dataclass(frozen=True)
class BudgetSnapshot:
    limits: BudgetLimits
    stage_calls: Mapping[str, int]
    used_tokens: int
    used_cost_micros: int


@dataclass(frozen=True)
class Artifact:
    name: str
    sha256: str
    media_type: str = "application/octet-stream"
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Evidence:
    evidence_id: str
    kind: str
    passed: bool
    summary: str
    source: str
    required: bool = True
    artifact_sha256: Optional[str] = None
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class PlanResult:
    steps: Tuple[str, ...]
    rationale: str = ""
    metadata: Mapping[str, Any] = field(default_factory=dict)
    usage: Usage = field(default_factory=Usage)


@dataclass(frozen=True)
class ExecutionResult:
    completed: bool
    summary: str
    output: Mapping[str, Any] = field(default_factory=dict)
    artifacts: Tuple[Artifact, ...] = ()
    usage: Usage = field(default_factory=Usage)


@dataclass(frozen=True)
class VerificationResult:
    passed: bool
    summary: str
    evidence: Tuple[Evidence, ...]
    usage: Usage = field(default_factory=Usage)


@dataclass(frozen=True)
class CritiqueResult:
    recommendation: str
    summary: str
    issues: Tuple[str, ...] = ()
    evidence_refs: Tuple[str, ...] = ()
    usage: Usage = field(default_factory=Usage)


@dataclass(frozen=True)
class ArbitrationResult:
    decision: str
    rationale: str
    evidence_refs: Tuple[str, ...]
    usage: Usage = field(default_factory=Usage)


@dataclass(frozen=True)
class PlanningRequest:
    objective: str
    context: Mapping[str, Any]
    round_index: int
    feedback: Tuple[Mapping[str, Any], ...]
    budget: BudgetSnapshot


@dataclass(frozen=True)
class ExecutionRequest:
    objective: str
    context: Mapping[str, Any]
    round_index: int
    plan: PlanResult
    budget: BudgetSnapshot


@dataclass(frozen=True)
class VerificationRequest:
    objective: str
    context: Mapping[str, Any]
    round_index: int
    plan: PlanResult
    execution: ExecutionResult
    budget: BudgetSnapshot


@dataclass(frozen=True)
class CritiqueRequest:
    objective: str
    context: Mapping[str, Any]
    round_index: int
    plan: PlanResult
    execution: ExecutionResult
    verification: VerificationResult
    budget: BudgetSnapshot


@dataclass(frozen=True)
class ArbitrationRequest:
    objective: str
    context: Mapping[str, Any]
    round_index: int
    plan: PlanResult
    execution: ExecutionResult
    verification: VerificationResult
    critique: CritiqueResult
    budget: BudgetSnapshot


@dataclass(frozen=True)
class AdaptiveExecutionCallbacks:
    planner: Callable[[PlanningRequest], PlanResult]
    executor: Callable[[ExecutionRequest], ExecutionResult]
    verifier: Callable[[VerificationRequest], VerificationResult]
    critic: Callable[[CritiqueRequest], CritiqueResult]
    arbiter: Callable[[ArbitrationRequest], ArbitrationResult]

    def validated(self):
        for stage in STAGES:
            if not callable(getattr(self, stage)):
                raise AdaptiveExecutionContractError("%s callback is not callable" % stage)
        return self


@dataclass(frozen=True)
class StageError:
    stage: str
    kind: str
    detail: str


@dataclass(frozen=True)
class RoundReceipt:
    round_index: int
    plan: Optional[PlanResult] = None
    execution: Optional[ExecutionResult] = None
    verification: Optional[VerificationResult] = None
    critique: Optional[CritiqueResult] = None
    arbitration: Optional[ArbitrationResult] = None
    error: Optional[StageError] = None


@dataclass(frozen=True)
class AdaptiveExecutionReceipt:
    objective: str
    context: Mapping[str, Any]
    limits: BudgetLimits
    usage: BudgetSnapshot
    status: str
    reason: str
    rounds: Tuple[RoundReceipt, ...]

    def __post_init__(self):
        if self.status not in ("succeeded", "failed", "stopped", "budget_exhausted"):
            raise AdaptiveExecutionContractError("unsupported receipt status")
        if self.status == "succeeded" and not self.succeeded:
            raise AdaptiveExecutionContractError(
                "a succeeded receipt requires verified evidence-backed acceptance"
            )

    @property
    def succeeded(self):
        if (
            self.status != "succeeded"
            or type(self.rounds) is not tuple
            or not self.rounds
        ):
            return False
        final = self.rounds[-1]
        if type(final) is not RoundReceipt or final.error is not None:
            return False
        if type(final.round_index) is not int or final.round_index < 1:
            return False

        # A receipt is an external trust boundary. Re-run the same complete
        # contract normalization used for callback results instead of checking
        # only the handful of fields needed by the acceptance decision. This
        # rejects forged receipts with missing plans, hollow evidence, invalid
        # artifacts/usages, or empty stage summaries. Equality with the
        # normalized values also rejects noncanonical sequence containers and
        # values that would be trimmed or case-folded during normalization.
        try:
            plan = _plan(final.plan)
            execution = _execution(final.execution)
            verification = _verification(final.verification)
            critique = _critique(final.critique, verification)
            arbitration = _arbitration(final.arbitration, verification)
        except Exception:
            return False
        if (
            type(final.plan) is not PlanResult
            or final.plan != plan
            or type(final.execution) is not ExecutionResult
            or final.execution != execution
            or type(final.verification) is not VerificationResult
            or final.verification != verification
            or type(final.critique) is not CritiqueResult
            or final.critique != critique
            or type(final.arbitration) is not ArbitrationResult
            or final.arbitration != arbitration
        ):
            return False
        return bool(
            execution.completed
            and verification.passed
            and critique.recommendation == "accept"
            and arbitration.decision == "accept"
        )

    def _body(self):
        return {
            "schema": RECEIPT_SCHEMA,
            "objective": self.objective,
            "context": self.context,
            "limits": self.limits,
            "usage": self.usage,
            "status": self.status,
            "reason": self.reason,
            "succeeded": self.succeeded,
            "rounds": self.rounds,
        }

    @property
    def receipt_sha256(self):
        return hashlib.sha256(_canonical_json(self._body()).encode("utf-8")).hexdigest()

    def to_dict(self):
        payload = _encode(self._body())
        payload["receipt_sha256"] = self.receipt_sha256
        return payload

    def to_json(self, indent=None):
        return json.dumps(
            self.to_dict(),
            sort_keys=True,
            separators=(",", ":") if indent is None else None,
            ensure_ascii=True,
            allow_nan=False,
            indent=indent,
        )


class _BudgetTracker:
    def __init__(self, limits):
        self.limits = limits
        self.stage_calls = {stage: 0 for stage in STAGES}
        self.used_tokens = 0
        self.used_cost_micros = 0

    def snapshot(self):
        return BudgetSnapshot(
            limits=self.limits,
            stage_calls=_mapping(self.stage_calls, "stage_calls"),
            used_tokens=self.used_tokens,
            used_cost_micros=self.used_cost_micros,
        )

    def reserve(self, stage):
        maximum = self.limits.max_calls_per_stage
        if maximum is not None and self.stage_calls[stage] >= maximum:
            return "%s call budget exhausted" % stage
        self.stage_calls[stage] += 1
        return None

    def consume(self, stage, usage):
        del stage
        self.used_tokens += usage.tokens
        self.used_cost_micros += usage.cost_micros
        if (
            self.limits.max_tokens is not None
            and self.used_tokens > self.limits.max_tokens
        ):
            return "token budget exceeded"
        if (
            self.limits.max_cost_micros is not None
            and self.used_cost_micros > self.limits.max_cost_micros
        ):
            return "cost budget exceeded"
        return None


@dataclass(frozen=True)
class _Invocation:
    value: Any = None
    error: Optional[StageError] = None
    budget_reason: Optional[str] = None


def _usage(value):
    if not isinstance(value, Usage):
        raise AdaptiveExecutionContractError("usage must be a Usage value")
    return Usage(
        tokens=_require_integer(value.tokens, "usage.tokens", 0),
        cost_micros=_require_integer(value.cost_micros, "usage.cost_micros", 0),
    )


def _artifact(value):
    if not isinstance(value, Artifact):
        raise AdaptiveExecutionContractError("artifacts must contain Artifact values")
    digest = _sha256(value.sha256, "artifact.sha256")
    if digest is None:
        raise AdaptiveExecutionContractError("artifact.sha256 is required")
    return Artifact(
        name=_require_nonempty(value.name, "artifact.name"),
        sha256=digest,
        media_type=_require_nonempty(value.media_type, "artifact.media_type"),
        metadata=_mapping(value.metadata, "artifact.metadata"),
    )


def _evidence(value):
    if not isinstance(value, Evidence):
        raise AdaptiveExecutionContractError("evidence must contain Evidence values")
    if type(value.passed) is not bool or type(value.required) is not bool:
        raise AdaptiveExecutionContractError("evidence passed and required flags must be booleans")
    return Evidence(
        evidence_id=_require_nonempty(value.evidence_id, "evidence.evidence_id"),
        kind=_require_nonempty(value.kind, "evidence.kind"),
        passed=value.passed,
        summary=_require_nonempty(value.summary, "evidence.summary"),
        source=_require_nonempty(value.source, "evidence.source"),
        required=value.required,
        artifact_sha256=_sha256(value.artifact_sha256, "evidence.artifact_sha256"),
        metadata=_mapping(value.metadata, "evidence.metadata"),
    )


def _plan(value):
    if not isinstance(value, PlanResult):
        raise AdaptiveExecutionContractError("planner must return PlanResult")
    return PlanResult(
        steps=_strings(value.steps, "plan.steps", require_nonempty=True),
        rationale=_string(value.rationale, "plan.rationale"),
        metadata=_mapping(value.metadata, "plan.metadata"),
        usage=_usage(value.usage),
    )


def _execution(value):
    if not isinstance(value, ExecutionResult):
        raise AdaptiveExecutionContractError("executor must return ExecutionResult")
    if type(value.completed) is not bool:
        raise AdaptiveExecutionContractError("execution.completed must be a boolean")
    if isinstance(value.artifacts, str) or not isinstance(value.artifacts, Sequence):
        raise AdaptiveExecutionContractError("execution.artifacts must be a sequence")
    return ExecutionResult(
        completed=value.completed,
        summary=_require_nonempty(value.summary, "execution.summary"),
        output=_mapping(value.output, "execution.output"),
        artifacts=tuple(_artifact(item) for item in value.artifacts),
        usage=_usage(value.usage),
    )


def _verification(value):
    if not isinstance(value, VerificationResult):
        raise AdaptiveExecutionContractError("verifier must return VerificationResult")
    if type(value.passed) is not bool:
        raise AdaptiveExecutionContractError("verification.passed must be a boolean")
    if isinstance(value.evidence, str) or not isinstance(value.evidence, Sequence):
        raise AdaptiveExecutionContractError("verification.evidence must be a sequence")
    evidence = tuple(_evidence(item) for item in value.evidence)
    if not evidence:
        raise AdaptiveExecutionContractError("verification must contain evidence")
    identifiers = [item.evidence_id for item in evidence]
    if len(set(identifiers)) != len(identifiers):
        raise AdaptiveExecutionContractError("verification evidence IDs must be unique")
    required = [item for item in evidence if item.required]
    if value.passed and (not required or not all(item.passed for item in required)):
        raise AdaptiveExecutionContractError(
            "passed verification requires passing required evidence"
        )
    return VerificationResult(
        passed=value.passed,
        summary=_require_nonempty(value.summary, "verification.summary"),
        evidence=evidence,
        usage=_usage(value.usage),
    )


def _evidence_index(verification):
    return {item.evidence_id: item for item in verification.evidence}


def _references(value, field_name, evidence, required=False):
    references = _strings(value, field_name, require_nonempty=required)
    unknown = sorted(set(references) - set(evidence))
    if unknown:
        raise AdaptiveExecutionContractError(
            "%s contains unknown evidence IDs: %s"
            % (field_name, ", ".join(unknown))
        )
    return references


def _critique(value, verification):
    if not isinstance(value, CritiqueResult):
        raise AdaptiveExecutionContractError("critic must return CritiqueResult")
    recommendation = str(value.recommendation or "").lower()
    if recommendation not in RECOMMENDATIONS:
        raise AdaptiveExecutionContractError("unsupported critic recommendation")
    evidence = _evidence_index(verification)
    references = _references(
        value.evidence_refs,
        "critique.evidence_refs",
        evidence,
        required=True,
    )
    issues = _strings(value.issues, "critique.issues")
    if recommendation == "accept":
        cited = [evidence[item] for item in references]
        if any(not item.passed for item in cited):
            raise AdaptiveExecutionContractError(
                "critic acceptance cannot cite failing evidence"
            )
        required_ids = {
            item.evidence_id for item in verification.evidence if item.required
        }
        if not required_ids.issubset(set(references)):
            raise AdaptiveExecutionContractError(
                "critic acceptance must cite every passing required evidence item"
            )
        if issues:
            raise AdaptiveExecutionContractError(
                "critic acceptance cannot report issues"
            )
    return CritiqueResult(
        recommendation=recommendation,
        summary=_require_nonempty(value.summary, "critique.summary"),
        issues=issues,
        evidence_refs=references,
        usage=_usage(value.usage),
    )


def _arbitration(value, verification):
    if not isinstance(value, ArbitrationResult):
        raise AdaptiveExecutionContractError("arbiter must return ArbitrationResult")
    decision = str(value.decision or "").lower()
    if decision not in DECISIONS:
        raise AdaptiveExecutionContractError("unsupported arbiter decision")
    evidence = _evidence_index(verification)
    references = _references(
        value.evidence_refs,
        "arbitration.evidence_refs",
        evidence,
        required=True,
    )
    if decision == "accept":
        cited = [evidence[item] for item in references]
        if any(not item.passed for item in cited):
            raise AdaptiveExecutionContractError(
                "acceptance cannot cite failing evidence"
            )
        required_ids = {
            item.evidence_id for item in verification.evidence if item.required
        }
        if not required_ids.issubset(set(references)):
            raise AdaptiveExecutionContractError(
                "acceptance must cite every passing required evidence item"
            )
    return ArbitrationResult(
        decision=decision,
        rationale=_require_nonempty(value.rationale, "arbitration.rationale"),
        evidence_refs=references,
        usage=_usage(value.usage),
    )


class AdaptiveExecutionEngine:
    """Runs bounded planner/executor/verifier/critic/arbiter rounds."""

    def __init__(self, callbacks, limits=None):
        if not isinstance(callbacks, AdaptiveExecutionCallbacks):
            raise AdaptiveExecutionContractError(
                "callbacks must be AdaptiveExecutionCallbacks"
            )
        self.callbacks = callbacks.validated()
        self.limits = (limits or BudgetLimits()).validated()

    @staticmethod
    def _round(index, values, error=None):
        return RoundReceipt(
            round_index=index,
            plan=values.get("plan"),
            execution=values.get("execution"),
            verification=values.get("verification"),
            critique=values.get("critique"),
            arbitration=values.get("arbitration"),
            error=error,
        )

    @staticmethod
    def _invoke(stage, callback, request_factory, normalizer, tracker):
        budget_reason = tracker.reserve(stage)
        if budget_reason:
            return _Invocation(budget_reason=budget_reason)
        request = request_factory(tracker.snapshot())
        try:
            raw = callback(request)
        except AdaptiveBudgetExhausted as exc:
            return _Invocation(budget_reason=str(exc))
        except AdaptiveCallbackFailure as exc:
            return _Invocation(
                error=StageError(
                    stage=stage, kind="adapter_error", detail=str(exc)[:1024]
                )
            )
        except Exception as exc:
            return _Invocation(
                error=StageError(
                    stage=stage,
                    kind="callback_error",
                    detail="%s callback raised %s"
                    % (stage, type(exc).__name__),
                )
            )
        try:
            value = normalizer(raw)
        except AdaptiveExecutionContractError as exc:
            return _Invocation(
                error=StageError(
                    stage=stage,
                    kind="contract_error",
                    detail=str(exc),
                )
            )
        except Exception as exc:
            return _Invocation(
                error=StageError(
                    stage=stage,
                    kind="contract_error",
                    detail="%s result normalization raised %s"
                    % (stage, type(exc).__name__),
                )
            )
        budget_reason = tracker.consume(stage, value.usage)
        return _Invocation(value=value, budget_reason=budget_reason)

    @staticmethod
    def _receipt(objective, context, limits, tracker, status, reason, rounds):
        return AdaptiveExecutionReceipt(
            objective=objective,
            context=context,
            limits=limits,
            usage=tracker.snapshot(),
            status=status,
            reason=reason,
            rounds=tuple(rounds),
        )

    def run(self, objective, context=None):
        objective = _require_nonempty(objective, "objective")
        context = _mapping({} if context is None else context, "context")
        tracker = _BudgetTracker(self.limits)
        rounds = []
        feedback = []

        for round_index in range(1, self.limits.max_rounds + 1):
            values = {}

            planning = self._invoke(
                "planner",
                self.callbacks.planner,
                lambda budget: PlanningRequest(
                    objective=objective,
                    context=_mapping(context, "context"),
                    round_index=round_index,
                    feedback=tuple(_mapping(item, "feedback") for item in feedback),
                    budget=budget,
                ),
                _plan,
                tracker,
            )
            terminal = self._handle_invocation(
                planning, "planner", round_index, values, rounds, tracker, objective, context
            )
            if terminal:
                return terminal
            values["plan"] = planning.value

            execution = self._invoke(
                "executor",
                self.callbacks.executor,
                lambda budget: ExecutionRequest(
                    objective=objective,
                    context=_mapping(context, "context"),
                    round_index=round_index,
                    plan=values["plan"],
                    budget=budget,
                ),
                _execution,
                tracker,
            )
            terminal = self._handle_invocation(
                execution, "executor", round_index, values, rounds, tracker, objective, context
            )
            if terminal:
                return terminal
            values["execution"] = execution.value

            verification = self._invoke(
                "verifier",
                self.callbacks.verifier,
                lambda budget: VerificationRequest(
                    objective=objective,
                    context=_mapping(context, "context"),
                    round_index=round_index,
                    plan=values["plan"],
                    execution=values["execution"],
                    budget=budget,
                ),
                _verification,
                tracker,
            )
            terminal = self._handle_invocation(
                verification, "verifier", round_index, values, rounds, tracker, objective, context
            )
            if terminal:
                return terminal
            values["verification"] = verification.value

            critique = self._invoke(
                "critic",
                self.callbacks.critic,
                lambda budget: CritiqueRequest(
                    objective=objective,
                    context=_mapping(context, "context"),
                    round_index=round_index,
                    plan=values["plan"],
                    execution=values["execution"],
                    verification=values["verification"],
                    budget=budget,
                ),
                lambda value: _critique(value, values["verification"]),
                tracker,
            )
            terminal = self._handle_invocation(
                critique, "critic", round_index, values, rounds, tracker, objective, context
            )
            if terminal:
                return terminal
            values["critique"] = critique.value

            arbitration = self._invoke(
                "arbiter",
                self.callbacks.arbiter,
                lambda budget: ArbitrationRequest(
                    objective=objective,
                    context=_mapping(context, "context"),
                    round_index=round_index,
                    plan=values["plan"],
                    execution=values["execution"],
                    verification=values["verification"],
                    critique=values["critique"],
                    budget=budget,
                ),
                lambda value: _arbitration(value, values["verification"]),
                tracker,
            )
            terminal = self._handle_invocation(
                arbitration, "arbiter", round_index, values, rounds, tracker, objective, context
            )
            if terminal:
                return terminal
            values["arbitration"] = arbitration.value
            rounds.append(self._round(round_index, values))

            if arbitration.value.decision == "accept":
                if not values["execution"].completed or not values["verification"].passed:
                    return self._receipt(
                        objective,
                        context,
                        self.limits,
                        tracker,
                        "failed",
                        "unverified acceptance rejected",
                        rounds,
                    )
                return self._receipt(
                    objective,
                    context,
                    self.limits,
                    tracker,
                    "succeeded",
                    "verified acceptance",
                    rounds,
                )
            if arbitration.value.decision == "stop":
                return self._receipt(
                    objective,
                    context,
                    self.limits,
                    tracker,
                    "stopped",
                    "evidence-backed arbiter stop",
                    rounds,
                )

            feedback.append(
                {
                    "round_index": round_index,
                    "verification": {
                        "passed": values["verification"].passed,
                        "summary": values["verification"].summary,
                        "evidence": [
                            {
                                "evidence_id": item.evidence_id,
                                "passed": item.passed,
                                "required": item.required,
                                "summary": item.summary,
                            }
                            for item in values["verification"].evidence
                        ],
                    },
                    "critique": {
                        "recommendation": values["critique"].recommendation,
                        "summary": values["critique"].summary,
                        "issues": list(values["critique"].issues),
                    },
                    "arbitration": {
                        "decision": values["arbitration"].decision,
                        "rationale": values["arbitration"].rationale,
                        "evidence_refs": list(values["arbitration"].evidence_refs),
                    },
                }
            )

        return self._receipt(
            objective,
            context,
            self.limits,
            tracker,
            "budget_exhausted",
            "round budget exhausted after evidence-backed replan",
            rounds,
        )

    def _handle_invocation(
        self,
        invocation,
        stage,
        round_index,
        values,
        rounds,
        tracker,
        objective,
        context,
    ):
        if invocation.error:
            rounds.append(
                self._round(round_index, values, error=invocation.error)
            )
            return self._receipt(
                objective,
                context,
                self.limits,
                tracker,
                "failed",
                (
                    invocation.error.detail
                    if invocation.error.kind == "adapter_error"
                    else "%s %s" % (stage, invocation.error.kind.replace("_", " "))
                ),
                rounds,
            )
        if invocation.budget_reason:
            if invocation.value is not None:
                field_name = {
                    "planner": "plan",
                    "executor": "execution",
                    "verifier": "verification",
                    "critic": "critique",
                    "arbiter": "arbitration",
                }[stage]
                values[field_name] = invocation.value
            rounds.append(self._round(round_index, values))
            return self._receipt(
                objective,
                context,
                self.limits,
                tracker,
                "budget_exhausted",
                "%s after %s" % (invocation.budget_reason, stage),
                rounds,
            )
        return None


__all__ = [
    "AdaptiveExecutionCallbacks",
    "AdaptiveBudgetExhausted",
    "AdaptiveExecutionContractError",
    "AdaptiveExecutionEngine",
    "AdaptiveExecutionReceipt",
    "ArbitrationRequest",
    "ArbitrationResult",
    "Artifact",
    "BudgetLimits",
    "BudgetSnapshot",
    "CritiqueRequest",
    "CritiqueResult",
    "Evidence",
    "ExecutionRequest",
    "ExecutionResult",
    "PlanResult",
    "PlanningRequest",
    "RECEIPT_SCHEMA",
    "RoundReceipt",
    "StageError",
    "Usage",
    "VerificationRequest",
    "VerificationResult",
]
