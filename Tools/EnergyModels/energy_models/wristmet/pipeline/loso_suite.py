"""The complete leave-one-participant-out (LOSO) evaluation suite behind the WristMET manifest."""

from __future__ import annotations

import time
from typing import Callable

import numpy as np

from . import analysis as A
from . import modeling as M
from .dataset import WindowDataset

#: Published results (Wei et al. 2025, Table 2/3 and text) the retrained model is compared with.
PAPER = {
    "60s": {
        "rmse_overall": 0.281,
        "rmse_sedentary": 0.268,
        "rmse_light": 0.307,
        "rmse_mod_vig": 0.310,
        "classifier_sedentary_positive": {"precision": 0.952, "recall": 0.628, "f1": 0.758},
    },
    "15s": {"rmse_overall": 0.326},
    "10s": {"rmse_overall": 0.316},
}

EXTRA_SEEDS = (1, 2, 3, 4)


def _compact(s: dict) -> dict:
    """Metrics worth keeping in the manifest (drops the verbose counters)."""
    sp = s["sedentary_positive"]
    nsp = s["nonsedentary_positive"]
    return {
        "n_windows": s["n_windows"],
        "rmse_overall": round(s["rmse_overall"], 4),
        "rmse_sedentary": round(s["rmse_sedentary"], 4),
        "rmse_light": round(s["rmse_light"], 4),
        "rmse_mod_vig": round(s["rmse_mod_vig"], 4),
        "rmse_per_participant_mean": round(s["rmse_per_participant_mean"], 4),
        "rmse_per_participant_sd": round(s["rmse_per_participant_sd"], 4),
        "classifier_sedentary_positive": {k: round(sp[k], 4) for k in ("precision", "recall", "f1")},
        "classifier_nonsedentary_positive": {k: round(nsp[k], 4) for k in ("precision", "recall", "f1")},
        "classifier_accuracy": round(s["accuracy"], 4),
        "class_counts": {"sedentary": s["n_sedentary"], "light": s["n_light"], "mod_vig": s["n_mod_vig"]},
    }


