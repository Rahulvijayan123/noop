"""Bounded execution: admission, worker processes, budgets (spec 01 section 5).

Real worker processes, real HTTP, short budgets. The providers and sleep-feature entry
points are in ``execution_fakes`` so a worker can import them; they import nothing heavy,
so a worker starts in well under a second.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

import pytest

from conftest import MANIFEST_PATH, hrv_body
from execution_fakes import (
    PROBE_FILE_ENV,
    CrashingProvider,
    LoadedIdentityProvider,
    ProbeProvider,
    SlowProvider,
    SpinningProvider,
)
from frwhoop_inference.contract import Beat, Window
from frwhoop_inference.execution import MATH_THREAD_ENV, ExecutionConfig
from frwhoop_inference.providers import ProviderRegistry
from frwhoop_inference.providers.hrv import HrvProductionProvider
from frwhoop_inference.server import Application, InferenceServer

#: Tight limits so every bound is reached quickly.
BASE_ENV = {
    "FRWHOOP_INFERENCE_MAX_ACTIVE": "1",
    "FRWHOOP_INFERENCE_MAX_WAITING": "0",
    "FRWHOOP_INFERENCE_QUEUE_WAIT_MS": "0",
    "FRWHOOP_INFERENCE_KILL_GRACE_MS": "200",
    "FRWHOOP_INFERENCE_START_WAIT_MS": "20000",
    "FRWHOOP_INFERENCE_START_TIMEOUT_MS": "60000",
    "FRWHOOP_SLEEP_FEATURES_MAX_ACTIVE": "1",
    "FRWHOOP_SLEEP_FEATURES_MAX_WAITING": "0",
    "FRWHOOP_SLEEP_FEATURES_QUEUE_WAIT_MS": "0",
    "FRWHOOP_SLEEP_FEATURES_BUDGET_MS": "300",
    "FRWHOOP_INFERENCE_HTTP_THREADS": "6",
    "FRWHOOP_INFERENCE_HTTP_BACKLOG": "8",
}


def _beats(count: int = 60) -> list[Beat]:
    return [Beat(ts=1_700_000_000 + i, rr_ms=1000.0, seq=i, ord=i) for i in range(count)]


def _infer_body(provider_id: str | None = None) -> dict[str, Any]:
    beats = _beats()
    return hrv_body(beats, window=Window(start=beats[0].ts - 5, end=beats[-1].ts + 5),
                    provider_id=provider_id)


def _features_body() -> dict[str, Any]:
    """A small request the sleep-features contract accepts (one 1 h night)."""
    start = 1_791_241_200  # 2026-10-04T23:00:00Z
    end = start + 3600
    return {
        "schema_version": 1,
        "algorithm_version": "nara-sleep-features-1",
        "context": {
            "user_id": "u-exec", "device_id": "d-exec", "day": "2026-10-05",
            "iana_timezone": "UTC", "input_revision": 3,
            "interval_start_utc": "2026-10-05T00:00:00Z",
            "interval_end_utc": "2026-10-06T00:00:00Z",
            "stage_algorithm_version": "frwhoop-server-1",
        },
        "nights": [{"night_id": "night-exec", "start_utc": "2026-10-04T23:00:00Z",
                    "end_utc": "2026-10-05T00:00:00Z", "is_nap": False, "user_edited": False,
                    "stages": [{"start": start, "end": end, "stage": "light"}]}],
        "hr_samples": [{"ts": ts, "bpm": 60.0} for ts in range(start, end, 5)],
        "skin_temp_samples": [],
        "rr_beats": [],
        "resp_breaths": {"intervals": [], "runs": []},
    }


@dataclass
class Bounded:
    server: InferenceServer
    base_url: str

    def request(self, method: str, path: str, body: Any = None,
                timeout: float = 30.0) -> tuple[int, dict[str, str], dict[str, Any]]:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, dict(response.headers), json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers), json.loads(exc.read())

    def post(self, path: str, body: Any, timeout: float = 30.0):
        return self.request("POST", path, body, timeout)

    def health(self) -> dict[str, Any]:
        status, _, body = self.request("GET", "/healthz", timeout=5.0)
        assert status == 200
        return body

    def lane(self, name: str) -> dict[str, Any]:
        return self.health()["execution"]["lanes"][name]

    def lane_direct(self, name: str) -> dict[str, Any]:
        """The lane state without an HTTP request (for tests that hold every handler)."""
        return self.server.lanes[name].snapshot()

    def wait_ready(self, name: str = "infer", timeout: float = 30.0) -> bool:
        return self.server.lanes[name].wait_ready(timeout)

    def wait_lane(self, name: str, predicate: Callable[[dict[str, Any]], bool],
                  timeout: float = 30.0, direct: bool = False) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            lane = self.lane_direct(name) if direct else self.lane(name)
            if predicate(lane):
                return lane
            assert time.monotonic() < deadline, f"lane {name} never reached the state: {lane}"
            time.sleep(0.05)


@pytest.fixture
def bounded():
    servers: list[InferenceServer] = []

    def factory(providers: list[Any], *, timeout_ms: int = 300, env: dict[str, str] | None = None,
                compute: str | None = None, readiness: str = "inline") -> Bounded:
        app = Application.build(registry=ProviderRegistry(providers), manifest_path=MANIFEST_PATH,
                                timeout_ms=timeout_ms, provider_readiness=readiness)
        config = ExecutionConfig.from_env({**BASE_ENV, **(env or {})})
        kwargs = {"sleep_features_compute": compute} if compute else {}
        server = InferenceServer(("127.0.0.1", 0), app, execution=config, **kwargs)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                         daemon=True).start()
        servers.append(server)
        return Bounded(server=server, base_url=f"http://127.0.0.1:{server.server_address[1]}")

    yield factory
    for server in servers:
        server.shutdown()
        server.server_close()


def _children() -> list[tuple[int, str]]:
    """Live (and zombie) child processes of this test process: ``(pid, stat)``."""
    out = subprocess.run(["ps", "-A", "-o", "ppid=,pid=,stat="], capture_output=True,
                         text=True, check=True).stdout
    me = os.getpid()
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and int(parts[0]) == me:
            rows.append((int(parts[1]), parts[2]))
    return rows


def _worker_children(server: InferenceServer) -> list[tuple[int, str]]:
    """Children that are (or were) one of this server's workers, the ``ps`` probe excluded."""
    known = set()
    for lane in server.lanes.values():
        known.update(lane.worker_pids())
    return [(pid, stat) for pid, stat in _children()
            if pid in known or "python" in _command(pid)]


