"""Pinned ActiNet artifacts: the upstream source, the offline conversion, and verify-before-load (ACTINET_CLASSIFIER.md §1).

Upstream ships the classifier as one ``joblib.lzma`` pickle of ``actinet.models.ActivityClassifier``. It holds the
network state dict, the class labels and the fitted ``actinet.hmm.HMM``. Unpickling it runs code and needs the
``actinet`` package, so the serve process never does it. The operator instead runs two offline steps:

- ``fetch``: download the pinned joblib (size, sha256 and upstream's own md5 checked).
- ``convert``: unpickle it ONCE in an offline environment that has ``actinet==0.7.2`` and ``torch==2.8.0``, and
  write two pickle-free files.

    python -m activity_context.actinet_classifier.weights fetch   --dest <source dir>
    python -m activity_context.actinet_classifier.weights convert --source <source dir>/<joblib> --dest <dir>
    python -m activity_context.actinet_classifier.weights verify  --dir <dir>

The two converted files:

- ``actinet-walmsley-20260128-weights.pt``: a plain ``{name: tensor}`` state dict for
  ``torch.load(weights_only=True)``.
- ``actinet-walmsley-20260128-hmm.json`` (``nara.actinet.hmm/1``): the class order, the HMM parameters with their
  dtypes, and the source identity. This file is the only place the class order comes from.

The conversion is byte-reproducible (fixed file names, upstream key order, canonical JSON), so the converted files
are pinned by size and sha256 like the source. At serve time a directory (``--artifact-dir`` /
``$ACTINET_CLASSIFIER_DIR``) is resolved and every file is verified before it is read. Any missing file is
``model_missing``; a size, sha256, schema, shape or finiteness mismatch is ``weights_mismatch`` (:class:`WeightsError`).
Nothing is downloaded at serve time. Weights and HMM parameters are University of Oxford material and are never
committed (ACTINET_CLASSIFIER.md "Licence").
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple

from . import (EPOCH_S, HMM_SCHEMA, MODEL_ID, MODEL_VERSION, UPSTREAM_CLASSIFIER_KEY, UPSTREAM_COMMIT,
               UPSTREAM_VERSION)

ARTIFACT_DIR_ENV = "ACTINET_CLASSIFIER_DIR"
BASE_URL = "https://wearables-files.ndph.ox.ac.uk/files/models/actinet/"
SSL_WEARABLES_TAG = "v1.0.0"


class WeightsError(RuntimeError):
    """``kind`` is ``model_missing`` (file or directory absent) or ``weights_mismatch`` (size, sha256, content)."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message


@dataclass(frozen=True)
class PinnedFile:
    role: str                  # source | weights | hmm
    filename: str
    sha256: str
    size: int
    url: Optional[str] = None
    md5: Optional[str] = None  # upstream's own pin (actinet.__classifiers__), source only


# Upstream artifact (audit 2026-10-07): actinet 0.7.2 __classifiers__["walmsley"] = {"version":
# "ssl-ukb-c24-rw-30s-20260128", "md5": "a829041ba84b18084b4b2897fb1b36a6"}; downloaded from BASE_URL, size and
# md5 matched, sha256 measured.
SOURCE = PinnedFile("source", MODEL_VERSION + ".joblib.lzma",
                    "07dfd7482350dc30f0d69a4d59216caf0835bcca2d71d8e10a1243c8f7697fba", 40902237,
                    url=BASE_URL + MODEL_VERSION + ".joblib.lzma", md5="a829041ba84b18084b4b2897fb1b36a6")

# Converted files: written by :func:`convert` with torch 2.8.0 from SOURCE (twice, byte-identical).
WEIGHTS = PinnedFile("weights", "actinet-walmsley-20260128-weights.pt",
                     "1a20251b3239a86867fc4233d6b2e2ba9371a69e26ca94576c6fc3e43c964dee", 44077763)
HMM = PinnedFile("hmm", "actinet-walmsley-20260128-hmm.json",
                 "79cc17a6b288d72d5de11d0482b0a02b9f0ba7f76dde3cd657db8ff894824cb5", 1489)
CONVERTED: Tuple[PinnedFile, ...] = (WEIGHTS, HMM)

# The offline environment the conversion is pinned to (torch's serializer writes the .pt bytes).
CONVERT_ENV = {"actinet": UPSTREAM_VERSION, "actipy": "3.8.0", "torch": "2.8.0", "joblib": "1.2.*",
               "numpy": "1.24.*", "python": "3.10"}


def sha256_file(path: str) -> str:
    from ..fetch_artifacts import sha256_file as _sha
    return _sha(path)


