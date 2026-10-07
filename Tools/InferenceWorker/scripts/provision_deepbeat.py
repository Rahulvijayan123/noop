#!/usr/bin/env python
"""Provision the DeepBeat rhythm shadow artifact (GPL-3.0) into the artifact root.

Downloads ``deepbeat.h5`` from the AshleyLab/deepbeat repository at the pinned
commit, verifies sha256 and size from the ACTUAL downloaded bytes, and stages
the file under the artifact root. NEVER run at inference time: inference only
reads already-staged, checksum-verified bytes.

Usage (from Tools/InferenceWorker):

    uv run python scripts/provision_deepbeat.py [--root <artifact-root>]

The root defaults to ``FRWHOOP_MODEL_ROOT`` if set, else
``/tmp/frwhoop-sensor-biomarkers/models`` (gitignored local staging). On
success it prints the manifest entry the parent merges into
``models/manifest.json``.

License: the released weights and repository code are GPL-3.0; the training
dataset is shared under a separate non-commercial data use agreement (Synapse
syn21985690) and is NOT downloaded here. No dataset is required for
inference-only use.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request

UPSTREAM_REPO = "https://github.com/AshleyLab/deepbeat"
PINNED_COMMIT = "f54004a80eaca99460d1e171c8ec203e182dacb9"
FILENAME = "deepbeat.h5"
EXPECTED_SHA256 = "6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3"
EXPECTED_SIZE = 1_502_052
DEFAULT_ROOT = "/tmp/frwhoop-sensor-biomarkers/models"

#: Relative path under the artifact root (matches the adapter + manifest entry).
RELPATH = f"deepbeat/{PINNED_COMMIT[:10]}/{FILENAME}"


def _sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_ROOT)
    parser.add_argument("--force", action="store_true",
                        help="re-download even when a verified copy already exists")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    target = os.path.join(root, RELPATH)
    if os.path.isfile(target) and not args.force:
        actual = _sha256_file(target)
        if actual == EXPECTED_SHA256 and os.path.getsize(target) == EXPECTED_SIZE:
            print(f"already verified at {target} ({actual[:12]}...)")
            return _print_entry(root)

    url = f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{FILENAME}"
    print(f"downloading {url}")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".part"
    with urllib.request.urlopen(url, timeout=300) as response, open(tmp, "wb") as out:
        while True:
            block = response.read(1 << 20)
            if not block:
                break
            out.write(block)
    size = os.path.getsize(tmp)
    actual = _sha256_file(tmp)
    if size != EXPECTED_SIZE:
        os.unlink(tmp)
        sys.stderr.write(f"size mismatch: got {size}, expected {EXPECTED_SIZE}\n")
        return 1
    if actual != EXPECTED_SHA256:
        os.unlink(tmp)
        sys.stderr.write(f"sha256 mismatch: got {actual}, expected {EXPECTED_SHA256}\n")
        return 1
    os.replace(tmp, target)
    print(f"staged {target} ({size} bytes, sha256 {actual})")
    return _print_entry(root)


def _print_entry(root: str) -> int:
    entry = {
        "id": "deepbeat",
        "kind": "model_checkpoint",
        "name": "DeepBeat deepbeat.h5",
        "revision": PINNED_COMMIT,
        "revision_date": "2026-10-06",
        "source_url": f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{FILENAME}",
        "license": "GPL-3.0",
        "license_evidence": "AshleyLab/deepbeat LICENSE file is GPL-3.0; dataset terms separate (Synapse syn21985690, non-commercial DUA)",
        "rights_verdict": "shadow_eligible",
        "status": "shadow_eligible",
        "status_reason": "disabled-by-default research shadow adapter; preprocessing pipeline unresolved so outputs are preprocessing_unverified and nonpublishable; inference-only load verified in keras 3 + torch backend with TF2 parity",
        "provider_id": "sensor.biomarkers.rhythm.v1",
        "wired": True,
        "input_contract": "(batch, 800, 1) float32 = 25 s PPG at 32 Hz; outputs qa(3 softmax: poor=0 acceptable=1 excellent=2) + rhythm(2 sigmoid: non-AF=0 AF=1)",
        "artifacts": [
            {
                "name": FILENAME,
                "path": RELPATH,
                "url": f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{FILENAME}",
                "size_bytes": EXPECTED_SIZE,
                "sha256": EXPECTED_SHA256,
                "verify_at_startup": True,
            }
        ],
        "required_for_readiness": False,
        "accuracy_label": "unverified_accuracy",
    }
    print(json.dumps({"deepbeat": entry}, indent=2))
    print(f"staged_under: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
