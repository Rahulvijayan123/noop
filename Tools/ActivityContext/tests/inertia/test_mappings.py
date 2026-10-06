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
    assert train == {"capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity"}
    for r in cw.doc["mappings"]:
        if r["used_for_training"]:
            assert r["dataset"] in train
    for ds in ("wear", "gotov", "extrasensory_watch", "realworld2016", "ut_complex_shoaib2016"):
        assert cw.role(ds) == "excluded_licence"
        assert all(cw.class_target(ds, lab, "locomotion") == 0 for lab in cw.source_labels(ds))


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
