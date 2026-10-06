# Evaluation — `shadow-ncsa-ood-hc` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `8f1faee3ae086939783e23c7b0f196aa6af8c6a3f888be3b9c3a5af0f2b125d1`; sealed bundle_sha256 `8fe56b2c8875caad6c206f5573e4fd1d513f8e07a71e6b46244156abf85c1b76` (test_gate.json `e301f84c7e8b45b8`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,861 | 0.848 | 0.625 [0.613, 0.636] | 0.630 [0.616, 0.642] | 0.630 [0.616, 0.642] | 0.562→0.411 | 0.319→0.230 | 0.032→0.014 (0.004) | 0.115→0.030 | 0.069 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,743 | 0.897 | 0.924 | 0.910 | 0.889 (36,065) | 0.035 | strong | 0.950 | P=0.986 n=11,291 → strong | – | strong | 0 |
| seated_likely | yes | 31,820 | 0.807 | 0.856 | 0.831 | 0.766 (25,868) | 0.039 | weak | 0.300 | P=0.807 n=33,768 → weak | gotov test: precision 0.657 at n_acc 140 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.351 | 0.095 | 0.149 | 0.378 (4,298) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.622 | 0.625 [0.611, 0.637] | 0.406 | 0.016 |  |
| gotov | 7 | 386 | 0.662 | 0.667 [0.571, 0.753]† | 0.757 | 0.109 |  |
| hhar_watch | 2 | 74 | 0.122 | 0.098 [0.038, 0.179]† | 1.935 | 0.530 | descriptive |
| mhealth | 2 | 16 | 0.556 | 0.420 [0.317, 0.517]† | 1.437 | 0.160 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.445 | 0.075 | descriptive |
| pamap2 | 2 | 204 | 0.598 | 0.565 [0.384, 0.595]† | 0.706 | 0.144 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.495 | 0.329 [0.196, 0.425]† | 0.902 | 0.193 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.90/0.92/0.91 (38536); gate P 0.99 n 11278 → strong | 0.54/0.83/0.65 (126); gate P 0.77 n 13 → weak | 0.00/0.00/0.00 (0) | 0.57/1.00/0.73 (4) | 0.00/0.00/0.00 (0) | 0.91/0.78/0.84 (77) | 0.00/0.00/0.00 (0) |
| seated_likely | 0.81/0.86/0.83 (31413); gate P 0.81 n 33311 → weak | 0.66/0.51/0.57 (182); gate P 0.66 n 140 → abstain | 0.38/0.24/0.30 (37); gate P 0.38 n 24 → weak | 0.44/0.67/0.53 (6); gate P 0.44 n 9 → weak | 0.81/1.00/0.90 (30); gate P 0.81 n 37 → weak | 0.50/0.89/0.64 (72); gate P 0.50 n 129 → abstain | 0.52/0.76/0.62 (80); gate P 0.52 n 118 → abstain |
| upright_stationary | 0.31/0.08/0.13 (4036) | 0.96/0.65/0.78 (78) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.78/0.13/0.22 (55) | 1.00/0.23/0.37 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.403, R 0.983, F1 0.572 (support 2,839, predicted 6,920)
- awake-lying gate at the frozen tau: pooled P=0.604 n=391 → abstain; per dataset capture24 P=0.598 n=378 → abstain, gotov P=0.769 n=13 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.630 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.986, P 0.852; ≥0.6: cov 0.920, P 0.870; ≥0.7: cov 0.833, P 0.889; ≥0.8: cov 0.695, P 0.914; ≥0.9: cov 0.435, P 0.942; ≥0.95: cov 0.206, P 0.963

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35806    2900      37       0
   3860   27245     715       0
    268    3623     407       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.863 | 0.611 [0.583, 0.645] | 0.662 [0.641, 0.688] | 0.662 [0.641, 0.688] | 0.643→0.400 | 0.297→0.187 | 0.110→0.026 (0.003) | 0.060→0.013 | 0.028 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,707 | 0.897 | 0.975 | 0.934 | 0.925 (73,462) | 0.036 | strong | 0.820 | P=0.976 n=64,717 → strong | wear test: precision 0.792 at n_acc 53 -> abstain | abstain | 0 |
