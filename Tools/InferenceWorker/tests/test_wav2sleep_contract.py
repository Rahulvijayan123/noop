"""wav2sleep input contract: every withheld reason, PPG-only refusals, the legacy segment shape and
the Spec 01 members pinned in docs/model-integration/README.md (ff143411e + 0fd8b94d3).

All fixtures are SYNTHETIC (tests/wav2sleep_fixtures.py). Each withheld case is refused before
any model is loaded; a guard that fails the test if the model is ever loaded proves it.
"""

import pytest

import wav2sleep_fixtures as F
from frwhoop_inference.contract import ProviderResult, WithheldReason
from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep import runtime
from frwhoop_inference.frwhoop_sleep.wav2sleep.contract import parse_night
from frwhoop_inference.frwhoop_sleep.wav2sleep.provider import Wav2SleepPpgProvider
from frwhoop_inference.frwhoop_sleep.wav2sleep.registry import Wav2SleepRegistryShim


@pytest.fixture(scope="module")
def base():
    """A valid 5-hour, single-run synthetic night at the anchored 25 Hz rate (300-s pieces)."""
    return F.night([(0, 5 * 3600)])


@pytest.fixture(autouse=True)
def model_must_not_load(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise AssertionError("the model was loaded for an input that must be withheld")

    monkeypatch.setattr(runtime, "get_model", refuse)
    monkeypatch.setattr(runtime, "run_ppg", refuse)


def call(payload, fixture, provider=None, **context_overrides):
    provider = provider or Wav2SleepPpgProvider(model_root="/nonexistent", enabled=True)
    ctx = F.context(fixture)
    ctx.update(context_overrides)
    return provider.infer(input=payload, context=ctx)


def expect(response, detail, reason=None):
    assert response["status"] == "withheld", response.get("diagnostics")
    assert response["diagnostics"]["reason_detail"] == detail, response["diagnostics"]
    assert response["withheld_reason"] == (reason or C.WIRE_REASON[detail])
    assert response["withheld_reason"] in {r.value for r in WithheldReason}
    assert response["result"] is None and response["raw_scores"] is None
    assert response["release_mode"] == "shadow"
    return response


def mutated(fixture, fn):
    payload = F.payload(fixture)
    fn(payload)
    return payload


def test_every_detail_maps_to_a_sidecar_withheld_reason():
    enum = {r.value for r in WithheldReason}
    assert set(C.WIRE_REASON.values()) <= enum


def test_disabled_lane_withholds_not_ready_without_parsing(base):
    provider = Wav2SleepPpgProvider(model_root="/nonexistent", enabled=False)
    expect(call({"garbage": True}, base, provider), "lane_disabled", "not_ready")


def test_provider_id_mismatch(base):
    response = Wav2SleepPpgProvider(enabled=True).infer(
        input=F.payload(base), context=F.context(base), provider={"provider_id": "sleepecg.wrn-gru-mesa.v1"})
    expect(response, "provider_id_mismatch")


def test_window_longer_than_the_official_max_sequence_is_withheld_not_truncated(base):
    payload = F.payload(base)
    payload["window"] = {"start_utc": base["window"]["start_utc"],
                         "end_utc": base["window"]["start_utc"] + C.MAX_WINDOW_SECONDS + 30}
    response = expect(call(payload, base), "night_too_long", "blocked_input")
    assert response["diagnostics"]["max_window_seconds"] == 36_000


def test_invalid_window(base):
    payload = F.payload(base)
    payload["window"] = {"start_utc": 100, "end_utc": 100}
    expect(call(payload, base), "invalid_window")
    payload["window"] = {"start_utc": 100, "end_utc": 115}
    expect(call(payload, base), "invalid_window")


# -- native rate: declared, from a small explicit set, consistent with the clock ----------------

@pytest.mark.parametrize("rate", C.SUPPORTED_NATIVE_RATES_HZ)
def test_each_supported_declared_rate_is_accepted_and_recorded(rate):
    fixture = F.night([(0, 5 * 3600)], rate=rate)
    night = parse_night(F.payload(fixture), F.context(fixture))
    assert night.native_rate_hz == rate and night.runs[0].rate_hz == rate
    assert night.runs[0].samples.size == 5 * 3600 * rate


def test_supported_rates_are_explicit_and_nothing_is_hard_coded_to_24():
    assert C.SUPPORTED_NATIVE_RATES_HZ == (24, 25)
    assert C.ANCHORED_V26_NATIVE_RATE_HZ == 25
    assert not hasattr(C, "NATIVE_RATE_HZ"), "the native rate is declared by the request"


@pytest.mark.parametrize("declared", [None, 26, 32, "25", 24.5, True])
def test_undeclared_or_unsupported_rate_is_refused(base, declared):
    def set_rate(payload):
        if declared is None:
            payload["ppg"].pop("native_rate_hz")
        else:
            payload["ppg"]["native_rate_hz"] = declared

    expect(call(mutated(base, set_rate), base), "unsupported_native_rate", "blocked_input")


def test_segment_sample_count_must_match_the_declared_rate(base):
    def per_second(payload):
        payload["ppg"]["segments"][3]["sample_count_per_second"] = 24

    expect(call(mutated(base, per_second), base), "unsupported_native_rate")


@pytest.mark.parametrize("value", [24, None, "25"])
def test_clock_samples_per_second_must_equal_the_declared_rate(base, value):
    def set_clock_rate(payload):
        clock = payload["ppg"]["segments"][2]["clock"]
        if value is None:
            clock.pop("samples_per_second")
        else:
            clock["samples_per_second"] = value

    expect(call(mutated(base, set_clock_rate), base), "clock_rate_mismatch", "blocked_input")


def test_samples_at_the_wrong_rate_for_the_declaration_are_not_contiguous(base):
    """25 Hz declared but 24 samples per second sent: the segment is short, never re-timed."""
    legacy = F.night([(0, 5 * 3600)], rate=24)
    payload = F.payload(legacy)
    payload["ppg"]["native_rate_hz"] = 25
    for segment in payload["ppg"]["segments"]:
        segment["sample_count_per_second"] = 25
        segment["clock"]["samples_per_second"] = 25
    expect(call(payload, legacy), "invalid_segment")


# -- clock: packet_timing_verified gates; source/grid/endpoint are provenance only ---------------

@pytest.mark.parametrize("clock", [
    None,                                                     # legacy shape: no clock at all
    {"samples_per_second": 25},                               # flag absent
    {"packet_timing_verified": False, "samples_per_second": 25},
    {"packet_timing_verified": "true", "samples_per_second": 25},
    {"verified": True, "samples_per_second": 25},             # the old assumed name is not read
])
def test_unverified_packet_timing_is_withheld(base, clock):
    def set_clock(payload):
        segment = payload["ppg"]["segments"][0]
        if clock is None:
            segment.pop("clock")
        else:
            segment["clock"] = clock

    expect(call(mutated(base, set_clock), base), "unverified_sample_clock", "unverified")


def test_clock_provenance_members_are_carried_and_never_gated(base):
    def odd_provenance(payload):
        for segment in payload["ppg"]["segments"]:
            segment["clock"]["source"] = 12345            # not even a string
            segment["clock"].pop("grid")
            segment["clock"]["endpoint"] = {"anything": True}

    night = parse_night(mutated(base, odd_provenance), F.context(base))
    assert len(night.runs) == 1
    assert night.runs[0].clock_provenance["source"] == "12345"
    assert "grid" not in night.runs[0].clock_provenance
    plain = parse_night(F.payload(base), F.context(base))
    assert plain.runs[0].clock_provenance == {"source": "synthetic fixture: strap record ts",
                                              "grid": "start_unix + j/25",
                                              "endpoint": "the next record's anchor belongs to the next second"}


# -- PPG only ------------------------------------------------------------------------------------

@pytest.mark.parametrize("key, value", [
    ("ecg", {"samples": [1, 2, 3]}),
    ("thx", [0.1, 0.2]),
    ("abd", {"source": "belt"}),
])
def test_other_modalities_are_not_admitted(base, key, value):
    payload = F.payload(base)
    payload[key] = value
    response = expect(call(payload, base), "channel_not_admitted")
    assert key in response["diagnostics"]["channels"]


@pytest.mark.parametrize("key, value", [
    ("thx", {"derived_from": "ppg", "method": "rsa", "samples": [0.0] * 10}),
    ("abd", {"source": "ppg_respiratory_modulation"}),
    ("rsa", [0.0] * 10),
    ("respiration", {"kind": "PPG-derived respiration"}),
])
def test_ppg_derived_respiration_is_refused_as_measured_effort(base, key, value):
    """An RSA/respiration waveform computed from the same PPG is never THX/ABD."""
    payload = F.payload(base)
    payload[key] = value
    response = expect(call(payload, base), "derived_respiration_refused")
    assert "not a measured" in response["diagnostics"]["message"]


def test_declared_signal_list_with_a_derived_thx_is_refused(base):
    payload = F.payload(base)
    payload["signals"] = {"PPG": {}, "THX": {"derived_from": "PPG"}}
    expect(call(payload, base), "derived_respiration_refused")
    payload["signals"] = ["PPG", "ECG"]
    expect(call(payload, base), "channel_not_admitted")
    payload["signals"] = ["PPG"]   # declaring the admitted modality alone is accepted
    night = parse_night(payload, F.context(base))
    assert len(night.runs) == 1


# -- anchor, sample domain -------------------------------------------------------------------------

def test_no_ppg_and_missing_anchor(base):
    expect(call({"window": base["window"]}, base), "no_ppg_segments")
    payload = {"window": base["window"],
               "ppg": {"native_rate_hz": 25, "units": "adc_counts", "segments": [],
                       "withheld_seconds": {"missing_ppg_anchor": 18_000}}}
    response = expect(call(payload, base), "missing_ppg_anchor", "blocked_input")
    assert response["diagnostics"]["producer_withheld_seconds"]["missing_ppg_anchor"] == 18_000


def test_delta_units_are_refused_as_unanchored(base):
    expect(call(mutated(base, lambda p: p["ppg"].update({"units": "deltas"})), base),
           "missing_ppg_anchor")


def test_legacy_deltas_sent_as_samples_are_detected(base):
    def to_deltas(payload):
        for segment in payload["ppg"]["segments"]:
            raw = segment["samples"]
            segment["samples"] = [0] + [b - a for a, b in zip(raw, raw[1:])]

    expect(call(mutated(base, to_deltas), base), "legacy_deltas_suspected", "blocked_input")


def test_short_segment_is_not_contiguous_at_the_native_rate(base):
    def drop(payload):
        payload["ppg"]["segments"][2]["samples"].pop()

    expect(call(mutated(base, drop), base), "invalid_segment")


def test_nonfinite_and_fractional_samples(base):
    def nan(payload):
        payload["ppg"]["segments"][1]["samples"][5] = float("nan")

    expect(call(mutated(base, nan), base), "nonfinite_samples")

    def frac(payload):
        payload["ppg"]["segments"][1]["samples"][5] = 378_000.5

    expect(call(mutated(base, frac), base), "non_integer_samples")


def test_saturated_samples_and_flags(base):
    def rail(payload):
        payload["ppg"]["segments"][4]["samples"][10] = C.ADC_SAMPLE_MAX

    expect(call(mutated(base, rail), base), "saturated_samples")

    def flag(payload):
        payload["ppg"]["segments"][4]["saturated"] = True

    expect(call(mutated(base, flag), base), "saturated_samples")


# -- optical configuration ---------------------------------------------------------------------------

def test_optical_configuration_rules(base):
    def no_identity(payload):
        payload["ppg"]["segments"][0]["config"].pop("identity")

    expect(call(mutated(base, no_identity), base), "optical_config_identity_missing", "blocked_input")

    def unstable(payload):
        payload["ppg"]["segments"][0]["config"]["stable"] = False

    expect(call(mutated(base, unstable), base), "optical_config_changed", "blocked_input")


@pytest.mark.parametrize("identity, known", [
    ("unknown", False),          # what the transport sends when it cannot identify the config
    ("Unknown", False),
    ("unknown", True),           # contradictory: "unknown" never identifies a configuration
    ("srcA=2;drvA=40", False),   # an identity string the transport itself does not vouch for
    ("srcA=2;drvA=40", None),
])
def test_unidentified_optical_configuration_is_refused(base, identity, known):
    def unidentified(payload):
        config = payload["ppg"]["segments"][1]["config"]
        config["identity"] = identity
        if known is None:
            config.pop("known")
        else:
            config["known"] = known

    response = expect(call(mutated(base, unidentified), base), "optical_config_unidentified",
                      "unverified")
    assert "polarity" in response["diagnostics"]["message"]


# -- run assembly: join within one run_id while contiguous; split + count violations -------------

def test_legacy_segment_shape_without_run_id_is_refused(base):
    """The pre-Spec-01 shape: no run_id, no clock, config {stable} only."""
    def legacy(payload):
        for segment in payload["ppg"]["segments"]:
            segment.pop("run_id")

    expect(call(mutated(base, legacy), base), "missing_run_id", "blocked_input")

    def fully_legacy(payload):
        for segment in payload["ppg"]["segments"]:
            segment.pop("run_id")
            segment.pop("clock")
            segment["config"] = {"stable": True}

    # the clock is checked per segment before run assembly
    expect(call(mutated(base, fully_legacy), base), "unverified_sample_clock")


def test_a_segment_without_run_id_is_its_own_run_and_is_never_joined():
    fixture = F.night([(0, 4 * 3600), (4 * 3600, 300)], run_ids=["a", None])
    night = parse_night(F.payload(fixture), F.context(fixture))
    assert [(r.run_id, r.seconds) for r in night.runs] == [("a", 14_400), (None, 300)]
    assert night.runs[0].end == night.runs[1].start      # touching, still separate
    assert night.run_id_discontinuities == 0


def test_a_gap_inside_one_run_id_is_split_and_counted_never_joined(base):
    def gap_in_run(payload):
        del payload["ppg"]["segments"][4]   # same run_id on both sides of a 300-s hole

    night = parse_night(mutated(base, gap_in_run), F.context(base))
    assert night.run_id_discontinuities == 1
    assert [(r.run_id, r.run_id_piece) for r in night.runs] == [("run-0", 0), ("run-0", 1)]
    assert night.runs[1].start - night.runs[0].end == 300
    detail = night.run_id_discontinuity_details[0]
    assert detail["reasons"] == ["gap"] and detail["run_id"] == "run-0"
    assert C.RUN_ID_DISCONTINUITY == "ppg_run_id_discontinuity"


def test_a_config_change_inside_one_run_id_is_split_and_counted(base):
    def changed(payload):
        for segment in payload["ppg"]["segments"][30:]:
            segment["config"]["identity"] = "srcA=2;drvA=55;rngA=3;offA=0;led=green"

    night = parse_night(mutated(base, changed), F.context(base))
    assert night.run_id_discontinuities == 1
    assert [r.config_identity for r in night.runs] == [
        F.DEFAULT_IDENTITY, "srcA=2;drvA=55;rngA=3;offA=0;led=green"]
    assert night.runs[0].end == night.runs[1].start           # contiguous in time, still split
    assert night.run_id_discontinuity_details[0]["reasons"] == ["config_identity_changed"]


def test_segment_order_and_overlap_are_structural_and_refused(base):
    def unsorted(payload):
        segs = payload["ppg"]["segments"]
        segs[1], segs[2] = segs[2], segs[1]

    expect(call(mutated(base, unsorted), base), "unsorted_segments")

    def overlap(payload):
        payload["ppg"]["segments"][3]["start_unix"] -= 10

    expect(call(mutated(base, overlap), base), "overlapping_segments")


# -- gates ---------------------------------------------------------------------------------------------

def test_too_many_segments_and_unknown_config(base):
    payload = F.payload(base, max_segments=10)
    expect(call(payload, base), "too_many_segments")
    expect(call(F.payload(base, not_a_gate=1), base), "unknown_config")
    expect(call(F.payload(base, max_window_seconds=40_000), base), "unknown_config")
    expect(call(F.payload(base, min_run_epochs=2.5), base), "unknown_config")


def test_runs_shorter_than_the_gate_are_never_staged():
    fixture = F.night([(0, 3600), (3700, 3600), (7400, 3600)])   # three 1-h runs
    response = expect(call(F.payload(fixture), fixture), "no_stageable_run", "insufficient_coverage")
    assert all(r["skip_reason"] == "run_too_short" for r in response["diagnostics"]["runs"])


def test_insufficient_overnight_coverage():
    fixture = F.night([(0, 3 * 3600)])                     # one 3-h run: 359 epochs < 480
    response = expect(call(F.payload(fixture), fixture), "insufficient_overnight_coverage",
                      "insufficient_coverage")
    assert response["diagnostics"]["scored_epochs"] < 480
    # enough epochs, too small a fraction of a long window
    wide = F.night([(0, 5 * 3600)], window=(F.DEFAULT_START - 3 * 3600, F.DEFAULT_START + 5 * 3600))
    response = expect(call(F.payload(wide), wide), "insufficient_overnight_coverage")
    assert response["diagnostics"]["coverage_fraction"] < 0.75


def test_withheld_results_map_onto_a_valid_provider_result(base):
    shim = Wav2SleepRegistryShim(Wav2SleepPpgProvider(model_root="/nonexistent", enabled=True))
    payload = mutated(base, lambda p: p.update({"thx": {"derived_from": "ppg"}}))
    request = type("R", (), {"input": payload, "context": F.context(base), "provider_id": None})()
    result = shim.infer(request)
    assert isinstance(result, ProviderResult)
    assert result.status == "withheld" and result.withheld_reason == "blocked_input"
    assert result.stages is None and result.value is None and result.publishable is False
    assert result.diagnostics["reason_detail"] == "derived_respiration_refused"
