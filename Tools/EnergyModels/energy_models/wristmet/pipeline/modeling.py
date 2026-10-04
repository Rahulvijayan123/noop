"""Training, leave-one-subject-out evaluation and sensitivity analyses for WristMET (build time)."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from xgboost import XGBClassifier

from ..features import classifier_features
from .dataset import (
    LIGHT_ACTIVITIES,
    VIGOROUS_ACTIVITIES,
    WindowDataset,
    met_class,
    regression_intensity,
    upstream_window_arrays,
)

DEFAULT_SEED = 0


@dataclass
class Assembled:
    meta: pd.DataFrame
    X_cls: np.ndarray
    X_reg: np.ndarray
    y_cls: np.ndarray
    met: np.ndarray
    groups: np.ndarray
    reg_train_mask: np.ndarray  # windows of light / vigorous activities with finite target and features
    window_s: int

    @property
    def participants(self) -> list[int]:
        return sorted(np.unique(self.groups).tolist())


def assemble(
    ds: WindowDataset,
    *,
    mirror: bool = True,
    age_offset: float = 0.0,
    keep: np.ndarray | None = None,
    demographics_source: str = "primary",
) -> Assembled:
    """Feature matrices exactly as the upstream pipeline builds them (see ``dataset.py``).

    ``age_offset`` shifts the age feature (the upstream code derives age as the year the script is run
    minus the birth year, which is 1-3 years above the age at the visit); ``demographics_source`` selects
    the demographic values ("primary", "agd" or "notebook", see ``dataset.Demographics``).
    ``keep`` optionally restricts the windows (boolean mask over ``ds.meta``).
    """
    padded, _ = upstream_window_arrays(ds, mirror=mirror)
    x_cls = classifier_features(padded)
    inten = regression_intensity(ds)
    demo = ds.demographics(demographics_source, age_offset)
    merged = ds.meta[["participant"]].merge(demo, left_on="participant", right_on="Participant", how="left")
    x_reg = np.column_stack(
        [
            merged["gender"].to_numpy(float),
            merged["age"].to_numpy(float),
            merged["BMI"].to_numpy(float),
            inten[:, 0],
            merged["gender_age"].to_numpy(float),
            merged["gender_BMI"].to_numpy(float),
            merged["age_BMI"].to_numpy(float),
            merged["age_gender_BMI"].to_numpy(float),
            inten[:, 1],
        ]
    )
    meta = ds.meta.copy()
    meta["freq_intensity"] = inten[:, 0]
    meta["rmssd_l1"] = inten[:, 1]
    met = meta["met"].to_numpy(float)
    nonsed_act = meta["activity"].isin(LIGHT_ACTIVITIES + VIGOROUS_ACTIVITIES).to_numpy()
    reg_mask = nonsed_act & np.isfinite(met) & np.isfinite(x_reg).all(axis=1)
    a = Assembled(
        meta=meta,
        X_cls=x_cls,
        X_reg=x_reg,
        y_cls=meta["label"].to_numpy(int),
        met=met,
        groups=meta["participant"].to_numpy(int),
        reg_train_mask=reg_mask,
        window_s=ds.window_s,
    )
    if keep is not None:
        a = subset(a, keep)
    return a


def subset(a: Assembled, keep: np.ndarray) -> Assembled:
    keep = np.asarray(keep, dtype=bool)
    return Assembled(
        meta=a.meta[keep].reset_index(drop=True),
        X_cls=a.X_cls[keep],
        X_reg=a.X_reg[keep],
        y_cls=a.y_cls[keep],
        met=a.met[keep],
        groups=a.groups[keep],
        reg_train_mask=a.reg_train_mask[keep],
        window_s=a.window_s,
    )


def make_classifier(seed: int = DEFAULT_SEED, **overrides) -> XGBClassifier:
    """``XGBClassifier()`` exactly as upstream constructs it (helper_model.py:42), plus a fixed seed."""
    return XGBClassifier(random_state=seed, **overrides)


def make_regressor(seed: int = DEFAULT_SEED, **overrides) -> RandomForestRegressor:
    """``RandomForestRegressor()`` exactly as upstream constructs it (in-lab.py:496), plus a fixed seed."""
    return RandomForestRegressor(random_state=seed, **overrides)


def fit_models(
    a: Assembled,
    train: np.ndarray,
    *,
    seed: int = DEFAULT_SEED,
    reg_cols: list[int] | None = None,
    rf_overrides: dict | None = None,
) -> tuple[XGBClassifier, RandomForestRegressor]:
    clf = make_classifier(seed)
    clf.fit(a.X_cls[train], a.y_cls[train])
    cols = reg_cols if reg_cols is not None else list(range(a.X_reg.shape[1]))
    m = train & a.reg_train_mask
    rf = make_regressor(seed, **(rf_overrides or {}))
    rf.fit(a.X_reg[m][:, cols], a.met[m])
    return clf, rf


def predict_pipeline(
    clf: XGBClassifier,
    rf: RandomForestRegressor,
    a: Assembled,
    test: np.ndarray,
    *,
    reg_cols: list[int] | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Two-stage prediction on windows ``test``: (class, p(non-sedentary), estimated METs >= 1)."""
    cols = reg_cols if reg_cols is not None else list(range(a.X_reg.shape[1]))
    prob = clf.predict_proba(a.X_cls[test])[:, 1]
    cls = clf.predict(a.X_cls[test]).astype(int)
    reg = rf.predict(a.X_reg[test][:, cols])
    est = np.where(cls == 0, 1.0, np.maximum(reg, 1.0))
    return cls, prob, est


