"""Raw IMU -> per-minute evidence (``energy_models.evidence``).

The end-to-end checks run the real WristMET artifact on the six public windows in
``tests/fixtures/wristmet_golden.json`` (turned back into a 100 Hz WHOOP-style recording), so a wrong
window, minute alignment, unit or axis step changes a number. The wrist CNN is replaced by a stub unless its
weights have been fetched; ``test_the_real_cnn_...`` runs only then.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import numpy as np
import pytest

from energy_models import evidence as ev
from energy_models.wristmet import AxisMap
from energy_models.wristmet.preprocess import DEG_TO_RAD, STANDARD_GRAVITY_MS2

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ev.DEFAULT_WRISTMET_PATH
GOLDEN = ROOT / "tests" / "fixtures" / "wristmet_golden.json"
EXAMPLE = ROOT / "tests" / "fixtures" / "energy_motion_evidence_v1.example.json"
SWIFT_CONFIG = ROOT.parents[1] / "Packages/StrandAnalytics/Sources/StrandAnalytics/Energy/EnergyConfig.swift"

T0_MS = 1_790_035_200_000          # a minute boundary
assert T0_MS % ev.MINUTE_MS == 0


class StubCNN:
    """Stands in for ``WristCNN``: constant output, remembers what it was asked to run on."""

    def __init__(self, value: float = 3.3):
        self.value = value
        self.shapes: list[tuple[int, ...]] = []

    def predict(self, windows, **_):
        windows = np.asarray(windows)
        self.shapes.append(windows.shape)
        return np.full(windows.shape[0], self.value)


@pytest.fixture(scope="module")
def bundle():
    return ev.load_wristmet(ARTIFACT)


@pytest.fixture(scope="module")
def golden():
    if not GOLDEN.exists():
        pytest.skip("golden fixture missing")
    return json.loads(GOLDEN.read_text())


@pytest.fixture(scope="module")
def wearer(golden):
    d = golden["demographics"]
    return ev.Wearer(d["age"], d["sex"], d["weight_kg"], d["height_cm"])


def to_raw(windows: np.ndarray, start_ms: float, *, with_gyr: bool = True) -> ev.Recording:
    """Consecutive 20 Hz model-space windows -> one continuous 100 Hz recording in WHOOP-style units.

    The 20 Hz samples sit exactly on every fifth raw sample, so resampling the recording back to 20 Hz on
    the same grid returns the original windows: the pipeline's output can be compared with the golden one.
    """
    n, length, _ = windows.shape
    series = windows.reshape(n * length, 6)                       # gyr_xyz (rad/s), acc_xyz (m/s^2)
    t20 = np.arange(n * length) * 50.0
    # Run to 10 ms before the next minute so the last minute holds the full 6,000 samples the CNN needs
    # (the final 40 ms repeat the last 20 Hz sample).
    t100 = np.arange(0.0, n * length * 50.0 - 10.0 + 1e-9, 10.0)
    cols = [np.interp(t100, t20, series[:, c]) for c in range(6)]
    acc = np.column_stack(cols[3:]) / STANDARD_GRAVITY_MS2
    gyr = np.column_stack(cols[:3]) / DEG_TO_RAD if with_gyr else None
    return ev.Recording(start_ms + t100, acc, gyr, "g", "deg/s")


def drop(rec: ev.Recording, keep: np.ndarray) -> ev.Recording:
    return ev.Recording(rec.t_ms[keep], rec.acc[keep], None if rec.gyr is None else rec.gyr[keep],
                        rec.acc_unit, rec.gyr_unit)


@pytest.fixture(scope="module")
def raw(golden):
    return to_raw(np.asarray(golden["windows"], dtype=np.float64), T0_MS)


@pytest.fixture(scope="module")
def doc(raw, wearer, bundle):
    return ev.build_evidence(raw, wearer, wristmet=bundle)


# ------------------------------------------------------------------ WristMET through the whole chain

def test_round_trip_through_a_100hz_recording_reproduces_the_golden_wristmet_outputs(doc, golden):
    exp = golden["expected"]
    minutes = doc["minutes"]
    assert [m["t"] for m in minutes] == [T0_MS // 1000 + 60 * i for i in range(6)]
    for m, met, p, ood in zip(minutes, exp["met"], exp["p_active"], exp["ood_signal"]):
        w = m["wristmet"]
        assert w["met"] == pytest.approx(met, abs=2e-3)
        assert w["p_active"] == pytest.approx(p, abs=2e-4)
        assert w["ood"] == pytest.approx(ood, abs=2e-3)
        assert m["imu_s"] == 60


def test_minutes_follow_the_wall_clock_not_the_recording_start(raw, wearer, bundle):
    shifted = ev.Recording(raw.t_ms + 13_700.0, raw.acc, raw.gyr, raw.acc_unit, raw.gyr_unit)
    d = ev.build_evidence(shifted, wearer, wristmet=bundle)
    ts = [m["t"] for m in d["minutes"]]
    assert all(t % 60 == 0 for t in ts)
    assert ts == [T0_MS // 1000 + 60 * i for i in range(1, 6)], "the partial first and last minutes are not modelled"
    assert d["provenance"]["counts"]["skipped_gap_or_late_start"] == 1   # first minute starts 13.7 s late
    assert d["provenance"]["counts"]["skipped_short_imu"] == 1           # the 13.65 s tail


def test_a_gap_costs_that_minute_and_only_that_minute(raw, wearer, bundle, doc):
    gap = (raw.t_ms >= T0_MS + 120_000 + 20_000) & (raw.t_ms < T0_MS + 120_000 + 25_000)
    d = ev.build_evidence(drop(raw, ~gap), wearer, wristmet=bundle)
    assert [m["t"] for m in d["minutes"]] == [T0_MS // 1000 + 60 * i for i in (0, 1, 3, 4, 5)]
    by_t = {m["t"]: m for m in doc["minutes"]}
    for m in d["minutes"]:
        assert m["wristmet"] == by_t[m["t"]]["wristmet"], "minutes around a gap are unaffected"
    assert d["provenance"]["counts"]["skipped_gap_or_late_start"] == 1


def test_a_sub_second_dropout_is_tolerated_but_a_longer_one_is_not(raw, wearer, bundle):
    short = (raw.t_ms >= T0_MS + 30_000) & (raw.t_ms < T0_MS + 30_400)
    assert len(ev.build_evidence(drop(raw, ~short), wearer, wristmet=bundle)["minutes"]) == 6
    longer = (raw.t_ms >= T0_MS + 30_000) & (raw.t_ms < T0_MS + 30_700)
    assert len(ev.build_evidence(drop(raw, ~longer), wearer, wristmet=bundle)["minutes"]) == 5


def test_a_minute_with_too_little_imu_is_skipped_and_counted(raw, wearer, bundle):
    keep = ~((raw.t_ms >= T0_MS + 60_000 + 20_000) & (raw.t_ms < T0_MS + 120_000))   # 20 s of minute 1 left
    d = ev.build_evidence(drop(raw, keep), wearer, wristmet=bundle)
    assert T0_MS // 1000 + 60 not in [m["t"] for m in d["minutes"]]
    assert d["provenance"]["counts"]["skipped_short_imu"] == 1


def test_unsorted_and_duplicated_samples_do_not_change_the_result(raw, wearer, bundle, doc):
    rng = np.random.default_rng(3)
    order = rng.permutation(raw.t_ms.size)
    dup = np.concatenate([order, order[:5000]])
    scrambled = ev.Recording(raw.t_ms[dup], raw.acc[dup], raw.gyr[dup], raw.acc_unit, raw.gyr_unit)
    assert ev.build_evidence(scrambled, wearer, wristmet=bundle)["minutes"] == doc["minutes"]


def test_non_finite_samples_are_dropped_not_propagated(raw, wearer, bundle):
    acc = raw.acc.copy()
    acc[1000, 0] = np.nan
    d = ev.build_evidence(ev.Recording(raw.t_ms, acc, raw.gyr, "g", "deg/s"), wearer, wristmet=bundle)
    assert all(np.isfinite(m["wristmet"]["met"]) for m in d["minutes"])
    assert len(d["minutes"]) == 6        # one missing 10 ms sample is inside the 500 ms tolerance


def test_the_wearers_demographics_are_not_written_but_their_distance_from_the_cohort_is(raw, bundle):
    w = ev.Wearer(41.37, "male", 91.23, 181.7)
    d = ev.build_evidence(raw, w, wristmet=bundle)
    text = json.dumps(d)
    for secret in ("41.37", "91.23", "181.7", "weight", "height", '"age"'):
        assert secret not in text
    expected = round(bundle.model.ood_demographic(age=41.37, sex="male", weight_kg=91.23, height_cm=181.7), 3)
    assert {m["demog_ood"] for m in d["minutes"]} == {expected}


def test_a_young_lean_wearer_is_flagged_as_outside_the_training_cohort(raw, bundle):
    young_lean = ev.Wearer(22.0, "male", 70.0, 175.0)
    d = ev.build_evidence(raw, young_lean, wristmet=bundle)
    assert d["minutes"][0]["demog_ood"] > 0.5


def test_left_wrist_is_mirrored_into_the_training_frame(raw, golden, bundle):
    d = golden["demographics"]
    right = ev.build_evidence(raw, ev.Wearer(d["age"], d["sex"], d["weight_kg"], d["height_cm"], "right"), wristmet=bundle)
    left = ev.build_evidence(raw, ev.Wearer(d["age"], d["sex"], d["weight_kg"], d["height_cm"], "left"), wristmet=bundle)
    assert len(left["minutes"]) == len(right["minutes"])
    assert [m["wristmet"] for m in left["minutes"]] != [m["wristmet"] for m in right["minutes"]]
    assert left["provenance"]["wrist"] == "left"


def test_an_axis_map_changes_the_windows_and_is_recorded(raw, wearer, bundle, doc):
    swapped = AxisMap(acc_source=(1, 0, 2), acc_sign=(1.0, 1.0, -1.0))
    d = ev.build_evidence(raw, wearer, wristmet=bundle, axis_map=swapped)
    assert d["minutes"] != doc["minutes"]
    assert d["provenance"]["axis_map"]["is_identity"] is False
    assert doc["provenance"]["axis_map"]["is_identity"] is True


# ------------------------------------------------------------------ the wrist CNN

def test_the_cnn_runs_only_on_minutes_wristmet_calls_non_sedentary(raw, wearer, bundle, golden):
    cnn = StubCNN(3.3)
    d = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=cnn)
    active = [i for i, m in enumerate(golden["expected"]["met"]) if m > 1.0]
    got = [i for i, m in enumerate(d["minutes"]) if "cnn" in m]
    assert got == active == [3, 4, 5]
    assert sum(s[0] for s in cnn.shapes) == 3
    assert all(s[1:] == (6000, 3) for s in cnn.shapes)
    c = d["minutes"][3]["cnn"]
    assert c == {"met": 3.3, "ood": c["ood"], "model": ev.CNN_MODEL_ID}
    assert 0.0 <= c["ood"] <= 1.0
    assert d["provenance"]["counts"]["cnn"] == 3


def test_the_cnn_does_not_change_wristmets_numbers(raw, wearer, bundle, doc):
    with_cnn = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=StubCNN(7.7))
    assert [m["wristmet"] for m in with_cnn["minutes"]] == [m["wristmet"] for m in doc["minutes"]]


def test_the_cnn_output_is_floored_at_one_met(raw, wearer, bundle):
    d = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=StubCNN(0.4))
    assert {m["cnn"]["met"] for m in d["minutes"] if "cnn" in m} == {1.0}


def test_without_a_gyroscope_wristmet_is_not_run_and_the_cnn_carries_the_minute(golden, wearer, bundle):
    rec = to_raw(np.asarray(golden["windows"], dtype=np.float64), T0_MS, with_gyr=False)
    cnn = StubCNN(2.5)
    d = ev.build_evidence(rec, wearer, wristmet=bundle, cnn=cnn)
    assert d["minutes"], "the CNN needs only the accelerometer"
    assert all("wristmet" not in m and "demog_ood" not in m for m in d["minutes"])
    assert all(m["cnn"]["met"] == 2.5 for m in d["minutes"])
    assert d["provenance"]["wristmet"]["ran"] is False
    cnn_only = ev.build_evidence(rec, wearer, wristmet=None, cnn=StubCNN(2.5))
    assert cnn_only["minutes"] == d["minutes"]


def test_policy_all_also_runs_the_cnn_on_non_motionless_sedentary_minutes(raw, wearer, bundle):
    active_only = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=StubCNN(), cnn_policy="active")
    everything = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=StubCNN(), cnn_policy="all")
    n_active = sum("cnn" in m for m in active_only["minutes"])
    n_all = sum("cnn" in m for m in everything["minutes"])
    assert n_all >= n_active == 3
    with pytest.raises(ValueError):
        ev.build_evidence(raw, wearer, wristmet=bundle, cnn_policy="sometimes")


def test_the_real_cnn_agrees_with_calling_it_directly(raw, wearer, bundle):
    cnn = ev.load_cnn()
    if cnn is None:
        pytest.skip("wrist CNN weights not fetched (scripts/fetch_wrist_cnn.sh)")
    from energy_models.wrist_cnn.inputs import prepare_windows

    d = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=cnn)
    k = next(i for i, m in enumerate(d["minutes"]) if "cnn" in m)
    lo = np.searchsorted(raw.t_ms, T0_MS + 60_000 * k)
    hi = np.searchsorted(raw.t_ms, T0_MS + 60_000 * (k + 1) + 1_000)
    prepared = prepare_windows(raw.acc[lo:hi], timestamps=(raw.t_ms[lo:hi] - (T0_MS + 60_000 * k)) / 1000.0,
                               fs=100.0, window_s=60.0, step_s=60.0)
    direct = float(cnn.predict(prepared.windows[:1])[0])
    assert d["minutes"][k]["cnn"]["met"] == pytest.approx(max(1.0, direct), abs=2e-3)


# ------------------------------------------------------------------ input validation

def test_acceleration_in_the_wrong_unit_is_refused(raw, wearer, bundle):
    ms2 = ev.Recording(raw.t_ms, raw.acc * STANDARD_GRAVITY_MS2, raw.gyr, "g", "deg/s")
    with pytest.raises(ValueError, match="m/s"):
        ev.build_evidence(ms2, wearer, wristmet=bundle)
    ok = ev.Recording(raw.t_ms, raw.acc * STANDARD_GRAVITY_MS2, raw.gyr, "m/s2", "deg/s")
    assert len(ev.build_evidence(ok, wearer, wristmet=bundle)["minutes"]) == 6
    with pytest.raises(ValueError, match="looks like g"):
        ev.build_evidence(ev.Recording(raw.t_ms, raw.acc, raw.gyr, "m/s2", "deg/s"), wearer, wristmet=bundle)


def test_mismatched_array_shapes_are_refused(raw, wearer, bundle):
    with pytest.raises(ValueError):
        ev.build_evidence(ev.Recording(raw.t_ms[:-1], raw.acc, raw.gyr), wearer, wristmet=bundle)


def test_an_empty_or_tiny_recording_gives_an_empty_document(wearer, bundle):
    d = ev.build_evidence(ev.Recording(np.array([T0_MS]), np.array([[0.0, 0.0, 1.0]]), None), wearer, wristmet=bundle)
    assert d["minutes"] == [] and d["schema"] == ev.SCHEMA


def test_profile_must_name_the_wearer():
    with pytest.raises(ValueError, match="weight_kg"):
        ev.Wearer.from_dict({"age": 30, "sex": "male", "height_cm": 180})


# ------------------------------------------------------------------ identity, contract, drift

def test_model_ids_pin_the_weights(doc, bundle):
    assert re.fullmatch(r"wristmet-v1-[0-9a-f]{8}", bundle.model_id)
    assert bundle.sha256.startswith(bundle.model_id.rsplit("-", 1)[1])
    assert {m["wristmet"]["model"] for m in doc["minutes"]} == {bundle.model_id}
    assert re.fullmatch(r"wrist-cnn-[0-9a-f]{7}", ev.CNN_MODEL_ID)


def test_provenance_records_the_validated_errors_not_the_papers(doc):
    v = doc["provenance"]["wristmet"]["validated_rmse_met"]
    assert v["sedentary"] < 0.4 < 1.0 < v["non_sedentary_regressor"] < 1.6
    assert 0.7 < v["overall"] < 0.9, "genuine leave-one-participant-out error, not the 0.281 the paper reports"


def test_a_tampered_artifact_is_refused(tmp_path):
    bad = tmp_path / "wristmet-v1.json.gz"
    bad.write_bytes(ARTIFACT.read_bytes()[:-8] + b"tampered")
    (tmp_path / "manifest.json").write_text((ARTIFACT.parent / "manifest.json").read_text())
    with pytest.raises(ValueError, match="sha256 mismatch"):
        ev.load_wristmet(bad)


def test_every_emitted_field_is_one_the_swift_decoder_knows(raw, wearer, bundle):
    """MotionEvidence.swift: minute keys t, imu_s, wristmet, cnn, demog_ood; estimate keys met, ood, p_active, model."""
    d = ev.build_evidence(raw, wearer, wristmet=bundle, cnn=StubCNN())
    assert d["schema"] == "energy-motion-evidence-v1" and d["minutes"]
    saw_cnn = False
    for m in d["minutes"]:
        assert set(m) <= {"t", "imu_s", "wristmet", "cnn", "demog_ood"}
        assert isinstance(m["t"], int) and isinstance(m["imu_s"], int)
        assert set(m["wristmet"]) == {"met", "p_active", "ood", "model"}
        if "cnn" in m:
            saw_cnn = True
            assert set(m["cnn"]) == {"met", "ood", "model"}
    assert saw_cnn


def test_the_committed_example_is_what_the_pipeline_emits(golden, wearer, bundle):
    """The Swift test decodes this file with MotionEvidenceDocument, so the two languages cannot drift apart.

    Regenerate after an intentional change with ``UPDATE_FIXTURES=1 pytest tests/test_evidence.py``.
    The CNN entries come from a constant stub so every field of the schema is covered; they are not real
    model output.
    """
    import os

    windows = np.asarray(golden["windows"], dtype=np.float64)[2:5]
    fresh = ev.build_evidence(to_raw(windows, T0_MS), wearer, wristmet=bundle, cnn=StubCNN(3.3))
    fresh["provenance"].pop("generator")
    fresh["note"] = ("Test fixture. WristMET values are real output for three public windows of the Zenodo "
                     "14858226 dataset; the 'cnn' values are a constant stub (3.3), not model output.")
    if os.environ.get("UPDATE_FIXTURES"):
        EXAMPLE.write_text(json.dumps(fresh, indent=1) + "\n")
    if not EXAMPLE.exists():
        pytest.fail(f"{EXAMPLE} is missing; run with UPDATE_FIXTURES=1")
    committed = json.loads(EXAMPLE.read_text())
    assert committed["schema"] == fresh["schema"]
    assert [m["t"] for m in committed["minutes"]] == [m["t"] for m in fresh["minutes"]]
    for a, b in zip(committed["minutes"], fresh["minutes"]):
        assert set(a) == set(b)
        assert a["wristmet"]["model"] == b["wristmet"]["model"]
        for key in ("met", "p_active", "ood"):
            assert a["wristmet"][key] == pytest.approx(b["wristmet"][key], abs=2e-3)
        assert ("cnn" in a) == ("cnn" in b)


def test_swift_wristmet_sigmas_match_the_validated_errors(bundle):
    """EnergyConfig.wristMETSigmaSedentary / Active are documented as the manifest's leave-one-out errors."""
    if not SWIFT_CONFIG.exists():
        pytest.skip("Swift sources not alongside this package")
    text = SWIFT_CONFIG.read_text()

    def value(name: str) -> float:
        m = re.search(rf"var {name}:\s*Double\s*=\s*([0-9.]+)", text)
        assert m, f"{name} not found in EnergyConfig.swift"
        return float(m.group(1))

    v = bundle.validated_rmse
    assert value("wristMETSigmaSedentary") == pytest.approx(v["sedentary"], abs=0.01)
    assert value("wristMETSigmaActive") == pytest.approx(v["non_sedentary_regressor"], abs=0.01)


