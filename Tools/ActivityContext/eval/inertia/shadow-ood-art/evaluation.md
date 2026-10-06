# Evaluation — `shadow-ood-art` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `3784c9c5bdcc70853a321a5586e53cfb08e3d68b346df1714eefa309078abb89`; sealed bundle_sha256 `9ff173b2a3eac8be98a1c38861dd9a780bdba7d246f75179f6e7db7ed266512a` (test_gate.json `0ea561c7298a2d53`; the served artifact carries the gate); encoder `standin:inertia-arch-random-init/ar_transformer-small/seed0` (standin); evidence_tier_max `shadow`
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
| 74,475 | 0.635 | 0.445 [0.421, 0.472] | 0.432 [0.411, 0.454] | 0.432 [0.411, 0.454] | 1.074→0.742 | 0.677→0.464 | 0.177→0.072 (0.005) | 0.210→0.046 | 0.312 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,748 | 0.681 | 0.712 | 0.696 | 0.649 (35,939) | 0.068 | weak | 0.630 | P=0.743 n=13,156 → abstain | – | abstain | 0 |
| seated_likely | yes | 30,507 | 0.576 | 0.622 | 0.598 | 0.503 (25,686) | 0.060 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.000 | 0.000 | 0.000 | 0.000 (4,220) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.445 | 0.432 [0.411, 0.453] | 0.738 | 0.073 |  |
| hhar_watch | 2 | 74 | 0.243 | 0.156 [0.000, 0.333]† | 1.416 | 0.479 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.271 [0.000, 0.524]† | 1.038 | 0.331 | descriptive |
| opportunity | 1 | 37 | 0.250 | 0.217 [0.217, 0.217]† | 1.353 | 0.099 | descriptive |
| pamap2 | 2 | 204 | 0.505 | 0.394 [0.240, 0.424]† | 1.082 | 0.110 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.156 | 0.110 [0.038, 0.166]† | 1.576 | 0.395 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.68/0.71/0.70 (39711); gate P 0.74 n 13130 → abstain | 0.00/0.00/0.00 (0) | 0.18/0.50/0.27 (4) | 0.00/0.00/0.00 (0) | 0.41/0.82/0.55 (33); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 24 → weak |
| seated_likely | 0.58/0.62/0.60 (30238) | 0.45/0.49/0.47 (37) | 0.60/0.50/0.55 (6) | 0.94/0.50/0.65 (30) | 0.59/0.70/0.64 (116) | 0.35/0.31/0.33 (80) |
| upright_stationary | 0.00/0.00/0.00 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.225, R 0.998, F1 0.367 (support 3,844, predicted 17,058)
- awake-lying gate at the frozen tau: pooled P=0.213 n=4,299 → abstain; per dataset capture24 P=0.214 n=4,273 → abstain, pamap2 P=1.000 n=2 → weak, wisdm2019_watch P=0.000 n=24 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.432 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.808, P 0.648; ≥0.6: cov 0.293, P 0.714; ≥0.7: cov 0.116, P 0.729; ≥0.8: cov 0.051, P 0.815; ≥0.9: cov 0.001, P 0.736; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  28290   11458       0       0
  11518   18989       0       0
   1704    2516       0       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.811 | 0.272 [0.243, 0.296] | 0.266 [0.234, 0.286] | 0.266 [0.234, 0.286] | 1.578→0.655 | 0.846→0.302 | 0.260→0.035 (0.004) | 0.165→0.017 | 0.104 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,386 | 0.816 | 0.994 | 0.897 | 0.816 (72,964) | 0.036 | weak | 0.300 | P=0.817 n=89,366 → weak | hhar_watch test: precision 0.487 at n_acc 152 -> abstain | abstain | 0 |
