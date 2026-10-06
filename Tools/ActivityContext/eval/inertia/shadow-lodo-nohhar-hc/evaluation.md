# Evaluation — `shadow-lodo-nohhar-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `cb2cd3200eaace919ab7f1a92cac5f1c22317a49760bba81f57f93a49fe5e596`; sealed bundle_sha256 `2bfa1d9f339a156a2e6a63df31737b54d030f42c7df5b8bfc1979733cb5cb2b2` (test_gate.json `2febc391c2f299d1`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,475 | 0.860 | 0.643 [0.629, 0.655] | 0.653 [0.636, 0.670] | 0.653 [0.636, 0.670] | 0.504→0.376 | 0.289→0.209 | 0.038→0.017 (0.004) | 0.096→0.019 | 0.057 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,473 | 0.911 | 0.923 | 0.917 | 0.905 (35,939) | 0.027 | weak | 0.300 | P=0.911 n=38,957 → weak | hhar_watch test: precision 0.000 at n_acc 30 -> abstain | abstain | 0 |
| seated_likely | yes | 31,782 | 0.815 | 0.882 | 0.847 | 0.776 (25,686) | 0.025 | weak | 0.300 | P=0.815 n=34,406 → weak | hhar_watch test: precision 0.750 at n_acc 40 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.468 | 0.123 | 0.195 | 0.530 (4,220) | 0.006 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.638 | 0.646 [0.630, 0.664] | 0.374 | 0.018 |  |
| hhar_watch | 2 | 74 | 0.459 | 0.325 [0.291, 0.358]† | 1.458 | 0.273 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.286 [0.190, 0.357]† | 0.879 | 0.440 | descriptive |
| opportunity | 1 | 37 | 0.643 | 0.684 [0.684, 0.684]† | 0.450 | 0.151 | descriptive |
| pamap2 | 2 | 204 | 0.726 | 0.736 [0.625, 0.746]† | 0.615 | 0.099 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.672 | 0.485 [0.373, 0.572]† | 0.717 | 0.132 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38395); gate P 0.91 n 38827 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 30 → abstain | 0.40/1.00/0.57 (4); gate P 0.40 n 10 → weak | 0.00/0.00/0.00 (0) | 0.90/0.81/0.85 (74); gate P 0.90 n 67 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 23 → weak |
| seated_likely | 0.82/0.88/0.85 (31554); gate P 0.82 n 34141 → weak | 0.75/0.81/0.78 (37); gate P 0.75 n 40 → abstain | 0.00/0.00/0.00 (6); gate P 0.00 n 5 → weak | 0.86/1.00/0.92 (30); gate P 0.86 n 35 → weak | 0.61/0.79/0.69 (75); gate P 0.61 n 96 → abstain | 0.67/0.75/0.71 (80); gate P 0.67 n 89 → abstain |
| upright_stationary | 0.43/0.11/0.17 (4036) | 1.00/0.11/0.20 (37) | 1.00/0.17/0.29 (6) | 1.00/0.29/0.44 (7) | 0.78/0.58/0.67 (55) | 1.00/0.59/0.75 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.425, R 0.992, F1 0.595 (support 2,569, predicted 6,004)
- awake-lying gate at the frozen tau: pooled P=0.425 n=6,004 → abstain; per dataset capture24 P=0.423 n=5,874 → abstain, hhar_watch P=0.000 n=30 → abstain, mhealth P=0.400 n=10 → weak, pamap2 P=0.896 n=67 → weak, wisdm2019_watch P=0.000 n=23 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.653 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.865; ≥0.6: cov 0.915, P 0.885; ≥0.7: cov 0.828, P 0.907; ≥0.8: cov 0.701, P 0.930; ≥0.9: cov 0.475, P 0.957; ≥0.95: cov 0.252, P 0.970

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35502    2920      51       0
   3204   28037     541       0
    251    3449     520       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.872 | 0.658 [0.629, 0.691] | 0.690 [0.662, 0.713] | 0.690 [0.662, 0.713] | 0.528→0.367 | 0.254→0.176 | 0.072→0.022 (0.003) | 0.052→0.010 | 0.024 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,188 | 0.911 | 0.969 | 0.939 | 0.911 (72,964) | 0.023 | strong | 0.815 | P=0.976 n=65,463 → strong | – | strong | 0 |
