#!/usr/bin/env python
"""Build the EXACT ``POST /v1/infer`` body the Swift worker assembles for HRV.

Source of truth: ``Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift``
(``CandidateBeat.json``, ``dedupByObservationIdentity``, ``candidateBeats``,
``hrvConfig``, ``hrvInput``) and ``CandidateStage.runOne`` (the ``context`` block).
The point of reproducing it here is that the end-to-end script must send the
worker's real payload shape to the sidecar, not a test-only one.

Input: a JSON array of ``noop_rr_intervals`` rows (``ts``, ``rrMs``, ``seq``,
``ord``, ``srcChannel``) on stdin or in a file, as the seeded day's rows.

Usage:
    uv run python scripts/build_hrv_request.py \
        --rows <rr-rows.json> --out <request.json> \
        --user-id <uuid> --device-id <uuid> \
        --day 2026-09-30 --tz Europe/London \
        --profile-version profile-1 --config-version cfg-1 --corrections-version corr-0

Notes / seams (recorded, not hidden):
  * the sidecar's ``parse_hrv_input`` reads ``input.beats`` and (optionally)
    ``input.windows`` + ``input.aggregation``. It does NOT read ``input.window``
    or ``input.config``, so the window the worker intends comes from
    ``context.interval_start_utc``/``interval_end_utc`` (which is exactly what the
    worker sets from ``CandidateInputs.intervalStart/End``) and the provider uses
    its own config defaults. The keys are still sent verbatim, because that is
    what the worker sends.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

# DayScorer.observationBucketSeconds
OBSERVATION_BUCKET_SECONDS = 1


def iso(ts: int) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def dedup_by_observation_identity(rows: list[dict]) -> list[dict]:
    seen: set[str] = set()
    out: list[dict] = []
    for row in rows:
        bucket = int(row["ts"]) // OBSERVATION_BUCKET_SECONDS
        key = "|".join([
            str(bucket),
            str(int(row["rrMs"])),
            str(int(row["seq"])),
            "-" if row.get("ord") is None else str(int(row["ord"])),
            "-" if row.get("srcChannel") is None else str(int(row["srcChannel"])),
        ])
        if key not in seen:
            seen.add(key)
            out.append(row)
    return out


def candidate_beats(rows: list[dict]) -> list[dict]:
    ordered = sorted(rows, key=lambda r: (int(r["ts"]), int(r["seq"]),
                                          int(r["ord"]) if r.get("ord") is not None else -(2**31)))
    beats: list[dict] = []
    previous_end: float | None = None
    previous_key: str | None = None
    for row in ordered:
        ts = int(row["ts"])
        rr = int(row["rrMs"])
        channel = None if row.get("srcChannel") is None else int(row["srcChannel"])
        key = f"{ts // OBSERVATION_BUCKET_SECONDS}|{-1 if channel is None else channel}"
        if key == previous_key and previous_end is not None:
            end = previous_end + rr / 1000.0
        else:
            end = ts + rr / 1000.0
        previous_end, previous_key = end, key
        beat = {
            "ts": ts,
            "rr_ms": rr,
            "seq": int(row["seq"]),
            "ts_end_seconds": ts + rr / 1000.0,
            "ts_end_reconstructed_seconds": end,
        }
        if row.get("ord") is not None:
            beat["ord"] = int(row["ord"])
        if channel is not None:
            beat["src_channel"] = channel
        beats.append(beat)
    return beats


def hrv_config() -> dict:
    """DayScorer.hrvConfig(), with the HRVAnalyzer constants it reads resolved.

    The five values marked (constant) come from
    Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift:
    minBeats=20, rrMinMs=300, rrMaxMs=2000, ectopicThreshold=0.20,
    ectopicWindowRadius=2, coveragePlausibleCeiling=1.10,
    coveragePlausibleFloor=1.0-(1.10-1.0), beatAccuracyToleranceS=0.5,
    beatAccuracyMinFraction=0.5.
    """
    return {
        "window_sec": 300,
        "min_clean_beats": 20,            # constant HRVAnalyzer.minBeats
        "min_pairs": 1,
        "min_coverage": 0.0,
        "splice_tolerance_s": 3.0,
        "rr_min_ms": 300,                 # constant HRVAnalyzer.rrMinMs
        "rr_max_ms": 2000,                # constant HRVAnalyzer.rrMaxMs
        "malik_threshold": 0.20,          # constant HRVAnalyzer.ectopicThreshold
        "malik_radius": 2,                # constant HRVAnalyzer.ectopicWindowRadius
        "coverage_floor": 1.0 - (1.10 - 1.0),
        "coverage_ceiling": 1.10,
        "beat_accuracy_tolerance_s": 0.5,
        "beat_accuracy_min_fraction": 0.5,
        "max_rejected_fraction": None,
        "aggregation": "mean_over_windows",
        "pooling": "sum_sq_and_pairs",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", help="JSON file: array of noop_rr_intervals rows")
    parser.add_argument("--synthetic-count", type=int, default=0,
                        help="generate this many synthetic beats instead of --rows "
                             "(deterministic; no capture is ever used)")
    parser.add_argument("--synthetic-start", type=int, default=1_790_808_000,
                        help="first beat's whole-unix-second timestamp for --synthetic-count")
    parser.add_argument("--out", required=True)
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--tz", default="Europe/London")
    parser.add_argument("--profile-version", default="profile-1")
    parser.add_argument("--config-version", default="cfg-1")
    parser.add_argument("--corrections-version", default="corr-0")
    parser.add_argument("--provider-id", default="production.runs.v1")
    parser.add_argument("--pad-seconds", type=int, default=60,
                        help="slack added either side of the beat span for the context interval")
    args = parser.parse_args()

    if args.synthetic_count:
        rows = [
            {"ts": args.synthetic_start + index,
             "rrMs": 800 + (index % 7) * 3,
             "seq": index,
             "ord": index,
             "srcChannel": 1}
            for index in range(args.synthetic_count)
        ]
    elif args.rows:
        with open(args.rows, "r", encoding="utf-8") as handle:
            rows = json.load(handle)
    else:
        sys.stderr.write("either --rows or --synthetic-count is required\n")
        return 2
    if not rows:
        sys.stderr.write("no RR rows: the seeded day is empty\n")
        return 1

    deduped = dedup_by_observation_identity(rows)
    beats = candidate_beats(deduped)
    interval_start = min(b["ts"] for b in beats) - args.pad_seconds
    interval_end = max(b["ts"] for b in beats) + args.pad_seconds

    body = {
        "metric": "hrv",
        "context": {
            "user_id": args.user_id,
            "device_id": args.device_id,
            "interval_start_utc": iso(interval_start),
            "interval_end_utc": iso(interval_end),
            "iana_timezone": args.tz,
            "profile_version": args.profile_version,
            "config_version": args.config_version,
            "corrections_version": args.corrections_version,
        },
        "input": {
            "beats": beats,
            "window": {"start_sec": interval_start, "end_sec": interval_end, "inclusive": True},
            "config": hrv_config(),
            "timestamp_convention": "interval_end_seconds",
            "timestamp_resolution": "whole_seconds",
            "observation_identity": {
                "dedup_key": ["ts_bucket_1s", "rr_ms", "seq", "ord", "src_channel"],
                "input_rows": len(rows),
                "deduped_rows": len(beats),
                "bucket_seconds": OBSERVATION_BUCKET_SECONDS,
            },
        },
        "provider": {"provider_id": args.provider_id},
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(body, handle, indent=1, sort_keys=True)
    print(f"request written: {args.out} (beats={len(beats)} input_rows={len(rows)} "
          f"interval={iso(interval_start)}..{iso(interval_end)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
