# Phase 1 sleep analytics — release notes

Branch `feat/sleep-analytics-phase1-20261007` (from main `fae049a`; spec audited
at `3ef5595`). Spec: `docs/sleep-analytics/spec.md` (the implementation
authority). Full metric definitions, gates and interpretation limits:
`docs/CURRENT_ALGORITHMS.md` §11. Rollout: `docs/sleep-analytics/rollout.md`.

## New

- `daily.sleep_analytics_v1`: descriptive sleep analytics for the day's resolved
  main-night group — observed sleep continuity (WASO strictly inside the sleep
  period, the canonical split-night gap contribution reported separately,
  estimated combined WASO, onset delay, REM/deep latency from sleep onset,
  longest observed sleep bout, complete estimated awakenings vs censored wake
  stretches, sleep→wake transitions), stage dynamics (per-label time and bouts
  with complete/censored splits and quantile gates, the 4×4 estimated epoch
  transition matrix with null probability rows), wrist movement (1 Hz gravity
  adjacencies against the shared stager stillness threshold), skin-temperature
  trends (nightly median/IQR/spread, pre-onset and post-wake OLS slopes over
  elapsed time, verified re-wear equilibration exclusions) and strictly gated
  PRV diagnostics (Poincaré SD1/SD2 medians of 5-minute windows).
- Every metric carries value/unit/status/reason with explicit nulls and the
  closed reason vocabulary; every group carries its own quality/coverage block.
  Counts can be zero with qualifying exposure; missing evidence is never a
  fabricated zero; no NaN/Infinity reaches the wire.
- Sleep tab: a compact expandable "Sleep analytics" card inside the night-detail
  section, rendered only for nights whose hosted document exists and still
  matches the night (staleness guard + the existing invalidated hosted refresh).
  Nulls render as Unavailable with a short human-readable reason — never 0, a
  clinical verdict or a red/green cutoff; stages are labelled estimated.

## Unchanged (verified)

Sleep detection and staging, Rest/Charge, canonical RMSSD/HRV, recovery,
steps/calories, the legacy columns and `server_daily_scores`, all stored
preferences and internal NOOP/Strand identifiers. The document is additive
free-form jsonb in the v2 snapshot; no DB migration; the dormant Python-sidecar
`sleep_features` pipeline is untouched.

## Known limitations (by design)

- No attempted-sleep marker exists in Phase 1, so marker-based SOL is
  `missing_marker` on every night (the verification logic ships for a future
  verified marker source).
- PRV is optical-source pulse-interval variability, never ECG-equivalent HRV;
  SD1 is usually redundant with RMSSD, so it stays in expandable diagnostics.
- Temperature is approximate wrist temperature: unmeasured ambient/bedding
  confounders; no core temperature, DLMO or circadian phase.
- Waveform/cycle/circadian/oxygen work stays deferred per spec §10–11.

## Sentry pin note (pre-existing main defect)

`fae049a` calls a Sentry option the pinned 9.30.0 prebuilt binary does not
expose; this branch builds by applying it through a runtime selector (no-op on
the pinned binary). See rollout.md for the upstream fix.
