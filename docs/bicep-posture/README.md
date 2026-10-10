# Sitting vs standing on an upper-arm strap (decoder hsmm-2.0)

Branch `feat/bicep-posture-20261009`, built on the context-watchdog lead branch (fb67c1e33). Nothing is deployed or
installed.

## The failure

On 2026-10-09 the owner sat from about 16:50 to 18:25. Production labelled about 75 minutes of it "Standing quietly"
or "Standing, hands busy".

- **The strap is on the bicep.** `placement_intervals` records this, but no activity decoder read it.
- **Every posture cue assumed a wrist:**
  - the forearm-axis "hanging arm leans standing" rule;
  - the hand-pattern rows ("desk-like ⇒ seated");
  - "standing up lowers the hand";
  - HART's fine sit/stand rows, trained on WISDM wrist data.
- **On the upper arm the humerus hangs in both postures.** The owner's held orientation sat 10–19° from their own
  standing calibration and 22–42° from their sitting one.
- **Calibration had no effect.** The owner did one run (calibration-v2, 2026-10-06), the profile fitter needs held-out
  runs, and its status was `needs_more_runs`. Nothing told the owner.

## The five changes

### 1. Placement-aware decoding (`ActivityWearPlacement.swift`)

`ActivityDecoderConfig.placements` holds the declared spans. Off the wrist (`bicep` / `other`), these cues lose their
seated-vs-upright difference and their stand-up-vs-sit-down difference:
- the wrist-geometry cues: held-orientation sit/stand, shift direction, hand pattern;
- the wrist-trained heads: HART fine rows, the transition expert's direction, the Inertia posture head.

Everything else they say still counts: still vs moving, lying vs not, a transition vs none. A wearer's own adopted
orientation rows still speak.

Placement sources:
- **Phone:** `ActivityPlacementCache` (from `PlacementStore`).
- **Worker:** `ActivityContextDays.loadDecoderReference`, via the placement resolver, with recipe `srv-cfg-2`.

A wrist or undeclared day keeps its cache tag and decodes exactly as before.

### 2. Still-duration prior (`ActivityStillPosture.swift`)

People rarely stand still for long. In Capture-24 (151 free-living participants; see
`_build-scratch/bicep-posture/A-duration/REPORT.md`), the log-odds of sitting within an uninterrupted still stretch
rise over the first minute's as follows.

| Time still | Extra log-odds, V1 (main) | Extra log-odds, V2 (chores count as standing) |
|---|---|---|
| 5 min | +0.75 | +0.44 |
| 10 min | +1.56 | +0.92 |
| 30 min | +2.48 | +1.64 |

Bouts:
- **Standing:** median 2.3 min; 6.8 % last longer than 10 min.
- **Sitting:** median 9.5 min.

How the decoder uses it:
- **Curve.** It adds the midpoint of V1 and V2, capped at ln 8. It never adds the base rate, so the first minute stays
  even.
- **Commit point.** A stillness alone commits a hedged "Sitting" after about 5 minutes. Class confidence stays under
  the wrist-only cap (0.75).
- **What ends a stretch:**
  - sustained stepping (at least 6 stepping seconds in 10 s);
  - a moving mode;
  - a decoded transition;
  - a posture shift that leaves the strap somewhere new;
  - the night;
  - a gap of more than 20 s.
- **What does not end a stretch:** reaching, fidgeting, a 1–3 s walk-class blip. Bursts came every few minutes in the
  owner's seated afternoon.
- **Gravity.** The prior speaks only with a gravity direction.
- **Lying.** It steps back as far as the held orientation leans recumbent: duration does not tell lying from sitting.
- **Switch-off.** `ActivityDecoderConfig.stillDurationPrior = false` turns it off. On the phone this is Activity
  calibration → "I often stand still for long stretches", for standing-desk or standing-job wearers.
- **Known error mode.** A long, step-free stand with no measured stand-up reads as sitting after a few minutes.

### 3. Personal heart rate by posture (`ActivityPostureHeartRate.swift`)

