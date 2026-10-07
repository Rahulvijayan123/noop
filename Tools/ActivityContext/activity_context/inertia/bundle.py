"""Head bundles (``nara.inertia.heads/1``): the single serialization authority (INERTIA1.md §5).

Training code writes bundles only through :func:`write_bundle`; the serve process reads them only through
:func:`load_bundle`. Both run the same validators (``bundle_schema``), so a bundle that loads is a bundle
that was written by the rules, and any byte change to a listed file refuses to load.

Bundle file keys
----------------
``manifest.json``  ``schema`` "nara.inertia.heads/1", ``bundle_id`` (= wire ``heads_version``),
    ``evidence_tier_max`` shadow|candidate|production,
    ``encoder`` {``encoder_id``, ``embedding_dim``, ``checkpoint_sha256``|null, ``config_sha256``|null, ...},
    ``preprocessing`` {``version`` "inertia-prep-1", ``window_s``, ``hop_s`` (default), ``rate_hz`` 20,
    ``axes`` [ax,ay,az], ``units`` "g", ...},
    ``heads`` {<head>: {``arch`` linear|mlp, ``class_order``, ``supported`` [bool, aligned],
    ``prior``/``status``/``tau`` {supported class: value}, ``merge_into`` {abstained: partner},
    ``covers`` {supported class: [itself, absorbed unsupported...]}, ``support_counts``, ``selection``};
    ``movement_intensity``: {``arch``, ``output`` "sigmoid", ``interval80``}},
    ``ood`` {``method``, ``threshold``, ``k``?, ``head``?} (filled from ood_meta), ``training`` {...},
    ``files`` {name: sha256} (filled by write_bundle; every file except manifest.json).
``heads.npz``  ``std.mu`` [D], ``std.sigma`` [D]; linear ``<head>.W`` [K,D], ``<head>.b`` [K]; mlp
    ``<head>.ln_g`` [D], ``<head>.ln_b`` [D], ``<head>.W1`` [H,D], ``<head>.b1`` [H], ``<head>.W2`` [K,H],
    ``<head>.b2`` [K]. K = len(class_order) (all classes, supported or not); movement_intensity K = 1.
``calibration.json``  ``schema`` "nara.inertia.calibration/1", ``heads`` {<head>: {``method``,
    ``class_order``, ``support_mask``, ``class_prior`` {supported: p}, ``fit`` {``split`` "val", ...},
    ``selection``?}}. Softmax heads: ``temperature`` (``T``), ``temp_bias`` (``T``, ``bias`` [K]) or
    ``vector`` (``weight`` [K] > 0, ``bias`` [K]); ``transition``: ``temperature_per_event`` (``T`` [K]).
    Per-class vectors are aligned with class_order; unsupported entries may be null.
    ``movement_intensity`` may appear with ``method`` "none".
``ood_reference.json``  ``schema`` "nara.inertia.ood/1", ``method`` maha_min|maha_global|knn|energy,
    ``threshold``, ``thresholds``? {name: value}, ``k`` (knn), ``head`` (energy), ``fit`` {``split`` "val"},
    ``content_sha256`` (sha256 of ood_reference.npz; filled by write_bundle).
``ood_reference.npz``  maha_min: ``mu``, ``sigma`` [D], ``class_means`` [C,D], ``precision`` [D,D];
    maha_global: ``mu``, ``sigma``, ``mean`` [D], ``precision``; knn: ``mu``, ``sigma``, ``reference`` float16
    [N,D] (L2-normalised z-scored embeddings); energy: no arrays.
Extra files (``label_mappings.json``, ``split_manifest.json`` — required for candidate/production —,
``encoder.json``, ...) are listed in ``files`` and verified like the rest.
``test_gate.json`` (``nara.inertia.test_gate/1``, written ONLY by :func:`seal_bundle` after the one-shot test
    evaluation): per head/class ``val_status``, ``tau``, the pooled and per-dataset test gates,
    ``final_status`` (= min of VAL status and every gate level; demotions only), ``reasons``; per head the
    ``merge_into`` and ``decoder_evidence`` recomputed for the final statuses; ``evaluated_bundle_sha256``
    (the pre-seal bundle hash the test evaluation was stamped with), ``test_sha256`` and the ledger entry.
    Sealing adds it to ``files`` and adds ``manifest.seal`` {evaluated_bundle_sha256, test_gate_sha256,
    test_sha256}; :func:`load_bundle` recomputes the pre-seal hash (manifest without ``seal`` and the gate
    entry, canonical JSON) and refuses a gate that was not made for exactly that bundle or that promotes.
    ``HeadBundle.wire_block`` serves the FINAL statuses/merges. Candidate/production bundles must be sealed.

``bundle_sha256`` = sha256 over, for each (name, sha256) in sorted(manifest.files): ``name 0x00 sha256
0x0A``, then ``"manifest.json" 0x00`` followed by the exact manifest.json bytes.

npz files are written deterministically (sorted keys, stored, fixed 1980-01-01 timestamps); JSON files are
``sort_keys`` / ``indent=2`` / UTF-8 / NaN refused, newline-terminated.
"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import zipfile
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Union

import numpy as np

from . import (CALIBRATION_SCHEMA, CLASSIFIER_HEADS, HEADS_SCHEMA, MULTILABEL_HEADS, OOD_SCHEMA, SOFTMAX_HEADS,
               TEST_GATE_SCHEMA)
from . import bundle_math as bm
from .bundle_schema import (REQUIRED_FILES, TEST_GATE_FILE, BundleError, supported_classes, validate_all,
                            validate_manifest, validate_test_gate)
from .contract import sha256_bytes

_RESERVED = set(REQUIRED_FILES) | {"manifest.json", TEST_GATE_FILE}
_ZIP_DATE = (1980, 1, 1, 0, 0, 0)


# ---------------------------------------------------------------------------
# Deterministic encoders
# ---------------------------------------------------------------------------

def _json_default(o: Any) -> Any:
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return float(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    raise TypeError(f"not JSON serializable: {type(o).__name__}")


def json_bytes(obj: Any) -> bytes:
    """The canonical on-disk JSON form used for every bundle JSON file."""
    return (json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False,
                       default=_json_default) + "\n").encode("utf-8")


def npz_bytes(arrays: Mapping[str, np.ndarray]) -> bytes:
    """Deterministic .npz bytes (np.load-compatible): sorted keys, ZIP_STORED, fixed timestamps."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
        for key in sorted(arrays):
            info = zipfile.ZipInfo(f"{key}.npy", date_time=_ZIP_DATE)
            info.external_attr = 0o644 << 16
            arr_buf = io.BytesIO()
            np.lib.format.write_array(arr_buf, np.ascontiguousarray(arrays[key]), allow_pickle=False)
            zf.writestr(info, arr_buf.getvalue())
    return buf.getvalue()


