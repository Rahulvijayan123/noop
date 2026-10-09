"""Reference implementation of rule `exercise-session-2` (docs/context-watchdog/EXERCISE_SESSION.md).

Batch mode only: given per-minute evidence and heart rate, return completed sessions and their recovery ends.
The Swift (phone), Python (anomaly service) and SQL (server) implementations are pinned to the fixture this script
writes:

    python3 contracts/reference/exercise_session_2.py > contracts/reference/exercise-session-2.json

Inputs per case: `t0` (unix, minute-aligned), `hr` (bpm per minute or null), `strong` / `weak` (0/1 per minute),
`rest_reference` (bpm). Outputs per case: `sessions` = [{start, end, recovery_end, pre_reference, confirmed,
confirmed_at}] in unix seconds, where `start`/`end` are the first/last evidence minute starts and `recovery_end` is
the start of the first minute that is no longer recovery.

Changes from `exercise-session-1`: a session is `confirmed` once its period holds MIN_CONFIRM_STRONG strong minutes,
or when it starts at most INHERIT_MIN minutes after the last evidence minute of a confirmed session (a workout split
by a long rest). `confirmed_at` is the start of the minute that confirmed it (the period start when inherited), null
when unconfirmed. An unconfirmed session is stored as phase `active`: it has no recovery (`recovery_end` is the
minute after `end`) and trains no exercise reference. Live opening is unchanged.
"""
import json
import statistics

RULE = "exercise-session-2"
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
MIN_CONFIRM_STRONG = 15
INHERIT_MIN = 30


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


def confirmation(a, b, strong, last_confirmed_end):
    """Minute index that confirms the session [a, b], or None. Inherited (index `a`) when the period starts at most
    INHERIT_MIN minutes after the last evidence minute of the previous confirmed session; otherwise the minute of the
    MIN_CONFIRM_STRONG-th strong minute in the period."""
    if last_confirmed_end is not None and a - last_confirmed_end <= INHERIT_MIN:
        return a
    count = 0
    for i in range(a, b + 1):
        count += 1 if strong[i] else 0
        if count == MIN_CONFIRM_STRONG:
            return i
    return None


def sessions(t0, hr, strong, weak, rest):
    n = len(hr)
    ev = anchored(strong, weak)
    found = [(a, b) for a, b in periods(ev) if qualifies(a, b, hr, strong, weak, rest)]
    out = []
    busy = set()
    previous_pre = None
    last_confirmed_end = None
    for k, (a, b) in enumerate(found):
        pre = pre_reference(a, hr, rest, busy, previous_pre)
        previous_pre = pre
        confirmed_at = confirmation(a, b, strong, last_confirmed_end)
        if confirmed_at is None:
            busy.update(range(a, b + 1))
            out.append({"start": t0 + a * 60, "end": t0 + b * 60, "recovery_end": t0 + (b + 1) * 60,
                        "pre_reference": round(float(pre), 3), "confirmed": False, "confirmed_at": None})
            continue
        last_confirmed_end = b
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
                    "pre_reference": round(float(pre), 3), "confirmed": True, "confirmed_at": t0 + confirmed_at * 60})
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

    def weakest_gym_19_strong(hr, strong, weak):
        # The owner's weakest gym session had 19 strong minutes: one set every third minute, still between sets.
        for i in range(0, 260):
            hr[i] = 72
        for k in range(19):
            i = 40 + 3 * k
            strong[i] = 1
        for i in range(40, 95):
            hr[i] = 118 + (i % 4)
        for j, i in enumerate(range(95, 260)):
            hr[i] = round(76 + 45 * (0.92 ** j))

    def late_night_low_movement(hr, strong, weak):
        # 4 strong minutes and anchored weak movement over 25 minutes at 100 bpm: session conditions 1-4 hold, but
        # it is not confirmed, so it is stored as `active` with no recovery.
        for i in range(0, 150):
            hr[i] = 70
        for i in range(40, 65):
            weak[i] = 1 if i % 2 == 0 else 0
            hr[i] = 100
        for i in (42, 50, 56, 64):
            strong[i] = 1
            weak[i] = 0
        for i in range(65, 80):
            hr[i] = 98

    def split_workout_carry_over(hr, strong, weak):
        # A confirmed session (15 strong), a 20-minute rest, a short second block (5 strong) that inherits
        # confirmation, another 25-minute rest and a third block that inherits it from the second.
        for i in range(0, 300):
            hr[i] = 72
        for i in range(30, 60):
            strong[i] = 1 if i % 2 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 132
        for i in range(60, 80):
            hr[i] = 104
        for i in range(80, 96):
            strong[i] = 1 if i % 3 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 128
        for i in range(96, 121):
            hr[i] = 105
        for i in range(121, 136):
            strong[i] = 1 if i % 3 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 126
        for j, i in enumerate(range(136, 300)):
            hr[i] = round(76 + 45 * (0.9 ** j))

    def confirm_threshold_14_then_15(hr, strong, weak):
        # 14 strong minutes stays unconfirmed; much later, 15 strong minutes confirms at the 15th.
        for i in range(0, 400):
            hr[i] = 72
        for i in range(30, 58):
            strong[i] = 1 if i % 2 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 124
        for i in range(200, 230):
            strong[i] = 1 if i % 2 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 124

    def carry_over_expires(hr, strong, weak):
        # A confirmed session, then 40 minutes later a short block: too late to inherit, so it stays unconfirmed.
        for i in range(0, 260):
            hr[i] = 72
        for i in range(30, 60):
            strong[i] = 1
            hr[i] = 130
        for i in range(60, 100):
            hr[i] = 92
        for i in range(100, 116):
            strong[i] = 1 if i % 3 == 0 else 0
            weak[i] = 1 - strong[i]
            hr[i] = 122

    return [
        _case("gym_sets_with_leg_work", 200, 72, gym),
        _case("resting_tachycardia_no_movement", 120, 70, resting_tachy),
        _case("fidgeting_tachycardia_weak_only", 120, 70, fidget_tachy),
        _case("short_brisk_walk_under_12_min", 90, 72, short_walk),
        _case("easy_walk_no_load", 120, 72, easy_walk),
        _case("two_bouts_gap_15_min", 200, 72, two_bouts),
        _case("no_return_recovery_capped", 260, 70, no_return),
        _case("fidgety_day_with_short_walk", 300, 70, fidgety_day_with_short_walk),
        _case("weakest_gym_19_strong", 260, 72, weakest_gym_19_strong),
        _case("late_night_low_movement_4_strong", 150, 70, late_night_low_movement),
        _case("split_workout_carry_over", 300, 72, split_workout_carry_over),
        _case("confirm_threshold_14_then_15", 400, 72, confirm_threshold_14_then_15),
        _case("carry_over_expires_after_30_min", 260, 72, carry_over_expires),
    ]


if __name__ == "__main__":
    print(json.dumps({"rule": RULE, "cases": cases()}, indent=1))
