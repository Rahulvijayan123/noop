"""Write tests/data/layer1_cases.json: invented night-vital tapes that exercise every Layer 1 path (short and long
histories, gaps, out-of-range nights, outliers, a slow drift, a sustained ramp, a level step, the change hold, the
ten-night HRV week, each vital's own band).

The expected results come from the app, never from the port. After changing the cases (or Layer 1):
    uv run python scripts/make_layer1_cases.py
    cd ../../Packages/StrandAnalytics && LAYER1_MIRROR_RECORD=1 swift test --filter LayerOneServerMirrorTests
records tests/data/layer1_expected.json with LongitudinalBaseline.evaluate and vitalVerdict; then
StrandAnalyticsTests/LayerOneServerMirrorTests and tests/test_layer1.py both check against it.
"""

from __future__ import annotations

import json
import math
import random
from datetime import date, timedelta
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "tests" / "data" / "layer1_cases.json"
END = date(2026, 10, 6)


def tape(n: int, value, *, seed: int, decimals: int, missing: float = 0.0) -> list[list]:
    rng = random.Random(seed)
    nights = []
    for i in range(n):
        day = END - timedelta(days=n - 1 - i)
        v = None if rng.random() < missing else value(i, rng)
        nights.append([day.isoformat(), None if v is None else round(v, decimals) if decimals else int(round(v))])
    return nights


def tonight(nights: list[list], value) -> list[list]:
    nights[-1][1] = value
    return nights


def case(name: str, series: str, nights: list[list], as_of: str | None = None) -> dict:
    return {"name": name, "series": series, "as_of": as_of or nights[-1][0], "nights": nights}


def cases() -> list[dict]:
    rhr = lambda mu, sd: (lambda i, r: r.gauss(mu, sd))  # noqa: E731
    hrv = lambda mu, sd: (lambda i, r: math.exp(r.gauss(math.log(mu), sd)))  # noqa: E731
    out = [
        case("rhr_stable_in_range", "sleep_rhr", tonight(tape(75, rhr(52, 1.8), seed=1, decimals=0), 53)),
        case("rhr_stable_off_high", "sleep_rhr", tonight(tape(75, rhr(52, 1.8), seed=1, decimals=0), 61)),
        case("rhr_short_history", "sleep_rhr", tonight(tape(9, rhr(55, 2.0), seed=2, decimals=0), 58)),
        case("rhr_five_nights", "sleep_rhr", tonight(tape(5, rhr(55, 2.0), seed=3, decimals=0), 56)),
        case("rhr_tonight_missing", "sleep_rhr", tonight(tape(40, rhr(50, 2.0), seed=4, decimals=0), None)),
        # A missing night halves the trust: with a long, full history the week usual still shows ("no reading").
        case("rhr_long_history_tonight_missing", "sleep_rhr",
             tonight(tape(90, rhr(52, 1.8), seed=17, decimals=0), None)),
        case("rhr_drift", "sleep_rhr", tape(80, lambda i, r: 50 + 0.09 * i + r.gauss(0, 1.2), seed=6, decimals=0)),
        # A long, clear ramp (0.2 bpm a night for 90 nights): the trend test finds it (slope_usable). It is reported
        # only; the usual is never moved along it.
        case("rhr_sustained_ramp", "sleep_rhr",
             tape(90, lambda i, r: 46 + 0.2 * i + r.gauss(0, 1.0), seed=23, decimals=0)),
        case("rhr_level_step", "sleep_rhr",
             tape(70, lambda i, r: (50 if i < 52 else 58) + r.gauss(0, 1.5), seed=7, decimals=0)),
        case("rhr_long_history", "sleep_rhr", tape(260, rhr(55, 2.5), seed=8, decimals=0)),
        # An 8 bpm step 33 nights back: the change detector fires (a change episode, regime_shift) and the
        # pre-change 60-day usual is held.
        case("rhr_regime_shift_holds_the_usual", "sleep_rhr",
             tape(100, lambda i, r: (50 if i < 67 else 58) + r.gauss(0, 1.5), seed=22, decimals=0)),
        case("rhr_mid_tape", "sleep_rhr", tape(90, rhr(53, 2.0), seed=9, decimals=0), as_of="2026-09-20"),
        case("hrv_stable_low_night", "sleep_hrv_ln", tonight(tape(70, hrv(60, 0.18), seed=10, decimals=1), 41.0)),
        case("hrv_twelve_nights", "sleep_hrv_ln", tape(12, hrv(70, 0.2), seed=12, decimals=1)),
        case("hrv_long_history", "sleep_hrv_ln", tape(300, hrv(55, 0.22), seed=13, decimals=1)),
        case("resp_high_night", "sleep_resp",
             tonight(tape(40, lambda i, r: r.gauss(14.5, 0.4), seed=14, decimals=1), 15.8)),
        case("temp_stable", "sleep_temp", tape(40, lambda i, r: r.gauss(33.9, 0.25), seed=15, decimals=2)),
        case("spo2_low_night", "sleep_spo2_mean",
             tonight(tape(40, lambda i, r: r.gauss(96.5, 0.8), seed=16, decimals=1), 92.4)),
    ]
    # Daily steps (waking_steps: 21 nights to establish, k 2.4, a 500-step floor; a worn day's 0 is a real 0).
    walk = lambda mu, sd: (lambda i, r: max(0, r.gauss(mu, sd)))  # noqa: E731
    out += [
        case("steps_long_history", "waking_steps", tape(90, walk(8200, 1800), seed=18, decimals=0)),
        case("steps_low_day", "waking_steps", tonight(tape(60, walk(9000, 1500), seed=19, decimals=0), 1800)),
        case("steps_short_history", "waking_steps", tape(12, walk(6500, 1200), seed=20, decimals=0)),
    ]
    zeros = tape(50, walk(7000, 1600), seed=21, decimals=0, missing=0.1)
    for index in (12, 30):
        zeros[index][1] = 0
    out.append(case("steps_zero_days_count", "waking_steps", tonight(zeros, 0)))
    # Gaps, nights outside the plausible range (low quality: kept, never trained) and a zero (also low quality).
    gappy = tape(60, rhr(54, 2.2), seed=5, decimals=0, missing=0.2)
    for index, value in ((10, 25), (31, 140), (44, 0)):
        gappy[index][1] = value
    out.append(case("rhr_gaps_and_out_of_range", "sleep_rhr", tonight(gappy, 57)))
    # Outliers far from the usual (trimmed from the long copy, down-weighted in the week).
    spiky = tape(70, hrv(62, 0.15), seed=11, decimals=1)
    for index, value in ((15, 210.0), (30, 9.0), (50, 180.0), (66, 12.0)):
        spiky[index][1] = value
    out.append(case("hrv_outliers", "sleep_hrv_ln", spiky))
    return out


def main() -> None:
    listed = cases()
    lines = ["{", ' "about": ' + json.dumps("Invented night-vital tapes for the Layer 1 port (one case per line). "
                                             "Written by scripts/make_layer1_cases.py; the expected results are "
                                             "layer1_expected.json, recorded from the app.") + ",", ' "cases": [']
    lines += ["  " + json.dumps(c, separators=(",", ":")) + ("," if i < len(listed) - 1 else "")
              for i, c in enumerate(listed)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines + [" ]", "}"]) + "\n")
    print(f"{len(listed)} cases -> {OUT}")


if __name__ == "__main__":
    main()
