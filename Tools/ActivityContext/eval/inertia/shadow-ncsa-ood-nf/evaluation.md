# Evaluation — `shadow-ncsa-ood-nf` (ood_bench)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `fa626b136de0b7b275de7d233cebe7835399eec7e695eea51979b039ba11c953`; sealed bundle_sha256 `07603e091a9d1b1a8d284981ef80da4bf0b3d3d442fb85fabf45e20a5f9ef3fa` (test_gate.json `db700a4e67199490`; the served artifact carries the gate); encoder `standin:nara-imu-feat-1-accel` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `c805f429821bb80c15da4ee6b2066c593321a40b3df8a0d7d26b01a838c5d7b1`; evaluations of this experiment on this test split: 2 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), gotov 587 (7 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wear 319 (5 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 76, gotov 11, hhar_watch 76, mhealth 76, opportunity 76, pamap2 76, wear 11, wisdm2019_watch 76

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,861 | 0.810 | 0.581 [0.566, 0.596] | 0.582 [0.567, 0.597] | 0.582 [0.567, 0.597] | 0.852→0.567 | 0.492→0.297 | 0.193→0.089 (0.005) | 0.237→0.077 | 0.156 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,965 | 0.824 | 0.938 | 0.877 | 0.808 (36,065) | 0.113 | strong | 0.790 | P=0.962 n=13,732 → strong | gotov test: precision 0.516 at n_acc 31 -> abstain | abstain | 0 |
| seated_likely | yes | 30,598 | 0.793 | 0.749 | 0.770 | 0.754 (25,868) | 0.106 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.455 | 0.056 | 0.099 | 0.514 (4,298) | 0.011 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.945 / 0.996 (74,339) | strong | 0.810 | P=0.962 n=70,485 → strong | gotov test: precision 0.939 at n_acc 326 -> weak; hhar_watch test: precision 0.500 at n_acc 74 -> abstain | abstain |

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.581 | 0.583 [0.568, 0.597] | 0.558 | 0.093 |  |
| gotov | 7 | 386 | 0.475 | 0.454 [0.341, 0.543]† | 0.993 | 0.245 |  |
| hhar_watch | 2 | 74 | 0.000 | 0.000 [0.000, 0.000]† | 2.679 | 0.735 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.133 [0.133, 0.133]† | 2.112 | 0.526 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.554 | 0.112 | descriptive |
| pamap2 | 2 | 204 | 0.555 | 0.479 [0.300, 0.540]† | 0.906 | 0.148 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.219 | 0.150 [0.093, 0.186]† | 1.929 | 0.447 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.83/0.94/0.88 (39761); gate P 0.96 n 13667 → strong | 0.44/0.87/0.58 (126); gate P 0.52 n 31 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 18 → weak | 0.25/1.00/0.40 (4); gate P 0.80 n 5 → weak | 0.00/0.00/0.00 (0) | 0.78/0.86/0.82 (74); gate P 1.00 n 5 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 6 → weak |
| seated_likely | 0.80/0.75/0.77 (30188) | 0.41/0.25/0.31 (182) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.81/1.00/0.90 (30) | 0.50/0.80/0.62 (75) | 0.46/0.44/0.45 (80) |
| upright_stationary | 0.43/0.05/0.09 (4036) | 1.00/0.31/0.47 (78) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.335, R 0.993, F1 0.502 (support 4,061, predicted 12,025)
- awake-lying gate at the frozen tau: pooled P=0.046 n=549 → abstain; per dataset capture24 P=0.000 n=484 → abstain, gotov P=0.516 n=31 → abstain, hhar_watch P=0.000 n=18 → weak, mhealth P=0.800 n=5 → weak, pamap2 P=1.000 n=5 → weak, wisdm2019_watch P=0.000 n=6 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.582 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.982, P 0.813; ≥0.6: cov 0.888, P 0.834; ≥0.7: cov 0.727, P 0.862; ≥0.8: cov 0.312, P 0.871; ≥0.9: cov 0.060, P 0.772; ≥0.95: cov 0.020, P 0.731

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  37469    2490       6       0
   7406   22912     280       0
    585    3474     239       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.833 | 0.413 [0.399, 0.429] | 0.416 [0.394, 0.432] | 0.416 [0.394, 0.432] | 1.014→0.514 | 0.487→0.233 | 0.290→0.047 (0.004) | 0.108→0.018 | 0.039 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,738 | 0.870 | 0.975 | 0.920 | 0.904 (73,462) | 0.055 | strong | 0.885 | P=0.973 n=58,515 → strong | wear test: precision 0.564 at n_acc 39 -> abstain | abstain | 0 |
