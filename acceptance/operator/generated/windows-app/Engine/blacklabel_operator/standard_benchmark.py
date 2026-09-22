import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime
from pathlib import Path

from . import __version__
from .benchmark_receipt import command_version, require_exact_sol, write_receipt
from .codex_runner import CodexRunner
from .profiles import SOL_MODEL
from .quota import quota_info_for_trial, require_quota_available
from .settings import should_start_new_session

HARBOR_SUITES = {
    "swe-bench": {
        "dataset": "swebench-verified",
        "official_manifest_sha256": (
            "8915e69fb7e44f6b310f1d5ad267ece2946b7f11ab55232b8066d3b6d43d3c04"
        ),
        "docker_platform": "linux/amd64",
        "force_build": False,
        "official_size": 500,
        "official_attempts": 1,
    },
    "terminal-bench": {
        "dataset": "terminal-bench@2.0",
        "official_manifest_sha256": (
            "179acbbe63c0c51cd3363fcd9399b7f52438a0b6941f4ad6f8e0e21548701484"
        ),
        "docker_platform": None,
        "force_build": True,
        "official_size": 89,
        "official_attempts": 5,
    },
    "terminal-bench-current": {
        "dataset": (
            "terminal-bench/terminal-bench@"
            "sha256:39d9f44b40420cde8fdcc087579c0d72a7e14fa3656d603c3f0d22fb35e27732"
        ),
        "dataset_name": "terminal-bench/terminal-bench",
        "dataset_revision": "4",
        "dataset_digest": (
            "sha256:39d9f44b40420cde8fdcc087579c0d72a7e14fa3656d603c3f0d22fb35e27732"
        ),
        "registry_repo": (
            "https://github.com/harbor-framework/terminal-bench.git@v4.0.0"
        ),
        "repository_url": (
            "https://github.com/harbor-framework/terminal-bench.git"
        ),
        "registry_path": "tasks/dataset.toml",
        # Raw bytes of tasks/dataset.toml.  This is intentionally distinct
        # from both Harbor's resolved campaign manifest and the comparable
        # runner's canonical task-name manifest.
        "dataset_file_sha256": (
            "ecd296ba053840bd4c0068e8f84e8a6fa829d184d0fd9852becdc19f4c895fcf"
        ),
        "official_manifest_sha256": (
            "4740ea3d60ebef3843f149ee5f91be6c4caad869d4b111299b05a298c3f4e4be"
        ),
        "task_manifest_sha256": (
            "da42796db57719d0e8f6994c77231ce2ace97e5fd57fe5ca1c5eb44011bea6c5"
        ),
        "repository_tag": "v4.0.0",
        "repository_commit": "452bf305c6daa62fc59061d22133a7cbc7c1572e",
        "docker_platform": None,
        "force_build": True,
        "official_size": 66,
        "official_attempts": 5,
        "official_reasoning_effort": "xhigh",
        "custom_agent_submission_accepted": True,
    },
    "aider-polyglot": {
        "dataset": "aider-polyglot@1.0",
        "docker_platform": None,
        "force_build": True,
        "official_size": 225,
        "official_attempts": 1,
    },
}
TERMINAL_BENCH_SUITES = ("terminal-bench", "terminal-bench-current")

# These are lane-specific targets, not a blended Operator score. Historical
# comparable targets come from the release audit. The current-generation
# Terminal-Bench 4.0 is the current official lane. Historical Terminal-Bench 2
# and SWE-bench Verified remain useful diagnostics but cannot certify a current
# global number-one claim.
NUMBER_ONE_GATES = {
    "terminal-bench": {
        "lane": "strongest-maintainer-merged-terminal-bench-2-record",
        "target_passes": 401,
        "target_trials": 445,
        "comparable": True,
        "protocol": "official-harbor-89-tasks-times-5-attempts",
    },
    "terminal-bench-current": {
        "lane": "terminal-bench-4.0-current-official-leader",
        "target_passes": 176,
        "target_trials": 330,
        "comparable": True,
        "mandatory_current_generation": True,
        "protocol": (
            "pinned-v4.0.0-66-tasks-times-5-trials; official-Harbor-"
            "submission; strict-beat-current-displayed-0.53"
        ),
    },
    "aider-polyglot": {
        "lane": "stock-aider-polyglot-two-try-model-leaderboard",
        "target_passes": 199,
        "target_trials": 225,
        "comparable": False,
        "protocol": "stock-aider-runner-required; custom Harbor agents are separate",
    },
    "swe-bench": {
        "lane": "swe-bench-verified-full-pass-at-1",
        "target_passes": 398,
        "target_trials": 500,
        "comparable": True,
        "protocol": "official-verified-500-task-pass-at-1",
    },
}

