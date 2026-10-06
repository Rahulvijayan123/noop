# Evaluation — `shadow-seed1-hc` (seed)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `1141f03851e3f4e04f5247a59c9118b288cff750fb68a22ad5e7e5541c8cffc3`; sealed bundle_sha256 `f91941703727b82d930d2265797b4b85684e9cc58ca8caf11e6ca48152965f74` (test_gate.json `578f28d5a84515af`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
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
| 74,475 | 0.861 | 0.650 [0.634, 0.667] | 0.663 [0.643, 0.683] | 0.663 [0.643, 0.683] | 0.506→0.372 | 0.290→0.207 | 0.036→0.021 (0.004) | 0.095→0.021 | 0.056 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,431 | 0.913 | 0.923 | 0.918 | 0.908 (35,939) | 0.031 | strong | 0.950 | P=0.984 n=14,511 → strong | – | strong | 0 |
| seated_likely | yes | 31,824 | 0.817 | 0.882 | 0.848 | 0.778 (25,686) | 0.025 | weak | 0.300 | P=0.817 n=34,334 → weak | pamap2 test: precision 0.639 at n_acc 83 -> abstain | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.469 | 0.147 | 0.224 | 0.522 (4,220) | 0.006 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.644 | 0.654 [0.638, 0.674] | 0.370 | 0.021 |  |
| hhar_watch | 2 | 74 | 0.662 | 0.487 [0.473, 0.497]† | 1.021 | 0.115 | descriptive |
| mhealth | 2 | 16 | 0.611 | 0.546 [0.357, 0.722]† | 0.762 | 0.317 | descriptive |
| opportunity | 1 | 37 | 0.643 | 0.684 [0.684, 0.684]† | 0.447 | 0.118 | descriptive |
| pamap2 | 2 | 204 | 0.745 | 0.749 [0.662, 0.749]† | 0.583 | 0.077 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.710 | 0.513 [0.417, 0.590]† | 0.705 | 0.092 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38352); gate P 0.98 n 14502 → strong | 0.00/0.00/0.00 (0) | 0.44/1.00/0.62 (4) | 0.00/0.00/0.00 (0) | 0.90/0.83/0.86 (75); gate P 0.86 n 7 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak |
| seated_likely | 0.82/0.88/0.85 (31597); gate P 0.82 n 34091 → weak | 0.87/0.92/0.89 (37); gate P 0.87 n 39 → weak | 0.33/0.17/0.22 (6); gate P 0.33 n 3 → weak | 0.86/1.00/0.92 (30); gate P 0.86 n 35 → weak | 0.64/0.72/0.68 (74); gate P 0.64 n 83 → abstain | 0.72/0.75/0.74 (80); gate P 0.72 n 83 → abstain |
| upright_stationary | 0.43/0.13/0.19 (4036) | 0.94/0.41/0.57 (37) | 1.00/0.67/0.80 (6) | 1.00/0.29/0.44 (7) | 0.73/0.69/0.71 (55) | 1.00/0.67/0.80 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.428, R 0.993, F1 0.598 (support 2,527, predicted 5,869)
- awake-lying gate at the frozen tau: pooled P=0.622 n=621 → abstain; per dataset capture24 P=0.621 n=612 → abstain, pamap2 P=0.857 n=7 → weak, wisdm2019_watch P=0.000 n=2 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.663 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.866; ≥0.6: cov 0.908, P 0.888; ≥0.7: cov 0.814, P 0.909; ≥0.8: cov 0.687, P 0.933; ≥0.9: cov 0.472, P 0.958; ≥0.95: cov 0.273, P 0.971

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35456    2933      42       0
   3109   28053     662       0
    250    3348     622       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.870 | 0.680 [0.642, 0.715] | 0.666 [0.634, 0.695] | 0.666 [0.634, 0.695] | 0.567→0.376 | 0.282→0.180 | 0.062→0.019 (0.003) | 0.059→0.010 | 0.025 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,190 | 0.916 | 0.962 | 0.939 | 0.916 (72,964) | 0.019 | strong | 0.815 | P=0.976 n=64,858 → strong | – | strong | 0 |
