# FRWHOOP: server-side physiology algorithm migration

Prepared 2026-10-01. Deliver a reviewable implementation on a new branch.

## 1. Goal and scope

Connect the specified signal-processing libraries and pretrained models to FRWHOOP's existing hosted computation pipeline. Replace an existing algorithm only when its replacement has compatible inputs, preserves application contracts, and passes an agreed comparison. Keep capture, synchronization, storage, and the iOS experience working throughout the migration.

Moving computation to a VPS permits heavier processing. It does not establish greater accuracy or recover signals the phone did not capture. Treat the supplied model list as candidates with different readiness levels, rather than a requirement to force every model into production.

Implement inference and adapters, not training. Preserve RHR definitions, Rest/recovery formulas, strain, calories, and step accumulation except for explicitly validated changes to their upstream inputs. The personalized physiology learning document is downstream context; its discovery agents, training loops, and individualized scoring are outside this migration.

This specification was written from supplied documents and primary project/vendor sources. It is not verification of the current GitHub checkout, deployed Droplet, or live Supabase schema. Establish those facts before editing.

## 2. Establish the real baseline

Read all applicable `AGENTS.md` files. Record repository URL, active branch, base SHA, dirty files, deployment SHA, runtime versions, and existing test failures.

Create `feat/server-physiology-models-20261001`, or a unique suffix if it exists. Start from the current relevant product branch, preserving recent hosted-sync work. Do not default to an older upstream NOOP branch. If necessary, use an isolated worktree. Never reset, discard, or stash someone else's changes. If required plumbing exists only in uncommitted changes, copy the relevant reviewed diffs into the isolated worktree and record their origin without altering the original checkout.

Trace one actual input through capture, durable receipt, archive, computation, projection, and app reads. Confirm the deployed repository rather than guessing between FRWHOOP, a NOOP fork, and another hosted-worker project. Report discrepancies and update the implementation map accordingly.

### Supplied evidence and its authority

| Source | How to use it |
| --- | --- |
| `System-Overview.txt`, `backend.md.txt`, `Database-and-Storage.txt`, `Algorithms.txt`, `Packets-and-Decoding.txt`, `Frontend.txt` | Main implementation map. Verify every path and contract against current code. |
| `FRWHOOP_PRODUCTION_AUDIT.md`, `REVIEW_ingest_replay.md`, `REVIEW_frontend_persistence.md`, `REVIEW_noop_protocol_parity.md`, `REPORT_sleep_review.md` | Existing fixes, known failures, and regression cases. Recheck whether each finding still applies. |
| `RR-OPTIMIZATION.md` | Preserve gap-aware beat handling. WHOOP agreement reported here is a comparator, not independent ground truth. |
| `ANALYTICS.md`, `ARCHITECTURE(1).md`, `DATA_MODEL.md`, `BUILD.md`, `BLE_REVERSE_ENGINEERING.md`, `ANDROID.md`, `CROSS_PLATFORM.md` | Upstream/reference context. These do not prove which algorithms or streams the hosted product uses. Android changes are outside scope. |
| `FRWHOOP_storage_system.md` | Proposed architecture. Do not reinstate its local-compute design over the current hosted implementation. |
| `FRWHOOP_personalized_physiology_learning_system.md` | Future consumers and versioning considerations, not authorization to build a learning system. |

The current documents identify these likely integration points:

| Concern | Candidate location to confirm |
| --- | --- |
| Computation and projections | `whoop/backend/metrics/engine.js`, especially `persistComputed` and `recomputeFromStorage` |
| Sleep | `metrics/sleepDetection.js`, `sleepStagerV2.js`, `sleep.js`, `overnight.js` |
| HRV and respiration | `hrv/engine.js`, `respiration/`, shared `signal/quality.js` and `signal/capability.js` |
| Transport and replay | `host/routes.js`, `identity/userRuntime.js`, `ingest/hourBuffer.js`, `historyBuffer.js`, `archiveFormat.js` |
| Database | `metrics/repository.js`, `whoop/supabase/migrations/` |
| App reads | `daySnapshotModel.js`, `dayReads.js`, `sleepPageModel.js`, `StageTimelineChart.jsx` |

