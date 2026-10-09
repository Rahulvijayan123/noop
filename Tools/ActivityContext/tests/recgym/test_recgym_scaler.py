"""The reproduced StandardScaler: provenance, shape, and the round trip against upstream's own sklearn transform."""

import json

import numpy as np
import pytest

from activity_context.recgym import CHANNELS, CLASSES, SCALER_VERSION, UPSTREAM_COMMIT
from activity_context.recgym.scaler import SCALER_PATH, ScalerError, load_scaler

from ._helpers import golden


def test_the_committed_scaler_loads_with_its_provenance():
    sc = load_scaler()
    assert sc.version == SCALER_VERSION
    assert sc.mean.shape == (80, 6) and sc.scale.shape == (80, 6)
    doc = sc.document
    prov = doc["provenance"]
    assert prov["upstream"]["commit"] == UPSTREAM_COMMIT
    assert len(prov["dataset"]["csv_sha256"]) == 64 and len(prov["dataset"]["archive_sha256"]) == 64
    assert prov["dataset"]["url"].startswith("https://www.kaggle.com/api/v1/datasets/download/")
    assert prov["procedure"]["script"].endswith("activity_context/recgym/reproduce.py")
    assert prov["procedure"]["split"] == {"train": [1, 2, 3, 4, 5, 6, 7], "val": [8], "test": [9, 10]}
    assert prov["procedure"]["windows"]["train"] == 28820
    test = prov["verification"]["reproduced"]["test"]
    assert test["n"] == 7072
    assert abs(test["accuracy"] - 0.963) <= 0.0015 and abs(test["loss"] - 0.1516) <= 0.0015
    assert doc["n_samples_seen"] == 28820


def test_scaler_transform_equals_upstreams_sklearn_transform():
    g = golden()
    sc = load_scaler()
    for item in g["scaler_roundtrip"]:
        raw = np.asarray(g["real"][item["index"]]["raw"], np.float64)[None]
        expected = np.asarray(item["scaled"], np.float64)[None]
        got = sc.transform(raw)
        assert np.max(np.abs(got - expected)) <= 1e-12
        assert np.max(np.abs(sc.inverse_transform(got) - raw)) <= 1e-12


def test_scaler_is_per_time_step_and_channel_and_close_to_the_channel_statistics():
    sc = load_scaler()
    # 480 distinct features, but every time step of a channel saw (almost) the same samples
    assert len(np.unique(sc.mean)) == 480
    per_channel = sc.mean.mean(axis=0)
    assert np.all(np.abs(sc.mean - per_channel) < 1e-3)
    assert np.all(sc.scale > 0.02) and np.all(sc.scale < 0.06)


def test_a_damaged_scaler_is_refused(tmp_path):
    with open(SCALER_PATH, "r", encoding="utf-8") as f:
        doc = json.load(f)
    bad = dict(doc, channels=list(reversed(CHANNELS)))
    p = tmp_path / "s.json"
    p.write_text(json.dumps(bad))
    with pytest.raises(ScalerError):
        load_scaler(str(p))
    bad = dict(doc, classes=list(CLASSES[1:]) + [CLASSES[0]])
    p.write_text(json.dumps(bad))
    with pytest.raises(ScalerError):
        load_scaler(str(p))
    bad = dict(doc, scale=[[0.0] * 6] * 80)
    p.write_text(json.dumps(bad))
    with pytest.raises(ScalerError):
        load_scaler(str(p))
    with pytest.raises(ScalerError):
        load_scaler().transform(np.zeros((1, 79, 6)))
