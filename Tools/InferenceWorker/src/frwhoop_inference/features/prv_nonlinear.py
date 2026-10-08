"""Secondary nonlinear PRV statistics: sample entropy and DFA alpha-1 (spec-02 §1, CONTRACT §5.3).

Owner: cardiac. Single producer of ``nights[].prv_nonlinear`` (the Swift ``sleep_analytics_v1``
never computes these; Python never recomputes SD1/SD2/pNN50).

These are OPTIONAL RESEARCH STATISTICS on optical pulse intervals (``source: prv_optical``):
secondary diagnostics, not ECG-equivalent HRV, and never an autonomic-disease, fitness or
exercise-threshold measure.

Method (``method_version`` ``prv-nonlinear-1``):

1. Beats inside the MAIN night ``[night.start, night.end)`` (naps are ``not_applicable``).
2. Adjacency reuses the stage-physiology producer (``features/physiology.py``): the production
   run detector ``providers.hrv.continuous_runs`` (a wall clock running ahead of the previous
   beat's own length by more than ``splice_tolerance_s`` starts a new run), additionally split at
   a source-channel change, then the production cleaner ``clean_rr_gap_aware`` per run (range
   filter + Malik ectopic rejection, the ``HRVAnalyzer.cleanRRGapAware`` port). An interval is
   TRUE-adjacent to its predecessor only when the cleaner reports them contiguous inside one run.
3. Segments are non-overlapping blocks of EXACTLY ``segment_beats`` consecutive true-adjacent
   cleaned intervals, laid from the start of each adjacency stretch; a stretch's remainder shorter
   than a segment is discarded. Nothing is concatenated across a gap, a removed beat, a run or a
   channel boundary, and only these equal-length segments are pooled.
4. Per segment (pinned NeuroKit2):
   * SampEn = ``nk.entropy_sample(x, delay=1, dimension=m, tolerance=r)`` with m =
     ``sampen_dimension`` and r = ``sampen_tolerance_sd`` x SD(x, ddof=1) of that segment
     (Richman & Moorman 2000; NeuroKit's default "sd" tolerance, passed explicitly).
   * DFA alpha-1 = ``nk.fractal_dfa(x, scale=[4..16], overlap=False, integrate=True, order=1)``:
     the Peng et al. 1995 short-term exponent over every integer box size from
     ``dfa_scales[0]`` to ``dfa_scales[1]`` inclusive, non-overlapping boxes (the textbook
     definition; NeuroKit's ``hrv_nonlinear`` default instead uses 4-11 beats with overlapping
     boxes, so its DFA_alpha1 is NOT this number).
   A segment whose SampEn or alpha-1 is undefined (no template matches, zero variance) is
   rejected for both statistics, so both summaries describe the same segments.
5. Night summary: median and IQR (numpy linear-interpolation percentiles) over the used segments.
   Fewer than ``min_segments`` used segments -> withheld (values null) with a reason.
6. Latency cap: at most ``max_segments`` segments are evaluated, chosen evenly across the night
   in time order (deterministic); the counts of available and evaluated segments are reported. A
   wall-clock guard (``time_budget_s``) withholds the whole block (``compute_budget_exceeded``)
   instead of risking the route's 3 s budget for every other block: it can only remove the block,
   never change a published value. Stretches shorter than one segment are not cleaned (they
   cannot contribute), which changes no result.
"""

from __future__ import annotations

import math
import time
from dataclasses import asdict, dataclass
from typing import Any, Sequence

import neurokit2 as nk
import numpy as np

from ..providers.hrv import HrvTuning, clean_rr_gap_aware, continuous_runs
from .config import SleepFeaturesConfig
from .contract import SleepFeaturesRequest, json_finite
from .timeline import Timeline

METHOD_VERSION = "prv-nonlinear-1"
SOURCE = "prv_optical"

#: Reason codes this block can emit (listed in docs/spec-02/notes/cardiac.md for wording).
REASON_NOT_MAIN_NIGHT = "not_main_night"
REASON_NO_RR_BEATS = "no_rr_beats"
REASON_INSUFFICIENT_SEGMENTS = "insufficient_segments"
REASON_COMPUTE_BUDGET_EXCEEDED = "compute_budget_exceeded"


