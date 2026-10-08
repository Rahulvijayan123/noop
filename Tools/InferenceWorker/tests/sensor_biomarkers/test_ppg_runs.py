"""Run-aware PPG computation (Spec 01 section 3; docs/model-integration/README.md).

Pulse detection, morphology, quality windows and the AC/DC ratio run inside one contiguous,
configuration-compatible run at a time; results aggregate with each run's real exposure;
amplitude is reported per configuration identity (per run when the configuration is
unidentified); the request's sample arrays are never written. Expectations are checked against
independent references: the same signal sent as one run, each run sent on its own, and the pooled
per-pulse values recomputed outside the document assembly.
"""

from __future__ import annotations

import copy
import hashlib
import json

import numpy as np
import pytest

from frwhoop_inference.contract import parse_request
from frwhoop_inference.sensor_biomarkers import ppg as sbppg
from frwhoop_inference.sensor_biomarkers.provider import SensorBiomarkersProvider

from ppg_run_helpers import (
    UNKNOWN_CLOCK,
    body,
    pulse_wave,
    segment,
    stages,
    unknown_segment,
)

RATE = 25.0
T0 = 1_780_000_000


def _families(segments, rate=RATE, families=None, **kw):
    return stages(SensorBiomarkersProvider(), body(segments, rate=rate, families=families, **kw))


def _pulse_doc(segments, rate=RATE):
    return sbppg.compute_pulse_shape(sbppg._validate_segments(segments, rate), rate)


def _quality_doc(segments, rate=RATE, expected=None):
    return sbppg.compute_ppg_quality(sbppg._validate_segments(segments, rate), rate,
                                     expected_duration_s=expected)


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

class TestRunAssembly:
    def test_segments_sharing_a_run_id_join_only_when_contiguous_and_compatible(self):
        wave = pulse_wave(90, RATE)
        segs = sbppg._validate_segments([
            unknown_segment(T0, wave[:750], run_id="ppg-a"),
            unknown_segment(T0 + 30, wave[750:1500], run_id="ppg-a"),
            # same run_id after a 10 s gap: split, never joined
            unknown_segment(T0 + 70, wave[1500:2250], run_id="ppg-a"),
        ], RATE)
        runs, counts = sbppg.build_ppg_runs(segs)
        assert [r.key for r in runs] == ["ppg-a", "ppg-a#2"]
        assert [r.duration for r in runs] == [60.0, 30.0]
        assert runs[0].segment_indices == (0, 1)
        assert counts == {"ppg_run_id_discontinuity": 1}
        # joined samples are a read-only copy of both segments, in order
        assert not runs[0].samples.flags.writeable
        assert np.array_equal(runs[0].samples, wave[:1500])

    def test_a_configuration_or_clock_change_inside_a_run_id_splits(self):
        wave = pulse_wave(60, RATE)
        segs = sbppg._validate_segments([
            segment(T0, wave[:750], RATE, run_id="r", identity="led=green;gain=1", known=True,
                    clock=UNKNOWN_CLOCK),
            segment(T0 + 30, wave[750:], RATE, run_id="r", identity="led=green;gain=2",
                    known=True, clock=UNKNOWN_CLOCK),
        ], RATE)
        runs, counts = sbppg.build_ppg_runs(segs)
        assert len(runs) == 2 and counts["ppg_run_id_discontinuity"] == 1
        segs = sbppg._validate_segments([
            unknown_segment(T0, wave[:750], run_id="r"),
            unknown_segment(T0 + 30, wave[750:], run_id="r",
                            clock={**UNKNOWN_CLOCK, "phase_s": 0.02}),
        ], RATE)
        runs, _ = sbppg.build_ppg_runs(segs)
        assert len(runs) == 2

    def test_legacy_segments_are_each_their_own_run(self):
        wave = pulse_wave(60, 24.0)
        segs = sbppg._validate_segments([segment(T0, wave[:720], 24.0),
                                         segment(T0 + 30, wave[720:], 24.0)], 24.0)
        runs, counts = sbppg.build_ppg_runs(segs)
        assert [r.key for r in runs] == ["segment-0", "segment-1"]
        assert counts == {}
        assert sbppg.legacy_request(segs)


