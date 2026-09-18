"""F4 — Plan import: one internal floor-plan format, three sources.

`Plan` is the single presentation-layer plan format (see the F1 design doc
in mapping/registry.py: geometry is presentation-only; detection never
reads it). Three importers produce byte-identical schema:

- `from_roomplan_json(path_or_dict)` — Apple RoomPlan CapturedRoom /
  CapturedStructure JSON export. Walls carry `dimensions` [len, height,
  thickness] and a 4x4 column-major `transform` (ARKit convention, y-up);
  each wall is projected to the floor plane (x, z) as a segment
  centre ± (len/2)·(local x-axis), and segments are clustered into room
  polygons — by nearest `sections`/`rooms` centre when the newer exports
  include them, else one hull for the whole capture. USDZ parsing is
  **gated**: reading the .usdz scene needs USD tooling (usd-core); we accept
  the JSON companion export (`CapturedRoom` encoded via JSONEncoder), which
  RoomPlan apps produce alongside the USDZ.
- `from_walk_trace(points, room_breaks)` — ARKit walk-trace fallback: the
  phone's positions while the user walks each room's perimeter/area.
  Per-room concave-ish hull via grid rasterization + boundary-edge contour
  chaining (deliberately simple).
- `from_rects(rect_specs)` — the draw-your-rooms editor artifact:
  named axis-aligned rectangles.

Node pinning: `.pin_node(node_id, xy, room=None)` during the F2 walk tour
("tap when you're next to the node") drops a node marker on the plan.

Demo Mode consumption: `to_demo_layout()` returns the rooms dict shape that
`vigil/static/demo.html` reads from `demo.py`'s DemoFeed snapshot —
`{room: {"rect": [x, y, w, h], "nodes": [{"node_id", "pos"}]}}` in the demo's
0..100 coordinate space — so a real imported plan can replace DemoFeed's
auto grid layout without modifying demo.py (a feed/UI wires it in).

Operating envelope: pure geometry bookkeeping + JSON/SVG serialization,
stdlib + numpy only, no IO beyond the given paths.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

DEMO_UNITS = 100.0  # demo.py layout coordinate space (0..100)


@dataclass
class Plan:
    """Internal floor plan. rooms: [{name, polygon [[x,y],...]}];
    nodes: [{node_id, xy [x,y], room}]; walls: [[[x,y],[x,y]], ...];
    meta: {source, units, ...}."""

    rooms: list[dict] = field(default_factory=list)
    nodes: list[dict] = field(default_factory=list)
    walls: list = field(default_factory=list)
    meta: dict = field(default_factory=lambda: {"source": "unknown",
                                                "units": "meters"})

    # -- room/node bookkeeping ------------------------------------------------

    def room_names(self) -> list[str]:
        return [r["name"] for r in self.rooms]

    def polygon(self, room: str) -> list[list[float]]:
        for r in self.rooms:
            if r["name"] == room:
                return r["polygon"]
        raise KeyError(f"unknown room {room!r}")

    def pin_node(self, node_id: int, xy, room: str | None = None) -> dict:
        """Pin a node marker at plan coordinates (F2 tour: 'tap when you are
        next to the node'). Room defaults to the polygon containing xy."""
        x, y = float(xy[0]), float(xy[1])
        if room is None:
            room = ""
            for r in self.rooms:
                if _point_in_polygon(x, y, r["polygon"]):
                    room = r["name"]
                    break
        entry = {"node_id": int(node_id), "xy": [x, y], "room": room}
        self.nodes = [n for n in self.nodes if n["node_id"] != int(node_id)]
        self.nodes.append(entry)
        return entry

    # -- geometry helpers --------------------------------------------------------

    def bbox(self) -> tuple[float, float, float, float]:
        pts = [p for r in self.rooms for p in r["polygon"]]
        pts += [n["xy"] for n in self.nodes]
        pts += [p for w in self.walls for p in w]
        if not pts:
            return 0.0, 0.0, 1.0, 1.0
        a = np.asarray(pts, np.float64)
        x0, y0 = a.min(axis=0)
        x1, y1 = a.max(axis=0)
        return float(x0), float(y0), float(max(x1 - x0, 1e-9)), float(max(y1 - y0, 1e-9))

    # -- persistence -----------------------------------------------------------------

    def to_dict(self) -> dict:
        return {"version": 1, "rooms": self.rooms, "nodes": self.nodes,
                "walls": self.walls, "meta": self.meta}

    @classmethod
    def from_dict(cls, d: dict) -> "Plan":
        return cls(rooms=list(d.get("rooms", [])),
                   nodes=list(d.get("nodes", [])),
                   walls=list(d.get("walls", [])),
                   meta=dict(d.get("meta", {})))

    def save(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(self.to_dict(), indent=2) + "\n",
                     encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path) -> "Plan":
        return cls.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))

    # -- presentation ------------------------------------------------------------------

    def render_svg(self, size: int = 640) -> str:
        """Self-contained SVG string (no external assets/scripts)."""
        x0, y0, w, h = self.bbox()
        pad = 0.05 * max(w, h)
        vb = f"{x0 - pad:.3f} {y0 - pad:.3f} {w + 2 * pad:.3f} {h + 2 * pad:.3f}"
        fs = 0.035 * max(w, h)
        parts = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" '
            f'height="{int(size * (h + 2 * pad) / (w + 2 * pad))}" viewBox="{vb}">',
            f'<rect x="{x0 - pad:.3f}" y="{y0 - pad:.3f}" width="{w + 2 * pad:.3f}" '
            f'height="{h + 2 * pad:.3f}" fill="#0f1417"/>',
        ]
        palette = ["#2e4756", "#3d5a48", "#5a4a3d", "#4a3d5a", "#565656",
                   "#3d505a"]
        for i, r in enumerate(self.rooms):
            pts = " ".join(f"{p[0]:.3f},{p[1]:.3f}" for p in r["polygon"])
            cx = float(np.mean([p[0] for p in r["polygon"]]))
            cy = float(np.mean([p[1] for p in r["polygon"]]))
            parts.append(f'<polygon points="{pts}" fill="{palette[i % len(palette)]}" '
                         'stroke="#dfe7ea" stroke-width="0.5%" opacity="0.85"/>')
            parts.append(f'<text x="{cx:.3f}" y="{cy:.3f}" fill="#dfe7ea" '
                         f'font-size="{fs:.3f}" font-family="sans-serif" '
                         f'text-anchor="middle">{_esc(r["name"])}</text>')
        for wall in self.walls:
            (ax, ay), (bx, by) = wall
            parts.append(f'<line x1="{ax:.3f}" y1="{ay:.3f}" x2="{bx:.3f}" '
                         f'y2="{by:.3f}" stroke="#9fb2ba" stroke-width="0.4%"/>')
        for n in self.nodes:
            x, y = n["xy"]
            parts.append(f'<circle cx="{x:.3f}" cy="{y:.3f}" r="{0.012 * max(w, h):.3f}" '
                         'fill="#e8b64c" stroke="#0f1417" stroke-width="0.2%"/>')
            parts.append(f'<text x="{x:.3f}" y="{y - 0.02 * max(w, h):.3f}" '
                         f'fill="#e8b64c" font-size="{0.8 * fs:.3f}" '
                         f'font-family="sans-serif" text-anchor="middle">'
                         f'n{n["node_id"]}</text>')
        parts.append("</svg>")
        return "\n".join(parts)

    def to_demo_layout(self) -> dict:
        """Rooms/nodes dict in demo.py's snapshot shape (see module docstring):
        {room: {"rect": [x, y, w, h], "nodes": [{"node_id": id,
        "pos": [x, y]}]}} scaled into the demo's 0..100 space."""
        x0, y0, w, h = self.bbox()
        s = (DEMO_UNITS * 0.92) / max(w, h)

        def _tx(p):
            return [round((p[0] - x0) * s + 4.0, 2),
                    round((p[1] - y0) * s + 4.0, 2)]

        out: dict[str, dict] = {}
        for r in self.rooms:
            poly = np.asarray(r["polygon"], np.float64)
            lo = poly.min(axis=0)
            hi = poly.max(axis=0)
            (rx, ry), (rx1, ry1) = _tx(lo), _tx(hi)
            out[r["name"]] = {"rect": [rx, ry, round(rx1 - rx, 2),
                                       round(ry1 - ry, 2)],
                              "nodes": []}
        for n in self.nodes:
            room = n.get("room") or (self.rooms[0]["name"] if self.rooms
                                     else "room")
            out.setdefault(room, {"rect": [4.0, 4.0, 92.0, 92.0], "nodes": []})
            out[room]["nodes"].append({"node_id": int(n["node_id"]),
                                       "pos": _tx(n["xy"])})
        return out


