# Phenotype signatures

Learn each patient's physiological signature for a caregiver-logged event type, from few labelled events,
and say honestly how reliable it is. Understanding comes first, then retrospective detection. Real-time alerts
and prediction are **not enabled** in this phase.

## Why this design (evidence)

- PR #5's 25 × 18 model grid over 32-s windows of raw HR + temperature overfits its selection on few events,
  and its gates never promote a model. Fixed simple models beat the search. Neural heads saw 2 time steps.
- At ≤ 1 false alert per day the expected event recall is set by the signal-to-noise **d** (how many SD of the
  patient's normal, same-context variation the event moves the signal). The model class matters far less than d.
  A Gaussian "100 independent decisions per day" formula (d = 2 → 37 %) was 2–3× optimistic on real WHOOP
  data, so reports estimate recall empirically from day-fold scores (§6).
- Events on the same day share that day's state; significance must be tested with day-level clusters
  (event-level tests were wrong up to 17 % of the time). Fewer than ~6 distinct days → no significance.
- Window F1 rewards over-alerting; it is not used to choose anything.

## What is reused, replaced, new

| Component | Decision |
|---|---|
| Event log (`manual_event_revisions`), per-event context, ground-truth projection | reused |
| PR #5 SQL (settings, jobs with leases/fencing, detections, reviews, negative intervals, inputs/state), routes, review UI, worker lanes, `EpisodeState` hysteresis, label-availability gating | reused |
| PR #5 modelling core (`data.py` windows, `features.py`, `models.py` 25 × 18 registry, `neural.py`, `frozen.py`, `sparse_group.py`, `training.py` argmax selection and gates) | replaced by the signature engine below |
| Inference lane publishing detections | disabled in this phase (no alerts); retrospective detection runs inside the evaluation |
| 1-minute timeline (built like the anomaly service's `features.load`), context baseline, event-locked profiles, matched controls, signature statistics, detectability, forward evaluation, observation periods, onset uncertainty | new |

## Engine (`Tools/PersonalEventDetection/personal_events/`)

Pure numpy/scipy (+ scikit-learn for the logistic model). Every step is causal: anything used to score or
test time *t* is fitted only on data and labels available before the evaluation cutoff.

### 1. Timeline (`timeline.py`)

One row per wall-clock minute of one device. Loaders: `load_postgres(db, owner, device, lo, hi, tz)` and
`load_whoop_sqlite(path, device, lo, hi, tz)` return the same `Timeline` (numpy arrays, NaN = missing, never 0).

| Column | Source | Rule |
|---|---|---|
| `hr`, `hr_max`, `hr_min`, `hr_n` | HR samples (1 Hz) | mean/max/min of 25–250 bpm; NaN if < 30 s present |
| `ln_rmssd` | R-R intervals | trailing 2-min window ending at the minute; Malik 20 % filter; ≥ 30 successive pairs; **only where `motion_ok`** (else NaN, flagged `motion_artifact`) |
| `motion`, `motion_p90` | gravity `dynAccel` (g) | mean / p90 per minute |
| `steps` | step counter | per-minute delta (counter wraps handled) |
| `temp` | skin temperature | °C when calibrated, else strap raw / 100; then detrended against its own trailing 6-h median (`temp_detr`) |
| `resp` | server `resp_rate_bpm` (Postgres) or activity-interval `respRateBpm` (phone) | where present |
| `asleep` | strap sleep state, sleep sessions/nights | 0/1/NaN |
| `activity`, `activity_conf`, `posture` | activity runs (server) / intervals (phone) | class at the minute's midpoint |
| `wear` | wrist events, HR presence, activity wear state | bool |
| `local_hour` | `tz` | 0–24 |

### 2. Context (`context.py`)

Per minute: `asleep`, `still_supine`, `still_seated`, `still_upright`, `still_unknown`, `walking`, `active`,
`recovery` (≤ 10 min after walking, ≤ 30 min after active), `off`, `unknown`. Plus `minutes_since_exertion`
and four time-of-day bands (00–06, 06–12, 12–18, 18–24).

### 3. Expected value and deviation (`baseline.py`)

`Normalizer(mode)` with modes compared in evaluation:

- `raw`: global robust median/MAD per channel.
- `context`: median/MAD per (context × time band), shrunk toward the context's pooled value and then the
  global value with weight n/(n+k), k = 60 minutes; scale floors (HR 1 bpm, ln-RMSSD 0.05, temp 0.05 °C,
  resp 0.3, motion 0.005 g).
- `context+response`: `context` plus, for HR, a ridge model of HR on recent movement (motion and steps lagged
  0–10 min, exponentially-weighted recent motion with τ = 3 and 10 min, minutes since exertion). Used only
  if it improves out-of-sample HR fit on the fitting data; otherwise falls back to `context`.

A context with too few fitting minutes borrows its parent's baseline (active → walking → awake pooled; still
contexts → still pooled → awake); this is flagged in `data_quality.notes`.

`fit(timeline, mask)` uses only minutes that are worn, not near any logged event (± 2 h), and before the
cutoff. `transform` returns `z[channel]` and the expected value in physical units (`expected[channel]`), so
findings can be reported in bpm, ms, °C, breaths/min. No baseline → NaN (abstain; no stand-in).

### 4. Event-locked profiles and matched controls (`profiles.py`)

- Profile: z of every channel at lags −30…+30 min around the onset (61 values per channel), with validity.
- Onset uncertainty: from the entry's `onsetUncertaintyMinutes` (0, 5, 15, 60; default 5). With ≥ 4 events,
  each onset is re-aligned within ± its uncertainty to the leave-one-out mean HR profile (bounded, recorded).
- Event context: the dominant context of [onset − u − 15, onset − u), not the logged minute (the event itself
  may change the context at the logged time).
- Matched controls (per event, up to 8): same patient; same dominant pre-window context with share
  ≥ max(0.7, event share − 0.1) and the same context group in the window's last minute; local time within
  ± 60 min, widened to 120 and then 240 min while fewer than 3 are found; a different local day; ≥ 2 h from any
  logged event / positive review / unreviewed detection; worn; HR coverage ≥ 70 %. Observation periods and
  reviewed negative intervals are used first, then a uniform random sample of candidate minutes (spacing
  rules over-sampled walks about to end and biased the null). Events with < 3 controls are dropped and
  counted in `evidence.events_dropped`.
- Controls are re-aligned the same way as their event, which costs some power but keeps the test valid.
- Level family: `D[event, channel, window] = event mean − mean over its controls`, windows
  [−30,−15), [−15,−5), [−5,0), [0,5), [5,15), [15,30] ("vs what is usual for the activity and time of day").
- Change family (u ≤ 15 only): each channel's change from pre = [−(u+15), −(u+5)) to [0,5), [5,15), [15,30],
  in physical units (bpm, RMSSD ms, °C, breaths/min, g, steps/min), tested as the event's centred rank among
  its own controls' changes (raw changes are bimodal when a walk starts or stops, which made a raw test
  anti-conservative). It recovers responses that context normalisation absorbs, e.g. an event that also
  makes the person move. Magnitudes and CIs are still reported in physical units.

