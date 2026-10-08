"""wav2sleep provider behaviour: output schema and type separation, masks, gaps, no cross-run
concatenation, PPG-only model input, determinism, cache identity, bounds and registry mapping.

These run WITHOUT the checkpoint: ``runtime.get_model`` is replaced by the vendored architecture
with seeded random weights (wav2sleep_helpers.stand_in_model). Outputs therefore mean nothing -
only structure, masking and bookkeeping are asserted here. Real-weight behaviour and parity with
the official code are in test_wav2sleep_real_weights.py. Fixtures are SYNTHETIC.
"""

import copy
import re

import numpy as np
import pytest
import torch

import wav2sleep_fixtures as F
import wav2sleep_helpers as H
from frwhoop_inference.contract import ProviderResult
from frwhoop_inference.frwhoop_sleep.providers.sleep_stage import LABEL_SPACE as SLEEPECG_LABEL_SPACE
from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep import runtime
from frwhoop_inference.frwhoop_sleep.wav2sleep.provider import Wav2SleepPpgProvider, make_providers
from frwhoop_inference.frwhoop_sleep.wav2sleep.registry import Wav2SleepRegistryShim

HEX64 = re.compile(r"^[0-9a-f]{64}$")


@pytest.fixture(scope="module")
def stand_in():
    loaded = H.stand_in_model(seed=0)
    loaded.model = H.ForwardSpy(loaded.model)
    return loaded


@pytest.fixture(autouse=True)
def patched_model(monkeypatch, stand_in):
    monkeypatch.setattr(runtime, "get_model", lambda _root: stand_in)
    stand_in.model.calls.clear()
    return stand_in


@pytest.fixture(scope="module")
def provider():
    return Wav2SleepPpgProvider(model_root="/stand-in", enabled=True, threads=1)


@pytest.fixture(scope="module")
def gap_night():
    return F.parity_night_gap()


@pytest.fixture(scope="module")
def gap_response(provider, gap_night, stand_in):
    import frwhoop_inference.frwhoop_sleep.wav2sleep.runtime as rt

    original = rt.get_model
    rt.get_model = lambda _root: stand_in
    try:
        return provider.infer(input=F.payload(gap_night), context=F.context(gap_night))
    finally:
        rt.get_model = original


def test_ok_response_schema_and_type_separation(gap_response):
    r = gap_response
    assert r["status"] == "ok", r["diagnostics"]
    assert r["release_mode"] == "shadow" and r["provider_id"] == C.PROVIDER_ID
    assert r["result"]["label_space"] == C.LABEL_SPACE != SLEEPECG_LABEL_SPACE
    assert "value" not in r["result"]
    raw = r["raw_scores"]
    n = r["coverage"]["window_epochs"]
    for key in ("epoch_start_utc", "mask", "mask_reason", "run_index"):
        assert len(raw[key]) == n
    for block in ("probabilities", "logits", "labels"):
        assert len(raw[block]["values"]) == n
    assert raw["probabilities"]["output_type"] == "class_probabilities"
    assert raw["probabilities"]["calibrated"] is False
    assert raw["logits"]["output_type"] == "logits"
    assert raw["labels"]["output_type"] == "argmax_label"
    assert raw["class_order"] == list(C.CLASS_ORDER) == ["wake", "light", "deep", "rem"]
    starts = raw["epoch_start_utc"]
    assert all(b - a == 30 for a, b in zip(starts, starts[1:])) and starts[0] % 30 == 0
    for i in range(n):
        p, z, label = (raw["probabilities"]["values"][i], raw["logits"]["values"][i],
                       raw["labels"]["values"][i])
        if raw["mask"][i]:
            assert raw["mask_reason"][i] is None
            assert len(p) == 4 and all(isinstance(v, float) for v in p)
            assert abs(sum(p) - 1.0) < 5e-6
            assert isinstance(label, str) and label == C.CLASS_ORDER[int(np.argmax(z))]
        else:
            assert raw["mask_reason"][i] in C.EPOCH_MASK_REASONS
            assert p is None and z is None and label is None
    # labels travel as label runs; probabilities never appear in stages
    for stage in r["result"]["stages"]:
        assert stage["label"] in C.CLASS_ORDER and stage["stage"] == stage["label"]
        assert stage["release_mode"] == "shadow" and stage["label_space"] == C.LABEL_SPACE
        assert stage["seconds"] == stage["epochs"] * 30
        assert not ({"probabilities", "logits", "scores"} & set(stage))
    digests = r["diagnostics"]["digests"]
    assert set(digests) == {"input", "artifact", "preprocessing", "cache_key"}
    assert all(HEX64.match(v) for v in digests.values())


