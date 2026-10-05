"""HRV providers.

Two providers, never conflated:

``production.runs.v1``
    Authoritative. A faithful port of the shipped engine semantics
    (``HRVAnalyzer`` / ``IntradaySeries`` / ``SleepStager``): range filter,
    Malik ectopic rejection, gap-aware adjacency, observation-identity dedup,
    5-minute tumbling windows closed on end, pooled squared differences and pair
    counts, plain-mean session aggregation with an over-count gate, and a
    duration-weighted day mean.

``neurokit2.shadow.v1``
    Gated comparison only. Calls ``neurokit2.hrv_time`` on the SAME cleaned
    interval series with reconstructed interval-END timestamps, and is labelled
    ``unverified_accuracy``. It can never publish a canonical value.

Both follow the hard rules recorded in
``/tmp/frwhoop-physiology/findings/hrv-neurokit.md`` section 6d:

1. never pass a bare list of RR values to ``hrv_time``;
2. never pass interval START times as ``RRI_Time``;
3. never feed whole-second store timestamps to ``hrv_time``;
4. never call ``signal_fixpeaks(method="neurokit")``;
5. never feed corrected peaks back into the interval series;
6. never use ``signal_quality`` / ``ecg_quality`` / ``ppg_quality``;
7. keep the original interval evidence and record before/after counts;
8. report valid pairs and coverage separately from the beat floor.

In addition this adapter applies the spec-section-5 requirements the shipped
engine does not: retransmission is removed by *observation identity*, and a
withheld result always carries a machine-readable reason.

Aggregation seam (audit S-1 / S-2)
----------------------------------
``input.aggregation`` decides the result:

``window``
    Score the first window. With SUPPLIED windows the contract requires exactly
    one, so this is unambiguous. With DERIVED windows (no ``input.windows``) a
    multi-window interval scores its FIRST 5 minutes and ignores the rest. That
    is retained only as back-compat for an explicit caller; the Swift worker
    states ``mean_over_windows`` instead.
``mean_over_windows``
    The nightly session value: the plain mean over the session's USABLE windows
    (``score_session``, the port of ``SleepStager.sessionAvgHRV``), with the
    over-count gate applied at SESSION level, withholding only when no usable
    window is left. A window the floor refused - including the first one - does
    not withhold the night (this is the S-2 repair).
``session``
    The legacy alias for ``mean_over_windows`` (same arithmetic). Kept so no
    earlier caller breaks; ``contract.is_session_aggregation`` is the single
    predicate both providers ask.
``day``
    Duration-weighted mean of session means.

``contract._resolve_hrv_aggregation`` reads a top-level ``input.aggregation``
first and mirrors ``input.config.aggregation`` (the only place the pre-repair
worker stated its intent, ``DayScoring.hrvConfig()``) when the top-level key is
absent. Before that repair the parser ignored the config copy and defaulted to
``window``, so the candidate value was the first window's RMSSD rather than the
session mean (audit S-1); an unknown spelling is now refused, not downgraded.

Spec section 5 vs the shipped code (verified divergences)
---------------------------------------------------------
Spec section 5 asks for "minimum 30 clean intervals, maximum 20 % artifact
fraction, minimum three usable windows, and median-window aggregation, subject
to current-code verification". The shipped Swift code does not implement those
numbers, and this port is faithful to the SHIPPED CODE, not to the spec's
provisional list. The divergences are recorded here so no reader assumes the
spec's thresholds are in force:

===========================  ==========================  ==========================
Spec section 5 (provisional)  Shipped code / this port    Evidence
===========================  ==========================  ==========================
minimum 30 clean intervals    ``min_clean_beats = 20``    ``HRVAnalyzer.swift:33``
                                                          (``minBeats = 20``)
maximum 20 % artifact         no nightly artifact gate    ``HRVAnalyzer.swift``
fraction                      (``max_rejected_fraction    exposes no such
                              = None``, ``min_coverage     constant; the port's
                              = 0.0``); the gate exists    defaults keep both
                              and is reachable only by     gates off, so
                              explicit tuning              ``artifact_fraction``
                                                          is reachable only via
                                                          the over-count path
minimum three usable windows  no such floor; a session    ``SleepStager.swift``
                              with one usable window is    ``:2958-2973``
                              scored
median-window aggregation     plain mean over windows     ``SleepStager.swift``
                                                          ``sessionAvgHRV``
                                                          (:2958-2973)
===========================  ==========================  ==========================

Consequence: the README's list of machine-readable withheld reasons is honest
about the vocabulary, but ``low_coverage`` and ``high_rejected_fraction`` fire
only when a caller tunes ``min_coverage`` / ``max_rejected_fraction`` away from
their shipped defaults. A stricter shadow gate, if wanted, belongs in the
candidate lane's tuning and must be recorded as a deliberate divergence.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from typing import Any, Iterable, Sequence

from ..contract import (
    ADAPTER_VERSION,
    TIMESTAMP_CONVENTION,
    TIMESTAMP_RESOLUTION,
    Beat,
    HrvInput,
    InferRequest,
    ProviderResult,
    Window,
    WithheldReason,
    is_session_aggregation,
    pooled_rmssd,
)

PRODUCTION_PROVIDER_ID = "production.runs.v1"
SHADOW_PROVIDER_ID = "neurokit2.shadow.v1"

NEUROKIT2_VERSION = "0.2.13"
NUMPY_VERSION = "2.5.3"

PRODUCTION_PREPROCESSING_VERSION = "hrv.preprocess.production.runs.v1"
SHADOW_PREPROCESSING_VERSION = "hrv.preprocess.neurokit2.shadow.v1"

#: Providers that may be promoted to canonical output. Only the production
#: provider qualifies; the shadow provider is permanently comparison-only.
PUBLISHABLE_PROVIDERS = (PRODUCTION_PROVIDER_ID,)


# --------------------------------------------------------------------------
# Tuning (defaults are the shipped code's constants)
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class HrvTuning:
    """Every threshold the port uses, with the shipped value as the default.

    ``HRVAnalyzer.swift``: rrMinMs=300 (:29), rrMaxMs=2000 (:31), minBeats=20
    (:33), ectopicThreshold=0.20 (:36), ectopicWindowRadius=2 (:40),
    coveragePlausibleCeiling=1.10 (:581), beatAccuracyToleranceS=0.5 (:521),
    beatAccuracyMinFraction=0.5 (:529).
    ``IntradaySeries.swift``: spliceToleranceSeconds=3.0 (:80).
    ``SleepStager.swift``: windowS = 5*60 (:3012).
    """

    window_sec: int = 300
    #: 20, not the spec's provisional 30: ``HRVAnalyzer.swift:33`` (``minBeats``).
    min_clean_beats: int = 20
    min_pairs: int = 1
    #: 0.0 (off), because the shipped analyzer has no nightly coverage floor. The
    #: ``low_coverage`` withheld branch is therefore reachable only when a caller
    #: tunes this away from its default (audit S-3).
    min_coverage: float = 0.0
    #: None (off), for the same reason: the shipped analyzer has no nightly
    #: artifact-fraction gate, so ``high_rejected_fraction`` needs explicit tuning
    #: and ``artifact_fraction`` is otherwise reachable only via the over-count
    #: path (audit S-3).
    max_rejected_fraction: float | None = None
    splice_tolerance_s: float = 3.0
    rr_min_ms: float = 300.0
    rr_max_ms: float = 2000.0
    malik_threshold: float = 0.20
    malik_radius: int = 2
    coverage_ceiling: float = 1.10
    coverage_floor: float = 1.0 - (1.10 - 1.0)
    beat_accuracy_tolerance_s: float = 0.5
    beat_accuracy_min_fraction: float = 0.5
    #: Rounding of whole-second timestamps allowed before a bucket counts as
    #: under-filled (a dropout). Shadow-only.
    bucket_tolerance_s: float = 0.25
    #: One-sided allowance, in milliseconds, for a reconstructed series whose
    #: beats bank more time than its store span allows. Two whole-second
    #: endpoints can each round by up to a second, so this absorbs that rounding
    #: while still refusing a genuine over-count. Shadow-only.
    store_overfill_allowance_ms: float = 2000.0
    #: A window shorter than this cannot be judged by its own R-R coverage:
    #: whole-second timestamps under-report the span by up to one second, so on a
    #: 12-second window the flooring bias alone is ~9% and would fire the
    #: over-count gate on clean data. The nightly path gates over-count at the
    #: SESSION level (``SleepStager.sessionHrvOverCounted``), where the same bias
    #: is negligible; this floor keeps the per-window gate honest.
    over_count_min_span_s: float = 300.0
    #: Cap on per-window diagnostics echoed back in the response.
    max_window_diagnostics: int = 512

    def to_wire(self) -> dict[str, Any]:
        return asdict(self)


DEFAULT_TUNING = HrvTuning()


# --------------------------------------------------------------------------
# Cleaning primitives (ports of the shipped Swift)
# --------------------------------------------------------------------------


def median(values: Sequence[float]) -> float:
    """Median of a non-empty sequence (``HRVAnalyzer.median``, :964-970)."""
    ordered = sorted(values)
    n = len(ordered)
    if n == 0:
        return 0.0
    if n % 2 == 1:
        return ordered[n // 2]
    return (ordered[n // 2 - 1] + ordered[n // 2]) / 2.0


def range_filter(rr: Sequence[float], tuning: HrvTuning) -> list[float]:
    """Keep only intervals inside ``[rr_min_ms, rr_max_ms]``, preserving order."""
    return [v for v in rr if tuning.rr_min_ms <= v <= tuning.rr_max_ms]


def reject_ectopic(nn: Sequence[float], tuning: HrvTuning) -> list[float]:
    """Malik-style ectopic rejection over a radius-2 centred window."""
    radius = tuning.malik_radius
    if len(nn) <= radius:
        return list(nn)
    kept: list[float] = []
    for i in range(len(nn)):
        lo = max(0, i - radius)
        hi = min(len(nn) - 1, i + radius)
        neighbours = [nn[j] for j in range(lo, hi + 1) if j != i]
        if len(neighbours) < 2:
            kept.append(nn[i])
            continue
        med = median(neighbours)
        if med <= 0 or abs(nn[i] - med) / med <= tuning.malik_threshold:
            kept.append(nn[i])
    return kept


def clean_rr_gap_aware_indexed(
    rr: Sequence[float], tuning: HrvTuning
) -> tuple[list[float], list[bool], list[int], int, int]:
    """``HRVAnalyzer.cleanRRGapAware`` (:167-203), keeping survivor indices.

    Returns ``(nn, contiguous, kept_orig, n_range_rejected, n_ectopic_rejected)``
    where ``kept_orig[k]`` is the index of ``nn[k]`` in the input series and
    ``contiguous[i]`` is true when ``nn[i]`` and ``nn[i-1]`` were adjacent beats
    in the ORIGINAL series. Index 0 is always false.
    """
    radius = tuning.malik_radius
    ranged_idx = [i for i, v in enumerate(rr) if tuning.rr_min_ms <= v <= tuning.rr_max_ms]
    ranged_val = [rr[i] for i in ranged_idx]
    kept_orig: list[int] = []
    kept_val: list[float] = []
    if len(ranged_val) <= radius:
        kept_orig = list(ranged_idx)
        kept_val = list(ranged_val)
    else:
        for i in range(len(ranged_val)):
            lo = max(0, i - radius)
            hi = min(len(ranged_val) - 1, i + radius)
            neighbours = [ranged_val[j] for j in range(lo, hi + 1) if j != i]
            if len(neighbours) < 2:
                keep = True
            else:
                med = median(neighbours)
                keep = True if med <= 0 else abs(ranged_val[i] - med) / med <= tuning.malik_threshold
            if keep:
                kept_orig.append(ranged_idx[i])
                kept_val.append(ranged_val[i])
    contiguous = [i > 0 and kept_orig[i] == kept_orig[i - 1] + 1 for i in range(len(kept_val))]
    return kept_val, contiguous, kept_orig, len(rr) - len(ranged_val), len(ranged_val) - len(kept_val)


def clean_rr_gap_aware(
    rr: Sequence[float], tuning: HrvTuning
) -> tuple[list[float], list[bool], int, int]:
    """``clean_rr_gap_aware_indexed`` without the survivor indices."""
    nn, contiguous, _kept_orig, n_range, n_ectopic = clean_rr_gap_aware_indexed(rr, tuning)
    return nn, contiguous, n_range, n_ectopic


def rmssd_gap_aware(nn: Sequence[float], contiguous: Sequence[bool]) -> tuple[float | None, int, int]:
    """``HRVAnalyzer.rmssdGapAware`` (:209-223): pooled sqrt(sum d^2 / pairs)."""
    sum_sq = 0.0
    pairs = 0
    excluded = 0
    for i in range(1, len(nn)):
        if contiguous[i]:
            delta = nn[i] - nn[i - 1]
            sum_sq += delta * delta
            pairs += 1
        else:
            excluded += 1
    return pooled_rmssd(sum_sq, pairs), pairs, excluded


def pnn50_gap_aware(nn: Sequence[float], contiguous: Sequence[bool]) -> float | None:
    """``HRVAnalyzer.pnn50GapAware`` (:228-241)."""
    nn50 = 0
    pairs = 0
    for i in range(1, len(nn)):
        if contiguous[i]:
            if abs(nn[i] - nn[i - 1]) > 50.0:
                nn50 += 1
            pairs += 1
    if pairs < 1:
        return None
    return float(nn50) / float(pairs) * 100.0


def sdnn(nn: Sequence[float]) -> float | None:
    """Sample SD (ddof=1), matching ``HRVAnalyzer.sdnnRaw`` (:104-110)."""
    if len(nn) < 2:
        return None
    mean = sum(nn) / len(nn)
    ss = sum((v - mean) ** 2 for v in nn)
    return math.sqrt(ss / (len(nn) - 1))


def continuous_runs(beats: Sequence[Beat], tolerance_s: float) -> list[list[Beat]]:
    """``IntradaySeries.continuousRuns`` (:254-269).

    A new run starts when the wall clock ran ahead of the previous beat's own
    length by more than ``tolerance_s``. Beats lost before storage never reach
    the cleaner, so only the timestamps reveal that two stored beats were not
    adjacent.
    """
    runs: list[list[Beat]] = []
    current: list[Beat] = []
    previous_ts: int | None = None
    for beat in beats:
        if (previous_ts is not None
                and float(beat.ts - previous_ts) - beat.rr_ms / 1000.0 > tolerance_s
                and current):
            runs.append(current)
            current = []
        current.append(beat)
        previous_ts = beat.ts
    if current:
        runs.append(current)
    return runs


# --------------------------------------------------------------------------
# Coverage
# --------------------------------------------------------------------------


def rr_coverage(ts: Sequence[int], rr: Sequence[float]) -> float:
    """Total beat-time / wall-clock span (``HRVAnalyzer.rrCoverage``, :601-606)."""
    if len(ts) < 2 or not rr:
        return 0.0
    span_ms = float(max(ts) - min(ts)) * 1000.0
    if span_ms <= 0:
        return 0.0
    return sum(rr) / span_ms


def collapsed_coverage(ts: Sequence[int], rr: Sequence[float], rr_tol_ms: float = 30.0) -> float:
    """Coverage after collapsing same-second near-duplicates
    (``HRVAnalyzer.collapsedCoverage``, :670-690)."""
    n = min(len(ts), len(rr))
    if n < 2:
        return 0.0
    order = sorted(range(n), key=lambda i: (ts[i], rr[i], i))
    kept_ts: list[int] = []
    kept_rr: list[float] = []
    for idx in order:
        t = ts[idx]
        r = rr[idx]
        dup = False
        j = len(kept_ts) - 1
        while j >= 0 and kept_ts[j] == t:
            if abs(kept_rr[j] - r) <= rr_tol_ms:
                dup = True
                break
            j -= 1
        if not dup:
            kept_ts.append(t)
            kept_rr.append(r)
    return rr_coverage(kept_ts, kept_rr)


def classify_coverage(coverage: float, collapsed: float, tuning: HrvTuning) -> str:
    """``HRVAnalyzer.classifyCoverage`` (:587-594)."""
    if not (coverage > 0):
        return "unmeasurable"
    if not (coverage >= tuning.coverage_floor):
        return "underCovered"
    if not (coverage > tuning.coverage_ceiling):
        return "plausible"
    return "crossSecondOverCount" if collapsed > tuning.coverage_ceiling else "sameSecondOverCount"


def successive_diff_is_trustworthy(verdict: str) -> bool:
    """``HRVAnalyzer.successiveDiffIsTrustworthy`` (:477-484)."""
    return verdict not in ("sameSecondOverCount", "crossSecondOverCount")


def beat_accurate_fraction(ts: Sequence[int], rr: Sequence[float], tuning: HrvTuning) -> float:
    """``HRVAnalyzer.beatAccurateFraction`` (:503-511)."""
    if len(ts) != len(rr) or len(ts) < 2:
        return 1.0
    accurate = 0
    for i in range(1, len(ts)):
        gap_s = float(ts[i] - ts[i - 1])
        if abs(gap_s - rr[i] / 1000.0) <= tuning.beat_accuracy_tolerance_s:
            accurate += 1
    return float(accurate) / float(len(ts) - 1)


# --------------------------------------------------------------------------
# Observation-identity dedup
# --------------------------------------------------------------------------


@dataclass
class DedupedSeries:
    beats: list[Beat]
    n_input: int
    n_duplicates_dropped: int

    @property
    def n_kept(self) -> int:
        return len(self.beats)


def dedup_by_observation_identity(beats: Sequence[Beat]) -> DedupedSeries:
    """Drop retransmitted copies of the same physical observation.

    Two beats are the same observation when their identity tuple matches:
    an explicit ``observation_id`` when present, otherwise
    ``(ts, rr_ms, src_channel, seq, ord)``. Two genuine beats inside one second
    with an equal value keep distinct identities because their ``seq``/``ord``
    differ (spec section 5: "Equal intervals in the same second can represent
    different genuine beats"). Beats with no delivery counters at all are
    indistinguishable and are therefore treated as duplicates.
    """
    seen: set[tuple[Any, ...]] = set()
    kept: list[Beat] = []
    for beat in beats:
        key = beat.identity
        if key in seen:
            continue
        seen.add(key)
        kept.append(beat)
    return DedupedSeries(beats=kept, n_input=len(beats), n_duplicates_dropped=len(beats) - len(kept))


# --------------------------------------------------------------------------
# Window analysis
# --------------------------------------------------------------------------


@dataclass
class WindowOutcome:
    window: Window
    n_input: int = 0
    n_clean: int = 0
    n_range_rejected: int = 0
    n_ectopic_rejected: int = 0
    n_runs: int = 0
    valid_pairs: int = 0
    gap_pairs_excluded: int = 0
    clean_beat_ms: float = 0.0
    window_ms: int = 0
    coverage: float = 0.0
    rr_coverage: float = 0.0
    collapsed_coverage: float = 0.0
    coverage_verdict: str = "unmeasurable"
    beat_accurate_fraction: float = 1.0
    mean_nn_ms: float | None = None
    sdnn_ms: float | None = None
    pnn50: float | None = None
    rmssd: float | None = None
    rejected_fraction: float = 0.0
    withheld_reason: str | None = None
    withheld_detail: str | None = None

    @property
    def usable(self) -> bool:
        return self.rmssd is not None

    def to_wire(self) -> dict[str, Any]:
        out = {
            "start_utc": _iso(self.window.start),
            "end_utc": _iso(self.window.end),
            "session_id": self.window.session_id,
            "stage": self.window.stage,
            "half_open": self.window.half_open,
            "n_input": self.n_input,
            "n_clean": self.n_clean,
            "n_range_rejected": self.n_range_rejected,
            "n_ectopic_rejected": self.n_ectopic_rejected,
            "n_runs": self.n_runs,
            "valid_pairs": self.valid_pairs,
            "gap_pairs_excluded": self.gap_pairs_excluded,
            "clean_beat_ms": round(self.clean_beat_ms, 3),
            "window_ms": self.window_ms,
            "coverage": round(self.coverage, 6),
            "rr_coverage": round(self.rr_coverage, 6),
            "collapsed_coverage": round(self.collapsed_coverage, 6),
            "coverage_verdict": self.coverage_verdict,
            "beat_accurate_fraction": round(self.beat_accurate_fraction, 6),
            "mean_nn_ms": None if self.mean_nn_ms is None else round(self.mean_nn_ms, 3),
            "sdnn_ms": None if self.sdnn_ms is None else round(self.sdnn_ms, 3),
            "pnn50": None if self.pnn50 is None else round(self.pnn50, 3),
            "rejected_fraction": round(self.rejected_fraction, 6),
            "rmssd_ms": None if self.rmssd is None else round(self.rmssd, 6),
            "withheld_reason": self.withheld_reason,
            "withheld_detail": self.withheld_detail,
        }
        return out


def _iso(ts: int) -> str:
    from ..contract import _fmt_utc

    return _fmt_utc(ts)


def analyze_window(window: Window, beats: Sequence[Beat], tuning: HrvTuning) -> WindowOutcome:
    """Clean and score one window (inclusive bounds, matching ``analyze``)."""
    in_window = [b for b in beats if window.contains(b.ts)]
    outcome = WindowOutcome(window=window, n_input=len(in_window),
                            window_ms=max(0, window.end - window.start) * 1000)
    ts = [b.ts for b in in_window]
    rr = [b.rr_ms for b in in_window]
    outcome.rr_coverage = rr_coverage(ts, rr)
    outcome.collapsed_coverage = collapsed_coverage(ts, rr)
    outcome.coverage_verdict = classify_coverage(outcome.rr_coverage, outcome.collapsed_coverage, tuning)
    outcome.beat_accurate_fraction = beat_accurate_fraction(ts, rr, tuning)

    if not in_window:
        outcome.withheld_reason = WithheldReason.INSUFFICIENT_COVERAGE.value
        outcome.withheld_detail = "no_beats_in_window"
        return outcome

    # Over-count gate first: a window whose beats bank more beat-time than the
    # wall clock allows cannot be trusted, and the window length is not what is
    # wrong with it. Skipped on windows too short for their own coverage figure
    # to be meaningful (see ``over_count_min_span_s``).
    if (outcome.window_ms >= tuning.over_count_min_span_s * 1000.0
            and not successive_diff_is_trustworthy(outcome.coverage_verdict)):
        outcome.withheld_reason = WithheldReason.ARTIFACT_FRACTION.value
        outcome.withheld_detail = f"over_count_{outcome.coverage_verdict}"
        return outcome

    runs = continuous_runs(in_window, tuning.splice_tolerance_s)
    outcome.n_runs = len(runs)
    sum_sq = 0.0
    clean_nn: list[float] = []
    contiguous_all: list[bool] = []
    for run in runs:
        values = [b.rr_ms for b in run]
        nn, contiguous, n_range, n_ectopic = clean_rr_gap_aware(values, tuning)
        outcome.n_range_rejected += n_range
        outcome.n_ectopic_rejected += n_ectopic
        if len(nn) <= 1:
            clean_nn.extend(nn)
            contiguous_all.extend([False] * len(nn))
            continue
        for i in range(1, len(nn)):
            if contiguous[i]:
                delta = nn[i] - nn[i - 1]
                sum_sq += delta * delta
                outcome.valid_pairs += 1
            else:
                outcome.gap_pairs_excluded += 1
        clean_nn.extend(nn)
        contiguous_all.extend(contiguous)

    # Every run boundary is a pair that was NOT adjacent: the wall clock ran
    # ahead of the interval, so beats between the two runs never reached the
    # cleaner. Count it as excluded rather than letting it vanish.
    outcome.gap_pairs_excluded += max(0, len(runs) - 1)

    outcome.n_clean = len(clean_nn)
    outcome.clean_beat_ms = sum(clean_nn)
    outcome.rejected_fraction = (1.0 - float(outcome.n_clean) / float(outcome.n_input)
                                if outcome.n_input else 0.0)
    if outcome.n_clean:
        outcome.mean_nn_ms = outcome.clean_beat_ms / float(outcome.n_clean)
    outcome.sdnn_ms = sdnn(clean_nn)
    outcome.pnn50 = pnn50_gap_aware(clean_nn, contiguous_all)
    outcome.coverage = (min(1.0, outcome.clean_beat_ms / float(outcome.window_ms))
                        if outcome.window_ms > 0 else 0.0)

    if outcome.n_clean < tuning.min_clean_beats:
        outcome.withheld_reason = WithheldReason.INSUFFICIENT_COVERAGE.value
        outcome.withheld_detail = "insufficient_clean_beats"
        return outcome
    if outcome.valid_pairs < 1:
        outcome.withheld_reason = WithheldReason.INSUFFICIENT_COVERAGE.value
        outcome.withheld_detail = "no_adjacent_pair"
        return outcome
    if outcome.valid_pairs < tuning.min_pairs:
        outcome.withheld_reason = WithheldReason.INSUFFICIENT_COVERAGE.value
        outcome.withheld_detail = "insufficient_valid_pairs"
        return outcome
    value = pooled_rmssd(sum_sq, outcome.valid_pairs)
    if value is None:
        outcome.withheld_reason = WithheldReason.PROVIDER_ERROR.value
        outcome.withheld_detail = "non_finite_rmssd"
        return outcome
    if outcome.coverage < tuning.min_coverage:
        outcome.withheld_reason = WithheldReason.INSUFFICIENT_COVERAGE.value
        outcome.withheld_detail = "low_coverage"
        return outcome
    if tuning.max_rejected_fraction is not None and outcome.rejected_fraction > tuning.max_rejected_fraction:
        outcome.withheld_reason = WithheldReason.ARTIFACT_FRACTION.value
        outcome.withheld_detail = "high_rejected_fraction"
        return outcome
    outcome.rmssd = value
    return outcome


def plan_windows(context_start: int, context_end: int, windows: Sequence[Window],
                 tuning: HrvTuning) -> list[Window]:
    """Resolve the analysis windows.

    With explicit windows the caller's boundaries are used verbatim. Without
    them the context interval is split into tumbling ``window_sec`` windows with
    the final window closed on ``end`` (``SleepStager.sessionHrvWindows``,
    :3005-3061).
    """
    if windows:
        return list(windows)
    out: list[Window] = []
    t = context_start
    window_sec = tuning.window_sec
    while True:
        is_final = t + window_sec >= context_end
        if is_final:
            out.append(Window(start=t, end=context_end))
            break
        out.append(Window(start=t, end=t + window_sec, half_open=True))
        t += window_sec
    return out


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------

_REASON_PRIORITY = (
    WithheldReason.ARTIFACT_FRACTION.value,
    WithheldReason.INSUFFICIENT_COVERAGE.value,
    WithheldReason.UNRESOLVED_ADJACENCY.value,
    WithheldReason.PROVIDER_ERROR.value,
)


def _dominant_reason(outcomes: Iterable[WindowOutcome]) -> tuple[str, str | None]:
    """Deterministic withheld reason for an aggregate with no usable window."""
    counts: dict[str, int] = {}
    details: dict[str, str | None] = {}
    for outcome in outcomes:
        if outcome.withheld_reason is None:
            continue
        counts[outcome.withheld_reason] = counts.get(outcome.withheld_reason, 0) + 1
        details.setdefault(outcome.withheld_reason, outcome.withheld_detail)
    if not counts:
        return WithheldReason.INSUFFICIENT_COVERAGE.value, "no_usable_window"
    best = max(counts.items(), key=lambda kv: (kv[1], -_REASON_PRIORITY.index(kv[0])
                                               if kv[0] in _REASON_PRIORITY else -len(_REASON_PRIORITY)))
    return best[0], details.get(best[0])


@dataclass
class SessionOutcome:
    session_id: str | None
    start: int
    end: int
    window_outcomes: list[WindowOutcome] = field(default_factory=list)
    value: float | None = None
    withheld_reason: str | None = None
    withheld_detail: str | None = None
    over_counted: bool = False
    rr_coverage: float = 0.0
    coverage_verdict: str = "unmeasurable"

    def to_wire(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "start_utc": _iso(self.start),
            "end_utc": _iso(self.end),
            "duration_s": max(0, self.end - self.start),
            "usable_windows": sum(1 for w in self.window_outcomes if w.usable),
            "total_windows": len(self.window_outcomes),
            "rmssd_ms": None if self.value is None else round(self.value, 6),
            "rr_coverage": round(self.rr_coverage, 6),
            "coverage_verdict": self.coverage_verdict,
            "over_counted": self.over_counted,
            "withheld_reason": self.withheld_reason,
            "withheld_detail": self.withheld_detail,
        }


def group_sessions(outcomes: Sequence[WindowOutcome]) -> list[SessionOutcome]:
    """Group window outcomes into sessions, preserving first-seen order."""
    order: list[str | None] = []
    groups: dict[str | None, list[WindowOutcome]] = {}
    for outcome in outcomes:
        key = outcome.window.session_id
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(outcome)
    sessions: list[SessionOutcome] = []
    for key in order:
        members = groups[key]
        sessions.append(SessionOutcome(
            session_id=key,
            start=min(w.window.start for w in members),
            end=max(w.window.end for w in members),
            window_outcomes=list(members),
        ))
    return sessions


def score_session(session: SessionOutcome, beats: Sequence[Beat], tuning: HrvTuning) -> SessionOutcome:
    """Plain mean over usable windows plus the over-count gate.

    ``SleepStager.sessionAvgHRV`` (:2958-2973) averages window RMSSDs with no
    weighting, then refuses the session outright when its own R-R banks more
    beat-time than the wall clock allows (``sessionHrvOverCounted``, :2980-2995).
    """
    in_session = [b for b in beats if session.start <= b.ts <= session.end]
    ts = [b.ts for b in in_session]
    rr = [b.rr_ms for b in in_session]
    session.rr_coverage = rr_coverage(ts, rr)
    session.coverage_verdict = classify_coverage(session.rr_coverage, session.rr_coverage, tuning)
    session.over_counted = not successive_diff_is_trustworthy(session.coverage_verdict)
    if session.over_counted:
        session.value = None
        session.withheld_reason = WithheldReason.ARTIFACT_FRACTION.value
        session.withheld_detail = f"over_count_{session.coverage_verdict}"
        return session
    usable = [w.rmssd for w in session.window_outcomes if w.usable and w.rmssd is not None]
    if not usable:
        reason, detail = _dominant_reason(session.window_outcomes)
        session.value = None
        session.withheld_reason = reason
        session.withheld_detail = detail
        return session
    session.value = sum(usable) / float(len(usable))
    return session


def score_day(sessions: Sequence[SessionOutcome]) -> tuple[float | None, str | None, str | None]:
    """Duration-weighted mean of session means (``AnalyticsEngine.avgHRVDaily``,
    :753-759). Sessions the over-count gate refused carry no weight."""
    total = 0.0
    weight = 0.0
    for session in sessions:
        if session.value is None:
            continue
        duration = float(max(0, session.end - session.start))
        total += session.value * duration
        weight += duration
    if weight <= 0:
        if not sessions:
            return None, WithheldReason.INSUFFICIENT_COVERAGE.value, "no_window"
        reason, detail = _dominant_reason(
            [w for s in sessions for w in s.window_outcomes] or []
        )
        return None, reason, detail
    return total / weight, None, None


# --------------------------------------------------------------------------
# Shared result assembly
# --------------------------------------------------------------------------


def _versions(preprocessing: str, dependency: str, config_version: str) -> dict[str, Any]:
    return {
        "adapter": ADAPTER_VERSION,
        "preprocessing": preprocessing,
        "dependency": dependency,
        "config": config_version,
        "model": None,
    }


def _window_diagnostics(outcomes: Sequence[WindowOutcome], tuning: HrvTuning) -> list[dict[str, Any]]:
    limit = tuning.max_window_diagnostics
    return [w.to_wire() for w in outcomes[:limit]]


def _pooled_summary(outcomes: Sequence[WindowOutcome]) -> dict[str, Any]:
    usable = [w for w in outcomes if w.usable]
    clean_beats = sum(w.n_clean for w in usable)
    clean_ms = sum(w.clean_beat_ms for w in usable)
    window_ms = sum(w.window_ms for w in usable)
    return {
        "usable_windows": len(usable),
        "total_windows": len(outcomes),
        "clean_beats": clean_beats,
        "clean_beat_ms": round(clean_ms, 3),
        "window_ms": window_ms,
        "coverage": round(min(1.0, clean_ms / float(window_ms)), 6) if window_ms > 0 else 0.0,
        "valid_pairs": sum(w.valid_pairs for w in usable),
        "gap_pairs_excluded": sum(w.gap_pairs_excluded for w in usable),
        "mean_nn_ms": round(clean_ms / clean_beats, 3) if clean_beats else None,
    }


# --------------------------------------------------------------------------
# production.runs.v1
# --------------------------------------------------------------------------


class HrvProductionProvider:
    """Authoritative HRV provider (port of the shipped engine)."""

    provider_id = PRODUCTION_PROVIDER_ID
    metric = "hrv"
    mode = "retrospective"
    label_space = None
    required_signals = ("rr_intervals",)
    eligibility_state = "eligible"
    eligibility_reason = None

    def __init__(self, tuning: HrvTuning = DEFAULT_TUNING):
        self.tuning = tuning

    # -- registry surface ---------------------------------------------------

    def versions(self, request: InferRequest | None = None) -> dict[str, Any]:
        config_version = request.context.config_version if request else "unbound"
        return _versions(PRODUCTION_PREPROCESSING_VERSION, f"numpy=={NUMPY_VERSION}", config_version)

    def readiness(self) -> tuple[bool, str | None]:
        try:  # numpy is the only runtime dependency of the production path
            import numpy  # noqa: F401
        except Exception as exc:  # pragma: no cover - exercised only on a broken env
            return False, f"{WithheldReason.BLOCKED_ARTIFACT.value}: numpy unavailable ({exc})"
        return True, None

    def capability(self) -> dict[str, Any]:
        return {
            "metric": self.metric,
            "provider_id": self.provider_id,
            "mode": self.mode,
            "required_signals": list(self.required_signals),
            "label_space": self.label_space,
            "unit": "ms",
            "publishable": True,
            "eligibility": {"state": self.eligibility_state, "reason": self.eligibility_reason},
            "versions": self.versions(),
            "aggregations": ["window", "mean_over_windows", "session", "day"],
            "thresholds": self.tuning.to_wire(),
        }

    # -- inference ---------------------------------------------------------

    def infer(self, request: InferRequest) -> ProviderResult:
        tuning = self.tuning
        payload: HrvInput = request.input
        context = request.context

        deduped = dedup_by_observation_identity(payload.beats)
        beats = deduped.beats

        windows = plan_windows(context.start_ts, context.end_ts, payload.windows, tuning)
        outcomes = [analyze_window(window, beats, tuning) for window in windows]

        versions = self.versions(request)
        diagnostics: dict[str, Any] = {
            "algorithm_id": self.provider_id,
            "aggregation": payload.aggregation,
            "n_input": deduped.n_input,
            "n_duplicates_dropped": deduped.n_duplicates_dropped,
            "n_after_dedup": deduped.n_kept,
            "n_runs": sum(w.n_runs for w in outcomes),
            "n_clean": sum(w.n_clean for w in outcomes),
            "n_range_rejected": sum(w.n_range_rejected for w in outcomes),
            "n_ectopic_rejected": sum(w.n_ectopic_rejected for w in outcomes),
            "valid_pairs": sum(w.valid_pairs for w in outcomes),
            "gap_pairs_excluded": sum(w.gap_pairs_excluded for w in outcomes),
            "clean_beat_ms": round(sum(w.clean_beat_ms for w in outcomes), 3),
            "window_ms": sum(w.window_ms for w in outcomes),
            "coverage": _pooled_summary(outcomes)["coverage"],
            "rr_coverage": round(rr_coverage([b.ts for b in beats], [b.rr_ms for b in beats]), 6),
            "collapsed_coverage": round(collapsed_coverage([b.ts for b in beats],
                                                           [b.rr_ms for b in beats]), 6),
            "coverage_verdict": classify_coverage(
                rr_coverage([b.ts for b in beats], [b.rr_ms for b in beats]),
                collapsed_coverage([b.ts for b in beats], [b.rr_ms for b in beats]),
                tuning),
            "beat_accurate_fraction": beat_accurate_fraction([b.ts for b in beats],
                                                             [b.rr_ms for b in beats], tuning),
            "rejected_fraction": (
                1.0 - float(sum(w.n_clean for w in outcomes)) / float(deduped.n_kept)
                if deduped.n_kept else 0.0),
            "mean_nn_ms": _pooled_summary(outcomes)["mean_nn_ms"],
            "sdnn_ms": None,
            "pnn50": None,
            "timestamp_convention": TIMESTAMP_CONVENTION,
            "timestamp_resolution": TIMESTAMP_RESOLUTION,
            "rounding": "none",
            "thresholds_used": tuning.to_wire(),
            "windows": _window_diagnostics(outcomes, tuning),
            "windows_truncated": len(outcomes) > tuning.max_window_diagnostics,
            "sessions": [],
            "withheld_detail": None,
        }
        coverage = _pooled_summary(outcomes)
        coverage["verdict"] = diagnostics["coverage_verdict"]

        # Window-level result. With SUPPLIED windows the contract has already
        # required exactly one, so ``outcomes[0]`` is that window. With DERIVED
        # windows a "window" request scores the first of them and silently ignores
        # the rest of the interval; that back-compat behaviour is retained (an
        # explicit caller asks for it) and is the reason the worker states
        # ``mean_over_windows``. See the module docstring's spec-vs-code table.
        if payload.aggregation == "window":
            outcome = outcomes[0]
            diagnostics["sdnn_ms"] = None if outcome.sdnn_ms is None else round(outcome.sdnn_ms, 3)
            diagnostics["pnn50"] = None if outcome.pnn50 is None else round(outcome.pnn50, 3)
            diagnostics["withheld_detail"] = outcome.withheld_detail
            if outcome.usable and outcome.rmssd is not None:
                return ProviderResult(
                    status="ok", value=outcome.rmssd, unit="ms", coverage=coverage,
                    diagnostics=diagnostics, versions=versions,
                    final_or_provisional="provisional" if context.live else "final",
                    publishable=True)
            return ProviderResult(
                status="withheld", value=None, unit="ms",
                withheld_reason=outcome.withheld_reason or WithheldReason.INSUFFICIENT_COVERAGE.value,
                coverage=coverage, diagnostics=diagnostics, versions=versions,
                final_or_provisional="provisional" if context.live else "final",
                publishable=True)

        # Session / day aggregation.
        sessions = [score_session(s, beats, tuning) for s in group_sessions(outcomes)]
        diagnostics["sessions"] = [s.to_wire() for s in sessions]
        # Coverage of the aggregated span, reported separately from the window
        # coverage: a night whose beats land in two windows out of ninety-six is
        # not adequately covered even though each usable window is.
        span_ms = sum(max(0, s.end - s.start) for s in sessions) * 1000
        coverage["session_span_ms"] = span_ms
        coverage["session_coverage"] = (
            round(min(1.0, coverage["clean_beat_ms"] / float(span_ms)), 6) if span_ms else 0.0)

        # ``mean_over_windows`` (the worker's spelling) and ``session`` (the legacy
        # alias) are the same arithmetic: the plain mean over the session's USABLE
        # windows, with the over-count gate applied at session level. A window the
        # floor refused therefore does NOT withhold the night (audit S-2) - only a
        # session with no usable window left withholds, and it names its reason.
        if is_session_aggregation(payload.aggregation):
            if len(sessions) != 1:
                diagnostics["withheld_detail"] = "multiple_sessions_with_session_aggregation"
                return ProviderResult(
                    status="withheld", value=None, unit="ms",
                    withheld_reason=WithheldReason.BLOCKED_INPUT.value,
                    coverage=coverage, diagnostics=diagnostics, versions=versions,
                    final_or_provisional="provisional" if context.live else "final",
                    publishable=True)
            session = sessions[0]
            if session.value is not None:
                return ProviderResult(
                    status="ok", value=session.value, unit="ms", coverage=coverage,
                    diagnostics=diagnostics, versions=versions,
                    final_or_provisional="provisional" if context.live else "final",
                    publishable=True)
            diagnostics["withheld_detail"] = session.withheld_detail
            return ProviderResult(
                status="withheld", value=None, unit="ms",
                withheld_reason=session.withheld_reason or WithheldReason.INSUFFICIENT_COVERAGE.value,
                coverage=coverage, diagnostics=diagnostics, versions=versions,
                final_or_provisional="provisional" if context.live else "final",
                publishable=True)

        # aggregation == "day"
        value, reason, detail = score_day(sessions)
        diagnostics["withheld_detail"] = detail
        if value is not None:
            return ProviderResult(
                status="ok", value=value, unit="ms", coverage=coverage,
                diagnostics=diagnostics, versions=versions,
                final_or_provisional="provisional" if context.live else "final",
                publishable=True)
        return ProviderResult(
            status="withheld", value=None, unit="ms",
            withheld_reason=reason or WithheldReason.INSUFFICIENT_COVERAGE.value,
            coverage=coverage, diagnostics=diagnostics, versions=versions,
            final_or_provisional="provisional" if context.live else "final",
            publishable=True)


# --------------------------------------------------------------------------
# neurokit2.shadow.v1
# --------------------------------------------------------------------------


@dataclass
class ReconstructedClock:
    """Interval END times reconstructed for ``neurokit2.hrv_time``."""

    end_times: list[float]
    resolved: bool
    detail: str | None
    n_buckets: int = 0
    store_span_ms: float = 0.0
    beat_time_ms: float = 0.0
    overfill_ms: float = 0.0
    n_runs: int = 0

    def to_wire(self) -> dict[str, Any]:
        return {
            "resolved": self.resolved,
            "detail": self.detail,
            "n_buckets": self.n_buckets,
            "store_span_ms": round(self.store_span_ms, 3),
            "beat_time_ms": round(self.beat_time_ms, 3),
            "overfill_ms": round(self.overfill_ms, 3),
            "n_runs": self.n_runs,
        }


def reconstruct_end_times(beats: Sequence[Beat], tuning: HrvTuning) -> ReconstructedClock:
    """Rebuild interval END times for NeuroKit2 from whole-second store stamps.

    Why this is needed
    ------------------
    ``RRInterval.ts`` is whole unix seconds (``Streams.swift:89``) while
    NeuroKit2's adjacency test has a 10 ms threshold
    (``intervals_utils.py:61-63``). Feeding the store
    stamps straight in discards most valid pairs and returns a plausible but
    badly wrong number (findings probe M: -35% on clean data, -95% on
    out-of-range data, silently). Hard rule 3 forbids it.

    How the clock is rebuilt
    ------------------------
    * Inside one delivery bucket (all beats sharing a ``ts``) the order comes
      from ``seq``/``ord``, and the end offsets come from RR accumulation. Two
      genuine beats in one second therefore get distinct sub-second end times.
    * Everywhere the accumulated beat time is continuous, so every genuinely
      adjacent pair satisfies ``|delta_t - rr| = 0`` and NeuroKit2 keeps it.
    * Where the store's own timestamps reveal lost time, production's
      ``continuousRuns`` splits the series; each split adds a one-second jump to
      the clock, which breaks NeuroKit2's mask for exactly the pair that spans
      the hole - the same pair production's gap-aware adjacency excludes.

    Refused (``resolved=False``) when the reconstruction cannot be trusted:
    missing ``seq``/``ord``, an ambiguous bucket order, or a series whose beats
    bank more time than its store span allows. The caller then withholds with
    ``unresolved_adjacency`` instead of guessing.
    """
    if not beats:
        return ReconstructedClock([], False, "no_beats")
    for index, beat in enumerate(beats):
        if beat.seq is None or beat.ord is None:
            return ReconstructedClock([], False, f"missing_seq_ord_at_{index}")

    # Bucket by ts (beats arrive ts-sorted) and check the delivery order is
    # unambiguous inside every bucket.
    buckets: list[tuple[int, list[Beat]]] = []
    for beat in beats:
        if buckets and buckets[-1][0] == beat.ts:
            buckets[-1][1].append(beat)
        else:
            buckets.append((beat.ts, [beat]))
    for ts, members in buckets:
        seen: set[tuple[int, int]] = set()
        for beat in members:
            key = (int(beat.seq), int(beat.ord))
            if key in seen:
                return ReconstructedClock([], False, f"ambiguous_bucket_order_at_{ts}",
                                          n_buckets=len(buckets))
            seen.add(key)

    beat_time_ms = sum(b.rr_ms for b in beats)
    mean_rr_ms = beat_time_ms / float(len(beats))
    store_span_ms = float(beats[-1].ts - beats[0].ts) * 1000.0
    # ``n`` intervals of mean length L span ``(n - 1) * L`` of wall clock between
    # the first and last beat, so the expected store span is the beat time minus
    # one interval. Both endpoints are whole seconds, so each can round by up to
    # a second: the one-sided allowance absorbs that. Under-filling is normal
    # (gaps) and is not refused.
    allowance_ms = tuning.store_overfill_allowance_ms
    overfill_ms = beat_time_ms - mean_rr_ms - store_span_ms
    if overfill_ms > allowance_ms:
        return ReconstructedClock([], False, "store_span_over_filled",
                                  n_buckets=len(buckets), store_span_ms=store_span_ms,
                                  beat_time_ms=beat_time_ms, overfill_ms=overfill_ms)

    runs = continuous_runs(beats, tuning.splice_tolerance_s)
    end_times: list[float] = []
    accumulated = 0.0
    jump = 0.0
    for run_index, run in enumerate(runs):
        if run_index > 0:
            jump += 1.0
        for beat in run:
            accumulated += beat.rr_ms / 1000.0
            end_times.append(accumulated + jump)
    return ReconstructedClock(end_times, True, None, n_buckets=len(buckets),
                              store_span_ms=store_span_ms, beat_time_ms=beat_time_ms,
                              overfill_ms=overfill_ms, n_runs=len(runs))


def _neurokit2_module():
    """Import neurokit2 lazily so server startup never depends on it."""
    import neurokit2  # noqa: PLC0415

    return neurokit2


def neurokit2_hrv_time(rr_ms: Sequence[float], end_times_s: Sequence[float]) -> dict[str, Any]:
    """Call ``neurokit2.hrv_time`` on the interval-native dict input path.

    Hard rules enforced here: the input is a dict carrying ``RRI`` (ms) and
    ``RRI_Time`` (END seconds), never a bare list (rule 1), never START times
    (rule 2), never the raw whole-second store timestamps (rule 3).
    ``sampling_rate=None`` selects the interval path explicitly: no peaks are
    involved, so a sampling rate would be meaningless.
    """
    nk = _neurokit2_module()
    frame = nk.hrv_time({"RRI": [float(v) for v in rr_ms],
                         "RRI_Time": [float(v) for v in end_times_s]},
                        sampling_rate=None)
    row = frame.iloc[0]

    def value(column: str) -> float | None:
        if column not in frame.columns:
            return None
        raw = row[column]
        try:
            out = float(raw)
        except (TypeError, ValueError):
            return None
        return out if math.isfinite(out) else None

    return {
        "rmssd": value("HRV_RMSSD"),
        "mean_nn": value("HRV_MeanNN"),
        "sdnn": value("HRV_SDNN"),
        "pnn50": value("HRV_pNN50"),
        "columns": [str(c) for c in frame.columns],
        "version": getattr(nk, "__version__", None),
    }


class HrvNeurokitShadowProvider:
    """Gated NeuroKit2 comparison provider. Never publishable."""

    provider_id = SHADOW_PROVIDER_ID
    metric = "hrv"
    mode = "retrospective"
    label_space = None
    required_signals = ("rr_intervals", "packet_delivery_order")
    eligibility_state = "unverified"
    eligibility_reason = "unverified_accuracy"

    def __init__(self, tuning: HrvTuning = DEFAULT_TUNING):
        self.tuning = tuning

    def versions(self, request: InferRequest | None = None) -> dict[str, Any]:
        config_version = request.context.config_version if request else "unbound"
        return _versions(SHADOW_PREPROCESSING_VERSION, f"neurokit2=={NEUROKIT2_VERSION}",
                         config_version)

    def readiness(self) -> tuple[bool, str | None]:
        try:
            nk = _neurokit2_module()
        except Exception as exc:  # pragma: no cover - exercised only on a broken env
            return False, f"{WithheldReason.BLOCKED_ARTIFACT.value}: neurokit2 unavailable ({exc})"
        version = getattr(nk, "__version__", None)
        if version != NEUROKIT2_VERSION:
            return False, (f"{WithheldReason.BLOCKED_ARTIFACT.value}: neurokit2=={version} "
                           f"is not the pinned {NEUROKIT2_VERSION}")
        return True, None

    def capability(self) -> dict[str, Any]:
        return {
            "metric": self.metric,
            "provider_id": self.provider_id,
            "mode": self.mode,
            "required_signals": list(self.required_signals),
            "label_space": self.label_space,
            "unit": "ms",
            "publishable": False,
            "accuracy_label": "unverified_accuracy",
            "eligibility": {"state": self.eligibility_state, "reason": self.eligibility_reason},
            "versions": self.versions(),
            "aggregations": ["window", "mean_over_windows", "session", "day"],
            "thresholds": self.tuning.to_wire(),
        }

    # -- inference ---------------------------------------------------------

    def _window_value(self, window: Window, beats: Sequence[Beat]) -> tuple[float | None, str | None,
                                                                            dict[str, Any]]:
        tuning = self.tuning
        # The SAME membership rule as the production path (``Window.contains``:
        # half-open on the upper bound for every tumbling window but the last), so
        # a beat landing exactly on a 300 s boundary is counted by the same single
        # window in both providers and the two differ only in arithmetic.
        in_window = [b for b in beats if window.contains(b.ts)]
        window_ms = max(0, window.end - window.start) * 1000
        detail: dict[str, Any] = {"n_input": len(in_window), "window_ms": window_ms}
        if not in_window:
            return None, "no_beats_in_window", detail

        # Production's gates, in production's order, so a comparison never pits a
        # shadow value against an authoritative withheld window for a reason that
        # is an artefact of the harness. The over-count gate comes first: a window
        # whose own beats bank more beat-time than the wall clock allows cannot be
        # trusted, and it is skipped on windows too short for their own coverage
        # figure to mean anything (``over_count_min_span_s``).
        ts = [b.ts for b in in_window]
        rr = [b.rr_ms for b in in_window]
        rr_cov = rr_coverage(ts, rr)
        collapsed_cov = collapsed_coverage(ts, rr)
        verdict = classify_coverage(rr_cov, collapsed_cov, tuning)
        detail["rr_coverage"] = round(rr_cov, 6)
        detail["collapsed_coverage"] = round(collapsed_cov, 6)
        detail["coverage_verdict"] = verdict
        if (window_ms >= tuning.over_count_min_span_s * 1000.0
                and not successive_diff_is_trustworthy(verdict)):
            return None, f"over_count_{verdict}", detail

        clock = reconstruct_end_times(in_window, tuning)
        detail["clock"] = clock.to_wire()
        if not clock.resolved:
            return None, clock.detail or "unresolved_adjacency", detail

        # Same cleaning as the production path, so the two differ only in
        # arithmetic. Retained beats carry their reconstructed END times.
        sum_sq = 0.0
        pairs = 0
        clean_rr: list[float] = []
        clean_end: list[float] = []
        offset = 0
        for run in continuous_runs(in_window, tuning.splice_tolerance_s):
            values = [b.rr_ms for b in run]
            nn, contiguous, kept_orig, _n_range, _n_ectopic = clean_rr_gap_aware_indexed(values, tuning)
            kept_end = [clock.end_times[offset + i] for i in kept_orig]
            for i in range(1, len(nn)):
                if contiguous[i]:
                    delta = nn[i] - nn[i - 1]
                    sum_sq += delta * delta
                    pairs += 1
            clean_rr.extend(nn)
            clean_end.extend(kept_end)
            offset += len(run)

        detail["n_clean"] = len(clean_rr)
        detail["production_valid_pairs"] = pairs
        detail["production_rmssd_ms"] = (None if pooled_rmssd(sum_sq, pairs) is None
                                         else round(pooled_rmssd(sum_sq, pairs), 6))
        if len(clean_rr) < tuning.min_clean_beats:
            return None, "insufficient_clean_beats", detail
        if pairs < tuning.min_pairs:
            return None, "insufficient_valid_pairs", detail

        # Same coverage floor and rejected-fraction ceiling as production
        # (``analyze_window``): a window production withholds as ``low_coverage``
        # or ``high_rejected_fraction`` must not come back from the shadow as a
        # number. The gate values are the caller's tuning, so the shadow is
        # configured like production when it is compared with production.
        coverage = (min(1.0, sum(clean_rr) / float(window_ms)) if window_ms > 0 else 0.0)
        rejected_fraction = 1.0 - float(len(clean_rr)) / float(len(in_window))
        detail["coverage"] = round(coverage, 6)
        detail["rejected_fraction"] = round(rejected_fraction, 6)
        if coverage < tuning.min_coverage:
            return None, "low_coverage", detail
        if (tuning.max_rejected_fraction is not None
                and rejected_fraction > tuning.max_rejected_fraction):
            return None, "high_rejected_fraction", detail

        nk_out = neurokit2_hrv_time(clean_rr, clean_end)
        detail["neurokit2"] = {
            "mean_nn_ms": nk_out["mean_nn"],
            "sdnn_ms": nk_out["sdnn"],
            "pnn50": nk_out["pnn50"],
            "pair_count": "unavailable",
        }
        rmssd = nk_out["rmssd"]
        if rmssd is None:
            return None, "neurokit2_non_finite", detail
        return rmssd, None, detail

    def infer(self, request: InferRequest) -> ProviderResult:
        tuning = self.tuning
        payload: HrvInput = request.input
        context = request.context
        deduped = dedup_by_observation_identity(payload.beats)
        beats = deduped.beats
        windows = plan_windows(context.start_ts, context.end_ts, payload.windows, tuning)
        versions = self.versions(request)

        results: list[tuple[Window, float | None, str | None, dict[str, Any]]] = []
        for window in windows:
            value, detail, info = self._window_value(window, beats)
            results.append((window, value, detail, info))

        diagnostics: dict[str, Any] = {
            "algorithm_id": self.provider_id,
            "accuracy_label": "unverified_accuracy",
            "publishable": False,
            "aggregation": payload.aggregation,
            "n_input": deduped.n_input,
            "n_duplicates_dropped": deduped.n_duplicates_dropped,
            "n_after_dedup": deduped.n_kept,
            "timestamp_convention": "reconstructed_interval_end_seconds",
            "timestamp_resolution": TIMESTAMP_RESOLUTION,
            "neurokit2_version": NEUROKIT2_VERSION,
            "neurokit2_hrv_time_sha256_prefix": "32a15fa59622bba8cf170744",
            "bucket_tolerance_s": tuning.bucket_tolerance_s,
            "thresholds_used": tuning.to_wire(),
            "windows": [
                {
                    "start_utc": _iso(window.start),
                    "end_utc": _iso(window.end),
                    "session_id": window.session_id,
                    "rmssd_ms": None if value is None else round(value, 6),
                    "withheld_detail": detail,
                    **info,
                }
                for window, value, detail, info in results[: tuning.max_window_diagnostics]
            ],
            "windows_truncated": len(results) > tuning.max_window_diagnostics,
            "withheld_detail": None,
        }
        usable = [(w, v) for (w, v, d, _i) in results if v is not None]
        coverage = {
            "usable_windows": len(usable),
            "total_windows": len(results),
            "clean_beats": sum(i.get("n_clean", 0) for (_w, _v, _d, i) in results),
            "valid_pairs": sum(i.get("production_valid_pairs", 0) for (_w, _v, _d, i) in results),
            "verdict": "shadow_comparison_only",
        }

        def withheld(detail: str | None) -> ProviderResult:
            unresolved = bool(detail) and (
                "seq_ord" in detail or "bucket" in detail or "ambiguous" in detail
                or "store_span" in detail or detail == "no_beats")
            # The two production gates that are not coverage floors report
            # ``artifact_fraction``; carrying the same reason keeps a shadow
            # comparison like-for-like instead of reporting a harness mismatch.
            artifact = bool(detail) and (
                detail.startswith("over_count_") or detail == "high_rejected_fraction")
            reason = (WithheldReason.UNRESOLVED_ADJACENCY.value if unresolved
                      else WithheldReason.ARTIFACT_FRACTION.value if artifact
                      else WithheldReason.INSUFFICIENT_COVERAGE.value)
            diagnostics["withheld_detail"] = detail
            return ProviderResult(
                status="withheld", value=None, unit="ms", withheld_reason=reason,
                coverage=coverage, diagnostics=diagnostics, versions=versions,
                final_or_provisional="provisional", publishable=False)

        if payload.aggregation == "window":
            _window, value, detail, _info = results[0]
            if value is None:
                return withheld(detail)
            return ProviderResult(
                status="ok", value=value, unit="ms", coverage=coverage, diagnostics=diagnostics,
                versions=versions, final_or_provisional="provisional", publishable=False,
                raw_scores={"neurokit2_hrv_time": results[0][3].get("neurokit2")})

        # session / day: an unweighted mean of window values for a session (the
        # analogue of the production plain mean), duration-weighted across
        # sessions for a day. The shadow provider reports no pair counts, so
        # pooling squared differences is not possible here and is not claimed.
        grouped = group_sessions([WindowOutcome(window=w) for (w, _v, _d, _i) in results])
        by_window: dict[int, tuple[float | None, str | None]] = {
            id(w): (v, d) for (w, v, d, _i) in results
        }
        session_values: list[tuple[float, float]] = []
        session_wire: list[dict[str, Any]] = []
        for session in grouped:
            values = [by_window[id(w.window)][0] for w in session.window_outcomes]
            usable_values = [v for v in values if v is not None]
            session_value = (sum(usable_values) / float(len(usable_values))) if usable_values else None
            duration = float(max(0, session.end - session.start))
            if session_value is not None:
                session_values.append((session_value, duration))
            session_wire.append({
                "session_id": session.session_id,
                "start_utc": _iso(session.start),
                "end_utc": _iso(session.end),
                "duration_s": max(0, session.end - session.start),
                "usable_windows": len(usable_values),
                "total_windows": len(values),
                "rmssd_ms": None if session_value is None else round(session_value, 6),
            })
        diagnostics["sessions"] = session_wire

        if is_session_aggregation(payload.aggregation):
            if len(grouped) != 1:
                return withheld("multiple_sessions_with_session_aggregation")
            if session_values:
                return ProviderResult(
                    status="ok", value=session_values[0][0], unit="ms", coverage=coverage,
                    diagnostics=diagnostics, versions=versions, final_or_provisional="provisional",
                    publishable=False)
            detail = next((d for (_w, _v, d, _i) in results if d), "no_usable_window")
            return withheld(detail)

        total = sum(v * d for v, d in session_values)
        weight = sum(d for _v, d in session_values)
        if weight <= 0:
            detail = next((d for (_w, _v, d, _i) in results if d), "no_usable_window")
            return withheld(detail)
        return ProviderResult(
            status="ok", value=total / weight, unit="ms", coverage=coverage,
            diagnostics=diagnostics, versions=versions, final_or_provisional="provisional",
            publishable=False)


