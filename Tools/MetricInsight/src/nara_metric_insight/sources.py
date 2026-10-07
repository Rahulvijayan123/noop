"""The owner's data for one job, loaded on first use and kept for the job only (never across jobs or users).

Each loader runs in its own read-only transaction through Database.as_owner (row-level security as the owner,
auth.uid() asserted) except coach memory, whose table is service-only and is read with an explicit owner filter.
The windows match internal.metric_insight_inputs, so what an analysis reads is what its fingerprint covers.
"""

from __future__ import annotations

import threading
from datetime import date, datetime, time, timedelta
from typing import Any, Callable
from zoneinfo import ZoneInfo

from .db import Database
from .metrics import ALGORITHM_VERSION, BASELINE_NIGHTS, SIGNALS, WINDOW_DAYS

SCORE_COLUMNS = sorted({s.column for s in SIGNALS.values()} | {"sleep_onset_at", "wake_onset_at", "source_device_id"})
EXPOSURE_DAYS = 14
MEMORY_ITEMS = 12


class Sources:
    def __init__(self, db: Database, user_id: str, metric: str, anchor: date | None, zone: ZoneInfo) -> None:
        self.db = db
        self.user_id = user_id
        self.metric = metric
        self.anchor = anchor
        self.zone = zone
        self._cache: dict[str, Any] = {}
        self._lock = threading.Lock()
        self.loaded: list[str] = []

    def _get(self, name: str, loader: Callable[[], Any]) -> Any:
        with self._lock:
            if name not in self._cache:
                self._cache[name] = loader()
                self.loaded.append(name)
            return self._cache[name]

    # ------------------------------------------------------------------ loaders

    def scores(self) -> dict[date, dict[str, Any]]:
        """server_daily_scores for the analysis window plus the baseline lead-in, keyed by day."""
        def load() -> dict[date, dict[str, Any]]:
            if self.anchor is None:
                return {}
            start = self.anchor - timedelta(days=WINDOW_DAYS + BASELINE_NIGHTS)

            def read(cur):
                cur.execute(
                    f"select day, {', '.join(SCORE_COLUMNS)} from public.server_daily_scores "
                    "where user_id = %s and algorithm_version = %s and day between %s and %s order by day",
                    (self.user_id, ALGORITHM_VERSION, start, self.anchor))
                return {row["day"]: row for row in cur.fetchall()}
            return self.db.as_owner(self.user_id, read)
        return self._get("scores", load)

    def context(self) -> tuple[dict[str, Any] | None, str | None]:
        """The current context document of the anchor day's scoring device: retrospective first, else live."""
        def load() -> tuple[dict[str, Any] | None, str | None]:
            if self.anchor is None:
                return None, None
            device = (self.scores().get(self.anchor) or {}).get("source_device_id")
            if device is None:
                return None, None

            def read(cur):
                cur.execute(
                    "select mode, document from public.physiology_context_days "
                    "where user_id = %s and device_id = %s and day = %s and superseded_by is null "
                    "order by (mode = 'retrospective') desc limit 1",
                    (self.user_id, device, self.anchor))
                row = cur.fetchone()
                return (row["document"], row["mode"]) if row else (None, None)
            return self.db.as_owner(self.user_id, read)
        return self._get("context", load)

    def exposures(self) -> list[dict[str, Any]]:
        def load() -> list[dict[str, Any]]:
            if self.anchor is None:
                return []
            low = int(datetime.combine(self.anchor - timedelta(days=EXPOSURE_DAYS), time(), self.zone).timestamp())
            high = int(datetime.combine(self.anchor + timedelta(days=1), time(), self.zone).timestamp())

            def read(cur):
                cur.execute(
                    "select event_id, kind, label, occurred_start, occurred_end, time_precision, confirmation, "
                    "dose_amount, dose_unit from public.exposure_events "
                    "where owner = %s and occurred_start < %s and occurred_end > %s order by occurred_start",
                    (self.user_id, high, low))
                return list(cur.fetchall())
            return self.db.as_owner(self.user_id, read)
        return self._get("exposures", load)

    def memory(self) -> list[dict[str, Any]]:
        """Per-user coach memory (service-only table): explicit owner filter, read only."""
        def load() -> list[dict[str, Any]]:
            def read(cur):
                cur.execute(
                    "select topic, content, importance from public.coach_memory_items where user_id = %s "
                    "order by importance desc, created_at desc, id limit %s", (self.user_id, MEMORY_ITEMS))
                return list(cur.fetchall())
            return self.db.service(read, read_only=True)
        return self._get("memory", load)

    def previous_insight(self) -> dict[str, Any] | None:
        def load() -> dict[str, Any] | None:
            def read(cur):
                cur.execute(
                    "select anchor_day, insight from public.metric_insights "
                    "where user_id = %s and metric = %s and superseded_at is null", (self.user_id, self.metric))
                return cur.fetchone()
            return self.db.as_owner(self.user_id, read)
        return self._get("previous_insight", load)
