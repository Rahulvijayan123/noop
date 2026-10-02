"""The HRV aggregation seam: ``input.aggregation`` vs the Swift worker's payload.

Audit S-1 (P1). The Swift worker's HRV payload (``DayScoring.hrvInput``) sends the
night's beats plus a SINGULAR ``input.window`` and states its aggregation intent
only inside ``input.config.aggregation`` (``"mean_over_windows"``). The parser read
neither, defaulted to ``"window"`` and scored ``outcomes[0]`` - the FIRST 5-minute
window - while ``coverage`` described the whole night.

Audit S-2 (P2). With that default, a night whose FIRST window was below the
20-clean-interval floor was withheld entirely, even when every other window was
clean.

These tests pin the repaired contract:

* ``mean_over_windows`` - top-level, or mirrored from ``input.config`` - scores the
  plain mean over the session's USABLE windows, exactly like
  ``SleepStager.sessionAvgHRV`` (never the first window);
* a withheld first window does not withhold the night;
* a session with no usable window still withholds, with a machine-readable reason;
* an explicit ``window`` request keeps the back-compat single-window behaviour;
* an unknown spelling is refused instead of being silently downgraded.
"""

from __future__ import annotations

import pytest

from conftest import hrv_body, iso
from frwhoop_inference.contract import (
    Beat,
    ContractError,
    HrvInput,
    Window,
    is_session_aggregation,
    parse_request,
)
from frwhoop_inference.providers.hrv import (
    DEFAULT_TUNING,
    HrvNeurokitShadowProvider,
    HrvProductionProvider,
    analyze_window,
    plan_windows,
)

# A three-window night: window k spans [NIGHT_START + 300k, +300).
NIGHT_START = 1_790_000_000
WINDOW_SEC = 300
#: One beat per second, alternating ``+a`` / ``-a``, so a window's RMSSD is ``2a``
#: exactly (and its neighbours are all within the 0.20 Malik radius).
AMPLITUDES = (5.0, 20.0, 45.0)
BEATS_PER_WINDOW = 60


def _night(amplitudes=AMPLITUDES, counts=None, *, start=NIGHT_START) -> list[Beat]:
    """A synthetic night: one segment per amplitude, one beat per second."""
    counts = list(counts) if counts is not None else [BEATS_PER_WINDOW] * len(amplitudes)
    beats: list[Beat] = []
    for index, (amplitude, count) in enumerate(zip(amplitudes, counts)):
        base = start + index * WINDOW_SEC
        for i in range(count):
            beats.append(Beat(ts=base + i, rr_ms=1000.0 + (amplitude if i % 2 == 0 else -amplitude),
                              seq=index * 1000 + i, ord=i))
    return beats


def _worker_body(beats, *, top_level: str | None = "mean_over_windows",
                 config: str | None = "mean_over_windows", start=NIGHT_START,
                 end=NIGHT_START + 3 * WINDOW_SEC) -> dict:
    """The worker's real payload shape.

    ``top_level=None`` is the PRE-REPAIR worker (intent only in ``config``);
    ``config=None`` is the post-repair worker (intent only at the top level).
    """
    body = hrv_body(beats, context_overrides={"interval_start_utc": iso(start),
                                              "interval_end_utc": iso(end)})
    payload = body["input"]
    if top_level is None:
        payload.pop("aggregation", None)
    else:
        payload["aggregation"] = top_level
    if config is not None:
        payload["config"] = {"window_sec": WINDOW_SEC, "aggregation": config,
                             "pooling": "sum_sq_and_pairs"}
    return body


def _session_mean_over_usable_windows(request, beats) -> tuple[float, int]:
    """The independent expectation: plain mean over the windows that pass floors.

    Computed from the provider's OWN window outcomes (so the windowing rules are
    not restated here) but with the aggregation done by this test, not by the
    provider's aggregation branch, which is what these tests are pinning.
    """
    windows = plan_windows(request.context.start_ts, request.context.end_ts,
                           request.input.windows, DEFAULT_TUNING)
    values = [o.rmssd for o in (analyze_window(w, beats, DEFAULT_TUNING) for w in windows)
              if o.rmssd is not None]
    assert values, "the fixture must leave at least one usable window"
    return sum(values) / float(len(values)), len(values)


# --------------------------------------------------------------------------
# Contract: which spellings are accepted, and where they may come from
# --------------------------------------------------------------------------