# ---------------------------------------------------------------------------
# No cross-boundary pulses
# ---------------------------------------------------------------------------

class TestNoCrossBoundaryPulses:
    def _halves(self):
        wave = pulse_wave(120, RATE)
        # cut in the middle of a pulse: 72 bpm -> 1.2 Hz; the peak of the beat that
        # starts at 60 s is at 60.125 s, so 60.08 s falls inside its upstroke
        cut = int(60.08 * RATE)
        return wave, cut

    def test_pulse_straddling_a_run_boundary_is_never_detected(self):
        wave, cut = self._halves()
        first, second = wave[:cut], wave[cut:]
        start2 = T0 + cut / RATE
        joined = _pulse_doc([unknown_segment(T0, first, run_id="r"),
                             unknown_segment(start2, second, run_id="r")])
        separate = _pulse_doc([unknown_segment(T0, first, run_id="r1"),
                               unknown_segment(start2, second, run_id="r2")])
        only_first = _pulse_doc([unknown_segment(T0, first, run_id="r1")])
        only_second = _pulse_doc([unknown_segment(start2, second, run_id="r2")])
        count = lambda d: d["measurements"]["pulse_accepted_count"]["value"]  # noqa: E731
        # Two runs are exactly the two runs analysed on their own: nothing is
        # found that needs samples from both sides of the boundary ...
        assert count(separate) == count(only_first) + count(only_second)
        assert separate["eligible_seconds"] == pytest.approx(
            only_first["eligible_seconds"] + only_second["eligible_seconds"])
        # ... while the same samples as one run do yield the straddling pulse.
        assert count(joined) > count(separate)

    def test_a_gap_never_becomes_a_pseudo_pulse(self):
        # Two stretches 20 s apart whose ends would splice into one fake beat
        # if concatenated (upstroke before the gap, decay after it).
        wave = pulse_wave(160, RATE)
        a, b = wave[: int(60.08 * RATE)], wave[int(80.5 * RATE):]
        segs = [unknown_segment(T0, a, run_id="r1"),
                unknown_segment(T0 + 80.5, b, run_id="r2")]
        doc = _pulse_doc(segs)
        alone = [_pulse_doc([s]) for s in segs]
        count = lambda d: d["measurements"]["pulse_accepted_count"]["value"]  # noqa: E731
        assert count(doc) == sum(count(d) for d in alone)
        # The old behaviour, one concatenated signal, accepts extra beats around
        # the splice that never existed.
        spliced = _pulse_doc([unknown_segment(T0, np.concatenate([a, b]), run_id="x")])
        assert count(spliced) > count(doc)

    def test_configuration_change_at_the_boundary_splits_like_separate_runs(self):
        wave, cut = self._halves()
        start2 = T0 + cut / RATE
        changed = _pulse_doc([
            segment(T0, wave[:cut], RATE, run_id="r", identity="gain=1", known=True),
            segment(start2, wave[cut:], RATE, run_id="r", identity="gain=2", known=True)])
        assert changed["reason_counts"]["ppg_run_id_discontinuity"] == 1
        assert {c["configuration"] for c in changed["configurations"]} == {"gain=1", "gain=2"}
        separate = _pulse_doc([
            segment(T0, wave[:cut], RATE, run_id="r1", identity="gain=1", known=True),
            segment(start2, wave[cut:], RATE, run_id="r2", identity="gain=2", known=True)])
        assert ([c["accepted"] for c in changed["configurations"]]
                == [c["accepted"] for c in separate["configurations"]])


# ---------------------------------------------------------------------------
# Exposure
# ---------------------------------------------------------------------------

