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
            " public.coach_memory_items cascade")
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
    assert sources.loaded == ["scores", "memory", "context"]


def config(pg, secret_file, tmp_path) -> Config:
    env = {"NARA_DB_URL_FILE": secret_file("db_url", pg.url), "NARA_LLM_API_KEY_FILE": secret_file("llm", "unused"),
           "NARA_LLM_BASE_URL": "http://127.0.0.1:9/v1", "NARA_LLM_MODEL": "fixture",
           "NARA_PRIME_BIN": sys.executable, "NARA_KERNEL_PYTHON": sys.executable,
           "NARA_WORK_ROOT": str(tmp_path / "work"), "NARA_WORKER_ID": "pytest-worker", "NARA_SANDBOX": "macos"}
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
