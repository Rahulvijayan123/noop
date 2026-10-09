"""ActiNet encoder: the ssl-wearables harnet30 feature extractor behind the ``inertia-prep-1`` input contract.

ActiNet (https://github.com/OxWearables/actinet) fine-tunes the self-supervised harnet30 ResNet
(https://github.com/OxWearables/ssl-wearables, UK Biobank pretraining) on Capture-24. Its 1024-d feature
extractor output is a frozen window embedding; the motion heads are trained on top exactly as for any other
encoder (INERTIA1.md §4b). Two pinned weight files:

``actinet/harnet30-c24-mw/30s@20hz``   ActiNet's ``ssl-ukb-c24-mw-30s-20260128`` classifier backbone
    (fine-tuned on ALL Capture-24 participants: Capture-24 test numbers are in-sample for this encoder).
``actinet/harnet30-ssl-ukb/30s@20hz``  the self-supervised backbone only (``mtl_30_best.mdl``, no labels).

Input: the contract's ``float32 [B, 3, 600]`` (g, gravity kept, 20 Hz). The network was trained on 30 Hz,
900-sample windows, so each window is upsampled with ``scipy.signal.resample_poly(up=3, down=2)`` inside
``embed``; nothing else in the lane changes rate. Weights: a plain ``{name: tensor}`` state_dict produced by
:func:`convert` from the upstream files, size + sha256 verified BEFORE ``torch.load(weights_only=True)``,
strict key/shape/dtype/finite checks, ``eval()``, frozen, fp32. ``device`` defaults to CPU (serving);
``mps``/``cuda`` are for offline embedding only and are not part of the encoder identity.
"""

from __future__ import annotations

import os
from typing import Any, Dict, Mapping, Optional

import numpy as np

from . import ACTINET_ENCODER_PREFIX
from .contract import EncoderInfo, InertiaUnavailable, make_info, sha256_file, validate_batch

ENV_CKPT = "ACTINET_CKPT_PATH"
DEFAULT_MAX_BATCH = 64
WINDOW_S = 30
UP, DOWN = 3, 2
UPSTREAM_SSL = "https://github.com/OxWearables/ssl-wearables@v1.0.0"
UPSTREAM_ACTINET = "https://github.com/OxWearables/actinet"

C24_ID = "actinet/harnet30-c24-mw/30s@20hz"
UKB_ID = "actinet/harnet30-ssl-ukb/30s@20hz"

WEIGHTS: Dict[str, Dict[str, Any]] = {
    C24_ID: {
        "file": "actinet-harnet30-c24-mw-20260128.pt",
        "sha256": "46732ff250087277072d056f64cfc27c62614948b6d76c127b16dff66af77ba5",
        "size": 41966554,
        "source": "actinet ssl-ukb-c24-mw-30s-20260128.joblib.lzma (model.feature_extractor)",
        "source_sha256": "9034d6c944f6af005b1387c0774e559ae24722d367366c843669d6375cf24b4a",
        "source_url": "https://wearables-files.ndph.ox.ac.uk/files/models/actinet/ssl-ukb-c24-mw-30s-20260128.joblib.lzma",
        "training_note": "fine-tuned on all Capture-24 participants (Capture-24 test is in-sample)",
    },
    UKB_ID: {
        "file": "ssl-wearables-harnet30-ukb-v1.0.0.pt",
        "sha256": "28f8bcd719735496588eefb7f80c83209576aca3068fa61e9eae9874278e73f8",
        "size": 41966691,
        "source": "ssl-wearables v1.0.0 model_check_point/mtl_30_best.mdl (feature_extractor)",
        "source_sha256": "885a4e3aa1cb3af241900c1ad7fb65b41336d7e592231d99fe6302ad4a9d5a6d",
        "source_url": "https://github.com/OxWearables/ssl-wearables/archive/refs/tags/v1.0.0.zip",
        "training_note": "self-supervised on UK Biobank only (no activity labels)",
    },
}