| walking | yes | 3,226 | 0.870 | 0.857 | 0.864 | 0.074 (33) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | yes | 5,309 | 0.444 | 0.128 | 0.199 | 0.000 (19) | 0.021 | abstain | 1.000 | – | – | abstain | 0 |
| running | yes | 296 | 0.745 | 0.939 | 0.831 | 0.830 (296) | 0.003 | weak | 0.360 | P=0.763 n=363 → abstain | – | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.004 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 855 | 0.507 | 0.167 | 0.252 | 0.544 (855) | 0.012 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.667 | 0.001 | 0.001 | 1.000 (3,518) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,463 | 0.287 | 0.236 | 0.259 | 0.487 (5,463) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| walking+brisk_walking | 8,306 | 0.670 / 0.443 (5,529) | weak | 0.605 | P=0.861 n=3,025 → weak | hhar_watch test: precision 0.625 at n_acc 56 -> abstain | abstain |
| stationary+walking+brisk_walking | 453 | 0.898 / 0.981 (89,909) | strong | 0.900 | P=0.974 n=60,696 → strong | wear test: precision 0.650 at n_acc 40 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| walking | 8,759 | weak→abstain (0.445) | abstain→abstain (1.000) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.410 | 0.405 [0.311, 0.443] | 0.502 | 0.048 |  |
| gotov | 7 | 585 | 0.486 | 0.442 [0.246, 0.500]† | 0.799 | 0.093 |  |
| hhar_watch | 2 | 174 | 0.500 | 0.263 [0.263, 0.365]† | 0.964 | 0.189 | descriptive |
| mhealth | 2 | 49 | 0.547 | 0.492 [0.492, 0.545]† | 0.802 | 0.192 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.296 | 0.246 | descriptive |
| pamap2 | 2 | 397 | 0.512 | 0.382 [0.316, 0.544]† | 1.152 | 0.124 | descriptive |
| wear | 5 | 319 | 0.754 | 0.456 [0.422, 0.492]† | 0.828 | 0.100 |  |
| wisdm2019_watch | 8 | 1,167 | 0.632 | 0.360 [0.294, 0.402]† | 0.895 | 0.113 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.87/0.98/0.92 (71986); gate P 0.97 n 57503 → strong | 0.78/0.91/0.84 (386); gate P 0.99 n 294 → strong | 0.69/1.00/0.82 (74); gate P 1.00 n 74 → strong | 0.64/0.95/0.77 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 5 → weak | 0.75/0.89/0.82 (187); gate P 0.99 n 115 → strong | 0.64/0.88/0.74 (112); gate P 0.56 n 39 → abstain | 1.00/0.82/0.90 (937); gate P 1.00 n 469 → strong |
| walking | 0.91/0.85/0.88 (3126) | 0.54/1.00/0.70 (33) | 0.61/1.00/0.76 (35) | 0.57/1.00/0.73 (4) | 0.00/0.00/0.00 (0) | 0.34/1.00/0.51 (11) | 0.00/0.00/0.00 (0) | 0.21/1.00/0.35 (17) |
| brisk_walking | 0.46/0.12/0.20 (5205) | 0.00/0.00/0.00 (19) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.39/0.53/0.45 (32) | 0.00/0.00/0.00 (0) | 0.24/0.36/0.29 (53) |
| running | 0.59/0.92/0.72 (103); gate P 0.63 n 151 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.29/1.00/0.44 (10); gate P 0.29 n 35 → abstain | 0.96/0.91/0.93 (93); gate P 0.95 n 88 → strong | 0.99/0.97/0.98 (80); gate P 0.99 n 79 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (80) |
| cycling | 0.56/0.18/0.27 (743) | 0.60/0.06/0.12 (47) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 1.00/0.21/0.35 (28) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.67/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.28/0.22/0.25 (5174) | 0.69/0.46/0.55 (100) | 0.00/0.00/0.00 (0) | 0.75/0.33/0.46 (9) | 0.00/0.00/0.00 (0) | 0.52/0.45/0.48 (66) | 0.87/0.46/0.61 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.416 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.894, P 0.885; ≥0.6: cov 0.854, P 0.906; ≥0.7: cov 0.812, P 0.923; ≥0.8: cov 0.748, P 0.944; ≥0.9: cov 0.601, P 0.980; ≥0.95: cov 0.079, P 0.985

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71925     214     332      19       0      71       0    1177
    412    2765       0       6       0       0       0      43
   2771      19     680      32       0      19       1    1787
      5       4       3     278       0       0       0       6
      4      71      56       0       0       0       0      21
    590       7      54       2       0     143       0      59
   3356      13      30       0       0       3       2     114
   3631      85     377      36       0      46       0    1288
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.650 | 0.409 [0.377, 0.472] | 0.413 [0.373, 0.484] | 0.413 [0.373, 0.484] | 1.321→0.756 | 0.719→0.480 | 0.188→0.060 (0.010) | 0.212→0.040 | 0.341 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.485 | 0.076 | 0.131 | 0.485 (6,845) | 0.072 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.660 | 0.963 | 0.783 | 0.660 (13,608) | 0.065 | abstain | 1.000 | – | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.480 | 0.122 | 0.195 | 0.480 (582) | 0.015 | weak | 0.505 | P=0.500 n=76 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 0.638 | 0.474 | 0.544 | 0.638 (78) | 0.008 | weak | 0.300 | P=0.638 n=58 → abstain | – | abstain | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.346 | 0.229 [0.210, 0.247] | 0.746 | 0.062 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.249 | 0.217 |  |
| mhealth | 2 | 19 | 0.000 | 0.000 [0.000, 0.000]† | 2.190 | 0.689 | descriptive |
| pamap2 | 2 | 67 | 0.355 | 0.280 [0.044, 0.280]† | 1.968 | 0.567 | descriptive |
| wear | 5 | 64 | 0.469 | 0.160 [0.145, 0.347]† | 2.298 | 0.319 |  |
| wisdm2019_watch | 8 | 320 | 0.722 | 0.373 [0.299, 0.536]† | 0.849 | 0.142 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.50/0.08/0.13 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.96/0.78 (13385) | 1.00/1.00/1.00 (63) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.78/1.00/0.88 (160) |
| repetitive_hand_motion | 0.00/0.00/0.00 (393); gate P 0.00 n 38 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 1.00/0.44/0.61 (160); gate P 1.00 n 38 → strong |
| exercise_motion | 0.00/0.00/0.00 (0); gate P 0.00 n 14 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (7) | 1.00/1.00/1.00 (7); gate P 1.00 n 7 → weak | 1.00/0.47/0.64 (64); gate P 1.00 n 30 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 7 → weak |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.413 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.952, P 0.660; ≥0.6: cov 0.833, P 0.672; ≥0.7: cov 0.601, P 0.698; ≥0.8: cov 0.173, P 0.626; ≥0.9: cov 0.001, P 0.909; ≥0.95: cov 0.000, P 1.000

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    517    6263       0      54       0      11       0
    481   13102       0      22       0       3       0
      0       0       0       0       0       0       0
     66     438       0      71       0       7       0
      0       0       0       0       0       0       0
      1      39       0       1       0      37       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.909 | 0.035 | 0.082→0.079 | 0.196→0.166 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.880 | 0.033 | 0.092→0.085 | 0.225→0.177 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.897 | 0.040 | 0.112→0.105 | 0.263→0.225 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.872 | 0.040 | 0.126→0.108 | 0.301→0.231 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.15/0.64/0.25 | 0.16/0.67/0.26 | 2.1 / 3.7 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.04/0.06/0.05 | 0.15/0.22/0.18 | 8.4 / 9.0 |
