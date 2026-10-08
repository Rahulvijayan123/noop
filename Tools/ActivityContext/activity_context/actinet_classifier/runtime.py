"""ActiNet classifier runtime: load once, then turn requests into ``actinet-classifier-1`` responses
(ACTINET_CLASSIFIER.md §5-6).

``build_runtime`` never raises. Failures map to kinds:
- missing directory or file: ``model_missing``;
- size, sha256, schema, shape or finiteness mismatch: ``weights_mismatch``;
- anything else: ``internal``.
The process stays up; ``ping`` reports ``model_available: false`` and every ``infer`` fails with that kind. Nothing
here imports the HART model stack, the Inertia lane's runtime or ElderNet.

A request carries one or more HART-identical ``run`` objects. Each is one contiguous NPB1 run: ``columns_b64`` holds
one entry per second of ``[start_ts, end_ts)``. Its ``head_b64`` / ``tail_b64`` context is validated, then unused.
Normally a request is a day's bursts, because upstream's HMM runs over a whole recording: one Viterbi pass spans
every valid epoch of the request, and the label after each time gap is restored.

Output types are kept apart: per-epoch timing and validity, the network's softmax probabilities in upstream class
order, and the HMM label. They are separate blocks aligned by epoch index, and an invalid epoch has neither output.

Resource bounds:
- thread cap (``threads``);
- fixed padded batch (``max_batch``);
- at most ``max_epochs`` epochs and ``MAX_RUNS`` runs per request;
- at most ``max_output_bytes`` per response line.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .. import __version__
from ..preprocess import (MAX_HEAD_SECONDS, MAX_RUN_SECONDS, MAX_TAIL_SECONDS, PreprocessError,
                          decode_columns_b64, validate_request_units)
from . import (CONSUMER, DEFAULT_GRID, EPOCH_S, ERROR_KINDS, MODEL_ID, MODEL_VERSION, PREPROCESSING_VERSION,
               RELEASE_MODE, REQUIRED_CHANNELS, SOURCE_HZ, TEMPORAL_VERSION, UPSTREAM_CLASSIFIER_KEY,
               UPSTREAM_COMMIT, UPSTREAM_VERSION, WIRE_SCHEMA)
from .hmm import HMMParams, params_from_doc, smooth
from .preprocess import Epoch, Run, epochs as make_epochs, model_batch, runs_from_seconds, validate_grid
from .weights import CONVERTED, SOURCE, PinnedFile, WeightsError, artifact_digest

MAX_OUTPUT_BYTES = 12 * 1024 * 1024          # below the worker's 16 MiB line cap
MAX_EPOCHS_PER_REQUEST = 2880                # 24 h of contiguous 30 s epochs
MAX_RUNS = 4000                              # a day of 60 s / 180 s bursts is 480
DEFAULT_MAX_BATCH = 64
REASON_NONFINITE = "nonfinite_output"
INTERVAL_MS = EPOCH_S * 1000
INPUT_DIGEST_PREFIX = b"actinet-input-1\n"
CACHE_PREFIX = "actinet-classifier-cache-1\n"
WIRE_DECIMALS = 6


class RequestError(Exception):
    """An infer request failed; ``kind`` is one of ERROR_KINDS."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind if kind in ERROR_KINDS else "internal"
        self.message = message


def preprocessing_descriptor(grid: str = DEFAULT_GRID, max_batch: int = DEFAULT_MAX_BATCH) -> Dict[str, Any]:
    """Everything deterministic between the raw seconds and the outputs; its digest is part of the cache key."""
    return {
        "version": PREPROCESSING_VERSION, "temporal": TEMPORAL_VERSION,
        "source": {"rate_hz": SOURCE_HZ, "channels": list(REQUIRED_CHANNELS), "units": "g", "scale": "i16/4096",
                   "gravity": "kept", "runs": "shared decoder: gap > 1 s splits, duplicate / clock reset refused"},
        "epoch": {"seconds": EPOCH_S, "source_samples": SOURCE_HZ * EPOCH_S, "grid": validate_grid(grid),
                  "partial": "invalid (never padded)"},
        "resample": "per-epoch linear interp1d, linspace(0,1,3000) -> linspace(0,1,900), no filter",
        "lowpass": "none", "calibration": "none (D1)", "nonwear": "none (D2)",
        "model_input": "float32 [B, 3, 900]", "batch_rows": int(max_batch),
        "outputs": {"probabilities": "softmax(logits) float64", "label": "argmax -> Viterbi over the request's "
                    "valid epochs, raw label restored after a time gap (upstream HMM.predict)"},
    }