def test_gap_and_run_edges_are_masked_with_reasons(gap_response, gap_night):
    raw = gap_response["raw_scores"]
    cov = gap_response["coverage"]
    assert (cov["window_epochs"], cov["scored_epochs"]) == (939, 898)  # 499 + 399, see fixture
    assert cov["mask_reason_counts"]["no_ppg"] > 30                    # the 17-min gap + edges
    assert cov["mask_reason_counts"]["run_edge_partial_epoch"] >= 2
    run_a, run_b = gap_night["_runs"]
    for start, reason in zip(raw["epoch_start_utc"], raw["mask_reason"]):
        if run_a["end"] <= start and start + 30 <= run_b["start"]:
            assert reason == "no_ppg"                                     # inside the gap
    staged = [r for r in gap_response["diagnostics"]["runs"] if r["staged"]]
    assert [r["staged_epochs"] for r in staged] == [499, 399]
    for row in staged:
        assert row["native_samples_per_epoch_used"] == 751          # 30 s x 25 Hz + the end sample
        assert row["native_rate_hz"] == 25 and row["polarity"] == "as_received"
        assert row["epoch_origin_unix"] % 30 == 0
    provenance = gap_response["raw_scores"]["native_sample_provenance"]
    assert provenance["native_rate_hz"] == 25 and provenance["native_samples_per_epoch_used"] == 751
    assert gap_response["coverage"]["native_rate_hz"] == 25
    assert gap_response["coverage"]["ppg_run_id_discontinuity"] == 0


def test_model_input_is_ppg_only(gap_response, stand_in):
    del gap_response
    provider = Wav2SleepPpgProvider(model_root="/stand-in", enabled=True, threads=1)
    fixture = F.night([(0, 5 * 3600)])
    stand_in.model.calls.clear()
    response = provider.infer(input=F.payload(fixture), context=F.context(fixture))
    assert response["status"] == "ok"
    assert stand_in.model.calls, "the model was not called"
    for call in stand_in.model.calls:
        assert set(call) == {"PPG"}, "ECG/ABD/THX must be absent from the model input"
        assert call["PPG"][0] == 1 and call["PPG"][1] % 1024 == 0
    assert response["diagnostics"]["modalities"] == {"model_input": ["PPG"],
                                                     "absent": ["ECG", "ABD", "THX"]}


def test_different_run_ids_are_never_concatenated(provider):
    touching = F.night([(0, 4 * 3600), (4 * 3600, 4 * 3600)], start=F.PARITY_START,
                       run_ids=["a", "b"], lead_s=0, tail_s=0)
    joined = F.night([(0, 8 * 3600)], start=F.PARITY_START, run_ids=["a"], lead_s=0, tail_s=0)
    alone_a = F.night([(0, 4 * 3600)], start=F.PARITY_START, run_ids=["a"], lead_s=0, tail_s=0,
                      window=(touching["window"]["start_utc"], touching["window"]["end_utc"]))
    r_touch = provider.infer(input=F.payload(touching), context=F.context(touching))
    r_join = provider.infer(input=F.payload(joined), context=F.context(joined))
    r_alone = provider.infer(input=F.payload(alone_a, min_coverage_fraction=0.4, min_valid_epochs=400),
                             context=F.context(alone_a))
    assert r_touch["status"] == r_join["status"] == r_alone["status"] == "ok"
    boundary = (F.PARITY_START + 4 * 3600 - 30 - r_touch["raw_scores"]["first_epoch_start_utc"]) // 30
    # run a's last epoch needs run b's first sample, so it is masked when the runs are separate ...
    assert r_touch["raw_scores"]["mask_reason"][boundary] == "run_edge_partial_epoch"
    # ... and scored when the same samples arrive as one run
    assert r_join["raw_scores"]["mask"][boundary] is True
    # run a's outputs do not depend on run b: identical to staging run a alone
    first_a = r_touch["raw_scores"]["probabilities"]["values"][:boundary]
    assert first_a == r_alone["raw_scores"]["probabilities"]["values"][:boundary]
    assert first_a != r_join["raw_scores"]["probabilities"]["values"][:boundary]