# A local full-suite score and an externally verified number-one result are
# different evidence products.  Campaigns exercise Operator's internal release
# lanes above; this contract names the additional stock/standardized protocols
# and organizer receipts required before any machine-readable ``number_one``
# field may become true.
LEGACY_EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA = (
    "black-label-operator/external-number-one-evidence-v1"
)
EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA = (
    "black-label-operator/external-number-one-evidence-v2"
)
LEGACY_EXTERNAL_NUMBER_ONE_CONTRACT_SCHEMA = (
    "black-label-operator/external-number-one-contract-v1"
)
EXTERNAL_NUMBER_ONE_CONTRACT_SCHEMA = (
    "black-label-operator/external-number-one-contract-v2"
)
EXTERNAL_TARGET_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER = (
    "no lane has a contract-pinned organizer API schema or signature trust root"
)
EXTERNAL_NUMBER_ONE_LANES = {
    "terminal-bench-4-current": {
        "campaign_suite": "terminal-bench-current",
        "protocol": "official-harbor-terminal-bench-4.0-66-tasks-5-attempts",
        "score_kind": "passes",
        "target_operator": "gte",
        "target_value": 176,
        "leader_value": 0.53,
        "leader_value_kind": "displayed_resolution_rate",
        "total": 330,
        "organizer": "Harbor",
        "target_source_url": (
            "https://hub.harborframework.com/jobs/"
            "a1ac63a1-8a9b-4bc7-9906-2b63657ee1c2"
        ),
        "harness_repository": (
            "https://github.com/harbor-framework/terminal-bench.git"
        ),
        "harness_revision": "452bf305c6daa62fc59061d22133a7cbc7c1572e",
        "dataset_repository": (
            "https://github.com/harbor-framework/terminal-bench.git"
        ),
        "dataset_revision": "452bf305c6daa62fc59061d22133a7cbc7c1572e",
        "dataset_file_sha256": (
            "ecd296ba053840bd4c0068e8f84e8a6fa829d184d0fd9852becdc19f4c895fcf"
        ),
        "task_manifest_sha256": (
            "da42796db57719d0e8f6994c77231ce2ace97e5fd57fe5ca1c5eb44011bea6c5"
        ),
        "submission_hosts": [
            "hub.harborframework.com",
            "huggingface.co",
            "github.com",
            "tbench.ai",
            "www.tbench.ai",
        ],
        "requires_stock_or_standardized_runner": True,
        "claim_policy": "strictly_beats_captured_leader",
    },
    "aider-polyglot-stock": {
        "campaign_suite": None,
        "protocol": "stock-aider-polyglot-225-exercises-two-tries",
        "score_kind": "passes",
        "target_operator": "gte",
        "target_value": 199,
        "leader_value": 198,
        "leader_value_kind": "passes_after_two_tries",
        "total": 225,
        "organizer": "Aider",
        "target_source_url": "https://aider.chat/docs/leaderboards/",
        "runner_repository": "https://github.com/Aider-AI/aider.git",
        "runner_revision": "5dc9490bb35f9729ef2c95d00a19ccd30c26339c",
        "dataset_repository": (
            "https://github.com/Aider-AI/polyglot-benchmark.git"
        ),
        "dataset_revision": "7e0611e77b54e2dea774cdc0aa00cf9f7ed6144f",
        "submission_hosts": ["aider.chat", "www.aider.chat", "github.com"],
        "requires_stock_or_standardized_runner": True,
        "claim_policy": "strictly_beats_captured_leader",
    },
    "swe-bench-pro-public": {
        "campaign_suite": None,
        "protocol": "official-scale-swe-bench-pro-public-731-task-pass-at-1",
        "score_kind": "passes",
        "target_operator": "gte",
        "target_value": 451,
        "leader_value": 61.50,
        "leader_value_kind": "displayed_resolve_percent",
        "total": 731,
        "organizer": "Scale SWE-bench Pro",
        "target_source_url": "https://labs.scale.com/leaderboard/swe_bench_pro_public",
        "harness_repository": (
            "https://github.com/scaleapi/SWE-bench_Pro-os.git"
        ),
        "harness_revision": "ca10a60a5fcae51e6948ffe1485d4153d421e6c5",
        "dataset_repository": (
            "https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro"
        ),
        "dataset_revision": "7ab5114912baf22bb098818e604c02fe7ad2c11f",
        "evaluator_sha256": (
            "bb5d4c5486be296e464e695df3747064aaa3bb197394bc6d39980634afec2034"
        ),
        "official_raw_sha256": (
            "b5b2462bfbf5aeb2cb7ba7d215778a1768b85f9d7ad7f748546c7f80a0ad1510"
        ),
        "dataset_parquet_sha256": (
            "c8cd7115496ad4e9a8b21d088cef576a65bf821bb542b24336f13f714cef13f8"
        ),
        "task_manifest_sha256": (
            "3d2dc2ea479bcd7833a3b1ce7f77e9d6409e0aee14a87fb81d9dd4b9d5aad0f3"
        ),
        "submission_hosts": [
            "github.com",
            "huggingface.co",
            "labs.scale.com",
            "scale.com",
        ],
        "requires_stock_or_standardized_runner": True,
        "claim_policy": "strictly_beats_captured_leader",
    },
    "arc-agi-3-standardized": {
        "campaign_suite": None,
        "protocol": (
            "official-arc-agi-3-standardized-general-purpose-model-"
            "25-environments"
        ),
        "score_kind": "score",
        "target_operator": "gte",
        "target_value": 100.0,
        "leader_value": 100.0,
        "leader_value_kind": "score_out_of_100",
        "total": 25,
        "organizer": "ARC Prize",
        "target_source_url": "https://arcprize.org/leaderboard/community",
        "runner_repository": (
            "https://github.com/arcprize/arc-agi-3-benchmarking.git"
        ),
        "runner_revision": "86d72170ce3155551712a9fafd290bab471d6eee",
        "submission_hosts": ["arcprize.org", "www.arcprize.org"],
        "requires_stock_or_standardized_runner": True,
        "claim_policy": "tie_for_number_one_only",
    },
}

