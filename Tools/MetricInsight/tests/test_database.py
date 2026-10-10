"""Owner-scoped reads, the queue and the worker's no-model path on a throwaway PostgreSQL (full migration chain)."""

from __future__ import annotations

import json
import sys
from datetime import date, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from nara_metric_insight import worker as worker_module
from nara_metric_insight.config import Config
from nara_metric_insight.db import Database, IsolationError, connect
from nara_metric_insight.sources import Sources
from nara_metric_insight.worker import AnalysisRejected, Worker

from .conftest import DEVICE_A, DEVICE_B, USER_A, USER_B

pytestmark = pytest.mark.pg
ANCHOR = date(2026, 10, 6)


def seed(pg, user: str, device: str, values: list[float | None], end: date = ANCHOR) -> None:
    rows = []
    for i, value in enumerate(values):
        day = end - timedelta(days=len(values) - 1 - i)
        rows.append(f"('{user}', '{day}', 'frwhoop-server-1', '{device}', {'null' if value is None else value}, 70)")
    pg.psql("insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm,"
            " hrv_rmssd_ms) values " + ", ".join(rows) + " on conflict (user_id, day, algorithm_version) do update"
            " set resting_hr_bpm = excluded.resting_hr_bpm")


@pytest.fixture()
def db(pg):
    pg.psql("truncate public.server_daily_scores, public.metric_insight_jobs, public.metric_insights,"
            " public.coach_memory_items, public.physiology_context_days, public.activity_gait_windows_days,"
            " public.scoring_snapshots_v2, public.scoring_jobs_v2 cascade")
    database = Database(connect(pg.url))
    yield database
    database.conn.close()


def test_owner_reads_see_only_the_owner_and_cannot_write(pg, db):
    seed(pg, USER_A, DEVICE_A, [50, 51, 49])
    seed(pg, USER_B, DEVICE_B, [60, 61])
    pg.psql(f"insert into public.coach_memory_items(user_id, content, importance) values"
            f" ('{USER_A}', 'A note', 3), ('{USER_B}', 'B note', 5)")

    def everything(cur):  # no user filter at all: row-level security decides
        cur.execute("select distinct user_id::text as u from public.server_daily_scores")
        return [r["u"] for r in cur.fetchall()]
    assert db.as_owner(USER_A, everything) == [USER_A]
    assert db.as_owner(USER_B, everything) == [USER_B]

    def write(cur):
        cur.execute("delete from public.server_daily_scores")
    with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
        db.as_owner(USER_A, write)
    with pytest.raises(IsolationError):  # the database must echo back exactly the owner the job names
        db.as_owner("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", everything)

    sources = Sources(db, USER_A, "resting_hr", ANCHOR, ZoneInfo("UTC"))
    assert sorted(sources.scores()) == [ANCHOR - timedelta(days=2), ANCHOR - timedelta(days=1), ANCHOR]
    assert [m["content"] for m in sources.memory()] == ["A note"]
    assert sources.context() == (None, None)
    assert sources.loaded == ["scores", "memory", "device", "context"]


def test_memory_is_the_active_rows_sana_uses_and_only_they_move_the_fingerprint(pg, db):
    seed(pg, USER_A, DEVICE_A, [50, 51, 49])
    pg.psql(f"insert into public.coach_memory_items(user_id, content, topic, importance) values"
            f" ('{USER_A}', 'Trains for a marathon', 'goal', 3)")

    def fingerprint() -> str:
        return pg.psql(f"select fingerprint from internal.metric_insight_inputs('{USER_A}', 'resting_hr')")
    active = fingerprint()
    # A retired row (merged away, contradicted, evicted) with the highest importance: neither read nor an input.
    pg.psql(f"insert into public.coach_memory_items(user_id, content, topic, importance, retired_at, retired_reason)"
            f" values ('{USER_A}', 'Used to run ultras', 'achievement', 5, now(), 'merged')")
    sources = Sources(db, USER_A, "resting_hr", ANCHOR, ZoneInfo("UTC"))
    assert [m["content"] for m in sources.memory()] == ["Trains for a marathon"]
    assert fingerprint() == active
    # Retiring the active row takes it out of both too.
    pg.psql(f"update public.coach_memory_items set retired_at = now(), retired_reason = 'contradicted'"
            f" where user_id = '{USER_A}' and content = 'Trains for a marathon'")
    assert Sources(db, USER_A, "resting_hr", ANCHOR, ZoneInfo("UTC")).memory() == []
    assert fingerprint() != active


def _devices(pg) -> None:
    pg.psql(f"insert into public.devices(id, user_id, source_kind, external_device_id) values"
            f" ('{DEVICE_A}', '{USER_A}', 'noop_push', 'whoop-A'), ('{DEVICE_B}', '{USER_B}', 'noop_push', 'whoop-B')"
            " on conflict do nothing")


