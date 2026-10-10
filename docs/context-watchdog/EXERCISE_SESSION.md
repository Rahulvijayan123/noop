# Exercise session and recovery (rule `exercise-session-2`)

One rule, implemented three times: on the phone in `Packages/StrandAnalytics/Sources/StrandAnalytics/ExerciseSession.swift`
(the Watchdog and the Layer 1 context strata), on the server in the measurement-context minute builder
(`supabase/migrations/20261009130100_measurement_context_minutes.sql`, `internal.exercise_session_spans_v2`), and in
the anomaly service (`Tools/AnomalyService/src/frwhoop_anomaly/exercise_session.py`). All three are pinned by the
shared fixture `contracts/reference/exercise-session-2.json`, written by `contracts/reference/exercise_session_2.py`.

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
  acceleration ≥ 0.10 g; or (phone) a decoder interval covering the minute with locomotion
  `walking`/`brisk_walking`/`running`, class `brisk_walking`/`running`/`cycling`/`vigorous_activity`, or arm behaviour
  `exercise_motion`; or (server, which has no decoder intervals) a current-lineage activity epoch labelled walking,
  running or active with confidence ≥ 0.6, or one inside a workout the person logged;
- *weak*: mean dynamic acceleration ≥ 0.05 g, or (phone) decoder class `light_activity`.

The Watchdog's own activity class is not evidence: it is weighted by heart rate, and evidence never is. HART
`other_movement` epochs are not evidence either: on the owner's data they cover 27 % of gym minutes and 29 % of other
awake minutes, so they carry no information about exercise (rule -1 counted them as weak on the server, which
stretched one non-gym period from 37 to 71 minutes).

A minute asleep or off the wrist is never evidence (whatever its motion). A weak minute counts only within 20 minutes
of a strong minute, so a fidgety afternoon never forms or stretches a period on its own.

From stored decoder intervals (Layer 1, history), the decoder's log-scaled intensity stands in for dynamic
acceleration: ≥ 0.48 (≈ 100 mg) strong, ≥ 0.40 (≈ 49 mg) weak; a minute is strong (weak) when strong (any evidence)
intervals cover ≥ 20 s of it.

**Active period**: counted evidence minutes (strong, or anchored weak) merged while the gap between consecutive
evidence minutes is at most 10 minutes. The period spans first to last evidence minute, still minutes inside included.

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

**Confirmation** (new in -2): a session is *confirmed* once its period holds at least 15 strong minutes, or when it
starts at most 30 minutes after the last evidence minute of the previous confirmed session (a workout split by a long
rest inherits confirmation; inheritance only runs forward). Confirmation never changes live opening: an open session
is compared with the exercise reference from the moment 1–3 hold, confirmed or not, so no gym minute goes back to a
rest comparison. It decides what the session leaves behind:

- a *confirmed* session gets its recovery phase and trains the personal exercise references and the routine;
- a session that ends *unconfirmed* is stored as phase `active`: no recovery phase (the usual 10-minute settle after a
  bout of movement applies, then the normal references), no exercise-reference or routine training, and its minutes
  still never enter a rest reference.

Why 15: on the owner's 9.5 days (9 gym sessions, `_build-scratch/ctxwd/G-models/`), every gym session held 19–100
strong minutes, while the non-gym periods that rule -1 called sessions held 3–27. Confirming at 15 with the 30-minute
carry-over keeps 9 of 9 gym sessions and 98.9 % of gym minutes inside a session, and cuts non-gym sessions from 6 to 1
(rest reference 70) or 15 to 4 (nightly resting HR + 10). Confirmation comes 1 minute later than opening at the
median, 20 at most. The margin is thin (19 against 15, 20 and 27), and a real workout with fewer than 15 strong
minutes is stored as `active`; the threshold is a new rule id when it changes.

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
| active (ended unconfirmed) | unchanged (posture / walking references after the 10-minute bout settle) | unchanged |
| neither | unchanged (posture / walking / sleep references) | unchanged |

Session, recovery and active minutes never enter rest references (awake rest, posture strata, the anomaly service's rest
bucket). A recurring routine (time of day × weekday/weekend) is recorded for interpretation and display only; it
never opens a session, never widens a safety bound, and never turns an alert into "usual".

## Activity models

The pretrained activity models were checked against the owner's gym sessions (audit 2026-10-09,
`_build-scratch/ctxwd/G-models/`). They see the cardio part of a gym session and not the lifting:

- HART calls 13.6 % of gym windows walking against 0.1 % elsewhere, but the strap's own motion and step classes
  already mark those minutes, live. HART abstains on 52 % of gym windows (it is trained on wrists; the strap is on the
  upper arm), and its epochs arrive a median 7 minutes after the data, up to 80.
- ActiNet's arm `exercise_motion` (candidate tier) fires on 22 % of covered gym minutes against 2.7 % elsewhere, with
  about 45 % coverage because raw motion is recorded 60 s in every 180 s.
- None of them sees the still lifting minutes (no motion, no steps, median HR 91): each flags 0–13 % of them.

Adding model evidence to rule -1 would have gained at most 1.5 points of gym coverage, never opened a session earlier,
and let one non-gym period back in. So models are not evidence here: they never open, confirm, extend or mute a
session. The phone's decoder already fuses HART when it arrives, and the Watchdog re-reads the evidence of re-decoded
minutes. A model trained on gym exercises themselves (resistance training on an arm IMU) is ported separately in
shadow mode and is not evidence either until it is validated on the owner's sessions.

## Logged workouts

A workout the wearer logged in workout mode ([WORKOUTS.md](WORKOUTS.md)) does not change the rule. Its minutes are
strong evidence (on the server this was already "inside a workout the person logged"; the phone and the anomaly service
now read the same log), so a logged workout of 15 minutes or more confirms itself at its 15th minute and gets its
recovery from the rule. The load check still decides whether the rule finds a session. On top of the rule, each
consumer treats a logged minute as `session` (an observed label) from its first minute while the strap is worn: the
Watchdog compares it with the exercise-session reference (safety bounds unchanged), the measurement-context row records
`session_basis = logged` with the workout's type, and the anomaly service withholds its windows as exercise.

## Versioning

The rule id `exercise-session-2` is stored with every derived row. Any change to a threshold is a new id.

Changes from `exercise-session-1` (which was never deployed): the confirmation step and the `active` phase; HART
`other_movement` removed from the server's weak evidence; the Watchdog activity class removed from this document's
evidence list (the code never used it).