class TestExposure:
    def test_quality_windows_never_span_runs_and_seconds_are_per_run(self):
        wave = pulse_wave(90, RATE)
        halves = [wave[: int(45 * RATE)], wave[int(45 * RATE):]]
        joined = _quality_doc([unknown_segment(T0, halves[0], run_id="r"),
                               unknown_segment(T0 + 45, halves[1], run_id="r")])
        split = _quality_doc([unknown_segment(T0, halves[0], run_id="r1"),
                              unknown_segment(T0 + 45, halves[1], run_id="r2")])
        # one 90 s run holds three complete 30 s windows; two 45 s runs hold one each
        assert joined["eligible_seconds"] == 90.0
        assert split["eligible_seconds"] == 60.0
        assert [r["eligible_seconds"] for r in split["runs"]["listed"]] == [30.0, 30.0]
        assert split["runs"]["eligible_seconds"] == 60.0
        assert split["measurements"]["template_similarity_median"]["count"] == 2

    def test_shared_run_id_chunks_match_the_contiguous_signal_exactly(self):
        wave = pulse_wave(600, RATE)
        contiguous = _families([unknown_segment(T0, wave, run_id="r")])
        chunked = _families([unknown_segment(T0, wave[:7500], run_id="r"),
                             unknown_segment(T0 + 300, wave[7500:], run_id="r")])
        for family in ("ppg_quality", "pulse_shape"):
            assert chunked[family]["measurements"] == contiguous[family]["measurements"], family
            assert chunked[family]["eligible_seconds"] == contiguous[family]["eligible_seconds"]

    def test_pooling_weights_each_pulse_once_not_each_run(self):
        # A long run of narrow pulses and a short run of wide pulses: the pooled
        # width50 median is the median over all accepted pulses (exposure
        # weighted), not the mean of the two run medians.
        narrow = pulse_wave(120, RATE, upstroke_frac=0.10)
        wide = pulse_wave(30, RATE, upstroke_frac=0.30, t0=200.0)
        segs = sbppg._validate_segments([unknown_segment(T0, narrow, run_id="n"),
                                         unknown_segment(T0 + 200, wide, run_id="w")], RATE)
        doc = sbppg.compute_pulse_shape(segs, RATE)
        runs, _ = sbppg.build_ppg_runs(segs)
        widths, durations = [], []
        per_run_medians = []
        for run in runs:
            analysed = sbppg._analyse_run(run, RATE, with_quality=False)
            metrics = sbppg._pulse_metrics(analysed["clean"], RATE, analysed["detected"])
            widths.extend(metrics["widths_ms"])
            durations.extend(metrics["durations_s"])
            per_run_medians.append(float(np.median(metrics["widths_ms"])))
        pooled = doc["measurements"]["pulse_width50_median_ms"]["value"]
        assert pooled == pytest.approx(float(np.median(widths)))
        assert pooled != pytest.approx(float(np.mean(per_run_medians)), rel=1e-3)
        assert doc["eligible_seconds"] == pytest.approx(sum(durations))
        assert doc["measurements"]["pulse_accepted_count"]["value"] == len(widths)


# ---------------------------------------------------------------------------
# Amplitude per configuration identity / per run
# ---------------------------------------------------------------------------

