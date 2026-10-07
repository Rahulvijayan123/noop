"""Validators for the head-bundle documents (manifest / heads.npz / calibration / OOD reference).

Used by both ``bundle.write_bundle`` (refuse to write an invalid bundle) and ``bundle.load_bundle``
(refuse to load one). Every failure is a :class:`BundleError` whose ``kind`` maps onto the serve error
kinds: ``model_missing`` (no bundle), ``checkpoint_mismatch`` (bytes differ from the recorded sha256),
``config_mismatch`` (anything structurally wrong). Key names are documented in ``bundle.py``.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Sequence

import numpy as np

from . import (ALL_HEADS, ALLOWED_HOP_S, ALLOWED_WINDOW_S, BUNDLE_TIERS, CALIBRATION_SCHEMA, CLASSIFIER_HEADS,
               HEAD_CLASS_ORDERS, HEADS_SCHEMA, INERTIA_AXES, INERTIA_RATE_HZ, MULTILABEL_HEADS, OOD_SCHEMA,
               PREPROCESSING_VERSION, PINNED_ENCODER_PREFIXES, SOFTMAX_HEADS, STANDIN_PREFIX,
               TEST_GATE_SCHEMA)
from .bundle_math import MULTILABEL_CALIBRATION_METHODS, OOD_METHODS, SOFTMAX_CALIBRATION_METHODS
from .contract import is_sha256_hex

REQUIRED_FILES = ("heads.npz", "calibration.json", "ood_reference.npz", "ood_reference.json")
# Provenance a candidate/production bundle must carry (spec §20, §26.12), plus the one-shot test gate.
PROVENANCE_FILES = ("label_mappings.json", "split_manifest.json")
TEST_GATE_FILE = "test_gate.json"
SEAL_KEYS = ("evaluated_bundle_sha256", "test_gate_sha256", "test_sha256")
# Optional seal key: a shadow bundle of a pinned encoder (inertia1 / actinet) built from a clean tree is promoted
# to ``candidate`` when sealed; ``promoted_from`` records the tier the evaluated (pre-seal) manifest carried.
SEAL_PROMOTED_FROM = "promoted_from"
HEAD_ARCHS = ("linear", "mlp")
CLASS_STATUSES = ("strong", "weak", "abstain")
_ARCH_KEYS = {"linear": ("W", "b"), "mlp": ("ln_g", "ln_b", "W1", "b1", "W2", "b2")}
_OOD_ARRAYS = {"maha_min": ("mu", "sigma", "class_means", "precision"),
               "maha_global": ("mu", "sigma", "mean", "precision"),
               "knn": ("mu", "sigma", "reference"), "energy": ()}


class BundleError(ValueError):
    """A head bundle cannot be written or loaded. ``kind`` is a serve error kind."""

    def __init__(self, kind: str, message: str):
        assert kind in ("model_missing", "checkpoint_mismatch", "config_mismatch")
        super().__init__(f"{kind}: {message}")
        self.kind = kind
        self.message = message


def _bad(msg: str) -> BundleError:
    return BundleError("config_mismatch", msg)


def _finite(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(float(x))


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise _bad(msg)


def supported_classes(head_meta: Mapping[str, Any]) -> List[str]:
    return [c for c, s in zip(head_meta["class_order"], head_meta["supported"]) if s]


# ---------------------------------------------------------------------------
# manifest.json
# ---------------------------------------------------------------------------

def validate_manifest(m: Mapping[str, Any]) -> None:
    _require(isinstance(m, Mapping), "manifest must be an object")
    _require(m.get("schema") == HEADS_SCHEMA, f"manifest.schema must be {HEADS_SCHEMA!r}")
    _require(isinstance(m.get("bundle_id"), str) and m["bundle_id"], "manifest.bundle_id must be a string")
    tier = m.get("evidence_tier_max")
    _require(tier in BUNDLE_TIERS, f"evidence_tier_max must be one of {BUNDLE_TIERS}")
    _validate_encoder_block(m.get("encoder"), tier)
    _validate_preprocessing(m.get("preprocessing"))
    heads = m.get("heads")
    _require(isinstance(heads, Mapping) and heads, "manifest.heads must be a non-empty object")
    for name, meta in heads.items():
        _require(name in ALL_HEADS, f"unknown head {name!r} (allowed: {ALL_HEADS})")
        if name in CLASSIFIER_HEADS:
            _validate_classifier_head(name, meta)
        else:
            _require(isinstance(meta, Mapping) and meta.get("arch") in HEAD_ARCHS,
                     f"{name}.arch must be one of {HEAD_ARCHS}")
            _require(meta.get("output") == "sigmoid", f"{name}.output must be 'sigmoid'")
            if "interval80" in meta:
                _require(_finite(meta["interval80"]) and meta["interval80"] >= 0, f"{name}.interval80 invalid")
    ood = m.get("ood")
    _require(isinstance(ood, Mapping) and ood.get("method") in OOD_METHODS and _finite(ood.get("threshold")),
             "manifest.ood must carry method and a finite threshold")
    files = m.get("files")
    _require(isinstance(files, Mapping), "manifest.files must be an object {name: sha256}")
    for name, digest in files.items():
        _require(isinstance(name, str) and name and "/" not in name and "\\" not in name
                 and name not in (".", "..", "manifest.json"), f"invalid bundle file name {name!r}")
        _require(is_sha256_hex(digest), f"files[{name!r}] must be a sha256 hex digest")
    for name in REQUIRED_FILES:
        _require(name in files, f"bundle is missing required file {name}")
    if tier in ("candidate", "production"):
        for name in PROVENANCE_FILES:
            _require(name in files, f"a {tier} bundle must carry {name}")
        _require(TEST_GATE_FILE in files and isinstance(m.get("seal"), Mapping),
                 f"a {tier} bundle must be sealed (test_gate.json from the one-shot test evaluation)")
    seal = m.get("seal")
    _require((seal is None) == (TEST_GATE_FILE not in files),
             "manifest.seal and files['test_gate.json'] must be present together")
    if seal is not None:
        promoted = isinstance(seal, Mapping) and SEAL_PROMOTED_FROM in seal
        _require(not promoted or (seal[SEAL_PROMOTED_FROM] == "shadow" and tier == "candidate"),
                 "manifest.seal.promoted_from must be 'shadow' on a candidate bundle")
        _require(isinstance(seal, Mapping) and set(seal) - {SEAL_PROMOTED_FROM} == set(SEAL_KEYS)
                 and all(is_sha256_hex(seal[k]) for k in SEAL_KEYS)
                 and seal["test_gate_sha256"] == files[TEST_GATE_FILE],
                 f"manifest.seal must be {{{', '.join(SEAL_KEYS)}}} (sha256 hex) matching files['test_gate.json']")


def _validate_encoder_block(enc: Any, tier: str) -> None:
    _require(isinstance(enc, Mapping), "manifest.encoder must be an object")
    eid = enc.get("encoder_id")
    _require(isinstance(eid, str) and eid.startswith(PINNED_ENCODER_PREFIXES + (STANDIN_PREFIX,)),
             "manifest.encoder.encoder_id must start with 'inertia-1/', 'actinet/' or 'standin:'")
    _require(isinstance(enc.get("embedding_dim"), int) and not isinstance(enc.get("embedding_dim"), bool)
             and enc["embedding_dim"] >= 1, "manifest.encoder.embedding_dim must be a positive int")
    for key in ("checkpoint_sha256", "config_sha256"):
        v = enc.get(key)
        _require(v is None or is_sha256_hex(v), f"manifest.encoder.{key} must be sha256 hex or null")
    if tier in ("candidate", "production"):
        _require(eid.startswith(PINNED_ENCODER_PREFIXES) and enc.get("checkpoint_sha256") is not None,
                 f"a {tier} bundle needs a pinned inertia-1 / actinet encoder with a checkpoint sha256")


def _validate_preprocessing(p: Any) -> None:
    _require(isinstance(p, Mapping), "manifest.preprocessing must be an object")
    _require(p.get("version") == PREPROCESSING_VERSION, f"preprocessing.version must be {PREPROCESSING_VERSION!r}")
    _require(p.get("window_s") in ALLOWED_WINDOW_S, f"preprocessing.window_s must be one of {ALLOWED_WINDOW_S}")
    _require(p.get("hop_s") in ALLOWED_HOP_S and p["hop_s"] <= p["window_s"],
             f"preprocessing.hop_s must be one of {ALLOWED_HOP_S} and <= window_s")
    _require(p.get("rate_hz") == INERTIA_RATE_HZ, f"preprocessing.rate_hz must be {INERTIA_RATE_HZ}")
    _require(list(p.get("axes") or []) == list(INERTIA_AXES), f"preprocessing.axes must be {list(INERTIA_AXES)}")
    _require(p.get("units") == "g", "preprocessing.units must be 'g'")


def _validate_classifier_head(name: str, meta: Any) -> None:
    _require(isinstance(meta, Mapping), f"heads.{name} must be an object")
    _require(meta.get("arch") in HEAD_ARCHS, f"heads.{name}.arch must be one of {HEAD_ARCHS}")
    order = list(HEAD_CLASS_ORDERS[name])
    _require(list(meta.get("class_order") or []) == order, f"heads.{name}.class_order must equal {order}")
    sup = meta.get("supported")
    _require(isinstance(sup, list) and len(sup) == len(order) and all(isinstance(s, bool) for s in sup),
             f"heads.{name}.supported must be {len(order)} booleans aligned with class_order")
    # Zero supported classes is legal: the head is then omitted from every window (INERTIA1.md §6).
    sup_classes = [c for c, s in zip(order, sup) if s]
    for key in ("prior", "status", "tau"):
        d = meta.get(key)
        _require(isinstance(d, Mapping) and sorted(d) == sorted(sup_classes),
                 f"heads.{name}.{key} must have exactly the supported classes as keys")
    for c in sup_classes:
        _require(_finite(meta["prior"][c]) and 0.0 <= meta["prior"][c] <= 1.0, f"heads.{name}.prior[{c}] not in [0,1]")
        _require(_finite(meta["tau"][c]) and 0.0 <= meta["tau"][c] <= 1.0, f"heads.{name}.tau[{c}] not in [0,1]")
        _require(meta["status"][c] in CLASS_STATUSES, f"heads.{name}.status[{c}] must be one of {CLASS_STATUSES}")
    validate_merge(name, meta.get("merge_into", {}), meta["status"], sup_classes)
    if "decoder_evidence" in meta:
        live = [c for c in sup_classes if meta["status"][c] in ("strong", "weak")]
        _require(meta["decoder_evidence"] is (len(live) > 1) if name in SOFTMAX_HEADS else isinstance(meta["decoder_evidence"], bool),
                 f"heads.{name}.decoder_evidence must be true iff the head has > 1 strong/weak class")
    _validate_covers(name, meta.get("covers", {}), order, sup_classes)
    fams = meta.get("families", {})
    _require(isinstance(fams, Mapping), f"heads.{name}.families must be an object")
    for key, fam in fams.items():
        _require(isinstance(fam, Mapping) and isinstance(fam.get("members"), list) and len(fam["members"]) > 1
                 and all(c in sup_classes for c in fam["members"]),
                 f"heads.{name}.families[{key!r}].members must list > 1 supported classes")
        _require(fam.get("status") in CLASS_STATUSES and _finite(fam.get("tau")) and 0.0 <= fam["tau"] <= 1.0,
                 f"heads.{name}.families[{key!r}] needs a status in {CLASS_STATUSES} and a tau in [0,1]")


def validate_merge(name: str, merge: Any, status: Mapping[str, str], sup_classes: Sequence[str]) -> None:
    """merge_into: abstained supported class -> strong/weak partner inside abstention.MERGE_COMPAT."""
    from .abstention import MERGE_COMPAT
    _require(isinstance(merge, Mapping), f"heads.{name}.merge_into must be an object")
    compat = MERGE_COMPAT.get(name, {})
    for src, dst in merge.items():
        _require(src in sup_classes and status[src] == "abstain",
                 f"heads.{name}.merge_into key {src!r} must be a supported abstained class")
        _require(dst in sup_classes and dst != src and status[dst] in ("strong", "weak"),
                 f"heads.{name}.merge_into[{src!r}] must be a supported strong/weak class")
        _require(dst in compat.get(src, ()),
                 f"heads.{name}.merge_into[{src!r}] = {dst!r} is outside the semantic-compatibility table "
                 f"(allowed: {list(compat.get(src, ()))})")


def _validate_covers(name: str, covers: Any, order: Sequence[str], sup_classes: Sequence[str]) -> None:
    """``covers {supported class: [itself, absorbed unsupported classes...]}`` (set targets)."""
    _require(isinstance(covers, Mapping), f"heads.{name}.covers must be an object")
    absorbed: Dict[str, str] = {}
    for cls, covered in covers.items():
        _require(cls in sup_classes, f"heads.{name}.covers key {cls!r} must be a supported class")
        _require(isinstance(covered, list) and cls in covered and len(set(covered)) == len(covered),
                 f"heads.{name}.covers[{cls!r}] must be a duplicate-free list that includes {cls!r}")
        for c in covered:
            if c == cls:
                continue
            _require(c in order and c not in sup_classes,
                     f"heads.{name}.covers[{cls!r}] may only absorb unsupported classes of this head ({c!r})")
            _require(c not in absorbed, f"heads.{name}: {c!r} is covered by both {absorbed.get(c)!r} and {cls!r}")
            absorbed[c] = cls


# ---------------------------------------------------------------------------
# heads.npz
# ---------------------------------------------------------------------------

def head_array_keys(manifest: Mapping[str, Any]) -> List[str]:
    keys = ["std.mu", "std.sigma"]
    for name, meta in manifest["heads"].items():
        keys += [f"{name}.{k}" for k in _ARCH_KEYS[meta["arch"]]]
    return sorted(keys)


def validate_heads_arrays(manifest: Mapping[str, Any], arrays: Mapping[str, np.ndarray]) -> None:
    want = head_array_keys(manifest)
    _require(sorted(arrays) == want, f"heads.npz keys must be exactly {want}, got {sorted(arrays)}")
    D = manifest["encoder"]["embedding_dim"]
    for key, arr in arrays.items():
        _require(isinstance(arr, np.ndarray) and arr.dtype.kind == "f", f"heads.npz[{key}] must be a float array")
        _require(bool(np.isfinite(arr).all()), f"heads.npz[{key}] contains nonfinite values")
    _require(arrays["std.mu"].shape == (D,) and arrays["std.sigma"].shape == (D,), f"std.mu/std.sigma must be [{D}]")
    _require(bool((arrays["std.sigma"] > 0).all()), "std.sigma must be > 0")
    for name, meta in manifest["heads"].items():
        K = len(HEAD_CLASS_ORDERS[name]) if name in CLASSIFIER_HEADS else 1
        a = {k: arrays[f"{name}.{k}"] for k in _ARCH_KEYS[meta["arch"]]}
        if meta["arch"] == "linear":
            _require(a["W"].shape == (K, D) and a["b"].shape == (K,), f"{name}: W must be [{K},{D}], b [{K}]")
        else:
            H = a["W1"].shape[0] if a["W1"].ndim == 2 else -1
            _require(a["ln_g"].shape == (D,) and a["ln_b"].shape == (D,), f"{name}: ln_g/ln_b must be [{D}]")
            _require(H >= 1 and a["W1"].shape == (H, D) and a["b1"].shape == (H,), f"{name}: W1 [H,{D}], b1 [H]")
            _require(a["W2"].shape == (K, H) and a["b2"].shape == (K,), f"{name}: W2 must be [{K},{H}], b2 [{K}]")


# ---------------------------------------------------------------------------
# calibration.json
# ---------------------------------------------------------------------------

def _vec(v: Any, K: int, sup: Sequence[bool], what: str) -> None:
    _require(isinstance(v, list) and len(v) == K, f"{what} must be a list of {K} numbers")
    for x, s in zip(v, sup):
        _require(_finite(x) if s else (x is None or _finite(x)), f"{what} has a nonfinite supported entry")


def validate_calibration(manifest: Mapping[str, Any], cal: Mapping[str, Any]) -> None:
    _require(isinstance(cal, Mapping) and cal.get("schema") == CALIBRATION_SCHEMA,
             f"calibration.schema must be {CALIBRATION_SCHEMA!r}")
    heads = cal.get("heads")
    _require(isinstance(heads, Mapping), "calibration.heads must be an object")
    want = sorted(h for h in manifest["heads"] if h in CLASSIFIER_HEADS)
    got = sorted(h for h in heads if h in CLASSIFIER_HEADS)
    _require(got == want, f"calibration must cover exactly the classifier heads {want}, got {got}")
    for name, c in heads.items():
        _require(name in manifest["heads"], f"calibration for unknown head {name!r}")
        if name not in CLASSIFIER_HEADS:
            _require(isinstance(c, Mapping) and c.get("method") == "none", f"{name} calibration must be method 'none'")
            continue
        meta = manifest["heads"][name]
        K, sup = len(meta["class_order"]), meta["supported"]
        methods = MULTILABEL_CALIBRATION_METHODS if name in MULTILABEL_HEADS else SOFTMAX_CALIBRATION_METHODS
        _require(isinstance(c, Mapping) and c.get("method") in methods,
                 f"calibration.{name}.method must be one of {methods}")
        _require(list(c.get("class_order") or []) == list(meta["class_order"]),
                 f"calibration.{name}.class_order differs from the manifest")
        _require(list(c.get("support_mask") or []) == list(sup), f"calibration.{name}.support_mask differs from manifest")
        fit = c.get("fit")
        _require(isinstance(fit, Mapping) and fit.get("split") == "val", f"calibration.{name}.fit.split must be 'val'")
        if c["method"] in ("temperature", "temp_bias"):
            _require(_t_ok(c.get("T")), f"calibration.{name}.T must be in (0, 1000]")
        if c["method"] == "temperature_per_event":
            _vec(c.get("T"), K, sup, f"calibration.{name}.T")
            _require(all(_t_ok(t) for t, s in zip(c["T"], sup) if s),
                     f"calibration.{name}.T must be in (0, 1000] for every supported event")
        if c["method"] in ("temp_bias", "vector"):
            _vec(c.get("bias"), K, sup, f"calibration.{name}.bias")
        if c["method"] == "vector":
            _vec(c.get("weight"), K, sup, f"calibration.{name}.weight")
            _require(all(float(w) > 0 for w, s in zip(c["weight"], sup) if s),
                     f"calibration.{name}.weight must be > 0 on supported classes")
        prior = c.get("class_prior")
        sup_classes = supported_classes(meta)
        _require(isinstance(prior, Mapping) and sorted(prior) == sorted(sup_classes)
                 and all(_finite(prior[k]) and 0.0 <= prior[k] <= 1.0 for k in sup_classes),
                 f"calibration.{name}.class_prior must map each supported class to [0,1]")


def _t_ok(t: Any) -> bool:
    return _finite(t) and 0.0 < float(t) <= 1e3


# ---------------------------------------------------------------------------
# ood_reference.json / .npz
# ---------------------------------------------------------------------------

def validate_ood(manifest: Mapping[str, Any], meta: Mapping[str, Any], arrays: Mapping[str, np.ndarray]) -> None:
    _require(isinstance(meta, Mapping) and meta.get("schema") == OOD_SCHEMA, f"ood_reference.schema must be {OOD_SCHEMA!r}")
    method = meta.get("method")
    _require(method in OOD_METHODS, f"ood method must be one of {OOD_METHODS}")
    _require(_finite(meta.get("threshold")), "ood threshold must be finite")
    if method != "energy":
        _require(float(meta["threshold"]) >= 0.0, "a distance threshold must be >= 0")
    fit = meta.get("fit")
    _require(isinstance(fit, Mapping) and fit.get("split") == "val", "ood_reference.fit.split must be 'val'")
    for k, v in (meta.get("thresholds") or {}).items():
        _require(_finite(v), f"ood thresholds[{k!r}] must be finite")
    want = sorted(_OOD_ARRAYS[method])
    _require(sorted(arrays) == want, f"ood_reference.npz keys for {method} must be exactly {want}")
    D = manifest["encoder"]["embedding_dim"]
    for key, arr in arrays.items():
        _require(arr.dtype.kind == "f" and bool(np.isfinite(arr).all()), f"ood_reference.npz[{key}] must be finite float")
    if method != "energy":
        _require(arrays["mu"].shape == (D,) and arrays["sigma"].shape == (D,) and bool((arrays["sigma"] > 0).all()),
                 f"ood mu/sigma must be [{D}] with sigma > 0")
    if method in ("maha_min", "maha_global"):
        _require(arrays["precision"].shape == (D, D), f"ood precision must be [{D},{D}]")
        if method == "maha_min":
            cm = arrays["class_means"]
            _require(cm.ndim == 2 and cm.shape[1] == D and cm.shape[0] >= 1, f"ood class_means must be [C,{D}]")
        else:
            _require(arrays["mean"].shape == (D,), f"ood mean must be [{D}]")
    if method == "knn":
        ref = arrays["reference"]
        _require(ref.dtype == np.float16 and ref.ndim == 2 and ref.shape[1] == D, f"ood reference must be float16 [N,{D}]")
        k = meta.get("k")
        _require(isinstance(k, int) and not isinstance(k, bool) and 1 <= k <= ref.shape[0], "ood k must be in [1, N]")
    if method == "energy":
        head = meta.get("head")
        _require(head in manifest["heads"] and head in SOFTMAX_HEADS and any(manifest["heads"][head]["supported"]),
                 "energy OOD needs 'head' naming a softmax head of this bundle with supported classes")
    mood = manifest["ood"]
    for key in ("method", "threshold", "k", "head"):
        if key in meta or key in mood:
            _require(mood.get(key) == meta.get(key), f"manifest.ood.{key} differs from ood_reference.json")


# ---------------------------------------------------------------------------
# test_gate.json (the seal of the one-shot test evaluation)
# ---------------------------------------------------------------------------

def validate_test_gate(manifest: Mapping[str, Any], gate: Any) -> None:
    """The gate file may only DEMOTE: per class val_status equals the manifest status, final_status <= it;
    merges are recomputed for the final statuses (compatibility table, live partners)."""
    from .abstention import STATUS_RANK
    _require(isinstance(gate, Mapping) and gate.get("schema") == TEST_GATE_SCHEMA,
             f"test_gate.schema must be {TEST_GATE_SCHEMA!r}")
    seal = manifest["seal"]
    for k in ("evaluated_bundle_sha256", "test_sha256"):
        _require(gate.get(k) == seal[k], f"test_gate.{k} differs from manifest.seal.{k}")
    _require(gate.get("bundle_id") == manifest["bundle_id"], "test_gate.bundle_id differs from the manifest")
    heads = gate.get("heads")
    _require(isinstance(heads, Mapping), "test_gate.heads must be an object")
    for h, meta in manifest["heads"].items():
        if h not in CLASSIFIER_HEADS or not isinstance(meta.get("status"), Mapping):
            continue
        g = heads.get(h)
        _require(isinstance(g, Mapping) and isinstance(g.get("classes"), Mapping),
                 f"test_gate.heads.{h} missing (every classifier head of a sealed bundle is gated)")
        sup = supported_classes(meta)
        _require(sorted(g["classes"]) == sorted(sup), f"test_gate.heads.{h}.classes must be exactly the supported classes")
        final = {}
        for c in sup:
            e = g["classes"][c]
            _require(isinstance(e, Mapping) and e.get("val_status") == meta["status"][c],
                     f"test_gate.heads.{h}.{c}.val_status differs from the manifest (gate file not from this bundle)")
            fs = e.get("final_status")
            _require(fs in CLASS_STATUSES, f"test_gate.heads.{h}.{c}.final_status must be one of {CLASS_STATUSES}")
            _require(STATUS_RANK[fs] <= STATUS_RANK[meta["status"][c]],
                     f"test_gate.heads.{h}.{c}: final_status {fs!r} would PROMOTE val status "
                     f"{meta['status'][c]!r}; the gate only demotes (refused)")
            final[c] = fs
        for key, fam in (g.get("families") or {}).items():
            _require(isinstance(fam, Mapping) and isinstance(fam.get("members"), list) and len(fam["members"]) > 1
                     and all(c in sup for c in fam["members"]),
                     f"test_gate.heads.{h}.families[{key!r}] must list > 1 supported classes of the head")
            vs, fs = fam.get("val_status"), fam.get("final_status")
            _require(vs in CLASS_STATUSES and fs in CLASS_STATUSES and STATUS_RANK[fs] <= STATUS_RANK[vs],
                     f"test_gate.heads.{h}.families[{key!r}]: final_status must not promote the VAL family status")
        merge = g.get("merge_into", {})
        if h in MULTILABEL_HEADS:
            _require(merge == {}, f"test_gate.heads.{h}.merge_into must be empty for a multi-label head")
        else:
            validate_merge(h, merge, final, sup)
            live = [c for c in sup if final[c] in ("strong", "weak")]
            _require(g.get("decoder_evidence") is (len(live) > 1),
                     f"test_gate.heads.{h}.decoder_evidence must be true iff > 1 strong/weak class after the gate")


def validate_all(manifest: Mapping[str, Any], heads: Mapping[str, np.ndarray], cal: Mapping[str, Any],
                 ood_meta: Mapping[str, Any], ood_arrays: Mapping[str, np.ndarray]) -> None:
    validate_manifest(manifest)
    validate_heads_arrays(manifest, heads)
    validate_calibration(manifest, cal)
    validate_ood(manifest, ood_meta, ood_arrays)


__all__ = ["BundleError", "REQUIRED_FILES", "PROVENANCE_FILES", "TEST_GATE_FILE", "SEAL_KEYS", "SEAL_PROMOTED_FROM", "HEAD_ARCHS",
           "CLASS_STATUSES", "supported_classes", "head_array_keys", "validate_manifest", "validate_heads_arrays",
           "validate_calibration", "validate_ood", "validate_merge", "validate_test_gate", "validate_all"]
