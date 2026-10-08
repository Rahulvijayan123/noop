"""Sidecar HTTP contract tests.

Required coverage: healthz, providers listing, infer happy path, unknown metric
404, malformed 400, not-ready 503, non-loopback refusal, timeout budget.

Every computation runs in a worker process (``frwhoop_inference.execution``), so the
custom providers these tests register live in ``execution_fakes`` (a worker imports them
by name); the bounds themselves are covered in ``test_execution.py``.
"""

from __future__ import annotations

import json
import time

import pytest

from conftest import MANIFEST_PATH, hrv_body, iso
from execution_fakes import ExplodingProvider, SlowProvider, UnreadyProvider
from frwhoop_inference.contract import MAX_BODY_BYTES, Beat, Window
from frwhoop_inference.providers import ProviderRegistry
from frwhoop_inference.server import Application, create_server, is_loopback_host, main


class _WarmServer:
    """A conftest ``LiveServer`` whose first ``/v1/infer`` waits for the warm worker.

    Every computation runs in a worker process that imports and warms the registry once
    (seconds on a loaded machine). A test measures the route, not that one-off start, so
    the wait happens here, outside the request's own 30 s client timeout."""

    def __init__(self, inner):
        self._inner = inner

    def __getattr__(self, name):
        return getattr(self._inner, name)

    def warm(self, timeout: float = 300.0) -> None:
        assert self._inner.server.lanes["infer"].wait_ready(timeout), "infer worker never warmed"

    def post(self, path, body, raw=None):
        if path == "/v1/infer":
            self.warm()
        return self._inner.post(path, body, raw=raw)


@pytest.fixture
def live_server(live_server):
    def factory(**kwargs):
        return _WarmServer(live_server(**kwargs))

    return factory


def _beats(count: int = 60) -> list[Beat]:
    return [Beat(ts=1_700_000_000 + i, rr_ms=1000.0, seq=i, ord=i) for i in range(count)]


def _body(**kwargs):
    beats = kwargs.pop("beats", _beats())
    window = kwargs.pop("window", Window(start=beats[0].ts - 5, end=beats[-1].ts + 5))
    return hrv_body(beats, window=window, **kwargs)


# -- GET /healthz -----------------------------------------------------------


def test_healthz_reports_readiness_per_provider(live_server):
    """Readiness is PER PROVIDER: the HRV providers need no model bytes.

    The default (empty) artifact root leaves the sleep-staging checkpoint unverified, which
    marks only ``sleepecg.wrn-gru-mesa.v1`` not-ready. HRV stays ready, the process-level flag
    reflects that a wired provider is down, and ``/v1/infer`` for HRV is unaffected.
    """
    server = live_server()
    status, body = server.get("/healthz")
    assert status == 200
    assert body["contract_version"]
    providers = body["providers"]
    # The sensor-biomarker providers are additive and ready without model bytes
    # (the rhythm shadow lane is disabled by default: no artifacts needed).
    assert set(providers) == {"production.runs.v1", "neurokit2.shadow.v1",
                              "hypnospy.hr-boundary.v1", "sleepecg.wrn-gru-mesa.v1",
                              "sensor.biomarkers.v1", "sensor.biomarkers.rhythm.v1"}
    for pid in ("production.runs.v1", "neurokit2.shadow.v1", "hypnospy.hr-boundary.v1"):
        assert providers[pid]["ready"] is True, providers[pid]
        assert providers[pid]["version"]
        assert providers[pid]["reason"] is None
    stage = providers["sleepecg.wrn-gru-mesa.v1"]
    assert stage["ready"] is False
    assert "blocked_artifact" in stage["reason"]
    # a wired provider is down, so the process flag is false, but HRV is untouched
    assert body["ready"] is False
    assert body["manifest"]["ok"] is False
    assert "sleepecg_wrn_gru_mesa" in body["manifest"]["reason"]
    assert body["counters"]["inference"] == 0


def test_healthz_is_fully_ready_with_a_populated_model_root(live_server, sleep_model_root):
    server = live_server(model_root=sleep_model_root)
    status, body = server.get("/healthz")
    assert status == 200
    assert body["manifest"]["ok"] is True
    assert body["ready"] is True
    assert all(state["ready"] for state in body["providers"].values())


