#!/usr/bin/env python
"""Materialize the sleep-staging artifact root from the INSTALLED wheel.

This mirrors the pytest fixture ``sleep_model_root`` in
``Tools/InferenceWorker/tests/conftest.py``: the SleepECG checkpoint ships inside
the ``sleepecg`` wheel, so the bytes are already on disk after ``uv sync``. The
script copies them to the manifest paths under a caller-supplied root and asserts
both sha256 digests against ``models/manifest.json``.

No network access, nothing written into the checkout, no weights committed.

Usage (from Tools/InferenceWorker, so the project venv is used):

    uv run python scripts/materialize_model_root.py <dest-root>

Prints the destination root on success; exits non-zero with a reason on failure.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys
import zipfile

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(PACKAGE_ROOT, "models", "manifest.json")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    dest = os.path.abspath(argv[1])

    import sleepecg

    from frwhoop_inference.artifacts import load_manifest, verify_manifest

    entries = {e["id"]: e for e in load_manifest(MANIFEST_PATH)["entries"]}
    entry = entries.get("sleepecg_wrn_gru_mesa")
    if entry is None:
        sys.stderr.write("manifest has no sleepecg_wrn_gru_mesa entry\n")
        return 1

    source_zip = os.path.join(os.path.dirname(sleepecg.__file__), "classifiers", "wrn-gru-mesa.zip")
    if not os.path.isfile(source_zip):
        sys.stderr.write(f"the installed wheel has no bundled checkpoint at {source_zip}\n")
        return 1

    os.makedirs(dest, exist_ok=True)
    for artifact in entry["artifacts"]:
        target = os.path.join(dest, artifact["path"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if artifact["name"] == "wrn-gru-mesa.zip":
            shutil.copyfile(source_zip, target)
        else:
            with zipfile.ZipFile(source_zip) as archive:
                with archive.open("classifier.keras") as handle:
                    with open(target, "wb") as out:
                        out.write(handle.read())
        digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
        if digest != artifact["sha256"]:
            sys.stderr.write(f"{artifact['name']}: sha256 mismatch ({digest})\n")
            return 1
        if os.path.getsize(target) != artifact["size_bytes"]:
            sys.stderr.write(f"{artifact['name']}: size mismatch\n")
            return 1
        print(f"materialized {artifact['name']} -> {target} ({digest[:12]}...)")

    state = verify_manifest(load_manifest(MANIFEST_PATH), dest, manifest_path=MANIFEST_PATH)
    if state.ok is not True:
        sys.stderr.write(f"verify_manifest rejected the root: {state.reason}\n")
        return 1
    print(f"MODEL_ROOT {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