def _load_npz(data: bytes, what: str) -> Dict[str, np.ndarray]:
    try:
        with np.load(io.BytesIO(data), allow_pickle=False) as z:
            return {k: z[k] for k in z.files}
    except Exception as exc:  # noqa: BLE001 - any parse failure is a bad bundle
        raise BundleError("config_mismatch", f"{what} is not a readable npz: {exc}") from exc


def compute_bundle_sha256(files: Mapping[str, str], manifest_bytes: bytes) -> str:
    h = hashlib.sha256()
    for name in sorted(files):
        h.update(name.encode("utf-8") + b"\x00" + files[name].encode("ascii") + b"\n")
    h.update(b"manifest.json\x00")
    h.update(manifest_bytes)
    return h.hexdigest()


def encoder_block(info: Any) -> Dict[str, Any]:
    """``manifest.encoder`` for heads trained on ``info`` (a contract.EncoderInfo). The serve process
    refuses a bundle whose encoder_id / embedding_dim / checkpoint_sha256 / config_sha256 differ."""
    return {"encoder_id": info.encoder_id, "encoder_kind": info.kind, "encoder_version": info.encoder_version,
            "embedding_dim": int(info.embedding_dim), "checkpoint_sha256": info.checkpoint_sha256,
            "config_sha256": info.config_sha256, "upstream_commit": info.upstream_commit,
            "extraction_point": info.extraction_point, "input_contract": info.input_contract.to_dict()}


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