# ``official_quality`` is deliberately independent from the take-first
# ``number_one`` claim above.  It is a five-lane product-quality definition:
# every lane must carry a score reported by, and verifiably attributable to,
# that lane's organizer on the common 0-100 scale.  Local pass counts are not
# converted into official-quality scores.
OFFICIAL_QUALITY_CONTRACT_SCHEMA = (
    "black-label-operator/official-quality-contract-v1"
)
OFFICIAL_QUALITY_EVIDENCE_SCHEMA = (
    "black-label-operator/official-quality-evidence-v1"
)
OFFICIAL_QUALITY_STATUS_SCHEMA = (
    "black-label-operator/official-quality-status-v1"
)
OFFICIAL_QUALITY_MINIMUM_SCORE = 91.0
OFFICIAL_QUALITY_SCORE_SCALE = 100
OFFICIAL_QUALITY_EVIDENCE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
OFFICIAL_QUALITY_FUTURE_CLOCK_SKEW_SECONDS = 5 * 60
OFFICIAL_QUALITY_LANES = {
    "terminal-bench-2-official": {
        "display_name": "Terminal-Bench 2",
        "campaign_suite": "terminal-bench",
        "protocol": "official-harbor-terminal-bench-2.0-89-tasks-5-attempts",
        "organizer": "Harbor",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "source_identity": {
            "dataset": "terminal-bench@2.0",
            "harbor_manifest_sha256": (
                "179acbbe63c0c51cd3363fcd9399b7f52438a0b6941f4ad6f8e0e21548701484"
            ),
            "official_tasks": 89,
            "official_attempts": 5,
            "official_trials": 445,
        },
        "score_scope": {
            "run_kind": "full_official_suite",
            "selection": "all",
            "dataset": "terminal-bench@2.0",
            "official_tasks": 89,
            "official_attempts": 5,
            "official_trials": 445,
            "execution_config": {
                "reasoning_effort": "max",
                "review_passes": 2,
            },
        },
        "provenance_ready": False,
        "provenance_blockers": [
            "Terminal-Bench 2 evaluator and runner revision are not contract-pinned"
        ],
        "organizer_verification": {
            "required": True,
            "method": "organizer-signed-score-receipt-v1",
            "signature_algorithm": "openssl-dgst-sha256",
            "receipt_schema": "harbor/official-score-receipt-v1",
            "trust_root_id": None,
            "trust_root_sha256": None,
            "trusted_hosts": [
                "hub.harborframework.com",
                "tbench.ai",
                "www.tbench.ai",
            ],
            "accepted_statuses": ["accepted", "published"],
            "caller_assertions_accepted": False,
            "locally_derived_scores_accepted": False,
            "closed_schema_required": True,
        },
    },
    "terminal-bench-4-current": {
        "display_name": "Terminal-Bench 4",
        "campaign_suite": "terminal-bench-current",
        "protocol": "official-harbor-terminal-bench-4.0-66-tasks-5-attempts",
        "organizer": "Harbor",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "source_identity": {
            "dataset": (
                "terminal-bench/terminal-bench@"
                "sha256:39d9f44b40420cde8fdcc087579c0d72a7e14fa3656d603c3f0d22fb35e27732"
            ),
            "repository": "https://github.com/harbor-framework/terminal-bench.git",
            "repository_tag": "v4.0.0",
            "repository_revision": "452bf305c6daa62fc59061d22133a7cbc7c1572e",
            "registry_path": "tasks/dataset.toml",
            "dataset_file_sha256": (
                "ecd296ba053840bd4c0068e8f84e8a6fa829d184d0fd9852becdc19f4c895fcf"
            ),
            "harbor_manifest_sha256": (
                "4740ea3d60ebef3843f149ee5f91be6c4caad869d4b111299b05a298c3f4e4be"
            ),
            "task_manifest_sha256": (
                "da42796db57719d0e8f6994c77231ce2ace97e5fd57fe5ca1c5eb44011bea6c5"
            ),
            "official_tasks": 66,
            "official_attempts": 5,
            "official_trials": 330,
        },
        "score_scope": {
            "run_kind": "full_official_suite",
            "selection": "all",
            "dataset": (
                "terminal-bench/terminal-bench@"
                "sha256:39d9f44b40420cde8fdcc087579c0d72a7e14fa3656d603c3f0d22fb35e27732"
            ),
            "official_tasks": 66,
            "official_attempts": 5,
            "official_trials": 330,
            "execution_config": {
                "reasoning_effort": "xhigh",
                "review_passes": 2,
            },
        },
        "provenance_ready": True,
        "provenance_blockers": [],
        "organizer_verification": {
            "required": True,
            "method": "organizer-signed-score-receipt-v1",
            "signature_algorithm": "openssl-dgst-sha256",
            "receipt_schema": "harbor/official-score-receipt-v1",
            "trust_root_id": None,
            "trust_root_sha256": None,
            "trusted_hosts": [
                "hub.harborframework.com",
                "tbench.ai",
                "www.tbench.ai",
            ],
            "accepted_statuses": ["accepted", "published"],
            "caller_assertions_accepted": False,
            "locally_derived_scores_accepted": False,
            "closed_schema_required": True,
        },
    },
    "aider-polyglot-stock": {
        "display_name": "Aider Polyglot",
        "campaign_suite": None,
        "protocol": "stock-aider-polyglot-225-exercises-two-tries",
        "organizer": "Aider",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "source_identity": {
            "runner_repository": "https://github.com/Aider-AI/aider.git",
            "runner_revision": "5dc9490bb35f9729ef2c95d00a19ccd30c26339c",
            "dataset_repository": (
                "https://github.com/Aider-AI/polyglot-benchmark.git"
            ),
            "dataset_revision": "7e0611e77b54e2dea774cdc0aa00cf9f7ed6144f",
            "official_exercises": 225,
            "tries": 2,
        },
        "score_scope": {
            "run_kind": "full_official_suite",
            "selection": "all",
            "dataset": "aider-polyglot",
            "official_exercises": 225,
            "tries": 2,
        },
        "provenance_ready": False,
        "provenance_blockers": [
            "stock Aider edit format, reasoning effort, and concurrency are not contract-pinned"
        ],
        "organizer_verification": {
            "required": True,
            "method": "organizer-signed-score-receipt-v1",
            "signature_algorithm": "openssl-dgst-sha256",
            "receipt_schema": "aider/official-polyglot-score-receipt-v1",
            "trust_root_id": None,
            "trust_root_sha256": None,
            "trusted_hosts": ["aider.chat", "www.aider.chat"],
            "accepted_statuses": ["accepted", "published"],
            "caller_assertions_accepted": False,
            "locally_derived_scores_accepted": False,
            "closed_schema_required": True,
        },
    },
    "swe-bench-verified-500": {
        "display_name": "SWE-bench Verified",
        "campaign_suite": "swe-bench",
        "protocol": "official-swe-bench-verified-500-task-pass-at-1",
        "organizer": "SWE-bench",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "source_identity": {
            "dataset": "swebench-verified",
            "harbor_manifest_sha256": (
                "8915e69fb7e44f6b310f1d5ad267ece2946b7f11ab55232b8066d3b6d43d3c04"
            ),
            "repository": "https://github.com/SWE-bench/SWE-bench.git",
            "official_tasks": 500,
            "attempts": 1,
        },
        "score_scope": {
            "run_kind": "full_official_suite",
            "selection": "all",
            "dataset": "swebench-verified",
            "official_tasks": 500,
            "official_attempts": 1,
            "official_trials": 500,
            "execution_config": {
                "reasoning_effort": "max",
                "review_passes": 2,
            },
        },
        "provenance_ready": False,
        "provenance_blockers": [
            "SWE-bench Verified evaluator revision and immutable runtime are not contract-pinned"
        ],
        "organizer_verification": {
            "required": True,
            "method": "organizer-signed-score-receipt-v1",
            "signature_algorithm": "openssl-dgst-sha256",
            "receipt_schema": "swe-bench/official-verified-score-receipt-v1",
            "trust_root_id": None,
            "trust_root_sha256": None,
            "trusted_hosts": [
                "www.swebench.com",
                "swebench.com",
                "github.com",
            ],
            "accepted_statuses": ["accepted", "published"],
            "caller_assertions_accepted": False,
            "locally_derived_scores_accepted": False,
            "closed_schema_required": True,
        },
    },
    "arc-agi-3-standardized": {
        "display_name": "ARC-AGI-3",
        "campaign_suite": None,
        "protocol": (
            "official-arc-agi-3-standardized-general-purpose-model-"
            "25-environments"
        ),
        "organizer": "ARC Prize",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "source_identity": {
            "runner_repository": (
                "https://github.com/arcprize/arc-agi-3-benchmarking.git"
            ),
            "runner_revision": "86d72170ce3155551712a9fafd290bab471d6eee",
            "official_environments": 25,
        },
        "score_scope": {
            "run_kind": "full_official_suite",
            "selection": "all",
            "protocol": "standardized-general-purpose-model",
            "official_environments": 25,
        },
        "provenance_ready": False,
        "provenance_blockers": [
            "standardized ARC model-config ID and canonical hashes are not pinned"
        ],
        "organizer_verification": {
            "required": True,
            "method": "organizer-signed-score-receipt-v1",
            "signature_algorithm": "openssl-dgst-sha256",
            "receipt_schema": "arc-prize/official-arc-agi-3-score-receipt-v1",
            "trust_root_id": None,
            "trust_root_sha256": None,
            "trusted_hosts": ["arcprize.org", "www.arcprize.org"],
            "accepted_statuses": ["accepted", "published"],
            "caller_assertions_accepted": False,
            "locally_derived_scores_accepted": False,
            "closed_schema_required": True,
        },
    },
}