def test_healthz_counts_requests(live_server):
    server = live_server()
    status, _ = server.post("/v1/infer", _body())
    assert status == 200
    status, health = server.get("/healthz")
    assert health["counters"]["inference"] == 1


# -- GET /v1/providers ------------------------------------------------------


def test_providers_lists_capabilities_and_recorded_models(live_server):
    server = live_server()
    status, body = server.get("/v1/providers")
    assert status == 200
    assert body["contract_version"]
    by_id = {p["provider_id"]: p for p in body["providers"]}
    assert set(by_id) == {"production.runs.v1", "neurokit2.shadow.v1",
                          "hypnospy.hr-boundary.v1", "sleepecg.wrn-gru-mesa.v1",
                          "sensor.biomarkers.v1", "sensor.biomarkers.rhythm.v1"}
    production = by_id["production.runs.v1"]
    assert production["metric"] == "hrv"
    assert production["mode"] == "retrospective"
    assert production["required_signals"] == ["rr_intervals"]
    assert production["publishable"] is True
    assert production["eligibility"]["state"] == "eligible"
    assert set(production["versions"]) >= {"adapter", "preprocessing", "dependency", "config", "model"}
    assert production["readiness"]["ready"] is True

    shadow = by_id["neurokit2.shadow.v1"]
    assert shadow["publishable"] is False
    assert shadow["accuracy_label"] == "unverified_accuracy"
    assert shadow["eligibility"]["state"] == "unverified"

    # Conditional models are recorded with eligibility states, not wired live.
    models = {m["id"]: m for m in body["models"]}
    assert set(models) == {"neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa", "wav2sleep",
                           "no_eeg_sleep_staging", "rr_estimation", "stepcount",
                           "cnn_wrist_model_freeliving",
                           "paradigma", "deepbeat", "siamaf"}
    assert models["wav2sleep"]["status"] == "blocked_input"
    assert models["stepcount"]["status"] == "blocked_license"
    assert models["stepcount"]["wired"] is False
    assert models["no_eeg_sleep_staging"]["status"] == "unverified"
    # six entries are wired now: the HRV dependency, the two landed sleep
    # candidates and the three additive sensor-biomarker lanes.
    wired = {m["id"] for m in body["models"] if m["wired"]}
    assert wired == {"neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa",
                     "paradigma", "deepbeat", "siamaf"}
    assert models["hypnospy"]["provider_id"] == "hypnospy.hr-boundary.v1"
    assert models["sleepecg_wrn_gru_mesa"]["provider_id"] == "sleepecg.wrn-gru-mesa.v1"
    assert models["sleepecg_wrn_gru_mesa"]["status"] == "shadow_eligible"
    # the sleep providers are listed with their readiness (gated by the checkpoint)
    sleep_boundary = by_id["hypnospy.hr-boundary.v1"]
    assert sleep_boundary["metric"] == "sleep_boundary"
    assert sleep_boundary["label_space"] == "in_bed/sleep_onset/final_wake/nap/waso"
    assert sleep_boundary["readiness"]["ready"] is True
    stage = by_id["sleepecg.wrn-gru-mesa.v1"]
    assert stage["metric"] == "sleep_stage"
    assert stage["label_space"] == "wake/rem/nrem"
    assert stage["accuracy_label"] == "unverified_accuracy"


def test_unknown_route_is_404(live_server):
    server = live_server()
    status, body = server.get("/nope")
    assert status == 404
    assert body["error"]["code"] == "not_found"


# -- POST /v1/infer ---------------------------------------------------------


def test_infer_happy_path(live_server):
    server = live_server()
    status, body = server.post("/v1/infer", _body())
    assert status == 200
    assert body["status"] == "ok"
    assert body["metric"] == "hrv"
    assert body["provider_id"] == "production.runs.v1"
    assert body["publishable"] is True
    assert body["result"]["unit"] == "ms"
    assert body["result"]["value"] == pytest.approx(0.0, abs=1e-9)
    assert body["input"]["sha256"]
    assert body["input"]["refs"]
    assert body["interval"]["local_day"]
    assert body["final_or_provisional"] == "final"
    assert body["coverage"]["valid_pairs"] == 59
    assert body["diagnostics"]["algorithm_id"] == "production.runs.v1"
    assert isinstance(body["runtime_ms"], int)
    assert body["versions"]["model"] is None


