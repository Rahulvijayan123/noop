"""Learned transition expert — artifact, training, and numpy-only inference.

Two model kinds share one artifact schema (``nara.transition.model/1``) and one inference path:

* ``xgb``      — XGBoost ``multi:softprob`` over transition-feat-1 features, exported as JSON
                 trees and evaluated in pure numpy float32 exactly as XGBoost does
                 (``float32(x) < split``, NaN follows ``default_left``). This mirrors the
                 WristMET precedent (Tools/EnergyModels/energy_models/wristmet): xgboost and
                 scikit-learn are BUILD-TIME dependencies only; the runtime needs numpy alone.
* ``logistic`` — multinomial logistic regression (scikit-learn), a single (5, n_features)
                 weight matrix; the simplest credible candidate (spec s13: the simplest
                 statistically similar model wins).

Both produce the same five canonical probabilities (none, sit_to_stand, stand_to_sit,
lie_down, get_up) plus an abstention rule mirroring the HART head's (max_prob / margin), so the
Swift ActivityContext evidence channel can weight them exactly like encoder evidence. The model
is an EVIDENCE EXPERT only — the HSMM stays canonical and may override it.

Abstention (spec s15): a window abstains when max_prob < thresholds.max_prob, or the top-2
margin < thresholds.margin, or any required feature is unresolvable (None -> NaN row). An
abstaining expert reports the abstained flag, and the Swift channel then skips that window
entirely — it is never silently forced into a class.
"""

from __future__ import annotations

import gzip
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .transition_features import FEATURE_NAMES, feature_matrix

SCHEMA = "nara.transition.model/1"
CLASSES: Tuple[str, ...] = ("none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up")
DEFAULT_THRESHOLDS = {"max_prob": 0.60, "margin": 0.10}
_CHUNK = 4096  # rows per tree-traversal batch (bounds memory, mirrors wristmet)


class TransitionModelError(ValueError):
    """Artifact is missing/incorrect; message is safe to surface."""


@dataclass(frozen=True)
class TransitionPrediction:
    """One window's transition-expert output (the evidence the HSMM consumes)."""
    probs: Dict[str, float]          # canonical 5 classes, summing to 1 (softmax)
    label: str                        # argmax class, or "unknown" when abstaining
    confidence: float                 # max prob over the 5 classes
    abstained: bool                   # threshold rule fired (see module docstring)


def _softmax_rows(m: np.ndarray) -> np.ndarray:
    m = m - m.max(axis=1, keepdims=True)
    e = np.exp(m)
    return e / e.sum(axis=1, keepdims=True)


class _TreeEnsemble:
    """Concatenated XGBoost trees evaluated level by level with numpy fancy indexing.

    XGBoost semantics exactly: go left iff ``float32(x) < float32(split_condition)``; NaN (an
    unresolvable feature) follows ``default_left``. Trees are grouped per class in ``group``;
    margins are summed per class in tree order (fixed), then softmaxed with base_margin.
    """

    def __init__(self, trees: List[dict], n_classes: int):
        if not trees or n_classes < 2:
            raise TransitionModelError("tree ensemble needs trees and >=2 classes")
        self.n_classes = n_classes
        feature, thr, left, right, dleft, value, tree_group = [], [], [], [], [], [], []
        roots, group_of_tree = [], []
        offset = 0
        for ti, t in enumerate(trees):
            nodes = t["nodes"]
            base = offset  # node ids inside a tree are LOCAL; the ensemble indexes globally
            for node in nodes:
                feature.append(int(node["feature"]))
                thr.append(float(node["split"]))
                # leaves (feature < 0) have no children; keep their links at themselves
                leaf = int(node["feature"]) < 0
                left.append(base if leaf else base + int(node["left"]))
                right.append(base if leaf else base + int(node["right"]))
                dleft.append(bool(node["default_left"]))
                value.append(float(node["value"]))
            roots.append(base)
            group_of_tree.append(int(t.get("class", ti % n_classes)))
            offset += len(nodes)
        self.feature = np.asarray(feature, dtype=np.int64)
        self.thr = np.asarray(thr, dtype=np.float32)
        self.left = np.asarray(left, dtype=np.int64)
        self.right = np.asarray(right, dtype=np.int64)
        self.default_left = np.asarray(dleft, dtype=bool)
        self.value = np.asarray(value, dtype=np.float32)
        self.roots = np.asarray(roots, dtype=np.int64)
        self.group = np.asarray(group_of_tree, dtype=np.int64)
        if (self.left < 0).any() or (self.right < 0).any():
            raise TransitionModelError("tree node links must be >= 0 (encode leaves as value nodes)")

    def margins(self, x: np.ndarray) -> np.ndarray:
        """(n, n_classes) summed leaf margins (float32, fixed tree order).

        Level-by-level evaluation: every row walks its tree until it lands on a leaf
        (feature < 0); leaves accumulate their value into the tree's class column.
        """
        n = x.shape[0]
        out = np.zeros((n, self.n_classes), dtype=np.float32)
        x32 = x.astype(np.float32)
        col = np.arange(x32.shape[1], dtype=np.int64)
        for ti in range(len(self.roots)):
            node = np.full(n, int(self.roots[ti]), dtype=np.int64)
            for _ in range(64):  # depth bound; boosted stumps are shallow
                active = self.feature[node] >= 0
                if not active.any():
                    break
                idx = np.where(active)[0]
                nd = node[idx]
                f = self.feature[nd]
                v = x32[idx, f]
                go_left = v < self.thr[nd]          # NaN compares False -> default branch
                nan = np.isnan(v)
                if nan.any():
                    go_left[nan] = self.default_left[nd[nan]]
                node[idx] = np.where(go_left, self.left[nd], self.right[nd])
            out[:, int(self.group[ti])] += self.value[node]
        return out


