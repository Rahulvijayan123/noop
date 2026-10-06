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
``encoder.json``, ``evaluation.json``/``.md``, ...) are listed in ``files`` and verified like the rest.

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

from . import (CALIBRATION_SCHEMA, CLASSIFIER_HEADS, HEADS_SCHEMA, MULTILABEL_HEADS, OOD_SCHEMA)
from . import bundle_math as bm
from .bundle_schema import (REQUIRED_FILES, BundleError, supported_classes, validate_all,
                            validate_manifest)
from .contract import sha256_bytes

_RESERVED = set(REQUIRED_FILES) | {"manifest.json"}
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
            meta = self.manifest["heads"][h]
            heads[h] = {"class_order": list(meta["class_order"]), "prior": dict(meta["prior"]),
                        "status": dict(meta["status"]), "tau": dict(meta["tau"]),
                        "merge_into": dict(meta.get("merge_into", {})),
                        "covers": {k: list(v) for k, v in meta.get("covers", {}).items()}}
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
    return HeadBundle(path=os.path.abspath(bundle_dir), manifest=manifest, calibration=cal, ood_meta=ood_meta,
                      heads_arrays=heads, ood_arrays=ood_arrays,
                      bundle_sha256=compute_bundle_sha256(manifest["files"], manifest_bytes))


__all__ = ["write_bundle", "load_bundle", "HeadBundle", "HeadOutputs", "BundleError", "compute_bundle_sha256",
           "encoder_block", "json_bytes", "npz_bytes"]
