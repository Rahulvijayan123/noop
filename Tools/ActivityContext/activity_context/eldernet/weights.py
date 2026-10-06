"""Pinned ElderNet weights: manifest, resolution from a weights directory, verified fetch (ELDERNET.md §1).

The six fine-tuned heads are committed in the upstream repository (plain git blobs, ~44 MB each) at
``UPSTREAM_COMMIT``. Nara never commits them: an operator either points ``ELDERNET_WEIGHTS_DIR`` (or
``--weights-dir``) at a directory holding the files, or runs the separate fetch CLI, which downloads them
from GitHub raw at the pinned commit and verifies size + sha256::

    python -m activity_context.eldernet.weights fetch --dest <dir>
    python -m activity_context.eldernet.weights verify --dir <dir>

The serve process never downloads: it only resolves and verifies. Any missing file is ``model_missing``,
any size/sha mismatch ``weights_mismatch`` (:class:`WeightsError`), refused before ``torch.load``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Dict, Mapping, Optional, Sequence

from . import HEAD_NAMES, UPSTREAM_COMMIT

WEIGHTS_DIR_ENV = "ELDERNET_WEIGHTS_DIR"
RAW_BASE = f"https://raw.githubusercontent.com/yonbrand/gait-quality/{UPSTREAM_COMMIT}/"


@dataclass(frozen=True)
class WeightFile:
    name: str            # head name (upstream config key)
    upstream_path: str   # path inside the upstream repository
    sha256: str
    size: int

    @property
    def filename(self) -> str:
        return os.path.basename(self.upstream_path)

    @property
    def url(self) -> str:
        return RAW_BASE + self.upstream_path


# sha256 / size measured on the pinned commit (audit 2026-10-06; md5 prefixes equal upstream examples/README.md).
MANIFEST: Dict[str, WeightFile] = {w.name: w for w in (
    WeightFile("gait_detection", "weights/gait_detection_weights.pt",
               "056f22994313d26161041f9b20b3c5045659b1e41bd6454c06ccc904ce3d1988", 44734111),
    WeightFile("gait_speed", "weights/gait_speed_weights.pt",
               "731e0297072c0d317d6e5e273112a013360cff01d542d1c7bef96b1a5c565929", 44734819),
    WeightFile("cadence", "weights/cadence_weights.pt",
               "17fff2e11b1bc49dc0dcb98b0d2c8e9beadb9f6e459044c4fff2f4d3f4d115ac", 44770673),
    WeightFile("gait_length", "weights/gait_length_weights.pt",
               "a8472562a9f6cfc9b17829296f870b9ca0a0d88a79a6459c803ae42593fd5f25", 44770673),
    WeightFile("regularity", "weights/regularity_weights.pt",
               "ad42c4a3a8c21551efd30d8e26015a29f2804d7dafa0b8793e719c193a77aa2a", 44768039),
    WeightFile("step_count", "weights/step_count_weights.pt",
               "8dfe83ee40d2ac64b74af15cdf53c96968af618b496793016c100fd9bbe0f1a6", 44770673),
)}
assert tuple(MANIFEST) == HEAD_NAMES

# Upstream files that are NOT loaded (SSL pre-training checkpoints), recorded for the audit only.
UNUSED_UPSTREAM_FILES = {
    "weights/ssl_eldernet_weights.mdl": "b9fde649ccf0d207772654b1701b204adfa00b6e12741edee22df6e8528329c3",
    "weights/ssl_ukb_weights.mdl": "c64f9135d99e2dcdfc9ae7cc0672f2bcc438df9ceb8215665882f92cddd162a6",
}


class WeightsError(RuntimeError):
    """``kind`` is ``model_missing`` (file absent / no directory) or ``weights_mismatch`` (size or sha256)."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message


def sha256_file(path: str) -> str:
    from ..fetch_artifacts import sha256_file as _sha
    return _sha(path)


def weights_dir(explicit: Optional[str] = None) -> str:
    """The explicit directory, else ``$ELDERNET_WEIGHTS_DIR``; "" when neither is set (never a guess)."""
    return (explicit or os.environ.get(WEIGHTS_DIR_ENV, "")).strip()


