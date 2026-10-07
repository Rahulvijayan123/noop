# Evaluation — `shadow-ncsa-primary-nf` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `e64cd4bbeaf7bfc243f0652fa4f89f1027843c97be3139c09c004d9aef89d233`; sealed bundle_sha256 `ab2f49d5cea90ca71f594816347c8f66d4ac91d0f4db8390cfd5db8a50f976d4` (test_gate.json `82cc2470b723f053`; the served artifact carries the gate); encoder `standin:nara-imu-feat-1-accel` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `c805f429821bb80c15da4ee6b2066c593321a40b3df8a0d7d26b01a838c5d7b1`; evaluations of this experiment on this test split: 2 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), gotov 587 (7 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wear 319 (5 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 79, gotov 14, hhar_watch 79, mhealth 79, opportunity 79, pamap2 79, wear 14, wisdm2019_watch 79

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,861 | 0.832 | 0.603 [0.589, 0.615] | 0.605 [0.590, 0.617] | 0.605 [0.590, 0.617] | 0.732→0.476 | 0.420→0.263 | 0.128→0.037 (0.005) | 0.188→0.037 | 0.088 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 39,224 | 0.861 | 0.933 | 0.895 | 0.850 (36,065) | 0.054 | strong | 0.895 | P=0.965 n=20,521 → strong | gotov test: precision 0.621 at n_acc 58 -> abstain | abstain | 0 |
| seated_likely | yes | 31,339 | 0.807 | 0.810 | 0.808 | 0.767 (25,868) | 0.046 | weak | 0.480 | P=0.768 n=25,985 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.316 | 0.067 | 0.111 | 0.354 (4,298) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.946 / 0.991 (73,980) | strong | 0.825 | P=0.961 n=69,540 → strong | gotov test: precision 0.933 at n_acc 329 -> weak; hhar_watch test: precision 0.500 at n_acc 74 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| seated_likely | 8,630 | weak→abstain (0.300) | weak→abstain (0.480) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.605 | 0.607 [0.592, 0.618] | 0.466 | 0.036 |  |
| gotov | 7 | 386 | 0.469 | 0.455 [0.318, 0.567]† | 1.050 | 0.292 |  |
| hhar_watch | 2 | 74 | 0.027 | 0.030 [0.027, 0.035]† | 3.067 | 0.791 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.133 [0.133, 0.133]† | 2.494 | 0.619 | descriptive |
| opportunity | 1 | 37 | 0.500 | 0.448 [0.448, 0.448]† | 0.436 | 0.127 | descriptive |
| pamap2 | 2 | 204 | 0.573 | 0.507 [0.374, 0.545]† | 0.847 | 0.204 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.287 | 0.173 [0.117, 0.205]† | 1.738 | 0.470 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.87/0.93/0.90 (39023); gate P 0.97 n 20418 → strong | 0.46/0.82/0.59 (126); gate P 0.62 n 58 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 29 → weak | 0.25/1.00/0.40 (4); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0) | 0.84/0.80/0.82 (71); gate P 0.83 n 6 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 9 → weak |
| seated_likely | 0.81/0.81/0.81 (30926); gate P 0.77 n 25592 → abstain | 0.44/0.35/0.39 (182); gate P 0.46 n 136 → abstain | 0.29/0.05/0.09 (37); gate P 0.29 n 7 → weak | 0.00/0.00/0.00 (6) | 0.81/1.00/0.90 (30); gate P 0.81 n 37 → weak | 0.53/0.90/0.67 (78); gate P 0.47 n 118 → abstain | 0.47/0.57/0.52 (80); gate P 0.47 n 95 → abstain |
| upright_stationary | 0.30/0.07/0.11 (4036) | 0.95/0.24/0.39 (78) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.25/0.02/0.03 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.357, R 0.989, F1 0.524 (support 3,320, predicted 9,201)
- awake-lying gate at the frozen tau: pooled P=0.054 n=761 → abstain; per dataset capture24 P=0.000 n=658 → abstain, gotov P=0.621 n=58 → abstain, hhar_watch P=0.000 n=29 → weak, mhealth P=0.000 n=1 → weak, pamap2 P=0.833 n=6 → weak, wisdm2019_watch P=0.000 n=9 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.605 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.988, P 0.835; ≥0.6: cov 0.889, P 0.855; ≥0.7: cov 0.760, P 0.871; ≥0.8: cov 0.633, P 0.895; ≥0.9: cov 0.361, P 0.941; ≥0.95: cov 0.015, P 0.943

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  36593    2464     167       0
   5508   25372     459       0
    411    3598     289       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.832 | 0.409 [0.396, 0.425] | 0.411 [0.390, 0.427] | 0.411 [0.390, 0.427] | 1.014→0.514 | 0.487→0.233 | 0.292→0.047 (0.004) | 0.108→0.018 | 0.038 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,738 | 0.870 | 0.975 | 0.920 | 0.904 (73,462) | 0.055 | strong | 0.885 | P=0.973 n=58,615 → strong | wear test: precision 0.575 at n_acc 40 -> abstain | abstain | 0 |
