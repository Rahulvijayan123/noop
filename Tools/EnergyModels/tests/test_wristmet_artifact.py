"""Checks on the built WristMET artifact, manifest and golden fixture.

Everything here skips cleanly when ``artifacts/wristmet`` has not been built; none of it needs the
Zenodo recordings. The rebuild-determinism test at the bottom runs only when ``WRISTMET_RESEARCH_DIR`` points
to a research directory that contains the data (it takes minutes).
"""

from __future__ import annotations

import gzip
import hashlib
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import pytest

from energy_models.wristmet import WristMetModel, features as F

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_DIR = ROOT / "artifacts" / "wristmet"
ARTIFACT = ARTIFACT_DIR / "wristmet-v1.json.gz"
MANIFEST = ARTIFACT_DIR / "manifest.json"
NOTICE = ARTIFACT_DIR / "NOTICE.md"
GOLDEN = ROOT / "tests" / "fixtures" / "wristmet_golden.json"
SIZE_LIMIT = 3 * 1024 * 1024

pytestmark = pytest.mark.skipif(
    not (ARTIFACT.exists() and MANIFEST.exists()),
    reason="WristMET artifact not built (python scripts/build_wristmet.py --research-dir ...)",
)


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(MANIFEST.read_text())


@pytest.fixture(scope="module")
def model(manifest) -> WristMetModel:
    return WristMetModel.load(ARTIFACT, expected_sha256=manifest["artifact"]["sha256"])


@pytest.fixture(scope="module")
def golden() -> dict:
    if not GOLDEN.exists():
        pytest.skip("golden fixture missing")
    return json.loads(GOLDEN.read_text())


@pytest.fixture(scope="module")
def golden_windows(golden) -> np.ndarray:
    return np.asarray(golden["windows"], dtype=np.float64)


# ---------------------------------------------------------------- manifest and licences

def test_manifest_matches_the_artifact_bytes(manifest):
    art = manifest["artifact"]
    data = ARTIFACT.read_bytes()
    assert art["path"] == ARTIFACT.name and art["bytes_gz"] == len(data)
    assert hashlib.sha256(data).hexdigest() == art["sha256"]
    raw = gzip.decompress(data)
    assert len(raw) == art["bytes_json"] and hashlib.sha256(raw).hexdigest() == art["sha256_json"]
    assert art["committed_to_git"] == (len(data) <= SIZE_LIMIT)
    assert manifest["model_id"] == "wristmet-v1" == json.loads(raw)["model_id"]


def test_manifest_records_provenance_licences_and_versions(manifest):
    prov = manifest["provenance"]
    assert prov["code"]["commit"] == "3d3517cb95ef490d5e867ebf6a7207b8f7278788"
    assert prov["code"]["license"] == "MIT" and "HABits Lab" in prov["code"]["copyright"]
    assert prov["data"]["zenodo_record"] == 14858226 and prov["data"]["doi"] == "10.5281/zenodo.14858226"
    assert prov["data"]["md5"] == "1840803700111c0a1871e9af3eacc9be" and prov["data"]["license"] == "CC BY 4.0"
    assert "NOT the authors' pretrained weights" in prov["weights"]
    versions = manifest["training"]["library_versions"]
    for lib in ("python", "numpy", "scikit-learn", "xgboost", "pandas"):
        assert versions.get(lib)
    assert manifest["dataset"]["zenodo_zip_md5_matches_record"] is True
    assert manifest["dataset"]["n_participants"] == 26 and manifest["dataset"]["n_windows_60s"] == 2189

    notice = NOTICE.read_text()
    for needle in (
        "CC BY 4.0",
        "MIT License",
        "Copyright (c) 2025 The HABits Lab",
        "10.5281/zenodo.14858226",
        "10.1038/s41598-025-99963-0",
        "not** the authors' pretrained model",
    ):
        assert needle in notice