| walking | yes | 8,337 | 0.828 | 0.123 | 0.214 | 0.824 (8,306) | 0.031 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.653 | 0.759 | 0.702 | 0.658 (203) | 0.003 | weak | 0.300 | P=0.658 n=234 → abstain | – | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 808 | 0.000 | 0.000 | 0.000 | 0.000 (808) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.000 (3,518) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.204 | 0.030 | 0.052 | 0.207 (5,249) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.261 | 0.252 [0.163, 0.292] | 0.651 | 0.034 |  |
| hhar_watch | 2 | 174 | 0.257 | 0.172 [0.158, 0.186]† | 1.587 | 0.302 | descriptive |
| mhealth | 2 | 49 | 0.333 | 0.276 [0.274, 0.333]† | 1.258 | 0.248 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.124 | 0.116 | descriptive |
| pamap2 | 2 | 397 | 0.310 | 0.224 [0.118, 0.233]† | 1.516 | 0.202 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.624 | 0.487 [0.434, 0.536]† | 0.502 | 0.127 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.82/0.99/0.90 (72132); gate P 0.82 n 87837 → weak | 0.49/1.00/0.65 (74); gate P 0.49 n 152 → abstain | 0.49/1.00/0.66 (19); gate P 0.49 n 39 → abstain | 1.00/1.00/1.00 (37); gate P 1.00 n 37 → strong | 0.59/0.97/0.73 (187); gate P 0.59 n 310 → abstain | 0.93/0.98/0.95 (937); gate P 0.93 n 991 → weak |
| walking | 0.87/0.12/0.21 (8185) | 0.05/0.03/0.04 (35) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (43) | 0.56/0.73/0.63 (70) |
| running | 0.55/0.69/0.61 (103); gate P 0.56 n 127 → abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.36/1.00/0.53 (10); gate P 0.36 n 28 → weak | 0.91/0.79/0.85 (80); gate P 0.91 n 69 → weak |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) |
| cycling | 0.00/0.00/0.00 (743) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (28) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) |
| other | 0.20/0.03/0.05 (5174) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.72/0.20/0.31 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.266 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.975, P 0.823; ≥0.6: cov 0.940, P 0.839; ≥0.7: cov 0.861, P 0.863; ≥0.8: cov 0.631, P 0.894; ≥0.9: cov 0.159, P 0.926; ≥0.95: cov 0.015, P 0.929

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  72973      64       0      10       0       0       0     339
   7028    1022       0      15       0       0      31     241
      0       0       0       0       0       0       0       0
      7      36       0     154       0       0       0       6
     96      44       0       0       0       0       5       7
    793      12       0       1       0       0       0       2
   3501       3       0       0       0       0       0      14
   4981      53       0      56       0       0       3     156
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.333 [0.333, 0.333] | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 1.153→0.727 | 0.716→0.462 | 0.183→0.086 (0.008) | 0.238→0.065 | 0.250 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.000 | 0.000 | 0.000 | 0.000 (6,845) | 0.086 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.646 | 1.000 | 0.785 | 0.646 (13,545) | 0.086 | weak | 0.710 | P=0.764 n=9,968 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.000 | 0.000 | 0.000 | 0.000 (582) | 0.023 | abstain | 1.000 | – | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.333 | 0.263 [0.241, 0.282] | 0.709 | 0.084 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.422 | 0.697 | descriptive |
| pamap2 | 2 | 60 | 0.000 | 0.000 [0.000, 0.000]† | 2.117 | 0.695 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.500 | 0.333 [0.333, 0.333]† | 1.556 | 0.310 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.00/0.00/0.00 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.65/1.00/0.79 (13385); gate P 0.77 n 9714 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 3 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 21 → weak | 0.50/1.00/0.67 (160); gate P 0.70 n 230 → abstain |
| repetitive_hand_motion | 0.00/0.00/0.00 (393) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (160) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.262 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.646; ≥0.6: cov 0.960, P 0.658; ≥0.7: cov 0.535, P 0.754; ≥0.8: cov 0.045, P 0.780; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0    6845       0       0       0       0       0
      0   13545       0       0       0       0       0
      0       0       0       0       0       0       0
      0     582       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.826 | 0.024 | 0.163→0.162 | 0.342→0.314 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.781 | 0.023 | 0.182→0.181 | 0.350→0.358 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.750 | 0.022 | 0.176→0.176 | 0.350→0.352 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.724 | 0.021 | 0.182→0.181 | 0.370→0.364 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.65 (weak) | 36 | 0.17/0.28/0.21 | 0.22/0.36/0.28 | 2.1 / 6.5 |
| stand_to_sit_like | 0.40 (weak) | 36 | 0.05/0.14/0.07 | 0.11/0.31/0.16 | 5.1 / 8.5 |
| walk_start | 0.60 (weak) | 405 | 0.37/0.22/0.28 | 0.39/0.23/0.29 | 2.0 / 3.8 |
| walk_stop | 0.55 (weak) | 404 | 0.36/0.24/0.29 | 0.43/0.29/0.35 | 2.5 / 6.6 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.217.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.141 | 0.136 | 0.064 | 0.417 | 0.816 |
| capture24 | 95,579 | 0.140 | 0.136 | 0.058 | 0.416 | 0.816 |
| pamap2 | 234 | 0.170 | 0.203 | 0.222 | 0.679 | 0.726 |

## OOD

Bundle method `maha_global` (k=None), threshold 36.306 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.066 on 95,637 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 2,048 | 0.456 | 0.018 (0.021) | 0.984 | 0.972 | 0.055 | 0.033 |
| knn@10 | 95,637 | 2,048 | 0.797 | 0.066 (0.021) | 0.579 | 0.772 | 0.048 | 0.225 |
| knn@20 | 95,637 | 2,048 | 0.793 | 0.066 (0.021) | 0.571 | 0.772 | 0.049 | 0.224 |
| knn@5 | 95,637 | 2,048 | 0.800 | 0.067 (0.021) | 0.537 | 0.763 | 0.047 | 0.227 |
| maha_global | 95,637 | 2,048 | 0.861 | 0.155 (0.021) | 0.373 | 0.665 | 0.066 | 0.374 |
| maha_min | 95,637 | 2,048 | 0.861 | 0.152 (0.021) | 0.377 | 0.664 | 0.066 | 0.374 |
| maha_rel | 95,637 | 2,048 | 0.694 | 0.084 (0.021) | 0.792 | 0.748 | 0.057 | 0.266 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.239, AURC 0.135; with OOD rejection max coverage 0.927, risk 0.205, AURC 0.123.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 850 | 0.769 | 0.019 (0.009) | 0.414 | 0.919 | 0.055 | 0.107 |
| knn@10 | 95,637 | 850 | 0.739 | 0.034 (0.009) | 0.746 | 0.968 | 0.048 | 0.032 |
| knn@20 | 95,637 | 850 | 0.799 | 0.044 (0.009) | 0.631 | 0.856 | 0.049 | 0.131 |
| knn@5 | 95,637 | 850 | 0.685 | 0.031 (0.009) | 0.841 | 0.969 | 0.047 | 0.031 |
| maha_global | 95,637 | 850 | 0.625 | 0.012 (0.009) | 0.584 | 0.960 | 0.066 | 0.040 |
| maha_min | 95,637 | 850 | 0.617 | 0.012 (0.009) | 0.621 | 0.960 | 0.066 | 0.040 |
| maha_rel | 95,637 | 850 | 0.402 | 0.010 (0.009) | 0.924 | 0.916 | 0.057 | 0.086 |

OOD method selection (VAL only): chosen `maha_global` from ood-art; VAL AUROC energy 0.431, knn@10 0.744, knn@20 0.733, knn@5 0.759, maha_global 0.843, maha_min 0.842


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
