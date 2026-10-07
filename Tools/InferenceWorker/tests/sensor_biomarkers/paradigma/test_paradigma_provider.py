"""Provider gating, input decoding, withholding and family documents (W3)."""

from __future__ import annotations

import json
import os

import numpy as np
import pytest

from pd_fixtures import ASSET_DIGESTS, MANIFEST_ENTRY, REPO_PACKAGE_ROOT, venv_python
from frwhoop_inference.contract import InferRequest, parse_context
from pd_fixtures import (manifest_with_paradigma, paradigma_env,
                          provisioned_root, real_asset_bytes,
                          venv_python_fixture)
from frwhoop_inference.sensor_biomarkers.paradigma import make_providers
from frwhoop_inference.sensor_biomarkers.paradigma.provider import (
    MIN_NATIVE_RATE_HZ,
    PROVIDER_ID,
    ParadigmaProvider,
    _decode_imu,
)


def build_request(input_block: dict, metric="sensor_biomarkers") -> InferRequest:
    body = {
        "metric": metric,
        "context": {
            "user_id": "u1", "device_id": "d1",
            "interval_start_utc": "2026-10-06T00:00:00Z",
            "interval_end_utc": "2026-10-06T01:00:00Z",
            "iana_timezone": "UTC",
            "profile_version": "p", "config_version": "c", "corrections_version": "k",
        },
        "input": input_block,
    }
    return parse_request(body)


def build_request_sb(**kwargs) -> InferRequest:
    """Build a sensor_biomarkers request directly (bypasses generic parse)."""
    context = parse_context({
        "user_id": "u1", "device_id": "d1",
        "interval_start_utc": "2026-10-06T00:00:00Z",
        "interval_end_utc": "2026-10-06T01:00:00Z",
        "iana_timezone": "UTC",
        "profile_version": "p", "config_version": "c", "corrections_version": "k",
    })
    return InferRequest(
        metric="sensor_biomarkers", context=context,
        input=kwargs.get("input"), provider_id=PROVIDER_ID,
        expected_versions=None, raw_input=dict(kwargs.get("input") or {}),
        input_sha256="x", input_refs=())


def imu_input(fs=100.0, seconds=40.0, families=("tremor", "arm_swing"),
              watch_side="left", device_orientation="screen_up", n_segments=1,
              gap_seconds=0.0, noise=0.05):
    n = int(seconds * fs)
    rng = np.random.default_rng(5)
    segs = []
    start = 1_700_000_000
    for _ in range(n_segments):
        accel = np.tile([0.0, 0.0, 1.0], (n, 1)) + rng.normal(0, noise, (n, 3))
        gyro = rng.normal(0, noise, (n, 3))
        segs.append({
            "start_unix": start,
            "duration_s": seconds,
            "accel_g": accel.tolist(),
            "gyro_dps": gyro.tolist(),
        })
        start += int(seconds + gap_seconds)
    return {
        "imu": {
            "sampling_rate_hz": fs,
            "units": {"accel": "g", "gyro": "deg/s"},
            "segments": segs,
        },
        "watch_side": watch_side,
        "device_orientation": device_orientation,
        "families": list(families),
    }


# ---------------------------------------------------------------------------
# Registration gating
# ---------------------------------------------------------------------------

def test_disabled_flag_registers_nothing(monkeypatch, tmp_path, manifest_with_paradigma):
    monkeypatch.delenv("FRWHOOP_PARADIGMA_ENABLED", raising=False)
    monkeypatch.setenv("FRWHOOP_MANIFEST", str(manifest_with_paradigma))
    assert make_providers() == []


def test_enabled_without_manifest_entry_registers_nothing(
        monkeypatch, tmp_path, provisioned_root):
    """Enabled + artifacts staged but no manifest entry -> fail closed."""
    if venv_python() is None:
        pytest.skip("paradigma subprocess venv not available")
    # a manifest WITHOUT the paradigma entry
    manifest = json.loads((REPO_PACKAGE_ROOT / "models" / "manifest.json").read_text())
    manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != "paradigma"]
    mp = tmp_path / "no-entry" / "manifest.json"
    mp.parent.mkdir()
    mp.write_text(json.dumps(manifest))
    monkeypatch.setenv("FRWHOOP_MANIFEST", str(mp))
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(provisioned_root))
    monkeypatch.setenv("FRWHOOP_PARADIGMA_PYTHON", venv_python())
    monkeypatch.setenv("FRWHOOP_PARADIGMA_ENABLED", "1")
    assert make_providers() == []


def test_missing_artifacts_do_not_break_other_families(
        monkeypatch, tmp_path, manifest_with_paradigma):
    """collect_optional_providers must fail closed: empty root -> no provider,
    and the descriptive providers still register."""
    monkeypatch.setenv("FRWHOOP_MANIFEST", str(manifest_with_paradigma))
    empty_root = tmp_path / "empty-root"
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(empty_root))
    if venv_python():
        monkeypatch.setenv("FRWHOOP_PARADIGMA_PYTHON", venv_python())
    monkeypatch.setenv("FRWHOOP_PARADIGMA_ENABLED", "1")
    assert make_providers() == []
    from frwhoop_inference.sensor_biomarkers import collect_optional_providers
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import PROVIDER_ID
    optional = collect_optional_providers()
    # no paradigma provider may register when its artifacts are missing, while
    # any OTHER optional providers (e.g. rhythm) remain unaffected
    assert all(p.provider_id != PROVIDER_ID for p in optional)