def official_quality_contract():
    """Return the five-lane, no-average official-quality contract."""
    return {
        "schema": OFFICIAL_QUALITY_CONTRACT_SCHEMA,
        "evidence_schema": OFFICIAL_QUALITY_EVIDENCE_SCHEMA,
        "claim": "official_quality.good",
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "minimum_score": OFFICIAL_QUALITY_MINIMUM_SCORE,
        "evidence_max_age_seconds": OFFICIAL_QUALITY_EVIDENCE_MAX_AGE_SECONDS,
        "future_clock_skew_seconds": OFFICIAL_QUALITY_FUTURE_CLOCK_SKEW_SECONDS,
        "required_lanes": {
            lane: json.loads(json.dumps(config, sort_keys=True))
            for lane, config in OFFICIAL_QUALITY_LANES.items()
        },
        "required_count": len(OFFICIAL_QUALITY_LANES),
        "policy": {
            "all_lanes_must_be_organizer_verified": True,
            "each_lane_must_meet_minimum": True,
            "averaging_allowed": False,
            "substitution_allowed": False,
            "caller_assertions_are_evidence": False,
            "locally_converted_pass_counts_are_official_scores": False,
            "independent_from_number_one_claim": True,
            "independent_from_internal_release_certification": True,
        },
    }


def _strict_json_object(pairs):
    payload = {}
    for key, value in pairs:
        if key in payload:
            raise ValueError("duplicate JSON key: %s" % key)
        payload[key] = value
    return payload


def strict_json_loads(raw):
    """Decode JSON while rejecting duplicate keys at every object depth."""
    return json.loads(raw, object_pairs_hook=_strict_json_object)


def external_number_one_contract():
    """Return the immutable external claim contract embedded in new campaigns."""
    return {
        "schema": EXTERNAL_NUMBER_ONE_CONTRACT_SCHEMA,
        "requires_internal_release_certification": True,
        "requires_verified_run_and_submission_receipts": True,
        "requires_fresh_hashed_target_snapshots": True,
        "target_snapshot_max_age_seconds": EXTERNAL_TARGET_MAX_AGE_SECONDS,
        "historical_lanes_do_not_certify_current_number_one": [
            "terminal-bench-2",
            "terminal-bench-2.1",
            "swe-bench-verified",
        ],
        "claim_policy": {
            "strict_number_one_requires_all_strict_lanes": True,
            "arc_agi_3_at_100_is_tie_for_number_one_only": True,
            "sole_number_one": False,
        },
        "required_lanes": {
            lane: dict(config)
            for lane, config in EXTERNAL_NUMBER_ONE_LANES.items()
        },
    }

OPERATOR_HARBOR_AGENT = (
    "blacklabel_operator.harbor_agent:BlackLabelOperatorAgent"
)

VERIFIER_INFRASTRUCTURE_MARKERS = {
    "JAVA_HOME is set to an invalid directory": "InvalidJavaHome",
    "No space left on device": "VerifierDiskFull",
    "uv: command not found": "VerifierDependencyMissing",
    "Failed to fetch: `https://pypi.org/simple/": "VerifierDependencyFetch",
    "leap-second file is expired": "VerifierBaselineDataExpired",
}

CODEX_BENCHMARK_CONFIG = {
    "analytics": {"enabled": False},
    "apps": {"_default": {"enabled": False}},
    "check_for_update_on_startup": False,
    "features": {
        "apps": False,
        "browser_use": False,
        "browser_use_external": False,
        "browser_use_full_cdp_access": False,
        # Codex uses its native code-mode host for benchmark workspace I/O.
        # Keep it enabled while disabling every non-native extension surface.
        "code_mode_host": True,
        "computer_use": False,
        "memories": False,
        "multi_agent": False,
        "multi_agent_v2": False,
        "plugins": False,
        "recommended_plugins": False,
        "remote_plugin": False,
        "skill_search": False,
        "plugin_sharing": False,
        "tool_suggest": False,
    },
    "mcp_servers": {},
    "plugins": {},
    "project_doc_max_bytes": 0,
    "skills": {
        "bundled": {"enabled": False},
        "config": [],
        "include_instructions": False,
    },
    "suppress_unstable_features_warning": True,
    "web_search": "disabled",
}


