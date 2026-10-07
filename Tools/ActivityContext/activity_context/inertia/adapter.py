"""Inertia-1 encoder adapter: verify-on-load, strict, frozen, CPU fp32 (INERTIA1.md §4, spec §7).

``Inertia1Encoder(ckpt_path or $INERTIA1_CKPT_PATH, encoder_config)`` load sequence; every failure is a
typed ``InertiaUnavailable(kind)``:

1. encoder config invalid -> ``config_mismatch``; config / checkpoint path missing -> ``model_missing``;
   file size or sha256 (computed BEFORE ``torch.load``) != config -> ``checkpoint_mismatch``;
2. ``torch.load(weights_only=True)`` (unloadable -> ``checkpoint_mismatch``), take the Lightning
   ``state_dict``, require exactly the vendored module's key set and shapes (the pretraining head included,
   so a wrong family/preset fails) and float32 finite tensors, then ``load_state_dict(strict=True)``
   -> otherwise ``config_mismatch``. ART ``pos_encoder.pe`` must equal the recomputed sinusoid table;
   PatchTST ``W_pos.shape[0]`` must equal ``window_s * hz / patch_len``;
3. optional ``expected_preprocessing`` (the bundle's): ``data.window_sec/hz/axes`` must match;
4. ``eval()``, ``requires_grad_(False)``, ``torch.inference_mode()``, fp32, CPU, ``torch.set_num_threads(1)``
   by default (process-global; faster than 12 threads at batch 64 and deterministic). No network, ever.

``make_test_checkpoint`` writes a Lightning-like ``{"state_dict": ...}`` file from a seeded random-init
vendored model, FOR TESTS AND FIXTURES ONLY — such a file is not Inertia-1 and is never pinned.
"""

from __future__ import annotations

import os
import time
from typing import Any, Dict, Mapping, Optional, Union

import numpy as np

from . import ENCODER_CONFIG_SCHEMA, INERTIA_RATE_HZ, REAL_ENCODER_PREFIX, UPSTREAM_COMMIT
from .contract import EncoderInfo, InertiaUnavailable, InputContract, make_info, sha256_file, validate_batch
from .encoder_config import (EXTRACTION_POINTS, EncoderConfigError, build_module, check_against_preprocessing,
                             expected_arch, load_encoder_config, random_init_id)

ENV_CKPT = "INERTIA1_CKPT_PATH"
DEFAULT_MAX_BATCH = 64                 # see runtime.DEFAULT_MAX_BATCH
TEST_CHECKPOINT_NOTE = "TEST CHECKPOINT: seeded random init of the vendored architecture; NOT Inertia-1"


def _torch():
    try:
        import torch
    except ImportError as exc:  # pragma: no cover - exercised only without the [inertia] extra
        raise InertiaUnavailable("model_missing", "torch is not installed (install the [inertia] extra)") from exc
    return torch


def random_init_module(method: str, arch: Mapping[str, Any], window_s: int, seed: int):
    """Vendored module with seeded random weights; the global torch RNG is left untouched.

    Built with one intra-op thread: the ART sinusoid table's last-ULP values depend on torch's thread
    count (vectorised sin/cos chunking), and fixture checkpoints must be byte-reproducible."""
    torch = _torch()
    prev = torch.get_num_threads()
    torch.set_num_threads(1)
    try:
        with torch.random.fork_rng(devices=[]):
            torch.manual_seed(int(seed))
            return build_module(method, arch, window_s)
    finally:
        torch.set_num_threads(prev)


class _TorchEncoder:
    """Shared frozen-module embedding loop (batched, inference_mode, fp32, CPU)."""

    def __init__(self, module, info: EncoderInfo, threads: Optional[int], max_batch: int):
        torch = _torch()
        if threads is not None:
            torch.set_num_threads(int(threads))
        module.eval()
        module.requires_grad_(False)
        self._module = module
        self._info = info
        self._torch = torch
        self.max_batch = int(max_batch)
        self.threads = torch.get_num_threads()

    @property
    def info(self) -> EncoderInfo:
        return self._info

    @property
    def module(self):
        return self._module

    def embed(self, batch: np.ndarray) -> np.ndarray:
        batch = validate_batch(batch, self._info.input_contract)
        D = self._info.embedding_dim
        out = np.empty((batch.shape[0], D), dtype=np.float32)
        with self._torch.inference_mode():
            for i in range(0, batch.shape[0], self.max_batch):
                x = self._torch.from_numpy(np.ascontiguousarray(batch[i:i + self.max_batch]))
                out[i:i + self.max_batch] = self._module.encode(x).numpy()
        return out


