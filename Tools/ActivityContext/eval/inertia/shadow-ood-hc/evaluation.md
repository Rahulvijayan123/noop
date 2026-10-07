# Evaluation — `shadow-ood-hc` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `f109c1627eb27949253e638f47fcd38d462b96ddd6c1364be62ada8e151c1050`; sealed bundle_sha256 `6fa95fa6c79330333bac013ce268af8c8e4ead9faca161d7d987c20885cd7fa7` (test_gate.json `f9460bfa58e749a6`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 4 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 58, hhar_watch 58, mhealth 58, opportunity 58, pamap2 58, wisdm2019_watch 58

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.847 | 0.617 [0.605, 0.627] | 0.619 [0.605, 0.629] | 0.619 [0.605, 0.629] | 0.599→0.413 | 0.346→0.231 | 0.043→0.014 (0.004) | 0.131→0.031 | 0.070 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,718 | 0.894 | 0.929 | 0.911 | 0.886 (35,939) | 0.036 | strong | 0.955 | P=0.988 n=8,074 → strong | – | strong | 0 |
| seated_likely | yes | 31,537 | 0.808 | 0.851 | 0.829 | 0.768 (25,686) | 0.042 | weak | 0.475 | P=0.769 n=27,232 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.291 | 0.073 | 0.116 | 0.319 (4,220) | 0.015 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.946 / 0.991 (73,608) | strong | 0.780 | P=0.960 n=69,465 → strong | hhar_watch test: precision 0.500 at n_acc 74 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| seated_likely | 8,630 | weak→abstain (0.300) | weak→abstain (0.475) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.617 | 0.619 [0.607, 0.631] | 0.409 | 0.015 |  |
| hhar_watch | 2 | 74 | 0.311 | 0.202 [0.196, 0.206]† | 1.844 | 0.312 | descriptive |
| mhealth | 2 | 16 | 0.556 | 0.433 [0.317, 0.556]† | 1.384 | 0.196 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.454 | 0.124 | descriptive |
| pamap2 | 2 | 204 | 0.601 | 0.562 [0.432, 0.571]† | 0.735 | 0.120 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.457 | 0.282 [0.182, 0.366]† | 0.950 | 0.238 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.90/0.93/0.91 (38638); gate P 0.99 n 8074 → strong | 0.00/0.00/0.00 (0) | 0.67/1.00/0.80 (4) | 0.00/0.00/0.00 (0) | 0.90/0.82/0.86 (76) | 0.00/0.00/0.00 (0) |
| seated_likely | 0.81/0.85/0.83 (31311); gate P 0.77 n 26910 → abstain | 0.59/0.62/0.61 (37); gate P 0.61 n 38 → abstain | 0.40/0.67/0.50 (6); gate P 0.40 n 10 → weak | 0.81/1.00/0.90 (30); gate P 0.81 n 37 → weak | 0.50/0.88/0.64 (73); gate P 0.47 n 118 → abstain | 0.49/0.78/0.60 (80); gate P 0.51 n 119 → abstain |
| upright_stationary | 0.28/0.07/0.11 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.75/0.11/0.19 (55) | 1.00/0.14/0.24 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.396, R 0.993, F1 0.566 (support 2,814, predicted 7,062)
- awake-lying gate at the frozen tau: pooled P=0.000 n=94 → abstain; per dataset capture24 P=0.000 n=94 → abstain; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.619 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.851; ≥0.6: cov 0.920, P 0.869; ≥0.7: cov 0.831, P 0.890; ≥0.8: cov 0.688, P 0.913; ≥0.9: cov 0.412, P 0.945; ≥0.95: cov 0.171, P 0.968

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35956    2723      39       0
   4000   26832     705       0
    268    3646     306       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.863 | 0.587 [0.535, 0.633] | 0.650 [0.610, 0.681] | 0.650 [0.610, 0.681] | 0.709→0.409 | 0.333→0.191 | 0.127→0.034 (0.004) | 0.080→0.015 | 0.030 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,214 | 0.895 | 0.977 | 0.934 | 0.895 (72,964) | 0.039 | strong | 0.855 | P=0.978 n=60,920 → strong | – | strong | 0 |
