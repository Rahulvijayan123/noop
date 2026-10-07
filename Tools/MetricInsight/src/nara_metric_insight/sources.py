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

from . import layer1
from .db import Database
from .metrics import ALGORITHM_VERSION, BASELINE_NIGHTS, INSIGHT_METRICS, SIGNALS, WINDOW_DAYS

SCORE_COLUMNS = sorted({s.column for s in SIGNALS.values() if s.source == "scores"}
                       | {"sleep_onset_at", "wake_onset_at", "source_device_id"})
# The app's Baseline night vitals that are server_daily_scores columns (steps come from the day values).
VITAL_COLUMNS = sorted(c for k, c in layer1.COLUMNS.items() if k != "waking_steps")
DAY_VALUE_COLUMNS = ("steps", "total_kcal", "energy", "spo2_candidate_pct", "spo2_candidate_samples")
CALM_HR_SERIES = "heart_rate.stable_awake_5min"
STEPS_HISTORY_DAYS = 400   # public.metric_insight_day_values_v1's longest range (the steps usual's replay)
GAIT_HISTORY_DAYS = 30     # activity_gait_windows_days keeps 30 days
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
        self._lock = threading.RLock()  # loaders build on each other (context needs the scores)
        self.loaded: list[str] = []

    def _get(self, name: str, loader: Callable[[], Any]) -> Any:
        with self._lock:
            if name not in self._cache:
                self._cache[name] = loader()
                self.loaded.append(name)
            return self._cache[name]

    # ------------------------------------------------------------------ loaders

    def _needs(self) -> set[str]:
        """The sources the metric and its related signals read (Signal.source)."""
        metric = INSIGHT_METRICS[self.metric]
        return {metric.signal.source} | {SIGNALS[k].source for k in metric.related if k in SIGNALS}

    def _uses_layer1(self, series: str) -> bool:
        metric = INSIGHT_METRICS[self.metric]
        return any(SIGNALS[k].layer1 == series for k in (metric.key, *metric.related) if k in SIGNALS)

    def scores(self) -> dict[date, dict[str, Any]]:
        """Every day's values for the analysis window plus the baseline lead-in, keyed by day: the server_daily_scores
        row, and where the metric reads them, the hosted day values (steps, energy, the SpO2 estimate) and the
        calm awake heart rate of the day's context document. One row per day, so every signal reads the same way."""
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
            rows = self.db.as_owner(self.user_id, read)
            needs = self._needs()
            if "day_values" in needs:
                _merge(rows, self.day_values(start))
            if "context" in needs:
                _merge(rows, self.calm_heart_rate(start))
            return rows
        return self._get("scores", load)

    def day_values(self, start: date) -> dict[date, dict[str, Any]]:
        """The hosted day values from `start` to the anchor (public.metric_insight_day_values_v1, as the owner)."""
        def read(cur, start=start):
            cur.execute("select * from public.metric_insight_day_values_v1(%s, %s)", (start, self.anchor))
            return {row["day"]: {k: row[k] for k in DAY_VALUE_COLUMNS} for row in cur.fetchall()}
        return self.db.as_owner(self.user_id, read) if self.anchor else {}

    def calm_heart_rate(self, start: date) -> dict[date, dict[str, Any]]:
        """Calm awake heart rate (the context layer's `heart_rate.stable_awake_5min` daily value) of each day from
        `start` to the anchor, from the scoring device's selected document: retrospective first, else live."""
        device = self.device()
        if device is None:
            return {}

        def read(cur):
            cur.execute(
                "select distinct on (d.day) d.day, internal_value.value from public.physiology_context_days d "
                "cross join lateral (select (x ->> 'value')::double precision as value "
                "  from jsonb_array_elements(case when jsonb_typeof(d.document -> 'daily_values') = 'array' "
                "                                 then d.document -> 'daily_values' else '[]'::jsonb end) x "
                "  where x ->> 'series_key' = %s and jsonb_typeof(x -> 'value') = 'number' limit 1) internal_value "
                "where d.user_id = %s and d.device_id = %s and d.day between %s and %s and d.superseded_by is null "
                "order by d.day, (d.mode = 'retrospective') desc",
                (CALM_HR_SERIES, self.user_id, device, start, self.anchor))
            return {row["day"]: {"calm_awake_hr_bpm": row["value"]} for row in cur.fetchall()}
        return self.db.as_owner(self.user_id, read)

    def device(self) -> str | None:
        """The analysed day's scoring device: its own score row, else the latest one before it (as the inputs
        fingerprint resolves it)."""
        def load() -> str | None:
            if self.anchor is None:
                return None

            def read(cur):
                cur.execute(
                    "select source_device_id from public.server_daily_scores where user_id = %s "
                    "and algorithm_version = %s and day <= %s and source_device_id is not null "
                    "order by day desc limit 1", (self.user_id, ALGORITHM_VERSION, self.anchor))
                row = cur.fetchone()
                return row["source_device_id"] if row else None
            return self.db.as_owner(self.user_id, read)
        return self._get("device", load)

    def gait_days(self) -> list[dict[str, Any]]:
        """ElderNet gait rows (activity_gait_windows_days, UTC days) of the analysed local day and the month before:
        per UTC day the newest result across modes and models, as the app's gait route serves it."""
        def load() -> list[dict[str, Any]]:
            device = self.device()
            if self.anchor is None or device is None:
                return []

            def read(cur):
                cur.execute(
                    "select distinct on (g.day) g.day, g.model_version, g.mode, g.n_windows, g.n_gait, g.hop_s, "
                    "g.window_s, g.summary -> 'gait' as gait, g.summary -> 'mean_gait_prob' as mean_gait_prob, "
                    "g.windows, g.result_revision from public.activity_gait_windows_days g "
                    "where g.user_id = %s and g.device_id = %s and g.day between %s and %s "
                    "order by g.day, g.computed_at desc, g.result_revision desc",
                    (self.user_id, device, self.anchor - timedelta(days=GAIT_HISTORY_DAYS),
                     self.anchor + timedelta(days=1)))
                return [dict(row) for row in cur.fetchall()]
            return self.db.as_owner(self.user_id, read)
        return self._get("gait_days", load)

    def vital_history(self) -> dict[date, dict[str, Any]]:
        """The night vitals of every scored night up to the anchor, and, when the metric uses the app's steps usual,
        the steps of the last 400 days: the app's Baseline replays the whole history (the phone loads all of it), so
        the usual and its call need it too."""
        def load() -> dict[date, dict[str, Any]]:
            if self.anchor is None:
                return layer1.History()

            def read(cur):
                cur.execute(
                    f"select day, {', '.join(VITAL_COLUMNS)} from public.server_daily_scores "
                    "where user_id = %s and algorithm_version = %s and day <= %s order by day",
                    (self.user_id, ALGORITHM_VERSION, self.anchor))
                return {row["day"]: row for row in cur.fetchall()}
            rows = self.db.as_owner(self.user_id, read)
            if self._uses_layer1("waking_steps"):
                _merge(rows, self.day_values(self.anchor - timedelta(days=STEPS_HISTORY_DAYS)))
            return layer1.History(rows)
        return self._get("vital_history", load)

    def context(self) -> tuple[dict[str, Any] | None, str | None]:
        """The current context document of the anchor day's scoring device: retrospective first, else live."""
        return self._get("context", lambda: self._context_of(self.anchor))

    def previous_context(self) -> tuple[dict[str, Any] | None, str | None]:
        """The day before the anchor: the movement that came before the anchor night (a night is scored on the
        day it ends)."""
        return self._get("previous_context",
                         lambda: self._context_of(self.anchor - timedelta(days=1)) if self.anchor else (None, None))

    def _context_of(self, day: date | None) -> tuple[dict[str, Any] | None, str | None]:
        if day is None or self.anchor is None:
            return None, None
        device = self.device()
        if device is None:
            return None, None

        def read(cur):
            cur.execute(
                "select mode, document from public.physiology_context_days "
                "where user_id = %s and device_id = %s and day = %s and superseded_by is null "
                "order by (mode = 'retrospective') desc limit 1",
                (self.user_id, device, day))
            row = cur.fetchone()
            return (row["document"], row["mode"]) if row else (None, None)
        return self.db.as_owner(self.user_id, read)

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

    def snapshots(self) -> dict[date, dict[str, Any]]:
        """The hosted day snapshots of the night's two local days (the evening before and the morning of), through
        the owner's own RPC (get_server_score_snapshot_v2 derives the owner from auth.uid()): the 15-minute HRV
        slots, their activity composition, the sleep sessions and sleep analytics."""
        def load() -> dict[date, dict[str, Any]]:
            if self.anchor is None:
                return {}
            out = {}
            for day in (self.anchor - timedelta(days=1), self.anchor):
                def read(cur, day=day):
                    cur.execute("select public.get_server_score_snapshot_v2(%s) as s", (day,))
                    row = cur.fetchone()
                    return row["s"] if row else None
                payload = self.db.as_owner(self.user_id, read)
                if isinstance(payload, dict) and isinstance(payload.get("daily"), dict):
                    out[day] = payload
            return out
        return self._get("snapshots", load)

    def activity_runs(self) -> list[dict[str, Any]]:
        """Decoded activity runs (activity_context_runs) from the morning before the night to the end of the
        anchor day, for the scoring device; the best source per UTC day (raw-IMU HART before strap streams)."""
        def load() -> list[dict[str, Any]]:
            if self.anchor is None:
                return []
            device = (self.scores().get(self.anchor) or {}).get("source_device_id")
            if device is None:
                return []
            low = int(datetime.combine(self.anchor - timedelta(days=1), time(), self.zone).timestamp())
            high = int(datetime.combine(self.anchor + timedelta(days=1), time(), self.zone).timestamp())

            def read(cur):
                cur.execute(
                    "select day, source_rank, start_ts, end_ts, activity_class, class_confidence, sleep_state, "
                    "wear_state from public.activity_context_runs where user_id = %s and device_id = %s "
                    "and day between %s and %s and start_ts < %s and end_ts > %s order by start_ts",
                    (self.user_id, device, self.anchor - timedelta(days=2), self.anchor + timedelta(days=1),
                     high, low))
                return list(cur.fetchall())
            rows = self.db.as_owner(self.user_id, read)
            best = {}
            for row in rows:
                best[row["day"]] = min(best.get(row["day"], 9), row["source_rank"])
            return [row for row in rows if row["source_rank"] == best[row["day"]]]
        return self._get("activity_runs", load)

    # Not connected yet. Each becomes an owner-scoped read here (Database.as_owner) once its table exists, and the
    # table joins internal.metric_insight_inputs so a change re-analyses; the tools and the prompt stay the same.
    def chat_history(self) -> list[dict[str, Any]] | None:
        """The person's own coach conversations (recent turns, summarised). None: not stored for analysis yet."""
        return None

    def health_records(self) -> dict[str, Any] | None:
        """Linked health records: conditions, medications, lab results (EHR). None: no records connected yet."""
        return None

    def previous_insight(self) -> dict[str, Any] | None:
        def load() -> dict[str, Any] | None:
            def read(cur):
                cur.execute(
                    "select anchor_day, insight from public.metric_insights "
                    "where user_id = %s and metric = %s and superseded_at is null", (self.user_id, self.metric))
                return cur.fetchone()
            return self.db.as_owner(self.user_id, read)
        return self._get("previous_insight", load)


def _merge(rows: dict[date, dict[str, Any]], extra: dict[date, dict[str, Any]]) -> None:
    """Add another source's values to each day's row (a day with only those values gets a row of its own)."""
    for day, values in extra.items():
        rows.setdefault(day, {"day": day}).update(values)
