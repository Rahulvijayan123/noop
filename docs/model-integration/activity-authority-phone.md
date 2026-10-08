# Activity authority: phone side (Spec 01 §2)

Branch `spec01/activity-phone-20261007` (from the integration merge `49bb94039`). The worker, database, route and
shared-policy side is `activity-authority.md` on `spec01/activity-20261007`; the parent folds this section into it.

## Phone side

### What changed and why

Two defects at the base:

1. `GaitWindowStore.evidenceConfig(model:)` built a `mode: .production` ElderNet config whatever the stored row's
   `mode` was, and `Repository.activityBaseDecoderConfig` installed it whenever its own hard-coded pins matched. A
   shadow or candidate `/gait-windows` row could therefore shape the phone's own decode (after round 1 the decoder
   refused the unrecorded windows, but the config, its cache tag and the decision were still the phone's, not the
   policy's).
2. `AppModel.syncGaitWindows` ran inside the success path of the HART (`/activity-windows`) fetch, so any HART
   failure (404 on an older server, a timeout) skipped the gait sync.

Now:

- The phone never builds an expert evidence config. `GaitWindowStore.Pins` and `evidenceConfig(model:)` are gone,
  and `activityBaseDecoderConfig` carries no expert entries. Every decode the wearer sees goes through
  `ActivityPhoneEvidence.canonical(...)` (`Strand/Data/Repository+ActivityContext.swift`), which builds the shared
  policy's sources from the stored rows, calls `ActivityExpertSelection.select(...)` and decodes with
  `.canonical(...)`.
- HART and gait windows are fetched by one pass object, `ActivityWindowsSync` (`Strand/Data/ActivityWindowsSync.swift`),
  which runs each fetch on its own and allows one pass at a time.

### How the phone uses the shared policy

`ActivityPhoneEvidence.canonical(input, base:, encoders:, gait:)` for a decode span `[dayStart, dayEnd)`:

| Policy argument | Built from |
|---|---|
| `revisions` | `ActivityEncoderWindowStore.inputRevisions(from:to:)`: each stored HART UTC day's `input_revision` (days that do not record one are absent, which the policy does not treat as a mismatch). |
| `gaitQuality` | `GaitWindowStore.sources(from:to:)`: one `GaitQualitySource` per stored UTC day with windows ending in the span; `releaseMode` = the record's `recordedRelease` (below), `route: .standalone`, pins / prior / input revision / day from the record. |
| `motionHeads` | always `[]` (no phone readback; see "Motion heads"). |
| `embeddedGait` | `EmbeddedGaitSource(windows: input.gaitWindows, releaseMode: ActivityEncoderWindowStore.embeddedGaitRelease(...))`: the HART-embedded ElderNet windows stored in `hart-windows-1`, at the weakest release the overlapping HART days record (`embedded_gait_release_mode`; missing = shadow). |

`selection.canonical(input, base:)` then installs only production channels and strips every other expert entry from
both the input and the config. The cache key (`"<reads>@<config.cacheTag>"`) uses that canonical config, so the
on-disk ActivityContext of a day is keyed by what actually shaped it; `cachedActivityContext(dayStart:)` computes
the same config for its instant draw.

Effect with today's server rows (all `shadow`/`candidate`, no pins in the route): no ElderNet, motion-head or
embedded-gait evidence reaches the phone's decode, i.e. it equals HART alone plus the strap's streams. This is a
visible change only on days whose stored `hart-windows-1` still carries HART-embedded `g_*` windows (the worker
disabled that route in round 1, `ActivityPythonService.Config.hartChild`); those windows used to shape the decode
unconditionally and now read as shadow, as the policy says. The worker's published stream day makes the same
change on `spec01/activity-20261007` (`ActivityContextDays.buildStreamDay` decodes with
`select(embeddedGait:).canonical(...)`, commit `3a685526e`), so phone and server still decode the same evidence.

There is no experimental preview on the phone (no UI decodes a candidate arm), so none was added. The walking card
(`GaitWindowsCache`, `WalkingInsightsSection`, `DayActivityDetailViews`) shows ElderNet gait quality from the
route's newest row; it is quality reporting, not activity decoding, and is unchanged (see "Requests to parent").

`Repository+ActivityPersonalProfile.swift` (not owned here) still gates gait windows on
`activityBaseDecoderConfig.gaitQuality`, which is now always nil, so the personal-profile fit runs without ElderNet
(as it effectively did at the base, where the decoder refused the unrecorded windows).