class TestAmplitudeScope:
    def test_identified_configurations_are_reported_separately_never_pooled(self):
        low = pulse_wave(60, RATE, amp=30000.0)
        high = pulse_wave(60, RATE, amp=60000.0, t0=60.0)
        doc = _pulse_doc([
            segment(T0, low, RATE, run_id="a", identity="led=green;drive=10", known=True),
            segment(T0 + 60, high, RATE, run_id="b", identity="led=green;drive=20", known=True)])
        assert doc["status"] == "ok"
        assert doc["pooled_across_configurations"] is False
        assert "pulse_amplitude_median_au" not in doc["measurements"]
        blocks = {c["configuration"]: c for c in doc["configurations"]}
        a = blocks["led=green;drive=10"]["measurements"]["pulse_amplitude_median_au"]
        b = blocks["led=green;drive=20"]["measurements"]["pulse_amplitude_median_au"]
        assert b["value"] == pytest.approx(2 * a["value"], rel=0.05)
        assert a["configuration"] == "led=green;drive=10" and a["configuration_known"] is True
        amp_dists = [d for c in doc["configurations"] for d in c["distributions"]
                     if d["key"] == "pulse_amplitude_median_au"]
        assert {d["configuration"] for d in amp_dists} == set(blocks)

    def test_one_identity_across_runs_pools_its_amplitude(self):
        doc = _pulse_doc([
            segment(T0, pulse_wave(60, RATE), RATE, run_id="a", identity="cfg-1", known=True),
            segment(T0 + 100, pulse_wave(60, RATE, t0=100.0), RATE, run_id="b",
                    identity="cfg-1", known=True)])
        assert len(doc["configurations"]) == 1
        top = doc["measurements"]["pulse_amplitude_median_au"]
        assert top["configuration"] == "cfg-1" and top["configuration_known"] is True
        assert doc["configurations"][0]["runs"] == 2

    def test_unidentified_configuration_reports_amplitude_per_run(self):
        # The path real v26 data takes: identity "unknown", known false, 25 Hz,
        # run_id "ppg-<start>", clock not verified against packet timing.
        amps = (20000.0, 30000.0, 45000.0)
        segs = [unknown_segment(T0 + 100 * i, pulse_wave(60, RATE, amp=amp, t0=100.0 * i))
                for i, amp in enumerate(amps)]
        doc = _pulse_doc(segs)
        assert doc["status"] == "ok"
        assert doc["amplitude_scope"] == "per_run"
        assert doc["amplitude_scope_reason"] == "configuration_unidentified"
        # never pooled: no amplitude at the top level or in the pooled block
        assert not set(sbppg.AMPLITUDE_KEYS) & set(doc["measurements"])
        (block,) = doc["configurations"]
        assert block["configuration"] == "unknown" and block["configuration_unidentified"] is True
        assert not set(sbppg.AMPLITUDE_KEYS) & set(block["measurements"])
        assert all(d["key"] != "pulse_amplitude_median_au" for d in doc.get("distributions", []))
        # ... reported per run instead, each run with its own level
        per_run = doc["run_amplitudes"]
        assert per_run["configuration_unidentified"] is True and per_run["runs"] == 3
        listed = per_run["listed"]
        assert [row["run"] for row in listed] == [f"ppg-{T0 + 100 * i}" for i in range(3)]
        medians = [row["pulse_amplitude_median_au"] for row in listed]
        assert medians[1] == pytest.approx(medians[0] * 1.5, rel=0.05)
        assert medians[2] == pytest.approx(medians[0] * 2.25, rel=0.05)
        # gain-independent features are pooled across the runs, labelled so
        width = doc["measurements"]["pulse_width50_median_ms"]
        assert width["configuration_known"] is False
        assert width["configuration_scope"] == "pooled_across_unidentified_runs"
        assert "configuration" not in width  # the app must not show a "stable configuration"
        assert doc["native_rate_hz"] == 25.0 and doc["native_sample_period_ms"] == 40.0

    def test_per_run_listings_are_bounded(self):
        segs = [unknown_segment(T0 + 20 * i, pulse_wave(10, RATE, t0=20.0 * i))
                for i in range(30)]
        doc = _pulse_doc(segs)
        assert doc["run_amplitudes"]["runs"] == 30
        assert len(doc["run_amplitudes"]["listed"]) == sbppg.MAX_LISTED_RUNS
        assert doc["run_amplitudes"]["listed_truncated"] == 30 - sbppg.MAX_LISTED_RUNS
        assert len(doc["runs"]["listed"]) == sbppg.MAX_LISTED_RUNS
        assert doc["runs"]["count"] == 30
        assert len(json.dumps(doc)) < 64 * 1024

    def test_configuration_blocks_are_bounded(self):
        segs = [segment(T0 + 20 * i, pulse_wave(10, RATE, t0=20.0 * i), RATE, run_id=f"r{i}",
                        identity=f"cfg-{i}", known=True) for i in range(12)]
        doc = _pulse_doc(segs)
        assert len(doc["configurations"]) == sbppg.MAX_LISTED_CONFIGURATIONS
        assert doc["configurations_truncated"] == 12 - sbppg.MAX_LISTED_CONFIGURATIONS
        assert doc["measurements"] == {}

    def test_config_known_false_is_stated_in_the_measurement_provenance(self):
        doc = _pulse_doc([segment(T0, pulse_wave(60, RATE), RATE, run_id="r",
                                  identity="src=1;drv=?", known=False)])
        amp = doc["measurements"]["pulse_amplitude_median_au"]
        assert amp["configuration"] == "src=1;drv=?" and amp["configuration_known"] is False

    def test_legacy_identity_is_unknown_to_the_transport(self):
        doc = _pulse_doc([segment(T0, pulse_wave(60, 24.0), 24.0)], rate=24.0)
        amp = doc["measurements"]["pulse_amplitude_median_au"]
        assert amp["configuration"] == "stable=True" and amp["configuration_known"] is False
        assert doc["configurations"][0]["identity_source"] == "legacy_config_members"


