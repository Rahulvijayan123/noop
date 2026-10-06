# Evaluation — `shadow-ncsa-primary-art` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `5b83956e960d14c619ff34cbb561e52efb74b279e3c02326084193bd35dafae5`; sealed bundle_sha256 `a3f0cb0974d84e4ca8388e95a2d2da92ab39f1feb4ffc054f4a1e20e5333b3b6` (test_gate.json `7b17d3ea00b1c059`; the served artifact carries the gate); encoder `standin:inertia-arch-random-init/ar_transformer-small/seed0` (standin); evidence_tier_max `shadow`
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
| 74,861 | 0.673 | 0.470 [0.446, 0.495] | 0.457 [0.436, 0.479] | 0.457 [0.436, 0.479] | 0.907→0.697 | 0.551→0.430 | 0.056→0.066 (0.005) | 0.143→0.041 | 0.259 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 40,001 | 0.719 | 0.779 | 0.748 | 0.691 (36,065) | 0.057 | abstain | 1.000 | – | – | abstain | 0 |
| seated_likely | yes | 30,562 | 0.610 | 0.628 | 0.619 | 0.541 (25,868) | 0.058 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.533 | 0.002 | 0.004 | 0.571 (4,298) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.471 | 0.459 [0.439, 0.479] | 0.692 | 0.069 |  |
| gotov | 7 | 386 | 0.431 | 0.373 [0.306, 0.423]† | 0.932 | 0.121 |  |
| hhar_watch | 2 | 74 | 0.054 | 0.065 [0.000, 0.121]† | 1.484 | 0.470 | descriptive |
| mhealth | 2 | 16 | 0.167 | 0.111 [0.000, 0.190]† | 1.217 | 0.496 | descriptive |
| opportunity | 1 | 37 | 0.000 | 0.000 [0.000, 0.000]† | 1.647 | 0.660 | descriptive |
| pamap2 | 2 | 204 | 0.458 | 0.327 [0.140, 0.361]† | 1.196 | 0.216 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.144 | 0.112 [0.020, 0.174]† | 1.371 | 0.407 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.72/0.78/0.75 (39836) | 0.44/0.74/0.55 (126) | 0.00/0.00/0.00 (0) | 0.25/0.50/0.33 (4) | 0.00/0.00/0.00 (0) | 0.27/0.86/0.41 (35) | 0.00/0.00/0.00 (0) |
| seated_likely | 0.61/0.63/0.62 (30113) | 0.58/0.55/0.57 (182) | 1.00/0.11/0.20 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (30) | 0.65/0.52/0.58 (114) | 0.40/0.29/0.34 (80) |
| upright_stationary | 0.53/0.00/0.00 (4036) | 0.00/0.00/0.00 (78) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.250, R 0.990, F1 0.399 (support 4,097, predicted 16,255)


Wrist-only: n=74,861, macro-F1 0.457 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.878, P 0.693; ≥0.6: cov 0.495, P 0.741; ≥0.7: cov 0.222, P 0.791; ≥0.8: cov 0.056, P 0.786; ≥0.9: cov 0.003, P 0.682; ≥0.95: cov 0.000, P 0.438

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  31173    8828       0       0
  11360   19195       7       0
    838    3452       8       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.811 | 0.278 [0.265, 0.293] | 0.284 [0.268, 0.300] | 0.284 [0.268, 0.300] | 1.449→0.643 | 0.757→0.300 | 0.130→0.021 (0.004) | 0.132→0.013 | 0.104 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,861 | 0.822 | 0.991 | 0.898 | 0.885 (73,462) | 0.022 | weak | 0.300 | P=0.822 n=89,057 → weak | gotov test: precision 0.742 at n_acc 480 -> abstain | abstain | 0 |
