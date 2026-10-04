# Nara-App core plumbing audit and repair specification

Date: 2026-10-03  
Target repository: https://github.com/Rahulvijayan123/Nara-App  
Scope: iOS acquisition, day ownership, durable storage, contextual metadata, and multi-user operation.

## 0. Evidence and execution contract

**This is an audit-and-repair specification, not a certification of the current app.** The authoring session could read the supplied architecture/protocol documents and public platform sources, but could not access the target repository: Git required authentication and public repository/raw reads were unavailable. No Nara-App branch, commit, deployment, or physical device was verified.

Rahul reports that VPS computation, cloud tracking, and five-minute RMSSD/SDNN are working; HART integration is being tested and some changes are unpushed. Preserve that work. Treat these as user-reported capabilities until traced and tested.

The source hierarchy is:

1. This specification defines required behavior and acceptance.
2. The authorized current Nara-App checkout defines existing implementation. Record branch, commit, dirty changes, and active product paths.
3. Deployed configuration, applied migrations, and device captures establish what actually runs.
4. Attached documents provide investigation leads. External Apple, WHOOP, NOOP, and Supabase sources establish platform/protocol context.

Read applicable AGENTS.md files. Inventory local work before creating an isolated branch/worktree. Do not reset, overwrite, discard, or silently exclude unpushed HART/physiology changes. If a relevant local change cannot be included safely, identify that dependency and continue independent work.

### Documentary leads to verify

The attachments cover both standalone NOOP and an older FRWHOOP tree. Do not assume Nara-App still uses SwiftUI/GRDB, React/Capacitor, Express, or the historical whoop/ paths.

| Area | Supplied evidence | Current-checkout investigation |
| --- | --- | --- |
| Day UI | Frontend.txt describes selectedDate, one-minute refreshes, revision-aware reads, and owner-tagged caches. | Trace Today selection, midnight/resume handling, chart/day labels, and stale async responses. Refreshing data does not prove date rollover. |
| Day bounds | Database-and-Storage.txt describes IANA day_bounds/local_calendar_date/profile_timezone and wake-date sleep association. | Trace every active writer, API/RPC, worker, and reader, including compatibility paths. |
| Durability | backend.md.txt describes native queues, fsynced per-user WALs, cloud outbox, and affected-day history recomputation. | Prove ACK ordering, queue ownership, callback wiring, crash recovery, and actual deployed configuration. |
| Archive completeness | FRWHOOP_PRODUCTION_AUDIT.md and storage documents describe manifests, replay, and ingest diagnostics. | Reproduce or disprove cross-midnight attribution, integrity-check gaps, and object/manifest divergence. |
| Wear | REVIEW_noop_protocol_parity.md describes NOOP contact/events absent from the then-current product decoder. | Trace supported firmware evidence through the entire product path; schema support alone is insufficient. |
| Multi-user | backend.md.txt describes userRuntime and a shared sync-queue.json; Frontend.txt describes a configured host device token. | Audit owner binding, merge keys, defaults, caches, credentials, concurrency, and signed object operations. |

Older REVIEW_ingest_replay.md findings conflict with later hardening notes. FRWHOOP_PRODUCTION_AUDIT.md explicitly describes uncommitted fixes and synthetic acceptance results. None of those findings or test counts establish the current GitHub or deployed state. NOOP's offline, account-free design does not establish cloud multi-user readiness.

For every requirement, record: ID, current source evidence, observed behavior, gap, change or justified no-change, validation evidence, and remaining device/deployment dependencies. Keep code, staging, deployed, and physical-device verification separate. Use PASS, FAIL, NOT VERIFIED, and justified NOT APPLICABLE; an unavailable environment is not PASS.

## 1. Outcome and scope

For each user and day, the app must know which day a measurement belongs to, what was acquired, where it is durably stored, what remains missing, whether the device was worn, its recorded placement, and whether the measurement is usable in that context.

Audit existing plumbing first. Repair broken wiring and missing contracts with the smallest coherent changes. Reuse existing day helpers, queues, manifests, diagnostics, and quality machinery.

| ID | Required area | Priority |
| --- | --- | --- |
| G1 | Correct Today/day rollover and day attribution | P0 |
| G2 | Durable acquisition and versioned daily reconciliation | P0 |
| G3 | Persisted wear/contact/availability state | P1; promote data-corruption consequences to P0 |
| G4 | Effective-dated wrist/bicep placement | P1 |
| G5 | Multi-user isolation, bounded concurrency, and measured capacity | P0 for isolation/durability; P1 for capacity evidence |
| G6 | Clock, ordering, deduplication, counter, and source integrity | P0 where ownership/counts are wrong |
| G7 | Minimal context/quality contract and operational visibility | P1 |

Do not add new SpO2 access experiments, physiology scores, classifiers, personalized models, or a replacement feature store. Preserve the existing five-minute HRV pipeline and HART work. Add the metadata and eligibility hooks they need. Step-counter ownership/reset bugs are in scope; inventing a new step estimator is not.