def sha256_json(obj: Any) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def cache_key(input_digest: str, artifact: str, preprocessing: str) -> str:
    """sha256 over the input digest, the artifact digest and the preprocessing digest (Spec 03 cache identity)."""
    text = f"{CACHE_PREFIX}{input_digest}\n{artifact}\n{preprocessing}\n"
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


@dataclass
class ActiNetRuntime:
    classifier: Optional[Any]                     # model.ActiNetClassifier (or a test double with .logits)
    classes: Tuple[str, ...]
    hmm: Optional[HMMParams]
    status: str                                   # actinet_loaded | actinet_unavailable
    error: Optional[WeightsError] = None
    pins: Tuple[PinnedFile, ...] = CONVERTED
    max_epochs: int = MAX_EPOCHS_PER_REQUEST
    max_output_bytes: int = MAX_OUTPUT_BYTES
    max_batch: int = DEFAULT_MAX_BATCH
    threads: int = 1
    grid: str = DEFAULT_GRID
    load_seconds: float = 0.0
    _digests: Dict[str, str] = field(default_factory=dict, repr=False)

    @property
    def available(self) -> bool:
        return self.error is None and self.classifier is not None and self.hmm is not None

    @property
    def artifact_digest(self) -> str:
        return artifact_digest(self.pins, SOURCE)

    @property
    def preprocessing(self) -> Dict[str, Any]:
        return preprocessing_descriptor(self.grid, self.max_batch)

    @property
    def preprocessing_digest(self) -> str:
        if "pre" not in self._digests:
            self._digests["pre"] = sha256_json(self.preprocessing)
        return self._digests["pre"]


def build_runtime(artifact_dir: Optional[str] = None, *, threads: Optional[int] = 1,
                  max_batch: int = DEFAULT_MAX_BATCH, max_epochs: int = MAX_EPOCHS_PER_REQUEST,
                  pins: Sequence[PinnedFile] = CONVERTED, classifier: Optional[Any] = None,
                  classes: Optional[Sequence[str]] = None, hmm: Optional[HMMParams] = None) -> ActiNetRuntime:
    """Resolve, verify and load once. ``classifier`` / ``classes`` / ``hmm`` inject pre-built parts (tests)."""
    t0 = time.perf_counter()
    kw = dict(pins=tuple(pins), max_epochs=int(max_epochs), max_batch=int(max_batch), threads=int(threads or 1))
    try:
        if classifier is None:
            from .model import build_classifier
            from .weights import read_artifact
            state, classes_, hmm_block, _ = read_artifact(artifact_dir, pins)
            hmm = params_from_doc(hmm_block, classes_)
            classifier = build_classifier(state, len(classes_), threads=threads, max_batch=max_batch)
            classes = classes_
        if classes is None or hmm is None:
            raise WeightsError("model_missing", "classes and hmm are required with an injected classifier")
        return ActiNetRuntime(classifier=classifier, classes=tuple(classes), hmm=hmm, status="actinet_loaded",
                              load_seconds=time.perf_counter() - t0, **kw)
    except WeightsError as exc:
        err = exc
    except Exception as exc:  # noqa: BLE001 - never crash the lane on load
        err = WeightsError("internal", f"{type(exc).__name__}: {exc}")
    return ActiNetRuntime(classifier=None, classes=(), hmm=None, status="actinet_unavailable", error=err,
                          load_seconds=time.perf_counter() - t0, **kw)


# ---------------------------------------------------------------------------
# Classification (array form; the served path and the offline tools share it)
# ---------------------------------------------------------------------------

