"""Encoder registry: ``build_encoder(spec)`` and the pinned-checkpoint allowlist.

``PINNED_CHECKPOINTS`` is the only route to ``production_eligible`` / wire ``encoder_kind == "inertia1"``.
It is EMPTY: no official Inertia-1 checkpoint is publicly downloadable (INERTIA1.md header, audited
2026-10-05). Adding one is a reviewed code change, never a runtime option:

1. obtain the official file from the upstream authors (release asset / model card) with its licence;
2. record ``sha256``/size from the downloaded bytes, verify against the authors' published digest, and
   confirm method/preset/window by loading it through ``Inertia1Encoder`` (strict keys, PE/W_pos checks);
3. add ``PINNED_CHECKPOINTS[sha256] = {"encoder_id": "inertia-1/<method>-<preset>/<w>s@20hz",
   "size": ..., "source_url": ..., "license": ..., "verified_by": ..., "verified_on": "YYYY-MM-DD"}``
   plus a test that the encoder_id matches its encoder.json; update INERTIA1.md and NOTICE.md.

Spec strings accepted by :func:`build_encoder`:

* ``standin:handcrafted-stats-v1`` / ``standin:nara-imu-feat-1-accel`` (kw: ``window_s``)
* ``standin:inertia-arch-random-init/<method>-<preset>/seed<k>`` (kw: ``window_s``, ``threads``; or, with
  ``encoder_config`` + ``ckpt_path``, the same id loaded from a fixture checkpoint)
* ``inertia-1/<method>-<preset>/<w>s@20hz`` (kw: ``encoder_config`` required, ``ckpt_path`` or
  ``$INERTIA1_CKPT_PATH``)
* a path to an ``encoder.json`` (kw: ``ckpt_path``)
"""

from __future__ import annotations

import os
from typing import Any, Dict

from . import REAL_ENCODER_PREFIX
from .contract import Encoder, InertiaUnavailable

PINNED_CHECKPOINTS: Dict[str, Dict[str, Any]] = {}

_ARCH_PREFIX = "standin:inertia-arch-random-init/"


def build_encoder(spec: str, **kw: Any) -> Encoder:
    """Build an encoder from a spec string (see module docstring). Failures are InertiaUnavailable."""
    from .standins import HANDCRAFTED_ID, IMU_FEAT_ID, HandcraftedStatsEncoder, ImuFeatAccelEncoder

    window_s = int(kw.get("window_s", 30))
    if spec == HANDCRAFTED_ID:
        return HandcraftedStatsEncoder(window_s=window_s)
    if spec == IMU_FEAT_ID:
        return ImuFeatAccelEncoder(window_s=window_s)
    loader_kw = {k: kw[k] for k in ("threads", "expected_preprocessing", "max_batch") if k in kw}
    if isinstance(spec, str) and spec.endswith(".json") and os.path.isfile(spec):
        from .adapter import Inertia1Encoder
        return Inertia1Encoder(kw.get("ckpt_path"), spec, **loader_kw)
    if isinstance(spec, str) and (spec.startswith(REAL_ENCODER_PREFIX) or spec.startswith(_ARCH_PREFIX)):
        from .adapter import Inertia1Encoder, RandomInitArchEncoder
        from .encoder_config import EncoderConfigError, parse_arch_id
        cfg = kw.get("encoder_config")
        if cfg is None:
            if spec.startswith(REAL_ENCODER_PREFIX):
                raise InertiaUnavailable("model_missing", f"{spec} needs its encoder.json and checkpoint")
            try:
                method, preset, _w, seed = parse_arch_id(spec)
                return RandomInitArchEncoder(method, preset, seed, window_s=window_s,
                                             **{k: v for k, v in loader_kw.items() if k != "expected_preprocessing"})
            except EncoderConfigError as exc:
                raise InertiaUnavailable("config_mismatch", str(exc)) from exc
        enc = Inertia1Encoder(kw.get("ckpt_path"), cfg, **loader_kw)
        if enc.info.encoder_id != spec:
            raise InertiaUnavailable("config_mismatch", f"encoder.json describes {enc.info.encoder_id}, not {spec}")
        return enc
    raise InertiaUnavailable("config_mismatch", f"unknown encoder spec {spec!r}")


def is_pinned(checkpoint_sha256: str, encoder_id: str) -> bool:
    entry = PINNED_CHECKPOINTS.get(checkpoint_sha256)
    return bool(entry) and entry.get("encoder_id") == encoder_id