## 2. Non-negotiable invariants

- Account/device ownership survives acquisition, queues, ACKs, archives, jobs, projections, caches, and replay.
- A sample is assigned by its occurrence time under a documented calendar policy, never by upload time.
- Missing physiology is null/unavailable. Measured zero steps can be valid; absent HR/HRV is not zero.
- Disconnected, off-body, poor contact, charging, disabled sensor, and unsupported stream are different facts.
- Last known values may appear only with their timestamp/stale state; they cannot masquerade as current measurements.
- A server acceptance ACK and verified cloud archival completion are different milestones.
- Retries converge to one logical dataset. Genuine repeated beat values must remain distinct.
- Late history, corrected clocks, and context corrections revise affected outputs and invalidate dependent caches.
- Raw evidence is retained under the configured retention policy, including unsupported packets and rejected physiology, with reason accounting.
- Passing a fixture or finding a helper function does not prove deployed or physical-device behavior.

## 3. G1: Calendar days and Today

### Required time contract

Store instants in UTC. Preserve original strap/device time, corrected event time, receive time, and correction provenance.

Today means the current local calendar date in the app's authoritative reporting timezone. Default product behavior should follow the phone's local IANA timezone, synchronized to the user's reporting configuration. If the current product intentionally offers a fixed reporting zone, preserve it as an explicit setting and make the displayed zone unambiguous.

Define and document the active timezone authority, offline fallback, and travel policy before changing day logic. App, native code, backend, worker, and SQL must use the same policy. Server OS timezone must never decide user day ownership.

Use half-open UTC calendar bounds: calendar_start <= event_time < calendar_end, obtained from local midnight to the following local midnight in one IANA zone. Never derive a local day by slicing a UTC ISO string or advancing by a fixed 86,400 seconds. DST calendar days can span 23 or 25 hours. Five-minute UTC-aligned windows may remain UTC-aligned; their day allocation and displayed axes must follow the calendar contract.

Timezone changes require nonoverlapping, effective-dated policy intervals. Assign an observation using the zone policy effective at its corrected occurrence time, then intersect its midnight-to-midnight calendar interval with that policy's effective interval. These assigned segments use half-open bounds and can be truncated or share a local date label during travel. Their coverage denominators use assigned duration, with the full calendar bounds retained as metadata. Preserve original UTC observations and unaffected historical assignments. If a current attestation's boundaries change, retain the prior snapshot as a superseded revision; do not silently rewrite its evidence. If existing (user, date) keys cannot represent segments, introduce a canonical day identity/boundary version or a deterministic aggregation that proves every instant is counted once. A date string alone must not conceal conflicting boundaries.

### Required UI behavior

Separate current todayKey, following-Today state, and explicitly selected historical date.

- While viewing Today in a foreground, responsive app, switch all day labels, counters, chart bounds, overlays, and queries to the new day within one second of local midnight. This is a product acceptance target, not an Apple guarantee.
- Recompute the date on launch, foreground/resume, significant time changes, and timezone/profile changes. Update before rendering meaningful Today data after resume.
- A user browsing a past day stays on that date, with its explicit date label. Returning to Today selects the current day.
- Rollover must not depend on a new sensor reading, successful network call, database revision change, or completion of yesterday's computation.
- Offline/new-day-empty state shows the new date and available new-day data or a pending state. Do not copy yesterday's totals into it.
- Clear or re-key day-specific accumulators and live step monotonic guards. A response started before midnight must populate its own day, not overwrite the new Today view.
- Keep a visible-app next-boundary timer, but use lifecycle/time-change recomputation independently. Apple can defer significant-time callbacks while suspended. [A1]

Main-night sleep may be associated with wake date. This is separate from calendar-day sensor accounting. Preserve continuous sleep/workout session bounds across midnight; derive overlapping day totals without splitting the underlying event incorrectly.

### Acceptance

G1 passes when the same UTC fixtures produce matching day bounds in app/backend/SQL, visible Today rolls over without network data, first meaningful resumed UI is current, old-date browsing is preserved, and exact-midnight observations appear once. Include all G1 cases in section 10.

## 4. G2: Acquisition, storage, and daily attestation

### 4.1 Establish actual stream capability

Inventory the connected WHOOP generation, firmware, enabled modes, and each active stream. Record supported/unsupported/not enabled, expected cadence or duty cycle, available historical recovery, and retention.

Do not assume every channel is continuously sampled. HR history, RR beats, IMU, optical PPG, skin temperature, and sleep-only SpO2 can have different schedules and recovery capabilities. Verify the current implementation rather than importing theoretical rates from older storage estimates.

Record separate acquisition and delivery intervals. A realtime-only IMU gap cannot be declared recovered because banked HR arrived. Sensor auto-shutdown/off-body detection must be captured through supported evidence; lack of a waveform is not proof of shutdown.

### 4.2 Trace durable handoff

