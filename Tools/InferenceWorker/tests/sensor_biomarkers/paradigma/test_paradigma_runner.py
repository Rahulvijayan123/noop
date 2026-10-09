"""End-to-end runner tests with the REAL assets and REAL pipeline (W3).

These tests execute the actual ParaDigMa 1.1.2 package (pinned upstream
commit) through the provider's bounded subprocess. They SKIP when the
paradigma subprocess venv is unavailable.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

from pd_fixtures import venv_python
from frwhoop_inference.sensor_biomarkers.paradigma import make_providers
from pd_fixtures import (manifest_with_paradigma, paradigma_env,
                          provisioned_root, real_asset_bytes,
                          venv_python_fixture)
from frwhoop_inference.sensor_biomarkers.paradigma import provider as provider_module
from frwhoop_inference.sensor_biomarkers.paradigma.axes import WHOOP5_TO_PARADIGMA
from frwhoop_inference.sensor_biomarkers.paradigma.provider import (
    PROVIDER_ID,
    ParadigmaProvider,
)
from frwhoop_inference.contract import InferRequest, parse_context


def sb_request(input_block: dict) -> InferRequest:
    context = parse_context({
        "user_id": "u1", "device_id": "d1",
        "interval_start_utc": "2026-10-06T00:00:00Z",
        "interval_end_utc": "2026-10-06T01:00:00Z",
        "iana_timezone": "UTC",
        "profile_version": "p", "config_version": "c", "corrections_version": "k",
    })
    return InferRequest(
        metric="sensor_biomarkers", context=context, input=input_block,
        provider_id=PROVIDER_ID, expected_versions=None,
        raw_input=dict(input_block), input_sha256="x", input_refs=())


def synth_input(seconds, mode="noise", fs=100.0, families=("tremor", "arm_swing"),
                watch_side="left", device_orientation="screen_up"):
    n = int(seconds * fs)
    t = np.arange(n) / fs
    rng = np.random.default_rng(101)
    if mode == "noise":
        gyro = rng.normal(0, 0.05, (n, 3))
        accel = np.tile([0.0, 0.0, 1.0], (n, 1)) + rng.normal(0, 0.02, (n, 3))
    elif mode == "flat":
        gyro = np.zeros((n, 3))
        accel = np.tile([0.0, 0.0, 1.0], (n, 1))
    elif mode == "5hz":
        gyro = np.column_stack([
            2.0 * np.sin(2 * np.pi * 5 * t),
            2.0 * np.cos(2 * np.pi * 5 * t + 0.3),
            0.5 * np.sin(2 * np.pi * 5 * t + 1.0)])
        accel = np.tile([0.0, 0.0, 1.0], (n, 1))
    else:
        raise ValueError(mode)
    return {
        "imu": {
            "sampling_rate_hz": fs,
            "units": {"accel": "g", "gyro": "deg/s"},
            "segments": [{
                "start_unix": 1_700_000_000,
                "duration_s": seconds,
                "accel_g": accel.tolist(),
                "gyro_dps": gyro.tolist(),
            }],
        },
        "watch_side": watch_side,
        "device_orientation": device_orientation,
        "families": list(families),
    }


def provider_one(paradigma_env) -> ParadigmaProvider:
    providers = make_providers()
    assert len(providers) == 1
    return providers[0]


# ---------------------------------------------------------------------------

def test_tremor_inference_with_real_assets(paradigma_env):
    """Real pipeline on synthetic noise: window timing, columns, parity."""
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(40.0, mode="noise")))
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    tremor = stages["tremor"]
    assert tremor["status"] == "ok"
    m = tremor["measurements"]
    # 40 s at 100 Hz -> ~9 four-second windows (the final partial second is
    # dropped by the library's resample-to-uniform-grid).
    assert m["eligible_rest_seconds"]["count"] == 9
    assert m["eligible_rest_seconds"]["value"] == pytest.approx(36.0)
    assert m["classified_tremor_seconds"]["count"] == 0
    assert m["rest_tremor_time_percent"]["value"] == pytest.approx(0.0)
    assert m["tremor_frequency_median_hz"]["value"] is None
    assert m["paradigma_tremor_power_median"]["unit"] == "(deg/s)^2"
    assert m["paradigma_tremor_power_median"]["value"] is None
    assert tremor["reason_counts"]["windows_total"] == 9
    assert tremor["quantification_parity_with_orchestrator"] is True
    assert result.coverage["tremor"]["eligible_seconds"] == pytest.approx(36.0)
    assert result.coverage["tremor"]["observed_seconds"] == pytest.approx(40.0)


def test_flat_signal_negative_control(paradigma_env):
    """Flat gyro: every window arm-at-rest, ZERO tremor windows (never fabricate)."""
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(60.0, mode="flat")))
    stages = {s["family"]: s for s in result.stages}
    tremor = stages["tremor"]
    assert tremor["status"] == "ok"
    m = tremor["measurements"]
    assert m["eligible_rest_seconds"]["count"] == 14
    assert m["classified_tremor_seconds"]["count"] == 0
    assert m["classified_tremor_seconds"]["value"] == 0.0
    assert m["rest_tremor_time_percent"]["value"] == pytest.approx(0.0)
    assert m["tremor_frequency_median_hz"]["value"] is None
    assert tremor["reason_counts"]["classified_tremor"] == 0


def test_5hz_frequency_detection_not_asserted_as_tremor(paradigma_env):
    """5 Hz synthetic motion: frequency detection is stable, classification is NOT
    asserted (the model's decision on synthetic signals is not a guarantee)."""
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(60.0, mode="5hz")))
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    tremor = stages["tremor"]
    assert tremor["status"] == "ok"
    m = tremor["measurements"]
    # The signal's PSD peak is at exactly 5.0 Hz; detection must find it.
    assert m["tremor_frequency_median_hz"]["value"] == pytest.approx(5.0, abs=0.01)
    assert m["eligible_rest_seconds"]["count"] == 14
    # Deliberately NOT asserting classified_tremor_seconds > 0: synthetic 5 Hz
    # motion is not guaranteed to be classified as rest tremor.
    diag = result.diagnostics["tremor"]
    assert diag["freq_peak_distribution"]["n"] == 14