@dataclass(frozen=True)
class PrvNonlinearConfig:
    """Fixed parameters (behaviour-changing; reported verbatim as the block's ``config``)."""

    #: segment length: exactly this many consecutive true-adjacent cleaned intervals
    segment_beats: int = 300
    sampen_dimension: int = 2
    sampen_delay: int = 1
    #: r = sampen_tolerance_sd x SD(segment, ddof=1)
    sampen_tolerance_sd: float = 0.2
    #: inclusive box-size range (beats) for alpha-1; every integer size is used
    dfa_scales: tuple[int, int] = (4, 16)
    dfa_overlap: bool = False
    dfa_order: int = 1
    #: fewer used segments than this -> withheld
    min_segments: int = 3
    #: latency cap: evaluate at most this many segments, evenly spaced over the night
    max_segments: int = 24
    #: wall-clock guard (s) for the whole block: past it the block is WITHHELD
    #: (``compute_budget_exceeded``) rather than risk the route's 3 s budget for every other
    #: block; it never changes a published number, only whether one is published
    time_budget_s: float = 0.4
    #: run split when the wall clock runs ahead of a beat's own length by more than this
    #: (``HrvTuning.splice_tolerance_s``, the stage-physiology producer's rule)
    splice_tolerance_s: float = HrvTuning().splice_tolerance_s

    def to_wire(self) -> dict[str, Any]:
        out = asdict(self)
        out["dfa_scales"] = list(self.dfa_scales)
        return out


PRV_NONLINEAR_CONFIG = PrvNonlinearConfig()


# ---------------------------------------------------------------------------
# Segmentation
# ---------------------------------------------------------------------------


def adjacency_stretches(beats: Sequence[Any], cfg: PrvNonlinearConfig = PRV_NONLINEAR_CONFIG,
                        tuning: HrvTuning | None = None) -> list[list[float]]:
    """Maximal stretches of true-adjacent cleaned intervals (ms), in time order.

    ``beats`` are time-ordered request beats (``ts``, ``rr_ms``, ``src_channel``). Runs come from
    the production run detector and are split at a source-channel change; each run is cleaned with
    the production gap-aware cleaner, and a new stretch starts wherever the cleaner reports a
    removed beat between two survivors.
    """
    tuning = tuning or HrvTuning()
    stretches: list[list[float]] = []
    for run in continuous_runs(list(beats), cfg.splice_tolerance_s):
        # split the run at a source-channel change (two transports never chain)
        pieces: list[list[Any]] = []
        for b in run:
            if pieces and getattr(pieces[-1][-1], "src_channel", None) == getattr(b, "src_channel", None):
                pieces[-1].append(b)
            else:
                pieces.append([b])
        for piece in pieces:
            if len(piece) < cfg.segment_beats:
                continue  # cannot hold one segment: skipping it changes no segment (latency only)
            nn, contiguous, _n_range, _n_ectopic = clean_rr_gap_aware([b.rr_ms for b in piece], tuning)
            current: list[float] = []
            for value, linked in zip(nn, contiguous):
                if linked and current:
                    current.append(value)
                else:
                    if current:
                        stretches.append(current)
                    current = [value]
            if current:
                stretches.append(current)
    return stretches


