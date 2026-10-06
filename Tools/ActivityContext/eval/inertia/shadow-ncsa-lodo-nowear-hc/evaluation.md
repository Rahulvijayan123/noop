# Evaluation — `shadow-ncsa-lodo-nowear-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `0ae6762ef47e5e496ad39635db94c093fbaa964cc234fe79e0b136edc4456044`; sealed bundle_sha256 `ae4238c6a36fedd86abda08063a0bc4a3f12822622f2f28dc7bdd8e1354d2546` (test_gate.json `f5b3482c2d0e8ad0`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,861 | 0.858 | 0.645 [0.631, 0.661] | 0.657 [0.639, 0.675] | 0.657 [0.639, 0.675] | 0.501→0.384 | 0.288→0.214 | 0.018→0.022 (0.004) | 0.089→0.024 | 0.062 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,376 | 0.911 | 0.920 | 0.915 | 0.905 (36,065) | 0.032 | weak | 0.300 | P=0.911 n=38,748 → weak | gotov test: precision 0.627 at n_acc 158 -> abstain | abstain | 0 |
| seated_likely | yes | 32,187 | 0.812 | 0.880 | 0.845 | 0.771 (25,868) | 0.032 | weak | 0.300 | P=0.812 n=34,903 → weak | gotov test: precision 0.668 at n_acc 184 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.483 | 0.136 | 0.212 | 0.536 (4,298) | 0.006 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.638 | 0.646 [0.629, 0.665] | 0.381 | 0.023 |  |
| gotov | 7 | 386 | 0.671 | 0.691 [0.577, 0.786]† | 0.582 | 0.114 |  |
| hhar_watch | 2 | 74 | 0.311 | 0.293 [0.190, 0.353]† | 1.429 | 0.325 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.262 [0.167, 0.333]† | 0.933 | 0.394 | descriptive |
| opportunity | 1 | 37 | 0.571 | 0.580 [0.580, 0.580]† | 0.485 | 0.116 | descriptive |
| pamap2 | 2 | 204 | 0.743 | 0.748 [0.719, 0.748]† | 0.554 | 0.079 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.685 | 0.487 [0.374, 0.565]† | 0.736 | 0.125 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38178); gate P 0.91 n 38453 → weak | 0.63/0.79/0.70 (126); gate P 0.63 n 158 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 43 → abstain | 0.33/1.00/0.50 (4); gate P 0.33 n 12 → weak | 0.00/0.00/0.00 (0) | 0.90/0.82/0.86 (68); gate P 0.90 n 62 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 20 → weak |
| seated_likely | 0.81/0.88/0.85 (31771); gate P 0.81 n 34480 → weak | 0.67/0.68/0.67 (182); gate P 0.67 n 184 → abstain | 0.63/0.32/0.43 (37); gate P 0.63 n 19 → weak | 0.00/0.00/0.00 (6); gate P 0.00 n 3 → weak | 0.83/1.00/0.91 (30); gate P 0.83 n 36 → weak | 0.67/0.72/0.69 (81); gate P 0.67 n 87 → abstain | 0.68/0.80/0.74 (80); gate P 0.68 n 94 → abstain |
| upright_stationary | 0.42/0.11/0.18 (4036) | 0.98/0.55/0.70 (78) | 0.92/0.30/0.45 (37) | 1.00/0.17/0.29 (6) | 1.00/0.14/0.25 (7) | 0.69/0.69/0.69 (55) | 1.00/0.57/0.73 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.413, R 0.983, F1 0.581 (support 2,472, predicted 5,888)
- awake-lying gate at the frozen tau: pooled P=0.413 n=5,888 → abstain; per dataset capture24 P=0.406 n=5,593 → abstain, gotov P=0.627 n=158 → abstain, hhar_watch P=0.000 n=43 → abstain, mhealth P=0.333 n=12 → weak, pamap2 P=0.903 n=62 → weak, wisdm2019_watch P=0.000 n=20 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.657 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.987, P 0.862; ≥0.6: cov 0.913, P 0.881; ≥0.7: cov 0.823, P 0.903; ≥0.8: cov 0.687, P 0.927; ≥0.9: cov 0.435, P 0.953; ≥0.95: cov 0.216, P 0.969

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35290    3049      37       0
   3259   28340     588       0
    199    3514     585       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.866 | 0.651 [0.618, 0.682] | 0.680 [0.651, 0.697] | 0.680 [0.651, 0.697] | 0.536→0.377 | 0.252→0.180 | 0.075→0.016 (0.004) | 0.045→0.010 | 0.027 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,703 | 0.908 | 0.970 | 0.938 | 0.933 (73,462) | 0.019 | strong | 0.800 | P=0.974 n=65,975 → strong | pamap2 test: precision 0.944 at n_acc 143 -> weak; wear test: precision 0.637 at n_acc 80 -> abstain | abstain | 0 |