def test_infer_accepts_an_explicit_provider(live_server):
    server = live_server()
    status, body = server.post("/v1/infer", _body(provider_id="neurokit2.shadow.v1"))
    assert status == 200
    assert body["provider_id"] == "neurokit2.shadow.v1"
    assert body["publishable"] is False
    assert body["final_or_provisional"] == "provisional"


def test_infer_is_deterministic_for_identical_input(live_server):
    server = live_server()
    _s1, first = server.post("/v1/infer", _body())
    _s2, second = server.post("/v1/infer", _body())
    assert first["input"]["sha256"] == second["input"]["sha256"]
    assert first["result"] == second["result"]


def test_infer_withheld_returns_a_machine_readable_reason(live_server):
    server = live_server()
    beats = [Beat(ts=1_700_000_000 + i, rr_ms=1000.0 if i % 2 == 0 else 100.0,
                  seq=i, ord=i) for i in range(60)]
    status, body = server.post("/v1/infer", _body(beats=beats))
    assert status == 200
    assert body["status"] == "withheld"
    assert body["result"] is None
    assert body["withheld_reason"] == "insufficient_coverage"
    assert body["diagnostics"]["withheld_detail"] == "no_adjacent_pair"


def test_unknown_metric_is_404(live_server):
    server = live_server()
    status, body = server.post("/v1/infer", {"metric": "not_a_metric", "context": {}, "input": {}})
    assert status == 404
    assert body["status"] == "error"
    assert body["error"]["code"] == "unknown_metric"


@pytest.mark.parametrize("metric", ["respiration"])
def test_known_metric_without_a_wired_provider_is_503(live_server, metric):
    """The metric domain has four members; ``respiration`` has no wired provider in this
    build and must say so instead of failing obscurely."""
    server = live_server()
    body = _body()
    body["metric"] = metric
    status, response = server.post("/v1/infer", body)
    assert status == 503
    assert response["error"]["code"] == "provider_unavailable"


@pytest.mark.parametrize("metric,provider_id", [
    ("sleep_boundary", "hypnospy.hr-boundary.v1"),
    ("sleep_stage", "sleepecg.wrn-gru-mesa.v1"),
])
def test_sleep_metrics_are_wired_and_validate_their_own_payload(live_server, sleep_model_root,
                                                                 metric, provider_id):
    """Both sleep metrics are served now. An HRV-shaped body is not a valid payload for
    them, so the request reaches the provider and comes back as a typed input error rather
    than a 503 ``provider_unavailable``."""
    server = live_server(model_root=sleep_model_root)
    body = _body()
    body["metric"] = metric
    status, response = server.post("/v1/infer", body)
    assert status != 503, response
    assert response["provider_id"] == provider_id
    assert response["status"] in {"error", "withheld"}


def test_unknown_provider_is_404(live_server):
    server = live_server()
    status, body = server.post("/v1/infer", _body(provider_id="nope.v1"))
    assert status == 404
    assert body["error"]["code"] == "unknown_provider"


# -- malformed input --------------------------------------------------------


def test_beats_for_a_different_interval_are_400_not_a_silent_withheld(live_server):
    """F6: a payload whose beats belong to another interval is a client error.

    It used to come back as HTTP 200 with ``withheld``/``no_beats_in_window``,
    which a caller cannot tell apart from an interval that genuinely has no beats.
    """
    start = 1_700_000_000
    beats = [Beat(ts=start + i, rr_ms=1000.0, seq=i, ord=i) for i in range(60)]
    body = hrv_body(beats, context_overrides={
        "interval_start_utc": iso(start + 365 * 24 * 3600),
        "interval_end_utc": iso(start + 365 * 24 * 3600 + 600)})
    server = live_server()
    status, response = server.post("/v1/infer", body)
    assert status == 400
    assert response["status"] == "error"
    assert response["error"]["code"] == "out_of_bounds_input"
    assert response["error"]["field"] == "input.beats"
    # it never reached a provider
    assert server.get("/healthz")[1]["counters"]["inference"] == 0


