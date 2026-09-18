"""
Homefront predictive sensing — the eldercare wedge (v0).

This is the layer that turns Homefront's raw sensing (presence + motion + range,
already produced honestly by home_engine.py) into a *learned baseline of normal*
and the *semantic anomalies* that depart from it. It is the defensible moat: Apple
Home / SmartThings can switch a light on a schedule; only a radar that has learned
how a specific resident normally lives can say "they got out of bed at 3am" or
"they haven't moved all morning."

Two anomalies in v0:

    bed-exit            during the resident's normal RESTING window (baseline =
                        present + near-zero motion), occupancy transitions out of a
                        sustained at-rest state — got out of bed / left the room.
                        The night-wandering / fall-risk cue.

    inactivity-anomaly  during a window where the resident is normally ACTIVE
                        (baseline = present + meaningful motion), motion stays far
                        below baseline for an abnormally long, sustained span — the
                        "hasn't moved when they always do" incapacitation cue.

HONESTY (CHARTER 5.1 zero-fabrication, 5.2 ship-no-data):
  * No baseline yet            -> state is None, status "learning_baseline". NEVER
                                  an anomaly. The model ships EMPTY and learns only
                                  from the buyer's own room over real nights.
  * A state is emitted ONLY when a learned baseline exists for THIS time-of-day AND
    the live signal crosses an explicit, sustained deviation gate. Sub-baseline,
    ambiguous, or single-frame blips -> None.
  * Nothing here fabricates a sensed value. It only *classifies* frames the sensing
    engine already produced (or the honest nulls it already emits).

Pure module: no I/O, no clock of its own, no numpy. Time is always passed in as an
epoch float on each observation, so the same code runs live (real wall-clock nights)
and under pytest (synthetic multi-night traces) with identical behaviour. Persistence
(to the buyer's local store) is the caller's job via to_dict()/from_dict().
"""

import math

# --- buckets: a coarse time-of-day index so "what is normal at 3am" is learnable.
BUCKETS_PER_DAY = 24                      # hourly buckets
SECONDS_PER_BUCKET = 86400 // BUCKETS_PER_DAY

# --- baseline readiness gates ---
DEFAULT_MIN_NIGHTS = 3                    # distinct calendar days before a baseline is usable
DEFAULT_MIN_BUCKET_SAMPLES = 20          # a bucket needs this many frames before it's "learned"
DEFAULT_MIN_BUCKET_DAYS = 2              # ...and must span this many DISTINCT days; one
                                         # night is never a baseline (kills thin-baseline
                                         # false anomalies — §5.1 accuracy-or-nothing)

# --- what counts as "resting" vs "active" in the LEARNED baseline of a bucket ---
REST_MOTION_MAX = 0.06                    # baseline mean motion below this => a resting bucket
ACTIVE_MOTION_MIN = 0.12                 # baseline mean motion above this => an active bucket
PRESENCE_MIN = 0.70                      # bucket must normally be occupied to judge it

# --- live deviation gates ---
REST_ESTABLISH_SEC = 120.0               # must be continuously at-rest this long to "be in bed"
DEPART_SUSTAIN_SEC = 12.0                # departure must persist this long to count (no blips)
DEPART_MOTION_K = 4.0                    # motion > rest_mean + K*std also counts as departure
DEFAULT_INACTIVITY_SEC = 1800.0         # active-window motion this far below baseline = anomaly
INACTIVITY_FRACTION = 0.25              # motion under this fraction of normal active = "still"


