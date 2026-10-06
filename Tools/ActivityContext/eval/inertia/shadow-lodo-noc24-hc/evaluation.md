# Evaluation — `shadow-lodo-noc24-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `62b9566ced026d1e26df99c8447ed9b90bb2262f834a3031b65f4100ba490222`; sealed bundle_sha256 `af46646f8e6721dc1718efc3dd5a6f4ca1ec16f103ebafd06aa4ecb8d2d2a0bc` (test_gate.json `91828fb677d7fc7c`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `a424d207e1c44f08e267f588b2122c787336055c`, source_tree_sha256 `48a7a17c749ac61c`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 3 (rerun reason: post_audit_rule_change — red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 29,906 | 0.467 | 0.588 [0.538, 0.643] | 0.430 [0.380, 0.480] | 0.430 [0.380, 0.480] | 1.021→0.939 | 0.716→0.679 | 0.296→0.268 (0.008) | 0.423→0.417 | 0.528 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `seated_likely`): accuracy 0.859, balanced acc 0.500, macro-F1 0.462. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 53,199.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 44,569 |
| seated_likely | yes | 25,686 | 0.913 | 0.419 | 0.575 | 0.913 (25,686) | 0.417 | strong | 0.860 | P=0.989 n=2,450 → strong | – | strong | 8,630 |
| upright_stationary | yes | 4,220 | 0.176 | 0.756 | 0.286 | 0.176 (4,220) | 0.417 | weak | 0.645 | P=0.163 n=13,204 → abstain | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 29,505 | 0.583 | 0.424 [0.373, 0.468] | 0.946 | 0.272 |  |
| hhar_watch | 2 | 74 | 0.919 | 0.919 [0.840, 1.000]† | 0.369 | 0.193 | descriptive |
| mhealth | 2 | 12 | 0.417 | 0.378 [0.333, 0.378]† | 0.727 | 0.192 | descriptive |
| opportunity | 1 | 37 | 0.714 | 0.769 [0.769, 0.769]† | 0.322 | 0.116 | descriptive |
| pamap2 | 2 | 119 | 0.703 | 0.661 [0.491, 0.951]† | 0.596 | 0.079 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.894 | 0.892 [0.756, 1.000]† | 0.377 | 0.074 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| seated_likely | 0.91/0.42/0.57 (25469); gate P 0.99 n 2403 → strong | 0.88/0.97/0.92 (37); gate P 1.00 n 4 → weak | 0.44/0.67/0.53 (6) | 0.88/1.00/0.94 (30); gate P 1.00 n 8 → weak | 1.00/0.41/0.58 (64); gate P 1.00 n 1 → weak | 1.00/0.79/0.88 (80); gate P 1.00 n 34 → strong |
| upright_stationary | 0.17/0.75/0.28 (4036); gate P 0.15 n 13033 → abstain | 0.97/0.86/0.91 (37); gate P 0.95 n 21 → weak | 0.33/0.17/0.22 (6) | 1.00/0.43/0.60 (7) | 0.59/1.00/0.74 (55); gate P 0.73 n 60 → abstain | 0.82/1.00/0.90 (79); gate P 0.81 n 90 → weak |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=29,906, macro-F1 0.430 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.467; ≥0.6: cov 0.794, P 0.463; ≥0.7: cov 0.596, P 0.459; ≥0.8: cov 0.379, P 0.454; ≥0.9: cov 0.100, P 0.487; ≥0.95: cov 0.001, P 0.944

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
      0       0       0       0
      0   10770   14916       0
      0    1029    3191       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 82,078 | 0.932 | 0.746 [0.670, 0.819] | 0.655 [0.600, 0.707] | 0.655 [0.600, 0.707] | 0.381→0.380 | 0.125→0.123 | 0.045→0.051 (0.001) | 0.031→0.031 | 0.025 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.894, balanced acc 0.250, macro-F1 0.236. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 9,575.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,286 | 0.938 | 0.998 | 0.967 | 0.937 (72,964) | 0.050 | strong | 0.300 | P=0.938 n=77,981 → weak | – | weak | 0 |
