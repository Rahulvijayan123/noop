# Root deployment baseline (read-only evidence, 2026-10-03)

Collected by the root agent over `ssh root@143.198.62.4` (droplet `frwhoop-worker-2`, sfo3, 4 vCPU / 8 GB, Ubuntu 24.04). All read-only.

## Checkout state (local, 2026-10-03)

- Authorized Nara-App checkout for this audit: `/Volumes/External SSD/Nara Whoop App V2/nara-core-plumbing` — git worktree of the nara-activity clone, branch `audit/core-plumbing-20261003`, base commit `56809066` (`integration/phone-20261003`: merge of the 12-commit `feature/activity-context-hart` lane (bae99408) into the noop WIP snapshot (2dbcca0d/ad9ce856), plus 2 integration commits).
- Unpushed/uncommitted work PRESERVED (untouched): `nara-activity` working tree has 11 dirty files (ImuSessionFileStore, CloudCapture, ImuObjectSource, RawDataCollectorView, tests, DayScoring, PostgresClient, .gitignore, + untracked fixtures/tests). 7 of 9 match integration HEAD; CloudCapture.swift + DayScoring.swift in that tree are OLDER than integration HEAD (superseded by 56809066 content), but the tree is left exactly as found.
- Remote `nara` = https://github.com/Rahulvijayan123/Nara-App.git; nara/main = c3e30be1; feature/activity-context-hart = 12 ahead / 2 behind nara/main.
- `Whoop-Nara` (different remote) also has dirty files (SettingsView, serverScores, claim_today migrations) — out of scope, untouched.

## Running deployment

- Service `frwhoop-worker` ACTIVE since 2026-10-03 08:09:17 UTC, NRestarts=0, Restart=always.
- Binary: `/opt/noop/Tools/CloudWorker/.build/x86_64-unknown-linux-gnu/release/frwhoop-worker`, sha256 prefix 686e80f443d34c27. NOTE: plain `release/` path, not the versioned `release-<sha>` symlink recommended by deploy/README.md.
- `/opt/noop` has NO git metadata (unpacked tarball) — deployed-revision identity must be proven by binary/source comparison, not env.
- MemoryCurrent ~199 MB (peak ~268 MB); CPU 7.4% avg over 12h46m. Host: 4 vCPU, 7.8 GiB (779 MiB used), 140 GB free disk, load 0.14.
- Production env keys: DB URL, DB SSL verify-full + pinned CA, B2 keys, ingest secret, worker name, SOURCE_REVISION, lane budgets (projection/scoring/archive/verify/reconcile), poll + heartbeat intervals.

## DB / queue evidence (read-only psql over the worker's TLS config)

- Heartbeat fresh (since_poll ~6s). `last_error` = "digest mismatch 6ad53e16-...: no expected wire digest recorded" — carried by the VERIFY lane.
- Scoring lane counters: claimed 1109, completed 1074, superseded 35, series_published 1019, series_rows_written 30553, series_failed 0, failures_persisted 0, legacy_deferred 32231. No dead letters.
- `scoring_jobs_v2`: 490 rows, 10 pending, 0 dead-lettered.
- `noop_projection_debt`: 72,667 rows, 10,691 failing, oldest 2026-08-25 (projection lane disabled in production via systemd drop-in).
- `scoring_archive_jobs_v2`: 15,738 total, 0 pending.
- Scale: 29 auth users / 29 profiles, 5 users with published scores, 173 published day scores.

## Open leads from live evidence

1. VERIFY lane digest mismatch on object 6ad53e16-b744-436c-8aa4-ec3c8fc73983 ("no expected wire digest recorded") — spec 4.6 archive integrity. Needs tracing: object-without-digest path.
2. Deployed binary identity vs current tree — to be compared (build the same revision and hash, or compare deployed sources with the worktree).
3. 10 pending scoring jobs (stale days?) — check ages and why.

## Device access

- Physical iPhone 16 (com.rahulvijayan.noop install, paired) available via `xcrun devicectl` (identifier 97672F64-21A1-5693-86CC-EF78A2795011). Apple Watch Series 10 paired. WHOOP strap pairing assumed via the phone app — physical BLE tests are possible but need the strap worn/present; treat strap-dependent checks as device-pending until confirmed.

## Verification layers available

- Code: macOS StrandTests (xcodebuild), worker swift tests (Linux/macOS), Deno suites (supabase/functions/tests + local PG harness), Python tools tests.
- Device: iPhone 16 connected (devicectl). WHOOP strap physical presence unconfirmed.
- Staging: none provisioned for this audit (no separate staging DB/worker); production is READ-ONLY accessible via ssh + psql. No writes, no migrations, no deploys authorized in this run.


## Deployed revision identity (proven, 2026-10-03)

- `sha256(concat(sha256(file) + "  " + path))` over `Tools/CloudWorker/Sources/**/*.swift` on the droplet = `c58ad0a91bbafe11e6ba52300b0532fde13e799c6861e4b25dee18f150a0dcd5`.
- The identical fingerprint at commit `c3e30be1` (nara/main, 'wip: top-up of noop edits') = same value. So the DEPLOYED WORKER SOURCE == `c3e30be1`'s CloudWorker (11 files: no ActivityLane/Npb1ImuDecoder/ActivityPythonService, DayScoring without activity/intraday-series additions).
- The current audit baseline 56809066 has 14 CloudWorker source files and differs by +2003 lines (ActivityLane, ActivityPythonService, Npb1ImuDecoder, DayScoring additions, PostgresClient, main.swift) — the deployed worker DOES NOT include the activity/HART lane or the DayScoring deltas.
- `/etc/frwhoop/worker.env` still sets `FRWHOOP_SOURCE_REVISION=a7ea5426` — a revision that does not exist in the authorized clone; the identity label remains wrong (same trap as the 2026-09-30 audit, new value). Do not read deployed revision from that env or the heartbeat `source_revision` column.
- Binary built 2026-10-03 08:02:27 UTC (fresh deploy this morning; service started 08:09:17 UTC).


## Verify-lane digest-mismatch trace (root, 2026-10-03, read-only production)

- Live `last_error`: `digest mismatch 6ad53e16-b744-436c-8aa4-ec3c8fc73983: no expected wire digest recorded`.
- Source: VerificationLane.swift:558 — a wire-scope manifest with NO recorded digest (manifest sha256 + wire_sha256 empty, no receipt) is deterministically unverifiable; the RPC would reject the commit, so the lane refuses early (correct per-try behavior).
- Candidate scan (VerificationLane.swift:113-125 candidateSQL): selects `object_manifests` rows with `status='ready'` AND `durability_receipt->>'state' IS DISTINCT FROM 'verified_indexed'` — the bad manifest is re-selected on EVERY scan pass.
- Handling: `rememberNegative` in-process cache (limit 512, VerificationLane.swift:58-70) — proven-bad objects are skipped only for the CURRENT process lifetime. After every worker restart the object is re-downloaded + re-hashed + re-rejected once, forever.
- GAP (spec 4.6): no durable quarantine/reason accounting in the DB for deterministically-unverifiable manifests. `noop_object_verification_debt` is EMPTY (0 rows) — the debt table is not the feeding source for these.
- Also note: the heartbeat's top-level `last_error` shows the verify lane's error permanently, masking nothing else — observability is fine; the convergence defect is the missing durable state.
- ASSIGNED: repair-attest (VerificationLane.swift + new migration in its range): deterministic digest-mismatch -> durably recorded quarantine (bounded evidence + reason), stop rescanning after restart; transient cases remain bounded-retry.
