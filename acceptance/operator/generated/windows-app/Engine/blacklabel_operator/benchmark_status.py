import json
import math
from pathlib import Path
from types import SimpleNamespace

from . import benchmark_campaign as _benchmark_campaign
from .standard_benchmark import (
    EXTERNAL_NUMBER_ONE_LANES,
    HARBOR_SUITES,
    OFFICIAL_QUALITY_LANES,
    OFFICIAL_QUALITY_MINIMUM_SCORE,
    OFFICIAL_QUALITY_SCORE_SCALE,
    OFFICIAL_QUALITY_STATUS_SCHEMA,
    benchmark_score_claim,
    official_quality_contract,
    strict_json_loads,
)

SUITE_ORDER = (
    "harnessbench",
    "terminal-bench-current",
    "terminal-bench",
    "aider-polyglot",
    "swe-bench",
    "arc-agi-3",
)


def campaign_status(*args, **kwargs):
    return _benchmark_campaign.campaign_status(*args, **kwargs)


def load_campaign(*args, **kwargs):
    return _benchmark_campaign.load_campaign(*args, **kwargs)


def latest_receipts(benchmark_dir):
    latest = {}
    for path in Path(benchmark_dir).rglob("receipt.json"):
        try:
            receipt = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        suite = receipt.get("suite")
        if suite not in SUITE_ORDER:
            continue
        candidate = dict(receipt)
        candidate["receipt_path"] = str(path.resolve())
        current = latest.get(suite)
        if current is None or float(candidate.get("finished_at") or 0) > float(
            current.get("finished_at") or 0
        ):
            latest[suite] = candidate
    return latest


def _missing_status(suite):
    official_tasks = HARBOR_SUITES.get(suite, {}).get("official_size")
    return {
        "suite": suite,
        "evidence_status": "not_run",
        "run_kind": "not_run",
        "tested_tasks": 0,
        "passed_selected_tasks": 0,
        "official_tasks": official_tasks,
        "coverage_percent": 0.0 if official_tasks else None,
        "benchmark_score": None,
        "leaderboard_score": None,
        "internal_release_certified": False,
        "number_one": False,
        "statement": "No benchmark receipt exists.",
        "receipt_path": None,
    }


def _harnessbench_status(receipt):
    result = receipt.get("result") or {}
    passed = int(result.get("passed") or 0)
    total = int(result.get("total") or 0)
    return {
        "suite": "harnessbench",
        "evidence_status": receipt.get("status"),
        "run_kind": "internal_acceptance",
        "tested_tasks": total,
        "passed_selected_tasks": passed,
        "official_tasks": None,
        "coverage_percent": None,
        "benchmark_score": None,
        "leaderboard_score": None,
        "internal_release_certified": False,
        "number_one": False,
        "statement": (
            "Internal Operator acceptance cases; not comparable to a public "
            "benchmark or leaderboard."
        ),
        "receipt_path": receipt.get("receipt_path"),
    }


def _standard_status(suite, receipt):
    scope = receipt.get("scope") or {}
    result = receipt.get("result") or {}
    claim = benchmark_score_claim(
        suite,
        requested_tasks=result.get("requested_tasks", scope.get("n_tasks", 0)),
        completed_tasks=result.get("completed_tasks", 0),
        passed_tasks=result.get("passed_tasks", 0),
        errored_tasks=result.get("errored_tasks", 0),
        include_tasks=scope.get("include_task"),
        dataset=scope.get("dataset"),
        attempts=scope.get("n_attempts"),
    )
    return {
        "suite": suite,
        "evidence_status": receipt.get("status"),
        "run_kind": claim["run_kind"],
        "tested_tasks": claim["completed_tasks"],
        "passed_selected_tasks": claim["passed_tasks"],
        "official_tasks": claim["official_tasks"],
        "official_trials": claim["official_trials"],
        "coverage_percent": claim["coverage_percent"],
        "benchmark_score": claim["benchmark_score"],
        "leaderboard_score": None,
        "comparison_numeric_target_met": claim[
            "comparison_numeric_target_met"
        ],
        "leaderboard_submission_verified": False,
        "internal_release_certified": False,
        "number_one": False,
        "statement": claim["statement"],
        "receipt_path": receipt.get("receipt_path"),
    }