def equal_length_segments(stretches: Sequence[Sequence[float]], segment_beats: int) -> list[list[float]]:
    """Non-overlapping blocks of exactly ``segment_beats`` intervals from each stretch's start."""
    out: list[list[float]] = []
    for stretch in stretches:
        for k in range(len(stretch) // segment_beats):
            out.append(list(stretch[k * segment_beats:(k + 1) * segment_beats]))
    return out


def evenly_spaced(n_available: int, cap: int) -> list[int]:
    """Indices of at most ``cap`` items spread evenly over ``n_available`` (deterministic)."""
    if n_available <= cap:
        return list(range(n_available))
    return sorted({int(round(i * (n_available - 1) / (cap - 1))) for i in range(cap)})


# ---------------------------------------------------------------------------
# Per-segment statistics (pinned NeuroKit2)
# ---------------------------------------------------------------------------


def segment_statistics(x: Sequence[float],
                       cfg: PrvNonlinearConfig = PRV_NONLINEAR_CONFIG) -> tuple[float | None, float | None]:
    """(SampEn, DFA alpha-1) of one segment via NeuroKit2; None where undefined."""
    arr = np.asarray(x, dtype=float)
    sd = float(np.std(arr, ddof=1)) if arr.size > 1 else 0.0
    if not math.isfinite(sd) or sd <= 0.0:
        return None, None
    sampen, _ = nk.entropy_sample(arr, delay=cfg.sampen_delay, dimension=cfg.sampen_dimension,
                                  tolerance=cfg.sampen_tolerance_sd * sd)
    lo, hi = cfg.dfa_scales
    alpha, _ = nk.fractal_dfa(arr, scale=np.arange(lo, hi + 1), overlap=cfg.dfa_overlap,
                              integrate=True, order=cfg.dfa_order, multifractal=False, show=False)
    sampen_v = float(sampen) if sampen is not None and math.isfinite(float(sampen)) else None
    alpha_v = float(alpha) if alpha is not None and math.isfinite(float(alpha)) else None
    return sampen_v, alpha_v


def _median_iqr(values: Sequence[float]) -> dict[str, Any]:
    if not values:
        return {"median": None, "iqr": None, "segments": 0}
    arr = np.asarray(values, dtype=float)
    iqr = float(np.percentile(arr, 75) - np.percentile(arr, 25)) if arr.size >= 2 else None
    return {"median": json_finite(float(np.median(arr))), "iqr": json_finite(iqr),
            "segments": int(arr.size)}


# ---------------------------------------------------------------------------
# Block
# ---------------------------------------------------------------------------


NOTES = ("Secondary optical pulse-rate-variability research statistics on equal-length gap-free "
         "segments; not ECG HRV and not a measure of autonomic disease, fitness or exercise "
         "thresholds.")


def _block(status: str, reasons: list[str], cfg: PrvNonlinearConfig, *, available: int = 0,
           evaluated: int = 0, used: int = 0, sampen: Sequence[float] = (),
           alpha: Sequence[float] = ()) -> dict[str, Any]:
    withheld = status != "available"
    return {
        "status": status,
        "reasons": reasons,
        "method_version": METHOD_VERSION,
        "neurokit2": nk.__version__,
        "source": SOURCE,
        "secondary": True,
        "config": cfg.to_wire(),
        "segments_available": available,
        "segments_evaluated": evaluated,
        "segments_used": used,
        "segments_rejected": evaluated - used,
        "sample_entropy": _median_iqr([] if withheld else sampen) | {"segments": len(sampen)},
        "dfa_alpha1": _median_iqr([] if withheld else alpha) | {"segments": len(alpha)},
        "notes": NOTES,
    }


def compute_night(req: SleepFeaturesRequest, tl: Timeline, cfg_root: SleepFeaturesConfig,
                  cfg: PrvNonlinearConfig = PRV_NONLINEAR_CONFIG) -> dict[str, Any]:
    """Per-night ``prv_nonlinear`` block (CONTRACT §5.3)."""
    night = tl.night
    if night.is_nap:
        return _block("not_applicable", [REASON_NOT_MAIN_NIGHT], cfg)
    started = time.perf_counter()
    beats = [b for b in req.beats if night.start <= b.ts < night.end]
    if not beats:
        return _block("withheld", [REASON_NO_RR_BEATS], cfg)

    segments = equal_length_segments(adjacency_stretches(beats, cfg), cfg.segment_beats)
    chosen = evenly_spaced(len(segments), cfg.max_segments)
    sampen: list[float] = []
    alpha: list[float] = []
    for k in chosen:
        if time.perf_counter() - started > cfg.time_budget_s:
            return _block("withheld", [REASON_COMPUTE_BUDGET_EXCEEDED], cfg, available=len(segments))
        s, a = segment_statistics(segments[k], cfg)
        if s is None or a is None:
            continue  # undefined for this segment: rejected for BOTH statistics
        sampen.append(s)
        alpha.append(a)
    used = len(sampen)
    if used < cfg.min_segments:
        return _block("withheld", [REASON_INSUFFICIENT_SEGMENTS], cfg, available=len(segments),
                      evaluated=len(chosen), used=used, sampen=sampen, alpha=alpha)
    return _block("available", [], cfg, available=len(segments), evaluated=len(chosen), used=used,
                  sampen=sampen, alpha=alpha)
