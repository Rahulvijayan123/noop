# Evaluation — `shadow-ncsa-lodo-nogotov-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `761e347000c7ccea366cccd3d4a21bda5dbabf04265737b6db5498f5e6865315`; sealed bundle_sha256 `09c4fd0c64b2ae5e8476c2143ad9480797a0911b3a552fc87e4c308af094d943` (test_gate.json `48a2d5bf879fbac4`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,861 | 0.855 | 0.644 [0.629, 0.660] | 0.656 [0.639, 0.674] | 0.656 [0.639, 0.674] | 0.537→0.392 | 0.308→0.218 | 0.050→0.022 (0.004) | 0.101→0.024 | 0.064 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,608 | 0.905 | 0.923 | 0.913 | 0.898 (36,065) | 0.032 | weak | 0.300 | P=0.905 n=39,376 → weak | gotov test: precision 0.535 at n_acc 170 -> abstain | abstain | 0 |
| seated_likely | yes | 31,955 | 0.812 | 0.870 | 0.840 | 0.773 (25,868) | 0.031 | weak | 0.300 | P=0.812 n=34,224 → weak | gotov test: precision 0.498 at n_acc 207 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.473 | 0.139 | 0.215 | 0.533 (4,298) | 0.008 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.639 | 0.650 [0.631, 0.668] | 0.387 | 0.024 |  |
| gotov | 7 | 386 | 0.468 | 0.450 [0.341, 0.555]† | 0.876 | 0.197 |  |
| hhar_watch | 2 | 74 | 0.554 | 0.432 [0.416, 0.446]† | 1.363 | 0.188 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.256 [0.190, 0.317]† | 0.958 | 0.422 | descriptive |
| opportunity | 1 | 37 | 0.643 | 0.684 [0.684, 0.684]† | 0.447 | 0.158 | descriptive |
| pamap2 | 2 | 204 | 0.743 | 0.751 [0.682, 0.751]† | 0.622 | 0.112 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.660 | 0.479 [0.382, 0.562]† | 0.740 | 0.125 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38403); gate P 0.91 n 39074 → weak | 0.54/0.72/0.61 (126); gate P 0.54 n 170 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 27 → weak | 0.44/1.00/0.62 (4); gate P 0.44 n 9 → weak | 0.00/0.00/0.00 (0) | 0.89/0.84/0.86 (75); gate P 0.89 n 71 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 25 → weak |
| seated_likely | 0.81/0.87/0.84 (31546); gate P 0.81 n 33763 → weak | 0.50/0.57/0.53 (182); gate P 0.50 n 207 → abstain | 0.85/0.78/0.82 (37); gate P 0.85 n 34 → weak | 0.14/0.17/0.15 (6); gate P 0.14 n 7 → weak | 0.86/1.00/0.92 (30); gate P 0.86 n 35 → weak | 0.63/0.77/0.70 (74); gate P 0.63 n 90 → abstain | 0.67/0.74/0.70 (80); gate P 0.67 n 88 → abstain |
| upright_stationary | 0.43/0.12/0.19 (4036) | 1.00/0.12/0.21 (78) | 0.92/0.32/0.48 (37) | 0.00/0.00/0.00 (6) | 1.00/0.29/0.44 (7) | 0.79/0.62/0.69 (55) | 1.00/0.58/0.74 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.414, R 0.982, F1 0.582 (support 2,704, predicted 6,411)
- awake-lying gate at the frozen tau: pooled P=0.414 n=6,411 → abstain; per dataset capture24 P=0.409 n=6,109 → abstain, gotov P=0.535 n=170 → abstain, hhar_watch P=0.000 n=27 → weak, mhealth P=0.444 n=9 → weak, pamap2 P=0.887 n=71 → weak, wisdm2019_watch P=0.000 n=25 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.656 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.983, P 0.860; ≥0.6: cov 0.909, P 0.882; ≥0.7: cov 0.818, P 0.903; ≥0.8: cov 0.682, P 0.926; ≥0.9: cov 0.432, P 0.950; ≥0.95: cov 0.219, P 0.965

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35619    2958      31       0
   3528   27794     633       0
    229    3472     597       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.871 | 0.670 [0.635, 0.705] | 0.697 [0.663, 0.724] | 0.697 [0.663, 0.724] | 0.504→0.367 | 0.248→0.177 | 0.046→0.019 (0.003) | 0.046→0.009 | 0.023 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,692 | 0.911 | 0.967 | 0.938 | 0.911 (73,462) | 0.020 | strong | 0.795 | P=0.976 n=65,530 → strong | wear test: precision 0.931 at n_acc 72 -> weak | weak | 0 |