# ---------------------------------------------------------------------------
# Importer (a): Apple RoomPlan JSON companion export
# ---------------------------------------------------------------------------

def from_roomplan_json(path_or_dict) -> Plan:
    """Parse a RoomPlan CapturedRoom/CapturedStructure JSON export.

    See module docstring for conventions (4x4 column-major transforms, y-up,
    floor plane = x/z). USDZ itself is gated on USD tooling — pass the JSON
    companion export."""
    if isinstance(path_or_dict, (str, Path)):
        data = json.loads(Path(path_or_dict).read_text(encoding="utf-8"))
    else:
        data = dict(path_or_dict)
    # CapturedStructure nests rooms; CapturedRoom has walls at top level
    walls_raw = list(data.get("walls", []))
    sections = list(data.get("sections", []) or data.get("rooms", []) or [])
    if not walls_raw and "rooms" in data and isinstance(data["rooms"], list):
        for rm in data["rooms"]:  # CapturedStructure: rooms carry walls
            walls_raw.extend(rm.get("walls", []))
    segments = [_wall_segment(w) for w in walls_raw]
    segments = [s for s in segments if s is not None]
    plan = Plan(meta={"source": "roomplan-json", "units": "meters"})
    plan.walls = [[[float(a[0]), float(a[1])], [float(b[0]), float(b[1])]]
                  for a, b in segments]
    if sections and segments:
        centres = []
        names = []
        for i, sec in enumerate(sections):
            c = sec.get("center") or sec.get("centre") or [0, 0, 0]
            if isinstance(c, dict):
                c = [c.get("x", 0.0), c.get("y", 0.0), c.get("z", 0.0)]
            centres.append((float(c[0]), float(c[-1])))  # (x, z)
            names.append(str(sec.get("label") or sec.get("name")
                             or f"room{i + 1}"))
        buckets: dict[int, list] = {i: [] for i in range(len(centres))}
        for a, b in segments:
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            j = int(np.argmin([np.hypot(mid[0] - cx, mid[1] - cy)
                               for cx, cy in centres]))
            buckets[j].extend([a, b])
        for i, name in enumerate(names):
            if buckets[i]:
                plan.rooms.append({"name": name,
                                   "polygon": _convex_hull(buckets[i])})
    elif segments:
        pts = [p for seg in segments for p in seg]
        plan.rooms.append({"name": "captured-room",
                           "polygon": _convex_hull(pts)})
    return plan