def write_bundle(out_dir: str, *, manifest: Mapping[str, Any], heads_arrays: Mapping[str, np.ndarray],
                 calibration: Mapping[str, Any], ood_arrays: Mapping[str, np.ndarray],
                 ood_meta: Mapping[str, Any], extra_files: Optional[Mapping[str, Union[bytes, str]]] = None,
                 ) -> str:
    """Validate and write a head bundle into a new (or empty) ``out_dir``; return its bundle_sha256.

    ``schema`` strings, ``files``, ``ood_reference.json.content_sha256`` and ``manifest.ood`` are filled in
    here. Raises BundleError (invalid content) or FileExistsError (non-empty out_dir)."""
    if os.path.isdir(out_dir) and os.listdir(out_dir):
        raise FileExistsError(f"bundle directory is not empty: {out_dir}")
    m = copy.deepcopy(dict(manifest))
    m.setdefault("schema", HEADS_SCHEMA)
    cal = copy.deepcopy(dict(calibration))
    cal.setdefault("schema", CALIBRATION_SCHEMA)
    om = copy.deepcopy(dict(ood_meta))
    om.setdefault("schema", OOD_SCHEMA)
    heads = {str(k): np.asarray(v) for k, v in heads_arrays.items()}
    ood_a = {str(k): np.asarray(v) for k, v in ood_arrays.items()}

    blobs: Dict[str, bytes] = {"heads.npz": npz_bytes(heads), "ood_reference.npz": npz_bytes(ood_a)}
    om["content_sha256"] = sha256_bytes(blobs["ood_reference.npz"])
    blobs["ood_reference.json"] = json_bytes(om)
    blobs["calibration.json"] = json_bytes(cal)
    for name, data in sorted((extra_files or {}).items()):
        if name in _RESERVED or not name or "/" in name or "\\" in name or name.startswith("."):
            raise BundleError("config_mismatch", f"invalid or reserved extra file name {name!r}")
        blobs[name] = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    ood_block = dict(m.get("ood") or {})
    for key in ("method", "threshold", "k", "head"):
        if key in om:
            ood_block[key] = om[key]
    m["ood"] = ood_block
    m["files"] = {name: sha256_bytes(b) for name, b in sorted(blobs.items())}
    validate_all(m, heads, cal, om, ood_a)

    os.makedirs(out_dir, exist_ok=True)
    for name, data in blobs.items():
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(data)
    with open(os.path.join(out_dir, "manifest.json"), "wb") as f:
        f.write(json_bytes(m))
    return load_bundle(out_dir).bundle_sha256


# ---------------------------------------------------------------------------
# Load + apply
# ---------------------------------------------------------------------------

@dataclass
class HeadOutputs:
    """Array form of ``HeadBundle.apply``. Columns of ``probs[h]`` follow ``supported_classes(h)``."""
    probs: Dict[str, np.ndarray]
    raw_logits: Dict[str, np.ndarray]           # [B, K] full class order, unsupported = -inf
    movement_intensity: Optional[np.ndarray]    # [B] or None when the bundle has no such head
    ood_score: np.ndarray                       # [B]
    is_ood: np.ndarray                          # [B] bool
    valid: np.ndarray                           # [B] bool: finite embedding and finite outputs