# ---------------------------------------------------------------------------
# Rates, gates and validation
# ---------------------------------------------------------------------------

class TestRatesAndGates:
    def test_the_native_rate_comes_from_the_request(self):
        fam = _families([unknown_segment(T0, pulse_wave(120, RATE))])
        assert fam["pulse_shape"]["native_rate_hz"] == 25.0
        assert fam["ppg_quality"]["native_rate_hz"] == 25.0
        assert fam["pulse_shape"]["status"] == "ok"

    @pytest.mark.parametrize("mutate, detail", [
        (lambda s: s["clock"].update({"samples_per_second": 24}), "clock.samples_per_second"),
        (lambda s: s.update({"sample_count_per_second": 24}), "sample_count_per_second"),
        (lambda s: s.update({"run_id": 7}), "run_id"),
        (lambda s: s["config"].update({"identity": ""}), "config.identity"),
        (lambda s: s["config"].update({"known": "yes"}), "config.known"),
        (lambda s: s.update({"clock": ["not", "an", "object"]}), "clock"),
        (lambda s: s["clock"].update({"packet_timing_verified": "true"}), "packet_timing_verified"),
    ])
    def test_malformed_run_aware_members_withhold_only_the_ppg_families(self, mutate, detail):
        seg = unknown_segment(T0, pulse_wave(60, RATE))
        mutate(seg)
        imu = {"sampling_rate_hz": 100, "units": {"accel": "g", "gyro": "deg/s"},
               "segments": [{"start_unix": T0, "duration_s": 60,
                             "accel_g": [[0.0, 0.0, 1.0]] * 6000,
                             "gyro_dps": [[0.0, 0.0, 0.0]] * 6000}]}
        fam = _families([seg], families=["movement", "ppg_quality", "pulse_shape"], imu=imu)
        assert fam["movement"]["status"] == "ok"
        for family in ("ppg_quality", "pulse_shape"):
            assert fam[family]["status"] == "withheld"
            assert fam[family]["reason"] == "blocked_input"
            assert detail in fam[family]["detail"]

    def test_short_and_noise_only_runs_are_withheld_per_run_not_crashed(self):
        rng = np.random.default_rng(4)
        segs = [unknown_segment(T0, pulse_wave(5, RATE)),                       # <= one 6 s window
                unknown_segment(T0 + 20, 200000 + rng.normal(0, 40, 750)),       # noise only
                unknown_segment(T0 + 100, pulse_wave(60, RATE, t0=100.0))]
        doc = _pulse_doc(segs)
        assert doc["status"] == "ok"
        assert doc["reason_counts"]["ppg_run_shorter_than_detector_window"] == 1
        assert doc["reason_counts"]["ppg_run_no_pulses_detected"] == 1
        statuses = [row["status"] for row in doc["runs"]["listed"]]
        assert statuses == ["shorter_than_detector_window", "no_pulses_detected", "used"]
        quality = _quality_doc(segs)
        assert quality["status"] == "ok"
        assert quality["eligible_seconds"] == 60.0

    def test_legacy_request_keeps_its_request_wide_corruption_gate(self):
        clean = pulse_wave(60, 24.0)
        clipped = pulse_wave(60, 24.0, t0=60.0)
        clipped[100:104] = sbppg.ADC_SAMPLE_MAX
        legacy = [segment(T0, clean, 24.0), segment(T0 + 60, clipped, 24.0)]
        q = _quality_doc(legacy, rate=24.0, expected=120.0)
        assert q["template_similarity_withheld"] is True
        assert q["measurements"]["valid_waveform_fraction"]["value"] == 0.0
        assert _pulse_doc(legacy, rate=24.0)["status"] == "withheld"
        # The run-aware request excludes only the clipped run.
        run_aware = [segment(T0, clean, 24.0, run_id="a", identity="unknown", known=False),
                     segment(T0 + 60, clipped, 24.0, run_id="b", identity="unknown", known=False)]
        q = _quality_doc(run_aware, rate=24.0, expected=120.0)
        assert "template_similarity_median" in q["measurements"]
        assert q["measurements"]["valid_waveform_fraction"]["value"] == pytest.approx(0.5)
        assert q["reason_counts"]["saturated_delta"] == 4
        p = _pulse_doc(run_aware, rate=24.0)
        assert p["status"] == "ok" and p["reason_counts"]["saturated_delta"] == 4
        assert [row["status"] for row in p["runs"]["listed"]] == ["used", "corrupt"]

    def test_perfusion_is_per_identity_and_never_for_an_unidentified_configuration(self):
        dc = {"dc_verified": True, "channel": "A"}
        two = sbppg._validate_segments([
            segment(T0, pulse_wave(60, RATE), RATE, run_id="a", identity="g1", known=True),
            segment(T0 + 60, pulse_wave(60, RATE, amp=60000.0, t0=60.0), RATE, run_id="b",
                    identity="g2", known=True)], RATE)
        doc = sbppg.compute_perfusion_research(two, RATE, optical_dc=dc)
        assert doc["status"] == "ok" and doc["measurements"] == {}
        assert {c["configuration"] for c in doc["configurations"]} == {"g1", "g2"}
        unknown = sbppg._validate_segments([unknown_segment(T0, pulse_wave(60, RATE))], RATE)
        doc = sbppg.compute_perfusion_research(unknown, RATE, optical_dc=dc)
        assert doc["status"] == "withheld" and doc["reason"] == "unverified_optical_dc"
        assert doc["reason_counts"] == {"configuration_unidentified": 1}


