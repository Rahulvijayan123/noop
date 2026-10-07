# Evaluation — `shadow-seed2-hc` (seed)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `90db5955712920137fcb2bf05a6015875dcd5e5a983916630db91d6be12bfea1`; sealed bundle_sha256 `2ff6a7bcdd2a6592565d3385d8de44419dbb26ec983a1017f0c11299033b50fa` (test_gate.json `c82cda609c37aaaa`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 4 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 74, hhar_watch 74, mhealth 74, opportunity 74, pamap2 74, wisdm2019_watch 74

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.857 | 0.643 [0.628, 0.659] | 0.655 [0.636, 0.674] | 0.655 [0.636, 0.674] | 0.533→0.387 | 0.307→0.215 | 0.052→0.026 (0.004) | 0.101→0.025 | 0.061 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,484 | 0.909 | 0.920 | 0.915 | 0.902 (35,939) | 0.034 | weak | 0.300 | P=0.902 n=36,438 → weak | – | weak | 0 |
| seated_likely | yes | 31,771 | 0.812 | 0.877 | 0.843 | 0.773 (25,686) | 0.033 | weak | 0.395 | P=0.773 n=28,320 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.465 | 0.132 | 0.206 | 0.523 (4,220) | 0.007 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.949 / 0.993 (73,497) | strong | 0.690 | P=0.959 n=71,242 → strong | hhar_watch test: precision 0.621 at n_acc 58 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| seated_likely | 8,630 | weak→abstain (0.300) | weak→abstain (0.395) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.638 | 0.647 [0.630, 0.667] | 0.385 | 0.026 |  |
| hhar_watch | 2 | 74 | 0.527 | 0.404 [0.388, 0.417]† | 1.311 | 0.138 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.256 [0.190, 0.317]† | 0.942 | 0.391 | descriptive |
| opportunity | 1 | 37 | 0.643 | 0.684 [0.684, 0.684]† | 0.439 | 0.140 | descriptive |
| pamap2 | 2 | 204 | 0.728 | 0.737 [0.625, 0.750]† | 0.608 | 0.103 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.653 | 0.471 [0.378, 0.548]† | 0.731 | 0.135 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38406); gate P 0.90 n 36355 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 27 → weak | 0.44/1.00/0.62 (4); gate P 0.44 n 9 → weak | 0.00/0.00/0.00 (0) | 0.90/0.81/0.85 (74); gate P 0.71 n 24 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 23 → weak |
| seated_likely | 0.81/0.88/0.84 (31543); gate P 0.77 n 28069 → abstain | 0.81/0.78/0.79 (37); gate P 0.85 n 34 → weak | 0.14/0.17/0.15 (6); gate P 0.14 n 7 → weak | 0.86/1.00/0.92 (30); gate P 0.86 n 35 → weak | 0.62/0.77/0.69 (75); gate P 0.57 n 83 → abstain | 0.65/0.75/0.70 (80); gate P 0.65 n 92 → abstain |
| upright_stationary | 0.43/0.12/0.18 (4036) | 0.91/0.27/0.42 (37) | 0.00/0.00/0.00 (6) | 1.00/0.29/0.44 (7) | 0.77/0.60/0.67 (55) | 1.00/0.56/0.72 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.419, R 0.992, F1 0.589 (support 2,580, predicted 6,115)
- awake-lying gate at the frozen tau: pooled P=0.006 n=3,576 → abstain; per dataset capture24 P=0.000 n=3,493 → abstain, hhar_watch P=0.000 n=27 → weak, mhealth P=0.444 n=9 → weak, pamap2 P=0.708 n=24 → weak, wisdm2019_watch P=0.000 n=23 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.655 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.983, P 0.862; ≥0.6: cov 0.907, P 0.884; ≥0.7: cov 0.814, P 0.905; ≥0.8: cov 0.673, P 0.929; ≥0.9: cov 0.422, P 0.956; ≥0.95: cov 0.201, P 0.970

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35422    3021      41       0
   3312   27858     601       0
    243    3419     558       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.872 | 0.656 [0.620, 0.694] | 0.687 [0.656, 0.713] | 0.687 [0.656, 0.713] | 0.543→0.369 | 0.263→0.177 | 0.065→0.021 (0.004) | 0.054→0.010 | 0.024 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,191 | 0.910 | 0.969 | 0.939 | 0.910 (72,964) | 0.023 | strong | 0.810 | P=0.976 n=65,024 → strong | pamap2 test: precision 0.932 at n_acc 146 -> weak | weak | 0 |
