"""Head bundle tests: round trip, tamper detection, schema refusals, head/calibration/OOD math."""

import copy
import json
import os

import numpy as np
import pytest

pytest.importorskip("scipy")
from scipy.special import expit, logsumexp, softmax  # noqa: E402

from activity_context.inertia import bundle_math as bm  # noqa: E402
from activity_context.inertia.bundle import BundleError, load_bundle, write_bundle  # noqa: E402
from activity_context.inertia.bundle_schema import validate_all  # noqa: E402
from activity_context.inertia.synthetic import synthetic_bundle_parts  # noqa: E402

D = 12
ENC = {"encoder_id": "standin:test-encoder", "embedding_dim": D, "checkpoint_sha256": None, "config_sha256": None}


def _parts(ood="knn", seed=0):
    ref = np.random.default_rng(100 + seed).normal(size=(40, D))
    return synthetic_bundle_parts(encoder=ENC, reference=ref, ood_method=ood, seed=seed)


def _write(tmp_path, parts=None, name="b", **kw):
    out = os.path.join(tmp_path, name)
    return out, write_bundle(out, **(parts or _parts()), **kw)


def _refuse(kind, fn, *a, **kw):
    with pytest.raises(BundleError) as ei:
        fn(*a, **kw)
    assert ei.value.kind == kind, str(ei.value)


def test_round_trip_and_deterministic_hash(tmp_path):
    out, sha = _write(tmp_path, extra_files={"label_mappings.json": "{}\n", "notes.md": b"fixture"})
    b = load_bundle(out)
    assert b.bundle_sha256 == sha and b.bundle_id == "fixture-heads-seed0"
    assert set(b.manifest["files"]) == {"heads.npz", "calibration.json", "ood_reference.npz", "ood_reference.json",
                                        "label_mappings.json", "notes.md"}
    parts = _parts()
    for k, v in parts["heads_arrays"].items():
        assert np.array_equal(b.heads_arrays[k], v)
    _, sha2 = _write(tmp_path, name="b2", extra_files={"label_mappings.json": "{}\n", "notes.md": b"fixture"})
    assert sha2 == sha
    assert b.manifest["ood"]["method"] == "knn" and b.ood_meta["content_sha256"]


@pytest.mark.parametrize("victim", ["heads.npz", "calibration.json", "ood_reference.npz", "ood_reference.json",
                                    "extra.txt"])