| walk_start | 0.30 (weak) | 405 | 0.31/0.41/0.35 | 0.37/0.49/0.42 | 2.0 / 6.4 |
| walk_stop | 0.35 (weak) | 404 | 0.33/0.40/0.36 | 0.40/0.49/0.44 | 2.7 / 6.4 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.168.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.121 | 0.137 | 0.296 | 0.745 | 0.780 |
| capture24 | 95,579 | 0.121 | 0.136 | 0.289 | 0.744 | 0.780 |
| gotov | 333 | 0.147 | 0.206 | 0.375 | 0.719 | 0.712 |
| pamap2 | 234 | 0.129 | 0.203 | 0.575 | 0.818 | 0.654 |

## OOD

Bundle method `knn` (k=20), threshold 0.324 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.046 on 96,541 windows.

**heldout_activities_test**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 2,048 | 0.762 | 0.080 (0.021) | 0.992 | 0.749 | 0.050 | 0.248 |
| knn@10 | 96,541 | 2,048 | 0.805 | 0.083 (0.021) | 0.461 | 0.809 | 0.045 | 0.182 |
| knn@20 | 96,541 | 2,048 | 0.805 | 0.076 (0.021) | 0.451 | 0.817 | 0.046 | 0.174 |
| knn@5 | 96,541 | 2,048 | 0.803 | 0.085 (0.021) | 0.460 | 0.801 | 0.046 | 0.188 |
| maha_global | 96,541 | 2,048 | 0.770 | 0.145 (0.021) | 0.584 | 0.712 | 0.050 | 0.288 |
| maha_min | 96,541 | 2,048 | 0.734 | 0.109 (0.021) | 0.661 | 0.772 | 0.046 | 0.226 |
| maha_rel | 96,541 | 2,048 | 0.245 | 0.013 (0.021) | 0.999 | 0.976 | 0.050 | 0.024 |

Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage 1.000, risk 0.218, AURC 0.059; with OOD rejection max coverage 0.951, risk 0.207, AURC 0.052.