def bucket_of(ts):
    """Hour-of-day bucket [0, 23] for an epoch timestamp (UTC-stable, DST-free)."""
    return int((ts % 86400) // SECONDS_PER_BUCKET)


def _day_index(ts):
    """Integer day number — used only to count DISTINCT nights observed."""
    return int(ts // 86400)


class _Welford:
    """Online mean/variance so the baseline updates per-frame without storing frames."""

    __slots__ = ("n", "mean", "m2")

    def __init__(self, n=0, mean=0.0, m2=0.0):
        self.n = n
        self.mean = mean
        self.m2 = m2

    def push(self, x):
        self.n += 1
        d = x - self.mean
        self.mean += d / self.n
        self.m2 += d * (x - self.mean)

    @property
    def std(self):
        return math.sqrt(self.m2 / self.n) if self.n > 1 else 0.0

    def to_dict(self):
        return {"n": self.n, "mean": self.mean, "m2": self.m2}

    @classmethod
    def from_dict(cls, d):
        return cls(int(d.get("n", 0)), float(d.get("mean", 0.0)), float(d.get("m2", 0.0)))


class BaselineModel:
    """Per-time-of-day baseline of normal motion + presence, learned online.

    Ships empty. Becomes `ready` only after >= min_nights DISTINCT days have been
    observed and the relevant buckets each hold >= min_bucket_samples frames.
    """

    def __init__(self, min_nights=DEFAULT_MIN_NIGHTS,
                 min_bucket_samples=DEFAULT_MIN_BUCKET_SAMPLES,
                 min_bucket_days=DEFAULT_MIN_BUCKET_DAYS):
        self.min_nights = min_nights
        self.min_bucket_samples = min_bucket_samples
        self.min_bucket_days = min_bucket_days
        self.motion = [_Welford() for _ in range(BUCKETS_PER_DAY)]    # motion stats / bucket
        self.presence = [_Welford() for _ in range(BUCKETS_PER_DAY)]  # presence rate / bucket
        self.days = set()                                             # distinct day indices seen
        self.bucket_days = [set() for _ in range(BUCKETS_PER_DAY)]    # distinct days seen / bucket

    def observe(self, ts, present, motion):
        b = bucket_of(ts)
        d = _day_index(ts)
        self.days.add(d)
        self.bucket_days[b].add(d)
        self.presence[b].push(1.0 if present else 0.0)
        # motion only shapes the resting/active baseline while the resident is present;
        # an empty room's zero-motion must not masquerade as "normally still".
        if present:
            self.motion[b].push(float(motion))

    @property
    def nights_observed(self):
        return len(self.days)

    def bucket_ready(self, b):
        # A bucket's baseline must span >= min_bucket_days DISTINCT days, not just
        # enough frames: 20 frames from a single night (2s at 10Hz) is not a learned
        # "normal at this hour" and must never back an anomaly (§5.1 accuracy-or-nothing).
        if len(self.bucket_days[b]) < self.min_bucket_days:
            return False
        return (self.motion[b].n >= self.min_bucket_samples or
                self.presence[b].n >= self.min_bucket_samples)

    @property
    def ready(self):
        return self.nights_observed >= self.min_nights

    def classify_bucket(self, b):
        """Label a learned bucket as 'rest', 'active', 'mixed', or None (not learned)."""
        if not self.bucket_ready(b):
            return None
        if self.presence[b].mean < PRESENCE_MIN:
            return None                       # not reliably occupied -> can't judge the resident
        if self.motion[b].n < self.min_bucket_samples:
            return None
        mm = self.motion[b].mean
        if mm <= REST_MOTION_MAX:
            return "rest"
        if mm >= ACTIVE_MOTION_MIN:
            return "active"
        return "mixed"

    def bucket_stats(self, b):
        return {
            "bucket": b,
            "kind": self.classify_bucket(b),
            "motion_mean": round(self.motion[b].mean, 4),
            "motion_std": round(self.motion[b].std, 4),
            "presence_rate": round(self.presence[b].mean, 3),
            "n": self.motion[b].n,
        }

    def summary(self):
        return {
            "ready": self.ready,
            "nights_observed": self.nights_observed,
            "nights_required": self.min_nights,
            "rest_buckets": [b for b in range(BUCKETS_PER_DAY) if self.classify_bucket(b) == "rest"],
            "active_buckets": [b for b in range(BUCKETS_PER_DAY) if self.classify_bucket(b) == "active"],
        }

    def to_dict(self):
        return {
            "min_nights": self.min_nights,
            "min_bucket_samples": self.min_bucket_samples,
            "min_bucket_days": self.min_bucket_days,
            "motion": [w.to_dict() for w in self.motion],
            "presence": [w.to_dict() for w in self.presence],
            "days": sorted(self.days),
            "bucket_days": [sorted(s) for s in self.bucket_days],
        }

    @classmethod
    def from_dict(cls, d):
        m = cls(int(d.get("min_nights", DEFAULT_MIN_NIGHTS)),
                int(d.get("min_bucket_samples", DEFAULT_MIN_BUCKET_SAMPLES)),
                int(d.get("min_bucket_days", DEFAULT_MIN_BUCKET_DAYS)))
        m.motion = [_Welford.from_dict(x) for x in d.get("motion", [])] or m.motion
        m.presence = [_Welford.from_dict(x) for x in d.get("presence", [])] or m.presence
        m.days = set(int(x) for x in d.get("days", []))
        bd = d.get("bucket_days")
        if bd:   # absent in a pre-fix store -> buckets re-establish day-spread (conservative)
            m.bucket_days = [set(int(x) for x in s) for s in bd]
        return m


class AnomalyDetector:
    """Stateful detector: feed it observations in time order, get a semantic state.

    update() returns a dict every call. `state` is None unless a real, sustained,
    baseline-relative anomaly is confirmed — there is no path that emits an anomaly
    without a `ready` baseline for the current bucket.
    """

    def __init__(self, model=None, depart_sustain_sec=DEPART_SUSTAIN_SEC,
                 rest_establish_sec=REST_ESTABLISH_SEC,
                 inactivity_sec=DEFAULT_INACTIVITY_SEC):
        self.model = model or BaselineModel()
        self.depart_sustain_sec = depart_sustain_sec
        self.rest_establish_sec = rest_establish_sec
        self.inactivity_sec = inactivity_sec
        # live bed-exit state
        self._rest_since = None           # ts the resident became continuously at-rest
        self._rest_established = False     # the current/last rest run reached the establish gate
        self._depart_since = None          # ts a departure from rest began
        self._bedexit_latched = False      # one bed-exit per established-rest episode
        # live inactivity state
        self._low_motion_since = None      # ts motion fell below the active baseline
        self._inactivity_latched = False

    def _rest_gate(self, rest_mean, rest_std):
        return max(REST_MOTION_MAX, rest_mean + DEPART_MOTION_K * rest_std)

    def update(self, ts, present, motion, learn=True):
        if learn:
            self.model.observe(ts, present, motion)

        b = bucket_of(ts)
        kind = self.model.classify_bucket(b)
        # Anomaly JUDGMENT (not just display) requires the bucket to have been learned
        # across >= min_bucket_days distinct days OTHER THAN today: tonight's own entry
        # frames must not arm tonight's alarm off a single prior night (thin-baseline
        # false positive; §5.1 accuracy-or-nothing).
        judgeable = len(self.model.bucket_days[b] - {_day_index(ts)}) >= self.model.min_bucket_days
        base = {
            "ts": ts, "bucket": b,
            "nights_observed": self.model.nights_observed,
            "nights_required": self.model.min_nights,
        }

        if not self.model.ready:
            return {**base, "state": None, "status": "learning_baseline",
                    "detail": f"baseline learning: {self.model.nights_observed}/"
                              f"{self.model.min_nights} nights"}

        ms = self.model.motion[b]
        rest_mean, rest_std = ms.mean, ms.std

        # ---- bed-exit: only meaningful in a learned RESTING bucket ----
        if kind == "rest":
            at_rest = present and motion <= self._rest_gate(rest_mean, rest_std)
            if at_rest:
                if self._rest_since is None:
                    self._rest_since = ts
                    self._rest_established = False
                if ts - self._rest_since >= self.rest_establish_sec:
                    self._rest_established = True
                    self._bedexit_latched = False     # re-arm for the next episode
                self._depart_since = None
            else:
                if self._depart_since is None:
                    self._depart_since = ts
                self._rest_since = None                # rest run is broken
                sustained = ts - self._depart_since >= self.depart_sustain_sec
                if (self._rest_established and sustained
                        and not self._bedexit_latched and judgeable):
                    self._bedexit_latched = True
                    self._rest_established = False
                    conf = 0.9 if not present else min(0.95, 0.5 + (motion - rest_mean))
                    return {**base, "state": "bed-exit", "status": "anomaly",
                            "confidence": round(float(max(0.5, min(0.99, conf))), 2),
                            "detail": "left a sustained at-rest state during the normal "
                                      "resting window"}
        else:
            self._rest_since = None
            self._depart_since = None

        # ---- inactivity-anomaly: only meaningful in a learned ACTIVE bucket ----
        if kind == "active":
            low_gate = ms.mean * INACTIVITY_FRACTION
            if present and motion < low_gate:
                if self._low_motion_since is None:
                    self._low_motion_since = ts
                if (ts - self._low_motion_since >= self.inactivity_sec
                        and not self._inactivity_latched and judgeable):
                    self._inactivity_latched = True
                    return {**base, "state": "inactivity-anomaly", "status": "anomaly",
                            "confidence": 0.8,
                            "detail": "motion far below the normal active baseline for an "
                                      "abnormally long span"}
            else:
                self._low_motion_since = None
                self._inactivity_latched = False
        else:
            self._low_motion_since = None
            self._inactivity_latched = False

        return {**base, "state": None, "status": "nominal",
                "bucket_kind": kind, "detail": "within learned baseline"}

    def snapshot(self):
        """Last-known readiness without advancing state (for the /anomaly endpoint poll)."""
        return {
            "ready": self.model.ready,
            "nights_observed": self.model.nights_observed,
            "nights_required": self.model.min_nights,
        }
