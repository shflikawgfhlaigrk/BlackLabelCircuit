"""Benchmark report generator (Track E3, CONTRACTS.md §8).

Operating envelope: replays labeled `.vigil` sessions through the fall
pipeline and vitals extractors, then writes an honest, self-contained
`report.html` + `report.json`. Every pipeline dependency is imported lazily
(FallPipeline, WindowManager, Breathing/HeartExtractor) and can be injected
for tests; when a stage isn't available yet, the corresponding section says
"no data" — this report never fabricates a number. Metrics on synthetic
sessions validate plumbing only; real acceptance numbers come from recorded
hardware sessions.

Fall event convention: an entry from `FallPipeline.run_session` counts as a
predicted fall when its topic/type is "fall.confirmed" (or label == "fall");
its time is `t` (or `ts`). Matching tolerance vs labels: ±3 s around the
labeled interval.

CLI: python3 -m vigil.benchmark sessions/*.vigil --out reports/
"""

from __future__ import annotations

import argparse
import hashlib
import html as _html
import json
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from . import __version__
from .config import VigilConfig
from .session import CONFOUNDER_LABELS, FALL_LABELS, Session

MATCH_TOL_S = 3.0
FALL_TYPES = ["fall-fast", "fall-slow", "fall-slide"]


# ---------------------------------------------------------------------------
# Result container
# ---------------------------------------------------------------------------

@dataclass
class BenchmarkResult:
    header: dict = field(default_factory=dict)
    falls: dict = field(default_factory=dict)
    vitals: dict = field(default_factory=dict)
    coverage: dict = field(default_factory=dict)
    failures: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(
            {"header": self.header, "falls": self.falls,
             "vitals": self.vitals, "coverage": self.coverage,
             "failures": self.failures, "notes": self.notes},
            indent=2, default=_jsonable)


def _jsonable(o: Any):
    if isinstance(o, (np.floating, np.integer)):
        return o.item()
    if isinstance(o, np.ndarray):
        return o.tolist()
    if isinstance(o, Path):
        return str(o)
    return str(o)


# ---------------------------------------------------------------------------
# Header helpers
# ---------------------------------------------------------------------------

def _git_hash() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=Path(__file__).resolve().parent,
            capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return "unknown"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Fall scoring
# ---------------------------------------------------------------------------

def _is_fall_event(e: dict) -> bool:
    topic = str(e.get("topic") or e.get("type") or e.get("event") or "")
    if topic:
        # Real pipelines also emit gate1.candidate / gate2.classified
        # (label == "fall") for the same physical event — only the
        # confirmed topic is a predicted fall.
        return topic == "fall.confirmed"
    return str(e.get("label", "")) == "fall"


def _event_t(e: dict) -> float:
    return float(e.get("t", e.get("ts", -1e9)))


def _score_internal(session: Session, events: list[dict],
                    tol: float = MATCH_TOL_S) -> dict:
    """Match predicted fall events to labeled fall intervals (±tol s).

    Returns {"per_fall": [{label, t0, t1, hit, event_t}],
             "false_alarms": [{t, attributed, said}]}."""
    preds = sorted((e for e in events if _is_fall_event(e)), key=_event_t)
    used: set[int] = set()
    per_fall = []
    for lb in session.labels:
        if lb.label not in FALL_LABELS:
            continue
        best_i, best_d = None, None
        for i, e in enumerate(preds):
            if i in used:
                continue
            t = _event_t(e)
            if lb.t0 - tol <= t <= lb.t1 + tol:
                d = abs(t - lb.t0)
                if best_d is None or d < best_d:
                    best_i, best_d = i, d
        if best_i is not None:
            used.add(best_i)
        per_fall.append({"label": lb.label, "t0": lb.t0, "t1": lb.t1,
                         "hit": best_i is not None,
                         "event_t": _event_t(preds[best_i])
                         if best_i is not None else None})
    false_alarms = []
    for i, e in enumerate(preds):
        if i in used:
            continue
        t = _event_t(e)
        attributed = "unlabeled"
        for lb in session.labels:
            if lb.label in CONFOUNDER_LABELS and lb.t0 - tol <= t <= lb.t1 + tol:
                attributed = lb.label
                break
        said = (f"fall.confirmed at t={t:.1f}s"
                + (f", confidence={e['confidence']:.2f}"
                   if isinstance(e.get("confidence"), (int, float)) else ""))
        false_alarms.append({"t": t, "attributed": attributed, "said": said})
    return {"per_fall": per_fall, "false_alarms": false_alarms}


