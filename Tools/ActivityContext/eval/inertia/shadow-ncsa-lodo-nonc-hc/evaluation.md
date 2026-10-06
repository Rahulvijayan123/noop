# Evaluation — `shadow-ncsa-lodo-nonc-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `f311783e3ad39b79e2d463750a0b4d8d971107166bf9fe815de5edee2d773320`; sealed bundle_sha256 `a1ff1b8ff0188040230ce21f916d70881f21278b7a6d56110efca8dc100eb3d3` (test_gate.json `8ff95d9f4515a971`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| recumbent (mostly sleep-period lying in training data) | yes | 38,606 | 0.905 | 0.922 | 0.913 | 0.898 (36,065) | 0.032 | weak | 0.300 | P=0.905 n=39,367 → weak | gotov test: precision 0.532 at n_acc 171 -> abstain | abstain | 0 |
| seated_likely | yes | 31,957 | 0.812 | 0.870 | 0.840 | 0.772 (25,868) | 0.031 | weak | 0.300 | P=0.812 n=34,235 → weak | gotov test: precision 0.495 at n_acc 206 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.475 | 0.139 | 0.215 | 0.533 (4,298) | 0.007 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.639 | 0.650 [0.631, 0.669] | 0.387 | 0.024 |  |
| gotov | 7 | 386 | 0.466 | 0.448 [0.336, 0.555]† | 0.872 | 0.198 |  |
| hhar_watch | 2 | 74 | 0.568 | 0.438 [0.416, 0.456]† | 1.358 | 0.201 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.256 [0.190, 0.317]† | 0.958 | 0.422 | descriptive |
| opportunity | 1 | 37 | 0.643 | 0.684 [0.684, 0.684]† | 0.445 | 0.158 | descriptive |
| pamap2 | 2 | 204 | 0.738 | 0.746 [0.682, 0.746]† | 0.620 | 0.103 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.660 | 0.479 [0.382, 0.562]† | 0.737 | 0.128 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38401); gate P 0.91 n 39065 → weak | 0.53/0.72/0.61 (126); gate P 0.53 n 171 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 26 → weak | 0.44/1.00/0.62 (4); gate P 0.44 n 9 → weak | 0.00/0.00/0.00 (0) | 0.89/0.84/0.86 (75); gate P 0.89 n 71 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 25 → weak |
| seated_likely | 0.81/0.87/0.84 (31548); gate P 0.81 n 33775 → weak | 0.50/0.56/0.53 (182); gate P 0.50 n 206 → abstain | 0.86/0.81/0.83 (37); gate P 0.86 n 35 → weak | 0.14/0.17/0.15 (6); gate P 0.14 n 7 → weak | 0.86/1.00/0.92 (30); gate P 0.86 n 35 → weak | 0.63/0.76/0.69 (74); gate P 0.63 n 89 → abstain | 0.67/0.74/0.70 (80); gate P 0.67 n 88 → abstain |
| upright_stationary | 0.43/0.12/0.19 (4036) | 1.00/0.12/0.21 (78) | 0.92/0.32/0.48 (37) | 0.00/0.00/0.00 (6) | 1.00/0.29/0.44 (7) | 0.77/0.62/0.69 (55) | 1.00/0.58/0.74 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.414, R 0.981, F1 0.582 (support 2,702, predicted 6,408)
- awake-lying gate at the frozen tau: pooled P=0.414 n=6,408 → abstain; per dataset capture24 P=0.408 n=6,106 → abstain, gotov P=0.532 n=171 → abstain, hhar_watch P=0.000 n=26 → weak, mhealth P=0.444 n=9 → weak, pamap2 P=0.887 n=71 → weak, wisdm2019_watch P=0.000 n=25 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.656 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.983, P 0.860; ≥0.6: cov 0.908, P 0.882; ≥0.7: cov 0.817, P 0.903; ≥0.8: cov 0.681, P 0.926; ≥0.9: cov 0.431, P 0.951; ≥0.95: cov 0.219, P 0.965

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35611    2963      32       0
   3529   27799     629       0
    227    3473     598       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.868 | 0.623 [0.583, 0.656] | 0.664 [0.631, 0.686] | 0.664 [0.631, 0.686] | 0.574→0.380 | 0.280→0.182 | 0.073→0.022 (0.003) | 0.059→0.010 | 0.026 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,694 | 0.909 | 0.969 | 0.938 | 0.909 (73,462) | 0.023 | strong | 0.830 | P=0.977 n=64,570 → strong | wear test: precision 0.590 at n_acc 61 -> abstain | abstain | 0 |
