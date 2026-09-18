"""C4 — Alert escalation module.

Operating envelope: subscribes to `fall.confirmed` and `vitals.apnea` on
the in-process bus. The first contact (lowest priority number) is notified
immediately; each subsequent contact after `alerts.escalation_s` unless
`ack(event_id)` arrives first (threading.Timer chain, cancellable; a
`timer_factory` hook makes tests deterministic without sleeping). Delivery:
Twilio SMS when the three env vars named in config.alerts are all set AND
the optional `twilio` package imports — otherwise a
{contact, body, ts, channel: "would-send"} record is appended to `.sent`
(the tests' observable). A local notification goes out per event: macOS
`osascript display notification` on darwin, else a channel "local" record
in `.sent`. `test_alert()` pushes a clearly marked test message through the
full path. Event-log wiring is the caller's job (EventLog.attach(bus)).
Never imports twilio at module top level (CONTRACTS §7).
"""

from __future__ import annotations

import itertools
import json
import os
import subprocess
import sys
import threading
import time

from ..bus import EventBus
from ..config import VigilConfig


class AlertModule:
    def __init__(self, config: VigilConfig, bus: EventBus | None = None,
                 timer_factory=None) -> None:
        self.config = config
        self.bus = bus
        self.sent: list[dict] = []
        self._timer_factory = timer_factory or threading.Timer
        self._acked: set[str] = set()
        self._timers: dict[str, object] = {}
        self._counter = itertools.count()
        self._lock = threading.RLock()
        if bus is not None:
            bus.subscribe("fall.confirmed", self._on_event)
            bus.subscribe("vitals.apnea", self._on_event)

    # -- event handling -------------------------------------------------------

    def _on_event(self, topic: str, payload: dict) -> str:
        with self._lock:
            event_id = f"{topic}#{next(self._counter)}"
        body = self._format(topic, payload)
        self._notify_local(event_id, body)
        self._dispatch(event_id, 0, body)
        return event_id

    def _format(self, topic: str, payload: dict) -> str:
        parts = []
        if payload.get("test"):
            parts.append("[TEST]")
        parts.append(f"Vigil alert: {topic}")
        for key in ("room", "t", "confidence", "kind"):
            if key in payload:
                parts.append(f"{key}={payload[key]}")
        return " ".join(str(p) for p in parts)

    def _contacts(self) -> list[dict]:
        return sorted(self.config.alerts.contacts,
                      key=lambda c: c.get("priority", 999))

    def _dispatch(self, event_id: str, idx: int, body: str) -> None:
        with self._lock:
            if event_id in self._acked:
                return
            contacts = self._contacts()
            if idx >= len(contacts):
                return
        self._send_sms(event_id, contacts[idx], body)
        if idx + 1 < len(contacts):
            timer = self._timer_factory(
                self.config.alerts.escalation_s,
                lambda: self._dispatch(event_id, idx + 1, body))
            if isinstance(timer, threading.Timer):
                timer.daemon = True
            with self._lock:
                self._timers[event_id] = timer
            timer.start()

    def ack(self, event_id: str) -> None:
        """Acknowledge an alert: stops any further escalation."""
        with self._lock:
            self._acked.add(event_id)
            timer = self._timers.pop(event_id, None)
        if timer is not None:
            timer.cancel()

    def close(self) -> None:
        with self._lock:
            timers = list(self._timers.values())
            self._timers.clear()
        for t in timers:
            t.cancel()

    # -- delivery channels -------------------------------------------------------

    def _twilio_creds(self) -> tuple[str, str, str] | None:
        a = self.config.alerts
        sid = os.environ.get(a.twilio_sid_env, "")
        token = os.environ.get(a.twilio_token_env, "")
        from_no = os.environ.get(a.twilio_from_env, "")
        if sid and token and from_no:
            return sid, token, from_no
        return None

    def _send_sms(self, event_id: str, contact: dict, body: str) -> None:
        record = {
            "event_id": event_id,
            "contact": contact.get("name") or contact.get("phone", "?"),
            "phone": contact.get("phone", ""),
            "body": body,
            "ts": time.time(),
        }
        creds = self._twilio_creds()
        if creds is not None:
            try:
                from twilio.rest import Client  # optional dep, lazy

                sid, token, from_no = creds
                Client(sid, token).messages.create(
                    to=contact.get("phone", ""), from_=from_no, body=body)
                record["channel"] = "twilio"
                with self._lock:
                    self.sent.append(record)
                return
            except Exception:
                pass  # fall through to would-send
        record["channel"] = "would-send"
        with self._lock:
            self.sent.append(record)

    def _notify_local(self, event_id: str, body: str) -> None:
        if sys.platform == "darwin":  # pragma: no cover (mac only)
            script = f'display notification {json.dumps(body)} with title "Vigil"'
            subprocess.run(["osascript", "-e", script],
                           check=False, capture_output=True)
        else:
            with self._lock:
                self.sent.append({
                    "event_id": event_id, "contact": "local", "body": body,
                    "ts": time.time(), "channel": "local",
                })

    # -- self-test ----------------------------------------------------------------

    def test_alert(self) -> str:
        """Send a clearly marked test alert through the full escalation path.
        Returns the event_id (ack it to stop the escalation chain)."""
        return self._on_event("fall.confirmed", {
            "room": "test", "t": 0.0, "confidence": 0.0, "test": True,
        })