@dataclass
class EpochResults:
    """``epochs`` in time order; the arrays cover the VALID epochs (``index`` = their positions in ``epochs``)."""
    epochs: List[Epoch]
    index: np.ndarray            # int [V]
    logits: np.ndarray           # float32 [V, K]
    probabilities: np.ndarray    # float64 [V, K]
    raw: np.ndarray              # int64 [V] argmax class index (upstream ``--no-hmm`` label)
    label: np.ndarray            # int64 [V] HMM label (class index)
    after_gap: np.ndarray        # bool [V] label restored to ``raw`` because the epoch follows a time gap


def classify_runs(rt: ActiNetRuntime, runs: Sequence[Run], start: float, end: float,
                  grid: Optional[str] = None) -> EpochResults:
    eps = make_epochs(runs, start, end, grid or rt.grid)
    if len(eps) > rt.max_epochs:
        raise RequestError("too_many_epochs", f"{len(eps)} epochs > {rt.max_epochs} per request; split the request")
    valid_pos = [i for i, ep in enumerate(eps) if ep.valid]
    k = len(rt.classes)
    logits = np.zeros((len(valid_pos), k), np.float32)
    step = max(1, int(rt.max_batch))                 # inputs built one padded batch at a time: bounded memory,
    for a in range(0, len(valid_pos), step):         # identical numerics (the classifier pads to max_batch)
        chunk = [eps[i] for i in valid_pos[a:a + step]]
        out = np.asarray(rt.classifier.logits(model_batch(runs, chunk)), dtype=np.float32)
        if out.shape != (len(chunk), k):
            raise RequestError("internal", f"classifier returned {out.shape}, expected {(len(chunk), k)}")
        logits[a:a + len(chunk)] = out
    finite = np.isfinite(logits).all(axis=1)
    for j in np.flatnonzero(~finite):
        ep = eps[valid_pos[j]]
        eps[valid_pos[j]] = Epoch(s=ep.s, e=ep.e, valid=False, reason=REASON_NONFINITE, covered_s=ep.covered_s)
    keep = np.flatnonzero(finite)
    index = np.asarray([valid_pos[j] for j in keep], dtype=np.int64)
    logits = logits[keep]
    from .model import softmax
    probs = softmax(logits) if logits.shape[0] else np.zeros((0, len(rt.classes)), np.float64)
    raw = np.argmax(logits, axis=1).astype(np.int64) if logits.shape[0] else np.zeros(0, np.int64)
    t_ms = np.asarray([int(round(eps[i].s * 1000)) for i in index], dtype=np.int64)
    label, gaps = smooth(raw, t_ms, rt.hmm, INTERVAL_MS)
    return EpochResults(epochs=eps, index=index, logits=logits, probabilities=probs, raw=raw,
                        label=np.asarray(label, dtype=np.int64), after_gap=gaps)


# ---------------------------------------------------------------------------
# Requests: {"op":"infer","runs":[run, ...]} (or the single HART-identical "run")
# ---------------------------------------------------------------------------