# ------------------------------------------------------------------ command line

def _write_inputs(tmp_path: Path, raw: ev.Recording, golden: dict) -> tuple[Path, Path]:
    imu = tmp_path / "day.npz"
    np.savez(imu, t_ms=raw.t_ms, acc=raw.acc, gyr=raw.gyr)
    profile = tmp_path / "profile.json"
    profile.write_text(json.dumps(golden["demographics"]))
    return imu, profile


def test_cli_writes_the_same_document_as_the_library(tmp_path, raw, golden, wearer, bundle, doc, capsys):
    imu, profile = _write_inputs(tmp_path, raw, golden)
    out = tmp_path / "evidence.json"
    assert ev.main(["--imu", str(imu), "--profile", str(profile), "--out", str(out), "--cnn", "off"]) == 0
    written = json.loads(out.read_text())
    assert written["minutes"] == doc["minutes"]
    assert "wrote 6 minutes" in capsys.readouterr().out


def test_cli_continues_without_cnn_weights_unless_they_are_required(tmp_path, raw, golden, capsys):
    imu, profile = _write_inputs(tmp_path, raw, golden)
    empty = tmp_path / "no-weights"
    empty.mkdir()
    out = tmp_path / "e.json"
    common = ["--imu", str(imu), "--profile", str(profile), "--out", str(out), "--cnn-dir", str(empty)]
    assert ev.main(common + ["--cnn", "auto"]) == 0
    assert "WristMET only" in capsys.readouterr().err
    assert all("cnn" not in m for m in json.loads(out.read_text())["minutes"])
    assert ev.main(common + ["--cnn", "on"]) == 2


