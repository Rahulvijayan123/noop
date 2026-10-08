"""HART adapter: load the official pretrained checkpoint into the upstream
TSPulseForClassification head and serve deterministic per-window predictions.

Lazy/optional import: torch / transformers / granite-tsfm are imported only
when HARTModel is actually used, so the baseline pipeline and all tests run
without any of them installed (C7: baseline + tests run without torch).

Load contract (hart-repro report s4/s7, upstream finetune.py:297-327):
  TSPulseForClassification.from_pretrained(checkpoint, ignore_mismatched_sizes=True)
  with overrides:
    num_input_channels=6, num_targets=<num WISDM classes>, loss="cross_entropy",
    head_reduce_d_model=1, head_aggregation_dim="patch", head_aggregation=None,
    head_gated_attention_activation="softmax",
    disable_mask_in_classification_eval=True, fft_time_consistent_masking=True,
    decoder_mode="common_channel"

Verify-on-load (spec s12 model operation gate): EXACTLY the 8 linear-head
tensors may be newly initialized and zero shape mismatches are allowed;
every overlapping tensor must load bit-identical. Any other new/mismatched
tensor raises ModelError (never silently hidden, never accepted).

Freeze policy (upstream finetune.py:121-130): whole backbone frozen;
time_encoding + fft_encoding unfrozen; decoder_with_head trainable.
Applied on load for training; inference runs eval mode regardless.

Scaler: the saved training StandardScaler (fit on train subjects/sessions
only, per hart-repro s3) is applied per window before the model, exactly like
the deployed rpi preprocess_window.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Set, Tuple

import numpy as np

from .manifest import Manifest
from .model_names import WISDM_ACTIVITY_NAMES
from .preprocess import N_CHANNELS, WINDOW_SAMPLES

# The complete linear classification head (hart-repro s7.1, 8 tensors / 3,463
# params) — the only tensors the 1ch-pretrained checkpoint does not contain.
EXPECTED_NEW_HEAD_TENSORS: Set[str] = {
    "decoder_with_head.head.head_norm.norm.bias",
    "decoder_with_head.head.head_norm.norm.weight",
    "decoder_with_head.head.loc_scale_norm.bias",
    "decoder_with_head.head.loc_scale_norm.weight",
    "decoder_with_head.head.projection.bias",
    "decoder_with_head.head.projection.weight",
    "decoder_with_head.head.reduce_proj.bias",
    "decoder_with_head.head.reduce_proj.weight",
}


class ModelError(RuntimeError):
    """Model cannot be loaded/used; message is safe to surface (serve kind)."""


def torch_available() -> bool:
    try:
        import torch  # noqa: F401
        return True
    except Exception:
        return False


def _import_torch():
    try:
        import torch
        return torch
    except Exception as exc:  # pragma: no cover - env-dependent
        raise ModelError(
            f"torch not importable ({exc}); install the [model] extra "
            "(torch==2.8.0, transformers==4.56.0, granite-tsfm==0.3.3)") from exc


def _file_sha256(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _load_model_and_verify(checkpoint_dir: str, num_classes: int,
                           manifest_seed: int = 0, manifest=None):
    """from_pretrained with upstream overrides + strict verify-on-load.

    Returns (model, torch, checkpoint_sha256). Raises ModelError unless exactly
    the expected head tensors are newly initialized with zero shape
    mismatches, all overlapping tensors are bit-identical to the checkpoint,
    and (when a manifest is given) the checkpoint sha256 matches the pinned
    digest. The digest is measured from the file every time, pinned or not:
    it is what the serve process reports as loaded.
    """
    torch = _import_torch()
    try:
        from safetensors.torch import load_file
        # Upstream import (HART finetune.py:37); granite-tsfm 0.3.x ships
        # tsfm_public; older layouts used granite_tsfm.hfam.
        try:
            from tsfm_public.models.tspulse import TSPulseForClassification
        except ImportError:
            from granite_tsfm.hfam import TSPulseForClassification
    except Exception as exc:
        raise ModelError(
            f"granite-tsfm/transformers not importable ({exc}); install the "
            "[model] extra") from exc

    safetensors = os.path.join(checkpoint_dir, "model.safetensors")
    if not os.path.isfile(safetensors):
        raise ModelError(f"checkpoint file missing: {safetensors}")
    actual = _file_sha256(safetensors)
    if manifest is not None:
        files = (manifest.checkpoint or {}).get("files", {})
        info = files.get("model.safetensors")
        expected = (info or {}).get("sha256") if isinstance(info, dict) else None
        if expected and actual != expected:
            raise ModelError(
                "checkpoint corrupt: model.safetensors sha256 mismatch "
                f"({actual[:16]}... != {expected[:16]}...)")

    # Upstream config overrides, finetuning_HART/finetune.py:300-316. mask_ratio
    # and channel_virtual_expand_scale matter: they decide whether the
    # reconstruction decoder is instantiated at all (they are already present in
    # the checkpoint config, but upstream passes them explicitly — keep parity).
    overrides = dict(
        head_gated_attention_activation="softmax",
        channel_virtual_expand_scale=1,
        mask_ratio=0.3,
        head_reduce_d_model=1,
        disable_mask_in_classification_eval=True,
        fft_time_consistent_masking=True,
        decoder_mode="common_channel",
        head_aggregation_dim="patch",
        head_aggregation=None,
        num_input_channels=N_CHANNELS,
        num_targets=num_classes,
        loss="cross_entropy",
        ignore_mismatched_sizes=True,
    )
    try:
        model = TSPulseForClassification.from_pretrained(
            checkpoint_dir, **overrides)
    except Exception as exc:
        raise ModelError(f"TSPulseForClassification.from_pretrained failed: {exc}") from exc

    ckpt = load_file(safetensors)
    model_sd = model.state_dict()
    ckpt_keys = set(ckpt.keys())
    model_keys = set(model_sd.keys())

    # Tensors the model has that the checkpoint does not. Two legitimate
    # checkpoints exist for this adapter:
    #   * the PRETRAINED reconstruction checkpoint (no head) -> exactly the 8
    #     linear-head tensors are newly initialized (hart-repro s7.1);
    #   * a FINE-TUNED classification checkpoint (head saved) -> zero new.
    # Anything else is silent architecture drift and must refuse to load.
    new_tensors = model_keys - ckpt_keys
    shape_mismatch = {k for k in (ckpt_keys & model_keys)
                      if tuple(ckpt[k].shape) != tuple(model_sd[k].shape)}
    fine_tuned = "decoder_with_head.head.projection.weight" in ckpt_keys
    expected_new = set() if fine_tuned else EXPECTED_NEW_HEAD_TENSORS
    if new_tensors != expected_new:
        extra = sorted(new_tensors - expected_new)
        absent = sorted(expected_new - new_tensors)
        kind = "fine-tuned" if fine_tuned else "pretrained"
        raise ModelError(
            "checkpoint verification failed: expected EXACTLY "
            f"{len(expected_new)} new tensors for a {kind} checkpoint, got "
            f"unexpected new tensors {extra} and/or missing {absent}")
    if shape_mismatch:
        raise ModelError(
            "checkpoint verification failed: shape mismatches on "
            f"{sorted(shape_mismatch)} — nothing may be silently resized")

    # Checkpoint tensors the classification model does not instantiate are the
    # reconstruction decoder (loss=ce + classification head): must all live
    # under decoder_with_head. and never under backbone/.
    unused = ckpt_keys - model_keys
    bad_unused = [k for k in sorted(unused) if not k.startswith("decoder_with_head.")]
    if bad_unused:
        raise ModelError(
            "checkpoint tensors unexpectedly unused by the classification model: "
            f"{bad_unused[:5]}")

    # Every overlapping tensor must be bit-identical (nothing silently resized).
    for k in sorted(ckpt_keys & model_keys):
        if not torch.equal(model_sd[k].to(torch.float32),
                           ckpt[k].to(torch.float32)):
            raise ModelError(f"checkpoint tensor {k} did not load bit-identical")

    model.eval()
    model = model.to("cpu")
    torch.set_num_threads(1)
    torch.manual_seed(manifest_seed)
    return model, torch, actual


def apply_freeze_policy(model, torch) -> Dict[str, int]:
    """Freeze the backbone; keep time_encoding, fft_encoding and the head
    trainable (upstream finetune.py:121-130). Returns param counts."""
    frozen = trainable = 0
    for name, p in model.named_parameters():
        if name.startswith("backbone.") and "time_encoding" not in name \
                and "fft_encoding" not in name:
            p.requires_grad = False
            frozen += int(p.numel())
        else:
            p.requires_grad = True
            trainable += int(p.numel())
    return {"frozen": frozen, "trainable": trainable}


@dataclass
class Prediction:
    """Per-window prediction in ontology terms (spec s8)."""
    label: str
    probs: Dict[str, float]        # ontology labels incl. "unknown"
    logits: Optional[np.ndarray]   # raw WISDM-class logits (18,) when HART
    baseline: bool
    # A01 calibration provenance: true only when the manifest carries a
    # versioned calibration artifact (never from model_kind/baseline).
    calibrated: bool = False
    # Full per-activity softmax keyed by WISDM_ACTIVITY_NAMES (FINE_SCHEMA); None when
    # the head is not the 18-letter WISDM head.
    fine_probs: Optional[Dict[str, float]] = None


def abstain(probs: Dict[str, float], max_prob: float, margin: float) -> str:
    """Spec s8 abstention: accept only when max class prob >= max_prob and
    the top-2 margin >= margin; otherwise 'unknown'."""
    order = sorted(probs.items(), key=lambda kv: kv[1], reverse=True)
    if len(order) < 2:
        return "unknown"
    p1, p2 = order[0][1], order[1][1]
    if p1 >= max_prob and (p1 - p2) >= margin:
        return order[0][0]
    return "unknown"


class HARTModel:
    """Loaded HART classifier; deterministic eval-mode per-window inference."""

    def __init__(self, manifest: Manifest, checkpoint_dir: str):
        if manifest.model_kind != "hart":
            raise ModelError(f"manifest model_kind={manifest.model_kind!r} is not 'hart'")
        self.manifest = manifest
        self.checkpoint_dir = checkpoint_dir
        num_classes = len(manifest.class_map)
        self.model, self.torch, self.checkpoint_sha256 = _load_model_and_verify(
            checkpoint_dir, num_classes, manifest.seed, manifest=manifest)
        # from_pretrained read the architecture from config.json beside the weights: part of what was loaded.
        config = os.path.join(checkpoint_dir, "config.json")
        self.config_sha256: Optional[str] = _file_sha256(config) if os.path.isfile(config) else None
        self.class_ids = list(manifest.class_map)          # WISDM letters 0..17
        sc = manifest.scaler
        self.mean = np.asarray(sc["mean"], dtype=np.float64)
        self.scale = np.asarray(sc["scale"], dtype=np.float64)
        self.fine_names: Optional[List[str]] = (
            [WISDM_ACTIVITY_NAMES[c] for c in self.class_ids]
            if self.class_ids and all(c in WISDM_ACTIVITY_NAMES for c in self.class_ids) else None)

    @staticmethod
    def _softmax(logits: np.ndarray) -> np.ndarray:
        softmax = np.exp(logits - logits.max())
        return softmax / softmax.sum()

    def _fine_probs(self, logits: np.ndarray) -> Optional[Dict[str, float]]:
        if self.fine_names is None or len(self.fine_names) != logits.shape[0]:
            return None
        softmax = self._softmax(logits)
        return {name: float(softmax[i]) for i, name in enumerate(self.fine_names)}

    def _ontology_probs(self, logits: np.ndarray) -> Dict[str, float]:
        softmax = self._softmax(logits)
        probs: Dict[str, float] = {}
        for cid, wisdm_label in enumerate(self.class_ids):
            onto = self.manifest.label_mapping.get(wisdm_label, "other_movement")
            probs[onto] = probs.get(onto, 0.0) + float(softmax[cid])
        return probs

    @staticmethod
    def _logits(out) -> np.ndarray:
        """Extract the (1, num_classes) logits from a forward output."""
        for attr in ("prediction_outputs", "logits"):
            if hasattr(out, attr) and getattr(out, attr) is not None:
                return np.asarray(getattr(out, attr).detach().cpu().numpy()).reshape(-1)
        raise ModelError("model forward returned no logits")

    def predict_window(self, window: np.ndarray) -> Prediction:
        """One 120x6 window (canonical g/deg/s) -> Prediction.

        Applies the saved scaler, runs eval-mode with no_grad, aggregates the
        WISDM-class softmax into ontology probabilities, then abstains.
        Deterministic: single thread, fixed seed, eval, no masking.
        """
        torch = self.torch
        if window.shape != (WINDOW_SAMPLES, N_CHANNELS):
            raise ModelError(f"window must be ({WINDOW_SAMPLES}, {N_CHANNELS}), got {window.shape}")
        if not np.isfinite(window).all():
            # No model output exists for this window: uncalibrated by definition.
            return Prediction("unknown", {"unknown": 1.0}, None, baseline=False, calibrated=False)
        x = (window - self.mean) / self.scale
        t = torch.from_numpy(np.asarray(x, dtype=np.float32)).unsqueeze(0)
        with torch.no_grad():
            out = self.model(past_values=t, return_loss=False)
        logits = self._logits(out)
        probs = self._ontology_probs(logits)
        th = self.manifest.thresholds
        label = abstain(probs, float(th["max_prob"]), float(th["margin"]))
        # calibrated comes from the manifest's calibration artifact, never from
        # model_kind: with no fitted artifact today this is always False.
        return Prediction(label=label, probs=probs,
                          logits=logits, baseline=False,
                          calibrated=self.manifest.calibrated,
                          fine_probs=self._fine_probs(logits))

    def close(self) -> None:
        self.model = None
