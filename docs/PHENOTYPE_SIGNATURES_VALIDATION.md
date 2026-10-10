# Phenotype signatures: validation on real WHOOP data

Companion to `docs/PHENOTYPE_SIGNATURES.md`. Everything below was measured on one real WHOOP 4 recording
(the owner's strap, 9.5 days, 2026-09-30 → 10-09, read from a checkpointed copy of the phone's `whoop.sqlite`)
with the engine in this branch. Only aggregate numbers are recorded here; the owner's data and the figures
drawn from it stay outside the repository.

**Verdict: signature learning is calibrated and usable for showing caregivers what changes around their
events. Retrospective detection is not reliable enough for alerts, and prediction must not start.**

## What data there was

- HR 1 Hz and R-R throughout; wrist gravity / posture / strap sleep state only from 10-05/10-06; no breathing
  rate on this strap; skin temperature throughout.
- **No real caregiver phenotype events exist yet.** Real labels available: 10 sleep onsets and 10 wake-ups
  (from sleep sessions), 9 DOUBLE_TAP markers, 12 guided activity labels, 8 stretch-feedback entries.
- So the evaluation has three parts: (1) nulls (pseudo-events at times with no event) for false signatures
  and false alerts; (2) positive controls: known effects planted onto the real recording at real times, to
  measure power and bias; (3) the real labels above. The external nurse-stress study used earlier only
  motivated the design; nothing here depends on it.

## Engine versions

| Version | Change that matters for validation |
|---|---|
| sig-1 | First engine: context baselines, matched controls by context at the onset minute, level family only, Gaussian expected recall, in-sample threshold certification. |
| sig-2 | Context from the pre-onset window; stricter control matching with widening; change-from-before family (rank test); fallback baselines; empirical recall; R-R `ord` order; `available_at` filtering; champion/challenger; emerging needs p < 0.05. |
| sig-3 | Out-of-fold, overdispersion-aware threshold certification; detectors abstain where the baseline has < 3 days; logistic observed-feature rules; `movement_accompanied` findings. |
| sig-4 | Joint multi-channel family (empirically weighted deviations); Layer 1 v2 context-strata baselines (`layer1`, `layer1+tod`). |

## 1. False signatures (nulls)

Random-time null: 1,200 sets of pseudo-events per normalisation mode (sig-3: 300 sets, context mode).
Walking nulls: pseudo-events placed during walks, one per day or uniformly over walking minutes (60 sets).

| Null | sig-1 | sig-2 | sig-3 |
|---|---|---|---|
| Random time: any finding shown | 2.2–2.9 % | 0.6–1.2 % | ≈ 1 % |
| Random time: emerging / established | 1.3–1.6 % / 0.8–1.5 % | 0.1–0.2 % / 0.5–1.1 % | 0.0 % / 1.0 % |
| Walking, one per day: established | 57–77 % | 23–27 % | 23 % (findings labelled with movement) |
| Walking, uniform: established | – | 22–27 % | 22 % (findings labelled with movement) |

- The random-time null is well calibrated: p < 0.05 in 1.6–2.1 % of all runs and 3.6–4.7 % of runs with
  ≥ 6 event days (nominal 5 %).