def test_cli_reports_bad_input_with_a_message_and_a_nonzero_exit(tmp_path, raw, golden, capsys):
    imu, profile = _write_inputs(tmp_path, raw, golden)
    profile.write_text(json.dumps({"age": 30}))
    assert ev.main(["--imu", str(imu), "--profile", str(profile), "--out", str(tmp_path / "x.json"), "--cnn", "off"]) == 2
    assert "profile is missing" in capsys.readouterr().err


def test_cli_axis_map_file_is_applied(tmp_path, raw, golden, doc):
    imu, profile = _write_inputs(tmp_path, raw, golden)
    amap = tmp_path / "axes.json"
    amap.write_text(json.dumps({"wristmet": {"acc_source": [1, 0, 2], "acc_sign": [1, 1, -1]}}))
    out = tmp_path / "e.json"
    assert ev.main(["--imu", str(imu), "--profile", str(profile), "--out", str(out), "--cnn", "off",
                    "--axis-map", str(amap)]) == 0
    written = json.loads(out.read_text())
    assert written["minutes"] != doc["minutes"]
    assert written["provenance"]["axis_map"]["acc_source"] == [1, 0, 2]


def test_csv_recordings_load(tmp_path, raw):
    path = tmp_path / "r.csv"
    n = 3000
    header = "t_ms,ax,ay,az,gx,gy,gz"
    rows = np.column_stack([raw.t_ms[:n], raw.acc[:n], raw.gyr[:n]])
    np.savetxt(path, rows, delimiter=",", header=header, comments="", fmt="%.6f")
    rec = ev.load_recording(path)
    assert rec.acc.shape == (n, 3) and rec.gyr.shape == (n, 3)
    np.testing.assert_allclose(rec.t_ms, raw.t_ms[:n])
    with pytest.raises(ValueError):
        ev.load_recording(tmp_path / "r.txt")