@dataclass
class HeadBundle:
    path: str
    manifest: Dict[str, Any]
    calibration: Dict[str, Any]
    ood_meta: Dict[str, Any]
    heads_arrays: Dict[str, np.ndarray] = field(repr=False)
    ood_arrays: Dict[str, np.ndarray] = field(repr=False)
    bundle_sha256: str = ""
    test_gate: Optional[Dict[str, Any]] = None      # parsed test_gate.json of a sealed bundle

    @property
    def sealed(self) -> bool:
        return self.test_gate is not None

    def effective_head(self, head: str) -> Dict[str, Any]:
        """The head entry as served: FINAL statuses and merges of a sealed bundle (the VAL ones otherwise)."""
        meta = dict(self.manifest["heads"][head])
        g = (self.test_gate or {}).get("heads", {}).get(head)
        if g is not None:
            meta["status"] = {c: e["final_status"] for c, e in g["classes"].items()}
            meta["merge_into"] = dict(g.get("merge_into", {}))
            if "decoder_evidence" in g:
                meta["decoder_evidence"] = g["decoder_evidence"]
        if head in SOFTMAX_HEADS:
            live = [c for c, st in meta["status"].items() if st in ("strong", "weak")]
            meta["decoder_evidence"] = len(live) > 1
        return meta

    @property
    def bundle_id(self) -> str:
        return self.manifest["bundle_id"]

    @property
    def embedding_dim(self) -> int:
        return int(self.manifest["encoder"]["embedding_dim"])

    @property
    def evidence_tier_max(self) -> str:
        return self.manifest["evidence_tier_max"]

    @property
    def encoder(self) -> Dict[str, Any]:
        return self.manifest["encoder"]

    @property
    def preprocessing(self) -> Dict[str, Any]:
        return self.manifest["preprocessing"]

    def heads_present(self) -> List[str]:
        return [h for h in CLASSIFIER_HEADS if h in self.manifest["heads"]]

    def supported_classes(self, head: str) -> List[str]:
        return supported_classes(self.manifest["heads"][head])

    def wire_block(self) -> Dict[str, Any]:
        """The ``bundle`` object of the motion-heads-1 infer response (INERTIA1.md §6)."""
        heads = {}
        for h in self.heads_present():
            meta = self.effective_head(h)
            heads[h] = {"class_order": list(meta["class_order"]), "prior": dict(meta["prior"]),
                        "status": dict(meta["status"]), "tau": dict(meta["tau"]),
                        "merge_into": dict(meta.get("merge_into", {})),
                        "covers": {k: list(v) for k, v in meta.get("covers", {}).items()}}
            if h in SOFTMAX_HEADS:
                # false = <= 1 evidence group after merging/dropping abstained classes: the decoder's
                # likelihood ratio is then identically 1 (inert head); carried so consumers can say so.
                heads[h]["decoder_evidence"] = bool(meta["decoder_evidence"])
        return {"heads": heads, "ood": {"method": self.ood_meta["method"],
                                        "threshold": float(self.ood_meta["threshold"])}}

    def _logits(self, head: str, z: np.ndarray) -> np.ndarray:
        a, arch = self.heads_arrays, self.manifest["heads"][head]["arch"]
        if arch == "linear":
            return bm.linear_logits(z, a[f"{head}.W"], a[f"{head}.b"])
        return bm.mlp_logits(z, *(a[f"{head}.{k}"] for k in ("ln_g", "ln_b", "W1", "b1", "W2", "b2")))

    def _ood(self, emb: np.ndarray, raw: Dict[str, np.ndarray]) -> np.ndarray:
        method, a = self.ood_meta["method"], self.ood_arrays
        if method == "energy":
            head = self.ood_meta["head"]
            idx = self._sup_idx(head)
            return bm.ood_energy(raw[head][:, idx])
        z = bm.standardize(emb, a["mu"], a["sigma"])
        if method == "maha_min":
            return bm.ood_maha_min(z, a["class_means"], a["precision"])
        if method == "maha_global":
            return bm.ood_maha_global(z, a["mean"], a["precision"])
        return bm.ood_knn(z, a["reference"], int(self.ood_meta["k"]))

    def _sup_idx(self, head: str) -> List[int]:
        return [i for i, s in enumerate(self.manifest["heads"][head]["supported"]) if s]

    def apply_arrays(self, emb: np.ndarray) -> HeadOutputs:
        emb = np.asarray(emb)
        if emb.ndim != 2 or emb.shape[1] != self.embedding_dim:
            raise ValueError(f"embeddings must be [B, {self.embedding_dim}], got {list(emb.shape)}")
        valid = np.isfinite(emb).all(axis=1)
        e = np.where(valid[:, None], emb.astype(np.float64), 0.0)
        probs: Dict[str, np.ndarray] = {}
        raw: Dict[str, np.ndarray] = {}
        mi = None
        with np.errstate(all="ignore"):
            z = bm.standardize(e, self.heads_arrays["std.mu"], self.heads_arrays["std.sigma"])
            for h in self.heads_present():
                logits = self._logits(h, z)
                idx = self._sup_idx(h)
                full = np.full_like(logits, -np.inf)
                full[:, idx] = logits[:, idx]
                raw[h] = full
                if not idx:
                    continue                                  # no supported class: omitted
                sup, cal = logits[:, idx], self.calibration["heads"][h]
                if h in MULTILABEL_HEADS:
                    T = np.array([cal["T"][i] for i in idx], dtype=np.float64)
                    p = bm.sigmoid(bm.calibrate(sup, "temperature_per_event", T=T))
                else:
                    vec = lambda key: None if cal.get(key) is None else np.array(  # noqa: E731
                        [cal[key][i] for i in idx], dtype=np.float64)
                    p = bm.softmax(bm.calibrate(sup, cal["method"], T=cal.get("T"),
                                                weight=vec("weight"), bias=vec("bias")))
                probs[h] = p
                valid &= np.isfinite(sup).all(axis=1) & np.isfinite(p).all(axis=1)
            if "movement_intensity" in self.manifest["heads"]:
                mi = bm.sigmoid(self._logits("movement_intensity", z)[:, 0])
                valid &= np.isfinite(mi)
            score = self._ood(e, raw)
            valid &= np.isfinite(score)
        is_ood = score > float(self.ood_meta["threshold"])
        return HeadOutputs(probs=probs, raw_logits=raw, movement_intensity=mi, ood_score=score,
                           is_ood=is_ood, valid=valid)

    def apply(self, emb: np.ndarray) -> List[Dict[str, Any]]:
        """Per-window dicts: ``{<head>: {class: p}, "movement_intensity", "ood_score", "is_ood"}``.

        A row whose embedding or outputs are nonfinite is ``{"nonfinite": True}`` (to be omitted)."""
        out = self.apply_arrays(emb)
        names = {h: self.supported_classes(h) for h in out.probs}
        rows: List[Dict[str, Any]] = []
        for i in range(out.valid.shape[0]):
            if not out.valid[i]:
                rows.append({"nonfinite": True})
                continue
            row: Dict[str, Any] = {h: {c: float(v) for c, v in zip(names[h], out.probs[h][i])} for h in out.probs}
            if out.movement_intensity is not None:
                row["movement_intensity"] = float(out.movement_intensity[i])
            row["ood_score"] = float(out.ood_score[i])
            row["is_ood"] = bool(out.is_ood[i])
            rows.append(row)
        return rows


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def _parse_json(data: bytes, what: str) -> Any:
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BundleError("config_mismatch", f"{what} is not valid JSON: {exc}") from exc


