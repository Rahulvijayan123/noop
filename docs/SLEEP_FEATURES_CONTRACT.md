
# Sleep phenotypes: shared contract (locked before parallel work)

Branch: `feature/sleep-phenotypes` (from `nara/main` = e2d0c56e230d2470ed5e074ec10ce2dde7632ca5).
Research spec: `/Volumes/Untitled/Downloads/spec-25.md` (authoritative requirements).
This document locks the SHARED decisions. Module owners implement against it and must not
rename wire keys. Deviations require root approval.

## 1. Canonical timeline (features/timeline.py — ROOT-OWNED)

Input: the day's DETECTED sleep sessions from `AnalyticsEngine.analyzeDay` (V2 staging,
`useSleepStagerV2: true`), edit-aware via `CandidateInputs.effectiveSleepWindow` semantics —
for the first wave the enrichment consumes the session list as loaded (same sessions the
snapshot's `sleep` array carries, incl. `is_nap`), and every night entry records whether a
user edit applied (`user_edited` per night, from `CandidateSleepEdit` presence for that day).

Rules (spec 4.1):
- Label space: `wake | light | deep | rem | uns` (lowercase, matching `StageSegment.stage`
  plus `uns`). UNS covers: off-wrist, missing, unscored, and data-loss seams. A confirmed
  bridge wake seam MAY be `wake` only when the two sessions are bridged by the existing
  `SleepStageTotals` bridging logic; otherwise the gap stays `uns`.
- 30-second epoch grid anchored at `night.start` (unix seconds), half-open `[start, end)`.
  An epoch's label = the stage covering the MAJORITY of the epoch (ties: the label of the
  earlier covering segment; no coverage majority → `uns`).
- Partial first/last epochs: public DURATION metrics use exact segment intersection sums;
  TRANSITION statistics use only fully-observed aligned epochs (first full epoch = the
  first epoch fully inside `[start, end)`).
- No transitions counted across `uns` epochs or across a real time gap (gap > 60 s inside
  the session with no stage coverage → `uns`).
- Overlaps: the last-writer (later `start`) wins inside a session, matching the current
  resolver; contradictory overlaps are counted in `coverage.overlap_seconds`.

Per-night output (dict): `night_id`, `start_utc`, `end_utc`, `is_nap`, `user_edited`,
`labels` (list of the 30 s labels, len = n_epochs), `epoch_s: 30`, plus coverage counters
(see §4). Naps are delivered as separate night entries with `is_nap: true`; the MAIN night
(selection = longest non-nap session, same as `DayScorer.mainSleepSession`) is `is_nap: false`.

## 2. Sidecar request/response (ROOT-OWNED; features/contract.py + server.py route)

New route: `POST /v1/sleep-features` (loopback-only, same body limits/loopback guard as
`/v1/infer`; budget: 3000 ms hard, run in-thread with a watchdog identical to
`run_inference`'s pattern; timeout → `status: "timeout"`, HTTP 200 with the degraded body).

Request (typed, versioned):
```json
{
  "schema_version": 1,
  "algorithm_version": "nara-sleep-features-1",
  "context": {
    "user_id": "...", "device_id": "...",
    "day": "YYYY-MM-DD", "iana_timezone": "...",
    "input_revision": 123,
    "interval_start_utc": "...", "interval_end_utc": "..."
  },
  "nights": [ { "night_id": "...", "start_utc": "...", "end_utc": "...",
                "is_nap": false, "user_edited": false,
                "stages": [ {"start": 1789000000, "end": 1789000030, "stage": "light"} ] } ],
  "hr_samples": [ {"ts": 1789000000, "bpm": 58.0} ],
  "skin_temp_samples": [ {"ts": 1789000000, "celsius": 31.2} ],
  "rr_beats": [ {"ts": 1789000000, "rr_ms": 900.0, "seq": 1, "ord": 0, "src_channel": 1} ],
  "resp_breaths": { "intervals": [ {"ts": 1789000005, "seconds": 4.1} ],
                    "runs": [ {"start": 1789000000, "end": 1789000300} ] },
  "history": {
    "pair_policy": "elapsed_24h",
    "days": [ { "day": "YYYY-MM-DD", "minutes": [ {"ts": 1789036800, "state": 1, "valid": true} ] } ]
  },
  "capabilities": { "oxygen_events": {...}, "waveform_staging": {...} }
}
```
Bounds (enforced in `features/contract.py`, 422/413 on violation):
- ≤ 16 h per night, ≤ 8 nights per request (main + naps + edits), ≤ 60_000 HR samples,
  ≤ 60_000 skin-temp samples, ≤ 120_000 RR beats, ≤ 20_000 breath intervals, ≤ 31 history
  days, ≤ 45_000 history minutes/day.
- `history.days[].minutes[].ts` = the minute's UTC start; `state` 1=sleep 0=wake (built by
  the WORKER from canonical published snapshots + wear evidence, see §5); `valid` = the
  minute is monitored (worn) and classified. The Python side never invents validity.