The PAMAP2 evidence (`_build-scratch/bicep-posture/C-hr/REPORT.md`):
- Within one session, standing runs +10.5 bpm over sitting.
- Across sessions, the same seated posture drifts 5.6 bpm RMS.
- Post-exercise sitting reads as "standing" for at least 5 minutes.

So the model:
- **Is personal only.** It is fitted from the wearer's labelled stretches (guided holds, confirmations, stretch
  verdicts). It is adopted only with a gap of at least 8 bpm and a held-out AUC of at least 0.75 over at least 2 runs.
  Until then nothing stands in for it.
- **Uses settled seconds only:** at least 3 min still, at least 15 min since exertion, |trend| ≤ 1 bpm/min, and a rate
  not above the standing level + gap/2.
- **Is relative to the resting reference.**
- **Is bounded at ln 1.5,** below every commit bar, so heart rate alone never makes a sitting or standing claim.

The owner's own calibration shows about +6 bpm, so for them heart rate stays posture-neutral for now.

### 4. Measured stand-ups and sit-downs (`ActivityVerticalShift.swift`)

Standing up lifts the shoulder about 0.3–0.5 m. The detector works on raw 100 Hz accelerometer + gyro, averaged to
50 Hz:
1. Gyro-aided gravity, forward and backward.
2. Movement segments bounded by stillness, plus walk onsets and offsets.
3. Double integration of a·ĝ − 1 g with zero mean velocity in the 1 s pads either side.
4. Accept only when |Δh| ≥ 0.20 m and the peak vertical velocity has the same sign and is at least 0.25 m/s.

It is a port of `_build-scratch/bicep-posture/B-upperarm/vdisp_ref.py`.

**Validated on the owner's own bicep strap** (raw IMU downloaded read-only;
`Tools/CloudWorker/Tests/frwhoop-workerTests/VerticalShiftRawReplayTests.swift`, opt-in via `NARA_RAW_IMU_DIR`).

2026-10-06 guided calibration:

| Labelled | Measured | Δh |
|---|---|---|
| sit→stand 21:08:22 | 21:08:19 | +0.335 m |
| stand→sit 21:09:56 | 21:09:53 | −0.233 m |
| sit→stand 21:10:15 | 21:10:16 | +0.369 m |

All three changes are found in the right direction, with no false shift in the session.

2026-10-09 16:36–18:36:
- sit-down at 16:52:20 (−0.25 m);
- brief stand and sit at 17:57:47 / 17:57:53 (+0.25 / −0.25 m), which the step counter corroborates;
- no false shift in 90 seated minutes.

How the decoder uses a shift:
- **Anchor.** A shift anchors the posture it ended in: ln 4 seated after a drop, ln 3 standing after a rise.
- **How long it holds.** The anchor lasts until the wearer moves on: sustained stepping, a moving mode, the night, or
  a new shift.
- **Fading.** While an anchor holds, the duration prior reads the anchor's age. A stand claim therefore fades over
  about 10 minutes, the way standing bouts do.

Plumbing:
- **Worker.** The raw-IMU lane runs the detector (`ActivityLane.verticalShifts`) and passes shifts to the decode.
- **Storage.** It stores the shifts in `activity_encoder_windows` as an additive `v_*` block (`vertical-shift-1`).
- **Readers.** The phone and the stream days read the shifts back.

**Cross-person check** (Opportunity upper-arm IMUs, 4 people; `B-upperarm/REPORT.md`):
- With gyro-aided gravity, direction is right 98 % / 96 % of labelled transitions.
- Accelerometer-only causal filters are near chance, so the gyro is essential.
- Every still-bounded burst gets the right direction, but only 39–54 % of kitchen transitions are still-bounded, so
  recall is partial.
- Bends and squats to low drawers (−0.7 to −0.9 m) are rejected by an upper bound of 0.70 m.
- A free-running detector there needs |Δh| ≥ 0.35 m (precision ~0.6). The owner's own bicep events measured
  0.23–0.37 m, hence the 0.20 m floor on still-bounded movements only.

