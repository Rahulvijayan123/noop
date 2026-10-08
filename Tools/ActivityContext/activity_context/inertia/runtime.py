"""Inertia runtime: load once (bundle + encoder), then turn infer requests into motion-heads-1 responses.

``build_runtime`` never raises: any load failure becomes ``status = "inertia_unavailable"`` with a typed
``InertiaUnavailable`` (model_missing | checkpoint_mismatch | config_mismatch | internal), and every infer
then fails with that kind — it never falls back to anything that claims to be Inertia (INERTIA1.md §6).

Stand-in encoders or stand-in bundles (anything whose wire ``encoder_kind`` is ``standin`` — including a
real-architecture checkpoint that is not in ``PINNED_CHECKPOINTS``) are refused unless
``allow_standin_shadow`` is set; then they run as ``standin_shadow`` and the response is capped at
``evidence_tier_max = "shadow"``.

Encoder resolution: an explicit ``encoder_config`` wins; otherwise the bundle's ``encoder.json`` is used as an
encoder config only when it IS one (schema ``nara.inertia.encoder/1``, checkpoint-backed). Training bundles
carry an encoder *card* there instead (the embedding-cache record); a stand-in is then built from its id by
the registry and its ``config_sha256`` must equal the bundle's (and the card's) — never guessed.

``expect_bundle_sha256`` (serve ``--expect-bundle-sha256``): a loaded bundle with any other hash is
unavailable (``config_mismatch``). Bundles with ``evidence_tier_max = "offline"`` (built from a dirty tree)
are refused unless ``allow_offline`` (offline replay tooling only; reported tier then ``shadow``).
"""

from __future__ import annotations

import os
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .. import __version__
from ..loaded import base_loaded, code_sha256, configure_torch_threads, loaded_digest
from ..preprocess import (MAX_HEAD_SECONDS, MAX_RUN_SECONDS, MAX_TAIL_SECONDS, PreprocessError,
                          decode_columns_b64, validate_request_units)
from . import (ACTINET_ENCODER_PREFIX, ALLOWED_HOP_S, ENCODER_CONFIG_SCHEMA, PREPROCESSING_VERSION, STANDIN_PREFIX,
               WIRE_SCHEMA)
from .bundle import BundleError, HeadBundle, load_bundle
from .contract import Encoder, EncoderInfo, InertiaUnavailable
from .preprocess import stack_windows, windows_from_seconds

MAX_OUTPUT_BYTES = 12 * 1024 * 1024          # below the worker's 16 MiB line cap
MAX_WINDOWS_PER_RESPONSE = 200_000
# 64, not 256: same throughput for ART/PatchTST small on CPU but ~360 MB less peak RSS (eval/inertia/perf.json).
DEFAULT_MAX_BATCH = 64
ERROR_KINDS = ("malformed", "model_missing", "checkpoint_mismatch", "config_mismatch", "timeout", "internal",
               "output_too_large")
_ROUND = 6


class RequestError(Exception):
    """An infer request failed; ``kind`` is one of ERROR_KINDS."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind if kind in ERROR_KINDS else "internal"
        self.message = message


@dataclass
class InertiaRuntime:
    encoder: Optional[Encoder]
    bundle: Optional[HeadBundle]
    status: str                                   # inertia_loaded | inertia_unavailable | standin_shadow
    error: Optional[InertiaUnavailable] = None
    max_batch: int = DEFAULT_MAX_BATCH
    max_output_bytes: int = MAX_OUTPUT_BYTES
    load_seconds: float = 0.0
    threads: Optional[int] = None

    @property
    def available(self) -> bool:
        return self.error is None and self.encoder is not None and self.bundle is not None

    def loaded(self) -> Dict[str, str]:
        """Only what this process holds (loaded.py): the bundle digest (over its verified files and manifest), the
        encoder checkpoint verified before load and its config digest. A bundle whose encoder is not the one its
        heads were trained on never loads (``check_consistency``), so an encoder without matching heads reports no
        bundle here."""
        out = base_loaded(self.threads if self.available else None)
        if not self.available:
            return out
        info = self.info
        out["bundle_sha256"] = self.bundle.bundle_sha256
        out["bundle_id"] = self.bundle.bundle_id
        out["encoder_id"] = info.encoder_id
        out["encoder_kind"] = info.wire_kind
        out["encoder_config_sha256"] = info.config_sha256
        if info.checkpoint_sha256:
            out["checkpoint_sha256"] = info.checkpoint_sha256
        out["evidence_tier_max"] = str(self.evidence_tier_max)
        return out

    @property
    def info(self) -> Optional[EncoderInfo]:
        return self.encoder.info if self.encoder is not None else None

    @property
    def evidence_tier_max(self) -> Optional[str]:
        if self.bundle is None:
            return None
        if self.status == "standin_shadow" or self.bundle.evidence_tier_max == "offline":
            return "shadow"           # the wire vocabulary has no 'offline'; it is never above shadow
        return self.bundle.evidence_tier_max

    @property
    def encoder_kind(self) -> Optional[str]:
        return self.info.wire_kind if self.info is not None else None


def check_consistency(bundle: HeadBundle, info: EncoderInfo) -> None:
    """The bundle's heads were trained on exactly this encoder (id, dim, bytes, config, window)."""
    enc = bundle.encoder
    problems = []
    if enc["encoder_id"] != info.encoder_id:
        problems.append(f"encoder_id {info.encoder_id} != bundle {enc['encoder_id']}")
    if enc["embedding_dim"] != info.embedding_dim:
        problems.append(f"embedding_dim {info.embedding_dim} != bundle {enc['embedding_dim']}")
    for key in ("checkpoint_sha256", "config_sha256"):
        if enc.get(key) is not None and enc[key] != getattr(info, key):
            problems.append(f"{key} differs from the bundle's")
    if info.input_contract.window_s != bundle.preprocessing["window_s"]:
        problems.append(f"window {info.input_contract.window_s}s != bundle {bundle.preprocessing['window_s']}s")
    if problems:
        raise InertiaUnavailable("config_mismatch", "; ".join(problems))


