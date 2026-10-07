"""Head fitting (torch, CPU, deterministic): masked losses, early stopping on VAL, the architecture rule.

* :func:`fit_head` trains ONE independent head with AdamW on TRAIN rows and early-stops on the VAL loss
  (same objective, VAL rows); the best-epoch weights are kept. Tasks: ``set`` (softmax set-CE with class
  weights), ``multilabel`` (masked BCE with per-event pos_weight), ``reg`` (Huber on sigmoid output).
* :func:`fit_grid` picks (lr, weight decay) on the VAL loss.
* :func:`select_arch` — the architecture rule (Agent D): MLP replaces the linear probe only if, by
  subject-grouped 5-fold CV over train ∪ val (fixed epochs/hyper-parameters from the train/val fit), the
  MLP improves macro-F1 by >= 2 points on average, the paired subject-bootstrap CI lower bound is > 0, the
  improvement is positive in >= 4/5 folds, and the (fold-oracle temperature) calibrated NLL is not worse
  by > 0.02. Otherwise linear. CV fold training rows are capped (hash subsample) to bound compute.

Determinism: ``torch.manual_seed(seed)``, deterministic algorithms, a fixed thread count, a seeded
generator for batch order; two runs with the same inputs give identical weights (tested).
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import torch

from . import metrics as M
from .bootstrap import cluster_bootstrap
from .heads import export_head, make_head, numpy_logits
from .losses import masked_bce, masked_huber, masked_set_ce

THREADS = 4
GRID = {"linear": ((3e-3, 1e-4), (3e-3, 1e-2)), "mlp": ((1e-3, 1e-4), (1e-3, 1e-2))}
MAX_EPOCHS, PATIENCE, BATCH = 40, 5, 1024
CV_FOLDS, CV_ROW_CAP = 5, 30000
RULE = {"min_delta_f1": 0.02, "max_nll_worse": 0.02, "min_folds": 4}


def set_determinism(seed: int) -> torch.Generator:
    torch.manual_seed(seed)
    torch.set_num_threads(THREADS)
    torch.use_deterministic_algorithms(True)
    return torch.Generator().manual_seed(seed)


@dataclass
class FitResult:
    arch: str
    lr: float
    wd: float
    best_epoch: int
    best_val: float
    arrays: Dict[str, np.ndarray]
    history: List[float] = field(default_factory=list)
    model: Optional[torch.nn.Module] = None


def _loss(task: str, out: torch.Tensor, y: torch.Tensor, sup: Optional[torch.Tensor], cw: Optional[torch.Tensor],
          rw: Optional[torch.Tensor]) -> torch.Tensor:
    if task == "set":
        return masked_set_ce(out, y, sup, cw, rw)
    if task == "multilabel":
        return masked_bce(out, y, sup, cw, rw)
    return masked_huber(torch.sigmoid(out[:, 0]), y, row_weight=rw)


def _tensor_y(task: str, y: np.ndarray) -> torch.Tensor:
    if task == "set":
        return torch.from_numpy(np.asarray(y, np.int64))
    if task == "multilabel":
        return torch.from_numpy(np.asarray(y, np.int64))
    return torch.from_numpy(np.asarray(y, np.float32))


def fit_head(task: str, arch: str, z_tr: np.ndarray, y_tr: np.ndarray, z_va: Optional[np.ndarray],
             y_va: Optional[np.ndarray], K: int, supported: Optional[np.ndarray] = None,
             class_weight: Optional[np.ndarray] = None, rw_tr: Optional[np.ndarray] = None,
             rw_va: Optional[np.ndarray] = None, lr: float = 3e-3, wd: float = 1e-4, seed: int = 0,
             max_epochs: int = MAX_EPOCHS, patience: int = PATIENCE, fixed_epochs: Optional[int] = None,
             name: str = "head") -> FitResult:
    gen = set_determinism(seed)
    model = make_head(arch, z_tr.shape[1], K)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=wd)
    Z = torch.from_numpy(np.ascontiguousarray(z_tr, np.float32))
    Y = _tensor_y(task, y_tr)
    sup = None if supported is None else torch.from_numpy(np.asarray(supported, bool))
    cw = None if class_weight is None else torch.from_numpy(np.asarray(class_weight, np.float32))
    RW = None if rw_tr is None else torch.from_numpy(np.asarray(rw_tr, np.float32))
    if z_va is not None:
        Zv, Yv = torch.from_numpy(np.ascontiguousarray(z_va, np.float32)), _tensor_y(task, y_va)
        RWv = None if rw_va is None else torch.from_numpy(np.asarray(rw_va, np.float32))
    best, best_state, best_ep, stall, hist = math.inf, None, 0, 0, []
    epochs = fixed_epochs if fixed_epochs is not None else max_epochs
    for ep in range(epochs):
        model.train()
        perm = torch.randperm(len(Z), generator=gen)
        for i in range(0, len(perm), BATCH):
            idx = perm[i:i + BATCH]
            opt.zero_grad(set_to_none=True)
            loss = _loss(task, model(Z[idx]), Y[idx], sup, cw, None if RW is None else RW[idx])
            loss.backward()
            opt.step()
        if fixed_epochs is not None or z_va is None:
            continue
        model.eval()
        with torch.no_grad():
            v = float(_loss(task, model(Zv), Yv, sup, cw, RWv))
        hist.append(v)
        if v < best - 1e-6:
            best, best_ep, stall = v, ep + 1, 0
            best_state = {k: t.detach().clone() for k, t in model.state_dict().items()}
        else:
            stall += 1
            if stall >= patience:
                break
    if best_state is not None:
        model.load_state_dict(best_state)
    else:
        best_ep = epochs
    model.eval()
    return FitResult(arch, lr, wd, best_ep, best, export_head(model, name, arch), hist, model)


def fit_grid(task: str, arch: str, z_tr, y_tr, z_va, y_va, K, seed: int = 0, **kw) -> Tuple[FitResult, List[Dict]]:
    best, rows = None, []
    for lr, wd in GRID[arch]:
        fr = fit_head(task, arch, z_tr, y_tr, z_va, y_va, K, lr=lr, wd=wd, seed=seed, **kw)
        rows.append({"lr": lr, "wd": wd, "best_epoch": fr.best_epoch, "val_loss": fr.best_val})
        if best is None or fr.best_val < best.best_val:
            best = fr
    return best, rows


def softmax_probs(arrays: Dict[str, np.ndarray], name: str, arch: str, z: np.ndarray, supported: np.ndarray,
                  T: float = 1.0) -> np.ndarray:
    lg = numpy_logits(arrays, name, arch, z) / T
    lg = np.where(np.asarray(supported, bool)[None, :], lg, -np.inf)
    lg = lg - lg.max(axis=1, keepdims=True)
    e = np.exp(lg)
    return e / e.sum(axis=1, keepdims=True)


def _fold_ids(subjects: np.ndarray, n: int) -> np.ndarray:
    subs = sorted(np.unique(subjects).tolist(), key=lambda s: hashlib.sha256(s.encode()).hexdigest())
    lut = {s: i % n for i, s in enumerate(subs)}
    return np.array([lut[s] for s in subjects])


def _cap(n_rows: int, uids: np.ndarray, cap: int) -> np.ndarray:
    if n_rows <= cap:
        return np.arange(n_rows)
    r = np.array([int(hashlib.sha256(u.encode()).hexdigest()[:12], 16) for u in uids])
    return np.sort(np.argsort(r, kind="stable")[:cap])


def _macro_f1(probs: np.ndarray, truth: np.ndarray, supported: np.ndarray) -> float:
    y, _ = M.attributed_truth(probs, truth)
    cm = M.confusion(y, probs.argmax(axis=1), probs.shape[1])
    present = [k for k in range(probs.shape[1]) if supported[k] and cm[k].sum() > 0]
    return M.macro_f1(cm, present)


def select_arch(name: str, z: np.ndarray, bits: np.ndarray, subjects: np.ndarray, uids: np.ndarray,
                supported: np.ndarray, class_weight: np.ndarray, rw: np.ndarray, fits: Dict[str, FitResult],
                seed: int = 0) -> Dict:
    """CV rule over train ∪ val rows (``bits`` resolved, nonzero). Returns the decision and its evidence."""
    from .calibrate import fit_temperature
    K = len(supported)
    truth = ((bits[:, None].astype(np.int64) >> np.arange(K)[None, :]) & 1).astype(bool)
    folds = _fold_ids(np.asarray(subjects).astype(str), CV_FOLDS)
    oof = {a: np.zeros((len(z), K)) for a in fits}
    per_fold = []
    for f in range(CV_FOLDS):
        te, tr = folds == f, folds != f
        if not te.any() or not tr.any():
            continue
        sel = np.flatnonzero(tr)[_cap(int(tr.sum()), uids[tr], CV_ROW_CAP)]
        row = {"fold": f, "n_train": int(len(sel)), "n_test": int(te.sum())}
        for a, fr in fits.items():
            m = fit_head("set", a, z[sel], bits[sel], None, None, K, supported, class_weight, rw[sel],
                         lr=fr.lr, wd=fr.wd, seed=seed, fixed_epochs=max(1, fr.best_epoch), name=name)
            lg = numpy_logits(m.arrays, name, a, z[te])[:, supported]
            T = fit_temperature(lg, truth[te][:, supported])["T"]
            p = softmax_probs(m.arrays, name, a, z[te], supported)
            pc = softmax_probs(m.arrays, name, a, z[te], supported, T)
            oof[a][te] = p
            row[a] = {"macro_f1": _macro_f1(p, truth[te], supported), "nll_cal": M.nll(pc, truth[te]), "T": T}
        per_fold.append(row)
    deltas = [r["mlp"]["macro_f1"] - r["linear"]["macro_f1"] for r in per_fold]
    d_nll = float(np.mean([r["mlp"]["nll_cal"] - r["linear"]["nll_cal"] for r in per_fold]))
    boot = cluster_bootstrap(lambda idx: _macro_f1(oof["mlp"][idx], truth[idx], supported)
                             - _macro_f1(oof["linear"][idx], truth[idx], supported),
                             np.asarray(subjects).astype(str), n_boot=300, seed=seed)
    n_pos = int(sum(d > 0 for d in deltas))
    mean_d = float(np.mean(deltas)) if deltas else float("nan")
    pick = ("mlp" if (mean_d >= RULE["min_delta_f1"] and boot["ci_low"] > 0 and n_pos >= RULE["min_folds"]
                      and d_nll <= RULE["max_nll_worse"]) else "linear")
    return {"chosen": pick, "mean_delta_macro_f1": mean_d, "folds_positive": n_pos, "delta_nll_cal": d_nll,
            "bootstrap_delta_macro_f1": boot, "per_fold": per_fold, "rule": dict(RULE, folds=CV_FOLDS,
            row_cap=CV_ROW_CAP, note="MLP iff mean dF1>=0.02 & CI low>0 & >=4/5 folds positive & dNLL<=0.02")}


__all__ = ["fit_head", "fit_grid", "select_arch", "softmax_probs", "FitResult", "set_determinism", "GRID", "RULE",
           "THREADS"]
