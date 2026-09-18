"""Resolve the ~/.vigil state surface for the Python sidecar — the mirror of Swift's `VigilPaths`.

WHY THIS EXISTS: Vigil is a security product, and its `~/.vigil` state surface is the OWNER's
live security map. On 2026-07-12 a QA pass launched under `env HOME=/tmp/vgqa-…` wrote
`exclusion_zones.json` into the founder's REAL home while his live Vigil was running — a stray
exclusion zone silently SUPPRESSES real presence dots. `env HOME=` is NOT isolation for this app.

b13 added `VigilPaths` (HomeCore.swift) so `VIGIL_HOME` / `HOMEFRONT_DATA_DIR` redirect that
surface. That fix covered the **Swift half only**: this sidecar named its state with raw
`os.path.expanduser("~/.vigil/…")` literals, which route through nothing and therefore escaped the
override entirely — with `VIGIL_HOME` set, `vigil_map.GEOMETRY_PATH` still resolved to
the real `~/.vigil/geometry.json`. HomeCore.swift already names this exact escape: "a raw
`~/.vigil/…` literal anywhere else escapes the override." The sidecar was that anywhere-else, and it
is the half that actually WRITES (baselines.json / geometry.json / home_graph.json churn per cycle).

Resolution order (first match wins) — byte-identical to VigilPaths.base():
  1. VIGIL_HOME          — explicit override; the isolation knob for QA/tests.
  2. HOMEFRONT_DATA_DIR  — the existing workspace override; one env var isolates the WHOLE state
                           surface, so a harness that already isolated the SQLite workspace cannot
                           leak the map into the owner's home. Base is <dir>/vigil, as in Swift.
  3. ~/.vigil            — unchanged legacy behaviour. With neither var set the resolved path is
                           byte-identical to the old literal, so the owner's live install is
                           untouched.

An empty value counts as UNSET (mirrors Swift's `value.isEmpty ? nil : value`), so `VIGIL_HOME=`
cannot silently redirect state to the process's working directory.

PURE: resolution NEVER creates a directory — callers create on write, as they already did — so
merely resolving a path in a test cannot materialise a `.vigil` dir in a real home.

Resolution happens on every CALL (never cached at import), so an in-process `monkeypatch.setenv`
is observed immediately and the override is provable in both directions. Modules exposing
path CONSTANTS re-export these through a module-level `__getattr__` for the same reason: a
constant frozen at import time would ignore an override set afterwards.
"""

from __future__ import annotations

import os

OVERRIDE_KEY = "VIGIL_HOME"       # VigilPaths.overrideKey
WORKSPACE_KEY = "HOMEFRONT_DATA_DIR"  # VigilPaths.workspaceKey


def _env(key: str) -> str | None:
    """An env var's value, treating empty/whitespace-only as unset (Swift: isEmpty -> nil)."""
    value = os.environ.get(key)
    if value is None:
        return None
    value = value.strip()
    return value or None


def base() -> str:
    """The base directory holding fleet.json / geometry.json / home_graph.json and siblings."""
    override = _env(OVERRIDE_KEY)
    if override is not None:
        return override
    workspace = _env(WORKSPACE_KEY)
    if workspace is not None:
        return os.path.join(workspace, "vigil")
    # Legacy default. expanduser("~/.vigil") verbatim — the pre-fix literal, so an install with
    # neither var set resolves byte-for-byte where it always did.
    return os.path.expanduser("~/.vigil")


def state_path(name: str) -> str:
    """A named state file inside the base directory.

    The ONLY way sidecar code may name a ~/.vigil file — a raw "~/.vigil/…" literal
    anywhere else escapes the override, which is the exact defect this module closes.
    """
    return os.path.join(base(), name)
