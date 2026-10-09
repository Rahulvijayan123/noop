"""Reference implementation of rule `exercise-session-1` (docs/context-watchdog/EXERCISE_SESSION.md).

Batch mode only: given per-minute evidence and heart rate, return completed sessions and their recovery ends.
The Swift (phone) and SQL (server) implementations are pinned to the fixture this script writes:

    python3 contracts/reference/exercise_session_1.py > contracts/reference/exercise-session-1.json

Inputs per case: `t0` (unix, minute-aligned), `hr` (bpm per minute or null), `strong` / `weak` (0/1 per minute),
`rest_reference` (bpm). Outputs per case: `sessions` = [{start, end, recovery_end, pre_reference}] in unix seconds,
where `start`/`end` are the first/last evidence minute starts and `recovery_end` is the start of the first minute
that is no longer recovery.
"""
import json
import statistics

RULE = "exercise-session-1"
MERGE_GAP_MIN = 10
ANCHOR_MIN = 20
SPAN_MIN = 10
MIN_EVIDENCE_IN_SPAN = 3
MIN_STRONG = 2
LOAD_DELTA_BPM = 25
MIN_LOAD_MIN = 8
MIN_DURATION_MIN = 12
RETURN_DELTA_BPM = 10
RETURN_RUN_MIN = 5
RECOVERY_CAP = (30, 120)
PRE_WINDOW = (45, 10)


def anchored(strong, weak):
    """Evidence minutes that count: strong minutes, and weak minutes within ANCHOR_MIN minutes of a strong one.
    Weak movement far from any strong minute (a fidgety afternoon) never forms or stretches a period."""
    n = len(strong)
    strong_idx = [i for i in range(n) if strong[i]]
    out = [False] * n
    j = 0
    for i in range(n):
        if strong[i]:
            out[i] = True
        elif weak[i]:
            while j < len(strong_idx) and strong_idx[j] < i - ANCHOR_MIN:
                j += 1
            out[i] = j < len(strong_idx) and strong_idx[j] <= i + ANCHOR_MIN
    return out


def periods(evidence):
    """Active periods: evidence minutes merged while the gap is at most MERGE_GAP_MIN minutes."""
    idx = [i for i, e in enumerate(evidence) if e]
    out = []
    for i in idx:
        if out and i - out[-1][1] <= MERGE_GAP_MIN:
            out[-1][1] = i
        else:
            out.append([i, i])
    return out


def qualifies(a, b, hr, strong, weak, rest):
    ev = anchored(strong, weak)
    dense = any(sum(ev[j] for j in range(s, min(s + SPAN_MIN, b + 1))) >= MIN_EVIDENCE_IN_SPAN
                for s in range(a, b + 1))
    n_strong = sum(strong[i] for i in range(a, b + 1))
    load = sum(1 for i in range(a, b + 1) if hr[i] is not None and hr[i] >= rest + LOAD_DELTA_BPM)
    duration = b - a + 1
    return dense and n_strong >= MIN_STRONG and load >= MIN_LOAD_MIN and duration >= MIN_DURATION_MIN


def pre_reference(a, hr, rest, busy, fallback):
    """Median HR 45..10 minutes before `a`, skipping minutes inside an earlier session or its recovery."""
    lo, hi = max(0, a - PRE_WINDOW[0]), max(0, a - PRE_WINDOW[1])
    vals = [hr[i] for i in range(lo, hi) if hr[i] is not None and i not in busy]
    if vals:
        return statistics.median(vals)
    return fallback if fallback is not None else rest


def sessions(t0, hr, strong, weak, rest):
    n = len(hr)
    ev = anchored(strong, weak)
    found = [(a, b) for a, b in periods(ev) if qualifies(a, b, hr, strong, weak, rest)]
    out = []
    busy = set()
    previous_pre = None
    for k, (a, b) in enumerate(found):
        pre = pre_reference(a, hr, rest, busy, previous_pre)
        previous_pre = pre
        duration = b - a + 1
        cap = min(max(duration, RECOVERY_CAP[0]), RECOVERY_CAP[1])
        limit = min(n, b + 1 + cap)
        if k + 1 < len(found):
            limit = min(limit, found[k + 1][0])
        end = limit
        run = 0
        for i in range(b + 1, limit):
            if hr[i] is not None and hr[i] <= pre + RETURN_DELTA_BPM:
                run += 1
                if run == RETURN_RUN_MIN:
                    end = i - RETURN_RUN_MIN + 1
                    break
            else:
                run = 0
        busy.update(range(a, end))
        out.append({"start": t0 + a * 60, "end": t0 + b * 60, "recovery_end": t0 + end * 60,
                    "pre_reference": round(float(pre), 3)})
    return out