def _wall_segment(wall: dict):
    """One RoomPlan wall -> floor-plane segment ((x0,z0),(x1,z1)) or None."""
    dims = wall.get("dimensions")
    tf = wall.get("transform")
    if not dims or not tf or len(tf) != 16:
        return None
    length = float(dims[0])
    # column-major simd_float4x4: column 0 = local x axis, column 3 = origin
    ax, az = float(tf[0]), float(tf[2])
    cx, cz = float(tf[12]), float(tf[14])
    norm = float(np.hypot(ax, az))
    if norm < 1e-12:
        return None
    ax, az = ax / norm, az / norm
    half = 0.5 * length
    return ((cx - half * ax, cz - half * az), (cx + half * ax, cz + half * az))


# ---------------------------------------------------------------------------
# Importer (b): ARKit walk-trace outline
# ---------------------------------------------------------------------------

def from_walk_trace(points, room_breaks, cell: float | None = None) -> Plan:
    """Walk-trace fallback: `points` is the phone's [n, 2] floor-plane track;
    `room_breaks` is [(start_index, room_name), ...] (segments run to the
    next break). Each room polygon is the concave-ish hull of its segment:
    grid-rasterize the points, then chain the boundary edges of the occupied
    cells into a contour (keep simple)."""
    pts = np.asarray(points, np.float64)
    if pts.ndim != 2 or pts.shape[1] < 2:
        raise ValueError("points must be [n, 2]")
    breaks = sorted((int(i), str(name)) for i, name in room_breaks)
    plan = Plan(meta={"source": "walk-trace", "units": "meters"})
    if cell is None:
        span = float((pts.max(axis=0) - pts.min(axis=0)).max())
        cell = max(span / 24.0, 1e-6)
    for k, (i0, name) in enumerate(breaks):
        i1 = breaks[k + 1][0] if k + 1 < len(breaks) else pts.shape[0]
        seg = pts[i0:i1]
        if seg.shape[0] < 3:
            continue
        plan.rooms.append({"name": name,
                           "polygon": _raster_contour(seg, cell)})
    return plan