def test_determinism_and_cache_identity(provider, gap_night):
    a = provider.infer(input=F.payload(gap_night), context=F.context(gap_night))
    b = provider.infer(input=F.payload(gap_night), context=F.context(gap_night))
    assert a["raw_scores"] == b["raw_scores"] and a["result"] == b["result"]
    assert a["diagnostics"]["digests"] == b["diagnostics"]["digests"]
    # one changed native sample -> a different input digest and cache key, same other digests
    changed = F.payload(gap_night)
    changed["ppg"]["segments"][7]["samples"][100] += 1
    c = provider.infer(input=changed, context=F.context(gap_night))
    da, dc = a["diagnostics"]["digests"], c["diagnostics"]["digests"]
    assert dc["input"] != da["input"] and dc["cache_key"] != da["cache_key"]
    assert dc["artifact"] == da["artifact"] and dc["preprocessing"] == da["preprocessing"]
    # a gate override changes the preprocessing digest (and so the cache key)
    d = provider.infer(input=F.payload(gap_night, min_valid_epochs=400), context=F.context(gap_night))
    assert d["diagnostics"]["digests"]["preprocessing"] != da["preprocessing"]
    assert d["diagnostics"]["gate_overrides"] == {"min_valid_epochs": 400}
    # re-chunking the same samples into other pieces does not change the input digest
    rechunked = F.payload(gap_night)
    segs = []
    for seg in rechunked["ppg"]["segments"]:
        half = seg["duration_s"] // 2
        if half:
            rate = rechunked["ppg"]["native_rate_hz"]
            first = dict(seg, duration_s=half, samples=seg["samples"][:half * rate])
            second = dict(seg, start_unix=seg["start_unix"] + half,
                          duration_s=seg["duration_s"] - half, samples=seg["samples"][half * rate:])
            segs += [first, second]
        else:
            segs.append(seg)
    rechunked["ppg"]["segments"] = segs
    e = provider.infer(input=rechunked, context=F.context(gap_night))
    assert e["diagnostics"]["digests"]["input"] == da["input"]
    assert e["raw_scores"] == a["raw_scores"]


def test_artifact_digest_follows_the_loaded_bytes(provider, gap_night, monkeypatch):
    first = provider.infer(input=F.payload(gap_night), context=F.context(gap_night))
    other = H.stand_in_model(seed=1)
    monkeypatch.setattr(runtime, "get_model", lambda _root: other)
    second = provider.infer(input=F.payload(gap_night), context=F.context(gap_night))
    assert second["diagnostics"]["digests"]["artifact"] != first["diagnostics"]["digests"]["artifact"]
    assert second["diagnostics"]["digests"]["cache_key"] != first["diagnostics"]["digests"]["cache_key"]


def test_ten_hour_window_is_the_bound(provider, stand_in):
    fixture = F.ten_hour_night()
    stand_in.model.calls.clear()
    response = provider.infer(input=F.payload(fixture), context=F.context(fixture))
    assert response["status"] == "ok"
    assert response["coverage"]["window_epochs"] == C.MAX_EPOCHS == 1200
    assert response["coverage"]["scored_epochs"] == 1199          # the last end sample is absent
    assert max(call["PPG"][1] for call in stand_in.model.calls) == 1199 * 1024
    longer = F.payload(fixture)
    longer["window"]["end_utc"] += 30
    refused = provider.infer(input=longer, context=F.context(fixture))
    assert refused["diagnostics"]["reason_detail"] == "night_too_long"