**Coverage limit.** Raw IMU is captured part-time by default (60 s in every 180 s), so about two thirds of posture
changes fall outside a capture window. The calibration screen forces continuous capture; Power saving → IMU capture
offers continuous capture at a battery cost.

### 5. Calibration that tells the truth (`ActivityGroundTruth.swift` calibration-v5, `ActivityCalibrationView`)

- **Hold length.** Holds are 75 s, so heart rate settles. Lying holds are 40 s.
- **New pose.** The second sit/stand repetition is "arms down": seated with the arms hanging, the pose an upper arm
  confuses with standing.
- **Runs.** Two runs personalise (v3/v4 needed three).
- **Status in plain words.** The day view's entry says "Not in use yet: 1 of 2 runs done…", and the calibration
  screen shows the heart-rate model's state.

## Calibration per placement, and what a switch switches

Everything placement-sensitive is calibrated per placement (`ActivityWearPlacement.calibrationKey`: wrist / bicep /
other, undeclared reads as wrist) and switches with Settings → Wear placement.

| What | Wrist | Bicep | Where |
|---|---|---|---|
| Sit / stand posture cues | forearm orientation, hand pattern, HART fine rows, shift direction | off (still / moving / lying kept) | `ActivityWearPlacement`, `ActivityContextModel.score` |
| Personal activity profile, heart-rate-by-posture model | fitted on wrist runs only | fitted on bicep runs only | `ActivityDecoderConfig.placementProfiles` / `placementPostureHeartRate`, phone refit groups runs and labels by the placement stamped on each label |
| Measured stand-up / sit-down (vshift-2) | peak velocity ≥ 0.5 m/s; anchors +1.5 / −0.7 × quality | ≥ 0.25 m/s; anchors ln 5 / ln 3 | `ActivityStillPosture.anchorLean(_:placement:)` |
| Still-duration prior | same (behavioural) | same | `ActivityStillPosture` |
| Skin-temperature baseline | own fold | own fold; switching back resumes the other | `ChargeBaselines.skinPlacementByDay` (phone), `DayScorer.foldBaselines(skinPlacementByDay:)` (server) |
| Step-estimate coefficient (WHOOP 4.0) | own fit | own fit | `IntelligenceEngine` steps block |
| Watchdog skin temperature / IMU | used | not used (unchanged rule); account-level placement now read | `WatchdogService` |
| Physiology-context references | own regime | own regime | already placement-keyed (`PCSignalValidity`) |
| Coach context | told the placement and the last switch | | `CoachTurnContext.placement` |

### Wrist calibration of the stand-up detector (D-wrist-shift)

Opportunity lower-arm vs upper-arm IMUs (4 subjects, 265 labelled transitions per sensor).

| Sensor | Rule | Direction correct | Precision | Recall | False events per sit/stand hour |
|---|---|---|---|---|---|
| Non-dominant wrist | shipped (vshift-1) | 0.91 | 0.56 | 0.46 | 12.4 |
| Non-dominant wrist | vshift-2 wrist rule | 1.00 | 0.86 | 0.30 | 1.35 |
| Dominant wrist | either | 0.29–0.75 | — | — | — |
| Upper arm (pooled) | vshift-1 → vshift-2 rule | — | 0.42 → 0.90 | — | — |

- On the dominant wrist, direction is unreliable: reaching flips the sign.
- What failed was the "offset" candidates (the end of a long movement), at 0.02–0.63 direction accuracy. vshift-2
  drops them.
- An uncalibrated accelerometer costs most on the wrist, so vshift-2 fits offset and gain from still windows.
- The owner's own bicep data under vshift-2: all 3 calibration changes and the 16:52 sit-down are still found. The
  17:57 brief stand's rise was an offset candidate and is dropped; its sit-down is kept.

### Wrist sit/stand before vs after (E-wrist-decoder, Capture-24)

80 participants, 510 h of labelled sitting/standing; wrist streams (gravity + dynamic acceleration, no HR, steps or
gyro).

