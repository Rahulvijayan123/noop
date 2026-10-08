# Spec 02 — physiology-context cardiac (label `pccard`)

Branch `spec02/pc-cardiac-20261007`, worktree `nara-spec02-pc-cardiac`, from foundation `fedeceb49`.
Scope: spec §1 "awake vs sleep HR" and "sustained high/low pulse episodes + HR acceleration with movement",
CONTRACT §6 (`sleep.day_night_heart_rate`, `pulse_episodes`, `PolicyVersions.pulse`, `Policy.pulse`).

## 1. Awake vs sleep heart rate (`PCSleepRhythm.swift`)

**What the existing contrast does (checked, not assumed).** `SleepRhythm.dayNightContrast` takes every
plausible (30–220 bpm) HR sample inside the day's main-sleep episodes as the sleep side, and every plausible sample
in the day window (up to the cutoff in causal mode) outside every sleep episode (main, naps, other days) as the
awake side; each side needs `SleepConfig.rhythmMinSamples` (1800) samples; value = median(awake) − median(sleep);
nil with `main_sleep_incomplete` when a main sleep is still in progress. Weighting is per sample: the sanitized
stream is one sample per second (System A collapses exact duplicates and rejects conflicting ones), so it is a
median over observed seconds. There is no per-minute step in the existing rule, so none was added (adding one would
change the published difference).

**Change.** The sample selection moved into one helper, `SleepRhythm.dayNightSeries`, which the contrast and the
new block both call — one series, two read-outs, no parallel model. The contrast's code path is otherwise
identical, so `proxy_hr_day_night_contrast.value` is unchanged (pinned by the existing
`PCSleepEvidenceSummaryTests` value 20 and by the new tests asserting `difference_bpm == contrast.value`).

`SleepRhythmSummary.dayNightHeartRate` (`sleep.day_night_heart_rate`, type `DayNightHeartRate`):

| Field | Definition |
| --- | --- |
| `state` | `supported` both medians, `partial` one, `unavailable` none |
| `awake_median_bpm`, `sleep_median_bpm` | medians of the two sides; nil (with reason) below 1800 samples |
| `difference_bpm` | awake − sleep from those medians (= the contrast value) |
| `percent_dip` | `100 × (awake − sleep) / awake`, only with both medians; reason `percent_dip_definition` |
| `percent_dip_definition` | `100*(awake_median_bpm-sleep_median_bpm)/awake_median_bpm` |
| `awake_samples`, `sleep_samples` | samples behind each median |
| `awake_eligible_s` | day window (to the cutoff when live) minus all sleep-episode time |
| `sleep_eligible_s` | merged main-sleep seconds; 0 while the main sleep is in progress |
| `awake_coverage`, `sleep_coverage` | distinct observed seconds / eligible seconds, in [0, 1]; nil without eligible time |
| `method` | `pc-day-night-hr-1` (= `SleepConfig.dayNightHeartRateVersion`, in the fingerprint) |
| `units` | `bpm` |
| `min_samples_per_side` | 1800 |
| `awake_window` | `[day start, day end)` or `[day start, cutoff)` |
| `reasons` | `rhythm_proxy_only`, `labels_read_heart_rate` always; `awake_hr_insufficient`, `sleep_hr_insufficient`, `no_main_sleep`, `main_sleep_incomplete`, `percent_dip_definition` as applicable |

The sleep side was selected by a detector that reads HR (circular by construction); the block inherits the
contrast's `rhythm_proxy_only` / `labels_read_heart_rate` reasons and the existing `rhythm_proxy` dependence note.

## 2. Sustained pulse episodes and HR acceleration with movement (`PCPulseEpisodes.swift`)

Stub replaced. Full definitions are in the file header; summary:

- **Qualified second** (HR-independent qualification): exactly one HR value in [30, 220] (a conflicting
  duplicate disqualifies the second); not part of a constant run ≥ 900 s at ≤ 2 s steps (the signal-validity
  stuck-signal bar, `hrFlatlineInvalidS`); motion evidence stationary and continuously stationary for ≥ 300 s
  (`EligibilityConfig.minPrecedingStillS`); not inside an exertion bout or the 600 s after one
  (`postBoutExclusionS`). Motion evidence is `BoutEvidence` — the bout detector's merge of HART epochs (when
  confident) and strap motion — so no HR-derived label (decoder track) ever qualifies HR.
