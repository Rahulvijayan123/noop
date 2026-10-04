"""Provenance tests: the committed manifest / NOTICE / requirements agree with the code, no weights
are tracked, the package imports numpy only, and the fetch script reports the documented exit codes.

None of these tests needs the downloaded weights or the network.
"""

from __future__ import annotations

import copy
import json
import os
import re
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

from energy_models.wrist_cnn import manifest as mf  # noqa: E402
from energy_models.wrist_cnn.pins import (  # noqa: E402
    PAPER_DOI,
    PINNED_COMMIT,
    PINS,
    UPSTREAM_URL,
)
from energy_models.wrist_cnn.spec import HEADS, WEIGHT_KEYS, macs_per_window, parameter_count  # noqa: E402

ART = _ROOT / "artifacts" / "wrist_cnn"
MANIFEST = ART / "manifest.json"
NOTICE = ART / "NOTICE.md"
SCRIPT = _ROOT / "scripts" / "fetch_wrist_cnn.sh"
HEX64 = re.compile(r"^[0-9a-f]{64}$")


@pytest.fixture(scope="module")
def committed() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


# ------------------------------------------------------------------ manifest


def test_committed_manifest_is_canonical_ascii_json(committed):
    text = MANIFEST.read_text(encoding="utf-8")
    assert text.isascii() and text.endswith("\n")
    assert mf.render(committed) == text


def test_code_derived_sections_of_the_committed_manifest_are_current(committed):
    assert mf.stale_sections(committed) == []


def test_manifest_pins_equal_the_pins_module_field_by_field(committed):
    assert committed["upstream"]["pinned_commit"] == PINNED_COMMIT
    assert committed["upstream"]["repository"] == UPSTREAM_URL
    assert committed["upstream"]["paper"]["doi"] == PAPER_DOI
    assert set(committed["upstream"]["files"]) == set(HEADS) == set(committed["converted"])
    for head in HEADS:
        up, pin = committed["upstream"]["files"][head], PINS.upstream[head]
        assert (up["path"], up["size_bytes"], up["sha256"], up["git_blob_sha1"]) == (
            pin.path, pin.size, pin.sha256, pin.git_blob_sha1,
        )
        assert PINNED_COMMIT in up["url"] and up["url"].endswith(pin.path)
        conv, npz = committed["converted"][head], PINS.npz[head]
        assert (conv["filename"], conv["size_bytes"], conv["sha256"]) == (npz.filename, npz.size, npz.sha256)
        assert conv["tensors"] == len(WEIGHT_KEYS) and conv["parameters"] == parameter_count(head)
        assert conv["dtype"] == "float32"
        assert HEX64.match(up["sha256"]) and HEX64.match(conv["sha256"])
        assert len(up["git_blob_sha1"]) == 40


def test_manifest_architecture_numbers_come_from_the_spec(committed):
    arch = committed["architecture"]
    assert arch["parameters"] == {h: parameter_count(h) for h in HEADS} == {"regression": 1455621, "classification": 1456103}
    assert arch["multiply_accumulates_per_window"] == {h: macs_per_window(h) for h in HEADS}
    assert arch["time_lengths_after_stage"]["conv6"] == 640 and arch["time_lengths_after_stage"]["pool_after_conv4"] == 658
    kinds = [layer["layer"] for layer in arch["layers"]]
    assert kinds.count("Conv1D") == 6 and kinds.count("MaxPooling1D") == 2 and kinds[-1] == "Dense"


def test_manifest_states_licence_labels_and_in_sample_caveats(committed):
    assert committed["redistribution"]["weights_in_repository"] is False
    assert committed["upstream"]["licence"]["declared"] is None
    assert committed["labels"]["indirect_calorimetry"] is False
    assert "waist" in committed["labels"]["reference"].lower()
    assert "not ground truth" in committed["intended_use"]
    assert "IN-SAMPLE" in committed["verification"]["public_sample"]["caveat"]
    assert committed["input"]["layout"].startswith("upstream layout")


