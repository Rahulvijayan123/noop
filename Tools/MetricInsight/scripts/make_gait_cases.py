"""Write tests/data/gait_cases.json: invented ElderNet `gait-windows-1` days for the walking-day port (gait.py).

The expected readings come from the app, never from the port. After changing the cases (or WalkingDayReading):
    uv run python scripts/make_gait_cases.py
    cd ../../Packages/StrandAnalytics && GAIT_MIRROR_RECORD=1 swift test --filter GaitServerMirrorTests
records tests/data/gait_expected.json; then GaitServerMirrorTests and tests/test_gait.py both check against it.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "tests" / "data" / "gait_cases.json"
DAY = 1_791_014_400          # an invented local midnight (epoch seconds)


def columns(hop: int, windows: list[dict], width: int = 10) -> dict:
    """`gait-windows-1` from windows {start, gp, g, pf, sp, cad, st, rg, stp} (stored units, -1 = absent)."""
    windows = sorted(windows, key=lambda w: w["start"])
    s0 = windows[0]["start"] - 7 if windows else DAY
    ds, t = [], s0
    for w in windows:
        ds.append(w["start"] - t)
        t = w["start"]
    out = {"format": "gait-windows-1", "n": len(windows), "w": width, "h": hop, "s0": s0, "ds": ds}
    for key in ("gp", "g", "pf", "sp", "cad", "st", "rg", "stp"):
        out[key] = [w[key] for w in windows]
    return out


def walk(rng: random.Random, start: int, seconds: int, hop: int, cadence: float, speed: float, *,
         pauses: tuple[tuple[int, int], ...] = (), no_speed_every: int = 0) -> list[dict]:
    out = []
    for i, t in enumerate(range(start, start + seconds, hop)):
        paused = any(a <= t - start < a + length for a, length in pauses)
        if paused:
            out.append({"start": t, "gp": 180, "g": 0, "pf": 0, "sp": -1, "cad": -1, "st": -1, "rg": -1, "stp": -1})
            continue
        cad = cadence + rng.uniform(-4, 4)
        sp = -1 if no_speed_every and i % no_speed_every == 0 else round((speed + rng.uniform(-0.1, 0.1)) * 100)
        out.append({"start": t, "gp": 900 + rng.randint(0, 99), "g": 1, "pf": 0, "sp": sp, "cad": round(cad),
                    "st": -1 if sp < 0 else round(sp / cad * 120), "rg": 70 + rng.randint(0, 25),
                    "stp": round(cad / 60 * 10 * 10)})
    return out


def still(start: int, seconds: int, hop: int, prefiltered: bool) -> list[dict]:
    return [{"start": t, "gp": 0 if prefiltered else 40, "g": 0, "pf": 1 if prefiltered else 0, "sp": -1, "cad": -1,
             "st": -1, "rg": -1, "stp": -1} for t in range(start, start + seconds, hop)]


def cases() -> list[dict]:
    rng = random.Random(7)
    h = 3_600
    day = (still(DAY + 2 * h, 600, 5, prefiltered=True)
           + walk(rng, DAY + 8 * h, 900, 5, 110, 1.4, pauses=((420, 10),))
           + walk(rng, DAY + 14 * h, 480, 5, 85, 1.0, pauses=((240, 25),), no_speed_every=4)
           + walk(rng, DAY + 16 * h, 30, 5, 95, 1.1)
           + still(DAY + 17 * h, 300, 5, prefiltered=False)
           + walk(rng, DAY - 600, 300, 5, 120, 1.6))           # the evening before: outside the day
    # The local day spans two UTC rows that both hold the window at their seam (counted once).
    seam = DAY + 7 * h
    first = walk(rng, seam - 300, 330, 5, 104, 1.3)
    second = [dict(w) for w in first if w["start"] >= seam] + walk(rng, seam + 30, 270, 5, 104, 1.3)
    return [
        {"name": "walks_pauses_and_still", "from": DAY, "to": DAY + 24 * h, "days": [columns(5, day)]},
        {"name": "two_utc_rows_one_seam", "from": DAY, "to": DAY + 24 * h,
         "days": [columns(5, first), columns(5, second)]},
        {"name": "no_walking_but_assessed", "from": DAY, "to": DAY + 24 * h,
         "days": [columns(5, still(DAY + 9 * h, 900, 5, prefiltered=False))]},
        {"name": "hop_10_no_overlap", "from": DAY, "to": DAY + 24 * h,
         "days": [columns(10, walk(rng, DAY + 18 * h, 1200, 10, 118, 1.5))]},
        {"name": "nothing_stored", "from": DAY, "to": DAY + 24 * h, "days": []},
    ]


def main() -> None:
    listed = cases()
    lines = ["{", ' "about": ' + json.dumps("Invented ElderNet gait-windows-1 days for the walking-day port "
                                             "(gait.py). Written by scripts/make_gait_cases.py; the expected readings "
                                             "are gait_expected.json, recorded from the app.") + ",", ' "cases": [']
    lines += ["  " + json.dumps(c, separators=(",", ":")) + ("," if i < len(listed) - 1 else "")
              for i, c in enumerate(listed)]
    OUT.write_text("\n".join(lines + [" ]", "}"]) + "\n")
    print(f"{len(listed)} cases -> {OUT}")


if __name__ == "__main__":
    main()