def verify_file(path: str, wf: WeightFile) -> str:
    if not os.path.isfile(path):
        raise WeightsError("model_missing", f"{wf.name}: {path} not found")
    size = os.path.getsize(path)
    if size != wf.size:
        raise WeightsError("weights_mismatch", f"{wf.name}: {path} is {size} bytes, pinned {wf.size}")
    digest = sha256_file(path)
    if digest != wf.sha256:
        raise WeightsError("weights_mismatch", f"{wf.name}: sha256 {digest[:16]}… != pinned {wf.sha256[:16]}…")
    return digest


def resolve(directory: Optional[str] = None, manifest: Mapping[str, WeightFile] = MANIFEST,
            names: Sequence[str] = HEAD_NAMES) -> Dict[str, str]:
    """name -> verified path. ``directory`` may hold the files flat or as ``weights/<file>``."""
    d = weights_dir(directory)
    if not d:
        raise WeightsError("model_missing", f"no weights directory: set ${WEIGHTS_DIR_ENV} or pass --weights-dir "
                           f"(fetch with: python -m activity_context.eldernet.weights fetch --dest <dir>)")
    if not os.path.isdir(d):
        raise WeightsError("model_missing", f"weights directory {d} does not exist")
    out: Dict[str, str] = {}
    for name in names:
        wf = manifest[name]
        flat, nested = os.path.join(d, wf.filename), os.path.join(d, wf.upstream_path)
        path = flat if os.path.isfile(flat) else nested
        verify_file(path, wf)
        out[name] = path
    return out


def wire_hashes(manifest: Mapping[str, WeightFile] = MANIFEST) -> Dict[str, str]:
    return {name: wf.sha256 for name, wf in manifest.items()}


WEIGHTS_DIGEST_PREFIX = "eldernet-weights-1\n"


def weights_digest(weights: Mapping[str, str]) -> str:
    """The deployment pin over a ``weights`` map (ELDERNET.md §5): sha256 of ``eldernet-weights-1\\n`` followed by
    ``name=sha256\\n`` per head in name order — the same text Swift ``GaitQualityModelInfo.weightsDigest`` and the
    SQL ``publish_activity_gait_windows_day`` check hash."""
    import hashlib
    text = WEIGHTS_DIGEST_PREFIX + "".join(f"{k}={v}\n" for k, v in sorted(weights.items()))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# The pinned deployment digest of the six heads (= weights_digest(wire_hashes()); asserted by the tests).
DEPLOYMENT_WEIGHTS_DIGEST = "01b2f982a0a2664f455a529a8c483a10106a7ddcd89c326e3d15e24fa4cf4ca6"


def fetch(dest: str, manifest: Mapping[str, WeightFile] = MANIFEST, retries: int = 5) -> Dict[str, str]:
    """Download every pinned file into ``dest`` (skipping ones already verified); never used at serve time."""
    from ..fetch_artifacts import download
    os.makedirs(dest, exist_ok=True)
    out = {}
    for name, wf in manifest.items():
        path = os.path.join(dest, wf.filename)
        try:
            verify_file(path, wf)
            print(f"  {wf.filename}: present, sha256 ok", file=sys.stderr)
        except WeightsError:
            print(f"  {wf.filename}: downloading {wf.size} B from {wf.url}", file=sys.stderr)
            download(wf.url, path, wf.sha256, wf.size, retries=retries)
        out[name] = path
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet pinned weights (fetch / verify / manifest)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="download the six heads at the pinned commit, sha256-verified")
    f.add_argument("--dest", default=None, help=f"target directory (default ${WEIGHTS_DIR_ENV})")
    v = sub.add_parser("verify", help="verify a weights directory against the pinned manifest")
    v.add_argument("--dir", default=None, help=f"weights directory (default ${WEIGHTS_DIR_ENV})")
    sub.add_parser("manifest", help="print the pinned manifest as JSON")
    args = ap.parse_args(argv)
    if args.cmd == "manifest":
        print(json.dumps({"upstream_commit": UPSTREAM_COMMIT, "weights_digest": weights_digest(wire_hashes()),
                          "files": {n: {"upstream_path": w.upstream_path, "sha256": w.sha256, "size": w.size,
                                        "url": w.url} for n, w in MANIFEST.items()}}, indent=2))
        return 0
    try:
        if args.cmd == "fetch":
            dest = weights_dir(args.dest)
            if not dest:
                ap.error(f"--dest or ${WEIGHTS_DIR_ENV} is required")
            fetch(dest)
        else:
            for name, path in resolve(args.dir).items():
                print(f"  {name}: {path} ok", file=sys.stderr)
    except WeightsError as exc:
        print(f"[eldernet.weights] {exc.kind}: {exc.message}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
