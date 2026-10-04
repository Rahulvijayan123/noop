"""LOSO experiments, baselines and sensitivity analyses used for the WristMET build report."""

from __future__ import annotations

import time
from typing import Callable

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor

from . import modeling as M
from .dataset import WindowDataset

GAP_TOLERANCE_MS = 500.0


def gap_mask(ds: WindowDataset, tol_ms: float = GAP_TOLERANCE_MS) -> np.ndarray:
    """True for windows whose raw samples contain a gap longer than ``tol_ms`` (data were interpolated across it)."""
    m = ds.meta
    return ((m["max_gap_acc_ms"] > tol_ms) | (m["max_gap_gyr_ms"] > tol_ms)).to_numpy()


def _flat(s: dict) -> dict:
    return {k: v for k, v in s.items()}


def run_loso(a: M.Assembled, **kw) -> tuple[pd.DataFrame, dict]:
    t = time.time()
    res = M.loso(a, **kw)
    s = M.summarize(res)
    s["seconds"] = round(time.time() - t, 1)
    return res, s


def baselines(a: M.Assembled, res: pd.DataFrame) -> dict:
    """Reference predictors evaluated on the same windows as the LOSO result ``res``."""
    met = a.met
    ok = np.isfinite(met)
    out: dict = {}

    def rmse(est: np.ndarray, mask: np.ndarray | None = None) -> float:
        m = ok if mask is None else ok & mask
        return float(np.sqrt(np.mean((est[m] - met[m]) ** 2)))

    out["predict_1.0_everywhere"] = rmse(np.ones_like(met))
    nonsed_true = a.meta["activity"].isin(
        a.meta.loc[a.reg_train_mask, "activity"].unique()
    ).to_numpy()
    # LOSO mean / activity-mean of the true non-sedentary windows of the other participants
    mean_est = np.full(len(met), np.nan)
    act_est = np.full(len(met), np.nan)
    acts = a.meta["activity"].to_numpy()
    for p in a.participants:
        te = a.groups == p
        tr = (a.groups != p) & a.reg_train_mask
        mean_est[te] = met[tr].mean()
        means = pd.Series(met[tr]).groupby(acts[tr]).mean()
        act_est[te] = pd.Series(acts[te]).map(means).fillna(met[tr].mean()).to_numpy()
    pred_cls = res["pred_class"].to_numpy()
    out["classifier_then_constant_nonsedentary_mean"] = rmse(np.where(pred_cls == 0, 1.0, mean_est))
    out["oracle_labels_then_constant_nonsedentary_mean"] = rmse(np.where(a.y_cls == 0, 1.0, mean_est))
    out["oracle_labels_then_activity_mean_loso"] = rmse(np.where(a.y_cls == 0, 1.0, act_est))
    out["classifier_then_published_rf_loso"] = rmse(res["est"].to_numpy())
    # non-sedentary windows only (true label), regression quality in isolation
    ns = a.reg_train_mask
    out["nonsedentary_windows_n"] = int((ns & ok).sum())
    out["nonsedentary_sd_of_target"] = float(np.std(met[ns & ok]))
    out["nonsedentary_rmse_constant_mean"] = rmse(mean_est, ns)
    out["nonsedentary_rmse_activity_mean_oracle"] = rmse(act_est, ns)
    # published RF on the true non-sedentary windows (oracle routing): need its predictions
    return out


def regression_only_loso(
    a: M.Assembled,
    cols: list[int],
    *,
    seed: int = M.DEFAULT_SEED,
    rf_overrides: dict | None = None,
    make: Callable[[], RandomForestRegressor] | None = None,
) -> float:
    """LOSO RMSE of the regressor alone on the true non-sedentary windows (no classifier involved)."""
    ns = a.reg_train_mask
    pred = np.full(len(a.met), np.nan)
    for p in a.participants:
        te = ns & (a.groups == p)
        tr = ns & (a.groups != p)
        if not te.any():
            continue
        rf = make() if make else M.make_regressor(seed, **(rf_overrides or {}))
        rf.fit(a.X_reg[tr][:, cols], a.met[tr])
        pred[te] = rf.predict(a.X_reg[te][:, cols])
    e = pred[ns] - a.met[ns]
    e = e[np.isfinite(e)]
    return float(np.sqrt(np.mean(e**2)))


def leakage_diagnostics(a: M.Assembled, res_proper: pd.DataFrame) -> dict:
    """What the headline numbers would look like if the LOSO loop leaked the held-out participant.

    These rows exist to interpret the gap to the published numbers; none of them is a valid
    out-of-sample estimate.
    """
    out = {}
    all_idx = np.ones(len(a.groups), dtype=bool)
    clf, rf = M.fit_models(a, all_idx)
    cls, prob, est = M.predict_pipeline(clf, rf, a, all_idx)
    full = a.meta[["participant", "activity", "label", "met"]].copy()
    full["pred_class"] = cls
    full["prob_nonsed"] = prob
    full["est"] = est
    out["in_sample_classifier_and_regressor"] = M.summarize(full)
    # classifier trained on everybody (as the published loop), regressor proper LOSO
    res_leaky_clf = M.loso(a, leaky_classifier=True)
    out["published_loop_leaky_classifier_proper_regressor"] = M.summarize(res_leaky_clf)
    # proper classifier, regressor trained on everybody including the held-out participant
    reg_all = rf.predict(a.X_reg)
    r2 = res_proper.copy()
    r2["est"] = np.where(r2["pred_class"].to_numpy() == 0, 1.0, np.maximum(reg_all, 1.0))
    out["proper_classifier_leaky_regressor"] = M.summarize(r2)
    return out