def md5_file(path: str) -> str:
    h = hashlib.md5()  # noqa: S324 - upstream's own integrity pin, checked in addition to sha256
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def artifact_dir(explicit: Optional[str] = None) -> str:
    """The explicit directory, else ``$ACTINET_CLASSIFIER_DIR``; "" when neither is set (never a guess)."""
    return (explicit or os.environ.get(ARTIFACT_DIR_ENV, "")).strip()


def verify_file(path: str, pf: PinnedFile) -> str:
    """Size then sha256 (then md5 when pinned); returns the sha256. Nothing is parsed before this passes."""
    if not os.path.isfile(path):
        raise WeightsError("model_missing", f"{pf.role}: {path} not found")
    size = os.path.getsize(path)
    if size != pf.size:
        raise WeightsError("weights_mismatch", f"{pf.role}: {os.path.basename(path)} is {size} bytes, pinned {pf.size}")
    digest = sha256_file(path)
    if digest != pf.sha256:
        raise WeightsError("weights_mismatch", f"{pf.role}: sha256 {digest[:16]}… != pinned {pf.sha256[:16]}…")
    if pf.md5 is not None and md5_file(path) != pf.md5:
        raise WeightsError("weights_mismatch", f"{pf.role}: md5 differs from upstream's pin {pf.md5}")
    return digest


def resolve(directory: Optional[str] = None, pins: Sequence[PinnedFile] = CONVERTED) -> Dict[str, str]:
    """role -> verified path of each converted file in ``directory``."""
    d = artifact_dir(directory)
    if not d:
        raise WeightsError("model_missing", f"no artifact directory: set ${ARTIFACT_DIR_ENV} or pass --artifact-dir "
                           f"(fetch + convert with: python -m activity_context.actinet_classifier.weights)")
    if not os.path.isdir(d):
        raise WeightsError("model_missing", f"artifact directory {d} does not exist")
    out = {}
    for pf in pins:
        path = os.path.join(d, pf.filename)
        verify_file(path, pf)
        out[pf.role] = path
    return out


ARTIFACT_DIGEST_PREFIX = "actinet-classifier-artifact-1\n"


def artifact_digest(pins: Sequence[PinnedFile] = CONVERTED, source: PinnedFile = SOURCE) -> str:
    """The deployment pin over the source and the converted files: sha256 of ``actinet-classifier-artifact-1\\n``
    then ``role=sha256\\n`` for the source and each converted file, in role order."""
    roles = {source.role: source.sha256, **{pf.role: pf.sha256 for pf in pins}}
    text = ARTIFACT_DIGEST_PREFIX + "".join(f"{k}={v}\n" for k, v in sorted(roles.items()))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# The deployment pin a worker sets (= artifact_digest(); asserted by the tests): changes whenever the source or a
# converted file changes, so it invalidates every cached answer even if a version label were reused.
DEPLOYMENT_ARTIFACT_DIGEST = "5d4d749a61d1b848d6930a66ee4c1d6aac9b236aeb6d2a3aeb9a8eb15864c941"


# ---------------------------------------------------------------------------
# The converted HMM / class-order document (nara.actinet.hmm/1)
# ---------------------------------------------------------------------------

def _finite_matrix(value: Any, shape: Tuple[int, ...], what: str) -> None:
    import numpy as np
    try:
        a = np.asarray(value, dtype=np.float64)
    except (TypeError, ValueError) as exc:
        raise WeightsError("weights_mismatch", f"hmm.{what}: not numeric") from exc
    if a.shape != shape:
        raise WeightsError("weights_mismatch", f"hmm.{what}: shape {a.shape} != {shape}")
    if not np.isfinite(a).all() or (a < 0).any():
        raise WeightsError("weights_mismatch", f"hmm.{what}: nonfinite or negative values")


def validate_hmm_doc(doc: Any) -> Tuple[Tuple[str, ...], Dict[str, Any]]:
    """A parsed ``nara.actinet.hmm/1`` document -> (class order, hmm block); ``weights_mismatch`` if malformed."""
    import numpy as np
    if not isinstance(doc, Mapping) or doc.get("schema") != HMM_SCHEMA:
        raise WeightsError("weights_mismatch", f"hmm file is not a {HMM_SCHEMA} document")
    classes = doc.get("classes")
    if (not isinstance(classes, list) or len(classes) < 2 or len(set(classes)) != len(classes)
            or not all(isinstance(c, str) and c for c in classes)):
        raise WeightsError("weights_mismatch", "hmm.classes must be >= 2 unique non-empty strings")
    if doc.get("window_sec") != EPOCH_S:
        raise WeightsError("weights_mismatch", f"window_sec {doc.get('window_sec')!r} != {EPOCH_S}")
    h = doc.get("hmm")
    k = len(classes)
    if not isinstance(h, Mapping):
        raise WeightsError("weights_mismatch", "hmm block missing")
    if h.get("labels") != list(range(k)):
        raise WeightsError("weights_mismatch", "hmm.labels must be the class indices 0..K-1")
    _finite_matrix(h.get("prior"), (k,), "prior")
    _finite_matrix(h.get("emission"), (k, k), "emission")
    _finite_matrix(h.get("transition"), (k, k), "transition")
    for flag in ("uniform_prior", "ignore_transition_gaps"):
        if not isinstance(h.get(flag), bool):
            raise WeightsError("weights_mismatch", f"hmm.{flag} must be a boolean")
    if h.get("dtypes") != {"prior": "float64", "emission": "float32", "transition": "float64"}:
        raise WeightsError("weights_mismatch", "hmm.dtypes must record float64 prior/transition, float32 emission")
    rows = np.asarray(h["transition"], dtype=np.float64).sum(axis=1)
    if not np.allclose(rows, 1.0, atol=1e-6):
        raise WeightsError("weights_mismatch", "hmm.transition rows must sum to 1")
    return tuple(classes), dict(h)


