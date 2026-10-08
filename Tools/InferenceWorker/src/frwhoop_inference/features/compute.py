"""Enrichment orchestrator: one request -> one sleep-features document.

Root-owned integration seam (docs/SLEEP_FEATURES_CONTRACT.md section 2).
Module owners' compute functions are called here and nowhere else; the
assembly order is fixed:

1. per-night canonical timelines (features/timeline.py)
2. per-night continuity / architecture / stage_physiology / settling /
   thermal / respiratory_variability blocks
3. whole-document regularity + capabilities blocks
4. per-night coverage + metric_status merge, statuses, dependencies

The whole document is computed under the caller's wall-clock budget (the
server route runs it with a watchdog, spec 7.4: 3000 ms). A module that raises
is isolated: its block publishes as withheld with the reason, and the rest
of the document survives (spec section 9 "Isolation": a failing feature never
erases the rest).
"""

from __future__ import annotations

import time
from typing import Any

import neurokit2
import numpy
import scipy
import yasa

from . import ALGORITHM_VERSION, SCHEMA_VERSION
from .config import CONFIG, CONFIG_VERSION
from .contract import SleepFeaturesRequest, fmt_utc
from . import architecture, continuity, physiology, prv_nonlinear, regularity, respiration, settling, thermal
from .timeline import Timeline, actual_sleep_onset, build_timeline, final_sleep_end

try:  # the shadow report is optional at import time; a broken import must not
    # take the whole enrichment down (the block degrades to not_run).
    from . import sleepecg_shadow
except Exception:  # noqa: BLE001
    sleepecg_shadow = None  # type: ignore[assignment]

#: The sidecar's own SleepECG version stamp (the candidate lane's pinned
#: dependency; recorded for provenance even when the shadow report is not_run).
SLEEPECG_VERSION = "0.5.9"


def _dependency_versions() -> dict[str, str]:
    # All imports are module-level (imported once at server start, never
    # per request: the fixture profile showed a per-request ``import yasa``
    # cost of ~4.5 s, which would blow the 3000 ms budget on its own).
    return {
        "yasa": yasa.__version__,
        "numpy": numpy.__version__,
        "scipy": scipy.__version__,
        "neurokit2": neurokit2.__version__,
        "sleepecg": SLEEPECG_VERSION,
    }


def _isolated(fn, *args) -> tuple[dict[str, Any], str | None]:
    """Run one module; a raise becomes a withheld block, never a lost document."""
    try:
        return fn(*args), None
    except Exception as exc:  # noqa: BLE001 - isolation is the contract
        return ({"status": "withheld", "reasons": ["module_error"],
                 "error": f"{type(exc).__name__}: {exc}"},
                f"{fn.__module__}.{fn.__name__}")