def load_bundle(bundle_dir: str) -> HeadBundle:
    """Load and fully verify a bundle (every listed file's sha256, schemas, class orders, ranges)."""
    if not bundle_dir or not os.path.isdir(bundle_dir):
        raise BundleError("model_missing", f"head bundle directory not found: {bundle_dir}")
    mpath = os.path.join(bundle_dir, "manifest.json")
    if not os.path.isfile(mpath):
        raise BundleError("model_missing", f"bundle has no manifest.json: {bundle_dir}")
    manifest_bytes = _read(mpath)
    manifest = _parse_json(manifest_bytes, "manifest.json")
    validate_manifest(manifest)
    blobs: Dict[str, bytes] = {}
    for name, digest in sorted(manifest["files"].items()):
        p = os.path.join(bundle_dir, name)
        if not os.path.isfile(p):
            raise BundleError("checkpoint_mismatch", f"bundle file listed but missing: {name}")
        data = _read(p)
        if sha256_bytes(data) != digest:
            raise BundleError("checkpoint_mismatch", f"bundle file sha256 mismatch (tampered?): {name}")
        blobs[name] = data
    heads = _load_npz(blobs["heads.npz"], "heads.npz")
    ood_arrays = _load_npz(blobs["ood_reference.npz"], "ood_reference.npz")
    cal = _parse_json(blobs["calibration.json"], "calibration.json")
    ood_meta = _parse_json(blobs["ood_reference.json"], "ood_reference.json")
    validate_all(manifest, heads, cal, ood_meta, ood_arrays)
    if ood_meta.get("content_sha256") != sha256_bytes(blobs["ood_reference.npz"]):
        raise BundleError("checkpoint_mismatch", "ood_reference.json content_sha256 does not match the npz")
    gate = None
    if TEST_GATE_FILE in manifest["files"]:
        gate = _parse_json(blobs[TEST_GATE_FILE], TEST_GATE_FILE)
        if presealed_sha256(manifest) != manifest["seal"]["evaluated_bundle_sha256"]:
            raise BundleError("checkpoint_mismatch", "manifest.seal.evaluated_bundle_sha256 is not the hash of this "
                              "bundle before sealing (the gate was made for a different bundle)")
        validate_test_gate(manifest, gate)
    return HeadBundle(path=os.path.abspath(bundle_dir), manifest=manifest, calibration=cal, ood_meta=ood_meta,
                      heads_arrays=heads, ood_arrays=ood_arrays,
                      bundle_sha256=compute_bundle_sha256(manifest["files"], manifest_bytes), test_gate=gate)


