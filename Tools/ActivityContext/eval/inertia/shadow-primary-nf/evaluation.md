# Evaluation — `shadow-primary-nf` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `8fb6cfeab131d1f2a53c28eb0ae67544927f3828c337bc0305d8cbde7a1fb09e`; sealed bundle_sha256 `efe44c375da389cc07169dfe5ec5188cca3cc58906105c287cecd7a5dcfa9ae6` (test_gate.json `f502e95b33b0ab37`; the served artifact carries the gate); encoder `standin:nara-imu-feat-1-accel` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 4 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 62, hhar_watch 62, mhealth 62, opportunity 62, pamap2 62, wisdm2019_watch 62

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.827 | 0.596 [0.582, 0.609] | 0.598 [0.583, 0.611] | 0.598 [0.583, 0.611] | 0.784→0.484 | 0.456→0.262 | 0.206→0.027 (0.005) | 0.219→0.039 | 0.103 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,463 | 0.847 | 0.941 | 0.892 | 0.833 (35,939) | 0.058 | strong | 0.885 | P=0.966 n=19,233 → strong | – | strong | 0 |
| seated_likely | yes | 30,792 | 0.811 | 0.785 | 0.798 | 0.773 (25,686) | 0.051 | weak | 0.300 | P=0.773 n=24,774 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.330 | 0.062 | 0.105 | 0.368 (4,220) | 0.007 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.946 / 0.993 (73,741) | strong | 0.815 | P=0.962 n=69,328 → strong | hhar_watch test: precision 0.500 at n_acc 74 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 8,630 | strong→strong (0.880) | strong→strong (0.885) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.598 | 0.600 [0.585, 0.611] | 0.477 | 0.028 |  |
| hhar_watch | 2 | 74 | 0.027 | 0.032 [0.029, 0.035]† | 2.994 | 0.785 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.133 [0.133, 0.133]† | 2.310 | 0.584 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.401 | 0.128 | descriptive |
| pamap2 | 2 | 204 | 0.556 | 0.489 [0.311, 0.542]† | 0.912 | 0.204 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.275 | 0.170 [0.115, 0.201]† | 1.752 | 0.480 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.85/0.94/0.89 (39388); gate P 0.97 n 19196 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 24 → weak | 0.25/1.00/0.40 (4) | 0.00/0.00/0.00 (0) | 0.78/0.80/0.79 (71); gate P 0.83 n 6 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 7 → weak |
| seated_likely | 0.81/0.79/0.80 (30561); gate P 0.78 n 24525 → abstain | 0.40/0.05/0.10 (37); gate P 0.40 n 5 → weak | 0.00/0.00/0.00 (6) | 0.81/1.00/0.90 (30); gate P 0.81 n 37 → weak | 0.52/0.85/0.64 (78); gate P 0.46 n 114 → abstain | 0.47/0.55/0.51 (80); gate P 0.47 n 93 → abstain |
| upright_stationary | 0.33/0.06/0.11 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.33/0.02/0.03 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.345, R 0.996, F1 0.512 (support 3,559, predicted 10,275)
- awake-lying gate at the frozen tau: pooled P=0.008 n=666 → abstain; per dataset capture24 P=0.000 n=629 → abstain, hhar_watch P=0.000 n=24 → weak, pamap2 P=0.833 n=6 → weak, wisdm2019_watch P=0.000 n=7 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.598 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.990, P 0.830; ≥0.6: cov 0.922, P 0.850; ≥0.7: cov 0.768, P 0.875; ≥0.8: cov 0.638, P 0.895; ≥0.9: cov 0.350, P 0.931; ≥0.95: cov 0.021, P 0.840

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  37152    2165     146       0
   6234   24172     386       0
    497    3461     262       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.837 | 0.422 [0.397, 0.447] | 0.417 [0.380, 0.439] | 0.417 [0.380, 0.439] | 0.820→0.475 | 0.410→0.229 | 0.055→0.015 (0.004) | 0.085→0.011 | 0.037 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,230 | 0.865 | 0.976 | 0.917 | 0.864 (72,964) | 0.013 | strong | 0.855 | P=0.973 n=56,487 → strong | – | strong | 0 |