### 5. Signature (`signature.py`)

- Per (channel, window): mean D, day-clustered bootstrap 95 % CI, consistency = share of events whose D has the
  mean's sign, events with data; also in physical units via the baseline scale.
- Global test: max-|t| over valid cells of both families, sign flips **shared within a local day**, exact
  when ≤ 12 days; cell p-values are family-wise adjusted. Smallest attainable p = 2 / 2^days is reported.
- Replication: split events in time; the first part's top cells must hold their sign with CI excluding 0 on
  the later events.
- Status:
  - `insufficient_events`: < 3 events with usable data → only per-event context is shown.
  - `individual_context`: ≥ 3 events but < 3 distinct days.
  - `individual_context` also while 3–5 days are not significant: p < 0.05 is unattainable below 6 days.
  - `no_reliable_signature`: not significant at p < 0.05 with ≥ 6 days, or significant but replication failed.
  - `emerging`: p < 0.05, replication not yet testable. (sig-1 used p < 0.10, which showed a signature for up
    to 17 % of null event types.)
  - `established`: p < 0.05 **and** replicated on later events.
- Distinct signatures: with ≥ 10 events, split by context at onset (asleep vs awake) or by 2-means on the
  event D vectors; keep the split only if both groups have ≥ 5 events on ≥ 3 days and each is significant on
  its own, otherwise report one signature.
