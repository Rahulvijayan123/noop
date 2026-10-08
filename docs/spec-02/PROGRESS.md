# Spec 02 — progress

Date: 2026-10-08
Branch: `feat/spec02-feature-reuse-20261007` (worktree `nara-spec02-features`), cut from `nara/main` `dab2124f3`.
Source spec: `/Volumes/Untitled/Downloads/spec-02-feature-reuse.md`. Integration detail: [HANDOFF.md](HANDOFF.md).

**Status: implemented and verified on the branch. Not pushed, not merged into `main`, not deployed.**

## 1. How it was built

The foundation commit `fedeceb49` laid the contract, optional types, decoders and stubs. Six owner branches were then
cut from it and merged back into this branch:

| Branch | Owns | Merged as |
| --- | --- | --- |
| `spec02/cardiac-prv-20261007` | HF repair, pNN50, stage movement, SampEn / DFA α1, Stress screen | `034e8f8c1` |
| `spec02/pc-cardiac-20261007` | awake vs sleep HR, pulse episodes, policy fingerprint | `ead587ba2` |
| `spec02/respiratory-context-20261007` | respiratory distribution / modulation, rebound, awake RR reference, post-exertion RR return, history nights | `d5c9451df` |
| `spec02/temperature-thermal-20261007` | post-wake slope repair, morning response, `CircadianEngine` relabel | `e91894d48` |
| `spec02/temperature-rhythm-20261007` | rhythm history, skin-temperature rhythm, rest-activity rhythm | `62112396d` |
| `spec02/readback-ui-20261007` | section-hiding fix, rendering, wording, producer-to-app round trips | `efdd6552e`, fast-forward to `f68620b69` |
| `spec02/android-circadian-20261008` | Android circadian wording (lead follow-up) | `024bba91b` |

Lead changes on top: CPU-time (not wall-clock) guards for the full-night golden and for `prv_nonlinear`; regenerated
`sleep_features` golden after a value-by-value diff (additions only); removal of the pre-merge
`respiratoryRecoveryComputes` switch and of the unread pNN50 threshold; the readback tests' older-document fixture;
`CURRENT_ALGORITHMS.md`, `CONTRACT.md`, this file and `HANDOFF.md`.

## 2. Spec checklist

| Spec item | State | Where |
| --- | --- | --- |
| §1 HF power repair (true timing, absolute ms², consumer) | Done | `HRVFreqDomain.swift`, Stress screen |
| §1 pNN50 on the SD1/SD2 adjacency | Done, end to end | `sleep_analytics_v1.prv_diagnostics` → Sleep analytics section |
| §1 SD1/SD2 single authority | Unchanged, still Swift only | — |
| §1 Awake vs sleep HR medians, coverage, % dip | Done, end to end | physiology context → HR context detail |
| §1 Sustained pulse episodes, HR rise with movement | Done, end to end | physiology context → HR context detail |
| §1 Sample entropy, DFA α1 (optional) | Done, end to end | `sleep_features.prv_nonlinear` → Sleep details |
| §2 Interval SD/RMSSD, distribution, stage-conditioned, supported range | Done, end to end | `sleep_features.respiratory_variability` → Sleep details |
| §2 Stable respiratory modulation | Done, end to end | same |
| §2 Nightly RR vs prior 7/28 days | Existing comparisons verified causal; reaches the document | physiology context `comparisons` |
| §2 Post-activity respiratory return | Done, end to end | `bouts[].recovery.respiratory_recovery` → history rows |
| §2 Awake RR reference adapter | Done | `resp_rate.stable_awake_5min` |
| §3 Thermal bins once, post-wake slope | Done, end to end | `sleep_analytics_v1.thermal` |
| §3 30-minute morning response (Swift owns) | Done, end to end | `sleep_analytics_v1.morning_response` |
| §3 Bounded history, cosinor, uncertainty, gate | Done, end to end | worker `rhythmDay` / `rhythm_history` → `observed_skin_temp_rhythm` |
| §3 `CircadianEngine` relabel | Done (Swift + Android wording) | dial, Health card |
| §3 Phase relations and retrospective drift | Done, end to end | `observed_skin_temp_rhythm.phase_relations` / `phase_drift` |
| §4 Morning HR / temperature / movement around the boundary | Done | `morning_response` |
| §4 Next-night rebound | Done, end to end | `sleep_features.rebound` |
| §4 Stage-associated movement | Done, end to end | `movement.stage_movement` |
| §4 IS/IV/L5/M10/RA | Done: full-day 1 Hz gravity exists (measured 24/24 h) | `sleep_features.rest_activity_rhythm` |
| §4 Thermal IV across midnight | Fixed | `features/thermal.py`, `rhythm.py` |
| §4 LIDS, kRA/kAR, 24hAlign | Deferred (spec) | — |
| Readback: hidden sleep-details sections | Fixed | `SleepFeatureCards.swift` |

## 3. Verification (integrated branch)

| Suite | Result |
| --- | --- |
| StrandAnalytics (skip `LongitudinalBaselineTests`) | 3594 run, 7 skipped, 0 failures |
| CloudWorker | 672 run, 63 skipped (database-backed), 0 failures |
| Python sidecar | 543 passed, 42 skipped, 0 failed |
| macOS StrandTests | 3255 run, 13 skipped; 3 failures, all pre-existing on `main` |
| iOS simulator build | succeeded |
| Deno route tests (sleep analytics, physiology context, spec-02 readback) | 23 + 5 passed |
| Android | not built or run (no toolchain) |

Details, logs and limitations: [HANDOFF.md](HANDOFF.md) §9.

## 4. Decisions taken

- **Policy fingerprint (owner question from the foundation).** Pulse config stays in `Policy` because the detector
  now reads it; every pulse and respiratory-recovery parameter is keyed. Deploying changes the default policy key;
  only re-scored days pick up the new blocks (see HANDOFF §5 for the back-fill choice).
- **Sleep-analytics version** bumped to `nara-sleep-analytics-2` / `v2` with the thermal repair.
- **Sub-agents** were used per CONTRACT §7, with cardiac and temperature each split in two.

## 5. Decisions for the owner before deploy

1. Back-fill older physiology-context days with `invalidate_physiology_context_span_v1`, or let them refresh as they
   are re-scored.
2. Re-score the last 35 days per user to make the skin-temperature and rest-activity rhythms available immediately,
   or wait ~5 days for `rhythmDay` bins to accumulate.
3. Native-speaker review of the new translations (Swift and Android).