def _b64_list(value: Any, what: str, max_len: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RequestError("malformed", f"{what} must be a list of base64 strings")
    if len(value) > max_len:
        raise RequestError("malformed", f"{what} exceeds {max_len} seconds")
    return value


@dataclass(frozen=True)
class RunRequest:
    start: int
    end: int
    body: List[str]
    head: List[str]
    tail: List[str]


def parse_run(run: Any, i: int) -> RunRequest:
    if not isinstance(run, dict):
        raise RequestError("malformed", f"runs[{i}] must be an object")
    start, end = run.get("start_ts"), run.get("end_ts")
    if (not isinstance(start, int) or not isinstance(end, int) or isinstance(start, bool)
            or isinstance(end, bool) or start < 0 or end <= start):
        raise RequestError("malformed", f"runs[{i}].start_ts/end_ts must be ints with start_ts < end_ts")
    if end - start > MAX_RUN_SECONDS:
        raise RequestError("malformed", f"runs[{i}] longer than {MAX_RUN_SECONDS} s")
    if run.get("sample_rate_hz") not in (None, SOURCE_HZ):
        raise RequestError("malformed", f"only {SOURCE_HZ} Hz input is supported, got {run.get('sample_rate_hz')!r}")
    ch = run.get("channels_order")
    if ch is not None and ch != ["ax", "ay", "az", "gx", "gy", "gz"]:
        raise RequestError("malformed", "channels_order must be [ax,ay,az,gx,gy,gz]")
    try:
        validate_request_units(run.get("units") or {"accel": "g", "gyro": "deg/s"})
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    body = _b64_list(run.get("columns_b64"), f"runs[{i}].columns_b64", MAX_RUN_SECONDS)
    if len(body) != end - start:
        raise RequestError("malformed", f"runs[{i}].columns_b64 count {len(body)} != end_ts - start_ts "
                           f"({end - start})")
    head = _b64_list(run.get("head_b64"), f"runs[{i}].head_b64", MAX_HEAD_SECONDS)
    tail = _b64_list(run.get("tail_b64"), f"runs[{i}].tail_b64", MAX_TAIL_SECONDS)
    return RunRequest(start=start, end=end, body=body, head=head, tail=tail)


def parse_infer_request(req: Dict[str, Any]) -> List[RunRequest]:
    runs = req.get("runs")
    if runs is None and "run" in req:
        runs = [req.get("run")]
    if not isinstance(runs, list) or not runs:
        raise RequestError("malformed", "infer requires a non-empty list 'runs' (or one object 'run')")
    if len(runs) > MAX_RUNS:
        raise RequestError("malformed", f"more than {MAX_RUNS} runs in one request")
    out = [parse_run(r, i) for i, r in enumerate(runs)]
    for a, b in zip(out, out[1:]):
        if b.start < a.end:
            raise RequestError("malformed", "runs must be in time order and must not overlap")
    if sum(r.end - r.start for r in out) > MAX_RUN_SECONDS:
        raise RequestError("malformed", f"more than {MAX_RUN_SECONDS} s of input in one request")
    return out


def decode_run(r: RunRequest) -> List[Tuple[int, np.ndarray]]:
    """The body seconds of one run. ``head_b64`` / ``tail_b64`` (HART filter context) are decoded so a malformed
    one is refused, then dropped: ActiNet has no filter transient, and context must not move or extend epochs."""
    try:
        for b in r.head + r.tail:
            decode_columns_b64(b)
        return [(r.start + i, decode_columns_b64(b)) for i, b in enumerate(r.body)]
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc


def input_digest(decoded: Sequence[Tuple[RunRequest, List[Tuple[int, np.ndarray]]]]) -> str:
    """sha256 over ``actinet-input-1\\n`` then, per run in order, ``start_ts,end_ts\\n`` and each body second as an
    8-byte little-endian timestamp plus its 1200 column bytes: exactly the bytes the outputs depend on."""
    h = hashlib.sha256(INPUT_DIGEST_PREFIX)
    for r, seconds in decoded:
        h.update(f"{r.start},{r.end}\n".encode("ascii"))
        for ts, cols in seconds:
            h.update(int(ts).to_bytes(8, "little", signed=True))
            h.update(np.asarray(cols, dtype="<i2").tobytes())
    return h.hexdigest()


def _num(x: float):
    return int(x) if float(x).is_integer() else round(float(x), 3)


def wire_response(rt: ActiNetRuntime, res: EpochResults, digest: str, t0: float) -> Dict[str, Any]:
    n = len(res.epochs)
    probs: List[Optional[List[float]]] = [None] * n
    labels: List[Optional[str]] = [None] * n
    gaps: List[Optional[bool]] = [None] * n
    for j, i in enumerate(res.index.tolist()):
        probs[i] = [round(float(v), WIRE_DECIMALS) for v in res.probabilities[j]]
        labels[i] = rt.classes[int(res.label[j])]
        gaps[i] = bool(res.after_gap[j])
    reasons: Dict[str, int] = {}
    for ep in res.epochs:
        if not ep.valid:
            reasons[ep.reason] = reasons.get(ep.reason, 0) + 1
    pre = rt.preprocessing_digest
    art = rt.artifact_digest
    return {
        "ok": True, "schema": WIRE_SCHEMA, "model_id": MODEL_ID, "model_version": MODEL_VERSION,
        "release_mode": RELEASE_MODE, "consumer": CONSUMER,
        "upstream": {"package": "actinet", "version": UPSTREAM_VERSION, "commit": UPSTREAM_COMMIT,
                     "classifier_key": UPSTREAM_CLASSIFIER_KEY},
        "artifact": {"digest": art, "files": {pf.role: pf.sha256 for pf in (SOURCE,) + tuple(rt.pins)}},
        "preprocessing_version": PREPROCESSING_VERSION, "temporal_version": TEMPORAL_VERSION,
        "preprocessing_digest": pre, "input_digest": digest, "cache_key": cache_key(digest, art, pre),
        "epoch_s": EPOCH_S, "grid": rt.grid, "classes": list(rt.classes),
        "epochs": [{"s": _num(ep.s), "e": _num(ep.e), "valid": ep.valid, "reason": ep.reason} for ep in res.epochs],
        "probabilities": {"output_type": "class_probabilities", "classes": list(rt.classes), "calibrated": False,
                          "values": probs},
        "label": {"output_type": "hmm_label", "method": TEMPORAL_VERSION, "values": labels, "after_gap": gaps},
        "counts": {"epochs": n, "valid": int(res.index.shape[0]), "invalid": reasons},
        "duration_ms": int((time.monotonic() - t0) * 1000),
    }


def handle_infer(rt: ActiNetRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    if not rt.available:
        err = rt.error or WeightsError("model_missing", "ActiNet runtime not loaded")
        raise RequestError(err.kind, err.message)
    t0 = time.monotonic()
    parsed = parse_infer_request(req)
    decoded = [(r, decode_run(r)) for r in parsed]
    try:                                       # one decode: adjacent runs join, any missing second splits
        runs = runs_from_seconds([sec for _, seconds in decoded for sec in seconds])
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    start, end = min(r.start for r in parsed), max(r.end for r in parsed)
    try:
        res = classify_runs(rt, runs, float(start), float(end))
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    return wire_response(rt, res, input_digest(decoded), t0)


def handle_ping(rt: ActiNetRuntime) -> Dict[str, Any]:
    return {
        "ok": True, "model_available": rt.available, "model_status": rt.status,
        "model_error": f"{rt.error.kind}: {rt.error.message}" if rt.error is not None else None,
        "schema": WIRE_SCHEMA, "model_id": MODEL_ID, "model_version": MODEL_VERSION, "release_mode": RELEASE_MODE,
        "consumer": CONSUMER, "classes": list(rt.classes),
        "artifact": {"digest": rt.artifact_digest, "files": {pf.role: pf.sha256 for pf in (SOURCE,) + tuple(rt.pins)}},
        "upstream": {"package": "actinet", "version": UPSTREAM_VERSION, "commit": UPSTREAM_COMMIT},
        "preprocessing_version": PREPROCESSING_VERSION, "temporal_version": TEMPORAL_VERSION,
        "preprocessing": rt.preprocessing, "preprocessing_digest": rt.preprocessing_digest,
        "bounds": {"threads": rt.threads, "max_batch": rt.max_batch, "max_epochs": rt.max_epochs,
                   "max_runs": MAX_RUNS, "max_output_bytes": rt.max_output_bytes},
        "package_version": __version__, "load_seconds": round(rt.load_seconds, 3),
    }


def handle_request(rt: ActiNetRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
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


__all__ = ["MAX_OUTPUT_BYTES", "MAX_EPOCHS_PER_REQUEST", "MAX_RUNS", "DEFAULT_MAX_BATCH", "REASON_NONFINITE",
           "RequestError", "preprocessing_descriptor", "cache_key", "ActiNetRuntime", "build_runtime", "EpochResults",
           "classify_runs", "RunRequest", "parse_run", "parse_infer_request", "decode_run", "input_digest",
           "wire_response", "handle_infer", "handle_ping", "handle_request"]