def _score_session(session: Session, events: list[dict]) -> dict:
    """Prefer the C-track scorer (vigil.falls.score_session /
    falls.fusion.score_session) lazily; fall back to the internal scorer if
    it is missing or returns an unrecognized shape."""
    scorer = None
    try:
        from .falls import fusion as _fusion  # lazy — Track C
        scorer = getattr(_fusion, "score_session", None)
    except ImportError:
        pass
    if scorer is None:
        try:
            from . import falls as _falls  # lazy — Track C
            scorer = getattr(_falls, "score_session", None)
        except ImportError:
            pass
    if scorer is not None:
        try:
            out = scorer(session, events)
            if (isinstance(out, dict) and "per_fall" in out
                    and "false_alarms" in out):
                return out
        except Exception:
            pass  # fall through to the internal scorer
    return _score_internal(session, events)


# ---------------------------------------------------------------------------
# run_benchmark
# ---------------------------------------------------------------------------

def run_benchmark(session_paths: list[Path], out_dir: Path,
                  config: VigilConfig | None = None,
                  classifier_path: Path | None = None,
                  *,
                  pipeline: Any = None,
                  window_manager: Any = None,
                  breathing_extractor: Any = None,
                  heart_extractor: Any = None) -> BenchmarkResult:
    """Run the full benchmark and write report.html + report.json.

    Keyword-only args are dependency-injection points for tests; when None,
    the real Track C/D objects are imported lazily and any unavailable stage
    degrades to a "no data" section (never a fabricated number).
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    config = config or VigilConfig()
    result = BenchmarkResult()

    sessions: list[tuple[Path, Session]] = []
    for p in session_paths:
        p = Path(p)
        sessions.append((p, Session.load(p)))

    # -- header ---------------------------------------------------------------
    inventory = []
    for p, s in sessions:
        counts: dict[str, int] = {}
        for lb in s.labels:
            counts[lb.label] = counts.get(lb.label, 0) + 1
        inventory.append({"path": str(p), "name": p.name,
                          "duration_s": round(s.duration_s, 1),
                          "nodes": s.node_ids, "labels": counts,
                          "refs": {k: len(v) for k, v in s.refs.items()}})
    result.header = {
        "git_hash": _git_hash(),
        "engine_version": __version__,
        "classifier_sha256": (_sha256(Path(classifier_path))
                              if classifier_path else None),
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sessions": inventory,
    }

    # -- fall pipeline ----------------------------------------------------------
    pl = pipeline
    if pl is None:
        try:
            from .bus import EventBus
            from .falls.fusion import FallPipeline  # lazy — Track C
            clf = None
            if classifier_path is not None:
                from .falls.gate2 import Gate2Classifier
                clf = Gate2Classifier()
                clf.load(classifier_path)
            pl = FallPipeline(config, EventBus(), clf)
        except ImportError as e:
            result.notes.append(f"fall pipeline unavailable ({e}); "
                                "falls section has no data")
            pl = None

    by_type = {ft: {"n": 0, "tp": 0} for ft in FALL_TYPES}
    conf_counts = {lb: {"n": 0, "fp": 0} for lb in sorted(CONFOUNDER_LABELS)}
    total_fp = 0
    for p, s in sessions:
        for lb in s.labels:
            if lb.label in CONFOUNDER_LABELS:
                conf_counts[lb.label]["n"] += 1
        if pl is None:
            continue
        try:
            events = list(pl.run_session(s))
        except Exception as e:  # a broken stage must not kill the report
            result.notes.append(f"{p.name}: run_session failed ({e})")
            events = []
        scored = _score_session(s, events)
        for pf in scored["per_fall"]:
            ft = pf["label"]
            by_type.setdefault(ft, {"n": 0, "tp": 0})
            by_type[ft]["n"] += 1
            if pf["hit"]:
                by_type[ft]["tp"] += 1
            else:
                result.failures.append({
                    "kind": "missed-fall", "session": p.name,
                    "t": pf["t0"], "label": ft,
                    "pipeline_said": "no fall.confirmed within "
                                     f"±{MATCH_TOL_S:.0f} s of the labeled "
                                     "fall"})
        for fa in scored["false_alarms"]:
            total_fp += 1
            if fa["attributed"] in conf_counts:
                conf_counts[fa["attributed"]]["fp"] += 1
            result.failures.append({
                "kind": "false-alarm", "session": p.name, "t": fa["t"],
                "label": fa["attributed"], "pipeline_said": fa["said"]})

    tp_all = sum(v["tp"] for v in by_type.values())
    n_all = sum(v["n"] for v in by_type.values())
    result.falls = {
        "available": pl is not None,
        "by_type": {
            ft: {"n": v["n"], "tp": v["tp"],
                 "recall": (v["tp"] / v["n"]) if v["n"] else None}
            for ft, v in by_type.items()},
        "recall": (tp_all / n_all) if (pl is not None and n_all) else None,
        "precision": (tp_all / (tp_all + total_fp))
                     if (pl is not None and (tp_all + total_fp)) else None,
        "n_false_alarms": total_fp if pl is not None else None,
        "confounders": {
            lb: {"n": v["n"], "fp": v["fp"],
                 "fp_rate": (v["fp"] / v["n"]) if v["n"] else None}
            for lb, v in conf_counts.items()},
    }

    # -- vitals -----------------------------------------------------------------
    wm, be, he = window_manager, breathing_extractor, heart_extractor
    if wm is None:
        try:
            from .vitals.windows import WindowManager  # lazy — Track D
            wm = WindowManager(config.thresholds)
        except ImportError as e:
            result.notes.append(f"vitals window manager unavailable ({e})")
    if be is None:
        try:
            from .vitals.breathing import BreathingExtractor  # lazy — Track D
            be = BreathingExtractor()
        except ImportError as e:
            result.notes.append(f"breathing extractor unavailable ({e})")
    if he is None:
        try:
            from .vitals.heart import HeartExtractor  # lazy — Track D
            he = HeartExtractor()
        except ImportError as e:
            result.notes.append(f"heart extractor unavailable ({e})")

    mae: dict[str, dict] = {"breathing": {}, "hr": {}}
    coverage_per: dict[str, dict] = {}
    for p, s in sessions:
        has_refs = {k: bool(s.refs.get(k)) for k in ("breathing", "hr")}
        if not any(has_refs.values()):
            continue
        nid = s.node_ids[0]
        for room, bed in config.vitals_zone.items():
            if bed in s.node_ids:
                nid = bed
                break
        energy = None
        if wm is not None:
            from .demo import motion_energy_series  # shared E helper
            energy = motion_energy_series(s.amps[nid], s.fs)
        cov_entry: dict[str, Any] = {}
        for kind, extractor in (("breathing", be), ("hr", he)):
            if not has_refs[kind]:
                continue
            refs = sorted(s.refs[kind], key=lambda r: r["t"])
            ref_t = np.array([r["t"] for r in refs])
            ref_bpm = np.array([r["bpm"] for r in refs])
            if wm is None or extractor is None or energy is None:
                mae[kind][p.name] = {"mae": None, "n_windows": 0}
                cov_entry[f"{kind}_pct"] = None
                continue
            wins = list(wm.find(energy, kind))
            covered = sum(t1 - t0 for t0, t1 in wins)
            cov_entry[f"{kind}_pct"] = (100.0 * covered / s.duration_s
                                        if s.duration_s else None)
            errs: list[float] = []
            ests: list[float] = []
            for t0, t1 in wins:
                i0, i1 = int(t0 * s.fs), int(t1 * s.fs)
                window = s.amps[nid][i0:i1]
                try:
                    if kind == "breathing":
                        est = extractor.estimate(window)
                    else:
                        f_breath = None
                        b_est = mae["breathing"].get(p.name)
                        if b_est and b_est.get("mean_est_bpm"):
                            f_breath = b_est["mean_est_bpm"] / 60.0
                        est = extractor.estimate({nid: window}, f_breath)
                except Exception as e:
                    result.notes.append(f"{p.name}: {kind} estimate failed "
                                        f"({e})")
                    continue
                ref = float(np.interp((t0 + t1) / 2.0, ref_t, ref_bpm))
                ests.append(float(est.bpm))
                errs.append(abs(float(est.bpm) - ref))
            entry: dict[str, Any] = {
                "mae": (float(np.mean(errs)) if errs else None),
                "n_windows": len(wins)}
            if kind == "breathing" and ests:
                # feed the mean breathing estimate to the heart extractor
                # (harmonic rejection hint per D contract)
                entry["mean_est_bpm"] = float(np.mean(ests))
            mae[kind][p.name] = entry
        coverage_per[p.name] = cov_entry

    def _agg(kind: str) -> float | None:
        vals = [v["mae"] for v in mae[kind].values() if v["mae"] is not None]
        return float(np.mean(vals)) if vals else None

    result.vitals = {
        "available": not (wm is None or (be is None and he is None)),
        "mae": mae,
        "aggregate": {"breathing_mae": _agg("breathing"),
                      "hr_mae": _agg("hr")},
    }
    pcts = [v for c in coverage_per.values()
            for v in c.values() if v is not None]
    result.coverage = {
        "per_session": coverage_per,
        "mean_qualifying_pct": (float(np.mean(pcts)) if pcts else None),
    }

    # -- reports ---------------------------------------------------------------
    (out_dir / "report.json").write_text(result.to_json(), encoding="utf-8")
    (out_dir / "report.html").write_text(_render_html(result),
                                         encoding="utf-8")
    return result


# ---------------------------------------------------------------------------
# HTML rendering (self-contained, no external assets)
# ---------------------------------------------------------------------------

def _fmt(v: Any, pct: bool = False, digits: int = 2) -> str:
    if v is None:
        return "no data"
    if isinstance(v, float):
        return (f"{100 * v:.1f}%" if pct else f"{v:.{digits}f}")
    return _html.escape(str(v))


def _table(headers: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "<p class='nodata'>no data</p>"
    head = "".join(f"<th>{_html.escape(h)}</th>" for h in headers)
    body = "".join(
        "<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return (f"<table><thead><tr>{head}</tr></thead>"
            f"<tbody>{body}</tbody></table>")


def _render_html(r: BenchmarkResult) -> str:
    h = r.header
    inv_rows = [[_fmt(s["name"]), _fmt(s["duration_s"], digits=1),
                 _fmt(",".join(map(str, s["nodes"]))),
                 _html.escape(json.dumps(s["labels"])),
                 _html.escape(json.dumps(s["refs"]))]
                for s in h.get("sessions", [])]

    falls = r.falls or {}
    fall_rows = [[_fmt(ft), _fmt(v["n"]), _fmt(v["tp"]),
                  _fmt(v["recall"], pct=True)]
                 for ft, v in falls.get("by_type", {}).items()] \
        if falls.get("available") else []
    conf_rows = [[_fmt(lb), _fmt(v["n"]), _fmt(v["fp"]),
                  _fmt(v["fp_rate"], pct=True)]
                 for lb, v in falls.get("confounders", {}).items()] \
        if falls.get("available") else []

    mae_rows = []
    for kind in ("breathing", "hr"):
        for sess, v in (r.vitals.get("mae", {}).get(kind, {}) or {}).items():
            mae_rows.append([_fmt(kind), _fmt(sess),
                             _fmt(v.get("n_windows")),
                             _fmt(v.get("mae")) + (" bpm"
                                                   if v.get("mae") is not None
                                                   else "")])

    cov_rows = [[_fmt(sess), _fmt(c.get("breathing_pct"), digits=1)
                 + ("%" if c.get("breathing_pct") is not None else ""),
                 _fmt(c.get("hr_pct"), digits=1)
                 + ("%" if c.get("hr_pct") is not None else "")]
                for sess, c in (r.coverage.get("per_session") or {}).items()]

    fail_rows = [[_fmt(f["kind"]), _fmt(f["session"]),
                  _fmt(float(f["t"]), digits=1) + " s", _fmt(f["label"]),
                  _fmt(f["pipeline_said"])]
                 for f in r.failures]

    notes = "".join(f"<li>{_html.escape(n)}</li>" for n in r.notes)
    summary_bits = []
    if falls.get("available"):
        summary_bits.append(f"fall recall {_fmt(falls.get('recall'), pct=True)}, "
                            f"precision {_fmt(falls.get('precision'), pct=True)}")
    agg = (r.vitals or {}).get("aggregate", {})
    if agg.get("breathing_mae") is not None:
        summary_bits.append(f"breathing MAE {_fmt(agg['breathing_mae'])} bpm")
    if agg.get("hr_mae") is not None:
        summary_bits.append(f"HR MAE {_fmt(agg['hr_mae'])} bpm")
    summary = " · ".join(summary_bits) if summary_bits else "no data"

    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Vigil benchmark report</title>
<style>
 body {{ font: 14px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif;
        color: #1c2530; margin: 32px auto; max-width: 960px; padding: 0 16px; }}
 h1 {{ font-size: 22px; }} h2 {{ font-size: 16px; margin-top: 28px;
      border-bottom: 1px solid #d8dee6; padding-bottom: 4px; }}
 table {{ border-collapse: collapse; margin: 10px 0; width: 100%; }}
 th, td {{ border: 1px solid #d8dee6; padding: 5px 9px; text-align: left;
          font-variant-numeric: tabular-nums; }}
 th {{ background: #f2f5f8; font-weight: 600; }}
 .meta {{ color: #5a6774; font-size: 12px; }}
 .meta code {{ background: #f2f5f8; padding: 1px 5px; border-radius: 4px; }}
 .nodata {{ color: #8a949e; font-style: italic; }}
 .summary {{ background: #f2f5f8; border-radius: 8px; padding: 10px 14px; }}
</style></head><body>
<h1>Vigil benchmark report</h1>
<p class="meta">
 generated {_fmt(h.get('generated_utc'))} ·
 git <code>{_fmt(h.get('git_hash'))}</code> ·
 engine v{_fmt(h.get('engine_version'))} ·
 classifier sha256 <code>{_fmt(h.get('classifier_sha256'))}</code>
</p>
<p class="summary">{summary}</p>

<h2>Session inventory</h2>
{_table(["session", "duration (s)", "nodes", "labels", "refs"], inv_rows)}

<h2>Fall detection — recall by fall type</h2>
{_table(["fall type", "labeled", "detected", "recall"], fall_rows)}
<p class="meta">overall recall {_fmt(falls.get('recall'), pct=True)} ·
precision {_fmt(falls.get('precision'), pct=True)} ·
false alarms {_fmt(falls.get('n_false_alarms'))}</p>

<h2>Confounder false-positive rate</h2>
{_table(["confounder", "occurrences", "false alarms", "FP rate"], conf_rows)}

<h2>Vitals accuracy (MAE vs reference)</h2>
{_table(["metric", "session", "qualifying windows", "MAE"], mae_rows)}

<h2>Coverage — qualifying-window %</h2>
{_table(["session", "breathing", "heart rate"], cov_rows)}
<p class="meta">mean qualifying-window coverage:
{_fmt(r.coverage.get('mean_qualifying_pct'), digits=1)}{'%' if r.coverage.get('mean_qualifying_pct') is not None else ''}</p>

<h2>Failure-case appendix</h2>
{_table(["kind", "session", "t", "label", "what the pipeline said"], fail_rows)
 if fail_rows else "<p class='nodata'>none — every labeled fall was caught and no false alarms fired" +
 ("" if falls.get('available') else " (fall pipeline not available: no data)") + "</p>"}

<h2>Notes</h2>
{('<ul>' + notes + '</ul>') if notes else "<p class='nodata'>none</p>"}
</body></html>
"""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python3 -m vigil.benchmark",
        description="Replay labeled .vigil sessions and write an honest "
                    "benchmark report")
    ap.add_argument("sessions", nargs="+", metavar="SESSION.vigil")
    ap.add_argument("--out", default="reports", metavar="DIR")
    ap.add_argument("--config", default=None, metavar="PATH")
    ap.add_argument("--classifier", default=None, metavar="PATH")
    args = ap.parse_args(argv)

    config = VigilConfig.load(args.config) if args.config else None
    result = run_benchmark(
        [Path(p) for p in args.sessions], Path(args.out), config=config,
        classifier_path=Path(args.classifier) if args.classifier else None)
    print(f"report: {Path(args.out) / 'report.html'}")
    falls = result.falls
    if falls.get("available"):
        rec = falls.get("recall")
        print(f"fall recall: {'no data' if rec is None else f'{rec:.1%}'}  "
              f"false alarms: {falls.get('n_false_alarms')}")
    else:
        print("fall pipeline: no data (Track C not available)")
    for n in result.notes:
        print(f"note: {n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