| walking | yes | 8,581 | 0.795 | 0.565 | 0.661 | 0.789 (8,358) | 0.014 | strong | 0.875 | P=0.981 n=2,672 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 296 | 0.879 | 0.882 | 0.880 | 0.879 (296) | 0.001 | strong | 0.925 | P=0.938 n=224 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.717 | 0.816 | 0.763 | 0.717 (152) | 0.002 | weak | 0.320 | P=0.729 n=170 → abstain | – | abstain | 0 |
| cycling | yes | 855 | 0.758 | 0.649 | 0.699 | 0.758 (855) | 0.002 | weak | 0.300 | P=0.762 n=727 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.717 | 0.448 | 0.551 | 0.719 (3,518) | 0.020 | weak | 0.570 | P=0.852 n=1,475 → weak | – | weak | 0 |
| other | yes | 5,463 | 0.407 | 0.361 | 0.382 | 0.412 (5,463) | 0.007 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.553 | 0.568 [0.450, 0.606] | 0.369 | 0.019 |  |
| gotov | 7 | 585 | 0.881 | 0.694 [0.359, 0.715]† | 0.401 | 0.048 |  |
| hhar_watch | 2 | 174 | 0.985 | 0.985 [0.970, 1.000]† | 0.150 | 0.096 | descriptive |
| mhealth | 2 | 49 | 0.863 | 0.845 [0.827, 0.949]† | 0.213 | 0.086 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.249 | 0.202 | descriptive |
| pamap2 | 2 | 397 | 0.768 | 0.722 [0.711, 0.756]† | 0.548 | 0.059 | descriptive |
| wear | 5 | 319 | 0.886 | 0.539 [0.517, 0.699]† | 0.348 | 0.048 |  |
| wisdm2019_watch | 8 | 1,167 | 0.930 | 0.630 [0.603, 0.788]† | 0.141 | 0.072 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71940); gate P 0.98 n 64094 → strong | 0.93/0.85/0.89 (386); gate P 0.99 n 306 → strong | 1.00/1.00/1.00 (74); gate P 1.00 n 71 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 21 → weak | 0.85/0.89/0.87 (187); gate P 0.95 n 145 → strong | 0.81/0.89/0.85 (112); gate P 0.93 n 72 → weak | 1.00/0.99/0.99 (937); gate P 1.00 n 805 → strong |
| walking | 0.79/0.56/0.65 (8377); gate P 0.98 n 2524 → strong | 0.95/1.00/0.97 (52); gate P 1.00 n 34 → strong | 0.95/1.00/0.97 (35); gate P 1.00 n 34 → strong | 0.67/1.00/0.80 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.91/0.72/0.81 (43); gate P 1.00 n 17 → weak | 0.00/0.00/0.00 (0) | 0.87/0.96/0.91 (70); gate P 1.00 n 59 → strong |
| running | 0.80/0.70/0.75 (103); gate P 0.93 n 57 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 7 → weak | 0.00/0.00/0.00 (0) | 0.36/1.00/0.53 (10); gate P 0.50 n 20 → weak | 1.00/0.96/0.98 (93); gate P 1.00 n 84 → strong | 1.00/1.00/1.00 (80); gate P 1.00 n 56 → strong |
| stairs | 0.04/0.25/0.07 (8); gate P 0.04 n 48 → abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (32); gate P 1.00 n 32 → strong | 1.00/0.33/0.50 (3); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0) | 1.00/0.93/0.96 (29); gate P 1.00 n 27 → weak | 0.00/0.00/0.00 (0) | 1.00/0.78/0.87 (80); gate P 1.00 n 62 → strong |
| cycling | 0.72/0.61/0.66 (743); gate P 0.72 n 623 → abstain | 1.00/0.94/0.97 (47); gate P 1.00 n 44 → strong | 1.00/0.94/0.97 (33); gate P 1.00 n 31 → strong | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.86/0.92 (28); gate P 1.00 n 24 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak |
| vehicle_motion | 0.72/0.45/0.55 (3484); gate P 0.85 n 1470 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.57/0.12/0.20 (34); gate P 1.00 n 3 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) |
| other | 0.39/0.34/0.36 (5174) | 0.57/0.74/0.64 (100) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.70/0.86/0.78 (66) | 0.94/0.81/0.87 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.697 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.906, P 0.920; ≥0.6: cov 0.854, P 0.945; ≥0.7: cov 0.810, P 0.961; ≥0.8: cov 0.758, P 0.975; ≥0.9: cov 0.662, P 0.986; ≥0.95: cov 0.532, P 0.992

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71283     654       0       5       5      45     402    1298
   2139    4849       0      16      26      86      88    1377
      0       0       0       0       0       0       0       0
      4      28       0     261       0       0       0       3
      3      16       0       0     124       0       0       9
    234      25       0       0       0     555       6      35
   1721      66       0       0       1       3    1576     151
   2834     458       0      15      17      43     126    1970
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.663 | 0.590 [0.546, 0.683] | 0.551 [0.514, 0.602] | 0.551 [0.514, 0.602] | 0.784→0.639 | 0.502→0.418 | 0.075→0.065 (0.010) | 0.107→0.040 | 0.194 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.612 | 0.037 | 0.070 | 0.612 (6,845) | 0.079 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.664 | 0.983 | 0.793 | 0.664 (13,608) | 0.069 | weak | 0.700 | P=0.779 n=12,247 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.621 | 0.493 | 0.550 | 0.621 (582) | 0.007 | strong | 0.770 | P=0.900 n=170 → weak | capture24 test: precision 0.452 at n_acc 31 -> abstain | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 0.742 | 0.846 | 0.790 | 0.742 (78) | 0.006 | strong | 0.760 | P=0.964 n=56 → weak | – | weak | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.447 | 0.306 [0.221, 0.356] | 0.646 | 0.067 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.323 | 0.275 |  |
| mhealth | 2 | 19 | 0.500 | 0.333 [0.333, 0.333]† | 0.688 | 0.434 | descriptive |
| pamap2 | 2 | 67 | 0.667 | 0.500 [0.333, 0.500]† | 0.691 | 0.314 | descriptive |
| wear | 5 | 64 | 0.812 | 0.448 [0.414, 0.488]† | 0.402 | 0.125 |  |
| wisdm2019_watch | 8 | 320 | 0.912 | 0.912 [0.748, 1.000]† | 0.305 | 0.107 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.61/0.04/0.07 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.98/0.79 (13385); gate P 0.78 n 12028 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 48 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 18 → weak | 0.00/0.00/0.00 (0) | 0.85/1.00/0.92 (160); gate P 0.99 n 151 → strong |
| repetitive_hand_motion | 0.42/0.32/0.36 (393); gate P 0.45 n 31 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (29); gate P 1.00 n 28 → weak | 0.00/0.00/0.00 (0) | 1.00/0.82/0.90 (160); gate P 1.00 n 111 → strong |
| exercise_motion | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (7); gate P 1.00 n 7 → weak | 1.00/1.00/1.00 (7); gate P 1.00 n 3 → weak | 1.00/0.81/0.90 (64); gate P 1.00 n 44 → strong | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.551 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.963, P 0.672; ≥0.6: cov 0.835, P 0.711; ≥0.7: cov 0.592, P 0.782; ≥0.8: cov 0.300, P 0.867; ≥0.9: cov 0.081, P 0.921; ≥0.95: cov 0.012, P 0.942

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    255    6469       0     108       0      13       0
    149   13382       0      67       0      10       0
      0       0       0       0       0       0       0
     13     282       0     287       0       0       0
      0       0       0       0       0       0       0
      0      12       0       0       0      66       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.926 | 0.063 | 0.102→0.099 | 0.234→0.212 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.894 | 0.053 | 0.100→0.099 | 0.225→0.199 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.923 | 0.091 | 0.103→0.101 | 0.231→0.213 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.900 | 0.075 | 0.106→0.104 | 0.239→0.211 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.12/0.53/0.19 | 0.14/0.61/0.22 | 2.9 / 5.4 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.51/0.36/0.42 | 0.58/0.40/0.47 | 2.4 / 5.7 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.36/0.39 | 0.53/0.44/0.48 | 2.5 / 6.9 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.138.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.103 | 0.137 | 0.499 | 0.782 | 0.765 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.494 | 0.782 | 0.766 |
