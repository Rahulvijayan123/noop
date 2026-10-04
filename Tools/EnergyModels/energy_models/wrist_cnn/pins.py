"""Provenance pins for the upstream wrist-CNN weights (stdlib only, no I/O).

The upstream repository ships NO licence file, so its weights are all rights
reserved: they are never committed or redistributed from here. They are fetched
from the upstream repository at ``PINNED_COMMIT`` and accepted only if their
sha256 equals the digests below (computed by this project from the files, and
cross-checked against a download from raw.githubusercontent.com).
"""

from __future__ import annotations

from dataclasses import dataclass

UPSTREAM_REPO = "razmik/cnn-wrist-model-freeliving"
UPSTREAM_URL = f"https://github.com/{UPSTREAM_REPO}"
PINNED_COMMIT = "9ca77ea104074ad82c648ec75c3a48e2bd82deeb"
PINNED_COMMIT_DATE = "2020-04-14T01:38:43Z"
RAW_HOST = "raw.githubusercontent.com"
RAW_URL_TEMPLATE = "https://raw.githubusercontent.com/{repo}/{commit}/{path}"

PAPER_CITATION = (
    "Nawaratne R, Alahakoon D, De Silva D, O'Halloran PD, Montoye AHK, Staley K, "
    "Nicholson M, Kingsley MIC. Deep learning to predict energy expenditure and "
    "activity intensity in free living conditions using wrist-specific accelerometry. "
    "Journal of Sports Sciences 2021;39(6):683-690."
)
PAPER_DOI = "10.1080/02640414.2020.1841394"


@dataclass(frozen=True)
class UpstreamFile:
    head: str
    path: str            # repo-relative POSIX path
    size: int            # bytes
    sha256: str
    git_blob_sha1: str   # `git rev-parse <commit>:<path>`; extra cross-check only

    @property
    def basename(self) -> str:
        return self.path.rsplit("/", 1)[-1]

    def raw_url(self) -> str:
        return RAW_URL_TEMPLATE.format(repo=UPSTREAM_REPO, commit=PINNED_COMMIT, path=self.path)


@dataclass(frozen=True)
class NpzPin:
    filename: str
    size: int
    sha256: str


UPSTREAM_FILES: dict[str, UpstreamFile] = {
    "regression": UpstreamFile(
        head="regression",
        path="pre-trained-models/regression/window-6000-overlap-3000/best_model.013-0.28.h5",
        size=17524696,
        sha256="31a5769b14514996d114af462e7f2d142ed17ebdce7b4a70596499e0955a5d8c",
        git_blob_sha1="94c1e6f4143397614b262a1f6c086b1098c08b1c",
    ),
    "classification": UpstreamFile(
        head="classification",
        path="pre-trained-models/classification/window-6000-overlap-3000/best_model.007-0.36.h5",
        size=17530824,
        sha256="83b04e0946e2a2999918a64db992431f9a1d591225380b2ca87a16dd661c7747",
        git_blob_sha1="bbbefc44c5e24c019d79d66a201f553bfa544eb7",
    ),
}

# sha256 of the converted float32 .npz files. The writer in fetch.py is
# byte-deterministic (hand-written zip container and .npy headers, fixed
# timestamps), so these are reproducible from the upstream digests above.
NPZ_PINS: dict[str, NpzPin] = {
    "regression": NpzPin(
        filename="wrist_cnn_regression_f32.npz",
        size=5825782,
        sha256="4c5af0c81fb44a118c71280eaba64f04529c4aaf8c896b7722a84c113f5db7ef",
    ),
    "classification": NpzPin(
        filename="wrist_cnn_classification_f32.npz",
        size=5827710,
        sha256="9b545f211bfaff6b2c49f0380e9b51bf2e1bab73baa0e3984f588f99fe40d4fc",
    ),
}


@dataclass(frozen=True)
class PinSet:
    """Everything a fetch/convert/load needs to know. Tests inject their own."""

    upstream: dict[str, UpstreamFile]
    npz: dict[str, NpzPin]


PINS = PinSet(upstream=UPSTREAM_FILES, npz=NPZ_PINS)