| Wrist decoder | Sitting recall | Sitting precision | Standing read as Sitting | Standing recall |
|---|---|---|---|---|
| hsmm-1.9 | 0.079 | 0.917 | 0.076 | 0 |
| hsmm-2.0 | 0.194 | 0.951 | 0.106 | 0 |

- **What changed.** hsmm-2.0 with the duration prior off is byte-identical to hsmm-1.9, so on a wrist the prior is
  the whole change.
- **What it costs.**
  - About 98 % of the added Sitting claims are right: +53 h correct against +1.3 h of standing called sitting.
  - 79 of 80 participants gain sitting recall.
  - 4 people who stand a lot lose more than 2 points of precision. The "I often stand still for long stretches"
    switch is their remedy.
- **Fitted on the same people?** Refitting the knots on even IDs and testing on odd IDs lands within 0.007 of the
  shipped table, so the in-sample effect is negligible.
- **Tuning.** Weakening the prior (×0.5) gives up 7–8 points of recall to save about 2. Strengthening it (×1.5, or
  steeper knots) adds sitting at near base-rate precision, at the cost of people who stand a lot. The wrist curve is
  therefore kept as is.
- **Open gaps on the wrist.**
  - It never publishes "Standing".
  - 62 % of sitting stays unresolved.
  - Still stretches break at arm shifts.

### Logging

**Phone.** `PlacementSwitchLog` keeps an append-only JSONL file in Application Support.
- **"Declared" entry:** from → to, effective start, revision, calibration before, decoder tag before.
- **"Recalculated" entry:** what switched, calibration before → after, decoder tag before → after.
- Each entry is also written to the strap log, which goes out with the Test Centre export.
- Settings → Wear placement lists the recent switches.
- Placement sync failures are now logged instead of dropped.

**Server.** `public.placement_change_events` (migration `20261010090000`) is append-only, enforced by a trigger.
- **Each row records:** op, placement, previous placement, effective span, revision, source, first re-derived day,
  activity jobs re-queued, straps touched, and any invalidation error.
- **What the trigger does on a change:** it re-queues activity-context jobs as well as the physiology-context and
  measurement-context days.
- **Rehearsal:** on production's schema dump, all 15 migrations apply. The smoke test shows a switch logged, the
  recent activity day re-queued (old one untouched), the correction logged with its previous placement, and an update
  rejected.

### Not switched (documented, not changed here)

- Sleep staging and motion-based sleep/wake (wrist-tuned stillness thresholds).
- HRV, resting heart rate and respiration daily baselines: physiology does not depend on site; optical quality does,
  and physiology context already splits by placement.
- ElderNet / Inertia / RecGym and the energy models' motion evidence: shadow or not production evidence today.
- ParaDigMa tremor gating: the inference worker's host source differs from git.
- Longitudinal (Layer-1) baseline tapes.
- The scoring attestation's `placement` slot.

## Replay of the owner's afternoon

`ActivityBicepReplayTests`, opt-in via `NARA_BICEP_REPLAY_DIR`. Covers 16:52:30–18:20, seated, with the three
measured shifts.

| Decoder | Standing | Sitting | Unresolved |
|---|---|---|---|
| production (hsmm-1.9, wrist reading) | ~75 min (from `activity_context_runs`) | — | — |
| hsmm-2.0, bicep | 0 | 72 min (38 desk sitting + 28 sitting + 6 seated fidgeting) | 16 min |

## Deploy notes (not done)

1. **Worker.** Release a worker with hsmm-2.0, `srv-cfg-2` and `versionsOrdinal` 3. This re-queues stored days.
2. **Placement resolver.** It needs migration `20261009150100_placement_device_resolution.sql`, which is pending on
   this line. Without it the worker falls back to device-scoped rows. The owner's placement is stored under
   installation ids, so the server would read "wrist" until the resolver is applied.
3. **Phone.** The phone build carries the placement cache, the standing-habit switch, calibration-v5 and the
   heart-rate fit.
4. **Database.** No new migration: the `v_*` block rides the existing `activity_encoder_windows` JSON.
