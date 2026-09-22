"""Leaderboard-comparable benchmark runners and external evidence ingestion.

The internal Operator Harbor agent and ARC planner intentionally do not enter
this module.  Stock Aider and the ARC Prize ``BenchmarkingAgent`` receive their
own source-bound receipts so their results cannot be relabelled from a custom
Operator run.
"""

import ast
import base64
import csv
from collections import Counter
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib import request
from urllib.parse import urlparse

from . import __version__
from .benchmark_receipt import source_identity
from .codex_runner import CodexRunner
from .settings import should_start_new_session
from .standard_benchmark import (
    CODEX_BENCHMARK_CONFIG,
    EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA,
    EXTERNAL_NUMBER_ONE_LANES,
    EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER,
    EXTERNAL_TARGET_MAX_AGE_SECONDS,
    OFFICIAL_QUALITY_EVIDENCE_SCHEMA,
    OFFICIAL_QUALITY_EVIDENCE_MAX_AGE_SECONDS,
    OFFICIAL_QUALITY_FUTURE_CLOCK_SKEW_SECONDS,
    OFFICIAL_QUALITY_LANES,
    OFFICIAL_QUALITY_SCORE_SCALE,
    OPERATOR_HARBOR_AGENT,
    VERIFIER_INFRASTRUCTURE_MARKERS,
    harbor_command,
    official_quality_contract,
    strict_json_loads,
)
from .profiles import SOL_MODEL
from .quota import quota_info_for_trial


COMPARABLE_RUN_SCHEMA = "black-label-operator/comparable-run-receipt-v1"
OFFICIAL_AIDER_REPOSITORY = "https://github.com/Aider-AI/aider.git"
OFFICIAL_POLYGLOT_REPOSITORY = (
    "https://github.com/Aider-AI/polyglot-benchmark.git"
)
OFFICIAL_ARC_REPOSITORY = (
    "https://github.com/arcprize/arc-agi-3-benchmarking.git"
)
OFFICIAL_TERMINAL_BENCH_REPOSITORY = (
    "https://github.com/harbor-framework/terminal-bench.git"
)
OFFICIAL_TERMINAL_BENCH_REVISION = (
    "452bf305c6daa62fc59061d22133a7cbc7c1572e"
)
OFFICIAL_TERMINAL_DATASET_FILE_SHA256 = (
    "ecd296ba053840bd4c0068e8f84e8a6fa829d184d0fd9852becdc19f4c895fcf"
)
OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256 = (
    "da42796db57719d0e8f6994c77231ce2ace97e5fd57fe5ca1c5eb44011bea6c5"
)
OFFICIAL_TERMINAL_DIRECTORY_NAME_MANIFEST_SHA256 = (
    "e8de437a3894022c492f341c57e0949f3a6cf492c55715d68b795877f3454855"
)
OFFICIAL_TERMINAL_DATASET_ENTRIES_SHA256 = (
    "f7dc01a2d8a826f19f6a5f9835a1598dfa0fcbfb9b49fe25610a3f30fbf71c90"
)
OFFICIAL_TERMINAL_RUNTIME_MANIFEST_SHA256 = (
    "26c4e0424b9517ae71034d65e0a8ee4083ccb8082e53e7765a5be36162f9b7da"
)
OFFICIAL_HARBOR_VERSION = "0.22.0"
OFFICIAL_HARBOR_PACKAGE_FILES = 437
OFFICIAL_HARBOR_RECORD_CONTENT_SHA256 = (
    "01c7bd9be33553c55044e10f5942fa527bc31c98d4301fca7428c2eaf654b7f2"
)
OFFICIAL_HARBOR_WRAPPER_TEMPLATE_SHA256 = (
    "00970fd71bc4ce3543f4182e8a18dade643c73ea1ab27cf1bb9d3202427b0111"
)
HARBOR_CERTIFYING_RUNTIME_ATTESTATION_SHA256 = (
    "4fd088df4d52de76d85b4358fcee9f1b19beddec3591a576d656c20c4079f5c5"
)
ARC_STANDARDIZED_CONFIG_BLOCKER = (
    "the external certification contract has no exact ARC model-config ID, "
    "canonical config SHA-256, or model-config file SHA-256"
)
OFFICIAL_SWE_PRO_REPOSITORY = (
    "https://github.com/scaleapi/SWE-bench_Pro-os.git"
)
OFFICIAL_SWE_PRO_REVISION = (
    "ca10a60a5fcae51e6948ffe1485d4153d421e6c5"
)
OFFICIAL_SWE_PRO_DATASET_REPOSITORY = (
    "https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro"
)
OFFICIAL_SWE_PRO_DATASET_REVISION = (
    "7ab5114912baf22bb098818e604c02fe7ad2c11f"
)
OFFICIAL_SWE_PRO_EVALUATOR_SHA256 = (
    "bb5d4c5486be296e464e695df3747064aaa3bb197394bc6d39980634afec2034"
)
OFFICIAL_SWE_PRO_RAW_DATA_SHA256 = (
    "b5b2462bfbf5aeb2cb7ba7d215778a1768b85f9d7ad7f748546c7f80a0ad1510"
)
OFFICIAL_SWE_PRO_PARQUET_SHA256 = (
    "c8cd7115496ad4e9a8b21d088cef576a65bf821bb542b24336f13f714cef13f8"
)
OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256 = (
    "3d2dc2ea479bcd7833a3b1ce7f77e9d6409e0aee14a87fb81d9dd4b9d5aad0f3"
)
OFFICIAL_SWE_PRO_NORMALIZED_INPUT_SHA256 = (
    "69bf672f111dc325ad1afb286b4541fded15e90df97600134f75e72ad134aabc"
)
SWE_PRO_GENERATION_RECEIPT_SCHEMA = (
    "black-label-operator/swe-pro-generation-receipt-v1"
)
SWE_PRO_CERTIFICATION_BLOCKERS = (
    "Scale publishes no contract-pinned immutable outer evaluator image digest",
    "Scale publishes no immutable 731-task inner-image repo-digest manifest",
    "Operator patch generation has no contract-pinned independent attestation key",
    "the pinned SWE source contains optional gitlinks not bound for generation provenance",
)
FULL_SHA256 = re.compile(r"[0-9a-f]{64}")
FULL_GIT_REVISION = re.compile(r"[0-9a-f]{40}")
IMMUTABLE_CONTAINER_IMAGE = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9._/:@-]*@sha256:[0-9a-f]{64}"
)
SAFE_ENV_NAME = re.compile(r"[A-Z][A-Z0-9_]*")
SAFE_RUN_ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{7,100}")
TARGET_SNAPSHOT_SCHEMA = "black-label-operator/leader-target-snapshot-v1"
OFFICIAL_QUALITY_OPENSSL_PATH = Path("/usr/bin/openssl")
OFFICIAL_QUALITY_OPENSSL_ENV = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
}
OFFICIAL_QUALITY_RECEIPT_KEYS = frozenset(
    {
        "schema",
        "lane",
        "protocol",
        "organizer",
        "source_identity",
        "campaign",
        "operator_source",
        "identity",
        "score_scope",
        "status",
        "receipt_id",
        "verified_at",
        "source_url",
        "official_score",
        "signing_public_key_pem",
        "signature",
    }
)
OFFICIAL_QUALITY_SCORE_KEYS = frozenset(
    {"value", "scale", "origin", "locally_derived"}
)
OFFICIAL_QUALITY_SIGNATURE_KEYS = frozenset(
    {
        "method",
        "algorithm",
        "trust_root_id",
        "payload_sha256",
        "value_base64",
    }
)
ARC_CONFIG_SOURCE = r"""
import json
import sys
from benchmarking.model_config import get_model_config
print(json.dumps(get_model_config(sys.argv[1]), sort_keys=True))
"""


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(payload):
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
    ).hexdigest()


def _timestamp(value, label):
    if isinstance(value, bool):
        raise RuntimeError("%s timestamp is invalid" % label)
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    if isinstance(value, str) and value.strip():
        normalized = value.strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError as exc:
            raise RuntimeError("%s timestamp is invalid" % label) from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    raise RuntimeError("%s timestamp is invalid" % label)


def _trusted_official_quality_openssl():
    path = OFFICIAL_QUALITY_OPENSSL_PATH
    if path != Path("/usr/bin/openssl"):
        raise RuntimeError("official-quality verifier path is not /usr/bin/openssl")
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise RuntimeError("trusted /usr/bin/openssl verifier is unavailable") from exc
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or os.access(path, os.W_OK)
        or not os.access(path, os.X_OK)
    ):
        raise RuntimeError(
            "trusted /usr/bin/openssl must be root-owned and not group/world writable"
        )
    return str(path)