Trace representative records through device notification, native persistence, upload, authenticated ingest, backend WAL/queue, immutable archive, manifest, computation, database projection, and UI.

Required behavior:

1. Persist native raw/normalized records and relevant context before they can be lost to process death. Avoid BLE callbacks waiting on network or heavy computation.
2. Bind queue records to acquisition-time owner/device/stream and sequence generation.
3. Advance acceptance watermarks only after the declared crash-safe boundary. ACK ranges cannot jump over a failed record. Use explicit sparse receipts if acceptance is noncontiguous.
4. Separate phone-to-server acceptance from strap history ACK/trim semantics. Prove each against actual firmware behavior and persistence order. Do not add destructive strap trim operations to make a test pass.
5. Retain backend WAL/outbox work until the required archive/manifest reconciliation succeeds. Object upload start, task scheduling, HTTP 200 without a durable receipt, or a queued database write is insufficient.
6. Handle expired auth, connectivity loss, storage outages, partial rejection, response loss, process restart, and disk pressure without silent data loss or cross-user blockage.
7. Quarantine malformed records with bounded evidence and a reason; do not label them successfully stored physiology. Keep them from permanently blocking unrelated valid work.
8. Document crash-safe local acceptance versus permanent VPS/disk-loss guarantees. Local fsync alone does not prove replicated cloud durability. User-visible cloud-saved state must reflect verified remote evidence.

### 4.3 Apple background and locked-phone audit

Verify the actual built target, native restoration identifier/callbacks, restored peripheral delegates/subscriptions, and acquisition startup without a foreground JavaScript bridge. Background BLE modes provide limited event-driven execution. [A2]

Test system eviction separately from force quit and Bluetooth Settings separately from Control Center. Current TN3115 adds iOS 26 AccessorySetupKit qualifications to some user-action relaunch cases. Check the actual supported accessory setup and pending Bluetooth action; do not assume ASK compatibility or guaranteed relaunch. [A3]

For durable background HTTP, inspect file-backed immutable uploads, stable session identifiers, restored task/outbox reconciliation, completion callbacks, and retry-safe receipts. OS scheduling prevents a blanket instant-background or exact-midnight-upload guarantee. [A4, A5]

Audit protection/accessibility of queue files, database WAL/SHM, upload files, and credentials during screen lock and after reboot/first unlock. Keep encrypted protection compatible with the intended use and retry when protected data becomes available. [A6]

### 4.4 Versioned DayCompleteness record

Extend existing completeness/ingest verification and manifest facilities, if present. Avoid a parallel second source of truth. Persist compact reconciliation results; raw high-volume streams remain in the established archive.

Minimum logical fields, adapted to existing schema:

| Group | Required content |
| --- | --- |
| Identity/time | Owner, device/assignment scope, canonical day identity, local date, IANA zone/policy version, full calendar bounds plus exact assigned UTC interval(s)/duration, revision, as_of, input generation. |
| Capability | Stream, firmware/decoder/schema versions, enabled/supported status, cadence/duty cycle, recoverable versus realtime-only. |
| Acquisition | Observed duration/counts, raw and decoded counts, rejected/duplicate counts, missing intervals, largest gap, known off-body and unknown durations. |
| Handoff | Last known phone queue/watermarks and their observation time, durably accepted IDs/watermarks, worker/WAL/outbox backlog and oldest age. Unknown phone state stays unknown. |
| Archive | Manifest/object references, unique sample/time inventory, hash/checksum verification method/status, missing/corrupt/orphan evidence, last archived event time. |
| Projection | Expected enabled projections, input revision, completed/failed computation, algorithm version, latest projected event time, readable snapshot revision. |
| Context/quality | Wear/contact/placement coverage, metric-specific eligible/usable duration and exclusion reasons, source arbitration provenance. |

Report these separately:

- Acquisition coverage over the actual day and configured collection intervals.
- Durable accepted data versus verified archived data.
- Database projection completion.
- Context availability and analyzable physiology coverage.

Known off-body time can explain a collection pause, but cannot become measured physiology or hide whole-day missingness. Unsupported/never-enabled streams have no fabricated 100% coverage. Use explicit denominators. RR is event-based: expected beats cannot be calculated as a fixed sample rate without supporting evidence.

Counts come from canonical distinct record identities. Duration comes from clipped, unioned coverage intervals, not sample counts multiplied by an assumed cadence or sums of overlapping archive ranges.

### 4.5 Midnight closure and late data

At the day boundary, start the new UI day immediately. Mark yesterday closed-to-new-calendar-time and pending reconciliation; seal/flush remaining acquired batches and enqueue bounded, per-user work, including quiet streams with no next sample.

The server must process due boundaries in each user's zone. A global server-midnight cron is insufficient. Trigger reconciliation on scheduled due work, reconnect/resume, history completion, storage repair, and corrected inputs.

Maintain independent reconciliation/archival/projection and acquisition-gap statuses. A settled inventory means all known input at a stated revision has been reconciled. It does not claim that every possible sensor datum was acquired. Persist observed irrecoverable gaps, unknown spans, and stale/unavailable phone-watermark evidence.

