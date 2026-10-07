#!/usr/bin/env python
"""Provision the SiamAF rhythm shadow artifact (MIT) into the artifact root.

Downloads ``proposed/saved_models/final_model.pt`` from the chengstark/SiamAF
repository at the pinned commit, verifies sha256 and size from the ACTUAL
downloaded bytes, and stages the file under the artifact root. NEVER run at
inference time: inference only reads already-staged, checksum-verified bytes.

Usage (from Tools/InferenceWorker):

    uv run python scripts/provision_siamaf.py [--root <artifact-root>]

The root defaults to ``FRWHOOP_MODEL_ROOT`` if set, else
``/tmp/frwhoop-sensor-biomarkers/models`` (gitignored local staging). On
success it prints the manifest entry the parent merges into
``models/manifest.json``.

License: MIT (repository LICENSE, Copyright (c) 2024 Zhicheng Guo). Training
data (Institution A bedside monitors) is private and not part of this adapter.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request

UPSTREAM_REPO = "https://github.com/chengstark/SiamAF"
PINNED_COMMIT = "c05be9e37d2013d0817aafc5b2e72b2f7649e95e"
FILENAME = "final_model.pt"
UPSTREAM_PATH = "proposed/saved_models/final_model.pt"
EXPECTED_SHA256 = "a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be"
EXPECTED_SIZE = 10_915_597
DEFAULT_ROOT = "/tmp/frwhoop-sensor-biomarkers/models"

RELPATH = f"siamaf/{PINNED_COMMIT[:10]}/{FILENAME}"


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

    url = f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{UPSTREAM_PATH}"
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
        "id": "siamaf",
        "kind": "model_checkpoint",
        "name": "SiamAF final_model.pt",
        "revision": PINNED_COMMIT,
        "revision_date": "2026-10-06",
        "source_url": f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{UPSTREAM_PATH}",
        "license": "MIT",
        "license_evidence": "repository LICENSE (Copyright (c) 2024 Zhicheng Guo)",
        "rights_verdict": "clear",
        "status": "shadow_eligible",
        "status_reason": "optional shadow comparator; preprocessing verified from source (scipy.signal.resample to 2400 + min-max); WHOOP native-rate domain mismatch and WHOOP/ECG release gate keep scores nonpublishable",
        "provider_id": "sensor.biomarkers.rhythm.v1",
        "wired": True,
        "input_contract": "(batch, 1, 2400) float32 = 30 s PPG; per-segment min-max; two logits non-AF=0/AF=1 via classification_head; forward takes two arguments (wrapper passes the unused second)",
        "artifacts": [
            {
                "name": FILENAME,
                "path": RELPATH,
                "url": f"{UPSTREAM_REPO}/raw/{PINNED_COMMIT}/{UPSTREAM_PATH}",
                "size_bytes": EXPECTED_SIZE,
                "sha256": EXPECTED_SHA256,
                "verify_at_startup": True,
            }
        ],
        "required_for_readiness": False,
        "accuracy_label": "unverified_accuracy",
    }
    print(json.dumps({"siamaf": entry}, indent=2))
    print(f"staged_under: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