def test_provider_registered_when_gateable(paradigma_env):
    providers = make_providers()
    assert len(providers) == 1
    provider = providers[0]
    assert provider.provider_id == PROVIDER_ID
    assert provider.metric == "sensor_biomarkers"
    assert provider.mode == "research"
    ready, reason = provider.readiness()
    assert ready, reason
    capability = provider.capability()
    assert capability["publishable"] is False
    assert capability["eligibility_state"] == "research_eligible"
    assert capability["axis_convention_verified"] is False


# ---------------------------------------------------------------------------
# Input decoding
# ---------------------------------------------------------------------------

def test_decode_imu_builds_contiguous_runs():
    raw = imu_input(seconds=40.0, n_segments=2, gap_seconds=0.0)
    meta, runs = _decode_imu(raw)
    assert len(runs) == 1  # two back-to-back segments merge into one run
    run = runs["run_1"]
    assert run["sample_count"] == 2 * 4000
    assert run["duration_s"] == pytest.approx(80.0)


def test_decode_imu_splits_at_gaps():
    raw = imu_input(seconds=40.0, n_segments=2, gap_seconds=10.0)
    meta, runs = _decode_imu(raw)
    assert len(runs) == 2
    assert runs["run_1"]["duration_s"] == pytest.approx(40.0)
    assert runs["run_2"]["duration_s"] == pytest.approx(40.0)


def test_decode_imu_rejects_low_native_rate():
    raw = imu_input(fs=25.0)
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import _ImuError
    with pytest.raises(_ImuError) as exc:
        _decode_imu(raw)
    assert exc.value.reason == "unsupported_native_rate"


def test_decode_imu_rejects_wrong_units():
    raw = imu_input()
    raw["imu"]["units"] = {"accel": "m/s^2", "gyro": "deg/s"}
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import _ImuError
    with pytest.raises(_ImuError) as exc:
        _decode_imu(raw)
    assert exc.value.reason == "preprocessing_unverified"


def test_decode_imu_rejects_overlapping_segments():
    raw = imu_input(seconds=40.0, n_segments=2, gap_seconds=-20.0)
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import _ImuError
    with pytest.raises(_ImuError):
        _decode_imu(raw)


def test_decode_imu_rejects_missing_imu():
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import _ImuError
    with pytest.raises(_ImuError) as exc:
        _decode_imu({})
    assert exc.value.reason == "artifact_unavailable"


# ---------------------------------------------------------------------------
# Withholding / family documents
# ---------------------------------------------------------------------------

def test_no_paradigma_family_requested_returns_ok(paradigma_env):
    provider = make_providers()[0]
    request = build_request_sb(input={
        "families": ["movement", "oscillation"],
        "imu": imu_input()["imu"],
    })
    result = provider.infer(request)
    assert result.status == "ok"
    assert result.stages == []


def test_arm_swing_withheld_when_watch_side_unknown(paradigma_env):
    provider = make_providers()[0]
    request = build_request_sb(input=imu_input(watch_side="unknown"))
    result = provider.infer(request)
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert "tremor" in stages
    assert "arm_swing" in stages
    assert stages["arm_swing"]["status"] == "withheld"
    assert stages["arm_swing"]["reason"] == "unknown_wrist_placement"
    assert stages["arm_swing"]["measurements"] == {}


def test_arm_swing_withheld_when_orientation_unknown_or_axis_unverified(paradigma_env):
    provider = make_providers()[0]
    # orientation unknown -> unknown_orientation
    request = build_request_sb(input=imu_input(device_orientation="unknown"))
    result = provider.infer(request)
    stages = {s["family"]: s for s in result.stages}
    assert stages["arm_swing"]["reason"] == "unknown_orientation"
    # axis convention unverified (even with everything known) -> still withheld
    request = build_request_sb(input=imu_input(watch_side="left", device_orientation="screen_up"))
    result = provider.infer(request)
    stages = {s["family"]: s for s in result.stages}
    assert stages["arm_swing"]["status"] == "withheld"
    assert stages["arm_swing"]["reason"] == "unknown_orientation"


def test_unsupported_native_rate_withholds_both_families(paradigma_env):
    provider = make_providers()[0]
    request = build_request_sb(input=imu_input(fs=20.0))
    result = provider.infer(request)
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "withheld"
    assert stages["tremor"]["reason"] == "unsupported_native_rate"
    assert stages["arm_swing"]["status"] == "withheld"
    assert stages["arm_swing"]["reason"] == "unsupported_native_rate"


def test_missing_imu_withholds_with_artifact_unavailable(paradigma_env):
    provider = make_providers()[0]
    request = build_request_sb(input={"families": ["tremor", "arm_swing"]})
    result = provider.infer(request)
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "withheld"
    assert stages["tremor"]["reason"] == "artifact_unavailable"


def test_tremor_runs_even_when_arm_swing_gated(paradigma_env):
    """A failed arm-swing gate never drops tremor (independent families)."""
    provider = make_providers()[0]
    request = build_request_sb(input=imu_input(watch_side="unknown"))
    result = provider.infer(request)
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "ok"
    assert stages["arm_swing"]["status"] == "withheld"
    # tremor actually classified: 40 s -> ~9 four-second windows
    assert stages["tremor"]["measurements"]["eligible_rest_seconds"]["count"] > 0