| walking | yes | 8,535 | 0.798 | 0.562 | 0.659 | 0.791 (8,306) | 0.013 | strong | 0.900 | P=0.984 n=2,624 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.880 | 0.901 | 0.891 | 0.880 (203) | 0.001 | strong | 0.745 | P=0.940 n=167 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.714 | 0.789 | 0.750 | 0.714 (152) | 0.002 | weak | 0.555 | P=0.876 n=121 → weak | – | weak | 0 |
| cycling | yes | 808 | 0.763 | 0.598 | 0.670 | 0.763 (808) | 0.002 | weak | 0.300 | P=0.765 n=631 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.732 | 0.432 | 0.543 | 0.733 (3,518) | 0.020 | weak | 0.525 | P=0.838 n=1,564 → weak | – | weak | 0 |
| other | yes | 5,249 | 0.395 | 0.357 | 0.375 | 0.400 (5,249) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.546 | 0.570 [0.448, 0.600] | 0.370 | 0.023 |  |
| hhar_watch | 2 | 174 | 0.924 | 0.751 [0.697, 0.985]† | 0.242 | 0.097 | descriptive |
| mhealth | 2 | 49 | 0.863 | 0.845 [0.827, 0.949]† | 0.210 | 0.095 | descriptive |
| opportunity | 1 | 37 | 0.946 | 0.486 [0.486, 0.486]† | 0.235 | 0.179 | descriptive |
| pamap2 | 2 | 397 | 0.805 | 0.789 [0.764, 0.789]† | 0.445 | 0.046 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.922 | 0.625 [0.597, 0.762]† | 0.142 | 0.070 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71934); gate P 0.98 n 64409 → strong | 0.96/1.00/0.98 (74); gate P 1.00 n 67 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.95/0.97 (37); gate P 1.00 n 20 → weak | 0.85/0.88/0.86 (187); gate P 0.95 n 146 → strong | 1.00/0.99/0.99 (937); gate P 1.00 n 805 → strong |
| walking | 0.80/0.55/0.65 (8383); gate P 0.98 n 2515 → strong | 0.92/0.97/0.94 (35); gate P 1.00 n 26 → weak | 0.67/1.00/0.80 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.88/0.88/0.88 (43); gate P 1.00 n 18 → weak | 0.86/0.96/0.91 (70); gate P 1.00 n 61 → strong |
| running | 0.77/0.82/0.79 (103); gate P 0.88 n 83 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.99/0.99 (80); gate P 1.00 n 64 → strong |
| stairs | 0.03/0.12/0.04 (8); gate P 0.07 n 15 → weak | 0.97/0.97/0.97 (32); gate P 1.00 n 29 → weak | 1.00/0.33/0.50 (3) | 0.00/0.00/0.00 (0) | 0.73/0.93/0.82 (29); gate P 0.96 n 24 → weak | 1.00/0.75/0.86 (80); gate P 1.00 n 53 → strong |
| cycling | 0.74/0.57/0.65 (743); gate P 0.74 n 575 → abstain | 1.00/0.76/0.86 (33); gate P 1.00 n 25 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.96/0.98 (28); gate P 1.00 n 27 → weak | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.73/0.43/0.55 (3484); gate P 0.84 n 1560 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.80/0.12/0.21 (34); gate P 1.00 n 3 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak |
| other | 0.39/0.35/0.37 (5174) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.70/0.86/0.77 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.690 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.913, P 0.918; ≥0.6: cov 0.862, P 0.942; ≥0.7: cov 0.819, P 0.960; ≥0.8: cov 0.773, P 0.973; ≥0.9: cov 0.679, P 0.985; ≥0.95: cov 0.525, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70919     651       0       9       1      28     352    1228
   2108    4794       0       3      29      87      97    1417
      0       0       0       0       0       0       0       0
      4      16       0     183       0       0       0       0
      3      19       0       0     120       0       0      10
    239      33       0       0       0     483      10      43
   1754      77       0       0       0       2    1519     166
   2794     420       0      13      18      33      98    1873
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.643 | 0.434 [0.393, 0.546] | 0.423 [0.375, 0.488] | 0.423 [0.375, 0.488] | 0.938→0.705 | 0.571→0.461 | 0.094→0.072 (0.010) | 0.171→0.054 | 0.265 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.415 | 0.094 | 0.154 | 0.415 (6,845) | 0.077 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.666 | 0.937 | 0.778 | 0.666 (13,545) | 0.069 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.440 | 0.271 | 0.336 | 0.440 (582) | 0.016 | weak | 0.930 | P=0.635 n=85 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.368 | 0.342 [0.299, 0.384] | 0.705 | 0.073 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.642 | 0.798 | descriptive |
| pamap2 | 2 | 60 | 0.240 | 0.227 [0.190, 0.259]† | 1.270 | 0.390 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.863 | 0.860 [0.709, 0.981]† | 0.551 | 0.140 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.41/0.09/0.15 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.03/0.06 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.67/0.94/0.78 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.78/1.00/0.88 (160) |
| repetitive_hand_motion | 0.13/0.07/0.09 (393); gate P 0.00 n 31 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.45/0.62 (29) | 1.00/0.72/0.84 (160); gate P 1.00 n 54 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.423 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.952, P 0.653; ≥0.6: cov 0.803, P 0.680; ≥0.7: cov 0.602, P 0.721; ≥0.8: cov 0.282, P 0.788; ≥0.9: cov 0.022, P 0.761; ≥0.95: cov 0.006, P 0.631

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    646    6084       0     115       0       0       0
    772   12687       0      86       0       0       0
      0       0       0       0       0       0       0
    139     285       0     158       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.933 | 0.066 | 0.089→0.088 | 0.198→0.185 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.901 | 0.061 | 0.087→0.085 | 0.199→0.168 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.932 | 0.098 | 0.087→0.085 | 0.194→0.177 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.906 | 0.080 | 0.097→0.095 | 0.219→0.190 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.12/0.53/0.20 | 0.14/0.58/0.22 | 2.7 / 4.3 |