def test_any_byte_change_refuses(tmp_path, victim):
    out, _ = _write(tmp_path, extra_files={"extra.txt": "hello"})
    p = os.path.join(out, victim)
    data = bytearray(open(p, "rb").read())
    data[len(data) // 2] ^= 0x01
    open(p, "wb").write(bytes(data))
    _refuse("checkpoint_mismatch", load_bundle, out)


def test_manifest_edit_refuses_or_changes_bundle_hash(tmp_path):
    out, sha = _write(tmp_path)
    mp = os.path.join(out, "manifest.json")
    m = json.load(open(mp))
    m["heads"]["posture"]["class_order"][0:2] = m["heads"]["posture"]["class_order"][1::-1]
    open(mp, "w").write(json.dumps(m))
    _refuse("config_mismatch", load_bundle, out)                         # class-order mismatch
    m["heads"]["posture"]["class_order"][0:2] = m["heads"]["posture"]["class_order"][1::-1]
    m["training"]["note"] = "edited"
    open(mp, "w").write(json.dumps(m))
    assert load_bundle(out).bundle_sha256 != sha                          # valid edits change the identity
    os.remove(os.path.join(out, "heads.npz"))
    _refuse("checkpoint_mismatch", load_bundle, out)
    _refuse("model_missing", load_bundle, os.path.join(tmp_path, "nope"))


def _mutated(mutate):
    p = copy.deepcopy(_parts())
    mutate(p)
    return p


@pytest.mark.parametrize("mutate", [
    lambda p: p["calibration"]["heads"]["locomotion"]["class_order"].reverse(),
    lambda p: p["calibration"]["heads"]["posture"]["support_mask"].__setitem__(0, False),
    lambda p: p["calibration"]["heads"]["posture"]["fit"].update(split="test"),
    lambda p: p["calibration"]["heads"]["posture"].update(T=0.0),
    lambda p: p["calibration"]["heads"]["transition"].update(method="temperature"),
    lambda p: p["calibration"]["heads"]["arm_behavior"]["weight"].__setitem__(0, -1.0),
    lambda p: p["calibration"]["heads"].pop("posture"),
    lambda p: p["manifest"]["heads"]["posture"]["tau"].update(recumbent=1.5),
    lambda p: p["manifest"]["heads"]["posture"]["status"].update(recumbent="great"),
    lambda p: p["manifest"]["heads"].update(gait={"arch": "linear"}),
    lambda p: p["manifest"]["heads"]["locomotion"]["covers"].update(walking=["walking", "running"]),
    lambda p: p["manifest"]["heads"]["locomotion"]["covers"].update(stairs=["stairs"]),
    lambda p: p["manifest"]["heads"]["posture"]["merge_into"].update(postural_transition="recumbent_x"),
    lambda p: p["manifest"].update(evidence_tier_max="candidate"),       # stand-in, no provenance
    lambda p: p["manifest"]["preprocessing"].update(version="inertia-prep-0"),
    lambda p: p["manifest"]["preprocessing"].update(hop_s=60),
    lambda p: p["heads_arrays"].update({"posture.extra": np.zeros(3, np.float32)}),
    lambda p: p["heads_arrays"].update({"posture.W": np.zeros((4, D + 1), np.float32)}),
    lambda p: p["heads_arrays"].update({"std.sigma": np.zeros(D, np.float32)}),
    lambda p: p["ood_meta"].update(fit={"split": "test"}),
    lambda p: p["ood_meta"].update(k=10_000),
    lambda p: p["ood_arrays"].update(reference=p["ood_arrays"]["reference"].astype(np.float32)),
])
def test_invalid_bundles_refused_at_write(tmp_path, mutate):
    _refuse("config_mismatch", _write, tmp_path, _mutated(mutate))


def test_non_empty_out_dir_refused(tmp_path):
    out, _ = _write(tmp_path)
    with pytest.raises(FileExistsError):
        write_bundle(out, **_parts())


def test_nonfinite_threshold_refused_by_validator():
    p = _parts()
    meta = dict(p["ood_meta"], schema="nara.inertia.ood/1", threshold=float("nan"))
    m = dict(p["manifest"], schema="nara.inertia.heads/1", ood={"method": "knn", "threshold": float("nan"), "k": 3},
             files={n: "0" * 64 for n in ("heads.npz", "calibration.json", "ood_reference.npz", "ood_reference.json")})
    with pytest.raises(BundleError):
        validate_all(m, p["heads_arrays"], dict(p["calibration"], schema="nara.inertia.calibration/1"), meta,
                     p["ood_arrays"])


def _manual(b, emb):
    """Direct numpy reference of the whole head stack, written independently of bundle.py."""
    a, cal = b.heads_arrays, b.calibration["heads"]
    z = (emb - a["std.mu"].astype(np.float64)) / a["std.sigma"].astype(np.float64)
    out = {}
    for h, meta in b.manifest["heads"].items():
        if meta["arch"] == "linear":
            logit = z @ a[f"{h}.W"].astype(np.float64).T + a[f"{h}.b"]
        else:
            mu, var = z.mean(1, keepdims=True), z.var(1, keepdims=True)
            hh = (z - mu) / np.sqrt(var + 1e-5) * a[f"{h}.ln_g"] + a[f"{h}.ln_b"]
            hh = hh @ a[f"{h}.W1"].astype(np.float64).T + a[f"{h}.b1"]
            from scipy.special import erf
            hh = 0.5 * hh * (1 + erf(hh / np.sqrt(2)))
            logit = hh @ a[f"{h}.W2"].astype(np.float64).T + a[f"{h}.b2"]
        if h == "movement_intensity":
            out[h] = expit(logit[:, 0])
            continue
        idx = [i for i, s in enumerate(meta["supported"]) if s]
        c, s = cal[h], logit[:, idx]
        if c["method"] == "temperature_per_event":
            out[h] = expit(s / np.array([c["T"][i] for i in idx]))
            continue
        if c["method"] == "temperature":
            s = s / c["T"]
        elif c["method"] == "temp_bias":
            s = s / c["T"] + np.array([c["bias"][i] for i in idx])
        else:
            s = s * np.array([c["weight"][i] for i in idx]) + np.array([c["bias"][i] for i in idx])
        out[h] = softmax(s, axis=1)
    return out


def test_apply_matches_direct_reference_and_wire_rules(tmp_path):
    out, _ = _write(tmp_path)
    b = load_bundle(out)
    emb = np.random.default_rng(9).normal(size=(25, D))
    res = b.apply_arrays(emb)
    ref = _manual(b, emb)
    for h, p in res.probs.items():
        assert np.abs(p - ref[h]).max() < 1e-12
    assert np.abs(res.movement_intensity - ref["movement_intensity"]).max() < 1e-12
    rows = b.apply(emb)
    for row in rows:
        for h in ("posture", "locomotion", "arm_behavior"):
            assert abs(sum(row[h].values()) - 1.0) < 1e-12
            assert list(row[h]) == b.supported_classes(h)
        assert all(0.0 < v < 1.0 for v in row["transition"].values())
        assert "brisk_walking" not in row["locomotion"] and "lying_down_like" not in row["transition"]
        assert "none" not in row["transition"]
    wire = b.wire_block()
    assert wire["heads"]["locomotion"]["covers"] == {"walking": ["walking", "brisk_walking"]}
    assert wire["heads"]["posture"]["merge_into"] == {"postural_transition": "upright_stationary"}
    assert wire["ood"] == {"method": "knn", "threshold": b.ood_meta["threshold"]}


def test_head_with_no_supported_class_is_omitted(tmp_path):
    def none_supported(p):
        meta = p["manifest"]["heads"]["transition"]
        meta["supported"] = [False] * len(meta["supported"])
        for k in ("prior", "status", "tau", "support_counts"):
            meta[k] = {}
        c = p["calibration"]["heads"]["transition"]
        c.update(support_mask=list(meta["supported"]), class_prior={}, T=[None] * len(meta["supported"]))
    out, _ = _write(tmp_path, _mutated(none_supported))
    rows = load_bundle(out).apply(np.zeros((2, D)))
    assert all("transition" not in r and "posture" in r for r in rows)


@pytest.mark.parametrize("method", ["temperature", "temp_bias", "vector"])
def test_calibration_math(method):
    rng = np.random.default_rng(1)
    z = rng.normal(size=(6, 4))
    T, w, bias = 1.7, rng.uniform(0.5, 2, 4), rng.normal(size=4)
    got = bm.softmax(bm.calibrate(z, method, T=T, weight=w, bias=bias))
    want = softmax({"temperature": z / T, "temp_bias": z / T + bias, "vector": z * w + bias}[method], axis=1)
    assert np.abs(got - want).max() < 1e-12
    Tv = rng.uniform(0.5, 2, 4)
    assert np.abs(bm.sigmoid(bm.calibrate(z, "temperature_per_event", T=Tv)) - expit(z / Tv)).max() < 1e-12


def test_mlp_matches_torch_reference():
    torch = pytest.importorskip("torch")
    rng = np.random.default_rng(2)
    z = rng.normal(size=(5, D))
    g, b0, W1, b1, W2, b2 = (rng.normal(size=s) for s in ((D,), (D,), (7, D), (7,), (3, 7), (3,)))
    net = torch.nn.Sequential(torch.nn.LayerNorm(D, eps=1e-5), torch.nn.Linear(D, 7), torch.nn.GELU(),
                              torch.nn.Linear(7, 3)).double()
    with torch.no_grad():
        for t, v in zip((net[0].weight, net[0].bias, net[1].weight, net[1].bias, net[3].weight, net[3].bias),
                        (g, b0, W1, b1, W2, b2)):
            t.copy_(torch.from_numpy(v))
        want = net(torch.from_numpy(z)).numpy()
    assert np.abs(bm.mlp_logits(z, g, b0, W1, b1, W2, b2) - want).max() < 1e-10


def test_ood_scores_match_sklearn():
    pytest.importorskip("sklearn")
    from sklearn.covariance import LedoitWolf
    from sklearn.neighbors import NearestNeighbors
    rng = np.random.default_rng(3)
    ref = rng.normal(size=(200, D))
    q = np.concatenate([rng.normal(size=(20, D)), rng.normal(3.0, 1.0, size=(20, D))])
    # kNN on L2-normalised vectors, reference stored float16
    u = (ref / np.linalg.norm(ref, axis=1, keepdims=True)).astype(np.float16)
    qn = (q / np.linalg.norm(q, axis=1, keepdims=True)).astype(np.float32)
    nn = NearestNeighbors(n_neighbors=5).fit(u.astype(np.float32))
    want = nn.kneighbors(qn)[0][:, 4]
    assert np.abs(bm.ood_knn(q, u, 5) - want).max() < 1e-4
    lw = LedoitWolf().fit(ref)
    P = lw.precision_
    assert np.abs(bm.ood_maha_global(q, lw.location_, P) - np.sqrt(lw.mahalanobis(q))).max() < 1e-8
    means = np.stack([ref[:100].mean(0), ref[100:].mean(0)])
    per_class = []
    for m in means:
        lw.location_ = m
        per_class.append(np.sqrt(lw.mahalanobis(q)))
    assert np.abs(bm.ood_maha_min(q, means, P) - np.min(per_class, axis=0)).max() < 1e-8
    logits = rng.normal(size=(7, 5))
    assert np.abs(bm.ood_energy(logits) + logsumexp(logits, axis=1)).max() < 1e-12
    assert bm.ood_maha_global(q[20:], lw.location_, P).mean() > bm.ood_maha_global(q[:20], lw.location_, P).mean()


@pytest.mark.parametrize("ood", ["knn", "maha_min", "maha_global", "energy"])
def test_nonfinite_rows_flagged_others_untouched(tmp_path, ood):
    out, _ = _write(tmp_path, _parts(ood))
    b = load_bundle(out)
    emb = np.random.default_rng(4).normal(size=(4, D))
    clean = b.apply(emb)
    emb[1, 3] = np.nan
    emb[2, 0] = 1e300                                       # finite input; distance OOD scores overflow
    emb[3, 5] = -np.inf
    rows = b.apply(emb)
    assert rows[1] == {"nonfinite": True} and rows[3] == {"nonfinite": True}
    if ood == "energy":                                     # softmax / logsumexp stay finite: kept, one-hot
        assert np.isfinite(rows[2]["ood_score"]) and max(rows[2]["posture"].values()) == 1.0
    else:
        assert rows[2] == {"nonfinite": True}
    assert rows[0] == clean[0]
    with pytest.raises(ValueError):
        b.apply(np.zeros((2, D + 1)))