# ---------------------------------------------------------------------------
# Immutability
# ---------------------------------------------------------------------------

def _digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True,
                                     default=lambda o: o.tolist()).encode()).hexdigest()


def test_request_samples_are_never_modified():
    wave = pulse_wave(120, RATE)
    as_array = wave.copy()
    segs = [segment(T0, as_array[:1500], RATE, run_id="r", identity="g1", known=True),
            segment(T0 + 60, as_array[1500:], RATE, run_id="r", identity="g1", known=True)]
    segs[0]["samples"] = as_array[:1500]          # a numpy view, the strongest aliasing case
    segs.append(segment(T0 + 200, pulse_wave(60, RATE, t0=200.0).tolist(), RATE, run_id="s",
                        identity="g1", known=True))
    request_body = body(segs, families=["ppg_quality", "pulse_shape", "perfusion_research"])
    request_body["input"]["ppg"]["optical_dc"] = {"dc_verified": True, "channel": "A"}
    before = _digest(copy.deepcopy(request_body["input"]))
    request = parse_request(request_body)
    SensorBiomarkersProvider().infer(request)
    assert _digest(request_body["input"]) == before
    assert np.array_equal(as_array, wave)
    validated = sbppg._validate_segments(request_body["input"]["ppg"]["segments"], RATE)
    assert all(not s["samples"].flags.writeable for s in validated)
    assert not np.shares_memory(validated[0]["samples"], as_array)