Document each existing metric's active producer, flags, input requirements, units, persistence fields, consumers, and fallback. The attachments already describe a hybrid sleep detector, a V2 stager, windowed gap-aware HRV, and several gated V2 engines. Do not treat the entire backend as untouched default NOOP math.

## 3. Replacement decisions

Recheck upstream source, checkpoints, dependencies, and license terms at a pinned revision before implementation. Verify code and weight permissions separately.

| Output | Candidate | Required action |
| --- | --- | --- |
| Overnight HRV | NeuroKit2 | Implement a versioned candidate using real RR timing and artifact diagnostics. Compare against the current windowed, gap-aware RMSSD engine before promotion. No training is needed. [S1, S2] |
| Main sleep interval, onset and wake | HypnosPy HR boundary algorithm | Implement an independent detector candidate. Its HR algorithm uses thresholds and boundary refinement without fitting a new model. Keep existing wear, motion, and wake guards until a comparison supports changing them. [S3] |
| Beat-based staging | SleepECG `wrn-gru-mesa` | Implement frozen inference when reliable consecutive heartbeat timing exists. It produces wake/REM/NREM, so retain a separate three-class result. It cannot directly populate light/deep fields. [S4] |
| Four-stage staging from optical waveform | wav2sleep, `joncarter/wav2sleep` | Conditional adapter for actual supported raw waveform data. For this product, verify PPG-only compatibility and preprocessing. It is a four-class, bidirectional model; use it for retrospective staging. [S5, S6] |
| Four-stage staging from HR and acceleration | `akaneriya1/no-eeg-sleep-staging` | Conditional challenger using its frozen bundled model. Requires compatible HR and sampled acceleration features. Its small healthy cohort and whole-night context limit transfer to WHOOP and live use. [S7] |
| Respiratory rate | `kazemikianoosh/RR_Estimation` | Conditional frozen-checkpoint adapter. Requires raw PPG and synchronized three-axis acceleration. The example performs fine-tuning; do not run that training path. Keep the existing quality-gated RR/RSA estimator until eligibility and validation pass. [S8] |
| Steps | Oxford `stepcount` | Record as blocked for commercial integration unless separate rights are supplied and verified. Its present academic-use terms do not authorize this product, including product shadow execution. Keep the existing strap counter. [S9] |
| RHR | Existing active method | Preserve the actual configured statistic. The documents describe different upstream and hosted definitions, including percentile methods and a sustained five-minute candidate. Do not assume the pasted table identifies the active method. |
| Rest/recovery | Existing formulas | Preserve definitions and weights. Recompute using the selected, consistent upstream results only after their promotion. A downloadable sleep embedding is not a replacement score. |
| Calories | Existing energy path | Preserve current canonical estimator and fallback. The listed wrist CNN repository exposes pretrained models but no visible repository license granting product integration; do not install it without verified rights, suitable inputs, and validation. [S10] |

### Input readiness is measured, not inferred

Build a capability report from real decoded/archive records, covering device and firmware, source, units, sensor time, cadence, coverage, maximum gap, clock drift, and provenance. Prove a usable signal survives the complete path into the worker.

The attachments say ordinary iOS uploads contain HR, RR, gravity/motion, and some decoded historical fields. Opaque notification archives and decoder support do not establish continuous raw PPG or high-rate acceleration availability.

These conversions are forbidden:

- Converting averaged HR into invented beats or PPG.
- Concatenating sparse RR batches into a fictitious uninterrupted heartbeat timeline.
- Feeding cumulative motion ticks, gravity summaries, or phone motion to a model trained on raw wrist acceleration without a separately validated adaptation.
- Feeding motion magnitude as three independent acceleration axes.
- Treating opaque optical bytes or reported packet rate as a validated, correctly timed physiological waveform.
- Splitting SleepECG NREM into light and deep using guessed percentages or legacy predictions.

Eligibility is per metric, session, device, and input generation. Use explicit states such as `eligible`, `blocked_input`, `blocked_artifact`, `blocked_license`, and `unverified`. A blocked candidate must not silently become a live dependency.