def _bundle_encoder_json(bundle: HeadBundle) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """(path, None) when the bundle's encoder.json is an encoder config; (None, card) when it is a training
    encoder card; (None, None) when the bundle has none. The file is hash-verified by load_bundle."""
    import json
    if "encoder.json" not in bundle.manifest["files"]:
        return None, None
    path = os.path.join(bundle.path, "encoder.json")
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if isinstance(doc, dict) and doc.get("schema") == ENCODER_CONFIG_SCHEMA:
        return path, None
    return None, doc if isinstance(doc, dict) else {}


def _resolve_encoder(bundle: HeadBundle, encoder_config: Optional[str], checkpoint: Optional[str],
                     threads: Optional[int], max_batch: int) -> Encoder:
    from .registry import build_encoder
    eid = bundle.encoder["encoder_id"]
    kw: Dict[str, Any] = {"window_s": bundle.preprocessing["window_s"], "threads": threads,
                          "ckpt_path": checkpoint, "max_batch": max_batch}
    cfg, card = (encoder_config, None) if encoder_config is not None else _bundle_encoder_json(bundle)
    if cfg is not None:
        kw["encoder_config"] = cfg
        kw["expected_preprocessing"] = bundle.preprocessing
        return build_encoder(eid, **kw)
    if not eid.startswith((STANDIN_PREFIX, ACTINET_ENCODER_PREFIX)):
        raise InertiaUnavailable("model_missing", f"{eid} needs its encoder.json (nara.inertia.encoder/1) and checkpoint")
    # stand-in: from its id (no config, no checkpoint); actinet: from its id + the pinned weights (--checkpoint)
    enc = build_encoder(eid, **kw)
    want = bundle.encoder.get("config_sha256")
    if want is None or enc.info.config_sha256 != want:
        raise InertiaUnavailable("config_mismatch", f"{eid} built from its id has config_sha256 "
                                 f"{enc.info.config_sha256[:12]}…, the bundle records {str(want)[:12]}…")
    if card is not None:
        for key in ("encoder_id", "config_sha256", "embedding_dim"):
            if key in card and card[key] != getattr(enc.info, key):
                raise InertiaUnavailable("config_mismatch", f"bundle encoder card {key} {card[key]!r} != the "
                                         f"stand-in built from its id ({getattr(enc.info, key)!r})")
    return enc


