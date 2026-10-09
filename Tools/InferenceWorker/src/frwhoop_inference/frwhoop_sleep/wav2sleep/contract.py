"""Input contract for the wav2sleep PPG-only adapter.

The request ``input`` carries the anchored PPG transport the Swift worker builds for
``sensor.biomarkers.v1`` (docs/sensor-biomarkers/CONTRACTS.md section 4) with the Spec 01 segment
members pinned in docs/model-integration/README.md, "PPG segments" (Spec 01 branch, commits
ff143411e and 0fd8b94d3):

.. code-block:: json

    {"window": {"start_utc": 1780900000, "end_utc": 1780930000},
     "ppg": {"native_rate_hz": 25, "units": "adc_counts",
             "segments": [{"start_unix": 1780900000, "duration_s": 300,
                           "samples": [378307, ...],            # native_rate_hz per second
                           "sample_count_per_second": 25,
                           "run_id": "r1",
                           "config": {"stable": true, "identity": "...", "known": true},
                           "clock": {"packet_timing_verified": true, "samples_per_second": 25,
                                     "source": "...", "grid": "...", "endpoint": "..."}}]}}

Rules (each failure is a machine-readable withheld detail, see constants.WIRE_REASON):

* The native rate is what the request declares: ``ppg.native_rate_hz`` must be in
  ``SUPPORTED_NATIVE_RATES_HZ`` and equal every segment's ``clock.samples_per_second``
  (``clock_rate_mismatch`` otherwise) and ``sample_count_per_second``. 25 Hz is the anchored v26
  convention (anchor + 24 deltas; the next record's anchor is the 26th point), 24 Hz the earlier one.
* ``clock.packet_timing_verified`` must be ``true``; a segment without ``clock`` is the legacy shape.
  Both withhold ``unverified_sample_clock``. ``clock.source/grid/endpoint`` are provenance only:
  carried into the output, never gated on.
* Only PPG is admitted. Any ECG/ABD/THX/respiration member is refused; a respiration or RSA
  waveform derived from the same PPG is refused by name (``derived_respiration_refused``) - it is
  never a measured chest/abdominal effort signal.
* Samples must be absolute ADC counts (``units == "adc_counts"``) inside the signed 20-bit optical
  domain, finite, integer-valued and off the rails; a run that looks like un-anchored deltas is
  refused (``legacy_deltas_suspected``). Polarity is never changed.
* ``config.identity`` must be present (``optical_config_identity_missing``) and identified:
  ``"unknown"`` or ``config.known != true`` withholds ``optical_config_unidentified`` - channel, LED
  and polarity matter to this model. ``config.stable`` must be true.
* Runs: segments sharing a ``run_id`` are joined only while each starts where the previous piece
  ended and keeps one ``config.identity``. A violation is SPLIT there (never joined) and counted
  as ``ppg_run_id_discontinuity``. Different ``run_id``\\s are never joined even when they touch;
  a segment without ``run_id`` is its own run; a request where no segment has one (the legacy
  shape) is refused (``missing_run_id``).
* Other transport-integrity failures (anchor, clock, configuration, saturation, overlap, order,
  structure) withhold the whole night - a request mixing verified and unverified pieces is not
  trusted. Gaps between valid runs are normal: they become masked epochs.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Mapping, Optional

import numpy as np

from ..timebase import parse_ts
from . import constants as C

#: ``config.identity`` value the transport sends when it cannot identify the configuration.
UNIDENTIFIED_CONFIG = "unknown"
#: Clock members carried as provenance (never interpreted), and the cap on their length.
CLOCK_PROVENANCE_MEMBERS = ("source", "grid", "endpoint")
_PROVENANCE_MAX_CHARS = 256


class Withhold(Exception):
    """An input or gate failure: the night is withheld with ``detail`` (constants.WIRE_REASON)."""

    def __init__(self, detail: str, message: str, **extra: Any):
        super().__init__(message)
        if detail not in C.WIRE_REASON:
            raise ValueError(f"unknown withheld detail {detail!r}")
        self.detail = detail
        self.reason = C.WIRE_REASON[detail]
        self.message = message
        self.extra = extra


@dataclass
class Segment:
    index: int
    start: int
    duration: int
    rate_hz: int
    samples: np.ndarray            # float64 copy of the absolute ADC counts (never mutated)
    run_id: Optional[str]
    config_identity: str
    clock_provenance: dict[str, Any] = field(default_factory=dict)
    segment_id: Optional[str] = None

    @property
    def end(self) -> int:
        return self.start + self.duration


@dataclass
class Run:
    """One contiguous, configuration-compatible run (clipped to the window)."""

    index: int
    run_id: Optional[str]
    config_identity: str
    start: int                     # whole seconds, first native sample at ``start``
    end: int                       # exclusive; last native sample at ``end - 1/rate``
    samples: np.ndarray            # float64, contiguous native samples of the clipped run
    rate_hz: int = C.ANCHORED_V26_NATIVE_RATE_HZ
    segment_indices: list[int] = field(default_factory=list)
    #: 0 for the first piece of a run_id; >0 when a ppg_run_id_discontinuity split it.
    run_id_piece: int = 0
    clock_provenance: dict[str, Any] = field(default_factory=dict)

    @property
    def seconds(self) -> int:
        return self.end - self.start


@dataclass
class ParsedNight:
    window_start: int
    window_end: int
    native_rate_hz: int
    runs: list[Run]
    segments_total: int
    segments_outside_window: int
    native_samples_total: int
    config: dict[str, Any]
    config_overrides: dict[str, Any]
    input_revision: Optional[str]
    producer_withheld_seconds: dict[str, int]
    #: Spec 01 counter: run_id violations that were split, never joined.
    run_id_discontinuities: int = 0
    run_id_discontinuity_details: list[dict[str, Any]] = field(default_factory=list)


# --------------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------------


def _is_int(value: Any) -> bool:
    return isinstance(value, (int, np.integer)) and not isinstance(value, bool)


def _int_valued(value: Any) -> Optional[int]:
    """``value`` as an int when it is an integer-valued number (24 or 24.0), else None."""
    if _is_int(value):
        return int(value)
    if isinstance(value, float) and math.isfinite(value) and value == int(value):
        return int(value)
    return None


def resolve_config(overrides: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    """Defaults plus validated overrides (unknown keys and out-of-bounds values are refused)."""
    config = dict(C.DEFAULT_CONFIG)
    if overrides is None:
        return config, {}
    if not isinstance(overrides, Mapping):
        raise Withhold("unknown_config", "input.config must be an object")
    unknown = sorted(set(overrides) - set(C.DEFAULT_CONFIG))
    if unknown:
        raise Withhold("unknown_config", "unknown config key(s): %s" % ", ".join(unknown))
    applied: dict[str, Any] = {}
    for key, value in overrides.items():
        lo, hi = C.CONFIG_BOUNDS[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) \
                or not math.isfinite(float(value)) or not (lo <= float(value) <= hi):
            raise Withhold("unknown_config", f"input.config.{key}={value!r} is outside [{lo}, {hi}]")
        if isinstance(C.DEFAULT_CONFIG[key], int) and not _is_int(value):
            raise Withhold("unknown_config", f"input.config.{key} must be an integer")
        config[key] = value
        applied[key] = value
    return config, applied


_DERIVED_MARKERS = ("ppg", "rsa", "derived", "pleth", "pulse", "photoplethysmo")


def _looks_ppg_derived(name: str, value: Any) -> tuple[bool, Optional[str]]:
    """True when a non-PPG channel is declared (or named) as computed from the PPG."""
    lowered = name.lower()
    if "rsa" in lowered or "derived" in lowered:
        return True, name
    if isinstance(value, Mapping):
        if value.get("derived_from") is not None:
            return True, str(value.get("derived_from"))
        for key in ("source", "method", "origin", "kind"):
            text = value.get(key)
            if isinstance(text, str) and any(marker in text.lower() for marker in _DERIVED_MARKERS):
                return True, text
    return False, None


def _refuse_other_modalities(payload: Mapping[str, Any]) -> None:
    """PPG-only: refuse ECG/ABD/THX/respiration, naming a PPG-derived respiration explicitly."""
    candidates: list[tuple[str, Any]] = []
    for key in payload:
        if str(key).lower() in C.FORBIDDEN_INPUT_KEYS:
            candidates.append((str(key), payload[key]))
    for key in ("signals", "channels", "modalities"):
        declared = payload.get(key)
        if declared is None:
            continue
        names = list(declared.keys()) if isinstance(declared, Mapping) else declared
        if not isinstance(names, (list, tuple)):
            raise Withhold("invalid_input", f"input.{key} must be a list or an object")
        for name in names:
            label = str(name).strip()
            if label.upper() != C.MODEL_SIGNAL:
                value = declared[name] if isinstance(declared, Mapping) else None
                candidates.append((label, value))
    if not candidates:
        return
    for name, value in candidates:
        derived, evidence = _looks_ppg_derived(name, value)
        if derived:
            raise Withhold(
                "derived_respiration_refused",
                f"input.{name}: a respiration/RSA waveform derived from the PPG is not a measured "
                "chest or abdominal effort signal and is never supplied to the model as ABD/THX",
                channel=name, derived_from=evidence)
    raise Withhold("channel_not_admitted",
                   "this adapter is PPG-only; ECG, ABD and THX are absent from the model input "
                   f"(refused: {', '.join(sorted({n for n, _ in candidates}))})",
                   channels=sorted({n for n, _ in candidates}))


def _segment_samples(raw: Any, where: str, expected: int, rate: int) -> np.ndarray:
    if not isinstance(raw, (list, tuple, np.ndarray)):
        raise Withhold("invalid_segment", f"{where}.samples must be an array")
    try:
        arr = np.asarray(raw, dtype=np.float64)
    except (TypeError, ValueError):
        raise Withhold("nonfinite_samples", f"{where}.samples must be numbers")
    if arr.ndim != 1:
        raise Withhold("invalid_segment", f"{where}.samples must be one-dimensional")
    if arr.size != expected:
        raise Withhold("invalid_segment",
                       f"{where}: duration_s x {rate} = {expected} samples expected, got "
                       f"{arr.size} (a short segment is not contiguous at the declared rate)")
    if not np.all(np.isfinite(arr)):
        raise Withhold("nonfinite_samples", f"{where}.samples contains non-finite values")
    if not np.all(arr == np.round(arr)):
        raise Withhold("non_integer_samples",
                       f"{where}.samples must be integer ADC counts (fractional values found)")
    if np.any(arr >= C.ADC_SAMPLE_MAX) or np.any(arr <= C.ADC_SAMPLE_MIN):
        raise Withhold("saturated_samples",
                       f"{where}.samples reach or leave the signed 20-bit optical rails "
                       f"[{C.ADC_SAMPLE_MIN}, {C.ADC_SAMPLE_MAX}]; saturated seconds must be "
                       "withheld by the transport, never sent as amplitudes")
    return arr


def _clock_provenance(clock: Mapping[str, Any]) -> dict[str, Any]:
    """The uninterpreted clock members, carried through (bounded; never gated on)."""
    out: dict[str, Any] = {}
    for key in CLOCK_PROVENANCE_MEMBERS:
        value = clock.get(key)
        if value is None:
            continue
        text = value if isinstance(value, str) else repr(value)
        out[key] = text[:_PROVENANCE_MAX_CHARS]
    return out


def _parse_segment(index: int, raw: Any, rate: int) -> Segment:
    where = f"input.ppg.segments[{index}]"
    if not isinstance(raw, Mapping):
        raise Withhold("invalid_segment", f"{where} must be an object")
    start, duration = raw.get("start_unix"), raw.get("duration_s")
    if not _is_int(start) or start <= 0:
        raise Withhold("invalid_segment", f"{where}.start_unix must be whole unix seconds")
    if not _is_int(duration) or duration <= 0:
        raise Withhold("invalid_segment", f"{where}.duration_s must be a positive whole number")
    per_second = raw.get("sample_count_per_second")
    if per_second is not None and _int_valued(per_second) != rate:
        raise Withhold("unsupported_native_rate",
                       f"{where}.sample_count_per_second={per_second!r} differs from the declared "
                       f"ppg.native_rate_hz={rate}")
    if raw.get("saturated") is True:
        raise Withhold("saturated_samples", f"{where} is flagged saturated by the transport")

    clock = raw.get("clock")
    if not isinstance(clock, Mapping):
        raise Withhold("unverified_sample_clock",
                       f"{where} has no clock object (the legacy segment shape): the per-second "
                       "grid was never checked against recorded packet timing")
    if _int_valued(clock.get("samples_per_second")) != rate:
        raise Withhold("clock_rate_mismatch",
                       f"{where}.clock.samples_per_second={clock.get('samples_per_second')!r} must "
                       f"equal ppg.native_rate_hz={rate}")
    if clock.get("packet_timing_verified") is not True:
        raise Withhold("unverified_sample_clock",
                       f"{where}.clock.packet_timing_verified is not true: the per-second grid was "
                       "not checked against recorded packet timing")

    config = raw.get("config")
    if not isinstance(config, Mapping):
        raise Withhold("optical_config_identity_missing", f"{where}.config is missing")
    identity = config.get("identity")
    if not isinstance(identity, str) or not identity.strip():
        raise Withhold("optical_config_identity_missing",
                       f"{where}.config.identity is missing; without it configuration "
                       "compatibility cannot be established")
    if identity.strip().lower() == UNIDENTIFIED_CONFIG or config.get("known") is not True:
        raise Withhold("optical_config_unidentified",
                       f"{where}: config.identity={identity!r}, config.known={config.get('known')!r} - "
                       "the transport did not identify gain, drive, channel and LED, and this model "
                       "is sensitive to channel and polarity",
                       identity=identity, known=config.get("known"))
    if config.get("stable") is not True:
        raise Withhold("optical_config_changed",
                       f"{where}.config.stable is not true: the optical configuration changed "
                       "inside the segment")
    if config.get("saturated") is True:
        raise Withhold("saturated_samples", f"{where}.config flags saturation")

    run_id = raw.get("run_id")
    if run_id is not None and (not isinstance(run_id, str) or not run_id):
        raise Withhold("invalid_segment", f"{where}.run_id must be a non-empty string")
    segment_id = raw.get("segment_id")
    samples = _segment_samples(raw.get("samples"), where, int(duration) * rate, rate)
    return Segment(index=index, start=int(start), duration=int(duration), rate_hz=rate,
                   samples=samples, run_id=run_id, config_identity=identity.strip(),
                   clock_provenance=_clock_provenance(clock),
                   segment_id=segment_id if isinstance(segment_id, str) else None)


def _assemble_runs(segments: list[Segment]) -> tuple[list[tuple[list[Segment], int]], list[dict]]:
    """Join segments only within one run_id and only while contiguous with one identity.

    Returns ``([(pieces, run_id_piece), ...], discontinuities)``. A gap or identity change inside
    one ``run_id`` starts a new piece (split, never joined) and is recorded as a
    ``ppg_run_id_discontinuity``. Order and overlap are structural and refuse the request.
    """
    for previous, segment in zip(segments, segments[1:]):
        if segment.start < previous.start:
            raise Withhold("unsorted_segments", "input.ppg.segments must be time-ordered")
    for previous, segment in zip(segments, segments[1:]):
        if segment.start < previous.end:
            raise Withhold("overlapping_segments",
                           f"segments[{previous.index}] and segments[{segment.index}] overlap; "
                           "a native sample belongs to exactly one segment")
    runs: list[tuple[list[Segment], int]] = []
    open_by_id: dict[str, tuple[list[Segment], int]] = {}
    discontinuities: list[dict[str, Any]] = []
    for segment in segments:
        if segment.run_id is None:
            runs.append(([segment], 0))
            continue
        current = open_by_id.get(segment.run_id)
        if current is not None:
            last = current[0][-1]
            reasons = []
            if segment.start != last.end:
                reasons.append("gap" if segment.start > last.end else "not_contiguous")
            if segment.config_identity != last.config_identity:
                reasons.append("config_identity_changed")
            if not reasons:
                current[0].append(segment)
                continue
            discontinuities.append({"run_id": segment.run_id, "segment": segment.index,
                                    "previous_end": last.end, "start": segment.start,
                                    "reasons": reasons})
            piece = (current[1] + 1)
        else:
            piece = 0
        entry = ([segment], piece)
        open_by_id[segment.run_id] = entry
        runs.append(entry)
    return runs, discontinuities


def _clip_run(index: int, pieces: list[Segment], piece_index: int, lo: int, hi: int) -> Optional[Run]:
    start, end = pieces[0].start, pieces[-1].end
    clipped_start, clipped_end = max(start, lo), min(end, hi)
    if clipped_end <= clipped_start:
        return None
    rate = pieces[0].rate_hz
    samples = np.concatenate([piece.samples for piece in pieces])
    first = (clipped_start - start) * rate
    last = (clipped_end - start) * rate
    provenance: dict[str, Any] = {}
    for key in CLOCK_PROVENANCE_MEMBERS:
        values = sorted({p.clock_provenance[key] for p in pieces if key in p.clock_provenance})
        if values:
            provenance[key] = values[0] if len(values) == 1 else values[:4]
    return Run(index=index, run_id=pieces[0].run_id, config_identity=pieces[0].config_identity,
               start=clipped_start, end=clipped_end, samples=samples[first:last].copy(),
               rate_hz=rate, segment_indices=[piece.index for piece in pieces],
               run_id_piece=piece_index, clock_provenance=provenance)


def _legacy_delta_check(run: Run) -> None:
    samples = run.samples
    if samples.size == 0:
        return
    if (float(np.max(np.abs(samples))) < C.LEGACY_DELTA_ABS_LIMIT
            and abs(float(np.median(samples))) < C.LEGACY_DELTA_MEDIAN_LIMIT):
        raise Withhold("legacy_deltas_suspected",
                       f"run {run.index}: every sample fits the i16 delta range and the run is "
                       "centred on zero - these look like un-anchored per-second deltas, not "
                       "absolute (anchor + cumulative delta) ADC counts",
                       run_index=run.index)


def _declared_rate(ppg: Mapping[str, Any]) -> int:
    raw = ppg.get("native_rate_hz")
    rate = _int_valued(raw)
    if rate is None or rate not in C.SUPPORTED_NATIVE_RATES_HZ:
        raise Withhold("unsupported_native_rate",
                       f"input.ppg.native_rate_hz={raw!r}; the request must declare one of "
                       f"{list(C.SUPPORTED_NATIVE_RATES_HZ)} (a detected variant is never "
                       "re-interpreted)")
    return rate


# --------------------------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------------------------


def parse_night(payload: Any, context: Mapping[str, Any]) -> ParsedNight:
    """Validate the request and return the clipped runs. Raises :class:`Withhold`."""
    if not isinstance(payload, Mapping):
        raise Withhold("invalid_input", "input must be an object")
    config, overrides = resolve_config(payload.get("config"))
    _refuse_other_modalities(payload)

    window = payload.get("window") or {}
    if not isinstance(window, Mapping):
        raise Withhold("invalid_window", "input.window must be an object")
    try:
        start = parse_ts(window.get("start_utc", context.get("interval_start_utc")), "window.start_utc")
        end = parse_ts(window.get("end_utc", context.get("interval_end_utc")), "window.end_utc")
    except ValueError as exc:  # timebase.InputError is a ValueError
        raise Withhold("invalid_window", str(exc))
    if end <= start:
        raise Withhold("invalid_window", "window end must be after window start")
    if end - start > int(config["max_window_seconds"]):
        raise Withhold("night_too_long",
                       f"window is {end - start} s; the official max sequence is "
                       f"{C.MAX_EPOCHS} epochs ({C.TRAINING_LENGTH_HOURS} h) and nothing is "
                       "silently truncated",
                       window_seconds=int(end - start), max_window_seconds=int(config["max_window_seconds"]))

    ppg = payload.get("ppg")
    producer_withheld: dict[str, int] = {}
    if isinstance(ppg, Mapping) and isinstance(ppg.get("withheld_seconds"), Mapping):
        producer_withheld = {str(k): int(v) for k, v in ppg["withheld_seconds"].items()
                             if _is_int(v)}
    segments_raw = ppg.get("segments") if isinstance(ppg, Mapping) else None
    if not isinstance(ppg, Mapping) or not segments_raw:
        if producer_withheld.get("missing_ppg_anchor"):
            raise Withhold("missing_ppg_anchor",
                           "no anchored PPG was delivered: the producer withheld "
                           f"{producer_withheld['missing_ppg_anchor']} seconds for a missing "
                           "absolute anchor (legacy delta-only records)",
                           producer_withheld_seconds=producer_withheld)
        raise Withhold("no_ppg_segments", "input.ppg.segments is missing or empty")
    rate = _declared_rate(ppg)
    if ppg.get("units") != "adc_counts":
        raise Withhold("missing_ppg_anchor",
                       f"input.ppg.units={ppg.get('units')!r}: only absolute ADC counts "
                       "(anchor + cumulative deltas) are admitted; deltas are never staged")
    if not isinstance(segments_raw, list):
        raise Withhold("invalid_segment", "input.ppg.segments must be an array")
    if len(segments_raw) > int(config["max_segments"]):
        raise Withhold("too_many_segments",
                       f"{len(segments_raw)} segments > max_segments={config['max_segments']}")

    segments = [_parse_segment(i, raw, rate) for i, raw in enumerate(segments_raw)]
    if not any(segment.run_id is not None for segment in segments):
        raise Withhold("missing_run_id",
                       "no segment carries run_id (the legacy segment shape): contiguous runs "
                       "cannot be established, and segments are never joined without one")
    pieces_by_run, discontinuities = _assemble_runs(segments)

    runs: list[Run] = []
    outside = 0
    for pieces, piece_index in pieces_by_run:
        run = _clip_run(len(runs), pieces, piece_index, start, end)
        if run is None:
            outside += len(pieces)
            continue
        _legacy_delta_check(run)
        runs.append(run)

    input_revision = payload.get("input_revision")
    return ParsedNight(
        window_start=int(start), window_end=int(end), native_rate_hz=rate, runs=runs,
        segments_total=len(segments), segments_outside_window=outside,
        native_samples_total=int(sum(run.samples.size for run in runs)),
        config=config, config_overrides=overrides,
        input_revision=input_revision if isinstance(input_revision, str) else None,
        producer_withheld_seconds=producer_withheld,
        run_id_discontinuities=len(discontinuities),
        run_id_discontinuity_details=discontinuities[:50],
    )