Build working NeuroKit2, HypnosPy, and SleepECG adapters with executable tests against suitable fixtures. For each conditional model, prove the pinned checkpoint can run on an upstream-compatible reference fixture where permitted. Wire it to product inputs only if the capability report supports that. If assets or access are unavailable, document the exact blocker; do not substitute fake inference or a success-returning stub.

Do not expand this branch into sensor enablement, firmware work, BLE persistence repair, or a new raw-stream ingestion system. Record any such prerequisite separately.

## 4. Integrate at the existing computation boundary

Keep Node/Express and the current orchestrator as the application owner. Run scientific Python inference in an isolated, long-lived worker process/container, using the existing hosted worker where possible. No per-sample Python subprocesses and no synchronous inference inside an ingest request.

Reuse the current durable job/recompute mechanism if it satisfies the requirements below. Add only the missing pieces. Avoid introducing a second broker or public inference service by default.

### Provider and result contract

Add versioned providers for `hrv`, `sleep_boundary`, `sleep_stage`, and `respiration`. Match current interfaces where possible; the following describes the necessary semantics rather than prescribed function names.

Inputs identify the user/device, immutable input objects or snapshot, UTC interval, IANA timezone, profile/configuration versions, user corrections, and required historical context. Each provider declares its required signals, label space, preprocessing revision, model revision, and retrospective or causal behavior.

Results carry:

- Status and withheld/fallback reason; numeric values are null when unavailable.
- Metric name, value/unit or stages, interval, and final/provisional status.
- Model, adapter, preprocessing, dependency, and configuration versions.
- Input references and hashes; signal coverage, gaps, artifact counts, and timing quality.
- Confidence semantics and raw model scores where provided. Do not label uncalibrated scores as validated probabilities.
- Runtime and error diagnostics sufficient to reproduce the decision.

Validate responses for shape, bounds, timestamps, label space, finiteness, and identity before persistence. Model failure must not prevent durable ingest, archive completion, existing metrics, or app reads.

### Job durability and concurrency

1. Acknowledge phone data according to the existing durable receipt contract. Candidate computation is never a prerequisite for that acknowledgement.
2. Schedule work from committed input snapshots and existing flush/history/recompute events. Preserve current live update behavior; do not add a wait for an hourly archive to display live HR.
3. Deduplicate jobs using user/device, interval, input generation/hash, provider/model/configuration, profile, corrections, and dependency versions. Repeated upload/replay must not create conflicting results.
4. Use durable leases or the existing equivalent, bounded retries with backoff, restart recovery, and terminal failure records. No unlimited retry loop.
5. Publish only if the relevant inputs, profile, corrections, and selected provider generation still match. An old job finishing late cannot overwrite a newer result.
6. Keep per-user data isolated. Respect deletion requests and refuse publication for deleted users.
7. Bound concurrency, input length, memory, and math-library thread counts to the measured Droplet capacity. Load each model once per worker and verify its artifact before readiness.

Keep nightly retrospective inference separate from live/provisional values. Whole-night normalization and bidirectional models can revise completed-night results; they cannot be presented as causal live predictions.

### Durable outputs

Prefer existing `algorithm_results`, `metric_runs`, and versioned B2 derived objects for candidate results. Confirm their actual schemas, uniqueness constraints, revision triggers, and retention. Use additive migrations only when existing surfaces cannot express the contract.

Shadow runs must not replace canonical daily/session values, alter the selected hypnogram, or trigger user-visible canonical revisions solely because a comparison ran. Isolate candidate values rather than overwriting an existing `algorithm_results` row for another input/version.

Canonical promotion must publish a consistent set of daily metrics, sessions, sleep details, and chart projections through the current writer and atomic sleep replacement path. Extend that boundary only if necessary. Preserve manual bounds, source arbitration, aliases, and refresh/invalidation behavior.

## 5. Signal and metric requirements

### HRV

Preserve raw intervals and within-packet order. Equal intervals in the same second can represent different genuine beats. Deduplicate retransmission by physical observation identity, not RR value alone. Verify the meaning of the packet timestamp before reconstructing beat end times, and keep gaps between independent bursts.