def _command(pid: int) -> str:
    out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    return out.stdout.strip()


def _alive(pid: int) -> bool:
    """True while ``pid`` exists in any form (a zombie included: unreaped is still there)."""
    out = subprocess.run(["ps", "-o", "pid=", "-p", str(pid)], capture_output=True, text=True)
    return bool(out.stdout.strip())


# -- configuration ----------------------------------------------------------


def test_defaults_are_the_measured_capacity():
    config = ExecutionConfig.from_env({})
    assert config.infer.workers == 1
    assert config.sleep_features.workers == 1
    assert config.infer.max_waiting == 2 and config.sleep_features.max_waiting == 1
    assert config.infer.queue_wait_ms == 250
    assert config.sleep_features_budget_ms == 3000
    assert config.math_threads == 1
    assert config.http_threads == 12


def test_configuration_is_clamped_not_trusted(capsys):
    config = ExecutionConfig.from_env({
        "FRWHOOP_INFERENCE_MAX_ACTIVE": "64", "FRWHOOP_INFERENCE_QUEUE_WAIT_MS": "nope",
        "FRWHOOP_INFERENCE_MATH_THREADS": "0", "FRWHOOP_SLEEP_FEATURES_BUDGET_MS": "9000"})
    assert config.infer.workers == 8
    assert config.infer.queue_wait_ms == 250
    assert config.math_threads == 1
    assert config.sleep_features_budget_ms == 9000
    assert "FRWHOOP_INFERENCE_MAX_ACTIVE" in capsys.readouterr().err