def test_in_interval_but_empty_window_still_withholds_no_beats_in_window(live_server):
    """F6 keeps the empty-window path: the beats describe THIS interval, but one
    window inside it holds none - a data gap, not an interval mismatch."""
    start = 1_700_000_000
    beats = [Beat(ts=start + i, rr_ms=1000.0, seq=i, ord=i) for i in range(60)]
    empty = Window(start=start + 300, end=start + 599)
    body = hrv_body(beats, windows=[empty], aggregation="window",
                    context_overrides={"interval_start_utc": iso(start),
                                       "interval_end_utc": iso(start + 600)})
    server = live_server()
    status, response = server.post("/v1/infer", body)
    assert status == 200
    assert response["status"] == "withheld"
    assert response["withheld_reason"] == "insufficient_coverage"
    assert response["diagnostics"]["withheld_detail"] == "no_beats_in_window"
    assert response["result"] is None


@pytest.mark.parametrize("raw", [b"", b"not json", b"{", b"[1,2,3]"])
def test_malformed_body_is_400(live_server, raw):
    server = live_server()
    status, body = server.post("/v1/infer", None, raw=raw)
    assert status == 400
    assert body["status"] == "error"
    assert body["error"]["code"] in ("malformed_json", "invalid_request")


@pytest.mark.parametrize("mutate,code", [
    (lambda b: b["context"].pop("user_id"), "invalid_context"),
    (lambda b: b["context"].update({"iana_timezone": "Mars/Olympus"}), "invalid_timezone"),
    (lambda b: b["context"].update({"interval_end_utc": b["context"]["interval_start_utc"]}),
     "invalid_timestamp"),
    (lambda b: b["context"].update({"user_id": "has spaces"}), "invalid_identity"),
    (lambda b: b["input"]["beats"][0].update({"rr_ms": "fast"}), "invalid_input"),
    (lambda b: b["input"]["beats"][0].update({"rr_ms": float("nan")}), "non_finite_input"),
    (lambda b: b["input"]["beats"][0].update({"rr_ms": 1.0}), "out_of_bounds_input"),
    (lambda b: b["input"].pop("beats"), "invalid_input"),
    (lambda b: b["input"].update({"beats": []}), "blocked_input"),
])
def test_invalid_payloads_are_400_with_a_code(live_server, mutate, code):
    server = live_server()
    body = _body()
    mutate(body)
    status, response = server.post("/v1/infer", body)
    assert status == 400, response
    assert response["status"] == "error"
    assert response["error"]["code"] == code


def test_oversized_body_closes_the_connection_instead_of_desynchronising(live_server):
    """F4: a 413 must not leave the body unread on a keep-alive connection.

    HTTP/1.1 keeps the connection open by default, so unread body bytes would be
    parsed as the NEXT request on the same socket. The connection is therefore
    closed with the error, and a client that pipelines a second request onto it
    gets no second response (and never hangs).
    """
    import socket

    server = live_server()
    host, port = server.server.server_address[0], server.server.server_address[1]
    oversized = MAX_BODY_BYTES + 1
    first = (b"POST /v1/infer HTTP/1.1\r\nHost: 127.0.0.1\r\n"
             b"Content-Type: application/json\r\n"
             b"Content-Length: " + str(oversized).encode() + b"\r\n\r\n")
    second = (b"POST /v1/infer HTTP/1.1\r\nHost: 127.0.0.1\r\n"
              b"Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")

    with socket.create_connection((host, port), timeout=10.0) as sock:
        sock.settimeout(10.0)
        try:
            sock.sendall(first)
            sock.sendall(b"x" * oversized)
            sock.sendall(second)
        except OSError:
            # the server may close the read side while we are still writing; that
            # is the behaviour under test, and the response is read below
            pass

        status, _body, rest = _read_raw_response(sock)
        assert status == 413, (status, _body)

        # nothing else may be served on this connection: no 200 for the second
        # request, and no second response parsed out of the refused body
        assert rest == b"", rest[:200]
        # and the connection itself is finished, so the client cannot wait on it
        try:
            trailing = sock.recv(1)
        except ConnectionResetError:
            trailing = b""
        assert trailing == b"", "the connection must be closed after a refused body"