**daphnet_fog_nonwrist**

| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|---|
| energy | 96,541 | 850 | 0.591 | 0.011 (0.009) | 0.867 | 0.994 | 0.050 | 0.006 |
| knn@10 | 96,541 | 850 | 0.666 | 0.017 (0.009) | 0.744 | 0.925 | 0.045 | 0.066 |
| knn@20 | 96,541 | 850 | 0.661 | 0.016 (0.009) | 0.765 | 0.949 | 0.046 | 0.045 |
| knn@5 | 96,541 | 850 | 0.671 | 0.017 (0.009) | 0.724 | 0.901 | 0.046 | 0.086 |
| maha_global | 96,541 | 850 | 0.556 | 0.012 (0.009) | 0.925 | 0.965 | 0.050 | 0.035 |
| maha_min | 96,541 | 850 | 0.557 | 0.014 (0.009) | 0.957 | 0.966 | 0.046 | 0.034 |
| maha_rel | 96,541 | 850 | 0.520 | 0.011 (0.009) | 0.953 | 0.880 | 0.050 | 0.120 |

OOD method selection (VAL only): chosen `knn@20` from ncsa-ood-nf; VAL AUROC energy 0.743, knn@10 0.839, knn@20 0.843, knn@5 0.834, maha_global 0.806, maha_min 0.783


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