| walking | yes | 2,817 | 0.844 | 0.484 | 0.615 | 0.116 (33) | 0.007 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | yes | 5,749 | 0.814 | 0.520 | 0.635 | 0.020 (19) | 0.011 | weak | 0.470 | P=0.881 n=3,009 → weak | – | weak | 0 |
| running | yes | 296 | 0.900 | 0.882 | 0.891 | 0.939 (296) | 0.002 | strong | 0.510 | P=0.908 n=284 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.795 | 0.763 | 0.779 | 0.913 (152) | 0.004 | weak | 0.365 | P=0.831 n=136 → weak | – | weak | 0 |
| cycling | yes | 855 | 0.711 | 0.650 | 0.679 | 0.808 (855) | 0.004 | weak | 0.300 | P=0.715 n=778 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.687 | 0.314 | 0.431 | 0.758 (3,518) | 0.024 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,463 | 0.374 | 0.300 | 0.333 | 0.577 (5,463) | 0.016 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.504 | 0.552 [0.444, 0.580] | 0.401 | 0.028 |  |
| gotov | 7 | 585 | 0.883 | 0.733 [0.541, 0.877]† | 0.415 | 0.048 |  |
| hhar_watch | 2 | 174 | 0.940 | 0.948 [0.930, 0.964]† | 0.292 | 0.183 | descriptive |
| mhealth | 2 | 49 | 0.826 | 0.803 [0.724, 0.949]† | 0.510 | 0.126 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.365 | 0.289 | descriptive |
| pamap2 | 2 | 397 | 0.728 | 0.697 [0.697, 0.760]† | 0.578 | 0.044 | descriptive |
| wear | 5 | 319 | 0.843 | 0.371 [0.358, 0.520]† | 0.466 | 0.078 |  |
| wisdm2019_watch | 8 | 1,167 | 0.899 | 0.611 [0.575, 0.758]† | 0.305 | 0.100 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.90/0.98/0.93 (71955); gate P 0.98 n 63492 → strong | 0.95/0.88/0.91 (386); gate P 1.00 n 292 → strong | 0.94/1.00/0.97 (74); gate P 1.00 n 74 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 11 → weak | 0.84/0.90/0.87 (187); gate P 0.98 n 131 → strong | 0.75/0.89/0.82 (112); gate P 0.79 n 53 → abstain | 1.00/0.93/0.97 (937); gate P 1.00 n 648 → strong |
| walking | 0.84/0.48/0.61 (2778) | 0.87/1.00/0.93 (33) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.50/0.33/0.40 (6) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| brisk_walking | 0.81/0.51/0.63 (5584); gate P 0.88 n 2849 → weak | 1.00/0.74/0.85 (19); gate P 1.00 n 14 → weak | 0.94/0.97/0.96 (35); gate P 0.97 n 35 → strong | 0.50/1.00/0.67 (4); gate P 0.50 n 8 → weak | 0.00/0.00/0.00 (0) | 0.94/0.78/0.85 (37); gate P 1.00 n 27 → weak | 0.00/0.00/0.00 (0) | 0.80/0.99/0.88 (70); gate P 0.91 n 76 → weak |
| running | 0.88/0.75/0.81 (103); gate P 0.90 n 86 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.36/1.00/0.53 (10); gate P 0.37 n 27 → weak | 1.00/0.94/0.97 (93); gate P 1.00 n 85 → strong | 1.00/0.96/0.98 (80); gate P 1.00 n 76 → strong |
| stairs | 0.03/0.12/0.05 (8); gate P 0.00 n 22 → weak | 0.00/0.00/0.00 (0) | 0.97/0.97/0.97 (32); gate P 0.97 n 32 → strong | 1.00/0.33/0.50 (3); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0) | 1.00/0.90/0.95 (29); gate P 1.00 n 25 → weak | 0.00/0.00/0.00 (0) | 1.00/0.71/0.83 (80); gate P 1.00 n 56 → strong |
| cycling | 0.68/0.61/0.64 (743); gate P 0.69 n 658 → abstain | 0.98/0.98/0.98 (47); gate P 0.98 n 47 → strong | 1.00/0.82/0.90 (33); gate P 1.00 n 27 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.93/0.96 (28); gate P 1.00 n 26 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 15 → weak |
| vehicle_motion | 0.69/0.32/0.43 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.15/0.26 (34) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.35/0.27/0.31 (5174) | 0.65/0.82/0.73 (100) | 0.00/0.00/0.00 (0) | 0.70/0.78/0.74 (9) | 0.00/0.00/0.00 (0) | 0.71/0.83/0.76 (66) | 0.96/0.70/0.81 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.662 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.915, P 0.907; ≥0.6: cov 0.860, P 0.931; ≥0.7: cov 0.807, P 0.953; ≥0.8: cov 0.744, P 0.971; ≥0.9: cov 0.640, P 0.985; ≥0.95: cov 0.457, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71830     149     323       8       0      80     233    1084
    912    1364       0       4       2       8      37     490
   1512       5    2990       8      17      86     104    1027
      5       0      26     261       0       0       0       4
      3       2      19       0     116       0       1      11
    233       2      39       0       0     556       0      25
   2254       9      43       0       0       4    1106     102
   3311      85     233       9      11      48     129    1637
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.657 | 0.482 [0.429, 0.585] | 0.491 [0.428, 0.568] | 0.491 [0.428, 0.568] | 0.961→0.710 | 0.562→0.462 | 0.057→0.063 (0.010) | 0.131→0.039 | 0.281 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.465 | 0.104 | 0.170 | 0.465 (6,845) | 0.074 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.673 | 0.951 | 0.788 | 0.673 (13,608) | 0.063 | weak | 0.705 | P=0.713 n=12,607 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.596 | 0.282 | 0.383 | 0.596 (582) | 0.012 | weak | 0.385 | P=0.596 n=267 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 0.657 | 0.590 | 0.622 | 0.657 (78) | 0.007 | weak | 0.475 | P=0.730 n=63 → abstain | – | abstain | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.369 | 0.259 [0.230, 0.277] | 0.711 | 0.064 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.339 | 0.286 |  |
| mhealth | 2 | 19 | 0.500 | 0.333 [0.333, 0.333]† | 1.221 | 0.540 | descriptive |
| pamap2 | 2 | 67 | 0.240 | 0.202 [0.202, 0.232]† | 1.363 | 0.496 | descriptive |
| wear | 5 | 64 | 0.609 | 0.189 [0.157, 0.295]† | 0.928 | 0.176 |  |
| wisdm2019_watch | 8 | 320 | 0.891 | 0.594 [0.502, 0.991]† | 0.469 | 0.139 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.47/0.10/0.17 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.67/0.06/0.12 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.67/0.95/0.79 (13385); gate P 0.71 n 12365 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 44 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 12 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 27 → weak | 0.00/0.00/0.00 (0) | 0.82/1.00/0.90 (160); gate P 0.99 n 159 → strong |
| repetitive_hand_motion | 0.16/0.05/0.08 (393); gate P 0.15 n 118 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.73/0.66/0.69 (29); gate P 0.71 n 24 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 1.00/0.78/0.88 (160); gate P 1.00 n 124 → strong |
| exercise_motion | 0.00/0.00/0.00 (0); gate P 0.00 n 17 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (7); gate P 1.00 n 7 → weak | 0.00/0.00/0.00 (7) | 1.00/0.61/0.76 (64); gate P 1.00 n 39 → strong | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.491 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.954, P 0.666; ≥0.6: cov 0.833, P 0.684; ≥0.7: cov 0.624, P 0.711; ≥0.8: cov 0.253, P 0.749; ≥0.9: cov 0.010, P 0.766; ≥0.95: cov 0.004, P 0.882

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    714    6045       0      68       0      18       0
    626   12941       0      35       0       6       0
      0       0       0       0       0       0       0
    187     231       0     164       0       0       0
      0       0       0       0       0       0       0
      9      15       0       8       0      46       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.927 | 0.062 | 0.093→0.090 | 0.213→0.192 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.898 | 0.053 | 0.097→0.096 | 0.215→0.191 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.925 | 0.090 | 0.092→0.089 | 0.210→0.187 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.906 | 0.077 | 0.102→0.101 | 0.222→0.203 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.85 (weak) | 36 | 0.18/0.53/0.27 | 0.20/0.58/0.30 | 2.7 / 4.3 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.70 (weak) | 405 | 0.47/0.40/0.43 | 0.56/0.47/0.51 | 2.5 / 6.1 |