def _run_id():
    return time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def benchmark_score_claim(
    suite,
    requested_tasks,
    completed_tasks,
    passed_tasks,
    errored_tasks=0,
    include_tasks=None,
    dataset=None,
    attempts=None,
):
    """Separate selected-task evidence from full benchmark score claims."""
    if suite not in HARBOR_SUITES:
        raise ValueError("unknown Harbor benchmark suite: %s" % suite)
    config = HARBOR_SUITES[suite]
    official_size = config["official_size"]
    effective_dataset = dataset or config["dataset"]
    requested_tasks = int(requested_tasks or 0)
    completed_tasks = int(completed_tasks or 0)
    passed_tasks = int(passed_tasks or 0)
    errored_tasks = int(errored_tasks or 0)
    include_tasks = list(include_tasks or [])
    attempts = benchmark_attempts(
        suite,
        requested_tasks,
        include_tasks=include_tasks,
        dataset=effective_dataset,
        override=attempts,
    )
    official_attempts = int(config.get("official_attempts") or 1)
    official_trials = official_size * official_attempts
    requested_trials = requested_tasks * attempts
    official_scope_requested = bool(
        official_size
        and effective_dataset == config["dataset"]
        and not include_tasks
        and requested_tasks == official_size
        and attempts == official_attempts
    )
    full_run = bool(
        official_scope_requested
        and completed_tasks == official_trials
        and errored_tasks == 0
    )
    if full_run:
        run_kind = "full"
        if suite == "terminal-bench-current":
            statement = (
                "Full pinned Terminal-Bench 4.0 task set completed; this is a "
                "local official-protocol score, not a leaderboard result until "
                "the organizer accepts and publishes its submission."
            )
        else:
            statement = (
                "Full official task set completed; this receipt contains a local "
                "benchmark score, not a verified leaderboard submission or "
                "number-one result."
            )
    elif official_scope_requested:
        run_kind = "incomplete_full_attempt"
        statement = (
            "Full-suite attempt did not complete cleanly; no benchmark or "
            "leaderboard score exists."
        )
    else:
        run_kind = "smoke"
        statement = (
            "Partial smoke run; selected-task results are not a benchmark or "
            "leaderboard score."
        )

    selected_rate = (
        round(passed_tasks / completed_tasks, 6) if completed_tasks else None
    )
    coverage_fraction = (
        round(completed_tasks / official_trials, 6) if official_trials else None
    )
    gate = dict(NUMBER_ONE_GATES[suite])
    comparison_numeric_target_met = (
        bool(full_run and passed_tasks >= gate["target_passes"])
        if gate["comparable"]
        else None
    )
    local_target_met = bool(
        full_run and passed_tasks >= int(gate["target_passes"])
    )
    return {
        "run_kind": run_kind,
        "statement": statement,
        "official_dataset": config["dataset"],
        "official_tasks": official_size,
        "official_attempts": official_attempts,
        "official_trials": official_trials,
        "official_reasoning_effort": config.get("official_reasoning_effort"),
        "registry_repo": config.get("registry_repo"),
        "registry_path": config.get("registry_path"),
        "repository_tag": config.get("repository_tag"),
        "repository_commit": config.get("repository_commit"),
        "requested_tasks": requested_tasks,
        "requested_attempts": attempts,
        "requested_trials": requested_trials,
        "completed_tasks": completed_tasks,
        "completed_trials": completed_tasks,
        "passed_tasks": passed_tasks,
        "errored_tasks": errored_tasks,
        "coverage_fraction": coverage_fraction,
        "coverage_percent": (
            round(coverage_fraction * 100, 4)
            if coverage_fraction is not None
            else None
        ),
        "selected_task_pass_rate": selected_rate,
        "benchmark_score_available": full_run,
        "benchmark_score": selected_rate if full_run else None,
        "leaderboard_submission_verified": False,
        "custom_agent_submission_accepted": config.get(
            "custom_agent_submission_accepted", True
        ),
        "leaderboard_score": None,
        "number_one_gate": gate,
        "comparison_numeric_target_met": comparison_numeric_target_met,
        # A local score cannot prove an organizer accepted or independently
        # verified the result.  Keep this fail-closed even when the numeric
        # take-first target is met.
        "number_one_target_met": False,
        "number_one": False,
        "external_evidence_required": True,
        "local_target_met": local_target_met,
    }


def benchmark_attempts(
    suite,
    n_tasks,
    include_tasks=None,
    dataset=None,
    override=None,
):
    """Return the official attempt count for an exact full-suite run.

    Terminal-Bench 2 rows require five independent trials per task. The pinned
    Terminal-Bench 4.0 defaults also require five. Smoke runs remain one trial
    unless explicitly increased. Aider's two-try protocol happens inside stock
    Aider and must not be represented as two custom-agent Harbor trials.
    """
    if suite not in HARBOR_SUITES:
        raise ValueError("unknown Harbor benchmark suite: %s" % suite)
    config = HARBOR_SUITES[suite]
    official_full = bool(
        int(n_tasks) == config["official_size"]
        and not include_tasks
        and dataset in (None, config["dataset"])
    )
    required = int(config.get("official_attempts") or 1) if official_full else 1
    if override is None:
        return required
    override = int(override)
    if override < 1:
        raise ValueError("n_attempts must be positive")
    if official_full and override != required:
        raise ValueError(
            "%s full-suite comparability requires n_attempts=%d"
            % (suite, required)
        )
    return override


def benchmark_review_passes(
    suite,
    n_tasks,
    include_tasks=None,
    dataset=None,
    override=None,
):
    if suite not in HARBOR_SUITES:
        raise ValueError("unknown Harbor benchmark suite: %s" % suite)
    if override is not None:
        override = int(override)
        if override not in (0, 1, 2):
            raise ValueError("review_passes override must be 0, 1, or 2")
        return override
    config = HARBOR_SUITES[suite]
    official_full = (
        int(n_tasks) == config["official_size"]
        and not include_tasks
        and dataset in (None, config["dataset"])
    )
    if official_full:
        return 0
    return 2


