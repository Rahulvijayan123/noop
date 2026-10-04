"""Builds the committed provenance file ``artifacts/wrist_cnn/manifest.json``.

The manifest records WHAT was fetched (pinned upstream commit, file sizes and sha256 digests),
HOW it was converted, the verified architecture and input conventions, and the measured evidence.
It never contains weights. Everything that can be derived from ``pins.py`` / ``spec.py`` is
regenerated here, and ``tests/test_wrist_cnn_manifest.py`` fails if the committed file drifts from
those modules. The ``verification`` / ``performance`` sections are measurements copied from the
reports written by ``verify_keras.py`` / ``evaluate.py`` / ``ood_eval.py`` (no numpy needed).

    python -m energy_models.wrist_cnn.manifest --parity parity.json --eval eval.json --ood ood.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from . import pins as _pins
from . import spec as _spec

SCHEMA = 1
MEASURED_ON = "2026-10-03"
ARTIFACTS_SUBDIR = Path("artifacts") / "wrist_cnn"

# Static facts, not derivable from the pins: how they were established.
LICENCE_EVIDENCE = (
    "GitHub repository API reports license: null for razmik/cnn-wrist-model-freeliving.",
    "No LICENSE, COPYING or NOTICE file exists in the tree at the pinned commit.",
    "The upstream README states no licence and no terms of reuse.",
)
FLOOR_MET = 1.336          # label value of every fully frozen (all samples identical) public sample window
QUIET_OUTPUT_MET = 1.402   # regression output on quiet public windows (mean; sd 0.010; n = 116)

# Measured by hand on 2026-10-03 (Apple M4 Max, Python 3.11.13, numpy 2.2.6) with benchmark runs of 96
# windows, batch sizes 1 to 64 (results do not depend on the batch size). The host was shared with
# other workloads (load average 12 to 17), so these are best-of-5 figures with the median 2-4% higher.
PERFORMANCE_NOTES = {
    "accelerate_numpy_wheel": {
        "ms_per_window_wall": 3.6,
        "ms_per_window_cpu": 5.2,
        "seconds_per_1440_windows_per_head": 5.2,
        "note": "numpy macOS arm64 wheel built against Apple Accelerate, default threading",
    },
    "accelerate_single_thread": {
        "ms_per_window_wall": 4.8,
        "seconds_per_1440_windows_per_head": 6.9,
        "note": "same wheel with VECLIB_MAXIMUM_THREADS=1",
    },
    "openblas_numpy_wheel": {
        "ms_per_window_wall": 41.5,
        "seconds_per_1440_windows_per_head": 59.8,
        "note": "numpy macosx_11_0_arm64 wheel (scipy-openblas 0.3.29, generic NEON kernels), same machine, "
        "best of 3 batches of 16; expect this order of magnitude on any host without a tuned BLAS. "
        "x86 hosts were not measured.",
    },
    "keras_reference": {
        "ms_per_window_wall": 6.2,
        "note": "tf_keras 2.21.0 / TensorFlow 2.21.0 on the same machine, batch 12, multi-threaded",
    },
    "ood_signal_ms_per_window": 0.17,
    "quiet_mask_ms_per_window": 0.04,
    "prepare_windows_24h_100hz_seconds": 0.12,
    "scratch_memory_mb_per_thread": 58.9,
    "weights_resident_mb_per_head_float32": 5.82,
}


def default_manifest_path() -> Path:
    return Path(__file__).resolve().parents[2] / ARTIFACTS_SUBDIR / "manifest.json"


def _architecture() -> dict[str, Any]:
    arch = _spec.REAL_ARCH
    layers = [{"layer": "Reshape", "input": [arch.window_samples * arch.n_axes], "output": [arch.window_samples, arch.n_axes]}]
    for i, filters in enumerate(arch.filters, start=1):
        layers.append(
            {
                "layer": "Conv1D",
                "filters": filters,
                "kernel_size": arch.kernel_size,
                "strides": 1,
                "padding": "valid",
                "activation": "relu",
            }
        )
        if i in arch.pool_after:
            layers.append({"layer": "MaxPooling1D", "pool_size": arch.pool_size, "strides": arch.pool_size, "padding": "valid"})
    layers.append({"layer": "GlobalMaxPooling1D"})
    layers.append({"layer": "Dropout", "rate": _spec.DROPOUT_RATE, "inference": "identity"})
    layers.append(
        {
            "layer": "Dense",
            "units": {head: _spec.HEAD_UNITS[head] for head in _spec.HEADS},
            "activation": dict(_spec.HEAD_ACTIVATION),
        }
    )
    return {
        "origin": "Keras 2.2.4 Sequential (read from the model_config of each .h5)",
        "layers": layers,
        "time_lengths_after_stage": {name: length for name, length in arch.stage_lengths()},
        "note": "the second pooling floors 1976 -> 658 (two trailing steps dropped), exactly as Keras 'valid' pooling does",
        "parameters": {head: _spec.parameter_count(head) for head in _spec.HEADS},
        "multiply_accumulates_per_window": {head: _spec.macs_per_window(head) for head in _spec.HEADS},
        "heads": "two separate networks (no shared weights): regression (MET) and 3-class intensity",
    }


def static_manifest(pin_set: _pins.PinSet | None = None) -> dict[str, Any]:
    """Everything that can be derived from the code: no measurements, no I/O."""
    ps = pin_set or _pins.PINS
    n_tensors = len(_spec.WEIGHT_KEYS)
    return {
        "schema": SCHEMA,
        "name": "wrist_cnn",
        "description": (
            "Pretrained 1-D CNN heads (energy-expenditure regression and 3-class activity intensity) "
            "for 60 s of raw wrist-worn tri-axial accelerometry, ported to a numpy-only forward pass."
        ),
        "intended_use": "supporting evidence for activity intensity / energy expenditure; not ground truth",
        "redistribution": {
            "weights_in_repository": False,
            "reason": "upstream declares no licence, so all rights are reserved by the authors",
            "policy": (
                "weights are fetched from the upstream repository at the pinned commit, accepted only if their "
                "sha256 equals the digests below, converted locally to float32 .npz, and kept in the git-ignored "
                "artifacts directory; they are never committed or redistributed"
            ),
        },
        "upstream": {
            "repository": _pins.UPSTREAM_URL,
            "pinned_commit": _pins.PINNED_COMMIT,
            "pinned_commit_date_utc": _pins.PINNED_COMMIT_DATE,
            "licence": {"declared": None, "evidence": list(LICENCE_EVIDENCE)},
            "paper": {"citation": _pins.PAPER_CITATION, "doi": _pins.PAPER_DOI},
            "files": {
                head: {
                    "path": f.path,
                    "url": f.raw_url(),
                    "size_bytes": f.size,
                    "sha256": f.sha256,
                    "git_blob_sha1": f.git_blob_sha1,
                }
                for head, f in ps.upstream.items()
            },
        },
        "converted": {
            head: {
                "filename": p.filename,
                "size_bytes": p.size,
                "sha256": p.sha256,
                "dtype": "float32",
                "tensors": n_tensors,
                "parameters": _spec.parameter_count(head),
                "container": (
                    "numpy .npz written byte-deterministically (stored zip, fixed timestamps, sorted keys, "
                    "version-1.0 .npy headers); conv kernels are [kernel, in, out], dense kernel [in, out]"
                ),
            }
            for head, p in ps.npz.items()
        },
        "fetch": {
            "command": "scripts/fetch_wrist_cnn.sh",
            "module": "python -m energy_models.wrist_cnn.fetch",
            "download_hosts": [_pins.RAW_HOST],
            "refusal": (
                "a download whose size or sha256 differs from its pin is discarded and the run aborts with exit "
                "status 2; a cached copy that fails verification is deleted and re-fetched (refused with --offline); "
                "the converted .npz is verified against its own pin and re-verified before every load"
            ),
            "converter_requirements": "requirements-cnn-convert.txt (h5py is needed only to convert)",
            "inference_requirements": "numpy only",
        },
        "architecture": _architecture(),
        "input": {
            "units": "g (standard gravity)",
            "gravity": "included (no high-pass, no band-pass, no standardisation)",
            "sample_rate_hz": _spec.SAMPLE_RATE_HZ,
            "window_samples": _spec.WINDOW_SAMPLES,
            "window_seconds": _spec.WINDOW_SECONDS,
            "training_window_overlap": 0.5,
            "axes": _spec.N_AXES,
            "training_sensor": (
                "ActiGraph GT3X+ on the wrist, raw export: 3 decimals, steps of 3-4 mg, rails at +-8 g "
                "(largest value in the public sample 7.996 g)"
            ),
            "layout": (
                "upstream layout: preprocess/prepare_train_data.py reshapes [x(6000), y(6000), z(6000)] to "
                "(6000, 3) without a transpose, so the network sees the axes concatenated in time and re-chopped "
                "into rows of three; it is NOT [time, axis]. Feeding [time, axis] to the same weights gives "
                "RMSE 2.21 MET instead of 0.74 on the public sample."
            ),
        },
        "output": {
            "regression": "one float, MET-like energy-expenditure index (linear head, not clipped)",
            "classification": "softmax over 3 classes, upstream names " + "/".join(_spec.CLASS_INDEX_NAMES),
            "class_semantics": (
                "measured on the public sample: the head follows the energy bands <1.5, 1.5-<3, >=3 MET (91% "
                "agreement); the sample's own activity_classes codes do not follow that scheme (48% agreement)"
            ),
        },
        "labels": {
            "reference": (
                "waist-worn ActiGraph energy-expenditure estimate ('waist_ee'): upstream's "
                "ReferenceMethod.update_reference_ee applies the Freedson VM3 Combination (11) equation to waist "
                "activity counts (MET = 0.001092 x VA + 1.336129, capped at 2.9999, while VM3 < 2453 counts/min; "
                "0.000863 x VM3 + 0.668876 above), plus its intensity class ('waist_intensity')"
            ),
            "indirect_calorimetry": False,
            "consequence": (
                "outputs are an activity-intensity index calibrated to a waist-accelerometer estimate, not a "
                "calorimetric energy cost"
            ),
            "label_floor_met": FLOOR_MET,
            "quiet_window_output_met": QUIET_OUTPUT_MET,
        },
        "whoop_mismatch_risks": [
            "axis orientation / sign of the device frame is not the ActiGraph wrist frame (measured: sign flips shift "
            "the mean output by up to 0.17 MET and single windows by up to 2.9 MET on the public sample)",
            "WHOOP raw resolution (1/4096 g) is finer than the training data (3-4 mg steps); behaviour of the network "
            "on finer or differently filtered signals was not measured",
            "wear site differs (training: wrist; a WHOOP strap may be worn on the upper arm)",
            "training used 60 s windows with exactly 100 Hz sampling; gaps must be reported, not interpolated silently",
            "labels are waist-ActiGraph estimates from one free-living cohort, not calorimetry",
        ],
    }


def _verification(
    parity: dict[str, Any] | None,
    evaluation: dict[str, Any] | None,
    ood: dict[str, Any] | None,
) -> dict[str, Any]:
    out: dict[str, Any] = {"measured_on": MEASURED_ON}
    if parity is not None:
        heads = parity["heads"]
        out["numpy_vs_keras"] = {
            "reference": (
                f"tf_keras {parity['environment']['tf_keras']} (legacy Keras 2 API) "
                f"on tensorflow {parity['environment']['tensorflow']}, CPU, float32"
            ),
            "numpy_version": parity["environment"]["numpy"],
            "platform": parity["environment"]["platform"],
            "tolerance_abs": parity["tolerance_abs"],
            "all_within_tolerance": parity["all_within_tolerance"],
            "input_set_sizes": parity["set_sizes"],
            "max_abs_diff_realistic_inputs": {
                "regression_met": heads["regression"]["max_abs_diff_realistic"],
                "classification_probability": heads["classification"]["max_abs_diff_realistic"],
            },
            "max_abs_diff_stress_inputs": {
                "regression_met": heads["regression"]["max_abs_diff_stress"],
                "classification_probability": heads["classification"]["max_abs_diff_stress"],
            },
            "float64_reference_max_abs_diff": {
                head: {
                    "numpy_float32_vs_float64": heads[head]["float64_reference"]["numpy32_vs_numpy64_max_abs"],
                    "keras_float32_vs_float64": heads[head]["float64_reference"]["keras32_vs_numpy64_max_abs"],
                }
                for head in _spec.HEADS
            },
        }
    if evaluation is not None:
        given = evaluation["upstream_layout_as_given"]
        reg = given["regression_vs_energy_e"]
        natural = evaluation["natural_layout_fed_to_model_for_contrast"]["regression_vs_energy_e"]
        out["public_sample"] = {
            "caveat": (
                "ONE participant (LSM146, one day, 7 segments) from the upstream repository's training-ready sample; "
                "the repository gives no train/test split, so treat this as IN-SAMPLE, not held-out performance. "
                "The paper reports r = 0.86 and 83.7% intensity accuracy on held-out participants."
            ),
            "n_windows": evaluation["n_windows"],
            "regression_vs_window_mean_energy_label": {
                "rmse_met": reg["rmse"],
                "mae_met": reg["mae"],
                "bias_met": reg["bias"],
                "pearson_r": reg["pearson_r"],
                "r2": reg["r2"],
            },
            "regression_in_natural_layout_for_contrast": {
                "rmse_met": natural["rmse"],
                "bias_met": natural["bias"],
                "pearson_r": natural["pearson_r"],
            },
            "classification_head_vs_energy_bands": {
                "accuracy": given["classification_vs_energy_e_bands"]["accuracy"],
                "balanced_accuracy": given["classification_vs_energy_e_bands"]["balanced_accuracy"],
                "majority_baseline": given["classification_vs_energy_e_bands"]["majority_baseline"],
            },
            "classification_head_vs_sample_activity_codes": {
                "accuracy": given["classification_vs_activity_classes"]["accuracy"],
                "note": "the sample's codes do not follow the head's class scheme (see output.class_semantics)",
            },
            "source_file_sha256": evaluation["source_file_sha256"],
        }
    if ood is not None:
        loso = ood["leave_one_segment_out"]
        inn = ood["in_sample"]
        out["ood_signal"] = {
            "in_sample_fraction_score_gt_0.5": inn["frac_gt_0.5"],
            "in_sample_flat_component_fraction_gt_0.5": inn["component_frac_gt_0.5"]["flat"],
            "leave_one_segment_out_fraction_gt_0.5": loso["pooled_frac_gt_0.5_all"],
            "leave_one_segment_out_fraction_gt_0.5_excluding_flat": loso["pooled_frac_gt_0.5_without_flat"],
            "spearman_score_vs_abs_error": inn["spearman_score_vs_abs_error"],
            "synthetic": {name: round(v["mean"], 4) for name, v in ood["synthetic"].items()},
            "caveat": (
                "the score is a plausibility signal, not a calibrated error predictor; its envelope comes from one "
                "participant and one day"
            ),
        }
    return out


def build_manifest(
    *,
    parity: dict[str, Any] | None = None,
    evaluation: dict[str, Any] | None = None,
    ood: dict[str, Any] | None = None,
    pin_set: _pins.PinSet | None = None,
) -> dict[str, Any]:
    manifest = static_manifest(pin_set)
    manifest["verification"] = _verification(parity, evaluation, ood)
    manifest["performance"] = {
        "measured_on": MEASURED_ON,
        "host": "Apple M4 Max, Python 3.11.13, numpy 2.2.6",
        **PERFORMANCE_NOTES,
    }
    return manifest


def render(manifest: dict[str, Any]) -> str:
    return json.dumps(manifest, indent=2, ensure_ascii=True) + "\n"


def stale_sections(committed: dict[str, Any], pin_set: _pins.PinSet | None = None) -> list[str]:
    """Top-level keys of the code-derived part of the manifest that differ from ``committed``."""
    return [key for key, value in static_manifest(pin_set).items() if committed.get(key) != value]


def _load(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Write artifacts/wrist_cnn/manifest.json (provenance only; no weights).")
    ap.add_argument("--parity", help="report written by verify_keras --report")
    ap.add_argument("--eval", dest="evaluation", help="report written by evaluate --json")
    ap.add_argument("--ood", help="report written by ood_eval --json")
    ap.add_argument("--out", default=str(default_manifest_path()))
    ap.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the code-derived sections of --out (pins, architecture, conventions) are stale",
    )
    args = ap.parse_args(argv)

    out = Path(args.out)
    if args.check:
        try:
            committed = json.loads(out.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"cannot read {out}: {exc}", file=sys.stderr)
            return 1
        stale = stale_sections(committed)
        if stale:
            print(f"{out} is stale in: {', '.join(stale)}; regenerate with manifest.py", file=sys.stderr)
            return 1
        print(f"{out} is up to date")
        return 0

    text = render(build_manifest(parity=_load(args.parity), evaluation=_load(args.evaluation), ood=_load(args.ood)))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
