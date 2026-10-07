"""Support / class weights (train only) / determinism / training-side vs bundle.apply parity (synthetic)."""

import numpy as np
import pytest

pytest.importorskip("torch")

from activity_context.inertia import HEAD_CLASS_ORDERS  # noqa: E402
from activity_context.inertia import weights as W  # noqa: E402
from activity_context.inertia.mappings import bitmask  # noqa: E402
from activity_context.inertia.targets import resolve_support  # noqa: E402
from activity_context.inertia.train_heads import fit_head  # noqa: E402

FAM = {"walking": ["walking", "brisk_walking"]}


def _bits(classes, head="locomotion"):
    return np.array([bitmask(c if isinstance(c, list) else [c], head) for c in classes], np.uint16)


def test_support_thresholds_and_covers():
    walk = ["walking", "brisk_walking"]
    tr = _bits([walk] * 300 + ["stationary"] * 300 + ["stairs"] * 150 + [["walking", "brisk_walking", "stationary"]] * 10)
    subj_tr = np.array([f"s{i % 6}" for i in range(len(tr))])
    va = _bits([walk] * 20 + ["stationary"] * 20 + ["stairs"] * 20)
    subj_va = np.array([f"v{i % 2}" for i in range(len(va))])
    sup = resolve_support("locomotion", tr, subj_tr, va, subj_va, FAM)
    order = HEAD_CLASS_ORDERS["locomotion"]
    assert sup.supported[order.index("walking")] and sup.supported[order.index("stationary")]
    assert not sup.supported[order.index("stairs")] and not sup.supported[order.index("brisk_walking")]
    assert sup.covers == {"walking": ["walking", "brisk_walking"]}
    r = sup.resolve(_bits([walk, "stairs", "brisk_walking", ["walking", "brisk_walking", "stationary"]]))
    assert list(r) == [bitmask(["walking"], "locomotion"), 0, bitmask(["walking"], "locomotion"),
                       bitmask(["walking", "stationary"], "locomotion")]


def test_too_few_val_subjects_unsupported():
    tr = _bits(["stationary"] * 400)
    sup = resolve_support("locomotion", tr, np.array([f"s{i % 6}" for i in range(400)]), _bits(["stationary"] * 50),
                          np.array(["v0"] * 50), FAM)
    assert not sup.supported.any()


def test_class_weights_train_only_and_clipped():
    bits = _bits(["stationary"] * 900 + ["walking"] * 100)
    sup = np.zeros(8, bool)
    sup[[0, 1]] = True
    w = W.class_weights(bits, sup)
    assert w[2:].sum() == 0 and abs(w[sup].mean() - 1.0) < 1e-9 and w[1] > w[0]
    w2 = W.class_weights(_bits(["stationary"] * 10000 + ["walking"] * 1), sup)
    assert w2[1] / w2[0] == pytest.approx(5.0 / 0.2, rel=1e-6) or w2[1] / w2[0] <= 25.0
    W.assert_train_only(np.array(["train", "train"]))
    with pytest.raises(W.LeakError):
        W.assert_train_only(np.array(["train", "val"]))


def test_balance_rows_sqrt():
    ds = np.array(["a"] * 100 + ["b"] * 4)
    subj = np.array(["a1"] * 75 + ["a2"] * 25 + ["b1"] * 4)
    w = W.balance_rows(ds, subj)
    assert abs(w.mean() - 1) < 1e-12
    tot = {d: w[ds == d].sum() for d in ("a", "b")}
    assert tot["a"] / tot["b"] == pytest.approx(np.sqrt(100) / np.sqrt(4), rel=1e-9)
    assert w[subj == "a1"].sum() / w[subj == "a2"].sum() == pytest.approx(np.sqrt(75) / np.sqrt(25), rel=1e-9)


def test_training_is_deterministic_on_cpu():
    rng = np.random.default_rng(0)
    z = rng.standard_normal((400, 12)).astype(np.float32)
    y = np.where(z[:, 0] > 0, 1 << 0, 1 << 1).astype(np.int64)
    sup = np.zeros(8, bool)
    sup[:2] = True
    a = fit_head("set", "mlp", z[:300], y[:300], z[300:], y[300:], 8, sup, seed=3, max_epochs=5)
    b = fit_head("set", "mlp", z[:300], y[:300], z[300:], y[300:], 8, sup, seed=3, max_epochs=5)
    for k in a.arrays:
        assert np.array_equal(a.arrays[k], b.arrays[k]), k


def test_smoke_bundle_parity_and_reproducibility(tmp_path):
    from activity_context.inertia import bundle as B
    from activity_context.inertia.smoke import run_smoke
    r = run_smoke(str(tmp_path / "a"), arch="linear")
    assert r["parity_max_abs"] < 1e-6                     # training-side numpy == bundle.apply
    assert set(r["heads"]) >= {"posture", "locomotion", "arm_behavior", "transition"}
    r2 = run_smoke(str(tmp_path / "b"), arch="linear")
    b1, b2 = B.load_bundle(r["bundle_dir"]), B.load_bundle(r2["bundle_dir"])
    for k in b1.heads_arrays:
        assert np.array_equal(b1.heads_arrays[k], b2.heads_arrays[k]), k
    m = b1.manifest
    assert m["evidence_tier_max"] == "shadow" and m["training"]["head_inputs"] == ["embedding"]
    assert m["encoder"]["checkpoint_sha256"] is None
    for h in ("posture", "locomotion", "arm_behavior", "transition"):
        assert m["heads"][h]["class_order"] == list(HEAD_CLASS_ORDERS[h])
    rows = b1.apply(np.zeros((2, m["encoder"]["embedding_dim"]), np.float32))
    for h in ("posture", "locomotion", "arm_behavior"):
        assert abs(sum(rows[0][h].values()) - 1.0) < 1e-9 and "unknown" not in rows[0][h]