def test_runtime_refuses_more_than_the_official_max_sequence(stand_in):
    with pytest.raises(ValueError, match="max sequence"):
        runtime.run_ppg(stand_in, np.zeros(1201 * 1024, dtype=np.float32), threads=1)
    with pytest.raises(ValueError, match="whole number"):
        runtime.run_ppg(stand_in, np.zeros(1000, dtype=np.float32), threads=1)


def test_thread_cap_is_applied_and_restored(stand_in, monkeypatch):
    seen = []
    inner = stand_in.model

    def spy(x):
        seen.append(torch.get_num_threads())
        return inner(x)

    loaded = copy.copy(stand_in)
    loaded.model = spy
    monkeypatch.setattr(runtime, "get_model", lambda _root: loaded)
    before = torch.get_num_threads()
    fixture = F.night([(0, 5 * 3600)])
    response = Wav2SleepPpgProvider(model_root="/stand-in", enabled=True, threads=2).infer(
        input=F.payload(fixture), context=F.context(fixture))
    assert response["status"] == "ok" and response["diagnostics"]["threads"] == 2
    assert seen == [2] and torch.get_num_threads() == before
    assert runtime.thread_cap(99) == C.MAX_THREADS and runtime.thread_cap("x") == 1
    assert runtime.thread_cap(0) == 1


def test_registry_shim_maps_ok_results_and_never_publishes(gap_night, stand_in):
    del stand_in
    shim = make_providers()[0]
    assert isinstance(shim, Wav2SleepRegistryShim)
    assert shim.provider_id == C.PROVIDER_ID and shim.metric == "sleep_stage"
    assert shim.publishable is False and shim.eligibility_state == "blocked_input"
    capability = shim.capability()
    assert capability["release_mode"] == "shadow" and capability["publishable"] is False
    assert capability["accuracy_label"] == "unverified_accuracy"
    assert capability["declarations"]["consumer"]["name"] == "sleep_stage_shadow_comparison"
    enabled = Wav2SleepRegistryShim(Wav2SleepPpgProvider(model_root="/stand-in", enabled=True))
    request = type("R", (), {"input": F.payload(gap_night), "context": F.context(gap_night),
                             "provider_id": C.PROVIDER_ID})()
    result = enabled.infer(request)
    assert isinstance(result, ProviderResult) and result.status == "ok"
    assert result.publishable is False and result.label_space == C.LABEL_SPACE
    assert result.stages and all(s["label"] in C.CLASS_ORDER for s in result.stages)
    assert result.value == 898 * 30          # the shim's scalar: scored seconds (coverage only)
    assert result.raw_scores["schema"] == "wav2sleep.ppg-only.epochs/1"
    identity = enabled.runtime_identity()
    assert identity["provider_id"] == C.PROVIDER_ID and identity["release_mode"] == "shadow"
    assert HEX64.match(identity["model_code_digest"])
    loaded = enabled.loaded_identity()            # Spec 01 identity.py hook: flat strings, <= 32 keys
    assert loaded and len(loaded) <= 32 and all(isinstance(k, str) and isinstance(v, str) for k, v in loaded.items())
    assert loaded["release_mode"] == "shadow" and loaded["provider_id"] == C.PROVIDER_ID


def test_server_routes_an_explicit_request_to_the_registered_provider(gap_night):
    from frwhoop_inference.contract import parse_request
    from frwhoop_inference.providers import ProviderRegistry
    from frwhoop_inference.server import Application, run_inference

    registry = ProviderRegistry([Wav2SleepRegistryShim(
        Wav2SleepPpgProvider(model_root="/stand-in", enabled=True))])
    app = Application.build(registry=registry, model_root="/nonexistent")
    assert app.provider_states[C.PROVIDER_ID].ready is True
    ctx = F.context(gap_night)
    body = {"metric": "sleep_stage",
            "context": {**ctx, "interval_start_utc": "2026-06-08T06:58:07Z",
                        "interval_end_utc": "2026-06-08T14:48:07Z"},
            "input": F.payload(gap_night),
            "provider": {"provider_id": C.PROVIDER_ID}}
    wire = run_inference(app, parse_request(body))
    assert wire["status"] == "ok" and wire["publishable"] is False
    assert wire["label_space"] == C.LABEL_SPACE and wire["result"]["stages"]
    assert wire["raw_scores"]["release_mode"] == "shadow"