- Movement annotation: an HR-up or HRV-down finding is marked `movement_accompanied` when steps or motion
  show a same-window change-family increase; the text adds “together with more movement” and a data-quality
  note is added. The status is not lowered: matching controls on activity at onset was tested and either
  failed to remove activity-selected false signatures or suppressed real movement-accompanied responses.
- Plain-language findings (top cells, max 5), each with its `basis`: “Heart rate rose 18 bpm (12–24) from before
  onset, within 5 min after onset, in 7 of 8 events.” (`change_from_before`) or “… 6 bpm above what is usual for
  the activity and time of day …” (`vs_usual_for_context`; “this person's usual level” in raw mode).

### 6. Detectability and retrospective detection (`detector.py`, `evaluation.py`)

- Scorers, all on causal trailing features (last 1, 5, 15 min of each channel's z, plus context):
  `hr_rule_raw` (HR above the training median + k·MAD), `hr_rule_context` (HR z above k),
  `template` (correlation of the trailing profile with the signature profile), `logistic` (L2, C chosen inside
  each day-blocked CV fold; missing features imputed as 0 plus a missingness indicator; a channel is used only
  if observed in ≥ 50 % of training negatives; a minute is scored only with HR present and ≥ 40 % of features
  observed).
- Every scorer abstains on minutes whose HR baseline (own or borrowed) has fewer than 3 local days behind it:
  new contexts (e.g. posture only after the accelerometer stream started) cannot be certified yet.
  A shallow tree model is only added later if it beats the logistic model forward.
- d = standardised separation of the scorer between event windows and matched-control windows,
  cross-validated by day. Expected recall at budgets 0.5 / 1 / 2 per day is **empirical**: the threshold that
  meets each budget on CV negative time (episode counter), the share of CV events above it, Wilson 95 % CI
  (`expected_recall_ci`). `assessment` is `promising` only if the lower d CI bound is ≥ 2.
- Thresholds are **certified out of fold**: the days before the cutoff are dealt into up to 5 folds; baselines,
  logistic and template are refitted without each fold's days and score only that fold. The threshold is the
  lowest one whose 80 % upper bound of false alerts per monitored day meets the budget, using a quasi-Poisson
  bound widened for day-to-day overdispersion (false alerts cluster on walking-heavy days). Negative time is
  everything outside each known event's match window [onset − u − 5 min, end + 10 min]. If no threshold
  meets the budget, the detector abstains. (sig-2 certified in-sample: the logistic then ran at 1.3 false
  alerts per held-out day under the null, 51 % of runs over budget.)
- `EpisodeState` (PR #5) turns scores into episodes (hysteresis, persistence, cooldown).
- Forward evaluation: cutoffs at each event day after the 3rd event; fit everything on data before the
  cutoff; test on later days. Metrics: event recall (Wilson CI), false alerts per 24 h of monitored time
  (exact Poisson CI), alert precision, latency (median, p90) from aligned onset, monitored fraction, d.
  Matching: an alert counts for an event within [onset − uncertainty − 5 min, end + 10 min].
- Promotion (champion/challenger): the incumbent model is frozen at its `retrospective.training_cutoff` and
  scored on everything after it; the challenger is refit at each later cutoff on the same events. Promote only
  with more detections at ≤ 1 false alert/day, or as many with fewer false alerts. All evidence is filtered on
  when it became available (`available_at`: observations `received_at`, negative reviews `created_at`,
  detection reviews `updated_at`), so labels entered after a cutoff never leak into it. With alerts disabled
  this governs the retrospective model only.
- Re-runs are skipped when nothing changed: a fingerprint of labels, per-stream row counts and latest
  timestamps, engine version and normalisation.

## Report (`signature-report-1`)

Stored in `event_detector_runs.report` (PR #5 table) and returned by
`GET /scores/event-detection/signature?typeId=<uuid>`.

```json
{
  "version": "signature-report-1",
  "type_id": "uuid", "generated_at": 1791600000,
  "engine": {"version": "sig-3", "normalization": "context"},
  "status": "insufficient_events | individual_context | no_reliable_signature | emerging | established",
  "evidence": {"events": 8, "event_days": 6, "observation_hours": 12.5, "confirmed_detections": 0,
               "rejected_detections": 0, "negative_intervals": 1, "monitored_days": 9.1,
               "events_used": 8, "events_dropped": {"fewer than 3 matched controls": 1}},
  "signatures": [{
    "id": "s1", "label": "all events", "events": 8, "event_days": 6, "event_ids": ["uuid"],
    "p_value": 0.03, "p_min_possible": 0.031, "replicated": true, "control_time_window_min": [60, 120],
    "context_at_onset": {"asleep": 0.0, "still": 0.62, "walking": 0.12, "active": 0.25, "unknown": 0.01},
    "findings": [{"channel": "hr", "unit": "bpm", "window": [0, 5], "direction": "up",
                  "change": 18.2, "change_ci": [12.1, 24.0], "change_z": 2.1, "consistency": 0.875,
                  "events_with_data": 8, "basis": "change_from_before", "movement_accompanied": false,
                  "text": "Heart rate rose 18 bpm (12–24) from before onset, within 5 min after onset, in 7 of 8 events."}],
    "profile": {"lags": [-30, 30], "channels": {"hr": {"unit": "bpm", "mean": [61 numbers],
                "ci_lo": [61], "ci_hi": [61]}}}
  }],
  "detectability": {"d": 1.8, "d_ci": [1.1, 2.4], "expected_recall": {"0.5": 0.12, "1": 0.30, "2": 0.45},
                    "expected_recall_ci": {"0.5": [0.03, 0.4], "1": [0.1, 0.62], "2": [0.18, 0.74]},
                    "assessment": "insufficient_data | too_weak_for_alerts | promising"},
  "retrospective": {"evaluated": true, "method": "logistic", "events": 5, "recall": 0.6, "recall_ci": [0.23, 0.88],
                    "false_alerts_per_day": 0.8, "false_alerts_ci": [0.2, 2.1], "latency_median_min": 3,
                    "monitored_days": 4.2, "baselines": {"hr_rule_raw": {}, "hr_rule_context": {}, "template": {}},
                    "promoted": false, "reason": "text", "training_cutoff": 1791400000, "champion": null},
  "data_quality": {"monitored_fraction": 0.82, "channels": {"hr": 0.97, "hrv": 0.4, "resp": 0.0, "temp": 0.95,
                   "motion": 0.3}, "notes": ["Breathing rate is not available for this strap yet."]},
  "limitations": ["text"],
  "alerts_enabled": false
}
```

Keys added in sig-2/sig-3 are optional (`events_used`, `events_dropped`, `control_time_window_min`, `basis`,
`movement_accompanied`, `expected_recall_ci`, `training_cutoff`, `champion`); finding channels may include
`steps`. Readers must
ignore unknown keys; the app does.

## Caregiver evidence

- Logged events of the type (with `onsetUncertaintyMinutes`), other event types (negatives for this type
  unless they overlap), **observation periods** (manual entry kind `observation`: “I was watching from … to
  …; everything that happened is logged”), reviewed negative intervals, confirmed / rejected / unsure
  detections (PR #5 reviews). Unsure is excluded. Archived entries are excluded.

## Validation before alerts

Deployment order: ship the app build that understands `observation` entries before (or with) the migration;
older builds skip the whole manual-event sync when they meet an observation revision.

See `docs/PHENOTYPE_SIGNATURES_VALIDATION.md` for the evaluation on real WHOOP recordings, the positive
controls planted on real WHOOP backgrounds, the normalisation ablation, and the evidence still required.