| walking | yes | 8,437 | 0.961 | 0.368 | 0.532 | 0.959 (8,306) | 0.062 | strong | 0.745 | P=0.974 n=2,676 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.902 | 0.729 | 0.807 | 0.908 (203) | 0.001 | strong | 0.855 | P=0.982 n=112 → strong | – | strong | 0 |
| stairs | yes | 152 | 0.192 | 0.888 | 0.316 | 0.195 (152) | 0.012 | strong | 0.565 | P=0.255 n=517 → abstain | – | abstain | 0 |
| cycling | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 808 |
| vehicle_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 3,518 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 5,249 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 80,428 | 0.530 | 0.528 [0.358, 0.604] | 0.387 | 0.052 |  |
| hhar_watch | 2 | 141 | 0.990 | 0.990 [0.980, 1.000]† | 0.040 | 0.027 | descriptive |
| mhealth | 2 | 36 | 0.833 | 0.825 [0.792, 1.000]† | 0.101 | 0.069 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.001 | 0.001 | descriptive |
| pamap2 | 2 | 269 | 0.989 | 0.975 [0.967, 0.980]† | 0.084 | 0.046 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.937 | 0.957 [0.915, 0.992]† | 0.064 | 0.016 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.94/1.00/0.97 (72032); gate P 0.94 n 76717 → weak | 1.00/1.00/1.00 (74); gate P 1.00 n 74 → strong | 1.00/1.00/1.00 (19); gate P 1.00 n 19 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 37 → strong | 1.00/0.98/0.99 (187); gate P 1.00 n 183 → strong | 0.98/1.00/0.99 (937); gate P 0.98 n 951 → strong |
| walking | 0.96/0.36/0.52 (8285); gate P 0.97 n 2540 → strong | 0.97/1.00/0.99 (35); gate P 1.00 n 32 → strong | 0.67/1.00/0.80 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.98/0.99 (43); gate P 1.00 n 37 → strong | 0.96/0.91/0.93 (70); gate P 1.00 n 63 → strong |
| running | 0.77/0.51/0.62 (103); gate P 0.96 n 54 → strong | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 2 → weak | 1.00/0.94/0.97 (80); gate P 1.00 n 46 → strong |
| stairs | 0.00/0.25/0.01 (8); gate P 0.01 n 383 → abstain | 1.00/0.97/0.98 (32); gate P 1.00 n 31 → strong | 1.00/0.33/0.50 (3); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.85/1.00/0.92 (29); gate P 0.87 n 31 → weak | 0.97/0.90/0.94 (80); gate P 1.00 n 71 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=82,078, macro-F1 0.655 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.997, P 0.934; ≥0.6: cov 0.991, P 0.937; ≥0.7: cov 0.984, P 0.940; ≥0.8: cov 0.974, P 0.944; ≥0.9: cov 0.958, P 0.949; ≥0.95: cov 0.936, P 0.955

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73118      78       0       3      87       0       0       0
   4843    3104       0      13     477       0       0       0
      0       0       0       0       0       0       0       0
      7      45       0     148       3       0       0       0
     13       4       0       0     135       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 14,127 | 0.535 | 0.731 [0.657, 0.781] | 0.412 [0.348, 0.474] | 0.412 [0.348, 0.474] | 0.489→0.816 | 0.325→0.579 | 0.032→0.199 (0.012) | 0.289→0.455 | 0.412 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.959, balanced acc 0.500, macro-F1 0.489. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 6,859.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 6,845 |
| desk_like | yes | 13,545 | 0.995 | 0.518 | 0.681 | 0.995 (13,545) | 0.455 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.078 | 0.945 | 0.143 | 0.078 (582) | 0.455 | strong | 0.555 | P=0.085 n=6,349 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 48 | 13,778 | 0.753 | 0.392 [0.328, 0.464] | 0.828 | 0.207 |  |
| pamap2 | 2 | 29 | 1.000 | 1.000 [1.000, 1.000]† | 0.138 | 0.128 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.897 | 0.896 [0.761, 0.991]† | 0.372 | 0.150 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | pamap2 | wisdm2019_watch |
|---|---|---|---|
| desk_like | 1.00/0.51/0.68 (13385) | 0.00/0.00/0.00 (0) | 0.84/0.98/0.90 (160) |
| repetitive_hand_motion | 0.06/0.99/0.11 (393); gate P 0.06 n 6195 → abstain | 1.00/1.00/1.00 (29); gate P 1.00 n 29 → weak | 0.98/0.81/0.89 (160); gate P 0.99 n 125 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=14,127, macro-F1 0.412 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.535; ≥0.6: cov 0.806, P 0.546; ≥0.7: cov 0.588, P 0.573; ≥0.8: cov 0.344, P 0.618; ≥0.9: cov 0.116, P 0.666; ≥0.95: cov 0.023, P 0.520

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0       0       0       0       0       0       0
      0    7010       0    6535       0       0       0
      0       0       0       0       0       0       0
      0      32       0     550       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.270.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.223 | 0.136 | -1.315 | 0.660 | 0.659 |
| capture24 | 95,579 | 0.224 | 0.136 | -1.337 | 0.661 | 0.658 |
| pamap2 | 234 | 0.108 | 0.203 | 0.653 | 0.814 | 0.953 |

## OOD

Bundle method `maha_global` (k=None), threshold 13.552 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.065 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
