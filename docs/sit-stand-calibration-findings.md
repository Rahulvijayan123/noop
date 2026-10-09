# Sitting vs standing on a wrist strap: can calibration and labels make it work?

Measured on 2026-10-08. Scripts, per-subject results and cached features are in
`/Volumes/Untitled/Nara Whoop App V2/_acx-scratch/sitstand/` (`scripts/`, `results/`). Run them with
`_acx-scratch/venv-ac/bin/python -I`. Nothing here is shipped yet. This document records evidence and options.

## Question

Users would do a guided calibration: sit, stand up, sit back down on cue. Some would also confirm or label real
events. Can the strap then tell sitting from standing reliably in everyday life?

## Short answer

**Not reliably from the wrist alone, even with calibration.** Calibration plus a few user confirmations can do two
things:
- move about half of users to roughly 0.8 balanced accuracy;
- tell us *which* users those are.

Even for those users, "standing" claims are right only about half the time. Standing is rare (median 10 % of still
time), and a held forearm looks the same either way.

The reliable product is therefore a verified, per-user "likely" label plus a growing labelled dataset. It is not a
sit/stand fact for everyone.

## What exists today (code)

- **Guided session** `calibration-v3` (`ActivityGroundTruth.swift:547-694`, `Strand/Collect/ActivityCalibrationSession.swift`).
  - It covers 2× sit/stand holds of 30 s, four cued sit↔stand moves, and lie-down / get-up steps.
  - It forces continuous raw IMU and stores `guided` labels in `activity_ground_truth_labels`.
- **Fitting.** The labels fit `personal-profile-3`, which shrinks HSMM observation profiles, validates
  leave-one-run-out, and applies the per-class guards.
- **Labelling.** "Help improve activity detection" asks up to 5 episode questions a day, and stretch verdicts are stored.
- **Missing pieces:**
  - no dedicated sit-vs-stand model;
  - no per-user switch that turns sit/stand claims on;
  - no in-the-moment "are you sitting or standing?" prompt, and no notification actions;
  - the buzz time is stored as the transition time, not the measured movement;
  - the local label file is not scoped by account or strap, and is pruned at 120 days, which silently drops old
    calibration runs from the fit;
  - no server-side consumer of labels.

## Measurements

Sources:
- **FORTH:** 15 subjects, scripted lab.
- **Capture-24:** 133 subjects, about one free-living day each, camera-labelled.
- **PAMAP2:** 8 subjects, chest HR.

Signals:
- **Strap "streams":** per-second gravity and dynamic acceleration.
- **Raw IMU:** simulated at the strap's 1-minute-in-3 duty cycle.

| Finding | Number |
| --- | --- |
| Lab (FORTH): orientation separates sit/stand for nearly everyone, even with no personal data | balanced accuracy (bacc) median 1.0 |
| Free living (Capture-24), population model, orientation / streams / + raw | bacc 0.60 / 0.68 / 0.72; standing precision 0.24–0.28 |
| Free living, personal model from a protocol-like 2 min sample | 0.68 (orientation; +0.01–0.06 over population); streams −0.025 |
| Personal ceiling (all of the first half of the day as labels) | 0.73 [IQR 0.58–0.83]; 33 % of users ≥ 0.8; standing precision 0.32 |
| Same model fitted on the test half itself (in-sample) | 0.88–0.93. The gap is day-to-day drift in how people hold their arm, not label count |
| Label budget (confirmed events per posture) | plateau about 0.72–0.76 after 3–5 events; orientation is the only feature worth personalising |
| Cued "sit still / stand still" sway features | anti-predictive in free living. Do not personalise micro-motion from cued data |
| Raw IMU over streams for this task | +0.006 (population), +0.000 (personal). Extra raw capture is not justified |
| Calibration-internal accuracy as a gate | useless: rank correlation 0.05–0.26 with free-living accuracy |
| **Verification gate**: enable if ≥ 6 of the last 8 user-confirmed bouts (4 sitting + 4 standing) are right | **55 % of users enabled; median bacc 0.79; standing precision 0.47** (not enabled: 0.52; rank correlation 0.60) |
| Strict gate: 8 of 8 | 11 % enabled; standing precision about 0.54 |
| Standing precision ≥ 0.8 | reached by no threshold for more than about 5–7 % of users |
| Transition anchoring (posture = direction of the last sit↔stand event) | lab bacc 0.92–1.0; **free living: chance (0.52)** |
| False posture events per stable hour, free living | 22.5 for the current decoder, 47 for a template detector; personal templates do not help |
| "Walk ends, so standing" | wrong more often than right: 44 % of post-walk bouts are standing |
| Heart rate, standing − sitting (PAMAP2) | +8.5 bpm median, positive for every subject |
| What heart rate adds on top of orientation (population, lab) | +0.02 bacc. Its free-living value is unmeasured: no free-living dataset has both heart rate and posture labels |

Limitations:
- No dataset has a cued session and free living for the same person.
- Capture-24 uses a different device and frame from WHOOP, the dominant wrist, and ±20 s camera labels.
- Stream features are proxies derived from raw data.

## What would actually make it work

1. **Verification-gated personal model.** This is the best wrist-only option.
   - *Calibration:* about 3 min of natural sitting and standing, with hands busy and not held artificially still,
     2 × 30 s each.
   - *Model:* personal orientation-only logistic regression, shrunk toward the population model (λ ≈ 0.3), with
     still-segment smoothing.
   - *Confirmations:* in-the-moment prompts ("Right now: sitting / standing / neither?"), 3–5 per posture.
   - *Gate:* show "Likely sitting / Likely standing" only while at least 6 of the last 8 confirmations agree. Keep
     sampling occasionally, so the gate can switch off when arm habits drift.
   - *Expected:* about 55 % coverage and about 0.8 bacc. Standing stays a "likely", never a fact.
2. **Collect the dataset that is missing.** The same confirmations are labelled WHOOP free-living data with heart
   rate. That is exactly what is needed to:
   - measure the orthostatic heart-rate signal (+8 bpm) in free living;
   - train a better population model in the WHOOP frame.

   Any model trained this way still has to pass the "no stand-in models" rule before it ships.
3. **A second sensor location.** A thigh or pocket sensor separates sit from stand almost perfectly. activPAL-style
   devices are the research gold standard. The phone in a trouser pocket could give thigh angle, but iOS background
   motion access is limited and phones are often not in a pocket. This would need a feasibility spike.

## What not to build

- A transition-anchored posture tracker.
- The "walk end ⇒ standing" rule.
- Calibration accuracy as the gate.
- Personalised sway or micro-motion features.
- More raw IMU capture for this purpose.
