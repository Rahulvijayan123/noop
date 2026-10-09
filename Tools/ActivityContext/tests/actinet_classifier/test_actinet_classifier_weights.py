"""Pinning and refusal: the source and converted files, verify-before-load, strict network load, the HMM document."""

import hashlib
import json
import os

import numpy as np
import pytest

from activity_context.actinet_classifier import HMM_SCHEMA, MODEL_VERSION, weights
from activity_context.actinet_classifier.weights import (CONVERTED, SOURCE, PinnedFile, WeightsError, artifact_digest,
                                                         canonical_json, read_artifact, resolve, validate_hmm_doc,
                                                         verify_file)

from ._helpers import CLASSES, hmm_doc, pins_for, write_fake_artifact

# sha256("actinet-classifier-artifact-1\n" + "hmm=..\nsource=..\nweights=..\n") over the pins below.
PINNED_ARTIFACT_DIGEST = "5d4d749a61d1b848d6930a66ee4c1d6aac9b236aeb6d2a3aeb9a8eb15864c941"


def test_source_pin_is_upstreams_walmsley_artifact():
    assert SOURCE.filename == MODEL_VERSION + ".joblib.lzma" == "ssl-ukb-c24-rw-30s-20260128.joblib.lzma"
    assert SOURCE.url == "https://wearables-files.ndph.ox.ac.uk/files/models/actinet/" + SOURCE.filename
    # actinet 0.7.2 __classifiers__["walmsley"]["md5"]; size and sha256 measured on the download (2026-10-07)
    assert SOURCE.md5 == "a829041ba84b18084b4b2897fb1b36a6"
    assert (SOURCE.size, SOURCE.sha256[:12]) == (40902237, "07dfd7482350")
    assert [pf.role for pf in CONVERTED] == ["weights", "hmm"]
    assert all(len(pf.sha256) == 64 and pf.size > 0 for pf in CONVERTED)


def test_artifact_digest_is_pinned_and_order_independent():
    assert artifact_digest() == PINNED_ARTIFACT_DIGEST == weights.DEPLOYMENT_ARTIFACT_DIGEST
    text = weights.ARTIFACT_DIGEST_PREFIX + "".join(
        f"{r}={s}\n" for r, s in sorted({"source": SOURCE.sha256, **{p.role: p.sha256 for p in CONVERTED}}.items()))
    assert artifact_digest() == hashlib.sha256(text.encode()).hexdigest()
    assert artifact_digest(tuple(reversed(CONVERTED))) == PINNED_ARTIFACT_DIGEST
    other = (CONVERTED[0], PinnedFile("hmm", CONVERTED[1].filename, "ab" * 32, 1))
    assert artifact_digest(other) != PINNED_ARTIFACT_DIGEST


def test_missing_directory_and_files(tmp_path, monkeypatch):
    monkeypatch.delenv(weights.ARTIFACT_DIR_ENV, raising=False)
    for d in (None, str(tmp_path / "absent")):
        with pytest.raises(WeightsError) as ei:
            resolve(d)
        assert ei.value.kind == "model_missing"
    with pytest.raises(WeightsError) as ei:
        resolve(str(tmp_path))
    assert ei.value.kind == "model_missing"


def test_size_and_sha_checked_before_any_parse(tmp_path):
    p = tmp_path / weights.WEIGHTS.filename
    p.write_bytes(b"not a torch file at all")
    pf = PinnedFile("weights", p.name, hashlib.sha256(b"something else").hexdigest(), p.stat().st_size + 1)
    with pytest.raises(WeightsError) as ei:
        verify_file(str(p), pf)
    assert ei.value.kind == "weights_mismatch" and "bytes, pinned" in ei.value.message
    pf = PinnedFile("weights", p.name, hashlib.sha256(b"something else").hexdigest(), p.stat().st_size)
    with pytest.raises(WeightsError) as ei:
        verify_file(str(p), pf)
    assert ei.value.kind == "weights_mismatch" and "sha256" in ei.value.message
    good = PinnedFile("source", p.name, hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_size, md5="0" * 32)
    with pytest.raises(WeightsError) as ei:
        verify_file(str(p), good)
    assert "md5" in ei.value.message


def test_real_pins_refuse_a_fake_artifact(tmp_path):
    write_fake_artifact(str(tmp_path))
    with pytest.raises(WeightsError) as ei:
        resolve(str(tmp_path))                    # random weights can never carry the pinned digests
    assert ei.value.kind == "weights_mismatch"