- **Activity-selected events remain a known false-signature mode.** An event type that systematically happens
  mid-walk gets "heart rate / steps rose from before onset", because the person keeps walking while comparable
  times do not. Matching controls on activity at the onset minute removed most of it (walking 7–8 %) but also
  removed real movement-accompanied responses (movement +20 bpm plant 33 % → 0 %). sig-3 therefore keeps the
  finding and says so: every HR/HRV finding on the walking nulls is marked `movement_accompanied` ("…, together
  with more movement"). 6–10 % of walking-null runs are established on step/motion findings alone, which are
  literally true (the person moved more).

## 2. False alerts (retrospective detection, held-out days)

Detectors are fitted and their threshold certified on days before a cutoff, then run on later days. Share of
runs whose certified ≤ 1/day threshold produced more than 1 false alert per held-out day (mean false
alerts/day in brackets), context mode:

| Null | logistic | hr_rule_raw | hr_rule_context | template |
|---|---|---|---|---|
| Random time, sig-1 | 37 % (0.98) | 1 % | 41 % (0.89) | 13 % |
| Random time, sig-2 | 51 % (1.32) | 1 % (0.59) | 29 % (0.78) | 7 % (0.37) |
| Random time, **sig-3** | **10 % (0.30)** | 0 % (0.40) | **3 % (0.14)** | 9 % (0.33) |
| Walking, one per day, sig-2 → **sig-3** | 83 % (2.03) → **26 % (0.59)** | 0 % → 0 % | 31 % → **0 %** | 0 % → 0 % |
| Walking, uniform, sig-2 → **sig-3** | 60 % (1.54) → **14 % (0.45)** | 7 % → 0 % | 50 % → **0 %** | 7 % → 4 % |

What it took: certifying on out-of-fold scores (each fold scored by models refitted without its days); a
quasi-Poisson bound, because false alerts cluster on walking-heavy days; abstaining where the HR baseline has
fewer than 3 days behind it (on this recording posture contexts start only on 10-05, so later days met
contexts certification never saw); and logistic rules on observed features.

## 3. Positive controls (planted effects, ±5 min onset uncertainty unless stated, 30 runs each)

Share of runs reaching `established`:

| Plant | raw | context | context+response |
|---|---|---|---|
| Awake, still: HR +25 bpm × U(0.5, 1.5), 10 min | 33 % | 33 % | 30 % |
| Asleep: HR +25 bpm | 63 % | 57 % | 57 % |
| HR +20 bpm with a movement burst | 63 % | 33 % (sig-1: 7 %) | 43 % (sig-1: 7 %) |
| HR +30 bpm with a movement burst | 73 % | 70 % (sig-1: 30 %) | 63 % (sig-1: 17 %) |
| HR +30 bpm with sensor-only movement | 67 % | 53 % | 47 % |

- **Activity-aware normalisation did suppress real signals in sig-1** (movement +20: raw 27 %, context 7 %):
  the context baseline expects a higher HR while moving and absorbs part of an event that makes the person
  move. The change-from-before family fixes this (HR change bias −0.7 to −2.8 bpm, CI coverage 0.85–0.98 in
  every mode). The "vs usual for the activity" level finding is still biased low under context modes
  (−6 to −8 bpm, coverage 0.50–0.67), and is labelled as such.
- Time to `established`: median 8–10 events on 8–10 different days.
- **Onset uncertainty is the largest power cost.** At ±15 min: asleep +25 falls to 13–23 %, movement +30 to
  23–40 %. Exact onsets matter more than any modelling choice.
- Wrong-channel findings (mostly temperature or breathing rate "vs usual") appear in 0–17 % of positive runs.
- With the significance gate at p < 0.05 and ≥ 6 event days required, a 25 bpm effect is established in
  about a third (awake) to a half (asleep) of runs of ~10 events. Smaller effects were not reliably found
  (planted +12 bpm on 8 events: p = 0.09, no reliable signature).

## 4. Detection performance at ≤ 1 false alert/day (held-out events)

| Plant | logistic sig-2 | logistic sig-3 | hr_rule_context sig-3 | template sig-3 |
|---|---|---|---|---|
| Awake +25 | 0.16 at 1.06/day | 0.04 [0.02–0.07] at 0.18/day | 0.04 [0.02–0.08] at 0.24/day | 0.01 |
| Movement +20 | 0.34 at 1.93/day | 0.12 [0.09–0.16] at 0.17/day | 0.00 | 0.00 |
| Movement +30 | 0.33 at 1.61/day | 0.06 [0.03–0.09] at 0.11/day | 0.00 | 0.01 |

- sig-2's apparent recall was bought by exceeding the false-alert budget. With honestly certified thresholds,
  recall for 25–30 bpm planted effects is 4–12 % on this recording; latency medians were 1.5–9.5 min.
- The simple HR rule in context z (hr_rule_context) matched or beat the logistic model for still and sleep
  events; the logistic model helped only for movement-accompanied events. Raw HR thresholds mostly fire on
  walks (on the walking nulls they "detect" 28–34 % of pseudo-events), which is what context normalisation
  removes.
- Expected recall (empirical, in reports) was roughly calibrated where the budget was met (mean |error| 0.05)
  but off by up to 0.16 in individual settings; reports carry its Wilson CI.

## 5. Real labels (sig-3, context mode)

| Type | Used / logged | Status | What the engine says |
|---|---|---|---|
| Wake-up | 10 / 10 (10 days) | established, p = 0.016, replicated | "Heart rate rose 10 bpm (7–14) from before onset, 5–15 min after onset, in 9 of 9 events, together with more movement." "Heart rate rose 7 bpm (4–10) … within 5 min after onset, in 9 of 9 events." Skin temperature 0.8 °C below usual after waking. |
| Sleep onset | 8 / 10 (2 had < 3 controls) | no reliable signature (p = 0.61); raw mode: established on "HR 22 bpm below usual … together with less movement" | The event-aligned HR falls ~10 bpm over 20 min, but the matched controls (context `unknown` before posture data existed: in bed and at a desk look the same) run 15–20 bpm higher already before onset, and the rank test cannot separate them. |
| DOUBLE_TAP | 8 / 9 (3 days) | individual context | not testable before 6 event days |
| Guided labels | 12 / 12 (2 days) | individual context | — |
| Stretch feedback | 8 / 8 (3 days) | individual context | — |

Wake-up is the one real event type with ≥ 6 days, and its signature matches physiology (HR rises on
waking, with movement). No real event type reached `promising` detectability (d 0.3–1.3); retrospective
detection caught 0 of 7 held-out wake-ups and 1 of 7 sleep onsets (template) at 0.27–0.54 false alerts/day.

## 6. sig-4: weighting channels together, and the app's own baselines

Joint family, context mode, ±5 min, same harness (planted amplitudes × U(0.5, 1.5), 20 % non-responders; 90 runs
per plant, 600 random-time and 60 + 60 walking null sets). "Established" share without → with the joint family:

| Set | Without | With |
|---|---|---|
| Random-time null | 1.2 % (p < 0.05 with ≥ 6 days: 3.1 %) | 1.3 % (4.6 %) |
| Walking null, one per day / uniform | 23.3 % / 21.7 % | 25.0 % / 21.7 % |
| Tremor-like: HR +12 bpm with a wrist-motion burst, no steps | 22.2 % | 28.9 % |
| Tremor-like at HR +8 bpm | 11.1 % | 16.7 % |
| HRV −0.3 ln with HR +10 bpm | 7.8 % | 16.7 % |
| HR only +25 / +15 | 55.6 % / 37.8 % | 67.8 % / 54.4 % |
| HR with movement +20 / +30 | 43.3 % / 50.0 % | 52.2 % / 60.0 % |

Weighting channels by how far each deviates (in SD of the person's normal variation) raised power for every
plant, most for multi-channel events, and kept the random-time null within limits. Accelerometer data exist only
on the last 3 days of this recording, so the tremor plant's motion component was visible on about a third of
events; its gain is a lower bound. The joint family is on by default.

Layer 1 baselines: the port reproduces the app's `ContextMaterializer` + `evaluate` + `WatchdogExpectation`
exactly (866 values, 1e-9 relative, recorded from the Swift). On this recording it changes nothing yet: the
reference window is T-60…T-8 and needs 4 days to be provisional and 14 to be established; sleep HR becomes
provisional around 10-11 and awake rest around 10-16, nothing is established before about 10-21. The posture
strata of the materializer on this branch (`lb-context-1`) stay empty with the current decoder (a still bout
restarts on every unknown-posture interval); `lb-context-2` on the context-watchdog branch fixes that and the port
must be re-recorded against it when the branches meet. On the server the inputs (per-interval HR, R-R
components, posture confidence) are not uploaded, so `layer1` falls back to the engine's context baseline there
and says so. The benefit of Layer 1 normalisation over the engine's own baseline is therefore not yet measured.

## 7. Evidence required before real-time detection

1. Real caregiver events: ≥ 10–12 per event type on ≥ 8 different days, onset uncertainty ≤ 5 min,
   and a signature that is `established` (p < 0.05 and replicated on later events).
2. Detectability: lower 95 % bound of d ≥ 2 (`promising`), and forward held-out recall with Wilson lower
   bound ≥ 0.5 at ≤ 1 false alert/day — not reached by any planted or real event here.
3. False-alert certification on ≥ 14 monitored days containing every context the detector will run in
   (≥ 3.7 alert-free days are needed just to show ≤ 1/day; 18 for ≤ 0.2/day), ideally with caregiver
   observation periods and reviewed detections as negative time.
4. Posture and accelerometer data for the whole baseline period (on this recording they start 10-05).
5. A prospective silent period: detections reviewed by caregivers, not sent, with promotion only via the
   champion/challenger rule on future-held-out events.

Prediction (before onset) needs all of the above plus precursor evidence beyond onset uncertainty and a
comparison with time-of-day and time-since-last-event baselines.

## Reproducing

The harness lives outside the repository (it reads owner data). Re-create it from these steps: build the
timeline with `personal_events.timeline.load_whoop_sqlite`; draw pseudo-events from worn minutes ≥ 2 h from
labels (random-time null) or from walking minutes (walking nulls); plant effects with
`personal_events.inject.plant`; run `personal_events.engine.run(..., forward_eval=True)` in each normalisation
mode and read `report`, `forward`. The CLI does the same for one type:
`nara-signatures --sqlite whoop.sqlite --device my-whoop --tz-offset-s -25200 --inject n=8,hr=12,dur=10,unc=5,seed=1
--type-id planted-hr --out report.json`.