Use the pinned NeuroKit2 release's supported timestamp-aware inputs or an audited adapter. Inspect artifact correction behavior: some methods insert, remove, or relocate peaks. Those operations must not silently manufacture continuity or inflate valid-beat coverage. Retain before/after counts and diagnostics; keep the original waveform/interval evidence intact.

RMSSD must use only genuinely adjacent accepted intervals. A removed beat, missing packet, or uncertain burst boundary breaks adjacency. Check the library result against an independent sum-of-squared-differences calculation with the same valid-pair mask. If combining contiguous runs, combine their squared differences and pair counts rather than averaging segment RMSSDs.

Keep headline units in milliseconds. Initially preserve the documented five-minute windows, minimum 30 clean intervals, maximum 20% artifact fraction, minimum three usable windows, and median-window aggregation, subject to current-code verification. Report valid pairs and time coverage separately; those beat floors alone do not prove adequate coverage. Predefine any stricter coverage gate before benchmarking.

Do not choose deep-stage windows merely to resemble WHOOP values. Do not classify every irregular rhythm as sensor artifact. Preserve diagnostic evidence and withhold unsupported estimates when the input lies outside the method's assumptions.

### Sleep boundaries

Run HypnosPy independently on appropriately sampled HR with documented gaps and coverage. Use its HR boundary algorithm, not an unrelated actigraphy default. Verify its actual API in the pinned source. Explicitly adapt analysis-day bounds to FRWHOOP's IANA timezone and wake-date semantics.

Distinguish in-bed interval, sleep onset, final wake, naps, and wake after sleep onset. A broad sleep-period window must not count every minute as asleep. Preserve current wear/context guards and user corrections. Compare boundaries independently before combining the selected detector with the selected stager.

### Sleep staging

Require trustworthy heartbeat timing for SleepECG. Do not call its ECG peak detector on averaged HR. Store wake/REM/NREM results with that label space and compare on compatible three-class references. They remain outside the current four-stage canonical display.

For wav2sleep, reproduce the pinned checkpoint's preprocessing and supported modality masking. The current model card specifies 1,024 ECG/PPG samples per 30-second epoch, rather than a generic assumed sampling rate. Preserve actual sensor timing, use validated anti-alias resampling, and do not fill missing channels with physiological zeros. Raw WHOOP optical data must independently pass signal-quality and transfer checks. [S6]

For the HR/acceleration challenger, preserve the frozen model's feature order and normalization. Do not substitute sparse gravity for its motion features. Treat its future-context features as retrospective and gate missing-data outputs even when the upstream model produces a label. [S7]

Use existing UTC epoch alignment and the actual `awake`/`wake` normalization boundary. Preserve app hypnogram segment shape, units, and rounding. For fully scored four-stage sessions, stage minutes must sum to in-bed minutes and asleep must equal light + deep + REM.

For unscored epochs, retain missingness and unscored duration in the candidate result. Do not force gaps into light or wake to satisfy a total. If the current renderer/contracts cannot express a candidate safely, retain a qualifying legacy session or use the existing unavailable behavior. No UI redesign is required.

### Respiration and unchanged outputs

For `RR_Estimation`, inspect the checkpoint, input order, normalization, sampling, and output scale. The example input shape is `(2048, 4)`; determine its actual timebase from source rather than guessing it. Load frozen weights and execute inference only. Synchronize PPG and acceleration before windowing. [S8]

Preserve the existing RR/RSA estimator, quality gates, and provenance when that candidate is blocked or fails. Distinguish its respiratory estimate from a direct sensor measurement. Never derive an apparently precise respiration series from insufficient beats.

Keep the existing step counter rollover/reset handling, energy fallback, active RHR method, recovery weights, Rest definition, strain, temperature, and source arbitration. Changes in a selected sleep interval may legitimately change dependent metrics, but all affected outputs must use the same selected session and generation.

## 6. DigitalOcean, Supabase, and application safeguards

### Droplet discovery and worker operation

Read the current deployment files and, when authorized access is available, inspect the deployed services read-only. Record OS/architecture, vCPU/RAM/disk, supervisor or container configuration, reverse proxy/TLS, ports/firewall, persistent volumes, restart policy, worker count, and secret injection. Do not copy an IP, capacity, or service name from an old report.