def harbor_command(
    suite,
    run_dir,
    n_tasks,
    include_tasks=None,
    dataset=None,
    codex_version=None,
    n_concurrent=1,
    max_retries=0,
    review_passes=None,
    reasoning_effort="high",
    n_attempts=None,
    dataset_path=None,
):
    if suite not in HARBOR_SUITES:
        raise ValueError("unknown Harbor benchmark suite: %s" % suite)
    if reasoning_effort not in (
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra",
    ):
        raise ValueError("unsupported benchmark reasoning effort")
    suite_config = HARBOR_SUITES[suite]
    official_full = bool(
        int(n_tasks) == int(suite_config["official_size"])
        and not include_tasks
        and dataset in (None, suite_config["dataset"])
    )
    official_effort = suite_config.get("official_reasoning_effort")
    if official_full and official_effort and reasoning_effort != official_effort:
        raise ValueError(
            "%s full-suite protocol requires reasoning_effort=%s"
            % (suite, official_effort)
        )
    command = [shutil.which("harbor") or "harbor", "run"]
    if dataset_path is not None:
        command.extend(["--path", str(Path(dataset_path).resolve())])
    else:
        if suite == "terminal-bench-current":
            raise ValueError(
                "terminal-bench-current requires a verified pinned local dataset path"
            )
        command.extend(["--dataset", dataset or suite_config["dataset"]])
        if suite_config.get("registry_repo") and not suite_config.get(
            "dataset_digest"
        ):
            command.extend(["--repo", suite_config["registry_repo"]])
        if suite_config.get("registry_path") and not suite_config.get(
            "dataset_digest"
        ):
            command.extend(["--registry-path", suite_config["registry_path"]])
    command.extend(
        [
        "--agent",
        OPERATOR_HARBOR_AGENT,
        "--model",
        SOL_MODEL,
        "--agent-kwarg",
        "reasoning_effort=%s" % reasoning_effort,
        ]
    )
    if codex_version:
        command.extend(["--agent-kwarg", "codex_version=%s" % codex_version])
    command.extend(["--agent-kwarg", "operator_version=%s" % __version__])
    review_passes = benchmark_review_passes(
        suite,
        n_tasks,
        include_tasks=include_tasks,
        dataset=dataset,
        override=review_passes,
    )
    command.extend(["--agent-kwarg", "review_passes=%d" % review_passes])
    command.extend(["--agent-kwarg", "benchmark_suite=%s" % suite])
    if suite == "aider-polyglot":
        command.extend(["--agent-kwarg", "workspace_consensus=true"])
    attempts = benchmark_attempts(
        suite,
        n_tasks,
        include_tasks=include_tasks,
        dataset=dataset,
        override=n_attempts,
    )
    command.extend(
        [
            "--agent-kwarg",
            "config=%s"
            % json.dumps(CODEX_BENCHMARK_CONFIG, separators=(",", ":"), sort_keys=True),
        ]
    )
    command.extend(
        [
            "--agent-env",
            "CODEX_AUTH_JSON_PATH=%s" % (Path.home() / ".codex" / "auth.json"),
            "--agent-env",
            "OPERATOR_SUPERVISED_PROCESS_GROUP=1",
            "--agent-setup-timeout-multiplier",
            "4",
            "--agent-timeout-multiplier",
            "24",
            "--environment-build-timeout-multiplier",
            "4",
            "--n-concurrent",
            str(n_concurrent),
            "--n-tasks",
            str(n_tasks),
            "--n-attempts",
            str(attempts),
            "--max-retries",
            str(max_retries),
            "--jobs-dir",
            str(Path(run_dir).resolve()),
            "--yes",
        ]
    )
    if suite_config["force_build"]:
        command.append("--force-build")
    for task_name in include_tasks or ():
        resolved_task_name = task_name
        if (
            suite == "terminal-bench-current"
            and suite_config.get("dataset_digest")
            and "/" not in task_name
        ):
            resolved_task_name = "terminal-bench/" + task_name
        command.extend(["--include-task-name", resolved_task_name])
    return command


def _git_output(argv, cwd=None, timeout=900):
    result = subprocess.run(
        argv,
        cwd=str(cwd) if cwd is not None else None,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "git command failed").strip()
        raise RuntimeError(detail)
    return result.stdout.strip()


