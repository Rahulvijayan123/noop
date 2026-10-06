# Evaluation — `shadow-ood-nf` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `bb828ffb3235147e9a82e6864e03d99ebbe1dae495025f1ba5c8300a503a9bec`; sealed bundle_sha256 `5916b911e7d062820f41ecd47b66da991802ad0da152d8822760b630bd0d7d84` (test_gate.json `4026a02c8f41df74`; the served artifact carries the gate); encoder `standin:nara-imu-feat-1-accel` (standin); evidence_tier_max `shadow`
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
| 74,475 | 0.816 | 0.574 [0.562, 0.587] | 0.567 [0.554, 0.582] | 0.567 [0.554, 0.582] | 0.925→0.552 | 0.556→0.290 | 0.293→0.086 (0.005) | 0.288→0.082 | 0.159 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,970 | 0.827 | 0.947 | 0.883 | 0.810 (35,939) | 0.115 | abstain | 1.000 | – | – | abstain | 0 |
| seated_likely | yes | 30,285 | 0.802 | 0.754 | 0.777 | 0.764 (25,686) | 0.114 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.414 | 0.022 | 0.042 | 0.475 (4,220) | 0.015 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.575 | 0.569 [0.556, 0.581] | 0.545 | 0.089 |  |
| hhar_watch | 2 | 74 | 0.014 | 0.017 [0.000, 0.032]† | 2.634 | 0.733 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.133 [0.133, 0.133]† | 2.019 | 0.501 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.518 | 0.122 | descriptive |
| pamap2 | 2 | 204 | 0.559 | 0.481 [0.300, 0.543]† | 0.897 | 0.145 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.225 | 0.153 [0.100, 0.190]† | 1.873 | 0.445 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.83/0.95/0.88 (39892) | 0.00/0.00/0.00 (0) | 0.25/1.00/0.40 (4) | 0.00/0.00/0.00 (0) | 0.78/0.86/0.82 (74) | 0.00/0.00/0.00 (0) |
| seated_likely | 0.80/0.76/0.78 (30057) | 0.50/0.03/0.05 (37) | 0.00/0.00/0.00 (6) | 0.81/1.00/0.90 (30) | 0.50/0.81/0.62 (75) | 0.47/0.45/0.46 (80) |
| upright_stationary | 0.42/0.02/0.04 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.339, R 0.998, F1 0.506 (support 4,066, predicted 11,970)


Wrist-only: n=74,475, macro-F1 0.567 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.819; ≥0.6: cov 0.908, P 0.836; ≥0.7: cov 0.792, P 0.863; ≥0.8: cov 0.275, P 0.844; ≥0.9: cov 0.045, P 0.751; ≥0.95: cov 0.009, P 0.650

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  37856    2110       4       0
   7323   22833     129       0
    591    3535      94       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.838 | 0.376 [0.353, 0.395] | 0.393 [0.363, 0.415] | 0.393 [0.363, 0.415] | 1.021→0.507 | 0.506→0.233 | 0.278→0.044 (0.004) | 0.126→0.018 | 0.036 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,223 | 0.872 | 0.975 | 0.921 | 0.872 (72,964) | 0.054 | strong | 0.885 | P=0.974 n=58,577 → strong | – | strong | 0 |
