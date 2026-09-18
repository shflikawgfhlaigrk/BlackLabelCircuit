"""In-process event bus + append-only event log (CONTRACTS.md §4).

Operating envelope: single-process pub/sub on the Mac; subscribers run
inline on the publisher's thread (keep handlers cheap — heavy work belongs
on the subscriber's own queue). The event log is privacy-preserving by
construction: it stores topic, room, time, confidence and small scalars —
never raw CSI or windows.
"""

from __future__ import annotations

import json
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable

Handler = Callable[[str, dict], None]

_FORBIDDEN_KEYS = {"amps", "window", "csi", "spectrogram", "frames", "context"}


class EventBus:
    """Thread-safe topic pub/sub. Topic patterns may end with '*' (prefix glob)."""

    def __init__(self) -> None:
        self._subs: dict[str, list[Handler]] = defaultdict(list)
        self._lock = threading.Lock()

    def subscribe(self, pattern: str, handler: Handler) -> None:
        with self._lock:
            self._subs[pattern].append(handler)

    def unsubscribe(self, pattern: str, handler: Handler) -> None:
        with self._lock:
            if handler in self._subs.get(pattern, []):
                self._subs[pattern].remove(handler)

    def publish(self, topic: str, payload: dict[str, Any]) -> None:
        with self._lock:
            handlers = [
                h
                for pat, hs in self._subs.items()
                for h in hs
                if pat == topic or (pat.endswith("*") and topic.startswith(pat[:-1]))
            ]
        for h in handlers:
            h(topic, payload)


class EventLog:
    """Append-only JSONL event log. One line per event, no raw signal data."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def append(self, topic: str, payload: dict[str, Any], ts: float | None = None) -> None:
        record = {"ts": time.time() if ts is None else ts, "topic": topic}
        record.update(
            {k: v for k, v in payload.items() if k not in _FORBIDDEN_KEYS and _is_scalarish(v)}
        )
        line = json.dumps(record, separators=(",", ":"))
        with self._lock, self.path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def attach(self, bus: EventBus, pattern: str = "*") -> None:
        bus.subscribe(pattern, lambda topic, payload: self.append(topic, payload))

    def read(self) -> list[dict]:
        if not self.path.exists():
            return []
        with self.path.open(encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]


def _is_scalarish(v: Any) -> bool:
    if isinstance(v, (str, int, float, bool)) or v is None:
        return True
    if isinstance(v, (list, tuple)) and len(v) <= 16:
        return all(_is_scalarish(x) for x in v)
    if isinstance(v, dict) and len(v) <= 16:
        return all(isinstance(k, str) and _is_scalarish(x) for k, x in v.items())
    return False