def _prepare_pinned_harbor_dataset(suite, benchmark_dir, source_id):
    """Materialize and verify a suite source before Harbor starts an agent."""
    config = HARBOR_SUITES[suite]
    repository_url = config.get("repository_url")
    revision = config.get("repository_commit")
    dataset_file_sha256 = config.get("dataset_file_sha256")
    if not repository_url:
        return None, None
    if not revision or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("pinned benchmark repository revision is invalid")
    if not dataset_file_sha256 or not re.fullmatch(
        r"[0-9a-f]{64}", dataset_file_sha256
    ):
        raise RuntimeError("pinned benchmark dataset file hash is invalid")

    source_parent = Path(benchmark_dir) / "_sources" / suite
    source_parent.mkdir(parents=True, exist_ok=True)
    source_dir = source_parent / source_id
    if source_dir.exists():
        raise RuntimeError("fresh benchmark source path already exists")
    _git_output(
        [
            "git",
            "clone",
            "--quiet",
            "--filter=blob:none",
            "--no-checkout",
            repository_url,
            str(source_dir),
        ]
    )
    _git_output(
        ["git", "checkout", "--quiet", "--detach", revision],
        cwd=source_dir,
    )
    resolved_revision = _git_output(["git", "rev-parse", "HEAD"], cwd=source_dir)
    if resolved_revision != revision:
        raise RuntimeError("fresh benchmark source revision does not match pin")
    if _git_output(["git", "status", "--porcelain"], cwd=source_dir):
        raise RuntimeError("fresh benchmark source checkout is dirty")

    dataset_path = source_dir / "tasks"
    manifest_path = dataset_path / "dataset.toml"
    if not manifest_path.is_file():
        raise RuntimeError("pinned benchmark dataset manifest is missing")
    actual_dataset_file_sha256 = hashlib.sha256(
        manifest_path.read_bytes()
    ).hexdigest()
    if actual_dataset_file_sha256 != dataset_file_sha256:
        raise RuntimeError("pinned benchmark dataset file hash changed")
    task_names = sorted(
        path.name
        for path in dataset_path.iterdir()
        if path.is_dir() and (path / "task.toml").is_file()
    )
    if len(task_names) != int(config["official_size"]):
        raise RuntimeError("pinned benchmark task count does not match contract")
    task_manifest_sha256 = hashlib.sha256(
        json.dumps(task_names, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    source_receipt = {
        "schema": "black-label-operator/pinned-harbor-source-v1",
        "suite": suite,
        "repository": repository_url,
        "revision": resolved_revision,
        "dataset_path": str(dataset_path.resolve()),
        "dataset_file_sha256": actual_dataset_file_sha256,
        "task_count": len(task_names),
        "task_manifest_sha256": task_manifest_sha256,
    }
    receipt_path = source_parent / (source_id + ".json")
    receipt_path.write_text(
        json.dumps(source_receipt, indent=2, sort_keys=True), encoding="utf-8"
    )
    return dataset_path, source_receipt


def validate_atif_trajectory(
    path,
    expected_operator_version=None,
    expected_codex_version=None,
    expected_model=SOL_MODEL,
):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("ATIF trajectory is missing or symbolic")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("ATIF trajectory is not valid JSON") from exc
    agent = payload.get("agent") if isinstance(payload, dict) else None
    subtrajectories = payload.get("subagent_trajectories") if isinstance(payload, dict) else None
    try:
        session_id = str(uuid.UUID(str(payload.get("session_id"))))
    except (AttributeError, ValueError) as exc:
        raise RuntimeError("ATIF trajectory session identity is invalid") from exc
    flattened = []
    inner_sessions = []
    trajectory_ids = []
    if not isinstance(subtrajectories, list) or not subtrajectories:
        raise RuntimeError("ATIF trajectory omits Operator subtrajectories")
    for trajectory in subtrajectories:
        inner_agent = trajectory.get("agent") if isinstance(trajectory, dict) else None
        try:
            inner_session = str(uuid.UUID(str(trajectory.get("session_id"))))
            trajectory_id = str(uuid.UUID(str(trajectory.get("trajectory_id"))))
        except (AttributeError, ValueError) as exc:
            raise RuntimeError("ATIF inner trajectory identity is invalid") from exc
        if (
            trajectory.get("schema_version") != "ATIF-v1.7"
            or not isinstance(inner_agent, dict)
            or inner_agent.get("name") != "codex"
            or inner_agent.get("model_name") != expected_model
            or not isinstance(inner_agent.get("version"), str)
            or not inner_agent.get("version")
            or (
                expected_codex_version is not None
                and inner_agent.get("version") != expected_codex_version
            )
            or not isinstance(trajectory.get("steps"), list)
            or not trajectory["steps"]
        ):
            raise RuntimeError("ATIF inner Codex trajectory identity is invalid")
        inner_sessions.append(inner_session)
        trajectory_ids.append(trajectory_id)
        for step in trajectory["steps"]:
            copied = dict(step)
            copied["step_id"] = len(flattened) + 1
            flattened.append(copied)
    session_hash = hashlib.sha256("\n".join(inner_sessions).encode("utf-8")).hexdigest()
    expected_session = "%s-%s-%s-%s-%s" % (
        session_hash[:8],
        session_hash[8:12],
        session_hash[12:16],
        session_hash[16:20],
        session_hash[20:32],
    )
    metrics = payload.get("final_metrics")
    if (
        set(payload)
        != {
            "schema_version",
            "session_id",
            "agent",
            "steps",
            "final_metrics",
            "subagent_trajectories",
        }
        or payload.get("schema_version") != "ATIF-v1.7"
        or session_id != payload.get("session_id")
        or session_id != expected_session
        or len(inner_sessions) != len(set(inner_sessions))
        or len(trajectory_ids) != len(set(trajectory_ids))
        or not isinstance(agent, dict)
        or set(agent) - {"name", "version", "model_name", "extra"}
        or agent.get("name") != "black-label-operator"
        or agent.get("model_name") != expected_model
        or not isinstance(agent.get("version"), str)
        or not agent.get("version")
        or (
            expected_operator_version is not None
            and agent.get("version") != expected_operator_version
        )
        or payload.get("steps") != flattened
        or not isinstance(metrics, dict)
        or set(metrics)
        != {
            "total_prompt_tokens",
            "total_completion_tokens",
            "total_cached_tokens",
            "total_cost_usd",
            "total_steps",
            "extra",
        }
        or metrics.get("total_steps") != len(flattened)
        or any(
            not isinstance(metrics.get(key), int) or metrics.get(key) < 0
            for key in (
                "total_prompt_tokens",
                "total_completion_tokens",
                "total_cached_tokens",
                "total_steps",
            )
        )
        or any(
            not isinstance(step, dict)
            or step.get("step_id") != index
            or step.get("source") not in {"system", "user", "agent"}
            or not isinstance(step.get("timestamp"), str)
            or not step.get("timestamp")
            or (step.get("message") is None and not step.get("tool_calls") and not step.get("observation"))
            for index, step in enumerate(flattened, 1)
        )
    ):
        raise RuntimeError("ATIF trajectory is not an exact merged Operator trajectory")
    for step in flattened:
        try:
            datetime.fromisoformat(step["timestamp"].replace("Z", "+00:00"))
        except ValueError as exc:
            raise RuntimeError("ATIF trajectory timestamp is invalid") from exc
    return payload


def _atif_trajectory_status(trial_dir):
    path = Path(trial_dir) / "agent" / "trajectory.json"
    if not path.is_file():
        return False, None, "MissingATIFTrajectory"
    try:
        validate_atif_trajectory(path)
    except RuntimeError:
        return False, str(path), "InvalidATIFTrajectory"
    return True, str(path), None


def _trial_results(run_dir, suite=None):
    trials = []
    for path in sorted(Path(run_dir).rglob("result.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if "task_name" not in payload or "trial_name" not in payload:
            continue
        verifier = payload.get("verifier_result") or {}
        rewards = verifier.get("rewards") or {}
        agent_info = payload.get("agent_info") or {}
        model_info = agent_info.get("model_info") or {}
        exception = payload.get("exception_info")
        quota_exception = quota_info_for_trial(path.parent)
        if quota_exception is not None:
            exception = quota_exception
        verifier_log = path.parent / "verifier" / "test-stdout.txt"
        if exception is None and verifier_log.is_file():
            try:
                verifier_text = verifier_log.read_text(
                    encoding="utf-8", errors="replace"
                )
            except OSError:
                verifier_text = ""
            for marker, exception_type in VERIFIER_INFRASTRUCTURE_MARKERS.items():
                if marker in verifier_text:
                    exception = {
                        "exception_type": exception_type,
                        "message": marker,
                    }
                    break
        atif_valid, atif_path, atif_error = _atif_trajectory_status(path.parent)
        if suite in TERMINAL_BENCH_SUITES and exception is None and atif_error:
            exception = {
                "exception_type": atif_error,
                "message": "Terminal-Bench leaderboard trials require a valid ATIF trajectory",
            }
        official_reward = rewards.get("reward")
        reward_is_pass = bool(
            not isinstance(official_reward, bool)
            and isinstance(official_reward, (int, float))
            and float(official_reward) == 1.0
        )
        trials.append(
            {
                "path": str(path.relative_to(run_dir)),
                "task_name": payload.get("task_name"),
                "trial_name": payload.get("trial_name"),
                "agent": agent_info.get("name"),
                "agent_version": agent_info.get("version"),
                "model": model_info.get("name"),
                "model_provider": model_info.get("provider"),
                "rewards": rewards,
                "official_reward": official_reward,
                "passed": reward_is_pass and exception is None,
                "exception": exception,
                "atif_trajectory": atif_path,
                "atif_valid": atif_valid,
            }
        )
    return trials


def _write_command(run_dir, command, environment=None):
    payload = {
        "provider": "codex",
        "agent": "black-label-operator",
        "profile": "sol-benchmark",
        "requested_model": SOL_MODEL,
        "resolved_model": SOL_MODEL,
        "argv": command,
        "environment": environment or {},
    }
    (Path(run_dir) / "command.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8"
    )


def run_harbor(args, settings):
    require_exact_sol("codex", SOL_MODEL, settings.model, "sol-benchmark")
    require_quota_available(settings.benchmark_dir)
    if not shutil.which("harbor"):
        raise RuntimeError("Harbor is not installed; run `uv tool install harbor`")
    if not (Path.home() / ".codex/auth.json").is_file():
        raise RuntimeError("Codex subscription auth is not available")

    run_id = _run_id()
    run_dir = settings.benchmark_dir / args.suite / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    dataset_path, source_receipt = _prepare_pinned_harbor_dataset(
        args.suite, settings.benchmark_dir, run_id
    )
    version_output = command_version(settings.codex_bin)
    version_match = re.search(r"\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b", version_output)
    if not version_match:
        raise RuntimeError("unable to resolve the Codex CLI version: %s" % version_output)
    codex_version = version_match.group(1)
    command = harbor_command(
        args.suite,
        run_dir,
        n_tasks=args.n_tasks,
        include_tasks=args.include_task,
        dataset=args.dataset,
        codex_version=codex_version,
        n_concurrent=args.n_concurrent,
        max_retries=args.max_retries,
        review_passes=args.review_passes,
        reasoning_effort=args.effort,
        n_attempts=getattr(args, "n_attempts", None),
        dataset_path=dataset_path,
    )
    attempts = benchmark_attempts(
        args.suite,
        args.n_tasks,
        include_tasks=args.include_task,
        dataset=args.dataset,
        override=getattr(args, "n_attempts", None),
    )
    expected_trials = args.n_tasks * attempts
    docker_platform = HARBOR_SUITES[args.suite]["docker_platform"]
    command_environment = {
        "PYTHONPATH": str(Path(__file__).resolve().parent.parent),
    }
    if docker_platform:
        command_environment["DOCKER_DEFAULT_PLATFORM"] = docker_platform
    _write_command(run_dir, command, command_environment)
    started = time.time()
    stdout_path = run_dir / "harbor.stdout.log"
    stderr_path = run_dir / "harbor.stderr.log"
    timed_out = False
    termination = None
    termination_confirmed = True
    with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open(
        "w", encoding="utf-8"
    ) as stderr:
        process_environment = os.environ.copy()
        process_environment.update(command_environment)
        new_session = should_start_new_session()
        process = subprocess.Popen(
            command,
            cwd=str(settings.repo_root),
            stdout=stdout,
            stderr=stderr,
            text=True,
            start_new_session=new_session,
            env=process_environment,
        )
        try:
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process_group_id = (
                process.pid if new_session and os.name != "nt" else None
            )
            termination_confirmed, termination = CodexRunner.terminate_spawned(
                process, process_group_id
            )

    trials = _trial_results(run_dir, suite=args.suite)
    passed = sum(1 for trial in trials if trial["passed"])
    completed = len(trials)
    errored = sum(1 for trial in trials if trial["exception"])
    if timed_out and not termination_confirmed:
        status = "blocked"
    elif timed_out:
        status = "incomplete"
    elif process.returncode not in (0, None) and not trials:
        status = "blocked"
    elif trials and errored == completed:
        status = "blocked"
    elif completed != expected_trials:
        status = "incomplete"
    elif passed == completed:
        status = "passed"
    else:
        status = "failed"
    claim_errored = max(1, errored) if not termination_confirmed else errored
    result = {
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "termination": termination,
        "termination_confirmed": termination_confirmed,
        "termination_detail": termination,
        "requested_tasks": args.n_tasks,
        "requested_attempts": attempts,
        "requested_trials": expected_trials,
        "completed_tasks": completed,
        "passed_tasks": passed,
        "errored_tasks": claim_errored,
        "trials": trials,
    }
    score_claim = benchmark_score_claim(
        args.suite,
        requested_tasks=args.n_tasks,
        completed_tasks=completed,
        passed_tasks=passed,
        errored_tasks=claim_errored,
        include_tasks=args.include_task,
        dataset=args.dataset,
        attempts=attempts,
    )
    result["score_claim"] = score_claim
    result["selected_scope_status"] = status
    receipt = write_receipt(
        run_dir,
        suite=args.suite,
        status=status,
        settings=settings,
        command=command,
        scope={
            "agent": "black-label-operator",
            "operator_version": __version__,
            "dataset": args.dataset or HARBOR_SUITES[args.suite]["dataset"],
            "registry_repo": HARBOR_SUITES[args.suite].get("registry_repo"),
            "registry_path": HARBOR_SUITES[args.suite].get("registry_path"),
            "repository_tag": HARBOR_SUITES[args.suite].get("repository_tag"),
            "repository_commit": HARBOR_SUITES[args.suite].get(
                "repository_commit"
            ),
            "pinned_source": source_receipt,
            "termination_confirmed": termination_confirmed,
            "termination_detail": termination,
            "n_tasks": args.n_tasks,
            "n_attempts": attempts,
            "include_task": args.include_task,
            "official_size": HARBOR_SUITES[args.suite]["official_size"],
            "n_concurrent": args.n_concurrent,
            "max_retries": args.max_retries,
            "review_passes": benchmark_review_passes(
                args.suite,
                args.n_tasks,
                include_tasks=args.include_task,
                dataset=args.dataset,
                override=args.review_passes,
            ),
            "reasoning_effort": args.effort,
            "run_kind": score_claim["run_kind"],
            "score_eligible": score_claim["benchmark_score_available"],
            "codex_version": codex_version,
            "docker_platform": docker_platform,
        },
        result=result,
        started_at=started,
    )
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if status == "passed" else 1