| walking | yes | 6,265 | 0.764 | 0.386 | 0.513 | 0.042 (33) | 0.018 | weak | 0.470 | P=0.891 n=1,912 → weak | gotov test: precision 0.635 at n_acc 52 -> abstain | abstain | 0 |
| brisk_walking | yes | 2,305 | 0.933 | 0.845 | 0.887 | 0.000 (19) | 0.011 | strong | 0.690 | P=0.977 n=1,237 → strong | – | strong | 0 |
| running | yes | 296 | 0.946 | 0.713 | 0.813 | 0.959 (296) | 0.001 | strong | 0.735 | P=0.965 n=171 → strong | capture24 test: precision 0.918 at n_acc 73 -> weak | weak | 0 |
| stairs | yes | 152 | 0.585 | 0.836 | 0.688 | 0.747 (152) | 0.002 | strong | 0.830 | P=0.984 n=63 → strong | – | strong | 0 |
| cycling | yes | 855 | 0.745 | 0.687 | 0.715 | 0.853 (855) | 0.002 | strong | 0.875 | P=0.901 n=414 → weak | – | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.679 | 0.417 | 0.517 | 0.721 (3,518) | 0.019 | weak | 0.615 | P=0.881 n=1,148 → weak | – | weak | 0 |
| other | yes | 5,463 | 0.375 | 0.359 | 0.367 | 0.574 (5,463) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.564 | 0.592 [0.484, 0.618] | 0.376 | 0.016 |  |
| gotov | 7 | 585 | 0.754 | 0.585 [0.430, 0.871]† | 0.244 | 0.073 |  |
| hhar_watch | 2 | 174 | 0.985 | 0.985 [0.970, 1.000]† | 0.171 | 0.150 | descriptive |
| mhealth | 2 | 49 | 0.863 | 0.845 [0.827, 0.949]† | 0.205 | 0.094 | descriptive |
| opportunity | 1 | 37 | 0.892 | 0.314 [0.314, 0.314]† | 0.331 | 0.148 | descriptive |
| pamap2 | 2 | 397 | 0.730 | 0.718 [0.662, 0.729]† | 0.447 | 0.040 | descriptive |
| wear | 5 | 319 | 0.585 | 0.270 [0.241, 0.314]† | 1.753 | 0.164 |  |
| wisdm2019_watch | 8 | 1,167 | 0.811 | 0.697 [0.626, 0.761]† | 0.151 | 0.092 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71951); gate P 0.97 n 64514 → strong | 0.96/0.93/0.94 (386); gate P 1.00 n 328 → strong | 1.00/1.00/1.00 (74); gate P 1.00 n 69 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.89/0.94 (37); gate P 1.00 n 19 → weak | 0.83/0.89/0.86 (187); gate P 0.94 n 143 → weak | 0.67/0.89/0.77 (112); gate P 0.64 n 80 → abstain | 1.00/0.99/1.00 (937); gate P 1.00 n 806 → strong |
| walking | 0.77/0.38/0.51 (6223); gate P 0.90 n 1854 → weak | 0.63/1.00/0.78 (33); gate P 0.63 n 52 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.40/0.40/0.40 (5); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 5 → weak | 0.50/0.25/0.33 (4) |
| brisk_walking | 0.94/0.85/0.89 (2143); gate P 0.97 n 1139 → strong | 0.00/0.00/0.00 (19) | 0.95/1.00/0.97 (35); gate P 1.00 n 28 → weak | 0.67/1.00/0.80 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.93/0.74/0.82 (38); gate P 1.00 n 12 → weak | 0.00/0.00/0.00 (0) | 0.92/1.00/0.96 (66); gate P 1.00 n 54 → strong |
| running | 0.87/0.79/0.83 (103); gate P 0.92 n 73 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.34/0.51 (93); gate P 1.00 n 16 → weak | 1.00/0.97/0.99 (80); gate P 1.00 n 62 → strong |
| stairs | 0.02/0.12/0.03 (8); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (32); gate P 1.00 n 12 → weak | 1.00/0.33/0.50 (3) | 0.00/0.00/0.00 (0) | 0.63/0.90/0.74 (29); gate P 1.00 n 13 → weak | 0.00/0.00/0.00 (0) | 1.00/0.84/0.91 (80); gate P 1.00 n 37 → strong |
| cycling | 0.71/0.64/0.67 (743); gate P 0.88 n 332 → weak | 0.98/1.00/0.99 (47); gate P 1.00 n 46 → strong | 1.00/0.94/0.97 (33); gate P 1.00 n 14 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.96/0.98 (28); gate P 1.00 n 18 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.68/0.42/0.52 (3484); gate P 0.88 n 1146 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.75/0.09/0.16 (34); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) |
| other | 0.36/0.34/0.35 (5174) | 0.76/0.84/0.80 (100) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.70/0.86/0.78 (66) | 0.75/0.52/0.61 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.680 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.898, P 0.916; ≥0.6: cov 0.845, P 0.940; ≥0.7: cov 0.798, P 0.959; ≥0.8: cov 0.747, P 0.972; ≥0.9: cov 0.657, P 0.984; ≥0.95: cov 0.538, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71474     444      41       5       2      45     411    1281
   1941    2420       0       0      17      31     103    1753
    187      19    1948       3      30      69      20      29
      5      12      26     211      21       0       0      21
      3       6       7       0     127       0       0       9
    214       9      10       0       0     587       4      31
   1847      31      26       0       1       3    1466     144
   3018     225      30       4      19      53     154    1960
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,035 | 0.659 | 0.403 [0.373, 0.489] | 0.380 [0.326, 0.458] | 0.380 [0.326, 0.458] | 0.862→0.672 | 0.545→0.439 | 0.061→0.067 (0.010) | 0.157→0.061 | 0.219 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.647, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 78.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.702 | 0.034 | 0.065 | 0.702 (6,845) | 0.089 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.658 | 0.993 | 0.792 | 0.658 (13,608) | 0.077 | weak | 0.745 | P=0.771 n=10,108 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.631 | 0.182 | 0.283 | 0.631 (582) | 0.018 | strong | 0.475 | P=0.748 n=115 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 78 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.350 | 0.299 [0.270, 0.323] | 0.672 | 0.068 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.158 | 0.146 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.415 | 0.753 | descriptive |
| pamap2 | 2 | 60 | 0.069 | 0.081 [0.044, 0.111]† | 1.066 | 0.515 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.791 | 0.781 [0.618, 0.915]† | 0.676 | 0.127 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|
| quiet | 0.70/0.03/0.07 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.99/0.79 (13385); gate P 0.77 n 9871 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 63 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 8 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 4 → weak | 0.70/1.00/0.83 (160); gate P 0.89 n 162 → weak |
| repetitive_hand_motion | 0.13/0.02/0.04 (393); gate P 0.09 n 32 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.14/0.24 (29) | 1.00/0.58/0.74 (160); gate P 1.00 n 83 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,035, macro-F1 0.380 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.957, P 0.669; ≥0.6: cov 0.830, P 0.703; ≥0.7: cov 0.621, P 0.748; ≥0.8: cov 0.308, P 0.810; ≥0.9: cov 0.051, P 0.929; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    233    6565       0      47       0       0       0
     78   13515       0      15       0       0       0
      0       0       0       0       0       0       0
     21     455       0     106       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.928 | 0.062 | 0.092→0.090 | 0.212→0.191 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.898 | 0.053 | 0.096→0.095 | 0.213→0.190 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.926 | 0.090 | 0.091→0.088 | 0.208→0.186 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.906 | 0.077 | 0.101→0.100 | 0.221→0.202 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.85 (weak) | 36 | 0.18/0.53/0.27 | 0.20/0.58/0.30 | 2.7 / 4.3 |