Preserve the public app endpoint. Bind a new inference endpoint to loopback/private networking or use an existing internal job channel. Confirm Cloud Firewall and host firewall rules together; retain required outbound access to Supabase/B2 and artifact preparation. Do not open a new public model port. [S11]

Use pinned Python/model dependencies and a reproducible environment. Separate incompatible scientific stacks if required. Cache checksum-verified artifacts at deployment preparation time; normal inference must not download weights or run training. Fail candidate readiness clearly when an artifact is absent.

Benchmark on the real Droplet class before setting concurrency. Track worker/job age, queue depth, retries, fallback/withheld rates, processing time, peak RSS, CPU, disk growth, and ingest latency. Use existing monitoring; document missing host metrics or alerts without replacing infrastructure. [S12]

### Supabase and storage

Keep current REST/RPC access unless there is a demonstrated need for direct SQL. If adding SQL access, choose the actual supported connection mode and IP family; transaction pooling is incompatible with session assumptions and prepared statements unless configured appropriately. [S13]

Keep privileged credentials on the server. RLS bypass means server-side user identity validation remains necessary. Verify candidate tables, functions, views, and object references with anonymous and two-user tests. New security-definer functions require fixed search paths, explicit authorization, and restricted grants. [S14]

Verify the live migration lineage before proposing changes. The documents identify `whoop/supabase/migrations/` as the complete tree and a separate top-level directory as incomplete. Do not apply both blindly or drop existing objects.

Preserve private B2 raw archives, manifests, WAL durability, deterministic object IDs, and replay. For candidate evaluation, verify downloaded bytes against available hashes rather than assuming an old `ready`/HEAD check establishes content integrity. Missing/corrupt inputs must fail eligibility, not produce fallback data from another user or date.

### iOS and read compatibility

No new on-phone model execution, slower uploads, forced foreground operation, or extra BLE commands. Preserve existing native capture, HealthKit provenance, local live overlays, and background behavior. Server-side computation cannot extend iOS execution privileges; Apple's background BLE guidance requires short event handling rather than extra inference work. [S15]

Verify `/api/days`, snapshot/range routes, Supabase RPC reads, canonical aliases, hypnogram mapping, `avg_hr` chart mapping, revision changes, and caches. Record any pre-existing read-path discrepancy; fix only regressions or blockers caused by this migration.

## 7. Controlled selection, fallback, and history

Use per-metric `off`, `shadow`, and `active` modes with explicit provider/version selection. Reuse existing configuration conventions. New candidates start in `shadow` where eligible; blocked candidates remain off. Do not make every metric switch together.

- `off`: current computation and output are unchanged; candidate runtime is optional.
- `shadow`: legacy remains canonical, with isolated candidate results and paired comparisons.
- `active`: only a validated compatible provider can publish; record its actual version and fallback choice.

When an active provider fails, use a quality-passing legacy calculation for the same current input generation or withhold the metric. Never silently reuse an old value as a fresh calculation. Record the reason and selected fallback.

Algorithm changes can shift a person's baseline even without physiological change. Keep histories and baselines identifiable by metric method and upstream dependency versions. Recompute the full required trailing context with the selected method in an isolated namespace before switching a dependent recovery/watchdog consumer. If required raw history is missing, retain the compatible legacy series or explicitly preserve existing insufficient-baseline behavior; do not mix incomparable versions silently.

Persist the dependency graph for sleep boundaries, stages, HRV, respiration, RHR, recovery, and Rest. Late history or corrected bounds invalidates every dependent result, including adjacent wake-date sessions when affected.

Prepare a resumable, bounded backfill tool with dry-run selection, per-user/date limits, idempotency, and progress records. Preserve original raw objects and versioned legacy outputs. Prepare and test rollback to legacy providers, including restoration/reprojection of already promoted days and their baselines, cache invalidation, and prevention of in-flight candidate writes. Changing a flag alone is not a complete historical rollback.

Implement and validate locally/staging where available. Deliver the branch and rollout artifacts; do not merge, deploy production, or change live production defaults as part of this brief.