def _arc_status(receipt):
    scope = receipt.get("scope") or {}
    result = receipt.get("result") or {}
    recordings = result.get("recordings") or []
    tested = len(recordings)
    benchmark_score = result.get("benchmark_score")
    if (
        scope.get("run_kind") == "full"
        and scope.get("score_eligible")
        and isinstance(benchmark_score, (int, float))
    ):
        run_kind = "full"
        statement = result.get("statement")
        tested = int(result.get("completed_games") or tested)
    elif receipt.get("status") == "blocked" and not tested:
        run_kind = "blocked"
        statement = result.get("reason") or "ARC-AGI-3 run was blocked."
    else:
        run_kind = "smoke"
        statement = (
            "Single-game ARC-AGI-3 evidence is a smoke run, not a full "
            "benchmark or leaderboard score."
        )
    return {
        "suite": "arc-agi-3",
        "evidence_status": receipt.get("status"),
        "run_kind": run_kind,
        "tested_tasks": tested,
        "passed_selected_tasks": (
            tested if run_kind == "full" else 1 if tested and result.get("won") else 0
        ),
        "official_tasks": scope.get("official_games", 25),
        "coverage_percent": round(100.0 * tested / 25, 4) if tested else 0.0,
        "benchmark_score": benchmark_score if run_kind == "full" else None,
        "leaderboard_score": None,
        "stock_leaderboard_comparable": False,
        "leaderboard_submission_verified": False,
        "internal_release_certified": False,
        "number_one": False,
        "statement": statement,
        "game": scope.get("game"),
        "receipt_path": receipt.get("receipt_path"),
    }


def _diagnostic_official_quality():
    lanes = [
        {
            "lane": lane,
            "display_name": contract["display_name"],
            "protocol": contract["protocol"],
            "organizer": contract["organizer"],
            "score": None,
            "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
            "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
            "status": "unverified_latest_receipt",
            "state": "unverified_latest_receipt",
            "organizer_verified": False,
            "verified": False,
            "score_meets_minimum": False,
            "provenance_ready": contract.get("provenance_ready") is True,
            "provenance_blockers": list(contract.get("provenance_blockers") or []),
            "reason": (
                "latest local receipts are not organizer-verified official scores"
            ),
        }
        for lane, contract in OFFICIAL_QUALITY_LANES.items()
    ]
    missing = [
        "organizer_verification:%s:unverified_latest_receipt" % lane
        for lane in OFFICIAL_QUALITY_LANES
    ]
    return {
        "schema": OFFICIAL_QUALITY_STATUS_SCHEMA,
        "scope": "latest_receipts_diagnostic_only",
        "state": "diagnostic_only",
        "good": False,
        "evidence_good": False,
        "historical_evidence_good": False,
        "contract_embedded": False,
        "legacy_non_certifying": True,
        "required": len(OFFICIAL_QUALITY_LANES),
        "verified": 0,
        "min": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "required_lanes": len(OFFICIAL_QUALITY_LANES),
        "verified_lanes": 0,
        "qualified_lanes": 0,
        "provenance_ready_lanes": sum(
            item["provenance_ready"] for item in lanes
        ),
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "averaging_allowed": False,
        "average_score": None,
        "all_individual_scores_meet_minimum": False,
        "current_source_checked": False,
        "current_source_match": False,
        "current_operator_source": None,
        "independent_from_number_one": True,
        "missing_requirements": missing,
        "lanes": lanes,
    }


def _latest_contracted_official_quality_campaign(benchmark_dir):
    candidates = []
    expected = official_quality_contract()
    root = Path(benchmark_dir) / "campaigns"
    for path in root.glob("*/campaign.json"):
        try:
            payload = strict_json_loads(path.read_text(encoding="utf-8"))
            created_at = payload.get("created_at")
            if (
                isinstance(created_at, bool)
                or not isinstance(created_at, (int, float))
                or not math.isfinite(float(created_at))
                or (payload.get("certification_contracts") or {}).get(
                    "official_quality"
                )
                != expected
            ):
                continue
            candidates.append(
                (float(created_at), str(payload.get("id") or ""), path.parent)
            )
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            continue
    return max(candidates)[2] if candidates else None


