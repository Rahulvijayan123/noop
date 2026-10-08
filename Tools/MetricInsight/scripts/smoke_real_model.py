"""One real-model analysis on SYNTHETIC data: a throwaway local PostgreSQL (full migration chain), an invented
user with 40 nights of resting heart rate that end in a short rise, a recorded alcohol exposure and shorter
estimated sleep; then the real worker (sandboxed prime-agent, the configured provider) and the published
insight. Nothing about a real person is involved.

    NARA_LLM_API_KEY_FILE=<0600 file> NARA_LLM_BASE_URL=https://api.fireworks.ai/inference/v1 \
    NARA_LLM_MODEL=accounts/fireworks/models/<id> NARA_PRIME_BIN=... NARA_KERNEL_PYTHON=... \
    uv run python scripts/smoke_real_model.py
"""

from __future__ import annotations

import json
import math
import os
import shutil
import sys
import tempfile
import time
from datetime import date, datetime, time as clock, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tests.conftest import LocalPostgres  # noqa: E402

from nara_metric_insight.config import Config  # noqa: E402
from nara_metric_insight.db import Database, connect  # noqa: E402
from nara_metric_insight.worker import Worker  # noqa: E402

USER = "5e1f0c2a-0000-4000-8000-00000000c0de"   # invented
DEVICE = "5e1f0c2a-0000-4000-8000-0000000d0e1c"
ANCHOR = date(2026, 10, 6)
ZONE = "America/Los_Angeles"


def main() -> None:
    base = Path(tempfile.mkdtemp(prefix="mi-pg-", dir="/tmp"))
    work = Path(tempfile.mkdtemp(prefix="mis-", dir="/tmp"))
    db_file = base / "db_url"
    pg = LocalPostgres(base).start()
    try:
        db_file.write_text(pg.url)
        pg.psql(f"insert into auth.users(id) values ('{USER}');"
                f"insert into public.profiles(id, timezone) values ('{USER}', '{ZONE}') on conflict (id) do update set timezone = excluded.timezone;")
        rows = []
        for i in range(40):
            day = ANCHOR - timedelta(days=39 - i)
            missing = i in (9, 22)
            rhr = 52 + round(1.5 * math.sin(i / 2.0)) + (6 if i >= 37 else 0)
            hrv = 68 - round(3 * math.sin(i / 3.0)) - (14 if i >= 37 else 0)
            sleep = 450 - (75 if i >= 37 else 0) + (i % 3) * 10
            rows.append(f"('{USER}', '{day}', 'frwhoop-server-1', '{DEVICE}', {'null' if missing else rhr}, "
                        f"{'null' if missing else hrv}, {sleep}, 0.9, 14.2)")
        pg.psql("insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm,"
                " hrv_rmssd_ms, sleep_total_min, sleep_efficiency, resp_rate_bpm) values " + ", ".join(rows))
        drink = int(datetime.combine(ANCHOR - timedelta(days=1), clock(21, 30), ZoneInfo(ZONE)).timestamp())
        event = {"event_id": "alcohol-1", "revision": 1, "kind": "alcohol", "label": "Two glasses of wine",
                 "occurred": {"start": drink, "end": drink + 3600}, "time_precision": "approximate",
                 "recorded_at": drink + 4000, "source": "user_entered", "confirmation": "confirmed"}
        pg.psql(f"select public.record_exposure_event_v1('{USER}', null, $ex${json.dumps(event)}$ex$::jsonb)")
        print(json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', 'resting_hr')"))["status"])

        env = dict(os.environ, NARA_DB_URL_FILE=str(db_file), NARA_WORK_ROOT=str(work), NARA_WORKER_ID="smoke",
                   NARA_SANDBOX=os.environ.get("NARA_SANDBOX", "macos"))
        worker = Worker(Config.from_env(env))
        worker.db = Database(connect(pg.url))
        started = time.monotonic()
        outcome = worker.once()
        print(json.dumps({"outcome": outcome, "seconds": round(time.monotonic() - started, 1)}))
        response = json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', 'resting_hr')"))
        print(json.dumps(response, indent=2))
        stored = pg.psql(f"select evidence -> 'validator' || jsonb_build_object('run', evidence -> 'run', "
                         f"'tool_calls', evidence -> 'tool_calls') from public.metric_insights where user_id = '{USER}'")
        print(stored)
        job = pg.psql("select last_error from public.metric_insight_jobs")
        if job:
            print("last_error:", job)
        worker.db.conn.close()
    finally:
        pg.stop()
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
