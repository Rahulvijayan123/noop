"""Shared test fixtures.

All fixtures are synthetic and seeded. No real capture is ever used (spec
section 8), and the ``*_ORACLE`` values are the independently computed numbers
published in ``/tmp/frwhoop-physiology/findings/hrv-neurokit.md`` section 4a/4c
(an independent Python port of the shipped Swift rules, run by a separate
research worker), so they are an external reference for this implementation.
"""

from __future__ import annotations

import json
import math
import os

# The sleep-staging candidate (SleepECG) loads its bundled Keras checkpoint directly. Keras
# must be told which backend to use BEFORE it is imported: with no backend selected it tries
# TensorFlow, which is not a dependency of this package.
os.environ.setdefault("KERAS_BACKEND", "torch")
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

import numpy as np
import pytest

from frwhoop_inference.contract import Beat, Window
from frwhoop_inference.providers import ProviderRegistry
from frwhoop_inference.server import Application, InferenceServer, InferenceHandler

REPO_PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(REPO_PACKAGE_ROOT, "models", "manifest.json")


# --------------------------------------------------------------------------
# Fixture construction (mirrors the research probe, so the oracles apply)
# --------------------------------------------------------------------------


@dataclass
class Fixture:
    """A beat series plus its ground-truth adjacency mask.

    ``adjacency[i]`` says interval ``i`` is genuinely adjacent to ``i-1`` in the
    SOURCE record. It is the independent truth the reference RMSSD is computed
    from; it is never fed to the provider.
    """

    name: str
    rr_ms: list[float]
    adjacency: list[bool]
    ts: list[int]

    def beats(self, with_delivery_order: bool = True) -> list[Beat]:
        return [
            Beat(ts=self.ts[i], rr_ms=self.rr_ms[i],
                 seq=i if with_delivery_order else None,
                 ord=i if with_delivery_order else None)
            for i in range(len(self.rr_ms))
        ]

    def window(self, slack: int = 10) -> Window:
        return Window(start=self.ts[0] - slack, end=self.ts[-1] + slack)


def _clean(n: int, base: float = 1000.0, sd: float = 25.0, seed: int = 7) -> list[tuple]:
    rng = np.random.default_rng(seed)
    return [(float(v), True, 0.0) for v in base + rng.normal(0, sd, n)]


#: Fixtures are anchored at a realistic unix epoch. The offset is an integer, so
#: every timestamp DIFFERENCE (and therefore every oracle value) is unchanged.
TS_EPOCH = 1_700_000_000


def build_fixture(name: str, records: Sequence[tuple[float, bool, float]]) -> Fixture:
    """Build a fixture exactly like the research probe.

    ``records`` is ``(rr_ms, adjacent_to_prev, extra_wall_clock_hole_seconds)``.
    Interval END times accumulate RR plus any hole; the stored ``ts`` is then the
    whole unix second the production store would carry.
    """
    rr = [float(r[0]) for r in records]
    adjacency = [False if i == 0 else bool(r[1]) for i, r in enumerate(records)]
    end_times: list[float] = []
    acc = 0.0
    for i, r in enumerate(records):
        acc += rr[i] / 1000.0 + float(r[2])
        end_times.append(acc)
    ts = [int(math.floor(t)) + TS_EPOCH for t in end_times]
    return Fixture(name=name, rr_ms=rr, adjacency=adjacency, ts=ts)