## 8. Validation and promotion gates

Capture baseline commands/results first. Run existing required backend, frontend model/read checks, and relevant iOS checks available in the actual repository. Historical pass counts in attachments are not current test evidence.

### Required engineering checks

| Area | Evidence required |
| --- | --- |
| HRV | Clean beats; equal same-second intervals; ms/seconds errors; dropped beat; rejected beat; duplicate burst; long gap; sparse night. Independent reference proves valid-pair RMSSD and withholding. |
| Model adapters | Pinned real inference on a suitable reference fixture; correct channels/label order/units; unsupported modality; missing/corrupt weights; malformed output; finite values and timing checks. No mocked-only success. |
| Sleep | Quiet awake-in-bed, elevated nighttime HR, fragmented sleep, off-wrist, naps, shift schedule, midnight, DST, user-edited bounds, missing epochs, and three-class isolation. |
| Failure isolation | Timeout, exception, OOM/process exit, worker restart, lost lease, database outage, B2 outage/corruption, retry exhaustion, and absent Python runtime with candidates off. Legacy ingest/read paths remain usable. |
| Concurrency/replay | Duplicate job, duplicate ingest, stale job finishing after new history, profile/edit changes during inference, deleted user, complete-night replay, deterministic results within a documented tolerance. |
| Persistence/security | Existing canonical fields unchanged in off/shadow; consistent selected-generation write; read-route and RPC parity; revision/cache behavior; anonymous and cross-user isolation on new surfaces. |
| Rollout/resources | Migration upgrade with previous app; bounded backfill resume; flag rollback plus historical restoration; representative nightly inference while normal ingest runs; latency and resource budgets met. |

Use explicit captured fixtures or permitted public references for scientific comparisons, and synthetic fixtures for deterministic failure/regression tests. Do not commit private captures or regenerate test labels from the algorithm under evaluation.

### Accuracy is separate from integration success

Before measuring candidates, record the evaluation dataset, independent subjects/nights, signal availability, model-training overlap, exclusions, primary metric, acceptable regression margins, and resource budgets. Do not select thresholds after seeing test results.

- HRV: compare paired beat/window RMSSD against independent ECG/validated beat reference, with bias, MAE, coverage, artifact behavior, and withheld fraction.
- Sleep boundaries: onset/wake and total-sleep errors, wake specificity, false sleep during quiet wake, nap precision/recall, and missingness.
- Staging: compatible-label confusion matrices, macro-F1, Cohen's kappa, per-stage performance, stage-duration bias, and withheld coverage. Collapse reference N1/N2/N3 to NREM only for the separate SleepECG comparison.
- Respiration: reference respiration MAE/bias and coverage by signal/motion quality.
- Systems: ingest and read p50/p95 latency, inference p50/p95, peak RAM/CPU, backlog drain, and recovery after failure.

Keep development/calibration subjects separate from final test subjects. Account for overlap with pretrained training sets. Report paired uncertainty using participant-level resampling when data supports it; do not count thousands of correlated epochs as independent participants.

The supplied sleep audit's metrics are synthetic, and WHOOP-reported values are comparators. Neither proves PSG accuracy. Public-dataset performance also does not establish WHOOP or rare-disease performance. Validate on target-domain data before canonical staging promotion or an accuracy claim.

A candidate passes promotion only when input/rights/artifact eligibility, contract/security/durability checks, the prespecified accuracy gate, and the measured resource gate all pass. If independent reference data is unavailable, deliver tested integration and shadow results with `unverified_accuracy`; keep production selection unchanged. Do not claim every replacement is complete when some are blocked.

## 9. Agent coordination and independent audits

Use a flat team. Only Prime spawns or reassigns agents; subagents must not spawn agents, reviewers, or additional task trees. Use up to six concurrent specialists if capacity permits, with these scoped responsibilities:

1. Current repository/deployment trace and DigitalOcean operations.
2. Supabase/storage contracts, migration and read-path compatibility.
3. NeuroKit2 HRV implementation.
4. HypnosPy boundaries and SleepECG adapter.
5. Conditional four-stage and respiration model research/adapters.
6. Independent test fixtures, scientific comparison, and integration validation.