def test_an_unpicklable_registry_is_refused_at_startup():
    class LocalProvider(HrvProductionProvider):
        provider_id = "local.runs.v1"

    app = Application.build(registry=ProviderRegistry([LocalProvider()]), manifest_path=MANIFEST_PATH)
    with pytest.raises(ValueError, match="cannot be sent to a worker process"):
        InferenceServer(("127.0.0.1", 0), app, execution=ExecutionConfig.from_env(BASE_ENV))


# -- /v1/infer --------------------------------------------------------------


def test_repeated_timeouts_never_grow_processes_or_threads(bounded):
    """The acceptance case: a provider that computes past its budget, five times over."""
    server = bounded([SpinningProvider(seconds=30)], timeout_ms=200)
    assert server.wait_ready()
    threads_before = threading.active_count()
    seen_pids: list[int] = []
    for attempt in range(5):
        lane = server.wait_lane("infer", lambda l: l["ready"] == 1)
        pid = lane["workers"][0]["pid"]
        seen_pids.append(pid)
        started = time.monotonic()
        status, _, body = server.post("/v1/infer", _infer_body())
        assert status == 200, body
        assert body["status"] == "withheld" and body["withheld_reason"] == "timeout"
        assert body["diagnostics"]["worker_terminated"] is True
        assert time.monotonic() - started < 2.0
        # At most one worker process exists at any time, and the overrun one goes away.
        assert len(_worker_children(server.server)) <= 1
        server.wait_lane("infer", lambda l: l["ready"] == 1)
        assert not _alive(pid), f"worker {pid} must be terminated and reaped"
        assert threading.active_count() <= threads_before, "no thread may be left computing"
    assert len(set(seen_pids)) == 5, "every overrun replaced its process"
    counters = server.lane("infer")["counters"]
    assert counters["timeouts"] == 5
    assert counters["terminations"] == 5
    assert counters["respawns"] == 5
    assert len(_worker_children(server.server)) == 1


def test_busy_answer_while_every_slot_is_held(bounded):
    server = bounded([SlowProvider(seconds=1.5)], timeout_ms=5_000)
    assert server.wait_ready()
    holder: dict[str, Any] = {}
    thread = threading.Thread(target=lambda: holder.update(
        result=server.post("/v1/infer", _infer_body())))
    thread.start()
    server.wait_lane("infer", lambda l: l["active"] == 1)

    started = time.monotonic()
    status, headers, body = server.post("/v1/infer", _infer_body())
    assert time.monotonic() - started < 1.0, "busy must be answered at once"
    assert status == 429
    assert body["status"] == "error" and body["error"]["code"] == "busy"
    assert body["error"]["lane"] == "infer"
    assert int(headers["Retry-After"]) >= 1
    assert body["error"]["retry_after_s"] == int(headers["Retry-After"])

    # /healthz stays answerable while the only slot computes.
    started = time.monotonic()
    lane = server.lane("infer")
    assert time.monotonic() - started < 1.0
    assert lane["active"] == 1 and lane["counters"]["busy_rejections"] == 1

    thread.join(10)
    status, _, body = holder["result"]
    assert status == 200 and body["status"] == "ok", "the admitted request still completes"


def test_a_short_queue_wait_then_busy(bounded):
    server = bounded([SlowProvider(seconds=2.0)], timeout_ms=5_000,
                     env={"FRWHOOP_INFERENCE_MAX_WAITING": "1",
                          "FRWHOOP_INFERENCE_QUEUE_WAIT_MS": "300"})
    assert server.wait_ready()
    thread = threading.Thread(target=lambda: server.post("/v1/infer", _infer_body()))
    thread.start()
    server.wait_lane("infer", lambda l: l["active"] == 1)
    started = time.monotonic()
    status, _, body = server.post("/v1/infer", _infer_body())
    waited = time.monotonic() - started
    assert status == 429 and body["error"]["code"] == "busy"
    assert 0.25 <= waited < 1.5, f"the bounded wait is ~300 ms, took {waited:.2f}s"
    thread.join(10)