- **Segments**: consecutive qualified samples ≤ `maxGapS` (10 s, = `ExertionConfig.hrGapMaxS`) apart with no
  System-A break between. Nothing is bridged.
- **Hysteresis** per segment: high enters at ≥ 100, exits after HR stays < 95 for 60 s (the episode ends at the
  first exit sample); low enters at ≤ 40, exits after > 43 held 60 s. Minimum 600 qualified seconds.
- **Censoring**: an episode touching its segment's edge carries why the segment began/ended:
  `episode_censored_gap` (gap or break), `episode_censored_qualification` (adjacent sample not qualified: movement,
  unsettled stillness, bout follow-up, implausible, stuck or conflicting), `cutoff_reached` (live cutoff),
  `episode_censored_window` (lookback/lookahead edge).
- **Ownership**: episodes belong to the day containing their start; the machine reads 6 h before the day and
  (retrospective) 6 h after, so a night episode crossing midnight keeps its true extent and is never split into two
  boundary-censored halves. Exposure counts only the day window.
- **Per episode**: `id` (`pulse_` + FNV(kind|start)), `kind`, `interval`, `duration_s`, `median_bpm`,
  `extreme_bpm` (max for high, min for low), `qualified_s`, `coverage` (= qualified/duration), `context`
  (`asleep`/`awake`/`mixed`/`unknown` from detected sleep episodes; `unknown` when the day has no sleep evidence),
  `evidence_source` (`hart_epochs`/`strap_motion`/`mixed`), `censoring`, `reasons` (`pulse_episode_high|low`).
  No confidence number is invented: support is `qualified_s`/`coverage` and censoring.
- **Acceleration with movement**: at an HR-independent movement onset `m` (movement right after stationary
  evidence): baseline = median qualified HR in `[m−75, m−15)` (≥ 45 samples); crossing = first sample ≥
  baseline + 10 bpm in `[m−15, m+30]`; rise onset `r` = last sample ≤ baseline before the crossing, `r ∈ [m−15,
  m+15]`, crossing − r ≤ 15 s; HR continuous from the baseline to the crossing. Event: `ts` (= r), `baseline_bpm`,
  `peak_bpm` (max in `[r, r+15]`), `rise_bpm`, `rise_s`, `movement_offset_s` (m − r), `context`,
  `baseline_samples`. No cause is attributed (`cause_not_attributed` on the summary).
- **Summary** (`pulse_episodes`): `version` `pc-pulse-1`, `state`, `thresholds` (all 22 numeric parameters),
  `qualified_inactive_s` / `_asleep_s` / `_awake_s`, `episodes`, `high/low_episode_count`, `high/low_episode_s`,
  `acceleration_events`, `acceleration_events_per_asleep_hour` / `_awake_hour` (only with ≥ 3600 qualified s in
  that context, else nil), `units`, `window`, `evaluated_span`, `evidence_seconds`, `reasons` (always
  `not_rhythm_classification`, `cause_not_attributed`, `labels_read_heart_rate`). No qualified second → `unavailable`,
  counts nil, `qualified_inactive_hr_insufficient`; some but < 3600 s → `partial` with the same reason, counts
  present (0 = evaluated, none found).
- **Thresholds: fixed, not personal.** The context layer's references are daily-value references
  (`PCReferences`, per series/regime, median/MAD over days); there is no stable second-level personal HR reference
  to anchor an enter/exit threshold to, and tying thresholds to references would make episodes move with reference
  history and freezing. So the thresholds are fixed, configurable bpm values, reported in every summary, and
  descriptive (not clinical cut-offs). No clinical words in fields, codes or comments.

Engine call site (`PCEngine.swift`): the detector now receives `allBouts` (history + today) instead of today's
bouts, because it reads the evening before the day and a bout's follow-up is never inactive.

## 3. Policy fingerprint decision

- `Policy.pulse: PulseEpisodeConfig` stays in the existing policy architecture because the detector now reads
  every field. The whole struct is encoded into `Policy.fingerprint`, so every behaviour-changing pulse parameter
  (all 23 stored fields, including `version`) moves the key; a test mutates each field and checks the key changes,
  and a `Mirror` check fails if a new field is added without being exercised. `PolicyVersions.pulse` =
  `pc-pulse-1`.