def _snapshot(pg, user: str, device: str, day: date, daily: dict) -> None:
    """A scored day as production has it: its scoring job (selected_scoring_device_v2 picks among them) and the
    snapshot it published."""
    pg.psql("insert into public.scoring_jobs_v2(user_id, device_id, day, algorithm_version, input_revision,"
            f" completed_revision) values ('{user}', '{device}', '{day}', 'frwhoop-server-1', 1, 1)"
            " on conflict do nothing")
    pg.psql("insert into public.scoring_snapshots_v2(user_id, device_id, day, algorithm_version, input_revision,"
            f" computed_at, payload) values ('{user}', '{device}', '{day}', 'frwhoop-server-1', 1, now(),"
            f" $j${json.dumps({'daily': daily})}$j$::jsonb)")


def test_day_values_stable_awake_heart_rate_and_gait_are_the_owners_own(pg, db):
    pg.psql("truncate public.scoring_jobs_v2, public.scoring_snapshots_v2, public.physiology_context_days,"
            " public.activity_gait_windows_days cascade")
    _devices(pg)
    seed(pg, USER_A, DEVICE_A, [50, 51, 49])
    seed(pg, USER_B, DEVICE_B, [60, 61])
    for user, device, steps in ((USER_A, DEVICE_A, 8123), (USER_B, DEVICE_B, 999)):
        for offset in (2, 1, 0):
            energy = {"total_kcal": 2300 + offset, "resting_kcal": 1600, "active_kcal": 700 + offset,
                      "workout_kcal": 0, "light_min": 200, "workouts": [], "model_version": "fusion-1"}
            _snapshot(pg, user, device, ANCHOR - timedelta(days=offset),
                      {"steps": steps + offset, "activeKcalEst": 2300 + offset, "energy": energy,
                       **({"spo2_candidate_pct": 96, "spo2_candidate_samples": 40} if offset == 0 else {})})
    _snapshot(pg, USER_A, DEVICE_A, ANCHOR - timedelta(days=3), {"steps": "lots", "activeKcalEst": True})

    def day_values(start, end):
        def read(cur):
            cur.execute("select * from public.metric_insight_day_values_v1(%s, %s)", (start, end))
            return cur.fetchall()
        return read
    mine = db.as_owner(USER_A, day_values(ANCHOR - timedelta(days=5), ANCHOR))
    # A value that is not a JSON number (a string, a boolean) is no value, never zero; only the owner's rows.
    assert [(r["day"], r["steps"], r["total_kcal"]) for r in mine] == [
        (ANCHOR - timedelta(days=3), None, None), (ANCHOR - timedelta(days=2), 8125, 2302),
        (ANCHOR - timedelta(days=1), 8124, 2301), (ANCHOR, 8123, 2300)]
    assert mine[-1]["spo2_candidate_pct"] == 96 and mine[-1]["energy"]["active_kcal"] == 700
    assert "model_version" not in mine[-1]["energy"]  # only the parts an explanation reads
    assert [r["steps"] for r in db.as_owner(USER_B, day_values(ANCHOR - timedelta(days=5), ANCHOR))] == [1001, 1000, 999]
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        db.as_owner(USER_A, day_values(ANCHOR - timedelta(days=401), ANCHOR))

    # Stable awake heart rate, picked as the app's chart picks it: the retrospective document first, else the live
    # one; in a document the best-supported value (a zero is no value); another owner's never.
    def context(user, device, day, mode, value, also=()):
        document = {"daily_values": [*also, {"series_key": "heart_rate.stable_awake_5min", "value": value,
                                             "units": "bpm", "support_count": 30, "regime_key": "b"},
                                     {"series_key": "hrv_rmssd.sleep_night", "value": 70}], "status": "available"}
        pg.psql("insert into public.physiology_context_days(user_id, device_id, day, mode, job_revision, finality,"
                " status, availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint,"
                f" input_fingerprint, document, document_bytes) values ('{user}', '{device}', '{day}', '{mode}', 1,"
                " 'provisional', 'available', 1791400000, 1791400000, 'physiology-context-1', 1, 'fixture-policy',"
                f" 'fixture-input', $j${json.dumps(document)}$j$::jsonb, 100)")
    context(USER_A, DEVICE_A, ANCHOR - timedelta(days=1), "causal_live", 66.0)
    context(USER_A, DEVICE_A, ANCHOR - timedelta(days=1), "retrospective", 64.0)
    context(USER_A, DEVICE_A, ANCHOR, "causal_live", 63.0, also=(
        {"series_key": "heart_rate.stable_awake_5min", "value": 0, "support_count": 99, "regime_key": "a"},
        {"series_key": "heart_rate.stable_awake_5min", "value": 61.0, "support_count": 12, "regime_key": "a"}))
    context(USER_A, DEVICE_A, ANCHOR - timedelta(days=2), "retrospective", 65.0, also=(
        {"series_key": "heart_rate.stable_awake_5min", "value": 67.0, "support_count": 30, "regime_key": "a"},))
    context(USER_B, DEVICE_B, ANCHOR, "retrospective", 90.0)
    rows = Sources(db, USER_A, "heart_rate", ANCHOR, ZoneInfo("UTC")).scores()
    assert {d: r.get("stable_awake_hr_bpm") for d, r in rows.items() if r.get("stable_awake_hr_bpm")} == {
        ANCHOR - timedelta(days=2): 67.0, ANCHOR - timedelta(days=1): 64.0, ANCHOR: 63.0}
    assert rows[ANCHOR]["steps"] == 8123 and rows[ANCHOR]["resting_hr_bpm"] == 49  # steps are related, merged per day

    # ElderNet gait rows: the owner's own, per UTC day the newest result.
    def gait_row(user, device, day, n_gait):
        windows = {"format": "gait-windows-1", "n": 1, "w": 10, "h": 5, "s0": 1791200000, "ds": [0], "gp": [950],
                   "g": [1], "pf": [0], "sp": [130], "cad": [108], "st": [140], "rg": [80], "stp": [180]}
        pg.psql("insert into public.activity_gait_windows_days(user_id, device_id, day, model_version, mode,"
                " algorithm_version, model_id, weights, weights_digest, upstream_commit, preprocessing_version,"
                " gait_schema, job_fingerprint, input_revision, window_s, hop_s, gait_threshold, n_windows, n_gait,"
                " n_prefiltered, n_dropped, summary, windows, result_revision, computed_at) values"
                f" ('{user}', '{device}', '{day}', 'eldernet-437a38b', 'shadow', 'gait-1', 'eldernet', '{{}}',"
                f" '{'a' * 64}', '437a38bc', 'pre-1', 'gait-quality-1', '{'b' * 64}', 1, 10, 5, 0.5, 100, {n_gait},"
                " 10, 0, '{\"gait\": {\"cadence_spm\": 104}}', $j$" + json.dumps(windows) + "$j$::jsonb, 1, now())")
    gait_row(USER_A, DEVICE_A, ANCHOR, 40)
    gait_row(USER_B, DEVICE_B, ANCHOR, 70)
    days = Sources(db, USER_A, "steps", ANCHOR, ZoneInfo("UTC")).gait_days()
    assert [(d["day"], d["n_gait"]) for d in days] == [(ANCHOR, 40)]
    assert days[0]["windows"]["format"] == "gait-windows-1" and days[0]["gait"] == {"cadence_spm": 104}


