"""M1 — Intervention: pre-committed rule enforcement with a user-owned
kill switch.

COMPLIANCE LINE (binding): this module analyzes only the trader themself
against their own pre-committed rules; it makes zero market predictions
and touches no market data feed beyond the user's own session tape.

Operating envelope: fires only when a TiltState arrives with BOTH the
stress flag and a pre-committed precursor — physiological state alone
never blocks anything, and a rule flag alone never blocks anything. Two
modes: "hard" (UI callback with block=True — grey out the order ticket)
and "nudge" (block=False + message). A cooldown suppresses repeat fires;
override is ALWAYS available (the user owns the kill switch) and every
override is logged. Honesty rule for the saves ledger: `est_avoided` is
user-entered or "n/a" — this module never fabricates a dollar value.
All timing is fed (t arguments) — no wall clock, no sleeps.
"""

from __future__ import annotations


class Intervention:
    """Publishes `desk.intervention` and drives the injectable UI callback."""

    TOPIC = "desk.intervention"
    OVERRIDE_TOPIC = "desk.intervention.override"

    def __init__(self, config_mode: str = "nudge", bus=None,
                 cooldown_s: float = 300.0, ui_callback=None) -> None:
        if config_mode not in ("hard", "nudge"):
            raise ValueError(f"config_mode must be 'hard'|'nudge', got {config_mode!r}")
        self.mode = config_mode
        self.bus = bus
        self.cooldown_s = float(cooldown_s)
        self.ui_callback = ui_callback  # injectable: cb(block: bool, message: str|None)
        self._last_fire: float | None = None
        self._blocked = False
        self.events: list[dict] = []     # every published intervention
        self.overrides: list[dict] = []  # every user override (always logged)
        self.acks: list[dict] = []
        self.saves: list[dict] = []      # {t, reason, est_avoided} — no fabricated $

    # -- firing -----------------------------------------------------------------

    def check(self, t: float, tilt_state) -> bool:
        """Fire iff stress AND a precursor are simultaneously present and
        the cooldown has elapsed. Returns True when an intervention fired."""
        if not (tilt_state.stress and tilt_state.precursor):
            return False
        if self._last_fire is not None and (t - self._last_fire) < self.cooldown_s:
            return False
        self._last_fire = float(t)
        reason = f"stress+{tilt_state.precursor}"
        payload = {"mode": self.mode, "reason": reason,
                   "cooldown_s": self.cooldown_s, "t": float(t),
                   "risk": round(float(tilt_state.risk), 3)}
        if self.bus is not None:
            self.bus.publish(self.TOPIC, payload)
        self.events.append(payload)
        if self.ui_callback is not None:
            if self.mode == "hard":
                self._blocked = True
                self.ui_callback(block=True, message=reason)
            else:
                self.ui_callback(
                    block=False,
                    message=(f"Pre-committed rule risk ({reason}). "
                             f"Ticket stays live — your call."))
        return True

    # -- the user owns the kill switch ---------------------------------------------

    def override(self, t: float, note: str = "") -> dict:
        """Always available, in any mode, at any time. Releases a hard
        block and logs the override — logging is the only consequence."""
        rec = {"t": float(t), "note": str(note), "mode": self.mode}
        self.overrides.append(rec)
        if self._blocked and self.ui_callback is not None:
            self._blocked = False
            self.ui_callback(block=False, message="override")
        if self.bus is not None:
            self.bus.publish(self.OVERRIDE_TOPIC, rec)
        return rec

    def ack(self, t: float) -> dict:
        """User acknowledged the intervention (dismiss without override)."""
        rec = {"t": float(t)}
        self.acks.append(rec)
        return rec

    # -- saves ledger -----------------------------------------------------------------

    def record_save(self, t: float, reason: str, est_avoided=None) -> dict:
        """Ledger entry for an intervention the user credits with a save.

        Honesty rule: `est_avoided` is whatever the USER entered, verbatim,
        or the literal string "n/a" — never a computed/fabricated value."""
        est = "n/a" if est_avoided is None or est_avoided == "" else str(est_avoided)
        rec = {"t": float(t), "reason": str(reason), "est_avoided": est}
        self.saves.append(rec)
        return rec
