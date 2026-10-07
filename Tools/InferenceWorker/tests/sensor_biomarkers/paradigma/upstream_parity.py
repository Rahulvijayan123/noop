"""Upstream reference parity check (runs in the narrow paradigma venv).

Executed by the main-env test suite through the venv python:

    <paradigma-venv>/bin/python upstream_parity.py <fixtures_dir> > result.json

Loads the vendored upstream reference features (tsdf float64 columnar bins)
and reference predictions, verifies the exact wheel asset bytes that the
pipeline will unpickle against the pinned sha256 digests, runs the REAL
classifiers, and prints:

    {"ok": true, "tremor": {"max_diff": ..., "n": ...}, "gait": {...},
     "arm_activity": {...}}

These are independent numerical expectations: the reference values are the
upstream published predictions at the pinned commit (Apache-2.0 fixtures
vendored with attribution in fixtures/PROVENANCE.md), produced by upstream's
own test suite (test_tremor_analysis.py / test_gait_analysis.py, which pass
against this pinned tree).
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

import numpy as np
import pandas as pd

from paradigma.classification import ClassifierPackage
from paradigma.config import GaitConfig, TremorConfig
from paradigma.pipelines.gait_pipeline import detect_gait, filter_gait
from paradigma.pipelines.tremor_pipeline import detect_tremor

#: Pinned sha256 of the exact bytes the pipeline unpickles (wheel assets).
ASSET_DIGESTS = {
    "tremor_detection_clf_package.pkl": "4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e",
    "gait_detection_clf_package.pkl": "f2309bb8cff87648a54a338493db2cedb25b4a9a60cd77bbdb2d17e010a7cc25",
    "gait_filtering_clf_package.pkl": "94068bca1997755e17fddae662dd0433ac06c12a3cd32869c6d9dc586ab845f4",
}


def asset_traversable(name: str):
    """The traversable/str path of one wheel asset.

    Default: the installed wheel's ``paradigma.assets`` member (verified
    against the pinned digests). ``PARADIGMA_ASSET_ROOT`` overrides the
    directory for the corruption tests ONLY - a scratch layout never touches
    the real venv - and the same sha256 verification gate applies to it.
    """
    override = os.environ.get("PARADIGMA_ASSET_ROOT")
    if override:
        return os.path.join(override, name)
    from importlib.resources import files

    return files("paradigma.assets").joinpath(name)


def verify_wheel_assets() -> dict:
    verified = {}
    for name, expected in ASSET_DIGESTS.items():
        path = asset_traversable(name)
        blob = path.read_bytes() if hasattr(path, "read_bytes") else open(path, "rb").read()
        actual = hashlib.sha256(blob).hexdigest()
        if actual != expected:
            raise SystemExit(f"asset {name}: sha256 {actual} != {expected}; refusing to unpickle")
        verified[name] = actual
    return verified


def _clf_path(name: str) -> str:
    """A real filesystem path for the upstream classifier loaders."""
    import importlib.resources as _res

    override = os.environ.get("PARADIGMA_ASSET_ROOT")
    if override:
        return os.path.join(override, name)
    pkg_dir = os.path.dirname(__import__("paradigma").__file__)
    return os.path.join(pkg_dir, "assets", name)


def load_tsdf(meta_path, fixture_dir):
    """Decode the tsdf float64 columnar fixture independently of the tsdf package."""
    meta = json.load(open(meta_path))
    rows = meta["rows"]
    out = {}
    # Vendored file names are <dir>__<basename>, e.g.
    # "3.extracted_features__tremor__tremor_meta.json" -> dir prefix
    # "3.extracted_features__tremor". Meta basenames contain no double
    # underscore, so the last "__" split is unambiguous.
    meta_name = os.path.basename(meta_path)
    prefix = meta_name.rsplit("__", 1)[0]
    for sensor in meta["sensors"]:
        fn = sensor["file_name"]
        full = os.path.join(fixture_dir, f"{prefix}__{fn}")
        if not os.path.isfile(full):
            raise SystemExit(f"fixture {fn} not found under {fixture_dir} (wanted {full})")
        arr = np.fromfile(full, dtype="<f8").reshape(rows, len(sensor["channels"]))
        for i, ch in enumerate(sensor["channels"]):
            out[ch] = arr[:, i]
    return pd.DataFrame(out)


def main(argv):
    if len(argv) != 2:
        print(json.dumps({"ok": False, "errors": ["usage: upstream_parity.py <fixtures_dir>"]}))
        return 2
    fixtures = argv[1]
    verify_wheel_assets()

    result = {"ok": True, "errors": []}

    # -- tremor detection parity -----------------------------------------
    tremor_features = load_tsdf(os.path.join(fixtures, "3.extracted_features__tremor__tremor_meta.json"), fixtures)
    tremor_ref = load_tsdf(os.path.join(fixtures, "4.predictions__tremor__tremor_meta.json"), fixtures)
    pred = detect_tremor(tremor_features.copy(), TremorConfig(),
                         _clf_path("tremor_detection_clf_package.pkl"))
    tremor_result = {"n": int(len(tremor_ref))}
    for col in ["pred_tremor_proba", "pred_tremor_logreg", "pred_tremor_checked", "pred_arm_at_rest"]:
        ours = pred[col].to_numpy(dtype=float)
        theirs = tremor_ref[col].to_numpy(dtype=float)
        tremor_result[col] = float(np.max(np.abs(ours - theirs))) if ours.size else 0.0
        if not np.allclose(ours, theirs, atol=1e-6, rtol=0):
            result["ok"] = False
            result["errors"].append(f"tremor {col} exceeds tolerance")
    result["tremor"] = tremor_result

    # -- gait detection parity -------------------------------------------
    gait_features = load_tsdf(os.path.join(fixtures, "3.extracted_features__gait__gait_meta.json"), fixtures)
    gait_ref = load_tsdf(os.path.join(fixtures, "4.predictions__gait__gait_meta.json"), fixtures)
    clf_gait = ClassifierPackage.load(_clf_path("gait_detection_clf_package.pkl"))
    proba = np.asarray(detect_gait(gait_features.copy(), clf_gait), dtype=float)
    theirs = gait_ref["pred_gait_proba"].to_numpy(dtype=float)
    maxdiff = float(np.max(np.abs(proba - theirs)))
    result["gait"] = {"n": int(len(theirs)), "max_diff": maxdiff}
    if not np.allclose(proba, theirs, atol=1e-6, rtol=0):
        result["ok"] = False
        result["errors"].append("gait proba exceeds tolerance")

    # -- arm activity filtering parity -----------------------------------
    arm_features = load_tsdf(os.path.join(fixtures, "3.extracted_features__gait__arm_activity_meta.json"), fixtures)
    arm_ref = load_tsdf(os.path.join(fixtures, "4.predictions__gait__arm_activity_meta.json"), fixtures)
    clf_arm = ClassifierPackage.load(_clf_path("gait_filtering_clf_package.pkl"))
    arm_proba = np.asarray(filter_gait(arm_features.copy(), clf_arm), dtype=float)
    theirs = arm_ref["pred_no_other_arm_activity_proba"].to_numpy(dtype=float)
    maxdiff = float(np.max(np.abs(arm_proba - theirs)))
    result["arm_activity"] = {"n": int(len(theirs)), "max_diff": maxdiff}
    if not np.allclose(arm_proba, theirs, atol=1e-6, rtol=0):
        result["ok"] = False
        result["errors"].append("arm_activity proba exceeds tolerance")

    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
