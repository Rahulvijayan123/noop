# Sensor biomarkers: independent adversarial review (spec-31)

Reviewer: independent, read-only except for this file. Range `1325319..adf66b2` on
`feat/sensor-biomarkers-20261006` (worktree `/Volumes/External SSD/Nara Whoop App V2/nara-sensor-biomarkers`).
Spec: `/Volumes/Untitled/Downloads/spec-31.md` (§6-11). Contract: `docs/sensor-biomarkers/CONTRACTS.md`.
Reviewed 2026-10-07.

## Verification actually run (this reviewer)

| Check | Command | Result |
| --- | --- | --- |
| Python sidecar | `cd Tools/InferenceWorker && UV_LINK_MODE=copy uv run pytest -q` | **515 passed, 0 failed, 0 errors, 0 skipped** (re-run `-v`: `515 passed, 431 warnings in 92.08s`; the 512-dot reading is a head-truncation artifact of the capture) |
| CloudWorker build | `cd Tools/CloudWorker && PKG_CONFIG_PATH=<homebrew libpq/zlib/openssl@3/zstd> swift build` | **rc 0** |
| Edge tests | `cd supabase/functions && EDGE_TEST_ARTIFACTS=/tmp/edge-test-artifacts deno test --allow-all tests/sensor_biomarkers_sql_test.ts tests/sensor_biomarkers_route_test.ts` | **9 passed (11 SQL steps + 8 route), 0 failed** |
| Artifact hashes | Downloaded the 5 pinned upstream bytes and sha256'd them | All 5 match the manifest AND the spec: tremor `4be2ac2b…c5b0e` (1475 B), gait `f2309bb8…cc25` (11 497 247 B), gait-filter `94068bca…b45f4` (3915 B), deepbeat `6df126f8…eee3` (1 502 052 B), siamaf `a141b91c…176be` (10 915 597 B). The staged root `/tmp/frwhoop-sensor-biomarkers/models` has the same bytes. |
| Real-weight execution | DeepBeat/SiamAF/ParaDigMa tests ran with the staged real weights during the suite (keras/torch warnings confirm real load); upstream-parity asserts reference predictions to `<=1e-6` | Real models, not mocks |
| iOS/macOS StrandTests | NOT run by this reviewer (parent-verified; slow). Source-reviewed only. | see P1 |

The parent-claimed numbers (`512 passed` in the task brief) are actually **515 passed** — the
implementation's `docs/sensor-biomarkers/validation.md` claim of "515 tests, 0 failures, 0 errors,
0 skipped" is accurate.

---

## Findings (ranked)

### P1-1 — iOS client and the edge route speak different contracts; the descriptive tier cannot integrate end-to-end

**Where.** `supabase/functions/_shared/serverScores.ts:380-386` returns
`Response.json({ days, identity })` and 404s (`not_found`) when no day row exists. The Swift client
`Strand/Push/SensorBiomarkerRepository.swift:321-335` (`parse`) only accepts an envelope whose
`envelope["sensor_biomarkers"]` member is the document (or a bare top-level document with
`families`), and `:227-241` (`refresh`) feeds the raw server envelope straight into `parse`.
`looksLikeDocument` (`:372-374`) requires a top-level `families`/`schema_version`, which the real
`{ days, identity }` envelope never has.

**Consequence (concrete counterexample).** Real call `GET /scores/sensor-biomarkers?day=2026-10-06&deviceId=whoop-…` returns
`{ "days": [ { "day": "2026-10-06", "document": { …families… } } ], "identity": … }`. Swift:
`envelope["sensor_biomarkers"] == nil` → `looksLikeDocument` false → **throws
`ReadError.malformed("missing sensor_biomarkers")`**. The store then renders `.failed`, for *every*
day, even when documents exist. Second half of the same defect: a day with no document returns HTTP
404 from the route (`serverScores.ts:385`), while the client's only no-data path is a 200 with
`sensor_biomarkers: NSNull` (`SensorBiomarkerRepository.swift:334-335`); 4xx is not mapped to
`.noData` (`SensorBiomarkerStore.load`, `SensorBiomarkerRepository.swift` `load` → `.failed`).
So a real deployment shows "failed" instead of "Not enough usable data".