Late history must revise every affected day using corrected event times and archive interval overlap. Do not select objects solely by filename date, ingest date, or period_day. A multi-day archive may remain one object; all contained days still need correct projections.

A historyComplete message alone is not full-day attestation. After a late update, invalidate affected snapshots and any dependent baseline/watchdog inputs through their existing interface. Preserve algorithm inputs/versions and user corrections.

### 4.6 Archive integrity and replay

Verify stored bytes using supported provider content-checksum evidence or an independent hash-verified read. A size-only HEAD, locally written checksum metadata, or an assumed ETag/SHA-256 equivalence is insufficient content validation. Record which paths genuinely verify bytes.

Reconcile object-without-manifest, manifest-without-object, corrupt object, stale verification, projection failure, and outbox retry. Stable immutable identities and retry-safe operations must converge without count inflation.

In an isolated test environment, discard only derived test projections/caches and rebuild from verified archives. Compare canonical sample identity/counts, day attribution, context intervals, gaps, and metric outputs with explicit numerical tolerances. A replay unavailable under the configured database transport is an open requirement, even if ordinary ingest works.

## 5. G3: Wear, contact, charging, and availability

### Independent state dimensions

| Dimension | Minimum states |
| --- | --- |
| Wear | ON_BODY, OFF_BODY, UNKNOWN |
| Contact quality | GOOD, POOR, UNKNOWN, when supported by evidence |
| Connection | Connected, disconnected, Bluetooth unavailable/unknown |
| Charging | True, false, unknown, independently of wear |
| Stream availability | Expected/observed, disabled, unsupported, temporarily missing, unknown |
| Placement | Wrist, bicep, other, unknown; implemented under G4 |

WHOOP can charge while worn. A WRIST_ON protocol label is the firmware's wear assertion; it does not establish anatomical wrist placement. Poor contact and device-asserted off-body can conflict with physical wearing, particularly with loose fit. Official WHOOP guidance distinguishes delayed sync, depletion, and off-body issues. [W1]

### Evidence, persistence, and continuity

Start with actual supported firmware events/status/contact fields. External NOOP references describe type-48 wear events and generation-specific field layouts, but current Nara wiring and device behavior must be verified. [N1]

Store each transition with owner/device/session, original/corrected event time, receive time, raw evidence/reference, firmware, decoder and interpretation versions, evidence basis, confidence category, and conflicts. Keep inferred state separate from direct device assertions; an uncalibrated raw byte is not a probability.

Trace state through decoder, queue serialization, transport allowlists, WAL, archive, interval reconstruction, API, UI, and metric eligibility. A Boolean in a live screen is insufficient.

Derive nonoverlapping half-open intervals in event-time order. Handle duplicates, out-of-order history, dropped transitions, restart, and gaps. Restore persisted evidence, but expose its age; a stale OFF_BODY or ON_BODY event cannot prove current state after an unobserved interval. Reconcile using new supported evidence or return UNKNOWN.

Never derive confirmed OFF_BODY solely from absent HR, stationary IMU, connection loss, a dead battery, or disabled capture. Preserve contradictory data and diagnostic reasons.

Audit any existing wear-detection overrides from earlier sensor work. Do not introduce overrides or undocumented command probing. The external WHOOP 5/MG command reference describes an override that can force worn state; such a mode invalidates normal wear assertions unless explicitly accounted for. [N2]

### Consumers and acceptance

Known off-body/poor-contact/stale context must reach relevant HRV, respiration, temperature, sleep, steps, HART, and watchdog inputs without fabricating values. Gates are metric-specific. Annotate post-don and state-change windows; preserve existing justified stabilization rules instead of inventing universal delays.

Physical acceptance requires labelled wear/remove/rewear captures on the actual device, plus loose-contact and Bluetooth-loss controls. Measure device detection latency and false assertions separately from pipeline propagation. Passing synthetic event tests establishes wiring, not physical detection accuracy.

## 6. G4: Wrist versus bicep placement

Implement or verify a small, synced user/device placement setting with effective-dated history:

- Minimum placement: WRIST, BICEP, OTHER, UNKNOWN.
- Optional side/accessory information, separate from location.
- Effective start/end in UTC, recorded time, owner/device, source (user or independently validated device/model), and revision.
- Historical unannotated periods remain UNKNOWN. Do not backfill all past data using today's setting.
- Placement changes made offline preserve their original effective time. Corrections affect only overlapping context/windows and downstream outputs.

**Manual placement is the required baseline.** Automatic identification is optional and cannot block this scope. A command name, IMU orientation, configured wrist side, or wear event is insufficient.

The documented WHOOP 5/MG command 84 response exposes cached on-body status with fixed location/confidence placeholders for its named firmware version. Do not interpret those bytes as bicep/wrist detection. Recheck actual generation, firmware, result status, and captured bytes before using any device field. [N2]

Audit placement applicability for:

