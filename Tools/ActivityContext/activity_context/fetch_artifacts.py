"""activity-fetch — download pinned artifacts and verify digests.

  * HART pretrained checkpoint (model.safetensors + config.json + training_args.bin)
    from the pinned commit 122b4a8b... (repo-committed artifact; no HF repo).
  * Optionally the WISDM-19 archive (310 MB, CC BY 4.0) for training.

Digests are pinned here AND in the model manifest; a mismatch aborts.
No weights are ever committed to git (see README artifact policy).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import urllib.request
from typing import Dict, Optional

HART_PIN = "122b4a8b07758deedfcf3b1e87f03eed5ad55967"
HART_BASE = ("https://github.com/EdgeIntelligenceLab/HART/raw/"
             f"{HART_PIN}/finetuning_HART/pretrained_checkpoint/")

CHECKPOINT_FILES: Dict[str, Dict] = {
    "model.safetensors": {
        "url": HART_BASE + "model.safetensors",
        "sha256": "88b8d1790a43cb5c96c5bba5da60c81ae08657024f9747cbe52d45c2acfd2e6d",
        "size": 856744,
    },
    "config.json": {
        "url": HART_BASE + "config.json",
        "sha256": "3bf321e86b4204b7bec8bb3e01fb1d5154ba070657372dd4190310bdd28c087a",
        "size": 3501,
    },
    "training_args.bin": {
        "url": HART_BASE + "training_args.bin",
        "sha256": "b603c33fe87a8b087e94af817ff3b066f373174b71133dfa38a1dc7f63a45088",
        "size": 5841,
    },
}

WISDM_ARCHIVE = {
    "url": ("https://archive.ics.uci.edu/static/public/507/"
            "wisdm+smartphone+and+smartwatch+activity+and+biometrics+dataset.zip"),
    "sha256": "6e0147f181d8f5275918db65eeb9dc842a0185d37cb6b2f30cbf74ee6e205469",
    "size": 310292805,
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: str, expected_sha256: str, expected_size: int,
             retries: int = 5) -> None:
    tmp = dest + ".part"
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as resp, \
                    open(tmp, "wb") as out:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
            size = os.path.getsize(tmp)
            digest = sha256_file(tmp)
            if size != expected_size or digest != expected_sha256:
                raise RuntimeError(
                    f"digest mismatch: size {size} (want {expected_size}), "
                    f"sha256 {digest[:16]}... (want {expected_sha256[:16]}...)")
            os.replace(tmp, dest)
            return
        except Exception as exc:  # noqa: BLE001 - retry loop
            if os.path.exists(tmp):
                os.remove(tmp)
            if attempt == retries:
                raise RuntimeError(f"failed to fetch {url}: {exc}") from exc
            print(f"  attempt {attempt}/{retries} failed: {exc}; retrying...",
                  file=sys.stderr)


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description="Fetch pinned activity artifacts")
    ap.add_argument("--checkpoint-dir", default="checkpoint",
                    help="dir to place model.safetensors/config.json/training_args.bin")
    ap.add_argument("--wisdm", default=None, metavar="DEST.zip",
                    help="also download the WISDM-19 archive to this path")
    args = ap.parse_args(argv)

    os.makedirs(args.checkpoint_dir, exist_ok=True)
    print(f"fetching HART checkpoint ({HART_PIN[:12]}) -> {args.checkpoint_dir}")
    for name, meta in CHECKPOINT_FILES.items():
        dest = os.path.join(args.checkpoint_dir, name)
        if os.path.isfile(dest) and sha256_file(dest) == meta["sha256"]:
            print(f"  {name}: present, digest ok")
            continue
        print(f"  {name}: downloading...")
        download(meta["url"], dest, meta["sha256"], meta["size"])
        print(f"  {name}: ok ({os.path.getsize(dest)} B)")

    if args.wisdm:
        m = WISDM_ARCHIVE
        if os.path.isfile(args.wisdm) and sha256_file(args.wisdm) == m["sha256"]:
            print(f"  wisdm: present, digest ok")
        else:
            print(f"  wisdm: downloading {m['size']} B (CC BY 4.0)...")
            download(m["url"], args.wisdm, m["sha256"], m["size"])
            print(f"  wisdm: ok ({os.path.getsize(args.wisdm)} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
