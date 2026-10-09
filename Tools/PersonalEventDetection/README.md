# Personal event signatures (signature engine sig-3)

Learns each patient's physiological signature for a caregiver-logged event type from few labelled events and says
how reliable it is. The design contract is [docs/PHENOTYPE_SIGNATURES.md](../../docs/PHENOTYPE_SIGNATURES.md).
**Real-time alerts are not enabled in this phase**: nothing here publishes detections or notifications.

The worker is disabled by default. Nothing here deploys anything; importing the package, applying migrations or
installing the app starts no process.

## Install

```sh
python3.12 -m venv .venv
.venv/bin/pip install -e .
```

Dependencies: numpy, scipy, scikit-learn (logistic model), psycopg (worker only). No neural networks, no
pretrained weights, no downloads.

## Engine (`personal_events/`)

| Module | Role |
|---|---|
| `timeline.py` | One row per minute of one device: HR, ln-RMSSD (2-min trailing, Malik, >= 30 pairs, motion-gated), motion, steps, skin temperature (+ 6-h detrended), respiration, sleep, activity class/posture, wear. `load_postgres` / `load_whoop_sqlite` (read-only). NaN = missing, never 0. |
| `context.py` | Per-minute context (asleep, still_supine/seated/upright/unknown, walking, active, recovery, off, unknown), minutes since exertion, 4 time-of-day bands; pre-window composition `[onset - u - 15, onset - u)` (u = onset uncertainty). |
| `baseline.py` | `Normalizer(raw | context | context+response)`: robust expected value and scale; z per channel. A context with too few minutes borrows its parent (active -> walking -> awake pooled; still contexts -> still pooled -> awake), flagged as a fallback; no baseline at all -> NaN. |
| `profiles.py` | Event-locked profiles (-30..+30 min), onset re-alignment within the logged uncertainty, matched controls (pre-window composition, time of day widened 60 -> 120 -> 240 min, >= 3 required), paired differences in two families: level vs. usual for the context, and change from the event's own pre-onset window in physical units. |
| `signature.py` | Day-level sign-flip max-t test over both families (change family tested on centred ranks), family-wise adjusted cell p-values, day-clustered bootstrap CIs, replication, status, distinct signatures, findings text. |
| `detector.py` | Causal scorers (`hr_rule_raw`, `hr_rule_context`, `template`, `logistic` with missingness indicators), detectability d, empirical expected recall, certified thresholds, episodes (equivalent to `policy.EpisodeState`). |
| `evaluation.py` | Fitting everything before a cutoff (labels and caregiver spans by `available_at`); detectability on day-fold CV scores (logistic C chosen inside each fold); forward evaluation; champion (frozen incumbent) vs challenger; promotion rule. |
| `report.py` | `signature-report-1` assembly and validator. |
| `engine.py` | End-to-end run used by the worker and the CLI. |
| `inject.py` | Planted-event positive controls on real backgrounds (in memory only). |
| `cli.py` | `nara-signatures evaluate ...` offline runner. |
| `database.py`, `worker.py`, `policy.py` | Job claim/lease/fence/heartbeat (PR #5), evidence assembly, the signature job, `EpisodeState`. |

## Statistical notes (sig-2)

- **Controls.** An event's context is the dominant context of `[onset - u - 15, onset - u)`, so a late log cannot
  let the event's own movement decide it. A control must have the same dominant context with a share
  >= max(0.7, the event's share - 0.1), the same context group in the window's last minute, a local time of day
  within +/- 60 min (widened to 120 and 240 min while fewer than 3 controls are found; the width is reported per
  event), another local day, >= 2 h from labels and detections. Controls are a uniform random sample of the
  candidate minutes (observation / negative time first): capping controls per day or per walk over-samples short
  bouts and biased the walking null. Events with fewer than 3 controls are dropped with a reason.
- **Two families.** Level: event window z minus its controls ("vs what is usual for the activity and time of
  day"). Change: (window - own pre-onset window) minus the same for the controls, in bpm / ms / degC /
  breaths/min / g / steps per min; pre = `[-(u + 15), -(u + 5))`, so the family is skipped when u > 15. The
  change family is tested on the event's centred rank among its controls (raw changes are bimodal - a walk goes
  on or stops - so event minus mean(controls) is skewed and a sign-flip test on it was anti-conservative).
- **Calibration (synthetic).** Random mid-walk onsets (memoryless walks, 10 events, 14 days, 100 seeds): 7 % of
  runs reach p < 0.05 at u = 0 (sig-1: 57-77 % "established" on the real recording). On the real recording,
  activity-selected nulls (onsets mid-walk) are still "established" in 22-23 % of runs because the person keeps
  walking after onset; sig-3 marks those findings `movement_accompanied` rather than hiding them.
- **Alignment cost.** Controls are re-aligned to the same leave-one-out template within the same bound as their
  event. This keeps the null valid but costs power: controls gain the same "best match" bonus, so the paired
  difference understates what alignment recovers for the event (largest for 15-60 min uncertainties).
- **Expected recall** is measured, not modelled: on day-fold CV scores, the threshold meeting each false-alert
  budget on CV negative time (episode counter) and the share of CV event windows reaching it (Wilson CI). The
  Gaussian 100-decisions/day relation is kept only in diagnostics. `promising` needs recall@1/day >= 0.5 with a
  Wilson lower bound >= 0.3 and d's CI lower bound >= 2.

## sig-3 changes

- **Certified thresholds hold on new days.** Every scorer's threshold is certified on out-of-fold scores: the
  days before the cutoff are dealt into up to 5 folds and the baselines, logistic model (C of the full fit) and
  template are refitted without each fold's days before scoring them. The 80 % Poisson upper bound is kept and
  widened (quasi-Poisson) for day-level overdispersion of the episode counts. Certification negative time
  excludes each known event's match window `[onset - u - 5 min, end + 10 min]` - the same window that decides
  whether a held-out alert is false - instead of +/- 2 h.
- **Detectors abstain where nothing vouches for the score.** A minute is scored only if its heart-rate baseline
  (own or borrowed) has seen >= 3 local days of data; the logistic model uses a channel only if it is observed in
  >= 50 % of its training negatives, and scores a minute only with HR present and >= 40 % of its z features
  observed.
- **Movement-accompanied findings.** A heart-rate / HRV finding is marked `movement_accompanied` (text: "...,
  together with more movement") when steps or wrist motion changed from before onset in an overlapping window,
  in the direction that would explain it; `data_quality.notes` then says the change may come from moving.
  Matching controls on the activity at the logged onset was evaluated and rejected: it suppressed real events
  that cause movement at onset (movement plants 33 % / 70 % established -> 0 % / 20 %) without bringing the
  walking null to 5 %.

## Worker

```text
NARA_EVENT_DETECTION_ENABLED=1
NARA_EVENT_DATABASE_URL=<private Postgres connection with TLS verification>
NARA_EVENT_CACHE=/var/lib/nara-events
NARA_EVENT_NORMALIZATION=context        # optional: raw | context | context+response
OMP_NUM_THREADS=1
OPENBLAS_NUM_THREADS=1
```

```sh
nara-event-worker --lane train
```

- The `train` lane claims a job per (owner, event type), assembles the evidence (this type's completed events with
  `onsetUncertaintyMinutes`, other types' events, observation periods, reviewed negative intervals, confirmed /
  rejected detections; archived entries and unsure reviews are not used), loads the device timeline over
  `[first relevant label - 30 days, now]` (at most 120 days), runs the engine and inserts the report into
  `event_detector_runs.report`. `event_detector_settings.state` becomes the report status and `detail` is
  `{status, events, event_days, assessment}`. Label edits made while the job ran fence the publish (the job is
  retried). Jobs run daily and are brought forward to 10 minutes after any label change. A run whose fingerprint
  (labels, per-stream row counts and latest timestamps, engine version, normalisation) equals the last stored one
  is skipped before the timeline is loaded.
- Champion/challenger: the last promoted report's `retrospective.training_cutoff` identifies the incumbent; the
  forward evaluation freezes the model fitted at that cutoff, scores it on everything after it, and promotes the
  refit procedure only with more detections at <= 1 false alert/day (or as many with fewer false alerts).
- The `infer` lane exits immediately with a message: there are no alerts in this phase. **Keep
  `NARA_EVENT_DETECTION_PUBLISH` unset.** Setting it to `1` only changes the message: sig-1 has no publishing
  detector.
- Account deletion cascades every database row; private caches under `NARA_EVENT_CACHE` are removed within an hour.
- Logs contain no credentials, SQL parameters or physiological data.

## Offline CLI

```sh
nara-signatures evaluate --sqlite whoop.sqlite --device <deviceId> --events events.json \
  [--observations observations.json] [--tz-offset-s -25200] [--normalization raw|context|context+response] \
  [--inject 'n=8,hr=12,dur=10,unc=5,seed=1'] [--type-id <type>] [--incumbent-cutoff <unix>] --out report.json
```

`events.json` is a list of `{id, type_id, start, end, onset_uncertainty_min[, available_at]}` (unix seconds);
observations are `{start, end[, available_at]}`. Planted events take `--type-id` when given. The SQLite file is
opened with `mode=ro` and never written. The output is the `signature-report-1` JSON plus `forward_evaluation`
(per cutoff and per method), `diagnostics` (dropped events, alignment shifts, controls, thresholds, timings) and,
with `--inject`, the planted events' true onsets. `--inject` keys: `n`, channel amplitudes (`hr` bpm, `hrv`
ln-RMSSD units, `temp` degC, `resp` breaths/min, `motion` g), `lag`, `dur`, `unc`, `context`
(`awake|asleep|still|walking|active|any`), `per_day`, `spacing` (h), `seed`.

## Local validation

```sh
PYTHONPATH=. python -m unittest discover -s tests -v
```

Database tests require `NARA_EVENT_TEST_DSN` pointing to a **disposable** local PostgreSQL database: apply
`tests/database_fixture.sql`, then migrations `20261008090000_manual_events.sql` and
`20261009090000_personal_event_detection.sql`. Never apply the fixture to Supabase. The synthetic tests prove the
pipeline's rules (causality, calibration on null data, recovery of planted effects, schema); they do not establish
accuracy on real patients.
