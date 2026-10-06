# Evaluation — `shadow-linear-hc` (arch)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `6dac0eddb1f9875cea6999450d666a57e3d827d686ff7451f85435117ed7c38f`; sealed bundle_sha256 `55ec82170e80c93c913a1c9f023c61aa2efc0ac2d14827a4ab77e75eda80fe39` (test_gate.json `90bfbccd4922ade6`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,475 | 0.847 | 0.617 [0.605, 0.627] | 0.618 [0.605, 0.628] | 0.618 [0.605, 0.628] | 0.599→0.413 | 0.346→0.231 | 0.043→0.014 (0.004) | 0.131→0.031 | 0.070 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,714 | 0.894 | 0.928 | 0.911 | 0.886 (35,939) | 0.036 | strong | 0.955 | P=0.989 n=8,269 → strong | – | strong | 0 |
| seated_likely | yes | 31,541 | 0.808 | 0.851 | 0.829 | 0.768 (25,686) | 0.043 | weak | 0.300 | P=0.808 n=33,218 → weak | hhar_watch test: precision 0.595 at n_acc 37 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.288 | 0.071 | 0.114 | 0.315 (4,220) | 0.015 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.617 | 0.618 [0.606, 0.630] | 0.409 | 0.015 |  |
| hhar_watch | 2 | 74 | 0.297 | 0.198 [0.182, 0.211]† | 1.844 | 0.325 | descriptive |
| mhealth | 2 | 16 | 0.556 | 0.433 [0.317, 0.556]† | 1.385 | 0.195 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.454 | 0.124 | descriptive |
| pamap2 | 2 | 204 | 0.601 | 0.562 [0.432, 0.571]† | 0.737 | 0.116 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.457 | 0.282 [0.182, 0.366]† | 0.950 | 0.238 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.90/0.93/0.91 (38634); gate P 0.99 n 8267 → strong | 0.00/0.00/0.00 (0) | 0.67/1.00/0.80 (4) | 0.00/0.00/0.00 (0) | 0.90/0.82/0.86 (76); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0) |
| seated_likely | 0.81/0.85/0.83 (31315); gate P 0.81 n 32881 → weak | 0.59/0.59/0.59 (37); gate P 0.59 n 37 → abstain | 0.40/0.67/0.50 (6); gate P 0.40 n 10 → weak | 0.81/1.00/0.90 (30); gate P 0.81 n 37 → weak | 0.50/0.88/0.64 (73); gate P 0.50 n 127 → abstain | 0.49/0.78/0.60 (80); gate P 0.49 n 126 → abstain |
| upright_stationary | 0.28/0.07/0.11 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.75/0.11/0.19 (55) | 1.00/0.14/0.24 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.395, R 0.993, F1 0.565 (support 2,810, predicted 7,061)
- awake-lying gate at the frozen tau: pooled P=0.696 n=309 → abstain; per dataset capture24 P=0.694 n=307 → abstain, pamap2 P=1.000 n=2 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.618 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.851; ≥0.6: cov 0.920, P 0.869; ≥0.7: cov 0.831, P 0.890; ≥0.8: cov 0.688, P 0.913; ≥0.9: cov 0.412, P 0.945; ≥0.95: cov 0.171, P 0.968

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35945    2731      38       0
   3999   26838     704       0
    271    3649     300       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.860 | 0.564 [0.506, 0.616] | 0.620 [0.572, 0.658] | 0.620 [0.572, 0.658] | 0.796→0.424 | 0.376→0.198 | 0.153→0.037 (0.004) | 0.092→0.016 | 0.032 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,213 | 0.889 | 0.978 | 0.932 | 0.889 (72,964) | 0.041 | strong | 0.865 | P=0.976 n=58,501 → strong | – | strong | 0 |