### Stored fields and migration

All new fields are optional Swift properties with nil defaults, so the synthesized `Decodable` reads records written
before them (missing keys decode as nil). Nothing is rewritten on upgrade; a day is replaced the next time the route
sends it at a new revision.

`GaitWindowStore.DayRecord` (`OpenWhoop/GaitWindows/<owner>/<device>/<day>.json`):

| Field | From the route | Old record |
|---|---|---|
| `mode` (existing) | `mode` | as stored |
| `releaseMode` | weaker of `release_mode` and `authority.release_mode` | nil |
| `inputRevision` | `input_revision` (else `authority.input_revision`) | nil |
| `pinnedModelVersion`, `pinnedWeightsDigest`, `gaitPrior` | `authority.pinned_model_version`, `.pinned_weights_digest`, `.gait_prior` | nil |
| `producerUse`, `producerReason` | `authority.use`, `.reason` (informational; the policy is re-run) | nil |
| `identity` | `identity` (must name the same `model_version` / `weights_digest` as `model`, else the day is not stored) | nil |

`recordedRelease` = `ActivityReleaseMode(recorded: mode)` lowered to `ActivityReleaseMode(recorded: releaseMode)` when
present: missing or unknown text is shadow, and a `release_mode` above `mode` cannot raise it. An old record (mode
`candidate`, no pins, no prior) therefore reads as candidate and the policy lowers it to shadow (`model_not_pinned`);
it is never production. A day the route answers `unchanged` with a lower `release_mode` than stored is lowered in place
(`GaitWindowStore.lowerRelease`), never raised. `save` compares every field except the windows' JSON text, so a demoted
or newly pinned row at the same revision is stored.

`ActivityEncoderWindowStore.DayRecord` (`OpenWhoop/ActivityWindows/...`): new `inputRevision` (`input_revision`),
`releaseMode` (`release_mode`, kept for inspection; HART is the production producer and is not gated here) and
`embeddedGaitReleaseMode` (`embedded_gait_release_mode`). Old records: nil, nil, nil (embedded gait reads as shadow).

`ServerScoreRepository.ActivityWindowsDay` / `GaitWindowsDay` carry the same fields (all optional, nil from a server
without them). `revisionNumber` accepts the int64-as-string the route sends (or a number; booleans and fractions
rejected).

### Fetch independence

`AppModel.syncActivityWindows` keeps its guards (cloud scoring authoritative, owner of the strap data, a read
candidate) and then calls `ActivityWindowsSync.run(hart:gait:)`:

- `hart` and `gait` each run inside their own `do/catch`; a throw is recorded in the outcome (`hartFailed`,
  `gaitFailed`) and the other still runs. Order: HART, then gait (sequential, so at most one request of each per pass).
- One pass at a time: a call while a pass is in flight returns nil (dropped, not queued); a new pass starts only
  `activityWindowsRefreshSeconds` (300 s) after the last one started. Sign-out calls `reset()` (the old
  `activityWindowsSyncedAt = nil`); an in-flight pass then finishes and its results are dropped by the per-fetch
  account checks.
- Materialization and the personal-profile refit are requested when either store changed.

### Motion heads

No phone store or route method: motion-head rows are shadow/candidate only, so the canonical decode could not use
them, and the worker side added no route (its doc, "Motion heads"). `ActivityPhoneEvidence` passes
`motionHeads: []`. When a production promotion adds a route with the `/gait-windows` fields, the extension point is a
`MotionHeadsWindowStore` beside `GaitWindowStore` whose `sources(from:to:)` feeds `motionHeads:` the same way.

### Compatibility

| Server | Phone behaviour |
|---|---|
| Today's (no release fields) | Gait rows stored with `mode` only; policy reads them as shadow (`model_not_pinned`); canonical decode = HART alone. HART days stored without revision; embedded gait shadow. |
| Release-authority route (`20261008100000` + new `serverScores.ts`) | Fields stored; rows are at most candidate (`release_mode` never production), so canonical decode is still HART alone; a candidate arm would be admitted by the policy but nothing on the phone decodes one. |
| A future production row | Admitted to the canonical decode only with pins, a prior and a matching input revision (`testAProductionRowWithItsPinsShapesTheCanonicalDecode`). |
| Old phone against the new route | Ignores the new fields; its own base defect remains on that build (it is fixed only by shipping this one). |

### Tests

New `StrandTests/ActivityPhoneAuthorityTests.swift` (macOS):

