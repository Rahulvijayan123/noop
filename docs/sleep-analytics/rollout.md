# Phase 1 sleep analytics — rollout plan (prepared, NOT executed)

Everything below is preparation only. Nothing is deployed, merged or backfilled by this branch.

## What ships (branch `feat/sleep-analytics-phase1-20261007`)

`daily.sleep_analytics_v1`: a pure Swift extractor in the shared `StrandAnalytics`
package, attached by the worker's scoring pass to every future v2 snapshot it
publishes, read back by the app from the hosted result. The canonical scores,
the legacy columns and the daily schema are untouched; the document is additive
free-form jsonb (`publish_scoring_snapshot_v2` already accepts it; no migration).

## Order

1. **Worker first.** Rebuild `frwhoop-worker` from this branch and deploy per
   `deploy/README.md` (the app and the worker share `StrandAnalytics`; a scoring
   package change requires rebuilding both). From the first deployed pass every
   newly published snapshot carries the document. A scoring failure inside the
   extractor withholds only its own document (bounded do/catch; verified by
   tests) — the drain never stalls.
2. **App second.** Ship the app reader any time after the worker: old snapshots
   (no key) decode to `nil` and the Sleep page renders exactly as before, so the
   app is backward and forward compatible with both snapshot generations. The
   Sleep details section appears for a night once its first post-deploy snapshot
   arrives.
3. **Rollback.** Deploy the prior worker build (documents stop being published;
   already-published documents remain readable by any app version or ignorable by
   the prior app). The app can also simply be rolled back: the section renders
   only when the document exists.

## Recompute / backfill

Days are recomputed only when they become dirty again (new data, edits or
config invalidation re-enqueue `scoring_jobs_v2`) — there is no automatic
backfill, and production is NOT backfilled by this work (per spec). A bounded
development backfill for requested days can re-dirty a bounded range through the
existing invalidation mechanism (e.g. a `config`-kind history input or an admin
`scoring_invalidations_v2` insert); no global `algorithm_version` string is
bumped and the closed `config` field list is untouched, so nothing else
recomputes. Recommended: re-dirty at most the last 7 days per device on request,
during low-traffic hours, watching `scoring_snapshots_v2` growth (the document
adds ~10–30 KiB per published day at v1 with the PRV window list; ~32 KiB
measured on a realistic 8 h night).

## Verification after deploy

- `GET /functions/v1/scores?day=…` returns `daily.sleep_analytics_v1` verbatim
  (pinned by `supabase/functions/tests/sleep_analytics_route_test.ts`, 4/4).
- The app's Sleep tab shows the "Sleep analytics" card for nights whose snapshot
  carries a matching (non-stale) document; nights without one show nothing new.
- Known withheld sources (honest, expected): marker-based SOL is `missing_marker`
  for every night (no marker source exists in Phase 1); PRV can be
  `unresolved_adjacency`/`insufficient_coverage` on noisy nights; thermal slopes
  need their peri-sleep windows covered by the read bound.

## Sentry pin follow-up (pre-existing main defect)

`fae049a` (main's tip at branch time) calls
`enableReportNonFullyBlockingAppHangs`, which the pinned Sentry 9.30.0 PREBUILT
binary does not expose (it exists in the 9.30.0 source). This branch builds by
calling it through a runtime selector (turns on any SDK that implements it,
no-ops on the pinned binary) — see `Strand/App/SentryMonitor.swift`. Upstream fix
on main: bump the Sentry pin to a release whose binaries carry the member, or
link the source product, then restore the direct assignment.