| gotov | 333 | 0.122 | 0.206 | 0.588 | 0.753 | 0.610 |
| pamap2 | 234 | 0.107 | 0.203 | 0.647 | 0.844 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.379 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.047 on 98,307 windows.

**heldout_dataset_gotov_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,722 | 587 | 0.526 | 0.007 (0.006) | 0.989 | 0.937 | 0.051 | 0.066 |
| knn@10 | 97,722 | 587 | 0.557 | 0.008 (0.006) | 0.840 | 0.893 | 0.041 | 0.090 |
| knn@20 | 97,722 | 587 | 0.557 | 0.007 (0.006) | 0.867 | 0.908 | 0.039 | 0.085 |
| knn@5 | 97,722 | 587 | 0.558 | 0.007 (0.006) | 0.847 | 0.906 | 0.041 | 0.078 |
| maha_global | 97,722 | 587 | 0.537 | 0.007 (0.006) | 0.962 | 0.954 | 0.047 | 0.044 |
| maha_min | 97,722 | 587 | 0.531 | 0.007 (0.006) | 0.963 | 0.957 | 0.047 | 0.041 |
| maha_rel | 97,722 | 587 | 0.423 | 0.005 (0.006) | 0.983 | 0.966 | 0.047 | 0.031 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.185, AURC 0.042; with OOD rejection max coverage 0.953, risk 0.179, AURC 0.039.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,722 | 850 | 0.372 | 0.006 (0.009) | 0.957 | 0.999 | 0.051 | 0.001 |
| knn@10 | 97,722 | 850 | 0.693 | 0.017 (0.009) | 0.789 | 0.934 | 0.041 | 0.055 |
| knn@20 | 97,722 | 850 | 0.705 | 0.020 (0.009) | 0.799 | 0.922 | 0.039 | 0.062 |
| knn@5 | 97,722 | 850 | 0.674 | 0.017 (0.009) | 0.781 | 0.931 | 0.041 | 0.060 |
| maha_global | 97,722 | 850 | 0.504 | 0.040 (0.009) | 0.886 | 0.966 | 0.047 | 0.034 |
| maha_min | 97,722 | 850 | 0.507 | 0.040 (0.009) | 0.926 | 0.965 | 0.047 | 0.034 |
| maha_rel | 97,722 | 850 | 0.576 | 0.053 (0.009) | 0.931 | 0.759 | 0.047 | 0.232 |

OOD method selection (VAL only): chosen `maha_global` from ncsa-ood-hc; VAL AUROC energy 0.729, knn@10 0.567, knn@20 0.561, knn@5 0.573, maha_global 0.810, maha_min 0.817


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