def run_suite(ds60: WindowDataset, ds15: WindowDataset | None, log: Callable[[str], None] = print) -> dict:
    out: dict = {}
    t0 = time.time()

    def step(name: str) -> None:
        log(f"[loso] {name} ({time.time() - t0:.0f}s)")

    # ---------------------------------------------------------------- 60 s
    step("60 s primary")
    a60 = M.assemble(ds60)
    res, s = A.run_loso(a60)
    out["w60_primary"] = _compact(s)
    out["w60_primary"]["baselines"] = {k: round(v, 4) for k, v in A.baselines(a60, res).items()}
    per_p = res.assign(se=(res["est"] - res["met"]) ** 2).dropna(subset=["met"]).groupby("participant")["se"].mean() ** 0.5
    out["w60_primary"]["per_participant_rmse"] = {f"P{int(p)}": round(float(v), 4) for p, v in per_p.items()}

    step("60 s seeds")
    overall = [s["rmse_overall"]]
    for seed in EXTRA_SEEDS:
        _, s2 = A.run_loso(a60, seed=seed)
        overall.append(s2["rmse_overall"])
    out["w60_seed_variation"] = {
        "seeds": [M.DEFAULT_SEED, *EXTRA_SEEDS],
        "rmse_overall": [round(v, 4) for v in overall],
        "mean": round(float(np.mean(overall)), 4),
        "sd": round(float(np.std(overall, ddof=1)), 4),
    }

    step("60 s leakage diagnostics")
    leak = A.leakage_diagnostics(a60, res)
    out["w60_leakage_diagnostics"] = {k: _compact(v) for k, v in leak.items()}

    step("60 s ablation")
    _, s_abl = A.run_loso(a60, reg_cols=[3, 8])
    out["w60_ablation_demographics_free"] = {
        "two_intensity_features": _compact(s_abl),
        "nine_features": out["w60_primary"],
        "regressor_only_rmse_on_nonsedentary_windows": {
            "two_intensity_features": round(A.regression_only_loso(a60, [3, 8]), 4),
            "nine_features": round(A.regression_only_loso(a60, list(range(9))), 4),
        },
    }

    step("60 s sensitivities")
    sens = {}
    _, s2 = A.run_loso(M.assemble(ds60, mirror=False))
    sens["mirroring_off"] = _compact(s2)
    _, s2 = A.run_loso(M.assemble(ds60, demographics_source="agd"))
    sens["demographics_agd_heights"] = _compact(s2)
    _, s2 = A.run_loso(M.assemble(ds60, demographics_source="notebook"))
    sens["demographics_upstream_notebook_ages"] = _compact(s2)
    _, s2 = A.run_loso(M.assemble(ds60, age_offset=2.0))
    sens["age_plus_2_years"] = _compact(s2)
    gm = A.gap_mask(ds60)
    sens["n_windows_with_gap_over_500ms"] = int(gm.sum())
    _, s2 = A.run_loso(M.assemble(ds60, keep=~gm))
    sens["exclude_gap_windows_train_and_test"] = _compact(s2)
    sens["faithful_training_evaluated_on_clean_windows"] = _compact(M.summarize(res, mask=~gm))
    sens["faithful_training_evaluated_on_gap_windows"] = _compact(M.summarize(res, mask=gm))
    keep_b = (ds60.meta["win_in_seg"] >= 2).to_numpy()
    _, s2 = A.run_loso(M.assemble(ds60, keep=keep_b))
    sens["skip_first_two_windows_per_segment"] = _compact(s2)
    out["w60_sensitivity"] = sens

    # ---------------------------------------------------------------- 15 s
    if ds15 is not None:
        step("15 s")
        a15 = M.assemble(ds15)
        res15, s15 = A.run_loso(a15)
        out["w15_primary"] = _compact(s15)
        out["w15_primary"]["baselines"] = {k: round(v, 4) for k, v in A.baselines(a15, res15).items()}
        leak15 = A.leakage_diagnostics(a15, res15)
        out["w15_leakage_diagnostics"] = {k: _compact(v) for k, v in leak15.items()}
        _, s15b = A.run_loso(a15, reg_cols=[3, 8])
        out["w15_ablation_demographics_free"] = _compact(s15b)
    out["paper"] = PAPER
    out["paper_comparison"] = _comparison(out)
    step("done")
    return out


def _comparison(out: dict) -> dict:
    """Side-by-side table: paper vs genuine LOSO vs the diagnostics that leak the held-out participant."""
    p60 = PAPER["60s"]
    ours = out["w60_primary"]
    leaky_clf = out["w60_leakage_diagnostics"]["published_loop_leaky_classifier_proper_regressor"]
    in_sample = out["w60_leakage_diagnostics"]["in_sample_classifier_and_regressor"]
    rows = {}
    for key in ("rmse_overall", "rmse_sedentary", "rmse_light", "rmse_mod_vig"):
        rows[f"60s_{key}"] = {
            "paper": p60[key],
            "ours_loso": ours[key],
            "ours_published_loop_leaky_classifier": leaky_clf[key],
            "ours_in_sample_not_a_valid_estimate": in_sample[key],
        }
    for metric in ("precision", "recall", "f1"):
        rows[f"60s_classifier_sedentary_positive_{metric}"] = {
            "paper": p60["classifier_sedentary_positive"][metric],
            "ours_loso": ours["classifier_sedentary_positive"][metric],
            "ours_published_loop_leaky_classifier": leaky_clf["classifier_sedentary_positive"][metric],
        }
    if "w15_primary" in out:
        rows["15s_rmse_overall"] = {
            "paper": PAPER["15s"]["rmse_overall"],
            "ours_loso": out["w15_primary"]["rmse_overall"],
            "ours_published_loop_leaky_classifier": out["w15_leakage_diagnostics"][
                "published_loop_leaky_classifier_proper_regressor"
            ]["rmse_overall"],
            "ours_in_sample_not_a_valid_estimate": out["w15_leakage_diagnostics"]["in_sample_classifier_and_regressor"][
                "rmse_overall"
            ],
        }
    rows["10s_rmse_overall"] = {"paper": PAPER["10s"]["rmse_overall"], "ours_loso": None, "note": "10 s windows not evaluated"}
    return rows
