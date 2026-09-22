"""Fail-closed epistemic snapshots for ARC-AGI-3 planning.

The planner's Markdown playbook is useful working memory, but it is not evidence.
This module binds that playbook to a structured hypothesis ledger and to the exact
authoritative observation-receipt tail that justified it.  A sealed snapshot is
content addressed and, when a previous snapshot is supplied, forms a causal
chain whose evidence and hypothesis state transitions cannot be rewritten.
"""

import copy
import hashlib
import json
import os
import re
import uuid
from pathlib import Path


ARC_EPISTEMIC_SCHEMA_VERSION = 1
ARC_EPISTEMIC_KIND = "black-label-operator/arc-epistemic-snapshot-v1"
ARC_HYPOTHESIS_STATES = frozenset(("candidate", "confirmed", "falsified"))

_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_ACTION_NAMES = frozenset(
    ("RESET", "ACTION1", "ACTION2", "ACTION3", "ACTION4", "ACTION5", "ACTION6", "ACTION7")
)
_ENVELOPE_KEYS = frozenset(("schema_version", "kind", "body", "snapshot_sha256"))
_BODY_KEYS = frozenset(
    (
        "game_id",
        "updated_through_receipt",
        "parent_snapshot_sha256",
        "hypotheses",
        "playbook",
    )
)
_HYPOTHESIS_KEYS = frozenset(
    (
        "id",
        "claim",
        "state",
        "updated_through_receipt",
        "supporting_receipts",
        "contradicting_receipts",
        "discriminating_prediction",
        "replay_evidence",
    )
)
_PREDICTION_KEYS = frozenset(("action", "expected", "distinguishes_from"))
_EXPECTED_KEYS = frozenset(("state", "levels_completed", "cells", "diff"))
_REPLAY_KEYS = frozenset(("before_receipt", "after_receipt"))
_PLAYBOOK_KEYS = frozenset(
    (
        "format",
        "content",
        "content_sha256",
        "updated_through_receipt",
        "hypothesis_ids",
    )
)
_LEGAL_TRANSITIONS = {
    "candidate": frozenset(("candidate", "confirmed", "falsified")),
    "confirmed": frozenset(("confirmed", "falsified")),
    "falsified": frozenset(("falsified",)),
}


class ArcEpistemicValidationError(ValueError):
    """Raised when an ARC epistemic snapshot cannot be proven from receipts."""


def _canonical_json(value):
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ArcEpistemicValidationError(
            "epistemic material is not canonical JSON: %s" % exc
        ) from exc


def canonical_sha256(value):
    """Return the canonical JSON SHA-256 used by receipts and snapshots."""

    return hashlib.sha256(_canonical_json(value)).hexdigest()


def _require_object(value, label):
    if not isinstance(value, dict):
        raise ArcEpistemicValidationError("%s must be an object" % label)
    return value