| Component | Required handling |
| --- | --- |
| HART/activity/posture | Record model/training placement, expected axes/units/rate, model version, and whether current placement is supported. Unknown or unvalidated bicep inputs cannot claim wrist-validated accuracy. |
| Steps | Identify source and counter semantics. Official WHOOP steps are wrist-optimized; do not invent a bicep correction factor or claim nonwrist validation. [W2] |
| Optical HR/RR | Carry contact/motion quality and source provenance. Do not rescale HR, RMSSD, or SDNN solely because location changed. |
| Skin temperature | Preserve site/contact/charging and transition context. Avoid treating a site change as an unexplained physiological baseline shift. |
| Five-minute windows | Flag mixed placement/state transitions and expose per-metric eligibility rather than assigning the entire window a guessed stable label. |

Persist declared placement and any model inference separately. If automatic placement is proposed later, require labelled, held-out device evidence and measured errors before it supplies authoritative context.

## 7. G5: Multiple users and capacity

### 7.1 Identity and ownership

Resolve identity from a verified account session or individually provisioned, revocable device credential bound to owner and allowed device. Reject missing/expired auth in production. Disable silent local/demo/default-user fallback for hosted multi-user requests.

Do not trust payload owner IDs, path UUIDs, device names, or a shared build-time phone token as user identity. Validate nested rows and object/device/session references before privileged writes.

Audit every account-scoped surface: profiles/timezones, calibration/baselines, detectors, clock correlations, live state, raw/normalized queues, ACKs, WAL paths, outbox merge IDs, object keys, jobs, daily/session IDs, caches, in-flight requests, realtime topics, settings, diagnostics, exports, and existing deletion flows.

Native queues need acquisition-time ownership. When account A switches to B with pending records, A's records remain securely retained under A or quarantined pending A authorization; they cannot be reassigned to B. Cancel/ignore old async responses and subscriptions before hydrating B. Device reassignment requires ownership intervals and must not expose a prior owner's history.

### 7.2 Database, storage, and privileged routes

Verify deployed migrations, grants, RLS, views, RPCs, indexes, and composite uniqueness. Older documents identify multiple migration roots; discover the actual active lineage and applied remote schema.

Test owner allow and attacker deny for read/write/update/delete where each operation is exposed. Cover ingest, snapshots/ranges, raw upload/download completion, signed URLs, recompute, diagnostics, export, device registration, realtime authorization, and existing deletion. Include owner checks on privileged backend paths: server secret/service-role access can bypass RLS. [S1]

Restrict definer-function execution and search paths if used. Current Supabase API keys include opaque publishable/secret formats; user Auth JWTs are a separate identity layer. Inspect actual transport/headers and do not insist every server API key decode as a JWT. Keep privileged credentials out of clients. [S2, S3]

Signed URLs require owner/object-status validation and short expiry. Correct namespace strings alone do not establish access control. Deleting an account in a test environment must not remove another owner's records or allow queued work to recreate the deleted owner's data.

### 7.3 Concurrency and fairness

Document process topology and single-writer assumptions. Serialize shared-file/WAL rewrites and per-owner state safely. A shared outbox is acceptable only with correct owner-aware merge keys and atomic persistence.

Use bounded global and per-user concurrency, runtime memory limits, backpressure, and observable retry/dead-letter behavior. A corrupt object or one user's long history replay cannot block everyone else's live ingest/read.

Protect publication against stale input revisions even with one process: concurrent asynchronous runs and retries can finish out of order. An older result may remain as audit history but cannot replace the latest canonical projection/attestation. Use atomic input-revision checks at publication. If multiple processes/replicas share jobs, add atomic claims, leases/fencing, and idempotent side effects; a worker that has lost ownership cannot publish. Do not add replicas around process-local queues as a shortcut.

### 7.4 Measured capacity and upgrade decision

Inspect authorized read-only deployment evidence: running revision, CPU/RAM/disk, service count/restart policy, active features, database tier/limits/transport, storage configuration, and durable-volume/backup setup. Do not infer the current VPS size/provider from historical memory.

Measure actual enabled-stream rates, duty cycles, compressed bytes, requests/object writes, reconnect backlog, HART/HRV compute cost, reads, and retention. Separate deployed traffic from prospective high-rate PPG/IMU modes.

Use two users for functional isolation, then configurable staging planning tiers of 10, 50, and 100 active users when no launch target is supplied. These are workload scenarios, not supported-user claims. Replay realistic cadence and mix live ingest, reads, five-minute computation, midnight closure, and a 24-hour backfill. Before each run, declare stream rates, batch sizes, backlog, duration, read/ingest/processing budgets, maximum job age, recovery deadline, and headroom criteria using existing product SLOs where available. Bound test duration and report any saturated tier rather than causing uncontrolled work.