def _night_coverage(req: SleepFeaturesRequest, tl: Timeline) -> dict[str, Any]:
    """The per-night coverage block (contract section 4). Pure counting."""
    start, end = tl.night.start, tl.night.end
    span = float(end - start)

    def valid_minutes(samples, min_seconds: int) -> tuple[int, int]:
        # time support, not rows: distinct observed seconds
        seconds = {}
        for s in samples:
            if start <= s.ts < end:
                seconds.setdefault(s.ts, 0)
                seconds[s.ts] += 1
        minutes: dict[int, int] = {}
        for ts in seconds:
            minutes[ts // 60] = minutes.get(ts // 60, 0) + 1
        valid = sum(1 for m, n in minutes.items() if n >= min_seconds)
        return valid, len(minutes)

    hr_valid_min, hr_observed_min = valid_minutes(req.hr, CONFIG.minute_valid_seconds)
    temp_valid_min, temp_observed_min = valid_minutes(req.temp, CONFIG.minute_valid_seconds)

    def max_gap(samples) -> float | None:
        tss = sorted({s.ts for s in samples if start <= s.ts < end})
        if not tss:
            return None
        gaps = [b - a for a, b in zip(tss, tss[1:])]
        # edge gaps count only when the night edge is inside the sample support
        return float(max(gaps)) if gaps else 0.0

    # RR valid pairs / rejected fraction from the production cleaner
    from ..providers.hrv import clean_rr_gap_aware, HrvTuning
    beats = [b for b in req.beats if start <= b.ts < end]
    rr = [b.rr_ms for b in beats]
    _, _, n_range, n_ectopic = clean_rr_gap_aware(rr, HrvTuning())
    rejected_fraction = ((n_range + n_ectopic) / len(rr)) if rr else None

    breath_min = 0.0
    for run in req.breath_runs:
        s, e = max(run.start, start), min(run.end + 1, end)
        if e > s:
            breath_min += float(e - s) / 60.0

    return {
        "known_fraction": tl.known_fraction,
        "known_epoch_fraction": (
            sum(1 for f in tl.fully_observed) / tl.n_epochs) if tl.n_epochs else 0.0,
        "valid_hr_min": hr_valid_min,
        "observed_hr_min": hr_observed_min,
        "valid_temp_min": temp_valid_min,
        "observed_temp_min": temp_observed_min,
        "hr_gap_max_s": max_gap(req.hr),
        "temp_gap_max_s": max_gap(req.temp),
        "rr_rows": len(beats),
        "rr_rejected_fraction": rejected_fraction,
        "breath_intervals": sum(1 for b in req.breaths if start <= b.ts < end),
        "breath_run_min": breath_min,
        "overlap_seconds": tl.overlap_seconds,
        "observed_onset_edge": tl.n_epochs > 0 and tl.coverage_s[0] > 0,
        "observed_offset_edge": tl.n_epochs > 0 and tl.coverage_s[-1] > 0,
        "max_unresolved_gap_s": (
            float(max((g1 - g0) for g0, g1 in tl.unresolved_gaps)) if tl.unresolved_gaps else 0.0),
        "sources": {
            "hr": sum(1 for s in req.hr if start <= s.ts < end),
            "temp": sum(1 for s in req.temp if start <= s.ts < end),
            "rr": len(beats),
            "resp": sum(1 for b in req.breaths if start <= b.ts < end),
        },
        "night_span_s": span,
    }


def compute(req: SleepFeaturesRequest, budget_ms: int = 3000) -> dict[str, Any]:
    """Assemble the whole sleep-features response document."""
    started = time.monotonic()
    deps = _dependency_versions()

    nights_out: list[dict[str, Any]] = []
    metric_status_reasons: list[str] = []
    timelines: dict[str, Timeline] = {}
    for night in req.nights:
        tl = build_timeline(night)
        timelines[night.night_id] = tl

        blocks: dict[str, Any] = {}
        module_errors: list[str] = []
        for key, fn in (
            ("continuity", continuity.compute_night),
            ("architecture", architecture.compute_night),
            ("stage_physiology", physiology.compute_night),
            ("settling", settling.compute_night),
            ("thermal", thermal.compute_night),
            ("respiratory_variability", respiration.compute_night),
            # spec-02 §1 / CONTRACT §5.3 (cardiac): secondary SampEn + DFA alpha-1 on
            # equal-length true-adjacent segments of the main night (naps: not_applicable).
            ("prv_nonlinear", prv_nonlinear.compute_night),
        ):
            block, err = _isolated(fn, req, tl, CONFIG)
            blocks[key] = block
            if err:
                module_errors.append(key)

        coverage = _night_coverage(req, tl)

        # Full-night continuity summary gate (spec 4.2): >= 95% known coverage,
        # observed onset/offset edges, no unresolved internal gap > 60 s.
        gate_reasons = _gate_reasons(coverage, CONFIG)
        night_gate = "available" if not gate_reasons else "partial"
        if gate_reasons:
            metric_status_reasons.extend(gate_reasons)
            # Downgrade continuity/architecture to partial when the gate fails,
            # preserving every computed number with its reason.
            for k in ("continuity", "architecture"):
                if isinstance(blocks.get(k), dict) and blocks[k].get("status") == "available":
                    blocks[k] = {**blocks[k],
                                 "status": "partial",
                                 "reasons": list(blocks[k].get("reasons", [])) + gate_reasons}

        nights_out.append({
            "night_id": night.night_id,
            "start_utc": fmt_utc(night.start),
            "end_utc": fmt_utc(night.end),
            "is_nap": night.is_nap,
            "user_edited": night.user_edited,
            "stage_source": "sleep-v2",
            # The canonical staging algorithm actually claimed for the day
            # (context-carried; contract section 9). "sleep-v2" would be a
            # made-up version, not the claimed one.
            "stage_algorithm_version": req.context.stage_algorithm_version,
            **blocks,
            "metric_status": {
                "night_gate": {"status": night_gate, "reasons": gate_reasons},
                "module_errors": module_errors,
            },
            "coverage": coverage,
        })

    reg_block, reg_err = _isolated(regularity.compute, req, CONFIG)
    capabilities: dict[str, Any] = {
        # Group B gates (spec section 6 / contract section 7): honest blockers.
        "oxygen_events": {"ready": False, "reason": "unverified_sparse_oxygen"},
        "waveform_staging": {"ready": False, "reason": "continuous_ppg_not_delivered"},
        "cvhr_screening": {"ready": False, "reason": "no_validated_port"},
        "ppg_autonomic_events": {"ready": False, "reason": "no_continuous_ppg"},
        "cpc_cycles": {"ready": False, "reason": "no_independent_respiratory_modulation_signal"},
    }
    if sleepecg_shadow is not None:
        shadow_report, _ = _isolated(sleepecg_shadow.compute, req, CONFIG)
        # Contract section 3 sleepecg_shadow: the {ready, reason, report}
        # wrapper. "ready" describes whether a comparison ran, NOT whether
        # SleepECG is promoted - it is a shadow comparison only (spec A8).
        capabilities["sleepecg_shadow"] = {
            "ready": shadow_report.get("status") == "available",
            "reason": shadow_report.get("reason")
                      or (shadow_report.get("reasons") or [None])[0],
            "report": shadow_report,
        }
    else:
        capabilities["sleepecg_shadow"] = {"ready": False,
                                           "reason": "module_unavailable"}

    status_reasons: list[str] = []
    if reg_err:
        status_reasons.append("regularity_module_error")
    status_reasons.extend(metric_status_reasons)
    any_available = any(n["continuity"].get("status") == "available" for n in nights_out)
    status = "partial" if (status_reasons or not any_available) else "available"
    if not nights_out:
        status = "withheld"
        status_reasons.append("no_nights")

    doc: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "algorithm_version": ALGORITHM_VERSION,
        "status": status,
        "status_reasons": sorted(set(status_reasons)),
        "nights": nights_out,
        "regularity": reg_block,
        "dependencies": {**deps,
                         "config_version": CONFIG_VERSION,
                         "config": CONFIG.to_wire()},
        "capabilities": capabilities,
        "duration_ms": None,  # filled by the route (wall-clock incl. transport)
    }
    return doc


def _gate_reasons(coverage: dict[str, Any], cfg) -> list[str]:
    reasons: list[str] = []
    if coverage["known_fraction"] < cfg.continuity_known_fraction:
        reasons.append("timeline_coverage_below_gate")
    if not coverage["observed_onset_edge"]:
        reasons.append("onset_edge_unobserved")
    if not coverage["observed_offset_edge"]:
        reasons.append("offset_edge_unobserved")
    if coverage["max_unresolved_gap_s"] > cfg.continuity_max_gap_s:
        reasons.append("unresolved_internal_gap")
    return reasons
