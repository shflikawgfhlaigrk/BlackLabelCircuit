"""M4.4 — RF site survey: walk-the-wall attenuation heatmap + anomaly triage.

TRIAGE TOOL, EXPLICITLY: the output says "point the inspector (moisture
meter / thermal camera / borescope) HERE" — it is NOT an inspection
replacement, NOT a moisture measurement, and carries no claim about what is
inside the wall. Localized excess RF attenuation is *consistent with*
moisture or unexpected voids/metal; only a physical inspection can confirm.

Input: an ordered walk of measurement points from a fixed TX/RX pair —
each point = {"xy": (x, y) meters, "window": [t,52] CSI amplitude} (or
precomputed summary stats). On hardware the walk comes from vigilctl + the
wizard; here the points are injectable, so tests and replays are exact.

Per-point features:
- mean_amp: mean CSI amplitude (path-attenuation proxy; raw amp units,
  uncalibrated — relative comparisons only).
- variance: mean temporal variance across subcarriers.
- fading_depth: (max - min) / mean of the per-subcarrier mean amplitudes —
  frequency-selective fading across the 52 subcarriers (multipath richness;
  wet material deepens the notches).

`SurveyGrid.fit(points)`:
- attenuation per point = (max point mean_amp) - mean_amp (relative dB-ish
  in raw units),
- inverse-distance-weighted (IDW) interpolation onto a regular grid (pure
  numpy, deterministic),
- anomaly flags where a point's leave-one-out IDW residual deviates from
  the walk's trend by more than max(k * 1.4826 * MAD, min_delta_amp)
  (moisture / void candidates; direction reported).

Export: `to_svg()` — a single self-contained SVG string (heatmap cells,
measurement points, anomaly markers, legend) and `to_json()`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

import numpy as np


@dataclass
class SurveyPoint:
    xy: tuple[float, float]
    mean_amp: float
    variance: float
    fading_depth: float
    attenuation: float = 0.0
    residual: float = 0.0
    anomaly: bool = False


def point_features(window: np.ndarray) -> tuple[float, float, float]:
    """(mean_amp, variance, fading_depth) for one measurement window."""
    w = np.asarray(window, np.float64)
    sub_mean = w.mean(axis=0)
    mean_amp = float(sub_mean.mean())
    variance = float(w.var(axis=0).mean())
    fading_depth = float((sub_mean.max() - sub_mean.min()) / max(mean_amp, 1e-9))
    return mean_amp, variance, fading_depth


def _idw(xys: np.ndarray, vals: np.ndarray, q: np.ndarray, p: float) -> float:
    d2 = ((xys - q) ** 2).sum(axis=1)
    w = 1.0 / np.maximum(d2, 1e-12) ** (p / 2.0)
    return float((w * vals).sum() / w.sum())


class SurveyGrid:
    """IDW attenuation heatmap + MAD anomaly triage (see module docstring)."""

    def __init__(self, resolution: int = 32, idw_power: float = 2.0,
                 k_mad: float = 4.0, min_delta_amp: float = 5.0) -> None:
        self.resolution = int(resolution)
        self.idw_power = float(idw_power)
        self.k_mad = float(k_mad)
        self.min_delta_amp = float(min_delta_amp)
        self.points: list[SurveyPoint] = []
        self.anomalies: list[dict] = []
        self.grid: np.ndarray | None = None   # [res, res] attenuation
        self.extent: tuple[float, float, float, float] | None = None

    # -- fit -----------------------------------------------------------------

    def fit(self, points: list) -> "SurveyGrid":
        """`points`: dicts with "xy" and either "window" [t,52] or the
        summary stats (mean_amp, variance, fading_depth); or SurveyPoint."""
        pts: list[SurveyPoint] = []
        for p in points:
            if isinstance(p, SurveyPoint):
                pts.append(SurveyPoint(tuple(p.xy), p.mean_amp, p.variance,
                                       p.fading_depth))
                continue
            xy = (float(p["xy"][0]), float(p["xy"][1]))
            if "window" in p and p["window"] is not None:
                m, v, f = point_features(p["window"])
            else:
                m, v, f = float(p["mean_amp"]), float(p.get("variance", 0.0)), \
                    float(p.get("fading_depth", 0.0))
            pts.append(SurveyPoint(xy, m, v, f))
        if len(pts) < 3:
            raise ValueError("survey needs at least 3 measurement points")
        ref = max(p.mean_amp for p in pts)
        for p in pts:
            p.attenuation = ref - p.mean_amp
        xys = np.asarray([p.xy for p in pts], np.float64)
        atten = np.asarray([p.attenuation for p in pts], np.float64)

        # leave-one-out residuals vs the walk trend
        resid = np.zeros(len(pts))
        for i in range(len(pts)):
            keep = np.arange(len(pts)) != i
            resid[i] = atten[i] - _idw(xys[keep], atten[keep], xys[i],
                                       self.idw_power)
        med = float(np.median(resid))
        mad = float(np.median(np.abs(resid - med)))
        thresh = max(self.k_mad * 1.4826 * mad, self.min_delta_amp)
        self.anomalies = []
        for i, p in enumerate(pts):
            p.residual = float(resid[i])
            if abs(resid[i] - med) > thresh:
                p.anomaly = True
                self.anomalies.append({
                    "index": i, "xy": p.xy,
                    "attenuation": round(p.attenuation, 3),
                    "residual": round(p.residual, 3),
                    "fading_depth": round(p.fading_depth, 4),
                    "direction": ("high-attenuation" if resid[i] - med > 0
                                  else "low-attenuation"),
                })
        self.anomalies.sort(key=lambda a: -abs(a["residual"]))
        self.points = pts

        # interpolated heatmap grid
        x0, x1 = float(xys[:, 0].min()), float(xys[:, 0].max())
        y0, y1 = float(xys[:, 1].min()), float(xys[:, 1].max())
        self.extent = (x0, x1, y0, y1)
        res = self.resolution
        gx = np.linspace(x0, x1, res)
        gy = np.linspace(y0, y1, res)
        grid = np.zeros((res, res))
        for j, y in enumerate(gy):
            for i, x in enumerate(gx):
                grid[j, i] = _idw(xys, atten, np.array([x, y]), self.idw_power)
        self.grid = grid
        return self

    # -- export ----------------------------------------------------------------

    def to_json(self) -> str:
        """Self-contained JSON export (deterministic; rounded floats)."""
        if self.grid is None:
            raise ValueError("call fit() first")
        return json.dumps({
            "triage_only": True,
            "note": "point the inspector here — not an inspection replacement",
            "resolution": self.resolution,
            "extent": [round(v, 4) for v in self.extent],
            "points": [{
                "xy": [round(p.xy[0], 4), round(p.xy[1], 4)],
                "mean_amp": round(p.mean_amp, 3),
                "variance": round(p.variance, 4),
                "fading_depth": round(p.fading_depth, 4),
                "attenuation": round(p.attenuation, 3),
                "residual": round(p.residual, 3),
                "anomaly": bool(p.anomaly),
            } for p in self.points],
            "anomalies": [dict(a, xy=[round(a["xy"][0], 4), round(a["xy"][1], 4)])
                          for a in self.anomalies],
            "grid": [[round(float(v), 3) for v in row] for row in self.grid],
        }, separators=(",", ":"))

    def to_svg(self, width: int = 520) -> str:
        """Self-contained SVG heatmap string (grid cells + points + anomaly
        markers + legend). Deterministic: fixed float formatting."""
        if self.grid is None:
            raise ValueError("call fit() first")
        res = self.resolution
        x0, x1, y0, y1 = self.extent
        margin = 34
        span_x = max(x1 - x0, 1e-9)
        span_y = max(y1 - y0, 1e-9)
        plot_w = width - 2 * margin
        plot_h = plot_w * span_y / span_x
        height = int(plot_h + 2 * margin + 22)
        cw, ch = plot_w / res, plot_h / res
        lo, hi = float(self.grid.min()), float(self.grid.max())
        rng = max(hi - lo, 1e-9)

        def color(v: float) -> str:
            t = (v - lo) / rng
            r = int(round(247 + (8 - 247) * t))
            g = int(round(251 + (48 - 251) * t))
            b = int(round(255 + (107 - 255) * t))
            return f"#{r:02x}{g:02x}{b:02x}"

        def px(x: float) -> float:
            return margin + (x - x0) / span_x * plot_w

        def py(y: float) -> float:
            return margin + (y - y0) / span_y * plot_h

        parts = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
            f'height="{height}" viewBox="0 0 {width} {height}">',
            f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
            f'<text x="{margin}" y="18" font-family="monospace" font-size="12">'
            f'RF site survey — attenuation heatmap (triage only)</text>',
        ]
        for j in range(res):
            for i in range(res):
                cx = margin + i * cw
                cy = margin + j * ch
                parts.append(
                    f'<rect class="cell" x="{cx:.2f}" y="{cy:.2f}" '
                    f'width="{cw + 0.5:.2f}" height="{ch + 0.5:.2f}" '
                    f'fill="{color(float(self.grid[j, i]))}"/>')
        for p in self.points:
            parts.append(
                f'<circle class="pt" cx="{px(p.xy[0]):.2f}" cy="{py(p.xy[1]):.2f}" '
                f'r="3" fill="#222222" stroke="#ffffff" stroke-width="1"/>')
        for a in self.anomalies:
            parts.append(
                f'<circle class="anomaly" cx="{px(a["xy"][0]):.2f}" '
                f'cy="{py(a["xy"][1]):.2f}" r="9" fill="none" '
                f'stroke="#d7301f" stroke-width="2.5"/>')
        parts.append(
            f'<text x="{margin}" y="{height - 8}" font-family="monospace" '
            f'font-size="11">attenuation {lo:.1f}..{hi:.1f} (raw amp units); '
            f'{len(self.anomalies)} anomaly candidate(s) circled — '
            f'inspect physically</text>')
        parts.append("</svg>")
        return "".join(parts)
