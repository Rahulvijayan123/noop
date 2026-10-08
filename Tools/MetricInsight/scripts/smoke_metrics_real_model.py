"""Real-model analyses of every key metric on SYNTHETIC data: an invented person with 60 nights of vitals (resting HR,
HRV RMSSD and SDNN, breathing, wrist temperature), hosted day values (steps, the day's energy, the strap's SpO2
estimate), stable awake heart rate from the context layer with its reference and a transient deviation yesterday,
ElderNet gait windows for yesterday's walks and a coffee in the afternoon. One metric at a time through the real
worker (sandboxed prime-agent, the configured provider). Nothing about a real person is involved.

    SMOKE_METRICS=steps,calories ... uv run python scripts/smoke_metrics_real_model.py   (same settings as
    scripts/smoke_real_model.py; SMOKE_SHOW_REJECTED=1 prints what the validator refused)
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

USER = "5e1f0c2a-0000-4000-8000-0000000000aa"   # invented
DEVICE = "5e1f0c2a-0000-4000-8000-00000000aaaa"
ZONE = ZoneInfo("America/Los_Angeles")
TODAY = datetime.now(ZONE).date()
YESTERDAY = TODAY - timedelta(days=1)
METRICS = [m for m in os.environ.get("SMOKE_METRICS", "hrv_sdnn,skin_temp,resp_rate,spo2,heart_rate,steps,"
                                                      "calories").split(",") if m]


def local(day: date, hour: int, minute: int = 0) -> int:
    return int(datetime(day.year, day.month, day.day, hour, minute, tzinfo=ZONE).timestamp())


def seed(pg: LocalPostgres) -> None:
    pg.psql(f"""insert into auth.users(id) values ('{USER}');
        insert into public.profiles(id, timezone) values ('{USER}', 'America/Los_Angeles')
          on conflict (id) do update set timezone = excluded.timezone;
        insert into public.devices(id, user_id, source_kind, external_device_id)
          values ('{DEVICE}', '{USER}', 'noop_push', 'whoop-SMOKE0002');
        insert into public.scoring_source_preferences_v2(user_id, device_id) values ('{USER}', '{DEVICE}');""")
    rows = []
    for i in range(60):
        day = TODAY - timedelta(days=59 - i)
        last = day == TODAY
        wave = math.sin(i / 3.0)
        onset = datetime(day.year, day.month, day.day, 6, 40, tzinfo=ZONE) - timedelta(hours=7, minutes=10)
        rows.append(f"('{USER}', '{day}', 'frwhoop-server-1', '{DEVICE}', {52 + round(wave)}, {66 - round(3 * wave)},"
                    f" {78 - round(4 * wave) - (14 if last else 0)}, {14.2 + 0.2 * wave + (1.1 if last else 0):.1f},"
                    f" {33.9 + 0.1 * wave + (0.6 if last else 0):.2f}, {0.6 if last else 0.0}, {440 - (35 if last else 0)},"
                    f" 0.9, '{onset.isoformat()}', '{(onset + timedelta(hours=7, minutes=10)).isoformat()}')")
    pg.psql("insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm,"
            " hrv_rmssd_ms, hrv_sdnn_ms, resp_rate_bpm, skin_temp_c, skin_temp_dev_c, sleep_total_min,"
            " sleep_efficiency, sleep_onset_at, wake_onset_at) values " + ", ".join(rows))
    for i in range(60):
        day = TODAY - timedelta(days=59 - i)
        busy = day == YESTERDAY
        steps = 12800 if busy else 8000 + 400 * (i % 5)
        total = 2750 if busy else 2300 + 20 * (i % 6)
        energy = {"total_kcal": total, "resting_kcal": 1620, "active_kcal": total - 1620,
                  "workout_kcal": 310 if busy else 0, "light_min": 190, "moderate_min": 70 if busy else 25,
                  "high_min": 8 if busy else 2, "coverage_min": 1380, "gap_min": 60, "confidence": 0.7,
                  "workouts": [{"start": local(day, 7, 30), "end": local(day, 8, 15)}] if busy else []}
        daily = {"steps": steps, "activeKcalEst": total, "energy": energy,
                 "spo2_candidate_pct": 93 if day == TODAY else 96 + (i % 2), "spo2_candidate_samples": 40}
        pg.psql(f"insert into public.scoring_snapshots_v2(user_id, device_id, day, algorithm_version, input_revision,"
                f" computed_at, payload) values ('{USER}', '{DEVICE}', '{day}', 'frwhoop-server-1', 1, now(),"
                f" $p${json.dumps({'daily': daily})}$p$::jsonb)")
        awake = 71.0 if busy else 64.0 + (i % 3) - 1
        values = [{"series_key": "heart_rate.stable_awake_5min", "value": awake, "units": "bpm", "support_count": 40,
                   "support_unit": "window"}]
        values += [{"series_key": f"heart_rate.stable_awake_5min.{band}", "value": awake + delta, "units": "bpm"}
                   for band, delta in (("band_06_12", -1.0), ("band_12_18", 3.0 if busy else 1.0),
                                       ("band_18_24", 0.0))]
        document = {"status": "available", "daily_values": values}
        if busy:
            document["comparisons"] = [{"series_key": "heart_rate.stable_awake_5min", "view": "rolling",
                                        "status": "ready", "center": 64.0, "signed_difference": 7.0, "robust_z": 2.8,
                                        "support_days": 28, "regime_key": "r"}]
            document["episodes"] = [{"series_key": "heart_rate.stable_awake_5min", "regime_key": "r",
                                     "state": "transient_deviation", "direction": 1, "start_day": str(day),
                                     "last_day": str(day), "duration_days": 1, "ongoing": True}]
        pg.psql("insert into public.physiology_context_days(user_id, device_id, day, mode, job_revision, finality,"
                " status, availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint,"
                f" input_fingerprint, document, document_bytes) values ('{USER}', '{DEVICE}', '{day}', 'retrospective',"
                " 1, 'final', 'available', 1791400000, 1791400000, 'physiology-context-1', 1, 'smoke-policy',"
                f" 'smoke-input', $d${json.dumps(document)}$d$::jsonb, 100)")
    # ElderNet: yesterday's brisk morning walk and an afternoon stroll; the days before from their summaries.
    windows = []
    for start, minutes, cadence, speed in ((local(YESTERDAY, 7, 30), 45, 116, 1.5), (local(YESTERDAY, 17), 20, 92, 1.1)):
        windows += [(t, cadence + (k % 5) - 2, speed) for k, t in enumerate(range(start, start + minutes * 60, 5))]
    by_utc: dict[date, list] = {}
    for t, cadence, speed in windows:
        by_utc.setdefault(datetime.fromtimestamp(t, ZoneInfo("UTC")).date(), []).append((t, cadence, speed))
    gait_days = {d: w for d, w in by_utc.items()}
    for k in range(2, 12):
        gait_days.setdefault(YESTERDAY - timedelta(days=k), None)
    for day, day_windows in sorted(gait_days.items()):
        if day_windows:
            n = len(day_windows)
            columns = {"format": "gait-windows-1", "n": n, "w": 10, "h": 5, "s0": day_windows[0][0],
                       "ds": [0] + [b[0] - a[0] for a, b in zip(day_windows, day_windows[1:])], "gp": [950] * n,
                       "g": [1] * n, "pf": [0] * n, "sp": [round(s * 100) for _, _, s in day_windows],
                       "cad": [c for _, c, _ in day_windows], "st": [round(s / c * 12000) for _, c, s in day_windows],
                       "rg": [82] * n, "stp": [round(c / 6 * 10) for _, c, _ in day_windows]}
            n_gait, summary = n, {"gait": {"cadence_spm": 108, "speed_mps": 1.35}}
        else:
            columns, n_gait, summary = None, 300 + 20 * (day.day % 7), {"gait": {"cadence_spm": 101, "speed_mps": 1.2}}
        pg.psql("insert into public.activity_gait_windows_days(user_id, device_id, day, model_version, mode,"
                " algorithm_version, model_id, weights, weights_digest, upstream_commit, preprocessing_version,"
                " gait_schema, job_fingerprint, input_revision, window_s, hop_s, gait_threshold, n_windows, n_gait,"
                " n_prefiltered, n_dropped, summary, windows, result_revision, computed_at) values"
                f" ('{USER}', '{DEVICE}', '{day}', 'eldernet-437a38b', 'shadow', 'gait-1', 'eldernet', '{{}}',"
                f" '{'a' * 64}', '437a38bc', 'pre-1', 'gait-quality-1', '{'b' * 64}', 1, 10, 5, 0.5, 17280, {n_gait},"
                f" 9000, 0, $s${json.dumps(summary)}$s$::jsonb,"
                f" {'null' if columns is None else '$w$' + json.dumps(columns) + '$w$::jsonb'}, 1, now())")
    coffee = local(YESTERDAY, 14)
    event = {"event_id": "coffee-1", "revision": 1, "kind": "caffeine", "label": "Coffee",
             "occurred": {"start": coffee, "end": coffee + 300}, "time_precision": "exact",
             "recorded_at": coffee + 600, "source": "user_entered", "confirmation": "confirmed"}
    pg.psql(f"select public.record_exposure_event_v1('{USER}', null, $ex${json.dumps(event)}$ex$::jsonb)")


def main() -> None:
    base = Path(tempfile.mkdtemp(prefix="mi-pg-", dir="/tmp"))
    work = Path(tempfile.mkdtemp(prefix="mis-", dir="/tmp"))
    pg = LocalPostgres(base).start()
    try:
        (base / "db_url").write_text(pg.url)
        seed(pg)
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
        for metric in METRICS:
            first = json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', '{metric}')"))
            # One metric at a time: an earlier metric's retry must not be the job this run claims.
            pg.psql(f"update public.metric_insight_jobs set not_before = case when metric = '{metric}' then now()"
                    f" else now() + interval '1 day' end where user_id = '{USER}'")
            started = time.monotonic()
            outcome = worker.once() if first["status"] == "pending" else first["status"]
            response = json.loads(pg.psql(f"select public.metric_insight_request_v1('{USER}', '{metric}')"))
            insight = response.get("insight") or {}
            print(f"\n=== {metric}: {outcome} in {round(time.monotonic() - started, 1)} s, data through "
                  f"{insight.get('data_through')}")
            print(json.dumps({k: insight.get(k) for k in ("headline", "observed", "interpretation", "uncertainty")},
                             indent=1, ensure_ascii=False))
            print("citations:", [(c.get("title") or "")[:80] for c in insight.get("citations") or []])
            print(pg.psql(f"select coalesce(last_error, '-') from public.metric_insight_jobs where user_id = '{USER}'"
                          f" and metric = '{metric}'"))
        worker.db.conn.close()
    finally:
        pg.stop()
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