def test_manifest_measurements_are_consistent_with_the_documented_tolerance(committed):
    parity = committed["verification"]["numpy_vs_keras"]
    assert parity["all_within_tolerance"] is True
    tol = parity["tolerance_abs"]
    assert tol <= 1e-4
    for bucket in ("max_abs_diff_realistic_inputs", "max_abs_diff_stress_inputs"):
        assert all(0.0 <= v <= tol for v in parity[bucket].values())
    sample = committed["verification"]["public_sample"]
    assert sample["n_windows"] == 1292
    assert 0.7 < sample["regression_vs_window_mean_energy_label"]["rmse_met"] < 0.8


def test_stale_sections_detects_a_changed_digest_and_a_changed_size(committed):
    assert mf.stale_sections(committed) == []
    broken = copy.deepcopy(committed)
    sha = broken["upstream"]["files"]["regression"]["sha256"]
    broken["upstream"]["files"]["regression"]["sha256"] = ("0" if sha[0] != "0" else "1") + sha[1:]
    assert mf.stale_sections(broken) == ["upstream"]
    broken = copy.deepcopy(committed)
    broken["converted"]["classification"]["size_bytes"] += 1
    assert mf.stale_sections(broken) == ["converted"]
    del broken["architecture"]
    assert set(mf.stale_sections(broken)) == {"converted", "architecture"}


def test_static_manifest_is_built_from_the_pins_it_is_given():
    other = replace(
        PINS,
        npz={**PINS.npz, "regression": replace(PINS.npz["regression"], sha256="ab" * 32, size=123)},
    )
    m = mf.static_manifest(other)
    assert m["converted"]["regression"]["sha256"] == "ab" * 32 and m["converted"]["regression"]["size_bytes"] == 123
    assert m["converted"]["classification"]["sha256"] == PINS.npz["classification"].sha256


def _reports():
    def head(realistic: float, stress: float) -> dict:
        return {
            "max_abs_diff_realistic": realistic,
            "max_abs_diff_stress": stress,
            "float64_reference": {"numpy32_vs_numpy64_max_abs": 1e-7, "keras32_vs_numpy64_max_abs": 2e-7},
        }

    parity = {
        "tolerance_abs": 1e-4,
        "all_within_tolerance": True,
        "set_sizes": {"real": 3},
        "environment": {"numpy": "2.2.6", "platform": "Darwin arm64", "tensorflow": "9.9.9", "tf_keras": "8.8.8"},
        "heads": {"regression": head(1.5e-5, 2.5e-6), "classification": head(3.5e-7, 4.5e-8)},
    }
    metrics = {"rmse": 0.5, "mae": 0.25, "bias": 0.125, "pearson_r": 0.75, "r2": 0.5}
    cls = {"accuracy": 0.8, "balanced_accuracy": 0.7, "majority_baseline": 0.5}
    evaluation = {
        "n_windows": 10,
        "upstream_layout_as_given": {
            "regression_vs_energy_e": metrics,
            "classification_vs_energy_e_bands": cls,
            "classification_vs_activity_classes": {"accuracy": 0.4},
        },
        "natural_layout_fed_to_model_for_contrast": {"regression_vs_energy_e": {"rmse": 2.0, "bias": -1.0, "pearson_r": 0.5}},
        "source_file_sha256": {"a.npy": "00" * 32},
    }
    ood = {
        "in_sample": {"frac_gt_0.5": 0.1, "component_frac_gt_0.5": {"flat": 0.1}, "spearman_score_vs_abs_error": -0.2},
        "leave_one_segment_out": {"pooled_frac_gt_0.5_all": 0.3, "pooled_frac_gt_0.5_without_flat": 0.05},
        "synthetic": {"still": {"mean": 0.0123456}, "NaN block": {"mean": 1.0}},
    }
    return parity, evaluation, ood