@pytest.fixture(scope="session")
def fixtures() -> dict[str, Fixture]:
    """The ten research fixtures (T1-T10)."""
    return {
        "T1_clean": build_fixture("T1_clean", _clean(60)),
        "T2_ectopic": build_fixture("T2_ectopic",
                                    _clean(30) + [(380.0, True, 0.0)] + _clean(30, seed=8)),
        "T3_dropped_beat": build_fixture("T3_dropped_beat", _clean(30) + _clean(29, seed=9)),
        "T4_duplicate_burst": build_fixture(
            "T4_duplicate_burst", _clean(30) + [(1000.0, False, 0.0)] * 3 + _clean(30, seed=10)),
        "T5_gap_90s": build_fixture("T5_gap_90s",
                                    _clean(60) + [(1000.0, False, 90.0)] + _clean(60, seed=11)),
        "T6_same_second_eq": build_fixture(
            "T6_same_second_eq",
            _clean(30) + [(500.0, True, 0.0), (500.0, True, 0.0), (1000.0, True, 0.0)]
            + _clean(30, seed=12)),
        "T7_short_run": build_fixture("T7_short_run", _clean(12)),
        "T8_out_of_range": build_fixture(
            "T8_out_of_range", _clean(20) + [(250.0, True, 0.0), (2500.0, True, 0.0)]
            + _clean(20, seed=13)),
        "T9_drop_1beat": build_fixture("T9_drop_1beat",
                                       _clean(30) + [(1000.0, False, 1.0)] + _clean(30, seed=21)),
        "T10_drop_4beat": build_fixture("T10_drop_4beat",
                                        _clean(30) + [(1000.0, False, 4.0)] + _clean(30, seed=22)),
    }


#: Independently computed oracle values: (rmssd_ms | None, valid_pairs, n_clean).
#: Source: findings/hrv-neurokit.md section 4a (T1-T8) and 4c (T9-T10).
ORACLE: dict[str, tuple[float | None, int, int]] = {
    "T1_clean": (31.156, 59, 60),
    "T2_ectopic": (30.956, 58, 60),
    "T3_dropped_beat": (36.408, 58, 59),
    "T4_duplicate_burst": (25.037, 62, 63),
    "T5_gap_90s": (31.041, 119, 121),
    "T6_same_second_eq": (29.520, 57, 59),
    # The published port refuses a run below the beat floor BEFORE counting
    # pairs and so reports 0; this implementation counts the pairs it found and
    # then applies the floor, so the pair count is reported honestly as 11.
    "T7_short_run": (None, 11, 12),
    "T8_out_of_range": (38.429, 38, 40),
    "T9_drop_1beat": (33.254, 60, 61),
    "T10_drop_4beat": (31.125, 59, 61),
}


# --------------------------------------------------------------------------
# Request building
# --------------------------------------------------------------------------


def iso(ts: int) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hrv_body(
    beats: Iterable[Beat],
    *,
    window: Window | None = None,
    windows: Sequence[Window] | None = None,
    aggregation: str = "window",
    metric: str = "hrv",
    user_id: str = "11111111-2222-3333-4444-555555555555",
    device_id: str = "whoop5-abcdef",
    provider_id: str | None = None,
    context_overrides: dict[str, Any] | None = None,
    beat_rows: Sequence[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    beats = list(beats)
    if beat_rows is None:
        rows = [
            {"ts": b.ts, "rr_ms": b.rr_ms, "seq": b.seq, "ord": b.ord,
             "src_channel": b.src_channel, "observation_id": b.observation_id}
            for b in beats
        ]
    else:
        rows = list(beat_rows)
    if windows is None:
        windows = [window] if window is not None else None
    if windows:
        start = min(w.start for w in windows) - 10
        end = max(w.end for w in windows) + 10
    else:
        start = min(b.ts for b in beats) - 10
        end = max(b.ts for b in beats) + 10
    context = {
        "user_id": user_id,
        "device_id": device_id,
        "interval_start_utc": iso(start),
        "interval_end_utc": iso(end),
        "iana_timezone": "Europe/London",
        "profile_version": "profile-2026-09-01",
        "config_version": "cfg-1",
        "corrections_version": "corr-0",
    }
    if context_overrides:
        context.update(context_overrides)
    payload: dict[str, Any] = {
        "metric": metric,
        "context": context,
        "input": {"beats": rows, "aggregation": aggregation},
        "provider": {"provider_id": provider_id} if provider_id else {},
    }
    if windows:
        payload["input"]["windows"] = [
            {"start_utc": iso(w.start), "end_utc": iso(w.end), "session_id": w.session_id,
             "stage": w.stage}
            for w in windows
        ]
    return payload


def window_rows(windows: Sequence[Window]) -> list[dict[str, Any]]:
    return [{"start_utc": iso(w.start), "end_utc": iso(w.end), "session_id": w.session_id}
            for w in windows]


# --------------------------------------------------------------------------
# Live server harness
# --------------------------------------------------------------------------


@dataclass
class LiveServer:
    server: InferenceServer
    base_url: str
    thread: threading.Thread

    def get(self, path: str) -> tuple[int, dict[str, Any]]:
        return self._request("GET", path)

    def post(self, path: str, body: Any, raw: bytes | None = None) -> tuple[int, dict[str, Any]]:
        return self._request("POST", path, body, raw=raw)

    def _request(self, method: str, path: str, body: Any = None,
                 raw: bytes | None = None) -> tuple[int, dict[str, Any]]:
        data = raw if raw is not None else (
            json.dumps(body).encode("utf-8") if body is not None else None)
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))