def _require_exact_keys(value, expected, label):
    actual = frozenset(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise ArcEpistemicValidationError(
            "%s keys are invalid (missing=%s unknown=%s)"
            % (label, missing, unknown)
        )


def _require_nonempty_string(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ArcEpistemicValidationError("%s must be a non-empty string" % label)
    return value


def _require_sha256(value, label, allow_none=False):
    if allow_none and value is None:
        return None
    if not isinstance(value, str) or not _SHA256_PATTERN.fullmatch(value):
        raise ArcEpistemicValidationError("%s must be a lowercase SHA-256" % label)
    return value


def _require_unique_sha_list(value, label, receipt_index):
    if not isinstance(value, list):
        raise ArcEpistemicValidationError("%s must be a list" % label)
    if len(value) != len(set(value)):
        raise ArcEpistemicValidationError("%s contains duplicate receipts" % label)
    for receipt_id in value:
        _require_sha256(receipt_id, "%s receipt" % label)
        if receipt_id not in receipt_index:
            raise ArcEpistemicValidationError(
                "%s references a non-authoritative receipt" % label
            )
    return value


def _validate_action(value, label):
    action = _require_object(value, label)
    name = action.get("action")
    if not isinstance(name, str) or name not in _ACTION_NAMES:
        raise ArcEpistemicValidationError("%s has an invalid ARC action" % label)
    allowed = {"action", "x", "y"} if name == "ACTION6" else {"action"}
    if set(action) != allowed:
        raise ArcEpistemicValidationError("%s action fields are invalid" % label)
    if name == "ACTION6":
        for coordinate in ("x", "y"):
            value = action[coordinate]
            if type(value) is not int or not 0 <= value <= 63:
                raise ArcEpistemicValidationError(
                    "%s %s must be an integer in 0..63" % (label, coordinate)
                )
    return action


def _executable_action(value, label):
    """Extract the executable portion from an authoritative action receipt."""

    action = _require_object(value, label)
    name = action.get("action")
    projected = {"action": name}
    if name == "ACTION6":
        projected.update({"x": action.get("x"), "y": action.get("y")})
    return _validate_action(projected, label)


def _validate_frame(value, label):
    if not isinstance(value, list) or not value:
        raise ArcEpistemicValidationError("%s must be a non-empty row list" % label)
    width = None
    for row in value:
        if not isinstance(row, list) or not row:
            raise ArcEpistemicValidationError("%s contains an invalid row" % label)
        if width is None:
            width = len(row)
        elif len(row) != width:
            raise ArcEpistemicValidationError("%s must be rectangular" % label)
        if any(type(cell) is not int for cell in row):
            raise ArcEpistemicValidationError("%s cells must be integers" % label)
    return value


def _validate_authoritative_receipts(authoritative_receipts, current_receipt_id):
    if not isinstance(authoritative_receipts, (list, tuple)) or not authoritative_receipts:
        raise ArcEpistemicValidationError(
            "authoritative_receipts must be a non-empty ordered sequence"
        )
    _require_sha256(current_receipt_id, "current_receipt_id")
    receipts = []
    receipt_index = {}
    previous = None
    game_id = None
    for index, raw_receipt in enumerate(authoritative_receipts):
        receipt = _require_object(raw_receipt, "authoritative receipt %d" % index)
        claimed = _require_sha256(
            receipt.get("receipt_sha256"),
            "authoritative receipt %d receipt_sha256" % index,
        )
        material = dict(receipt)
        material.pop("receipt_sha256", None)
        if canonical_sha256(material) != claimed:
            raise ArcEpistemicValidationError(
                "authoritative receipt %d has an invalid content hash" % index
            )
        if receipt.get("ledger_schema") != 1:
            raise ArcEpistemicValidationError(
                "authoritative receipt %d has an unsupported ledger schema" % index
            )
        if receipt.get("previous_receipt_sha256") != previous:
            raise ArcEpistemicValidationError(
                "authoritative receipt %d breaks the causal receipt chain" % index
            )
        if claimed in receipt_index:
            raise ArcEpistemicValidationError("authoritative receipts contain a duplicate")
        receipt_game = _require_nonempty_string(
            receipt.get("game_id"), "authoritative receipt %d game_id" % index
        )
        if game_id is None:
            game_id = receipt_game
        elif receipt_game != game_id:
            raise ArcEpistemicValidationError(
                "authoritative receipts mix ARC game identities"
            )
        if receipt.get("step") != index:
            raise ArcEpistemicValidationError(
                "authoritative receipt steps are not contiguous"
            )
        _require_nonempty_string(
            receipt.get("state"), "authoritative receipt %d state" % index
        )
        levels = receipt.get("levels_completed")
        if type(levels) is not int or levels < 0:
            raise ArcEpistemicValidationError(
                "authoritative receipt %d levels_completed is invalid" % index
            )
        _validate_frame(receipt.get("frame"), "authoritative receipt %d frame" % index)
        action = _require_object(
            receipt.get("action"), "authoritative receipt %d action" % index
        )
        if index == 0:
            if action != {"action": "INIT"}:
                raise ArcEpistemicValidationError(
                    "the first authoritative receipt must be the INIT observation"
                )
        elif action != {"action": "UNATTRIBUTED"}:
            _executable_action(action, "authoritative receipt %d action" % index)
        receipt_index[claimed] = receipt
        receipts.append(receipt)
        previous = claimed
    if previous != current_receipt_id:
        raise ArcEpistemicValidationError(
            "current_receipt_id is not the authoritative receipt tail"
        )
    return receipts, receipt_index, game_id


def _validate_expected(value, label):
    expected = _require_object(value, label)
    unknown = set(expected) - _EXPECTED_KEYS
    if unknown or not expected:
        raise ArcEpistemicValidationError(
            "%s must contain only non-empty ARC observation expectations" % label
        )
    if "state" in expected:
        _require_nonempty_string(expected["state"], "%s state" % label)
    if "levels_completed" in expected:
        levels = expected["levels_completed"]
        if type(levels) is not int or levels < 0:
            raise ArcEpistemicValidationError(
                "%s levels_completed must be a non-negative integer" % label
            )
    cells = expected.get("cells", [])
    if not isinstance(cells, list):
        raise ArcEpistemicValidationError("%s cells must be a list" % label)
    seen_cells = set()
    for cell in cells:
        if (
            not isinstance(cell, list)
            or len(cell) != 3
            or any(type(item) is not int for item in cell)
            or not 0 <= cell[0] <= 63
            or not 0 <= cell[1] <= 63
        ):
            raise ArcEpistemicValidationError(
                "%s cells must be integer [x,y,color] triples" % label
            )
        coordinate = (cell[0], cell[1])
        if coordinate in seen_cells:
            raise ArcEpistemicValidationError(
                "%s contains duplicate cell coordinates" % label
            )
        seen_cells.add(coordinate)
    diffs = expected.get("diff", [])
    if not isinstance(diffs, list):
        raise ArcEpistemicValidationError("%s diff must be a list" % label)
    seen_diffs = set()
    for change in diffs:
        if (
            not isinstance(change, list)
            or len(change) != 4
            or any(type(item) is not int for item in change)
            or not 0 <= change[0] <= 63
            or not 0 <= change[1] <= 63
        ):
            raise ArcEpistemicValidationError(
                "%s diff must contain integer [x,y,before,after] rows" % label
            )
        coordinate = (change[0], change[1])
        if coordinate in seen_diffs:
            raise ArcEpistemicValidationError(
                "%s contains duplicate diff coordinates" % label
            )
        seen_diffs.add(coordinate)
    if not any(
        key in expected and (key not in ("cells", "diff") or expected[key])
        for key in _EXPECTED_KEYS
    ):
        raise ArcEpistemicValidationError("%s has no discriminating outcome" % label)
    return expected


def _prediction_matches(prediction, before, after):
    del before  # The receipt-chain adjacency proves the transition's start state.
    if _executable_action(after.get("action"), "replay observation action") != prediction[
        "action"
    ]:
        return False
    expected = prediction["expected"]
    if "state" in expected and after.get("state") != expected["state"]:
        return False
    if (
        "levels_completed" in expected
        and after.get("levels_completed") != expected["levels_completed"]
    ):
        return False
    frame = after["frame"]
    for x, y, color in expected.get("cells", []):
        if y >= len(frame) or x >= len(frame[y]) or frame[y][x] != color:
            return False
    observed_diff = {
        tuple(change)
        for change in after.get("diff", [])
        if isinstance(change, list) and len(change) == 4
    }
    if any(tuple(change) not in observed_diff for change in expected.get("diff", [])):
        return False
    return True


def _trusted_causal_match(after, hypothesis_id):
    causal = after.get("causal_outcome")
    if not isinstance(causal, dict):
        return False
    required = {
        "plan_sha256",
        "world_model_sha256",
        "hypothesis_id",
        "prediction_index",
        "action_receipt_id",
        "predicted_frame_sha256",
        "observed_frame_sha256",
        "observed_observation_sha256",
        "matched",
        "errors",
    }
    if set(causal) != required:
        return False
    digests = (
        causal["plan_sha256"],
        causal["world_model_sha256"],
        causal["predicted_frame_sha256"],
        causal["observed_frame_sha256"],
        causal["observed_observation_sha256"],
    )
    return bool(
        causal["matched"] is True
        and causal["hypothesis_id"] == hypothesis_id
        and causal["action_receipt_id"] == after.get("action_receipt_id")
        and type(causal["prediction_index"]) is int
        and causal["prediction_index"] >= 0
        and all(isinstance(value, str) and _SHA256_PATTERN.fullmatch(value) for value in digests)
        and causal["predicted_frame_sha256"] == causal["observed_frame_sha256"]
        and causal["errors"] == []
    )


def _validate_prediction(value, label, hypothesis_ids):
    prediction = _require_object(value, label)
    _require_exact_keys(prediction, _PREDICTION_KEYS, label)
    _validate_action(prediction["action"], "%s action" % label)
    _validate_expected(prediction["expected"], "%s expected" % label)
    targets = prediction["distinguishes_from"]
    if not isinstance(targets, list) or not targets:
        raise ArcEpistemicValidationError(
            "%s must distinguish this hypothesis from another" % label
        )
    if len(targets) != len(set(targets)):
        raise ArcEpistemicValidationError(
            "%s contains duplicate hypothesis targets" % label
        )
    if any(target not in hypothesis_ids for target in targets):
        raise ArcEpistemicValidationError(
            "%s references an unknown hypothesis" % label
        )
    return prediction


def _validate_replay(value, label, receipt_index):
    replay = _require_object(value, label)
    _require_exact_keys(replay, _REPLAY_KEYS, label)
    before_id = _require_sha256(replay["before_receipt"], "%s before_receipt" % label)
    after_id = _require_sha256(replay["after_receipt"], "%s after_receipt" % label)
    if before_id not in receipt_index or after_id not in receipt_index:
        raise ArcEpistemicValidationError(
            "%s references non-authoritative replay evidence" % label
        )
    after = receipt_index[after_id]
    if after.get("previous_receipt_sha256") != before_id:
        raise ArcEpistemicValidationError(
            "%s receipts are not one authoritative transition" % label
        )
    return replay


def _validate_hypotheses(hypotheses, receipt_index, current_receipt_id):
    if not isinstance(hypotheses, list) or len(hypotheses) < 2:
        raise ArcEpistemicValidationError(
            "epistemic snapshots require at least two competing hypotheses"
        )
    identifiers = []
    for index, hypothesis in enumerate(hypotheses):
        _require_object(hypothesis, "hypothesis %d" % index)
        _require_exact_keys(hypothesis, _HYPOTHESIS_KEYS, "hypothesis %d" % index)
        identifiers.append(
            _require_nonempty_string(hypothesis["id"], "hypothesis %d id" % index)
        )
    if len(identifiers) != len(set(identifiers)):
        raise ArcEpistemicValidationError("hypothesis IDs must be unique")
    hypothesis_ids = frozenset(identifiers)
    by_id = {}
    replay_results = {}
    for index, hypothesis in enumerate(hypotheses):
        label = "hypothesis %s" % hypothesis["id"]
        _require_nonempty_string(hypothesis["claim"], "%s claim" % label)
        state = hypothesis["state"]
        if state not in ARC_HYPOTHESIS_STATES:
            raise ArcEpistemicValidationError("%s state is invalid" % label)
        if hypothesis["updated_through_receipt"] != current_receipt_id:
            raise ArcEpistemicValidationError(
                "%s is stale relative to the authoritative receipt tail" % label
            )
        supporting = _require_unique_sha_list(
            hypothesis["supporting_receipts"],
            "%s supporting_receipts" % label,
            receipt_index,
        )
        contradicting = _require_unique_sha_list(
            hypothesis["contradicting_receipts"],
            "%s contradicting_receipts" % label,
            receipt_index,
        )
        if not supporting:
            raise ArcEpistemicValidationError(
                "%s needs authoritative supporting evidence" % label
            )
        if set(supporting) & set(contradicting):
            raise ArcEpistemicValidationError(
                "%s uses one receipt as both support and contradiction" % label
            )
        prediction = _validate_prediction(
            hypothesis["discriminating_prediction"],
            "%s discriminating_prediction" % label,
            hypothesis_ids,
        )
        if hypothesis["id"] in prediction["distinguishes_from"]:
            raise ArcEpistemicValidationError(
                "%s prediction cannot distinguish itself" % label
            )
        replays = hypothesis["replay_evidence"]
        if not isinstance(replays, list):
            raise ArcEpistemicValidationError("%s replay_evidence must be a list" % label)
        replay_pairs = []
        matches = []
        for replay_index, raw_replay in enumerate(replays):
            replay = _validate_replay(
                raw_replay,
                "%s replay_evidence %d" % (label, replay_index),
                receipt_index,
            )
            pair = (replay["before_receipt"], replay["after_receipt"])
            if pair in replay_pairs:
                raise ArcEpistemicValidationError(
                    "%s contains duplicate replay evidence" % label
                )
            replay_pairs.append(pair)
            matches.append(
                _prediction_matches(
                    prediction,
                    receipt_index[pair[0]],
                    receipt_index[pair[1]],
                )
            )
        if state == "candidate":
            if contradicting or any(not matched for matched in matches):
                raise ArcEpistemicValidationError(
                    "%s is contradicted and must be falsified" % label
                )
        elif state == "confirmed":
            if contradicting or not matches or not all(matches):
                raise ArcEpistemicValidationError(
                    "%s confirmation requires matched replay evidence and no contradiction"
                    % label
                )
            after_receipts = {pair[1] for pair in replay_pairs}
            if not after_receipts.issubset(set(supporting)):
                raise ArcEpistemicValidationError(
                    "%s confirmed replay receipts must also be supporting receipts" % label
                )
            if not any(
                _trusted_causal_match(receipt_index[pair[1]], hypothesis["id"])
                for pair in replay_pairs
            ):
                raise ArcEpistemicValidationError(
                    "%s confirmation requires a matching trusted causal outcome"
                    % label
                )
        else:
            mismatched = {
                replay_pairs[item][1]
                for item, matched in enumerate(matches)
                if not matched
            }
            if not contradicting or not mismatched:
                raise ArcEpistemicValidationError(
                    "%s falsification requires an observed prediction contradiction" % label
                )
            if not mismatched.issubset(set(contradicting)):
                raise ArcEpistemicValidationError(
                    "%s mismatched replay receipts must be contradicting receipts" % label
                )
        by_id[hypothesis["id"]] = hypothesis
        replay_results[hypothesis["id"]] = tuple(matches)

    for hypothesis_id, hypothesis in by_id.items():
        prediction = hypothesis["discriminating_prediction"]
        for target_id in prediction["distinguishes_from"]:
            target_prediction = by_id[target_id]["discriminating_prediction"]
            if hypothesis_id not in target_prediction["distinguishes_from"]:
                raise ArcEpistemicValidationError(
                    "discriminating prediction links must be reciprocal"
                )
            if prediction["action"] != target_prediction["action"]:
                raise ArcEpistemicValidationError(
                    "paired hypotheses must predict different outcomes for one action"
                )
            if prediction["expected"] == target_prediction["expected"]:
                raise ArcEpistemicValidationError(
                    "paired hypotheses have no discriminating outcome"
                )
    return by_id, replay_results


def _validate_playbook(playbook, current_receipt_id, hypothesis_ids):
    playbook = _require_object(playbook, "playbook")
    _require_exact_keys(playbook, _PLAYBOOK_KEYS, "playbook")
    if playbook["format"] != "markdown":
        raise ArcEpistemicValidationError("playbook format must be markdown")
    content = _require_nonempty_string(playbook["content"], "playbook content")
    claimed = _require_sha256(playbook["content_sha256"], "playbook content_sha256")
    actual = hashlib.sha256(content.encode("utf-8")).hexdigest()
    if claimed != actual:
        raise ArcEpistemicValidationError("playbook content hash mismatch")
    if playbook["updated_through_receipt"] != current_receipt_id:
        raise ArcEpistemicValidationError(
            "playbook is stale relative to the authoritative receipt tail"
        )
    if playbook["hypothesis_ids"] != sorted(hypothesis_ids):
        raise ArcEpistemicValidationError(
            "playbook hypothesis IDs do not match the hypothesis ledger"
        )


def _validate_envelope(snapshot):
    snapshot = _require_object(snapshot, "epistemic snapshot")
    _require_exact_keys(snapshot, _ENVELOPE_KEYS, "epistemic snapshot")
    if snapshot["schema_version"] != ARC_EPISTEMIC_SCHEMA_VERSION:
        raise ArcEpistemicValidationError("epistemic snapshot schema is unsupported")
    if snapshot["kind"] != ARC_EPISTEMIC_KIND:
        raise ArcEpistemicValidationError("epistemic snapshot kind is invalid")
    body = _require_object(snapshot["body"], "epistemic snapshot body")
    _require_exact_keys(body, _BODY_KEYS, "epistemic snapshot body")
    claimed = _require_sha256(snapshot["snapshot_sha256"], "snapshot_sha256")
    material = {
        "schema_version": snapshot["schema_version"],
        "kind": snapshot["kind"],
        "body": body,
    }
    if canonical_sha256(material) != claimed:
        raise ArcEpistemicValidationError("epistemic snapshot content hash mismatch")
    return body


def _validate_causal_transition(previous_snapshot, snapshot, receipt_order):
    previous_body = _validate_envelope(previous_snapshot)
    body = snapshot["body"]
    if body["parent_snapshot_sha256"] != previous_snapshot["snapshot_sha256"]:
        raise ArcEpistemicValidationError("epistemic snapshot parent hash mismatch")
    if previous_body["game_id"] != body["game_id"]:
        raise ArcEpistemicValidationError("epistemic snapshots mix ARC game identities")
    previous_receipt = previous_body["updated_through_receipt"]
    current_receipt = body["updated_through_receipt"]
    if previous_receipt not in receipt_order:
        raise ArcEpistemicValidationError(
            "previous snapshot receipt is not authoritative"
        )
    if receipt_order[previous_receipt] >= receipt_order[current_receipt]:
        raise ArcEpistemicValidationError(
            "epistemic snapshot did not advance to new authoritative evidence"
        )

    previous_hypotheses = {
        hypothesis["id"]: hypothesis for hypothesis in previous_body["hypotheses"]
    }
    current_hypotheses = {
        hypothesis["id"]: hypothesis for hypothesis in body["hypotheses"]
    }
    removed = set(previous_hypotheses) - set(current_hypotheses)
    if removed:
        raise ArcEpistemicValidationError(
            "causal snapshot removed hypothesis history: %s" % sorted(removed)
        )
    for hypothesis_id, before in previous_hypotheses.items():
        after = current_hypotheses[hypothesis_id]
        if before["claim"] != after["claim"]:
            raise ArcEpistemicValidationError(
                "causal snapshot rewrote hypothesis %s" % hypothesis_id
            )
        if after["state"] not in _LEGAL_TRANSITIONS[before["state"]]:
            raise ArcEpistemicValidationError(
                "hypothesis %s made an illegal state transition" % hypothesis_id
            )
        for field in (
            "supporting_receipts",
            "contradicting_receipts",
            "replay_evidence",
        ):
            before_material = {canonical_sha256(item) for item in before[field]}
            after_material = {canonical_sha256(item) for item in after[field]}
            if not before_material.issubset(after_material):
                raise ArcEpistemicValidationError(
                    "causal snapshot removed %s from hypothesis %s"
                    % (field, hypothesis_id)
                )
        if (
            before["discriminating_prediction"]
            != after["discriminating_prediction"]
        ):
            raise ArcEpistemicValidationError(
                "causal snapshot rewrote hypothesis %s prediction" % hypothesis_id
            )


def validate_arc_epistemic_snapshot(
    snapshot,
    *,
    authoritative_receipts,
    current_receipt_id,
    previous_snapshot=None,
):
    """Validate a sealed ARC epistemic snapshot and return an isolated copy.

    ``authoritative_receipts`` must be the complete ordered observation ledger
    through ``current_receipt_id``.  Evidence references are accepted only when
    present in that verified ledger.  Supplying ``previous_snapshot`` also
    enforces the snapshot parent link and monotonic hypothesis history.
    """

    receipts, receipt_index, game_id = _validate_authoritative_receipts(
        authoritative_receipts, current_receipt_id
    )
    body = _validate_envelope(snapshot)
    if body["game_id"] != game_id:
        raise ArcEpistemicValidationError(
            "epistemic snapshot and authoritative receipts disagree on game_id"
        )
    if body["updated_through_receipt"] != current_receipt_id:
        raise ArcEpistemicValidationError(
            "epistemic snapshot is stale relative to the authoritative receipt tail"
        )
    _require_sha256(
        body["parent_snapshot_sha256"],
        "parent_snapshot_sha256",
        allow_none=True,
    )
    hypotheses, _replays = _validate_hypotheses(
        body["hypotheses"], receipt_index, current_receipt_id
    )
    _validate_playbook(body["playbook"], current_receipt_id, hypotheses)
    if previous_snapshot is None:
        if body["parent_snapshot_sha256"] is not None:
            raise ArcEpistemicValidationError(
                "root epistemic snapshot has an unverified parent"
            )
    else:
        previous_body = _validate_envelope(previous_snapshot)
        previous_receipt = previous_body.get("updated_through_receipt")
        receipt_order = {
            receipt["receipt_sha256"]: index for index, receipt in enumerate(receipts)
        }
        if previous_receipt not in receipt_order:
            raise ArcEpistemicValidationError(
                "previous snapshot receipt is not authoritative"
            )
        previous_prefix = receipts[: receipt_order[previous_receipt] + 1]
        previous_index = {
            receipt["receipt_sha256"]: receipt for receipt in previous_prefix
        }
        previous_hypotheses, _previous_replays = _validate_hypotheses(
            previous_body["hypotheses"], previous_index, previous_receipt
        )
        _validate_playbook(
            previous_body["playbook"], previous_receipt, previous_hypotheses
        )
        _validate_causal_transition(previous_snapshot, snapshot, receipt_order)
    return copy.deepcopy(snapshot)


def seal_arc_epistemic_snapshot(
    *,
    game_id,
    hypotheses,
    playbook_markdown,
    authoritative_receipts,
    current_receipt_id,
    previous_snapshot=None,
):
    """Create and validate a content-addressed ARC epistemic snapshot."""

    _require_nonempty_string(game_id, "game_id")
    _require_nonempty_string(playbook_markdown, "playbook_markdown")
    hypothesis_ids = []
    if isinstance(hypotheses, list):
        hypothesis_ids = sorted(
            hypothesis.get("id")
            for hypothesis in hypotheses
            if isinstance(hypothesis, dict) and isinstance(hypothesis.get("id"), str)
        )
    body = {
        "game_id": game_id,
        "updated_through_receipt": current_receipt_id,
        "parent_snapshot_sha256": (
            previous_snapshot.get("snapshot_sha256")
            if isinstance(previous_snapshot, dict)
            else None
        ),
        "hypotheses": copy.deepcopy(hypotheses),
        "playbook": {
            "format": "markdown",
            "content": playbook_markdown,
            "content_sha256": hashlib.sha256(
                playbook_markdown.encode("utf-8")
            ).hexdigest(),
            "updated_through_receipt": current_receipt_id,
            "hypothesis_ids": hypothesis_ids,
        },
    }
    material = {
        "schema_version": ARC_EPISTEMIC_SCHEMA_VERSION,
        "kind": ARC_EPISTEMIC_KIND,
        "body": body,
    }
    snapshot = dict(material)
    snapshot["snapshot_sha256"] = canonical_sha256(material)
    return validate_arc_epistemic_snapshot(
        snapshot,
        authoritative_receipts=authoritative_receipts,
        current_receipt_id=current_receipt_id,
        previous_snapshot=previous_snapshot,
    )


def write_arc_epistemic_snapshot(directory, snapshot):
    """Persist an already validated snapshot under its immutable content address."""

    _validate_envelope(snapshot)
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    path = root / (snapshot["snapshot_sha256"] + ".json")
    rendered = render_arc_epistemic_snapshot(snapshot)
    if path.exists():
        try:
            existing = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise ArcEpistemicValidationError(
                "content-addressed snapshot path is unreadable: %s" % exc
            ) from exc
        if existing != rendered:
            raise ArcEpistemicValidationError(
                "content-addressed snapshot path collision"
            )
        return path
    temporary = root / (".%s.tmp-%s" % (snapshot["snapshot_sha256"], uuid.uuid4().hex))
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(str(temporary), str(path))
        except FileExistsError:
            try:
                existing = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise ArcEpistemicValidationError(
                    "content-addressed snapshot path is unreadable: %s" % exc
                ) from exc
            if existing != rendered:
                raise ArcEpistemicValidationError(
                    "content-addressed snapshot path collision"
                )
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return path


def render_arc_epistemic_snapshot(snapshot):
    """Return the one accepted byte representation for a sealed snapshot."""

    _validate_envelope(snapshot)
    try:
        return json.dumps(
            snapshot,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        ) + "\n"
    except (TypeError, ValueError) as exc:
        raise ArcEpistemicValidationError(
            "epistemic snapshot is not canonical JSON: %s" % exc
        ) from exc