def test_manifest_loso_table_is_complete_and_honest(manifest):
    loso = manifest.get("loso")
    assert loso is not None, "the committed manifest must come from a full build (evaluation suite included)"
    p = loso["w60_primary"]
    for key in ("rmse_overall", "rmse_sedentary", "rmse_light", "rmse_mod_vig"):
        assert 0.0 < p[key] < 3.0
        assert loso["paper_comparison"][f"60s_{key}"]["ours_loso"] == p[key]
    for key in ("precision", "recall", "f1"):
        assert 0.0 <= p["classifier_sedentary_positive"][key] <= 1.0
    assert loso["paper"]["60s"]["rmse_overall"] == 0.281 and loso["paper"]["15s"]["rmse_overall"] == 0.326
    assert loso["w15_primary"]["rmse_overall"] > 0.0
    abl = loso["w60_ablation_demographics_free"]
    assert abl["two_intensity_features"]["rmse_overall"] > 0.0 and abl["nine_features"]["rmse_overall"] == p["rmse_overall"]
    assert set(loso["w60_leakage_diagnostics"]) >= {
        "in_sample_classifier_and_regressor",
        "published_loop_leaky_classifier_proper_regressor",
    }
    # the limitation text is generated from the same numbers
    first = manifest["limitations"][0]
    assert f"{p['rmse_overall']:.3f}" in first and "NOT reproduced" in first


def test_manifest_ood_section_documents_the_formula_and_an_out_of_cohort_example(manifest, model):
    ood = manifest["ood"]
    assert "acc_mean_norm" in ood["signal_formula"] and "z_age" in ood["demographic_formula"]
    example = ood["out_of_cohort_example"]
    assert (example["age"], example["sex"], example["weight_kg"], example["height_cm"]) == (22.0, "male", 70.0, 175.0)
    live = model.ood_demographic(age=22.0, sex="male", weight_kg=70.0, height_cm=175.0)
    assert live == pytest.approx(example["ood_demographic"], abs=1e-4)
    assert 0.5 < live < 1.0  # clearly outside the 25-64 y, BMI 30.5-46.2 training population


# ---------------------------------------------------------------- the loaded model

def test_loaded_model_structure(model):
    assert model.model_id == "wristmet-v1"
    assert (model.window_samples, model.sample_rate_hz) == (1200, 20.0)
    assert model.classifier_feature_names == F.CLASSIFIER_FEATURE_NAMES and len(model.classifier_feature_names) == 42
    assert model.regressor_feature_names == F.REGRESSOR_FEATURE_NAMES and len(model.regressor_feature_names) == 9
    assert model._clf.n_trees == 100 and model._rf.n_trees == 100
    env = model.signal_envelope
    assert len(env.names) == 46 and env.gravity_unit_vectors.shape[1] == 3
    demo = model.demographic_envelope
    assert (demo.age_min, demo.age_max) == (25.0, 64.0)


def test_manifest_envelope_summary_matches_the_model(manifest, model):
    demo = manifest["envelope_summary"]["demographic"]
    assert demo["n_participants"] == 26 and demo["sex_counts"] == {"female": 17, "male": 9}
    assert demo["age"]["min"] == model.demographic_envelope.age_min
    assert demo["bmi"]["max"] == pytest.approx(model.demographic_envelope.bmi_max, abs=1e-3)
    assert manifest["envelope_summary"]["signal"]["n_windows"] == 2189
    envelope = model.spec["training_envelope"]
    for name in ("min", "max", "p0.5", "p99.5"):
        assert name in envelope["regression_features"]["features"]["Intensity (RMSSD_l1)"]


# ---------------------------------------------------------------- golden regression fixture

def test_golden_fixture_is_small_and_consistent(golden, golden_windows):
    assert 1 <= golden_windows.shape[0] <= 8 and golden_windows.shape[1:] == (1200, 6)
    assert golden["model_id"] == "wristmet-v1" and GOLDEN.stat().st_size < 1_000_000


def test_golden_features_match_the_feature_code(golden, golden_windows):
    exp = golden["expected"]
    np.testing.assert_allclose(F.classifier_features(golden_windows), np.asarray(exp["classifier_features"]), rtol=1e-9, atol=1e-12)
    inten = F.regression_intensity_features(golden_windows)
    reg = F.regressor_features(inten, **golden["demographics"])
    np.testing.assert_allclose(reg, np.asarray(exp["regressor_features"]), rtol=1e-9, atol=1e-12)