**Why tests pass anyway (evidence honesty).** Every iOS test stubs the *wrong* server shape:
`StrandTests/SensorBiomarkerTests.swift:231` `BiomarkerStub.body = ["sensor_biomarkers": fullDocument()]`
and `:285` `["sensor_biomarkers": NSNull()]`. The route tests (`sensor_biomarkers_route_test.ts`)
assert the *actual* `body.days[…]` shape. The two suites never exercise each other's contract;
`validation.md` §5.7 explicitly admits no device-path test ran. So spec 10.6 ("iOS rendering of
valid/partial/withheld results") is satisfied only against a mock that the real server cannot
produce.

**Fix (parent decision — both files are owned by different workers).** Make one side match the
other: either the route serves the document envelope the client parses, or the client parses the
`days` array (and treats 404 as `.noData`). Add one cross-layer fixture test that feeds the *real*
route test fixture into the Swift `parse`.

**Severity.** P1. Blocks the descriptive tier end-to-end; nothing else in the stack is affected.

### P2-1 — `pulse_shape.eligible_seconds` is a pulse count, not seconds

**Where.** `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/ppg.py:487`:
`eligible_seconds=float(sum(c["accepted"] for c in configurations))` — the number of accepted
*pulses*, not seconds. Every other family reports real seconds (`imu.py`, `ppg.py` quality path).

**Consequence.** CONTRACTS §3 defines `eligible_seconds` as seconds; the iOS coverage line renders
`duration(eligibleSeconds)` (`Strand/Screens/SensorBiomarkersSection.swift` `coverage(family:)`),
so a 1234-pulse day shows "Eligible 20m 34s". The SQL publish validates `eligible_seconds >= 0` but
not its meaning. No test asserts this field for pulse_shape, so the wrong units are unpinned.

**Counterexample.** 5 minutes at 24 Hz with 7 accepted pulses → document says
`eligible_seconds: 7` while `observed_seconds: 300`. Coverage then reads "Observed 5m · eligible 7s".

### P2-2 — Lane merges quantile measurements from a single best-coverage request, not the day distribution

**Where.** `Tools/CloudWorker/Sources/frwhoop-worker/SensorBiomarkerLane.swift:752-779` (merge).
Count/seconds keys are summed, but every other measurement key (median/p95/iqr/fraction/percent)
is taken verbatim from the request with the largest `observedSeconds`.

**Consequence.** Spec §8 defines `enmo_median_mg`/`enmo_p95_mg` as the "distribution of valid
5-second epochs", `template_similarity_median` over the pooled windows, etc. On a multi-chunk day
(a day splits into many 5-minute requests), the published median/p95 is **one chunk's** median, not
the day's median; additive `_seconds`/`_count` keys are summed from all chunks. The merged document
is therefore internally inconsistent (e.g., `low_movement_seconds` summed over the day while
`low_movement_fraction` is one chunk's fraction). The behavior is pinned by
`FamilyStageMergeSumsCoverageAndCountsTakesQuantileFromBestCoverage`, so it is a deliberate choice —
but it deviates from the contract's per-day-distribution semantics and is a silent accuracy loss on
any day longer than one request. `validation.md` does not disclose this aggregation semantics.

**Recommendation.** Either have the sidecar emit pooled per-day quantiles (add a per-family
"distribution summary" stage the lane passes through), or document the best-coverage-chunk
semantics in CONTRACTS §4/§8 and accept it for v1.

### P2-3 — PPG descriptive families are always withheld on the real wire (anchor absent), and no lane test covers the PPG path

**Where.** `SensorBiomarkerInputs.swift` `PpgCodec` (lines 412-417: "the absolute optical anchor
(`baseCode`) is NOT carried on this wire") and the lane builds `PpgWaveformInput` **without**
`baseCode` (`SensorBiomarkerLane.swift:451-453`), so `reconstructSecond` withholds
every second `missing_ppg_anchor`. The `PpgWaveformInput(whoopSample:)` path that *can* carry an
anchor is never used by the lane.

**Consequence.** In production the descriptive tier delivers only `movement` + `oscillation`;
`ppg_quality`, `pulse_shape` and `perfusion_research` are always withheld until a codec revision
ships the anchor. This is documented and fail-closed by design (`validation.md` §5.1, spec Phase A
accepts it), so it is not a correctness defect — but it is the single largest *scope* gap of the
descriptive tier, and **all lane-level integration tests are IMU-only** (`SensorBiomarkerLaneTests.swift`,
every test passes `ppgRuns: []`), so the always-withheld PPG behavior is never exercised end-to-end.
W1's unit tests cover the anchor-present path only.

### P3 findings

1. **Reason vocabulary drift.** Reasons used in code but absent from CONTRACTS §3's vocabulary:
   `blocked_input` (`provider.py:263,284`; `rhythm/provider.py:61`), `provider_error`,
   `provider_withheld` (`SensorBiomarkerLane.swift` parseEnvelope), `not_ready`
   (`rhythm/provider.py`). They flow into `sensor_biomarker_days.withheld_reasons` and the iOS
   fallback renders them as "Not enough usable data." — safe, but the contract should either list
   them or forbid them.
2. **Enqueue fingerprint overwrite under READ COMMITTED races.** `enqueue_sensor_biomarker_day`
   MERGES `input_object_ids`/`input_digests` (union) but always REPLACES `fingerprint` with the
   incoming value. A racing reconcile that enqueues a per-object subset after the job exists leaves
   `job.fingerprint` momentarily inconsistent with `job.input_digests`; the day row's
   `job_fingerprint` can then disagree with its `input_revision`. Self-heals on the next reconcile
   (fingerprint change → revision bump). Inherited from the `activity_context` pattern; no security
   impact.
3. **`rhythm_shadow` provider_revision is hard-coded to `deepbeat/1.0.0`** even when only SiamAF is
   enabled (`SensorBiomarkerLane.providerRevision`, and `PROVIDER_REVISIONS["rhythm_shadow"]`).
   Cosmetic metadata inaccuracy for a shadow family.
4. **Uncalibrated movement family renders odd coverage.** `compute_movement` with an unresolved
   gravity offset returns `status:"ok"` + ENMO measurements + `eligible_seconds: 0.0`; iOS renders
   "Observed 11h · eligible 0s". Honest, but visually confusing; consider `eligible_seconds: null`.

---

## Security review (spec §8, CONTRACTS §5/§6)

| Item | Verdict | Evidence |
| --- | --- | --- |
| RLS on `sensor_biomarker_days`/`sensor_biomarker_jobs` | **Correct.** Owner select-only; writes service-role only. Negative control runs through real PostgREST roles (cross-owner read = empty, own read = 1 row). | `migration:20261007140000` `sensor_biomarkers_select_own` policy; `sensor_biomarkers_sql_test.ts` "RLS" step (passed). |
| Cross-owner reads via the route | **Blocked twice.** `findNoopDevice` scopes the device resolution to `user_id=eq.<credential owner>`; the read adds `user_id=eq.<owner>&device_id=eq.<resolved>`; RLS backs it up. `deviceId` is validated (`isSafeExternalDeviceId`), days validated (`DAY_RE` + `isCalendarDay`), no SQL injection surface. | `_shared/devices.ts` `findNoopDevice`; `serverScores.ts:193-201`; route test "every read is scoped…" assertion. |
| Credential handling | Installation token or JWT only; no secrets in code; provision scripts hit public pinned URLs only; lane sanitizes/logs no payloads. | `tokens.ts` (pre-existing), `SensorBiomarkerLane.sanitize`. |
| Read route budget | ≤31 days; ≤256 KiB/day enforced by SQL check and iOS `maxDocumentBytes`. | `serverScores.ts` `SENSOR_BIOMARKERS_MAX_DAYS=31`; SQL `octet_length(document::text) <= 262144`. |
| Loopback-only sidecar | Reuses the existing `FRWHOOP_INFERENCE_URL` (loopback) inference client; no new network exposure. | `main.swift` config; sensor lane uses the same `inferenceClient`. |
| Migration | Delivered unapplied; only disposable local Postgres in tests. | Migration header; test harness starts its own DB. |

No P0/P1 security findings.

## Regressions (shared files, `fae049a..adf66b2`)

- `contract.py` / `providers/__init__.py`: only add the `sensor_biomarkers` metric to `METRICS`
  (with the provider owning its payload validation, like the sleep candidates) and append
  `collect_providers()`/`collect_optional_providers()` (fail-closed) to the registry. No existing
  metric changed. 515/0 suite green.
- `main.swift`: adds an OFF-by-default lane gated on `FRWHOOP_SENSOR_BIOMARKERS_ENABLED=="1"` AND
  `FRWHOOP_DISABLE_LANES` AND `FRWHOOP_INFERENCE_URL`; heartbeat/queue-age additions are guarded by
  table presence. `swift build` rc 0.
- `serverScores.ts`: purely additive route branch; the existing route set is untouched. Route
  regression subset reported (93 passed, 1 pre-existing `placement_route_test.ts` failure that also
  fails on HEAD) — the placement failure was not re-verified by this reviewer.
- `manifest.json`: 3 new optional entries (`required_for_readiness:false`); all hashes verified by
  this reviewer against the actual pinned upstream bytes.
- iOS: `AppModel` adds `SensorBiomarkerStore.shared.reset()` to sign-out and read candidates;
  `MetricExplorerView` adds one flag-gated section on the HRV detail page; `SentryMonitor` change is
  an `#if os(iOS)` build fix (no behavior change on iOS).

## Licenses / attribution

- **DeepBeat (GPL-3.0)** — contained: the adapter is a from-scratch server-side adapter, the GPL
  weights are only ever provisioned to the artifact root (never committed, never bundled into the
  iOS app or any user-facing path), the lane is OFF by default, and outputs are
  `preprocessing_unverified`/nonpublishable. Acceptable for a disabled research/shadow lane; the
  repo should keep a NOTICE entry (the parent-owned ATTRIBUTION ledger is referenced).
- **SiamAF (MIT)** — vendored `rhythm/_siamaf_vendored.py` carries the MIT header with author,
  source URL, pinned commit and upstream sha256; strict-state-dict load with verified `module.`
  prefix strip. Compliant.
- **ParaDigMa (Apache-2.0)** — fixture provenance recorded in
  `tests/sensor_biomarkers/paradigma/fixtures/PROVENANCE.md` (source, commit, license); the tremor
  pkl sha256 matches the spec's independently computed hash. Compliant.

## Evidence honesty

Strong overall: independent numerical oracles (analytic ENMO 1.05 g → 50 mg; analytic A²/2 band
power; exact pulse closed forms), real-weight tests (I re-verified every staged hash against the
actual upstream bytes), upstream parity to machine precision, explicit negative controls (flat/
clipped/short/unverified inputs must not classify), and `validation.md` accurately reports the
numbers I reproduced. Two honesty gaps: (a) the iOS route-shape tests mock a response the server
cannot produce (P1-1), and (b) `validation.md` §5.7's "route/auth shape" claim overstates coverage —
the route tests and iOS tests verify two incompatible contracts.

## Release recommendation

- **Descriptive tier: NO-GO for end-to-end release until P1-1 is resolved.** The server-side
  computation (movement + oscillation, and PPG once an anchor side-channel exists) is correct,
  gated, tested and honest. The phone↔route contract mismatch makes the feature unusable in a real
  deployment today; it is a small, one-sided fix, but it must land with a cross-layer test.
  P2-1/P2-2 should be fixed or explicitly documented in the contract before GA.
- **Research tier (ParaDigMa tremor/arm_swing): functional and correctly gated** — real weights,
  upstream parity, arm_swing withheld on unverified placement/orientation/axis (as spec requires).
  Ship disabled; tremor is IMU-only so it is not blocked by P1.
- **Shadow tier (DeepBeat/SiamAF): correct fail-closed behavior** — real weights, withheld
  `preprocessing_unverified`, never user-facing, flags off by default. Ship disabled.

No production deployment, no migration application, no git operations were performed by this
reviewer.
