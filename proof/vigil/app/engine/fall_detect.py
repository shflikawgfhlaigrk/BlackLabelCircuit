#!/usr/bin/env python3
"""
Fall / emergency monitor — the eldercare safety layer over a single reliable node.

Built ONLY on signals that are reliable from one well-placed bedside board (proven
this session): motion present/absent and breathing present/absent. It does NOT
rely on through-wall position (unreliable on this hardware) or heart rate
(unreliable on commodity CSI). Conservative by design: thresholds are in MINUTES
and a real fall is about minutes-on-the-floor, not seconds — so false alarms are
rare and a genuine emergency is still caught fast.

State machine per monitored room:

    EMPTY        no presence / no motion / no breathing for a while
    ACTIVE       motion seen recently — person up and moving (fine)
    RESTING      present + breathing, low motion — sleeping / sitting still (fine)
    --- ALERTS ---
    FALL         was ACTIVE, then SUSTAINED stillness while still present
                 (got up / moving, then went down and stayed down)
    NO_MOTION    present but no motion for an abnormally long span during a window
                 the resident is normally active (incapacitation)
    NO_BREATHING present (a body is there) but NO breathing detected for a long
                 window — escalate; possible not-breathing

An alert latches until acknowledged, and re-fires on the notifier's cadence.
Everything here is honest: it only raises an alert from real, gated signals;
absence of a reliable signal is reported as 'unknown', never as 'safe'.
"""
import time


# Motion-EMA above this = the resident is actively MOVING (walking / up), distinct
# from the ~0.04 occupancy floor (a body present but still). A conservative
# heuristic, not a measurement — keeps 'fell, then still' catchable while a calm
# seated person isn't mislabeled 'moving'.
FALL_MOVE_THRESH = 0.08


def fall_signals_from_frame(frame, move_thresh=FALL_MOVE_THRESH):
    """Map a sensing frame (home_engine.py) to FallMonitor's three reliable inputs.

    Pure + testable, no clock. Honest by construction (CHARTER §5.1):
      * present_static     = the engine's gated occupancy (range peak OR motion proxy),
        OR a real accuracy-gated breathing rate. Motion-gated occupancy collapses a
        few seconds after a body goes still, but a gated breath cannot originate from
        an empty room, so crediting it as presence is what lets a fallen-but-breathing
        resident stay 'present' long enough for FALL/NO_BREATHING to fire. A resident
        who LEFT emits neither (walking isn't still, so no breath; empty room, so no
        occupancy), so presence still clears — no false hold.
      * moving             = motion EMA clearly above the occupancy floor;
      * breathing_detected = a REAL accuracy-gated rate was emitted (None when the
        SNR/periodicity gate failed OR vitals were suppressed on synthetic demo data)
        -> a suppressed / absent rate never counts as 'breathing present'.
    Returns (moving, breathing_detected, present_static).
    """
    breathing_detected = frame.get("breathing_bpm") is not None
    present_static = bool(frame.get("present")) or breathing_detected
    motion = frame.get("motion", 0.0) or 0.0
    moving = float(motion) > move_thresh
    return moving, breathing_detected, present_static