def test_golden_predictions(golden, golden_windows, manifest, model):
    assert golden["artifact_sha256"] == manifest["artifact"]["sha256"], (
        "golden fixture belongs to a different artifact build; rerun scripts/build_wristmet.py to regenerate both"
    )
    exp = golden["expected"]
    r = model.predict_windows(golden_windows, **golden["demographics"])
    np.testing.assert_allclose(r.met, exp["met"], rtol=0, atol=1e-6)
    np.testing.assert_allclose(r.p_active, exp["p_active"], rtol=0, atol=1e-6)
    np.testing.assert_allclose(r.ood_signal, exp["ood_signal"], rtol=0, atol=1e-6)
    assert r.ood_demographic == pytest.approx(exp["ood_demographic"], abs=1e-9)
    # numpy evaluator vs the scikit-learn / xgboost objects that produced the artifact
    assert np.max(np.abs(r.p_active - np.asarray(exp["xgboost_p_active"]))) <= 1e-5
    assert np.max(np.abs(r.met_if_active - np.asarray(exp["sklearn_met_if_active"]).clip(min=1.0))) <= 1e-6
    np.testing.assert_array_equal(r.is_active, np.asarray(exp["xgboost_p_active"]) > 0.5)
    assert np.all(r.valid) and np.all(r.met >= 1.0) and np.all((r.p_active >= 0.0) & (r.p_active <= 1.0))
    assert np.all((r.ood_signal >= 0.0) & (r.ood_signal <= 1.0)) and 0.0 <= r.ood_demographic <= 1.0


def test_golden_windows_are_in_distribution(golden, golden_windows, model):
    r = model.predict_windows(golden_windows, **golden["demographics"])
    assert r.ood_signal.max() < 0.5


def test_ood_signal_reacts_to_per_axis_gravity_outside_the_training_envelope(golden, golden_windows, model):
    demo = golden["demographics"]
    env = model.signal_envelope
    base = model.predict_windows(golden_windows, **demo).ood_signal
    for axis, label in enumerate("xyz"):
        j = env.names.index(f"mean_acc_{label}")
        band = env.p_high[j] - env.p_low[j]
        shifted = golden_windows.copy()
        mean = shifted[:, :, 3 + axis].mean(axis=1)
        shifted[:, :, 3 + axis] += (env.p_high[j] + band - mean)[:, None]  # one band-width above the training range
        s = model.predict_windows(shifted, **demo).ood_signal
        assert np.all(s >= 1.0 - math.exp(-1.0 / env.range_scale) - 1e-9), (label, s)
        assert np.all(s > base)
        mild = golden_windows.copy()
        mild[:, :, 3 + axis] += (env.p_high[j] + 0.1 * band - mean)[:, None]
        assert np.all(model.predict_windows(mild, **demo).ood_signal < s)  # graded, not binary


def test_ood_signal_reacts_to_unit_mistakes(golden, golden_windows, model):
    demo = golden["demographics"]
    base = model.predict_windows(golden_windows, **demo).ood_signal
    acc_in_g = golden_windows.copy()
    acc_in_g[:, :, 3:6] /= 9.80665
    assert np.all(model.predict_windows(acc_in_g, **demo).ood_signal > 0.5)
    gyr_deg = golden_windows.copy()
    gyr_deg[:, :, 0:3] *= 180.0 / np.pi
    s = model.predict_windows(gyr_deg, **demo).ood_signal
    assert np.all(s >= base - 1e-12)
    moving = np.array([m["measured_met"] >= 3.0 for m in golden["source"]])
    assert moving.any() and np.all(s[moving] > 0.5)


def test_nan_inf_and_short_windows_on_the_real_model(golden, golden_windows, model):
    demo = golden["demographics"]
    w = golden_windows.copy()
    w[0, 100, 3] = np.nan
    w[1, 5, 0] = np.inf
    r = model.predict_windows(w, **demo)
    assert np.isnan(r.met[:2]).all() and np.isnan(r.p_active[:2]).all() and (r.ood_signal[:2] == 1.0).all()
    assert np.isfinite(r.met[2:]).all()
    short = model.predict_windows(golden_windows[:, :1199], **demo)
    assert np.isnan(short.met).all() and (short.ood_signal == 1.0).all()
    clean = model.predict_windows(golden_windows, **demo)
    np.testing.assert_array_equal(r.met[2:], clean.met[2:])  # neighbours unaffected by invalid windows


