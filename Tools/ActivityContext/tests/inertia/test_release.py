"""Operator release of a sealed candidate head bundle to production (bundle.release_to_production): the copy is
production, verifies, keeps the evaluated hash and every artifact byte, and the source is untouched. Runs against a
real sealed candidate bundle when INERTIA_CANDIDATE_BUNDLE (or the research checkout's copy) is present."""

import copy
import json
import os

import pytest

from activity_context.inertia import bundle as B
from activity_context.inertia.bundle_schema import SEAL_RELEASE, BundleError, validate_manifest

_DEFAULT = os.path.join(os.path.dirname(__file__), *[".."] * 5, "research", "inertia-bundles",
                        "shadow-ncsa-primary-actukb")
CANDIDATE = os.environ.get("INERTIA_CANDIDATE_BUNDLE") or os.path.normpath(_DEFAULT)

needs_bundle = pytest.mark.skipif(not os.path.isfile(os.path.join(CANDIDATE, "manifest.json")),
                                  reason="no sealed candidate bundle on this machine")


@needs_bundle
def test_release_copies_a_sealed_candidate_as_production(tmp_path):
    src = B.load_bundle(CANDIDATE)
    assert src.evidence_tier_max == "candidate" and src.sealed
    before = open(os.path.join(CANDIDATE, "manifest.json"), "rb").read()
    out = B.release_to_production(CANDIDATE, str(tmp_path / "prod"), "owner decision", "2026-10-10T00:00:00+00:00")
    assert out.evidence_tier_max == "production" and out.sealed
    assert out.manifest["seal"][SEAL_RELEASE] == {"from": "candidate", "reason": "owner decision",
                                                  "released_at": "2026-10-10T00:00:00+00:00"}
    assert out.bundle_sha256 != src.bundle_sha256
    assert B.presealed_sha256(out.manifest) == src.manifest["seal"]["evaluated_bundle_sha256"]
    for name in src.manifest["files"]:
        assert open(os.path.join(CANDIDATE, name), "rb").read() == open(os.path.join(out.path, name), "rb").read()
    assert open(os.path.join(CANDIDATE, "manifest.json"), "rb").read() == before


@needs_bundle
def test_release_refuses_non_candidates_and_existing_targets(tmp_path):
    prod = B.release_to_production(CANDIDATE, str(tmp_path / "prod"), "owner decision", "2026-10-10T00:00:00+00:00")
    with pytest.raises(BundleError):
        B.release_to_production(prod.path, str(tmp_path / "again"), "x", "2026-10-10T00:00:00+00:00")
    with pytest.raises(BundleError):
        B.release_to_production(CANDIDATE, prod.path, "x", "2026-10-10T00:00:00+00:00")
    with pytest.raises(BundleError):
        B.release_to_production(CANDIDATE, str(tmp_path / "blank"), "  ", "2026-10-10T00:00:00+00:00")


@needs_bundle
def test_production_needs_the_release_record_and_only_production_carries_it():
    m = B.load_bundle(CANDIDATE).manifest
    bare = copy.deepcopy(m)
    bare["evidence_tier_max"] = "production"
    with pytest.raises(BundleError):
        validate_manifest(bare)
    stray = copy.deepcopy(m)
    stray["seal"] = dict(stray["seal"], **{SEAL_RELEASE: {"from": "candidate", "reason": "x", "released_at": "t"}})
    with pytest.raises(BundleError):
        validate_manifest(stray)
    malformed = copy.deepcopy(bare)
    malformed["seal"] = dict(malformed["seal"], **{SEAL_RELEASE: {"from": "shadow", "reason": "x", "released_at": "t"}})
    with pytest.raises(BundleError):
        validate_manifest(malformed)
    json.dumps(m)
