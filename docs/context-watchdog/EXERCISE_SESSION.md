# Exercise session and recovery (rule `exercise-session-1`)

One rule, implemented twice: on the phone in `Packages/StrandAnalytics/Sources/StrandAnalytics/ExerciseSession.swift`
(the Watchdog and the Layer 1 context strata) and on the server in the measurement-context minute builder
(`supabase/migrations/2026100913xxxx_measurement_context_minutes.sql`). Both are pinned by the shared fixture
`contracts/reference/exercise-session-1.json`.

## Why

A wrist (or upper-arm) strap sees resistance training as mostly still: between sets, and during leg work, the strap
barely moves while heart rate is 100–150 bpm. Judging those minutes against a sitting or resting reference produced
the gym false alarms (audit 2026-10-09, `_build-scratch/ctxwd/A-watchdog/REPORT.md`). The fix is a session: a period
opened by movement, which keeps its still minutes, followed by a recovery phase. Inside them, readings are compared
with the person's own exercise and recovery references, never muted. Outside them nothing changes.

## Rules

Inputs are per-minute and HR-free except the load check.

**Evidence minutes** (never heart rate, never time of day):

- *strong*: walking or running step ticks covering at least half of the minute's step samples; or mean dynamic
  acceleration ≥ 0.10 g; or an exercise activity class for the minute (walk, run, cycle-like, resistance); or a decoder
  interval covering the minute with locomotion `walking`/`brisk_walking`/`running`, class
  `brisk_walking`/`running`/`cycling`/`vigorous_activity`, or arm behaviour `exercise_motion`;
- *weak*: mean dynamic acceleration ≥ 0.05 g, or decoder class `light_activity`.

**Active period**: evidence minutes (strong or weak) merged while the gap between consecutive evidence minutes is at
most 10 minutes. The period spans first to last evidence minute, still minutes inside included.

**Exercise session**: an active period that has

1. at least 3 evidence minutes inside some 10-minute span, and
2. at least 2 strong minutes, and
3. load: at least 8 minutes with heart rate ≥ rest reference + 25 bpm, and
4. duration (first to last evidence minute) ≥ 12 minutes.

The rest reference is, in order: the established awake-rest HR centre; the sleep resting HR + 10; the median of the
person's still, awake minutes in the 2 hours before the period; 70 bpm. Heart rate only qualifies a period that
movement opened (3): a still, high heart rate never opens a session, so resting tachycardia keeps being judged
against rest.

**Live sessions** (the phone): a period counts as a session as soon as 1–3 hold, even while shorter than 12 minutes
(4 is checked once it ends). A session stays open while the newest evidence minute is at most 10 minutes old.

**Recovery**: starts at the session's last evidence minute. It ends at the first of

- heart rate within the pre-session reference + 10 bpm for 5 consecutive minutes (the pre-session reference is the
  median HR from 45 to 10 minutes before the session started, skipping minutes inside an earlier session or its recovery, falling back to the
  previous session's pre-session reference, then the rest reference), or
- the cap: session duration clamped to [30, 120] minutes, or
- a new session.

Minutes in recovery that are again evidence minutes extend the session instead (the gap rule above).

## What the phases change

| Phase | Compared with | Safety bounds |
| --- | --- | --- |
| session | `exercise_session_hr` (personal; "learning" until established) | in-session ceiling: HR above min(own session p99 + 10, 208 − 0.7·age, or 200 bpm when age is unknown) for ≥ 5 min |
| recovery | `exercise_recovery_hr` (personal; "learning" until established) | resting rule (> 120 bpm for 10 still minutes) applies from 15 minutes after the session's last evidence minute |
| neither | unchanged (posture / walking / sleep references) | unchanged |

Session and recovery minutes never enter rest references (awake rest, posture strata, the anomaly service's rest
bucket). A recurring routine (time of day × weekday/weekend) is recorded for interpretation and display only; it
never opens a session, never widens a safety bound, and never turns an alert into "usual".

## Versioning

The rule id `exercise-session-1` is stored with every derived row. Any change to a threshold is a new id.
