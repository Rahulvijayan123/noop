# Evaluation — `shadow-lodo-c24only-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `79278a60edaaecabb22e30b51fec33d3abec06b7e83c9e89d3d62b9fe36d6053`; sealed bundle_sha256 `f3f30e698bd34ef9df6fcd9cdfbba674b9778933559fd5fda5c828de50912965` (test_gate.json `daab960f6632614b`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 4 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 71, hhar_watch 71, mhealth 71, opportunity 71, pamap2 71, wisdm2019_watch 71

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.876 | 0.681 [0.661, 0.700] | 0.701 [0.675, 0.724] | 0.701 [0.675, 0.724] | 0.418→0.325 | 0.235→0.182 | 0.045→0.007 (0.004) | 0.076→0.012 | 0.039 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 37,878 | 0.937 | 0.922 | 0.929 | 0.933 (35,939) | 0.015 | strong | 0.880 | P=0.978 n=29,425 → strong | – | strong | 0 |
| seated_likely | yes | 32,377 | 0.829 | 0.909 | 0.867 | 0.790 (25,686) | 0.016 | weak | 0.300 | P=0.790 n=28,993 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.543 | 0.212 | 0.305 | 0.599 (4,220) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.953 / 0.990 (72,953) | strong | 0.570 | P=0.958 n=72,203 → strong | hhar_watch test: precision 0.500 at n_acc 74 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 8,630 | strong→strong (0.875) | strong→strong (0.880) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.684 | 0.704 [0.680, 0.727] | 0.319 | 0.009 |  |
| hhar_watch | 2 | 74 | 0.311 | 0.192 [0.108, 0.245]† | 2.342 | 0.426 | descriptive |
| mhealth | 2 | 16 | 0.500 | 0.383 [0.222, 0.517]† | 1.187 | 0.262 | descriptive |
| opportunity | 1 | 37 | 0.610 | 0.626 [0.626, 0.626]† | 0.497 | 0.099 | descriptive |
| pamap2 | 2 | 204 | 0.536 | 0.502 [0.317, 0.527]† | 0.939 | 0.268 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.413 | 0.236 [0.170, 0.279]† | 1.246 | 0.341 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.94/0.92/0.93 (37807); gate P 0.98 n 29404 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 9 → weak | 0.40/0.50/0.44 (4) | 0.00/0.00/0.00 (0) | 0.92/0.69/0.79 (67); gate P 0.75 n 4 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 8 → weak |
| seated_likely | 0.83/0.91/0.87 (32142); gate P 0.79 n 28652 → abstain | 0.53/0.62/0.57 (37); gate P 0.53 n 43 → abstain | 0.55/1.00/0.71 (6); gate P 0.55 n 11 → weak | 0.85/0.93/0.89 (30); gate P 0.85 n 33 → weak | 0.49/0.87/0.63 (82); gate P 0.43 n 127 → abstain | 0.48/0.76/0.59 (80); gate P 0.48 n 127 → abstain |
| upright_stationary | 0.54/0.22/0.31 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.50/0.29/0.36 (7) | 0.30/0.05/0.09 (55) | 1.00/0.06/0.12 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.452, R 0.988, F1 0.620 (support 1,974, predicted 4,318)
- awake-lying gate at the frozen tau: pooled P=0.005 n=655 → abstain; per dataset capture24 P=0.000 n=634 → abstain, hhar_watch P=0.000 n=9 → weak, pamap2 P=0.750 n=4 → weak, wisdm2019_watch P=0.000 n=8 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.701 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.990, P 0.879; ≥0.6: cov 0.922, P 0.900; ≥0.7: cov 0.846, P 0.920; ≥0.8: cov 0.746, P 0.941; ≥0.9: cov 0.582, P 0.965; ≥0.95: cov 0.418, P 0.979

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  34927    2925      26       0
   2207   29442     728       0
    160    3164     896       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,298 | 0.873 | 0.627 [0.590, 0.655] | 0.650 [0.614, 0.675] | 0.650 [0.614, 0.675] | 0.551→0.355 | 0.264→0.172 | 0.091→0.015 (0.003) | 0.085→0.014 | 0.022 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.804, balanced acc 0.200, macro-F1 0.178. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 355.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,149 | 0.931 | 0.956 | 0.943 | 0.931 (72,964) | 0.024 | strong | 0.775 | P=0.978 n=66,236 → strong | – | strong | 0 |