Report throughput, p50/p95/p99 latency, per-user queue/job age, outage recovery time, CPU/RSS/event-loop delay, disk/fsync behavior, DB connections/query/lock time, and storage retries. Suggested initial targets are p95 durable-ingest response <= 2 seconds from server request receipt, and p95 projection processing lag <= 60 seconds from eligibility: the later of required window closure and durable acceptance of the inputs for that revision. A five-minute HRV result is not due before its window closes. Measure sensor-to-acceptance delivery lag separately, including late banked history and OS-suspended delivery. These are adjustable product targets for a healthy staging run; explain changes and retain no-loss/isolation invariants.

For compact day reads, use an initial healthy-run p95 response budget of 2 seconds unless an existing product SLO supplies a better target. Steady-state queues must remain bounded without sustained growth, and injected-outage backlog must drain by the declared recovery deadline. Capacity passes only for the tested workload/configuration against those predeclared objectives with documented headroom. Do not relabel a failed target as passing after observing results. Lack of staging/VPS access remains NOT VERIFIED.

Recommend changes against measured bottlenecks: indexes/query tuning for DB limits, computation isolation for blocked ingestion, storage for retained backlog, or more compute for persistent CPU/RAM pressure. Include current capacity, limiting resource, upgrade trigger, and expected cost/operational impact. Do not mandate Kafka/Kubernetes/a provider migration or buy/resize infrastructure without evidence.

## 8. G6: Timing, identity, counters, and source integrity

Audit these two additional plumbing foundations before new algorithms:

1. **Clock/order/deduplication:** preserve strap time and correction history; bound timestamp uncertainty; handle phone clock changes, device reboot, sequence rollover/reinstall, delayed history, and duplicate retransmission. Dedup keys need owner, device, stream, and source generation/frame/beat identity. Timestamp-only or RR-value-only keys must not collapse distinct observations. Invalid CRC/unsupported layouts retain evidence and reason accounting, not trusted physiology.
2. **Counter/source semantics:** verify whether each step field is cumulative, daily, interval-based, resettable, or still unvalidated. Handle modulo rollover and strap restart without huge deltas. Do not carry yesterday's total through a global monotonic guard. Check HealthKit/Apple Watch/WHOOP source arbitration where active; overlapping HR/RR series cannot be concatenated into artificial physiology, and exported samples reimported from HealthKit are not independent evidence. [A7]

Changing corrected event time must invalidate affected day/window assignments reproducibly. No server-receive-time fallback may silently give uncertain history a confident day.

Step acceptance for this scope covers correct day/reset/dedup/source/placement handling. A short labelled walking/nonwalking trial can expose counter problems, but does not certify full step accuracy or justify building a new estimator here.

## 9. G7: Minimal context, quality, and visibility

Attach a consistent envelope to existing observations/derived windows, using existing schema or compact metadata:

| Field group | Minimum content |
| --- | --- |
| Ownership/input | Owner, device/source, input/archive references, schema/decoder/algorithm version |
| Timing | UTC bounds, day identity/zone policy, source/receive timestamps, clock quality |
| Availability | Coverage, missing/rejected/duplicate counts or durations, last valid time |
| Context | Wear/contact/placement and their evidence/age, charging, motion/activity when actually available |
| Qualification | Metric-specific eligibility, quality/exclusion reasons, source arbitration, provisional/final revision |

Keep quality dimensions inspectable. A single confidence number must not erase missingness, unknown placement, motion, or bad contact. Existing artifact filters remain auditable; preserve raw input and rejected-fraction diagnostics.

HART labels are optional context until valid input/model output exists. Unknown/missing IMU remains UNKNOWN, not stationary/rest. Expire old labels across gaps. Do not train/retrain HART in this task.

Make one owner-scoped diagnostic surface show day bounds, stream status, acquisition/usable coverage, wear/placement uncertainty, queue age, durable acceptance, verified archival, projection revision, largest gap, and specific blockers. Extend existing ingest verification if present. A small settings/status addition is sufficient; no dashboard redesign is required.

For existing baseline/watchdog integration, pass eligibility and missingness through its current interface. Known sensor-off/off-body intervals must not generate physiological low-value alerts. If that consumer is outside the repository, provide a tested adapter/contract and mark its end-to-end integration separately.

## 10. Acceptance matrix

Tests should exercise discovered active paths and failure boundaries. Reuse current fixtures/checks where meaningful. Every row needs evidence or a precise NOT VERIFIED reason.