- All timestamps ISO-8601 UTC `YYYY-MM-DDTHH:MM:SSZ` for *_utc keys; plain unix ints for
  `stages`, `hr_samples`, `resp_breaths`, history minutes.
- `celsius` values must be finite and within [-10, 60]; bpm within [20, 250]; rr_ms within
  [200, 3000]; breath seconds within [0.5, 60].

Response (HTTP 200 always when the request validates; per-metric status fields):
```json
{
  "schema_version": 1,
  "algorithm_version": "nara-sleep-features-1",
  "status": "available" | "partial" | "withheld" | "timeout" | "error",
  "status_reasons": ["..."],
  "nights": [ { "night_id": "...", "start_utc": "...", "end_utc": "...", "is_nap": false,
                "stage_source": "sleep-v2",
                "stage_algorithm_version": "sleep-stager-v2-<record-actual>",
                "continuity": {...}, "architecture": {...}, "stage_physiology": {...},
                "settling": {...}, "thermal": {...}, "respiratory_variability": {...},
                "metric_status": {...}, "coverage": {...} } ],
  "regularity": {...},
  "dependencies": { "yasa": "0.8.0", "numpy": "...", "scipy": "...", "neurokit2": "0.2.13",
                     "sleepecg": "0.5.9", "config": {...thresholds, versions...} },
  "capabilities": {
    "oxygen_events":   {"ready": false, "reason": "unverified_sparse_oxygen"},
    "waveform_staging": {"ready": false, "reason": "continuous_ppg_not_delivered"},
    "sleepecg_shadow": {"ready": true|false, "reason": "...", "report": {...} }
  },
  "duration_ms": 123
}
```
- Every numeric leaf is finite or absent; NaN/inf → omitted + a `metric_status` reason.
- Every metric block carries its own `status`: `available` (all sub-metrics computable),
  `partial` (some sub-metrics null, with `reasons`), `withheld` (block not published,
  machine-readable reason), or `not_applicable`.
- A complete trace with zero events reports 0; missing evidence reports null + reason.
- No new composite score, no staging replacement, no promotion of candidates.

## 3. Metric blocks (owner-scoped, wire keys locked)

### continuity (A1) — owner: worker-continuity
Keys: `tib_min`, `tst_min`, `sol_min`, `sol_5min_run_min`, `spt_min`, `waso_min`,
`terminal_wake_min`, `sleep_efficiency_pct`, `sleep_maintenance_efficiency_pct`,
`recurrent_awakenings`, `recurrent_awakenings_60s_plus`, `recurrent_awakening_index_per_h`,
`return_to_sleep_latency_median_min`, `awakening_duration` {`count`,`median_min`,`p90_min`,`max_min`},
`longest_sleep_bout_min`, `mean_sleep_bout_min`, `sleep_bouts` {count},
`sfi_yasa_per_h` (YASA 0.8.0 SFI — counts sleep→WAKE transitions incl. terminal; DO NOT
equate with the recurrent awakening index), `yasa_stats` (raw `Hypnogram.sleep_statistics()`
dict, verbatim). Semantics exactly per spec A1 (TIB/TST/SOL/SOL_5min/SPT/WASO/terminal wake;
merge light+deep+rem → sleep label for bouts; internal awakening bounded by known sleep on
both sides; recurrent index denominator = TST/3600; null when no sleep).