def test_top_level_mean_over_windows_is_accepted_and_kept():
    request = parse_request(_worker_body(_night(), config=None))
    assert isinstance(request.input, HrvInput)
    assert request.input.aggregation == "mean_over_windows"
    assert is_session_aggregation(request.input.aggregation) is True
    assert is_session_aggregation("session") is True
    assert is_session_aggregation("window") is False
    assert is_session_aggregation("day") is False


def test_config_aggregation_is_mirrored_when_the_top_level_key_is_absent():
    """The pre-repair worker states its intent ONLY in ``input.config``."""
    request = parse_request(_worker_body(_night(), top_level=None, config="mean_over_windows"))
    assert request.input.aggregation == "mean_over_windows"


def test_top_level_aggregation_wins_over_the_config_mirror():
    request = parse_request(_worker_body(_night(), top_level="window", config="mean_over_windows"))
    assert request.input.aggregation == "window"


def test_unknown_aggregation_spelling_is_refused_not_downgraded():
    with pytest.raises(ContractError) as top:
        parse_request(_worker_body(_night(), top_level="median"))
    assert top.value.code == "invalid_input"
    assert top.value.field == "input.aggregation"

    with pytest.raises(ContractError) as mirrored:
        parse_request(_worker_body(_night(), top_level=None, config="median"))
    assert mirrored.value.code == "invalid_input"
    assert mirrored.value.field == "input.config.aggregation"

    with pytest.raises(ContractError) as not_a_string:
        parse_request(_worker_body(_night(), top_level=7))  # type: ignore[arg-type]
    assert not_a_string.value.code == "invalid_input"


# --------------------------------------------------------------------------
# S-1: the value is the session mean over windows, never the first window
# --------------------------------------------------------------------------


def test_worker_payload_scores_the_session_mean_over_windows():
    """The audit's S-1 reproduction, at unit scale: 3 windows, 3 different RMSSDs."""
    beats = _night()
    request = parse_request(_worker_body(beats))
    expected, usable = _session_mean_over_usable_windows(request, beats)
    first_window = analyze_window(
        plan_windows(request.context.start_ts, request.context.end_ts, (), DEFAULT_TUNING)[0],
        beats, DEFAULT_TUNING)

    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"
    assert usable >= 3, "the fixture must be a multi-window night"
    assert outcome.coverage["usable_windows"] == usable
    assert outcome.value == pytest.approx(expected, abs=1e-9)
    assert outcome.value != pytest.approx(first_window.rmssd, abs=1e-6), (
        "the candidate value must not be the first window's RMSSD (audit S-1)")
    assert outcome.diagnostics["aggregation"] == "mean_over_windows"


def test_both_spellings_of_the_session_mean_agree_exactly():
    beats = _night()
    pre_repair = HrvProductionProvider().infer(
        parse_request(_worker_body(beats, top_level=None, config="mean_over_windows")))
    post_repair = HrvProductionProvider().infer(
        parse_request(_worker_body(beats, top_level="mean_over_windows", config=None)))
    legacy_alias = HrvProductionProvider().infer(
        parse_request(_worker_body(beats, top_level="session", config=None)))
    assert pre_repair.status == post_repair.status == legacy_alias.status == "ok"
    assert pre_repair.value == pytest.approx(post_repair.value, abs=0.0)
    assert post_repair.value == pytest.approx(legacy_alias.value, abs=0.0)


def test_capability_advertises_the_worker_spelling():
    aggregations = HrvProductionProvider().capability()["aggregations"]
    assert "mean_over_windows" in aggregations
    assert "window" in aggregations


# --------------------------------------------------------------------------
# S-2: a withheld first window does not withhold the night
# --------------------------------------------------------------------------


def test_withheld_first_window_does_not_withhold_the_night():
    """The first window has 19 clean intervals (one below the floor); the rest are clean.

    19 - not fewer - on purpose: a handful of consecutive beats inside a 300 s
    window banks more beat-time than its own span allows, so the window would be
    refused by the over-count gate instead of the beat floor, and this test is
    about the beat floor.
    """
    beats = _night(counts=(19, BEATS_PER_WINDOW, BEATS_PER_WINDOW))
    request = parse_request(_worker_body(beats))
    expected, usable = _session_mean_over_usable_windows(request, beats)

    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok", "a sparse FIRST window must not withhold the night (S-2)"
    assert usable == 2
    assert outcome.coverage["usable_windows"] == 2
    assert outcome.coverage["total_windows"] == 3
    assert outcome.value == pytest.approx(expected, abs=1e-9)
    assert outcome.diagnostics["windows"][0]["withheld_detail"] == "insufficient_clean_beats"
    assert outcome.diagnostics["windows"][0]["rmssd_ms"] is None


