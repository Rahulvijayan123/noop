"""label_mappings.json: schema, class orders (= INERTIA1.md), policy (no MASK row trained, no 'unknown'),
completeness (every source label of every dataset has a row for every head), MET transform, roles."""

import os
import re

import numpy as np
import pytest

from activity_context.inertia import HEAD_CLASS_ORDERS
from activity_context.inertia import mappings as Mp

INERTIA1_MD = os.path.join(os.path.dirname(__file__), "..", "..", "INERTIA1.md")


@pytest.fixture(scope="module")
def cw():
    return Mp.load_mappings()


def _md_class_orders():
    out = {}
    with open(INERTIA1_MD, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\| `(\w+)`(?: \(multi-label\))? \| ([a-z_, ]+) \|$", line.strip())
            if m:
                out[m.group(1)] = tuple(c.strip() for c in m.group(2).split(","))
    return out


def test_class_orders_equal_contract_table(cw):
    md = _md_class_orders()
    assert set(md) == {"posture", "locomotion", "arm_behavior", "transition"}
    for h, order in md.items():
        assert HEAD_CLASS_ORDERS[h] == order
        assert tuple(cw.doc["head_class_orders"][h]) == order
        assert "unknown" not in order and "none" not in order


def test_schema_and_validation_clean(cw):
    assert cw.doc["schema"] == "nara.inertia.mappings/1"
    assert Mp.validate(cw) == []
    assert len(cw.doc["mappings"]) == 2635


def test_every_label_has_every_head(cw):
    for ds in cw.doc["dataset_roles"]:
        for lab in cw.source_labels(ds):
            for h in Mp.ALL_ROW_HEADS:
                cw.row(ds, lab, h)          # raises if missing


def test_no_mask_row_used_and_no_unknown_target(cw):
    for r in cw.doc["mappings"]:
        if r["target_type"] == "mask":
            assert r["nara_target"] == "MASK" and not r["used_for_training"]
        t = r["nara_target"]
        assert t != "unknown" and not (isinstance(t, list) and "unknown" in t)


def test_only_train_wrist_datasets_train(cw):
    train = set(cw.datasets("train_wrist"))
    assert train == {"capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "gotov", "wear"}
    for r in cw.doc["mappings"]:
        if r["used_for_training"]:
            assert r["dataset"] in train
    # no stated (or a conflicting) licence: still excluded after the 2026-10-06 decision
    for ds in ("extrasensory_watch", "realworld2016", "ut_complex_shoaib2016", "uci_hmp_wrist"):
        assert cw.role(ds) == "excluded_licence"
        assert all(cw.class_target(ds, lab, "locomotion") == 0 for lab in cw.source_labels(ds))


def test_nc_sa_licence_decision(cw):
    """GOTOV/WEAR (CC BY-NC-SA 4.0) train since 2026-10-06 with exactly Agent C's audited rows (all high/medium);
    low-confidence / candidate rows stay unused with an explicit policy."""
    dec = cw.doc["licence_decisions"][0]
    assert dec["date"] == "2026-10-06" and dec["datasets"] == ["gotov", "wear"]
    assert set(dec["still_excluded"]) == {"extrasensory_watch", "realworld2016", "ut_complex_shoaib2016", "uci_hmp_wrist"}
    for ds in ("gotov", "wear"):
        assert cw.role(ds) == "train_wrist" and cw.doc["dataset_roles"][ds]["licence"] == "CC BY-NC-SA 4.0"
    nc = [r for r in cw.doc["mappings"] if r["dataset"] in ("gotov", "wear")]
    for r in nc:
        assert r["used_for_training"] == r["audit_used_for_training"]
        if r["used_for_training"]:
            assert r["mapping_confidence"] in ("high", "medium") and r["licence_decision"].startswith("2026-10-06")
        elif r["target_type"] != "mask":
            assert r["policy"].startswith("not trained")
    assert sum(r["used_for_training"] for r in nc) == 69
    L = lambda ds, lab: Mp.mask_classes(cw.class_target(ds, lab, "locomotion"), "locomotion")
    assert L("gotov", "walkingSlow") == ["walking"] and L("gotov", "walkingNormal") == ["walking"]
    assert L("gotov", "walkingFast") == ["brisk_walking"]                      # the only brisk_walking supervision
    A = lambda ds, lab: Mp.mask_classes(cw.class_target(ds, lab, "arm_behavior"), "arm_behavior")
    for lab in ("push-ups", "push-ups (complex)", "burpees", "bench-dips", "jogging (rotating arms)"):
        assert A("wear", lab) == ["exercise_motion"]
    for lab in ("sit-ups", "sit-ups (complex)", "lunges", "lunges (complex)"):    # medium but 'arms may be static'
        assert A("wear", lab) == [] and cw.row("wear", lab, "arm_behavior")["mapping_confidence"] == "medium"
    assert A("gotov", "sittingSofa") == [] and A("gotov", "dishwashing") == []    # low confidence: unused
    assert A("gotov", "sittingChair") == ["desk_like"]
    for lab in ("NA", "syncJumping", "step"):
        assert all(cw.class_target("gotov", lab, h) == 0 for h in ("posture", "locomotion", "arm_behavior"))
    assert cw.transition_state("gotov", "NA") is None and cw.transition_state("wear", "null") is None
    assert cw.transition_state("gotov", "walkingFast") == "walk"


def test_gotov_measured_met_rows(cw):
    assert cw.intensity_measured("gotov", "walkingFast") and cw.intensity_measured("gotov", "lyingDownLeft")
    assert np.isnan(cw.intensity_target("gotov", "walkingFast"))       # no fixed label value: measured per window
    assert not cw.intensity_measured("gotov", "NA") and not cw.intensity_measured("wear", "jogging")
    assert not cw.intensity_measured("capture24", "7030 sleeping;MET 0.95")
    assert "gotov-met-1" in cw.row("gotov", "cycling", "movement_intensity")["nara_target"]["value"]


def test_missing_target_is_mask_never_unknown(cw):
    # WISDM walking supervises locomotion only; posture/arm are MASK (0), not a class
    assert cw.class_target("wisdm2019_watch", "A", "posture") == 0
    assert cw.class_target("wisdm2019_watch", "A", "arm_behavior") == 0
    assert Mp.mask_classes(cw.class_target("wisdm2019_watch", "A", "locomotion"), "locomotion") == ["walking", "brisk_walking"]
    assert np.isnan(cw.intensity_target("wisdm2019_watch", "A"))           # low-confidence MET row not trained


def test_met_transform():
    for met, v in ((0.95, 0.0), (1.5, 0.163), (3.0, 0.442), (6.0, 0.721), (12.0, 1.0), (20.0, 1.0)):
        assert abs(Mp.met_to_intensity(met) - v) < 1e-3
    with pytest.raises(Mp.MappingError):
        Mp.met_to_intensity(0.0)


def test_bitmask_roundtrip():
    b = Mp.bitmask(["walking", "brisk_walking"], "locomotion")
    assert b == 0b110 and Mp.mask_classes(b, "locomotion") == ["walking", "brisk_walking"]
    with pytest.raises(Mp.MappingError):
        Mp.bitmask(["unknown"], "posture")


def test_transition_states_and_rules(cw):
    assert cw.transition_state("opportunity", "loc:4") == "sit"
    assert cw.transition_state("opportunity", "loc:0") is None
    assert cw.transition_state("capture24", "7030 sleeping;MET 0.95") == "sleep"
    assert cw.event_pairs()[("sit", "walk")] == ["sit_to_stand_like", "walk_start"]
    assert cw.transition_rule("wisdm2019_watch")["mode"] == "negatives_only"
    assert cw.set_families("locomotion") == {"walking": ["walking", "brisk_walking"]}


def test_markdown_table(cw, tmp_path):
    md = Mp.markdown_table(cw)
    assert md.count("\n| ") > 2635 and "MASK" in md
    rc = Mp.main(["table", "--out", str(tmp_path / "t.md")])
    assert rc == 0 and (tmp_path / "t.md").read_text().startswith("# Inertia head label mappings")


def test_tampered_mapping_rejected(cw, tmp_path):
    import json
    doc = json.loads(open(Mp.MAPPINGS_PATH, encoding="utf-8").read())
    doc["mappings"][0]["used_for_training"] = True        # a MASK row may never train
    p = tmp_path / "m.json"
    p.write_text(json.dumps(doc))
    with pytest.raises(Mp.MappingError):
        Mp.load_mappings(str(p))