### architecture (A2) — owner: worker-continuity
Keys: `transition_counts` 4x4 (rows/cols order `wake,light,deep,rem`, self-transitions
included, UNS pairs excluded, gap-crossing pairs excluded), `transition_probabilities`
(null row when unobserved), `row_weights`, `entropy_rate_bits_per_transition` (≥100 eligible
pairs for whole-night entropy; else null + `thin_data`), `bouts` per stage {count,
`median_min`, `p90_min`, `max_min`, `total_min`}, `rem_latency_from_onset_min` (first REM
start − s; NOT YASA's Lat_REM which is from recording start), `deep_latency_from_onset_min`,
`deep_front_load_fraction` (first third of [s,f)), `rem_late_fraction` (final third),
`eligible_pairs`, `excluded_pairs_uns`, `excluded_pairs_gap`.

### regularity (A3) — owner: worker-regularity
Rolling SRI (7/14/30-day) with `pair_policy: "elapsed_24h"`, exact 24×60-lag pairing on the
1-minute UTC grid, exclusion of invalid minutes on both sides, no pairing across a missing
intervening day (a "missing day" = a history day with < 12 h valid minutes), gates: ≥5
monitored valid days, ≥4 day-equivalents (96 h) of valid paired minutes, ≥80% of otherwise
eligible pair duration. Keys: `sri_7d`, `sri_14d`, `sri_30d`, each {`value`, `paired_minutes`,
`eligible_minutes`, `valid_days`, `status`, `reasons`}, plus `pair_coverage_by_hour` (24 ints)
and `clock_profile`. Withheld reasons include `insufficient_history`, `no_valid_daytime_decision`.
Timing variability (delivered even when SRI withheld): per-metric circular mean/SD
(`circadian_sd_min`) for `bed_time`, `sleep_onset`, `final_wake`, `midsleep` (midpoint
between actual sleep onset and final wake), using the night's IANA timezone, local clock
minutes → angles; `adjacent_night_phase_shift_min` (median, signed shortest circular
difference); `social_jetlag_min` only with work/free-day labels (withheld first wave:
`workday_labels_unavailable`). DST: elapsed-time pairing (SRI) is DST-immune by construction;
clock metrics report `dst_transition_days` count and use zone-aware local time. Negative SRI
preserved (never clipped). No SRI clip, no probability framing.

### stage_physiology (A4) — owner: worker-physiology
Per stage (`wake`,`light`,`deep`,`rem`): `hr_median_bpm`, `hr_p10_bpm`, `hr_p90_bpm`,
`rmssd_ms` {`median`,`iqr`,`windows`}, `sdnn_ms` {`median`,`iqr`,`windows`}, `resp_median_bpm`,
`resp_variability_cv`, `skin_temp_median_c`, `skin_temp_mad_c`, `movement_events_per_h`
(detector: 1 Hz gravity-change stream, resolution stated), `valid_min`, `windows`,
`excluded_mixed_stage_min`, `thin_data: bool`. Gates per spec 4.2: 5-min windows, ≥80%
temporal coverage, ≥100 valid adjacent pairs, ≤20% rejection fraction, ≥90% duration in the
claimed stage; ≥2 independent usable windows else thin-data status. RMSSD/SDNN from the
PRODUCTION cleaning (`HRVAnalyzer.cleanRRGapAware` semantics — reproduced in Python via the
existing `providers/hrv.py` production path reuse), adjacency broken by missing/rejected
beats; aggregates = median + IQR over windows. Canonical nightly HRV unchanged.

### settling (A5) — owner: worker-settling
Keys: `hr_pre_onset_slope_bpm_min` (Theil-Sen over [−30,0) min), `hr_early_sleep_slope_bpm_min`
([0,+30)), `hr_drop_bpm` (median HR[−20,−5) − median HR[+15,+30)), `hr_nadir_latency_min`
(earliest min of 5-min mean HR in [0,+90), ≥4 supported minutes per candidate window),
`hr_settling_latency_min` (first post-onset 10-min interval with ≥8 valid minutes, |Theil-Sen
slope| ≤ 0.1 bpm/min and MAD ≤ 2 bpm; else `no_detected_plateau` reason + null),
`hrv_early_sleep_curve` [{`ts`, `rmssd_ms`, `pairs`, `coverage`}] over [0,+60),
`hrv_early_sleep_log_slope_per_min` (Theil-Sen of log RMSSD, ≥4 usable windows, else null +
`thin_data`), `hr_curve` [{`ts`,`bpm`,`valid`}] (minute medians over [−30,+90]),
`temp_curve` [{`ts`,`celsius`,`valid`}] (same span). t=0 = canonical actual sleep onset s
(first sleep epoch of the main night, incl. the settled-onset gate), NOT session.start.

### thermal (A6) — owner: worker-settling
Nightly keys: `baseline_c` (median temp [−45,−15)), `early_sleep_delta_c` (median [+30,+60)
− baseline), `rise_slope_c_min` (Theil-Sen [0,+30)), `peak_latency_min` (earliest max supported
5-min median between onset and final wake), `pre_wake_slope_c_min` (Theil-Sen over final 30
valid minutes before final wake), `thermal_transition` {`onset_min`, `rss_single`, `rss_split`,
`improvement_pct`, `post_slope_c_min`, `sustained_c`, `supported`: bool} — bounded two-line
breakpoint search over [−45,+45] min, ≥15 valid minutes per side, ≥20% RSS improvement,
post-slope ≥ 0.005 C/min, sustained ≥ max(0.1 C, 2×pre-transition MAD); else
`supported: false` + `no_detectable_transition`. `thermal_to_sleep_latency_min` = (sleep
onset − thermal onset)/60 with sign, only when supported. Minute values = medians of
supported, worn, non-charging skin-temp observations (worker excludes charging intervals via
the existing charge/wear evidence it loads). Multi-day rhythm (`mesor_c`, `amplitude_c`,
`acrophase_h`, `fit_quality`, `is`, `iv`, `daily_amplitude_c`, `phase_stability_h`): fit
y = M + a·cos(2πt/24) + b·sin(2πt/24) on balanced hourly bins, ≥5 days with all 24 hourly
bins supported and ≥80% whole-day coverage, observation in every 6-h quadrant; nocturnal-only
→ withheld `insufficient_daytime_temperature`. IS/IV per the spec's population-moment
formulas, consecutive-hours-only numerator, null on zero variance. Existing CircadianEngine
untouched; this block is separately named observed skin-temperature rhythm.

### respiratory_variability (A7) — owner: worker-physiology
Input: the Swift-computed `SleepStager.respBreathTrack(rr)` intervals + runs, exported
VERBATIM by the worker (no Python recomputation). Keys: `intervals_valid`, `rate_bpm`
(60/median(d)), `sd_interval_s`, `cv_interval`, `rmssd_interval_s` (sqrt(mean((d_next −
d_prev)²)) over adjacent intervals within the same usable run — NOT over run boundaries),
`valid_run_min`, `stage_conditioned` per stage {`rate_bpm`,`cv_interval`,`windows`}, and
`outlier_fraction_vs_personal` (windows outside personal distribution, withheld when no
personal baseline). Gates: ≥20 estimated breath intervals per usable 5-min window, ≥80% run
coverage. Labels carry `estimate_source: "rsa-derived"`, `unobserved_breath_is_not_apnea:
true` wording in `coverage.estimate_source`.

### sleepecg_shadow (A8) — owner: worker-continuity (report only)
Report agreement of the existing SleepECG wrn-gru-mesa candidate lane vs V2 in the common
label space (V2 light/deep → NREM; wake/rem unchanged): `epochs_compared`, `agreement_pct`,
`agreement_by_label` {wake, nrem, rem}, `v2_distribution`, `sleepecg_distribution`,
`disagreement_near_onset_offset_pct`, `weights_revision`, `status`. No promotion, no
independent light/deep claim. Reuses the existing provider's staged output when the
candidate lane ran; otherwise `status: "not_run"`.

## 4. Coverage block (per night)
`known_fraction` (fraction of [start,end) with a known label), `known_epoch_fraction`,
`valid_hr_min`, `valid_temp_min`, `hr_gap_max_s`, `temp_gap_max_s`, `rr_valid_pairs`,
`rr_rejected_fraction`, `breath_intervals`, `breath_run_min`, `overlap_seconds`,
`observed_onset_edge`, `observed_offset_edge`, `max_unresolved_gap_s`, `sources` {`hr`: n,
`temp`: n, `rr`: n, `resp`: n}. Continuity summary gate (spec 4.2): ≥95% known timeline
coverage, observed onset/offset edges, no unresolved internal gap > 60 s → else that night's
continuity/architecture publish as `partial` with reasons.

## 5. History (regularity input) — worker-built, ROOT-OWNED loader
The worker builds the 31-day history ONCE per enrichment call from the user's published
snapshots (`scoring_snapshots_v2.payload->'sleep'` for local days d−31..d−1, newest
result_revision per (day, algorithm)), decoding each night's stage array to a 1-minute
sleep(1)/wake(0) grid, plus wear/monitoring validity: a minute is `valid` when it is inside a
detected session (staged coverage) OR (outside sessions) the minute has ≥30 s of HR presence
in the day's HR rows (worn). Outside-session minutes with no HR evidence are `valid: false`
(unknown awake-vs-off-wrist), never wake. Naps included as sleep. History days whose snapshot
is absent → the day is missing entirely (excluded from SRI; day-equivalents gate counts it).
Cache/digest: the request carries `history_revision_digest` = sha256 over the 31 (day,
result_revision) pairs; the response's `regularity` carries it back. A revision change
anywhere in the window invalidates the rolling SRI. Revising day d invalidates windows that
include d — automatic, because the digest changes.

## 6. Swift integration (ROOT-OWNED)
- `Tools/CloudWorker/Sources/frwhoop-worker/SleepFeatureEnrichment.swift`: builds the
  bounded request from the day's loaded inputs (stage segments from `result.sleepSessions`
  — the SAME sessions the snapshot `sleep` array carries; HR/RR/temp samples already loaded
  by `DayScoring`; breath track via `SleepStager.respBreathTrack(rr)`; history via §5),
  calls `POST /v1/sleep-features` through the existing `InferenceClient` transport pattern
  (new method; 3500 ms budget incl. transport; on timeout/absence → features withheld, core
  results unaffected), validates + attaches the response under
  `snapshot.daily.sleep_features` (verbatim passthrough of validated JSON, like
  `activity_context`).