def _check_state(state: Any, module, method: str, arch: Mapping[str, Any], window_s: int) -> None:
    torch = _torch()
    if not isinstance(state, Mapping) or not all(isinstance(k, str) and isinstance(v, torch.Tensor)
                                                 for k, v in state.items()):
        raise InertiaUnavailable("config_mismatch", "checkpoint state_dict is not a {name: tensor} mapping")
    want = module.state_dict()
    missing, unexpected = sorted(set(want) - set(state)), sorted(set(state) - set(want))
    if missing or unexpected:
        raise InertiaUnavailable("config_mismatch", f"state_dict keys differ from {method} "
                                 f"(missing {missing[:5]}{'…' if len(missing) > 5 else ''}, "
                                 f"unexpected {unexpected[:5]}{'…' if len(unexpected) > 5 else ''})")
    if method == "patchtst":
        n_patch = window_s * INERTIA_RATE_HZ // arch["patch_len"]
        got = tuple(state["model.backbone.W_pos"].shape)
        if got[:1] != (n_patch,):
            raise InertiaUnavailable("config_mismatch", f"PatchTST W_pos has {got[0]} patches; a {window_s}s "
                                     f"@ {INERTIA_RATE_HZ} Hz window needs {n_patch} (learned W_pos is window-coupled)")
    for k, v in state.items():
        if tuple(v.shape) != tuple(want[k].shape):
            raise InertiaUnavailable("config_mismatch", f"{k}: shape {list(v.shape)} != {list(want[k].shape)}")
        if v.dtype != torch.float32:
            raise InertiaUnavailable("config_mismatch", f"{k}: dtype {v.dtype} (expected float32)")
        if not bool(torch.isfinite(v).all()):
            raise InertiaUnavailable("config_mismatch", f"{k}: nonfinite weights")
    if method == "ar_transformer":
        if not torch.allclose(state["pos_encoder.pe"], want["pos_encoder.pe"], rtol=0.0, atol=1e-6):
            raise InertiaUnavailable("config_mismatch", "pos_encoder.pe differs from the sinusoid table")


class Inertia1Encoder(_TorchEncoder):
    """Checkpoint-backed vendored encoder (real ``inertia-1/`` ids, or ``standin:`` random-init fixtures)."""

    def __init__(self, ckpt_path: Optional[str], encoder_config: Union[str, Mapping[str, Any]], device: str = "cpu",
                 threads: Optional[int] = 1, *, expected_preprocessing: Optional[Mapping[str, Any]] = None,
                 max_batch: int = DEFAULT_MAX_BATCH):
        t0 = time.perf_counter()
        if device != "cpu":
            raise InertiaUnavailable("config_mismatch", f"only device='cpu' is supported, got {device!r}")
        try:
            cfg, _base = load_encoder_config(encoder_config)
            if expected_preprocessing is not None:
                check_against_preprocessing(cfg, expected_preprocessing)
        except FileNotFoundError as exc:
            raise InertiaUnavailable("model_missing", str(exc)) from exc
        except EncoderConfigError as exc:
            raise InertiaUnavailable("config_mismatch", str(exc)) from exc
        path = ckpt_path or os.environ.get(ENV_CKPT) or ""
        if not path or not os.path.isfile(path):
            raise InertiaUnavailable("model_missing", f"Inertia-1 checkpoint not found (path {path!r}; set "
                                     f"--checkpoint or ${ENV_CKPT})")
        ck = cfg["checkpoint"]
        if os.path.getsize(path) != ck["size"]:
            raise InertiaUnavailable("checkpoint_mismatch", f"checkpoint size {os.path.getsize(path)} != {ck['size']}")
        sha = sha256_file(path)
        if sha != ck["sha256"]:
            raise InertiaUnavailable("checkpoint_mismatch", f"checkpoint sha256 {sha[:12]}… != config {ck['sha256'][:12]}…")
        torch = _torch()
        try:
            blob = torch.load(path, map_location="cpu", weights_only=True)
        except Exception as exc:  # noqa: BLE001 - any unpickling failure is a bad checkpoint
            raise InertiaUnavailable("checkpoint_mismatch", f"checkpoint is not loadable: {exc}") from exc
        state = blob["state_dict"] if isinstance(blob, Mapping) and "state_dict" in blob else blob
        method, preset, window_s = cfg["method"], cfg["preset"], cfg["data"]["window_sec"]
        module = build_module(method, cfg["arch"], window_s)
        _check_state(state, module, method, cfg["arch"], window_s)
        try:
            module.load_state_dict(state, strict=True)
        except RuntimeError as exc:
            raise InertiaUnavailable("config_mismatch", f"strict load failed: {exc}") from exc
        kind = "inertia1" if cfg["encoder_id"].startswith(REAL_ENCODER_PREFIX) else "standin"
        info = make_info(encoder_id=cfg["encoder_id"], kind=kind, config=cfg, embedding_dim=cfg["embedding_dim"],
                         window_s=window_s, extraction_point=cfg["extraction_point"], checkpoint_sha256=sha,
                         upstream_commit=UPSTREAM_COMMIT, version_tag=f"{method}-{preset}")
        super().__init__(module, info, threads, max_batch)
        self.checkpoint_path = os.path.abspath(path)
        self.load_seconds = time.perf_counter() - t0