def test_the_slot_frees_only_after_the_process_is_terminated_and_reaped(bounded):
    server = bounded([SpinningProvider(seconds=30)], timeout_ms=250,
                     env={"FRWHOOP_INFERENCE_KILL_GRACE_MS": "300"})
    assert server.wait_ready()
    old_pid = server.lane("infer")["workers"][0]["pid"]
    status, _, body = server.post("/v1/infer", _infer_body())
    assert status == 200 and body["withheld_reason"] == "timeout"
    # Straight after the timeout the slot is out of service, so a new request is refused...
    status, _, body = server.post("/v1/infer", _infer_body())
    assert status == 429 and body["error"]["code"] == "busy", body
    # ...and when the slot is back, the overrun process no longer exists in any form.
    lane = server.wait_lane("infer", lambda l: l["ready"] == 1)
    assert lane["workers"][0]["pid"] != old_pid
    assert not _alive(old_pid)
    assert lane["last_exit"] and str(old_pid) in lane["last_exit"]


def test_a_crashed_worker_is_respawned(bounded):
    server = bounded([CrashingProvider(), HrvProductionProvider()], timeout_ms=5_000)
    assert server.wait_ready()
    old_pid = server.lane("infer")["workers"][0]["pid"]
    status, _, body = server.post("/v1/infer", _infer_body(provider_id="crash.runs.v1"))
    assert status == 500
    assert body["error"]["code"] == "provider_error"
    assert "worker process exited" in body["error"]["message"]
    lane = server.wait_lane("infer", lambda l: l["ready"] == 1)
    assert lane["workers"][0]["pid"] != old_pid and not _alive(old_pid)
    assert lane["counters"]["crashes"] == 1 and lane["counters"]["respawns"] == 1
    status, _, body = server.post("/v1/infer", _infer_body(provider_id="production.runs.v1"))
    assert status == 200 and body["status"] == "ok", "the replacement serves the next request"


def test_a_worker_that_dies_while_idle_is_replaced(bounded):
    server = bounded([HrvProductionProvider()], timeout_ms=5_000)
    assert server.wait_ready()
    old_pid = server.lane("infer")["workers"][0]["pid"]
    os.kill(old_pid, signal.SIGKILL)
    lane = server.wait_lane("infer", lambda l: l["ready"] == 1 and l["workers"][0]["pid"] != old_pid)
    assert lane["counters"]["crashes"] == 1
    assert not _alive(old_pid)
    status, _, body = server.post("/v1/infer", _infer_body())
    assert status == 200 and body["status"] == "ok"


def test_the_registry_is_warmed_once_per_process_not_per_request(bounded, tmp_path, monkeypatch):
    probe = tmp_path / "probe.log"
    monkeypatch.setenv(PROBE_FILE_ENV, str(probe))
    server = bounded([ProbeProvider()], timeout_ms=5_000)
    assert server.wait_ready()
    worker_pid = server.lane("infer")["workers"][0]["pid"]
    for _ in range(3):
        status, _, body = server.post("/v1/infer", _infer_body())
        assert status == 200 and body["status"] == "ok"
        assert body["diagnostics"]["probe"]["pid"] == worker_pid
        # The numerical-library caps were in the worker's environment before it imported.
        assert set(body["diagnostics"]["probe"]["env"].values()) == {"1"}
    events = [line.split() for line in probe.read_text().splitlines()]
    assert events.count(["warm", str(worker_pid)]) == 1, events
    assert events.count(["infer", str(worker_pid)]) == 3
    assert ["infer", str(os.getpid())] not in events, "the HTTP process never computes"
    hello_env = server.server.lanes["infer"]._workers[0].hello["math_threads"]
    assert set(hello_env) == set(MATH_THREAD_ENV) and set(hello_env.values()) == {"1"}


def test_worker_reported_readiness_is_adopted_once(bounded):
    server = bounded([HrvProductionProvider()], timeout_ms=5_000, readiness="worker")
    health = server.health()
    assert health["execution"]["provider_readiness"]["source"] == "worker"
    # Not yet reported: a request is "come back later", not a verdict on the provider.
    if health["execution"]["provider_readiness"]["reported_at_utc"] is None:
        status, headers, body = server.post("/v1/infer", _infer_body())
        assert status == 429 and body["error"]["code"] == "busy" and "Retry-After" in headers
    assert server.wait_ready()
    deadline = time.monotonic() + 10
    while server.health()["execution"]["provider_readiness"]["reported_at_utc"] is None:
        assert time.monotonic() < deadline
        time.sleep(0.05)
    health = server.health()
    assert health["providers"]["production.runs.v1"]["ready"] is True
    assert health["providers"]["production.runs.v1"]["reason"] is None
    assert server.server.app.adopt_worker_readiness({"production.runs.v1": [False, "x"]}) is False
    status, _, body = server.post("/v1/infer", _infer_body())
    assert status == 200 and body["status"] == "ok"