def test_fake_artifact_loads_with_its_own_pins_and_class_order(tmp_path):
    torch = pytest.importorskip("torch")
    pins = write_fake_artifact(str(tmp_path))
    state, classes, hmm_block, digests = read_artifact(str(tmp_path), pins)
    assert classes == CLASSES                      # from the artifact, not from the code
    assert set(digests) == {"weights", "hmm"} and all(isinstance(v, torch.Tensor) for v in state.values())
    assert hmm_block["labels"] == [0, 1, 2, 3]


class _NotATensor:
    pass


def test_pickled_objects_are_never_loaded(tmp_path):
    torch = pytest.importorskip("torch")
    write_fake_artifact(str(tmp_path))
    torch.save({"feature_extractor.x": _NotATensor()}, str(tmp_path / weights.WEIGHTS.filename))
    with pytest.raises(WeightsError) as ei:        # weights_only=True refuses arbitrary classes
        read_artifact(str(tmp_path), pins_for(str(tmp_path)))
    assert ei.value.kind == "weights_mismatch"


def test_strict_network_load_refusals():
    torch = pytest.importorskip("torch")
    from activity_context.actinet_classifier.model import ActiNetNetwork, load_network
    sd = ActiNetNetwork(4).state_dict()
    load_network(sd, 4)
    cases = {
        "missing": {k: v for k, v in sd.items() if k != "classifier.linear2.bias"},
        "extra": {**sd, "classifier.linear3.weight": torch.zeros(1)},
        "shape": {**sd, "classifier.linear2.weight": torch.zeros(3, 512)},
        "dtype": {**sd, "classifier.linear2.bias": sd["classifier.linear2.bias"].double()},
        "nonfinite": {**sd, "classifier.linear1.bias": torch.full((512,), float("nan"))},
    }
    for name, bad in cases.items():
        with pytest.raises(WeightsError) as ei:
            load_network(bad, 4)
        assert ei.value.kind == "weights_mismatch", name
    with pytest.raises(WeightsError):
        load_network(sd, 3)                        # head width must equal the artifact's class count


def test_hmm_document_validation():
    validate_hmm_doc(json.loads(canonical_json(hmm_doc())))
    bad = []
    d = hmm_doc(); d["schema"] = "other"; bad.append(d)
    d = hmm_doc(); d["classes"] = ["a", "a", "b", "c"]; bad.append(d)
    d = hmm_doc(); d["window_sec"] = 10; bad.append(d)
    d = hmm_doc(); d["hmm"]["labels"] = [1, 2, 3, 4]; bad.append(d)
    d = hmm_doc(); d["hmm"]["emission"] = d["hmm"]["emission"][:3]; bad.append(d)
    d = hmm_doc(); d["hmm"]["transition"][0][0] = -0.1; bad.append(d)
    d = hmm_doc(); d["hmm"]["prior"][0] = float("nan"); bad.append(d)
    d = hmm_doc(); d["hmm"]["transition"][1] = [0.5, 0.5, 0.5, 0.5]; bad.append(d)
    d = hmm_doc(); d["hmm"]["dtypes"]["emission"] = "float64"; bad.append(d)
    d = hmm_doc(); d["hmm"]["uniform_prior"] = 1; bad.append(d)
    for i, doc in enumerate(bad):
        with pytest.raises(WeightsError) as ei:
            validate_hmm_doc(doc)
        assert ei.value.kind == "weights_mismatch", i
    assert HMM_SCHEMA == "nara.actinet.hmm/1"


def test_canonical_json_keeps_float32_values_exact():
    em = np.array([[0.5143734216690063, 0.2661537528038025], [0.0026896593626588583, 0.9973103404045105]],
                  np.float32)
    doc = json.loads(canonical_json({"e": em.astype(np.float64).tolist()}))
    assert np.array_equal(np.asarray(doc["e"], np.float32), em)
    with pytest.raises(ValueError):
        canonical_json({"x": float("nan")})


def test_convert_verifies_the_source_before_unpickling(tmp_path):
    src = tmp_path / SOURCE.filename
    src.write_bytes(b"\x80\x04 a pickle that must never be loaded")
    with pytest.raises(WeightsError) as ei:
        weights.convert(str(src), str(tmp_path / "out"))
    assert ei.value.kind == "weights_mismatch"
    assert not os.path.exists(tmp_path / "out")


def test_manifest_cli(capsys):
    assert weights.main(["manifest"]) == 0
    doc = json.loads(capsys.readouterr().out)
    assert doc["artifact_digest"] == PINNED_ARTIFACT_DIGEST
    assert doc["files"]["source"]["md5"] == SOURCE.md5 and doc["convert_env"]["torch"] == "2.8.0"