def test_a_session_with_no_usable_window_still_withholds():
    beats = _night(counts=(19, 19, 19))
    outcome = HrvProductionProvider().infer(parse_request(_worker_body(beats)))
    assert outcome.status == "withheld"
    assert outcome.value is None
    assert outcome.withheld_reason == "insufficient_coverage"
    assert outcome.diagnostics["withheld_detail"] == "insufficient_clean_beats"


# --------------------------------------------------------------------------
# Back-compat: an explicit ``window`` request still scores one window
# --------------------------------------------------------------------------


def test_explicit_window_aggregation_still_scores_the_first_window():
    beats = _night()
    request = parse_request(_worker_body(beats, top_level="window", config=None))
    first_window = analyze_window(
        plan_windows(request.context.start_ts, request.context.end_ts, (), DEFAULT_TUNING)[0],
        beats, DEFAULT_TUNING)

    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"
    assert outcome.value == pytest.approx(first_window.rmssd, abs=1e-9)
    assert outcome.diagnostics["aggregation"] == "window"
    # ...and the whole-night mean is a DIFFERENT number, which is exactly the
    # divergence the repaired worker payload avoids.
    mean_over_windows, _usable = _session_mean_over_usable_windows(request, beats)
    assert outcome.value != pytest.approx(mean_over_windows, abs=1e-6)


def test_absent_aggregation_keeps_the_documented_defaults():
    """No top-level key, no config: supplied windows aggregate, derived do not."""
    beats = _night()
    derived = parse_request(_worker_body(beats, top_level=None, config=None))
    assert derived.input.aggregation == "window"
    supplied = parse_request(hrv_body(
        beats, aggregation="session",
        context_overrides={"interval_start_utc": iso(NIGHT_START),
                           "interval_end_utc": iso(NIGHT_START + 3 * WINDOW_SEC)}))
    assert supplied.input.aggregation == "session"


# --------------------------------------------------------------------------
# The shadow provider takes the same session path for the same spelling
# --------------------------------------------------------------------------


def test_shadow_provider_takes_the_session_path_for_mean_over_windows():
    """The S-1 repair applies to BOTH providers: the shadow must not fall through to
    the duration-weighted day branch when the caller asked for the session mean."""
    beats = _night()
    request = parse_request(_worker_body(beats, top_level=None, config="mean_over_windows"))
    shadow = HrvNeurokitShadowProvider().infer(request)
    assert shadow.status == "ok", shadow.withheld_reason
    expected, usable = _session_mean_over_usable_windows(request, beats)
    assert usable >= 3
    # the shadow reports its own (NeuroKit2) window values, so compare shapes, not numbers:
    # exactly one session was aggregated and the value is not the first window's.
    assert len(shadow.diagnostics["sessions"]) == 1
    assert shadow.diagnostics["windows"][0]["rmssd_ms"] is not None
    assert shadow.value != pytest.approx(shadow.diagnostics["windows"][0]["rmssd_ms"], abs=1e-6)
    assert shadow.publishable is False
    assert expected > 0  # the production expectation is asserted in its own test above


def test_shadow_provider_refuses_two_sessions_under_mean_over_windows():
    """Same rule as production: the session mean is only defined for ONE session.

    ``day`` is the spelling that weights across sessions, so it must not be what
    ``mean_over_windows`` silently does.
    """
    beats = _night()
    windows = [Window(start=NIGHT_START + i * WINDOW_SEC, end=NIGHT_START + (i + 1) * WINDOW_SEC,
                      session_id=("night" if i < 2 else "nap")) for i in range(3)]
    common = {"interval_start_utc": iso(NIGHT_START),
              "interval_end_utc": iso(NIGHT_START + 3 * WINDOW_SEC)}
    session_body = hrv_body(beats, windows=windows, aggregation="mean_over_windows",
                            context_overrides=common)
    shadow_session = HrvNeurokitShadowProvider().infer(parse_request(session_body))
    assert shadow_session.status == "withheld"
    # the DETAIL is what proves the branch: the session rule refused, the day rule did not.
    # (The shadow maps every non-artifact detail to ``insufficient_coverage``; production
    # reports ``blocked_input`` for this same refusal. That reason-string difference is
    # pre-existing and unchanged here.)
    assert shadow_session.diagnostics["withheld_detail"] == "multiple_sessions_with_session_aggregation"

    day_body = hrv_body(beats, windows=windows, aggregation="day",
                        context_overrides=common)
    shadow_day = HrvNeurokitShadowProvider().infer(parse_request(day_body))
    assert shadow_day.status == "ok", shadow_day.withheld_reason