def test_build_manifest_maps_report_fields_without_inventing_any():
    parity, evaluation, ood = _reports()
    m = mf.build_manifest(parity=parity, evaluation=evaluation, ood=ood)
    v = m["verification"]
    assert v["numpy_vs_keras"]["reference"] == "tf_keras 8.8.8 (legacy Keras 2 API) on tensorflow 9.9.9, CPU, float32"
    assert v["numpy_vs_keras"]["max_abs_diff_realistic_inputs"] == {"regression_met": 1.5e-5, "classification_probability": 3.5e-7}
    assert v["numpy_vs_keras"]["max_abs_diff_stress_inputs"] == {"regression_met": 2.5e-6, "classification_probability": 4.5e-8}
    assert v["public_sample"]["regression_vs_window_mean_energy_label"] == {
        "rmse_met": 0.5, "mae_met": 0.25, "bias_met": 0.125, "pearson_r": 0.75, "r2": 0.5,
    }
    assert v["public_sample"]["classification_head_vs_sample_activity_codes"]["accuracy"] == 0.4
    assert v["ood_signal"]["leave_one_segment_out_fraction_gt_0.5_excluding_flat"] == 0.05
    assert v["ood_signal"]["synthetic"] == {"still": 0.0123, "NaN block": 1.0}
    assert m["performance"]["accelerate_numpy_wheel"]["ms_per_window_wall"] > 0
    assert mf.stale_sections(m) == []          # measurements never leak into the code-derived sections


def test_build_manifest_without_reports_carries_no_measurements():
    m = mf.build_manifest()
    assert m["verification"] == {"measured_on": mf.MEASURED_ON}
    assert mf.render(m).endswith("\n")


def test_manifest_cli_check_and_write(tmp_path, capsys, committed):
    assert mf.main(["--check", "--out", str(MANIFEST)]) == 0
    capsys.readouterr()

    stale = copy.deepcopy(committed)
    stale["upstream"]["pinned_commit"] = "0" * 40
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(stale), encoding="utf-8")
    assert mf.main(["--check", "--out", str(bad)]) == 1
    assert "stale in: upstream" in capsys.readouterr().err

    assert mf.main(["--check", "--out", str(tmp_path / "missing.json")]) == 1
    assert "cannot read" in capsys.readouterr().err

    out = tmp_path / "nested" / "m.json"
    assert mf.main(["--out", str(out)]) == 0
    assert mf.stale_sections(json.loads(out.read_text(encoding="utf-8"))) == []


# ------------------------------------------------------------------ NOTICE


def test_notice_states_licence_status_provenance_and_label_caveats():
    text = NOTICE.read_text(encoding="utf-8")
    flat = " ".join(text.split()).lower()
    for needle in (
        UPSTREAM_URL.lower(),
        PINNED_COMMIT,
        PAPER_DOI,
        "no licence",
        "all rights stay with the authors",
        "never committed",
        "waist",
        "not indirect calorimetry",
        "supporting evidence, not ground truth",
        "sha256",
    ):
        assert needle in flat, needle


# ------------------------------------------------------------------ nothing weight-like is tracked


WEIGHT_SUFFIXES = {".h5", ".hdf5", ".npz", ".npy", ".pt", ".pth", ".onnx", ".tflite", ".mlmodel", ".mlpackage", ".keras", ".safetensors", ".pb"}


def test_package_and_scripts_contain_no_weight_files():
    found = []
    for base in (_ROOT / "energy_models" / "wrist_cnn", _ROOT / "scripts"):
        for p in base.rglob("*"):
            if p.is_file() and p.suffix.lower() in WEIGHT_SUFFIXES and "__pycache__" not in p.parts:
                found.append(str(p.relative_to(_ROOT)))
    assert found == []