| walking | yes | 8,533 | 0.783 | 0.574 | 0.662 | 0.776 (8,306) | 0.014 | strong | 0.965 | P=0.983 n=2,658 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.890 | 0.837 | 0.863 | 0.890 (203) | 0.000 | strong | 0.725 | P=0.935 n=153 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.416 | 0.868 | 0.563 | 0.419 (152) | 0.003 | weak | 0.860 | P=0.773 n=154 → abstain | – | abstain | 0 |
| cycling | yes | 808 | 0.717 | 0.675 | 0.695 | 0.717 (808) | 0.001 | weak | 0.300 | P=0.718 n=759 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.663 | 0.483 | 0.559 | 0.664 (3,518) | 0.018 | weak | 0.680 | P=0.821 n=1,599 → weak | – | weak | 0 |
| other | yes | 5,249 | 0.400 | 0.362 | 0.380 | 0.405 (5,249) | 0.013 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.570 | 0.567 [0.454, 0.597] | 0.380 | 0.019 |  |
| hhar_watch | 2 | 174 | 0.978 | 0.978 [0.955, 1.000]† | 0.087 | 0.049 | descriptive |
| mhealth | 2 | 49 | 0.863 | 0.845 [0.827, 0.949]† | 0.158 | 0.083 | descriptive |
| opportunity | 1 | 37 | 0.973 | 0.493 [0.493, 0.493]† | 0.249 | 0.189 | descriptive |
| pamap2 | 2 | 397 | 0.806 | 0.795 [0.745, 0.800]† | 0.448 | 0.072 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.931 | 0.631 [0.611, 0.973]† | 0.106 | 0.046 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.92/0.96/0.94 (71936); gate P 0.98 n 63759 → strong | 1.00/1.00/1.00 (74); gate P 1.00 n 71 → strong | 1.00/0.84/0.91 (19); gate P 1.00 n 16 → weak | 1.00/0.97/0.99 (37); gate P 1.00 n 21 → weak | 0.87/0.88/0.87 (187); gate P 0.96 n 149 → strong | 1.00/0.99/1.00 (937); gate P 1.00 n 842 → strong |
| walking | 0.78/0.57/0.66 (8381); gate P 0.98 n 2557 → strong | 0.94/0.97/0.96 (35); gate P 1.00 n 26 → weak | 0.67/1.00/0.80 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 0.94/0.72/0.82 (43); gate P 1.00 n 16 → weak | 0.92/0.93/0.92 (70); gate P 1.00 n 55 → strong |
| running | 0.78/0.72/0.75 (103); gate P 0.86 n 69 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.95/0.97 (80); gate P 1.00 n 64 → strong |
| stairs | 0.01/0.25/0.02 (8); gate P 0.03 n 30 → abstain | 0.97/1.00/0.98 (32); gate P 1.00 n 31 → strong | 1.00/0.33/0.50 (3); gate P 1.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.59/1.00/0.74 (29); gate P 0.81 n 32 → weak | 0.94/0.85/0.89 (80); gate P 1.00 n 60 → strong |
| cycling | 0.69/0.65/0.67 (743); gate P 0.69 n 697 → abstain | 1.00/0.94/0.97 (33); gate P 1.00 n 31 → strong | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.93/0.96 (28); gate P 1.00 n 26 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak |
| vehicle_motion | 0.66/0.48/0.56 (3484); gate P 0.82 n 1594 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.75/0.26/0.39 (34); gate P 1.00 n 5 → weak | 0.00/0.00/0.00 (0) |
| other | 0.40/0.36/0.37 (5174) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.72/0.85/0.78 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.666 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.931, P 0.907; ≥0.6: cov 0.878, P 0.933; ≥0.7: cov 0.832, P 0.952; ≥0.8: cov 0.781, P 0.968; ≥0.9: cov 0.687, P 0.981; ≥0.95: cov 0.568, P 0.988

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70395     767       0       6      18      61     648    1295
   1980    4898       0       3     105      98      96    1353
      0       0       0       0       0       0       0       0
      4      27       0     170       0       0       0       2
      3       9       0       0     132       0       0       8
    204      25       0       0       0     545       2      32
   1573      81       0       0       2       3    1698     161
   2657     448       0      12      60      53     117    1902
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.651 | 0.456 [0.414, 0.565] | 0.457 [0.414, 0.513] | 0.457 [0.414, 0.513] | 0.947→0.718 | 0.577→0.466 | 0.092→0.059 (0.010) | 0.176→0.048 | 0.299 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.477 | 0.181 | 0.262 | 0.477 (6,845) | 0.064 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.681 | 0.904 | 0.777 | 0.681 (13,545) | 0.063 | weak | 0.640 | P=0.712 n=14,109 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.408 | 0.282 | 0.333 | 0.408 (582) | 0.016 | abstain | 1.000 | – | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.395 | 0.387 [0.334, 0.429] | 0.717 | 0.060 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.267 | 0.707 | descriptive |
| pamap2 | 2 | 60 | 0.239 | 0.236 [0.140, 0.313]† | 1.318 | 0.419 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.850 | 0.584 [0.478, 0.653]† | 0.591 | 0.101 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.48/0.18/0.26 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.68/0.90/0.78 (13385); gate P 0.71 n 13899 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 9 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 28 → weak | 0.86/1.00/0.93 (160); gate P 0.92 n 173 → weak |
| repetitive_hand_motion | 0.14/0.10/0.12 (393) | 0.00/0.00/0.00 (0) | 1.00/0.41/0.59 (29) | 1.00/0.70/0.82 (160) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.457 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.943, P 0.664; ≥0.6: cov 0.770, P 0.694; ≥0.7: cov 0.581, P 0.716; ≥0.8: cov 0.284, P 0.721; ≥0.9: cov 0.033, P 0.660; ≥0.95: cov 0.006, P 0.625

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
   1236    5470       0     139       0       0       0
   1197   12249       0      99       0       0       0
      0       0       0       0       0       0       0
    158     260       0     164       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.930 | 0.064 | 0.091→0.089 | 0.201→0.190 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.901 | 0.056 | 0.098→0.098 | 0.204→0.195 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.928 | 0.095 | 0.091→0.089 | 0.203→0.186 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.905 | 0.078 | 0.101→0.099 | 0.220→0.200 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.14/0.56/0.22 | 0.15/0.61/0.24 | 2.7 / 4.6 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.50/0.33/0.40 | 0.57/0.38/0.45 | 2.4 / 5.6 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.36/0.40 | 0.53/0.45/0.49 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.136.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.102 | 0.136 | 0.511 | 0.790 | 0.773 |
| capture24 | 95,579 | 0.102 | 0.136 | 0.508 | 0.790 | 0.773 |
| pamap2 | 234 | 0.110 | 0.203 | 0.605 | 0.837 | 0.705 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
