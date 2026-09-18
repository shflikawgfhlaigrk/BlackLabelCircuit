"""M2 — ADL rollup: honest daily activities-of-daily-living report.

Operating envelope: aggregates one day of EventGraph records (transitions,
motion, steam, door) into an ADLReport. Everything is computed from derived
events; nothing is re-derived from signals. Honesty rules: every claim in
``render_text()`` carries the event count it rests on; a day with no
supporting events says "no data" — nothing is ever fabricated; the
confidence of underlying events propagates (median confidence per claim).

Conventions: ``date_t0`` is local midnight of the reported day; night is
22:00-06:00 relative to it. Occupancy is derived from transition events
(the person is in a room from the transition into it until the next
transition out); a 15-minute merge gap absorbs brief excursions (a night
bathroom trip does not split the sleep window). Gait trend needs a
multi-day graph — with fewer than 2 days of transition data it returns
None with an explicit reason.

Privacy by design: the ledger stores derived events only (room, person-tag,
timestamps, confidence) — zero raw CSI, zero images by construction;
household members must be informed; person-tags are opt-in labels supplied
by the deployment, not covert biometric identification.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

DAY_S = 86400.0
NIGHT_START_H = 22.0
NIGHT_END_H = 6.0

DEFAULT_ROLES = {"bed": "bed", "bath": "bath", "kitchen": "kitchen",
                 "living": "living"}


@dataclass
class ADLReport:
    """One day of ADL findings; every field carries its event count and the
    (median) confidence of the events behind it. None/'no data' where the
    graph has nothing — never fabricated.

    Privacy by design: derived events only (room, person-tag, timestamps,
    confidence) — zero raw CSI, zero images by construction; household
    members must be informed; person-tags are opt-in deployment labels, not
    covert biometric identification.
    """

    date_t0: float = 0.0
    date_t1: float = 0.0
    person: str | None = None
    n_events: int = 0
    sleep_window: dict | None = None       # {t0,t1,duration_s,restlessness,n_events,confidence}
    meals_inferred: dict = field(default_factory=dict)  # {count,episodes,n_events,confidence}
    hygiene: dict = field(default_factory=dict)         # {showers,events,confidence}
    bathroom_frequency: dict = field(default_factory=dict)  # {total,day,night,n_events}
    gait_speed_trend: dict | None = None   # {today_median_s,trailing_median_s,trend_pct,n_transitions,n_days}
    gait_speed_reason: str | None = None
    time_in_chair: dict | None = None      # {longest_s,total_s,episodes,n_events}

    # -- rendering -----------------------------------------------------------

    def _hhmm(self, ts: float) -> str:
        h = ((ts - self.date_t0) / 3600.0) % 24.0
        m = int(round((h % 1.0) * 60.0))
        hh = int(h) % 24
        if m == 60:
            hh, m = (hh + 1) % 24, 0
        return f"{hh:02d}:{m:02d}"

    def render_text(self) -> str:
        """Plain-English letter paragraph; every claim carries its event
        count, missing data says 'no data', nothing is fabricated."""
        who = self.person or "the household"
        lines = [f"Daily activity letter for {who} "
                 f"({self.n_events} ledger events recorded)."]
        s = self.sleep_window
        if s is None:
            lines.append("Sleep: no data (no bedroom occupancy recorded).")
        else:
            lines.append(
                f"Sleep: in the bedroom from {self._hhmm(s['t0'])} to "
                f"{self._hhmm(s['t1'])} ({s['duration_s'] / 3600.0:.1f} h), "
                f"with {s['restlessness']} restless bursts "
                f"(from {s['n_events']} events, median confidence "
                f"{s['confidence']:.2f}).")
        m = self.meals_inferred
        if not m or m.get("count", 0) == 0:
            lines.append("Meals: no data (no kitchen activity recorded).")
        else:
            with_steam = sum(1 for ep in m["episodes"] if ep.get("steam"))
            lines.append(
                f"Meals: {m['count']} inferred kitchen sessions "
                f"({with_steam} with cooking steam; {m['n_events']} kitchen "
                f"events, median confidence {m['confidence']:.2f}).")
        h = self.hygiene
        if not h or h.get("showers", 0) == 0:
            lines.append("Hygiene: no data (no shower steam events).")
        else:
            lines.append(
                f"Hygiene: {h['showers']} shower detected "
                f"(median confidence {h['confidence']:.2f})."
                if h["showers"] == 1 else
                f"Hygiene: {h['showers']} showers detected "
                f"(median confidence {h['confidence']:.2f}).")
        b = self.bathroom_frequency
        if not b or b.get("total", 0) == 0:
            lines.append("Bathroom: no data (no bathroom entries recorded).")
        else:
            lines.append(
                f"Bathroom: {b['total']} visits ({b['day']} daytime, "
                f"{b['night']} overnight; from {b['n_events']} transition "
                "events).")
        g = self.gait_speed_trend
        if g is None:
            lines.append(f"Gait: no data — {self.gait_speed_reason}.")
        else:
            lines.append(
                f"Gait: median room-transition time {g['today_median_s']:.1f} s "
                f"vs trailing median {g['trailing_median_s']:.1f} s "
                f"({g['trend_pct']:+.0f}%; {g['n_transitions']} transitions "
                f"over {g['n_days']} days).")
        c = self.time_in_chair
        if c is None:
            lines.append("Sitting: no data (no living-room occupancy recorded).")
        else:
            lines.append(
                f"Sitting: longest continuous living-room stay "
                f"{c['longest_s'] / 3600.0:.1f} h ({c['episodes']} stays, "
                f"{c['n_events']} events).")
        return "\n".join(lines)


class DailyRollup:
    """Builds an ADLReport for one day from an EventGraph.

    ``rooms`` maps roles {bed, bath, kitchen, living} to actual room names;
    by default the first graph room containing the role substring is used.

    Privacy by design: consumes derived events only (room, person-tag,
    timestamps, confidence) — zero raw CSI, zero images by construction;
    household members must be informed; person-tags are opt-in deployment
    labels, not covert biometric identification.
    """

    def __init__(self, graph, *, person: str | None = None,
                 rooms: dict[str, str] | None = None,
                 merge_gap_s: float = 900.0, meal_min_s: float = 300.0,
                 meal_cluster_gap_s: float = 2700.0,
                 lookback_s: float = 12 * 3600.0) -> None:
        self.graph = graph
        self.person = person
        self.merge_gap_s = float(merge_gap_s)
        self.meal_min_s = float(meal_min_s)
        self.meal_cluster_gap_s = float(meal_cluster_gap_s)
        self.lookback_s = float(lookback_s)
        self._roles = dict(rooms) if rooms else None

    def _room_for(self, role: str) -> str | None:
        if self._roles and role in self._roles:
            return self._roles[role]
        needle = DEFAULT_ROLES[role]
        for r in self.graph.rooms():
            if needle in r.lower():
                return r
        return None

    # -- build ----------------------------------------------------------------

    def build(self, date_t0: float, date_t1: float | None = None) -> ADLReport:
        date_t1 = date_t0 + DAY_S if date_t1 is None else float(date_t1)
        rep = ADLReport(date_t0=date_t0, date_t1=date_t1, person=self.person)
        day_events = self.graph.query(date_t0, date_t1, person=self.person)
        rep.n_events = len(day_events)
        # occupancy from transitions, with lookback so the previous evening's
        # bedroom entry (sleep 23:00 -> 07:00) is captured
        trans = self.graph.query(date_t0 - self.lookback_s, date_t1,
                                 person=self.person, kind="transition")
        occ = _occupancy(trans, date_t1)
        rep.sleep_window = self._sleep(occ, date_t0, date_t1)
        rep.meals_inferred = self._meals(occ, date_t0, date_t1)
        rep.hygiene = self._hygiene(date_t0, date_t1)
        rep.bathroom_frequency = self._bathroom(trans, date_t0, date_t1)
        rep.gait_speed_trend, rep.gait_speed_reason = self._gait(date_t0, date_t1)
        rep.time_in_chair = self._chair(occ, date_t0, date_t1)
        return rep

    # -- sections ---------------------------------------------------------------

    def _sleep(self, occ, date_t0, date_t1) -> dict | None:
        bed = self._room_for("bed")
        if bed is None:
            return None
        eps = _merge_episodes([iv for iv in occ if iv[0] == bed], self.merge_gap_s)
        # episodes overlapping the reported day (incl. lookback for the
        # previous-evening bedtime)
        eps = [e for e in eps if e[1] > date_t0 - self.lookback_s and e[0] < date_t1]
        if not eps:
            return None
        t0, t1 = max(eps, key=lambda e: e[1] - e[0])
        bursts = self.graph.query(t0, t1, person=self.person, room=bed,
                                  kind="motion")
        n_ev = len(bursts) + sum(1 for tr in occ if tr[0] == bed)
        confs = [b["confidence"] for b in bursts] or [1.0]
        return {"t0": t0, "t1": t1, "duration_s": t1 - t0,
                "restlessness": len(bursts), "n_events": n_ev,
                "confidence": float(np.median(confs))}

    def _meals(self, occ, date_t0, date_t1) -> dict:
        kitchen = self._room_for("kitchen")
        if kitchen is None:
            return {"count": 0, "episodes": [], "n_events": 0, "confidence": 0.0}
        eps = [e for e in _merge_episodes(
            [iv for iv in occ if iv[0] == kitchen], self.merge_gap_s)
            if e[1] > date_t0 and e[0] < date_t1]
        steams = self.graph.query(date_t0, date_t1, room=kitchen, kind="steam")
        kitchen_events = self.graph.query(date_t0, date_t1, person=self.person,
                                          room=kitchen)
        qualifying = []
        for t0, t1 in eps:
            has_steam = any(t0 - self.merge_gap_s <= s["ts"] <= t1 + self.merge_gap_s
                            for s in steams)
            if has_steam or (t1 - t0) >= self.meal_min_s:
                qualifying.append({"t0": t0, "t1": t1, "steam": has_steam})
        # cluster episodes separated by less than the cluster gap into one meal
        meals: list[dict] = []
        for ep in qualifying:
            if meals and ep["t0"] - meals[-1]["t1"] < self.meal_cluster_gap_s:
                meals[-1]["t1"] = ep["t1"]
                meals[-1]["steam"] = meals[-1]["steam"] or ep["steam"]
            else:
                meals.append(dict(ep))
        confs = [e["confidence"] for e in kitchen_events] or [0.0]
        return {"count": len(meals), "episodes": meals,
                "n_events": len(kitchen_events),
                "confidence": float(np.median(confs))}

    def _hygiene(self, date_t0, date_t1) -> dict:
        bath = self._room_for("bath")
        if bath is None:
            return {"showers": 0, "events": [], "confidence": 0.0}
        steams = self.graph.query(date_t0, date_t1, room=bath, kind="steam")
        confs = [s["confidence"] for s in steams] or [0.0]
        return {"showers": len(steams),
                "events": [{"ts": s["ts"], "confidence": s["confidence"],
                            "t1": s["attrs"].get("t1")} for s in steams],
                "confidence": float(np.median(confs))}

    def _bathroom(self, trans, date_t0, date_t1) -> dict:
        bath = self._room_for("bath")
        if bath is None:
            return {"total": 0, "day": 0, "night": 0, "n_events": 0}
        visits = [tr for tr in trans
                  if tr["room"] == bath and date_t0 <= tr["ts"] < date_t1]
        night = sum(1 for tr in visits if _is_night(tr["ts"], date_t0))
        return {"total": len(visits), "day": len(visits) - night,
                "night": night, "n_events": len(visits)}

    def _gait(self, date_t0, date_t1):
        """Median transition traversal time today vs trailing 7-day median.
        Needs a multi-day graph: with <2 days of transition data returns
        (None, reason) — never a fabricated trend."""
        hist_t0 = date_t0 - 7 * DAY_S
        trans = self.graph.query(hist_t0, date_t1, person=self.person,
                                 kind="transition")
        by_day: dict[int, list[float]] = {}
        for tr in trans:
            tv = tr["attrs"].get("traversal_s")
            if tv is None:
                continue
            by_day.setdefault(int((tr["ts"] - hist_t0) // DAY_S), []).append(float(tv))
        today_key = int((date_t0 - hist_t0) // DAY_S)
        # a calendar day only counts as data if it has >=3 traversals (a
        # single late-evening transition is not a gait sample of that day)
        data_days = {k for k, vs in by_day.items() if len(vs) >= 3}
        today = [v for k, vs in by_day.items() if k >= today_key for v in vs]
        trailing = [v for k in sorted(data_days) if k < today_key
                    for v in by_day[k]]
        n_days = len(data_days)
        if n_days < 2 or not today or not trailing:
            return None, (f"insufficient history: {n_days} day(s) of "
                          "transition data (need >= 2)")
        tm, hm = float(np.median(today)), float(np.median(trailing))
        return ({"today_median_s": tm, "trailing_median_s": hm,
                 "trend_pct": (tm - hm) / hm * 100.0 if hm > 0 else 0.0,
                 "n_transitions": len(today) + len(trailing),
                 "n_days": n_days}, None)

    def _chair(self, occ, date_t0, date_t1) -> dict | None:
        living = self._room_for("living")
        if living is None:
            return None
        eps = [(max(t0, date_t0), min(t1, date_t1))
               for r, t0, t1 in occ
               if r == living and t1 > date_t0 and t0 < date_t1]
        if not eps:
            return None
        longest = max(t1 - t0 for t0, t1 in eps)
        n_motion = len(self.graph.query(date_t0, date_t1, person=self.person,
                                        room=living, kind="motion"))
        return {"longest_s": longest,
                "total_s": sum(t1 - t0 for t0, t1 in eps),
                "episodes": len(eps), "n_events": len(eps) + n_motion}


# -- occupancy helpers ---------------------------------------------------------


def _occupancy(transitions: list[dict], t_end: float) -> list[tuple[str, float, float]]:
    """(room, t0, t1) intervals: in a room from the transition into it until
    the next transition (last interval clipped at t_end). State before the
    first transition is unknown and reported as nothing (no data)."""
    out: list[tuple[str, float, float]] = []
    trs = [t for t in transitions if t.get("room")]
    for a, b in zip(trs, trs[1:]):
        if b["ts"] > a["ts"]:
            out.append((a["room"], a["ts"], b["ts"]))
    if trs and t_end > trs[-1]["ts"]:
        out.append((trs[-1]["room"], trs[-1]["ts"], t_end))
    return out


def _merge_episodes(intervals: list[tuple[str, float, float]],
                    gap_s: float) -> list[tuple[float, float]]:
    """Merge same-room intervals separated by gaps <= gap_s (brief
    excursions, e.g. a night bathroom trip, do not split the episode)."""
    eps: list[list[float]] = []
    for _, t0, t1 in sorted(intervals, key=lambda iv: iv[1]):
        if eps and t0 - eps[-1][1] <= gap_s:
            eps[-1][1] = max(eps[-1][1], t1)
        else:
            eps.append([t0, t1])
    return [(a, b) for a, b in eps]


def _is_night(ts: float, date_t0: float) -> bool:
    h = ((ts - date_t0) / 3600.0) % 24.0
    return h < NIGHT_END_H or h >= NIGHT_START_H