- Wired from `DayScoring.scoreAndBuildPayloads` AFTER the snapshot is built, BEFORE publish,
  OFF the repeatable-read hot path where the current candidate assembly sits: enrichment runs
  in `ScoringLane` after `runFleet`'s publish-and-finish, publishing a REPLICA snapshot row
  is NOT used — instead the enrichment result is attached to the SAME payload before
  publish, called with a bounded wall-clock budget and a bounded input assembly (no new
  DB reads inside the transaction beyond the history query, which is a single bounded
  SELECT). If the sidecar is not configured (`FRWHOOP_INFERENCE_URL` unset), the snapshot
  publishes without `sleep_features` (byte-identical to today) — same dormant-default
  pattern as the candidate lane.
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepFeatureDocument.swift`: shared
  Codable types mirroring the response (decode-non-fatally in `HostedDayResult` from
  `daily.sleep_features`, same pattern as `activity_context`; malformed/future schema →
  nil, day intact).
- App UI: `Strand/Screens/SleepFeatureCards.swift` (new) + minimal wiring in
  `SleepModel.swift`/`SleepView.swift` (owner: worker-client): a compact expandable "Sleep
  detail" section — Continuity / Regularity / Architecture / Physiology / Settling / 
  Breathing cards. Estimate wording: stages are model estimates; RSA breathing is estimated
  from heart-rate rhythm, not airflow; oxygen burden UI never shows a fake zero — B1
  blocked card states the reason. Existing "strap estimate (unverified)" oxygen wording kept.
- No DB migration: `publish_scoring_snapshot_v2` stores `daily` verbatim; `serverScores.ts`
  passes `daily` through; `ServerScoreRepository` caches raw JSON. Offline persistence =
  existing raw snapshot cache. No new table in the first wave.

## 7. Group B (ROOT-OWNED, capability gates only)
- B1 (pobm oxygen): BLOCKED — `SPO2_STRAP_EST` is an unvalidated sparse strap estimate
  (~400–500 s/night), `noop_spo2_samples` are uncalibrated ADC. Capability gate reports
  `{"ready": false, "reason": "unverified_sparse_oxygen"}`. No pobm dependency added to
  production; `pobm` version/compatibility research recorded in the manifest section of
  this doc's final report. Next smallest action: qualify the strap estimate against a
  reference oximeter (spec B1 qualification list).
- B2 (wav2sleep): BLOCKED — no continuous, timestamp-qualified WHOOP waveform delivery to
  the server exists. Capability gate `{"ready": false, "reason": "continuous_ppg_not_delivered"}`.
  Shadow-lane preparation steps documented (spec B2 items 1–10); weights NOT vendored into
  the repo; no fabricated checkpoint. Next smallest action: extend the object lane to
  deliver per-epoch PPG windows with source/clock metadata, then wire the qualified shadow
  provider through the existing candidate lane.
- B3 (CVHR), B4 (PPG autonomic events), B5 (CPC/cycles): BLOCKED, same waveform/heartbeat
  prerequisites; capability entries `not_started` with reasons; no speculative code.
- The capabilities object in every response states these gates machine-readably.

## 8. Testing + fixture
- Python: `Tools/InferenceWorker/tests/test_sleep_features_*.py` per module + a fixture-night
  end-to-end test (synthetic staged night + HR/RR/temp/breath inputs → full response →
  assert invariants: no NaN, half-open math, UNS handling, YASA REM-latency subtraction,
  SRI ±100 identities, circular midnight, DST/timezone cases).
- Swift worker: `Tools/CloudWorker/Tests/frwhoop-workerTests/SleepFeatureEnrichmentTests.swift`
  (request assembly bounds, timeout → withheld, absent sidecar → no key, passthrough
  validation).
- App: decode tests in `StrandTests` (HostedDayResult sleep_features decode non-fatal;
  card rendering smoke). Run `xcodegen generate` after adding app files.
- Commands: `cd Tools/InferenceWorker && uv sync && uv run pytest`; worker
  `cd Tools/CloudWorker && swift test`; app `xcodebuild test ... -only-testing:StrandTests`
  per docs/IOS.md. Deployment per deploy/README.md (NOT performed in this wave; runbook
  updated).

## 9. Version stamps
`algorithm_version: "nara-sleep-features-1"`, `stage_algorithm_version: "sleep-stager-v2"` (the canonical scoring algorithm
version actually claimed for the day — `ScoringLane.v2AlgorithmVersion`, default
`frwhoop-server-1`, passed through by the worker), dependency
versions recorded from the imported packages at runtime (yasa/numpy/scipy/neurokit2/sleepecg).
Config object `dependencies.config` carries every threshold from §3 with versioned name
`sleep-features-defaults-1`.
