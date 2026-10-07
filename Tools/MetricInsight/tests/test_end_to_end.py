"""The RHR slice end to end: request -> queue -> this worker -> a real, sandboxed prime-agent (driven by the
scripted stub model) -> owner-scoped tools -> validator -> publish -> request serves it from cache.

Needs NARA_TEST_PRIME_BIN / NARA_TEST_KERNEL_PYTHON (defaults: the research checkout next to the repository).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path

import pytest

from nara_metric_insight.config import Config
from nara_metric_insight.db import Database, connect
from nara_metric_insight.prompts import GUIDANCE
from nara_metric_insight.worker import Worker

from .conftest import DEVICE_A, DEVICE_B, USER_A, USER_B
from .stub_llm import StubLLM

RESEARCH = Path(__file__).resolve().parents[4] / "research" / "prime-agent"
PRIME_BIN = os.environ.get("NARA_TEST_PRIME_BIN", str(RESEARCH / "target" / "debug" / "prime-agent"))
KERNEL_PYTHON = os.environ.get("NARA_TEST_KERNEL_PYTHON", str(RESEARCH / ".venv" / "bin" / "python"))
pytestmark = [pytest.mark.pg, pytest.mark.prime,
              pytest.mark.skipif(not (os.access(PRIME_BIN, os.X_OK) and os.access(KERNEL_PYTHON, os.X_OK)),
                                 reason="prime-agent binary or kernel Python not available"),
              pytest.mark.skipif(sys.platform != "darwin", reason="the local sandbox is sandbox-exec (macOS)")]
ANCHOR = date(2026, 10, 6)
API_KEY = "provider-key-only-the-proxy-holds"


def seed(pg, user: str, device: str, values: list[float | None]) -> None:
    rows = []
    for i, value in enumerate(values):
        day = ANCHOR - timedelta(days=len(values) - 1 - i)
        rows.append(f"('{user}', '{day}', 'frwhoop-server-1', '{device}', {'null' if value is None else value}, "
                    f"{70 + i}, 14.0, 0.9, {420 + i})")
    pg.psql("insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm,"
            " hrv_rmssd_ms, resp_rate_bpm, sleep_efficiency, sleep_total_min) values " + ", ".join(rows) +
            " on conflict (user_id, day, algorithm_version) do update set resting_hr_bpm = excluded.resting_hr_bpm")


def request(pg, user: str) -> dict:
    return json.loads(pg.psql(f"select public.metric_insight_request_v1('{user}', 'resting_hr')"))


def job(pg) -> dict:
    return json.loads(pg.psql("select row_to_json(q) from public.metric_insight_jobs q where metric = 'resting_hr'"
                              f" and user_id = '{USER_A}'"))


@pytest.fixture(scope="session")
def curated_harness():
    out = Path(tempfile.mkdtemp(prefix="mih-", dir="/tmp"))
    script = Path(__file__).resolve().parents[1] / "scripts" / "build_curated_harness.py"
    built = subprocess.run([KERNEL_PYTHON, str(script), str(out)], capture_output=True, text=True, timeout=120)
    assert built.returncode == 0, built.stderr
    yield built.stdout.strip()
    shutil.rmtree(out, ignore_errors=True)


@pytest.fixture()
def stub():
    server = StubLLM()
    yield server
    server.stop()


@pytest.fixture()
def worker(pg, stub, secret_file, curated_harness):
    pg.psql("truncate public.server_daily_scores, public.metric_insight_jobs, public.metric_insights,"
            " public.coach_memory_items cascade")
    work_root = Path(tempfile.mkdtemp(prefix="mie-", dir="/tmp"))
    env = {"NARA_DB_URL_FILE": secret_file("db_url", pg.url), "NARA_LLM_API_KEY_FILE": secret_file("llm_api_key", API_KEY),
           "NARA_LLM_BASE_URL": stub.url, "NARA_LLM_MODEL": "fixture-model", "NARA_PRIME_BIN": PRIME_BIN,
           "NARA_KERNEL_PYTHON": KERNEL_PYTHON, "NARA_WORK_ROOT": str(work_root), "NARA_WORKER_ID": "pytest-e2e",
           "NARA_SANDBOX": "macos", "NARA_TURN_TIMEOUT_S": "120", "NARA_CURATED_HARNESS": curated_harness,
           "NARA_LITERATURE_REMOTE": "none"}  # tests never reach the network
    instance = Worker(Config.from_env(env))
    instance.db = Database(connect(pg.url))
    yield instance
    instance.db.conn.close()
    assert list(work_root.iterdir()) == [], "a run directory outlived its job"
    shutil.rmtree(work_root, ignore_errors=True)


def tool_outputs(stub: StubLLM) -> list[str]:
    out = []
    for body in stub.requests:
        for message in body.get("messages") or []:
            if message.get("role") == "tool":
                content = message.get("content")
                out.append(content if isinstance(content, str) else json.dumps(content))
    return out


def test_rhr_explained_end_to_end_then_served_from_cache(pg, stub, worker):
    seed(pg, USER_A, DEVICE_A, [47, 50, 51, 53, 51, None, 48, 45])
    seed(pg, USER_B, DEVICE_B, [70, 71, 72, 73])
    pg.psql(f"insert into public.coach_memory_items(user_id, content, importance) values ('{USER_B}', 'B only', 5)")
    assert request(pg, USER_A)["status"] == "pending"

    assert worker.once() == "published"
    ready = request(pg, USER_A)
    assert ready["status"] == "ready"
    insight = ready["insight"]
    assert insight["kind"] == "explained" and insight["data_through"] == "2026-10-06"
    assert insight["headline"] == "Resting heart rate 45 bpm on Oct 6"
    assert insight["observed"] == ["Your resting heart rate was 45 bpm on Oct 6.", "That is 3 bpm lower than on Oct 5."]
    assert insight["basis"]["nights"] == 7 and insight["basis"]["missing_nights"] == 1
    assert [c["id"] for c in insight["citations"]] and all(c["url"].startswith("https://pubmed") for c in insight["citations"])
    related = {r["metric"]: r for r in insight["related"]}
    assert related["hrv_rmssd"]["estimated"] is False and related["resp_rate"]["estimated"] is True

    # Prime ran with Nara's guidance, the provider saw only the proxy's key, and the model loaded data via tools.
    system = json.dumps(stub.requests[0]["messages"][0])
    assert "Nara's metric explanation agent" in system and GUIDANCE.splitlines()[0] in system
    assert set(stub.authorizations) == {f"Bearer {API_KEY}"}
    task = next(m for m in stub.requests[0]["messages"] if m.get("role") == "user")
    assert "53" not in json.dumps(task), "the series itself must not be in the prompt"
    evidence_line = next(o for o in tool_outputs(stub) if "EVIDENCE=" in o)
    probe = json.loads(evidence_line.split("EVIDENCE=", 1)[1].split("\\n")[0].split("\n")[0])["probe"]
    assert probe.pop("global_harness_write") in ("blocked:PermissionError", "blocked:OSError")  # the sandbox, not a typo
    # agent learning reaches the model only as the curated, user-free harness, and nothing is added to it on disk
    assert probe.pop("harness_ids_on_disk") == ["absolute-dates", "estimates", "evidence-first", "rhr-variation",
                                                "short-history"]
    assert probe == {"cross_user": "refused", "internet": "blocked", "secret_like_env": []}
    assert "B only" not in json.dumps(stub.requests) and "73" not in evidence_line

    stored = json.loads(pg.psql(f"select evidence from public.metric_insights where id = {insight['id']}"))
    assert stored["tool_calls"][:4] == ["get_metric_summary", "get_data_quality", "get_related_metrics", "search_literature"]
    assert stored["validator"] == {"attempts": 1, "rejected": []}

    calls = len(stub.requests)
    assert request(pg, USER_A)["status"] == "ready"
    assert worker.once() is None and len(stub.requests) == calls  # unchanged data: no model call at all


def test_a_rejected_answer_is_retried_once_then_published(pg, stub, worker):
    seed(pg, USER_A, DEVICE_A, [52, 50, 49, 53, 51])
    stub.scenario = "retry"
    assert request(pg, USER_A)["status"] == "pending"
    assert worker.once() == "published"
    insight = request(pg, USER_A)["insight"]
    assert "stress" not in json.dumps(insight).lower()
    stored = json.loads(pg.psql(f"select evidence from public.metric_insights where id = {insight['id']}"))
    assert stored["validator"]["attempts"] == 2 and "wording" in stored["validator"]["rejected"]
    assert "retry-answer" in stub.decisions


def test_an_answer_that_never_validates_fails_the_job(pg, stub, worker):
    seed(pg, USER_A, DEVICE_A, [52, 50, 49, 53, 51])
    stub.scenario = "always_bad"
    assert request(pg, USER_A)["status"] == "pending"
    outcome = worker.once()
    assert outcome.startswith("rejected:") and "wording" in outcome
    state = job(pg)
    assert state["consecutive_failures"] == 1 and state["last_error"].startswith("validation:")
    assert request(pg, USER_A)["insight"] is None  # nothing unvalidated ever reaches the app