def presealed_sha256(manifest: Mapping[str, Any]) -> str:
    """bundle_sha256 of the bundle before :func:`seal_bundle` (manifest without ``seal``/gate entry)."""
    m = copy.deepcopy(dict(manifest))
    m.pop("seal", None)
    m["files"] = {k: v for k, v in m["files"].items() if k != TEST_GATE_FILE}
    return compute_bundle_sha256(m["files"], json_bytes(m))


def gate_document(bundle: HeadBundle, evaluation: Mapping[str, Any]) -> Dict[str, Any]:
    """test_gate.json content from an evaluate-once report (``evaluate_heads``); merges recomputed."""
    from . import abstention as A
    integ = evaluation.get("integrity") or {}
    heads: Dict[str, Any] = {}
    for h in bundle.heads_present():
        meta = bundle.manifest["heads"][h]
        if not isinstance(meta.get("status"), Mapping):
            continue
        rep = (evaluation.get("heads") or {}).get(h)
        if rep is None:
            raise BundleError("config_mismatch", f"evaluation has no report for head {h}; cannot seal")
        src = rep["gate"] if h in SOFTMAX_HEADS else {e: v["gate"] for e, v in rep["per_event"].items() if v.get("supported")}
        classes: Dict[str, Any] = {}
        for c in supported_classes(meta):
            g = src.get(c)
            if g is None:
                raise BundleError("config_mismatch", f"evaluation has no gate for {h}.{c}; cannot seal")
            classes[c] = {"val_status": g["val_status"], "tau": meta["tau"][c], "pooled": g.get("test"),
                          "per_dataset": g.get("per_dataset", {}), "final_status": g["final_status"],
                          "reasons": list(g.get("reasons", []))}
        final = {c: e["final_status"] for c, e in classes.items()}
        entry: Dict[str, Any] = {"classes": classes}
        fams = {k: {"members": list(v["members"]), "val_status": v["val_status"], "tau": v["tau"],
                    "pooled": v.get("test"), "per_dataset": v.get("per_dataset", {}),
                    "final_status": v["final_status"], "reasons": list(v.get("reasons", []))}
                for k, v in (rep.get("families") or {}).items() if v.get("val_status") is not None}
        if fams:
            entry["families"] = fams            # reported only: never changes a served per-class status
        if h in SOFTMAX_HEADS:
            sym = (meta.get("selection") or {}).get("merge_confusion_val_sym")
            entry["merge_into"] = A.merge_partners(final, list(meta["class_order"]), h, sym)
            groups = A.evidence_groups(final, entry["merge_into"])
            entry["evidence_groups"] = groups
            entry["decoder_evidence"] = len(groups) > 1
        else:
            entry["merge_into"] = {}
        heads[h] = entry
    return {"schema": TEST_GATE_SCHEMA, "bundle_id": bundle.bundle_id, "experiment": evaluation.get("experiment"),
            "evaluated_bundle_sha256": bundle.bundle_sha256, "test_sha256": integ.get("test_sha256"),
            "ledger_entry": dict(integ), "heads": heads,
            "rule": "final_status = min(VAL status, pooled test gate level, every wrist-dataset gate level with "
                    "n_acc >= 30); levels: strong (precision >= .95 [+ CP95 >= .90, recall >= .05 pooled]), weak "
                    "(precision >= .80 or n_acc < 30), else abstain. Demotions only; merges recomputed inside "
                    "abstention.MERGE_COMPAT (locomotion directed specific -> general) for the final statuses. "
                    f"Set targets ({A.SET_RULE}): every gate of a set member uses its single-label evidence; set "
                    "families are gated as one class and reported under 'families'.",
            "status_rule": A.SET_RULE}