class _CapturingModel:
    """Records the exact PPG tensor every forward receives."""

    def __init__(self, model):
        self.model = model
        self.inputs = []

    def __call__(self, x):
        self.inputs.append({k: v.detach().clone() for k, v in x.items()})
        return self.model(x)


def test_the_adapter_never_flips_polarity_silently(monkeypatch):
    """The checkpoint is polarity-sensitive and WHOOP's optical polarity is unverified, so the PPG
    must reach the model with the sign it arrived with: a negated night gives exactly the negated
    model input (no inversion, rectification or auto-correction), and different outputs."""
    loaded = copy.copy(H.stand_in_model(seed=3))
    capture = _CapturingModel(loaded.model)
    loaded.model = capture
    monkeypatch.setattr(runtime, "get_model", lambda _root: loaded)
    provider = Wav2SleepPpgProvider(model_root="/stand-in", enabled=True, threads=1)
    fixture = F.night([(0, 5 * 3600)])
    negated = F.payload(fixture)
    for segment in negated["ppg"]["segments"]:
        segment["samples"] = [-v for v in segment["samples"]]
    pos = provider.infer(input=F.payload(fixture), context=F.context(fixture))
    neg = provider.infer(input=negated, context=F.context(fixture))
    assert pos["status"] == neg["status"] == "ok"
    (x_pos,), (x_neg,) = [list(i.values()) for i in capture.inputs]
    assert torch.equal(x_neg, -x_pos), "the input sign was changed on the way to the model"
    assert pos["raw_scores"]["probabilities"]["values"] != neg["raw_scores"]["probabilities"]["values"]
    assert pos["diagnostics"]["polarity"] == neg["diagnostics"]["polarity"] == "as_received"
    assert "polarity" not in C.DEFAULT_CONFIG, "there is no switch that could flip it"
    assert "whoop_optical_polarity_and_domain_characterised" in C.ACTIVATION_GATES


def test_declared_24_hz_is_staged_on_the_same_epoch_grid(provider):
    a = F.night([(0, 5 * 3600)], rate=25)
    b = F.night([(0, 5 * 3600)], rate=24)
    ra = provider.infer(input=F.payload(a), context=F.context(a))
    rb = provider.infer(input=F.payload(b), context=F.context(b))
    assert ra["status"] == rb["status"] == "ok"
    assert ra["raw_scores"]["epoch_start_utc"] == rb["raw_scores"]["epoch_start_utc"]
    assert ra["raw_scores"]["mask"] == rb["raw_scores"]["mask"]
    assert rb["raw_scores"]["native_sample_provenance"]["native_rate_hz"] == 24
    assert rb["raw_scores"]["native_sample_provenance"]["native_samples_per_epoch_used"] == 721
    assert ra["diagnostics"]["digests"]["input"] != rb["diagnostics"]["digests"]["input"]


def test_a_run_id_discontinuity_is_split_staged_separately_and_counted(provider):
    fixture = F.night([(0, 9 * 3600)])
    payload = F.payload(fixture)
    del payload["ppg"]["segments"][54]            # a 300-s hole inside run-0 at 4.5 h
    response = provider.infer(input=payload, context=F.context(fixture))
    assert response["status"] == "ok", response["diagnostics"]
    assert response["coverage"]["ppg_run_id_discontinuity"] == 1
    assert response["diagnostics"]["ppg_run_id_discontinuity"] == 1
    staged = [r for r in response["diagnostics"]["runs"] if r["staged"]]
    assert [(r["run_id"], r["run_id_piece"]) for r in staged] == [("run-0", 0), ("run-0", 1)]
    assert response["coverage"]["mask_reason_counts"]["no_ppg"] >= 9   # the hole is never bridged