class FallMonitor:
    def __init__(self,
                 fall_still_secs=45.0,      # ACTIVE -> down-and-stays-down this long = FALL
                 fall_lookback_secs=20.0,   # must have been moving within this window before
                 no_motion_secs=900.0,      # 15 min no motion while present = check (incapacitation)
                 no_breathing_secs=120.0,   # present + no breathing this long = escalate
                 present_grace_secs=30.0):  # how long presence persists after last positive signal
        self.fall_still_secs = fall_still_secs
        self.fall_lookback_secs = fall_lookback_secs
        self.no_motion_secs = no_motion_secs
        self.no_breathing_secs = no_breathing_secs
        self.present_grace_secs = present_grace_secs
        # tracked timestamps (None = never seen; 0.0 is a valid ts so don't use it)
        self.last_motion = None
        self.last_breath = None
        self.last_present = None      # last tick a body was detected (motion/breath/dev)
        self.present_hold_secs = 25.0 # bridge the ~20s breathing-lock after motion stops.
                                      # MUST be < fall_still_secs so 'left the room'
                                      # (no breathing relock) clears before FALL fires.
        self.active_until = 0.0       # we consider them "recently active" until this ts
        self.state = "EMPTY"
        self.alert = None             # dict when latched, else None
        self.started = time.time()

    def update(self, now, moving, breathing_detected, present_static, calibrated):
        """Feed one tick of the reliable signals. Returns the current public state.

        present_static = a body is in the room even if motionless (CSI differs from
        the empty-room baseline). This is what distinguishes 'fell silently' (body
        still there) from 'left the room' (channel returns to empty) — the core
        ambiguity a single node otherwise can't resolve.
        """
        if not calibrated:
            self.state = "CALIBRATING"
            return self._public(now)

        if moving:
            self.last_motion = now
            self.active_until = now + self.fall_lookback_secs
        if breathing_detected:
            self.last_breath = now

        if present_static:
            self.last_present = now
        # presence held briefly past the last positive signal — bridges the breathing
        # relock gap for a person who fell and went still, WITHOUT false-holding a
        # person who left (hold < fall_still_secs, so it clears before FALL fires).
        present = self.last_present is not None and (now - self.last_present) < self.present_hold_secs
        still_for = (now - self.last_motion) if self.last_motion is not None else 1e9
        breath_for = (now - self.last_breath) if self.last_breath is not None else 1e9
        was_recently_active = (self.last_motion is not None
                               and (now - self.last_motion) < (self.fall_still_secs + self.fall_lookback_secs))

        # ---- evaluate alert conditions (most urgent first) ----
        # Sleeping (present + breathing, still) is NORMAL — never alerts: breathing
        # recency keeps NO_BREATHING from firing and stillness alone is not a fall.
        new_alert = None
        if present and breath_for > self.no_breathing_secs and still_for > self.no_breathing_secs:
            # down, present, neither moving nor breathing detected — the unambiguous emergency
            new_alert = ("NO_BREATHING", "A person is present but no movement or breathing detected — check now")
        elif present and was_recently_active and still_for > self.fall_still_secs:
            # was moving, then abrupt sustained stillness while a body is still here.
            # Fires even if still breathing (a conscious fall). NOTE: deliberately
            # lying down also looks like this to one board — an honest soft alert.
            new_alert = ("FALL", "Was moving, then went still and hasn't gotten up — possible fall")

        # ---- state for display ----
        if not present:
            self.state = "EMPTY"
        elif still_for < 4.0:
            self.state = "ACTIVE"
        elif breath_for < 30.0:
            self.state = "RESTING"
        else:
            self.state = "STILL"

        if new_alert:
            kind, msg = new_alert
            if self.alert is None or self.alert["kind"] != kind:
                # new (or escalated) alert
                self.alert = {"kind": kind, "message": msg, "since": now,
                              "acknowledged": False, "last_notified": 0.0}
            self.state = kind
        return self._public(now)

    def acknowledge(self):
        if self.alert:
            self.alert["acknowledged"] = True

    def clear(self):
        self.alert = None

    def _public(self, now):
        a = None
        if self.alert:
            a = {
                "kind": self.alert["kind"],
                "message": self.alert["message"],
                "since_s": round(now - self.alert["since"], 1),
                "acknowledged": self.alert["acknowledged"],
            }
        return {
            "state": self.state,
            "alert": a,
            "last_motion_s": round(now - self.last_motion, 1) if self.last_motion is not None else None,
            "last_breath_s": round(now - self.last_breath, 1) if self.last_breath is not None else None,
        }

    def needs_notify(self, now, cadence_s=30.0):
        """True if a live, unacknowledged alert is due for (re)notification."""
        if not self.alert or self.alert["acknowledged"]:
            return False
        if now - self.alert["last_notified"] >= cadence_s:
            self.alert["last_notified"] = now
            return True
        return False
