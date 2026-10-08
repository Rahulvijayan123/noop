# Activity ground truth — guided calibration, labels, evaluation

Operator guide for the WHOOP activity ground-truth work: guided labeled capture, ground-truth label
storage and sync, weak labels from stretch feedback, and the offline evaluation harness.

## Guided activity calibration (phone, WHOOP 5/MG)

Settings → Test Centre → **Activity calibration** (shown only when a WHOOP 5/MG is paired). A session:

1. snapshots the current raw-IMU capture mode and durably records it (`activity-calibration-inflight-v1`);
2. requests **continuous** raw-IMU capture for the session (100 Hz accel + gyro instead of the default
   part-time duty cycle);
3. gates on: strap connected + bonded, 5/MG, on-wrist, battery above the low-battery threshold and not
   charging-up-from-low, and no manual Raw Data session in flight (the raw session owns the stream);
4. walks the guided protocol (`calibration-v3`, about 5.5 minutes) as two skippable activities, posture and
   posture changes only. Walking, desk work, typing and fidgeting are not collected: ElderNet and the gait
   chain already call walking, and the personal-profile fitter never learns from arm tags.
   - *Sit and stand*: sit, stand up, stand, sit down, twice (30 s holds).
   - *Lie down and get up*: sit, lie down, lie, sit up, sit, lie down, lie, get up and stand.
   Each run has eight position changes (sit to stand, stand to sit, lying down, getting up);
5. each activity waits on a Start tap, then a 5 s countdown, then its steps run back to back with no taps.
   There are exactly two cues: **one buzz = move now** (fired 3 s into a move, after an on-screen "get ready"
   count) and **three buzzes = activity done**. Holds never buzz. The screen reads the same `Date`
   deadlines the runner acts on, so the words, the numbers and the buzz change in the same 0.1 s tick. The
   strap buzz is an acknowledged write so the IMU stream cannot crowd it out; the phone mirrors both cues.
   Every activity can be skipped (**Skip activity**), and **Stop** ends the run; skipping or stopping keeps the
   steps already saved. The labeled interval trims a 2 s guard from each step edge, and a move's
   `transition_ts` is the instant the buzz fired, always inside the interval so the server accepts it;
6. writes one ground-truth label per step with its cue timestamps, posture or transition heads
   (+ `transition_ts`), the phone's raw-IMU
   coverage for the interval (`sensor_quality`: covered seconds, gaps, 100 Hz), and raw-evidence
   references (`raw_refs`); a label with no raw evidence records *explicitly missing* coverage, never a
   silent zero;
7. restores the previous capture mode on success, cancel, backgrounding, and — through the durable
   marker — on the next launch if the app died mid-session. The mode is restored before the marker is
   cleared, so a crash in between restores again on the next launch.

Labels sync to `POST /scores/ground-truth-labels` in batches of 25 with the installation credential; the
server enriches `raw_refs` with the verified `rawImuSession` object manifests that overlap the interval.
Labels never store raw IMU bytes and never store model predictions as truth.

A label the server refuses as structurally invalid (`invalid_*`) is moved out of the upload queue into
`ground-truth-labels.quarantine.json` beside the label file, so it is not re-sent on every scene
activation. It is kept, not deleted, and goes back in the queue when a different app build runs (the
refusal may mean the server was older than the app). Other refusals keep retrying.

## Weak labels from stretch feedback

The day page ("Your day" section) shows a compact **Help improve activity detection** queue (≤ 5/day)
when recent decoded stretches are uncertain (high uncertainty, low head confidence, small top-2 margin,
abstaining heads), disagree (HART windows vs the decoder), or cover rare classes. An answer also writes a
**weak** ground-truth label (`source = stretch_feedback`). **Unsure never becomes a hard training label**
(`user_unsure = true`); Mixed records an empty-headed weak label; Skip records nothing.

## Evaluation (offline, `Tools/ActivityContext`)

```bash
cd Tools/ActivityContext
uv venv --python 3.10 .venv && uv pip install --python .venv/bin/python -e ".[dev]"
.venv/bin/python -m activity_context.evaluate_labels \
    --labels labels.jsonl --windows day-hart-windows.json \
    --out-dir out --holdout-sessions 1 --json
```

Guided strong labels only by default (`--include-weak` adds a clearly-labelled combined view); gapped
labels are excluded unless `--include-degraded`. Splits are session-held-out (or chronological) — never
random windows. A guided label's session is its calibration session; a stretch-feedback label's session is
its own stretch. Windows on opposite sides of the split that share raw seconds are dropped from both sides
and counted (`overlap_dropped_units`).

Reported per (model × head × split): per-class P/R/F1, macro-F1, balanced accuracy, confusion matrix,
abstention, accepted coverage, duration-weighted accuracy, segment IoU, Brier/ECE-15 (accepted windows,
head's own simplex), transitions (F1 at ±2/5/10 s, timing error, false events/hour), per-session
distributions, and a temporal block on the decoded stream:

- **label acquisition delay**: after a truth change, time until the first window predicting the new truth;
- **transition delay**: each predicted change against the nearest truth change in the same contiguous
  stretch of windows (signed bias, median and p90 of the absolute delay);
- **flips per hour** outside ±2 s of a truth change, and the median run length of identical predictions;
- **time to stable correct state**: time until 3 consecutive windows predict the new truth.

A gap between labelled windows (the rest between two guided steps) is never a truth change.

`activity_context.personalize` is a SHADOW-ONLY prototype: it refuses to fit below the evidence gates
(≥ 30 windows AND ≥ 3 distinct sessions per class) and reports generic-vs-personalized deltas on held-out
sessions.

## Real-device checklist (WHOOP 5/MG, one guided run)

1. Pair the strap, sign in, and confirm the day page shows decoded activity.
2. Set raw-IMU capture to a known mode (e.g. Part-time) in Settings → Test Centre.
3. Settings → Test Centre → Activity calibration → review the protocol → Start.
4. Confirm the gate passes (connected, on-wrist, battery OK); if blocked, the message names the reason and
   the capture mode is unchanged.
5. During a labeled step, confirm the strap keeps streaming continuously rather than on the duty cycle.
6. Finish or cancel the session → confirm the capture mode returns to the previous setting immediately.
7. Force-quit the app mid-session → relaunch → confirm the mode is restored and capture is not stuck on
   continuous.
8. After ~10 minutes (upload lane + worker), verify on the server: `object_manifests` has new verified
   `rawImuSession` objects covering the session; `activity_ground_truth_labels` holds the labels with
   `raw_refs` enriched with object ids + sha256 digests; `activity_encoder_windows` has rows overlapping
   the labeled intervals.
9. Export the day's `hart-windows-1` document + labels and run the evaluation CLI; confirm the report
   counts the labeled windows and separates strong from weak.
10. Repeat a short session with the strap low-battery or off-wrist: the gate blocks, the mode is restored,
    and any partial labels record their missing coverage explicitly.