def seal_bundle(bundle_dir: str, evaluation: Mapping[str, Any]) -> HeadBundle:
    """Bind the one-shot test gate to the served artifact (G-3): write ``test_gate.json``, list it in
    ``files``, add ``manifest.seal`` and re-write the manifest; returns the re-loaded (verified) bundle.

    Refuses an already-sealed bundle and an evaluation that was not stamped with this bundle's hash."""
    b = load_bundle(bundle_dir)
    if b.sealed:
        raise BundleError("config_mismatch", f"{bundle_dir} is already sealed; retrain to evaluate again")
    integ = evaluation.get("integrity") or {}
    if evaluation.get("bundle_sha256") != b.bundle_sha256 or integ.get("bundle_sha256") != b.bundle_sha256:
        raise BundleError("config_mismatch", "the evaluation was not stamped with this bundle's sha256; refusing to seal")
    if not integ.get("test_sha256"):
        raise BundleError("config_mismatch", "the evaluation carries no test_sha256 (not an evaluate-once report)")
    gate = gate_document(b, evaluation)
    gate_bytes = json_bytes(gate)
    m = copy.deepcopy(b.manifest)
    m["files"] = dict(m["files"], **{TEST_GATE_FILE: sha256_bytes(gate_bytes)})
    m["seal"] = {"evaluated_bundle_sha256": b.bundle_sha256, "test_gate_sha256": m["files"][TEST_GATE_FILE],
                 "test_sha256": gate["test_sha256"]}
    validate_manifest(m)
    validate_test_gate(m, gate)
    with open(os.path.join(bundle_dir, TEST_GATE_FILE), "wb") as f:
        f.write(gate_bytes)
    tmp = os.path.join(bundle_dir, ".manifest.json.tmp")
    with open(tmp, "wb") as f:
        f.write(json_bytes(m))
    os.replace(tmp, os.path.join(bundle_dir, "manifest.json"))
    return load_bundle(bundle_dir)


__all__ = ["write_bundle", "load_bundle", "seal_bundle", "gate_document", "presealed_sha256", "HeadBundle",
           "HeadOutputs", "BundleError", "compute_bundle_sha256", "encoder_block", "json_bytes", "npz_bytes"]