| walking | yes | 8,579 | 0.789 | 0.561 | 0.656 | 0.782 (8,358) | 0.012 | strong | 0.915 | P=0.986 n=2,667 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 296 | 0.925 | 0.706 | 0.801 | 0.925 (296) | 0.001 | strong | 0.695 | P=0.950 n=179 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.647 | 0.737 | 0.689 | 0.647 (152) | 0.002 | weak | 0.610 | P=0.792 n=120 → abstain | – | abstain | 0 |
| cycling | yes | 855 | 0.733 | 0.643 | 0.685 | 0.733 (855) | 0.002 | weak | 0.300 | P=0.737 n=746 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.706 | 0.383 | 0.497 | 0.707 (3,518) | 0.021 | weak | 0.625 | P=0.898 n=983 → weak | – | weak | 0 |
| other | yes | 5,463 | 0.404 | 0.361 | 0.381 | 0.409 (5,463) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.531 | 0.560 [0.439, 0.589] | 0.378 | 0.022 |  |
| gotov | 7 | 585 | 0.839 | 0.664 [0.441, 0.691]† | 0.409 | 0.059 |  |
| hhar_watch | 2 | 174 | 0.962 | 0.966 [0.964, 0.970]† | 0.187 | 0.099 | descriptive |
| mhealth | 2 | 49 | 0.807 | 0.750 [0.728, 0.949]† | 0.270 | 0.056 | descriptive |
| opportunity | 1 | 37 | 0.919 | 0.319 [0.319, 0.319]† | 0.287 | 0.201 | descriptive |
| pamap2 | 2 | 397 | 0.763 | 0.757 [0.644, 0.791]† | 0.481 | 0.063 | descriptive |
| wear | 5 | 319 | 0.552 | 0.308 [0.264, 0.354]† | 1.727 | 0.173 |  |
| wisdm2019_watch | 8 | 1,167 | 0.920 | 0.742 [0.707, 0.773]† | 0.166 | 0.078 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71942); gate P 0.98 n 63194 → strong | 0.90/0.87/0.88 (386); gate P 1.00 n 296 → strong | 0.97/1.00/0.99 (74); gate P 1.00 n 70 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.92/0.96 (37); gate P 1.00 n 19 → weak | 0.85/0.88/0.86 (187); gate P 0.96 n 136 → strong | 0.65/0.82/0.73 (112); gate P 0.59 n 61 → abstain | 1.00/0.98/0.99 (937); gate P 1.00 n 778 → strong |
| walking | 0.80/0.55/0.65 (8375); gate P 0.99 n 2499 → strong | 0.84/1.00/0.91 (52); gate P 1.00 n 52 → strong | 0.92/1.00/0.96 (35); gate P 1.00 n 30 → strong | 0.57/1.00/0.73 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.71/0.98/0.82 (43); gate P 1.00 n 22 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 3 → weak | 0.79/0.96/0.86 (70); gate P 1.00 n 57 → strong |
| running | 0.82/0.74/0.78 (103); gate P 0.87 n 68 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.39/0.56 (93); gate P 1.00 n 27 → weak | 1.00/0.96/0.98 (80); gate P 1.00 n 64 → strong |
| stairs | 0.02/0.12/0.04 (8); gate P 0.00 n 17 → weak | 0.00/0.00/0.00 (0) | 1.00/0.97/0.98 (32); gate P 1.00 n 27 → weak | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.90/0.62/0.73 (29); gate P 1.00 n 16 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 8 → weak | 1.00/0.78/0.87 (80); gate P 1.00 n 52 → strong |
| cycling | 0.69/0.60/0.65 (743); gate P 0.70 n 645 → abstain | 1.00/0.91/0.96 (47); gate P 1.00 n 43 → strong | 1.00/0.88/0.94 (33); gate P 1.00 n 29 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.89/0.94 (28); gate P 1.00 n 25 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.71/0.39/0.50 (3484); gate P 0.90 n 979 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.60/0.09/0.15 (34); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) |
| other | 0.39/0.35/0.37 (5174) | 0.56/0.57/0.57 (100) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.70/0.88/0.78 (66) | 0.76/0.45/0.56 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.664 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.911, P 0.914; ≥0.6: cov 0.859, P 0.939; ≥0.7: cov 0.814, P 0.958; ≥0.8: cov 0.764, P 0.972; ≥0.9: cov 0.665, P 0.984; ≥0.95: cov 0.502, P 0.989

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71386     680       0       5       1      51     360    1211
   2093    4809       0       3      22      81      91    1480
      0       0       0       0       0       0       0       0
      5      49       0     209      17       0       0      16
      3      29       0       0     112       0       0       8
    221      35       0       0       0     550       9      40
   1930      79       0       0       1      12    1349     147
   2894     411       0       9      20      56     103    1970
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,035 | 0.654 | 0.471 [0.432, 0.546] | 0.417 [0.363, 0.462] | 0.417 [0.363, 0.462] | 0.910→0.665 | 0.576→0.441 | 0.096→0.065 (0.010) | 0.179→0.052 | 0.219 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.647, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 78.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.077 | 0.000 | 0.000 | 0.077 (6,845) | 0.078 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.658 | 0.993 | 0.791 | 0.658 (13,608) | 0.064 | weak | 0.720 | P=0.774 n=10,661 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.505 | 0.419 | 0.458 | 0.505 (582) | 0.013 | strong | 0.690 | P=0.766 n=124 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 78 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.422 | 0.361 [0.264, 0.405] | 0.665 | 0.066 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.492 | 0.388 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.511 | 0.778 | descriptive |
| pamap2 | 2 | 60 | 0.397 | 0.295 [0.282, 0.308]† | 1.008 | 0.339 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.853 | 0.850 [0.678, 0.969]† | 0.565 | 0.111 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|
| quiet | 0.08/0.00/0.00 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.99/0.79 (13385); gate P 0.77 n 10462 → abstain | 1.00/1.00/1.00 (63) | 0.00/0.00/0.00 (0); gate P 0.00 n 12 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 15 → weak | 0.77/1.00/0.87 (160); gate P 0.92 n 172 → weak |
| repetitive_hand_motion | 0.31/0.27/0.29 (393); gate P 0.15 n 34 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.79/0.88 (29) | 1.00/0.71/0.83 (160); gate P 1.00 n 90 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,035, macro-F1 0.417 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.958, P 0.665; ≥0.6: cov 0.835, P 0.680; ≥0.7: cov 0.562, P 0.756; ≥0.8: cov 0.299, P 0.843; ≥0.9: cov 0.021, P 0.924; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      1    6696       0     148       0       0       0
      9   13508       0      91       0       0       0
      0       0       0       0       0       0       0
      3     335       0     244       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.926 | 0.063 | 0.102→0.099 | 0.234→0.213 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.894 | 0.053 | 0.100→0.099 | 0.225→0.200 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.923 | 0.091 | 0.104→0.101 | 0.232→0.214 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.900 | 0.075 | 0.107→0.104 | 0.239→0.211 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.12/0.53/0.19 | 0.14/0.61/0.22 | 2.9 / 5.4 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.51/0.35/0.42 | 0.58/0.40/0.47 | 2.3 / 5.9 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.35/0.39 | 0.54/0.44/0.48 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.139.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.103 | 0.137 | 0.497 | 0.780 | 0.764 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.492 | 0.779 | 0.765 |
| gotov | 333 | 0.123 | 0.206 | 0.587 | 0.752 | 0.607 |
| pamap2 | 234 | 0.107 | 0.203 | 0.645 | 0.845 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.052 on 98,307 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