class TransitionModel:
    """Load a transition artifact and predict per-window 5-class probabilities (numpy only)."""

    def __init__(self, artifact: dict):
        if not isinstance(artifact, dict):
            raise TransitionModelError("artifact must be a JSON object")
        if artifact.get("schema") != SCHEMA:
            raise TransitionModelError(f"unsupported schema {artifact.get('schema')!r} (expected {SCHEMA})")
        self.kind = artifact.get("model_kind")
        if self.kind not in ("xgb", "logistic"):
            raise TransitionModelError(f"model_kind must be 'xgb' or 'logistic', got {self.kind!r}")
        self.classes = tuple(artifact.get("classes", ()))
        if tuple(self.classes) != CLASSES:
            raise TransitionModelError(f"classes must be {CLASSES}, got {self.classes}")
        self.feature_names = tuple(artifact.get("feature_names", ()))
        if not self.feature_names or any(f not in FEATURE_NAMES for f in self.feature_names):
            raise TransitionModelError("feature_names must be a subset of transition-feat-1 names")
        scaler = artifact.get("scaler", {})
        self.mean = np.asarray(scaler.get("mean", []), dtype=np.float64)
        self.scale = np.asarray(scaler.get("scale", []), dtype=np.float64)
        if self.mean.shape != (len(self.feature_names),) or self.scale.shape != (len(self.feature_names),):
            raise TransitionModelError("scaler mean/scale must match feature_names length")
        if not np.isfinite(self.scale).all() or (self.scale <= 0).any():
            raise TransitionModelError("scaler scale must be finite and positive")
        thr = artifact.get("thresholds", {})
        self.max_prob = float(thr.get("max_prob", DEFAULT_THRESHOLDS["max_prob"]))
        self.margin = float(thr.get("margin", DEFAULT_THRESHOLDS["margin"]))
        self.base_margin = np.asarray(artifact.get("base_margin", [0.0] * len(CLASSES)), dtype=np.float32)
        if self.kind == "xgb":
            self.trees = _TreeEnsemble(artifact.get("trees", []), len(CLASSES))
        else:
            w = np.asarray(artifact.get("logistic", {}).get("weights", []), dtype=np.float64)
            b = np.asarray(artifact.get("logistic", {}).get("bias", []), dtype=np.float64)
            if w.shape != (len(CLASSES), len(self.feature_names)) or b.shape != (len(CLASSES),):
                raise TransitionModelError("logistic weights (5, n_features) and bias (5,) required")
            self.lr_w, self.lr_b = w, b
        self.provenance = artifact.get("provenance", {})
        self.model_version = str(artifact.get("model_version", "transition-v0"))

    @classmethod
    def load(cls, path) -> "TransitionModel":
        p = Path(path)
        opener = gzip.open if p.suffix == ".gz" else open
        try:
            with opener(p, "rt") as fh:  # type: ignore[operator]
                return cls(json.load(fh))
        except TransitionModelError:
            raise
        except Exception as exc:
            raise TransitionModelError(f"unreadable transition artifact {p}: {exc}") from exc

    # ---- inference -----------------------------------------------------------

    def _features_matrix(self, rows: Sequence[Dict[str, Optional[float]]]) -> np.ndarray:
        mat, names = feature_matrix(list(rows))  # canonical order
        idx = [list(FEATURE_NAMES).index(f) for f in self.feature_names]
        mat = mat[:, idx]
        bad = ~np.isfinite(mat).all(axis=1)
        mat[bad] = 0.0  # NaN rows handled via the rows mask, not imputed silently
        return (mat - self.mean) / self.scale, ~bad

    def predict_batch(self, rows: Sequence[Dict[str, Optional[float]]]) -> List[TransitionPrediction]:
        """Deterministic per-window predictions; rows with unresolvable features abstain."""
        if not rows:
            return []
        x, resolvable = self._features_matrix(rows)
        if self.kind == "xgb":
            margins = self.trees.margins(x) + self.base_margin
            probs = _softmax_rows(margins.astype(np.float64))
        else:
            margins = x @ self.lr_w.T + self.lr_b
            probs = _softmax_rows(margins)
        out: List[TransitionPrediction] = []
        for i in range(len(rows)):
            if not resolvable[i]:
                out.append(TransitionPrediction(
                    probs={c: 0.2 for c in CLASSES}, label="unknown", confidence=0.0, abstained=True))
                continue
            p = {c: float(probs[i, j]) for j, c in enumerate(CLASSES)}
            ordered = sorted(p.items(), key=lambda kv: kv[0])  # fixed order for determinism
            top2 = sorted((v for _, v in ordered), reverse=True)[:2]
            mx = top2[0]
            marg = mx - (top2[1] if len(top2) > 1 else 0.0)
            abstained = mx < self.max_prob or marg < self.margin
            label = max(ordered, key=lambda kv: (kv[1], kv[0]))[0]
            out.append(TransitionPrediction(probs=p, label="unknown" if abstained else label,
                                            confidence=float(mx), abstained=abstained))
        return out

    def predict_window(self, data: np.ndarray, hz: float) -> TransitionPrediction:
        """Convenience: features of one native-rate (n, 6) window -> prediction."""
        from .transition_features import window_transition_features
        return self.predict_batch([window_transition_features(data, hz)])[0]