def _torch():
    try:
        import torch
    except ImportError as exc:  # pragma: no cover - exercised only without the [inertia] extra
        raise InertiaUnavailable("model_missing", "torch is not installed (install the [inertia] extra)") from exc
    return torch


def encoder_config(encoder_id: str) -> Dict[str, Any]:
    w = WEIGHTS[encoder_id]
    return {"family": "ssl-wearables-harnet30", "weights_file": w["file"], "weights_source": w["source"],
            "weights_source_sha256": w["source_sha256"], "window_s": WINDOW_S, "input_rate_hz": 20,
            "network_rate_hz": 30, "resample": f"scipy.signal.resample_poly(up={UP}, down={DOWN}, axis=-1)",
            "extraction_point": "feature_extractor output [B, 1024, 1] flattened", "upstream": UPSTREAM_SSL}


def resolve_checkpoint(encoder_id: str, ckpt_path: Optional[str]) -> str:
    """A weights file path, or a directory holding the pinned file name; falls back to $ACTINET_CKPT_PATH."""
    path = ckpt_path or os.environ.get(ENV_CKPT)
    if not path:
        raise InertiaUnavailable("model_missing", f"{encoder_id} needs its weights (--checkpoint / ${ENV_CKPT})")
    if os.path.isdir(path):
        path = os.path.join(path, WEIGHTS[encoder_id]["file"])
    if not os.path.isfile(path):
        raise InertiaUnavailable("model_missing", f"ActiNet weights not found: {path}")
    return path


class ActiNetEncoder:
    """Frozen harnet30 feature extractor; ``embed`` float32 [B, 3, 600] @ 20 Hz -> float32 [B, 1024]."""

    def __init__(self, encoder_id: str, ckpt_path: Optional[str] = None, window_s: int = WINDOW_S,
                 threads: Optional[int] = 1, max_batch: int = DEFAULT_MAX_BATCH, device: str = "cpu",
                 expected_preprocessing: Optional[Mapping[str, Any]] = None):
        if encoder_id not in WEIGHTS:
            raise InertiaUnavailable("config_mismatch", f"unknown ActiNet encoder {encoder_id!r}; known {sorted(WEIGHTS)}")
        if int(window_s) != WINDOW_S:
            raise InertiaUnavailable("config_mismatch", f"{encoder_id} is a {WINDOW_S}s encoder, not {window_s}s")
        if expected_preprocessing is not None and int(expected_preprocessing.get("window_s", WINDOW_S)) != WINDOW_S:
            raise InertiaUnavailable("config_mismatch", "bundle preprocessing window_s != 30")
        w = WEIGHTS[encoder_id]
        path = resolve_checkpoint(encoder_id, ckpt_path)
        size = os.path.getsize(path)
        if size != w["size"]:
            raise InertiaUnavailable("checkpoint_mismatch", f"{os.path.basename(path)}: size {size} != pinned {w['size']}")
        digest = sha256_file(path)
        if digest != w["sha256"]:
            raise InertiaUnavailable("checkpoint_mismatch", f"{os.path.basename(path)}: sha256 {digest[:12]}… != "
                                     f"pinned {w['sha256'][:12]}…")
        torch = _torch()
        from .vendor.ssl_wearables_resnet import HARNET30_DIM, harnet30_feature_extractor
        try:
            state = torch.load(path, map_location="cpu", weights_only=True)
        except Exception as exc:  # noqa: BLE001
            raise InertiaUnavailable("checkpoint_mismatch", f"unloadable weights: {type(exc).__name__}: {exc}") from exc
        module = harnet30_feature_extractor()
        want = module.state_dict()
        if not isinstance(state, Mapping) or set(state) != set(want):
            raise InertiaUnavailable("config_mismatch", "weights keys differ from the harnet30 feature extractor")
        for k, v in state.items():
            if not isinstance(v, torch.Tensor) or tuple(v.shape) != tuple(want[k].shape) or v.dtype != want[k].dtype:
                raise InertiaUnavailable("config_mismatch", f"{k}: tensor shape/dtype differs from harnet30")
            if v.is_floating_point() and not bool(torch.isfinite(v).all()):
                raise InertiaUnavailable("config_mismatch", f"{k}: nonfinite weights")
        module.load_state_dict(state, strict=True)
        if threads is not None:
            torch.set_num_threads(int(threads))
        module.eval()
        module.requires_grad_(False)
        self._torch = torch
        self._device = torch.device(device)
        self._module = module.to(self._device)
        self.max_batch = int(max_batch)
        self._info = make_info(encoder_id=encoder_id, kind="actinet", config=encoder_config(encoder_id),
                               embedding_dim=HARNET30_DIM, window_s=WINDOW_S,
                               extraction_point="harnet30.feature_extractor", checkpoint_sha256=digest,
                               upstream_commit="ssl-wearables@v1.0.0")

    @property
    def info(self) -> EncoderInfo:
        return self._info

    def embed(self, batch: np.ndarray) -> np.ndarray:
        from scipy.signal import resample_poly
        batch = validate_batch(batch, self._info.input_contract)
        out = np.empty((batch.shape[0], self._info.embedding_dim), dtype=np.float32)
        from ..loaded import no_nnpack
        # NNPACK off, as ElderNet runs: ~24x faster on one CPU thread, embeddings within 5e-6 (activity-authority.md).
        with self._torch.inference_mode(), no_nnpack():
            for i in range(0, batch.shape[0], self.max_batch):
                x30 = resample_poly(batch[i:i + self.max_batch].astype(np.float64), UP, DOWN, axis=-1)
                x = self._torch.from_numpy(np.ascontiguousarray(x30, dtype=np.float32)).to(self._device)
                out[i:i + self.max_batch] = self._module(x).reshape(x.shape[0], -1).cpu().numpy()
        return out