def loso(
    a: Assembled,
    *,
    seed: int = DEFAULT_SEED,
    leaky_classifier: bool = False,
    reg_cols: list[int] | None = None,
    rf_overrides: dict | None = None,
    classifier_train_mask: np.ndarray | None = None,
) -> pd.DataFrame:
    """Leave-one-participant-out predictions for every window.

    ``leaky_classifier=True`` reproduces the as-published ``in-lab.py`` loop, where the classifier is
    fit on *all* participants (including the held-out one; lines 437-442 comment the exclusion out).
    The regressor is always fit on the true non-sedentary windows of the other participants
    (in-lab.py:484-497; the upstream ``regression()`` helper that the LOSO loop calls is not in the
    public repository).
    """
    out = np.zeros((len(a.groups), 3))
    for held in a.participants:
        test = a.groups == held
        train = ~test
        clf_train = np.ones_like(train) if leaky_classifier else train
        if classifier_train_mask is not None:
            clf_train = clf_train & classifier_train_mask
        clf = make_classifier(seed)
        clf.fit(a.X_cls[clf_train], a.y_cls[clf_train])
        cols = reg_cols if reg_cols is not None else list(range(a.X_reg.shape[1]))
        m = train & a.reg_train_mask
        rf = make_regressor(seed, **(rf_overrides or {}))
        rf.fit(a.X_reg[m][:, cols], a.met[m])
        cls = clf.predict(a.X_cls[test]).astype(int)
        prob = clf.predict_proba(a.X_cls[test])[:, 1]
        reg = rf.predict(a.X_reg[test][:, cols])
        out[test, 0] = cls
        out[test, 1] = prob
        out[test, 2] = np.where(cls == 0, 1.0, np.maximum(reg, 1.0))
    res = a.meta[["participant", "activity", "label", "met"]].copy()
    res["pred_class"] = out[:, 0].astype(int)
    res["prob_nonsed"] = out[:, 1]
    res["est"] = out[:, 2]
    return res


def summarize(res: pd.DataFrame, mask: np.ndarray | None = None) -> dict:
    """Pooled RMSE overall / by measured-MET class, per-participant mean RMSE, classifier metrics."""
    r = res if mask is None else res[mask]
    r = r[np.isfinite(r["met"])]
    err = r["est"].to_numpy() - r["met"].to_numpy()
    cls = met_class(r["met"].to_numpy())
    out = {
        "n_windows": int(len(r)),
        "rmse_overall": float(np.sqrt(np.mean(err**2))),
        "rmse_sedentary": float(np.sqrt(np.mean(err[cls == 0] ** 2))),
        "rmse_light": float(np.sqrt(np.mean(err[cls == 1] ** 2))),
        "rmse_mod_vig": float(np.sqrt(np.mean(err[cls == 2] ** 2))),
        "n_sedentary": int((cls == 0).sum()),
        "n_light": int((cls == 1).sum()),
        "n_mod_vig": int((cls == 2).sum()),
    }
    per_p = r.assign(se=err**2).groupby("participant")["se"].mean().pow(0.5)
    out["rmse_per_participant_mean"] = float(per_p.mean())
    out["rmse_per_participant_sd"] = float(per_p.std(ddof=1))
    y = r["label"].to_numpy()
    p = r["pred_class"].to_numpy()
    out.update(classifier_metrics(y, p))
    return out


def classifier_metrics(y: np.ndarray, pred: np.ndarray) -> dict:
    """Precision / recall / F1 with ``sedentary`` (label 0) as the positive class, and the complement."""
    res = {}
    for name, pos in (("sedentary_positive", 0), ("nonsedentary_positive", 1)):
        tp = int(((pred == pos) & (y == pos)).sum())
        fp = int(((pred == pos) & (y != pos)).sum())
        fn = int(((pred != pos) & (y == pos)).sum())
        prec = tp / (tp + fp) if tp + fp else float("nan")
        rec = tp / (tp + fn) if tp + fn else float("nan")
        f1 = 2 * prec * rec / (prec + rec) if prec == prec and rec == rec and prec + rec else float("nan")
        res[name] = {"precision": prec, "recall": rec, "f1": f1, "tp": tp, "fp": fp, "fn": fn}
    res["accuracy"] = float((y == pred).mean())
    return res