| walking | yes | 8,574 | 0.755 | 0.610 | 0.675 | 0.747 (8,306) | 0.009 | strong | 0.940 | P=0.984 n=2,687 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 203 |
| stairs | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 152 |
| cycling | yes | 808 | 0.678 | 0.627 | 0.652 | 0.678 (808) | 0.002 | weak | 0.315 | P=0.683 n=736 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.643 | 0.498 | 0.561 | 0.645 (3,518) | 0.025 | weak | 0.515 | P=0.796 n=1,803 → abstain | – | abstain | 0 |
| other | yes | 5,249 | 0.397 | 0.443 | 0.419 | 0.402 (5,249) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| stationary+walking | 453 | 0.935 / 0.968 (84,563) | strong | 0.795 | P=0.982 n=71,218 → strong | pamap2 test: precision 0.946 at n_acc 184 -> weak | weak |

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,718 | 0.628 | 0.662 [0.623, 0.694] | 0.344 | 0.015 |  |
| hhar_watch | 2 | 142 | 0.838 | 0.510 [0.469, 0.909]† | 0.330 | 0.065 | descriptive |
| mhealth | 2 | 36 | 0.711 | 0.579 [0.556, 0.610]† | 0.759 | 0.228 | descriptive |
| opportunity | 1 | 37 | 0.432 | 0.151 [0.151, 0.151]† | 1.172 | 0.126 | descriptive |
| pamap2 | 2 | 358 | 0.687 | 0.663 [0.535, 0.701]† | 0.646 | 0.051 | descriptive |
| wisdm2019_watch | 8 | 1,007 | 0.764 | 0.296 [0.250, 0.334]† | 1.148 | 0.121 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.93/0.96/0.95 (71895); gate P 0.98 n 65685 → strong | 0.93/1.00/0.96 (74); gate P 1.00 n 72 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.43/0.60 (37); gate P 1.00 n 1 → weak | 0.92/0.81/0.86 (187); gate P 0.98 n 132 → strong | 1.00/0.54/0.70 (937); gate P 1.00 n 330 → strong |
| walking | 0.76/0.60/0.67 (8422); gate P 0.98 n 2553 → strong | 0.83/1.00/0.91 (35); gate P 1.00 n 35 → strong | 0.25/1.00/0.40 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.46/1.00/0.63 (43); gate P 1.00 n 31 → strong | 0.64/0.99/0.78 (70); gate P 1.00 n 64 → strong |
| cycling | 0.76/0.63/0.69 (743); gate P 0.77 n 607 → abstain | 1.00/0.52/0.68 (33); gate P 1.00 n 17 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.54/0.70 (28); gate P 1.00 n 14 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 94 → abstain |
| vehicle_motion | 0.67/0.50/0.57 (3484); gate P 0.81 n 1746 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0); gate P 0.00 n 4 → weak | 0.51/0.62/0.56 (34); gate P 1.00 n 16 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 36 → abstain |
| other | 0.41/0.44/0.43 (5174) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.70/0.47/0.56 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,298, macro-F1 0.650 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.898, P 0.926; ≥0.6: cov 0.849, P 0.951; ≥0.7: cov 0.810, P 0.967; ≥0.8: cov 0.771, P 0.977; ≥0.9: cov 0.708, P 0.986; ≥0.95: cov 0.604, P 0.991

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  69905     889       0       0       0     117     546    1692
   1591    5228       0       0       0      88     169    1498
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
     65      73       0       0       0     507      65      98
   1434      96       0       0       0       1    1751     236
   2059     640       0       0       0      35     192    2323
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,390 | 0.664 | 0.500 [0.500, 0.500] | 0.399 [0.368, 0.428] | 0.399 [0.368, 0.428] | 0.671→0.643 | 0.470→0.450 | 0.060→0.142 (0.007) | 0.167→0.142 | 0.202 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.664, balanced acc 0.500, macro-F1 0.399. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 596.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.000 | 0.000 | 0.000 | 0.000 (6,845) | 0.142 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.664 | 1.000 | 0.798 | 0.664 (13,545) | 0.142 | weak | 0.735 | P=0.851 n=6,999 → weak | – | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 582 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,187 | 0.500 | 0.399 [0.367, 0.427] | 0.644 | 0.142 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.320 | 0.733 | descriptive |
| pamap2 | 2 | 31 | 0.000 | 0.000 [0.000, 0.000]† | 1.299 | 0.727 | descriptive |
| wisdm2019_watch | 8 | 160 | 1.000 | 1.000 [1.000, 1.000]† | 0.305 | 0.263 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.00/0.00/0.00 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/1.00/0.80 (13385); gate P 0.85 n 6882 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 1.00/1.00/1.00 (160); gate P 1.00 n 114 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,390, macro-F1 0.399 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.664; ≥0.6: cov 1.000, P 0.664; ≥0.7: cov 0.999, P 0.665; ≥0.8: cov 0.000, P –; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0    6845       0       0       0       0       0
      0   13545       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.940 | 0.056 | 0.071→0.069 | 0.167→0.131 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.911 | 0.055 | 0.087→0.088 | 0.187→0.161 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.950 | 0.079 | 0.063→0.060 | 0.151→0.114 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.916 | 0.074 | 0.087→0.087 | 0.198→0.156 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.70 (weak) | 36 | 0.02/0.25/0.04 | 0.04/0.47/0.07 | 4.9 / 8.3 |
| stand_to_sit_like | 0.60 (weak) | 36 | 0.02/0.33/0.05 | 0.05/0.69/0.10 | 5.1 / 8.9 |
| walk_start | 0.25 (weak) | 405 | 0.28/0.36/0.32 | 0.35/0.45/0.39 | 2.4 / 6.7 |
| walk_stop | 0.40 (weak) | 404 | 0.24/0.38/0.30 | 0.31/0.48/0.37 | 2.4 / 7.2 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.142.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.501 | 0.758 | 0.786 |
| capture24 | 95,579 | 0.102 | 0.136 | 0.499 | 0.757 | 0.786 |
| pamap2 | 234 | 0.132 | 0.203 | 0.487 | 0.813 | 0.692 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.247 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.057 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