| stand_to_sit_like | 0.80 (weak) | 36 | 0.08/0.19/0.11 | 0.20/0.50/0.28 | 6.5 / 8.9 |
| walk_start | 0.70 (weak) | 405 | 0.44/0.39/0.42 | 0.52/0.46/0.49 | 2.4 / 6.4 |
| walk_stop | 0.60 (weak) | 404 | 0.46/0.36/0.40 | 0.58/0.44/0.50 | 2.5 / 6.8 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.139.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.494 | 0.779 | 0.765 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.491 | 0.778 | 0.765 |
| pamap2 | 234 | 0.108 | 0.203 | 0.645 | 0.845 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.291 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.

**heldout_dataset_hhar_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,229 | 174 | 0.426 | 0.005 (0.002) | 0.992 | 0.931 | 0.046 | 0.069 |
| knn@10 | 97,229 | 174 | 0.518 | 0.002 (0.002) | 0.798 | 0.971 | 0.041 | 0.017 |
| knn@20 | 97,229 | 174 | 0.533 | 0.002 (0.002) | 0.772 | 0.954 | 0.039 | 0.029 |
| knn@5 | 97,229 | 174 | 0.518 | 0.002 (0.002) | 0.806 | 0.966 | 0.042 | 0.023 |
| maha_global | 97,229 | 174 | 0.571 | 0.002 (0.002) | 0.891 | 0.966 | 0.050 | 0.034 |
| maha_min | 97,229 | 174 | 0.544 | 0.002 (0.002) | 0.920 | 0.989 | 0.050 | 0.011 |
| maha_rel | 97,229 | 174 | 0.274 | 0.001 (0.002) | 0.995 | 0.948 | 0.046 | 0.046 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.181, AURC 0.042; with OOD rejection max coverage 0.950, risk 0.176, AURC 0.040.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 97,229 | 850 | 0.365 | 0.006 (0.009) | 0.960 | 0.978 | 0.046 | 0.019 |
| knn@10 | 97,229 | 850 | 0.693 | 0.016 (0.009) | 0.784 | 0.932 | 0.041 | 0.056 |
| knn@20 | 97,229 | 850 | 0.705 | 0.018 (0.009) | 0.793 | 0.922 | 0.039 | 0.060 |
| knn@5 | 97,229 | 850 | 0.674 | 0.015 (0.009) | 0.776 | 0.931 | 0.042 | 0.058 |
| maha_global | 97,229 | 850 | 0.509 | 0.040 (0.009) | 0.881 | 0.965 | 0.050 | 0.035 |
| maha_min | 97,229 | 850 | 0.511 | 0.040 (0.009) | 0.924 | 0.965 | 0.050 | 0.035 |
| maha_rel | 97,229 | 850 | 0.579 | 0.058 (0.009) | 0.933 | 0.753 | 0.046 | 0.241 |

OOD method selection (VAL only): chosen `maha_global` from ood-hc; VAL AUROC energy 0.788, knn@10 0.558, knn@20 0.555, knn@5 0.563, maha_global 0.823, maha_min 0.824


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