def test_healthz_reports_what_the_warm_worker_loaded(bounded):
    # Checkpoints load in the worker process, so /healthz must show the worker's own report, not
    # what the HTTP process's unloaded copy of the provider would say.
    server = bounded([LoadedIdentityProvider()], timeout_ms=5_000)
    assert server.wait_ready()
    deadline = time.monotonic() + 10
    while True:
        entry = server.health()["identity"]["providers"]["loaded.runs.v1"]
        if entry.get("loaded_source") == "worker":
            break
        assert time.monotonic() < deadline, entry
        time.sleep(0.05)
    workers = set(server.server.lanes["infer"].worker_pids())
    assert entry["loaded"]["checkpoint_sha256"] == "ab" * 32
    assert int(entry["loaded"]["measured_in_pid"]) in workers
    assert int(entry["loaded"]["measured_in_pid"]) != os.getpid()


# -- /v1/sleep-features -----------------------------------------------------


def test_sleep_features_timeouts_terminate_and_stay_bounded(bounded):
    server = bounded([HrvProductionProvider()], compute="execution_fakes:spinning_compute")
    assert server.wait_ready("sleep_features")
    seen = []
    for _ in range(3):
        lane = server.wait_lane("sleep_features", lambda l: l["ready"] == 1)
        pid = lane["workers"][0]["pid"]
        seen.append(pid)
        started = time.monotonic()
        status, _, doc = server.post("/v1/sleep-features", _features_body())
        assert status == 200
        assert doc["status"] == "timeout"
        assert doc["status_reasons"] == ["enrichment_budget_exceeded"]
        assert doc["budget_ms"] == 300
        assert doc["nights"][0]["night_id"] == "night-exec"
        assert time.monotonic() - started < 2.0
        server.wait_lane("sleep_features", lambda l: l["ready"] == 1)
        assert not _alive(pid)
        lanes = server.health()["execution"]["lanes"]
        assert sum(len([w for w in l["workers"] if w["pid"]]) for l in lanes.values()) <= 2
    assert len(set(seen)) == 3
    counters = server.lane("sleep_features")["counters"]
    assert counters["timeouts"] == 3 and counters["respawns"] == 3
    assert server.health()["counters"]["withheld"] == 3


def test_sleep_features_busy_while_the_slot_is_held(bounded):
    # A roomy infer budget: this test is about lane independence, not about a loaded host's
    # HRV runtime (300 ms was overrun on a saturated test machine).
    server = bounded([HrvProductionProvider()], compute="execution_fakes:sleepy_compute",
                     timeout_ms=10_000, env={"FRWHOOP_SLEEP_FEATURES_BUDGET_MS": "1500"})
    assert server.wait_ready("sleep_features")
    thread = threading.Thread(target=lambda: server.post("/v1/sleep-features", _features_body()))
    thread.start()
    server.wait_lane("sleep_features", lambda l: l["active"] == 1)
    started = time.monotonic()
    status, headers, body = server.post("/v1/sleep-features", _features_body())
    assert time.monotonic() - started < 1.0
    assert status == 429 and body["error"]["code"] == "busy"
    assert body["error"]["lane"] == "sleep_features" and int(headers["Retry-After"]) >= 1
    # The infer lane is independent: an infer request is still served meanwhile.
    assert server.wait_ready("infer")
    status, _, body = server.post("/v1/infer", _infer_body())
    assert status == 200 and body["status"] == "ok"
    thread.join(10)


