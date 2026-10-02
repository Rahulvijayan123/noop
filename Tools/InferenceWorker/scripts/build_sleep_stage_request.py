#!/usr/bin/env python
"""Build a real ``sleep_stage`` request for the sidecar from the project's own fixture.

Reuses ``tests/sleep_fixtures.py`` (the same deterministic synthetic night the
wiring tests use) rather than inventing a second fixture, and sends the exact
``input`` shape ``tests/test_sleep_providers_wiring.py`` proves is accepted:
``{"rr": [[ts, rr_ms, seq, ord, suspect], ...], "window": {...}, "age", "gender"}``.

Usage (from Tools/InferenceWorker):

    uv run python scripts/build_sleep_stage_request.py --out sleep_stage.json \
        --user-id <uuid> --device-id <uuid> [--fixture normal_night]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PACKAGE_ROOT, "tests"))

PROVIDER_ID = "sleepecg.wrn-gru-mesa.v1"


def iso(ts: int) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--fixture", default="normal_night")
    parser.add_argument("--profile-version", default="profile-1")
    parser.add_argument("--config-version", default="cfg-1")
    parser.add_argument("--corrections-version", default="corr-0")
    args = parser.parse_args()

    import sleep_fixtures as F

    fixture = getattr(F, args.fixture)()
    series = F.rr_series_from_fixture(fixture)
    window = series["window"]

    body = {
        "metric": "sleep_stage",
        "context": {
            "user_id": args.user_id,
            "device_id": args.device_id,
            "interval_start_utc": iso(window["start_utc"]),
            "interval_end_utc": iso(window["end_utc"]),
            "iana_timezone": series["tz"],
            "profile_version": args.profile_version,
            "config_version": args.config_version,
            "corrections_version": args.corrections_version,
        },
        "input": {
            "rr": [list(row) for row in series["rr"]],
            "window": {"start_utc": window["start_utc"], "end_utc": window["end_utc"]},
            "age": series["age"],
            "gender": series["gender"],
        },
        "provider": {"provider_id": PROVIDER_ID},
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(body, handle)
    print(f"request written: {args.out} (fixture={fixture.name} rr_rows={len(series['rr'])} "
          f"window={iso(window['start_utc'])}..{iso(window['end_utc'])} tz={series['tz']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