| walking | yes | 8,509 | 0.802 | 0.524 | 0.634 | 0.796 (8,306) | 0.014 | weak | 0.485 | P=0.870 n=4,417 → weak | pamap2 test: precision 0.750 at n_acc 56 -> abstain | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.968 | 0.749 | 0.844 | 0.968 (203) | 0.003 | strong | 0.300 | P=0.968 n=157 → strong | capture24 test: precision 0.923 at n_acc 65 -> weak | weak | 0 |
| stairs | yes | 152 | 0.822 | 0.730 | 0.774 | 0.822 (152) | 0.004 | weak | 0.635 | P=0.977 n=86 → strong | – | weak | 0 |
| cycling | yes | 808 | 0.721 | 0.573 | 0.639 | 0.721 (808) | 0.003 | weak | 0.300 | P=0.723 n=640 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.749 | 0.300 | 0.428 | 0.754 (3,518) | 0.026 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.352 | 0.258 | 0.297 | 0.356 (5,249) | 0.016 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| stationary+walking | 453 | 0.916 / 0.980 (87,393) | strong | 0.855 | P=0.981 n=67,365 → strong | – | strong |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| stationary | 453 | strong→strong (0.850) | strong→strong (0.855) |
| walking | 453 | weak→abstain (0.475) | weak→abstain (0.485) |

merge_into under the old rule (symmetric table): {'walking': 'stairs'}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.473 | 0.526 [0.419, 0.564] | 0.411 | 0.034 |  |
| hhar_watch | 2 | 174 | 0.909 | 0.923 [0.900, 0.944]† | 0.282 | 0.117 | descriptive |
| mhealth | 2 | 49 | 0.779 | 0.762 [0.724, 0.884]† | 0.423 | 0.108 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.286 | 0.235 | descriptive |
| pamap2 | 2 | 397 | 0.780 | 0.781 [0.781, 0.880]† | 0.588 | 0.045 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.883 | 0.595 [0.550, 0.761]† | 0.262 | 0.078 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.89/0.98/0.93 (71960); gate P 0.98 n 59997 → strong | 0.88/1.00/0.94 (74); gate P 1.00 n 74 → strong | 0.85/0.89/0.87 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 11 → weak | 0.84/0.91/0.87 (187); gate P 0.98 n 132 → strong | 1.00/0.96/0.98 (937); gate P 1.00 n 690 → strong |
| walking | 0.80/0.52/0.63 (8357); gate P 0.87 n 4228 → weak | 0.95/1.00/0.97 (35); gate P 1.00 n 35 → strong | 0.50/1.00/0.67 (4); gate P 0.50 n 8 → weak | 0.00/0.00/0.00 (0) | 0.70/0.98/0.82 (43); gate P 0.75 n 56 → abstain | 0.71/0.99/0.83 (70); gate P 0.77 n 90 → abstain |
| running | 0.92/0.58/0.71 (103); gate P 0.92 n 65 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 1.00/0.90/0.95 (80); gate P 1.00 n 72 → strong |
| stairs | 0.04/0.12/0.06 (8); gate P 0.00 n 2 → weak | 1.00/0.97/0.98 (32); gate P 1.00 n 19 → weak | 1.00/0.33/0.50 (3) | 0.00/0.00/0.00 (0) | 0.96/0.79/0.87 (29); gate P 1.00 n 19 → weak | 1.00/0.69/0.81 (80); gate P 1.00 n 46 → strong |
| cycling | 0.71/0.56/0.62 (743); gate P 0.71 n 581 → abstain | 1.00/0.67/0.80 (33); gate P 1.00 n 22 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/0.86/0.92 (28); gate P 1.00 n 24 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 9 → weak |
| vehicle_motion | 0.75/0.30/0.43 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.12/0.21 (34) | 0.00/0.00/0.00 (0) |
| other | 0.35/0.25/0.29 (5174) | 0.00/0.00/0.00 (0) | 0.67/0.44/0.53 (9) | 0.00/0.00/0.00 (0) | 0.75/0.80/0.77 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.650 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.924, P 0.903; ≥0.6: cov 0.872, P 0.929; ≥0.7: cov 0.822, P 0.950; ≥0.8: cov 0.758, P 0.968; ≥0.9: cov 0.616, P 0.982; ≥0.95: cov 0.413, P 0.988

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71513     513       0       3       0      58     168     959
   2479    4460       0       2      19      64     117    1368
      0       0       0       0       0       0       0       0
      4      47       0     152       0       0       0       0
      3      27       0       0     111       0       0      11
    277      39       0       0       0     463       0      29
   2269      57       0       0       0      14    1054     124
   3363     418       0       0       5      43      68    1352
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.643 | 0.434 [0.392, 0.546] | 0.422 [0.374, 0.486] | 0.422 [0.374, 0.486] | 0.940→0.705 | 0.571→0.461 | 0.093→0.072 (0.010) | 0.172→0.054 | 0.265 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.413 | 0.093 | 0.152 | 0.413 (6,845) | 0.077 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.665 | 0.937 | 0.778 | 0.665 (13,545) | 0.069 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.438 | 0.271 | 0.335 | 0.438 (582) | 0.016 | weak | 0.930 | P=0.635 n=85 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.368 | 0.341 [0.299, 0.383] | 0.705 | 0.073 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.642 | 0.798 | descriptive |
| pamap2 | 2 | 60 | 0.224 | 0.206 [0.190, 0.222]† | 1.271 | 0.424 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.863 | 0.860 [0.709, 0.981]† | 0.550 | 0.140 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.41/0.09/0.15 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.67/0.94/0.78 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.78/1.00/0.88 (160) |
| repetitive_hand_motion | 0.12/0.07/0.09 (393); gate P 0.00 n 31 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.45/0.62 (29) | 1.00/0.72/0.84 (160); gate P 1.00 n 54 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.422 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.952, P 0.653; ≥0.6: cov 0.803, P 0.681; ≥0.7: cov 0.602, P 0.721; ≥0.8: cov 0.280, P 0.787; ≥0.9: cov 0.022, P 0.758; ≥0.95: cov 0.006, P 0.631

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    637    6093       0     115       0       0       0
    768   12689       0      88       0       0       0
      0       0       0       0       0       0       0
    139     285       0     158       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.925 | 0.063 | 0.104→0.100 | 0.237→0.216 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.893 | 0.053 | 0.101→0.099 | 0.228→0.201 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.922 | 0.091 | 0.105→0.102 | 0.236→0.217 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.900 | 0.075 | 0.107→0.105 | 0.241→0.213 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.12/0.53/0.19 | 0.14/0.64/0.23 | 2.9 / 5.8 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.51/0.35/0.41 | 0.58/0.40/0.47 | 2.4 / 5.9 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.36/0.39 | 0.53/0.44/0.48 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.129.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.099 | 0.136 | 0.529 | 0.805 | 0.768 |
