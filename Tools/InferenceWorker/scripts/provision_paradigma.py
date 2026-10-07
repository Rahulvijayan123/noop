#!/usr/bin/env python
"""Provision the ParaDigMa classifier assets into a local artifact root.

Downloads the three real pretrained classifier packages from the PINNED
upstream tree (biomarkersParkinson/paradigma commit
4735d6d21b2a62b764a0bc7e0f677577e6ce1668), verifies each byte blob's
sha256 + size against the measured values below, stages them under the
artifact root, and records provenance (source URL, pinned commit, filename,
sha256, size, license) plus a ready-to-merge ``models/manifest.json`` entry.

PROVISIONING ONLY - this script NEVER runs at inference time. The sidecar
only reads the staged, manifest-verified bytes.

Usage (network mode, from Tools/InferenceWorker):

    uv run python scripts/provision_paradigma.py --dest /tmp/frwhoop-sensor-biomarkers/models

Offline mode (copy from a local pinned clone - used by tests):

    uv run python scripts/provision_paradigma.py --dest <root> --from-tree <clone-dir>

Prints the destination root on success; exits non-zero with a reason on
failure. No weights are committed anywhere in the checkout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

#: Pinned upstream tree (resolved clone HEAD, 2026-10-06).
UPSTREAM_COMMIT = "4735d6d21b2a62b764a0bc7e0f677577e6ce1668"
UPSTREAM_REPO = "https://github.com/biomarkersParkinson/paradigma"
RAW_BASE = (
    "https://raw.githubusercontent.com/biomarkersParkinson/paradigma/"
    f"{UPSTREAM_COMMIT}/src/paradigma/assets"
)
LICENSE = "Apache-2.0"

#: Measured from the actual downloaded bytes at the pinned commit.
#: tremor sha256 cross-checks the value published in docs/sensor-biomarkers/CONTRACTS.md.
ASSETS = {
    "tremor_detection_clf_package.pkl": {
        "sha256": "4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e",
        "size_bytes": 1475,
    },
    "gait_detection_clf_package.pkl": {
        "sha256": "f2309bb8cff87648a54a338493db2cedb25b4a9a60cd77bbdb2d17e010a7cc25",
        "size_bytes": 11497247,
    },
    "gait_filtering_clf_package.pkl": {
        "sha256": "94068bca1997755e17fddae662dd0433ac06c12a3cd32869c6d9dc586ab845f4",
        "size_bytes": 3915,
    },
}


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def download_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "frwhoop-provision"})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", default=os.environ.get("FRWHOOP_MODEL_ROOT",
                        "/tmp/frwhoop-sensor-biomarkers/models"))
    parser.add_argument("--from-tree", default=None,
                        help="copy assets from a local pinned clone (offline mode)")
    args = parser.parse_args(argv)

    dest = os.path.abspath(args.dest)
    rel_dir = os.path.join("paradigma", UPSTREAM_COMMIT)
    asset_dir = os.path.join(dest, rel_dir)
    os.makedirs(asset_dir, exist_ok=True)

    artifacts = []
    for name, expected in ASSETS.items():
        target = os.path.join(asset_dir, name)
        if args.from_tree:
            src = os.path.join(args.from_tree, "src", "paradigma", "assets", name)
            if not os.path.isfile(src):
                sys.stderr.write(f"source tree missing {name}\n")
                return 1
            blob = open(src, "rb").read()
        else:
            url = f"{RAW_BASE}/{name}"
            sys.stderr.write(f"downloading {name} ({expected['size_bytes']} bytes)...\n")
            blob = download_bytes(url)

        # Verify the bytes BEFORE staging anything: never write unverified bytes.
        actual_sha = hashlib.sha256(blob).hexdigest()
        if actual_sha != expected["sha256"]:
            sys.stderr.write(f"{name}: sha256 {actual_sha} != {expected['sha256']}\n")
            return 1
        if len(blob) != expected["size_bytes"]:
            sys.stderr.write(f"{name}: size {len(blob)} != {expected['size_bytes']}\n")
            return 1
        with open(target, "wb") as out:
            out.write(blob)
        artifacts.append({
            "name": name,
            "path": os.path.join(rel_dir, name),
            "url": f"{RAW_BASE}/{name}",
            "size_bytes": expected["size_bytes"],
            "sha256": expected["sha256"],
            "verify_at_startup": True,
            "required_for_readiness": True,
        })
        print(f"provisioned {name} -> {target} ({actual_sha[:12]}...)")

    provenance = {
        "artifact_id": "paradigma",
        "upstream_repo": UPSTREAM_REPO,
        "pinned_commit": UPSTREAM_COMMIT,
        "resolved_commit_sha": UPSTREAM_COMMIT,
        "license": LICENSE,
        "license_evidence": "repo LICENSE file is Apache License 2.0",
        "provisioned_at_utc": datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "real upstream pretrained classifier packages, not a reimplementation",
        "artifacts": artifacts,
    }
    with open(os.path.join(dest, "paradigma", "provenance.json"), "w") as out:
        json.dump(provenance, out, indent=2)

    entry = {
        "id": "paradigma",
        "kind": "model_checkpoint",
        "name": "ParaDigMa 1.1.2 tremor/gait/gait-filtering classifiers",
        "revision": "1.1.2",
        "source_url": UPSTREAM_REPO,
        "tag_commit": UPSTREAM_COMMIT,
        "license": LICENSE,
        "license_evidence": "repo LICENSE is Apache License 2.0",
        "rights_verdict": "clear",
        "status": "eligible",
        "status_reason": "real pinned inference executed 2026-10-06; classifier "
                        "assets verified by sha256; portability to WHOOP unverified "
                        "(research tier)",
        "provider_id": "sensor.biomarkers.paradigma.v1",
        "wired": True,
        "input_contract": "prepared IMU DataFrame with time (relative s), "
                          "accelerometer_x/y/z (g), gyroscope_x/y/z (deg/s); "
                          "run_paradigma via the narrow subprocess env; "
                          "gait requires verified watch_side + device_orientation "
                          "+ verified WHOOP axis convention",
        "artifacts": artifacts,
        "required_for_readiness": True,
        "accuracy_label": "unverified_accuracy",
        "runtime_note": "executed in the narrow optional subprocess venv "
                        "(python 3.12, numpy 2.5.3, scipy 1.18.1, pandas 2.3.3, "
                        "scikit-learn 1.6.0) because the main env pins "
                        "scikit-learn 1.9.1 (outside paradigma's <1.6.1 range)",
    }
    with open(os.path.join(dest, "paradigma", "manifest-entry.json"), "w") as out:
        json.dump(entry, out, indent=2)

    print(f"MODEL_ROOT {dest}")
    print(f"provenance: {os.path.join(dest, 'paradigma', 'provenance.json')}")
    print(f"manifest entry (parent merges into models/manifest.json): "
          f"{os.path.join(dest, 'paradigma', 'manifest-entry.json')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
