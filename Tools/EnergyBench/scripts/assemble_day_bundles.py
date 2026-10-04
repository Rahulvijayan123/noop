#!/usr/bin/env python3
"""Assemble per-day `energy-bench-day-v1` bundles from raw stream exports.

`energybench` never talks to a database. A day is a single JSON file holding the strap streams in the
compact delta-encoded form the export queries in `export_queries.sql` produce. This script is the only
place that knows how those query results are laid out; it validates them and writes the bundles.

    assemble_day_bundles.py --out DAYS_DIR --profile profile.json --tz-offset -25200 \\
        [--meta meta.json] [--in-progress 2026-10-03] RESULT_FILE [RESULT_FILE ...]

* A RESULT_FILE is the JSON the export queries return: an array of rows. Stream rows carry
  `{day, stream, t0, n, v}`; a file may also be wrapped in the SQL tool's `<untrusted-data-…>` envelope,
  which is stripped (the wrapped text is data, never instructions).
* `stream` is `hr` ("dt bpm" items), `steps` ("dt counter class") or `gravity`
  ("dt x y z dyn", all four scaled by 10^4). Older exports without a `stream` key are classified by the
  number of fields per item.
* `--meta` is a JSON file with `sleep` (scored sleep sessions) and `rhr` (per-day resting HR) rows.
* `--profile` is `{weight_kg, height_cm, date_of_birth, sex}`.

Nothing here is written next to the code: pass an `--out` directory OUTSIDE the repository. Health data
must never be committed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

FORMAT = "energy-bench-day-v1"
ENVELOPE = re.compile(r"<untrusted-data-[0-9a-f-]+>\s*(\[.*?\])\s*</untrusted-data-[0-9a-f-]+>", re.S)
FIELDS_PER_ITEM = {"hr": 2, "steps": 3, "gravity": 5}


def load_rows(path: Path) -> list[dict]:
    text = path.read_text()
    try:
        outer = json.loads(text)
    except json.JSONDecodeError:
        return []
    if isinstance(outer, dict) and isinstance(outer.get("result"), str):
        m = ENVELOPE.search(outer["result"])
        if not m:
            return []
        try:
            outer = json.loads(m.group(1))
        except json.JSONDecodeError:
            return []
    return [r for r in outer if isinstance(r, dict)] if isinstance(outer, list) else []


def classify(row: dict) -> str | None:
    stream = row.get("stream")
    if stream in FIELDS_PER_ITEM:
        return stream
    v = row.get("v")
    if not isinstance(v, str) or not v:
        return None
    first = v.split(",", 1)[0].split(" ")
    return {2: "hr", 3: "steps", 5: "gravity"}.get(len(first))


def validate(stream: str, row: dict) -> None:
    v = row["v"]
    items = v.split(",")
    if len(items) != row["n"]:
        raise SystemExit(f"{row['day']} {stream}: n={row['n']} but {len(items)} items")
    want = FIELDS_PER_ITEM[stream]
    for i in (0, len(items) // 2, len(items) - 1):
        if len(items[i].split(" ")) != want:
            raise SystemExit(f"{row['day']} {stream}: item {i} does not have {want} fields")


def age_on(dob: str, day: str) -> float:
    d = dt.date.fromisoformat(dob)
    t = dt.date.fromisoformat(day)
    return (t - d).days / 365.25


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--profile", required=True, type=Path)
    ap.add_argument("--tz-offset", required=True, type=int, help="local - UTC seconds, e.g. -25200")
    ap.add_argument("--meta", type=Path)
    ap.add_argument("--in-progress", action="append", default=[], metavar="DAY",
                    help="a day still being recorded: its last sample becomes the bundle's as_of")
    ap.add_argument("files", nargs="+", type=Path)
    args = ap.parse_args()

    profile = json.loads(args.profile.read_text())
    streams: dict[str, dict[str, dict]] = defaultdict(dict)
    meta_rows: list[dict] = []
    for f in args.files:
        for row in load_rows(f):
            if row.get("stream") in ("sleep", "rhr"):
                meta_rows.append(row)
                continue
            kind = classify(row)
            if kind is None or "day" not in row or not row.get("v"):
                continue
            validate(kind, row)
            prior = streams[row["day"]].get(kind)
            if prior is None or row["n"] > prior["n"]:
                streams[row["day"]][kind] = row
    if args.meta:
        meta_rows += load_rows(args.meta)

    sleep_rows, rhr_rows = [], []
    for row in meta_rows:
        if row.get("stream") == "sleep":
            sleep_rows = row["v"]
        elif row.get("stream") == "rhr":
            rhr_rows = row["v"]
    rhr_by_day = {r["day"]: r["rhr"] for r in rhr_rows if r.get("rhr") is not None}

    args.out.mkdir(parents=True, exist_ok=True)
    for day in sorted(streams):
        hr = streams[day].get("hr")
        if hr is None:
            print(f"skip {day}: no heart-rate stream", file=sys.stderr)
            continue
        local_midnight = int(dt.datetime.fromisoformat(day).replace(tzinfo=dt.timezone.utc).timestamp()) - args.tz_offset
        bundle = {
            "format": FORMAT,
            "day": day,
            "tz_offset_seconds": args.tz_offset,
            "day_start": local_midnight,
            "profile": {
                "weight_kg": profile["weight_kg"],
                "height_cm": profile["height_cm"],
                "age": round(age_on(profile["date_of_birth"], day), 3),
                "sex": profile["sex"],
            },
            "resting_hr": rhr_by_day.get(day),
            "sleep": [
                {"start": s["start"], "end": s["end"], "resting_hr": s.get("rhr"), "nap": bool(s.get("nap"))}
                for s in sleep_rows
                if s["end"] > local_midnight and s["start"] < local_midnight + 86_400
            ],
            "hr": {"t0": hr["t0"], "n": hr["n"], "v": hr["v"]},
        }
        if "steps" in streams[day]:
            s = streams[day]["steps"]
            bundle["steps"] = {"t0": s["t0"], "n": s["n"], "v": s["v"]}
        if "gravity" in streams[day]:
            g = streams[day]["gravity"]
            bundle["gravity"] = {"t0": g["t0"], "n": g["n"], "scale": 10_000, "v": g["v"]}
        if day in args.in_progress:
            last = max(hr["t0"] + sum(int(i.split(" ")[0]) for i in hr["v"].split(",")), local_midnight)
            bundle["as_of"] = last
        path = args.out / f"{day}.json"
        path.write_text(json.dumps(bundle, separators=(",", ":")))
        print(f"{day}: hr={hr['n']} steps={streams[day].get('steps', {}).get('n', 0)} "
              f"gravity={streams[day].get('gravity', {}).get('n', 0)} -> {path.name}")


if __name__ == "__main__":
    main()