- `SleepConfig.dayNightHeartRateVersion` (`pc-day-night-hr-1`) keys the new day/night block the same way.
- `respiratoryRecovery`: nothing computes it on this branch, so it is **out** of the fingerprint and out of
  `versions` (`PolicyVersions.respiratoryRecovery` is nil). Mechanism, in `PCContract.swift`:
  `Policy.respiratoryRecoveryComputes = false`; while false, `fingerprint` blanks
  `exertion.respiratoryRecoveryVersion` before encoding (so its value cannot move the key) and `versions` omits it.
  **Coordination with the respiratory agent:** flip `Policy.respiratoryRecoveryComputes` to `true` in the commit
  that makes `BoutRecovery.respiratoryRecovery` compute; nothing else is needed. (Its version lives in
  `ExertionConfig`, their file, so the flag sits in `Policy` to keep my edits out of `PCExertionBouts.swift`.)
- **Invalidation scope (read this before deploying).** The default policy fingerprint changes (pulse config +
  day/night version entered it), so every physiology-context document built after the deploy carries a new policy
  key. How that reaches stored rows, checked in the code:
  - `publish_physiology_context_v1` treats a publish as `unchanged` only when BOTH `policy_fingerprint` and
    `input_fingerprint` equal the current row. With a new policy key, every rebuild after the deploy stores a new
    revision once (even with identical inputs), then later rebuilds are idempotent again.
  - Nothing re-enqueues on a policy change: `enqueue_physiology_context_days_v1` bumps jobs only on scoring
    completions (dependency fingerprint), finality due, or explicit invalidation; the worker
    (`ContextLane.swift`) does not compare the stored policy key. So existing documents are recomputed only when
    their job next runs: the live day and recently scored days quickly; older closed days keep their pre-deploy
    document (without `pulse_episodes` / `day_night_heart_rate`) until something touches them. To recompute history
    deliberately, run `invalidate_physiology_context_span_v1` over the wanted span (operator decision; not done
    here).
  - Change-detection episode ids include the policy fingerprint (`PCChangeDetection` `ep_` ids), so persistent-change
    episodes rebuilt after the deploy get new ids. Frozen references are matched by (series, regime, version), not
    by fingerprint, so they are not re-registered.

## 4. Persistence / API trace

| Hop | Where | Result |
| --- | --- | --- |
| Producer | `Engine.buildDay` → `document.pulseEpisodes`, `sleep.dayNightHeartRate` | computed on every build |
| Encode | `PhysiologyContext.encoder()` (snake_case, sorted) | keys `pulse_episodes`, `sleep.day_night_heart_rate` (test asserts the keys) |
| Stored form | `StoredDocument.split` copies the document and only removes envelopes | both blocks stay in the summary (test: split → encode → decode → join == original) |
| Worker | `ContextLane.encodeProducts` → `publish_physiology_context_v1` `document` (jsonb, whole) | no key whitelist in the RPC (checks header/identity/size only) |
| DB | `physiology_context_days.document` (`20261006050000_physiology_context.sql`) | stored as published |
| Read RPC | `physiology_context_read_v1` returns `r.document` (only `envelopes` filtered by `p_metric`) | whole document |
| Edge | `serverScores.ts` `/context` → `Response.json({context, identity})`; `physiologyContext.ts` only parses queries | no projection; Deno test added that both blocks pass through verbatim |
| App | `PhysiologyContextDocument.decode` → `full` = `DayDocument` (has both), `sleep` = `SleepRhythmSummary` (has `dayNightHeartRate`) | decodes; `pulse_episodes` is reachable via `full` only — the lenient member decoder (`LenientDayDocument`) has no `pulseEpisodes` member yet (UI agent) |

Old documents without the new keys decode (`pulseEpisodes`/`dayNightHeartRate`/`versions.pulse` nil; test).

## 5. Reason codes (UI agent: map each in `MeasurementContextWording.swift`)

New, declared in `SleepRhythm.reasonCodes` (already enumerated by `PhysiologyContextWordingCoverageTests`, so
that test FAILS until these are mapped):
- `percent_dip_definition`, `awake_hr_insufficient`, `sleep_hr_insufficient`

New, declared in `PulseEpisodes.reasonCodes` (the coverage test does not list `PulseEpisodes` yet — the UI agent
should add `("PulseEpisodes", PC.PulseEpisodes.reasonCodes)` to it):
- `pulse_episode_high`, `pulse_episode_low`, `hr_acceleration_with_movement`, `episode_censored_gap`,
  `episode_censored_qualification`, `qualified_inactive_hr_insufficient`, `cause_not_attributed`,
  `not_rhythm_classification`, `episode_censored_window` (new, not in the CONTRACT's reserved list: the
  lookback/lookahead edge)