def config(pg, secret_file, tmp_path) -> Config:
    env = {"NARA_DB_URL_FILE": secret_file("db_url", pg.url), "NARA_LLM_API_KEY_FILE": secret_file("llm", "unused"),
           "NARA_LLM_BASE_URL": "http://127.0.0.1:9/v1", "NARA_LLM_MODEL": "fixture",
           "NARA_PRIME_BIN": sys.executable, "NARA_KERNEL_PYTHON": sys.executable,
           "NARA_WORK_ROOT": str(tmp_path / "work"), "NARA_WORKER_ID": "pytest-worker", "NARA_SANDBOX": "macos",
           "NARA_LITERATURE_REMOTE": "none"}
    return Config.from_env(env)


def request(pg, user: str) -> dict:
    return json.loads(pg.psql(f"select public.metric_insight_request_v1('{user}', 'resting_hr')"))


def test_too_few_nights_publish_a_fixed_message_without_a_model(pg, db, secret_file, tmp_path):
    seed(pg, USER_A, DEVICE_A, [None, 52, None, 50])
    assert request(pg, USER_A)["status"] == "pending"
    work = Worker(config(pg, secret_file, tmp_path))
    work.db = db

    def no_model(*args, **kwargs):
        raise AssertionError("Prime must not run for an insufficient-data job")
    original = worker_module.PrimeSession
    worker_module.PrimeSession = no_model
    try:
        assert work.once() == "published"
    finally:
        worker_module.PrimeSession = original
    ready = request(pg, USER_A)
    assert ready["status"] == "ready"
    insight = ready["insight"]
    assert insight["kind"] == "insufficient_data" and insight["headline"] == "Not enough measured nights yet"
    assert insight["observed"] == ["2 nights of resting heart rate measured so far, most recently 50 bpm on Oct 6."]
    assert insight["basis"]["nights"] == 2 and insight["data_through"] == "2026-10-06"
    assert work.once() is None  # cached: nothing left to do


