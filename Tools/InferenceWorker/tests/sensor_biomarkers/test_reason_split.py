"""`artifact_unavailable` split (2026-10-09): a family whose model or weights are missing reads
``model_unavailable``; a family no verified input reached reads ``no_verified_input`` (the canonical
codes of contracts/reason-codes.json). The old string stays in the vocabulary so stored documents
remain valid, and is never written."""

import json
from pathlib import Path

from frwhoop_inference.sensor_biomarkers import DETAIL_REASONS
from frwhoop_inference.sensor_biomarkers.optional import (
    LEGACY_REASON_ARTIFACT_UNAVAILABLE, REASON_MODEL_UNAVAILABLE, REASON_NO_VERIFIED_INPUT,
    STATE_ARTIFACT_UNAVAILABLE, STATE_REASONS, make_state, state_documents)
from frwhoop_inference.sensor_biomarkers.rhythm.provider import _wire_reason

CONTRACT = Path(__file__).resolve().parents[4] / "contracts" / "reason-codes.json"


def test_missing_weights_publish_model_unavailable_not_artifact_unavailable():
    assert STATE_REASONS[STATE_ARTIFACT_UNAVAILABLE] == ("withheld", REASON_MODEL_UNAVAILABLE)
    state = make_state("paradigma", STATE_ARTIFACT_UNAVAILABLE, detail="weights missing",
                       detail_code="artifact_missing")
    # The adapter state keeps naming what is missing; the family reason is the canonical code.
    assert state["state"] == "artifact_unavailable" and state["reason"] == "model_unavailable"
    docs = state_documents(["tremor", "arm_swing"], state)
    assert {d["reason"] for d in docs} == {"model_unavailable"}
    assert all(d["reason_counts"] == {"artifact_missing": 1} for d in docs)


def test_vocabulary_has_both_codes_and_keeps_the_legacy_one_readable():
    assert REASON_NO_VERIFIED_INPUT in DETAIL_REASONS
    assert REASON_MODEL_UNAVAILABLE in DETAIL_REASONS
    assert LEGACY_REASON_ARTIFACT_UNAVAILABLE in DETAIL_REASONS
    assert LEGACY_REASON_ARTIFACT_UNAVAILABLE not in {r for _s, r in STATE_REASONS.values()}


def test_standalone_wire_reasons_stay_in_the_sidecar_enum():
    assert _wire_reason("no_verified_input") == "insufficient_coverage"
    assert _wire_reason("model_unavailable") == "blocked_artifact"
    assert _wire_reason("artifact_unavailable") == "blocked_artifact"


def test_codes_are_the_canonical_contract_codes():
    if not CONTRACT.exists():      # the sidecar ships without the repository's contracts directory
        return
    doc = json.loads(CONTRACT.read_text())
    codes = {c["code"] for c in doc["codes"]}
    assert {REASON_NO_VERIFIED_INPUT, REASON_MODEL_UNAVAILABLE} <= codes
    legacy = doc["legacy"]["sensor_biomarker"]
    assert legacy[REASON_NO_VERIFIED_INPUT]["code"] == "no_verified_input"
    assert legacy[REASON_MODEL_UNAVAILABLE]["code"] == "model_unavailable"