def test_a_normal_request_still_keeps_the_connection_alive(live_server):
    """The close-on-refusal rule must be scoped to refused bodies: two ordinary
    requests on ONE socket both get served, so keep-alive is not broken."""
    import json as _json
    import socket

    server = live_server()
    server.warm()
    host, port = server.server.server_address[0], server.server.server_address[1]
    payload = _json.dumps(_body()).encode("utf-8")
    request = (b"POST /v1/infer HTTP/1.1\r\nHost: 127.0.0.1\r\n"
               b"Content-Type: application/json\r\nContent-Length: "
               + str(len(payload)).encode() + b"\r\n\r\n" + payload)

    with socket.create_connection((host, port), timeout=10.0) as sock:
        sock.settimeout(10.0)
        sock.sendall(request)
        first_status, first_body, rest = _read_raw_response(sock)
        assert first_status == 200
        assert rest == b""

        # the SAME connection, a second request: served, so keep-alive survived
        sock.sendall(request)
        second_status, second_body, rest = _read_raw_response(sock)
        assert second_status == 200
        assert rest == b""
        assert _json.loads(second_body)["status"] == "ok"
        assert _json.loads(second_body)["provider_id"] == "production.runs.v1"


def _read_raw_response(sock):
    """Read one HTTP/1.1 response from a raw socket; return (status, body, rest)."""
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = sock.recv(65536)
        if not chunk:
            raise AssertionError(f"connection closed before the response headers: {buffer[:200]!r}")
        buffer += chunk
    head, _, rest = buffer.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1])
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(rest) < length:
        chunk = sock.recv(65536)
        if not chunk:
            break
        rest += chunk
    body, rest = rest[:length], rest[length:]
    return status, body, rest


def test_server_survives_a_burst_of_bad_requests(live_server):
    """The server must never crash on bad input: after a burst of garbage it
    still answers a good request."""
    server = live_server()
    for raw in (b"", b"{", b"[]", b"null", b'"x"'):
        server.post("/v1/infer", None, raw=raw)
    status, body = server.post("/v1/infer", _body())
    assert status == 200 and body["status"] == "ok"
    assert server.get("/healthz")[0] == 200


# -- readiness / 503 --------------------------------------------------------


def _write_manifest(tmp_path, *, sha256: str | None = None, required: bool,
                    provider_id: str | None = None):
    """A one-entry manifest. ``sha256=None`` omits the digest entirely (audit DD-4)."""
    artifact = {
        "name": "weights.bin",
        "path": "test/rev1/weights.bin",
        "url": "file:///dev/null",
        "size_bytes": 4,
        "verify_at_startup": True,
    }
    if sha256 is not None:
        artifact["sha256"] = sha256
    manifest = {
        "manifest_version": "test",
        "entries": [{
            "id": "test_model",
            "provider_id": provider_id,
            "kind": "model_checkpoint",
            "name": "test",
            "revision": "rev1",
            "license": "MIT",
            "rights_verdict": "clear",
            "status": "eligible",
            "input_contract": "n/a",
            "required_for_readiness": required,
            "artifacts": [artifact],
        }],
    }
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    return str(path)


def test_missing_required_artifact_makes_the_server_not_ready(tmp_path, live_server):
    model_root = tmp_path / "models"
    model_root.mkdir()
    # the entry is bound to one provider: only THAT provider is gated by the missing bytes
    manifest_path = _write_manifest(tmp_path, sha256="0" * 64, required=True,
                                    provider_id="production.runs.v1")
    server = live_server(manifest_path=manifest_path, model_root=str(model_root))

    status, health = server.get("/healthz")
    assert status == 200
    assert health["manifest"]["ok"] is False
    assert "blocked_artifact" in health["manifest"]["reason"]
    assert health["manifest"]["failed_checks"][0]["status"] == "missing"
    # the gated provider is down; the shadow provider is untouched
    assert health["providers"]["production.runs.v1"]["ready"] is False
    assert "blocked_artifact" in health["providers"]["production.runs.v1"]["reason"]
    assert health["providers"]["neurokit2.shadow.v1"]["ready"] is True
    assert health["ready"] is False

    status, body = server.post("/v1/infer", _body())
    assert status == 503
    assert body["error"]["code"] == "provider_not_ready"
    assert "blocked_artifact" in body["error"]["message"]
    # the ungated provider still answers
    status, body = server.post("/v1/infer", _body(provider_id="neurokit2.shadow.v1"))
    assert status == 200