| walking | yes | 8,510 | 0.818 | 0.508 | 0.627 | 0.812 (8,306) | 0.015 | strong | 0.920 | P=0.987 n=1,958 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.951 | 0.665 | 0.783 | 0.951 (203) | 0.003 | strong | 0.300 | P=0.951 n=142 → strong | capture24 test: precision 0.883 at n_acc 60 -> weak | weak | 0 |
| stairs | yes | 152 | 0.690 | 0.763 | 0.725 | 0.690 (152) | 0.004 | weak | 0.640 | P=0.861 n=101 → weak | – | weak | 0 |
| cycling | yes | 808 | 0.715 | 0.546 | 0.619 | 0.715 (808) | 0.004 | weak | 0.300 | P=0.718 n=614 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.760 | 0.246 | 0.372 | 0.764 (3,518) | 0.026 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.343 | 0.243 | 0.284 | 0.347 (5,249) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.465 | 0.508 [0.401, 0.559] | 0.426 | 0.038 |  |
| hhar_watch | 2 | 174 | 0.887 | 0.902 [0.847, 0.944]† | 0.307 | 0.097 | descriptive |
| mhealth | 2 | 49 | 0.788 | 0.736 [0.728, 0.922]† | 0.375 | 0.118 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.238 | 0.202 | descriptive |
| pamap2 | 2 | 397 | 0.764 | 0.759 [0.736, 0.895]† | 0.529 | 0.037 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.853 | 0.583 [0.522, 0.763]† | 0.279 | 0.069 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.89/0.98/0.93 (71959); gate P 0.98 n 57593 → strong | 0.85/1.00/0.92 (74); gate P 1.00 n 73 → strong | 0.94/0.84/0.89 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 14 → weak | 0.83/0.91/0.87 (187); gate P 0.98 n 130 → strong | 1.00/0.96/0.98 (937); gate P 1.00 n 675 → strong |
| walking | 0.82/0.50/0.62 (8358); gate P 0.99 n 1892 → strong | 0.97/0.97/0.97 (35); gate P 1.00 n 17 → weak | 0.57/1.00/0.73 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.79/0.77/0.78 (43); gate P 1.00 n 13 → weak | 0.76/0.96/0.85 (70); gate P 1.00 n 32 → strong |
| running | 0.88/0.51/0.65 (103); gate P 0.88 n 60 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.78/0.87 (80); gate P 1.00 n 62 → strong |
| stairs | 0.06/0.25/0.10 (8); gate P 0.00 n 5 → weak | 0.97/1.00/0.98 (32); gate P 1.00 n 22 → weak | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.63/0.83/0.72 (29); gate P 0.76 n 25 → weak | 0.89/0.72/0.80 (80); gate P 0.94 n 49 → weak |
| cycling | 0.70/0.53/0.60 (743); gate P 0.71 n 558 → abstain | 1.00/0.58/0.73 (33); gate P 1.00 n 19 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.86/0.92 (28); gate P 1.00 n 24 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 9 → weak |
| vehicle_motion | 0.76/0.25/0.37 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.12/0.21 (34) | 0.00/0.00/0.00 (0) |
| other | 0.34/0.23/0.28 (5174) | 0.00/0.00/0.00 (0) | 0.73/0.89/0.80 (9) | 0.00/0.00/0.00 (0) | 0.77/0.86/0.81 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.620 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.933, P 0.895; ≥0.6: cov 0.882, P 0.919; ≥0.7: cov 0.829, P 0.942; ≥0.8: cov 0.756, P 0.964; ≥0.9: cov 0.589, P 0.981; ≥0.95: cov 0.367, P 0.987

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71638     482       0       4       0      62     142     885
   2607    4325       0       2      34      58      81    1403
      0       0       0       0       0       0       0       0
      4      56       0     135       7       0       0       1
      3      22       0       0     116       0       0      11
    292      32       0       0       0     441       1      42
   2465      66       0       0       0      17     866     104
   3568     305       0       1      11      39      49    1276
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.643 | 0.434 [0.392, 0.546] | 0.422 [0.375, 0.486] | 0.422 [0.375, 0.486] | 0.938→0.705 | 0.571→0.461 | 0.093→0.072 (0.010) | 0.171→0.054 | 0.265 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.413 | 0.093 | 0.152 | 0.413 (6,845) | 0.077 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.666 | 0.937 | 0.778 | 0.666 (13,545) | 0.069 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.438 | 0.271 | 0.335 | 0.438 (582) | 0.016 | weak | 0.930 | P=0.635 n=85 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.368 | 0.341 [0.299, 0.384] | 0.705 | 0.073 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.641 | 0.798 | descriptive |
| pamap2 | 2 | 60 | 0.240 | 0.227 [0.190, 0.259]† | 1.269 | 0.390 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.863 | 0.860 [0.709, 0.981]† | 0.550 | 0.139 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.41/0.09/0.15 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.03/0.06 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.67/0.94/0.78 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.78/1.00/0.88 (160) |
| repetitive_hand_motion | 0.12/0.07/0.09 (393); gate P 0.00 n 31 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.45/0.62 (29) | 1.00/0.72/0.84 (160); gate P 1.00 n 54 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.422 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.951, P 0.653; ≥0.6: cov 0.803, P 0.681; ≥0.7: cov 0.602, P 0.721; ≥0.8: cov 0.282, P 0.788; ≥0.9: cov 0.022, P 0.759; ≥0.95: cov 0.006, P 0.631

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    640    6090       0     115       0       0       0
    771   12686       0      88       0       0       0
      0       0       0       0       0       0       0
    139     285       0     158       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.926 | 0.063 | 0.102→0.099 | 0.235→0.213 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.893 | 0.053 | 0.101→0.099 | 0.226→0.200 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.923 | 0.091 | 0.104→0.101 | 0.232→0.214 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.900 | 0.075 | 0.107→0.104 | 0.239→0.212 | abstain→abstain |
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

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.139.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.495 | 0.780 | 0.765 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.492 | 0.779 | 0.765 |
| pamap2 | 234 | 0.107 | 0.203 | 0.645 | 0.845 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