| Test | Requirement | Required observation |
| --- | --- | --- |
| T01 | G1 | Foreground Today crosses 23:59:59 to 00:00 online/offline with no new sensor data; <= 1 second rollover; yesterday preserved. |
| T02 | G1 | Suspended across midnight or several days: first meaningful resumed Today is current before network catch-up. |
| T03 | G1 | Explicit past-day selection remains selected; Today action returns to current date. |
| T04 | G1 | Cache hit/unchanged revision and a delayed prior-day response cannot block or reverse rollover. |
| T05 | G1/G2 | Exact-midnight and cross-midnight/multi-day history batch updates every correct day once; archive label does not control attribution. |
| T06 | G1/G6 | America/Los_Angeles spring/fall DST, UTC, Asia/Kolkata, travel/date-line and clock-change fixtures agree across active app/backend/SQL paths. |
| T07 | G1/G2 | Continuous sleep/workout spanning midnight keeps session bounds; calendar totals and wake-date sleep display remain correct. |
| T08 | G2 | Quiet day end plus offline phone/storage outage leaves durable pending work; retry completes without fabricated full acquisition. |
| T09 | G2/G6 | Kill/restart around append, ACK, upload, verification, manifest, projection, and queue trim; accepted sample identities/counts survive. |
| T10 | G2/G6 | Lost ACK, duplicate/reordered batch, device reboot and sequence reset converge without dropping distinct beats or inflating counts. |
| T11 | G2 | Same-size corruption, orphan object, missing object, failed projection/outbox retry prevent false verified completion and are reconciled/quarantined. |
| T12 | G2 | Test-only derived-data wipe/replay reproduces identities, days, context, coverage, and outputs within declared tolerances. |
| T13 | G2 | Realtime-only lost IMU/PPG remains missing when banked HR is recovered; disabled/unsupported streams have truthful status. |
| T14 | G2 | Physical locked-phone collection, app eviction/crash, force quit, reboot/first unlock, Settings/Control Center Bluetooth, and network transitions have separate capture/delivery evidence. |
| T15 | G3 | Physical wear/remove/rewear captures supported device evidence, transition latency, durable intervals, and cold-start recovery. |
| T16 | G3 | Worn strap with Bluetooth off/out of range is not falsely declared nonwear. |
| T17 | G3/G7 | Loose contact, charging while worn/off-body, stale/missing transitions, and contradictory evidence stay distinct and do not generate fake physiology. |
| T18 | G3/G6 | Duplicate/delayed wear events and clock corrections replay deterministically without negative/overlapping intervals. |
| T19 | G4/G7 | Wrist-to-bicep change mid-window, offline change, and history correction retain effective times and flag mixed/unsupported context. |
| T20 | G4 | Malformed/failed status response and WHOOP 5 placeholder fields do not produce automatic placement certainty. |
| T21 | G5 | Two users with matching timestamps/sequence values, different devices/zones/profiles, and same-date outbox writes during a DB outage remain isolated through retry and restart. |
| T22 | G5 | Forged/nested mixed-owner device/object/session links, expired/invalid/wrong-project JWTs, revoked device tokens, no auth, and cross-user RPC/signed URL/recompute/realtime access fail without owner writes or ACK advancement. |
| T23 | G5 | A-to-B account switch with every queue type pending and A's request in flight never displays or uploads A data as B. |
| T24 | G5 | A's large backfill plus a failing job does not starve B's live writes/reads; bounded work and recovery are observable. |
| T25 | G5 | Existing deletion/device-reassignment flows isolate owners and prevent old queued jobs/history from leaking or resurrecting removed data. |
| T26 | G5 | Staged capacity report includes workload/tier, revision, latency/freshness, queue lag, resource headroom, recovery, and justified upgrade decision. |
| T27 | G6 | Step counter resets/wraps/reconnects and midnight rollover preserve legitimate deltas without yesterday carryover or huge jumps. |
| T28 | G6/G7 | Active HealthKit/source overlap and export/reimport preserve provenance, deletion handling, and separate series; unavailable is not zero. |
| T29 | G7 | Known bad/off-body data is retained as evidence but excluded by relevant consumers; missing HART is not rest; stale live values are labelled. |
| T30 | G2/G7 | Diagnostics and resumed UI expose the same day/input revision, coverage, pending state, and source/context reasons after repair/replay. |
| T31 | G2/G5 | An older input revision finishes/retries after the newer run: latest projections/attestations remain newer. With shared workers, an expired/fenced worker also cannot publish. |

Synthetic acceptance establishes deterministic wiring. Real iPhone/WHOOP captures establish platform/device behavior. Staging establishes multi-user and capacity behavior. Deployment evidence establishes what is live. Do not substitute one for another.

## 11. Execution and deliverables

### Parallel workstreams

Use several subagents, normally five to seven within available concurrency:

1. Current-code inventory and day UI/calendar contracts.
2. Native BLE/lifecycle/locked-phone capture and durable upload.
3. Archive reconciliation, daily attestation, and replay.
4. Wear/contact/placement and minimal context propagation.
5. Auth/device ownership/database/storage isolation.
6. Worker fairness, capacity, diagnostics, and load evidence.
7. Independent integration/audit work as slots become available.

Give each a scoped file/worktree ownership and bounded question. Parallelize investigation; coordinate shared schema, authentication, time helpers, and queue contracts centrally. Freeze those contracts before independent implementations depend on them.

Each subagent returns a short evidence slice: requirement IDs, source/lines, conclusion, changed files, validation commands/results, unresolved risks, and recommended next work. Store full traces/results in files so the root can inspect relevant slices without ingesting entire transcripts.