Assign file ownership or isolated worktrees. Prime owns shared orchestration and integration. Parallelize independent research/implementation, then review dependent integration sequentially. Use existing configured models; record capability limitations rather than pretending unavailable tools exist.

Every change receives review by a different agent from its author. Use additional flat review waves covering signal/method correctness, deployment/durability, and database/app contracts. Reviewers read the actual diff and relevant source, reproduce meaningful checks, and report file/function, impact, reproduction, and severity.

Maintain a findings ledger with `open`, `fixed_pending_retest`, `verified_fixed`, and `blocked_external`. Authors repair defects; an independent reviewer verifies the repair. No finding is closed merely because the author says it passed.

Allow up to three directed review/repair rounds per change. After that, Prime resolves the remaining defect directly or reports a release blocker with evidence. The limit prevents endless delegation/review recursion; it does not convert failures into passes. Candidate failures should not stop unrelated eligible work.

Tie final audits to the exact final commit. Any subsequent code change invalidates the affected review until it is checked again. No open critical/high issue in touched behavior may be described as release-ready.

## 10. Required handoff and completion

Deliver:

- New branch, base/head SHAs, implementation commits, and a draft PR when available.
- Discovery report identifying actual runtime, deployed schema, active algorithms, data capabilities, and document/code discrepancies.
- Model registry/manifest with pinned revisions, artifact hashes, input contracts, rights, status, and deployment dependencies.
- Working eligible adapters, provider selection/fallback, durable integration, and executable tests.
- Validation report separating engineering PASS/FAIL, accuracy evidence, and blocked inputs/assets/rights.
- Independent audit findings with verified repairs tied to final HEAD.
- Exact deployment preparation, shadow evaluation, per-metric promotion, backfill, and rollback instructions.

Use a per-candidate handoff table: implemented, reference inference tested, real input eligible, shadow evaluated, accuracy verified, promotion eligible, and remaining blocker. `Skipped`, unavailable credentials, and unavailable device tests are not passes.

Completion means the branch is integrated, independently audited, tested to the available evidence, and safe to review. Production promotion remains gated per metric. State plainly which replacements can run now and which cannot.

## 11. Primary sources

Checked 2026-10-01. Recheck at implementation time and record exact revisions.

- S1: [NeuroKit2](https://github.com/neuropsychology/NeuroKit) and [timestamp-aware HRV implementation](https://neuropsychology.github.io/NeuroKit/_modules/neurokit2/hrv/hrv_time.html).
- S2: [NeuroKit2 signal and artifact correction API](https://neuropsychology.github.io/NeuroKit/functions/signal.html#signal-fixpeaks).
- S3: [HypnosPy, including its HR boundary method](https://github.com/HypnosPy/HypnosPy).
- S4: [SleepECG included classifiers and label sets](https://sleepecg.readthedocs.io/en/stable/classification/).
- S5: [wav2sleep inference implementation](https://github.com/joncarter1/wav2sleep).
- S6: [wav2sleep checkpoint and signal specifications](https://huggingface.co/joncarter/wav2sleep).
- S7: [HR/acceleration staging model, bundle, and limitations](https://github.com/akaneriya1/no-eeg-sleep-staging).
- S8: [RR_Estimation checkpoint and example](https://github.com/kazemikianoosh/RR_Estimation).
- S9: [Oxford stepcount license](https://github.com/OxWearables/stepcount/blob/main/LICENSE.md).
- S10: [Wrist energy-expenditure CNN repository](https://github.com/razmik/cnn-wrist-model-freeliving).
- S11: [DigitalOcean firewall rules](https://docs.digitalocean.com/products/networking/firewalls/how-to/configure-rules/).
- S12: [DigitalOcean monitoring](https://docs.digitalocean.com/products/monitoring/getting-started/quickstart/).
- S13: [Supabase connection modes](https://supabase.com/docs/guides/database/connecting-to-postgres).
- S14: [Supabase row-level security and privileged access](https://supabase.com/docs/guides/database/postgres/row-level-security).
- S15: [Apple Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