def test_required_artifact_without_a_digest_makes_the_server_not_ready(tmp_path, live_server):
    """Audit DD-4: a ``verify_at_startup`` entry with no published sha256 fails CLOSED.

    Nothing can verify the bytes, so readiness must not be granted on the strength of
    the file merely being absent-or-present. Before the repair ``no_sha256`` was not a
    failure, so a manifest edited to drop one digest let the provider report ready.
    """
    model_root = tmp_path / "models"
    model_root.mkdir()
    manifest_path = _write_manifest(tmp_path, sha256=None, required=True,
                                    provider_id="production.runs.v1")
    server = live_server(manifest_path=manifest_path, model_root=str(model_root))

    status, health = server.get("/healthz")
    assert status == 200
    assert health["manifest"]["ok"] is False
    assert health["manifest"]["failed_checks"][0]["status"] == "no_sha256"
    assert "no_sha256" in health["manifest"]["reason"]
    assert health["providers"]["production.runs.v1"]["ready"] is False
    assert "blocked_artifact" in health["providers"]["production.runs.v1"]["reason"]
    assert health["providers"]["neurokit2.shadow.v1"]["ready"] is True
    assert health["ready"] is False

    status, body = server.post("/v1/infer", _body())
    assert status == 503
    assert body["error"]["code"] == "provider_not_ready"


def test_optional_artifact_without_a_digest_does_not_block_readiness(tmp_path, live_server):
    """The same entry, not required: it is reported as a failed optional check only."""
    model_root = tmp_path / "models"
    model_root.mkdir()
    manifest_path = _write_manifest(tmp_path, sha256=None, required=False)
    server = live_server(manifest_path=manifest_path, model_root=str(model_root))

    status, health = server.get("/healthz")
    assert status == 200
    assert health["manifest"]["ok"] is True
    # the failed check is REPORTED, but it gates no provider because the entry is optional
    assert [c["status"] for c in health["manifest"]["failed_checks"]] == ["no_sha256"]
    assert "no_sha256" in health["manifest"]["reason"]
    assert "optional artifacts failed verification" in health["manifest"]["reason"]


def test_mismatched_required_artifact_makes_the_server_not_ready(tmp_path, live_server):
    model_root = tmp_path / "models"
    (model_root / "test" / "rev1").mkdir(parents=True)
    (model_root / "test" / "rev1" / "weights.bin").write_bytes(b"abcd")
    manifest_path = _write_manifest(tmp_path, sha256="f" * 64, required=True,
                                    provider_id="production.runs.v1")
    server = live_server(manifest_path=manifest_path, model_root=str(model_root))
    status, health = server.get("/healthz")
    assert health["ready"] is False
    assert health["manifest"]["failed_checks"][0]["status"] == "sha256_mismatch"
    assert health["providers"]["production.runs.v1"]["ready"] is False


def test_matching_required_artifact_is_ready(tmp_path, live_server):
    import hashlib

    model_root = tmp_path / "models"
    (model_root / "test" / "rev1").mkdir(parents=True)
    payload = b"abcd"
    (model_root / "test" / "rev1" / "weights.bin").write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    manifest_path = _write_manifest(tmp_path, sha256=digest, required=True,
                                    provider_id="production.runs.v1")
    server = live_server(manifest_path=manifest_path, model_root=str(model_root))
    status, health = server.get("/healthz")
    assert health["ready"] is True
    assert health["providers"]["production.runs.v1"]["ready"] is True
    assert health["manifest"]["ok"] is True
    assert health["manifest"]["failed_checks"] == []
    assert server.post("/v1/infer", _body())[0] == 200