| walking | yes | 3,326 | 0.865 | 0.843 | 0.854 | 0.070 (33) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | yes | 5,209 | 0.436 | 0.105 | 0.169 | 0.000 (19) | 0.021 | abstain | 1.000 | – | – | abstain | 0 |
| running | yes | 296 | 0.744 | 0.932 | 0.828 | 0.826 (296) | 0.003 | weak | 0.375 | P=0.768 n=357 → abstain | – | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 855 | 0.503 | 0.170 | 0.254 | 0.543 (855) | 0.012 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.500 | 0.000 | 0.001 | 1.000 (3,518) | 0.014 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,463 | 0.285 | 0.247 | 0.264 | 0.485 (5,463) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| walking+brisk_walking | 8,306 | 0.678 / 0.436 (5,383) | weak | 0.590 | P=0.866 n=3,002 → weak | hhar_watch test: precision 0.660 at n_acc 53 -> abstain | abstain |
| stationary+walking+brisk_walking | 453 | 0.898 / 0.980 (89,779) | strong | 0.900 | P=0.974 n=60,879 → strong | wear test: precision 0.634 at n_acc 41 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| walking | 8,759 | weak→abstain (0.450) | abstain→abstain (1.000) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.407 | 0.401 [0.307, 0.441] | 0.502 | 0.048 |  |
| gotov | 7 | 585 | 0.485 | 0.440 [0.242, 0.500]† | 0.805 | 0.095 |  |
| hhar_watch | 2 | 174 | 0.500 | 0.263 [0.263, 0.365]† | 0.964 | 0.191 | descriptive |
| mhealth | 2 | 49 | 0.547 | 0.492 [0.492, 0.545]† | 0.768 | 0.177 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.295 | 0.245 | descriptive |
| pamap2 | 2 | 397 | 0.517 | 0.391 [0.327, 0.546]† | 1.132 | 0.119 | descriptive |
| wear | 5 | 319 | 0.747 | 0.451 [0.422, 0.580]† | 0.816 | 0.087 |  |
| wisdm2019_watch | 8 | 1,167 | 0.617 | 0.354 [0.293, 0.397]† | 0.899 | 0.113 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.87/0.98/0.92 (71986); gate P 0.97 n 57597 → strong | 0.78/0.90/0.84 (386); gate P 0.99 n 293 → strong | 0.69/1.00/0.82 (74); gate P 1.00 n 74 → strong | 0.64/0.95/0.77 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 5 → weak | 0.76/0.89/0.82 (187); gate P 0.99 n 116 → strong | 0.64/0.88/0.74 (112); gate P 0.57 n 40 → abstain | 1.00/0.83/0.90 (937); gate P 1.00 n 474 → strong |
| walking | 0.90/0.84/0.87 (3225) | 0.54/1.00/0.70 (33) | 0.61/1.00/0.76 (35) | 0.57/1.00/0.73 (4) | 0.00/0.00/0.00 (0) | 0.36/1.00/0.53 (12) | 0.00/0.00/0.00 (0) | 0.22/1.00/0.35 (17) |
| brisk_walking | 0.46/0.10/0.17 (5106) | 0.00/0.00/0.00 (19) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.41/0.52/0.46 (31) | 0.00/0.00/0.00 (0) | 0.21/0.28/0.24 (53) |
| running | 0.60/0.92/0.73 (103); gate P 0.64 n 148 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.28/1.00/0.43 (10); gate P 0.28 n 36 → abstain | 0.95/0.89/0.92 (93); gate P 0.97 n 86 → strong | 0.99/0.97/0.98 (80); gate P 1.00 n 77 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (80) |
| cycling | 0.56/0.18/0.28 (743) | 0.60/0.06/0.12 (47) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 1.00/0.21/0.35 (28) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.50/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.28/0.23/0.25 (5174) | 0.67/0.46/0.54 (100) | 0.00/0.00/0.00 (0) | 0.75/0.33/0.46 (9) | 0.00/0.00/0.00 (0) | 0.55/0.52/0.53 (66) | 0.79/0.47/0.59 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.411 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.894, P 0.885; ≥0.6: cov 0.854, P 0.905; ≥0.7: cov 0.813, P 0.923; ≥0.8: cov 0.748, P 0.944; ≥0.9: cov 0.602, P 0.980; ≥0.95: cov 0.078, P 0.986

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71917     224     267      19       0      71       0    1240
    460    2804       0       6       0       0       0      56
   2710      19     547      31       0      21       1    1880
      5       4       2     276       0       0       0       9
      4      73      50       0       0       0       0      25
    591       8      47       2       0     145       0      62
   3352      18      24       0       0       3       1     120
   3621      91     317      37       0      48       0    1349
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.646 | 0.452 [0.420, 0.527] | 0.413 [0.378, 0.464] | 0.413 [0.378, 0.464] | 1.152→0.725 | 0.656→0.465 | 0.059→0.068 (0.009) | 0.170→0.041 | 0.256 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.423 | 0.022 | 0.043 | 0.423 (6,845) | 0.074 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.654 | 0.979 | 0.784 | 0.654 (13,608) | 0.067 | weak | 0.690 | P=0.715 n=11,028 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.397 | 0.204 | 0.270 | 0.397 (582) | 0.014 | weak | 0.675 | P=0.546 n=163 → abstain | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 0.516 | 0.603 | 0.556 | 0.516 (78) | 0.007 | weak | 0.350 | P=0.516 n=91 → abstain | – | abstain | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.348 | 0.221 [0.195, 0.237] | 0.722 | 0.068 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.359 | 0.300 |  |
| mhealth | 2 | 19 | 0.286 | 0.242 [0.190, 0.333]† | 1.231 | 0.492 | descriptive |
| pamap2 | 2 | 67 | 0.355 | 0.280 [0.000, 0.303]† | 1.504 | 0.545 | descriptive |
| wear | 5 | 64 | 0.562 | 0.360 [0.329, 0.389]† | 2.054 | 0.244 |  |
| wisdm2019_watch | 8 | 320 | 0.819 | 0.813 [0.618, 0.969]† | 0.535 | 0.095 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.42/0.02/0.04 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.98/0.79 (13385); gate P 0.71 n 10808 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 29 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 3 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 23 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 13 → weak | 0.73/1.00/0.85 (160); gate P 0.91 n 152 → weak |
| repetitive_hand_motion | 0.09/0.04/0.06 (393); gate P 0.07 n 80 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (0) | 1.00/0.64/0.78 (160); gate P 1.00 n 83 → strong |
| exercise_motion | 0.00/0.00/0.00 (0); gate P 0.00 n 44 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.57/0.73 (7); gate P 1.00 n 4 → weak | 1.00/1.00/1.00 (7); gate P 1.00 n 7 → weak | 1.00/0.56/0.72 (64); gate P 1.00 n 36 → strong | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.413 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.963, P 0.656; ≥0.6: cov 0.895, P 0.670; ≥0.7: cov 0.486, P 0.722; ≥0.8: cov 0.223, P 0.814; ≥0.9: cov 0.076, P 0.878; ≥0.95: cov 0.007, P 0.874

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    154    6555       0     123       0      13       0
    199   13320       0      58       0      31       0
      0       0       0       0       0       0       0
      9     454       0     119       0       0       0
      0       0       0       0       0       0       0
      2      29       0       0       0      47       0
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

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.170.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.122 | 0.137 | 0.288 | 0.753 | 0.786 |
| capture24 | 95,579 | 0.122 | 0.136 | 0.281 | 0.752 | 0.786 |
| gotov | 333 | 0.148 | 0.206 | 0.375 | 0.716 | 0.721 |
| pamap2 | 234 | 0.129 | 0.203 | 0.573 | 0.814 | 0.654 |

## OOD

Bundle method `knn` (k=20), threshold 0.323 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.048 on 98,307 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
