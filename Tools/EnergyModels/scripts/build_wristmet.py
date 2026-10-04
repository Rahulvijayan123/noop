#!/usr/bin/env python3
"""Rebuild the WristMET artifact (``artifacts/wristmet``) from the public Zenodo data.

Needs the build-time libraries pinned in ``requirements-wristmet-build.txt`` (pandas, scikit-learn, xgboost,
openpyxl, ...). The recordings stay outside the git repository (``--research-dir``).

    python scripts/build_wristmet.py --research-dir /path/to/nara-energy-research

Steps: (1) verify and extract ``Phase_2_Data.zip`` (md5 of Zenodo record 14858226), (2) build the 60 s and 15 s
window datasets (cached under the research directory), (3) leave-one-participant-out evaluation suite
(``--skip-loso`` to omit), (4) train the production models with fixed seeds, export, verify parity with
scikit-learn / XGBoost on every training window, (5) write ``manifest.json``, ``NOTICE.md`` and the golden test
fixture. Everything is deterministic: two runs with the same library versions give the same artifact bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import zipfile
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from energy_models.wristmet.pipeline import dataset as D  # noqa: E402
from energy_models.wristmet.pipeline import manifest as MF  # noqa: E402
from energy_models.wristmet.pipeline import modeling as M  # noqa: E402
from energy_models.wristmet.pipeline import production as P  # noqa: E402
from energy_models.wristmet.pipeline.export import PROVENANCE  # noqa: E402

COMMIT_SIZE_LIMIT_BYTES = 3 * 1024 * 1024
DATA_DIR_NAME = "Phase 2 - Data"


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def locate_data(research: Path, zip_path: Path | None, log) -> tuple[Path, str | None]:
    extracted = research / "zenodo" / "extracted"
    root = extracted / DATA_DIR_NAME
    zip_path = zip_path or research / "zenodo" / "Phase_2_Data.zip"
    md5 = None
    if zip_path.exists():
        md5 = md5_of(zip_path)
        log(f"[data] {zip_path.name}: md5 {md5} ({'OK' if md5 == PROVENANCE['data']['md5'] else 'MISMATCH'})")
        if md5 != PROVENANCE["data"]["md5"]:
            raise SystemExit("zip md5 does not match Zenodo record 14858226")
    if not root.exists():
        if not zip_path.exists():
            raise SystemExit(f"neither {root} nor {zip_path} exist; download record 14858226 from Zenodo first")
        log(f"[data] extracting to {extracted}")
        extracted.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(extracted)
    if not root.exists():
        raise SystemExit(f"expected {root} after extraction")
    return root, md5


def load_or_build(root: Path, cache: Path, window_s: int, rebuild: bool, log) -> D.WindowDataset:
    tag = f"{window_s}s"
    needed = [cache / f"{name}_{tag}.{ext}" for name, ext in (("windows", "npy"), ("meta", "csv"), ("demos", "json"), ("reports", "json"))]
    if not rebuild and all(p.exists() for p in needed):
        log(f"[data] loading cached {tag} windows")
        return D.WindowDataset.load(cache, window_s)
    t = time.time()
    ds = D.build_window_dataset(root, window_s)
    ds.save(cache)
    log(f"[data] built {tag} windows: {len(ds.meta)} in {time.time() - t:.0f}s")
    return ds


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_research = os.environ.get("WRISTMET_RESEARCH_DIR")
    ap.add_argument("--research-dir", type=Path, default=Path(default_research) if default_research else None,
                    help="directory outside git holding zenodo/Phase_2_Data.zip, the extracted data, caches and results "
                         "(env WRISTMET_RESEARCH_DIR)")
    ap.add_argument("--data-zip", type=Path, default=None, help="Phase_2_Data.zip (default: <research-dir>/zenodo/Phase_2_Data.zip)")
    ap.add_argument("--out-dir", type=Path, default=PACKAGE_ROOT / "artifacts" / "wristmet")
    ap.add_argument("--golden", type=Path, default=PACKAGE_ROOT / "tests" / "fixtures" / "wristmet_golden.json")
    ap.add_argument("--seed", type=int, default=M.DEFAULT_SEED)
    ap.add_argument("--skip-loso", action="store_true", help="skip the evaluation suite (the artifact does not depend on it)")
    ap.add_argument("--skip-15s", action="store_true", help="skip the 15 s dataset and its evaluation")
    ap.add_argument("--rebuild-cache", action="store_true", help="rebuild the window caches from the raw data")
    args = ap.parse_args()
    if args.research_dir is None:
        ap.error("--research-dir (or WRISTMET_RESEARCH_DIR) is required")

    def log(msg: str) -> None:
        print(msg, flush=True)

    research = args.research_dir.resolve()
    cache = research / "cache"
    results_dir = research / "results"
    results_dir.mkdir(parents=True, exist_ok=True)

    root, md5 = locate_data(research, args.data_zip, log)
    ds60 = load_or_build(root, cache, 60, args.rebuild_cache, log)
    ds15 = None if args.skip_15s else load_or_build(root, cache, 15, args.rebuild_cache, log)

    loso = None
    loso_path = results_dir / "loso_results.json"
    if not args.skip_loso:
        from energy_models.wristmet.pipeline import loso_suite

        loso = loso_suite.run_suite(ds60, ds15, log)
        loso_path.write_text(json.dumps(loso, indent=1))
    elif loso_path.exists():
        loso = json.loads(loso_path.read_text())
        log(f"[loso] reusing {loso_path}")

    production = P.build_production(ds60, args.out_dir, args.golden, seed=args.seed, log=log)

    size = production["artifact"]["bytes_gz"]
    committed = size <= COMMIT_SIZE_LIMIT_BYTES
    gitignore = args.out_dir / ".gitignore"
    if committed:
        gitignore.write_text(f"# {P.ARTIFACT_NAME} is small enough to be committed (<= 3 MB gz); it is rebuilt by scripts/build_wristmet.py\n!{P.ARTIFACT_NAME}\n")
    elif gitignore.exists():
        gitignore.unlink()

    manifest_loso = None
    if loso is not None:
        manifest_loso = json.loads(json.dumps(loso))
        for key in ("w60_primary", "w15_primary"):
            if key in manifest_loso:
                manifest_loso[key].pop("per_participant_rmse", None)
    manifest = MF.build_manifest(
        model_id=P.MODEL_ID,
        production=production,
        loso=manifest_loso,
        dataset_info=MF.dataset_summary(ds60, ds15, md5),
        committed=committed,
    )
    MF.write_manifest(args.out_dir / "manifest.json", manifest)
    MF.write_notice(args.out_dir / "NOTICE.md", P.MODEL_ID)
    log(f"[done] {args.out_dir}: artifact {size} bytes gz, committed={committed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
