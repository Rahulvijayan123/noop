# Signals Watchdog and Layer 1 now read

Four additions. Each one is a signal this app already stored, which the old Watchdog and Layer 1 never read. Each section has the same four parts: the gap, how the code is better, how the wiring works, and what stays the same.

HART is not one of these four. It is a later note at the end. It does not set Off, a notification, or a Layer 1 center.

None of the four average Charge into these engines, write a 7-day or 60-day snapshot from `evaluate`, or score the raw 100 Hz tensor.

## 1. One-hertz motion when the gravity lane is missing

### 1. The gap

The old window trusted SQLite `gravitySample` alone. A WHOOP 5 session on this app can have a full 100 Hz capture file and an empty gravity table, or gravity rows whose `dynAccel` is nil. Those minutes stayed `unknown`. The 14-minute green band never stamped, and `wakingImuEnergy` stayed empty on a day the strap moved.

### 2. How this improves the code

The tick can learn still, walk, and waking energy from motion the phone already saved, without a second capture path and without handing 100 Hz samples to `evaluate`.

### 3. How the implementation works

`WatchdogService.imuSamples` still prefers SQLite `x, y, z`. It opens `ImuSessionFileStore` only when that lane is empty, or when the family is WHOOP 5 and every row’s `dynAccel` is nil. `WatchdogGravityFill.fromRawIMU` turns each one-second frame into one sample: the mean of the first 300 acceleration columns is the gravity vector, and `dynAccel` is the RMS of the per-sample magnitude around that mean. SQLite `x, y, z` win. A missing `dynAccel` is filled by timestamp. `evaluate` still sees one sample per second.

### 4. What stays the same

Chair-still is still occupancy under 0.32 and `dynAccel` under 0.22. Unknown minutes still do not stamp the green band. The 100 Hz writer and the file format are unchanged. Off, safety, and personal-off still come from the vital residuals, not from this fill.

## 2. The strap’s asleep code, before a sleep session exists

### 1. The gap

The old tick marked sleep only from scored sleep sessions. A minute the strap had already called asleep, while that session was still open or not written yet, could train awake rest and the still green band.

### 2. How this improves the code

Sleep stays out of awake rest as soon as the strap says so. The engines use a stream they already bank (`sleepStateSample`), instead of waiting for a closed session row.

### 3. How the implementation works

Each tick reads `sleepStateSample` for the Watchdog source ids over the same half-hour. State `2` means asleep. States `0` (wake), `1` (still), and `3` (up) are ignored. `WatchdogService.asleepIntervals` merges those seconds into half-open intervals and starts a new interval when the gap is longer than 90 seconds. The intervals are appended to the session list passed into `evaluate` and into the tape ingest. A WHOOP 4.0 that never banks the stream adds nothing.

### 4. What stays the same

This is the existing sleep door, with an earlier start. It does not create a sleep score and does not change Charge. The extra bits in `rawByte` (on-wrist, wake quality) are not read. Wrist-off stays on `WRIST_OFF` / `WRIST_ON` plus a fresh live heart-rate packet. A quiet window’s severity, `shouldNotify`, and live Off do not move just because a sleep interval was added.

## 3. Logged placement, when the strap is not on the wrist

### 1. The gap

Chair-still and `wakingImuEnergy` assume a wrist gravity vector. A bicep or other site the wearer logged would otherwise look still, stamp a green band, and add energy to a series that means waking wrist motion.

### 2. How this improves the code

A placement the wearer already set stops the wrist model from learning on the wrong site. Unknown placement is not guessed into wrist or into bicep.

### 3. How the implementation works

`PlacementStore.activePlacement` is read for the active device at the tick time. `wrist` and `unknown` keep the IMU path in section 1. `bicep` and `other` return an empty IMU list before any file read, so the minute stays unknown unless the strap step class says walk or run. Putting the strap back on the wrist in Settings restores gravity on the next tick. No past Layer 1 day is rewritten.

### 4. What stays the same

Steps, heart rate, and the Off check are unchanged. An empty IMU list is the same unknown path the engine already had when gravity was missing. It does not clear an off reading and it does not notify.

## 4. The phone’s activity-context cache, as a caption

### 1. The gap

The heart-rate page already decodes a local day document (posture, locomotion, arm, wear, sleep) and stores it under `OpenWhoop/ActivityContext`. The Watchdog card had no line for that label, so the live card could not show motion context the rest of the app had already computed.

### 2. How this improves the code

The person looking at Watchdog, including the card embedded on the Baseline screen, can see the label the heart-rate page already produced. The tick does not decode the day again, and the label cannot become a vote.

### 3. How the implementation works

After each tick, `activityContextNote` loads today’s file from `ActivityContextFileStore`. It tries the same source key the heart-rate page uses (`importedReadIds` joined by `+`), then each source id. It takes the run that contains `now`. When `displayContext` is present and is not `Unclear`, it sets `BaselineStore.activityContextNote`. The Watchdog card appends that sentence to its caption. A cache miss leaves the note empty and does not start a decode.

### 4. What stays the same

The sentence is not stored in `WatchdogCarry`, is not a feature column, and is not an input to `evaluate`. Severity, `shouldNotify`, green-band counts, and both Layer 1 centers are identical with or without the file. This document is not HART.

## Left out on purpose

| Signal | Why it stays out |
|---|---|
| Charge and hosted day scores | Mixing them into the 7-day copy, the 60-day copy, or Off would average the three engines. |
| Night `spo2_candidate_pct` | An unverified strap estimate. A raw SpO₂ sample may still be charted. The night average is not a usual and not a notify reason. |
| `v18AuxSample` and raw PPG waveforms | Banked for a later census. No validated feature for a green band or a Layer 1 series. |
| `@81` on-wrist bits | Not a second wrist detector. |
| Raw Data `user_confirmed` intervals | Sparse collector labels. They are ground truth for a future HART check, not a class for every minute. |
| Official TimesFM 3.0 or UniTS weights | The students already in the package stay the students. Those upstream weights are not shipped. |

## Later note: HART

HART is the worker checkpoint on uploaded 100 Hz windows. It runs only when `FRWHOOP_ACTIVITY_ENABLED=1`, and its held-out watch results are below the promotion bar, so the lane is shadow. The phone does not call it. The four sections above do not depend on it.

The same four-part shape, for when it is connected later:

1. **The gap.** Watchdog’s on-device class and HART’s 30-second epoch can disagree, and nothing on the card says which shadow label the worker published.
2. **How it would improve the code.** A shadow line, and a local disagreement row, would show chair-still versus HART `other_movement` without letting the checkpoint move a number.
3. **How that wiring would work.** Read an existing `activity_context` payload for the active strap. Show one line. If the labels disagree, append a debug row (minute, Watchdog class, HART label). Do not break the tie.
4. **What stays the same.** Until a WHOOP-labeled promotion (not WISDM) passes 0.85 macro-F1 and 0.90 precision on walking and running, HART does not change severity, `shouldNotify`, a green-band counter, `wakingImuEnergy`, or either Layer 1 center. After that, the only allowed use is the learning door the step class already has: walking can keep a minute out of still, and stationary can fill an unknown minute. It still cannot page, clear Off, or become a Layer 1 series.
