"""One real-model HRV analysis on SYNTHETIC data with state detail: 40 nights of history, then an evening walk and
a late bike ride, the night's 15-minute HRV readings by activity in the hosted snapshot, and lower HRV that night.
Nothing about a real person is involved. Same settings as scripts/smoke_real_model.py.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import sys
import tempfile
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tests.conftest import LocalPostgres  # noqa: E402

from nara_metric_insight.config import Config  # noqa: E402
from nara_metric_insight.db import Database, connect  # noqa: E402
from nara_metric_insight.worker import Worker  # noqa: E402

USER = "5e1f0c2a-0000-4000-8000-00000000fade"   # invented
DEVICE = "5e1f0c2a-0000-4000-8000-0000000faded"
ANCHOR = date(2026, 10, 6)
ZONE = ZoneInfo("America/Los_Angeles")
METRIC = os.environ.get("SMOKE_METRIC", "hrv_rmssd")


def local(day: date, hour: int, minute: int = 0) -> int:
    return int(datetime(day.year, day.month, day.day, hour, minute, tzinfo=ZONE).timestamp())


def main() -> None:
    base = Path(tempfile.mkdtemp(prefix="mi-pg-", dir="/tmp"))
    work = Path(tempfile.mkdtemp(prefix="mis-", dir="/tmp"))
    pg = LocalPostgres(base).start()
    try:
        (base / "db_url").write_text(pg.url)
        evening = ANCHOR - timedelta(days=1)
        onset, wake = datetime(2026, 10, 5, 23, 40, tzinfo=ZONE), datetime(2026, 10, 6, 6, 40, tzinfo=ZONE)
        pg.psql(f"""insert into auth.users(id) values ('{USER}');
            insert into public.profiles(id, timezone) values ('{USER}', 'America/Los_Angeles')
              on conflict (id) do update set timezone = excluded.timezone;
            insert into public.devices(id, user_id, source_kind, external_device_id)
              values ('{DEVICE}', '{USER}', 'noop_push', 'whoop-SMOKE0001');
            insert into public.scoring_source_preferences_v2(user_id, device_id) values ('{USER}', '{DEVICE}');""")
        rows = []
        for i in range(40):
            day = ANCHOR - timedelta(days=39 - i)
            hrv = 66 - round(3 * math.sin(i / 3.0)) - (14 if day == ANCHOR else 0)
            rhr = 52 + round(1.2 * math.sin(i / 2.0)) + (6 if day == ANCHOR else 0)
            on = (onset - timedelta(days=39 - i)).isoformat()
            off = (wake - timedelta(days=39 - i)).isoformat()
            rows.append(f"('{USER}', '{day}', 'frwhoop-server-1', '{DEVICE}', {rhr}, {hrv}, {440 - (40 if day == ANCHOR else 0)},"
                        f" 0.9, 14.0, '{on}', '{off}')")
        pg.psql("insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm,"
                " hrv_rmssd_ms, sleep_total_min, sleep_efficiency, resp_rate_bpm, sleep_onset_at, wake_onset_at) values "
                + ", ".join(rows))

        # The hosted snapshots: 15-minute HRV readings with their activity composition, and the night's session.
        def slot(t: int, rmssd: float, shares: dict, recent: int | None = None, post: bool = False) -> tuple:
            return [t, rmssd, 400], {"slot_s": t, "shares": shares, "unknown_share": 0.0, "recent_activity_s": recent,
                                     "post_activity": post}
        afternoon = [slot(local(evening, 15) + k * 900, 54 + (k % 3), {"stationary": 0.95}) for k in range(8)]
        walk = [slot(local(evening, 18) + k * 900, 31 + k, {"walking": 0.8, "stationary": 0.2}) for k in range(3)]
        ride = [slot(local(evening, 21) + k * 900, 24 + k, {"other_movement": 0.85, "stationary": 0.15}) for k in range(2)]
        after = [slot(local(evening, 21, 30) + k * 900, 36 + 2 * k, {"stationary": 1.0}, 300 + k * 900, True)
                 for k in range(2)]
        night = [[local(ANCHOR, 0) + k * 900, 50 + (k % 4), 900] for k in range(24)]
        evening_slots = afternoon + walk + ride + after
        session = {"start_at": onset.astimezone(ZoneInfo("UTC")).isoformat(), "end_at": wake.astimezone(ZoneInfo("UTC")).isoformat(),
                   "is_nap": False, "asleep_min": 400}
        for day, points, contexts in ((evening, [p for p, _ in evening_slots], [c for _, c in evening_slots]),
                                      (ANCHOR, night, [])):
            payload = {"daily": {"hrv_series": {"slot_s": 900, "points": points},
                                 "activity_context": {"contexts": {"hrv_slots": contexts, "sleep_sessions": []}}},
                       "sleep": [session] if day == ANCHOR else []}
            pg.psql(f"insert into public.scoring_snapshots_v2(user_id, device_id, day, algorithm_version, input_revision,"
                    f" computed_at, payload) values ('{USER}', '{DEVICE}', '{day}', 'frwhoop-server-1', 1, now(),"
                    f" $p${json.dumps(payload)}$p$::jsonb)")
        runs = [{"s": local(evening, 18), "e": local(evening, 18, 42), "activity_class": "walking"},
                {"s": local(evening, 19), "e": local(evening, 20, 50), "activity_class": "sitting"},
                {"s": local(evening, 21), "e": local(evening, 21, 32), "activity_class": "cycling"}]
        for utc_day in sorted({datetime.fromtimestamp(r["s"], ZoneInfo("UTC")).date() for r in runs}):
            day_runs = [r for r in runs if datetime.fromtimestamp(r["s"], ZoneInfo("UTC")).date() == utc_day]
            pg.psql(f"""insert into public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version,
                ontology_version, decoder_version, feature_schema, model_version, preprocessing_version, job_fingerprint,
                input_revision, publish_interval_s, observed_s, run_count, event_count, unclear_s, mean_confidence,
                document, result_revision, computed_at) values ('{USER}', '{DEVICE}', '{utc_day}', 'hart-activity-1', 2,
                'v1', 'd1', 'f1', 'm1', 'p1', '{"b" * 64}', 1, 60, 3600, {len(day_runs)}, 0, 0, 0.9,
                $d${json.dumps({"runs": day_runs})}$d$::jsonb, 1, now())""")
        print(json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', '{METRIC}')"))["status"])

        env = dict(os.environ, NARA_DB_URL_FILE=str(base / "db_url"), NARA_WORK_ROOT=str(work), NARA_WORKER_ID="smoke",
                   NARA_SANDBOX=os.environ.get("NARA_SANDBOX", "macos"))
        if os.environ.get("SMOKE_SHOW_REJECTED"):  # synthetic data only: print what the validator refused
            from nara_metric_insight import validate, worker as worker_module
            original = validate.check

            def logged(text, *args, **kwargs):
                result = original(text, *args, **kwargs)
                if not result.ok:
                    print("REJECTED:", text[:1600], "\nERRORS:", result.errors, file=sys.stderr)
                return result
            worker_module.validate.check = logged
        worker = Worker(Config.from_env(env))
        worker.db = Database(connect(pg.url))
        started = time.monotonic()
        outcome = worker.once()
        print(json.dumps({"outcome": outcome, "seconds": round(time.monotonic() - started, 1)}))
        response = json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', '{METRIC}')"))
        insight = response.get("insight") or {}
        print(json.dumps({k: insight.get(k) for k in ("headline", "observed", "interpretation", "uncertainty")}, indent=1))
        print("citations:", [(c.get("title") or "")[:80] for c in insight.get("citations") or []])
        print(pg.psql(f"select evidence -> 'validator' || jsonb_build_object('run', evidence -> 'run') "
                      f"from public.metric_insights where user_id = '{USER}'"))
        print("last_error:", pg.psql("select coalesce(last_error, '-') from public.metric_insight_jobs"))
        worker.db.conn.close()
    finally:
        pg.stop()
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