def canonical_json(obj: Any) -> bytes:
    """Sorted keys, no whitespace, shortest round-trip floats, NaN refused, one trailing newline."""
    return (json.dumps(obj, sort_keys=True, separators=(",", ":"), allow_nan=False, ensure_ascii=True)
            + "\n").encode("ascii")


def read_artifact(directory: Optional[str] = None, pins: Sequence[PinnedFile] = CONVERTED):
    """Resolve + verify, then load: (state dict, class order, hmm block, {role: sha256}). Never unpickles code:
    ``torch.load(weights_only=True)`` and ``json``."""
    import torch
    paths = resolve(directory, pins)
    digests = {pf.role: pf.sha256 for pf in pins}
    try:
        state = torch.load(paths["weights"], map_location="cpu", weights_only=True)
    except Exception as exc:  # noqa: BLE001 - any unreadable file is a mismatch, never a crash
        raise WeightsError("weights_mismatch", f"weights: not a loadable state dict: {type(exc).__name__}: "
                           f"{exc}") from exc
    if not isinstance(state, Mapping) or not all(isinstance(v, torch.Tensor) for v in state.values()):
        raise WeightsError("weights_mismatch", "weights: not a {name: tensor} state dict")
    try:
        with open(paths["hmm"], "rb") as f:
            doc = json.loads(f.read().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise WeightsError("weights_mismatch", f"hmm: not valid JSON: {exc}") from exc
    classes, hmm_block = validate_hmm_doc(doc)
    return dict(state), classes, hmm_block, digests


# ---------------------------------------------------------------------------
# Offline conversion (operator, install time; needs the upstream package)
# ---------------------------------------------------------------------------

def _as_list(a, dtype) -> list:
    import numpy as np
    return np.asarray(a, dtype=dtype).astype(np.float64).tolist()


def convert(source: str, dest: str, pin: PinnedFile = SOURCE) -> Dict[str, Dict[str, Any]]:
    """Unpickle the pinned upstream joblib (offline; ``actinet`` installed) and write the two converted files into
    ``dest``. The source is verified first; the unpickled object's network, labels and HMM are checked against what
    the adapter implements before anything is written. Returns ``{role: {file, sha256, size}}``."""
    import numpy as np
    import torch
    verify_file(source, pin)
    try:
        import joblib
        import actinet  # noqa: F401 - the pickle references actinet.models / actinet.hmm
    except ImportError as exc:
        raise WeightsError("model_missing", f"conversion needs the upstream package (actinet=={UPSTREAM_VERSION}) "
                           f"in an offline environment: {exc}") from exc
    clf = joblib.load(source)                                   # the one unpickle, offline
    cls = type(clf)
    if (cls.__module__, cls.__name__) != ("actinet.models", "ActivityClassifier"):
        raise WeightsError("weights_mismatch", f"unexpected pickled type {cls.__module__}.{cls.__name__}")
    if int(getattr(clf, "window_sec", -1)) != EPOCH_S or getattr(clf, "repo_tag", None) != SSL_WEARABLES_TAG:
        raise WeightsError("weights_mismatch", f"window_sec/repo_tag {getattr(clf, 'window_sec', None)!r}/"
                           f"{getattr(clf, 'repo_tag', None)!r} != {EPOCH_S}/{SSL_WEARABLES_TAG}")
    classes = [str(c) for c in np.asarray(clf.labels).tolist()]
    k = len(classes)
    h = clf.hmm
    hmm_block = {
        "labels": [int(v) for v in np.asarray(h.labels).tolist()],
        "prior": _as_list(h.prior, np.float64),
        "emission": _as_list(h.emission, np.float32),
        "transition": _as_list(h.transition, np.float64),
        "uniform_prior": bool(h.uniform_prior),
        "ignore_transition_gaps": bool(h.ignore_transition_gaps),
        "handle_sleep_transitions": bool(h.handle_sleep_transitions),   # fit-time only; recorded, unused
        "dtypes": {"prior": "float64", "emission": "float32", "transition": "float64"},
    }
    if np.asarray(h.emission).dtype != np.float32 or np.asarray(h.transition).dtype != np.float64:
        raise WeightsError("weights_mismatch", "HMM dtypes differ from the released artifact's (float32 emission, "
                           "float64 transition)")
    doc = {"schema": HMM_SCHEMA, "model_id": MODEL_ID, "model_version": MODEL_VERSION,
           "upstream": {"package": "actinet", "version": UPSTREAM_VERSION, "commit": UPSTREAM_COMMIT,
                        "classifier_key": UPSTREAM_CLASSIFIER_KEY},
           "source": {"file": pin.filename, "sha256": pin.sha256, "size": pin.size, "md5": pin.md5},
           "network": {"hub": f"OxWearables/ssl-wearables:{SSL_WEARABLES_TAG}", "entry": "harnet30",
                       "n_classes": k},
           "classes": classes, "window_sec": EPOCH_S, "hmm": hmm_block}
    validate_hmm_doc(json.loads(canonical_json(doc)))
    state = {name: t.detach().clone().contiguous() for name, t in clf.model_weights.items()}
    from .model import load_network
    load_network(state, k)                                      # strict: keys, shapes, dtypes, finite
    os.makedirs(dest, exist_ok=True)
    out = {}
    wpath = os.path.join(dest, WEIGHTS.filename)
    torch.save(state, wpath)
    hpath = os.path.join(dest, HMM.filename)
    with open(hpath, "wb") as f:
        f.write(canonical_json(doc))
    for role, path in (("weights", wpath), ("hmm", hpath)):
        out[role] = {"file": os.path.basename(path), "sha256": sha256_file(path), "size": os.path.getsize(path)}
    return out


def fetch(dest: str, pin: PinnedFile = SOURCE, retries: int = 5) -> str:
    """Download the pinned upstream joblib into ``dest`` (skipped when already verified); never used at serve time."""
    from ..fetch_artifacts import download
    os.makedirs(dest, exist_ok=True)
    path = os.path.join(dest, pin.filename)
    try:
        verify_file(path, pin)
        print(f"  {pin.filename}: present, verified", file=sys.stderr)
    except WeightsError:
        print(f"  {pin.filename}: downloading {pin.size} B from {pin.url}", file=sys.stderr)
        download(pin.url, path, pin.sha256, pin.size, retries=retries)
        verify_file(path, pin)
    return path


def manifest() -> Dict[str, Any]:
    return {"model_id": MODEL_ID, "model_version": MODEL_VERSION, "upstream_version": UPSTREAM_VERSION,
            "upstream_commit": UPSTREAM_COMMIT, "artifact_digest": artifact_digest(),
            "convert_env": CONVERT_ENV,
            "files": {pf.role: {"file": pf.filename, "sha256": pf.sha256, "size": pf.size,
                                **({"url": pf.url} if pf.url else {}), **({"md5": pf.md5} if pf.md5 else {})}
                      for pf in (SOURCE,) + CONVERTED}}


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ActiNet classifier artifacts (fetch / convert / verify / manifest)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="download the pinned upstream joblib (size + sha256 + md5 verified)")
    f.add_argument("--dest", required=True)
    c = sub.add_parser("convert", help="offline: unpickle the verified joblib once and write the pinned files")
    c.add_argument("--source", required=True, help="the fetched joblib.lzma")
    c.add_argument("--dest", default=None, help=f"output directory (default ${ARTIFACT_DIR_ENV})")
    v = sub.add_parser("verify", help="verify a converted artifact directory against the pins")
    v.add_argument("--dir", default=None, help=f"artifact directory (default ${ARTIFACT_DIR_ENV})")
    sub.add_parser("manifest", help="print the pins as JSON")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "manifest":
            print(json.dumps(manifest(), indent=2))
        elif args.cmd == "fetch":
            print(fetch(args.dest))
        elif args.cmd == "convert":
            dest = artifact_dir(args.dest)
            if not dest:
                ap.error(f"--dest or ${ARTIFACT_DIR_ENV} is required")
            print(json.dumps(convert(args.source, dest), indent=2))
        else:
            _, classes, _, _ = read_artifact(args.dir)
            print(json.dumps({"ok": True, "classes": list(classes), "artifact_digest": artifact_digest()}))
    except WeightsError as exc:
        print(f"[actinet_classifier.weights] {exc.kind}: {exc.message}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