def benchmark_status(
    benchmark_dir, settings=None, current_operator_source=None
):
    receipts = latest_receipts(benchmark_dir)
    suites = []
    for suite in SUITE_ORDER:
        receipt = receipts.get(suite)
        if receipt is None:
            suites.append(_missing_status(suite))
        elif suite == "harnessbench":
            suites.append(_harnessbench_status(receipt))
        elif suite == "arc-agi-3":
            suites.append(_arc_status(receipt))
        else:
            suites.append(_standard_status(suite, receipt))
    full_scores = {
        item["suite"]: item["benchmark_score"]
        for item in suites
        if item["benchmark_score"] is not None
    }
    missing_external = [
        "campaign_bound_internal_release_certification",
        *(
            "verified_external_evidence:%s" % lane
            for lane in EXTERNAL_NUMBER_ONE_LANES
        ),
    ]
    official_quality = _diagnostic_official_quality()
    official_quality_campaign = None
    selected_campaign = _latest_contracted_official_quality_campaign(benchmark_dir)
    if selected_campaign is not None:
        try:
            campaign = load_campaign(selected_campaign)
            effective_settings = settings or SimpleNamespace(
                benchmark_dir=Path(benchmark_dir)
            )
            evaluated = campaign_status(
                effective_settings,
                selected_campaign,
                current_operator_source=current_operator_source,
            )
            official_quality = evaluated["official_quality"]
            official_quality_campaign = {
                "id": campaign["id"],
                "path": str(selected_campaign.resolve()),
                "created_at": campaign["created_at"],
            }
        except (OSError, TypeError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
            official_quality["campaign_evaluation_error"] = str(exc)
    return {
        "schema": "black-label-operator/benchmark-status-v2",
        "statement": (
            "Black Label Operator has no full public benchmark score yet."
            if not full_scores
            else "Full local benchmark scores exist only where listed."
        ),
        "full_benchmark_scores": full_scores,
        "leaderboard_scores": {},
        "certification_scope": "latest_receipts_diagnostic_only",
        "internal_release_certified": False,
        "certified": False,
        "number_one": False,
        "number_one_missing_requirements": missing_external,
        "official_quality": official_quality,
        "official_quality_campaign": official_quality_campaign,
        "certification": {
            "internal_release": {
                "certified": False,
                "reason": "latest receipts are not one frozen-source campaign",
            },
            "external_number_one": {
                "number_one": False,
                "verified_lanes": 0,
                "required_lanes": len(EXTERNAL_NUMBER_ONE_LANES),
                "missing_requirements": missing_external,
            },
            "official_quality": official_quality,
        },
        "suites": suites,
    }


def render_status(payload):
    lines = [payload["statement"], ""]
    official_quality = payload.get("official_quality") or {}
    lines.append("SUITE             KIND                 SELECTED  COVERAGE   SCORE")
    for item in payload["suites"]:
        selected = "%d/%d" % (
            item["passed_selected_tasks"],
            item["tested_tasks"],
        )
        coverage = (
            "%.4f%%" % item["coverage_percent"]
            if item["coverage_percent"] is not None
            else "n/a"
        )
        score = (
            "%.4f" % item["benchmark_score"]
            if item["benchmark_score"] is not None
            else "n/a"
        )
        lines.append(
            "%-17s %-20s %-9s %-10s %s"
            % (item["suite"], item["run_kind"], selected, coverage, score)
        )
    lines.extend(
        [
            "",
            "Official quality good: %s (%d/%d organizer-verified scores; each must be >= %.1f/100; no averaging)"
            % (
                "yes" if official_quality.get("good") is True else "no",
                official_quality.get(
                    "verified_lanes", official_quality.get("verified", 0)
                ),
                official_quality.get(
                    "required_lanes",
                    official_quality.get("required", len(OFFICIAL_QUALITY_LANES)),
                ),
                official_quality.get("minimum_score", OFFICIAL_QUALITY_MINIMUM_SCORE),
            ),
            "SELECTED is selected-task evidence only. SCORE is emitted only "
            "after a complete official task set.",
            "This latest-receipt view cannot certify a release or a number-one "
            "claim; use a frozen campaign plus verified external receipts.",
            "Local receipts and converted pass counts cannot satisfy official quality.",
        ]
    )
    return "\n".join(lines)
