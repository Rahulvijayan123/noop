"""Pinned RecGym checkpoint: the archive, the member, resolution, verification and the operator fetch (RECGYM.md §1).

Upstream commits ``models.zip`` (nine PyTorch state dicts) at ``UPSTREAM_COMMIT``. The head uses one member,
``models/wrist_-_imu_only_best.pt`` (wrist, IMU only, 6 input channels, 12 classes). Nara never commits it. The
deployment path is the sidecar model manifest (``Tools/InferenceWorker/models/manifest.json`` entry
``recgym_cnn_transformer``: the archive by url + sha256, the member by ``zip_member``), which ``deploy/provision.sh``
stages into ``/opt/frwhoop-models/current/recgym/e085ac0e/``. For a host without the provisioner there is a fetch
CLI that does the same thing into a directory::

    python -m activity_context.recgym.weights fetch --dest <dir>
    python -m activity_context.recgym.weights verify --path <dir or file>

The serve process never downloads: it resolves ``--weights-path`` / ``$RECGYM_WEIGHTS_PATH`` (the file, or a
directory holding it flat or as ``models/<file>``) and checks size and sha256 before ``torch.load``. A missing file
is ``model_missing``; any size or digest mismatch ``weights_mismatch`` (:class:`WeightsError`).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Optional, Sequence

from . import UPSTREAM_COMMIT

WEIGHTS_PATH_ENV = "RECGYM_WEIGHTS_PATH"


@dataclass(frozen=True)
class PinnedFile:
    name: str
    path: str            # path inside the upstream repository (archive) or the archive (member)
    sha256: str
    size: int


# Measured on the pinned commit (2026-10-09): the archive from raw.githubusercontent.com equals the clone's bytes.
ARCHIVE = PinnedFile("models.zip", "models.zip",
                     "eb779a1fbf5af2db76c8babbfd3e4d8162d9e677738215db5c03f5c2fe4cdfe8", 6321334)
ARCHIVE_URL = f"https://raw.githubusercontent.com/MKorp7/HAR_IMU_CNN-Transformer/{UPSTREAM_COMMIT}/models.zip"
CHECKPOINT = PinnedFile("wrist_-_imu_only_best.pt", "models/wrist_-_imu_only_best.pt",
                        "7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9", 774140)
# Where the provisioner stages it under the model root (the sidecar manifest's artifact path).
MODEL_ROOT_RELPATH = f"recgym/{UPSTREAM_COMMIT[:8]}/{CHECKPOINT.name}"


class WeightsError(RuntimeError):
    """``kind`` is ``model_missing`` (no file / nothing configured) or ``weights_mismatch`` (size or sha256)."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message


def sha256_file(path: str) -> str:
    from ..loaded import file_sha256
    return file_sha256(path)


def configured_path(explicit: Optional[str] = None) -> str:
    """The explicit path, else ``$RECGYM_WEIGHTS_PATH``; "" when neither is set (never a guess)."""
    return (explicit or os.environ.get(WEIGHTS_PATH_ENV, "")).strip()


def verify_file(path: str, pin: PinnedFile = CHECKPOINT) -> str:
    """Size, then sha256, of ``path`` against ``pin``; returns the measured digest."""
    if not os.path.isfile(path):
        raise WeightsError("model_missing", f"{pin.name}: {path} not found")
    size = os.path.getsize(path)
    if size != pin.size:
        raise WeightsError("weights_mismatch", f"{pin.name}: {path} is {size} bytes, pinned {pin.size}")
    digest = sha256_file(path)
    if digest != pin.sha256:
        raise WeightsError("weights_mismatch", f"{pin.name}: sha256 {digest[:16]}… != pinned {pin.sha256[:16]}…")
    return digest


def resolve_measured(path: Optional[str] = None) -> tuple:
    """(verified checkpoint path, sha256 measured from its bytes). ``path`` is the file or a directory holding it
    flat or as ``models/<file>``."""
    p = configured_path(path)
    if not p:
        raise WeightsError("model_missing", f"no checkpoint configured: set ${WEIGHTS_PATH_ENV} or pass "
                           f"--weights-path (fetch with: python -m activity_context.recgym.weights fetch --dest <dir>)")
    if os.path.isdir(p):
        flat, nested = os.path.join(p, CHECKPOINT.name), os.path.join(p, CHECKPOINT.path)
        p = flat if os.path.isfile(flat) else nested
    return p, verify_file(p)


def extract_member(archive_path: str, dest_path: str) -> str:
    """Verify the archive, extract the pinned member (size-capped) to ``dest_path`` and verify it."""
    import zipfile
    verify_file(archive_path, ARCHIVE)
    with zipfile.ZipFile(archive_path) as z:
        info = z.getinfo(CHECKPOINT.path)
        if info.file_size != CHECKPOINT.size:
            raise WeightsError("weights_mismatch", f"{CHECKPOINT.path} is {info.file_size} bytes in the archive")
        tmp = dest_path + ".part"
        with z.open(info) as src, open(tmp, "wb") as out:
            out.write(src.read(CHECKPOINT.size + 1))
    try:
        verify_file(tmp)
    except WeightsError:
        os.unlink(tmp)
        raise
    os.replace(tmp, dest_path)
    return dest_path


def fetch(dest: str, retries: int = 5) -> str:
    """Download the archive at the pinned commit (sha256-verified), extract the member; never used at serve time."""
    from ..fetch_artifacts import download
    os.makedirs(dest, exist_ok=True)
    target = os.path.join(dest, CHECKPOINT.name)
    try:
        verify_file(target)
        print(f"  {CHECKPOINT.name}: present, sha256 ok", file=sys.stderr)
        return target
    except WeightsError:
        pass
    archive = os.path.join(dest, ARCHIVE.name)
    try:
        verify_file(archive, ARCHIVE)
    except WeightsError:
        print(f"  {ARCHIVE.name}: downloading {ARCHIVE.size} B from {ARCHIVE_URL}", file=sys.stderr)
        download(ARCHIVE_URL, archive, ARCHIVE.sha256, ARCHIVE.size, retries=retries)
    return extract_member(archive, target)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="RecGym pinned checkpoint (fetch / verify / manifest)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="download models.zip at the pinned commit and extract the wrist IMU checkpoint")
    f.add_argument("--dest", required=True, help="target directory")
    v = sub.add_parser("verify", help="verify a checkpoint file or directory against the pin")
    v.add_argument("--path", default=None, help=f"file or directory (default ${WEIGHTS_PATH_ENV})")
    sub.add_parser("manifest", help="print the pins as JSON")
    args = ap.parse_args(argv)
    if args.cmd == "manifest":
        print(json.dumps({"upstream_commit": UPSTREAM_COMMIT, "archive_url": ARCHIVE_URL,
                          "archive": ARCHIVE.__dict__, "checkpoint": CHECKPOINT.__dict__,
                          "model_root_relpath": MODEL_ROOT_RELPATH}, indent=2))
        return 0
    try:
        if args.cmd == "fetch":
            print(fetch(args.dest))
        else:
            path, digest = resolve_measured(args.path)
            print(f"  {path}: sha256 {digest} ok", file=sys.stderr)
    except WeightsError as exc:
        print(f"[recgym.weights] {exc.kind}: {exc.message}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