| walking | yes | 8,493 | 0.722 | 0.475 | 0.573 | 0.714 (8,306) | 0.022 | weak | 0.605 | P=0.881 n=3,173 → weak | hhar_watch test: precision 0.583 at n_acc 60 -> abstain | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.689 | 0.951 | 0.799 | 0.710 (203) | 0.001 | weak | 0.590 | P=0.805 n=220 → weak | capture24 test: precision 0.674 at n_acc 132 -> abstain | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 808 | 0.494 | 0.431 | 0.460 | 0.494 (808) | 0.006 | weak | 0.485 | P=0.584 n=483 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.312 | 0.001 | 0.003 | 0.312 (3,518) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.269 | 0.123 | 0.168 | 0.272 (5,249) | 0.013 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| stationary+walking | 453 | 0.898 / 0.994 (90,472) | strong | 0.865 | P=0.975 n=60,089 → strong | – | strong |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| walking | 453 | weak→abstain (0.600) | weak→abstain (0.605) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.415 | 0.396 [0.286, 0.436] | 0.473 | 0.016 |  |
| hhar_watch | 2 | 174 | 0.644 | 0.470 [0.344, 0.663]† | 0.651 | 0.162 | descriptive |
| mhealth | 2 | 49 | 0.714 | 0.658 [0.640, 0.861]† | 0.504 | 0.091 | descriptive |
| opportunity | 1 | 37 | 0.946 | 0.486 [0.486, 0.486]† | 0.402 | 0.236 | descriptive |
| pamap2 | 2 | 397 | 0.573 | 0.531 [0.499, 0.675]† | 0.853 | 0.102 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.678 | 0.411 [0.383, 0.433]† | 0.467 | 0.088 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.86/0.98/0.92 (71976); gate P 0.97 n 55763 → strong | 0.84/1.00/0.91 (74); gate P 1.00 n 73 → strong | 0.84/0.84/0.84 (19); gate P 1.00 n 16 → weak | 1.00/0.95/0.97 (37); gate P 1.00 n 12 → weak | 0.79/0.90/0.84 (187); gate P 0.98 n 116 → strong | 1.00/0.89/0.94 (937); gate P 1.00 n 507 → strong |
| walking | 0.74/0.47/0.57 (8341); gate P 0.90 n 3014 → weak | 0.55/1.00/0.71 (35); gate P 0.58 n 60 → abstain | 0.40/1.00/0.57 (4); gate P 0.57 n 7 → weak | 0.00/0.00/0.00 (0) | 0.38/0.91/0.53 (43); gate P 0.26 n 31 → abstain | 0.40/0.86/0.54 (70); gate P 0.39 n 61 → abstain |
| running | 0.53/0.93/0.67 (103); gate P 0.67 n 132 → abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.91/1.00/0.95 (10); gate P 1.00 n 10 → weak | 1.00/0.96/0.98 (80); gate P 1.00 n 68 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) |
| cycling | 0.49/0.41/0.45 (743); gate P 0.58 n 414 → abstain | 1.00/0.58/0.73 (33); gate P 1.00 n 17 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 1.00/0.71/0.83 (28); gate P 1.00 n 19 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 28 → weak |
| vehicle_motion | 0.31/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) |
| other | 0.27/0.12/0.16 (5174) | 0.00/0.00/0.00 (0) | 0.67/0.44/0.53 (9) | 0.00/0.00/0.00 (0) | 0.65/0.48/0.56 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.417 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.883, P 0.896; ≥0.6: cov 0.817, P 0.926; ≥0.7: cov 0.757, P 0.946; ≥0.8: cov 0.679, P 0.964; ≥0.9: cov 0.567, P 0.980; ≥0.95: cov 0.440, P 0.987

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71471     916       0      24       1     219       4     595
   3277    4035       0      39       0      76       5    1061
      0       0       0       0       0       0       0       0
      2       7       0     193       0       0       0       1
      4     139       0       0       0       0       0       9
    396      31       0       0       0     348       0      33
   3353      76       0       2       0      30       5      52
   4165     384       0      22       0      32       2     644
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.395 [0.362, 0.493] | 0.353 [0.307, 0.422] | 0.353 [0.307, 0.422] | 1.049→0.738 | 0.632→0.478 | 0.135→0.068 (0.008) | 0.200→0.050 | 0.339 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.491 | 0.023 | 0.044 | 0.491 (6,845) | 0.071 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.654 | 0.981 | 0.785 | 0.654 (13,545) | 0.063 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.319 | 0.180 | 0.231 | 0.319 (582) | 0.015 | weak | 0.910 | P=0.415 n=82 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.341 | 0.285 [0.262, 0.304] | 0.735 | 0.067 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.541 | 0.780 | descriptive |
| pamap2 | 2 | 60 | 0.032 | 0.040 [0.000, 0.070]† | 1.992 | 0.691 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.803 | 0.795 [0.609, 0.937]† | 0.693 | 0.148 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.49/0.02/0.04 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.98/0.79 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.72/1.00/0.84 (160) |
| repetitive_hand_motion | 0.03/0.02/0.03 (393); gate P 0.00 n 48 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 1.00/0.61/0.75 (160); gate P 1.00 n 34 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.353 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.981, P 0.650; ≥0.6: cov 0.914, P 0.662; ≥0.7: cov 0.648, P 0.684; ≥0.8: cov 0.007, P 0.400; ≥0.9: cov 0.004, P 0.435; ≥0.95: cov 0.003, P 0.429

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    156    6560       0     129       0       0       0
    157   13293       0      95       0       0       0
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
| stand_to_sit_like | 0.95 (weak) | 36 | 0.04/0.06/0.05 | 0.14/0.19/0.16 | 8.2 / 8.8 |
| walk_start | 0.30 (weak) | 405 | 0.31/0.41/0.35 | 0.37/0.50/0.42 | 2.0 / 6.3 |
| walk_stop | 0.35 (weak) | 404 | 0.32/0.40/0.35 | 0.39/0.49/0.44 | 2.5 / 6.5 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.173.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.123 | 0.136 | 0.285 | 0.776 | 0.780 |
| capture24 | 95,579 | 0.123 | 0.136 | 0.280 | 0.776 | 0.780 |
| pamap2 | 234 | 0.135 | 0.203 | 0.500 | 0.798 | 0.654 |

## OOD

Bundle method `knn` (k=20), threshold 0.322 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.

## Per-window test predictions (outside git)

npz per dataset: uid/subject/session/label (str), t0/t1 (float s, dataset clock: Capture-24 unix s, WISDM device ns/1e9), purity; probs_<head> [N,K] over the fixed class order (NaN = unsupported), raw_logits_<head> (-inf unsupported), movement_intensity, ood_score, is_ood, valid, class_orders_json, bundle_sha256. Join HART windows on (subject, session, t0..t1).

- wisdm2019_watch: `research/inertia-bundles/shadow-primary-nf/test_predictions/wisdm2019_watch.npz` (1,397 windows)
- capture24: `research/inertia-bundles/shadow-primary-nf/test_predictions/capture24.npz` (95,579 windows)

Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