Also emitted, already declared and worded by their owners: `cutoff_reached` (ExertionBouts),
`labels_read_heart_rate`, `rhythm_proxy_only`, `no_main_sleep`, `main_sleep_incomplete` (SleepRhythm),
`activity_evidence_unavailable` (Engine).

Non-code strings shown to users: episode `kind` `sustained_high`/`sustained_low`, `context`
`asleep`/`awake`/`mixed`/`unknown`, `evidence_source` `hart_epochs`/`strap_motion`/`mixed`.

## 6. Edits to root-owned / shared files

- `PCContract.swift` (Policy only): `Policy.respiratoryRecoveryComputes` (static, false); `versions` sets
  `respiratoryRecovery` only when it computes; `fingerprint` blanks `exertion.respiratoryRecoveryVersion` while it
  does not.
- `PCEngine.swift`: the pulse detector call passes `allBouts` (comment updated). No other change.
- `supabase/functions/tests/physiology_context_routes_test.ts`: one pass-through test. `physiologyContext.ts`
  unchanged (it projects nothing).
- Wire-shape additions beyond CONTRACT §6 (all optional, `= nil`, old JSON decodes): `DayNightHeartRate.method`,
  `units`, `min_samples_per_side`, `awake_window`; `PulseEpisode.coverage`, `evidence_source`;
  `HeartRateAccelerationEvent.baseline_samples`; `PulseEpisodeSummary.units`, `window`, `evaluated_span`,
  `evidence_seconds`. Config additions: `PulseEpisodeConfig` gained `hrPlausibleMin/MaxBpm`, `flatlineMaxStepS`,
  `flatlineMaxS`, `settleStillS`, `postBoutExclusionS`, `maxUnknownFraction`, `accelerationBaselineMinS`,
  `lookbackS`, `lookaheadS`; `maxGapS` default 30 → 10. `SleepConfig.dayNightHeartRateVersion`.

## 7. Tests

| Run | Result | Log |
| --- | --- | --- |
| `sbuild.sh … pccard sa-test --filter 'PCPulseEpisodesTests\|PCCardiacContextTests'` (full build incl. tests, 1287 s) | 28 run (19 pulse + 9 cardiac context), 0 failures | `_build-scratch/spec02/logs/pccard-sa-test-130130.log` |
| `sbuild.sh … pccard sa-test --filter 'PC\|Physiology\|SleepRhythm\|Pulse'` | 310 run, 4 skipped, 0 failures (includes `PCSleepEvidenceSummaryTests` contrast = 20, `PCDocumentSizeTests`, `PCRealReplayTests`, `PCEngineTests`) | `_build-scratch/spec02/logs/pccard-sa-test-133855.log` |
| `deno test --allow-all tests/physiology_context_routes_test.ts` (supabase/functions) | 19 passed, 0 failed | terminal |

New tests: `PCPulseEpisodesTests` (hysteresis with a sub-hold dip, held exit, oscillation around the enter
threshold, brief excursion, minimum duration 599/600, gap / break / qualification-loss / cutoff censoring, settle
rule, bout follow-up, stuck signal, exact and conflicting duplicates, no data / no motion evidence / partial
exposure, sustained low in sleep, day ownership across both midnights, acceleration baseline/rise/offset by hand,
no event without movement / without rise / with a slow rise / across a hole, rates need an hour of exposure,
JSON round trip and the foundation JSON shape decoding) and `PCCardiacContextTests` (medians, coverage and dip
against hand values, mixed-value medians, implausible samples, insufficient sides, no night, no HR, causal window,
unfinished night, duplicates, fingerprint per pulse field + Mirror completeness + respiratory exclusion, engine →
encoder → decoder and stored-form round trip with the wire keys, documents without the new keys decode, codes
registered). Not run: CloudWorker build/tests (no worker source changed), the app's `StrandTests`
(`PhysiologyContextWordingCoverageTests` is expected to fail until the three new SleepRhythm codes are worded).

## 8. Not done / limits

- App rendering of both blocks is the UI agent's (wording map, lenient `pulseEpisodes` member, cards).
- Thresholds are population-fixed descriptive values; a personal-baseline variant would need a second-level
  personal HR reference the context layer does not have.
- HART/strap stillness is not proof of rest or wakefulness, and the sleep context comes from an HR-reading
  detector; both are disclosed in reasons. Acceleration events are associations in time only.
- CloudWorker was not rebuilt (no worker source changed; it consumes the package).