class RandomInitArchEncoder(_TorchEncoder):
    """``standin:inertia-arch-random-init/<method>-<preset>/seed<k>`` — negative control, NOT Inertia-1."""

    def __init__(self, method: str, preset: str, seed: int, window_s: int = 30, threads: Optional[int] = 1,
                 max_batch: int = DEFAULT_MAX_BATCH):
        arch = expected_arch(method, preset)
        module = random_init_module(method, arch, window_s, seed)
        cfg = {"encoder_id": random_init_id(method, preset, seed), "method": method, "preset": preset,
               "arch": arch, "window_s": int(window_s), "seed": int(seed), "note": TEST_CHECKPOINT_NOTE}
        info = make_info(encoder_id=cfg["encoder_id"], kind="standin", config=cfg, embedding_dim=arch["d_model"],
                         window_s=window_s, extraction_point=EXTRACTION_POINTS[method],
                         upstream_commit=UPSTREAM_COMMIT, version_tag=f"random-init-{method}-{preset}")
        super().__init__(module, info, threads, max_batch)


def make_test_checkpoint(path: str, method: str, preset_or_arch: Union[str, Mapping[str, Any]], window_s: int,
                         seed: int, *, encoder_id: Optional[str] = None) -> Dict[str, Any]:
    """TESTS/FIXTURES ONLY: write a seeded random-init Lightning-like ``.ckpt``; return its encoder.json dict.

    ``preset_or_arch`` is a preset name, or an arch dict (merged over ``tiny``) to build a deliberately
    non-preset network; the returned config then has ``preset: "custom"`` and does not validate as-is."""
    torch = _torch()
    if isinstance(preset_or_arch, str):
        preset, arch = preset_or_arch, expected_arch(method, preset_or_arch)
    else:
        preset, arch = "custom", {**expected_arch(method, "tiny"), **dict(preset_or_arch)}
    module = random_init_module(method, arch, window_s, seed)
    state = {k: v.detach().clone().contiguous() for k, v in module.state_dict().items()}
    torch.save({"state_dict": state, "nara_note": TEST_CHECKPOINT_NOTE}, path)
    return {
        "schema": ENCODER_CONFIG_SCHEMA,
        "encoder_id": encoder_id or random_init_id(method, preset, seed),
        "method": method, "preset": preset, "arch": arch,
        "data": {"window_sec": int(window_s), "hz": INERTIA_RATE_HZ, "axes": 3, "axis_reduce": "l2"},
        "checkpoint": {"file": os.path.basename(path), "sha256": sha256_file(path), "size": os.path.getsize(path),
                       "source": "make_test_checkpoint (seeded random init; NOT Inertia-1)", "url": None},
        "inertia_repo_commit": UPSTREAM_COMMIT,
        "extraction_point": EXTRACTION_POINTS[method],
        "embedding_dim": int(arch["d_model"]),
        "input_contract": InputContract(window_s=int(window_s)).config_dict(),
        "notes": TEST_CHECKPOINT_NOTE,
    }