| walk_stop | 0.65 (weak) | 404 | 0.49/0.36/0.41 | 0.60/0.44/0.51 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.131.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.097 | 0.137 | 0.537 | 0.777 | 0.765 |
| capture24 | 95,579 | 0.097 | 0.136 | 0.532 | 0.775 | 0.765 |
| gotov | 333 | 0.103 | 0.206 | 0.702 | 0.802 | 0.685 |
| pamap2 | 234 | 0.109 | 0.203 | 0.601 | 0.849 | 0.744 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.609 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.044 on 96,541 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 2,048 | 0.696 | 0.073 (0.021) | 0.971 | 0.740 | 0.051 | 0.263 |
| knn@10 | 96,541 | 2,048 | 0.567 | 0.022 (0.021) | 0.774 | 0.974 | 0.042 | 0.022 |
| knn@20 | 96,541 | 2,048 | 0.560 | 0.022 (0.021) | 0.785 | 0.979 | 0.040 | 0.016 |
| knn@5 | 96,541 | 2,048 | 0.570 | 0.022 (0.021) | 0.763 | 0.971 | 0.043 | 0.024 |
| maha_global | 96,541 | 2,048 | 0.796 | 0.141 (0.021) | 0.496 | 0.734 | 0.044 | 0.259 |
| maha_min | 96,541 | 2,048 | 0.799 | 0.152 (0.021) | 0.495 | 0.736 | 0.044 | 0.256 |
| maha_rel | 96,541 | 2,048 | 0.599 | 0.134 (0.021) | 0.951 | 0.692 | 0.046 | 0.302 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.190, AURC 0.047; with OOD rejection max coverage 0.951, risk 0.182, AURC 0.041.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 850 | 0.322 | 0.006 (0.009) | 0.970 | 1.000 | 0.051 | 0.000 |
| knn@10 | 96,541 | 850 | 0.686 | 0.017 (0.009) | 0.782 | 0.928 | 0.042 | 0.060 |
| knn@20 | 96,541 | 850 | 0.700 | 0.019 (0.009) | 0.790 | 0.922 | 0.040 | 0.065 |
| knn@5 | 96,541 | 850 | 0.672 | 0.017 (0.009) | 0.771 | 0.925 | 0.043 | 0.062 |
| maha_global | 96,541 | 850 | 0.499 | 0.040 (0.009) | 0.893 | 0.966 | 0.044 | 0.033 |
| maha_min | 96,541 | 850 | 0.502 | 0.040 (0.009) | 0.939 | 0.965 | 0.044 | 0.034 |
| maha_rel | 96,541 | 850 | 0.572 | 0.058 (0.009) | 0.928 | 0.720 | 0.046 | 0.274 |

OOD method selection (VAL only): chosen `maha_global` from ncsa-ood-hc; VAL AUROC energy 0.729, knn@10 0.567, knn@20 0.561, knn@5 0.573, maha_global 0.810, maha_min 0.817


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