def build_runtime(bundle_dir: Optional[str], *, encoder_config: Optional[str] = None,
                  checkpoint: Optional[str] = None, allow_standin_shadow: bool = False,
                  threads: Optional[int] = 1, max_batch: int = DEFAULT_MAX_BATCH,
                  encoder: Optional[Encoder] = None, expect_bundle_sha256: Optional[str] = None,
                  allow_offline: bool = False) -> InertiaRuntime:
    """Load the bundle and its encoder once. ``encoder`` injects a pre-built encoder (tests)."""
    t0 = time.perf_counter()
    code_sha256()  # hashed once now, so a ping (under the request timeout) never pays for it
    bundle: Optional[HeadBundle] = None
    enc: Optional[Encoder] = None
    try:
        try:
            bundle = load_bundle(bundle_dir or "")
        except BundleError as exc:
            raise InertiaUnavailable(exc.kind, exc.message) from exc
        if expect_bundle_sha256 is not None and bundle.bundle_sha256 != expect_bundle_sha256.strip().lower():
            raise InertiaUnavailable("config_mismatch", f"bundle_sha256 {bundle.bundle_sha256[:16]}… differs from the "
                                     f"expected {expect_bundle_sha256[:16]}… (--expect-bundle-sha256)")
        if bundle.evidence_tier_max == "offline" and not allow_offline:
            raise InertiaUnavailable("config_mismatch", "bundle evidence_tier_max is 'offline' (built from a dirty "
                                     "source tree with --allow-dirty): offline research only, never served")
        enc = encoder if encoder is not None else _resolve_encoder(bundle, encoder_config, checkpoint, threads,
                                                                   max_batch)
        check_consistency(bundle, enc.info)
        standin = enc.info.wire_kind == "standin" or bundle.encoder["encoder_id"].startswith(STANDIN_PREFIX)
        if standin and not allow_standin_shadow:
            raise InertiaUnavailable("model_missing", f"{enc.info.encoder_id} is a stand-in (not a pinned Inertia-1 "
                                     f"checkpoint); it runs only with --allow-standin-shadow")
        status = "standin_shadow" if standin else "inertia_loaded"
        if "torch" in sys.modules:
            # The encoder runs on torch (a numpy stand-in never imports it): one inter-op thread, `threads` intra-op.
            configure_torch_threads(threads)
        return InertiaRuntime(encoder=enc, bundle=bundle, status=status, max_batch=max_batch,
                              load_seconds=time.perf_counter() - t0, threads=threads)
    except InertiaUnavailable as exc:
        return InertiaRuntime(encoder=enc, bundle=bundle, status="inertia_unavailable", error=exc,
                              max_batch=max_batch, load_seconds=time.perf_counter() - t0)
    except Exception as exc:  # noqa: BLE001 - never crash the lane on load
        return InertiaRuntime(encoder=enc, bundle=bundle, status="inertia_unavailable",
                              error=InertiaUnavailable("internal", f"{type(exc).__name__}: {exc}"),
                              max_batch=max_batch, load_seconds=time.perf_counter() - t0)


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