# ---- build-time training (xgboost / scikit-learn; never a runtime dep) --------

def train_xgboost(x_train, y_train, seed: int = 0, n_estimators: int = 300,
                  max_depth: int = 3) -> Any:
    """Fit an XGBoost multi:softprob model (build-time only)."""
    import xgboost as xgb
    model = xgb.XGBClassifier(
        objective="multi:softprob", num_class=len(CLASSES), n_estimators=n_estimators,
        max_depth=max_depth, learning_rate=0.1, subsample=0.8, colsample_bytree=0.8,
        min_child_weight=3, reg_lambda=1.0, random_state=seed, n_jobs=1, tree_method="hist",
        eval_metric="mlogloss")
    model.fit(np.asarray(x_train, dtype=np.float32), np.asarray(y_train, dtype=np.int64))
    return model


def train_logistic(x_train, y_train, seed: int = 0) -> Any:
    """Fit multinomial logistic regression (build-time only)."""
    from sklearn.linear_model import LogisticRegression
    return LogisticRegression(max_iter=2000, C=1.0, random_state=seed).fit(
        np.asarray(x_train, dtype=np.float64), np.asarray(y_train, dtype=np.int64))


def _node_id(ref: Any) -> int:
    """Parse an xgboost node reference like ``'0-7'`` (tree-node) into the node index."""
    return int(str(ref).split("-")[-1])


