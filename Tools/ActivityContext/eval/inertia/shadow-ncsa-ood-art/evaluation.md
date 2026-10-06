# Evaluation — `shadow-ncsa-ood-art` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `ed3a9c821ded3dbc8e5c10bc8210e4974a10f81afb144b10efbcdee4b18d1681`; sealed bundle_sha256 `0c06a002ff50006f0f08c9de9142ac31279ecaa099f3f33871640f021881b95b` (test_gate.json `5ec72b5adbbdf74f`; the served artifact carries the gate); encoder `standin:inertia-arch-random-init/ar_transformer-small/seed0` (standin); evidence_tier_max `shadow`
- provenance: git_commit `bed5973b5533a11a84226c030f1de28de6a7f5c4`, source_tree_sha256 `64891b62cf8bfd73`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `c805f429821bb80c15da4ee6b2066c593321a40b3df8a0d7d26b01a838c5d7b1`; evaluations of this experiment on this test split: 1 (rerun reason: none); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), gotov 587 (7 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wear 319 (5 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,861 | 0.641 | 0.448 [0.424, 0.473] | 0.435 [0.412, 0.455] | 0.435 [0.412, 0.455] | 1.002→0.731 | 0.618→0.458 | 0.102→0.065 (0.005) | 0.180→0.042 | 0.307 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,718 | 0.689 | 0.733 | 0.710 | 0.660 (36,065) | 0.061 | weak | 0.665 | P=0.753 n=10,040 → abstain | – | abstain | 0 |
| seated_likely | yes | 30,845 | 0.579 | 0.612 | 0.595 | 0.503 (25,868) | 0.060 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.000 | 0.000 | 0.000 | 0.000 (4,298) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.449 | 0.436 [0.417, 0.457] | 0.726 | 0.067 |  |
| gotov | 7 | 386 | 0.463 | 0.389 [0.331, 0.447]† | 1.138 | 0.171 |  |
| hhar_watch | 2 | 74 | 0.000 | 0.000 [0.000, 0.000]† | 1.478 | 0.484 | descriptive |
| mhealth | 2 | 16 | 0.667 | 0.524 [0.524, 0.524]† | 1.009 | 0.462 | descriptive |
| opportunity | 1 | 37 | 0.000 | 0.000 [0.000, 0.000]† | 1.421 | 0.544 | descriptive |
| pamap2 | 2 | 204 | 0.559 | 0.531 [0.490, 0.531]† | 1.020 | 0.109 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.013 | 0.013 [0.000, 0.039]† | 1.473 | 0.515 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.69/0.73/0.71 (39557); gate P 0.76 n 9914 → abstain | 0.47/0.89/0.62 (126); gate P 0.43 n 117 → abstain | 0.00/0.00/0.00 (0) | 0.40/1.00/0.57 (4) | 0.00/0.00/0.00 (0) | 1.00/0.68/0.81 (31); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 7 → weak |
| seated_likely | 0.58/0.61/0.60 (30392) | 0.61/0.50/0.55 (182) | 0.00/0.00/0.00 (37) | 1.00/1.00/1.00 (6) | 0.00/0.00/0.00 (30) | 0.64/1.00/0.78 (118) | 0.08/0.03/0.04 (80) |
| upright_stationary | 0.00/0.00/0.00 (4036) | 0.00/0.00/0.00 (78) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.224, R 0.994, F1 0.366 (support 3,814, predicted 16,923)
- awake-lying gate at the frozen tau: pooled P=0.177 n=3,018 → abstain; per dataset capture24 P=0.167 n=2,892 → abstain, gotov P=0.427 n=117 → abstain, pamap2 P=1.000 n=2 → weak, wisdm2019_watch P=0.000 n=7 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.435 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.816, P 0.647; ≥0.6: cov 0.386, P 0.698; ≥0.7: cov 0.101, P 0.759; ≥0.8: cov 0.035, P 0.789; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  29118   10600       0       0
  11973   18872       0       0
   1160    3138       0       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.811 | 0.303 [0.289, 0.314] | 0.309 [0.286, 0.325] | 0.309 [0.286, 0.325] | 1.489→0.641 | 0.786→0.297 | 0.183→0.036 (0.004) | 0.138→0.015 | 0.106 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,859 | 0.818 | 0.994 | 0.897 | 0.884 (73,462) | 0.037 | weak | 0.300 | P=0.818 n=89,688 → weak | gotov test: precision 0.705 at n_acc 518 -> abstain | abstain | 0 |
| walking | yes | 6,687 | 0.726 | 0.048 | 0.090 | 0.000 (33) | 0.030 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | yes | 1,727 | 0.841 | 0.464 | 0.598 | 0.000 (19) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |
| running | yes | 296 | 0.716 | 0.861 | 0.782 | 0.752 (296) | 0.002 | strong | 0.775 | P=0.854 n=226 → weak | capture24 test: precision 0.699 at n_acc 73 -> abstain | abstain | 0 |
| stairs | yes | 152 | 0.111 | 0.007 | 0.012 | 0.125 (152) | 0.004 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 855 | 0.109 | 0.007 | 0.013 | 0.109 (855) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.000 (3,518) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,463 | 0.250 | 0.047 | 0.080 | 0.474 (5,463) | 0.008 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.297 | 0.290 [0.204, 0.317] | 0.637 | 0.035 |  |
| gotov | 7 | 585 | 0.258 | 0.259 [0.181, 0.761]† | 0.801 | 0.162 |  |
| hhar_watch | 2 | 174 | 0.228 | 0.162 [0.126, 0.191]† | 1.372 | 0.298 | descriptive |
| mhealth | 2 | 49 | 0.333 | 0.276 [0.274, 0.333]† | 1.162 | 0.258 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.124 | 0.116 | descriptive |
| pamap2 | 2 | 397 | 0.324 | 0.252 [0.149, 0.278]† | 1.380 | 0.161 | descriptive |
| wear | 5 | 319 | 0.720 | 0.520 [0.483, 0.742]† | 0.816 | 0.093 |  |
| wisdm2019_watch | 8 | 1,167 | 0.519 | 0.428 [0.400, 0.533]† | 0.459 | 0.125 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.82/0.99/0.90 (72107); gate P 0.82 n 87460 → weak | 0.70/0.95/0.81 (386); gate P 0.70 n 518 → abstain | 0.49/1.00/0.65 (74); gate P 0.49 n 152 → abstain | 0.49/1.00/0.66 (19); gate P 0.49 n 39 → abstain | 1.00/1.00/1.00 (37); gate P 1.00 n 37 → strong | 0.61/0.97/0.75 (187); gate P 0.61 n 295 → abstain | 0.59/0.99/0.74 (112); gate P 0.59 n 189 → abstain | 0.92/0.98/0.95 (937); gate P 0.92 n 998 → weak |
| walking | 0.75/0.05/0.09 (6641) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (2) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (5) |
| brisk_walking | 0.87/0.47/0.61 (1569) | 0.00/0.00/0.00 (19) | 0.18/0.14/0.16 (29) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.62/0.12/0.20 (41) | 0.00/0.00/0.00 (0) | 0.72/0.74/0.73 (65) |
| running | 0.54/0.83/0.65 (103); gate P 0.70 n 73 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.40/1.00/0.57 (10); gate P 0.59 n 17 → weak | 0.96/0.87/0.92 (93); gate P 0.99 n 73 → strong | 0.87/0.86/0.87 (80); gate P 0.94 n 53 → weak |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 1.00/0.01/0.02 (80) |
| cycling | 0.09/0.01/0.01 (743) | 0.22/0.04/0.07 (47) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (28) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.19/0.03/0.05 (5174) | 0.68/0.30/0.42 (100) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.49/0.50/0.49 (66) | 0.76/0.30/0.43 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.309 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.965, P 0.827; ≥0.6: cov 0.928, P 0.843; ≥0.7: cov 0.853, P 0.863; ≥0.8: cov 0.620, P 0.892; ≥0.9: cov 0.116, P 0.921; ≥0.95: cov 0.010, P 0.949

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73384      82      75      18       0      48       0     252
   5949     321       0       1       0       0       0     416
    833      14     801      16       1       0       0      62
      8       0       8     255       7       0       0      18
    109       1      32       0       1       0       0       9
    829       0      12       4       0       6       0       4
   3500       3       1       0       0       0       0      14
   5097      21      23      62       0       1       0     259
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.646 | 0.337 [0.312, 0.359] | 0.327 [0.297, 0.357] | 0.327 [0.297, 0.357] | 1.405→0.734 | 0.782→0.453 | 0.226→0.047 (0.009) | 0.240→0.037 | 0.251 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.512 | 0.003 | 0.006 | 0.512 (6,845) | 0.072 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.646 | 0.999 | 0.784 | 0.646 (13,608) | 0.047 | weak | 0.675 | P=0.747 n=10,821 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.500 | 0.002 | 0.003 | 0.500 (582) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 1.000 | 0.346 | 0.514 | 1.000 (78) | 0.010 | weak | 0.300 | P=1.000 n=27 → weak | – | weak | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.334 | 0.265 [0.243, 0.284] | 0.712 | 0.043 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.154 | 0.143 |  |
| mhealth | 2 | 19 | 0.000 | 0.000 [0.000, 0.000]† | 2.507 | 0.597 | descriptive |
| pamap2 | 2 | 67 | 0.286 | 0.231 [0.000, 0.231]† | 1.890 | 0.647 | descriptive |
| wear | 5 | 64 | 0.328 | 0.165 [0.121, 0.291]† | 1.805 | 0.347 |  |
| wisdm2019_watch | 8 | 320 | 0.503 | 0.340 [0.333, 0.354]† | 1.690 | 0.202 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.57/0.00/0.01 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.65/1.00/0.79 (13385); gate P 0.75 n 10545 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 63 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 3 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 45 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 4 → weak | 0.50/1.00/0.67 (160); gate P 0.73 n 161 → abstain |
| repetitive_hand_motion | 0.00/0.00/0.00 (393) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 1.00/0.01/0.01 (160) |
| exercise_motion | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (7) | 1.00/0.86/0.92 (7); gate P 1.00 n 6 → weak | 1.00/0.33/0.49 (64); gate P 1.00 n 21 → weak | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.327 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.973, P 0.656; ≥0.6: cov 0.804, P 0.704; ≥0.7: cov 0.448, P 0.764; ≥0.8: cov 0.213, P 0.803; ≥0.9: cov 0.001, P 1.000; ≥0.95: cov 0.000, P 1.000

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
     21    6824       0       0       0       0       0
     16   13591       0       1       0       0       0
      0       0       0       0       0       0       0
      0     581       0       1       0       0       0
      0       0       0       0       0       0       0
      4      47       0       0       0      27       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.881 | 0.031 | 0.113→0.098 | 0.275→0.203 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.824 | 0.035 | 0.120→0.100 | 0.289→0.213 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.786 | 0.028 | 0.146→0.146 | 0.298→0.303 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.823 | 0.039 | 0.126→0.107 | 0.304→0.221 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.15/0.28/0.20 | 0.20/0.36/0.25 | 1.9 / 6.5 |
| stand_to_sit_like | 0.65 (weak) | 36 | 0.08/0.25/0.12 | 0.16/0.47/0.24 | 4.7 / 8.8 |
| walk_start | 0.65 (weak) | 405 | 0.27/0.11/0.15 | 0.30/0.12/0.17 | 1.9 / 3.8 |
| walk_stop | 0.50 (weak) | 404 | 0.36/0.25/0.29 | 0.45/0.30/0.36 | 3.0 / 6.2 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.201.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.136 | 0.137 | 0.124 | 0.467 | 0.775 |
| capture24 | 95,579 | 0.136 | 0.136 | 0.114 | 0.463 | 0.775 |
| gotov | 333 | 0.151 | 0.206 | 0.405 | 0.706 | 0.718 |
| pamap2 | 234 | 0.142 | 0.203 | 0.382 | 0.750 | 0.774 |

## OOD

Bundle method `maha_global` (k=None), threshold 36.675 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.059 on 96,541 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 2,048 | 0.479 | 0.021 (0.021) | 0.992 | 0.942 | 0.040 | 0.049 |
| knn@10 | 96,541 | 2,048 | 0.794 | 0.064 (0.021) | 0.579 | 0.776 | 0.048 | 0.218 |
| knn@20 | 96,541 | 2,048 | 0.791 | 0.064 (0.021) | 0.566 | 0.778 | 0.047 | 0.213 |
| knn@5 | 96,541 | 2,048 | 0.798 | 0.065 (0.021) | 0.540 | 0.769 | 0.046 | 0.216 |
| maha_global | 96,541 | 2,048 | 0.859 | 0.141 (0.021) | 0.375 | 0.670 | 0.059 | 0.350 |
| maha_min | 96,541 | 2,048 | 0.860 | 0.142 (0.021) | 0.376 | 0.667 | 0.059 | 0.351 |
| maha_rel | 96,541 | 2,048 | 0.765 | 0.110 (0.021) | 0.686 | 0.691 | 0.055 | 0.330 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.239, AURC 0.143; with OOD rejection max coverage 0.935, risk 0.210, AURC 0.133.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 850 | 0.470 | 0.007 (0.009) | 0.688 | 1.000 | 0.040 | 0.000 |
| knn@10 | 96,541 | 850 | 0.740 | 0.034 (0.009) | 0.743 | 0.969 | 0.048 | 0.031 |
| knn@20 | 96,541 | 850 | 0.799 | 0.043 (0.009) | 0.606 | 0.956 | 0.047 | 0.034 |
| knn@5 | 96,541 | 850 | 0.687 | 0.029 (0.009) | 0.843 | 0.969 | 0.046 | 0.031 |
| maha_global | 96,541 | 850 | 0.611 | 0.011 (0.009) | 0.580 | 0.962 | 0.059 | 0.039 |
| maha_min | 96,541 | 850 | 0.606 | 0.011 (0.009) | 0.603 | 0.961 | 0.059 | 0.039 |
| maha_rel | 96,541 | 850 | 0.459 | 0.011 (0.009) | 0.957 | 0.900 | 0.055 | 0.101 |

OOD method selection (VAL only): chosen `maha_global` from ncsa-ood-art; VAL AUROC energy 0.479, knn@10 0.744, knn@20 0.731, knn@5 0.761, maha_global 0.836, maha_min 0.837


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