The root owns the requirement matrix and integration. For each slice, decide whether to accept, inspect source, launch focused research, assign a repair, or request an independent audit. Do not accept a subagent's assertion as sufficient evidence.

### Repair and independent review loop

Establish current behavior, fix confirmed gaps, integrate changes, and run relevant tests. Then have auditors who did not author the changes challenge day ownership, ACK boundaries, late data, owner isolation, state continuity, and deployment assumptions.

Every material finding needs a reproducible failure or precise source trace, a repair, targeted regression validation, and re-audit. Repeat until in-scope code/integration findings are closed. If access prevents physical/deployed validation, finish all independent implementation/checks and identify the exact blocked evidence; do not declare production readiness.

Produce in the repository's documentation location:

- audit.md: source baseline, active architecture, requirement matrix, verified existing features, findings, repairs, and unresolved device/deployment checks.
- acceptance.md: section-10 results with commands, environment/revisions, compact outputs, and captured evidence references.
- capacity.md: measured tier/limits, backlog recovery, bottlenecks, upgrade triggers, and unverified live assumptions.
- rollout.md: ordered additive migrations/config changes, compatibility, deployment checks, verification, and rollback.
- Focused code/migrations and regression checks required for the repaired contracts.

Use existing scripts after discovering the current tree; historical test command names are hints, not instructions to run nonexistent files. Avoid broad refactors and implementation-mirroring tests. Do not rewrite metric formulas under a plumbing change.

This run authorizes local/staging implementation and reviewable deployment preparation. It does not authorize destructive production data operations, live migrations/deployment, infrastructure purchases/resizes, or firmware experiments. Prepare the concrete rollout and finish all available checks before seeking any additional authorization that is actually necessary.

### Completion gate

Implementation is complete when every applicable in-scope code requirement has evidence-backed acceptance or a precise external blocker, independent audit findings are repaired and rechecked, and the rollout is reviewable.

Production readiness requires the relevant staging, actual device, applied schema, and deployed revision evidence. State separately what is code-verified, device-verified, staging-verified, and deployed-verified. A remaining P0 failure or missing essential isolation/durability proof blocks a production-ready claim.

## 12. Sources

Sources were checked on 2026-10-03. Recheck current platform/version-specific guidance during execution. Modern Apple/WHOOP pages sometimes exposed only page shells; relevant official text was retrieved through indexed primary-source results. NOOP references are public fork documentation, not firmware certification or current Nara code.

### Supplied context

System-Overview.txt; backend.md.txt; Database-and-Storage.txt; Frontend.txt; Packets-and-Decoding.txt; Algorithms.txt; FRWHOOP_storage_system.md; FRWHOOP_PRODUCTION_AUDIT.md; REVIEW_ingest_replay.md; REVIEW_frontend_persistence.md; REVIEW_noop_protocol_parity.md. ANALYTICS.md, ARCHITECTURE(1).md, and DATA_MODEL.md describe standalone NOOP and must be interpreted in that scope.

FRWHOOP_personalized_physiology_learning_system.md is a future downstream consumer proposal, not an implementation requirement for this task.

### Apple

- **A1:** [Significant time changes](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationsignificanttimechange(_:)); [Calendar day intervals](https://developer.apple.com/documentation/foundation/calendar/dateinterval(of:for:)); [System timezone changes](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nssystemtimezonedidchange).
- **A2:** [Core Bluetooth background processing and restoration](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
- **A3:** [TN3115: Bluetooth restoration relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules), including the iOS 26 revision.
- **A4:** [Background URLSession configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)); [Background transfer lifecycle](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).
- **A5:** [isDiscretionary scheduling](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary).
- **A6:** [File protection after first unlock](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication).
- **A7:** [HealthKit privacy and availability](https://developer.apple.com/documentation/healthkit/protecting-user-privacy); [Source revision](https://developer.apple.com/documentation/healthkit/hkobject/sourcerevision); [Anchored incremental changes](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery).

### WHOOP and NOOP interoperability

- **W1:** [WHOOP missing-data guidance](https://support.whoop.com/s/article/Missing-Data).
- **W2:** [WHOOP steps and placement guidance](https://support.whoop.com/s/article/Steps).
- **N1:** [NOOP public fork: protocol implementation](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_IMPLEMENTATION.md).
- **N2:** [NOOP public fork: generation/firmware-bounded command contracts](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_COMMANDS.md). WHOOP 5/MG details cited here are bounded to the document's 50.42.1.0 contract, not assumed applicable to every strap.

### Backend/platform

- **S1:** [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security).
- **S2:** [Supabase API keys](https://supabase.com/docs/guides/getting-started/api-keys).
- **S3:** [Supabase database functions](https://supabase.com/docs/guides/database/functions).
- [Supabase connection management](https://supabase.com/docs/guides/database/connection-management).
- [DigitalOcean monitoring metrics](https://docs.digitalocean.com/products/monitoring/concepts/metrics/), if DigitalOcean is the actual host.