def test_the_only_committed_cnn_fixture_is_a_small_synthetic_golden_file():
    fixtures = sorted((_ROOT / "tests" / "fixtures").glob("wrist_cnn_*"))
    assert [p.name for p in fixtures] == ["wrist_cnn_golden.npz"]
    golden = fixtures[0]
    assert golden.stat().st_size < 300_000
    with np.load(golden, allow_pickle=False) as z:
        assert set(z.files) == {"counts", "met_expected", "meta_json", "names", "proba_expected", "quantum_g"}
        assert z["counts"].shape[0] <= 3 and z["counts"].dtype == np.int16
        assert z["met_expected"].size <= 3 and z["proba_expected"].shape == (z["met_expected"].size, 3)


def test_gitignore_keeps_weights_out_and_only_provenance_files_in():
    lines = [ln.strip() for ln in (_ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()]
    rules = [ln for ln in lines if ln and not ln.startswith("#")]
    assert "artifacts/**" in rules
    assert "!artifacts/**/manifest.json" in rules and "!artifacts/**/NOTICE.md" in rules
    reincluded = [r for r in rules if r.startswith("!") and re.search(r"\.h5|\.hdf5|\.npz|\.npy|upstream|wrist_cnn", r)]
    assert reincluded == []
    assert "*.part" in rules


# ------------------------------------------------------------------ requirements


PIN_LINE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*==[0-9][A-Za-z0-9_.+!-]*$")


def _requirement_lines(path: Path) -> list[str]:
    return [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.strip().startswith("#")]


def test_requirements_are_exact_pins_and_the_convert_set_is_minimal():
    convert = _requirement_lines(_ROOT / "requirements-cnn-convert.txt")
    assert sorted(ln.split("==")[0].lower() for ln in convert) == ["h5py", "numpy"]
    assert all(PIN_LINE.match(ln) for ln in convert), convert

    verify = _requirement_lines(_ROOT / "requirements-cnn-verify.txt")
    includes = [ln for ln in verify if ln.startswith("-r ")]
    assert includes == ["-r requirements-cnn-convert.txt"]
    pins = [ln for ln in verify if not ln.startswith("-r ")]
    assert all(PIN_LINE.match(ln) for ln in pins), [ln for ln in pins if not PIN_LINE.match(ln)]
    names = {ln.split("==")[0].lower() for ln in pins}
    assert {"tensorflow", "tf_keras", "pytest"} <= names
    assert len(names) == len(pins), "duplicate pins"


def test_convert_numpy_pin_matches_the_project_numpy_pin():
    pyproject = _ROOT / "pyproject.toml"
    m = re.search(r'"numpy==([0-9][0-9A-Za-z.]*)"', pyproject.read_text(encoding="utf-8")) if pyproject.exists() else None
    if m is None:
        pytest.skip("pyproject.toml has no exact numpy pin")
    convert = dict(ln.split("==") for ln in _requirement_lines(_ROOT / "requirements-cnn-convert.txt"))
    assert convert["numpy"] == m.group(1)


# ------------------------------------------------------------------ package surface


def test_package_import_pulls_in_numpy_only_and_exports_the_public_api():
    code = (
        "import sys\n"
        "import energy_models.wrist_cnn as pkg\n"
        "heavy = {'h5py', 'tensorflow', 'tf_keras', 'keras', 'torch', 'scipy', 'pandas', 'sklearn', 'matplotlib'}\n"
        "bad = sorted(heavy & {m.split('.')[0] for m in sys.modules})\n"
        "assert not bad, bad\n"
        "tools = {'fetch', 'verify_keras', 'evaluate', 'ood_eval', 'manifest', 'testing', 'synthetic'}\n"
        "loaded = sorted(t for t in tools if 'energy_models.wrist_cnn.' + t in sys.modules)\n"
        "assert not loaded, loaded\n"
        "missing = [n for n in pkg.__all__ if not hasattr(pkg, n)]\n"
        "assert not missing, missing\n"
        "assert len(pkg.PINNED_COMMIT) == 40 and set(pkg.PINS.upstream) == {'regression', 'classification'}\n"
        "print(','.join(sorted(pkg.__all__)))\n"
    )
    res = subprocess.run([sys.executable, "-c", code], cwd=_ROOT, capture_output=True, text=True, timeout=120)
    assert res.returncode == 0, res.stderr
    exported = set(res.stdout.strip().split(","))
    assert {"load_model", "predict_met", "predict_proba", "prepare_windows", "ood_signal", "quiet_mask", "WristCNN"} <= exported


@pytest.mark.parametrize("module", ["fetch", "manifest"])
def test_tools_run_as_modules_without_import_warnings(module):
    # `python -m pkg.mod` warns (runpy) when the package __init__ already imported `pkg.mod`.
    res = subprocess.run(
        [sys.executable, "-W", "error", "-m", f"energy_models.wrist_cnn.{module}", "--help"],
        cwd=_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert res.returncode == 0, res.stderr
    assert "Warning" not in res.stderr


# ------------------------------------------------------------------ fetch script


needs_bash = pytest.mark.skipif(not (SCRIPT.exists() and os.name == "posix"), reason="needs bash on a POSIX host")


def _run_script(args, art_dir, **extra_env):
    env = {**os.environ, "NARA_WRIST_CNN_DIR": str(art_dir), "PYTHON": sys.executable, **extra_env}
    return subprocess.run(["bash", str(SCRIPT), *args], cwd=_ROOT, env=env, capture_output=True, text=True, timeout=120)


@needs_bash
def test_fetch_script_is_executable_and_parses():
    assert os.access(SCRIPT, os.X_OK)
    assert SCRIPT.read_text(encoding="utf-8").startswith("#!/usr/bin/env bash")
    res = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert res.returncode == 0, res.stderr


@needs_bash
def test_fetch_script_check_reports_missing_artifacts_with_exit_status_1(tmp_path):
    res = _run_script(["--check"], tmp_path)
    assert res.returncode == 1, res.stderr
    assert "regression: missing" in res.stdout and "classification: missing" in res.stdout


@needs_bash
def test_fetch_script_check_reports_a_tampered_artifact_with_exit_status_1(tmp_path):
    for head in HEADS:
        (tmp_path / PINS.npz[head].filename).write_bytes(b"not the pinned weights")
    res = _run_script(["--check"], tmp_path)
    assert res.returncode == 1
    assert "regression: mismatch" in res.stdout and "classification: mismatch" in res.stdout


@needs_bash
def test_fetch_script_refuses_a_cached_upstream_file_that_fails_its_digest(tmp_path):
    pytest.importorskip("h5py")
    cache = tmp_path / "upstream"
    cache.mkdir()
    (cache / PINS.upstream["regression"].basename).write_bytes(b"\x89HDF\r\n\x1a\n tampered")
    res = _run_script(["--offline"], tmp_path)
    assert res.returncode == 2, res.stderr
    assert "REFUSING" in res.stderr
    assert not list(tmp_path.glob("*.npz")), "nothing may be converted from an unverified file"


@needs_bash
def test_fetch_script_offline_without_a_cache_is_a_plain_error_not_a_download(tmp_path):
    pytest.importorskip("h5py")
    res = _run_script(["--offline"], tmp_path)
    assert res.returncode == 3, res.stderr
    assert "--offline" in res.stderr
    assert not list(tmp_path.glob("*.npz"))


@needs_bash
def test_fetch_script_fails_loudly_when_the_chosen_python_cannot_import_the_converter_modules(tmp_path):
    fake_python = tmp_path / "python-without-modules"
    fake_python.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    fake_python.chmod(0o755)
    res = _run_script([], tmp_path / "art", PYTHON=str(fake_python))
    assert res.returncode == 3
    assert "cannot import" in res.stderr