| walking | yes | 8,500 | 0.707 | 0.470 | 0.564 | 0.698 (8,306) | 0.020 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.783 | 0.852 | 0.816 | 0.790 (203) | 0.003 | weak | 0.835 | P=0.950 n=121 → strong | – | weak | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.006 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 808 | 0.638 | 0.118 | 0.199 | 0.638 (808) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.000 (3,518) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.302 | 0.217 | 0.252 | 0.305 (5,249) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.379 | 0.392 [0.276, 0.411] | 0.499 | 0.044 |  |
| hhar_watch | 2 | 174 | 0.500 | 0.304 [0.304, 0.365]† | 0.959 | 0.210 | descriptive |
| mhealth | 2 | 49 | 0.510 | 0.427 [0.427, 0.543]† | 0.768 | 0.193 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.276 | 0.231 | descriptive |
| pamap2 | 2 | 397 | 0.445 | 0.361 [0.309, 0.501]† | 1.114 | 0.134 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.608 | 0.362 [0.324, 0.403]† | 0.845 | 0.111 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.87/0.98/0.92 (71969); gate P 0.97 n 57866 → strong | 0.69/1.00/0.82 (74); gate P 1.00 n 74 → strong | 0.64/0.95/0.77 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 10 → weak | 0.75/0.89/0.81 (187); gate P 0.99 n 118 → strong | 1.00/0.83/0.91 (937); gate P 1.00 n 493 → strong |
| walking | 0.73/0.46/0.57 (8348) | 0.54/1.00/0.70 (35) | 0.44/1.00/0.62 (4) | 0.00/0.00/0.00 (0) | 0.33/0.70/0.45 (43) | 0.26/0.81/0.39 (70) |
| running | 0.73/0.87/0.79 (103); gate P 0.92 n 62 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.43/1.00/0.61 (10); gate P 0.91 n 11 → weak | 0.98/0.79/0.87 (80); gate P 1.00 n 38 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) |
| cycling | 0.68/0.13/0.21 (743) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 1.00/0.07/0.13 (28) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) |
| other | 0.30/0.21/0.25 (5174) | 0.00/0.00/0.00 (0) | 0.50/0.11/0.18 (9) | 0.00/0.00/0.00 (0) | 0.62/0.45/0.53 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.393 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.905, P 0.886; ≥0.6: cov 0.863, P 0.906; ≥0.7: cov 0.820, P 0.924; ≥0.8: cov 0.749, P 0.945; ≥0.9: cov 0.609, P 0.980; ≥0.95: cov 0.081, P 0.989

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71374     757       0      14       4      19       0    1055
   3044    3994       0      12      28      11       0    1411
      0       0       0       0       0       0       0       0
      5      25       0     173       0       0       0       0
      4     142       0       0       0       0       0       6
    578      54       0       3       1      95       0      77
   3353      79       0       0       0       1       0      85
   3467     602       0      19       1      23       0    1137
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.395 [0.362, 0.493] | 0.353 [0.307, 0.422] | 0.353 [0.307, 0.422] | 1.048→0.738 | 0.632→0.478 | 0.135→0.068 (0.008) | 0.200→0.050 | 0.340 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.487 | 0.022 | 0.043 | 0.487 (6,845) | 0.071 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.654 | 0.981 | 0.785 | 0.654 (13,545) | 0.063 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.316 | 0.180 | 0.230 | 0.316 (582) | 0.015 | weak | 0.910 | P=0.422 n=83 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.341 | 0.285 [0.261, 0.304] | 0.735 | 0.068 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.540 | 0.779 | descriptive |
| pamap2 | 2 | 60 | 0.032 | 0.040 [0.000, 0.070]† | 1.990 | 0.691 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.803 | 0.795 [0.609, 0.937]† | 0.693 | 0.151 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.48/0.02/0.04 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.98/0.79 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.72/1.00/0.84 (160) |
| repetitive_hand_motion | 0.03/0.02/0.03 (393); gate P 0.00 n 48 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 1.00/0.61/0.75 (160); gate P 1.00 n 35 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.353 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.982, P 0.650; ≥0.6: cov 0.914, P 0.662; ≥0.7: cov 0.648, P 0.684; ≥0.8: cov 0.007, P 0.404; ≥0.9: cov 0.004, P 0.435; ≥0.95: cov 0.003, P 0.422

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    154    6562       0     129       0       0       0
    157   13290       0      98       0       0       0
      0       0       0       0       0       0       0
      5     472       0     105       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.911 | 0.035 | 0.083→0.079 | 0.203→0.166 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.881 | 0.033 | 0.093→0.085 | 0.233→0.177 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.899 | 0.041 | 0.115→0.106 | 0.273→0.228 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.873 | 0.040 | 0.130→0.109 | 0.312→0.233 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.15/0.64/0.24 | 0.16/0.67/0.25 | 2.1 / 3.7 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.04/0.06/0.05 | 0.13/0.19/0.16 | 8.2 / 8.8 |
| walk_start | 0.30 (weak) | 405 | 0.31/0.41/0.35 | 0.37/0.50/0.42 | 2.0 / 6.3 |
| walk_stop | 0.35 (weak) | 404 | 0.32/0.40/0.36 | 0.40/0.49/0.44 | 2.5 / 6.5 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.170.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.121 | 0.136 | 0.294 | 0.774 | 0.776 |
| capture24 | 95,579 | 0.121 | 0.136 | 0.289 | 0.773 | 0.777 |
| pamap2 | 234 | 0.138 | 0.203 | 0.496 | 0.794 | 0.628 |

## OOD

Bundle method `knn` (k=20), threshold 0.322 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.049 on 95,637 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 2,048 | 0.767 | 0.080 (0.021) | 0.990 | 0.745 | 0.051 | 0.256 |
| knn@10 | 95,637 | 2,048 | 0.797 | 0.086 (0.021) | 0.465 | 0.809 | 0.048 | 0.188 |
| knn@20 | 95,637 | 2,048 | 0.797 | 0.077 (0.021) | 0.454 | 0.815 | 0.049 | 0.178 |
| knn@5 | 95,637 | 2,048 | 0.797 | 0.091 (0.021) | 0.470 | 0.796 | 0.048 | 0.198 |
| maha_global | 95,637 | 2,048 | 0.781 | 0.173 (0.021) | 0.568 | 0.695 | 0.058 | 0.320 |
| maha_min | 95,637 | 2,048 | 0.736 | 0.155 (0.021) | 0.691 | 0.737 | 0.050 | 0.263 |
| maha_rel | 95,637 | 2,048 | 0.269 | 0.073 (0.021) | 0.977 | 0.912 | 0.049 | 0.088 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.214, AURC 0.053; with OOD rejection max coverage 0.949, risk 0.203, AURC 0.047.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 850 | 0.600 | 0.012 (0.009) | 0.900 | 0.951 | 0.051 | 0.052 |
| knn@10 | 95,637 | 850 | 0.672 | 0.017 (0.009) | 0.738 | 0.921 | 0.048 | 0.074 |
| knn@20 | 95,637 | 850 | 0.667 | 0.017 (0.009) | 0.758 | 0.948 | 0.049 | 0.049 |
| knn@5 | 95,637 | 850 | 0.676 | 0.017 (0.009) | 0.718 | 0.900 | 0.048 | 0.094 |
| maha_global | 95,637 | 850 | 0.555 | 0.012 (0.009) | 0.929 | 0.965 | 0.058 | 0.045 |
| maha_min | 95,637 | 850 | 0.573 | 0.017 (0.009) | 0.969 | 0.966 | 0.050 | 0.034 |
| maha_rel | 95,637 | 850 | 0.579 | 0.014 (0.009) | 0.935 | 0.873 | 0.049 | 0.124 |

OOD method selection (VAL only): chosen `knn@20` from ood-nf; VAL AUROC energy 0.765, knn@10 0.842, knn@20 0.843, knn@5 0.836, maha_global 0.821, maha_min 0.799


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