def test_sleep_features_crash_and_error_degrade_and_respawn(bounded):
    server = bounded([HrvProductionProvider()], compute="execution_fakes:crashing_compute",
                     env={"FRWHOOP_SLEEP_FEATURES_BUDGET_MS": "5000"})
    assert server.wait_ready("sleep_features")
    old_pid = server.lane("sleep_features")["workers"][0]["pid"]
    status, _, doc = server.post("/v1/sleep-features", _features_body())
    assert status == 200 and doc["status"] == "error"
    assert doc["error"].startswith("worker_crashed")
    lane = server.wait_lane("sleep_features", lambda l: l["ready"] == 1)
    assert lane["workers"][0]["pid"] != old_pid and not _alive(old_pid)
    assert lane["counters"]["crashes"] == 1

    raising = bounded([HrvProductionProvider()], compute="execution_fakes:raising_compute")
    assert raising.wait_ready("sleep_features")
    status, _, doc = raising.post("/v1/sleep-features", _features_body())
    assert status == 200 and doc["status"] == "error"
    assert "feature module exploded" in doc["error"]
    assert raising.lane("sleep_features")["counters"]["respawns"] == 0, \
        "an exception is a reply: the process keeps serving"


# -- HTTP layer -------------------------------------------------------------


def test_a_flood_cannot_grow_threads_and_healthz_still_answers(bounded):
    server = bounded([SlowProvider(seconds=1.0)], timeout_ms=5_000)
    assert server.wait_ready()
    baseline = threading.active_count()
    results: list[int] = []
    lock = threading.Lock()

    def fire():
        try:
            status, _, _ = server.post("/v1/infer", _infer_body(), timeout=20)
        except (urllib.error.URLError, ConnectionError, OSError):
            status = -1
        with lock:
            results.append(status)

    clients = [threading.Thread(target=fire) for _ in range(24)]
    for client in clients:
        client.start()
    peak_server_threads = 0
    healthz_ms: list[float] = []
    while any(client.is_alive() for client in clients):
        # Threads that are not the test's own clients: the server's never grow.
        alive_clients = sum(1 for client in clients if client.is_alive())
        peak_server_threads = max(peak_server_threads, threading.active_count() - alive_clients)
        started = time.monotonic()
        server.health()
        healthz_ms.append((time.monotonic() - started) * 1000)
        time.sleep(0.05)
    for client in clients:
        client.join()
    assert peak_server_threads <= baseline, (peak_server_threads, baseline)
    assert max(healthz_ms) < 1500, f"/healthz must keep answering (worst {max(healthz_ms):.0f} ms)"
    assert results.count(200) >= 1
    assert all(status in (200, 429, -1) for status in results), results
    assert results.count(429) >= 12, results
    assert threading.active_count() <= baseline
    http = server.health()["execution"]["http"]
    assert http["threads"] == 6


def test_connections_beyond_the_pool_and_backlog_get_a_busy_answer(bounded):
    server = bounded([SlowProvider(seconds=3.0)], timeout_ms=10_000,
                     env={"FRWHOOP_INFERENCE_HTTP_THREADS": "2", "FRWHOOP_INFERENCE_HTTP_BACKLOG": "1",
                          "FRWHOOP_INFERENCE_MAX_WAITING": "1",
                          "FRWHOOP_INFERENCE_QUEUE_WAIT_MS": "5000"})
    assert server.wait_ready()
    host, port = server.server.server_address[:2]
    # Two connections hold both handler threads (one computing, one waiting for the slot).
    holders = [threading.Thread(target=lambda: server.post("/v1/infer", _infer_body(), timeout=20))
               for _ in range(2)]
    for holder in holders:
        holder.start()
    server.wait_lane("infer", lambda l: l["active"] == 1 and l["waiting"] == 1, direct=True)
    # A third connection fills the one-deep backlog; a fourth is refused at once.
    queued = socket.create_connection((host, port), timeout=5)
    time.sleep(0.2)
    refused = socket.create_connection((host, port), timeout=5)
    refused.settimeout(5)
    reply = b""
    while b"\r\n\r\n" not in reply:
        chunk = refused.recv(4096)
        if not chunk:
            break
        reply += chunk
    assert reply.startswith(b"HTTP/1.1 429"), reply[:200]
    assert b"Retry-After: 1" in reply
    refused.close()
    queued.close()
    for holder in holders:
        holder.join(20)
    assert server.server.handler_pool_snapshot()["refused_connections"] >= 1