def _case(name, minutes, rest, build):
    hr = [None] * minutes
    strong = [0] * minutes
    weak = [0] * minutes
    build(hr, strong, weak)
    t0 = 1_790_000_000 - 1_790_000_000 % 60
    return {"name": name, "t0": t0, "rest_reference": rest, "hr": hr, "strong": strong, "weak": weak,
            "sessions": sessions(t0, hr, strong, weak, rest)}


def cases():
    def gym(hr, strong, weak):
        for i in range(0, 50):
            hr[i] = 74 + (i % 3)
        # 60 minutes of sets: 1 strong minute, 2 still minutes, HR 112–142.
        for i in range(50, 110):
            phase = (i - 50) % 3
            strong[i] = 1 if phase == 0 else 0
            hr[i] = 140 - 8 * phase - (i % 5)
        # 8 minutes of leg work: strap still, HR high; then one more set.
        for i in range(110, 117):
            hr[i] = 128
        strong[116] = 1
        hr[116] = 131
        for i in range(117, 121):
            hr[i] = 126
        # Recovery: decays toward 78.
        for j, i in enumerate(range(121, 200)):
            hr[i] = round(78 + 50 * (0.93 ** j))

    def resting_tachy(hr, strong, weak):
        for i in range(0, 120):
            hr[i] = 70 if i < 40 else 125

    def fidget_tachy(hr, strong, weak):
        for i in range(0, 120):
            hr[i] = 70 if i < 40 else 121
            weak[i] = 1 if i >= 40 and i % 2 == 0 else 0

    def short_walk(hr, strong, weak):
        for i in range(0, 90):
            hr[i] = 72
        for i in range(40, 48):
            strong[i] = 1
            hr[i] = 104

    def easy_walk(hr, strong, weak):
        for i in range(0, 120):
            hr[i] = 72
        for i in range(40, 70):
            strong[i] = 1
            hr[i] = 88

    def two_bouts(hr, strong, weak):
        for i in range(0, 200):
            hr[i] = 72
        for i in range(30, 55):
            strong[i] = 1 if i % 2 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 120
        for i in range(55, 70):
            hr[i] = 90
        for i in range(70, 95):
            strong[i] = 1
            hr[i] = 125
        for i in range(95, 200):
            hr[i] = 76

    def fidgety_day_with_short_walk(hr, strong, weak):
        # Four hours of fidgeting (weak every other minute) at 96 bpm, a 6-minute walk at 115 in the middle.
        for i in range(0, 300):
            hr[i] = 72 if i < 30 or i >= 270 else 96
            weak[i] = 1 if 30 <= i < 270 and i % 2 == 0 else 0
        for i in range(147, 153):
            strong[i] = 1
            weak[i] = 0
            hr[i] = 115

    def no_return(hr, strong, weak):
        for i in range(0, 60):
            hr[i] = 70
        for i in range(60, 90):
            strong[i] = 1
            hr[i] = 140
        for i in range(90, 260):
            hr[i] = 118

    return [
        _case("gym_sets_with_leg_work", 200, 72, gym),
        _case("resting_tachycardia_no_movement", 120, 70, resting_tachy),
        _case("fidgeting_tachycardia_weak_only", 120, 70, fidget_tachy),
        _case("short_brisk_walk_under_12_min", 90, 72, short_walk),
        _case("easy_walk_no_load", 120, 72, easy_walk),
        _case("two_bouts_gap_15_min", 200, 72, two_bouts),
        _case("no_return_recovery_capped", 260, 70, no_return),
        _case("fidgety_day_with_short_walk", 300, 70, fidgety_day_with_short_walk),
    ]


if __name__ == "__main__":
    print(json.dumps({"rule": RULE, "cases": cases()}, indent=1))