def validate_official_quality_organizer_receipt(
    receipt_path, lane, contract, campaign
):
    """Verify one organizer-signed, direct 0-100 official score receipt.

    The receipt's score is never inferred from local passes.  A boolean such as
    ``independently_verified`` is explicitly not a trust primitive: the public
    key must match the contract-pinned organizer trust root and the detached
    signature must verify over the canonical receipt body.
    """
    receipt_path = Path(receipt_path)
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise RuntimeError("official organizer receipt is missing or symbolic")
    if receipt_path.stat().st_size > 1024 * 1024:
        raise RuntimeError("official organizer receipt exceeds 1 MiB")
    try:
        receipt = strict_json_loads(receipt_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError("official organizer receipt is not JSON") from exc
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    if not isinstance(receipt, dict):
        raise RuntimeError("official organizer receipt must be an object")
    forbidden_assertions = {
        "independently_verified",
        "organizer_verified",
        "caller_attested",
        "verified",
    }
    if forbidden_assertions.intersection(receipt):
        raise RuntimeError(
            "caller verification flags are not organizer-verification evidence"
        )
    if set(receipt) != OFFICIAL_QUALITY_RECEIPT_KEYS:
        raise RuntimeError("official organizer receipt does not match the closed schema")
    if not isinstance(campaign, dict):
        raise RuntimeError("official organizer receipt requires a campaign binding")

    verification = contract.get("organizer_verification") or {}
    if verification.get("caller_assertions_accepted") is not False:
        raise RuntimeError("official-quality contract permits caller assertions")
    if verification.get("locally_derived_scores_accepted") is not False:
        raise RuntimeError("official-quality contract permits locally derived scores")
    expected = {
        "schema": verification.get("receipt_schema"),
        "lane": lane,
        "protocol": contract.get("protocol"),
        "organizer": contract.get("organizer"),
        "source_identity": contract.get("source_identity"),
        "score_scope": contract.get("score_scope"),
        "campaign": {
            "id": campaign.get("id"),
            "created_at": campaign.get("created_at"),
        },
        "operator_source": campaign.get("operator_source"),
        "identity": campaign.get("identity"),
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise RuntimeError(
                "official organizer receipt %s does not match the contract" % key
            )
    if set(receipt["campaign"]) != {"id", "created_at"}:
        raise RuntimeError("official organizer receipt campaign binding is not closed")
    operator_source = receipt["operator_source"]
    if not FULL_SHA256.fullmatch(str(operator_source.get("tree_sha256") or "")):
        raise RuntimeError("official organizer receipt is not source-bound")
    if contract.get("provenance_ready") is not True or contract.get(
        "provenance_blockers"
    ):
        raise RuntimeError(
            "official benchmark provenance is incomplete: %s"
            % "; ".join(
                contract.get("provenance_blockers")
                or ["contract is not marked provenance-ready"]
            )
        )
    if receipt.get("status") not in set(verification.get("accepted_statuses") or []):
        raise RuntimeError("official organizer receipt is not accepted or published")
    if not str(receipt.get("receipt_id") or "").strip():
        raise RuntimeError("official organizer receipt ID is missing")
    verified_at = _timestamp(
        receipt.get("verified_at"), "official organizer verification"
    )
    campaign_created_at = _timestamp(
        campaign.get("created_at"), "official-quality campaign creation"
    )
    now = time.time()
    if verified_at < campaign_created_at - OFFICIAL_QUALITY_FUTURE_CLOCK_SKEW_SECONDS:
        raise RuntimeError("official organizer receipt predates the campaign")
    if verified_at > now + OFFICIAL_QUALITY_FUTURE_CLOCK_SKEW_SECONDS:
        raise RuntimeError("official organizer receipt verification is in the future")
    if now - verified_at > OFFICIAL_QUALITY_EVIDENCE_MAX_AGE_SECONDS:
        raise RuntimeError("official organizer receipt is stale")
    parsed_url = urlparse(str(receipt.get("source_url") or ""))
    if (
        parsed_url.scheme != "https"
        or parsed_url.hostname not in set(verification.get("trusted_hosts") or [])
    ):
        raise RuntimeError("official organizer receipt URL is not trusted")

    score = receipt.get("official_score")
    if not isinstance(score, dict):
        raise RuntimeError("official organizer score is missing")
    if any(key in score for key in ("passed", "total", "numerator", "denominator")):
        raise RuntimeError("local pass counts cannot be converted into official scores")
    if set(score) != OFFICIAL_QUALITY_SCORE_KEYS:
        raise RuntimeError("official organizer score does not match the closed schema")
    value = score.get("value")
    scale = score.get("scale")
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or not 0 <= float(value) <= OFFICIAL_QUALITY_SCORE_SCALE
        or scale != OFFICIAL_QUALITY_SCORE_SCALE
        or score.get("origin") != "organizer_reported"
        or score.get("locally_derived") is not False
    ):
        raise RuntimeError("official organizer score is not a direct 0-100 score")

    trust_root_id = verification.get("trust_root_id")
    trust_root_sha256 = verification.get("trust_root_sha256")
    if (
        not isinstance(trust_root_id, str)
        or not trust_root_id.strip()
        or not FULL_SHA256.fullmatch(str(trust_root_sha256 or ""))
    ):
        raise RuntimeError("organizer trust root is not configured")
    signature = receipt.get("signature")
    public_key_pem = receipt.get("signing_public_key_pem")
    if (
        not isinstance(signature, dict)
        or set(signature) != OFFICIAL_QUALITY_SIGNATURE_KEYS
        or not isinstance(public_key_pem, str)
    ):
        raise RuntimeError("organizer signature evidence is missing")
    if (
        signature.get("method") != verification.get("method")
        or signature.get("algorithm") != verification.get("signature_algorithm")
        or signature.get("trust_root_id") != trust_root_id
        or hashlib.sha256(public_key_pem.encode("utf-8")).hexdigest()
        != trust_root_sha256
    ):
        raise RuntimeError("organizer signature trust root does not match")
    signed = dict(receipt)
    signed.pop("signature", None)
    signed.pop("signing_public_key_pem", None)
    signed_bytes = json.dumps(
        signed, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if signature.get("payload_sha256") != hashlib.sha256(signed_bytes).hexdigest():
        raise RuntimeError("organizer signed payload hash does not match")
    try:
        signature_bytes = base64.b64decode(
            str(signature.get("value_base64") or ""), validate=True
        )
    except (ValueError, TypeError) as exc:
        raise RuntimeError("organizer signature is not valid base64") from exc
    if not signature_bytes:
        raise RuntimeError("organizer signature is empty")
    openssl = _trusted_official_quality_openssl()
    with tempfile.TemporaryDirectory(prefix="operator-quality-") as temporary:
        root = Path(temporary)
        key_path = root / "organizer-public-key.pem"
        payload_path = root / "receipt.json"
        signature_path = root / "receipt.sig"
        key_path.write_text(public_key_pem, encoding="utf-8")
        payload_path.write_bytes(signed_bytes)
        signature_path.write_bytes(signature_bytes)
        for artifact in (key_path, payload_path, signature_path):
            artifact.chmod(0o600)
        completed = subprocess.run(
            [
                openssl,
                "dgst",
                "-sha256",
                "-verify",
                str(key_path),
                "-signature",
                str(signature_path),
                str(payload_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
            close_fds=True,
            cwd=str(root),
            env=dict(OFFICIAL_QUALITY_OPENSSL_ENV),
        )
    if (
        completed.returncode != 0
        or completed.stdout != "Verified OK\n"
        or completed.stderr != ""
    ):
        raise RuntimeError("organizer receipt signature verification failed")
    return {
        "lane": lane,
        "protocol": contract["protocol"],
        "organizer": contract["organizer"],
        "score": float(value),
        "score_scale": OFFICIAL_QUALITY_SCORE_SCALE,
        "receipt_id": receipt["receipt_id"],
        "verified_at": receipt["verified_at"],
        "source_url": receipt["source_url"],
        "operator_source": operator_source,
        "identity": receipt["identity"],
        "campaign": receipt["campaign"],
        "score_scope": receipt["score_scope"],
        "trust_method": verification["method"],
        "trust_root_id": trust_root_id,
        "organizer_verified": True,
    }


def _write_json_exclusive(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    path.chmod(0o400)
    return path


def _write_bytes_exclusive(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    path.chmod(0o400)
    return path


def _write_json_atomic_exclusive(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    staging = path.parent / (".%s.%s.tmp" % (path.name, uuid.uuid4().hex))
    try:
        _write_json_exclusive(staging, payload)
        os.link(staging, path, follow_symlinks=False)
        path.chmod(0o400)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except FileExistsError as exc:
        raise RuntimeError("official-quality evidence already exists") from exc
    finally:
        try:
            staging.unlink()
        except OSError:
            pass
    return path


def _copy_exclusive(source, destination):
    source = Path(source)
    destination = Path(destination)
    if source.is_symlink() or not source.is_file():
        raise RuntimeError("evidence artifact must be a regular non-symbolic file")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("evidence artifact already exists: %s" % destination)
    with source.open("rb") as reader:
        descriptor = os.open(
            destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
        )
        try:
            with os.fdopen(descriptor, "wb") as writer:
                for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                    writer.write(chunk)
                writer.flush()
                os.fsync(writer.fileno())
        except Exception:
            try:
                destination.unlink()
            except OSError:
                pass
            raise
    destination.chmod(0o400)
    return destination


def _git_output(root, *args):
    completed = subprocess.run(
        ["git", "--no-replace-objects", "-C", str(root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "git %s failed: %s"
            % (" ".join(args), completed.stderr.strip() or "no output")
        )
    return completed.stdout.strip()


def _normalize_remote(value):
    value = str(value or "").strip().rstrip("/")
    if value.startswith("git@github.com:"):
        value = "https://github.com/" + value.split(":", 1)[1]
    if value.startswith("ssh://git@github.com/"):
        value = "https://github.com/" + value.split("github.com/", 1)[1]
    if value.endswith(".git"):
        value = value[:-4]
    return value.lower()


def _contract_git_pin(
    contract, repository_key, revision_key, expected_repository, label
):
    repository = contract.get(repository_key)
    revision = contract.get(revision_key)
    if _normalize_remote(repository) != _normalize_remote(expected_repository):
        raise RuntimeError("%s repository pin is missing or changed" % label)
    if not FULL_GIT_REVISION.fullmatch(str(revision or "")):
        raise RuntimeError("%s immutable revision pin is missing or changed" % label)
    return str(revision)


def _require_exact_sol_model(requested, resolved, label):
    if requested != SOL_MODEL or resolved != SOL_MODEL:
        raise RuntimeError(
            "%s requires exact requested and resolved model %s"
            % (label, SOL_MODEL)
        )


def _arc_config_contract_pin(contract):
    config_id = contract.get("model_config_id")
    config_sha256 = contract.get("model_config_sha256")
    config_file_sha256 = contract.get("model_config_file_sha256")
    resolved_model = contract.get("resolved_model")
    if (
        not isinstance(config_id, str)
        or not config_id
        or not FULL_SHA256.fullmatch(str(config_sha256 or ""))
        or not FULL_SHA256.fullmatch(str(config_file_sha256 or ""))
        or resolved_model != SOL_MODEL
    ):
        return None
    return {
        "config_id": config_id,
        "config_sha256": config_sha256,
        "config_file_sha256": config_file_sha256,
        "resolved_model": resolved_model,
    }


def _tracked_content_identity(root):
    root = Path(root).resolve()
    if _git_output(root, "replace", "-l"):
        raise RuntimeError("official source contains Git replacement refs")
    entries = _git_output(root, "ls-files", "--stage", "-z").split("\0")
    entries = [entry for entry in entries if entry]
    if not entries:
        raise RuntimeError("official source contains no tracked files")
    flag_entries = _git_output(root, "ls-files", "-v", "-z").split("\0")
    flag_entries = [entry for entry in flag_entries if entry]
    index_flags = {
        entry[2:]: entry[0]
        for entry in flag_entries
        if len(entry) >= 3 and entry[1] == " "
    }
    if len(index_flags) != len(flag_entries) or any(
        flag != "H" for flag in index_flags.values()
    ):
        raise RuntimeError(
            "official source uses assume-unchanged, skip-worktree, or nonstandard index flags"
        )
    digest = hashlib.sha256()
    files = 0
    gitlinks = []
    parsed = []
    for entry in entries:
        metadata, separator, name = entry.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise RuntimeError("official source index entry is malformed")
        mode, object_id, stage = fields
        if stage != "0" or not re.fullmatch(r"[0-9a-f]{40,64}", object_id):
            raise RuntimeError("official source index is not at stage zero")
        parsed.append((name, mode, object_id))
    for name, mode, object_id in sorted(parsed):
        path = root / name
        if index_flags.get(name) != "H":
            raise RuntimeError("official source index flags changed: %s" % name)
        digest.update(name.encode("utf-8") + b"\0" + mode.encode("ascii") + b"\0")
        if mode == "160000":
            if not path.is_dir():
                raise RuntimeError("tracked gitlink is not materialized: %s" % name)
            revision = _git_output(path, "rev-parse", "HEAD")
            if revision != object_id:
                raise RuntimeError("tracked gitlink revision changed: %s" % name)
            if _git_output(
                path,
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ):
                raise RuntimeError("tracked gitlink is dirty or has ignored files: %s" % name)
            remote = _git_output(path, "remote", "get-url", "origin")
            nested = _tracked_content_identity(path)
            digest.update(bytes.fromhex(object_id))
            gitlinks.append(
                {
                    "path": name,
                    "revision": object_id,
                    "origin": remote,
                    "tracked_content_sha256": nested["content_sha256"],
                    "tracked_files": nested["files"],
                    "tracked_gitlinks": nested["gitlinks"],
                }
            )
            continue
        if mode == "120000":
            if not path.is_symlink():
                raise RuntimeError("tracked symbolic link is not materialized: %s" % name)
            blob = subprocess.run(
                ["git", "--no-replace-objects", "cat-file", "blob", object_id],
                cwd=str(root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=120,
                check=False,
            )
            if blob.returncode != 0:
                raise RuntimeError("official symbolic-link Git blob is unreadable: %s" % name)
            target = os.readlink(path)
            target_bytes = os.fsencode(target)
            resolved_target = (path.parent / target).resolve()
            if (
                os.path.isabs(target)
                or target_bytes != blob.stdout
                or root not in resolved_target.parents
                or not resolved_target.is_file()
            ):
                raise RuntimeError("official symbolic link is unsafe or changed: %s" % name)
            digest.update(hashlib.sha256(target_bytes).digest())
            files += 1
            continue
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("tracked source is missing or non-regular: %s" % name)
        if mode not in {"100644", "100755"}:
            raise RuntimeError("official source file mode is unsupported: %s" % name)
        actual_executable = bool(path.stat().st_mode & 0o111)
        if actual_executable != (mode == "100755"):
            raise RuntimeError("official source executable mode changed: %s" % name)
        blob = subprocess.run(
            ["git", "--no-replace-objects", "cat-file", "blob", object_id],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            check=False,
        )
        if blob.returncode != 0:
            raise RuntimeError("official source Git blob is unreadable: %s" % name)
        working_bytes = path.read_bytes()
        if working_bytes != blob.stdout:
            raise RuntimeError("tracked source bytes differ from the Git index: %s" % name)
        digest.update(hashlib.sha256(working_bytes).digest())
        files += 1
    return {
        "files": files,
        "gitlinks": gitlinks,
        "content_sha256": digest.hexdigest(),
    }


def official_git_identity(root, expected_revision, expected_repository):
    root = Path(root).expanduser().resolve()
    if not (root / ".git").exists():
        raise RuntimeError("official source is not a Git checkout: %s" % root)
    if not FULL_GIT_REVISION.fullmatch(str(expected_revision or "")):
        raise RuntimeError("an exact 40-character expected revision is required")
    revision = _git_output(root, "rev-parse", "HEAD")
    if revision != expected_revision:
        raise RuntimeError(
            "source revision %s does not match required %s"
            % (revision, expected_revision)
        )
    status = _git_output(
        root, "status", "--porcelain=v1", "--untracked-files=all"
    )
    if status:
        raise RuntimeError("official benchmark source must be clean")
    remote = _git_output(root, "remote", "get-url", "origin")
    if _normalize_remote(remote) != _normalize_remote(expected_repository):
        raise RuntimeError("benchmark source origin is not the official repository")
    tree = _git_output(root, "rev-parse", "HEAD^{tree}")
    content = _tracked_content_identity(root)
    stage_entries = [
        entry.partition("\t")
        for entry in _git_output(root, "ls-files", "--stage").splitlines()
    ]
    tracked_modes = {
        name: metadata.split()[0]
        for metadata, separator, name in stage_entries
        if separator and name and len(metadata.split()) == 3
    }
    tracked_files = {
        name for name, mode in tracked_modes.items() if mode != "160000"
    }
    gitlink_roots = {
        item["path"] for item in content["gitlinks"]
    }
    actual_files = set()
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(root)
        if relative_directory == Path("."):
            directory_names[:] = [name for name in directory_names if name != ".git"]
        relative_prefix = "" if relative_directory == Path(".") else relative_directory.as_posix()
        if any(
            relative_prefix == gitlink
            or relative_prefix.startswith(gitlink + "/")
            for gitlink in gitlink_roots
        ):
            directory_names[:] = []
            continue
        for name in tuple(directory_names):
            candidate = directory_path / name
            if candidate.is_symlink():
                raise RuntimeError(
                    "official source contains a symbolic directory: %s"
                    % candidate.relative_to(root)
                )
        for name in file_names:
            candidate = directory_path / name
            relative = candidate.relative_to(root).as_posix()
            if candidate.is_symlink():
                target = os.readlink(candidate)
                resolved_target = (candidate.parent / target).resolve()
                if (
                    tracked_modes.get(relative) != "120000"
                    or os.path.isabs(target)
                    or root not in resolved_target.parents
                    or not resolved_target.is_file()
                ):
                    raise RuntimeError(
                        "official source contains an unsafe symbolic file: %s" % relative
                    )
            elif not candidate.is_file():
                raise RuntimeError("official source contains a non-regular file: %s" % relative)
            actual_files.add(relative)
    extras = sorted(actual_files - tracked_files)
    missing = sorted(tracked_files - actual_files)
    if extras or missing:
        raise RuntimeError(
            "official source export differs from its immutable Git tree "
            "(extra=%s missing=%s)" % (extras[:5], missing[:5])
        )
    return {
        "path": str(root),
        "repository": expected_repository,
        "origin": remote,
        "revision": revision,
        "git_tree": tree,
        "tracked_files": content["files"],
        "tracked_gitlinks": content["gitlinks"],
        "tracked_content_sha256": content["content_sha256"],
        "exported_files": len(actual_files),
        "export_matches_git": True,
        "clean": True,
    }


def _filesystem_export_identity(root):
    root = Path(root).resolve()
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("frozen benchmark source is missing or symbolic")
    entries = []
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in directory_names:
            if (directory_path / name).is_symlink():
                raise RuntimeError("frozen benchmark source contains a symbolic directory")
        for name in file_names:
            path = directory_path / name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError("frozen benchmark source contains a non-regular file")
            relative = path.relative_to(root).as_posix()
            mode = "100755" if path.stat().st_mode & 0o111 else "100644"
            content_sha256 = _sha256_file(path)
            entries.append(
                {
                    "path": relative,
                    "mode": mode,
                    "bytes": path.stat().st_size,
                    "sha256": content_sha256,
                }
            )
    entries.sort(key=lambda item: item["path"])
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(
            entry["path"].encode("utf-8")
            + b"\0"
            + entry["mode"].encode("ascii")
            + b"\0"
            + bytes.fromhex(entry["sha256"])
        )
    return {
        "files": len(entries),
        "tracked_content_sha256": digest.hexdigest(),
        "manifest_sha256": _canonical_sha256(entries),
    }


def _export_verified_git_tree(source, source_identity_record, destination):
    source = Path(source).resolve()
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("frozen benchmark source destination already exists")
    if source_identity_record.get("tracked_gitlinks"):
        raise RuntimeError("frozen Terminal-Bench source does not permit gitlinks")
    revision = source_identity_record.get("revision")
    completed = subprocess.run(
        ["git", "--no-replace-objects", "ls-tree", "-r", "-z", str(revision)],
        cwd=str(source),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("pinned Git tree cannot be exported")
    raw_entries = [item for item in completed.stdout.split(b"\0") if item]
    destination.mkdir(parents=True, mode=0o700)
    seen = set()
    try:
        for raw_entry in raw_entries:
            metadata, separator, raw_name = raw_entry.partition(b"\t")
            fields = metadata.decode("ascii").split()
            try:
                name = raw_name.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise RuntimeError("pinned Git tree path is not UTF-8") from exc
            relative = Path(name)
            if (
                not separator
                or len(fields) != 3
                or fields[0] not in {"100644", "100755"}
                or fields[1] != "blob"
                or not re.fullmatch(r"[0-9a-f]{40,64}", fields[2])
                or not relative.parts
                or relative.is_absolute()
                or ".." in relative.parts
                or name in seen
            ):
                raise RuntimeError("pinned Git tree entry is unsafe or unsupported")
            seen.add(name)
            mode, _object_type, object_id = fields
            blob = subprocess.run(
                ["git", "--no-replace-objects", "cat-file", "blob", object_id],
                cwd=str(source),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=120,
                check=False,
            )
            if blob.returncode != 0:
                raise RuntimeError("pinned Git tree blob is unreadable: %s" % name)
            path = _write_bytes_exclusive(destination / relative, blob.stdout)
            path.chmod(0o500 if mode == "100755" else 0o400)
        for directory in sorted(
            (item for item in destination.rglob("*") if item.is_dir()),
            key=lambda item: len(item.parts),
            reverse=True,
        ):
            directory.chmod(0o500)
        destination.chmod(0o500)
    except Exception:
        # The caller owns a new exclusive artifact directory. Leaving a partial,
        # non-runnable export is safer than reusing it on a retry.
        raise
    identity = _filesystem_export_identity(destination)
    if (
        identity["files"] != source_identity_record.get("tracked_files")
        or identity["tracked_content_sha256"]
        != source_identity_record.get("tracked_content_sha256")
    ):
        raise RuntimeError("frozen benchmark source differs from the verified Git tree")
    return {
        "path": str(destination.resolve()),
        "revision": revision,
        **identity,
        "read_only": True,
    }


def _validate_bound_frozen_source(record, paths, source_identity_record):
    required = {
        "path",
        "artifact_path",
        "revision",
        "files",
        "tracked_content_sha256",
        "manifest_sha256",
        "read_only",
    }
    if not isinstance(record, dict) or set(record) != required:
        raise RuntimeError("frozen benchmark source receipt is incomplete")
    root = Path(str(record.get("path") or ""))
    artifact_prefix = Path(str(record.get("artifact_path") or ""))
    if (
        root.is_symlink()
        or not root.is_dir()
        or not artifact_prefix.parts
        or artifact_prefix.is_absolute()
        or ".." in artifact_prefix.parts
        or record.get("revision") != source_identity_record.get("revision")
        or record.get("tracked_content_sha256")
        != source_identity_record.get("tracked_content_sha256")
        or record.get("read_only") is not True
    ):
        raise RuntimeError("frozen benchmark source receipt identity changed")
    actual = _filesystem_export_identity(root)
    if any(record.get(key) != value for key, value in actual.items()):
        raise RuntimeError("frozen benchmark source bytes or modes changed")
    expected_bound_paths = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("frozen benchmark source contains a symbolic path")
        if path.stat().st_mode & 0o222:
            raise RuntimeError("frozen benchmark source is writable")
        if path.is_file():
            relative = str(artifact_prefix / path.relative_to(root))
            if paths.get(relative) != path.resolve():
                raise RuntimeError("frozen benchmark source file is not artifact-bound")
            expected_bound_paths.add(relative)
    if root.stat().st_mode & 0o222:
        raise RuntimeError("frozen benchmark source root is writable")
    actual_bound_paths = {
        relative
        for relative in paths
        if Path(relative).parts[: len(artifact_prefix.parts)]
        == artifact_prefix.parts
    }
    if expected_bound_paths != actual_bound_paths:
        raise RuntimeError("frozen benchmark source artifact coverage changed")
    return root.resolve()


def _portable_runtime_tree_identity(root, excluded_roots=()):
    root = Path(root).resolve()
    excluded = {Path(path).resolve() for path in excluded_roots}
    entries = []
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        kept_directories = []
        for name in sorted(directory_names):
            candidate = directory_path / name
            if name == "__pycache__" or candidate.resolve() in excluded:
                continue
            if candidate.is_symlink():
                target = os.readlink(candidate)
                resolved = candidate.resolve()
                entries.append(
                    {
                        "path": candidate.relative_to(root).as_posix(),
                        "kind": "symlink-directory",
                        "target": (
                            str(resolved.relative_to(root))
                            if root in resolved.parents
                            else resolved.name
                        ),
                    }
                )
                continue
            kept_directories.append(name)
        directory_names[:] = kept_directories
        for name in sorted(file_names):
            if name.endswith((".pyc", ".pyo")) or name == ".DS_Store":
                continue
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                target = os.readlink(path)
                resolved = path.resolve()
                if not resolved.is_file():
                    raise RuntimeError("Harbor runtime contains a broken symbolic file")
                entries.append(
                    {
                        "path": relative,
                        "kind": "symlink-file",
                        "target": (
                            str(resolved.relative_to(root))
                            if root in resolved.parents
                            else resolved.name
                        ),
                        "target_sha256": _sha256_file(resolved),
                        "target_bytes": resolved.stat().st_size,
                    }
                )
                continue
            if not path.is_file():
                raise RuntimeError("Harbor runtime contains a non-regular file")
            entries.append(
                {
                    "path": relative,
                    "kind": "file",
                    "executable": bool(path.stat().st_mode & 0o111),
                    "bytes": path.stat().st_size,
                    "sha256": _sha256_file(path),
                }
            )
    entries.sort(key=lambda item: (item["path"], item["kind"]))
    return {
        "entries": len(entries),
        "manifest_sha256": _canonical_sha256(entries),
    }


def _harbor_full_runtime_attestation(python, python_realpath, site_packages):
    python = Path(python)
    python_realpath = Path(python_realpath)
    site_packages = Path(site_packages).resolve()
    venv_root = python.parent.parent.resolve()
    if venv_root not in site_packages.parents:
        raise RuntimeError("Harbor site-packages is outside its virtual environment")
    probe_source = (
        "import json,platform,site,sys,sysconfig;"
        "print(json.dumps({"
        "'base_prefix':sys.base_prefix,'prefix':sys.prefix,"
        "'implementation':sys.implementation.name,"
        "'cache_tag':sys.implementation.cache_tag,"
        "'version':platform.python_version(),"
        "'platform':platform.platform(),"
        "'stdlib':sysconfig.get_paths()['stdlib'],"
        "'purelib':sysconfig.get_paths()['purelib'],"
        "'user_site_enabled':site.ENABLE_USER_SITE"
        "},sort_keys=True))"
    )
    probe = subprocess.run(
        [str(python), "-I", "-c", probe_source],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
    )
    if probe.returncode != 0:
        raise RuntimeError("Harbor isolated Python runtime probe failed")
    try:
        runtime = json.loads(probe.stdout.strip())
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor isolated Python probe was not JSON") from exc
    base_prefix = Path(str(runtime.get("base_prefix") or "")).resolve()
    if (
        Path(str(runtime.get("prefix") or "")).resolve() != venv_root
        or Path(str(runtime.get("purelib") or "")).resolve() != site_packages
        or runtime.get("user_site_enabled") is not False
        or not base_prefix.is_dir()
        or not python_realpath.is_file()
    ):
        raise RuntimeError("Harbor isolated Python identity is inconsistent")
    site_identity = _portable_runtime_tree_identity(site_packages)
    base_identity = _portable_runtime_tree_identity(
        base_prefix,
        excluded_roots=(site_packages,),
    )
    startup_files = []
    for path in sorted(site_packages.rglob("*")):
        if path.is_file() and (
            path.suffix == ".pth" or path.name in {"sitecustomize.py", "usercustomize.py"}
        ):
            startup_files.append(
                {
                    "path": path.relative_to(site_packages).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": _sha256_file(path),
                }
            )
    payload = {
        "schema": "black-label-operator/harbor-runtime-attestation-v1",
        "python": {
            "implementation": runtime.get("implementation"),
            "cache_tag": runtime.get("cache_tag"),
            "version": runtime.get("version"),
            "platform": runtime.get("platform"),
            "executable_sha256": _sha256_file(python_realpath),
        },
        "base_runtime": base_identity,
        "site_packages": site_identity,
        "startup_files": startup_files,
        "isolated_probe": True,
        "user_site_enabled": False,
    }
    return {
        "sha256": _canonical_sha256(payload),
        "payload": payload,
    }


def _harbor_runtime_identity(executable=None):
    executable = Path(executable or shutil.which("harbor") or "").expanduser()
    if not str(executable) or not executable.exists():
        raise RuntimeError("Harbor 0.22 executable is missing")
    executable = executable.resolve()
    if not executable.is_file():
        raise RuntimeError("Harbor executable is not a regular file")
    try:
        wrapper = executable.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise RuntimeError("Harbor executable wrapper is unreadable") from exc
    lines = wrapper.splitlines()
    if not lines or not lines[0].startswith("#!"):
        raise RuntimeError("Harbor executable has no bound Python interpreter")
    python = Path(lines[0][2:].strip()).expanduser()
    if not python.is_file():
        raise RuntimeError("Harbor runtime Python is missing")
    python_realpath = python.resolve()
    normalized_wrapper = re.sub(
        r"^#!.*$", "#!<HARBOR_VENV_PYTHON>", wrapper, count=1, flags=re.MULTILINE
    )
    wrapper_template_sha256 = hashlib.sha256(
        normalized_wrapper.encode("utf-8")
    ).hexdigest()
    if wrapper_template_sha256 != OFFICIAL_HARBOR_WRAPPER_TEMPLATE_SHA256:
        raise RuntimeError("Harbor executable wrapper is not the pinned console entrypoint")
    site_packages = sorted(
        executable.parent.parent.glob("lib/python*/site-packages")
    )
    if len(site_packages) != 1:
        raise RuntimeError("Harbor site-packages root is ambiguous")
    site_packages = site_packages[0].resolve()
    dist_infos = sorted(site_packages.glob("harbor-*.dist-info"))
    if len(dist_infos) != 1:
        raise RuntimeError("Harbor distribution metadata is ambiguous")
    dist_info = dist_infos[0]
    metadata = (dist_info / "METADATA").read_text(encoding="utf-8")
    version_match = re.search(r"^Version:\s*(\S+)\s*$", metadata, re.MULTILINE)
    version = version_match.group(1) if version_match else None
    record_path = dist_info / "RECORD"
    if record_path.is_symlink() or not record_path.is_file():
        raise RuntimeError("Harbor wheel RECORD is missing")
    expected_entries = []
    mismatches = []
    try:
        with record_path.open(newline="", encoding="utf-8") as handle:
            for relative, encoded_hash, size_text in csv.reader(handle):
                if (
                    not relative.startswith("harbor/")
                    or "/__pycache__/" in relative
                    or relative.endswith((".pyc", ".pyo"))
                ):
                    continue
                if not encoded_hash.startswith("sha256=") or not size_text.isdigit():
                    raise RuntimeError("Harbor RECORD package entry is not hash-bound")
                encoded = encoded_hash.split("=", 1)[1]
                expected_hash = base64.urlsafe_b64decode(
                    encoded + "=" * ((4 - len(encoded) % 4) % 4)
                ).hex()
                expected_size = int(size_text)
                package_path = site_packages / relative
                if package_path.is_symlink() or not package_path.is_file():
                    actual_hash = None
                    actual_size = None
                else:
                    actual_hash = _sha256_file(package_path)
                    actual_size = package_path.stat().st_size
                expected_entries.append((relative, expected_hash, expected_size))
                if actual_hash != expected_hash or actual_size != expected_size:
                    mismatches.append(
                        {
                            "path": relative,
                            "expected_sha256": expected_hash,
                            "actual_sha256": actual_hash,
                            "expected_bytes": expected_size,
                            "actual_bytes": actual_size,
                        }
                    )
    except (OSError, ValueError) as exc:
        raise RuntimeError("Harbor wheel RECORD is invalid") from exc
    expected_digest = hashlib.sha256()
    for relative, expected_hash, expected_size in sorted(expected_entries):
        expected_digest.update(
            relative.encode("utf-8")
            + b"\0"
            + str(expected_size).encode("ascii")
            + b"\0"
            + bytes.fromhex(expected_hash)
        )
    version_process = subprocess.run(
        [str(executable), "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    reported_version = version_process.stdout.strip()
    if version_process.returncode != 0 or not reported_version:
        raise RuntimeError("Harbor executable version probe failed")
    wheel_record_matches = bool(
        version == OFFICIAL_HARBOR_VERSION
        and reported_version == OFFICIAL_HARBOR_VERSION
        and len(expected_entries) == OFFICIAL_HARBOR_PACKAGE_FILES
        and expected_digest.hexdigest() == OFFICIAL_HARBOR_RECORD_CONTENT_SHA256
        and not mismatches
    )
    full_attestation = _harbor_full_runtime_attestation(
        python, python_realpath, site_packages
    )
    full_attestation_matches = bool(
        HARBOR_CERTIFYING_RUNTIME_ATTESTATION_SHA256
        and full_attestation["sha256"]
        == HARBOR_CERTIFYING_RUNTIME_ATTESTATION_SHA256
    )
    return {
        "executable": str(executable),
        "executable_sha256": _sha256_file(executable),
        "wrapper_template_sha256": wrapper_template_sha256,
        "python": str(python),
        "python_realpath": str(python_realpath),
        "python_sha256": _sha256_file(python),
        "version": version,
        "reported_version": reported_version,
        "package_files": len(expected_entries),
        "record_content_sha256": expected_digest.hexdigest(),
        "record_sha256": _sha256_file(record_path),
        "record_mismatches": mismatches,
        "wheel_record_matches": wheel_record_matches,
        "full_runtime_attestation_sha256": full_attestation["sha256"],
        "full_runtime_attestation": full_attestation["payload"],
        "full_runtime_attestation_matches": full_attestation_matches,
        "stock_eligible": bool(
            wheel_record_matches and full_attestation_matches
        ),
        "certification_blocker": (
            None
            if wheel_record_matches and full_attestation_matches
            else (
                "full isolated Harbor interpreter/dependency/startup runtime is not attested"
                if wheel_record_matches
                else "Harbor package differs from its official wheel RECORD"
            )
        ),
    }


def _campaign_context(settings, campaign_name, lane):
    from .benchmark_campaign import find_campaign, load_campaign

    campaign_dir = find_campaign(settings, campaign_name)
    campaign = load_campaign(campaign_dir)
    contract = ((campaign.get("certification_contracts") or {}).get(
        "external_number_one"
    ) or {}).get("required_lanes", {}).get(lane)
    expected = EXTERNAL_NUMBER_ONE_LANES[lane]
    if contract != expected:
        raise RuntimeError("campaign external evidence contract is missing or changed")
    tree = (campaign.get("operator_source") or {}).get("tree_sha256")
    if not FULL_SHA256.fullmatch(str(tree or "")):
        raise RuntimeError("campaign has no exact frozen Operator source identity")
    frozen = Path(str(campaign.get("operator_source_path") or ""))
    if not frozen.is_dir() or source_identity(frozen).get("tree_sha256") != tree:
        raise RuntimeError("campaign frozen Operator source no longer matches")
    return campaign_dir, campaign, expected


def _official_quality_campaign_context(settings, campaign_name, lane):
    from .benchmark_campaign import find_campaign, load_campaign

    if lane not in OFFICIAL_QUALITY_LANES:
        raise RuntimeError("unknown official-quality lane")
    campaign_dir = find_campaign(settings, campaign_name)
    campaign = load_campaign(campaign_dir)
    expected_contract = official_quality_contract()
    embedded = (campaign.get("certification_contracts") or {}).get(
        "official_quality"
    )
    if embedded != expected_contract:
        raise RuntimeError("campaign official-quality contract is missing or changed")
    contract = (embedded.get("required_lanes") or {}).get(lane)
    expected = OFFICIAL_QUALITY_LANES[lane]
    if contract != expected:
        raise RuntimeError("campaign official-quality lane contract is missing or changed")
    if expected.get("provenance_ready") is not True or expected.get(
        "provenance_blockers"
    ):
        raise RuntimeError(
            "official benchmark provenance is incomplete: %s"
            % "; ".join(
                expected.get("provenance_blockers")
                or ["contract is not marked provenance-ready"]
            )
        )
    tree = (campaign.get("operator_source") or {}).get("tree_sha256")
    if not FULL_SHA256.fullmatch(str(tree or "")):
        raise RuntimeError("campaign has no exact frozen Operator source identity")
    if not isinstance(campaign.get("identity"), dict):
        raise RuntimeError("campaign has no exact benchmark identity")
    _timestamp(campaign.get("created_at"), "official-quality campaign creation")
    frozen = Path(str(campaign.get("operator_source_path") or ""))
    frozen_identity = source_identity(frozen) if frozen.is_dir() else None
    expected_frozen = campaign.get("frozen_operator_source")
    frozen_matches = (
        frozen_identity == expected_frozen
        if isinstance(expected_frozen, dict)
        else (
            isinstance(frozen_identity, dict)
            and frozen_identity.get("tree_sha256") == tree
        )
    )
    if not frozen_matches:
        raise RuntimeError("campaign frozen Operator source no longer matches")
    return Path(campaign_dir).resolve(), campaign, expected


def _official_quality_campaign_context(settings, campaign_name, lane):
    from .benchmark_campaign import find_campaign, load_campaign
    from .standard_benchmark import (
        OFFICIAL_QUALITY_LANES,
        official_quality_contract,
    )

    if lane not in OFFICIAL_QUALITY_LANES:
        raise RuntimeError("unknown official-quality lane")
    campaign_dir = find_campaign(settings, campaign_name)
    campaign = load_campaign(campaign_dir)
    embedded = (campaign.get("certification_contracts") or {}).get(
        "official_quality"
    )
    expected_contract = official_quality_contract()
    if embedded != expected_contract:
        raise RuntimeError("campaign official-quality contract is missing or changed")
    contract = (embedded.get("required_lanes") or {}).get(lane)
    if contract != OFFICIAL_QUALITY_LANES[lane]:
        raise RuntimeError("campaign official-quality lane contract is missing or changed")
    if contract.get("provenance_ready") is not True or contract.get(
        "provenance_blockers"
    ):
        raise RuntimeError(
            "official benchmark provenance is incomplete: %s"
            % "; ".join(
                contract.get("provenance_blockers")
                or ["contract is not marked provenance-ready"]
            )
        )
    tree = (campaign.get("operator_source") or {}).get("tree_sha256")
    if not FULL_SHA256.fullmatch(str(tree or "")):
        raise RuntimeError("campaign has no exact frozen Operator source identity")
    frozen = Path(str(campaign.get("operator_source_path") or ""))
    if not frozen.is_dir() or source_identity(frozen).get("tree_sha256") != tree:
        raise RuntimeError("campaign frozen Operator source no longer matches")
    return Path(campaign_dir).resolve(), campaign, contract


def _artifact_manifest(lane_dir, artifact_root):
    lane_dir = Path(lane_dir).resolve()
    artifact_root = Path(artifact_root).resolve()
    if lane_dir not in artifact_root.parents:
        raise RuntimeError("run artifacts must stay inside their evidence lane")
    artifacts = []
    for path in sorted(artifact_root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("run artifacts may not contain symbolic links")
        if not path.is_file():
            continue
        artifacts.append(
            {
                "path": str(path.relative_to(lane_dir)),
                "bytes": path.stat().st_size,
                "sha256": _sha256_file(path),
            }
        )
    if not artifacts:
        raise RuntimeError("comparable run produced no artifacts")
    return artifacts


def _seal_tree(root):
    root = Path(root)
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            path.chmod(0o500 if path.stat().st_mode & 0o111 else 0o400)
    for path in sorted(
        (item for item in root.rglob("*") if item.is_dir()),
        key=lambda item: len(item.parts),
        reverse=True,
    ):
        path.chmod(0o500)
    root.chmod(0o500)


def _process(command, cwd, env, stdout_path, stderr_path, timeout):
    timed_out = False
    termination_confirmed = True
    termination_detail = None
    with Path(stdout_path).open("w", encoding="utf-8") as stdout, Path(
        stderr_path
    ).open("w", encoding="utf-8") as stderr:
        new_session = should_start_new_session()
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=env,
            stdout=stdout,
            stderr=stderr,
            text=True,
            start_new_session=new_session,
        )
        try:
            process.wait(timeout=float(timeout))
        except subprocess.TimeoutExpired:
            timed_out = True
            process_group = process.pid if new_session and os.name != "nt" else None
            termination_confirmed, termination_detail = (
                CodexRunner.terminate_spawned(process, process_group)
            )
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                termination_confirmed = False
                termination_detail = "benchmark root process remained live"
    return {
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "termination_confirmed": termination_confirmed,
        "termination_detail": termination_detail,
    }


def _finalize_receipt(path, payload):
    body = dict(payload)
    body["payload_sha256"] = _canonical_sha256(body)
    return _write_json_exclusive(path, body)


def _aider_tasks(polyglot_root):
    root = Path(polyglot_root)
    tasks = sorted(
        str(path.relative_to(root))
        for language in root.iterdir()
        if language.is_dir()
        for path in (language / "exercises" / "practice").glob("*")
        if path.is_dir()
    )
    if len(tasks) != 225 or len(tasks) != len(set(tasks)):
        raise RuntimeError(
            "stock Aider Polyglot requires exactly 225 unique exercises"
        )
    return tasks


def _aider_commands(args, run_id, artifact_root, source, dataset):
    docker = shutil.which("docker")
    if not docker:
        raise RuntimeError("Docker is required for stock Aider Polyglot")
    image = "black-label-aider-stock:%s" % args.aider_revision[:12]
    build = [
        docker,
        "build",
        "--file",
        str(source / "benchmark" / "Dockerfile"),
        "--tag",
        image,
        str(source),
    ]
    container = "black-label-aider-stock-%s" % run_id.lower()
    run = [
        docker,
        "run",
        "--rm",
        "--name",
        container,
        "--memory=12g",
        "--memory-swap=12g",
        "--volume",
        "%s:/benchmarks" % artifact_root,
        "--volume",
        "%s:/benchmarks/polyglot-benchmark:ro" % dataset,
        "--env",
        "AIDER_DOCKER=1",
        "--env",
        "AIDER_BENCHMARK_DIR=/benchmarks",
    ]
    for name in args.credential_env:
        if not SAFE_ENV_NAME.fullmatch(name):
            raise RuntimeError("invalid credential environment name: %s" % name)
        run.extend(["--env", name])
    run.extend(
        [
            image,
            "python3",
            "/aider/benchmark/benchmark.py",
            run_id,
            "--model",
            args.model,
            "--edit-format",
            args.edit_format,
            "--threads",
            str(args.threads),
            "--tries",
            "2",
            "--num-tests",
            "225",
            "--exercises-dir",
            "polyglot-benchmark",
        ]
    )
    if args.reasoning_effort:
        run.extend(["--reasoning-effort", args.reasoning_effort])
    return image, build, run


def aider_stock(args, settings, execute=False):
    lane = "aider-polyglot-stock"
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    aider_revision = _contract_git_pin(
        contract,
        "runner_repository",
        "runner_revision",
        OFFICIAL_AIDER_REPOSITORY,
        "stock Aider",
    )
    polyglot_revision = _contract_git_pin(
        contract,
        "dataset_repository",
        "dataset_revision",
        OFFICIAL_POLYGLOT_REPOSITORY,
        "Aider Polyglot dataset",
    )
    if args.aider_revision != aider_revision:
        raise RuntimeError("stock Aider revision does not match the contract")
    if args.polyglot_revision != polyglot_revision:
        raise RuntimeError("Aider Polyglot revision does not match the contract")
    _require_exact_sol_model(
        args.model, args.expected_resolved_model, "stock Aider"
    )
    source = Path(args.aider_source).expanduser().resolve()
    dataset = Path(args.polyglot_source).expanduser().resolve()
    source_before = official_git_identity(
        source, aider_revision, OFFICIAL_AIDER_REPOSITORY
    )
    dataset_before = official_git_identity(
        dataset, polyglot_revision, OFFICIAL_POLYGLOT_REPOSITORY
    )
    tasks = _aider_tasks(dataset)
    if not args.edit_format.strip():
        raise RuntimeError("the stock Aider edit format must be explicit")
    if int(args.threads) < 1:
        raise RuntimeError("Aider threads must be positive")
    run_id = args.run_id or time.strftime("%Y-%m-%d-%H-%M-%S--") + uuid.uuid4().hex[:8]
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]{7,100}", run_id):
        raise RuntimeError("Aider run ID is unsafe")
    lane_dir = campaign_dir / "external-evidence" / lane
    artifact_root = lane_dir / "artifacts" / run_id
    image, build_command, run_command = _aider_commands(
        args, run_id, artifact_root, source, dataset
    )
    plan = {
        "lane": lane,
        "protocol": contract["protocol"],
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": "stock-aider-benchmark",
        "custom_operator_agent": False,
        "aider_source": source_before,
        "dataset": dict(dataset_before, exercises=len(tasks), task_ids_sha256=_canonical_sha256(tasks)),
        "model": {
            "requested": args.model,
            "expected_resolved": args.expected_resolved_model,
            "edit_format": args.edit_format,
            "reasoning_effort": args.reasoning_effort,
        },
        "tries": 2,
        "exercises": 225,
        "image": image,
        "build_command": build_command,
        "run_command": run_command,
        "execute": bool(execute),
    }
    if not execute:
        return plan
    missing = [name for name in args.credential_env if not os.environ.get(name)]
    if not args.credential_env or missing:
        raise RuntimeError(
            "stock Aider provider credentials are missing: %s"
            % (", ".join(missing) if missing else "--credential-env is required")
        )
    if artifact_root.exists():
        raise RuntimeError("Aider run artifacts already exist: %s" % artifact_root)
    artifact_root.mkdir(parents=True, mode=0o700)
    started = time.time()
    env = os.environ.copy()
    build_result = _process(
        build_command,
        source,
        env,
        artifact_root / "docker-build.stdout.log",
        artifact_root / "docker-build.stderr.log",
        args.build_timeout,
    )
    run_result = None
    image_id = None
    if build_result["exit_code"] == 0 and not build_result["timed_out"]:
        inspected = subprocess.run(
            [shutil.which("docker"), "image", "inspect", "--format={{.Id}}", image],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
        )
        image_id = inspected.stdout.strip() if inspected.returncode == 0 else None
        run_result = _process(
            run_command,
            source,
            env,
            artifact_root / "aider.stdout.log",
            artifact_root / "aider.stderr.log",
            args.timeout,
        )
    source_after = official_git_identity(
        source, aider_revision, OFFICIAL_AIDER_REPOSITORY
    )
    dataset_after = official_git_identity(
        dataset, polyglot_revision, OFFICIAL_POLYGLOT_REPOSITORY
    )
    identity_stable = source_before == source_after and dataset_before == dataset_after
    output_dir = artifact_root / run_id
    result_files = sorted(output_dir.glob("*/exercises/practice/*/.aider.results.json"))
    results = []
    errors = []
    for path in result_files:
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append("invalid result %s: %s" % (path.name, exc))
            continue
        outcomes = item.get("tests_outcomes")
        if not isinstance(outcomes, list) or not 1 <= len(outcomes) <= 2:
            errors.append("result does not contain one or two stock tries: %s" % path)
            continue
        if item.get("model") != args.expected_resolved_model:
            errors.append("resolved model identity mismatch: %s" % path)
        if item.get("edit_format") != args.edit_format:
            errors.append("edit-format identity mismatch: %s" % path)
        if item.get("commit_hash") != aider_revision[:7]:
            errors.append("Aider source identity mismatch: %s" % path)
        results.append(bool(outcomes[-1]))
    completed = len(results)
    passed = sum(results)
    clean = bool(
        run_result
        and run_result["exit_code"] == 0
        and not run_result["timed_out"]
        and run_result["termination_confirmed"]
        and identity_stable
        and completed == len(tasks) == 225
        and not errors
    )
    score = {"passed": passed, "total": 225} if clean else None
    if clean:
        (artifact_root / "summary.json").write_text(
            json.dumps(
                {"completed": completed, "passed_after_two_tries": passed},
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
    artifacts = _artifact_manifest(lane_dir, artifact_root)
    payload = {
        "schema": COMPARABLE_RUN_SCHEMA,
        "lane": lane,
        "protocol": contract["protocol"],
        "status": "completed" if clean else "blocked",
        "scope": "full" if clean else "incomplete",
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": {
            "kind": "stock-aider-benchmark",
            "custom_operator_agent": False,
            "tries": 2,
            "exercises": 225,
            "aider_source": source_before,
            "container_image": image,
            "container_image_id": image_id,
        },
        "dataset": dict(dataset_before, exercises=225, task_ids_sha256=_canonical_sha256(tasks)),
        "model": plan["model"],
        "command": {"build": build_command, "run": run_command},
        "process": {"build": build_result, "run": run_result},
        "identity_stable": identity_stable,
        "score": score,
        "diagnostics": {"completed": completed, "errors": errors},
        "started_at": started,
        "finished_at": time.time(),
        "artifacts": artifacts,
    }
    receipt = lane_dir / (run_id + "-run-receipt.json")
    _finalize_receipt(receipt, payload)
    _seal_tree(artifact_root)
    return {"receipt": str(receipt), "status": payload["status"], "score": score}


def _arc_config(uv, source, config_id):
    completed = subprocess.run(
        [
            uv,
            "run",
            "--project",
            str(source),
            "--frozen",
            "python",
            "-c",
            ARC_CONFIG_SOURCE,
            config_id,
        ],
        cwd=str(source),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=600,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "official ARC model config lookup failed: %s"
            % (completed.stderr.strip() or "no output")
        )
    try:
        payload = json.loads(completed.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise RuntimeError("official ARC model config was not machine-readable") from exc
    if payload.get("id") != config_id:
        raise RuntimeError("ARC model config identity mismatch")
    model = (payload.get("request") or {}).get("model")
    api_key_env = (payload.get("client") or {}).get("api_key_env")
    if not model or not SAFE_ENV_NAME.fullmatch(str(api_key_env or "")):
        raise RuntimeError("ARC model config lacks an exact model or credential identity")
    return payload


def _scorecard_from_log(text):
    marker = "--- FINAL SCORECARD REPORT ---"
    position = text.rfind(marker)
    if position < 0:
        return None
    fragment = text[position + len(marker) :]
    object_at = fragment.find("{")
    if object_at < 0:
        return None
    try:
        payload, _remainder = json.JSONDecoder().raw_decode(fragment[object_at:])
    except json.JSONDecodeError:
        return None
    if isinstance(payload, dict):
        payload.pop("api_key", None)
        return payload
    return None


def _arc_integrity(scorecard, recordings, required_tag):
    errors = []
    environments = scorecard.get("environments") if isinstance(scorecard, dict) else None
    if not isinstance(environments, list) or len(environments) != 25:
        errors.append("official scorecard does not contain 25 environments")
        environments = []
    ids = [item.get("id") for item in environments if isinstance(item, dict)]
    if len(ids) != 25 or any(not item for item in ids) or len(set(ids)) != 25:
        errors.append("official scorecard environment IDs are missing or duplicated")
    tags = scorecard.get("tags") if isinstance(scorecard, dict) else None
    if not isinstance(tags, list) or required_tag not in tags:
        errors.append("official scorecard is missing the source-bound run tag")
    card_id = scorecard.get("card_id") if isinstance(scorecard, dict) else None
    if not isinstance(card_id, str) or not card_id:
        errors.append("official scorecard card_id is missing")
    scores = []
    for environment in environments:
        value = environment.get("score") if isinstance(environment, dict) else None
        runs = environment.get("runs") if isinstance(environment, dict) else None
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or not 0 <= float(value) <= 100
            or not isinstance(runs, list)
            or not runs
        ):
            errors.append("official scorecard has a malformed environment")
            continue
        scores.append(float(value))
    official = scorecard.get("score") if isinstance(scorecard, dict) else None
    recomputed = sum(scores) / len(scores) if len(scores) == 25 else None
    if (
        isinstance(official, bool)
        or not isinstance(official, (int, float))
        or recomputed is None
        or not math.isclose(float(official), recomputed, rel_tol=0, abs_tol=1e-7)
    ):
        errors.append("official scorecard aggregate is invalid")
    recording_ids = set()
    invalid_recordings = 0
    for path in recordings:
        ids_in_file = set()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
            for line in lines:
                data = (json.loads(line).get("data") or {})
                game_id = data.get("game_id") or data.get("id")
                if game_id:
                    ids_in_file.add(str(game_id))
        except (OSError, json.JSONDecodeError, AttributeError):
            invalid_recordings += 1
            continue
        if len(ids_in_file) != 1:
            invalid_recordings += 1
        recording_ids.update(ids_in_file)
    if invalid_recordings or recording_ids != set(ids):
        errors.append("official recordings do not exactly cover the scorecard")
    return {
        "valid": not errors,
        "errors": errors,
        "score": float(official) if not errors else None,
        "card_id": card_id,
        "environment_ids": sorted(str(item) for item in ids if item),
        "environment_ids_sha256": _canonical_sha256(sorted(str(item) for item in ids if item)),
        "scorecard_sha256": _canonical_sha256(scorecard) if isinstance(scorecard, dict) else None,
        "recordings": len(recordings),
    }


def arc_standardized(args, settings, execute=False):
    lane = "arc-agi-3-standardized"
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    arc_revision = _contract_git_pin(
        contract,
        "runner_repository",
        "runner_revision",
        OFFICIAL_ARC_REPOSITORY,
        "standardized ARC",
    )
    if args.arc_revision != arc_revision:
        raise RuntimeError("standardized ARC revision does not match the contract")
    source = Path(args.arc_source).expanduser().resolve()
    source_before = official_git_identity(
        source, arc_revision, OFFICIAL_ARC_REPOSITORY
    )
    config_pin = _arc_config_contract_pin(contract)
    if config_pin is None:
        plan = {
            "lane": lane,
            "protocol": contract["protocol"],
            "campaign": campaign["id"],
            "operator_source": campaign["operator_source"],
            "runner": "arc-official-benchmarking-agent",
            "custom_operator_planner": False,
            "arc_source": source_before,
            "eligible": False,
            "certification_blockers": [ARC_STANDARDIZED_CONFIG_BLOCKER],
            "model": {
                "required_requested_model": SOL_MODEL,
                "required_resolved_model": SOL_MODEL,
                "contract_config": None,
            },
            "official_games": 25,
            "command": None,
            "execute": bool(execute),
        }
        if not execute:
            return plan
        raise RuntimeError(
            "standardized ARC comparable run is ineligible: %s"
            % ARC_STANDARDIZED_CONFIG_BLOCKER
        )
    if args.config != config_pin["config_id"]:
        raise RuntimeError("standardized ARC config does not match the contract")
    uv = shutil.which("uv")
    if not uv:
        raise RuntimeError("uv is required for standardized ARC-AGI-3")
    config_path = source / "benchmarking" / "model_configs.yaml"
    if config_path.is_symlink() or not config_path.is_file():
        raise RuntimeError("official ARC model config file is missing")
    if _sha256_file(config_path) != config_pin["config_file_sha256"]:
        raise RuntimeError("standardized ARC model-config file does not match the contract")
    config = _arc_config(uv, source, config_pin["config_id"])
    if _canonical_sha256(config) != config_pin["config_sha256"]:
        raise RuntimeError("standardized ARC model config does not match the contract")
    _require_exact_sol_model(
        config_pin["resolved_model"],
        (config.get("request") or {}).get("model"),
        "standardized ARC",
    )
    run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]{7,100}", run_id):
        raise RuntimeError("ARC run ID is unsafe")
    lane_dir = campaign_dir / "external-evidence" / lane
    artifact_root = lane_dir / "artifacts" / run_id
    run_tag = "black-label-operator-comparable-" + campaign["operator_source"]["tree_sha256"][:16]
    command = [
        uv,
        "run",
        "--project",
        str(source),
        "--frozen",
        "python",
        "main.py",
        "--config",
        args.config,
        "--tags",
        run_tag + ",standardized-model,full-25",
    ]
    plan = {
        "lane": lane,
        "protocol": contract["protocol"],
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": "arc-official-benchmarking-agent",
        "custom_operator_planner": False,
        "arc_source": source_before,
        "eligible": True,
        "certification_blockers": [],
        "model": {
            "requested_model": SOL_MODEL,
            "expected_resolved_model": SOL_MODEL,
            "config_id": config_pin["config_id"],
            "config_sha256": _canonical_sha256(config),
            "config_file_sha256": _sha256_file(config_path),
            "resolved_model": config["request"]["model"],
            "runtime": config.get("runtime"),
            "client": {
                key: value
                for key, value in (config.get("client") or {}).items()
                if key != "api_key"
            },
            "request": config.get("request"),
        },
        "official_games": 25,
        "command": command,
        "execute": bool(execute),
    }
    if not execute:
        return plan
    required_env = ["ARC_API_KEY", str(config["client"]["api_key_env"])]
    missing = [name for name in required_env if not os.environ.get(name)]
    if missing:
        raise RuntimeError("standardized ARC credentials are missing: %s" % ", ".join(missing))
    if artifact_root.exists():
        raise RuntimeError("ARC run artifacts already exist: %s" % artifact_root)
    recordings_dir = artifact_root / "recordings"
    recordings_dir.mkdir(parents=True, mode=0o700)
    env = os.environ.copy()
    env["ARC_BASE_URL"] = "https://arcprize.org"
    env["ONLINE_ONLY"] = "True"
    env["RECORDINGS_DIR"] = str(recordings_dir)
    started = time.time()
    process = _process(
        command,
        source,
        env,
        artifact_root / "arc.stdout.log",
        artifact_root / "arc.stderr.log",
        args.timeout,
    )
    log = (artifact_root / "arc.stdout.log").read_text(
        encoding="utf-8", errors="replace"
    ) + "\n" + (artifact_root / "arc.stderr.log").read_text(
        encoding="utf-8", errors="replace"
    )
    scorecard = _scorecard_from_log(log)
    if scorecard:
        (artifact_root / "scorecard.json").write_text(
            json.dumps(scorecard, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    recordings = sorted(recordings_dir.glob("*.recording.jsonl"))
    integrity = _arc_integrity(scorecard or {}, recordings, run_tag)
    source_after = official_git_identity(
        source, arc_revision, OFFICIAL_ARC_REPOSITORY
    )
    clean = bool(
        process["exit_code"] == 0
        and not process["timed_out"]
        and process["termination_confirmed"]
        and source_before == source_after
        and integrity["valid"]
    )
    score = (
        {"value": integrity["score"], "completed_units": 25, "scale": 100}
        if clean
        else None
    )
    artifacts = _artifact_manifest(lane_dir, artifact_root)
    payload = {
        "schema": COMPARABLE_RUN_SCHEMA,
        "lane": lane,
        "protocol": contract["protocol"],
        "status": "completed" if clean else "blocked",
        "scope": "full" if clean else "incomplete",
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": {
            "kind": "arc-official-benchmarking-agent",
            "custom_operator_planner": False,
            "official_games": 25,
            "arc_source": source_before,
        },
        "model": plan["model"],
        "command": command,
        "environment": {
            "ARC_BASE_URL": "https://arcprize.org",
            "ONLINE_ONLY": "True",
            "credential_env_names": required_env,
        },
        "process": process,
        "identity_stable": source_before == source_after,
        "score": score,
        "scorecard": integrity,
        "started_at": started,
        "finished_at": time.time(),
        "artifacts": artifacts,
    }
    receipt = lane_dir / (run_id + "-run-receipt.json")
    _finalize_receipt(receipt, payload)
    _seal_tree(artifact_root)
    return {"receipt": str(receipt), "status": payload["status"], "score": score}


def _run_id(value, label):
    value = value or time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    if not SAFE_RUN_ID.fullmatch(value):
        raise RuntimeError("%s run ID is unsafe" % label)
    return value


def _relative_to_lane(path, lane_dir, label):
    path = Path(path).resolve()
    lane_dir = Path(lane_dir).resolve()
    if lane_dir not in path.parents:
        raise RuntimeError("%s is outside its evidence lane" % label)
    return str(path.relative_to(lane_dir))


def _frozen_operator_version(campaign):
    path = Path(campaign["operator_source_path"]) / "blacklabel_operator" / "__init__.py"
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("frozen Operator version source is missing")
    match = re.search(
        r'^__version__\s*=\s*["\']([^"\']+)["\']\s*$',
        path.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise RuntimeError("frozen Operator version is not machine-readable")
    return match.group(1)


def _harbor_result_json(path, label="Harbor trial result"):
    path = Path(path)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise RuntimeError("%s exceeds its byte limit" % label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("%s is not valid Harbor JSON" % label) from exc


def _terminal_tasks(source, harbor_runtime=None):
    tasks_root = Path(source) / "tasks"
    manifest = tasks_root / "dataset.toml"
    if manifest.is_symlink() or not manifest.is_file():
        raise RuntimeError("Terminal-Bench 4 dataset manifest is missing")
    if _sha256_file(manifest) != OFFICIAL_TERMINAL_DATASET_FILE_SHA256:
        raise RuntimeError("Terminal-Bench 4 dataset manifest hash changed")
    dataset_entries = []
    for block in manifest.read_text(encoding="utf-8").split("[[tasks]]")[1:]:
        name_match = re.search(r'^name\s*=\s*"([^"]+)"\s*$', block, re.MULTILINE)
        digest_match = re.search(
            r'^digest\s*=\s*"(sha256:[0-9a-f]{64})"\s*$',
            block,
            re.MULTILINE,
        )
        if not name_match or not digest_match:
            raise RuntimeError("Terminal-Bench dataset task entry is malformed")
        dataset_entries.append(
            {"name": name_match.group(1), "digest": digest_match.group(1)}
        )
    dataset_entries.sort(key=lambda item: item["name"])
    if (
        len(dataset_entries) != 66
        or len({item["name"] for item in dataset_entries}) != 66
        or _canonical_sha256(dataset_entries)
        != OFFICIAL_TERMINAL_DATASET_ENTRIES_SHA256
    ):
        raise RuntimeError("Terminal-Bench dataset digest manifest changed")
    declared = {item["name"]: item["digest"] for item in dataset_entries}
    tasks = []
    for path in sorted(tasks_root.iterdir()):
        task_toml = path / "task.toml"
        if not path.is_dir() or path.is_symlink() or not task_toml.is_file():
            continue
        text = task_toml.read_text(encoding="utf-8")
        section_match = re.search(
            r"^\[task\]\s*$([\s\S]*?)(?=^\[|\Z)", text, re.MULTILINE
        )
        name_match = (
            re.search(
                r'^name\s*=\s*"([^"]+)"\s*$',
                section_match.group(1),
                re.MULTILINE,
            )
            if section_match
            else None
        )
        if not name_match:
            raise RuntimeError("Terminal-Bench task.toml has no exact [task].name")
        canonical_name = name_match.group(1)
        if canonical_name != "terminal-bench/" + path.name:
            raise RuntimeError("Terminal-Bench directory/name mapping changed")
        if canonical_name not in declared:
            raise RuntimeError("Terminal-Bench task is absent from dataset.toml")
        tasks.append(
            {
                "directory": path.name,
                "name": canonical_name,
                "declared_digest": declared[canonical_name],
            }
        )
    if (
        len(tasks) != 66
        or len({item["name"] for item in tasks}) != 66
        or _canonical_sha256([item["name"] for item in tasks])
        != OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256
        or _canonical_sha256(
            [
                {"directory": item["directory"], "name": item["name"]}
                for item in tasks
            ]
        )
        != OFFICIAL_TERMINAL_DIRECTORY_NAME_MANIFEST_SHA256
        or set(declared) != {item["name"] for item in tasks}
    ):
        raise RuntimeError("Terminal-Bench 4 requires the exact 66-task manifest")
    harbor_runtime = harbor_runtime or _harbor_runtime_identity()
    digest_script = r'''
import json
import sys
from pathlib import Path
from harbor.models.task.task import Task
from harbor.publisher.packager import Packager
root = Path(sys.argv[1])
print(json.dumps({
    path.name: {
        "runtime_digest": "sha256:" + Packager.compute_content_hash(path)[0],
        "runtime_dirhash": Task(path).checksum,
    }
    for path in sorted(root.iterdir())
    if path.is_dir() and (path / "task.toml").is_file()
}, sort_keys=True))
'''
    completed = subprocess.run(
        [harbor_runtime["python"], "-c", digest_script, str(tasks_root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    try:
        runtime_digests = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor task content digest probe failed") from exc
    if completed.returncode != 0 or set(runtime_digests) != {
        item["directory"] for item in tasks
    }:
        raise RuntimeError("Harbor task content digest probe failed")
    for item in tasks:
        item.update(runtime_digests[item["directory"]])
    if _canonical_sha256(tasks) != OFFICIAL_TERMINAL_RUNTIME_MANIFEST_SHA256:
        raise RuntimeError("Terminal-Bench runtime task content manifest changed")
    return tasks


def _terminal_trial_payload(path, expected_task=None, expected_model=None):
    payload = _harbor_result_json(path)
    required_fields = {
        "id",
        "task_name",
        "trial_name",
        "trial_uri",
        "task_id",
        "source",
        "task_checksum",
        "config",
        "agent_info",
        "agent_result",
        "verifier_result",
        "verifier_environment_mode",
        "exception_info",
        "started_at",
        "finished_at",
        "environment_setup",
        "agent_setup",
        "agent_execution",
        "verifier",
        "step_results",
    }
    if not isinstance(payload, dict) or required_fields != set(payload):
        raise RuntimeError("Terminal-Bench Harbor result fields are not exact")
    task_id = payload.get("task_name") if isinstance(payload, dict) else None
    trial_name = payload.get("trial_name") if isinstance(payload, dict) else None
    config = payload.get("config") or {}
    agent_config = config.get("agent") or {}
    kwargs = agent_config.get("kwargs") or {}
    agent_info = payload.get("agent_info") or {}
    model_info = agent_info.get("model_info") or {}
    reward = ((payload.get("verifier_result") or {}).get("rewards") or {}).get(
        "reward"
    )
    error = payload.get("exception_info")
    quota_error = quota_info_for_trial(Path(path).parent)
    if quota_error is not None:
        error = quota_error
    verifier_log = Path(path).parent / "verifier" / "test-stdout.txt"
    if error is None and verifier_log.is_file():
        text = verifier_log.read_text(encoding="utf-8", errors="replace")
        if any(marker in text for marker in VERIFIER_INFRASTRUCTURE_MARKERS):
            error = {"exception_type": "VerifierInfrastructureError"}
    agent_result = payload.get("agent_result") or {}
    metadata = agent_result.get("metadata") or {}
    try:
        trial_uuid = str(uuid.UUID(str(payload.get("id"))))
        started_at = _timestamp(payload.get("started_at"), "Harbor trial start")
        finished_at = _timestamp(payload.get("finished_at"), "Harbor trial finish")
    except (ValueError, RuntimeError) as exc:
        raise RuntimeError("Terminal-Bench Harbor trial identity is invalid") from exc
    trial_uri = urlparse(str(payload.get("trial_uri") or ""))
    trial_path = Path(path).parent.resolve()
    uri_path = Path(trial_uri.path).resolve() if trial_uri.scheme == "file" else None
    expected_kwargs = {
        "reasoning_effort": "xhigh",
        "review_passes": 0,
        "benchmark_suite": "terminal-bench-current",
        "codex_version": (
            expected_model.get("codex_version") if expected_model else kwargs.get("codex_version")
        ),
        "operator_version": (
            expected_model.get("operator_version")
            if expected_model
            else kwargs.get("operator_version")
        ),
        "config": CODEX_BENCHMARK_CONFIG,
    }
    phase_times = []
    for phase_name in ("environment_setup", "agent_setup", "agent_execution", "verifier"):
        phase = payload.get(phase_name)
        if not isinstance(phase, dict) or set(phase) != {"started_at", "finished_at"}:
            raise RuntimeError("Terminal-Bench Harbor phase timing is incomplete")
        phase_start = _timestamp(
            phase.get("started_at"), "Harbor %s start" % phase_name
        )
        phase_finish = _timestamp(
            phase.get("finished_at"), "Harbor %s finish" % phase_name
        )
        if phase_finish < phase_start:
            raise RuntimeError("Terminal-Bench Harbor phase timing is reversed")
        phase_times.append((phase_start, phase_finish))
    if (
        not isinstance(task_id, str)
        or not task_id
        or (expected_task is not None and task_id != expected_task)
        or not isinstance(trial_name, str)
        or not trial_name
        or trial_name != trial_path.name
        or trial_uri.scheme != "file"
        or uri_path != trial_path
        or not FULL_SHA256.fullmatch(str(payload.get("task_checksum") or ""))
        or trial_uuid != str(payload.get("id"))
        or finished_at < started_at
        or any(
            phase_start < started_at - 1 or phase_finish > finished_at + 1
            for phase_start, phase_finish in phase_times
        )
        or any(
            phase_times[index][0] < phase_times[index - 1][1]
            for index in range(1, len(phase_times))
        )
        or payload.get("source") != "tasks"
        or payload.get("verifier_environment_mode") not in ("shared", "separate")
        or payload.get("step_results") is not None
        or config.get("trial_name") != trial_name
        or agent_config.get("name") != OPERATOR_HARBOR_AGENT
        or agent_config.get("model_name") != SOL_MODEL
        or kwargs != expected_kwargs
        or agent_info.get("name") != "black-label-operator"
        or set(agent_info) != {"name", "version", "model_info"}
        or set(model_info) != {"name", "provider"}
        or model_info.get("name") != SOL_MODEL
        or model_info.get("provider") != "openai"
        or isinstance(reward, bool)
        or reward not in (0, 1, 0.0, 1.0)
        or error is not None
        or not isinstance(metadata.get("operator_task_id"), str)
        or not metadata.get("operator_task_id")
    ):
        raise RuntimeError("Terminal-Bench Harbor result metadata is not comparable")
    if expected_model is not None and (
        kwargs.get("codex_version") != expected_model.get("codex_version")
        or kwargs.get("operator_version") != expected_model.get("operator_version")
        or agent_info.get("version") != expected_model.get("operator_version")
        or metadata.get("operator_profile") != "sol"
        or metadata.get("operator_provider") != "codex"
        or metadata.get("operator_model") != SOL_MODEL
    ):
        raise RuntimeError("Terminal-Bench model/config identity changed")
    return payload, task_id, trial_name, int(float(reward) == 1.0)


def _validate_terminal_result_config(
    payload, trial_lock, task, model, source, expected_job_id, expected_job_root
):
    config = payload.get("config") if isinstance(payload, dict) else None
    task_path = (Path(source) / "tasks" / task["directory"]).resolve()
    expected_kwargs = {
        "reasoning_effort": "xhigh",
        "codex_version": model.get("codex_version"),
        "operator_version": model.get("operator_version"),
        "review_passes": 0,
        "benchmark_suite": "terminal-bench-current",
        "config": CODEX_BENCHMARK_CONFIG,
    }
    expected_agent = {
        "name": OPERATOR_HARBOR_AGENT,
        "import_path": None,
        "model_name": SOL_MODEL,
        "n_concurrent": None,
        "concurrency_group": None,
        "skills": [],
        "override_timeout_sec": None,
        "override_setup_timeout_sec": None,
        "max_timeout_sec": None,
        "resume_trajectory": False,
        "load_trajectory": None,
        "extra_allowed_hosts": [],
        "kwargs": expected_kwargs,
        "env": {
            "CODEX_AUTH_JSON_PATH": "****",
            "OPERATOR_SUPERVISED_PROCESS_GROUP": "1",
        },
        "mcp_servers": [],
    }
    expected_environment = {
        "type": "docker",
        "import_path": None,
        "force_build": True,
        "delete": True,
        "cpu_enforcement_policy": "auto",
        "memory_enforcement_policy": "auto",
        "override_cpus": None,
        "override_memory_mb": None,
        "override_storage_mb": None,
        "override_gpus": None,
        "override_tpu": None,
        "mounts": None,
        "extra_docker_compose": [],
        "kwargs": {},
        "extra_allowed_hosts": [],
    }
    expected_task = {
        "path": str(task_path),
        "git_url": None,
        "git_commit_id": None,
        "name": None,
        "ref": None,
        "overwrite": False,
        "download_dir": None,
        "source": "tasks",
    }
    expected_root_keys = {
        "task",
        "trial_name",
        "trials_dir",
        "install_only",
        "timeout_multiplier",
        "agent_timeout_multiplier",
        "verifier_timeout_multiplier",
        "agent_setup_timeout_multiplier",
        "environment_build_timeout_multiplier",
        "agent",
        "user_agent",
        "environment",
        "verifier",
        "artifacts",
        "extra_instruction_paths",
        "extra_instructions",
        "job_id",
        "source_trial",
    }
    result_task_id = payload.get("task_id") or {}
    if (
        not isinstance(config, dict)
        or set(config) != expected_root_keys
        or config.get("task") != expected_task
        or config.get("trial_name") != payload.get("trial_name")
        or Path(str(config.get("trials_dir") or "")).resolve()
        != Path(expected_job_root).resolve()
        or config.get("install_only") is not False
        or config.get("timeout_multiplier") != 1.0
        or config.get("agent_timeout_multiplier") != 24.0
        or config.get("verifier_timeout_multiplier") is not None
        or config.get("agent_setup_timeout_multiplier") != 4.0
        or config.get("environment_build_timeout_multiplier") != 4.0
        or config.get("agent") != expected_agent
        or config.get("user_agent") is not None
        or config.get("environment") != expected_environment
        or config.get("verifier")
        != {
            "override_timeout_sec": None,
            "max_timeout_sec": None,
            "disable": False,
        }
        or config.get("artifacts") != []
        or config.get("extra_instruction_paths") != []
        or config.get("extra_instructions") != []
        or config.get("source_trial") is not None
        or str(config.get("job_id")) != str(expected_job_id)
        or set(result_task_id) != {"path"}
        or Path(str(result_task_id.get("path") or "")).resolve() != task_path
        or (trial_lock.get("agent") or {})
        != {
            key: value
            for key, value in expected_agent.items()
            if value is not None
            and key
            not in {
                "import_path",
                "n_concurrent",
                "concurrency_group",
                "override_timeout_sec",
                "override_setup_timeout_sec",
                "max_timeout_sec",
                "load_trajectory",
            }
        }
        or (trial_lock.get("environment") or {})
        != {
            "type": "docker",
            "force_build": True,
            "delete": True,
            "cpu_enforcement_policy": "auto",
            "memory_enforcement_policy": "auto",
            "extra_docker_compose": [],
            "kwargs": {},
            "extra_allowed_hosts": [],
        }
    ):
        raise RuntimeError(
            "Harbor TrialResult config is not the exact job/trial-lock protocol"
        )
    try:
        if str(uuid.UUID(str(config.get("job_id")))) != str(config.get("job_id")):
            raise ValueError
    except ValueError as exc:
        raise RuntimeError("Harbor TrialResult job identity is invalid") from exc
    return True


def _terminal_atif(
    path,
    expected_operator_version=None,
    expected_codex_version=None,
    expected_agent_window=None,
    expected_agent_result=None,
):
    payload = _json_artifact(path, "Terminal-Bench ATIF", max_bytes=256 * 1024 * 1024)
    agent = payload.get("agent") if isinstance(payload, dict) else None
    try:
        session_id = str(uuid.UUID(str(payload.get("session_id"))))
    except (AttributeError, ValueError) as exc:
        raise RuntimeError("Terminal-Bench ATIF session identity is invalid") from exc
    subtrajectories = payload.get("subagent_trajectories")
    if not isinstance(subtrajectories, list) or not subtrajectories:
        raise RuntimeError("Terminal-Bench ATIF omits Operator subtrajectories")
    inner_session_ids = []
    flattened = []
    for subtrajectory in subtrajectories:
        inner_agent = (
            subtrajectory.get("agent") if isinstance(subtrajectory, dict) else None
        )
        inner_session = (
            subtrajectory.get("session_id")
            if isinstance(subtrajectory, dict)
            else None
        )
        try:
            inner_session = str(uuid.UUID(str(inner_session)))
        except ValueError as exc:
            raise RuntimeError("Terminal-Bench inner Codex session is invalid") from exc
        if (
            not isinstance(inner_agent, dict)
            or inner_agent.get("name") != "codex"
            or inner_agent.get("version") != expected_codex_version
            or inner_agent.get("model_name") != SOL_MODEL
            or not isinstance(subtrajectory.get("steps"), list)
            or not subtrajectory["steps"]
        ):
            raise RuntimeError("Terminal-Bench inner Codex trajectory identity changed")
        inner_session_ids.append(inner_session)
        for step in subtrajectory["steps"]:
            copied = dict(step)
            copied["step_id"] = len(flattened) + 1
            flattened.append(copied)
    session_hash = hashlib.sha256(
        "\n".join(inner_session_ids).encode("utf-8")
    ).hexdigest()
    expected_session = "%s-%s-%s-%s-%s" % (
        session_hash[:8],
        session_hash[8:12],
        session_hash[12:16],
        session_hash[16:20],
        session_hash[20:32],
    )
    step_timestamps = [
        _timestamp(step.get("timestamp"), "Terminal-Bench ATIF step")
        for step in payload.get("steps") or []
    ]
    metrics = payload.get("final_metrics")
    if expected_agent_result is not None:
        if not isinstance(metrics, dict) or (
            metrics.get("total_prompt_tokens")
            != expected_agent_result.get("n_input_tokens")
            or metrics.get("total_cached_tokens")
            != expected_agent_result.get("n_cache_tokens")
            or metrics.get("total_completion_tokens")
            != expected_agent_result.get("n_output_tokens")
            or metrics.get("total_cost_usd") != expected_agent_result.get("cost_usd")
        ):
            raise RuntimeError("Terminal-Bench ATIF metrics do not match AgentResult")
    if (
        payload.get("schema_version") != "ATIF-v1.7"
        or session_id != payload.get("session_id")
        or session_id != expected_session
        or not isinstance(agent, dict)
        or agent.get("name") != "black-label-operator"
        or not isinstance(agent.get("version"), str)
        or not agent.get("version")
        or (
            expected_operator_version is not None
            and agent.get("version") != expected_operator_version
        )
        or agent.get("model_name") != SOL_MODEL
        or not isinstance(payload.get("steps"), list)
        or not payload["steps"]
        or payload["steps"] != flattened
        or len(inner_session_ids) != len(set(inner_session_ids))
        or (
            expected_agent_window is not None
            and any(
                timestamp < expected_agent_window[0] - 1
                or timestamp > expected_agent_window[1] + 1
                for timestamp in step_timestamps
            )
        )
        or any(
            not isinstance(step, dict)
            or step.get("step_id") != index
            or not isinstance(step.get("timestamp"), str)
            or not isinstance(step.get("source"), str)
            or not (
                step.get("message") is not None
                or step.get("tool_calls")
                or step.get("observation")
            )
            for index, step in enumerate(payload["steps"], 1)
        )
    ):
        raise RuntimeError("Terminal-Bench ATIF is missing or invalid")
    payload["_validated_inner_session_ids"] = inner_session_ids
    return payload


def _strict_harbor_trial_documents(result_path, atif_path, lock_path, harbor_runtime):
    validation_script = r'''
import json
import sys
from pathlib import Path
from harbor.models.job.lock import TrialLock
from harbor.models.trajectories import Trajectory
from harbor.models.trial.result import TrialResult
result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
trajectory = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
lock = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
TrialResult.model_validate(result)
Trajectory.model_validate(trajectory)
TrialLock.model_validate(lock)
print(json.dumps({
    "id": str(result["id"]),
    "task_name": result["task_name"],
    "trial_name": result["trial_name"],
    "session_id": trajectory.get("session_id"),
    "lock_task_name": lock["task"]["name"],
    "lock_task_digest": lock["task"]["digest"],
}, sort_keys=True))
'''
    completed = subprocess.run(
        [
            harbor_runtime["python"],
            "-c",
            validation_script,
            str(result_path),
            str(atif_path),
            str(lock_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
    )
    try:
        validated = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor 0.22 rejected TrialResult, ATIF, or trial lock") from exc
    if completed.returncode != 0 or not isinstance(validated, dict):
        raise RuntimeError("Harbor 0.22 rejected TrialResult, ATIF, or trial lock")
    return validated


def _strict_harbor_job_lock(path, harbor_runtime):
    validation_script = r'''
import json
import sys
from pathlib import Path
from harbor.models.job.lock import JobLock
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
JobLock.model_validate(payload)
print(json.dumps({"schema_version": payload.get("schema_version"), "trials": len(payload.get("trials", []))}))
'''
    completed = subprocess.run(
        [harbor_runtime["python"], "-c", validation_script, str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
    )
    try:
        validated = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor 0.22 rejected the job lock") from exc
    if (
        completed.returncode != 0
        or validated.get("schema_version") != 3
        or validated.get("trials") != 330
    ):
        raise RuntimeError("Harbor 0.22 rejected the exact 330-trial job lock")
    return _harbor_result_json(path, label="Harbor job lock")


def _terminal_job_result(path, harbor_runtime, expected_trials=330):
    validation_script = r'''
import json
import sys
from pathlib import Path
from harbor.models.job.result import JobResult
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
validated = JobResult.model_validate(payload)
print(json.dumps({"id": str(validated.id), "n_total_trials": validated.n_total_trials}, sort_keys=True))
'''
    completed = subprocess.run(
        [harbor_runtime["python"], "-c", validation_script, str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
    )
    try:
        validated = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Harbor 0.22 rejected the job result") from exc
    payload = _harbor_result_json(path, label="Harbor job result")
    stats = payload.get("stats") if isinstance(payload, dict) else None
    required_stats = {
        "n_completed_trials",
        "n_errored_trials",
        "n_running_trials",
        "n_pending_trials",
        "n_cancelled_trials",
        "n_retries",
        "evals",
    }
    optional_stats = {"n_input_tokens", "n_cache_tokens", "n_output_tokens", "cost_usd"}
    try:
        job_id = str(uuid.UUID(str(payload.get("id"))))
        started = _timestamp(payload.get("started_at"), "Harbor job start")
        updated = _timestamp(payload.get("updated_at"), "Harbor job update")
        finished = _timestamp(payload.get("finished_at"), "Harbor job finish")
    except (AttributeError, ValueError, RuntimeError) as exc:
        raise RuntimeError("Harbor job result identity is invalid") from exc
    if (
        completed.returncode != 0
        or validated.get("id") != job_id
        or validated.get("n_total_trials") != int(expected_trials)
        or set(payload)
        != {"id", "started_at", "updated_at", "finished_at", "n_total_trials", "stats"}
        or not isinstance(stats, dict)
        or not required_stats <= set(stats) <= required_stats | optional_stats
        or payload.get("n_total_trials") != int(expected_trials)
        or stats.get("n_completed_trials") != int(expected_trials)
        or stats.get("n_errored_trials") != 0
        or stats.get("n_running_trials") != 0
        or stats.get("n_pending_trials") != 0
        or stats.get("n_cancelled_trials") != 0
        or stats.get("n_retries") != 0
        or not isinstance(stats.get("evals"), dict)
        or not stats["evals"]
        or not (started <= updated <= finished)
    ):
        raise RuntimeError("Harbor job result is not one complete clean 330-trial job")
    return payload, job_id, (started, finished)


def _validate_terminal_trial_lock_payload(payload, task, model, source):
    expected_root_keys = {
        "schema_version",
        "task",
        "install_only",
        "timeout_multiplier",
        "agent_timeout_multiplier",
        "agent_setup_timeout_multiplier",
        "environment_build_timeout_multiplier",
        "agent",
        "bridge_inputs",
        "skills",
        "environment",
        "verifier",
    }
    locked_task = payload.get("task") if isinstance(payload, dict) else None
    agent = payload.get("agent") if isinstance(payload, dict) else None
    environment = payload.get("environment") if isinstance(payload, dict) else None
    verifier = payload.get("verifier") if isinstance(payload, dict) else None
    task_path = (Path(source) / "tasks" / task["directory"]).resolve()
    expected_kwargs = {
        "reasoning_effort": "xhigh",
        "codex_version": model.get("codex_version"),
        "operator_version": model.get("operator_version"),
        "review_passes": 0,
        "benchmark_suite": "terminal-bench-current",
        "config": CODEX_BENCHMARK_CONFIG,
    }
    if (
        not isinstance(payload, dict)
        or set(payload) != expected_root_keys
        or payload.get("schema_version") != 2
        or payload.get("install_only") is not False
        or payload.get("timeout_multiplier") != 1.0
        or payload.get("agent_timeout_multiplier") != 24.0
        or payload.get("agent_setup_timeout_multiplier") != 4.0
        or payload.get("environment_build_timeout_multiplier") != 4.0
        or payload.get("bridge_inputs") != {}
        or payload.get("skills") != []
        or not isinstance(locked_task, dict)
        or set(locked_task) != {"name", "type", "digest", "source", "path"}
        or locked_task.get("name") != task["directory"]
        or locked_task.get("type") != "local"
        or locked_task.get("digest") != task["runtime_digest"]
        or locked_task.get("source") != "tasks"
        or Path(str(locked_task.get("path") or "")).resolve() != task_path
        or not isinstance(agent, dict)
        or set(agent)
        != {
            "name",
            "model_name",
            "skills",
            "resume_trajectory",
            "extra_allowed_hosts",
            "kwargs",
            "env",
            "mcp_servers",
        }
        or agent.get("name") != OPERATOR_HARBOR_AGENT
        or agent.get("model_name") != SOL_MODEL
        or agent.get("skills") != []
        or agent.get("resume_trajectory") is not False
        or agent.get("extra_allowed_hosts") != []
        or agent.get("kwargs") != expected_kwargs
        or agent.get("env")
        != {
            "CODEX_AUTH_JSON_PATH": "****",
            "OPERATOR_SUPERVISED_PROCESS_GROUP": "1",
        }
        or agent.get("mcp_servers") != []
        or not isinstance(environment, dict)
        or set(environment)
        != {
            "type",
            "force_build",
            "delete",
            "cpu_enforcement_policy",
            "memory_enforcement_policy",
            "extra_docker_compose",
            "kwargs",
            "extra_allowed_hosts",
        }
        or environment
        != {
            "type": "docker",
            "force_build": True,
            "delete": True,
            "cpu_enforcement_policy": "auto",
            "memory_enforcement_policy": "auto",
            "extra_docker_compose": [],
            "kwargs": {},
            "extra_allowed_hosts": [],
        }
        or not isinstance(verifier, dict)
        or set(verifier) != {"disable", "environment_mode"}
        or verifier.get("disable") is not False
        or verifier.get("environment_mode") not in {"shared", "separate"}
    ):
        raise RuntimeError("Harbor trial lock is not the exact replay protocol")
    return True


def _validate_terminal_job_lock_payload(payload, n_concurrent):
    expected_exceptions = [
        "AgentAuthenticationError",
        "RewardFileEmptyError",
        "RewardFileNotFoundError",
        "ApiUsageLimitError",
        "VerifierOutputParseError",
        "AgentTimeoutError",
        "AgentSafetyRefusalError",
        "ModelNotFoundError",
        "VerifierTimeoutError",
    ]
    retry = payload.get("retry") if isinstance(payload, dict) else None
    if (
        not isinstance(payload, dict)
        or set(payload)
        != {"schema_version", "created_at", "harbor", "n_concurrent_trials", "retry", "trials"}
        or payload.get("schema_version") != 3
        or not isinstance(payload.get("created_at"), str)
        or (payload.get("harbor") or {})
        != {"version": OFFICIAL_HARBOR_VERSION, "is_editable": False}
        or payload.get("n_concurrent_trials") != int(n_concurrent)
        or retry
        != {
            "max_retries": 0,
            "exclude_exceptions": expected_exceptions,
            "wait_multiplier": 1.0,
            "min_wait_sec": 1.0,
            "max_wait_sec": 60.0,
        }
        or not isinstance(payload.get("trials"), list)
        or len(payload["trials"]) != 330
    ):
        raise RuntimeError("Harbor job lock is not the exact 330-trial protocol")
    _timestamp(payload["created_at"], "Harbor job lock creation")
    return True


def _validate_terminal_record_uniqueness(records):
    fields = (
        "trial_id",
        "session_id",
        "trial_name",
        "result_sha256",
        "atif_sha256",
    )
    for field in fields:
        values = [record.get(field) for record in records]
        if any(not isinstance(value, str) or not value for value in values):
            raise RuntimeError("Terminal-Bench %s identity is missing" % field)
        if len(values) != len(set(values)):
            raise RuntimeError("Terminal-Bench %s values are not globally unique" % field)
    inner_session_ids = [
        session
        for record in records
        for session in (record.get("inner_session_ids") or [])
    ]
    if (
        any(not isinstance(value, str) or not value for value in inner_session_ids)
        or len(inner_session_ids) != len(set(inner_session_ids))
    ):
        raise RuntimeError(
            "Terminal-Bench embedded Codex session IDs are not globally unique"
        )
    by_task = {}
    owners = {}
    for record in records:
        task_id = record.get("task_id")
        operator_task_id = record.get("operator_task_id")
        if (
            not isinstance(task_id, str)
            or not task_id
            or not isinstance(operator_task_id, str)
            or not operator_task_id
        ):
            raise RuntimeError("Terminal-Bench Operator task identity is missing")
        if task_id in by_task and by_task[task_id] != operator_task_id:
            raise RuntimeError(
                "Terminal-Bench Operator task identity changed across attempts"
            )
        if operator_task_id in owners and owners[operator_task_id] != task_id:
            raise RuntimeError(
                "Terminal-Bench Operator task identity is shared across tasks"
            )
        by_task[task_id] = operator_task_id
        owners[operator_task_id] = task_id
    return True


def _terminal_verifier_artifacts(trial_dir, expected_reward):
    verifier_dir = Path(trial_dir) / "verifier"
    paths = {
        "reward": verifier_dir / "reward.txt",
        "ctrf": verifier_dir / "ctrf.json",
        "stdout": verifier_dir / "test-stdout.txt",
    }
    for label, path in paths.items():
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("Terminal-Bench verifier %s artifact is missing" % label)
    try:
        reward_text = paths["reward"].read_text(encoding="utf-8").strip()
        reward_value = float(reward_text)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise RuntimeError("Terminal-Bench verifier reward is invalid") from exc
    ctrf = _json_artifact(
        paths["ctrf"], "Terminal-Bench CTRF", max_bytes=64 * 1024 * 1024
    )
    results = ctrf.get("results") if isinstance(ctrf, dict) else None
    tests = results.get("tests") if isinstance(results, dict) else None
    summary = results.get("summary") if isinstance(results, dict) else None
    tool = results.get("tool") if isinstance(results, dict) else None
    stdout = paths["stdout"].read_text(encoding="utf-8", errors="replace")
    statuses = ("passed", "failed", "skipped", "pending", "other")
    status_counts = Counter(
        item.get("status") for item in tests if isinstance(item, dict)
    ) if isinstance(tests, list) else Counter()
    test_names = [
        item.get("name") for item in tests if isinstance(item, dict)
    ] if isinstance(tests, list) else []
    timing_values = []
    if isinstance(tests, list):
        for item in tests:
            if not isinstance(item, dict):
                continue
            for key in ("duration", "start", "stop"):
                value = item.get(key)
                if value is not None:
                    timing_values.append(value)
    if (
        isinstance(reward_value, bool)
        or reward_value not in (0.0, 1.0)
        or int(reward_value) != int(expected_reward)
        or not isinstance(ctrf, dict)
        or set(ctrf) != {"results"}
        or not isinstance(results, dict)
        or set(results) != {"tool", "summary", "tests"}
        or not isinstance(tests, list)
        or not tests
        or len(test_names) != len(tests)
        or any(not isinstance(name, str) or not name for name in test_names)
        or len(test_names) != len(set(test_names))
        or any(
            not isinstance(item, dict)
            or item.get("status") not in statuses
            for item in tests
        )
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in timing_values
        )
        or any(
            item.get("duration") is not None and float(item["duration"]) < 0
            for item in tests
        )
        or any(
            item.get("start") is not None
            and item.get("stop") is not None
            and float(item["stop"]) < float(item["start"])
            for item in tests
        )
        or not isinstance(summary, dict)
        or set(summary)
        != {"tests", "passed", "failed", "skipped", "pending", "other", "start", "stop"}
        or any(
            isinstance(summary.get(key), bool)
            or not isinstance(summary.get(key), int)
            or summary.get(key) < 0
            for key in ("tests", "passed", "failed", "skipped", "pending", "other")
        )
        or summary.get("tests") != len(tests)
        or any(summary.get(status) != status_counts[status] for status in statuses)
        or sum(summary.get(status) for status in statuses) != len(tests)
        or any(
            isinstance(summary.get(key), bool)
            or not isinstance(summary.get(key), (int, float))
            or not math.isfinite(float(summary.get(key)))
            for key in ("start", "stop")
        )
        or float(summary.get("stop")) < float(summary.get("start"))
        or not isinstance(tool, dict)
        or set(tool) != {"name", "version"}
        or any(not isinstance(tool.get(key), str) or not tool.get(key) for key in tool)
        or (
            int(expected_reward) == 1
            and (
                status_counts["passed"] != len(tests)
                or any(status_counts[status] for status in statuses[1:])
            )
        )
        or (
            int(expected_reward) == 0
            and status_counts["passed"] == len(tests)
        )
        or any(marker in stdout for marker in VERIFIER_INFRASTRUCTURE_MARKERS)
    ):
        raise RuntimeError("Terminal-Bench verifier artifacts are not clean and binary")
    return paths


def terminal_bench_4_current(args, settings, execute=False):
    lane = "terminal-bench-4-current"
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    if args.terminal_revision != OFFICIAL_TERMINAL_BENCH_REVISION:
        raise RuntimeError("Terminal-Bench 4 revision does not match the contract")
    source = Path(args.terminal_source).expanduser().resolve()
    source_before = official_git_identity(
        source, OFFICIAL_TERMINAL_BENCH_REVISION, OFFICIAL_TERMINAL_BENCH_REPOSITORY
    )
    harbor_runtime = _harbor_runtime_identity(
        getattr(args, "harbor_executable", None)
    )
    tasks = _terminal_tasks(source, harbor_runtime=harbor_runtime)
    canonical_task_names = [item["name"] for item in tasks]
    if not str(args.codex_version or "").strip():
        raise RuntimeError("an exact Codex CLI version is required")
    if int(args.n_concurrent) < 1:
        raise RuntimeError("Terminal-Bench concurrency must be positive")
    frozen = Path(campaign["operator_source_path"]).resolve()
    frozen_version = _frozen_operator_version(campaign)
    if frozen_version != __version__:
        raise RuntimeError(
            "comparable adapter and frozen Operator versions do not match"
        )
    run_id = _run_id(args.run_id, "Terminal-Bench")
    lane_dir = Path(campaign_dir) / "external-evidence" / lane
    artifact_root = lane_dir / "artifacts" / run_id
    jobs_dir = artifact_root / "harbor-jobs"
    frozen_source_path = artifact_root / "terminal-bench-source"
    command = harbor_command(
        "terminal-bench-current",
        jobs_dir,
        n_tasks=66,
        include_tasks=[],
        codex_version=args.codex_version,
        n_concurrent=args.n_concurrent,
        max_retries=0,
        review_passes=0,
        reasoning_effort="xhigh",
        n_attempts=5,
        dataset_path=frozen_source_path / "tasks",
    )
    command[0] = harbor_runtime["executable"]
    environment = {
        "PYTHONPATH": str(frozen),
        "OPERATOR_HOME": str(artifact_root / "operator-home"),
    }
    plan = {
        "lane": lane,
        "protocol": contract["protocol"],
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": "official-harbor",
        "eligible": harbor_runtime["stock_eligible"],
        "certification_blockers": (
            []
            if harbor_runtime["stock_eligible"]
            else [harbor_runtime["certification_blocker"]]
        ),
        "harbor_runtime": harbor_runtime,
        "harbor_source": source_before,
        "frozen_harbor_source_path": str(frozen_source_path.resolve()),
        "dataset": {
            "name": "terminal-bench@4.0",
            "tasks": 66,
            "attempts": 5,
            "trials": 330,
            "dataset_file_sha256": OFFICIAL_TERMINAL_DATASET_FILE_SHA256,
            "task_manifest_sha256": _canonical_sha256(canonical_task_names),
            "directory_name_manifest_sha256": _canonical_sha256(
                [
                    {"directory": item["directory"], "name": item["name"]}
                    for item in tasks
                ]
            ),
            "dataset_entries_sha256": _canonical_sha256(
                [
                    {"name": item["name"], "digest": item["declared_digest"]}
                    for item in tasks
                ]
            ),
            "runtime_manifest_sha256": _canonical_sha256(tasks),
            "task_manifest": tasks,
        },
        "model": {
            "provider": "codex",
            "profile": "sol-benchmark",
            "requested": SOL_MODEL,
            "expected_resolved": SOL_MODEL,
            "codex_version": args.codex_version,
            "operator_version": frozen_version,
            "reasoning_effort": "xhigh",
            "review_passes": 0,
        },
        "command": command,
        "environment": environment,
        "execute": bool(execute),
    }
    if not execute:
        return plan
    if not harbor_runtime["stock_eligible"]:
        raise RuntimeError(
            "Terminal-Bench 4 comparable run is ineligible: selected Harbor "
            "0.22 runtime is not an attested isolated official runtime"
        )
    if not Path(harbor_runtime["executable"]).is_file() or not shutil.which("docker"):
        raise RuntimeError("Terminal-Bench 4 requires Harbor and Docker")
    if not (Path.home() / ".codex" / "auth.json").is_file():
        raise RuntimeError("Codex subscription auth is not available")
    if artifact_root.exists() or artifact_root.is_symlink():
        raise RuntimeError("Terminal-Bench run artifacts already exist: %s" % artifact_root)
    artifact_root.mkdir(parents=True, mode=0o700)
    frozen_source = _export_verified_git_tree(
        source, source_before, frozen_source_path
    )
    frozen_source["artifact_path"] = _relative_to_lane(
        frozen_source_path, lane_dir, "frozen Terminal-Bench source"
    )
    if _terminal_tasks(
        frozen_source_path, harbor_runtime=harbor_runtime
    ) != tasks:
        raise RuntimeError("frozen Terminal-Bench task content changed during export")
    started = time.time()
    process_environment = os.environ.copy()
    process_environment.update(environment)
    process = _process(
        command,
        frozen,
        process_environment,
        artifact_root / "harbor.stdout.log",
        artifact_root / "harbor.stderr.log",
        args.timeout,
    )
    source_after = official_git_identity(
        source, OFFICIAL_TERMINAL_BENCH_REVISION, OFFICIAL_TERMINAL_BENCH_REPOSITORY
    )
    runtime_after = _harbor_runtime_identity(harbor_runtime["executable"])
    frozen_source_after = {
        "path": frozen_source["path"],
        "revision": frozen_source["revision"],
        **_filesystem_export_identity(frozen_source_path),
        "read_only": True,
        "artifact_path": frozen_source["artifact_path"],
    }
    identity_stable = bool(
        source_before == source_after
        and harbor_runtime == runtime_after
        and frozen_source == frozen_source_after
    )
    job_lock_paths = []
    for candidate in sorted(jobs_dir.rglob("lock.json")):
        try:
            lock_candidate = _json_artifact(
                candidate, "Harbor lock", max_bytes=256 * 1024 * 1024
            )
        except RuntimeError:
            continue
        if isinstance(lock_candidate, dict) and lock_candidate.get("schema_version") == 3:
            job_lock_paths.append(candidate)
    job_lock_path = job_lock_paths[0] if len(job_lock_paths) == 1 else None
    job_lock = None
    job_root = None
    job_result_path = None
    job_id = None
    job_window = None
    job_trial_lock_hashes = Counter()
    by_task = {item["name"]: [] for item in tasks}
    errors = []
    if job_lock_path is None:
        errors.append("Harbor run must contain exactly one schema-3 job lock")
    else:
        try:
            job_root = job_lock_path.parent.resolve()
            job_lock = _strict_harbor_job_lock(job_lock_path, harbor_runtime)
            _validate_terminal_job_lock_payload(job_lock, args.n_concurrent)
            job_result_path = job_root / "result.json"
            _job_result, job_id, job_window = _terminal_job_result(
                job_result_path, harbor_runtime
            )
            if (
                (job_lock.get("harbor") or {}).get("version") != OFFICIAL_HARBOR_VERSION
                or (job_lock.get("harbor") or {}).get("is_editable") is not False
                or job_lock.get("n_concurrent_trials") != int(args.n_concurrent)
                or (job_lock.get("retry") or {}).get("max_retries") != 0
            ):
                raise RuntimeError("Harbor job lock does not match the exact run protocol")
            for locked_trial in job_lock.get("trials") or []:
                job_trial_lock_hashes[_canonical_sha256(locked_trial)] += 1
        except (OSError, RuntimeError) as exc:
            errors.append(str(exc))
    trial_result_paths = sorted(job_root.glob("*/result.json")) if job_root else []
    if len(trial_result_paths) != 330:
        errors.append(
            "Harbor job contains %d direct trial results, expected 330"
            % len(trial_result_paths)
        )
    for result_path in trial_result_paths:
        try:
            payload = _harbor_result_json(result_path)
        except RuntimeError as exc:
            errors.append(str(exc))
            continue
        if not isinstance(payload, dict) or not payload.get("task_name"):
            errors.append("Harbor job contains a non-trial direct result")
            continue
        task_id = payload.get("task_name")
        if task_id not in by_task:
            errors.append("unexpected Terminal-Bench task: %s" % task_id)
            continue
        by_task[task_id].append(result_path)
    records = []
    for task in tasks:
        task_id = task["name"]
        ordered = sorted(
            by_task[task_id],
            key=lambda path: (
                str((_harbor_result_json(path).get("started_at") or "")),
                str((_harbor_result_json(path).get("trial_name") or "")),
            ),
        )
        if len(ordered) != 5:
            errors.append("%s has %d Harbor trials, expected 5" % (task_id, len(ordered)))
        for attempt, result_path in enumerate(ordered, 1):
            try:
                _payload, actual_task, trial_name, reward = _terminal_trial_payload(
                    result_path, expected_task=task_id, expected_model=plan["model"]
                )
                atif_path = result_path.parent / "agent" / "trajectory.json"
                atif = _terminal_atif(
                    atif_path,
                    expected_operator_version=frozen_version,
                    expected_codex_version=args.codex_version,
                    expected_agent_window=(
                        _timestamp(
                            _payload["agent_execution"]["started_at"],
                            "Harbor agent execution start",
                        ),
                        _timestamp(
                            _payload["agent_execution"]["finished_at"],
                            "Harbor agent execution finish",
                        ),
                    ),
                    expected_agent_result=_payload.get("agent_result"),
                )
                lock_path = result_path.parent / "lock.json"
                if lock_path.is_symlink() or not lock_path.is_file():
                    raise RuntimeError("Harbor trial lock is missing")
                validated = _strict_harbor_trial_documents(
                    result_path, atif_path, lock_path, harbor_runtime
                )
                trial_lock = _json_artifact(
                    lock_path, "Harbor trial lock", max_bytes=16 * 1024 * 1024
                )
                _validate_terminal_trial_lock_payload(
                    trial_lock, task, plan["model"], frozen_source_path
                )
                _validate_terminal_result_config(
                    _payload,
                    trial_lock,
                    task,
                    plan["model"],
                    frozen_source_path,
                    job_id,
                    job_root,
                )
                locked_task = trial_lock.get("task") or {}
                locked_agent = trial_lock.get("agent") or {}
                locked_kwargs = locked_agent.get("kwargs") or {}
                task_path = (
                    frozen_source_path / "tasks" / task["directory"]
                ).resolve()
                result_task = _payload.get("task_id") or {}
                result_config_task = ((_payload.get("config") or {}).get("task") or {})
                if (
                    trial_lock.get("schema_version") != 2
                    or locked_task.get("name") != task["directory"]
                    or locked_task.get("type") != "local"
                    or locked_task.get("digest") != task["runtime_digest"]
                    or Path(str(locked_task.get("path") or "")).resolve() != task_path
                    or locked_agent.get("name") != OPERATOR_HARBOR_AGENT
                    or locked_agent.get("model_name") != SOL_MODEL
                    or locked_kwargs
                    != {
                        "reasoning_effort": "xhigh",
                        "codex_version": args.codex_version,
                        "operator_version": frozen_version,
                        "review_passes": 0,
                        "benchmark_suite": "terminal-bench-current",
                        "config": CODEX_BENCHMARK_CONFIG,
                    }
                    or trial_lock.get("agent_timeout_multiplier") != 24.0
                    or trial_lock.get("agent_setup_timeout_multiplier") != 4.0
                    or trial_lock.get("environment_build_timeout_multiplier") != 4.0
                    or (trial_lock.get("environment") or {}).get("force_build") is not True
                    or (trial_lock.get("verifier") or {}).get("disable") is not False
                    or _payload.get("task_checksum") != task["runtime_dirhash"]
                    or Path(str(result_task.get("path") or "")).resolve() != task_path
                    or Path(str(result_config_task.get("path") or "")).resolve()
                    != task_path
                    or validated.get("id") != str(_payload.get("id"))
                    or validated.get("session_id") != atif.get("session_id")
                    or validated.get("lock_task_digest") != task["runtime_digest"]
                    or result_path.parent.parent.resolve() != job_root
                    or not (
                        job_window[0]
                        <= _timestamp(_payload.get("started_at"), "Harbor trial start")
                        <= _timestamp(_payload.get("finished_at"), "Harbor trial finish")
                        <= job_window[1]
                    )
                ):
                    raise RuntimeError(
                        "Harbor TrialResult, lock, and pinned task do not cross-bind"
                    )
                lock_payload_hash = _canonical_sha256(trial_lock)
                if job_trial_lock_hashes[lock_payload_hash] < 1:
                    raise RuntimeError("Harbor trial lock is absent from its job lock")
                job_trial_lock_hashes[lock_payload_hash] -= 1
                verifier_paths = _terminal_verifier_artifacts(
                    result_path.parent, reward
                )
                records.append(
                    {
                        "task_id": task["name"],
                        "harbor_task_name": actual_task,
                        "canonical_task_name": task["name"],
                        "attempt": attempt,
                        "trial_id": validated["id"],
                        "session_id": validated["session_id"],
                        "inner_session_ids": atif[
                            "_validated_inner_session_ids"
                        ],
                        "operator_task_id": (_payload.get("agent_result") or {})
                        .get("metadata", {})
                        .get("operator_task_id"),
                        "job_id": job_id,
                        "trial_name": trial_name,
                        "reward": reward,
                        "error": None,
                        "result_path": _relative_to_lane(
                            result_path, lane_dir, "Terminal-Bench result"
                        ),
                        "result_sha256": _sha256_file(result_path),
                        "atif_path": _relative_to_lane(
                            atif_path, lane_dir, "Terminal-Bench ATIF"
                        ),
                        "atif_sha256": _sha256_file(atif_path),
                        "lock_path": _relative_to_lane(
                            lock_path, lane_dir, "Terminal-Bench trial lock"
                        ),
                        "lock_sha256": _sha256_file(lock_path),
                        "reward_path": _relative_to_lane(
                            verifier_paths["reward"],
                            lane_dir,
                            "Terminal-Bench verifier reward",
                        ),
                        "reward_sha256": _sha256_file(verifier_paths["reward"]),
                        "ctrf_path": _relative_to_lane(
                            verifier_paths["ctrf"],
                            lane_dir,
                            "Terminal-Bench CTRF",
                        ),
                        "ctrf_sha256": _sha256_file(verifier_paths["ctrf"]),
                        "verifier_stdout_path": _relative_to_lane(
                            verifier_paths["stdout"],
                            lane_dir,
                            "Terminal-Bench verifier stdout",
                        ),
                        "verifier_stdout_sha256": _sha256_file(
                            verifier_paths["stdout"]
                        ),
                    }
                )
            except (OSError, RuntimeError) as exc:
                errors.append("%s attempt %d: %s" % (task_id, attempt, exc))
    try:
        _validate_terminal_record_uniqueness(records)
    except RuntimeError as exc:
        errors.append(str(exc))
    if any(job_trial_lock_hashes.values()):
        errors.append("Harbor job lock contains unmatched or duplicated trials")
    clean = bool(
        not process["timed_out"]
        and process["termination_confirmed"]
        and process["exit_code"] in (0, 1)
        and identity_stable
        and len(records) == 330
        and not errors
    )
    trial_summary = {
        "schema": "black-label-operator/terminal-bench-4-trial-results-v1",
        "trials": records,
    }
    summary_path = artifact_root / "terminal-bench-4-trials.json"
    _write_json_exclusive(summary_path, trial_summary)
    score = (
        {"passed": sum(record["reward"] for record in records), "total": 330}
        if clean
        else None
    )
    artifacts = _artifact_manifest(lane_dir, artifact_root)
    payload = {
        "schema": COMPARABLE_RUN_SCHEMA,
        "lane": lane,
        "protocol": contract["protocol"],
        "status": "completed" if clean else "blocked",
        "scope": "full" if clean else "incomplete",
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": {
            "kind": "official-harbor",
            "dataset": "terminal-bench@4.0",
            "tasks": 66,
            "attempts": 5,
            "trials": 330,
            "source_content_sha256": source_before["tracked_content_sha256"],
            "dataset_file_sha256": OFFICIAL_TERMINAL_DATASET_FILE_SHA256,
            "task_manifest_sha256": _canonical_sha256(canonical_task_names),
            "directory_name_manifest_sha256": plan["dataset"][
                "directory_name_manifest_sha256"
            ],
            "dataset_entries_sha256": plan["dataset"][
                "dataset_entries_sha256"
            ],
            "runtime_manifest_sha256": plan["dataset"][
                "runtime_manifest_sha256"
            ],
            "task_manifest": tasks,
            "harbor_runtime": harbor_runtime,
            "frozen_harbor_source": frozen_source,
            "job_lock_path": (
                _relative_to_lane(job_lock_path, lane_dir, "Terminal-Bench job lock")
                if job_lock_path is not None
                else None
            ),
            "job_lock_sha256": (
                _sha256_file(job_lock_path) if job_lock_path is not None else None
            ),
            "job_result_path": (
                _relative_to_lane(
                    job_result_path, lane_dir, "Terminal-Bench job result"
                )
                if job_result_path is not None
                else None
            ),
            "job_result_sha256": (
                _sha256_file(job_result_path)
                if job_result_path is not None and job_result_path.is_file()
                else None
            ),
            "job_id": job_id,
            "trial_results_path": _relative_to_lane(
                summary_path, lane_dir, "Terminal-Bench summary"
            ),
            "harbor_source": source_before,
        },
        "dataset": plan["dataset"],
        "model": plan["model"],
        "command": command,
        "environment": environment,
        "process": process,
        "identity_stable": identity_stable,
        "score": score,
        "diagnostics": {"completed": len(records), "errors": errors},
        "started_at": started,
        "finished_at": time.time(),
        "artifacts": artifacts,
    }
    receipt = lane_dir / (run_id + "-run-receipt.json")
    _finalize_receipt(receipt, payload)
    _seal_tree(artifact_root)
    return {"receipt": str(receipt), "status": payload["status"], "score": score}


def _swe_pro_rows(source, dataset_source):
    source = Path(source)
    dataset_source = Path(dataset_source)
    evaluator = source / "swe_bench_pro_eval.py"
    raw = source / "helper_code" / "sweap_eval_full_v2.jsonl"
    parquet = dataset_source / "data" / "test-00000-of-00001.parquet"
    required = (
        (evaluator, OFFICIAL_SWE_PRO_EVALUATOR_SHA256, "evaluator"),
        (raw, OFFICIAL_SWE_PRO_RAW_DATA_SHA256, "official evaluation dataset"),
        (parquet, OFFICIAL_SWE_PRO_PARQUET_SHA256, "pinned public parquet"),
    )
    for path, expected, label in required:
        if path.is_symlink() or not path.is_file() or _sha256_file(path) != expected:
            raise RuntimeError("SWE-bench Pro %s hash changed" % label)
    rows = []
    try:
        with raw.open("r", encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        raise RuntimeError(
                            "SWE-bench Pro official dataset row is not an object"
                        )
                    normalized = dict(item)
                    normalized["fail_to_pass"] = normalized.pop("FAIL_TO_PASS")
                    normalized["pass_to_pass"] = normalized.pop("PASS_TO_PASS")
                    # Gold patches are not part of the evaluator input given to the
                    # candidate agent and do not belong in comparable evidence.
                    normalized.pop("patch", None)
                    normalized.pop("test_patch", None)
                    rows.append(normalized)
    except (KeyError, OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("SWE-bench Pro official dataset export is invalid") from exc
    rows.sort(key=lambda item: str(item.get("instance_id") or ""))
    instance_ids = [item.get("instance_id") for item in rows]
    if (
        len(instance_ids) != 731
        or any(not isinstance(item, str) or not item for item in instance_ids)
        or len(set(instance_ids)) != 731
        or _canonical_sha256(instance_ids) != OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256
    ):
        raise RuntimeError("SWE-bench Pro requires the exact 731-instance public set")
    scripts = source / "run_scripts"
    for instance_id in instance_ids:
        directory = scripts / instance_id
        for name in ("run_script.sh", "parser.py"):
            path = directory / name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError(
                    "SWE-bench Pro scripts do not cover %s" % instance_id
                )
    return rows


def _validate_swe_generation_receipt(
    receipt_path,
    patches_path,
    campaign,
    requested_model,
    resolved_model,
    instance_ids,
):
    raise RuntimeError(
        "SWE-bench Pro generation evidence is ineligible: %s"
        % "; ".join(SWE_PRO_CERTIFICATION_BLOCKERS)
    )
    receipt_path = Path(receipt_path).expanduser().resolve()
    patches_path = Path(patches_path).expanduser().resolve()
    if (
        receipt_path.is_symlink()
        or not receipt_path.is_file()
        or patches_path.is_symlink()
        or not patches_path.is_file()
    ):
        raise RuntimeError("SWE-bench Pro generation evidence is missing or symbolic")
    receipt = _json_artifact(
        receipt_path, "SWE-bench Pro generation receipt", max_bytes=16 * 1024 * 1024
    )
    if not isinstance(receipt, dict):
        raise RuntimeError("SWE-bench Pro generation receipt is not an object")
    body = dict(receipt)
    payload_hash = body.pop("payload_sha256", None)
    generation_config = receipt.get("generation_config") if isinstance(receipt, dict) else None
    generation_config_sha256 = receipt.get("generation_config_sha256") if isinstance(receipt, dict) else None
    model = receipt.get("model") if isinstance(receipt, dict) else None
    dataset = receipt.get("dataset") if isinstance(receipt, dict) else None
    if (
        receipt.get("schema") != SWE_PRO_GENERATION_RECEIPT_SCHEMA
        or payload_hash != _canonical_sha256(body)
        or (receipt.get("operator_source") or {}).get("tree_sha256")
        != (campaign.get("operator_source") or {}).get("tree_sha256")
        or not isinstance(generation_config, dict)
        or generation_config.get("agent") != "black-label-operator"
        or generation_config.get("attempts") != 1
        or generation_config.get("dataset_split") != "public"
        or not FULL_SHA256.fullmatch(str(generation_config_sha256 or ""))
        or generation_config_sha256 != _canonical_sha256(generation_config)
        or not isinstance(model, dict)
        or model.get("requested") != requested_model
        or model.get("resolved") != resolved_model
        or not requested_model
        or not resolved_model
        or not isinstance(dataset, dict)
        or _normalize_remote(dataset.get("repository"))
        != _normalize_remote(OFFICIAL_SWE_PRO_DATASET_REPOSITORY)
        or dataset.get("revision") != OFFICIAL_SWE_PRO_DATASET_REVISION
        or dataset.get("split") != "public"
        or dataset.get("instances") != 731
        or dataset.get("manifest_sha256")
        != OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256
        or receipt.get("patches_sha256") != _sha256_file(patches_path)
    ):
        raise RuntimeError("SWE-bench Pro generation receipt is not source-bound")
    patches = _json_artifact(
        patches_path, "SWE-bench Pro generated patches", max_bytes=256 * 1024 * 1024
    )
    if not isinstance(patches, list) or len(patches) != 731:
        raise RuntimeError("SWE-bench Pro requires exactly 731 generated patches")
    patch_ids = []
    for item in patches:
        if not isinstance(item, dict):
            raise RuntimeError("SWE-bench Pro generated patch metadata is malformed")
        instance_id = item.get("instance_id")
        patch_value = item.get("patch", item.get("model_patch"))
        if (
            not isinstance(instance_id, str)
            or not isinstance(patch_value, str)
            or item.get("model") != resolved_model
            or item.get("generation_config_sha256")
            != generation_config_sha256
        ):
            raise RuntimeError("SWE-bench Pro generated patch metadata is malformed")
        patch_ids.append(instance_id)
    if len(set(patch_ids)) != 731 or set(patch_ids) != set(instance_ids):
        raise RuntimeError("SWE-bench Pro generated patches do not cover the public set")
    return receipt, patches


def _swe_evaluator_patches(generated, prefix):
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]{1,100}", prefix):
        raise RuntimeError("SWE-bench Pro patch prefix is unsafe")
    return [
        {
            "instance_id": item["instance_id"],
            "patch": item.get("patch", item.get("model_patch")),
            "prefix": prefix,
        }
        for item in sorted(generated, key=lambda item: item["instance_id"])
    ]


def _swe_eval_command(
    docker,
    image,
    container,
    socket_path,
    source,
    dataset_source,
    artifact_root,
    workers,
):
    return [
        docker,
        "run",
        "--rm",
        "--name",
        container,
        "--platform",
        "linux/amd64",
        "--volume",
        "%s:/var/run/docker.sock" % socket_path,
        "--volume",
        "%s:%s:ro" % (source, source),
        "--volume",
        "%s:%s:ro" % (dataset_source, dataset_source),
        "--volume",
        "%s:%s:rw" % (artifact_root, artifact_root),
        "--workdir",
        str(source),
        image,
        "python",
        str(source / "swe_bench_pro_eval.py"),
        "--raw_sample_path",
        str(artifact_root / "public-eval-input.jsonl"),
        "--patch_path",
        str(artifact_root / "patches.json"),
        "--output_dir",
        str(artifact_root / "evaluation"),
        "--scripts_dir",
        str(source / "run_scripts"),
        "--num_workers",
        str(workers),
        "--dockerhub_username",
        "jefzda",
        "--use_local_docker",
        "--docker_platform",
        "linux/amd64",
        "--block_network",
    ]


def _literal_test_names(value, label):
    if isinstance(value, list):
        items = value
    elif isinstance(value, str):
        try:
            items = ast.literal_eval(value)
        except (SyntaxError, ValueError) as exc:
            raise RuntimeError("%s is not a literal test-name list" % label) from exc
    else:
        raise RuntimeError("%s is not a test-name list" % label)
    if not isinstance(items, list) or any(not isinstance(item, str) for item in items):
        raise RuntimeError("%s is not a string test-name list" % label)
    return set(items)


def _swe_output_passed(output, row):
    tests = output.get("tests") if isinstance(output, dict) else None
    if not isinstance(tests, list):
        raise RuntimeError("SWE-bench Pro per-instance output has no tests")
    passed = set()
    for item in tests:
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("name"), str)
            or not isinstance(item.get("status"), str)
        ):
            raise RuntimeError("SWE-bench Pro per-instance test output is malformed")
        if item["status"] == "PASSED":
            passed.add(item["name"])
    required = _literal_test_names(row.get("fail_to_pass"), "FAIL_TO_PASS")
    required.update(_literal_test_names(row.get("pass_to_pass"), "PASS_TO_PASS"))
    return required <= passed


def swe_bench_pro(args, settings, execute=False):
    lane = "swe-bench-pro-public"
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    if args.swe_pro_revision != OFFICIAL_SWE_PRO_REVISION:
        raise RuntimeError("SWE-bench Pro evaluator revision does not match the contract")
    if args.dataset_revision != OFFICIAL_SWE_PRO_DATASET_REVISION:
        raise RuntimeError("SWE-bench Pro dataset revision does not match the contract")
    blocked_plan = {
        "lane": lane,
        "protocol": contract["protocol"],
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": "official-swe-bench-pro",
        "eligible": False,
        "certification_blockers": list(SWE_PRO_CERTIFICATION_BLOCKERS),
        "execute": bool(execute),
        "statement": (
            "No comparable SWE-bench Pro run can start until the organizer "
            "publishes immutable evaluator and per-task image identities and "
            "Operator generation has independent per-instance attestation."
        ),
    }
    if not execute:
        return blocked_plan
    raise RuntimeError(
        "SWE-bench Pro comparable run is ineligible: %s"
        % "; ".join(SWE_PRO_CERTIFICATION_BLOCKERS)
    )
    source = Path(args.swe_pro_source).expanduser().resolve()
    dataset_source = Path(args.dataset_source).expanduser().resolve()
    source_before = official_git_identity(
        source, OFFICIAL_SWE_PRO_REVISION, OFFICIAL_SWE_PRO_REPOSITORY
    )
    dataset_before = official_git_identity(
        dataset_source,
        OFFICIAL_SWE_PRO_DATASET_REVISION,
        OFFICIAL_SWE_PRO_DATASET_REPOSITORY,
    )
    rows = _swe_pro_rows(source, dataset_source)
    instance_ids = [item["instance_id"] for item in rows]
    input_lines = b"".join(
        (
            json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        for row in rows
    )
    if hashlib.sha256(input_lines).hexdigest() != OFFICIAL_SWE_PRO_NORMALIZED_INPUT_SHA256:
        raise RuntimeError("SWE-bench Pro normalized evaluator input changed")
    generation_receipt, generated = _validate_swe_generation_receipt(
        args.generation_receipt,
        args.patches,
        campaign,
        args.model,
        args.expected_resolved_model,
        instance_ids,
    )
    if not IMMUTABLE_CONTAINER_IMAGE.fullmatch(str(args.evaluator_image or "")):
        raise RuntimeError("SWE-bench Pro evaluator image must use an immutable digest")
    if int(args.workers) < 1:
        raise RuntimeError("SWE-bench Pro evaluator workers must be positive")
    docker = shutil.which("docker")
    if not docker:
        raise RuntimeError("Docker is required for SWE-bench Pro")
    socket_path = Path(args.docker_socket).expanduser().resolve()
    try:
        socket_valid = socket_path.exists() and socket_path.stat().st_mode
    except OSError:
        socket_valid = False
    if not socket_valid or not socket_path.is_socket():
        raise RuntimeError("SWE-bench Pro requires an explicit live Docker socket")
    run_id = _run_id(args.run_id, "SWE-bench Pro")
    lane_dir = Path(campaign_dir) / "external-evidence" / lane
    artifact_root = lane_dir / "artifacts" / run_id
    container = "black-label-swe-pro-" + run_id.lower()
    command = _swe_eval_command(
        docker,
        args.evaluator_image,
        container,
        socket_path,
        source,
        dataset_source,
        artifact_root,
        args.workers,
    )
    plan = {
        "lane": lane,
        "protocol": contract["protocol"],
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": "official-swe-bench-pro",
        "harness_source": source_before,
        "dataset_source": dataset_before,
        "dataset": {
            "name": "ScaleAI/SWE-bench_Pro:public",
            "instances": 731,
            "manifest_sha256": _canonical_sha256(instance_ids),
            "parquet_sha256": OFFICIAL_SWE_PRO_PARQUET_SHA256,
            "official_raw_sha256": OFFICIAL_SWE_PRO_RAW_DATA_SHA256,
            "normalized_input_sha256": OFFICIAL_SWE_PRO_NORMALIZED_INPUT_SHA256,
        },
        "model": {
            "requested": args.model,
            "expected_resolved": args.expected_resolved_model,
            "generation_config_sha256": generation_receipt[
                "generation_config_sha256"
            ],
            "generation_receipt_sha256": _sha256_file(args.generation_receipt),
            "generated_patches_sha256": _sha256_file(args.patches),
        },
        "evaluator": {
            "source_sha256": OFFICIAL_SWE_PRO_EVALUATOR_SHA256,
            "container_image": args.evaluator_image,
            "platform": "linux/amd64",
            "network_blocked_in_task_containers": True,
            "workers": int(args.workers),
        },
        "command": command,
        "execute": bool(execute),
    }
    if not execute:
        return plan
    if artifact_root.exists() or artifact_root.is_symlink():
        raise RuntimeError("SWE-bench Pro run artifacts already exist: %s" % artifact_root)
    artifact_root.mkdir(parents=True, mode=0o700)
    generation_copy = _copy_exclusive(
        args.generation_receipt, artifact_root / "generation-receipt.json"
    )
    generated_copy = _copy_exclusive(
        args.patches, artifact_root / "generated-patches.json"
    )
    evaluator_patches = _swe_evaluator_patches(generated, run_id)
    evaluator_patches_path = _write_json_exclusive(
        artifact_root / "patches.json", evaluator_patches
    )
    manifest_path = _write_json_exclusive(
        artifact_root / "instance-manifest.json", instance_ids
    )
    input_path = _write_bytes_exclusive(
        artifact_root / "public-eval-input.jsonl", input_lines
    )
    started = time.time()
    process = _process(
        command,
        source,
        os.environ.copy(),
        artifact_root / "swe-pro.stdout.log",
        artifact_root / "swe-pro.stderr.log",
        args.timeout,
    )
    if process["timed_out"]:
        subprocess.run(
            [docker, "rm", "--force", container],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
    source_after = official_git_identity(
        source, OFFICIAL_SWE_PRO_REVISION, OFFICIAL_SWE_PRO_REPOSITORY
    )
    dataset_after = official_git_identity(
        dataset_source,
        OFFICIAL_SWE_PRO_DATASET_REVISION,
        OFFICIAL_SWE_PRO_DATASET_REPOSITORY,
    )
    identity_stable = source_before == source_after and dataset_before == dataset_after
    results_path = artifact_root / "evaluation" / "eval_results.json"
    errors = []
    results = {}
    if results_path.is_file() and not results_path.is_symlink():
        try:
            official_results = _json_artifact(
                results_path,
                "SWE-bench Pro evaluation results",
                max_bytes=32 * 1024 * 1024,
            )
        except RuntimeError as exc:
            official_results = None
            errors.append(str(exc))
    else:
        official_results = None
        errors.append("official SWE-bench Pro evaluation results are missing")
    row_by_id = {row["instance_id"]: row for row in rows}
    output_paths = {}
    for instance_id in instance_ids:
        output_path = (
            artifact_root / "evaluation" / instance_id / (run_id + "_output.json")
        )
        if output_path.is_symlink() or not output_path.is_file():
            errors.append("missing SWE-bench Pro output for %s" % instance_id)
            continue
        try:
            output = _json_artifact(
                output_path,
                "SWE-bench Pro per-instance output",
                max_bytes=16 * 1024 * 1024,
            )
            results[instance_id] = _swe_output_passed(
                output, row_by_id[instance_id]
            )
            output_paths[instance_id] = _relative_to_lane(
                output_path, lane_dir, "SWE-bench Pro output"
            )
        except RuntimeError as exc:
            errors.append("%s: %s" % (instance_id, exc))
    if (
        not isinstance(official_results, dict)
        or set(official_results) != set(instance_ids)
        or any(not isinstance(value, bool) for value in official_results.values())
        or official_results != results
    ):
        errors.append("official SWE-bench Pro aggregate does not match per-instance outputs")
    clean = bool(
        process["exit_code"] == 0
        and not process["timed_out"]
        and process["termination_confirmed"]
        and identity_stable
        and len(results) == 731
        and not errors
    )
    score = (
        {"passed": sum(results.values()), "total": 731} if clean else None
    )
    artifacts = _artifact_manifest(lane_dir, artifact_root)
    payload = {
        "schema": COMPARABLE_RUN_SCHEMA,
        "lane": lane,
        "protocol": contract["protocol"],
        "status": "completed" if clean else "blocked",
        "scope": "full" if clean else "incomplete",
        "campaign": campaign["id"],
        "operator_source": campaign["operator_source"],
        "runner": {
            "kind": "official-swe-bench-pro",
            "dataset": "ScaleAI/SWE-bench_Pro:public",
            "tasks": 731,
            "attempts": 1,
            "harness_sha256": OFFICIAL_SWE_PRO_EVALUATOR_SHA256,
            "dataset_manifest_sha256": _canonical_sha256(instance_ids),
            "instance_manifest_path": _relative_to_lane(
                manifest_path, lane_dir, "SWE-bench Pro instance manifest"
            ),
            "evaluation_results_path": _relative_to_lane(
                results_path, lane_dir, "SWE-bench Pro results"
            ),
            "patches_path": _relative_to_lane(
                evaluator_patches_path, lane_dir, "SWE-bench Pro evaluator patches"
            ),
            "generated_patches_path": _relative_to_lane(
                generated_copy, lane_dir, "SWE-bench Pro generated patches"
            ),
            "generation_receipt_path": _relative_to_lane(
                generation_copy, lane_dir, "SWE-bench Pro generation receipt"
            ),
            "evaluation_input_path": _relative_to_lane(
                input_path, lane_dir, "SWE-bench Pro evaluation input"
            ),
            "evaluation_outputs": output_paths,
            "patch_prefix": run_id,
            "harness_source": source_before,
            "dataset_source": dataset_before,
            "evaluator_image": args.evaluator_image,
            "container_name": container,
            "docker_socket": str(socket_path),
        },
        "dataset": plan["dataset"],
        "model": plan["model"],
        "evaluator": plan["evaluator"],
        "command": command,
        "process": process,
        "identity_stable": identity_stable,
        "score": score,
        "diagnostics": {"completed": len(results), "errors": errors},
        "started_at": started,
        "finished_at": time.time(),
        "artifacts": artifacts,
    }
    receipt = lane_dir / (run_id + "-run-receipt.json")
    _finalize_receipt(receipt, payload)
    _seal_tree(artifact_root)
    return {"receipt": str(receipt), "status": payload["status"], "score": score}


def _validate_artifacts(receipt_path, receipt):
    root = Path(receipt_path).resolve().parent
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise RuntimeError("comparable run receipt has no artifact manifest")
    seen = set()
    resolved = {}
    for item in artifacts:
        if not isinstance(item, dict):
            raise RuntimeError("comparable run artifact entry is malformed")
        relative = Path(str(item.get("path") or ""))
        if not relative.parts or relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("comparable run artifact path is unsafe")
        if str(relative) in seen:
            raise RuntimeError("comparable run artifact path is duplicated")
        seen.add(str(relative))
        path = root / relative
        cursor = root
        for part in relative.parts:
            cursor = cursor / part
            if cursor.is_symlink():
                raise RuntimeError("comparable run artifact path traverses a symbolic link")
        try:
            resolved_path = path.resolve(strict=True)
        except OSError as exc:
            raise RuntimeError("comparable run artifact is missing") from exc
        if root != resolved_path and root not in resolved_path.parents:
            raise RuntimeError("comparable run artifact escapes its evidence lane")
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("comparable run artifact is missing")
        if path.stat().st_size != item.get("bytes") or _sha256_file(path) != item.get("sha256"):
            raise RuntimeError("comparable run artifact hash mismatch")
        resolved[str(relative)] = resolved_path
    return resolved


def _json_artifact(path, label, max_bytes=64 * 1024 * 1024):
    path = Path(path)
    if path.stat().st_size > int(max_bytes):
        raise RuntimeError("%s exceeds its byte limit" % label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("%s is not valid JSON" % label) from exc


def _artifact_path(paths, relative, label):
    relative = str(relative or "")
    path = paths.get(relative)
    if path is None:
        raise RuntimeError("%s is not bound by the artifact manifest" % label)
    return path


def _recompute_aider_score(receipt, paths, contract):
    runner = receipt.get("runner") or {}
    dataset = receipt.get("dataset") or {}
    model = receipt.get("model") or {}
    result_paths = sorted(
        (relative, path)
        for relative, path in paths.items()
        if relative.endswith("/.aider.results.json")
    )
    if len(result_paths) != int(contract["total"]):
        raise RuntimeError("stock Aider artifacts do not contain 225 results")
    passed = 0
    task_ids = []
    for relative, path in result_paths:
        marker = "/exercises/practice/"
        if marker not in relative:
            raise RuntimeError("stock Aider result path is not an official exercise")
        prefix, exercise = relative.split(marker, 1)
        language = prefix.rsplit("/", 1)[-1]
        exercise_name = exercise.rsplit("/.aider.results.json", 1)[0]
        if not language or not exercise_name or "/" in exercise_name:
            raise RuntimeError("stock Aider result task identity is malformed")
        task_ids.append("%s/exercises/practice/%s" % (language, exercise_name))
        payload = _json_artifact(path, "stock Aider result", max_bytes=4 * 1024 * 1024)
        outcomes = payload.get("tests_outcomes") if isinstance(payload, dict) else None
        if (
            not isinstance(outcomes, list)
            or not 1 <= len(outcomes) <= 2
            or any(not isinstance(value, bool) for value in outcomes)
            or payload.get("model") != model.get("expected_resolved")
            or payload.get("edit_format") != model.get("edit_format")
            or payload.get("commit_hash") != contract["runner_revision"][:7]
        ):
            raise RuntimeError("stock Aider result metadata is not comparable")
        passed += int(outcomes[-1])
    if len(set(task_ids)) != int(contract["total"]):
        raise RuntimeError("stock Aider task identities are duplicated")
    if dataset.get("task_ids_sha256") != _canonical_sha256(sorted(task_ids)):
        raise RuntimeError("stock Aider task manifest does not match its results")
    if runner.get("exercises") != len(task_ids):
        raise RuntimeError("stock Aider runner count does not match its results")
    return {"passed": passed, "total": len(task_ids)}


def _recompute_arc_score(receipt, paths, contract):
    runner = receipt.get("runner") or {}
    scorecard_paths = [
        path for relative, path in paths.items() if relative.endswith("/scorecard.json")
    ]
    recording_paths = sorted(
        path
        for relative, path in paths.items()
        if relative.endswith(".recording.jsonl")
    )
    if len(scorecard_paths) != 1 or len(recording_paths) != int(contract["total"]):
        raise RuntimeError("standardized ARC artifacts do not exactly cover 25 games")
    scorecard = _json_artifact(
        scorecard_paths[0], "standardized ARC scorecard", max_bytes=4 * 1024 * 1024
    )
    integrity = _arc_integrity(scorecard, recording_paths, runner.get("run_tag"))
    if not integrity["valid"]:
        raise RuntimeError(
            "standardized ARC artifacts are invalid: %s"
            % "; ".join(integrity["errors"])
        )
    if _canonical_sha256(integrity) != _canonical_sha256(receipt.get("scorecard")):
        raise RuntimeError("standardized ARC scorecard receipt was not recomputed")
    return {
        "value": integrity["score"],
        "completed_units": int(contract["total"]),
        "scale": 100,
    }


def _recompute_terminal_score(receipt, paths, contract):
    runner = receipt.get("runner") or {}
    model = receipt.get("model") or {}
    runtime = runner.get("harbor_runtime") or {}
    source_record = runner.get("harbor_source") or {}
    task_manifest = runner.get("task_manifest")
    if (
        not isinstance(task_manifest, list)
        or len(task_manifest) != 66
        or _canonical_sha256(task_manifest)
        != OFFICIAL_TERMINAL_RUNTIME_MANIFEST_SHA256
        or _canonical_sha256([item.get("name") for item in task_manifest])
        != OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256
    ):
        raise RuntimeError("Terminal-Bench pinned task manifest is invalid")
    task_by_name = {
        item.get("name"): item for item in task_manifest if isinstance(item, dict)
    }
    if len(task_by_name) != 66:
        raise RuntimeError("Terminal-Bench pinned task manifest is duplicated")
    frozen_source_path = _validate_bound_frozen_source(
        runner.get("frozen_harbor_source"), paths, source_record
    )
    if _terminal_tasks(
        frozen_source_path, harbor_runtime=runtime
    ) != task_manifest:
        raise RuntimeError("frozen Terminal-Bench source does not match its task manifest")
    job_lock_path = _artifact_path(
        paths, runner.get("job_lock_path"), "Terminal-Bench Harbor job lock"
    )
    if _sha256_file(job_lock_path) != runner.get("job_lock_sha256"):
        raise RuntimeError("Terminal-Bench Harbor job lock changed")
    job_root = job_lock_path.parent.resolve()
    job_result_path = _artifact_path(
        paths, runner.get("job_result_path"), "Terminal-Bench Harbor job result"
    )
    if (
        job_result_path.parent.resolve() != job_root
        or _sha256_file(job_result_path) != runner.get("job_result_sha256")
    ):
        raise RuntimeError("Terminal-Bench Harbor job result changed or moved")
    _job_result, job_id, job_window = _terminal_job_result(
        job_result_path, runtime, expected_trials=int(contract["total"])
    )
    if runner.get("job_id") != job_id:
        raise RuntimeError("Terminal-Bench Harbor job identity changed")
    job_lock = _strict_harbor_job_lock(job_lock_path, runtime)
    try:
        n_concurrent = int(
            _one_command_value(receipt.get("command"), "--n-concurrent")
        )
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Terminal-Bench command concurrency is invalid") from exc
    _validate_terminal_job_lock_payload(job_lock, n_concurrent)
    if (
        (job_lock.get("harbor") or {}).get("version") != OFFICIAL_HARBOR_VERSION
        or (job_lock.get("harbor") or {}).get("is_editable") is not False
        or (job_lock.get("retry") or {}).get("max_retries") != 0
    ):
        raise RuntimeError("Terminal-Bench Harbor job lock identity changed")
    job_trial_lock_hashes = Counter(
        _canonical_sha256(item) for item in job_lock.get("trials") or []
    )
    result_path = _artifact_path(
        paths, runner.get("trial_results_path"), "Terminal-Bench trial results"
    )
    payload = _json_artifact(
        result_path, "Terminal-Bench trial results", max_bytes=64 * 1024 * 1024
    )
    records = payload.get("trials") if isinstance(payload, dict) else None
    if (
        payload.get("schema")
        != "black-label-operator/terminal-bench-4-trial-results-v1"
        or not isinstance(records, list)
        or len(records) != int(contract["total"])
    ):
        raise RuntimeError("Terminal-Bench trial results are incomplete")
    _validate_terminal_record_uniqueness(records)
    keys = set()
    tasks = set()
    result_paths = set()
    atif_paths = set()
    lock_paths = set()
    verifier_paths_seen = set()
    result_hashes = set()
    atif_hashes = set()
    trial_ids = set()
    session_ids = set()
    trial_names = set()
    operator_task_ids_by_task = {}
    operator_task_id_owners = {}
    inner_session_ids = set()
    passed = 0
    for record in records:
        if not isinstance(record, dict):
            raise RuntimeError("Terminal-Bench trial result is not an object")
        task_id = record.get("task_id")
        task = task_by_name.get(task_id)
        attempt = record.get("attempt")
        reward = record.get("reward")
        atif_sha256 = record.get("atif_sha256")
        result_sha256 = record.get("result_sha256")
        lock_sha256 = record.get("lock_sha256")
        if (
            not isinstance(task_id, str)
            or task is None
            or record.get("canonical_task_name") != task_id
            or record.get("harbor_task_name") != task_id
            or isinstance(attempt, bool)
            or not isinstance(attempt, int)
            or not 1 <= attempt <= int(runner.get("attempts") or 0)
            or isinstance(reward, bool)
            or reward not in (0, 1, 0.0, 1.0)
            or record.get("error") is not None
            or not FULL_SHA256.fullmatch(str(atif_sha256 or ""))
            or not FULL_SHA256.fullmatch(str(result_sha256 or ""))
            or not FULL_SHA256.fullmatch(str(lock_sha256 or ""))
            or not FULL_SHA256.fullmatch(str(record.get("reward_sha256") or ""))
            or not FULL_SHA256.fullmatch(str(record.get("ctrf_sha256") or ""))
            or not FULL_SHA256.fullmatch(
                str(record.get("verifier_stdout_sha256") or "")
            )
            or not isinstance(record.get("trial_id"), str)
            or not isinstance(record.get("session_id"), str)
            or not isinstance(record.get("trial_name"), str)
            or not isinstance(record.get("operator_task_id"), str)
            or record.get("job_id") != job_id
            or not isinstance(record.get("inner_session_ids"), list)
            or not record.get("inner_session_ids")
            or any(
                not isinstance(item, str) for item in record["inner_session_ids"]
            )
        ):
            raise RuntimeError("Terminal-Bench trial result is not clean and binary")
        result_path = _artifact_path(
            paths, record.get("result_path"), "Terminal-Bench Harbor result"
        )
        atif_path = _artifact_path(
            paths, record.get("atif_path"), "Terminal-Bench ATIF"
        )
        lock_path = _artifact_path(
            paths, record.get("lock_path"), "Terminal-Bench trial lock"
        )
        reward_path = _artifact_path(
            paths, record.get("reward_path"), "Terminal-Bench verifier reward"
        )
        ctrf_path = _artifact_path(
            paths, record.get("ctrf_path"), "Terminal-Bench CTRF"
        )
        stdout_path = _artifact_path(
            paths,
            record.get("verifier_stdout_path"),
            "Terminal-Bench verifier stdout",
        )
        current_verifier_paths = {reward_path, ctrf_path, stdout_path}
        if (
            result_path in result_paths
            or atif_path in atif_paths
            or lock_path in lock_paths
            or verifier_paths_seen.intersection(current_verifier_paths)
            or result_sha256 in result_hashes
            or atif_sha256 in atif_hashes
            or record["trial_id"] in trial_ids
            or record["session_id"] in session_ids
            or record["trial_name"] in trial_names
            or any(item in inner_session_ids for item in record["inner_session_ids"])
            or _sha256_file(result_path) != result_sha256
            or _sha256_file(atif_path) != atif_sha256
            or _sha256_file(lock_path) != lock_sha256
            or _sha256_file(reward_path) != record.get("reward_sha256")
            or _sha256_file(ctrf_path) != record.get("ctrf_sha256")
            or _sha256_file(stdout_path) != record.get("verifier_stdout_sha256")
        ):
            raise RuntimeError("Terminal-Bench trial artifacts are duplicated or changed")
        result_payload, actual_task, trial_name, actual_reward = _terminal_trial_payload(
            result_path,
            expected_task=task_id,
            expected_model=model,
        )
        atif = _terminal_atif(
            atif_path,
            expected_operator_version=model.get("operator_version"),
            expected_codex_version=model.get("codex_version"),
            expected_agent_window=(
                _timestamp(
                    result_payload["agent_execution"]["started_at"],
                    "Harbor agent execution start",
                ),
                _timestamp(
                    result_payload["agent_execution"]["finished_at"],
                    "Harbor agent execution finish",
                ),
            ),
            expected_agent_result=result_payload.get("agent_result"),
        )
        validated = _strict_harbor_trial_documents(
            result_path, atif_path, lock_path, runtime
        )
        trial_lock = _json_artifact(
            lock_path, "Terminal-Bench trial lock", max_bytes=16 * 1024 * 1024
        )
        _validate_terminal_trial_lock_payload(
            trial_lock,
            task,
            model,
            frozen_source_path,
        )
        _validate_terminal_result_config(
            result_payload,
            trial_lock,
            task,
            model,
            frozen_source_path,
            job_id,
            job_root,
        )
        locked_task = trial_lock.get("task") or {}
        locked_agent = trial_lock.get("agent") or {}
        task_path = (
            frozen_source_path
            / "tasks"
            / task["directory"]
        ).resolve()
        result_task = result_payload.get("task_id") or {}
        result_config_task = ((result_payload.get("config") or {}).get("task") or {})
        lock_payload_hash = _canonical_sha256(trial_lock)
        verifier_paths = _terminal_verifier_artifacts(result_path.parent, reward)
        if (
            actual_reward != int(float(reward) == 1.0)
            or trial_name != record.get("trial_name")
            or actual_task != task_id
            or validated.get("id") != record.get("trial_id")
            or validated.get("session_id") != record.get("session_id")
            or atif.get("_validated_inner_session_ids")
            != record.get("inner_session_ids")
            or ((result_payload.get("agent_result") or {}).get("metadata") or {}).get(
                "operator_task_id"
            )
            != record.get("operator_task_id")
            or ((atif.get("agent") or {}).get("model_name"))
            != model.get("expected_resolved")
            or trial_lock.get("schema_version") != 2
            or locked_task.get("name") != task["directory"]
            or locked_task.get("type") != "local"
            or locked_task.get("digest") != task["runtime_digest"]
            or Path(str(locked_task.get("path") or "")).resolve() != task_path
            or result_payload.get("task_checksum") != task["runtime_dirhash"]
            or Path(str(result_task.get("path") or "")).resolve() != task_path
            or Path(str(result_config_task.get("path") or "")).resolve()
            != task_path
            or locked_agent.get("name") != OPERATOR_HARBOR_AGENT
            or locked_agent.get("model_name") != SOL_MODEL
            or (locked_agent.get("kwargs") or {})
            != {
                "reasoning_effort": "xhigh",
                "codex_version": model.get("codex_version"),
                "operator_version": model.get("operator_version"),
                "review_passes": 0,
                "benchmark_suite": "terminal-bench-current",
                "config": CODEX_BENCHMARK_CONFIG,
            }
            or job_trial_lock_hashes[lock_payload_hash] < 1
            or verifier_paths
            != {"reward": reward_path, "ctrf": ctrf_path, "stdout": stdout_path}
            or result_path.parent.parent.resolve() != job_root
            or atif_path.parent.parent.resolve() != result_path.parent.resolve()
            or lock_path.parent.resolve() != result_path.parent.resolve()
            or any(
                path.parent.parent.resolve() != result_path.parent.resolve()
                for path in current_verifier_paths
            )
            or not (
                job_window[0]
                <= _timestamp(result_payload.get("started_at"), "Harbor trial start")
                <= _timestamp(result_payload.get("finished_at"), "Harbor trial finish")
                <= job_window[1]
            )
        ):
            raise RuntimeError("Terminal-Bench trial summary does not match official artifacts")
        job_trial_lock_hashes[lock_payload_hash] -= 1
        result_paths.add(result_path)
        atif_paths.add(atif_path)
        lock_paths.add(lock_path)
        verifier_paths_seen.update(current_verifier_paths)
        result_hashes.add(result_sha256)
        atif_hashes.add(atif_sha256)
        trial_ids.add(record["trial_id"])
        session_ids.add(record["session_id"])
        trial_names.add(record["trial_name"])
        prior_operator_task_id = operator_task_ids_by_task.setdefault(
            task_id, record["operator_task_id"]
        )
        prior_owner = operator_task_id_owners.setdefault(
            record["operator_task_id"], task_id
        )
        if (
            prior_operator_task_id != record["operator_task_id"]
            or prior_owner != task_id
        ):
            raise RuntimeError(
                "Terminal-Bench Operator task identity is not stable per task"
            )
        inner_session_ids.update(record["inner_session_ids"])
        key = (task_id, attempt)
        if key in keys:
            raise RuntimeError("Terminal-Bench trial slot is duplicated")
        keys.add(key)
        tasks.add(task_id)
        passed += int(float(reward) == 1.0)
    if (
        len(tasks) != int(runner.get("tasks") or 0)
        or any(
            (task_id, attempt) not in keys
            for task_id in tasks
            for attempt in range(1, int(runner.get("attempts") or 0) + 1)
        )
        or any(job_trial_lock_hashes.values())
        or set(result_paths)
        != {
            path.resolve()
            for path in job_root.glob("*/result.json")
            if path.is_file() and not path.is_symlink()
        }
        or runner.get("task_manifest_sha256")
        != _canonical_sha256(sorted(tasks))
        or runner.get("task_manifest_sha256")
        != OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256
    ):
        raise RuntimeError("Terminal-Bench task manifest does not match its trials")
    return {"passed": passed, "total": len(records)}


def _recompute_swe_pro_score(receipt, paths, contract):
    raise RuntimeError(
        "SWE-bench Pro comparable evidence is ineligible: %s"
        % "; ".join(SWE_PRO_CERTIFICATION_BLOCKERS)
    )
    runner = receipt.get("runner") or {}
    manifest_path = _artifact_path(
        paths, runner.get("instance_manifest_path"), "SWE-bench Pro instance manifest"
    )
    results_path = _artifact_path(
        paths, runner.get("evaluation_results_path"), "SWE-bench Pro evaluation results"
    )
    patches_path = _artifact_path(
        paths, runner.get("patches_path"), "SWE-bench Pro patches"
    )
    generated_path = _artifact_path(
        paths,
        runner.get("generated_patches_path"),
        "SWE-bench Pro generated patches",
    )
    generation_receipt_path = _artifact_path(
        paths,
        runner.get("generation_receipt_path"),
        "SWE-bench Pro generation receipt",
    )
    evaluation_input_path = _artifact_path(
        paths,
        runner.get("evaluation_input_path"),
        "SWE-bench Pro evaluation input",
    )
    instances = _json_artifact(
        manifest_path, "SWE-bench Pro instance manifest", max_bytes=32 * 1024 * 1024
    )
    results = _json_artifact(
        results_path, "SWE-bench Pro evaluation results", max_bytes=32 * 1024 * 1024
    )
    evaluator_patches = _json_artifact(
        patches_path, "SWE-bench Pro patches", max_bytes=256 * 1024 * 1024
    )
    if (
        not isinstance(instances, list)
        or len(instances) != int(contract["total"])
        or any(not isinstance(item, str) or not item for item in instances)
        or len(set(instances)) != len(instances)
        or runner.get("dataset_manifest_sha256")
        != _canonical_sha256(sorted(instances))
        or not isinstance(results, dict)
        or set(results) != set(instances)
        or any(not isinstance(value, bool) for value in results.values())
        or runner.get("dataset_manifest_sha256")
        != OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256
        or not isinstance(evaluator_patches, list)
        or len(evaluator_patches) != len(instances)
    ):
        raise RuntimeError("SWE-bench Pro artifacts do not cover the exact public set")
    model = receipt.get("model") or {}
    generation_receipt, generated = _validate_swe_generation_receipt(
        generation_receipt_path,
        generated_path,
        receipt,
        model.get("requested"),
        model.get("expected_resolved"),
        instances,
    )
    if (
        model.get("generation_config_sha256")
        != generation_receipt.get("generation_config_sha256")
        or model.get("generation_receipt_sha256")
        != _sha256_file(generation_receipt_path)
        or model.get("generated_patches_sha256") != _sha256_file(generated_path)
    ):
        raise RuntimeError("SWE-bench Pro model identity is not generation-bound")
    generated_by_id = {
        item["instance_id"]: item.get("patch", item.get("model_patch"))
        for item in generated
    }
    patch_ids = []
    prefix = runner.get("patch_prefix")
    for patch in evaluator_patches:
        if not isinstance(patch, dict):
            raise RuntimeError("SWE-bench Pro patch artifact is malformed")
        instance_id = patch.get("instance_id")
        value = patch.get("patch")
        if (
            not isinstance(instance_id, str)
            or not isinstance(value, str)
            or patch.get("prefix") != prefix
            or generated_by_id.get(instance_id) != value
        ):
            raise RuntimeError("SWE-bench Pro patch artifact is malformed")
        patch_ids.append(instance_id)
    if len(set(patch_ids)) != len(instances) or set(patch_ids) != set(instances):
        raise RuntimeError("SWE-bench Pro patches do not cover the instance manifest")
    if (
        _sha256_file(evaluation_input_path)
        != OFFICIAL_SWE_PRO_NORMALIZED_INPUT_SHA256
    ):
        raise RuntimeError("SWE-bench Pro evaluation input does not match the pin")
    rows = []
    try:
        with evaluation_input_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    rows.append(json.loads(line))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("SWE-bench Pro evaluation input is invalid") from exc
    if (
        len(rows) != len(instances)
        or [row.get("instance_id") for row in rows] != sorted(instances)
    ):
        raise RuntimeError("SWE-bench Pro evaluation input coverage changed")
    row_by_id = {row["instance_id"]: row for row in rows}
    output_map = runner.get("evaluation_outputs")
    if not isinstance(output_map, dict) or set(output_map) != set(instances):
        raise RuntimeError("SWE-bench Pro per-instance outputs are incomplete")
    recomputed = {}
    seen_outputs = set()
    for instance_id in instances:
        output_path = _artifact_path(
            paths,
            output_map.get(instance_id),
            "SWE-bench Pro per-instance output",
        )
        if output_path in seen_outputs:
            raise RuntimeError("SWE-bench Pro per-instance output is duplicated")
        seen_outputs.add(output_path)
        output = _json_artifact(
            output_path,
            "SWE-bench Pro per-instance output",
            max_bytes=16 * 1024 * 1024,
        )
        recomputed[instance_id] = _swe_output_passed(
            output, row_by_id[instance_id]
        )
    if results != recomputed:
        raise RuntimeError(
            "SWE-bench Pro aggregate does not match the official per-instance outputs"
        )
    return {"passed": sum(recomputed.values()), "total": len(instances)}


def _recompute_score(receipt_path, receipt, lane, contract):
    paths = _validate_artifacts(receipt_path, receipt)
    if lane == "aider-polyglot-stock":
        score = _recompute_aider_score(receipt, paths, contract)
    elif lane == "arc-agi-3-standardized":
        score = _recompute_arc_score(receipt, paths, contract)
    elif lane == "terminal-bench-4-current":
        score = _recompute_terminal_score(receipt, paths, contract)
    elif lane == "swe-bench-pro-public":
        score = _recompute_swe_pro_score(receipt, paths, contract)
    else:
        raise RuntimeError("unknown current comparable evidence lane")
    if _canonical_sha256(score) != _canonical_sha256(receipt.get("score")):
        raise RuntimeError("comparable run score does not match official artifacts")
    return score


def _command_values(command, flag):
    if (
        not isinstance(command, list)
        or any(not isinstance(item, str) or not item for item in command)
    ):
        raise RuntimeError("comparable run command is malformed")
    values = []
    for index, item in enumerate(command):
        if item == flag:
            if index + 1 >= len(command):
                raise RuntimeError("comparable run command flag has no value")
            values.append(command[index + 1])
    return values


def _one_command_value(command, flag):
    values = _command_values(command, flag)
    if len(values) != 1:
        raise RuntimeError("comparable run command requires exactly one %s" % flag)
    return values[0]


def _validate_terminal_command(receipt, receipt_path):
    command = receipt.get("command")
    runner = receipt.get("runner") or {}
    model = receipt.get("model") or {}
    source = runner.get("frozen_harbor_source") or {}
    runtime = runner.get("harbor_runtime") or {}
    try:
        n_concurrent = int(_one_command_value(command, "--n-concurrent"))
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Terminal-Bench Harbor concurrency is invalid") from exc
    job_lock_relative = str(runner.get("job_lock_path") or "")
    job_lock_absolute = Path(receipt_path).resolve().parent / job_lock_relative
    jobs_dir = job_lock_absolute.parent.parent
    expected = harbor_command(
        "terminal-bench-current",
        jobs_dir,
        n_tasks=66,
        include_tasks=[],
        codex_version=model.get("codex_version"),
        n_concurrent=n_concurrent,
        max_retries=0,
        review_passes=0,
        reasoning_effort="xhigh",
        n_attempts=5,
        dataset_path=Path(source.get("path") or "") / "tasks",
    )
    expected[0] = str(runtime.get("executable") or "")
    if n_concurrent < 1 or command != expected:
        raise RuntimeError("Terminal-Bench Harbor command is not the exact full protocol")


def _validate_swe_command(receipt, receipt_path):
    command = receipt.get("command")
    runner = receipt.get("runner") or {}
    evaluator = receipt.get("evaluator") or {}
    source = runner.get("harness_source") or {}
    dataset = runner.get("dataset_source") or {}
    input_relative = runner.get("evaluation_input_path")
    input_path = Path(receipt_path).resolve().parent / str(input_relative or "")
    artifact_root = input_path.resolve().parent
    expected = _swe_eval_command(
        command[0] if isinstance(command, list) and command else "docker",
        runner.get("evaluator_image"),
        runner.get("container_name"),
        runner.get("docker_socket"),
        Path(source.get("path") or ""),
        Path(dataset.get("path") or ""),
        artifact_root,
        evaluator.get("workers"),
    )
    if command != expected:
        raise RuntimeError("SWE-bench Pro evaluator command is not the exact protocol")


def validate_comparable_run_receipt(receipt_path, lane, campaign):
    receipt_path = Path(receipt_path)
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise RuntimeError("comparable run receipt is missing or symbolic")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError("comparable run receipt is invalid JSON") from exc
    if not isinstance(receipt, dict):
        raise RuntimeError("comparable run receipt is not a JSON object")
    if receipt.get("schema") != COMPARABLE_RUN_SCHEMA:
        raise RuntimeError("comparable run receipt schema is unsupported")
    payload_hash = receipt.get("payload_sha256")
    body = dict(receipt)
    body.pop("payload_sha256", None)
    if payload_hash != _canonical_sha256(body):
        raise RuntimeError("comparable run receipt self-hash mismatch")
    contract = EXTERNAL_NUMBER_ONE_LANES[lane]
    if receipt.get("lane") != lane or receipt.get("protocol") != contract["protocol"]:
        raise RuntimeError("comparable run receipt lane or protocol mismatch")
    if receipt.get("campaign") != campaign.get("id"):
        raise RuntimeError("comparable run receipt campaign mismatch")
    if (receipt.get("operator_source") or {}).get("tree_sha256") != (
        campaign.get("operator_source") or {}
    ).get("tree_sha256"):
        raise RuntimeError("comparable run receipt source mismatch")
    if receipt.get("status") != "completed" or receipt.get("scope") != "full":
        raise RuntimeError("comparable run receipt is not a clean full run")
    runner = receipt.get("runner") or {}
    if lane == "aider-polyglot-stock":
        aider_source = runner.get("aider_source") or {}
        dataset = receipt.get("dataset") or {}
        model = receipt.get("model") or {}
        aider_revision = _contract_git_pin(
            contract,
            "runner_repository",
            "runner_revision",
            OFFICIAL_AIDER_REPOSITORY,
            "stock Aider",
        )
        polyglot_revision = _contract_git_pin(
            contract,
            "dataset_repository",
            "dataset_revision",
            OFFICIAL_POLYGLOT_REPOSITORY,
            "Aider Polyglot dataset",
        )
        if (
            runner.get("kind") != "stock-aider-benchmark"
            or runner.get("custom_operator_agent") is not False
            or runner.get("tries") != 2
            or runner.get("exercises") != 225
            or dataset.get("exercises") != 225
            or _normalize_remote(aider_source.get("repository"))
            != _normalize_remote(OFFICIAL_AIDER_REPOSITORY)
            or _normalize_remote(dataset.get("repository"))
            != _normalize_remote(OFFICIAL_POLYGLOT_REPOSITORY)
            or aider_source.get("revision") != aider_revision
            or dataset.get("revision") != polyglot_revision
            or not FULL_SHA256.fullmatch(
                str(aider_source.get("tracked_content_sha256") or "")
            )
            or not FULL_SHA256.fullmatch(
                str(dataset.get("tracked_content_sha256") or "")
            )
            or model.get("requested") != SOL_MODEL
            or model.get("expected_resolved") != SOL_MODEL
        ):
            raise RuntimeError("custom Operator Aider evidence cannot enter the stock lane")
    elif lane == "arc-agi-3-standardized":
        arc_source = runner.get("arc_source") or {}
        model = receipt.get("model") or {}
        arc_revision = _contract_git_pin(
            contract,
            "runner_repository",
            "runner_revision",
            OFFICIAL_ARC_REPOSITORY,
            "standardized ARC",
        )
        config_pin = _arc_config_contract_pin(contract)
        if config_pin is None:
            raise RuntimeError(
                "standardized ARC evidence is ineligible: %s"
                % ARC_STANDARDIZED_CONFIG_BLOCKER
            )
        if (
            runner.get("kind") != "arc-official-benchmarking-agent"
            or runner.get("custom_operator_planner") is not False
            or runner.get("official_games") != 25
            or (receipt.get("scorecard") or {}).get("valid") is not True
            or _normalize_remote(arc_source.get("repository"))
            != _normalize_remote(OFFICIAL_ARC_REPOSITORY)
            or arc_source.get("revision") != arc_revision
            or not FULL_SHA256.fullmatch(
                str(arc_source.get("tracked_content_sha256") or "")
            )
            or model.get("requested_model") != SOL_MODEL
            or model.get("expected_resolved_model") != SOL_MODEL
            or model.get("config_id") != config_pin["config_id"]
            or model.get("config_sha256") != config_pin["config_sha256"]
            or model.get("config_file_sha256")
            != config_pin["config_file_sha256"]
            or model.get("resolved_model") != SOL_MODEL
        ):
            raise RuntimeError("custom Operator ARC evidence cannot enter the standardized lane")
    elif lane == "terminal-bench-4-current":
        source = runner.get("harbor_source") or {}
        runtime = runner.get("harbor_runtime") or {}
        model = receipt.get("model") or {}
        process = receipt.get("process") or {}
        dataset = receipt.get("dataset") or {}
        if (
            runner.get("kind") != "official-harbor"
            or runner.get("dataset") != "terminal-bench@4.0"
            or runner.get("tasks") != 66
            or runner.get("attempts") != 5
            or runner.get("trials") != 330
            or not FULL_SHA256.fullmatch(
                str(runner.get("source_content_sha256") or "")
            )
            or not FULL_SHA256.fullmatch(
                str(runner.get("task_manifest_sha256") or "")
            )
            or runner.get("source_content_sha256")
            != source.get("tracked_content_sha256")
            or runner.get("dataset_file_sha256")
            != OFFICIAL_TERMINAL_DATASET_FILE_SHA256
            or runner.get("task_manifest_sha256")
            != OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256
            or runner.get("directory_name_manifest_sha256")
            != OFFICIAL_TERMINAL_DIRECTORY_NAME_MANIFEST_SHA256
            or runner.get("dataset_entries_sha256")
            != OFFICIAL_TERMINAL_DATASET_ENTRIES_SHA256
            or runner.get("runtime_manifest_sha256")
            != OFFICIAL_TERMINAL_RUNTIME_MANIFEST_SHA256
            or dataset.get("name") != "terminal-bench@4.0"
            or dataset.get("tasks") != 66
            or dataset.get("attempts") != 5
            or dataset.get("trials") != 330
            or dataset.get("dataset_file_sha256")
            != OFFICIAL_TERMINAL_DATASET_FILE_SHA256
            or dataset.get("task_manifest_sha256")
            != OFFICIAL_TERMINAL_TASK_MANIFEST_SHA256
            or dataset.get("directory_name_manifest_sha256")
            != OFFICIAL_TERMINAL_DIRECTORY_NAME_MANIFEST_SHA256
            or dataset.get("dataset_entries_sha256")
            != OFFICIAL_TERMINAL_DATASET_ENTRIES_SHA256
            or dataset.get("runtime_manifest_sha256")
            != OFFICIAL_TERMINAL_RUNTIME_MANIFEST_SHA256
            or _normalize_remote(source.get("repository"))
            != _normalize_remote(OFFICIAL_TERMINAL_BENCH_REPOSITORY)
            or source.get("revision") != OFFICIAL_TERMINAL_BENCH_REVISION
            or not FULL_SHA256.fullmatch(
                str(source.get("tracked_content_sha256") or "")
            )
            or source.get("export_matches_git") is not True
            or runtime.get("version") != OFFICIAL_HARBOR_VERSION
            or runtime.get("reported_version") != OFFICIAL_HARBOR_VERSION
            or runtime.get("package_files") != OFFICIAL_HARBOR_PACKAGE_FILES
            or runtime.get("record_content_sha256")
            != OFFICIAL_HARBOR_RECORD_CONTENT_SHA256
            or runtime.get("wrapper_template_sha256")
            != OFFICIAL_HARBOR_WRAPPER_TEMPLATE_SHA256
            or runtime.get("full_runtime_attestation_sha256")
            != HARBOR_CERTIFYING_RUNTIME_ATTESTATION_SHA256
            or runtime.get("full_runtime_attestation_matches") is not True
            or runtime.get("record_mismatches") != []
            or runtime.get("stock_eligible") is not True
            or model.get("provider") != "codex"
            or model.get("profile") != "sol-benchmark"
            or model.get("requested") != SOL_MODEL
            or model.get("expected_resolved") != SOL_MODEL
            or model.get("reasoning_effort") != "xhigh"
            or model.get("review_passes") != 0
            or process.get("timed_out") is not False
            or process.get("termination_confirmed") is not True
            or process.get("exit_code") not in (0, 1)
            or receipt.get("identity_stable") is not True
        ):
            raise RuntimeError("Terminal-Bench 4 requires exact official Harbor evidence")
        live_runtime = _harbor_runtime_identity(runtime.get("executable"))
        if live_runtime != runtime:
            raise RuntimeError("Terminal-Bench Harbor runtime changed after the run")
        live_source = official_git_identity(
            source.get("path"),
            OFFICIAL_TERMINAL_BENCH_REVISION,
            OFFICIAL_TERMINAL_BENCH_REPOSITORY,
        )
        live_tasks = _terminal_tasks(source.get("path"), harbor_runtime=live_runtime)
        if live_source != source or live_tasks != runner.get("task_manifest"):
            raise RuntimeError("Terminal-Bench pinned source or task manifest changed")
        _validate_terminal_command(receipt, receipt_path)
    elif lane == "swe-bench-pro-public":
        raise RuntimeError(
            "SWE-bench Pro comparable evidence is ineligible: %s"
            % "; ".join(SWE_PRO_CERTIFICATION_BLOCKERS)
        )
        source = runner.get("harness_source") or {}
        dataset_source = runner.get("dataset_source") or {}
        dataset = receipt.get("dataset") or {}
        evaluator = receipt.get("evaluator") or {}
        process = receipt.get("process") or {}
        if (
            runner.get("kind") != "official-swe-bench-pro"
            or runner.get("dataset") != "ScaleAI/SWE-bench_Pro:public"
            or runner.get("tasks") != 731
            or runner.get("attempts") != 1
            or not FULL_SHA256.fullmatch(
                str(runner.get("harness_sha256") or "")
            )
            or not FULL_SHA256.fullmatch(
                str(runner.get("dataset_manifest_sha256") or "")
            )
            or runner.get("harness_sha256")
            != OFFICIAL_SWE_PRO_EVALUATOR_SHA256
            or runner.get("dataset_manifest_sha256")
            != OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256
            or dataset.get("name") != "ScaleAI/SWE-bench_Pro:public"
            or dataset.get("instances") != 731
            or dataset.get("manifest_sha256")
            != OFFICIAL_SWE_PRO_TASK_MANIFEST_SHA256
            or dataset.get("parquet_sha256") != OFFICIAL_SWE_PRO_PARQUET_SHA256
            or dataset.get("official_raw_sha256")
            != OFFICIAL_SWE_PRO_RAW_DATA_SHA256
            or dataset.get("normalized_input_sha256")
            != OFFICIAL_SWE_PRO_NORMALIZED_INPUT_SHA256
            or _normalize_remote(source.get("repository"))
            != _normalize_remote(OFFICIAL_SWE_PRO_REPOSITORY)
            or source.get("revision") != OFFICIAL_SWE_PRO_REVISION
            or not FULL_SHA256.fullmatch(
                str(source.get("tracked_content_sha256") or "")
            )
            or _normalize_remote(dataset_source.get("repository"))
            != _normalize_remote(OFFICIAL_SWE_PRO_DATASET_REPOSITORY)
            or dataset_source.get("revision")
            != OFFICIAL_SWE_PRO_DATASET_REVISION
            or not FULL_SHA256.fullmatch(
                str(dataset_source.get("tracked_content_sha256") or "")
            )
            or evaluator.get("source_sha256")
            != OFFICIAL_SWE_PRO_EVALUATOR_SHA256
            or not IMMUTABLE_CONTAINER_IMAGE.fullmatch(
                str(evaluator.get("container_image") or "")
            )
            or evaluator.get("container_image") != runner.get("evaluator_image")
            or evaluator.get("platform") != "linux/amd64"
            or evaluator.get("network_blocked_in_task_containers") is not True
            or process.get("exit_code") != 0
            or process.get("timed_out") is not False
            or process.get("termination_confirmed") is not True
            or receipt.get("identity_stable") is not True
        ):
            raise RuntimeError("SWE-bench Pro requires exact official runner evidence")
        _validate_swe_command(receipt, receipt_path)
    else:
        raise RuntimeError("unknown current comparable evidence lane")
    _recompute_score(receipt_path, receipt, lane, contract)
    return receipt


def ingest_official_quality_evidence(args, settings):
    """Ingest one signed organizer receipt without accepting caller claims."""
    lane = args.lane
    campaign_dir, campaign, contract = _official_quality_campaign_context(
        settings, args.campaign, lane
    )
    source_input = Path(args.organizer_receipt).expanduser()
    if source_input.is_symlink():
        raise RuntimeError("organizer receipt source may not be a symbolic link")
    try:
        source = source_input.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError("organizer receipt source is missing") from exc
    if not source.is_file() or source.stat().st_size > 1024 * 1024:
        raise RuntimeError("organizer receipt source must be a regular file under 1 MiB")

    quality_root = campaign_dir / "official-quality-evidence"
    if quality_root.is_symlink():
        raise RuntimeError("official-quality evidence root may not be symbolic")
    quality_root.mkdir(mode=0o700, exist_ok=True)
    lane_dir = quality_root / lane
    if lane_dir.is_symlink():
        raise RuntimeError("official-quality lane may not be symbolic")
    lane_dir.mkdir(mode=0o700, exist_ok=True)
    evidence_path = lane_dir / "evidence.json"
    if evidence_path.exists() or evidence_path.is_symlink():
        raise RuntimeError("official-quality evidence already exists for this lane")

    staging = lane_dir / (".organizer-receipt.%s.tmp" % uuid.uuid4().hex)
    stored = None
    try:
        _copy_exclusive(source, staging)
        validated = validate_official_quality_organizer_receipt(
            staging, lane, contract, campaign
        )
        digest = _sha256_file(staging)
        stored = lane_dir / ("organizer-receipt-%s.json" % digest[:16])
        if stored.exists() or stored.is_symlink():
            raise RuntimeError("official organizer receipt is already stored")
        os.link(staging, stored, follow_symlinks=False)
        stored.chmod(0o400)
        staging.unlink()
        validated_again = validate_official_quality_organizer_receipt(
            stored, lane, contract, campaign
        )
        if validated_again != validated or _sha256_file(stored) != digest:
            raise RuntimeError("stored organizer receipt changed during ingest")
        verification = contract["organizer_verification"]
        wrapper = {
            "schema": OFFICIAL_QUALITY_EVIDENCE_SCHEMA,
            "lane": lane,
            "protocol": contract["protocol"],
            "campaign": {
                "id": campaign["id"],
                "created_at": campaign["created_at"],
            },
            "operator_source": campaign["operator_source"],
            "identity": campaign["identity"],
            "score_scope": contract["score_scope"],
            "official_score": {
                "value": validated["score"],
                "scale": OFFICIAL_QUALITY_SCORE_SCALE,
                "origin": "organizer_reported",
                "locally_derived": False,
            },
            "organizer_verification": {
                key: verification.get(key)
                for key in (
                    "method",
                    "signature_algorithm",
                    "receipt_schema",
                    "trust_root_id",
                    "trust_root_sha256",
                )
            },
            "organizer_receipt": {
                "path": str(stored.relative_to(campaign_dir)),
                "sha256": digest,
            },
        }
        _write_json_atomic_exclusive(evidence_path, wrapper)
    except Exception:
        for artifact in (staging, stored):
            if artifact is None:
                continue
            try:
                artifact.unlink()
            except OSError:
                pass
        raise

    from .benchmark_campaign import campaign_status

    return {
        "campaign": campaign["id"],
        "lane": lane,
        "organizer_receipt": str(stored),
        "organizer_receipt_sha256": digest,
        "evidence": str(evidence_path),
        "score": validated["score"],
        "status": campaign_status(settings, campaign_dir)["official_quality"],
    }


def capture_target_snapshot(args, settings):
    lane = args.lane
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    raise RuntimeError(
        "organizer target capture is ineligible: %s"
        % EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER
    )
    campaign_dir = Path(campaign_dir).resolve()
    lane_dir = campaign_dir / "external-evidence" / lane
    lane_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    source_url = contract["target_source_url"]
    api_request = request.Request(
        source_url,
        headers={
            "Accept": "text/html,application/json;q=0.9,*/*;q=0.1",
            "User-Agent": "BlackLabelOperator-Evidence/0.8",
        },
    )
    with request.urlopen(api_request, timeout=float(args.timeout)) as response:
        final_url = response.geturl()
        status = int(getattr(response, "status", 200))
        content_type = response.headers.get("Content-Type")
        body = response.read(10 * 1024 * 1024 + 1)
    if status != 200 or not body or len(body) > 10 * 1024 * 1024:
        raise RuntimeError("organizer target snapshot response is invalid or too large")
    allowed_hosts = set(contract["submission_hosts"])
    allowed_hosts.add(urlparse(source_url).hostname)
    if urlparse(final_url).scheme != "https" or urlparse(final_url).hostname not in allowed_hosts:
        raise RuntimeError("organizer target snapshot redirected off approved hosts")
    captured_at = time.time()
    expires_at = captured_at + EXTERNAL_TARGET_MAX_AGE_SECONDS
    digest = hashlib.sha256(body).hexdigest()
    capture_id = "%s-%s" % (
        time.strftime("%Y%m%d-%H%M%S", time.gmtime(captured_at)),
        uuid.uuid4().hex[:8],
    )
    raw_path = lane_dir / ("target-raw-%s-%s.bin" % (capture_id, digest[:16]))
    _write_bytes_exclusive(raw_path, body)
    snapshot = {
        "schema": TARGET_SNAPSHOT_SCHEMA,
        "lane": lane,
        "source_url": source_url,
        "final_url": final_url,
        "captured_at": captured_at,
        "expires_at": expires_at,
        "leader_value": contract["leader_value"],
        "leader_value_kind": contract["leader_value_kind"],
        "target_operator": contract["target_operator"],
        "target_value": contract["target_value"],
        "raw_snapshot": {
            "path": str(raw_path.relative_to(campaign_dir)),
            "sha256": digest,
            "bytes": len(body),
            "http_status": status,
            "content_type": content_type,
        },
    }
    snapshot_path = lane_dir / (
        "target-snapshot-%s-%s.json" % (capture_id, digest[:16])
    )
    _write_json_exclusive(snapshot_path, snapshot)
    return {
        "campaign": campaign["id"],
        "lane": lane,
        "target_snapshot": str(snapshot_path),
        "raw_snapshot": str(raw_path),
        "captured_at": captured_at,
        "expires_at": expires_at,
        "sha256": _sha256_file(snapshot_path),
    }


def ingest_external_evidence(args, settings):
    lane = args.lane
    campaign_dir, campaign, contract = _campaign_context(
        settings, args.campaign, lane
    )
    raise RuntimeError(
        "external certification ingest is ineligible: %s"
        % EXTERNAL_ORGANIZER_VERIFICATION_BLOCKER
    )
    campaign_dir = Path(campaign_dir).resolve()
    lane_dir = campaign_dir / "external-evidence" / lane
    lane_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    run_path = Path(args.run_receipt).expanduser().resolve()
    if run_path.parent != lane_dir.resolve():
        raise RuntimeError(
            "run receipt must be generated directly in this campaign lane"
        )
    run = validate_comparable_run_receipt(run_path, lane, campaign)
    submission_source = Path(args.submission_receipt).expanduser().resolve()
    target_source = Path(args.target_snapshot).expanduser().resolve()
    if len({submission_source, target_source, run_path}) != 3:
        raise RuntimeError(
            "run, target snapshot, and organizer receipts must be separate artifacts"
        )
    parsed = urlparse(args.url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in set(contract["submission_hosts"])
    ):
        raise RuntimeError("submission URL is not on an approved organizer host")
    if not args.independently_verified:
        raise RuntimeError("organizer acceptance must be independently verified")
    if args.status not in ("accepted", "published"):
        raise RuntimeError("organizer status must be accepted or published")
    if not str(args.receipt_id or "").strip() or not str(args.verified_at or "").strip():
        raise RuntimeError("organizer receipt ID and verification time are required")
    if (
        target_source.parent != lane_dir.resolve()
        or target_source.is_symlink()
        or not target_source.is_file()
        or target_source.stat().st_size > 1024 * 1024
    ):
        raise RuntimeError(
            "target snapshot must be captured directly in this campaign lane"
        )
    try:
        snapshot_payload = json.loads(target_source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("target snapshot must be a JSON artifact") from exc
    expected_snapshot = {
        "schema": TARGET_SNAPSHOT_SCHEMA,
        "lane": lane,
        "source_url": contract["target_source_url"],
        "leader_value": contract["leader_value"],
        "leader_value_kind": contract["leader_value_kind"],
        "target_operator": contract["target_operator"],
        "target_value": contract["target_value"],
    }
    if any(
        snapshot_payload.get(key) != value
        for key, value in expected_snapshot.items()
    ):
        raise RuntimeError("target snapshot content does not match the contract")
    captured_at = _timestamp(
        snapshot_payload.get("captured_at"), "target snapshot capture"
    )
    expires_at = _timestamp(
        snapshot_payload.get("expires_at"), "target snapshot expiry"
    )
    now = time.time()
    if captured_at > now + 300:
        raise RuntimeError("target snapshot capture time is in the future")
    if now - captured_at > EXTERNAL_TARGET_MAX_AGE_SECONDS or expires_at <= now:
        raise RuntimeError("target snapshot is stale or expired")
    if expires_at - captured_at > EXTERNAL_TARGET_MAX_AGE_SECONDS:
        raise RuntimeError("target snapshot expiry exceeds the contract maximum")
    final_url = urlparse(str(snapshot_payload.get("final_url") or ""))
    approved_target_hosts = set(contract["submission_hosts"])
    approved_target_hosts.add(urlparse(contract["target_source_url"]).hostname)
    if (
        final_url.scheme != "https"
        or final_url.hostname not in approved_target_hosts
    ):
        raise RuntimeError("target snapshot final URL is not approved")
    raw = snapshot_payload.get("raw_snapshot") or {}
    raw_relative = Path(str(raw.get("path") or ""))
    if (
        not raw_relative.parts
        or raw_relative.is_absolute()
        or ".." in raw_relative.parts
    ):
        raise RuntimeError("target raw snapshot path is unsafe")
    raw_path = campaign_dir / raw_relative
    if (
        raw_path.parent != lane_dir.resolve()
        or raw_path.is_symlink()
        or not raw_path.is_file()
        or raw_path.stat().st_size != raw.get("bytes")
        or _sha256_file(raw_path) != raw.get("sha256")
        or raw.get("http_status") != 200
    ):
        raise RuntimeError("target raw snapshot artifact does not match")
    target_hash = _sha256_file(target_source)
    target_destination = target_source
    evidence_path = lane_dir / "evidence.json"
    if evidence_path.exists() or evidence_path.is_symlink():
        raise RuntimeError("external evidence already exists for this lane")
    submission_hash = _sha256_file(submission_source)
    destination = lane_dir / ("organizer-%s.receipt" % submission_hash[:16])
    _copy_exclusive(submission_source, destination)
    evidence = {
        "schema": EXTERNAL_NUMBER_ONE_EVIDENCE_SCHEMA,
        "lane": lane,
        "protocol": contract["protocol"],
        "operator_source": campaign["operator_source"],
        "score": run["score"],
        "run_receipt": {
            "path": str(run_path.relative_to(campaign_dir)),
            "sha256": _sha256_file(run_path),
        },
        "target_snapshot": {
            "path": str(target_destination.relative_to(campaign_dir)),
            "sha256": target_hash,
            "source_url": contract["target_source_url"],
            "captured_at": snapshot_payload.get("captured_at"),
            "expires_at": snapshot_payload.get("expires_at"),
        },
        "submission_receipt": {
            "path": str(destination.relative_to(campaign_dir)),
            "sha256": submission_hash,
            "organizer": contract["organizer"],
            "status": args.status,
            "independently_verified": True,
            "receipt_id": args.receipt_id,
            "url": args.url,
            "verified_at": args.verified_at,
        },
    }
    _write_json_exclusive(evidence_path, evidence)
    return {
        "campaign": campaign["id"],
        "lane": lane,
        "evidence": str(evidence_path),
        "score": run["score"],
        "number_one": False,
        "statement": (
            "Organizer evidence was ingested; campaign certification still "
            "decides the multi-lane number-one claim."
        ),
    }