def test_a_broken_manifest_does_not_crash_the_server(tmp_path, live_server):
    path = tmp_path / "broken.json"
    path.write_text("{ not json")
    server = live_server(manifest_path=str(path), model_root=str(tmp_path))
    status, health = server.get("/healthz")
    assert status == 200
    assert health["manifest"]["load_error"]
    # F1: an unreadable manifest must FAIL CLOSED - with no entries we cannot know which
    # artifacts a provider needs, so nothing may claim readiness (and no metric is served).
    assert health["ready"] is False
    assert all(state["ready"] is False for state in health["providers"].values())
    assert all("manifest unusable" in (state["reason"] or "")
               for state in health["providers"].values())
    # the server still answers the diagnostic routes and refuses inference cleanly
    assert server.get("/v1/providers")[0] == 200
    status, body = server.post("/v1/infer", _body())
    assert status == 503
    assert body["error"]["code"] == "provider_not_ready"


def test_provider_level_readiness_failure_is_503(live_server):
    registry = ProviderRegistry([UnreadyProvider()])
    server = live_server(registry=registry, manifest_path=MANIFEST_PATH)
    status, health = server.get("/healthz")
    assert health["providers"]["unready.runs.v1"]["ready"] is False
    status, body = server.post("/v1/infer", _body())
    assert status == 503
    assert body["error"]["code"] == "provider_not_ready"
    assert "blocked_license" in body["error"]["message"]


# -- timeout budget ---------------------------------------------------------


def test_request_timeout_budget_withholds_instead_of_hanging(live_server):
    registry = ProviderRegistry([SlowProvider(seconds=5.0)])
    server = live_server(registry=registry, manifest_path=MANIFEST_PATH, timeout_ms=150)
    # Time the request, not the worker's one-off warm-up.
    server.warm()
    started = time.monotonic()
    status, body = server.post("/v1/infer", _body())
    elapsed = time.monotonic() - started
    assert status == 200
    assert body["status"] == "withheld"
    assert body["withheld_reason"] == "timeout"
    assert body["result"] is None
    assert body["diagnostics"]["withheld_detail"] == "request_budget_exceeded"
    assert body["diagnostics"]["worker_terminated"] is True
    assert elapsed < 3.0, "the request must not wait for the provider"


def test_provider_exception_becomes_a_500_error_body(live_server):
    registry = ProviderRegistry([ExplodingProvider()])
    server = live_server(registry=registry, manifest_path=MANIFEST_PATH)
    status, body = server.post("/v1/infer", _body())
    assert status == 500
    assert body["error"]["code"] == "provider_error"
    assert "kaboom" in body["error"]["message"]
    assert server.get("/healthz")[0] == 200


# -- bind safety ------------------------------------------------------------


def test_loopback_detection():
    assert is_loopback_host("127.0.0.1")
    assert is_loopback_host("::1")
    assert is_loopback_host("localhost")
    assert not is_loopback_host("0.0.0.0")
    assert not is_loopback_host("10.0.0.5")


@pytest.mark.parametrize("host", ["0.0.0.0", "10.0.0.5", "::"])
def test_create_server_refuses_a_non_loopback_bind(host):
    with pytest.raises(ValueError) as excinfo:
        create_server(host, 0, manifest_path=MANIFEST_PATH)
    assert "loopback" in str(excinfo.value)


def test_main_refuses_a_non_loopback_bind(capsys):
    assert main(["--host", "0.0.0.0", "--port", "0"]) == 2
    assert "loopback only" in capsys.readouterr().err


def test_create_server_allows_a_non_loopback_test_bind(tmp_path):
    server = create_server("0.0.0.0", 0, manifest_path=MANIFEST_PATH,
                           allow_non_loopback=True)
    try:
        assert server.server_address[0] == "0.0.0.0"
    finally:
        server.server_close()


def test_arg_parser_defaults_to_loopback_and_8787():
    from frwhoop_inference.server import build_arg_parser

    args = build_arg_parser().parse_args([])
    assert args.host == "127.0.0.1"
    assert args.port == 8787
    assert args.timeout_ms == 20_000
    assert args.allow_non_loopback is False