def convert(source: str, out_path: str, kind: str) -> Dict[str, Any]:
    """Write a pinned-format weights file from an upstream artifact (offline; needs the upstream packages).

    ``kind="actinet"``: an ActiNet ``*.joblib.lzma`` classifier (needs ``actinet`` installed);
    ``kind="ssl"``: ssl-wearables ``mtl_30_best.mdl`` (DataParallel keys ``module.feature_extractor.*``)."""
    torch = _torch()
    from .vendor.ssl_wearables_resnet import harnet30_feature_extractor
    if kind == "actinet":
        import joblib
        clf = joblib.load(source)
        if getattr(clf, "model", None) is None:
            clf.load_model()
        sd = clf.model.feature_extractor.state_dict()
    elif kind == "ssl":
        raw = torch.load(source, map_location="cpu")
        sd = {".".join(k.split(".")[2:]): v for k, v in raw.items() if k.split(".")[1:2] == ["feature_extractor"]}
    else:
        raise ValueError(f"unknown kind {kind!r}")
    fe = harnet30_feature_extractor()
    fe.load_state_dict(sd, strict=True)
    torch.save({k: v.detach().clone().contiguous() for k, v in fe.state_dict().items()}, out_path)
    return {"file": os.path.basename(out_path), "sha256": sha256_file(out_path), "size": os.path.getsize(out_path),
            "source_sha256": sha256_file(source)}


def is_actinet_id(encoder_id: str) -> bool:
    return isinstance(encoder_id, str) and encoder_id.startswith(ACTINET_ENCODER_PREFIX)


if __name__ == "__main__":  # pragma: no cover - offline artifact tool
    import argparse
    import json
    p = argparse.ArgumentParser(description="convert upstream ActiNet / ssl-wearables weights to the pinned format")
    p.add_argument("source")
    p.add_argument("out")
    p.add_argument("--kind", choices=("actinet", "ssl"), required=True)
    a = p.parse_args()
    print(json.dumps(convert(a.source, a.out, a.kind)))