def _b64_list(value: Any, what: str, max_len: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RequestError("malformed", f"{what} must be a list of base64 strings")
    if len(value) > max_len:
        raise RequestError("malformed", f"{what} exceeds {max_len} seconds")
    return value


def parse_infer_request(req: Dict[str, Any], window_s: int, default_hop_s: int
                        ) -> Tuple[int, int, List[str], List[str], List[str], int]:
    """Validate the HART-identical ``run`` object (+ optional ``hop_s``)."""
    run = req.get("run")
    if not isinstance(run, dict):
        raise RequestError("malformed", "infer requires an object 'run'")
    start, end = run.get("start_ts"), run.get("end_ts")
    if (not isinstance(start, int) or not isinstance(end, int) or isinstance(start, bool)
            or isinstance(end, bool) or start < 0 or end <= start):
        raise RequestError("malformed", "run.start_ts/end_ts must be ints with start_ts < end_ts")
    if end - start > MAX_RUN_SECONDS:
        raise RequestError("malformed", f"run longer than {MAX_RUN_SECONDS} s")
    if run.get("sample_rate_hz") not in (None, 100):
        raise RequestError("malformed", f"only 100 Hz input is supported, got {run.get('sample_rate_hz')!r}")
    ch = run.get("channels_order")
    if ch is not None and ch != ["ax", "ay", "az", "gx", "gy", "gz"]:
        raise RequestError("malformed", "channels_order must be [ax,ay,az,gx,gy,gz]")
    try:
        validate_request_units(run.get("units") or {"accel": "g", "gyro": "deg/s"})
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    body = _b64_list(run.get("columns_b64"), "columns_b64", MAX_RUN_SECONDS)
    if len(body) != end - start:
        raise RequestError("malformed", f"columns_b64 count {len(body)} != end_ts - start_ts ({end - start})")
    pick = lambda k: run.get(k) if run.get(k) is not None else req.get(k)  # noqa: E731
    head = _b64_list(pick("head_b64"), "head_b64", MAX_HEAD_SECONDS)
    tail = _b64_list(pick("tail_b64"), "tail_b64", MAX_TAIL_SECONDS)
    hop = pick("hop_s")
    if hop is None:
        hop = default_hop_s
    if isinstance(hop, bool) or not isinstance(hop, (int, float)) or float(hop) not in ALLOWED_HOP_S \
            or float(hop) > window_s:
        raise RequestError("malformed", f"hop_s must be one of {list(ALLOWED_HOP_S)} and <= {window_s}, got {hop!r}")
    return start, end, body, head, tail, int(hop)


def _seconds(start: int, end: int, body: List[str], head: List[str], tail: List[str]) -> List[tuple]:
    try:
        out = [(start - len(head) + i, decode_columns_b64(b)) for i, b in enumerate(head)]
        out += [(start + i, decode_columns_b64(b)) for i, b in enumerate(body)]
        out += [(end + i, decode_columns_b64(b)) for i, b in enumerate(tail)]
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    return out


def embed_batched(encoder: Encoder, batch: np.ndarray, max_batch: int) -> np.ndarray:
    D = encoder.info.embedding_dim
    if batch.shape[0] == 0:
        return np.zeros((0, D), dtype=np.float32)
    parts = [encoder.embed(batch[i:i + max_batch]) for i in range(0, batch.shape[0], max_batch)]
    emb = np.concatenate(parts, axis=0)
    if emb.shape != (batch.shape[0], D):
        raise RequestError("internal", f"encoder returned shape {list(emb.shape)}, expected [{batch.shape[0]}, {D}]")
    return emb


def infer_seconds(rt: InertiaRuntime, seconds: List[tuple], start: int, end: int, hop_s: int
                  ) -> Tuple[List[Dict[str, Any]], int]:
    """Decoded seconds -> wire windows (rounded) and the count of nonfinite windows omitted."""
    window_s = rt.bundle.preprocessing["window_s"]
    try:
        windows = windows_from_seconds(seconds, start, end, window_s, hop_s)
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    if len(windows) > MAX_WINDOWS_PER_RESPONSE:
        raise RequestError("malformed", "too many windows for one response")
    emb = embed_batched(rt.encoder, stack_windows(windows), rt.max_batch) if windows else None
    rows = rt.bundle.apply(emb) if windows else []
    out: List[Dict[str, Any]] = []
    dropped = 0
    for w, row in zip(windows, rows):
        if row.get("nonfinite"):
            dropped += 1
            continue
        item: Dict[str, Any] = {"s": w.s, "e": w.e}
        for key, val in row.items():
            if isinstance(val, dict):
                item[key] = {c: round(p, _ROUND) for c, p in val.items()}
            elif isinstance(val, bool):
                item[key] = val
            else:
                item[key] = round(val, _ROUND)
        out.append(item)
    return out, dropped


def handle_infer(rt: InertiaRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    if not rt.available:
        err = rt.error or InertiaUnavailable("model_missing", "Inertia runtime not loaded")
        raise RequestError(err.kind, err.message)
    t0 = time.monotonic()
    pre = rt.bundle.preprocessing
    start, end, body, head, tail, hop_s = parse_infer_request(req, pre["window_s"], pre["hop_s"])
    windows, dropped = infer_seconds(rt, _seconds(start, end, body, head, tail), start, end, hop_s)
    info = rt.info
    return {
        "ok": True, "schema": WIRE_SCHEMA,
        "encoder_id": info.encoder_id, "encoder_kind": info.wire_kind, "encoder_version": info.encoder_version,
        "checkpoint_sha256": info.checkpoint_sha256, "heads_version": rt.bundle.bundle_id,
        "bundle_sha256": rt.bundle.bundle_sha256, "preprocessing_version": PREPROCESSING_VERSION,
        "evidence_tier_max": rt.evidence_tier_max, "window_s": int(pre["window_s"]), "hop_s": hop_s,
        "bundle": rt.bundle.wire_block(), "windows": windows, "n_dropped_nonfinite": dropped,
        "duration_ms": int((time.monotonic() - t0) * 1000),
    }


def handle_ping(rt: InertiaRuntime) -> Dict[str, Any]:
    info = rt.info if rt.available else None
    loaded = rt.loaded()
    return {
        "ok": True, "model_available": rt.available, "model_status": rt.status,
        "model_error": str(rt.error) if rt.error is not None else None,
        "encoder_id": info.encoder_id if info else None, "encoder_kind": info.wire_kind if info else None,
        "encoder_version": info.encoder_version if info else None,
        "heads_version": rt.bundle.bundle_id if rt.bundle else None,
        "bundle_sha256": rt.bundle.bundle_sha256 if rt.bundle else None,
        "checkpoint_sha256": info.checkpoint_sha256 if info else None,
        "preprocessing_version": PREPROCESSING_VERSION,
        "evidence_tier_max": rt.evidence_tier_max if rt.available else None,
        "package_version": __version__,
        "loaded": loaded, "loaded_digest": loaded_digest(loaded),
    }


def handle_request(rt: InertiaRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    """Dispatch one request object. Raises RequestError for every protocol-level failure."""
    req_id = req.get("id")
    if not isinstance(req_id, str) or not req_id:
        raise RequestError("malformed", "request needs a string 'id'")
    op = req.get("op")
    if op == "ping":
        resp = handle_ping(rt)
    elif op == "infer":
        resp = handle_infer(rt, req)
    elif op == "shutdown":
        resp = {"ok": True}
    else:
        raise RequestError("malformed", f"unknown op {op!r} (expected ping|infer|shutdown)")
    return {"id": req_id, "op": op, **resp}