def _raster_contour(pts: np.ndarray, cell: float) -> list[list[float]]:
    """Occupied-cell union boundary as a closed CCW polygon."""
    ij = np.floor(pts[:, :2] / cell).astype(int)
    occupied = {(int(i), int(j)) for i, j in ij}
    # 1-cell closing pass so a sparse walking track forms a solid blob
    grown = set(occupied)
    for (i, j) in occupied:
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                grown.add((i + di, j + dj))
    occupied = grown
    # directed boundary edges, interior on the left -> CCW outer loop
    edges: dict[tuple, tuple] = {}
    for (i, j) in occupied:
        x0, y0, x1, y1 = i, j, i + 1, j + 1
        if (i, j - 1) not in occupied:
            edges[(x0, y0)] = (x1, y0)
        if (i + 1, j) not in occupied:
            edges[(x1, y0)] = (x1, y1)
        if (i, j + 1) not in occupied:
            edges[(x1, y1)] = (x0, y1)
        if (i - 1, j) not in occupied:
            edges[(x0, y1)] = (x0, y0)
    loops = []
    remaining = dict(edges)
    while remaining:
        start = next(iter(remaining))
        loop = [start]
        cur = remaining.pop(start)
        while cur != start and cur in remaining:
            loop.append(cur)
            cur = remaining.pop(cur)
        loops.append(loop)
    loop = max(loops, key=len)
    # drop collinear grid points, scale back to plan units
    poly = []
    n = len(loop)
    for idx in range(n):
        a, b, c = loop[idx - 1], loop[idx], loop[(idx + 1) % n]
        if (b[0] - a[0]) * (c[1] - b[1]) != (b[1] - a[1]) * (c[0] - b[0]):
            poly.append([b[0] * cell, b[1] * cell])
    return poly if len(poly) >= 3 else [[p[0] * cell, p[1] * cell]
                                        for p in loop]


# ---------------------------------------------------------------------------
# Importer (c): draw-your-rooms rectangles
# ---------------------------------------------------------------------------

def from_rects(rect_specs) -> Plan:
    """Editor artifact: [{"name": str, "rect": [x, y, w, h]}, ...] (or a
    {name: rect} mapping)."""
    if isinstance(rect_specs, dict):
        rect_specs = [{"name": k, "rect": v} for k, v in rect_specs.items()]
    plan = Plan(meta={"source": "rect-editor", "units": "meters"})
    for spec in rect_specs:
        x, y, w, h = (float(v) for v in spec["rect"])
        plan.rooms.append({"name": str(spec["name"]),
                           "polygon": [[x, y], [x + w, y], [x + w, y + h],
                                       [x, y + h]]})
    return plan


# ---------------------------------------------------------------------------
# small geometry helpers
# ---------------------------------------------------------------------------

def _convex_hull(points) -> list[list[float]]:
    """Andrew monotone chain; returns CCW hull as [[x, y], ...]."""
    pts = sorted({(round(float(p[0]), 9), round(float(p[1]), 9))
                  for p in points})
    if len(pts) <= 2:
        return [[x, y] for x, y in pts]

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return [[x, y] for x, y in lower[:-1] + upper[:-1]]


def _point_in_polygon(x: float, y: float, poly) -> bool:
    inside = False
    n = len(poly)
    for i in range(n):
        (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % n]
        if (y0 > y) != (y1 > y):
            xi = x0 + (y - y0) / (y1 - y0) * (x1 - x0)
            if x < xi:
                inside = not inside
    return inside


def _esc(s: str) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))