def start_server(
    *,
    registry: ProviderRegistry | None = None,
    manifest_path: str | None = None,
    model_root: str | None = None,
    timeout_ms: int = 20_000,
) -> LiveServer:
    app = Application.build(registry=registry, manifest_path=manifest_path,
                            model_root=model_root, timeout_ms=timeout_ms)
    server = InferenceServer(("127.0.0.1", 0), app)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                              daemon=True)
    thread.start()
    port = server.server_address[1]
    return LiveServer(server=server, base_url=f"http://127.0.0.1:{port}", thread=thread)


@pytest.fixture
def live_server():
    servers: list[LiveServer] = []

    def factory(**kwargs: Any) -> LiveServer:
        server = start_server(**kwargs)
        servers.append(server)
        return server

    yield factory
    for server in servers:
        server.server.shutdown()
        server.server.server_close()


@pytest.fixture(scope="session")
def sleep_model_root(tmp_path_factory) -> str:
    """A real artifact root for the sleep candidates, built from the installed wheel.

    The SleepECG checkpoint is bundled inside the ``sleepecg`` wheel, so the bytes are already
    on disk after ``uv sync``: this fixture copies them to the manifest paths under a temporary
    root and asserts both sha256s against the manifest. Nothing is downloaded and nothing is
    committed. ``verify_manifest`` then verifies the same bytes at startup, so the readiness
    gate is exercised for real instead of being stubbed out.
    """
    import hashlib
    import shutil
    import zipfile

    import sleepecg

    from frwhoop_inference.artifacts import load_manifest, verify_manifest

    entries = {e["id"]: e for e in load_manifest(MANIFEST_PATH)["entries"]}
    entry = entries["sleepecg_wrn_gru_mesa"]
    root = tmp_path_factory.mktemp("frwhoop-models")
    source_zip = os.path.join(os.path.dirname(sleepecg.__file__), "classifiers",
                              "wrn-gru-mesa.zip")
    for artifact in entry["artifacts"]:
        target = root / artifact["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if artifact["name"] == "wrn-gru-mesa.zip":
            shutil.copyfile(source_zip, target)
        else:
            with zipfile.ZipFile(source_zip) as archive:
                with archive.open("classifier.keras") as handle:
                    target.write_bytes(handle.read())
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        assert digest == artifact["sha256"], f"{artifact['name']} hash mismatch"
        assert target.stat().st_size == artifact["size_bytes"]

    state = verify_manifest(load_manifest(MANIFEST_PATH), str(root), manifest_path=MANIFEST_PATH)
    assert state.ok is True, state.reason
    assert all(c.status == "verified" for c in state.checks if c.required_for_readiness)
    return str(root)


@pytest.fixture(scope="session")
def manifest_entries() -> list[dict[str, Any]]:
    with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)["entries"]