def test_a_rejected_analysis_fails_the_job_and_keeps_it_retryable(pg, db, secret_file, tmp_path, monkeypatch):
    seed(pg, USER_A, DEVICE_A, [50, 51, 49, 52, 48])
    assert request(pg, USER_A)["status"] == "pending"
    work = Worker(config(pg, secret_file, tmp_path))
    work.db = db

    async def rejected(*args, **kwargs):
        raise AnalysisRejected(["grounding", "wording"])
    monkeypatch.setattr(worker_module, "analyse", rejected)
    assert work.once() == "rejected:grounding,wording"
    job = json.loads(pg.psql("select row_to_json(q) from public.metric_insight_jobs q"))
    assert job["consecutive_failures"] == 1 and job["last_error"] == "validation:grounding,wording"
    assert job["lease_token"] is None and job["dead_letter"] is False
    assert request(pg, USER_A)["status"] == "pending"  # the app keeps showing its chart; the card waits


def _jobs(pg) -> dict[str, dict]:
    rows = json.loads(pg.psql("select coalesce(json_agg(row_to_json(q)), '[]') from public.metric_insight_jobs q"))
    return {f"{r['user_id']}:{r['metric']}": r for r in rows}


def _no_model(monkeypatch) -> None:
    def refuse(*args, **kwargs):
        raise AssertionError("Prime must not run for an insufficient-data job")
    monkeypatch.setattr(worker_module, "PrimeSession", refuse)


def test_the_sweep_pregenerates_once_per_new_day_and_never_ahead_of_a_person(pg, db, secret_file, tmp_path,
                                                                           monkeypatch):
    _no_model(monkeypatch)
    today = date.today()
    seed(pg, USER_A, DEVICE_A, [52, 50], end=today - timedelta(days=1))
    seed(pg, USER_B, DEVICE_B, [60, 61], end=today - timedelta(days=10))  # nothing recent: not pre-generated

    assert db.sweep(60) == 2  # resting heart rate and HRV are the only metrics with measured values
    jobs = _jobs(pg)
    assert sorted(k.split(":")[1] for k in jobs) == ["hrv_rmssd", "resting_hr"]
    assert all(k.startswith(USER_A) and j["background"] for k, j in jobs.items())
    assert db.sweep(60) == 0  # already queued: asking again changes nothing

    # A person opens the resting-heart-rate card while both background jobs wait: theirs goes first, although the
    # other was queued earlier in the same sweep and sorts ahead of it by name.
    assert request(pg, USER_A)["status"] == "pending"
    assert _jobs(pg)[f"{USER_A}:resting_hr"]["background"] is False
    assert db.claim("pytest-worker", 300)["metric"] == "resting_hr"
    pg.psql("update public.metric_insight_jobs set lease_token = null, lease_until = null where metric = 'resting_hr'")

    work = Worker(config(pg, secret_file, tmp_path))
    work.db = db
    assert [work.once(), work.once(), work.once()] == ["published", "published", None]
    assert request(pg, USER_A)["status"] == "ready"
    assert db.sweep(60) == 0  # every metric with data has its explanation

    # New inputs for the same day (a re-score) are not pre-generated: the card regenerates when it is opened.
    seed(pg, USER_A, DEVICE_A, [52, 53], end=today - timedelta(days=1))
    assert db.sweep(60) == 0
    # A new measured day is.
    seed(pg, USER_A, DEVICE_A, [53], end=today)
    assert db.sweep(60) == 2
    assert all(j["background"] for k, j in _jobs(pg).items() if j["completed_revision"] < j["input_revision"])
    assert db.sweep(1) == 0


def test_the_sweep_respects_the_batch_limit_the_daily_bound_and_failed_inputs(pg, db):
    today = date.today()
    seed(pg, USER_A, DEVICE_A, [52, 50], end=today)
    assert db.sweep(1) == 1
    assert db.sweep(1) == 1  # the next call queues the next missing one
    assert db.sweep(1) == 0
    # Resting heart rate stays queued. HRV ran out of runs today without publishing: not queued again until tomorrow.
    pg.psql("update public.metric_insight_jobs set completed_revision = input_revision, runs_day = (now() at time zone 'UTC')::date,"
            " runs_count = 8 where metric = 'hrv_rmssd'")
    assert db.sweep(60) == 0
    pg.psql("update public.metric_insight_jobs set runs_count = 0, input_revision = input_revision + 1,"
            " dead_letter = true where metric = 'hrv_rmssd'")
    assert db.sweep(60) == 0  # failed three times on exactly these inputs
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        db.sweep(0)