| capture24 | 95,579 | 0.099 | 0.136 | 0.526 | 0.804 | 0.769 |
| pamap2 | 234 | 0.110 | 0.203 | 0.611 | 0.851 | 0.692 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.471 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.048 on 95,637 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 2,048 | 0.776 | 0.091 (0.021) | 0.823 | 0.716 | 0.055 | 0.305 |
| knn@10 | 95,637 | 2,048 | 0.556 | 0.022 (0.021) | 0.796 | 0.977 | 0.041 | 0.019 |
| knn@20 | 95,637 | 2,048 | 0.546 | 0.021 (0.021) | 0.810 | 0.980 | 0.040 | 0.015 |
| knn@5 | 95,637 | 2,048 | 0.560 | 0.022 (0.021) | 0.789 | 0.978 | 0.043 | 0.019 |
| maha_global | 95,637 | 2,048 | 0.802 | 0.163 (0.021) | 0.487 | 0.727 | 0.048 | 0.272 |
| maha_min | 95,637 | 2,048 | 0.801 | 0.167 (0.021) | 0.496 | 0.730 | 0.047 | 0.268 |
| maha_rel | 95,637 | 2,048 | 0.524 | 0.109 (0.021) | 0.965 | 0.735 | 0.046 | 0.257 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.190, AURC 0.049; with OOD rejection max coverage 0.947, risk 0.182, AURC 0.044.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 95,637 | 850 | 0.492 | 0.009 (0.009) | 0.962 | 0.980 | 0.055 | 0.021 |
| knn@10 | 95,637 | 850 | 0.693 | 0.017 (0.009) | 0.781 | 0.927 | 0.041 | 0.059 |
| knn@20 | 95,637 | 850 | 0.704 | 0.018 (0.009) | 0.794 | 0.919 | 0.040 | 0.061 |
| knn@5 | 95,637 | 850 | 0.674 | 0.016 (0.009) | 0.774 | 0.933 | 0.043 | 0.056 |
| maha_global | 95,637 | 850 | 0.515 | 0.040 (0.009) | 0.879 | 0.965 | 0.048 | 0.034 |
| maha_min | 95,637 | 850 | 0.519 | 0.040 (0.009) | 0.922 | 0.965 | 0.047 | 0.034 |
| maha_rel | 95,637 | 850 | 0.586 | 0.060 (0.009) | 0.928 | 0.732 | 0.046 | 0.261 |

OOD method selection (VAL only): chosen `maha_global` from ood-hc; VAL AUROC energy 0.788, knn@10 0.558, knn@20 0.555, knn@5 0.563, maha_global 0.823, maha_min 0.824


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