| stand_to_sit_like | 0.70 (weak) | 36 | 0.10/0.42/0.16 | 0.16/0.64/0.25 | 4.0 / 7.4 |
| walk_start | 0.65 (weak) | 405 | 0.44/0.40/0.42 | 0.52/0.48/0.50 | 2.5 / 6.5 |
| walk_stop | 0.60 (weak) | 404 | 0.46/0.37/0.41 | 0.57/0.45/0.50 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.130.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.095 | 0.137 | 0.558 | 0.787 | 0.772 |
| capture24 | 95,579 | 0.095 | 0.136 | 0.553 | 0.786 | 0.773 |
| gotov | 333 | 0.103 | 0.206 | 0.690 | 0.802 | 0.679 |
| pamap2 | 234 | 0.105 | 0.203 | 0.637 | 0.855 | 0.744 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.339 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.051 on 98,307 windows.

**heldout_dataset_wear_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,988 | 319 | 0.618 | 0.006 (0.003) | 0.973 | 0.878 | 0.050 | 0.122 |
| knn@10 | 97,988 | 319 | 0.733 | 0.006 (0.003) | 0.537 | 0.922 | 0.041 | 0.047 |
| knn@20 | 97,988 | 319 | 0.740 | 0.006 (0.003) | 0.492 | 0.931 | 0.040 | 0.060 |
| knn@5 | 97,988 | 319 | 0.728 | 0.006 (0.003) | 0.580 | 0.903 | 0.042 | 0.066 |
| maha_global | 97,988 | 319 | 0.874 | 0.093 (0.003) | 0.526 | 0.417 | 0.049 | 0.583 |
| maha_min | 97,988 | 319 | 0.872 | 0.104 (0.003) | 0.554 | 0.411 | 0.049 | 0.589 |
| maha_rel | 97,988 | 319 | 0.640 | 0.142 (0.003) | 0.970 | 0.586 | 0.045 | 0.408 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.186, AURC 0.043; with OOD rejection max coverage 0.949, risk 0.179, AURC 0.040.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,988 | 850 | 0.241 | 0.005 (0.009) | 0.985 | 0.998 | 0.050 | 0.002 |
| knn@10 | 97,988 | 850 | 0.689 | 0.016 (0.009) | 0.782 | 0.933 | 0.041 | 0.058 |
| knn@20 | 97,988 | 850 | 0.702 | 0.018 (0.009) | 0.789 | 0.924 | 0.040 | 0.064 |
| knn@5 | 97,988 | 850 | 0.673 | 0.016 (0.009) | 0.769 | 0.926 | 0.042 | 0.061 |
| maha_global | 97,988 | 850 | 0.497 | 0.039 (0.009) | 0.892 | 0.965 | 0.049 | 0.035 |
| maha_min | 97,988 | 850 | 0.498 | 0.040 (0.009) | 0.939 | 0.965 | 0.049 | 0.035 |
| maha_rel | 97,988 | 850 | 0.569 | 0.064 (0.009) | 0.923 | 0.709 | 0.045 | 0.276 |

OOD method selection (VAL only): chosen `maha_global` from ncsa-ood-hc; VAL AUROC energy 0.729, knn@10 0.567, knn@20 0.561, knn@5 0.573, maha_global 0.810, maha_min 0.817


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