- `testShadowAndCandidateGaitRowsCannotChangeThePhonesDecode`: replay through the real stores
  (`ActivityEncoderWindowStore` with HART windows, `GaitWindowStore`) → `ActivityPhoneEvidence.canonical` →
  `ActivityContextDayBuilder.update`; the sorted-key JSON of the document and the cache tag are identical with no
  gait rows, shadow and candidate rows from today's server, pinned shadow/candidate rows from the new route, and a
  candidate row whose `release_mode` claims production. Sensitivity check: the pinned candidate row decoded as a
  candidate arm does change the document.
- `testAProductionRowWithItsPinsShapesTheCanonicalDecode`: positive control; and a row from another input
  revision is not combined.
- `testEmbeddedGaitWindowsInHartRecordsStayOutOfTheCanonicalDecode`: HART-embedded windows at nil / shadow /
  candidate / unknown release decode identically to a HART day without them.
- `testRecordsStoredBeforeTheReleaseFieldsReadAsTheirRecordedModeNeverProduction`,
  `testHartRecordsStoredBeforeTheFieldsReadWithoutRevisionAndShadowEmbeddedGait`: old on-disk JSON layouts.
- `testAnUnchangedDayCanOnlyBeLoweredInPlace`.
- `testGaitRouteParsingOldAndNewServer`, `testActivityWindowsRouteParsingCarriesRevisionAndReleases`.
- `testGaitFetchRunsWhenHartFetchFails`, `testOnePassAtATime`.

### Test results

All with `DEVELOPER_DIR="/Volumes/External SSD/Xcode.app/Contents/Developer"`, after `xcodegen generate`,
derived data under `_build-scratch/spec01/activity-phone/`:

- `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath …/dd-mac
  -only-testing:StrandTests/ActivityPhoneAuthorityTests -only-testing:StrandTests/ActivityImuCaptureTests
  -only-testing:StrandTests/ActivityPersonalProfileStoreTests`: 25 tests, 0 failures (10 + 9 + 6).
- Same with `-only-testing:StrandTests`: 3216 tests, 13 skipped, 11 assertion failures in 3 test cases:
  `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` (known time-zone failure) and
  `ActivityCalibrationSessionTests.testBeginWithAnEmptyProtocolEndsCleanly` /
  `.testStepsChainBackToBackAndEveryActivityEndsWithDone`. The two calibration tests are not in COMMON.md's known
  list but fail identically (22 tests, 10 failures) with every file of this branch reset to `49bb94039`, so they
  were already failing at the base and are not caused by this branch (they touch none of its code). The other two known
  time-zone tests passed in this run.
- iOS: `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination generic/platform=iOS
  -derivedDataPath …/dd-ios CODE_SIGNING_ALLOWED=NO build`: `** BUILD SUCCEEDED **`.

Not verified: a real device against the deployed or the new route (no deploy, by rule); the worker's route
fields were read from its committed `serverScores.ts`/doc at its final `e25dc3fb0` (route unchanged since `3a685526e`) and are matched by the parsing tests
here, not by an end-to-end request.

### Requests to parent

1. Fold this section into `activity-authority.md` (worker side owns that file).
2. `Strand/Data/Repository+ActivityPersonalProfile.swift` (not owned here) still reads gait windows through
   `activityBaseDecoderConfig.gaitQuality` + `GaitWindowStore.trackInput`. The config no longer carries an ElderNet
   entry, so the personal-profile fit now runs without ElderNet (at the base the decoder already refused those
   unrecorded windows). If a production gait row should ever reach the fit, route that input through
   `ActivityPhoneEvidence.canonical(...)` there (a few lines; no change needed for today's rows).
3. Owner decision: the walking card (`GaitWindowsCache`, `WalkingInsightsSection`, `DayActivityDetailViews`) shows
   ElderNet gait quality from the newest row of any mode. That is quality reporting, not activity decoding, and is
   unchanged here; say if it should be limited to candidate or production rows.
4. After the worker branch merges, the hand-written parsing of the `authority` block in
   `ServerScoreRepository.gaitWindowsDays` can be replaced by `ActivityExpertAuthority` (added on
   `spec01/activity-20261007` in `09790adab`, not in this tree, so not used here); field names and semantics already
   match its final doc (`e25dc3fb0`).
5. `ActivityCalibrationSessionTests` (2 tests) fail at `49bb94039` with no change of this branch involved; please
   assign to whoever owns `Strand/Collect/ActivityCalibrationSession.swift`.