def _xgb_trees_to_artifact(model, feature_names: Sequence[str], mean, scale,
                           thresholds: Dict[str, float], provenance: Dict[str, Any],
                           model_version: str) -> dict:
    """Dump an XGBClassifier as schema-nara.transition.model/1 trees (float32-exact)."""
    booster = model.get_booster()
    df = booster.trees_to_dataframe()
    trees: List[dict] = []
    n_class = len(CLASSES)
    n_estimators = model.n_estimators
    for t in sorted(df["Tree"].unique()):
        sub = df[df["Tree"] == t]
        # XGBoost orders multi:softprob trees iteration-major / class-minor: tree t covers
        # class (t % n_class) within iteration (t // n_class) -- verify against predict_proba.
        cls = int(t) % n_class
        nodes = []
        for _, row in sub.iterrows():
            f = row.get("Feature")
            is_leaf = (not isinstance(f, str)) or f == "Leaf"
            if is_leaf:
                # trees_to_dataframe stores the leaf value in Gain for Leaf rows
                nodes.append({"feature": -1, "split": 0.0, "left": 0, "right": 0,
                              "default_left": False, "value": float(row["Gain"])})
            else:
                fid = int(str(f).lstrip("f"))
                thr = np.float32(row["Split"])  # float32 comparison, xgboost semantics
                nodes.append({"feature": fid, "split": float(thr),
                              "left": _node_id(row["Yes"]), "right": _node_id(row["No"]),
                              "default_left": bool(row["Missing"] == row["Yes"]),
                              "value": 0.0})
        trees.append({"class": cls, "nodes": nodes})
    return {
        "schema": SCHEMA, "model_kind": "xgb", "model_version": model_version,
        "classes": list(CLASSES), "feature_names": list(feature_names),
        "feature_schema": "transition-feat-1",
        "scaler": {"mean": [float(v) for v in mean], "scale": [float(v) for v in scale],
                   "fit": "train"},
        "thresholds": thresholds, "trees": trees,
        "base_margin": _xgb_base_margin(booster, n_class), "provenance": provenance,
    }


def _xgb_base_margin(booster, n_class: int) -> List[float]:
    """The booster's fitted per-class intercept, as the margin every tree sum starts from.

    XGBoost >= 3 fits a vector ``base_score`` for multi:softprob; older versions store one
    scalar, which shifts every class equally and so cancels in the softmax."""
    config = json.loads(booster.save_config())
    raw = str(config["learner"]["learner_model_param"]["base_score"]).strip()
    values = [float(v) for v in raw.strip("[]").split(",") if v.strip()]
    if len(values) == n_class:
        return values
    return [0.0] * n_class


def export_logistic(model, feature_names: Sequence[str], mean, scale,
                    thresholds: Dict[str, float], provenance: Dict[str, Any],
                    model_version: str) -> dict:
    """Serialize a fitted LogisticRegression as schema-nara.transition.model/1."""
    # scikit-learn classes_ may be canonical strings or integer class ids; map to the
    # canonical CLASSES order either way so the artifact always stores canonical order.
    classes = [str(c) for c in model.classes_]
    if tuple(classes) == tuple(CLASSES):
        order = list(range(len(CLASSES)))
    elif all(c.lstrip("-").isdigit() for c in classes):
        order = [int(c) for c in classes]
    else:
        raise TransitionModelError(f"logistic classes {classes!r} do not map onto {CLASSES}")
    w = np.asarray(model.coef_, dtype=np.float64)[order]
    b = np.asarray(model.intercept_, dtype=np.float64)[order]
    return {
        "schema": SCHEMA, "model_kind": "logistic", "model_version": model_version,
        "classes": list(CLASSES), "feature_names": list(feature_names),
        "feature_schema": "transition-feat-1",
        "scaler": {"mean": [float(v) for v in mean], "scale": [float(v) for v in scale],
                   "fit": "train"},
        "thresholds": thresholds,
        "logistic": {"weights": w.tolist(), "bias": b.tolist()},
        "provenance": provenance,
    }


def write_artifact(artifact: dict, path) -> str:
    """Write the artifact as gzipped JSON; returns the sha256 of the uncompressed bytes."""
    raw = json.dumps(artifact, separators=(",", ":"), sort_keys=True).encode("utf-8")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(p, "wb") as fh:
        fh.write(raw)
    return hashlib.sha256(raw).hexdigest()