def test_short_input_withheld_not_enough_valid_data(paradigma_env):
    """Under one 4 s window -> withheld not_enough_valid_data, null burden."""
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(2.0, mode="noise")))
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "withheld"
    assert stages["tremor"]["reason"] == "not_enough_valid_data"
    assert stages["tremor"]["measurements"] == {}
    assert stages["arm_swing"]["status"] == "withheld"


def test_short_run_beside_long_run_is_left_out_not_adapter_broken(paradigma_env):
    """A run that cannot fill one window used to fail the whole runner job (adapter_broken)."""
    provider = provider_one(paradigma_env)
    block = synth_input(40.0, mode="noise")
    rng = np.random.default_rng(102)
    n = 300  # 3 s at 100 Hz, after a 10 s gap
    block["imu"]["segments"].append({
        "start_unix": 1_700_000_050,
        "duration_s": 3.0,
        "accel_g": (np.tile([0.0, 0.0, 1.0], (n, 1)) + rng.normal(0, 0.02, (n, 3))).tolist(),
        "gyro_dps": rng.normal(0, 0.05, (n, 3)).tolist(),
    })
    result = provider.infer(sb_request(block))
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "ok"
    assert stages["tremor"]["measurements"]["eligible_rest_seconds"]["count"] == 9
    assert result.coverage["tremor"]["observed_seconds"] == pytest.approx(43.0)
    assert result.diagnostics["short_runs_excluded"]["count"] == 1
    assert result.diagnostics["short_runs_excluded"]["seconds"] == pytest.approx(3.0)


def test_low_rate_withheld_unsupported_native_rate(paradigma_env):
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(40.0, fs=25.0)))
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "withheld"
    assert stages["tremor"]["reason"] == "unsupported_native_rate"


def test_deterministic_reproducibility_on_cpu(paradigma_env):
    """Two identical runs must produce byte-identical family documents."""
    provider = provider_one(paradigma_env)
    request = sb_request(synth_input(40.0, mode="5hz"))
    first = provider.infer(request)
    second = provider.infer(request)
    a = json.dumps({"stages": first.stages, "coverage": first.coverage,
                    "diagnostics": first.diagnostics}, sort_keys=True, default=str)
    b = json.dumps({"stages": second.stages, "coverage": second.coverage,
                    "diagnostics": second.diagnostics}, sort_keys=True, default=str)
    assert a == b


def test_combined_tremor_and_gait_path(paradigma_env, monkeypatch):
    """With the axis convention marked verified, the combined run_paradigma
    (tremor + gait) path executes; synthetic data yields no clean gait."""
    # arm_swing is currently gated by the unverified WHOOP axis convention;
    # lift the gate for this test only to exercise the combined subprocess path.
    monkeypatch.setattr(provider_module, "WHOOP5_AXIS_CONVENTION_VERIFIED", True)
    monkeypatch.setattr(provider_module, "rotation_can_enable_arm_swing", lambda: True)
    provider = provider_one(paradigma_env)
    result = provider.infer(sb_request(synth_input(60.0, mode="noise")))
    assert result.status == "ok"
    stages = {s["family"]: s for s in result.stages}
    assert stages["tremor"]["status"] == "ok"
    arm = stages["arm_swing"]
    assert arm["status"] == "ok"
    # synthetic noise is not classified as gait -> zero eligible arm swing,
    # but the measurement must be a real zero, never a percentage of the day.
    assert arm["measurements"]["eligible_arm_swing_seconds"]["value"] == 0.0
    assert arm["measurements"]["arm_swing_bout_count"]["value"] == 0
    # zero-bout family publishes only the two zero counts; no fabricated ROM/PAV
    assert "arm_swing_rom_median_deg" not in arm["measurements"]
    assert result.coverage["arm_swing"]["eligible_seconds"] == 0.0