| walking | yes | 3,716 | 0.817 | 0.028 | 0.054 | 0.000 (33) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | yes | 4,696 | 0.775 | 0.251 | 0.379 | 0.006 (19) | 0.013 | weak | 0.490 | P=0.876 n=1,052 → weak | wisdm2019_watch test: precision 0.671 at n_acc 70 -> abstain | abstain | 0 |
| running | yes | 296 | 0.740 | 0.865 | 0.798 | 0.795 (296) | 0.001 | strong | 0.780 | P=0.838 n=241 → weak | capture24 test: precision 0.750 at n_acc 72 -> abstain | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 855 | 0.355 | 0.032 | 0.058 | 0.355 (855) | 0.015 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.000 (3,518) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,463 | 0.215 | 0.055 | 0.088 | 0.377 (5,463) | 0.013 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.258 | 0.262 [0.173, 0.286] | 0.640 | 0.021 |  |
| gotov | 7 | 585 | 0.337 | 0.377 [0.304, 0.706]† | 0.797 | 0.099 |  |
| hhar_watch | 2 | 174 | 0.329 | 0.251 [0.164, 0.317]† | 1.236 | 0.213 | descriptive |
| mhealth | 2 | 49 | 0.417 | 0.391 [0.333, 0.449]† | 0.978 | 0.227 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.123 | 0.115 | descriptive |
| pamap2 | 2 | 397 | 0.342 | 0.258 [0.251, 0.258]† | 1.380 | 0.201 | descriptive |
| wear | 5 | 319 | 0.741 | 0.706 [0.643, 0.767]† | 0.764 | 0.108 |  |
| wisdm2019_watch | 8 | 1,167 | 0.531 | 0.411 [0.389, 0.527]† | 0.464 | 0.135 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.82/0.99/0.90 (72109); gate P 0.82 n 86957 → weak | 0.74/0.92/0.82 (386); gate P 0.74 n 480 → abstain | 0.55/1.00/0.71 (74); gate P 0.55 n 135 → abstain | 0.51/1.00/0.68 (19); gate P 0.51 n 37 → abstain | 1.00/1.00/1.00 (37); gate P 1.00 n 37 → strong | 0.68/0.96/0.80 (187); gate P 0.68 n 264 → abstain | 0.61/0.99/0.76 (112); gate P 0.61 n 182 → abstain | 0.95/0.97/0.96 (937); gate P 0.95 n 965 → weak |
| walking | 0.92/0.03/0.05 (3656) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.23/0.38 (26) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (1) |
| brisk_walking | 0.81/0.24/0.38 (4552); gate P 0.90 n 967 → weak | 0.67/0.11/0.18 (19) | 0.28/0.31/0.30 (35); gate P 0.47 n 15 → weak | 1.00/0.50/0.67 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (17) | 0.00/0.00/0.00 (0) | 0.50/0.77/0.60 (69); gate P 0.67 n 70 → abstain |
| running | 0.63/0.75/0.68 (103); gate P 0.75 n 72 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.27/1.00/0.43 (10); gate P 0.38 n 26 → weak | 0.91/0.92/0.91 (93); gate P 0.94 n 84 → weak | 0.90/0.91/0.91 (80); gate P 1.00 n 49 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (80) |
| cycling | 0.20/0.02/0.03 (743) | 1.00/0.32/0.48 (47) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (28) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.17/0.04/0.06 (5174) | 0.47/0.34/0.40 (100) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.40/0.55/0.46 (66) | 0.83/0.31/0.45 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.284 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.967, P 0.826; ≥0.6: cov 0.927, P 0.838; ≥0.7: cov 0.854, P 0.858; ≥0.8: cov 0.628, P 0.891; ≥0.9: cov 0.187, P 0.930; ≥0.95: cov 0.010, P 0.944

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73183       6     161      13       0      49       0     449
   3292     103       0       0       0       0       0     321
   3195      15    1179      24       1       0       0     282
      6       0      21     256       3       0       0      10
     63       0      64       0       0       0       0      25
    803       0      24       0       0      27       0       1
   3496       0       3       0       0       0       0      19
   5031       2      69      53       5       0       0     303
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.651 | 0.357 [0.325, 0.387] | 0.360 [0.320, 0.394] | 0.360 [0.320, 0.394] | 1.213→0.745 | 0.698→0.460 | 0.125→0.064 (0.010) | 0.189→0.045 | 0.271 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.605 | 0.046 | 0.085 | 0.605 (6,845) | 0.088 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.652 | 0.985 | 0.785 | 0.652 (13,608) | 0.069 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.000 | 0.000 | 0.000 | 0.000 (582) | 0.015 | abstain | 1.000 | – | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 1.000 | 0.397 | 0.569 | 1.000 (78) | 0.009 | weak | 0.300 | P=1.000 n=31 → strong | – | weak | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.344 | 0.291 [0.269, 0.313] | 0.729 | 0.061 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.072 | 0.070 |  |
| mhealth | 2 | 19 | 0.000 | 0.000 [0.000, 0.000]† | 2.675 | 0.727 | descriptive |
| pamap2 | 2 | 67 | 0.286 | 0.231 [0.000, 0.231]† | 1.595 | 0.556 | descriptive |
| wear | 5 | 64 | 0.391 | 0.281 [0.216, 0.345]† | 1.569 | 0.314 |  |
| wisdm2019_watch | 8 | 320 | 0.500 | 0.333 [0.333, 0.333]† | 1.470 | 0.297 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.61/0.05/0.09 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.98/0.79 (13385) | 1.00/1.00/1.00 (63) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.50/1.00/0.67 (160) |
| repetitive_hand_motion | 0.00/0.00/0.00 (393) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (160) |
| exercise_motion | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (7) | 1.00/0.86/0.92 (7); gate P 1.00 n 6 → weak | 1.00/0.39/0.56 (64); gate P 1.00 n 25 → weak | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.360 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.930, P 0.668; ≥0.6: cov 0.785, P 0.706; ≥0.7: cov 0.531, P 0.740; ≥0.8: cov 0.317, P 0.778; ≥0.9: cov 0.052, P 0.722; ≥0.95: cov 0.000, P 1.000

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    313    6532       0       0       0       0       0
    203   13404       0       1       0       0       0
      0       0       0       0       0       0       0
      1     581       0       0       0       0       0
      0       0       0       0       0       0       0
      0      47       0       0       0      31       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.881 | 0.031 | 0.113→0.098 | 0.274→0.203 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.824 | 0.035 | 0.120→0.100 | 0.289→0.213 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.786 | 0.028 | 0.146→0.146 | 0.298→0.301 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.823 | 0.039 | 0.126→0.107 | 0.304→0.221 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.15/0.28/0.20 | 0.20/0.36/0.25 | 1.9 / 6.5 |
| stand_to_sit_like | 0.70 (weak) | 36 | 0.09/0.22/0.13 | 0.18/0.44/0.26 | 5.6 / 8.9 |
| walk_start | 0.55 (weak) | 405 | 0.36/0.20/0.26 | 0.38/0.21/0.27 | 2.1 / 4.2 |
| walk_stop | 0.50 (weak) | 404 | 0.36/0.25/0.29 | 0.45/0.30/0.36 | 3.0 / 6.2 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.203.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.138 | 0.137 | 0.091 | 0.452 | 0.789 |
| capture24 | 95,579 | 0.138 | 0.136 | 0.082 | 0.449 | 0.789 |
| gotov | 333 | 0.157 | 0.206 | 0.375 | 0.704 | 0.646 |
| pamap2 | 234 | 0.165 | 0.203 | 0.255 | 0.684 | 0.748 |

## OOD

Bundle method `maha_global` (k=None), threshold 36.207 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.063 on 98,307 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