def test_determinism_and_batch_invariance_on_the_real_model(golden, golden_windows, model):
    demo = golden["demographics"]
    a = model.predict_windows(golden_windows, **demo)
    b = model.predict_windows(golden_windows.copy(), **demo)
    c = WristMetModel.load(ARTIFACT).predict_windows(golden_windows, **demo)
    for name in ("met", "p_active", "ood_signal"):
        np.testing.assert_array_equal(getattr(a, name), getattr(b, name))
        np.testing.assert_array_equal(getattr(a, name), getattr(c, name))
    for i in range(golden_windows.shape[0]):
        one = model.predict_windows(golden_windows[i : i + 1], **demo)
        assert one.met[0] == a.met[i] and one.p_active[0] == a.p_active[i] and one.ood_signal[0] == a.ood_signal[i]
    reordered = model.predict_windows(golden_windows[::-1], **demo)
    np.testing.assert_array_equal(reordered.met[::-1], a.met)


def test_demographics_change_only_the_regression_stage(golden, golden_windows, model):
    demo = dict(golden["demographics"])
    a = model.predict_windows(golden_windows, **demo)
    other = model.predict_windows(golden_windows, age=demo["age"] + 10, sex="male", weight_kg=demo["weight_kg"] + 20, height_cm=demo["height_cm"])
    np.testing.assert_array_equal(a.p_active, other.p_active)  # the classifier does not see demographics
    np.testing.assert_array_equal(a.met[~a.is_active], 1.0)
    assert not np.array_equal(a.met_if_active, other.met_if_active)


def test_runtime_per_window(golden_windows, golden, model):
    demo = golden["demographics"]
    rng = np.random.default_rng(0)
    batch = np.tile(golden_windows, (34, 1, 1))[:200] + rng.normal(0.0, 0.01, (200, 1200, 6))
    model.predict_windows(batch[:4], **demo)  # warm-up
    t0 = time.perf_counter()
    r = model.predict_windows(batch, **demo)
    per_window_ms = (time.perf_counter() - t0) * 1000.0 / 200.0
    assert r.met.shape == (200,) and np.isfinite(r.met).all()
    t0 = time.perf_counter()
    model.predict_windows(batch[:1], **demo)
    single_ms = (time.perf_counter() - t0) * 1000.0
    # measured ~0.4 ms / 1.5 ms on an Apple M-series laptop; the generous bounds only catch algorithmic regressions
    assert per_window_ms < 20.0, per_window_ms
    assert single_ms < 200.0, single_ms


# ---------------------------------------------------------------- opt-in: rebuild from the public data

@pytest.mark.skipif(
    not os.environ.get("WRISTMET_RESEARCH_DIR"),
    reason="set WRISTMET_RESEARCH_DIR to a directory holding zenodo/Phase_2_Data.zip to rebuild (minutes)",
)
def test_rebuild_from_public_data_reproduces_the_artifact(manifest, tmp_path):
    pytest.importorskip("pandas")
    pytest.importorskip("sklearn")
    pytest.importorskip("xgboost")
    pytest.importorskip("openpyxl")
    out = tmp_path / "wristmet"
    cmd = [
        sys.executable,
        str(ROOT / "scripts" / "build_wristmet.py"),
        "--research-dir",
        os.environ["WRISTMET_RESEARCH_DIR"],
        "--out-dir",
        str(out),
        "--golden",
        str(tmp_path / "golden.json"),
        "--skip-loso",
        "--skip-15s",
    ]
    subprocess.run(cmd, check=True, cwd=ROOT)
    rebuilt = (out / ARTIFACT.name).read_bytes()
    expected = manifest["artifact"]["sha256"]
    if hashlib.sha256(rebuilt).hexdigest() != expected:
        versions = json.loads((out / "manifest.json").read_text())["training"]["library_versions"]
        pinned = manifest["training"]["library_versions"]
        assert versions != pinned, "same library versions must give identical bytes"
        pytest.skip(f"library versions differ from the committed build ({versions} vs {pinned}); bytes may legitimately differ")