| walking | yes | 8,532 | 0.790 | 0.573 | 0.664 | 0.783 (8,306) | 0.013 | strong | 0.885 | P=0.983 n=2,639 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.899 | 0.837 | 0.867 | 0.899 (203) | 0.001 | strong | 0.580 | P=0.941 n=169 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.722 | 0.803 | 0.760 | 0.722 (152) | 0.002 | weak | 0.515 | P=0.826 n=138 → weak | – | weak | 0 |
| cycling | yes | 808 | 0.719 | 0.656 | 0.686 | 0.719 (808) | 0.002 | weak | 0.300 | P=0.720 n=736 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.713 | 0.420 | 0.529 | 0.715 (3,518) | 0.020 | weak | 0.600 | P=0.873 n=1,232 → weak | – | weak | 0 |
| other | yes | 5,249 | 0.400 | 0.333 | 0.363 | 0.404 (5,249) | 0.008 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| stationary+walking | 453 | 0.925 / 0.979 (86,460) | strong | 0.840 | P=0.983 n=68,885 → strong | – | strong |

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.555 | 0.569 [0.445, 0.606] | 0.372 | 0.021 |  |
| hhar_watch | 2 | 174 | 0.985 | 0.985 [0.970, 1.000]† | 0.151 | 0.115 | descriptive |
| mhealth | 2 | 49 | 0.807 | 0.750 [0.728, 0.949]† | 0.230 | 0.118 | descriptive |
| opportunity | 1 | 37 | 0.919 | 0.319 [0.319, 0.319]† | 0.333 | 0.231 | descriptive |
| pamap2 | 2 | 397 | 0.798 | 0.785 [0.770, 0.785]† | 0.471 | 0.049 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.918 | 0.619 [0.583, 0.781]† | 0.167 | 0.082 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71937); gate P 0.98 n 64002 → strong | 1.00/1.00/1.00 (74); gate P 1.00 n 68 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.92/0.96 (37); gate P 1.00 n 16 → weak | 0.84/0.88/0.86 (187); gate P 0.93 n 146 → weak | 1.00/0.99/0.99 (937); gate P 1.00 n 776 → strong |
| walking | 0.79/0.57/0.66 (8380); gate P 0.98 n 2529 → strong | 0.95/1.00/0.97 (35); gate P 1.00 n 30 → strong | 0.57/1.00/0.73 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.87/0.93/0.90 (43); gate P 1.00 n 17 → weak | 0.81/0.97/0.88 (70); gate P 1.00 n 59 → strong |
| running | 0.80/0.72/0.76 (103); gate P 0.88 n 81 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.95/0.97 (80); gate P 1.00 n 68 → strong |
| stairs | 0.05/0.25/0.08 (8); gate P 0.04 n 24 → weak | 1.00/1.00/1.00 (32); gate P 1.00 n 32 → strong | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.79/0.93/0.86 (29); gate P 0.96 n 25 → weak | 1.00/0.76/0.87 (80); gate P 1.00 n 57 → strong |
| cycling | 0.70/0.63/0.66 (743); gate P 0.70 n 674 → abstain | 1.00/0.94/0.97 (33); gate P 1.00 n 31 → strong | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.89/0.94 (28); gate P 1.00 n 25 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak |
| vehicle_motion | 0.71/0.42/0.53 (3484); gate P 0.87 n 1231 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.50/0.09/0.15 (34); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0) |
| other | 0.39/0.33/0.36 (5174) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.71/0.86/0.78 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.687 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.909, P 0.919; ≥0.6: cov 0.859, P 0.943; ≥0.7: cov 0.814, P 0.961; ≥0.8: cov 0.765, P 0.974; ≥0.9: cov 0.671, P 0.985; ≥0.95: cov 0.533, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70939     680       0       5       3      59     386    1119
   2134    4892       0       3      23      91      92    1297
      0       0       0       0       0       0       0       0
      4      28       0     170       0       0       0       1
      3      18       0       0     122       0       0       9
    205      34       0       0       0     530       4      35
   1788      81       0       0       1       4    1478     166
   2846     459       0      11      20      53     112    1748
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.656 | 0.460 [0.416, 0.566] | 0.448 [0.403, 0.503] | 0.448 [0.403, 0.503] | 0.915→0.706 | 0.556→0.458 | 0.078→0.058 (0.009) | 0.162→0.044 | 0.290 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.479 | 0.105 | 0.172 | 0.479 (6,845) | 0.058 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.674 | 0.949 | 0.788 | 0.674 (13,545) | 0.057 | weak | 0.660 | P=0.717 n=14,146 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.466 | 0.326 | 0.384 | 0.466 (582) | 0.017 | weak | 0.950 | P=0.636 n=110 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.399 | 0.376 [0.315, 0.417] | 0.708 | 0.058 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.594 | 0.785 | descriptive |
| pamap2 | 2 | 60 | 0.207 | 0.195 [0.167, 0.222]† | 1.242 | 0.466 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.881 | 0.591 [0.489, 0.991]† | 0.443 | 0.115 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.49/0.11/0.17 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.67/0.95/0.79 (13385); gate P 0.72 n 13942 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 12 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 23 → weak | 0.83/1.00/0.91 (160); gate P 0.94 n 169 → weak |
| repetitive_hand_motion | 0.20/0.14/0.17 (393); gate P 0.00 n 40 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.41/0.59 (29) | 1.00/0.76/0.87 (160); gate P 1.00 n 70 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.448 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.950, P 0.667; ≥0.6: cov 0.801, P 0.694; ≥0.7: cov 0.600, P 0.725; ≥0.8: cov 0.275, P 0.738; ≥0.9: cov 0.021, P 0.672; ≥0.95: cov 0.006, P 0.656

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    716    5991       0     138       0       0       0
    616   12849       0      80       0       0       0
      0       0       0       0       0       0       0
    162     230       0     190       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.931 | 0.065 | 0.096→0.095 | 0.211→0.202 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.897 | 0.053 | 0.098→0.097 | 0.214→0.195 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.928 | 0.095 | 0.094→0.093 | 0.207→0.195 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.905 | 0.078 | 0.103→0.102 | 0.229→0.206 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.13/0.56/0.22 | 0.15/0.61/0.24 | 2.8 / 4.6 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.70 (weak) | 405 | 0.43/0.38/0.40 | 0.50/0.45/0.47 | 2.4 / 6.9 |
| walk_stop | 0.75 (weak) | 404 | 0.54/0.32/0.40 | 0.65/0.39/0.48 | 2.4 / 6.8 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.138.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.490 | 0.795 | 0.759 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.487 | 0.795 | 0.759 |
| pamap2 | 234 | 0.112 | 0.203 | 0.603 | 0.848 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
